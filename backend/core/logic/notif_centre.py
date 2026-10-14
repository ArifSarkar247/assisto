"""
notif_centre.py — Assisto HOME NOTIFICATION CENTRE (pure, deterministic, no AI,
no Django, no DB, no network). Unit-testable stdlib only.

WHAT THIS IS
    The home screen has TWO distinct inboxes, served by this one engine:

    a) REMINDERS feed  — everything TIME-BOUND the user must act on, grouped into
       today / upcoming / missed. Built by aggregating already-collected raw rows
       (reminders, medicine doses, bills/subscriptions due, meetings, birthdays,
       document expiry, loan/EMI returns, to-dos). Each item is actionable
       (done / snooze / open) and deep-links via a screen route.

    b) NOTIFICATIONS feed — events that HAPPENED (circle/community/channel
       requests + activity, family alerts, scam alerts, watch-feed alerts,
       business/CRM events, security logins, plan/points, app updates). Each has
       a seen flag; the feed supports type filtering, mark-all-read and an
       unseen count.

    This module NEVER invents data and NEVER touches the DB. The Django view
    collects the raw rows (the user's records) + `now`, hands them in, and this
    classifies / groups / sorts / localises them. Keeping it pure makes the
    sectioning + snooze math deterministic and testable, and lets the Flutter
    client cache the output offline (the endpoints are only the sync source).

HARD RULES (from the brief)
    * CHAT MESSAGES ARE EXCLUDED from the notifications feed — they belong to the
      My Circle unread count, not here. `is_chat_event()` guards this and
      `build_feed()` drops anything it flags.
    * Each notification respects its module's per-type enabled flag
      (`settings_enabled`): a disabled type is filtered out of the feed AND the
      unseen count.
    * Bilingual: every item carries title/body as {"bn":..., "en":...} so the
      client renders the user's language without a server round-trip.

Run self-tests:
    (cd backend && python3 -c "import core.logic.notif_centre_tests_snippets as t; t.run_all()")
"""
from datetime import datetime, date, timedelta

# ---------------------------------------------------------------------------
# REMINDERS FEED — sections
# ---------------------------------------------------------------------------
SEC_TODAY = "today"
SEC_UPCOMING = "upcoming"
SEC_MISSED = "missed"
SECTIONS = (SEC_MISSED, SEC_TODAY, SEC_UPCOMING)

# How far ahead an upcoming item may be and still appear in the feed.
UPCOMING_WINDOW_DAYS = 7

# Deep-link routes are the canonical screen_synonyms routes. We map each source
# module to the route the client should open. (screen_synonyms.resolve() turns
# user text into these same routes; here we go source -> route directly.)
_SOURCE_ROUTE = {
    "reminder": "reminders",
    "todo": "notes",
    "medicine": "family",
    "bill": "money",
    "subscription": "subscriptions",
    "meeting": "meetings",
    "appointment": "meetings",
    "birthday": "birthdays",
    "document": "documents",
    "loan": "money",
    "emi": "finance",
}


def route_for(source_module):
    """Deep-link route for a reminders-feed item, via the screen_synonyms map."""
    return _SOURCE_ROUTE.get(source_module, "reminders")


def _as_dt(v):
    """Coerce date/datetime/ISO-string to a datetime (date -> midnight). None-safe."""
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    if isinstance(v, date):
        return datetime(v.year, v.month, v.day)
    if isinstance(v, str):
        s = v.strip()
        try:
            if "T" in s or " " in s:
                return datetime.fromisoformat(s.replace(" ", "T")[:19])
            d = date.fromisoformat(s[:10])
            return datetime(d.year, d.month, d.day)
        except ValueError:
            return None
    return None


def section_for(when, now, done=False):
    """Which reminders section does a time-bound item fall in?

    done=True  → None (completed items never show).
    when==None → "today" (undated but outstanding → surface so it isn't lost).
    past       → "missed".
    same day   → "today".
    future     → "upcoming".
    """
    if done:
        return None
    w = _as_dt(when)
    if w is None:
        return SEC_TODAY
    if w < now:
        # Same calendar day but earlier clock time still counts as TODAY, not
        # missed, so a 9am dose shown at 10am stays actionable under Today.
        if w.date() == now.date():
            return SEC_TODAY
        return SEC_MISSED
    if w.date() == now.date():
        return SEC_TODAY
    return SEC_UPCOMING


def in_feed_window(when, now, window=UPCOMING_WINDOW_DAYS):
    """Should the item appear at all? Missed + today always; future only within
    the look-ahead window."""
    w = _as_dt(when)
    if w is None:
        return True
    if w < now:
        return True
    return (w.date() - now.date()).days <= window


def _item_sort_key(item):
    """Missed first (oldest first), then today, then upcoming (soonest first)."""
    order = {SEC_MISSED: 0, SEC_TODAY: 1, SEC_UPCOMING: 2}
    w = _as_dt(item.get("when"))
    ts = w.timestamp() if w else 0.0
    return (order.get(item.get("section"), 9), ts)


