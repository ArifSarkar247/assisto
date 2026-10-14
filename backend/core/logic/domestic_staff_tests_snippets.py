"""
domestic_staff_tests_snippets.py — plain-assert tests for DOMESTIC STAFF /
DRIVER tracker (#186, §20). Pure stdlib. Deterministic engine, every assertion
hand-verified against fixed inputs. `python domestic_staff_tests_snippets.py`
or import and call run_all().
"""

try:  # Django harness
    from core.logic import domestic_staff as D
except ImportError:  # standalone
    import domestic_staff as D  # noqa: E402


# --------------------------------------------------------------- poisha
def test_to_poisha_is_exact_integer():
    assert D.to_poisha("12000") == 1200000
    assert D.to_poisha("12.50") == 1250
    assert D.to_poisha("12.505") == 1251
    assert D.to_poisha(500) == 500  # already poisha
    assert D.to_poisha(True) == 0
    assert D.to_poisha("junk") == 0


def test_fmt_poisha_taka_sign_and_grouping():
    assert D.fmt_poisha(1200000) == "৳12,000.00"
    assert D.fmt_poisha(-5000) == "-৳50.00"
    assert D.fmt_poisha(0) == "৳0.00"


def test_role_label_bilingual():
    assert D.role_label("driver", "en") == "Driver"
    assert D.role_label("driver", "bn") != "Driver"
    assert D.role_label("", "en") == "Other"


# --------------------------------------------------------------- pro-rate
def test_full_month_pays_full_salary_exactly():
    # 8000 taka, full month -> exactly 800000 poisha, no rounding loss
    assert D.month_due_poisha("8000") == 800000
    assert D.month_due_poisha("8000", 30, 30) == 800000
    assert D.month_due_poisha("8000", 31, 30) == 800000  # present>=month


def test_partial_month_is_floored_integer():
    # 8000 over 30 days, present 15 -> floor(800000*15/30) = 400000
    assert D.month_due_poisha("8000", 15, 30) == 400000
    # 8000, present 10 of 30 -> floor(800000*10/30)=266666
    assert D.month_due_poisha("8000", 10, 30) == 266666


def test_bad_attendance_never_deducts():
    # negative day count -> full salary (a bad entry never shortchanges worker)
    assert D.month_due_poisha("8000", -5, 30) == 800000
    assert D.month_due_poisha("0") == 0


# --------------------------------------------------------------- per-month
def test_person_month_outstanding_and_state():
    person = {"id": 1, "name": "Rahima", "role": "maid", "salary": "8000"}
    payments = [
        {"person": 1, "month": "2026-10", "kind": "salary", "amount": "5000"},
    ]
    r = D.person_month(person, payments, "2026-10", lang="en")
    assert r["due"] == 800000
    assert r["paid"] == 500000
    assert r["outstanding"] == 300000  # still owed 3000
    assert r["state"] == "owed"


def test_person_month_settled_and_overpaid():
    person = {"id": 1, "name": "A", "salary": "5000"}
    pay_full = [{"person": 1, "month": "2026-10", "amount": "5000"}]
    r = D.person_month(person, pay_full, "2026-10")
    assert r["outstanding"] == 0 and r["state"] == "settled"
    pay_over = [{"person": 1, "month": "2026-10", "amount": "6000"}]
    r2 = D.person_month(person, pay_over, "2026-10")
    assert r2["outstanding"] == -100000 and r2["state"] == "overpaid"


def test_attendance_prorates_the_month_due():
    person = {"id": 1, "name": "A", "salary": "8000"}
    pay = [{"person": 1, "month": "2026-10", "kind": "salary",
            "amount": "0", "present_days": 15, "month_days": 30}]
    r = D.person_month(person, pay, "2026-10")
    assert r["due"] == 400000  # pro-rated half month
    assert r["present_days"] == 15


def test_advances_tracked_separately_in_month():
    person = {"id": 1, "name": "A", "salary": "5000"}
    pay = [
        {"person": 1, "month": "2026-10", "kind": "salary", "amount": "5000"},
        {"person": 1, "month": "2026-10", "kind": "advance", "amount": "1000"},
    ]
    r = D.person_month(person, pay, "2026-10")
    assert r["outstanding"] == 0  # wages settled; advance NOT netted into month
    assert r["advance"] == 100000


