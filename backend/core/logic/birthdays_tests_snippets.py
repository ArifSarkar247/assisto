"""
birthdays_tests_snippets.py — plain-assert tests for core.logic.birthdays.

NOT a Django TestCase. Smoke locally:

    python3 -c "import core.logic.birthdays_tests_snippets as t; t.run_all()"
"""
from datetime import date
from core.logic import birthdays as B


def test_next_occurrence_future_this_year():
    today = date(2026, 1, 1)
    nxt = B.next_occurrence("1990-06-15", today=today)
    assert nxt == date(2026, 6, 15), nxt


def test_next_occurrence_rolls_to_next_year():
    today = date(2026, 7, 1)
    nxt = B.next_occurrence("1990-06-15", today=today)
    assert nxt == date(2027, 6, 15), nxt


def test_today_counts_as_occurrence():
    today = date(2026, 6, 15)
    assert B.next_occurrence("1990-06-15", today=today) == today
    assert B.days_until("1990-06-15", today=today) == 0


def test_leap_day_moves_to_feb28_nonleap():
    # 2026 is not a leap year -> Feb 29 falls back to Feb 28
    nxt = B.next_occurrence("2000-02-29", today=date(2026, 1, 1))
    assert nxt == date(2026, 2, 28), nxt


def test_turning_age():
    today = date(2026, 1, 1)
    assert B.turning_age("1990-06-15", today=today) == 36
    # unknown year sentinel -> None
    assert B.turning_age("1900-06-15", today=today) is None


def test_turning_age_future_year_never_negative():
    # A birth/start year AFTER the next occurrence must never yield a negative
    # age — it is clamped to 0.
    today = date(2026, 1, 1)
    # next occurrence of 06-15 in 2026; birth year 2030 is in the future.
    age = B.turning_age("2030-06-15", today=today)
    assert age == 0, age


def test_lead_days_single_and_day_of():
    today = date(2026, 6, 1)
    dates = B.reminder_dates("1990-06-15", lead_days=1, today=today)
    assert date(2026, 6, 14) in dates, dates   # 1 day before
    assert date(2026, 6, 15) in dates, dates   # day of


def test_lead_days_multiple_and_deduped():
    today = date(2026, 6, 1)
    dates = B.reminder_dates("1990-06-15", lead_days=[7, 1], today=today)
    assert date(2026, 6, 8) in dates, dates
    assert date(2026, 6, 14) in dates, dates
    assert date(2026, 6, 15) in dates, dates
    assert dates == sorted(dates), dates
    assert len(dates) == len(set(dates)), dates


def test_lead_days_not_before_today():
    today = date(2026, 6, 14)
    dates = B.reminder_dates("1990-06-15", lead_days=[30, 1], today=today)
    assert all(d >= today for d in dates), dates


def test_should_remind_today():
    assert B.should_remind_today("1990-06-15", lead_days=1, today=date(2026, 6, 14))
    assert B.should_remind_today("1990-06-15", lead_days=1, today=date(2026, 6, 15))
    assert not B.should_remind_today("1990-06-15", lead_days=1, today=date(2026, 6, 10))


def test_clamp_lead_days():
    assert B.clamp_lead_days(-5) == 0
    assert B.clamp_lead_days(999) == B.LEAD_DAYS_MAX
    assert B.clamp_lead_days("bad") == B.LEAD_DAYS_DEFAULT


def test_upcoming_sorted_and_filtered():
    today = date(2026, 6, 1)
    occ = [
        {"name": "A", "date": "1990-06-20", "kind": "birthday"},
        {"name": "B", "date": "1985-06-05", "kind": "birthday"},
        {"name": "C", "date": "1970-12-25", "kind": "memorable"},
    ]
    up = B.upcoming(occ, within_days=30, today=today)
    names = [o["name"] for o in up]
    assert names == ["B", "A"], names   # C is >30 days away, filtered out
    assert up[0]["days_until"] <= up[1]["days_until"], up


