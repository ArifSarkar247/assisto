"""guardian2 — PART 6 TWO GUARDIANS (owner order 3 Nov 18:40).

A second guardian (Dad, Mom, grandparent) joins a child by an invite CODE /
link that an existing guardian created — and STILL sees nothing until an
EXISTING guardian taps Approve (a forwarded code alone gives no access).

  invite   existing guardian  -> GuardianLink(state=invited, code, 48 h)
  join     the second person enters the code -> state=pending (no access)
  approve  an existing guardian (never the requester) -> state=approved:
           added as a co-guardian to the child's kids watches + school plans
           (so the existing location screens, arrive/leave, danger alerts
           work for both) and to the child's SOS / fall / check-in fan-out
  reject   -> state=rejected (requester told; nothing was ever shared)
  remove   any guardian of the child, or the co-guardian leaving -> state=
           removed; stripped from every watch / plan at once; BOTH guardians
           and the child are told; the child's "who can see me" updates.

The child always sees every approved guardian (name + since when) and every
pending request ("waiting for approval — cannot see you yet") on GET
/guardians/mine (core.guardianship.guardians_of + pending_for_child here).

Max guardians per child comes from the plan (Child Plan 2, School Safe 4;
safeplans owns the number) through max_guardians() — default 2 until that
module exists. The limit only stops NEW invites/approvals; it never removes
anyone and never touches SOS (safety is never paywalled).

Nothing here blocks SOS: family_alerts calls sos_extra_recipients() inside a
try/except, after the circle recipients are already known.
Owner Admin / staff never read this table (web privacy wall test)."""
from __future__ import annotations

import logging
import secrets
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

log = logging.getLogger(__name__)

INVITE_HOURS = 48
CODE_LEN = 8
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # no 0/O, 1/I/L
LIVE = ("invited", "pending")
DEFAULT_MAX = 2
MAX_LIVE_INVITES = 3            # per child, unused codes at one time
# family_alerts kinds that also reach approved co-guardians of the sender
SOS_KINDS = ("sos", "sos_resolved", "fall", "checkin_overdue", "wellness_alert")
INVITE_URL = "https://lifeassisto.com/g/%s"


# ------------------------------------------------------------------ limits
def max_guardians(child):
    """How many guardians this child's plan allows. safeplans owns the number
    (core.safe_plans.max_guardians: Child Plan 2, School Safe 4); until it is
    merged — or if it errors — 2."""
    try:
        from .safe_plans import max_guardians as plan_max   # safeplans
        n = int(plan_max(child))
        return n if n >= 1 else DEFAULT_MAX
    except Exception:  # noqa: BLE001 — ImportError until safeplans merges
        return DEFAULT_MAX


# ------------------------------------------------------------------ lookups
def _name(viewer, user):
    from . import push
    try:
        return push.seen_name(viewer, user) if viewer is not None else push.display_name(user)
    except Exception:  # noqa: BLE001
        return getattr(user, "name", "") or ""


def approved_ids(child_id):
    from .models import GuardianLink
    return set(GuardianLink.objects.filter(child_id=child_id, state="approved")
               .values_list("guardian_id", flat=True))


def is_approved(child_id, uid):
    from .models import GuardianLink
    if not child_id or not uid:
        return False
    return GuardianLink.objects.filter(child_id=child_id, guardian_id=uid,
                                       state="approved").exists()


def child_ids_owned_by(owner_id):
    """Children whose kids watch / school plan `owner_id` set up."""
    from .models import KidsWatch, SchoolPlan
    ids = set(KidsWatch.objects.filter(owner_id=owner_id, child_user__isnull=False)
              .values_list("child_user_id", flat=True))
    ids |= set(SchoolPlan.objects.filter(owner_id=owner_id, child_user__isnull=False)
               .values_list("child_user_id", flat=True))
    ids |= set(SchoolPlan.objects.filter(owner_id=owner_id, watch__child_user__isnull=False)
               .values_list("watch__child_user_id", flat=True))
    return ids


def co_pair(owner_id, uid):
    """True when `uid` is an APPROVED co-guardian of a child whose watch /
    plan `owner_id` set up — the co-guardian then counts as a valid peer of
    that owner for the watch / plan checks (kidswatch_service._peer_ok,
    guardianship._peer_ok). Removed / rejected links stop at once."""
    from .models import GuardianLink
    if not owner_id or not uid or owner_id == uid:
        return False
    kids = set(GuardianLink.objects.filter(guardian_id=uid, state="approved")
               .values_list("child_id", flat=True))
    return bool(kids) and bool(kids & child_ids_owned_by(owner_id))


