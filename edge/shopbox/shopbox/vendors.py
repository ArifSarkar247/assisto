"""RTSP URL templates for the camera brands common in Bangladeshi shops, plus
credential redaction. Pure functions (no I/O) — unit-tested.

  imou / dahua  rtsp://admin:<secret>@host:port/cam/realmonitor?channel=<ch>&subtype=<0|1>
                (Imou: the user is always "admin", the secret is the device
                SAFETY CODE printed on the camera's label)
  hikvision     rtsp://<user>:<secret>@host:port/Streaming/Channels/<ch>01 (main)
                                                              /<ch>02 (sub)
  tapo          rtsp://<camera-account>:<secret>@host:554/stream1 (main) /stream2 (sub)
                (needs a "Camera Account" created in the Tapo app)
  ezviz         rtsp://admin:<verification code>@host:554/H.264 (main)
                                                  /h264/ch1/sub/av_stream (sub)
                (some models need "Local RTSP" / LAN live view switched on)
  onvif         resolved on the device via GetStreamUri (see onvif.py)
  rtsp          the owner's custom URL, as given

User and secret are URL-encoded (quote(safe="")) so characters like @ : / #
inside a password survive.
"""
from __future__ import annotations

import re
from typing import Iterable, Optional
from urllib.parse import quote, urlsplit, urlunsplit

VENDORS = ("imou", "dahua", "hikvision", "tapo", "ezviz", "onvif", "rtsp")
TEMPLATE_VENDORS = ("imou", "dahua", "hikvision", "tapo", "ezviz")
DEFAULT_RTSP_PORT = 554
# ONVIF HTTP port to try when the request does not name one.
DEFAULT_ONVIF_PORT = {"tapo": 2020}

_HOST_RE = re.compile(r"^[A-Za-z0-9.\-]{1,253}$|^\[?[0-9A-Fa-f:.]{2,45}\]?$")
_USERINFO_RE = re.compile(r"([a-zA-Z][a-zA-Z0-9+.\-]*://)[^/@\s]*@")


def clean_host(host: str) -> str:
    """Validate a camera host (IPv4/IPv6/hostname); returns it URL-ready."""
    h = str(host or "").strip()
    if not h or not _HOST_RE.match(h):
        raise ValueError("bad host")
    if ":" in h and not h.startswith("["):
        h = "[%s]" % h
    return h


def _port(port, default: int = DEFAULT_RTSP_PORT) -> int:
    try:
        p = int(port) if port not in (None, "") else default
    except (TypeError, ValueError):
        raise ValueError("bad port")
    if not 1 <= p <= 65535:
        raise ValueError("bad port")
    return p


def _channel(ch) -> int:
    try:
        c = int(ch) if ch not in (None, "") else 1
    except (TypeError, ValueError):
        raise ValueError("bad channel")
    if not 1 <= c <= 256:
        raise ValueError("bad channel")
    return c


def _cred(user: Optional[str], secret: Optional[str]) -> str:
    if not user:
        return ""
    c = quote(str(user), safe="")
    if secret:
        c += ":" + quote(str(secret), safe="")
    return c + "@"


def stream_path(vendor: str, channel=1, stream: str = "main") -> str:
    """URL path (+query) for a template vendor, WITHOUT host or credentials."""
    v = str(vendor or "").lower()
    ch = _channel(channel)
    sub = str(stream or "main").lower() == "sub"
    if v in ("imou", "dahua"):
        return "/cam/realmonitor?channel=%d&subtype=%d" % (ch, 1 if sub else 0)
    if v == "hikvision":
        return "/Streaming/Channels/%d%s" % (ch, "02" if sub else "01")
    if v == "tapo":
        return "/stream2" if sub else "/stream1"
    if v == "ezviz":
        return "/h264/ch1/sub/av_stream" if sub else "/H.264"
    raise ValueError("no template for vendor %r" % vendor)


def default_user(vendor: str, username: Optional[str]) -> Optional[str]:
    v = str(vendor or "").lower()
    if v in ("imou", "ezviz"):
        return "admin"              # fixed by the vendor
    if v == "dahua":
        return username or "admin"
    return username or None


def build_rtsp_url(vendor: str, host: str = "", port=None, channel=1,
                   stream: str = "main", username: Optional[str] = None,
                   secret: Optional[str] = None,
                   rtsp_url: Optional[str] = None) -> str:
    """The credentialed RTSP URL for FFmpeg. In memory only: never log it
    (use `redact_url`) and never save it (config keeps the clean form)."""
    v = str(vendor or "").lower()
    if v == "rtsp":
        url = str(rtsp_url or "").strip()
        if not url.lower().startswith(("rtsp://", "rtsps://")):
            raise ValueError("custom URL must start with rtsp://")
        parts = urlsplit(url)
        if (parts.username is None) and username:
            return urlunsplit((parts.scheme, _cred(username, secret) + parts.netloc,
                               parts.path, parts.query, parts.fragment))
        return url
    if v not in TEMPLATE_VENDORS:
        raise ValueError("unknown vendor %r" % vendor)
    h = clean_host(host)
    p = _port(port)
    return "rtsp://%s%s:%d%s" % (_cred(default_user(v, username), secret), h, p,
                                 stream_path(v, channel, stream))


def redact_url(url: str) -> str:
    """rtsp://user:pass@host/x -> rtsp://host/x (userinfo removed entirely)."""
    return _USERINFO_RE.sub(r"\1", str(url or ""))


def url_path(url: str) -> str:
    """Path + query of a URL, never credentials: '/cam/realmonitor?channel=1'."""
    parts = urlsplit(redact_url(url))
    return parts.path + ("?" + parts.query if parts.query else "")


def redact_text(text: str, secrets: Iterable[Optional[str]] = ()) -> str:
    """Strip URL userinfo and every given secret (raw and URL-encoded)."""
    out = redact_url(str(text or ""))
    for s in sorted({str(x) for x in secrets if x}, key=len, reverse=True):
        for form in {s, quote(s, safe="")}:
            if form:
                out = out.replace(form, "***")
    return out
