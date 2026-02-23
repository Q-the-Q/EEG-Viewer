"""Main application window with tab widget, menu bar, and status bar."""

from PyQt5.QtWidgets import (
    QMainWindow, QTabWidget, QFileDialog, QStatusBar, QAction, QMessageBox,
    QToolBar, QPushButton, QWidget, QVBoxLayout,
)
from PyQt5.QtCore import Qt
from PyQt5.QtGui import QFont

from .waveform_tab import WaveformTab
from .qeeg_tab import QEEGTab
from .connectivity_tab import ConnectivityTab
from .advanced_analysis_tab import AdvancedAnalysisTab
from .band_view_tab import BandViewTab
from ..data.edf_loader import EDFLoader
from ..utils.constants import APP_NAME


class MainWindow(QMainWindow):
    """Main window containing EEG waveform and qEEG analysis tabs."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._loader = EDFLoader()
        self._init_ui()
        self._init_toolbar()
        self._init_menu()
        self._init_statusbar()

    def _init_ui(self):
        # Tab widget
        self._tabs = QTabWidget()
        self._waveform_tab = WaveformTab()
        self._band_view_tab = BandViewTab()
        self._qeeg_tab = QEEGTab()
        self._connectivity_tab = ConnectivityTab()
        self._advanced_tab = AdvancedAnalysisTab()
        self._tabs.addTab(self._waveform_tab, "EEG Waveform")
        self._tabs.addTab(self._band_view_tab, "Band Waveforms")
        self._tabs.addTab(self._qeeg_tab, "qEEG Analysis")
        self._tabs.addTab(self._connectivity_tab, "Brain Connectivity")
        self._tabs.addTab(self._advanced_tab, "Advanced Analysis")

        # Connect qEEG analysis complete signal to other tabs
        self._qeeg_tab.analysis_complete.connect(self._on_qeeg_analysis_complete)

        self.setCentralWidget(self._tabs)

    def _init_toolbar(self):
        toolbar = QToolBar("Main Toolbar")
        toolbar.setMovable(False)
        toolbar.setStyleSheet(
            "QToolBar { spacing: 8px; padding: 4px; }"
        )
        self.addToolBar(toolbar)

        open_btn = QPushButton("  Open EDF File  ")
        open_btn.setFont(QFont("", 12))
        open_btn.setStyleSheet(
            "QPushButton {"
            "  background-color: #3388CC;"
            "  color: white;"
            "  border: none;"
            "  border-radius: 4px;"
            "  padding: 8px 16px;"
            "  font-weight: bold;"
            "}"
            "QPushButton:hover {"
            "  background-color: #2870A8;"
            "}"
        )
        open_btn.clicked.connect(self._open_file)
        toolbar.addWidget(open_btn)

    def _init_menu(self):
        menubar = self.menuBar()

        # File menu
        file_menu = menubar.addMenu("File")

        open_action = QAction("Open EDF...", self)
        open_action.setShortcut("Ctrl+O")
        open_action.triggered.connect(self._open_file)
        file_menu.addAction(open_action)

        file_menu.addSeparator()

        quit_action = QAction("Quit", self)
        quit_action.setShortcut("Ctrl+Q")
        quit_action.triggered.connect(self.close)
        file_menu.addAction(quit_action)

        # Help menu
        help_menu = menubar.addMenu("Help")
        about_action = QAction("About", self)
        about_action.triggered.connect(self._show_about)
        help_menu.addAction(about_action)

    def _init_statusbar(self):
        self._statusbar = QStatusBar()
        self.setStatusBar(self._statusbar)
        self._statusbar.showMessage("Ready - Open an EDF file to begin")

    def _open_file(self):
        file_path, _ = QFileDialog.getOpenFileName(
            self, "Open EDF File", "",
            "EDF Files (*.edf *.edf+);;All Files (*)"
        )
        if not file_path:
            return

        try:
            self._loader.load(file_path)
        except Exception as e:
            QMessageBox.critical(self, "Error Loading File", str(e))
            return

        # Update UI
        filename = file_path.split("/")[-1]
        self.setWindowTitle(f"{APP_NAME} - {filename}")

        dur_m, dur_s = divmod(int(self._loader.duration), 60)
        self._statusbar.showMessage(
            f"{self._loader.n_eeg_channels} EEG channels + "
            f"{'ECG' if 'ECG' in self._loader.channel_names else 'no ECG'} | "
            f"{self._loader.sfreq:.0f} Hz | "
            f"{dur_m:02d}:{dur_s:02d} duration"
        )

        # Pass data to tabs
        self._waveform_tab.set_data(self._loader)
        self._band_view_tab.set_data(self._loader)
        self._qeeg_tab.set_data(self._loader)

    def _show_about(self):
        QMessageBox.about(
            self,
            f"About {APP_NAME}",
            f"{APP_NAME} v1.0\n\n"
            "EEG waveform visualization and qEEG analysis.\n"
            "Supports EDF/EDF+ format files.\n\n"
            "Built with PyQt5, MNE-Python, and PyQtGraph."
        )

    def _on_qeeg_analysis_complete(self, analyzer, loader):
        """Called when qEEG analysis completes - update other tabs."""
        self._connectivity_tab.set_analyzer(analyzer, loader)
        self._advanced_tab.set_analyzer(analyzer, loader)

    def keyPressEvent(self, event):
        """Handle keyboard shortcuts."""
        if event.key() == Qt.Key_Space:
            current = self._tabs.currentWidget()
            if current == self._waveform_tab:
                self._waveform_tab._on_play_pause()
                return
            elif current == self._band_view_tab:
                self._band_view_tab._on_play_pause()
                return
        super().keyPressEvent(event)
