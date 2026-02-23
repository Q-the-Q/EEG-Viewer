"""Tab 1: Multi-channel EEG waveform viewer with playback and static modes."""

import numpy as np
import pyqtgraph as pg
from PyQt5.QtWidgets import QWidget, QVBoxLayout, QHBoxLayout, QSplitter
from PyQt5.QtCore import Qt

from .channel_selector import ChannelSelector
from .waveform_controls import WaveformControls
from ..workers.playback_worker import PlaybackWorker
from ..data.channel_map import DISPLAY_ORDER
from ..utils.constants import (
    CHANNEL_SPACING_UV, DEFAULT_AMPLITUDE_SCALE, DEFAULT_WINDOW_SEC,
    TRACE_COLOR, GRID_ALPHA,
)

# ECG signals are typically 1-3 mV, while re-referenced EEG is ~10 uV.
# This scale factor compresses the ECG trace so it fits in one channel slot.
_ECG_SCALE_FACTOR = 0.05  # 5% of normal scaling — keeps ECG within its lane


class WaveformTab(QWidget):
    """Multi-channel EEG waveform display with playback controls."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._loader = None
        self._plot_items = {}
        self._visible_channels = []
        self._amplitude_scale = DEFAULT_AMPLITUDE_SCALE
        self._time_window = DEFAULT_WINDOW_SEC
        self._current_time = 0.0
        self._mode = "static"
        self._channel_spacing = CHANNEL_SPACING_UV

        self._init_ui()
        self._init_playback()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Top area: channel selector + plot
        splitter = QSplitter(Qt.Horizontal)

        # Channel selector (left)
        self._channel_selector = ChannelSelector()
        splitter.addWidget(self._channel_selector)

        # PyQtGraph plot (center)
        self._plot_widget = pg.PlotWidget()
        self._plot_widget.setLabel("bottom", "Time", units="s")
        self._plot_widget.showGrid(x=True, y=True, alpha=GRID_ALPHA)
        self._plot_widget.setMouseEnabled(x=True, y=False)
        self._plot_widget.getAxis("left").setWidth(60)
        splitter.addWidget(self._plot_widget)

        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, stretch=1)

        # Bottom: controls
        self._controls = WaveformControls()
        layout.addWidget(self._controls)

        # Connect control signals
        self._controls.play_pause_clicked.connect(self._on_play_pause)
        self._controls.speed_changed.connect(self._on_speed_changed)
        self._controls.position_changed.connect(self._on_scrub)
        self._controls.amplitude_changed.connect(self._on_amplitude_changed)
        self._controls.mode_changed.connect(self._on_mode_changed)
        self._controls.window_size_changed.connect(self._on_window_size_changed)
        self._channel_selector.channels_changed.connect(self._on_channels_changed)

    def _init_playback(self):
        self._playback = PlaybackWorker(self)
        self._playback.time_updated.connect(self._on_playback_tick)
        self._playback.playback_finished.connect(self._on_playback_finished)

    def _is_ecg_channel(self, ch_name):
        """Check if a channel is ECG/EKG (not EEG)."""
        return ch_name.upper() in ("ECG", "EKG")

    def _channel_scale(self, ch_name):
        """Return the amplitude scale factor for a channel.

        ECG channels are scaled down to prevent overlap with EEG traces.
        """
        if self._is_ecg_channel(ch_name):
            return self._amplitude_scale * _ECG_SCALE_FACTOR
        return self._amplitude_scale

    def set_data(self, loader):
        """Initialize display with loaded EDF data."""
        self._loader = loader

        # Order channels according to DISPLAY_ORDER, with unknowns at end
        ordered = []
        for ch in DISPLAY_ORDER:
            if ch in loader.channel_names:
                ordered.append(ch)
        for ch in loader.channel_names:
            if ch not in ordered:
                ordered.append(ch)

        self._visible_channels = list(ordered)
        self._channel_selector.set_channels(ordered)
        self._controls.set_duration(loader.duration)
        self._playback.set_duration(loader.duration)

        # Create plot items for each channel
        self._create_plot_items(ordered)
        self._update_display()

    def _create_plot_items(self, channels):
        """Create PlotDataItem for each channel."""
        self._plot_widget.clear()
        self._plot_items.clear()

        for i, ch_name in enumerate(channels):
            # Use a distinct red color for ECG to differentiate from EEG traces
            if self._is_ecg_channel(ch_name):
                pen = pg.mkPen(color="#CC3333", width=1)
            else:
                pen = pg.mkPen(color=TRACE_COLOR, width=1)
            item = self._plot_widget.plot([], [], pen=pen, name=ch_name)
            self._plot_items[ch_name] = item

        self._update_y_axis_labels()

    def _update_y_axis_labels(self):
        """Set Y-axis tick labels to channel names at offset positions."""
        ticks = []
        for i, ch_name in enumerate(self._visible_channels):
            offset = -i * self._channel_spacing * self._amplitude_scale
            ticks.append((offset, ch_name))

        y_axis = self._plot_widget.getAxis("left")
        y_axis.setTicks([ticks])

    def _update_display(self):
        """Refresh the waveform display for current state."""
        if self._loader is None or not self._visible_channels:
            return

        if self._mode == "static":
            self._draw_static()
        else:
            self._draw_windowed()

    def _draw_static(self):
        """Draw the full recording for static/scrollable viewing."""
        # Hide all items first
        for ch_name, item in self._plot_items.items():
            if ch_name not in self._visible_channels:
                item.setData([], [])

        # Get data for visible channels
        data, times = self._loader.get_all_data(self._visible_channels)

        # Downsample for display performance if needed
        max_points = 50000
        if data.shape[1] > max_points:
            step = data.shape[1] // max_points
            data = data[:, ::step]
            times = times[::step]

        for i, ch_name in enumerate(self._visible_channels):
            if ch_name in self._plot_items:
                offset = -i * self._channel_spacing * self._amplitude_scale
                ch_scale = self._channel_scale(ch_name)
                scaled = data[i] * ch_scale * 1e6 + offset  # convert V to uV
                self._plot_items[ch_name].setData(times, scaled)

        self._plot_widget.setXRange(0, self._loader.duration, padding=0.01)
        self._update_y_range()

    def _draw_windowed(self):
        """Draw a time window for playback mode."""
        # Hide all items first
        for ch_name, item in self._plot_items.items():
            if ch_name not in self._visible_channels:
                item.setData([], [])

        start = max(0, self._current_time)
        duration = min(self._time_window, self._loader.duration - start)
        if duration <= 0:
            return

        data, times = self._loader.get_data_chunk(start, duration, self._visible_channels)

        for i, ch_name in enumerate(self._visible_channels):
            if ch_name in self._plot_items:
                offset = -i * self._channel_spacing * self._amplitude_scale
                ch_scale = self._channel_scale(ch_name)
                scaled = data[i] * ch_scale * 1e6 + offset  # convert V to uV
                self._plot_items[ch_name].setData(times, scaled)

        self._plot_widget.setXRange(start, start + self._time_window, padding=0)
        self._update_y_range()

    def _update_y_range(self):
        """Set Y range to fit all visible channels."""
        if not self._visible_channels:
            return
        n = len(self._visible_channels)
        top = self._channel_spacing * self._amplitude_scale
        bottom = -(n) * self._channel_spacing * self._amplitude_scale
        self._plot_widget.setYRange(bottom, top, padding=0.02)

    # --- Event handlers ---

    def _on_play_pause(self):
        if self._playback.is_playing:
            self._playback.pause()
            self._controls.set_playing(False)
        else:
            self._playback.start()
            self._controls.set_playing(True)

    def _on_speed_changed(self, speed):
        self._playback.set_speed(speed)

    def _on_scrub(self, time_sec):
        self._current_time = time_sec
        self._playback.seek(time_sec)
        if self._mode == "playback":
            self._draw_windowed()

    def _on_amplitude_changed(self, scale):
        self._amplitude_scale = scale
        self._update_y_axis_labels()
        self._update_display()

    def _on_mode_changed(self, mode):
        self._mode = mode
        if mode == "playback":
            self._current_time = 0.0
            self._playback.reset()
            self._controls.update_time_display(0.0)
        self._update_display()

    def _on_window_size_changed(self, window_sec):
        self._time_window = window_sec
        if self._mode == "playback":
            self._draw_windowed()

    def _on_channels_changed(self, channels):
        self._visible_channels = channels
        self._create_plot_items(channels)
        self._update_display()

    def _on_playback_tick(self, current_time):
        self._current_time = current_time
        self._controls.update_time_display(current_time)
        self._draw_windowed()

    def _on_playback_finished(self):
        self._controls.set_playing(False)
