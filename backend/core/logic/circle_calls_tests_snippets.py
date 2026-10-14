"""
circle_calls_tests_snippets.py — plain-assert tests for core.logic.circle_calls.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.circle_calls_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle_calls as CC


# ---- THE video plan gate (server-side entitlement) ----

def test_voice_free_for_all():
    free_caller = {"plan": "free", "accepted": True}
    callee = {"accepted": True}
    r = CC.can_place_call(free_caller, callee, "voice")
    assert r["allowed"] is True
    assert r["upgrade_required"] is False


def test_free_caller_video_denied():
    free_caller = {"plan": "free", "accepted": True}
    callee = {"accepted": True}
    r = CC.can_place_call(free_caller, callee, "video")
    assert r["allowed"] is False
    assert r["upgrade_required"] is True
    assert r["needs_video_plan"] is True
    assert r["reason"] == "video_requires_premium"


def test_premium_caller_free_receiver_video_allowed():
    # A Premium son video-calls his FREE mother -> allowed (caller plan gates).
    premium_caller = {"plan": "premium", "accepted": True}
    free_callee = {"plan": "free", "accepted": True}
    r = CC.can_place_call(premium_caller, free_callee, "video")
    assert r["allowed"] is True
    assert r["upgrade_required"] is False


def test_family_business_annual_plans_allow_video():
    for plan in ("family", "business", "annual", "premium_annual"):
        caller = {"plan": plan, "accepted": True}
        assert CC.can_place_call(caller, {"accepted": True}, "video")["allowed"] is True


def test_referral_points_unlock_video():
    caller = {"plan": "free", "video_unlocked": True, "accepted": True}
    r = CC.can_place_call(caller, {"accepted": True}, "video")
    assert r["allowed"] is True


def test_call_denied_when_not_connected():
    caller = {"plan": "premium", "accepted": False}
    assert CC.can_place_call(caller, {"accepted": True}, "voice")["allowed"] is False


def test_call_denied_when_blocked():
    caller = {"plan": "premium", "accepted": True, "blocked": True}
    r = CC.can_place_call(caller, {"accepted": True}, "voice")
    assert r["allowed"] is False
    assert r["reason"] == "not_connected"


def test_restricted_voice_allowed_but_silent():
    caller = {"plan": "free", "accepted": True}
    callee = {"accepted": True, "restricted": True}
    r = CC.can_place_call(caller, callee, "voice")
    assert r["allowed"] is True
    assert r.get("silent") is True


def test_plan_allows_video_helper():
    assert CC.plan_allows_video("premium") is True
    assert CC.plan_allows_video("free") is False
    assert CC.plan_allows_video(None) is False


def test_upgrade_prompt_bilingual():
    bn = CC.upgrade_prompt("bn")
    en = CC.upgrade_prompt("en")
    assert "প্রিমিয়াম" in bn["title"]
    assert "Premium" in en["title"]


# ---- call-record state machine ----

def test_call_fsm_answer_path():
    s, ch = CC.apply_call_event(CC.CALL_RINGING, "answer")
    assert s == CC.CALL_CONNECTING and ch is True
    s, ch = CC.apply_call_event(CC.CALL_CONNECTING, "connected")
    assert s == CC.CALL_ACTIVE and ch is True
    s, ch = CC.apply_call_event(CC.CALL_ACTIVE, "hangup")
    assert s == CC.CALL_ENDED and ch is True


def test_call_fsm_missed_declined_canceled():
    assert CC.apply_call_event(CC.CALL_RINGING, "timeout")[0] == CC.CALL_MISSED
    assert CC.apply_call_event(CC.CALL_RINGING, "decline")[0] == CC.CALL_DECLINED
    assert CC.apply_call_event(CC.CALL_RINGING, "cancel")[0] == CC.CALL_CANCELED


def test_call_fsm_illegal_noop():
    s, ch = CC.apply_call_event(CC.CALL_ENDED, "answer")
    assert ch is False and s == CC.CALL_ENDED
    assert CC.apply_call_event(CC.CALL_ACTIVE, "answer")[1] is False


def test_is_missed_and_terminal():
    assert CC.is_missed(CC.CALL_MISSED) is True
    assert CC.is_missed(CC.CALL_CANCELED) is True
    assert CC.is_missed(CC.CALL_DECLINED) is False
    assert CC.is_terminal(CC.CALL_ENDED) is True
    assert CC.is_terminal(CC.CALL_ACTIVE) is False


def test_can_call_back():
    assert CC.can_call_back({"state": CC.CALL_MISSED}) is True
    assert CC.can_call_back({"state": CC.CALL_ENDED}) is True
    assert CC.can_call_back({"state": CC.CALL_ACTIVE}) is False


# ---- record construction + duration ----

def test_new_call_record():
    now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    rec = CC.new_call_record("c1", 1, 2, "video", started_at=now)
    assert rec["state"] == CC.CALL_RINGING
    assert rec["kind"] == "video"
    assert rec["duration_sec"] == 0


def test_finalize_call_duration():
    t0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    rec = CC.new_call_record("c1", 1, 2, "voice", started_at=t0)
    rec = CC.finalize_call(rec, "answer", at=t0 + timedelta(seconds=5))
    assert rec["state"] == CC.CALL_CONNECTING
    rec = CC.finalize_call(rec, "connected", at=t0 + timedelta(seconds=6))
    rec = CC.finalize_call(rec, "hangup", at=t0 + timedelta(seconds=65))
    assert rec["state"] == CC.CALL_ENDED
    # duration measured from answered_at (t0+5) to end (t0+65) = 60s
    assert rec["duration_sec"] == 60


def test_finalize_missed_zero_duration():
    t0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    rec = CC.new_call_record("c1", 1, 2, "voice", started_at=t0)
    rec = CC.finalize_call(rec, "timeout", at=t0 + timedelta(seconds=30))
    assert rec["state"] == CC.CALL_MISSED
    assert rec["duration_sec"] == 0


def test_format_duration():
    assert CC.format_duration(0) == "0:00"
    assert CC.format_duration(65) == "1:05"
    assert CC.format_duration(3725) == "1:02:05"


def test_outcome_label_bilingual():
    rec = {"caller_id": 1, "callee_id": 2, "kind": "video", "state": CC.CALL_MISSED}
    # viewer is the callee (2) -> incoming missed
    en = CC.call_outcome_label(rec, 2, "en")
    assert "Video" in en and "Missed" in en
    bn = CC.call_outcome_label(rec, 2, "bn")
    assert "ভিডিও" in bn and "মিসড" in bn


# ---- in-call controls ----

def test_default_controls():
    v = CC.default_controls("video")
    assert v["camera_on"] is True and v["speaker_on"] is True
    a = CC.default_controls("voice")
    assert a["camera_on"] is False


def test_toggle_control():
    c = CC.default_controls("voice")
    c = CC.toggle_control(c, "muted")
    assert c["muted"] is True
    c = CC.toggle_control(c, "switch_camera")
    assert c["front_camera"] is False
    # unknown control ignored
    before = dict(c)
    assert CC.toggle_control(c, "nonsense") == before


# ---- transport status / ICE ----

def test_transport_status_states():
    s = CC.transport_status(push_ready=False, turn_ready=False, lang="en")
    assert s["app_open_calling"] is True
    assert s["app_closed_ring"] is False
    assert s["turn_relay"] is False
    assert "while the app is open" in s["banner"]
    s2 = CC.transport_status(push_ready=True, turn_ready=True, lang="en")
    assert s2["app_closed_ring"] is True and s2["turn_relay"] is True


def test_ice_config_turn_gated():
    cfg = CC.ice_config(turn_ready=False)
    assert len(cfg["iceServers"]) == 1  # STUN only
    cfg2 = CC.ice_config(turn_ready=True,
                         turn={"urls": "turn:relay.example:3478",
                               "username": "u", "credential": "c"})
    assert len(cfg2["iceServers"]) == 2


# ---- reconnecting state (Section-21 advanced call-flow) ----

def test_call_fsm_reconnect_path():
    # active -> reconnect -> reconnecting, then recover back to active.
    s, ch = CC.apply_call_event(CC.CALL_ACTIVE, "reconnect")
    assert s == CC.CALL_RECONNECTING and ch is True
    s, ch = CC.apply_call_event(CC.CALL_RECONNECTING, "connected")
    assert s == CC.CALL_ACTIVE and ch is True


def test_call_fsm_reconnect_then_fail_or_hangup():
    assert CC.apply_call_event(CC.CALL_RECONNECTING, "fail")[0] == CC.CALL_FAILED
    assert CC.apply_call_event(CC.CALL_RECONNECTING, "hangup")[0] == CC.CALL_ENDED


def test_reconnecting_not_terminal_but_connected():
    assert CC.is_terminal(CC.CALL_RECONNECTING) is False
    assert CC.is_connected(CC.CALL_RECONNECTING) is True
    assert CC.is_connected(CC.CALL_ACTIVE) is True
    assert CC.is_connected(CC.CALL_RINGING) is False


def test_duration_survives_reconnect():
    t0 = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    rec = CC.new_call_record("c1", 1, 2, "voice", started_at=t0)
    rec = CC.finalize_call(rec, "answer", at=t0 + timedelta(seconds=2))
    rec = CC.finalize_call(rec, "connected", at=t0 + timedelta(seconds=3))
    rec = CC.finalize_call(rec, "reconnect", at=t0 + timedelta(seconds=20))
    assert rec["state"] == CC.CALL_RECONNECTING
    rec = CC.finalize_call(rec, "connected", at=t0 + timedelta(seconds=25))
    rec = CC.finalize_call(rec, "hangup", at=t0 + timedelta(seconds=62))
    assert rec["state"] == CC.CALL_ENDED
    # duration from answered_at (t0+2) to end (t0+62) = 60s, unbroken.
    assert rec["duration_sec"] == 60


def test_live_status_label_covers_all_states():
    for st in (CC.CALL_RINGING, CC.CALL_CONNECTING, CC.CALL_ACTIVE,
               CC.CALL_RECONNECTING, CC.CALL_FAILED, CC.CALL_ENDED):
        bn = CC.live_status_label(st, outgoing=True, lang="bn")
        en = CC.live_status_label(st, outgoing=True, lang="en")
        assert bn and en and bn != en
    # incoming ringing differs from outgoing ringing
    out = CC.live_status_label(CC.CALL_RINGING, outgoing=True, lang="en")
    inc = CC.live_status_label(CC.CALL_RINGING, outgoing=False, lang="en")
    assert out != inc and "Incoming" in inc


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_calls: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
