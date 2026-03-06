// CoherenceHeatmapView.swift
// Coherence heatmap matrix rendered via Canvas. Shows inter-channel coherence 0–1.
// In diff mode, shows coherence change (−1 to +1) with diverging colormap.
// Band selection is controlled externally (from QEEGDashboard) so all recordings share the same band.

import SwiftUI

struct CoherenceHeatmapView: View {
    let results: QEEGResults
    /// Which frequency band to display. Controlled by the parent view.
    var selectedBand: String = "Alpha"
    /// When true, values represent coherence differences and may be negative.
    var isDiff: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Text(isDiff ? "Coherence Change" : "Coherence Matrix")
                .font(.caption.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            GeometryReader { geo in
                Canvas { context, size in
                    drawHeatmap(context: context, size: size)
                }
            }
        }
    }

    private func drawHeatmap(context: GraphicsContext, size: CGSize) {
        guard let matrix = results.coherence[selectedBand] else { return }
        let n = results.channels.count
        guard n > 0, matrix.count == n else { return }

        let labelWidth: CGFloat = 30
        let plotSize = min(size.width - labelWidth, size.height - labelWidth)
        let cellSize = plotSize / CGFloat(n)
        let offsetX = labelWidth
        let offsetY: CGFloat = 0

        // Draw cells
        for i in 0..<n {
            for j in 0..<n {
                let value = matrix[i][j]
                let color = isDiff ? diffCoherenceColor(value) : coherenceColor(value)
                let rect = CGRect(
                    x: offsetX + CGFloat(j) * cellSize,
                    y: offsetY + CGFloat(i) * cellSize,
                    width: cellSize + 0.5,
                    height: cellSize + 0.5
                )
                context.fill(Path(rect), with: .color(color))
            }
        }

        // Channel labels
        for (i, ch) in results.channels.enumerated() {
            // Y-axis labels (rows)
            context.draw(
                Text(ch).font(.system(size: 7)),
                at: CGPoint(x: labelWidth - 2, y: offsetY + CGFloat(i) * cellSize + cellSize / 2),
                anchor: .trailing
            )
            // X-axis labels (columns) — rotated
            let x = offsetX + CGFloat(i) * cellSize + cellSize / 2
            let y = offsetY + CGFloat(n) * cellSize + 2
            context.draw(
                Text(ch).font(.system(size: 7)),
                at: CGPoint(x: x, y: y),
                anchor: .top
            )
        }
    }

    /// Standard coherence colormap (0–1): Yellow → Orange → Red
    private func coherenceColor(_ value: Float) -> Color {
        let t = max(0, min(1, value))
        // Yellow → Orange → Red
        if t < 0.5 {
            let f = Double(t / 0.5)
            return Color(red: 1.0, green: 1.0 - 0.35 * f, blue: 0.8 * (1.0 - f))
        } else {
            let f = Double((t - 0.5) / 0.5)
            return Color(red: 1.0, green: 0.65 * (1.0 - f), blue: 0)
        }
    }

    /// Diff coherence colormap (−1 to +1): uses the existing EEG z-score diverging colormap.
    /// Maps: −1 → cyan (decreased), 0 → black (unchanged), +1 → yellow (increased).
    private func diffCoherenceColor(_ value: Float) -> Color {
        let clamped = max(-1, min(1, value))
        let position = (clamped + 1) / 2  // Map −1...+1 to 0...1
        return ColorMap.eegColorMap(at: position)
    }
}
