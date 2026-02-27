// CoherenceHeatmapView.swift
// Coherence heatmap matrix rendered via Canvas. Shows inter-channel coherence 0–1.
// Band selection is controlled externally (from QEEGDashboard) so all recordings share the same band.

import SwiftUI

struct CoherenceHeatmapView: View {
    let results: QEEGResults
    /// Which frequency band to display. Controlled by the parent view.
    var selectedBand: String = "Alpha"

    var body: some View {
        VStack(spacing: 8) {
            Text("Coherence Matrix")
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
                // Yellow-Orange-Red colormap
                let color = coherenceColor(value)
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
}
