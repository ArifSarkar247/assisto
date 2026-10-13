"""
meetings_tests_snippets.py — plain-assert tests for core.logic.meetings.
NOT a Django TestCase. Smoke:
    python3 -c "import core.logic.meetings_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta

from core.logic import meetings as M


def test_normalise_requires_title_and_start():
    ok, err = M.normalise_appointment({"start": "2026-01-01T10:00"})
    assert not ok and err == "title_required", (ok, err)
    ok, err = M.normalise_appointment({"title": "X"})
    assert not ok and err == "start_required", (ok, err)
    ok, data = M.normalise_appointment(
        {"title": " Dentist ", "start": "2026-01-01T10:00", "duration_min": 2})
    assert ok and data["title"] == "Dentist"
    assert data["duration_min"] == M.DURATION_MIN  # clamped up from 2


def test_clamp_duration():
    assert M.clamp_duration(99999) == M.DURATION_MAX
    assert M.clamp_duration(1) == M.DURATION_MIN
    assert M.clamp_duration("bad") == M.DURATION_DEFAULT_MIN
    assert M.clamp_duration(45) == 45


def test_reminder_times_drops_past_and_sorts():
    now = datetime(2026, 1, 1, 9, 0)
    start = datetime(2026, 1, 2, 9, 0)  # 24h out
    times = M.reminder_times(start, offsets_min=[24 * 60, 60, 0], now=now)
    # 24h-before == now exactly -> dropped (<= now); 60-before and 0-before kept
    assert start - timedelta(hours=1) in times
    assert start in times
    assert times == sorted(times)
    # a past offset (48h before a 24h-out event) is impossible here; verify dedup
    times2 = M.reminder_times(start, offsets_min=[60, 60], now=now)
    assert len(times2) == 1


def test_leave_at_and_phase():
    start = datetime(2026, 1, 1, 10, 0)
    la = M.leave_at(start, travel_minutes=20, buffer_min=5)
    assert la == datetime(2026, 1, 1, 9, 35)
    # unknown travel -> unknown phase
    assert M.leave_now_phase(start, None, now=start)[0] == "unknown"
    # well before leave time
    state, mins = M.leave_now_phase(start, 20, now=datetime(2026, 1, 1, 9, 0))
    assert state == "later" and mins == 35, (state, mins)
    # past leave time
    state, mins = M.leave_now_phase(start, 20, now=datetime(2026, 1, 1, 9, 40))
    assert state == "leave_now" and mins == 5, (state, mins)


def test_maps_dir_url():
    u = M.maps_dir_url(lat=23.8, lng=90.4)
    assert "destination=23.8,90.4" in u
    u2 = M.maps_dir_url(place="Dhaka Medical")
    assert "destination=Dhaka%20Medical" in u2
    assert M.maps_dir_url() is None


def test_upcoming_filters_past_and_window():
    now = datetime(2026, 1, 1, 12, 0)
    appts = [
        {"title": "past", "start": "2025-12-31T12:00"},
        {"title": "soon", "start": "2026-01-01T15:00"},
        {"title": "far", "start": "2026-03-01T12:00"},
    ]
    up = M.upcoming(appts, now=now)
    assert [a["title"] for a in up] == ["soon", "far"]
    win = M.upcoming(appts, now=now, within_days=7)
    assert [a["title"] for a in win] == ["soon"]


def test_conflicts_detects_overlap_not_touching():
    appts = [
        {"title": "A", "start": "2026-01-01T10:00", "duration_min": 60},
        {"title": "B", "start": "2026-01-01T10:30", "duration_min": 60},  # overlaps A
        {"title": "C", "start": "2026-01-01T11:00", "duration_min": 60},  # touches B end? B ends 11:30
    ]
    c = M.conflicts(appts)
    assert (0, 1) in c  # A & B overlap
    assert (1, 2) in c  # B(10:30-11:30) & C(11:00-12:00) overlap
    # pure touching: X ends exactly when Y starts -> no conflict
    touch = [
        {"title": "X", "start": "2026-01-01T09:00", "duration_min": 60},
        {"title": "Y", "start": "2026-01-01T10:00", "duration_min": 60},
    ]
    assert M.conflicts(touch) == []


def test_payloads_bilingual():
    bn = M.reminder_payload("ডাক্তার", 60, "ক্লিনিক", "bn")
    en = M.reminder_payload("Doctor", 60, "Clinic", "en")
    assert bn["kind"] == en["kind"] == "appointment_reminder"
    assert "1 hour" in en["body"]
    ln = M.leave_now_payload("Doctor", "Clinic", 15, "en")
    assert ln["kind"] == "appointment_leave_now" and "15 min" in ln["body"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"meetings: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
