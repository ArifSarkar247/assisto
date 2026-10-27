"""
Seeded generator for the RULE-feature eval sets (owner order G).

    cd backend && python -m core.ai_evals.build_rules

Writes core/ai_evals/<feature>.jsonl for the 10 rule features. Expected values
are the SEMANTIC truth computed here (what a correct parser must answer for a
fixed clock: Tuesday 2026-10-27 10:00, Asia/Dhaka) — never copied from running
the parser. Phrasing mixes Bangla script, Banglish and English the way
Bangladeshi users write; names are test names (রহিম/করিম/Rahim/Karim), phone
numbers are obvious test numbers (0171100000x).

Known gaps (a real parser limitation we have not fixed yet) are listed in
KNOWN_GAPS by case text; the CI threshold says they may not grow.
"""
import json
import os
import random
from datetime import date, datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
NOW = datetime(2026, 10, 27, 10, 0)          # a Tuesday
NOW_S = "2026-10-27T10:00"
TODAY = NOW.date()
_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn(x):
    return str(x).translate(_BN)


def d_iso(d):
    return d.isoformat()


def next_wd(wd):
    """Next occurrence of weekday wd strictly after today."""
    k = (wd - TODAY.weekday()) % 7 or 7
    return TODAY + timedelta(days=k)


# ------------------------------------------------------------------ writer
def finish(fid, rows, rng, target=(0.40, 0.25, 0.30), minimum=210):
    """Balance languages (bn / banglish / en / mixed), number ids, write."""
    by = {}
    for r in rows:
        by.setdefault(r["lang"], []).append(r)
    for v in by.values():
        rng.shuffle(v)
    out = []
    total = max(minimum, min(len(rows), 240))
    quota = {"bn": int(total * target[0]), "banglish": int(total * target[1]),
             "en": int(total * target[2])}
    for lang, q in quota.items():
        out += by.get(lang, [])[:q]
    rest = [r for r in rows if r not in out]
    rng.shuffle(rest)
    # mixed first, then whatever is left, until total
    rest.sort(key=lambda r: r["lang"] != "mixed")
    out += rest[: max(0, total - len(out))]
    seen, uniq = set(), []
    for r in out:
        key = json.dumps(r["input"], ensure_ascii=False, sort_keys=True)
        if key in seen:
            continue
        seen.add(key)
        uniq.append(r)
    if len(uniq) < minimum:
        raise SystemExit("%s: only %d unique cases" % (fid, len(uniq)))
    path = os.path.join(HERE, fid + ".jsonl")
    with open(path, "w", encoding="utf-8") as f:
        for i, r in enumerate(uniq, 1):
            row = {"id": "%s-%04d" % (fid, i), "lang": r["lang"], "input": r["input"],
                   "expect": r["expect"], "tags": r.get("tags", [])}
            gap = r.get("known_gap") or KNOWN_GAPS.get(fid, {}).get(_gap_key(r["input"]))
            if gap:
                row["known_gap"] = gap
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return len(uniq)


def _gap_key(inp):
    return inp.get("text") or inp.get("body") or ""


# filled after the first honest run: {feature: {case text: reason}}
KNOWN_GAPS = {}


def case(lang, inp, expect, *tags):
    return {"lang": lang, "input": inp, "expect": expect, "tags": list(tags)}


# ================================================================== reminders
TASKS_BN = ["বিদ্যুৎ বিল দিতে", "আম্মুকে ফোন করতে", "ওষুধ খেতে", "গ্যাস বিল জমা দিতে",
            "রহিমের সাথে মিটিং", "বাসা ভাড়া দিতে", "ডাক্তার দেখাতে", "স্কুলের ফি দিতে",
            "করিম ভাইকে টাকা ফেরত দিতে", "বাজার করতে"]
TASKS_BL = ["bill dite", "ammu ke call dite", "oshudh khete", "meeting e jete",
            "bhara dite", "doctor er kache jete", "Karim bhai ke taka dite", "bazar korte"]
TASKS_EN = ["pay the electricity bill", "call mom", "take medicine", "meeting with Rahim",
            "pay rent", "doctor appointment", "submit the report", "pick up Karim"]
KEY = {  # a word the clean title must keep
    **{t: t.split()[0] for t in TASKS_BN}, **{t: t.split()[0] for t in TASKS_BL},
    **{t: t.split()[-1] for t in TASKS_EN},
}
TRIG_BN = ["মনে করিয়ে দিও", "মনে করিয়ে দাও", "রিমাইন্ডার দাও", ""]
TRIG_BL = ["mone koriye dio", "reminder dao", ""]

# (bangla phrase, banglish phrase, english phrase, hour, minute)
TIMES = [
    ("সকাল {h}টায়", "sokal {h}tay", "at {h}am", None, "am"),
    ("দুপুর {h}টায়", "dupur {h}tay", "at {h}pm", None, "noon"),
    ("বিকেল {h}টায়", "bikel {h}tay", "at {h}pm", None, "pm"),
    ("সন্ধ্যা {h}টায়", "sondha {h}tay", "at {h}pm", None, "pm"),
    ("রাত {h}টায়", "raat {h}tay", "at {h}pm", None, "night"),
]
HOURS = {"am": [6, 7, 8, 9, 10, 11], "noon": [1, 2, 3], "pm": [4, 5, 6, 7], "night": [8, 9, 10, 11]}


def to24(kind, h):
    if kind == "am":
        return h
    return h + 12 if h < 12 else h


DAYS = [
    # (bn, banglish, en, date)
    ("কাল", "kal", "tomorrow", TODAY + timedelta(days=1)),
    ("আগামীকাল", "kalke", "tomorrow", TODAY + timedelta(days=1)),
    ("পরশু", None, "day after tomorrow", TODAY + timedelta(days=2)),
    ("শুক্রবার", "shukrobar", "on Friday", next_wd(4)),
    ("শনিবার", "shonibar", "on Saturday", next_wd(5)),
    ("রবিবার", "robibar", "on Sunday", next_wd(6)),
    ("সোমবার", "shombar", "on Monday", next_wd(0)),
    ("বুধবার", "budhbar", "on Wednesday", next_wd(2)),
    ("বৃহস্পতিবার", None, "on Thursday", next_wd(3)),
    ("৩ দিন পর", None, "in 3 days", TODAY + timedelta(days=3)),
    ("৫ দিন পর", None, "in 5 days", TODAY + timedelta(days=5)),
    ("আগামী মাসের ৫ তারিখ", None, "next month on the 5th", date(2026, 11, 5)),
    ("১৫ নভেম্বর", None, "15 November", date(2026, 11, 15)),
    ("২০/১১", None, "20/11", date(2026, 11, 20)),
]


