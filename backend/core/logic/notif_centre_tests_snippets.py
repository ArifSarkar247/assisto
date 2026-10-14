"""
notif_centre_tests_snippets.py — plain-assert tests for core.logic.notif_centre.

NOT a Django TestCase. Smoke locally:
    (cd backend && python3 -c "import core.logic.notif_centre_tests_snippets as t; t.run_all()")
"""
from datetime import datetime, date, timedelta

from core.logic import notif_centre as N

NOW = datetime(2026, 10, 14, 10, 0, 0)  # a Wednesday, 10am


# ---------------------------------------------------------------- reminders feed
def test_section_today_upcoming_missed():
    assert N.section_for(NOW.replace(hour=14), NOW) == N.SEC_TODAY        # later today
    assert N.section_for(NOW.replace(hour=9), NOW) == N.SEC_TODAY         # earlier today
    assert N.section_for(NOW + timedelta(days=2), NOW) == N.SEC_UPCOMING
    assert N.section_for(NOW - timedelta(days=1), NOW) == N.SEC_MISSED
    assert N.section_for(None, NOW) == N.SEC_TODAY                        # undated
    assert N.section_for(NOW - timedelta(days=1), NOW, done=True) is None  # done hidden


def test_window_drops_far_future_keeps_missed():
    assert N.in_feed_window(NOW + timedelta(days=3), NOW) is True
    assert N.in_feed_window(NOW + timedelta(days=30), NOW) is False
    assert N.in_feed_window(NOW - timedelta(days=5), NOW) is True
    assert N.in_feed_window(None, NOW) is True


def test_route_for_source_uses_screen_routes():
    assert N.route_for("medicine") == "family"
    assert N.route_for("subscription") == "subscriptions"
    assert N.route_for("todo") == "notes"
    assert N.route_for("unknown") == "reminders"


def test_normalize_reminder_bilingual_and_actions():
    it = N.normalize_reminder(
        {"id": 7, "source_module": "medicine",
         "title": {"bn": "ওষুধ", "en": "Medicine"},
         "when": NOW.replace(hour=9)}, NOW)
    assert it["section"] == N.SEC_TODAY
    assert it["title"] == {"bn": "ওষুধ", "en": "Medicine"}
    assert it["route"] == "family"
    assert it["actions"] == ["done", "snooze", "open"]


def test_normalize_reminder_string_title_and_drop_done():
    it = N.normalize_reminder({"id": 1, "title": "Call bank", "when": NOW}, NOW)
    assert it["title"] == {"bn": "Call bank", "en": "Call bank"}
    assert N.normalize_reminder({"id": 2, "title": "x", "done": True, "when": NOW}, NOW) is None


def test_build_reminders_groups_sorts_and_windows():
    raw = [
        {"id": 1, "source_module": "reminder", "title": "A", "when": NOW + timedelta(days=1)},
        {"id": 2, "source_module": "loan", "title": "B", "when": NOW - timedelta(days=2)},
        {"id": 3, "source_module": "medicine", "title": "C", "when": NOW.replace(hour=8)},
        {"id": 4, "source_module": "subscription", "title": "D", "when": NOW + timedelta(days=40)},  # dropped
        {"id": 5, "source_module": "loan", "title": "E", "when": NOW - timedelta(days=5)},
    ]
    feed = N.build_reminders(raw, NOW)
    assert len(feed[N.SEC_UPCOMING]) == 1
    assert len(feed[N.SEC_TODAY]) == 1
    assert len(feed[N.SEC_MISSED]) == 2
    # missed sorted oldest-first: id 5 (-5d) before id 2 (-2d)
    assert [i["id"] for i in feed[N.SEC_MISSED]] == [5, 2]


def test_reminders_counts():
    raw = [
        {"id": 1, "title": "a", "when": NOW},
        {"id": 2, "title": "b", "when": NOW - timedelta(days=1)},
        {"id": 3, "title": "c", "when": NOW + timedelta(days=2)},
    ]
    c = N.reminders_counts(raw, NOW)
    assert c == {N.SEC_MISSED: 1, N.SEC_TODAY: 1, N.SEC_UPCOMING: 1}


