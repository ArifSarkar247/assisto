"""aiqual: the chat as it was on main at 9 Nov 2026 (before aiqual), copied
verbatim, so the offline AI exam can score BEFORE and AFTER in the same CI
run (tests_aiqual_exam prints AIEXAM-OFFLINE-BEFORE). Test-only: nothing in
the product imports this module."""
import re
from contextlib import ExitStack, contextmanager
from unittest import mock

CHAT_TASK = (
    "তুমি Assisto, একজন বাংলা-প্রথম সহকারী। উত্তর সবসময় বাংলায় (বাংলা "
    "হরফে) দাও — প্রশ্নের উত্তর প্রথম বাক্যেই, সত্যভাবে ও সম্পূর্ণভাবে। "
    "'আমার কাছে আপনার তথ্য নেই' দিয়ে কখনো শুরু করবে না। প্রশ্ন তার "
    "নিজের রেকর্ড নিয়ে হলে তবেই নিচের DATA দেখবে; কোনো সংখ্যা বা তথ্য বানাবে না।",
    "You are Assisto, a Bangla-first assistant. Reply in English — answer "
    "the question in the first sentence, completely and truthfully. Never open "
    "by saying you don't have the user's data. Use the DATA below only when "
    "the question is about their own records; never invent numbers or facts.")
CHAT_DATA = "User's latest message: {text}\n\nTheir data summary:\n{summary}"
CONTINUE_NOTE = (
    "তোমার আগের উত্তরটি মাঝপথে কেটে গিয়েছিল। ঠিক যেখানে থেমেছিল সেখান থেকে চালিয়ে যাও — "
    "আগে যা লেখা হয়েছে তা একটুও আবার লিখবে না; পরের শব্দ থেকে শুরু করো।",
    "Your previous answer was cut off. Continue EXACTLY from where it stopped — do not "
    "repeat anything already written; start with the next words.")
_SENT_END = re.compile(r"(?<![0-9০-৯])[.!?।](?:\s|$)|\n")

_ROMAN_BN = frozenset("""
ami amar amake amra amader tumi tomar tomake apni apnar apnake se tar tader
ki keno kemon kothay kobe koto kon kar kake kivabe kibhabe ki-bhabe
achi acho achen ache achhe ase nai nei na hobe hoy hoyni hoise hoyeche
korbo korte koro korun kori kore korechi korsi bolo bolun boli bolte
jabo jao jan jai jete asbo aso ashen ashbo khabo khao khete dao den dite nibo nite
bhalo valo kharap thik shob sob onek ektu ekhon ajke aj kal kalke porshu
taka poisa bari basa ghor school office kaj kotha bhai apu vai bon ma baba
dorkar lagbe lage chai chaai jante bujhi bujhte parbo parben pari parsi
""".split())
_BN_SCRIPT = re.compile(r"[ঀ-৿]")
_LATIN_WORD = re.compile(r"[A-Za-z']+")

_TOPICS = {
    "medical": r"medicine|medication|dose|dosage|tablet|symptom|diagnos|disease|pregnan|doctor|"
               r"blood pressure|diabetes|fever|cancer|ওষুধ|ডোজ|ট্যাবলেট|রোগ|জ্বর|ডাক্তার|"
               r"গর্ভ|ডায়াবেটিস|প্রেশার|osudh|jor|daktar",
    "legal": r"\blaw\b|legal|lawyer|court|case against|divorce|inheritance|land dispute|police case|"
             r"contract|আইন|উকিল|আদালত|মামলা|তালাক|উত্তরাধিকার|জমির|দলিল|mamla|ukil",
    "financial": r"invest|stock|share market|loan|interest rate|tax|insurance|crypto|mutual fund|"
                 r"savings? certificate|বিনিয়োগ|শেয়ার|ঋণ|লোন|সুদ|কর\b|ট্যাক্স|বীমা|সঞ্চয়পত্র|"
                 r"biniyog|share bazar",
}
_COMPILED = {k: re.compile(v, re.I) for k, v in _TOPICS.items()}
RECENT = re.compile(
    r"\b(today|latest|news|current(?:ly)?|right now|this week|price (?:now|today)|score|"
    r"weather|exchange rate|dollar rate|20[2-3]\d)\b|আজ|আজকের|সর্বশেষ|খবর|এখন(?:কার)? দাম|"
    r"আবহাওয়া|ডলারের রেট|ajker|aj ke|latest", re.I)


