// BandPowerView.swift
// Band-filtered Global Field Power waveforms and spectrogram.
// Shows Delta, Theta, Alpha, Beta GFP traces (std across channels after bandpass filtering).

import SwiftUI
import Combine

struct BandPowerView: View {
    let edfData: EDFData

    @State private var bandTraces: [(name: String, color: Color, data: [Float])] = []
    @State private var spectrogramData: SignalProcessor.SpectrogramResult?
    @State private var isProcessing = true
    @State private var currentTime: Float = 0
    @State private var windowSec: Float = Constants.defaultWindowSec
    @State private var amplitudeScale: Float = 1.0
    @State private var isPlaying = false
    @State private var speed: Float = 1.0
    @State private var timer: AnyCancellable?

    var body: some View {
        VStack(spacing: 0) {
            if isProcessing {
                ProgressView("Processing band filters...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Top: Band GFP traces
                Canvas { context, size in
                    drawBandTraces(context: context, size: size)
                }
                .frame(maxHeight: .infinity)

                Divider()

                // Bottom: Spectrogram
                Canvas { context, size in
                    drawSpectrogram(context: context, size: size)
                }
                .frame(height: 200)

                Divider()

                // Controls
                controlsBar
            }
        }
        .task {
            await processData()
        }
        .onDisappear {
            timer?.cancel()
        }
    }

    // MARK: - Controls

    private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32)
                }

                VStack(spacing: 2) {
                    Text("Speed: \(speed, specifier: "%.1f")x")
                        .font(.caption2)
                    Slider(value: $speed, in: 0.5...4.0, step: 0.5)
                        .frame(width: 80)
                }

                VStack(spacing: 2) {
                    let curMin = Int(currentTime) / 60
                    let curSec = Int(currentTime) % 60
                    let totMin = Int(edfData.duration) / 60
                    let totSec = Int(edfData.duration) % 60
                    Text(String(format: "%02d:%02d / %02d:%02d", curMin, curSec, totMin, totSec))
                        .font(.caption2.monospacedDigit())
                    Slider(value: $currentTime, in: 0...max(0.01, edfData.duration - windowSec))
                        .frame(minWidth: 200)
                }

                VStack(spacing: 2) {
                    Text("Scale: \(amplitudeScale, specifier: "%.1f")x")
                        .font(.caption2)
                    Slider(value: $amplitudeScale, in: 0.1...5.0)
                        .frame(width: 100)
                }

                Picker("Window", selection: $windowSec) {
                    ForEach(Constants.windowSizeOptions, id: \.self) { ws in
                        Text("\(Int(ws))s").tag(ws)
                    }
                }
                .pickerStyle(.menu)

                // Legend
                HStack(spacing: 8) {
                    ForEach(bandTraces, id: \.name) { trace in
                        HStack(spacing: 4) {
                            Circle().fill(trace.color).frame(width: 8, height: 8)
                            Text(trace.name).font(.caption2)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Data Processing

    private func processData() async {
        isProcessing = true

        let eegData = edfData.eegData
        let sfreq = edfData.sfreq

        // Preprocess
        let referenced = SignalProcessor.averageReference(eegData)
        let filtered = referenced.map { SignalProcessor.highpassFilter($0, sfreq: sfreq, cutoff: 1.0) }

        // Compute band GFP traces
        var traces = [(name: String, color: Color, data: [Float])]()

        for band in Constants.freqBands {
            let bandFiltered = filtered.map {
                SignalProcessor.bandpassFilter($0, sfreq: sfreq, lowCut: band.low, highCut: band.high)
            }
            let gfp = SignalProcessor.globalFieldPower(bandFiltered)
            // Convert to µV
            let gfpUV = gfp.map { $0 * 1e6 }
            traces.append((name: band.name, color: band.color, data: gfpUV))
        }

        // Compute spectrogram on GFP signal
        let gfpSignal = SignalProcessor.globalFieldPower(filtered)
        let specResult = SignalProcessor.spectrogram(gfpSignal, sfreq: sfreq)

        await MainActor.run {
            self.bandTraces = traces
            self.spectrogramData = specResult
            self.isProcessing = false
        }
    }

    // MARK: - Drawing Band Traces

    private func drawBandTraces(context: GraphicsContext, size: CGSize) {
        guard !bandTraces.isEmpty else { return }

        let sfreq = edfData.sfreq
        let startSample = Int(currentTime * sfreq)
        let windowSamples = Int(windowSec * sfreq)

        let maxPoints = 2000
        let bandSpacing: Float = 50.0  // µV between bands
        let nBands = bandTraces.count
        let totalHeight = Float(nBands) * bandSpacing
        let yScale = Float(size.height) / totalHeight * amplitudeScale

        // Grid
        var gridPath = Path()
        let pixelsPerSec = size.width / CGFloat(windowSec)
        var gridSec = ceil(Double(currentTime))
        while Float(gridSec) < currentTime + windowSec {
            let x = CGFloat(Float(gridSec) - currentTime) * pixelsPerSec
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            gridSec += 1
        }
        context.stroke(gridPath, with: .color(.gray.opacity(0.15)), lineWidth: 0.5)

        for (idx, trace) in bandTraces.enumerated() {
            let centerY = CGFloat((Float(idx) + 0.5) * bandSpacing * yScale)

            // Label
            context.draw(
                Text(trace.name).font(.system(size: 10, weight: .medium)),
                at: CGPoint(x: 30, y: centerY),
                anchor: .leading
            )

            // Zero line
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: centerY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(zeroPath, with: .color(.gray.opacity(0.1)), lineWidth: 0.5)

            // Trace
            let data = trace.data
            let endSample = min(startSample + windowSamples, data.count)
            guard endSample > startSample else { continue }

            let actualSamples = endSample - startSample
            let step = max(1, actualSamples / maxPoints)
            let nPoints = actualSamples / step
            let xStep = size.width / CGFloat(nPoints)

            var path = Path()
            for p in 0..<nPoints {
                let sampleIdx = startSample + p * step
                guard sampleIdx < data.count else { break }

                let value = CGFloat(data[sampleIdx])
                let x = CGFloat(p) * xStep
                let y = centerY - value * CGFloat(yScale) * 0.5

                if p == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(trace.color), lineWidth: 1.0)
        }
    }

    // MARK: - Drawing Spectrogram

    private func drawSpectrogram(context: GraphicsContext, size: CGSize) {
        guard let spec = spectrogramData, !spec.times.isEmpty, !spec.frequencies.isEmpty else { return }

        let maxFreq: Float = 30.0
        let freqIndices = spec.frequencies.enumerated().filter { $0.element <= maxFreq }
        guard let lastFreqIdx = freqIndices.last?.offset else { return }

        // Find min/max for color scaling (5th-95th percentile)
        var allValues = [Float]()
        for fi in 0...lastFreqIdx {
            allValues.append(contentsOf: spec.power[fi])
        }
        allValues.sort()
        let vmin = allValues[Int(Float(allValues.count) * 0.05)]
        let vmax = allValues[Int(Float(allValues.count) * 0.95)]

        // Find time range
        let startTime = currentTime
        let endTime = currentTime + windowSec
        let timeIndices = spec.times.enumerated().filter { $0.element >= startTime && $0.element <= endTime }
        guard !timeIndices.isEmpty else { return }

        let pixelWidth = max(1, size.width / CGFloat(timeIndices.count))
        let pixelHeight = max(1, size.height / CGFloat(lastFreqIdx + 1))

        for (colIdx, (tIdx, _)) in timeIndices.enumerated() {
            for fi in 0...lastFreqIdx {
                let value = spec.power[fi][tIdx]
                let normalized = (value - vmin) / (vmax - vmin)
                let color = ColorMap.viridis(at: max(0, min(1, normalized)))

                let x = CGFloat(colIdx) * pixelWidth
                let y = size.height - CGFloat(fi + 1) * pixelHeight  // Flip Y (low freq at bottom)

                context.fill(
                    Path(CGRect(x: x, y: y, width: pixelWidth + 1, height: pixelHeight + 1)),
                    with: .color(color)
                )
            }
        }

        // Band boundary lines
        let bandBoundaries: [Float] = [1, 4, 8, 13, 25]
        for freq in bandBoundaries {
            let y = size.height * (1.0 - CGFloat(freq / maxFreq))
            var linePath = Path()
            linePath.move(to: CGPoint(x: 0, y: y))
            linePath.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(linePath, with: .color(.white.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }

        // Frequency labels
        for freq in bandBoundaries {
            let y = size.height * (1.0 - CGFloat(freq / maxFreq))
            context.draw(
                Text("\(Int(freq)) Hz").font(.system(size: 8)).foregroundColor(.white),
                at: CGPoint(x: size.width - 25, y: y),
                anchor: .trailing
            )
        }
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            timer?.cancel()
            timer = nil
        } else {
            isPlaying = true
            timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    currentTime += Float(1.0 / 30.0) * speed
                    if currentTime >= edfData.duration - windowSec {
                        currentTime = 0
                    }
                }
        }
    }
}
