"""EEG Viewer for iPad (Pyto) — standalone matplotlib-based qEEG analysis.

Run this script in Pyto on iPad. It uses only numpy, scipy, and matplotlib —
no MNE, no PyQt5, no C extensions beyond what Pyto bundles.

Usage:
    1. Place this file and the companion modules in the same folder on iPad
    2. Place an .edf file in the same folder (or adjust the path below)
    3. Run this script in Pyto

Required companion files (same directory):
    - edf_reader.py
    - topomap.py
    - signal_processing.py
    - constants.py
"""

import os
import numpy as np
import matplotlib
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
from scipy.signal import spectrogram as scipy_spectrogram

from edf_reader import read_edf
from topomap import plot_topomap, ZSCORE_CMAP
from signal_processing import (
    compute_psd, compute_band_power, compute_relative_power,
    bandpass_filter, highpass_filter, average_reference,
    reject_artifacts, compute_zscores_within,
)
from constants import (
    FREQ_BANDS, STANDARD_1020_CHANNELS, REGION_MAP, ZSCORE_VMIN, ZSCORE_VMAX,
    BAND_SHADING,
)


def find_edf_file():
    """Find an EDF file in the current directory."""
    cwd = os.path.dirname(os.path.abspath(__file__))
    for f in os.listdir(cwd):
        if f.lower().endswith(".edf"):
            return os.path.join(cwd, f)
    # Also check parent directory
    parent = os.path.dirname(cwd)
    for f in os.listdir(parent):
        if f.lower().endswith(".edf"):
            return os.path.join(parent, f)
    return None


def preprocess(edf):
    """Preprocess EDF data: select EEG channels, average reference, filter.

    Returns:
        (eeg_data, eeg_channels, sfreq) — data in Volts, average-referenced, 1Hz HP filtered.
    """
    # Identify EEG channels (exclude ECG/EKG)
    eeg_indices = []
    eeg_channels = []
    for i, ch in enumerate(edf["channel_names"]):
        if ch.upper() not in ("ECG", "EKG") and ch in STANDARD_1020_CHANNELS:
            eeg_indices.append(i)
            eeg_channels.append(ch)

    eeg_data = edf["data"][eeg_indices]
    sfreq = edf["sfreq"]

    # Average reference (matches clinical qEEG preprocessing)
    eeg_data = average_reference(eeg_data)

    # 1 Hz high-pass filter (removes DC drift, eye-blink artifacts)
    eeg_data = highpass_filter(eeg_data, sfreq, cutoff=1.0)

    return eeg_data, eeg_channels, sfreq


def run_analysis(eeg_data, eeg_channels, sfreq):
    """Run full qEEG analysis pipeline.

    Returns dict with all results.
    """
    print("  Rejecting artifacts...")
    clean_data, artifact_stats = reject_artifacts(eeg_data, sfreq)
    pct = artifact_stats["rejected"] / max(artifact_stats["total"], 1) * 100
    print(f"  -> {artifact_stats['clean']}/{artifact_stats['total']} epochs clean ({pct:.1f}% rejected)")

    print("  Computing PSD...")
    freqs, psd = compute_psd(clean_data, sfreq)

    print("  Computing band powers and Z-scores...")
    band_powers = {}
    relative_powers = {}
    zscores = {}
    for band_name, band_range in FREQ_BANDS.items():
        band_powers[band_name] = compute_band_power(psd, freqs, band_range)
        relative_powers[band_name] = compute_relative_power(psd, freqs, band_range)
        zscores[band_name] = compute_zscores_within(relative_powers[band_name])

    return {
        "freqs": freqs,
        "psd": psd,
        "band_powers": band_powers,
        "relative_powers": relative_powers,
        "zscores": zscores,
        "clean_data": clean_data,
        "artifact_stats": artifact_stats,
        "eeg_channels": eeg_channels,
        "sfreq": sfreq,
    }


