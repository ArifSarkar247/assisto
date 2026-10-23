"""b3-group: LiveKit SFU helpers for group calls — PURE (no Django, no DB, no
clock: the caller passes `now_ts`).

  * a minimal HS256 JWT (encode + verify) — LiveKit access tokens, the server
    API (RoomService over Twirp) token and the webhook signature all use
    HS256 with the API secret, so no `livekit-api` / PyJWT dependency;
  * the access-token claims for one participant (room join, publish /
    subscribe, host = roomAdmin);
  * SFU bandwidth (egress) metering math for the P&L;
  * the CONSENT state machine for call recording (B5) — 1:1 and group share
    it: recording runs ONLY while every current participant has accepted.

LiveKit token format (https://docs.livekit.io/home/get-started/authentication/):
    iss = API key, sub = identity, nbf / exp, name, metadata,
    video = {room, roomJoin, canPublish, canSubscribe, canPublishData,
             roomAdmin?}
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json

TOKEN_TTL_S = 2 * 3600          # a join token is valid for 2 h (rejoin)
ADMIN_TTL_S = 120               # server -> LiveKit API calls
DEFAULT_MAX_PARTICIPANTS = 8
HARD_MAX_PARTICIPANTS = 16      # a t3.large; the owner can lower, never above
DEFAULT_AUDIO_KBPS = 40.0       # Opus voice, per published stream
DEFAULT_VIDEO_KBPS = 600.0      # simulcast mid layer, per published stream
DEFAULT_EGRESS_USD_PER_GB = 0.1093   # AWS ap-south-1 (same as TURN)
GIB = 1024 ** 3


# ------------------------------------------------------------------ JWT
def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _unb64(s: str) -> bytes:
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def jwt_encode(claims: dict, secret: str) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    h = _b64(json.dumps(header, separators=(",", ":")).encode())
    p = _b64(json.dumps(claims, separators=(",", ":"), sort_keys=True).encode())
    sig = hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64(sig)}"


class TokenError(ValueError):
    pass


def jwt_decode(token: str, secret: str, now_ts=None, leeway=10) -> dict:
    """Verify an HS256 JWT (signature, alg, nbf/exp when now_ts is given).
    Raises TokenError. Used for the LiveKit webhook and in tests."""
    try:
        h, p, s = str(token or "").split(".")
        header = json.loads(_unb64(h))
        claims = json.loads(_unb64(p))
        sig = _unb64(s)
    except Exception:
        raise TokenError("malformed")
    if header.get("alg") != "HS256":
        raise TokenError("alg")
    want = hmac.new(secret.encode(), f"{h}.{p}".encode(), hashlib.sha256).digest()
    if not hmac.compare_digest(sig, want):
        raise TokenError("signature")
    if now_ts is not None:
        if "exp" in claims and now_ts > float(claims["exp"]) + leeway:
            raise TokenError("expired")
        if "nbf" in claims and now_ts + leeway < float(claims["nbf"]):
            raise TokenError("not_yet_valid")
    return claims


def access_token(api_key, api_secret, *, identity, name, room, now_ts,
                 ttl=TOKEN_TTL_S, host=False, can_publish=True,
                 can_subscribe=True, metadata=None):
    """The LiveKit JWT for one participant of `room`. `host` adds roomAdmin
    (LiveKit lets a room admin mute/remove from the client too; we still run
    host actions through OUR server so they are audited and gated)."""
    now = int(now_ts)
    grant = {"room": str(room), "roomJoin": True,
             "canPublish": bool(can_publish),
             "canSubscribe": bool(can_subscribe),
             "canPublishData": True}
    if host:
        grant["roomAdmin"] = True
    claims = {"iss": api_key, "sub": str(identity), "nbf": now - 5,
              "exp": now + int(ttl), "name": str(name or "")[:80],
              "video": grant}
    if metadata:
        claims["metadata"] = json.dumps(metadata, separators=(",", ":"))
    return jwt_encode(claims, api_secret)


def admin_token(api_key, api_secret, room, now_ts, ttl=ADMIN_TTL_S):
    """Bearer token for RoomService calls about `room` (mute / remove / list
    / delete)."""
    now = int(now_ts)
    return jwt_encode({"iss": api_key, "nbf": now - 5, "exp": now + int(ttl),
                       "video": {"room": str(room), "roomAdmin": True,
                                 "roomList": True, "roomCreate": True}},
                      api_secret)


def webhook_body_ok(claims: dict, body: bytes) -> bool:
    """LiveKit webhooks: Authorization = JWT whose `sha256` claim is the
    base64 sha256 of the raw body."""
    want = base64.b64encode(hashlib.sha256(body or b"").digest()).decode()
    got = str(claims.get("sha256") or "")
    return bool(got) and hmac.compare_digest(got, want)


def http_base(ws_url: str) -> str:
    """wss://host/path -> https://host/path (RoomService base)."""
    u = str(ws_url or "").rstrip("/")
    if u.startswith("wss://"):
        return "https://" + u[6:]
    if u.startswith("ws://"):
        return "http://" + u[5:]
    return u


def clamp_max(n, hard=HARD_MAX_PARTICIPANTS):
    try:
        n = int(n)
    except (TypeError, ValueError):
        n = DEFAULT_MAX_PARTICIPANTS
    return max(3, min(hard, n))


