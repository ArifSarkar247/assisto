"""
pa_delegate_tests_snippets.py — plain-assert tests for PA delegate-access
(#111, §14). Pure stdlib. `python pa_delegate_tests_snippets.py` or import and
call run_all(). Deterministic engine → every assertion is hand-verified.
"""

try:  # Django harness
    from core.logic import pa_delegate as D
except ImportError:  # standalone
    import pa_delegate as D  # noqa: E402


# ---------------------------------------------------------------- catalog

def test_catalog_is_ordered_and_complete():
    cat = D.catalog()
    assert len(cat) == len(D.ALL_SCOPES)
    assert [c["scope"] for c in cat] == list(D.ALL_SCOPES)
    for c in cat:
        assert c["exposes"]  # every scope has honest UI copy


def test_known_and_unknown_scope():
    assert D.is_known_scope(D.SCOPE_SEE_SCHEDULE)
    assert not D.is_known_scope("read_my_mind")
    assert D.exposes_key("read_my_mind") == ""
    assert D.scope_meta("read_my_mind") is None


def test_sensitivity_flags():
    assert not D.is_sensitive(D.SCOPE_SEE_SCHEDULE)
    assert not D.is_sensitive(D.SCOPE_VIEW_BRIEFS)
    assert D.is_sensitive(D.SCOPE_SEE_MONEY)
    assert D.is_sensitive(D.SCOPE_SEE_HEALTH)
    assert D.is_sensitive(D.SCOPE_APPROVE_VISITORS)


# ---------------------------------------------------------- least privilege

def test_default_is_least_privilege():
    d = D.default_scopes()
    # only low-risk read-only scopes
    assert d == {D.SCOPE_SEE_SCHEDULE, D.SCOPE_VIEW_BRIEFS, D.SCOPE_SEE_TASKS}
    # NOTHING sensitive is ever in the default
    for s in d:
        assert not D.is_sensitive(s)


def test_default_is_fresh_each_call():
    a = D.default_scopes()
    a.add("junk")
    b = D.default_scopes()
    assert "junk" not in b


# --------------------------------------------------------------- normalize

def test_normalize_drops_unknown():
    assert D.normalize_scopes([D.SCOPE_SEE_MONEY, "forged", "x"]) == {
        D.SCOPE_SEE_MONEY}
    assert D.normalize_scopes(None) == set()


def test_set_scope_is_pure():
    base = {D.SCOPE_SEE_SCHEDULE}
    out = D.set_scope(base, D.SCOPE_SEE_TASKS, on=True)
    assert out == {D.SCOPE_SEE_SCHEDULE, D.SCOPE_SEE_TASKS}
    assert base == {D.SCOPE_SEE_SCHEDULE}  # input untouched
    # unknown scope is a no-op
    assert D.set_scope(base, "forged", on=True) == base


# --------------------------------------------- can_access: default deny seam

def test_can_access_default_deny():
    stored = {D.SCOPE_SEE_SCHEDULE}
    assert D.can_access(stored, D.SCOPE_SEE_SCHEDULE) is True
    # never granted → denied
    assert D.can_access(stored, D.SCOPE_SEE_MONEY) is False


def test_forged_client_scope_reads_as_not_granted():
    # a hostile client claims a capability the DB never stored
    stored_in_db = D.default_scopes()  # schedule/briefs/tasks only
    assert D.can_access(stored_in_db, D.SCOPE_SEE_MONEY) is False
    assert D.can_access(stored_in_db, D.SCOPE_SEE_HEALTH) is False
    # an entirely invented scope name is also denied
    assert D.can_access(stored_in_db, "sudo_everything") is False


def test_can_access_empty_store_denies_all():
    for s in D.ALL_SCOPES:
        assert D.can_access(set(), s) is False


# ----------------------------------------------------------- confirm gate

def test_grant_requires_confirm():
    assert D.grant_requires_confirm(D.SCOPE_SEE_SCHEDULE) is False
    assert D.grant_requires_confirm(D.SCOPE_SEE_MONEY) is True
    # unknown → fail-safe to requiring the gate
    assert D.grant_requires_confirm("forged") is True


