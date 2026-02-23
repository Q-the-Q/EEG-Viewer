"""Playback controls panel for the waveform viewer."""

from PyQt5.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QPushButton, QSlider, QLabel,
    QComboBox, QRadioButton, QButtonGroup, QGroupBox, QCheckBox, QGridLayout,
)
from PyQt5.QtCore import pyqtSignal, Qt

from ..utils.constants import (
    MIN_SPEED, MAX_SPEED, DEFAULT_SPEED, DEFAULT_WINDOW_SEC, WINDOW_SIZE_OPTIONS,
)


class WaveformControls(QWidget):
    """Bottom control bar for the waveform viewer."""

    play_pause_clicked = pyqtSignal()
    speed_changed = pyqtSignal(float)
    position_changed = pyqtSignal(float)  # time in seconds
    amplitude_changed = pyqtSignal(float)
    mode_changed = pyqtSignal(str)  # "static" or "playback"
    window_size_changed = pyqtSignal(float)
    band_filters_changed = pyqtSignal(list)  # list of selected band names
    view_mode_changed = pyqtSignal(str)  # "waveform" or "spectrogram"

    def __init__(self, parent=None):
        super().__init__(parent)
        self._duration = 0.0
        self._init_ui()

    def _init_ui(self):
        main_layout = QHBoxLayout(self)
        main_layout.setContentsMargins(8, 4, 8, 4)

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
        main_layout.addWidget(mode_group)

        self._mode_group.buttonClicked.connect(self._on_mode_changed)

        # Play/Pause button
        self._play_btn = QPushButton("Play")
        self._play_btn.setFixedWidth(70)
        self._play_btn.setEnabled(False)
        self._play_btn.clicked.connect(self.play_pause_clicked.emit)
        main_layout.addWidget(self._play_btn)

        # Speed control
        speed_layout = QVBoxLayout()
        self._speed_label = QLabel(f"Speed: {DEFAULT_SPEED:.1f}x")
        self._speed_slider = QSlider(Qt.Horizontal)
        self._speed_slider.setRange(
            int(MIN_SPEED * 10), int(MAX_SPEED * 10)
        )
        self._speed_slider.setValue(int(DEFAULT_SPEED * 10))
        self._speed_slider.setFixedWidth(100)
        self._speed_slider.setEnabled(False)
        self._speed_slider.valueChanged.connect(self._on_speed_slider_changed)
        speed_layout.addWidget(self._speed_label)
        speed_layout.addWidget(self._speed_slider)
        main_layout.addLayout(speed_layout)

        # Time scrubber
        scrub_layout = QVBoxLayout()
        self._time_label = QLabel("00:00 / 00:00")
        self._time_slider = QSlider(Qt.Horizontal)
        self._time_slider.setRange(0, 0)
        self._time_slider.valueChanged.connect(self._on_time_slider_changed)
        scrub_layout.addWidget(self._time_label)
        scrub_layout.addWidget(self._time_slider)
        main_layout.addLayout(scrub_layout, stretch=3)

        # Amplitude scale
        amp_layout = QVBoxLayout()
        self._amp_label = QLabel("Scale: 1.0x")
        self._amp_slider = QSlider(Qt.Horizontal)
        self._amp_slider.setRange(10, 500)
        self._amp_slider.setValue(100)
        self._amp_slider.setFixedWidth(120)
        self._amp_slider.valueChanged.connect(self._on_amp_slider_changed)
        amp_layout.addWidget(self._amp_label)
        amp_layout.addWidget(self._amp_slider)
        main_layout.addLayout(amp_layout)

        # Window size combo
        win_layout = QVBoxLayout()
        win_layout.addWidget(QLabel("Window:"))
        self._window_combo = QComboBox()
        for ws in WINDOW_SIZE_OPTIONS:
            self._window_combo.addItem(f"{ws:.0f}s", ws)
        default_idx = WINDOW_SIZE_OPTIONS.index(DEFAULT_WINDOW_SEC)
        self._window_combo.setCurrentIndex(default_idx)
        self._window_combo.currentIndexChanged.connect(self._on_window_combo_changed)
        win_layout.addWidget(self._window_combo)
        main_layout.addLayout(win_layout)

        # Band filters (for waveform displays)
        band_group = QGroupBox("Band Filters")
        band_layout = QGridLayout()
        band_layout.setContentsMargins(4, 2, 4, 2)
        band_layout.setSpacing(4)

        self._band_checks = {}
        bands = ["Delta", "Theta", "Alpha", "Beta", "Gamma"]
        for i, band in enumerate(bands):
            cb = QCheckBox(band)
            cb.toggled.connect(self._on_band_filter_changed)
            self._band_checks[band] = cb
            band_layout.addWidget(cb, i // 3, i % 3)

        band_group.setLayout(band_layout)
        main_layout.addWidget(band_group)

        # View mode selector
        view_group = QGroupBox("View")
        view_layout = QVBoxLayout()
        view_layout.setContentsMargins(4, 2, 4, 2)
        self._view_group = QButtonGroup(self)
        self._waveform_radio = QRadioButton("Waveform")
        self._spectrogram_radio = QRadioButton("Spectrogram")
        self._waveform_radio.setChecked(True)
        self._view_group.addButton(self._waveform_radio)
        self._view_group.addButton(self._spectrogram_radio)
        view_layout.addWidget(self._waveform_radio)
        view_layout.addWidget(self._spectrogram_radio)
        view_group.setLayout(view_layout)
        main_layout.addWidget(view_group)
        self._view_group.buttonClicked.connect(self._on_view_mode_changed)

    def set_duration(self, duration):
        """Set total recording duration in seconds."""
        self._duration = duration
        self._time_slider.setRange(0, int(duration * 1000))
        self._update_time_label(0.0)

    def update_time_display(self, current_sec):
        """Update the time label and slider from playback."""
        self._time_slider.blockSignals(True)
        self._time_slider.setValue(int(current_sec * 1000))
        self._time_slider.blockSignals(False)
        self._update_time_label(current_sec)

    def set_playing(self, is_playing):
        """Toggle play/pause button text."""
        self._play_btn.setText("Pause" if is_playing else "Play")

    def _update_time_label(self, current_sec):
        cur_m, cur_s = divmod(int(current_sec), 60)
        tot_m, tot_s = divmod(int(self._duration), 60)
        self._time_label.setText(f"{cur_m:02d}:{cur_s:02d} / {tot_m:02d}:{tot_s:02d}")

    def _on_mode_changed(self, button):
        mode = "static" if button == self._static_radio else "playback"
        is_playback = mode == "playback"
        self._play_btn.setEnabled(is_playback)
        self._speed_slider.setEnabled(is_playback)
        self.mode_changed.emit(mode)

    def _on_speed_slider_changed(self, value):
        speed = value / 10.0
        self._speed_label.setText(f"Speed: {speed:.1f}x")
        self.speed_changed.emit(speed)

    def _on_time_slider_changed(self, value):
        time_sec = value / 1000.0
        self._update_time_label(time_sec)
        self.position_changed.emit(time_sec)

    def _on_amp_slider_changed(self, value):
        scale = value / 100.0
        self._amp_label.setText(f"Scale: {scale:.1f}x")
        self.amplitude_changed.emit(scale)

    def _on_window_combo_changed(self, index):
        window_sec = self._window_combo.itemData(index)
        self.window_size_changed.emit(window_sec)

    def _on_band_filter_changed(self):
        """Emit list of selected bands."""
        selected = [band for band, cb in self._band_checks.items() if cb.isChecked()]
        self.band_filters_changed.emit(selected)

    def _on_view_mode_changed(self, button):
        """Switch between waveform and spectrogram views."""
        view_mode = "waveform" if button == self._waveform_radio else "spectrogram"
        self.view_mode_changed.emit(view_mode)
