# EEG Viewer

**Type:** Cross-platform EEG visualization & quantitative analysis app
**Status:** Active development
**Tech Stack:** Python (PyQt5, MNE, scipy, matplotlib) + Swift/SwiftUI (Accelerate/vDSP, SceneKit, Swift Charts). Zero external dependencies on Swift side.

## Goal

EEG Viewer loads standard `.edf` EEG recordings and performs clinical-style quantitative EEG (qEEG) analysis — magnitude spectra, topographic Z-score maps, coherence matrices, hemispheric asymmetry, peak frequency detection, and heart-brain coherence. It exists as two parallel implementations: a **Python desktop app** (macOS/Linux/Windows) and a **native iPadOS/Mac Catalyst app** (Swift). Both produce equivalent analysis with near-complete feature parity — configurable notch filtering, bad channel management, waveform annotations, HRV/heart-brain coherence, and multi-EDF comparison. The Swift app has a few additional features: Apple Pencil annotation, 3D brain visualization (SceneKit), and artifact rejection overlay. Used for clinical EEG review and research.

## Architecture

### Python Desktop App (`eeg_viewer/`)

```
main.py → eeg_viewer/app.py (PyQt5 setup)
  └─ ui/main_window.py (7-tab interface, toolbar with notch filter)
       ├─ ui/waveform_tab.py + waveform_controls.py (playback, scrolling, annotations)
       ├─ ui/band_view_tab.py (per-band waveforms)
       ├─ ui/qeeg_tab.py (spectra, topomaps, coherence, asymmetry)
       ├─ ui/connectivity_tab.py + advanced_analysis_tab.py (brain connectivity, advanced)
       ├─ ui/heart_tab.py (ECG, HRV metrics, Poincare, heart-brain coherence)
       ├─ ui/comparison_tab.py (multi-EDF comparison, up to 3 recordings)
       ├─ ui/bad_channel_dialog.py (channel management with auto-detection)
       ├─ ui/annotation_label_editor.py (label types, colors, analysis modes)
       └─ ui/export_dialog.py (PDF/CSV)

Data pipeline: data/edf_loader.py (MNE) → data/signal_processor.py (scipy) → data/qeeg_analyzer.py
Heart: data/hrv_analyzer.py (Pan-Tompkins R-peak detection, HRV metrics, multi-band coherence)
Annotations: data/annotation_store.py (JSON sidecar persistence, interoperable with Swift app)
Normative Z-scores: data/normative_db.py
Constants: utils/constants.py (bands, PSD params, display settings, HRV params)
PDF: utils/pdf_report.py (reportlab)
Background: workers/analysis_worker.py, workers/playback_worker.py (QThread)
```

### Swift iPadOS/Mac App (`EEGViewer/`)

```
EEGViewerApp.swift → ContentView.swift (tab navigation)
  ├─ WaveformView.swift (multi-channel display, annotations, Apple Pencil)
  ├─ BandPowerView.swift (per-band waveforms + spectrogram)
  ├─ QEEGDashboard.swift (spectra, topomaps, coherence, asymmetry, peak freq)
  ├─ BrainView3D.swift (SceneKit 3D brain model)
  └─ HeartDashboard.swift → HRVChartsView.swift (ECG, HRV, heart-brain coherence)

Data pipeline: EDFReader.swift (pure-Swift parser) → EDFData.swift (model)
DSP: SignalProcessor.swift (Accelerate/vDSP — bandpass, Welch PSD, coherence, notch, envelope)
Analysis: QEEGAnalyzer.swift (async, epoch-based artifact rejection, bad channel interpolation)
Heart: HRVAnalyzer.swift (Pan-Tompkins R-peak detection, HRV metrics, multi-band coherence)
Annotations: EEGAnnotation.swift (AnnotationStore, JSON sidecar persistence)
Constants: Constants.swift (bands, electrode positions, PSD params, HRV params, z-score ranges)
Rendering: TopoMapRenderer.swift (CoreGraphics), ColorMap.swift, PDFExporter.swift
```

