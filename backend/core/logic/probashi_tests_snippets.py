"""
probashi_tests_snippets.py — plain-assert tests for the PROBASHI CORNER (#191,
§20): remittance log, time-zone pair, documents checklist. Pure stdlib,
deterministic (all time is passed in). `python probashi_tests_snippets.py` or
import and call run_all().
"""
from datetime import date, datetime, timezone

try:  # Django harness
    from core.logic import probashi as P
except ImportError:  # standalone
    import probashi as P  # noqa: E402


# --------------------------------------------------------------- money fmt

def test_to_minor_and_fmt():
    assert P.to_minor("100") == 10000
    assert P.to_minor("1,250.50") == 125050
    assert P.to_minor("abc") == 0
    assert P.fmt_minor(125050) == "1,250.50"
    assert P.fmt_bdt(10000) == "৳100.00"
    assert P.fmt_bdt(-5000) == "-৳50.00"


def test_parse_rate():
    assert P.parse_rate("128.50") == 128.50
    assert P.parse_rate("1,300") == 1300.0
    assert P.parse_rate("junk") == 0.0
    assert P.parse_rate("-5") == 0.0  # negatives clamped


# --------------------------------------------------------------- remittance

def test_bdt_received_exact_round_once():
    # send 100.00 units (10000 minor) at 128.50 BDT/unit -> ৳12,850.00
    assert P.bdt_received(10000, "128.50") == 1285000
    # 150.00 units at 128.33 -> 19249.5 BDT -> round half up to poisha
    assert P.bdt_received(15000, 128.33) == P.bdt_received(15000, 128.33)
    got = P.bdt_received(15000, 128.33)
    assert got == 1924950  # 15000 * 128.33 = 1924950 poisha exactly


def test_remittance_summary_totals_and_avg_rate():
    rows = [
        {"amount": "100", "rate": "128.50", "date": "2026-01-10"},
        {"amount": "200", "rate": "130.00", "date": "2026-02-10"},
    ]
    s = P.remittance_summary(rows, "en")
    assert s["count"] == 2
    assert s["total_sent_minor"] == 30000  # 300.00 units
    # 100*128.50 + 200*130.00 = 12850 + 26000 = 38850 BDT
    assert s["total_bdt"] == 3885000
    assert s["total_bdt_display"] == "৳38,850.00"
    # weighted avg = 38850/300 = 129.50
    assert s["avg_rate_display"] == "129.50"
    assert s["rows"][0]["bdt_display"] == "৳12,850.00"


def test_remittance_validate():
    assert P.validate_remittance(
        {"amount": "100", "rate": "128", "date": "2026-01-01"}) == []
    assert "amount_required" in P.validate_remittance({"rate": "1", "date": "x"})
    assert "rate_required" in P.validate_remittance(
        {"amount": "1", "date": "x"})
    assert "date_required" in P.validate_remittance(
        {"amount": "1", "rate": "1"})


# --------------------------------------------------------------- timezone

def test_parse_offset_forms():
    assert P.parse_offset("+6") == 360
    assert P.parse_offset("+6:00") == 360
    assert P.parse_offset("-3:30") == -210
    assert P.parse_offset(6) == 360          # small -> hours
    assert P.parse_offset("5.5") == 330
    assert P.parse_offset("UTC+4") == 240


def test_timezone_pair_deterministic_sides():
    # Fixed UTC instant: 2026-06-15 09:00 UTC
    now = datetime(2026, 6, 15, 9, 0, tzinfo=timezone.utc)
    # abroad = Dubai UTC+4 ; home = Dhaka UTC+6
    r = P.timezone_pair(now, "+4", abroad_label="Dubai", home_label="Dhaka")
    assert r["home"]["time"] == "15:00"      # 09:00 + 6h
    assert r["abroad"]["time"] == "13:00"    # 09:00 + 4h
    assert r["home"]["label"] == "Dhaka"
    assert r["ahead"] == "home"              # BD ahead of Dubai
    assert r["diff_min"] == 120
    assert "2h" in r["diff_display"]["en"]
    # determinism
    assert P.timezone_pair(now, "+4") == P.timezone_pair(now, "+4")


def test_timezone_pair_crosses_date():
    # 2026-06-15 20:00 UTC: Dhaka = +6 -> 02:00 next day
    now = "2026-06-15T20:00:00+00:00"
    r = P.timezone_pair(now, "-5")  # New York-ish, no DST concern (fixed offset)
    assert r["home"]["time"] == "02:00"
    assert r["home"]["date"] == "2026-06-16"   # rolled to next day
    assert r["abroad"]["time"] == "15:00"
    assert r["abroad"]["date"] == "2026-06-15"
    assert r["ahead"] == "home"
    assert r["diff_min"] == 11 * 60


def test_timezone_pair_same():
    now = datetime(2026, 6, 15, 9, 0, tzinfo=timezone.utc)
    r = P.timezone_pair(now, "+6")  # abroad also +6
    assert r["ahead"] == "same"
    assert r["diff_display"]["en"] == "Same time"


# --------------------------------------------------------------- documents

def test_doc_status_from_today():
    today = date(2026, 6, 1)
    assert P.doc_status("2026-05-01", today)["status"] == "expired"
    assert P.doc_status("2026-05-01", today)["days_left"] == -31
    assert P.doc_status("2026-07-01", today)["status"] == "expiring"  # 30 days
    assert P.doc_status("2027-07-01", today)["status"] == "valid"
    assert P.doc_status(None, today)["status"] == "no_date"
    assert P.doc_status(None, today)["days_left"] is None


def test_docs_overview_sort_and_counts():
    today = date(2026, 6, 1)
    rows = [
        {"kind": "passport", "expiry": "2030-01-01"},   # valid
        {"kind": "visa", "expiry": "2026-05-01"},        # expired
        {"kind": "ticket", "expiry": "2026-07-15"},      # expiring
        {"kind": "nid"},                                 # no_date
    ]
    o = P.docs_overview(rows, today, lang="en")
    # most urgent first: expired, then soonest, then undated last
    assert o["rows"][0]["kind"] == "visa"
    assert o["rows"][-1]["kind"] == "nid"
    assert o["counts"] == {"expired": 1, "expiring": 1, "valid": 1, "no_date": 1}
    assert o["next_expiry"]["kind"] == "visa"
    assert "en" in o["note"]


def test_docs_overview_warn_window_configurable():
    today = date(2026, 6, 1)
    rows = [{"kind": "passport", "expiry": "2026-08-01"}]  # 61 days away
    assert P.docs_overview(rows, today, warn_days=30)["rows"][0]["status"] == "valid"
    assert P.docs_overview(rows, today, warn_days=90)["rows"][0]["status"] == "expiring"


def run_all():
    g = globals()
    fns = [v for k, v in g.items() if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"probashi: {len(fns)} tests passed")


if __name__ == "__main__":
    run_all()
