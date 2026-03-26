"""Multi-EDF comparison tab -- side-by-side band power and topomaps for up to 3 recordings."""

from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGroupBox, QPushButton,
    QLabel, QFileDialog, QSplitter, QProgressBar,
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal
import numpy as np

from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from matplotlib.figure import Figure

from ..data.edf_loader import EDFLoader
from ..data.signal_processor import SignalProcessor
from ..data.qeeg_analyzer import QEEGAnalyzer
from ..data.normative_db import NormativeDB
from ..utils.constants import FREQ_BANDS, BAND_SOLID_COLORS


MAX_COMPARISONS = 3
SLOT_COLORS = ['#4A90D9', '#D94A4A', '#4AD94A']


class _SlotWorker(QThread):
    finished = pyqtSignal(int, object)  # slot_index, analyzer
    error = pyqtSignal(int, str)

    def __init__(self, slot_idx, loader, notch_freq):
        super().__init__()
        self.slot_idx = slot_idx
        self.loader = loader
        self.notch_freq = notch_freq

    def run(self):
        try:
            processor = SignalProcessor(self.loader.sfreq)
            normative = NormativeDB()
            analyzer = QEEGAnalyzer(
                self.loader, processor, normative,
                notch_freq=self.notch_freq,
            )
            analyzer.run_full_analysis()
            self.finished.emit(self.slot_idx, analyzer)
        except Exception as e:
            self.error.emit(self.slot_idx, str(e))


class ComparisonTab(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._slots = [None] * MAX_COMPARISONS  # (loader, analyzer, filename)
        self._workers = [None] * MAX_COMPARISONS
        self._old_workers = []  # keep refs to prevent GC of running threads
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        # Slot controls
        controls = QHBoxLayout()
        self._slot_buttons = []
        self._slot_labels = []

        for i in range(MAX_COMPARISONS):
            btn = QPushButton(f"Load Recording {i + 1}")
            btn.setStyleSheet(f"background-color: {SLOT_COLORS[i]}; color: white; padding: 6px;")
            btn.clicked.connect(lambda _, idx=i: self._load_slot(idx))
            controls.addWidget(btn)

            label = QLabel("(empty)")
            controls.addWidget(label)

            self._slot_buttons.append(btn)
            self._slot_labels.append(label)

        self._progress = QProgressBar()
        self._progress.setRange(0, 0)
        self._progress.hide()
        controls.addWidget(self._progress)
        layout.addLayout(controls)

        # Comparison plots
        splitter = QSplitter(Qt.Vertical)

        # Band power comparison
        bp_group = QGroupBox("Band Power Comparison")
        bp_layout = QVBoxLayout(bp_group)
        self._bp_fig = Figure(figsize=(8, 3))
        self._bp_canvas = FigureCanvasQTAgg(self._bp_fig)
        bp_layout.addWidget(self._bp_canvas)
        splitter.addWidget(bp_group)

        # Topomap comparison
        topo_group = QGroupBox("Topographic Maps")
        topo_layout = QVBoxLayout(topo_group)
        self._topo_fig = Figure(figsize=(8, 4))
        self._topo_canvas = FigureCanvasQTAgg(self._topo_fig)
        topo_layout.addWidget(self._topo_canvas)
        splitter.addWidget(topo_group)

        layout.addWidget(splitter)

    def _load_slot(self, idx):
        file_path, _ = QFileDialog.getOpenFileName(
            self, f"Open EDF for Slot {idx + 1}",
            "", "EDF Files (*.edf *.edf+)"
        )
        if not file_path:
            return

        loader = EDFLoader()
        loader.load(file_path)
        filename = file_path.rsplit('/', 1)[-1]
        self._slot_labels[idx].setText(filename)

        # Get notch freq
        main_window = self.window()
        notch_freq = main_window.get_notch_freq() if hasattr(main_window, 'get_notch_freq') else 0

        # Disconnect previous worker; keep reference alive to prevent GC crash
        old_worker = self._workers[idx]
        if old_worker is not None:
            old_worker.finished.disconnect()
            old_worker.error.disconnect()
            if old_worker.isRunning():
                self._old_workers.append(old_worker)
                old_worker.finished.connect(
                    lambda _i=0, _a=None, w=old_worker:
                        self._old_workers.remove(w) if w in self._old_workers else None
                )

        self._progress.show()
        worker = _SlotWorker(idx, loader, notch_freq)
        worker.finished.connect(self._on_slot_done)
        worker.error.connect(self._on_slot_error)
        self._workers[idx] = worker
        worker.start()

    def _on_slot_done(self, idx, analyzer):
        filename = self._slot_labels[idx].text()
        self._slots[idx] = {
            "analyzer": analyzer,
            "filename": filename,
        }
        self._progress.hide()
        self._update_comparison()

    def _on_slot_error(self, idx, msg):
        self._progress.hide()
        self._slot_labels[idx].setText(f"Error: {msg}")

    def _update_comparison(self):
        """Redraw comparison plots for all loaded slots."""
        loaded = [(i, s) for i, s in enumerate(self._slots) if s is not None]
        if not loaded:
            return

        self._draw_band_comparison(loaded)
        self._draw_topo_comparison(loaded)

    def _draw_band_comparison(self, loaded):
        self._bp_fig.clear()
        n_loaded = len(loaded)
        bands = list(FREQ_BANDS.keys())
        n_bands = len(bands)
        bar_width = 0.8 / n_loaded

        ax = self._bp_fig.add_subplot(111)
        x = np.arange(n_bands)

        for j, (slot_idx, slot) in enumerate(loaded):
            analyzer = slot["analyzer"]
            powers = []
            for band_name in bands:
                if band_name in analyzer.relative_powers:
                    powers.append(np.mean(analyzer.relative_powers[band_name]) * 100)
                else:
                    powers.append(0)

            ax.bar(x + j * bar_width, powers, bar_width,
                   label=slot["filename"], color=SLOT_COLORS[slot_idx], alpha=0.8)

        ax.set_xticks(x + bar_width * (n_loaded - 1) / 2)
        ax.set_xticklabels(bands)
        ax.set_ylabel("Relative Power (%)")
        ax.set_title("Band Power Comparison")
        ax.legend(fontsize='small')
        self._bp_fig.tight_layout()
        self._bp_canvas.draw()

    def _draw_topo_comparison(self, loaded):
        self._topo_fig.clear()
        n_loaded = len(loaded)
        bands = list(FREQ_BANDS.keys())
        n_bands = len(bands)

        for j, (slot_idx, slot) in enumerate(loaded):
            analyzer = slot["analyzer"]
            for b, band_name in enumerate(bands):
                ax = self._topo_fig.add_subplot(n_loaded, n_bands, j * n_bands + b + 1)
                if band_name in analyzer.zscores:
                    import mne
                    zscore_data = analyzer.zscores[band_name]
                    info = analyzer.loader.get_eeg_info()
                    mne.viz.plot_topomap(
                        zscore_data, info, axes=ax, show=False,
                        vlim=(-2.5, 2.5), cmap='RdBu_r',
                    )
                title = f"{slot['filename'][:15]}\n{band_name}" if j == 0 else band_name
                ax.set_title(title, fontsize=8)

        self._topo_fig.tight_layout()
        self._topo_canvas.draw()
