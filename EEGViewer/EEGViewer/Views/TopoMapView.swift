// TopoMapView.swift
// Topographic head map display for Z-scores, rendered via Canvas + TopoMapRenderer.

import SwiftUI

struct TopoMapView: View {
    let zscores: [Float]
    let channels: [String]
    let bandName: String
    let freqRange: String

    @State private var renderedImage: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Text(bandName)
                .font(.caption.bold())
            Text(freqRange)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let image = renderedImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(Circle())
            } else {
                ProgressView()
                    .frame(width: 120, height: 120)
            }
        }
        .task {
            renderedImage = await Task.detached {
                TopoMapRenderer.render(values: zscores, channels: channels, size: 200)
            }.value
        }
    }
}

/// Color bar legend for topomaps.
struct TopoColorBar: View {
    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.1fZ", Constants.zscoreMax))
                .font(.system(size: 8))
            GeometryReader { geo in
                Canvas { context, size in
                    let steps = Int(size.height)
                    for y in 0..<steps {
                        let position = 1.0 - Float(y) / Float(steps)
                        let color = ColorMap.neuroSynchrony(at: position)
                        context.fill(
                            Path(CGRect(x: 0, y: CGFloat(y), width: size.width, height: 2)),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(width: 20)
            Text("0")
                .font(.system(size: 8))
            Text(String(format: "%.1fZ", Constants.zscoreMin))
                .font(.system(size: 8))
        }
    }
}
