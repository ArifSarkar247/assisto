"""
ramadan_tests_snippets.py — plain-assert tests for core.logic.ramadan.
NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.ramadan_tests_snippets as t; t.run_all()"
"""
from datetime import date

from core.logic import ramadan as R


def _hhmm_to_min(s):
    h, m = map(int, s.split(":"))
    return h * 60 + m


def test_prayer_times_dhaka_sane_ordering():
    # Dhaka ~ (23.81, 90.41), tz +6. A mid-March day.
    pt = R.prayer_times(date(2026, 3, 15), 23.81, 90.41, tz_offset_hours=6.0)
    for k in ("sehri_end", "fajr", "sunrise", "dhuhr", "asr", "iftar", "isha"):
        assert pt[k] is not None, (k, pt)
    # chronological order through the day
    order = [pt["fajr"], pt["sunrise"], pt["dhuhr"], pt["asr"],
             pt["iftar"], pt["isha"]]
    mins = [_hhmm_to_min(x) for x in order]
    assert mins == sorted(mins), (order, mins)
    # sehri ends at fajr; iftar == maghrib
    assert pt["sehri_end"] == pt["fajr"]
    assert pt["iftar"] == pt["maghrib"]
    # Dhaka iftar mid-March is roughly 18:0x — sanity band 17:30-18:45
    assert 17 * 60 + 30 <= _hhmm_to_min(pt["iftar"]) <= 18 * 60 + 45, pt["iftar"]


def test_method_angles_affect_fajr():
    d = date(2026, 3, 15)
    karachi = R.prayer_times(d, 23.81, 90.41, method="karachi")
    isna = R.prayer_times(d, 23.81, 90.41, method="isna")
    # ISNA (15 deg) fajr is LATER (closer to sunrise) than Karachi (18 deg)
    assert _hhmm_to_min(isna["fajr"]) > _hhmm_to_min(karachi["fajr"])


def test_hanafi_asr_later_than_standard():
    d = date(2026, 3, 15)
    std = R.prayer_times(d, 23.81, 90.41, asr=R.ASR_STANDARD)
    han = R.prayer_times(d, 23.81, 90.41, asr=R.ASR_HANAFI)
    assert _hhmm_to_min(han["asr"]) > _hhmm_to_min(std["asr"])


def test_alarm_offsets():
    assert R.sehri_alarm_time("04:00", prewake_min=60) == "03:00"
    assert R.sehri_alarm_time("00:30", prewake_min=60) == "23:30"  # wrap
    assert R.iftar_alert_time("18:10", prealert_min=10) == "18:00"
    assert R.sehri_alarm_time(None) is None


def test_zakat_fallback_matches_rate():
    r = R.zakat(cash=100000)
    assert r["zakat_due"] == "2500.00"
    r2 = R.zakat(cash=1000, nisab=100000)
    assert r2["above_nisab"] is False and r2["zakat_due"] == "0"


def test_salami_split():
    r = R.salami_split(1000, 3)
    assert r["each"] == "333" and r["remainder"] == "1"
    assert R.salami_split(500, 0)["each"] == "0"


def test_greeting_and_salami_drafts():
    g = R.eid_greeting_draft("Rahim", "Karim", "en")
    assert "Eid Mubarak" in g["text"] and "Rahim" in g["text"] and g["editable"]
    gb = R.eid_greeting_draft("রহিম", "", "bn")
    assert "ঈদ মুবারক" in gb["text"]
    s = R.salami_card_draft("Child", 200, "Dad", "en")
    assert "200 Tk eidi" in s["text"]


def test_ramadan_day():
    start = date(2026, 2, 18)
    assert R.ramadan_day(start, date(2026, 2, 10))["phase"] == "before"
    assert R.ramadan_day(start, date(2026, 2, 10))["days_until"] == 8
    mid = R.ramadan_day(start, date(2026, 2, 20))
    assert mid["phase"] == "during" and mid["day"] == 3
    assert R.ramadan_day(start, date(2026, 4, 1))["phase"] == "after"
    assert R.ramadan_day(None)["phase"] == "before"


def test_payloads():
    assert R.sehri_payload("04:00", "en")["kind"] == "sehri_wake"
    assert "04:00" in R.iftar_payload("04:00", "bn")["body"]
    assert R.WAKE_IVR_AVAILABLE is False  # key-gated


def test_ramadan_calendar():
    cal = R.ramadan_calendar(date(2026, 2, 18), today=date(2026, 2, 20))
    assert len(cal) == 30
    assert cal[0]["day"] == 1 and cal[0]["date"] == "2026-02-18"
    assert cal[0]["phase"] == "past"
    assert cal[2]["is_today"] is True and cal[2]["phase"] == "today"
    assert cal[3]["phase"] == "future"
    assert R.ramadan_calendar(None) == []


def test_minutes_until():
    assert R.minutes_until("04:00", "03:00") == 60
    assert R.minutes_until("03:00", "04:00") == 23 * 60  # wraps to tomorrow
    assert R.minutes_until("18:10", "18:10") == 0
    assert R.minutes_until("bad", "03:00") is None


def test_nisab_value():
    v = R.nisab_value(gold_price_per_gram=10000, silver_price_per_gram=120)
    # silver default (lower monetary): 612.36 * 120 = 73483.20
    assert v["nisab"] == "73483.20"
    assert v["gold_nisab"] == "874800.00"
    assert v["basis"] == "silver"
    g = R.nisab_value(gold_price_per_gram=10000, silver_price_per_gram=120,
                      prefer="gold")
    assert g["nisab"] == "874800.00"
    # zero prices -> zero (UI falls back to manual nisab)
    assert R.nisab_value()["nisab"] == "0.00"


def test_fasting_stats():
    s = R.fasting_stats([1, 2, 2, 3, 99])  # dedup + drop out-of-range
    assert s["kept"] == 3 and s["total"] == 30 and s["days"] == [1, 2, 3]
    assert R.fasting_stats([])["kept"] == 0


def test_salami_tracker_total():
    r = R.salami_tracker_total([
        {"name": "A", "amount": "200", "direction": "given"},
        {"name": "B", "amount": "500", "direction": "received"},
        {"name": "C", "amount": "100", "direction": "given"},
    ])
    assert r["given"] == "300.00" and r["received"] == "500.00"
    assert r["net"] == "200.00"
    assert r["given_count"] == 2 and r["received_count"] == 1
    assert R.salami_tracker_total([])["net"] == "0.00"


def test_duas_source_noted():
    ds = R.duas("en")
    assert len(ds) == 3
    for d in ds:
        assert d["arabic"] and d["source"] and d["meaning"]
    # bn meanings differ from en (localised), arabic identical
    assert R.duas("bn")[0]["arabic"] == ds[0]["arabic"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"ramadan: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
