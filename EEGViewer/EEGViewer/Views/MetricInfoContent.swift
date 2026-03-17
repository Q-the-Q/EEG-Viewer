// MetricInfoContent.swift
// Centralized educational descriptions for Heart dashboard metrics and charts,
// plus a reusable InfoButton view that presents popover explanations.

import SwiftUI

// MARK: - Info Content Definitions

/// Namespace holding all educational text for Heart dashboard metrics and charts.
enum MetricInfoContent {

    struct InfoItem {
        let title: String
        let description: String
    }

    // MARK: Section Headers (Charts)

    static let ecgWaveform = InfoItem(
        title: "ECG Waveform",
        description: "The electrocardiogram (ECG) shows the electrical activity of the heart over time. Each heartbeat produces a characteristic PQRST waveform. The R-peaks (marked with red triangles) represent ventricular depolarization and are used to calculate beat-to-beat (R-R) intervals for HRV analysis. An inverted ECG may occur due to electrode placement and is automatically corrected for display."
    )

    static let hrvMetrics = InfoItem(
        title: "HRV Metrics",
        description: "Heart rate variability (HRV) measures the variation in time between consecutive heartbeats. Higher HRV generally indicates better autonomic nervous system flexibility and cardiovascular health. These metrics capture both time-domain (beat-to-beat timing) and frequency-domain (oscillatory patterns) aspects of cardiac variability."
    )

    static let tachogram = InfoItem(
        title: "R-R Interval Tachogram",
        description: "The tachogram plots each R-R interval (time between consecutive heartbeats, in milliseconds) over the recording duration. It visualizes beat-to-beat variability over time. The green shaded band shows the mean R-R interval \u{00B1} one standard deviation (SDNN). Intervals outside this band indicate moments of unusually high or low heart rate."
    )

    static let hrvSpectrum = InfoItem(
        title: "HRV Frequency Spectrum",
        description: "The power spectral density (PSD) of R-R interval variability, computed via Welch\u{2019}s method. The Low Frequency band (LF, 0.04\u{2013}0.15 Hz, blue) reflects both sympathetic and parasympathetic activity, including baroreflex oscillations. The High Frequency band (HF, 0.15\u{2013}0.4 Hz, green) primarily reflects parasympathetic (vagal) tone and respiratory sinus arrhythmia."
    )

    static let poincarePlot = InfoItem(
        title: "Poincar\u{00E9} Plot",
        description: "A scatter diagram where each R-R interval is plotted against the next. Points along the identity line (diagonal) indicate consecutive beats with similar timing. SD1 (perpendicular to the identity line) captures short-term, beat-to-beat variability related to vagal tone. SD2 (along the identity line) reflects longer-term variability. The ellipses show 1\u{03C3}, 2\u{03C3}, and 3\u{03C3} contours. For a bivariate normal distribution, these capture approximately 39%, 87%, and 99% of points respectively."
    )

    static let heartBrainCoherence = InfoItem(
        title: "Heart-Brain Coherence",
        description: "Measures the synchronization between cardiac rhythm (R-R interval variations) and EEG band power envelopes in the low-frequency band (0.04\u{2013}0.15 Hz). Three EEG bands are analyzed: Delta (1\u{2013}4 Hz, autonomic/homeostatic), Theta (4\u{2013}8 Hz, limbic/emotional), and Alpha (8\u{2013}13 Hz, cortical relaxation). EEG epochs with artifacts (>100 \u{00b5}V peak-to-peak) are automatically rejected before analysis. Higher coherence values indicate stronger coupling between cardiac and neural oscillations, associated with focused attention, positive emotional states, and effective self-regulation."
    )

    // MARK: Individual Metrics

    static let meanHR = InfoItem(
        title: "Mean Heart Rate",
        description: "The average number of heartbeats per minute across the recording. Normal resting heart rate for adults is typically 60\u{2013}100 BPM. Below 60 BPM (bradycardia) is common in athletes and well-conditioned individuals. Above 100 BPM (tachycardia) may indicate stress, anxiety, or cardiac conditions."
    )

    static let sdnn = InfoItem(
        title: "SDNN",
        description: "Standard Deviation of Normal-to-Normal intervals. SDNN reflects overall HRV and is influenced by both sympathetic and parasympathetic branches of the autonomic nervous system. It represents total variability over the recording period. Typical short-term values are 50\u{2013}150 ms. Low SDNN is associated with reduced cardiac adaptability and has prognostic significance in cardiac risk assessment."
    )

    static let rmssd = InfoItem(
        title: "RMSSD",
        description: "Root Mean Square of Successive Differences between adjacent R-R intervals. RMSSD is the primary time-domain measure of vagal (parasympathetic) tone and reflects short-term, beat-to-beat variability. Typical values are 20\u{2013}75 ms. Low RMSSD suggests reduced parasympathetic activity, while higher values indicate robust vagal modulation."
    )

    static let pnn50 = InfoItem(
        title: "pNN50",
        description: "The percentage of successive R-R intervals that differ by more than 50 milliseconds. Like RMSSD, pNN50 primarily reflects parasympathetic (vagal) activity. Typical values are 5\u{2013}40%. Higher values indicate greater vagal influence on heart rate. It is less sensitive to artifacts than some other HRV measures."
    )

    static let ansBalance = InfoItem(
        title: "ANS Balance",
        description: "Autonomic Nervous System Balance shows the relative contribution of sympathetic (LF) versus parasympathetic (HF) activity to heart rate variability. The bar displays the proportion of total spectral power in each band. Sympathetic dominance (more LF) is typical during stress or physical activity; parasympathetic dominance (more HF) is typical during rest and relaxation."
    )

    static let lfHfRatio = InfoItem(
        title: "LF/HF Ratio",
        description: "The ratio of Low Frequency power to High Frequency power. Traditionally interpreted as an index of sympathovagal balance, though this interpretation is debated in current literature. Typical values range from 0.5 to 5.0. Higher ratios suggest relative sympathetic dominance; lower ratios suggest parasympathetic dominance. Context (posture, activity, breathing) strongly influences this metric."
    )

    static let lfPower = InfoItem(
        title: "LF Power",
        description: "Low Frequency power (0.04\u{2013}0.15 Hz) in the HRV spectrum, measured in ms\u{00B2}. LF power reflects a mixture of sympathetic and parasympathetic activity, including baroreflex-mediated blood pressure oscillations (Mayer waves at ~0.1 Hz). It is influenced by both autonomic tone and respiratory patterns."
    )

    static let hfPower = InfoItem(
        title: "HF Power",
        description: "High Frequency power (0.15\u{2013}0.4 Hz) in the HRV spectrum, measured in ms\u{00B2}. HF power is primarily driven by parasympathetic (vagal) activity and respiratory sinus arrhythmia \u{2014} the natural variation in heart rate that occurs with each breathing cycle. It is considered the most reliable spectral index of vagal tone."
    )
}

// MARK: - Reusable Info Button View

/// A small "i" circle button that presents a popover with educational content.
/// On iPad, this renders as a floating bubble with an arrow.
/// On iPhone, `.popover()` automatically degrades to a sheet.
struct InfoButton: View {
    let info: MetricInfoContent.InfoItem

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(info.title)
                    .font(.headline)
                Text(info.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(idealWidth: 320, maxWidth: 360)
        }
    }
}
