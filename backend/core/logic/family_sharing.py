"""
family_sharing.py — Assisto FAMILY "good-bits -> ADVANCED" server-enforced logic
(SPEC v2.1 §21) for three features:

  #67 SELECTIVE SHARING — per-family-member, per-item consent: which of MY info
      each family member may see (location / medicine / money-summary /
      documents / safe-journey).  Pure grant/revoke state + a SERVER-ENFORCED
      access decision + an audit-log entry builder.  Benchmarked against the
      circle_privacy.py visibility contract (VIS_* audiences) — this is the
      finer-grained, per-item cousin of can_see_field().
  #73 FAMILY CARD — a deterministic, shareable family-card payload (members +
      relations + emergency info), bilingual, built from data the client already
      holds.  No AI, no network, no secrets.
  #75 PROBASHI FAMILY — expatriate two-timezone math (my-time <-> family-in-BD
      time), honest scheduled-call slot proposals (reuse meetings/calls — this
      only computes the local<->BD time pair, it does not place a call), and
      remittance *reminder context* (a nudge to SEND money — NEVER a wallet,
      NEVER holds or moves money).

Pure Python, deterministic, no DB, no AI key, no network.  Every function takes
plain dicts/values (resolved by the view from the DB) and returns a decision —
so the client CANNOT skip enforcement and the functions are trivially
unit-testable.  Mirrors the shape/conventions of core.logic.circle_privacy.

Run self-tests (no DB):
    python3 -c "import core.logic.family_sharing_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ===========================================================================
# #67 SELECTIVE SHARING — per-member, per-item consent
# ===========================================================================
# The owner shares specific *items* of their own info with specific family
# members.  Default is SHARE NOTHING (opt-in, privacy-first) — unlike a circle
# where contacts are already consented, here the owner must deliberately grant
# each item to each person.  Everything is revocable and every change is logged.

ITEM_LOCATION = "location"
ITEM_MEDICINE = "medicine"
ITEM_MONEY_SUMMARY = "money_summary"
ITEM_DOCUMENTS = "documents"
ITEM_SAFE_JOURNEY = "safe_journey"
SHAREABLE_ITEMS = (
    ITEM_LOCATION,
    ITEM_MEDICINE,
    ITEM_MONEY_SUMMARY,
    ITEM_DOCUMENTS,
    ITEM_SAFE_JOURNEY,
)


def is_shareable_item(item):
    return item in SHAREABLE_ITEMS


def default_sharing_grants():
    """Safe default: NOTHING is shared with anyone.  Grants is a mapping of
    {member_id: set(items)}.  An empty/missing map means share nothing."""
    return {}


def normalize_grants(grants):
    """Coerce an arbitrary dict into {int member_id: set(valid items)}.
    Unknown items are dropped (defence in depth against a stale/hostile client)."""
    out = {}
    for mid, items in (grants or {}).items():
        try:
            key = int(mid)
        except (TypeError, ValueError):
            continue
        valid = {i for i in (items or []) if i in SHAREABLE_ITEMS}
        if valid:
            out[key] = valid
    return out


def set_grant(grants, member_id, item, on=True):
    """Return updated grants with `item` granted/revoked for `member_id`.
    Never mutates the input.  Raises nothing — an invalid item is a no-op so a
    buggy client can't partially corrupt the map."""
    out = {k: set(v) for k, v in normalize_grants(grants).items()}
    if not is_shareable_item(item):
        return out
    try:
        mid = int(member_id)
    except (TypeError, ValueError):
        return out
    cur = out.setdefault(mid, set())
    if on:
        cur.add(item)
    else:
        cur.discard(item)
        if not cur:
            out.pop(mid, None)
    return out


def revoke_member(grants, member_id):
    """Revoke ALL items from one member in a single step (the 'revoke flow')."""
    out = {k: set(v) for k, v in normalize_grants(grants).items()}
    try:
        out.pop(int(member_id), None)
    except (TypeError, ValueError):
        pass
    return out


