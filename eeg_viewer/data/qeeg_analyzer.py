"""Orchestrates all qEEG computations: PSD, band powers, Z-scores, coherence, asymmetry, peak frequencies.

Includes epoch-based artifact rejection to exclude movement/muscle/blink artifacts
before spectral analysis, matching the preprocessing used by clinical qEEG software.
"""

import numpy as np
import mne

from ..utils.constants import FREQ_BANDS, TOTAL_POWER_RANGE
from ..data.channel_map import REGION_MAP, ASYMMETRY_PAIRS


class QEEGAnalyzer:
    """Runs the full qEEG analysis pipeline."""

    def __init__(self, loader, processor, normative, time_range=None):
        self.loader = loader
        self.processor = processor
        self.normative = normative

        # Time range for analysis: (start_sec, end_sec) or None for full recording
        self.time_range = time_range

        # EEG channel info
        self.eeg_channels = loader.get_eeg_channels()
        self.n_eeg = len(self.eeg_channels)

        # Results
        self.freqs = None
        self.psd = None          # (n_eeg, n_freqs) in V^2/Hz
        self.band_powers = {}    # band_name -> (n_eeg,)
        self.relative_powers = {}  # band_name -> (n_eeg,)
        self.zscores = {}        # band_name -> (n_eeg,)
        self.coherence = {}      # band_name -> (n_eeg, n_eeg)
        self.asymmetry = {}      # band_name -> list of ((left, right), value)
        self.peak_freqs = {}     # channel_name -> {"alpha_peak": float, "dominant": float}

        # Artifact rejection stats
        self.artifact_stats = {}  # populated after rejection

        # Channel quality assessment
        self.channel_quality = {}  # channel_name -> 'good' or 'poor'

        # Clean data cache (for coherence which needs time-domain data)
        self._clean_data = None

        # Progress callback (set by worker)
        self._progress_callback = None

    def _get_eeg_data(self):
        """Fetch EEG data, respecting the selected time range."""
        if self.time_range:
            start_sec, end_sec = self.time_range
            return self.loader.get_data_range(self.eeg_channels, start_sec, end_sec)
        return self.loader.get_all_data(self.eeg_channels)

    def set_progress_callback(self, callback):
        self._progress_callback = callback

    def _report_progress(self, percent, message):
        if self._progress_callback:
            self._progress_callback(percent, message)

    def run_full_analysis(self):
        """Run all analyses sequentially."""
        self._report_progress(2, "Detecting high-impedance channels...")
        self._detect_channel_quality()

        self._report_progress(4, "Applying adaptive filtering...")
        self._apply_channel_filtering()

        self._report_progress(6, "Rejecting artifacts...")
        self._reject_artifacts()

        self._report_progress(10, "Computing power spectral density...")
        self._compute_psd()

        self._report_progress(20, "Computing band powers...")
        self._compute_band_powers()

        self._report_progress(35, "Computing Z-scores...")
        self._compute_zscores()

        self._report_progress(45, "Computing coherence...")
        self._compute_coherence()

        self._report_progress(85, "Computing asymmetry...")
        self._compute_asymmetry()

        self._report_progress(92, "Finding peak frequencies...")
        self._compute_peak_frequencies()

        self._report_progress(100, "Analysis complete")

    def _detect_channel_quality(self):
        """Detect high-impedance channels using spectral and statistical analysis."""
        data, _ = self._get_eeg_data()
        self.channel_quality = self.processor.detect_impedance_issues(data, self.eeg_channels)

    def _apply_channel_filtering(self):
        """Apply adaptive channel-specific filtering based on impedance assessment."""
        data, _ = self._get_eeg_data()
        # Store filtered data but keep original for artifact rejection
        self._filtered_data = self.processor.apply_adaptive_filtering(data, self.eeg_channels)

    def _reject_artifacts(self):
        """Apply epoch-based artifact rejection to EEG data.

        Segments the recording into 2-second epochs and rejects any epoch
        where any channel's peak-to-peak amplitude exceeds 100 µV. This
        removes movement artifacts, muscle bursts, and electrode pops that
        would otherwise distort spectral estimates and topomap patterns.

        Uses the adaptively filtered data to reduce false rejections from
        high-impedance channels.
        """
        # Use filtered data for artifact rejection (reduces false positives on noisy channels)
        if hasattr(self, '_filtered_data'):
            data = self._filtered_data
        else:
            data, _ = self._get_eeg_data()

        self._clean_data = self.processor.reject_artifacts(data)

        self.artifact_stats = {
            "total_epochs": self.processor.n_total_epochs,
            "clean_epochs": self.processor.n_clean_epochs,
            "rejected_epochs": self.processor.n_total_epochs - self.processor.n_clean_epochs,
            "threshold_uv": self.processor.rejection_threshold,
            "pct_rejected": (
                (self.processor.n_total_epochs - self.processor.n_clean_epochs)
                / max(self.processor.n_total_epochs, 1) * 100
            ),
        }

    def _compute_psd(self):
        """Compute PSD on artifact-free data."""
        self.freqs, self.psd = self.processor.compute_psd_welch(self._clean_data)

    def _compute_band_powers(self):
        """Compute absolute and relative power for each frequency band."""
        for band_name, band_range in FREQ_BANDS.items():
            self.band_powers[band_name] = self.processor.compute_band_power(
                self.psd, self.freqs, band_range
            )
            self.relative_powers[band_name] = self.processor.compute_relative_power(
                self.psd, self.freqs, band_range
            )

    def _compute_zscores(self):
        """Compute Z-scores for topomaps."""
        for band_name in FREQ_BANDS:
            rel_power = self.relative_powers[band_name]
            self.zscores[band_name] = self.normative.compute_zscores(
                rel_power, band_name=band_name
            )

    def recompute_zscores(self):
        """Recompute Z-scores only (for when method changes)."""
        self._compute_zscores()

    def _compute_coherence(self):
        """Compute coherence between all channel pairs per band.

        Uses artifact-free data for coherence computation.
        """
        data = self._clean_data

        # Pre-compute coherence for all pairs
        n = self.n_eeg
        coh_spectra = {}
        total_pairs = n * (n - 1) // 2
        done = 0

        for i in range(n):
            for j in range(i + 1, n):
                f, Cxy = self.processor.compute_coherence(data[i], data[j])
                coh_spectra[(i, j)] = Cxy
                done += 1
                if done % 20 == 0:
                    pct = 45 + int(40 * done / total_pairs)
                    self._report_progress(pct, f"Computing coherence ({done}/{total_pairs})...")

        # Average coherence within each band
        for band_name, (f_low, f_high) in FREQ_BANDS.items():
            band_mask = (f >= f_low) & (f <= f_high)
            matrix = np.eye(n)  # diagonal = 1.0
            for i in range(n):
                for j in range(i + 1, n):
                    Cxy = coh_spectra[(i, j)]
                    mean_coh = np.mean(Cxy[band_mask])
                    matrix[i, j] = mean_coh
                    matrix[j, i] = mean_coh
            self.coherence[band_name] = matrix

    def _compute_asymmetry(self):
        """Compute hemispheric asymmetry: ln(Right) - ln(Left) for homologous pairs."""
        for band_name in FREQ_BANDS:
            pairs_values = []
            for left_ch, right_ch in ASYMMETRY_PAIRS:
                if left_ch in self.eeg_channels and right_ch in self.eeg_channels:
                    left_idx = self.eeg_channels.index(left_ch)
                    right_idx = self.eeg_channels.index(right_ch)
                    left_power = self.band_powers[band_name][left_idx]
                    right_power = self.band_powers[band_name][right_idx]
                    # Avoid log(0)
                    left_power = max(left_power, 1e-20)
                    right_power = max(right_power, 1e-20)
                    asym = np.log(right_power) - np.log(left_power)
                    pairs_values.append(((left_ch, right_ch), float(asym)))
            self.asymmetry[band_name] = pairs_values

    def _compute_peak_frequencies(self):
        """Find peak frequency per channel: alpha peak and overall dominant frequency."""
        alpha_low, alpha_high = FREQ_BANDS["Alpha"]
        total_low, total_high = TOTAL_POWER_RANGE
        alpha_mask = (self.freqs >= alpha_low) & (self.freqs <= alpha_high)
        total_mask = (self.freqs >= total_low) & (self.freqs <= total_high)

        for i, ch in enumerate(self.eeg_channels):
            ch_psd = self.psd[i]

            # Alpha peak frequency
            if np.any(alpha_mask) and np.any(ch_psd[alpha_mask] > 0):
                alpha_idx = np.argmax(ch_psd[alpha_mask])
                alpha_peak = self.freqs[alpha_mask][alpha_idx]
            else:
                alpha_peak = 0.0

            # Dominant frequency (overall)
            if np.any(total_mask) and np.any(ch_psd[total_mask] > 0):
                dom_idx = np.argmax(ch_psd[total_mask])
                dominant = self.freqs[total_mask][dom_idx]
            else:
                dominant = 0.0

            self.peak_freqs[ch] = {
                "alpha_peak": float(alpha_peak),
                "dominant": float(dominant),
            }

    def get_region_spectra(self, region):
        """Return averaged amplitude spectrum for a brain region.

        Args:
            region: One of 'Frontal', 'Central', 'Posterior'.

        Returns:
            Tuple of (freqs, mean_amplitude_spectrum).
        """
        channels = REGION_MAP.get(region, [])
        indices = [self.eeg_channels.index(ch) for ch in channels if ch in self.eeg_channels]
        if not indices:
            return self.freqs, np.zeros(len(self.freqs))

        # Average PSD across channels in the region
        region_psd = np.mean(self.psd[indices], axis=0)
        # Convert to amplitude spectrum (uV/sqrt(Hz)), multiply by 1e6 to convert V to uV
        amplitude = self.processor.compute_amplitude_spectrum(region_psd) * 1e6
        return self.freqs, amplitude

    def export_csv(self, file_path):
        """Export all numerical results to CSV."""
        import csv

        with open(file_path, "w", newline="") as f:
            writer = csv.writer(f)

            # Artifact rejection info
            if self.artifact_stats:
                writer.writerow(["=== Artifact Rejection ==="])
                writer.writerow([
                    f"Threshold: {self.artifact_stats['threshold_uv']:.0f} uV",
                    f"Clean epochs: {self.artifact_stats['clean_epochs']}/{self.artifact_stats['total_epochs']}",
                    f"Rejected: {self.artifact_stats['pct_rejected']:.1f}%",
                ])
                writer.writerow([])

            # Band powers
            writer.writerow(["=== Band Powers (Absolute) ==="])
            writer.writerow(["Channel"] + list(FREQ_BANDS.keys()))
            for i, ch in enumerate(self.eeg_channels):
                row = [ch]
                for band in FREQ_BANDS:
                    row.append(f"{self.band_powers[band][i]:.6e}")
                writer.writerow(row)

            writer.writerow([])

            # Relative powers
            writer.writerow(["=== Relative Powers ==="])
            writer.writerow(["Channel"] + list(FREQ_BANDS.keys()))
            for i, ch in enumerate(self.eeg_channels):
                row = [ch]
                for band in FREQ_BANDS:
                    row.append(f"{self.relative_powers[band][i]:.4f}")
                writer.writerow(row)

            writer.writerow([])

            # Z-scores
            writer.writerow([f"=== Z-Scores ({self.normative.get_method_label()}) ==="])
            writer.writerow(["Channel"] + list(FREQ_BANDS.keys()))
            for i, ch in enumerate(self.eeg_channels):
                row = [ch]
                for band in FREQ_BANDS:
                    row.append(f"{self.zscores[band][i]:.3f}")
                writer.writerow(row)

            writer.writerow([])

            # Asymmetry
            writer.writerow(["=== Hemispheric Asymmetry (ln(R) - ln(L)) ==="])
            writer.writerow(["Pair"] + list(FREQ_BANDS.keys()))
            for pair_idx in range(len(ASYMMETRY_PAIRS)):
                left, right = ASYMMETRY_PAIRS[pair_idx]
                row = [f"{left}-{right}"]
                for band in FREQ_BANDS:
                    asym_list = self.asymmetry[band]
                    if pair_idx < len(asym_list):
                        row.append(f"{asym_list[pair_idx][1]:.4f}")
                    else:
                        row.append("N/A")
                writer.writerow(row)

            writer.writerow([])

            # Peak frequencies
            writer.writerow(["=== Peak Frequencies ==="])
            writer.writerow(["Channel", "Alpha Peak (Hz)", "Dominant Freq (Hz)"])
            for ch in self.eeg_channels:
                pf = self.peak_freqs.get(ch, {})
                writer.writerow([
                    ch,
                    f"{pf.get('alpha_peak', 0):.2f}",
                    f"{pf.get('dominant', 0):.2f}",
                ])
