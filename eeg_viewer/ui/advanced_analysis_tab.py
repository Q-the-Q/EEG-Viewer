"""Advanced Analysis Tab - Spectrogram and temporal band power analysis."""

import numpy as np
from scipy.signal import spectrogram as scipy_spectrogram
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QComboBox, QScrollArea, QFrame, QGroupBox,
)
from PyQt5.QtCore import Qt

from ..utils.constants import FREQ_BANDS


class SpectrogramWidget(QWidget):
    """Interactive spectrogram for selected channel."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._analyzer = None
        self._loader = None
        self._init_ui()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Channel selector
        selector = QHBoxLayout()
        selector.addWidget(QLabel("Channel:"))
        self._channel_combo = QComboBox()
        self._channel_combo.currentTextChanged.connect(self._on_channel_changed)
        selector.addWidget(self._channel_combo)
        selector.addStretch()
        layout.addLayout(selector)

        # Matplotlib figure
        self._figure = Figure(figsize=(12, 6), dpi=100)
        self._figure.set_facecolor("white")
        self._canvas = FigureCanvasQTAgg(self._figure)
        layout.addWidget(self._canvas)

    def set_data(self, analyzer, loader):
        """Update spectrogram with analyzer data."""
        self._analyzer = analyzer
        self._loader = loader

        # Populate channel selector
        self._channel_combo.blockSignals(True)
        self._channel_combo.clear()
        for ch in analyzer.eeg_channels:
            self._channel_combo.addItem(ch)
        self._channel_combo.blockSignals(False)

        # Draw first channel
        if len(analyzer.eeg_channels) > 0:
            self._plot_spectrogram(analyzer.eeg_channels[0])

    def _on_channel_changed(self, channel):
        """Re-plot when channel selection changes."""
        if self._analyzer and channel:
            self._plot_spectrogram(channel)

    def _plot_spectrogram(self, channel_name):
        """Plot spectrogram for selected channel using STFT."""
        if not self._analyzer or not self._loader:
            return

        # Get raw data for this channel
        channel_idx = self._analyzer.eeg_channels.index(channel_name)
        data, times = self._loader.get_all_data([channel_name])
        signal = data[0]

        # Compute spectrogram using short-time Fourier transform
        # nperseg = 256 gives ~2 Hz resolution at 500 Hz sampling rate
        # noverlap = 128 gives good temporal resolution
        f, t, Sxx = scipy_spectrogram(
            signal,
            fs=self._loader.sfreq,
            window='hann',
            nperseg=256,
            noverlap=128,
            scaling='density'
        )

        # Convert power to dB scale for visualization
        Sxx_db = 10 * np.log10(Sxx + 1e-20)

        self._figure.clear()
        ax = self._figure.add_subplot(111)

        # Plot spectrogram
        im = ax.pcolormesh(
            t, f, Sxx_db,
            shading='gouraud',
            cmap='viridis',
            vmin=np.percentile(Sxx_db, 5),
            vmax=np.percentile(Sxx_db, 95)
        )

        # Overlay frequency band boundaries
        band_boundaries = [1, 4, 8, 13, 25]
        for boundary in band_boundaries:
            if boundary <= f[-1]:
                ax.axhline(boundary, color='white', linewidth=1, linestyle='--', alpha=0.7)

        ax.set_xlabel('Time (s)', fontsize=11, fontweight='bold')
        ax.set_ylabel('Frequency (Hz)', fontsize=11, fontweight='bold')
        ax.set_title(f'Spectrogram - {channel_name}', fontsize=12, fontweight='bold')
        ax.set_ylim([0, 30])

        # Add colorbar
        cbar = self._figure.colorbar(im, ax=ax, label='Power (dB/Hz)')

        # Add band labels
        band_labels = [
            (2.5, 'Delta'),
            (6, 'Theta'),
            (10.5, 'Alpha'),
            (19, 'Beta')
        ]
        for freq, label in band_labels:
            if freq <= f[-1]:
                ax.text(
                    t[-1] * 0.02, freq, label,
                    color='white', fontsize=9, fontweight='bold',
                    bbox=dict(boxstyle='round', facecolor='black', alpha=0.5)
                )

        self._figure.tight_layout()
        self._canvas.draw()


class BandPowerEvolutionWidget(QWidget):
    """Show how band power changes over time."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._analyzer = None
        self._init_ui()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        self._figure = Figure(figsize=(12, 6), dpi=100)
        self._figure.set_facecolor("white")
        self._canvas = FigureCanvasQTAgg(self._figure)
        layout.addWidget(self._canvas)

    def plot_band_evolution(self, analyzer):
        """Plot relative band power per channel as grouped bars."""
        self._analyzer = analyzer

        self._figure.clear()
        ax = self._figure.add_subplot(111)

        # Prepare data: channels x bands
        channels = analyzer.eeg_channels
        bands = list(FREQ_BANDS.keys())
        n_channels = len(channels)
        n_bands = len(bands)

        # Get relative powers
        data = np.zeros((n_channels, n_bands))
        for band_idx, band_name in enumerate(bands):
            data[:, band_idx] = analyzer.relative_powers[band_name]

        # Create grouped bar chart
        x = np.arange(n_channels)
        width = 0.2
        colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728']

        for band_idx, band_name in enumerate(bands):
            offset = (band_idx - n_bands/2 + 0.5) * width
            ax.bar(
                x + offset, data[:, band_idx],
                width, label=band_name, color=colors[band_idx], alpha=0.8
            )

        ax.set_xlabel('Channel', fontsize=11, fontweight='bold')
        ax.set_ylabel('Relative Power', fontsize=11, fontweight='bold')
        ax.set_title('Band Power Distribution by Channel', fontsize=12, fontweight='bold')
        ax.set_xticks(x)
        ax.set_xticklabels(channels, rotation=45, ha='right')
        ax.legend(loc='upper left', ncol=4)
        ax.grid(True, axis='y', alpha=0.3)

        self._figure.tight_layout()
        self._canvas.draw()