def reply_lang(text, app_lang="bn"):
    t = str(text or "")
    if _BN_SCRIPT.search(t):
        return "bn"
    words = [w.lower() for w in _LATIN_WORD.findall(t)]
    if not words:
        return "bn" if app_lang == "bn" else "en"
    hits = sum(1 for w in words if w in _ROMAN_BN)
    if hits >= 2 or (hits >= 1 and len(words) <= 3):
        return "bn"
    return "en"


def topic_of(*texts):
    t = " ".join(str(x or "")[:3000] for x in texts)
    for k in ("medical", "legal", "financial"):
        if _COMPILED[k].search(t):
            return k
    return ""


def end_at_sentence(text):
    t = (text or "").rstrip()
    ends = [m.end() for m in _SENT_END.finditer(t)]
    if not ends:
        return t
    cut = ends[-1]
    return t[:cut].rstrip() if cut >= len(t) * 0.3 else t


def chat_task_text(lang, user=None, *, minor=None, tools=None, follow="", photo=False,
                   out_cap=0, web=False, romanized=False):   # romanized: aichat-nine, ignored
    """The old inline composition in _produce_reply (no format / length /
    web / date rules)."""
    from core import ai_compliance as AC
    from core import ai_tools as AT
    from core import views_chat as VC
    from core.i18n import pick
    t = pick(lang, *CHAT_TASK)
    if minor is None:
        t += "\n" + AC.system_rules(user)
    else:
        t += "\n" + AC.GENERAL_RULE + ("\n" + AC.SAFE_MODE_RULE if minor else "")
    if (user is not None) if tools is None else tools:
        t += "\n" + AT.TOOL_RULE
    if follow == "continue":
        t += "\n" + pick(lang, *CONTINUE_NOTE)
    elif follow == "more":
        t += "\n" + pick(lang, *VC.MORE_NOTE)
    if photo:
        t += "\n" + pick(lang, *VC.PHOTO_NOTE)
    return t


def chat_data(text, summary, now=None):
    return CHAT_DATA.format(text=text, summary=summary)


def finish_reply(reply, text, lang, *, truncated=False, data_reply="", history=None,
                 strict=False):
    """The old post-processing: guards, money, ACTION, internal words, cut."""
    from core import ai_guard
    from core import ai_tools as AT
    from core import views_chat as VC
    n_money = 0
    try:
        reply, _f = ai_guard.clean_assistant_answer(reply, lang)
        reply, n_money = ai_guard.scrub_ungrounded_money(
            reply, text, data_reply, [h.get("content", "") for h in (history or [])],
            lang=lang, strict=strict)
    except Exception:  # noqa: BLE001
        pass
    reply, proposal = AT.extract(reply)
    reply = VC.scrub_internal(reply)
    cut = bool(truncated)
    if cut:
        reply = end_at_sentence(reply)
    return reply, proposal, cut, n_money


def wants_web(text, lid, c=None):
    from core import ai_levels_service as ALS
    lv, _ = ALS.cfg(c)
    if not lv.get("web_on") or not RECENT.search(text or ""):
        return False
    return lid in lv["levels"]


@contextmanager
def legacy():
    """Run the product with the 9 Nov (pre-aiqual) chat behaviour."""
    from core import ai_compliance as AC, ai_levels_service as ALS, ai_prompt as AP
    from core import views_chat as VC
    with ExitStack() as st:
        for obj, name, val in (
                (VC, "CHAT_TASK", CHAT_TASK), (VC, "CONTINUE_NOTE", CONTINUE_NOTE),
                (VC, "chat_task_text", chat_task_text), (VC, "chat_data", chat_data),
                (VC, "finish_reply", finish_reply), (VC, "end_at_sentence", end_at_sentence),
                (AP, "reply_lang", reply_lang), (AP, "identity_rule", lambda off=None: AP.IDENTITY_ALL),
                (AC, "topic_of", topic_of), (ALS, "wants_web", wants_web)):
            st.enter_context(mock.patch.object(obj, name, val))
        yield
