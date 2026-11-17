"""gboxlinux — resource profile so the Guard Box fits a 2 GB Raspberry Pi.

  full  a PC / mini PC with >= 3.5 GB RAM: the configured settings as they are.
  lite  <= 3.5 GB RAM or an ARM board: the camera SUB-stream, 1.5 analysed
        frames a second per camera (the rest are grabbed but never decoded
        to colour), 512 px analysis frames, ONE inference thread, onnxruntime
        without its memory arena, OpenCV single-threaded, a smaller outbox.

`SHOPBOX_PROFILE=lite|full` overrides the choice (the CI uses it).
The systemd unit adds hard caps on top (MemoryMax, CPUWeight, Nice).
"""
from __future__ import annotations

import logging
import os
from typing import Optional

from . import sysinfo

log = logging.getLogger(__name__)

LITE_RAM_MB = 3584
LITE = {"sample_fps": 1.5, "frame_width": 512, "detector_threads": 1,
        "queue_max_mb": 25}


def choose(mem_mb: Optional[int] = None, arch: Optional[str] = None) -> str:
    env = (os.environ.get("SHOPBOX_PROFILE") or "").strip().lower()
    if env in ("lite", "full"):
        return env
    mem = sysinfo.mem_total_mb() if mem_mb is None else mem_mb
    a = sysinfo.arch() if arch is None else arch
    if a in ("arm64", "armv7"):
        return "lite"
    if mem is not None and mem <= LITE_RAM_MB:
        return "lite"
    return "full"


def apply(cfg, name: Optional[str] = None) -> str:
    """Tighten an AppConfig in memory for the profile (never saved: moving
    the box to a bigger PC brings the full settings back)."""
    name = name or choose()
    if name != "lite":
        return name
    from dataclasses import asdict
    d, s = cfg.detection, cfg.sending
    cfg._unprofiled = {"detection": asdict(d), "sending": asdict(s)}
    d.sample_fps = min(float(d.sample_fps), LITE["sample_fps"])
    d.frame_width = min(int(d.frame_width), LITE["frame_width"])
    d.detector_threads = min(int(d.detector_threads), LITE["detector_threads"])
    d.prefer_substream = True
    d.low_memory = True
    s.queue_max_mb = min(int(s.queue_max_mb), LITE["queue_max_mb"])
    try:
        import cv2
        cv2.setNumThreads(1)
    except Exception:
        pass
    log.info("resource profile: lite (sub-stream, %.1f fps, %d px, 1 thread)",
             d.sample_fps, d.frame_width)
    return name
