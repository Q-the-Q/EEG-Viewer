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
# nperseg=1024 at 500 Hz gives 0.488 Hz resolution, matching clinical qEEG
# report amplitude scales (e.g., ~4.3 µV Frontal max).
# Higher nperseg concentrates low-frequency power and inflates the 1-2 Hz peak.
PSD_NPERSEG = 1024
PSD_NOVERLAP = 512
PSD_WINDOW = "hann"

# Total power range for relative power computation
TOTAL_POWER_RANGE = (1.0, 25.0)

# Notch filter
NOTCH_FREQ_OPTIONS = [0, 50, 60]  # 0 = off
NOTCH_BANDWIDTH = 2.0  # Hz
NOTCH_DEFAULT_FREQ = 0  # Off by default, auto-detect from EDF metadata

# HRV Analysis
HRV_INTERPOLATION_RATE = 4.0  # Hz, uniform RR resampling
HRV_PSD_NPERSEG = 256  # Welch segment length at 4 Hz
HRV_PSD_NOVERLAP = 128  # 50% overlap
HRV_LF_BAND = (0.04, 0.15)  # Hz
HRV_HF_BAND = (0.15, 0.4)  # Hz
HRV_TOTAL_BAND = (0.003, 0.4)  # Hz

# R-peak detection
R_PEAK_REFRACTORY_MS = 200.0  # min interval between peaks
R_PEAK_MIN_RR_MS = 300.0  # min valid RR (200 BPM)
R_PEAK_MAX_RR_MS = 2000.0  # max valid RR (30 BPM)
ECG_BANDPASS_LOW = 5.0  # Hz
ECG_BANDPASS_HIGH = 15.0  # Hz

# Heart-brain coherence
HB_COHERENCE_BANDS = {
    "Delta": (1.0, 4.0),
    "Theta": (4.0, 8.0),
    "Alpha": (8.0, 13.0),
}
HB_COHERENCE_LF_BAND = (0.04, 0.15)  # Hz, for coherence averaging
HB_COHERENCE_MIN_NPERSEG = 128
HB_COHERENCE_MAX_NPERSEG = 256
EEG_ENVELOPE_WINDOW_SEC = 2.0
EEG_ENVELOPE_STEP_SEC = 0.25

# Artifact rejection (also used by signal_processor.py -- keep in sync)
ARTIFACT_THRESHOLD_UV = 100.0  # uV peak-to-peak

# Application styling
APP_NAME = "EEG Viewer"
BACKGROUND_COLOR = "#FFFFFF"
TRACE_COLOR = "#1a1a2e"
GRID_ALPHA = 0.3
