// EEGAnnotation.swift
// Data model and persistence for EEG waveform annotations.

import SwiftUI
import UIKit

// MARK: - CodableColor

/// A Codable wrapper around SwiftUI Color, stored as RGBA components.
struct CodableColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ color: Color) {
        let uiColor = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - AnnotationLabel

/// A user-configurable label that can be applied to annotations.
struct AnnotationLabel: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var color: CodableColor
    var analysisMode: AnalysisMode

    /// How an annotation with this label should be handled during analysis.
    enum AnalysisMode: String, Codable, CaseIterable {
        case exclude = "exclude"
        case analyzeSeparately = "analyzeSeparately"
    }

    init(id: UUID = UUID(), name: String, color: CodableColor, analysisMode: AnalysisMode) {
        self.id = id
        self.name = name
        self.color = color
        self.analysisMode = analysisMode
    }
}

// MARK: - EEGAnnotation

/// A time-range annotation on the EEG recording.
struct EEGAnnotation: Identifiable, Codable, Equatable {
    let id: UUID
    var startTime: Float
    var endTime: Float
    var labelID: UUID

    init(id: UUID = UUID(), startTime: Float, endTime: Float, labelID: UUID) {
        self.id = id
        self.startTime = min(startTime, endTime)
        self.endTime = max(startTime, endTime)
        self.labelID = labelID
    }
}

// MARK: - AnnotationFile

/// Simple Codable container for JSON serialization of annotations.
struct AnnotationFile: Codable {
    var labels: [AnnotationLabel]
    var annotations: [EEGAnnotation]
    var badChannelIndices: Set<Int>?  // optional for backward compat with existing JSON
}

// MARK: - AnnotationStore

/// Observable store that manages annotation labels and annotations with JSON persistence.
class AnnotationStore: ObservableObject {
    @Published var labels: [AnnotationLabel]
    @Published var annotations: [EEGAnnotation]
    @Published var badChannelIndices: Set<Int> = []
    private(set) var currentURL: URL?
    private var isAccessingSecurityScope = false

    init() {
        self.labels = Self.defaultLabels()
        self.annotations = []
    }

    // MARK: Default Labels

    static func defaultLabels() -> [AnnotationLabel] {
        [
            AnnotationLabel(
                name: "Artifact",
                color: CodableColor(red: 0.9, green: 0.2, blue: 0.2),
                analysisMode: .exclude
            ),
            AnnotationLabel(
                name: "Eyes Open",
                color: CodableColor(red: 0.5, green: 0.5, blue: 0.5),
                analysisMode: .exclude
            ),
            AnnotationLabel(
                name: "Movement",
                color: CodableColor(red: 0.9, green: 0.6, blue: 0.1),
                analysisMode: .exclude
            ),
        ]
    }

    // MARK: Persistence

    /// Returns the annotation file URL corresponding to a given EDF file URL (sidecar next to EDF).
    static func annotationURL(for edfURL: URL) -> URL {
        edfURL.deletingPathExtension().appendingPathExtension("annotations.json")
    }

