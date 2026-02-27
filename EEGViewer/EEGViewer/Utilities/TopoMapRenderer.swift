// TopoMapRenderer.swift
// Renders topographic head maps using Inverse Distance Weighting interpolation
// and Core Graphics. Replaces MNE's plot_topomap + scipy CloughTocher2DInterpolator.

import SwiftUI
import CoreGraphics

struct TopoMapRenderer {

    /// Render a topomap as a CGImage.
    /// - Parameters:
    ///   - values: Z-score values per channel (matched to channels array)
    ///   - channels: Channel names (subset of standard 10-20)
    ///   - size: Pixel dimensions of the output image
    static func render(values: [Float], channels: [String], size: Int = 200) -> CGImage? {
        let gridSize = size
        let headRadius = Constants.headRadius
        let margin: Float = 0.01

        // Get electrode positions for available channels
        var electrodes = [(x: Float, y: Float, value: Float)]()
        for (i, ch) in channels.enumerated() {
            if let pos = Constants.electrodePositions2D[ch], i < values.count {
                electrodes.append((x: pos.x, y: pos.y, value: values[i]))
            }
        }
        guard !electrodes.isEmpty else { return nil }

        // Map coordinates to pixel space
        let scale = Float(gridSize) / (2.0 * (headRadius + margin))
        let centerX = Float(gridSize) / 2.0
        let centerY = Float(gridSize) / 2.0
        let pixelRadius = headRadius * scale

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = gridSize * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: gridSize * gridSize * bytesPerPixel)

        // IDW interpolation with power=2
        let idwPower: Float = 2.0

        for py in 0..<gridSize {
            for px in 0..<gridSize {
                // Convert pixel to electrode coordinate space
                let ex = (Float(px) - centerX) / scale
                let ey = -(Float(py) - centerY) / scale  // Flip Y (nose up)

                // Check if inside head circle
                let distFromCenter = sqrtf(ex * ex + ey * ey)
                if distFromCenter > headRadius * 1.0 {
                    // Transparent outside head
                    continue
                }

                // IDW interpolation
                var weightedSum: Float = 0
                var weightSum: Float = 0
                var exactMatch = false

                for elec in electrodes {
                    let dx = ex - elec.x
                    let dy = ey - elec.y
                    let dist = sqrtf(dx * dx + dy * dy)

                    if dist < 0.0001 {
                        weightedSum = elec.value
                        weightSum = 1.0
                        exactMatch = true
                        break
                    }

                    let weight = 1.0 / powf(dist, idwPower)
                    weightedSum += weight * elec.value
                    weightSum += weight
                }

                let interpolated = exactMatch ? weightedSum : (weightSum > 0 ? weightedSum / weightSum : 0)

                // Map to colormap
                let position = ColorMap.zscoreToPosition(interpolated)
                let (r, g, b) = ColorMap.neuroSynchronyRGB(at: position)

                let offset = (py * gridSize + px) * bytesPerPixel
                pixelData[offset] = UInt8(min(255, max(0, r * 255)))
                pixelData[offset + 1] = UInt8(min(255, max(0, g * 255)))
                pixelData[offset + 2] = UInt8(min(255, max(0, b * 255)))
                pixelData[offset + 3] = 255  // Alpha
            }
        }

        // Create CGImage
        guard let context = CGContext(
            data: &pixelData,
            width: gridSize,
            height: gridSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw head outline, nose, and ears
        drawHeadOverlay(context: context, centerX: CGFloat(centerX), centerY: CGFloat(centerY),
                        radius: CGFloat(pixelRadius), scale: CGFloat(scale))

        // Draw electrode dots
        for elec in electrodes {
            let px = CGFloat(elec.x * scale + centerX)
            let py = CGFloat(elec.y * scale + centerY)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
            context.fillEllipse(in: CGRect(x: px - 2, y: py - 2, width: 4, height: 4))
        }

        return context.makeImage()
    }

    private static func drawHeadOverlay(context: CGContext, centerX: CGFloat, centerY: CGFloat,
                                         radius: CGFloat, scale: CGFloat) {
        context.setStrokeColor(CGColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1))
        context.setLineWidth(2.0)

        // Head circle
        context.strokeEllipse(in: CGRect(
            x: centerX - radius, y: centerY - radius,
            width: radius * 2, height: radius * 2
        ))

        // Nose (triangle at top — high Y in CGContext = top of displayed image)
        let noseWidth: CGFloat = radius * 0.15
        let noseHeight: CGFloat = radius * 0.12
        let noseBase = centerY + radius
        context.beginPath()
        context.move(to: CGPoint(x: centerX - noseWidth, y: noseBase))
        context.addLine(to: CGPoint(x: centerX, y: noseBase + noseHeight))
        context.addLine(to: CGPoint(x: centerX + noseWidth, y: noseBase))
        context.strokePath()

        // Left ear (CGContext: left side of head)
        let earWidth: CGFloat = 6
        let earHeight: CGFloat = radius * 0.3
        context.beginPath()
        context.addArc(center: CGPoint(x: centerX - radius - earWidth / 2, y: centerY),
                       radius: earHeight / 2, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        context.strokePath()

        // Right ear
        context.beginPath()
        context.addArc(center: CGPoint(x: centerX + radius + earWidth / 2, y: centerY),
                       radius: earHeight / 2, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        context.strokePath()
    }
}
