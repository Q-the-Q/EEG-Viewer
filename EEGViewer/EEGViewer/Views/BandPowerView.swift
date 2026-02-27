// BandPowerView.swift
// Band-filtered Global Field Power waveforms and spectrogram.
// Shows Delta, Theta, Alpha, Beta GFP traces (std across channels after bandpass filtering).

import SwiftUI
import Combine

struct BandPowerView: View {
    let edfData: EDFData

    @State private var bandTraces: [(name: String, color: Color, data: [Float])] = []
    @State private var spectrogramData: SignalProcessor.SpectrogramResult?
    @State private var decimatedSfreq: Float = 50.0
    @State private var spectrogramImage: CGImage?
    @State private var isProcessing = true
    @State private var currentTime: Float = 0
    @State private var windowSec: Float = Constants.defaultWindowSec
    @State private var amplitudeScale: Float = 1.0
    @State private var isPlaying = false
    @State private var speed: Float = 1.0
    @State private var timer: AnyCancellable?
    @GestureState private var dragStartTime: Float?

    private let spectrogramMaxFreq: Float = 50.0

    var body: some View {
        VStack(spacing: 0) {
            if isProcessing {
                ProgressView("Processing band filters...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .foregroundColor(.white)
            } else {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // Top: Band GFP traces
                        Canvas { context, size in
                            drawBandTraces(context: context, size: size)
                        }
                        .frame(height: 200)

                        // Subtle separator
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 1)

                        // Main: Spectrogram (fills remaining space)
                        Canvas { context, size in
                            drawSpectrogram(context: context, size: size)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    .gesture(
                        DragGesture()
                            .updating($dragStartTime) { _, state, _ in
                                if state == nil { state = currentTime }
                            }
                            .onChanged { value in
                                if let startTime = dragStartTime {
                                    let dt = Float(value.translation.width) / Float(geo.size.width) * windowSec
                                    currentTime = max(0, min(edfData.duration - windowSec, startTime - dt))
                                }
                            }
                    )
                }

                // Controls
                controlsBar
            }
        }
        .background(Color.black)
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
                        .foregroundColor(.white)
                        .frame(width: 32)
                }

                VStack(spacing: 2) {
                    Text("Speed: \(speed, specifier: "%.1f")x")
                        .font(.caption2).foregroundColor(.gray)
                    Slider(value: $speed, in: 0.5...4.0, step: 0.5)
                        .frame(width: 80)
                        .tint(.blue)
                }

                VStack(spacing: 2) {
                    let curMin = Int(currentTime) / 60
                    let curSec = Int(currentTime) % 60
                    let totMin = Int(edfData.duration) / 60
                    let totSec = Int(edfData.duration) % 60
                    Text(String(format: "%02d:%02d / %02d:%02d", curMin, curSec, totMin, totSec))
                        .font(.caption2.monospacedDigit()).foregroundColor(.gray)
                    Slider(value: $currentTime, in: 0...max(0.01, edfData.duration - windowSec))
                        .frame(minWidth: 200)
                        .tint(.blue)
                }

                VStack(spacing: 2) {
                    Text("Scale: \(amplitudeScale, specifier: "%.1f")x")
                        .font(.caption2).foregroundColor(.gray)
                    Slider(value: $amplitudeScale, in: 0.1...5.0)
                        .frame(width: 100)
                        .tint(.blue)
                }

                Picker("Window", selection: $windowSec) {
                    ForEach(Constants.windowSizeOptions, id: \.self) { ws in
                        Text("\(Int(ws))s").tag(ws)
                    }
                }
                .pickerStyle(.menu)
                .tint(.blue)

                // Legend
                HStack(spacing: 8) {
                    ForEach(bandTraces, id: \.name) { trace in
                        HStack(spacing: 4) {
                            Circle().fill(trace.color).frame(width: 8, height: 8)
                            Text(trace.name).font(.caption2).foregroundColor(.gray)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.10))
    }

    // MARK: - Data Processing

