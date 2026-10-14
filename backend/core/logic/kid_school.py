"""
kid_school.py — pure, deterministic KID'S SCHOOL CORNER logic (#27, SPEC v2.1
§21 advanced). A parent manages a child's school life:

  * CHILDREN            — a minimal, parent-owned roster (name + class only; no
    extra child data is required or invented — child-privacy by design).
  * SCHOOL NOTICES      — the parent MANUALLY enters a notice (title/body) and
    tags its type, OR a deterministic keyword router SUGGESTS a type. There is
    NO AI and NO document scan — `suggest_type` is a transparent keyword lookup
    the UI shows as a suggestion the parent confirms. Types:
        fee  | exam | ptm | event | other
    A fee notice carries an optional ৳ amount + a due date; exam/ptm/event carry
    a date; `other` carries neither.
  * UPCOMING / OVERDUE  — from a passed-in `now` (never the wall clock), each
    dated notice is classified honestly:
        overdue   — its date is strictly before `now` and it's not done/paid
        due_today — its date == `now`
        upcoming  — its date is after `now`
        no_date   — no date set (honest: can never be "overdue")
        done      — marked done/paid (never overdue, even if past)
    with a per-child rollup and a stable overdue→done sort.

HARD RULES (this module holds no data and does no I/O):
  * NO DB, NO AI, NO CLOCK, NO SCAN. Every time-relative function takes `now`
    explicitly so results are reproducible and testable. Returns plain dicts.
  * CHILD PRIVACY. A child row is only {name, klass}. We never require birthdays,
    IDs, photos, or anything beyond what a parent types to organise notices.
  * The keyword router is a MODULE CONSTANT, documented below and echoed via
    `type_keywords()` so the routing is never a black box and the parent can see
    why a type was suggested. A low-confidence guess returns 'other' — we never
    force a type onto an ambiguous notice.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer renders them directly and keeps ZERO Bangla in .dart.
  * MONEY: a fee amount is stored as the parent typed it; the ৳ glyph is a
    display concern. This module reports the raw amount string back untouched
    (no money is held, no arithmetic on fees beyond passing it through).

REMINDER SEAM (documented, NOT wired): `due_soon(notices, now, within_days)`
returns the dated notices that fall due within `within_days` of `now` — exactly
the set a future reminder/notification job would act on. No notification is
scheduled here; the app currently surfaces these in-screen only (consistent with
the project's foreground-polling decision).

Row shapes the view layer stores (see integration note):
  child  : {id, name, klass}
  notice : {id, child, title, body, type, amount, date, done}
           type ∈ {fee, exam, ptm, event, other}; date 'YYYY-MM-DD';
           amount only meaningful for type == 'fee'; done flags paid/handled.

Run self-tests (no DB):
    python3 -c "import core.logic.kid_school_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ===========================================================================
# NOTICE TYPES + deterministic keyword router
# ===========================================================================

# Ordered. Each: (value, bn_label, en_label, has_date, has_amount).
NOTICE_TYPES = (
    ("fee", "ফি", "Fee", True, True),
    ("exam", "পরীক্ষা", "Exam", True, False),
    ("ptm", "অভিভাবক সভা", "Parents' meeting", True, False),
    ("event", "অনুষ্ঠান", "Event", True, False),
    ("other", "অন্যান্য", "Other", False, False),
)
_TYPE_INFO = {v: (bn, en, hd, ha) for v, bn, en, hd, ha in NOTICE_TYPES}
VALID_TYPES = tuple(v for v, *_ in NOTICE_TYPES)

# Keyword → type. Lower-cased substring match on the notice title+body. Both
# Bangla and English cues, because a BD school notice arrives in either. This is
# a SUGGESTION engine the parent confirms — it never overrides a type the parent
# already picked. Order matters: the first type with any hit wins the suggestion;
# ties are broken by this declared priority (fee > exam > ptm > event).
TYPE_KEYWORDS = {
    "fee": (
        "fee", "fees", "tuition", "payment", "due", "bill", "invoice",
        "admission", "session charge", "montly", "monthly",
        "ফি", "বেতন", "পরিশোধ", "বকেয়া", "চাঁদা", "ভর্তি", "টাকা",
    ),
    "exam": (
        "exam", "examination", "test", "quiz", "assessment", "result",
        "mid-term", "midterm", "final", "half-yearly", "annual exam",
        "পরীক্ষা", "টেস্ট", "মূল্যায়ন", "ফলাফল", "রেজাল্ট",
    ),
    "ptm": (
        "ptm", "parent", "parents meeting", "parent-teacher", "meeting",
        "guardian", "অভিভাবক", "সভা", "মিটিং", "শিক্ষক-অভিভাবক",
    ),
    "event": (
        "event", "sports", "annual day", "cultural", "picnic", "celebration",
        "programme", "program", "fair", "function", "field trip", "holiday",
        "অনুষ্ঠান", "খেলা", "ক্রীড়া", "সাংস্কৃতিক", "পিকনিক", "ছুটি", "ভ্রমণ",
    ),
}
# Priority for tie-breaking when more than one type matches.
_TYPE_PRIORITY = ("fee", "exam", "ptm", "event")


def type_label(value, lang="bn"):
    info = _TYPE_INFO.get(value)
    if not info:
        return value or ""
    return pick(lang, info[0], info[1])


def type_rows(lang="bn"):
    """The whole type catalog as display rows — so the UI can show the chooser
    and know which fields each type uses. [{value, label, has_date, has_amount}]."""
    return [
        {
            "value": v,
            "label": pick(lang, bn, en),
            "has_date": hd,
            "has_amount": ha,
        }
        for v, bn, en, hd, ha in NOTICE_TYPES
    ]


def type_keywords():
    """Echo the router table so the UI can SHOW why a type was suggested."""
    return {k: list(v) for k, v in TYPE_KEYWORDS.items()}


def suggest_type(title, body=""):
    """Deterministic keyword routing: suggest a notice type from its text.

    Returns {type, confident, matched} where:
        type       — the suggested type value (one of VALID_TYPES)
        confident  — True only when at least one keyword matched; False means we
                     fell back to 'other' because nothing matched (honest — we
                     never pretend to know)
        matched    — the keyword that triggered the suggestion, or None
    The parent always confirms; this only pre-selects the dropdown.
    """
    text = f"{title or ''} {body or ''}".lower()
    best = None
    best_kw = None
    for t in _TYPE_PRIORITY:
        for kw in TYPE_KEYWORDS[t]:
            if kw.lower() in text:
                best = t
                best_kw = kw
                break
        if best is not None:
            break
    if best is None:
        return {"type": "other", "confident": False, "matched": None}
    return {"type": best, "confident": True, "matched": best_kw}


# ===========================================================================
# date helpers — honest, no live clock
# ===========================================================================

def _parse_date(value):
    """ISO 'YYYY-MM-DD' (or date/datetime) → date, else None."""
    if value is None or value == "":
        return None
    if isinstance(value, date):
        return value
    try:
        return date.fromisoformat(str(value)[:10])
    except (ValueError, TypeError):
        return None


def _is_done(notice):
    return bool(notice.get("done"))


# ===========================================================================
# per-notice status + per-child board
# ===========================================================================

def notice_status(notice, now):
    """Status of one notice relative to `now`. Returns
        {id, child, title, type, type_known, has_date, amount,
         date, done, state, days}
    where `state` is one of:
        done      — marked done/paid (never 'overdue', even if past date)
        no_date   — type carries no date OR none set (honest)
        overdue   — date strictly before `now`, not done
        due_today — date == now
        upcoming  — date after now
    `days` is signed days-until (negative = overdue), or None for done/no_date.
    An 'other' notice (dateless by type) is always no_date.
    """
    t = notice.get("type") or "other"
    if t not in VALID_TYPES:
        t = "other"
    info = _TYPE_INFO[t]
    has_date_field = info[2]
    n = _parse_date(now)
    due = _parse_date(notice.get("date")) if has_date_field else None
    done = _is_done(notice)
    base = {
        "id": notice.get("id"),
        "child": notice.get("child"),
        "title": (notice.get("title") or "").strip(),
        "type": t,
        "has_date": has_date_field,
        "amount": notice.get("amount") if t == "fee" else None,
        "date": due.isoformat() if isinstance(due, date) else None,
        "done": done,
    }
    if done:
        base.update({"state": "done", "days": None})
        return base
    if due is None:
        base.update({"state": "no_date", "days": None})
        return base
    if n is None:
        # No reference time → cannot judge overdue; be honest.
        base.update({"state": "upcoming", "days": None})
        return base
    delta = (due - n).days
    if delta < 0:
        state = "overdue"
    elif delta == 0:
        state = "due_today"
    else:
        state = "upcoming"
    base.update({"state": state, "days": delta})
    return base


_STATE_ORDER = {"overdue": 0, "due_today": 1, "upcoming": 2,
                "no_date": 3, "done": 4}


def child_board(notices, now):
    """Partition + sort a child's notices for display. Returns {
        overdue, due_today, upcoming, no_date, done,  (lists of status dicts)
        fees, exams, ptm, events,                     (by type, open only)
        counts: {overdue, due_today, upcoming, no_date, done, open,
                 fee, exam, ptm, event, other},
        all: [...]   (every notice, stable overdue→done, then by date)
    }. Deterministic: within a bucket sort by date, then title, then id."""
    statuses = [notice_status(x, now) for x in notices]

    def key(s):
        d = s["date"] or "9999-99-99"
        return (_STATE_ORDER.get(s["state"], 9), d,
                s["title"].lower(), str(s.get("id")))

    statuses.sort(key=key)
    buckets = {k: [] for k in _STATE_ORDER}
    by_type = {t: [] for t in VALID_TYPES}
    for s in statuses:
        buckets[s["state"]].append(s)
        by_type[s["type"]].append(s)
    counts = {k: len(v) for k, v in buckets.items()}
    counts["open"] = (counts["overdue"] + counts["due_today"]
                      + counts["upcoming"] + counts["no_date"])
    for t in VALID_TYPES:
        counts[t] = len(by_type[t])
    # "open" (not-done) items per type, for the upcoming-per-child lists.
    open_by_type = {t: [s for s in by_type[t] if s["state"] != "done"]
                    for t in VALID_TYPES}
    return {
        "overdue": buckets["overdue"],
        "due_today": buckets["due_today"],
        "upcoming": buckets["upcoming"],
        "no_date": buckets["no_date"],
        "done": buckets["done"],
        "fees": open_by_type["fee"],
        "exams": open_by_type["exam"],
        "ptm": open_by_type["ptm"],
        "events": open_by_type["event"],
        "counts": counts,
        "all": statuses,
    }


def due_soon(notices, now, within_days=7):
    """REMINDER SEAM (documented, not wired). The dated, not-done notices whose
    date falls on or after `now` and within `within_days` days — the exact set a
    future reminder job would act on. Overdue items are NOT included here (a
    reminder is forward-looking); use child_board()['overdue'] for those.
    Returns a date-sorted list of status dicts. Deterministic."""
    out = []
    for s in (notice_status(x, now) for x in notices):
        if s["state"] in ("upcoming", "due_today") and s["days"] is not None \
                and 0 <= s["days"] <= within_days:
            out.append(s)
    out.sort(key=lambda s: (s["date"] or "9999-99-99",
                            s["title"].lower(), str(s.get("id"))))
    return out


def roster_summary(children, notices, now):
    """A home-screen rollup across all children. Returns {
        children: [{id, name, klass, overdue, due_today, open, next}],
        totals: {children, overdue, due_today, open},
        empty: bool
    }. `next` is the single nearest upcoming/overdue dated notice for the child
    (or None), so the list tile can show 'next up' honestly."""
    by_child = {}
    for x in notices:
        by_child.setdefault(x.get("child"), []).append(x)
    rows = []
    tot_overdue = tot_today = tot_open = 0
    for c in children:
        cid = c.get("id")
        board = child_board(by_child.get(cid, []), now)
        co = board["counts"]
        # nearest actionable dated item: prefer overdue (most urgent), else the
        # earliest upcoming/due_today.
        nxt = None
        if board["overdue"]:
            nxt = board["overdue"][-1]  # least-overdue (closest to today)
        else:
            dated = board["due_today"] + board["upcoming"]
            dated = [d for d in dated if d["date"]]
            if dated:
                nxt = min(dated, key=lambda d: d["date"])
        rows.append({
            "id": cid,
            "name": (c.get("name") or "").strip(),
            "klass": (c.get("klass") or "").strip(),
            "overdue": co["overdue"],
            "due_today": co["due_today"],
            "open": co["open"],
            "next": nxt,
        })
        tot_overdue += co["overdue"]
        tot_today += co["due_today"]
        tot_open += co["open"]
    return {
        "children": rows,
        "totals": {
            "children": len(children),
            "overdue": tot_overdue,
            "due_today": tot_today,
            "open": tot_open,
        },
        "empty": len(children) == 0,
    }


# ===========================================================================
# validation (wire validates on save; UI mirrors this)
# ===========================================================================

def validate_child(name, klass):
    """Error codes for a child row. Empty list → valid. Child privacy: only a
    name is required; class is optional (not every parent tracks a class)."""
    return [] if (name or "").strip() else ["name_required"]


def validate_notice(title, ntype, amount=None, _date=None):
    """Error codes for a notice row. A fee with a typed amount must be a
    non-negative number; a dated type with junk in the date field is flagged.
    We do NOT force a date — a dateless exam/ptm/event is allowed (honest 'no
    date yet'), it just won't appear in upcoming/overdue."""
    errs = []
    if not (title or "").strip():
        errs.append("title_required")
    t = ntype or "other"
    if t not in VALID_TYPES:
        errs.append("bad_type")
        return errs
    if t == "fee" and amount not in (None, ""):
        try:
            if float(str(amount).replace(",", "")) < 0:
                errs.append("amount_negative")
        except (TypeError, ValueError):
            errs.append("amount_invalid")
    if _date not in (None, "") and _parse_date(_date) is None:
        errs.append("date_invalid")
    return errs