def plan_owner_ids(user):
    """Owners of watches / plans of the children `user` co-guards (approved)."""
    from .models import GuardianLink, KidsWatch, SchoolPlan
    kids = list(GuardianLink.objects.filter(guardian=user, state="approved")
                .values_list("child_id", flat=True))
    if not kids:
        return []
    ids = set(SchoolPlan.objects.filter(child_user_id__in=kids).values_list("owner_id", flat=True))
    ids |= set(SchoolPlan.objects.filter(watch__child_user_id__in=kids)
               .values_list("owner_id", flat=True))
    ids |= set(KidsWatch.objects.filter(child_user_id__in=kids).values_list("owner_id", flat=True))
    ids.discard(user.id)
    return list(ids)


def _verified_parent_ids(child):
    from . import guardianship as G
    from .models import CircleMember
    out = set()
    for m in CircleMember.objects.filter(user=child, state="accepted", blocked=False,
                                         peer_user__isnull=False,
                                         relation__in=list(G.PARENT_EDGES)) \
            .select_related("peer_user"):
        if G.verified_parent(m.peer_user, child):
            out.add(m.peer_user_id)
    return out


def guardian_ids(child):
    """Every CURRENT guardian of `child`: any feature (watch / school plan /
    live journey / chip), approved co-guardians, and verified parents."""
    from . import guardianship as G
    if child is None:
        return set()
    ids = set(G.guardian_user_ids(child)) | _verified_parent_ids(child)
    ids.discard(child.id)
    return ids


def is_guardian(user, child):
    return bool(user and child) and user.id in guardian_ids(child)


def _live_links(child):
    from .models import GuardianLink
    now = timezone.now()
    # expire stale codes lazily (an unused invite only — a pending request
    # waits for the guardian's answer)
    GuardianLink.objects.filter(child=child, state="invited",
                                expires_at__lt=now).update(state="expired")
    return GuardianLink.objects.filter(child=child, state__in=LIVE)


# ----------------------------------------------------------------- notifying
def _tell(users, title_bn, title_en, body_bn, body_en, meta, high=False):
    """In-app notice + push. Never raises (a notice must never break a flow)."""
    try:
        from . import kidswatch_service as KW
        KW._send([u for u in users if u is not None], title_bn, title_en,
                 body_bn, body_en, {"event": "guardian2", **meta},
                 family_alert=False, high=high, route="guardians")
    except Exception:  # noqa: BLE001
        log.warning("guardian2: notify failed")


def _user(uid):
    from .models import User
    return User.objects.filter(pk=uid).first()


# --------------------------------------------------------------- actions
class LinkError(Exception):
    def __init__(self, code, http=400, **extra):
        super().__init__(code)
        self.code, self.http, self.extra = code, http, extra


def _new_code():
    from .models import GuardianLink
    for _ in range(20):
        c = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
        if not GuardianLink.objects.filter(code=c).exists():
            return c
    raise LinkError("try_again", 503)


def _room(child, extra=0):
    """(used, max): current guardians + requests waiting for approval."""
    from .models import GuardianLink
    used = len(guardian_ids(child)) + GuardianLink.objects.filter(
        child=child, state="pending").count() + extra
    return used, max_guardians(child)


def create_invite(inviter, child, now=None):
    now = now or timezone.now()
    if child is None or inviter is None or inviter.id == child.id:
        raise LinkError("not_found", 404)
    if not is_guardian(inviter, child):
        raise LinkError("not_guardian", 403)
    used, mx = _room(child)
    if used >= mx:
        raise LinkError("limit", 409, max=mx)
    if _live_links(child).filter(state="invited").count() >= MAX_LIVE_INVITES:
        raise LinkError("too_many_invites", 429)
    from .models import GuardianLink
    link = GuardianLink.objects.create(child=child, invited_by=inviter, code=_new_code(),
                                       expires_at=now + timedelta(hours=INVITE_HOURS))
    return link


def _norm_code(code):
    return "".join(ch for ch in str(code or "").upper() if ch.isalnum())[:12]


