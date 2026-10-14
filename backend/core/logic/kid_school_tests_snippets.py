"""
kid_school_tests_snippets.py — plain-assert tests for the KID'S SCHOOL CORNER
engine (#27, §21). Pure stdlib. Deterministic keyword routing + honest
upcoming/overdue from a passed-in `now`; every assertion hand-verified against
fixed inputs. `python kid_school_tests_snippets.py` or import and call run_all().
"""

try:  # Django harness
    from core.logic import kid_school as K
except ImportError:  # standalone
    import kid_school as K  # noqa: E402


# --------------------------------------------------------- keyword routing
def test_suggest_fee():
    r = K.suggest_type("Monthly tuition fee", "Please pay by 10th")
    assert r["type"] == "fee" and r["confident"] is True
    assert r["matched"] is not None


def test_suggest_exam():
    r = K.suggest_type("Half-yearly examination routine")
    assert r["type"] == "exam" and r["confident"]


def test_suggest_ptm():
    r = K.suggest_type("Parent-teacher meeting on Friday")
    assert r["type"] == "ptm"


def test_suggest_event():
    r = K.suggest_type("Annual sports day celebration")
    assert r["type"] == "event"


def test_suggest_bangla():
    r = K.suggest_type("আগামী সপ্তাহে পরীক্ষা শুরু")
    assert r["type"] == "exam" and r["confident"]


def test_suggest_unknown_is_other_not_confident():
    r = K.suggest_type("Dear all, note the new school uniform shade")
    assert r["type"] == "other" and r["confident"] is False
    assert r["matched"] is None


def test_suggest_priority_fee_over_event():
    # text matches both 'fee' and 'event' cues → fee wins by declared priority
    r = K.suggest_type("Annual function fee notice")
    assert r["type"] == "fee"


def test_type_rows_shapes():
    rows = K.type_rows("en")
    fee = next(r for r in rows if r["value"] == "fee")
    assert fee["has_amount"] and fee["has_date"]
    other = next(r for r in rows if r["value"] == "other")
    assert not other["has_date"] and not other["has_amount"]


# --------------------------------------------------------- notice status
def test_notice_overdue():
    n = {"id": 1, "type": "fee", "amount": "500", "date": "2026-01-01"}
    s = K.notice_status(n, "2026-01-10")
    assert s["state"] == "overdue" and s["days"] == -9
    assert s["amount"] == "500"


def test_notice_due_today():
    s = K.notice_status({"type": "exam", "date": "2026-02-01"}, "2026-02-01")
    assert s["state"] == "due_today" and s["days"] == 0


def test_notice_upcoming():
    s = K.notice_status({"type": "ptm", "date": "2026-03-01"}, "2026-02-01")
    assert s["state"] == "upcoming" and s["days"] == 28


def test_done_never_overdue():
    n = {"type": "fee", "date": "2026-01-01", "done": True}
    s = K.notice_status(n, "2026-06-01")
    assert s["state"] == "done" and s["days"] is None


def test_other_type_is_dateless():
    s = K.notice_status({"type": "other", "date": "2026-01-01"}, "2026-06-01")
    assert s["state"] == "no_date"   # 'other' carries no date by type


def test_no_date_is_never_overdue():
    s = K.notice_status({"type": "exam"}, "2026-06-01")
    assert s["state"] == "no_date" and s["days"] is None


def test_amount_only_for_fee():
    s = K.notice_status({"type": "exam", "amount": "500", "date": "2026-01-01"},
                        "2026-01-01")
    assert s["amount"] is None       # amount ignored for non-fee


# --------------------------------------------------------- child board
def _notices():
    return [
        {"id": 1, "type": "fee", "amount": "500", "date": "2026-01-01"},
        {"id": 2, "type": "exam", "date": "2026-02-10"},
        {"id": 3, "type": "ptm", "date": "2026-02-05"},
        {"id": 4, "type": "fee", "amount": "300", "date": "2026-03-01",
         "done": True},
        {"id": 5, "type": "other", "title": "note"},
    ]


