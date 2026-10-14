"""
ramadan.py — Assisto Ramadan mode logic (module-5 "Life").

Pure Python, deterministic, no AI key, unit-testable. Benchmarked against a
SAFE subset of Muslim Pro (prayer-time + Ramadan features only; no content we
can't license).

What lives here:
  - sehri (suhoor / imsak) and iftar times computed FROM LOCATION using a
    standard astronomical solar-position calculation.
      METHOD CITED: NOAA solar-position equations (equation of time + solar
      declination), converted to local solar hour-angle. Fajr/Isha use the
      "twilight depression angle" convention. The default angle set is the
      University of Islamic Sciences, Karachi (Fajr 18 deg, Isha 18 deg) which
      is widely used for Bangladesh; the Fiqh / asr convention and the angle set
      are configurable. Sehri ends at Fajr (dawn); Iftar is at Maghrib (sunset).
      These are ASTRONOMICAL estimates — the UI notes local committee/mosque
      times may differ slightly, and we never claim religious authority.
  - zakat: reuses core.finance.zakat when available (same 2.5% logic), with a
    pure fallback so this module self-tests without Django.
  - Eid salami (eidi) split helper + Eid greeting / salami card DRAFTS (bn/en),
    clearly user-editable text, never auto-sent.
  - Ramadan day countdown helper.

Wake-for-sehri IVR CALL is KEY-GATED (telephony/partner) and lives only as a
clearly-marked flag the integrator gates; this module just computes the time.
"""
import math
from datetime import datetime, timedelta, date


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# calculation-method presets (twilight depression angles, in degrees)
# ---------------------------------------------------------------------------

METHODS = {
    # name: (fajr_angle, isha_angle)
    "karachi": (18.0, 18.0),          # Univ. of Islamic Sciences, Karachi (BD default)
    "mwl": (18.0, 17.0),              # Muslim World League
    "isna": (15.0, 15.0),             # Islamic Society of North America
    "egypt": (19.5, 17.5),            # Egyptian General Authority
}
METHOD_DEFAULT = "karachi"

ASR_STANDARD = "standard"  # Shafi'i/Maliki/Hanbali: shadow = object length
ASR_HANAFI = "hanafi"      # Hanafi: shadow = 2x object length


# ---------------------------------------------------------------------------
# NOAA solar position -> local sun events
# ---------------------------------------------------------------------------

def _julian_day(d):
    """Julian day number at 00:00 UTC for a date."""
    y, m = d.year, d.month
    if m <= 2:
        y -= 1
        m += 12
    a = y // 100
    b = 2 - a + a // 4
    return (math.floor(365.25 * (y + 4716))
            + math.floor(30.6001 * (m + 1)) + d.day + b - 1524.5)


def _sun_declination_eqtime(d):
    """Return (declination_deg, equation_of_time_minutes) for a date (NOAA)."""
    jd = _julian_day(d)
    t = (jd - 2451545.0) / 36525.0  # Julian centuries from J2000
    # geometric mean longitude & anomaly of the sun
    l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360.0
    m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
    mrad = math.radians(m)
    e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
    c = ((1.914602 - t * (0.004817 + 0.000014 * t)) * math.sin(mrad)
         + (0.019993 - 0.000101 * t) * math.sin(2 * mrad)
         + 0.000289 * math.sin(3 * mrad))
    true_long = l0 + c
    omega = 125.04 - 1934.136 * t
    app_long = true_long - 0.00569 - 0.00478 * math.sin(math.radians(omega))
    # obliquity of the ecliptic
    seconds = 21.448 - t * (46.8150 + t * (0.00059 - t * 0.001813))
    eps0 = 23.0 + (26.0 + seconds / 60.0) / 60.0
    eps = eps0 + 0.00256 * math.cos(math.radians(omega))
    decl = math.degrees(math.asin(
        math.sin(math.radians(eps)) * math.sin(math.radians(app_long))))
    # equation of time (minutes)
    y = math.tan(math.radians(eps / 2.0)) ** 2
    l0r = math.radians(l0)
    eot = 4 * math.degrees(
        y * math.sin(2 * l0r)
        - 2 * e * math.sin(mrad)
        + 4 * e * y * math.sin(mrad) * math.cos(2 * l0r)
        - 0.5 * y * y * math.sin(4 * l0r)
        - 1.25 * e * e * math.sin(2 * mrad))
    return decl, eot


