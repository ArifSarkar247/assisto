"""Camera compatibility check ("will this camera work with Assisto?") and LAN
discovery, run on the shop PC when the server hands it a gateway task.

run_check(request) walks five honest steps and NEVER claims more than it saw:

  reachable  TCP connect to the camera (RTSP port, or the ONVIF port for
             vendor "onvif"), 3 s
  auth       RTSP DESCRIBE with the credentials (Digest/Basic): 200 = ok,
             401 = auth_failed. Only an actual 401 is reported as a wrong
             password; anything unclear stays ok=null.
  stream     open with OpenCV/FFmpeg (10 s), read frames for ~2 s, measure
             resolution + fps
  snapshot   ONE JPEG, long side <= 640 px, quality ~75
  events     ONVIF GetEventProperties when ONVIF answers; otherwise null
             (code not_checked) — brand cloud/webhook push is NOT verified here

Everything that goes back to the server is passed through `sanitize()`, which
removes URL credentials and every secret value from every string.
"""
from __future__ import annotations

import base64
import hashlib
import logging
import re
import socket
import time
from typing import Callable, Dict, List, Optional, Tuple
from urllib.parse import urlsplit

from . import onvif as onvif_mod
from . import vendors
from .config import join_rtsp_credentials, split_rtsp_credentials

log = logging.getLogger(__name__)

STEP_KEYS = ("reachable", "auth", "stream", "snapshot", "events")
TCP_TIMEOUT_S = 3.0
STREAM_TIMEOUT_S = 10.0
MEASURE_S = 2.0
SNAPSHOT_LONG_SIDE = 640
SNAPSHOT_QUALITY = 75


# ---------------------------------------------------------------- helpers
def tcp_connect(host: str, port: int, timeout: float = TCP_TIMEOUT_S) -> None:
    """Raises OSError/socket.timeout when the port is not reachable."""
    h = host.strip("[]")
    s = socket.create_connection((h, int(port)), timeout=timeout)
    s.close()