### Key Data Flow (Swift)

1. User picks `.edf` → `EDFReader` parses → `EDFData` struct (channels, signals, metadata)
2. `ContentView` holds `@State edfData`, passes to tab views
3. Analysis tabs call `SignalProcessor` (stateless DSP functions) and `QEEGAnalyzer`/`HRVAnalyzer` (async pipelines)
4. Annotations stored in `AnnotationStore` (ObservableObject), persisted as `.annotations.json` sidecar next to EDF
5. Bad channels interpolated via inverse-distance-squared weighting before average referencing

### Shared Concepts (Both Platforms)

- **19 standard 10-20 EEG channels** (Fp1, Fp2, F7, F3, Fz, F4, F8, T7, C3, Cz, C4, T8, P7, P3, Pz, P4, P8, O1, O2)
- **Frequency bands**: Delta (1–4 Hz), Theta (4–8), Alpha (8–13), Beta (13–25)
- **Welch PSD**: nperseg=1024, noverlap=512, Hann window
- **Artifact rejection**: 100 µV peak-to-peak threshold on 2-second epochs
- **Z-scores**: within-subject (default) and approximate normative

## Getting Started

### Python Desktop App

```bash
cd "EEG Viewer"
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
python main.py
```

### Swift App

1. Open `EEGViewer/EEGViewer.xcodeproj` in Xcode
2. Select build target:
   - **iPad**: select your connected iPad device
   - **Mac**: select **"My Mac (Mac Catalyst)"** — NOT native macOS (UIKit APIs won't compile for AppKit)
3. Build and run (⌘R)

**Build from CLI:**
```bash
# Mac Catalyst
cd "EEG Viewer/EEGViewer"
xcodebuild -scheme EEGViewer -destination 'platform=macOS,variant=Mac Catalyst' build

# iPad (find device ID with: xcrun devicectl list devices)
xcodebuild -scheme EEGViewer -sdk iphoneos -destination 'id=<DEVICE_ID>' build
```

**Gotchas:**
- Always build as **Mac Catalyst**, not native macOS — PDFExporter uses UIKit APIs
- The Xcode project is at `EEGViewer/EEGViewer.xcodeproj` (not the repo root)
- Security-scoped URL access is needed for iPad file picker — annotations copy sidecar files during document picker callback while scope is active
- `vDSP_create_fftsetup` requires power-of-two segment lengths

## Current State

**Working (both platforms unless noted):**
- Full qEEG analysis pipeline (spectra, topomaps, coherence, asymmetry)
- Configurable notch filter (50/55/60/65 Hz, auto-detect from EDF metadata)
- Bad channel management: manual selection + auto-detection with visual [BAD] badges, MNE spatial interpolation (Python) / inverse-distance weighting (Swift)
- Waveform annotations: Shift+drag creation, right-click edit/delete, JSON sidecar persistence, annotation import (Python); Apple Pencil/finger/mouse/trackpad + edge resizing (Swift)
- Artifact rejection overlay: toggle shows rejected epochs as red regions with stats (X/Y (Z%) @NuV)
- Progressive artifact threshold relaxation: 100->150->200->300->500 uV with min 30 clean epochs
- Heart rate analysis: Pan-Tompkins R-peak detection, HRV time/frequency domain, Poincare, multi-band heart-brain coherence; arc gauges with normal ranges (Python), gauge cards (Swift)
- Multi-EDF comparison (up to 3 recordings side-by-side)
- Window size options include Half/All based on recording duration
- Band power spectrogram (GFP time-frequency, scipy STFT with Hann window)
- 3D brain visualization with SceneKit (Swift only)
- Longitudinal analysis pipeline: Python modules for tracking qEEG changes across treatment courses
- PDF export
- Mac Catalyst support (Swift)

**No automated tests** — verification is manual (build + run on device). No CI/CD pipeline.

## Key Conventions

### Swift App

- **Zero external dependencies** — all DSP uses Apple's Accelerate framework (`vDSP`). No SPM packages.
- **`nonisolated private static func`** for heavy computation methods (runs off main actor via `Task.detached`)
- **Thread safety**: Use `withUnsafeMutableBufferPointer` for `DispatchQueue.concurrentPerform` array writes. Use serial `DispatchQueue` for shared static caches.
- **Annotations persist as `.annotations.json`** sidecar files next to the EDF. Fallback to App Support on iPad if sandbox prevents sidecar writing.
- **`edfData.eegChannelNames`** (not `channelNames`) when indexing into `edfData.eegData` — `eegData` excludes ECG, `channelNames` includes it.
- **Notch filter**: zero-phase IIR biquad, bandwidth normalized by Nyquist (`bw = π × bandwidth/nyquist`), not sample rate.
- **Constants.swift** is the single source of truth for frequency bands, electrode positions, PSD parameters, artifact thresholds, and HRV settings.
- **Backward compatibility**: When expanding data models (like `HRVResults`), add computed property aliases for old field names.
- **Artifact overlay**: Uses avg-ref-only (no highpass) for the visual overlay because the IIR biquad highpass produces different peak-to-peak than MNE's FIR filter. `getArtifactMask()` has progressive threshold relaxation matching `rejectArtifacts()`.

### Python App

- **MNE-Python** handles EDF I/O, montage setup, topographic map rendering, and bad channel interpolation (`raw.interpolate_bads()`)
- **scipy.signal** for Welch PSD, coherence, bandpass/notch filtering (`iirnotch` + `filtfilt`)
- **QThread workers** for background analysis (qEEG, HRV, comparison slots) and playback animation
- **Bad channel interpolation** operates on `raw.copy()` to avoid mutating the shared `loader.raw`
- **Annotation store** uses the same JSON sidecar format (`.annotations.json`) as the Swift app for cross-platform interoperability
- **7 tabs**: EEG Waveform, Band Waveforms, qEEG Analysis, Brain Connectivity, Advanced Analysis, Heart, Compare

### Both Platforms

- Channel names auto-converted: T3→T7, T4→T8, T5→P7, T6→P8 (old→new 10-20 nomenclature)
- Device prefixes stripped (e.g., "EEG Fp1" → "Fp1")
- Commits follow conventional commits (`feat:`, `fix:`, `docs:`)
- PRs get code review before merge; branch protection may be enabled on main

### Git Workflow

- Feature branches: `feat/<feature-name>`
- Always create new commits (never amend unless explicitly asked)
- Code review → fix bugs → update README → merge → pull to main

## Notes

<!-- Add strategic context, future plans, or important history here.
     This section is for manual additions — don't overwrite it. -->

### Longitudinal Analysis Tool

The `longitudinal/` directory contains a separate Jupyter notebook-based tool for longitudinal eTMS (Transcranial Magnetic Stimulation) analysis. It's independent of the main EEG Viewer apps. See `longitudinal/longitudinal.ipynb`.

### Implementation Plans

Detailed plans live in `docs/superpowers/plans/` and `docs/plans/`:
- `2026-03-16-waveform-annotations.md` — 11-task plan for annotation system (completed)
- `2026-03-17-heart-brain-coherence-improvements.md` — Multi-band coherence plan (completed)
- `2026-03-20-python-feature-parity.md` — Python app feature parity plan: notch filter, bad channels, HRV, annotations, comparison (completed)

### Hardware Tested

- **Zeto WR-19** wireless EEG headset (19 channels + ECG, 500 Hz)
- **iPad Pro 11-inch** (iPad8,1) for iPadOS builds
- **Apple Silicon Mac** for Mac Catalyst builds

---

*Updated 2026-03-26*
