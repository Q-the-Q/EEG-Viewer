// HRVAnalyzer.swift
// Orchestrates HRV analysis: R-peak detection, time/frequency-domain HRV, heart-brain coherence.

import Foundation
import Accelerate

/// Results from a complete HRV analysis.
struct HRVResults {
    // R-peak detection
    let rPeakIndices: [Int]
    let rrIntervals: [Float]       // ms
    let rrTimes: [Float]           // seconds

    // Time-domain HRV
    let meanHR: Float              // BPM
    let sdnn: Float                // ms
    let rmssd: Float               // ms
    let pnn50: Float               // %

    // Frequency-domain HRV
    let hrvFreqs: [Float]
    let hrvPSD: [Float]
    let lfPower: Float             // ms^2
    let hfPower: Float             // ms^2
    let lfHfRatio: Float
    let totalPower: Float          // ms^2

    // Poincaré plot
    let rrN: [Float]               // RR[n]
    let rrN1: [Float]              // RR[n+1]
    let sd1: Float                 // ms
    let sd2: Float                 // ms

    // Heart-Brain Coherence (multi-band)
    let heartBrainCoherenceByBand: [String: [String: Float]]  // band → (channel → LF coherence)
    let coherenceScoreByBand: [String: Float]                  // band → mean coherence
    let coherenceBestBand: String                              // band with highest mean

    /// Backward-compatible accessor: returns alpha-band per-channel coherence.
    var heartBrainCoherence: [String: Float] {
        heartBrainCoherenceByBand["Alpha"] ?? [:]
    }
    /// Backward-compatible accessor: returns alpha-band overall coherence score.
    var coherenceScore: Float {
        coherenceScoreByBand["Alpha"] ?? 0
    }

    // Metadata
    let ecgChannelName: String
    let sfreq: Float
    let sourceFilename: String
    let ecgIsInverted: Bool            // true if inverted polarity was chosen
}

@MainActor
class HRVAnalyzer: ObservableObject {
    @Published var progress: Float = 0
    @Published var statusMessage: String = ""
    @Published var results: HRVResults?
    @Published var isAnalyzing = false
    @Published var errorMessage: String?