def build_reminders(rng):
    rows = []
    for dbn, dbl, den, dd in DAYS:
        for tbn, tbl, ten, _x, kind in TIMES:
            for h in HOURS[kind][:3]:
                hh = to24(kind, h)
                when = "%sT%02d:00:00" % (d_iso(dd), hh)
                task = rng.choice(TASKS_BN)
                trig = rng.choice(TRIG_BN)
                t = " ".join(x for x in [dbn, tbn.format(h=bn(h)), task, trig] if x)
                rows.append(case("bn", {"text": t, "now": NOW_S},
                                 {"datetime": when, "freq": None,
                                  "title": task}, "oneoff"))
                if dbl:
                    task = rng.choice(TASKS_BL)
                    t = " ".join(x for x in [dbl, tbl.format(h=h), task, rng.choice(TRIG_BL)] if x)
                    rows.append(case("banglish", {"text": t, "now": NOW_S},
                                     {"datetime": when, "freq": None}, "oneoff"))
                task = rng.choice(TASKS_EN)
                t = rng.choice(["remind me to {t} {d} {w}", "{t} {d} {w}",
                                "set a reminder to {t} {d} {w}"]).format(
                    t=task, d=den, w=ten.format(h=h))
                rows.append(case("en", {"text": t, "now": NOW_S},
                                 {"datetime": when, "freq": None,
                                  "title__contains": KEY[task]}, "oneoff"))
        # date only -> 09:00 default
        task = rng.choice(TASKS_BN)
        rows.append(case("bn", {"text": "%s %s" % (dbn, task), "now": NOW_S},
                         {"datetime": "%sT09:00:00" % d_iso(dd), "date_only": True,
                          "title__contains": KEY[task]}, "date_only"))
        task = rng.choice(TASKS_EN)
        rows.append(case("en", {"text": "%s %s" % (task, den), "now": NOW_S},
                         {"datetime": "%sT09:00:00" % d_iso(dd), "date_only": True},
                         "date_only"))
    # recurrence
    for wbn, wbl, wen, wd in [("শুক্রবার", "shukrobar", "friday", 4), ("সোমবার", "shombar", "monday", 0),
                              ("রবিবার", "robibar", "sunday", 6), ("বুধবার", "budhbar", "wednesday", 2),
                              ("শনিবার", "shonibar", "saturday", 5)]:
        for h in (7, 8, 9):
            task = rng.choice(TASKS_BN)
            rows.append(case("bn", {"text": "প্রতি %s সকাল %sটায় %s" % (wbn, bn(h), task), "now": NOW_S},
                             {"freq": "weekly", "weekday": wd, "rule_time": "%02d:00" % h,
                              "title": task}, "weekly"))
            rows.append(case("en", {"text": "every %s at %dam %s" % (wen, h, rng.choice(TASKS_EN)),
                                    "now": NOW_S},
                             {"freq": "weekly", "weekday": wd, "rule_time": "%02d:00" % h}, "weekly"))
    for h in (7, 8, 9, 10):
        for task in rng.sample(TASKS_BN, 3):
            rows.append(case("bn", {"text": "প্রতিদিন সকাল %sটায় %s" % (bn(h), task), "now": NOW_S},
                             {"freq": "daily", "rule_time": "%02d:00" % h,
                              "title": task}, "daily"))
        rows.append(case("en", {"text": "daily at %dam %s" % (h, rng.choice(TASKS_EN)), "now": NOW_S},
                         {"freq": "daily", "rule_time": "%02d:00" % h}, "daily"))
        rows.append(case("banglish", {"text": "protidin sokal %dtay %s" % (h, rng.choice(TASKS_BL)),
                                      "now": NOW_S},
                         {"freq": "daily", "rule_time": "%02d:00" % h}, "daily"))
    for dom in (1, 5, 10, 15, 25):
        rows.append(case("bn", {"text": "প্রতি মাসের %s তারিখে বাসা ভাড়া দিতে মনে করিয়ে দিও" % bn(dom),
                                "now": NOW_S},
                         {"freq": "monthly", "day_of_month": dom, "title__contains": "ভাড়া"},
                         "monthly"))
        rows.append(case("en", {"text": "every month on the %d pay the internet bill" % dom,
                                "now": NOW_S},
                         {"freq": "monthly", "day_of_month": dom}, "monthly"))
    # "next / আগামী <weekday>" — the qualifier must not stay in the title.
    # KNOWN GAP: the parser keeps "next"/"আগামী" in the title, and the shared
    # Python<->Dart golden (reminders_golden.json: "next meeting") locks that
    # behaviour — fixing it needs the Dart mirror + golden changed together.
    gap_next = "title keeps 'next'/'আগামী' (Dart golden parity; fix both parsers together)"
    for wbn, wen, wd in [("শুক্রবার", "friday", 4), ("সোমবার", "monday", 0), ("রবিবার", "sunday", 6),
                         ("শনিবার", "saturday", 5), ("বৃহস্পতিবার", "thursday", 3)]:
        for task in rng.sample(TASKS_BN[:5], 2):
            rows.append(case("bn", {"text": "আগামী %s বিকেল ৫টায় %s" % (wbn, task), "now": NOW_S},
                             {"datetime": "%sT17:00:00" % d_iso(next_wd(wd)), "title": task}, "next_wd"))
            rows[-1]["known_gap"] = gap_next
        for task in ("meeting", "pay rent", "call Karim"):
            rows.append(case("en", {"text": "next %s 5pm %s" % (wen, task), "now": NOW_S},
                             {"datetime": "%sT17:00:00" % d_iso(next_wd(wd)), "title": task}, "next_wd"))
            rows[-1]["known_gap"] = gap_next
    # expense / past dates (prefer_past mode)
    past = [("গতকাল চা খেতে ৫০ টাকা খরচ করেছি", "2026-10-26"),
            ("কাল বাজারে ৫০০ টাকা খরচ করেছি", "2026-10-26"),
            ("পরশু রিকশা ভাড়া ৮০ টাকা দিলাম", "2026-10-25"),
            ("আজ দুপুরে ভাত খেতে ১২০ টাকা", "2026-10-27"),
            ("yesterday spent 300 on groceries", "2026-10-26"),
            ("kal 200 taka khoroch korechi", "2026-10-26"),
            ("gotokal bazar 700 taka", "2026-10-26"),
            ("৩ দিন আগে ওষুধ কিনলাম ৪৫০ টাকা", "2026-10-24"),
            ("2 days ago paid 1500 for electricity", "2026-10-25"),
            ("শুক্রবার জুতা কিনলাম ২০০০ টাকা", "2026-10-23"),
            ("রবিবার ৩০০ টাকার মাছ কিনেছি", "2026-10-25"),
            ("bought medicine 250 today", "2026-10-27"),
            ("চা ২০ টাকা", "2026-10-27"),
            ("১০ তারিখে বিদ্যুৎ বিল দিলাম ১২০০", "2026-10-10")]
    for t, d in past:
        lang = "en" if t[0].isascii() and t.split()[0] in ("yesterday", "2", "bought") else (
            "banglish" if t[0].isascii() else "bn")
        rows.append(case(lang, {"text": t, "now": NOW_S, "mode": "expense"},
                         {"expense_date": d}, "past"))
    # Bangla digits + mixed
    for dbn, _bl, den, dd in DAYS[:6]:
        rows.append(case("mixed", {"text": "%s at 5pm meeting with Rahim" % dbn, "now": NOW_S},
                         {"datetime": "%sT17:00:00" % d_iso(dd)}, "mixed"))
        rows.append(case("mixed", {"text": "%s সন্ধ্যা ৭টায় call Karim" % dbn, "now": NOW_S},
                         {"datetime": "%sT19:00:00" % d_iso(dd)}, "mixed"))
    return rows


# ================================================================== home intent
ITEMS_BN = ["চা", "রিকশা ভাড়া", "বাজার", "দুপুরের খাবার", "মোবাইল রিচার্জ", "ওষুধ", "সিএনজি ভাড়া", "ডিম"]
ITEMS_EN = ["lunch", "groceries", "rickshaw", "medicine", "mobile recharge", "taxi", "coffee"]
NAMES = [("রহিম", "Rahim"), ("করিম", "Karim"), ("সালমা", "Salma"), ("জামাল", "Jamal"), ("নাসরিন", "Nasrin")]
AMTS = [20, 50, 120, 250, 500, 800, 1200, 1500, 2500, 5000]


