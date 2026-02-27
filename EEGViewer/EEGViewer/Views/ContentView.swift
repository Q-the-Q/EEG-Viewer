// ContentView.swift
// Main view with tab navigation, file picker, and data management.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var edfData: EDFData?
    @State private var showFilePicker = false
    @State private var selectedTab = 0
    @State private var errorMessage: String?
    @StateObject private var analyzer = QEEGAnalyzer()

    var body: some View {
        NavigationStack {
            Group {
                if let data = edfData {
                    TabView(selection: $selectedTab) {
                        WaveformView(edfData: data)
                            .tabItem { Label("EEG Waveform", systemImage: "waveform.path") }
                            .tag(0)

                        BandPowerView(edfData: data)
                            .tabItem { Label("Band Waveforms", systemImage: "chart.line.uptrend.xyaxis") }
                            .tag(1)

                        QEEGDashboard(edfData: data, analyzer: analyzer)
                            .tabItem { Label("qEEG Analysis", systemImage: "brain.head.profile") }
                            .tag(2)

                        BrainView3D(edfData: data)
                            .tabItem { Label("3D Brain", systemImage: "brain") }
                            .tag(3)
                    }
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
                if let data = edfData {
                    ToolbarItem(placement: .bottomBar) {
                        statusBar(data: data)
                    }
                }
            }
            .sheet(isPresented: $showFilePicker) {
                DocumentPicker { url in
                    loadFile(url: url)
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

    private func statusBar(data: EDFData) -> some View {
        let eegCount = data.eegIndices.count
        let hasECG = data.channelNames.contains(where: { $0.uppercased() == "ECG" || $0.uppercased() == "EKG" })
        let durMin = Int(data.duration) / 60
        let durSec = Int(data.duration) % 60

        return HStack(spacing: 16) {
            Text("\(eegCount) EEG channels")
            if hasECG { Text("+ ECG") }
            Divider().frame(height: 16)
            Text("\(Int(data.sfreq)) Hz")
            Divider().frame(height: 16)
            Text(String(format: "%02d:%02d duration", durMin, durSec))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func loadFile(url: URL) {
        do {
            let data = try EDFReader.read(url: url)
            self.edfData = data
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

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
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            // Start accessing security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            // Copy to temp location for reliable access
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.copyItem(at: url, to: tempURL)

            onPick(tempURL)
        }
    }
}