class AdvancedAnalysisTab(QWidget):
    """Advanced analysis visualizations: spectrograms and band power evolution."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._analyzer = None
        self._loader = None
        self._init_ui()

    def _init_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setSpacing(0)
        main_layout.setContentsMargins(0, 0, 0, 0)

        # Header
        header = QHBoxLayout()
        header_label = QLabel("Advanced Analysis")
        header_label.setStyleSheet("font-size: 16px; font-weight: bold; padding: 12px;")
        header.addWidget(header_label)
        header.addStretch()
        main_layout.addLayout(header)

        # Divider
        divider = QFrame()
        divider.setFrameShape(QFrame.HLine)
        main_layout.addWidget(divider)

        # Scrollable content
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        content_layout = QVBoxLayout(content)
        content_layout.setSpacing(16)

        # Spectrogram section
        spec_group = QGroupBox("Time-Frequency Analysis (Spectrogram)")
        spec_group.setStyleSheet("QGroupBox { font-weight: bold; font-size: 13px; }")
        spec_group.setMinimumHeight(450)
        spec_layout = QVBoxLayout(spec_group)
        spec_layout.setContentsMargins(4, 12, 4, 4)
        self._spectrogram_widget = SpectrogramWidget()
        spec_layout.addWidget(self._spectrogram_widget)
        content_layout.addWidget(spec_group)

        # Band power evolution section
        band_group = QGroupBox("Relative Band Power by Channel")
        band_group.setStyleSheet("QGroupBox { font-weight: bold; font-size: 13px; }")
        band_group.setMinimumHeight(420)
        band_layout = QVBoxLayout(band_group)
        band_layout.setContentsMargins(4, 12, 4, 4)
        self._band_evolution_widget = BandPowerEvolutionWidget()
        band_layout.addWidget(self._band_evolution_widget)
        content_layout.addWidget(band_group)

        scroll.setWidget(content)
        main_layout.addWidget(scroll, stretch=1)

    def set_analyzer(self, analyzer, loader):
        """Update plots with analyzer data."""
        self._analyzer = analyzer
        self._loader = loader

        if analyzer and loader:
            self._spectrogram_widget.set_data(analyzer, loader)
            self._band_evolution_widget.plot_band_evolution(analyzer)
