// ECGWaveformView.swift
// Single-channel ECG waveform viewer with R-peak annotations.

import SwiftUI
import Combine
import Accelerate

struct ECGWaveformView: View {
    let ecgSignal: [Float]
    let sfreq: Float
    let rPeakIndices: [Int]
    var isInverted: Bool = false

    /// Display signal — cached once; flipped if ECG was detected as inverted so R-peaks point up.
    /// Using a stored property avoids heap-allocating a full copy on every Canvas redraw.
    private let _displaySignal: [Float]?

    /// Safe accessor that falls back to ecgSignal if not pre-computed
    var displaySignal: [Float] { _displaySignal ?? ecgSignal }

    init(ecgSignal: [Float], sfreq: Float, rPeakIndices: [Int], isInverted: Bool = false) {
        self.ecgSignal = ecgSignal
        self.sfreq = sfreq
        self.rPeakIndices = rPeakIndices
        self.isInverted = isInverted
        self._displaySignal = isInverted ? ecgSignal.map { -$0 } : nil
    }

    @State private var currentTime: Float = 0
    @State private var windowSec: Float = 10.0
    @State private var amplitudeScale: Float = 1.0
    @GestureState private var dragStartTime: Float?

    private var duration: Float {
        Float(displaySignal.count) / sfreq
    }

    /// Waveform canvas height grows with amplitude scale (base 170, max 500)
    private var waveformHeight: CGFloat {
        min(500, max(170, CGFloat(amplitudeScale) * 170))
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Canvas { context, size in
                    drawECG(context: &context, size: size)
                }
                .gesture(
                    DragGesture()
                        .updating($dragStartTime) { _, state, _ in
                            if state == nil { state = currentTime }
                        }
                        .onChanged { value in
                            if let startTime = dragStartTime {
                                let dt = Float(value.translation.width) / Float(geo.size.width) * windowSec
                                currentTime = max(0, min(duration - windowSec, startTime - dt))
                            }
                        }
                )
            }
            .frame(height: waveformHeight)

            Divider()

            // Compact controls
            HStack(spacing: 16) {
                // Time scrubber
                Slider(value: $currentTime, in: 0...max(0.01, duration - windowSec))
                    .frame(maxWidth: .infinity)

                // Window size
                Picker("Window", selection: $windowSec) {
                    ForEach([5, 10, 20, 30] as [Float], id: \.self) { w in
                        Text("\(Int(w))s").tag(w)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                // Amplitude
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $amplitudeScale, in: 0.2...5.0)
                        .frame(width: 80)
                    Text(String(format: "%.1f×", amplitudeScale))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func drawECG(context: inout GraphicsContext, size: CGSize) {
        let leftMargin: CGFloat = 50
        let topMargin: CGFloat = 8
        let bottomMargin: CGFloat = 8
        let plotWidth = size.width - leftMargin - 8
        let plotHeight = size.height - topMargin - bottomMargin

        guard plotWidth > 0, plotHeight > 0 else { return }

        // Background (use system background for dark mode support)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(.systemBackground)))

        // Determine sample range (use displaySignal for polarity-corrected ECG)
        let sig = displaySignal
        let startSample = Int(currentTime * sfreq)
        let endSample = min(sig.count, Int((currentTime + windowSec) * sfreq))
        guard endSample > startSample else { return }

        let totalSamples = endSample - startSample

        // Grid lines (1-second intervals) — guard against inverted range
        let startSec = Int(ceil(currentTime))
        let endSec = Int(floor(currentTime + windowSec))
        if startSec <= endSec {
            for sec in startSec...endSec {
                let x = leftMargin + CGFloat(Float(sec) - currentTime) / CGFloat(windowSec) * plotWidth
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: topMargin)); p.addLine(to: CGPoint(x: x, y: size.height - bottomMargin)) },
                    with: .color(Color.gray.opacity(0.15)),
                    lineWidth: 0.5
                )
                // Time label
                context.draw(
                    Text("\(sec)s").font(.system(size: 9)).foregroundColor(.gray),
                    at: CGPoint(x: x, y: size.height - 2), anchor: .bottom
                )
            }
        }

        // Zero line
        let midY = topMargin + plotHeight / 2
        context.stroke(
            Path { p in p.move(to: CGPoint(x: leftMargin, y: midY)); p.addLine(to: CGPoint(x: size.width - 8, y: midY)) },
            with: .color(Color.gray.opacity(0.3)),
            lineWidth: 0.5
        )

        // "ECG" label
        context.draw(
            Text("ECG").font(.system(size: 11, weight: .medium)).foregroundColor(.red),
            at: CGPoint(x: 6, y: midY), anchor: .leading
        )

        // Determine amplitude range for auto-scaling
        let visibleSlice = Array(sig[startSample..<endSample])
        var maxAbs: Float = 0
        vDSP_maxmgv(visibleSlice, 1, &maxAbs, vDSP_Length(visibleSlice.count))
        if maxAbs == 0 { maxAbs = 1 }
        let scale = Float(plotHeight / 2) / maxAbs * amplitudeScale * 0.8

        // Downsample for performance
        let maxPoints = 2000
        let step = max(1, totalSamples / maxPoints)

        // Clip to plot area as safety net
        let plotRect = CGRect(x: leftMargin, y: topMargin, width: plotWidth, height: plotHeight)
        context.clip(to: Path(plotRect))

        // Draw ECG trace
        var path = Path()
        var first = true
        for i in stride(from: startSample, to: endSample, by: step) {
            let x = leftMargin + CGFloat(Float(i - startSample) / Float(totalSamples)) * plotWidth
            let y = midY - CGFloat(sig[i] * scale)
            if first {
                path.move(to: CGPoint(x: x, y: y))
                first = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(Color(red: 0.8, green: 0.1, blue: 0.1)), lineWidth: 1.2)

        // Draw R-peak markers
        for peakIdx in rPeakIndices {
            guard peakIdx >= startSample && peakIdx < endSample else { continue }
            let x = leftMargin + CGFloat(Float(peakIdx - startSample) / Float(totalSamples)) * plotWidth
            let y = midY - CGFloat(sig[peakIdx] * scale)

            // Red triangle above peak
            let triSize: CGFloat = 6
            var tri = Path()
            tri.move(to: CGPoint(x: x, y: y - triSize - 2))
            tri.addLine(to: CGPoint(x: x - triSize / 2, y: y - 2))
            tri.addLine(to: CGPoint(x: x + triSize / 2, y: y - 2))
            tri.closeSubpath()
            context.fill(tri, with: .color(.red))
        }
    }
}
