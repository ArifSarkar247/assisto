"""
nominee_tests_snippets.py — plain-assert tests for core.logic.nominee.

NOT a Django TestCase. Smoke locally:
    python3 -c "import core.logic.nominee_tests_snippets as t; t.run_all()"

Covers the release-safeguard invariant end to end: a saved plan opens nothing;
no trigger fires without its verified precondition; there is no path to `open`
that skips the cancellable grace window; and the owner can always cancel/revoke.
"""
from datetime import datetime, timedelta

from core.logic import nominee as N


NOW = datetime(2026, 10, 14, 12, 0)


def _plan(**kw):
    base = dict(name="Rahim", contact="017...", relationship="child",
                scopes=["emergency", "wishes"], priority=2,
                trigger="owner_grant")
    base.update(kw)
    return N.build_nominee(**base)


# ---- build / validate -----------------------------------------------------

def test_build_requires_name_and_scope():
    try:
        N.build_nominee(name="", contact="x", scopes=["emergency"])
        assert False, "empty name should raise"
    except ValueError:
        pass
    try:
        N.build_nominee(name="A", contact="x", scopes=[])
        assert False, "empty scope should raise"
    except ValueError:
        pass


def test_scopes_all_expands_and_dedups():
    assert N.normalize_scopes("all") == list(N.SCOPES)
    assert N.normalize_scopes(["emergency", "emergency", "junk"]) == ["emergency"]
    assert N.normalize_scopes(["wishes", "all"]) == list(N.SCOPES)


def test_build_defaults_armed_and_closed():
    n = _plan()
    assert n["release_state"] == N.STATE_ARMED
    assert n["activated"] is False
    assert n["scope"] == "emergency"           # legacy mirror = first scope
    assert N.visible_scopes(n) == []           # dormant plan leaks nothing


def test_order_by_priority():
    a = _plan(name="A", priority=3)
    b = _plan(name="B", priority=1)
    assert [x["name"] for x in N.order_nominees([a, b])] == ["B", "A"]


# ---- SAFETY: nothing opens without a verified trigger ---------------------

def test_owner_grant_needs_confirmation():
    n = _plan(trigger="owner_grant")
    ok, _, _, n2 = N.request_release(n, owner_confirmed=False, now=NOW)
    assert not ok and n2["release_state"] == N.STATE_ARMED
    ok, _, _, n3 = N.request_release(n, owner_confirmed=True, now=NOW)
    assert ok and n3["release_state"] == N.STATE_PENDING


def test_inactivity_needs_wellness_alert():
    n = _plan(trigger="inactivity")
    for st in ("off", "ok", "quiet", "prompt", None):
        ok, _, _, _ = N.request_release(n, wellness_state=st, now=NOW)
        assert not ok, f"wellness {st} must NOT open a release"
    ok, _, _, n2 = N.request_release(n, wellness_state="alert", now=NOW)
    assert ok and n2["release_state"] == N.STATE_PENDING


def test_multi_verify_needs_quorum_of_named_people():
    n = _plan(trigger="multi_verify", multi_verify_ids=[5, 6, 7],
              multi_verify_quorum=2)
    # too few
    ok, _, _, _ = N.request_release(n, confirmations=[5], now=NOW)
    assert not ok
    # outsiders don't count
    ok, _, _, _ = N.request_release(n, confirmations=[99, 100], now=NOW)
    assert not ok
    # quorum of named people
    ok, _, _, n2 = N.request_release(n, confirmations=[5, 6, 99], now=NOW)
    assert ok and n2["release_confirmations"] == [5, 6]


def test_multi_verify_empty_ids_can_never_fire():
    n = _plan(trigger="multi_verify", multi_verify_ids=[])
    ok, _, _, _ = N.request_release(n, confirmations=[1, 2, 3], now=NOW)
    assert not ok, "no named confirmers => quorum 0 => never fires"


# ---- SAFETY: no path to open skips the cancellable grace window -----------

def test_cannot_open_before_grace_elapses():
    n = _plan(trigger="owner_grant", grace_hours=48)
    _, _, _, pend = N.request_release(n, owner_confirmed=True, now=NOW)
    assert N.grace_remaining_seconds(pend, NOW) == 48 * 3600
    # one second before the window ends: still refused
    almost = NOW + timedelta(hours=48) - timedelta(seconds=1)
    assert not N.can_open_now(pend, almost)
    ok, _, _, still = N.open_access(pend, owner_confirmed=True, now=almost)
    assert not ok and still["release_state"] == N.STATE_PENDING
    assert N.visible_scopes(still) == []       # nothing visible while pending


def test_open_requires_window_elapsed_and_final_confirm():
    n = _plan(trigger="owner_grant", grace_hours=24)
    _, _, _, pend = N.request_release(n, owner_confirmed=True, now=NOW)
    after = NOW + timedelta(hours=24, seconds=1)
    assert N.can_open_now(pend, after)
    # window elapsed but NO final confirm -> refused
    ok, _, _, _ = N.open_access(pend, owner_confirmed=False, now=after)
    assert not ok
    # window elapsed + final confirm -> open
    ok, _, _, opened = N.open_access(pend, owner_confirmed=True, now=after)
    assert ok and opened["release_state"] == N.STATE_OPEN
    assert opened["activated"] is True
    assert set(N.visible_scopes(opened)) == {"emergency", "wishes"}


def test_open_without_request_is_refused():
    n = _plan(trigger="owner_grant")
    ok, _, _, _ = N.open_access(n, owner_confirmed=True, now=NOW)
    assert not ok, "cannot open straight from armed"


# ---- SAFETY: owner can always cancel / revoke -----------------------------

def test_cancel_pending_returns_to_armed():
    n = _plan(trigger="owner_grant")
    _, _, _, pend = N.request_release(n, owner_confirmed=True, now=NOW)
    back = N.cancel_release(pend)
    assert back["release_state"] == N.STATE_ARMED
    assert back["release_pending"] is False
    assert N.grace_remaining_seconds(back, NOW) == 0


def test_revoke_open_access():
    n = _plan(trigger="owner_grant", grace_hours=1)
    _, _, _, pend = N.request_release(n, owner_confirmed=True, now=NOW)
    after = NOW + timedelta(hours=2)
    _, _, _, opened = N.open_access(pend, owner_confirmed=True, now=after)
    assert opened["activated"] is True
    back = N.cancel_release(opened)
    assert back["activated"] is False
    assert back["release_state"] == N.STATE_ARMED
    assert N.visible_scopes(back) == []


def test_double_request_refused():
    n = _plan(trigger="owner_grant")
    _, _, _, pend = N.request_release(n, owner_confirmed=True, now=NOW)
    ok, _, _, _ = N.request_release(pend, owner_confirmed=True, now=NOW)
    assert not ok, "already pending"


# ---- status helper --------------------------------------------------------

def test_release_status_bilingual():
    n = _plan()
    assert N.release_status(n, "en")["state"] == N.STATE_ARMED
    assert N.release_status(n, "bn")["label"]  # non-empty Bangla
    _, _, _, pend = N.request_release(n, owner_confirmed=True, now=NOW)
    st = N.release_status(pend, "en", now=NOW)
    assert st["state"] == N.STATE_PENDING and st["grace_remaining_seconds"] > 0


# ---------------------------------------------------------------------------

def run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
    print(f"nominee: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
