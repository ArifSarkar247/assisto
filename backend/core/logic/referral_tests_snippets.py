"""
referral_tests_snippets.py — plain-assert tests for core.logic.referral.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.referral_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timezone

from core.logic import referral as R


NOW = datetime(2026, 10, 13, 12, 0, 0, tzinfo=timezone.utc)


def _grant_row(inviter=1, invitee=2, device="dev-A", rid=100, month="2026-10"):
    return {
        "id": rid, "kind": R.KIND_GRANT, "user_id": inviter,
        "points": R.POINTS_PER_REFERRAL, "reason": R.REASON_REFERRAL,
        "invitee_id": invitee, "device_id": device, "reverses": None,
        "month": month, "created_at": "2026-10-13T12:00:00+00:00",
    }


# --- the 3-condition gate ---------------------------------------------------

def test_award_only_on_accept_not_install():
    # installed + signed up but NOT accepted => no reward
    ok, code = R.can_award(1, 2, "dev-A", installed=True, signed_up=True,
                           accepted=False, now=NOW)
    assert not ok and code == R.ERR_NOT_ACCEPTED, code


def test_award_requires_install_and_signup():
    ok, code = R.can_award(1, 2, "dev-A", installed=False, now=NOW)
    assert not ok and code == R.ERR_NOT_INSTALLED, code
    ok, code = R.can_award(1, 2, "dev-A", installed=True, signed_up=False, now=NOW)
    assert not ok and code == R.ERR_NOT_SIGNED_UP, code


def test_full_gate_passes_and_grants_points():
    res = R.award_for_accept(1, 2, "dev-A", phone_verified=True, now=NOW)
    assert res["ok"] and res["code"] == R.OK, res
    assert res["grant"]["points"] == R.POINTS_PER_REFERRAL, res
    assert res["grant"]["user_id"] == 1, res
    assert res["grant"]["invitee_id"] == 2, res


# --- anti-abuse -------------------------------------------------------------

def test_self_invite_rejected():
    ok, code = R.can_award(7, 7, "dev-X", now=NOW)
    assert not ok and code == R.ERR_SELF_INVITE, code
    res = R.award_for_accept(7, 7, "dev-X", phone_verified=True, now=NOW)
    assert not res["ok"] and res["code"] == R.ERR_SELF_INVITE, res


def test_inactive_accounts_rejected():
    ok, code = R.can_award(1, 2, "dev-A", inviter_active=False, now=NOW)
    assert not ok and code == R.ERR_INACTIVE, code
    ok, code = R.can_award(1, 2, "dev-A", invitee_active=False, now=NOW)
    assert not ok and code == R.ERR_INVITEE_INACTIVE, code


def test_phone_gate_only_when_sms_enabled():
    # SMS key absent => phone check skipped even if unverified
    ok, code = R.can_award(1, 2, "dev-A", phone_verified=False,
                           sms_gate_enabled=False, now=NOW)
    assert ok and code == R.OK, code
    # SMS key present => unverified phone blocks the reward
    ok, code = R.can_award(1, 2, "dev-A", phone_verified=False,
                           sms_gate_enabled=True, now=NOW)
    assert not ok and code == R.ERR_PHONE_UNVERIFIED, code


def test_duplicate_person_rejected():
    ledger = [_grant_row(inviter=1, invitee=2, device="dev-A")]
    # same invitee person, different device => still one-per-person block
    ok, code = R.can_award(1, 2, "dev-B", ledger=ledger, now=NOW)
    assert not ok and code == R.ERR_DUP_PERSON, code


def test_duplicate_device_rejected():
    ledger = [_grant_row(inviter=1, invitee=2, device="dev-A")]
    # different invitee person but SAME device => duplicate-device block
    ok, code = R.can_award(1, 3, "dev-A", ledger=ledger, now=NOW)
    assert not ok and code == R.ERR_DUP_DEVICE, code


def test_monthly_cap():
    ledger = [_grant_row(inviter=1, invitee=100 + i, device=f"d{i}", rid=i)
              for i in range(R.MONTHLY_REFERRAL_CAP)]
    ok, code = R.can_award(1, 999, "d-new", ledger=ledger, now=NOW)
    assert not ok and code == R.ERR_MONTHLY_CAP, code
    # a different calendar month does NOT count against this month's cap
    last_month = [dict(r, month="2026-09") for r in ledger]
    ok, code = R.can_award(1, 999, "d-new", ledger=last_month, now=NOW)
    assert ok and code == R.OK, code


# --- welcome bonus ----------------------------------------------------------

def test_welcome_bonus_to_invitee():
    res = R.award_for_accept(1, 2, "dev-A", phone_verified=True, now=NOW)
    assert res["bonus"] is not None, res
    assert res["bonus"]["user_id"] == 2, res
    assert res["bonus"]["points"] == R.WELCOME_BONUS_POINTS, res
    # disabled when welcome_bonus=0
    res0 = R.award_for_accept(1, 2, "dev-A", phone_verified=True,
                              welcome_bonus=0, now=NOW)
    assert res0["bonus"] is None, res0


# --- clawback ---------------------------------------------------------------

def test_clawback_reverses_grant():
    grant = _grant_row(inviter=1, invitee=2, device="dev-A", rid=100)
    ledger = [grant]
    assert R.balance(ledger, user_id=1) == R.POINTS_PER_REFERRAL
    cb = R.clawback(1, grant, now=NOW, row_id=101)
    assert cb["points"] == -R.POINTS_PER_REFERRAL, cb
    assert cb["reverses"] == 100, cb
    ledger.append(cb)
    # balance returns to zero
    assert R.balance(ledger, user_id=1) == 0, ledger
    # and the slot frees: the same person/device may be rewarded again
    ok, code = R.can_award(1, 2, "dev-A", ledger=ledger, now=NOW)
    assert ok and code == R.OK, code


# --- balance / history ------------------------------------------------------

def test_balance_never_negative():
    ledger = [{"user_id": 1, "kind": R.KIND_REDEEM, "points": -5,
               "reason": R.REASON_REDEEM_PREMIUM,
               "created_at": "2026-10-13T12:00:00+00:00"}]
    assert R.balance(ledger, user_id=1) == 0


def test_history_newest_first_and_localized():
    ledger = [
        dict(_grant_row(rid=1), created_at="2026-10-10T00:00:00+00:00"),
        dict(_grant_row(rid=2), created_at="2026-10-12T00:00:00+00:00"),
    ]
    h = R.history(ledger, user_id=1, lang="en")
    assert h[0]["created_at"] > h[1]["created_at"], h
    assert h[0]["label"] == "Referral reward", h
    hb = R.history(ledger, user_id=1, lang="bn")
    assert hb[0]["label"] != "Referral reward", hb  # localized to bn


# --- redeem math ------------------------------------------------------------

def test_redeem_math_whole_days_only():
    # balance of 2 referrals = 100 points; rate 25/day => 4 days, 100 spent
    ledger = [_grant_row(rid=1, invitee=2, device="dA"),
              _grant_row(rid=2, invitee=3, device="dB")]
    assert R.balance(ledger, user_id=1) == 100
    res = R.redeem(1, 100, ledger, now=NOW)
    assert res["ok"], res
    assert res["days"] == 4, res
    assert res["spent"] == 100, res
    assert res["row"]["points"] == -100, res


def test_redeem_floors_and_keeps_remainder():
    ledger = [_grant_row(rid=1, invitee=2, device="dA")]  # 50 points
    # ask for 60 (> balance) rejected
    res = R.redeem(1, 60, ledger, now=NOW)
    assert not res["ok"] and res["code"] == "insufficient_balance", res
    # ask for 50; 50/25 = 2 days, spend 50 exactly
    res = R.redeem(1, 50, ledger, now=NOW)
    assert res["ok"] and res["days"] == 2 and res["spent"] == 50, res
    # a non-multiple redeem floors: 30 points -> 1 day, spend 25, keep 5
    led2 = [_grant_row(rid=1, invitee=2, device="dA")]  # 50 points
    res = R.redeem(1, 30, led2, now=NOW)
    assert res["ok"] and res["days"] == 1 and res["spent"] == 25, res


def test_redeem_below_minimum_rejected():
    ledger = [_grant_row(rid=1, invitee=2, device="dA")]
    res = R.redeem(1, R.MIN_REDEEM_POINTS - 1, ledger, now=NOW)
    assert not res["ok"] and res["code"] == "below_minimum", res


def test_points_days_conversions():
    assert R.points_to_days(100, rate=25) == 4
    assert R.points_to_days(99, rate=25) == 3
    assert R.days_to_points(3, rate=25) == 75


def test_summary_can_redeem_flag():
    ledger = [_grant_row(rid=1, invitee=2, device="dA")]  # 50 points
    s = R.referral_summary(ledger, 1, lang="en")
    assert s["points"] == 50 and s["redeemable_days"] == 2, s
    assert s["can_redeem"] is True, s
    empty = R.referral_summary([], 1, lang="en")
    assert empty["points"] == 0 and empty["can_redeem"] is False, empty


def _redeem_row(inviter=1, points=-25, rid=900):
    return {
        "id": rid, "kind": R.KIND_REDEEM, "user_id": inviter,
        "points": points, "reason": R.REASON_REDEEM_PREMIUM,
        "invitee_id": None, "device_id": None, "reverses": None,
        "month": "2026-10", "created_at": "2026-10-13T13:00:00+00:00",
    }


# --- ADVANCED (#102 advanced) -----------------------------------------------

def test_joined_count_and_my_referrals_ignore_clawed():
    led = [
        _grant_row(rid=1, invitee=2, device="dA"),
        _grant_row(rid=2, invitee=3, device="dB"),
        {"id": 9, "kind": R.KIND_CLAWBACK, "user_id": 1, "points": -50,
         "reason": R.REASON_CLAWBACK_FAKE, "invitee_id": 3, "device_id": "dB",
         "reverses": 2, "month": "2026-10",
         "created_at": "2026-10-13T12:30:00+00:00"},
    ]
    # invitee 3's grant was clawed back => only 1 genuine join remains
    assert R.joined_count(led, 1) == 1, R.joined_count(led, 1)
    assert [r["invitee_id"] for r in R.my_referrals(led, 1)] == [2]


def test_progress_from_backend_constants_only():
    # 1 referral = 50 pts, 25 pts/day => 1 friend already buys a whole day,
    # friends_per_day == 1, and the next whole day needs 1 more friend.
    led = [_grant_row(rid=1, invitee=2, device="dA")]
    p = R.progress(led, 1)  # uses POINTS_PER_REFERRAL=50, rate=25
    assert p["friends_joined"] == 1, p
    assert p["points_per_referral"] == R.POINTS_PER_REFERRAL, p
    assert p["points_per_day"] == R.POINTS_PER_PREMIUM_DAY, p
    assert p["days_earned_total"] == 2, p      # 50 pts // 25 = 2 days
    assert p["friends_per_day"] == 1, p
    assert p["friends_to_next_day"] == 1, p
    # empty ledger: zero progress, still consistent, no crash
    e = R.progress([], 1)
    assert e["friends_joined"] == 0 and e["days_earned_total"] == 0, e
    assert 0.0 <= e["progress_to_next_day"] <= 1.0, e


def test_leaderboard_is_honest_no_nonjoiners():
    led = [
        _grant_row(rid=1, invitee=2, device="dA"),
        _grant_row(rid=2, invitee=3, device="dB"),
    ]
    lb = R.invite_leaderboard(led, 1, lang="en")
    assert len(lb) == 2 and lb[0]["rank"] == 1, lb
    # only real joiners appear; ids are circle invitees, nothing else leaked
    ids = {row["invitee_id"] for row in lb}
    assert ids == {2, 3}, ids
    assert all(set(row) >= {"rank", "invitee_id", "points", "created_at"}
               for row in lb)


def test_audit_reconciles_to_balance():
    led = [
        _grant_row(rid=1, invitee=2, device="dA"),   # +50
        _grant_row(rid=2, invitee=3, device="dB"),   # +50
        _redeem_row(points=-25, rid=900),            # -25 spent
    ]
    a = R.audit(led, 1, lang="en")
    assert a["earned_total"] == 100, a
    assert a["spent_total"] == 25, a
    assert a["reversed_total"] == 0, a
    assert a["balance"] == R.balance(led, 1) == 75, (a, R.balance(led, 1))


def test_redeemed_history_recomputes_days():
    led = [_redeem_row(points=-50, rid=901)]
    h = R.redeemed_history(led, 1, lang="en")
    assert len(h) == 1 and h[0]["spent"] == 50 and h[0]["days"] == 2, h


def test_advanced_summary_is_superset():
    led = [_grant_row(rid=1, invitee=2, device="dA")]
    s = R.advanced_summary(led, 1, lang="en")
    # has every referral_summary key plus the advanced bundles
    base = R.referral_summary(led, 1, lang="en")
    assert set(s) >= set(base), set(base) - set(s)
    assert {"progress", "leaderboard", "audit", "redeemed"} <= set(s), set(s)


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"referral: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
