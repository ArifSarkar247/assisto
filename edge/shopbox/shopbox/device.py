"""Device control-plane calls (outbound HTTPS only): pair check, heartbeat and
config pull. The token travels in the `X-Shop-Token` header (or the JSON body)
— never in the URL, so it stays out of access logs.

  POST shop/pair/check   validate a site/camera token, get the shop name
  POST shop/heartbeat    "I'm alive" (+ caps) -> config_version, live_pending
  GET  shop/config       hours / enabled / zones v2 / tuning per camera
  GET  shop/gateway/tasks             camera checks / LAN discovery to run
  POST shop/gateway/tasks/<id>/result multipart: result JSON + one JPEG

`DeviceSync` runs the heartbeat loop in a daemon thread and applies the
owner's server-side settings (camera on/off, per-camera hours) to the local
config without touching anything the owner set up locally (RTSP, zones,
timezone, closed days).
"""
from __future__ import annotations

import logging
import threading
from typing import Callable, Dict, List, Optional
from urllib.parse import urljoin

from . import __version__

log = logging.getLogger(__name__)

PAIR_PATH = "shop/pair/check"
HEARTBEAT_PATH = "shop/heartbeat"
CONFIG_PATH = "shop/config"
TASKS_PATH = "shop/gateway/tasks"
TASK_RESULT_PATH = "shop/gateway/tasks/%d/result"


class DeviceClient:
    def __init__(self, base_url: str, timeout: float = 20.0, session=None):
        import requests

        low = base_url.lower()
        if not low.startswith("https://") and not low.startswith(
                "http://127.0.0.1") and not low.startswith("http://localhost"):
            raise ValueError("base URL must be https://")
        self.base = base_url if base_url.endswith("/") else base_url + "/"
        self.timeout = float(timeout)
        self.s = session or requests.Session()
        self.s.headers.update({"User-Agent": "AssistoShopBox/%s" % __version__,
                               "Accept": "application/json"})

    def _call(self, method: str, path: str, token: str, body: Optional[dict] = None):
        """-> (status, json_dict). status 0 = network error (offline)."""
        import requests

        url = urljoin(self.base, path)
        headers = {"X-Shop-Token": token}
        try:
            if method == "GET":
                r = self.s.get(url, headers=headers, timeout=self.timeout)
            else:
                r = self.s.post(url, json=body or {}, headers=headers,
                                timeout=self.timeout)
        except requests.RequestException:
            return 0, {}
        try:
            d = r.json()
        except ValueError:
            d = {}
        return r.status_code, d if isinstance(d, dict) else {}

    def pair_check(self, token: str):
        """-> ("ok"|"bad"|"offline"|"unsupported", site_name). "unsupported"
        means an older server without shop/pair/check (404)."""
        st, d = self._call("POST", PAIR_PATH, token)
        if st == 200:
            return "ok", str((d.get("site") or {}).get("name") or "")
        if st == 401:
            return "bad", ""
        if st == 404:
            return "unsupported", ""
        return "offline", ""

    def heartbeat(self, token: str, caps: List[str],
                  camera_ids: Optional[List[int]] = None,
                  extra: Optional[dict] = None):
        body = {"caps": list(caps), "platform": "windows", "version": __version__}
        if camera_ids:
            body["camera_ids"] = [int(x) for x in camera_ids][:64]
        if extra:
            # cctvx: live_ids (cameras delivering frames) + motion_at
            if isinstance(extra.get("live_ids"), list):
                body["live_ids"] = [int(x) for x in extra["live_ids"]][:64]
            if extra.get("motion_at"):
                body["motion_at"] = float(extra["motion_at"])
        return self._call("POST", HEARTBEAT_PATH, token, body)

    def config(self, token: str):
        return self._call("GET", CONFIG_PATH, token)

    def gateway_tasks(self, token: str):
        return self._call("GET", TASKS_PATH, token)

    def post_task_result(self, token: str, task_id: int, result: dict,
                         snapshot: Optional[bytes] = None) -> int:
        """multipart/form-data: `result` (JSON string) + optional `snapshot`
        (image/jpeg). -> HTTP status, 0 = network error."""
        import json

        import requests

        url = urljoin(self.base, TASK_RESULT_PATH % int(task_id))
        # (None, value) = a plain form field; always multipart/form-data
        files = {"result": (None, json.dumps(result, separators=(",", ":")))}
        if snapshot:
            files["snapshot"] = ("snapshot.jpg", snapshot, "image/jpeg")
        try:
            r = self.s.post(url, files=files,
                            headers={"X-Shop-Token": token}, timeout=self.timeout)
        except requests.RequestException:
            return 0
        return int(r.status_code)


