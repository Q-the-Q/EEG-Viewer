"""Scan the Scans/ directory for EDF session files and parse them into a structured session table.

Parses filenames like 'day 0 pre', 'day 7 post.edf', 'day 6.edf' into
(day, condition, filepath) rows for longitudinal analysis.
"""

import os
import re
import pandas as pd

# Regex to match 'day N', 'day N pre', 'day N post' with optional .edf extension
SESSION_PATTERN = re.compile(
    r"^day\s+(\d+)\s*(pre|post)?(?:\.edf)?$", re.IGNORECASE
)


def scan_sessions(scans_dir, patient_id="default"):
    """Discover and parse all EDF session files from a Scans directory.

    Args:
        scans_dir: Path to the directory containing EDF files.
        patient_id: Identifier for the patient (for future multi-patient support).

    Returns:
        DataFrame with columns: day (int), condition (str), filepath (str), patient_id (str).
        Sorted by (day, condition) where condition ordering is baseline < pre < post.
    """
    rows = []
    skipped = []

    for entry in os.listdir(scans_dir):
        full_path = os.path.join(scans_dir, entry)

        # Skip directories and hidden files
        if os.path.isdir(full_path) or entry.startswith("."):
            continue

        match = SESSION_PATTERN.match(entry)
        if not match:
            skipped.append(entry)
            continue

        day = int(match.group(1))
        suffix = match.group(2)

        if suffix:
            condition = suffix.lower()  # 'pre' or 'post'
        elif day == 0:
            condition = "baseline"
        else:
            condition = "pre"  # Unlabeled files (e.g., 'day 6.edf') treated as pre

        # Day 0 is always baseline regardless of suffix
        if day == 0:
            condition = "baseline"

        rows.append({
            "day": day,
            "condition": condition,
            "filepath": full_path,
            "patient_id": patient_id,
        })

    df = pd.DataFrame(rows, columns=["day", "condition", "filepath", "patient_id"])

    # Sort: by day, then condition (baseline < pre < post)
    condition_order = {"baseline": 0, "pre": 1, "post": 2}
    df["_sort"] = df["condition"].map(condition_order)
    df = df.sort_values(["day", "_sort"]).drop(columns="_sort").reset_index(drop=True)

    # Store skipped files as metadata
    df.attrs["skipped_files"] = skipped

    return df


def validate_sessions(df):
    """Validate the session table and return a summary.

    Args:
        df: DataFrame from scan_sessions().

    Returns:
        Dictionary with validation summary:
            - total_files: Total number of session files found
            - days_found: Sorted list of unique day numbers
            - complete_pairs: Days with both pre and post recordings
            - pre_only: Days with only pre (no post)
            - post_only: Days with only post (no pre)
            - has_baseline: Whether day 0 baseline exists
            - skipped_files: Files that did not match the naming pattern
    """
    days = sorted(df["day"].unique())
    has_baseline = 0 in days

    complete_pairs = []
    pre_only = []
    post_only = []

    for day in days:
        if day == 0:
            continue  # Baseline is special
        day_df = df[df["day"] == day]
        conditions = set(day_df["condition"])
        has_pre = "pre" in conditions
        has_post = "post" in conditions
        if has_pre and has_post:
            complete_pairs.append(day)
        elif has_pre:
            pre_only.append(day)
        elif has_post:
            post_only.append(day)

    return {
        "total_files": len(df),
        "days_found": days,
        "complete_pairs": complete_pairs,
        "pre_only": pre_only,
        "post_only": post_only,
        "has_baseline": has_baseline,
        "skipped_files": df.attrs.get("skipped_files", []),
    }


def get_baseline(df):
    """Return the row for the day 0 baseline recording.

    Args:
        df: DataFrame from scan_sessions().

    Returns:
        Series for the baseline row.

    Raises:
        ValueError: If no day 0 baseline exists.
    """
    baseline = df[(df["day"] == 0) & (df["condition"] == "baseline")]
    if baseline.empty:
        raise ValueError("No day 0 baseline recording found in the session table.")
    return baseline.iloc[0]


def print_session_summary(df):
    """Print a formatted summary of the session table."""
    summary = validate_sessions(df)

    print(f"Total EDF files: {summary['total_files']}")
    print(f"Days found: {summary['days_found']}")
    print(f"Baseline (day 0): {'Yes' if summary['has_baseline'] else 'MISSING'}")
    print(f"Complete pre/post pairs: {summary['complete_pairs']}")
    if summary["pre_only"]:
        print(f"Pre-only (no post): {summary['pre_only']}")
    if summary["post_only"]:
        print(f"Post-only (no pre): {summary['post_only']}")
    if summary["skipped_files"]:
        print(f"Skipped files: {summary['skipped_files']}")

    # Show the full table
    print("\nSession table:")
    print(df[["day", "condition", "filepath"]].to_string(index=False))


if __name__ == "__main__":
    # Quick test against the real Scans directory
    scans_dir = os.path.join(os.path.dirname(__file__), "..", "Scans")
    scans_dir = os.path.abspath(scans_dir)

    if os.path.isdir(scans_dir):
        df = scan_sessions(scans_dir)
        print_session_summary(df)
    else:
        print(f"Scans directory not found: {scans_dir}")
