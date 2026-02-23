"""QTimer-driven playback controller for waveform animation."""

from PyQt5.QtCore import QObject, QTimer, pyqtSignal

from ..utils.constants import TARGET_FPS, DEFAULT_SPEED


class PlaybackWorker(QObject):
    """Drives waveform playback animation using QTimer on the main thread.

    Uses QTimer rather than QThread because GUI updates must happen on the
    main thread, and the per-frame data slicing is fast (numpy array views).
    """

    time_updated = pyqtSignal(float)  # current time in seconds
    playback_finished = pyqtSignal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self._timer = QTimer(self)
        self._timer.timeout.connect(self._tick)
        self._fps = TARGET_FPS
        self._speed = DEFAULT_SPEED
        self._current_time = 0.0
        self._duration = 0.0
        self._is_playing = False

    @property
    def is_playing(self):
        return self._is_playing

    @property
    def current_time(self):
        return self._current_time

    def set_duration(self, duration):
        """Set total recording duration in seconds."""
        self._duration = duration

    def start(self):
        """Start playback."""
        if self._duration <= 0:
            return
        self._is_playing = True
        interval_ms = int(1000 / self._fps)
        self._timer.start(interval_ms)

    def pause(self):
        """Pause playback."""
        self._is_playing = False
        self._timer.stop()

    def seek(self, time_sec):
        """Jump to specific time."""
        self._current_time = max(0.0, min(time_sec, self._duration))
        self.time_updated.emit(self._current_time)

    def set_speed(self, speed):
        """Update playback speed multiplier."""
        self._speed = speed

    def reset(self):
        """Reset to beginning."""
        self.pause()
        self._current_time = 0.0
        self.time_updated.emit(self._current_time)

    def _tick(self):
        """Advance time by one frame step."""
        step = self._speed / self._fps
        self._current_time += step

        if self._current_time >= self._duration:
            self._current_time = self._duration
            self.time_updated.emit(self._current_time)
            self.pause()
            self.playback_finished.emit()
            return

        self.time_updated.emit(self._current_time)