_DEFAULT_ACTIONS = ("done", "snooze", "open")


def normalize_reminder(raw, now, window=UPCOMING_WINDOW_DAYS):
    """Coerce one raw time-bound row into a complete reminders-feed item, or None
    if it is done / out of the look-ahead window.

    Input raw keys:
        id            — stable id (client uses it for done/snooze).
        source_module — reminder|todo|medicine|bill|subscription|meeting|
                        appointment|birthday|document|loan|emi
        title         — {"bn":..,"en":..} OR a plain string (used for both langs).
        when          — datetime/date/ISO string/None.
        done          — bool (optional).
        actions       — override the default [done, snooze, open] (optional).
        route         — override the source->route mapping (optional).
        meta          — any extra dict the client wants echoed (optional).
    """
    done = bool(raw.get("done"))
    when = raw.get("when")
    if not in_feed_window(when, now, window):
        return None
    section = section_for(when, now, done=done)
    if section is None:
        return None
    src = raw.get("source_module") or "reminder"
    title = raw.get("title")
    if isinstance(title, str):
        title = {"bn": title, "en": title}
    elif not isinstance(title, dict):
        title = {"bn": "", "en": ""}
    w = _as_dt(when)
    item = {
        "id": raw.get("id"),
        "source_module": src,
        "title": {"bn": title.get("bn", ""), "en": title.get("en", "")},
        "when": w.isoformat() if w else None,
        "section": section,
        "route": raw.get("route") or route_for(src),
        "actions": list(raw.get("actions") or _DEFAULT_ACTIONS),
    }
    if raw.get("meta") is not None:
        item["meta"] = raw["meta"]
    return item


def build_reminders(raw_items, now, window=UPCOMING_WINDOW_DAYS):
    """Aggregate raw time-bound rows into {missed, today, upcoming} sections,
    each sorted. Empty sections are kept so the client can show honest empties."""
    buckets = {s: [] for s in SECTIONS}
    for raw in raw_items or []:
        it = normalize_reminder(raw, now, window)
        if it is None:
            continue
        buckets[it["section"]].append(it)
    for s in buckets:
        buckets[s].sort(key=_item_sort_key)
    return buckets


def reminders_counts(raw_items, now, window=UPCOMING_WINDOW_DAYS):
    b = build_reminders(raw_items, now, window)
    return {s: len(b[s]) for s in SECTIONS}


# ---------------------------------------------------------------------------
# SNOOZE — 15m / 1h / tomorrow / custom  → return the NEW time
# ---------------------------------------------------------------------------
SNOOZE_PRESETS = ("15m", "1h", "tomorrow", "custom")
TOMORROW_HOUR = 8  # tomorrow snooze lands at 08:00 local


def snooze_until(option, now, current_when=None, custom=None):
    """Compute the new fire time for a snooze.

    option: "15m" | "1h" | "tomorrow" | "custom".
      15m / 1h  → relative to NOW (not the old due time — the user is acting now).
      tomorrow  → next day at TOMORROW_HOUR.
      custom    → `custom` (datetime / date / ISO string), returned as-is.
    Returns a datetime, or None if unparseable.
    """
    opt = (option or "").strip().lower()
    if opt == "15m":
        return now + timedelta(minutes=15)
    if opt == "1h":
        return now + timedelta(hours=1)
    if opt == "tomorrow":
        d = now.date() + timedelta(days=1)
        return datetime(d.year, d.month, d.day, TOMORROW_HOUR, 0)
    if opt == "custom":
        return _as_dt(custom)
    return None


# ---------------------------------------------------------------------------
# NOTIFICATIONS FEED — events that happened
# ---------------------------------------------------------------------------
# Known event types grouped by domain. `type` is the stable key the client
# filters on (GET notif/feed?type=...). These double as the per-type settings
# keys (settings_enabled map).
TYPE_CIRCLE_REQUEST = "circle_request"      # someone wants to connect
TYPE_CIRCLE_ACTIVITY = "circle_activity"    # status/reaction/group activity (NOT chat)
TYPE_COMMUNITY = "community"                 # community request/activity
TYPE_CHANNEL = "channel"                     # channel request/activity
TYPE_FAMILY_ALERT = "family_alert"          # missed-medicine / fall relayed to family
TYPE_SAFE_JOURNEY = "safe_journey"          # arrived / overdue
TYPE_SOS = "sos"
TYPE_SCAM = "scam"
TYPE_WATCH = "watch"                         # price/rate watcher hit
TYPE_BUSINESS = "business"                   # order / lead / due (CRM)
TYPE_SECURITY = "security"                   # new-device login
TYPE_PLAN = "plan"                           # plan / points
TYPE_APP_UPDATE = "app_update"

NOTIF_TYPES = (
    TYPE_CIRCLE_REQUEST, TYPE_CIRCLE_ACTIVITY, TYPE_COMMUNITY, TYPE_CHANNEL,
    TYPE_FAMILY_ALERT, TYPE_SAFE_JOURNEY, TYPE_SOS, TYPE_SCAM, TYPE_WATCH,
    TYPE_BUSINESS, TYPE_SECURITY, TYPE_PLAN, TYPE_APP_UPDATE,
)

