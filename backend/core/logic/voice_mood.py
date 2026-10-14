"""
voice_mood.py — the deterministic, key-free engine behind Assisto's
VOICE MOOD SENSING wellness check-in (issue #15, SPEC v2.1 §21, ADVANCED).

WHAT THIS IS
    An OPT-IN, ON-DEVICE wellness check-in. The user self-reports a mood (and,
    optionally, a "voice energy" self-rating they give themselves after a short
    on-device recording that NEVER leaves the phone). From that we keep a
    deterministic mood log, compute a 7-day mood trend and surface gentle,
    NON-CLINICAL supportive suggestions.

    This module is PURE, exactly like `wellness_tracker.py` / `in_chat_ai.py`:
    no Django, no DB, no network, no clock (today is passed in), **no AI** and
    **no audio**. It only ever sees a mood label + an optional integer energy
    rating + a date string. Same inputs always give the same output, so the
    on-device Dart mirror produces identical results offline and tests can pin
    them.

PRIVACY — THE WHOLE POINT
    Nothing here touches audio. The feature is opt-in; the raw voice (if the
    user chooses to use the voice-energy helper at all) is processed on the
    device and discarded — only the user's OWN mood + energy number is kept.
    This engine is never asked to reach a server. The client may store rows in
    a generic per-user collection OR purely in on-device SharedPreferences
    (the privacy-forward default); either way a row is only {mood, energy, date}
    — there is NO audio, NO transcript, NO server inference.

NOT A MEDICAL / MENTAL-HEALTH SERVICE
    This NEVER diagnoses and NEVER scores "how mentally healthy you are". The
    suggestions are supportive, everyday, widely-published self-care nudges
    (rest, a short walk, reaching out to someone) — never clinical advice. When
    the recent trend looks persistently low we surface an HONEST, non-alarming
    pointer to reach a real professional / helpline (the UI localises a Bangla
    national mental-health helpline). We point to help; we never pretend to be
    help.

Run self-tests:
    python3 -c "import core.logic.voice_mood_tests_snippets as t; t.run_all()"
"""

# ---- moods ------------------------------------------------------------------
# Five neutral mood keys, ordered low→high. Seed English labels only; the UI
# localises them. Each carries a deterministic "score" used only for the trend
# average — NOT a clinical score, just an ordering so a 7-day line can be drawn.
MOODS = ("low", "down", "ok", "good", "great")

# score per mood (1..5). Deterministic ordinal; never surfaced as a diagnosis.
_MOOD_SCORE = {"low": 1, "down": 2, "ok": 3, "good": 4, "great": 5}

# Energy self-rating range the user may optionally give (after an on-device-only
# voice sample they rate themselves — or skip entirely). 0 means "not rated".
ENERGY_MIN = 0
ENERGY_MAX = 5

TREND_DAYS = 7

# A trend is "persistently low" (→ show the gentle helpline pointer) when, over
# the logged days in the window, the average mood score is at/below this AND at
# least this many days were actually logged (so one bad day never trips it).
_LOW_AVG_THRESHOLD = 2.0
_LOW_MIN_LOGGED = 3

# Supportive suggestion KEYS (UI localises to real bn/en copy). Never clinical.
# Keyed by mood bucket; the engine only ever returns keys, never prose.
SUGGESTION_KEYS = {
    "low":   ["rest", "reach_out", "breathe", "helpline"],
    "down":  ["walk", "reach_out", "breathe"],
    "ok":    ["walk", "gratitude"],
    "good":  ["keep_going", "gratitude"],
    "great": ["celebrate", "share"],
}

# Marker every result carries so callers stay honest: this is a self-reported,
# on-device, non-clinical check-in — not a measurement or a diagnosis.
MARKER_KEY = "mood_self_report"


# ---- helpers ----------------------------------------------------------------
def _date_key(v):
    """Normalise a date-ish value to 'YYYY-MM-DD' or None. No parsing of time."""
    s = str(v or "").strip()
    if not s:
        return None
    s = s.split("T")[0].split(" ")[0]
    parts = s.split("-")
    if len(parts) != 3:
        return None
    try:
        y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
    except ValueError:
        return None
    if not (1 <= m <= 12 and 1 <= d <= 31):
        return None
    return "%04d-%02d-%02d" % (y, m, d)


def _coerce_energy(v):
    """Clamp an optional energy self-rating into [ENERGY_MIN, ENERGY_MAX].
    Anything unparseable or missing becomes 0 ('not rated')."""
    try:
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return 0
    if n < ENERGY_MIN:
        return ENERGY_MIN
    if n > ENERGY_MAX:
        return ENERGY_MAX
    return n


def _day_index(iso):
    """Days-since-epoch ordinal for an ISO date (proleptic Gregorian) — lets us
    walk a window without importing datetime. Deterministic, pure arithmetic."""
    y, m, d = (int(x) for x in iso.split("-"))
    if m <= 2:
        y -= 1
        m += 12
    # days from a fixed reference using the standard civil-from-days inverse.
    era = (y if y >= 0 else y - 399) // 400
    yoe = y - era * 400
    doy = (153 * (m - 3) + 2) // 5 + d - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _iso_from_index(n):
    """Inverse of _day_index — ISO date string for a days-since-epoch ordinal."""
    z = n + 719468
    era = (z if z >= 0 else z - 146096) // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + 3 if mp < 10 else mp - 9
    if m <= 2:
        y += 1
    return "%04d-%02d-%02d" % (y, m, d)


