"""Z-score computation for topographic maps.

Provides two methods:
1. Within-subject: Z-score each channel relative to the mean/std across all channels.
2. Approximate normative: Z-score relative to published adult EEG norms.
"""

import numpy as np


# Approximate normative means and SDs for relative power (eyes-closed adults)
# Based on published literature (Thatcher et al., Johnstone et al.)
# These are APPROXIMATE and should be clearly labeled in the UI.
NORMATIVE_RELATIVE_POWER = {
    "Delta": {"mean": 0.28, "std": 0.09},
    "Theta": {"mean": 0.18, "std": 0.07},
    "Alpha": {"mean": 0.32, "std": 0.11},
    "Beta": {"mean": 0.14, "std": 0.06},
}


class NormativeDB:
    """Provides Z-score computation for topographic maps."""

    def __init__(self, method="within"):
        self._method = method

    def set_method(self, method):
        """Set Z-score computation method.

        Args:
            method: 'within' for within-subject or 'normative' for approximate normative.
        """
        self._method = method

    @property
    def method(self):
        return self._method

    def get_method_label(self):
        """Return human-readable label for the current method."""
        if self._method == "within":
            return "Within-Subject Z-Scores"
        return "Approximate Normative Z-Scores"

    def compute_zscores(self, channel_values, band_name=None):
        """Compute Z-scores using the selected method.

        Args:
            channel_values: Array of shape (n_channels,) with one value per channel.
            band_name: Frequency band name (required for normative method).

        Returns:
            Array of Z-scores, shape (n_channels,).
        """
        if self._method == "within":
            return self.compute_zscore_within_subject(channel_values)
        else:
            if band_name is None:
                raise ValueError("band_name required for normative Z-score method")
            return self.compute_zscore_normative(channel_values, band_name)

    @staticmethod
    def compute_zscore_within_subject(channel_values):
        """Z-score each channel relative to the mean/std across all channels.

        Z_i = (val_i - mean(vals)) / std(vals)

        This highlights which brain regions deviate from the subject's own average.
        """
        mean = np.mean(channel_values)
        std = np.std(channel_values, ddof=1)
        if std < 1e-10:
            return np.zeros_like(channel_values)
        return (channel_values - mean) / std

    @staticmethod
    def compute_zscore_normative(channel_values, band_name):
        """Z-score each channel relative to published normative means.

        Z_i = (val_i - norm_mean) / norm_std
        """
        if band_name not in NORMATIVE_RELATIVE_POWER:
            return np.zeros_like(channel_values)
        norm = NORMATIVE_RELATIVE_POWER[band_name]
        return (channel_values - norm["mean"]) / norm["std"]
