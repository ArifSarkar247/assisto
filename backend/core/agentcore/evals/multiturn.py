"""AF-18 eval set "multiturn": >= 50 THREE-turn conversations per topic
(money, family, safety, documents, travel, health, learning, business) in
Bangla, English and Banglish — follow-ups ("and last month?", "say that
again"), corrections ("no, I meant ..."), pronouns ("send HIM a tagada"),
"undo that" (a reminder / a second reminder / a logged expense / a stock
change taken back; a sent message honestly NOT taken back; nothing to undo).

Each turn is a real run (runner.start with follow_up = the previous turn's
run), graded by harness.grade (tools, answer, topic, billing, audit, PII);
then the conversation's end state is checked in the database.
"""
from .build_goalsets import SUFFIX, VARIANTS
from .fixtures import EXPECT as M
from .fixtures_topics import tk

TOPICS = ("money", "family", "safety", "documents", "travel", "health", "learning", "business")
USE_VARIANTS = (0, 1, 3, 6)
AGAIN = {"bn": "আবার বলো", "en": "Say that again", "bl": "abar bolo"}
UNDO = {"bn": "ওটা বাতিল করো", "en": "Undo that", "bl": "undo kore dao"}
UNDONE = ("ফিরিয়ে নেওয়া হয়েছে", "Undone")
NOTHING = ("ফিরিয়ে নেওয়ার মতো কিছু নেই", "Nothing to undo")
CANNOT = ("আর ফেরানো যায় না", "cannot be undone")


def _L(lang, pair):
    return pair[0] if lang == "bn" else pair[1]