def test_confirm_grant_nonsensitive_immediate():
    g = D.confirm_grant(D.SCOPE_SEE_SCHEDULE, confirmed=False)
    assert g["allowed"] is True and g["needs_confirm"] is False


def test_confirm_grant_sensitive_needs_confirm():
    g = D.confirm_grant(D.SCOPE_SEE_MONEY, confirmed=False)
    assert g["allowed"] is False and g["needs_confirm"] is True
    assert g["reason"] == "confirm_required"
    g2 = D.confirm_grant(D.SCOPE_SEE_MONEY, confirmed=True)
    assert g2["allowed"] is True and g2["needs_confirm"] is False


def test_confirm_grant_unknown_refused():
    g = D.confirm_grant("forged", confirmed=True)
    assert g["allowed"] is False and g["reason"] == "unknown_scope"


# ----------------------------------------------------------- apply_grant

def test_apply_grant_nonsensitive_applies():
    r = D.apply_grant(set(), D.SCOPE_SEE_SCHEDULE, on=True)
    assert r["changed"] is True
    assert r["scopes"] == {D.SCOPE_SEE_SCHEDULE}


def test_apply_grant_sensitive_held_until_confirmed():
    r = D.apply_grant(set(), D.SCOPE_SEE_MONEY, on=True, confirmed=False)
    assert r["changed"] is False
    assert r["scopes"] == set()  # NOT granted without confirm
    assert r["gate"]["needs_confirm"] is True
    r2 = D.apply_grant(set(), D.SCOPE_SEE_MONEY, on=True, confirmed=True)
    assert r2["changed"] is True
    assert r2["scopes"] == {D.SCOPE_SEE_MONEY}


def test_apply_grant_revoke_is_immediate_and_safe():
    r = D.apply_grant({D.SCOPE_SEE_MONEY}, D.SCOPE_SEE_MONEY, on=False)
    assert r["changed"] is True
    assert r["scopes"] == set()
    assert r["gate"]["needs_confirm"] is False


def test_apply_grant_unknown_scope_noop():
    r = D.apply_grant({D.SCOPE_SEE_SCHEDULE}, "forged", on=True, confirmed=True)
    assert r["changed"] is False
    assert r["scopes"] == {D.SCOPE_SEE_SCHEDULE}


# --------------------------------------------------------------- audit

def test_audit_entry_shape_and_honesty():
    e = D.audit_entry(delegate_id="7", owner_id="3",
                      scope=D.SCOPE_SEE_MONEY, action="denied",
                      at="2026-10-14T09:00:00", detail="blocked", allowed=False)
    assert e["delegate_id"] == 7 and e["owner_id"] == 3
    assert e["action"] == "denied"
    assert e["allowed"] is False
    assert e["sensitive"] is True
    assert e["at"] == "2026-10-14T09:00:00"


def test_audit_entry_unknown_action_and_scope_coerced():
    e = D.audit_entry(delegate_id=1, owner_id=2, scope="forged",
                      action="hacked", at="x")
    assert e["action"] == "viewed"
    assert e["scope"] == "unknown"
    assert e["sensitive"] is False


def test_summarize_audit():
    entries = [
        D.audit_entry(delegate_id=1, owner_id=2, scope=D.SCOPE_SEE_SCHEDULE,
                      action="viewed", at="t1"),
        D.audit_entry(delegate_id=1, owner_id=2, scope=D.SCOPE_SEE_MONEY,
                      action="denied", at="t2", allowed=False),
        D.audit_entry(delegate_id=1, owner_id=2, scope=D.SCOPE_SEND_FOLLOWUPS,
                      action="acted", at="t3"),
    ]
    s = D.summarize_audit(entries)
    assert s["total"] == 3
    assert s["denied"] == 1
    assert s["sensitive"] == 2  # money + send_followups are sensitive
    assert s["by_action"]["viewed"] == 1
    assert s["by_action"]["denied"] == 1
    assert s["by_action"]["acted"] == 1


def test_summarize_audit_empty():
    s = D.summarize_audit([])
    assert s["total"] == 0 and s["denied"] == 0 and s["sensitive"] == 0


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_delegate: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
