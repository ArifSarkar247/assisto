"""
reminders_tests_snippets.py — pure-python self-tests for nlp_datetime +
reminders_engine. NO Django, NO DB. Run directly:

    python3 backend/core/logic/reminders_tests_snippets.py

Every assert is a real scenario a Bangladeshi user would type (Bangla / English /
Banglish, Bangla digits). `NOW` is fixed so results are deterministic.
"""

import os
import sys
import importlib.util
from datetime import datetime, date

# --- load the two modules without needing the Django package context ---------
_HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    path = os.path.join(_HERE, name + ".py")
    spec = importlib.util.spec_from_file_location("logic_" + name, path)
    mod = importlib.util.module_from_spec(spec)
    # register so reminders_engine's `from .nlp_datetime import ...` resolves:
    sys.modules["logic_" + name] = mod
    spec.loader.exec_module(mod)
    return mod


# reminders_engine does `from .nlp_datetime import ...`; emulate the package.
import types
_pkg = types.ModuleType("rpkg")
_pkg.__path__ = [_HERE]
sys.modules["rpkg"] = _pkg
_ndt_spec = importlib.util.spec_from_file_location("rpkg.nlp_datetime",
                                                   os.path.join(_HERE, "nlp_datetime.py"))
nlp = importlib.util.module_from_spec(_ndt_spec)
sys.modules["rpkg.nlp_datetime"] = nlp
_ndt_spec.loader.exec_module(nlp)
_eng_spec = importlib.util.spec_from_file_location("rpkg.reminders_engine",
                                                   os.path.join(_HERE, "reminders_engine.py"))
eng = importlib.util.module_from_spec(_eng_spec)
sys.modules["rpkg.reminders_engine"] = eng
_eng_spec.loader.exec_module(eng)

parse = nlp.parse

# Fixed reference time: Tuesday 13 Oct 2026, 10:00 (so weekday math is checkable).
# (13 Oct 2026 is a Tuesday; the next Friday is 16 Oct.)
NOW = datetime(2026, 10, 13, 10, 0, 0)

_count = 0


def ok(cond, msg):
    global _count
    _count += 1
    assert cond, "FAIL: " + msg


def di(iso):
    return datetime.fromisoformat(iso) if iso else None


# =========================================================== nlp_datetime
def test_digits():
    ok(nlp.normalize_digits("১২৩৪৫৬৭৮৯০") == "1234567890", "bn digits")
    ok(nlp.normalize_digits(None) == "", "none digits")


def test_relative_bn():
    r = parse("আগামীকাল ডাক্তার দেখাতে যাব", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 14), "আগামীকাল -> +1 day")
    ok(di(r["datetime"]).hour == nlp.DEFAULT_HOUR, "no time -> default 9am")
    ok(r["date_only"] is True, "date_only when no clock")

    r = parse("৩ দিন পর বিল দিতে হবে", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 16), "৩ দিন পর")

    r = parse("পরশু মিটিং", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 15), "পরশু -> +2")

    r = parse("আজকে রিপোর্ট জমা", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 13), "আজ -> today")


def test_time_bn():
    r = parse("প্রতিদিন সকাল ৮টা ওষুধ", now=NOW)
    ok(r["recurrence_rule"]["freq"] == "daily", "প্রতিদিন -> daily")
    ok(r["recurrence_rule"]["time"] == "08:00", "সকাল ৮টা -> 08:00")

    r = parse("রাত ৯টা খবর দেখব", now=NOW)
    # রাত makes bare 9টা -> 21:00
    ok(di(r["datetime"]).hour == 21, "রাত ৯টা -> 21:00")

    r = parse("বিকাল ৫টা চা", now=NOW)
    ok(di(r["datetime"]).hour == 17, "বিকাল ৫টা -> 17:00")

    r = parse("সকাল ৭টা ৩০ মিনিট দৌড়", now=NOW)
    ok(di(r["datetime"]).hour == 7 and di(r["datetime"]).minute == 30, "৭টা ৩০ মিনিট")


