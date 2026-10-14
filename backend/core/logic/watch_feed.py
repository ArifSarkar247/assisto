"""
watch_feed.py — Assisto WATCH FEED aggregation (no AI key; pure Python,
deterministic, unit-testable).

WHAT THIS IS
    The Watch Feed is the user's single "what needs my attention now" digest.
    The app already has many module signals (reminders due today, medicine
    doses, money loans/dues, subscription renewals, birthdays, safe-journey
    check-ins, family wellness alerts, price/rate watchers). Each of those is
    served by its own endpoint. This module does NOT invent data — it is the
    pure classifier that turns an already-collected list of raw signals into a
    prioritized, grouped feed the client can render.

    Keeping classification here (instead of scattered in the Flutter screen)
    makes the ordering/grouping rules deterministic and testable, and lets the
    client compose the feed from existing endpoints without duplicating logic.

GROUPS
    "today"      — happens / is due today (or already overdue).
    "upcoming"   — happens within the look-ahead window (default 7 days).
    "needs_you"  — a person/thing needs your decision (family wellness, safe
                   journey overdue, business needs-you, budget blown). These
                   float to the top regardless of date.

PRIORITY (lower sorts first)
    Derived from severity + group so "high + needs_you" always leads and a
    low-severity far-off item trails. Ties break on due-day ascending so the
    soonest actionable item wins.

Run self-tests:
    python3 -c "import core.logic.watch_feed_tests_snippets as t; t.run_all()"
"""

# ---- groups -----------------------------------------------------------------
GROUP_NEEDS_YOU = "needs_you"
GROUP_TODAY = "today"
GROUP_UPCOMING = "upcoming"

GROUPS = (GROUP_NEEDS_YOU, GROUP_TODAY, GROUP_UPCOMING)

# ---- severity ---------------------------------------------------------------
SEV_HIGH = "high"
SEV_MED = "med"
SEV_LOW = "low"

UPCOMING_WINDOW_DAYS = 7

# Signal kinds whose very nature is "a person/thing needs YOUR decision",
# so they belong in needs_you no matter the date. Kept small and explicit.
_NEEDS_YOU_KINDS = frozenset({
    "family_alert", "scam", "checkin_overdue", "fall", "sos",
    "business_needs_you", "budget", "safe_journey",
})

# base rank per group (needs_you first), then severity offset inside the group
_GROUP_RANK = {GROUP_NEEDS_YOU: 0, GROUP_TODAY: 100, GROUP_UPCOMING: 200}
_SEV_RANK = {SEV_HIGH: 0, SEV_MED: 10, SEV_LOW: 20}


def classify_group(kind, days_until, severity=SEV_MED):
    """Return which feed group a signal belongs to.

    kind         — signal kind string (e.g. "refill", "loan_due", "birthday").
    days_until   — int days until it happens; negative = overdue; None = no
                   date (treated as needing attention now).
    severity     — "high" | "med" | "low".
    """
    if kind in _NEEDS_YOU_KINDS:
        return GROUP_NEEDS_YOU
    # High-severity dated items that are due/overdue also need you now.
    if severity == SEV_HIGH and days_until is not None and days_until <= 0:
        return GROUP_NEEDS_YOU
    if days_until is None:
        # Undated but not a needs_you kind → surface as today so it isn't lost.
        return GROUP_TODAY
    if days_until <= 0:
        return GROUP_TODAY
    return GROUP_UPCOMING


def in_window(days_until, window=UPCOMING_WINDOW_DAYS):
    """Should an upcoming (future-dated) signal appear in the feed at all?
    Overdue/undated always show; future shows only within the window."""
    if days_until is None or days_until <= 0:
        return True
    return days_until <= window


def priority(group, severity=SEV_MED, days_until=None):
    """Sort key (ascending). Lower = more urgent / shown first."""
    base = _GROUP_RANK.get(group, 300) + _SEV_RANK.get(severity, 10)
    # Within equal group+severity, sooner due-day wins. Overdue (negative)
    # sorts before today(0) before future. Undated treated as "now" (0).
    du = 0 if days_until is None else days_until
    return (base, du)


def normalize(signal):
    """Coerce a raw signal dict into a complete, classified feed item.

    Input keys (all optional except `kind`):
        kind, title, text, severity, days_until, module (deep-link route),
        action (quick-action id), amount, source, at.
    Output adds: group, priority, and fills defaults so the client can render
    without null-guards. Returns None if the signal is a future item outside
    the look-ahead window (so callers can filter cheaply).
    """
    kind = signal.get("kind") or "info"
    severity = signal.get("severity") or SEV_MED
    if severity not in (SEV_HIGH, SEV_MED, SEV_LOW):
        severity = SEV_MED
    days = signal.get("days_until")
    if days is not None:
        try:
            days = int(days)
        except (TypeError, ValueError):
            days = None
    if not in_window(days):
        return None
    group = classify_group(kind, days, severity)
    out = dict(signal)
    out["kind"] = kind
    out["severity"] = severity
    out["days_until"] = days
    out["group"] = group
    out["priority"] = priority(group, severity, days)
    return out


def build_feed(signals, window=UPCOMING_WINDOW_DAYS):
    """Turn a flat list of raw signals into a grouped, sorted feed.

    Returns a dict: {group: [item, ...]} for the three groups, each list
    sorted by priority. Empty groups are kept (so the client can render honest
    per-group empty copy). Signals outside the window are dropped.
    """
    buckets = {g: [] for g in GROUPS}
    for s in signals or []:
        item = normalize(s)
        if item is None:
            continue
        buckets[item["group"]].append(item)
    for g in buckets:
        buckets[g].sort(key=lambda it: it["priority"])
    return buckets


def ordered(signals, window=UPCOMING_WINDOW_DAYS):
    """Flat, fully-sorted feed (needs_you → today → upcoming, by priority)."""
    buckets = build_feed(signals, window=window)
    out = []
    for g in GROUPS:
        out.extend(buckets[g])
    return out


def counts(signals, window=UPCOMING_WINDOW_DAYS):
    """Per-group counts — handy for a badge / summary line."""
    buckets = build_feed(signals, window=window)
    return {g: len(buckets[g]) for g in GROUPS}
