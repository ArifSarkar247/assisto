"""
day_planner.py — the deterministic engine behind the AI DAILY PLANNER
(owner PART 2, flag `ai_daily_planner`, OFF until proven).

Builds TODAY's time-blocked plan from the user's OWN data that other modules
already keep — it stores nothing new:
  * meetings  — PA schedule slots (Personal Secretary), fixed in time;
  * reminders — Reminder rows due today, fixed 15-minute markers;
  * prayers   — optional, the same sun-math as Unseen World / Ramadan
                (core.logic.ramadan.prayer_times), 20-minute protected blocks;
  * tasks     — Task Manager rows that matter today (overdue, due today,
                urgent/high, already "doing"), placed into the free gaps in
                priority order, each for its own estimate (default 30 min);
  * bills     — due today / overdue lines from the PS bills section.

PURE: no Django, no DB, no network, no clock (`now` is passed in), no AI.
The optional AI polish (views) only writes advice text ON TOP of this plan;
it never moves a block. Times are naive LOCAL datetimes.
"""
from __future__ import annotations

from datetime import datetime, timedelta

from . import task_manager as TM

REMINDER_MIN = 15
PRAYER_MIN = 20
PRAYERS = ("fajr", "dhuhr", "asr", "maghrib", "isha")
PRAYER_NAMES = {
    "fajr": ("ফজর", "Fajr"), "dhuhr": ("যোহর", "Dhuhr"), "asr": ("আসর", "Asr"),
    "maghrib": ("মাগরিব", "Maghrib"), "isha": ("এশা", "Isha"),
}
DEFAULT_START = "08:00"
DEFAULT_END = "22:00"
MAX_TASKS = 40
MAX_MEETING_MIN = 12 * 60
STEP_MIN = 5          # tasks start on a 5-minute grid

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn(n):
    return str(n).translate(_BN)


def _hhmm_ok(s):
    try:
        h, m = str(s).split(":")
        h, m = int(h), int(m)
        return 0 <= h <= 23 and 0 <= m <= 59
    except (ValueError, TypeError):
        return False


def clean_prefs(p):
    """{day_start, day_end, prayer} with safe defaults; end must be after start."""
    p = dict(p or {})
    st = p.get("day_start") if _hhmm_ok(p.get("day_start")) else DEFAULT_START
    en = p.get("day_end") if _hhmm_ok(p.get("day_end")) else DEFAULT_END
    if _mins(en) <= _mins(st):
        st, en = DEFAULT_START, DEFAULT_END
    return {"day_start": st, "day_end": en, "prayer": bool(p.get("prayer"))}


def _mins(hhmm):
    h, m = str(hhmm).split(":")
    return int(h) * 60 + int(m)


def _at(day, hhmm):
    return datetime(day.year, day.month, day.day) + timedelta(minutes=_mins(hhmm))


def _ceil_step(dt):
    dt = dt.replace(second=0, microsecond=0)
    r = dt.minute % STEP_MIN
    return dt + timedelta(minutes=(STEP_MIN - r) % STEP_MIN)


def _hm(dt):
    return "%02d:%02d" % (dt.hour, dt.minute)


def _naive(v):
    if isinstance(v, datetime):
        return v.replace(tzinfo=None)
    d = TM._parse(v)
    return d.replace(tzinfo=None) if d else None


# ------------------------------------------------------------ task picking

def todays_tasks(tasks, now):
    """Open tasks that belong in today's plan, in plan order:
    overdue -> doing -> urgent -> high -> due today (by due time) -> rest.
    Done tasks and tasks due on a later day (non-urgent) are left out."""
    end_of_day = datetime(now.year, now.month, now.day) + timedelta(days=1)
    picked = []
    for t in (TM.normalize_task(x) for x in (tasks or [])):
        if t["status"] == TM.STATUS_DONE or not t["title"]:
            continue
        due = _naive(t["due"])
        overdue = due is not None and due < now
        due_today = due is not None and due < end_of_day
        hot = t["priority"] in (TM.PRIORITY_URGENT, TM.PRIORITY_HIGH)
        if not (overdue or due_today or hot or t["status"] == TM.STATUS_DOING):
            continue
        if due is not None and not due_today and t["priority"] != TM.PRIORITY_URGENT:
            continue   # high but due another day -> not today's job
        rank = (0 if overdue else 1 if t["status"] == TM.STATUS_DOING
                else 2 if t["priority"] == TM.PRIORITY_URGENT
                else 3 if t["priority"] == TM.PRIORITY_HIGH else 4)
        picked.append((rank, due or end_of_day, t.get("id") or 0, t, overdue))
    picked.sort(key=lambda r: (r[0], r[1], r[2]))
    return [(r[3], r[4]) for r in picked[:MAX_TASKS]]


