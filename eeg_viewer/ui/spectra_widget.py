"""Magnitude spectra plots for Frontal, Central, and Posterior regions.

Matches the NeuroSynchrony PDF report layout:
- Colored band shading (Delta, Theta, Alpha, Beta) with distinct light tints
- Light vertical gridlines at every 1 Hz
- Dashed vertical lines at band boundaries (4, 8, 13 Hz)
- Blue spectrum line
- Y-axis auto-scaled so the spectrum fits entirely within the plot
- Region labels on the left
"""

import numpy as np
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from PyQt5.QtWidgets import QWidget, QVBoxLayout

from ..utils.constants import FREQ_BANDS


# Colors matching the PDF exactly
_SPECTRUM_LINE_COLOR = "#3388CC"  # Medium blue matching PDF line

# Band shading colors - light tints matching the PDF
# The PDF shows subtle colored bands for each frequency range
_BAND_SHADING = {
    "Delta": {"range": (1.0, 4.0),  "color": "#D6EAF8"},  # Light blue
    "Theta": {"range": (4.0, 8.0),  "color": "#D5F5E3"},  # Light green tint
    "Alpha": {"range": (8.0, 13.0), "color": "#FCF3CF"},  # Light yellow tint
    "Beta":  {"range": (13.0, 25.0),"color": "#D4EFF7"},  # Light cyan
}

_GRID_LINE_COLOR = "#CCDDEE"     # Very light for 1 Hz gridlines
_BAND_BOUNDARY_COLOR = "#AACCDD" # Slightly darker for band boundary lines
_HGRID_COLOR = "#DDDDDD"         # Horizontal gridlines


class SpectraWidget(QWidget):
    """Three magnitude spectra plots matching the NeuroSynchrony PDF style."""

    REGIONS = ["Frontal", "Central", "Posterior"]

    def __init__(self, parent=None):
        super().__init__(parent)
        self._figure = Figure(figsize=(10, 8), dpi=100)
        self._figure.set_facecolor("white")
        self._canvas = FigureCanvasQTAgg(self._figure)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self._canvas)

    def plot_spectra(self, analyzer):
        """Plot magnitude spectra for Frontal, Central, Posterior regions."""
        self._figure.clear()

        for idx, region in enumerate(self.REGIONS):
            ax = self._figure.add_subplot(3, 1, idx + 1)
            freqs, amplitude = analyzer.get_region_spectra(region)

            # Display range 1-25 Hz (matching PDF)
            mask = (freqs >= 1) & (freqs <= 25)
            freqs_display = freqs[mask]
            amp_display = amplitude[mask]

            # ---- Band shading (colored tints for each frequency band) ----
            for band_name, band_info in _BAND_SHADING.items():
                f_low, f_high = band_info["range"]
                ax.axvspan(f_low, f_high, color=band_info["color"],
                           alpha=0.85, zorder=0)

            # ---- Light vertical gridlines at every 1 Hz ----
            for hz in range(1, 26):
                ax.axvline(hz, color=_GRID_LINE_COLOR, linewidth=0.4,
                           linestyle="-", zorder=1, alpha=0.6)

            # ---- Dashed lines at band boundaries (4, 8, 13 Hz) ----
            for boundary_hz in [4, 8, 13]:
                ax.axvline(
                    boundary_hz, color=_BAND_BOUNDARY_COLOR,
                    linewidth=0.9, linestyle="--", zorder=2,
                )

            # ---- Y-axis scaling: auto-scale so spectrum fits within graph ----
            # Match the PDF style where the Y-axis label (e.g. "4.3 µV") is
            # the graph ceiling, and the spectrum line just fits below it
            if len(amp_display) > 0:
                max_amp = np.max(amp_display)
                # Add 15% headroom to ensure line never clips
                y_scale = max_amp * 1.15
                # Round to nice value (0.5 increment)
                y_scale = np.ceil(y_scale * 2) / 2
                # Absolute minimum of 0.5 µV
                y_scale = max(y_scale, 0.5)
            else:
                y_scale = 1.0

            ax.set_ylim(0, y_scale)

            # ---- Horizontal gridlines at regular intervals ----
            # Choose sensible tick spacing based on y_scale
            if y_scale <= 1.5:
                ytick_step = 0.5
            elif y_scale <= 3.0:
                ytick_step = 1.0
            elif y_scale <= 6.0:
                ytick_step = 1.0
            else:
                ytick_step = 2.0
            yticks = np.arange(0, y_scale + ytick_step * 0.01, ytick_step)
            ax.set_yticks(yticks)
            ax.yaxis.grid(True, color=_HGRID_COLOR, linewidth=0.5,
                          linestyle="-", zorder=0)

            # ---- Plot the spectrum line (blue, matching PDF) ----
            ax.plot(
                freqs_display, amp_display,
                color=_SPECTRUM_LINE_COLOR, linewidth=1.5, zorder=5,
            )

            # ---- Y-axis label: scale max in µV (matching PDF) ----
            ax.set_ylabel(f"{y_scale:.1f} µV", fontsize=10, fontweight="bold")

            # ---- Region label on the left ----
            ax.text(
                -0.10, 0.5, region,
                transform=ax.transAxes,
                fontsize=12, fontweight="bold",
                va="center", ha="center",
            )

            # ---- X-axis: only show label on bottom plot ----
            ax.set_xlim(1, 25)
            ax.set_xticks([5, 10, 15, 20, 25])
            if idx == 2:
                ax.set_xlabel("Frequency (Hz)", fontsize=11)
            else:
                ax.set_xticklabels([])

            # Clean up spines to match PDF's minimal style
            ax.spines["top"].set_visible(False)
            ax.spines["right"].set_visible(False)
            ax.tick_params(axis="both", which="both", length=3)

        self._figure.tight_layout(rect=[0.08, 0.02, 1.0, 0.98])
        self._canvas.draw()
