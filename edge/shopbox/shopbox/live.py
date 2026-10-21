"""LIVE VIEW sender for the Windows Shop Box (optional, aiortc).

When the owner opens "Live view" in the app, the server creates a session and
this PC answers it as the WebRTC SENDER: frames already being pulled from the
camera's RTSP stream on the LAN are sent peer-to-peer to the owner's phone (or
through the Assisto TURN relay when P2P is impossible — relayed minutes cost
the owner credits). The server only relays the SDP/ICE text. NOTHING is
recorded, here or on the server, and the session is hard-capped by the server
(10 min default).

Outbound only: aiortc's ICE agent opens UDP sockets towards the peer / STUN /
TURN like any WebRTC client; no listening TCP port, no UPnP, no forwarding.

aiortc is OPTIONAL (requirements-live.txt). If it is not installed or fails to
import, `available()` is False, the heartbeat does not advertise the "live"
capability, and the owner's app honestly says live view is not supported by
this device. Everything here is guarded: a WebRTC failure ends the session; it
never stops monitoring.
"""
from __future__ import annotations

import asyncio
import logging
import threading
import time
from typing import Callable, Optional
from urllib.parse import urljoin

log = logging.getLogger(__name__)

POLL_S = 1.0
LIVE_FPS = 10


def available() -> bool:
    try:
        import aiortc  # noqa: F401
        import av  # noqa: F401
        return True
    except Exception:
        return False


def ice_servers_from(server_list):
    """The server's `ice_servers` -> aiortc RTCIceServer list."""
    from aiortc import RTCIceServer

    out = []
    for s in server_list or []:
        urls = s.get("urls")
        if not urls:
            continue
        out.append(RTCIceServer(urls=urls, username=s.get("username"),
                                credential=s.get("credential")))
    return out


def parse_candidate(c: dict):
    """Browser/flutter_webrtc candidate dict -> aiortc RTCIceCandidate (or None)."""
    from aiortc.sdp import candidate_from_sdp

    line = (c or {}).get("candidate") or ""
    if not line:
        return None
    if line.startswith("candidate:"):
        line = line[len("candidate:"):]
    try:
        cand = candidate_from_sdp(line)
    except Exception:
        return None
    cand.sdpMid = c.get("sdpMid")
    cand.sdpMLineIndex = c.get("sdpMLineIndex")
    return cand


def is_relayed(pc) -> bool:
    """True when the nominated ICE pair uses a TURN relay candidate. Uses
    aioice internals defensively; unknown -> False."""
    try:
        for t in pc.getTransceivers():
            ice = t.sender.transport.transport           # RTCIceTransport
            conn = getattr(ice, "_connection", None)     # aioice.Connection
            for pair in (getattr(conn, "_nominated", {}) or {}).values():
                if getattr(pair.local_candidate, "type", "") == "relay" or \
                        getattr(pair.remote_candidate, "type", "") == "relay":
                    return True
    except Exception:
        pass
    return False


def _make_track(frame_source: Callable[[], Optional[object]]):
    """A VideoStreamTrack that sends the latest BGR frame from the camera."""
    import av
    import numpy as np
    from aiortc import VideoStreamTrack

    class LatestFrameTrack(VideoStreamTrack):
        kind = "video"

        def __init__(self):
            super().__init__()
            self._blank = np.zeros((360, 640, 3), np.uint8)

        async def recv(self):
            pts, time_base = await self.next_timestamp()
            frame = None
            try:
                frame = frame_source()
            except Exception:
                frame = None
            img = frame if frame is not None else self._blank
            vf = av.VideoFrame.from_ndarray(img, format="bgr24")
            vf.pts, vf.time_base = pts, time_base
            return vf

    return LatestFrameTrack()


