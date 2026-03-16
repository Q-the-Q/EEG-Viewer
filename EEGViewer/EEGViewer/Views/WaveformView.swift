// WaveformView.swift
// Multi-channel EEG waveform viewer with Canvas rendering.
// Supports static (full recording) and playback (animated scrolling) modes.

import SwiftUI
import Combine

struct WaveformView: View {
    let edfData: EDFData
    @ObservedObject var annotationStore: AnnotationStore

    @State private var isPlaying = false
    @State private var currentTime: Float = 0
    @State private var speed: Float = 1.0
    @State private var amplitudeScale: Float = 1.0
    @State private var windowSec: Float = Constants.defaultWindowSec
    @State private var selectedChannels: Set<Int> = []
    @State private var showChannelSelector = false
    @State private var timer: AnyCancellable?
    @GestureState private var dragStartTime: Float?
    @State private var activeLabelID: UUID?
    @State private var pencilPreviewStart: CGFloat?
    @State private var pencilPreviewEnd: CGFloat?
    @State private var selectedAnnotationID: UUID?
    @State private var showLabelEditor = false

    private var activeLabel: AnnotationLabel? {
        annotationStore.labels.first { $0.id == activeLabelID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Label selector bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(annotationStore.labels) { label in
                        Button {
                            if let selID = selectedAnnotationID {
                                annotationStore.updateAnnotation(selID, labelID: label.id)
                                selectedAnnotationID = nil
                            } else {
                                activeLabelID = label.id
                            }
                        } label: {
                            Text(label.name)
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(label.color.color.opacity(activeLabelID == label.id ? 0.4 : 0.15))
                                )
                                .overlay(
                                    Capsule().stroke(label.color.color, lineWidth: activeLabelID == label.id ? 2 : 0.5)
                                )
                                .foregroundColor(label.color.color)
                        }
                    }

                    Button {
                        showLabelEditor = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.caption)
                    }

                    Spacer()

                    if !annotationStore.annotations.isEmpty {
                        Text("\(annotationStore.annotations.count) annotations")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color(.systemGray6))

            // Waveform canvas
            GeometryReader { geo in
                ZStack {
                    Canvas { context, size in
                        drawWaveforms(context: context, size: size)
                    }
                    .gesture(
                        DragGesture()
                            .updating($dragStartTime) { _, state, _ in
                                if state == nil { state = currentTime }
                            }
                            .onChanged { value in
                                if let startTime = dragStartTime {
                                    if isPlaying { stopPlayback() }
                                    let dt = Float(value.translation.width) / Float(geo.size.width) * windowSec
                                    currentTime = max(0, min(edfData.duration - windowSec, startTime - dt))
                                }
                            }
                    )

                    // Pencil overlay (only captures pencil touches)
                    PencilOverlayView(
                        windowSec: windowSec,
                        currentTime: currentTime,
                        duration: edfData.duration,
                        onDraw: { start, end in
                            if let activeID = activeLabelID {
                                annotationStore.addAnnotation(startTime: start, endTime: end, labelID: activeID)
                            }
                        },
                        previewStart: $pencilPreviewStart,
                        previewEnd: $pencilPreviewEnd
                    )
                    .allowsHitTesting(true)

                    // Live preview rectangle while drawing
                    if let ps = pencilPreviewStart, let pe = pencilPreviewEnd {
                        let x = min(ps, pe)
                        let w = abs(pe - ps)
                        Rectangle()
                            .fill(activeLabel?.color.color.opacity(0.3) ?? Color.red.opacity(0.3))
                            .frame(width: w, height: geo.size.height)
                            .position(x: x + w / 2, y: geo.size.height / 2)
                            .allowsHitTesting(false)
                    }
                }
            }

            Divider()

