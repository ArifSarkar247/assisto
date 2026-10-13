"""
safety_tests_snippets.py — plain-assert tests for core.logic.safety.

NOT a Django TestCase. Smoke locally:
    python3 -c "import core.logic.safety_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta

from core.logic import safety as S


def test_sos_countdown_clamp():
    assert S.clamp_sos_countdown(999) == S.SOS_COUNTDOWN_MAX
    assert S.clamp_sos_countdown(-5) == S.SOS_COUNTDOWN_MIN
    assert S.clamp_sos_countdown("abc") == S.SOS_COUNTDOWN_DEFAULT
    assert S.clamp_sos_countdown(8) == 8


def test_sos_phase_counting_and_fire():
    assert S.sos_phase(5, 0) == ("counting", 5)
    assert S.sos_phase(5, 2) == ("counting", 3)
    assert S.sos_phase(5, 5) == ("fired", 0)
    assert S.sos_phase(5, 9) == ("fired", 0)
    assert S.sos_phase(0, 0) == ("fired", 0)  # immediate


def test_sos_phase_cancel():
    assert S.sos_phase(5, 2, cancelled=True) == ("cancelled", 0)


def test_sos_targets_order_skips_blank():
    cs = [{"name": "A", "phone": "0171"}, {"name": "B", "phone": ""}, {"name": "C", "phone": "0192"}]
    out = S.sos_alert_targets(cs)
    assert [c["name"] for c in out] == ["A", "C"], out


def test_sos_primary_skips_leading_blank():
    # The app's SOS must dial the FIRST contact that has a phone, not blindly
    # contacts[0]. Mirror: targets[0] when the leading entry is phoneless.
    cs = [{"name": "NoPhone", "phone": "  "}, {"name": "Real", "phone": "01999"}]
    out = S.sos_alert_targets(cs)
    assert out and out[0]["name"] == "Real", out
    # all-blank -> no callable target (app shows "add a contact")
    assert S.sos_alert_targets([{"name": "X", "phone": ""}]) == []
    assert S.sos_alert_targets([]) == []


def test_fall_window_clamp_defaults():
    cfg = S.default_fall_config()
    assert cfg["window_seconds"] == 120
    assert cfg["enabled"] is False
    assert S.clamp_fall_window(5) == S.FALL_WINDOW_MIN
    assert S.clamp_fall_window(99999) == S.FALL_WINDOW_MAX


def test_fall_prompt_phase():
    assert S.fall_prompt_phase(120, 0) == ("waiting", 120)
    assert S.fall_prompt_phase(120, 60) == ("waiting", 60)
    assert S.fall_prompt_phase(120, 120) == ("alert", 0)
    assert S.fall_prompt_phase(120, 30, im_ok=True) == ("ok", 0)


def test_checkin_on_time():
    now = datetime(2026, 1, 1, 12, 0)
    eta = now + timedelta(minutes=20)
    state, mins = S.checkin_status(eta, now=now)
    assert state == "on_time", (state, mins)
    assert mins == 20, mins


def test_checkin_grace():
    now = datetime(2026, 1, 1, 12, 10)
    eta = datetime(2026, 1, 1, 12, 0)
    state, mins = S.checkin_status(eta, now=now, grace_minutes=15)
    assert state == "grace", (state, mins)


def test_checkin_overdue_alerts():
    now = datetime(2026, 1, 1, 12, 40)
    eta = datetime(2026, 1, 1, 12, 0)
    state, mins = S.checkin_status(eta, now=now, grace_minutes=15)
    assert state == "overdue", (state, mins)
    assert mins == 40, mins
    assert S.should_alert_checkin(eta, now=now, grace_minutes=15) is True


def test_checkin_arrived_never_alerts():
    now = datetime(2026, 1, 1, 13, 0)
    eta = datetime(2026, 1, 1, 12, 0)
    assert S.checkin_status(eta, now=now, arrived=True)[0] == "arrived"
    assert S.should_alert_checkin(eta, now=now, arrived=True) is False


def test_checkin_iso_string_and_unknown():
    now = datetime(2026, 1, 1, 12, 0)
    state, _ = S.checkin_status("2026-01-01T12:30:00", now=now)
    assert state == "on_time", state
    assert S.checkin_status("not-a-date", now=now)[0] == "unknown"
    assert S.checkin_status(None, now=now)[0] == "unknown"


def test_geofence_within():
    # Dhaka ~ (23.8103, 90.4125). A point ~50m away is within 150m.
    assert S.within_place(23.8103, 90.4125, 23.8104, 90.4125, radius_m=150) is True
    assert S.within_place(23.8103, 90.4125, 23.9000, 90.5000, radius_m=150) is False
    assert S.within_place(None, 90.4, 23.8, 90.4) is False


def test_payloads_bilingual():
    bn = S.checkin_overdue_payload("রহিম", "স্কুল", 30, "bn")
    en = S.checkin_overdue_payload("Rahim", "school", 30, "en")
    assert bn["kind"] == en["kind"] == "checkin_overdue"
    assert "রহিম" in bn["body"] and "Rahim" in en["body"]
    assert S.fall_alert_payload("X", "en")["kind"] == "fall_alert"
    assert S.sos_payload("X", "http://m", "en")["kind"] == "sos"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"safety: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
