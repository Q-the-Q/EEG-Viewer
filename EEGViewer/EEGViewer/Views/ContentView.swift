// ContentView.swift
// Main view with tab navigation, file picker, and data management.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var edfData: EDFData?
    @State private var loadedFilename: String = ""
    @State private var showFilePicker = false
    @State private var selectedTab = 0
    @State private var errorMessage: String?
    @State private var fileLoadID = UUID()
    @StateObject private var analyzer = QEEGAnalyzer()
    @StateObject private var hrvAnalyzer = HRVAnalyzer()
    @StateObject private var annotationStore = AnnotationStore()
    @State private var loadedFileURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let data = edfData {
                    TabView(selection: $selectedTab) {
                        WaveformView(edfData: data, annotationStore: annotationStore)
                            .tabItem { Label("Waveforms", systemImage: "waveform.path") }
                            .tag(0)

                        BandPowerView(edfData: data, annotationStore: annotationStore)
                            .tabItem { Label("Bands", systemImage: "chart.line.uptrend.xyaxis") }
                            .tag(1)

                        QEEGDashboard(edfData: data, analyzer: analyzer, primaryFilename: loadedFilename, annotationStore: annotationStore)
                            .tabItem { Label("qEEG", systemImage: "brain.head.profile") }
                            .tag(2)

                        BrainView3D(edfData: data, annotationStore: annotationStore)
                            .tabItem { Label("3D Brain", systemImage: "brain") }
                            .tag(3)

                        HeartDashboard(edfData: data, analyzer: hrvAnalyzer, primaryFilename: loadedFilename, annotationStore: annotationStore)
                            .tabItem { Label("\u{2764}\u{FE0F}", systemImage: "heart.fill") }
                            .tag(4)
                    }
                    .id(fileLoadID)
                } else {
                    welcomeView
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Open EDF", systemImage: "doc.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker { tempURL, originalURL in
                    loadFile(tempURL: tempURL, originalURL: originalURL)
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 80))
                .foregroundStyle(.blue)

            Text("EEG Viewer")
                .font(.largeTitle.bold())

            Text("Open an EDF file to begin analysis")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button {
                showFilePicker = true
            } label: {
                Label("Open EDF File", systemImage: "doc.badge.plus")
                    .font(.title3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func loadFile(tempURL: URL, originalURL: URL) {
        Task {
            do {
                // Parse EDF off the main thread — file I/O + Int16→Float conversion can
                // block for several seconds on large recordings.
                let data = try await Task.detached(priority: .userInitiated) {
                    try EDFReader.read(url: tempURL)
                }.value
                self.edfData = data
                self.loadedFileURL = originalURL
                self.annotationStore.load(for: originalURL)
                self.loadedFilename = originalURL.lastPathComponent
                self.errorMessage = nil
                // Reset analyzers so stale results from previous file are cleared
                self.analyzer.results = nil
                self.hrvAnalyzer.results = nil
                self.hrvAnalyzer.errorMessage = nil
                self.hrvAnalyzer.isAnalyzing = false
                // New ID forces SwiftUI to recreate all tab views (resets @State, re-fires .onAppear)
                self.fileLoadID = UUID()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Document Picker

/// Document picker that returns both a temp copy (for reading) and the original URL (for sidecar persistence).
struct DocumentPicker: UIViewControllerRepresentable {
    /// Callback: (tempURL for reading, originalURL for annotation sidecar)
    let onPick: (URL, URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.data])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL, URL) -> Void

        init(onPick: @escaping (URL, URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // Start accessing security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // Copy to temp location for reliable EDF reading
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)

            // Also copy annotation sidecar if it exists (while we still have security scope)
            let sidecarURL = AnnotationStore.annotationURL(for: url)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                let tempSidecar = AnnotationStore.annotationURL(for: tempURL)
                try? FileManager.default.removeItem(at: tempSidecar)
                try? FileManager.default.copyItem(at: sidecarURL, to: tempSidecar)
            }

            onPick(tempURL, url)
        }
    }
}
