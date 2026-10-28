"""Gateway task runner: the owner adds a camera in the app, the server queues a
`check` (or a LAN `discover`) task, and this PC — which is on the shop's LAN —
runs it and posts the result.

  heartbeat -> tasks_pending > 0 (or every ~60 s anyway)
    GET  shop/gateway/tasks
    -> save the camera secret in the encrypted SecretStore FIRST (the server
       wipes it as soon as it hands it out), then queue the task
    worker thread (one task at a time): compat.run_check / run_discover
    POST shop/gateway/tasks/<id>/result  (result JSON + at most one JPEG),
         retried with backoff on network failure, never fatal
    successful check with a server camera id -> local CameraConfig added /
         updated (credential-free URL in config.json; secret stays in the store)

Nothing in here may crash the device-sync loop, and no secret is ever posted
or logged (results go through compat.sanitize()).
"""
from __future__ import annotations

import collections
import logging
import queue
import threading
import time
from typing import Callable, Optional

from . import compat
from . import siren as siren_mod
from .config import AppConfig, CameraConfig, clean_source, split_rtsp_credentials

log = logging.getLogger(__name__)

ACTIONS = ("check", "discover", "siren")
POLL_EVERY_S = 60.0
RETRY_DELAYS = (2.0, 5.0, 15.0)     # max 3 retries after the first attempt
MAX_TASKS_PER_POLL = 10


def secret_key(server_camera_id) -> str:
    return "cam_secret:%s" % server_camera_id


def user_key(server_camera_id) -> str:
    return "cam_user:%s" % server_camera_id


def local_cam_id(server_camera_id) -> str:
    return "srv%s" % int(server_camera_id)


def upsert_camera(cfg: AppConfig, server_id: int, request: dict, stream_url: str,
                  name: Optional[str] = None) -> CameraConfig:
    """Add or update the local camera for a server camera after a good check.
    `stream_url` must be credential-free (asserted)."""
    clean, u, p = split_rtsp_credentials(stream_url)
    assert u is None and p is None, "credentials must not reach config.json"
    cam = next((c for c in cfg.cameras if c.server_id == int(server_id)), None)
    src = clean_source({k: v for k, v in (request or {}).items()
                        if k not in ("secret", "username", "rtsp_url")})
    if cam is None:
        cam = CameraConfig(id=local_cam_id(server_id),
                           name=(name or "Camera %d" % int(server_id))[:120],
                           rtsp_url=clean, server_id=int(server_id), source=src)
        cfg.cameras.append(cam)
    else:
        cam.rtsp_url = clean
        cam.source = src or cam.source
        if name:
            cam.name = name[:120]
    return cam