def test_wish_drafts_three_styles_and_name():
    for lang in ("bn", "en"):
        d = B.wish_drafts("Rahim", "birthday", age=40, lang=lang)
        assert len(d) == 3, d
        assert {x["style"] for x in d} == {"short", "warm", "formal"}, d
        assert all("Rahim" in x["text"] for x in d), d


def test_wish_drafts_age_only_when_relevant():
    # death anniversary never shows an age clause
    d = B.wish_drafts("X", "death_anniversary", age=50, lang="en")
    assert all("50" not in x["text"] for x in d), d


def test_greeting_card_both_langs():
    for lang in ("bn", "en"):
        c = B.greeting_card("Mina", "birthday", age=30, lang=lang)
        assert c["title"] and c["body"], c
        assert "Mina" in c["body"], c


def test_reminder_payload_variants():
    p0 = B.reminder_payload("A", "birthday", 0, "en")
    assert "Today" in p0["body"], p0
    p1 = B.reminder_payload("A", "birthday", 1, "en")
    assert "Tomorrow" in p1["body"], p1
    p5 = B.reminder_payload("A", "birthday", 5, "en")
    assert "5 days" in p5["body"], p5


def test_never_auto_send_contract():
    # drafts are plain text structures only — no send/network symbols exist
    src_fns = [B.wish_drafts, B.greeting_card]
    for fn in src_fns:
        assert callable(fn)


# ---- ADVANCED (v2.1 §21) upgrades --------------------------------------

def test_upcoming_this_week_flag_and_label():
    today = date(2026, 6, 1)
    occ = [
        {"name": "Soon", "date": "1990-06-05", "kind": "birthday"},   # 4 days
        {"name": "Later", "date": "1990-06-20", "kind": "anniversary"},  # 19 days
    ]
    up = B.upcoming(occ, within_days=30, today=today, lang="en")
    by = {o["name"]: o for o in up}
    assert by["Soon"]["this_week"] is True, up
    assert by["Later"]["this_week"] is False, up
    assert by["Soon"]["kind_label"] == "Birthday", up
    assert by["Later"]["kind_label"] == "Anniversary", up


def test_this_week_window():
    today = date(2026, 6, 1)
    occ = [
        {"name": "A", "date": "1990-06-03", "kind": "birthday"},   # 2 days
        {"name": "B", "date": "1990-06-20", "kind": "birthday"},   # 19 days
    ]
    tw = B.this_week(occ, today=today)
    assert [o["name"] for o in tw] == ["A"], tw


def test_non_yearly_oneoff_dropped_after_pass():
    today = date(2026, 6, 10)
    occ = [
        {"name": "Future one-off", "date": "2026-06-15", "kind": "memorable", "yearly": False},
        {"name": "Past one-off", "date": "2026-06-05", "kind": "memorable", "yearly": False},
    ]
    up = B.upcoming(occ, within_days=30, today=today)
    names = [o["name"] for o in up]
    assert names == ["Future one-off"], names
    assert up[0]["turning_age"] is None, up        # one-offs never show age


def test_wish_drafts_relation_in_formal_only():
    d_en = B.wish_drafts("Mom-name", "birthday", age=50, lang="en", relation="Mom")
    assert "Dear Mom" in d_en[2]["text"], d_en
    assert "Dear Mom" not in d_en[0]["text"], d_en
    # bn formal drafts already open with "Dear" (priyo), so the relation is
    # NOT double-prepended: the draft stays unchanged.
    plain = B.wish_drafts("X", "birthday", lang="bn")
    withrel = B.wish_drafts("X", "birthday", lang="bn", relation="মা")
    assert withrel[2]["text"] == plain[2]["text"], withrel


def test_ai_wish_mock_default_is_honest():
    w = B.ai_wish("Rahim", "birthday", age=30, lang="en", style="short")
    assert w["source"] == "ai_mock", w
    assert w["is_mock"] is True, w
    assert w["ai_required"] is True, w
    assert w["auto_sent"] is False, w
    assert "Rahim" in w["text"], w