def join(user, code, now=None):
    """The second person enters the code: a request that waits for an
    existing guardian. Gives NO access by itself."""
    from .models import GuardianLink
    now = now or timezone.now()
    c = _norm_code(code)
    with transaction.atomic():
        link = GuardianLink.objects.select_for_update().filter(code=c).first() if c else None
        if link is None:
            raise LinkError("bad_code", 404)
        if link.state != "invited":
            raise LinkError("code_used", 409)
        if link.expires_at < now:
            link.state = "expired"
            link.save(update_fields=["state"])
            raise LinkError("expired", 410)
        child = link.child
        if user.id == child.id:
            raise LinkError("self", 400)
        if user.id in guardian_ids(child):
            raise LinkError("already_guardian", 409)
        if GuardianLink.objects.filter(child=child, guardian=user, state="pending").exists():
            raise LinkError("already_pending", 409)
        used, mx = _room(child)
        if used >= mx:
            raise LinkError("limit", 409, max=mx)
        link.guardian, link.state, link.requested_at = user, "pending", now
        link.save(update_fields=["guardian", "state", "requested_at"])
    approvers = [_user(u) for u in sorted(guardian_ids(child))]
    for a in approvers:
        if a is None:
            continue
        rn, cn = _name(a, user), _name(a, child)
        _tell([a], "নতুন অভিভাবকের অনুরোধ", "New guardian request",
              "%s, %s-এর অভিভাবক হতে চান। আপনি অনুমতি না দিলে তিনি কিছুই দেখতে পাবেন না।"
              % (rn, cn),
              "%s wants to be a guardian of %s. They see nothing until you approve." % (rn, cn),
              {"link_id": link.id, "action": "approve"}, high=True)
    return link


def _approver_ok(user, link):
    return (user.id != (link.guardian_id or 0) and user.id != link.child_id
            and is_guardian(user, link.child))


def _sync_features(link, add):
    """Add / strip the co-guardian on the child's kids watches + school plans
    (the existing screens and alert fan-outs then cover both guardians)."""
    from . import kidswatch_service as KW
    from .models import KidsWatch, SchoolPlan
    gid = link.guardian_id
    child = link.child
    for w in KidsWatch.objects.filter(child_user=child).exclude(state="disabled"):
        ids = [int(x) for x in (w.guardian_ids or []) if str(x).lstrip("-").isdigit()]
        if add and gid != w.owner_id and gid not in ids and len(ids) < KW.MAX_GUARDIANS:
            w.guardian_ids = ids + [gid]
            w.save(update_fields=["guardian_ids", "updated_at"])
        elif not add and gid in ids:
            w.guardian_ids = [x for x in ids if x != gid]
            w.save(update_fields=["guardian_ids", "updated_at"])
    plans = list(SchoolPlan.objects.filter(child_user=child)) + list(
        SchoolPlan.objects.filter(child_user__isnull=True, watch__child_user=child))
    for p in plans:
        ids = [int(x) for x in (p.watcher_ids or []) if str(x).lstrip("-").isdigit()]
        if add and gid != p.owner_id and gid not in ids:
            p.watcher_ids = ids + [gid]
            p.save(update_fields=["watcher_ids", "updated_at"])
        elif not add and gid in ids:
            p.watcher_ids = [x for x in ids if x != gid]
            p.save(update_fields=["watcher_ids", "updated_at"])


def decide(user, link_id, approve, now=None):
    from .models import GuardianLink
    now = now or timezone.now()
    with transaction.atomic():
        link = (GuardianLink.objects.select_for_update().select_related("child", "guardian")
                .filter(pk=link_id).first())
        if link is None or not _approver_ok(user, link):
            raise LinkError("not_found", 404)
        if link.state != "pending":
            raise LinkError("not_pending", 409)
        if approve:
            # the requester already counts as "pending" in _room: no +1
            used, mx = _room(link.child)
            if used > mx:
                raise LinkError("limit", 409, max=mx)
            link.state, link.approved_at = "approved", now
        else:
            link.state = "rejected"
            link.ended_at = now
        link.decided_by = user
        link.save(update_fields=["state", "approved_at", "decided_by", "ended_at"])
        if approve:
            _sync_features(link, add=True)
    g, child = link.guardian, link.child
    if approve:
        _tell([g], "অনুমতি পেয়েছেন", "Request approved",
              "%s অনুমতি দিয়েছেন — এখন থেকে %s-এর লোকেশন, পৌঁছানো/বের হওয়া ও SOS সতর্কতা পাবেন।"
              % (_name(g, user), _name(g, child)),
              "%s approved — you now get %s's location, arrive/leave and SOS alerts."
              % (_name(g, user), _name(g, child)), {"link_id": link.id, "state": "approved"})
        others = [_user(u) for u in guardian_ids(child) if u not in (g.id, user.id)]
        if others:
            _tell(others, "নতুন অভিভাবক", "New guardian",
                  "%s এখন %s-এর অভিভাবক (%s অনুমতি দিয়েছেন)।" % (g.name or "", child.name or "",
                                                               user.name or ""),
                  "%s is now a guardian of %s (approved by %s)." % (g.name or "", child.name or "",
                                                                   user.name or ""),
                  {"link_id": link.id, "state": "approved"})
        _tell([child], "কে তোমার লোকেশন দেখেন — বদলেছে", "Who can see your location changed",
              "%s এখন তোমার লোকেশন দেখতে পারবেন। কে কে দেখেন: অভিভাবক পাতায়।" % _name(child, g),
              "%s can now see your location. See everyone on the Guardians page." % _name(child, g),
              {"link_id": link.id, "state": "approved", "child_view": True})
    else:
        _tell([g], "অনুরোধ গ্রহণ হয়নি", "Request not approved",
              "%s-এর অভিভাবক হওয়ার অনুরোধ গ্রহণ হয়নি। কিছুই শেয়ার হয়নি।" % _name(g, child),
              "Your request to be a guardian of %s was not approved. Nothing was shared."
              % _name(g, child), {"link_id": link.id, "state": "rejected"})
    return link