    func analyze(edfData: EDFData, filename: String = "", exclusions: [(start: Float, end: Float)] = []) async {
        isAnalyzing = true
        errorMessage = nil
        progress = 0
        statusMessage = "Starting heart analysis..."

        guard let ecgSignal = edfData.ecgData,
              let ecgName = edfData.ecgChannelName else {
            errorMessage = "No ECG/EKG channel found."
            isAnalyzing = false
            return
        }

        let sfreq = edfData.sfreq

        // Step 0.5: Apply annotation exclusions to ECG signal
        let ecgForAnalysis: [Float]
        if !exclusions.isEmpty {
            let excluded = SignalProcessor.applyExclusions([ecgSignal], sfreq: sfreq, exclusions: exclusions)
            ecgForAnalysis = excluded.first ?? ecgSignal
        } else {
            ecgForAnalysis = ecgSignal
        }

        // Step 1: Preprocess ECG for R-peak detection
        await updateProgress(0.05, "Preprocessing ECG...")
        let filteredECG = await Task.detached {
            SignalProcessor.bandpassFilter(ecgForAnalysis, sfreq: sfreq,
                                           lowCut: Constants.ecgBandpassLow,
                                           highCut: Constants.ecgBandpassHigh)
        }.value

        // Step 2: Pan-Tompkins R-peak detection
        await updateProgress(0.15, "Detecting R-peaks...")
        let detection = await Task.detached {
            HRVAnalyzer.detectRPeaks(filteredECG: filteredECG, rawECG: ecgForAnalysis, sfreq: sfreq)
        }.value
        let rPeakIndices = detection.peaks
        let ecgIsInverted = detection.isInverted

        guard rPeakIndices.count >= 10 else {
            errorMessage = "Insufficient ECG quality — only \(rPeakIndices.count) R-peaks detected."
            isAnalyzing = false
            return
        }

        // Step 3: Compute R-R intervals
        await updateProgress(0.30, "Computing R-R intervals...")
        var rrIntervals = [Float]()
        var rrTimes = [Float]()
        for i in 1..<rPeakIndices.count {
            let diffSamples = Float(rPeakIndices[i] - rPeakIndices[i - 1])
            let rrMs = diffSamples / sfreq * 1000.0
            // Reject physiologically implausible intervals
            if rrMs >= Constants.rPeakMinRR_ms && rrMs <= Constants.rPeakMaxRR_ms {
                rrIntervals.append(rrMs)
                rrTimes.append(Float(rPeakIndices[i]) / sfreq)
            }
        }

        guard rrIntervals.count >= 5 else {
            errorMessage = "Too few valid R-R intervals (\(rrIntervals.count))."
            isAnalyzing = false
            return
        }

        // Step 4: Time-domain HRV metrics
        await updateProgress(0.40, "Computing HRV metrics...")
        let timeDomain = await Task.detached {
            HRVAnalyzer.computeTimeDomain(rrIntervals: rrIntervals)
        }.value

        // Step 5: Poincaré
        await updateProgress(0.50, "Computing Poincaré plot...")
        let poincare = await Task.detached {
            HRVAnalyzer.computePoincare(rrIntervals: rrIntervals)
        }.value

        // Step 6: Frequency-domain HRV
        await updateProgress(0.60, "Computing HRV spectrum...")
        let freqDomain = await Task.detached {
            HRVAnalyzer.computeFrequencyDomain(rrIntervals: rrIntervals, rrTimes: rrTimes)
        }.value

        // Step 7: Heart-Brain Coherence
        await updateProgress(0.75, "Computing heart-brain coherence...")
        let coherenceResult = await Task.detached {
            HRVAnalyzer.computeHeartBrainCoherence(
                rrIntervals: rrIntervals, rrTimes: rrTimes,
                eegData: edfData.eegData, eegChannels: edfData.eegChannelNames,
                sfreq: sfreq
            )
        }.value

        await updateProgress(1.0, "Analysis complete")

        results = HRVResults(
            rPeakIndices: rPeakIndices,
            rrIntervals: rrIntervals,
            rrTimes: rrTimes,
            meanHR: timeDomain.meanHR,
            sdnn: timeDomain.sdnn,
            rmssd: timeDomain.rmssd,
            pnn50: timeDomain.pnn50,
            hrvFreqs: freqDomain.freqs,
            hrvPSD: freqDomain.psd,
            lfPower: freqDomain.lfPower,
            hfPower: freqDomain.hfPower,
            lfHfRatio: freqDomain.lfHfRatio,
            totalPower: freqDomain.totalPower,
            rrN: poincare.rrN,
            rrN1: poincare.rrN1,
            sd1: poincare.sd1,
            sd2: poincare.sd2,
            heartBrainCoherenceByBand: coherenceResult.perBand,
            coherenceScoreByBand: coherenceResult.overallByBand,
            coherenceBestBand: coherenceResult.bestBand,
            ecgChannelName: ecgName,
            sfreq: sfreq,
            sourceFilename: filename,
            ecgIsInverted: ecgIsInverted
        )

        isAnalyzing = false
    }

    private func updateProgress(_ value: Float, _ message: String) async {
        progress = value
        statusMessage = message
    }

    // MARK: - R-Peak Detection (Pan-Tompkins)

