"""Channel selection panel with checkboxes for each EEG channel."""

from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QCheckBox, QPushButton, QLabel, QScrollArea, QFrame,
)
from PyQt5.QtCore import pyqtSignal


class ChannelSelector(QWidget):
    """Left panel with checkboxes for each EEG/ECG channel."""

    channels_changed = pyqtSignal(list)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._checkboxes = {}
        self._init_ui()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)

        label = QLabel("Channels")
        label.setStyleSheet("font-weight: bold; font-size: 13px;")
        layout.addWidget(label)

        # Select All / None buttons
        btn_layout = QVBoxLayout()
        self._select_all_btn = QPushButton("Select All")
        self._select_all_btn.clicked.connect(self._select_all)
        btn_layout.addWidget(self._select_all_btn)

        self._select_none_btn = QPushButton("Select None")
        self._select_none_btn.clicked.connect(self._select_none)
        btn_layout.addWidget(self._select_none_btn)
        layout.addLayout(btn_layout)

        # Separator
        line = QFrame()
        line.setFrameShape(QFrame.HLine)
        line.setFrameShadow(QFrame.Sunken)
        layout.addWidget(line)

        # Scrollable checkbox area
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        self._checkbox_container = QWidget()
        self._checkbox_layout = QVBoxLayout(self._checkbox_container)
        self._checkbox_layout.setContentsMargins(0, 0, 0, 0)
        self._checkbox_layout.setSpacing(2)
        scroll.setWidget(self._checkbox_container)
        layout.addWidget(scroll)

        self.setFixedWidth(140)

    def set_channels(self, channel_names):
        """Populate checkboxes from channel list. All checked by default."""
        # Clear existing
        for cb in self._checkboxes.values():
            self._checkbox_layout.removeWidget(cb)
            cb.deleteLater()
        self._checkboxes.clear()

        for name in channel_names:
            cb = QCheckBox(name)
            cb.setChecked(True)
            cb.stateChanged.connect(self._on_checkbox_changed)
            self._checkbox_layout.addWidget(cb)
            self._checkboxes[name] = cb

        self._checkbox_layout.addStretch()

    def get_selected(self):
        """Return list of checked channel names in order."""
        return [name for name, cb in self._checkboxes.items() if cb.isChecked()]

    def _select_all(self):
        for cb in self._checkboxes.values():
            cb.blockSignals(True)
            cb.setChecked(True)
            cb.blockSignals(False)
        self.channels_changed.emit(self.get_selected())

    def _select_none(self):
        for cb in self._checkboxes.values():
            cb.blockSignals(True)
            cb.setChecked(False)
            cb.blockSignals(False)
        self.channels_changed.emit(self.get_selected())

    def _on_checkbox_changed(self, state):
        self.channels_changed.emit(self.get_selected())
