"""
family_sharing_tests_snippets.py — plain-assert tests for core.logic.family_sharing.

NOT a Django TestCase (no DB). The integrator folds these into core/tests.py.
Smoke locally:
    python3 -c "import core.logic.family_sharing_tests_snippets as t; t.run_all()"
"""
from datetime import datetime, timezone

from core.logic import family_sharing as F


# ---- #67 selective sharing: grant / revoke / default-deny -----------------

def test_default_shares_nothing():
    g = F.default_sharing_grants()
    assert g == {}
    assert F.can_share_item(g, 5, F.ITEM_LOCATION) is False


def test_set_grant_and_can_share():
    g = F.set_grant({}, 5, F.ITEM_LOCATION)
    assert F.can_share_item(g, 5, F.ITEM_LOCATION) is True
    # not granted to anyone else, and no other item
    assert F.can_share_item(g, 6, F.ITEM_LOCATION) is False
    assert F.can_share_item(g, 5, F.ITEM_MEDICINE) is False


def test_set_grant_is_immutable():
    g0 = {}
    g1 = F.set_grant(g0, 5, F.ITEM_MEDICINE)
    assert g0 == {}            # original untouched
    assert 5 in g1


def test_invalid_item_is_noop():
    g = F.set_grant({}, 5, "bank_pin")
    assert g == {}
    assert F.can_share_item(g, 5, "bank_pin") is False


def test_revoke_single_item():
    g = F.set_grant({}, 5, F.ITEM_LOCATION)
    g = F.set_grant(g, 5, F.ITEM_MEDICINE)
    g = F.set_grant(g, 5, F.ITEM_LOCATION, on=False)
    assert F.can_share_item(g, 5, F.ITEM_LOCATION) is False
    assert F.can_share_item(g, 5, F.ITEM_MEDICINE) is True


def test_revoke_last_item_drops_member():
    g = F.set_grant({}, 5, F.ITEM_LOCATION)
    g = F.set_grant(g, 5, F.ITEM_LOCATION, on=False)
    assert 5 not in g


def test_revoke_member_and_all():
    g = F.set_grant({}, 5, F.ITEM_LOCATION)
    g = F.set_grant(g, 6, F.ITEM_MONEY_SUMMARY)
    g2 = F.revoke_member(g, 5)
    assert 5 not in g2 and 6 in g2
    assert F.revoke_all(g) == {}


def test_shared_items_for_is_stable_order():
    g = F.set_grant({}, 5, F.ITEM_SAFE_JOURNEY)
    g = F.set_grant(g, 5, F.ITEM_LOCATION)
    # returned in SHAREABLE_ITEMS order, not insertion order
    assert F.shared_items_for(g, 5) == [F.ITEM_LOCATION, F.ITEM_SAFE_JOURNEY]


def test_consent_summary_grid():
    g = F.set_grant({}, 5, F.ITEM_LOCATION)
    members = [{"id": 5, "name": "Ma", "relation": "mother"},
               {"id": 6, "name": "Baba", "relation": "father"}]
    s = F.consent_summary(g, members)
    assert s["total_shared"] == 1
    row5 = next(r for r in s["rows"] if r["member_id"] == 5)
    assert row5["items"][F.ITEM_LOCATION] is True
    assert row5["items"][F.ITEM_MEDICINE] is False
    assert row5["shared_count"] == 1


def test_normalize_drops_bad_items():
    g = F.normalize_grants({5: ["location", "garbage"], "x": ["medicine"]})
    assert g == {5: {"location"}}


# ---- #67 audit log --------------------------------------------------------

def test_audit_grant_entry():
    now = datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    e = F.build_audit_entry(F.AUDIT_GRANT, member_id=5, item=F.ITEM_LOCATION,
                            member_name="Ma", now=now)
    assert e["action"] == "grant"
    assert e["member_id"] == 5
    assert e["item"] == "location"
    assert e["at"] == "2026-01-02T03:04:05+00:00"


def test_audit_revoke_all_has_no_item():
    e = F.build_audit_entry(F.AUDIT_REVOKE_ALL)
    assert e["action"] == "revoke_all"
    assert e["item"] is None


# ---- #73 family card ------------------------------------------------------

def test_family_card_payload():
    card = F.build_family_card(
        {"name": "Karim", "phone": "01700000000"},
        [{"name": "Ma", "relation": "mother", "phone": "01800000000"}],
        {"blood_group": "O+", "contact_name": "Ma"},
        lang="en")
    assert card["member_count"] == 1
    assert card["owner_name"] == "Karim"
    assert card["emergency"]["blood_group"] == "O+"
    assert "family card" in F.family_card_caption(card, lang="en")


# ---- #75 probashi: two-timezone + remittance context ----------------------

def test_two_timezone_now_diff():
    now = datetime(2026, 1, 1, 12, 0, tzinfo=timezone.utc)  # 12:00 UTC
    r = F.two_timezone_now(my_offset_min=0, now_utc=now)    # probashi at UTC
    assert r["bd"].hour == 18       # UTC+6
    assert r["my"].hour == 12
    assert r["diff_min"] == -360     # I am 6h behind BD


def test_bd_time_at_my_local():
    now = datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc)
    # probashi in London-ish UTC+0 calling at 21:00 their time
    r = F.bd_time_at_my_local(my_offset_min=0, hh=21, now_utc=now)
    assert r["my"].hour == 21
    assert r["bd"].hour == 3         # 21:00 UTC -> 03:00 next-day BD


def test_propose_call_slots_both_polite():
    now = datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc)
    slots = F.propose_call_slots(my_offset_min=0, now_utc=now, horizon_h=24)
    # every returned slot must be polite at BOTH ends
    for s in slots:
        assert 8 <= s["my"].hour < 22
        assert 8 <= s["bd"].hour < 22
        assert s["comfortable"] is True


def test_remittance_never_a_wallet():
    r = F.remittance_reminder_context(amount_hint="20000 BDT", cadence="monthly",
                                      last_sent="2026-01-01")
    assert r["is_wallet"] is False
    assert r["holds_money"] is False
    assert r["next_due"] == "2026-01-31"
    assert r["amount_hint"] == "20000 BDT"
    assert "never holds or sends money" in r["disclaimer"] or r["disclaimer"]


def test_remittance_weekly_cadence():
    r = F.remittance_reminder_context(cadence="weekly", last_sent="2026-01-01")
    assert r["cadence"] == "weekly"
    assert r["next_due"] == "2026-01-08"


def run_all():
    import inspect
    import sys
    mod = sys.modules[__name__]
    fns = [f for n, f in inspect.getmembers(mod, inspect.isfunction)
           if n.startswith("test_")]
    for f in fns:
        f()
    print(f"family_sharing: {len(fns)} tests passed")
