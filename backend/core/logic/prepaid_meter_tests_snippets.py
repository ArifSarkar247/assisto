"""
prepaid_meter_tests_snippets.py — plain-assert tests for the PREPAID-METER
tracker (#193, §20). Pure stdlib. `python prepaid_meter_tests_snippets.py` or
import and call run_all(). Deterministic; fixed `as_of` so projection math never
drifts. Every assertion hand-verified against the integer-poisha model.
"""

try:  # Django harness
    from core.logic import prepaid_meter as M
except ImportError:  # standalone
    import prepaid_meter as M  # noqa: E402

AS_OF = "2026-06-20"


# --------------------------------------------------------------- poisha

def test_poisha_and_fmt():
    assert M.to_poisha("500") == 50000
    assert M.to_poisha("12.50") == 1250
    assert M.fmt_poisha(50000) == "৳500.00"
    assert M.fmt_poisha(1250) == "৳12.50"


# --------------------------------------------------------------- consumption

def test_daily_consumption_from_closed_intervals():
    # recharges: 1 Jun 500, 11 Jun 500 (span 10 days); consumed = first 500
    # over 10 days = 5000 poisha/day (=৳50/day)
    rr = [{"date": "2026-06-01", "amount": "500"},
          {"date": "2026-06-11", "amount": "500"}]
    c = M.daily_consumption(rr, as_of=AS_OF)
    assert c["span_days"] == 10
    assert c["rate"] == 5000
    assert c["confident"] is True


def test_daily_consumption_unknown_when_thin():
    assert M.daily_consumption([], as_of=AS_OF)["confident"] is False
    one = [{"date": "2026-06-01", "amount": "500"}]
    assert M.daily_consumption(one, as_of=AS_OF)["rate"] == 0
    same_day = [{"date": "2026-06-01", "amount": "500"},
                {"date": "2026-06-01", "amount": "500"}]
    assert M.daily_consumption(same_day, as_of=AS_OF)["confident"] is False


def test_daily_consumption_ignores_bad_rows():
    rr = [{"date": "2026-06-01", "amount": "500"},
          {"date": "bad", "amount": "999"},
          {"date": "2026-06-11", "amount": "0"},
          {"date": "2026-06-11", "amount": "500"}]
    c = M.daily_consumption(rr, as_of=AS_OF)
    assert c["span_days"] == 10 and c["rate"] == 5000


# --------------------------------------------------------------- balance

def test_balance_from_last_recharge_decayed():
    # rate ৳50/day; last recharge 11 Jun 500; as_of 20 Jun = 9 days later.
    # balance = 50000 - 5000*9 = 5000 poisha (৳50)
    rr = [{"date": "2026-06-01", "amount": "500"},
          {"date": "2026-06-11", "amount": "500"}]
    b = M.current_balance({}, rr, as_of=AS_OF)
    assert b["basis"] == "last_recharge"
    assert b["balance"] == 5000


def test_balance_from_explicit_reading():
    rr = [{"date": "2026-06-01", "amount": "500"},
          {"date": "2026-06-11", "amount": "500"}]  # rate 5000/day
    meter = {"balance": "200", "balance_date": "2026-06-18"}  # 2 days ago
    b = M.current_balance(meter, rr, as_of=AS_OF)
    assert b["basis"] == "reading"
    assert b["balance"] == 20000 - 5000 * 2  # 10000 poisha


def test_balance_never_negative():
    rr = [{"date": "2026-01-01", "amount": "500"},
          {"date": "2026-01-11", "amount": "500"}]  # long ago
    b = M.current_balance({}, rr, as_of=AS_OF)
    assert b["balance"] == 0


# --------------------------------------------------------------- projection

def test_project_runout_ok_vs_low():
    # rate ৳50/day, balance ৳50 on 20 Jun -> 1 day left -> LOW (<5)
    rr = [{"date": "2026-06-01", "amount": "500"},
          {"date": "2026-06-11", "amount": "500"}]
    p = M.project_runout({}, rr, as_of=AS_OF)
    assert p["rate"] == 5000
    assert p["balance"] == 5000
    assert p["days_left"] == 1
    assert p["state"] == "low"
    assert p["low"] is True
    assert p["runout_date"] == "2026-06-21"


def test_project_runout_ok_state():
    # Big last recharge, modest rate -> many days left -> ok
    rr = [{"date": "2026-06-01", "amount": "300"},
          {"date": "2026-06-16", "amount": "3000"}]  # rate 30000/15=2000/day
    # balance = 300000 - 2000*4(days since 16->20) = 292000; days = 146 -> ok
    p = M.project_runout({}, rr, as_of=AS_OF)
    assert p["state"] == "ok"
    assert p["low"] is False
    assert p["days_left"] is not None and p["days_left"] >= M.DEFAULT_LOW_DAYS


def test_project_runout_unknown_when_no_rate():
    one = [{"date": "2026-06-18", "amount": "500"}]
    p = M.project_runout({}, one, as_of=AS_OF)
    assert p["state"] == "unknown"
    assert p["days_left"] is None
    assert p["runout_date"] is None


def test_project_runout_empty():
    p = M.project_runout({}, [], as_of=AS_OF)
    assert p["state"] == "empty"
    assert p["balance"] == 0
    assert p["low"] is True


def test_project_note_bilingual():
    p = M.project_runout({}, [], as_of=AS_OF)
    assert "bn" in p["note"] and "en" in p["note"]


# --------------------------------------------------------------- overview

def test_meters_overview_sorts_low_first():
    meters = [{"id": 1, "name": "Flat", "kind": "electricity"},
              {"id": 2, "name": "Kitchen", "kind": "gas"}]
    rr = {
        1: [{"date": "2026-06-01", "amount": "300"},
            {"date": "2026-06-16", "amount": "3000"}],   # ok
        2: [{"date": "2026-06-01", "amount": "500"},
            {"date": "2026-06-11", "amount": "500"}],    # low
    }
    ov = M.meters_overview(meters, rr, as_of=AS_OF)
    assert ov[0]["id"] == 2  # low surfaces first
    assert ov[0]["state"] == "low"
    assert ov[0]["total_recharged"] == 100000  # ৳1000


# --------------------------------------------------------------- validation

def test_validate_meter():
    assert "name_required" in M.validate_meter({"kind": "electricity"})
    assert "bad_kind" in M.validate_meter({"name": "A", "kind": "water"})
    assert "bad_balance_date" in M.validate_meter(
        {"name": "A", "balance_date": "nope"})
    assert M.validate_meter({"name": "A", "kind": "gas"}) == []


def test_validate_recharge():
    assert "amount_required" in M.validate_recharge(
        {"date": "2026-06-01", "meter": 1})
    assert "date_required" in M.validate_recharge(
        {"amount": "500", "meter": 1})
    assert "meter_required" in M.validate_recharge(
        {"amount": "500", "date": "2026-06-01"})
    assert M.validate_recharge(
        {"amount": "500", "date": "2026-06-01", "meter": 1}) == []


# --------------------------------------------------------------- seam

def test_live_seam_is_honest_and_inert():
    s = M.live_balance_seam()
    assert s["available"] is False
    assert s["reason"] == "no_live_utility_key"
    assert "bn" in s["note"] and "en" in s["note"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"prepaid_meter: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