# Per topic: reads A, B (tools, answer) + a correction to B + two reminders.
# Each phrase entry: {src: text}; "bl" = Banglish (answered in Bangla).
def _reads(topic):
    if topic == "money":
        return dict(
            A={"bn": "এই মাসে আমার কত খরচ হলো?", "en": "How much did I spend this month?",
               "bl": "ei mashe koto khoroch holo?"},
            A_exp=lambda l: {"tools": ["money.month_summary"], "answer_has": [tk(M["expense_this"], l)]},
            B={"bn": "আমার বাজেটের অবস্থা কী?", "en": "Am I over budget anywhere?", "bl": "budget er obostha ki?"},
            B_fix={"bn": "না, আমি বাজেটের অবস্থা জানতে চেয়েছি", "en": "No, I meant my budget status",
                   "bl": "na, ami budget er obostha jante chaisi"},
            B_exp=lambda l: {"tools": ["budget.status"], "answer_has": [M["budget_over"]]},
            F={"bn": "আর গত মাসে?", "en": "And last month?", "bl": "ar gotomash e?"},
            F_exp=lambda l: {"tools": ["money.month_summary"], "answer_has": [tk(M["expense_last"], l)]},
            R1={"bn": "কাল সকালে বিদ্যুৎ বিল দেওয়ার কথা মনে করিয়ে দিও",
                "en": "Remind me tomorrow to pay the electricity bill", "bl": "kal current bill dite mone koriye dio"},
            R2={"bn": "কাল বাসাভাড়া দিতে হবে, মনে করিয়ে দিও", "en": "Set a reminder for tomorrow to pay rent",
                "bl": "kal basha vara dite mone koriye dio"})
    if topic == "family":
        return dict(
            A={"bn": "সামনে কার জন্মদিন আছে?", "en": "Whose birthday is coming up?", "bl": "kar jonmodin ashche samne?"},
            A_exp=lambda l: {"tools": ["birthdays.upcoming"], "answer_has": ["Ammu"]},
            B={"bn": "পরিবারের সবাই ঠিকমতো যাচ্ছে তো?", "en": "Is my family okay on the road right now?",
               "bl": "family r sobai thik ache?"},
            B_fix={"bn": "না, আমি জানতে চেয়েছি পরিবারের সবাই ঠিক আছে কিনা", "en": "No, I meant: is my family okay?",
                   "bl": "na, family r sobai thik ache kina"},
            B_exp=lambda l: {"tools": ["family.status"], "answer_has": ["Nadia"]},
            R1={"bn": "কাল সকালে আম্মুকে ফোন করার কথা মনে করিয়ে দিও", "en": "Remind me tomorrow to call Ammu",
                "bl": "kal abbu ke phone dite mone koriye dio"},
            R2={"bn": "কাল নানুর বাসায় যাওয়ার রিমাইন্ডার দাও", "en": "Set a reminder for tomorrow to buy Rafi's gift",
                "bl": "kal nanur basay jawar reminder dao"})
    if topic == "safety":
        return dict(
            A={"bn": "আমার যাত্রা কেমন চলছে?", "en": "How is my journey going?", "bl": "amar journey kemon cholche?"},
            A_exp=lambda l: {"tools": ["journey.status"], "answer_has": ["Office"]},
            B={"bn": "পরিবারের সবাই ঠিকমতো পৌঁছেছে?", "en": "Is my family safe on their journey?",
               "bl": "family r sobai safe journey te ache?"},
            B_fix={"bn": "না, আমি পরিবারের যাত্রার খবর জানতে চেয়েছি", "en": "No, I meant my family's journeys",
                   "bl": "na, ami family r journey r khobor jante chaisi"},
            B_exp=lambda l: {"tools": ["family.status"], "answer_has": ["Nadia"]},
            S={"bn": "SOS চালু করো", "en": "Start an SOS for me", "bl": "SOS chalu koro"},
            S_exp=lambda l: {"tools": [], "no_tools": True, "answer_has": [_L(l, ("৯৯৯", "999"))]})
    if topic == "documents":
        return dict(
            A={"bn": "আমার কোন ডকুমেন্টের মেয়াদ শেষ হচ্ছে?", "en": "Which of my documents expire soon?",
               "bl": "kon document er meyad shesh hocche?"},
            A_exp=lambda l: {"tools": ["documents.expiring"], "answer_has": ["Passport"]},
            B={"bn": "আমার ইন্স্যুরেন্সের কাগজ কোথায় রেখেছি?", "en": "Where did I keep my insurance papers?",
               "bl": "insurance er kagoj kothay rekhechi?"},
            B_fix={"bn": "না, আমি জানতে চেয়েছি ইন্স্যুরেন্সের কাগজ কোথায় রেখেছি",
                   "en": "No, I meant: where did I keep my insurance papers?",
                   "bl": "na, insurance er kagoj kothay rekhechi seta bolo"},
            B_exp=lambda l: {"tools": ["notes.search"], "answer_has": ["Insurance papers"]},
            R1={"bn": "কাল সকালে পাসপোর্ট নবায়নের কথা মনে করিয়ে দিও", "en": "Remind me tomorrow to renew my passport",
                "bl": "kal passport renew er kotha mone koriye dio"},
            R2={"bn": "কাল লাইসেন্স অফিসে যাওয়ার রিমাইন্ডার দাও",
                "en": "Set a reminder for tomorrow to visit the licence office",
                "bl": "kal licence office e jawar reminder dao"})
    if topic == "travel":
        return dict(
            A={"bn": "আমার ট্রিপ কেমন চলছে?", "en": "How is my trip going?", "bl": "amar trip kemon cholche?"},
            A_exp=lambda l: {"tools": ["journey.status"], "answer_has": ["Sylhet"]},
            B={"bn": "ট্যুরের আগে কী কী কাজ বাকি?", "en": "Show my reminders before the tour",
               "bl": "tour er age ki ki kaj ache?"},
            B_fix={"bn": "না, আমি জানতে চেয়েছি ট্যুরের আগে কী কী কাজ বাকি",
                   "en": "No, I meant my reminders before the tour", "bl": "na, tour er age ki ki kaj ache bolo"},
            B_exp=lambda l: {"tools": ["reminders.list"], "answer_has": ["Pack bags"]},
            R1={"bn": "কাল সকালে ব্যাগ গোছানোর কথা মনে করিয়ে দিও", "en": "Remind me tomorrow to pack for the trip",
                "bl": "kal shokale bag gochanor kotha mone koriye dio"},
            R2={"bn": "কাল ট্রেনের সময় দেখার রিমাইন্ডার দাও", "en": "Set a reminder for tomorrow to buy snacks for the bus",
                "bl": "kal train er shomoy dekhar reminder dao"})
    if topic == "health":
        return dict(
            A={"bn": "আজ আমার কী কী রিমাইন্ডার আছে?", "en": "What reminders do I have today?",
               "bl": "aj amar ki ki reminder ache?"},
            A_exp=lambda l: {"tools": ["reminders.list"], "answer_has": ["Drink water"]},
            B={"bn": "ওষুধের ডোজ কত খাব?", "en": "What dose of medicine should I take?", "bl": "osudh er dose koto khabo?"},
            B_fix={"bn": "না, আমি জানতে চেয়েছি ওষুধের ডোজ কত খাব", "en": "No, I meant: what medicine dose should I take?",
                   "bl": "na, osudh er dose koto khabo seta bolo"},
            B_exp=lambda l: {"tools": [], "no_tools": True, "answer_has": [_L(l, ("ডাক্তার", "doctor"))]},
            R1={"bn": "কাল সকালে হাঁটার কথা মনে করিয়ে দিও", "en": "Remind me tomorrow to go for a walk",
                "bl": "kal shokale hatar kotha mone koriye dio"},
            R2={"bn": "কাল রাতে বেশি পানি খাওয়ার রিমাইন্ডার দাও", "en": "Set a reminder for tomorrow to drink more water",
                "bl": "kal pani khawar reminder dao"})
    if topic == "learning":
        return dict(
            A={"bn": "আমার IELTS পরীক্ষা কবে?", "en": "When is my IELTS exam?", "bl": "amar IELTS exam kobe?"},
            A_exp=lambda l: {"tools": ["reminders.list"], "answer_has": ["IELTS exam"]},
            B={"bn": "পরীক্ষার আগে কী কী কাজ বাকি?", "en": "Show my reminders before the exam",
               "bl": "exam er age ki ki kaj ache?"},
            B_fix={"bn": "না, আমি জানতে চেয়েছি পরীক্ষার আগে কী কী কাজ বাকি",
                   "en": "No, I meant my reminders before the exam", "bl": "na, exam er age ki ki kaj ache seta bolo"},
            B_exp=lambda l: {"tools": ["reminders.list"], "answer_has": ["Submit bank job application"]},
            R1={"bn": "কাল সকালে IELTS পড়ার কথা মনে করিয়ে দিও", "en": "Remind me tomorrow to study for IELTS",
                "bl": "kal shokale IELTS porar kotha mone koriye dio"},
            R2={"bn": "কাল চাকরির আবেদনের রিমাইন্ডার দাও", "en": "Set a reminder for tomorrow to update my CV",
                "bl": "kal job application er reminder dao"})
    if topic == "business":
        return dict(
            A={"bn": "খাতায় কার কাছে কত বাকি?", "en": "Who owes me money in my khata?", "bl": "khatay kar kache koto baki?"},
            A_exp=lambda l: {"tools": ["khata.dues"], "answer_has": [tk(4700, l), "Selim"]},
            B={"bn": "কোন মালের স্টক কম?", "en": "Which products are low on stock?", "bl": "kon maler stock kom?"},
            B_fix={"bn": "না, আমি জানতে চেয়েছি কোন মালের স্টক কম", "en": "No, I meant: which products are low on stock?",
                   "bl": "na, kon maler stock kom seta bolo"},
            B_exp=lambda l: {"tools": ["stock.low"], "answer_has": ["Dal"]},
            P={"bn": "ওকে বাকির তাগাদা পাঠাও", "en": "Send him a tagada on WhatsApp", "bl": "oke tagada pathao"},
            ST={"bn": "Chal 5kg এর স্টকে ২০টি যোগ করো", "en": "Add 20 Chal 5kg to stock",
                "bl": "Chal 5kg stock e 20 ta add koro"},
            R1={"bn": "কাল চাল কেনার কথা মনে করিয়ে দিও", "en": "Remind me tomorrow to restock rice",
                "bl": "kal chal kenar kotha mone koriye dio"},
            R2={"bn": "কাল সাপ্লায়ারকে ফোন দেওয়ার রিমাইন্ডার দাও", "en": "Set a reminder for tomorrow to call the supplier",
                "bl": "kal supplier ke phone dewar reminder dao"})
    raise KeyError(topic)


