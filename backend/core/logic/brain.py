"""
Assisto Brain — honest, no-AI-key answers over the user's OWN data + the app's
offline knowledge, plus a QUESTION classifier that guarantees a question is
NEVER silently saved as a note.

Design (owner A3 bug: typing "Amar kno data ace naki??" was saved as a note):
  * is_question(text)  → True when the text is a question (bn/Banglish/en).
    A question is ANSWERED, never captured.
  * is_clear_capture(parse_result) → True only for expenses / timed reminders /
    explicit "mone rakho/save/note:" prefixes. Everything else that isn't a
    known command and isn't a question is AMBIGUOUS → we ANSWER + offer a
    "Save as note" chip (we never silently save).
  * answer(user, text, lang) → a dict {reply, cards, route, handler, level}:
      L1  deterministic answers over the user's real rows (counts, balance, …)
      L2  offline knowledge base (app-help + govt/health/dictionary/medicine)
      L4  honest escalation when the question needs cloud AI and no key is set.

Everything here is deterministic and sourced to the user's own data or the
app's own data — it never fabricates a fact, number, or answer.
"""
import re

from ..i18n import pick
from . import help_kb

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def _norm(s):
    return (s or "").strip().translate(_BN_DIGITS)


# ----------------------------------------------------------------------------
# QUESTION DETECTION (bn + Banglish + en)
# ----------------------------------------------------------------------------
# Multi-word / phrase markers (checked as substrings, case-insensitive).
_Q_PHRASES = [
    # Banglish
    "ace naki", "ache ki", "ache naki", "ace ki", "ktotuku", "koto taka",
    "ki ki", "koto khoroch", "koto kharap", "kemon ace", "kemon ache",
    "how many", "how much", "how do", "how to", "how can", "what is",
    "what are", "what's", "whats", "tell me", "can you", "do i", "do you",
    "is there", "are there", "koto gula", "koyta", "koy ta",
    # Bangla
    "আছে কি", "কী কী", "কত টাকা", "কত খরচ", "কেমন আছে", "কয়টা",
]

# Single-token markers. Banglish ones are matched on whitespace/?-split tokens
# so "kal" (tomorrow) never trips "ke"/"ki". Bangla markers are substring-safe.
_Q_TOKENS_BANGLISH = {
    "ki", "kno", "kano", "keno", "kivabe", "kibhabe", "kemne", "koto", "kothay",
    "kobe", "ke", "naki", "koyta", "kon", "konta", "karon",
}
_Q_WORDS_EN = {
    "what", "why", "how", "when", "where", "who", "which", "whom", "whose",
    "is", "are", "am", "do", "does", "did", "can", "could", "should", "would",
    "will", "shall", "was", "were", "has", "have", "whats",
}
# Longer Bangla question markers that are safe to match as substrings — they do
# not appear inside common statement words.
_Q_BANGLA_SUBSTR = [
    "কেন", "কীভাবে", "কিভাবে", "কোথায়", "কবে", "নাকি", "কয়টা", "কোন",
    "কারা", "কত টাকা", "কত খরচ",
]
# Short Bangla markers that DO appear inside everyday words (e.g. "কে" inside
# "বিকেল", "কি" inside "কিনলাম") — only count them as a standalone token.
_Q_BANGLA_TOKEN = {"কি", "কী", "কে", "কত", "কোনটা"}


def _tokens(text):
    return re.findall(r"[^\s?।,.!]+", _norm(text).lower())


def is_question(text):
    """True when `text` reads as a question in bn / Banglish / en."""
    raw = (text or "").strip()
    if not raw:
        return False
    low = _norm(raw).lower()
    # 1. ends with a question mark (single or '??')
    if raw.rstrip().endswith("?"):
        return True
    # 2. phrase markers
    for ph in _Q_PHRASES:
        if ph in low or ph in raw:
            return True
    # 3. Longer Bangla question markers (safe as substrings)
    for w in _Q_BANGLA_SUBSTR:
        if w in raw:
            return True
    # 4. Short Bangla markers + Banglish / English — standalone tokens only, so
    #    "কে" inside "বিকেল" or "ki" inside a longer word never misfires.
    toks = _tokens(raw)
    if toks:
        if any(t in _Q_BANGLA_TOKEN for t in toks):
            return True
        if toks[0] in _Q_WORDS_EN:
            return True
        if any(t in _Q_TOKENS_BANGLISH for t in toks):
            return True
        if any(t in _Q_WORDS_EN for t in toks[:2]):
            return True
    return False


