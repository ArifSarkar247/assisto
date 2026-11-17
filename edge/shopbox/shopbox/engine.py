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

import uuid

from . import clip as clipmod
from . import paths, payload
from .analyzer import CameraAnalyzer

# cctvdet: zone detections + tamper get a 10 s clip and a per-zone cooldown
DET_CLIP_TYPES = frozenset({payload.GATE_PERSON, payload.LOITERING,
                            payload.POST_EMPTY, payload.GATE_OPEN,
                            payload.CAMERA_HEALTH, payload.CROWD,
                            payload.VEHICLE_IN_OUT, payload.PARKING_OVERSTAY,
                            payload.WRONG_PARKING})
from .camera import CameraWorker
from .client import (CLIP_GIVE_UP_S, DROP, SENT, UNAUTHORIZED, ClipClient,
                     ClipSender, IngestClient, Sender)
from .config import AppConfig, join_rtsp_credentials
from .cooldown import Cooldown, RateBudget
from .outbox import Outbox
from .person import load_detector
from .secure_store import SITE_TOKEN, SecretStore, cam_key
from .thresholds import T as SHARED

log = logging.getLogger(__name__)

# cctvx: a camera counts as live when it delivered a frame this recently
LIVE_FRAME_S = 120.0


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
            threads=cfg.detection.detector_threads,
            low_memory=bool(getattr(cfg.detection, "low_memory", False)))
        s = cfg.sending
        self.outbox = Outbox(paths.path("outbox"), max_items=s.queue_max_items,
                             max_bytes=s.queue_max_mb * 1024 * 1024,
                             max_age_s=s.queue_max_age_h * 3600)
        self.cooldown = Cooldown(s.cooldown_s)
        # cashguard: encrypted 3-5 s clips for cash-zone alerts (only once
        # the server config names someone to seal them for)
        self.clips = clipmod.ClipRecorder(on_ready=self._on_clip_ready)
        self._long_refs: set = set()      # cctvdet: refs of 10 s detection clips
        self.clip_outbox = Outbox(paths.path("clips"), max_items=40,
                                  max_bytes=40 * 1024 * 1024,
                                  max_age_s=CLIP_GIVE_UP_S, ext=".bin")
        self.clip_sender: Optional[ClipSender] = None
        self.workers: Dict[str, CameraWorker] = {}
        self.analyzers: Dict[str, CameraAnalyzer] = {}
        self.sender: Optional[Sender] = None
        self.sync = None                 # device.DeviceSync (heartbeat/config)
        self.live = None                 # live.LiveAnswerer when aiortc is present
        self.latest: Dict[str, object] = {}   # cam_id -> latest analysis frame
        self.running = False
        # gboxlinux: power / internet events, the speaker, DVR health
        self.box = None                  # boxstate.BoxMonitor
        self.speaker = None              # speaker.Speaker
        self.dvr = None                  # dvrhealth.DvrHealth
        self.profile = "full"
        self.started_at: Optional[float] = None
        self._url_calls: Dict[str, int] = {}
        self._sub_ok: Dict[str, bool] = {}

    # ------------------------------------------------------------ credentials
    def tokens_for(self, camera_id: Optional[str]):
        site = self.store.get(SITE_TOKEN)
        cam = self.store.get(cam_key(camera_id, "token")) if camera_id else None
        return site, cam

    def rtsp_url_for(self, cam_id: str) -> str:
        url = camera_url(self.cfg, self.store, cam_id)
        if not getattr(self.cfg.detection, "prefer_substream", False):
            return url
        # gboxlinux (2 GB Pi): the sub-stream, unless it never delivered a
        # frame in 3 tries -> back to the URL the owner gave
        from .vendors import sub_stream_url
        n = self._url_calls.get(cam_id, 0) + 1
        self._url_calls[cam_id] = n
        w = self.workers.get(cam_id)
        if w is not None and getattr(w, "last_frame_at", None):
            self._sub_ok.setdefault(cam_id, True)
        if n > 3 and not self._sub_ok.get(cam_id):
            return url
        return sub_stream_url(url)

    def has_tokens(self) -> bool:
        return bool(self.store.get(SITE_TOKEN) or any(
            self.store.get(cam_key(c.id, "token")) for c in self.cfg.cameras))

    def camera_health(self, cam_id: str) -> Optional[dict]:
        """gboxlinux: the heartbeat health of a code-paired camera — the box
        has had no picture from it for cam_lost_s (shared with the phone)."""
        cam = self.cfg.camera(cam_id)
        if cam is None or not cam.guard or not cam.enabled or not self.running:
            return None
        w = self.workers.get(cam_id)
        last = getattr(w, "last_frame_at", None) if w is not None else None
        ref = last if last is not None else self.started_at
        lost = ref is not None and time.time() - ref >= float(SHARED["cam_lost_s"])
        return {"box_cam_lost": bool(lost)}

    def play_token(self, cam_id: Optional[str]):
        """(token, server camera id) to fetch the owner's warning clip."""
        tok = self.store.get(cam_key(cam_id, "token")) if cam_id else None
        if tok:
            return tok, None
        cam = self.cfg.camera(cam_id) if cam_id else None
        return self.store.get(SITE_TOKEN), (cam.server_id if cam else None)

    def on_play(self, token: str, cam_id: str, tasks: list) -> None:
        if self.speaker is None:
            return
        self._play_cam = cam_id
        self.speaker.play_async(tasks)

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
        try:
            self.clips.configure(data.get("clip"))
        except Exception:
            log.exception("clip config ignored")
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

    def heartbeat_extra(self) -> dict:
        """cctvx: which server cameras REALLY deliver frames now (a dead
        stream -> "camera offline" on the server after 10 min) and when
        movement was last seen anywhere ("shop opened"). No images."""
        now = time.time()
        live = []
        for c in self.cfg.cameras:
            if c.server_id is None or not c.enabled:
                continue
            w = self.workers.get(c.id)
            t = getattr(w, "last_frame_at", None) if w is not None else None
            if t is not None and now - t <= LIVE_FRAME_S:
                live.append(int(c.server_id))
        motion = [a.last_motion_at for a in self.analyzers.values()
                  if getattr(a, "last_motion_at", None)]
        out = {"live_ids": live} if self.running else {}
        if motion:
            out["motion_at"] = round(max(motion), 1)
        return out

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
        if not self.has_tokens():
            raise RuntimeError("not_paired")
        self.started_at = time.time()
        client = IngestClient(self.cfg.base_url, timeout=self.cfg.sending.timeout_s)
        self.sender = Sender(self.outbox, client, self.tokens_for,
                             RateBudget(self.cfg.sending.max_per_min, 60.0),
                             snapshot_mode=self.cfg.sending.snapshot_mode,
                             on_result=self._on_send_result)
        self.sender.start()
        try:
            self.clip_sender = ClipSender(
                self.clip_outbox, ClipClient(self.cfg.base_url,
                                             timeout=max(30.0, self.cfg.sending.timeout_s)),
                self.tokens_for)
            self.clip_sender.start()
        except Exception:
            log.exception("clip sender could not start (alerts continue)")
            self.clip_sender = None
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
        # cctvdet: a gate's remembered CLOSED picture survives a restart
        an.zrules.load_refs(self._load_refs(cam.id))
        an.on_refs_changed = lambda refs, cid=cam.id: self._save_refs(cid, refs)
        # cctvdet stage 2: the optional on-box plate reader (one per engine)
        if getattr(self, "_plates", None) is None:
            try:
                from .plates import PlateReader
                self._plates = PlateReader()
            except Exception:
                self._plates = False
        an.plates = self._plates if self._plates else None
        self.analyzers[cam.id] = an
        w = CameraWorker(cam.id, cam.name,
                         url_provider=lambda cid=cam.id: self.rtsp_url_for(cid),
                         sample_fps=self.cfg.detection.sample_fps,
                         on_frame=lambda f, cid=cam.id: self._on_frame(cid, f),
                         on_tap=lambda f, cid=cam.id: self._on_tap(cid, f),
                         tap_fps=float(self.clips.cfg.get("fps") or 5),
                         tap_active=lambda: self.clips.enabled)
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
            self._start_box_parts()
            if self.speaker is not None and self.speaker.player:
                caps.append("speaker")
            self.tasks = GatewayTasks(client, lambda: self.store.get(SITE_TOKEN),
                                      self.store, on_checked=self.on_camera_checked,
                                      speaker=self.speaker)
            self.sync = DeviceSync(
                client, self.device_tokens, caps, self.apply_server_config,
                on_live=(self.live.handle if self.live else None),
                tasks=self.tasks, camera_ids=self.server_camera_ids,
                extra=self.heartbeat_extra, health=self.camera_health,
                box=self.box, on_play=self.on_play)
            self.sync.start()
        except Exception:
            log.exception("device sync could not start (monitoring continues)")
            self.sync = None

    def _start_box_parts(self) -> None:
        """gboxlinux: power / internet watch, the speaker, DVR health. Each
        part is optional; none may stop monitoring."""
        try:
            from .boxstate import BoxMonitor
            self.box = BoxMonitor(queued_alerts=lambda: len(self.outbox))
            self.box.start()
        except Exception:
            log.exception("box monitor could not start")
            self.box = None
        try:
            from .speaker import Speaker, device_fetcher
            self._play_cam = None
            self.speaker = Speaker(device_fetcher(
                self.cfg.base_url, lambda: self.play_token(self._play_cam)))
        except Exception:
            log.exception("speaker could not start")
            self.speaker = None
        try:
            from .dvrhealth import DvrHealth
            self.dvr = DvrHealth(self.cfg, self._cam_creds, self.cfg.base_url,
                                 lambda: self.store.get(SITE_TOKEN) or next(
                                     iter(self.device_tokens().values()), None))
            self.dvr.start()
        except Exception:
            log.exception("DVR health could not start")
            self.dvr = None

    def _cam_creds(self, cam):
        from .tasks import secret_key, user_key
        user = self.store.get(cam_key(cam.id, "user"))
        pwd = self.store.get(cam_key(cam.id, "pass"))
        if cam.server_id is not None and not (user or pwd):
            user = self.store.get(user_key(cam.server_id))
            pwd = self.store.get(secret_key(cam.server_id))
        return user, pwd

    def stop(self) -> None:
        if self.box:
            self.box.stop()
        if self.dvr:
            self.dvr.stop()
        if self.clip_sender:
            self.clip_sender.stop()
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
    def _on_tap(self, cam_id: str, frame) -> None:
        self.clips.tap(cam_id, frame)
        if self.clips.jobs:
            self.clips.sweep()

    @staticmethod
    def _refs_path(cam_id: str) -> str:
        safe = "".join(c for c in str(cam_id) if c.isalnum() or c in "-_")[:40] or "cam"
        return paths.path("zone_refs_%s.json" % safe)

    def _load_refs(self, cam_id: str) -> dict:
        try:
            with open(self._refs_path(cam_id), encoding="utf-8") as f:
                d = json.load(f)
            return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save_refs(self, cam_id: str, refs: dict) -> None:
        try:
            with open(self._refs_path(cam_id), "w", encoding="utf-8") as f:
                json.dump(refs, f)
        except OSError:
            log.warning("gate picture could not be saved (kept in memory)")

    @staticmethod
    def wants_clip(trig) -> bool:
        """Cash-guard alerts get a clip: a hand/person at the cash zone, the
        motion-only cash-zone fallback, someone in a restricted zone, or a
        person in the cash zone after closing."""
        sig = trig.signals or {}
        if trig.type == "hand_in_cash_zone" or trig.type == "zone_intrusion":
            return True
        if trig.type in DET_CLIP_TYPES:     # cctvdet: 10 s clip
            return True
        if trig.type == "motion":
            return bool(sig.get("motion_in_zone"))
        if trig.type == "after_hours":
            return bool(sig.get("person_in_zone"))
        return False

    def _on_clip_ready(self, cam_id: str, clip_ref: str, frames) -> None:
        cfg = self.clips.cfg
        long_clip = clip_ref in self._long_refs
        self._long_refs.discard(clip_ref)
        try:
            if long_clip:
                # cctvdet: the 10 s detection clip (server: 2-12.5 s, <= 40 frames)
                built = clipmod.build_clip(frames, float(cfg.get("fps") or 5),
                                           cfg.get("recipients") or [],
                                           int(cfg.get("max_kb") or 900) * 1024,
                                           min_s=3.0, max_s=clipmod.DET_CLIP_S + 0.5,
                                           max_frames=clipmod.DET_CLIP_MAX_FRAMES)
            else:
                built = clipmod.build_clip(frames, float(cfg.get("fps") or 5),
                                           cfg.get("recipients") or [],
                                           int(cfg.get("max_kb") or 900) * 1024)
        except Exception:
            log.exception("clip could not be sealed")
            built = None
        if built is None:
            log.info("clip %s skipped (too short / nobody to seal for)", clip_ref[:8])
            return
        ct, meta = built
        cam = self.cfg.camera(cam_id)
        item = {"clip_ref": clip_ref, "camera_id": cam_id, "meta": meta}
        if cam is not None and cam.server_id is not None:
            item["server_camera_id"] = int(cam.server_id)
        self.clip_outbox.put(item, ct)
        log.info("clip queued: %d frames, %.1f s, %d bytes (sealed)",
                 meta["frames"], meta["duration_s"], len(ct))
        if self.clip_sender:
            self.clip_sender.wake()

    def _on_frame(self, cam_id: str, frame) -> None:
        self.latest[cam_id] = frame          # live view reads the newest frame
        an = self.analyzers.get(cam_id)
        if an is None:
            return
        trig = an.process(frame)
        if trig is not None:
            self.handle_trigger(cam_id, trig)
        for x in an.take_extra():         # cctvdet: zone detections / tamper
            self.handle_trigger(cam_id, x)

    def handle_trigger(self, cam_id: str, trig) -> bool:
        """Apply cooldown, encode the one snapshot, queue. Returns True if queued."""
        cam = self.cfg.camera(cam_id)
        if cam is not None and not cam.enabled:
            return False                     # the owner switched it off
        cool = (cam.tuning or {}).get("cooldown_s") if cam is not None else None
        if cool is None and cam is not None and cam.guard:
            # the phone Guard Box's cool-downs (guard_thresholds.json)
            cool = float(SHARED["person_cooldown_s"] if trig.type in (
                payload.PERSON_DETECTED, payload.ZONE_INTRUSION, payload.LINE_CROSSING)
                else SHARED["motion_cooldown_s"])
        key = (cam_id, trig.type)
        if trig.type in DET_CLIP_TYPES:
            # cctvdet: one per zone (a gate and a post may both be busy)
            key = (cam_id, trig.type, str((trig.signals or {}).get("zone") or ""))
        if not self.cooldown.allow(key, cool):
            return False
        snap = None
        if self.cfg.sending.snapshot_mode != "never":
            try:
                snap = payload.encode_snapshot(
                    trig.frame, max_bytes=self.cfg.sending.snapshot_max_kb * 1024,
                    zone=cam.cash_zone() if cam else None)
            except ValueError:
                snap = None
        signals = trig.signals
        if cam is not None and cam.guard:
            from .sysinfo import platform_name
            signals = dict(signals, source="guard_box_%s" % platform_name())
        event = payload.build_event(trig.type, signals, camera_id=cam_id,
                                    at=trig.at)
        if cam is not None and cam.server_id is not None:
            event["server_camera_id"] = int(cam.server_id)
        if self.clips.enabled and self.wants_clip(trig):
            ref = uuid.uuid4().hex
            if trig.type in DET_CLIP_TYPES:
                self._long_refs.add(ref)
                ok = self.clips.start(cam_id, ref, trig.at, seconds=clipmod.DET_CLIP_S,
                                      pre_s=clipmod.DET_CLIP_PRE_S)
            else:
                ok = self.clips.start(cam_id, ref, trig.at)
            if ok:
                event["clip_ref"] = ref
            else:
                self._long_refs.discard(ref)
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
            "profile": self.profile,
            "speaker": bool(self.speaker and self.speaker.player),
            "dvr_health": ("off" if not (self.dvr and self.dvr.available)
                           else (self.dvr.last or "waiting")),
            "box_events_waiting": len(self.box.queue) if self.box else 0,
            "internet_down_since": self.box.net.down_since if self.box else None,
            "heartbeat_online": self.sync.online if self.sync else None,
            "gateway_state": self.tasks.state if self.tasks else "idle",
            "gateway_last": self.tasks.last if self.tasks else None,
            "clips": {"enabled": self.clips.enabled,
                      "queued": len(self.clip_outbox),
                      "sent": self.clip_sender.sent if self.clip_sender else 0,
                      "dropped": self.clip_sender.dropped if self.clip_sender else 0},
        }
