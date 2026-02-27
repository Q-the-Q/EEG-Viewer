# EEG Viewer

A cross-platform EEG visualization and quantitative EEG (qEEG) analysis application for standard `.edf` (European Data Format) files. Available as both a **Python desktop application** (macOS/Linux/Windows) and a **native iPadOS app** (Swift/SwiftUI).

Both platforms perform the same core analysis — magnitude spectra, topographic Z-score maps, coherence matrices, hemispheric asymmetry, and peak frequency detection — with output styled to match clinical qEEG reports.

---

## Platforms

### Python Desktop App

Built with PyQt5 for the GUI, MNE-Python for EEG data handling, and matplotlib for publication-quality spectra and topomap visualizations.

**Features:**
- **Multi-channel EEG display** of all 19 standard 10-20 channels plus ECG
- **Two playback modes**: real-time animated playback with adjustable speed (0.5x-4x), and static scrollable view
- **Channel selection**: toggle individual channels on/off
- **Amplitude scaling**: adjustable gain for waveform traces
- **Time window**: configurable display windows (2s, 5s, 10s, 20s, 30s, 60s)
- **Playback scrubber**: seek to any point in the recording
- **qEEG Analysis**: magnitude spectra, topographic maps, coherence matrix, hemispheric asymmetry, peak frequencies
- **PDF Report**: multi-page clinical-style report with embedded spectra, topomaps, and data tables
- **CSV Export**: all numerical results in tabular format

### iPadOS App

Native Swift application built with SwiftUI, Swift Charts, and Apple's Accelerate framework for high-performance DSP. Zero external dependencies — EDF parsing, FFT, and all signal processing use only Apple frameworks.

**Features:**
- **EEG Waveform Viewer**: multi-channel scrollable waveform display with pinch-to-zoom, amplitude scaling, and time window control
- **Band Waveforms**: filtered waveform traces per frequency band (Delta, Theta, Alpha, Beta)
- **qEEG Analysis Dashboard**:
  - **Magnitude Spectra**: Frontal, Central, and Posterior region amplitude spectra (1–30 Hz) with shared Y-axis scaling using Swift Charts
  - **Topographic Z-Score Maps**: four interpolated head maps (Delta, Theta, Alpha, Beta) rendered via CoreGraphics with a custom clinical colormap
  - **Coherence Matrix**: inter-channel coherence heatmap rendered on Canvas, with band selection shared across all recordings
  - **Hemispheric Asymmetry**: bar charts showing ln(Right) − ln(Left) for 8 homologous pairs, with shared band picker
  - **Peak Frequency Table**: alpha peak and dominant frequency per channel
- **Multi-EDF Comparison**: compare up to 3 EDF recordings side-by-side (1 primary + 2 comparisons) with synchronized band selection and shared spectra Y-axis
- **PDF Export**: multi-page clinical report with all chart sections, coherence/asymmetry rendered for all 4 bands and grouped by band for easy comparison across recordings. Shared via `UIActivityViewController` (Save to Files, AirDrop, email, iMessage)
- **3D Brain View**: interactive SceneKit visualization of electrode positions on a brain model
- **Artifact Rejection**: epoch-based artifact detection with adaptive thresholds and rejection statistics displayed per recording

---

## Installation

### Python Desktop App

**Requirements:** Python 3.9 or later · macOS, Linux, or Windows

```bash
cd "EEG Viewer"

# Create a virtual environment (recommended, especially on macOS with Homebrew Python)
python3 -m venv venv
source venv/bin/activate   # macOS/Linux
# venv\Scripts\activate    # Windows

# Install dependencies
pip install -r requirements.txt
```

**Dependencies:**
| Package | Purpose |
|---------|---------|
| PyQt5 | Desktop GUI framework |
| pyqtgraph | High-performance waveform plotting |
| MNE-Python | EEG data I/O, montage setup, topomap rendering |
| scipy | Welch PSD, coherence, bandpass filtering, numerical integration |
| numpy | Numerical computing |
| matplotlib | Spectra plots, topographic maps, embedded in Qt |
| reportlab | PDF report generation |

### iPadOS App

**Requirements:** Xcode 15+ · iPadOS 16+ (uses `ImageRenderer`, Swift Charts)

1. Open `EEGViewer/EEGViewer.xcodeproj` in Xcode
2. Select your iPad device or simulator as the build target
3. Build and run (⌘R)

No external dependencies — the app uses only Apple frameworks (SwiftUI, Accelerate, CoreGraphics, SceneKit, Charts).