# ----------------------------------------------------------------------------
# CAPTURE CLARITY — only clear statements auto-save
# ----------------------------------------------------------------------------
_EXPLICIT_SAVE = [
    "mone rakho", "mone rekho", "mone rakhba", "save kore", "note koro",
    "note:", "note :", "save:", "save :", "মনে রাখো", "মনে রেখো", "মনে রাখবে",
    "নোট করো", "সেভ করো", "remember", "save this",
]

# Intents the rule parser emits that are unambiguous captures/commands.
_CLEAR_COMMAND_INTENTS = {
    "expense", "income", "loan", "medicine", "music", "navigate", "call",
    "nearby", "query_money", "query_today",
}


def has_explicit_save(text):
    low = _norm(text).lower()
    return any(p in low or p in text for p in _EXPLICIT_SAVE)


def is_clear_capture(parse_result, text):
    """True when the parser's result is a clear, auto-saveable capture:
    an expense/income/loan/medicine, a reminder WITH a time, or an explicit
    'mone rakho/save/note:' memory. A bare free-text 'memory' is NOT clear."""
    intent = (parse_result or {}).get("intent")
    if intent in ("expense", "income", "loan"):
        return True
    if intent == "medicine":
        return True
    if intent == "reminder":
        # only auto-save a reminder when we actually resolved a time
        return bool(parse_result.get("due"))
    if intent == "memory":
        return has_explicit_save(text)
    return False


# ----------------------------------------------------------------------------
# ASSISTO BRAIN — deterministic answers
# ----------------------------------------------------------------------------
# L1 question routing: which data summary a question is asking for.
_WANT_OVERVIEW = [
    "kno data", "kon data", "ki data", "data ace", "data ache", "data achhe",
    "ki ki data", "amar data", "ki ki ace", "ki ki ache", "koyta data",
    "my data", "what data", "what do you know", "what you know",
    "ki jano", "ki jan", "kemon data", "koto data",
    "কী ডেটা", "কি ডেটা", "ডেটা আছে", "কী কী আছে", "আমার ডেটা", "কী জানো",
]
_WANT_MONEY = [
    "koto taka", "koto khoroch", "ei mase koto", "balance", "khoroch koto",
    "how much", "my balance", "total khoroch", "koto income", "koto ay",
    "কত টাকা", "কত খরচ", "ব্যালেন্স", "এ মাসে কত", "এই মাসে কত", "কত আছে",
]
_WANT_REMINDERS = [
    "reminder gula", "reminder gulo", "amar reminder", "ki reminder",
    "reminder ki", "upcoming reminder", "my reminders", "what reminders",
    "রিমাইন্ডার গুলা", "রিমাইন্ডার গুলো", "আমার রিমাইন্ডার", "কী রিমাইন্ডার",
]
_WANT_TODOS = [
    "amar todo", "todo gula", "todo gulo", "koyta kaj", "ki kaj baki",
    "my todos", "my tasks", "what tasks", "kaj gula",
    "আমার টুডু", "কাজ গুলা", "কয়টা কাজ", "কী কাজ বাকি",
]


def _has(text, words):
    low = _norm(text).lower()
    return any(w in low or w in text for w in words)


def _route_question(text):
    """Pick which L1 handler (if any) a question is asking for."""
    # overview must win over the broad money/reminder markers it may contain
    if _has(text, _WANT_OVERVIEW):
        return "overview"
    if _has(text, _WANT_REMINDERS):
        return "reminders"
    if _has(text, _WANT_TODOS):
        return "todos"
    if _has(text, _WANT_MONEY):
        return "money"
    return None


