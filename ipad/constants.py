"""Constants and configuration for the iPad EEG Viewer."""

# Frequency band definitions (Hz)
FREQ_BANDS = {
    "Delta": (1.0, 4.0),
    "Theta": (4.0, 8.0),
    "Alpha": (8.0, 13.0),
    "Beta": (13.0, 25.0),
}

# Total power range for relative power computation
TOTAL_POWER_RANGE = (1.0, 25.0)

# PSD computation
PSD_NPERSEG = 1024
PSD_NOVERLAP = 512
PSD_WINDOW = "hann"

# Z-score colormap range
ZSCORE_VMIN = -2.5
ZSCORE_VMAX = 2.5

# Artifact rejection
EPOCH_DURATION_SEC = 2.0
ARTIFACT_THRESHOLD_UV = 100.0
MIN_CLEAN_EPOCHS = 30

# Standard 10-20 EEG channels
STANDARD_1020_CHANNELS = [
    "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8",
    "T7", "C3", "Cz", "C4", "T8",
    "P7", "P3", "Pz", "P4", "P8", "O1", "O2",
]

# Mapping of channels to brain regions
REGION_MAP = {
    "Frontal": ["Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8"],
    "Central": ["T7", "C3", "Cz", "C4", "T8"],
    "Posterior": ["P7", "P3", "Pz", "P4", "P8", "O1", "O2"],
}

# Homologous pairs for hemispheric asymmetry
ASYMMETRY_PAIRS = [
    ("Fp1", "Fp2"), ("F7", "F8"), ("F3", "F4"), ("T7", "T8"),
    ("C3", "C4"), ("P7", "P8"), ("P3", "P4"), ("O1", "O2"),
]

# Band colors for spectra shading
BAND_SHADING = {
    "Delta": "#D6EAF8",
    "Theta": "#D5F5E3",
    "Alpha": "#FCF3CF",
    "Beta":  "#D4EFF7",
}
