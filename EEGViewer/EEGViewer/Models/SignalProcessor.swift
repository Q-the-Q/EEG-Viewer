// SignalProcessor.swift
// Signal processing using Apple Accelerate framework (vDSP).
// Replaces scipy.signal operations: Welch PSD, Butterworth filtering, coherence.

import Foundation
import Accelerate

struct SignalProcessor {

    // MARK: - Average Reference

    /// Subtract the mean across channels at each time point.
    static func averageReference(_ data: [[Float]]) -> [[Float]] {
        let nChannels = data.count
        guard nChannels > 0 else { return data }
        let nSamples = data[0].count

        // Compute mean across channels for each sample
        var mean = [Float](repeating: 0, count: nSamples)
        for ch in 0..<nChannels {
            vDSP_vadd(mean, 1, data[ch], 1, &mean, 1, vDSP_Length(nSamples))
        }
        var divisor = Float(nChannels)
        vDSP_vsdiv(mean, 1, &divisor, &mean, 1, vDSP_Length(nSamples))

        // Subtract mean from each channel
        var result = data
        for ch in 0..<nChannels {
            vDSP_vsub(mean, 1, data[ch], 1, &result[ch], 1, vDSP_Length(nSamples))
        }
        return result
    }

    // MARK: - High-Pass Filter (Butterworth, order 4, zero-phase)

    /// Apply a zero-phase high-pass Butterworth filter.
    static func highpassFilter(_ signal: [Float], sfreq: Float, cutoff: Float) -> [Float] {
        let nyquist = sfreq / 2.0
        let normalizedCutoff = cutoff / nyquist

        // Design 2nd-order high-pass biquad sections (cascade 2 for 4th order)
        let sections = designHighpassBiquad(normalizedCutoff: Double(normalizedCutoff))

        // Forward pass
        var result = applyBiquadCascade(signal, sections: sections)
        // Reverse
        result.reverse()
        // Backward pass
        result = applyBiquadCascade(result, sections: sections)
        // Reverse again
        result.reverse()

        return result
    }

    /// Apply a zero-phase bandpass Butterworth filter.
    static func bandpassFilter(_ signal: [Float], sfreq: Float, lowCut: Float, highCut: Float) -> [Float] {
        // Implement as cascade of high-pass and low-pass
        let hp = highpassFilter(signal, sfreq: sfreq, cutoff: lowCut)
        return lowpassFilter(hp, sfreq: sfreq, cutoff: highCut)
    }

    /// Apply a zero-phase low-pass Butterworth filter.
    static func lowpassFilter(_ signal: [Float], sfreq: Float, cutoff: Float) -> [Float] {
        let nyquist = sfreq / 2.0
        let normalizedCutoff = cutoff / nyquist

        let sections = designLowpassBiquad(normalizedCutoff: Double(normalizedCutoff))

        var result = applyBiquadCascade(signal, sections: sections)
        result.reverse()
        result = applyBiquadCascade(result, sections: sections)
        result.reverse()

        return result
    }

    // MARK: - Welch PSD

