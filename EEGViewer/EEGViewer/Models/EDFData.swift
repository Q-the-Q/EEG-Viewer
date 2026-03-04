// EDFData.swift
// Data model for parsed EDF file contents.

import Foundation

/// Holds all data from a parsed EDF file.
struct EDFData {
    /// Channel labels (cleaned, e.g. "Fp1", "O2", "ECG")
    let channelNames: [String]
    /// Raw data in Volts — shape: [channel][sample]
    let data: [[Float]]
    /// Sampling frequency in Hz
    let sfreq: Float
    /// Total recording duration in seconds
    let duration: Float
    /// Total number of channels
    let nChannels: Int
    /// Patient metadata
    let patientInfo: PatientInfo

    struct PatientInfo {
        let patientID: String
        let recordingID: String
        let startDate: String
        let startTime: String
    }

    /// Number of samples per channel
    var nSamples: Int { data.first?.count ?? 0 }

    /// Indices of EEG-only channels (excludes ECG/EKG)
    var eegIndices: [Int] {
        channelNames.enumerated().compactMap { idx, name in
            let upper = name.uppercased()
            if upper == "ECG" || upper == "EKG" { return nil }
            if Constants.standard1020Channels.contains(name) { return idx }
            return nil
        }
    }

    /// EEG channel names only
    var eegChannelNames: [String] {
        eegIndices.map { channelNames[$0] }
    }

    /// EEG data only (excludes ECG), in Volts — [channel][sample]
    var eegData: [[Float]] {
        eegIndices.map { data[$0] }
    }

    // MARK: - ECG Access

    /// Index of the ECG/EKG channel, if present.
    var ecgIndex: Int? {
        channelNames.firstIndex { name in
            let upper = name.uppercased()
            return upper == "ECG" || upper == "EKG"
        }
    }

    /// ECG channel name, if present.
    var ecgChannelName: String? {
        guard let idx = ecgIndex else { return nil }
        return channelNames[idx]
    }

    /// ECG data in Volts, if present.
    var ecgData: [Float]? {
        guard let idx = ecgIndex else { return nil }
        return data[idx]
    }

    /// Whether this EDF file contains an ECG channel.
    var hasECG: Bool {
        ecgIndex != nil
    }
}