    nonisolated private static func detectRPeaks(filteredECG: [Float], rawECG: [Float], sfreq: Float) -> (peaks: [Int], isInverted: Bool) {
        let n = filteredECG.count
        guard n > Int(sfreq) else { return ([], false) }

        // Try both polarities (some devices record inverted ECG)
        let normalPeaks = panTompkins(signal: filteredECG, rawSignal: rawECG, sfreq: sfreq)
        let invertedFiltered = filteredECG.map { -$0 }
        let invertedRaw = rawECG.map { -$0 }
        let invertedPeaks = panTompkins(signal: invertedFiltered, rawSignal: invertedRaw, sfreq: sfreq)

        let isInverted = invertedPeaks.count > normalPeaks.count
        let primaryPeaks = isInverted ? invertedPeaks : normalPeaks

        // If Pan-Tompkins fails badly, fall back to simple peak detection on raw signal
        if primaryPeaks.count < 5 {
            let fallbackPeaks = simplePeakDetection(rawSignal: rawECG, sfreq: sfreq)
            if fallbackPeaks.count > primaryPeaks.count {
                return (fallbackPeaks, false)
            }
        }

        return (primaryPeaks, isInverted)
    }

    /// Robust Pan-Tompkins with amplitude normalization and adaptive thresholding.
    nonisolated private static func panTompkins(signal: [Float], rawSignal: [Float], sfreq: Float) -> [Int] {
        let n = signal.count
        guard n > 10 else { return [] }

        // 0. Normalize signal to zero-mean, unit-variance (amplitude-independent)
        var mean: Float = 0
        var sd: Float = 0
        vDSP_normalize(signal, 1, nil, 1, &mean, &sd, vDSP_Length(n))
        var normalized: [Float]
        if sd > 0 {
            normalized = signal.map { ($0 - mean) / sd }
        } else {
            normalized = signal
        }

        // 1. Differentiate: 5-point derivative [-1,-2,0,2,1]
        // Don't scale by sfreq — normalized signal makes this rate-independent
        var diff = [Float](repeating: 0, count: n)
        for i in 2..<(n - 2) {
            diff[i] = -normalized[i - 2] - 2 * normalized[i - 1] + 2 * normalized[i + 1] + normalized[i + 2]
        }

        // 2. Square
        var squared = [Float](repeating: 0, count: n)
        vDSP_vsq(diff, 1, &squared, 1, vDSP_Length(n))

        // 3. Moving window integration (~150 ms)
        let winLen = max(1, Int(0.15 * sfreq))
        var integrated = [Float](repeating: 0, count: n)
        var runningSum: Float = 0
        for i in 0..<n {
            runningSum += squared[i]
            if i >= winLen { runningSum -= squared[i - winLen] }
            integrated[i] = runningSum / Float(min(i + 1, winLen))
        }

        // 4. Compute robust threshold from the full signal (not just first 2s)
        //    Use sorted values to find a percentile-based threshold
        let sorted = integrated.sorted()
        let p90 = sorted[Int(Float(sorted.count) * 0.90)]
        let p50 = sorted[Int(Float(sorted.count) * 0.50)]
        var threshold = p50 + 0.3 * (p90 - p50)  // Between median and 90th percentile

        let refractorySamples = max(1, Int(Constants.rPeakRefractoryMs / 1000.0 * sfreq))
        let searchRadius = max(1, Int(0.075 * sfreq))  // ±75 ms

        var peaks = [Int]()
        var lastPeakIdx = -refractorySamples
        var recentPeakValues = [Float]()

        for i in 1..<(n - 1) {
            if i - lastPeakIdx < refractorySamples { continue }

            if integrated[i] > threshold &&
               integrated[i] >= integrated[i - 1] &&
               integrated[i] >= integrated[i + 1] {

                // Refine: find true R-peak (maximum value) in raw signal within ±75ms
                // rawSignal is already polarity-corrected, so search for max (not abs max)
                let searchStart = max(0, i - searchRadius)
                let searchEnd = min(rawSignal.count, i + searchRadius + 1)
                var bestIdx = i
                var bestVal: Float = -Float.infinity
                for j in searchStart..<searchEnd {
                    if rawSignal[j] > bestVal {
                        bestVal = rawSignal[j]
                        bestIdx = j
                    }
                }

                peaks.append(bestIdx)
                lastPeakIdx = bestIdx

                // Adaptive threshold: track recent peak heights
                recentPeakValues.append(integrated[i])
                if recentPeakValues.count > 8 { recentPeakValues.removeFirst() }
                let recentMean = recentPeakValues.reduce(0, +) / Float(recentPeakValues.count)
                threshold = 0.35 * recentMean  // 35% of recent average peak height
            }
        }

        // Search-back pass: find missed beats in large gaps
        if peaks.count >= 2 {
            var meanRR: Float = 0
            for i in 1..<peaks.count {
                meanRR += Float(peaks[i] - peaks[i - 1])
            }
            meanRR /= Float(peaks.count - 1)

            var insertions = [(index: Int, peak: Int)]()
            for i in 1..<peaks.count {
                let gap = Float(peaks[i] - peaks[i - 1])
                if gap > 1.8 * meanRR {
                    // Search this gap with a lower threshold
                    let gapStart = peaks[i - 1] + refractorySamples
                    let gapEnd = peaks[i] - refractorySamples
                    if gapStart < gapEnd {
                        var bestIdx = gapStart
                        var bestVal: Float = -Float.infinity
                        for j in gapStart..<gapEnd {
                            if integrated[j] > bestVal {
                                bestVal = integrated[j]
                                bestIdx = j
                            }
                        }
                        if bestVal > threshold * 0.3 {
                            // Refine in raw signal (search for max, not abs max)
                            let sStart = max(0, bestIdx - searchRadius)
                            let sEnd = min(rawSignal.count, bestIdx + searchRadius + 1)
                            var refinedIdx = bestIdx
                            var refinedVal: Float = -Float.infinity
                            for j in sStart..<sEnd {
                                if rawSignal[j] > refinedVal {
                                    refinedVal = rawSignal[j]
                                    refinedIdx = j
                                }
                            }
                            // Verify refractory distance from neighboring peaks
                            let tooCloseLeft = refinedIdx - peaks[i - 1] < refractorySamples
                            let tooCloseRight = peaks[i] - refinedIdx < refractorySamples
                            if !tooCloseLeft && !tooCloseRight {
                                insertions.append((index: i, peak: refinedIdx))
                            }
                        }
                    }
                }
            }
            // Insert in reverse order to preserve indices
            for ins in insertions.reversed() {
                peaks.insert(ins.peak, at: ins.index)
            }
        }

        return peaks
    }