def test_weekly_bn():
    r = parse("প্রতি শুক্রবার জুম্মা", now=NOW)
    ok(r["recurrence_rule"]["freq"] == "weekly", "প্রতি শুক্রবার weekly")
    ok(r["recurrence_rule"]["weekday"] == 4, "শুক্রবার -> 4 (Fri)")
    ok(di(r["datetime"]).weekday() == 4, "anchor is a Friday")
    # NOW is Tue 13 Oct; next Friday is 16 Oct
    ok(di(r["datetime"]).date() == date(2026, 10, 16), "next Friday 16 Oct")


def test_monthly_bn():
    r = parse("প্রতি মাসের ৫ তারিখ বাড়ি ভাড়া", now=NOW)
    ok(r["recurrence_rule"]["freq"] == "monthly", "monthly")
    ok(r["recurrence_rule"]["day_of_month"] == 5, "dom 5")
    # 5th already passed in Oct (now 13th) -> next is 5 Nov
    ok(di(r["datetime"]).date() == date(2026, 11, 5), "next 5th -> Nov")

    r = parse("প্রতি মাসের ১ তারিখ সেলারি", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 11, 1), "1st -> Nov 1")


def test_next_month_date():
    r = parse("আগামী মাসের ৫ তারিখ পরীক্ষা", now=NOW)
    ok(r["recurrence_rule"] is None, "one-off, not recurring")
    ok(di(r["datetime"]).date() == date(2026, 11, 5), "next month day 5")


def test_english():
    r = parse("next Friday 5pm meeting", now=NOW)
    ok(di(r["datetime"]).weekday() == 4, "next friday")
    ok(di(r["datetime"]).hour == 17, "5pm -> 17:00")

    r = parse("every day at 7:30am gym", now=NOW)
    ok(r["recurrence_rule"]["freq"] == "daily", "every day daily")
    ok(r["recurrence_rule"]["time"] == "07:30", "7:30am")

    r = parse("in 3 days pay rent", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 16), "in 3 days")

    r = parse("remind me to call mom tomorrow morning", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 14), "tomorrow")
    ok(di(r["datetime"]).hour == 8, "morning -> 8")
    ok("call mom" in r["clean_title"].lower(), "clean title keeps task: " + r["clean_title"])


def test_explicit_date():
    r = parse("25/12 christmas", now=NOW)
    ok(di(r["datetime"]).month == 12 and di(r["datetime"]).day == 25, "25/12")
    r = parse("5/1/2027 trip", now=NOW)
    ok(di(r["datetime"]).year == 2027, "explicit year")


def test_banglish():
    r = parse("protidin sokal 8ta medicine", now=NOW)
    # 'protidin' daily; '8ta' not matched (banglish time weak) but freq ok
    ok(r["recurrence_rule"]["freq"] == "daily", "banglish protidin")
    r = parse("next friday call", now=NOW)
    ok(di(r["datetime"]).weekday() == 4, "banglish-ish english friday")


def test_confidence_and_clean():
    r = parse("just some random text", now=NOW)
    ok(r["datetime"] is None, "no date -> None datetime")
    ok(r["confidence"] == 0.0, "no match -> 0 confidence")
    r = parse("প্রতি মাসের ৫ তারিখ সকাল ৯টা", now=NOW)
    ok(r["confidence"] >= 0.8, "strong recurrence -> high confidence")


def test_time_only_rolls_to_tomorrow():
    # NOW is 10:00; "8am" already passed -> tomorrow
    r = parse("8am breakfast", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 14), "8am past -> tomorrow")
    # "2pm" still ahead today
    r = parse("2pm lunch", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 13), "2pm today")


# =========================================================== engine
def test_next_occurrence():
    rule = {"freq": "daily", "interval": 1, "weekday": None,
            "day_of_month": None, "month": None, "time": "08:00"}
    anchor = datetime(2026, 10, 13, 8, 0)
    nxt = eng.next_occurrence(anchor, rule, after=NOW)  # NOW 10:00 -> tomorrow 8am
    ok(nxt == datetime(2026, 10, 14, 8, 0), "daily next after today's pass")

    rule = {"freq": "weekly", "interval": 1, "weekday": 4,
            "day_of_month": None, "month": None, "time": "17:00"}
    anchor = datetime(2026, 10, 16, 17, 0)
    nxt = eng.next_occurrence(anchor, rule, after=datetime(2026, 10, 16, 18, 0))
    ok(nxt == datetime(2026, 10, 23, 17, 0), "weekly +1 week")

    rule = {"freq": "monthly", "interval": 1, "weekday": None,
            "day_of_month": 31, "month": None, "time": "09:00"}
    anchor = datetime(2026, 1, 31, 9, 0)
    nxt = eng.next_occurrence(anchor, rule, after=datetime(2026, 2, 1, 0, 0))
    ok(nxt == datetime(2026, 2, 28, 9, 0), "monthly clamps Feb (28)")


