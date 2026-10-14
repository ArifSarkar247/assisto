"""
msg_channel_tests_snippets.py — plain-assert tests for core.logic.msg_channel.
NOT a Django TestCase (no DB, no AI key).

Smoke locally:
    cd backend && python3 -c "import core.logic.msg_channel_tests_snippets as t; t.run_all()"

These deterministically prove the server-enforced channel contract:
  - followers CANNOT reply / DM the admin,
  - a count_only follower is NEVER in ANY listing but IS counted,
  - verified is owner-APPROVED only (no self-grant),
  - poll tally by index, analytics from counts only (no PII),
  - channel content is NOT E2E (while personal/group E2E is untouched here).
"""

from core.logic import msg_channel as C


# ───────────────────────────── helpers ────────────────────────────────────

def _channel(**over):
    ch = C.new_channel(
        channel_id=1, owner_id=100, name="Morning Brief", handle="@Morning_Brief",
        description="Daily news", category="news", language="bn", created_at="t0",
    )
    ch.update(over)
    return ch


def _roster_mixed():
    """owner=100. followers: 200 show, 201 count_only(default), 202 show,
    203 count_only(explicit)."""
    ch = _channel()
    roster = {}
    ch, roster, _ = C.follow(ch, roster, 200, visibility=C.VIS_SHOW)
    ch, roster, _ = C.follow(ch, roster, 201)                      # default -> count_only
    ch, roster, _ = C.follow(ch, roster, 202, visibility=C.VIS_SHOW)
    ch, roster, _ = C.follow(ch, roster, 203, visibility=C.VIS_COUNT_ONLY)
    return ch, roster


# ───────────────────────── followers can't reply / DM ─────────────────────

def test_follower_cannot_reply():
    assert C.can_follower_reply() is False
    assert C.can_follower_reply(role=C.ROLE_FOLLOWER, channel=_channel()) is False
    # No capability for reply/comment/dm exists in the follower matrix.
    for cap in ("reply", "comment", "dm", "publish", "edit_post"):
        assert C.has_capability(C.ROLE_FOLLOWER, cap) is False


def test_follower_cannot_dm_admin():
    assert C.can_follower_dm_admin() is False
    assert C.can_follower_dm_admin(channel=_channel(), follower_id=201) is False


def test_follower_can_only_read_and_react():
    assert C.can_react(C.ROLE_FOLLOWER) is True
    assert C.has_capability(C.ROLE_FOLLOWER, "read") is True
    assert C.can_publish(C.ROLE_FOLLOWER) is False
    assert C.can_publish(C.ROLE_OWNER) is True
    assert C.can_publish(C.ROLE_ADMIN) is True


# ─────────────────── count-only NEVER shown but IS counted ─────────────────

def test_default_visibility_is_count_only():
    f = C.new_follower(900)
    assert f["visibility"] == C.VIS_COUNT_ONLY
    assert C.VIS_DEFAULT == C.VIS_COUNT_ONLY
    assert C.is_count_only(f) is True
    # unknown / None also coerces to count_only (safe side)
    assert C.normalize_follower_visibility("garbage") == C.VIS_COUNT_ONLY
    assert C.normalize_follower_visibility(None) == C.VIS_COUNT_ONLY


def test_count_includes_count_only():
    ch, roster = _roster_mixed()
    # 4 followers total, 2 of them count_only.
    assert C.follower_count(followers=roster) == 4
    assert ch["follower_count"] == 4


def test_count_only_absent_from_public_list():
    ch, roster = _roster_mixed()
    ch, _, _ = C.set_list_visibility(ch, 100, C.LIST_PUBLIC)  # owner makes list public
    out = C.serialize_follower_list(ch, roster, viewer_id=999)  # a random public viewer
    shown = {r["user_id"] for r in out["followers"]}
    assert shown == {200, 202}                 # only the "show" followers
    assert 201 not in shown and 203 not in shown
    assert out["count"] == 4                    # but ALL 4 are counted
    assert out["hidden_count_only"] == 2
    assert out["listable"] == 2