    /// Fallback detector: simple amplitude-based peak finding on the raw ECG.
    /// Used when Pan-Tompkins fails (e.g., unusual signal characteristics).
    nonisolated private static func simplePeakDetection(rawSignal: [Float], sfreq: Float) -> [Int] {
        let n = rawSignal.count
        guard n > Int(sfreq) else { return [] }

        // Highpass at 1 Hz to remove baseline wander
        let filtered = SignalProcessor.highpassFilter(rawSignal, sfreq: sfreq, cutoff: 1.0)

        // Compute absolute value envelope
        let absSignal = filtered.map { abs($0) }

        // Smooth with ~100ms moving average
        let smoothLen = max(1, Int(0.1 * sfreq))
        var smoothed = [Float](repeating: 0, count: n)
        var runSum: Float = 0
        for i in 0..<n {
            runSum += absSignal[i]
            if i >= smoothLen { runSum -= absSignal[i - smoothLen] }
            smoothed[i] = runSum / Float(min(i + 1, smoothLen))
        }

        // Threshold: use percentile-based approach
        let sorted = smoothed.sorted()
        let p75 = sorted[Int(Float(n) * 0.75)]
        let p50 = sorted[Int(Float(n) * 0.50)]
        let threshold = p50 + 0.5 * (p75 - p50)

        let refractorySamples = max(1, Int(Constants.rPeakRefractoryMs / 1000.0 * sfreq))

        var peaks = [Int]()
        var lastPeakIdx = -refractorySamples

        for i in 1..<(n - 1) {
            if i - lastPeakIdx < refractorySamples { continue }

            if smoothed[i] > threshold &&
               smoothed[i] >= smoothed[max(0, i - 1)] &&
               smoothed[i] >= smoothed[min(n - 1, i + 1)] {

                // Refine: find actual peak in raw signal within ±50ms
                let radius = max(1, Int(0.05 * sfreq))
                let sStart = max(0, i - radius)
                let sEnd = min(n, i + radius + 1)
                var bestIdx = i
                var bestVal: Float = -Float.infinity
                for j in sStart..<sEnd {
                    if abs(filtered[j]) > bestVal {
                        bestVal = abs(filtered[j])
                        bestIdx = j
                    }
                }

                peaks.append(bestIdx)
                lastPeakIdx = bestIdx
            }
        }

        return peaks
    }