# ---- validation -------------------------------------------------------------
def validate(mood, energy=0, date=""):
    """Return a list of problem KEYS (empty ⇒ valid). The UI localises these."""
    problems = []
    if mood not in MOODS:
        problems.append("bad_mood")
    if _date_key(date) is None:
        problems.append("bad_date")
    return problems


# ---- folding ----------------------------------------------------------------
def fold_by_day(rows):
    """Collapse raw log rows into one record per day (latest wins).

    `rows` is a list of dicts: {mood, energy?, date, id?}. We sort by id (then
    insertion order) so the newest entry for a day wins deterministically, and
    keep only {mood, energy, score} per day. Rows with an unknown mood or an
    unparseable date are skipped (never crash on bad input)."""
    indexed = list(enumerate(rows or []))

    def _key(pair):
        i, r = pair
        rid = r.get("id")
        rid = rid if isinstance(rid, int) else 10 ** 15
        return (rid, i)

    indexed.sort(key=_key)
    days = {}
    for _, r in indexed:
        mood = r.get("mood")
        if mood not in MOODS:
            continue
        iso = _date_key(r.get("date"))
        if iso is None:
            continue
        days[iso] = {
            "mood": mood,
            "energy": _coerce_energy(r.get("energy")),
            "score": _MOOD_SCORE[mood],
        }
    return days


# ---- trend ------------------------------------------------------------------
def trend(rows, today, days=TREND_DAYS):
    """7-day mood trend ending on `today` (ISO string).

    Returns a dict:
        days        — window length
        series      — [{date, logged, mood|None, energy, score}] oldest→newest
        logged_days — how many of the window days had a log
        avg_score   — mean mood score over logged days (0 if none), 2dp
        avg_energy  — mean energy over days with a non-zero rating (0 if none)
        low_streak  — count of trailing logged days at/below "down"
        persistently_low — bool: honest flag to show the helpline pointer
    All pure; `today` is passed in so there is no clock here.
    """
    t = _date_key(today)
    empty = {
        "days": days, "series": [], "logged_days": 0, "avg_score": 0.0,
        "avg_energy": 0.0, "low_streak": 0, "persistently_low": False,
    }
    if t is None:
        return empty
    folded = fold_by_day(rows)
    end = _day_index(t)
    start = end - (days - 1)
    series = []
    sum_score = 0
    logged = 0
    sum_energy = 0
    energy_days = 0
    for n in range(start, end + 1):
        iso = _iso_from_index(n)
        rec = folded.get(iso)
        if rec is None:
            series.append({"date": iso, "logged": False, "mood": None,
                           "energy": 0, "score": 0})
        else:
            series.append({"date": iso, "logged": True, "mood": rec["mood"],
                           "energy": rec["energy"], "score": rec["score"]})
            logged += 1
            sum_score += rec["score"]
            if rec["energy"] > 0:
                sum_energy += rec["energy"]
                energy_days += 1
    # trailing low streak (newest backwards, only consecutive logged days)
    low_streak = 0
    for item in reversed(series):
        if not item["logged"]:
            break
        if item["score"] <= _MOOD_SCORE["down"]:
            low_streak += 1
        else:
            break
    avg_score = round(sum_score / logged, 2) if logged else 0.0
    avg_energy = round(sum_energy / energy_days, 2) if energy_days else 0.0
    persistently_low = (logged >= _LOW_MIN_LOGGED
                        and avg_score <= _LOW_AVG_THRESHOLD)
    return {
        "days": days,
        "series": series,
        "logged_days": logged,
        "avg_score": avg_score,
        "avg_energy": avg_energy,
        "low_streak": low_streak,
        "persistently_low": persistently_low,
    }


# ---- suggestions ------------------------------------------------------------
def suggestions(mood, persistently_low=False):
    """Supportive, NON-CLINICAL suggestion KEYS for a mood. UI localises them.

    We always append 'helpline' when the recent trend is persistently low, even
    if the single mood is okay, so the gentle "reach real help" pointer is never
    missed — and we never surface it as alarming prose here (it's one key)."""
    keys = list(SUGGESTION_KEYS.get(mood, SUGGESTION_KEYS["ok"]))
    if persistently_low and "helpline" not in keys:
        keys.append("helpline")
    # de-dupe preserving order
    seen = set()
    return [k for k in keys if not (k in seen or seen.add(k))]


# ---- single entry (mirrors a check-in) --------------------------------------
def check_in(mood, energy=0, date="", rows=None, today=None):
    """Evaluate a single check-in against the existing log.

    Returns an honest result dict. If the input is invalid, returns
    `problems` (localised keys) and never crashes. Pure; `today` passed in.
    The caller persists the {mood, energy, date} row itself — this never
    touches storage."""
    problems = validate(mood, energy=energy, date=date)
    result = {
        "mood": mood,
        "energy": _coerce_energy(energy),
        "date": _date_key(date) or "",
        "marker": MARKER_KEY,
        "ai_required": False,
        "mock": False,          # this is the user's own self-report, not a mock
        "on_device": True,
        "problems": problems,
    }
    if problems:
        result["suggestions"] = []
        result["trend"] = None
        return result
    # include this check-in in the window so the trend reflects it immediately
    merged = list(rows or [])
    merged.append({"mood": mood, "energy": energy, "date": date, "id": 10 ** 15})
    tday = today or date
    tr = trend(merged, tday)
    result["trend"] = tr
    result["suggestions"] = suggestions(mood, tr.get("persistently_low", False))
    return result