def _turn(goal, exp, topic, **extra):
    e = {"forbid": [], "answer_has": [], "no_tools": False}
    e.update(exp)
    e.setdefault("tools", [])
    e["topics"] = [topic]
    e.update(extra)
    return {"goal": goal, "expect": e}


def _undo(src, lang, topic, what):
    return _turn(UNDO[src], {"tools": [], "no_tools": True, "answer_has": [_L(lang, what)]}, topic)


def _again(src, lang, topic, exp):
    return _turn(AGAIN[src], exp, topic)


def _kinds(topic, src, lang):
    """-> {kind: (turns, end_state)} for one language."""
    r = _reads(topic)
    A, B = r["A"][src], r["B"][src]
    a_exp, b_exp = r["A_exp"](lang), r["B_exp"](lang)
    out = {
        # K1: read, another read, "say that again" -> the second read again
        "follow_again": ([_turn(A, a_exp, topic), _turn(B, b_exp, topic), _again(src, lang, topic, b_exp)], {}),
        # K2: read, correction, "again"
        "correction": ([_turn(A, a_exp, topic), _turn(r["B_fix"][src], b_exp, topic),
                        _again(src, lang, topic, b_exp)], {}),
        # K5: read, undo (nothing to undo), "again" -> the read (undo turns are skipped)
        "undo_nothing": ([_turn(A, a_exp, topic), _undo(src, lang, topic, NOTHING),
                          _again(src, lang, topic, a_exp)], {}),
    }
    if "R1" in r:
        R1, R2 = r["R1"][src], r["R2"][src]
        rem = {"tools": ["reminders.create"], "reminder": True}
        # K3: reminder, undo -> gone, read still fine
        out["undo_reminder"] = ([_turn(R1, rem, topic), _undo(src, lang, topic, UNDONE), _turn(A, a_exp, topic)],
                                {"reminders_gone": [R1]})
        # K4: two reminders, undo -> only the second is taken back
        out["undo_last_only"] = ([_turn(R1, rem, topic), _turn(R2, {"tools": ["reminders.create"]}, topic),
                                  _undo(src, lang, topic, UNDONE)],
                                 {"reminders_kept": [R1], "reminders_gone": [R2]})
    if topic == "money":
        log = {"bn": "আজ বাজারে ৫০০ টাকা খরচ হয়েছে, লিখে রাখো", "en": "Log an expense of 350 taka for lunch",
               "bl": "aj 200 taka khoroch hoise, likhe rakho"}[src]
        amt = {"bn": 500, "en": 350, "bl": 200}[src]
        out["undo_money_log"] = ([_turn(log, {"tools": ["money.log"], "txn": ["expense", amt]}, topic),
                                  _undo(src, lang, topic, UNDONE), _turn(A, a_exp, topic)],
                                 {"no_agent_txn": True})
        out["follow_last_month"] = ([_turn(A, a_exp, topic), _turn(r["F"][src], r["F_exp"](lang), topic),
                                     _turn(B, b_exp, topic)], {})
    if topic == "safety":
        sos = r["S"][src]
        out["sos_again"] = ([_turn(A, a_exp, topic), _turn(sos, r["S_exp"](lang), topic),
                             _again(src, lang, topic, r["S_exp"](lang))], {})
        out["read_undo_read"] = ([_turn(B, b_exp, topic), _undo(src, lang, topic, NOTHING),
                                  _turn(A, a_exp, topic)], {})
    if topic == "business":
        tag = _turn(r["P"][src], {"tools": ["khata.dues", "khata.tagada"], "approval": "khata.tagada",
                                  "decide": "approve", "no_send": True, "answer_has": ["Selim"]}, topic)
        # K6: dues, "send HIM a tagada" (name from the last answer), undo -> cannot unsend
        out["pronoun_tagada"] = ([_turn(A, a_exp, topic), tag, _undo(src, lang, topic, CANNOT)], {})
        # K7: stock +20, undo -> back, low stock shows it again
        out["undo_stock"] = ([_turn(r["ST"][src], {"tools": ["stock.adjust"], "stock": {"Chal 5kg": 22}}, topic),
                              _undo(src, lang, topic, UNDONE),
                              _turn(B, {"tools": ["stock.low"], "answer_has": ["Chal 5kg", "Dal"]}, topic)],
                             {"stock": {"Chal 5kg": 2}})
    return out


