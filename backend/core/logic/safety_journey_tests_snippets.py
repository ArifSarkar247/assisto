"""
safety_journey_tests_snippets.py — plain-assert tests for core.logic.safety_journey.

NOT a Django TestCase. Smoke locally:
    python3 -c "import core.logic.safety_journey_tests_snippets as t; t.run_all()"

Covers the mandated SCENARIO tests (item 19):
  normal trip -> arrival; late arrival -> overdue -> alert; no-response
  escalation; SOS dispatch; duress PIN (looks cancelled, alert sent); low
  battery <15% auto-send; offline queue + retry; watcher-without-app expiring
  web link; wellness-check no-activity -> alert.
"""
from datetime import datetime, timedelta

from core.logic import safety_journey as J


DHAKA = (23.8103, 90.4125)


def _journey(now, eta_min=30, dest_coords=True):
    dest = {"name": "Home", "lat": 23.8200, "lng": 90.4200} if dest_coords \
        else {"name": "Home"}
    return J.new_journey(
        traveller_id=1,
        destination=dest,
        eta=now + timedelta(minutes=eta_min),
        watcher_ids=[2, 3, 2],   # dup dropped
        started_at=now,
    )


# ---- item 1: start journey ------------------------------------------------

def test_new_journey_dedups_watchers_and_sets_expiry():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now)
    assert j["watcher_ids"] == [2, 3], j["watcher_ids"]
    assert j["status"] == "active"
    assert j["expires_at"] is not None
    # expiry = eta + grace + resp + retention (10+5 min + 24h here)
    exp = J.parse_dt(j["expires_at"])
    assert exp > J.parse_dt(j["eta"])


def test_preset_journey():
    now = datetime(2026, 1, 1, 18, 0)
    preset = {"name": "Office->Home", "destination": {"name": "Home"}, "minutes": 45}
    j = J.preset_journey(preset, 1, [2], now=now)
    assert J.parse_dt(j["eta"]) == now + timedelta(minutes=45)


# ---- SCENARIO: normal trip -> arrival (item 4) ----------------------------

def test_normal_trip_auto_arrival():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now)
    # moving, not yet near dest
    J.record_location(j, 23.8103, 90.4125, at=now + timedelta(minutes=5))
    arrived, dist = J.arrival_check(j)
    assert arrived is False and dist is not None
    # arrives within geofence
    J.record_location(j, 23.8201, 90.4201, at=now + timedelta(minutes=20))
    arrived, dist = J.arrival_check(j)
    assert arrived is True, dist
    J.mark_arrived(j, at=now + timedelta(minutes=20))
    assert j["status"] == "arrived"
    assert J.overdue_state(j, now=now + timedelta(hours=2))[0] == "arrived"


def test_manual_im_safe_without_geofence():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now, dest_coords=False)
    assert J.arrival_check(j) == (False, None)  # no coords -> no auto
    J.mark_arrived(j, at=now + timedelta(minutes=25))
    assert j["status"] == "arrived"


# ---- SCENARIO: late arrival -> overdue -> alert (item 5) ------------------

def test_overdue_progression_to_alert():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now, eta_min=30)   # eta 18:30, grace 10, resp 5
    assert J.overdue_state(j, now=now)[0] == "on_time"
    assert J.overdue_state(j, now=datetime(2026, 1, 1, 18, 35))[0] == "grace"
    assert J.overdue_state(j, now=datetime(2026, 1, 1, 18, 42))[0] == "ask"
    assert J.overdue_state(j, now=datetime(2026, 1, 1, 18, 50))[0] == "alert"
    assert J.should_alert_overdue(j, now=datetime(2026, 1, 1, 18, 50)) is True


# ---- SCENARIO: no-response escalation -------------------------------------

def test_no_response_escalation_vs_responded_ok():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now, eta_min=30)
    late = datetime(2026, 1, 1, 18, 50)
    # if the traveller answers "I'm OK", NO alert
    assert J.overdue_state(j, now=late, responded_ok=True)[0] == "ok"
    assert J.should_alert_overdue(j, now=late, responded_ok=True) is False
    # no answer -> alert
    assert J.should_alert_overdue(j, now=late) is True