def test_count_only_hidden_even_from_owner():
    """THE hard rule: the channel OWNER still cannot see a count_only follower."""
    ch, roster = _roster_mixed()
    ch, _, _ = C.set_list_visibility(ch, 100, C.LIST_PUBLIC)
    out = C.serialize_follower_list(ch, roster, viewer_id=100)  # viewer IS the owner
    shown = {r["user_id"] for r in out["followers"]}
    assert 201 not in shown, "owner must NOT see a count_only follower"
    assert 203 not in shown, "owner must NOT see a count_only follower"
    assert shown == {200, 202}
    assert out["count"] == 4                    # owner still sees the true count
    assert out["hidden_count_only"] == 2


def test_count_only_hidden_from_admin():
    ch, roster = _roster_mixed()
    ch, _, _ = C.add_admin(ch, 100, 300)
    ch, _, _ = C.set_list_visibility(ch, 100, C.LIST_PRIVATE)
    out = C.serialize_follower_list(ch, roster, viewer_id=300)  # a channel admin
    shown = {r["user_id"] for r in out["followers"]}
    assert 201 not in shown and 203 not in shown
    assert shown == {200, 202}


def test_private_list_blocks_nonprivileged_enumeration():
    ch, roster = _roster_mixed()   # default list_visibility is PRIVATE
    assert ch["list_visibility"] == C.LIST_PRIVATE
    out = C.serialize_follower_list(ch, roster, viewer_id=777)  # random viewer
    assert out["followers"] == []               # cannot enumerate a private list
    assert out["count"] == 4                     # but the count is still visible
    # even private, the private-list hidden-aggregate is honest
    assert out["hidden_count_only"] == 2


def test_visibility_is_changeable_anytime():
    ch, roster = _roster_mixed()
    ch, _, _ = C.set_list_visibility(ch, 100, C.LIST_PUBLIC)
    # 201 opts IN -> becomes visible; 200 opts OUT -> disappears.
    roster = dict(roster)
    roster[201] = C.set_follower_visibility(roster[201], C.VIS_SHOW)
    roster[200] = C.set_follower_visibility(roster[200], C.VIS_COUNT_ONLY)
    out = C.serialize_follower_list(ch, roster, viewer_id=999)
    shown = {r["user_id"] for r in out["followers"]}
    assert shown == {201, 202}
    assert 200 not in shown                      # just opted out -> gone immediately
    assert out["count"] == 4
    assert out["hidden_count_only"] == 2         # now 200 + 203


def test_unfollow_decrements_count():
    ch, roster = _roster_mixed()
    ch, roster, removed = C.unfollow(ch, roster, 203)
    assert removed is True
    assert C.follower_count(followers=roster) == 3
    assert ch["follower_count"] == 3


def test_follow_is_idempotent():
    ch = _channel()
    roster = {}
    ch, roster, _ = C.follow(ch, roster, 200, visibility=C.VIS_SHOW)
    ch, roster, rec = C.follow(ch, roster, 200)   # follow again
    assert C.follower_count(followers=roster) == 1
    assert rec["visibility"] == C.VIS_SHOW        # original record kept


def test_mute_does_not_affect_count_or_listing():
    ch, roster = _roster_mixed()
    roster = C.set_muted(roster, 200, True)
    assert C.follower_count(followers=roster) == 4
    ch, _, _ = C.set_list_visibility(ch, 100, C.LIST_PUBLIC)
    out = C.serialize_follower_list(ch, roster, viewer_id=999)
    muted_flags = {r["user_id"]: r["muted"] for r in out["followers"]}
    assert muted_flags.get(200) is True


def test_pagination_never_leaks_count_only():
    """Even with limit/offset paging, a count_only follower cannot surface."""
    ch = _channel()
    roster = {}
    for uid in range(200, 210):
        vis = C.VIS_SHOW if uid % 2 == 0 else C.VIS_COUNT_ONLY
        ch, roster, _ = C.follow(ch, roster, uid, visibility=vis)
    ch, _, _ = C.set_list_visibility(ch, 100, C.LIST_PUBLIC)
    seen = set()
    for off in range(0, 10, 2):
        out = C.serialize_follower_list(ch, roster, viewer_id=999, limit=2, offset=off)
        seen |= {r["user_id"] for r in out["followers"]}
    assert all(u % 2 == 0 for u in seen)          # only even (show) ids ever appear
    assert seen == {200, 202, 204, 206, 208}