def plot_magnitude_spectra(results, axes):
    """Plot magnitude spectra for Frontal, Central, Posterior regions."""
    freqs = results["freqs"]
    psd = results["psd"]
    channels = results["eeg_channels"]

    regions = ["Frontal", "Central", "Posterior"]
    for col, region in enumerate(regions):
        ax = axes[col]
        region_chs = REGION_MAP.get(region, [])
        indices = [channels.index(ch) for ch in region_chs if ch in channels]
        if not indices:
            continue

        region_psd = np.mean(psd[indices], axis=0)
        amplitude = np.sqrt(region_psd) * 1e6  # µV

        freq_mask = (freqs >= 1) & (freqs <= 25)
        f = freqs[freq_mask]
        a = amplitude[freq_mask]

        # Band shading
        for band_name, shade_color in BAND_SHADING.items():
            f_low, f_high = FREQ_BANDS[band_name]
            ax.axvspan(f_low, f_high, alpha=0.3, color=shade_color)

        # Band boundaries
        for boundary in [4, 8, 13]:
            ax.axvline(boundary, color="gray", linewidth=0.8, linestyle="--", alpha=0.5)

        # 1 Hz gridlines
        for hz in range(1, 26):
            ax.axvline(hz, color="#E0E0E0", linewidth=0.3, alpha=0.5)

        ax.plot(f, a, color="#1a1a2e", linewidth=1.2)
        ax.fill_between(f, 0, a, alpha=0.15, color="#1a1a2e")

        max_amp = np.max(a)
        y_max = np.ceil(max_amp * 10) / 10
        if y_max < max_amp * 1.05:
            y_max = max_amp * 1.05

        ax.set_xlim(1, 25)
        ax.set_ylim(0, y_max)
        ax.set_xlabel("Frequency (Hz)", fontsize=9)
        ax.set_ylabel("Amplitude (µV)", fontsize=9)
        ax.set_title(f"{region}\n(max {max_amp:.2f} µV)", fontsize=10, fontweight="bold")
        ax.grid(True, axis="y", alpha=0.3)


def plot_topomaps(results, axes):
    """Plot 4 topomaps (Delta, Theta, Alpha, Beta) + colorbar."""
    bands = list(FREQ_BANDS.keys())
    channels = results["eeg_channels"]

    for i, band_name in enumerate(bands):
        ax = axes[i]
        zscores = results["zscores"][band_name]
        f_low, f_high = FREQ_BANDS[band_name]

        im, _ = plot_topomap(
            zscores, channels, ax=ax,
            vmin=ZSCORE_VMIN, vmax=ZSCORE_VMAX,
        )
        ax.set_title(f"{band_name}\n({f_low:.0f}-{f_high:.0f} Hz)", fontsize=10, fontweight="bold")

    # Colorbar in the 5th axis
    cbar_ax = axes[4]
    sm = plt.cm.ScalarMappable(cmap=ZSCORE_CMAP, norm=plt.Normalize(ZSCORE_VMIN, ZSCORE_VMAX))
    sm.set_array([])
    cbar = plt.colorbar(sm, cax=cbar_ax)
    cbar.set_ticks([ZSCORE_VMIN, 0, ZSCORE_VMAX])
    cbar.set_ticklabels([f"{ZSCORE_VMIN:.1f}Z", "0", f"{ZSCORE_VMAX:.1f}Z"])


