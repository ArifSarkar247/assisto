"""
ai_inbox.py — Assisto AI Inbox triage engine (feature 22, SPEC v2.1 §21
ADVANCED). Pure Python, deterministic, no Django, no AI key, no network; fully
unit-testable.

WHAT THIS IS
    A unified SMART INBOX over the user's email / notifications / messages. The
    engine takes raw items (each: source, sender, subject, snippet, ts, read)
    and returns, per item, an advanced triage view:

        category   : one of CATEGORIES — urgent | action | fyi | promo
        priority   : 0..100 integer (higher = sooner); drives priority sort
        needs_reply: bool — belongs in the "Needs reply" view
        summary    : a short, deterministic one-line gist (NOT generative)
        replies    : up to 3 suggested quick-reply *labels* (MOCK). Turning a
                     label into real drafted prose is key-gated (see below).

    It also offers list-level helpers the UI leans on: filtering by category /
    source, priority sort, "needs reply" view, and bulk-action application
    (done / snooze) over a set of ids — all pure transforms on dicts.

WHY RULE-BASED (honest states)
    Real categorisation/summaries/drafts from an LLM, and fetching live email
    over IMAP/Gmail, both need a provider key + OAuth the owner has not added.
    So the live-account connection and the *generative* reply drafting are
    KEY-GATED; everything here is deterministic keyword/heuristic logic that
    runs today on MOCK items. `suggest_replies()` returns canned labels; a
    real draft would call the key-gated layer — this module never does.

Benchmarked (capability only, adapted to a bilingual BD audience) against the
best smart-inbox apps (Gmail Priority/Important + nudges, Superhuman split
inbox + "needs reply", Spark smart inbox categories, Hey's Imbox/Feed/Paper
Trail screening). We reproduce the *decisions* (categorise, summarise,
needs-reply, snooze, quick replies, priority) deterministically.
"""
from datetime import datetime, timedelta

# ---- enums (single source of truth; the app mirrors these strings) --------
CATEGORIES = ("urgent", "action", "fyi", "promo")
SOURCES = ("email", "notification", "message")

# priority base per category; refined by signals below.
_CATEGORY_BASE = {"urgent": 80, "action": 55, "fyi": 25, "promo": 5}

# Keyword banks are bilingual (English + Bangla). Bangla lives in the backend
# only — never in .dart. Lower-cased substring match.
_URGENT = ["urgent", "asap", "immediately", "overdue", "due today", "final notice",
           "payment failed", "suspended", "account locked", "action required",
           "security alert", "otp", "verification code", "deadline today",
           "জরুরি", "আজকের মধ্যে", "বকেয়া", "বন্ধ", "সতর্কতা", "শেষ সুযোগ"]
_ACTION = ["reply", "response needed", "please confirm", "waiting", "reminder",
           "follow up", "follow-up", "invoice", "meeting", "rsvp", "approve",
           "sign", "review", "schedule", "can you", "could you", "?",
           "উত্তর", "মিটিং", "রিমাইন্ডার", "অনুমোদন", "নিশ্চিত"]
_PROMO = ["sale", "% off", "discount", "offer", "deal", "coupon", "unsubscribe",
          "newsletter", "promotion", "limited time", "buy now", "subscribe",
          "ছাড়", "অফার", "বিক্রয়", "নিউজলেটার"]
# Questions / explicit reply asks ⇒ needs_reply even if only "action".
_REPLY_SIGNALS = ["?", "reply", "please confirm", "please respond", "rsvp",
                  "let me know", "waiting for your", "can you", "could you",
                  "উত্তর", "জানাবেন", "নিশ্চিত করুন"]


def _text(item):
    return f"{item.get('subject', '')} {item.get('snippet', '')}".lower()


def _any(text, bank):
    return any(w in text for w in bank)


# ---- categorise -----------------------------------------------------------
def categorize(item):
    """Deterministic category for one item. Promo is detected first so a 'SALE —
    reply to claim' lands in promo, not action; then urgent > action > fyi."""
    t = _text(item)
    if _any(t, _PROMO) and not _any(t, _URGENT):
        return "promo"
    if _any(t, _URGENT):
        return "urgent"
    if _any(t, _ACTION):
        return "action"
    return "fyi"


def needs_reply(item, category=None):
    """True when the item plausibly expects a human reply. Promos never do."""
    category = category or categorize(item)
    if category == "promo":
        return False
    if category == "urgent":
        return True
    return _any(_text(item), _REPLY_SIGNALS)


def _recency_boost(item, now):
    """0..15 bump for freshness; unknown/absent ts ⇒ neutral 8."""
    ts = item.get("ts")
    if not isinstance(ts, datetime):
        return 8
    age = now - ts
    if age <= timedelta(hours=1):
        return 15
    if age <= timedelta(hours=6):
        return 10
    if age <= timedelta(days=1):
        return 6
    if age <= timedelta(days=3):
        return 2
    return 0


def priority(item, now=None, category=None):
    """0..100. category base + recency + unread + needs-reply, clamped."""
    now = now or datetime.utcnow()
    category = category or categorize(item)
    p = _CATEGORY_BASE[category]
    p += _recency_boost(item, now)
    if not item.get("read", False):
        p += 5
    if needs_reply(item, category):
        p += 8
    return max(0, min(100, p))


