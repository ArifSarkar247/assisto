"""
voice_commands_tests_snippets.py — plain-assert tests for
core.logic.voice_commands (ADVANCED voice layer). NOT a Django TestCase.

Smoke locally:
    cd backend && python3 -c "import core.logic.voice_commands_tests_snippets as t; t.run_all()"

Covers: empty input, SOS priority, call/reminder/expense/open intents in
en + Banglish + bn, amount extraction (reused money_parse digit-normalise),
reminder time extraction (reused nlp_datetime), route reuse of screen_synonyms,
the always-confirm invariant, and the honesty invariant (no transcript is ever
invented — map_command only ever runs on text passed in).
"""
from core.logic import voice_commands as V

_checks = 0


def _ok(cond, msg=""):
    global _checks
    assert cond, msg
    _checks += 1


def test_empty():
    _ok(V.map_command("") is None)
    _ok(V.map_command(None) is None)
    _ok(V.map_command("   ") is None)


def test_sos_wins():
    for txt in ["SOS", "help me please", "বিপদ! বাঁচাও", "bipod, bachao"]:
        r = V.map_command(txt)
        _ok(r["intent"] == V.INTENT_SOS, txt)
        _ok(r["route"] == "emergency", txt)
        _ok(r["confirm"] is True, txt)
    # SOS beats an otherwise "call" sentence
    r = V.map_command("call for help me emergency")
    _ok(r["intent"] == V.INTENT_SOS)


def test_call():
    r = V.map_command("call mom")
    _ok(r["intent"] == V.INTENT_CALL)
    _ok(r["route"] == "circle")
    _ok(r["args"]["name"] == "mom", r["args"])
    # Banglish + bn
    _ok(V.map_command("abba ke phone koro")["intent"] == V.INTENT_CALL)
    _ok(V.map_command("আব্বুকে কল করো")["intent"] == V.INTENT_CALL)


def test_reminder():
    r = V.map_command("remind me to take medicine at 9pm")
    _ok(r["intent"] == V.INTENT_REMINDER)
    _ok(r["route"] == "reminders")
    _ok("medicine" in (r["args"]["text"] or "").lower(), r["args"])
    # nlp_datetime should have found a time
    _ok(isinstance(r["args"]["when"], dict))
    _ok(r["args"]["when"], "expected a parsed schedule for '9pm'")
    # bn
    _ok(V.map_command("আগামীকাল সকালে মনে করিয়ে দিও")["intent"] == V.INTENT_REMINDER)


def test_expense():
    r = V.map_command("i spent 500 on groceries")
    _ok(r["intent"] == V.INTENT_EXPENSE)
    _ok(r["route"] == "money")
    _ok(r["args"]["amount"] == 500, r["args"])
    # Bangla numerals via money_parse.normalize_digits reuse
    r2 = V.map_command("৫০ টাকা খরচ করেছি")
    _ok(r2["intent"] == V.INTENT_EXPENSE, r2)
    _ok(r2["args"]["amount"] == 50, r2["args"])
    # no amount spoken -> amount None, still an expense intent
    r3 = V.map_command("log expense lunch")
    _ok(r3["intent"] == V.INTENT_EXPENSE)
    _ok(r3["args"]["amount"] is None, r3["args"])


def test_expense_date_past_biased():
    from datetime import datetime
    now = datetime(2026, 10, 13, 10, 0)
    r = V.map_command("কাল ৫০০ টাকা খরচ করেছি", now=now)
    _ok(r["intent"] == V.INTENT_EXPENSE, r)
    _ok(r["args"]["date"] == "2026-10-12", r["args"])        # yesterday
    r = V.map_command("kal 200 taka khoroch korechi", now=now)
    _ok(r["args"]["date"] == "2026-10-12", r["args"])
    r = V.map_command("৫০ টাকা খরচ করেছি", now=now)
    _ok(r["args"]["date"] == "2026-10-13", r["args"])        # no day word -> today


def test_open_route_reuse():
    # open-verb + known subject -> navigate (reuses screen_synonyms)
    r = V.map_command("open my money")
    _ok(r["intent"] == V.INTENT_OPEN)
    _ok(r["route"] == "money", r)
    _ok(V.map_command("show documents")["route"] == "documents")
    # bn open-phrase resolves via shared synonym map
    r_bn = V.map_command("আমার হিসাব দেখাও")
    _ok(r_bn["intent"] == V.INTENT_OPEN)
    _ok(r_bn["route"] == "money", r_bn)
    # bare subject with no verb still navigates
    _ok(V.map_command("reminders")["route"] == "reminders")


def test_unknown():
    r = V.map_command("the weather is nice today")
    _ok(r["intent"] == V.INTENT_UNKNOWN)
    _ok(r["route"] is None)
    _ok(r["confirm"] is True)  # confirm invariant holds even for unknown


def test_confirm_invariant():
    for txt in ["call mom", "i spent 500", "remind me at 9pm",
                "open money", "sos", "weather"]:
        r = V.map_command(txt)
        _ok(r is not None and r["confirm"] is True, txt)


def run_all():
    test_empty()
    test_sos_wins()
    test_call()
    test_reminder()
    test_expense()
    test_expense_date_past_biased()
    test_open_route_reuse()
    test_unknown()
    test_confirm_invariant()
    print(f"voice_commands: {_checks} checks passed")


if __name__ == "__main__":
    run_all()
