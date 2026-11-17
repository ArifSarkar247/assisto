"""Owner AI chat rebuild (4 Nov 01:02 + 01:05): ACTIONS only through the
model, and never written without the user's Yes.

The old home path ran a regex / keyword intent parser BEFORE the AI and wrote
straight into the user's data ("remind me tomorrow at 9 am to take the gas
tablet" -> "Logged your expense, 9 BDT"). Now the message always goes to the
model; when the user clearly asks to save something, the MODEL proposes it
(a provider-neutral tool call: one `ACTION: {json}` line at the end of its
answer), the server validates the proposal against this fixed list, strips the
line from the answer and shows a CONFIRM card ("Set reminder tomorrow 09:00?
Yes / No"). Only POST /agent/confirm with yes=true writes — tagged source="ai"
so the one-tap clean-up can find it.

Allowed tools: expense, income, reminder, note, profile_name."""
import json
import re
import secrets
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation

from django.db import transaction
from django.utils import timezone

from .i18n import pick

PENDING = "ai_pending"
TTL_HOURS = 24
TOOLS = ("expense", "income", "reminder", "note", "profile_name")
_LINE = re.compile(r"^\s*ACTION\s*:\s*(\{.*\})\s*$", re.M)

TOOL_RULE = (
    "Saving in the app: ONLY when the user clearly asks you to save something — an "
    "expense or income, a reminder, a note to remember, or their own name — add ONE "
    "last line exactly like: ACTION: {\"type\": \"reminder\", \"title\": \"...\", "
    "\"due\": \"YYYY-MM-DDTHH:MM\"} (types: expense / income with \"amount\" and "
    "\"category\"; reminder with \"title\" and \"due\" in local time; note with "
    "\"title\"; profile_name with \"name\"). A number inside a reminder (\"at 9 am\") "
    "is a TIME, never money. Never say it is saved — the user confirms with a "
    "button first. No ACTION line for questions, feelings, translations or chat. "
    # gap-aichat2 (live 10338: expense messages got no confirm card): the
    # common money cases, said explicitly — the line is the ONLY way the app
    # can show the Yes button.
    "When the user tells you an amount they spent or earned and asks to log / "
    "save / write it (e.g. 'চায়ে ৫০ টাকা খরচ লিখে রাখো', '50 tk khoroch likhe "
    "rakho', 'spent 200 taka on lunch, note it', 'বেতন ২০০০০ টাকা পেলাম লিখে রাখো') "
    "you MUST end with ONE line like ACTION: {\"type\": \"expense\", \"amount\": 50, "
    "\"category\": \"চা\"} (income for money received). Write the amount with "
    "ASCII digits (৫০ -> 50). Without that line nothing can be saved.")


def extract(reply):
    """(clean_reply, proposal or None). The ACTION line never reaches the user."""
    m = None
    for m in _LINE.finditer(reply or ""):
        pass
    if m is None:
        return reply, None
    clean = (reply[:m.start()] + reply[m.end():]).strip()
    try:
        raw = json.loads(m.group(1))
    except ValueError:
        return clean, None
    return clean, validate(raw)


def _amount(v):
    try:
        a = Decimal(str(v)).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError):
        return None
    return a if Decimal("0") < a < Decimal("100000000") else None


def _due(v, now=None):
    s = str(v or "").strip()[:16]
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
        try:
            d = datetime.strptime(s, fmt)
            return timezone.make_aware(d) if timezone.is_naive(d) else d
        except ValueError:
            continue
    return None


def validate(raw):
    """A clean proposal dict or None (anything off the list is dropped)."""
    if not isinstance(raw, dict):
        return None
    t = str(raw.get("type") or "")
    if t not in TOOLS:
        return None
    if t in ("expense", "income"):
        a = _amount(raw.get("amount"))
        if a is None:
            return None
        return {"type": t, "amount": str(a), "category": str(raw.get("category") or "")[:60]}
    if t == "reminder":
        title = str(raw.get("title") or "").strip()[:200]
        if not title:
            return None
        due = _due(raw.get("due"))
        return {"type": t, "title": title, "due": due.isoformat() if due else ""}
    if t == "note":
        title = str(raw.get("title") or "").strip()[:200]
        return {"type": t, "title": title} if title else None
    name = " ".join(str(raw.get("name") or "").split())[:60]
    return {"type": t, "name": name} if name else None


