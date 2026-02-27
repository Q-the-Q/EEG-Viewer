// QEEGDashboard.swift
// qEEG Analysis dashboard: spectra, topomaps, coherence, asymmetry, peak frequencies.
// Supports comparing up to 3 EDF recordings (1 primary + 2 comparisons).

import SwiftUI
import Combine

// MARK: - Comparison Manager

/// Manages comparison EDF sessions for side-by-side analysis.
@MainActor
class ComparisonManager: ObservableObject {
    struct Session: Identifiable {
        let id = UUID()
        let edfData: EDFData
        let filename: String
        let analyzer: QEEGAnalyzer
        var analysisTask: Task<Void, Never>?
    }

    @Published var sessions: [Session] = []
    /// Per-session Combine sinks keyed by session ID — cleaned up on removal.
    private var sessionCancellables: [UUID: AnyCancellable] = [:]

    var canAddMore: Bool { sessions.count < 2 }

    func addSession(edfData: EDFData, filename: String) {
        let analyzer = QEEGAnalyzer()
        var session = Session(edfData: edfData, filename: filename, analyzer: analyzer)

        // Forward analyzer state changes to trigger dashboard re-renders
        sessionCancellables[session.id] = analyzer.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        session.analysisTask = Task { await analyzer.analyze(edfData: edfData, filename: filename) }
        sessions.append(session)
    }

    /// Remove a session by its stable ID. Cancels in-flight analysis and cleans up sink.
    func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].analysisTask?.cancel()
        sessionCancellables.removeValue(forKey: id)
        sessions.remove(at: index)
    }

    func removeAll() {
        for session in sessions { session.analysisTask?.cancel() }
        sessions.removeAll()
        sessionCancellables.removeAll()
    }
}

// MARK: - Dashboard View

struct QEEGDashboard: View {
    let edfData: EDFData
    @ObservedObject var analyzer: QEEGAnalyzer
    let primaryFilename: String
    @StateObject private var comparisonManager = ComparisonManager()
    @State private var showComparisonPicker = false
    @State private var comparisonError: String?
    @State private var showShareSheet = false
    @State private var pdfData: Data?
    @State private var isExporting = false
    @State private var selectedCoherenceBand: String = "Alpha"
    @State private var isLoadingComparison = false

    /// All available results: primary + comparisons (only those that have completed analysis).
    /// Each entry includes a stable sessionID (nil for primary) for safe removal.
    private var allResults: [(index: Int, filename: String, results: QEEGResults, sessionID: UUID?)] {
        var list = [(index: Int, filename: String, results: QEEGResults, sessionID: UUID?)]()
        if let r = analyzer.results {
            list.append((index: 1, filename: primaryFilename, results: r, sessionID: nil))
        }
        for (i, session) in comparisonManager.sessions.enumerated() {
            if let r = session.analyzer.results {
                list.append((index: i + 2, filename: session.filename, results: r, sessionID: session.id))
            }
        }
        return list
    }

    private var hasComparisons: Bool {
        !comparisonManager.sessions.isEmpty
    }

