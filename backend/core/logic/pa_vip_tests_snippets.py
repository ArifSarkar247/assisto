"""
pa_vip_tests_snippets.py — plain-assert tests for the PA VIP & stakeholder
tracker (#118, §14, CORPORATE). Pure stdlib. `now` passed in (no clock), so
every assertion is hand-verified against fixed dates. No DB, no AI, no network.
"""

try:  # Django harness
    from core.logic import pa_vip as A
except ImportError:  # standalone
    import pa_vip as A  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_requires_name():
    assert "empty_name" in A.validate(name="")
    assert A.validate(name="Mr Rahman") == []


def test_validate_bad_tier():
    assert "bad_tier" in A.validate(name="X", tier="platinum")
    assert A.validate(name="X", tier="strategic") == []


# --------------------------------------------------------------- date helpers

def test_iso_rejects_garbage_and_impossible_dates():
    assert A._iso("2026-10-14") == "2026-10-14"
    assert A._iso("not a date") == ""
    assert A._iso("2026-13-40") == ""  # impossible month/day rejected


def test_add_days_pure():
    assert A._add_days("2026-10-14", 7) == "2026-10-21"
    assert A._add_days("2026-10-14", -1) == "2026-10-13"
    assert A._add_days("bad", 7) == ""


# --------------------------------------------------------------- next-touch

def test_effective_next_touch_prefers_explicit():
    assert A.effective_next_touch(last_touch="2026-01-01",
                                  next_touch="2026-06-06",
                                  cadence_days=10) == "2026-06-06"


def test_effective_next_touch_derives_from_cadence():
    assert A.effective_next_touch(last_touch="2026-10-01",
                                  next_touch="",
                                  cadence_days=30) == "2026-10-31"


def test_effective_next_touch_falls_back_to_default_cadence():
    # last-touch only, no cadence → last + DEFAULT_CADENCE_DAYS
    exp = A._add_days("2026-10-01", A.DEFAULT_CADENCE_DAYS)
    assert A.effective_next_touch(last_touch="2026-10-01") == exp


def test_effective_next_touch_unknown_when_nothing():
    assert A.effective_next_touch() == ""


# --------------------------------------------------------------- status

def test_status_overdue_due_soon_on_track():
    now = "2026-10-14"
    # due yesterday → overdue
    assert A.status_for(now, next_touch="2026-10-13")["status"] == A.STATUS_OVERDUE
    # due in 3 days (<=7) → due soon
    ds = A.status_for(now, next_touch="2026-10-17")
    assert ds["status"] == A.STATUS_DUE_SOON
    assert ds["days"] == 3
    # due in 30 days → on track
    assert A.status_for(now, next_touch="2026-11-13")["status"] == A.STATUS_ON_TRACK


def test_status_no_date_when_nothing_known():
    r = A.status_for("2026-10-14")
    assert r["status"] == A.STATUS_NO_DATE
    assert r["days"] is None


def test_status_days_negative_when_overdue():
    r = A.status_for("2026-10-14", next_touch="2026-10-04")
    assert r["days"] == -10


# --------------------------------------------------------------- summarise

def test_summarise_counts_by_status():
    now = "2026-10-14"
    contacts = [
        {"name": "A", "next_touch": "2026-10-01"},   # overdue
        {"name": "B", "next_touch": "2026-10-16"},   # due soon
        {"name": "C", "next_touch": "2026-12-01"},   # on track
        {"name": "D"},                               # no date
    ]
    c = A.summarise(contacts, now)["counts"]
    assert c["overdue"] == 1
    assert c["due_soon"] == 1
    assert c["on_track"] == 1
    assert c["no_date"] == 1
    assert c["total"] == 4


def test_summarise_sorts_overdue_first_then_tier():
    now = "2026-10-14"
    contacts = [
        {"name": "OnTrackStd", "tier": "standard", "next_touch": "2026-12-01"},
        {"name": "OverdueKey", "tier": "key", "next_touch": "2026-10-01"},
        {"name": "OverdueStrategic", "tier": "strategic",
         "next_touch": "2026-10-05"},
    ]
    items = A.summarise(contacts, now)["items"]
    # overdue bucket first; within it, strategic tier before key tier
    assert items[0]["name"] == "OverdueStrategic"
    assert items[1]["name"] == "OverdueKey"
    assert items[2]["name"] == "OnTrackStd"


def test_summarise_privacy_never_leaks_notes_or_log():
    now = "2026-10-14"
    items = A.summarise([{"name": "VIP", "org": "Acme", "tier": "key",
                          "next_touch": "2026-10-20",
                          "notes": "SECRET private note",
                          "log": [{"date": "2026-01-01",
                                   "note": "SECRET interaction"}]}], now)["items"]
    row = items[0]
    assert set(row.keys()) == {"name", "org", "tier", "status",
                               "due_date", "days"}
    # the secrets never appear in the roll-up payload
    assert "SECRET" not in repr(row)


def test_summarise_drops_unnamed_contacts():
    items = A.summarise([{"name": ""}, {"org": "x"}], "2026-10-14")["items"]
    assert items == []


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"pa_vip: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