# Chat-message event types that MUST NOT appear in the notification centre —
# they feed the My Circle unread badge instead. Guarded explicitly.
_CHAT_EVENT_TYPES = frozenset({
    "chat", "chat_message", "message", "dm", "circle_message", "group_message",
})

# Route per notification type (deep-link via screen_synonyms routes).
_TYPE_ROUTE = {
    TYPE_CIRCLE_REQUEST: "circle",
    TYPE_CIRCLE_ACTIVITY: "circle",
    TYPE_COMMUNITY: "circle",
    TYPE_CHANNEL: "circle",
    TYPE_FAMILY_ALERT: "family",
    TYPE_SAFE_JOURNEY: "journey",
    TYPE_SOS: "emergency",
    TYPE_SCAM: "scam",
    TYPE_WATCH: "watch_feed",
    TYPE_BUSINESS: "business",
    TYPE_SECURITY: "plans",
    TYPE_PLAN: "plans",
    TYPE_APP_UPDATE: "plans",
}


def is_chat_event(ev):
    """True if an event is a chat message (so it must be EXCLUDED from the notif
    centre). Matches on an explicit type OR a chat marker flag."""
    t = (ev.get("type") or "").strip().lower()
    if t in _CHAT_EVENT_TYPES:
        return True
    return bool(ev.get("is_chat") or ev.get("chat_message"))


def type_enabled(etype, settings_enabled):
    """Is this notification type enabled in the user's per-type settings?
    Missing key / None settings → enabled (opt-out model). An explicit False
    suppresses the type."""
    if not settings_enabled:
        return True
    return settings_enabled.get(etype, True) is not False


def route_for_type(etype):
    return _TYPE_ROUTE.get(etype, "plans")


def normalize_event(ev):
    """Coerce one raw event into a complete notification item (bilingual), or
    None if it is a chat event (excluded by rule).

    Input ev keys:
        id    — stable id.
        type  — one of NOTIF_TYPES (free strings tolerated).
        title / body — {"bn","en"} OR plain string.
        at    — datetime / ISO string.
        seen  — bool (default False).
        route — override (optional).
        meta  — extra echoed dict (optional).
    """
    if is_chat_event(ev):
        return None
    etype = ev.get("type") or "app_update"

    def _bi(v):
        if isinstance(v, str):
            return {"bn": v, "en": v}
        if isinstance(v, dict):
            return {"bn": v.get("bn", ""), "en": v.get("en", "")}
        return {"bn": "", "en": ""}

    at = _as_dt(ev.get("at"))
    out = {
        "id": ev.get("id"),
        "type": etype,
        "title": _bi(ev.get("title")),
        "body": _bi(ev.get("body")),
        "at": at.isoformat() if at else None,
        "seen": bool(ev.get("seen")),
        "route": ev.get("route") or route_for_type(etype),
    }
    if ev.get("meta") is not None:
        out["meta"] = ev["meta"]
    return out


def build_feed(events, settings_enabled=None, type_filter=None):
    """Turn raw events into the notifications feed.

    * Drops chat events (rule).
    * Drops types disabled in settings_enabled.
    * Optionally keeps only `type_filter` (a type string or a set/list of types).
    * Sorts newest-first (events with no `at` sort last).
    Returns a list of normalized items.
    """
    wanted = None
    if type_filter:
        wanted = {type_filter} if isinstance(type_filter, str) else set(type_filter)
    out = []
    for ev in events or []:
        it = normalize_event(ev)
        if it is None:
            continue
        if not type_enabled(it["type"], settings_enabled):
            continue
        if wanted is not None and it["type"] not in wanted:
            continue
        out.append(it)

    def _k(it):
        at = _as_dt(it.get("at"))
        return at.timestamp() if at else float("-inf")

    out.sort(key=_k, reverse=True)
    return out


def unseen_count(events, settings_enabled=None):
    """Number of enabled, non-chat events the user hasn't seen. Drives the home
    notification badge."""
    return sum(1 for it in build_feed(events, settings_enabled) if not it["seen"])


def mark_all_seen(events, settings_enabled=None):
    """Return the feed with every (enabled, non-chat) item marked seen — the pure
    half of 'mark-all-read' (the view persists the seen ids / read_all_at)."""
    feed = build_feed(events, settings_enabled)
    for it in feed:
        it["seen"] = True
    return feed


def badges(chat_unread, events, settings_enabled=None):
    """The two home badges in one shot.

    my_circle_unread — passed-in chat unread count (computed by the view from
                       CircleMessage; CHAT lives here, NOT in the notif centre).
    notif_unseen     — unseen count of the notification centre (chat excluded).
    """
    return {
        "my_circle_unread": max(0, int(chat_unread or 0)),
        "notif_unseen": unseen_count(events, settings_enabled),
    }
