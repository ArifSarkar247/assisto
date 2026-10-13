"""
circle_calls.py — Assisto "Connected Circle" CALLS logic (M1 item 5).

Pure Python, deterministic, no DB, no AI key.  This module is the SERVER-SIDE
authority for calls; the integrator wires it into the call-signalling view so
the client can never bypass the rules.  Benchmarked against WhatsApp +
Messenger voice/video calling.

THE CALL CONTRACT (owner-specified, enforced here):
  - VOICE calls are FREE for everyone in an accepted relationship.
  - VIDEO calls are PREMIUM-ONLY for the *CALLER*: the person PLACING the video
    call must hold Premium / Family / Business (or have redeemed referral points
    for it).  The RECEIVER may be free — a Premium son can video-call his free
    mother.  This is gated in `can_place_call()`; the AI/client CANNOT bypass it
    because the signalling endpoint calls this function before issuing an offer.
  - A call may only be placed between two members whose relationship is mutually
    ACCEPTED and not blocked/restricted (privacy is enforced in
    circle_privacy.py — the view calls BOTH).
  - WebRTC 1:1 is the transport.  It works WHILE THE APP IS OPEN now via the
    relay's local signalling.  App-closed ring (FCM data / APNs PushKit +
    CallKit) and a production TURN relay are KEY-GATED on infra the owner
    provisions; `transport_status()` states exactly what works now.

WHAT LIVES HERE (logic/state only — the DB CallRecord model, the WebRTC offer/
answer relay endpoint, the push ring and the TURN server are platform-gated and
marked for the integrator):
  - `can_place_call(caller, callee, kind)` — the video plan gate (THE gate).
  - Call-record state machine: ringing -> connecting -> active -> ended, plus
    missed / declined / failed / canceled, with duration + call-back eligibility.
  - Call kinds + low-data / mute / speaker / camera control flags.
  - Transport status strings ("works while app open"; "app-closed ring available
    when push keys are set"; "HD video available when TURN server is live").
  - Bilingual upgrade prompt + missed-call / history labels.

Run self-tests (no DB):
    python3 -c "import core.logic.circle_calls_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# Plans / entitlement — which plans may PLACE a video call
# ---------------------------------------------------------------------------
# The caller's plan slug comes from the same source as /me/plan ("free",
# "premium", "annual", "family", "business", ...).  Any paid tier that includes
# the video entitlement is listed here.  Referral points can mint a temporary
# "video unlock" that the integrator records on the member; `video_unlocked`
# lets that override the plan check without touching this allow-list.

CALL_VOICE = "voice"
CALL_VIDEO = "video"
CALL_KINDS = (CALL_VOICE, CALL_VIDEO)

# Plan slugs whose holder may PLACE a video call.  Voice is free for all plans.
VIDEO_PLANS = {"premium", "annual", "family", "business", "premium_annual", "pro"}


def normalize_kind(kind):
    k = (kind or "").strip().lower()
    return k if k in CALL_KINDS else CALL_VOICE


def plan_allows_video(plan):
    """Does this plan slug include the video-call entitlement?"""
    return (plan or "").strip().lower() in VIDEO_PLANS


def can_place_call(caller, callee, kind):
    """THE server-side call gate.  Returns a dict:
        {allowed, kind, reason, upgrade_required, needs_video_plan}

    `caller` and `callee` are resolved member dicts.  Required caller keys:
        plan                -> plan slug ("free"/"premium"/...)
        video_unlocked      -> bool (referral-points unlock), optional
    Required relationship keys on BOTH (so the view passes the mutual row):
        accepted            -> bool (relationship mutually accepted)
        blocked             -> bool (either side blocked), optional
        restricted          -> bool (callee restricted the caller), optional

    RULES (in order):
      1. Relationship must be mutually accepted and not blocked  -> else deny.
      2. VOICE  -> always allowed for an accepted, non-blocked pair.
      3. VIDEO  -> allowed ONLY if the CALLER's plan allows video OR the caller
         has a referral-points video unlock.  Receiver plan is irrelevant.

    The signalling endpoint MUST call this before creating a WebRTC offer; it is
    the single source of truth for the video entitlement and cannot be bypassed
    by a client that simply sets kind='video'.
    """
    caller = caller or {}
    callee = callee or {}
    kind = normalize_kind(kind)

    accepted = bool(caller.get("accepted", True)) and bool(callee.get("accepted", True))
    blocked = bool(caller.get("blocked")) or bool(callee.get("blocked"))
    restricted = bool(callee.get("restricted"))

    if blocked or not accepted:
        return {
            "allowed": False,
            "kind": kind,
            "reason": "not_connected",
            "upgrade_required": False,
            "needs_video_plan": False,
        }

    # A restricted contact's call must not RING (see circle_privacy.allow_call),
    # but placing is not an entitlement error — the view decides ring vs silent.
    # We still allow the record so the missed call is logged on the restricted
    # side's filtered inbox.  can_place_call reports entitlement only.

    if kind == CALL_VOICE:
        return {
            "allowed": True,
            "kind": kind,
            "reason": "ok",
            "upgrade_required": False,
            "needs_video_plan": False,
            "silent": restricted,
        }

    # kind == video: gate on the CALLER's entitlement only.
    if plan_allows_video(caller.get("plan")) or bool(caller.get("video_unlocked")):
        return {
            "allowed": True,
            "kind": kind,
            "reason": "ok",
            "upgrade_required": False,
            "needs_video_plan": False,
            "silent": restricted,
        }

    return {
        "allowed": False,
        "kind": kind,
        "reason": "video_requires_premium",
        "upgrade_required": True,
        "needs_video_plan": True,
    }


def upgrade_prompt(lang="bn"):
    """Shown to a FREE caller who tries to place a video call."""
    return {
        "kind": "circle_call_upgrade",
        "title": pick(lang, "ভিডিও কল প্রিমিয়াম সুবিধা", "Video calling is Premium"),
        "body": pick(
            lang,
            "ভিডিও কল করতে প্রিমিয়াম লাগবে। ভয়েস কল সবার জন্য ফ্রি। "
            "রেফারেল পয়েন্ট দিয়েও আনলক করা যায়।",
            "Video calling needs Premium. Voice calls are free for everyone. "
            "You can also unlock it with referral points.",
        ),
        "cta_upgrade": pick(lang, "প্রিমিয়াম নিন", "Get Premium"),
        "cta_points": pick(lang, "পয়েন্ট দিয়ে আনলক", "Unlock with points"),
    }


# ---------------------------------------------------------------------------
# Call-record state machine
# ---------------------------------------------------------------------------
# A call record tracks one 1:1 call.  The caller side drives ringing; the callee
# accepts / declines; either side may hang up.  Terminal states carry an outcome
# used by call history (missed / answered / declined / canceled / failed).

CALL_RINGING = "ringing"        # offer sent, awaiting answer
CALL_CONNECTING = "connecting"  # answered, media negotiating
CALL_ACTIVE = "active"          # media flowing
CALL_ENDED = "ended"            # normal hang-up after being active
CALL_MISSED = "missed"          # callee never answered (rang out)
CALL_DECLINED = "declined"      # callee actively declined
CALL_CANCELED = "canceled"      # caller hung up before answer
CALL_FAILED = "failed"          # transport/negotiation failure

CALL_STATES = {
    CALL_RINGING, CALL_CONNECTING, CALL_ACTIVE, CALL_ENDED,
    CALL_MISSED, CALL_DECLINED, CALL_CANCELED, CALL_FAILED,
}
_TERMINAL = {CALL_ENDED, CALL_MISSED, CALL_DECLINED, CALL_CANCELED, CALL_FAILED}

# current -> {event: next}.  Events name an actor action or a timeout.
_CALL_TRANSITIONS = {
    CALL_RINGING: {
        "answer": CALL_CONNECTING,
        "decline": CALL_DECLINED,     # callee declines
        "cancel": CALL_CANCELED,      # caller hangs up before answer
        "timeout": CALL_MISSED,       # rang out, no answer
        "fail": CALL_FAILED,
    },
    CALL_CONNECTING: {
        "connected": CALL_ACTIVE,
        "hangup": CALL_ENDED,
        "fail": CALL_FAILED,
    },
    CALL_ACTIVE: {
        "hangup": CALL_ENDED,
        "fail": CALL_FAILED,
    },
}


def apply_call_event(state, event):
    """Return (new_state, changed).  Illegal/unknown events are no-ops so the
    signalling endpoint can reject without raising."""
    state = state if state in CALL_STATES else CALL_RINGING
    nxt = _CALL_TRANSITIONS.get(state, {}).get(event)
    if nxt is None:
        return state, False
    return nxt, True


def is_terminal(state):
    return state in _TERMINAL


def is_missed(state):
    """A missed call for history = rang out OR canceled before the callee
    answered.  (Declined is shown separately; it is not 'missed'.)"""
    return state in (CALL_MISSED, CALL_CANCELED)


def can_call_back(record):
    """May the user offer a one-tap call-back for this record?  Yes for any
    terminated call where a conversation did not complete normally OR for any
    ended call (call-back is always offered in history)."""
    state = (record or {}).get("state", "")
    return state in _TERMINAL


# ---------------------------------------------------------------------------
# Call record construction + duration
# ---------------------------------------------------------------------------

def new_call_record(call_id, caller_id, callee_id, kind, started_at=None):
    """Create a fresh ringing call record (the DB row the integrator persists).
    `kind` must already have passed can_place_call()."""
    started_at = started_at or datetime.now(timezone.utc)
    return {
        "id": call_id,
        "caller_id": caller_id,
        "callee_id": callee_id,
        "kind": normalize_kind(kind),
        "state": CALL_RINGING,
        "started_at": _iso(started_at),
        "answered_at": None,
        "ended_at": None,
        "duration_sec": 0,
        "low_data": False,
    }


def finalize_call(record, event, at=None):
    """Advance a record by `event`, stamping answered_at/ended_at/duration.
    Returns the updated record (new dict).  The integrator saves it."""
    record = dict(record or {})
    at = at or datetime.now(timezone.utc)
    state, changed = apply_call_event(record.get("state", CALL_RINGING), event)
    if not changed:
        return record
    record["state"] = state
    if state == CALL_CONNECTING and not record.get("answered_at"):
        record["answered_at"] = _iso(at)
    if is_terminal(state):
        record["ended_at"] = _iso(at)
        ans = _parse(record.get("answered_at"))
        if ans is not None and state in (CALL_ENDED, CALL_FAILED):
            record["duration_sec"] = max(0, int((at - ans).total_seconds()))
        else:
            record["duration_sec"] = 0
    return record


def call_outcome_label(record, viewer_id, lang="bn"):
    """History row label from `viewer_id`'s perspective (incoming/outgoing +
    outcome).  Mirrors WhatsApp's call log wording."""
    state = (record or {}).get("state", "")
    outgoing = record.get("caller_id") == viewer_id
    kind = normalize_kind(record.get("kind"))
    kind_word = pick(lang, "ভিডিও" if kind == CALL_VIDEO else "ভয়েস",
                     "Video" if kind == CALL_VIDEO else "Voice")
    if state in (CALL_MISSED, CALL_CANCELED):
        base = pick(lang, "মিসড কল", "Missed call") if not outgoing \
            else pick(lang, "বাতিল করা কল", "Canceled call")
    elif state == CALL_DECLINED:
        base = pick(lang, "বাতিল", "Declined")
    elif state == CALL_FAILED:
        base = pick(lang, "ব্যর্থ কল", "Call failed")
    else:
        dir_word = pick(lang, "আউটগোয়িং" if outgoing else "ইনকামিং",
                        "Outgoing" if outgoing else "Incoming")
        base = dir_word
    return f"{kind_word} · {base}"


