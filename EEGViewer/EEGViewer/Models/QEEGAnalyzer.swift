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
    let sourceFilename: String
    /// True when this result set represents a diff (post − baseline), not a real recording.
    let isDiff: Bool

    init(freqs: [Float], psd: [[Float]], bandPowers: [String: [Float]],
         relativePowers: [String: [Float]], zscores: [String: [Float]],
         coherence: [String: [[Float]]], asymmetry: [String: [(pair: String, value: Float)]],
         peakFreqs: [(channel: String, alphaPeak: Float, dominant: Float)],
         artifactStats: SignalProcessor.ArtifactStats, cleanData: [[Float]],
         channels: [String], sfreq: Float, sourceFilename: String, isDiff: Bool = false) {
        self.freqs = freqs; self.psd = psd; self.bandPowers = bandPowers
        self.relativePowers = relativePowers; self.zscores = zscores
        self.coherence = coherence; self.asymmetry = asymmetry
        self.peakFreqs = peakFreqs; self.artifactStats = artifactStats
        self.cleanData = cleanData; self.channels = channels
        self.sfreq = sfreq; self.sourceFilename = sourceFilename; self.isDiff = isDiff
    }

    /// Compute element-wise difference: post − baseline.
    /// PSD is stored in the amplitude domain (sqrt(post) − sqrt(baseline)) so the spectra chart
    /// can display values as µV change without needing sqrtf on potentially negative numbers.
    /// Returns nil if channels or frequency resolution don't match.
    static func diff(baseline: QEEGResults, post: QEEGResults) -> QEEGResults? {
        guard baseline.channels == post.channels,
              baseline.freqs.count == post.freqs.count else { return nil }

        let nCh = baseline.channels.count
        let nFreq = baseline.freqs.count

        // PSD: amplitude-domain diff → sqrt(post) - sqrt(baseline)
        var diffPSD = [[Float]](repeating: [Float](repeating: 0, count: nFreq), count: nCh)
        for ch in 0..<nCh {
            for f in 0..<nFreq {
                let postAmp = ch < post.psd.count && f < post.psd[ch].count
                    ? sqrtf(max(0, post.psd[ch][f])) : 0
                let baseAmp = ch < baseline.psd.count && f < baseline.psd[ch].count
                    ? sqrtf(max(0, baseline.psd[ch][f])) : 0
                diffPSD[ch][f] = postAmp - baseAmp
            }
        }

        // Band powers, relative powers, z-scores: element-wise diff
        let bands = Array(baseline.bandPowers.keys)
        var diffBandPowers = [String: [Float]]()
        var diffRelativePowers = [String: [Float]]()
        var diffZscores = [String: [Float]]()
        for band in bands {
            let bp1 = baseline.bandPowers[band] ?? []
            let bp2 = post.bandPowers[band] ?? []
            diffBandPowers[band] = (0..<nCh).map { i in
                (i < bp2.count ? bp2[i] : 0) - (i < bp1.count ? bp1[i] : 0)
            }
            let rp1 = baseline.relativePowers[band] ?? []
            let rp2 = post.relativePowers[band] ?? []
            diffRelativePowers[band] = (0..<nCh).map { i in
                (i < rp2.count ? rp2[i] : 0) - (i < rp1.count ? rp1[i] : 0)
            }
            let z1 = baseline.zscores[band] ?? []
            let z2 = post.zscores[band] ?? []
            diffZscores[band] = (0..<nCh).map { i in
                (i < z2.count ? z2[i] : 0) - (i < z1.count ? z1[i] : 0)
            }
        }

        // Coherence: element-wise matrix diff per band
        var diffCoherence = [String: [[Float]]]()
        for band in bands {
            let c1 = baseline.coherence[band] ?? []
            let c2 = post.coherence[band] ?? []
            var matrix = [[Float]](repeating: [Float](repeating: 0, count: nCh), count: nCh)
            for i in 0..<nCh {
                for j in 0..<nCh {
                    let v1 = (i < c1.count && j < c1[i].count) ? c1[i][j] : 0
                    let v2 = (i < c2.count && j < c2[i].count) ? c2[i][j] : 0
                    matrix[i][j] = v2 - v1
                }
            }
            diffCoherence[band] = matrix
        }

        // Asymmetry: match pairs by name and diff
        var diffAsymmetry = [String: [(pair: String, value: Float)]]()
        for band in bands {
            let a1 = baseline.asymmetry[band] ?? []
            let a2 = post.asymmetry[band] ?? []
            let a1Dict = Dictionary(uniqueKeysWithValues: a1.map { ($0.pair, $0.value) })
            diffAsymmetry[band] = a2.map { item in
                let baseVal = a1Dict[item.pair] ?? 0
                return (pair: item.pair, value: item.value - baseVal)
            }
        }

        // Peak frequencies: diff per channel
        let diffPeaks: [(channel: String, alphaPeak: Float, dominant: Float)] =
            zip(baseline.peakFreqs, post.peakFreqs).map { b, p in
                (channel: b.channel, alphaPeak: p.alphaPeak - b.alphaPeak,
                 dominant: p.dominant - b.dominant)
            }

        return QEEGResults(
            freqs: baseline.freqs, psd: diffPSD,
            bandPowers: diffBandPowers, relativePowers: diffRelativePowers,
            zscores: diffZscores, coherence: diffCoherence,
            asymmetry: diffAsymmetry, peakFreqs: diffPeaks,
            artifactStats: post.artifactStats, cleanData: [],
            channels: baseline.channels, sfreq: baseline.sfreq,
            sourceFilename: "Difference (R2 \u{2212} R1)", isDiff: true
        )
    }
}

