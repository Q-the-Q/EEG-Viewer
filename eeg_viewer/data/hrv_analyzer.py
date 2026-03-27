"""HRV analysis: Pan-Tompkins R-peak detection, time/frequency domain metrics,
Poincare plot, and multi-band heart-brain coherence.

Ported from Swift HRVAnalyzer -- identical algorithms and parameters.
"""

import numpy as np
from scipy.signal import butter, filtfilt, welch, coherence as scipy_coherence
from ..utils.constants import (
    HRV_INTERPOLATION_RATE, HRV_PSD_NPERSEG, HRV_PSD_NOVERLAP,
    HRV_LF_BAND, HRV_HF_BAND, HRV_TOTAL_BAND,
    R_PEAK_REFRACTORY_MS, R_PEAK_MIN_RR_MS, R_PEAK_MAX_RR_MS,
    ECG_BANDPASS_LOW, ECG_BANDPASS_HIGH,
    HB_COHERENCE_BANDS, HB_COHERENCE_LF_BAND,
    HB_COHERENCE_MIN_NPERSEG, HB_COHERENCE_MAX_NPERSEG,
    EEG_ENVELOPE_WINDOW_SEC, EEG_ENVELOPE_STEP_SEC,
    ARTIFACT_THRESHOLD_UV,
)


def bandpass(signal, low, high, sfreq, order=4):
    """Zero-phase Butterworth bandpass filter."""
    nyq = sfreq / 2.0
    b, a = butter(order, [low / nyq, high / nyq], btype='band')
    return filtfilt(b, a, signal)


def detect_r_peaks(ecg, sfreq):
    """Pan-Tompkins R-peak detection. Returns array of sample indices.

    Tries both polarities, uses whichever finds more peaks.
    Falls back to simple peak detection if <5 peaks found.
    """
    peaks_normal = _pan_tompkins(ecg, sfreq)
    peaks_inverted = _pan_tompkins(-ecg, sfreq)

    if len(peaks_normal) >= len(peaks_inverted) and len(peaks_normal) >= 5:
        return peaks_normal
    elif len(peaks_inverted) >= 5:
        return peaks_inverted
    # Fallback
    return _simple_peak_detect(ecg, sfreq)


def _pan_tompkins(signal, sfreq):
    """Core Pan-Tompkins algorithm."""
    # Bandpass 5-15 Hz
    filtered = bandpass(signal, ECG_BANDPASS_LOW, ECG_BANDPASS_HIGH, sfreq)

    # Normalize
    mean = np.mean(filtered)
    std = np.std(filtered)
    if std > 0:
        normalized = (filtered - mean) / std
    else:
        return np.array([], dtype=int)

    n = len(normalized)

    # 5-point derivative
    diff = np.zeros(n)
    for i in range(2, n - 2):
        diff[i] = -normalized[i - 2] - 2 * normalized[i - 1] + 2 * normalized[i + 1] + normalized[i + 2]

    # Square
    squared = diff ** 2

    # Moving window integration (~150 ms)
    win_len = max(1, int(0.15 * sfreq))
    integrated = np.zeros(n)
    running_sum = 0.0
    for i in range(n):
        running_sum += squared[i]
        if i >= win_len:
            running_sum -= squared[i - win_len]
        integrated[i] = running_sum / min(i + 1, win_len)

    # Adaptive threshold
    sorted_int = np.sort(integrated)
    p90 = sorted_int[int(0.90 * len(sorted_int))]
    p50 = sorted_int[int(0.50 * len(sorted_int))]
    threshold = p50 + 0.3 * (p90 - p50)

    # Peak detection with refractory period
    refractory = max(1, int(R_PEAK_REFRACTORY_MS / 1000 * sfreq))
    search_radius = max(1, int(0.075 * sfreq))
    peaks = []
    recent_vals = []
    last_peak = -refractory

    for i in range(1, n - 1):
        if integrated[i] <= threshold:
            continue
        if integrated[i] < integrated[i - 1] or integrated[i] < integrated[i + 1]:
            continue  # not a local max
        if i - last_peak < refractory:
            continue

        # Refine in raw signal
        lo = max(0, i - search_radius)
        hi = min(n, i + search_radius + 1)
        refined = lo + np.argmax(filtered[lo:hi])
        peaks.append(refined)
        last_peak = refined

        # Update adaptive threshold
        recent_vals.append(integrated[i])
        if len(recent_vals) > 8:
            recent_vals.pop(0)
        threshold = 0.35 * np.mean(recent_vals)

    peaks = np.array(peaks, dtype=int)

    # Search-back for missed beats
    if len(peaks) >= 2:
        rr_samples = np.diff(peaks)
        mean_rr = np.mean(rr_samples)
        extra = []
        for i in range(1, len(peaks)):
            gap = peaks[i] - peaks[i - 1]
            if gap <= 1.8 * mean_rr:
                continue
            lo = peaks[i - 1] + refractory
            hi = peaks[i] - refractory
            if lo >= hi:
                continue
            seg = integrated[lo:hi]
            best_idx = lo + np.argmax(seg)
            if seg[best_idx - lo] > 0.3 * threshold:
                # Refine
                rlo = max(0, best_idx - search_radius)
                rhi = min(n, best_idx + search_radius + 1)
                refined = rlo + np.argmax(filtered[rlo:rhi])
                # Check refractory
                ok = True
                for p in peaks:
                    if abs(refined - p) < refractory:
                        ok = False
                        break
                if ok:
                    extra.append(refined)
        if extra:
            peaks = np.sort(np.concatenate([peaks, extra]))

    return peaks