def revoke_all(grants):
    """Revoke everything from everyone (panic/reset)."""
    return {}


def can_share_item(owner_grants, member_id, item):
    """THE server-enforced access decision: may `member_id` see the owner's
    `item`?  The view calls this before serializing ANY shared field, so a
    client that asks for an ungranted item gets nothing.  Default-deny."""
    if not is_shareable_item(item):
        return False
    try:
        mid = int(member_id)
    except (TypeError, ValueError):
        return False
    return item in normalize_grants(owner_grants).get(mid, set())


def shared_items_for(owner_grants, member_id):
    """The items a given member is allowed to see (sorted, stable order)."""
    try:
        mid = int(member_id)
    except (TypeError, ValueError):
        return []
    granted = normalize_grants(owner_grants).get(mid, set())
    return [i for i in SHAREABLE_ITEMS if i in granted]


def consent_summary(owner_grants, members):
    """Build the consent-screen model: for every family member, which items are
    on/off.  `members` = [{id, name, relation}].  The UI renders this as a grid
    of per-member, per-item toggles; the owner reviews exactly what each person
    can see before confirming."""
    g = normalize_grants(owner_grants)
    rows = []
    for m in members or []:
        try:
            mid = int(m.get("id"))
        except (TypeError, ValueError):
            continue
        granted = g.get(mid, set())
        rows.append({
            "member_id": mid,
            "name": m.get("name") or "",
            "relation": m.get("relation") or "",
            "items": {i: (i in granted) for i in SHAREABLE_ITEMS},
            "shared_count": len(granted),
        })
    total_shared = sum(len(v) for v in g.values())
    return {"rows": rows, "total_shared": total_shared,
            "items": list(SHAREABLE_ITEMS)}


# ---- audit log -----------------------------------------------------------
# Every grant/revoke is logged so the owner can see WHAT they shared, WITH whom,
# and WHEN — and undo it.  The builder is pure; the view appends the returned
# entry to the persisted log.

AUDIT_GRANT = "grant"
AUDIT_REVOKE = "revoke"
AUDIT_REVOKE_MEMBER = "revoke_member"
AUDIT_REVOKE_ALL = "revoke_all"
AUDIT_ACTIONS = (AUDIT_GRANT, AUDIT_REVOKE, AUDIT_REVOKE_MEMBER, AUDIT_REVOKE_ALL)


def build_audit_entry(action, member_id=None, item=None, member_name="",
                      actor_id=None, now=None):
    """Return one audit-log entry for a sharing change.  `now` defaults to UTC
    (the view passes the real time).  `item` is only meaningful for grant/revoke
    of a single item."""
    action = action if action in AUDIT_ACTIONS else AUDIT_GRANT
    now = now or datetime.now(timezone.utc)
    entry = {
        "action": action,
        "at": now.replace(microsecond=0).isoformat(),
        "actor_id": actor_id,
        "member_id": None,
        "member_name": member_name or "",
        "item": None,
    }
    if member_id is not None:
        try:
            entry["member_id"] = int(member_id)
        except (TypeError, ValueError):
            entry["member_id"] = None
    if action in (AUDIT_GRANT, AUDIT_REVOKE) and is_shareable_item(item):
        entry["item"] = item
    return entry


def item_label(item, lang="bn"):
    labels = {
        ITEM_LOCATION: ("আমার অবস্থান", "My location"),
        ITEM_MEDICINE: ("ওঙুধ ও সিডিউল", "Medicine & schedule"),
        ITEM_MONEY_SUMMARY: ("টাকার সারাংশ", "Money summary"),
        ITEM_DOCUMENTS: ("ডকুমেন্ট", "Documents"),
        ITEM_SAFE_JOURNEY: ("নিরাপদ যাত্রা", "Safe journey"),
    }
    bn, en = labels.get(item, ("", ""))
    return pick(lang, bn, en)


# ===========================================================================
# #73 FAMILY CARD — deterministic shareable-card payload
# ===========================================================================

