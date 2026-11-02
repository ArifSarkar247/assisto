"""guardianship.py — many-to-many guardianship across features (circlea).

ONE answer to "who guards this child?" and "which children do I guard, and
with whom?", built from the features that already carry consent:

  kids_watch   KidsWatch.owner + guardian_ids  (child = KidsWatch.child_user)
  school_mode  SchoolPlan.owner + watcher_ids  (child = SchoolPlan.child_user;
               only while enabled; a phone plan only once the child accepted)
  journey      JourneyRequest.requester for a LIVE request whose traveller is
               the child (standing child mode or a one-off the child accepted)

Benchmark: Google Family Link (several parents per child, each parent sees
every child, the child sees every parent), Life360 (everyone in the Circle
gets the alert).  Rules:

  * Every guardian of a child is told about the child's safety alerts
    (alert_audience) — not just the parent who set the feature up.  A
    co-guardian from ANOTHER feature is added only while they are an
    accepted, unblocked Circle peer of the child (re-checked every time).
  * The child always sees every watcher by name (guardians_of).
  * The child may remove a guardian where the feature's consent rule lets the
    child decide (remove_guardian): school-mode watchers (the child accepted
    the plan; stopping a plan was already one tap), guardian journeys (the
    traveller consents to every request).  A kids watch is set up by the
    parent who owns it — the child cannot remove that; the answer says so
    and names who can.  Nothing here touches billing (safety is never paid).

Public API (agent/missing builds on it):
    guardians_of(child)                 -> [ {id, name, sources:[...]} ]
    children_of(guardian)               -> [ {key, name, child_user_id,
                                             sources:[...], co_guardians:[...]} ]
    alert_audience(owner, ids, child)   -> [User] owner + ids + co-guardians
    guardian_user_ids(child)            -> set of user ids
    remove_guardian(child, guardian_id) -> {"removed": [...], "kept": [...]}
"""
from __future__ import annotations

from django.utils import timezone

SRC_WATCH = "kids_watch"
SRC_SCHOOL = "school_mode"
SRC_JOURNEY = "journey"
JOURNEY_LIVE = ("pending", "accepted", "active")


def _peer_ok(owner_id, user_id):
    from .models import CircleMember
    return CircleMember.objects.filter(user_id=owner_id, peer_user_id=user_id,
                                       state="accepted", blocked=False).exists()


def _ids(raw):
    out = []
    for x in raw or []:
        try:
            out.append(int(x))
        except (TypeError, ValueError):
            continue
    return out


def _name(viewer, user):
    from . import push
    try:
        return push.seen_name(viewer, user) if viewer is not None else push.display_name(user)
    except Exception:  # noqa: BLE001
        return getattr(user, "name", "") or ""


# ------------------------------------------------------------- raw links
def _links_for_child(child):
    """[(guardian_user_id, source_dict)] for one child account."""
    from .models import JourneyRequest, KidsWatch, SchoolPlan
    out = []
    for w in KidsWatch.objects.filter(child_user=child).exclude(state="disabled"):
        out.append((w.owner_id, {"kind": SRC_WATCH, "ref": w.id, "role": "owner",
                                 "owner_id": w.owner_id}))
        for uid in _ids(w.guardian_ids):
            if uid != w.owner_id and _peer_ok(w.owner_id, uid):
                out.append((uid, {"kind": SRC_WATCH, "ref": w.id, "role": "guardian",
                                  "owner_id": w.owner_id}))
    for p in SchoolPlan.objects.filter(child_user=child, enabled=True):
        if p.watch_id is None and p.accepted_at is None:
            continue           # a phone plan the child has not accepted yet
        out.append((p.owner_id, {"kind": SRC_SCHOOL, "ref": p.id, "role": "owner",
                                 "owner_id": p.owner_id}))
        for uid in _ids(p.watcher_ids):
            if uid != p.owner_id and _peer_ok(p.owner_id, uid):
                out.append((uid, {"kind": SRC_SCHOOL, "ref": p.id, "role": "guardian",
                                  "owner_id": p.owner_id}))
    for r in JourneyRequest.objects.filter(traveller=child,
                                           status__in=("accepted", "active")):
        out.append((r.requester_id, {"kind": SRC_JOURNEY, "ref": r.id, "role": "owner",
                                     "owner_id": r.requester_id,
                                     "standing": bool(r.standing),
                                     "live": r.status == "active"}))
    return [(uid, s) for uid, s in out if uid and uid != child.id]


def _removable(src):
    # consent rules (see module doc): the child decides on school mode +
    # journeys; a kids watch belongs to the parent who set it up.
    return src["kind"] in (SRC_SCHOOL, SRC_JOURNEY)


