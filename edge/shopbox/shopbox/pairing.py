"""gboxlinux — pair a camera of this box with the owner's account the SAME
way the phone Guard Box does: the owner opens Assisto -> CCTV -> "Add phone
camera / Guard Box", which shows a QR and a short code; on the box the owner
types the code (or pastes the QR's link). POST shop/phonecam/claim answers a
CAMERA token, kept encrypted on the box; the server keeps no camera password.

Also adds a camera from its RTSP address: the user name and password are
split off the URL and stored encrypted; config.json keeps the clean URL.
"""
from __future__ import annotations

import re
from typing import Optional, Tuple
from urllib.parse import urljoin, urlsplit

from . import sysinfo
from .config import AppConfig, CameraConfig, split_rtsp_credentials
from .secure_store import cam_key

CLAIM_PATH = "shop/phonecam/claim"

# (code, Bangla, English) for the owner-facing messages
MESSAGES = {
    "ok": ("যুক্ত হয়েছে", "Paired"),
    "bad_code": ("কোডটি ভুল বা মেয়াদ শেষ। মালিকের ফোনে নতুন কোড দেখুন।",
                 "Wrong or expired code. Check the new code on the owner's phone."),
    "code_used": ("এই কোড আগেই ব্যবহার হয়েছে। মালিকের ফোনে নতুন কোড নিন।",
                  "This code was already used. Get a new code on the owner's phone."),
    "camera_cap": ("মালিকের প্ল্যানে আর ক্যামেরা যোগ করা যাবে না — প্ল্যান বাড়ান বা ক্রেডিট নিন।",
                   "The owner's plan has no room for another camera — upgrade or add credits."),
    "rate_limited": ("অনেকবার ভুল কোড। ১০ মিনিট পরে আবার চেষ্টা করুন।",
                     "Too many wrong codes. Try again in 10 minutes."),
    "feature_off": ("এই অ্যাকাউন্টে পাহারা বক্স এখনো চালু হয়নি।",
                    "Guard Box is not switched on for this account yet."),
    "offline": ("সার্ভারে পৌঁছানো যাচ্ছে না — ইন্টারনেট দেখে আবার চেষ্টা করুন।",
                "Cannot reach the server — check the internet and try again."),
}


def normalize_code(text: str) -> str:
    """The typed code ("12-AB3CD") or the QR's link, trimmed. The server
    (logic/phonecam.normalize_code) accepts the link, spaces, lower case and
    a missing dash, so nothing else is changed here."""
    return " ".join((text or "").split())[:200]


def guess_source(clean_url: str) -> Optional[dict]:
    """Brand + host from a clean RTSP URL (for DVR health and the sub-stream);
    None when it is not a brand we know."""
    try:
        p = urlsplit(clean_url)
    except ValueError:
        return None
    host = p.hostname or ""
    path = (p.path or "") + ("?" + p.query if p.query else "")
    vendor = None
    m = re.search(r"/Streaming/Channels/(\d+)", path, re.I)
    if m:
        vendor = "hikvision"
        ch = max(1, int(m.group(1)) // 100)
    else:
        m = re.search(r"realmonitor\?channel=(\d+)", path, re.I)
        if m:
            vendor = "dahua"
            ch = int(m.group(1))
    if not vendor or not host:
        return None
    return {"vendor": vendor, "host": host, "port": p.port or 554, "channel": ch}


def add_camera(cfg: AppConfig, store, name: str, rtsp_url: str,
               user: Optional[str] = None, password: Optional[str] = None) -> CameraConfig:
    clean, u, p = split_rtsp_credentials(rtsp_url)
    if not clean.lower().startswith(("rtsp://", "rtsps://")):
        raise ValueError("the camera address must start with rtsp://")
    cam = CameraConfig.new(name or "Camera", clean)
    cam.source = guess_source(clean)
    u = user or u
    p = password or p
    if u:
        store.set(cam_key(cam.id, "user"), u)
    if p:
        store.set(cam_key(cam.id, "pass"), p)
    cfg.cameras.append(cam)
    return cam


def claim(base_url: str, code: str, name: str, timeout: float = 20.0,
          session=None) -> Tuple[str, dict]:
    """-> (outcome code, server answer). outcome: ok | bad_code | code_used |
    camera_cap | rate_limited | feature_off | offline."""
    import requests

    low = base_url.lower()
    if not low.startswith("https://") and not low.startswith(
            ("http://127.0.0.1", "http://localhost")):
        raise ValueError("base URL must be https://")
    s = session or requests
    body = {"code": normalize_code(code), "name": (name or "")[:120],
            "model": sysinfo.device_model(), "platform": sysinfo.platform_name()}
    try:
        r = s.post(urljoin(base_url if base_url.endswith("/") else base_url + "/", CLAIM_PATH),
                   json=body, timeout=timeout, headers={"Accept": "application/json"})
    except requests.RequestException:
        return "offline", {}
    try:
        d = r.json()
    except ValueError:
        d = {}
    d = d if isinstance(d, dict) else {}
    if r.status_code in (200, 201) and d.get("camera_token"):
        return "ok", d
    code_ = str(d.get("code") or "")
    if r.status_code == 429:
        return "rate_limited", d
    if code_ in MESSAGES:
        return code_, d
    if r.status_code == 402:
        return "camera_cap", d
    if r.status_code in (403, 404):
        return "feature_off", d
    if r.status_code >= 500:
        return "offline", d
    return "bad_code", d


def pair_camera(cfg: AppConfig, store, cam: CameraConfig, code: str,
                session=None) -> str:
    """Claim `code` for local camera `cam`; on success the camera token is
    stored encrypted and the camera becomes a Guard Box camera."""
    out, d = claim(cfg.base_url, code, cam.name, timeout=cfg.sending.timeout_s,
                   session=session)
    if out != "ok":
        return out
    store.set(cam_key(cam.id, "token"), str(d["camera_token"]))
    cam.guard = True
    try:
        cam.server_id = int((d.get("camera") or {}).get("id"))
    except (TypeError, ValueError):
        pass
    site = (d.get("site") or {}).get("name")
    if site and not cfg.site_name:
        cfg.site_name = str(site)[:120]
    return "ok"


def message(code: str, lang: str = "bn") -> str:
    bn, en = MESSAGES.get(code, MESSAGES["bad_code"])
    return bn if lang == "bn" else en