def build_family_card(owner, members, emergency=None, lang="bn"):
    """Build the family-card model the client renders (then captures to PNG via
    the existing RepaintBoundary flow).  Pure projection of data the client
    already has — no secrets added, no network.

    `owner`     = {name, phone}
    `members`   = [{name, relation, phone}]
    `emergency` = {blood_group, address, contact_name, contact_phone} (optional)
    """
    owner = owner or {}
    rows = []
    for m in members or []:
        rows.append({
            "name": (m.get("name") or "").strip(),
            "relation": (m.get("relation") or "").strip(),
            "phone": (m.get("phone") or "").strip(),
        })
    emer = emergency or {}
    return {
        "title": pick(lang, "আমার পরিবার", "My family"),
        "owner_name": (owner.get("name") or "").strip(),
        "owner_phone": (owner.get("phone") or "").strip(),
        "members": rows,
        "member_count": len(rows),
        "emergency": {
            "blood_group": (emer.get("blood_group") or "").strip(),
            "address": (emer.get("address") or "").strip(),
            "contact_name": (emer.get("contact_name") or "").strip(),
            "contact_phone": (emer.get("contact_phone") or "").strip(),
        },
        "lang": "en" if lang == "en" else "bn",
    }


def family_card_caption(card, lang="bn"):
    """Short text caption shipped alongside the shared image / print export."""
    name = (card or {}).get("owner_name") or pick(lang, "আমার", "my")
    n = (card or {}).get("member_count", 0)
    if lang == "en":
        return f"{name} — family card ({n} members)"
    return f"{name} — পরিবার কার্ড"


# ===========================================================================
# #75 PROBASHI FAMILY — two-timezone view + remittance *context* (never a wallet)
# ===========================================================================
# An expatriate (probashi) sees their own local time alongside family time in
# Bangladesh (Asia/Dhaka, fixed UTC+06:00, no DST).  We compute the pair so the
# UI can show both clocks and propose call slots that are polite at BOTH ends.

BD_UTC_OFFSET_MIN = 6 * 60  # Asia/Dhaka is UTC+06:00 year-round (no DST).


def _tz(offset_minutes):
    return timezone(timedelta(minutes=int(offset_minutes)))


def two_timezone_now(my_offset_min, now_utc=None):
    """Return {my, bd} datetimes for 'now' in the probashi's local tz and in BD.
    `my_offset_min` = the probashi's UTC offset in minutes (the view resolves it
    from the device). Honest: this is wall-clock conversion only."""
    now_utc = now_utc or datetime.now(timezone.utc)
    my = now_utc.astimezone(_tz(my_offset_min))
    bd = now_utc.astimezone(_tz(BD_UTC_OFFSET_MIN))
    return {
        "my": my,
        "bd": bd,
        "my_offset_min": int(my_offset_min),
        "bd_offset_min": BD_UTC_OFFSET_MIN,
        "diff_min": int(my_offset_min) - BD_UTC_OFFSET_MIN,
    }


def bd_time_at_my_local(my_offset_min, hh, mm=0, now_utc=None):
    """What BD wall-clock time corresponds to `hh:mm` on the probashi's clock
    today?  Used to show 'if you call at 9pm your time, it's X in Dhaka'."""
    now_utc = now_utc or datetime.now(timezone.utc)
    mine = now_utc.astimezone(_tz(my_offset_min)).replace(
        hour=int(hh) % 24, minute=int(mm) % 60, second=0, microsecond=0)
    bd = mine.astimezone(_tz(BD_UTC_OFFSET_MIN))
    return {"my": mine, "bd": bd}


# Polite call windows (local wall-clock, [start, end)) at EACH end.  A proposed
# slot must be inside BOTH windows to be "comfortable" for everyone.
_POLITE_START_H = 8
_POLITE_END_H = 22


def _is_polite(dt):
    return _POLITE_START_H <= dt.hour < _POLITE_END_H