def guardian_user_ids(child):
    if child is None:
        return set()
    return {uid for uid, _s in _links_for_child(child)}


def guardians_of(child):
    """Every guardian of `child`, by name, with what they see and whether the
    child can remove them.  Ordered by name; nobody is listed twice."""
    from .models import User
    links = _links_for_child(child)
    users = {u.id: u for u in User.objects.filter(pk__in={uid for uid, _ in links})}
    rows = {}
    for uid, src in links:
        u = users.get(uid)
        if u is None:
            continue
        row = rows.setdefault(uid, {"id": uid, "name": _name(child, u), "sources": []})
        owner = users.get(src["owner_id"]) or (
            User.objects.filter(pk=src["owner_id"]).first())
        row["sources"].append({**{k: v for k, v in src.items() if k != "owner_id"},
                               "removable": _removable(src),
                               "set_up_by": _name(child, owner) if owner else ""})
    out = list(rows.values())
    for r in out:
        r["removable"] = any(s["removable"] for s in r["sources"])
    out.sort(key=lambda r: (r["name"] or "").lower())
    return out


# ----------------------------------------------------------- guardian side
def _peers_of(user):
    """Users who have an accepted edge TO `user` (they may list `user` as a
    guardian on their own watch / plan)."""
    from .models import CircleMember
    return set(CircleMember.objects.filter(peer_user=user, state="accepted", blocked=False)
               .values_list("user_id", flat=True))


def children_of(guardian):
    """Every child `guardian` watches (own or shared), each with the OTHER
    guardians by name — "also watched by Dad".  Account-less children (a
    watch with no child account) are keyed by the watch."""
    from .models import JourneyRequest, KidsWatch, SchoolPlan, User
    me = guardian.id
    owners = _peers_of(guardian) | {me}
    kids = {}

    def add(key, name, child_id, src):
        k = kids.setdefault(key, {"key": key, "name": name, "child_user_id": child_id,
                                  "sources": []})
        if not k["name"] and name:
            k["name"] = name
        k["sources"].append(src)

    for w in KidsWatch.objects.filter(owner_id__in=owners).exclude(state="disabled"):
        mine = w.owner_id == me
        if not mine and not (me in _ids(w.guardian_ids) and _peer_ok(w.owner_id, me)):
            continue
        key = "u%d" % w.child_user_id if w.child_user_id else "w%d" % w.id
        add(key, w.child_name, w.child_user_id,
            {"kind": SRC_WATCH, "ref": w.id, "role": "owner" if mine else "guardian"})
    for p in SchoolPlan.objects.filter(owner_id__in=owners, enabled=True):
        mine = p.owner_id == me
        if not mine and not (me in _ids(p.watcher_ids) and _peer_ok(p.owner_id, me)):
            continue
        key = ("u%d" % p.child_user_id if p.child_user_id else
               ("w%d" % p.watch_id if p.watch_id else "p%d" % p.id))
        add(key, p.child_name, p.child_user_id,
            {"kind": SRC_SCHOOL, "ref": p.id, "role": "owner" if mine else "guardian"})
    for r in JourneyRequest.objects.filter(requester=guardian, status__in=JOURNEY_LIVE) \
            .select_related("traveller"):
        add("u%d" % r.traveller_id, _name(guardian, r.traveller), r.traveller_id,
            {"kind": SRC_JOURNEY, "ref": r.id, "role": "owner", "status": r.status})
    child_ids = {k["child_user_id"] for k in kids.values() if k["child_user_id"]}
    cusers = {u.id: u for u in User.objects.filter(pk__in=child_ids)}
    for k in kids.values():
        cu = cusers.get(k["child_user_id"])
        if cu is not None:
            k["name"] = _name(guardian, cu) or k["name"]
            others = [g for g in guardians_of(cu) if g["id"] != me]
            k["co_guardians"] = [{"id": g["id"], "name": _co_name(guardian, g)}
                                 for g in others]
        else:
            k["co_guardians"] = _co_from_sources(guardian, k["sources"])
    out = sorted(kids.values(), key=lambda k: (k["name"] or "").lower())
    return out


def _co_name(viewer, g):
    from .models import User
    u = User.objects.filter(pk=g["id"]).first()
    return _name(viewer, u) if u else g["name"]


