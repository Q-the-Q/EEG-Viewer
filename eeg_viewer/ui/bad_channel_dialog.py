"""Dialog for viewing and managing bad (noisy/disconnected) EEG channels."""

from PyQt5.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QListWidget, QListWidgetItem,
    QPushButton, QLabel, QDialogButtonBox,
)
from PyQt5.QtCore import Qt


class BadChannelDialog(QDialog):
    """Shows all EEG channels with checkboxes; checked = bad."""

    def __init__(self, channel_names, bad_channels=None, auto_detected=None, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Bad Channel Management")
        self.setMinimumWidth(350)
        self.setMinimumHeight(400)

        bad_channels = bad_channels or []
        auto_detected = auto_detected or []

        layout = QVBoxLayout(self)

        info_label = QLabel(
            "Check channels to mark as bad. Auto-detected channels are pre-checked.\n"
            "Bad channels will be spatially interpolated before analysis."
        )
        info_label.setWordWrap(True)
        layout.addWidget(info_label)

        self.channel_list = QListWidget()
        for name in channel_names:
            item = QListWidgetItem(name)
            item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
            is_bad = name in bad_channels or name in auto_detected
            item.setCheckState(Qt.Checked if is_bad else Qt.Unchecked)
            if name in auto_detected and name not in bad_channels:
                item.setText(f"{name} (auto-detected)")
            self.channel_list.addItem(item)
        layout.addWidget(self.channel_list)

        # Buttons
        btn_layout = QHBoxLayout()
        select_auto = QPushButton("Select Auto-Detected")
        select_auto.clicked.connect(lambda: self._set_auto(auto_detected, True))
        clear_all = QPushButton("Clear All")
        clear_all.clicked.connect(lambda: self._set_all(False))
        btn_layout.addWidget(select_auto)
        btn_layout.addWidget(clear_all)
        layout.addLayout(btn_layout)

        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _set_auto(self, auto_detected, checked):
        for i in range(self.channel_list.count()):
            item = self.channel_list.item(i)
            name = item.text().replace(" (auto-detected)", "")
            if name in auto_detected:
                item.setCheckState(Qt.Checked if checked else Qt.Unchecked)

    def _set_all(self, checked):
        for i in range(self.channel_list.count()):
            self.channel_list.item(i).setCheckState(
                Qt.Checked if checked else Qt.Unchecked
            )

    def get_bad_channels(self):
        """Return list of channel names marked as bad."""
        bad = []
        for i in range(self.channel_list.count()):
            item = self.channel_list.item(i)
            if item.checkState() == Qt.Checked:
                name = item.text().replace(" (auto-detected)", "")
                bad.append(name)
        return bad
