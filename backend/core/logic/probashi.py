"""
probashi.py — pure, deterministic PROBASHI CORNER math (#191, SPEC v2.1 §20,
built to the §21 "advanced" standard) for Bangladeshis living abroad.

Three deterministic tools, no money held, no live clock:

  1. REMITTANCE LOG — each time you send money home, you record the amount you
     SENT (in the foreign currency), the exchange RATE, and the date; we compute
     the BDT RECEIVED and running totals (total sent, total BDT, average rate).
     Money is NEVER moved or held — this is a record book you keep yourself.

  2. TIME-ZONE PAIR — given a stored UTC offset for "home" (Bangladesh, +6:00)
     and for "abroad", and a single passed-in UTC instant (`now`), we render
     BOTH local clock times side by side. DETERMINISTIC: the only time input is
     the `now` the caller passes; we never read the system clock here, so the
     tests can pin it and the Dart mirror is identical offline.

  3. DOCUMENTS CHECKLIST — passport / visa / air-ticket etc. with an expiry
     date; given a passed-in "today", we compute days-until-expiry and a status
     (valid / expiring-soon / expired). The reminder SEAM (push/email N days
     before) is DOCUMENTED here but NOT wired — no scheduler, no notification is
     sent by this module.

HARD RULES (identical to the money modules' discipline):

  * ALL MONEY IS INTEGER POISHA for BDT (1 BDT = 100 poisha); the foreign
    "amount sent" is kept in integer minor units (1 unit = 100 subunits, e.g.
    cents). The rate is a decimal BDT-per-foreign-unit; BDT received is computed
    exactly and rounded ONCE to the nearest poisha. No float drift accumulates
    because each row is rounded independently and totals add the rounded poisha.
  * NO DB, NO AI, NO I/O, NO LIVE CLOCK, NO MONEY-HOLDING. `now` / `today` are
    always PASSED IN. Returns plain dicts; the view persists rows in a flexible
    per-user JSON collection.
  * Human-facing copy is bilingual {"bn","en"} so the Dart layer shows it
    directly and keeps ZERO Bangla in .dart.

Run self-tests (no DB):
    python3 -c "import core.logic.probashi_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# money helpers — integer minor units, no float drift
# ---------------------------------------------------------------------------

def to_minor(v):
    """Coerce an amount-ish string to INTEGER MINOR UNITS (×100). Junk -> 0.
    Works for both the foreign amount (cents) and BDT (poisha)."""
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
        major = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    minor = major * 100 + milli // 10
    if milli % 10 >= 5:
        minor += 1
    return -minor if neg else minor


def _group(n):
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


def fmt_bdt(poisha):
    """Format integer poisha as a ৳ amount string (always 2 dp)."""
    p = int(poisha)
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


def fmt_minor(minor):
    """Format integer minor units as a plain 2-dp number (no currency sign) —
    for the foreign 'amount sent', whose symbol/label the UI supplies."""
    m = int(minor)
    neg = m < 0
    m = abs(m)
    major, sub = divmod(m, 100)
    return ("-" if neg else "") + f"{_group(major)}.{sub:02d}"


def parse_rate(v):
    """Parse a BDT-per-foreign-unit rate to a float >= 0. Junk -> 0.0."""
    if v is None or v == "":
        return 0.0
    try:
        r = float(str(v).strip().replace(",", ""))
    except ValueError:
        return 0.0
    return r if r >= 0 else 0.0


# ---------------------------------------------------------------------------
# 1. remittance log
# ---------------------------------------------------------------------------

def bdt_received(amount_minor, rate):
    """BDT received (INTEGER POISHA) for `amount_minor` foreign minor units at
    `rate` BDT per foreign unit. Rounded ONCE to nearest poisha.
        poisha = amount_minor(/100 foreign units) × rate(BDT/unit) × 100
               = amount_minor × rate
    (the ×100 for cents->units cancels the ×100 for BDT->poisha). Pure int+round.
    """
    r = parse_rate(rate)
    exact = int(amount_minor) * r  # already in poisha, see docstring
    # round half up, sign-aware
    if exact >= 0:
        return int(exact + 0.5)
    return -int(-exact + 0.5)


def validate_remittance(row):
    """Validation codes for a remittance entry before storing."""
    problems = []
    if to_minor(row.get("amount")) <= 0:
        problems.append("amount_required")
    if parse_rate(row.get("rate")) <= 0:
        problems.append("rate_required")
    if not str(row.get("date") or "").strip():
        problems.append("date_required")
    return problems


def remittance_summary(rows, lang="bn"):
    """Totals over a remittance log.

    rows: [{'amount','rate','date','currency'?,'note'?}] — amount is foreign,
    rate is BDT/unit. Returns per-row computed BDT plus totals:
        {
          'rows': [{...row, 'amount_minor','amount_display','rate',
                    'bdt','bdt_display'}],
          'count','total_sent_minor','total_bdt','total_bdt_display',
          'avg_rate','avg_rate_display','note':{bn,en}
        }
    'avg_rate' is the BDT-weighted average (total BDT ÷ total foreign units),
    the honest effective rate across all your transfers.
    """
    out_rows = []
    total_minor = 0
    total_bdt = 0
    for r in rows:
        amt = to_minor(r.get("amount"))
        rate = parse_rate(r.get("rate"))
        bdt = bdt_received(amt, rate)
        total_minor += amt
        total_bdt += bdt
        row = dict(r)
        row.update({
            "amount_minor": amt,
            "amount_display": fmt_minor(amt),
            "rate": rate,
            "bdt": bdt,
            "bdt_display": fmt_bdt(bdt),
        })
        out_rows.append(row)
    # effective rate = total BDT (taka) ÷ total foreign (units)
    avg = (total_bdt / total_minor) if total_minor else 0.0  # poisha/cent = BDT/unit
    return {
        "rows": out_rows,
        "count": len(out_rows),
        "total_sent_minor": total_minor,
        "total_sent_display": fmt_minor(total_minor),
        "total_bdt": total_bdt,
        "total_bdt_display": fmt_bdt(total_bdt),
        "avg_rate": avg,
        "avg_rate_display": f"{avg:.2f}",
        "note": {
            "bn": "অ্যাপ কোনো টাকা পাঠায় না বা রাখে না — এটি শুধু আপনার পাঠানো "
                  "টাকার হিসাব রাখে। রেট আপনি নিজে লেখেন।",
            "en": "The app sends and holds no money — it only keeps a record of "
                  "what you sent. You enter the rate yourself.",
        },
    }


# ---------------------------------------------------------------------------
# 2. time-zone pair (deterministic from a passed-in instant)
# ---------------------------------------------------------------------------

# Bangladesh is always UTC+6:00 (no DST).
HOME_OFFSET_MIN = 6 * 60


def parse_offset(v):
    """Parse a UTC offset to INTEGER MINUTES. Accepts an int/float of minutes,
    or a string like '+6', '+6:00', '-3:30', '5.5'. Junk -> 0 (UTC)."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, (int, float)):
        # treat small magnitudes as HOURS, large as MINUTES
        return int(round(v * 60)) if abs(v) <= 14 else int(v)
    s = str(v).strip().replace("UTC", "").replace("GMT", "").strip()
    neg = s.startswith("-")
    if s and s[0] in "+-":
        s = s[1:]
    if ":" in s:
        h, m = (s.split(":", 1) + ["0"])[:2]
        try:
            mins = int(h) * 60 + int(m or 0)
        except ValueError:
            mins = 0
    elif "." in s:
        try:
            mins = int(round(float(s) * 60))
        except ValueError:
            mins = 0
    else:
        try:
            mins = int(s) * 60
        except ValueError:
            mins = 0
    return -mins if neg else mins