    // MARK: - Time-Domain HRV

    private struct TimeDomainResult {
        let meanHR: Float
        let sdnn: Float
        let rmssd: Float
        let pnn50: Float
    }

    nonisolated private static func computeTimeDomain(rrIntervals: [Float]) -> TimeDomainResult {
        let count = rrIntervals.count
        guard count > 1 else {
            return TimeDomainResult(meanHR: 0, sdnn: 0, rmssd: 0, pnn50: 0)
        }

        // Mean RR and Mean HR
        var meanRR: Float = 0
        vDSP_meanv(rrIntervals, 1, &meanRR, vDSP_Length(count))
        let meanHR = meanRR > 0 ? 60000.0 / meanRR : 0

        // SDNN: standard deviation of all NN intervals
        // vDSP_normalize returns population stddev (divides by N); clinical SDNN uses
        // sample stddev (divides by N-1), so apply Bessel's correction.
        var mean: Float = 0
        var sdnn: Float = 0
        var popSD: Float = 0
        vDSP_normalize(rrIntervals, 1, nil, 1, &mean, &popSD, vDSP_Length(count))
        let n = Float(count)
        sdnn = count > 1 ? popSD * sqrtf(n / (n - 1)) : popSD

        // Successive differences
        var diffs = [Float](repeating: 0, count: count - 1)
        for i in 0..<(count - 1) {
            diffs[i] = rrIntervals[i + 1] - rrIntervals[i]
        }

        // RMSSD: root mean square of successive differences
        var squaredDiffs = [Float](repeating: 0, count: diffs.count)
        vDSP_vsq(diffs, 1, &squaredDiffs, 1, vDSP_Length(diffs.count))
        var meanSqDiff: Float = 0
        vDSP_meanv(squaredDiffs, 1, &meanSqDiff, vDSP_Length(diffs.count))
        let rmssd = sqrtf(meanSqDiff)

        // pNN50: percentage of successive differences > 50 ms
        let nn50Count = diffs.filter { abs($0) > 50.0 }.count
        let pnn50 = Float(nn50Count) / Float(diffs.count) * 100.0

        return TimeDomainResult(meanHR: meanHR, sdnn: sdnn, rmssd: rmssd, pnn50: pnn50)
    }

    // MARK: - Poincaré Plot

    private struct PoincareResult {
        let rrN: [Float]
        let rrN1: [Float]
        let sd1: Float
        let sd2: Float
    }

    nonisolated private static func computePoincare(rrIntervals: [Float]) -> PoincareResult {
        guard rrIntervals.count >= 2 else {
            return PoincareResult(rrN: [], rrN1: [], sd1: 0, sd2: 0)
        }

        let rrN = Array(rrIntervals.dropLast())
        let rrN1 = Array(rrIntervals.dropFirst())

        // SD1 = std(RR[n+1] - RR[n]) / sqrt(2)
        let diffs = zip(rrN1, rrN).map { $0 - $1 }
        let sd1 = stddev(diffs) / sqrtf(2.0)

        // SD2 = std(RR[n+1] + RR[n]) / sqrt(2)
        let sums = zip(rrN1, rrN).map { $0 + $1 }
        let sd2 = stddev(sums) / sqrtf(2.0)

        return PoincareResult(rrN: rrN, rrN1: rrN1, sd1: sd1, sd2: sd2)
    }