            // Controls
            controlsBar
        }
        .onAppear {
            selectedChannels = Set(edfData.eegIndices)
            activeLabelID = annotationStore.labels.first?.id
        }
        .onDisappear {
            stopPlayback()
        }
        .sheet(isPresented: $showChannelSelector) {
            channelSelectorSheet
        }
        .sheet(isPresented: $showLabelEditor) {
            AnnotationLabelEditor(store: annotationStore)
        }
    }

    // MARK: - Controls

    private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // Play/Pause
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32)
                }

                // Speed
                VStack(spacing: 2) {
                    Text("Speed: \(speed, specifier: "%.1f")x")
                        .font(.caption2)
                    Slider(value: $speed, in: 0.5...4.0, step: 0.5)
                        .frame(width: 80)
                }

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

        // Draw annotation regions (behind waveforms)
        for annotation in annotationStore.annotations {
            guard let label = annotationStore.label(for: annotation) else { continue }
            let annStartPx = CGFloat(annotation.startTime - currentTime) / CGFloat(windowSec) * size.width
            let annEndPx = CGFloat(annotation.endTime - currentTime) / CGFloat(windowSec) * size.width
            guard annEndPx > 0 && annStartPx < size.width else { continue }

            let clampedStart = max(0, annStartPx)
            let clampedEnd = min(size.width, annEndPx)
            let rect = CGRect(x: clampedStart, y: 0, width: clampedEnd - clampedStart, height: size.height)
            context.fill(Path(rect), with: .color(label.color.color.opacity(0.2)))

            // Label name at top of region
            if clampedEnd - clampedStart > 30 {
                context.draw(
                    Text(label.name).font(.system(size: 9, weight: .medium)).foregroundColor(label.color.color),
                    at: CGPoint(x: clampedStart + 4, y: 8),
                    anchor: .topLeading
                )
            }
        }

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

// MARK: - Pencil Overlay

struct PencilOverlayView: UIViewRepresentable {
    let windowSec: Float
    let currentTime: Float
    let duration: Float
    let onDraw: (Float, Float) -> Void
    @Binding var previewStart: CGFloat?
    @Binding var previewEnd: CGFloat?

    func makeUIView(context: Context) -> PencilCaptureView {
        let view = PencilCaptureView()
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: PencilCaptureView, context: Context) {
        context.coordinator.windowSec = windowSec
        context.coordinator.currentTime = currentTime
        context.coordinator.duration = duration
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDraw: onDraw, previewStart: $previewStart, previewEnd: $previewEnd,
                    windowSec: windowSec, currentTime: currentTime, duration: duration)
    }

    class Coordinator: NSObject {
        let onDraw: (Float, Float) -> Void
        var previewStart: Binding<CGFloat?>
        var previewEnd: Binding<CGFloat?>
        var windowSec: Float
        var currentTime: Float
        var duration: Float
        private var startX: CGFloat?

        init(onDraw: @escaping (Float, Float) -> Void, previewStart: Binding<CGFloat?>,
             previewEnd: Binding<CGFloat?>, windowSec: Float, currentTime: Float, duration: Float) {
            self.onDraw = onDraw; self.previewStart = previewStart; self.previewEnd = previewEnd
            self.windowSec = windowSec; self.currentTime = currentTime; self.duration = duration
        }

        func pencilBegan(at x: CGFloat, width: CGFloat) {
            startX = x
            previewStart.wrappedValue = x
            previewEnd.wrappedValue = x
        }

        func pencilMoved(to x: CGFloat, width: CGFloat) {
            previewEnd.wrappedValue = x
        }

        func pencilEnded(at x: CGFloat, width: CGFloat) {
            guard let sx = startX else { return }
            let startFrac = Float(min(sx, x) / width)
            let endFrac = Float(max(sx, x) / width)
            let startTime = max(0, currentTime + startFrac * windowSec)
            let endTime = min(duration, currentTime + endFrac * windowSec)
            if endTime - startTime > 0.1 {
                onDraw(startTime, endTime)
            }
            startX = nil
            previewStart.wrappedValue = nil
            previewEnd.wrappedValue = nil
        }
    }
}

class PencilCaptureView: UIView {
    weak var coordinator: PencilOverlayView.Coordinator?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        coordinator?.pencilBegan(at: touch.location(in: self).x, width: bounds.width)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        coordinator?.pencilMoved(to: touch.location(in: self).x, width: bounds.width)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touch.type == .pencil else { return }
        coordinator?.pencilEnded(at: touch.location(in: self).x, width: bounds.width)
    }
}