def _hour_angle(lat_deg, decl_deg, altitude_deg):
    """Hour angle (degrees) for the sun at a given altitude (depression angles
    pass negative altitude). Returns None if the sun never reaches it."""
    lat = math.radians(lat_deg)
    decl = math.radians(decl_deg)
    alt = math.radians(altitude_deg)
    cos_h = (math.sin(alt) - math.sin(lat) * math.sin(decl)) / (
        math.cos(lat) * math.cos(decl))
    if cos_h < -1 or cos_h > 1:
        return None
    return math.degrees(math.acos(cos_h))


def _event_time(d, lat, lng, tz_offset_hours, altitude_deg, morning):
    """Local clock time (HH:MM as float hours) for the sun at `altitude_deg`.

    morning=True -> before solar noon (dawn side); False -> after (dusk side).
    Returns float hours in [0,24) or None (polar / no event)."""
    decl, eot = _sun_declination_eqtime(d)
    ha = _hour_angle(lat, decl, altitude_deg)
    if ha is None:
        return None
    # solar noon in local time (hours)
    solar_noon = 12.0 - (lng / 15.0) - (eot / 60.0) + tz_offset_hours
    delta = ha / 15.0  # degrees -> hours
    t = solar_noon - delta if morning else solar_noon + delta
    return t % 24.0


def _hhmm(hours_float):
    if hours_float is None:
        return None
    total = int(round(hours_float * 60))
    total %= 24 * 60
    return f"{total // 60:02d}:{total % 60:02d}"


# standard altitudes
SUNRISE_ALT = -0.833   # includes refraction + solar radius
SUNSET_ALT = -0.833
MAGHRIB_ALT = -0.833


def prayer_times(d, lat, lng, tz_offset_hours=6.0, method=METHOD_DEFAULT,
                 asr=ASR_STANDARD):
    """All sun-based times for Ramadan mode on date `d` at a location.

    tz_offset_hours default +6 (Bangladesh). Returns HH:MM strings (local) with
    None where the event doesn't occur. Sehri ends at `fajr`; iftar is `maghrib`.
    """
    fajr_a, isha_a = METHODS.get(method, METHODS[METHOD_DEFAULT])
    decl, _ = _sun_declination_eqtime(d)
    fajr = _event_time(d, lat, lng, tz_offset_hours, -fajr_a, morning=True)
    sunrise = _event_time(d, lat, lng, tz_offset_hours, SUNRISE_ALT, morning=True)
    # dhuhr = solar noon; recompute cleanly:
    _, eot = _sun_declination_eqtime(d)
    dhuhr = (12.0 - (lng / 15.0) - (eot / 60.0) + tz_offset_hours) % 24.0
    # asr: shadow factor
    factor = 2.0 if asr == ASR_HANAFI else 1.0
    lat_r = math.radians(lat)
    decl_r = math.radians(decl)
    asr_alt = math.degrees(math.atan(
        1.0 / (factor + math.tan(abs(lat_r - decl_r)))))
    asr_t = _event_time(d, lat, lng, tz_offset_hours, asr_alt, morning=False)
    maghrib = _event_time(d, lat, lng, tz_offset_hours, MAGHRIB_ALT, morning=False)
    isha = _event_time(d, lat, lng, tz_offset_hours, -isha_a, morning=False)
    return {
        "date": d.isoformat(),
        "method": method,
        "asr_convention": asr,
        "sehri_end": _hhmm(fajr),   # stop eating at dawn (Fajr)
        "fajr": _hhmm(fajr),
        "sunrise": _hhmm(sunrise),
        "dhuhr": _hhmm(dhuhr),
        "asr": _hhmm(asr_t),
        "iftar": _hhmm(maghrib),    # break fast at sunset (Maghrib)
        "maghrib": _hhmm(maghrib),
        "isha": _hhmm(isha),
    }


