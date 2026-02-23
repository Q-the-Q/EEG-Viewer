"""Application setup and factory."""

import os
import matplotlib
matplotlib.use("Qt5Agg")

import pyqtgraph as pg

from .utils.constants import APP_NAME


def configure():
    """Configure application-level settings."""
    # High-DPI support
    os.environ["QT_AUTO_SCREEN_SCALE_FACTOR"] = "1"

    # PyQtGraph defaults
    pg.setConfigOptions(antialias=True, background="w", foreground="k")


def create_app():
    """Create and return the main window."""
    configure()
    from .ui.main_window import MainWindow
    window = MainWindow()
    window.setWindowTitle(APP_NAME)
    window.resize(1400, 900)
    return window
