// SpectraChartView.swift
// Magnitude spectra display for Frontal, Central, and Posterior regions using Swift Charts.
// Renders with a light background to match clinical report style.
// SpectraOverlayView (below) shows two recordings overlaid on one chart with differential
// area coloring: red where R2 > R1 (power increased), blue where R2 < R1 (decreased).

import SwiftUI
import Charts

struct SpectraChartView: View {
    let results: QEEGResults
    let region: String
    let channels: [String]
    /// Shared Y-axis max across all 3 region charts (peak + 0.2 µV).
    /// If nil, falls back to per-chart auto-scale.
    var sharedMaxY: Float? = nil

    // Band shading — alternating near-white / light blue (matches reference report)
    private let shadeLighter = Color(red: 0.94, green: 0.96, blue: 0.98)  // Near-white
    private let shadeDarker  = Color(red: 0.78, green: 0.88, blue: 0.97)  // Definite light blue
    // Teal dashed band boundary lines
    private let boundaryColor = Color(red: 0.35, green: 0.58, blue: 0.62)
    // Spectrum line — dark blue
    private let lineColor = Color(red: 0.20, green: 0.40, blue: 0.70)
    // Area fill under curve — medium blue, semi-opaque
    private let fillColor = Color(red: 0.50, green: 0.72, blue: 0.92)

    private var effectiveMaxY: Float {
        sharedMaxY ?? max(0.1, (spectrumData.map(\.amplitude).max() ?? 1.0) * 1.15)
    }

    /// Y-axis grid values (every 2.0 µV)
    private var yGridValues: [Float] {
        var vals = [Float]()
        var y: Float = 2.0
        while y < effectiveMaxY {
            vals.append(y)
            y += 2.0
        }
        return vals
    }