    private func processData() async {
        isProcessing = true

        let eegData = edfData.eegData
        let sfreq = edfData.sfreq

        let (traces, specResult, processedSfreq, specImg) = await Task.detached(priority: .userInitiated) {
            let referenced = SignalProcessor.averageReference(eegData)
            let filtered = referenced.map { SignalProcessor.highpassFilter($0, sfreq: sfreq, cutoff: 1.0) }

            // Decimate to 50 Hz for band analysis (1-25 Hz range)
            let decimFactor = max(1, Int(sfreq / 50.0))
            let decimSfreq = sfreq / Float(decimFactor)
            let decimated = filtered.map { SignalProcessor.decimate($0, factor: decimFactor, sfreq: sfreq) }

            // Compute band GFP traces on decimated data
            var bandNames = [String]()
            var bandData = [[Float]]()

            for band in Constants.freqBands {
                let bandFiltered = decimated.map {
                    SignalProcessor.bandpassFilter($0, sfreq: decimSfreq, lowCut: band.low, highCut: band.high)
                }
                let gfp = SignalProcessor.globalFieldPower(bandFiltered)
                let gfpUV = gfp.map { $0 * 1e6 }
                bandNames.append(band.name)
                bandData.append(gfpUV)
            }

            // Spectrogram on higher-rate data for wider frequency range (0-50 Hz)
            // Decimate to ~128 Hz (Nyquist = 64 Hz, supports 50 Hz display)
            let specDecimFactor = max(1, Int(sfreq / 128.0))
            let specDecimSfreq = sfreq / Float(specDecimFactor)
            let specDecimated = filtered.map { SignalProcessor.decimate($0, factor: specDecimFactor, sfreq: sfreq) }

            let specGfp = SignalProcessor.globalFieldPower(specDecimated)
            let specNperseg = min(256, specGfp.count / 4)
            let specNoverlap = specNperseg - max(4, specNperseg / 16)  // ~94% overlap
            let spec = SignalProcessor.spectrogram(specGfp, sfreq: specDecimSfreq,
                                                    nperseg: specNperseg,
                                                    noverlap: specNoverlap)

            let specImage = BandPowerView.renderSpectrogramImage(spec: spec, maxFreq: 50.0)

            return (zip(bandNames, bandData).map { ($0, $1) }, spec, decimSfreq, specImage)
        }.value

        var fullTraces = [(name: String, color: Color, data: [Float])]()
        for (i, band) in Constants.freqBands.enumerated() {
            if i < traces.count {
                fullTraces.append((name: traces[i].0, color: band.color, data: traces[i].1))
            }
        }

        self.bandTraces = fullTraces
        self.spectrogramData = specResult
        self.decimatedSfreq = processedSfreq
        self.spectrogramImage = specImg
        self.isProcessing = false
    }

    // MARK: - Drawing Band Traces

