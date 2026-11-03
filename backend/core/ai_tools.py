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
    "button first. No ACTION line for questions, feelings, translations or chat.")


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