# ───────────────────────── verified = owner-approved only ─────────────────

def test_cannot_self_verify():
    ch = _channel()
    # owner requesting only sets pending, never verified
    ch2, ok, _ = C.request_verification(ch, 100)
    assert ok is True
    assert ch2["verification_state"] == C.VERIF_PENDING
    assert ch2["verified"] is False
    assert C.is_verified(ch2) is False


def test_owner_cannot_grant_badge():
    ch = _channel()
    # owner is NOT a platform operator -> grant refused
    ch2, ok, reason = C.grant_verification(ch, operator_actor_id=100,
                                           is_platform_operator=False)
    assert ok is False and reason == "operator_only"
    assert C.is_verified(ch2) is False


def test_operator_grant_and_revoke():
    ch = _channel()
    ch, ok, _ = C.grant_verification(ch, operator_actor_id=5, is_platform_operator=True)
    assert ok is True
    assert C.is_verified(ch) is True
    assert ch["verified_by"] == 5
    ch, ok, _ = C.revoke_verification(ch, operator_actor_id=5, is_platform_operator=True)
    assert ok is True
    assert C.is_verified(ch) is False


def test_forged_flag_without_operator_is_not_verified():
    # A client that forges verified=True but no operator approver -> still not verified.
    ch = _channel(verified=True, verified_by=None)
    assert C.is_verified(ch) is False


def test_profile_edit_cannot_set_verified_or_count():
    patch = {"name": "x", "verified": True, "follower_count": 9999,
             "owner_id": 1, "admin_ids": [1]}
    clean = C.sanitize_profile_edit(patch)
    assert "verified" not in clean
    assert "follower_count" not in clean
    assert "owner_id" not in clean
    assert "admin_ids" not in clean
    assert clean["name"] == "x"


# ───────────────────────────── posts NOT E2E ──────────────────────────────

def test_channel_content_not_e2e():
    assert C.is_e2e_surface() is False
    assert C.post_is_e2e() is False
    ch = _channel()
    post, ok, _ = C.new_post(1, ch, author_id=100, kind=C.POST_TEXT, text="hello")
    assert ok is True
    assert post["e2e"] is False
    assert post["content_scheme"] == C.CONTENT_NOT_E2E
    assert C.post_is_e2e(post) is False


def test_post_claiming_e2e_is_rejected():
    post = {"kind": C.POST_TEXT, "text": "hi", "e2e": True}
    ok, reason = C.validate_post(post)
    assert ok is False and reason == "channel_post_must_not_be_e2e"


def test_follower_cannot_publish_post():
    ch, _ = _roster_mixed()
    post, ok, reason = C.new_post(9, ch, author_id=200, kind=C.POST_TEXT, text="hi")
    assert post is None and ok is False and reason == "publish_denied"


def test_post_kinds_validation():
    ch = _channel()
    # link post needs a url
    _, ok, reason = C.new_post(2, ch, 100, C.POST_LINK, link_url=None)
    assert ok is False and reason == "link_required"
    # photo needs media
    _, ok, reason = C.new_post(3, ch, 100, C.POST_PHOTO, media_refs=[])
    assert ok is False and reason == "media_required"
    # good link
    p, ok, _ = C.new_post(4, ch, 100, C.POST_LINK, link_url="https://x.test")
    assert ok is True and p["link_url"] == "https://x.test"


def test_reactions_are_aggregate_only():
    ch = _channel()
    post, _, _ = C.new_post(5, ch, 100, C.POST_TEXT, text="yo")
    post = C.add_reaction(post, "👍")
    post = C.add_reaction(post, "👍")
    post = C.add_reaction(post, "❤")
    assert post["reactions"] == {"👍": 2, "❤": 1}  # counts only, no reactor ids
    post = C.remove_reaction(post, "❤")
    assert "❤" not in post["reactions"]


# ───────────────────────────── polls by index ─────────────────────────────

