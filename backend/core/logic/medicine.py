"""
Medicine & family-care logic (no AI key needed — pure local math).

Everything here is deterministic and unit-testable:
  - dose expansion (how many doses a schedule produces per day / over a range)
  - pill-count inventory + refill prediction
  - adherence % (taken vs scheduled) per window, per medicine + overall
  - missed-dose escalation ladder (reminder → re-remind → caregiver alert)
    wired to the Medicine follow-up fields, respecting quiet hours.

Kept free of Django imports where possible so it can be reasoned about
in isolation; the few model touches are late-bound inside functions.
"""
from datetime import date, datetime, time, timedelta


# ---------------------------------------------------------------------------
# dose semantics
# ---------------------------------------------------------------------------

def doses_per_day(times):
    """Number of scheduled doses in a day for a times list like ['08:00','20:00']."""
    return len([t for t in (times or []) if str(t).strip()])


def active_on(med_start, med_end, day):
    """Is the course active on `day` (inclusive of start/end)?"""
    if med_start and day < med_start:
        return False
    if med_end and day > med_end:
        return False
    return True


def scheduled_slots_for_day(times, med_start, med_end, day, prn=False):
    """Ordered list of HH:MM slots due on `day`. PRN (as-needed) medicines are
    never 'scheduled' — they produce an empty list so they don't hurt adherence."""
    if prn:
        return []
    if not active_on(med_start, med_end, day):
        return []
    return sorted(str(t).strip() for t in (times or []) if str(t).strip())


def course_days(med_start, med_end, today=None):
    """Remaining whole days of a fixed course (None if open-ended)."""
    if not med_end:
        return None
    today = today or date.today()
    if med_end < today:
        return 0
    return (med_end - today).days + 1


# ---------------------------------------------------------------------------
# inventory + refill prediction
# ---------------------------------------------------------------------------

def pills_per_dose(dose_qty):
    """How many units one dose consumes (defaults to 1)."""
    try:
        q = float(dose_qty)
        return q if q > 0 else 1.0
    except (TypeError, ValueError):
        return 1.0