def _fmt_offset(mins):
    """Minutes -> 'UTC+6:00' style label."""
    sign = "-" if mins < 0 else "+"
    mins = abs(int(mins))
    return f"UTC{sign}{mins // 60}:{mins % 60:02d}"


def _local(now_utc, offset_min):
    """Apply an integer-minute offset to a UTC instant -> naive local datetime."""
    return now_utc + timedelta(minutes=offset_min)


def _as_utc(now):
    """Normalise `now` to an aware UTC datetime. Accepts an aware/naive datetime
    (naive assumed UTC) or an ISO string."""
    if isinstance(now, datetime):
        dt = now
    else:
        dt = datetime.fromisoformat(str(now))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def timezone_pair(now, abroad_offset, home_offset=HOME_OFFSET_MIN,
                  abroad_label="", home_label=""):
    """Render BOTH clocks for a single passed-in UTC instant `now`.

    now           : aware/naive datetime (UTC) or ISO string — the ONLY time in.
    abroad_offset : the expat's local UTC offset (string/number -> parse_offset).
    home_offset   : Bangladesh, default +6:00.
    *_label       : free-text city/zone labels the UI supplies (not localised
                    here; may be empty).

    Deterministic — same `now` + offsets always give the same strings. Returns:
        {
          'home':   {'label','offset_min','offset_display','time','date',
                     'weekday_idx','minutes_of_day'},
          'abroad': {...same...},
          'diff_min','diff_display':{bn,en},'ahead':'home'|'abroad'|'same'
        }
    Times are 24-hour 'HH:MM'; `weekday_idx` 0=Mon..6=Sun; `date` is ISO so the
    UI can localise/format and show "+1 day" style hints itself.
    """
    utc = _as_utc(now)
    ab_off = parse_offset(abroad_offset)
    hm_off = parse_offset(home_offset)
    ab = _local(utc, ab_off)
    hm = _local(utc, hm_off)

    def block(local_dt, off, label):
        return {
            "label": label or "",
            "offset_min": off,
            "offset_display": _fmt_offset(off),
            "time": local_dt.strftime("%H:%M"),
            "date": local_dt.strftime("%Y-%m-%d"),
            "weekday_idx": local_dt.weekday(),
            "minutes_of_day": local_dt.hour * 60 + local_dt.minute,
        }

    diff = hm_off - ab_off  # home is this many minutes ahead of abroad
    if diff > 0:
        ahead = "home"
    elif diff < 0:
        ahead = "abroad"
    else:
        ahead = "same"
    d = abs(diff)
    dh, dm = divmod(d, 60)
    hhmm = f"{dh}:{dm:02d}" if dm else f"{dh}"
    return {
        "home": block(hm, hm_off, home_label),
        "abroad": block(ab, ab_off, abroad_label),
        "diff_min": diff,
        "ahead": ahead,
        "diff_display": {
            "bn": "একই সময়" if ahead == "same"
                  else (f"বাংলাদেশ {hhmm} ঘণ্টা এগিয়ে" if ahead == "home"
                        else f"বাংলাদেশ {hhmm} ঘণ্টা পিছিয়ে"),
            "en": "Same time" if ahead == "same"
                  else (f"Bangladesh is {hhmm}h ahead" if ahead == "home"
                        else f"Bangladesh is {hhmm}h behind"),
        },
    }