# ---------------------------------------------------------------- snooze
def test_snooze_presets_return_new_time():
    assert N.snooze_until("15m", NOW) == NOW + timedelta(minutes=15)
    assert N.snooze_until("1h", NOW) == NOW + timedelta(hours=1)
    tm = N.snooze_until("tomorrow", NOW)
    assert tm.date() == (NOW.date() + timedelta(days=1)) and tm.hour == N.TOMORROW_HOUR
    cust = datetime(2026, 12, 25, 18, 30)
    assert N.snooze_until("custom", NOW, custom=cust) == cust
    assert N.snooze_until("bogus", NOW) is None


# ---------------------------------------------------------------- notifications feed
def _events():
    return [
        {"id": 1, "type": N.TYPE_CIRCLE_REQUEST, "title": "req", "at": NOW, "seen": False},
        {"id": 2, "type": N.TYPE_FAMILY_ALERT, "title": "missed med", "at": NOW - timedelta(hours=1), "seen": True},
        {"id": 3, "type": N.TYPE_SCAM, "title": "scam", "at": NOW - timedelta(hours=2), "seen": False},
        {"id": 4, "type": "chat_message", "title": "hi", "at": NOW, "seen": False},   # EXCLUDED
        {"id": 5, "type": N.TYPE_BUSINESS, "title": "order", "at": NOW - timedelta(minutes=5), "seen": False},
    ]


def test_chat_events_excluded():
    assert N.is_chat_event({"type": "chat_message"}) is True
    assert N.is_chat_event({"type": "circle_message"}) is True
    assert N.is_chat_event({"type": "circle_activity", "is_chat": True}) is True
    assert N.is_chat_event({"type": N.TYPE_SCAM}) is False
    feed = N.build_feed(_events())
    assert all(it["type"] not in ("chat_message",) for it in feed)
    assert all(it["id"] != 4 for it in feed)   # the chat event is gone


def test_feed_sorted_newest_first_and_bilingual():
    feed = N.build_feed(_events())
    ats = [it["at"] for it in feed]
    assert ats == sorted(ats, reverse=True)
    first = feed[0]
    assert set(first["title"].keys()) == {"bn", "en"}
    assert first["route"]  # has a deep-link route


def test_type_filter():
    feed = N.build_feed(_events(), type_filter=N.TYPE_SCAM)
    assert [it["id"] for it in feed] == [3]
    feed2 = N.build_feed(_events(), type_filter={N.TYPE_SCAM, N.TYPE_BUSINESS})
    assert {it["id"] for it in feed2} == {3, 5}


def test_settings_disable_a_type_removes_it_from_feed_and_count():
    settings = {N.TYPE_SCAM: False}
    feed = N.build_feed(_events(), settings_enabled=settings)
    assert all(it["type"] != N.TYPE_SCAM for it in feed)
    # unseen were: circle_request(1), scam(3), business(5) => 3; disabling scam => 2
    assert N.unseen_count(_events()) == 3
    assert N.unseen_count(_events(), settings_enabled=settings) == 2


def test_mark_all_seen_sets_every_item():
    feed = N.mark_all_seen(_events())
    assert all(it["seen"] for it in feed)


def test_badges_combines_chat_and_notif():
    b = N.badges(5, _events())
    assert b["my_circle_unread"] == 5   # chat count passed through (chat NOT in notif)
    assert b["notif_unseen"] == 3
    # chat unread is independent of notif feed:
    assert N.badges(0, _events())["notif_unseen"] == 3


def run_all():
    import inspect
    import sys
    mod = sys.modules[__name__]
    tests = [f for n, f in inspect.getmembers(mod, inspect.isfunction)
             if n.startswith("test_")]
    for fn in tests:
        fn()
    print(f"notif_centre: {len(tests)} tests passed")


if __name__ == "__main__":
    run_all()