    var body: some View {
        Group {
            if analyzer.isAnalyzing {
                analysisProgress(analyzer: analyzer, label: "Recording 1")
            } else if analyzer.results != nil {
                dashboardContent
            } else {
                readyToAnalyzeView
            }
        }
        .sheet(isPresented: $showComparisonPicker) {
            DocumentPicker { url in
                loadComparisonFile(url: url)
            }
        }
        .alert("Comparison Error", isPresented: .init(
            get: { comparisonError != nil },
            set: { if !$0 { comparisonError = nil } }
        )) {
            Button("OK") { comparisonError = nil }
        } message: {
            Text(comparisonError ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let pdfData {
                ShareSheet(items: [pdfData])
            }
        }
    }

    // MARK: - Dashboard Content

    private var dashboardContent: some View {
        let results = allResults
        let sharedSpectraMaxY = computeSharedSpectraMaxY(allResults: results)

        return ScrollView {
            VStack(spacing: 20) {
                // Add Comparison button
                addComparisonButton

                // Comparison progress indicators (for comparisons still analyzing)
                comparisonProgressSection

                // ── Magnitude Spectra ──────────────────────────
                sectionHeader("Magnitude Spectra")
                ForEach(Array(results.enumerated()), id: \.element.index) { _, entry in
                    if hasComparisons {
                        recordingLabel(index: entry.index, filename: entry.filename, sessionID: entry.sessionID)
                    }
                    artifactStatsBar(results: entry.results)
                    spectraRow(results: entry.results, sharedMaxY: sharedSpectraMaxY)
                }

                Divider()

                // ── Topographic Z-Score Maps ──────────────────
                sectionHeader("Topographic Z-Score Maps")
                ForEach(Array(results.enumerated()), id: \.element.index) { _, entry in
                    if hasComparisons {
                        recordingLabel(index: entry.index, filename: entry.filename, sessionID: entry.sessionID)
                    }
                    topoRow(results: entry.results)
                }

                Divider()

                // ── Coherence + Asymmetry ─────────────────────
                HStack {
                    sectionHeader("Coherence & Asymmetry")
                    Spacer()
                    Picker("Band", selection: $selectedCoherenceBand) {
                        ForEach(Constants.freqBands, id: \.name) { band in
                            Text(band.name).tag(band.name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                ForEach(Array(results.enumerated()), id: \.element.index) { _, entry in
                    if hasComparisons {
                        recordingLabel(index: entry.index, filename: entry.filename, sessionID: entry.sessionID)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        CoherenceHeatmapView(results: entry.results,
                                             selectedBand: selectedCoherenceBand)
                            .frame(minHeight: 300)

                        AsymmetryChartView(results: entry.results,
                                           selectedBand: selectedCoherenceBand)
                            .frame(minHeight: 300)
                    }
                }

                Divider()

                // ── Peak Frequencies ──────────────────────────
                sectionHeader("Peak Frequencies")
                ForEach(Array(results.enumerated()), id: \.element.index) { _, entry in
                    if hasComparisons {
                        recordingLabel(index: entry.index, filename: entry.filename, sessionID: entry.sessionID)
                    }
                    peakFrequencyTable(results: entry.results)
                }
            }
            .padding()
        }
    }

    // MARK: - Ready State

    private var readyToAnalyzeView: some View {
        VStack(spacing: 16) {
            Text("Ready to analyze")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button {
                Task { await analyzer.analyze(edfData: edfData, filename: primaryFilename) }
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

    // MARK: - Comparison Progress

    private var comparisonProgressSection: some View {
        VStack(spacing: 8) {
            // File loading indicator (before analysis starts)
            if isLoadingComparison {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading comparison file…")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(8)
            }

            // Analysis progress indicators
            ForEach(comparisonManager.sessions) { session in
                if session.analyzer.isAnalyzing {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Analyzing: \(session.filename)")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        ProgressView(value: Double(session.analyzer.progress))
                            .progressViewStyle(.linear)
                        Text(session.analyzer.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - Analysis Progress (Primary)

    private func analysisProgress(analyzer: QEEGAnalyzer, label: String) -> some View {
        VStack(spacing: 16) {
            Text(label)
                .font(.headline)

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

    // MARK: - Add Comparison Button

    private var addComparisonButton: some View {
        HStack {
            // Export PDF button
            Button {
                exportPDF()
            } label: {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Export PDF", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isExporting)

            Spacer()

            Button {
                showComparisonPicker = true
            } label: {
                Label("Add Comparison EDF", systemImage: "plus.rectangle.on.rectangle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .disabled(!comparisonManager.canAddMore || isLoadingComparison)
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    // MARK: - Recording Label

    private func recordingLabel(index: Int, filename: String, sessionID: UUID?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording \(index)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text(filename)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Show remove button for comparisons (sessionID != nil)
            if let id = sessionID {
                Button {
                    comparisonManager.removeSession(id: id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
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

    private func spectraRow(results: QEEGResults, sharedMaxY: Float) -> some View {
        let regions = ["Frontal", "Central", "Posterior"]

        return HStack(alignment: .top, spacing: 12) {
            ForEach(regions, id: \.self) { region in
                let channelNames = Constants.regionMap[region] ?? []
                SpectraChartView(results: results, region: region,
                                 channels: channelNames, sharedMaxY: sharedMaxY)
                    .frame(minHeight: 200)
            }
        }
    }

    /// Compute shared spectra Y-axis max across ALL recordings.
    private func computeSharedSpectraMaxY(allResults: [(index: Int, filename: String, results: QEEGResults, sessionID: UUID?)]) -> Float {
        let regions = ["Frontal", "Central", "Posterior"]
        var globalPeak: Float = 0
        for entry in allResults {
            for region in regions {
                let chs = Constants.regionMap[region] ?? []
                let peak = SpectraChartView.peakAmplitude(results: entry.results, channels: chs)
                globalPeak = max(globalPeak, peak)
            }
        }
        return globalPeak + 0.2
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

    // MARK: - Comparison File Loading

    private func loadComparisonFile(url: URL) {
        isLoadingComparison = true
        Task {
            do {
                // Read EDF on background thread to avoid blocking UI
                let data = try await Task.detached(priority: .userInitiated) {
                    try EDFReader.read(url: url)
                }.value
                let filename = url.lastPathComponent
                comparisonManager.addSession(edfData: data, filename: filename)
            } catch {
                comparisonError = error.localizedDescription
            }
            isLoadingComparison = false
        }
    }

    // MARK: - PDF Export

    private func exportPDF() {
        isExporting = true
        // Strip sessionID — PDFExporter doesn't need it
        let pdfResults = allResults.map { (index: $0.index, filename: $0.filename, results: $0.results) }
        let data = edfData
        // Wrap in Task so the run loop yields and the spinner actually renders.
        // ImageRenderer must run on main actor, but Task yields before starting work.
        Task { @MainActor in
            let pdf = PDFExporter.generateReport(allResults: pdfResults, edfData: data)
            self.pdfData = pdf
            self.isExporting = false
            self.showShareSheet = true
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