def test_interval():
    rule = {"freq": "daily", "interval": 3, "weekday": None,
            "day_of_month": None, "month": None, "time": "09:00"}
    anchor = datetime(2026, 10, 13, 9, 0)
    nxt = eng.next_occurrence(anchor, rule, after=datetime(2026, 10, 13, 10, 0))
    ok(nxt == datetime(2026, 10, 16, 9, 0), "every 3 days")


def test_expand():
    rule = {"freq": "weekly", "interval": 1, "weekday": 4,
            "day_of_month": None, "month": None, "time": "17:00"}
    anchor = datetime(2026, 10, 16, 17, 0)
    occ = eng.expand(anchor, rule, start=NOW,
                     end=datetime(2026, 11, 30, 23, 59), limit=10)
    ok(len(occ) == 7, "Fridays 16 Oct..30 Nov = 7, got %d" % len(occ))
    ok(occ[0] == datetime(2026, 10, 16, 17, 0), "first friday")
    ok(all(d.weekday() == 4 for d in occ), "all fridays")


def test_agenda_combined():
    # a weekly recurring reminder + a one-off dated to-do + a dated note,
    # expanded into one sorted calendar window (the mirror of the app view).
    start = datetime(2026, 10, 13, 0, 0)
    end = datetime(2026, 10, 27, 23, 59)
    items = [
        {"id": "r1", "kind": "reminder", "title": "prayer",
         "anchor": datetime(2026, 10, 16, 17, 0),
         "rule": {"freq": "weekly", "interval": 1, "weekday": 4,
                  "day_of_month": None, "month": None, "time": "17:00"},
         "done": False},
        {"id": "t1", "kind": "todo", "title": "pay bill",
         "anchor": datetime(2026, 10, 13, 8, 0), "rule": None, "done": False},
        {"id": "n1", "kind": "note", "title": "groceries",
         "anchor": datetime(2026, 10, 20, 10, 0), "rule": None, "done": False},
    ]
    ag = eng.agenda(items, start=start, end=end, now=NOW)
    kinds = [o["kind"] for o in ag]
    # two Fridays (16, 23 Oct) + the todo + the note = 4 occurrences
    ok(len(ag) == 4, "combined agenda size, got %d" % len(ag))
    ok(ag == sorted(ag, key=lambda o: o["when"]), "agenda sorted by when")
    ok(kinds.count("reminder") == 2, "weekly reminder expanded to 2 Fridays")
    ok(kinds.count("note") == 1 and kinds.count("todo") == 1, "note+todo once")
    # the past-anchored todo (12 Oct < NOW) that is in-window is flagged overdue
    todo = next(o for o in ag if o["kind"] == "todo")
    ok(todo["overdue"] is True, "past todo overdue")
    future_note = next(o for o in ag if o["kind"] == "note")
    ok(future_note["overdue"] is False, "future note not overdue")
    ok(all(o["recurring"] == (o["kind"] == "reminder") for o in ag),
       "recurring flag set only on expanded reminder")


def test_overdue():
    anchor = datetime(2026, 10, 12, 9, 0)  # yesterday
    ok(eng.is_overdue(anchor, None, done=False, now=NOW) is True, "one-off past overdue")
    ok(eng.is_overdue(anchor, None, done=True, now=NOW) is False, "done not overdue")
    future = datetime(2026, 10, 20, 9, 0)
    ok(eng.is_overdue(future, None, now=NOW) is False, "future not overdue")


