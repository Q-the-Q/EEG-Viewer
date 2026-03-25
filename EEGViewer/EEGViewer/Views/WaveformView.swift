// WaveformView.swift
// Multi-channel EEG waveform viewer with Canvas rendering.
// Supports static (full recording) and playback (animated scrolling) modes.

import SwiftUI
import Combine
import Accelerate

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
    @State private var selectedAnnotationID: UUID?
    @State private var showLabelEditor = false
    // badChannelIndices stored in annotationStore for JSON persistence

    // Annotation creation via long press + drag
    @State private var annotationDragStart: CGFloat?
    @State private var annotationDragEnd: CGFloat?
    @State private var isCreatingAnnotation = false

    // Annotation edge resizing
    @State private var resizingAnnotationID: UUID?
    @State private var resizingEdge: AnnotationEdge?
    @State private var resizeStartX: CGFloat?

    private enum AnnotationEdge { case leading, trailing }

    // Edit popover for long press on existing annotation
    @State private var showAnnotationEditPopover = false
    @State private var showAnnotationImporter = false

    // Auto-detected artifact overlay
    @State private var showArtifacts = false
    @State private var artifactMask: [Bool] = []
    @State private var artifactThresholdUV: Float = 100
    @State private var editingAnnotationID: UUID?

    private var activeLabel: AnnotationLabel? {
        annotationStore.labels.first { $0.id == activeLabelID }
    }

    private var artifactStatsText: String {
        guard !artifactMask.isEmpty else { return "Artifacts" }
        let rejected = artifactMask.filter { !$0 }.count
        let total = artifactMask.count
        let pct = total > 0 ? Float(rejected) / Float(total) * 100 : 0
        let threshStr = artifactThresholdUV.isFinite ? "\(Int(artifactThresholdUV))uV" : "off"
        return "\(rejected)/\(total) (\(String(format: "%.0f", pct))%) @\(threshStr)"
    }

    /// Compute artifact mask for visual overlay.
    /// Uses average reference only (no highpass) to avoid IIR filter artifacts,
    /// with progressive threshold relaxation matching the analysis pipeline.
    private func computeArtifactMask() {
        let rawData = edfData.eegData
        let sfreq = edfData.sfreq

        DispatchQueue.global(qos: .userInitiated).async {
            // Average reference only — skip highpass to avoid IIR biquad edge effects
            // that inflate peak-to-peak beyond what the analysis pipeline produces
            let data = SignalProcessor.averageReference(rawData)

            // Compute mask with progressive threshold relaxation
            let result = SignalProcessor.getArtifactMask(data, sfreq: sfreq)

            let rejected = result.mask.filter { !$0 }.count
            let total = result.mask.count
            print("[ArtifactMask] \(rejected)/\(total) rejected, threshold=\(result.effectiveThresholdUV)uV")

            DispatchQueue.main.async {
                artifactMask = result.mask
                artifactThresholdUV = result.effectiveThresholdUV
            }
        }
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

                    Button {
                        showAnnotationImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }

                    // Artifact overlay toggle
                    Button {
                        showArtifacts.toggle()
                        if showArtifacts && artifactMask.isEmpty {
                            computeArtifactMask()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showArtifacts
                                ? "exclamationmark.triangle.fill"
                                : "exclamationmark.triangle")
                            Text(showArtifacts ? artifactStatsText : "Artifacts")
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(showArtifacts ? Color.red.opacity(0.15) : Color.gray.opacity(0.1))
                        )
                        .foregroundColor(showArtifacts ? .red : .secondary)
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
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawWaveforms(context: context, size: size)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let tapTime = currentTime + Float(location.x / geo.size.width) * windowSec
                        if let tapped = annotationStore.annotations.first(where: {
                            tapTime >= $0.startTime && tapTime <= $0.endTime
                        }) {
                            selectedAnnotationID = (selectedAnnotationID == tapped.id) ? nil : tapped.id
                        } else {
                            selectedAnnotationID = nil
                        }
                    }
                    .gesture(
                        longPressAnnotationGesture(in: geo)
                            .exclusively(before: scrubGesture(in: geo))
                    )

                    // Live preview rectangle while creating annotation
                    if let ps = annotationDragStart, let pe = annotationDragEnd {
                        let x = min(ps, pe)
                        let w = abs(pe - ps)
                        Rectangle()
                            .fill(activeLabel?.color.color.opacity(0.3) ?? Color.red.opacity(0.3))
                            .frame(width: w, height: geo.size.height)
                            .position(x: x + w / 2, y: geo.size.height / 2)
                            .allowsHitTesting(false)
                    }

                    // Drag handles on selected annotation (overlay approach avoids .position() hit-test issues)
                    if let selID = selectedAnnotationID,
                       let annotation = annotationStore.annotations.first(where: { $0.id == selID }) {
                        let startPx = CGFloat(annotation.startTime - currentTime) / CGFloat(windowSec) * geo.size.width
                        let endPx = CGFloat(annotation.endTime - currentTime) / CGFloat(windowSec) * geo.size.width

                        // Leading handle
                        if startPx > -20 && startPx < geo.size.width + 20 {
                            annotationHandle(edge: .leading, annotationID: selID, offsetX: startPx - 22, height: geo.size.height, geoWidth: geo.size.width)
                        }
                        // Trailing handle
                        if endPx > -20 && endPx < geo.size.width + 20 {
                            annotationHandle(edge: .trailing, annotationID: selID, offsetX: endPx - 22, height: geo.size.height, geoWidth: geo.size.width)
                        }
                    }
                }
                .coordinateSpace(name: "waveformArea")
            }

            Divider()

            // Controls
            controlsBar
        }
        .onAppear {
            selectedChannels = Set(edfData.eegIndices)
            activeLabelID = annotationStore.labels.first?.id
            // Precompute artifact mask for overlay
            // Apply same preprocessing as analysis pipeline (avg ref + highpass)
            computeArtifactMask()
        }
        .onDisappear {
            stopPlayback()
        }
        .onChange(of: annotationStore.labels.count) { _ in
            // Reset activeLabelID if the current label was deleted
            if let activeID = activeLabelID,
               !annotationStore.labels.contains(where: { $0.id == activeID }) {
                activeLabelID = annotationStore.labels.first?.id
            }
        }
        .sheet(isPresented: $showChannelSelector) {
            channelSelectorSheet
        }
        .sheet(isPresented: $showLabelEditor) {
            AnnotationLabelEditor(store: annotationStore)
        }
        .popover(isPresented: $showAnnotationEditPopover) {
            annotationEditMenu
        }
        .sheet(isPresented: $showAnnotationImporter) {
            AnnotationImportPicker { url in
                annotationStore.importFromFile(url)
            }
        }
    }

    // MARK: - Gestures

    /// Regular drag gesture for scrubbing through the recording
    private func scrubGesture(in geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragStartTime) { _, state, _ in
                if state == nil { state = currentTime }
            }
            .onChanged { value in
                guard !isCreatingAnnotation else { return }
                if let startTime = dragStartTime {
                    if isPlaying { stopPlayback() }
                    let dt = Float(value.translation.width) / Float(geo.size.width) * windowSec
                    currentTime = max(0, min(edfData.duration - windowSec, startTime - dt))
                }
            }
    }

    /// Long press followed by drag to create an annotation
    private func longPressAnnotationGesture(in geo: GeometryProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    guard let drag = drag else { return }
                    // Skip if we already triggered an edit popover for this gesture
                    guard !showAnnotationEditPopover else { return }
                    if !isCreatingAnnotation {
                        // Check if long press landed on an existing annotation
                        let pressTime = currentTime + Float(drag.startLocation.x / geo.size.width) * windowSec
                        if let existing = annotationStore.annotations.first(where: {
                            pressTime >= $0.startTime && pressTime <= $0.endTime
                        }) {
                            // Long press on existing annotation → show edit menu
                            editingAnnotationID = existing.id
                            selectedAnnotationID = existing.id
                            showAnnotationEditPopover = true
                            return
                        }
                        isCreatingAnnotation = true
                        annotationDragStart = drag.startLocation.x
                    }
                    annotationDragEnd = drag.location.x
                default:
                    break
                }
            }
            .onEnded { value in
                defer {
                    isCreatingAnnotation = false
                    annotationDragStart = nil
                    annotationDragEnd = nil
                }
                guard case .second(true, let drag) = value, let drag = drag else { return }
                guard isCreatingAnnotation else { return }
                let startX = min(drag.startLocation.x, drag.location.x)
                let endX = max(drag.startLocation.x, drag.location.x)
                let startFrac = Float(startX / geo.size.width)
                let endFrac = Float(endX / geo.size.width)
                let startTime = max(0, currentTime + startFrac * windowSec)
                let endTime = min(edfData.duration, currentTime + endFrac * windowSec)
                if endTime - startTime > 0.1, let activeID = activeLabelID {
                    annotationStore.addAnnotation(startTime: startTime, endTime: endTime, labelID: activeID)
                }
            }
    }

    // MARK: - Annotation Drag Handles

    @ViewBuilder
    private func annotationHandle(edge: AnnotationEdge, annotationID: UUID, offsetX: CGFloat, height: CGFloat, geoWidth: CGFloat) -> some View {
        // 44pt wide invisible touch target, 6pt visible bar, positioned via offset from top-leading
        VStack {
            Spacer()
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: 6, height: 48)
            Spacer()
        }
        .frame(width: 44, height: height)
        .contentShape(Rectangle())
        .offset(x: offsetX)
        .highPriorityGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("waveformArea"))
                .onChanged { value in
                    guard let annotation = annotationStore.annotations.first(where: { $0.id == annotationID }) else { return }
                    let newTime = currentTime + Float(value.location.x / geoWidth) * windowSec
                    let clampedTime = max(0, min(edfData.duration, newTime))
                    switch edge {
                    case .leading:
                        if clampedTime < annotation.endTime - 0.1 {
                            annotationStore.updateAnnotationInMemory(annotationID, startTime: clampedTime)
                        }
                    case .trailing:
                        if clampedTime > annotation.startTime + 0.1 {
                            annotationStore.updateAnnotationInMemory(annotationID, endTime: clampedTime)
                        }
                    }
                }
                .onEnded { _ in
                    annotationStore.save()
                }
        )
    }

    // MARK: - Annotation Edit Menu

    private var annotationEditMenu: some View {
        VStack(spacing: 12) {
            if let editID = editingAnnotationID,
               let annotation = annotationStore.annotations.first(where: { $0.id == editID }),
               let label = annotationStore.label(for: annotation) {
                Text(label.name)
                    .font(.headline)

                Text(String(format: "%.1fs – %.1fs (%.1fs)", annotation.startTime, annotation.endTime, annotation.endTime - annotation.startTime))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Change label:")
                    .font(.caption.bold())
                ForEach(annotationStore.labels) { lbl in
                    Button {
                        annotationStore.updateAnnotation(editID, labelID: lbl.id)
                        showAnnotationEditPopover = false
                    } label: {
                        HStack {
                            Circle().fill(lbl.color.color).frame(width: 12, height: 12)
                            Text(lbl.name)
                            if lbl.id == label.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    annotationStore.removeAnnotation(editID)
                    selectedAnnotationID = nil
                    editingAnnotationID = nil
                    showAnnotationEditPopover = false
                } label: {
                    Label("Delete Annotation", systemImage: "trash")
                }
            }
        }
        .padding()
        .frame(minWidth: 200)
    }

    // MARK: - Controls

    private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                // Channel selector button (prominent, always visible)
                Button {
                    showChannelSelector = true
                } label: {
                    Label("Channels", systemImage: "list.bullet")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)

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
                    let halfDur = (edfData.duration / 2).rounded()
                    let fullDur = edfData.duration.rounded()
                    if halfDur > Constants.windowSizeOptions.last ?? 0 {
                        Text("Half").tag(halfDur)
                    }
                    Text("All").tag(fullDur)
                }
                .pickerStyle(.menu)

                // Delete selected annotation
                if selectedAnnotationID != nil {
                    Button(role: .destructive) {
                        if let id = selectedAnnotationID {
                            annotationStore.removeAnnotation(id)
                            selectedAnnotationID = nil
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.caption)
                    }
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
                // Bad channel instruction section
                if !annotationStore.badChannelIndices.isEmpty {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("\(annotationStore.badChannelIndices.count) bad channel\(annotationStore.badChannelIndices.count == 1 ? "" : "s") marked")
                                .font(.subheadline.bold())
                        }
                        Text("Bad channels are interpolated (distance-weighted average from neighboring electrodes) before analysis. They appear with a red trace in the waveform view.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Tap the warning icon to mark noisy or flat channels as bad. Bad channels will be spatially interpolated before average referencing in the qEEG analysis pipeline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Channels") {
                    ForEach(0..<edfData.nChannels, id: \.self) { idx in
                        HStack {
                            Toggle(isOn: Binding(
                                get: { selectedChannels.contains(idx) },
                                set: { if $0 { selectedChannels.insert(idx) } else { selectedChannels.remove(idx) } }
                            )) {
                                HStack {
                                    Text(edfData.channelNames[idx])
                                        .foregroundColor(annotationStore.badChannelIndices.contains(idx) ? .red : .primary)
                                    if annotationStore.badChannelIndices.contains(idx) {
                                        Text("BAD")
                                            .font(.caption2.bold())
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(.red))
                                    }
                                }
                            }

                            // Bad channel marker (EEG channels only)
                            if edfData.eegIndices.contains(idx) {
                                Button {
                                    annotationStore.toggleBadChannel(idx)
                                } label: {
                                    Image(systemName: annotationStore.badChannelIndices.contains(idx) ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                        .foregroundColor(annotationStore.badChannelIndices.contains(idx) ? .red : .gray)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
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
            let isSelected = annotation.id == selectedAnnotationID
            context.fill(Path(rect), with: .color(label.color.color.opacity(isSelected ? 0.35 : 0.2)))
            if isSelected {
                context.stroke(Path(rect), with: .color(label.color.color), lineWidth: 2)
            }

            // Label name at top of region
            if clampedEnd - clampedStart > 30 {
                context.draw(
                    Text(label.name).font(.system(size: 9, weight: .medium)).foregroundColor(label.color.color),
                    at: CGPoint(x: clampedStart + 4, y: 8),
                    anchor: .topLeading
                )
            }
        }

        // Draw artifact rejection overlays (behind waveforms, after annotations)
        if showArtifacts && !artifactMask.isEmpty {
            let epochSec = Constants.epochDuration
            for (i, isClean) in artifactMask.enumerated() {
                guard !isClean else { continue }
                let epochStart = Float(i) * epochSec
                let epochEnd = epochStart + epochSec
                let startPx = CGFloat(epochStart - currentTime) / CGFloat(windowSec) * size.width
                let endPx = CGFloat(epochEnd - currentTime) / CGFloat(windowSec) * size.width
                guard endPx > 0 && startPx < size.width else { continue }

                let clampedStart = max(0, startPx)
                let clampedEnd = min(size.width, endPx)
                let rect = CGRect(x: clampedStart, y: 0,
                                  width: clampedEnd - clampedStart, height: size.height)
                context.fill(Path(rect), with: .color(.red.opacity(0.15)))
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

            let lineColor = annotationStore.badChannelIndices.contains(chIdx) ? Color.red.opacity(0.5) : Constants.waveformLineColor
            context.stroke(path, with: .color(lineColor), lineWidth: annotationStore.badChannelIndices.contains(chIdx) ? 1.5 : 1.0)
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
        // Can't play when the entire recording fits in the window
        guard windowSec < edfData.duration else { return }
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

// MARK: - Annotation Import Picker

/// Document picker specifically for importing .annotations.json files.
struct AnnotationImportPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // Copy to temp for reliable reading
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)

            onPick(tempURL)
        }
    }
}

