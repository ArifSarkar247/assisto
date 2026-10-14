"""
ai_inbox_tests_snippets.py — plain-assert tests for core.logic.ai_inbox.

NOT a Django TestCase. Smoke locally:
    python3 -c "import core.logic.ai_inbox_tests_snippets as t; t.run_all()"

Covers categorise / needs-reply / priority / summary / quick-replies (mock) /
filter / needs-reply view / priority sort / snooze + bulk done / active view /
convert payloads — i.e. the whole advanced triage contract.
"""
from datetime import datetime, timedelta

from core.logic import ai_inbox as A


NOW = datetime(2026, 10, 14, 12, 0)


def _item(**kw):
    base = dict(id="1", source="email", sender="Bank",
                subject="Hello", snippet="just saying hi",
                ts=NOW, read=False)
    base.update(kw)
    return base


# ---- categorise -----------------------------------------------------------

def test_categorize_urgent():
    assert A.categorize(_item(subject="URGENT: payment failed")) == "urgent"


def test_categorize_action():
    assert A.categorize(_item(subject="Meeting", snippet="please reply")) == "action"


def test_categorize_promo():
    assert A.categorize(_item(subject="50% off SALE", snippet="buy now")) == "promo"


def test_categorize_fyi_default():
    assert A.categorize(_item(subject="Monthly update", snippet="info only")) == "fyi"


def test_promo_beats_action_but_not_urgent():
    # promo wording + a reply ask ⇒ promo
    assert A.categorize(_item(subject="SALE reply to claim")) == "promo"
    # promo wording + urgent ⇒ urgent (an urgent security note isn't a promo)
    assert A.categorize(_item(subject="offer suspended account")) == "urgent"


def test_bangla_keywords():
    assert A.categorize(_item(subject="জরুরি বকেয়া")) == "urgent"
    assert A.categorize(_item(subject="মিটিং রিমাইন্ডার")) == "action"


# ---- needs reply ----------------------------------------------------------

def test_needs_reply_question():
    assert A.needs_reply(_item(subject="Can you review this?")) is True


def test_needs_reply_urgent_always():
    assert A.needs_reply(_item(subject="URGENT account locked")) is True


def test_promo_never_needs_reply():
    assert A.needs_reply(_item(subject="Big SALE buy now")) is False


def test_fyi_no_reply():
    assert A.needs_reply(_item(subject="Newsletter", snippet="monthly digest")) is False


# ---- priority -------------------------------------------------------------

def test_priority_ordering_by_category():
    urgent = A.priority(_item(subject="URGENT payment failed"), now=NOW)
    fyi = A.priority(_item(subject="newsletter digest"), now=NOW)
    assert urgent > fyi


def test_priority_clamped_0_100():
    p = A.priority(_item(subject="URGENT asap action required?"), now=NOW)
    assert 0 <= p <= 100


def test_unread_and_recency_boost():
    fresh_unread = A.priority(_item(subject="note", ts=NOW, read=False), now=NOW)
    old_read = A.priority(
        _item(subject="note", ts=NOW - timedelta(days=5), read=True), now=NOW)
    assert fresh_unread > old_read


# ---- summary + quick replies ----------------------------------------------

def test_summary_sender_and_subject():
    s = A._summary(_item(sender="Rahim", subject="Lunch?"))
    assert "Rahim" in s and "Lunch?" in s


def test_summary_truncates():
    s = A._summary(_item(sender="X", subject="y" * 200))
    assert s.endswith("...") and len(s) <= 95 + len("X: ")


def test_quick_replies_mock_by_category():
    urgent = A.suggest_replies(_item(subject="URGENT payment failed"))
    promo = A.suggest_replies(_item(subject="SALE buy now"))
    assert len(urgent) == 3 and promo == []


def test_quick_replies_are_deterministic_labels_not_prose():
    # Even with a (mock) key flag the labels are the same canned keys — the
    # module never drafts real prose here.
    a = A.suggest_replies(_item(subject="please confirm"), ai_key_available=True)
    b = A.suggest_replies(_item(subject="please confirm"), ai_key_available=False)
    assert a == b and all(" " not in x for x in a)