def test_snooze():
    due = datetime(2026, 10, 13, 9, 0)
    ok(eng.snooze(due, "10 min", now=NOW) == datetime(2026, 10, 13, 10, 10), "10 min")
    ok(eng.snooze(due, "১৫ মিনিট", now=NOW) == datetime(2026, 10, 13, 10, 15), "bn 15 min")
    ok(eng.snooze(due, "আধা ঘণ্টা", now=NOW) == datetime(2026, 10, 13, 10, 30), "half hour bn")
    ok(eng.snooze(due, "1 hour", now=NOW) == datetime(2026, 10, 13, 11, 0), "1 hour")
    t = eng.snooze(due, "tomorrow morning", now=NOW)
    ok(t == datetime(2026, 10, 14, 8, 0), "tomorrow morning -> 8am")
    t = eng.snooze(due, "আগামীকাল", now=NOW)
    ok(t.date() == date(2026, 10, 14), "bn tomorrow")
    t = eng.snooze(due, "next week", now=NOW)
    ok(t.date() == date(2026, 10, 20), "next week")
    ok(eng.snooze(due, "gibberish xyz", now=NOW) is None, "unparseable -> None")


def test_memory_search():
    items = [
        {"title": "আম্মুর ওষুধ", "detail": "Napa সকালে", "category": "স্বাস্থ্য"},
        {"title": "Wifi password", "detail": "home router is abc123", "category": "tech"},
        {"title": "গাড়ির নম্বর", "detail": "ঢাকা মেট্রো গ ১২৩৪", "category": "গাড়ি"},
        {"title": "Doctor appointment", "detail": "Dr Rahman, Square", "category": "health"},
    ]
    res = eng.search_memory("আম্মুর ওষুধ সম্পর্কে কী বলেছিলাম?", items)
    ok(res[0]["title"] == "আম্মুর ওষুধ", "memory top hit by title")
    ok(res[0]["_score"] > 0, "scored")

    res = eng.search_memory("what is the wifi password", items)
    ok(res[0]["title"] == "Wifi password", "english memory hit")

    res = eng.search_memory("doctor", items)
    ok(any(r["title"] == "Doctor appointment" for r in res), "partial word doctor")

    res = eng.search_memory("completely unrelated zzz", items)
    ok(res == [], "no match -> empty")

    q = eng.extract_memory_query("আমি তোমাকে গাড়ির নম্বর নিয়ে কী বলেছিলাম?")
    ok("গাড়ির" in q and "নম্বর" in q, "query extraction strips framing: %r" % q)


def test_last_occurrence():
    rule = {"freq": "daily", "interval": 1, "weekday": None,
            "day_of_month": None, "month": None, "time": "08:00"}
    anchor = datetime(2026, 10, 1, 8, 0)
    last = eng.last_occurrence(anchor, rule, at=NOW)  # NOW 13 Oct 10:00
    ok(last == datetime(2026, 10, 13, 8, 0), "last daily occ today 8am")


def test_golden():
    """Load reminders_golden.json and assert parse() matches every case.

    This SAME json is also asserted by a Dart test against reminders_nlp.dart
    (see note in the integrator report), so the Python engine and its Dart
    mirror cannot silently drift apart.
    """
    import json
    path = os.path.join(_HERE, "reminders_golden.json")
    if not os.path.exists(path):
        return  # golden file optional; skip cleanly if absent
    with open(path, encoding="utf-8") as f:
        cases = json.load(f)
    ok(len(cases) > 0, "golden file has cases")
    for case in cases:
        text = case["input"]
        now = datetime.fromisoformat(case["now"])
        exp = case["expected"]
        if case.get("mode") == "expense":
            got = nlp.expense_date(text, now=now).isoformat()
            ok(got == exp["expense_date"],
               "golden expense_date %r: got %r want %r" % (text, got, exp["expense_date"]))
            continue
        r = parse(text, now=now)
        for k in ("past", "needs_time"):
            if k in exp:
                ok(r[k] == exp[k], "golden %s %r: got %r want %r" % (k, text, r[k], exp[k]))
        ok(r["datetime"] == exp["datetime"],
           "golden datetime %r: got %r want %r" % (text, r["datetime"], exp["datetime"]))
        ok(r["recurrence_rule"] == exp["recurrence_rule"],
           "golden recurrence %r: got %r want %r"
           % (text, r["recurrence_rule"], exp["recurrence_rule"]))
        ok(r["clean_title"] == exp["clean_title"],
           "golden clean_title %r: got %r want %r"
           % (text, r["clean_title"], exp["clean_title"]))


