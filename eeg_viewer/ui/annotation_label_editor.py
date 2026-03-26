"""Dialog for managing annotation label types -- name, color, analysis mode."""

from PyQt5.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QTableWidget, QTableWidgetItem,
    QPushButton, QComboBox, QColorDialog, QHeaderView, QDialogButtonBox,
    QLineEdit, QMessageBox,
)
from PyQt5.QtGui import QColor
from PyQt5.QtCore import Qt

from ..data.annotation_store import AnnotationStore, AnnotationLabel


class AnnotationLabelEditor(QDialog):
    """Dialog for adding, editing, and removing annotation labels."""

    def __init__(self, store: AnnotationStore, parent=None):
        super().__init__(parent)
        self.store = store
        self.setWindowTitle("Annotation Labels")
        self.setMinimumWidth(500)
        self.setMinimumHeight(350)
        self._setup_ui()
        self._populate()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        # Table
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Color", "Name", "Mode", ""])
        self.table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.table.setColumnWidth(0, 60)
        self.table.setColumnWidth(2, 130)
        self.table.setColumnWidth(3, 60)
        layout.addWidget(self.table)

        # Add new label row
        add_layout = QHBoxLayout()
        self.new_name = QLineEdit()
        self.new_name.setPlaceholderText("New label name")
        add_layout.addWidget(self.new_name)
        add_btn = QPushButton("+ Add")
        add_btn.clicked.connect(self._add_label)
        add_layout.addWidget(add_btn)
        layout.addLayout(add_layout)

        # OK/Cancel
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.accepted.connect(self._save_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _populate(self):
        self.table.setRowCount(len(self.store.labels))
        for i, label in enumerate(self.store.labels):
            self._set_row(i, label)

    def _set_row(self, row, label):
        # Use label.id in lambdas (not row index) to avoid stale references after deletion
        label_id = label.id

        # Color button
        c = label.color
        r, g, b = int(c['red'] * 255), int(c['green'] * 255), int(c['blue'] * 255)
        color_btn = QPushButton()
        color_btn.setStyleSheet(f"background-color: rgb({r},{g},{b}); border: 1px solid gray;")
        color_btn.setFixedWidth(50)
        color_btn.clicked.connect(lambda _, lid=label_id: self._pick_color(lid))
        self.table.setCellWidget(row, 0, color_btn)

        # Name
        name_item = QTableWidgetItem(label.name)
        self.table.setItem(row, 1, name_item)

        # Analysis mode combo
        mode_combo = QComboBox()
        mode_combo.addItems(["Exclude", "Analyze Separately"])
        mode_combo.setCurrentIndex(0 if label.analysisMode == "exclude" else 1)
        self.table.setCellWidget(row, 2, mode_combo)

        # Delete button
        del_btn = QPushButton("x")
        del_btn.setFixedWidth(40)
        del_btn.clicked.connect(lambda _, lid=label_id: self._delete_label(lid))
        self.table.setCellWidget(row, 3, del_btn)

    def _find_label_row(self, label_id):
        """Find the current row index for a label by its ID."""
        for i, label in enumerate(self.store.labels):
            if label.id == label_id:
                return i
        return None

    def _pick_color(self, label_id):
        row = self._find_label_row(label_id)
        if row is None:
            return
        label = self.store.labels[row]
        c = label.color
        initial = QColor(int(c['red'] * 255), int(c['green'] * 255), int(c['blue'] * 255))
        color = QColorDialog.getColor(initial, self, "Pick Label Color")
        if color.isValid():
            label.color = {
                "red": color.redF(), "green": color.greenF(),
                "blue": color.blueF(), "alpha": 1.0,
            }
            btn = self.table.cellWidget(row, 0)
            r, g, b = color.red(), color.green(), color.blue()
            btn.setStyleSheet(f"background-color: rgb({r},{g},{b}); border: 1px solid gray;")

    def _add_label(self):
        name = self.new_name.text().strip()
        if not name:
            return
        label = AnnotationLabel(name=name)
        self.store.labels.append(label)
        row = self.table.rowCount()
        self.table.insertRow(row)
        self._set_row(row, label)
        self.new_name.clear()

    def _delete_label(self, label_id):
        row = self._find_label_row(label_id)
        if row is None:
            return
        label = self.store.labels[row]
        reply = QMessageBox.question(
            self, "Delete Label",
            f"Delete '{label.name}'? All annotations with this label will be removed.",
            QMessageBox.Yes | QMessageBox.No,
        )
        if reply == QMessageBox.Yes:
            self.store.remove_annotations_for_label(label.id)
            self.store.labels.pop(row)
            self.table.removeRow(row)

    def _save_and_accept(self):
        # Read back edited names and modes
        for i in range(self.table.rowCount()):
            if i < len(self.store.labels):
                name_item = self.table.item(i, 1)
                if name_item:
                    self.store.labels[i].name = name_item.text()
                mode_combo = self.table.cellWidget(i, 2)
                if mode_combo:
                    self.store.labels[i].analysisMode = (
                        "exclude" if mode_combo.currentIndex() == 0
                        else "analyzeSeparately"
                    )
        self.store.save()
        self.accept()
