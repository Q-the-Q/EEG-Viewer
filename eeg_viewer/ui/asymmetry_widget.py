"""Hemispheric asymmetry bar chart display."""

import numpy as np
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from PyQt5.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QComboBox, QLabel

from ..utils.constants import FREQ_BANDS


class AsymmetryWidget(QWidget):
    """Horizontal bar chart showing hemispheric asymmetry per channel pair."""

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
        self._figure = Figure(figsize=(5, 4), dpi=100)
        self._figure.set_facecolor("white")
        self._canvas = FigureCanvasQTAgg(self._figure)
        layout.addWidget(self._canvas)

    def plot_asymmetry(self, analyzer):
        """Plot asymmetry bars for the selected band."""
        self._analyzer = analyzer
        self._draw()

    def _on_band_changed(self, band_name):
        if self._analyzer:
            self._draw()

    def _draw(self):
        band_name = self._band_combo.currentText()
        if not band_name or band_name not in self._analyzer.asymmetry:
            return

        pairs_values = self._analyzer.asymmetry[band_name]
        if not pairs_values:
            return

        labels = [f"{left}-{right}" for (left, right), _ in pairs_values]
        values = [v for _, v in pairs_values]
        colors = ["#CC4444" if v > 0 else "#4444CC" for v in values]

        self._figure.clear()
        ax = self._figure.add_subplot(111)

        y_pos = np.arange(len(labels))
        ax.barh(y_pos, values, color=colors, height=0.6)
        ax.set_yticks(y_pos)
        ax.set_yticklabels(labels, fontsize=9)
        ax.axvline(0, color="black", linewidth=0.8)
        ax.set_xlabel("Asymmetry: ln(Right) - ln(Left)", fontsize=9)
        ax.set_title(f"Asymmetry: {band_name}", fontsize=11, fontweight="bold")

        # Legend explanation
        ax.text(
            0.98, 0.02,
            "Red = Right > Left | Blue = Left > Right",
            transform=ax.transAxes, fontsize=7,
            ha="right", va="bottom", style="italic", color="#666",
        )

        ax.grid(True, axis="x", alpha=0.3)
        self._figure.tight_layout()
        self._canvas.draw()