# ---- triage_item / list ---------------------------------------------------

def test_triage_item_non_destructive():
    src = _item(subject="Meeting please reply")
    out = A.triage_item(src, now=NOW)
    assert "category" not in src  # original untouched
    assert out["category"] == "action" and out["needs_reply"] is True
    assert out["priority"] > 0 and out["summary"]


def test_triage_list():
    out = A.triage_list([_item(id="a", subject="URGENT"),
                         _item(id="b", subject="newsletter")], now=NOW)
    assert len(out) == 2 and out[0]["category"] == "urgent"


# ---- filter / views / sort ------------------------------------------------

def test_filter_by_category_and_source():
    items = A.triage_list([
        _item(id="a", source="email", subject="URGENT"),
        _item(id="b", source="message", subject="newsletter"),
    ], now=NOW)
    assert len(A.filter_items(items, category="urgent")) == 1
    assert len(A.filter_items(items, source="message")) == 1
    assert len(A.filter_items(items, category="urgent", source="message")) == 0


def test_needs_reply_view_sorted():
    items = A.triage_list([
        _item(id="a", subject="newsletter"),            # no reply
        _item(id="b", subject="please confirm?"),       # reply
        _item(id="c", subject="URGENT account locked"),  # reply, higher pri
    ], now=NOW)
    view = A.needs_reply_view(items)
    ids = [it["id"] for it in view]
    assert "a" not in ids and ids[0] == "c"


def test_sort_by_priority_desc():
    items = A.triage_list([
        _item(id="lo", subject="newsletter"),
        _item(id="hi", subject="URGENT payment failed"),
    ], now=NOW)
    assert [it["id"] for it in A.sort_by_priority(items)] == ["hi", "lo"]


def test_category_counts():
    items = A.triage_list([
        _item(id="a", subject="URGENT"),
        _item(id="b", subject="please reply?"),
        _item(id="c", subject="SALE"),
        _item(id="d", subject="info"),
    ], now=NOW)
    c = A.category_counts(items)
    assert c["urgent"] == 1 and c["action"] == 1 and c["promo"] == 1
    assert c["fyi"] == 1 and c["needsReply"] >= 2


# ---- snooze / bulk / active ------------------------------------------------

def test_snooze_valid_and_invalid():
    end = A.snooze_until(NOW, 24)
    assert end == NOW + timedelta(hours=24)
    try:
        A.snooze_until(NOW, 5)
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_bulk_done_is_non_destructive():
    items = A.triage_list([_item(id="a"), _item(id="b")], now=NOW)
    out = A.apply_bulk(items, ["a"], "done", now=NOW)
    assert out[0]["done"] is True and "done" not in items[0]
    assert "done" not in out[1]


def test_bulk_snooze_and_active_hides_it():
    items = A.triage_list([_item(id="a"), _item(id="b")], now=NOW)
    out = A.apply_bulk(items, ["a"], "snooze", now=NOW, hours=24)
    active = A.active_items(out, now=NOW)
    assert [it["id"] for it in active] == ["b"]
    # after the window it returns
    later = A.active_items(out, now=NOW + timedelta(hours=25))
    assert {it["id"] for it in later} == {"a", "b"}


def test_unknown_bulk_action_raises():
    try:
        A.apply_bulk([_item()], ["1"], "nuke")
        assert False
    except ValueError:
        pass


def test_done_items_excluded_from_active():
    items = A.triage_list([_item(id="a"), _item(id="b")], now=NOW)
    out = A.apply_bulk(items, ["a"], "done", now=NOW)
    assert [it["id"] for it in A.active_items(out, now=NOW)] == ["b"]


# ---- convert payloads ------------------------------------------------------

def test_to_task_payload():
    p = A.to_task_payload(_item(subject="Pay rent", snippet="due soon"))
    assert p["title"] == "Pay rent" and p["source"] == "inbox"
    assert p["source_id"] == "1"


def test_to_reminder_payload():
    when = NOW + timedelta(days=1)
    p = A.to_reminder_payload(_item(subject="Call doctor"), when=when)
    assert p["text"] == "Call doctor" and p["when"] == when.isoformat()


def run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
    print(f"ai_inbox: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
