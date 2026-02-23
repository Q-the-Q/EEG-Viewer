// EDFReader.swift
// Pure-Swift EDF file parser — reads EDF/EDF+ files using Foundation Data.
// Port of ipad/edf_reader.py, following the EDF specification:
// https://www.edfplus.info/specs/edf.html

import Foundation
import Accelerate

enum EDFError: Error, LocalizedError {
    case fileNotFound
    case invalidHeader(String)
    case dataTruncated

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "EDF file not found"
        case .invalidHeader(let msg): return "Invalid EDF header: \(msg)"
        case .dataTruncated: return "EDF data is truncated"
        }
    }
}

struct EDFReader {

    /// Read an EDF file from disk and return parsed data.
    static func read(url: URL) throws -> EDFData {
        guard let fileData = try? Data(contentsOf: url) else {
            throw EDFError.fileNotFound
        }
        return try parse(data: fileData)
    }

    /// Parse EDF data from a Data buffer.
    static func parse(data: Data) throws -> EDFData {
        var offset = 0

        // --- MAIN HEADER (256 bytes) ---
        let _ = readASCII(data, offset: &offset, length: 8)           // version
        let patientID = readASCII(data, offset: &offset, length: 80)
        let recordingID = readASCII(data, offset: &offset, length: 80)
        let startDate = readASCII(data, offset: &offset, length: 8)
        let startTime = readASCII(data, offset: &offset, length: 8)
        let _ = readASCII(data, offset: &offset, length: 8)           // header bytes
        let _ = readASCII(data, offset: &offset, length: 44)          // reserved

        guard let nDataRecords = Int(readASCII(data, offset: &offset, length: 8)) else {
            throw EDFError.invalidHeader("Cannot parse number of data records")
        }
        guard let recordDuration = Float(readASCII(data, offset: &offset, length: 8)) else {
            throw EDFError.invalidHeader("Cannot parse record duration")
        }
        guard let nChannels = Int(readASCII(data, offset: &offset, length: 4)) else {
            throw EDFError.invalidHeader("Cannot parse number of channels")
        }

        // --- CHANNEL HEADERS (256 bytes per channel) ---
        var labels = [String]()
        for _ in 0..<nChannels {
            labels.append(readASCII(data, offset: &offset, length: 16))
        }

        // Transducers (80 bytes each) — skip
        offset += nChannels * 80

        var physDims = [String]()
        for _ in 0..<nChannels {
            physDims.append(readASCII(data, offset: &offset, length: 8))
        }

        var physMins = [Float]()
        for _ in 0..<nChannels {
            physMins.append(Float(readASCII(data, offset: &offset, length: 8)) ?? 0)
        }
        var physMaxs = [Float]()
        for _ in 0..<nChannels {
            physMaxs.append(Float(readASCII(data, offset: &offset, length: 8)) ?? 0)
        }
        var digMins = [Float]()
        for _ in 0..<nChannels {
            digMins.append(Float(readASCII(data, offset: &offset, length: 8)) ?? 0)
        }
        var digMaxs = [Float]()
        for _ in 0..<nChannels {
            digMaxs.append(Float(readASCII(data, offset: &offset, length: 8)) ?? 0)
        }

        // Prefilters (80 bytes each) — skip
        offset += nChannels * 80

        var samplesPerRecord = [Int]()
        for _ in 0..<nChannels {
            samplesPerRecord.append(Int(readASCII(data, offset: &offset, length: 8)) ?? 0)
        }

        // Channel reserved (32 bytes each) — skip
        offset += nChannels * 32

        // --- Compute scaling factors ---
        var scales = [Float](repeating: 0, count: nChannels)
        var offsets = [Float](repeating: 0, count: nChannels)
        for i in 0..<nChannels {
            let digRange = digMaxs[i] - digMins[i]
            let physRange = physMaxs[i] - physMins[i]
            if digRange == 0 {
                scales[i] = 0
                offsets[i] = 0
            } else {
                scales[i] = physRange / digRange
                offsets[i] = physMins[i] - digMins[i] * scales[i]
            }
        }

        // --- DATA RECORDS ---
        let totalSamplesPerChannel = nDataRecords * samplesPerRecord[0]
        var channelData = [[Float]](repeating: [Float](repeating: 0, count: totalSamplesPerChannel), count: nChannels)

        data.withUnsafeBytes { rawBuffer in
            var dataOffset = offset
            for rec in 0..<nDataRecords {
                for ch in 0..<nChannels {
                    let nSamps = samplesPerRecord[ch]
                    let baseIdx = rec * nSamps
                    let bytesNeeded = nSamps * 2

                    guard dataOffset + bytesNeeded <= data.count else { return }

                    // Read Int16 values and convert to Float with scaling
                    let int16Ptr = rawBuffer.baseAddress!.advanced(by: dataOffset)
                        .assumingMemoryBound(to: Int16.self)

                    for s in 0..<nSamps {
                        let digital = Float(int16Ptr[s])
                        channelData[ch][baseIdx + s] = digital * scales[ch] + offsets[ch]
                    }

                    dataOffset += bytesNeeded
                }
            }
        }

        // --- Clean channel names ---
        var cleanNames = [String]()
        for label in labels {
            var name = label
            // Strip EEG prefix
            for prefix in ["EEG ", "EEG-", "EEG"] {
                if name.hasPrefix(prefix) && name.count > prefix.count {
                    name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            // Rename old 10-20 names
            if let newName = Constants.oldToNewNames[name] {
                name = newName
            }
            cleanNames.append(name)
        }

        // --- Convert units to Volts ---
        for i in 0..<nChannels {
            let unit = physDims[i].lowercased().trimmingCharacters(in: .whitespaces)
            if ["uv", "µv", "microvolt", "microvolts"].contains(unit) {
                // Convert µV to V
                var scale: Float = 1e-6
                vDSP_vsmul(channelData[i], 1, &scale, &channelData[i], 1, vDSP_Length(channelData[i].count))
            }
        }

        let sfreq = Float(samplesPerRecord[0]) / recordDuration
        let duration = Float(nDataRecords) * recordDuration

        return EDFData(
            channelNames: cleanNames,
            data: channelData,
            sfreq: sfreq,
            duration: duration,
            nChannels: nChannels,
            patientInfo: EDFData.PatientInfo(
                patientID: patientID,
                recordingID: recordingID,
                startDate: startDate,
                startTime: startTime
            )
        )
    }

    // MARK: - Helpers

    /// Read ASCII string from Data at offset, trimming whitespace. Advances offset.
    private static func readASCII(_ data: Data, offset: inout Int, length: Int) -> String {
        let end = min(offset + length, data.count)
        let slice = data[offset..<end]
        offset = end
        return String(data: slice, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
