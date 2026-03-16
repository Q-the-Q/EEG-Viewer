// EEGAnnotation.swift
// Data model and persistence for EEG waveform annotations.

import SwiftUI

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
}

// MARK: - AnnotationStore

/// Observable store that manages annotation labels and annotations with JSON persistence.
class AnnotationStore: ObservableObject {
    @Published var labels: [AnnotationLabel]
    @Published var annotations: [EEGAnnotation]
    private(set) var currentURL: URL?

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

    /// Returns the annotation file URL corresponding to a given EDF file URL.
    static func annotationURL(for edfURL: URL) -> URL {
        edfURL.deletingPathExtension().appendingPathExtension("annotations.json")
    }

    /// Loads annotations for the given EDF file, or resets to defaults if none exist.
    func load(for edfURL: URL) {
        let url = Self.annotationURL(for: edfURL)
        currentURL = edfURL

        guard FileManager.default.fileExists(atPath: url.path) else {
            labels = Self.defaultLabels()
            annotations = []
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(AnnotationFile.self, from: data)
            labels = file.labels
            annotations = file.annotations
        } catch {
            print("AnnotationStore: failed to load \(url.lastPathComponent): \(error)")
            labels = Self.defaultLabels()
            annotations = []
        }
    }

    /// Saves current labels and annotations to the JSON file.
    func save() {
        guard let edfURL = currentURL else { return }
        let url = Self.annotationURL(for: edfURL)
        let file = AnnotationFile(labels: labels, annotations: annotations)

        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            print("AnnotationStore: failed to save \(url.lastPathComponent): \(error)")
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

    // MARK: Mutation Helpers

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

    /// Updates fields of an existing annotation and saves.
    func updateAnnotation(_ id: UUID, startTime: Float? = nil, endTime: Float? = nil, labelID: UUID? = nil) {
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
        save()
    }
}
