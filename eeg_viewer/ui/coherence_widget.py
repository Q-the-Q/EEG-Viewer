"""Coherence heatmap matrix display."""

import numpy as np
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from PyQt5.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QComboBox, QLabel

from ..utils.constants import FREQ_BANDS


class CoherenceWidget(QWidget):
    """Displays coherence as a heatmap matrix per frequency band."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._analyzer = None
        self._init_ui()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Band selector
        selector = QHBoxLayout()
        selector.addWidget(QLabel("Band:"))
        self._band_combo = QComboBox()
        for band_name in FREQ_BANDS:
            self._band_combo.addItem(band_name)
        self._band_combo.currentTextChanged.connect(self._on_band_changed)
        selector.addWidget(self._band_combo)
        selector.addStretch()
        layout.addLayout(selector)

        # Matplotlib figure
        self._figure = Figure(figsize=(5, 4.5), dpi=100)
        self._figure.set_facecolor("white")
        self._canvas = FigureCanvasQTAgg(self._figure)
        layout.addWidget(self._canvas)

    def plot_coherence(self, analyzer):
        """Plot coherence matrix for the selected band."""
        self._analyzer = analyzer
        self._draw()

    def _on_band_changed(self, band_name):
        if self._analyzer:
            self._draw()

    def _draw(self):
        band_name = self._band_combo.currentText()
        if not band_name or band_name not in self._analyzer.coherence:
            return

        matrix = self._analyzer.coherence[band_name]
        channels = self._analyzer.eeg_channels

        self._figure.clear()
        ax = self._figure.add_subplot(111)

        im = ax.imshow(
            matrix, cmap="YlOrRd", vmin=0, vmax=1,
            interpolation="nearest", aspect="equal",
        )

        # Labels
        n = len(channels)
        ax.set_xticks(range(n))
        ax.set_xticklabels(channels, rotation=90, fontsize=7)
        ax.set_yticks(range(n))
        ax.set_yticklabels(channels, fontsize=7)

        self._figure.colorbar(im, ax=ax, label="Coherence", shrink=0.8)
        ax.set_title(f"Coherence: {band_name}", fontsize=11, fontweight="bold")

        self._figure.tight_layout()
        self._canvas.draw()
