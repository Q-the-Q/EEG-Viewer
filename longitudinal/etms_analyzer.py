"""Longitudinal eTMS analysis module.

Runs the existing qEEG pipeline on all session files and collects results
into structured DataFrames for longitudinal visualization.
"""

import os
import sys
import pickle
import time

import numpy as np
import pandas as pd
from scipy import stats

# Add project root to path so we can import eeg_viewer modules
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)

from eeg_viewer.data.edf_loader import EDFLoader
from eeg_viewer.data.signal_processor import SignalProcessor
from eeg_viewer.data.qeeg_analyzer import QEEGAnalyzer
from eeg_viewer.data.normative_db import NormativeDB
from eeg_viewer.data.channel_map import (
    STANDARD_1020_CHANNELS, REGION_MAP, ASYMMETRY_PAIRS,
)
from eeg_viewer.utils.constants import FREQ_BANDS

CACHE_FILE = os.path.join(os.path.dirname(__file__), ".analysis_cache.pkl")


def analyze_session(filepath, skip_coherence=False):
    """Run the full qEEG pipeline on a single EDF file.

    Args:
        filepath: Path to an EDF file.
        skip_coherence: If True, skip coherence computation (much faster).

    Returns:
        Dictionary containing all computed metrics for the session.
    """
    loader = EDFLoader()
    loader.load(filepath)

    processor = SignalProcessor(loader.sfreq)
    normative = NormativeDB(method="within")
    analyzer = QEEGAnalyzer(loader, processor, normative)

    # Run the pipeline (but we may want to skip coherence)
    analyzer._detect_channel_quality()
    analyzer._apply_channel_filtering()
    analyzer._reject_artifacts()
    analyzer._compute_psd()
    analyzer._compute_band_powers()
    analyzer._compute_zscores()

    if not skip_coherence:
        analyzer._compute_coherence()

    analyzer._compute_asymmetry()
    analyzer._compute_peak_frequencies()

    eeg_channels = analyzer.eeg_channels

    # Extract results into a flat dictionary
    result = {
        "eeg_channels": eeg_channels,
        "sfreq": loader.sfreq,
        "duration": loader.duration,
        "artifact_stats": analyzer.artifact_stats,
        "channel_quality": analyzer.channel_quality,
    }

    # Per-channel band powers
    for band in FREQ_BANDS:
        for i, ch in enumerate(eeg_channels):
            result[f"abs_{band}_{ch}"] = float(analyzer.band_powers[band][i])
            result[f"rel_{band}_{ch}"] = float(analyzer.relative_powers[band][i])
            result[f"zscore_{band}_{ch}"] = float(analyzer.zscores[band][i])

    # Per-channel peak frequencies
    for ch in eeg_channels:
        pf = analyzer.peak_freqs.get(ch, {})
        result[f"alpha_peak_{ch}"] = pf.get("alpha_peak", 0.0)
        result[f"dominant_freq_{ch}"] = pf.get("dominant", 0.0)

    # Per-region aggregates
    for region, channels in REGION_MAP.items():
        region_indices = [
            eeg_channels.index(ch) for ch in channels if ch in eeg_channels
        ]
        if not region_indices:
            continue

        for band in FREQ_BANDS:
            # Mean relative power across channels in this region
            region_rel = np.mean([
                analyzer.relative_powers[band][i] for i in region_indices
            ])
            result[f"rel_{band}_{region}"] = float(region_rel)

            # Mean absolute power across channels in this region
            region_abs = np.mean([
                analyzer.band_powers[band][i] for i in region_indices
            ])
            result[f"abs_{band}_{region}"] = float(region_abs)

        # Theta/Beta ratio for the region
        theta_indices = [analyzer.relative_powers["Theta"][i] for i in region_indices]
        beta_indices = [analyzer.relative_powers["Beta"][i] for i in region_indices]
        mean_theta = np.mean(theta_indices)
        mean_beta = np.mean(beta_indices)
        result[f"theta_beta_ratio_{region}"] = (
            float(mean_theta / mean_beta) if mean_beta > 1e-10 else 0.0
        )

    # Asymmetry
    for band in FREQ_BANDS:
        for pair, value in analyzer.asymmetry[band]:
            left, right = pair
            result[f"asym_{band}_{left}_{right}"] = float(value)

    # Coherence matrices (stored separately since they're 2D)
    coherence_matrices = {}
    if not skip_coherence and analyzer.coherence:
        for band in FREQ_BANDS:
            if band in analyzer.coherence:
                coherence_matrices[band] = analyzer.coherence[band].copy()

        # Mean regional coherence
        for region, channels in REGION_MAP.items():
            region_indices = [
                eeg_channels.index(ch) for ch in channels if ch in eeg_channels
            ]
            for band in FREQ_BANDS:
                if band in analyzer.coherence:
                    matrix = analyzer.coherence[band]
                    # Mean within-region coherence (excluding diagonal)
                    coh_vals = []
                    for ii in range(len(region_indices)):
                        for jj in range(ii + 1, len(region_indices)):
                            coh_vals.append(matrix[region_indices[ii], region_indices[jj]])
                    result[f"mean_coh_{band}_{region}"] = (
                        float(np.mean(coh_vals)) if coh_vals else 0.0
                    )

    result["_coherence_matrices"] = coherence_matrices

    return result