def test_clean_title_connectors():
    # P2: dangling leading/trailing connectors stripped after date removal.
    ok(parse("pay bill on 25/12", now=NOW)["clean_title"] == "pay bill",
       "on-connector stripped")
    ok(parse("call mom at 5pm", now=NOW)["clean_title"] == "call mom",
       "at-connector stripped")
    r = parse("২৫ তারিখে বিল দাও", now=NOW)
    ok("তারিখ" not in r["clean_title"], "bn date-word stripped: %r" % r["clean_title"])


def test_month_name_and_this_month():
    # P2: month-name parsing + "এই মাসের N তারিখ"
    r = parse("25 December trip", now=NOW)
    ok(di(r["datetime"]).month == 12 and di(r["datetime"]).day == 25, "25 December")
    r = parse("may 5 picnic", now=NOW)
    ok(di(r["datetime"]).month == 5 and di(r["datetime"]).day == 5, "may 5")
    r = parse("এই মাসের ২০ তারিখ পেমেন্ট", now=NOW)
    ok(di(r["datetime"]).date() == date(2026, 10, 20), "this month day 20")


def test_snooze_day_after():
    # P1: পরশু (day-after) must be +2 days, not grouped into tonight.
    due = datetime(2026, 10, 13, 9, 0)
    t = eng.snooze(due, "পরশু", now=NOW)
    ok(t.date() == date(2026, 10, 15), "পরশু snooze -> +2 days")
    t = eng.snooze(due, "day after tomorrow", now=NOW)
    ok(t.date() == date(2026, 10, 15), "day after tomorrow snooze -> +2")


def test_interval_monthly_yearly():
    # every-2-months / every-3-years respect interval in next_occurrence.
    rule = {"freq": "monthly", "interval": 2, "weekday": None,
            "day_of_month": 10, "month": None, "time": "09:00"}
    anchor = datetime(2026, 1, 10, 9, 0)
    nxt = eng.next_occurrence(anchor, rule, after=datetime(2026, 2, 1, 0, 0))
    ok(nxt == datetime(2026, 3, 10, 9, 0), "every 2 months skips Feb: %r" % nxt)
    rule = {"freq": "yearly", "interval": 3, "weekday": None,
            "day_of_month": 1, "month": 1, "time": "09:00"}
    anchor = datetime(2026, 1, 1, 9, 0)
    nxt = eng.next_occurrence(anchor, rule, after=datetime(2026, 6, 1, 0, 0))
    ok(nxt == datetime(2029, 1, 1, 9, 0), "every 3 years: %r" % nxt)


# ================================================= pre-launch Bangla fixes
def test_today_no_time_never_past():
    # NOW 10:00, default 09:00 already gone -> next full hour, still today
    r = parse("আজকে রিপোর্ট জমা", now=NOW)
    ok(di(r["datetime"]) == datetime(2026, 10, 13, 11, 0), "আজকে -> 11:00 (next hour)")
    ok(di(r["datetime"]) > NOW, "never in the past")
    r = parse("আজকে রিপোর্ট জমা", now=datetime(2026, 10, 13, 10, 20))
    ok(di(r["datetime"]) == datetime(2026, 10, 13, 11, 0), "10:20 -> 11:00")
    r = parse("today submit report", now=datetime(2026, 10, 13, 7, 0))
    ok(di(r["datetime"]).hour == 9, "before 09:00 keeps default 09:00")
    r = parse("আজ রিপোর্ট", now=datetime(2026, 10, 13, 23, 20))
    ok(r["needs_time"] is True and di(r["datetime"]) > datetime(2026, 10, 13, 23, 20),
       "late night -> 23:59 + needs_time")
    r = parse("আজ সকালে হাঁটা", now=NOW)
    ok(di(r["datetime"]).hour == 8, "explicit day-part keeps its hour")


