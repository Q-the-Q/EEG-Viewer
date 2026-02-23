"""Export dialog for CSV and PDF reports."""

from PyQt5.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QPushButton, QLabel,
    QFileDialog, QRadioButton, QButtonGroup, QGroupBox, QMessageBox,
)


class ExportDialog(QDialog):
    """Dialog for exporting qEEG results to CSV or PDF."""

    def __init__(self, analyzer, loader, parent=None):
        super().__init__(parent)
        self._analyzer = analyzer
        self._loader = loader
        self.setWindowTitle("Export qEEG Results")
        self.setMinimumWidth(350)
        self._init_ui()

    def _init_ui(self):
        layout = QVBoxLayout(self)

        # Format selection
        format_group = QGroupBox("Export Format")
        format_layout = QVBoxLayout()
        self._format_group = QButtonGroup(self)

        self._csv_radio = QRadioButton("CSV (numerical data)")
        self._csv_radio.setChecked(True)
        self._format_group.addButton(self._csv_radio)
        format_layout.addWidget(self._csv_radio)

        self._pdf_radio = QRadioButton("PDF Report (plots + data)")
        self._format_group.addButton(self._pdf_radio)
        format_layout.addWidget(self._pdf_radio)

        format_group.setLayout(format_layout)
        layout.addWidget(format_group)

        # Buttons
        btn_layout = QHBoxLayout()
        btn_layout.addStretch()

        cancel_btn = QPushButton("Cancel")
        cancel_btn.clicked.connect(self.reject)
        btn_layout.addWidget(cancel_btn)

        export_btn = QPushButton("Export")
        export_btn.setDefault(True)
        export_btn.clicked.connect(self._do_export)
        btn_layout.addWidget(export_btn)

        layout.addLayout(btn_layout)

    def _do_export(self):
        if self._csv_radio.isChecked():
            self._export_csv()
        else:
            self._export_pdf()

    def _export_csv(self):
        file_path, _ = QFileDialog.getSaveFileName(
            self, "Export CSV", "qeeg_results.csv",
            "CSV Files (*.csv);;All Files (*)"
        )
        if not file_path:
            return

        try:
            self._analyzer.export_csv(file_path)
            QMessageBox.information(self, "Export Complete", f"CSV saved to:\n{file_path}")
            self.accept()
        except Exception as e:
            QMessageBox.critical(self, "Export Error", str(e))

    def _export_pdf(self):
        file_path, _ = QFileDialog.getSaveFileName(
            self, "Export PDF Report", "qeeg_report.pdf",
            "PDF Files (*.pdf);;All Files (*)"
        )
        if not file_path:
            return

        try:
            from ..utils.pdf_report import PDFReportGenerator
            generator = PDFReportGenerator()
            eeg_info = self._loader.get_eeg_info()
            patient_info = self._loader.get_patient_info()
            generator.generate(self._analyzer, eeg_info, file_path, patient_info)
            QMessageBox.information(self, "Export Complete", f"PDF saved to:\n{file_path}")
            self.accept()
        except Exception as e:
            QMessageBox.critical(self, "Export Error", str(e))