# ------------------------------------------------------------------ cost
def stream_rates(n_present, n_video):
    """Downstream (server -> phones) streams while `n_present` people are in
    the room and `n_video` of them publish a camera/screen: every listener
    receives every OTHER publisher once (SFU forwarding, no mixing).
    -> (audio_streams, video_streams)."""
    n = max(0, int(n_present))
    v = max(0, min(n, int(n_video)))
    if n < 2:
        return 0, 0
    return n * (n - 1), v * (n - 1)


def tick(acc_audio_s, acc_video_s, n_present, n_video, seconds):
    """Accumulate stream-seconds for `seconds` at the given room shape."""
    a, v = stream_rates(n_present, n_video)
    s = max(0.0, float(seconds))
    return acc_audio_s + a * s, acc_video_s + v * s


def egress_bytes(audio_stream_s, video_stream_s, audio_kbps=DEFAULT_AUDIO_KBPS,
                 video_kbps=DEFAULT_VIDEO_KBPS):
    """Bytes the SFU sends out for the accumulated stream-seconds (ingress
    is free on AWS; each stream leaves the server once per listener)."""
    return (audio_stream_s * audio_kbps + video_stream_s * video_kbps) * 1000.0 / 8.0


def bdt_for_bytes(n_bytes, bdt_per_gb):
    return n_bytes / GIB * float(bdt_per_gb)


def per_participant_minute_bdt(n_present, video, audio_kbps, video_kbps,
                               bdt_per_gb):
    """What ONE participant-minute costs at room size n (shown in Owner
    Admin so the owner sees the price of a 3-person / 8-person call)."""
    n = max(2, int(n_present))
    kbps = audio_kbps * (n - 1) + (video_kbps * (n - 1) if video else 0)
    return bdt_for_bytes(kbps * 1000.0 / 8.0 * 60, bdt_per_gb)


# ------------------------------------------------------------------ consent
# Recording (B5) is NEVER silent: the requester asks, every participant must
# accept, any decline cancels it, and a newcomer who has not accepted pauses
# it until they do. States:
#   none       nothing requested
#   pending    asked; waiting for the others
#   recording  everyone present accepted -> the requester's phone records
#   paused     someone present has not accepted (a new joiner) -> no audio
#   declined   someone said no -> nothing (more) is recorded; terminal
#   stopped    the requester (or anyone) stopped it; terminal
CONSENT_TERMINAL = ("declined", "stopped")


def consent_new(requester_id, request_id, present_ids, now_iso=""):
    st = {"id": int(request_id), "requester": int(requester_id),
          "status": "pending", "accepted": [int(requester_id)],
          "declined_by": None, "started_at": None, "updated_at": now_iso}
    return consent_eval(st, present_ids, now_iso)


def consent_eval(state, present_ids, now_iso=""):
    """Recompute pending / recording / paused for the people present now.
    Terminal states never change."""
    st = dict(state or {})
    status = st.get("status") or "none"
    if status in CONSENT_TERMINAL or status == "none":
        return st
    present = {int(x) for x in present_ids}
    acc = {int(x) for x in st.get("accepted") or []}
    everyone = len(present) >= 2 and present <= acc
    if everyone:
        if status != "recording":
            st["status"] = "recording"
            st["ever"] = True
            if not st.get("started_at"):
                st["started_at"] = now_iso
    else:
        # not everybody present agreed -> nothing is recorded (a newcomer
        # pauses a running recording until they accept)
        st["status"] = "paused" if st.get("ever") else "pending"
    st["updated_at"] = now_iso
    return st


def consent_accept(state, user_id, present_ids, now_iso=""):
    st = dict(state or {})
    if (st.get("status") or "none") in CONSENT_TERMINAL + ("none",):
        return st
    acc = [int(x) for x in st.get("accepted") or []]
    if int(user_id) not in acc:
        acc.append(int(user_id))
    st["accepted"] = acc
    return consent_eval(st, present_ids, now_iso)


def consent_decline(state, user_id, now_iso=""):
    st = dict(state or {})
    if (st.get("status") or "none") in CONSENT_TERMINAL + ("none",):
        return st
    st["status"] = "declined"
    st["declined_by"] = int(user_id)
    st["updated_at"] = now_iso
    return st


def consent_stop(state, user_id, now_iso=""):
    st = dict(state or {})
    if (st.get("status") or "none") in CONSENT_TERMINAL + ("none",):
        return st
    st["status"] = "stopped"
    st["stopped_by"] = int(user_id)
    st["updated_at"] = now_iso
    return st


def consent_may_record(state):
    return (state or {}).get("status") == "recording"


def consent_view(state, viewer_id):
    """What one phone needs: the status, who asked, whether I still have to
    answer, and whether my phone is the one recording."""
    st = state or {}
    status = st.get("status") or "none"
    acc = {int(x) for x in st.get("accepted") or []}
    req = st.get("requester")
    return {"id": st.get("id"), "status": status, "requester": req,
            "accepted": sorted(acc), "declined_by": st.get("declined_by"),
            "i_must_answer": status in ("pending", "paused")
            and int(viewer_id) not in acc,
            "i_record": status == "recording" and req is not None
            and int(req) == int(viewer_id),
            "started_at": st.get("started_at")}