def test_kal_past_vs_future():
    y, t = date(2026, 10, 12), date(2026, 10, 14)
    for s in ["কাল ৫০০ টাকা খরচ করেছি", "গতকাল", "কাল গিয়েছিলাম", "কাল বাজারে গেলাম",
              "কালকে চাল কিনলাম", "কাল ছুটি ছিল", "কাল ও এসেছিল", "kal 500 taka khoroch korechi",
              "kal gelam", "kalke kinlam", "gotokal bazar", "yesterday lunch",
              "কাল ধার দিছি"]:
        ok(di(parse(s, now=NOW)["datetime"]).date() == y, "past -> yesterday: " + s)
        ok(parse(s, now=NOW)["past"] is True, "past flag: " + s)
    for s in ["কাল সকালে মিটিং", "কাল মনে করিয়ে দিও", "কাল মিটিং আছে", "কাল যাচ্ছি",
              "কাল বাজার করব", "আগামীকাল", "kal office jabo", "tomorrow",
              "কাল যা কিনেছি তার হিসাব মনে করিয়ে দিও"]:
        ok(di(parse(s, now=NOW)["datetime"]).date() == t, "future/neutral -> tomorrow: " + s)
        ok(parse(s, now=NOW)["past"] is False, "not past: " + s)
    ok(di(parse("পরশু গিয়েছিলাম", now=NOW)["datetime"]).date() == date(2026, 10, 11), "পরশু past -2")
    ok(di(parse("পরশু মিটিং", now=NOW)["datetime"]).date() == date(2026, 10, 15), "পরশু +2")
    ok(di(parse("৩ দিন আগে বিল দিয়েছি", now=NOW)["datetime"]).date() == date(2026, 10, 10), "৩ দিন আগে")
    ok(di(parse("2 days ago paid", now=NOW)["datetime"]).date() == date(2026, 10, 11), "2 days ago")
    ok(di(parse("শুক্রবার গিয়েছিলাম", now=NOW)["datetime"]).date() == date(2026, 10, 9),
       "past weekday -> last Friday")


def test_kal_not_inside_other_words():
    # regression: সকাল/বিকাল contain কাল but are NOT "tomorrow"
    ok(di(parse("বিকাল ৫টা চা", now=NOW)["datetime"]) == datetime(2026, 10, 13, 17, 0), "বিকাল today")
    ok(di(parse("সকাল ১১টা মিটিং", now=NOW)["datetime"]) == datetime(2026, 10, 13, 11, 0), "সকাল ১১টা today")
    ok(parse("আজকাল খুব ব্যস্ত", now=NOW)["datetime"] is None, "আজকাল is not a date")


def test_past_tense_helper():
    for s in ["করেছি", "গিয়েছিলাম", "কিনলাম", "গেল", "হয়েছে", "korechi", "gelam", "khaisi", "ছিল"]:
        ok(nlp.is_past_tense(s), "past: " + s)
    for s in ["আছি", "আছে", "করছি", "যাচ্ছি", "সকাল", "চাল তেল", "সালাম", "করব", "মনে করিয়ে দিও করেছি"]:
        ok(not nlp.is_past_tense(s), "not past: " + s)