def _money_summary(user):
    """(total_balance, month_income, month_expense) as Decimals — mirrors
    MoneySummaryView's math without the HTTP layer."""
    from decimal import Decimal
    from django.db.models import Sum
    from django.utils import timezone

    def dec(x):
        return x or Decimal("0")

    now = timezone.localtime()
    y, m = now.year, now.month
    total = Decimal("0")
    for a in user.accounts.all():
        inc = dec(a.txns.filter(kind="income").aggregate(s=Sum("amount"))["s"])
        exp = dec(a.txns.filter(kind="expense").aggregate(s=Sum("amount"))["s"])
        tout = dec(a.txns.filter(kind="transfer").aggregate(s=Sum("amount"))["s"])
        tin = dec(a.txns_in.filter(kind="transfer").aggregate(s=Sum("amount"))["s"])
        total += a.opening_balance + inc - exp - tout + tin
    mt = user.txns.filter(date__year=y, date__month=m)
    m_inc = dec(mt.filter(kind="income").aggregate(s=Sum("amount"))["s"])
    m_exp = dec(mt.filter(kind="expense").aggregate(s=Sum("amount"))["s"])
    return total, m_inc, m_exp


def _l1_overview(user, lang):
    """A real summary of everything Assisto holds for this user, with counts
    and links. Numbers come from the user's own rows — never invented."""
    from django.utils import timezone
    today = timezone.localdate()

    reminders = user.reminders.filter(done=False)
    rem_n = reminders.count()
    next_rem = reminders.filter(due_at__isnull=False, due_at__gte=timezone.now()) \
        .order_by("due_at").first()
    total, m_inc, m_exp = _money_summary(user)
    notes_n = user.notes.count()
    todos_n = user.todos.filter(done=False).count()
    mem_n = user.memories.count()
    contacts_n = user.contacts.count()
    docs = user.documents.all()
    docs_n = docs.count()
    expiring = sum(1 for d in docs if d.expiry_date and 0 <= (d.expiry_date - today).days <= 30)
    devices_n = user.protected_phones.count()
    circle_n = user.circle_members.filter(state="accepted").count()
    acc_n = user.accounts.count()

    # honest empty state
    everything = (rem_n + notes_n + todos_n + mem_n + contacts_n + docs_n +
                  devices_n + circle_n + acc_n + (1 if (m_inc or m_exp) else 0))
    if everything == 0:
        reply = pick(lang,
                     "এখনও আপনার কোনো ডেটা জমা নেই। চ্যাটে খরচ, রিমাইন্ডার বা নোট "
                     "যোগ করা শুরু করুন — যেমন '৫০০ টাকা বাজার' বা "
                     "'কাল ৯টায় মিটিং মনে করিয়ে দিও'।",
                     "You don't have any data saved yet. Start adding expenses, "
                     "reminders or notes in chat — e.g. '500 taka bazar' or "
                     "'remind me about the meeting at 9am tomorrow'.")
        cards = [{"type": "summary",
                  "title": pick(lang, "কোনো ডেটা নেই", "No data yet"),
                  "subtitle": pick(lang, "যোগ করা শুরু করুন",
                                   "Start adding your details")}]
        return reply, cards, None

    def _n(bn_label, en_label, n, extra_bn="", extra_en=""):
        return pick(lang,
                    f"• {bn_label}: {n}{extra_bn}",
                    f"• {en_label}: {n}{extra_en}")

    next_bn = next_en = ""
    if next_rem and next_rem.due_at:
        when = timezone.localtime(next_rem.due_at).strftime("%d %b %H:%M")
        next_bn = pick(lang, f" (পরেরটি {when})", "")
        next_en = pick(lang, "", f" (next {when})")
    exp_bn = f" ({expiring} মেয়াদ শেষের পথে)" if expiring else ""
    exp_en = f" ({expiring} expiring soon)" if expiring else ""

    lines = [
        pick(lang, "আপনার Assisto-তে যা আছে:", "Here's what's in your Assisto:"),
        _n("রিমাইন্ডার", "Reminders", rem_n, next_bn, next_en),
        pick(lang,
             f"• টাকা: ব্যালেন্স ৳{total}, এ মাসে খরচ ৳{m_exp}, আয় ৳{m_inc}",
             f"• Money: balance ৳{total}, this month spent ৳{m_exp}, earned ৳{m_inc}"),
        _n("নোট", "Notes", notes_n),
        _n("টুডু (বাকি)", "Todos (open)", todos_n),
        _n("মেমোরি আইটেম", "Memory items", mem_n),
        _n("কন্টাক্ট", "Contacts", contacts_n),
        _n("ডকুমেন্ট", "Documents", docs_n, exp_bn, exp_en),
        _n("ডিভাইস", "Devices", devices_n),
        _n("Circle সদস্য", "Circle members", circle_n),
    ]
    reply = "\n".join(lines)
    cards = [
        {"type": "summary", "route": "reminders",
         "title": pick(lang, f"রিমাইন্ডার: {rem_n}", f"Reminders: {rem_n}"),
         "subtitle": pick(lang, "দেখতে ট্যাপ করুন", "Tap to view")},
        {"type": "summary", "route": "money",
         "title": pick(lang, f"ব্যালেন্স ৳{total}", f"Balance ৳{total}"),
         "subtitle": pick(lang, f"এ মাসে খরচ ৳{m_exp}", f"Spent ৳{m_exp} this month")},
        {"type": "summary", "route": "documents",
         "title": pick(lang, f"ডকুমেন্ট: {docs_n}", f"Documents: {docs_n}"),
         "subtitle": pick(lang, f"{expiring} মেয়াদ শেষের পথে" if expiring else "ভল্ট",
                          f"{expiring} expiring soon" if expiring else "Vault")},
    ]
    return reply, cards, None


