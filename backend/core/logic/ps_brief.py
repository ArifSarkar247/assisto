"""
ps_brief.py — Personal Secretary (PS) "Today" brief (owner Part 2.1, 2 Nov).

PURE (no Django, no DB, no network, no AI, no hidden clock). Builds the PS
day page from the user's OWN rows only:

  * schedule slots   (PaCollectionItem collection='schedule'; `start` is the
                      phone's LOCAL naive ISO time, as the schedule screen saves)
  * follow-ups       (collection='followups'; `due_at` is UTC ISO, see
                      pa_liaison._to_epoch)
  * reminders        ({id, title, due_at(local naive datetime)} dicts)

Every line carries `src` = {"kind", "id"} so the app can open the exact row
it came from — nothing is invented, nothing summarised by a model. Text is a
bn/en template pair (works with no AI key).
"""
from datetime import datetime, timedelta, timezone

from . import pa_liaison as LIA
from . import pa_schedule as SCH

_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
SOON_DAYS = LIA.DUE_SOON_DAYS
MAX_LINES = 8


def bn(n):
    return str(n).translate(_BN_DIGITS)


def _hm(dt, lang):
    """12-hour clock in the user's words: '৪:০০ বিকেল' / '4:00 pm'."""
    h, m = dt.hour, dt.minute
    h12 = h % 12 or 12
    if lang == "bn":
        part = ("রাত" if h < 4 else "ভোর" if h < 6 else "সকাল" if h < 12
                else "দুপুর" if h < 15 else "বিকেল" if h < 18
                else "সন্ধ্যা" if h < 20 else "রাত")
        return "%s %s:%s" % (part, bn(h12), bn("%02d" % m))
    return "%d:%02d %s" % (h12, m, "am" if h < 12 else "pm")


def _people(slot):
    return [p for p in SCH.clean_people(slot.get("people"))][:4]


def _circle_ids(row):
    out = []
    for v in (row.get("circle_ids") or []):
        try:
            out.append(int(v))
        except (TypeError, ValueError):
            continue
    return out


def _circle(row):
    """My Circle people picked on the row: [{"id": int, "name": str}]."""
    out = []
    for p in (row.get("circle_people") or []):
        if not isinstance(p, dict):
            continue
        try:
            out.append({"id": int(p.get("id")), "name": str(p.get("name") or "").strip()})
        except (TypeError, ValueError):
            continue
    return out[:8]


def _line(bn_text, en_text, kind, rid, **extra):
    d = {"bn": bn_text, "en": en_text, "src": {"kind": kind, "id": rid}}
    d.update(extra)
    return d


def _sec(key, title_bn, title_en, lines):
    return {"key": key, "title_bn": title_bn, "title_en": title_en, "lines": lines}