---

## Usage

### Python Desktop App

```bash
source venv/bin/activate
python main.py
```

1. Click **"Open EDF File"** in the toolbar (or File > Open EDF)
2. Select a `.edf` file containing EEG data
3. The **Waveform** tab shows the raw EEG traces
4. The **qEEG Analysis** tab automatically computes and displays all analyses
5. Use **Export** to save results as PDF or CSV

### iPadOS App

1. Tap **"Open EDF File"** on the welcome screen (or the toolbar button)
2. Select a `.edf` file from Files
3. Navigate tabs: **EEG Waveform** → **Band Waveforms** → **qEEG Analysis** → **3D Brain**
4. In the qEEG Analysis tab, tap **"Run qEEG Analysis"** to compute
5. Use **"Add Comparison EDF"** to load additional recordings for side-by-side comparison
6. Tap **"Export PDF"** to generate and share a clinical report

---

## Neuroscience Background

### The EEG Signal

Electroencephalography (EEG) measures electrical activity generated by populations of cortical neurons. When large groups of pyramidal neurons fire synchronously, the summed postsynaptic potentials create voltage fluctuations detectable at the scalp surface. These signals are typically in the range of 10-100 microvolts (uV) and are recorded at multiple electrode locations across the scalp.

### The International 10-20 System

The standard 10-20 system defines 19 electrode positions on the scalp, placed at 10% and 20% intervals of measured skull distances:

```
         Fp1  Fp2          (Frontopolar)
     F7  F3   Fz   F4  F8  (Frontal)
     T7  C3   Cz   C4  T8  (Central/Temporal)
     P7  P3   Pz   P4  P8  (Parietal/Temporal)
         O1   O2           (Occipital)
```

- **Letters** indicate the brain region: Fp (frontopolar), F (frontal), C (central), T (temporal), P (parietal), O (occipital)
- **Odd numbers** are left hemisphere, **even numbers** are right hemisphere, **z** is midline

**Note on nomenclature**: Older EEG systems (including some Zeto devices) use the original 10-20 names T3/T4/T5/T6. The 2006 ACNS standard renamed these to T7/T8/P7/P8 respectively. This application automatically handles the conversion.

### Frequency Bands

EEG activity is decomposed into standard frequency bands, each associated with different brain states:

| Band | Range | Associated Activity |
|------|-------|-------------------|
| **Delta** | 1-4 Hz | Deep sleep, pathological slowing in wake, brain lesions |
| **Theta** | 4-8 Hz | Drowsiness, light sleep, memory encoding, meditation |
| **Alpha** | 8-13 Hz | Relaxed wakefulness (eyes closed), dominant in posterior regions, suppresses with eye opening |
| **Beta** | 13-25 Hz | Active thinking, focus, anxiety, motor planning |

Alpha activity is the dominant rhythm in healthy awake adults with eyes closed and is strongest over posterior (occipital/parietal) regions. Its peak frequency (typically 9-11 Hz) varies with age and is an important clinical marker.

### Brain Regions in This Application

For the magnitude spectra display, channels are grouped into three regions matching clinical convention:

- **Frontal**: Fp1, Fp2, F7, F3, Fz, F4, F8 (prefrontal and frontal cortex)
- **Central**: T7, C3, Cz, C4, T8 (central and temporal cortex, including sensorimotor areas)
- **Posterior**: P7, P3, Pz, P4, P8, O1, O2 (parietal and occipital cortex, including visual areas)

---

## Calculations and Signal Processing

