"""
wedding_events.py — pure, deterministic WEDDING & EVENTS planner logic
(#189, SPEC v2.1 §20). A thin event planner with four honest tools:

  * GUEST LIST          — tally RSVP status (yes/no/maybe/invited) and the
    head-count of confirmed guests + their plus-ones, so the couple can size
    catering honestly.
  * BUDGET TRACKER      — per-category estimated vs actual (INTEGER POISHA),
    totals, variance, and an HONEST over-budget warning. The planner HOLDS NO
    MONEY — it only adds up what the user typed and flags when actual exceeds
    estimate.
  * TASK / VENDOR LIST  — days-until / overdue status from a passed-in `now`
    (honest: a done task is never overdue; an undated task is never overdue),
    with a stable overdue→done partition.
  * COUNTDOWN           — whole days from a passed-in `now` to the event date
    (never the wall clock), with honest today / past states.

HARD RULES:
  * ALL MONEY IS INTEGER POISHA (1 taka = 100 poisha). No float ever enters the
    budget ledger; taka strings are parsed on the decimal string so binary-float
    noise cannot leak in. The planner never holds, moves, or requests money.
  * NO DB, NO AI, NO CLOCK. Time-relative functions take `now` explicitly so
    results are reproducible and testable.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer renders them directly and keeps ZERO Bangla in .dart. The ৳ sign
    lives here, not in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.wedding_events_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ===========================================================================
# poisha <-> taka (integer only; display helper) — mirrors mess_accounting
# ===========================================================================

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha. int → already poisha; '12.50'
    taka strings / taka floats → poisha; junk → 0. Computed on the decimal
    STRING so binary-float noise never leaks in."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    try:
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def _group(n):
    """South-Asian lakh/crore comma grouping of a non-negative integer string."""
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


def fmt_poisha(p):
    """Integer poisha → '৳12,34,567.89'. The ৳ sign lives here, not in .dart."""
    p = int(round(p))
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ===========================================================================
# GUEST LIST — RSVP tally + honest head count
# ===========================================================================

# Canonical RSVP statuses. Anything unknown is treated as 'invited' (honest:
# an un-answered invite is not a 'yes').
RSVP_STATES = ("yes", "no", "maybe", "invited")


def _rsvp(g):
    s = str(g.get("rsvp") or g.get("status") or "invited").strip().lower()
    return s if s in RSVP_STATES else "invited"


def _plus(g):
    try:
        n = int(g.get("plus_ones", 0) or 0)
    except (TypeError, ValueError):
        n = 0
    return max(0, n)


def guest_summary(guests):
    """RSVP tally + confirmed head count. `guests`: [{name, rsvp, plus_ones}].
    Returns {
      total,                      # number of invites (rows)
      counts: {yes,no,maybe,invited},
      confirmed_heads,            # yes guests + their plus-ones
      expected_heads,             # yes + maybe guests + their plus-ones
      pending,                    # maybe + invited (not yet a firm yes/no)
      empty
    }
    confirmed_heads is for catering you can COUNT ON; expected_heads is the
    optimistic ceiling (treats 'maybe' as attending) — both are shown so the
    user plans honestly rather than guessing.
    """
    counts = {s: 0 for s in RSVP_STATES}
    confirmed = 0
    expected = 0
    for g in guests:
        s = _rsvp(g)
        counts[s] += 1
        heads = 1 + _plus(g)
        if s == "yes":
            confirmed += heads
            expected += heads
        elif s == "maybe":
            expected += heads
    return {
        "total": len(guests),
        "counts": counts,
        "confirmed_heads": confirmed,
        "expected_heads": expected,
        "pending": counts["maybe"] + counts["invited"],
        "empty": len(guests) == 0,
    }


def validate_guest(name, guests):
    """Error codes for a new guest. Duplicate name is case-insensitive."""
    errs = []
    n = (name or "").strip()
    if not n:
        errs.append("name_required")
    elif any((g.get("name") or "").strip().lower() == n.lower()
             for g in guests):
        errs.append("duplicate_name")
    return errs


# ===========================================================================
# BUDGET TRACKER — estimated vs actual, honest over-budget warning
# ===========================================================================

# Suggested categories (bilingual). The UI may add free-text categories too;
# the engine does NOT restrict to these — it sums whatever rows it's given.
BUDGET_CATEGORIES = (
    ("venue", "ভেন্যু / কমিউনিটি সেন্টার", "Venue / community centre"),
    ("food", "খাবার / ক্যাটারিং", "Food / catering"),
    ("decor", "সাজসজ্জা / স্টেজ", "Decoration / stage"),
    ("photography", "ফটোগ্রাফি / ভিডিও", "Photography / video"),
    ("attire", "পোশাক / গয়না", "Attire / jewellery"),
    ("gifts", "উপহার / তত্ত্ব", "Gifts / tatto"),
    ("transport", "যাতায়াত", "Transport"),
    ("other", "অন্যান্য", "Other"),
)


def category_label(key, lang="bn"):
    """Bilingual label for a known category key; unknown → the key verbatim
    (honest: we echo a user's free-text category, we don't drop it)."""
    for k, bn, en in BUDGET_CATEGORIES:
        if k == key:
            return pick(lang, bn, en)
    return str(key or "").strip()


def budget_summary(rows, lang="bn"):
    """Per-category estimated-vs-actual roll-up in INTEGER poisha.
    `rows`: [{category, estimated, actual}].  Returns {
      categories: [{category, label, estimated, actual, variance,
                    estimated_display, actual_display, variance_display,
                    over}],   # over=True when actual > estimated
      total_estimated, total_actual, total_variance (+ _display),
      over_budget,            # total actual > total estimated
      over_amount,            # how much over, 0 if within budget
      over_amount_display,
      note, empty
    }
    variance = actual − estimated (positive = spent MORE than planned). The
    honest over-budget warning fires on the TOTAL, and each row flags its own
    overrun. Holds no money — it only totals what the user typed.
    """
    agg = {}
    order = []
    for r in rows:
        cat = str(r.get("category") or "other").strip() or "other"
        if cat not in agg:
            agg[cat] = {"estimated": 0, "actual": 0}
            order.append(cat)
        agg[cat]["estimated"] += to_poisha(r.get("estimated"))
        agg[cat]["actual"] += to_poisha(r.get("actual"))

    cats = []
    tot_est = tot_act = 0
    for cat in order:
        est = agg[cat]["estimated"]
        act = agg[cat]["actual"]
        var = act - est
        tot_est += est
        tot_act += act
        cats.append({
            "category": cat,
            "label": category_label(cat, lang),
            "estimated": est,
            "actual": act,
            "variance": var,
            "estimated_display": fmt_poisha(est),
            "actual_display": fmt_poisha(act),
            "variance_display": fmt_poisha(var),
            "over": act > est,
        })
    total_var = tot_act - tot_est
    over = tot_act > tot_est
    return {
        "categories": cats,
        "total_estimated": tot_est,
        "total_actual": tot_act,
        "total_variance": total_var,
        "total_estimated_display": fmt_poisha(tot_est),
        "total_actual_display": fmt_poisha(tot_act),
        "total_variance_display": fmt_poisha(total_var),
        "over_budget": over,
        "over_amount": total_var if over else 0,
        "over_amount_display": fmt_poisha(total_var if over else 0),
        "note": {
            "bn": "অ্যাসিস্টো কোনো টাকা রাখে না — এটি শুধু আপনার লেখা হিসাব যোগ করে।",
            "en": "Assisto holds no money — it only adds up the amounts you enter.",
        },
        "empty": len(cats) == 0,
    }


# ===========================================================================
# TASK / VENDOR CHECKLIST — honest overdue from a passed-in `now`
# ===========================================================================

def _parse_date(value):
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except (ValueError, TypeError):
        return None


def task_status(task, now):
    """Status of one task/vendor item relative to `now`. Returns
    {state, days, due_date, done, title, vendor} where state ∈
    done | no_due | overdue | due_today | upcoming. `days` is signed days-until
    (negative = overdue), None for done/no_due. Done is NEVER overdue; an
    undated task is NEVER overdue (honest)."""
    n = _parse_date(now)
    due = _parse_date(task.get("due_date"))
    done = bool(task.get("done"))
    title = (task.get("title") or "").strip()
    vendor = (task.get("vendor") or "").strip()
    if done:
        state, days = "done", None
    elif due is None:
        state, days = "no_due", None
    elif n is None:
        state, days = "upcoming", None
    else:
        days = (due - n).days
        state = "overdue" if days < 0 else ("due_today" if days == 0
                                            else "upcoming")
    return {
        "state": state,
        "days": days,
        "due_date": due.isoformat() if isinstance(due, date) else None,
        "done": done,
        "title": title,
        "vendor": vendor,
    }


_TASK_ORDER = {"overdue": 0, "due_today": 1, "upcoming": 2,
               "no_due": 3, "done": 4}


def task_board(tasks, now):
    """Partition + stable-sort tasks/vendors. Returns {overdue, due_today,
    upcoming, no_due, done, counts, all}. Deterministic: within a bucket, sort
    by due date then title then id."""
    statuses = []
    for t in tasks:
        s = task_status(t, now)
        s["id"] = t.get("id")
        statuses.append(s)

    def key(s):
        due = s["due_date"] or "9999-99-99"
        return (_TASK_ORDER.get(s["state"], 9), due,
                s["title"].lower(), str(s.get("id")))

    statuses.sort(key=key)
    buckets = {k: [] for k in _TASK_ORDER}
    for s in statuses:
        buckets[s["state"]].append(s)
    counts = {k: len(v) for k, v in buckets.items()}
    counts["open"] = counts["overdue"] + counts["due_today"] + \
        counts["upcoming"] + counts["no_due"]
    return {
        "overdue": buckets["overdue"],
        "due_today": buckets["due_today"],
        "upcoming": buckets["upcoming"],
        "no_due": buckets["no_due"],
        "done": buckets["done"],
        "counts": counts,
        "all": statuses,
    }


def validate_task(title):
    return [] if (title or "").strip() else ["title_required"]


# ===========================================================================
# COUNTDOWN — whole days from a passed-in `now` to the event date
# ===========================================================================

def countdown(event_date, now):
    """Whole days from `now` to `event_date` (both ISO / date). Returns {
      state,        # no_date | today | future | past
      days,         # days remaining (future) — None otherwise
      days_ago,     # days since (past)      — None otherwise
      event_date, label:{bn,en}
    }. Uses the passed-in `now`, never the wall clock — fully reproducible."""
    ev = _parse_date(event_date)
    n = _parse_date(now)
    if ev is None or n is None:
        return {"state": "no_date", "days": None, "days_ago": None,
                "event_date": ev.isoformat() if isinstance(ev, date) else None,
                "label": {"bn": "তারিখ নির্ধারণ করুন",
                          "en": "Set the event date"}}
    delta = (ev - n).days
    if delta > 0:
        return {"state": "future", "days": delta, "days_ago": None,
                "event_date": ev.isoformat(),
                "label": {"bn": f"আর {delta} দিন বাকি",
                          "en": f"{delta} day{'s' if delta != 1 else ''} to go"}}
    if delta == 0:
        return {"state": "today", "days": 0, "days_ago": 0,
                "event_date": ev.isoformat(),
                "label": {"bn": "আজই অনুষ্ঠান!", "en": "The big day is today!"}}
    ago = -delta
    return {"state": "past", "days": None, "days_ago": ago,
            "event_date": ev.isoformat(),
            "label": {"bn": f"{ago} দিন আগে হয়ে গেছে",
                      "en": f"{ago} day{'s' if ago != 1 else ''} ago"}}