def format_duration(seconds, lang="bn"):
    """mm:ss (or h:mm:ss) for a completed call's duration."""
    s = max(0, int(seconds or 0))
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{sec:02d}"
    return f"{m}:{sec:02d}"


# ---------------------------------------------------------------------------
# In-call controls (flags the client toggles; server just relays/records)
# ---------------------------------------------------------------------------

def default_controls(kind):
    """Initial control state for a new call.  Video starts with camera on."""
    kind = normalize_kind(kind)
    return {
        "muted": False,
        "speaker_on": kind == CALL_VIDEO,   # video defaults to loudspeaker
        "camera_on": kind == CALL_VIDEO,
        "front_camera": True,
        "low_data": False,
    }


def toggle_control(controls, name):
    """Flip a boolean control; unknown names are ignored.  Low-data mode, when
    enabled on a VIDEO call, the client should drop resolution/framerate."""
    controls = dict(controls or {})
    if name == "switch_camera":
        controls["front_camera"] = not controls.get("front_camera", True)
        return controls
    if name in ("muted", "speaker_on", "camera_on", "low_data", "front_camera"):
        controls[name] = not bool(controls.get(name))
    return controls


# ---------------------------------------------------------------------------
# Transport status ("what works now") — key-gated infra, stated in the UI
# ---------------------------------------------------------------------------
# Voice/video over WebRTC work WHILE THE APP IS OPEN via the relay's local
# signalling.  App-closed ring needs push keys; HD/relayed media needs a TURN
# server.  These flags come from server settings the owner flips when infra is
# provisioned; defaults are the honest "not yet" state.