def build_home_intent(rng):
    rows = []
    for a in AMTS:
        for it in rng.sample(ITEMS_BN, 3):
            rows.append(case("bn", {"text": "%s %s টাকা খরচ" % (it, bn(a))},
                             {"intent": "expense", "amount": str(a)}, "expense"))
        rows.append(case("bn", {"text": "%s কিনলাম %s টাকায়" % (rng.choice(ITEMS_BN), bn(a))},
                         {"intent": "expense", "amount": str(a)}, "expense"))
        rows.append(case("en", {"text": "spent %d on %s" % (a, rng.choice(ITEMS_EN))},
                         {"intent": "expense", "amount": str(a)}, "expense"))
        rows.append(case("en", {"text": "paid %d taka for %s" % (a, rng.choice(ITEMS_EN))},
                         {"intent": "expense", "amount": str(a)}, "expense"))
        rows.append(case("banglish", {"text": "%s %d taka" % (rng.choice(["cha", "rickshaw", "bazar", "lunch"]), a)},
                         {"intent": "expense", "amount": str(a)}, "expense"))
    for a in (5000, 12000, 25000, 30000, 45000):
        rows.append(case("bn", {"text": "বেতন পেলাম %s টাকা" % bn(a)},
                         {"intent": "income", "amount": str(a)}, "income"))
        rows.append(case("en", {"text": "got salary %d" % a},
                         {"intent": "income", "amount": str(a)}, "income"))
        rows.append(case("en", {"text": "received %d from tuition" % a},
                         {"intent": "income", "amount": str(a)}, "income"))
        rows.append(case("banglish", {"text": "salary pelam %d" % a},
                         {"intent": "income", "amount": str(a)}, "income"))
    for nb, ne in NAMES:
        for a in (300, 500, 1000, 2000):
            rows.append(case("bn", {"text": "%sকে %s টাকা ধার দিলাম" % (nb, bn(a))},
                             {"intent": "loan", "kind": "given", "amount": str(a), "person": nb}, "loan"))
            rows.append(case("bn", {"text": "%sর কাছ থেকে %s টাকা ধার নিলাম" % (nb, bn(a))},
                             {"intent": "loan", "kind": "taken", "amount": str(a)}, "loan"))
            rows.append(case("en", {"text": "lent %d to %s" % (a, ne)},
                             {"intent": "loan", "kind": "given", "amount": str(a)}, "loan"))
            rows.append(case("en", {"text": "borrowed %d from %s" % (a, ne)},
                             {"intent": "loan", "kind": "taken", "amount": str(a)}, "loan"))
        rows.append(case("bn", {"text": "%sকে কল দাও" % nb}, {"intent": "call", "name": nb}, "call"))
        rows.append(case("bn", {"text": "%s কে ফোন করো" % nb}, {"intent": "call", "name": nb}, "call"))
        rows.append(case("en", {"text": "call %s" % ne}, {"intent": "call", "name": ne}, "call"))
        rows.append(case("banglish", {"text": "%s ke call dao" % ne},
                         {"intent": "call", "name__contains": ne}, "call"))
    for h, kind in ((8, "am"), (9, "am"), (5, "pm"), (7, "pm"), (10, "night")):
        hh = to24(kind, h)
        part = {"am": "সকাল", "pm": "বিকেল" if h < 6 else "সন্ধ্যা", "night": "রাত"}[kind]
        for task in rng.sample(TASKS_BN[:6], 3):
            if "ওষুধ" in task:
                continue
            rows.append(case("bn", {"text": "কাল %s %sটায় %s মনে করিয়ে দিও" % (part, bn(h), task)},
                             {"intent": "reminder", "due_time": "%02d:00" % hh}, "reminder"))
        rows.append(case("en", {"text": "remind me to %s at %d:00" % (rng.choice(TASKS_EN[:2] + TASKS_EN[4:]), hh)},
                         {"intent": "reminder", "due_time": "%02d:00" % hh}, "reminder"))
        rows.append(case("bn", {"text": "%s %sটায় ওষুধ খাওয়ার কথা মনে করিয়ে দিও" % (part, bn(h))},
                         {"intent": "medicine", "due_time": "%02d:00" % hh}, "medicine"))
    for t in ["মনে রাখো আমার লকারের চাবি আলমারির উপরে", "মনে রেখো গাড়ির কাগজ ড্রয়ারে",
              "remember my passport is in the blue bag", "remember Rahim's shop is near Mirpur 10",
              "মনে রাখো ওয়াইফাই রাউটার স্টোর রুমে", "remember the spare key is with Karim"]:
        rows.append(case("en" if t.isascii() else "bn", {"text": t}, {"intent": "memory"}, "memory"))
    for place in ["গুলশান ১", "মিরপুর ১০", "ধানমন্ডি ২৭", "উত্তরা সেক্টর ৭", "বনানী"]:
        rows.append(case("bn", {"text": "%s রাস্তা দেখাও" % place}, {"intent": "navigate", "place": place}, "nav"))
    for place in ["Gulshan 1", "Mirpur 10", "Dhanmondi 27", "Banani", "Bashundhara City"]:
        rows.append(case("en", {"text": "navigate to %s" % place}, {"intent": "navigate", "place": place}, "nav"))
        rows.append(case("en", {"text": "directions to %s" % place}, {"intent": "navigate"}, "nav"))
    for t, pt in [("কাছের ফার্মেসি কোথায়", "pharmacy"), ("আশেপাশে হাসপাতাল", "hospital"),
                  ("কাছাকাছি এটিএম", "atm"), ("nearby restaurant", "restaurant"),
                  ("pharmacy near me", "pharmacy"), ("hospital nearby", "hospital"),
                  ("atm near me", "atm"), ("আশেপাশে রেস্টুরেন্ট", "restaurant"),
                  ("কাছে কোনো ক্লিনিক আছে", "hospital"), ("nearby hotel", "lodging")]:
        rows.append(case("en" if t.isascii() else "bn", {"text": t},
                         {"intent": "nearby", "place_type": pt}, "nearby"))
    for nb, ne in NAMES:
        for a in (400, 700, 1500):
            rows.append(case("banglish", {"text": "%s ke %d taka dhar dilam" % (ne, a)},
                             {"intent": "loan", "kind": "given", "amount": str(a)}, "loan"))
            rows.append(case("banglish", {"text": "%s er kach theke %d taka dhar nilam" % (ne, a)},
                             {"intent": "loan", "kind": "taken", "amount": str(a)}, "loan"))
    for a in (8000, 18000, 22000, 35000):
        rows.append(case("banglish", {"text": "beton pelam %d" % a},
                         {"intent": "income", "amount": str(a)}, "income"))
        rows.append(case("banglish", {"text": "tuition theke %d taka income holo" % a},
                         {"intent": "income", "amount": str(a)}, "income"))
    for a in (60, 150, 350, 900):
        rows.append(case("banglish", {"text": "%s e %d taka khoroch holo" % (rng.choice(["bazar", "nasta", "bus"]), a)},
                         {"intent": "expense", "amount": str(a)}, "expense"))
    for t, it in [("এই মাসে কত খরচ হলো", "query_money"), ("আমার ব্যালেন্স কত", "query_money"),
                  ("how much did I spend", "query_money"), ("show my balance", "query_money"),
                  ("আজ কী আছে", "query_today"), ("today's briefing", "query_today"),
                  ("আজকে কী কী আছে", "query_today"), ("koto taka ache amar", "query_money"),
                  ("balance koto", "query_money")]:
        lang = "bn" if not t.isascii() else ("banglish" if "koto" in t else "en")
        rows.append(case(lang, {"text": t}, {"intent": it}, "query"))
    return rows


