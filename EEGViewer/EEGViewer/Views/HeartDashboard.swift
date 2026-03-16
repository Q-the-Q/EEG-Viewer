// HeartDashboard.swift
// Main Heart tab view: HRV analysis, ECG waveform, and heart-brain coherence.

import SwiftUI

struct HeartDashboard: View {
    let edfData: EDFData
    @ObservedObject var analyzer: HRVAnalyzer
    let primaryFilename: String
    @ObservedObject var annotationStore: AnnotationStore
    @State private var applyAnnotations = true

    var body: some View {
        Group {
            if !edfData.hasECG {
                noECGView
            } else if analyzer.isAnalyzing {
                analyzingView
            } else if let errorMessage = analyzer.errorMessage {
                errorView(errorMessage)
            } else if let results = analyzer.results {
                dashboardContent(results)
            } else {
                readyToAnalyzeView
            }
        }
    }

    // MARK: - States

    private var noECGView: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.slash")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No ECG Channel Found")
                .font(.title2.bold())

            Text("This EDF file does not contain an ECG or EKG channel.\nHeart rate variability and heart-brain coherence analysis require an ECG recording.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyToAnalyzeView: some View {
        VStack(spacing: 20) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Heart Analysis")
                .font(.title2.bold())

            Text("ECG channel detected: \(edfData.ecgChannelName ?? "ECG")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Annotation filter toggle
            Button {
                applyAnnotations.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: applyAnnotations ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    let count = annotationStore.excludedTimeRanges().count
                    Text(applyAnnotations && count > 0 ? "\(count) annotations excluded" : "No annotation filter")
                }
                .font(.caption)
                .foregroundColor(applyAnnotations ? .orange : .gray)
            }

            Button {
                Task {
                    let exclusions = applyAnnotations ? annotationStore.excludedTimeRanges() : []
                    await analyzer.analyze(edfData: edfData, filename: primaryFilename, exclusions: exclusions)
                }
            } label: {
                Label("Run Heart Analysis", systemImage: "heart.fill")
                    .font(.title3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var analyzingView: some View {
        VStack(spacing: 16) {
            ProgressView(value: analyzer.progress) {
                Text("Analyzing ECG...")
                    .font(.headline)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 300)

            Text(analyzer.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.heart")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Analysis Issue")
                .font(.title2.bold())

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                analyzer.errorMessage = nil
            } label: {
                Label("Try Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dashboard Content

    private func dashboardContent(_ results: HRVResults) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Heart Analysis")
                            .font(.title2.bold())
                        Text(primaryFilename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("\(results.rPeakIndices.count) R-peaks detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
                .padding(.horizontal)

                // Section: ECG Waveform (height adapts to amplitude scale)
                sectionHeader("ECG Waveform", systemImage: "waveform.path.ecg",
                             info: MetricInfoContent.ecgWaveform)
                ECGWaveformView(
                    ecgSignal: edfData.ecgData ?? [],
                    sfreq: edfData.sfreq,
                    rPeakIndices: results.rPeakIndices,
                    isInverted: results.ecgIsInverted
                )
                .padding(.horizontal)

                // Section: HRV Metrics
                sectionHeader("HRV Metrics", systemImage: "heart.text.square",
                             info: MetricInfoContent.hrvMetrics)
                HRVMetricsCard(results: results)
                    .padding(.horizontal)

                // Section: R-R Tachogram
                sectionHeader("R-R Interval Tachogram", systemImage: "chart.xyaxis.line",
                             info: MetricInfoContent.tachogram)
                TachogramChartView(results: results)
                    .padding(.horizontal)

                // Section: HRV Spectrum
                sectionHeader("HRV Frequency Spectrum", systemImage: "waveform.circle",
                             info: MetricInfoContent.hrvSpectrum)
                HRVSpectrumChartView(results: results)
                    .padding(.horizontal)

                // Section: Poincaré Plot
                sectionHeader("Poincar\u{00E9} Plot", systemImage: "circle.grid.cross",
                             info: MetricInfoContent.poincarePlot)
                PoincareChartView(results: results)
                    .padding(.horizontal)

                Divider()
                    .padding(.horizontal)

                // Section: Heart-Brain Coherence
                sectionHeader("Heart-Brain Coherence", systemImage: "brain.head.profile.fill",
                             info: MetricInfoContent.heartBrainCoherence)
                HeartBrainCoherenceChartView(results: results)
                    .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding(.top)
        }
    }

    private func sectionHeader(_ title: String, systemImage: String,
                               info: MetricInfoContent.InfoItem? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.red)
            Text(title)
                .font(.headline)
            if let info = info {
                InfoButton(info: info)
            }
        }
        .padding(.horizontal)
    }
}