# ---- SCENARIO: SOS dispatch (item 7) --------------------------------------

def test_sos_payload_with_location():
    loc = {"lat": 23.81, "lng": 90.41}
    p = J.sos_journey_payload("Rahima", loc=loc, lang="en")
    assert p["kind"] == "sos" and p["silent"] is False
    assert "maps.google.com" in p["body"]
    bn = J.sos_journey_payload("রহিমা", loc=loc, lang="bn")
    assert "রহিমা" in bn["body"]


# ---- SCENARIO: duress PIN (looks cancelled, alert sent) (item 8) ----------

def test_duress_pin_fake_cancel_fires_silent_alert():
    salt = "s1"
    normal = J.hash_pin("1234", salt)
    duress = J.hash_pin("9999", salt)
    # normal pin -> genuine cancel, no alert
    a = J.verify_pin_action("1234", normal, duress, salt)
    assert a == "cancel"
    out = J.duress_outcome(a)
    assert out == {"ui": "cancelled", "alert": False, "silent": False}
    # duress pin -> screen LOOKS cancelled, silent alert fires
    a2 = J.verify_pin_action("9999", normal, duress, salt)
    assert a2 == "duress"
    out2 = J.duress_outcome(a2)
    assert out2["ui"] == "cancelled" and out2["alert"] is True and out2["silent"] is True
    # wrong pin -> do not cancel, keep armed
    assert J.verify_pin_action("0000", normal, duress, salt) == "wrong"
    assert J.duress_outcome("wrong")["ui"] == "stay"


def test_duress_pin_hash_not_reversible_and_stable():
    h1 = J.hash_pin("1234", "salt")
    h2 = J.hash_pin("1234", "salt")
    assert h1 == h2 and "1234" not in h1 and len(h1) == 64


# ---- SCENARIO: low battery <15% auto-send (item 6) ------------------------

def test_low_battery_crossing_fires_once():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now)
    assert J.low_battery_trigger(j, 20) is False          # above threshold
    assert J.low_battery_trigger(j, 14) is True            # first cross
    assert J.low_battery_trigger(j, 14, last_sent_pct=14) is False  # no repeat
    assert J.low_battery_trigger(j, 8, last_sent_pct=14) is True    # dropped more
    J.mark_arrived(j)
    assert J.low_battery_trigger(j, 5) is False            # not active anymore


# ---- SCENARIO: offline queue + retry (item 17) ----------------------------

def test_offline_queue_retry_and_send():
    now = datetime(2026, 1, 1, 18, 0)
    q = J.enqueue_alert([], J.sos_journey_payload("X", lang="en"), now=now)
    assert len(q) == 1 and q[0]["sent"] is False
    aid = q[0]["id"]
    due = J.due_alerts(q, now=now)
    assert len(due) == 1
    # fail once -> backoff pushes next_retry into the future
    q = J.mark_alert_result(q, aid, success=False, now=now)
    assert q[0]["attempts"] == 1
    assert J.due_alerts(q, now=now) == []   # not due yet
    later = now + timedelta(seconds=10)
    assert len(J.due_alerts(q, now=later)) == 1
    # succeed -> no longer due
    q = J.mark_alert_result(q, aid, success=True, now=later)
    assert q[0]["sent"] is True
    assert J.due_alerts(q, now=later + timedelta(hours=1)) == []


def test_backoff_caps():
    assert J.next_backoff_seconds(0) == 5
    assert J.next_backoff_seconds(1) == 10
    assert J.next_backoff_seconds(3) == 40
    assert J.next_backoff_seconds(99) == 300


# ---- SCENARIO: watcher-without-app expiring web link (item 13) ------------