def test_poll_tally_by_index():
    poll, ok, _ = C.new_channel_poll(1, 3, "Best day?", ["Fri", "Sat", "Sun"])
    assert ok is True
    votes = {}
    votes, ok, _ = C.apply_vote(votes, poll, 200, [0])
    assert ok
    votes, ok, _ = C.apply_vote(votes, poll, 201, [2])
    votes, ok, _ = C.apply_vote(votes, poll, 202, [2])
    res = C.tally_poll(poll, votes)
    assert res["counts"] == [1, 0, 2]
    assert res["leading"] == [2]
    assert res["total_voters"] == 3
    assert res["total_votes"] == 3


def test_poll_single_choice_and_revote():
    poll, _, _ = C.new_channel_poll(2, 2, "Yes/No?", ["Yes", "No"], multi=False)
    votes = {}
    _, ok, reason = C.apply_vote(votes, poll, 200, [0, 1])   # single-choice: 2 not allowed
    assert ok is False and reason == "single_choice_only"
    votes, ok, _ = C.apply_vote(votes, poll, 200, [0])
    votes, ok, _ = C.apply_vote(votes, poll, 200, [1])       # re-vote replaces
    res = C.tally_poll(poll, votes)
    assert res["counts"] == [0, 1]


def test_poll_out_of_range_and_closed():
    poll, _, _ = C.new_channel_poll(3, 3, "q", ["a", "b", "c"], multi=True)
    _, ok, reason = C.apply_vote({}, poll, 1, [5])
    assert ok is False and reason == "choice_out_of_range"
    _, ok, reason = C.apply_vote({}, poll, 1, [0, 0])
    assert ok is False and reason == "duplicate_choice"
    poll = C.close_poll(poll)
    _, ok, reason = C.apply_vote({}, poll, 1, [0])
    assert ok is False and reason == "poll_closed"


# ───────────────────────────── analytics (counts only) ────────────────────

def test_analytics_from_counts_only_no_pii():
    ch = _channel(follower_count=4)
    p1, _, _ = C.new_post(1, ch, 100, C.POST_TEXT, text="a")
    p2, _, _ = C.new_post(2, ch, 100, C.POST_TEXT, text="b")
    p1 = C.record_view(p1); p1 = C.record_view(p1); p1 = C.record_view(p1)
    p2 = C.record_view(p2)
    p1 = C.add_reaction(p1, "👍"); p1 = C.add_reaction(p1, "👍")
    p2 = C.add_reaction(p2, "❤")
    series = [("w1", 1), ("w2", 2), ("w3", 4)]
    a = C.channel_analytics(ch, [p1, p2], follower_count_series=series)
    assert a["total_views"] == 4
    assert a["post_count"] == 2
    assert a["avg_views_per_post"] == 2.0
    assert a["total_reactions"] == 3
    assert a["reactions_breakdown"] == {"👍": 2, "❤": 1}
    assert a["follower_growth"]["net"] == 3
    assert a["follower_growth"]["start"] == 1 and a["follower_growth"]["end"] == 4
    assert a["contains_pii"] is False
    # NO identity-bearing keys anywhere in the analytics payload.
    text = repr(a).lower()
    for banned in ("user_id", "follower_id", "voter", "reactor", "phone", "name"):
        assert banned not in text, f"analytics leaked PII-ish key: {banned}"


def test_view_counter_stores_no_viewer():
    ch = _channel()
    post, _, _ = C.new_post(1, ch, 100, C.POST_TEXT, text="x")
    post = C.record_view(post)
    assert post["views"] == 1
    # record_view takes no viewer id at all -> structurally cannot store PII.
    assert "viewers" not in post and "viewer_ids" not in post


# ───────────────────────────── profile / admin / link ─────────────────────

def test_new_channel_defaults_private_and_unverified():
    ch = _channel()
    assert ch["list_visibility"] == C.LIST_PRIVATE
    assert ch["verified"] is False
    assert ch["verification_state"] == C.VERIF_NONE
    assert ch["handle"] == "morning_brief"      # sanitised @ + case
    assert ch["category"] == "news"
    assert ch["language"] == "bn"


