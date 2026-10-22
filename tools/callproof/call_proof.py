#!/usr/bin/env python3
"""
call_proof.py — A4 CALL PROOF: two real clients place, answer, talk and hang
up a My Circle voice call against the LIVE server + LIVE TURN, from outside
AWS (a GitHub runner), and measure that audio really flows both ways.

Run by the manual workflow "Call proof" (.github/workflows/call-proof.yml).

SECRETS (GitHub -> Settings -> Secrets and variables -> Actions):
  CALL_PROOF_A_PHONE, CALL_PROOF_A_PASSWORD   test account A (the caller)
  CALL_PROOF_B_PHONE, CALL_PROOF_B_PASSWORD   test account B (the callee)
  A and B must be ACCEPTED My Circle contacts of each other. Optional:
  CALL_PROOF_A_MEMBER_ID = A's circle member id for B (skips discovery).
  Tokens / credentials are never printed (masked with ::add-mask::).

WHAT ONE RUN DOES (the same API + signalling the phones use):
  B polls GET circle/calls/incoming (also makes B "reachable"),
  A: GET rtc/turn -> POST circle/<member>/call {kind:voice, client_call_id}
     -> offer via POST rt/send {topic:"call.signal"}
  B: sees the call -> POST circle/calls/<id>/event ringing, answer
     -> reads the offer (GET rt/events?after=0&topics=call.signal&call_id=N)
     -> answer via rt/send
  both: ICE (aiortc) -> POST event connected {relayed}; heartbeat = rt/events
     polls every 1 s; a 440 Hz / 660 Hz tone is sent both ways for --talk s
  A: POST event hangup -> B polls GET circle/calls/<id> until phase "ended"
     (= hang-up latency); both status rows must say ended.
  RUNS: "relay" = forced relay (aioice transport_policy=RELAY on BOTH peers:
  only TURN relay candidates exist, so the selected pair is relay<->relay),
  "direct" = all candidates (both peers share the runner, so this mostly
  proves signalling; the relay run is the real internet path). "relay-tcp" /
  "relay-tls" put the turn:?transport=tcp / turns: URL first (aiortc uses only
  the first TURN url).

HOW TO READ THE TABLE (job summary):
  connect = answer -> ICE connected (and place -> connected), relay = the
  selected candidate pair types, A->B / B->A = RTP packets/bytes the receiver
  counted (inbound-rtp, plus the sender's outbound-rtp), hang-up = A's hangup
  POST -> B sees "ended". PASS = connected within 20 s, >= MIN_PACKETS packets
  received each way, both sides ended. Any FAIL turns the job red.

Local:  CALL_PROOF_A_PHONE=.. CALL_PROOF_A_PASSWORD=.. CALL_PROOF_B_PHONE=..
        CALL_PROOF_B_PASSWORD=.. python3 tools/callproof/call_proof.py \
        --api https://api.lifeassisto.com/api/v1 --runs relay,direct --talk 30
        python3 tools/callproof/call_proof.py --loopback   (no server: two
        local peers, checks the media + stats code only)
"""
from __future__ import annotations

import argparse
import asyncio
import fractions
import json
import math
import os
import sys
import time
import uuid

import requests
from aiortc import (RTCConfiguration, RTCIceServer, RTCPeerConnection,
                    RTCSessionDescription)
from aiortc.mediastreams import AudioStreamTrack, MediaStreamError
from aiortc.contrib.media import MediaBlackhole

try:
    import av
except Exception:  # pragma: no cover
    av = None

CONNECT_TIMEOUT_S = 20
MIN_PACKETS_PER_30S = 1000   # voice ~50 packets/s -> 1500 in 30 s


def mask(v):
    if v and os.environ.get("GITHUB_ACTIONS") == "true":
        print("::add-mask::%s" % v, flush=True)


def log(*a):
    print("[%s]" % time.strftime("%H:%M:%S"), *a, flush=True)