# ---------------------------------------------------------------------------
# sehri / iftar alarm offsets (the native alarm is a platform hook)
# ---------------------------------------------------------------------------

SEHRI_PREWAKE_DEFAULT_MIN = 60   # wake this long before sehri ends
IFTAR_PREALERT_DEFAULT_MIN = 10  # heads-up before iftar


def sehri_alarm_time(sehri_end_hhmm, prewake_min=SEHRI_PREWAKE_DEFAULT_MIN):
    """HH:MM to ring the sehri wake alarm = sehri_end - prewake (wrap at 00:00)."""
    return _shift_hhmm(sehri_end_hhmm, -abs(int(prewake_min)))


def iftar_alert_time(iftar_hhmm, prealert_min=IFTAR_PREALERT_DEFAULT_MIN):
    return _shift_hhmm(iftar_hhmm, -abs(int(prealert_min)))


def _shift_hhmm(hhmm, delta_min):
    if not hhmm:
        return None
    try:
        h, m = map(int, str(hhmm).split(":"))
    except (ValueError, AttributeError):
        return None
    total = (h * 60 + m + delta_min) % (24 * 60)
    return f"{total // 60:02d}:{total % 60:02d}"


# Wake-for-sehri IVR CALL is key-gated (telephony/partner). This flag is all the
# logic layer exposes; the integrator gates the actual call.
WAKE_IVR_AVAILABLE = False


# ---------------------------------------------------------------------------
# zakat — reuse finance.zakat when present, else a pure fallback
# ---------------------------------------------------------------------------

def zakat(cash=0, gold_value=0, silver_value=0, investments=0, debts=0, nisab=0):
    """Thin wrapper so Ramadan mode offers zakat without duplicating logic.
    Prefers core.finance.zakat (single source of truth); falls back to an
    identical pure computation when Django isn't importable (self-tests)."""
    try:
        from core import finance
        return finance.zakat(cash=cash, gold_value=gold_value,
                             silver_value=silver_value, investments=investments,
                             debts=debts, nisab=nisab)
    except Exception:
        from decimal import Decimal

        def _d(v):
            try:
                return Decimal(str(v if v not in (None, "") else "0"))
            except Exception:
                return Decimal("0")
        wealth = (_d(cash) + _d(gold_value) + _d(silver_value)
                  + _d(investments) - _d(debts))
        if wealth <= 0:
            return {"zakatable": "0", "zakat_due": "0", "above_nisab": False}
        above = wealth >= _d(nisab) if _d(nisab) > 0 else True
        due = (wealth * Decimal("0.025")).quantize(Decimal("0.01")) if above \
            else Decimal("0")
        return {"zakatable": str(wealth), "zakat_due": str(due),
                "above_nisab": above}


# ---------------------------------------------------------------------------
# Eid salami (eidi) split + greeting / salami card drafts
# ---------------------------------------------------------------------------

