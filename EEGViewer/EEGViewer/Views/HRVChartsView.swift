// HRVChartsView.swift
// Chart sub-views for the Heart dashboard: tachogram, HRV spectrum, Poincaré, coherence, metrics card.

import SwiftUI
import Charts

// MARK: - HRV Metrics Card (with gauge visualization)

struct HRVMetricsCard: View {
    let results: HRVResults

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Row 1: Primary metrics with arc gauges
            LazyVGrid(columns: columns, spacing: 12) {
                gaugeCell("Mean HR", value: results.meanHR, unit: "BPM",
                          format: "%.0f", rangeKey: "meanHR",
                          info: MetricInfoContent.meanHR)
                gaugeCell("SDNN", value: results.sdnn, unit: "ms",
                          format: "%.1f", rangeKey: "sdnn",
                          info: MetricInfoContent.sdnn)
                gaugeCell("RMSSD", value: results.rmssd, unit: "ms",
                          format: "%.1f", rangeKey: "rmssd",
                          info: MetricInfoContent.rmssd)
                gaugeCell("pNN50", value: results.pnn50, unit: "%",
                          format: "%.1f", rangeKey: "pnn50",
                          info: MetricInfoContent.pnn50)
            }

            // Row 2: Frequency-domain metrics with bar context
            LazyVGrid(columns: columns, spacing: 12) {
                powerBalanceCell(info: MetricInfoContent.ansBalance)
                gaugeCell("LF/HF", value: results.lfHfRatio, unit: "ratio",
                          format: "%.2f", rangeKey: "lfhf",
                          info: MetricInfoContent.lfHfRatio)
                powerCell("LF Power", value: results.lfPower, color: .blue,
                          info: MetricInfoContent.lfPower)
                powerCell("HF Power", value: results.hfPower, color: .green,
                          info: MetricInfoContent.hfPower)
            }
        }
    }

    // MARK: - Gauge Cell (arc gauge + value + interpretation)

    private func gaugeCell(_ label: String, value: Float, unit: String,
                           format: String, rangeKey: String,
                           info: MetricInfoContent.InfoItem? = nil) -> some View {
        let range = Constants.hrvRanges[rangeKey]
        let interpretation = interpretValue(value, range: range)

        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let info = info {
                    InfoButton(info: info)
                }
            }

            // Arc gauge
            ArcGaugeView(value: value, range: range)
                .frame(width: 70, height: 42)

            Text(String(format: format, value))
                .font(.system(.body, design: .rounded).monospacedDigit().bold())
                .foregroundStyle(interpretation.color)

            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(interpretation.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(interpretation.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Power Balance Cell (LF vs HF stacked bar)

    private func powerBalanceCell(info: MetricInfoContent.InfoItem? = nil) -> some View {
        let total = results.lfPower + results.hfPower
        let lfFrac = total > 0 ? CGFloat(results.lfPower / total) : 0.5

        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text("ANS Balance")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let info = info {
                    InfoButton(info: info)
                }
            }

            // Stacked bar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: geo.size.width * lfFrac)
                    Rectangle()
                        .fill(Color.green.opacity(0.7))
                        .frame(width: geo.size.width * (1 - lfFrac))
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .padding(.horizontal, 8)

            HStack(spacing: 0) {
                Text("LF ")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.blue)
                Text(String(format: "%.0f%%", (total > 0 ? results.lfPower / total * 100 : 0)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
                Spacer()
                Text(String(format: "%.0f%%", (total > 0 ? results.hfPower / total * 100 : 0)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text(" HF")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 8)

            Text(lfFrac > 0.6 ? "Sympathetic" : lfFrac < 0.4 ? "Parasympathetic" : "Balanced")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(lfFrac > 0.6 ? .orange : lfFrac < 0.4 ? .blue : .green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Power Cell (simple value with magnitude bar)

    private func powerCell(_ label: String, value: Float, color: Color,
                           info: MetricInfoContent.InfoItem? = nil) -> some View {
        let totalPower = results.totalPower
        let fraction = totalPower > 0 ? CGFloat(value / totalPower) : 0

        return VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let info = info {
                    InfoButton(info: info)
                }
            }

            Text(formatPower(value))
                .font(.system(.body, design: .rounded).monospacedDigit().bold())
                .foregroundStyle(color)

            Text("ms\u{00B2}")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            // Proportion bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.systemGray4))
                    Capsule()
                        .fill(color.opacity(0.7))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 10)

            Text(String(format: "%.0f%% of total", fraction * 100))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }

    // MARK: - Helpers

    private struct Interpretation {
        let label: String
        let color: Color
    }

    private func interpretValue(_ value: Float, range: Constants.HRVRange?) -> Interpretation {
        guard let range = range else {
            return Interpretation(label: "", color: .primary)
        }
        if value < range.normalLow {
            return Interpretation(label: range.lowLabel, color: .orange)
        } else if value > range.normalHigh {
            return Interpretation(label: range.highLabel, color: .orange)
        } else {
            return Interpretation(label: range.normalLabel, color: .green)
        }
    }

    private func formatPower(_ power: Float) -> String {
        if power >= 10000 { return String(format: "%.1fk", power / 1000) }
        if power >= 1000 { return String(format: "%.1fk", power / 1000) }
        return String(format: "%.0f", power)
    }
}

// MARK: - Arc Gauge View (semi-circular gauge with colored zones)

struct ArcGaugeView: View {
    let value: Float
    let range: Constants.HRVRange?

    var body: some View {
        Canvas { context, size in
            guard let range = range else { return }

            let center = CGPoint(x: size.width / 2, y: size.height - 2)
            let radius = min(size.width / 2, size.height) - 4
            let lineWidth: CGFloat = 6
            let startAngle = Angle.degrees(180)
            let endAngle = Angle.degrees(360)
            let totalSweep = 180.0

            // Background track
            let trackPath = Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: startAngle, endAngle: endAngle, clockwise: false)
            }
            context.stroke(trackPath, with: .color(Color(.systemGray4)), lineWidth: lineWidth)

            // Colored zones: blue (low) → green (normal) → orange (high)
            let normalLowFrac = Double((range.normalLow - range.min) / (range.max - range.min))
            let normalHighFrac = Double((range.normalHigh - range.min) / (range.max - range.min))

            // Low zone (blue-ish)
            let lowEnd = Angle.degrees(180 + totalSweep * normalLowFrac)
            let lowPath = Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: startAngle, endAngle: lowEnd, clockwise: false)
            }
            context.stroke(lowPath, with: .color(Color.blue.opacity(0.4)), lineWidth: lineWidth)

            // Normal zone (green)
            let normalEnd = Angle.degrees(180 + totalSweep * normalHighFrac)
            let normalPath = Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: lowEnd, endAngle: normalEnd, clockwise: false)
            }
            context.stroke(normalPath, with: .color(Color.green.opacity(0.6)), lineWidth: lineWidth)

            // High zone (orange)
            let highPath = Path { p in
                p.addArc(center: center, radius: radius,
                         startAngle: normalEnd, endAngle: endAngle, clockwise: false)
            }
            context.stroke(highPath, with: .color(Color.orange.opacity(0.4)), lineWidth: lineWidth)

            // Needle indicator
            let clampedValue = max(range.min, min(range.max, value))
            let needleFrac = Double((clampedValue - range.min) / (range.max - range.min))
            let needleAngle = Angle.degrees(180 + totalSweep * needleFrac)
            let needleLength = radius - lineWidth / 2 - 2
            let needleTip = CGPoint(
                x: center.x + needleLength * CGFloat(cos(needleAngle.radians)),
                y: center.y + needleLength * CGFloat(sin(needleAngle.radians))
            )

            // Needle line
            let needlePath = Path { p in
                p.move(to: center)
                p.addLine(to: needleTip)
            }
            context.stroke(needlePath, with: .color(.primary), lineWidth: 1.5)

            // Needle dot at tip
            let dotRect = CGRect(x: needleTip.x - 2.5, y: needleTip.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dotRect), with: .color(.primary))

            // Center dot
            let centerDot = CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: centerDot), with: .color(.primary))
        }
    }
}