@MainActor
class QEEGAnalyzer: ObservableObject {
    @Published var progress: Float = 0
    @Published var statusMessage: String = ""
    @Published var results: QEEGResults?
    @Published var isAnalyzing = false

    func analyze(edfData: EDFData, filename: String = "", exclusions: [(start: Float, end: Float)] = [], badChannelIndices: Set<Int> = []) async {
        isAnalyzing = true
        progress = 0
        statusMessage = "Starting analysis..."

        let channels = edfData.eegChannelNames
        var data = edfData.eegData
        let sfreq = edfData.sfreq

        // Step 0.5: Interpolate bad channels before average referencing
        if !badChannelIndices.isEmpty {
            await updateProgress(0.01, "Interpolating bad channels...")
            data = await Task.detached {
                SignalProcessor.interpolateBadChannels(data, channels: channels, badChannelIndices: badChannelIndices)
            }.value
        }

        // Step 1: Preprocess — average reference + high-pass filter
        await updateProgress(0.02, "Average referencing...")
        data = await Task.detached {
            SignalProcessor.averageReference(data)
        }.value

        await updateProgress(0.04, "High-pass filtering...")
        data = await Task.detached {
            data.map { SignalProcessor.highpassFilter($0, sfreq: sfreq, cutoff: 1.0) }
        }.value

        // Step 1.5: Apply manual annotation exclusions
        if !exclusions.isEmpty {
            await updateProgress(0.05, "Applying annotation exclusions...")
            data = await Task.detached {
                SignalProcessor.applyExclusions(data, sfreq: sfreq, exclusions: exclusions)
            }.value
        }

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

        // Step 5: Coherence — compute once per pair, extract all bands at once
        await updateProgress(0.35, "Computing coherence...")
        let coherenceMatrices = await Task.detached(priority: .userInitiated) {
            // Use smaller nperseg (512) for faster coherence — less freq resolution but much faster
            let cohNperseg = 512
            let cohNoverlap = 256

            // Initialize matrices for all bands
            var matrices = [String: [[Float]]]()
            for band in Constants.freqBands {
                matrices[band.name] = [[Float]](repeating: [Float](repeating: 0, count: nChannels), count: nChannels)
                // Diagonal = 1.0
                for i in 0..<nChannels { matrices[band.name]![i][i] = 1.0 }
            }

            // Compute coherence once per pair, extract all 4 bands
            for i in 0..<nChannels {
                for j in (i + 1)..<nChannels {
                    let (cohFreqs, coh) = SignalProcessor.coherence(
                        cleanData[i], cleanData[j], sfreq: sfreq,
                        nperseg: cohNperseg, noverlap: cohNoverlap
                    )
                    // Extract band coherence for all 4 bands from this single computation
                    for band in Constants.freqBands {
                        let bandCoh = SignalProcessor.bandCoherence(coh, freqs: cohFreqs, low: band.low, high: band.high)
                        matrices[band.name]![i][j] = bandCoh
                        matrices[band.name]![j][i] = bandCoh
                    }
                }
            }
            return matrices
        }.value

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
            sfreq: sfreq,
            sourceFilename: filename
        )

        isAnalyzing = false
    }

    private func updateProgress(_ value: Float, _ message: String) async {
        progress = value
        statusMessage = message
    }
}