# ================================================================== money voice
def build_expense_parse(rng):
    rows = []
    for a in AMTS:
        for it in rng.sample(ITEMS_BN, 4):
            rows.append(case("bn", {"text": "%s %s টাকা" % (it, bn(a))},
                             {"n": 1, "amount": str(a), "txn_type": "expense"}, "expense"))
        rows.append(case("bn", {"text": "%s %s টাকা খরচ হলো" % (rng.choice(ITEMS_BN), bn(a))},
                         {"amount": str(a), "txn_type": "expense"}, "expense"))
        rows.append(case("en", {"text": "spent %d on %s" % (a, rng.choice(ITEMS_EN))},
                         {"amount": str(a), "txn_type": "expense"}, "expense"))
        rows.append(case("en", {"text": "%s %d taka" % (rng.choice(ITEMS_EN), a)},
                         {"amount": str(a), "txn_type": "expense"}, "expense"))
        rows.append(case("banglish", {"text": "%s %d taka khoroch" % (rng.choice(["cha", "nasta", "bazar", "rickshaw vara"]), a)},
                         {"amount": str(a), "txn_type": "expense"}, "expense"))
    for a in (3000, 15000, 25000, 40000):
        rows.append(case("bn", {"text": "বেতন পেলাম %s টাকা" % bn(a)},
                         {"amount": str(a), "txn_type": "income"}, "income"))
        rows.append(case("en", {"text": "got paid %d for freelancing" % a},
                         {"amount": str(a), "txn_type": "income"}, "income"))
        rows.append(case("banglish", {"text": "tuition theke %d taka pelam" % a},
                         {"amount": str(a), "txn_type": "income"}, "income"))
    for nb, ne in NAMES:
        for a in (200, 500, 1000, 3000):
            rows.append(case("bn", {"text": "%sকে %s টাকা ধার দিলাম" % (nb, bn(a))},
                             {"amount": str(a), "txn_type": "due_in", "counterparty": nb}, "lent"))
            rows.append(case("banglish", {"text": "%s ke %d taka dhar dilam" % (ne, a)},
                             {"amount": str(a), "txn_type": "due_in", "counterparty": ne}, "lent"))
            rows.append(case("en", {"text": "lent %d to %s" % (a, ne)},
                             {"amount": str(a), "txn_type": "due_in", "counterparty": ne}, "lent"))
            rows.append(case("en", {"text": "borrowed %d from %s" % (a, ne)},
                             {"amount": str(a), "txn_type": "due_out", "counterparty": ne}, "borrowed"))
    for _ in range(30):
        k = rng.choice([2, 3])
        its = rng.sample(ITEMS_BN, k)
        amts = rng.sample(AMTS[:7], k)
        t = ", ".join("%s %s টাকা" % (i, bn(a)) for i, a in zip(its, amts))
        rows.append(case("bn", {"text": t}, {"n": k, "amounts": [str(a) for a in amts]}, "batch"))
        its = rng.sample(ITEMS_EN, k)
        t = " and ".join("%s %d" % (i, a) for i, a in zip(its, amts))
        rows.append(case("en", {"text": t}, {"n": k, "amounts": [str(a) for a in amts]}, "batch"))
    for a in (1500, 2500, 10000):
        rows.append(case("mixed", {"text": "Rahim ke ৳%s দিলাম bazar er jonno" % bn(a)},
                         {"amount": str(a)}, "mixed"))
        rows.append(case("mixed", {"text": "electricity bill %s টাকা দিলাম" % bn(a)},
                         {"amount": str(a), "txn_type": "expense"}, "mixed"))
    return rows