def _summary(item):
    """Deterministic one-line gist: sender + trimmed subject. No generation."""
    sender = (item.get("sender") or "").strip()
    subject = (item.get("subject") or item.get("snippet") or "").strip()
    subject = " ".join(subject.split())
    if len(subject) > 90:
        subject = subject[:87].rstrip() + "..."
    if sender and subject:
        return f"{sender}: {subject}"
    return subject or sender


# ---- quick replies (MOCK labels; real prose is key-gated) -----------------
# Label KEYS only — the app renders them via l10n (bilingual) so there is no
# Bangla here that needs to reach .dart. A real LLM draft is NOT produced here.
_REPLY_SETS = {
    "urgent": ["ackOnIt", "needMoreTime", "callMe"],
    "action": ["willDo", "notNow", "askDetails"],
    "fyi": ["thanks", "noted"],
    "promo": [],
}


def suggest_replies(item, category=None, ai_key_available=False):
    """Return up to 3 quick-reply *label keys* (MOCK). `ai_key_available` is
    threaded through only so callers can decide whether a tapped label becomes a
    real drafted reply; this function never drafts — it stays deterministic."""
    category = category or categorize(item)
    return list(_REPLY_SETS.get(category, []))[:3]


# ---- per-item enrichment + list-level helpers -----------------------------
def triage_item(item, now=None, ai_key_available=False):
    """Full advanced view for one item (non-destructive: returns a new dict)."""
    now = now or datetime.utcnow()
    cat = categorize(item)
    nr = needs_reply(item, cat)
    out = dict(item)
    out.update({
        "category": cat,
        "priority": priority(item, now=now, category=cat),
        "needs_reply": nr,
        "summary": _summary(item),
        "replies": suggest_replies(item, category=cat,
                                   ai_key_available=ai_key_available),
    })
    return out


def triage_list(items, now=None, ai_key_available=False):
    now = now or datetime.utcnow()
    return [triage_item(it, now=now, ai_key_available=ai_key_available)
            for it in (items or [])]


def filter_items(items, category=None, source=None):
    out = items
    if category:
        out = [it for it in out if it.get("category") == category]
    if source:
        out = [it for it in out if it.get("source") == source]
    return list(out)


def needs_reply_view(items):
    """The 'Needs reply' view, highest priority first."""
    return sort_by_priority([it for it in items if it.get("needs_reply")])


def sort_by_priority(items):
    """Priority desc; stable tie-break on ts desc then id for determinism."""
    def key(it):
        ts = it.get("ts")
        ts_key = ts.timestamp() if isinstance(ts, datetime) else 0
        return (-(it.get("priority", 0)), -ts_key, str(it.get("id", "")))
    return sorted(items, key=key)


def category_counts(items):
    """Badge counts per category (+ a 'needsReply' tally) for filter chips."""
    counts = {c: 0 for c in CATEGORIES}
    for it in items:
        c = it.get("category")
        if c in counts:
            counts[c] += 1
    counts["needsReply"] = sum(1 for it in items if it.get("needs_reply"))
    return counts


# ---- bulk / single actions (pure state transitions) -----------------------
VALID_SNOOZE_HOURS = (1, 3, 24, 72)


def snooze_until(now, hours):
    """Snooze end time; invalid durations raise so the view returns 400."""
    if hours not in VALID_SNOOZE_HOURS:
        raise ValueError("invalid snooze duration")
    return now + timedelta(hours=hours)


def apply_bulk(items, ids, action, now=None, hours=24):
    """Apply a bulk action to the items whose id is in `ids`. Returns a NEW list
    (never mutates input). Supported: 'done' | 'snooze' | 'read' | 'unsnooze'.
    Snoozed/done items keep their data so the UI can undo."""
    now = now or datetime.utcnow()
    ids = set(ids or [])
    if action not in ("done", "snooze", "read", "unsnooze"):
        raise ValueError("unknown action")
    out = []
    for it in items:
        if it.get("id") in ids:
            nit = dict(it)
            if action == "done":
                nit["done"] = True
            elif action == "read":
                nit["read"] = True
            elif action == "snooze":
                nit["snoozed_until"] = snooze_until(now, hours)
            elif action == "unsnooze":
                nit.pop("snoozed_until", None)
            out.append(nit)
        else:
            out.append(dict(it))
    return out


def active_items(items, now=None):
    """Items shown in the main list: not done, and not currently snoozed."""
    now = now or datetime.utcnow()
    res = []
    for it in items:
        if it.get("done"):
            continue
        su = it.get("snoozed_until")
        if isinstance(su, datetime) and su > now:
            continue
        res.append(it)
    return res


# ---- convert-to-task / reminder (hand-off payloads; no persistence here) ---
def to_task_payload(item):
    """Build the payload the app posts to the existing task endpoint. Pure; no
    DB. The owner confirms before anything is created."""
    return {
        "title": (item.get("subject") or _summary(item))[:120],
        "note": item.get("snippet", ""),
        "source": "inbox",
        "source_id": item.get("id"),
    }


def to_reminder_payload(item, when=None):
    return {
        "text": (item.get("subject") or _summary(item))[:120],
        "when": when.isoformat() if isinstance(when, datetime) else None,
        "source": "inbox",
        "source_id": item.get("id"),
    }