def _simple_peak_detect(ecg, sfreq):
    """Fallback: absolute-value envelope peak detection."""
    # Highpass at 1 Hz
    nyq = sfreq / 2.0
    b, a = butter(2, 1.0 / nyq, btype='high')
    hp = filtfilt(b, a, ecg)

    envelope = np.abs(hp)
    smooth_len = max(1, int(0.1 * sfreq))
    kernel = np.ones(smooth_len) / smooth_len
    smoothed = np.convolve(envelope, kernel, mode='same')

    sorted_s = np.sort(smoothed)
    p50 = sorted_s[int(0.50 * len(sorted_s))]
    p75 = sorted_s[int(0.75 * len(sorted_s))]
    threshold = p50 + 0.5 * (p75 - p50)

    refractory = max(1, int(R_PEAK_REFRACTORY_MS / 1000 * sfreq))
    radius = max(1, int(0.05 * sfreq))

    peaks = []
    last_peak = -refractory
    for i in range(1, len(smoothed) - 1):
        if smoothed[i] <= threshold:
            continue
        if smoothed[i] < smoothed[i - 1] or smoothed[i] < smoothed[i + 1]:
            continue
        if i - last_peak < refractory:
            continue
        lo = max(0, i - radius)
        hi = min(len(ecg), i + radius + 1)
        refined = lo + np.argmax(np.abs(ecg[lo:hi]))
        peaks.append(refined)
        last_peak = refined

    return np.array(peaks, dtype=int)


def compute_rr_intervals(peaks, sfreq):
    """Compute validated RR intervals in milliseconds."""
    if len(peaks) < 2:
        return np.array([])
    rr = np.diff(peaks) / sfreq * 1000.0  # ms
    # Filter physiologically valid range
    mask = (rr >= R_PEAK_MIN_RR_MS) & (rr <= R_PEAK_MAX_RR_MS)
    return rr[mask]


def compute_time_domain(rr_ms):
    """Time-domain HRV metrics.

    Returns dict with: meanHR, sdnn, rmssd, pnn50
    """
    if len(rr_ms) < 2:
        return {"meanHR": 0, "sdnn": 0, "rmssd": 0, "pnn50": 0}

    mean_rr = np.mean(rr_ms)
    mean_hr = 60000.0 / mean_rr if mean_rr > 0 else 0

    sdnn = np.std(rr_ms, ddof=1)  # Bessel's correction

    diffs = np.diff(rr_ms)
    rmssd = np.sqrt(np.mean(diffs ** 2))
    pnn50 = 100.0 * np.sum(np.abs(diffs) > 50) / len(diffs) if len(diffs) > 0 else 0

    return {"meanHR": mean_hr, "sdnn": sdnn, "rmssd": rmssd, "pnn50": pnn50}


def compute_poincare(rr_ms):
    """Poincare plot analysis.

    Returns dict with: rr_n, rr_n1, sd1, sd2
    """
    if len(rr_ms) < 3:
        return {"rr_n": [], "rr_n1": [], "sd1": 0, "sd2": 0}

    rr_n = rr_ms[:-1]
    rr_n1 = rr_ms[1:]
    sd1 = np.std(rr_n1 - rr_n, ddof=1) / np.sqrt(2)
    sd2 = np.std(rr_n1 + rr_n, ddof=1) / np.sqrt(2)

    return {"rr_n": rr_n, "rr_n1": rr_n1, "sd1": sd1, "sd2": sd2}