# ================================================================== money sms
def build_money_sms(rng):
    rows = []
    refs = ["9F2A1B3C", "AK7D9X2P", "BH3K8Q1M", "CJ5L2W9R", "DE4N6T8Y", "7XG2H5KQ"]
    for a, fee, bal in [(500, 0, 1512), (1000, 0, 2300), (2500, 0, 7120), (150, 0, 830),
                        (12000, 0, 15240), (75, 0, 312)]:
        r = rng.choice(refs)
        body = ("You have received Tk %s.00 from 01711000001. Fee Tk 0.00. Balance Tk %s.00. "
                "TrxID %s at 12/10/2026 10:11" % ("{:,}".format(a), "{:,}".format(bal), r))
        rows.append(case("en", {"body": body, "sender": "bKash"},
                         {"channel": "bkash", "type": "credit", "amount": "%d.00" % a if False else str(a),
                          "balance": str(bal), "ref": r, "counterparty_number": "01711000001",
                          "date": "2026-10-12", "parsed": True}, "bkash", "credit"))
    for a, fee, bal in [(1000, 18.5, 812), (2000, 37, 4210), (5000, 92.5, 120), (500, 9.25, 300)]:
        r = rng.choice(refs)
        body = ("Cash Out Tk %s.00 to 01811000002 successful. Fee Tk %s. Balance Tk %s.00. "
                "TrxID %s at 20/10/2026 18:40" % ("{:,}".format(a), ("%.2f" % fee), "{:,}".format(bal), r))
        rows.append(case("en", {"body": body, "sender": "bKash"},
                         {"channel": "bkash", "type": "debit", "amount": str(a),
                          "fee": ("%g" % fee), "balance": str(bal), "ref": r,
                          "date": "2026-10-20", "parsed": True}, "bkash", "cashout"))
    for a, bal in [(250, 812.33), (1200, 3200.5), (80, 45)]:
        r = rng.choice(refs)
        body = "Payment Tk %s.00 to DARAZ BD successful. Balance Tk %s. TrxID %s at 21/10/2026 12:00" % (
            "{:,}".format(a), ("%g" % bal), r)
        rows.append(case("en", {"body": body, "sender": "bKash"},
                         {"channel": "bkash", "type": "debit", "amount": str(a),
                          "balance": ("%g" % bal), "ref": r, "parsed": True}, "bkash", "payment"))
    for a, bal in [(1000, 1312), (3500, 4100), (200, 950), (7000, 7020)]:
        r = rng.choice(refs)
        body = "Money Received. Amount: Tk %s.00 Sender: 01911000003 Ref: N/A TxnID: %s Balance: Tk %s.00 22/10/2026 09:15" % (
            "{:,}".format(a), r, "{:,}".format(bal))
        rows.append(case("en", {"body": body, "sender": "NAGAD"},
                         {"channel": "nagad", "type": "credit", "amount": str(a),
                          "balance": str(bal), "ref": r, "parsed": True}, "nagad", "credit"))
        body = "Cash Out Tk %s.00 successful. Fee: Tk 0.00 TxnID: %s Balance: Tk %s.00" % (
            "{:,}".format(a), r, "{:,}".format(bal))
        rows.append(case("en", {"body": body, "sender": "NAGAD"},
                         {"channel": "nagad", "type": "debit", "amount": str(a),
                          "balance": str(bal), "ref": r, "parsed": True}, "nagad", "cashout"))
    for a, bal in [(500, 1234), (1500, 2050), (90, 410)]:
        r = rng.choice(refs)
        body = "Tk%s.0 received from A/C:01711000004 Fee:Tk0.0 Bal:Tk%s.0 TxnId:%s" % (a, "{:,}".format(bal), r)
        rows.append(case("en", {"body": body, "sender": "16216"},
                         {"type": "credit", "amount": str(a), "balance": str(bal), "ref": r,
                          "parsed": True}, "rocket"))
    for a, bal, d in [(2500, 48210, "2026-10-12"), (999.5, 15000, "2026-10-15"), (12000, 3000, "2026-10-01")]:
        body = "Your A/C ...1234 debited BDT %s at SHWAPNO on %s. Avl Bal BDT %s" % (
            "{:,.2f}".format(a), {"2026-10-12": "12-OCT-26", "2026-10-15": "15-OCT-26",
                                  "2026-10-01": "01-OCT-26"}[d], "{:,.2f}".format(bal))
        rows.append(case("en", {"body": body, "sender": "CITYBANK"},
                         {"channel": "bank", "type": "debit", "amount": "%g" % a,
                          "balance": str(bal), "date": d, "parsed": True}, "bank", "debit"))
        body = "Dear Customer, your A/C ...5678 credited BDT %s on %s (Salary). Avl Bal BDT %s" % (
            "{:,.2f}".format(a), {"2026-10-12": "12-OCT-26", "2026-10-15": "15-OCT-26",
                                  "2026-10-01": "01-OCT-26"}[d], "{:,.2f}".format(bal))
        rows.append(case("en", {"body": body, "sender": "DBBL"},
                         {"channel": "bank", "type": "credit", "amount": "%g" % a,
                          "date": d, "parsed": True}, "bank", "credit"))
    # Bangla-script SMS (bKash bn template) and Bangla digits
    for a, bal in [(500, 1500), (1200, 2200), (3000, 3500), (750, 900)]:
        r = rng.choice(refs)
        body = "আপনি ০১৭১১০০০০০৫ থেকে ৳%s প্রাপ্ত হয়েছেন। ফি ৳০। ব্যালেন্স ৳%s। TrxID %s" % (bn(a), bn(bal), r)
        rows.append(case("bn", {"body": body, "sender": "bKash"},
                         {"channel": "bkash", "amount": str(a), "balance": str(bal), "ref": r}, "bkash", "bn"))
        body = "ক্যাশ আউট ৳%s সফল হয়েছে। ফি ৳%s। ব্যালেন্স ৳%s। TrxID %s" % (bn(a), bn(int(a * 0.0185)), bn(bal), r)
        rows.append(case("bn", {"body": body, "sender": "bKash"},
                         {"channel": "bkash", "amount": str(a), "balance": str(bal), "ref": r}, "bkash", "bn"))
    # pad with varied amounts so every channel has dozens of rows
    seen = len(rows)
    i = 0
    while len(rows) < 240:
        i += 1
        a = rng.choice([100, 220, 450, 650, 1100, 1750, 2600, 3900, 4800, 6400, 8800, 15500])
        bal = a + rng.choice([12, 300, 1450, 9000])
        r = "T%02dQ%04dZ" % (i, a % 10000)
        kind = rng.choice(["bk_recv", "bk_send", "ng_recv", "rk_recv", "bank_db", "upay_recv", "bn_recv"])
        if kind == "bk_recv":
            body = "You have received Tk %s.00 from 0171100%04d. Fee Tk 0.00. Balance Tk %s.00. TrxID %s at 0%d/10/2026 1%d:05" % (
                "{:,}".format(a), i, "{:,}".format(bal), r, (i % 9) + 1, i % 10)
            ex = {"channel": "bkash", "type": "credit", "amount": str(a), "balance": str(bal), "ref": r,
                  "date": "2026-10-0%d" % ((i % 9) + 1)}
            lang = "en"
        elif kind == "bk_send":
            body = "Send Money Tk %s.00 to 0181100%04d successful. Ref rent. Fee Tk 5.00. Balance Tk %s.00. TrxID %s at 1%d/10/2026 20:10" % (
                "{:,}".format(a), i, "{:,}".format(bal), r, i % 10)
            ex = {"channel": "bkash", "type": "debit", "amount": str(a), "fee": "5", "balance": str(bal),
                  "ref": r}
            lang = "en"
        elif kind == "ng_recv":
            body = "Money Received. Amount: Tk %s.00 Sender: 0191100%04d TxnID: %s Balance: Tk %s.00" % (
                "{:,}".format(a), i, r, "{:,}".format(bal))
            ex = {"channel": "nagad", "type": "credit", "amount": str(a), "balance": str(bal), "ref": r}
            lang = "en"
        elif kind == "rk_recv":
            body = "Tk%s.0 received from A/C:0171100%04d Fee:Tk0.0 Bal:Tk%s.0 TxnId:%s" % (a, i, "{:,}".format(bal), r)
            ex = {"type": "credit", "amount": str(a), "balance": str(bal), "ref": r}
            lang = "en"
        elif kind == "upay_recv":
            body = "Upay: You have received Tk %s.00 from 0161100%04d. Balance Tk %s.00. TrxID %s" % (
                "{:,}".format(a), i, "{:,}".format(bal), r)
            ex = {"channel": "upay", "type": "credit", "amount": str(a), "balance": str(bal), "ref": r}
            lang = "en"
        elif kind == "bn_recv":
            body = "আপনি ০১৭১১০০%s থেকে ৳%s প্রাপ্ত হয়েছেন। ব্যালেন্স ৳%s। TrxID %s" % (bn("%04d" % i), bn(a), bn(bal), r)
            ex = {"channel": "bkash", "amount": str(a), "balance": str(bal), "ref": r}
            lang = "bn"
        else:
            body = "Your A/C ...4321 debited BDT %s at UTTARA PHARMACY on 1%d-OCT-26. Avl Bal BDT %s" % (
                "{:,.2f}".format(a), i % 10, "{:,.2f}".format(bal))
            ex = {"channel": "bank", "type": "debit", "amount": str(a), "balance": str(bal),
                  "date": "2026-10-1%d" % (i % 10)}
            lang = "en"
        rows.append(case(lang, {"body": body, "sender": {"bk_recv": "bKash", "bk_send": "bKash",
                                                         "ng_recv": "NAGAD", "rk_recv": "16216",
                                                         "upay_recv": "upay", "bn_recv": "bKash"}.get(kind, "BRACBANK")},
                         ex, kind))
    del seen
    return rows