// MARK: - R-R Tachogram (with mean ± SD reference band)

struct TachogramChartView: View {
    let results: HRVResults

    @State private var showRefBand = true

    private struct RRPoint: Identifiable {
        let id = UUID()
        let time: Float
        let interval: Float
    }

    private var dataPoints: [RRPoint] {
        zip(results.rrTimes, results.rrIntervals).map { RRPoint(time: $0, interval: $1) }
    }

    private var meanRR: Float {
        guard !results.rrIntervals.isEmpty else { return 0 }
        return results.rrIntervals.reduce(0, +) / Float(results.rrIntervals.count)
    }

    private var sdRR: Float { results.sdnn }

    var body: some View {
        VStack(spacing: 6) {
            Chart {
                // Mean ± 1 SD reference band
                if showRefBand {
                    RectangleMark(
                        yStart: .value("", meanRR - sdRR),
                        yEnd: .value("", meanRR + sdRR)
                    )
                    .foregroundStyle(Color.green.opacity(0.08))

                    // Mean line
                    RuleMark(y: .value("Mean", meanRR))
                        .foregroundStyle(Color.green.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("Mean")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        }
                }

                // Data line
                ForEach(dataPoints) { point in
                    LineMark(
                        x: .value("Time (s)", point.time),
                        y: .value("RR (ms)", point.interval)
                    )
                    .foregroundStyle(Color.red.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartXAxisLabel {
                Text("Time (seconds)")
                    .font(.system(size: 13, weight: .medium))
            }
            .chartYAxisLabel {
                Text("R-R Interval (ms)")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(height: 220)

            // Controls
            HStack {
                Toggle(isOn: $showRefBand) {
                    Label("Mean \u{00B1} SD", systemImage: "lines.measurement.horizontal")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                // Summary stats
                Text("Mean: \(String(format: "%.0f", meanRR)) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("SD: \(String(format: "%.0f", sdRR)) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - HRV Frequency Spectrum (with log scale toggle)

struct HRVSpectrumChartView: View {
    let results: HRVResults

    @State private var useLogScale = false

    private struct SpecPoint: Identifiable {
        let id = UUID()
        let freq: Float
        let power: Float
        let logPower: Float
    }

    private var dataPoints: [SpecPoint] {
        guard results.hrvFreqs.count == results.hrvPSD.count else { return [] }
        return zip(results.hrvFreqs, results.hrvPSD)
            .filter { $0.0 >= 0.003 && $0.0 <= 0.45 }
            .map { SpecPoint(freq: $0, power: $1, logPower: $1 > 0 ? log10($1) : -3) }
    }

    /// Peak frequency in LF band
    private var lfPeakFreq: Float? {
        let lfPoints = dataPoints.filter { $0.freq >= Constants.lfBand.low && $0.freq <= Constants.lfBand.high }
        return lfPoints.max(by: { $0.power < $1.power })?.freq
    }

    /// Peak frequency in HF band
    private var hfPeakFreq: Float? {
        let hfPoints = dataPoints.filter { $0.freq >= Constants.hfBand.low && $0.freq <= Constants.hfBand.high }
        return hfPoints.max(by: { $0.power < $1.power })?.freq
    }

    var body: some View {
        VStack(spacing: 6) {
            Chart {
                // LF band shading (0.04-0.15 Hz)
                RectangleMark(
                    xStart: .value("", Constants.lfBand.low),
                    xEnd: .value("", Constants.lfBand.high),
                    yStart: nil, yEnd: nil
                )
                .foregroundStyle(Color.blue.opacity(0.08))

                // HF band shading (0.15-0.4 Hz)
                RectangleMark(
                    xStart: .value("", Constants.hfBand.low),
                    xEnd: .value("", Constants.hfBand.high),
                    yStart: nil, yEnd: nil
                )
                .foregroundStyle(Color.green.opacity(0.08))

                // PSD curve
                ForEach(dataPoints) { point in
                    let yValue = useLogScale ? point.logPower : point.power

                    AreaMark(
                        x: .value("Freq", point.freq),
                        y: .value("Power", yValue)
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [Color.purple.opacity(0.3), Color.purple.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom)
                    )

                    LineMark(
                        x: .value("Freq", point.freq),
                        y: .value("Power", yValue)
                    )
                    .foregroundStyle(Color.purple)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                // LF/HF band labels
                if lfPeakFreq != nil {
                    PointMark(x: .value("", 0.095), y: .value("", useLogScale ? (dataPoints.first { $0.freq >= 0.095 }?.logPower ?? 0) * 0.1 : (dataPoints.first { $0.freq >= 0.095 }?.power ?? 0) * 0.1))
                        .annotation(position: .top) {
                            Text("LF").font(.system(size: 13, weight: .bold)).foregroundColor(.blue)
                        }
                        .opacity(0)
                }
                if hfPeakFreq != nil {
                    PointMark(x: .value("", 0.275), y: .value("", useLogScale ? (dataPoints.first { $0.freq >= 0.275 }?.logPower ?? 0) * 0.1 : (dataPoints.first { $0.freq >= 0.275 }?.power ?? 0) * 0.1))
                        .annotation(position: .top) {
                            Text("HF").font(.system(size: 13, weight: .bold)).foregroundColor(.green)
                        }
                        .opacity(0)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartXAxisLabel {
                Text("Frequency (Hz)")
                    .font(.system(size: 13, weight: .medium))
            }
            .chartYAxisLabel {
                Text(useLogScale ? "log\u{2081}\u{2080} Power" : "Power (ms\u{00B2}/Hz)")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(height: 220)

            // Controls
            HStack {
                Toggle(isOn: $useLogScale) {
                    Label("Log Scale", systemImage: "function")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                if let lfPeak = lfPeakFreq {
                    Text("LF peak: \(String(format: "%.3f", lfPeak)) Hz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.blue)
                }
                if let hfPeak = hfPeakFreq {
                    Text("HF peak: \(String(format: "%.3f", hfPeak)) Hz")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Poincaré Plot (with SD1/SD2 ellipse overlay)

struct PoincareChartView: View {
    let results: HRVResults

    @State private var showEllipse = true

    private struct PoinPoint: Identifiable {
        let id = UUID()
        let rrN: Float
        let rrN1: Float
        let zone: Int  // 1 = inside 1σ, 2 = 1σ–2σ, 3 = 2σ–3σ, 4 = outside 3σ
    }

    /// Visual styles for each sigma level (rendered outermost-first for correct layering).
    private struct SigmaLevel {
        let multiplier: Float
        let label: String
        let opacity: Double
        let lineWidth: CGFloat
        let dash: [CGFloat]
    }

    private static let sigmaLevels: [SigmaLevel] = [
        SigmaLevel(multiplier: 1, label: "1\u{03C3}", opacity: 0.9, lineWidth: 2.5, dash: []),
        SigmaLevel(multiplier: 2, label: "2\u{03C3}", opacity: 0.5, lineWidth: 1.5, dash: [6, 4]),
        SigmaLevel(multiplier: 3, label: "3\u{03C3}", opacity: 0.3, lineWidth: 1.0, dash: [3, 3]),
    ]

    /// Ellipse point for plotting
    private struct EllipsePoint: Identifiable {
        let id: Int
        let x: Float
        let y: Float
    }

    /// Mean of RR[n] series (precise center for the Poincaré ellipse).
    private var meanRR: Float {
        guard !results.rrN.isEmpty else { return 0 }
        return results.rrN.reduce(0, +) / Float(results.rrN.count)
    }

    /// Zone classification results for multi-sigma analysis.
    private struct ZoneAnalysis {
        let points: [PoinPoint]
        let zone1Count: Int   // inside 1σ
        let zone2Count: Int   // between 1σ and 2σ
        let zone3Count: Int   // between 2σ and 3σ
        let outsideCount: Int // outside 3σ
    }

    /// Pre-computed analysis: data points with 4-zone classification.
    /// Uses normalized elliptical distance: d ≤ 1 → 1σ, d ≤ 4 → 2σ, d ≤ 9 → 3σ.
    private var analysis: ZoneAnalysis {
        let center = meanRR
        let sd1 = results.sd1
        let sd2 = results.sd2
        let canClassify = sd1 > 0 && sd2 > 0
        let sq2 = Float(2).squareRoot()
        let sd1sq = sd1 * sd1
        let sd2sq = sd2 * sd2

        var z1 = 0, z2 = 0, z3 = 0, zOut = 0
        let points: [PoinPoint] = zip(results.rrN, results.rrN1).map { rrN, rrN1 in
            var zone = 1
            if canClassify {
                let dx = rrN - center
                let dy = rrN1 - center
                let rx = (dx + dy) / sq2
                let ry = (-dx + dy) / sq2
                let d = (rx * rx) / sd2sq + (ry * ry) / sd1sq
                if d <= 1.0 { zone = 1 }
                else if d <= 4.0 { zone = 2 }
                else if d <= 9.0 { zone = 3 }
                else { zone = 4 }
            }
            switch zone {
            case 1: z1 += 1
            case 2: z2 += 1
            case 3: z3 += 1
            default: zOut += 1
            }
            return PoinPoint(rrN: rrN, rrN1: rrN1, zone: zone)
        }
        return ZoneAnalysis(points: points, zone1Count: z1, zone2Count: z2,
                            zone3Count: z3, outsideCount: zOut)
    }

    private var dataPoints: [PoinPoint] { analysis.points }

    /// Color for each sigma zone.
    private func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return Color.green.opacity(0.5)
        case 2: return Color.yellow.opacity(0.6)
        case 3: return Color.orange.opacity(0.7)
        default: return Color.red.opacity(0.7)
        }
    }

    /// Data-driven axis range so the scatter fills the plot area
    private var axisRange: ClosedRange<Float> {
        let allValues = results.rrN + results.rrN1
        guard let lo = allValues.min(), let hi = allValues.max(), hi > lo else { return 0...1000 }
        let padding = max((hi - lo) * 0.15, 30)
        return (lo - padding)...(hi + padding)
    }

    /// Compute ellipse points for a given sigma level (centered at mean, rotated 45°).
    private func ellipsePoints(sigma: Float) -> [EllipsePoint] {
        guard results.sd1 > 0, results.sd2 > 0 else { return [] }
        let steps = 61  // 60 segments + close
        let cx = meanRR
        let cy = meanRR
        let cosA = Float(cos(Double.pi / 4))
        let sinA = Float(sin(Double.pi / 4))

        return (0..<steps).map { i in
            let angle = Float(i) / Float(steps - 1) * 2 * Float.pi
            let ex = results.sd2 * sigma * cos(angle)
            let ey = results.sd1 * sigma * sin(angle)
            let rx = ex * cosA - ey * sinA + cx
            let ry = ex * sinA + ey * cosA + cy
            return EllipsePoint(id: i, x: rx, y: ry)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Chart {
                // Identity line (uses data-driven axis range)
                LineMark(
                    x: .value("", axisRange.lowerBound), y: .value("", axisRange.lowerBound)
                )
                .foregroundStyle(Color.gray.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

                LineMark(
                    x: .value("", axisRange.upperBound), y: .value("", axisRange.upperBound)
                )
                .foregroundStyle(Color.gray.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 4]))

                // SD1/SD2 ellipses — 1σ, 2σ, 3σ (outermost first for layering)
                if showEllipse {
                    ForEach(Array(Self.sigmaLevels.reversed().enumerated()), id: \.offset) { _, sigma in
                        ForEach(ellipsePoints(sigma: sigma.multiplier)) { pt in
                            LineMark(
                                x: .value("EX", pt.x),
                                y: .value("EY", pt.y),
                                series: .value("Ellipse", "ellipse-\(sigma.label)")
                            )
                            .foregroundStyle(Color.cyan.opacity(sigma.opacity))
                            .lineStyle(StrokeStyle(lineWidth: sigma.lineWidth, dash: sigma.dash))
                        }
                    }
                }

                // Data points — green if inside ellipse, orange if outside
                ForEach(dataPoints) { point in
                    PointMark(
                        x: .value("RR[n] (ms)", point.rrN),
                        y: .value("RR[n+1] (ms)", point.rrN1)
                    )
                    .symbolSize(16)
                    .foregroundStyle(zoneColor(point.zone))
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartXAxisLabel {
                Text("RR\u{2099} (ms)")
                    .font(.system(size: 13, weight: .medium))
            }
            .chartYAxisLabel {
                Text("RR\u{2099}\u{208A}\u{2081} (ms)")
                    .font(.system(size: 13, weight: .medium))
            }
            .chartXScale(domain: axisRange)
            .chartYScale(domain: axisRange)
            .chartLegend(.hidden)
            .frame(height: 300)
            .overlay(alignment: .topLeading) {
                let a = analysis
                let total = a.zone1Count + a.zone2Count + a.zone3Count + a.outsideCount
                let pct = { (count: Int) -> String in
                    total > 0 ? String(format: "%.0f", Float(count) / Float(total) * 100) : "0"
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.cyan)
                            .frame(width: 12, height: 3)
                        Text("SD1: \(String(format: "%.1f", results.sd1)) ms")
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.cyan)
                            .frame(width: 12, height: 3)
                        Text("SD2: \(String(format: "%.1f", results.sd2)) ms")
                    }
                    if results.sd1 > 0 {
                        Text("SD2/SD1: \(String(format: "%.2f", results.sd2 / results.sd1))")
                    }
                    Divider().frame(width: 140)
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("1\u{03C3}: \(a.zone1Count) (\(pct(a.zone1Count))%)")
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.yellow).frame(width: 7, height: 7)
                        Text("2\u{03C3}: \(a.zone2Count) (\(pct(a.zone2Count))%)")
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("3\u{03C3}: \(a.zone3Count) (\(pct(a.zone3Count))%)")
                    }
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("Out: \(a.outsideCount) (\(pct(a.outsideCount))%)")
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .padding(10)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .padding(10)
            }

            // Controls
            HStack {
                Toggle(isOn: $showEllipse) {
                    Label("SD1/SD2 Ellipses (1\u{2013}3\u{03C3})", systemImage: "oval")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("SD1 (vagal) \u{2022} SD2 (total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Heart-Brain Coherence Chart (with sort toggle and mean threshold)

struct HeartBrainCoherenceChartView: View {
    let results: HRVResults

    @State private var sortByValue = false
    @State private var selectedBand: String = Constants.heartBrainCoherenceBands.last?.name ?? "Alpha"

    private struct CohPoint: Identifiable {
        let id = UUID()
        let channel: String
        let coherence: Float
    }

    private var dataPoints: [CohPoint] {
        let bandData = results.heartBrainCoherenceByBand[selectedBand] ?? [:]
        let points = Constants.standard1020Channels.compactMap { ch -> CohPoint? in
            guard let coh = bandData[ch] else { return nil }
            return CohPoint(channel: ch, coherence: coh)
        }
        if sortByValue {
            return points.sorted { $0.coherence > $1.coherence }
        }
        return points
    }

    /// Channel ordering for the x-axis (maintains sort when toggle changes)
    private var channelOrder: [String] {
        dataPoints.map(\.channel)
    }

    private var currentOverallScore: Float {
        results.coherenceScoreByBand[selectedBand] ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            // Band selector (segmented control)
            Picker("EEG Band", selection: $selectedBand) {
                ForEach(Constants.heartBrainCoherenceBands, id: \.name) { band in
                    Text(band.name).tag(band.name)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 4)

            // Best band indicator
            if results.coherenceBestBand != selectedBand {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption2)
                    Text("Strongest coupling in \(results.coherenceBestBand) band")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Vertical bar chart — channel names on X-axis with high-contrast labels
            Chart {
                // Mean coherence threshold line
                RuleMark(y: .value("Mean", currentOverallScore))
                    .foregroundStyle(Color.orange.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .annotation(position: .trailing, alignment: .leading) {
                        Text("Mean")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }

                ForEach(dataPoints) { point in
                    BarMark(
                        x: .value("Channel", point.channel),
                        y: .value("Coherence", point.coherence)
                    )
                    .foregroundStyle(coherenceColor(point.coherence))
                }
            }
            .chartXScale(domain: channelOrder)
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel(orientation: .vertical)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel()
                        .font(.system(size: 12))
                }
            }
            .chartYAxisLabel {
                Text("Coherence (\(selectedBand) → LF)")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(height: 260)

            // Controls + overall score
            HStack(spacing: 12) {
                Toggle(isOn: $sortByValue) {
                    Label("Sort by Value", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                // Overall score badge
                HStack(spacing: 6) {
                    Image(systemName: "heart.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                    Text("Overall:")
                        .font(.subheadline)
                    Text(String(format: "%.3f", currentOverallScore))
                        .font(.subheadline.monospacedDigit().bold())
                    Text(coherenceInterpretation)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(coherenceInterpretationColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            .padding(.horizontal, 4)
        }
    }

    private var maxCoherence: Float {
        let maxVal = dataPoints.map(\.coherence).max() ?? 0.1
        return max(maxVal, 0.1)
    }

    private var coherenceInterpretation: String {
        let score = currentOverallScore
        if score >= 0.5 { return "High" }
        if score >= 0.3 { return "Moderate" }
        if score >= 0.1 { return "Low" }
        return "Very Low"
    }

    private var coherenceInterpretationColor: Color {
        let score = currentOverallScore
        if score >= 0.5 { return .green }
        if score >= 0.3 { return .blue }
        if score >= 0.1 { return .orange }
        return .secondary
    }

    private func coherenceColor(_ value: Float) -> Color {
        let maxVal = maxCoherence
        let t = maxVal > 0 ? Double(min(value / maxVal, 1.0)) : 0
        return Color(
            red: 0.2 + 0.6 * t,
            green: 0.3 * (1 - t) + 0.1 * t,
            blue: 0.8 * (1 - t)
        )
    }
}
