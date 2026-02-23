"""Signal processing: PSD computation, band power extraction, filtering, artifact rejection, impedance detection."""

import numpy as np
from scipy.signal import welch, butter, filtfilt, coherence
from scipy.integrate import simpson

from ..utils.constants import (
    PSD_NPERSEG, PSD_NOVERLAP, PSD_WINDOW, FREQ_BANDS, TOTAL_POWER_RANGE,
)

# Artifact rejection defaults
EPOCH_DURATION_SEC = 2.0       # Epoch length for artifact rejection
ARTIFACT_THRESHOLD_UV = 100.0  # Peak-to-peak threshold in microvolts
MIN_CLEAN_EPOCHS = 30          # Minimum clean epochs required (fallback: relax threshold)

# Impedance detection parameters
IMPEDANCE_DETECTION_ENABLED = True
IMPEDANCE_NOISE_FLOOR_THRESHOLD = -110.0  # dB - channels above this have high impedance
IMPEDANCE_SLOPE_THRESHOLD = -1.8          # 1/f slope - steeper = more noise
IMPEDANCE_RMS_PERCENTILE = 75             # Flag channels in top 25% RMS


class SignalProcessor:
    """Signal processing utilities for EEG analysis."""

    def __init__(self, sfreq):
        self.sfreq = sfreq
        self.n_clean_epochs = 0
        self.n_total_epochs = 0
        self.rejection_threshold = ARTIFACT_THRESHOLD_UV

        # Channel quality assessment
        self.channel_quality = {}  # channel_name -> {'quality': 'good'/'poor', 'filters_applied': [...]}
        self.bad_channels = []     # List of channel indices/names flagged as high-impedance

    def detect_impedance_issues(self, data, channel_names):
        """Detect high-impedance channels using spectral and statistical criteria.

        High-impedance electrodes show:
        1. Elevated low-frequency noise (0.5-2 Hz)
        2. Steep 1/f slope (poor signal quality)
        3. Abnormally high RMS amplitude

        Args:
            data: Array of shape (n_channels, n_samples) in Volts.
            channel_names: List of channel names.

        Returns:
            Dictionary mapping channel_names to quality flags ('good' or 'poor').
        """
        self.channel_quality = {}
        self.bad_channels = []

        if not IMPEDANCE_DETECTION_ENABLED or data.shape[0] == 0:
            for ch in channel_names:
                self.channel_quality[ch] = 'good'
            return self.channel_quality

        # Compute metrics for all channels
        rms_values = np.sqrt(np.mean(data**2, axis=1))
        rms_threshold = np.percentile(rms_values, IMPEDANCE_RMS_PERCENTILE)

        slopes = []
        low_freq_powers = []

        for i in range(data.shape[0]):
            # Spectral analysis
            f, psd = welch(data[i], fs=self.sfreq, nperseg=1024, noverlap=512)

            # Low-frequency noise floor (0.5-2 Hz)
            low_mask = (f >= 0.5) & (f <= 2.0)
            low_power_db = 10 * np.log10(np.mean(psd[low_mask]) + 1e-20)
            low_freq_powers.append(low_power_db)

            # 1/f slope in log-log space (0.5-30 Hz)
            log_f = np.log10(f + 1e-10)  # Add small epsilon to avoid log(0)
            log_psd = np.log10(psd + 1e-20)  # Add small epsilon to avoid log(0)
            mask = (f >= 0.5) & (f <= 30)
            if np.any(mask):
                slope, _ = np.polyfit(log_f[mask], log_psd[mask], 1)
                slopes.append(slope)
            else:
                slopes.append(0)

        slopes = np.array(slopes)
        low_freq_powers = np.array(low_freq_powers)

        # Classify each channel
        for i, ch in enumerate(channel_names):
            is_bad = False
            reasons = []

            # Check 1: High low-frequency noise floor
            if low_freq_powers[i] > IMPEDANCE_NOISE_FLOOR_THRESHOLD:
                is_bad = True
                reasons.append(f"high-noise-floor({low_freq_powers[i]:.1f}dB)")

            # Check 2: Steep 1/f slope (poor signal quality)
            if slopes[i] < IMPEDANCE_SLOPE_THRESHOLD:
                is_bad = True
                reasons.append(f"steep-1f-slope({slopes[i]:.2f})")

            # Check 3: Abnormally high RMS
            if rms_values[i] > rms_threshold:
                is_bad = True
                reasons.append(f"high-RMS({rms_values[i]*1e6:.1f}µV)")

            if is_bad:
                self.channel_quality[ch] = 'poor'
                self.bad_channels.append(i)
            else:
                self.channel_quality[ch] = 'good'

        return self.channel_quality

    def apply_adaptive_filtering(self, data, channel_names=None):
        """Apply channel-specific filtering based on impedance assessment.

        High-impedance channels get stronger low-pass and notch filtering:
        - Good channels: Standard 0.5 Hz high-pass + 50 Hz notch
        - Bad channels: 1 Hz high-pass (stronger) + 50 Hz notch + additional smoothing

        Args:
            data: Array of shape (n_channels, n_samples) in Volts.
            channel_names: List of channel names (for mapping to quality flags).

        Returns:
            Filtered data of same shape.
        """
        if not channel_names:
            channel_names = [f"CH{i}" for i in range(data.shape[0])]

        if not self.channel_quality:
            # If not yet assessed, assess now
            self.detect_impedance_issues(data, channel_names)

        nyquist = self.sfreq / 2
        filtered = data.copy()

        for i, ch in enumerate(channel_names):
            quality = self.channel_quality.get(ch, 'good')

            if quality == 'poor':
                # Stronger filtering for bad channels
                # High-pass at 1 Hz (vs 0.5 Hz for good channels)
                b, a = butter(4, 1 / nyquist, btype='high')
                filtered[i] = filtfilt(b, a, filtered[i])

                # Notch filter at 50 Hz
                b, a = butter(2, [49/nyquist, 51/nyquist], btype='bandstop')
                filtered[i] = filtfilt(b, a, filtered[i])

                # Additional low-pass smoothing (40 Hz cutoff)
                b, a = butter(2, 40 / nyquist, btype='low')
                filtered[i] = filtfilt(b, a, filtered[i])
            else:
                # Standard filtering for good channels
                # High-pass at 0.5 Hz
                b, a = butter(4, 0.5 / nyquist, btype='high')
                filtered[i] = filtfilt(b, a, filtered[i])

                # Notch filter at 50 Hz
                b, a = butter(2, [49/nyquist, 51/nyquist], btype='bandstop')
                filtered[i] = filtfilt(b, a, filtered[i])

        return filtered

    def reject_artifacts(self, data, threshold_uv=None, epoch_sec=None):
        """Epoch-based artifact rejection.

        Segments continuous data into fixed-length epochs, computes the
        peak-to-peak amplitude for each channel in each epoch, and rejects
        any epoch where ANY channel exceeds the threshold.

        This is the standard approach used in clinical qEEG software like
        NeuroSynchrony, NeuroGuide, and BrainDx.

        Args:
            data: Array of shape (n_channels, n_samples) in Volts.
            threshold_uv: Peak-to-peak rejection threshold in microvolts.
                          Default: 100 uV (standard clinical threshold).
            epoch_sec: Epoch duration in seconds. Default: 2.0s.

        Returns:
            clean_data: Array of shape (n_channels, n_clean_samples) with
                        artifact-free epochs concatenated.
        """
        threshold = threshold_uv or ARTIFACT_THRESHOLD_UV
        epoch_dur = epoch_sec or EPOCH_DURATION_SEC
        epoch_samples = int(epoch_dur * self.sfreq)

        n_channels = data.shape[0]
        n_epochs = data.shape[1] // epoch_samples

        if n_epochs == 0:
            self.n_clean_epochs = 0
            self.n_total_epochs = 0
            return data

        # Split into epochs and compute peak-to-peak per channel per epoch
        clean_epochs = []
        for e in range(n_epochs):
            start = e * epoch_samples
            end = start + epoch_samples
            epoch = data[:, start:end]

            # Peak-to-peak in microvolts for each channel
            ptp_uv = (np.max(epoch, axis=1) - np.min(epoch, axis=1)) * 1e6

            # Reject if ANY channel exceeds threshold
            if np.all(ptp_uv <= threshold):
                clean_epochs.append(epoch)

        self.n_total_epochs = n_epochs
        self.rejection_threshold = threshold

        # If too few clean epochs, progressively relax the threshold
        if len(clean_epochs) < MIN_CLEAN_EPOCHS:
            # Try relaxed thresholds
            for relaxed_thresh in [150, 200, 300, 500]:
                clean_epochs = []
                for e in range(n_epochs):
                    start = e * epoch_samples
                    end = start + epoch_samples
                    epoch = data[:, start:end]
                    ptp_uv = (np.max(epoch, axis=1) - np.min(epoch, axis=1)) * 1e6
                    if np.all(ptp_uv <= relaxed_thresh):
                        clean_epochs.append(epoch)
                self.rejection_threshold = relaxed_thresh
                if len(clean_epochs) >= MIN_CLEAN_EPOCHS:
                    break

        # If still too few, use all epochs (no rejection)
        if len(clean_epochs) < MIN_CLEAN_EPOCHS:
            self.n_clean_epochs = n_epochs
            self.rejection_threshold = float('inf')
            return data

        self.n_clean_epochs = len(clean_epochs)

        # Concatenate clean epochs back into continuous data
        clean_data = np.concatenate(clean_epochs, axis=1)
        return clean_data

    def compute_psd_welch(self, data, n_fft=None, n_overlap=None):
        """Compute PSD using Welch's method.

        Args:
            data: Array of shape (n_channels, n_samples).
            n_fft: FFT length (default from constants).
            n_overlap: Overlap samples (default from constants).

        Returns:
            Tuple of (freqs, psd) where psd shape is (n_channels, n_freqs).
        """
        nperseg = n_fft or PSD_NPERSEG
        noverlap = n_overlap or PSD_NOVERLAP
        freqs, psd = welch(
            data, fs=self.sfreq, nperseg=nperseg, noverlap=noverlap,
            window=PSD_WINDOW, detrend="constant", axis=-1,
        )
        return freqs, psd

    def compute_band_power(self, psd, freqs, band):
        """Compute absolute band power by integrating PSD within frequency range.

        Args:
            psd: PSD array, shape (n_channels, n_freqs).
            freqs: Frequency array.
            band: Tuple (f_low, f_high) in Hz.

        Returns:
            Array of shape (n_channels,) with absolute power per channel.
        """
        f_low, f_high = band
        mask = (freqs >= f_low) & (freqs <= f_high)
        if not np.any(mask):
            return np.zeros(psd.shape[0])
        return simpson(psd[:, mask], x=freqs[mask], axis=1)

    def compute_relative_power(self, psd, freqs, band, total_range=None):
        """Compute relative band power = band_power / total_power.

        Args:
            psd: PSD array, shape (n_channels, n_freqs).
            freqs: Frequency array.
            band: Tuple (f_low, f_high) in Hz.
            total_range: Tuple (f_low, f_high) for total power computation.

        Returns:
            Array of shape (n_channels,) with relative power per channel.
        """
        if total_range is None:
            total_range = TOTAL_POWER_RANGE
        band_power = self.compute_band_power(psd, freqs, band)
        total_power = self.compute_band_power(psd, freqs, total_range)
        # Avoid division by zero
        total_power = np.where(total_power > 0, total_power, 1e-10)
        return band_power / total_power

    def compute_amplitude_spectrum(self, psd):
        """Convert PSD (uV^2/Hz) to amplitude spectrum (uV/sqrt(Hz)).

        This gives the magnitude spectra as shown in the PDF report Y-axis.
        """
        return np.sqrt(psd)

    def compute_coherence(self, data_ch1, data_ch2, nperseg=None):
        """Compute coherence between two channels.

        Args:
            data_ch1: 1D array for channel 1.
            data_ch2: 1D array for channel 2.
            nperseg: Segment length (default from constants).

        Returns:
            Tuple of (freqs, coherence_values).
        """
        nperseg = nperseg or PSD_NPERSEG
        f, Cxy = coherence(data_ch1, data_ch2, fs=self.sfreq, nperseg=nperseg)
        return f, Cxy

    def bandpass_filter(self, data, low, high, order=4):
        """Apply bandpass Butterworth filter.

        Args:
            data: Array of shape (n_channels, n_samples).
            low: Low cutoff frequency in Hz.
            high: High cutoff frequency in Hz.
            order: Filter order.

        Returns:
            Filtered data of same shape.
        """
        nyquist = self.sfreq / 2
        b, a = butter(order, [low / nyquist, high / nyquist], btype="band")
        return filtfilt(b, a, data, axis=-1)