# ---------------------------------------------------------------------------
# 3. documents checklist — expiry from a passed-in `today`
# ---------------------------------------------------------------------------

# Known document kinds (stable keys; UI label localised by key).
DOC_KINDS = ("passport", "visa", "ticket", "nid", "work_permit", "insurance",
             "other")

# A document is "expiring soon" within this many days (default reminder window).
DEFAULT_WARN_DAYS = 90


def _as_date(v):
    """Normalise to a date. Accepts a date/datetime or 'YYYY-MM-DD'. Bad -> None."""
    if v is None or v == "":
        return None
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    try:
        return date.fromisoformat(str(v)[:10])
    except ValueError:
        return None


def doc_status(expiry, today, warn_days=DEFAULT_WARN_DAYS):
    """Status of one document given its expiry and a passed-in `today`.

    Returns {'days_left','status','warn_days'} where status is one of
    'expired' | 'expiring' | 'valid' | 'no_date'. `days_left` is None when no
    expiry is set; negative means already expired."""
    exp = _as_date(expiry)
    td = _as_date(today)
    if exp is None or td is None:
        return {"days_left": None, "status": "no_date", "warn_days": warn_days}
    days = (exp - td).days
    if days < 0:
        status = "expired"
    elif days <= warn_days:
        status = "expiring"
    else:
        status = "valid"
    return {"days_left": days, "status": status, "warn_days": warn_days}


def docs_overview(rows, today, warn_days=DEFAULT_WARN_DAYS, lang="bn"):
    """Compute status for a whole document checklist and sort the most urgent
    first (expired, then soonest expiry, then undated).

    rows: [{'kind','label'?,'number'?,'expiry'?}] ; `today` is passed in.
    Returns {'rows':[{...row, 'days_left','status'}], 'counts':{expired,
    expiring,valid,no_date}, 'next_expiry':row|None, 'note':{bn,en}}.

    REMINDER SEAM (documented, NOT wired): a scheduler could, each day, call
    doc_status(expiry, today) for every row and enqueue a push/email when
    status flips to 'expiring' (days_left == warn_days) and again at 7/1 days.
    This module computes the status only; nothing here schedules or sends.
    """
    out = []
    counts = {"expired": 0, "expiring": 0, "valid": 0, "no_date": 0}
    for r in rows:
        st = doc_status(r.get("expiry"), today, warn_days)
        row = dict(r)
        row.update(st)
        counts[st["status"]] += 1
        out.append(row)

    def sort_key(r):
        # expired/expiring/valid by days_left; undated last
        dl = r.get("days_left")
        if dl is None:
            return (2, 0)
        return (0 if dl < 0 else 1, dl)

    out.sort(key=sort_key)
    next_exp = next((r for r in out if r.get("days_left") is not None), None)
    return {
        "rows": out,
        "counts": counts,
        "next_expiry": next_exp,
        "warn_days": warn_days,
        "note": {
            "bn": "মেয়াদের তারিখ আপনি লেখেন; অ্যাপ শুধু কত দিন বাকি তা দেখায়। "
                  "স্বয়ংক্রিয় রিমাইন্ডার এখনো চালু নয়।",
            "en": "You enter the expiry dates; the app only shows the days left. "
                  "Automatic reminders are not wired yet.",
        },
    }