    /// Compute Power Spectral Density using Welch's method.
    /// Returns (frequencies, psd) where psd is in V²/Hz.
    static func welchPSD(_ signal: [Float], sfreq: Float,
                         nperseg: Int = Constants.psdNperseg,
                         noverlap: Int = Constants.psdNoverlap) -> (freqs: [Float], psd: [Float]) {
        let nSamples = signal.count
        let step = nperseg - noverlap
        let nSegments = max(1, (nSamples - nperseg) / step + 1)

        // Hann window
        var window = [Float](repeating: 0, count: nperseg)
        vDSP_hann_window(&window, vDSP_Length(nperseg), Int32(vDSP_HANN_NORM))

        // Window power (for normalization)
        var windowPower: Float = 0
        vDSP_dotpr(window, 1, window, 1, &windowPower, vDSP_Length(nperseg))

        // FFT setup
        let log2n = vDSP_Length(log2(Float(nperseg)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ([], [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let nFreqs = nperseg / 2 + 1
        var avgPSD = [Float](repeating: 0, count: nFreqs)

        for seg in 0..<nSegments {
            let startIdx = seg * step
            let endIdx = startIdx + nperseg
            guard endIdx <= nSamples else { break }

            // Extract segment and apply window
            var windowed = [Float](repeating: 0, count: nperseg)
            vDSP_vmul(Array(signal[startIdx..<endIdx]), 1, window, 1, &windowed, 1, vDSP_Length(nperseg))

            // Remove DC (detrend="constant")
            var mean: Float = 0
            vDSP_meanv(windowed, 1, &mean, vDSP_Length(nperseg))
            mean = -mean
            vDSP_vsadd(windowed, 1, &mean, &windowed, 1, vDSP_Length(nperseg))

            // FFT (real-to-complex, in-place)
            var realPart = [Float](repeating: 0, count: nperseg / 2)
            var imagPart = [Float](repeating: 0, count: nperseg / 2)

            // Pack into split complex
            windowed.withUnsafeBufferPointer { buf in
                buf.baseAddress!.withMemoryRebound(to: Float.self, capacity: nperseg) { ptr in
                    var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                    vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(ptr)), 2,
                              &splitComplex, 1, vDSP_Length(nperseg / 2))
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Compute magnitude squared
            var magnitudes = [Float](repeating: 0, count: nFreqs)

            // DC component
            magnitudes[0] = realPart[0] * realPart[0]
            // Nyquist
            magnitudes[nFreqs - 1] = imagPart[0] * imagPart[0]
            // Other bins
            for k in 1..<(nFreqs - 1) {
                magnitudes[k] = realPart[k] * realPart[k] + imagPart[k] * imagPart[k]
            }

            // Scale: multiply by 2 for one-sided (except DC and Nyquist)
            for k in 1..<(nFreqs - 1) {
                magnitudes[k] *= 2.0
            }

            // Accumulate
            vDSP_vadd(avgPSD, 1, magnitudes, 1, &avgPSD, 1, vDSP_Length(nFreqs))
        }

        // Average and normalize to V²/Hz
        let actualSegments = Float(nSegments)
        let scale = 1.0 / (actualSegments * sfreq * windowPower)
        var scaledPSD = [Float](repeating: 0, count: nFreqs)
        var s = scale
        vDSP_vsmul(avgPSD, 1, &s, &scaledPSD, 1, vDSP_Length(nFreqs))

        // Frequency axis
        var freqs = [Float](repeating: 0, count: nFreqs)
        let freqStep = sfreq / Float(nperseg)
        for i in 0..<nFreqs {
            freqs[i] = Float(i) * freqStep
        }

        return (freqs, scaledPSD)
    }

    // MARK: - Band Power (Trapezoidal Integration)

    /// Compute absolute band power by integrating PSD over frequency range.
    static func bandPower(_ psd: [Float], freqs: [Float], low: Float, high: Float) -> Float {
        var power: Float = 0
        for i in 1..<freqs.count {
            if freqs[i] >= low && freqs[i - 1] <= high {
                let fLow = max(freqs[i - 1], low)
                let fHigh = min(freqs[i], high)
                let df = fHigh - fLow
                if df > 0 {
                    power += (psd[i - 1] + psd[i]) / 2.0 * df
                }
            }
        }
        return power
    }

    /// Compute relative band power (band / total).
    static func relativePower(_ psd: [Float], freqs: [Float], low: Float, high: Float) -> Float {
        let bp = bandPower(psd, freqs: freqs, low: low, high: high)
        let total = bandPower(psd, freqs: freqs,
                              low: Constants.totalPowerRange.low,
                              high: Constants.totalPowerRange.high)
        return total > 0 ? bp / total : 0
    }

    // MARK: - Artifact Rejection

    struct ArtifactStats {
        let totalEpochs: Int
        let cleanEpochs: Int
        let rejectedEpochs: Int
        let thresholdUV: Float
    }

    /// Reject epochs where any channel exceeds peak-to-peak threshold.
    /// Returns (clean data concatenated, stats).
    static func rejectArtifacts(_ data: [[Float]], sfreq: Float,
                                thresholdUV: Float = Constants.artifactThresholdUV) -> ([[Float]], ArtifactStats) {
        let nChannels = data.count
        guard nChannels > 0 else {
            return (data, ArtifactStats(totalEpochs: 0, cleanEpochs: 0, rejectedEpochs: 0, thresholdUV: thresholdUV))
        }
        let nSamples = data[0].count
        let epochSamples = Int(Constants.epochDuration * sfreq)
        let nEpochs = nSamples / epochSamples

        let thresholdV = thresholdUV * 1e-6  // Convert µV threshold to V

        var cleanIndices = [Int]()
        var currentThreshold = thresholdV

        // Try progressively relaxed thresholds if needed
        let thresholds: [Float] = [thresholdV, 150e-6, 200e-6, 300e-6, 500e-6]

        for thresh in thresholds {
            cleanIndices = []
            for epoch in 0..<nEpochs {
                let start = epoch * epochSamples
                let end = start + epochSamples
                var isClean = true

                for ch in 0..<nChannels {
                    let segment = Array(data[ch][start..<end])
                    var minVal: Float = 0
                    var maxVal: Float = 0
                    vDSP_minv(segment, 1, &minVal, vDSP_Length(epochSamples))
                    vDSP_maxv(segment, 1, &maxVal, vDSP_Length(epochSamples))
                    let ptp = maxVal - minVal
                    if ptp > thresh {
                        isClean = false
                        break
                    }
                }
                if isClean { cleanIndices.append(epoch) }
            }
            currentThreshold = thresh
            if cleanIndices.count >= Constants.minCleanEpochs { break }
        }

        // If still not enough, use all epochs
        if cleanIndices.count < Constants.minCleanEpochs {
            cleanIndices = Array(0..<nEpochs)
        }

        // Concatenate clean epochs
        let cleanSamples = cleanIndices.count * epochSamples
        var cleanData = [[Float]](repeating: [Float](repeating: 0, count: cleanSamples), count: nChannels)

        for (outIdx, epochIdx) in cleanIndices.enumerated() {
            let srcStart = epochIdx * epochSamples
            let dstStart = outIdx * epochSamples
            for ch in 0..<nChannels {
                cleanData[ch].replaceSubrange(dstStart..<dstStart + epochSamples,
                                              with: data[ch][srcStart..<srcStart + epochSamples])
            }
        }

        let stats = ArtifactStats(
            totalEpochs: nEpochs,
            cleanEpochs: cleanIndices.count,
            rejectedEpochs: nEpochs - cleanIndices.count,
            thresholdUV: currentThreshold * 1e6
        )

        return (cleanData, stats)
    }

    // MARK: - Z-Scores (Within-Subject)

    /// Compute within-subject Z-scores: (value - mean) / std across channels.
    static func zscoresWithin(_ values: [Float]) -> [Float] {
        guard values.count > 1 else { return values.map { _ in 0 } }
        var mean: Float = 0
        var std: Float = 0
        vDSP_normalize(values, 1, nil, 1, &mean, &std, vDSP_Length(values.count))

        if std < 1e-10 { return values.map { _ in 0 } }

        var result = [Float](repeating: 0, count: values.count)
        var negMean = -mean
        vDSP_vsadd(values, 1, &negMean, &result, 1, vDSP_Length(values.count))
        var invStd = 1.0 / std
        vDSP_vsmul(result, 1, &invStd, &result, 1, vDSP_Length(values.count))

        return result
    }

    // MARK: - Global Field Power

    /// Compute GFP (std across channels) at each time point.
    /// Vectorized: computes mean across channels, then sum of squared deviations, per sample.
    static func globalFieldPower(_ data: [[Float]]) -> [Float] {
        let nChannels = data.count
        guard nChannels > 1 else { return data.first ?? [] }
        let nSamples = data[0].count
        let n = vDSP_Length(nSamples)
        let fChannels = Float(nChannels)

        // Step 1: Compute mean across channels at each time point (vectorized)
        var mean = [Float](repeating: 0, count: nSamples)
        for ch in 0..<nChannels {
            vDSP_vadd(mean, 1, data[ch], 1, &mean, 1, n)
        }
        var divisor = fChannels
        vDSP_vsdiv(mean, 1, &divisor, &mean, 1, n)

        // Step 2: Accumulate squared deviations from mean (vectorized)
        var sumSqDev = [Float](repeating: 0, count: nSamples)
        var temp = [Float](repeating: 0, count: nSamples)
        for ch in 0..<nChannels {
            // temp = data[ch] - mean
            vDSP_vsub(mean, 1, data[ch], 1, &temp, 1, n)
            // temp = temp * temp
            vDSP_vmul(temp, 1, temp, 1, &temp, 1, n)
            // sumSqDev += temp
            vDSP_vadd(sumSqDev, 1, temp, 1, &sumSqDev, 1, n)
        }

        // Step 3: variance = sumSqDev / nChannels, gfp = sqrt(variance)
        var gfp = [Float](repeating: 0, count: nSamples)
        vDSP_vsdiv(sumSqDev, 1, &divisor, &gfp, 1, n)
        var count = Int32(nSamples)
        vvsqrtf(&gfp, gfp, &count)

        return gfp
    }

    // MARK: - Coherence

    /// Compute coherence between two signals using Welch-based cross-spectral density.
    static func coherence(_ signal1: [Float], _ signal2: [Float], sfreq: Float,
                          nperseg: Int = Constants.psdNperseg,
                          noverlap: Int = Constants.psdNoverlap) -> (freqs: [Float], coh: [Float]) {
        let nSamples = min(signal1.count, signal2.count)
        let step = nperseg - noverlap
        let nSegments = max(1, (nSamples - nperseg) / step + 1)

        var window = [Float](repeating: 0, count: nperseg)
        vDSP_hann_window(&window, vDSP_Length(nperseg), Int32(vDSP_HANN_NORM))

        let log2n = vDSP_Length(log2(Float(nperseg)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ([], [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let nFreqs = nperseg / 2 + 1

        // Accumulators for auto and cross spectra
        var pxx = [Float](repeating: 0, count: nFreqs)
        var pyy = [Float](repeating: 0, count: nFreqs)
        var pxyReal = [Float](repeating: 0, count: nFreqs)
        var pxyImag = [Float](repeating: 0, count: nFreqs)

        for seg in 0..<nSegments {
            let startIdx = seg * step
            let endIdx = startIdx + nperseg
            guard endIdx <= nSamples else { break }

            // Window both signals
            var w1 = [Float](repeating: 0, count: nperseg)
            var w2 = [Float](repeating: 0, count: nperseg)
            vDSP_vmul(Array(signal1[startIdx..<endIdx]), 1, window, 1, &w1, 1, vDSP_Length(nperseg))
            vDSP_vmul(Array(signal2[startIdx..<endIdx]), 1, window, 1, &w2, 1, vDSP_Length(nperseg))

            // FFT both
            let (r1, i1) = fftReal(w1, setup: fftSetup, log2n: log2n)
            let (r2, i2) = fftReal(w2, setup: fftSetup, log2n: log2n)

            // Accumulate auto and cross spectra
            for k in 0..<nFreqs {
                let re1 = k < r1.count ? r1[k] : 0
                let im1 = k < i1.count ? i1[k] : 0
                let re2 = k < r2.count ? r2[k] : 0
                let im2 = k < i2.count ? i2[k] : 0

                pxx[k] += re1 * re1 + im1 * im1
                pyy[k] += re2 * re2 + im2 * im2
                // Cross: X * conj(Y)
                pxyReal[k] += re1 * re2 + im1 * im2
                pxyImag[k] += im1 * re2 - re1 * im2
            }
        }

        // Coherence = |Pxy|² / (Pxx * Pyy)
        var coh = [Float](repeating: 0, count: nFreqs)
        for k in 0..<nFreqs {
            let crossMag2 = pxyReal[k] * pxyReal[k] + pxyImag[k] * pxyImag[k]
            let denom = pxx[k] * pyy[k]
            coh[k] = denom > 0 ? crossMag2 / denom : 0
        }

        var freqs = [Float](repeating: 0, count: nFreqs)
        let freqStep = sfreq / Float(nperseg)
        for i in 0..<nFreqs { freqs[i] = Float(i) * freqStep }

        return (freqs, coh)
    }

    /// Average coherence within a frequency band.
    static func bandCoherence(_ coh: [Float], freqs: [Float], low: Float, high: Float) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for i in 0..<freqs.count {
            if freqs[i] >= low && freqs[i] <= high {
                sum += coh[i]
                count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }

    // MARK: - Spectrogram

    struct SpectrogramResult {
        let frequencies: [Float]
        let times: [Float]
        let power: [[Float]]  // [freq][time] in dB
    }

    /// Compute spectrogram of a signal.
    static func spectrogram(_ signal: [Float], sfreq: Float,
                            nperseg: Int = Constants.spectrogramNperseg,
                            noverlap: Int = Constants.spectrogramNoverlap) -> SpectrogramResult {
        let nSamples = signal.count
        let step = nperseg - noverlap
        let nSegments = max(1, (nSamples - nperseg) / step + 1)
        let nFreqs = nperseg / 2 + 1

        var window = [Float](repeating: 0, count: nperseg)
        vDSP_hann_window(&window, vDSP_Length(nperseg), Int32(vDSP_HANN_NORM))

        var windowPower: Float = 0
        vDSP_dotpr(window, 1, window, 1, &windowPower, vDSP_Length(nperseg))

        let log2n = vDSP_Length(log2(Float(nperseg)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return SpectrogramResult(frequencies: [], times: [], power: [])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var powerMatrix = [[Float]](repeating: [Float](repeating: 0, count: nSegments), count: nFreqs)
        var times = [Float](repeating: 0, count: nSegments)

        for seg in 0..<nSegments {
            let startIdx = seg * step
            let endIdx = startIdx + nperseg
            guard endIdx <= nSamples else { break }

            var windowed = [Float](repeating: 0, count: nperseg)
            vDSP_vmul(Array(signal[startIdx..<endIdx]), 1, window, 1, &windowed, 1, vDSP_Length(nperseg))

            let (realPart, imagPart) = fftReal(windowed, setup: fftSetup, log2n: log2n)

            // Power in dB
            let scale = 1.0 / (sfreq * windowPower)
            for k in 0..<nFreqs {
                let re = k < realPart.count ? realPart[k] : 0
                let im = k < imagPart.count ? imagPart[k] : 0
                var mag2 = (re * re + im * im) * scale
                if k > 0 && k < nFreqs - 1 { mag2 *= 2.0 }
                powerMatrix[k][seg] = 10.0 * log10f(mag2 + 1e-20)
            }

            times[seg] = (Float(startIdx) + Float(nperseg) / 2.0) / sfreq
        }

        var freqs = [Float](repeating: 0, count: nFreqs)
        let freqStep = sfreq / Float(nperseg)
        for i in 0..<nFreqs { freqs[i] = Float(i) * freqStep }

        return SpectrogramResult(frequencies: freqs, times: times, power: powerMatrix)
    }

    // MARK: - FFT Helper

    private static func fftReal(_ input: [Float], setup: FFTSetup, log2n: vDSP_Length) -> (real: [Float], imag: [Float]) {
        let n = input.count
        let halfN = n / 2

        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)

        input.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: Float.self, capacity: n) { ptr in
                var split = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(ptr)), 2,
                          &split, 1, vDSP_Length(halfN))
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Unpack: DC is in realPart[0], Nyquist is in imagPart[0]
        var fullReal = [Float](repeating: 0, count: halfN + 1)
        var fullImag = [Float](repeating: 0, count: halfN + 1)

        fullReal[0] = realPart[0]  // DC
        fullImag[0] = 0
        fullReal[halfN] = imagPart[0]  // Nyquist
        fullImag[halfN] = 0

        for k in 1..<halfN {
            fullReal[k] = realPart[k]
            fullImag[k] = imagPart[k]
        }

        return (fullReal, fullImag)
    }

    // MARK: - Biquad Filter Design

    /// Design a 2nd-order high-pass biquad (Butterworth approximation).
    /// Two sections cascaded gives 4th order.
    private static func designHighpassBiquad(normalizedCutoff: Double) -> [[Double]] {
        let omega = Double.pi * normalizedCutoff
        let sn = sin(omega)
        let cs = cos(omega)
        let alpha = sn / (2.0 * sqrt(2.0))  // Q = sqrt(2)/2 for Butterworth

        // High-pass coefficients
        let b0 = (1.0 + cs) / 2.0
        let b1 = -(1.0 + cs)
        let b2 = (1.0 + cs) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cs
        let a2 = 1.0 - alpha

        // Normalize
        let section = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        // Cascade two sections for 4th order
        return [section, section]
    }

    /// Design a 2nd-order low-pass biquad (Butterworth approximation).
    private static func designLowpassBiquad(normalizedCutoff: Double) -> [[Double]] {
        let omega = Double.pi * normalizedCutoff
        let sn = sin(omega)
        let cs = cos(omega)
        let alpha = sn / (2.0 * sqrt(2.0))

        let b0 = (1.0 - cs) / 2.0
        let b1 = 1.0 - cs
        let b2 = (1.0 - cs) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cs
        let a2 = 1.0 - alpha

        let section = [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
        return [section, section]
    }

    /// Apply a cascade of biquad sections to a signal.
    private static func applyBiquadCascade(_ signal: [Float], sections: [[Double]]) -> [Float] {
        var result = signal
        for section in sections {
            result = applyBiquadVDSP(result, coeffs: section)
        }
        return result
    }

    /// Apply a single biquad section using vDSP_deq22 (hardware-optimized).
    /// vDSP_deq22 coefficients: [b0, b1, b2, a1, a2] where:
    ///   A[n] = b0*X[n] + b1*X[n-1] + b2*X[n-2] - a1*A[n-1] - a2*A[n-2]
    private static func applyBiquadVDSP(_ signal: [Float], coeffs: [Double]) -> [Float] {
        let n = signal.count
        guard n > 2 else { return signal }

        // vDSP_deq22 expects 5 coefficients: [b0, b1, b2, a1, a2]
        var c: [Float] = coeffs.map { Float($0) }

        // Prepend two zeros to input (vDSP_deq22 needs x[n-1], x[n-2] before first sample)
        var input = [Float](repeating: 0, count: n + 2)
        input.replaceSubrange(2..<n+2, with: signal)

        var output = [Float](repeating: 0, count: n + 2)

        vDSP_deq22(&input, 1, &c, &output, 1, vDSP_Length(n))

        return Array(output[2..<n+2])
    }

    // MARK: - Decimation

    /// Decimate a signal by factor (anti-alias LP filter + downsample).
    /// Useful for reducing computation before band-limited analysis.
    static func decimate(_ signal: [Float], factor: Int, sfreq: Float) -> [Float] {
        guard factor > 1 else { return signal }
        // Anti-alias: low-pass at new Nyquist (sfreq/factor/2)
        let cutoff = sfreq / Float(factor) / 2.0 * 0.9  // 90% of new Nyquist
        let filtered = lowpassFilter(signal, sfreq: sfreq, cutoff: cutoff)
        // Downsample by taking every Nth sample
        let n = filtered.count / factor
        var result = [Float](repeating: 0, count: n)
        for i in 0..<n {
            result[i] = filtered[i * factor]
        }
        return result
    }
}