# ------------------------------------------------------------------ media
class Tone(AudioStreamTrack):
    """A sine tone, 48 kHz mono, 20 ms frames (what Opus wants)."""

    def __init__(self, hz):
        super().__init__()
        self.hz = hz
        self._n = 0
        self._t0 = None

    async def recv(self):
        if self.readyState != "live":
            raise MediaStreamError
        rate, samples = 48000, 960
        if self._t0 is None:
            self._t0 = time.time()
        wait = self._t0 + self._n / rate - time.time()
        if wait > 0:
            await asyncio.sleep(wait)
        frame = av.AudioFrame(format="s16", layout="mono", samples=samples)
        amp = 8000
        buf = bytearray()
        for i in range(samples):
            v = int(amp * math.sin(2 * math.pi * self.hz * (self._n + i) / rate))
            buf += v.to_bytes(2, "little", signed=True)
        frame.planes[0].update(bytes(buf))
        frame.pts = self._n
        frame.sample_rate = rate
        frame.time_base = fractions.Fraction(1, rate)
        self._n += samples
        return frame


def force_relay(on):
    """aiortc has no iceTransportPolicy; aioice does (TransportPolicy.RELAY)."""
    import aiortc.rtcicetransport as rit
    import aioice
    if not hasattr(force_relay, "orig"):
        force_relay.orig = rit.Connection
    orig = force_relay.orig
    if not on:
        rit.Connection = orig
        return
    policy = getattr(aioice, "TransportPolicy", None)
    if policy is None:
        raise RuntimeError("installed aioice has no TransportPolicy (need >= 0.9)")

    def relay_only(*args, **kw):
        kw["transport_policy"] = policy.RELAY
        return orig(*args, **kw)
    rit.Connection = relay_only


def ice_config(ice_servers, prefer, relay_only=False):
    """RTCConfiguration from the server's ice_servers. aiortc uses only the
    FIRST turn url, so put the preferred transport first.
    relay_only: drop every stun: URL. aioice's TransportPolicy.RELAY only
    drops HOST candidates and still gathers server-reflexive ones from STUN,
    so a "forced relay" run could otherwise connect host<->srflx."""
    out = []
    for s in ice_servers or []:
        urls = s.get("urls") or []
        if isinstance(urls, str):
            urls = [urls]
        if relay_only:
            urls = [u for u in urls if not u.startswith("stun:")]
            if not urls:
                continue
        if s.get("username"):
            def rank(u):
                if prefer == "tls":
                    return 0 if u.startswith("turns:") else 1
                if prefer == "tcp":
                    return 0 if "transport=tcp" in u and u.startswith("turn:") else 1
                return 0 if "transport=udp" in u else 1
            urls = sorted(urls, key=rank)
            out.append(RTCIceServer(urls=urls, username=s["username"],
                                    credential=s.get("credential", "")))
        else:
            out.append(RTCIceServer(urls=urls))
    return RTCConfiguration(iceServers=out)


def selected_pair(pc):
    """(local type, remote type, local addr) of the nominated ICE pair."""
    try:
        for t in pc.getTransceivers():
            ice = t.sender.transport.transport
            conn = ice._connection
            nom = getattr(conn, "_nominated", {}) or {}
            for pair in nom.values():
                lc, rc = pair.local_candidate, pair.remote_candidate
                return lc.type, rc.type, "%s:%s" % (lc.host, lc.port)
    except Exception:
        pass
    return "?", "?", ""


async def rtp_stats(pc):
    st = await pc.getStats()
    out = {"sent_pk": 0, "sent_b": 0, "recv_pk": 0, "lost": 0}
    for r in st.values():
        if r.type == "outbound-rtp":
            out["sent_pk"] += r.packetsSent or 0
            out["sent_b"] += r.bytesSent or 0
        elif r.type == "inbound-rtp":
            out["recv_pk"] += r.packetsReceived or 0
            out["lost"] += max(0, r.packetsLost or 0)
    return out


async def wait_connected(pc, timeout):
    end = time.time() + timeout
    while time.time() < end:
        if pc.iceConnectionState in ("connected", "completed"):
            return True
        if pc.iceConnectionState == "failed":
            return False
        await asyncio.sleep(0.05)
    return False


def make_pc(cfg, hz):
    pc = RTCPeerConnection(cfg)
    pc.addTrack(Tone(hz))
    hole = MediaBlackhole()

    @pc.on("track")
    def _on_track(track):
        hole.addTrack(track)
    return pc, hole


