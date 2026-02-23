// QEEGDashboard.swift
// qEEG Analysis dashboard: spectra, topomaps, coherence, asymmetry, peak frequencies.

import SwiftUI

struct QEEGDashboard: View {
    let edfData: EDFData
    @ObservedObject var analyzer: QEEGAnalyzer

    var body: some View {
        Group {
            if analyzer.isAnalyzing {
                analysisProgress
            } else if let results = analyzer.results {
                ScrollView {
                    VStack(spacing: 20) {
                        // Artifact stats
                        artifactStatsBar(results: results)

                        // Row 1: Magnitude Spectra (3 regions)
                        Text("Magnitude Spectra")
                            .font(.headline)
                        spectraRow(results: results)

                        Divider()

                        // Row 2: Topographic Maps (4 bands)
                        Text("Topographic Z-Score Maps")
                            .font(.headline)
                        topoRow(results: results)

                        Divider()

                        // Row 3: Coherence + Asymmetry
                        HStack(alignment: .top, spacing: 16) {
                            CoherenceHeatmapView(results: results)
                                .frame(minHeight: 300)

                            AsymmetryChartView(results: results)
                                .frame(minHeight: 300)
                        }

                        Divider()

                        // Row 4: Peak Frequencies
                        peakFrequencyTable(results: results)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 16) {
                    Text("Ready to analyze")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await analyzer.analyze(edfData: edfData) }
                    } label: {
                        Label("Run qEEG Analysis", systemImage: "waveform.path.ecg")
                            .font(.title3)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Analysis Progress

    private var analysisProgress: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(analyzer.progress))
                .progressViewStyle(.linear)
                .frame(width: 300)

            Text(analyzer.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(analyzer.progress * 100))%")
                .font(.title2.monospacedDigit())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Artifact Stats

    private func artifactStatsBar(results: QEEGResults) -> some View {
        let stats = results.artifactStats
        let pct = stats.totalEpochs > 0
            ? Float(stats.rejectedEpochs) / Float(stats.totalEpochs) * 100
            : 0

        return HStack {
            Spacer()
            Text("Epochs: \(stats.cleanEpochs)/\(stats.totalEpochs) clean (\(String(format: "%.1f", pct))% rejected)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Spectra Row

    private func spectraRow(results: QEEGResults) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(["Frontal", "Central", "Posterior"], id: \.self) { region in
                let channelNames = Constants.regionMap[region] ?? []
                SpectraChartView(results: results, region: region, channels: channelNames)
                    .frame(minHeight: 200)
            }
        }
    }

    // MARK: - Topomap Row

    private func topoRow(results: QEEGResults) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Constants.freqBands, id: \.name) { band in
                if let zs = results.zscores[band.name] {
                    TopoMapView(
                        zscores: zs,
                        channels: results.channels,
                        bandName: band.name,
                        freqRange: "\(Int(band.low))-\(Int(band.high)) Hz"
                    )
                }
            }
            TopoColorBar()
                .frame(width: 30, height: 150)
        }
    }

    // MARK: - Peak Frequency Table

    private func peakFrequencyTable(results: QEEGResults) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peak Frequencies")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible(minimum: 60)),
                GridItem(.flexible(minimum: 80)),
                GridItem(.flexible(minimum: 80)),
            ], spacing: 4) {
                // Header
                Text("Channel").font(.caption.bold())
                Text("Alpha Peak").font(.caption.bold())
                Text("Dominant").font(.caption.bold())

                ForEach(results.peakFreqs, id: \.channel) { peak in
                    Text(peak.channel).font(.caption)
                    Text(String(format: "%.1f Hz", peak.alphaPeak)).font(.caption.monospacedDigit())
                    Text(String(format: "%.1f Hz", peak.dominant)).font(.caption.monospacedDigit())
                }
            }
        }
    }
}
