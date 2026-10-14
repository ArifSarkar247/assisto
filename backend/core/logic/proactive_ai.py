"""
proactive_ai.py — the deterministic, key-free engine behind Assisto's
PROACTIVE AI suggestions digest (issue #6, SPEC v2.1 §21, ADVANCED).

WHAT THIS IS
    A proactive-suggestions digest. DETERMINISTIC rules run over signals the
    app ALREADY collects (bills due, expenses not logged this week, a birthday
    coming, a subscription renewing, a medicine refill, a safe-journey check-in)
    and turn them into helpful, grouped nudges — each one dismissable and each
    carrying an honest "why am I seeing this" reason.

    This is the PROACTIVITY layer that sits ON TOP of `watch_feed.py`: watch_feed
    classifies raw signals into needs_you / today / upcoming groups; this module
    reshapes those into user-facing SUGGESTIONS with an urgency bucket, a stable
    id, a localisable reason key, and dismissal handling. It never INVENTS data —
    every nudge traces back to a real signal the caller passed in. If there are
    no signals there are no nudges (honest empty state).

    This module is PURE, exactly like `watch_feed.py`: no Django, no DB, no
    network, no clock (days_until is passed in, computed by the caller), **no
    AI**. Same inputs → same output, so the on-device Dart mirror matches and
    tests can pin it.

AI SEAM (documented, not built)
    The nudges here are rule-derived and honest. An AI-PERSONALISED proactivity
    layer — re-ranking/phrasing nudges from the user's own patterns — is the
    documented `core.ai.generate` seam the integrator can wire later. Every
    result carries `ai_required=False` so the current rule path stays honest;
    the real-AI path would only re-order/re-phrase, never fabricate a nudge.

DISMISSALS
    A dismissed nudge stays hidden until its signal meaningfully changes. We key
    dismissals by a STABLE suggestion id (kind + source ref), and re-surface a
    nudge only when its "epoch" changes (e.g. a bill moves to a new due date, or
    a weekly nudge rolls into a new week) so a dismissal is respected but not
    forever-silencing a genuinely new situation.

Run self-tests:
    python3 -c "import core.logic.proactive_ai_tests_snippets as t; t.run_all()"
"""

from core.logic import watch_feed as _wf

# ---- urgency buckets --------------------------------------------------------
URGENCY_NOW = "now"          # needs you today / overdue / high-severity
URGENCY_SOON = "soon"        # within the look-ahead window
URGENCY_FYI = "fyi"          # gentle, informational

URGENCIES = (URGENCY_NOW, URGENCY_SOON, URGENCY_FYI)

# Map a watch_feed group → a proactive urgency bucket.
_GROUP_URGENCY = {
    _wf.GROUP_NEEDS_YOU: URGENCY_NOW,
    _wf.GROUP_TODAY: URGENCY_NOW,
    _wf.GROUP_UPCOMING: URGENCY_SOON,
}

# Each nudge carries a reason KEY the UI localises for "why am I seeing this".
# Keyed by signal kind, with a generic fallback. Engine returns keys, not prose.
REASON_KEYS = {
    "bill_due": "reason_bill_due",
    "loan_due": "reason_loan_due",
    "subscription": "reason_subscription",
    "birthday": "reason_birthday",
    "refill": "reason_refill",
    "expense_gap": "reason_expense_gap",
    "safe_journey": "reason_safe_journey",
    "family_alert": "reason_family_alert",
    "reminder": "reason_reminder",
}
REASON_FALLBACK = "reason_generic"

MARKER_KEY = "proactive_rule"


# ---- id + epoch -------------------------------------------------------------
def suggestion_id(signal):
    """Stable id for a signal so dismissals can be keyed to it.

    Uses kind + an explicit source ref if the caller provides one (`ref`), else
    falls back to kind + title so distinct nudges don't collide. Deterministic;
    no hashing of volatile fields."""
    kind = str(signal.get("kind") or "info")
    ref = signal.get("ref")
    if ref is None or ref == "":
        ref = str(signal.get("title") or signal.get("text") or "")
    return "%s:%s" % (kind, ref)


