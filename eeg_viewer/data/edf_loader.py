"""EDF file loading and management using MNE-Python."""

import re
import numpy as np
import mne

from .channel_map import OLD_TO_NEW_CHANNEL_NAMES, STANDARD_1020_CHANNELS


class EDFLoader:
    """Loads and manages EDF/EDF+ file data."""

    def __init__(self):
        self.raw = None
        self.file_path = ""
        self.channel_names = []
        self.eeg_channel_names = []
        self.sfreq = 0.0
        self.duration = 0.0
        self.n_channels = 0
        self.n_eeg_channels = 0
        self._eeg_info = None

    def load(self, file_path):
        """Load an EDF file, rename channels, set montage.

        Handles:
        - Stripping 'EEG ' or 'EEG-' prefixes from channel names
        - Renaming old 10-20 nomenclature (T3->T7, T4->T8, T5->P7, T6->P8)
        - Setting ECG channel type
        - Applying standard_1020 montage for topographic mapping
        """
        self.file_path = file_path
        self.raw = mne.io.read_raw_edf(file_path, preload=True, verbose=False)

        # Strip EEG prefix from channel names
        rename_map = {}
        for ch in self.raw.ch_names:
            new_name = re.sub(r"^EEG[\s\-]*", "", ch).strip()
            if new_name != ch:
                rename_map[ch] = new_name
        if rename_map:
            self.raw.rename_channels(rename_map)

        # Rename old 10-20 nomenclature to new
        rename_old = {
            old: new
            for old, new in OLD_TO_NEW_CHANNEL_NAMES.items()
            if old in self.raw.ch_names
        }
        if rename_old:
            self.raw.rename_channels(rename_old)

        # Set ECG/EKG channel types if present
        ecg_channels = [ch for ch in self.raw.ch_names if ch.upper() in ("ECG", "EKG")]
        if ecg_channels:
            self.raw.set_channel_types({ch: "ecg" for ch in ecg_channels})

        # Apply standard 10-20 montage for EEG channels
        montage = mne.channels.make_standard_montage("standard_1020")
        self.raw.set_montage(montage, on_missing="warn", verbose=False)

        # Apply average reference to EEG channels.
        # Raw EDF data from devices like the Zeto WR-19 is recorded against
        # a single hardware reference. Re-referencing to the average of all
        # EEG channels removes the common signal and produces amplitudes
        # consistent with clinical qEEG reports.
        self.raw.set_eeg_reference("average", verbose=False)

        # Apply a 1 Hz high-pass filter to remove slow DC drift and reduce
        # eye-blink artifacts in frontal channels. Clinical qEEG software
        # (e.g., NeuroSynchrony) applies similar preprocessing.
        self.raw.filter(l_freq=1.0, h_freq=None, picks="eeg", verbose=False)

        # Store metadata
        self.channel_names = list(self.raw.ch_names)
        self.sfreq = self.raw.info["sfreq"]
        self.duration = self.raw.times[-1]
        self.n_channels = len(self.channel_names)

        # Identify EEG-only channels
        eeg_picks = mne.pick_types(self.raw.info, eeg=True, ecg=False)
        self.eeg_channel_names = [self.raw.ch_names[i] for i in eeg_picks]
        self.n_eeg_channels = len(self.eeg_channel_names)

        # Pre-compute EEG-only Info for topomaps
        self._eeg_info = mne.pick_info(self.raw.info, eeg_picks)

    def get_data_chunk(self, start_sec, duration_sec, channels=None):
        """Return (data, times) for a time window.

        Args:
            start_sec: Start time in seconds.
            duration_sec: Duration in seconds.
            channels: List of channel names, or None for all.

        Returns:
            Tuple of (data, times) where data shape is (n_channels, n_samples).
        """
        start_sample = int(start_sec * self.sfreq)
        stop_sample = int((start_sec + duration_sec) * self.sfreq)
        stop_sample = min(stop_sample, self.raw.n_times)

        picks = channels if channels else None
        data, times = self.raw.get_data(
            picks=picks, start=start_sample, stop=stop_sample, return_times=True
        )
        return data, times

    def get_all_data(self, channels=None):
        """Return full recording data.

        Args:
            channels: List of channel names, or None for all.

        Returns:
            Tuple of (data, times).
        """
        picks = channels if channels else None
        data, times = self.raw.get_data(picks=picks, return_times=True)
        return data, times

    def get_data_range(self, channels=None, start_sec=None, end_sec=None):
        """Return data for a specific time range.

        Args:
            channels: List of channel names, or None for all.
            start_sec: Start time in seconds (None = beginning).
            end_sec: End time in seconds (None = end of recording).

        Returns:
            Tuple of (data, times).
        """
        picks = channels if channels else None
        start_sample = int(start_sec * self.sfreq) if start_sec else 0
        stop_sample = int(end_sec * self.sfreq) if end_sec else self.raw.n_times
        stop_sample = min(stop_sample, self.raw.n_times)
        data, times = self.raw.get_data(
            picks=picks, start=start_sample, stop=stop_sample, return_times=True
        )
        return data, times

    def get_eeg_channels(self):
        """Return list of EEG-only channel names (excludes ECG)."""
        return list(self.eeg_channel_names)

    def get_eeg_info(self):
        """Return MNE Info object for EEG channels only (for topomaps)."""
        return self._eeg_info

    def get_info(self):
        """Return full MNE Info object."""
        return self.raw.info

    def get_patient_info(self):
        """Extract patient info from the EDF header if available."""
        info = {}
        if self.raw is not None:
            subject_info = self.raw.info.get("subject_info", {})
            if subject_info:
                info["name"] = subject_info.get("first_name", "")
                info["sex"] = subject_info.get("sex", "")
                info["birthday"] = subject_info.get("birthday", "")
            # Also try to extract from filename
            info["file_name"] = self.file_path.split("/")[-1] if self.file_path else ""
            info["duration_sec"] = self.duration
            info["sfreq"] = self.sfreq
            info["n_eeg_channels"] = self.n_eeg_channels
            info["meas_date"] = str(self.raw.info.get("meas_date", ""))
        return info
