"""famcare (owner review 28 Oct) — Family Care server side.

* SAFETY IS NEVER PAYWALLED: every plan (Free included) may keep up to
  SAFETY_FAMILY_FREE family members; a paid plan with a bigger number keeps
  its number. SOS + family alerts never cost credits (core/family_alerts.py).
* Members are picked from My Circle in ONE tap (`from_circle`) — idempotent,
  never typed twice; only the caller's own ACCEPTED Circle edges.
* Shared reminders: assign a reminder to a Circle-linked family member; it
  lands in THEIR reminder list (+ a push unless their quiet hours), the done
  state is theirs and the assigner reads it back here.
* Family shopping list: the household owner's list, read + ticked by the
  owner's Circle-linked family members.
* Shared vault documents: one document -> chosen members, revocable, audited;
  the recipient may read it only while the share is active AND they are
  still in the owner's Circle.
"""
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

SAFETY_FAMILY_FREE = 5
TASKS_PER_PAIR_PER_DAY = 20
LIST_MAX_ITEMS = 300


# ------------------------------------------------------------------ limits
def plan_family(user):
    """The plan's own family number (0 when the plan has none)."""
    try:
        from . import plans as P
        pid = P.effective_plan(user)
        cp = P._config_plan(pid)
        spec = P.PLANS.get(pid) or {}
        return int((cp or spec).get("family") or 0)
    except Exception:
        return 0


def family_cap(user):
    """Members this user may keep: never below the free safety floor."""
    return max(SAFETY_FAMILY_FREE, plan_family(user))


def limits(user):
    from .models import FamilyMember
    used = FamilyMember.objects.filter(user=user).count()
    cap = family_cap(user)
    return {"limit": cap, "used": used, "left": max(0, cap - used),
            "safety_free": True, "free_floor": SAFETY_FAMILY_FREE}


def over_cap(user):
    from .models import FamilyMember
    return FamilyMember.objects.filter(user=user).count() >= family_cap(user)


# ------------------------------------------------------------- circle pick
def _accepted_edges(user):
    from .models import CircleMember
    return CircleMember.objects.filter(user=user, state="accepted", blocked=False)


def _edge_phone(m):
    from .push import member_peer_user
    if (m.phone or "").strip():
        return m.phone.strip()
    u = member_peer_user(m)
    return (getattr(u, "phone", "") or "").strip() if u else ""


def _edge_name(m):
    try:
        from .views_module5 import _resolve_peer
        name, _photo = _resolve_peer(m)
        if name:
            return name
    except Exception:
        pass
    return m.name or ""


def circle_candidates(user):
    """Accepted Circle members + whether each is already in the family list."""
    from .models import FamilyMember
    linked = dict(FamilyMember.objects.filter(user=user, circle_member__isnull=False)
                  .values_list("circle_member_id", "id"))
    out = []
    for m in _accepted_edges(user).order_by("name", "id"):
        out.append({
            "circle_id": m.id, "name": _edge_name(m), "relation": m.relation,
            "custom_label": m.custom_label, "phone": _edge_phone(m),
            "family_id": linked.get(m.id),
        })
    return out


def from_circle(user, circle_id):
    """(member_dict, created, error). Idempotent: picking the same Circle
    member twice returns the existing family entry."""
    from .models import CircleMember, FamilyMember
    m = CircleMember.objects.filter(user=user, pk=circle_id, state="accepted",
                                    blocked=False).first()
    if m is None:
        return None, False, "not_in_circle"
    with transaction.atomic():
        fm = FamilyMember.objects.select_for_update().filter(
            user=user, circle_member=m).first()
        if fm is not None:
            return fm, False, None
        # a hand-typed entry with the same phone: link it instead of a second row
        phone = _edge_phone(m)
        if phone:
            from .phone import canonical_phone
            want = canonical_phone(phone) or phone
            for cand in FamilyMember.objects.filter(user=user, circle_member__isnull=True):
                p = (cand.phone or "").strip()
                if p and (canonical_phone(p) or p) == want:
                    cand.circle_member = m
                    cand.save(update_fields=["circle_member", "updated_at"])
                    return cand, False, None
        if over_cap(user):
            return None, False, "family_limit"
        rel = m.custom_label if m.relation == "custom" and m.custom_label else m.relation
        fm = FamilyMember.objects.create(
            user=user, name=(_edge_name(m) or "")[:80] or "?",
            relation=(rel or "")[:40], phone=phone[:24], circle_member=m)
    return fm, True, None


