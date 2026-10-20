"""Wires everything together for one monitoring session:

  CameraWorker (per camera, RTSP) -> CameraAnalyzer -> Cooldown
      -> snapshot encode -> Outbox (disk) -> Sender (HTTPS, rate-budgeted)

Also keeps a small local log of recent events for the UI ("last events").
"""
from __future__ import annotations

import collections
import json
import logging
import threading
import time
from typing import Dict, List, Optional

from . import paths, payload
from .analyzer import CameraAnalyzer
from .camera import CameraWorker
from .client import DROP, SENT, UNAUTHORIZED, IngestClient, Sender
from .config import AppConfig, join_rtsp_credentials
from .cooldown import Cooldown, RateBudget
from .outbox import Outbox
from .person import load_detector
from .secure_store import SITE_TOKEN, SecretStore, cam_key

log = logging.getLogger(__name__)


def camera_url(cfg: AppConfig, store: SecretStore, cam_id: str) -> str:
    """The credentialed RTSP URL handed to FFmpeg. In memory only: never
    logged (logutil masks userinfo) and never saved."""
    cam = cfg.camera(cam_id)
    user = store.get(cam_key(cam_id, "user"))
    pwd = store.get(cam_key(cam_id, "pass"))
    return join_rtsp_credentials(cam.rtsp_url, user, pwd)


class EventLog:
    """Recent local events (bounded in memory + a small JSONL file)."""

    def __init__(self, path: Optional[str] = None, keep: int = 300):
        self.path = path or paths.path("events.jsonl")
        self._mem = collections.deque(maxlen=keep)
        self._lock = threading.Lock()
        self.keep = keep
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                lines = f.readlines()[-keep:]
            for ln in lines:
                try:
                    self._mem.append(json.loads(ln))
                except ValueError:
                    pass
            with open(self.path, "w", encoding="utf-8") as f:  # trim on start
                f.writelines(lines)
        except FileNotFoundError:
            pass

    def add(self, **row) -> None:
        row.setdefault("ts", time.time())
        with self._lock:
            self._mem.append(row)
            try:
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(row, ensure_ascii=False) + "\n")
            except OSError:
                pass

    def recent(self, n: int = 50) -> List[dict]:
        with self._lock:
            return list(self._mem)[-n:][::-1]


class Engine:
    def __init__(self, cfg: AppConfig, store: Optional[SecretStore] = None,
                 detector=None, events: Optional[EventLog] = None):
        self.cfg = cfg
        self.store = store or SecretStore()
        self.events = events or EventLog()
        self.detector = detector if detector is not None else load_detector(
            score_thr=cfg.detection.person_score,
            threads=cfg.detection.detector_threads)
        s = cfg.sending
        self.outbox = Outbox(paths.path("outbox"), max_items=s.queue_max_items,
                             max_bytes=s.queue_max_mb * 1024 * 1024,
                             max_age_s=s.queue_max_age_h * 3600)
        self.cooldown = Cooldown(s.cooldown_s)
        self.workers: Dict[str, CameraWorker] = {}
        self.analyzers: Dict[str, CameraAnalyzer] = {}
        self.sender: Optional[Sender] = None
        self.running = False

    # ------------------------------------------------------------ credentials
    def tokens_for(self, camera_id: Optional[str]):
        site = self.store.get(SITE_TOKEN)
        cam = self.store.get(cam_key(camera_id, "token")) if camera_id else None
        return site, cam

    def rtsp_url_for(self, cam_id: str) -> str:
        return camera_url(self.cfg, self.store, cam_id)

    # -------------------------------------------------------------- lifecycle
    def start(self) -> None:
        if self.running:
            return
        if not self.store.get(SITE_TOKEN):
            raise RuntimeError("not_paired")
        client = IngestClient(self.cfg.base_url, timeout=self.cfg.sending.timeout_s)
        self.sender = Sender(self.outbox, client, self.tokens_for,
                             RateBudget(self.cfg.sending.max_per_min, 60.0),
                             snapshot_mode=self.cfg.sending.snapshot_mode,
                             on_result=self._on_send_result)
        self.sender.start()
        for cam in self.cfg.cameras:
            if not cam.enabled:
                continue
            an = CameraAnalyzer(cam, self.cfg.hours_for(cam), self.cfg.detection,
                                self.detector)
            self.analyzers[cam.id] = an
            w = CameraWorker(cam.id, cam.name,
                             url_provider=lambda cid=cam.id: self.rtsp_url_for(cid),
                             sample_fps=self.cfg.detection.sample_fps,
                             on_frame=lambda f, cid=cam.id: self._on_frame(cid, f))
            self.workers[cam.id] = w
            w.start()
        self.running = True
        log.info("monitoring %d camera(s); detector=%s", len(self.workers),
                 getattr(self.detector, "name", "motion_only"))

    def stop(self) -> None:
        for w in self.workers.values():
            w.stop()
        if self.sender:
            self.sender.stop()
        for w in self.workers.values():
            w.join(timeout=15)
        self.workers.clear()
        self.analyzers.clear()
        self.running = False

    # --------------------------------------------------------------- pipeline
    def _on_frame(self, cam_id: str, frame) -> None:
        an = self.analyzers.get(cam_id)
        if an is None:
            return
        trig = an.process(frame)
        if trig is None:
            return
        self.handle_trigger(cam_id, trig)

    def handle_trigger(self, cam_id: str, trig) -> bool:
        """Apply cooldown, encode the one snapshot, queue. Returns True if queued."""
        if not self.cooldown.allow((cam_id, trig.type)):
            return False
        cam = self.cfg.camera(cam_id)
        snap = None
        if self.cfg.sending.snapshot_mode != "never":
            try:
                snap = payload.encode_snapshot(
                    trig.frame, max_bytes=self.cfg.sending.snapshot_max_kb * 1024,
                    zone=cam.zone if cam else None)
            except ValueError:
                snap = None
        event = payload.build_event(trig.type, trig.signals, camera_id=cam_id,
                                    at=trig.at)
        self.outbox.put(event, snap)
        self.events.add(camera=cam.name if cam else cam_id, type=trig.type,
                        status="queued", signals=trig.signals)
        log.info("event queued: camera=%s type=%s", cam.name if cam else cam_id,
                 trig.type)
        if self.sender:
            self.sender.wake()
        return True

    def _on_send_result(self, item_id, event, res) -> None:
        cam = self.cfg.camera(event.get("camera_id") or "")
        name = cam.name if cam else event.get("camera_id")
        if res.outcome == SENT:
            status = "alert" if res.raised else "logged"
        elif res.outcome == DROP:
            status = "rejected"
        elif res.outcome == UNAUTHORIZED:
            status = "unpaired"
        else:
            return     # retries are not interesting in the UI list
        self.events.add(camera=name, type=event.get("type"), status=status,
                        confidence=res.confidence)

    # ----------------------------------------------------------------- status
    def status(self) -> dict:
        return {
            "running": self.running,
            "detector": getattr(self.detector, "name", "motion_only"),
            "cameras": {cid: w.status for cid, w in self.workers.items()},
            "queued": len(self.outbox),
            "online": self.sender.online if self.sender else None,
            "unauthorized": self.sender.unauthorized if self.sender else False,
        }