def summary(p, lang):
    """The question on the confirm card."""
    t = p["type"]
    if t == "expense":
        return pick(lang, "খরচ ৳%s লিখে রাখব?" % p["amount"], "Save expense ৳%s?" % p["amount"])
    if t == "income":
        return pick(lang, "আয় ৳%s লিখে রাখব?" % p["amount"], "Save income ৳%s?" % p["amount"])
    if t == "reminder":
        when = ""
        if p.get("due"):
            d = timezone.localtime(datetime.fromisoformat(p["due"]))
            when = d.strftime("%Y-%m-%d %H:%M")
        return pick(lang, "রিমাইন্ডার সেট করব: “%s” %s?" % (p["title"], when),
                    "Set reminder: “%s” %s?" % (p["title"], when))
    if t == "note":
        return pick(lang, "নোট হিসেবে রাখব: “%s”?" % p["title"], "Save as a note: “%s”?" % p["title"])
    return pick(lang, "আপনার নাম “%s” হিসেবে বদলাব?" % p["name"],
                "Change your name to “%s”?" % p["name"])


def propose(user, proposal, lang, now=None):
    """Store the proposal; return the confirm card (nothing is written yet)."""
    from .models import PaCollectionItem
    now = now or timezone.now()
    pid = secrets.token_urlsafe(12)
    PaCollectionItem.objects.create(user=user, collection=PENDING, data={
        "id": pid, "p": proposal, "at": now.isoformat(), "lang": lang})
    return {"type": "confirm_action", "pending_id": pid, "action": proposal["type"],
            "title": summary(proposal, lang),
            "yes": pick(lang, "হ্যাঁ", "Yes"), "no": pick(lang, "না", "No")}


def confirm(user, pid, yes, now=None):
    """(status, body). Executes a pending proposal ONCE on Yes."""
    from .models import PaCollectionItem
    now = now or timezone.now()
    with transaction.atomic():
        row = (PaCollectionItem.objects.select_for_update()
               .filter(user=user, collection=PENDING, data__id=str(pid)[:40]).first())
        if row is None:
            return 404, {"ok": False, "reason": "not_found"}
        d = dict(row.data or {})
        lang = d.get("lang") or "bn"
        at = datetime.fromisoformat(d.get("at")) if d.get("at") else now
        row.delete()
        if now - at > timedelta(hours=TTL_HOURS):
            return 410, {"ok": False, "reason": "expired"}
        if not yes:
            return 200, {"ok": True, "done": False,
                         "message": pick(lang, "ঠিক আছে, কিছু সেভ করিনি।", "OK — nothing was saved.")}
        card = _execute(user, d["p"], lang, now)
    return 200, {"ok": True, "done": True, "card": card,
                 "message": pick(lang, "সেভ করেছি।", "Saved.")}


def _execute(user, p, lang, now):
    from .models import Account, MemoryItem, Reminder, Transaction
    t = p["type"]
    if t in ("expense", "income"):
        acc = user.accounts.first() or Account.objects.create(user=user, name="ক্যাশ",
                                                              acc_type="cash")
        tx = Transaction.objects.create(user=user, account=acc, kind=t,
                                        amount=Decimal(p["amount"]), category=p.get("category", ""),
                                        date=timezone.localdate(), source="ai")
        return {"type": t, "title": "৳%s %s" % (p["amount"], p.get("category", "")),
                "model": "txn", "id": tx.id, "undo": True}
    if t == "reminder":
        due = datetime.fromisoformat(p["due"]) if p.get("due") else None
        r = Reminder.objects.create(user=user, title=p["title"], due_at=due, source="ai",
                                    remind_before_min=0)
        return {"type": "reminder", "title": p["title"], "model": "reminder", "id": r.id,
                "undo": True}
    if t == "note":
        m = MemoryItem.objects.create(user=user, title=p["title"], source="ai", needs_review=False)
        return {"type": "memory", "title": p["title"], "model": "memory", "id": m.id, "undo": True}
    user.name = p["name"]
    user.save(update_fields=["name"])
    return {"type": "profile", "title": p["name"]}