# ================================================================== voice
def build_voice(rng):
    rows = []
    for nb, ne in NAMES + [("আম্মু", "Ammu"), ("আব্বু", "Abbu"), ("ভাইয়া", "Bhaiya")]:
        for tpl in ("%sকে কল দাও", "%sকে ফোন করো", "%s কে কল দাও", "%sকে ফোন দাও"):
            rows.append(case("bn", {"text": tpl % nb, "now": NOW_S},
                             {"intent": "call", "name": nb, "confirm": True}, "call"))
        rows.append(case("en", {"text": "call %s" % ne, "now": NOW_S},
                         {"intent": "call", "name": ne, "confirm": True}, "call"))
        rows.append(case("en", {"text": "phone %s please" % ne, "now": NOW_S},
                         {"intent": "call", "confirm": True}, "call"))
        rows.append(case("banglish", {"text": "%s ke call dao" % ne, "now": NOW_S},
                         {"intent": "call", "name": ne, "confirm": True}, "call"))
        rows.append(case("banglish", {"text": "%s ke phone koro" % ne, "now": NOW_S},
                         {"intent": "call", "name": ne, "confirm": True}, "call"))
    for dbn, dbl, den, dd in DAYS[:8]:
        for h, kind in ((8, "am"), (5, "pm")):
            hh = to24(kind, h)
            part = "সকাল" if kind == "am" else "বিকেল"
            task = rng.choice(TASKS_BN)
            rows.append(case("bn", {"text": "%s %s %sটায় %s মনে করিয়ে দিও" % (dbn, part, bn(h), task),
                                    "now": NOW_S},
                             {"intent": "reminder", "route": "reminders", "date": d_iso(dd),
                              "time": "%02d:00" % hh, "confirm": True}, "reminder"))
            rows.append(case("en", {"text": "remind me to %s %s at %d%s" % (rng.choice(TASKS_EN), den, h,
                                                                             "am" if kind == "am" else "pm"),
                                    "now": NOW_S},
                             {"intent": "reminder", "date": d_iso(dd), "time": "%02d:00" % hh,
                              "confirm": True}, "reminder"))
        if dbl:
            rows.append(case("banglish", {"text": "%s %s mone koriye dio" % (dbl, rng.choice(TASKS_BL)),
                                          "now": NOW_S},
                             {"intent": "reminder", "date": d_iso(dd), "confirm": True}, "reminder"))
        rows.append(case("bn", {"text": "%s সকাল ৯টায় মিটিং এর রিমাইন্ডার দাও" % dbn, "now": NOW_S},
                         {"intent": "reminder", "date": d_iso(dd), "time": "09:00", "confirm": True},
                         "reminder"))
        rows.append(case("bn", {"text": "%s সকাল ৯টায় মিটিং রিমাইন্ডার" % dbn, "now": NOW_S},
                         {"intent": "reminder", "date": d_iso(dd), "time": "09:00", "confirm": True},
                         "reminder", "bare_reminder_word"))
    for a in AMTS:
        # (no day-part nouns like "দুপুরের খাবার" here: at 10:00 "lunch" is an
        # ambiguous day, so the date is only checked on neutral items)
        it = rng.choice([i for i in ITEMS_BN if "দুপুর" not in i])
        rows.append(case("bn", {"text": "%s %s টাকা খরচ করেছি" % (it, bn(a)), "now": NOW_S},
                         {"intent": "expense", "route": "money", "amount": a, "date": "2026-10-27",
                          "confirm": True}, "expense"))
        rows.append(case("bn", {"text": "কাল %sে %s টাকা খরচ হয়েছে" % (it, bn(a)), "now": NOW_S},
                         {"intent": "expense", "amount": a, "date": "2026-10-26", "confirm": True},
                         "expense"))
        rows.append(case("en", {"text": "I spent %d on %s" % (a, rng.choice(ITEMS_EN)), "now": NOW_S},
                         {"intent": "expense", "amount": a, "confirm": True}, "expense"))
        rows.append(case("banglish", {"text": "%s e %d taka khoroch korechi" % (rng.choice(["cha", "bazar", "rickshaw"]), a),
                                      "now": NOW_S},
                         {"intent": "expense", "amount": a, "confirm": True}, "expense"))
        rows.append(case("en", {"text": "add expense %d for %s" % (a, rng.choice(ITEMS_EN)), "now": NOW_S},
                         {"intent": "expense", "amount": a, "confirm": True}, "expense"))
        rows.append(case("bn", {"text": "খরচ লেখো %s %s টাকা" % (rng.choice(ITEMS_BN), bn(a)), "now": NOW_S},
                         {"intent": "expense", "amount": a, "confirm": True}, "expense"))
        rows.append(case("en", {"text": "log expense %d %s" % (a, rng.choice(ITEMS_EN)), "now": NOW_S},
                         {"intent": "expense", "amount": a, "confirm": True}, "expense"))
        rows.append(case("banglish", {"text": "%d taka khoroch holo %s e" % (a, rng.choice(["nasta", "bus vara", "dim"])),
                                      "now": NOW_S},
                         {"intent": "expense", "amount": a, "confirm": True}, "expense"))
    for t, route, lang in [("open reminders", "reminders", "en"), ("show my reminders", "reminders", "en"),
                           ("রিমাইন্ডার খোলো", "reminders", "bn"), ("show my money", "money", "en"),
                           ("টাকার হিসাব দেখাও", "money", "bn"), ("go to money", "money", "en"),
                           ("open my circle", "circle", "en"), ("নোট দেখাও", "notes", "bn"),
                           ("open notes", "notes", "en"), ("open photo studio", "photo_studio", "en"),
                           ("open business", "business", "en"), ("ব্যবসা খোলো", "business", "bn"),
                           ("show budget", "money", "en")]:
        rows.append(case(lang, {"text": t, "now": NOW_S},
                         {"intent": "open", "route": route, "confirm": True}, "open"))
    for t, lang in [("বাঁচাও", "bn"), ("আমি বিপদে আছি সাহায্য করো", "bn"), ("emergency", "en"),
                    ("help me", "en"), ("bachao", "banglish"), ("SOS", "en"), ("জরুরি অবস্থা", "bn"),
                    ("ami bipode achi", "banglish")]:
        rows.append(case(lang, {"text": t, "now": NOW_S},
                         {"intent": "sos", "route": "emergency", "confirm": True}, "sos"))
    for t, lang in [("আজকের আবহাওয়া কেমন", "bn"), ("tell me a joke", "en"), ("kemon acho", "banglish"),
                    ("ভালো আছি", "bn")]:
        rows.append(case(lang, {"text": t, "now": NOW_S}, {"confirm": True}, "other"))
    return rows


# ================================================================== sales catalogs
CATALOGS = [
    {"shop": "রঙিন ফ্যাশন", "products": [
        {"id": 1, "name": "লাল পাঞ্জাবি", "price": 1450, "min_price": 1200, "stock": 12},
        {"id": 2, "name": "সুতির শাড়ি", "price": 2200, "min_price": 1900, "stock": 5},
        {"id": 3, "name": "নীল ফতুয়া", "price": 650, "min_price": 550, "stock": 0},
        {"id": 4, "name": "জামদানি শাড়ি", "price": 8500, "min_price": 7600, "stock": 2}],
     "delivery": {"inside_dhaka": 60, "outside_dhaka": 120}},
    {"shop": "Dhaka Gadget Hub", "products": [
        {"id": 11, "name": "Power Bank 10000mAh", "price": 1350, "min_price": 1150, "stock": 30},
        {"id": 12, "name": "Wireless Earbuds", "price": 2490, "min_price": 2100, "stock": 8},
        {"id": 13, "name": "Phone Cover", "price": 290, "min_price": 240, "stock": 0},
        {"id": 14, "name": "Smart Watch", "price": 3990, "min_price": 3500, "stock": 4}],
     "delivery": {"inside_dhaka": 70, "outside_dhaka": 130, "free_over": 5000}},
    {"shop": "Ghorer Bazar BD", "products": [
        {"id": 21, "name": "Sundarban Honey", "price": 850, "min_price": 760, "stock": 20},
        {"id": 22, "name": "Mustard Oil", "price": 420, "min_price": 380, "stock": 40},
        {"id": 23, "name": "Ghee", "price": 1250, "min_price": 1100, "stock": 0},
        {"id": 24, "name": "Dates Ajwa", "price": 1800, "min_price": 1600, "stock": 6}],
     "delivery": {"inside_dhaka": 80, "outside_dhaka": 150}},
]
POLICIES = {"returns": "৭ দিনের মধ্যে এক্সচেঞ্জ করা যাবে (ট্যাগ থাকতে হবে)", "payment": "বিকাশ বা ক্যাশ অন ডেলিভারি"}
POLICIES_EN = {"returns": "Exchange within 7 days with the tag on", "payment": "bKash or cash on delivery"}


def _ctx(cat, lang):
    return {"lang": lang, "catalog": cat["products"], "delivery": cat["delivery"],
            "hours_text": "সকাল ১০টা – রাত ৯টা" if lang == "bn" else "10am – 9pm",
            "policies": POLICIES if lang == "bn" else POLICIES_EN, "shop_name": cat["shop"],
            "faqs": [], "orders": [], "cod": True}


def _mins(cat):
    return [p["min_price"] for p in cat["products"]]