def test_web_link_valid_then_expires():
    now = datetime(2026, 1, 1, 18, 0)
    expires = now + timedelta(minutes=30)
    secret = "websecret"
    tok = J.make_web_token("abc", expires, secret)
    jid, ok, reason = J.parse_web_token(tok, secret, now=now)
    assert jid == "abc" and ok is True and reason == "ok"
    # right after expiry (inside grace) -> 'ended' page, no location
    jid, ok, reason = J.parse_web_token(tok, secret, now=expires + timedelta(minutes=2))
    assert ok is False and reason == "ended"
    # well past -> expired/dead
    jid, ok, reason = J.parse_web_token(tok, secret, now=expires + timedelta(minutes=30))
    assert ok is False and reason == "expired"
    # tampered token -> bad
    assert J.parse_web_token(tok + "x", secret, now=now)[2] == "bad"
    assert J.parse_web_token("garbage", secret, now=now)[2] == "bad"


# ---- SCENARIO: wellness check no-activity -> alert (item 16) ---------------

def test_wellness_off_without_optin():
    cfg = J.default_wellness_config()
    cfg["enabled"] = True   # but parent_opt_in still False
    assert J.wellness_state(cfg, datetime(2026, 1, 1, 0, 0),
                            now=datetime(2026, 1, 3, 12, 0))[0] == "off"


def test_wellness_progression_quiet_prompt_alert():
    cfg = J.default_wellness_config()
    cfg.update(enabled=True, parent_opt_in=True, period_hours=12,
               response_window_min=60, quiet_start="22:00", quiet_end="07:00")
    last = datetime(2026, 1, 1, 8, 0)
    # recent activity -> ok
    assert J.wellness_state(cfg, last, now=datetime(2026, 1, 1, 12, 0))[0] == "ok"
    # 12h idle but it's 03:00 (quiet hours) -> wait
    assert J.wellness_state(cfg, last, now=datetime(2026, 1, 1, 23, 30))[0] == "quiet"
    # 12h idle, awake hours -> prompt
    assert J.wellness_state(cfg, last, now=datetime(2026, 1, 1, 21, 0))[0] == "prompt"
    # prompt sent, no answer past window -> alert children
    sent = datetime(2026, 1, 1, 21, 0)
    st = J.wellness_state(cfg, last, now=datetime(2026, 1, 1, 22, 5),
                          prompt_sent_at=sent)
    # 22:05 is quiet -> but prompt already out; response window elapsed -> alert
    assert st[0] == "alert", st
    # answered -> ok
    assert J.wellness_state(cfg, last, now=datetime(2026, 1, 1, 21, 30),
                            responded=True, prompt_sent_at=sent)[0] == "ok"


def test_quiet_hours_wrap_midnight():
    cfg = J.default_wellness_config()
    cfg.update(quiet_start="22:00", quiet_end="07:00")
    assert J.in_quiet_hours(cfg, datetime(2026, 1, 1, 23, 0)) is True
    assert J.in_quiet_hours(cfg, datetime(2026, 1, 1, 3, 0)) is True
    assert J.in_quiet_hours(cfg, datetime(2026, 1, 1, 12, 0)) is False


# ---- item 15: route deviation ---------------------------------------------

def test_route_deviation():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now)
    # off by default
    assert J.route_deviation(j, 23.90, 90.90) == (False, None)
    j["route_deviation_on"] = True
    j["planned_route"] = [{"lat": 23.8103, "lng": 90.4125},
                          {"lat": 23.8200, "lng": 90.4200}]
    j["route_deviation_m"] = 500
    dev, m = J.route_deviation(j, 23.8105, 90.4127)  # ~30m off
    assert dev is False
    dev, m = J.route_deviation(j, 23.95, 90.55)       # far off
    assert dev is True and m > 500


# ---- item 14: routine commutes --------------------------------------------

def test_routine_due_window_and_dedup():
    routine = {"enabled": True, "days": ["thu"], "time": "18:00"}
    thu = datetime(2026, 1, 1, 18, 3)   # 2026-01-01 is a Thursday
    assert J.routine_due(routine, now=thu) is True
    # outside window
    assert J.routine_due(routine, now=datetime(2026, 1, 1, 18, 30)) is False
    # wrong day
    assert J.routine_due(routine, now=datetime(2026, 1, 2, 18, 3)) is False
    # already started today -> not due again
    assert J.routine_due(routine, now=thu,
                         last_started=datetime(2026, 1, 1, 18, 1)) is False
    # disabled
    assert J.routine_due({"enabled": False, "days": ["thu"], "time": "18:00"},
                         now=thu) is False