# --------------------------------------------------------------- summary
def test_person_summary_net_dues_and_advance():
    person = {"id": 1, "name": "Rahima", "role": "maid",
              "salary": "8000", "join_date": "2026-09"}
    payments = [
        # Sept: fully paid
        {"person": 1, "month": "2026-09", "kind": "salary", "amount": "8000"},
        # Oct: paid only 5000 -> owed 3000
        {"person": 1, "month": "2026-10", "kind": "salary", "amount": "5000"},
        # advance of 2000 taken, 500 repaid -> advance balance 1500
        {"person": 1, "month": "2026-10", "kind": "advance", "amount": "2000"},
        {"person": 1, "month": "2026-10", "kind": "repay", "amount": "500"},
    ]
    s = D.person_summary(person, payments, "2026-10", lang="en")
    assert s["wages_outstanding"] == 300000  # 3000 unpaid wages
    assert s["advance_balance"] == 150000    # 2000 - 500
    # net = wages owed - advance held = 3000 - 1500 = 1500 (you still owe)
    assert s["net_dues"] == 150000
    assert s["state"] == "owed"
    # months newest-first
    assert s["months"][0]["month"] == "2026-10"


def test_person_summary_advance_due_state():
    person = {"id": 1, "name": "A", "salary": "5000", "join_date": "2026-10"}
    payments = [
        {"person": 1, "month": "2026-10", "kind": "salary", "amount": "5000"},
        {"person": 1, "month": "2026-10", "kind": "advance", "amount": "3000"},
    ]
    s = D.person_summary(person, payments, "2026-10")
    assert s["wages_outstanding"] == 0
    assert s["advance_balance"] == 300000
    assert s["net_dues"] == -300000  # worker owes back 3000 of advance
    assert s["state"] == "advance_due"


def test_person_summary_settled():
    person = {"id": 1, "name": "A", "salary": "5000", "join_date": "2026-10"}
    payments = [{"person": 1, "month": "2026-10", "amount": "5000"}]
    s = D.person_summary(person, payments, "2026-10")
    assert s["net_dues"] == 0 and s["state"] == "settled"


def test_summary_walks_every_month_join_to_now():
    person = {"id": 1, "name": "A", "salary": "1000", "join_date": "2026-08"}
    s = D.person_summary(person, [], "2026-10")
    months = [m["month"] for m in s["months"]]
    assert months == ["2026-10", "2026-09", "2026-08"]
    assert s["total_due"] == 300000  # 3 months unpaid
    assert s["wages_outstanding"] == 300000


def test_household_summary_sorted_most_owed_first():
    people = [
        {"id": 1, "name": "Low", "salary": "1000", "join_date": "2026-10"},
        {"id": 2, "name": "High", "salary": "9000", "join_date": "2026-10"},
    ]
    s = D.household_summary(people, [], "2026-10", lang="en")
    assert s["count"] == 2
    assert s["total_monthly_salary"] == 1000000  # 10000 taka
    assert s["people"][0]["name"] == "High"  # owed most sorts first
    assert s["anyone_owed"] is True


def test_no_money_note_present_and_bilingual():
    s = D.person_summary({"id": 1, "name": "A", "salary": "1", "join_date": "2026-10"},
                         [], "2026-10")
    assert "bn" in s["note"] and "en" in s["note"]


def test_summary_is_deterministic():
    person = {"id": 1, "name": "A", "salary": "7777", "join_date": "2026-07"}
    pay = [{"person": 1, "month": "2026-08", "amount": "3000"}]
    a = D.person_summary(person, pay, "2026-10", lang="en")
    b = D.person_summary(person, pay, "2026-10", lang="en")
    assert a == b


def test_empty_household_is_honest():
    s = D.household_summary([], [], "2026-10")
    assert s["count"] == 0
    assert s["total_net_dues"] == 0
    assert s["people"] == []
    assert s["anyone_owed"] is False


# --------------------------------------------------------------- validation
def test_validate_person():
    people = [{"name": "Karim"}]
    assert "name_required" in D.validate_person("  ", "5000", people)
    assert "duplicate_name" in D.validate_person("karim", "5000", people)
    assert "salary_required" in D.validate_person("Rahim", "0", people)
    assert D.validate_person("Rahim", "5000", people) == []


def test_validate_payment():
    assert "amount_required" in D.validate_payment("0", "salary")
    assert "bad_kind" in D.validate_payment("100", "bogus")
    assert D.validate_payment("100", "advance") == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"domestic_staff: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