# ------------------------------------------------------------------ API
class Client:
    def __init__(self, api, name):
        self.api = api.rstrip("/")
        self.name = name
        self.s = requests.Session()
        self.s.headers.update({"Accept": "application/json",
                               "Accept-Language": "en"})
        self.user = {}
        self.seq = 0

    def _url(self, p):
        return self.api + p

    def post(self, p, body):
        r = self.s.post(self._url(p), json=body, timeout=15)
        try:
            j = r.json()
        except Exception:
            j = {}
        return r.status_code, j

    def get(self, p):
        r = self.s.get(self._url(p), timeout=15)
        try:
            j = r.json()
        except Exception:
            j = {}
        return r.status_code, j

    def login(self, phone, pw):
        code, j = self.post("/auth/login", {"identifier": phone, "password": pw})
        tok = j.get("token")
        if code != 200 or not tok:
            raise RuntimeError("%s login failed (HTTP %s)" % (self.name, code))
        mask(tok)
        self.s.headers["Authorization"] = "Token %s" % tok
        self.user = j.get("user") or {}

    async def aget(self, p):
        return await asyncio.to_thread(self.get, p)

    async def apost(self, p, body):
        return await asyncio.to_thread(self.post, p, body)

    def member_for(self, other):
        override = os.environ.get("CALL_PROOF_%s_MEMBER_ID" % self.name)
        if override:
            return int(override)
        code, j = self.get("/circle/members")
        rows = j.get("results") or []
        oname = (other.user.get("name") or "").strip().lower()
        ophone = "".join(ch for ch in str(other.user.get("phone") or "") if ch.isdigit())
        for m in rows:
            mp = "".join(ch for ch in str(m.get("phone") or "") if ch.isdigit())
            if ophone and mp and mp[-10:] == ophone[-10:]:
                return m["id"]
        for m in rows:
            if oname and (m.get("name") or "").strip().lower() == oname:
                return m["id"]
        if len(rows) == 1:
            return rows[0]["id"]
        raise RuntimeError("%s: cannot find the circle member for the other "
                           "account (%d members); set CALL_PROOF_%s_MEMBER_ID"
                           % (self.name, len(rows), self.name))

    async def turn(self):
        code, j = await self.aget("/rtc/turn")
        for s in j.get("ice_servers") or []:
            mask(s.get("username"))
            mask(s.get("credential"))
        return j

    async def signal(self, call_id, kind, data):
        code, j = await self.apost("/rt/send", {"topic": "call.signal", "payload": {
            "call_id": call_id, "kind": kind, "data": data}})
        if code >= 300:
            raise RuntimeError("%s rt/send %s -> HTTP %s %s" % (
                self.name, kind, code, j.get("code", "")))

    async def event(self, call_id, ev, **extra):
        body = {"event": ev}
        body.update(extra)
        return await self.apost("/circle/calls/%d/event" % call_id, body)

    async def poll_events(self, call_id, after=None):
        a = self.seq if after is None else after
        code, j = await self.aget("/rt/events?after=%d&topics=call&call_id=%d"
                                  % (a, call_id))
        evs = [e for e in (j.get("events") or [])
               if (e.get("payload") or {}).get("call_id") == call_id]
        if after is None:
            seqs = [e.get("seq", 0) for e in j.get("events") or []]
            self.seq = max([self.seq, int(j.get("seq") or 0)] + seqs)
        return evs


# ------------------------------------------------------------------ one run
async def heartbeat(client, call_id, state, stop):
    """rt/events every 1 s: keeps the server's heartbeat fresh AND catches
    call.state / trickled ICE."""
    while not stop.is_set():
        try:
            for e in await client.poll_events(call_id):
                state["events"].append(e)
                p = e.get("payload") or {}
                if e.get("topic") == "call.state" and p.get("phase") == "ended":
                    state["ended_at"] = state.get("ended_at") or time.time()
                    state["end_reason"] = p.get("end_reason")
        except Exception as ex:
            log(client.name, "poll error", ex.__class__.__name__)
        try:
            await asyncio.wait_for(stop.wait(), 1.0)
        except asyncio.TimeoutError:
            pass