class SignalClient:
    """Device-side signaling over HTTPS (X-Shop-Token header)."""

    def __init__(self, base_url: str, token: str, session=None, timeout: float = 15.0):
        import requests

        self.base = base_url if base_url.endswith("/") else base_url + "/"
        self.token = token
        self.s = session or requests.Session()
        self.timeout = timeout

    def _url(self, sid, what):
        return urljoin(self.base, "shop/live/%d/%s" % (int(sid), what))

    def poll(self, sid, after):
        r = self.s.get(self._url(sid, "signal") + "?after=%d" % int(after),
                       headers={"X-Shop-Token": self.token}, timeout=self.timeout)
        return r.status_code, (r.json() if r.content else {})

    def send(self, sid, kind, payload):
        r = self.s.post(self._url(sid, "signal"), json={"kind": kind, "payload": payload},
                        headers={"X-Shop-Token": self.token}, timeout=self.timeout)
        return r.status_code

    def end(self, sid, relayed, seconds):
        try:
            self.s.post(self._url(sid, "end"),
                        json={"relayed": bool(relayed), "seconds": int(seconds)},
                        headers={"X-Shop-Token": self.token}, timeout=self.timeout)
        except Exception:
            pass


async def run_session(sig: SignalClient, session: dict,
                      frame_source: Callable[[], Optional[object]],
                      clock: Callable[[], float] = time.time,
                      max_s: float = 600.0) -> dict:
    """Answer ONE live session. Returns {answered, relayed, seconds, reason}."""
    from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

    sid = int(session["id"])
    ice = (session.get("ice") or {}).get("ice_servers") or []
    pc = RTCPeerConnection(RTCConfiguration(iceServers=ice_servers_from(ice)))
    loop = asyncio.get_running_loop()
    after, answered, relayed, since = 0, False, False, None
    deadline = clock() + max_s
    reason = "timeout"
    try:
        while clock() < deadline:
            st, d = await loop.run_in_executor(None, sig.poll, sid, after)
            if st in (401, 404):
                reason = "gone"
                break
            if st != 200:
                await asyncio.sleep(2.0)
                continue
            after = int(d.get("seq") or after)
            bye = d.get("status") in ("ended", "expired")
            for m in d.get("messages") or []:
                kind, p = m.get("kind"), m.get("payload") or {}
                if kind == "offer" and not answered:
                    await pc.setRemoteDescription(
                        RTCSessionDescription(sdp=p.get("sdp"), type=p.get("type", "offer")))
                    pc.addTrack(_make_track(frame_source))
                    ans = await pc.createAnswer()
                    await pc.setLocalDescription(ans)   # gathers ICE (in the SDP)
                    await loop.run_in_executor(
                        None, sig.send, sid, "answer",
                        {"type": pc.localDescription.type, "sdp": pc.localDescription.sdp})
                    answered, since = True, clock()
                elif kind == "candidate":
                    cand = parse_candidate(p)
                    if cand is not None:
                        try:
                            await pc.addIceCandidate(cand)
                        except Exception:
                            pass
                elif kind == "bye":
                    bye = True
            if answered and not relayed:
                relayed = is_relayed(pc)
            if bye:
                reason = "ended"
                break
            await asyncio.sleep(POLL_S)
    finally:
        try:
            await pc.close()
        except Exception:
            pass
    secs = int(clock() - since) if since else 0
    await loop.run_in_executor(None, sig.end, sid, relayed, secs)
    return {"answered": answered, "relayed": relayed, "seconds": secs, "reason": reason}


class LiveAnswerer:
    """Runs at most ONE live session at a time, in its own thread + event loop."""

    def __init__(self, base_url: str, frame_source_for: Callable[[str], Callable]):
        self.base_url = base_url
        self.frame_source_for = frame_source_for   # token -> () -> latest frame
        self._busy = threading.Lock()
        self.last_result: Optional[dict] = None

    def handle(self, token: str, session: dict) -> bool:
        if not self._busy.acquire(blocking=False):
            return False                       # already streaming

        def _run():
            try:
                sig = SignalClient(self.base_url, token)
                self.last_result = asyncio.run(
                    run_session(sig, session, self.frame_source_for(token)))
                log.info("live session %s finished: %s", session.get("id"),
                         self.last_result)
            except Exception:
                log.exception("live session failed")
            finally:
                self._busy.release()

        threading.Thread(target=_run, name="live-%s" % session.get("id"),
                         daemon=True).start()
        return True
