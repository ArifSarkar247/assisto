"""RTSP capture on the LOCAL network: one thread per camera, low-fps sampling,
reconnect with exponential backoff.

OpenCV's FFmpeg backend decodes every frame the camera sends, so CPU cost is
driven by the stream's resolution/fps, not by our sampling rate. Use the
camera's SUB-STREAM (e.g. 640x360 @ 10-15 fps) — see README — and the client
only *analyses* `sample_fps` frames per second (default 3).
"""
from __future__ import annotations

import logging
import os
import threading
import time
from typing import Callable, Optional, Tuple

from .logutil import mask_url

log = logging.getLogger(__name__)

# RTSP over TCP: far more reliable than UDP on busy shop Wi-Fi/LANs. Must be
# set before the first VideoCapture is opened.
os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")

OPEN_TIMEOUT_MS = 10000
READ_TIMEOUT_MS = 10000


def open_capture(url: str):
    """Open a stream with the FFmpeg backend and bounded timeouts."""
    import cv2

    params = []
    for name, val in (("CAP_PROP_OPEN_TIMEOUT_MSEC", OPEN_TIMEOUT_MS),
                      ("CAP_PROP_READ_TIMEOUT_MSEC", READ_TIMEOUT_MS)):
        if hasattr(cv2, name):
            params += [getattr(cv2, name), val]
    try:
        cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG, params)
    except TypeError:            # very old OpenCV without the params overload
        cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG)
    try:
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
    except Exception:
        pass
    return cap


def grab_one_frame(url: str, timeout_s: float = 15.0) -> Tuple[bool, Optional[object], str]:
    """For the UI's 'Test camera' / zone drawing: (ok, frame, message).
    The message never contains credentials."""
    t0 = time.monotonic()
    cap = open_capture(url)
    try:
        if not cap.isOpened():
            return False, None, "could_not_open"
        while time.monotonic() - t0 < timeout_s:
            ok, frame = cap.read()
            if ok and frame is not None:
                h, w = frame.shape[:2]
                return True, frame, "%dx%d" % (w, h)
        return False, None, "no_frames"
    finally:
        cap.release()


class CameraWorker(threading.Thread):
    """Pulls frames from one camera and feeds `on_frame(frame)` at ~sample_fps.

    status: "starting" | "online" | "offline" | "stopped"
    """

    def __init__(self, cam_id: str, name: str, url_provider: Callable[[], str],
                 sample_fps: float, on_frame: Callable, max_backoff_s: float = 60.0,
                 on_tap: Optional[Callable] = None, tap_fps: float = 5.0,
                 tap_active: Optional[Callable[[], bool]] = None):
        super().__init__(name="cam-%s" % cam_id, daemon=True)
        self.cam_id = cam_id
        self.cam_name = name
        self.url_provider = url_provider     # builds the credentialed URL lazily
        self.interval = 1.0 / max(0.2, min(float(sample_fps), 10.0))
        self.on_frame = on_frame
        # cashguard: a cheaper, faster tap for the clip ring (JPEG only, no
        # analysis) — None keeps the old single-rate behaviour exactly
        self.on_tap = on_tap
        self.tap_interval = 1.0 / max(1.0, min(float(tap_fps), 10.0))
        self.tap_active = tap_active or (lambda: True)
        self.max_backoff_s = max_backoff_s
        self.status = "starting"
        self.last_frame_at: Optional[float] = None
        self._halt = threading.Event()

    def stop(self) -> None:
        self._halt.set()

    def run(self) -> None:
        backoff = 2.0
        while not self._halt.is_set():
            url = self.url_provider()
            cap = open_capture(url)
            if not cap.isOpened():
                cap.release()
                self.status = "offline"
                log.warning("camera %s: cannot open %s; retry in %.0fs",
                            self.cam_name, mask_url(url), backoff)
                self._halt.wait(backoff)
                backoff = min(self.max_backoff_s, backoff * 2)
                continue
            log.info("camera %s: connected", self.cam_name)
            self.status = "online"
            session_start = time.monotonic()
            failures = 0
            next_at = 0.0
            next_tap = 0.0
            try:
                while not self._halt.is_set():
                    # grab() keeps the decoder current without the cost of a
                    # colour conversion; retrieve() only at the sampling rate.
                    if not cap.grab():
                        failures += 1
                        if failures >= 3:
                            break
                        continue
                    failures = 0
                    now = time.monotonic()
                    tap_due = (self.on_tap is not None and now >= next_tap
                               and self.tap_active())
                    if now < next_at and not tap_due:
                        continue
                    ok, frame = cap.retrieve()
                    if not ok or frame is None:
                        continue
                    self.last_frame_at = time.time()
                    if tap_due:
                        next_tap = now + self.tap_interval
                        try:
                            self.on_tap(frame)
                        except Exception:
                            log.exception("camera %s: clip tap error", self.cam_name)
                    if now < next_at:
                        continue
                    next_at = now + self.interval
                    try:
                        self.on_frame(frame)
                    except Exception:
                        log.exception("camera %s: analysis error", self.cam_name)
            finally:
                cap.release()
            if time.monotonic() - session_start >= 60:
                backoff = 2.0          # it was a stable session: retry quickly
            if not self._halt.is_set():
                self.status = "offline"
                log.warning("camera %s: stream lost; reconnecting in %.0fs",
                            self.cam_name, backoff)
                self._halt.wait(backoff)
                backoff = min(self.max_backoff_s, backoff * 2)
        self.status = "stopped"
