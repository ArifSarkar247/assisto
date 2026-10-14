"""
pa_callemail_tests_snippets.py — plain-assert tests for the PA Call & Email
handling engine (#106, §14). Pure stdlib. `python pa_callemail_tests_snippets.py`
or import and call run_all(). The engine is deterministic, so every assertion is
hand-verified against fixed inputs. No DB, no AI, no network.
"""

try:  # Django harness
    from core.logic import pa_callemail as A
except ImportError:  # standalone
    import pa_callemail as A  # noqa: E402


# --------------------------------------------------------------- validation

def test_validate_ok():
    assert A.validate("call", contact="Vendor", subject="Quote") == []
    assert A.validate("email", subject="Invoice") == []
    assert A.validate("call", contact="Someone") == []


def test_validate_catches_bad_channel_and_empty():
    assert "bad_channel" in A.validate("fax", contact="x", subject="y")
    assert "empty_task" in A.validate("call", contact="", subject="")


# --------------------------------------------------------------- normalise

def test_normalise_defaults_unknown_enums_safely():
    n = A.normalise({"channel": "pigeon", "priority": "urgent",
                     "status": "maybe", "contact": "  A  B  ", "subject": "S"})
    assert n["channel"] == A.CHANNEL_CALL
    assert n["priority"] == A.PRIORITY_NORMAL
    assert n["status"] == A.STATUS_TODO
    assert n["contact"] == "A B"  # whitespace collapsed


# --------------------------------------------------------------- ordering

def test_order_open_before_done_then_priority():
    items = [
        {"subject": "z", "priority": "low", "status": "todo"},
        {"subject": "a", "priority": "high", "status": "done"},
        {"subject": "m", "priority": "high", "status": "todo"},
    ]
    out = A.order(items)
    # open high first, then open low, then the done one last
    assert out[0]["subject"] == "m"
    assert out[1]["subject"] == "z"
    assert out[2]["subject"] == "a"


def test_order_is_deterministic_and_pure():
    items = [{"subject": "b", "priority": "normal", "status": "todo"},
             {"subject": "a", "priority": "normal", "status": "todo"}]
    snapshot = list(items)
    assert A.order(items) == A.order(items)
    assert items == snapshot  # not mutated


# --------------------------------------------------------------- counts

def test_counts_split_calls_emails_done():
    items = [
        {"channel": "call", "status": "todo", "subject": "a"},
        {"channel": "call", "status": "todo", "subject": "b"},
        {"channel": "email", "status": "todo", "subject": "c"},
        {"channel": "email", "status": "done", "subject": "d"},
    ]
    c = A.counts(items)
    assert c == {"open_calls": 2, "open_emails": 1, "open_total": 3,
                 "done": 1, "total": 4}


# --------------------------------------------------------------- draft reply

def test_draft_reply_fills_template_deterministically():
    item = {"channel": "email", "contact": "Mr Rahman", "subject": "the invoice"}
    r = A.draft_reply(item, category=A.CAT_ACK, sender="PA")
    assert r["ai_required"] is False
    assert r["mock"] is True
    assert r["marker"] == A.MARKER_KEY
    assert "Mr Rahman" in r["body"]
    assert "the invoice" in r["body"]
    assert "PA" in r["body"]
    # deterministic
    assert A.draft_reply(item, A.CAT_ACK, "PA") == A.draft_reply(item, A.CAT_ACK, "PA")


def test_draft_reply_each_category_differs():
    item = {"contact": "X", "subject": "Y"}
    bodies = {c: A.draft_reply(item, c)["body"] for c in A.CATEGORIES}
    assert len(set(bodies.values())) == len(A.CATEGORIES)


def test_draft_reply_unknown_category_falls_back_to_ack():
    item = {"contact": "X", "subject": "Y"}
    assert A.draft_reply(item, "rude")["category"] == A.CAT_ACK


def test_draft_reply_never_fabricates_when_ai_requested():
    item = {"contact": "X", "subject": "Y"}
    r = A.draft_reply(item, A.CAT_SCHEDULE, want_ai=True)
    assert r["ai_required"] is True
    assert r["body"] == ""   # honest: no invented AI reply
    assert r["marker"] == A.MARKER_KEY


def test_draft_reply_handles_missing_fields_without_crash():
    r = A.draft_reply({}, A.CAT_ACK)
    assert "—" in r["body"]  # placeholders, never an exception


# --------------------------------------------------------------- never-send

def test_nothing_here_sends_only_returns_state_or_text():
    # the public surface is validate / normalise / order / counts / draft_reply
    # — all return data; there is no send/dial/mail function.
    for name in ("send", "dial", "call_now", "mail", "transmit"):
        assert not hasattr(A, name)


# --------------------------------------------------------------- runner

def run_all():
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
    print(f"pa_callemail: {len(fns)} checks passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