async def one_run(A, B, member_id, mode, talk_s):
    res = {"run": mode, "verdict": "FAIL", "note": ""}
    relay = mode.startswith("relay")
    prefer = "tls" if mode == "relay-tls" else ("tcp" if mode == "relay-tcp" else "udp")
    force_relay(relay)
    pcA = pcB = holeA = holeB = None
    call_id = None
    stop = asyncio.Event()
    stA, stB = {"events": []}, {"events": []}
    tasks = []
    try:
        # B is "online" (in-app poll) so the server rings it, never "offline".
        await B.aget("/circle/calls/incoming")
        await B.poll_events(0, after=None)
        await A.poll_events(0, after=None)
        cfgA_raw = await A.turn()
        if not cfgA_raw.get("configured") or cfgA_raw.get("throttled"):
            res["note"] = "rtc/turn: configured=%s throttled=%s" % (
                cfgA_raw.get("configured"), cfgA_raw.get("throttled"))
            if relay:
                return res
        t_place = time.time()
        code, r = await A.apost("/circle/%d/call" % member_id, {
            "kind": "voice", "client_call_id": str(uuid.uuid4())})
        if code not in (200, 201) or not r.get("allowed") or not r.get("call_id"):
            res["note"] = "place HTTP %s allowed=%s reason=%s" % (
                code, r.get("allowed"), r.get("reason") or r.get("end_reason"))
            return res
        call_id = int(r["call_id"])
        res["call_id"] = call_id
        if r.get("phase") == "ended":
            res["note"] = "server ended the call at once: %s" % r.get("end_reason")
            return res
        tasks += [asyncio.create_task(heartbeat(A, call_id, stA, stop))]
        ice_a = cfgA_raw.get("ice_servers") or (r.get("ice") or {}).get("iceServers")
        pcA, holeA = make_pc(ice_config(ice_a, prefer, relay_only=relay), 440)
        offer = await pcA.createOffer()
        await pcA.setLocalDescription(offer)   # aiortc gathers here (no trickle)
        await A.signal(call_id, "offer", {"type": pcA.localDescription.type,
                                          "sdp": pcA.localDescription.sdp})
        log("A placed", call_id, "phase", r.get("phase"), "offer sent")

        # ---- B: see the ring, ack, answer
        seen = False
        for _ in range(100):
            code, j = await B.aget("/circle/calls/incoming")
            if any(int(c.get("call_id") or 0) == call_id for c in j.get("calls") or []):
                seen = True
                break
            await asyncio.sleep(0.3)
        if not seen:
            res["note"] = "B never saw the call in circle/calls/incoming"
            return res
        res["ring_s"] = time.time() - t_place
        await B.event(call_id, "ringing")
        t_answer = time.time()
        code, ans = await B.event(call_id, "answer")
        if ans.get("phase") not in ("accepted", "connected"):
            res["note"] = "answer -> phase %s (%s)" % (ans.get("phase"), ans.get("end_reason"))
            return res
        tasks += [asyncio.create_task(heartbeat(B, call_id, stB, stop))]
        cfgB_raw = await B.turn()
        ice_b = cfgB_raw.get("ice_servers") or (ans.get("ice") or {}).get("iceServers")
        pcB, holeB = make_pc(ice_config(ice_b, prefer, relay_only=relay), 660)
        offer_sdp = None
        for _ in range(50):
            for e in await B.poll_events(call_id, after=0):
                p = e.get("payload") or {}
                if e.get("topic") == "call.signal" and p.get("kind") == "offer":
                    offer_sdp = p.get("data")
            if offer_sdp:
                break
            await asyncio.sleep(0.2)
        if not offer_sdp:
            res["note"] = "B never received the offer"
            return res
        await pcB.setRemoteDescription(RTCSessionDescription(
            sdp=offer_sdp["sdp"], type=offer_sdp["type"]))
        answer = await pcB.createAnswer()
        await pcB.setLocalDescription(answer)
        await B.signal(call_id, "answer", {"type": pcB.localDescription.type,
                                           "sdp": pcB.localDescription.sdp})
        # ---- A: wait for the answer (from its heartbeat stream or a poll)
        ans_sdp = None
        end = time.time() + 10
        while time.time() < end and not ans_sdp:
            for e in stA["events"] + await A.poll_events(call_id, after=0):
                p = e.get("payload") or {}
                if e.get("topic") == "call.signal" and p.get("kind") == "answer":
                    ans_sdp = p.get("data")
            if not ans_sdp:
                await asyncio.sleep(0.2)
        if not ans_sdp:
            res["note"] = "A never received the answer"
            return res
        res["answer_delivery_s"] = time.time() - t_answer
        await pcA.setRemoteDescription(RTCSessionDescription(
            sdp=ans_sdp["sdp"], type=ans_sdp["type"]))
        await holeA.start()
        await holeB.start()
        okA, okB = await asyncio.gather(wait_connected(pcA, CONNECT_TIMEOUT_S),
                                        wait_connected(pcB, CONNECT_TIMEOUT_S))
        t_conn = time.time()
        if not (okA and okB):
            res["note"] = "ICE not connected in %ds (A=%s B=%s)" % (
                CONNECT_TIMEOUT_S, pcA.iceConnectionState, pcB.iceConnectionState)
            await A.event(call_id, "fail")
            return res
        res["connect_s"] = t_conn - t_answer
        res["place_connect_s"] = t_conn - t_place
        la, ra, _ = selected_pair(pcA)
        lb, rb, _ = selected_pair(pcB)
        res["pairA"], res["pairB"] = "%s<->%s" % (la, ra), "%s<->%s" % (lb, rb)
        relayed = "relay" in (la, ra, lb, rb)
        res["relayed"] = relayed
        await A.event(call_id, "connected", relayed=relayed)
        await B.event(call_id, "connected", relayed=relayed)
        log("connected in %.2fs (A %s, B %s); talking %ds" % (
            res["connect_s"], res["pairA"], res["pairB"], talk_s))
        await asyncio.sleep(talk_s)
        sa, sb = await rtp_stats(pcA), await rtp_stats(pcB)
        res["statsA"], res["statsB"] = sa, sb
        # ---- hang up (A) and time until B sees ended
        t_h = time.time()
        await A.event(call_id, "hangup")
        b_end = None
        while time.time() - t_h < 10:
            if stB.get("ended_at"):
                b_end = stB["ended_at"]
                break
            code, j = await B.aget("/circle/calls/%d" % call_id)
            if j.get("phase") == "ended":
                b_end = time.time()
                break
            await asyncio.sleep(0.1)
        res["hangup_s"] = (b_end - t_h) if b_end else None
        _, ja = await A.aget("/circle/calls/%d" % call_id)
        _, jb = await B.aget("/circle/calls/%d" % call_id)
        res["ended_both"] = ja.get("phase") == "ended" and jb.get("phase") == "ended"
        need = int(MIN_PACKETS_PER_30S * talk_s / 30)
        ok = (sb["recv_pk"] >= need and sa["recv_pk"] >= need and res["ended_both"]
              and res["hangup_s"] is not None and (relayed or not relay))
        if relay and not relayed:
            res["note"] = "forced relay run but the selected pair is not relay"
        elif not ok:
            res["note"] = "need >= %d packets each way and both ended" % need
        res["verdict"] = "PASS" if ok else "FAIL"
        return res
    except Exception as ex:
        res["note"] = "%s: %s" % (ex.__class__.__name__, str(ex)[:200])
        return res
    finally:
        stop.set()
        for t in tasks:
            try:
                await asyncio.wait_for(t, 3)
            except Exception:
                pass
        if call_id:
            # never leave a live call behind
            for c, ev in ((A, "hangup"), (B, "hangup")):
                try:
                    await c.event(call_id, ev)
                except Exception:
                    pass
        for h in (holeA, holeB):
            try:
                if h:
                    await h.stop()
            except Exception:
                pass
        for pc in (pcA, pcB):
            try:
                if pc:
                    await pc.close()
            except Exception:
                pass
        force_relay(False)