def _md5(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def _parse_auth_header(value: str) -> Tuple[str, Dict[str, str]]:
    scheme, _, rest = value.strip().partition(" ")
    params = dict(re.findall(r'(\w+)\s*=\s*"?([^",]*)"?', rest))
    return scheme.lower(), params


def rtsp_auth_header(method: str, uri: str, user: str, secret: str,
                     www_authenticate: str) -> Optional[str]:
    scheme, p = _parse_auth_header(www_authenticate)
    if scheme == "basic":
        return "Basic " + base64.b64encode(
            ("%s:%s" % (user, secret)).encode("utf-8")).decode("ascii")
    if scheme == "digest" and p.get("nonce") is not None:
        realm = p.get("realm", "")
        resp = _md5("%s:%s:%s" % (_md5("%s:%s:%s" % (user, realm, secret)),
                                  p["nonce"], _md5("%s:%s" % (method, uri))))
        return ('Digest username="%s", realm="%s", nonce="%s", uri="%s", '
                'response="%s"' % (user, realm, p["nonce"], uri, resp))
    return None


def _read_response(sock) -> Tuple[int, Dict[str, str], str]:
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 65536:
            break
    head, _, body = buf.partition(b"\r\n\r\n")
    lines = head.decode("latin-1", "replace").split("\r\n")
    m = re.match(r"RTSP/\d\.\d\s+(\d{3})", lines[0] if lines else "")
    if not m:
        raise ValueError("not an RTSP response")
    headers: Dict[str, str] = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        headers.setdefault(k.strip().lower(), v.strip())
    try:
        n = min(int(headers.get("content-length", "0")), 65536)
    except ValueError:
        n = 0
    while len(body) < n:
        chunk = sock.recv(4096)
        if not chunk:
            break
        body += chunk
    return int(m.group(1)), headers, body[:n].decode("utf-8", "replace")


def rtsp_describe(clean_url: str, user: Optional[str], secret: Optional[str],
                  timeout: float = 5.0,
                  connect: Callable = socket.create_connection) -> Tuple[int, str]:
    """RTSP DESCRIBE (with one auth retry) -> (status, sdp). Raises OSError /
    socket.timeout / ValueError on transport problems. The request line uses
    the credential-free URL; credentials only travel in the auth header."""
    parts = urlsplit(clean_url)
    host, port = parts.hostname, parts.port or 554
    sock = connect((host, port), timeout)
    try:
        sock.settimeout(timeout)
        req = ("DESCRIBE %s RTSP/1.0\r\nCSeq: %d\r\nAccept: application/sdp\r\n"
               "User-Agent: AssistoShopBox\r\n%s\r\n")
        sock.sendall((req % (clean_url, 1, "")).encode("utf-8"))
        status, headers, body = _read_response(sock)
        if status == 401 and user:
            auth = rtsp_auth_header("DESCRIBE", clean_url, user, secret or "",
                                    headers.get("www-authenticate", ""))
            if auth:
                msg = (req % (clean_url, 2, "Authorization: %s\r\n" % auth)).encode("utf-8")
                try:
                    sock.sendall(msg)
                    status, headers, body = _read_response(sock)
                except (OSError, ValueError):
                    # many cameras close the connection after a 401: reconnect
                    try:
                        sock.close()
                    except OSError:
                        pass
                    sock = connect((host, port), timeout)
                    sock.settimeout(timeout)
                    sock.sendall(msg)
                    status, headers, body = _read_response(sock)
        return status, body
    finally:
        try:
            sock.close()
        except OSError:
            pass


def sdp_codec(sdp: str) -> Optional[str]:
    in_video = False
    for ln in (sdp or "").splitlines():
        if ln.startswith("m="):
            in_video = ln.startswith("m=video")
        elif in_video and ln.startswith("a=rtpmap:"):
            m = re.match(r"a=rtpmap:\d+\s+([A-Za-z0-9\-]+)/", ln)
            if m:
                return m.group(1).lower()
    return None


def probe_stream(url: str, timeout_s: float = STREAM_TIMEOUT_S,
                 measure_s: float = MEASURE_S) -> dict:
    """Open with OpenCV/FFmpeg and measure. -> {ok, code, detail, frame,
    width, height, fps, codec}. Never raises."""
    from .camera import open_capture

    t0 = time.monotonic()
    try:
        cap = open_capture(url)
    except Exception as exc:
        return {"ok": False, "code": "stream_failed", "detail": type(exc).__name__}
    try:
        if not cap.isOpened():
            took = time.monotonic() - t0
            return {"ok": False,
                    "code": "timeout" if took >= timeout_s * 0.9 else "stream_failed",
                    "detail": "FFmpeg could not open the stream (%.1fs)" % took}
        frame = None
        while time.monotonic() - t0 < timeout_s:
            ok, f = cap.read()
            if ok and f is not None:
                frame = f
                break
        if frame is None:
            return {"ok": False, "code": "timeout", "detail": "no frames within %ds"
                    % int(timeout_s)}
        n, t1 = 0, time.monotonic()
        while time.monotonic() - t1 < measure_s:
            ok, f = cap.read()
            if ok and f is not None:
                n += 1
                frame = f
        dt = max(1e-3, time.monotonic() - t1)
        fps = n / dt
        codec = None
        try:
            import cv2
            if not fps:
                fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
            cc = int(cap.get(cv2.CAP_PROP_FOURCC) or 0)
            if cc:
                codec = "".join(chr((cc >> (8 * i)) & 0xFF) for i in range(4)
                                ).strip().lower() or None
        except Exception:
            pass
        h, w = frame.shape[:2]
        return {"ok": True, "code": None, "detail": "%dx%d" % (w, h), "frame": frame,
                "width": int(w), "height": int(h), "fps": round(float(fps), 1),
                "codec": codec}
    finally:
        try:
            cap.release()
        except Exception:
            pass


def encode_check_snapshot(frame) -> Optional[bytes]:
    """One JPEG, long side <= 640 px, quality ~75. None if encoding fails."""
    try:
        import cv2

        h, w = frame.shape[:2]
        long_side = max(h, w)
        if long_side > SNAPSHOT_LONG_SIDE:
            r = SNAPSHOT_LONG_SIDE / float(long_side)
            frame = cv2.resize(frame, (max(1, int(round(w * r))),
                                       max(1, int(round(h * r)))),
                               interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY,
                                               SNAPSHOT_QUALITY])
        if not ok:
            return None
        data = buf.tobytes()
        return data if data[:3] == b"\xff\xd8\xff" else None
    except Exception:
        return None