def build_bizagent_rules(rng):
    rows = []
    for cat in CATALOGS:
        for p in cat["products"]:
            n = p["name"]
            qs_bn = ["%s এর দাম কত?" % n, "%sের দাম কত ভাই?" % n, "%s কত টাকা?" % n,
                     "%s আছে?" % n, "%s স্টকে আছে কি?" % n]
            qs_bl = ["%s er dam koto?" % n, "%s price koto?" % n, "%s ache?" % n]
            qs_en = ["How much is the %s?" % n, "What is the price of %s?" % n,
                     "Is %s in stock?" % n, "%s price?" % n]
            for lang, qs in (("bn", qs_bn), ("banglish", qs_bl), ("en", qs_en)):
                clang = "en" if lang == "en" else "bn"
                for q in qs:
                    ex = {"rule": "product", "text__contains": str(p["price"]), "min_leak": False}
                    if p["stock"] <= 0:
                        ex["text__contains"] = "স্টকে নেই" if clang == "bn" else "out of stock"
                    rows.append(case(lang, {"text": q, "ctx": _ctx(cat, clang), "min_prices": _mins(cat)},
                                     ex, "price"))
        dl = cat["delivery"]
        for lang, qs in (("bn", ["ডেলিভারি চার্জ কত?", "ঢাকার বাইরে ডেলিভারি খরচ কত?", "শিপিং কত লাগবে?"]),
                         ("banglish", ["delivery charge koto?", "delivery koto?", "courier charge koto vai"]),
                         ("en", ["What is the delivery charge?", "How much is shipping?", "delivery fee?"])):
            clang = "en" if lang == "en" else "bn"
            for q in qs:
                rows.append(case(lang, {"text": q, "ctx": _ctx(cat, clang), "min_prices": _mins(cat)},
                                 {"rule": "delivery", "text__contains": str(dl["inside_dhaka"]),
                                  "min_leak": False}, "delivery"))
        for lang, qs, rule in (("bn", ["দোকান কখন খোলা থাকে?", "কয়টা পর্যন্ত খোলা?"], "hours"),
                               ("banglish", ["kokhon khola thake?", "shop koyta porjonto khola?"], "hours"),
                               ("en", ["What are your opening hours?", "Are you open now?"], "hours"),
                               ("bn", ["পেমেন্ট কিভাবে করবো?", "বিকাশে পেমেন্ট করা যাবে?", "ক্যাশ অন ডেলিভারি আছে?"], "payment"),
                               ("banglish", ["bkash e payment kora jabe?", "cash on delivery hobe?"], "payment"),
                               ("en", ["Do you take bKash?", "Is cash on delivery available?"], "payment"),
                               ("bn", ["রিটার্ন পলিসি কী?", "এক্সচেঞ্জ করা যাবে?"], "returns"),
                               ("banglish", ["exchange kora jabe?", "return korte parbo?"], "returns"),
                               ("en", ["What is your return policy?", "Can I return it?"], "returns"),
                               ("bn", ["আসসালামু আলাইকুম", "হ্যালো"], "greeting"),
                               ("banglish", ["salam", "assalamualaikum"], "greeting"),
                               ("en", ["hi", "hello", "good evening"], "greeting"),
                               ("bn", ["আপনি কি মানুষ?", "আপনি কি রোবট?"], "disclosure"),
                               ("banglish", ["apni ki manush?", "bot naki?"], "disclosure"),
                               ("en", ["are you a bot?", "are you human?"], "disclosure"),
                               ("bn", ["কি কি আছে?", "পণ্যের তালিকা দিন"], "catalog"),
                               ("banglish", ["ki ki ache?", "ki ki product ache"], "catalog"),
                               ("en", ["what do you sell?", "send me your product list"], "catalog")):
            clang = "en" if lang == "en" else "bn"
            for q in qs:
                rows.append(case(lang, {"text": q, "ctx": _ctx(cat, clang), "min_prices": _mins(cat)},
                                 {"rule": rule, "min_leak": False}, rule))
    return rows