def meetings_section(slots, now_local):
    """Today's active slots in start order + honest clash minutes.
    `now_local` is a NAIVE local datetime (the slots' own clock)."""
    day = SCH.agenda(slots, scope="day", anchor=now_local, now=now_local)
    items = day[0]["items"] if day else []
    clash_with = {}
    for c in SCH.conflicts(slots):
        clash_with.setdefault(c["a"], c["overlap_min"])
        clash_with.setdefault(c["b"], c["overlap_min"])
    lines = []
    for it in items[:MAX_LINES]:
        s, idx = it["slot"], it["index"]
        st = SCH._naive(SCH.parse_dt(s.get("start")))
        ppl = _people(s)
        place = str(s.get("place") or "").strip()
        tb = "%s — %s" % (_hm(st, "bn"), s.get("title", ""))
        te = "%s — %s" % (_hm(st, "en"), s.get("title", ""))
        if ppl:
            tb += " (%s)" % ", ".join(ppl)
            te += " (with %s)" % ", ".join(ppl)
        if place:
            tb += " · %s" % place
            te += " · %s" % place
        if idx in clash_with:
            tb += " ⚠ অন্য মিটিং-এর সাথে %s মিনিট সময় মিলে যায়" % bn(clash_with[idx])
            te += " ⚠ overlaps another slot by %d min" % clash_with[idx]
        lines.append(_line(tb, te, "schedule", s.get("id"),
                           start=st.isoformat(), people=ppl,
                           circle_ids=_circle_ids(s), circle=_circle(s),
                           done=SCH.clean_status(s.get("status")) == SCH.STATUS_DONE,
                           clash=idx in clash_with))
    nxt = SCH.next_up(slots, now=now_local)
    head = None
    if nxt["has_next"]:
        s = nxt["slot"]
        sd = SCH._naive(SCH.parse_dt(s.get("start")))
        if sd.date() == now_local.date():
            if nxt["in_progress"]:
                head = {"bn": "এখন চলছে: %s" % s.get("title", ""),
                        "en": "Now: %s" % s.get("title", "")}
            else:
                mins = nxt["minutes_until"]
                if mins < 60:
                    wb, we = "%s মিনিট পরে" % bn(mins), "in %d min" % mins
                elif mins % 60 == 0:
                    wb, we = "%s ঘণ্টা পরে" % bn(mins // 60), "in %dh" % (mins // 60)
                else:
                    wb = "%s ঘণ্টা %s মিনিট পরে" % (bn(mins // 60), bn(mins % 60))
                    we = "in %dh %dm" % (mins // 60, mins % 60)
                head = {"bn": "পরের মিটিং %s: %s" % (wb, s.get("title", "")),
                        "en": "Next %s: %s" % (we, s.get("title", ""))}
            head["src"] = {"kind": "schedule", "id": s.get("id")}
    return lines, head


def _due_local(f, tz):
    e = LIA._to_epoch(f.get("due_at"))
    if e is None:
        return None
    return datetime.fromtimestamp(e, tz).replace(tzinfo=None)


def followups_section(followups, now_local, tz=timezone.utc):
    """Open follow-ups that are overdue, due today, or due within SOON_DAYS
    CALENDAR days in the user's own timezone `tz` (due_at is stored UTC)."""
    today = now_local.date()
    rows = []
    for f in followups or []:
        if not LIA.is_open(f):
            continue
        due = _due_local(f, tz)
        if due is None:
            continue
        d = (due.date() - today).days
        if d > SOON_DAYS:
            continue
        rows.append((due, str(f.get("title") or ""), d, f))
    rows.sort(key=lambda r: (r[0], r[1]))
    lines = []
    for due, title, d, f in rows[:MAX_LINES]:
        who = str(f.get("counterpart") or "").strip()
        if due < now_local:
            state = "overdue"
            if d < 0:
                wb, we = "%s দিন পেরিয়েছে" % bn(-d), "%d day(s) overdue" % -d
            else:
                wb, we = "আজকের সময় পেরিয়েছে", "past due today"
        elif d == 0:
            wb, we, state = "আজ", "today", "today"
        else:
            wb, we, state = ("কাল" if d == 1 else "%s দিন পরে" % bn(d),
                             "tomorrow" if d == 1 else "in %d days" % d, "soon")
        waiting = f.get("status", LIA.STATUS_WAITING) == LIA.STATUS_WAITING
        lines.append(_line(
            "%s — %s (%s)%s" % (who, title, wb, "" if waiting else " · এবার আপনার পালা"),
            "%s — %s (%s)%s" % (who, title, we, "" if waiting else " · your move"),
            "followup", f.get("id"), state=state, counterpart=who,
            circle_ids=_circle_ids(f), circle=_circle(f)))
    return lines


def reminders_section(reminders, now_local):
    day0 = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
    day1 = day0 + timedelta(days=1)
    rows = []
    for r in reminders or []:
        due = r.get("due_at")
        if due is None:
            continue
        due = SCH._naive(due)
        if day0 <= due < day1:
            rows.append((due, r))
    rows.sort(key=lambda x: x[0])
    return [_line("%s — %s" % (_hm(due, "bn"), r.get("title", "")),
                  "%s — %s" % (_hm(due, "en"), r.get("title", "")),
                  "reminder", r.get("id"))
            for due, r in rows[:MAX_LINES]]


def build(slots, followups, reminders, now_local, tz=timezone.utc, extra_sections=()):
    """The PS Today page. `now_local` is the naive local time in `tz`."""
    secs = []
    m_lines, head = meetings_section(slots, now_local)
    if m_lines:
        secs.append(_sec("meetings", "আজকের মিটিং", "Today's meetings", m_lines))
    f_lines = followups_section(followups, now_local, tz)
    if f_lines:
        secs.append(_sec("followups", "ফলো-আপ", "Follow-ups", f_lines))
    r_lines = reminders_section(reminders, now_local)
    if r_lines:
        secs.append(_sec("reminders", "আজকের রিমাইন্ডার", "Today's reminders", r_lines))
    for s in extra_sections or ():
        if s and s.get("lines"):
            secs.append(s)
    overdue = sum(1 for l in f_lines if l.get("state") == "overdue")
    return {
        "date": now_local.date().isoformat(),
        "next": head,
        "sections": secs,
        "counts": {"meetings": len(m_lines), "followups": len(f_lines),
                   "overdue": overdue, "reminders": len(r_lines)},
        "empty": not secs,
        "ai_used": False,
    }


def proactive_lines(slots, followups, now_local, tz=timezone.utc):
    """Short lines for Agent Core's morning brief (meetings + overdue only)."""
    out = []
    m_lines, _ = meetings_section(slots, now_local)
    if m_lines:
        first = m_lines[0]
        out.append({"bn": "আজ %sটি মিটিং; প্রথমটি %s" % (bn(len(m_lines)), first["bn"]),
                    "en": "%d meeting(s) today; first: %s" % (len(m_lines), first["en"])})
    over = [l for l in followups_section(followups, now_local, tz) if l["state"] == "overdue"]
    if over:
        out.append({"bn": "%sটি ফলো-আপ দিন পেরিয়েছে: %s" % (
                        bn(len(over)), ", ".join(l["counterpart"] for l in over[:3])),
                    "en": "%d follow-up(s) overdue: %s" % (
                        len(over), ", ".join(l["counterpart"] for l in over[:3]))})
    return out
