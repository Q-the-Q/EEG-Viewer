"""Annotation data model and JSON sidecar persistence.

File format is interoperable with the Swift EEG Viewer app --
both use .annotations.json sidecar files next to the EDF.
"""

import json
import os
import uuid
from dataclasses import dataclass, field, asdict
from typing import List, Tuple, Optional


@dataclass
class AnnotationLabel:
    """A user-configurable label for annotations."""
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())
    name: str = ""
    color: dict = field(default_factory=lambda: {"red": 0.3, "green": 0.5, "blue": 0.9, "alpha": 1.0})
    analysisMode: str = "exclude"  # "exclude" or "analyzeSeparately"


@dataclass
class EEGAnnotation:
    """A time-range annotation on the EEG recording."""
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())
    startTime: float = 0.0
    endTime: float = 0.0
    labelID: str = ""


DEFAULT_LABELS = [
    AnnotationLabel(name="Artifact",
                    color={"red": 0.9, "green": 0.2, "blue": 0.2, "alpha": 1.0},
                    analysisMode="exclude"),
    AnnotationLabel(name="Eyes Open",
                    color={"red": 0.5, "green": 0.5, "blue": 0.5, "alpha": 1.0},
                    analysisMode="exclude"),
    AnnotationLabel(name="Movement",
                    color={"red": 0.9, "green": 0.6, "blue": 0.1, "alpha": 1.0},
                    analysisMode="exclude"),
]


class AnnotationStore:
    """Manages annotation labels and annotations with JSON sidecar persistence."""

    def __init__(self):
        self.labels: List[AnnotationLabel] = [
            AnnotationLabel(id=l.id, name=l.name, color=dict(l.color),
                           analysisMode=l.analysisMode)
            for l in DEFAULT_LABELS
        ]
        self.annotations: List[EEGAnnotation] = []
        self.bad_channel_indices: set = set()
        self._edf_path: Optional[str] = None

    @staticmethod
    def annotation_path(edf_path: str) -> str:
        """Return .annotations.json path for a given EDF file."""
        base = os.path.splitext(edf_path)[0]
        return base + ".annotations.json"

    def load(self, edf_path: str):
        """Load annotations from JSON sidecar, or reset to defaults."""
        self._edf_path = edf_path
        ann_path = self.annotation_path(edf_path)

        if not os.path.exists(ann_path):
            self.labels = [
                AnnotationLabel(id=l.id, name=l.name, color=dict(l.color),
                               analysisMode=l.analysisMode)
                for l in DEFAULT_LABELS
            ]
            self.annotations = []
            self.bad_channel_indices = set()
            return

        try:
            with open(ann_path, 'r') as f:
                data = json.load(f)

            self.labels = []
            for lbl in data.get("labels", []):
                self.labels.append(AnnotationLabel(
                    id=lbl["id"],
                    name=lbl["name"],
                    color=lbl["color"],
                    analysisMode=lbl["analysisMode"],
                ))

            self.annotations = []
            for ann in data.get("annotations", []):
                self.annotations.append(EEGAnnotation(
                    id=ann["id"],
                    startTime=ann["startTime"],
                    endTime=ann["endTime"],
                    labelID=ann["labelID"],
                ))

            self.bad_channel_indices = set(data.get("badChannelIndices", []))
        except Exception as e:
            print(f"AnnotationStore: failed to load {ann_path}: {e}")
            self.labels = [
                AnnotationLabel(id=l.id, name=l.name, color=dict(l.color),
                               analysisMode=l.analysisMode)
                for l in DEFAULT_LABELS
            ]
            self.annotations = []
            self.bad_channel_indices = set()

    def save(self):
        """Save to JSON sidecar next to EDF."""
        if not self._edf_path:
            return
        ann_path = self.annotation_path(self._edf_path)

        data = {
            "labels": [asdict(l) for l in self.labels],
            "annotations": [asdict(a) for a in self.annotations],
            "badChannelIndices": sorted(self.bad_channel_indices),
        }

        try:
            with open(ann_path, 'w') as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"AnnotationStore: failed to save: {e}")

    def label_for(self, annotation: EEGAnnotation) -> Optional[AnnotationLabel]:
        """Return the label for an annotation."""
        for lbl in self.labels:
            if lbl.id == annotation.labelID:
                return lbl
        return None

    def excluded_time_ranges(self) -> List[Tuple[float, float]]:
        """Return time ranges for annotations with 'exclude' mode."""
        ranges = []
        for ann in self.annotations:
            lbl = self.label_for(ann)
            if lbl and lbl.analysisMode == "exclude":
                ranges.append((ann.startTime, ann.endTime))
        return ranges

    def separate_groups(self) -> dict:
        """Return annotations grouped by label name for 'analyzeSeparately' labels."""
        groups = {}
        for ann in self.annotations:
            lbl = self.label_for(ann)
            if lbl and lbl.analysisMode == "analyzeSeparately":
                groups.setdefault(lbl.name, []).append(
                    (ann.startTime, ann.endTime)
                )
        return groups

    def add_annotation(self, start_time: float, end_time: float, label_id: str):
        """Add a new annotation and save."""
        ann = EEGAnnotation(
            startTime=min(start_time, end_time),
            endTime=max(start_time, end_time),
            labelID=label_id,
        )
        self.annotations.append(ann)
        self.save()
        return ann

    def remove_annotation(self, ann_id: str):
        """Remove annotation by ID and save."""
        self.annotations = [a for a in self.annotations if a.id != ann_id]
        self.save()

    def remove_annotations_for_label(self, label_id: str):
        """Remove all annotations with given label ID."""
        self.annotations = [a for a in self.annotations if a.labelID != label_id]
        self.save()
