"""remnotes (owner review 28 Oct) — Reminders & Notes server rules.

* The app always kept a note's checklist / tags / priority / due date /
  reminder link, a reminder's priority / label and a to-do's priority —
  the server had no columns for them, so the FIRST sync replaced the phone's
  copy with the server's and wiped them. They are stored now.
* Everything the app sends is SANITISED, never rejected: an over-long list
  is trimmed, an unknown colour becomes "", a vault attachment that is not
  the caller's own document is dropped. A rejected offline write would sit
  in the phone's queue forever, so only the abuse caps below refuse.
* Abuse caps (not a paywall — notes and reminders are free on every plan):
  DAILY_CREATES per kind per day, TOTAL_CAP per kind.
* Share a note with one My Circle member: a COPY lands in their notes
  (+ a push unless their quiet hours). Vault attachments are never copied
  (documents stay private; the vault has its own revocable sharing).
"""
import re
from datetime import timedelta

from django.utils import timezone

NOTE_COLORS = ("red", "orange", "yellow", "green", "teal", "blue", "purple", "gray")
CHECKLIST_MAX = 200
CHECK_TEXT_MAX = 300
TAGS_MAX = 20
TAG_MAX = 30
ATTACH_MAX = 10
BODY_MAX = 20000
DAILY_CREATES = 300
TOTAL_CAP = {"note": 5000, "reminder": 3000, "todo": 5000}
SHARES_PER_DAY = 30
RULE_FREQS = ("daily", "weekly", "monthly", "yearly")
_TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


# ------------------------------------------------------------ sanitisers
def clean_checklist(value):
    out = []
    if not isinstance(value, list):
        return out
    for it in value:
        if isinstance(it, str):
            it = {"text": it, "done": False}
        if not isinstance(it, dict):
            continue
        text = str(it.get("text") or "").strip()[:CHECK_TEXT_MAX]
        if not text:
            continue
        out.append({"text": text, "done": it.get("done") is True})
        if len(out) >= CHECKLIST_MAX:
            break
    return out


def clean_tags(value):
    if isinstance(value, str):
        value = value.split(",")
    if not isinstance(value, list):
        return []
    out, seen = [], set()
    for t in value:
        t = str(t or "").strip().lstrip("#")[:TAG_MAX]
        if not t or t.lower() in seen:
            continue
        seen.add(t.lower())
        out.append(t)
        if len(out) >= TAGS_MAX:
            break
    return out


def clean_color(value):
    v = str(value or "").strip().lower()
    return v if v in NOTE_COLORS else ""


def clean_priority(value):
    return "high" if str(value or "").strip().lower() == "high" else "none"


def clean_rule(value):
    """A to-do repeat rule in the reminders' shape, or {}."""
    if not isinstance(value, dict):
        return {}
    freq = str(value.get("freq") or "")
    if freq not in RULE_FREQS:
        return {}
    out = {"freq": freq}

    def _int(k, lo, hi):
        try:
            n = int(value.get(k))
        except (TypeError, ValueError):
            return None
        return n if lo <= n <= hi else None

    out["interval"] = _int("interval", 1, 365) or 1
    for k, lo, hi in (("weekday", 0, 6), ("day_of_month", 1, 31), ("month", 1, 12)):
        n = _int(k, lo, hi)
        if n is not None:
            out[k] = n
    tm = str(value.get("time") or "")
    if _TIME.match(tm):
        out["time"] = tm
    return out


def clean_attachments(user, value):
    """Only the caller's OWN vault documents; titles come from the vault."""
    from .models import Document
    if not isinstance(value, list) or user is None:
        return []
    ids = []
    for it in value:
        raw = it.get("doc_id") if isinstance(it, dict) else it
        try:
            n = int(raw)
        except (TypeError, ValueError):
            continue
        if n not in ids:
            ids.append(n)
    if not ids:
        return []
    own = dict(Document.objects.filter(user=user, pk__in=ids[:50])
               .values_list("id", "title"))
    return [{"doc_id": i, "title": own[i]} for i in ids if i in own][:ATTACH_MAX]


# ------------------------------------------------------------------ caps
def over_cap(user, kind):
    """None, or 'daily_cap' / 'total_cap' for one more `kind` row."""
    from .models import Note, Reminder, Todo
    model = {"note": Note, "reminder": Reminder, "todo": Todo}.get(kind)
    if model is None or user is None:
        return None
    qs = model.objects.filter(user=user)
    if qs.count() >= TOTAL_CAP.get(kind, 5000):
        return "total_cap"
    if qs.filter(created_at__gte=timezone.now() - timedelta(days=1)).count() >= DAILY_CREATES:
        return "daily_cap"
    return None


# ----------------------------------------------------------------- share
def _name(u):
    return (getattr(u, "name", "") or "").strip() or (getattr(u, "phone", "") or "")


def _quiet(user):
    try:
        from . import family_alerts as FA
        return FA.in_quiet_hours(user)
    except Exception:
        return False


def share_note(user, note, circle_id):
    """(copy, error). Copies `note` into the notes of the caller's ACCEPTED,
    unblocked My Circle member `circle_id` (who has not blocked the caller)."""
    from .models import CircleMember, Note
    from .push import member_peer_user
    try:
        cid = int(circle_id)
    except (TypeError, ValueError):
        return None, "not_in_circle"
    edge = CircleMember.objects.filter(user=user, pk=cid, state="accepted",
                                       blocked=False).first()
    if edge is None:
        return None, "not_in_circle"
    to = member_peer_user(edge)
    if to is None or to.pk == user.pk:
        return None, "not_linked"
    if CircleMember.objects.filter(user=to, peer_user=user, blocked=True).exists():
        return None, "not_in_circle"
    since = timezone.now() - timedelta(days=1)
    sent = Note.objects.filter(source="shared", shared_from__user=user.pk,
                               created_at__gte=since).count()
    if sent >= SHARES_PER_DAY:
        return None, "rate_limited"
    if over_cap(to, "note"):
        return None, "their_full"
    copy = Note.objects.create(
        user=to, title=note.title, body=note.body, source="shared",
        checklist=clean_checklist(note.checklist), tags=clean_tags(note.tags),
        color=clean_color(note.color), priority=clean_priority(note.priority),
        due_at=note.due_at, attachments=[],
        shared_from={"user": user.pk, "name": _name(user)[:80]},
    )
    if not _quiet(to):
        from . import push
        n = _name(user)
        head = (note.title or note.body or "").strip()[:80]
        push.safe_push(to, "reminder", f"{n} আপনাকে একটি নোট পাঠিয়েছেন",
                       f"{n} sent you a note", head, head,
                       data={"route": "notes", "note_id": str(copy.pk)})
    return copy, None
