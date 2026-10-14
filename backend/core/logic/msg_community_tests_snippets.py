"""
msg_community_tests_snippets.py — plain-assert tests for core.logic.msg_community.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.msg_community_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import msg_community as C
from core.logic.circle import REQ_ACCEPTED, REQ_PENDING


NOW = datetime(2026, 10, 14, 12, 0, 0, tzinfo=timezone.utc)


# ---- community create + mandatory announcements group ----

def test_new_community_seeds_announcements():
    com, ann, creator = C.new_community("com1", 1, "Dhaka Devs", "desc", now=NOW)
    assert com["name"] == "Dhaka Devs"
    assert ann["kind"] == C.GROUP_KIND_ANNOUNCEMENTS
    assert ann["announcements_only"] is True
    assert creator["role"] == C.ROLE_ADMIN
    assert creator["group_id"] == ann["id"]


def test_new_community_requires_name():
    try:
        C.new_community("c", 1, "   ", now=NOW)
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_community_info_caps():
    info = C.sanitize_community_info("x" * 500, "d" * 5000)
    assert len(info["name"]) == C.COMMUNITY_NAME_MAX
    assert len(info["description"]) == C.COMMUNITY_DESC_MAX


def test_topic_group_honours_join_mode_and_announcements():
    g, _ = C.new_community_group("g1", "com1", 1, "General",
                                 kind=C.GROUP_KIND_TOPIC, join_mode="open",
                                 now=NOW)
    assert g["kind"] == C.GROUP_KIND_TOPIC
    assert g["join_mode"] == C.JOIN_OPEN
    assert g["announcements_only"] is False
    # announcements kind forces announcements_only even if arg says False
    ga, _ = C.new_community_group("g2", "com1", 1, "News",
                                  kind=C.GROUP_KIND_ANNOUNCEMENTS,
                                  announcements_only=False, now=NOW)
    assert ga["announcements_only"] is True


def test_group_rules_and_size_admin_only():
    rules, ok = C.set_group_rules("admin", "be kind")
    assert ok and rules == "be kind"
    _, ok2 = C.set_group_rules("member", "nope")
    assert ok2 is False
    sz, ok3 = C.set_group_size_limit("admin", 5000)
    assert ok3 and sz == 1024   # clamped to hard max
    _, ok4 = C.set_group_size_limit("member", 10)
    assert ok4 is False


# ---- groups you're in / can join ----

def test_partition_groups():
    groups = [
        {"id": "g1", "name": "A", "kind": "topic", "join_mode": "open"},
        {"id": "g2", "name": "B", "kind": "topic", "join_mode": "request"},
        {"id": "g3", "name": "C", "kind": "topic", "join_mode": "open"},
    ]
    out = C.partition_groups(groups, my_active_group_ids=["g1"],
                             my_pending_group_ids=["g2"])
    assert [g["id"] for g in out["joined"]] == ["g1"]
    assert [g["id"] for g in out["requested"]] == ["g2"]
    assert len(out["joinable"]) == 1
    assert out["joinable"][0]["action"] == "join"   # g3 is open


# ---- open-join vs request-join ----

def test_open_join_adds_directly():
    g = {"id": "g1", "join_mode": "open", "size_limit": 10}
    r = C.request_to_join(g, current_size=3)
    assert r["allowed"] and r["action"] == "joined"


def test_request_join_creates_request():
    g = {"id": "g1", "join_mode": "request", "size_limit": 10}
    r = C.request_to_join(g, current_size=3)
    assert r["allowed"] and r["action"] == "requested"


def test_join_already_member_and_pending():
    g = {"id": "g1", "join_mode": "request", "size_limit": 10}
    assert C.request_to_join(g, 3, already_member=True)["reason"] == "already_member"
    assert C.request_to_join(g, 3, has_pending=True)["reason"] == "already_requested"


# ---- size cap ----

def test_size_cap_blocks_join():
    g = {"id": "g1", "join_mode": "open", "size_limit": 4}
    r = C.request_to_join(g, current_size=4)
    assert r["allowed"] is False and r["reason"] == "group_full"


# ---- join-request FSM ----

def test_join_fsm():
    s, ch = C.apply_join_event(C.JOIN_PENDING, "approve")
    assert s == C.JOIN_APPROVED and ch
    s, ch = C.apply_join_event(C.JOIN_PENDING, "reject")
    assert s == C.JOIN_REJECTED and ch
    s, ch = C.apply_join_event(C.JOIN_PENDING, "cancel")
    assert s == C.JOIN_CANCELLED and ch
    # illegal (already approved)
    s, ch = C.apply_join_event(C.JOIN_APPROVED, "reject")
    assert ch is False and s == C.JOIN_APPROVED


# ---- admin approve / remove ----

def test_admin_approve_gate():
    ok = C.can_approve_join("admin", current_size=3, group_size_limit=10)
    assert ok["allowed"]
    assert C.can_approve_join("member", 3, 10)["reason"] == "not_admin"
    assert C.can_approve_join("admin", 10, 10)["reason"] == "group_full"
    assert C.can_approve_join("admin", 3, 10, request_state=C.JOIN_APPROVED)["reason"] == "not_pending"


def test_remove_member_gate():
    assert C.can_remove_community_member("admin", "member")["allowed"]
    assert C.can_remove_community_member("member", "member")["reason"] == "not_admin"
    assert C.can_remove_community_member("admin", "member", target_is_actor=True)["reason"] == "use_leave"
    assert C.can_remove_community_member("admin", "admin", admin_count=1)["reason"] == "last_admin"
    assert C.can_remove_community_member("admin", "admin", admin_count=2)["allowed"]


# ---- announcements-only post gate ----

def test_announcements_post_gate():
    ann = {"announcements_only": True}
    topic = {"announcements_only": False}
    assert C.can_post_in_group("admin", ann) is True
    assert C.can_post_in_group("member", ann) is False   # members can't post
    assert C.can_post_in_group("member", topic) is True  # normal topic: anyone
    assert "Only admins" in C.post_blocked_reason("en")


# ---- member card: name+photo always, phone hidden by default ----

def test_member_card_phone_hidden_by_default():
    m = {"member_id": 7, "name": "Rahim", "photo_ref": "blob://x", "phone": "017..."}
    card = C.member_card(m, viewer_id=9)
    assert card["name"] == "Rahim"
    assert card["photo_ref"] == "blob://x"
    assert card["phone"] is None          # hidden by default
    assert card["phone_hidden"] is True


def test_member_card_phone_shown_when_opted_in():
    m = {"member_id": 7, "name": "Rahim", "photo_ref": "b", "phone": "017",
         "show_phone": True}
    card = C.member_card(m, viewer_id=9)
    assert card["phone"] == "017" and card["phone_hidden"] is False


def test_member_sees_own_phone():
    m = {"member_id": 7, "name": "Rahim", "phone": "017"}  # not opted in
    card = C.member_card(m, viewer_id=7)                   # viewing self
    assert card["phone"] == "017"


def test_set_show_phone_toggle():
    m = {"member_id": 7, "name": "R"}
    assert C.member_card(C.set_show_phone(m, True), viewer_id=9)["phone_hidden"] is False
    assert C.member_card(C.set_show_phone(m, False), viewer_id=9)["phone_hidden"] is True


# ---- who-can-message setting ----

def test_who_can_msg_default_and_normalize():
    assert C.normalize_who_can_msg(None) == C.WHO_EVERYONE   # default everyone
    assert C.normalize_who_can_msg("NOBODY") == C.WHO_NOBODY
    assert C.normalize_who_can_msg("garbage") == C.WHO_EVERYONE


# ---- can_direct_message: the consent flow ----

def test_direct_when_in_circle():
    r = C.can_direct_message(rel_state=REQ_ACCEPTED,
                             recipient_who_can_msg="everyone")
    assert r["allowed"] and r["route"] == "direct" and r["calls_allowed"] is True


def test_direct_when_prior_request_accepted():
    r = C.can_direct_message(rel_state=REQ_PENDING,
                             prior_request_state=C.MSGREQ_ACCEPTED,
                             recipient_who_can_msg="everyone")
    assert r["route"] == "direct" and r["calls_allowed"] is True


def test_first_message_outside_circle_is_message_request():
    # not in circle, no prior accepted request, recipient allows everyone
    r = C.can_direct_message(rel_state=None, prior_request_state=None,
                             recipient_who_can_msg="everyone")
    assert r["allowed"] is True
    assert r["route"] == "message_request"       # NOT direct
    assert r["reason"] == "first_contact_outside_circle"
    assert r["calls_allowed"] is False           # no calls before acceptance


def test_who_nobody_blocks_even_request():
    r = C.can_direct_message(rel_state=None, prior_request_state=None,
                             recipient_who_can_msg="nobody")
    assert r["allowed"] is False
    assert r["route"] is None and r["reason"] == "who_nobody"


def test_blocked_beats_everything():
    r = C.can_direct_message(rel_state=REQ_ACCEPTED,
                             recipient_who_can_msg="everyone",
                             blocked_either=True)
    assert r["allowed"] is False and r["reason"] == "blocked"


def test_not_in_same_community_refused():
    r = C.can_direct_message(rel_state=None, recipient_who_can_msg="everyone",
                             same_community=False)
    assert r["allowed"] is False and r["reason"] == "not_in_community"


# ---- calls gated before acceptance ----

def test_no_calls_before_acceptance():
    assert C.can_call(rel_state=None)["allowed"] is False
    assert C.can_call(rel_state=REQ_ACCEPTED)["allowed"] is True
    assert C.can_call(prior_request_state=C.MSGREQ_ACCEPTED)["allowed"] is True
    assert C.can_call(rel_state=REQ_ACCEPTED, blocked_either=True)["allowed"] is False


# ---- message-request FSM + record ----

def test_msgreq_fsm():
    s, ch = C.apply_msgreq_event(C.MSGREQ_PENDING, "accept")
    assert s == C.MSGREQ_ACCEPTED and ch
    s, ch = C.apply_msgreq_event(C.MSGREQ_PENDING, "decline")
    assert s == C.MSGREQ_DECLINED and ch
    s, ch = C.apply_msgreq_event(C.MSGREQ_PENDING, "block")
    assert s == C.MSGREQ_BLOCKED and ch
    s, ch = C.apply_msgreq_event(C.MSGREQ_BLOCKED, "unblock")
    assert s == C.MSGREQ_DECLINED and ch
    # accept then block is allowed
    s, ch = C.apply_msgreq_event(C.MSGREQ_ACCEPTED, "block")
    assert s == C.MSGREQ_BLOCKED and ch
    # illegal
    s, ch = C.apply_msgreq_event(C.MSGREQ_ACCEPTED, "accept")
    assert ch is False


def test_new_message_request_holds_ciphertext():
    row = C.new_message_request(5, 9, "com1", "CT", "NONCE", "k1", now=NOW)
    assert row["state"] == C.MSGREQ_PENDING
    assert row["first_ciphertext"] == "CT" and row["first_nonce"] == "NONCE"
    assert "body" not in row and "text" not in row   # server never sees plaintext


def test_report_sender():
    p = C.report_sender(9, 5, "com1", "harassment", also_block=True)
    assert p["auto_flag"] is True and p["also_block"] is True
    assert C.report_sender(9, 5, "com1", "weird")["reason"] == "other"


# ---- rate limit ----

def test_rate_limit_allows_under_cap():
    times = [(NOW - timedelta(minutes=m)).isoformat() for m in (1, 5, 10)]
    r = C.check_msgreq_rate(times, now=NOW)
    assert r["allowed"] is True and r["count"] == 3 and r["remaining"] == 2


def test_rate_limit_blocks_at_cap():
    times = [(NOW - timedelta(minutes=m)).isoformat() for m in (1, 2, 3, 4, 5)]
    r = C.check_msgreq_rate(times, now=NOW)   # 5 == MSGREQ_RATE_MAX
    assert r["allowed"] is False and r["remaining"] == 0
    assert r["retry_after_sec"] > 0


def test_rate_limit_ignores_outside_window():
    # 5 old (2h ago) + 1 recent → only 1 counts
    old = [(NOW - timedelta(hours=2, minutes=m)).isoformat() for m in range(5)]
    recent = [(NOW - timedelta(minutes=1)).isoformat()]
    r = C.check_msgreq_rate(old + recent, now=NOW)
    assert r["count"] == 1 and r["allowed"] is True


def test_rate_limited_message_bilingual():
    assert "min" in C.rate_limited_message(300, "en")
    assert "মিনিট" in C.rate_limited_message(300, "bn")


# ---- bilingual labels / notifications ----

def test_labels_bilingual():
    assert C.join_mode_label("open", "en") == "Anyone can join"
    assert "অনুমোদন" in C.join_mode_label("request", "bn")
    assert C.who_can_msg_label("nobody", "en") == "Nobody"
    assert C.who_can_msg_label("everyone", "bn") == "সবাই"
    assert "circle" in C.message_request_banner("en")
    assert "community messages" in C.who_nobody_blocked_message("en")
    assert "wants to join" in C.join_requested_notification("Ann", "General", "en")["body"]
    assert "member of" in C.join_approved_notification("General", "en")["body"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"msg_community: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
