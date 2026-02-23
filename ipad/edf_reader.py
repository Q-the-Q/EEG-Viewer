"""Pure-Python EDF file reader — no C extensions required.

Reads EDF/EDF+ files using only struct and numpy, making it compatible
with iPad Python environments (Pyto) where C-extension packages like
pyedflib and MNE cannot be installed.

Based on the European Data Format specification:
https://www.edfplus.info/specs/edf.html
"""

import struct
import numpy as np

# Old 10-20 nomenclature to new (ACNS 2006 standard)
OLD_TO_NEW = {"T3": "T7", "T4": "T8", "T5": "P7", "T6": "P8"}


def read_edf(file_path):
    """Read an EDF file and return channel data, names, and sample rate.

    Args:
        file_path: Path to the .edf file.

    Returns:
        dict with keys:
            'data': np.ndarray of shape (n_channels, n_samples) in Volts
            'channel_names': list of channel name strings
            'sfreq': sampling frequency in Hz
            'duration': total duration in seconds
            'n_channels': number of channels
            'patient_info': dict with patient metadata from header
    """
    with open(file_path, "rb") as f:
        # --- HEADER (256 bytes) ---
        version = f.read(8).decode("ascii").strip()
        patient_id = f.read(80).decode("ascii").strip()
        recording_id = f.read(80).decode("ascii").strip()
        start_date = f.read(8).decode("ascii").strip()
        start_time = f.read(8).decode("ascii").strip()
        header_bytes = int(f.read(8).decode("ascii").strip())
        reserved = f.read(44).decode("ascii").strip()
        n_data_records = int(f.read(8).decode("ascii").strip())
        record_duration = float(f.read(8).decode("ascii").strip())
        n_channels = int(f.read(4).decode("ascii").strip())

        # --- CHANNEL HEADERS (256 bytes per channel) ---
        labels = [f.read(16).decode("ascii").strip() for _ in range(n_channels)]
        transducers = [f.read(80).decode("ascii").strip() for _ in range(n_channels)]
        phys_dims = [f.read(8).decode("ascii").strip() for _ in range(n_channels)]
        phys_mins = [float(f.read(8).decode("ascii").strip()) for _ in range(n_channels)]
        phys_maxs = [float(f.read(8).decode("ascii").strip()) for _ in range(n_channels)]
        dig_mins = [float(f.read(8).decode("ascii").strip()) for _ in range(n_channels)]
        dig_maxs = [float(f.read(8).decode("ascii").strip()) for _ in range(n_channels)]
        prefilters = [f.read(80).decode("ascii").strip() for _ in range(n_channels)]
        samples_per_record = [int(f.read(8).decode("ascii").strip()) for _ in range(n_channels)]
        ch_reserved = [f.read(32).decode("ascii").strip() for _ in range(n_channels)]

        # Compute scaling factors: digital -> physical (Volts)
        # physical = (digital - dig_min) / (dig_max - dig_min) * (phys_max - phys_min) + phys_min
        scales = []
        offsets = []
        for i in range(n_channels):
            dig_range = dig_maxs[i] - dig_mins[i]
            phys_range = phys_maxs[i] - phys_mins[i]
            if dig_range == 0:
                scales.append(0.0)
                offsets.append(0.0)
            else:
                scale = phys_range / dig_range
                offset = phys_mins[i] - dig_mins[i] * scale
                scales.append(scale)
                offsets.append(offset)

        # --- DATA RECORDS ---
        # EDF stores data as interleaved records:
        # [record1_ch1, record1_ch2, ..., record2_ch1, record2_ch2, ...]
        all_data = []
        for _ in range(n_data_records):
            record_channels = []
            for ch_idx in range(n_channels):
                n_samps = samples_per_record[ch_idx]
                raw_bytes = f.read(n_samps * 2)  # 16-bit integers
                digital = np.frombuffer(raw_bytes, dtype="<i2")
                # Convert to physical units
                physical = digital.astype(np.float64) * scales[ch_idx] + offsets[ch_idx]
                record_channels.append(physical)
            all_data.append(record_channels)

    # Concatenate records for each channel
    data = np.zeros((n_channels, n_data_records * samples_per_record[0]))
    for ch_idx in range(n_channels):
        segments = [all_data[rec][ch_idx] for rec in range(n_data_records)]
        data[ch_idx] = np.concatenate(segments)

    # Clean up channel names: strip "EEG " prefix, rename old nomenclature
    clean_names = []
    for label in labels:
        name = label
        # Strip EEG prefix
        for prefix in ["EEG ", "EEG-", "EEG"]:
            if name.startswith(prefix) and len(name) > len(prefix):
                name = name[len(prefix):].strip()
                break
        # Rename old 10-20 names
        name = OLD_TO_NEW.get(name, name)
        clean_names.append(name)

    # Convert physical units to Volts if needed
    # EDF physical dimension is usually "uV" for EEG
    for i in range(n_channels):
        unit = phys_dims[i].lower().strip()
        if unit in ("uv", "µv", "microvolt", "microvolts"):
            data[i] *= 1e-6  # Convert µV to V

    sfreq = samples_per_record[0] / record_duration
    duration = n_data_records * record_duration

    return {
        "data": data,
        "channel_names": clean_names,
        "sfreq": sfreq,
        "duration": duration,
        "n_channels": n_channels,
        "patient_info": {
            "patient_id": patient_id,
            "recording_id": recording_id,
            "start_date": start_date,
            "start_time": start_time,
        },
    }
