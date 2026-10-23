"""a1-circle — owner bug report on build 202 (My Circle chat list + calls).

1. ONE chat-list row per peer USER, always: dedupe_chat_rows() collapses
   1:1 rows that resolve to the same peer account (two edges of mine to one
   person — e.g. one by phone, one linked by account), keeping the row with
   the newest message.
   Two DIFFERENT accounts that share a display name are NOT merged (never
   without the owner); mark_same_names() gives those rows a subtle second
   identifier (the custom label / relation on the device, or the masked tail
   of the number on MY edge: "…888").
2. `peer_has_app`: the peer has a registered device or a published key — a
   peer who never opened Assisto gets an honest "hasn't opened Assisto yet"
   hint instead of a bare "No messages yet".
3. In-chat call events: call_events() = the 1:1 call records between the
   viewer and one peer, glare / double-tap duplicates collapsed.

Nothing here raises into a view (every entry point is guarded by the caller
or returns the input unchanged).
"""
from __future__ import annotations

import re
from datetime import timedelta

# Two call records between the same pair that start this close together are
# ONE user-visible call (glare: both tapped call; or a double placement).
GLARE_WINDOW_S = 15


# ---------------------------------------------------------------------------
# chat list
# ---------------------------------------------------------------------------
def _peer_id(row):
    m = row.get("member") if isinstance(row, dict) else None
    if not isinstance(m, dict):
        return None
    pid = m.get("peer_user_id")
    return pid if pid not in (None, "") else None


def _is_group(row):
    return bool(row.get("is_group")) or row.get("kind") == "group"


def dedupe_chat_rows(rows):
    """One 1:1 row per peer user id. The survivor is the row with the newest
    activity (`at`); ties keep the accepted edge, then the first seen. Its
    unread count is the max of the duplicates (both edges read the same
    conversation, so a sum would double-count). Rows with no resolvable peer
    and group rows pass through untouched. Order is preserved."""
    best = {}
    for i, r in enumerate(rows):
        if _is_group(r):
            continue
        pid = _peer_id(r)
        if pid is None:
            continue
        cur = best.get(pid)
        if cur is None:
            best[pid] = i
            continue
        a, b = rows[cur], r
        ka = (a.get("at") or "", a.get("request") is None)
        kb = (b.get("at") or "", b.get("request") is None)
        if kb > ka:
            best[pid] = i
    keep_idx = set(best.values())
    unread = {}
    for r in rows:
        pid = None if _is_group(r) else _peer_id(r)
        if pid is not None:
            try:
                n = int(r.get("unread") or 0)
            except (TypeError, ValueError):
                n = 0
            unread[pid] = max(unread.get(pid, 0), n)
    out = []
    for i, r in enumerate(rows):
        pid = None if _is_group(r) else _peer_id(r)
        if pid is not None and i not in keep_idx:
            continue
        if pid is not None:
            r["unread"] = unread.get(pid, r.get("unread") or 0)
        out.append(r)
    return out


def _norm_name(s):
    return re.sub(r"\s+", " ", str(s or "")).strip().casefold()


def phone_tail(phone, n=3):
    digits = re.sub(r"\D", "", str(phone or ""))
    return digits[-n:] if len(digits) >= n + 4 else ""


def mark_same_names(rows, edges_by_id):
    """1:1 rows that share a display name with ANOTHER row get
    member.same_name = True and member.phone_tail (the last 3 digits of the
    number on MY edge — a number I already have; '' when the edge has none).
    Other rows get same_name False and no tail (a number is never sent when
    it isn't needed)."""
    counts = {}
    for r in rows:
        if _is_group(r):
            continue
        k = _norm_name((r.get("member") or {}).get("name"))
        if k:
            counts[k] = counts.get(k, 0) + 1
    for r in rows:
        if _is_group(r):
            continue
        m = r.get("member")
        if not isinstance(m, dict):
            continue
        k = _norm_name(m.get("name"))
        dup = bool(k) and counts.get(k, 0) > 1
        m["same_name"] = dup
        if dup:
            e = edges_by_id.get(str(r.get("id")))
            m["phone_tail"] = phone_tail(getattr(e, "phone", "")) if e else ""
    return rows


def users_with_app(user_ids):
    """The subset of `user_ids` that ever opened the app on a phone (a push
    device row or a published E2E key)."""
    from .models import Device, UserPublicKey
    ids = [i for i in set(user_ids) if i]
    if not ids:
        return set()
    have = set(Device.objects.filter(user_id__in=ids)
               .values_list("user_id", flat=True))
    have |= set(UserPublicKey.objects.filter(user_id__in=ids)
                .exclude(public_key="").values_list("user_id", flat=True))
    return have


