"""
blood_donor_tests_snippets.py — plain-assert tests for the BLOOD-DONOR NETWORK
(#188, §20). Pure stdlib. `python blood_donor_tests_snippets.py` or import and
call run_all(). Deterministic; every assertion hand-verified against fixed
inputs (a fixed `today` so date math never drifts).
"""

try:  # Django harness
    from core.logic import blood_donor as B
except ImportError:  # standalone
    import blood_donor as B  # noqa: E402

TODAY = "2026-06-01"


# --------------------------------------------------------------- groups

def test_normalise_group():
    assert B.normalise_group("o+") == "O+"
    assert B.normalise_group("A positive") == "A+"
    assert B.normalise_group("ab negative") == "AB-"
    assert B.normalise_group("  b-  ") == "B-"
    assert B.normalise_group("Z+") is None
    assert B.normalise_group("") is None


# --------------------------------------------------------------- eligibility

def test_next_eligible_date_is_interval_days_later():
    # 2026-03-01 + 90 days = 2026-05-30
    assert B.next_eligible_date("2026-03-01") == __import__(
        "datetime").date(2026, 5, 30)
    assert B.next_eligible_date(None) is None
    assert B.next_eligible_date("garbage") is None


def test_eligibility_resting_when_within_interval():
    e = B.eligibility("2026-05-01", today=TODAY)  # +90 = 2026-07-30
    assert e["state"] == "resting"
    assert e["eligible"] is False
    assert e["has_history"] is True
    assert e["days_left"] == 59  # 2026-06-01 -> 2026-07-30
    assert e["next_date"] == "2026-07-30"


def test_eligibility_eligible_after_interval():
    e = B.eligibility("2026-01-01", today=TODAY)  # +90 = 2026-04-01 (past)
    assert e["state"] == "eligible"
    assert e["eligible"] is True
    assert e["days_left"] == 0


def test_eligibility_unknown_history_counts_as_eligible():
    e = B.eligibility(None, today=TODAY)
    assert e["state"] == "unknown"
    assert e["eligible"] is True
    assert e["has_history"] is False
    assert e["next_date"] is None


# --------------------------------------------------------------- compatibility

def test_universal_donor_and_recipient():
    assert B.can_donate_to("O-", "AB+") is True
    assert B.can_donate_to("O-", "O-") is True
    # AB+ can only give to AB+
    assert B.can_donate_to("AB+", "O-") is False
    assert B.can_donate_to("AB+", "AB+") is True


def test_can_donate_rejects_unknown_group():
    assert B.can_donate_to("Z+", "O+") is False
    assert B.can_donate_to("O+", "") is False


def test_compatible_donor_groups_for_recipient():
    # Anyone who can give to O+ : O+ and O-
    assert B.compatible_donor_groups("O+") == ["O+", "O-"]
    # AB+ can receive from everyone
    assert B.compatible_donor_groups("AB+") == list(B.BLOOD_GROUPS)
    assert B.compatible_donor_groups("Z") == []


# --------------------------------------------------------------- privacy

def test_contact_hidden_by_default():
    card = B.public_donor_card(
        {"id": 1, "name": "Rahim", "blood_group": "o+", "phone": "017xxxxxxxx"},
        today=TODAY)
    assert card["share_contact"] is False
    assert card["contact_hidden"] is True
    assert card["phone"] is None  # NEVER leaked without opt-in


def test_contact_shown_only_on_opt_in():
    card = B.public_donor_card(
        {"id": 2, "name": "Karim", "blood_group": "A+",
         "phone": "01711111111", "share_contact": True},
        today=TODAY)
    assert card["share_contact"] is True
    assert card["contact_hidden"] is False
    assert card["phone"] == "01711111111"


# --------------------------------------------------------------- search

def _sample():
    return [
        {"id": 1, "name": "Rahim", "blood_group": "O+", "area": "Mirpur",
         "availability": "available", "last_donation": "2026-01-01"},  # eligible
        {"id": 2, "name": "Karim", "blood_group": "O+", "area": "Mirpur",
         "availability": "available", "last_donation": "2026-05-01"},  # resting
        {"id": 3, "name": "Shila", "blood_group": "A+", "area": "Uttara",
         "availability": "unavailable", "last_donation": None},
        {"id": 4, "name": "Bablu", "blood_group": "O-", "area": "Mirpur",
         "availability": "available", "last_donation": "2026-01-01"},  # eligible
    ]


def test_search_by_group_and_area():
    res = B.search_donors(_sample(), blood_group="o+", area="mirpur",
                          today=TODAY)
    assert [c["id"] for c in res] == [1, 2]  # both O+ in Mirpur


def test_search_ranks_eligible_available_first():
    res = B.search_donors(_sample(), blood_group="O+", today=TODAY)
    # id 1 is eligible+available -> tier 0, id 2 resting -> tier 1
    assert res[0]["id"] == 1
    assert res[1]["id"] == 2


def test_search_only_available_and_only_eligible():
    res = B.search_donors(_sample(), only_available=True, only_eligible=True,
                          today=TODAY)
    ids = {c["id"] for c in res}
    assert ids == {1, 4}  # 2 resting, 3 unavailable


def test_search_compatible_for_recipient():
    # Recipient A+ can take from A+, A-, O+, O-. Of the sample: 1,2 (O+),
    # 3 (A+), 4 (O-).
    res = B.search_donors(_sample(), compatible_for="A+", today=TODAY)
    assert {c["id"] for c in res} == {1, 2, 3, 4}
    # Recipient O- can take only from O-: id 4
    res2 = B.search_donors(_sample(), compatible_for="O-", today=TODAY)
    assert {c["id"] for c in res2} == {4}


def test_search_never_leaks_phone_without_opt_in():
    donors = [{"id": 9, "name": "X", "blood_group": "O+",
               "phone": "0170000000", "availability": "available"}]
    res = B.search_donors(donors, blood_group="O+", today=TODAY)
    assert res[0]["phone"] is None and res[0]["contact_hidden"] is True


# --------------------------------------------------------------- summary

def test_registry_summary_counts():
    s = B.registry_summary(_sample(), today=TODAY)
    assert s["total"] == 4
    assert s["available_now"] == 3  # 1,2,4
    assert s["eligible_now"] == 3   # 1,4 eligible + 3 (unknown history => eligible)
    assert s["by_group"]["O+"] == 2
    assert "bn" in s["note"] and "en" in s["note"]


# --------------------------------------------------------------- validation

def test_validate_donor():
    assert "name_required" in B.validate_donor(
        {"blood_group": "O+"})
    assert "blood_group_required" in B.validate_donor(
        {"name": "A", "blood_group": "Z"})
    assert "bad_last_donation" in B.validate_donor(
        {"name": "A", "blood_group": "O+", "last_donation": "nope"})
    assert "share_on_without_phone" in B.validate_donor(
        {"name": "A", "blood_group": "O+", "share_contact": True})
    assert B.validate_donor(
        {"name": "A", "blood_group": "O+", "last_donation": "2026-01-01",
         "availability": "available"}) == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"blood_donor: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