def remove(user, link_id, now=None):
    """Remove an approved co-guardian (any guardian of the child), let the
    co-guardian leave, or cancel an unused / pending invite. Both guardians +
    the child are told when an approved guardian goes."""
    from .models import GuardianLink
    now = now or timezone.now()
    with transaction.atomic():
        link = (GuardianLink.objects.select_for_update().select_related("child", "guardian")
                .filter(pk=link_id).first())
        if link is None or link.state not in ("approved",) + LIVE:
            raise LinkError("not_found", 404)
        is_self = user.id == link.guardian_id
        if not is_self and not _approver_ok(user, link):
            raise LinkError("not_found", 404)
        was = link.state
        link.state, link.ended_at, link.ended_by = "removed", now, user
        link.save(update_fields=["state", "ended_at", "ended_by"])
        if was == "approved":
            _sync_features(link, add=False)
    g, child = link.guardian, link.child
    if was != "approved":
        if g is not None and not is_self:
            _tell([g], "অনুরোধ বাতিল", "Request cancelled",
                  "%s-এর অভিভাবক হওয়ার অনুরোধ বাতিল হয়েছে।" % _name(g, child),
                  "The request to be a guardian of %s was cancelled." % _name(g, child),
                  {"link_id": link.id, "state": "removed"})
        return link
    gname, uname, cname = g.name or "", user.name or "", child.name or ""
    if is_self:
        bn, en = ("%s নিজে %s-এর অভিভাবক থেকে সরে গেছেন।" % (gname, cname),
                  "%s left as a guardian of %s." % (gname, cname))
    else:
        bn, en = ("%s, %s-কে %s-এর অভিভাবক থেকে সরিয়েছেন।" % (uname, gname, cname),
                  "%s removed %s as a guardian of %s." % (uname, gname, cname))
    tail_bn, tail_en = " এখন থেকে তিনি লোকেশন বা সতর্কতা পাবেন না।", \
        " They no longer see the location or get alerts."
    told = [g] + [_user(u) for u in sorted(guardian_ids(child)) if u != g.id]
    _tell(told, "অভিভাবক সরানো হয়েছে", "Guardian removed", bn + tail_bn, en + tail_en,
          {"link_id": link.id, "state": "removed"}, high=True)
    _tell([child], "কে তোমার লোকেশন দেখেন — বদলেছে", "Who can see your location changed",
          "%s আর তোমার লোকেশন দেখতে পারবেন না।" % _name(child, g),
          "%s can no longer see your location." % _name(child, g),
          {"link_id": link.id, "state": "removed", "child_view": True})
    return link


# ------------------------------------------------------------------ shapes
def _iso(dt):
    return dt.isoformat() if dt else None


def link_dict(link, viewer):
    return {
        "id": link.id, "state": link.state,
        "child_id": link.child_id, "child_name": _name(viewer, link.child),
        "guardian_id": link.guardian_id,
        "guardian_name": _name(viewer, link.guardian) if link.guardian_id else "",
        "invited_by_name": _name(viewer, link.invited_by),
        "code": link.code if (link.state == "invited" and link.invited_by_id == viewer.id) else "",
        "link": INVITE_URL % link.code if (link.state == "invited"
                                          and link.invited_by_id == viewer.id) else "",
        "expires_at": _iso(link.expires_at), "requested_at": _iso(link.requested_at),
        "approved_at": _iso(link.approved_at),
    }