def mark_has_app(rows):
    pids = [_peer_id(r) for r in rows if not _is_group(r)]
    have = users_with_app([p for p in pids if p is not None])
    for r in rows:
        if _is_group(r):
            continue
        pid = _peer_id(r)
        # unknown peer (phone-only edge, no account) = not on Assisto yet
        r["peer_has_app"] = pid is not None and pid in have
    return rows


def add_key_history(rows, edges_by_id):
    """`last.peer_key_history`: the peer's EARLIER public keys so the phone
    can decrypt a last message sent before the peer's key changed."""
    from . import e2_keys
    for r in rows:
        last = r.get("last")
        if _is_group(r) or not isinstance(last, dict):
            continue
        e = edges_by_id.get(str(r.get("id")))
        last["peer_key_history"] = e2_keys.edge_key_history(e) if e else []
    return rows


def polish_chat_rows(rows, edges):
    """Everything above, in order. Never raises: a failure returns `rows`."""
    edges_by_id = {str(e.id): e for e in edges}
    try:
        rows = dedupe_chat_rows(rows)
    except Exception:
        pass
    for fn in (lambda x: mark_same_names(x, edges_by_id), mark_has_app,
               lambda x: add_key_history(x, edges_by_id)):
        try:
            rows = fn(rows)
        except Exception:
            pass
    return rows


# ---------------------------------------------------------------------------
# in-chat call events
# ---------------------------------------------------------------------------
def _answered(rec, reason):
    """A call that really connected (the history's 'answered' rule)."""
    return (rec.duration_sec or 0) > 0 or reason in ("hangup", "lost") or \
        (rec.state == "ended" and reason in ("", "hangup", "lost"))


def dedupe_calls(items):
    """`items` = [(record, end_reason)] in ANY order. Records between the
    same pair starting within GLARE_WINDOW_S of each other are one call; the
    survivor is the answered one (longest), else the earliest placed.
    Returns the survivors oldest-first."""
    items = sorted(items, key=lambda t: (t[0].started_at, t[0].id))
    groups = []
    for rec, reason in items:
        g = groups[-1] if groups else None
        if g is not None and (rec.started_at - g[-1][0].started_at) <= \
                timedelta(seconds=GLARE_WINDOW_S) and \
                {rec.caller_id, rec.callee_id} == \
                {g[-1][0].caller_id, g[-1][0].callee_id}:
            g.append((rec, reason))
            continue
        groups.append([(rec, reason)])
    out = []
    for g in groups:
        answered = [t for t in g if _answered(*t)]
        if answered:
            out.append(max(answered, key=lambda t: (t[0].duration_sec or 0,
                                                    -t[0].id)))
        else:
            out.append(g[0])
    return out


def call_category(rec, reason, viewer_id):
    """'answered' | 'missed' (incoming, I never answered) | 'declined'
    (incoming, I declined) | 'no_answer' (my outgoing call, not answered) |
    'busy' | 'failed'."""
    outgoing = rec.caller_id == viewer_id
    if _answered(rec, reason):
        return "answered"
    if reason == "failed" or rec.state == "failed":
        return "failed"
    if reason == "declined" or rec.state == "declined":
        return "declined"
    if outgoing:
        return "busy" if reason == "busy" else "no_answer"
    return "missed"   # no_answer / busy / offline / canceled -> missed


def call_events(viewer, edge, limit=200):
    """The call records between `viewer` and the peer of `edge` as chat
    timeline events, oldest first."""
    from django.db.models import Q
    from .models import CallRecord, CallSession
    from .push import member_peer_user
    peer = member_peer_user(edge)
    if peer is None or peer.pk == viewer.pk:
        return []
    recs = list(CallRecord.objects.filter(
        Q(caller=viewer, callee=peer) | Q(caller=peer, callee=viewer))
        .order_by("-started_at", "-id")[:limit])
    reasons = dict(CallSession.objects.filter(call__in=recs)
                   .values_list("call_id", "end_reason"))
    from .logic import call_signal as CS
    # a call still ringing / in progress is not history yet
    items = [(r, reasons.get(r.id) or "") for r in recs
             if r.state not in CS.LIVE_STATES]
    out = []
    for rec, reason in dedupe_calls(items):
        out.append({
            "id": rec.id, "kind": rec.kind,
            "outgoing": rec.caller_id == viewer.id,
            "category": call_category(rec, reason, viewer.id),
            "duration_sec": int(rec.duration_sec or 0),
            "started_at": rec.started_at.isoformat(),
            "ended_at": rec.ended_at.isoformat() if rec.ended_at else None,
        })
    return out
