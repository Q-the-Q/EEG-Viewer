// AsymmetryChartView.swift
// Hemispheric asymmetry bar chart: ln(Right) - ln(Left) for 8 homologous pairs.
// Band selection is controlled externally (from QEEGDashboard) so all recordings share the same band.

import SwiftUI
import Charts

struct AsymmetryChartView: View {
    let results: QEEGResults
    /// Which frequency band to display. Controlled by the parent view.
    var selectedBand: String = "Alpha"

    var body: some View {
        VStack(spacing: 8) {
            Text("Hemispheric Asymmetry")
                .font(.caption.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pairs = results.asymmetry[selectedBand] {
                Chart(pairs, id: \.pair) { item in
                    BarMark(
                        x: .value("Asymmetry", item.value),
                        y: .value("Pair", item.pair)
                    )
                    .foregroundStyle(item.value >= 0
                        ? Color(red: 0.8, green: 0.267, blue: 0.267)    // Red: Right > Left
                        : Color(red: 0.267, green: 0.267, blue: 0.8))   // Blue: Left > Right

                    RuleMark(x: .value("", 0))
                        .foregroundStyle(.primary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartXAxisLabel("ln(Right) - ln(Left)")
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Float.self) {
                                Text(String(format: "%.2f", v))
                                    .font(.system(size: 8))
                            }
                        }
                    }
                }
            }
        }
    }
}