def _interpolate_rr(peaks, rr_ms, sfreq, target_rate=HRV_INTERPOLATION_RATE):
    """Interpolate RR intervals to uniform sample rate."""
    if len(rr_ms) < 2:
        return np.array([]), target_rate
    # Recompute all RR intervals and midpoints, then apply the same
    # physiological filter so timestamps align with the filtered rr_ms.
    all_rr = np.diff(peaks) / sfreq * 1000.0
    all_times = (peaks[:-1] + peaks[1:]) / 2.0 / sfreq
    mask = (all_rr >= R_PEAK_MIN_RR_MS) & (all_rr <= R_PEAK_MAX_RR_MS)
    rr_times = all_times[mask]
    # Uniform time grid
    t_start = rr_times[0]
    t_end = rr_times[-1]
    t_uniform = np.arange(t_start, t_end, 1.0 / target_rate)
    rr_interp = np.interp(t_uniform, rr_times, rr_ms)
    return rr_interp, target_rate


def compute_frequency_domain(peaks, rr_ms, sfreq):
    """Frequency-domain HRV: Welch PSD of interpolated RR series.

    Returns dict with: freqs, psd, lf_power, hf_power, lf_hf_ratio, total_power
    """
    rr_interp, fs = _interpolate_rr(peaks, rr_ms, sfreq)
    if len(rr_interp) < 8:
        return {
            "freqs": np.array([]), "psd": np.array([]),
            "lf_power": 0, "hf_power": 0, "lf_hf_ratio": 0, "total_power": 0,
        }

    if len(rr_interp) < HRV_PSD_NPERSEG:
        nperseg = max(8, _prev_power_of_two(len(rr_interp)))
    else:
        nperseg = HRV_PSD_NPERSEG

    # Detrend
    rr_interp = rr_interp - np.mean(rr_interp)

    freqs, psd = welch(rr_interp, fs=fs, nperseg=nperseg,
                       noverlap=nperseg // 2, window='hann')

    lf_power = _band_power(freqs, psd, HRV_LF_BAND)
    hf_power = _band_power(freqs, psd, HRV_HF_BAND)
    total_power = _band_power(freqs, psd, HRV_TOTAL_BAND)
    lf_hf = lf_power / hf_power if hf_power > 0 else 0

    return {
        "freqs": freqs, "psd": psd,
        "lf_power": lf_power, "hf_power": hf_power,
        "lf_hf_ratio": lf_hf, "total_power": total_power,
    }


def compute_heart_brain_coherence(ecg, eeg_data, eeg_channel_names, sfreq,
                                  exclusions=None):
    """Multi-band heart-brain coherence (Delta, Theta, Alpha).

    Args:
        ecg: 1D array, ECG signal
        eeg_data: 2D array (n_channels, n_samples)
        eeg_channel_names: list of str
        sfreq: float, sampling rate
        exclusions: list of (start_sec, end_sec) to exclude

    Returns dict with per-band results:
        {band_name: {"channels": {ch: coh_value}, "mean": float}}
        and "best_band": str
    """
    # R-peak detection on (optionally excluded) ECG
    ecg_clean = _apply_exclusions(ecg, sfreq, exclusions)
    peaks = detect_r_peaks(ecg_clean, sfreq)
    rr_ms = compute_rr_intervals(peaks, sfreq)
    if len(rr_ms) < 10:
        return {"error": "Too few R-peaks for coherence analysis"}

    # Interpolate cardiac signal at 4 Hz
    rr_interp, fs = _interpolate_rr(peaks, rr_ms, sfreq)
    if len(rr_interp) < HB_COHERENCE_MIN_NPERSEG:
        return {"error": "Recording too short for coherence"}
    cardiac = rr_interp - np.mean(rr_interp)

    # Compute cardiac start time for EEG envelope alignment
    cardiac_start_sec = (peaks[0] + peaks[1]) / 2.0 / sfreq

    results = {}
    best_band = None
    best_mean = -1

    for band_name, (f_low, f_high) in HB_COHERENCE_BANDS.items():
        channel_coherences = {}

        for ch_idx, ch_name in enumerate(eeg_channel_names):
            eeg_ch = eeg_data[ch_idx].copy()

            # Artifact rejection: zero dirty epochs (preserve timeline)
            epoch_len = int(2.0 * sfreq)
            for start in range(0, len(eeg_ch) - epoch_len + 1, epoch_len):
                epoch = eeg_ch[start:start + epoch_len]
                ptp = np.max(epoch) - np.min(epoch)
                if ptp * 1e6 > ARTIFACT_THRESHOLD_UV:
                    eeg_ch[start:start + epoch_len] = 0.0

            # Apply exclusions
            eeg_ch = _apply_exclusions(eeg_ch, sfreq, exclusions)

            # Bandpass into band
            try:
                bp = bandpass(eeg_ch, f_low, f_high, sfreq)
            except Exception:
                continue

            # Windowed RMS envelope at ~4 Hz, aligned to cardiac start time
            win_samples = int(EEG_ENVELOPE_WINDOW_SEC * sfreq)
            step_samples = int(EEG_ENVELOPE_STEP_SEC * sfreq)
            start_sample = int(cardiac_start_sec * sfreq)
            n_windows = max(1, (len(bp) - start_sample - win_samples) // step_samples + 1)
            envelope = np.zeros(n_windows)
            for w in range(n_windows):
                s = start_sample + w * step_samples
                e = s + win_samples
                seg = bp[s:e]
                envelope[w] = np.sqrt(np.mean(seg ** 2))

            # Trim to match cardiac length
            min_len = min(len(cardiac), len(envelope))
            if min_len < 8:
                continue
            c = cardiac[:min_len]
            e = envelope[:min_len] - np.mean(envelope[:min_len])

            # Adaptive nperseg
            nperseg = _adaptive_nperseg(min_len)

            # Coherence
            try:
                freqs, coh = scipy_coherence(c, e, fs=fs,
                                             nperseg=nperseg, noverlap=nperseg // 2)
            except Exception:
                continue

            # Average coherence in LF band
            mask = (freqs >= HB_COHERENCE_LF_BAND[0]) & (freqs <= HB_COHERENCE_LF_BAND[1])
            if np.any(mask):
                channel_coherences[ch_name] = float(np.mean(coh[mask]))

        band_mean = np.mean(list(channel_coherences.values())) if channel_coherences else 0
        results[band_name] = {"channels": channel_coherences, "mean": band_mean}

        if band_mean > best_mean:
            best_mean = band_mean
            best_band = band_name

    results["best_band"] = best_band
    return results


def _band_power(freqs, psd, band):
    """Trapezoidal integration of PSD within band."""
    mask = (freqs >= band[0]) & (freqs <= band[1])
    if not np.any(mask):
        return 0.0
    return float(np.trapezoid(psd[mask], freqs[mask]))


def _prev_power_of_two(n):
    """Largest power of two <= n."""
    p = 1
    while p * 2 <= n:
        p *= 2
    return p


def _adaptive_nperseg(min_len):
    """Choose nperseg for coherence: power-of-two, clamped to [MIN, MAX]."""
    if min_len >= HB_COHERENCE_MAX_NPERSEG:
        return HB_COHERENCE_MAX_NPERSEG
    elif min_len >= HB_COHERENCE_MIN_NPERSEG:
        return HB_COHERENCE_MIN_NPERSEG
    else:
        return max(8, _prev_power_of_two(min_len))


def _apply_exclusions(signal, sfreq, exclusions):
    """Remove exclusion time ranges from signal, concatenating kept segments."""
    if not exclusions:
        return signal
    n = len(signal)
    # Convert to sample ranges and sort
    ranges = sorted(
        (int(s * sfreq), min(int(e * sfreq), n))
        for s, e in exclusions
    )
    # Merge overlapping
    merged = [ranges[0]]
    for s, e in ranges[1:]:
        if s <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    # Build included segments
    segments = []
    pos = 0
    for s, e in merged:
        if pos < s:
            segments.append(signal[pos:s])
        pos = e
    if pos < n:
        segments.append(signal[pos:n])
    return np.concatenate(segments) if segments else np.array([])


def run_full_analysis(ecg, sfreq, eeg_data=None, eeg_channel_names=None,
                      exclusions=None):
    """Run complete HRV analysis pipeline.

    Args:
        ecg: 1D array, ECG signal
        sfreq: float, sampling rate
        eeg_data: optional 2D array for heart-brain coherence
        eeg_channel_names: optional list of str
        exclusions: optional list of (start_sec, end_sec) tuples

    Returns dict with all results.
    """
    ecg_clean = _apply_exclusions(ecg, sfreq, exclusions)
    peaks = detect_r_peaks(ecg_clean, sfreq)
    rr_ms = compute_rr_intervals(peaks, sfreq)

    results = {
        "peaks": peaks,
        "rr_ms": rr_ms,
        "ecg_filtered": bandpass(ecg_clean, ECG_BANDPASS_LOW, ECG_BANDPASS_HIGH, sfreq),
        "time_domain": compute_time_domain(rr_ms),
        "poincare": compute_poincare(rr_ms),
        "frequency_domain": compute_frequency_domain(peaks, rr_ms, sfreq),
    }

    # When exclusions are applied, also provide original-timeline display data
    # so the ECG plot shows wall-clock time with peaks in correct positions.
    if exclusions:
        results["ecg_display"] = bandpass(ecg, ECG_BANDPASS_LOW, ECG_BANDPASS_HIGH, sfreq)
        results["peaks_display"] = detect_r_peaks(ecg, sfreq)

    if eeg_data is not None and eeg_channel_names is not None:
        results["heart_brain"] = compute_heart_brain_coherence(
            ecg, eeg_data, eeg_channel_names, sfreq, exclusions
        )

    return results