class GatewayTasks:
    def __init__(self, client, site_token: Callable[[], Optional[str]], store, *,
                 on_checked: Optional[Callable[[dict, "compat.CheckOutcome"], None]] = None,
                 check: Callable = compat.run_check,
                 discover: Callable = compat.run_discover,
                 siren: Callable = siren_mod.hikvision_siren,
                 poll_every_s: float = POLL_EVERY_S,
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep,
                 threaded: bool = True):
        self.client = client
        self.site_token = site_token
        self.store = store
        self.on_checked = on_checked
        self.check = check
        self.discover = discover
        self.siren = siren
        self.poll_every_s = float(poll_every_s)
        self.clock = clock
        self.sleep = sleep
        self.threaded = threaded
        self._q: "queue.Queue[dict]" = queue.Queue()
        self._seen = collections.deque(maxlen=200)
        self._last_poll: Optional[float] = None
        self._worker: Optional[threading.Thread] = None
        self._halt = threading.Event()
        self._lock = threading.Lock()
        # for the UI: state idle|check|discover; last = {action, ok, camera_id, at}
        self.state = "idle"
        self.last: Optional[dict] = None

    # ------------------------------------------------------------- polling
    def maybe_poll(self, tasks_pending: int = 0) -> int:
        now = self.clock()
        if tasks_pending > 0 or self._last_poll is None or \
                now - self._last_poll >= self.poll_every_s:
            return self.poll()
        return 0

    def poll(self) -> int:
        """Fetch tasks, save their secrets, queue them. -> tasks queued."""
        self._last_poll = self.clock()
        tok = self.site_token()
        if not tok:
            return 0
        st, d = self.client.gateway_tasks(tok)
        if st != 200 or not isinstance(d, dict):
            return 0
        n = 0
        rows = d.get("tasks") if isinstance(d.get("tasks"), list) else []
        for t in rows[:MAX_TASKS_PER_POLL]:
            task = self._accept(t)
            if task is not None:
                self._q.put(task)
                n += 1
        if n:
            self._ensure_worker()
        return n

    def _accept(self, t) -> Optional[dict]:
        if not isinstance(t, dict):
            return None
        try:
            tid = int(t.get("id"))
        except (TypeError, ValueError):
            return None
        with self._lock:
            if tid in self._seen:
                return None
            self._seen.append(tid)
        action = str(t.get("action") or "")
        cam = t.get("camera_id")
        try:
            cam = int(cam) if cam is not None else None
        except (TypeError, ValueError):
            cam = None
        req = dict(t.get("request") or {}) if isinstance(t.get("request"), dict) else {}
        secret = req.pop("secret", None) or None
        if action == "check":
            if req.get("rtsp_url"):
                clean, u, p = split_rtsp_credentials(str(req["rtsp_url"]))
                req["rtsp_url"] = clean
                if u and not req.get("username"):
                    req["username"] = u
                secret = p or secret
            if cam is not None:
                # the server has already forgotten it: save it before anything
                if secret:
                    self.store.set(secret_key(cam), secret)
                if req.get("username"):
                    self.store.set(user_key(cam), str(req["username"]))
        return {"id": tid, "action": action, "camera_id": cam, "request": req,
                "name": str(t.get("name") or "")[:120] or None,
                # only for a camera-less check: memory only, never stored
                "_secret": secret if cam is None else None}

    # -------------------------------------------------------------- worker
    def _ensure_worker(self) -> None:
        if not self.threaded:
            while not self._q.empty():
                self.run_one(self._q.get())
            return
        if self._worker is None or not self._worker.is_alive():
            self._worker = threading.Thread(target=self._loop, name="gateway-tasks",
                                            daemon=True)
            self._worker.start()

    def stop(self) -> None:
        self._halt.set()

    def _loop(self) -> None:
        while not self._halt.is_set():
            try:
                task = self._q.get(timeout=30)
            except queue.Empty:
                continue
            try:
                self.run_one(task)
            except Exception:
                log.exception("gateway task failed")

    def run_one(self, task: dict) -> bool:
        """Run one task and post its result. -> True when the result was posted."""
        action, cam = task.get("action"), task.get("camera_id")
        secret = task.get("_secret")
        snap = None
        self.state = action if action in ACTIONS else "idle"
        try:
            if action == "check":
                req = dict(task.get("request") or {})
                if cam is not None:
                    secret = secret or self.store.get(secret_key(cam))
                    req["username"] = req.get("username") or self.store.get(user_key(cam))
                req["secret"] = secret
                out = self.check(req)
                result, snap = out.result, out.snapshot
                if out.ok and cam is not None:
                    if out.user:
                        self.store.set(user_key(cam), out.user)
                    if self.on_checked is not None:
                        try:
                            self.on_checked(task, out)
                        except Exception:
                            log.exception("adding the checked camera failed")
            elif action == "discover":
                result = self.discover(task.get("request") or {})
            elif action == "siren" and cam is not None:
                # cctvx: the owner tapped "Siren" — the password never left
                # this PC's encrypted store
                req = dict(task.get("request") or {})
                secret = self.store.get(secret_key(cam))
                result = self.siren(str(req.get("host") or ""),
                                    int(req.get("http_port") or 80),
                                    self.store.get(user_key(cam)), secret,
                                    int(req.get("seconds") or 15),
                                    int(req.get("channel") or 1))
            else:
                result = {"ok": False, "steps": [], "code": "not_supported",
                          "detail": "unknown action"}
        except Exception as exc:
            log.warning("gateway task %s crashed: %s", task.get("id"), type(exc).__name__)
            result = {"ok": False, "steps": [], "code": "internal_error",
                      "detail": type(exc).__name__}
        result = compat.sanitize(result, [secret])
        if snap is not None and snap[:3] != b"\xff\xd8\xff":
            snap = None                    # only ever a JPEG
        posted = self._post(task["id"], result, snap)
        self.state = "idle"
        self.last = {"action": action, "ok": bool(result.get("ok")),
                     "camera_id": cam, "at": time.time(),
                     "count": len(result.get("discovered") or [])
                     if action == "discover" else None}
        if not posted:
            with self._lock:               # let a later poll pick it up again
                try:
                    self._seen.remove(task["id"])
                except ValueError:
                    pass
        return posted

    def _post(self, task_id: int, result: dict, snap: Optional[bytes]) -> bool:
        tok = self.site_token()
        if not tok:
            return False
        for attempt in range(len(RETRY_DELAYS) + 1):
            st = self.client.post_task_result(tok, task_id, result, snap)
            if 200 <= st < 300:
                return True
            if 400 <= st < 500 and st not in (408, 425, 429):
                log.warning("server refused task %s result (HTTP %d)", task_id, st)
                return True                # retrying will not help; do not rerun
            if attempt < len(RETRY_DELAYS):
                self.sleep(RETRY_DELAYS[attempt])
        log.warning("could not post task %s result; will retry on a later poll",
                    task_id)
        return False