    /// Sample standard deviation (Bessel-corrected, divides by N-1).
    nonisolated private static func stddev(_ arr: [Float]) -> Float {
        guard arr.count > 1 else { return 0 }
        var mean: Float = 0
        var popSD: Float = 0
        vDSP_normalize(arr, 1, nil, 1, &mean, &popSD, vDSP_Length(arr.count))
        let n = Float(arr.count)
        return popSD * sqrtf(n / (n - 1))
    }

    // MARK: - Frequency-Domain HRV

    private struct FreqDomainResult {
        let freqs: [Float]
        let psd: [Float]
        let lfPower: Float
        let hfPower: Float
        let lfHfRatio: Float
        let totalPower: Float
    }

    nonisolated private static func computeFrequencyDomain(rrIntervals: [Float], rrTimes: [Float]) -> FreqDomainResult {
        let empty = FreqDomainResult(freqs: [], psd: [], lfPower: 0, hfPower: 0, lfHfRatio: 0, totalPower: 0)
        guard rrTimes.count >= 10 else { return empty }

        let interpRate = Constants.hrvInterpolationRate

        // Interpolate RR intervals to uniform 4 Hz grid
        let rrUniform = SignalProcessor.interpolateLinear(
            times: rrTimes, values: rrIntervals, targetSfreq: interpRate
        )
        guard rrUniform.count >= Constants.hrvPsdNperseg else { return empty }

        // Remove mean (detrend)
        var mean: Float = 0
        vDSP_meanv(rrUniform, 1, &mean, vDSP_Length(rrUniform.count))
        let detrended = rrUniform.map { $0 - mean }

        // Welch PSD
        let (freqs, psd) = SignalProcessor.welchPSD(
            detrended, sfreq: interpRate,
            nperseg: Constants.hrvPsdNperseg, noverlap: Constants.hrvPsdNoverlap
        )

        // Band powers
        let lfPower = SignalProcessor.bandPower(psd, freqs: freqs,
                                                 low: Constants.lfBand.low, high: Constants.lfBand.high)
        let hfPower = SignalProcessor.bandPower(psd, freqs: freqs,
                                                 low: Constants.hfBand.low, high: Constants.hfBand.high)
        let totalPower = SignalProcessor.bandPower(psd, freqs: freqs,
                                                    low: Constants.totalHRVBand.low, high: Constants.totalHRVBand.high)
        let lfHfRatio = hfPower > 0 ? lfPower / hfPower : 0

        return FreqDomainResult(
            freqs: freqs, psd: psd,
            lfPower: lfPower, hfPower: hfPower,
            lfHfRatio: lfHfRatio, totalPower: totalPower
        )
    }

    // MARK: - Heart-Brain Coherence

    private struct CoherenceResult {
        let perBand: [String: [String: Float]]   // band → (channel → coherence)
        let overallByBand: [String: Float]        // band → mean coherence
        let bestBand: String                      // band with highest mean
    }

