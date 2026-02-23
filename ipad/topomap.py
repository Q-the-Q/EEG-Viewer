"""Custom topographic map renderer using only numpy, scipy, matplotlib.

Replaces MNE's plot_topomap() for iPad compatibility. Uses scipy's
CloughTocher2DInterpolator for smooth interpolation and matplotlib
for rendering — the same approach MNE uses internally.
"""

import numpy as np
from scipy.interpolate import CloughTocher2DInterpolator
from matplotlib.colors import LinearSegmentedColormap
from matplotlib.patches import Circle
import matplotlib.pyplot as plt


# Standard 10-20 electrode positions (x, y) extracted from MNE's standard_1020 montage.
# These are 3D positions projected onto 2D using x, y coordinates (azimuthal projection).
ELECTRODE_POS_2D = {
    "Fp1": (-0.029437, 0.083917),
    "Fp2": (0.029872, 0.084896),
    "F7":  (-0.070263, 0.042474),
    "F3":  (-0.050244, 0.053111),
    "Fz":  (0.000312, 0.058512),
    "F4":  (0.051836, 0.054305),
    "F8":  (0.073043, 0.044422),
    "T7":  (-0.084161, -0.016019),
    "C3":  (-0.065358, -0.011632),
    "Cz":  (0.000401, -0.009167),
    "C4":  (0.067118, -0.010900),
    "T8":  (0.085080, -0.015020),
    "P7":  (-0.072434, -0.073453),
    "P3":  (-0.053007, -0.078788),
    "Pz":  (0.000325, -0.081115),
    "P4":  (0.055667, -0.078560),
    "P8":  (0.073056, -0.073068),
    "O1":  (-0.029413, -0.112449),
    "O2":  (0.029843, -0.112156),
}

# NeuroSynchrony colormap: cyan -> blue -> dark blue -> BLACK -> magenta -> red -> yellow
ZSCORE_CMAP = LinearSegmentedColormap.from_list(
    "neurosynchrony",
    [
        (0.00, "#00FFFF"),   # -2.5Z: cyan
        (0.10, "#00CCEE"),
        (0.20, "#0099DD"),
        (0.30, "#0066CC"),
        (0.40, "#003399"),
        (0.48, "#0A0A40"),
        (0.50, "#000000"),   # 0Z: black
        (0.52, "#400A20"),
        (0.60, "#990033"),
        (0.70, "#CC0055"),
        (0.80, "#FF0000"),
        (0.90, "#FF8800"),
        (1.00, "#FFFF00"),   # +2.5Z: yellow
    ],
    N=256,
)


def get_channel_positions(channel_names):
    """Return (x, y) position arrays for the given channel names.

    Args:
        channel_names: List of channel name strings.

    Returns:
        np.ndarray of shape (n_channels, 2) with x, y positions.
    """
    positions = []
    for ch in channel_names:
        if ch in ELECTRODE_POS_2D:
            positions.append(ELECTRODE_POS_2D[ch])
        else:
            raise KeyError(f"Unknown electrode: {ch}")
    return np.array(positions)


def plot_topomap(data, channel_names, ax=None, cmap=None, vmin=-2.5, vmax=2.5,
                 resolution=100, show_head=True, show_sensors=False, contours=0):
    """Plot a topographic map of scalp data.

    Args:
        data: 1D array of values (one per channel), e.g. Z-scores.
        channel_names: List of channel names matching data order.
        ax: Matplotlib axes to plot on. Created if None.
        cmap: Colormap (default: NeuroSynchrony).
        vmin, vmax: Color scale limits.
        resolution: Grid resolution for interpolation.
        show_head: Draw head outline, nose, ears.
        show_sensors: Draw electrode dots.
        contours: Number of contour lines (0 = none).

    Returns:
        (im, ax) tuple — the image object and axes.
    """
    if cmap is None:
        cmap = ZSCORE_CMAP
    if ax is None:
        fig, ax = plt.subplots(1, 1, figsize=(4, 4))

    pos = get_channel_positions(channel_names)
    x, y = pos[:, 0], pos[:, 1]

    # Determine head radius from electrode positions
    center_x = np.mean(x)
    center_y = np.mean(y)
    max_dist = np.max(np.sqrt((x - center_x)**2 + (y - center_y)**2))
    head_radius = max_dist * 1.15  # Slightly larger than outermost electrode

    # Create interpolation grid
    grid_x = np.linspace(center_x - head_radius, center_x + head_radius, resolution)
    grid_y = np.linspace(center_y - head_radius, center_y + head_radius, resolution)
    grid_xx, grid_yy = np.meshgrid(grid_x, grid_y)

    # Interpolate using Clough-Tocher (same as MNE's default 'cubic')
    interpolator = CloughTocher2DInterpolator(pos, data)
    grid_data = interpolator(grid_xx, grid_yy)

    # Mask outside the head circle
    dist_from_center = np.sqrt((grid_xx - center_x)**2 + (grid_yy - center_y)**2)
    mask = dist_from_center > head_radius
    grid_data[mask] = np.nan

    # Plot interpolated data
    im = ax.imshow(
        grid_data,
        extent=[grid_x[0], grid_x[-1], grid_y[0], grid_y[-1]],
        origin="lower",
        cmap=cmap,
        vmin=vmin,
        vmax=vmax,
        interpolation="bilinear",
        aspect="equal",
    )

    # Contour lines
    if contours > 0:
        ax.contour(
            grid_xx, grid_yy, grid_data,
            levels=contours, colors="gray", linewidths=0.5, alpha=0.5,
        )

    # Draw head outline
    if show_head:
        _draw_head(ax, center_x, center_y, head_radius)

    # Draw sensor dots
    if show_sensors:
        ax.scatter(x, y, c="black", s=8, zorder=5)

    ax.set_xlim(center_x - head_radius * 1.3, center_x + head_radius * 1.3)
    ax.set_ylim(center_y - head_radius * 1.3, center_y + head_radius * 1.3)
    ax.set_aspect("equal")
    ax.axis("off")

    return im, ax


def _draw_head(ax, cx, cy, radius):
    """Draw a stylized head outline (circle + nose + ears)."""
    # Head circle
    head = Circle((cx, cy), radius, fill=False, edgecolor="black", linewidth=1.5)
    ax.add_patch(head)

    # Nose (triangle at top)
    nose_len = radius * 0.12
    nose_width = radius * 0.12
    nose_x = [cx - nose_width, cx, cx + nose_width]
    nose_y = [cy + radius, cy + radius + nose_len, cy + radius]
    ax.plot(nose_x, nose_y, color="black", linewidth=1.5)

    # Left ear
    ear_x = cx - radius
    ear_y = cy
    ear_w = radius * 0.06
    ear_h = radius * 0.15
    ax.plot(
        [ear_x, ear_x - ear_w, ear_x - ear_w, ear_x],
        [ear_y + ear_h, ear_y + ear_h * 0.5, ear_y - ear_h * 0.5, ear_y - ear_h],
        color="black", linewidth=1.5,
    )

    # Right ear
    ear_x = cx + radius
    ax.plot(
        [ear_x, ear_x + ear_w, ear_x + ear_w, ear_x],
        [ear_y + ear_h, ear_y + ear_h * 0.5, ear_y - ear_h * 0.5, ear_y - ear_h],
        color="black", linewidth=1.5,
    )
