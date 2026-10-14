"""
farmer_mode_tests_snippets.py — plain-assert tests for FARMER / VILLAGE MODE
(#199, §20). Pure stdlib. `python farmer_mode_tests_snippets.py` or import and
call run_all(). The engine is deterministic (callers pass `now`), so every
assertion below is hand-verified against fixed inputs.
"""

from datetime import date

try:  # Django harness
    from core.logic import farmer_mode as F
except ImportError:  # standalone
    import farmer_mode as F  # noqa: E402


# --------------------------------------------------------------- ledger status

def test_status_planned_when_no_dates():
    assert F.record_status({"name": "Boro"}, now=date(2026, 1, 1)) == F.STATUS_PLANNED


def test_status_growing_when_planted_only():
    row = {"name": "Boro", "planted": "2026-11-01"}
    assert F.record_status(row, now=date(2026, 12, 1)) == F.STATUS_GROWING


def test_status_harvested_when_harvest_date_passed():
    row = {"name": "Boro", "planted": "2025-11-01", "harvest": "2026-03-01"}
    assert F.record_status(row, now=date(2026, 3, 2)) == F.STATUS_HARVESTED


def test_status_sold_when_income_recorded():
    row = {"name": "Boro", "planted": "2025-11-01",
           "harvest": "2026-03-01", "income": 5000}
    # income wins even though harvest also passed
    assert F.record_status(row, now=date(2026, 3, 2)) == F.STATUS_SOLD


def test_status_future_harvest_still_growing():
    row = {"name": "Boro", "planted": "2026-11-01", "harvest": "2027-03-01"}
    assert F.record_status(row, now=date(2026, 12, 1)) == F.STATUS_GROWING


# --------------------------------------------------------------- profit math

def test_profit_basic():
    p = F.record_profit({"cost": 2000, "income": 5000})
    assert p["cost"] == 2000
    assert p["income"] == 5000
    assert p["profit"] == 3000
    assert p["margin_pct"] == 60.0
    assert p["profitable"] is True


def test_profit_loss():
    p = F.record_profit({"cost": 6000, "income": 5000})
    assert p["profit"] == -1000
    assert p["profitable"] is False


def test_profit_no_income_no_margin():
    p = F.record_profit({"cost": 2000})
    assert p["income"] == 0
    assert p["profit"] == -2000
    assert p["margin_pct"] is None
    assert p["profitable"] is False


def test_profit_blank_fields_are_zero_not_crash():
    p = F.record_profit({"cost": "", "income": None})
    assert p["cost"] == 0 and p["income"] == 0 and p["profit"] == 0


def test_profit_never_invents_a_price():
    # with no income the engine reports a loss equal to cost, not a guess
    p = F.record_profit({"name": "Potato", "cost": 3500})
    assert p["income"] == 0


# --------------------------------------------------------------- ledger summary

def test_ledger_summary_aggregates_and_counts():
    rows = [
        {"name": "Boro", "cost": 2000, "income": 5000,
         "planted": "2025-11-01", "harvest": "2026-03-01"},   # sold
        {"name": "Jute", "cost": 1500, "planted": "2026-04-01"},  # growing
        {"name": "Wheat"},                                      # planned
    ]
    s = F.ledger_summary(rows, now=date(2026, 5, 1))
    assert s["count"] == 3
    assert s["total_cost"] == 3500
    assert s["total_income"] == 5000
    assert s["net_profit"] == 1500
    assert s["profitable"] is True
    assert s["status_counts"][F.STATUS_SOLD] == 1
    assert s["status_counts"][F.STATUS_GROWING] == 1
    assert s["status_counts"][F.STATUS_PLANNED] == 1


def test_ledger_summary_empty():
    s = F.ledger_summary([], now=date(2026, 1, 1))
    assert s["count"] == 0 and s["net_profit"] == 0 and s["profitable"] is False


# --------------------------------------------------------------- crop calendar

def test_season_for_month_windows():
    assert F.season_for_month(11) == "rabi"      # sowing rabi
    assert F.season_for_month(3) == "kharif1"    # sowing kharif1
    assert F.season_for_month(7) == "kharif2"    # sowing kharif2 (sow pref)


