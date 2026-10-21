"""Live view sender (aiortc, optional). Skipped when aiortc isn't installed
(it ships via requirements-live.txt). A real in-process loopback: an aiortc
'owner' peer makes the recvonly offer, run_session answers through an
in-memory signaling stub, and the owner must receive a video frame."""
import asyncio
import time

import numpy as np
import pytest

aiortc = pytest.importorskip("aiortc")

from shopbox import live  # noqa: E402


def test_available_true_when_installed():
    assert live.available()


def test_parse_candidate_and_ice_servers():
    c = live.parse_candidate({"candidate": "candidate:1 1 udp 2122260223 192.168.1.5 "
                                           "54321 typ host generation 0",
                              "sdpMid": "0", "sdpMLineIndex": 0})
    assert c is not None and c.type == "host" and c.sdpMid == "0"
    assert live.parse_candidate({"candidate": ""}) is None
    servers = live.ice_servers_from([{"urls": ["stun:x:3478"]},
                                     {"urls": ["turn:x:3478"], "username": "u",
                                      "credential": "p"}])
    assert len(servers) == 2 and servers[1].username == "u"


class MemSignal:
    """In-memory stand-in for the server's signaling endpoints."""

    def __init__(self):
        self.msgs, self.seq, self.ended = [], 0, None

    def push(self, side, kind, payload):
        self.seq += 1
        self.msgs.append({"seq": self.seq, "side": side, "kind": kind,
                          "payload": payload})

    def poll(self, sid, after):
        return 200, {"status": "active", "seq": self.seq,
                     "messages": [m for m in self.msgs
                                  if m["side"] == "owner" and m["seq"] > after]}

    def send(self, sid, kind, payload):
        self.push("device", kind, payload)
        return 200

    def end(self, sid, relayed, seconds):
        self.ended = (relayed, seconds)


def test_loopback_owner_receives_video():
    from aiortc import RTCPeerConnection, RTCSessionDescription

    async def main():
        sig = MemSignal()
        owner = RTCPeerConnection()
        owner.addTransceiver("video", direction="recvonly")
        got = asyncio.Event()

        @owner.on("track")
        def on_track(track):
            async def pull():
                await track.recv()
                got.set()
            asyncio.ensure_future(pull())

        await owner.setLocalDescription(await owner.createOffer())
        sig.push("owner", "offer", {"type": "offer", "sdp": owner.localDescription.sdp})
        frame = np.full((240, 320, 3), 120, np.uint8)
        stop_at = time.time() + 20

        task = asyncio.ensure_future(live.run_session(
            sig, {"id": 1, "ice": {"ice_servers": []}}, lambda: frame,
            max_s=20))
        # wait for the device's answer, apply it, wait for a frame, then bye
        while time.time() < stop_at and not any(m["kind"] == "answer" for m in sig.msgs):
            await asyncio.sleep(0.1)
        ans = [m for m in sig.msgs if m["kind"] == "answer"][0]["payload"]
        await owner.setRemoteDescription(RTCSessionDescription(**ans))
        await asyncio.wait_for(got.wait(), 15)
        sig.push("owner", "bye", {})
        res = await asyncio.wait_for(task, 10)
        await owner.close()
        return res, sig

    res, sig = asyncio.run(main())
    assert res["answered"] and res["reason"] == "ended"
    assert res["relayed"] is False                # host candidates: P2P
    assert sig.ended is not None and sig.ended[0] is False