def member_dict(fm):
    edge = fm.circle_member
    return {"id": fm.id, "name": fm.name, "relation": fm.relation, "phone": fm.phone,
            "notes": fm.notes, "circle_member": fm.circle_member_id,
            "in_circle": bool(edge is not None and edge.state == "accepted"
                              and not edge.blocked)}


# ---------------------------------------------------------- household / acl
def linked_user(fm):
    """The account of a Circle-linked family member who is still a consenting
    Circle member of the owner (accepted, nobody blocked anybody)."""
    from . import family_alerts as FA
    from .push import member_peer_user
    edge = fm.circle_member
    if edge is None or edge.state != "accepted" or edge.blocked:
        return None
    u = member_peer_user(edge)
    if u is None or u.pk == fm.user_id:
        return None
    back = FA._edge(u, fm.user)
    if back is not None and (back.blocked or back.state in ("blocked", "declined")):
        return None
    return u


def household(owner):
    """{user_id: User} of the owner's linked family accounts."""
    from .models import FamilyMember
    out = {}
    for fm in FamilyMember.objects.filter(user=owner, circle_member__isnull=False) \
            .select_related("circle_member", "circle_member__peer_user"):
        u = linked_user(fm)
        if u is not None:
            out[u.pk] = u
    return out


def households_of(user):
    """Owners whose household includes `user` (I may read their list)."""
    from .models import FamilyMember
    owners = {}
    qs = FamilyMember.objects.filter(circle_member__peer_user=user,
                                     circle_member__state="accepted",
                                     circle_member__blocked=False) \
        .select_related("user", "circle_member")
    for fm in qs:
        if fm.user_id != user.pk and linked_user(fm) is not None:
            owners[fm.user_id] = fm.user
    return owners


def can_use_list(user, owner):
    return user.pk == owner.pk or user.pk in household(owner)


def _quiet(user):
    try:
        from . import family_alerts as FA
        return FA.in_quiet_hours(user)
    except Exception:
        return False


def _push(user, tbn, ten, bbn, ben, route):
    if _quiet(user):
        return False
    from . import push
    return bool(push.safe_push(user, "reminder", tbn, ten, bbn, ben,
                               data={"route": route, "kind": "family_task"}))


def _name(u):
    return (getattr(u, "name", "") or "").strip() or (getattr(u, "phone", "") or "")


# --------------------------------------------------------- shared reminders
def assign_reminder(user, member_id, title, due_at=None, notes=""):
    """(reminder, error). The reminder is created in the MEMBER's account."""
    from .models import FamilyMember, Reminder
    fm = FamilyMember.objects.filter(user=user, pk=member_id) \
        .select_related("circle_member").first()
    if fm is None:
        return None, "not_found"
    to = linked_user(fm)
    if to is None:
        return None, "not_linked"
    title = (title or "").strip()[:200]
    if not title:
        return None, "title_required"
    since = timezone.now() - timedelta(days=1)
    sent = Reminder.objects.filter(user=to, created_at__gte=since,
                                   link__type="family_task",
                                   link__from_user=user.pk).count()
    if sent >= TASKS_PER_PAIR_PER_DAY:
        return None, "rate_limited"
    r = Reminder.objects.create(
        user=to, title=title, notes=(notes or "")[:2000], due_at=due_at,
        link={"type": "family_task", "id": user.pk, "from_user": user.pk,
              "from_name": _name(user)[:80], "family_id": fm.id,
              "label": _name(user)[:80]},
    )
    n = _name(user)
    _push(to, f"{n} আপনাকে একটি কাজ দিয়েছেন", f"{n} gave you a task",
          title, title, "reminders")
    return r, None


