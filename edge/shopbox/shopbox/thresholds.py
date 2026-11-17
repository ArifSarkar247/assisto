"""gboxlinux — the SHARED Guard Box thresholds (guard_thresholds.json).

The phone Guard Box (Flutter) and this box (Linux / Raspberry Pi / Windows)
alert on the same rules: the same person score, the same cool-downs, the same
"camera lost" time. The JSON next to this file is the single source; the
defaults below are only a fallback when a frozen build lost the data file,
and a unit test keeps all three (JSON, these defaults, the Dart constants)
equal.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Dict

DEFAULTS: Dict[str, float] = {
    "person_score": 0.45,
    "person_cooldown_s": 60,
    "motion_cooldown_s": 180,
    "check_every_s": 5,
    "cam_lost_s": 120,
    "confirm_frames": 3,
    "live_fps": 4,
    "offline_queue_max": 20,
}
FILENAME = "guard_thresholds.json"


def _candidates():
    here = os.path.dirname(os.path.abspath(__file__))
    out = [os.path.join(here, FILENAME)]
    base = getattr(sys, "_MEIPASS", None)
    if base:
        out.append(os.path.join(base, "shopbox", FILENAME))
    return out


def load() -> Dict[str, float]:
    """The shared thresholds (unknown / bad values -> the defaults)."""
    out = dict(DEFAULTS)
    for p in _candidates():
        try:
            with open(p, "r", encoding="utf-8") as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        for k, v in d.items():
            if k in DEFAULTS and isinstance(v, (int, float)) and not isinstance(v, bool):
                out[k] = v
        break
    return out


T = load()