    var body: some View {
        // Compute spectrum data once per render cycle
        let data = spectrumData
        let maxAmp = data.map(\.amplitude).max()

        VStack(spacing: 4) {
            if let maxAmp {
                Text(String(format: "%.1f \u{00B5}V", maxAmp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(region)
                .font(.subheadline.bold())
                .foregroundColor(.primary)

            Chart {
                // Alternating light/dark blue band shading
                ForEach(Array(Constants.freqBands.enumerated()), id: \.element.name) { idx, band in
                    RectangleMark(
                        xStart: .value("", max(band.low, Float(2.0))),
                        xEnd: .value("", band.high),
                        yStart: .value("", Float(0)),
                        yEnd: .value("", effectiveMaxY)
                    )
                    .foregroundStyle(idx % 2 == 0 ? shadeLighter : shadeDarker)
                }

                // Vertical grid lines at tick marks (on top of band shading)
                ForEach([5, 10, 15, 20, 25] as [Float], id: \.self) { freq in
                    RuleMark(x: .value("", freq))
                        .foregroundStyle(Color.black.opacity(0.15))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                // Horizontal grid lines (Y axis ticks)
                ForEach(yGridValues, id: \.self) { yVal in
                    RuleMark(y: .value("", yVal))
                        .foregroundStyle(Color.black.opacity(0.15))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                // Teal dashed band boundaries
                ForEach([4, 8, 13] as [Float], id: \.self) { freq in
                    RuleMark(x: .value("", freq))
                        .foregroundStyle(boundaryColor.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
                }

                // Area fill under curve — solid semi-opaque blue
                ForEach(data, id: \.freq) { point in
                    AreaMark(
                        x: .value("Frequency", point.freq),
                        y: .value("Amplitude", point.amplitude)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [
                                fillColor.opacity(0.55),
                                fillColor.opacity(0.30)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }

                // Amplitude spectrum line
                ForEach(data, id: \.freq) { point in
                    LineMark(
                        x: .value("Frequency", point.freq),
                        y: .value("Amplitude", point.amplitude)
                    )
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.0))
                }
            }
            .chartXScale(domain: 2...25)
            .chartYScale(domain: 0...effectiveMaxY)
            .chartXAxis {
                AxisMarks(values: [5, 10, 15, 20, 25]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1.0))
                        .foregroundStyle(Color.black.opacity(0.3))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray)
                    AxisValueLabel {
                        if let v = value.as(Float.self) {
                            Text("\(Int(v))")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.35))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1.0))
                        .foregroundStyle(Color.black.opacity(0.3))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray)
                    AxisValueLabel {
                        if let v = value.as(Float.self) {
                            Text(String(format: "%.1f", v))
                                .font(.system(size: 8))
                                .foregroundColor(Color(white: 0.35))
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.white)
                    .border(Color.gray.opacity(0.2), width: 0.5)
            }
            // Force light appearance so chart renders with white background
            .environment(\.colorScheme, .light)
        }
    }

    private struct SpectrumPoint: Identifiable {
        let id = UUID()
        let freq: Float
        let amplitude: Float
    }

    private var spectrumData: [SpectrumPoint] {
        let freqs = results.freqs
        let channelIndices = channels.compactMap { results.channels.firstIndex(of: $0) }
        guard !channelIndices.isEmpty else { return [] }

        var points = [SpectrumPoint]()
        for (i, freq) in freqs.enumerated() where freq >= 2 && freq <= 25 {
            var sumPSD: Float = 0
            for chIdx in channelIndices {
                if chIdx < results.psd.count && i < results.psd[chIdx].count {
                    sumPSD += results.psd[chIdx][i]
                }
            }
            let avgPSD = sumPSD / Float(channelIndices.count)
            let amplitudeUV = sqrtf(avgPSD) * 1e6
            points.append(SpectrumPoint(freq: freq, amplitude: amplitudeUV))
        }
        return points
    }

    /// Compute peak amplitude for this region (used by parent to find global max).
    static func peakAmplitude(results: QEEGResults, channels: [String]) -> Float {
        let channelIndices = channels.compactMap { results.channels.firstIndex(of: $0) }
        guard !channelIndices.isEmpty else { return 0 }

        var peak: Float = 0
        for (i, freq) in results.freqs.enumerated() where freq >= 2 && freq <= 25 {
            var sumPSD: Float = 0
            for chIdx in channelIndices {
                if chIdx < results.psd.count && i < results.psd[chIdx].count {
                    sumPSD += results.psd[chIdx][i]
                }
            }
            let amplitudeUV = sqrtf(sumPSD / Float(channelIndices.count)) * 1e6
            peak = max(peak, amplitudeUV)
        }
        return peak
    }
}

// MARK: - Spectra Overlay View

/// Overlay chart showing two recordings on the same axes for visual comparison.
/// Recording 1 (baseline) is drawn as a dashed line; Recording 2 (post) as a solid line.
/// The area between is filled red where R2 > R1 (power increased) and blue where
/// R2 < R1 (power decreased), making spectral changes immediately visible.
struct SpectraOverlayView: View {
    let baselineResults: QEEGResults
    let postResults: QEEGResults
    let region: String
    let channels: [String]
    var sharedMaxY: Float? = nil

    // Band shading (same as SpectraChartView)
    private let shadeLighter = Color(red: 0.94, green: 0.96, blue: 0.98)
    private let shadeDarker  = Color(red: 0.78, green: 0.88, blue: 0.97)
    private let boundaryColor = Color(red: 0.35, green: 0.58, blue: 0.62)
    // Line colors: R1 = gray-blue dashed, R2 = dark blue solid
    private let baselineLineColor = Color(red: 0.50, green: 0.50, blue: 0.60)
    private let postLineColor = Color(red: 0.20, green: 0.40, blue: 0.70)

    private var effectiveMaxY: Float {
        let data = overlayData
        let maxAmp = data.map { max($0.baselineAmplitude, $0.postAmplitude) }.max() ?? 1.0
        return sharedMaxY ?? max(0.1, maxAmp * 1.15)
    }

    private var yGridValues: [Float] {
        var vals = [Float]()
        var y: Float = 2.0
        while y < effectiveMaxY {
            vals.append(y)
            y += 2.0
        }
        return vals
    }

    var body: some View {
        let data = overlayData
        // Frequency bin width for RectangleMark fills (constant for FFT data)
        let halfStep: Float = data.count > 1 ? (data[1].freq - data[0].freq) / 2 : 0.25

        VStack(spacing: 4) {
            // Compact legend
            HStack(spacing: 8) {
                legendLine(color: baselineLineColor, dashed: true, label: "R1")
                legendLine(color: postLineColor, dashed: false, label: "R2")
                legendPatch(color: Color.red.opacity(0.40), label: "\u{2191}")
                legendPatch(color: Color.blue.opacity(0.40), label: "\u{2193}")
            }

            Text(region)
                .font(.subheadline.bold())
                .foregroundColor(.primary)

            Chart {
                // Band shading
                ForEach(Array(Constants.freqBands.enumerated()), id: \.element.name) { idx, band in
                    RectangleMark(
                        xStart: .value("", max(band.low, Float(2.0))),
                        xEnd: .value("", band.high),
                        yStart: .value("", Float(0)),
                        yEnd: .value("", effectiveMaxY)
                    )
                    .foregroundStyle(idx % 2 == 0 ? shadeLighter : shadeDarker)
                }

                // Vertical grid lines
                ForEach([5, 10, 15, 20, 25] as [Float], id: \.self) { freq in
                    RuleMark(x: .value("", freq))
                        .foregroundStyle(Color.black.opacity(0.15))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                // Horizontal grid lines
                ForEach(yGridValues, id: \.self) { yVal in
                    RuleMark(y: .value("", yVal))
                        .foregroundStyle(Color.black.opacity(0.15))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                // Band boundaries
                ForEach([4, 8, 13] as [Float], id: \.self) { freq in
                    RuleMark(x: .value("", freq))
                        .foregroundStyle(boundaryColor.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [5, 4]))
                }

                // Differential fill using discrete bars at each frequency bin.
                // RectangleMark avoids AreaMark path-closing artifacts (diagonal lines).

                // Red bars where R2 > R1 (power increased)
                ForEach(data.filter { $0.postAmplitude > $0.baselineAmplitude }, id: \.freq) { point in
                    RectangleMark(
                        xStart: .value("", point.freq - halfStep),
                        xEnd: .value("", point.freq + halfStep),
                        yStart: .value("", point.baselineAmplitude),
                        yEnd: .value("", point.postAmplitude)
                    )
                    .foregroundStyle(Color.red.opacity(0.30))
                }

                // Blue bars where R1 > R2 (power decreased)
                ForEach(data.filter { $0.baselineAmplitude > $0.postAmplitude }, id: \.freq) { point in
                    RectangleMark(
                        xStart: .value("", point.freq - halfStep),
                        xEnd: .value("", point.freq + halfStep),
                        yStart: .value("", point.postAmplitude),
                        yEnd: .value("", point.baselineAmplitude)
                    )
                    .foregroundStyle(Color.blue.opacity(0.30))
                }

                // R1 line (dashed)
                ForEach(data, id: \.freq) { point in
                    LineMark(
                        x: .value("Frequency", point.freq),
                        y: .value("Amplitude", point.baselineAmplitude),
                        series: .value("Series", "Baseline")
                    )
                    .foregroundStyle(baselineLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }

                // R2 line (solid)
                ForEach(data, id: \.freq) { point in
                    LineMark(
                        x: .value("Frequency", point.freq),
                        y: .value("Amplitude", point.postAmplitude),
                        series: .value("Series", "Post")
                    )
                    .foregroundStyle(postLineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.0))
                }
            }
            .chartXScale(domain: 2...25)
            .chartYScale(domain: 0...effectiveMaxY)
            .chartXAxis {
                AxisMarks(values: [5, 10, 15, 20, 25]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1.0))
                        .foregroundStyle(Color.black.opacity(0.3))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray)
                    AxisValueLabel {
                        if let v = value.as(Float.self) {
                            Text("\(Int(v))")
                                .font(.system(size: 9))
                                .foregroundColor(Color(white: 0.35))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1.0))
                        .foregroundStyle(Color.black.opacity(0.3))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray)
                    AxisValueLabel {
                        if let v = value.as(Float.self) {
                            Text(String(format: "%.1f", v))
                                .font(.system(size: 8))
                                .foregroundColor(Color(white: 0.35))
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.white)
                    .border(Color.gray.opacity(0.2), width: 0.5)
            }
            .chartLegend(.hidden)
            .environment(\.colorScheme, .light)
        }
    }

    // MARK: - Legend Helpers

    private func legendLine(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 3) {
            if dashed {
                HStack(spacing: 2) {
                    Rectangle().fill(color).frame(width: 6, height: 2)
                    Rectangle().fill(color).frame(width: 6, height: 2)
                }
                .frame(width: 16, height: 8)
            } else {
                Rectangle().fill(color).frame(width: 16, height: 2)
            }
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }

    private func legendPatch(color: Color, label: String) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 8))
        }
    }

    // MARK: - Data

    private struct OverlayPoint {
        let freq: Float
        let baselineAmplitude: Float
        let postAmplitude: Float
    }

    /// Compute paired amplitude spectra for both recordings across the region's channels.
    private var overlayData: [OverlayPoint] {
        let freqs = baselineResults.freqs
        let channelIndices = channels.compactMap { baselineResults.channels.firstIndex(of: $0) }
        guard !channelIndices.isEmpty else { return [] }

        var points = [OverlayPoint]()
        for (i, freq) in freqs.enumerated() where freq >= 2 && freq <= 25 {
            // Baseline (R1)
            var sumPSD1: Float = 0
            for chIdx in channelIndices {
                if chIdx < baselineResults.psd.count && i < baselineResults.psd[chIdx].count {
                    sumPSD1 += baselineResults.psd[chIdx][i]
                }
            }
            let amp1 = sqrtf(sumPSD1 / Float(channelIndices.count)) * 1e6

            // Post (R2)
            var sumPSD2: Float = 0
            for chIdx in channelIndices {
                if chIdx < postResults.psd.count && i < postResults.psd[chIdx].count {
                    sumPSD2 += postResults.psd[chIdx][i]
                }
            }
            let amp2 = sqrtf(sumPSD2 / Float(channelIndices.count)) * 1e6

            points.append(OverlayPoint(freq: freq, baselineAmplitude: amp1, postAmplitude: amp2))
        }
        return points
    }
}
