#!/usr/bin/env python3
"""EEG Viewer - Desktop application for EEG waveform visualization and qEEG analysis."""

import sys
import os

# Ensure the script's directory is in the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PyQt5.QtWidgets import QApplication
from eeg_viewer.app import create_app


def main():
    app = QApplication(sys.argv)
    app.setApplicationName("EEG Viewer")
    window = create_app()
    window.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
