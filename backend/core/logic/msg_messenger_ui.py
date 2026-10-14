"""
msg_messenger_ui.py — Assisto Messenger FULL-UI backend logic (MESSENGER_UI_FULL
sections 2-4 "BACKEND NEEDED").

Pure Python, deterministic, NO Django, NO DB, NO AI key.  Every function takes
plain dicts/values (resolved by the view from the DB) and returns a decision or
a new record — it never touches the DB — so the server enforcement CANNOT be
skipped by the client and every branch is trivially unit-testable.

This module is the SERVER-SIDE authority for the hub-⋮ and chat-⋮ actions the
full UI exposes that were not already covered by circle_extras / circle_calls /
msg_moderation.  It REUSES those modules rather than re-implementing:

  - circle_extras : disappearing timers, per-chat theme/wallpaper (ChatSettings),
                    broadcast_fanout_plan, backup, linked-device DESIGN stubs.
  - circle_calls  : can_place_call (voice free / VIDEO Premium caller-gated),
                    new_call_record, the call state machine.
  - msg_moderation: build_report / evaluate_report (the report pipeline).

WHAT THIS ADDS (the gaps the full UI needs, each SERVER-ENFORCED):

  1. STARRED messages — star/unstar a message; list across chats with a chat-ref
     + message-id so the client can jump to it.  (StarredMessage model.)
  2. LINKED DEVICES — mint a SINGLE-USE, short-TTL pairing token (QR payload) for
     web/desktop; confirm it exactly once; the confirm reuses circle_extras
     can_link_device (cap + web-after-mobile).  Token never carries a key.
  3. CALLS — an EXPIRING tokenized call link (send-call-link); a SCHEDULED call
     (time + a reminder descriptor fanned out to every invitee); a new GROUP call
     whose VIDEO leg is Premium caller-gated via circle_calls.can_place_call.
  4. REPORT-LAST-5 — the reporter's device supplies a plaintext SNAPSHOT of the
     last <=5 decrypted messages of a 1:1 chat.  The SERVER NEVER DECRYPTS; it
     accepts the reporter-supplied snapshot, sanitises it, caps it at 5, and
     attaches it to the moderation report built by msg_moderation.build_report.
  5. READ-ALL — a plan to mark every chat read for the user (the view applies it).
  6. CUSTOM LISTS — user-defined chat lists that feed the hub filter chips
     (All · Unread · Favourites · Groups · <user lists>).  (ChatList model.)

THE PRIVACY CONTRACT (inherited, re-enforced):
  - A pairing token is a short random handle + TTL — NEVER a key, NEVER plaintext.
  - The report-last-5 snapshot is the ONLY plaintext that ever reaches the server,
    and ONLY because the REPORTER's own device chose to attach it (the user is
    reporting; they consent to surfacing their own view of the chat).  The server
    still never decrypts anything itself and never touches the OTHER party's keys.
  - Starred / lists / call-links carry only OPAQUE references (chat id, message
    id), never message bodies.

Run self-tests (no DB):
    python3 -c "import core.logic.msg_messenger_ui_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

import secrets
from datetime import datetime, timedelta, timezone

from core.logic import circle_calls as CC
from core.logic import circle_extras as CX


def pick(lang, bn, en):
    return en if lang == "en" else bn


def _now(now=None):
    return now or datetime.now(timezone.utc)


def _as_dt(v):
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    if isinstance(v, (int, float)):
        return datetime.fromtimestamp(v, tz=timezone.utc)
    if isinstance(v, str):
        try:
            d = datetime.fromisoformat(v.replace("Z", "+00:00"))
            return d if d.tzinfo else d.replace(tzinfo=timezone.utc)
        except ValueError:
            return None
    return None


def _iso(dt):
    dt = _as_dt(dt)
    return dt.isoformat() if dt else None


# ===========================================================================
# 1. STARRED messages
# ===========================================================================
# A star is a per-USER bookmark on a specific message in a specific chat.  The
# server stores only opaque references (the chat it lives in + the message id)
# so the client can JUMP to it — never the body.  Toggling is idempotent.

STAR_CHAT_KINDS = ("member", "group", "community", "channel")


def normalize_chat_ref(chat_kind, chat_id):
    """Canonicalise a (kind,id) chat reference used by stars / lists / reports.
    Unknown kinds snap to 'member' (a 1:1 circle chat — the default)."""
    kind = (chat_kind or "").strip().lower()
    if kind not in STAR_CHAT_KINDS:
        kind = "member"
    return {"chat_kind": kind, "chat_id": str(chat_id)}


def build_star(user_id, chat_kind, chat_id, message_id, now=None):
    """A StarredMessage row (pure).  message_id is the opaque id the client uses
    to jump back to the message; no body is ever stored."""
    ref = normalize_chat_ref(chat_kind, chat_id)
    return {
        "user_id": user_id,
        "chat_kind": ref["chat_kind"],
        "chat_id": ref["chat_id"],
        "message_id": str(message_id),
        "at": _iso(_now(now)),
    }


def star_jump_target(star):
    """What the 'Starred' list hands the client so a tap JUMPS to the message:
    the chat reference + the message id (no body)."""
    s = star or {}
    return {
        "chat_kind": s.get("chat_kind"),
        "chat_id": s.get("chat_id"),
        "message_id": s.get("message_id"),
    }


# ===========================================================================
# 2. LINKED DEVICES — single-use, short-TTL pairing token (QR)
# ===========================================================================
# To link a web/desktop client the mobile primary mints a pairing token.  The
# token is a short RANDOM handle (NOT a key) with a short TTL and is SINGLE-USE:
# once confirmed it can never be reused.  The QR payload the mobile shows is just
# {token, expires_at, base} — the key-transfer 'welcome' still happens through
# circle_extras.build_link_request (opaque, sealed to the new device key).  The
# web client itself is built later; this is the server side NOW.

LINK_TOKEN_TTL_SEC = 120          # 2-minute pairing window (short-lived)
LINK_TOKEN_BYTES = 24             # url-safe random handle


def mint_link_token(user_id, platform="web", base_url="", now=None):
    """Mint a SINGLE-USE, short-TTL pairing token + the QR payload the primary
    device renders.  The token is a random handle, never a key / never plaintext.
    The integrator stores {token, user_id, platform, expires_at, used=False}."""
    now = _now(now)
    token = secrets.token_urlsafe(LINK_TOKEN_BYTES)
    expires_at = now + timedelta(seconds=LINK_TOKEN_TTL_SEC)
    plat = platform if platform in CX.DEVICE_PLATFORMS else "web"
    record = {
        "token": token,
        "user_id": user_id,
        "platform": plat,
        "created_at": _iso(now),
        "expires_at": _iso(expires_at),
        "used": False,
    }
    qr_payload = {
        "kind": "assisto_device_link",
        "token": token,
        "expires_at": record["expires_at"],
        "base": base_url or "",
    }
    return {"record": record, "qr_payload": qr_payload,
            "ttl_sec": LINK_TOKEN_TTL_SEC}


def link_token_state(record, now=None):
    """Classify a stored token: 'ok' | 'used' | 'expired' | 'unknown'."""
    if not record:
        return "unknown"
    if record.get("used"):
        return "used"
    exp = _as_dt(record.get("expires_at"))
    if exp is None:
        return "unknown"
    if _now(now) > exp:
        return "expired"
    return "ok"


def can_confirm_link(token_record, existing_devices, new_platform, now=None):
    """Return (ok, reason).  The token must be fresh + unused AND the companion
    cap / web-after-mobile order (circle_extras.can_link_device) must allow it."""
    st = link_token_state(token_record, now=now)
    if st != "ok":
        return False, st            # used / expired / unknown
    ok, why = CX.can_link_device(existing_devices, new_platform)
    if not ok:
        return False, why           # device_cap / web_after_mobile
    return True, "ok"


def consume_link_token(token_record):
    """Mark the pairing token USED (single-use) — the integrator saves this so a
    replay of the same token/QR can never link a second device."""
    rec = dict(token_record or {})
    rec["used"] = True
    return rec


def linked_device_view(device, lang="bn"):
    """A safe 'manage linked devices' row: name / platform / last-active / role.
    Never exposes a key.  `device` is a circle_extras.device_record-shaped dict."""
    d = device or {}
    plat = d.get("platform", "android")
    plat_label = {
        "android": ("অ্যান্ড্রয়েড", "Android"),
        "ios": ("আইফোন", "iPhone"),
        "web": ("ওয়েব / ডেস্কটপ", "Web / Desktop"),
    }.get(plat, ("ডিভাইস", "Device"))
    return {
        "device_id": d.get("device_id"),
        "name": d.get("name") or "",
        "platform": plat,
        "platform_label": pick(lang, *plat_label),
        "role": d.get("role", CX.DEVICE_ROLE_LINKED),
        "last_active": d.get("last_active") or d.get("linked_at"),
        "revoked": bool(d.get("revoked")),
    }


# ===========================================================================
# 3a. CALLS — send an EXPIRING tokenized call link
# ===========================================================================
# "Send call link" shares a tokenized join link that EXPIRES.  The token is a
# random handle (not a room secret); kind is voice/video.  A VIDEO link is gated
# on the CREATOR's plan exactly like placing a video call (circle_calls), so a
# free user cannot mint a video link they could never host.

CALL_LINK_TTL_SEC = 24 * 3600     # a call link lives a day by default
CALL_LINK_BYTES = 18


def mint_call_link(creator, kind="voice", base_url="", ttl_sec=None, now=None):
    """Mint an expiring call-join link.  Returns {ok, reason, record?, url?,
    upgrade_required}.  VIDEO is Premium creator-gated (reuses circle_calls'
    entitlement) — a free creator gets reason='video_requires_premium'."""
    kind = CC.normalize_kind(kind)
    now = _now(now)
    if kind == CC.CALL_VIDEO:
        gate = CC.can_place_call(
            {"plan": (creator or {}).get("plan"),
             "video_unlocked": (creator or {}).get("video_unlocked"),
             "accepted": True},
            {"accepted": True}, CC.CALL_VIDEO)
        if not gate["allowed"]:
            return {"ok": False, "reason": gate["reason"],
                    "upgrade_required": True}
    ttl = int(ttl_sec) if ttl_sec else CALL_LINK_TTL_SEC
    token = secrets.token_urlsafe(CALL_LINK_BYTES)
    expires_at = now + timedelta(seconds=max(60, ttl))
    record = {
        "token": token,
        "creator_id": (creator or {}).get("id"),
        "kind": kind,
        "created_at": _iso(now),
        "expires_at": _iso(expires_at),
        "revoked": False,
    }
    url = f"{base_url.rstrip('/')}/call/{token}" if base_url else f"/call/{token}"
    return {"ok": True, "reason": "ok", "record": record, "url": url,
            "upgrade_required": False}


def call_link_joinable(record, now=None):
    """True if a call link may still be used to join (not revoked, not expired)."""
    r = record or {}
    if r.get("revoked"):
        return False
    exp = _as_dt(r.get("expires_at"))
    if exp is None:
        return False
    return _now(now) <= exp


# ===========================================================================
# 3b. CALLS — SCHEDULE a call (time + reminder descriptor to all invitees)
# ===========================================================================
# "Schedule call" picks a future time and notifies every invitee with a reminder
# descriptor.  Reuses circle_extras' schedule-time window validation.  VIDEO is
# Premium gated on the ORGANISER (they host).  The reminder descriptor is what the
# integrator feeds the reminders engine / push — one per invitee.

SCHEDULE_CALL_REMIND_LEAD_SEC = 15 * 60   # remind 15 min before by default


def validate_scheduled_call(organiser, invitee_ids, scheduled_at, kind="voice",
                            now=None):
    """Return (ok, reason).  >=1 invitee, a sane future time (circle_extras
    window), and — for video — the organiser must hold the video entitlement."""
    kind = CC.normalize_kind(kind)
    invitees = [i for i in (invitee_ids or []) if i != (organiser or {}).get("id")]
    if not invitees:
        return False, "no_invitees"
    ok, why = CX.validate_schedule_time(scheduled_at, now=now)
    if not ok:
        return False, why                 # too soon / too far / bad send_at
    if kind == CC.CALL_VIDEO:
        gate = CC.can_place_call(
            {"plan": (organiser or {}).get("plan"),
             "video_unlocked": (organiser or {}).get("video_unlocked"),
             "accepted": True},
            {"accepted": True}, CC.CALL_VIDEO)
        if not gate["allowed"]:
            return False, "video_requires_premium"
    return True, "ok"


def build_scheduled_call(organiser, invitee_ids, scheduled_at, kind="voice",
                         title="", remind_lead_sec=None, now=None):
    """Assemble a ScheduledCall record.  Raises ValueError if invalid.  Returns
    the record PLUS a reminder descriptor per invitee (organiser included) for
    the integrator to enqueue."""
    ok, why = validate_scheduled_call(organiser, invitee_ids, scheduled_at,
                                      kind=kind, now=now)
    if not ok:
        raise ValueError("invalid scheduled call: " + why)
    kind = CC.normalize_kind(kind)
    when = _as_dt(scheduled_at)
    lead = int(remind_lead_sec) if remind_lead_sec is not None \
        else SCHEDULE_CALL_REMIND_LEAD_SEC
    remind_at = when - timedelta(seconds=max(0, lead))
    org_id = (organiser or {}).get("id")
    all_targets = [org_id] + [i for i in invitee_ids if i != org_id]
    record = {
        "kind": "scheduled_call",
        "organiser_id": org_id,
        "invitee_ids": [i for i in invitee_ids if i != org_id],
        "call_kind": kind,
        "title": (title or "").strip()[:120],
        "scheduled_at": _iso(when),
        "remind_at": _iso(remind_at),
        "status": "scheduled",             # scheduled -> started | cancelled
    }
    reminders = [scheduled_call_reminder(record, uid) for uid in all_targets]
    return {"record": record, "reminders": reminders}


def scheduled_call_reminder(record, invitee_id, lang="bn"):
    """One reminder descriptor for one invitee (fed to the reminders engine)."""
    kind = CC.normalize_kind(record.get("call_kind"))
    kind_word = pick(lang, "ভিডিও কল" if kind == CC.CALL_VIDEO else "ভয়েস কল",
                     "Video call" if kind == CC.CALL_VIDEO else "Voice call")
    title = record.get("title") or kind_word
    return {
        "invitee_id": invitee_id,
        "remind_at": record.get("remind_at"),
        "scheduled_at": record.get("scheduled_at"),
        "call_kind": kind,
        "title": title,
        "body": pick(lang,
                     f"নির্ধারিত {kind_word}: {title}",
                     f"Scheduled {kind_word.lower()}: {title}"),
    }


# ===========================================================================
# 3c. CALLS — NEW GROUP CALL (reuse circle_calls; video Premium caller-gated)
# ===========================================================================
# Starting a group call: the organiser dials N accepted members.  VOICE is free;
# VIDEO requires the ORGANISER's plan (reuses can_place_call — receivers may be
# free).  Each invitee must be an ACCEPTED, non-blocked circle member.

GROUP_CALL_MAX = 32               # a sane cap on a group call size


def plan_group_call(organiser, invitees, kind="voice"):
    """Plan a group call.  `organiser` = {id, plan, video_unlocked}; `invitees` =
    list of {id, accepted, blocked}.  Returns
        {allowed, kind, reason, upgrade_required, dialled, skipped}
    Reuses circle_calls.can_place_call for the VIDEO entitlement (organiser-gated)
    and per-invitee relationship gating.  A single not-connected invitee is
    skipped (not fatal); an empty dial list or a video-entitlement failure is."""
    kind = CC.normalize_kind(kind)
    org = organiser or {}
    caller = {"plan": org.get("plan"), "video_unlocked": org.get("video_unlocked"),
              "accepted": True}

    # VIDEO entitlement is the organiser's — check it once, up front.
    if kind == CC.CALL_VIDEO:
        ent = CC.can_place_call(caller, {"accepted": True}, CC.CALL_VIDEO)
        if not ent["allowed"]:
            return {"allowed": False, "kind": kind,
                    "reason": "video_requires_premium",
                    "upgrade_required": True, "dialled": [], "skipped": []}

    dialled, skipped = [], []
    for inv in (invitees or [])[:GROUP_CALL_MAX]:
        if inv.get("id") == org.get("id"):
            continue
        g = CC.can_place_call(caller,
                              {"accepted": inv.get("accepted", True),
                               "blocked": inv.get("blocked")}, kind)
        if g["allowed"]:
            dialled.append(inv.get("id"))
        else:
            skipped.append({"id": inv.get("id"), "reason": g["reason"]})

    if not dialled:
        return {"allowed": False, "kind": kind, "reason": "no_connected_invitees",
                "upgrade_required": False, "dialled": [], "skipped": skipped}
    return {"allowed": True, "kind": kind, "reason": "ok",
            "upgrade_required": False, "dialled": dialled, "skipped": skipped}


# ===========================================================================
# 4. REPORT-LAST-5 — reporter supplies a plaintext snapshot; server never decrypts
# ===========================================================================
# When a user reports a 1:1 chat, their DEVICE sends the last <=5 DECRYPTED
# messages as a plaintext snapshot (their own view, which they consent to share by
# reporting).  The SERVER NEVER DECRYPTS — it accepts the reporter-supplied
# snapshot, sanitises it (caps to 5, keeps only safe display fields, truncates),
# and attaches it to the moderation report.  The OTHER party's keys are never
# touched; no ciphertext is decrypted server-side.

REPORT_SNAPSHOT_MAX = 5
_SNAPSHOT_TEXT_CAP = 4000         # per-message text cap (defensive)


def sanitize_report_snapshot(messages):
    """Take the reporter's plaintext snapshot and return AT MOST the last 5
    messages, keeping ONLY safe display fields.  Pure; the server performs NO
    decryption — it only trims what the reporter's device already decrypted and
    chose to attach.  Each item -> {message_id, from_me, sender_name, at,
    content_type, text}."""
    rows = list(messages or [])
    # Keep the LAST 5 (most recent) — the UI shows the last 5 for context.
    rows = rows[-REPORT_SNAPSHOT_MAX:]
    out = []
    for m in rows:
        m = m or {}
        ct = (m.get("content_type") or "text")
        text = m.get("text")
        if text is not None:
            text = str(text)[:_SNAPSHOT_TEXT_CAP]
        out.append({
            "message_id": (str(m.get("message_id")) if m.get("message_id")
                           is not None else None),
            "from_me": bool(m.get("from_me")),
            "sender_name": str(m.get("sender_name") or "")[:120],
            "at": _iso(m.get("at")),
            "content_type": ct,
            "text": text,
        })
    return out


def build_chat_report(report_id, reporter_id, target_user_id, categories,
                      snapshot_messages, note="", now=None):
    """Build a moderation report for a 1:1 chat with the reporter's last-5
    plaintext snapshot attached.  Delegates the report decision shape to
    msg_moderation.build_report (target_kind='person'); the snapshot is extra
    CONTEXT the admin reviews — the server never decrypted it.  Returns
    {report, snapshot}; the view persists both and runs evaluate_report."""
    # Lazy import so this module keeps its "reuse" contract explicit and avoids a
    # hard import cycle at module load.
    from core.logic import msg_moderation as MM
    rpt = MM.build_report(
        report_id=report_id, reporter_id=reporter_id,
        target_kind=MM.T_PERSON, target_id=target_user_id,
        categories=categories, note=note, now=now)
    snapshot = sanitize_report_snapshot(snapshot_messages)
    rpt["snapshot"] = snapshot                 # reporter-supplied context
    rpt["snapshot_source"] = "reporter_device"  # server never decrypted
    return {"report": rpt, "snapshot": snapshot}


# ===========================================================================
# 5. READ-ALL — mark every chat read for the user
# ===========================================================================

def read_all_plan(chat_refs):
    """Return the set of chat refs to mark read + a count.  The view applies the
    read-receipt write per chat; this just normalises the plan.  Idempotent."""
    refs = [normalize_chat_ref(c.get("chat_kind"), c.get("chat_id"))
            for c in (chat_refs or []) if c.get("chat_id") is not None]
    return {"marked": refs, "count": len(refs)}


# ===========================================================================
# 6. CUSTOM LISTS — user-defined chat lists feeding the hub filter chips
# ===========================================================================
# A user may define named lists ("Family", "Work"); each is a set of chat member
# refs.  The hub shows them as extra filter chips after All/Unread/Favourites/
# Groups.  Reserved chip ids may NOT be used as a user list name/id.

RESERVED_CHIP_IDS = frozenset({"all", "unread", "favourites", "favorites", "groups"})
LIST_NAME_MAX = 40
LIST_MAX_MEMBERS = 500


def validate_list_name(name):
    """Return (ok, reason).  Non-empty, within length, not a reserved chip id."""
    n = (name or "").strip()
    if not n:
        return False, "empty_name"
    if len(n) > LIST_NAME_MAX:
        return False, "name_too_long"
    if n.strip().lower() in RESERVED_CHIP_IDS:
        return False, "reserved_name"
    return True, "ok"


def build_chat_list(user_id, name, member_refs=None, now=None):
    """A ChatList row (pure).  member_refs are CircleMember ids (deduped)."""
    ok, why = validate_list_name(name)
    if not ok:
        raise ValueError("invalid list name: " + why)
    members = _dedupe_ids(member_refs)[:LIST_MAX_MEMBERS]
    return {
        "user_id": user_id,
        "name": (name or "").strip()[:LIST_NAME_MAX],
        "member_refs": members,
        "created_at": _iso(_now(now)),
    }


def list_add_members(current_refs, add_refs):
    """Add member refs to a list (deduped, capped).  Returns the new ref list."""
    merged = _dedupe_ids(list(current_refs or []) + list(add_refs or []))
    return merged[:LIST_MAX_MEMBERS]


def list_remove_members(current_refs, remove_refs):
    """Remove member refs from a list.  Returns the new ref list."""
    rm = set(_dedupe_ids(remove_refs))
    return [r for r in _dedupe_ids(current_refs) if r not in rm]


def hub_filter_chips(user_lists, lang="bn"):
    """The hub filter-chip spec: the fixed chips + the user's own lists appended.
    Order matches the UI: All · Unread · Favourites · Groups · <user lists>."""
    fixed = [
        {"id": "all", "label": pick(lang, "সব", "All"), "builtin": True},
        {"id": "unread", "label": pick(lang, "অপঠিত", "Unread"), "builtin": True},
        {"id": "favourites", "label": pick(lang, "প্রিয়", "Favourites"),
         "builtin": True},
        {"id": "groups", "label": pick(lang, "গ্রুপ", "Groups"), "builtin": True},
    ]
    for lst in (user_lists or []):
        fixed.append({
            "id": f"list:{lst.get('id')}",
            "label": (lst.get("name") or "")[:LIST_NAME_MAX],
            "builtin": False,
            "member_count": len(lst.get("member_refs") or []),
        })
    return fixed


# ===========================================================================
# 7. BROADCAST — reuse circle_extras.broadcast_fanout_plan with the circle gate
# ===========================================================================
# A broadcast list sends ONE composed message to MANY contacts as SEPARATE 1:1
# messages.  The owner-rule gate: a recipient only receives it if they have the
# SENDER in THEIR accepted circle.  We pass the set of such recipients as
# `accepted_ids` to broadcast_fanout_plan, which rejects any non-accepted member.

def broadcast_send_plan(sender_id, recipient_ids, mutual_accepted_ids,
                        broadcast_id, base_client_msg_id):
    """Return (ok, reason, plan).  `mutual_accepted_ids` MUST be the recipients
    who have the SENDER in THEIR accepted circle (the view resolves this from the
    OTHER side's CircleMember rows — not the sender's).  Delegates to
    circle_extras.broadcast_fanout_plan which enforces the accepted-only gate."""
    try:
        plan = CX.broadcast_fanout_plan(
            sender_id, recipient_ids, mutual_accepted_ids,
            broadcast_id, base_client_msg_id)
    except ValueError as e:
        reason = str(e).split(": ", 1)[-1]
        return False, reason, []            # 'not_connected' / 'no recipients' / ...
    return True, "ok", plan


# ===========================================================================
# helpers
# ===========================================================================

def _dedupe_ids(ids):
    seen, out = set(), []
    for i in (ids or []):
        if i is None:
            continue
        if i in seen:
            continue
        seen.add(i)
        out.append(i)
    return out
