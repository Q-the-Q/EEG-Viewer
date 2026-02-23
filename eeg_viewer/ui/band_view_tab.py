"""Tab: Band-filtered waveform viewer with spectrogram.

Shows 4 traces (Delta, Theta, Alpha, Beta) using Global Field Power (GFP) —
the standard deviation across all EEG channels at each time point — which
measures overall brain activation in each band. Includes a time-frequency
spectrogram and static/playback modes.
"""

import numpy as np
from scipy.signal import spectrogram as scipy_spectrogram
import pyqtgraph as pg
from matplotlib.figure import Figure
from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QSplitter, QLabel, QComboBox,
    QPushButton, QSlider, QRadioButton, QButtonGroup, QGroupBox, QFrame,
)
from PyQt5.QtCore import Qt, pyqtSignal

from ..data.signal_processor import SignalProcessor
from ..workers.playback_worker import PlaybackWorker
from ..utils.constants import (
    FREQ_BANDS, DEFAULT_WINDOW_SEC, DEFAULT_SPEED, MIN_SPEED, MAX_SPEED,
    TARGET_FPS, WINDOW_SIZE_OPTIONS, GRID_ALPHA,
)

# Colors for each band trace
BAND_TRACE_COLORS = {
    "Delta": "#6A0DAD",  # Purple
    "Theta": "#228B22",  # Green
    "Alpha": "#DAA520",  # Gold
    "Beta":  "#CC3333",  # Red
}

# Spacing between band traces in µV (GFP peaks at ~10-40 µV)
BAND_SPACING_UV = 50.0