def transport_status(push_ready=False, turn_ready=False, lang="bn"):
    """Return the capability matrix + a localized banner stating exactly what
    works right now, so the UI never over-promises."""
    return {
        "app_open_calling": True,   # WebRTC signalling via relay — works now
        "app_closed_ring": bool(push_ready),
        "turn_relay": bool(turn_ready),
        "banner": pick(
            lang,
            "এখন অ্যাপ খোলা থাকলে কল কাজ করে। "
            + ("অ্যাপ বন্ধ থাকলেও রিং আসবে। " if push_ready
               else "অ্যাপ বন্ধ থাকলে রিং আসবে পুশ চালু হলে। ")
            + ("উন্নত সংযোগ সার্ভার চালু আছে।" if turn_ready
               else "কঠিন নেটওয়ার্কে কল স্থিতিশীল হবে কল সার্ভার (TURN) চালু হলে।"),
            "Calls work now while the app is open. "
            + ("You'll also ring when the app is closed. " if push_ready
               else "Ringing when the app is closed arrives when push is enabled. ")
            + ("A relay (TURN) server is live for hard networks." if turn_ready
               else "Calls will get more reliable on hard networks when the "
                    "call (TURN) server is enabled."),
        ),
    }


def ice_config(turn_ready=False, stun_urls=None, turn=None):
    """Build a WebRTC ICE server config for the client.  STUN is always on
    (free); TURN is included only when the owner has provisioned it (key-gated).
    `turn` = {"urls":[...], "username":..., "credential":...} from settings."""
    servers = []
    for u in (stun_urls or ["stun:stun.l.google.com:19302"]):
        servers.append({"urls": u})
    if turn_ready and turn and turn.get("urls"):
        servers.append({
            "urls": turn["urls"],
            "username": turn.get("username", ""),
            "credential": turn.get("credential", ""),
        })
    return {"iceServers": servers}


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _iso(dt):
    if dt is None:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.isoformat()


def _parse(v):
    if v is None:
        return None
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
    except ValueError:
        return None