def analyze_all_sessions(session_df, skip_coherence=False, progress_callback=None,
                         use_cache=True):
    """Analyze all sessions and return results keyed by (day, condition).

    Args:
        session_df: DataFrame from file_scanner.scan_sessions().
        skip_coherence: If True, skip coherence for faster iteration.
        progress_callback: Optional callable(current, total, filepath, elapsed).
        use_cache: If True, load/save results from/to a pickle cache.

    Returns:
        Dictionary mapping (day, condition) -> result dict from analyze_session().
    """
    results = {}
    cache = _load_cache() if use_cache else {}

    total = len(session_df)
    start_time = time.time()

    for seq, (idx, row) in enumerate(session_df.iterrows()):
        day = row["day"]
        condition = row["condition"]
        filepath = row["filepath"]

        # Check cache (keyed by filepath + modification time)
        cache_key = _cache_key(filepath, skip_coherence)
        if cache_key in cache:
            results[(day, condition)] = cache[cache_key]
            if progress_callback:
                elapsed = time.time() - start_time
                progress_callback(seq + 1, total, filepath, elapsed, cached=True)
            continue

        # Analyze
        if progress_callback:
            elapsed = time.time() - start_time
            progress_callback(seq + 1, total, filepath, elapsed, cached=False)

        result = analyze_session(filepath, skip_coherence=skip_coherence)
        results[(day, condition)] = result

        # Update cache
        cache[cache_key] = result

    if use_cache:
        _save_cache(cache)

    return results


def build_results_dataframe(results, session_df):
    """Build a structured DataFrame from analysis results.

    Args:
        results: Dict from analyze_all_sessions().
        session_df: Original session DataFrame.

    Returns:
        Tuple of (metrics_df, coherence_store).
        metrics_df: DataFrame with index (patient_id, day, condition) and columns for all scalar metrics.
        coherence_store: Dict mapping (day, condition, band) -> 19x19 numpy array.
    """
    rows = []
    coherence_store = {}

    for _, session_row in session_df.iterrows():
        day = session_row["day"]
        condition = session_row["condition"]
        patient_id = session_row["patient_id"]
        key = (day, condition)

        if key not in results:
            continue

        result = results[key]

        # Extract scalar metrics (skip internal keys)
        row = {"patient_id": patient_id, "day": day, "condition": condition}
        for k, v in result.items():
            if k.startswith("_") or k in ("eeg_channels", "channel_quality", "artifact_stats"):
                continue
            if isinstance(v, (int, float, np.floating, np.integer)):
                row[k] = float(v)

        rows.append(row)

        # Store coherence matrices separately
        coh_matrices = result.get("_coherence_matrices", {})
        for band, matrix in coh_matrices.items():
            coherence_store[(day, condition, band)] = matrix

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.set_index(["patient_id", "day", "condition"])
        # Sort the index
        df = df.sort_index()

    return df, coherence_store


