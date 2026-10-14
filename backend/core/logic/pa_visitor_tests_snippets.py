"""
pa_visitor_tests_snippets.py — plain-assert tests for the PA visitor /
appointment filter engine (#105, §14, advanced §21). Pure stdlib.
`python pa_visitor_tests_snippets.py` or import and call run_all(). The engine
is deterministic, so every assertion is hand-verified against fixed inputs.
"""

try:  # Django harness
    from core.logic import pa_visitor as V
except ImportError:  # standalone
    import pa_visitor as V  # noqa: E402


NOW = "2026-10-14T10:00:00Z"
PAST = "2026-10-10T09:00:00Z"
FUTURE = "2026-10-20T15:00:00Z"


def _req(**kw):
    base = {"id": 1, "name": "Mr Rahman", "reason": "Discuss contract",
            "priority": V.PRIORITY_NORMAL, "status": V.STATUS_PENDING,
            "requested_at": FUTURE}
    base.update(kw)
    return base


# --------------------------------------------------------------- validation

def test_validate_ok():
    assert V.validate(_req()) == []


def test_validate_catches_each():
    assert "name_required" in V.validate(_req(name="  "))
    assert "reason_required" in V.validate(_req(reason=""))
    assert "bad_priority" in V.validate(_req(priority="urgent"))
    assert "bad_status" in V.validate(_req(status="expired"))  # not storable


def test_validate_event_and_confirm():
    assert V.validate_event("approve") == V.STATUS_APPROVED
    assert V.validate_event("decline") == V.STATUS_DECLINED
    assert V.validate_event("suggest") == V.STATUS_SUGGESTED
    assert V.validate_event("nope") is None
    assert V.needs_confirm("approve") and V.needs_confirm("decline")
    assert not V.needs_confirm("suggest")


# --------------------------------------------------------------- status

def test_future_pending_stays_pending():
    assert V.compute_status(_req(requested_at=FUTURE), NOW) == V.STATUS_PENDING


def test_past_pending_becomes_expired():
    assert V.compute_status(_req(requested_at=PAST), NOW) == V.STATUS_EXPIRED


def test_settled_rows_never_expire():
    assert V.compute_status(_req(status=V.STATUS_APPROVED, requested_at=PAST),
                            NOW) == V.STATUS_APPROVED
    assert V.compute_status(_req(status=V.STATUS_SUGGESTED, requested_at=PAST),
                            NOW) == V.STATUS_SUGGESTED


def test_no_time_pending_stays_pending():
    assert V.compute_status(_req(requested_at=None), NOW) == V.STATUS_PENDING


# --------------------------------------------------------------- triage

def test_triage_approve_decline():
    a = V.triage(_req(), "approve", NOW)
    assert a["status"] == V.STATUS_APPROVED and "problem" not in a
    d = V.triage(_req(), "decline", NOW)
    assert d["status"] == V.STATUS_DECLINED


def test_triage_does_not_mutate_input():
    src = _req()
    V.triage(src, "approve", NOW)
    assert src["status"] == V.STATUS_PENDING


def test_triage_suggest_needs_time():
    bad = V.triage(_req(), "suggest", NOW)
    assert bad["problem"] == "suggest_needs_time"
    assert bad["status"] == V.STATUS_PENDING
    good = V.triage(_req(), "suggest", NOW, suggested_at=FUTURE)
    assert good["status"] == V.STATUS_SUGGESTED
    assert good["requested_at"] == FUTURE
    assert good["suggested_at"] == FUTURE


def test_triage_bad_event():
    out = V.triage(_req(), "teleport", NOW)
    assert out["problem"] == "bad_event"


def test_triage_refuses_already_settled():
    out = V.triage(_req(status=V.STATUS_APPROVED), "decline", NOW)
    assert out["problem"] == "already_settled"
    assert out["status"] == V.STATUS_APPROVED  # unchanged


def test_expired_can_still_be_triaged():
    out = V.triage(_req(requested_at=PAST), "decline", NOW)
    assert out["status"] == V.STATUS_DECLINED  # expired is still actionable


# --------------------------------------------------------------- priority

def test_set_priority():
    assert V.set_priority(_req(), V.PRIORITY_VIP)["priority"] == V.PRIORITY_VIP
    assert V.set_priority(_req(priority=V.PRIORITY_VIP),
                          "bogus")["priority"] == V.PRIORITY_VIP  # ignored