# ------------------------------------------------------------------ build

def build(now, prefs=None, meetings=(), reminders=(), tasks=(), bills=(),
          prayer_times=None):
    """Return the plan dict:

    {date, window:{start,end}, blocks:[{start,end,kind,title,src,past,clash,
     overdue,priority}], unscheduled:[{title,minutes,src,priority}],
     bills:[{bn,en,src}], free_min, counts:{...}, tips:[{bn,en}], empty}
    """
    now = now.replace(tzinfo=None, second=0, microsecond=0)
    p = clean_prefs(prefs)
    day = now.date()
    w0, w1 = _at(day, p["day_start"]), _at(day, p["day_end"])
    blocks, busy = [], []

    # meetings (fixed)
    for m in meetings or ():
        st = _naive(m.get("start"))
        if st is None or st.date() != day:
            continue
        try:
            dur = int(m.get("duration_min") or 60)
        except (TypeError, ValueError):
            dur = 60
        dur = max(5, min(MAX_MEETING_MIN, dur))
        en = st + timedelta(minutes=dur)
        blocks.append({"start": st, "end": en, "kind": "meeting",
                       "title": str(m.get("title") or "").strip(),
                       "src": {"kind": "schedule", "id": m.get("id")}})
        busy.append((st, en))

    # reminders (fixed markers)
    for r in reminders or ():
        st = _naive(r.get("due_at"))
        if st is None or st.date() != day:
            continue
        en = st + timedelta(minutes=REMINDER_MIN)
        blocks.append({"start": st, "end": en, "kind": "reminder",
                       "title": str(r.get("title") or "").strip(),
                       "src": {"kind": "reminder", "id": r.get("id")}})
        busy.append((st, en))

    # prayers (protected)
    if p["prayer"] and prayer_times:
        for key in PRAYERS:
            hm = prayer_times.get(key)
            if not _hhmm_ok(hm):
                continue
            st = _at(day, hm)
            en = st + timedelta(minutes=PRAYER_MIN)
            nb, ne = PRAYER_NAMES[key]
            blocks.append({"start": st, "end": en, "kind": "prayer",
                           "title": ne, "title_bn": nb, "title_en": ne,
                           "src": {"kind": "prayer", "id": key}})
            busy.append((st, en))

    # meeting clashes (honest flag, never silently moved)
    meets = [b for b in blocks if b["kind"] == "meeting"]
    for i, a in enumerate(meets):
        for b in meets[i + 1:]:
            if a["start"] < b["end"] and b["start"] < a["end"]:
                a["clash"] = b["clash"] = True

    # free gaps from max(window start, now) to window end
    cursor = _ceil_step(max(w0, now))
    gaps = _free_gaps(cursor, w1, busy)

    unscheduled = []
    picked = todays_tasks(tasks, now)
    for t, overdue in picked:
        need = t["est_min"] or TM.DEFAULT_EST_MIN
        slot = None
        for gi, (g0, g1) in enumerate(gaps):
            if (g1 - g0).total_seconds() / 60 >= need:
                slot = gi
                break
        src = {"kind": "task", "id": t.get("id"), "project_id": t.get("project_id")}
        if slot is None:
            unscheduled.append({"title": t["title"], "minutes": need, "src": src,
                                "priority": t["priority"], "overdue": overdue})
            continue
        g0, g1 = gaps[slot]
        st, en = g0, g0 + timedelta(minutes=need)
        blocks.append({"start": st, "end": en, "kind": "task", "title": t["title"],
                       "src": src, "priority": t["priority"], "overdue": overdue})
        nxt = _ceil_step(en)
        gaps[slot] = (nxt, g1) if nxt < g1 else None
        gaps = [g for g in gaps if g]

    blocks.sort(key=lambda b: (b["start"], b["end"]))
    free_min = int(sum((g1 - g0).total_seconds() // 60 for g0, g1 in gaps))
    out_blocks = []
    for b in blocks:
        ob = dict(b)
        ob["start"], ob["end"] = _hm(b["start"]), _hm(b["end"])
        ob["past"] = b["end"] <= now
        ob.setdefault("clash", False)
        ob.setdefault("overdue", False)
        out_blocks.append(ob)

    counts = {
        "meetings": sum(1 for b in blocks if b["kind"] == "meeting"),
        "reminders": sum(1 for b in blocks if b["kind"] == "reminder"),
        "prayers": sum(1 for b in blocks if b["kind"] == "prayer"),
        "tasks_planned": sum(1 for b in blocks if b["kind"] == "task"),
        "tasks_unscheduled": len(unscheduled),
        "bills": len(bills or ()),
    }
    plan = {
        "date": day.isoformat(),
        "window": {"start": p["day_start"], "end": p["day_end"]},
        "prayer": p["prayer"],
        "blocks": out_blocks,
        "unscheduled": unscheduled,
        "bills": list(bills or ())[:6],
        "free_min": free_min,
        "counts": counts,
        "empty": not out_blocks and not unscheduled and not bills,
    }
    plan["tips"] = tips(plan)
    return plan


def _free_gaps(start, end, busy):
    """Sorted free intervals in [start, end) not covered by `busy`."""
    if start >= end:
        return []
    spans = sorted((max(a, start), min(b, end)) for a, b in busy
                   if b > start and a < end)
    gaps, cur = [], start
    for a, b in spans:
        if a > cur:
            gaps.append((cur, a))
        cur = max(cur, b)
    if cur < end:
        gaps.append((cur, end))
    # tasks start on the grid
    out = []
    for a, b in gaps:
        a = _ceil_step(a)
        if b - a >= timedelta(minutes=STEP_MIN):
            out.append((a, b))
    return out


def tips(plan):
    """Template advice (no AI) — always present, bn+en, Bangla digits in bn."""
    c = plan["counts"]
    out = []
    first = next((b for b in plan["blocks"] if b["kind"] == "task" and not b["past"]), None)
    if first:
        out.append({"bn": "প্রথম কাজ %s-এ: %s" % (bn(first["start"]), first["title"]),
                    "en": "First task at %s: %s" % (first["start"], first["title"])})
    od = sum(1 for b in plan["blocks"] if b.get("overdue")) + \
        sum(1 for u in plan["unscheduled"] if u.get("overdue"))
    if od:
        out.append({"bn": "%sটি কাজের মেয়াদ পেরিয়েছে — আগে রাখা হয়েছে।" % bn(od),
                    "en": "%d overdue task(s) are placed first." % od})
    if c["tasks_unscheduled"]:
        n = c["tasks_unscheduled"]
        out.append({"bn": "%sটি কাজ আজ আঁটছে না — অন্য দিনে সরান বা সময় কমান।" % bn(n),
                    "en": "%d task(s) don't fit today — move them or shorten them." % n})
    if any(b.get("clash") for b in plan["blocks"]):
        out.append({"bn": "দুটি মিটিং একই সময়ে পড়েছে — একটি সরান।",
                    "en": "Two meetings overlap — move one."})
    if c["bills"]:
        out.append({"bn": "আজ %sটি বিল/দেনা দেখুন।" % bn(c["bills"]),
                    "en": "Check %d bill(s)/due(s) today." % c["bills"]})
    if plan["free_min"] >= 60 and not c["tasks_unscheduled"]:
        h, m = divmod(plan["free_min"], 60)
        out.append({"bn": "আজ আরও প্রায় %s ঘণ্টা %s মিনিট ফাঁকা।" % (bn(h), bn(m)),
                    "en": "About %dh %dm still free today." % (h, m)})
    return out[:5]


def ai_data(plan):
    """Compact, PII-light text of the plan for the AI polish (goes in the
    router's DATA fence). Titles only — no ids, no phone numbers."""
    lines = ["date %s window %s-%s" % (plan["date"], plan["window"]["start"],
                                       plan["window"]["end"])]
    for b in plan["blocks"]:
        lines.append("%s-%s %s%s %s" % (b["start"], b["end"], b["kind"],
                                        "(" + b["priority"] + ")" if b.get("priority") else "",
                                        b.get("title_en") or b["title"]))
    for u in plan["unscheduled"]:
        lines.append("does-not-fit %smin %s" % (u["minutes"], u["title"]))
    for bl in plan["bills"]:
        lines.append("bill %s" % bl.get("en", ""))
    return "\n".join(lines)[:4000]
