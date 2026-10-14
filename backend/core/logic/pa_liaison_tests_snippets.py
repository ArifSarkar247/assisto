"""
pa_liaison_tests_snippets.py — plain-assert tests for the PA liaison &
follow-up engine (#108, §14, advanced §21). Pure stdlib.
`python pa_liaison_tests_snippets.py` or import and call run_all(). The engine
is deterministic, so every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import pa_liaison as L
except ImportError:  # standalone
    import pa_liaison as L  # noqa: E402


NOW = "2026-10-14T10:00:00Z"
PAST = "2026-10-10T10:00:00Z"        # 4 days before NOW
TOMORROW = "2026-10-15T10:00:00Z"    # 1 day after NOW
FAR = "2026-10-30T10:00:00Z"         # 16 days after NOW


def _item(**kw):
    base = {"id": 1, "title": "Chase vendor quote", "counterpart": "ABC Ltd",
            "status": L.STATUS_WAITING, "due_at": TOMORROW, "nudge": "off"}
    base.update(kw)
    return base


# --------------------------------------------------------------- validation

def test_validate_ok():
    assert L.validate(_item()) == []


def test_validate_catches_each():
    assert "title_required" in L.validate(_item(title=" "))
    assert "counterpart_required" in L.validate(_item(counterpart=""))
    assert "bad_status" in L.validate(_item(status="pending"))
    assert "bad_nudge" in L.validate(_item(nudge="hourly"))


def test_transitions():
    assert L.can_transition(L.STATUS_WAITING, L.STATUS_DONE)
    assert L.can_transition(L.STATUS_DONE, L.STATUS_WAITING)  # re-open allowed
    assert not L.can_transition(L.STATUS_WAITING, "pending")


def test_set_status_done_stamps_completed():
    out = L.set_status(_item(), L.STATUS_DONE, NOW)
    assert out["status"] == L.STATUS_DONE
    assert out["completed_at"] == NOW


def test_set_status_reopen_clears_completed():
    done = L.set_status(_item(), L.STATUS_DONE, NOW)
    re = L.set_status(done, L.STATUS_WAITING, NOW)
    assert re["status"] == L.STATUS_WAITING
    assert "completed_at" not in re


def test_set_status_bad_transition():
    out = L.set_status(_item(), "ghost", NOW)
    assert out["problem"] == "bad_transition"
    assert out["status"] == L.STATUS_WAITING


def test_set_status_does_not_mutate():
    src = _item()
    L.set_status(src, L.STATUS_DONE, NOW)
    assert src["status"] == L.STATUS_WAITING


# --------------------------------------------------------------- overdue

def test_overdue_true_when_open_and_past():
    assert L.is_overdue(_item(due_at=PAST), NOW) is True


def test_done_never_overdue():
    assert L.is_overdue(_item(status=L.STATUS_DONE, due_at=PAST), NOW) is False


def test_no_due_never_overdue():
    assert L.is_overdue(_item(due_at=None), NOW) is False


def test_future_not_overdue():
    assert L.is_overdue(_item(due_at=FAR), NOW) is False


def test_replied_can_be_overdue():
    assert L.is_overdue(_item(status=L.STATUS_REPLIED, due_at=PAST), NOW) is True


# --------------------------------------------------------------- days / urgency

def test_days_until_due():
    assert L.days_until_due(_item(due_at=TOMORROW), NOW) == 1
    assert L.days_until_due(_item(due_at=PAST), NOW) == -4
    assert L.days_until_due(_item(due_at=None), NOW) is None


def test_urgency_buckets():
    assert L.urgency(_item(due_at=PAST), NOW) == "overdue"
    assert L.urgency(_item(due_at=TOMORROW), NOW) == "due_soon"
    assert L.urgency(_item(due_at=FAR), NOW) == "later"
    assert L.urgency(_item(due_at=None), NOW) == "later"
    assert L.urgency(_item(status=L.STATUS_DONE), NOW) == "done"


# --------------------------------------------------------------- ordering

def test_order_overdue_first():
    rows = [_item(id=1, due_at=FAR), _item(id=2, due_at=PAST),
            _item(id=3, status=L.STATUS_DONE)]
    out = L.order_list(rows, NOW)
    assert [r["id"] for r in out] == [2, 1, 3]


def test_order_replied_before_waiting_in_later():
    rows = [_item(id=1, status=L.STATUS_WAITING, due_at=FAR),
            _item(id=2, status=L.STATUS_REPLIED, due_at=FAR)]
    out = L.order_list(rows, NOW)
    assert out[0]["id"] == 2


def test_order_deterministic():
    rows = [_item(id=1, due_at=PAST), _item(id=2, due_at=TOMORROW)]
    assert L.order_list(rows, NOW) == L.order_list(rows, NOW)


# --------------------------------------------------------------- filter

def test_filter_by_status():
    rows = [_item(id=1, status=L.STATUS_WAITING),
            _item(id=2, status=L.STATUS_DONE)]
    out = L.filter_list(rows, NOW, status=L.STATUS_DONE)
    assert [r["id"] for r in out] == [2]


def test_filter_only_overdue():
    rows = [_item(id=1, due_at=PAST), _item(id=2, due_at=FAR)]
    out = L.filter_list(rows, NOW, only_overdue=True)
    assert [r["id"] for r in out] == [1]


def test_filter_unknown_status_empty():
    assert L.filter_list([_item()], NOW, status="ghost") == []


# --------------------------------------------------------------- nudge

def test_nudge_off_no_schedule():
    assert L.next_nudge_at(_item(nudge="off"), NOW) is None
    assert L.nudge_due(_item(nudge="off"), NOW) is False


def test_nudge_closed_item_silent():
    it = _item(status=L.STATUS_DONE, nudge="daily")
    assert L.next_nudge_at(it, NOW) is None
    assert L.nudge_due(it, NOW) is False


def test_nudge_due_when_anchor_reached():
    # anchored on due_at=PAST (4 days ago), daily cadence → long past due
    it = _item(nudge="daily", due_at=PAST)
    assert L.nudge_due(it, NOW) is True


def test_nudge_not_due_yet():
    # last nudged just now, weekly cadence → next is ~7 days out
    it = _item(nudge="weekly", last_nudged_at=NOW, due_at=FAR)
    assert L.nudge_due(it, NOW) is False
    nxt = L.next_nudge_at(it, NOW)
    assert nxt is not None and nxt > L._to_epoch(NOW)


def test_next_nudge_no_backlog_spam():
    # dormant 4 days, daily cadence: next fire is strictly in the FUTURE, not
    # a pile of missed past slots.
    it = _item(nudge="daily", due_at=PAST)
    nxt = L.next_nudge_at(it, NOW)
    assert nxt is not None and nxt > L._to_epoch(NOW)


# --------------------------------------------------------------- counts

def test_counts():
    rows = [
        _item(id=1, status=L.STATUS_WAITING, due_at=PAST),     # overdue
        _item(id=2, status=L.STATUS_REPLIED, due_at=TOMORROW),  # due_soon
        _item(id=3, status=L.STATUS_WAITING, due_at=FAR),      # later
        _item(id=4, status=L.STATUS_DONE),
    ]
    c = L.counts(rows, NOW)
    assert c["total"] == 4
    assert c["overdue"] == 1
    assert c["due_soon"] == 1
    assert c["open"] == 3
    assert c["by_status"][L.STATUS_DONE] == 1


# --------------------------------------------------------------- privacy

def test_public_view_minimises_contact():
    pv = L.public_view(_item(phone="01998887766"), NOW)
    assert pv["has_contact"] is True
    assert pv["contact_hint"].endswith("7766")
    assert "01998887766" not in str(pv.values())
    assert "phone" not in pv and "contact" not in pv


def test_public_view_fields():
    pv = L.public_view(_item(due_at=PAST), NOW)
    assert pv["urgency"] == "overdue"
    assert pv["overdue"] is True
    assert pv["days_until_due"] == -4


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_liaison: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
