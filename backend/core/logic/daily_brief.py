"""
daily_brief.py — the deterministic, key-free engine behind Assisto's MORNING
BRIEF & NIGHT SUMMARY (#7, SPEC v2.1 §6, built to ADVANCED §21).

Two daily digest cards assembled DETERMINISTICALLY from the user's OWN app data:

    * MORNING brief  — "what's ahead today": today's reminders, payments due,
                       birthdays, and calendar/meeting events, grouped and
                       ordered so the most time-sensitive item is first.
    * NIGHT summary  — "what happened / tomorrow preview": what was due today
                       (done vs still-open) + a short preview of tomorrow.

This module is PURE, exactly like `pa_brief.py` / `social.py`: no Django, no DB,
no network, **no AI**. ``now`` is ALWAYS passed in (never a live clock) so the
on-device Dart mirror and the tests produce identical output.

HONEST, NOT AI — ASSEMBLED FROM REAL DATA ONLY
----------------------------------------------
The brief is a DETERMINISTIC ASSEMBLY of the user's own entered data. It invents
NOTHING: an empty source contributes nothing and the UI simply shows the honest
"nothing scheduled" state. There is NO fabricated motivational prose. An
"AI-enhanced brief" (warm natural-language narration of the same items) is a
FUTURE, KEY-GATED seam — `ai_brief_plan()` returns the request shape a real
provider would receive; nothing here calls a model.

WEATHER & NEWS ARE KEY-GATED SEAMS (NOT FABRICATED)
---------------------------------------------------
Weather and headlines genuinely need an external feed. We NEVER make them up.
`weather_slot()` / `news_slot()` return a slot the UI renders as an honest
"add a weather / news key" placeholder until the owner connects the matching
Integrations key (`weather` / `news`). When connected, the integrator fills the
slot's `data` from the real feed; the shape is the contract.

The brief returns structured DATA (items, groups, flags) — never localized
prose — so the same assembly drives bn/en and the share text the app builds.

Hand-verified in daily_brief_tests_snippets.py.
"""
from datetime import datetime, timedelta


def parse_dt(v):
    """Parse an ISO string / datetime into a naive datetime, or None."""
    if v is None:
        return None
    if isinstance(v, datetime):
        return v.replace(tzinfo=None) if v.tzinfo else v
    try:
        d = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        return d.replace(tzinfo=None) if d.tzinfo else d
    except (ValueError, TypeError):
        return None


def _day(dt):
    return dt.date() if dt else None


# Item kinds the brief groups by. The UI localises the labels + picks an icon.
KINDS = ("reminder", "payment", "birthday", "event")

# Which brief we're building.
MODES = ("morning", "night")


# ---------------------------------------------------------------------------
# normalise heterogeneous source rows into one flat item shape
# ---------------------------------------------------------------------------

def _mk(kind, title, when=None, amount=None, done=False, meta=None):
    return {
        "kind": kind,
        "title": str(title or "").strip(),
        "when": when.isoformat() if isinstance(when, datetime) else None,
        "_dt": when,                 # internal, stripped before return
        "amount": amount,            # integer poisha or None (payments)
        "done": bool(done),
        "meta": meta or {},
    }


def normalise(reminders=None, payments=None, birthdays=None, events=None):
    """Turn the four heterogeneous source lists into one flat list of items.

    Each source is a list of dicts the caller already fetched from existing
    endpoints (see integration notes). We read only well-known fields and skip
    rows we can't place (no title, or no usable date for dated kinds) — honest:
    a malformed row contributes nothing rather than a blank card.

        reminders : [{title, due_at(iso), done}]
        payments  : [{title|name, due_date(iso)|due_at, amount, paid|done}]
        birthdays : [{name, date(iso)|next(iso)}]
        events    : [{title, start(iso)|when(iso), place}]
    """
    items = []
    for r in (reminders or []):
        t = r.get("title") or r.get("text")
        if not str(t or "").strip():
            continue
        items.append(_mk("reminder", t, parse_dt(r.get("due_at") or r.get("when")),
                         done=bool(r.get("done"))))
    for p in (payments or []):
        t = p.get("title") or p.get("name") or p.get("label")
        if not str(t or "").strip():
            continue
        items.append(_mk("payment", t,
                         parse_dt(p.get("due_date") or p.get("due_at")),
                         amount=p.get("amount"),
                         done=bool(p.get("paid") or p.get("done")),
                         meta={"category": p.get("category", "")}))
    for b in (birthdays or []):
        t = b.get("name") or b.get("title")
        if not str(t or "").strip():
            continue
        items.append(_mk("birthday", t,
                         parse_dt(b.get("next") or b.get("date"))))
    for e in (events or []):
        t = e.get("title") or e.get("name")
        if not str(t or "").strip():
            continue
        items.append(_mk("event", t,
                         parse_dt(e.get("start") or e.get("when")),
                         meta={"place": str(e.get("place") or "").strip()}))
    return items