def task_dict(r, viewer):
    link = r.link or {}
    return {"id": r.id, "title": r.title, "notes": r.notes,
            "due_at": r.due_at.isoformat() if r.due_at else None,
            "done": r.done, "from_user": link.get("from_user"),
            "from_name": link.get("from_name", ""),
            "to_user": r.user_id, "to_name": _name(r.user),
            "family_id": link.get("family_id"),
            "mine": link.get("from_user") == viewer.pk,
            "updated_at": r.updated_at.isoformat() if r.updated_at else None}


def tasks(user):
    from .models import Reminder
    by_me = Reminder.objects.filter(link__type="family_task", link__from_user=user.pk) \
        .select_related("user").order_by("done", "due_at", "-id")[:200]
    to_me = Reminder.objects.filter(user=user, link__type="family_task") \
        .order_by("done", "due_at", "-id")[:200]
    return {"assigned_by_me": [task_dict(r, user) for r in by_me],
            "assigned_to_me": [task_dict(r, user) for r in to_me]}


def cancel_task(user, rid):
    from .models import Reminder
    r = Reminder.objects.filter(pk=rid, link__type="family_task",
                                link__from_user=user.pk).first()
    if r is None:
        return False
    r.delete()
    return True


def on_reminder_saved(r, was_done):
    """The assignee ticked a family task done -> tell the assigner once."""
    link = r.link or {}
    if link.get("type") != "family_task" or was_done or not r.done:
        return
    from django.contrib.auth import get_user_model
    by = get_user_model().objects.filter(pk=link.get("from_user")).first()
    if by is None:
        return
    n = _name(r.user)
    _push(by, f"{n} কাজটি শেষ করেছেন", f"{n} finished the task",
          r.title, r.title, "family")


# ------------------------------------------------------------ shopping list
def item_dict(it, viewer):
    return {"id": it.id, "text": it.text, "qty": it.qty, "done": it.done,
            "added_by": _name(it.added_by) if it.added_by else "",
            "done_by": _name(it.done_by) if it.done_by else "",
            "mine": it.added_by_id == viewer.pk,
            "updated_at": it.updated_at.isoformat() if it.updated_at else None}


def lists_for(user):
    from .models import FamilyListItem
    owners = [user] + list(households_of(user).values())
    out = []
    for o in owners:
        items = FamilyListItem.objects.filter(owner=o).select_related(
            "added_by", "done_by")[:LIST_MAX_ITEMS]
        out.append({"owner_id": o.pk, "owner_name": _name(o), "mine": o.pk == user.pk,
                    "shared_with": len(household(o)) if o.pk == user.pk else None,
                    "items": [item_dict(i, user) for i in items]})
    return out


def add_item(user, owner_id, text, qty=""):
    from django.contrib.auth import get_user_model
    from .models import FamilyListItem
    owner = user if not owner_id else get_user_model().objects.filter(pk=owner_id).first()
    if owner is None or not can_use_list(user, owner):
        return None, "forbidden"
    text = (text or "").strip()[:200]
    if not text:
        return None, "text_required"
    if FamilyListItem.objects.filter(owner=owner).count() >= LIST_MAX_ITEMS:
        return None, "list_full"
    return FamilyListItem.objects.create(owner=owner, text=text,
                                         qty=(qty or "").strip()[:40],
                                         added_by=user), None


def _item_for(user, pk):
    from .models import FamilyListItem
    it = FamilyListItem.objects.filter(pk=pk).select_related("owner").first()
    if it is None or not can_use_list(user, it.owner):
        return None
    return it