def cases():
    out, n = [], 0
    for topic in TOPICS:
        for src in ("bn", "en", "bl"):
            lang = "en" if src == "en" else "bn"
            for kind, (turns, end) in _kinds(topic, src, lang).items():
                for vi in USE_VARIANTS:
                    v = VARIANTS[src][vi]
                    ts = [dict(t, expect=dict(t["expect"])) for t in turns]
                    g = ts[0]["goal"]
                    ts[0]["goal"] = g + v if SUFFIX[vi] else v + g
                    end2 = dict(end)
                    # a reminder's title is the turn's own text (with the variant)
                    for key in ("reminders_gone", "reminders_kept"):
                        if key in end2:
                            end2[key] = [ts[0]["goal"] if x == g else x for x in end2[key]]
                    n += 1
                    out.append({"id": "mt-%s-%03d" % (topic, n), "topic": topic, "lang": lang, "src": src,
                                "kind": kind, "variant": vi, "turns": ts, "end": end2})
    return out


def run_conv(conv, seam):
    """-> [reasons]. Turn 1 names the topic; later turns go through the
    classifier with follow_up = the previous turn's run."""
    from ...models import AgentApproval, Product, Reminder, Transaction, User
    from .. import runner as RN
    from . import harness as H
    user = H.make_user(credits=200)
    H.SEEDERS[conv["topic"]](user)
    bad, prev = [], None
    for i, t in enumerate(conv["turns"], 1):
        bal0 = User.objects.get(pk=user.pk).ai_credits
        n0 = len(seam.prompts)
        run = RN.start(user, t["goal"], topic=conv["topic"] if i == 1 else "", channel="eval",
                       lang=conv["lang"], follow_up=prev.pk if prev is not None else None)
        dec = t["expect"].get("decide")
        if dec:
            ap = AgentApproval.objects.filter(run=run, status="pending").first()
            if ap is not None:
                RN.decide(user, ap.pk, dec, lang=conv["lang"])
                run.refresh_from_db()
        if i > 1 and RN.follow_up_of(type(run).objects.get(pk=run.pk)) != prev.pk:
            bad.append("t%d: not linked to the previous turn" % i)
        bad += ["t%d: %s" % (i, r) for r in H.grade({"expect": t["expect"]}, run, seam.prompts[n0:], bal0)]
        prev = run
    end = conv["end"]
    for title in end.get("reminders_gone") or []:
        if Reminder.objects.filter(user=user, title=title.strip()[:120]).exists():
            bad.append("end: reminder not undone: " + title)
    for title in end.get("reminders_kept") or []:
        if not Reminder.objects.filter(user=user, title=title.strip()[:120]).exists():
            bad.append("end: reminder lost: " + title)
    if end.get("no_agent_txn") and Transaction.objects.filter(user=user, source="agent").exists():
        bad.append("end: logged expense not undone")
    for name, n in (end.get("stock") or {}).items():
        p = Product.objects.filter(user=user, name=name).first()
        if p is None or p.stock != n:
            bad.append("end: stock %s=%s want %s" % (name, p.stock if p else None, n))
    return bad


def run_suite(convs):
    from unittest import mock
    from .harness import ci_brain
    out = {"passed": [], "failed": []}
    # ~1,300 planner calls in ONE test: the router's daily USD caps (not
    # under test here) would stop the suite half-way (same as the AF-5 suite)
    with ci_brain() as seam, \
            mock.patch("core.ai_router.total_capped", return_value=False), \
            mock.patch("core.ai_router.provider_capped", return_value=False):
        for c in convs:
            bad = run_conv(c, seam)
            (out["failed"] if bad else out["passed"]).append((c["id"], bad))
    return out
