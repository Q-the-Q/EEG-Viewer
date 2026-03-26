"""Tab 1: Multi-channel EEG waveform viewer with playback and static modes."""

import numpy as np
import pyqtgraph as pg
from PyQt5.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QSplitter, QPushButton,
    QButtonGroup, QMenu, QDialog,
)
from PyQt5.QtCore import Qt

from .channel_selector import ChannelSelector
from .waveform_controls import WaveformControls
from ..workers.playback_worker import PlaybackWorker
from ..data.channel_map import DISPLAY_ORDER
from ..utils.constants import (
    CHANNEL_SPACING_UV, DEFAULT_AMPLITUDE_SCALE, DEFAULT_WINDOW_SEC,
    TRACE_COLOR, GRID_ALPHA,
)

# ECG signals are typically 1-3 mV, while re-referenced EEG is ~10 uV.
# This scale factor compresses the ECG trace so it fits in one channel slot.
_ECG_SCALE_FACTOR = 0.05  # 5% of normal scaling — keeps ECG within its lane


class WaveformTab(QWidget):
    """Multi-channel EEG waveform display with playback controls."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._loader = None
        self._plot_items = {}
        self._visible_channels = []
        self._amplitude_scale = DEFAULT_AMPLITUDE_SCALE
        self._time_window = DEFAULT_WINDOW_SEC
        self._current_time = 0.0
        self._mode = "static"
        self._channel_spacing = CHANNEL_SPACING_UV

        self.annotation_store = None
        self._annotation_regions = []
        self._selected_label_idx = 0
        self._drag_start = None
        self._drag_region = None

        self._init_ui()
        self._init_playback()

    def _init_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Label bar for annotations (populated when annotation store is set)
        self._label_bar_layout = QHBoxLayout()
        self._label_buttons = QButtonGroup()
        self._label_buttons.setExclusive(True)
        layout.addLayout(self._label_bar_layout)

        # Top area: channel selector + plot
        splitter = QSplitter(Qt.Horizontal)

        # Channel selector (left)
        self._channel_selector = ChannelSelector()
        splitter.addWidget(self._channel_selector)

        # PyQtGraph plot (center)
        self._plot_widget = pg.PlotWidget()
        self._plot_widget.setLabel("bottom", "Time", units="s")
        self._plot_widget.showGrid(x=True, y=True, alpha=GRID_ALPHA)
        self._plot_widget.setMouseEnabled(x=True, y=False)
        self._plot_widget.getAxis("left").setWidth(60)
        splitter.addWidget(self._plot_widget)

        splitter.setStretchFactor(0, 0)
        splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, stretch=1)

        # Set up annotation mouse interaction
        self._setup_annotation_interaction()

        # Bottom: controls
        self._controls = WaveformControls()
        layout.addWidget(self._controls)

        # Connect control signals
        self._controls.play_pause_clicked.connect(self._on_play_pause)
        self._controls.speed_changed.connect(self._on_speed_changed)
        self._controls.position_changed.connect(self._on_scrub)
        self._controls.amplitude_changed.connect(self._on_amplitude_changed)
        self._controls.mode_changed.connect(self._on_mode_changed)
        self._controls.window_size_changed.connect(self._on_window_size_changed)
        self._channel_selector.channels_changed.connect(self._on_channels_changed)

    def _init_playback(self):
        self._playback = PlaybackWorker(self)
        self._playback.time_updated.connect(self._on_playback_tick)
        self._playback.playback_finished.connect(self._on_playback_finished)

    def _is_ecg_channel(self, ch_name):
        """Check if a channel is ECG/EKG (not EEG)."""
        return ch_name.upper() in ("ECG", "EKG")

    def _channel_scale(self, ch_name):
        """Return the amplitude scale factor for a channel.

        ECG channels are scaled down to prevent overlap with EEG traces.
        """
        if self._is_ecg_channel(ch_name):
            return self._amplitude_scale * _ECG_SCALE_FACTOR
        return self._amplitude_scale

    def set_data(self, loader):
        """Initialize display with loaded EDF data."""
        self._loader = loader

        # Order channels according to DISPLAY_ORDER, with unknowns at end
        ordered = []
        for ch in DISPLAY_ORDER:
            if ch in loader.channel_names:
                ordered.append(ch)
        for ch in loader.channel_names:
            if ch not in ordered:
                ordered.append(ch)

        self._visible_channels = list(ordered)
        self._channel_selector.set_channels(ordered)
        self._controls.set_duration(loader.duration)
        self._playback.set_duration(loader.duration)

        # Create plot items for each channel
        self._create_plot_items(ordered)
        self._update_display()

    def _create_plot_items(self, channels):
        """Create PlotDataItem for each channel."""
        self._plot_widget.clear()
        self._plot_items.clear()

        for i, ch_name in enumerate(channels):
            # Use a distinct red color for ECG to differentiate from EEG traces
            if self._is_ecg_channel(ch_name):
                pen = pg.mkPen(color="#CC3333", width=1)
            else:
                pen = pg.mkPen(color=TRACE_COLOR, width=1)
            item = self._plot_widget.plot([], [], pen=pen, name=ch_name)
            self._plot_items[ch_name] = item

        self._update_y_axis_labels()

    def _update_y_axis_labels(self):
        """Set Y-axis tick labels to channel names at offset positions."""
        ticks = []
        for i, ch_name in enumerate(self._visible_channels):
            offset = -i * self._channel_spacing * self._amplitude_scale
            ticks.append((offset, ch_name))

        y_axis = self._plot_widget.getAxis("left")
        y_axis.setTicks([ticks])

    def _update_display(self):
        """Refresh the waveform display for current state."""
        if self._loader is None or not self._visible_channels:
            return

        if self._mode == "static":
            self._draw_static()
        else:
            self._draw_windowed()

    def _draw_static(self):
        """Draw the full recording for static/scrollable viewing."""
        # Hide all items first
        for ch_name, item in self._plot_items.items():
            if ch_name not in self._visible_channels:
                item.setData([], [])

        # Get data for visible channels
        data, times = self._loader.get_all_data(self._visible_channels)

        # Downsample for display performance if needed
        max_points = 50000
        if data.shape[1] > max_points:
            step = data.shape[1] // max_points
            data = data[:, ::step]
            times = times[::step]

        for i, ch_name in enumerate(self._visible_channels):
            if ch_name in self._plot_items:
                offset = -i * self._channel_spacing * self._amplitude_scale
                ch_scale = self._channel_scale(ch_name)
                scaled = data[i] * ch_scale * 1e6 + offset  # convert V to uV
                self._plot_items[ch_name].setData(times, scaled)

        self._plot_widget.setXRange(0, self._loader.duration, padding=0.01)
        self._update_y_range()

    def _draw_windowed(self):
        """Draw a time window for playback mode."""
        # Hide all items first
        for ch_name, item in self._plot_items.items():
            if ch_name not in self._visible_channels:
                item.setData([], [])

        start = max(0, self._current_time)
        duration = min(self._time_window, self._loader.duration - start)
        if duration <= 0:
            return

        data, times = self._loader.get_data_chunk(start, duration, self._visible_channels)

        for i, ch_name in enumerate(self._visible_channels):
            if ch_name in self._plot_items:
                offset = -i * self._channel_spacing * self._amplitude_scale
                ch_scale = self._channel_scale(ch_name)
                scaled = data[i] * ch_scale * 1e6 + offset  # convert V to uV
                self._plot_items[ch_name].setData(times, scaled)

        self._plot_widget.setXRange(start, start + self._time_window, padding=0)
        self._update_y_range()

    def _update_y_range(self):
        """Set Y range to fit all visible channels."""
        if not self._visible_channels:
            return
        n = len(self._visible_channels)
        top = self._channel_spacing * self._amplitude_scale
        bottom = -(n) * self._channel_spacing * self._amplitude_scale
        self._plot_widget.setYRange(bottom, top, padding=0.02)

    # --- Event handlers ---

    def _on_play_pause(self):
        if self._playback.is_playing:
            self._playback.pause()
            self._controls.set_playing(False)
        else:
            self._playback.start()
            self._controls.set_playing(True)

    def _on_speed_changed(self, speed):
        self._playback.set_speed(speed)

    def _on_scrub(self, time_sec):
        self._current_time = time_sec
        self._playback.seek(time_sec)
        if self._mode == "playback":
            self._draw_windowed()

    def _on_amplitude_changed(self, scale):
        self._amplitude_scale = scale
        self._update_y_axis_labels()
        self._update_display()

    def _on_mode_changed(self, mode):
        self._mode = mode
        if mode == "playback":
            self._current_time = 0.0
            self._playback.reset()
            self._controls.update_time_display(0.0)
        self._update_display()

    def _on_window_size_changed(self, window_sec):
        self._time_window = window_sec
        if self._mode == "playback":
            self._draw_windowed()

    def _on_channels_changed(self, channels):
        self._visible_channels = channels
        self._create_plot_items(channels)
        self._update_display()

    def _on_playback_tick(self, current_time):
        self._current_time = current_time
        self._controls.update_time_display(current_time)
        self._draw_windowed()

    def _on_playback_finished(self):
        self._controls.set_playing(False)

    # --- Annotation support ---

    def set_annotation_store(self, store):
        """Set the annotation store and update UI."""
        self.annotation_store = store
        self._rebuild_label_bar()
        self._draw_annotations()

    def _rebuild_label_bar(self):
        """Rebuild label buttons from annotation store."""
        # Clear existing
        while self._label_bar_layout.count():
            item = self._label_bar_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        if not self.annotation_store:
            return

        for i, label in enumerate(self.annotation_store.labels):
            c = label.color
            btn = QPushButton(label.name)
            r, g, b = int(c['red'] * 255), int(c['green'] * 255), int(c['blue'] * 255)
            btn.setStyleSheet(
                f"QPushButton {{ background-color: rgba({r},{g},{b},80); "
                f"border: 2px solid rgba({r},{g},{b},200); padding: 4px 8px; }}"
                f"QPushButton:checked {{ border: 3px solid rgba({r},{g},{b},255); font-weight: bold; }}"
            )
            btn.setCheckable(True)
            if i == self._selected_label_idx:
                btn.setChecked(True)
            btn.clicked.connect(lambda checked, idx=i: self._on_label_selected(idx))
            self._label_bar_layout.addWidget(btn)

        self._label_bar_layout.addStretch()

        # Add "Edit Labels" button
        edit_btn = QPushButton("Edit Labels...")
        edit_btn.clicked.connect(self._edit_labels)
        self._label_bar_layout.addWidget(edit_btn)

    def _on_label_selected(self, idx):
        self._selected_label_idx = idx

    def _edit_labels(self):
        """Open label editor dialog."""
        from .annotation_label_editor import AnnotationLabelEditor
        if not self.annotation_store:
            return
        dialog = AnnotationLabelEditor(self.annotation_store, parent=self)
        if dialog.exec_() == QDialog.Accepted:
            self._rebuild_label_bar()
            self._draw_annotations()

    def _draw_annotations(self):
        """Draw annotation regions on the plot."""
        # Remove existing regions
        for region in self._annotation_regions:
            self._plot_widget.removeItem(region)
        self._annotation_regions.clear()

        if not self.annotation_store:
            return

        for ann in self.annotation_store.annotations:
            label = self.annotation_store.label_for(ann)
            if not label:
                continue
            c = label.color
            r, g, b = int(c['red'] * 255), int(c['green'] * 255), int(c['blue'] * 255)

            region = pg.LinearRegionItem(
                values=[ann.startTime, ann.endTime],
                movable=False,
                brush=pg.mkBrush(r, g, b, 40),
                pen=pg.mkPen(r, g, b, 150),
            )
            region.ann_id = ann.id  # tag for identification
            self._plot_widget.addItem(region)
            self._annotation_regions.append(region)

    def _setup_annotation_interaction(self):
        """Set up mouse handlers for Shift+drag annotation creation."""
        vb = self._plot_widget.getPlotItem().getViewBox()
        self._orig_mouse_press = vb.mousePressEvent
        self._orig_mouse_move = vb.mouseMoveEvent
        self._orig_mouse_release = vb.mouseReleaseEvent

        vb.mousePressEvent = self._on_mouse_press
        vb.mouseMoveEvent = self._on_mouse_move
        vb.mouseReleaseEvent = self._on_mouse_release

    def _on_mouse_press(self, event):
        if event.button() == Qt.RightButton and self.annotation_store:
            # Right-click: context menu on existing annotation
            pos = self._plot_widget.getPlotItem().getViewBox().mapSceneToView(event.scenePos())
            self._show_annotation_menu(pos.x(), event.screenPos())
            return

        if event.button() == Qt.LeftButton and self.annotation_store:
            # Check for Shift+Click for annotation creation
            if event.modifiers() & Qt.ShiftModifier:
                pos = self._plot_widget.getPlotItem().getViewBox().mapSceneToView(event.scenePos())
                self._drag_start = pos.x()
                # Create preview region
                self._drag_region = pg.LinearRegionItem(
                    values=[self._drag_start, self._drag_start],
                    movable=False,
                    brush=pg.mkBrush(100, 100, 255, 40),
                )
                self._plot_widget.addItem(self._drag_region)
                return

        self._orig_mouse_press(event)

    def _on_mouse_move(self, event):
        if self._drag_start is not None and self._drag_region is not None:
            pos = self._plot_widget.getPlotItem().getViewBox().mapSceneToView(event.scenePos())
            self._drag_region.setRegion([self._drag_start, pos.x()])
            return
        self._orig_mouse_move(event)

    def _on_mouse_release(self, event):
        if event.button() == Qt.LeftButton and self._drag_start is not None:
            pos = self._plot_widget.getPlotItem().getViewBox().mapSceneToView(event.scenePos())
            end_time = pos.x()

            # Remove preview
            if self._drag_region:
                self._plot_widget.removeItem(self._drag_region)
                self._drag_region = None

            # Create annotation if drag was meaningful (>0.1s)
            if abs(end_time - self._drag_start) > 0.1 and self.annotation_store:
                if self._selected_label_idx < len(self.annotation_store.labels):
                    label = self.annotation_store.labels[self._selected_label_idx]
                    self.annotation_store.add_annotation(self._drag_start, end_time, label.id)
                    self._draw_annotations()

            self._drag_start = None
            return

        self._orig_mouse_release(event)

    def _show_annotation_menu(self, time_x, screen_pos):
        """Show context menu for annotation at given time."""
        if not self.annotation_store:
            return

        # Find annotation at this time
        hit = None
        for ann in self.annotation_store.annotations:
            if ann.startTime <= time_x <= ann.endTime:
                hit = ann
                break

        if not hit:
            return

        menu = QMenu(self)

        # Label reassignment submenu
        label_menu = menu.addMenu("Change Label")
        for lbl in self.annotation_store.labels:
            action = label_menu.addAction(lbl.name)
            action.setCheckable(True)
            action.setChecked(lbl.id == hit.labelID)
            action.triggered.connect(
                lambda checked, lid=lbl.id, aid=hit.id:
                    self._reassign_label(aid, lid)
            )

        menu.addSeparator()
        delete_action = menu.addAction("Delete Annotation")
        delete_action.triggered.connect(lambda: self._delete_annotation(hit.id))

        menu.exec_(screen_pos.toPoint())

    def _reassign_label(self, ann_id, label_id):
        for ann in self.annotation_store.annotations:
            if ann.id == ann_id:
                ann.labelID = label_id
                break
        self.annotation_store.save()
        self._draw_annotations()

    def _delete_annotation(self, ann_id):
        self.annotation_store.remove_annotation(ann_id)
        self._draw_annotations()
