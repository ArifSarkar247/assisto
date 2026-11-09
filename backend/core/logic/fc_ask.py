"""fcbrain — the family ASK BAR offline parser (pure Python, no DB, no AI).

Mirror of app/lib/family_v3/brain/fc_ask_parser.dart; the SAME case table
(app/test/fixtures/fc_ask_cases.json) drives both test suites, so the phone
and the server answer the same question the same way.

Understands Bangla, romanized Bangla and English, e.g.
  "Is Ammu OK" · "আম্মু ঠিক আছে?" · "ammu thik ase?" · "Where is my son" ·
  "ছেলে কোথায়" · "chele kothay" · "abbur charge koto" · "sobai thik?"
and answers ONLY from family status (never "OK" unless the status is ok).
Returns None when it cannot answer -> the caller asks the AI.

member dicts: {user_id, name, label, relation, state, reason, place_label,
               last_seen (ISO), battery, paused}
answer: {text, member_user_id, action: none|open_member|call|location}
"""
import re
from datetime import datetime, timezone

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")

# relation -> words a family uses (lowercase / Bangla)
RELATION_WORDS = {
    "mother": ("ammu", "amma", "ammi", "ma", "maa", "mom", "mum", "mummy", "mother",
               "আম্মু", "আম্মা", "আম্মি", "মা", "মামণি"),
    "father": ("abbu", "abba", "baba", "bapi", "dad", "daddy", "father", "papa",
               "আব্বু", "আব্বা", "বাবা", "বাপি"),
    "son": ("son", "chele", "chhele", "cheley", "bacha", "ছেলে"),
    "daughter": ("daughter", "meye", "maye", "mey", "মেয়ে", "মেয়ে"),
    "spouse": ("wife", "husband", "bou", "bow", "swami", "বউ", "বৌ", "স্ত্রী", "স্বামী"),
    "brother": ("brother", "bhai", "bhaiya", "vai", "ভাই", "ভাইয়া"),
    "sister": ("sister", "bon", "apu", "apa", "didi", "বোন", "আপু", "আপা", "দিদি"),
    "grandparent": ("dadu", "nanu", "dadi", "nani", "grandma", "grandpa", "granny",
                    "দাদু", "নানু", "দাদি", "নানি"),
}
WHERE = ("where", "location", "kothay", "kothai", "kotay", "koi", "kon jaygay",
         "কোথায়", "কোথায়", "কই", "লোকেশন")
OKQ = ("ok", "okay", "fine", "safe", "alright", "all right", "doing", "how is", "hows",
       "thik", "theek", "valo", "bhalo", "nirapod", "kemon",
       "ঠিক", "ভালো", "ভাল", "নিরাপদ", "কেমন")
BATTERY = ("battery", "charge", "charj", "ব্যাটারি", "চার্জ")
WHEN = ("last seen", "when", "kokhon", "shesh khobor", "কখন", "শেষ খবর")
ALL = ("everyone", "everybody", "all", "family", "sobai", "shobai", "sokole",
       "সবাই", "সকলে", "পরিবার")
_SUFFIX = ("দের", "এর", "ের", "র", "কে", "রা", "টা", "টি")
_ROM_SUFFIX = ("er", "r", "ke", "ra")


def bn_num(v):
    return str(v).translate(_BN)


def norm(q):
    q = str(q or "").lower()
    q = re.sub(r"[?？!।,.;:\"'()\-]+", " ", q)
    return re.sub(r"\s+", " ", q).strip()


def _has(text, words):
    toks = set(text.split())
    for w in words:
        if " " in w:
            if w in text:
                return True
        elif w in toks or any(_stem(t) == w for t in toks):
            return True
    return False


def _stem(tok):
    for s in _SUFFIX:
        if tok.endswith(s) and len(tok) > len(s) + 1:
            return tok[: -len(s)]
    if re.fullmatch(r"[a-z]+", tok):
        for s in _ROM_SUFFIX:
            if tok.endswith(s) and len(tok) > len(s) + 2:
                return tok[: -len(s)]
    return tok