def plot_band_gfp(eeg_data, sfreq, ax):
    """Plot Global Field Power traces for each band."""
    colors = {"Delta": "#6A0DAD", "Theta": "#228B22", "Alpha": "#DAA520", "Beta": "#CC3333"}
    n_samples = eeg_data.shape[1]
    times = np.arange(n_samples) / sfreq

    # Downsample for plotting
    max_pts = 20000
    step = max(1, n_samples // max_pts)
    t_ds = times[::step]

    for band_name, (f_low, f_high) in FREQ_BANDS.items():
        filtered = bandpass_filter(eeg_data, sfreq, f_low, f_high)
        gfp = np.std(filtered, axis=0) * 1e6  # µV
        gfp_ds = gfp[::step]
        ax.plot(t_ds, gfp_ds, label=band_name, color=colors[band_name], linewidth=0.8, alpha=0.8)

    ax.set_xlabel("Time (s)", fontsize=10)
    ax.set_ylabel("GFP (µV)", fontsize=10)
    ax.set_title("Band Power — Global Field Power", fontsize=11, fontweight="bold")
    ax.legend(loc="upper right", fontsize=9)
    ax.grid(True, alpha=0.3)


def plot_spectrogram(eeg_data, sfreq, ax):
    """Plot global GFP spectrogram."""
    gfp_signal = np.std(eeg_data, axis=0)

    f, t, Sxx = scipy_spectrogram(
        gfp_signal, fs=sfreq, window="hann", nperseg=256, noverlap=192, scaling="density",
    )
    Sxx_db = 10 * np.log10(Sxx + 1e-20)

    im = ax.pcolormesh(
        t, f, Sxx_db, shading="gouraud", cmap="viridis",
        vmin=np.percentile(Sxx_db, 5), vmax=np.percentile(Sxx_db, 95),
    )
    for boundary in [1, 4, 8, 13, 25]:
        ax.axhline(boundary, color="white", linewidth=0.5, linestyle="--", alpha=0.5)
    ax.set_ylim(0, 30)
    ax.set_xlabel("Time (s)", fontsize=10)
    ax.set_ylabel("Frequency (Hz)", fontsize=10)
    ax.set_title("Global Field Power Spectrogram", fontsize=11, fontweight="bold")
    plt.colorbar(im, ax=ax, label="Power (dB/Hz)", shrink=0.8)


# ============================================================
# MAIN
# ============================================================
def main():
    print("=" * 50)
    print("EEG Viewer for iPad")
    print("=" * 50)

    # Find EDF file
    edf_path = find_edf_file()
    if edf_path is None:
        print("No .edf file found. Place an EDF file in the same directory.")
        return

    print(f"\nLoading: {os.path.basename(edf_path)}")
    edf = read_edf(edf_path)
    print(f"  {edf['n_channels']} channels, {edf['sfreq']:.0f} Hz, {edf['duration']:.0f}s")

    print("\nPreprocessing...")
    eeg_data, eeg_channels, sfreq = preprocess(edf)
    print(f"  {len(eeg_channels)} EEG channels: {', '.join(eeg_channels)}")

    print("\nRunning qEEG analysis...")
    results = run_analysis(eeg_data, eeg_channels, sfreq)

    # --- Page 1: qEEG Report (Spectra + Topomaps) ---
    print("\nGenerating qEEG Report...")
    fig1 = plt.figure(figsize=(14, 10))
    fig1.suptitle("qEEG Analysis Report", fontsize=14, fontweight="bold", y=0.98)
    gs1 = GridSpec(2, 5, figure=fig1, hspace=0.35, wspace=0.4,
                   height_ratios=[1, 1.2])

    # Spectra: top row, first 3 columns
    spectra_axes = [fig1.add_subplot(gs1[0, i]) for i in range(3)]
    plot_magnitude_spectra(results, spectra_axes)
    # Topomaps: bottom row, all 5 columns (4 maps + colorbar)
    topo_axes = [fig1.add_subplot(gs1[1, i]) for i in range(5)]
    plot_topomaps(results, topo_axes)

    # Add artifact stats text
    stats = results["artifact_stats"]
    pct = stats["rejected"] / max(stats["total"], 1) * 100
    fig1.text(
        0.75, 0.92,
        f"Epochs: {stats['clean']}/{stats['total']} clean ({pct:.1f}% rejected)",
        fontsize=9, ha="center", color="#666",
    )

    plt.show(block=False)

    # --- Page 2: Band Waveforms + Spectrogram ---
    print("Generating Band Waveforms...")
    fig2, (ax_gfp, ax_spec) = plt.subplots(2, 1, figsize=(14, 8))
    fig2.suptitle("Band Power & Spectrogram", fontsize=14, fontweight="bold", y=0.98)
    fig2.subplots_adjust(hspace=0.35)

    plot_band_gfp(results["clean_data"], sfreq, ax_gfp)
    plot_spectrogram(results["clean_data"], sfreq, ax_spec)

    plt.show()
    print("\nDone!")


if __name__ == "__main__":
    main()
