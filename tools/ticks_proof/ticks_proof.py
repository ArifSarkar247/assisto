#!/usr/bin/env python3
"""x2-ticks A4 — TWO-CLIENT tick proof against the LIVE server.

  A (sender)  --POST /circle/<edge>/messages-->  server
  B (recipient) gets `msg.new` on its realtime queue (what an open app sees)
                and acks DELIVERED exactly like the app's FCM background
                isolate: POST /circle/receipts {delivered:[id]} with its token
  A sees `receipt.update` ... "delivered"  -> ✓✓      (target < 2 s)
  B opens the chat: POST /circle/<edge>/seen
  A sees `receipt.update` ... "read"       -> blue ✓✓ (target < 1 s)

Timings are measured AS SEEN BY A (A polls GET /rt/events every 0.25 s; the
app polls 0.5 s while it waits for ticks, so add <= 0.25 s for a phone).

CRYPTO: the message is encrypted exactly like the app (crypto/e2e.dart
SoftwareE2E, scheme x25519-xchacha-fallback-v1: X25519 -> HKDF-SHA256(zero
salt, info = "assisto-circle-<scheme>" || lo(pubA,pubB) || hi) -> ChaCha20-
Poly1305, 12-byte nonce, AAD = sender key id). The script uses EPHEMERAL
keys and never publishes them (the test phones' real keys stay intact), so
the server stores an opaque but correctly-formed envelope; B decrypts it
locally with the ephemeral key to prove the round trip. Set
TICKS_PROOF_PUBLISH_KEYS=1 to publish the ephemeral keys instead.

Env: API_BASE (default https://api.lifeassisto.com), CALL_PROOF_A_PHONE,
CALL_PROOF_A_PASSWORD, CALL_PROOF_B_PHONE, CALL_PROOF_B_PASSWORD,
TICKS_PROOF_ROUNDS (default 3), optional TICKS_PROOF_A_EDGE /
TICKS_PROOF_B_EDGE (circle member ids when name matching is ambiguous).
Writes a Markdown table to $GITHUB_STEP_SUMMARY (and stdout). Exit 1 when a
round misses delivered/read or a target (unless read receipts are off — then
the read step is reported honestly as "receipts off").

  python3 tools/ticks_proof/ticks_proof.py           # live
  python3 tools/ticks_proof/ticks_proof.py --selftest  # crypto only
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request

SCHEME = "x25519-xchacha-fallback-v1"
DELIVERED_TARGET_S = 2.0
READ_TARGET_S = 1.0
POLL_S = 0.25
WAIT_S = 20.0


# --------------------------------------------------------------- crypto
def _hkdf(ikm, info, length=32, salt=None):
    salt = salt if salt is not None else b"\x00" * 32
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, prev, n = b"", b"", 1
    while len(out) < length:
        prev = hmac.new(prk, prev + info + bytes([n]), hashlib.sha256).digest()
        out += prev
        n += 1
    return out[:length]


def _context(a, b):
    lo, hi = (a, b) if a < b else (b, a)   # bytewise lexicographic == Dart
    return ("assisto-circle-%s" % SCHEME).encode() + lo + hi


def key_id(pub):
    return hashlib.sha256(pub).hexdigest()[:12]


class Identity:
    def __init__(self, priv=None):
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PrivateKey)
        from cryptography.hazmat.primitives import serialization as S
        if priv is None:
            priv = bytearray(os.urandom(32))
            priv[0] &= 248
            priv[31] &= 127
            priv[31] |= 64
            priv = bytes(priv)
        self.priv = priv
        self._k = X25519PrivateKey.from_private_bytes(priv)
        self.pub = self._k.public_key().public_bytes(
            S.Encoding.Raw, S.PublicFormat.Raw)
        self.kid = key_id(self.pub)

    def shared(self, peer_pub):
        from cryptography.hazmat.primitives.asymmetric.x25519 import (
            X25519PublicKey)
        return self._k.exchange(X25519PublicKey.from_public_bytes(peer_pub))


def encrypt(me, peer_pub, text, nonce=None):
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    key = _hkdf(me.shared(peer_pub), _context(me.pub, peer_pub))
    nonce = nonce or os.urandom(12)
    ct = ChaCha20Poly1305(key).encrypt(nonce, text.encode(), me.kid.encode())
    return {"ciphertext": base64.b64encode(ct).decode(),
            "nonce": base64.b64encode(nonce).decode(),
            "sender_key_id": me.kid, "scheme": SCHEME}


def decrypt(me, sender_pub, env):
    from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
    key = _hkdf(me.shared(sender_pub), _context(sender_pub, me.pub))
    pt = ChaCha20Poly1305(key).decrypt(
        base64.b64decode(env["nonce"]), base64.b64decode(env["ciphertext"]),
        env["sender_key_id"].encode())
    return pt.decode()


# A fixed vector the Dart test (app/test/x2_ticks_test.dart) decrypts with
# SoftwareE2E — proves this Python matches the app's crypto contract.
VECTOR = {
    "a_priv": "a8" + "11" * 30 + "51",
    "b_priv": "b0" + "22" * 30 + "62",
    "nonce": "000102030405060708090a0b",
    "text": "ticks-proof ✓✓",
}


def vector():
    a = Identity(bytes.fromhex(VECTOR["a_priv"]))
    b = Identity(bytes.fromhex(VECTOR["b_priv"]))
    env = encrypt(a, b.pub, VECTOR["text"], bytes.fromhex(VECTOR["nonce"]))
    return a, b, env


def selftest():
    a, b, env = vector()
    assert decrypt(b, a.pub, env) == VECTOR["text"]
    x, y = Identity(), Identity()
    assert decrypt(y, x.pub, encrypt(x, y.pub, "hi")) == "hi"
    print("selftest ok")
    print(json.dumps({"a_pub": base64.b64encode(a.pub).decode(),
                      "b_pub": base64.b64encode(b.pub).decode(), **env},
                     indent=1))


# --------------------------------------------------------------- HTTP
class Client:
    def __init__(self, base, name):
        self.base = base.rstrip("/") + "/api/v1"
        self.name = name
        self.token = None

    def req(self, method, path, body=None, timeout=20):
        data = None if body is None else json.dumps(body).encode()
        r = urllib.request.Request(self.base + path, data=data, method=method)
        r.add_header("Content-Type", "application/json")
        r.add_header("Accept-Language", "en")
        r.add_header("User-Agent", "assisto-ticks-proof/1")
        if self.token:
            r.add_header("Authorization", "Token " + self.token)
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except Exception:
                return e.code, {"raw": raw[:200].decode("utf-8", "replace")}

    def login(self, phone, password):
        st, j = self.req("POST", "/auth/login",
                         {"identifier": phone, "password": password})
        if st != 200 or "token" not in j:
            raise SystemExit("%s: login failed (HTTP %s)" % (self.name, st))
        self.token = j["token"]
        self.user = j.get("user") or {}
        return self.user

    def seq(self):
        st, j = self.req("GET", "/rt/events?after=0&topics=__none__")
        return int(j.get("seq") or 0) if st == 200 else 0

    def wait_event(self, after, pred, timeout=WAIT_S):
        """Poll rt/events like the app; returns (event, t_seen, new_after)."""
        end = time.time() + timeout
        while time.time() < end:
            st, j = self.req("GET", "/rt/events?after=%d" % after)
            now = time.time()
            if st == 200:
                for e in j.get("events", []):
                    after = max(after, int(e.get("seq") or 0))
                    if pred(e):
                        return e, now, after
            time.sleep(POLL_S)
        return None, None, after


def find_edge(client, peer_name, override):
    if override:
        return int(override)
    st, j = client.req("GET", "/circle/members")
    rows = j.get("results", j if isinstance(j, list) else [])
    hits = [r for r in rows if (r.get("name") or "").strip()
            == (peer_name or "").strip()]
    if len(hits) != 1:
        raise SystemExit("%s: cannot find ONE circle edge named %r (found %d)"
                         " — set TICKS_PROOF_%s_EDGE" % (
                             client.name, peer_name, len(hits),
                             client.name[-1]))
    return int(hits[0]["id"])


def ms(x):
    return "—" if x is None else "%.0f ms" % (x * 1000)


def run():
    base = os.environ.get("API_BASE", "https://api.lifeassisto.com")
    need = ["CALL_PROOF_A_PHONE", "CALL_PROOF_A_PASSWORD",
            "CALL_PROOF_B_PHONE", "CALL_PROOF_B_PASSWORD"]
    miss = [k for k in need if not os.environ.get(k)]
    if miss:
        raise SystemExit("missing secrets: " + ", ".join(miss))
    rounds = int(os.environ.get("TICKS_PROOF_ROUNDS", "3"))
    A, B = Client(base, "A"), Client(base, "B")
    ua = A.login(os.environ["CALL_PROOF_A_PHONE"],
                 os.environ["CALL_PROOF_A_PASSWORD"])
    ub = B.login(os.environ["CALL_PROOF_B_PHONE"],
                 os.environ["CALL_PROOF_B_PASSWORD"])
    edge_a = find_edge(A, ub.get("name"), os.environ.get("TICKS_PROOF_A_EDGE"))
    edge_b = find_edge(B, ua.get("name"), os.environ.get("TICKS_PROOF_B_EDGE"))
    ka, kb = Identity(), Identity()
    if os.environ.get("TICKS_PROOF_PUBLISH_KEYS") == "1":
        for c, k in ((A, ka), (B, kb)):
            c.req("POST", "/circle/keys", {"public_key": base64.b64encode(
                k.pub).decode(), "key_id": k.kid, "scheme": SCHEME})

    rows, failures = [], []
    for i in range(1, rounds + 1):
        a_after, b_after = A.seq(), B.seq()
        text = "[ticks-proof %d/%d] %s" % (i, rounds, time.strftime("%H:%M:%S"))
        env = encrypt(ka, kb.pub, text)
        env.update(content_type="text",
                   client_msg_id="tp-%d-%d" % (int(time.time() * 1000), i))
        t0 = time.time()
        st, j = A.req("POST", "/circle/%d/messages" % edge_a, env)
        t_sent = time.time()
        if st != 201:
            failures.append("round %d: send HTTP %s %s" % (i, st, j))
            continue
        mid = int(j["id"])
        # B: the open app's realtime "msg.new" (FCM is the closed-app path)
        e, t_new, b_after = B.wait_event(
            b_after, lambda e: e["topic"] == "msg.new"
            and int(e["payload"].get("message_id") or 0) == mid)
        # B acks exactly like the FCM background isolate
        t_ack = time.time()
        st2, j2 = B.req("POST", "/circle/receipts", {"delivered": [mid]})
        ok_ack = st2 == 200 and mid in (j2.get("accepted") or [])
        # round-trip decrypt on "B's phone" (fetch its own copy)
        st3, j3 = B.req("GET", "/circle/%d/messages" % edge_b)
        mine = [m for m in j3.get("results", []) if int(m["id"]) == mid]
        dec = None
        if mine:
            try:
                dec = decrypt(kb, ka.pub, mine[0])
            except Exception:
                dec = None
        # A: ✓✓
        e2, t_dl, a_after = A.wait_event(
            a_after, lambda e: e["topic"] == "receipt.update"
            and e["payload"].get("statuses", {}).get(str(mid))
            in ("delivered", "read"))
        # B opens the chat (visible) -> seen
        time.sleep(1.0)
        t_open = time.time()
        B.req("POST", "/circle/%d/seen" % edge_b)
        e3, t_rd, a_after = A.wait_event(
            a_after, lambda e: e["topic"] == "receipt.update"
            and e["payload"].get("statuses", {}).get(str(mid)) == "read",
            timeout=8.0)
        _, info = A.req("GET", "/circle/messages/%d/info" % mid)
        rec = (info.get("recipients") or [{}])[0]
        receipts_off = bool(rec.get("receipts_off"))
        dl_lat = (t_dl - t_ack) if t_dl else None
        rd_lat = (t_rd - t_open) if t_rd else None
        row = {
            "round": i, "id": mid, "send": t_sent - t0,
            "msg_new_to_B": (t_new - t_sent) if t_new else None,
            "ack_ok": ok_ack, "decrypt_ok": dec == text,
            "delivered_at_A": (t_dl - t_sent) if t_dl else None,
            "delivered_after_ack": dl_lat,
            "read_after_open": rd_lat, "receipts_off": receipts_off,
            "server_delivered": rec.get("delivered_at"),
            "server_seen": rec.get("seen_at"),
        }
        rows.append(row)
        if not ok_ack or t_dl is None:
            failures.append("round %d: no ✓✓ at A" % i)
        elif dl_lat > DELIVERED_TARGET_S:
            failures.append("round %d: ✓✓ took %s" % (i, ms(dl_lat)))
        if receipts_off:
            pass   # honest: read can't be shown — reported below
        elif t_rd is None:
            failures.append("round %d: no blue ✓✓ at A" % i)
        elif rd_lat > READ_TARGET_S:
            failures.append("round %d: blue ✓✓ took %s" % (i, ms(rd_lat)))
        if dec != text:
            failures.append("round %d: decrypt round trip failed" % i)
    report(rows, failures, base)
    return 1 if failures else 0


def report(rows, failures, base):
    lines = ["## Ticks proof (live: %s)" % base, "",
             "| # | msg id | ✓ sent (POST) | msg.new → B | ✓✓ at A "
             "(after B's ack) | ✓✓ at A (after send) | blue ✓✓ at A (after "
             "B opens) | decrypt | server delivered / seen |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        read = ("receipts off (privacy)" if r["receipts_off"]
                else ms(r["read_after_open"]))
        lines.append("| %d | %d | %s | %s | %s | %s | %s | %s | %s / %s |" % (
            r["round"], r["id"], ms(r["send"]), ms(r["msg_new_to_B"]),
            ms(r["delivered_after_ack"]), ms(r["delivered_at_A"]), read,
            "ok" if r["decrypt_ok"] else "FAIL",
            r["server_delivered"] or "—", r["server_seen"] or "—"))
    lines += ["", "Targets: ✓✓ < %.0f s, blue ✓✓ < %.0f s (A polls every "
              "%.2f s; a phone waiting for ticks polls 0.5 s)." % (
                  DELIVERED_TARGET_S, READ_TARGET_S, POLL_S), ""]
    lines += (["**FAIL**"] + ["- " + f for f in failures]) if failures \
        else ["**PASS** — every round reached ✓ → ✓✓ → blue ✓✓ in time."]
    lines += ["", "Not covered here: the real FCM delivery to a CLOSED phone"
              " (needs a device); this run exercises the exact ack request the"
              " FCM background isolate sends."]
    out = "\n".join(lines)
    print(out)
    p = os.environ.get("GITHUB_STEP_SUMMARY")
    if p:
        with open(p, "a", encoding="utf-8") as f:
            f.write(out + "\n")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    sys.exit(run())
