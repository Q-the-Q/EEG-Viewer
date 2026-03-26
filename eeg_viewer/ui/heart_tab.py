"""Heart Rate Analysis tab -- ECG, HRV metrics, Poincare, heart-brain coherence."""

from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QGroupBox, QLabel,
    QPushButton, QSplitter, QProgressBar,
)
from PyQt5.QtCore import Qt, QThread, pyqtSignal
import numpy as np

from matplotlib.backends.backend_qt5agg import FigureCanvasQTAgg
from matplotlib.figure import Figure
from matplotlib.patches import Arc
import matplotlib.patches as mpatches

from ..data.hrv_analyzer import run_full_analysis
from ..utils.constants import HRV_RANGES


class _AnalysisWorker(QThread):
    finished = pyqtSignal(dict)
    error = pyqtSignal(str)

    def __init__(self, ecg, sfreq, eeg_data, eeg_ch_names, exclusions):
        super().__init__()
        self.ecg = ecg
        self.sfreq = sfreq
        self.eeg_data = eeg_data
        self.eeg_ch_names = eeg_ch_names
        self.exclusions = exclusions

    def run(self):
        try:
            results = run_full_analysis(
                self.ecg, self.sfreq,
                self.eeg_data, self.eeg_ch_names,
                self.exclusions,
            )
            self.finished.emit(results)
        except Exception as e:
            self.error.emit(str(e))


