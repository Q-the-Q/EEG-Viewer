// SpectraChartView.swift
// Magnitude spectra display for Frontal, Central, and Posterior regions using Swift Charts.
// Renders with a light background to match clinical report style.

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
                Text(String(format: "%.1f µV", maxAmp))
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
                        yStart: .value("", 0),
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
            // Average PSD across region channels, then sqrt for amplitude in µV
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