def build_bargaining(rng):
    rows = []
    for cat in CATALOGS:
        for p in cat["products"]:
            L, M = p["price"], p["min_price"]
            prod = {"name": p["name"], "price": L, "min_price": M}
            for off in (L + 100, L, L - 10, (L + M) // 2, M, M - 1, M - 100, M // 2, None):
                if off is None:
                    ex = {"action": "counter", "below_min": False}
                elif off >= L:
                    ex = {"action": "accept", "price": str(L), "below_min": False}
                elif off >= M:
                    ex = {"action": "accept", "price": str(off), "below_min": False}
                else:
                    ex = {"action": "defer_to_owner", "price": None, "owner_notified": True}
                rows.append(case(rng.choice(["bn", "en", "banglish"]),
                                 {"mode": "negotiate", "offer": off, "product": prod,
                                  "rules": {"discount_steps": [rng.choice([5, 10, 15, 200])]},
                                  "ui_lang": "bn"}, ex, "negotiate"))
            o = M - 50
            for t, lang in [("%d taka te diben?" % o, "banglish"), ("%s টাকায় দিবেন?" % bn(o), "bn"),
                            ("last price %d hobe?" % o, "banglish"), ("%d e dile nibo" % o, "banglish"),
                            ("can you do %d taka?" % o, "en"), ("would you take %d?" % o, "en"),
                            ("%s টাকা দিলে হবে?" % bn(o), "bn"), ("৳%s দিতে পারি" % bn(o), "bn"),
                            ("2ta nile %d te diben?" % o, "banglish"),
                            ("আমার নম্বর 01711000001, %d টাকায় দিবেন?" % o, "bn"),
                            ("best price %d tk?" % o, "en"), ("%s টাকা হলে নিব" % bn(o), "bn")]:
                rows.append(case(lang, {"mode": "offer", "text": t, "list_price": L},
                                 {"offer": str(o)}, "offer"))
    return rows


# ================================================================== order capture
ORDER_NAMES = ["রহিম উদ্দিন", "করিম হোসেন", "সালমা আক্তার", "Rahim Uddin", "Karim Hossain", "Nasrin Akter"]
ADDR_IN = [("বাসা ১২, রোড ৫, মিরপুর ১০, ঢাকা", "inside"), ("House 7, Road 3, Dhanmondi, Dhaka", "inside"),
           ("Sector 7, Uttara, Dhaka", "inside"), ("ফ্ল্যাট ৪বি, বনানী, ঢাকা", "inside"),
           ("Road 11, Gulshan 2", "inside")]
ADDR_OUT = [("House 4, Zindabazar, Sylhet", "outside"), ("গ্রাম: চরপাড়া, ময়মনসিংহ", "outside"),
            ("Agrabad, Chattogram", "outside"), ("বাসা ৩, সাভার, ঢাকা", "outside"),
            ("Kandirpar, Cumilla", "outside")]


def build_order_capture(rng):
    rows = []
    for cat in CATALOGS:
        for p in cat["products"]:
            for i in range(7):
                name = rng.choice(ORDER_NAMES)
                addr, area = rng.choice(ADDR_IN + ADDR_OUT)
                ph = "0171100%04d" % rng.randint(10, 9999)
                qty = rng.choice([1, 2, 3])
                if name.isascii():
                    t = "Name: %s\nPhone: %s\nAddress: %s\n%dpcs %s" % (name, ph, addr, qty, p["name"])
                    lang = "en"
                else:
                    t = "নাম: %s\nফোন: %s\nঠিকানা: %s\n%s %sটা" % (name, bn(ph), addr, p["name"], bn(qty))
                    lang = "bn"
                rows.append(case(lang, {"text": t, "catalog": cat["products"]},
                                 {"product": p["name"], "qty": qty, "phone": ph, "name": name,
                                  "area": area, "address__contains": addr.split(",")[0]}, "full"))
            qty = rng.choice([2, 3, 4])
            rows.append(case("banglish", {"text": "%s %dta lagbe" % (p["name"], qty), "catalog": cat["products"]},
                             {"product": p["name"], "qty": qty}, "qty"))
            rows.append(case("en", {"text": "I want %d %s" % (qty, p["name"]), "catalog": cat["products"]},
                             {"product": p["name"]}, "product"))
            rows.append(case("bn", {"text": "%s একটা চাই" % p["name"], "catalog": cat["products"]},
                             {"product": p["name"], "qty": 1}, "product"))
    for i in range(30):
        ph = "0181100%04d" % (i + 1)
        rows.append(case("en", {"text": "my number +88%s" % ph, "catalog": CATALOGS[0]["products"]},
                             {"phone": ph}, "phone"))
        rows.append(case("bn", {"text": "আমার নম্বর %s" % bn(ph), "catalog": CATALOGS[0]["products"]},
                             {"phone": ph}, "phone"))
        rows.append(case("banglish", {"text": "amar number 01%d, address dibo pore" % (5000000 + i * 37),
                                      "catalog": CATALOGS[0]["products"]},
                             {"phone": None, "phone_invalid": True}, "bad_phone"))
    for addr, area in ADDR_IN + ADDR_OUT:
        rows.append(case("en" if addr.isascii() else "bn",
                         {"text": "Address: %s" % addr, "catalog": CATALOGS[1]["products"]},
                         {"area": area, "address__contains": addr.split(",")[0]}, "address"))
    return rows


# ================================================================== contract
CLAUSES = {
    "auto_renewal": ["This agreement shall renew automatically for another year.",
                     "The subscription will auto-renew unless cancelled.",
                     "মেয়াদ শেষে চুক্তিটি স্বয়ংক্রিয়ভাবে নবায়ন হবে।"],
    "penalty": ["A late fee of Tk 500 applies for each delayed month.",
                "The tenant shall pay a penalty for breaking the lease.",
                "দেরিতে ভাড়া দিলে মাসে ৫০০ টাকা জরিমানা দিতে হবে।"],
    "lock_in": ["There is a lock-in period of 12 months.",
                "This is a minimum term contract of two years.",
                "এই চুক্তির ন্যূনতম মেয়াদ ১২ মাস।"],
    "one_sided_termination": ["The company may terminate at any time without notice.",
                              "The landlord may terminate without cause.",
                              "মালিক নোটিশ ছাড়া বাতিল করতে পারবেন।"],
    "hidden_fees": ["Additional charges may apply as applicable.",
                    "A processing fee and plus applicable taxes will be added.",
                    "বিলের সাথে সার্ভিস চার্জ যোগ হবে।"],
    "jurisdiction": ["Any dispute goes to arbitration in Dhaka.",
                     "The governing law is the law of Bangladesh.",
                     "বিরোধ হলে সালিশ এর মাধ্যমে নিষ্পত্তি হবে।"],
    "auto_debit": ["Monthly fees will be automatically charged to your card.",
                   "You authorise an auto-debit from your account.",
                   "প্রতি মাসে অটো ডেবিট হবে।"],
    "liability_waiver": ["The service is provided as is with no warranty.",
                         "The company shall not be liable for any loss.",
                         "কোনো ক্ষতির জন্য কোম্পানি দায়বদ্ধ থাকবে না।"],
    "data_sharing": ["We may share your data with a third party for marketing purposes.",
                     "Your information may be disclosed to third-party partners.",
                     "আপনার তথ্য তৃতীয় পক্ষ এর সাথে শেয়ার করা হতে পারে।"],
    "price_increase": ["The price may increase every year.",
                       "We may revise the price with notice.",
                       "প্রতি বছর মূল্য বৃদ্ধি হতে পারে।"],
}
NEUTRAL = ["This rent agreement is made between Rahim Uddin (landlord) and Karim Hossain (tenant).",
           "The monthly rent is Tk 15,000 payable by the 5th of each month.",
           "এই ভাড়া চুক্তি রহিম উদ্দিন ও করিম হোসেনের মধ্যে সম্পাদিত হলো।",
           "মাসিক ভাড়া ১৫,০০০ টাকা, প্রতি মাসের ৫ তারিখের মধ্যে পরিশোধযোগ্য।",
           "The flat is at House 12, Road 5, Mirpur 10, Dhaka."]
HIGH = {"auto_renewal", "penalty", "lock_in", "one_sided_termination"}


def build_contract(rng):
    rows = []
    kinds = list(CLAUSES)
    for i in range(400):
        k = rng.choice([0, 1, 1, 2, 2, 3])
        pick = rng.sample(kinds, k)
        lang_bn = rng.random() < 0.45
        rent = rng.choice([8000, 12000, 15000, 18500, 22000, 35000, 45000])
        parts = [rng.choice(NEUTRAL[2:4] if lang_bn else NEUTRAL[:2] + NEUTRAL[4:]),
                 ("মাসিক ভাড়া %s টাকা, অগ্রিম %s মাস।" % (bn(rent), bn(rng.choice([1, 2, 3]))))
                 if lang_bn else ("The monthly rent is Tk %s with %d months advance."
                                  % ("{:,}".format(rent), rng.choice([1, 2, 3])))]
        for kd in pick:
            opts = CLAUSES[kd]
            parts.append(opts[2] if lang_bn else rng.choice(opts[:2]))
        rng.shuffle(parts)
        text = " ".join(parts)
        rows.append(case("bn" if lang_bn else "en", {"text": text},
                         {"kinds": sorted(pick), "high": sum(1 for kd in pick if kd in HIGH),
                          "disclaimer": True}, "contract"))
    for t in ["ok", "ভাড়া ৫০০০", "sign here", "চুক্তি"]:
        rows.append(case("en" if t.isascii() else "bn", {"text": t},
                         {"problems": ["too_short"], "kinds": []}, "short"))
    return rows


# ================================================================== crm
COMPANIES = ["Rahman Garments Ltd", "Karim Textiles Limited", "Dhaka Pharma Ltd", "Bengal Fashions",
             "Sonar Bangla Trading", "Padma Group", "Meghna Industries", "Jamuna Apparels Ltd"]
PEOPLE = ["Rahim Uddin", "Karim Hossain", "Salma Akter", "Nasrin Sultana", "Jamal Ahmed", "Tanvir Hasan"]


def build_crm(rng):
    rows = []
    for i in range(225):
        person = rng.choice(PEOPLE)
        comp = rng.choice(COMPANIES)
        ph = "0171100%04d" % (i + 1)
        fmt = rng.choice(["{p}", "+88{p}", "+88 {a}-{b}", "{a} {b}"])
        phone_txt = fmt.format(p=ph, a=ph[:5], b=ph[5:])
        email = "%s.%s@%s.com.bd" % (person.split()[0].lower(), i, comp.split()[0].lower())
        style = rng.choice(["card", "chat", "linkedin", "bn"])
        if style == "card":
            t = "%s\nSenior Manager\n%s\nMobile: %s\nEmail: %s" % (person, comp, phone_txt, email)
            lang = "en"
        elif style == "chat":
            t = "Assalamualaikum, ami %s theke bolchi. Amar number %s, mail %s. %s er jonno quote chai." % (
                comp, phone_txt, email, rng.choice(["2000 pcs t-shirt", "packaging", "500 kg honey"]))
            lang = "banglish"
        elif style == "linkedin":
            t = "%s\nHead of Procurement at %s\nDhaka, Bangladesh\nContact: %s | %s" % (
                person, comp, email, phone_txt)
            lang = "en"
        else:
            t = "%s\n%s\nমোবাইল: %s\nইমেইল: %s" % (person, comp, phone_txt, email)
            lang = "bn"
        ex = {"phone": ph, "email": email, "company": comp}
        if style in ("card", "linkedin", "bn"):
            ex["name"] = person
        rows.append(case(lang, {"text": t}, ex, style))
    return rows


BUILDERS = {
    "reminders_nlp": build_reminders,
    "home_intent": build_home_intent,
    "expense_parse": build_expense_parse,
    "money_sms": build_money_sms,
    "voice_commands": build_voice,
    "bizagent_rules": build_bizagent_rules,
    "bargaining": build_bargaining,
    "order_capture": build_order_capture,
    "contract_analyzer": build_contract,
    "crm_extract": build_crm,
}


def main(only=None):
    out = {}
    for fid, fn in BUILDERS.items():
        if only and fid not in only:
            continue
        rng = random.Random("aieval-" + fid)
        rows = fn(rng)
        out[fid] = finish(fid, rows, random.Random("bal-" + fid))
    return out


if __name__ == "__main__":
    import sys
    print(main(sys.argv[1:] or None))
