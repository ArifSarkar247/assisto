"""
msg_messenger_ui_tests_snippets.py — plain-assert tests for
core.logic.msg_messenger_ui.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.msg_messenger_ui_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import msg_messenger_ui as M


_NOW = datetime(2026, 10, 14, 12, 0, 0, tzinfo=timezone.utc)


# ---- 1. STARRED ----

def test_star_build_and_jump():
    s = M.build_star(7, "member", 42, "msg_99", now=_NOW)
    assert s["user_id"] == 7
    assert s["chat_kind"] == "member"
    assert s["chat_id"] == "42"
    assert s["message_id"] == "msg_99"
    j = M.star_jump_target(s)
    assert j == {"chat_kind": "member", "chat_id": "42", "message_id": "msg_99"}


def test_star_chat_kind_normalised():
    assert M.normalize_chat_ref("GROUP", 5)["chat_kind"] == "group"
    assert M.normalize_chat_ref("bogus", 5)["chat_kind"] == "member"


# ---- 2. LINKED DEVICES — single-use + short TTL ----

def test_link_token_minted_fresh():
    out = M.mint_link_token(3, platform="web", base_url="https://x", now=_NOW)
    assert out["ttl_sec"] == M.LINK_TOKEN_TTL_SEC
    assert out["record"]["used"] is False
    assert out["qr_payload"]["kind"] == "assisto_device_link"
    assert out["qr_payload"]["token"] == out["record"]["token"]
    assert M.link_token_state(out["record"], now=_NOW) == "ok"


def test_link_token_expires():
    out = M.mint_link_token(3, now=_NOW)
    later = _NOW + timedelta(seconds=M.LINK_TOKEN_TTL_SEC + 1)
    assert M.link_token_state(out["record"], now=later) == "expired"


def test_link_token_single_use():
    out = M.mint_link_token(3, now=_NOW)
    used = M.consume_link_token(out["record"])
    assert used["used"] is True
    assert M.link_token_state(used, now=_NOW) == "used"


def test_confirm_link_requires_fresh_token_and_cap():
    mobile = [{"platform": "android", "role": "linked", "revoked": False}]
    out = M.mint_link_token(3, platform="web", now=_NOW)
    ok, why = M.can_confirm_link(out["record"], mobile, "web", now=_NOW)
    assert ok is True and why == "ok"
    # used token rejected
    used = M.consume_link_token(out["record"])
    ok2, why2 = M.can_confirm_link(used, mobile, "web", now=_NOW)
    assert ok2 is False and why2 == "used"


def test_confirm_link_web_after_mobile_gate():
    out = M.mint_link_token(3, platform="web", now=_NOW)
    # no mobile device yet -> web link blocked by circle_extras order rule
    ok, why = M.can_confirm_link(out["record"], [], "web", now=_NOW)
    assert ok is False and why == "web_after_mobile"


def test_linked_device_view_no_key():
    row = M.linked_device_view(
        {"device_id": "d1", "name": "Office PC", "platform": "web",
         "public_key_id": "pk", "linked_at": _NOW.isoformat()}, lang="en")
    assert row["platform_label"] == "Web / Desktop"
    assert "public_key_id" not in row and "private_key" not in row


# ---- 3a. CALL LINK — expiring + video premium-gated ----

def test_call_link_voice_free():
    r = M.mint_call_link({"id": 1, "plan": "free"}, kind="voice", base_url="https://x",
                         now=_NOW)
    assert r["ok"] is True
    assert r["url"].endswith(r["record"]["token"])
    assert M.call_link_joinable(r["record"], now=_NOW) is True


def test_call_link_video_premium_gated():
    free = M.mint_call_link({"id": 1, "plan": "free"}, kind="video", now=_NOW)
    assert free["ok"] is False
    assert free["reason"] == "video_requires_premium"
    assert free["upgrade_required"] is True
    prem = M.mint_call_link({"id": 1, "plan": "premium"}, kind="video", now=_NOW)
    assert prem["ok"] is True


def test_call_link_expires():
    r = M.mint_call_link({"id": 1, "plan": "free"}, kind="voice",
                         ttl_sec=120, now=_NOW)
    later = _NOW + timedelta(seconds=121)
    assert M.call_link_joinable(r["record"], now=later) is False


# ---- 3b. SCHEDULE CALL ----

def test_schedule_call_builds_reminders():
    when = _NOW + timedelta(hours=2)
    out = M.build_scheduled_call({"id": 1, "plan": "free"}, [2, 3], when,
                                 kind="voice", title="Team sync", now=_NOW)
    rec = out["record"]
    assert rec["invitee_ids"] == [2, 3]
    assert rec["call_kind"] == "voice"
    # a reminder per invitee + organiser (3 total)
    assert len(out["reminders"]) == 3
    assert all(r["remind_at"] == rec["remind_at"] for r in out["reminders"])


def test_schedule_call_video_premium_gated():
    when = _NOW + timedelta(hours=2)
    try:
        M.build_scheduled_call({"id": 1, "plan": "free"}, [2], when,
                               kind="video", now=_NOW)
        assert False, "expected ValueError"
    except ValueError as e:
        assert "video_requires_premium" in str(e)


def test_schedule_call_needs_invitees_and_future():
    when = _NOW + timedelta(hours=2)
    ok, why = M.validate_scheduled_call({"id": 1, "plan": "free"}, [], when,
                                        now=_NOW)
    assert ok is False and why == "no_invitees"
    ok2, why2 = M.validate_scheduled_call({"id": 1, "plan": "free"}, [2],
                                          _NOW - timedelta(hours=1), now=_NOW)
    assert ok2 is False  # in the past -> too soon


# ---- 3c. NEW GROUP CALL (video premium caller-gated) ----

def test_group_call_voice_free():
    plan = M.plan_group_call(
        {"id": 1, "plan": "free"},
        [{"id": 2, "accepted": True}, {"id": 3, "accepted": True}],
        kind="voice")
    assert plan["allowed"] is True
    assert sorted(plan["dialled"]) == [2, 3]


def test_group_call_video_premium_gated():
    plan = M.plan_group_call(
        {"id": 1, "plan": "free"},
        [{"id": 2, "accepted": True}], kind="video")
    assert plan["allowed"] is False
    assert plan["reason"] == "video_requires_premium"
    assert plan["upgrade_required"] is True
    ok = M.plan_group_call(
        {"id": 1, "plan": "premium"},
        [{"id": 2, "accepted": True}], kind="video")
    assert ok["allowed"] is True and ok["dialled"] == [2]


def test_group_call_skips_not_connected():
    plan = M.plan_group_call(
        {"id": 1, "plan": "free"},
        [{"id": 2, "accepted": True}, {"id": 3, "accepted": False},
         {"id": 4, "blocked": True, "accepted": True}],
        kind="voice")
    assert plan["allowed"] is True
    assert plan["dialled"] == [2]
    assert {s["id"] for s in plan["skipped"]} == {3, 4}


# ---- 4. REPORT-LAST-5 (reporter snapshot; server never decrypts) ----

def test_report_snapshot_capped_to_last_5():
    msgs = [{"message_id": i, "text": f"m{i}", "at": _NOW} for i in range(8)]
    snap = M.sanitize_report_snapshot(msgs)
    assert len(snap) == 5
    # last 5 kept (ids 3..7)
    assert [m["message_id"] for m in snap] == ["3", "4", "5", "6", "7"]


def test_report_snapshot_keeps_only_safe_fields():
    snap = M.sanitize_report_snapshot(
        [{"message_id": 1, "text": "hi", "sender_name": "A", "from_me": True,
          "content_type": "text", "at": _NOW,
          "ciphertext": "SHOULD_NOT_APPEAR", "private_key": "x"}])
    row = snap[0]
    assert set(row.keys()) == {"message_id", "from_me", "sender_name", "at",
                               "content_type", "text"}
    assert "ciphertext" not in row and "private_key" not in row


def test_build_chat_report_attaches_reporter_snapshot():
    out = M.build_chat_report(
        report_id="r1", reporter_id=7, target_user_id=9,
        categories=["harassment"],
        snapshot_messages=[{"message_id": 1, "text": "bad", "at": _NOW}],
        note="please review", now=_NOW)
    rpt = out["report"]
    assert rpt["valid"] is True
    assert rpt["target_kind"] == "person"
    assert rpt["target_id"] == 9
    assert rpt["snapshot_source"] == "reporter_device"
    assert len(rpt["snapshot"]) == 1
    assert rpt["snapshot"][0]["text"] == "bad"


# ---- 5. READ-ALL ----

def test_read_all_plan():
    plan = M.read_all_plan([
        {"chat_kind": "member", "chat_id": 1},
        {"chat_kind": "group", "chat_id": 2},
        {"chat_kind": "member", "chat_id": None},  # dropped
    ])
    assert plan["count"] == 2
    assert plan["marked"][0] == {"chat_kind": "member", "chat_id": "1"}


# ---- 6. CUSTOM LISTS ----

def test_list_name_validation():
    assert M.validate_list_name("Family")[0] is True
    assert M.validate_list_name("")[0] is False
    assert M.validate_list_name("All")[1] == "reserved_name"
    assert M.validate_list_name("x" * 60)[1] == "name_too_long"


def test_build_and_mutate_list():
    lst = M.build_chat_list(7, "Work", [1, 2, 2, 3])
    assert lst["member_refs"] == [1, 2, 3]   # deduped
    added = M.list_add_members(lst["member_refs"], [3, 4])
    assert added == [1, 2, 3, 4]
    removed = M.list_remove_members(added, [1, 4])
    assert removed == [2, 3]


def test_hub_chips_include_user_lists():
    chips = M.hub_filter_chips(
        [{"id": 11, "name": "Family", "member_refs": [1, 2]}], lang="en")
    ids = [c["id"] for c in chips]
    assert ids[:4] == ["all", "unread", "favourites", "groups"]
    assert ids[-1] == "list:11"
    assert chips[-1]["member_count"] == 2


# ---- 7. BROADCAST — circle gate (recipient must have sender accepted) ----

def test_broadcast_only_to_mutual_accepted():
    # recipients 2,3 ; but only 2 has the sender in THEIR accepted circle
    ok, reason, plan = M.broadcast_send_plan(
        sender_id=1, recipient_ids=[2, 3], mutual_accepted_ids=[2],
        broadcast_id="b1", base_client_msg_id="c1")
    assert ok is False
    assert reason == "not_connected"


def test_broadcast_fanout_individual_messages():
    ok, reason, plan = M.broadcast_send_plan(
        sender_id=1, recipient_ids=[2, 3], mutual_accepted_ids=[2, 3],
        broadcast_id="b1", base_client_msg_id="c1")
    assert ok is True
    assert len(plan) == 2
    # distinct per-recipient dedupe ids; no shared server id
    assert {p["client_msg_id"] for p in plan} == {"c1:2", "c1:3"}
    assert all(p["is_broadcast"] for p in plan)


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"msg_messenger_ui: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
