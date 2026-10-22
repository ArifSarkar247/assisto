#!/usr/bin/env python3
"""
turn_probe.py — test Assisto's coturn from OUTSIDE AWS (A1-b).

Run by the manual GitHub workflow "TURN probe" (.github/workflows/turn-probe.yml)
on a GitHub-hosted runner, i.e. from the public internet, exactly where the
phones are.  Pure Python standard library (a minimal RFC 5389 STUN / RFC 5766
TURN client with long-term-credential MESSAGE-INTEGRITY) — nothing to install.

CREDENTIALS (never printed; each value is also masked with ::add-mask::):
  1. Like the app (preferred): log in with CALL_PROOF_A_PHONE /
     CALL_PROOF_A_PASSWORD  ->  POST {api}/auth/login {identifier,password}
     -> {"token"}  ->  GET {api}/rtc/turn  (header "Authorization: Token <t>")
     -> ice_servers[].username/credential.  This proves the LIVE API hands out
     working TURN credentials.
  2. Fallback: mint them with TURN_STATIC_SECRET exactly like
     backend/core/logic/rtc.py:  username = "<expiry>:probe",
     credential = base64(HMAC-SHA1(username, secret)).
  Neither present -> only the unauthenticated STUN / reachability checks run.

WHAT IS PROBED (host default turn.lifeassisto.com):
  STUN binding  UDP 3478          (is UDP 3478 open in the security group?)
  TCP connect + STUN over TCP 3478
  TLS handshake + STUN over TLS 5349 (cert subject / expiry reported)
  TURN Allocate over UDP / TCP / TLS -> relayed address; port must lie in
     49152-65535 (coturn min-port/max-port)
  RELAY RANGE: a second runner socket sends a UDP packet straight to the
     relayed port (inbound through the AWS security group) and the relay sends
     one back via a Send indication — proves UDP 49152-65535 is open.

HOW TO READ: the job summary has one row per check: OK = reachable/working,
BLOCKED = no answer (timeout -> usually the AWS security group / ufw drops it),
REFUSED = the port answered with a TCP reset (open in the firewall but nothing
listens there, e.g. 5349 before tls-listening-port is configured), FAIL = it
answered but the TURN step failed (e.g. 401 = bad credentials).  The job only
goes red on a script error, never on a blocked port.

Local run:  python3 tools/callproof/turn_probe.py --host turn.lifeassisto.com
            [--api https://api.lifeassisto.com/api/v1] [--summary out.md]
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import socket
import ssl
import struct
import sys
import time
import urllib.request

MAGIC = 0x2112A442
# methods / classes
BINDING, ALLOCATE, REFRESH, SEND, DATA, CREATE_PERMISSION = 1, 3, 4, 6, 7, 8
REQ, IND, OK_, ERR = 0x0000, 0x0010, 0x0100, 0x0110
# attributes
A_USERNAME, A_MI, A_ERROR, A_REALM, A_NONCE = 0x0006, 0x0008, 0x0009, 0x0014, 0x0015
A_XOR_MAPPED, A_XOR_PEER, A_DATA, A_XOR_RELAYED = 0x0020, 0x0012, 0x0013, 0x0016
A_LIFETIME, A_REQ_TRANSPORT, A_SOFTWARE = 0x000D, 0x0019, 0x8022

RELAY_MIN, RELAY_MAX = 49152, 65535
TIMEOUT = 3.0


def _mask(v):
    if v and os.environ.get("GITHUB_ACTIONS") == "true":
        print("::add-mask::%s" % v, flush=True)


# --------------------------------------------------------------- STUN codec
def _msg_type(method, cls):
    m = method
    return ((m & 0x0F80) << 2) | ((m & 0x0070) << 1) | (m & 0x000F) | cls


def _split_type(t):
    cls = t & 0x0110
    method = (t & 0x000F) | ((t & 0x00E0) >> 1) | ((t & 0x3E00) >> 2)
    return method, cls


def _attr(t, v):
    pad = (4 - len(v) % 4) % 4
    return struct.pack("!HH", t, len(v)) + v + b"\0" * pad


def _xor_addr(ip, port, txid):
    a = ipaddress.ip_address(ip)
    xport = port ^ (MAGIC >> 16)
    if a.version == 4:
        xip = int(a) ^ MAGIC
        return struct.pack("!BBH", 0, 1, xport) + struct.pack("!I", xip)
    key = struct.pack("!I", MAGIC) + txid
    raw = bytes(x ^ y for x, y in zip(a.packed, key))
    return struct.pack("!BBH", 0, 2, xport) + raw


def _parse_xor_addr(v, txid):
    fam, xport = v[1], struct.unpack("!H", v[2:4])[0]
    port = xport ^ (MAGIC >> 16)
    if fam == 1:
        ip = ipaddress.IPv4Address(struct.unpack("!I", v[4:8])[0] ^ MAGIC)
    else:
        key = struct.pack("!I", MAGIC) + txid
        ip = ipaddress.IPv6Address(bytes(x ^ y for x, y in zip(v[4:20], key)))
    return str(ip), port


def build(method, cls, attrs=(), key=None, txid=None):
    txid = txid or os.urandom(12)
    body = b"".join(_attr(t, v) for t, v in attrs)
    if key is not None:
        hdr = struct.pack("!HHI", _msg_type(method, cls), len(body) + 24, MAGIC) + txid
        mac = hmac.new(key, hdr + body, hashlib.sha1).digest()
        body += _attr(A_MI, mac)
    hdr = struct.pack("!HHI", _msg_type(method, cls), len(body), MAGIC) + txid
    return hdr + body, txid


def parse(buf):
    if len(buf) < 20:
        return None
    t, ln, magic = struct.unpack("!HHI", buf[:8])
    if magic != MAGIC or t & 0xC000:
        return None
    txid = buf[8:20]
    attrs, i = {}, 20
    while i + 4 <= 20 + ln and i + 4 <= len(buf):
        at, al = struct.unpack("!HH", buf[i:i + 4])
        attrs.setdefault(at, buf[i + 4:i + 4 + al])
        i += 4 + al + ((4 - al % 4) % 4)
    method, cls = _split_type(t)
    return {"method": method, "cls": cls, "txid": txid, "attrs": attrs}


def _err_code(m):
    v = m["attrs"].get(A_ERROR)
    if not v or len(v) < 4:
        return 0, ""
    return v[2] * 100 + v[3], v[4:].decode("utf-8", "replace")


# ------------------------------------------------------------- transports
class Chan:
    """One STUN 'connection' over udp / tcp / tls with request/response."""

    def __init__(self, kind, host, port):
        self.kind, self.host, self.port = kind, host, port
        self.cert = None
        addr = socket.getaddrinfo(host, port, socket.AF_INET)[0][4]
        self.addr = addr
        if kind == "udp":
            self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.s.settimeout(TIMEOUT)
        else:
            raw = socket.create_connection(addr, timeout=TIMEOUT)
            if kind == "tls":
                ctx = ssl.create_default_context()
                self.s = ctx.wrap_socket(raw, server_hostname=host)
                c = self.s.getpeercert() or {}
                subj = dict(x[0] for x in c.get("subject", ()))
                self.cert = "CN=%s, expires %s" % (subj.get("commonName", "?"),
                                                   c.get("notAfter", "?"))
            else:
                self.s = raw
            self.s.settimeout(TIMEOUT)
        self._buf = b""

    def send(self, data):
        if self.kind == "udp":
            self.s.sendto(data, self.addr)
        else:
            self.s.sendall(data)

    def recv_msg(self, timeout=TIMEOUT):
        self.s.settimeout(timeout)
        if self.kind == "udp":
            while True:
                data, _ = self.s.recvfrom(65535)
                m = parse(data)
                if m:
                    return m
        while True:
            if len(self._buf) >= 20:
                need = 20 + struct.unpack("!H", self._buf[2:4])[0]
                if len(self._buf) >= need:
                    msg, self._buf = self._buf[:need], self._buf[need:]
                    m = parse(msg)
                    if m:
                        return m
                    continue
            chunk = self.s.recv(65535)
            if not chunk:
                raise ConnectionError("closed")
            self._buf += chunk

    def request(self, method, attrs=(), key=None, retries=3):
        msg, txid = build(method, REQ, attrs, key)
        deadline = time.time() + TIMEOUT * (retries if self.kind == "udp" else 1)
        tries = 0
        while True:
            if self.kind == "udp" or tries == 0:
                self.send(msg)
            tries += 1
            try:
                while True:
                    left = deadline - time.time()
                    if left <= 0:
                        raise socket.timeout()
                    m = self.recv_msg(min(left, 1.0 if self.kind == "udp" else left))
                    if m["txid"] == txid:
                        return m
            except socket.timeout:
                if time.time() >= deadline:
                    raise
                if self.kind != "udp":
                    continue

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def _classify(e):
    if isinstance(e, (socket.timeout, TimeoutError)):
        return "BLOCKED", "no answer within %.0fs (security group / firewall drop?)" % TIMEOUT
    if isinstance(e, ConnectionRefusedError):
        return "REFUSED", "TCP reset: port open but nothing listening"
    if isinstance(e, ssl.SSLError):
        return "FAIL", "TLS error: %s" % e.__class__.__name__ + (" %s" % getattr(e, "reason", ""))
    return "FAIL", "%s: %s" % (e.__class__.__name__, e)


# ----------------------------------------------------------------- probes
def stun_binding(kind, host, port):
    t0 = time.time()
    ch = None
    try:
        ch = Chan(kind, host, port)
        m = ch.request(BINDING)
        ms = (time.time() - t0) * 1000
        if m["cls"] != OK_:
            return "FAIL", "binding error %s" % (_err_code(m),)
        mapped = m["attrs"].get(A_XOR_MAPPED)
        ip, p = _parse_xor_addr(mapped, m["txid"]) if mapped else ("?", 0)
        d = "%.0f ms, runner seen as %s:%d" % (ms, ip, p)
        if ch.cert:
            d += "; cert %s" % ch.cert
        return "OK", d
    except Exception as e:
        return _classify(e)
    finally:
        if ch:
            ch.close()


class TurnAlloc:
    def __init__(self, kind, host, port, user, pwd):
        self.ch = Chan(kind, host, port)
        self.user, self.pwd = user, pwd
        self.key = None
        self.realm = self.nonce = b""
        self.relay = None
        self.lifetime = 0

    def _auth_attrs(self):
        return [(A_USERNAME, self.user.encode()), (A_REALM, self.realm),
                (A_NONCE, self.nonce)]

    def _authed(self, method, attrs):
        m = self.ch.request(method, list(attrs) + self._auth_attrs(), self.key)
        if m["cls"] == ERR and _err_code(m)[0] == 438:  # stale nonce
            self.nonce = m["attrs"].get(A_NONCE, self.nonce)
            m = self.ch.request(method, list(attrs) + self._auth_attrs(), self.key)
        return m

    def allocate(self):
        rt = [(A_REQ_TRANSPORT, bytes([17, 0, 0, 0])), (A_LIFETIME, struct.pack("!I", 120))]
        m = self.ch.request(ALLOCATE, rt)
        if m["cls"] == ERR and _err_code(m)[0] == 401:
            self.realm = m["attrs"].get(A_REALM, b"")
            self.nonce = m["attrs"].get(A_NONCE, b"")
            self.key = hashlib.md5(("%s:%s:%s" % (
                self.user, self.realm.decode(), self.pwd)).encode()).digest()
            m = self._authed(ALLOCATE, rt)
        if m["cls"] != OK_:
            code, reason = _err_code(m)
            raise RuntimeError("Allocate error %d %s" % (code, reason))
        self.relay = _parse_xor_addr(m["attrs"][A_XOR_RELAYED], m["txid"])
        lt = m["attrs"].get(A_LIFETIME)
        self.lifetime = struct.unpack("!I", lt)[0] if lt else 0
        return self.relay

    def permit(self, ip):
        txid = os.urandom(12)
        m = self._authed(CREATE_PERMISSION, [(A_XOR_PEER, _xor_addr(ip, 0, txid))])
        if m["cls"] != OK_:
            raise RuntimeError("CreatePermission error %s" % (_err_code(m),))

    def send_to(self, ip, port, data):
        txid = os.urandom(12)
        msg, _ = build(SEND, IND, [(A_XOR_PEER, _xor_addr(ip, port, txid)),
                                   (A_DATA, data)], txid=txid)
        self.ch.send(msg)

    def wait_data(self, timeout):
        end = time.time() + timeout
        while time.time() < end:
            try:
                m = self.ch.recv_msg(max(0.1, end - time.time()))
            except socket.timeout:
                break
            if m["method"] == DATA and m["cls"] == IND:
                return m["attrs"].get(A_DATA, b"")
        return None

    def release(self):
        try:
            self._authed(REFRESH, [(A_LIFETIME, struct.pack("!I", 0))])
        except Exception:
            pass
        self.ch.close()


def turn_probe(kind, host, port, user, pwd, relay_test):
    t0 = time.time()
    a = None
    try:
        a = TurnAlloc(kind, host, port, user, pwd)
        rip, rport = a.allocate()
        ms = (time.time() - t0) * 1000
        in_range = RELAY_MIN <= rport <= RELAY_MAX
        detail = "%.0f ms, relay %s:%d (%s 49152-65535), lifetime %ds" % (
            ms, rip, rport, "inside" if in_range else "OUTSIDE", a.lifetime)
        rows = [("TURN allocate %s %d" % (kind.upper(), port),
                 "OK" if in_range else "FAIL", detail)]
        if relay_test:
            rows.append(relay_range_test(a, host, port, rip, rport))
        return rows
    except Exception as e:
        st, d = _classify(e)
        return [("TURN allocate %s %d" % (kind.upper(), port), st, d)]
    finally:
        if a:
            a.release()


def relay_range_test(alloc, host, port, rip, rport):
    """A plain UDP socket on the runner (the 'peer') talks to the relayed
    port: inbound peer->relay (AWS SG must allow UDP 49152-65535) and back."""
    name = "Relay range UDP %d (peer<->relay)" % rport
    peer = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    peer.settimeout(TIMEOUT)
    try:
        # learn the peer socket's public address (same server IP as the relay)
        msg, txid = build(BINDING, REQ)
        addr = socket.getaddrinfo(host, port, socket.AF_INET)[0][4]
        mapped = None
        for _ in range(3):
            peer.sendto(msg, addr)
            try:
                data, _ = peer.recvfrom(2048)
                m = parse(data)
                if m and m["txid"] == txid and A_XOR_MAPPED in m["attrs"]:
                    mapped = _parse_xor_addr(m["attrs"][A_XOR_MAPPED], txid)
                    break
            except socket.timeout:
                continue
        if not mapped:
            return name, "FAIL", "could not learn the runner's public UDP address"
        alloc.permit(mapped[0])
        inbound = outbound = False
        for _ in range(3):
            peer.sendto(b"assisto-probe-in", (rip, rport))
            got = alloc.wait_data(1.5)
            if got == b"assisto-probe-in":
                inbound = True
                break
        alloc.send_to(mapped[0], mapped[1], b"assisto-probe-out")
        end = time.time() + 3
        while time.time() < end:
            try:
                data, src = peer.recvfrom(2048)
            except socket.timeout:
                break
            if data == b"assisto-probe-out":
                outbound = True
                break
        if inbound and outbound:
            return name, "OK", "data flowed both ways through the relay port"
        if outbound and not inbound:
            return name, "BLOCKED", ("relay->peer works but peer->relay port was "
                                     "dropped: open UDP 49152-65535 inbound")
        if inbound and not outbound:
            return name, "FAIL", "peer->relay works, relay->peer did not arrive (runner NAT?)"
        return name, "BLOCKED", "no data either way: open UDP 49152-65535 inbound"
    except Exception as e:
        st, d = _classify(e)
        return name, st, d
    finally:
        peer.close()


# ------------------------------------------------------------ credentials
def creds_from_api(api, phone, password):
    def call(url, body=None, token=None):
        req = urllib.request.Request(url, method="POST" if body is not None else "GET")
        req.add_header("Accept", "application/json")
        req.add_header("Accept-Language", "en")
        if body is not None:
            req.add_header("Content-Type", "application/json")
            req.data = json.dumps(body).encode()
        if token:
            req.add_header("Authorization", "Token %s" % token)
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode() or "{}")

    tok = call(api.rstrip("/") + "/auth/login",
               {"identifier": phone, "password": password}).get("token")
    if not tok:
        raise RuntimeError("login returned no token")
    _mask(tok)
    cfg = call(api.rstrip("/") + "/rtc/turn", token=tok)
    if not cfg.get("configured"):
        raise RuntimeError("/rtc/turn says TURN is not configured")
    if cfg.get("throttled"):
        raise RuntimeError("/rtc/turn is throttled (%s)" % cfg.get("reason"))
    urls = []
    for s in cfg.get("ice_servers") or []:
        if s.get("username"):
            _mask(s["username"])
            _mask(s.get("credential", ""))
            urls += s.get("urls") or []
            return s["username"], s.get("credential", ""), urls
    raise RuntimeError("no TURN entry in /rtc/turn")


def creds_from_secret(secret, ttl=3600):
    username = "%d:probe" % (int(time.time()) + ttl)
    cred = base64.b64encode(hmac.new(secret.encode(), username.encode(),
                                     hashlib.sha1).digest()).decode()
    _mask(cred)
    return username, cred


# ------------------------------------------------------------------- main
AWS_RULES = """
### If blocked: AWS security group inbound rules needed

