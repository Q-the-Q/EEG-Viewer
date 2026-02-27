// WaveformView.swift
// Multi-channel EEG waveform viewer with Canvas rendering.
// Supports static (full recording) and playback (animated scrolling) modes.

import SwiftUI
import Combine

struct WaveformView: View {
    let edfData: EDFData

    @State private var mode: ViewMode = .static_
    @State private var isPlaying = false
    @State private var currentTime: Float = 0
    @State private var speed: Float = 1.0
    @State private var amplitudeScale: Float = 1.0
    @State private var windowSec: Float = Constants.defaultWindowSec
    @State private var selectedChannels: Set<Int> = []
    @State private var showChannelSelector = false
    @State private var timer: AnyCancellable?

    enum ViewMode {
        case static_
        case playback
    }

    var body: some View {
        VStack(spacing: 0) {
            // Waveform canvas
            GeometryReader { geo in
                Canvas { context, size in
                    drawWaveforms(context: context, size: size)
                }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if mode == .static_ {
                                let dt = Float(value.translation.width) / Float(geo.size.width) * windowSec
                                currentTime = max(0, min(edfData.duration - windowSec, currentTime - dt))
                            }
                        }
                )
            }

            Divider()

            // Controls
            controlsBar
        }
        .onAppear {
            selectedChannels = Set(edfData.eegIndices)
        }
        .onDisappear {
            stopPlayback()
        }
        .sheet(isPresented: $showChannelSelector) {
            channelSelectorSheet
        }
    }

    // MARK: - Controls

    private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // Mode picker
                Picker("Mode", selection: $mode) {
                    Text("Static").tag(ViewMode.static_)
                    Text("Playback").tag(ViewMode.playback)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: mode) { newMode in
                    if newMode == .static_ { stopPlayback() }
                }

                // Play/Pause
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32)
                }
                .disabled(mode == .static_)

                // Speed
                VStack(spacing: 2) {
                    Text("Speed: \(speed, specifier: "%.1f")x")
                        .font(.caption2)
                    Slider(value: $speed, in: 0.5...4.0, step: 0.5)
                        .frame(width: 80)
                }
                .disabled(mode == .static_)

                // Time scrubber
                VStack(spacing: 2) {
                    Text(timeLabel)
                        .font(.caption2.monospacedDigit())
                    Slider(value: $currentTime, in: 0...max(0.01, edfData.duration - windowSec))
                        .frame(minWidth: 200)
                }

                // Amplitude
                VStack(spacing: 2) {
                    Text("Scale: \(amplitudeScale, specifier: "%.1f")x")
                        .font(.caption2)
                    Slider(value: $amplitudeScale, in: 0.1...5.0)
                        .frame(width: 100)
                }

                // Window size
                Picker("Window", selection: $windowSec) {
                    ForEach(Constants.windowSizeOptions, id: \.self) { ws in
                        Text("\(Int(ws))s").tag(ws)
                    }
                }
                .pickerStyle(.menu)

                // Channel selector button
                Button {
                    showChannelSelector = true
                } label: {
                    Label("Channels", systemImage: "list.bullet")
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var timeLabel: String {
        let curMin = Int(currentTime) / 60
        let curSec = Int(currentTime) % 60
        let totMin = Int(edfData.duration) / 60
        let totSec = Int(edfData.duration) % 60
        return String(format: "%02d:%02d / %02d:%02d", curMin, curSec, totMin, totSec)
    }

    private var channelSelectorSheet: some View {
        NavigationStack {
            List {
                ForEach(0..<edfData.nChannels, id: \.self) { idx in
                    Toggle(edfData.channelNames[idx], isOn: Binding(
                        get: { selectedChannels.contains(idx) },
                        set: { if $0 { selectedChannels.insert(idx) } else { selectedChannels.remove(idx) } }
                    ))
                }
            }
            .navigationTitle("Channels")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showChannelSelector = false }
                }
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button("Select All") { selectedChannels = Set(0..<edfData.nChannels) }
                        Spacer()
                        Button("EEG Only") { selectedChannels = Set(edfData.eegIndices) }
                        Spacer()
                        Button("None") { selectedChannels = [] }
                    }
                }
            }
        }
    }

    // MARK: - Drawing

    private func drawWaveforms(context: GraphicsContext, size: CGSize) {
        // White background
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))

        let channels = selectedChannels.sorted()
        guard !channels.isEmpty else { return }

        let nChannels = channels.count
        let channelHeight = size.height / CGFloat(nChannels)
        let sfreq = edfData.sfreq

        let startSample = Int(currentTime * sfreq)
        let windowSamples = Int(windowSec * sfreq)
        let endSample = min(startSample + windowSamples, edfData.data[0].count)
        guard endSample > startSample else { return }

        let actualSamples = endSample - startSample

        // Downsample for performance
        let maxPoints = 2000
        let step = max(1, actualSamples / maxPoints)
        let nPoints = actualSamples / step

        let xScale = size.width / CGFloat(nPoints)
        let spacing = Constants.channelSpacingUV * 1e-6  // Convert to Volts
        let yScale = channelHeight / CGFloat(spacing * 2) * CGFloat(amplitudeScale)

        // Draw gridlines
        var gridPath = Path()
        // Vertical time gridlines (every 1 second)
        let pixelsPerSec = size.width / CGFloat(windowSec)
        let firstGridSec = ceil(Double(currentTime))
        var gridSec = firstGridSec
        while Float(gridSec) < currentTime + windowSec {
            let x = CGFloat(Float(gridSec) - currentTime) * pixelsPerSec
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
            gridSec += 1
        }
        context.stroke(gridPath, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)

        // Draw each channel
        for (row, chIdx) in channels.enumerated() {
            let centerY = channelHeight * (CGFloat(row) + 0.5)

            // Channel label
            context.draw(
                Text(edfData.channelNames[chIdx]).font(.system(size: 10, weight: .medium)).foregroundColor(.black),
                at: CGPoint(x: 30, y: centerY),
                anchor: .leading
            )

            // Zero line
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: centerY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(zeroPath, with: .color(.gray.opacity(0.2)), lineWidth: 0.5)

            // Waveform
            let data = edfData.data[chIdx]
            var path = Path()
            var started = false

            for p in 0..<nPoints {
                let sampleIdx = startSample + p * step
                guard sampleIdx < data.count else { break }

                let value = CGFloat(data[sampleIdx])
                let x = CGFloat(p) * xScale
                let y = centerY - value * yScale

                if !started {
                    path.move(to: CGPoint(x: x, y: y))
                    started = true
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(Constants.waveformLineColor), lineWidth: 1.0)
        }
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        isPlaying = true
        timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let dt = Float(1.0 / 30.0) * speed
                currentTime += dt
                if currentTime >= edfData.duration - windowSec {
                    currentTime = 0
                }
            }
    }

    private func stopPlayback() {
        isPlaying = false
        timer?.cancel()
        timer = nil
    }
}