def overview(user):
    """GET /guardians/links — for a guardian: requests waiting for MY approval,
    my unused invites, the co-guardians I approved/added (removable), and my
    own requests (waiting / approved)."""
    from .models import GuardianLink
    now = timezone.now()
    my_kids = set()
    try:
        from . import guardianship as G
        my_kids = {k["child_user_id"] for k in G.children_of(user) if k.get("child_user_id")}
    except Exception:  # noqa: BLE001
        my_kids = set()
    GuardianLink.objects.filter(child_id__in=my_kids, state="invited",
                                expires_at__lt=now).update(state="expired")
    rows = (GuardianLink.objects.filter(child_id__in=my_kids,
                                        state__in=("invited", "pending", "approved"))
            .exclude(guardian=user).select_related("child", "guardian", "invited_by"))
    to_approve, invites, co = [], [], []
    for r in rows:
        d = link_dict(r, user)
        d["max"] = max_guardians(r.child)
        if r.state == "pending":
            to_approve.append(d)
        elif r.state == "invited":
            if r.invited_by_id == user.id:
                invites.append(d)
        else:
            co.append(d)
    mine = [link_dict(r, user) for r in GuardianLink.objects.filter(
        guardian=user, state__in=("pending", "approved")).select_related(
        "child", "guardian", "invited_by")]
    return {"to_approve": to_approve, "invites": invites, "co_guardians": co,
            "my_requests": mine}


def pending_for_child(child):
    """For the child's own screen: requests waiting for approval (they can
    NOT see the child yet — the screen says so)."""
    from .models import GuardianLink
    return [{"id": r.id, "name": _name(child, r.guardian),
             "requested_at": _iso(r.requested_at)}
            for r in GuardianLink.objects.filter(child=child, state="pending",
                                                 guardian__isnull=False)
            .select_related("guardian")]


# --------------------------------------------------------------- SOS
def sos_extra_recipients(sender):
    """Approved co-guardians of `sender` (a child) + the guardians who
    approved them — so SOS / fall / check-in alerts ring BOTH guardians even
    when one of them is not in the child's My Circle."""
    from .models import GuardianLink, User
    ids = set()
    for g, d in GuardianLink.objects.filter(child=sender, state="approved") \
            .values_list("guardian_id", "decided_by_id"):
        ids.add(g)
        if d:
            ids.add(d)
    ids.discard(sender.id)
    ids.discard(None)
    if not ids:
        return []
    cur = guardian_ids(sender)
    return list(User.objects.filter(pk__in=[i for i in ids if i in cur]))


def responding(user, delivery_id, now=None):
    """POST /family/alerts/<id>/responding — "I am going". The other people
    who got the same SOS and the sender see "<name> is responding"."""
    from . import push
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    d = (FamilyAlertDelivery.objects.select_related("sender")
         .filter(pk=delivery_id, recipient=user, kind__in=("sos", "fall")).first())
    if d is None:
        return None
    first = d.responding_at is None
    if first:
        d.responding_at = now
        if d.seen_at is None:
            d.seen_at = now
        if d.received_at is None:
            d.received_at = now
        d.save(update_fields=["responding_at", "seen_at", "received_at"])
    if first:
        others = list(FamilyAlertDelivery.objects.filter(event_key=d.event_key)
                      .exclude(recipient=user).select_related("recipient"))
        for o in others:
            n = _name(o.recipient, user)
            push.safe_push(o.recipient, "family_alert", "%s সাড়া দিচ্ছেন" % n,
                           "%s is responding" % n,
                           "%s জানিয়েছেন তিনি যাচ্ছেন / ব্যবস্থা নিচ্ছেন।" % n,
                           "%s says they are on it." % n,
                           data={"route": "family/alerts", "event": "sos_responding",
                                 "delivery_id": o.id, "responder_id": user.id},
                           high_priority=True)
        if d.sender is not None:
            n = _name(d.sender, user)
            push.safe_push(d.sender, "family_alert", "%s আসছেন" % n,
                           "%s is responding" % n,
                           "%s তোমার SOS দেখেছেন এবং সাড়া দিচ্ছেন।" % n,
                           "%s saw your SOS and is responding." % n,
                           data={"route": "safety/sos", "event": "sos_responding",
                                 "responder_id": user.id},
                           high_priority=True)
    return {"responders": responders(d.event_key, user)}


def responders(event_key, viewer):
    """[{name, at, me}] — who tapped "I am responding" for one SOS event."""
    from .models import FamilyAlertDelivery
    out = []
    for o in (FamilyAlertDelivery.objects.filter(event_key=event_key,
                                                 responding_at__isnull=False)
              .select_related("recipient").order_by("responding_at")):
        out.append({"name": _name(viewer, o.recipient), "at": _iso(o.responding_at),
                    "me": o.recipient_id == getattr(viewer, "id", None)})
    return out