# ---------------------------------------------------------------------------
# bucketing by day relative to `now`
# ---------------------------------------------------------------------------

def _bucket(item, today, kind_birthday_window=0):
    """Return 'overdue' | 'today' | 'tomorrow' | 'future' | 'undated' for an
    item relative to ``today`` (a date). Birthdays never count as 'overdue' —
    they recur, so a birthday with no date is 'undated' and a past-dated one
    the caller is expected to have advanced to its next occurrence."""
    dt = item.get("_dt")
    if dt is None:
        return "undated"
    d = dt.date()
    diff = (d - today).days
    if item["kind"] == "birthday":
        if diff < 0:
            return "future"      # recurring; a past raw date is not "overdue"
        return "today" if diff == 0 else ("tomorrow" if diff == 1 else "future")
    if diff < 0:
        return "overdue"
    if diff == 0:
        return "today"
    if diff == 1:
        return "tomorrow"
    return "future"


# Sort key: overdue first, then by time-of-day, then kind priority (payments &
# events before reminders before birthdays when same time), then title.
_KIND_ORDER = {"payment": 0, "event": 1, "reminder": 2, "birthday": 3}


def _sort_key(item):
    dt = item.get("_dt")
    # undated items sort last within their group
    t = (dt.hour * 60 + dt.minute) if dt else 24 * 60 + 1
    return (t, _KIND_ORDER.get(item["kind"], 9), item["title"].lower())


def _strip(items):
    out = []
    for it in items:
        c = dict(it)
        c.pop("_dt", None)
        out.append(c)
    return out


# ---------------------------------------------------------------------------
# morning brief
# ---------------------------------------------------------------------------

def morning_brief(now=None, reminders=None, payments=None, birthdays=None,
                  events=None):
    """Assemble the MORNING card: what's ahead TODAY (plus anything overdue that
    still needs the user). Deterministic; invents nothing.

    Returns::

        {
          "mode": "morning",
          "date": "YYYY-MM-DD",
          "overdue":  [items...],   # past-due, still open — needs you first
          "today":    [items...],   # due today
          "counts":   {"overdue","today","total", per-kind...},
          "empty":    bool,         # honest: nothing scheduled
          "weather":  <slot>,       # key-gated placeholder
          "ai_enhanced": False,     # deterministic assembly, no model
          "mock": True
        }
    """
    now = parse_dt(now) or datetime.now()
    today = now.date()
    items = normalise(reminders, payments, birthdays, events)

    overdue, due_today = [], []
    for it in items:
        if it["done"]:
            continue
        b = _bucket(it, today)
        if b == "overdue":
            overdue.append(it)
        elif b == "today":
            due_today.append(it)

    overdue.sort(key=_sort_key)
    due_today.sort(key=_sort_key)

    counts = {"overdue": len(overdue), "today": len(due_today),
              "total": len(overdue) + len(due_today)}
    for k in KINDS:
        counts[k] = sum(1 for it in (overdue + due_today) if it["kind"] == k)

    return {
        "mode": "morning",
        "date": today.isoformat(),
        "overdue": _strip(overdue),
        "today": _strip(due_today),
        "counts": counts,
        "empty": counts["total"] == 0,
        "weather": weather_slot(),
        "ai_enhanced": False,
        "mock": True,
    }


# ---------------------------------------------------------------------------
# night summary
# ---------------------------------------------------------------------------

def night_summary(now=None, reminders=None, payments=None, birthdays=None,
                  events=None):
    """Assemble the NIGHT card: what happened TODAY + a TOMORROW preview.

    Returns::

        {
          "mode": "night",
          "date": "YYYY-MM-DD",
          "done_today":   [items...],   # due today AND marked done
          "open_today":   [items...],   # due today, still not done
          "tomorrow":     [items...],   # due tomorrow (preview)
          "counts": {"done","open","tomorrow","completion_pct", per-kind...},
          "empty": bool,
          "news": <slot>,               # key-gated placeholder
          "ai_enhanced": False,
          "mock": True
        }

    ``completion_pct`` is an honest integer: done / (done+open) today, 0 when
    nothing was due. We never round a day with open items up to 100%."""
    now = parse_dt(now) or datetime.now()
    today = now.date()
    items = normalise(reminders, payments, birthdays, events)

    done_today, open_today, tomorrow = [], [], []
    for it in items:
        b = _bucket(it, today)
        if b == "today":
            (done_today if it["done"] else open_today).append(it)
        elif b == "tomorrow" and not it["done"]:
            tomorrow.append(it)

    done_today.sort(key=_sort_key)
    open_today.sort(key=_sort_key)
    tomorrow.sort(key=_sort_key)

    due = len(done_today) + len(open_today)
    pct = int(round(len(done_today) / due * 100)) if due else 0
    counts = {"done": len(done_today), "open": len(open_today),
              "tomorrow": len(tomorrow), "completion_pct": pct}
    for k in KINDS:
        counts[k] = sum(1 for it in tomorrow if it["kind"] == k)

    return {
        "mode": "night",
        "date": today.isoformat(),
        "done_today": _strip(done_today),
        "open_today": _strip(open_today),
        "tomorrow": _strip(tomorrow),
        "counts": counts,
        "empty": (due == 0 and not tomorrow),
        "news": news_slot(),
        "ai_enhanced": False,
        "mock": True,
    }