# ------------------------------------------------------------------ profile
def profile_line(user):
    """Minimal profile for every turn: first name, preferred language, city
    (if the user set one), plan level. NEVER phone, money or location."""
    if user is None:
        return ""
    first = ((user.name or "").strip().split() or [""])[0][:40]
    lang = getattr(user, "language", "") or ""
    city = ""
    for f in ("city", "home_city"):
        v = getattr(user, f, "") or ""
        if v:
            city = str(v)[:40]
            break
    try:
        from . import plans
        plan = plans.effective_plan(user)
    except Exception:  # noqa: BLE001
        plan = ""
    parts = ["first name: %s" % first if first else "",
             "preferred language: %s" % lang if lang else "",
             "city: %s" % city if city else "", "plan: %s" % plan if plan else ""]
    return "User profile — " + "; ".join(p for p in parts if p) if any(parts) else ""


# ------------------------------------------------------------------ clean-up
def agent_entries(user, days=14, now=None):
    """Entries the AI chat wrote for this user (source="ai") — for the one-tap
    clean-up of the old parser's false entries."""
    from .models import Reminder, Transaction
    now = now or timezone.now()
    since = now - timedelta(days=days)
    out = []
    for t in Transaction.objects.filter(user=user, source="ai", created_at__gte=since):
        out.append({"model": "txn", "id": t.id, "title": "৳%s %s" % (t.amount, t.category),
                    "kind": t.kind, "at": t.created_at.isoformat()})
    for r in Reminder.objects.filter(user=user, source="ai", created_at__gte=since):
        out.append({"model": "reminder", "id": r.id, "title": r.title,
                    "at": r.created_at.isoformat()})
    return out


def clean_up(user, ids):
    """Delete the chosen agent-made entries (only source="ai", only own)."""
    from .models import Reminder, Transaction
    n = 0
    for it in ids or []:
        model, pk = str(it.get("model")), it.get("id")
        if model == "txn":
            n += Transaction.objects.filter(user=user, source="ai", pk=pk).delete()[0]
        elif model == "reminder":
            n += Reminder.objects.filter(user=user, source="ai", pk=pk).delete()[0]
    return n


# ---------------------------------------------------------------------------
# gap-aichat2: deterministic SAFETY NET for the money tools. Live 10338: the
# real model sometimes answers "চায়ে ৫০ টাকা খরচ লিখে রাখো" without the
# ACTION line -> no confirm card (CI never saw it: the e2e fake always emits
# the line). When the message is an UNAMBIGUOUS "log X taka spent / earned"
# and the model gave no proposal, the server builds the same proposal. It is
# still only a proposal — nothing is written without the user's Yes.
# ---------------------------------------------------------------------------
_BN_TO_ASCII = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_AMT = re.compile(
    r"([0-9০-৯][0-9০-৯,]*(?:\.[0-9০-৯]+)?)\s*(k(?![a-z])|হাজার|hajar(?![a-z]))?", re.I)
_CUR = re.compile(r"৳|টাকা|\btaka\b|\btk\b|\bbdt\b|\btakar\b", re.I)
_SPEND = re.compile(
    r"খরচ|খরচা|কিনলাম|কিনেছি|কেনা হলো|দিলাম|দিয়েছি|দিয়েছি|"
    r"\b(?:spent|spend|expense|expenses|bought|paid|khoroch|khorcha|khoros|kinlam|kinechi)\b", re.I)
_EARN = re.compile(
    r"আয়|আয়|পেলাম|পেয়েছি|পেয়েছি|বেতন পেলাম|বিক্রি করলাম|"
    r"\b(?:income|earned|earn|received|got paid|salary|ay|aay|pelam|peyechi|payechi|paisi)\b", re.I)
