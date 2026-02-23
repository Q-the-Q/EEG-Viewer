"""Signal processing for iPad EEG Viewer — numpy/scipy only.

Portable copy of the desktop signal_processor.py with no package imports,
only flat-file imports compatible with Pyto on iPad.
"""

import numpy as np
from scipy.signal import welch, butter, filtfilt, coherence
from scipy.integrate import simpson

from constants import (
    PSD_NPERSEG, PSD_NOVERLAP, PSD_WINDOW, FREQ_BANDS, TOTAL_POWER_RANGE,
    EPOCH_DURATION_SEC, ARTIFACT_THRESHOLD_UV, MIN_CLEAN_EPOCHS,
)


def compute_psd(data, sfreq):
    """Compute PSD using Welch's method.

    Returns:
        (freqs, psd) where psd shape is (n_channels, n_freqs).
    """
    return welch(
        data, fs=sfreq, nperseg=PSD_NPERSEG, noverlap=PSD_NOVERLAP,
        window=PSD_WINDOW, detrend="constant", axis=-1,
    )


def compute_band_power(psd, freqs, band):
    """Absolute band power via Simpson integration."""
    f_low, f_high = band
    mask = (freqs >= f_low) & (freqs <= f_high)
    if not np.any(mask):
        return np.zeros(psd.shape[0])
    return simpson(psd[:, mask], x=freqs[mask], axis=1)


def compute_relative_power(psd, freqs, band):
    """Relative band power = band / total."""
    band_power = compute_band_power(psd, freqs, band)
    total_power = compute_band_power(psd, freqs, TOTAL_POWER_RANGE)
    total_power = np.where(total_power > 0, total_power, 1e-10)
    return band_power / total_power


def bandpass_filter(data, sfreq, low, high, order=4):
    """Apply bandpass Butterworth filter."""
    nyquist = sfreq / 2
    b, a = butter(order, [low / nyquist, high / nyquist], btype="band")
    return filtfilt(b, a, data, axis=-1)


def highpass_filter(data, sfreq, cutoff=1.0, order=4):
    """Apply high-pass Butterworth filter."""
    nyquist = sfreq / 2
    b, a = butter(order, cutoff / nyquist, btype="high")
    return filtfilt(b, a, data, axis=-1)


def average_reference(data):
    """Apply average reference: subtract mean across channels at each time point."""
    mean_signal = np.mean(data, axis=0, keepdims=True)
    return data - mean_signal


def reject_artifacts(data, sfreq, threshold_uv=None, epoch_sec=None):
    """Epoch-based artifact rejection.

    Returns:
        (clean_data, stats_dict)
    """
    threshold = threshold_uv or ARTIFACT_THRESHOLD_UV
    epoch_dur = epoch_sec or EPOCH_DURATION_SEC
    epoch_samples = int(epoch_dur * sfreq)
    n_epochs = data.shape[1] // epoch_samples

    if n_epochs == 0:
        return data, {"total": 0, "clean": 0, "rejected": 0, "threshold": threshold}

    clean_epochs = []
    for e in range(n_epochs):
        start = e * epoch_samples
        end = start + epoch_samples
        epoch = data[:, start:end]
        ptp_uv = (np.max(epoch, axis=1) - np.min(epoch, axis=1)) * 1e6
        if np.all(ptp_uv <= threshold):
            clean_epochs.append(epoch)

    # Progressively relax if too few clean epochs
    if len(clean_epochs) < MIN_CLEAN_EPOCHS:
        for relaxed in [150, 200, 300, 500]:
            clean_epochs = []
            for e in range(n_epochs):
                start = e * epoch_samples
                end = start + epoch_samples
                epoch = data[:, start:end]
                ptp_uv = (np.max(epoch, axis=1) - np.min(epoch, axis=1)) * 1e6
                if np.all(ptp_uv <= relaxed):
                    clean_epochs.append(epoch)
            threshold = relaxed
            if len(clean_epochs) >= MIN_CLEAN_EPOCHS:
                break

    if len(clean_epochs) < MIN_CLEAN_EPOCHS:
        stats = {"total": n_epochs, "clean": n_epochs, "rejected": 0, "threshold": float("inf")}
        return data, stats

    clean_data = np.concatenate(clean_epochs, axis=1)
    stats = {
        "total": n_epochs,
        "clean": len(clean_epochs),
        "rejected": n_epochs - len(clean_epochs),
        "threshold": threshold,
    }
    return clean_data, stats


def compute_zscores_within(channel_values):
    """Within-subject Z-scores."""
    mean = np.mean(channel_values)
    std = np.std(channel_values, ddof=1)
    if std < 1e-10:
        return np.zeros_like(channel_values)
    return (channel_values - mean) / std