def compute_longitudinal_features(metrics_df):
    """Compute derived longitudinal features from the metrics DataFrame.

    Args:
        metrics_df: DataFrame from build_results_dataframe().

    Returns:
        Dictionary with three DataFrames:
        - baseline_delta: Each session minus day 0 baseline values.
        - session_delta: Post minus pre for each day.
        - trend_slopes: Linear regression of pre-treatment baselines over days.
    """
    # Get numeric columns only
    numeric_cols = metrics_df.select_dtypes(include=[np.number]).columns.tolist()

    # --- Baseline delta ---
    # Find the baseline row (day 0)
    baseline_rows = metrics_df.xs("baseline", level="condition", drop_level=False)
    if baseline_rows.empty:
        # Try day 0 pre if no baseline condition
        try:
            baseline_rows = metrics_df.xs(0, level="day", drop_level=False)
        except KeyError:
            baseline_rows = pd.DataFrame()

    if not baseline_rows.empty:
        baseline_values = baseline_rows[numeric_cols].iloc[0]
        baseline_delta = metrics_df[numeric_cols].subtract(baseline_values, axis=1)
    else:
        baseline_delta = pd.DataFrame()

    # --- Session delta (post - pre) ---
    session_delta_rows = []

    # Get unique (patient_id, day) combinations
    if not metrics_df.empty:
        idx = metrics_df.index.droplevel("condition").unique()
        for patient_id, day in idx:
            try:
                pre_row = metrics_df.loc[(patient_id, day, "pre"), numeric_cols]
            except KeyError:
                # Try baseline for day 0
                try:
                    pre_row = metrics_df.loc[(patient_id, day, "baseline"), numeric_cols]
                except KeyError:
                    continue
            try:
                post_row = metrics_df.loc[(patient_id, day, "post"), numeric_cols]
            except KeyError:
                continue

            delta = post_row - pre_row
            delta_dict = delta.to_dict()
            delta_dict["patient_id"] = patient_id
            delta_dict["day"] = day
            session_delta_rows.append(delta_dict)

    session_delta = pd.DataFrame(session_delta_rows)
    if not session_delta.empty:
        session_delta = session_delta.set_index(["patient_id", "day"]).sort_index()

    # --- Trend slopes (linear regression on pre-treatment baselines) ---
    trend_rows = []

    # Get pre-treatment (and baseline) rows only
    pre_mask = metrics_df.index.get_level_values("condition").isin(["pre", "baseline"])
    pre_df = metrics_df[pre_mask].copy()

    if len(pre_df) >= 3:  # Need at least 3 points for meaningful regression
        days = pre_df.index.get_level_values("day").astype(float).values

        for col in numeric_cols:
            values = pre_df[col].values
            valid = ~np.isnan(values)
            if valid.sum() >= 3:
                slope, intercept, r_value, p_value, std_err = stats.linregress(
                    days[valid], values[valid]
                )
                trend_rows.append({
                    "metric": col,
                    "slope": slope,
                    "intercept": intercept,
                    "r_squared": r_value ** 2,
                    "p_value": p_value,
                    "std_err": std_err,
                    "n_points": int(valid.sum()),
                })

    trend_slopes = pd.DataFrame(trend_rows)
    if not trend_slopes.empty:
        trend_slopes = trend_slopes.set_index("metric")

    return {
        "baseline_delta": baseline_delta,
        "session_delta": session_delta,
        "trend_slopes": trend_slopes,
    }


# --- Cache utilities ---

def _cache_key(filepath, skip_coherence):
    """Generate a cache key from filepath and its modification time."""
    try:
        mtime = os.path.getmtime(filepath)
    except OSError:
        mtime = 0
    return (filepath, mtime, skip_coherence)


def _load_cache():
    """Load the analysis cache from disk."""
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "rb") as f:
                return pickle.load(f)
        except (pickle.UnpicklingError, EOFError, OSError):
            return {}
    return {}


def _save_cache(cache):
    """Save the analysis cache to disk."""
    try:
        with open(CACHE_FILE, "wb") as f:
            pickle.dump(cache, f)
    except OSError as e:
        print(f"Warning: Could not save cache: {e}")


def clear_cache():
    """Delete the analysis cache file."""
    if os.path.exists(CACHE_FILE):
        os.remove(CACHE_FILE)
        print("Cache cleared.")
    else:
        print("No cache file found.")