def sanitize(obj, secrets: List[Optional[str]]):
    """Recursively strip URL userinfo and secret values from every string."""
    if isinstance(obj, str):
        return vendors.redact_text(obj, secrets)
    if isinstance(obj, dict):
        return {k: sanitize(v, secrets) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [sanitize(v, secrets) for v in obj]
    return obj


def _int(v, default=None):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


# ------------------------------------------------------------------ check
class CheckOutcome:
    """result: JSON-ready dict (sanitised). snapshot: JPEG bytes or None.
    stream_url: credential-free RTSP URL to save in config. user/secret: the
    credentials that worked (kept in memory, for the SecretStore only)."""

    def __init__(self, result: dict, snapshot: Optional[bytes] = None,
                 stream_url: Optional[str] = None, user: Optional[str] = None,
                 secret: Optional[str] = None):
        self.result = result
        self.snapshot = snapshot
        self.stream_url = stream_url
        self.user = user
        self.secret = secret

    @property
    def ok(self) -> bool:
        return bool(self.result.get("ok"))


def _default_onvif(host, port, user, secret):
    return onvif_mod.OnvifClient.for_host(host, port, username=user, password=secret,
                                          timeout=4.0)


def run_check(request: dict, *, tcp: Callable = tcp_connect,
              opener: Callable = probe_stream, describe: Callable = rtsp_describe,
              onvif: Callable = _default_onvif,
              encoder: Callable = encode_check_snapshot) -> CheckOutcome:
    """See module docstring. Never raises; never returns a secret."""
    req = dict(request or {})
    vendor = str(req.get("vendor") or "").lower()
    user = req.get("username") or None
    secret = req.get("secret") or None
    custom_url = req.get("rtsp_url") or None
    secrets = [secret]
    if custom_url:
        _, u_in, p_in = split_rtsp_credentials(str(custom_url))
        secrets += [p_in]
        user = u_in or user
        secret = p_in or secret
    steps: Dict[str, dict] = {k: {"key": k, "ok": None, "code": "skipped",
                                  "detail": "not run"} for k in STEP_KEYS}
    info = {"width": None, "height": None, "fps": None, "codec": None,
            "onvif": False, "events_supported": False, "manufacturer": None,
            "model": None, "rtsp_path": None}
    snapshot = None
    clean_url = None

    def done(ok: bool) -> CheckOutcome:
        res = {"ok": bool(ok), "steps": [steps[k] for k in STEP_KEYS], "info": info}
        return CheckOutcome(sanitize(res, secrets), snapshot if ok else None,
                            clean_url if ok else None, user, secret)

    def setstep(key, ok, code=None, detail=""):
        steps[key] = {"key": key, "ok": ok, "code": code, "detail": str(detail)[:200]}

    try:
        if vendor not in vendors.VENDORS:
            setstep("reachable", False, "not_supported", "unknown vendor")
            return done(False)
        # -------------------------------------------- where to connect
        if vendor == "rtsp":
            clean0, _, _ = split_rtsp_credentials(str(custom_url or ""))
            try:
                p = urlsplit(clean0)
                host, port = p.hostname, p.port or vendors.DEFAULT_RTSP_PORT
            except ValueError:
                host, port = None, None
            if not host or not clean0.lower().startswith(("rtsp://", "rtsps://")):
                setstep("reachable", False, "not_supported", "custom URL must be rtsp://")
                return done(False)
        else:
            try:
                host = vendors.clean_host(req.get("host")).strip("[]")
            except ValueError:
                setstep("reachable", False, "unreachable", "bad host")
                return done(False)
            port = _int(req.get("port"), vendors.DEFAULT_RTSP_PORT)
        onvif_port = _int(req.get("onvif_port"))
        if vendor == "onvif":
            onvif_port = onvif_port or 80
        elif onvif_port is None and vendor in vendors.TEMPLATE_VENDORS:
            onvif_port = vendors.DEFAULT_ONVIF_PORT.get(vendor, 80)
        first_port = onvif_port if vendor == "onvif" else port

        # -------------------------------------------- 1. reachable
        try:
            tcp(host, first_port, TCP_TIMEOUT_S)
            setstep("reachable", True, None, "tcp %d open" % first_port)
        except socket.timeout:
            setstep("reachable", False, "timeout", "tcp %d: no answer in %ds"
                    % (first_port, int(TCP_TIMEOUT_S)))
            return done(False)
        except OSError as exc:
            setstep("reachable", False, "unreachable", "tcp %d: %s"
                    % (first_port, type(exc).__name__))
            return done(False)

        # -------------------------------------------- ONVIF (optional)
        cam_onvif = None
        onvif_auth_failed = False
        if onvif_port:
            try:
                if vendor != "onvif":
                    tcp(host, onvif_port, 1.5)
                cam_onvif = onvif(host, onvif_port, user, secret)
                try:
                    di = cam_onvif.get_device_information()
                    info["manufacturer"] = di.get("manufacturer")
                    info["model"] = di.get("model")
                except onvif_mod.OnvifError as exc:
                    if exc.code == "auth_failed":
                        raise
                cam_onvif.get_capabilities()
                info["onvif"] = True
            except onvif_mod.OnvifError as exc:
                onvif_auth_failed = exc.code == "auth_failed"
                info["onvif"] = onvif_auth_failed      # it speaks ONVIF
                cam_onvif = None
            except (OSError, ValueError):
                cam_onvif = None

        # -------------------------------------------- build the stream URL
        if vendor == "onvif":
            if onvif_auth_failed:
                setstep("auth", False, "auth_failed", "ONVIF rejected the credentials")
                return done(False)
            if cam_onvif is None:
                setstep("stream", False, "no_onvif", "ONVIF did not answer")
                return done(False)
            try:
                profiles = cam_onvif.get_profiles()
                if not profiles:
                    raise onvif_mod.OnvifError("fault", "no media profiles")
                want_sub = str(req.get("stream") or "main").lower() == "sub"
                prof = profiles[1] if (want_sub and len(profiles) > 1) else profiles[0]
                uri = cam_onvif.get_stream_uri(prof["token"])
                if not uri:
                    raise onvif_mod.OnvifError("fault", "no stream URI")
            except onvif_mod.OnvifError as exc:
                code = "auth_failed" if exc.code == "auth_failed" else "no_onvif"
                setstep("auth" if code == "auth_failed" else "stream", False, code,
                        "ONVIF %s: %s" % (exc.code, exc.detail))
                return done(False)
            clean_url, u_in, p_in = split_rtsp_credentials(uri)
            secrets.append(p_in)
        elif vendor == "rtsp":
            clean_url = split_rtsp_credentials(str(custom_url))[0]
        else:
            user = vendors.default_user(vendor, user)
            clean_url = split_rtsp_credentials(vendors.build_rtsp_url(
                vendor, host, port, req.get("channel") or 1,
                req.get("stream") or "main", user, None))[0]
        info["rtsp_path"] = vendors.url_path(clean_url)
        cred_url = join_rtsp_credentials(clean_url, user, secret)

        # -------------------------------------------- 2. auth (RTSP DESCRIBE)
        auth_known = False
        if clean_url.lower().startswith("rtsp://"):
            try:
                st, sdp = describe(clean_url, user, secret, 5.0)
                if st == 200:
                    setstep("auth", True, None, "RTSP DESCRIBE 200")
                    info["codec"] = sdp_codec(sdp)
                    auth_known = True
                elif st in (401, 403):
                    setstep("auth", False, "auth_failed", "RTSP %d" % st)
                    return done(False)
                elif st == 404:
                    setstep("auth", None, "not_checked", "RTSP 404 (path not found)")
                else:
                    setstep("auth", None, "not_checked", "RTSP %d" % st)
            except socket.timeout:
                setstep("auth", None, "timeout", "RTSP DESCRIBE timed out")
            except (OSError, ValueError) as exc:
                setstep("auth", None, "not_checked", "RTSP DESCRIBE: %s"
                        % type(exc).__name__)
        else:
            setstep("auth", None, "not_checked", "rtsps: checked via stream")

        # -------------------------------------------- 3. stream
        pr = opener(cred_url, STREAM_TIMEOUT_S) or {}
        if not pr.get("ok"):
            code = pr.get("code") or "stream_failed"
            if code not in ("timeout", "stream_failed", "auth_failed"):
                code = "stream_failed"
            setstep("stream", False, code, pr.get("detail") or "stream did not open")
            if onvif_auth_failed and not auth_known:
                setstep("auth", False, "auth_failed", "ONVIF rejected the credentials")
            return done(False)
        if not auth_known:
            setstep("auth", True, None, "stream opened with these credentials")
        info["width"], info["height"] = pr.get("width"), pr.get("height")
        info["fps"] = pr.get("fps")
        info["codec"] = info["codec"] or pr.get("codec")
        setstep("stream", True, None, "%sx%s @ %s fps" % (pr.get("width"),
                                                          pr.get("height"),
                                                          pr.get("fps")))

        # -------------------------------------------- 4. snapshot
        frame = pr.get("frame")
        snapshot = encoder(frame) if frame is not None else None
        if snapshot:
            setstep("snapshot", True, None, "jpeg %d bytes" % len(snapshot))
        else:
            setstep("snapshot", False, "snapshot_failed", "could not encode a JPEG")

        # -------------------------------------------- 5. events
        if cam_onvif is not None:
            try:
                ok = cam_onvif.get_event_properties()
                info["events_supported"] = bool(ok)
                setstep("events", bool(ok), None if ok else "not_supported",
                        "ONVIF events%s" % (" (PullPoint)" if cam_onvif.pullpoint
                                            else ""))
            except onvif_mod.OnvifError as exc:
                setstep("events", False, "not_supported",
                        "ONVIF GetEventProperties: %s" % exc.code)
        else:
            setstep("events", None, "not_checked",
                    "ONVIF not available; brand push (Assisto webhook / Imou cloud) "
                    "is not verified from the PC")
        return done(True)
    except Exception as exc:          # never crash the task runner
        log.warning("camera check failed unexpectedly: %s", type(exc).__name__)
        for k in STEP_KEYS:
            if steps[k]["code"] == "skipped":
                setstep(k, None, "internal_error", type(exc).__name__)
                break
        return done(False)


def run_discover(request: Optional[dict] = None, *,
                 discover: Callable = onvif_mod.discover) -> dict:
    timeout_s = 4.0
    try:
        timeout_s = float((request or {}).get("timeout_s") or 4.0)
    except (TypeError, ValueError):
        pass
    try:
        devs = discover(timeout_s)[:onvif_mod.MAX_DEVICES]
    except Exception as exc:
        return {"ok": False, "discovered": [], "code": "discover_failed",
                "detail": type(exc).__name__}
    return sanitize({"ok": True, "discovered": devs}, [])
