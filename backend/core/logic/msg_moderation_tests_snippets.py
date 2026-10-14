"""
msg_moderation_tests_snippets.py — plain-assert tests for
core.logic.msg_moderation.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.msg_moderation_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timedelta, timezone

from core.logic import msg_moderation as M


def _dt(mins=0):
    return datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc) + timedelta(minutes=mins)


# ---- categories ----

def test_severe_detection():
    assert M.is_severe([M.R_CSAE]) is True
    assert M.is_severe([M.R_TERRORISM, M.R_SPAM]) is True
    assert M.is_severe([M.R_SPAM, M.R_HARASSMENT]) is False


def test_scam_fraud_is_severe():
    assert M.is_severe([M.R_SCAM_FRAUD]) is True


def test_normalize_drops_unknown():
    assert M.normalize_categories(["spam", "bogus", "spam"]) == [M.R_SPAM]
    assert M.normalize_categories(None) == []


def test_legal_retention_flag():
    assert M.requires_legal_retention([M.R_CSAE]) is True
    assert M.requires_legal_retention([M.R_SCAM_FRAUD]) is False  # severe but not retention-flagged
    assert M.requires_legal_retention([M.R_SPAM]) is False


def test_category_label_bilingual():
    assert M.category_label(M.R_SCAM_FRAUD, "en") == "Scam / fraud"
    assert "প্রতারণা" in M.category_label(M.R_SCAM_FRAUD, "bn")


# ---- report validity ----

def test_build_report_valid():
    r = M.build_report("rp1", reporter_id=10, target_kind=M.T_CHANNEL,
                       target_id=99, categories=[M.R_SPAM], now=_dt())
    assert r["valid"] is True
    assert r["categories"] == [M.R_SPAM]


def test_self_report_person_invalid():
    r = M.build_report("rp", reporter_id=5, target_kind=M.T_PERSON,
                       target_id=5, categories=[M.R_HARASSMENT], now=_dt())
    assert r["valid"] is False


def test_empty_reason_invalid():
    r = M.build_report("rp", reporter_id=5, target_kind=M.T_POST,
                       target_id=7, categories=[], now=_dt())
    assert r["valid"] is False


def test_invalid_report_rejected_in_eval():
    r = M.build_report("rp", reporter_id=None, target_kind=M.T_POST,
                       target_id=7, categories=[M.R_SPAM], now=_dt())
    d = M.evaluate_report(r, [], M.STATUS_VISIBLE, now=_dt())
    assert d["accepted"] is False and d["reason"] == "invalid_report"
    assert d["new_status"] is None


# ---- SEVERE -> immediate hide on 1 report ----

def test_severe_immediate_hide_on_first_report():
    r = M.build_report("rp1", reporter_id=10, target_kind=M.T_POST,
                       target_id=99, categories=[M.R_CSAE], now=_dt())
    d = M.evaluate_report(r, [], M.STATUS_VISIBLE, now=_dt())
    assert d["severe"] is True
    assert d["action"] == "hide"
    assert d["new_status"] == M.STATUS_HIDDEN
    assert d["queue"] is True
    assert d["reason"] == "severe_immediate"
    assert d["legal_retention"] is True


def test_severe_on_already_hidden_just_queues():
    r = M.build_report("rp2", reporter_id=11, target_kind=M.T_POST,
                       target_id=99, categories=[M.R_TERRORISM], now=_dt())
    d = M.evaluate_report(r, [], M.STATUS_HIDDEN, now=_dt())
    assert d["action"] == "queue"
    assert d["new_status"] is None
    assert d["queue"] is True


# ---- NON-SEVERE needs threshold ----

def test_non_severe_single_report_review_only_no_hide():
    r = M.build_report("rp1", reporter_id=10, target_kind=M.T_CHANNEL,
                       target_id=5, categories=[M.R_SPAM], now=_dt())
    d = M.evaluate_report(r, [], M.STATUS_VISIBLE, now=_dt())
    assert d["action"] == "queue"
    assert d["new_status"] is None          # NOT hidden
    assert d["reason"] == "non_severe_review"
    assert d["queue"] is True


# ---- MASS report -> temp auto-hide then review ----

def test_mass_report_temp_hide_then_review():
    cfg = M.default_config()  # threshold 5, window 60m
    target = (M.T_CHANNEL, 5)
    existing = []
    # 4 distinct earlier reporters, all non-severe, within window.
    for i in range(4):
        existing.append(M.build_report(f"rp{i}", reporter_id=100 + i,
                                        target_kind=target[0], target_id=target[1],
                                        categories=[M.R_SPAM], now=_dt(i)))
    # After 4 existing + 1 new = 5 distinct -> should auto-hide.
    new = M.build_report("rpX", reporter_id=200, target_kind=target[0],
                         target_id=target[1], categories=[M.R_SPAM], now=_dt(5))
    d = M.evaluate_report(new, existing, M.STATUS_VISIBLE, config=cfg, now=_dt(5))
    assert d["distinct_reporters"] == 5
    assert d["action"] == "hide"
    assert d["new_status"] == M.STATUS_HIDDEN
    assert d["reason"] == "mass_report"
    assert d["severe"] is False
    assert d["queue"] is True


def test_mass_report_same_reporter_counts_once():
    """Anti false-report: one person reporting 10x counts as 1 distinct."""
    cfg = M.default_config()
    existing = [M.build_report(f"rp{i}", reporter_id=100,  # SAME reporter
                               target_kind=M.T_CHANNEL, target_id=5,
                               categories=[M.R_SPAM], now=_dt(i))
                for i in range(9)]
    new = M.build_report("rpX", reporter_id=100, target_kind=M.T_CHANNEL,
                         target_id=5, categories=[M.R_SPAM], now=_dt(10))
    d = M.evaluate_report(new, existing, M.STATUS_VISIBLE, config=cfg, now=_dt(10))
    assert d["distinct_reporters"] == 1
    assert d["action"] == "queue"          # NOT hidden
    assert d["new_status"] is None


def test_mass_report_outside_window_not_counted():
    cfg = M.default_config()  # window 60m
    existing = [M.build_report(f"rp{i}", reporter_id=100 + i,
                               target_kind=M.T_CHANNEL, target_id=5,
                               categories=[M.R_SPAM], now=_dt(-120 + i))  # old
                for i in range(4)]
    new = M.build_report("rpX", reporter_id=200, target_kind=M.T_CHANNEL,
                         target_id=5, categories=[M.R_SPAM], now=_dt(0))
    d = M.evaluate_report(new, existing, M.STATUS_VISIBLE, config=cfg, now=_dt(0))
    assert d["distinct_reporters"] == 1     # only the new one is recent
    assert d["new_status"] is None


# ---- queue item ----

def test_build_and_bump_queue_item():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_VISIBLE, now=_dt())
    assert it["queue_state"] == M.Q_QUEUED
    assert it["report_count"] == 1
    it2 = M.bump_queue_item(it, severe=True, categories=[M.R_CSAE])
    assert it2["report_count"] == 2
    assert it2["severe"] is True
    assert it2["legal_retention"] is True
    assert M.R_CSAE in it2["categories"]


# ---- admin action state machine ----

def test_admin_remove_resolves_and_audits():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SCAM_FRAUD], severe=True,
                            status=M.STATUS_HIDDEN, now=_dt())
    new_it, audit = M.apply_admin_action(it, M.A_REMOVE, admin_id=1,
                                         reason="confirmed fraud", now=_dt(1))
    assert new_it["content_status"] == M.STATUS_REMOVED
    assert new_it["queue_state"] == M.Q_RESOLVED
    assert new_it["decision"] == M.A_REMOVE
    # audit entry created per action (who/what/when/reason)
    assert audit["actor_id"] == 1
    assert audit["action"] == M.A_REMOVE
    assert audit["reason"] == "confirmed fraud"
    assert audit["at"] == _dt(1)


def test_admin_restore_sets_restored():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_HIDDEN, now=_dt())
    new_it, audit = M.apply_admin_action(it, M.A_RESTORE, admin_id=2,
                                         reason="false report", now=_dt())
    assert new_it["content_status"] == M.STATUS_RESTORED
    assert new_it["queue_state"] == M.Q_RESOLVED


def test_admin_action_requires_reason():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_VISIBLE, now=_dt())
    try:
        M.apply_admin_action(it, M.A_REMOVE, admin_id=1, reason="  ", now=_dt())
        assert False, "should have raised"
    except ValueError:
        pass


def test_admin_unknown_action_raises():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_VISIBLE, now=_dt())
    try:
        M.apply_admin_action(it, "nuke", admin_id=1, reason="x", now=_dt())
        assert False
    except ValueError:
        pass


def test_warn_does_not_change_content_status():
    it = M.build_queue_item("q1", M.T_PERSON, 99, [M.R_HARASSMENT], severe=False,
                            status=M.STATUS_VISIBLE, now=_dt())
    new_it, _ = M.apply_admin_action(it, M.A_WARN, admin_id=1,
                                     reason="first warning", now=_dt())
    assert new_it["content_status"] == M.STATUS_VISIBLE
    assert new_it["queue_state"] == M.Q_RESOLVED


# ---- appeals re-open ----

def test_appeal_reopens_item():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_REMOVED, now=_dt())
    resolved, _ = M.apply_admin_action(it, M.A_REMOVE, admin_id=1,
                                       reason="spam", now=_dt(1))
    assert M.can_appeal(resolved, action_time=_dt(1), now=_dt(60)) is True
    appealed, audit = M.open_appeal(resolved, appellant_id=99,
                                    reason="not spam", now=_dt(61))
    assert appealed["queue_state"] == M.Q_UNDER_APPEAL
    assert audit["action"] == "appeal"
    requeued = M.reopen_for_review(appealed)
    assert requeued["queue_state"] == M.Q_QUEUED


def test_appeal_window_expired():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_REMOVED, now=_dt())
    resolved, _ = M.apply_admin_action(it, M.A_REMOVE, admin_id=1,
                                       reason="spam", now=_dt(1))
    # default appeal window 30d; 40 days later -> cannot appeal.
    late = _dt(1) + timedelta(days=40)
    assert M.can_appeal(resolved, action_time=_dt(1), now=late) is False


def test_cannot_appeal_unresolved():
    it = M.build_queue_item("q1", M.T_POST, 99, [M.R_SPAM], severe=False,
                            status=M.STATUS_HIDDEN, now=_dt())
    assert M.can_appeal(it, action_time=_dt(1), now=_dt(2)) is False


# ---- audit ----

def test_audit_entry_fields():
    a = M.build_audit_entry(actor_id=7, action=M.A_BAN, target_kind=M.T_PERSON,
                            target_id=42, reason="repeat abuse", now=_dt())
    assert a["actor_id"] == 7
    assert a["action"] == M.A_BAN
    assert a["target_id"] == 42
    assert a["reason"] == "repeat abuse"
    assert a["at"] == _dt()


# ---- OWNER ADMIN users: projection EXCLUDES message content + contacts ----

def _raw_user():
    return {
        "id": 42,
        "name": "Rahim",
        "phone": "+8801700000000",
        "photo_url": "https://cdn/x.jpg",
        "signup_date": "2026-01-01",
        "plan": "premium",
        "last_active": "2026-10-14",
        "app_version": "1.0.0+61",
        "report_count": 2,
        "status": M.U_ACTIVE,
        # ---- PRIVATE: must NEVER reach admin ----
        "messages": ["secret text 1", "secret text 2"],
        "message_contents": "hello my love",
        "contacts": [1, 2, 3],
        "contact_list": ["mom", "dad"],
        "e2e_keys": "DEADBEEF",
        "password_hash": "xxx",
    }


def test_admin_projection_excludes_message_content_and_contacts():
    proj = M.admin_user_projection(_raw_user())
    # the GUARD the task asks us to assert:
    assert "messages" not in proj
    assert "message_contents" not in proj
    assert "message_bodies" not in proj
    assert "contacts" not in proj
    assert "contact_list" not in proj
    assert "e2e_keys" not in proj
    assert "password_hash" not in proj
    # no forbidden field at all
    assert not (M.ADMIN_FORBIDDEN_FIELDS & set(proj.keys()))
    # public fields ARE present
    assert proj["name"] == "Rahim"
    assert proj["report_count"] == 2
    assert set(proj.keys()) == set(M.ADMIN_USER_PUBLIC_FIELDS)


def test_list_users_search_by_name_and_phone():
    users = [_raw_user(),
             {"id": 7, "name": "Karim", "phone": "+8801811111111",
              "status": M.U_SUSPENDED, "messages": ["x"], "contacts": [9]}]
    by_name = M.list_users_for_admin(users, query="rah")
    assert len(by_name) == 1 and by_name[0]["id"] == 42
    by_phone = M.list_users_for_admin(users, query="1811")
    assert len(by_phone) == 1 and by_phone[0]["id"] == 7
    # even searched rows are projected (no leak)
    assert "messages" not in by_phone[0] and "contacts" not in by_phone[0]


def test_list_users_filter_by_status():
    users = [_raw_user(),
             {"id": 7, "name": "Karim", "phone": "+88", "status": M.U_SUSPENDED}]
    susp = M.list_users_for_admin(users, status=M.U_SUSPENDED)
    assert len(susp) == 1 and susp[0]["id"] == 7


# ---- admin user actions (suspend/unsuspend/reset) ----

def test_suspend_logs_out_and_audits():
    ns, reset, audit = M.admin_user_action(M.U_ACTIVE, M.A_SUSPEND, admin_id=1,
                                           target_user_id=42, reason="abuse",
                                           now=_dt())
    assert ns == M.U_SUSPENDED
    assert reset is True                   # sessions reset on suspend
    assert audit["action"] == M.A_SUSPEND
    assert audit["new_status"] == M.U_SUSPENDED


def test_unsuspend_restores_active():
    ns, reset, _ = M.admin_user_action(M.U_SUSPENDED, M.A_UNSUSPEND, admin_id=1,
                                       target_user_id=42, reason="appeal upheld",
                                       now=_dt())
    assert ns == M.U_ACTIVE
    assert reset is False


def test_ban_transition():
    ns, reset, audit = M.admin_user_action(M.U_ACTIVE, M.A_BAN, admin_id=1,
                                           target_user_id=42, reason="csae",
                                           now=_dt())
    assert ns == M.U_BANNED
    assert reset is True
    assert audit["action"] == M.A_BAN


def test_reset_sessions_only():
    ns, reset, _ = M.admin_user_action(M.U_ACTIVE, M.A_RESET_SESSIONS, admin_id=1,
                                       target_user_id=42, reason="security",
                                       now=_dt())
    assert ns == M.U_ACTIVE
    assert reset is True


def test_admin_user_action_requires_reason():
    try:
        M.admin_user_action(M.U_ACTIVE, M.A_SUSPEND, admin_id=1,
                            target_user_id=42, reason="", now=_dt())
        assert False
    except ValueError:
        pass


# ---- labels ----

def test_labels_bilingual():
    assert M.action_label(M.A_BAN, "en") == "Ban"
    assert "নিষিদ্ধ" in M.action_label(M.A_BAN, "bn")
    assert M.status_label(M.STATUS_HIDDEN, "en") == "Hidden"
    assert M.status_label(M.U_SUSPENDED, "bn") == "স্থগিত"


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"msg_moderation: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