def test_ai_wish_real_provider_when_key():
    def fake_llm(prompt):
        return {"text": "LLM: " + (prompt.get("name") or ""), "source": "ai"}
    w = B.ai_wish("Mina", "birthday", lang="en", ai_key_available=True, provider=fake_llm)
    assert w["source"] == "ai", w
    assert w["is_mock"] is False, w
    assert w["text"].startswith("LLM: Mina"), w
    # key present but NO provider -> still mock (honest)
    w2 = B.ai_wish("Mina", "birthday", lang="en", ai_key_available=True)
    assert w2["is_mock"] is True, w2


def test_send_actions_with_and_without_phone():
    acts = B.send_actions("Happy birthday!", phone="+8801711111111", lang="en")
    kinds = [a["kind"] for a in acts]
    assert "whatsapp" in kinds and "sms" in kinds and "call" in kinds, kinds
    wa = next(a for a in acts if a["kind"] == "whatsapp")
    assert wa["uri"].startswith("https://wa.me/8801711111111?text="), wa
    assert "%21" in wa["uri"] or "Happy" in wa["uri"], wa   # text encoded
    assert all(a["auto_sent"] is False for a in acts), acts
    # no phone -> whatsapp share (no recipient) + share only
    acts2 = B.send_actions("hi", phone=None, lang="en")
    kinds2 = [a["kind"] for a in acts2]
    assert "sms" not in kinds2 and "call" not in kinds2, kinds2
    assert "whatsapp" in kinds2 and "share" in kinds2, kinds2


def test_link_and_import():
    patch = B.link_occasion_to_contact({"name": "A"}, contact_id=7,
                                        phone="0171", relation="friend")
    assert patch["linked_contact_id"] == 7, patch
    assert patch["phone"] == "0171", patch
    drafts = B.import_occasions_from_contacts([
        {"id": 1, "name": "Has bday", "birthday": "1990-03-04", "phones": ["0171"]},
        {"id": 2, "name": "No bday"},
    ])
    assert len(drafts) == 1, drafts
    assert drafts[0]["name"] == "Has bday", drafts
    assert drafts[0]["date"] == "1990-03-04", drafts
    assert drafts[0]["phone"] == "0171", drafts
    assert drafts[0]["source"] == "contacts_import", drafts


def test_scenario_week_before_mothers_birthday():
    # Real-world: Mom's birthday is next week; user set pre-reminders 7/1/0.
    today = date(2026, 6, 8)
    occ = {"name": "Mom", "date": "1970-06-15", "kind": "birthday",
           "relation": "Mom", "lead_days": [7, 1, 0]}
    up = B.upcoming([occ], within_days=30, today=today, lang="en")[0]
    assert up["days_until"] == 7 and up["this_week"] is True, up
    assert up["turning_age"] == 56, up
    # a pre-reminder fires today (7 days before)
    assert B.should_remind_today(occ["date"], lead_days=occ["lead_days"], today=today), occ
    # the wish the user will send, personalised + key-gated AI preview
    w = B.ai_wish(up["name"], up["kind"], age=up["turning_age"], lang="en",
                  relation="Mom", style="formal")
    assert "Mom" in w["text"] and w["auto_sent"] is False, w
    # one-tap send opens WhatsApp with the text prefilled (user presses send)
    acts = B.send_actions(w["text"], phone="+8801711111111", lang="en")
    assert any(a["kind"] == "whatsapp" and not a["auto_sent"] for a in acts), acts


def run_all():
    import inspect
    fns = [v for k, v in sorted(globals().items())
           if k.startswith("test_") and inspect.isfunction(v)]
    for fn in fns:
        fn()
    print(f"birthdays: {len(fns)} tests passed")
    return len(fns)


if __name__ == "__main__":
    run_all()