    nonisolated private static func computeHeartBrainCoherence(
        rrIntervals: [Float], rrTimes: [Float],
        eegData: [[Float]], eegChannels: [String],
        sfreq: Float
    ) -> CoherenceResult {
        let empty = CoherenceResult(
            perBand: [:], overallByBand: [:], bestBand: "Alpha"
        )
        guard rrTimes.count >= 10, !eegData.isEmpty else { return empty }

        let interpRate = Constants.hrvInterpolationRate
        let windowSec = Constants.eegEnvelopeWindowSec
        let stepSec = Constants.eegEnvelopeStepSec

        // Cardiac rhythm signal: interpolated RR at 4 Hz, detrended
        let cardiacSignal = SignalProcessor.interpolateLinear(
            times: rrTimes, values: rrIntervals, targetSfreq: interpRate
        )
        guard cardiacSignal.count >= 32 else { return empty }

        var cardiacMean: Float = 0
        vDSP_meanv(cardiacSignal, 1, &cardiacMean, vDSP_Length(cardiacSignal.count))
        let cardiacDetrended = cardiacSignal.map { $0 - cardiacMean }

        // EEG artifact rejection parameters
        let epochSamples = Int(2.0 * sfreq)  // 2-second epochs
        let artifactThreshold = Constants.eegArtifactThresholdUV

        // Process each EEG band (delta, theta, alpha)
        var perBand = [String: [String: Float]]()
        var overallByBand = [String: Float]()

        for band in Constants.heartBrainCoherenceBands {
            var perChannel = [String: Float]()
            var cohSum: Float = 0
            var cohCount = 0

            for (chIdx, channel) in eegChannels.enumerated() {
                guard chIdx < eegData.count else { continue }
                let rawChannel = eegData[chIdx]

                // --- Artifact rejection: reject 2s epochs with >100 µV peak-to-peak ---
                var cleanSegments = [Float]()
                var epochStart = 0
                while epochStart + epochSamples <= rawChannel.count {
                    let epoch = Array(rawChannel[epochStart..<epochStart + epochSamples])
                    var epochMin: Float = 0, epochMax: Float = 0
                    vDSP_minv(epoch, 1, &epochMin, vDSP_Length(epoch.count))
                    vDSP_maxv(epoch, 1, &epochMax, vDSP_Length(epoch.count))
                    let ptp = epochMax - epochMin
                    if ptp < artifactThreshold {
                        cleanSegments.append(contentsOf: epoch)
                    }
                    epochStart += epochSamples
                }
                guard cleanSegments.count >= epochSamples else { continue }

                // --- Bandpass into this EEG band ---
                let bandFiltered = SignalProcessor.bandpassFilter(
                    cleanSegments, sfreq: sfreq,
                    lowCut: band.low, highCut: band.high
                )

                // --- Compute windowed RMS envelope (~4 Hz output) ---
                let envelope = SignalProcessor.windowedRMSEnvelope(
                    bandFiltered, sfreq: sfreq,
                    windowSec: windowSec, stepSec: stepSec
                )
                guard envelope.count >= 32 else { continue }

                // Match lengths to cardiac signal
                let minLen = min(cardiacDetrended.count, envelope.count)
                let cardTrimmed = Array(cardiacDetrended.prefix(minLen))
                var envTrimmed = Array(envelope.prefix(minLen))

                // Detrend envelope
                var envMean: Float = 0
                vDSP_meanv(envTrimmed, 1, &envMean, vDSP_Length(envTrimmed.count))
                envTrimmed = envTrimmed.map { $0 - envMean }

                // --- Adaptive nperseg: prefer 128-256, fall back to 64 ---
                let nperseg: Int
                if minLen >= Constants.heartBrainCoherenceMaxNperseg {
                    nperseg = Constants.heartBrainCoherenceMaxNperseg
                } else if minLen >= Constants.heartBrainCoherenceMinNperseg {
                    nperseg = Constants.heartBrainCoherenceMinNperseg
                } else {
                    nperseg = min(64, minLen)  // fallback for very short recordings
                }
                let noverlap = nperseg / 2
                guard nperseg >= 8 else { continue }

                let (cohFreqs, coh) = SignalProcessor.coherence(
                    cardTrimmed, envTrimmed, sfreq: interpRate,
                    nperseg: nperseg, noverlap: noverlap
                )

                let bandCoh = SignalProcessor.bandCoherence(
                    coh, freqs: cohFreqs,
                    low: Constants.heartBrainCoherenceLFBand.low,
                    high: Constants.heartBrainCoherenceLFBand.high
                )

                perChannel[channel] = bandCoh
                cohSum += bandCoh
                cohCount += 1
            }

            perBand[band.name] = perChannel
            overallByBand[band.name] = cohCount > 0 ? cohSum / Float(cohCount) : 0
        }

        // Find best band (highest overall mean)
        let bestBand = overallByBand.max(by: { $0.value < $1.value })?.key ?? "Alpha"

        return CoherenceResult(
            perBand: perBand,
            overallByBand: overallByBand,
            bestBand: bestBand
        )
    }
}