def toggle_item(user, pk, done=None):
    it = _item_for(user, pk)
    if it is None:
        return None
    it.done = (not it.done) if done is None else bool(done)
    it.done_by = user if it.done else None
    it.save(update_fields=["done", "done_by", "updated_at"])
    return it


def delete_item(user, pk):
    it = _item_for(user, pk)
    if it is None:
        return False
    it.delete()
    return True


def clear_done(user, owner_id=None):
    from django.contrib.auth import get_user_model
    from .models import FamilyListItem
    owner = user if not owner_id else get_user_model().objects.filter(pk=owner_id).first()
    if owner is None or not can_use_list(user, owner):
        return None
    n, _ = FamilyListItem.objects.filter(owner=owner, done=True).delete()
    return n


# ------------------------------------------------------- shared vault docs
def share_dict(s, viewer):
    d = s.document
    return {"id": s.id, "document_id": d.id, "title": d.title, "doc_type": d.doc_type,
            "expiry_date": d.expiry_date.isoformat() if d.expiry_date else None,
            "has_file": bool(d.file), "owner_name": _name(s.owner),
            "recipient_id": s.recipient_id, "recipient_name": _name(s.recipient),
            "active": s.revoked_at is None,
            "created_at": s.created_at.isoformat(),
            "revoked_at": s.revoked_at.isoformat() if s.revoked_at else None,
            "opens": s.opens,
            "last_opened_at": s.last_opened_at.isoformat() if s.last_opened_at else None}


def share_docs(user, document_id, member_ids):
    """(created_shares, error)."""
    from .models import Document, FamilyDocShare, FamilyMember
    doc = Document.objects.filter(user=user, pk=document_id).first()
    if doc is None:
        return None, "not_found"
    fms = list(FamilyMember.objects.filter(user=user, pk__in=list(member_ids or []))
               .select_related("circle_member"))
    if not fms:
        return None, "no_members"
    out = []
    for fm in fms:
        to = linked_user(fm)
        if to is None:
            continue
        s = FamilyDocShare.objects.filter(owner=user, document=doc, recipient=to,
                                          revoked_at__isnull=True).first()
        if s is None:
            s = FamilyDocShare.objects.create(owner=user, document=doc, recipient=to)
            n = _name(user)
            # vault rule: a push never carries the title / numbers / file
            _push(to, f"{n} আপনার সাথে একটি কাগজ শেয়ার করেছেন",
                  f"{n} shared a document with you", "", "", "family")
        out.append(s)
    if not out:
        return None, "not_linked"
    return out, None


def revoke_share(user, pk):
    from .models import FamilyDocShare
    s = FamilyDocShare.objects.filter(owner=user, pk=pk, revoked_at__isnull=True).first()
    if s is None:
        return None
    s.revoked_at = timezone.now()
    s.save(update_fields=["revoked_at"])
    return s


def doc_shares(user):
    from .models import FamilyDocShare
    mine = FamilyDocShare.objects.filter(owner=user).select_related(
        "document", "recipient", "owner")[:200]
    to_me = FamilyDocShare.objects.filter(recipient=user, revoked_at__isnull=True) \
        .select_related("document", "owner", "recipient")[:200]
    return {"shared_by_me": [share_dict(s, user) for s in mine],
            "shared_with_me": [share_dict(s, user) for s in to_me
                               if recipient_may_read(s)]}


def recipient_may_read(s):
    from . import family_alerts as FA
    return s.revoked_at is None and FA.is_member(s.owner, s.recipient)


def open_share(user, pk):
    """The share the recipient may read right now (and count the open)."""
    from django.db.models import F
    from .models import FamilyDocShare
    s = FamilyDocShare.objects.filter(pk=pk, recipient=user).select_related(
        "document", "owner", "recipient").first()
    if s is None or not recipient_may_read(s):
        return None
    FamilyDocShare.objects.filter(pk=s.pk).update(opens=F("opens") + 1,
                                                  last_opened_at=timezone.now())
    return s
