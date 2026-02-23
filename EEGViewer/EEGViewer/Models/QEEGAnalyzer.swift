// QEEGAnalyzer.swift
// Orchestrates the full qEEG analysis pipeline: PSD, band power, Z-scores, coherence, asymmetry.

import Foundation
import Combine

/// Results from a complete qEEG analysis.
struct QEEGResults {
    let freqs: [Float]
    let psd: [[Float]]  // [channel][freq]
    let bandPowers: [String: [Float]]  // band name → [channel]
    let relativePowers: [String: [Float]]
    let zscores: [String: [Float]]
    let coherence: [String: [[Float]]]  // band name → [ch][ch]
    let asymmetry: [String: [(pair: String, value: Float)]]
    let peakFreqs: [(channel: String, alphaPeak: Float, dominant: Float)]
    let artifactStats: SignalProcessor.ArtifactStats
    let cleanData: [[Float]]
    let channels: [String]
    let sfreq: Float
}

@MainActor
class QEEGAnalyzer: ObservableObject {
    @Published var progress: Float = 0
    @Published var statusMessage: String = ""
    @Published var results: QEEGResults?
    @Published var isAnalyzing = false

    func analyze(edfData: EDFData) async {
        isAnalyzing = true
        progress = 0
        statusMessage = "Starting analysis..."

        let channels = edfData.eegChannelNames
        var data = edfData.eegData
        let sfreq = edfData.sfreq

        // Step 1: Preprocess — average reference + high-pass filter
        await updateProgress(0.02, "Average referencing...")
        data = await Task.detached {
            SignalProcessor.averageReference(data)
        }.value

        await updateProgress(0.04, "High-pass filtering...")
        data = await Task.detached {
            data.map { SignalProcessor.highpassFilter($0, sfreq: sfreq, cutoff: 1.0) }
        }.value

        // Step 2: Artifact rejection
        await updateProgress(0.06, "Rejecting artifacts...")
        let (cleanData, artifactStats) = await Task.detached {
            SignalProcessor.rejectArtifacts(data, sfreq: sfreq)
        }.value

        let pctRejected = artifactStats.totalEpochs > 0
            ? Float(artifactStats.rejectedEpochs) / Float(artifactStats.totalEpochs) * 100
            : 0
        await updateProgress(0.08, "Artifacts: \(artifactStats.cleanEpochs)/\(artifactStats.totalEpochs) clean (\(String(format: "%.1f", pctRejected))% rejected)")

        // Step 3: Compute PSD for all channels
        await updateProgress(0.10, "Computing PSD...")
        let nChannels = cleanData.count
        var allPSD = [[Float]](repeating: [], count: nChannels)
        var freqs = [Float]()

        let psdResults = await Task.detached {
            cleanData.map { SignalProcessor.welchPSD($0, sfreq: sfreq) }
        }.value

        for (i, result) in psdResults.enumerated() {
            if i == 0 { freqs = result.freqs }
            allPSD[i] = result.psd
        }

        // Step 4: Band powers and Z-scores
        await updateProgress(0.20, "Computing band powers...")
        var bandPowers = [String: [Float]]()
        var relativePowers = [String: [Float]]()
        var zscores = [String: [Float]]()

        for band in Constants.freqBands {
            var bp = [Float](repeating: 0, count: nChannels)
            var rp = [Float](repeating: 0, count: nChannels)
            for ch in 0..<nChannels {
                bp[ch] = SignalProcessor.bandPower(allPSD[ch], freqs: freqs, low: band.low, high: band.high)
                rp[ch] = SignalProcessor.relativePower(allPSD[ch], freqs: freqs, low: band.low, high: band.high)
            }
            bandPowers[band.name] = bp
            relativePowers[band.name] = rp
            zscores[band.name] = SignalProcessor.zscoresWithin(rp)
        }

        // Step 5: Coherence (most expensive — O(n²) channel pairs)
        await updateProgress(0.35, "Computing coherence...")
        var coherenceMatrices = [String: [[Float]]]()

        for (bandIdx, band) in Constants.freqBands.enumerated() {
            let bandMatrix = await Task.detached {
                var mat = [[Float]](repeating: [Float](repeating: 0, count: nChannels), count: nChannels)
                for i in 0..<nChannels {
                    mat[i][i] = 1.0
                    for j in (i + 1)..<nChannels {
                        let (cohFreqs, coh) = SignalProcessor.coherence(cleanData[i], cleanData[j], sfreq: sfreq)
                        let bandCoh = SignalProcessor.bandCoherence(coh, freqs: cohFreqs, low: band.low, high: band.high)
                        mat[i][j] = bandCoh
                        mat[j][i] = bandCoh
                    }
                }
                return mat
            }.value

            coherenceMatrices[band.name] = bandMatrix
            let cohProgress = 0.35 + Float(bandIdx + 1) / Float(Constants.freqBands.count) * 0.45
            await updateProgress(cohProgress, "Coherence: \(band.name) complete")
        }

        // Step 6: Asymmetry
        await updateProgress(0.85, "Computing asymmetry...")
        var asymmetry = [String: [(pair: String, value: Float)]]()

        for band in Constants.freqBands {
            guard let bp = bandPowers[band.name] else { continue }
            var pairs = [(pair: String, value: Float)]()
            for ap in Constants.asymmetryPairs {
                guard let leftIdx = channels.firstIndex(of: ap.left),
                      let rightIdx = channels.firstIndex(of: ap.right) else { continue }
                let leftPower = bp[leftIdx]
                let rightPower = bp[rightIdx]
                let asymValue = (leftPower > 0 && rightPower > 0)
                    ? log(rightPower) - log(leftPower)
                    : 0
                pairs.append((pair: "\(ap.left)-\(ap.right)", value: asymValue))
            }
            asymmetry[band.name] = pairs
        }

        // Step 7: Peak frequencies
        await updateProgress(0.92, "Finding peak frequencies...")
        var peakFreqs = [(channel: String, alphaPeak: Float, dominant: Float)]()

        for (ch, channelName) in channels.enumerated() {
            guard ch < allPSD.count else { continue }
            let psd = allPSD[ch]

            // Alpha peak (8-13 Hz)
            var alphaPeak: Float = 0
            var alphaMax: Float = -Float.infinity
            for (i, f) in freqs.enumerated() where f >= 8 && f <= 13 {
                if psd[i] > alphaMax {
                    alphaMax = psd[i]
                    alphaPeak = f
                }
            }

            // Dominant frequency (1-25 Hz)
            var dominant: Float = 0
            var domMax: Float = -Float.infinity
            for (i, f) in freqs.enumerated() where f >= 1 && f <= 25 {
                if psd[i] > domMax {
                    domMax = psd[i]
                    dominant = f
                }
            }

            peakFreqs.append((channel: channelName, alphaPeak: alphaPeak, dominant: dominant))
        }

        await updateProgress(1.0, "Analysis complete")

        results = QEEGResults(
            freqs: freqs,
            psd: allPSD,
            bandPowers: bandPowers,
            relativePowers: relativePowers,
            zscores: zscores,
            coherence: coherenceMatrices,
            asymmetry: asymmetry,
            peakFreqs: peakFreqs,
            artifactStats: artifactStats,
            cleanData: cleanData,
            channels: channels,
            sfreq: sfreq
        )

        isAnalyzing = false
    }

    private func updateProgress(_ value: Float, _ message: String) async {
        progress = value
        statusMessage = message
    }
}