> **Note:** The technical details below describe the signal processing pipeline, which is implemented equivalently in both the Python desktop app (using scipy/numpy/MNE) and the iPadOS app (using Apple's Accelerate/vDSP framework). The iPadOS app performs all FFT, PSD, and filtering operations natively via `vDSP.FFT` and `vDSP` vector operations — no Python bridge or external libraries are needed.

### Preprocessing Pipeline

Before analysis, the raw EEG data undergoes the following preprocessing steps:

1. **Channel Renaming**: Strip device-specific prefixes (e.g., "EEG Fp1" becomes "Fp1") and convert old nomenclature (T3/T4/T5/T6 to T7/T8/P7/P8)

2. **Average Re-referencing**: Raw EEG from hardware devices is recorded against a single physical reference electrode. This common signal can dominate the data. Re-referencing to the average of all 19 EEG channels (`raw.set_eeg_reference("average")`) removes the common signal and produces voltage distributions that better reflect underlying cortical sources. This step is critical - without it, spectral amplitudes may be inflated by 3-5x.

3. **High-pass Filtering at 1 Hz**: A 1 Hz high-pass filter removes slow DC drift and attenuates low-frequency artifacts such as eye blinks (which primarily affect frontal channels) and electrode drift. Clinical qEEG software applies similar preprocessing.

4. **Impedance Detection & Adaptive Filtering**: Before artifact rejection, the software automatically detects high-impedance (poor-quality) channels by analyzing:
   - **Low-frequency noise floor** (0.5-2 Hz) — high impedance shows as elevated low-freq power
   - **1/f slope** — steep slopes indicate poor signal quality
   - **Abnormally high RMS amplitude** — channels in the top 25% RMS

   Channels flagged as high-impedance receive **stronger filtering**:
   - **Poor-quality channels**: 1 Hz high-pass (stronger) + 50 Hz notch + 40 Hz low-pass smoothing
   - **Good-quality channels**: 0.5 Hz high-pass (standard) + 50 Hz notch only

   This adaptive approach reduces noise without over-filtering good signals. Example: If frontal electrode Fp1 has high impedance, it gets extra smoothing to reduce its noise contribution during subsequent spectral analysis.

5. **Epoch-Based Artifact Rejection**: The continuous recording is segmented into 2-second epochs. For each epoch, the peak-to-peak amplitude (max - min) is computed for every EEG channel. If **any** channel in an epoch exceeds 100 µV peak-to-peak, that entire epoch is rejected. This removes transient artifacts caused by:
   - **Head/body movement** — large, slow deflections affecting multiple channels
   - **Muscle artifacts (EMG)** — high-frequency bursts, especially in temporal channels (T7, T8)
   - **Eye blinks/movements (EOG)** — sharp frontal deflections (Fp1, Fp2)
   - **Electrode pops** — sudden spikes from loose electrode contact

   Only the clean (artifact-free) epochs are concatenated and used for all subsequent spectral computations. This is the standard approach used by clinical qEEG software (NeuroSynchrony, NeuroGuide, BrainDx). If fewer than 30 clean epochs remain, the threshold is progressively relaxed (to 150, 200, 300, then 500 µV) to ensure enough data for reliable spectral estimation.

### Power Spectral Density (PSD) via Welch's Method

The core spectral analysis uses Welch's method (`scipy.signal.welch`):

1. The continuous EEG signal is divided into overlapping segments
2. Each segment is windowed (Hann window) and FFT-transformed
3. The squared magnitudes of all segments are averaged, reducing noise

**Parameters used:**
- `nperseg = 1024` (segment length): at 500 Hz sampling rate, this gives a frequency resolution of 0.488 Hz
- `noverlap = 512` (50% overlap): standard for Welch's method, reduces variance
- `window = 'hann'` (Hann window): reduces spectral leakage from windowing

The result is a PSD estimate in V^2/Hz for each channel, representing how power is distributed across frequencies.

### Amplitude (Magnitude) Spectrum

The magnitude spectra displayed in the plots are computed as:

```
amplitude(f) = sqrt(PSD(f)) * 1e6    [units: uV/sqrt(Hz)]
```

For regional spectra, the PSD values from all channels in a region are averaged before taking the square root. This matches the convention used in clinical qEEG reports where Y-axis values are in microvolts.

### Band Power Computation

**Absolute band power** for each frequency band is computed by numerical integration of the PSD over the band's frequency range using Simpson's rule (`scipy.integrate.simpson`):

```
P_band = integral from f_low to f_high of PSD(f) df    [units: V^2]
```

**Relative band power** normalizes each band's power by the total power across all bands:

```
P_relative = P_band / P_total
```

where `P_total` is the integral from 1-25 Hz. Relative power expresses what fraction of total EEG power falls within each band (values between 0 and 1). This is more robust than absolute power for comparing between individuals or sessions, as it removes overall amplitude differences.

### Z-Score Computation

Z-scores express how much each channel deviates from a reference distribution. Two methods are available:

**Within-Subject Z-Scores** (default):
```
Z_i = (value_i - mean(all_channels)) / std(all_channels)
```
This highlights which brain regions differ from the subject's own average. It reveals the spatial distribution of activity: which areas are relatively more or less active. No normative database is needed.

**Approximate Normative Z-Scores**:
```
Z_i = (value_i - population_mean) / population_std
```
Compares each channel against published population means and standard deviations from the EEG normative literature (Thatcher et al., Johnstone et al.). This shows how the subject's EEG compares to a typical adult population. Note: these are approximate since we use aggregate published values rather than a comprehensive age/sex-stratified normative database.

Z-scores are clipped to the range [-2.5, +2.5] for topomap display.

### Topographic Mapping

Topographic maps (topomaps) display the spatial distribution of a measurement across the scalp. MNE-Python's `plot_topomap` function:

1. Takes the 19 Z-score values at their known electrode positions
2. Interpolates values across the head surface using spherical spline interpolation
3. Renders the result as a color-mapped 2D head image

The custom colormap ranges from dark navy blue (-2.5 Z) through cyan and white (0 Z) to red, orange, and yellow (+2.5 Z), matching the NeuroSynchrony clinical report style.

### Coherence

Coherence measures the linear relationship between two signals as a function of frequency, analogous to a frequency-domain correlation coefficient. Values range from 0 (no linear relationship) to 1 (perfect linear relationship).

Computed using `scipy.signal.coherence` for all 171 unique channel pairs (19 choose 2), then averaged within each frequency band. High coherence between two channels suggests functional connectivity or common input.

### Hemispheric Asymmetry

Asymmetry is computed for 8 homologous left-right electrode pairs (e.g., F3-F4, O1-O2) as:

```
Asymmetry = ln(P_right) - ln(P_left)
```

where P is absolute band power. The logarithmic transformation normalizes the distribution. Positive values indicate greater right-hemisphere power; negative values indicate greater left-hemisphere power.

Frontal alpha asymmetry (F3-F4, F7-F8) is particularly studied in clinical research as it relates to emotional regulation, approach/withdrawal motivation, and depression.

### Peak Frequency Detection

For each channel, two peak frequencies are identified:

- **Alpha Peak**: the frequency with maximum PSD in the alpha band (8-13 Hz). The individual alpha frequency (IAF) is a key marker that correlates with cognitive processing speed and declines with age.
- **Dominant Frequency**: the frequency with maximum PSD across the entire 1-25 Hz range.

---

## Project Structure

```
EEG Viewer/
    main.py                              # Python app entry point
    requirements.txt                     # Python dependencies
    README.md                            # This file

    eeg_viewer/                          # ── Python Desktop App ──
        __init__.py
        app.py                           # QApplication setup, matplotlib/pyqtgraph config
        data/
            __init__.py
            edf_loader.py                # EDF file I/O, preprocessing (re-ref, filter, montage)
            channel_map.py               # 10-20 channel regions, asymmetry pairs, display order
            signal_processor.py          # PSD, band power, coherence, filtering
            normative_db.py              # Z-score computation (within-subject & normative)
            qeeg_analyzer.py             # Full analysis pipeline orchestrator
        ui/
            __init__.py
            main_window.py               # Main window with tabs, menu bar, toolbar
            waveform_tab.py              # Multi-channel EEG waveform display
            waveform_controls.py         # Playback controls (play/pause/speed/scrubber)
            channel_selector.py          # Channel toggle checkboxes
            qeeg_tab.py                  # qEEG dashboard assembling all widgets
            spectra_widget.py            # Magnitude spectra plots (Frontal/Central/Posterior)
            topomap_widget.py            # Topographic head maps with Z-score coloring
            coherence_widget.py          # Coherence heatmap matrix
            asymmetry_widget.py          # Hemispheric asymmetry bar charts
            export_dialog.py             # CSV/PDF export dialog
        utils/
            __init__.py
            constants.py                 # Central configuration (bands, PSD params, display)
            pdf_report.py                # PDF report generation with embedded plots
        workers/
            __init__.py
            playback_worker.py           # QTimer-based waveform playback at 30 FPS
            analysis_worker.py           # QThread worker for background qEEG computation

    EEGViewer/                           # ── iPadOS App (Xcode project) ──
        EEGViewer.xcodeproj/             # Xcode project file
        EEGViewer/
            EEGViewerApp.swift           # @main App entry point
            Models/
                Constants.swift          # Frequency bands, electrode positions, region maps
                EDFData.swift            # EDF data model (signals, headers, metadata)
                EDFReader.swift          # Pure-Swift EDF parser (no dependencies)
                QEEGAnalyzer.swift       # Async analysis pipeline (FFT, PSD, coherence)
                SignalProcessor.swift    # DSP via Accelerate (Welch PSD, filtering, coherence)
            Views/
                ContentView.swift        # Tab navigation, file picker, data management
                WaveformView.swift       # Multi-channel EEG waveform display
                BandPowerView.swift      # Per-band filtered waveform traces
                QEEGDashboard.swift      # qEEG dashboard + multi-EDF comparison manager
                SpectraChartView.swift   # Regional magnitude spectra (Swift Charts)
                TopoMapView.swift        # Topographic Z-score head map
                CoherenceHeatmapView.swift  # Coherence heatmap (Canvas)
                AsymmetryChartView.swift # Hemispheric asymmetry bar chart (Swift Charts)
                BrainView3D.swift        # 3D brain visualization (SceneKit)
            Utilities/
                ColorMap.swift           # Clinical-style colormap (blue → white → red)
                TopoMapRenderer.swift    # CoreGraphics topomap renderer (interpolation + head outline)
                PDFExporter.swift        # PDF report generator (ImageRenderer + UIGraphicsPDFRenderer)
```

---

## Configuration

Key parameters can be adjusted in `eeg_viewer/utils/constants.py`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `PSD_NPERSEG` | 1024 | Welch FFT segment length (determines frequency resolution) |
| `PSD_NOVERLAP` | 512 | Segment overlap (50%) |
| `CHANNEL_SPACING_UV` | 50.0 | Vertical spacing between waveform traces in uV |
| `ZSCORE_VMIN/VMAX` | -2.5/+2.5 | Z-score range for topomap color scaling |
| `TARGET_FPS` | 30 | Playback animation frame rate |

### Frequency Band Definitions

| Band | Low (Hz) | High (Hz) |
|------|----------|-----------|
| Delta | 1.0 | 4.0 |
| Theta | 4.0 | 8.0 |
| Alpha | 8.0 | 13.0 |
| Beta | 13.0 | 25.0 |

---

## Supported EDF Files

The application reads standard `.edf` (European Data Format) and `.edf+` files. It expects:

- 19 EEG channels in the standard 10-20 system
- Optional ECG/EKG channel (automatically detected and excluded from EEG analysis)
- Sampling rate is detected automatically (tested with 500 Hz)

Channel names can use either old (T3/T4/T5/T6) or new (T7/T8/P7/P8) nomenclature, and may include device-specific prefixes (e.g., "EEG Fp1") which are automatically stripped.

Tested with recordings from the **Zeto WR-19** wireless EEG headset.

---

## Limitations and Caveats

- **Normative Z-scores are approximate**: The built-in normative values are derived from published aggregate literature, not from a comprehensive age/sex-stratified database. For clinical interpretation, a validated normative database (e.g., Thatcher NeuroGuide, BrainDx) should be used.
- **Automated artifact rejection only**: The application uses a fixed peak-to-peak amplitude threshold (100 µV) for artifact rejection. While effective for gross artifacts (movement, muscle bursts, electrode pops), it does not include more sophisticated methods like ICA-based eye artifact removal, spatial filtering, or manual epoch review. Clinical qEEG software may use additional artifact detection strategies.

- **Fixed impedance thresholds**: Impedance detection uses fixed thresholds for low-frequency noise floor and 1/f slope. Different populations (children, elderly, patients with pathology) may require tuning these parameters for optimal detection.
- **Limited comparison support**: The iPadOS app supports side-by-side comparison of up to 3 recordings. The Python desktop app analyzes one file at a time. Neither platform supports group-level statistical analysis or longitudinal treatment-response tracking.
- **No source localization**: Analysis is at the sensor (scalp electrode) level. Source localization methods like LORETA or sLORETA are not implemented.
- **Not a medical device**: This software is for educational and research purposes. It is not FDA-cleared and should not be used for clinical diagnosis.

---

## References

- Niedermeyer, E. & da Silva, F. L. (2004). *Electroencephalography: Basic Principles, Clinical Applications, and Related Fields*. Lippincott Williams & Wilkins.
- Thatcher, R. W. (2010). Validity and reliability of quantitative electroencephalography. *Journal of Neurotherapy*, 14(2), 122-152.
- Johnstone, J., Gunkelman, J., & Lunt, J. (2005). Clinical database development: characterization of EEG phenotypes. *Clinical EEG and Neuroscience*, 36(2), 99-107.
- Gramfort, A. et al. (2013). MEG and EEG data analysis with MNE-Python. *Frontiers in Neuroscience*, 7, 267.
- Welch, P. D. (1967). The use of fast Fourier transform for the estimation of power spectra. *IEEE Transactions on Audio and Electroacoustics*, 15(2), 70-73.

---

## License

This project is provided for educational and research purposes.