def _l1_money(user, lang):
    total, m_inc, m_exp = _money_summary(user)
    reply = pick(lang,
                 f"মোট ব্যালেন্স ৳{total}। এ মাসে খরচ ৳{m_exp}, আয় ৳{m_inc}।",
                 f"Total balance ৳{total}. This month: spent ৳{m_exp}, earned ৳{m_inc}.")
    cards = [{"type": "summary", "route": "money",
              "title": pick(lang, f"ব্যালেন্স ৳{total}", f"Balance ৳{total}"),
              "subtitle": pick(lang, f"খরচ ৳{m_exp} · আয় ৳{m_inc}",
                               f"Spent ৳{m_exp} · Earned ৳{m_inc}")}]
    return reply, cards, "money"


def _l1_reminders(user, lang):
    from django.utils import timezone
    up = list(user.reminders.filter(done=False).order_by("due_at", "-updated_at")[:8])
    if not up:
        reply = pick(lang, "আপনার কোনো রিমাইন্ডার নেই।",
                     "You don't have any reminders.")
        return reply, [{"type": "summary", "route": "reminders",
                        "title": pick(lang, "রিমাইন্ডার নেই", "No reminders"),
                        "subtitle": pick(lang, "যোগ করতে বলুন", "Ask me to add one")}], "reminders"
    lines = [pick(lang, "আপনার রিমাইন্ডার:", "Your reminders:")]
    for r in up:
        when = (timezone.localtime(r.due_at).strftime("%d %b %H:%M")
                if r.due_at else pick(lang, "সময় ছাড়া", "no time"))
        lines.append(f"• {r.title} — {when}")
    reply = "\n".join(lines)
    cards = [{"type": "summary", "route": "reminders",
              "title": pick(lang, f"{len(up)}টি রিমাইন্ডার", f"{len(up)} reminders"),
              "subtitle": pick(lang, "দেখতে ট্যাপ করুন", "Tap to view")}]
    return reply, cards, "reminders"


def _l1_todos(user, lang):
    open_t = list(user.todos.filter(done=False).order_by("-updated_at")[:8])
    if not open_t:
        reply = pick(lang, "আপনার কোনো বাকি কাজ নেই।", "You have no open tasks.")
        return reply, [{"type": "summary", "route": "todos",
                        "title": pick(lang, "কাজ নেই", "No tasks"),
                        "subtitle": pick(lang, "সব শেষ!", "All done!")}], "todos"
    lines = [pick(lang, "আপনার বাকি কাজ:", "Your open tasks:")]
    lines += [f"• {t.title}" for t in open_t]
    reply = "\n".join(lines)
    cards = [{"type": "summary", "route": "todos",
              "title": pick(lang, f"{len(open_t)}টি কাজ বাকি", f"{len(open_t)} open tasks"),
              "subtitle": pick(lang, "দেখতে ট্যাপ করুন", "Tap to view")}]
    return reply, cards, "todos"