# --------------------------------------------------------------- ordering

def test_vip_sorts_before_normal():
    rows = [_req(id=1, priority=V.PRIORITY_NORMAL),
            _req(id=2, priority=V.PRIORITY_VIP)]
    out = V.order_queue(rows, NOW)
    assert out[0]["id"] == 2


def test_pending_before_settled_within_priority():
    rows = [_req(id=1, status=V.STATUS_APPROVED),
            _req(id=2, status=V.STATUS_PENDING)]
    out = V.order_queue(rows, NOW)
    assert out[0]["id"] == 2


def test_sooner_requested_first():
    rows = [_req(id=1, requested_at="2026-10-25T10:00:00Z"),
            _req(id=2, requested_at="2026-10-21T10:00:00Z")]
    out = V.order_queue(rows, NOW)
    assert out[0]["id"] == 2


def test_order_is_deterministic():
    rows = [_req(id=1), _req(id=2, priority=V.PRIORITY_VIP), _req(id=3)]
    assert V.order_queue(rows, NOW) == V.order_queue(rows, NOW)


# --------------------------------------------------------------- filter

def test_filter_by_status():
    rows = [_req(id=1, status=V.STATUS_PENDING),
            _req(id=2, status=V.STATUS_APPROVED)]
    out = V.filter_queue(rows, NOW, status=V.STATUS_APPROVED)
    assert [r["id"] for r in out] == [2]


def test_filter_by_computed_expired():
    rows = [_req(id=1, requested_at=PAST),       # expired
            _req(id=2, requested_at=FUTURE)]     # pending
    out = V.filter_queue(rows, NOW, status=V.STATUS_EXPIRED)
    assert [r["id"] for r in out] == [1]


def test_filter_by_priority():
    rows = [_req(id=1, priority=V.PRIORITY_VIP),
            _req(id=2, priority=V.PRIORITY_NORMAL)]
    out = V.filter_queue(rows, NOW, priority=V.PRIORITY_VIP)
    assert [r["id"] for r in out] == [1]


def test_filter_unknown_value_matches_nothing():
    rows = [_req(id=1)]
    assert V.filter_queue(rows, NOW, status="ghost") == []


def test_filter_multi_value():
    rows = [_req(id=1, status=V.STATUS_PENDING),
            _req(id=2, status=V.STATUS_APPROVED),
            _req(id=3, status=V.STATUS_DECLINED)]
    out = V.filter_queue(rows, NOW,
                         status=[V.STATUS_APPROVED, V.STATUS_DECLINED])
    assert sorted(r["id"] for r in out) == [2, 3]


# --------------------------------------------------------------- counts

def test_counts():
    rows = [
        _req(id=1, status=V.STATUS_PENDING, requested_at=FUTURE,
             priority=V.PRIORITY_VIP),
        _req(id=2, status=V.STATUS_PENDING, requested_at=PAST),   # expired
        _req(id=3, status=V.STATUS_APPROVED),
        _req(id=4, status=V.STATUS_SUGGESTED),
    ]
    c = V.counts(rows, NOW)
    assert c["total"] == 4
    assert c["by_status"][V.STATUS_PENDING] == 1
    assert c["by_status"][V.STATUS_EXPIRED] == 1
    assert c["by_status"][V.STATUS_APPROVED] == 1
    assert c["by_status"][V.STATUS_SUGGESTED] == 1
    assert c["vip"] == 1
    assert c["needs_attention"] == 3  # pending + expired + suggested


# --------------------------------------------------------------- privacy

def test_public_view_minimises_contact():
    pv = V.public_view(_req(phone="01712223210"), NOW)
    assert pv["has_contact"] is True
    assert pv["contact_hint"].endswith("3210")
    assert "01712223210" not in str(pv.values())  # raw never leaks
    assert "phone" not in pv and "contact" not in pv


def test_public_view_no_contact():
    pv = V.public_view(_req(), NOW)
    assert pv["has_contact"] is False
    assert pv["contact_hint"] == ""


def test_public_view_status_is_effective():
    pv = V.public_view(_req(requested_at=PAST), NOW)
    assert pv["status"] == V.STATUS_EXPIRED
    assert pv["is_vip"] is False


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_visitor: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
