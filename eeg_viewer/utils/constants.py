"""Constants and default configuration for the EEG Viewer application."""

# Frequency band definitions (Hz)
FREQ_BANDS = {
    "Delta": (1.0, 4.0),
    "Theta": (4.0, 8.0),
    "Alpha": (8.0, 13.0),
    "Beta": (13.0, 25.0),
}

# Band colors for spectra shading
BAND_COLORS = {
    "Delta": "#D8BFD8",  # Thistle / light purple
    "Theta": "#90EE90",  # Light green
    "Alpha": "#FFFACD",  # Lemon chiffon / light yellow
    "Beta": "#FFA07A",   # Light salmon
}

# Band colors for topomaps and charts (solid)
BAND_SOLID_COLORS = {
    "Delta": "#8B008B",  # Dark magenta
    "Theta": "#228B22",  # Forest green
    "Alpha": "#DAA520",  # Goldenrod
    "Beta": "#CD5C5C",   # Indian red
}

# Z-score colormap range (matches PDF reference)
ZSCORE_VMIN = -2.5
ZSCORE_VMAX = 2.5

# Playback defaults
DEFAULT_WINDOW_SEC = 10.0
DEFAULT_SPEED = 1.0
MIN_SPEED = 0.5
MAX_SPEED = 4.0
TARGET_FPS = 30
WINDOW_SIZE_OPTIONS = [2.0, 5.0, 10.0, 20.0, 30.0, 60.0]

# Channel display
# After average re-referencing, EEG amplitude std is ~10 uV, so 50 uV spacing
# provides good separation without excessive whitespace
CHANNEL_SPACING_UV = 50.0  # microvolts between channel traces
DEFAULT_AMPLITUDE_SCALE = 1.0

# PSD computation
# nperseg=1024 at 500 Hz gives 0.488 Hz resolution, matching the NeuroSynchrony
# report's amplitude scale (e.g., ~4.3 µV Frontal max).
# Higher nperseg concentrates low-frequency power and inflates the 1-2 Hz peak.
PSD_NPERSEG = 1024
PSD_NOVERLAP = 512
PSD_WINDOW = "hann"

# Total power range for relative power computation
TOTAL_POWER_RANGE = (1.0, 25.0)

# Application styling
APP_NAME = "EEG Viewer"
BACKGROUND_COLOR = "#FFFFFF"
TRACE_COLOR = "#1a1a2e"
GRID_ALPHA = 0.3