def epoch(signal):
    """A string that changes when a dismissed nudge should RE-surface.

    - For dated nudges, the due date (caller passes `due` as 'YYYY-MM-DD') — a
      bill that moves to a new date re-surfaces.
    - For the weekly 'expense_gap' nudge, the caller passes `week` (e.g.
      '2026-W41') so a fresh week re-surfaces it.
    - Else '' (dismissal is sticky until the caller changes the id/ref).
    """
    return str(signal.get("due") or signal.get("week") or "")


def is_dismissed(signal, dismissed):
    """True if this signal's (id, epoch) is in the dismissed set.

    `dismissed` is an iterable of {id, epoch} dicts (as persisted). A dismissal
    only suppresses the SAME epoch, so a genuinely-new situation re-appears."""
    sid = suggestion_id(signal)
    ep = epoch(signal)
    for d in dismissed or []:
        if d.get("id") == sid and str(d.get("epoch") or "") == ep:
            return True
    return False


# ---- reason -----------------------------------------------------------------
def reason_key(kind):
    """Localisable 'why am I seeing this' key for a signal kind."""
    return REASON_KEYS.get(kind, REASON_FALLBACK)


# ---- build ------------------------------------------------------------------
def to_suggestion(signal):
    """Normalise ONE raw signal into a proactive suggestion dict (or None if it
    is a future item outside the watch_feed window). Pure; traces back to the
    caller's signal — never fabricates fields."""
    item = _wf.normalize(signal)
    if item is None:
        return None
    urgency = _GROUP_URGENCY.get(item["group"], URGENCY_FYI)
    # Low-severity upcoming items are gentle FYIs, not "soon" nudges.
    if urgency == URGENCY_SOON and item["severity"] == _wf.SEV_LOW:
        urgency = URGENCY_FYI
    return {
        "id": suggestion_id(signal),
        "epoch": epoch(signal),
        "kind": item["kind"],
        "title": signal.get("title", ""),
        "text": signal.get("text", ""),
        "module": signal.get("module", ""),      # deep-link route (client owns)
        "action": signal.get("action", ""),      # quick-action id (optional)
        "days_until": item["days_until"],
        "severity": item["severity"],
        "group": item["group"],
        "urgency": urgency,
        "priority": item["priority"],
        "reason": reason_key(item["kind"]),
        "marker": MARKER_KEY,
        "ai_required": False,
        "mock": False,
    }


def digest(signals, dismissed=None, window=_wf.UPCOMING_WINDOW_DAYS):
    """Turn raw signals into a grouped, dismissal-filtered proactive digest.

    Returns:
        {
          "buckets": {now:[...], soon:[...], fyi:[...]},  # each sorted by priority
          "counts":  {now:int, soon:int, fyi:int, total:int},
          "dismissed_count": int,   # how many were hidden by dismissals
          "has_any": bool,          # any visible nudge at all (honest empty)
          "marker": "proactive_rule",
          "ai_required": False,
        }
    Dropped: future items outside the window, and dismissed (id,epoch) pairs.
    """
    buckets = {u: [] for u in URGENCIES}
    hidden = 0
    for s in signals or []:
        sug = to_suggestion(s)
        if sug is None:
            continue
        if is_dismissed(s, dismissed):
            hidden += 1
            continue
        buckets[sug["urgency"]].append(sug)
    for u in buckets:
        buckets[u].sort(key=lambda it: (it["priority"], it["id"]))
    counts = {u: len(buckets[u]) for u in URGENCIES}
    counts["total"] = sum(counts[u] for u in URGENCIES)
    return {
        "buckets": buckets,
        "counts": counts,
        "dismissed_count": hidden,
        "has_any": counts["total"] > 0,
        "marker": MARKER_KEY,
        "ai_required": False,
    }


def ordered(signals, dismissed=None, window=_wf.UPCOMING_WINDOW_DAYS):
    """Flat, fully-sorted visible digest (now → soon → fyi, by priority)."""
    d = digest(signals, dismissed=dismissed, window=window)
    out = []
    for u in URGENCIES:
        out.extend(d["buckets"][u])
    return out
