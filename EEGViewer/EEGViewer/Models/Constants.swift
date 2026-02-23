// Constants.swift
// Frequency bands, electrode positions, region maps, colors, and analysis parameters.

import SwiftUI

enum Constants {

    // MARK: - Frequency Bands

    struct FreqBand {
        let name: String
        let low: Float
        let high: Float
        let color: Color
        let shadeColor: Color
    }

    static let freqBands: [FreqBand] = [
        FreqBand(name: "Delta", low: 1.0, high: 4.0,
                 color: Color(red: 0.416, green: 0.051, blue: 0.678),  // #6A0DAD
                 shadeColor: Color(red: 0.839, green: 0.918, blue: 0.973)),  // #D6EAF8
        FreqBand(name: "Theta", low: 4.0, high: 8.0,
                 color: Color(red: 0.133, green: 0.545, blue: 0.133),  // #228B22
                 shadeColor: Color(red: 0.835, green: 0.961, blue: 0.890)),  // #D5F5E3
        FreqBand(name: "Alpha", low: 8.0, high: 13.0,
                 color: Color(red: 0.855, green: 0.647, blue: 0.125),  // #DAA520
                 shadeColor: Color(red: 0.988, green: 0.953, blue: 0.812)),  // #FCF3CF
        FreqBand(name: "Beta",  low: 13.0, high: 25.0,
                 color: Color(red: 0.800, green: 0.200, blue: 0.200),  // #CC3333
                 shadeColor: Color(red: 0.831, green: 0.937, blue: 0.969)),  // #D4EFF7
    ]

    static let totalPowerRange: (low: Float, high: Float) = (1.0, 25.0)

    // MARK: - PSD Parameters

    static let psdNperseg: Int = 1024
    static let psdNoverlap: Int = 512

    // MARK: - Artifact Rejection

    static let epochDuration: Float = 2.0
    static let artifactThresholdUV: Float = 100.0
    static let minCleanEpochs: Int = 30

    // MARK: - Z-Score Display Range

    static let zscoreMin: Float = -2.5
    static let zscoreMax: Float = 2.5

    // MARK: - Standard 10-20 Channels (19 EEG)

    static let standard1020Channels: [String] = [
        "Fp1", "Fp2",
        "F7", "F3", "Fz", "F4", "F8",
        "T7", "C3", "Cz", "C4", "T8",
        "P7", "P3", "Pz", "P4", "P8",
        "O1", "O2",
    ]

    // MARK: - Old 10-20 Name Mapping

    static let oldToNewNames: [String: String] = [
        "T3": "T7", "T4": "T8", "T5": "P7", "T6": "P8",
    ]

    // MARK: - Brain Region Map

    static let regionMap: [String: [String]] = [
        "Frontal":   ["Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8"],
        "Central":   ["T7", "C3", "Cz", "C4", "T8"],
        "Posterior":  ["P7", "P3", "Pz", "P4", "P8", "O1", "O2"],
    ]

    // MARK: - Hemispheric Asymmetry Pairs (Left, Right)

    static let asymmetryPairs: [(left: String, right: String)] = [
        ("Fp1", "Fp2"), ("F7", "F8"), ("F3", "F4"), ("T7", "T8"),
        ("C3", "C4"),   ("P7", "P8"), ("P3", "P4"), ("O1", "O2"),
    ]

    // MARK: - 2D Electrode Positions (azimuthal projection, nose-up)
    // Extracted from MNE standard_1020 montage

    static let electrodePositions2D: [String: (x: Float, y: Float)] = [
        "Fp1": (-0.0294, 0.0839),
        "Fp2": (0.0294,  0.0839),
        "F7":  (-0.0748, 0.0464),
        "F3":  (-0.0445, 0.0516),
        "Fz":  (0.0,     0.0602),
        "F4":  (0.0445,  0.0516),
        "F8":  (0.0748,  0.0464),
        "T7":  (-0.0856, 0.0),
        "C3":  (-0.0533, 0.0),
        "Cz":  (0.0,     0.0),
        "C4":  (0.0533,  0.0),
        "T8":  (0.0856,  0.0),
        "P7":  (-0.0748, -0.0464),
        "P3":  (-0.0445, -0.0516),
        "Pz":  (0.0,     -0.0602),
        "P4":  (0.0445,  -0.0516),
        "P8":  (0.0748,  -0.0464),
        "O1":  (-0.0294, -0.0839),
        "O2":  (0.0294,  -0.0839),
    ]

    // MARK: - Head Radius for Topomap

    static let headRadius: Float = 0.095

    // MARK: - NeuroSynchrony Colormap Stops
    // cyan → blue → black → magenta → red → yellow

    struct ColorStop {
        let position: Float  // 0.0 to 1.0
        let r: Float
        let g: Float
        let b: Float
    }

    static let neuroSynchronyStops: [ColorStop] = [
        ColorStop(position: 0.0,   r: 0.0,   g: 1.0,   b: 1.0),   // Cyan  (-2.5Z)
        ColorStop(position: 0.1,   r: 0.0,   g: 0.6,   b: 0.867), // Light blue
        ColorStop(position: 0.3,   r: 0.0,   g: 0.4,   b: 0.8),   // Blue
        ColorStop(position: 0.5,   r: 0.0,   g: 0.0,   b: 0.0),   // Black (0Z)
        ColorStop(position: 0.7,   r: 0.8,   g: 0.0,   b: 0.333), // Magenta
        ColorStop(position: 0.9,   r: 1.0,   g: 0.0,   b: 0.0),   // Red
        ColorStop(position: 1.0,   r: 1.0,   g: 1.0,   b: 0.0),   // Yellow (+2.5Z)
    ]

    // MARK: - Waveform Display

    static let waveformLineColor = Color(red: 0.102, green: 0.102, blue: 0.180)  // #1a1a2e
    static let channelSpacingUV: Float = 50.0
    static let defaultWindowSec: Float = 10.0
    static let windowSizeOptions: [Float] = [2, 5, 10, 20, 30, 60]
    static let defaultSpeed: Float = 1.0
    static let minSpeed: Float = 0.5
    static let maxSpeed: Float = 4.0

    // MARK: - Spectrogram

    static let spectrogramNperseg: Int = 256
    static let spectrogramNoverlap: Int = 192
}