def test_child_board_partition_and_counts():
    b = K.child_board(_notices(), "2026-02-01")
    assert b["counts"]["overdue"] == 1     # the ৳500 fee
    assert b["counts"]["done"] == 1
    assert b["counts"]["no_date"] == 1     # the 'other'
    assert b["counts"]["upcoming"] == 2    # exam + ptm
    # open fees list excludes the paid one
    assert len(b["fees"]) == 1
    assert b["counts"]["fee"] == 2         # total fees (incl. paid)


def test_child_board_sorted_overdue_first():
    b = K.child_board(_notices(), "2026-02-01")
    assert b["all"][0]["state"] == "overdue"


# --------------------------------------------------------- due_soon seam
def test_due_soon_forward_only_within_window():
    b = K.due_soon(_notices(), "2026-02-01", within_days=7)
    ids = [s["id"] for s in b]
    assert ids == [3]                      # ptm on 02-05 is within 7 days
    # overdue fee (id 1) is excluded; exam 02-10 is outside 7-day window


def test_due_soon_excludes_overdue_and_done():
    b = K.due_soon(_notices(), "2026-02-01", within_days=60)
    assert all(s["state"] in ("upcoming", "due_today") for s in b)
    assert 4 not in [s["id"] for s in b]   # the done fee never appears


# --------------------------------------------------------- roster summary
def test_roster_summary_rollup_and_next():
    children = [{"id": 10, "name": "Rumi", "klass": "Class 3"}]
    notices = [
        {"id": 1, "child": 10, "type": "fee", "amount": "500",
         "date": "2026-01-01"},
        {"id": 2, "child": 10, "type": "exam", "date": "2026-02-10"},
    ]
    r = K.roster_summary(children, notices, "2026-02-01")
    row = r["children"][0]
    assert row["overdue"] == 1
    assert row["open"] == 2
    # overdue is the most urgent "next"
    assert row["next"]["id"] == 1
    assert r["totals"]["children"] == 1 and r["totals"]["overdue"] == 1


def test_roster_next_is_earliest_upcoming_when_no_overdue():
    children = [{"id": 10, "name": "Rumi", "klass": ""}]
    notices = [
        {"id": 2, "child": 10, "type": "exam", "date": "2026-03-10"},
        {"id": 3, "child": 10, "type": "ptm", "date": "2026-02-20"},
    ]
    r = K.roster_summary(children, notices, "2026-02-01")
    assert r["children"][0]["next"]["id"] == 3   # earlier date


def test_roster_empty():
    r = K.roster_summary([], [], "2026-02-01")
    assert r["empty"] is True and r["totals"]["children"] == 0


# --------------------------------------------------------- determinism
def test_board_deterministic():
    a = K.child_board(_notices(), "2026-02-01")
    b = K.child_board(_notices(), "2026-02-01")
    assert a == b


def test_status_copy_bilingual_via_labels():
    assert K.type_label("fee", "bn") != K.type_label("fee", "en")


# --------------------------------------------------------- validation
def test_validate_child():
    assert "name_required" in K.validate_child("", "Class 1")
    assert K.validate_child("Rumi", "") == []    # class optional (privacy)


def test_validate_notice():
    assert "title_required" in K.validate_notice("", "fee")
    assert "bad_type" in K.validate_notice("X", "nope")
    assert "amount_negative" in K.validate_notice("Fee", "fee", amount="-5")
    assert "amount_invalid" in K.validate_notice("Fee", "fee", amount="abc")
    assert "date_invalid" in K.validate_notice("Exam", "exam", _date="31-01")
    assert K.validate_notice("Exam", "exam") == []   # dateless exam is allowed
    assert K.validate_notice("Fee", "fee", amount="500",
                             _date="2026-01-01") == []


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"kid_school: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
