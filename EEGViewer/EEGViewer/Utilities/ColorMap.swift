// ColorMap.swift
// NeuroSynchrony-style diverging colormap and Viridis-like colormap for spectrograms.

import SwiftUI

struct ColorMap {

    /// Interpolate the NeuroSynchrony colormap at a normalized position (0-1).
    /// Maps Z-scores: -2.5 (cyan) → 0 (black) → +2.5 (yellow).
    static func neuroSynchrony(at position: Float) -> Color {
        let t = max(0, min(1, position))
        let stops = Constants.neuroSynchronyStops

        // Find surrounding stops
        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            if t >= stops[i].position && t <= stops[i + 1].position {
                lower = stops[i]
                upper = stops[i + 1]
                break
            }
        }

        let range = upper.position - lower.position
        let frac = range > 0 ? (t - lower.position) / range : 0

        let r = Double(lower.r + frac * (upper.r - lower.r))
        let g = Double(lower.g + frac * (upper.g - lower.g))
        let b = Double(lower.b + frac * (upper.b - lower.b))

        return Color(red: r, green: g, blue: b)
    }

    /// Convert a Z-score to a colormap position (0-1).
    static func zscoreToPosition(_ zscore: Float) -> Float {
        return (zscore - Constants.zscoreMin) / (Constants.zscoreMax - Constants.zscoreMin)
    }

    /// Get RGB components for NeuroSynchrony at a position (0-1).
    static func neuroSynchronyRGB(at position: Float) -> (r: Float, g: Float, b: Float) {
        let t = max(0, min(1, position))
        let stops = Constants.neuroSynchronyStops

        var lower = stops[0]
        var upper = stops[stops.count - 1]
        for i in 0..<(stops.count - 1) {
            if t >= stops[i].position && t <= stops[i + 1].position {
                lower = stops[i]
                upper = stops[i + 1]
                break
            }
        }

        let range = upper.position - lower.position
        let frac = range > 0 ? (t - lower.position) / range : 0

        return (
            r: lower.r + frac * (upper.r - lower.r),
            g: lower.g + frac * (upper.g - lower.g),
            b: lower.b + frac * (upper.b - lower.b)
        )
    }

    /// Viridis-like colormap for spectrograms (simplified 5-stop version).
    static func viridis(at position: Float) -> Color {
        let t = max(0, min(1, position))

        // Simplified viridis: dark purple → blue → green → yellow
        let r: Double
        let g: Double
        let b: Double

        if t < 0.25 {
            let f = Double(t / 0.25)
            r = 0.267 * (1 - f) + 0.282 * f
            g = 0.004 * (1 - f) + 0.140 * f
            b = 0.329 * (1 - f) + 0.458 * f
        } else if t < 0.5 {
            let f = Double((t - 0.25) / 0.25)
            r = 0.282 * (1 - f) + 0.127 * f
            g = 0.140 * (1 - f) + 0.566 * f
            b = 0.458 * (1 - f) + 0.551 * f
        } else if t < 0.75 {
            let f = Double((t - 0.5) / 0.25)
            r = 0.127 * (1 - f) + 0.741 * f
            g = 0.566 * (1 - f) + 0.873 * f
            b = 0.551 * (1 - f) + 0.150 * f
        } else {
            let f = Double((t - 0.75) / 0.25)
            r = 0.741 * (1 - f) + 0.993 * f
            g = 0.873 * (1 - f) + 0.906 * f
            b = 0.150 * (1 - f) + 0.144 * f
        }

        return Color(red: r, green: g, blue: b)
    }

    static func viridisRGB(at position: Float) -> (r: Float, g: Float, b: Float) {
        let t = max(0, min(1, position))
        let r: Float; let g: Float; let b: Float

        if t < 0.25 {
            let f = t / 0.25
            r = 0.267 * (1 - f) + 0.282 * f
            g = 0.004 * (1 - f) + 0.140 * f
            b = 0.329 * (1 - f) + 0.458 * f
        } else if t < 0.5 {
            let f = (t - 0.25) / 0.25
            r = 0.282 * (1 - f) + 0.127 * f
            g = 0.140 * (1 - f) + 0.566 * f
            b = 0.458 * (1 - f) + 0.551 * f
        } else if t < 0.75 {
            let f = (t - 0.5) / 0.25
            r = 0.127 * (1 - f) + 0.741 * f
            g = 0.566 * (1 - f) + 0.873 * f
            b = 0.551 * (1 - f) + 0.150 * f
        } else {
            let f = (t - 0.75) / 0.25
            r = 0.741 * (1 - f) + 0.993 * f
            g = 0.873 * (1 - f) + 0.906 * f
            b = 0.150 * (1 - f) + 0.144 * f
        }
        return (r, g, b)
    }
}