def _name_keys(m):
    keys = set()
    for v in (m.get("label"), m.get("name")):
        v = norm(v)
        if v:
            keys.add(v)
            keys.add(v.split(" ")[0])
    return {k for k in keys if len(k) >= 2}


def find_members(text, members):
    """Members the question names: by label / name first, then relation."""
    toks = text.split()
    stems = {_stem(t) for t in toks} | set(toks)
    hits = []
    for m in members:
        for k in _name_keys(m):
            if (" " in k and k in text) or k in stems:
                hits.append(m)
                break
    if hits:
        return hits
    for rel, words in RELATION_WORDS.items():
        ws = {w.rstrip("_") for w in words}
        if stems & ws:
            # a member matches by relation, or because their LABEL is one of
            # this relation's words ("আম্মু" answers a romanized "ammu")
            hits = [m for m in members if (m.get("relation") or "") == rel or
                    (_name_keys(m) & ws)]
            if hits:
                return hits
    return []


def _relation_word(text):
    for t in text.split():
        st = _stem(t)
        for words in RELATION_WORDS.values():
            ws = {w.rstrip("_") for w in words}
            if t in ws or st in ws:
                return t
    return ""


def _age(last_seen, now, lang):
    try:
        d = datetime.fromisoformat(str(last_seen).replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return ""
    s = max(0, int((now - d).total_seconds()))
    en = lang == "en"
    if s < 90:
        return "just now" if en else "এইমাত্র"
    if s < 3600:
        n = s // 60
        return ("%d min ago" % n) if en else ("%s মিনিট আগে" % bn_num(n))
    if s < 86400:
        n = s // 3600
        return ("%d h ago" % n) if en else ("%s ঘণ্টা আগে" % bn_num(n))
    n = s // 86400
    return ("%d days ago" % n) if en else ("%s দিন আগে" % bn_num(n))


REASON_BN = {"battery_off": "চার্জ শেষ হয়ে ফোন বন্ধ হতে পারে",
             "no_internet": "ইন্টারনেট নেই",
             "background_killed": "ফোন ব্যাকগ্রাউন্ডে Assisto বন্ধ করে দিচ্ছে",
             "never": "Assisto এখনো খবর পাঠায়নি", "clock": "ফোনের ঘড়ি ভুল",
             "battery_low": "চার্জ কম", "watch": "অনেকক্ষণ কোনো সাড়া নেই",
             "carecall_missed": "কেয়ার কল ধরেননি", "journey_overdue": "যাত্রায় দেরি হচ্ছে"}
REASON_EN = {"battery_off": "the battery may have run out", "no_internet": "no internet",
             "background_killed": "the phone is stopping Assisto in the background",
             "never": "Assisto has not reported yet", "clock": "the phone clock is wrong",
             "battery_low": "battery is low", "watch": "no response for a long time",
             "carecall_missed": "missed a Care Call", "journey_overdue": "a journey is late"}


def _reason(r, lang):
    return (REASON_EN if lang == "en" else REASON_BN).get(r or "", "")


_AT_BN = {"বাড়ি": "বাড়িতে", "স্কুল": "স্কুলে", "অফিস": "অফিসে", "কলেজ": "কলেজে",
          "মাদ্রাসা": "মাদ্রাসায়", "দোকান": "দোকানে"}


def at_bn(place):
    """Natural Bangla locative: বাড়ি -> বাড়িতে, স্কুল -> স্কুলে, else "X-এ"."""
    p = str(place or "").strip()
    return _AT_BN.get(p, "%s-এ" % p)


def _ok_answer(m, lang, now):
    en, n = lang == "en", (m.get("label") or m.get("name") or "")
    st = m.get("state") or "stale"
    age = _age(m.get("last_seen"), now, lang)
    if st == "sos":
        return {"text": ("%s pressed SOS. Call now." % n) if en else ("%s SOS চেপেছেন। এখনই ফোন করুন।" % n),
                "member_user_id": m["user_id"], "action": "call"}
    if st == "paused" or m.get("paused"):
        return {"text": ("%s has paused sharing for now." % n) if en
                else ("%s এখন শেয়ারিং বিরতিতে রেখেছেন।" % n),
                "member_user_id": m["user_id"], "action": "call"}
    if st == "ok":
        where = m.get("place_label") or ""
        if en:
            t = "Yes, %s is OK (last news %s%s)." % (n, age, (", at %s" % where) if where else "")
        else:
            t = "হ্যাঁ, %s ঠিক আছেন (শেষ খবর %s%s)।" % (n, age, (", %s" % at_bn(where)) if where else "")
        return {"text": t, "member_user_id": m["user_id"], "action": "open_member"}
    if st == "check":
        r = _reason(m.get("reason"), lang)
        return {"text": ("Check on %s: %s." % (n, r)) if en else ("%s-কে একবার দেখুন: %s।" % (n, r)),
                "member_user_id": m["user_id"], "action": "call"}
    r = _reason(m.get("reason"), lang)
    if en:
        t = "No fresh news from %s%s%s. Call to be sure." % (
            n, (" (last %s)" % age) if age else "", ("; %s" % r) if r else "")
    else:
        t = "%s-এর কাছ থেকে নতুন খবর নেই%s%s। নিশ্চিত হতে ফোন করুন।" % (
            n, (" (শেষ খবর %s)" % age) if age else "", ("; %s" % r) if r else "")
    return {"text": t, "member_user_id": m["user_id"], "action": "call"}


def _where_answer(m, lang, now):
    en, n = lang == "en", (m.get("label") or m.get("name") or "")
    if m.get("state") == "paused" or m.get("paused"):
        return {"text": ("%s has paused sharing, so Assisto does not show a place." % n) if en
                else ("%s শেয়ারিং বিরতিতে রেখেছেন, তাই জায়গা দেখানো হচ্ছে না।" % n),
                "member_user_id": m["user_id"], "action": "call"}
    place = m.get("place_label") or ""
    age = _age(m.get("last_seen"), now, lang)
    fresh = m.get("state") in ("ok", "check", "sos")
    if place and fresh:
        return {"text": ("%s is at %s (news %s)." % (n, place, age)) if en
                else ("%s এখন %s (খবর %s)।" % (n, at_bn(place), age)),
                "member_user_id": m["user_id"], "action": "location"}
    if place:
        return {"text": ("%s was last at %s, %s. No fresh news since." % (n, place, age)) if en
                else ("%s শেষবার %s ছিলেন, %s। এরপর নতুন খবর নেই।" % (n, at_bn(place), age)),
                "member_user_id": m["user_id"], "action": "call"}
    return {"text": ("Assisto does not know where %s is right now%s." % (n, (" (last news %s)" % age) if age else "")) if en
            else ("%s এখন কোথায় Assisto জানে না%s।" % (n, (" (শেষ খবর %s)" % age) if age else "")),
            "member_user_id": m["user_id"], "action": "open_member"}


def _battery_answer(m, lang, now):
    en, n = lang == "en", (m.get("label") or m.get("name") or "")
    b = m.get("battery")
    if m.get("paused") or m.get("state") == "paused" or b is None:
        return {"text": ("Assisto does not know %s's battery right now." % n) if en
                else ("%s-এর চার্জ এখন জানা নেই।" % n), "member_user_id": m["user_id"], "action": "open_member"}
    age = _age(m.get("last_seen"), now, lang)
    return {"text": ("%s's phone was at %d%% (%s)." % (n, b, age)) if en
            else ("%s-এর ফোনে চার্জ ছিল %s%% (%s)।" % (n, bn_num(b), age)),
            "member_user_id": m["user_id"], "action": "open_member"}


def _when_answer(m, lang, now):
    en, n = lang == "en", (m.get("label") or m.get("name") or "")
    age = _age(m.get("last_seen"), now, lang)
    if not age:
        return {"text": ("No news from %s yet." % n) if en else ("%s-এর কাছ থেকে এখনো কোনো খবর আসেনি।" % n),
                "member_user_id": m["user_id"], "action": "call"}
    return {"text": ("Last news from %s: %s." % (n, age)) if en else ("%s-এর শেষ খবর: %s।" % (n, age)),
            "member_user_id": m["user_id"], "action": "open_member"}


def _all_answer(members, lang, now):
    en = lang == "en"
    if not members:
        return {"text": "No family members yet." if en else "পরিবারে এখনো কেউ নেই।",
                "member_user_id": None, "action": "none"}
    order = {"sos": 0, "check": 1, "stale": 2, "paused": 3, "ok": 4}
    bad = sorted([m for m in members if m.get("state") != "ok"],
                 key=lambda m: order.get(m.get("state"), 2))
    if not bad:
        return {"text": "Yes, everyone is OK with fresh news." if en
                else "হ্যাঁ, সবাই ঠিক আছেন — সবার তাজা খবর আছে।",
                "member_user_id": None, "action": "none"}
    a = _ok_answer(bad[0], lang, now)
    if len(bad) > 1:
        more = len(bad) - 1
        a["text"] += (" (+%d more to check)" % more) if en else (" (আরও %s জন)" % bn_num(more))
    return a


def answer(q, members, lang="bn", now=None):
    """-> answer dict or None (not understood -> AI)."""
    now = now or datetime.now(timezone.utc)
    text = norm(q)
    if not text:
        return None
    members = [m for m in (members or []) if isinstance(m, dict) and m.get("user_id") is not None]
    hits = find_members(text, members)
    intent = None
    if _has(text, BATTERY):
        intent = "battery"
    elif _has(text, WHERE):
        intent = "where"
    elif _has(text, WHEN):
        intent = "when"
    elif _has(text, OKQ):
        intent = "ok"
    if not hits:
        if intent == "ok" and _has(text, ALL):
            return _all_answer(members, lang, now)
        word = _relation_word(text)
        if word and intent is not None:
            return {"text": ("Nobody in your family list is \"%s\". Add them from My Circle." % word)
                    if lang == "en" else
                    ("আপনার পরিবারের তালিকায় \"%s\" নেই। My Circle থেকে যোগ করুন।" % word),
                    "member_user_id": None, "action": "none"}
        return None
    if intent is None:
        if len(text.split()) > 3:
            return None           # a long sentence about someone: let the AI read it
        intent = "ok"
    if len(hits) > 1 and len({h["user_id"] for h in hits}) > 1:
        names = ", ".join((h.get("label") or h.get("name") or "") for h in hits[:4])
        return {"text": ("Who do you mean: %s?" % names) if lang == "en" else ("কার কথা বলছেন: %s?" % names),
                "member_user_id": None, "action": "none"}
    m = hits[0]
    return {"ok": _ok_answer, "where": _where_answer, "battery": _battery_answer,
            "when": _when_answer}[intent](m, lang, now)


def simple_status(brain, now):
    """Fallback honest status (same rule as core.logic.family_status, for
    before fcscreen merges): green only with fresh data."""
    from datetime import timedelta
    b = brain or {}
    try:
        pu = b.get("paused_until")
        if pu and datetime.fromisoformat(str(pu).replace("Z", "+00:00")) > now:
            return {"state": "paused", "reason": "paused"}
        seen = datetime.fromisoformat(str(b.get("last_seen")).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return {"state": "stale", "reason": "never"}
    iv = max(900, min(86400, int(b.get("interval_s") or 10800)))
    if now - seen > timedelta(seconds=iv):
        return {"state": "stale", "reason": "background_killed"}
    bat = b.get("battery")
    if bat is not None and bat <= 15 and not b.get("charging"):
        return {"state": "check", "reason": "battery_low"}
    return {"state": "ok", "reason": "ok"}