def salami_split(total, people):
    """Split an eidi/salami budget across people. Returns per-person (floored to
    whole taka) + remainder to distribute. Never negative; people<=0 -> all left."""
    try:
        from decimal import Decimal
        tot = Decimal(str(total))
        n = int(people)
    except Exception:
        return {"each": "0", "remainder": "0", "people": 0}
    if n <= 0 or tot <= 0:
        return {"each": "0", "remainder": str(tot if tot > 0 else 0), "people": max(0, n)}
    each = (tot // n)
    rem = tot - each * n
    return {"each": str(each), "remainder": str(rem), "people": n}


def eid_greeting_draft(to_name="", from_name="", lang="bn"):
    """An editable Eid greeting DRAFT (never auto-sent). Uses only the names the
    user supplies; no fabricated content."""
    to = to_name.strip()
    frm = from_name.strip()
    if lang == "en":
        body = (f"Eid Mubarak{', ' + to if to else ''}! "
                f"May this Eid bring you peace, health and joy."
                + (f"\n— {frm}" if frm else ""))
    else:
        body = (f"ঈদ মুবারক{', ' + to if to else ''}! "
                f"এই ঈদ আপনার জীবনে শান্তি, সুস্থতা ও আনন্দ বয়ে আনুক।"
                + (f"\n— {frm}" if frm else ""))
    return {"kind": "eid_greeting", "lang": lang, "text": body, "editable": True}


def salami_card_draft(to_name="", amount=None, from_name="", lang="bn"):
    """An editable Eid salami card DRAFT. amount is optional; if given it is only
    echoed (we don't move money)."""
    to = to_name.strip()
    frm = from_name.strip()
    amt_bn = f" ({amount}৳ সালামি)" if amount not in (None, "") else ""
    amt_en = f" ({amount} Tk eidi)" if amount not in (None, "") else ""
    if lang == "en":
        text = (f"Eid Mubarak{', ' + to if to else ''}!{amt_en} "
                f"Here's a little something for you."
                + (f"\n— {frm}" if frm else ""))
    else:
        text = (f"ঈদ মুবারক{', ' + to if to else ''}!{amt_bn} "
                f"তোমার জন্য ছোট্ট উপহার।"
                + (f"\n— {frm}" if frm else ""))
    return {"kind": "eid_salami", "lang": lang, "text": text, "editable": True}


# ---------------------------------------------------------------------------
# Ramadan day countdown (start date is user/owner supplied — moon-sighting
# varies, so we never hard-code it)
# ---------------------------------------------------------------------------

def ramadan_day(start_date, today=None):
    """Which day of Ramadan `today` is, given a user-supplied start date.

    Returns:
      {'phase': 'before'|'during'|'after', 'day': int|None, 'days_until': int|None}
    start_date/today accept date or ISO string. Ramadan assumed 30 days max.
    """
    def _d(v):
        if isinstance(v, date) and not isinstance(v, datetime):
            return v
        if isinstance(v, datetime):
            return v.date()
        try:
            return date.fromisoformat(str(v))
        except (ValueError, TypeError):
            return None
    s = _d(start_date)
    t = _d(today) or date.today()
    if s is None:
        return {"phase": "before", "day": None, "days_until": None}
    diff = (t - s).days
    if diff < 0:
        return {"phase": "before", "day": None, "days_until": -diff}
    if diff <= 29:
        return {"phase": "during", "day": diff + 1, "days_until": 0}
    return {"phase": "after", "day": None, "days_until": None}


# ---------------------------------------------------------------------------
# bilingual payloads
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Ramadan calendar (30 days from a user/owner-supplied start date) — ADVANCED
# ---------------------------------------------------------------------------

RAMADAN_MAX_DAYS = 30  # Ramadan is 29 or 30 days; moon-sighting decides day 29/30.


def ramadan_calendar(start_date, length=RAMADAN_MAX_DAYS, today=None):
    """A Ramadan calendar: one entry per fasting day from `start_date`.

    start_date is USER/OWNER supplied (moon-sighting varies by country — we never
    hard-code it). Returns a list of {day, date(ISO), is_today, phase} where phase
    is 'past'|'today'|'future'. Empty list if no start date. No prayer times here
    (those are computed per-day from location by prayer_times)."""
    def _d(v):
        if isinstance(v, date) and not isinstance(v, datetime):
            return v
        if isinstance(v, datetime):
            return v.date()
        try:
            return date.fromisoformat(str(v))
        except (ValueError, TypeError):
            return None
    s = _d(start_date)
    if s is None:
        return []
    t = _d(today) or date.today()
    n = max(1, min(int(length or RAMADAN_MAX_DAYS), RAMADAN_MAX_DAYS))
    out = []
    for i in range(n):
        d = s + timedelta(days=i)
        if d < t:
            phase = "past"
        elif d == t:
            phase = "today"
        else:
            phase = "future"
        out.append({"day": i + 1, "date": d.isoformat(),
                    "is_today": d == t, "phase": phase})
    return out


# ---------------------------------------------------------------------------
# Sehri / Iftar countdown (minutes remaining; pure, UI ticks the seconds)
# ---------------------------------------------------------------------------

def minutes_until(target_hhmm, now_hhmm):
    """Whole minutes from now_hhmm until the next occurrence of target_hhmm.
    Both HH:MM (24h). If target already passed today, counts to tomorrow.
    Returns int in [0, 1440) or None on bad input."""
    def _m(s):
        try:
            h, m = map(int, str(s).split(":"))
            if not (0 <= h < 24 and 0 <= m < 60):
                return None
            return h * 60 + m
        except (ValueError, AttributeError):
            return None
    tgt, now = _m(target_hhmm), _m(now_hhmm)
    if tgt is None or now is None:
        return None
    return (tgt - now) % (24 * 60)


# ---------------------------------------------------------------------------
# zakat nisab helper — nisab from user/owner-entered bullion PRICE + weight
# ---------------------------------------------------------------------------

# Nisab thresholds (classical, Sahih sources / fiqh consensus):
#   gold nisab  = 87.48 g  (7.5 tola / 20 mithqal)
#   silver nisab = 612.36 g (52.5 tola / 200 dirham)
# The lower of the two monetary values is the nisab most scholars recommend for
# the poor's benefit. We NEVER guess bullion prices — the per-gram price is a
# user/owner input. Source: classical fiqh (hadith of 200 dirhams / 20 dinars).
NISAB_GOLD_GRAMS = 87.48
NISAB_SILVER_GRAMS = 612.36


def nisab_value(gold_price_per_gram=0, silver_price_per_gram=0, prefer="silver"):
    """Monetary nisab from USER-ENTERED per-gram prices. Returns the chosen
    threshold (silver by default — lower, more cautious) or the gold threshold.
    Returns Decimal-string. 0 prices -> '0' (UI then asks for a manual nisab)."""
    from decimal import Decimal

    def _d(v):
        try:
            return Decimal(str(v if v not in (None, "") else "0"))
        except Exception:
            return Decimal("0")
    gold = _d(gold_price_per_gram) * Decimal(str(NISAB_GOLD_GRAMS))
    silver = _d(silver_price_per_gram) * Decimal(str(NISAB_SILVER_GRAMS))
    if prefer == "gold":
        chosen = gold
    else:
        chosen = silver if silver > 0 else gold
    return {
        "nisab": str(chosen.quantize(Decimal("0.01"))),
        "gold_nisab": str(gold.quantize(Decimal("0.01"))),
        "silver_nisab": str(silver.quantize(Decimal("0.01"))),
        "gold_grams": NISAB_GOLD_GRAMS,
        "silver_grams": NISAB_SILVER_GRAMS,
        "basis": prefer,
    }


# ---------------------------------------------------------------------------
# fasting tracker + salami tracker aggregates (entries are user-entered)
# ---------------------------------------------------------------------------

def fasting_stats(kept_days, total_days=RAMADAN_MAX_DAYS):
    """Summarise a fasting log. `kept_days` is an iterable of day-numbers the
    user marked fasted. Pure counting — nothing invented."""
    try:
        kept = {int(x) for x in kept_days if 1 <= int(x) <= int(total_days)}
    except (TypeError, ValueError):
        kept = set()
    total = max(1, min(int(total_days or RAMADAN_MAX_DAYS), RAMADAN_MAX_DAYS))
    return {"kept": len(kept), "total": total,
            "missed_so_far": 0, "days": sorted(kept)}


def salami_tracker_total(entries):
    """Sum an Eid salami (eidi) log. Each entry {name, amount, direction} where
    direction is 'given'|'received'. Amounts are USER-ENTERED (we never move
    money). Returns given/received/net as Decimal-strings + counts."""
    from decimal import Decimal

    def _d(v):
        try:
            return Decimal(str(v if v not in (None, "") else "0"))
        except Exception:
            return Decimal("0")
    given = Decimal("0")
    received = Decimal("0")
    gc = rc = 0
    for e in entries or []:
        amt = _d((e or {}).get("amount"))
        if (e or {}).get("direction") == "received":
            received += amt
            rc += 1
        else:
            given += amt
            gc += 1
    return {
        "given": str(given.quantize(Decimal("0.01"))),
        "received": str(received.quantize(Decimal("0.01"))),
        "net": str((received - given).quantize(Decimal("0.01"))),
        "given_count": gc, "received_count": rc,
    }


# ---------------------------------------------------------------------------
# Duas — authentic, SOURCE-NOTED. Arabic kept as data (never in .dart source).
# Sources are the standard Sahih collections; cited per dua. Bangla/English are
# meanings, not scripture. We present these as references, not religious rulings.
# ---------------------------------------------------------------------------

DUAS = [
    {
        "key": "sehri_intent",
        "title_bn": "সেহরি / রোজার নিয়ত",
        "title_en": "Intention for fasting (Sehri)",
        "arabic": "وَبِصَوْمِ غَدٍ نَّوَيْتُ مِنْ شَهْرِ رَمَضَانَ",
        "meaning_bn": "আমি রমজান মাসের আগামীকালের রোজার নিয়ত করলাম।",
        "meaning_en": "I intend to keep tomorrow's fast of the month of Ramadan.",
        "source": "Sunan Abi Dawud 2454 (reported intention of fasting)",
    },
    {
        "key": "iftar",
        "title_bn": "ইফতারের দোয়া",
        "title_en": "Dua at Iftar (breaking fast)",
        "arabic": "ذَهَبَ الظَّمَأُ وَابْتَلَّتِ الْعُرُوقُ وَثَبَتَ الْأَجْرُ إِنْ شَاءَ اللَّهُ",
        "meaning_bn": "পিপাসা দূর হলো, শিরা-উপশিরা সিক্ত হলো এবং ইনশাআল্লাহ সওয়াব নির্ধারিত হলো।",
        "meaning_en": "The thirst is gone, the veins are moistened, and the reward is "
                      "confirmed, if Allah wills.",
        "source": "Sunan Abi Dawud 2357 (Hasan)",
    },
    {
        "key": "laylat_qadr",
        "title_bn": "লাইলাতুল কদরের দোয়া",
        "title_en": "Dua for Laylat al-Qadr",
        "arabic": "اللَّهُمَّ إِنَّكَ عَفُوٌّ تُحِبُّ الْعَفْوَ فَاعْفُ عَنِّي",
        "meaning_bn": "হে আল্লাহ, আপনি ক্ষমাশীল, ক্ষমা করতে ভালোবাসেন; তাই আমাকে ক্ষমা করুন।",
        "meaning_en": "O Allah, You are Pardoning and love to pardon, so pardon me.",
        "source": "Sunan al-Tirmidhi 3513 (Sahih)",
    },
]


def duas(lang="bn"):
    """Return the source-noted dua list localised (meaning only; Arabic verbatim
    and each with its collection reference). Pure data; no AI, no invention."""
    out = []
    for d in DUAS:
        out.append({
            "key": d["key"],
            "title": pick(lang, d["title_bn"], d["title_en"]),
            "arabic": d["arabic"],
            "meaning": pick(lang, d["meaning_bn"], d["meaning_en"]),
            "source": d["source"],
        })
    return out


def sehri_payload(sehri_end_hhmm, lang="bn"):
    return {
        "kind": "sehri_wake",
        "title": pick(lang, "সেহরির সময়", "Sehri time"),
        "body": pick(lang,
            f"উঠুন — সেহরি শেষ হবে {sehri_end_hhmm}-এ।",
            f"Wake up — sehri ends at {sehri_end_hhmm}."),
    }


def iftar_payload(iftar_hhmm, lang="bn"):
    return {
        "kind": "iftar",
        "title": pick(lang, "ইফতারের সময় প্রায়", "Iftar is near"),
        "body": pick(lang,
            f"ইফতার {iftar_hhmm}-এ।",
            f"Iftar is at {iftar_hhmm}."),
    }