# ------------------------------------------------------------------ loopback
async def loopback(talk_s, relay=False):
    """No server: two local peers, SDP exchanged directly (checks media/stats)."""
    force_relay(relay)
    cfg = RTCConfiguration(iceServers=[])
    pcA, holeA = make_pc(cfg, 440)
    pcB, holeB = make_pc(cfg, 660)
    await pcA.setLocalDescription(await pcA.createOffer())
    await pcB.setRemoteDescription(pcA.localDescription)
    await pcB.setLocalDescription(await pcB.createAnswer())
    await pcA.setRemoteDescription(pcB.localDescription)
    await holeA.start()
    await holeB.start()
    t0 = time.time()
    ok = all(await asyncio.gather(wait_connected(pcA, 20), wait_connected(pcB, 20)))
    res = {"run": "loopback", "connect_s": time.time() - t0}
    la, ra, _ = selected_pair(pcA)
    res["pairA"] = res["pairB"] = "%s<->%s" % (la, ra)
    res["relayed"] = "relay" in (la, ra)
    await asyncio.sleep(talk_s)
    res["statsA"], res["statsB"] = await rtp_stats(pcA), await rtp_stats(pcB)
    res["hangup_s"] = 0.0
    need = int(MIN_PACKETS_PER_30S * talk_s / 30)
    res["verdict"] = "PASS" if ok and res["statsA"]["recv_pk"] >= need and \
        res["statsB"]["recv_pk"] >= need else "FAIL"
    for h in (holeA, holeB):
        await h.stop()
    await pcA.close()
    await pcB.close()
    force_relay(False)
    return res