def apply_server_camera(local_cam, server_cam: dict, site_hours: Optional[dict] = None
                        ) -> bool:
    """Merge the owner's server-side settings into a local CameraConfig. Only
    `enabled` and the per-camera open/close hours are taken from the server;
    the local timezone / closed days / zone / RTSP stay. Returns True when
    anything changed. Pure (no I/O) — unit-tested."""
    changed = False
    en = bool(server_cam.get("enabled", True))
    if local_cam.enabled != en:
        local_cam.enabled = en
        changed = True
    h = server_cam.get("hours") or None
    # the server falls back to site hours itself; only a camera-level override
    # that differs from the site's is stored per camera locally.
    if h and isinstance(h, dict) and h.get("open") and h.get("close"):
        if site_hours and h.get("open") == site_hours.get("open") and \
                h.get("close") == site_hours.get("close"):
            h = None
    if h:
        cur = dict(local_cam.hours or {})
        new = dict(cur)
        new["open"], new["close"] = str(h["open"]), str(h["close"])
        if new != cur:
            local_cam.hours = new
            changed = True
    # CCTV AI Watchman keys (optional: an older server simply omits them, and
    # then whatever was stored locally stays)
    from .config import clean_source
    from .zone import normalize_tuning, normalize_zones_v2

    if "zones" in server_cam:
        z = normalize_zones_v2(server_cam.get("zones"))
        if z != local_cam.zones_v2:
            local_cam.zones_v2 = z
            changed = True
    if "tuning" in server_cam:
        t = normalize_tuning(server_cam.get("tuning"))
        if t != local_cam.tuning:
            local_cam.tuning = t
            changed = True
    if "source" in server_cam:
        src = clean_source(server_cam.get("source"))
        if src and src != local_cam.source:
            local_cam.source = src
            changed = True
    return changed


def apply_server_site(app_cfg, site: dict) -> bool:
    """Server shop hours -> local default hours (open/close only)."""
    h = (site or {}).get("hours") or {}
    if not (h.get("open") and h.get("close")):
        return False
    cur = dict(app_cfg.hours or {})
    new = dict(cur)
    new["open"], new["close"] = str(h["open"]), str(h["close"])
    if new == cur:
        return False
    app_cfg.hours = new
    return True


class DeviceSync(threading.Thread):
    """Heartbeat every `every_s`; pull config when its version changes; hand
    pending live-view sessions to `on_live` (when live view is available)."""

    def __init__(self, client: DeviceClient, tokens: Callable[[], Dict[str, str]],
                 caps: List[str], on_config: Callable[[dict, Optional[str]], None],
                 on_live: Optional[Callable[[str, dict], None]] = None,
                 every_s: float = 20.0, tasks=None,
                 camera_ids: Optional[Callable[[], List[int]]] = None,
                 extra: Optional[Callable[[], dict]] = None):
        super().__init__(name="device-sync", daemon=True)
        self.client = client
        self.tokens = tokens        # () -> {local_camera_id or "": token}
        self.caps = list(caps)
        self.on_config = on_config
        self.on_live = on_live
        self.every_s = float(every_s)
        self.tasks = tasks          # tasks.GatewayTasks (camera checks) or None
        self.camera_ids = camera_ids  # () -> server camera ids captured here
        self.extra = extra            # () -> cctvx heartbeat extras
        self._halt = threading.Event()
        self._versions: Dict[str, str] = {}
        self.online: Optional[bool] = None
        self.unauthorized = False

    def stop(self) -> None:
        self._halt.set()

    def tick(self) -> None:
        """One heartbeat round (public for tests)."""
        any_ok = False
        pending = 0
        ids: List[int] = []
        if self.camera_ids is not None:
            try:
                ids = list(self.camera_ids() or [])
            except Exception:
                ids = []
        for cam_id, tok in (self.tokens() or {}).items():
            if not tok:
                continue
            # the site token reports the gateway cameras it captures
            ext = None
            if self.extra is not None and not cam_id:
                try:
                    ext = self.extra() or None
                except Exception:
                    ext = None
            st, d = (self.client.heartbeat(tok, self.caps, ids if not cam_id else None,
                                           ext) if ext else
                     self.client.heartbeat(tok, self.caps, ids if not cam_id else None))
            if st == 401:
                self.unauthorized = True
                continue
            if st != 200:
                continue
            any_ok = True
            self.unauthorized = False
            try:
                pending = max(pending, int(d.get("tasks_pending") or 0))
            except (TypeError, ValueError):
                pass
            ver = str(d.get("config_version") or "")
            if ver and self._versions.get(cam_id) != ver:
                cst, cfg = self.client.config(tok)
                if cst == 200:
                    self._versions[cam_id] = ver
                    try:
                        self.on_config(cfg, cam_id or None)
                    except Exception:
                        log.exception("applying server config failed")
            if self.on_live is not None:
                for s in d.get("live_pending") or []:
                    try:
                        self.on_live(tok, s)
                    except Exception:
                        log.exception("live session handler failed")
        self.online = any_ok if self.tokens() else None
        if self.tasks is not None and any_ok:
            try:
                self.tasks.maybe_poll(pending)
            except Exception:
                log.exception("gateway task poll failed")

    def run(self) -> None:
        while not self._halt.is_set():
            try:
                self.tick()
            except Exception:
                log.exception("heartbeat round failed")
            self._halt.wait(self.every_s)