    private func drawBandTraces(context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        guard !bandTraces.isEmpty else { return }

        let sfreq = decimatedSfreq
        let startSample = Int(currentTime * sfreq)
        let windowSamples = Int(windowSec * sfreq)

        let maxPoints = 2000
        let nBands = bandTraces.count
        let laneHeight = Float(size.height) / Float(nBands)

        // Grid (subtle on dark)
        var gridPath = Path()
        let pixelsPerSec = size.width / CGFloat(windowSec)
        var gridSec = ceil(Double(currentTime))
        while Float(gridSec) < currentTime + windowSec {
            let x = CGFloat(Float(gridSec) - currentTime) * pixelsPerSec
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            gridSec += 1
        }
        context.stroke(gridPath, with: .color(.white.opacity(0.06)), lineWidth: 0.5)

        for (idx, trace) in bandTraces.enumerated() {
            let centerY = CGFloat((Float(idx) + 0.5) * laneHeight)

            // Label (white for dark bg)
            context.draw(
                Text(trace.name).font(.system(size: 10, weight: .medium)).foregroundColor(.white),
                at: CGPoint(x: 30, y: centerY),
                anchor: .leading
            )

            // Zero line
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: centerY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(zeroPath, with: .color(.white.opacity(0.05)), lineWidth: 0.5)

            // Trace — auto-scale each band to fit its lane
            let data = trace.data
            let endSample = min(startSample + windowSamples, data.count)
            guard endSample > startSample else { continue }

            // Find max amplitude in the visible window for this band
            let visibleSlice = data[startSample..<endSample]
            let peakAmp = visibleSlice.map { abs($0) }.max() ?? 1.0
            let bandScale = peakAmp > 0 ? (laneHeight * 0.4 * amplitudeScale) / peakAmp : 1.0

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
                let y = centerY - value * CGFloat(bandScale)

                if p == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(trace.color), lineWidth: 1.5)
        }
    }

    // MARK: - Drawing Spectrogram

    private func drawSpectrogram(context: GraphicsContext, size: CGSize) {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

        guard let image = spectrogramImage, let spec = spectrogramData,
              !spec.times.isEmpty, !spec.frequencies.isEmpty else { return }

        let maxFreq = spectrogramMaxFreq
        let leftMargin: CGFloat = 36
        let bottomMargin: CGFloat = 18
        let plotWidth = size.width - leftMargin
        let plotHeight = size.height - bottomMargin

        let freqIndices = spec.frequencies.enumerated().filter { $0.element <= maxFreq }
        guard let lastFreqIdx = freqIndices.last?.offset else { return }
        let actualMaxFreq = spec.frequencies[lastFreqIdx]

        // Use the actual frequency ceiling for all axis calculations so
        // labels, band boundaries, and the image stay aligned
        let displayMaxFreq = actualMaxFreq

        // Find time column indices for the current window
        var startCol = 0
        var endCol = spec.times.count - 1
        for (i, t) in spec.times.enumerated() {
            if t <= currentTime { startCol = i }
            if t <= currentTime + windowSec { endCol = i }
        }

        let cropWidth = max(1, endCol - startCol + 1)

        // Crop the pre-rendered CGImage to current time window
        if let cropped = image.cropping(to: CGRect(x: startCol, y: 0,
                                                    width: cropWidth, height: image.height)) {
            context.draw(
                Image(decorative: cropped, scale: 1.0),
                in: CGRect(x: leftMargin, y: 0, width: plotWidth, height: plotHeight)
            )
        }

        // Band boundary overlay lines (dashed white)
        let bandBoundaries: [Float] = [4, 8, 13, 25]
        for freq in bandBoundaries {
            if freq > displayMaxFreq { continue }
            let y = plotHeight * (1.0 - CGFloat(freq / displayMaxFreq))
            var linePath = Path()
            linePath.move(to: CGPoint(x: leftMargin, y: y))
            linePath.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(linePath, with: .color(.white.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        }

        // Frequency axis labels (left side)
        let freqLabels: [Float] = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50]
        for freq in freqLabels {
            if freq > displayMaxFreq { continue }
            let y = plotHeight * (1.0 - CGFloat(freq / displayMaxFreq))
            context.draw(
                Text("\(Int(freq))").font(.system(size: 8)).foregroundColor(.gray),
                at: CGPoint(x: leftMargin - 4, y: y),
                anchor: .trailing
            )
        }

        // "Hz" label
        context.draw(
            Text("Hz").font(.system(size: 7, weight: .medium)).foregroundColor(.gray.opacity(0.6)),
            at: CGPoint(x: leftMargin - 4, y: 4),
            anchor: .trailing
        )

        // Time axis labels (bottom)
        let nTimeLabels = 6
        let timeStep = windowSec / Float(nTimeLabels)
        let roundedStep = max(1, round(timeStep))
        var timeLabelSec = ceil(currentTime / roundedStep) * roundedStep
        while timeLabelSec <= currentTime + windowSec {
            let x = leftMargin + CGFloat((timeLabelSec - currentTime) / windowSec) * plotWidth
            if x >= leftMargin && x <= size.width - 20 {
                let tMin = Int(timeLabelSec) / 60
                let tSec = Int(timeLabelSec) % 60
                context.draw(
                    Text(String(format: "%d:%02d", tMin, tSec))
                        .font(.system(size: 8)).foregroundColor(.gray),
                    at: CGPoint(x: x, y: plotHeight + 10),
                    anchor: .center
                )
            }
            timeLabelSec += roundedStep
        }

        // Axis lines
        var axisPath = Path()
        axisPath.move(to: CGPoint(x: leftMargin, y: 0))
        axisPath.addLine(to: CGPoint(x: leftMargin, y: plotHeight))
        axisPath.move(to: CGPoint(x: leftMargin, y: plotHeight))
        axisPath.addLine(to: CGPoint(x: size.width, y: plotHeight))
        context.stroke(axisPath, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
    }

    // MARK: - Spectrogram Image Rendering

    /// Pre-render the full spectrogram to a CGImage using the jet colormap.
    private static func renderSpectrogramImage(spec: SignalProcessor.SpectrogramResult,
                                                maxFreq: Float) -> CGImage? {
        let nTime = spec.times.count
        guard nTime > 0 else { return nil }

        let freqIndices = spec.frequencies.enumerated().filter { $0.element <= maxFreq }
        guard let lastFreqIdx = freqIndices.last?.offset else { return nil }
        let nFreq = lastFreqIdx + 1
        guard nFreq > 0 else { return nil }

        // 3rd-97th percentile for stronger contrast
        var allValues = [Float]()
        allValues.reserveCapacity(nFreq * nTime)
        for fi in 0..<nFreq {
            allValues.append(contentsOf: spec.power[fi])
        }
        allValues.sort()
        let vmin = allValues[max(0, Int(Float(allValues.count) * 0.03))]
        let vmax = allValues[min(allValues.count - 1, Int(Float(allValues.count) * 0.97))]
        let range = vmax - vmin

        var pixels = [UInt8](repeating: 0, count: nTime * nFreq * 4)

        for fi in 0..<nFreq {
            let row = nFreq - 1 - fi  // Flip Y: low freq at bottom
            for ti in 0..<nTime {
                let value = spec.power[fi][ti]
                let normalized = range > 0 ? max(0, min(1, (value - vmin) / range)) : 0.5
                let (r, g, b) = ColorMap.jetRGB(at: normalized)

                let offset = (row * nTime + ti) * 4
                pixels[offset]     = UInt8(min(255, max(0, r * 255)))
                pixels[offset + 1] = UInt8(min(255, max(0, g * 255)))
                pixels[offset + 2] = UInt8(min(255, max(0, b * 255)))
                pixels[offset + 3] = 255
            }
        }

        // Use withUnsafeMutableBytes to guarantee the pixel buffer stays alive
        // while CGContext holds a raw pointer to it through makeImage()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return pixels.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: nTime,
                height: nFreq,
                bitsPerComponent: 8,
                bytesPerRow: nTime * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
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