# ------------------------------------------------------------------ report
def fmt_s(v):
    return "-" if v is None else "%.2f s" % v


def table(results, talk_s):
    out = ["## Call proof (live server + live TURN, from a GitHub runner)", "",
           "Talk time per run: %d s. PASS = ICE connected <= %d s, >= %d RTP "
           "packets received each way, hang-up seen by both." % (
               talk_s, CONNECT_TIMEOUT_S, int(MIN_PACKETS_PER_30S * talk_s / 30)), "",
           "| Run | Call | Connect (answer→ICE / place→ICE) | Relay used (A / B pair) "
           "| A→B packets / bytes | B→A packets / bytes | Hang-up latency | Verdict | Note |",
           "|---|---|---|---|---|---|---|---|---|"]
    for r in results:
        sa, sb = r.get("statsA") or {}, r.get("statsB") or {}
        # aiortc's inbound-rtp has no bytesReceived: bytes = the sender's
        # outbound-rtp bytesSent; packets = what the RECEIVER counted.
        ab = ba = "-"
        if sa and sb:
            ab = "%s rx (%s lost) / %s B (sent %s)" % (
                sb["recv_pk"], sb["lost"], sa["sent_b"], sa["sent_pk"])
            ba = "%s rx (%s lost) / %s B (sent %s)" % (
                sa["recv_pk"], sa["lost"], sb["sent_b"], sb["sent_pk"])
        out.append("| %s | %s | %s / %s | %s (%s / %s) | %s | %s | %s | %s | %s |" % (
            r["run"], r.get("call_id", "-"), fmt_s(r.get("connect_s")),
            fmt_s(r.get("place_connect_s")),
            "yes" if r.get("relayed") else ("no" if "relayed" in r else "-"),
            r.get("pairA", "-"), r.get("pairB", "-"), ab, ba,
            fmt_s(r.get("hangup_s")), "**%s**" % r["verdict"],
            (r.get("note") or "").replace("|", "/")))
    return "\n".join(out)


async def amain(a):
    if a.loopback:
        results = [await loopback(a.talk)]
    else:
        env = os.environ
        for k in ("CALL_PROOF_A_PASSWORD", "CALL_PROOF_B_PASSWORD"):
            mask(env.get(k))
        missing = [k for k in ("CALL_PROOF_A_PHONE", "CALL_PROOF_A_PASSWORD",
                               "CALL_PROOF_B_PHONE", "CALL_PROOF_B_PASSWORD")
                   if not env.get(k)]
        if missing:
            print("missing secrets: %s" % ", ".join(missing))
            return 2
        A, B = Client(a.api, "A"), Client(a.api, "B")
        await asyncio.to_thread(A.login, env["CALL_PROOF_A_PHONE"], env["CALL_PROOF_A_PASSWORD"])
        await asyncio.to_thread(B.login, env["CALL_PROOF_B_PHONE"], env["CALL_PROOF_B_PASSWORD"])
        member = await asyncio.to_thread(A.member_for, B)
        log("A's member id for B:", member)
        results = []
        for rnd in range(max(1, a.rounds)):
            for mode in [m.strip() for m in a.runs.split(",") if m.strip()]:
                log("run", mode, "round", rnd + 1)
                r = await one_run(A, B, member, mode, a.talk)
                if a.rounds > 1:
                    r["run"] = "%s #%d" % (mode, rnd + 1)
                log(json.dumps({k: v for k, v in r.items()}, default=str))
                results.append(r)
                await asyncio.sleep(3)
    text = table(results, a.talk)
    print(text)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(text + "\n")
    return 0 if results and all(r["verdict"] == "PASS" for r in results) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default=os.environ.get("API_BASE") or "https://api.lifeassisto.com/api/v1")
    ap.add_argument("--runs", default=os.environ.get("CALL_PROOF_RUNS") or "relay,direct")
    ap.add_argument("--rounds", type=int, default=int(os.environ.get("CALL_PROOF_ROUNDS") or 1))
    ap.add_argument("--talk", type=int, default=int(os.environ.get("CALL_PROOF_TALK") or 30))
    ap.add_argument("--loopback", action="store_true")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    return asyncio.run(amain(ap.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
