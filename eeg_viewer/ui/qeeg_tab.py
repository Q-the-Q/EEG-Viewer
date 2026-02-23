"""Tab 2: qEEG analysis dashboard."""

from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QComboBox,
    QPushButton, QProgressBar, QScrollArea, QGridLayout, QTableWidget,
    QTableWidgetItem, QHeaderView, QGroupBox, QSplitter, QFrame,
    QDoubleSpinBox, QCheckBox,
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal

from .spectra_widget import SpectraWidget
from .topomap_widget import TopomapWidget
from ..data.signal_processor import SignalProcessor
from ..data.normative_db import NormativeDB
from ..data.qeeg_analyzer import QEEGAnalyzer
from ..workers.analysis_worker import AnalysisWorker


class QEEGTab(QWidget):
    """qEEG analysis dashboard with spectra, topomaps, and peak frequencies."""

    # Signal emitted when analysis completes (passes analyzer and loader)
    analysis_complete = pyqtSignal(object, object)  # (analyzer, loader)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._loader = None
        self._analyzer = None
        self._worker = None
        self._thread = None
        self._init_ui()

    def _init_ui(self):
        main_layout = QVBoxLayout(self)

        # Top controls bar
        controls = QHBoxLayout()
        self._status_label = QLabel("Load an EDF file to begin analysis")
        self._status_label.setStyleSheet("font-size: 13px; color: #666;")
        controls.addWidget(self._status_label)
        controls.addStretch()

        controls.addWidget(QLabel("Z-Score Method:"))
        self._zscore_combo = QComboBox()
        self._zscore_combo.addItem("Within-Subject", "within")
        self._zscore_combo.addItem("Normative (Approximate)", "normative")
        self._zscore_combo.currentIndexChanged.connect(self._on_zscore_method_changed)
        self._zscore_combo.setEnabled(False)
        controls.addWidget(self._zscore_combo)

        self._export_btn = QPushButton("Export...")
        self._export_btn.setEnabled(False)
        self._export_btn.clicked.connect(self._on_export)
        controls.addWidget(self._export_btn)
        main_layout.addLayout(controls)

        # Time range selector bar
        range_bar = QHBoxLayout()
        range_bar.addWidget(QLabel("Analysis Time Range:"))

        self._range_check = QCheckBox("Custom range")
        self._range_check.setChecked(False)
        self._range_check.toggled.connect(self._on_range_toggled)
        range_bar.addWidget(self._range_check)

        range_bar.addWidget(QLabel("Start (s):"))
        self._start_spin = QDoubleSpinBox()
        self._start_spin.setDecimals(1)
        self._start_spin.setSingleStep(1.0)
        self._start_spin.setMinimum(0.0)
        self._start_spin.setMaximum(0.0)
        self._start_spin.setEnabled(False)
        self._start_spin.setFixedWidth(90)
        range_bar.addWidget(self._start_spin)

        range_bar.addWidget(QLabel("End (s):"))
        self._end_spin = QDoubleSpinBox()
        self._end_spin.setDecimals(1)
        self._end_spin.setSingleStep(1.0)
        self._end_spin.setMinimum(0.0)
        self._end_spin.setMaximum(0.0)
        self._end_spin.setEnabled(False)
        self._end_spin.setFixedWidth(90)
        range_bar.addWidget(self._end_spin)

        self._range_label = QLabel("")
        self._range_label.setStyleSheet("font-size: 12px; color: #888;")
        range_bar.addWidget(self._range_label)

        self._reanalyze_btn = QPushButton("Re-analyze")
        self._reanalyze_btn.setEnabled(False)
        self._reanalyze_btn.setStyleSheet(
            "QPushButton { background-color: #55AA55; color: white; border: none; "
            "border-radius: 3px; padding: 4px 12px; font-weight: bold; }"
            "QPushButton:hover { background-color: #449944; }"
            "QPushButton:disabled { background-color: #CCC; color: #888; }"
        )
        self._reanalyze_btn.clicked.connect(self._on_reanalyze)
        range_bar.addWidget(self._reanalyze_btn)

        range_bar.addStretch()
        main_layout.addLayout(range_bar)

        # Progress bar
        self._progress_bar = QProgressBar()
        self._progress_bar.setVisible(False)
        self._progress_bar.setTextVisible(True)
        main_layout.addWidget(self._progress_bar)

        # Scrollable content area
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.NoFrame)
        content = QWidget()
        self._content_layout = QVBoxLayout(content)
        self._content_layout.setSpacing(24)  # Increased from 16 for more breathing room
        self._content_layout.setContentsMargins(8, 8, 8, 8)

        # Magnitude Spectra section - larger visualization
        spectra_group = QGroupBox("QEEG Magnitude Spectra")
        spectra_group.setStyleSheet("QGroupBox { font-weight: bold; font-size: 14px; }")
        spectra_group.setMinimumHeight(500)  # Large enough for clear visualization
        spectra_layout = QVBoxLayout(spectra_group)
        spectra_layout.setContentsMargins(4, 12, 4, 4)
        self._spectra_widget = SpectraWidget()
        spectra_layout.addWidget(self._spectra_widget)
        self._content_layout.addWidget(spectra_group)

        # Topographic Maps section - larger visualization
        topo_group = QGroupBox("QEEG Relative Power")
        topo_group.setStyleSheet("QGroupBox { font-weight: bold; font-size: 14px; }")
        topo_group.setMinimumHeight(500)  # Large enough for clear topomap rendering
        topo_layout = QVBoxLayout(topo_group)
        topo_layout.setContentsMargins(4, 12, 4, 4)
        self._topomap_widget = TopomapWidget()
        topo_layout.addWidget(self._topomap_widget)
        self._content_layout.addWidget(topo_group)

        # Peak frequency table
        peak_group = QGroupBox("Peak Frequencies")
        peak_group.setStyleSheet("QGroupBox { font-weight: bold; font-size: 14px; }")
        peak_group.setMinimumHeight(250)
        peak_layout = QVBoxLayout(peak_group)
        peak_layout.setContentsMargins(4, 12, 4, 4)
        self._peak_table = QTableWidget()
        self._peak_table.setMaximumHeight(300)  # Increased from 200 to allow larger table
        peak_layout.addWidget(self._peak_table)
        self._content_layout.addWidget(peak_group)

        # Don't add stretch - let content flow naturally with scroll
        scroll.setWidget(content)
        main_layout.addWidget(scroll, stretch=1)

    def set_data(self, loader):
        """Start qEEG analysis on loaded data."""
        self._loader = loader

        # Configure time range spinboxes for this recording
        duration = loader.duration
        self._start_spin.setMaximum(duration)
        self._end_spin.setMaximum(duration)
        self._start_spin.setValue(0.0)
        self._end_spin.setValue(duration)
        self._update_range_label()

        self._run_analysis()

    def _get_time_range(self):
        """Return the selected time range or None for full recording."""
        if self._range_check.isChecked():
            start = self._start_spin.value()
            end = self._end_spin.value()
            if end > start:
                return (start, end)
        return None

    def _run_analysis(self, time_range=None):
        """Run the qEEG analysis, optionally on a specific time range."""
        self._status_label.setText("Computing qEEG analysis...")
        self._status_label.setStyleSheet("font-size: 13px; color: #666;")
        self._progress_bar.setVisible(True)
        self._progress_bar.setValue(0)
        self._reanalyze_btn.setEnabled(False)

        # Create analyzer with time range
        processor = SignalProcessor(self._loader.sfreq)
        normative = NormativeDB()
        method = self._zscore_combo.currentData()
        normative.set_method(method)

        self._analyzer = QEEGAnalyzer(
            self._loader, processor, normative, time_range=time_range
        )

        # Run in background thread
        self._thread = QThread()
        self._worker = AnalysisWorker(self._analyzer)
        self._worker.moveToThread(self._thread)
        self._thread.started.connect(self._worker.run)
        self._worker.progress.connect(self._on_progress)
        self._worker.finished.connect(self._on_analysis_complete)
        self._worker.error.connect(self._on_analysis_error)
        self._worker.finished.connect(self._thread.quit)
        self._thread.start()

    def _on_progress(self, percent, message):
        self._progress_bar.setValue(percent)
        self._progress_bar.setFormat(f"{message} ({percent}%)")

    def _on_range_toggled(self, checked):
        """Enable/disable time range spinboxes."""
        self._start_spin.setEnabled(checked)
        self._end_spin.setEnabled(checked)
        if self._loader:
            self._reanalyze_btn.setEnabled(True)
        self._update_range_label()

    def _update_range_label(self):
        """Update the label showing the current time range duration."""
        if not self._loader:
            return
        if self._range_check.isChecked():
            start = self._start_spin.value()
            end = self._end_spin.value()
            dur = max(0, end - start)
            self._range_label.setText(f"({dur:.1f}s selected)")
        else:
            self._range_label.setText(f"(full recording: {self._loader.duration:.1f}s)")

    def _on_reanalyze(self):
        """Re-run analysis with the current time range settings."""
        if not self._loader:
            return
        time_range = self._get_time_range()
        self._run_analysis(time_range=time_range)

    def _on_analysis_complete(self):
        self._progress_bar.setVisible(False)
        self._zscore_combo.setEnabled(True)
        self._export_btn.setEnabled(True)
        self._reanalyze_btn.setEnabled(True)

        # Build status message with artifact rejection and channel quality info
        status_parts = ["Analysis complete"]

        # Show time range if custom
        if self._analyzer.time_range:
            start, end = self._analyzer.time_range
            status_parts.append(f"[{start:.1f}s – {end:.1f}s]")

        status_parts.append("|")

        # Channel quality
        if self._analyzer.channel_quality:
            bad_chs = [ch for ch, q in self._analyzer.channel_quality.items() if q == 'poor']
            if bad_chs:
                status_parts.append(f"High-impedance channels: {', '.join(bad_chs)} |")

        # Artifact rejection stats
        stats = self._analyzer.artifact_stats
        if stats:
            status_parts.append(
                f"Epochs: {stats['clean_epochs']}/{stats['total_epochs']} clean "
                f"({stats['pct_rejected']:.1f}% rejected, threshold: {stats['threshold_uv']:.0f} µV)"
            )

        self._status_label.setText(" ".join(status_parts))

        # Populate widgets
        eeg_info = self._loader.get_eeg_info()
        self._spectra_widget.plot_spectra(self._analyzer)
        self._topomap_widget.plot_topomaps(self._analyzer, eeg_info)
        self._populate_peak_table()

        # Emit signal for other tabs (e.g., ConnectivityTab)
        self.analysis_complete.emit(self._analyzer, self._loader)

    def _on_analysis_error(self, error_msg):
        self._progress_bar.setVisible(False)
        self._status_label.setText(f"Analysis error: {error_msg}")
        self._status_label.setStyleSheet("font-size: 13px; color: red;")

    def _on_zscore_method_changed(self, index):
        if self._analyzer is None:
            return
        method = self._zscore_combo.currentData()
        self._analyzer.normative.set_method(method)
        self._analyzer.recompute_zscores()
        eeg_info = self._loader.get_eeg_info()
        self._topomap_widget.plot_topomaps(self._analyzer, eeg_info)
        # Update connectivity tab z-scores too
        self.analysis_complete.emit(self._analyzer, self._loader)

    def _populate_peak_table(self):
        if self._analyzer is None:
            return

        peak_freqs = self._analyzer.peak_freqs
        channels = list(peak_freqs.keys())

        self._peak_table.setColumnCount(3)
        self._peak_table.setHorizontalHeaderLabels(
            ["Channel", "Peak Alpha (Hz)", "Dominant Freq (Hz)"]
        )
        self._peak_table.setRowCount(len(channels))

        for row, ch in enumerate(channels):
            self._peak_table.setItem(row, 0, QTableWidgetItem(ch))
            alpha_peak = peak_freqs[ch].get("alpha_peak", 0)
            dominant = peak_freqs[ch].get("dominant", 0)
            self._peak_table.setItem(row, 1, QTableWidgetItem(f"{alpha_peak:.2f}"))
            self._peak_table.setItem(row, 2, QTableWidgetItem(f"{dominant:.2f}"))

        self._peak_table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)

    def _on_export(self):
        from .export_dialog import ExportDialog
        dialog = ExportDialog(self._analyzer, self._loader, self)
        dialog.exec_()