    /// Returns a fallback URL in App Support for when sidecar writing is not permitted (e.g., iPad sandbox).
    static func fallbackURL(for edfURL: URL) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let annotDir = appSupport.appendingPathComponent("Annotations", isDirectory: true)
        try? FileManager.default.createDirectory(at: annotDir, withIntermediateDirectories: true)
        let baseName = edfURL.deletingPathExtension().lastPathComponent
        return annotDir.appendingPathComponent("\(baseName).annotations.json")
    }

    /// Loads annotation data from a specific file URL.
    private func loadFromURL(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(AnnotationFile.self, from: data)
            labels = file.labels
            annotations = file.annotations
            badChannelIndices = file.badChannelIndices ?? []
        } catch {
            print("AnnotationStore: failed to load \(url.lastPathComponent): \(error)")
            labels = Self.defaultLabels()
            annotations = []
            badChannelIndices = []
        }
    }

    /// Loads annotations for the given EDF file (original security-scoped URL), or resets to defaults if none exist.
    func load(for edfURL: URL) {
        currentURL = edfURL
        let url = Self.annotationURL(for: edfURL)

        // Security-scoped access for reading from the original file location
        let accessing = edfURL.startAccessingSecurityScopedResource()
        if accessing { isAccessingSecurityScope = true }
        defer {
            if accessing {
                edfURL.stopAccessingSecurityScopedResource()
                isAccessingSecurityScope = false
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            // Try App Support fallback (iPad may have saved here)
            let fallback = Self.fallbackURL(for: edfURL)
            if FileManager.default.fileExists(atPath: fallback.path) {
                loadFromURL(fallback)
            } else {
                labels = Self.defaultLabels()
                annotations = []
                badChannelIndices = []
            }
            return
        }

        loadFromURL(url)
    }

    /// Saves current labels, annotations, and bad channels to JSON.
    /// Tries sidecar next to EDF first; falls back to App Support if permission denied (iPad).
    func save() {
        guard let edfURL = currentURL else { return }
        let file = AnnotationFile(labels: labels, annotations: annotations, badChannelIndices: badChannelIndices)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(file)

            // Try writing next to the original EDF (works on Mac, may fail on iPad)
            let sidecarURL = Self.annotationURL(for: edfURL)

            // Only acquire security scope if not already held (prevents ref count imbalance)
            let needsAccess = !isAccessingSecurityScope
            let accessing = needsAccess ? edfURL.startAccessingSecurityScopedResource() : false
            defer { if accessing { edfURL.stopAccessingSecurityScopedResource() } }

            do {
                try data.write(to: sidecarURL, options: .atomic)
            } catch {
                // Sidecar write failed (likely iPad sandbox) — fall back to App Support
                let fallbackURL = Self.fallbackURL(for: edfURL)
                try data.write(to: fallbackURL, options: .atomic)
                print("AnnotationStore: saved to App Support fallback (sidecar write failed: \(error.localizedDescription))")
            }
        } catch {
            print("AnnotationStore: failed to save: \(error)")
        }
    }

    // MARK: Query Helpers

    /// Returns the label associated with the given annotation, if it exists.
    func label(for annotation: EEGAnnotation) -> AnnotationLabel? {
        labels.first { $0.id == annotation.labelID }
    }

    /// Returns time ranges for all annotations whose label mode is `.exclude`.
    func excludedTimeRanges() -> [(start: Float, end: Float)] {
        annotations.compactMap { annotation in
            guard let lbl = label(for: annotation), lbl.analysisMode == .exclude else {
                return nil
            }
            return (start: annotation.startTime, end: annotation.endTime)
        }
    }

    /// Returns annotations grouped by label name for labels with `.analyzeSeparately` mode.
    func separateGroups() -> [String: [(start: Float, end: Float)]] {
        var groups: [String: [(start: Float, end: Float)]] = [:]
        for annotation in annotations {
            guard let lbl = label(for: annotation), lbl.analysisMode == .analyzeSeparately else {
                continue
            }
            groups[lbl.name, default: []].append(
                (start: annotation.startTime, end: annotation.endTime)
            )
        }
        return groups
    }

    // MARK: Import

    /// Imports annotations from an external JSON file (e.g., created on Mac, imported on iPad).
    func importFromFile(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(AnnotationFile.self, from: data)
            labels = file.labels
            annotations = file.annotations
            badChannelIndices = file.badChannelIndices ?? []
            save()  // re-save to local persistence
        } catch {
            print("AnnotationStore: failed to import from \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: Mutation Helpers

    /// Toggles a channel's bad status and saves.
    func toggleBadChannel(_ index: Int) {
        if badChannelIndices.contains(index) {
            badChannelIndices.remove(index)
        } else {
            badChannelIndices.insert(index)
        }
        save()
    }

    /// Adds a new annotation and saves.
    func addAnnotation(startTime: Float, endTime: Float, labelID: UUID) {
        let annotation = EEGAnnotation(startTime: startTime, endTime: endTime, labelID: labelID)
        annotations.append(annotation)
        save()
    }

    /// Removes the annotation with the given ID and saves.
    func removeAnnotation(_ id: UUID) {
        annotations.removeAll { $0.id == id }
        save()
    }

    /// Updates fields of an existing annotation in memory only (no disk write).
    /// Use this during high-frequency gesture callbacks (e.g. drag .onChanged).
    func updateAnnotationInMemory(_ id: UUID, startTime: Float? = nil, endTime: Float? = nil, labelID: UUID? = nil) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var annotation = annotations[index]
        let newStart = startTime ?? annotation.startTime
        let newEnd = endTime ?? annotation.endTime
        annotation.startTime = min(newStart, newEnd)
        annotation.endTime = max(newStart, newEnd)
        if let labelID = labelID {
            annotation.labelID = labelID
        }
        annotations[index] = annotation
    }

    /// Updates fields of an existing annotation and saves to disk.
    func updateAnnotation(_ id: UUID, startTime: Float? = nil, endTime: Float? = nil, labelID: UUID? = nil) {
        updateAnnotationInMemory(id, startTime: startTime, endTime: endTime, labelID: labelID)
        save()
    }

    /// Removes all annotations referencing the given label ID and saves.
    func removeAnnotations(forLabel labelID: UUID) {
        annotations.removeAll { $0.labelID == labelID }
        save()
    }
}