def days_left(stock_count, times, dose_qty=1, prn=False, prn_per_day=0):
    """How many days the current `stock_count` units will last.
    Returns None when the daily burn is 0 (open-ended / no schedule)."""
    if stock_count is None:
        return None
    per_dose = pills_per_dose(dose_qty)
    if prn:
        daily = float(prn_per_day or 0) * per_dose
    else:
        daily = doses_per_day(times) * per_dose
    if daily <= 0:
        return None
    return int(float(stock_count) // daily)


def predicted_refill_date(stock_count, times, dose_qty=1, today=None,
                          prn=False, prn_per_day=0):
    """The day stock is expected to run out. None if it never will on current burn."""
    dl = days_left(stock_count, times, dose_qty, prn=prn, prn_per_day=prn_per_day)
    if dl is None:
        return None
    return (today or date.today()) + timedelta(days=dl)


def refill_warning(stock_count, times, dose_qty=1, warn_days=5, today=None,
                   prn=False, prn_per_day=0):
    """Return ('ok'|'soon'|'out', days_left) for an early low-stock warning."""
    dl = days_left(stock_count, times, dose_qty, prn=prn, prn_per_day=prn_per_day)
    if dl is None:
        return ("ok", None)
    if dl <= 0:
        return ("out", 0)
    if dl <= warn_days:
        return ("soon", dl)
    return ("ok", dl)


def apply_dose_to_stock(stock_count, dose_qty=1):
    """Decrement inventory when a dose is taken; never below 0.

    Handles FRACTIONAL doses (e.g. dose_qty=0.5): stock is tracked as a float
    so a half-pill dose decrements 0.5, not 0 (the old int(round(...)) bug).
    Returns a float; callers persist to a DecimalField (P6)."""
    if stock_count is None:
        return None
    rem = float(stock_count) - pills_per_dose(dose_qty)
    return max(0.0, rem)


def restore_dose_to_stock(stock_count, dose_qty=1):
    """Inverse of apply_dose_to_stock — add a dose's units back on undo.
    Fractional-safe. Returns a float."""
    if stock_count is None:
        return None
    return float(stock_count) + pills_per_dose(dose_qty)


# ---------------------------------------------------------------------------
# adherence
# ---------------------------------------------------------------------------

def _iter_days(start, end):
    d = start
    while d <= end:
        yield d
        d += timedelta(days=1)


def adherence(scheduled, taken):
    """Simple ratio helper → (percent_int, taken, scheduled)."""
    if scheduled <= 0:
        return (100, taken, scheduled)
    pct = int(round(100.0 * taken / scheduled))
    return (max(0, min(100, pct)), taken, scheduled)


def adherence_for_med(times, med_start, med_end, taken_set, window_start,
                      window_end, prn=False):
    """taken_set: set of (iso_date, 'HH:MM'). Counts only days inside the course
    AND the window. PRN medicines report doses taken but 0 scheduled → 100%."""
    scheduled = 0
    taken = 0
    for day in _iter_days(window_start, window_end):
        slots = scheduled_slots_for_day(times, med_start, med_end, day, prn=prn)
        scheduled += len(slots)
        for slot in slots:
            if (day.isoformat(), slot) in taken_set:
                taken += 1
    return adherence(scheduled, taken)


def streak_days(times, med_start, med_end, taken_set, today=None, lookback=60,
                prn=False):
    """Consecutive days (ending today) where every scheduled dose was taken.
    PRN meds have no scheduled doses → streak is always 0 (not meaningful)."""
    if prn:
        return 0
    today = today or date.today()
    streak = 0
    for i in range(lookback):
        day = today - timedelta(days=i)
        slots = scheduled_slots_for_day(times, med_start, med_end, day, prn=prn)
        if not slots:
            # no scheduled doses that day — doesn't break a streak, doesn't add
            if i == 0:
                continue
            continue
        if all((day.isoformat(), s) in taken_set for s in slots):
            streak += 1
        else:
            break
    return streak


# ---------------------------------------------------------------------------
# missed-dose escalation
# ---------------------------------------------------------------------------

def _hhmm(s):
    try:
        h, m = str(s).split(":")
        return time(int(h), int(m))
    except Exception:
        return None


def in_quiet_hours(now_t, quiet_start, quiet_end):
    """Is `now_t` (a time) inside the quiet window? Handles overnight wrap
    (e.g. 22:00 → 07:00). Empty window → never quiet."""
    qs, qe = _hhmm(quiet_start), _hhmm(quiet_end)
    if not qs or not qe:
        return False
    if qs <= qe:
        return qs <= now_t < qe
    # overnight wrap
    return now_t >= qs or now_t < qe


def escalation_plan(slot, followup_repeat_min, followup_retries,
                    caregiver_alert_min, quiet_start="", quiet_end="",
                    base_day=None):
    """Produce the timed ladder of notifications for ONE missed dose.

    reminder at T (dose time) →
      re-remind every `followup_repeat_min` for `followup_retries` times →
      caregiver alert at T + `caregiver_alert_min`.
    Any event landing in quiet hours is marked suppressed=True (the caller
    defers it to quiet_end rather than waking the person at night).

    Returns a list of dicts: {kind, at (datetime), suppressed}.
    """
    base_day = base_day or date.today()
    t0 = _hhmm(slot)
    if not t0:
        return []
    start = datetime.combine(base_day, t0)
    events = [{"kind": "reminder", "at": start}]
    for i in range(1, int(followup_retries or 0) + 1):
        events.append({
            "kind": "reremind",
            "at": start + timedelta(minutes=int(followup_repeat_min or 0) * i),
        })
    if caregiver_alert_min and int(caregiver_alert_min) > 0:
        events.append({
            "kind": "caregiver_alert",
            "at": start + timedelta(minutes=int(caregiver_alert_min)),
        })
    for e in events:
        e["suppressed"] = in_quiet_hours(e["at"].time(), quiet_start, quiet_end)
    return events


def next_escalation_action(events, now, acknowledged=False):
    """Given a computed plan and the current time, what should fire next?

    Returns the earliest non-suppressed event whose time <= now and which
    hasn't been superseded, or None. Caregiver alert only fires if the dose
    is still not acknowledged.
    """
    if acknowledged:
        return None
    due = [e for e in events if not e["suppressed"] and e["at"] <= now]
    if not due:
        return None
    return due[-1]  # latest step reached
