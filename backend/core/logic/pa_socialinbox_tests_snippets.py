"""
pa_socialinbox_tests_snippets.py — plain-assert tests for the PA unified social
inbox / DM triage (#123, §14). Pure stdlib. Deterministic; the live-fetch seam
is honest and never fabricates a message.
"""
try:  # Django harness
    from core.logic import pa_socialinbox as S
except ImportError:  # standalone
    import pa_socialinbox as S  # noqa: E402


# --------------------------------------------------------------- normalize
def test_normalize_fallbacks_and_from_alias():
    m = S.normalize_item({"platform": "x", "priority": "p", "status": "s",
                          "from": "  @fan  ", "message": "  hi  "})
    assert m["platform"] == S.PLAT_OTHER
    assert m["priority"] == S.PR_NORMAL
    assert m["status"] == S.ST_NEW
    assert m["from_handle"] == "@fan"
    assert m["message"] == "hi"


# --------------------------------------------------------------- validate
def test_validate_needs_sender_or_message():
    assert S.validate_item({"from": "@a"}) == []
    assert S.validate_item({"message": "hello"}) == []
    assert "empty_item" in S.validate_item({"from": "", "message": ""})
    assert "bad_at" in S.validate_item({"from": "@a", "at": "nope"})


# --------------------------------------------------------------- ordering
def test_order_open_before_handled_then_priority():
    items = [
        {"id": 1, "from": "a", "status": "replied", "priority": "urgent"},
        {"id": 2, "from": "b", "status": "new", "priority": "low"},
        {"id": 3, "from": "c", "status": "new", "priority": "urgent"},
    ]
    out = S.order_inbox(items)
    # open (new) first, urgent before low; handled last
    assert [x["id"] for x in out] == [3, 2, 1]


def test_order_newest_first_within_bucket():
    items = [
        {"id": 1, "from": "a", "status": "new", "priority": "normal",
         "at": "2026-10-01T10:00"},
        {"id": 2, "from": "b", "status": "new", "priority": "normal",
         "at": "2026-10-05T10:00"},
    ]
    out = S.order_inbox(items)
    assert [x["id"] for x in out] == [2, 1]


def test_order_is_pure():
    items = [{"id": 1, "from": "a"}]
    S.order_inbox(items)
    assert items == [{"id": 1, "from": "a"}]


# --------------------------------------------------------------- triage
def test_triage_counts_open_urgent_platform():
    items = [
        {"id": 1, "platform": "instagram", "status": "new", "priority": "urgent"},
        {"id": 2, "platform": "instagram", "status": "new", "priority": "normal"},
        {"id": 3, "platform": "facebook", "status": "replied", "priority": "low"},
    ]
    t = S.triage(items)
    assert t["count"] == 3
    assert t["open_count"] == 2 and t["handled_count"] == 1
    assert t["by_platform_open"]["instagram"] == 2
    assert t["by_platform_open"]["facebook"] == 0
    assert t["urgent_count"] == 1 and t["urgent"][0]["id"] == 1


def test_triage_empty():
    t = S.triage([])
    assert t["count"] == 0 and t["open_count"] == 0 and t["urgent_count"] == 0


# --------------------------------------------------------------- seam
def test_fetch_seam_is_honest_and_empty():
    r = S.inbox_fetch_seam()
    assert r["required"] is True and r["mock"] is True
    assert r["messages"] == []          # never fabricates a DM / sender
    assert r["marker"] == S.INBOX_MARKER_KEY
    # names BOTH Meta keys that would unlock a real fetch
    assert "instagram" in r["keys"] and "messenger" in r["keys"]


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"pa_socialinbox: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