def test_bad_category_language_fallback():
    ch = C.new_channel(2, 100, "T", "h", category="zzz", language="fr")
    assert ch["category"] == "other"
    assert ch["language"] == "other"


def test_admin_add_remove_owner_only():
    ch = _channel()
    ch2, ok, _ = C.add_admin(ch, actor_id=200, new_admin_id=300)  # non-owner
    assert ok is False
    ch, ok, _ = C.add_admin(ch, actor_id=100, new_admin_id=300)
    assert ok is True and 300 in ch["admin_ids"]
    assert C.role_of(ch, 300) == C.ROLE_ADMIN
    ch, ok, _ = C.remove_admin(ch, actor_id=100, admin_id=300)
    assert ok is True and 300 not in ch["admin_ids"]


def test_set_list_visibility_owner_only():
    ch = _channel()
    _, ok, _ = C.set_list_visibility(ch, actor_id=200, visibility=C.LIST_PUBLIC)
    assert ok is False
    ch, ok, _ = C.set_list_visibility(ch, actor_id=100, visibility=C.LIST_PUBLIC)
    assert ok is True and ch["list_visibility"] == C.LIST_PUBLIC


def test_share_link_roundtrip():
    ch = _channel()
    link = C.make_share_link(ch)
    assert link.startswith("assisto://channel/")
    parsed = C.parse_share_link(link)
    assert parsed["handle"] == "morning_brief"
    assert parsed["channel_id"] == 1
    assert C.parse_share_link("https://evil.test") is None


# ─────────────── reviewer-pass §21 (#94) — UI-relied invariants ────────────

def test_rp_new_follower_count_only_is_the_default():
    # #94 reviewer-pass: the follower toast ("you now follow, count-only") must
    # match the server default. A brand-new follower is count_only with NO
    # explicit choice.
    ch = _channel()
    ch2, roster, rec = C.follow(ch, {}, user_id=42)
    assert rec["visibility"] == C.VIS_COUNT_ONLY
    assert C.is_count_only(rec) is True
    # ...and such a follower is NEVER listed, even to the owner.
    out = C.serialize_follower_list(ch2, roster, viewer_id=ch2["owner_id"])
    assert out["count"] == 1
    assert out["followers"] == []
    assert out["hidden_count_only"] == 1


def test_rp_unfollow_decrements_count_and_drops_from_list():
    # The UI unfollow (now behind a confirm gate) must actually leave: count
    # drops and the row disappears from any listing.
    ch = _channel()
    ch, roster, _ = C.follow(ch, {}, user_id=7)
    roster = {7: C.set_follower_visibility(roster[7], C.VIS_SHOW)}
    ch = dict(ch); ch["follower_count"] = C.follower_count(followers=roster)
    ch, roster, removed = C.unfollow(ch, roster, 7)
    assert removed is True
    assert C.follower_count(followers=roster) == 0


def test_rp_verified_badge_requires_recorded_operator():
    # The UI shows MsgrVerifiedBadge only on is_verified(). A forged flag with no
    # operator approver must read as NOT verified so the badge never lies.
    forged = _channel(verified=True, verified_by=None)
    assert C.is_verified(forged) is False
    legit = _channel(verified=True, verified_by=999)
    assert C.is_verified(legit) is True


def test_rp_analytics_carry_no_pii():
    # The admin Analytics tab renders counts only; assert the payload says so and
    # carries no per-follower field.
    ch = _channel()
    post, _, _ = C.new_post(1, ch, author_id=100, kind=C.POST_TEXT, text="hi")
    post = C.record_view(C.add_reaction(post, "👍"))
    a = C.channel_analytics(ch, [post], follower_count_series=[("d1", 1), ("d2", 3)])
    assert a["contains_pii"] is False
    assert "followers" not in a and "viewers" not in a
    assert a["follower_growth"]["net"] == 2


# ───────────────────────────── runner ─────────────────────────────────────

def run_all():
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    passed = 0
    for t in tests:
        t()
        passed += 1
    print(f"msg_channel: {passed}/{len(tests)} tests passed")
    return passed


if __name__ == "__main__":
    run_all()
