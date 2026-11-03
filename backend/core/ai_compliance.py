"""aifinal (owner AI order 3 Nov 23:15, PART 6): AI answer compliance.

  * every AI answer is labelled "AI generated" in the app (meta.ai_generated);
  * general information only — never personalised legal, medical or financial
    advice: the model is told so, and an answer on those topics ends with ONE
    short consult-a-professional line (added here, deterministic);
  * safe AI mode for users under 18 and child accounts: age-appropriate
    instructions, the line to talk to a parent / teacher on hard topics.

Always on (compliance, not a feature switch). Pure rules, no AI call."""
import re

GENERAL_RULE = (
    "Give general information only. Never give personalised legal, medical or "
    "financial advice (no diagnosis, no dose, no specific legal strategy, no "
    "specific investment pick); explain the general options and say a "
    "qualified professional should decide.")

SAFE_MODE_RULE = (
    "SAFE MODE: the user is under 18 (a child account). Keep every answer "
    "age-appropriate and kind. Never discuss sexual content, dating, gambling, "
    "alcohol, drugs, weapons or violence in detail; never ask for or encourage "
    "sharing personal details, photos or location with strangers; for bullying, "
    "abuse, self-harm or any scary situation, tell them to talk to a parent, "
    "teacher or trusted adult now and that 999 is the emergency number.")

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

_LINES = {
    "medical": ("এটি সাধারণ তথ্য — নিজের ক্ষেত্রে সিদ্ধান্তের আগে ডাক্তারের পরামর্শ নিন।",
                "This is general information — please consult a doctor for your own case."),
    "legal": ("এটি সাধারণ তথ্য — নিজের বিষয়ে সিদ্ধান্তের আগে একজন আইনজীবীর পরামর্শ নিন।",
              "This is general information — please consult a lawyer for your own case."),
    "financial": ("এটি সাধারণ তথ্য — টাকা-পয়সার সিদ্ধান্তের আগে একজন আর্থিক পরামর্শদাতার সাথে কথা বলুন।",
                  "This is general information — please talk to a qualified financial adviser "
                  "before deciding."),
}


def topic_of(*texts):
    """'medical' | 'legal' | 'financial' | '' for the user's message (+ reply)."""
    t = " ".join(str(x or "")[:3000] for x in texts)
    for k in ("medical", "legal", "financial"):
        if _COMPILED[k].search(t):
            return k
    return ""


def add_professional_line(reply, text, lang):
    """Append the one short consult-a-professional line when the topic is
    legal / medical / financial (once; never twice). Returns (reply, topic)."""
    topic = topic_of(text)
    if not topic:
        return reply, ""
    bn, en = _LINES[topic]
    line = bn if lang == "bn" else en
    body = (reply or "").rstrip()
    if line in body:
        return body, topic
    return body + "\n\n" + line, topic


def is_minor(user):
    """Under 18 or a child account (fails CLOSED to safe mode on error)."""
    if user is None:
        return False
    try:
        from .safe_plans import is_child_account
        return bool(is_child_account(user))
    except Exception:  # noqa: BLE001
        return True


def system_rules(user):
    """Extra system text for an AI chat call."""
    rules = GENERAL_RULE
    if is_minor(user):
        rules += "\n" + SAFE_MODE_RULE
    return rules
