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
    from .tasks import secret_key, user_key

    cam = cfg.camera(cam_id)
    user = store.get(cam_key(cam_id, "user"))
    pwd = store.get(cam_key(cam_id, "pass"))
    if cam.server_id is not None and not (user or pwd):
        # added from the app via a gateway check: the secret was saved under
        # the server camera id when the task arrived
        user = store.get(user_key(cam.server_id))
        pwd = store.get(secret_key(cam.server_id))
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
                 detector=None, events: Optional[EventLog] = None,
                 cfg_store=None):
        self.cfg = cfg
        self.cfg_store = cfg_store       # ConfigStore; created lazily on save
        self.tasks = None                # tasks.GatewayTasks (camera checks)
        self._cam_lock = threading.Lock()
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
        self.sync = None                 # device.DeviceSync (heartbeat/config)
        self.live = None                 # live.LiveAnswerer when aiortc is present
        self.latest: Dict[str, object] = {}   # cam_id -> latest analysis frame
        self.running = False

    # ------------------------------------------------------------ credentials
    def tokens_for(self, camera_id: Optional[str]):
        site = self.store.get(SITE_TOKEN)
        cam = self.store.get(cam_key(camera_id, "token")) if camera_id else None
        return site, cam

    def rtsp_url_for(self, cam_id: str) -> str:
        return camera_url(self.cfg, self.store, cam_id)

    def device_tokens(self) -> Dict[str, str]:
        """Tokens to heartbeat with: each camera's own token (so the owner's
        app shows THAT camera online), else the site token once."""
        out = {}
        for cam in self.cfg.cameras:
            tok = self.store.get(cam_key(cam.id, "token"))
            if tok:
                out[cam.id] = tok
        if not out:
            site = self.store.get(SITE_TOKEN)
            if site:
                out[""] = site
        return out

    def _cam_for_token(self, token: str) -> Optional[str]:
        for cid, tok in self.device_tokens().items():
            if tok == token:
                return cid or (self.cfg.cameras[0].id if self.cfg.cameras else None)
        return None

    def frame_source_for(self, token: str):
        cid = self._cam_for_token(token)
        return lambda: self.latest.get(cid) if cid else None

    def apply_server_config(self, data: dict, cam_id: Optional[str]) -> None:
        """Owner's server-side settings -> local config (enabled + hours)."""
        from .device import apply_server_camera, apply_server_site
        changed = apply_server_site(self.cfg, data.get("site") or {})
        site_hours = (data.get("site") or {}).get("hours") or None
        srv_cams = [c for c in (data.get("cameras") or []) if isinstance(c, dict)]
        if cam_id:
            cam = self.cfg.camera(cam_id)
            srv = srv_cams[0] if srv_cams else None
            if cam is not None and srv is not None:
                changed = apply_server_camera(cam, srv, site_hours) or changed
        else:
            # site token: match the gateway cameras by their server id
            for srv in srv_cams:
                try:
                    sid = int(srv.get("id"))
                except (TypeError, ValueError):
                    continue
                cam = next((c for c in self.cfg.cameras if c.server_id == sid), None)
                if cam is not None:
                    if srv.get("name"):
                        cam.name = str(srv["name"])[:120]
                    changed = apply_server_camera(cam, srv, site_hours) or changed
        if changed:
            for cid, an in list(self.analyzers.items()):
                cam = self.cfg.camera(cid)
                if cam is not None:
                    an.reconfigure(cam, self.cfg.hours_for(cam))
            self._save_config()
            log.info("applied the owner's server settings")

    def _save_config(self) -> None:
        try:
            if self.cfg_store is None:
                from .config import ConfigStore
                self.cfg_store = ConfigStore()
            self.cfg_store.save(self.cfg)
        except Exception:
            log.exception("could not save config")

    def server_camera_ids(self) -> List[int]:
        return [c.server_id for c in self.cfg.cameras
                if c.server_id is not None and c.enabled]

    def on_camera_checked(self, task: dict, outcome) -> None:
        """A gateway check succeeded: add/update the local camera and (when
        monitoring) start capturing it. The secret is already in the store."""
        from .tasks import upsert_camera

        with self._cam_lock:
            cam = upsert_camera(self.cfg, task["camera_id"], task.get("request") or {},
                                outcome.stream_url, name=task.get("name"))
            self._save_config()
            if self.running and cam.enabled:
                old = self.workers.pop(cam.id, None)
                if old is not None:
                    old.stop()
                self._start_camera(cam)
        log.info("camera %s ready from the app check", cam.name)

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
        self._start_device_sync()
        with self._cam_lock:
            for cam in self.cfg.cameras:
                if cam.enabled:
                    self._start_camera(cam)
            self.running = True
        log.info("monitoring %d camera(s); detector=%s", len(self.workers),
                 getattr(self.detector, "name", "motion_only"))

    def _start_camera(self, cam) -> None:
        an = CameraAnalyzer(cam, self.cfg.hours_for(cam), self.cfg.detection,
                            self.detector)
        self.analyzers[cam.id] = an
        w = CameraWorker(cam.id, cam.name,
                         url_provider=lambda cid=cam.id: self.rtsp_url_for(cid),
                         sample_fps=self.cfg.detection.sample_fps,
                         on_frame=lambda f, cid=cam.id: self._on_frame(cid, f))
        self.workers[cam.id] = w
        w.start()

    def _start_device_sync(self) -> None:
        """Heartbeat + config pull + (optional) live view. Never fatal."""
        try:
            from . import live
            from .device import DeviceClient, DeviceSync
            from .tasks import GatewayTasks
            caps = ["gateway"]
            if live.available():
                self.live = live.LiveAnswerer(self.cfg.base_url, self.frame_source_for)
                caps.append("live")
            client = DeviceClient(self.cfg.base_url, timeout=self.cfg.sending.timeout_s)
            self.tasks = GatewayTasks(client, lambda: self.store.get(SITE_TOKEN),
                                      self.store, on_checked=self.on_camera_checked)
            self.sync = DeviceSync(
                client, self.device_tokens, caps, self.apply_server_config,
                on_live=(self.live.handle if self.live else None),
                tasks=self.tasks, camera_ids=self.server_camera_ids)
            self.sync.start()
        except Exception:
            log.exception("device sync could not start (monitoring continues)")
            self.sync = None

    def stop(self) -> None:
        if self.sync:
            self.sync.stop()
        if self.tasks:
            self.tasks.stop()
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
        self.latest[cam_id] = frame          # live view reads the newest frame
        an = self.analyzers.get(cam_id)
        if an is None:
            return
        trig = an.process(frame)
        if trig is None:
            return
        self.handle_trigger(cam_id, trig)

    def handle_trigger(self, cam_id: str, trig) -> bool:
        """Apply cooldown, encode the one snapshot, queue. Returns True if queued."""
        cam = self.cfg.camera(cam_id)
        if cam is not None and not cam.enabled:
            return False                     # the owner switched it off
        cool = (cam.tuning or {}).get("cooldown_s") if cam is not None else None
        if not self.cooldown.allow((cam_id, trig.type), cool):
            return False
        snap = None
        if self.cfg.sending.snapshot_mode != "never":
            try:
                snap = payload.encode_snapshot(
                    trig.frame, max_bytes=self.cfg.sending.snapshot_max_kb * 1024,
                    zone=cam.cash_zone() if cam else None)
            except ValueError:
                snap = None
        event = payload.build_event(trig.type, trig.signals, camera_id=cam_id,
                                    at=trig.at)
        if cam is not None and cam.server_id is not None:
            event["server_camera_id"] = int(cam.server_id)
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
            "live_view": bool(self.live),
            "heartbeat_online": self.sync.online if self.sync else None,
            "gateway_state": self.tasks.state if self.tasks else "idle",
            "gateway_last": self.tasks.last if self.tasks else None,
        }