# ---- item 18: privacy auto-delete / expiry --------------------------------

def test_journey_expiry_and_redaction():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now, eta_min=30)
    J.record_location(j, 23.81, 90.41, at=now)
    assert J.journey_is_expired(j, now=now) is False
    # after hard expiry
    far = now + timedelta(days=2)
    assert J.journey_is_expired(j, now=far) is True
    red = J.redact_expired_journey(j, now=far)
    assert red["last_location"] is None
    assert red["status"] == "expired"
    assert red["destination"] == {"name": "Home"}  # name kept, coords dropped
    # not expired -> unchanged
    assert J.redact_expired_journey(j, now=now) is j


def test_stopped_trip_retention_clock():
    now = datetime(2026, 1, 1, 18, 0)
    j = _journey(now)
    j["location_retention_hours"] = 0   # delete immediately on stop
    J.record_location(j, 23.81, 90.41, at=now)
    J.stop_journey(j, at=now)
    assert J.journey_is_expired(j, now=now) is True
    assert J.redact_expired_journey(j, now=now)["last_location"] is None


# ---- item 10/11/9/12: consent, nearest help, fake call, helplines ---------

def test_where_are_you_consent():
    req = J.where_are_you_request(5, "Karim", lang="en")
    assert req["kind"] == "where_are_you" and "accept" in req["actions"]
    assert J.resolve_where_are_you(True) == "share"
    assert J.resolve_where_are_you(False) == "withheld"


def test_nearest_help_ranking():
    q = J.nearest_help_query(*DHAKA)
    assert {x["type"] for x in q} == {"police", "hospital"}
    places = [
        {"name": "Far", "lat": 23.90, "lng": 90.50},
        {"name": "Near", "lat": 23.8110, "lng": 90.4130},
        {"name": "NoCoord"},
    ]
    ranked = J.rank_nearest(places, *DHAKA, limit=2)
    assert ranked[0]["name"] == "Near"
    assert "distance_m" in ranked[0] and "maps.google.com" in ranked[0]["directions"]
    assert all("lat" in p for p in ranked)  # NoCoord skipped


def test_fake_call_plan():
    now = datetime(2026, 1, 1, 18, 0)
    p = J.fake_call_plan("Boss", 10, now=now)
    assert p["caller"] == "Boss" and p["delay_seconds"] == 10
    assert J.parse_dt(p["ring_at"]) == now + timedelta(seconds=10)
    # clamps + default name
    assert J.fake_call_plan("", 9999)["delay_seconds"] == J.FAKE_CALL_DELAY_MAX


def test_helplines_verified_numbers():
    bn = J.helplines("bn")
    en = J.helplines("en")
    nums = {h["number"] for h in en}
    assert nums == {"999", "109"}, nums
    assert all(h["label"] for h in bn) and all(h["label"] for h in en)


# ---- payloads bilingual ---------------------------------------------------

def test_payloads_bilingual():
    for fn, args in [
        (J.journey_started_payload, ("X", "Home")),
        (J.arrived_payload, ("X", "Home")),
        (J.overdue_payload, ("X", "Home", 20)),
        (J.low_battery_payload, ("X", 10)),
        (J.wellness_payload, ("X",)),
        (J.route_deviation_payload, ("X", 600)),
    ]:
        en = fn(*args, lang="en")
        bn = fn(*args, lang="bn")
        assert en["title"] and bn["title"] and en["body"] and bn["body"]
        assert en["body"] != bn["body"]
    v = J.vehicle_payload("X", {"plate": "DHA-1234", "mode": "CNG"}, lang="en")
    assert "DHA-1234" in v["body"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"safety_journey: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
