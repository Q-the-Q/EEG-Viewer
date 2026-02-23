"""Tab: Brain Connectivity Analysis - Coherence and Hemispheric Asymmetry."""

from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QSplitter, QGroupBox, QFrame, QScrollArea,
)
from PyQt5.QtCore import Qt

from .coherence_widget import CoherenceWidget
from .asymmetry_widget import AsymmetryWidget


class ConnectivityTab(QWidget):
    """Large, dedicated view for coherence and asymmetry analysis results."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._analyzer = None
        self._loader = None
        self._init_ui()

    def _init_ui(self):
        main_layout = QVBoxLayout(self)
        main_layout.setSpacing(0)
        main_layout.setContentsMargins(0, 0, 0, 0)

        # Top label bar
        header = QHBoxLayout()
        header_label = QLabel("Brain Connectivity Analysis")
        header_label.setStyleSheet("font-size: 16px; font-weight: bold; padding: 12px;")
        header.addWidget(header_label)
        header.addStretch()
        main_layout.addLayout(header)

        # Divider
        divider = QFrame()
        divider.setFrameShape(QFrame.HLine)
        main_layout.addWidget(divider)

        # Content area with splitter
        splitter = QSplitter(Qt.Horizontal)
        splitter.setStyleSheet("QSplitter::handle { background-color: #ddd; }")

        # Left: Coherence (larger)
        coh_group = QGroupBox("Coherence Matrix")
        coh_group.setStyleSheet(
            "QGroupBox { font-weight: bold; font-size: 13px; padding-top: 10px; } "
            "QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 3px 0 3px; }"
        )
        coh_layout = QVBoxLayout(coh_group)
        coh_layout.setContentsMargins(8, 12, 8, 8)
        self._coherence_widget = CoherenceWidget()
        coh_layout.addWidget(self._coherence_widget)
        splitter.addWidget(coh_group)

        # Right: Asymmetry (larger)
        asym_group = QGroupBox("Hemispheric Asymmetry")
        asym_group.setStyleSheet(
            "QGroupBox { font-weight: bold; font-size: 13px; padding-top: 10px; } "
            "QGroupBox::title { subcontrol-origin: margin; left: 10px; padding: 0 3px 0 3px; }"
        )
        asym_layout = QVBoxLayout(asym_group)
        asym_layout.setContentsMargins(8, 12, 8, 8)
        self._asymmetry_widget = AsymmetryWidget()
        asym_layout.addWidget(self._asymmetry_widget)
        splitter.addWidget(asym_group)

        # Equal initial sizes
        splitter.setSizes([500, 500])
        splitter.setCollapsible(0, False)
        splitter.setCollapsible(1, False)

        main_layout.addWidget(splitter, stretch=1)

    def set_analyzer(self, analyzer, loader):
        """Update plots with analyzer results."""
        self._analyzer = analyzer
        self._loader = loader
        if analyzer and analyzer.coherence:
            self._coherence_widget.plot_coherence(analyzer)
            self._asymmetry_widget.plot_asymmetry(analyzer)

    def update_plots(self, analyzer):
        """Refresh plots when analyzer is updated (e.g., z-score method change)."""
        if analyzer and analyzer.coherence:
            self._coherence_widget.plot_coherence(analyzer)
            self._asymmetry_widget.plot_asymmetry(analyzer)
