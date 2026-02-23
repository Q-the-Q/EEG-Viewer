"""Background thread worker for qEEG analysis."""

from PyQt5.QtCore import QObject, pyqtSignal


class AnalysisWorker(QObject):
    """Runs qEEG analysis in a background QThread."""

    progress = pyqtSignal(int, str)  # (percentage, status message)
    finished = pyqtSignal()
    error = pyqtSignal(str)

    def __init__(self, analyzer):
        super().__init__()
        self._analyzer = analyzer

    def run(self):
        """Execute the full analysis pipeline."""
        try:
            self._analyzer.set_progress_callback(self._on_progress)
            self._analyzer.run_full_analysis()
            self.finished.emit()
        except Exception as e:
            self.error.emit(str(e))

    def _on_progress(self, percent, message):
        self.progress.emit(percent, message)
