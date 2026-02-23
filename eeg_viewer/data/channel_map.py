"""EEG channel mapping for the 10-20 system.

Maps channels to brain regions, defines homologous pairs for asymmetry analysis,
and provides the standard channel ordering.
"""

# Standard 10-20 EEG channels (19 channels, after renaming old nomenclature)
STANDARD_1020_CHANNELS = [
    "Fp1", "Fp2",
    "F7", "F3", "Fz", "F4", "F8",
    "T7", "C3", "Cz", "C4", "T8",
    "P7", "P3", "Pz", "P4", "P8",
    "O1", "O2",
]

# Mapping of 10-20 channels to brain regions (for magnitude spectra)
REGION_MAP = {
    "Frontal": ["Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8"],
    "Central": ["T7", "C3", "Cz", "C4", "T8"],
    "Posterior": ["P7", "P3", "Pz", "P4", "P8", "O1", "O2"],
}

# Homologous pairs for hemispheric asymmetry analysis (left, right)
ASYMMETRY_PAIRS = [
    ("Fp1", "Fp2"),
    ("F7", "F8"),
    ("F3", "F4"),
    ("T7", "T8"),
    ("C3", "C4"),
    ("P7", "P8"),
    ("P3", "P4"),
    ("O1", "O2"),
]

# Old 10-20 nomenclature to new (ACNS 2006 standard)
OLD_TO_NEW_CHANNEL_NAMES = {
    "T3": "T7",
    "T4": "T8",
    "T5": "P7",
    "T6": "P8",
}

# Display order for channels in waveform viewer (top to bottom)
DISPLAY_ORDER = [
    "Fp1", "Fp2",
    "F7", "F3", "Fz", "F4", "F8",
    "T7", "C3", "Cz", "C4", "T8",
    "P7", "P3", "Pz", "P4", "P8",
    "O1", "O2",
    "ECG",
]