def _co_from_sources(viewer, sources):
    """Co-guardians of an account-less child (watch / plan rows only)."""
    from .models import KidsWatch, SchoolPlan, User
    ids = set()
    for s in sources:
        if s["kind"] == SRC_WATCH:
            w = KidsWatch.objects.filter(pk=s["ref"]).first()
            if w:
                ids |= {w.owner_id} | {u for u in _ids(w.guardian_ids)
                                       if _peer_ok(w.owner_id, u)}
        elif s["kind"] == SRC_SCHOOL:
            p = SchoolPlan.objects.filter(pk=s["ref"]).first()
            if p:
                ids |= {p.owner_id} | {u for u in _ids(p.watcher_ids)
                                       if _peer_ok(p.owner_id, u)}
    ids.discard(viewer.id)
    return [{"id": u.id, "name": _name(viewer, u)}
            for u in User.objects.filter(pk__in=ids).order_by("name")]


# ---------------------------------------------------------------- fan-out
def alert_audience(owner, ids, child=None):
    """Who gets a child's safety alert: the feature's owner + its chosen
    guardians (still-valid peers of the owner) + EVERY other guardian of the
    child from any feature, while they are an accepted, unblocked Circle
    peer of the child.  Deduplicated, owner first, never the child."""
    from .models import User
    first = [owner.id] if owner is not None else []
    want = list(first)
    for uid in _ids(ids):
        if uid not in want and owner is not None and _peer_ok(owner.id, uid):
            want.append(uid)
    if child is not None:
        for uid in sorted(guardian_user_ids(child)):
            if uid not in want and (_peer_ok(child.id, uid) or _peer_ok(uid, child.id)):
                want.append(uid)
    if child is not None:
        want = [u for u in want if u != child.id]
    users = {u.id: u for u in User.objects.filter(pk__in=want)}
    return [users[u] for u in want if u in users]


# ---------------------------------------------------------------- removal
def remove_guardian(child, guardian_id, now=None):
    """The CHILD removes one guardian from everything the child may decide.
    Returns {"removed": [{kind, ref}], "kept": [{kind, ref, set_up_by}]}."""
    from . import guardian_journey as GJ
    from . import kidswatch_service as KW
    from .models import JourneyRequest, SchoolPlan, User
    now = now or timezone.now()
    gid = int(guardian_id)
    g = User.objects.filter(pk=gid).first()
    removed, kept = [], []
    if g is None:
        return {"removed": removed, "kept": kept}
    gname = _name(None, child) or ""
    for p in SchoolPlan.objects.filter(child_user=child):
        if p.owner_id == gid:
            if p.enabled:
                p.enabled = False
                p.save(update_fields=["enabled", "updated_at"])
                removed.append({"kind": SRC_SCHOOL, "ref": p.id, "stopped": True})
                KW._send(KW.plan_watchers(p), "স্কুল-মোড বন্ধ করা হয়েছে",
                         "School mode was turned off",
                         "%s স্কুল-মোড বন্ধ করেছে।" % (p.child_name or gname),
                         "%s turned School Mode off." % (p.child_name or gname),
                         {"plan_id": p.id, "event": "stopped_by_child"},
                         family_alert=False)
        elif gid in _ids(p.watcher_ids):
            p.watcher_ids = [u for u in _ids(p.watcher_ids) if u != gid]
            p.save(update_fields=["watcher_ids", "updated_at"])
            removed.append({"kind": SRC_SCHOOL, "ref": p.id})
            KW._send([p.owner, g], "স্কুল-মোড থেকে সরানো হয়েছে",
                     "Removed from School Mode",
                     "%s নিজে %s-কে স্কুল-মোড দেখা থেকে সরিয়েছে।" % (
                         p.child_name or gname, g.name or ""),
                     "%s removed %s from School Mode." % (p.child_name or gname, g.name or ""),
                     {"plan_id": p.id, "event": "watcher_removed_by_child"},
                     family_alert=False)
    for r in JourneyRequest.objects.filter(traveller=child, requester_id=gid,
                                           status__in=JOURNEY_LIVE):
        GJ.finish(r, "withdrawn", now, by="traveller")
        r.refresh_from_db()
        if r.status not in ("ended", "declined"):
            r.status = "ended"
            r.save(update_fields=["status", "updated_at"])
        removed.append({"kind": SRC_JOURNEY, "ref": r.id})
        tn = GJ._name(r.requester, child)
        GJ.notify(r.requester, r, "withdrawn", "%s সম্মতি ফিরিয়ে নিয়েছেন" % tn,
                  "%s withdrew consent" % tn, "এই যাত্রা আর শেয়ার হবে না।",
                  "Trips will not be shared any more.")
    for uid, src in _links_for_child(child):
        if uid == gid and src["kind"] == SRC_WATCH:
            owner = User.objects.filter(pk=src["owner_id"]).first()
            kept.append({"kind": SRC_WATCH, "ref": src["ref"],
                         "set_up_by": _name(child, owner) if owner else ""})
    return {"removed": removed, "kept": kept}