def _l2_knowledge(text, lang):
    """Offline knowledge base: app-help first, then the existing govt / health /
    medicine / dictionary data. Returns (reply, cards) or None."""
    # 1. app-help KB (how do I ... )
    hk = help_kb.match(text, lang)
    if hk:
        return hk["answer"], [{"type": "help", "route": hk["route"],
                               "title": pick(lang, "অ্যাপ সহায়িকা", "App help"),
                               "subtitle": pick(lang, "স্ক্রিন খুলতে ট্যাপ", "Tap to open")}]
    # 2. govt services
    try:
        from . import govt_guide
        hits = govt_guide.search(text, lang)
        if hits:
            s = hits[0]
            steps = s.get("steps") or []
            body = "; ".join(steps[:4]) if steps else ""
            reply = pick(lang,
                         f"{s['name']}: {body}\nসূত্র: {s.get('portal','')} — "
                         "সর্বশেষ নিয়ম অফিসিয়াল পোর্টালে যাচাই করুন।",
                         f"{s['name']}: {body}\nSource: {s.get('portal','')} — "
                         "confirm current rules on the official portal.")
            return reply, [{"type": "guide", "route": "guides",
                            "title": s["name"],
                            "subtitle": s.get("portal", ""),
                            "url": s.get("url", "")}]
    except Exception:
        pass
    # 3. health tips
    try:
        from . import health_tips
        tips = health_tips.tips(lang=lang, query=text)
        if tips:
            tp = tips[0]
            title = tp.get("title") or tp.get("topic") or ""
            body = tp.get("body") or tp.get("summary") or ""
            src = health_tips.source_name(tp.get("source", ""), lang) \
                if tp.get("source") else ""
            reply = f"{title}: {body}".strip(": ")
            if src:
                reply += pick(lang, f"\nসূত্র: {src}", f"\nSource: {src}")
            reply += pick(lang, "\n(জরুরি হলে ৯৯৯ বা চিকিৎসকের পরামর্শ নিন।)",
                          "\n(In an emergency call 999 or see a doctor.)")
            return reply, [{"type": "health", "route": "health",
                            "title": title or pick(lang, "স্বাস্থ্য পরামর্শ", "Health tip"),
                            "subtitle": src}]
    except Exception:
        pass
    return None


def _l4_needs_ai(lang):
    return pick(lang,
                "এই প্রশ্নের জন্য AI সহকারী দরকার (মালিক এখনও key যোগ করেননি)। "
                "তবে আমি এখনও আপনার নিজের ডেটা ও অ্যাপ নিয়ে সব প্রশ্নের উত্তর দিতে পারি।",
                "This needs the AI assistant (owner hasn't added the key yet). "
                "I can still answer about YOUR data and the app.")


def answer(user, text, lang="bn"):
    """Answer a question with no AI key. Returns a dict:
      {reply, cards, route, handler, level}
    `handler` names the branch that answered; `level` is 'L1'|'L2'|'L4'.
    Never returns an empty reply, never saves anything."""
    text = (text or "").strip()
    # L1 — the user's own data
    want = _route_question(text)
    if want == "overview":
        reply, cards, route = _l1_overview(user, lang)
        return {"reply": reply, "cards": cards, "route": route,
                "handler": "data_overview", "level": "L1"}
    if want == "money":
        reply, cards, route = _l1_money(user, lang)
        return {"reply": reply, "cards": cards, "route": route,
                "handler": "money", "level": "L1"}
    if want == "reminders":
        reply, cards, route = _l1_reminders(user, lang)
        return {"reply": reply, "cards": cards, "route": route,
                "handler": "reminders", "level": "L1"}
    if want == "todos":
        reply, cards, route = _l1_todos(user, lang)
        return {"reply": reply, "cards": cards, "route": route,
                "handler": "todos", "level": "L1"}

    # L2 — offline knowledge base
    kb = _l2_knowledge(text, lang)
    if kb:
        reply, cards = kb
        route = cards[0].get("route") if cards else None
        return {"reply": reply, "cards": cards, "route": route,
                "handler": "knowledge", "level": "L2"}

    # L4 — needs cloud AI, which is off
    return {"reply": _l4_needs_ai(lang), "cards": [], "route": None,
            "handler": "needs_ai", "level": "L4"}


def save_note_card(text, lang="bn"):
    """The 'Save as note' affordance offered for ambiguous text. Reuses the
    existing card shape; the app re-sends the phrase with an explicit save
    prefix (or hits the notes screen) to actually save it. We NEVER save here."""
    return {"type": "save_note", "route": "notes",
            "title": pick(lang, "নোট হিসেবে রাখব?", "Save as a note?"),
            "subtitle": (text[:80] + ("…" if len(text) > 80 else "")),
            "app_action": "save_note", "save_text": text}