class BandViewTab(QWidget):
    """Band-filtered waveform viewer with spectrogram."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._loader = None
        self._processor = None
        self._band_data = {}       # band_name -> (times, averaged_filtered_uV)
        self._plot_items = {}
        self._amplitude_scale = 1.0
        self._time_window = DEFAULT_WINDOW_SEC
        self._current_time = 0.0
        self._mode = "static"
        self._spectrogram_data = None  # (t, f, Sxx_db)
        self._init_ui()
        self._init_playback()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        # Main splitter: waveform (top) + spectrogram (bottom)
        splitter = QSplitter(Qt.Vertical)

        # --- Band waveform section ---
        waveform_container = QWidget()
        waveform_layout = QVBoxLayout(waveform_container)
        waveform_layout.setContentsMargins(0, 0, 0, 0)

        wf_label = QLabel("Band Power — Global Field Power (GFP)")
        wf_label.setStyleSheet("font-weight: bold; font-size: 14px; padding: 4px;")
        waveform_layout.addWidget(wf_label)

        self._plot_widget = pg.PlotWidget()
        self._plot_widget.setLabel("bottom", "Time", units="s")
        self._plot_widget.showGrid(x=True, y=True, alpha=GRID_ALPHA)
        self._plot_widget.setMouseEnabled(x=True, y=False)
        self._plot_widget.getAxis("left").setWidth(60)
        self._plot_widget.setBackground("w")
        waveform_layout.addWidget(self._plot_widget)

        splitter.addWidget(waveform_container)

        # --- Spectrogram section ---
        spec_container = QWidget()
        spec_layout = QVBoxLayout(spec_container)
        spec_layout.setContentsMargins(0, 0, 0, 0)

        spec_header = QHBoxLayout()
        spec_label = QLabel("Spectrogram (Global Field Power)")
        spec_label.setStyleSheet("font-weight: bold; font-size: 14px; padding: 4px;")
        spec_header.addWidget(spec_label)
        spec_header.addStretch()
        spec_layout.addLayout(spec_header)

        self._spec_figure = Figure(figsize=(12, 4), dpi=100)
        self._spec_figure.set_facecolor("white")
        self._spec_canvas = FigureCanvasQTAgg(self._spec_figure)
        spec_layout.addWidget(self._spec_canvas)

        splitter.addWidget(spec_container)
        splitter.setStretchFactor(0, 3)
        splitter.setStretchFactor(1, 2)

        layout.addWidget(splitter, stretch=1)

        # --- Controls bar ---
        controls = QHBoxLayout()
        controls.setContentsMargins(8, 4, 8, 4)

        # Mode toggle
        mode_group = QGroupBox("Mode")
        mode_layout = QVBoxLayout()
        mode_layout.setContentsMargins(4, 2, 4, 2)
        self._mode_group = QButtonGroup(self)
        self._static_radio = QRadioButton("Static")
        self._playback_radio = QRadioButton("Playback")
        self._static_radio.setChecked(True)
        self._mode_group.addButton(self._static_radio)
        self._mode_group.addButton(self._playback_radio)
        mode_layout.addWidget(self._static_radio)
        mode_layout.addWidget(self._playback_radio)
        mode_group.setLayout(mode_layout)
        controls.addWidget(mode_group)
        self._mode_group.buttonClicked.connect(self._on_mode_changed)

        # Play/Pause
        self._play_btn = QPushButton("Play")
        self._play_btn.setFixedWidth(70)
        self._play_btn.setEnabled(False)
        self._play_btn.clicked.connect(self._on_play_pause)
        controls.addWidget(self._play_btn)

        # Speed
        speed_layout = QVBoxLayout()
        self._speed_label = QLabel(f"Speed: {DEFAULT_SPEED:.1f}x")
        self._speed_slider = QSlider(Qt.Horizontal)
        self._speed_slider.setRange(int(MIN_SPEED * 10), int(MAX_SPEED * 10))
        self._speed_slider.setValue(int(DEFAULT_SPEED * 10))
        self._speed_slider.setFixedWidth(100)
        self._speed_slider.setEnabled(False)
        self._speed_slider.valueChanged.connect(self._on_speed_changed)
        speed_layout.addWidget(self._speed_label)
        speed_layout.addWidget(self._speed_slider)
        controls.addLayout(speed_layout)

        # Time scrubber
        scrub_layout = QVBoxLayout()
        self._time_label = QLabel("00:00 / 00:00")
        self._time_slider = QSlider(Qt.Horizontal)
        self._time_slider.setRange(0, 0)
        self._time_slider.valueChanged.connect(self._on_scrub)
        scrub_layout.addWidget(self._time_label)
        scrub_layout.addWidget(self._time_slider)
        controls.addLayout(scrub_layout, stretch=3)

        # Amplitude
        amp_layout = QVBoxLayout()
        self._amp_label = QLabel("Scale: 1.0x")
        self._amp_slider = QSlider(Qt.Horizontal)
        self._amp_slider.setRange(10, 500)
        self._amp_slider.setValue(100)
        self._amp_slider.setFixedWidth(120)
        self._amp_slider.valueChanged.connect(self._on_amp_changed)
        amp_layout.addWidget(self._amp_label)
        amp_layout.addWidget(self._amp_slider)
        controls.addLayout(amp_layout)

        # Window size
        win_layout = QVBoxLayout()
        win_layout.addWidget(QLabel("Window:"))
        self._window_combo = QComboBox()
        for ws in WINDOW_SIZE_OPTIONS:
            self._window_combo.addItem(f"{ws:.0f}s", ws)
        default_idx = WINDOW_SIZE_OPTIONS.index(DEFAULT_WINDOW_SEC)
        self._window_combo.setCurrentIndex(default_idx)
        self._window_combo.currentIndexChanged.connect(self._on_window_changed)
        win_layout.addWidget(self._window_combo)
        controls.addLayout(win_layout)

        layout.addLayout(controls)

    def _init_playback(self):
        self._playback = PlaybackWorker(self)
        self._playback.time_updated.connect(self._on_playback_tick)
        self._playback.playback_finished.connect(self._on_playback_finished)

    def set_data(self, loader):
        """Compute band-filtered data and spectrogram from loaded EDF."""
        self._loader = loader
        self._processor = SignalProcessor(loader.sfreq)

        self._time_slider.setRange(0, int(loader.duration * 1000))
        self._playback.set_duration(loader.duration)
        self._update_time_label(0.0)

        # Get all EEG data
        eeg_channels = loader.get_eeg_channels()
        data, times = loader.get_all_data(eeg_channels)

        # Bandpass filter and compute GFP (std across channels) for each band.
        # Simple averaging cancels out because of average-referencing, so we use
        # Global Field Power = std across channels, which measures activation.
        self._band_data = {}
        for band_name, (f_low, f_high) in FREQ_BANDS.items():
            filtered = self._processor.bandpass_filter(data, f_low, f_high)
            # GFP: standard deviation across channels at each time point (µV)
            gfp_trace = np.std(filtered, axis=0) * 1e6
            self._band_data[band_name] = (times, gfp_trace)

        # Compute spectrogram on GFP signal (std across channels, not mean)
        gfp_signal = np.std(data, axis=0)
        f, t, Sxx = scipy_spectrogram(
            gfp_signal, fs=loader.sfreq,
            window='hann', nperseg=256, noverlap=192, scaling='density',
        )
        Sxx_db = 10 * np.log10(Sxx + 1e-20)
        self._spectrogram_data = (t, f, Sxx_db)

        # Create plot items
        self._create_plot_items()
        self._plot_spectrogram()
        self._update_display()

    def _create_plot_items(self):
        """Create PyQtGraph traces for each band."""
        self._plot_widget.clear()
        self._plot_items.clear()

        # Remove old legend if any
        if self._plot_widget.plotItem.legend is not None:
            self._plot_widget.plotItem.legend.scene().removeItem(
                self._plot_widget.plotItem.legend
            )
            self._plot_widget.plotItem.legend = None

        legend = self._plot_widget.addLegend(offset=(10, 10))

        bands = list(FREQ_BANDS.keys())
        for i, band_name in enumerate(bands):
            color = BAND_TRACE_COLORS.get(band_name, "#333333")
            pen = pg.mkPen(color=color, width=1.5)
            item = self._plot_widget.plot([], [], pen=pen, name=band_name)
            self._plot_items[band_name] = item

        self._update_y_axis_labels()

    def _update_y_axis_labels(self):
        """Set Y-axis labels for each band at its offset."""
        bands = list(FREQ_BANDS.keys())
        ticks = []
        for i, band_name in enumerate(bands):
            offset = -i * BAND_SPACING_UV * self._amplitude_scale
            ticks.append((offset, band_name))
        y_axis = self._plot_widget.getAxis("left")
        y_axis.setTicks([ticks])

    def _update_display(self):
        """Refresh waveform display."""
        if not self._band_data:
            return
        if self._mode == "static":
            self._draw_static()
        else:
            self._draw_windowed()

    def _draw_static(self):
        """Draw full recording for static view."""
        bands = list(FREQ_BANDS.keys())
        max_points = 50000

        for i, band_name in enumerate(bands):
            times, trace = self._band_data[band_name]
            offset = -i * BAND_SPACING_UV * self._amplitude_scale

            # Downsample for performance
            if len(trace) > max_points:
                step = len(trace) // max_points
                t_ds = times[::step]
                y_ds = trace[::step]
            else:
                t_ds = times
                y_ds = trace

            scaled = y_ds * self._amplitude_scale + offset
            self._plot_items[band_name].setData(t_ds, scaled)

        self._plot_widget.setXRange(0, self._loader.duration, padding=0.01)
        self._update_y_range()

    def _draw_windowed(self):
        """Draw time window for playback."""
        bands = list(FREQ_BANDS.keys())
        start = max(0, self._current_time)
        end = min(start + self._time_window, self._loader.duration)
        if end <= start:
            return

        for i, band_name in enumerate(bands):
            times, trace = self._band_data[band_name]
            offset = -i * BAND_SPACING_UV * self._amplitude_scale

            # Find sample indices for the window
            start_idx = int(start * self._loader.sfreq)
            end_idx = int(end * self._loader.sfreq)
            end_idx = min(end_idx, len(trace))

            t_win = times[start_idx:end_idx]
            y_win = trace[start_idx:end_idx]
            scaled = y_win * self._amplitude_scale + offset
            self._plot_items[band_name].setData(t_win, scaled)

        self._plot_widget.setXRange(start, start + self._time_window, padding=0)
        self._update_y_range()

    def _update_y_range(self):
        """Fit Y range to visible bands."""
        n = len(FREQ_BANDS)
        top = BAND_SPACING_UV * self._amplitude_scale
        bottom = -(n) * BAND_SPACING_UV * self._amplitude_scale
        self._plot_widget.setYRange(bottom, top, padding=0.05)

    def _plot_spectrogram(self):
        """Draw the global average spectrogram."""
        if self._spectrogram_data is None:
            return

        t, f, Sxx_db = self._spectrogram_data

        self._spec_figure.clear()
        ax = self._spec_figure.add_subplot(111)

        im = ax.pcolormesh(
            t, f, Sxx_db,
            shading='gouraud', cmap='viridis',
            vmin=np.percentile(Sxx_db, 5),
            vmax=np.percentile(Sxx_db, 95),
        )

        # Band boundary lines
        for boundary in [1, 4, 8, 13, 25]:
            if boundary <= f[-1]:
                ax.axhline(boundary, color='white', linewidth=0.8, linestyle='--', alpha=0.6)

        ax.set_xlabel('Time (s)', fontsize=10)
        ax.set_ylabel('Frequency (Hz)', fontsize=10)
        ax.set_ylim([0, 30])
        ax.set_title('Global Field Power Spectrogram', fontsize=11, fontweight='bold')

        self._spec_figure.colorbar(im, ax=ax, label='Power (dB/Hz)')

        # Band labels
        for freq, label in [(2.5, 'Delta'), (6, 'Theta'), (10.5, 'Alpha'), (19, 'Beta')]:
            ax.text(
                t[-1] * 0.02, freq, label, color='white', fontsize=8, fontweight='bold',
                bbox=dict(boxstyle='round', facecolor='black', alpha=0.4),
            )

        self._spec_figure.tight_layout()
        self._spec_canvas.draw()

    def _update_time_label(self, current_sec):
        duration = self._loader.duration if self._loader else 0
        cur_m, cur_s = divmod(int(current_sec), 60)
        tot_m, tot_s = divmod(int(duration), 60)
        self._time_label.setText(f"{cur_m:02d}:{cur_s:02d} / {tot_m:02d}:{tot_s:02d}")

    # --- Event handlers ---

    def _on_mode_changed(self, button):
        mode = "static" if button == self._static_radio else "playback"
        self._mode = mode
        is_playback = mode == "playback"
        self._play_btn.setEnabled(is_playback)
        self._speed_slider.setEnabled(is_playback)
        if is_playback:
            self._current_time = 0.0
            self._playback.reset()
            self._update_time_label(0.0)
        self._update_display()

    def _on_play_pause(self):
        if self._playback.is_playing:
            self._playback.pause()
            self._play_btn.setText("Play")
        else:
            self._playback.start()
            self._play_btn.setText("Pause")

    def _on_speed_changed(self, value):
        speed = value / 10.0
        self._speed_label.setText(f"Speed: {speed:.1f}x")
        self._playback.set_speed(speed)

    def _on_scrub(self, value):
        time_sec = value / 1000.0
        self._current_time = time_sec
        self._playback.seek(time_sec)
        self._update_time_label(time_sec)
        if self._mode == "playback":
            self._draw_windowed()

    def _on_amp_changed(self, value):
        self._amplitude_scale = value / 100.0
        self._amp_label.setText(f"Scale: {self._amplitude_scale:.1f}x")
        self._update_y_axis_labels()
        self._update_display()

    def _on_window_changed(self, index):
        self._time_window = self._window_combo.itemData(index)
        if self._mode == "playback":
            self._draw_windowed()

    def _on_playback_tick(self, current_time):
        self._current_time = current_time
        self._time_slider.blockSignals(True)
        self._time_slider.setValue(int(current_time * 1000))
        self._time_slider.blockSignals(False)
        self._update_time_label(current_time)
        self._draw_windowed()

    def _on_playback_finished(self):
        self._play_btn.setText("Play")
