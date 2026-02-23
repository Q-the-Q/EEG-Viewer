"""Topographic head maps for qEEG relative power Z-scores.

Matches the NeuroSynchrony PDF report colormap:
- +2.5Z (top): light yellow
- through orange, red, magenta
- 0Z (center): black
- through dark blue, medium blue, light blue
- -2.5Z (bottom): cyan
"""

import numpy as np
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from matplotlib.colors import LinearSegmentedColormap
from PyQt5.QtWidgets import QWidget, QVBoxLayout

import mne

from ..utils.constants import FREQ_BANDS, ZSCORE_VMIN, ZSCORE_VMAX


# Custom colormap matching the NeuroSynchrony PDF colorbar.
# Reading from bottom (-2.5Z) to top (+2.5Z):
#   cyan -> light blue -> blue -> dark blue -> BLACK -> magenta -> red -> orange -> yellow
ZSCORE_CMAP = LinearSegmentedColormap.from_list(
    "neurosynchrony",
    [
        (0.00, "#00FFFF"),   # -2.5Z: cyan
        (0.10, "#00CCEE"),   # light cyan-blue
        (0.20, "#0099DD"),   # light blue
        (0.30, "#0066CC"),   # medium blue
        (0.40, "#003399"),   # dark blue
        (0.48, "#0A0A40"),   # very dark blue, approaching black
        (0.50, "#000000"),   # 0Z: black
        (0.52, "#400A20"),   # very dark magenta, coming from black
        (0.60, "#990033"),   # dark magenta
        (0.70, "#CC0055"),   # magenta
        (0.80, "#FF0000"),   # red
        (0.90, "#FF8800"),   # orange
        (1.00, "#FFFF00"),   # +2.5Z: yellow
    ],
    N=256,
)


class TopomapWidget(QWidget):
    """Four topographic head maps (Delta, Theta, Alpha, Beta) with Z-score coloring.

    Sized larger to match the PDF where topomaps take up significant page space.
    """

    def __init__(self, parent=None):
        super().__init__(parent)
        # Larger figure to make topomaps prominent (matching PDF proportions)
        self._figure = Figure(figsize=(14, 5.5), dpi=100)
        self._figure.set_facecolor("white")
        self._canvas = FigureCanvasQTAgg(self._figure)
        self._canvas.setMinimumHeight(400)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self._canvas)

    def plot_topomaps(self, analyzer, eeg_info):
        """Plot 4 topomaps (Delta, Theta, Alpha, Beta) with Z-score coloring.

        Args:
            analyzer: QEEGAnalyzer with computed Z-scores.
            eeg_info: MNE Info object with EEG channel positions only.
        """
        self._figure.clear()

        band_names = list(FREQ_BANDS.keys())

        # Layout: 4 large topomap axes + 1 colorbar axis
        map_width = 0.20
        map_height = 0.75
        y_offset = 0.10
        x_start = 0.03
        x_spacing = 0.225

        axes = []
        for i in range(4):
            ax = self._figure.add_axes(
                [x_start + i * x_spacing, y_offset, map_width, map_height]
            )
            axes.append(ax)

        # Colorbar axis on the right
        cbar_ax = self._figure.add_axes([0.93, y_offset, 0.025, map_height])

        im = None
        for i, band_name in enumerate(band_names):
            zscores = analyzer.zscores[band_name]
            f_low, f_high = FREQ_BANDS[band_name]

            # Plot topomap
            im, _ = mne.viz.plot_topomap(
                zscores,
                eeg_info,
                axes=axes[i],
                cmap=ZSCORE_CMAP,
                vlim=(ZSCORE_VMIN, ZSCORE_VMAX),
                show=False,
                contours=0,
                sensors=False,
            )

            # Title above each topomap (matching PDF style)
            axes[i].set_title(
                f"{band_name} ({f_low:.0f}-{f_high:.0f} Hz)",
                fontsize=11, fontweight="bold", pad=8,
            )

        # Colorbar matching PDF style with Z labels
        if im is not None:
            cbar = self._figure.colorbar(im, cax=cbar_ax)
            cbar.set_ticks([ZSCORE_VMIN, 0, ZSCORE_VMAX])
            cbar.set_ticklabels(
                [f"{ZSCORE_VMIN:.1f} Z", "0", f"{ZSCORE_VMAX:.1f} Z"]
            )
            cbar.ax.tick_params(labelsize=10)

        self._canvas.draw()
