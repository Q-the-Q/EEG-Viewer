// SpectraChartView.swift
// Magnitude spectra display for Frontal, Central, and Posterior regions using Swift Charts.

import SwiftUI
import Charts

struct SpectraChartView: View {
    let results: QEEGResults
    let region: String
    let channels: [String]

    var body: some View {
        VStack(spacing: 4) {
            Text(region)
                .font(.caption.bold())

            if let maxAmp = computeMaxAmplitude() {
                Text(String(format: "max %.2f µV", maxAmp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Chart {
                // Band shading
                ForEach(Constants.freqBands, id: \.name) { band in
                    RectangleMark(
                        xStart: .value("", band.low),
                        xEnd: .value("", band.high),
                        yStart: .value("", 0),
                        yEnd: .value("", maxYValue)
                    )
                    .foregroundStyle(band.shadeColor.opacity(0.25))
                }

                // Band boundaries
                ForEach([4, 8, 13] as [Float], id: \.self) { freq in
                    RuleMark(x: .value("", freq))
                        .foregroundStyle(.gray.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [4, 4]))
                }

                // Amplitude spectrum line
                ForEach(spectrumData, id: \.freq) { point in
                    LineMark(
                        x: .value("Frequency", point.freq),
                        y: .value("Amplitude", point.amplitude)
                    )
                    .foregroundStyle(Color(red: 0.05, green: 0.3, blue: 0.7))
                    .lineStyle(StrokeStyle(lineWidth: 2.0))
                }

                // Area fill
                ForEach(spectrumData, id: \.freq) { point in
                    AreaMark(
                        x: .value("Frequency", point.freq),
                        y: .value("Amplitude", point.amplitude)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [
                                Color(red: 0.05, green: 0.3, blue: 0.7).opacity(0.35),
                                Color(red: 0.05, green: 0.3, blue: 0.7).opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }
            .chartXScale(domain: 1...25)
            .chartYScale(domain: 0...maxYValue)
            .chartXAxis {
                AxisMarks(values: [1, 4, 8, 13, 25]) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let v = value.as(Float.self) {
                            Text("\(Int(v))")
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Float.self) {
                            Text(String(format: "%.1f", v))
                                .font(.system(size: 8))
                        }
                    }
                }
            }
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
        for (i, freq) in freqs.enumerated() where freq >= 1 && freq <= 25 {
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

    private var maxYValue: Float {
        let maxAmp = spectrumData.map(\.amplitude).max() ?? 1.0
        return max(0.1, maxAmp * 1.15)
    }

    private func computeMaxAmplitude() -> Float? {
        spectrumData.map(\.amplitude).max()
    }
}