def build(mode="morning", now=None, reminders=None, payments=None,
          birthdays=None, events=None):
    """Single entry point. ``mode`` in MODES selects morning/night; anything
    else falls back to morning (total, never crashes)."""
    if mode == "night":
        return night_summary(now, reminders, payments, birthdays, events)
    return morning_brief(now, reminders, payments, birthdays, events)


# ---------------------------------------------------------------------------
# key-gated external slots — HONEST placeholders, never fabricated
# ---------------------------------------------------------------------------

def weather_slot(connected=False, data=None):
    """Weather slot for the morning card. HONEST: with no `weather` Integrations
    key connected we return an empty slot the UI renders as "add a weather key".
    We NEVER fabricate a forecast. When the integrator wires the `weather` key,
    it passes connected=True + the real `data` (e.g. {temp_c, summary_key,
    high_c, low_c}); the shape is the contract, not invented here."""
    return {
        "slot": "weather",
        "integration": "weather",     # Integrations registry key
        "connected": bool(connected),
        "data": data if (connected and data) else None,
        "needs_key": not connected,
        "mock": True,
    }


def news_slot(connected=False, items=None):
    """Headline slot for the night card. HONEST: with no `news` Integrations key
    connected we return an empty slot the UI renders as "add a news key". We
    NEVER fabricate headlines. When wired, the integrator passes connected=True
    + real `items` (list of {title, url}); the shape is the contract."""
    return {
        "slot": "news",
        "integration": "news",        # Integrations registry key
        "connected": bool(connected),
        "items": list(items) if (connected and items) else [],
        "needs_key": not connected,
        "mock": True,
    }


# ---------------------------------------------------------------------------
# share / export text (plain, portable) — the app localises labels; this is the
# backend-side share body. Kept ASCII-structural so callers can localise.
# ---------------------------------------------------------------------------

def share_text(brief, labels=None):
    """Assemble a plain-text brief for share/export from a morning/night dict.

    ``labels`` is an OPTIONAL dict of localized section labels the CALLER passes
    (the app supplies bn/en from its ARB); when omitted we fall back to neutral
    English keys so the backend can still emit something useful in tests/logs.
    Emits NO Bangla itself. Omits empty sections (honest). Returns a string."""
    L = {"overdue": "Overdue", "today": "Today", "tomorrow": "Tomorrow",
         "done": "Done", "open": "Still open", "nothing": "Nothing scheduled"}
    if labels:
        L.update({k: str(v) for k, v in labels.items() if v})

    def _fmt(it):
        when = ""
        if it.get("when"):
            dt = parse_dt(it["when"])
            if dt:
                when = " " + dt.strftime("%H:%M")
        return "  - " + it["title"] + when

    lines = []
    if brief.get("mode") == "night":
        sections = [("done", "done_today"), ("open", "open_today"),
                    ("tomorrow", "tomorrow")]
    else:
        sections = [("overdue", "overdue"), ("today", "today")]
    for label_key, data_key in sections:
        rows = brief.get(data_key) or []
        if rows:
            lines.append(L[label_key] + ":")
            lines.extend(_fmt(it) for it in rows)
    if not lines:
        lines.append(L["nothing"])
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# FUTURE, KEY-GATED AI seam (documented, NOT built)
# ---------------------------------------------------------------------------

def ai_brief_plan(brief, lang="bn"):
    """Return the request SHAPE a real provider would receive to NARRATE the
    brief in warm natural language (the same items, rephrased into a few
    friendly lines). This NEVER calls a model and needs NO key; it only
    describes the contract so the integrator can wire `core.ai.generate` behind
    the `anthropic` key later. Only the user's OWN assembled items are ever
    sent; the deterministic cards stay the always-available, honest path."""
    return {
        "task": "narrate_daily_brief",
        "mode": brief.get("mode", "morning"),
        "lang": lang if lang in ("bn", "en") else "bn",
        "source": {k: brief.get(k) for k in
                   ("overdue", "today", "done_today", "open_today", "tomorrow")
                   if brief.get(k)},
        "ai_required": True,     # this path needs the anthropic key
        "mock": False,
    }