EC2 -> Security Groups -> (the group on the lifeassisto instance) -> Inbound rules -> Add:

| Type | Protocol | Port range | Source | Why |
|---|---|---|---|---|
| Custom UDP | UDP | 3478 | 0.0.0.0/0 | STUN + TURN over UDP |
| Custom TCP | TCP | 3478 | 0.0.0.0/0 | TURN over TCP (networks that block UDP) |
| Custom TCP | TCP | 5349 | 0.0.0.0/0 | TURN over TLS (strict mobile/office networks) |
| Custom UDP | UDP | 49152 - 65535 | 0.0.0.0/0 | TURN relay ports (the media itself) |

ufw equivalent on the box:

```
sudo ufw allow 3478/udp
sudo ufw allow 3478/tcp
sudo ufw allow 5349/tcp
sudo ufw allow 49152:65535/udp
```

BLOCKED = no answer at all (security group or ufw drops it). REFUSED = the
port is open but coturn does not listen there (e.g. 5349 needs
`tls-listening-port=5349` + `cert`/`pkey` in /etc/turnserver.conf).
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("TURN_PROBE_HOST") or "turn.lifeassisto.com")
    ap.add_argument("--api", default=os.environ.get("API_BASE") or "https://api.lifeassisto.com/api/v1")
    ap.add_argument("--port", type=int, default=3478)
    ap.add_argument("--tls-port", type=int, default=5349)
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    a = ap.parse_args()

    rows = []
    try:
        ip = socket.gethostbyname(a.host)
        rows.append(("DNS %s" % a.host, "OK", ip))
    except Exception as e:
        rows.append(("DNS %s" % a.host, "FAIL", str(e)))
        ip = None

    user = pwd = None
    source = "none"
    phone, pw = os.environ.get("CALL_PROOF_A_PHONE"), os.environ.get("CALL_PROOF_A_PASSWORD")
    secret = os.environ.get("TURN_STATIC_SECRET", "")
    _mask(pw)
    _mask(secret)
    if phone and pw:
        try:
            user, pwd, urls = creds_from_api(a.api, phone, pw)
            source = "live API /rtc/turn (logged in as the proof account A)"
            rows.append(("Credentials via /rtc/turn", "OK",
                         "TURN urls handed out: " + ", ".join(urls)))
        except Exception as e:
            rows.append(("Credentials via /rtc/turn", "FAIL", "%s: %s" % (
                e.__class__.__name__, str(e)[:160])))
    if user is None and secret:
        user, pwd = creds_from_secret(secret)
        source = "minted from TURN_STATIC_SECRET"
    if user is None:
        rows.append(("TURN credentials", "SKIPPED",
                     "no CALL_PROOF_A_* or TURN_STATIC_SECRET secret: allocation tests skipped"))

    if ip:
        rows.append(("STUN UDP %d" % a.port,) + stun_binding("udp", a.host, a.port))
        rows.append(("STUN over TCP %d" % a.port,) + stun_binding("tcp", a.host, a.port))
        rows.append(("STUN over TLS %d" % a.tls_port,) + stun_binding("tls", a.host, a.tls_port))
        if user:
            rows += turn_probe("udp", a.host, a.port, user, pwd, relay_test=True)
            rows += turn_probe("tcp", a.host, a.port, user, pwd, relay_test=True)
            if any(r[0].startswith("STUN over TLS") and r[1] == "OK" for r in rows):
                rows += turn_probe("tls", a.host, a.tls_port, user, pwd, relay_test=False)
            else:
                rows.append(("TURN allocate TLS %d" % a.tls_port, "SKIPPED",
                             "TLS port not reachable (see STUN over TLS row)"))

    out = ["## TURN probe from outside AWS (GitHub runner)", "",
           "Host `%s`, credentials: %s." % (a.host, source), "",
           "| Check | Result | Detail |", "|---|---|---|"]
    icon = {"OK": "OK", "BLOCKED": "**BLOCKED**", "REFUSED": "**REFUSED**",
            "FAIL": "**FAIL**", "SKIPPED": "skipped"}
    for name, st, d in rows:
        out.append("| %s | %s | %s |" % (name, icon.get(st, st), str(d).replace("|", "/")))
    bad = [r for r in rows if r[1] in ("BLOCKED", "REFUSED", "FAIL")]
    out += ["", "**Verdict:** %s" % (
        "everything reachable — relay works from the internet." if not bad else
        "%d check(s) not OK: %s" % (len(bad), "; ".join(r[0] for r in bad)))]
    out.append(AWS_RULES)
    text = "\n".join(out)
    print(text)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
