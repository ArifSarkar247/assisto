"""
circle_privacy_tests_snippets.py — plain-assert tests for core.logic.circle_privacy.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.circle_privacy_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timezone

from core.logic import circle_privacy as P


# ---- block / restrict state ----

def test_apply_block_unblock():
    s = P.apply_block(set(), 5)
    assert 5 in s
    s = P.apply_block(s, 5, on=False)
    assert 5 not in s


def test_is_blocked_either_direction():
    me = {"blocked": {5}, "blocked_by": {9}}
    assert P.is_blocked(me, 5) is True       # I blocked them
    assert P.is_blocked(me, 9) is True       # they blocked me
    assert P.is_blocked(me, 1) is False


def test_is_restricted():
    me = {"restricted": {7}}
    assert P.is_restricted(me, 7) is True
    assert P.is_restricted(me, 8) is False


# ---- message delivery (block silent, restrict filtered) ----

def test_block_prevents_message():
    sender = {"id": 5}
    recipient = {"blocked": {5}}
    d = P.deliver_decision(sender, recipient)
    assert d["deliver"] is False and d["reason"] == "blocked"


def test_blocked_by_also_drops():
    sender = {"id": 5}
    recipient = {"blocked_by": {5}}
    assert P.deliver_decision(sender, recipient)["deliver"] is False


def test_restrict_delivers_to_filtered_inbox_no_notify():
    sender = {"id": 7}
    recipient = {"restricted": {7}}
    d = P.deliver_decision(sender, recipient)
    assert d["deliver"] is True
    assert d["inbox"] == "restricted"
    assert d["notify"] is False


def test_normal_delivery_notifies():
    d = P.deliver_decision({"id": 3}, {})
    assert d["deliver"] is True and d["inbox"] == "normal" and d["notify"] is True


# ---- visibility resolver ----

def test_visibility_nobody_hides():
    owner = {"visibility": {"last_seen": P.VIS_NOBODY}}
    viewer = {"id": 2, "relation": "mother"}
    assert P.can_see_field(owner, viewer, "last_seen") is False


def test_visibility_family_only():
    owner = {"visibility": {"last_seen": P.VIS_FAMILY}}
    assert P.can_see_field(owner, {"id": 2, "relation": "mother"}, "last_seen") is True
    assert P.can_see_field(owner, {"id": 3, "relation": "friend"}, "last_seen") is False


def test_visibility_everyone():
    owner = {"visibility": {"profile_photo": P.VIS_EVERYONE}}
    assert P.can_see_field(owner, {"id": 9, "relation": "friend"}, "profile_photo") is True


def test_block_hides_all_visibility():
    owner = {"visibility": {"profile_photo": P.VIS_EVERYONE}, "blocked": {9}}
    assert P.can_see_field(owner, {"id": 9, "relation": "friend"}, "profile_photo") is False


def test_restrict_hides_active_status():
    owner = {"visibility": {"active_status": P.VIS_EVERYONE}, "restricted": {4}}
    # restricted viewer cannot see active status even though policy is everyone
    assert P.can_see_field(owner, {"id": 4, "relation": "friend"}, "active_status") is False
    # but can still see profile photo (not an active-status field)
    owner["visibility"]["profile_photo"] = P.VIS_EVERYONE
    assert P.can_see_field(owner, {"id": 4, "relation": "friend"}, "profile_photo") is True


def test_default_visibility_safe():
    d = P.default_visibility()
    assert d["last_seen"] == P.VIS_FAMILY
    assert d["active_status"] == P.VIS_FAMILY


# ---- read receipts reciprocal rule ----

def test_read_receipt_both_on():
    viewer = {"id": 1, "read_receipts": True}
    sender = {"id": 2, "read_receipts": True}
    assert P.can_see_read_receipt(viewer, sender) is True


def test_read_receipt_reciprocal_viewer_off():
    # If I (viewer) turned receipts OFF, I can't see yours.
    viewer = {"id": 1, "read_receipts": False}
    sender = {"id": 2, "read_receipts": True}
    assert P.can_see_read_receipt(viewer, sender) is False


def test_read_receipt_sender_off():
    viewer = {"id": 1, "read_receipts": True}
    sender = {"id": 2, "read_receipts": False}
    assert P.can_see_read_receipt(viewer, sender) is False


def test_read_receipt_restricted_hidden():
    viewer = {"id": 1, "read_receipts": True}
    sender = {"id": 2, "read_receipts": True, "restricted": {1}}
    assert P.can_see_read_receipt(viewer, sender) is False


def test_typing_reciprocal():
    assert P.can_see_typing({"id": 1, "typing": False}, {"id": 2, "typing": True}) is False
    assert P.can_see_typing({"id": 1, "typing": True}, {"id": 2, "typing": True}) is True


# ---- incoming-call policy ----

def test_call_policy_nobody():
    cfg = {"policy": P.CALLS_NOBODY}
    r = P.allow_call(cfg, {"id": 2, "relation": "friend"})
    assert r["ring"] is False and r["log_missed"] is True


def test_call_policy_chosen():
    cfg = {"policy": P.CALLS_CHOSEN, "allow_ids": [5]}
    assert P.allow_call(cfg, {"id": 5})["ring"] is True
    assert P.allow_call(cfg, {"id": 6})["ring"] is False


def test_call_policy_relations():
    cfg = {"policy": P.CALLS_RELATIONS, "allow_relations": ["mother", "father"]}
    assert P.allow_call(cfg, {"id": 1, "relation": "mother"})["ring"] is True
    assert P.allow_call(cfg, {"id": 2, "relation": "friend"})["ring"] is False


def test_blocked_call_silent_not_logged():
    cfg = {"policy": P.CALLS_EVERYONE}
    r = P.allow_call(cfg, {"id": 2, "blocked": True})
    assert r["ring"] is False and r["log_missed"] is False and r["reason"] == "blocked"


def test_restricted_call_no_ring_but_logged():
    cfg = {"policy": P.CALLS_EVERYONE}
    r = P.allow_call(cfg, {"id": 2, "relation": "friend", "restricted": True})
    assert r["ring"] is False and r["log_missed"] is True and r["reason"] == "restricted"


# ---- DND schedule + family exception ----

def test_dnd_blocks_non_family():
    cfg = {"policy": P.CALLS_EVERYONE, "dnd_enabled": True,
           "dnd_start": "22:00", "dnd_end": "07:00", "dnd_family_exception": True}
    at_2am = datetime(2026, 1, 1, 2, 0, tzinfo=timezone.utc)
    r = P.allow_call(cfg, {"id": 2, "relation": "friend"}, now_local=at_2am)
    assert r["ring"] is False and r["log_missed"] is True and r["reason"] == "dnd"


def test_dnd_family_exception_rings():
    cfg = {"policy": P.CALLS_EVERYONE, "dnd_enabled": True,
           "dnd_start": "22:00", "dnd_end": "07:00", "dnd_family_exception": True}
    at_2am = datetime(2026, 1, 1, 2, 0, tzinfo=timezone.utc)
    r = P.allow_call(cfg, {"id": 2, "relation": "mother"}, now_local=at_2am)
    assert r["ring"] is True and r["reason"] == "dnd_family_exception"


def test_dnd_family_exception_off_blocks_family():
    cfg = {"policy": P.CALLS_EVERYONE, "dnd_enabled": True,
           "dnd_start": "22:00", "dnd_end": "07:00", "dnd_family_exception": False}
    at_2am = datetime(2026, 1, 1, 2, 0, tzinfo=timezone.utc)
    r = P.allow_call(cfg, {"id": 2, "relation": "mother"}, now_local=at_2am)
    assert r["ring"] is False and r["reason"] == "dnd"


def test_dnd_outside_window_rings():
    cfg = {"policy": P.CALLS_EVERYONE, "dnd_enabled": True,
           "dnd_start": "22:00", "dnd_end": "07:00"}
    at_noon = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    assert P.allow_call(cfg, {"id": 2, "relation": "friend"}, now_local=at_noon)["ring"] is True


def test_dnd_window_wrap_helper():
    from datetime import time
    assert P._in_dnd_window(time(2, 0), time(22, 0), time(7, 0)) is True
    assert P._in_dnd_window(time(23, 0), time(22, 0), time(7, 0)) is True
    assert P._in_dnd_window(time(12, 0), time(22, 0), time(7, 0)) is False


# ---- report ----

def test_report_build():
    r = P.build_report(1, 2, "harassment", note="bad", also_block=True, lang="en")
    assert r["reason"] == "harassment"
    assert r["also_block"] is True
    assert r["suggest_block"] is True


def test_report_attach_messages():
    r = P.build_report(1, 2, "spam", attach_messages=["m1", "m2", "m3"])
    assert r["attached_message_count"] == 3
    assert r["suggest_block"] is False


def test_report_unknown_reason_to_other():
    assert P.build_report(1, 2, "weird")["reason"] == "other"


# ---- mute / notify / pin / lock ----

def test_mute_timed_and_always():
    now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    until = P.mute_until(P.MUTE_8H, now=now)
    assert until == now.timestamp() + 8 * 3600
    assert P.mute_until(P.MUTE_ALWAYS, now=now) is None


def test_is_muted():
    now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)
    # always
    assert P.is_muted({"muted": True, "until": None}, now=now) is True
    # expired timed mute
    assert P.is_muted({"muted": True, "until": now.timestamp() - 10}, now=now) is False
    # live timed mute
    assert P.is_muted({"muted": True, "until": now.timestamp() + 10}, now=now) is True
    assert P.is_muted({"muted": False}, now=now) is False


def test_should_notify_combines_mute_and_inbox():
    assert P.should_notify({"muted": False}, "restricted") is False
    assert P.should_notify({"muted": True, "until": None}, "normal") is False
    assert P.should_notify({"muted": False}, "normal") is True


def test_can_pin_limit():
    assert P.can_pin(0) is True
    assert P.can_pin(3) is False


def test_chat_lock_config_no_raw_pin_stored():
    c = P.chat_lock_config("pin", pin_hash="abc123")
    assert c["locked"] is True and c["method"] == "pin"
    assert c["pin_hash"] == "abc123"
    bio = P.chat_lock_config("fingerprint")
    assert bio["locked"] is True and bio["pin_hash"] is None
    off = P.chat_lock_config("none")
    assert off["locked"] is False


# ---- labels ----

def test_labels_bilingual():
    assert P.call_policy_label(P.CALLS_NOBODY, "en") == "Nobody"
    assert "কেউ" in P.call_policy_label(P.CALLS_NOBODY, "bn")
    assert P.visibility_label(P.VIS_FAMILY, "en") == "Family only"
    assert P.mute_label(P.MUTE_8H, "en") == "8 hours"


# ---- reviewer-pass (§21): honest call hints + confirm gate + load state ----

def test_call_policy_hint_bilingual():
    assert "circle" in P.call_policy_label_hint(P.CALLS_EVERYONE, "en")
    assert "missed" in P.call_policy_label_hint(P.CALLS_NOBODY, "en")
    assert "মিসড" in P.call_policy_label_hint(P.CALLS_NOBODY, "bn")


def test_call_policy_restrictive_flag():
    assert P.call_policy_is_restrictive(P.CALLS_EVERYONE) is False
    assert P.call_policy_is_restrictive(P.CALLS_NOBODY) is True
    assert P.call_policy_is_restrictive(P.CALLS_CHOSEN) is True
    assert P.call_policy_is_restrictive(P.CALLS_RELATIONS) is True
    # garbage normalizes to everyone -> not restrictive
    assert P.call_policy_is_restrictive("bogus") is False


def test_call_policy_confirm_gate():
    # no gate for the permissive default
    assert P.call_policy_confirm(P.CALLS_EVERYONE) is None
    # nobody -> mentions family explicitly (every call missed)
    nobody = P.call_policy_confirm(P.CALLS_NOBODY, "en")
    assert nobody is not None and "family" in nobody
    assert "পরিবার" in P.call_policy_confirm(P.CALLS_NOBODY, "bn")
    # chosen/relations -> a confirm, different copy
    assert P.call_policy_confirm(P.CALLS_CHOSEN, "en") is not None


def test_privacy_load_failed_notice_bilingual():
    assert P.privacy_load_failed_notice("en").startswith("Couldn")
    assert "লোড" in P.privacy_load_failed_notice("bn")


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"circle_privacy: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