def test_season_for_month_rejects_bad():
    try:
        F.season_for_month(13)
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_season_now_deterministic():
    assert F.season_now(now=date(2026, 11, 15)) == "rabi"


def test_crop_calendar_shape_and_current_flag():
    cal = F.crop_calendar(now=date(2026, 11, 15))
    assert cal["season"] == "rabi"
    assert "boro_rice" in cal["crops"]
    assert len(cal["all_seasons"]) == 3
    current = [s for s in cal["all_seasons"] if s["current"]]
    assert len(current) == 1 and current[0]["season"] == "rabi"


def test_crops_for_season_unknown_is_empty():
    assert F.crops_for_season("winter") == []


def test_every_crop_key_is_stable_token():
    # tokens only — no prose / no spaces (Dart localises labels)
    for k in F.CROP_KEYS:
        assert k == k.lower() and " " not in k


# --------------------------------------------------------------- vaccination

def test_vacc_due_when_interval_passed():
    v = F.vaccination_status("2025-01-01", now=date(2026, 1, 1))
    assert v["status"] == F.VACC_DUE
    assert v["days_until"] <= 0


def test_vacc_soon_within_window():
    # last + 180 = due; now 10 days before due → soon
    last = date(2026, 1, 1)
    due = date(2026, 6, 30)  # 180 days later
    now = due.fromordinal(due.toordinal() - 10)
    v = F.vaccination_status(last.isoformat(), now=now)
    assert v["status"] == F.VACC_SOON
    assert 0 < v["days_until"] <= F.SOON_DAYS


def test_vacc_ok_far_out():
    v = F.vaccination_status("2026-06-01", now=date(2026, 6, 15))
    assert v["status"] == F.VACC_OK
    assert v["days_until"] > F.SOON_DAYS


def test_vacc_unknown_without_date():
    v = F.vaccination_status(None, now=date(2026, 1, 1))
    assert v["status"] == F.VACC_UNKNOWN
    assert v["due_date"] is None


def test_vacc_due_date_is_last_plus_interval():
    v = F.vaccination_status("2026-01-01", now=date(2026, 1, 2))
    assert v["due_date"] == "2026-06-30"  # 2026-01-01 + 180 days


# --------------------------------------------------------------- livestock

def test_livestock_summary_counts_and_due():
    rows = [
        {"animal": "cow", "count": 3, "last_vaccinated": "2025-01-01"},   # due
        {"animal": "goat", "count": 5, "last_vaccinated": "2026-06-01"},  # ok
        {"animal": "chicken", "count": 20},                                # unknown
    ]
    s = F.livestock_summary(rows, now=date(2026, 6, 15))
    assert s["animals"] == 3
    assert s["total_head"] == 28
    assert s["by_type"]["cow"] == 3
    assert s["vacc_due"] == 1
    assert s["vacc_unknown"] == 1


def test_livestock_negative_count_clamped():
    s = F.livestock_summary([{"animal": "cow", "count": -4}], now=date(2026, 1, 1))
    assert s["total_head"] == 0


# --------------------------------------------------------------- validation

def test_validate_record():
    assert F.validate_record({"name": "Boro", "cost": 100}) == []
    assert "name_required" in F.validate_record({"cost": 100})
    assert "cost_negative" in F.validate_record({"name": "x", "cost": -1})
    assert "income_negative" in F.validate_record({"name": "x", "income": -1})
    assert "harvest_before_planting" in F.validate_record(
        {"name": "x", "planted": "2026-03-01", "harvest": "2026-01-01"})


def test_validate_livestock():
    assert F.validate_livestock({"animal": "cow", "count": 2}) == []
    assert "animal_required" in F.validate_livestock({"count": 2})
    assert "count_negative" in F.validate_livestock({"animal": "cow", "count": -1})


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    return len(fns)


if __name__ == "__main__":
    n = run_all()
    print(f"farmer_mode: {n} snippet tests passed")