class HeartTab(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._loader = None
        self._results = None
        self._worker = None
        self._setup_ui()

    def _setup_ui(self):
        layout = QVBoxLayout(self)

        # Top bar: analyze button + progress
        top = QHBoxLayout()
        self._analyze_btn = QPushButton("Analyze Heart Rate")
        self._analyze_btn.setEnabled(False)
        self._analyze_btn.clicked.connect(self._run_analysis)
        top.addWidget(self._analyze_btn)
        self._progress = QProgressBar()
        self._progress.setRange(0, 0)  # indeterminate
        self._progress.hide()
        top.addWidget(self._progress)
        self._status_label = QLabel("Load an EDF file with ECG channel")
        top.addWidget(self._status_label)
        top.addStretch()
        layout.addLayout(top)

        # Main content: 2x2 grid via splitters
        splitter_v = QSplitter(Qt.Vertical)

        # Top row: ECG plot + metrics
        splitter_top = QSplitter(Qt.Horizontal)

        # ECG with R-peaks
        ecg_group = QGroupBox("ECG with R-Peaks")
        ecg_layout = QVBoxLayout(ecg_group)
        self._ecg_fig = Figure(figsize=(6, 2))
        self._ecg_canvas = FigureCanvasQTAgg(self._ecg_fig)
        ecg_layout.addWidget(self._ecg_canvas)
        splitter_top.addWidget(ecg_group)

        # Metrics gauges
        metrics_group = QGroupBox("HRV Metrics")
        metrics_layout = QVBoxLayout(metrics_group)
        self._gauge_fig = Figure(figsize=(5, 4))
        self._gauge_canvas = FigureCanvasQTAgg(self._gauge_fig)
        metrics_layout.addWidget(self._gauge_canvas)
        splitter_top.addWidget(metrics_group)
        splitter_top.setSizes([500, 400])

        splitter_v.addWidget(splitter_top)

        # Bottom row: Poincare + coherence
        splitter_bot = QSplitter(Qt.Horizontal)

        # Poincare
        poincare_group = QGroupBox("Poincare Plot")
        poincare_layout = QVBoxLayout(poincare_group)
        self._poincare_fig = Figure(figsize=(3, 3))
        self._poincare_canvas = FigureCanvasQTAgg(self._poincare_fig)
        poincare_layout.addWidget(self._poincare_canvas)
        splitter_bot.addWidget(poincare_group)

        # Heart-brain coherence
        coherence_group = QGroupBox("Heart-Brain Coherence")
        coherence_layout = QVBoxLayout(coherence_group)
        self._coherence_fig = Figure(figsize=(4, 3))
        self._coherence_canvas = FigureCanvasQTAgg(self._coherence_fig)
        coherence_layout.addWidget(self._coherence_canvas)
        splitter_bot.addWidget(coherence_group)

        splitter_v.addWidget(splitter_bot)
        layout.addWidget(splitter_v)

    def set_data(self, loader):
        self._loader = loader
        # Check for ECG channel
        raw = loader.raw
        ecg_chs = [ch for ch in raw.ch_names
                    if ch.upper() in ('ECG', 'EKG', 'ECG1', 'EKG1')]
        has_ecg = len(ecg_chs) > 0
        self._analyze_btn.setEnabled(has_ecg)
        self._status_label.setText(
            f"ECG channel: {ecg_chs[0]}" if has_ecg
            else "No ECG channel found"
        )

    def _run_analysis(self):
        if not self._loader:
            return

        raw = self._loader.raw
        ecg_chs = [ch for ch in raw.ch_names
                    if ch.upper() in ('ECG', 'EKG', 'ECG1', 'EKG1')]
        if not ecg_chs:
            return

        ecg_idx = raw.ch_names.index(ecg_chs[0])
        ecg = raw.get_data(picks=[ecg_idx])[0]
        sfreq = raw.info['sfreq']

        # Get EEG data for coherence
        eeg_ch_names = self._loader.eeg_channel_names
        eeg_data = raw.get_data(picks=eeg_ch_names)

        # Get exclusions from annotation store if available
        main_window = self.window()
        exclusions = []
        if hasattr(main_window, 'annotation_store'):
            exclusions = main_window.annotation_store.excluded_time_ranges()

        self._analyze_btn.setEnabled(False)
        self._progress.show()
        self._status_label.setText("Analyzing...")

        # Stop previous worker if still running
        if self._worker is not None:
            self._worker.finished.disconnect()
            self._worker.error.disconnect()
            if self._worker.isRunning():
                self._worker.quit()
                self._worker.wait(1000)

        self._worker = _AnalysisWorker(ecg, sfreq, eeg_data, eeg_ch_names, exclusions)
        self._worker.finished.connect(self._on_results)
        self._worker.error.connect(self._on_error)
        self._worker.start()

    def _on_results(self, results):
        self._results = results
        self._progress.hide()
        self._analyze_btn.setEnabled(True)

        td = results["time_domain"]
        n_peaks = len(results["peaks"])
        self._status_label.setText(f"Done -- {n_peaks} R-peaks, HR {td['meanHR']:.0f} BPM")

        self._draw_ecg(results)
        self._fill_metrics(results)
        self._draw_poincare(results)
        self._draw_coherence(results)

    def _on_error(self, msg):
        self._progress.hide()
        self._analyze_btn.setEnabled(True)
        self._status_label.setText(f"Error: {msg}")

    def _draw_ecg(self, results):
        self._ecg_fig.clear()
        ax = self._ecg_fig.add_subplot(111)
        # Use original-timeline display data when available (exclusions applied)
        ecg = results.get("ecg_display", results["ecg_filtered"])
        peaks = results.get("peaks_display", results["peaks"])
        sfreq = self._loader.raw.info['sfreq']

        # Show first 10 seconds
        n_show = min(len(ecg), int(10 * sfreq))
        t = np.arange(n_show) / sfreq
        ax.plot(t, ecg[:n_show] * 1e6, color='#1a1a2e', linewidth=0.5)

        # R-peaks in window
        peak_mask = peaks < n_show
        if np.any(peak_mask):
            p = peaks[peak_mask]
            ax.scatter(p / sfreq, ecg[p] * 1e6, color='red', s=20, zorder=5)

        ax.set_xlabel("Time (s)")
        ax.set_ylabel("uV")
        ax.set_title("ECG (first 10s)")
        self._ecg_fig.tight_layout()
        self._ecg_canvas.draw()

    def _fill_metrics(self, results):
        td = results["time_domain"]
        fd = results["frequency_domain"]
        pc = results["poincare"]

        self._gauge_fig.clear()

        # 5 gauge metrics in a 2x3 grid (last cell has extra text metrics)
        gauge_data = [
            ("Mean HR", td["meanHR"], "BPM", "meanHR"),
            ("SDNN", td["sdnn"], "ms", "sdnn"),
            ("RMSSD", td["rmssd"], "ms", "rmssd"),
            ("pNN50", td["pnn50"], "%", "pnn50"),
            ("LF/HF", fd["lf_hf_ratio"], "", "lfhf"),
        ]

        for i, (title, value, unit, key) in enumerate(gauge_data):
            ax = self._gauge_fig.add_subplot(2, 3, i + 1)
            self._draw_gauge(ax, title, value, unit, key)

        # 6th cell: additional metrics as text
        ax_extra = self._gauge_fig.add_subplot(2, 3, 6)
        ax_extra.set_xlim(0, 1)
        ax_extra.set_ylim(0, 1)
        ax_extra.axis("off")
        extra_lines = [
            f"SD1: {pc['sd1']:.1f} ms",
            f"SD2: {pc['sd2']:.1f} ms",
            f"LF:  {fd['lf_power']:.1f} ms\u00b2",
            f"HF:  {fd['hf_power']:.1f} ms\u00b2",
            f"TP:  {fd['total_power']:.1f} ms\u00b2",
        ]
        for j, line in enumerate(extra_lines):
            ax_extra.text(0.1, 0.85 - j * 0.18, line, fontsize=8,
                         fontfamily='monospace', va='top')

        self._gauge_fig.tight_layout(pad=0.5)
        self._gauge_canvas.draw()

    def _draw_gauge(self, ax, title, value, unit, key):
        """Draw a semi-circular arc gauge with colored zones and needle."""
        rng = HRV_RANGES.get(key)
        if not rng:
            ax.text(0.5, 0.5, f"{title}\n{value:.1f} {unit}", ha='center', va='center',
                    transform=ax.transAxes, fontsize=9)
            ax.axis('off')
            return

        rng_min, norm_low, norm_high, rng_max, low_label, norm_label, high_label = rng
        ax.set_xlim(-1.3, 1.3)
        ax.set_ylim(-0.3, 1.4)
        ax.set_aspect('equal')
        ax.axis('off')

        # Draw arc segments: low (blue), normal (green), high (orange)
        def angle_for(v):
            frac = (v - rng_min) / (rng_max - rng_min)
            frac = max(0, min(1, frac))
            return 180 - frac * 180  # 180° (left) to 0° (right)

        lw = 12
        a_min = angle_for(rng_min)
        a_norm_low = angle_for(norm_low)
        a_norm_high = angle_for(norm_high)
        a_max = angle_for(rng_max)

        # Low zone
        arc_low = Arc((0, 0), 2, 2, angle=0, theta1=a_norm_low, theta2=a_min,
                      color='#4488CC', linewidth=lw, alpha=0.4)
        ax.add_patch(arc_low)
        # Normal zone
        arc_norm = Arc((0, 0), 2, 2, angle=0, theta1=a_norm_high, theta2=a_norm_low,
                       color='#44AA44', linewidth=lw, alpha=0.6)
        ax.add_patch(arc_norm)
        # High zone
        arc_high = Arc((0, 0), 2, 2, angle=0, theta1=a_max, theta2=a_norm_high,
                       color='#CC8844', linewidth=lw, alpha=0.4)
        ax.add_patch(arc_high)

        # Needle
        clamped = max(rng_min, min(rng_max, value))
        needle_angle = np.radians(angle_for(clamped))
        nx = 0.85 * np.cos(needle_angle)
        ny = 0.85 * np.sin(needle_angle)
        ax.plot([0, nx], [0, ny], color='#333333', linewidth=2, solid_capstyle='round')
        ax.plot(0, 0, 'o', color='#333333', markersize=4)

        # Value text
        if value < norm_low:
            color, label = '#CC6600', low_label
        elif value > norm_high:
            color, label = '#CC6600', high_label
        else:
            color, label = '#228B22', norm_label

        ax.text(0, -0.15, f"{value:.1f} {unit}", ha='center', fontsize=10,
                fontweight='bold', color=color)
        ax.text(0, 1.25, title, ha='center', fontsize=9, fontweight='bold')
        ax.text(0, -0.3, label, ha='center', fontsize=7, color=color, fontstyle='italic')

    def _draw_poincare(self, results):
        self._poincare_fig.clear()
        ax = self._poincare_fig.add_subplot(111)
        pc = results["poincare"]

        if len(pc["rr_n"]) > 0:
            ax.scatter(pc["rr_n"], pc["rr_n1"], s=5, alpha=0.5, color='steelblue')
            # Identity line
            lims = [min(np.min(pc["rr_n"]), np.min(pc["rr_n1"])),
                    max(np.max(pc["rr_n"]), np.max(pc["rr_n1"]))]
            ax.plot(lims, lims, 'k--', alpha=0.3)
            ax.set_title(f"SD1={pc['sd1']:.1f}  SD2={pc['sd2']:.1f}")
        else:
            ax.text(0.5, 0.5, "Insufficient data", ha='center', va='center',
                    transform=ax.transAxes)

        ax.set_xlabel("RR(n) ms")
        ax.set_ylabel("RR(n+1) ms")
        self._poincare_fig.tight_layout()
        self._poincare_canvas.draw()

    def _draw_coherence(self, results):
        self._coherence_fig.clear()
        ax = self._coherence_fig.add_subplot(111)

        hb = results.get("heart_brain")
        if not hb or "error" in hb:
            msg = hb.get("error", "No coherence data") if hb else "No EEG data"
            ax.text(0.5, 0.5, msg, ha='center', va='center',
                    transform=ax.transAxes)
            self._coherence_fig.tight_layout()
            self._coherence_canvas.draw()
            return

        bands = [b for b in ("Delta", "Theta", "Alpha") if b in hb]
        means = [hb[b]["mean"] for b in bands]
        colors = ['#6B5B95', '#88B04B', '#F7CAC9']

        bars = ax.bar(bands, means, color=colors[:len(bands)])
        best = hb.get("best_band", "")
        for i, b in enumerate(bands):
            if b == best:
                bars[i].set_edgecolor('gold')
                bars[i].set_linewidth(2)

        ax.set_ylabel("Mean Coherence")
        ax.set_title("Heart-Brain Coherence by Band")
        ax.set_ylim(0, 1)
        self._coherence_fig.tight_layout()
        self._coherence_canvas.draw()
