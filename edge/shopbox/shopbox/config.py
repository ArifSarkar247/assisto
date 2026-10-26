"""Non-secret configuration (config.json in the user config dir).

Secrets (enrollment token, RTSP username/password, camera tokens) are NOT here;
they live encrypted in secure_store. RTSP URLs are stored WITHOUT userinfo —
`split_rtsp_credentials()` strips `user:pass@` out of whatever the owner pastes.
"""
from __future__ import annotations

import json
import os
import threading
import uuid
from dataclasses import asdict, dataclass, field
from typing import List, Optional, Tuple
from urllib.parse import quote, unquote, urlsplit, urlunsplit

from . import paths
from .hours import Hours
from .zone import normalize_polygon, normalize_tuning, normalize_zones_v2

DEFAULT_BASE_URL = "https://api.lifeassisto.com/api/v1/"


@dataclass
class CameraConfig:
    id: str
    name: str
    rtsp_url: str                         # credentials stripped
    zone: List[List[float]] = field(default_factory=list)   # normalised polygon
    enabled: bool = True
    hours: Optional[dict] = None          # per-camera override of site hours
    # ---- CCTV AI Watchman (all optional; absent on older configs/servers)
    server_id: Optional[int] = None       # the server's ShopCamera id
    source: Optional[dict] = None         # vendor/host/port/channel/stream (no secret)
    zones_v2: Optional[dict] = None       # server zones v2 (normalised)
    tuning: Optional[dict] = None         # person_conf / motion_mult / cooldown_s

    @classmethod
    def new(cls, name: str, rtsp_url: str) -> "CameraConfig":
        return cls(id=uuid.uuid4().hex[:10], name=name.strip()[:120],
                   rtsp_url=rtsp_url.strip())

    @classmethod
    def from_dict(cls, d: dict) -> "CameraConfig":
        sid = d.get("server_id")
        return cls(id=str(d["id"]), name=str(d.get("name", ""))[:120],
                   rtsp_url=str(d.get("rtsp_url", "")),
                   zone=[list(p) for p in normalize_polygon(d.get("zone"))],
                   enabled=bool(d.get("enabled", True)),
                   hours=d.get("hours") or None,
                   server_id=int(sid) if str(sid).isdigit() else None,
                   source=clean_source(d.get("source")),
                   zones_v2=normalize_zones_v2(d.get("zones_v2")),
                   tuning=normalize_tuning(d.get("tuning")))

    def cash_zone(self) -> List[List[float]]:
        """The cash-drawer polygon: a v2 `cash` zone from the owner's app
        wins; otherwise the zone drawn locally on this PC."""
        for z in (self.zones_v2 or {}).get("zones") or []:
            if z.get("type") == "cash":
                return z["points"]
        return self.zone


SOURCE_KEYS = ("vendor", "host", "port", "onvif_port", "channel", "stream",
               "rtsp_path")


def clean_source(d) -> Optional[dict]:
    """Server camera `source` minus anything that is not a known, non-secret
    key (a secret must never reach config.json)."""
    if not isinstance(d, dict):
        return None
    out = {k: d[k] for k in SOURCE_KEYS
           if k in d and isinstance(d[k], (str, int)) and not isinstance(d[k], bool)}
    if "rtsp_path" in out:
        from .vendors import redact_url
        out["rtsp_path"] = redact_url(str(out["rtsp_path"]))[:300]
    return out or None


@dataclass
class DetectionConfig:
    sample_fps: float = 3.0           # frames analysed per second per camera
    frame_width: int = 640            # analysis frames are downscaled to this
    motion_min_area_frac: float = 0.002
    zone_motion_frac: float = 0.03    # >= this share of zone pixels changed
    person_score: float = 0.45
    zone_overlap: float = 0.15        # person box vs zone overlap to count
    confirm_frames: int = 2           # consecutive sampled frames required
    linger_s: float = 8.0             # in-zone this long => "lingering"
    detector_threads: int = 2


@dataclass
class SendingConfig:
    cooldown_s: float = 180.0         # per camera + event type
    max_per_min: int = 12             # global; server anon throttle is 30/min/IP
    snapshot_mode: str = "auto"       # auto | always | never
    snapshot_max_kb: int = 150
    queue_max_items: int = 200
    queue_max_mb: int = 40
    queue_max_age_h: float = 12.0
    timeout_s: float = 20.0


