"""
circle_groups_tests_snippets.py — plain-assert tests for core.logic.circle_groups.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.circle_groups_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import circle_groups as G
from core.logic.circle import REQ_ACCEPTED, REQ_PENDING


# ---- roles + permission matrix ----

def test_role_normalize_and_admin():
    assert G.normalize_role("ADMIN") == "admin"
    assert G.normalize_role("nonsense") == "member"
    assert G.is_admin("admin") is True
    assert G.is_admin("member") is False


def test_capability_matrix():
    # member caps for both
    assert G.has_capability("member", "post") is True
    assert G.has_capability("member", "vote") is True
    assert G.has_capability("member", "react") is True
    # admin-only caps
    assert G.has_capability("member", "add_member") is False
    assert G.has_capability("admin", "add_member") is True
    assert G.has_capability("member", "remove_member") is False
    assert G.has_capability("member", "post_when_announcements_only") is False
    assert G.has_capability("admin", "post_when_announcements_only") is True
    # unknown capability
    assert G.has_capability("admin", "nonsense") is False


# ---- membership FSM ----

def test_membership_fsm():
    s, ch = G.apply_membership_event(G.MEMBERSHIP_ACTIVE, "leave")
    assert s == G.MEMBERSHIP_LEFT and ch is True
    s, ch = G.apply_membership_event(G.MEMBERSHIP_ACTIVE, "remove")
    assert s == G.MEMBERSHIP_REMOVED and ch is True
    s, ch = G.apply_membership_event(G.MEMBERSHIP_LEFT, "rejoin")
    assert s == G.MEMBERSHIP_ACTIVE and ch is True
    # illegal
    s, ch = G.apply_membership_event(G.MEMBERSHIP_ACTIVE, "rejoin")
    assert ch is False and s == G.MEMBERSHIP_ACTIVE


# ---- role FSM + last-admin protection ----

def test_role_promote_demote():
    r, ch, why = G.apply_role_event("member", "promote", actor_role="admin")
    assert r == "admin" and ch is True and why == "ok"
    r, ch, why = G.apply_role_event("admin", "demote", actor_role="admin", admin_count=2)
    assert r == "member" and ch is True


def test_role_change_requires_admin():
    r, ch, why = G.apply_role_event("member", "promote", actor_role="member")
    assert ch is False and why == "not_admin"


def test_cannot_demote_last_admin():
    r, ch, why = G.apply_role_event("admin", "demote", actor_role="admin", admin_count=1)
    assert ch is False and why == "last_admin" and r == "admin"


def test_role_noop():
    r, ch, why = G.apply_role_event("admin", "promote", actor_role="admin")
    assert ch is False and why == "noop"


# ---- add member: CIRCLE-ONLY + size cap ----

def test_add_requires_admin():
    r = G.can_add_member("member", REQ_ACCEPTED, current_size=3)
    assert r["allowed"] is False and r["reason"] == "not_admin"


def test_add_circle_only():
    # candidate not an accepted circle member -> rejected
    r = G.can_add_member("admin", REQ_PENDING, current_size=3)
    assert r["allowed"] is False and r["reason"] == "not_in_circle"
    # accepted circle member -> allowed
    r = G.can_add_member("admin", REQ_ACCEPTED, current_size=3)
    assert r["allowed"] is True


def test_add_blocked_rejected():
    r = G.can_add_member("admin", REQ_ACCEPTED, current_size=3, blocked_either=True)
    assert r["allowed"] is False and r["reason"] == "blocked"


def test_add_already_member():
    r = G.can_add_member("admin", REQ_ACCEPTED, current_size=3, already_member=True)
    assert r["allowed"] is False and r["reason"] == "already_member"


def test_add_size_cap():
    r = G.can_add_member("admin", REQ_ACCEPTED, current_size=5, size_limit=5)
    assert r["allowed"] is False and r["reason"] == "group_full"
    r = G.can_add_member("admin", REQ_ACCEPTED, current_size=4, size_limit=5)
    assert r["allowed"] is True


def test_clamp_size_limit():
    assert G.clamp_size_limit(0) == 1
    assert G.clamp_size_limit(-5) == 1
    assert G.clamp_size_limit(99999) == G.SIZE_LIMIT_MAX
    assert G.clamp_size_limit("bad") == G.SIZE_LIMIT_DEFAULT
    assert G.clamp_size_limit(50) == 50


# ---- remove member + last-admin ----

def test_remove_requires_admin():
    r = G.can_remove_member("member", "member")
    assert r["allowed"] is False and r["reason"] == "not_admin"


def test_remove_self_uses_leave():
    r = G.can_remove_member("admin", "admin", target_is_actor=True)
    assert r["allowed"] is False and r["reason"] == "use_leave"


def test_remove_last_admin_blocked():
    r = G.can_remove_member("admin", "admin", admin_count=1)
    assert r["allowed"] is False and r["reason"] == "last_admin"
    r = G.can_remove_member("admin", "admin", admin_count=2)
    assert r["allowed"] is True


def test_remove_member_ok():
    r = G.can_remove_member("admin", "member")
    assert r["allowed"] is True


# ---- leave ----

def test_leave_member_ok():
    r = G.can_leave("member", admin_count=1, member_count=5)
    assert r["allowed"] is True and r["dissolves"] is False


def test_last_admin_must_promote_first():
    r = G.can_leave("admin", admin_count=1, member_count=5)
    assert r["allowed"] is False and r["reason"] == "promote_before_leaving"


def test_last_admin_last_member_dissolves():
    r = G.can_leave("admin", admin_count=1, member_count=1)
    assert r["allowed"] is True and r["dissolves"] is True


# ---- announcements-only gate ----

def test_announcements_only_gate():
    assert G.can_post("member", announcements_only=False) is True
    assert G.can_post("member", announcements_only=True) is False
    assert G.can_post("admin", announcements_only=True) is True
    assert G.can_post("admin", announcements_only=False) is True


# ---- group envelope (E2E fan-out) ----

def test_build_group_fanout_opaque():
    per = {
        "2": {"ciphertext": "AAAABBBB", "nonce": "Q0NDRA=="},
        "3": {"ciphertext": "EEEEFFFF", "nonce": "R0dHSA=="},
    }
    env = G.build_group_fanout("grp1", sender_id=1, recipient_ids=[2, 3],
                               per_recipient=per, sender_key_id="abc123")
    ok, why = G.validate_group_envelope(env)
    assert ok, why
    assert env["group_id"] == "grp1"
    assert env["content_type"] == "text"
    assert env["ciphertext"]  # top-level carries first recipient's blob
    assert env["per_recipient"] == per


def test_group_envelope_requires_group_id():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2]}
    ok, why = G.validate_group_envelope(env)
    assert ok is False and "group_id" in why


def test_group_envelope_rejects_plaintext_mentions():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "group_id": "g1",
           "mentions": ["Rahim", "Karim"]}  # names, not ids
    ok, why = G.validate_group_envelope(env)
    assert ok is False and "mentions" in why


def test_group_envelope_accepts_id_mentions():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "group_id": "g1", "mentions": [2, "3"]}
    ok, why = G.validate_group_envelope(env)
    assert ok, why
    assert G.mention_targets(env) == [2, 3]


def test_group_envelope_rejects_per_recipient_plaintext():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "group_id": "g1",
           "per_recipient": {"2": {"ciphertext": "x", "nonce": "y",
                                   "plaintext": "hi"}}}
    ok, why = G.validate_group_envelope(env)
    assert ok is False and "plaintext" in why


def test_fanout_rejects_plaintext_smuggle():
    try:
        G.build_group_fanout("g1", 1, [2], {"2": {"ciphertext": "a", "nonce": "b",
                             "body": "leak"}}, "kid")
        assert False, "should have raised"
    except ValueError as e:
        assert "non-opaque" in str(e)


def test_mention_cap():
    env = {"content_type": "text", "ciphertext": "x", "nonce": "y",
           "recipient_ids": [2], "group_id": "g1",
           "mentions": list(range(G.MENTION_MAX + 1))}
    ok, why = G.validate_group_envelope(env)
    assert ok is False


# ---- reactions ----

def test_group_reactions():
    env = {"reactions": {}}
    env, ok = G.add_reaction(env, 2, "👍")
    assert ok is True
    env, ok = G.add_reaction(env, 3, "👍")
    env, ok = G.add_reaction(env, 4, "❤️")
    summary = G.reaction_summary(env)
    assert summary["total"] == 3
    assert summary["counts"]["👍"] == 2
    env, ok = G.remove_reaction(env, 2)
    assert G.reaction_summary(env)["counts"]["👍"] == 1


def test_reaction_rejects_long():
    env = {"reactions": {}}
    env, ok = G.add_reaction(env, 2, "this is way too long to be an emoji")
    assert ok is False


# ---- pinned (admin-only, capped) ----

def test_pin_admin_only():
    assert G.can_pin_group("member", [], "m1") is False
    assert G.can_pin_group("admin", [], "m1") is True


def test_pin_cap_and_apply():
    pins = []
    for i in range(G.PIN_CAP_PER_GROUP):
        pins, ok = G.apply_pin_group("admin", pins, "m%d" % i, pin=True)
        assert ok is True
    pins, ok = G.apply_pin_group("admin", pins, "overflow", pin=True)
    assert ok is False and len(pins) == G.PIN_CAP_PER_GROUP
    # unpin always ok
    pins, ok = G.apply_pin_group("admin", pins, "m0", pin=False)
    assert ok is True and "m0" not in pins
    # member can't pin
    pins2, ok = G.apply_pin_group("member", pins, "x", pin=True)
    assert ok is False


# ---- polls ----

def test_new_poll_and_bounds():
    poll = G.new_poll("p1", "g1", author_id=1, option_count=3,
                      question_ct={"ciphertext": "q", "nonce": "n"},
                      options_ct=[{"ciphertext": "a"}, {"ciphertext": "b"},
                                  {"ciphertext": "c"}])
    assert poll["option_count"] == 3 and poll["closed"] is False


def test_new_poll_rejects_bad_option_count():
    try:
        G.new_poll("p1", "g1", 1, 1, {"ciphertext": "q"}, [{"ciphertext": "a"}])
        assert False
    except ValueError:
        pass
    try:
        # option_count mismatch with options_ct length
        G.new_poll("p1", "g1", 1, 3, {"ciphertext": "q"}, [{"ciphertext": "a"}])
        assert False
    except ValueError:
        pass


def test_new_poll_rejects_plaintext_option():
    try:
        G.new_poll("p1", "g1", 1, 2, {"ciphertext": "q"},
                   [{"ciphertext": "a"}, {"text": "Yes"}])
        assert False
    except ValueError:
        pass


def test_vote_validation():
    poll = {"option_count": 3, "multi": False, "closed": False}
    ok, why = G.validate_vote(poll, [0])
    assert ok is True
    ok, why = G.validate_vote(poll, [0, 1])
    assert ok is False and why == "single_choice_only"
    ok, why = G.validate_vote(poll, [5])
    assert ok is False and why == "choice_out_of_range"
    ok, why = G.validate_vote(poll, [0, 0])
    assert ok is False and why == "duplicate_choice"
    ok, why = G.validate_vote(poll, [])
    assert ok is False and why == "empty_vote"


def test_vote_multi_and_closed():
    poll = {"option_count": 4, "multi": True, "closed": False}
    ok, why = G.validate_vote(poll, [0, 2, 3])
    assert ok is True
    closed = {"option_count": 4, "multi": True, "closed": True}
    ok, why = G.validate_vote(closed, [0])
    assert ok is False and why == "poll_closed"


def test_apply_vote_replaces():
    poll = {"option_count": 3, "multi": False, "closed": False}
    votes = {}
    votes, ok, why = G.apply_vote(votes, poll, voter_id=10, choices=[0])
    assert ok is True and votes[10] == [0]
    # re-vote replaces
    votes, ok, why = G.apply_vote(votes, poll, voter_id=10, choices=[2])
    assert votes[10] == [2]


def test_tally():
    poll = {"option_count": 3, "multi": True, "closed": False}
    votes = {1: [0], 2: [0, 1], 3: [1], 4: [2]}
    r = G.tally_poll(poll, votes)
    assert r["counts"] == [2, 2, 1]
    assert r["total_voters"] == 4
    assert r["total_votes"] == 5
    assert set(r["leading"]) == {0, 1}


def test_close_poll():
    poll = {"id": "p1", "closed": False, "author_id": 7}
    p, ok = G.close_poll(poll, actor_role="member", author_id=7, actor_id=7)
    assert ok is True and p["closed"] is True
    p, ok = G.close_poll(poll, actor_role="member", author_id=7, actor_id=8)
    assert ok is False  # non-author member can't close
    p, ok = G.close_poll(poll, actor_role="admin")
    assert ok is True


# ---- group calls (reuse 1:1 video gate) ----

def test_group_voice_free():
    r = G.can_place_group_call({"plan": "free", "role": "member"}, "voice",
                               member_count=5)
    assert r["allowed"] is True


def test_group_video_requires_premium_initiator():
    r = G.can_place_group_call({"plan": "free", "role": "member"}, "video",
                               member_count=5)
    assert r["allowed"] is False
    assert r["needs_video_plan"] is True
    assert r["reason"] == "video_requires_premium"


def test_group_video_premium_initiator_ok():
    r = G.can_place_group_call({"plan": "premium", "role": "member"}, "video",
                               member_count=5)
    assert r["allowed"] is True and r["group_video"] is True


def test_group_video_referral_unlock():
    r = G.can_place_group_call({"plan": "free", "video_unlocked": True}, "video")
    assert r["allowed"] is True


# ---- invite link (signed, expiring, circle-gated redeem) ----

def test_group_invite_roundtrip():
    secret = "s3cr3t"
    tok = G.make_group_invite("g1", inviter_id=1, secret=secret)
    ok, data = G.parse_group_invite(tok, secret)
    assert ok is True
    assert data["group_id"] == "g1" and data["inviter_id"] == 1


def test_group_invite_bad_signature():
    tok = G.make_group_invite("g1", 1, "right")
    ok, why = G.parse_group_invite(tok, "wrong")
    assert ok is False and why == "bad signature"


def test_group_invite_expired():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    tok = G.make_group_invite("g1", 1, "s", ttl_minutes=10, now=now)
    ok, why = G.parse_group_invite(tok, "s", now=now + timedelta(minutes=20))
    assert ok is False and why == "expired"


def test_group_invite_not_group_tag():
    ok, why = G.parse_group_invite("x.foo.bar", "s")
    assert ok is False


def test_redeem_is_circle_gated():
    # leaked link: joiner is NOT an accepted circle member of the inviter
    r = G.can_redeem_invite(REQ_PENDING, current_size=3)
    assert r["allowed"] is False and r["reason"] == "not_in_circle"
    # accepted circle member redeems fine
    r = G.can_redeem_invite(REQ_ACCEPTED, current_size=3)
    assert r["allowed"] is True


def test_redeem_size_and_already_member():
    r = G.can_redeem_invite(REQ_ACCEPTED, current_size=10, size_limit=10)
    assert r["allowed"] is False and r["reason"] == "group_full"
    r = G.can_redeem_invite(REQ_ACCEPTED, current_size=3, already_member=True)
    assert r["allowed"] is False and r["reason"] == "already_member"


# ---- group creation ----

def test_new_group_seeds_admin():
    gr, cm = G.new_group("g1", creator_id=1, name="  Family  ",
                         description="our family", size_limit=50)
    assert gr["name"] == "Family"
    assert gr["size_limit"] == 50
    assert cm["role"] == "admin" and cm["status"] == "active"
    assert cm["member_id"] == 1


def test_new_group_requires_name():
    try:
        G.new_group("g1", 1, "   ")
        assert False
    except ValueError:
        pass


def test_sanitize_caps():
    info = G.sanitize_group_info("x" * 500, "d" * 5000)
    assert len(info["name"]) == G.GROUP_NAME_MAX
    assert len(info["description"]) == G.GROUP_DESC_MAX


# ---- report + notifications (bilingual) ----

def test_group_report_payload():
    p = G.group_report_payload(1, "g1", "harassment", target_member_id=2)
    assert p["auto_flag"] is True
    assert p["reason"] == "harassment"
    p2 = G.group_report_payload(1, "g1", "weird")
    assert p2["reason"] == "other"


def test_notifications_bilingual():
    en = G.member_added_notification("Ann", "Bob", "en")
    assert "added" in en["body"]
    bn = G.member_added_notification("Ann", "Bob", "bn")
    assert "যুক্ত" in bn["body"]
    assert "Admin" in G.role_label("admin", "en")
    assert "অ্যাডমিন" in G.role_label("admin", "bn")
    assert "Only admins" in G.announcements_mode_notification(True, "en")["body"]
    assert "Premium" in G.group_call_upgrade_prompt("en")["title"]
    assert "প্রিমিয়াম" in G.group_call_upgrade_prompt("bn")["title"]


# ---- §21 destructive confirm copy ----

def test_confirm_copy_has_three_parts_bilingual():
    for action in ("leave", "remove", "demote", "delete_messages",
                   "clear_chat", "report"):
        en = G.confirm_copy(action, lang="en")
        bn = G.confirm_copy(action, lang="bn")
        assert en["title"] and en["body"] is not None and en["confirm"]
        assert bn["title"] and bn["confirm"]
        assert en["title"] != bn["title"]  # actually localized


def test_confirm_copy_personalizes_name():
    en = G.confirm_copy("remove", name="Rahim", lang="en")
    assert "Rahim" in en["body"]
    bn = G.confirm_copy("remove", name="রহিম", lang="bn")
    assert "রহিম" in bn["body"]
    assert G.confirm_copy("remove", lang="en")["body"]  # no name -> generic


def test_confirm_copy_unknown_action_safe_default():
    c = G.confirm_copy("bogus", lang="en")
    assert c["title"] and c["confirm"]


# ---- §21 roster state classifier ----

def test_roster_state_precedence():
    assert G.roster_state([], loaded=False, failed=True) == "error"
    assert G.roster_state([], loaded=False) == "loading"
    assert G.roster_state([], loaded=True) == "empty"
    assert G.roster_state([{"id": 1}], loaded=True) == "ready"
    assert G.roster_state([{"id": 1}], loaded=True, failed=True) == "error"


def test_roster_notices_bilingual():
    assert G.roster_empty_notice("en") and G.roster_empty_notice("bn")
    assert "Try again" in G.roster_error_notice("en")
    assert G.roster_empty_notice("en") != G.roster_empty_notice("bn")


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_groups: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