def test_time_words():
    def hm(s, now=NOW):
        d = di(parse(s, now=now)["datetime"])
        return (d.hour, d.minute)
    ok(hm("বিকাল সাড়ে পাঁচটা চা") == (17, 30), "সাড়ে পাঁচটা বিকাল")
    ok(hm("সাড়ে ৫টায় মিটিং") == (5, 30), "সাড়ে ৫টায়")
    ok(hm("পৌনে ১০টায় ক্লাস") == (9, 45), "পৌনে ১০টা -> 9:45")
    ok(hm("পৌনে একটা দুপুরে") == (12, 45), "পৌনে একটা দুপুর -> 12:45")
    ok(hm("সকাল সোয়া আটটা নাস্তা") == (8, 15), "সোয়া আটটা")
    ok(hm("দেড়টায় লাঞ্চ") == (13, 30), "দেড়টা -> 13:30")
    ok(hm("আড়াইটায় মিটিং") == (14, 30), "আড়াইটা -> 14:30")
    ok(hm("রাত দেড়টা ওষুধ") == (1, 30), "রাত দেড়টা -> 01:30")
    ok(hm("রাত সাড়ে ৯টা খবর") == (21, 30), "রাত সাড়ে ৯টা")
    ok(hm("সকাল সাতটা হাঁটা") == (7, 0), "number word with day-part")
    ok(hm("পাঁচটায় মিটিং") == (5, 0), "number word + টায়")
    # money amounts are NOT times
    ok(parse("সাড়ে পাঁচ হাজার টাকা", now=NOW)["datetime"] is None, "amount untouched")
    ok(parse("একটা আপেল", now=NOW)["datetime"] is None, "একটা is 'a', not 1 o'clock")
    ok(parse("৫০ টাকা খরচ", now=NOW)["datetime"] is None, "৫০ টাকা is money, not 50 o'clock")
    ok(parse("৫০টা ডিম", now=NOW)["datetime"] is None, "৫০টা is a count")
    # snooze: বিকালে must not mean tomorrow
    t = eng.snooze(datetime(2026, 10, 13, 9, 0), "বিকালে", now=NOW)
    ok(t.date() == date(2026, 10, 13) and t.hour == 16, "snooze বিকালে -> today 16:00: %r" % t)


def test_number_words_and_month_end():
    ok(di(parse("পাঁচ তারিখ বিল", now=NOW)["datetime"]).date() == date(2026, 11, 5), "পাঁচ তারিখ")
    ok(di(parse("তিন দিন পর পরীক্ষা", now=NOW)["datetime"]).date() == date(2026, 10, 16), "তিন দিন পর")
    ok(di(parse("দুই সপ্তাহ পর", now=NOW)["datetime"]).date() == date(2026, 10, 27), "দুই সপ্তাহ পর")
    r = parse("প্রতি মাসের পাঁচ তারিখ ভাড়া", now=NOW)
    ok(r["recurrence_rule"]["day_of_month"] == 5, "monthly with number word")
    r = parse("প্রতি মাসের ৫ তারিখ বাড়ি ভাড়া", now=NOW)
    ok(r["recurrence_rule"]["freq"] == "monthly" and r["recurrence_rule"]["day_of_month"] == 5,
       "regression monthly digits")
    ok(di(parse("মাসের শেষে বেতন", now=NOW)["datetime"]).date() == date(2026, 10, 31), "month end")
    ok(di(parse("end of the month report", now=NOW)["datetime"]).date() == date(2026, 10, 31), "eom en")
    r = parse("মাসের শেষে বেতন", now=datetime(2026, 10, 31, 23, 30))
    ok(di(r["datetime"]).date() == date(2026, 11, 30), "month end passed -> next month end")
    r = parse("প্রতি মাসের শেষে বিল", now=NOW)
    ok(r["recurrence_rule"]["freq"] == "monthly" and r["recurrence_rule"]["day_of_month"] == 31,
       "every month end -> monthly dom 31")


def test_expense_date():
    ed = lambda s: nlp.expense_date(s, now=NOW)
    ok(ed("কাল ৫০০ টাকা খরচ") == date(2026, 10, 12), "expense bare কাল -> yesterday")
    ok(ed("কাল ৫০০ টাকা খরচ করেছি") == date(2026, 10, 12), "expense past কাল")
    ok(ed("৫০০ টাকা চা") == date(2026, 10, 13), "no date -> today")
    ok(ed("পরশু ২০০ টাকা রিকশা") == date(2026, 10, 11), "expense পরশু -> -2")
    ok(ed("আগামীকাল ১০০ টাকা") == date(2026, 10, 13), "never in the future")
    ok(ed("২০ তারিখ ভাড়া ৫০০০") == date(2026, 9, 20), "N তারিখ ahead -> last month")
    ok(ed("শুক্রবার বাজার ৮০০") == date(2026, 10, 9), "weekday -> last one")
    ok(nlp.day_offset("কাল সকাল ৮টা") == 1 and nlp.day_offset("সকাল ৮টা") is None
       and nlp.day_offset("গতকাল") == -1, "day_offset helper")


def run():
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
    print("ALL PASS — %d assertions across %d tests" % (_count, len(tests)))
    return _count


if __name__ == "__main__":
    run()