@dataclass
class AppConfig:
    base_url: str = DEFAULT_BASE_URL
    language: str = "bn"              # "bn" | "en" — whole UI in ONE language
    site_name: str = ""
    hours: dict = field(default_factory=lambda: Hours().to_dict())
    cameras: List[CameraConfig] = field(default_factory=list)
    detection: DetectionConfig = field(default_factory=DetectionConfig)
    sending: SendingConfig = field(default_factory=SendingConfig)
    auto_start: bool = True           # UI starts monitoring when opened

    # ----------------------------------------------------------- (de)serialise
    @classmethod
    def from_dict(cls, d: dict) -> "AppConfig":
        c = cls()
        c.base_url = normalize_base_url(d.get("base_url") or DEFAULT_BASE_URL)
        c.language = d.get("language") if d.get("language") in ("bn", "en") else "bn"
        c.site_name = str(d.get("site_name", ""))[:120]
        try:
            c.hours = Hours.from_dict(d.get("hours")).to_dict()
        except ValueError:
            c.hours = Hours().to_dict()
        c.cameras = [CameraConfig.from_dict(x) for x in d.get("cameras", [])
                     if isinstance(x, dict) and x.get("id")]
        c.detection = _merge(DetectionConfig(), d.get("detection"))
        c.sending = _merge(SendingConfig(), d.get("sending"))
        if c.sending.snapshot_mode not in ("auto", "always", "never"):
            c.sending.snapshot_mode = "auto"
        c.auto_start = bool(d.get("auto_start", True))
        return c

    def to_dict(self) -> dict:
        return asdict(self)

    def camera(self, cam_id: str) -> Optional[CameraConfig]:
        return next((c for c in self.cameras if c.id == cam_id), None)

    def hours_for(self, cam: CameraConfig) -> Hours:
        try:
            return Hours.from_dict(cam.hours or self.hours)
        except ValueError:
            return Hours.from_dict(self.hours)


def _merge(obj, d):
    if isinstance(d, dict):
        for k, v in d.items():
            if hasattr(obj, k) and v is not None:
                cur = getattr(obj, k)
                try:
                    setattr(obj, k, type(cur)(v))
                except (TypeError, ValueError):
                    pass
    return obj


def normalize_base_url(url: str) -> str:
    url = (url or DEFAULT_BASE_URL).strip()
    if not url.endswith("/"):
        url += "/"
    return url


def split_rtsp_credentials(url: str) -> Tuple[str, Optional[str], Optional[str]]:
    """'rtsp://u:p@host/x' -> ('rtsp://host/x', 'u', 'p'). Credentials are
    URL-decoded so special characters survive a round trip."""
    parts = urlsplit((url or "").strip())
    if parts.username is None and parts.password is None:
        return url.strip(), None, None
    host = parts.hostname or ""
    if ":" in host:                     # IPv6 literal
        host = "[%s]" % host
    netloc = host + (":%d" % parts.port if parts.port else "")
    clean = urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))
    return (clean, unquote(parts.username) if parts.username else None,
            unquote(parts.password) if parts.password else None)


def join_rtsp_credentials(url: str, user: Optional[str], password: Optional[str]) -> str:
    """Inverse of split: build the URL actually handed to FFmpeg (in memory
    only — never logged, never saved)."""
    if not user:
        return url
    parts = urlsplit(url)
    cred = quote(user, safe="")
    if password:
        cred += ":" + quote(password, safe="")
    return urlunsplit((parts.scheme, cred + "@" + parts.netloc, parts.path,
                       parts.query, parts.fragment))


class ConfigStore:
    """Load/save config.json atomically."""

    def __init__(self, path: Optional[str] = None):
        self.path = path or paths.path("config.json")
        self._lock = threading.Lock()

    def load(self) -> AppConfig:
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                return AppConfig.from_dict(json.load(f))
        except FileNotFoundError:
            return AppConfig()
        except (OSError, ValueError):
            # keep the broken file for support, start with defaults
            try:
                os.replace(self.path, self.path + ".broken")
            except OSError:
                pass
            return AppConfig()

    def save(self, cfg: AppConfig) -> None:
        with self._lock:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(cfg.to_dict(), f, ensure_ascii=False, indent=2)
            os.replace(tmp, self.path)