_SAVE = re.compile(
    r"লিখে রাখ|লিখে রেখো|লিখে নাও|লিখো|লিখুন|লেখো|লিখ|হিসাবে রাখ|হিসেবে রাখ|হিসাবে যোগ|"
    r"হিসেবে যোগ|যোগ কর|সেভ কর|রেকর্ড কর|নোট কর|খাতায়|"
    r"\b(?:log|save|record|note it|note down|write down|add|track|likhe rakh\w*|likh\w*|"
    r"rakho|rakhen|add koro|jog koro|save koro)\b", re.I)
_QUESTION = re.compile(
    r"[?？]|\b(?:how|what|why|when|which|should|can i|could|kivabe|kemne|koto|ki\b)|"
    # (no \b next to Bangla: a vowel sign is not \w, so "কি\b" matched "কিনলাম")
    r"কত|কী|(?:^|\s)কি(?:\s|$)|কীভাবে|কেন|কোন|কিভাবে|উচিত|পারি", re.I)
_NOT_MONEY_TOOL = re.compile(
    r"মনে করিয়ে|রিমাইন্ডার|remind|alarm|অ্যালার্ম|ধার|loan|lend|borrow|"
    r"বাকি দিলাম|পাওনা|due\b", re.I)
_CAT_STOP = frozenset("""
আজ আজকে গতকাল কাল আমি আমার এই ওই একটা আর মোট i my today yesterday the a an for on in
ajke aj kal ami amar total te e
""".split())


def _num(raw):
    try:
        return Decimal(raw.translate(_BN_TO_ASCII).replace(",", ""))
    except (InvalidOperation, ValueError):
        return None


def _category(text, span):
    """A short category from the words around the amount: 'চায়ে ৫০ টাকা'
    -> 'চা', 'spent 200 taka on lunch' -> 'lunch'. Empty when unsure."""
    m = re.search(r"\b(?:on|for|from)\s+([A-Za-z][A-Za-z ]{1,24})", text[span[1]:], re.I)
    if m:
        w = m.group(1).strip().split()
        return " ".join(w[:2])[:30]
    before = text[:span[0]].split()
    for w in reversed(before[-2:]):
        w = re.sub(r"[,.;:!]+$", "", w)
        low = w.lower()
        if not w or low in _CAT_STOP or _SPEND.search(w) or _SAVE.search(w):
            continue
        for suf in ("য়ের", "য়ে", "য়", "েতে", "ের", "ে", "এ", "te", "e"):
            if len(w) > len(suf) + 1 and w.endswith(suf):
                w = w[:-len(suf)]
                break
        return w[:30]
    return ""


def money_safety_net(text):
    """A validated expense/income proposal for an unambiguous "log X taka
    spent / earned" message, else None. Unambiguous = exactly one amount with
    a currency word (or ৳), a spend XOR earn word, an explicit save word
    (or a very short statement like "চায়ে ৫০ টাকা খরচ"), not a question, not
    a reminder / loan."""
    t = " ".join(str(text or "").split())
    if not t or len(t) > 160 or _NOT_MONEY_TOOL.search(t) or _QUESTION.search(t):
        return None
    if not _CUR.search(t):
        return None
    amts = [m for m in _AMT.finditer(t) if m.group(1)]
    nums = [(m, _num(m.group(1))) for m in amts]
    nums = [(m, n) for m, n in nums if n is not None and n > 0]
    if len(nums) != 1:
        return None
    m, n = nums[0]
    if m.group(2):
        n = n * 1000
    spend, earn = bool(_SPEND.search(t)), bool(_EARN.search(t))
    if spend == earn:
        return None
    short = len(t.split()) <= 6
    if not (_SAVE.search(t) or short):
        return None
    raw = {"type": "expense" if spend else "income", "amount": str(n),
           "category": _category(t, m.span())}
    p = validate(raw)
    if p is not None:
        p["safety_net"] = True
    return p