def propose_call_slots(my_offset_min, now_utc=None, step_min=30, horizon_h=24):
    """Propose call slots over the next `horizon_h` hours where it is a polite
    hour at BOTH ends (probashi + BD).  Returns a list of
    {my, bd, comfortable} — honest about which are comfortable vs merely awake.
    This ONLY computes times; placing the call reuses the existing meetings/calls
    feature (the view wires the chosen slot into a scheduled meeting)."""
    now_utc = now_utc or datetime.now(timezone.utc)
    my_tz = _tz(my_offset_min)
    bd_tz = _tz(BD_UTC_OFFSET_MIN)
    # start from the next step boundary
    base = now_utc.replace(second=0, microsecond=0)
    minute = (base.minute // step_min + 1) * step_min
    base = base.replace(minute=0) + timedelta(minutes=minute)
    out = []
    steps = int(horizon_h * 60 / step_min)
    for i in range(steps):
        t = base + timedelta(minutes=i * step_min)
        my = t.astimezone(my_tz)
        bd = t.astimezone(bd_tz)
        comfortable = _is_polite(my) and _is_polite(bd)
        if comfortable:
            out.append({"my": my, "bd": bd, "comfortable": True})
    return out


def remittance_reminder_context(amount_hint=None, cadence="monthly",
                                last_sent=None, now=None, lang="bn"):
    """Build a remittance REMINDER (a nudge to SEND money) — explicitly NOT a
    wallet.  Assisto never holds, moves, or transfers money; this only reminds.
    Returns a plain context object with a due date and an honest disclaimer.

    `cadence` in {monthly, weekly}.  `last_sent` = ISO date|None.  `amount_hint`
    is a free-form user note (e.g. "20000 BDT"), echoed back, never validated as
    currency and never treated as a balance."""
    now = now or datetime.now(timezone.utc)
    days = 7 if cadence == "weekly" else 30
    due = None
    if last_sent:
        try:
            base = datetime.fromisoformat(str(last_sent))
            if base.tzinfo is None:
                base = base.replace(tzinfo=timezone.utc)
            due = (base + timedelta(days=days)).date().isoformat()
        except (ValueError, TypeError):
            due = None
    disclaimer = pick(
        lang,
        "Assisto কখনও টাকা রাখে না বা "
        "পাঠায় না — এটি শুধু স্মরণ "
        "করিয়ে দেয়।",
        "Assisto never holds or sends money — this is only a reminder.")
    return {
        "kind": "remittance_reminder",
        "is_wallet": False,          # hard, explicit: never a wallet
        "holds_money": False,
        "cadence": "weekly" if cadence == "weekly" else "monthly",
        "amount_hint": (amount_hint or "").strip() or None,
        "last_sent": str(last_sent) if last_sent else None,
        "next_due": due,
        "disclaimer": disclaimer,
    }


# ===========================================================================
# ENDPOINT NEEDS (integration note — SERVER-ENFORCED intent for #67)
# ===========================================================================
# The client cannot enforce consent on its own; these endpoints must exist and
# call the functions above before serializing any shared field:
#
#   GET  /family/sharing/consent
#        -> consent_summary(owner_grants, members)   (the consent screen)
#   POST /family/sharing/grant    {member_id, item, on}
#        -> set_grant(...) + append build_audit_entry(AUDIT_GRANT/REVOKE, ...)
#   POST /family/sharing/revoke-member  {member_id}
#        -> revoke_member(...) + build_audit_entry(AUDIT_REVOKE_MEMBER, ...)
#   POST /family/sharing/revoke-all
#        -> revoke_all(...) + build_audit_entry(AUDIT_REVOKE_ALL, ...)
#   GET  /family/sharing/audit
#        -> the persisted list of build_audit_entry(...) rows
#   GET  /family/shared/<member_id>/<item>
#        -> MUST short-circuit with can_share_item(owner_grants, member_id, item)
#           BEFORE loading/returning the field; default-deny on false.
#
# These names are a specification for the integrator (D-series wiring); no URL
# or view is added by this change.
