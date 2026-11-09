"""fcscreen (Family Care v3, owner order 9 Nov 10:50) — multi-family membership,
shared family tasks and the Family board. Public helpers are the interface
other agents use (owner_actions/FAMILY_CARE_V3_API.md §2); every helper is
defensive (never raises into a caller; [] / False when anything is missing).

Trust rules (server-enforced here):
  * adults join ONLY by accepting on their own phone (invited -> active);
  * a child is added active only by an approved guardian (guardian_links);
  * only accepted, unblocked My Circle peers can be invited;
  * anyone can leave any time; an admin can remove others, not themselves;
  * nothing here is exposed to Django staff/admin views (no place, no location).
"""
import logging
from datetime import timedelta

from django.db import transaction
from django.utils import timezone

from .logic import family_status as FS

log = logging.getLogger(__name__)

MAX_FAMILIES = 5
MAX_MEMBERS = 20
MAX_OPEN_TASKS = 50
ROLES = ("admin", "adult", "child", "elder")
RELATIONS = ("son", "daughter", "mother", "father", "spouse", "brother", "sister",
             "grandparent", "grandchild", "other")
TASK_KINDS = ("medicine", "doctor", "bill", "other")
AMBER_TTL_MAX_S = 7 * 86400


# ------------------------------------------------------------------ basics
def _models():
    from .models import FcFamily, FcMembership, FcTask
    return FcFamily, FcMembership, FcTask


def _active(user):
    _, M, _ = _models()
    return M.objects.filter(user=user, state="active")


def families_of(user):
    try:
        return [m.family for m in _active(user).select_related("family").order_by("id")]
    except Exception:  # noqa: BLE001 — interface helper never raises
        return []


def family_ids_of(user):
    try:
        return list(_active(user).order_by("id").values_list("family_id", flat=True))
    except Exception:  # noqa: BLE001
        return []


def membership(user, family_id):
    try:
        return _active(user).filter(family_id=family_id).select_related("family").first()
    except Exception:  # noqa: BLE001
        return None


def role_of(user, family_id):
    m = membership(user, family_id)
    return m.role if m else None


def member_ids(family_id):
    try:
        _, M, _ = _models()
        return list(M.objects.filter(family_id=family_id, state="active")
                    .order_by("id").values_list("user_id", flat=True))
    except Exception:  # noqa: BLE001
        return []


def co_member_ids(user, family_id=None):
    try:
        _, M, _ = _models()
        fams = family_ids_of(user) if family_id is None else (
            [family_id] if membership(user, family_id) else [])
        ids = (M.objects.filter(family_id__in=fams, state="active")
               .exclude(user_id=user.id).values_list("user_id", flat=True))
        return sorted(set(ids))
    except Exception:  # noqa: BLE001
        return []


def shares_family(a, b):
    if a is None or b is None or a.id == b.id:
        return False
    return b.id in co_member_ids(a)


def someone_abroad(family_id):
    try:
        _, M, _ = _models()
        return M.objects.filter(family_id=family_id, state="active").exclude(
            abroad_tz="").exists()
    except Exception:  # noqa: BLE001
        return False


def _name(viewer, user):
    try:
        from . import push as PUSH
        return PUSH.seen_name(viewer, user) if viewer else PUSH.display_name(user)
    except Exception:  # noqa: BLE001
        return (getattr(user, "name", "") or "").strip()


def _phone(viewer, user):
    """The number the viewer has for this person (their Circle edge first)."""
    try:
        from .models import CircleMember
        e = CircleMember.objects.filter(user=viewer, peer_user=user, state="accepted",
                                        blocked=False).first()
        if e is not None and (e.phone or "").strip():
            return e.phone.strip()
    except Exception:  # noqa: BLE001
        pass
    return (getattr(user, "phone", "") or "").strip()


def members_of(user):
    """UNION over all the user's families, excluding the user, deduped:
    [{user_id, name, phone, relation, label, role, family_ids}] (fcsos uses it
    for SOS recipients, fcelder for the ladder)."""
    try:
        _, M, _ = _models()
        fams = family_ids_of(user)
        out = {}
        for m in (M.objects.filter(family_id__in=fams, state="active")
                  .exclude(user_id=user.id).select_related("user").order_by("id")):
            r = out.get(m.user_id)
            if r is None:
                out[m.user_id] = {"user_id": m.user_id, "name": _name(user, m.user),
                                  "phone": _phone(user, m.user), "relation": m.relation,
                                  "label": m.label, "role": m.role,
                                  "family_ids": [m.family_id]}
            else:
                r["family_ids"].append(m.family_id)
                r["relation"] = r["relation"] or m.relation
                r["label"] = r["label"] or m.label
        return list(out.values())
    except Exception:  # noqa: BLE001
        return []


# ---------------------------------------------------------- amber status
def set_member_status(user, state, reason, source, ttl_s=None, now=None):
    """Another module raises an amber status on `user` (all their families).
    Only 'amber' is accepted (red = SOS belongs to fcsos; gray/green are
    computed from fresh data, never set by hand)."""
    if state not in ("amber", "check") or not source:
        return False
    try:
        _, M, _ = _models()
        now = now or timezone.now()
        until = None
        if ttl_s:
            until = (now + timedelta(seconds=max(60, min(int(ttl_s), AMBER_TTL_MAX_S)))
                     ).isoformat()
        payload = {"state": "amber", "reason": str(reason or "")[:24],
                   "source": str(source)[:16], "at": now.isoformat(), "until": until}
        for m in M.objects.filter(user=user, state="active"):
            a = m.alert if isinstance(m.alert, dict) else {}
            a = dict(a)
            a[payload["source"]] = payload
            m.alert = a
            m.save(update_fields=["alert"])
        return True
    except Exception as e:  # noqa: BLE001
        log.warning("family_v3: set_member_status failed %s", type(e).__name__)
        return False


def clear_member_status(user, source):
    try:
        _, M, _ = _models()
        for m in M.objects.filter(user=user).exclude(alert={}):
            a = dict(m.alert or {})
            if a.pop(str(source)[:16], None) is not None:
                m.alert = a
                m.save(update_fields=["alert"])
        return True
    except Exception:  # noqa: BLE001
        return False


def _amber_flags(alert, now):
    """{source: payload} -> flags for FS.member_status (only unexpired)."""
    flags = {}
    for p in (alert or {}).values() if isinstance(alert, dict) else []:
        if not isinstance(p, dict) or p.get("state") != "amber":
            continue
        until = FS.parse_ts(p.get("until"))
        if until is not None and until <= now:
            continue
        reason = p.get("reason") or "watch"
        if reason in FS.AMBER_FLAGS:
            flags[reason] = True
        else:
            flags.setdefault("amber_reason", reason)
    return flags


# ------------------------------------------------------- family lifecycle
def ensure_default_family(user, name="My family"):
    """Every person has at least one family (created lazily, just them)."""
    try:
        fams = families_of(user)
        if fams:
            return fams[0]
        return create_family(user, name)[0]
    except Exception:  # noqa: BLE001
        return None


def create_family(user, name):
    F, M, _ = _models()
    name = (name or "").strip()[:60]
    if not name:
        return None, "name_required"
    if _active(user).count() >= MAX_FAMILIES:
        return None, "family_limit"
    with transaction.atomic():
        f = F.objects.create(name=name, created_by=user)
        M.objects.create(family=f, user=user, role="admin", state="active",
                         joined_at=timezone.now())
    return f, None


def rename_family(user, family_id, name):
    m = membership(user, family_id)
    if m is None or m.role != "admin":
        return "forbidden"
    name = (name or "").strip()[:60]
    if not name:
        return "name_required"
    m.family.name = name
    m.family.save(update_fields=["name"])
    return None


def invite(inviter, family_id, circle_member_id, role="adult", label="", relation=""):
    """-> (membership, error). Only an accepted, unblocked My Circle peer."""
    from .models import CircleMember
    _, M, _ = _models()
    me = membership(inviter, family_id)
    if me is None or me.role == "child":
        return None, "forbidden"
    role = role if role in ROLES and role != "admin" else "adult"
    edge = CircleMember.objects.filter(user=inviter, pk=circle_member_id, state="accepted",
                                       blocked=False).select_related("peer_user").first()
    if edge is None or edge.peer_user is None:
        return None, "not_in_circle"
    peer = edge.peer_user
    if M.objects.filter(family_id=family_id, state__in=("active", "invited")).count() >= MAX_MEMBERS:
        return None, "member_limit"
    direct = False
    if role == "child":
        try:
            from . import guardian_links as GL
            direct = GL.is_guardian(inviter, peer)
        except Exception:  # noqa: BLE001
            direct = False
        if not direct:
            return None, "not_guardian"
    if relation and relation not in RELATIONS:
        relation = "other"
    now = timezone.now()
    with transaction.atomic():
        m = M.objects.select_for_update().filter(family_id=family_id, user=peer).first()
        if m is not None and m.state == "active":
            return m, None
        if m is None:
            m = M(family_id=family_id, user=peer)
        if direct and _active(peer).count() >= MAX_FAMILIES:
            return None, "family_limit"
        m.role, m.invited_by = role, inviter
        m.label = (label or m.label or "")[:40]
        m.relation = relation or m.relation or (edge.relation if edge.relation in RELATIONS else "")
        m.state = "active" if direct else "invited"
        m.joined_at = now if direct else None
        m.left_at = None
        m.save()
    if not direct:
        _tell(peer, "family_invite",
              "%s আপনাকে পরিবারে যোগ হতে বলেছেন" % _name(peer, inviter),
              "%s invited you to a family" % _name(peer, inviter),
              "খুলে হ্যাঁ বা না বলুন — আপনার অনুমতি ছাড়া কেউ যোগ করতে পারে না।",
              "Open it to accept or decline — nobody can add you without your OK.",
              {"route": "family", "membership_id": m.id})
    return m, None


def answer_invite(user, membership_id, accept):
    _, M, _ = _models()
    m = M.objects.filter(pk=membership_id, user=user, state="invited").select_related(
        "family").first()
    if m is None:
        return None, "not_found"
    if accept and _active(user).count() >= MAX_FAMILIES:
        return None, "family_limit"
    m.state = "active" if accept else "declined"
    m.joined_at = timezone.now() if accept else None
    m.save(update_fields=["state", "joined_at"])
    if accept and m.invited_by_id:
        _tell(m.invited_by, "family_joined",
              "%s পরিবারে যোগ দিয়েছেন" % _name(m.invited_by, user),
              "%s joined the family" % _name(m.invited_by, user), "", "",
              {"route": "family", "family_id": m.family_id})
    return m, None


def leave(user, family_id):
    """Anyone can leave any time. The last admin leaving hands admin to the
    longest-standing adult so the family is never stuck."""
    try:
        _, M, _ = _models()
        with transaction.atomic():
            m = M.objects.select_for_update().filter(user=user, family_id=family_id,
                                                     state="active").first()
            if m is None:
                return False
            was_admin = m.role == "admin"
            m.state, m.left_at, m.alert = "left", timezone.now(), {}
            m.save(update_fields=["state", "left_at", "alert"])
            if was_admin and not M.objects.filter(family_id=family_id, state="active",
                                                  role="admin").exists():
                nxt = (M.objects.filter(family_id=family_id, state="active")
                       .exclude(role="child").order_by("joined_at", "id").first())
                if nxt is not None:
                    nxt.role = "admin"
                    nxt.save(update_fields=["role"])
        return True
    except Exception:  # noqa: BLE001
        return False


def remove_member(admin, family_id, user_id):
    me = membership(admin, family_id)
    if me is None or me.role != "admin":
        return "forbidden"
    if user_id == admin.id:
        return "use_leave"
    _, M, _ = _models()
    n = M.objects.filter(family_id=family_id, user_id=user_id,
                         state__in=("active", "invited")).update(
        state="left", left_at=timezone.now(), alert={})
    return None if n else "not_found"


def update_member(viewer, family_id, user_id, data):
    """label / relation: admin or the member themself; abroad_tz: self only."""
    me = membership(viewer, family_id)
    if me is None:
        return "forbidden"
    _, M, _ = _models()
    m = M.objects.filter(family_id=family_id, user_id=user_id, state="active").first()
    if m is None:
        return "not_found"
    is_self = viewer.id == user_id
    if not (is_self or me.role == "admin"):
        return "forbidden"
    fields = []
    if "label" in data:
        m.label = str(data.get("label") or "").strip()[:40]
        fields.append("label")
    if "relation" in data:
        r = str(data.get("relation") or "")
        m.relation = r if r in RELATIONS else ""
        fields.append("relation")
    if "abroad_tz" in data:
        if not is_self:
            return "forbidden"
        tz = str(data.get("abroad_tz") or "").strip()[:40]
        if tz:
            try:
                from zoneinfo import ZoneInfo
                ZoneInfo(tz)
            except Exception:  # noqa: BLE001
                return "bad_tz"
        m.abroad_tz = tz
        fields.append("abroad_tz")
    if "role" in data and me.role == "admin" and not is_self:
        r = str(data.get("role") or "")
        if r in ("adult", "elder", "admin"):
            m.role = r
            fields.append("role")
    if fields:
        m.save(update_fields=fields)
    return None


def _tell(user, kind, tbn, ten, bbn, ben, data):
    try:
        from . import push as PUSH
        PUSH.safe_push(user, kind, tbn, ten, bbn, ben, data=data)
    except Exception:  # noqa: BLE001
        pass


# ----------------------------------------------------------------- tasks
def task_dict(viewer, t):
    return {"id": t.id, "title": t.title, "kind": t.kind,
            "due_date": t.due_date.isoformat() if t.due_date else None,
            "created_by": t.created_by_id,
            "created_by_name": _name(viewer, t.created_by) if t.created_by else "",
            "taken_by": t.taken_by_id,
            "taken_by_name": _name(viewer, t.taken_by) if t.taken_by else "",
            "taken_at": t.taken_at.isoformat() if t.taken_at else None,
            "mine": t.taken_by_id == viewer.id,
            "done": t.done_at is not None,
            "done_by_name": _name(viewer, t.done_by) if t.done_by else "",
            "done_at": t.done_at.isoformat() if t.done_at else None}


def open_tasks(viewer, family_id, now=None):
    _, _, T = _models()
    now = now or timezone.now()
    from django.db.models import Q
    qs = T.objects.filter(family_id=family_id).filter(
        Q(done_at__isnull=True) | Q(done_at__gte=now - timedelta(hours=24)))
    rows = list(qs.select_related("created_by", "taken_by", "done_by").order_by("-id")[:60])
    rows.sort(key=lambda t: (t.done_at is not None, t.taken_by_id is not None,
                             t.due_date or now.date() + timedelta(days=3650), -t.id))
    return [task_dict(viewer, t) for t in rows]


def add_task(viewer, family_id, title, kind="other", due_date=None):
    if membership(viewer, family_id) is None:
        return None, "forbidden"
    _, _, T = _models()
    title = (title or "").strip()[:120]
    if not title:
        return None, "title_required"
    if kind not in TASK_KINDS:
        kind = "other"
    if T.objects.filter(family_id=family_id, done_at__isnull=True).count() >= MAX_OPEN_TASKS:
        return None, "task_limit"
    t = T.objects.create(family_id=family_id, title=title, kind=kind, due_date=due_date,
                         created_by=viewer)
    for uid in co_member_ids(viewer, family_id):
        _tell_task(viewer, uid, t)
    return t, None


def _tell_task(viewer, uid, t):
    try:
        from .models import User
        u = User.objects.filter(pk=uid).first()
        if u is None:
            return
        try:
            from . import notif_budget   # fcbrain: <= 3 non-safety notifications/day
            if not notif_budget.allow(u, "family_task", False):
                return
        except ImportError:
            pass
        who = _name(u, viewer)
        _tell(u, "family_task", "পরিবারের কাজ: %s" % t.title, "Family task: %s" % t.title,
              "%s যোগ করেছেন — কে করবেন?" % who, "%s added it — who will do it?" % who,
              {"route": "family", "family_id": t.family_id, "task_id": t.id})
    except Exception:  # noqa: BLE001
        pass


def task_action(viewer, task_id, action):
    _, _, T = _models()
    with transaction.atomic():
        t = T.objects.select_for_update().filter(pk=task_id).first()
        if t is None or membership(viewer, t.family_id) is None:
            return None, "not_found"
        now = timezone.now()
        if action == "take":
            if t.done_at is not None:
                return None, "already_done"
            if t.taken_by_id and t.taken_by_id != viewer.id:
                return None, "already_taken"
            t.taken_by, t.taken_at = viewer, now
        elif action == "release":
            if t.taken_by_id != viewer.id:
                return None, "forbidden"
            t.taken_by, t.taken_at = None, None
        elif action == "done":
            if t.done_at is None:
                t.done_by, t.done_at = viewer, now
                if t.taken_by_id is None:
                    t.taken_by, t.taken_at = viewer, now
        elif action == "undo":
            t.done_by, t.done_at = None, None
        elif action == "delete":
            if t.created_by_id != viewer.id and role_of(viewer, t.family_id) != "admin":
                return None, "forbidden"
            t.delete()
            return None, None
        else:
            return None, "bad_action"
        t.save()
    return t, None


# ----------------------------------------------------------------- board
def _brain(viewer, member, now):
    """fcbrain's member_brain_state (battery, place, pause, heartbeat), then
    the app's own presence heartbeat: a phone that used Assisto recently IS
    fresh news, so the newer of the two timestamps wins. Never invents data —
    no source at all = {} = gray "never"."""
    b = {}
    try:
        from . import family_brain   # fcbrain
        got = family_brain.member_brain_state(viewer, member)
        if isinstance(got, dict):
            b = dict(got)
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001
        log.warning("family_v3: brain state failed %s", type(e).__name__)
    try:
        from .models import CirclePresence
        p = CirclePresence.objects.filter(user=member).first()
        if p is not None and p.last_seen:
            mine = FS.parse_ts(b.get("last_seen"))
            if mine is None or p.last_seen > mine:
                b["last_seen"] = p.last_seen.isoformat()
                b.setdefault("source", "presence")
    except Exception:  # noqa: BLE001
        pass
    return b


def _sos_ids(viewer, family_id, ids, now):
    try:
        from . import family_sos_v3   # fcsos
        return set(family_sos_v3.active_sos_user_ids(family_id))
    except ImportError:
        pass
    except Exception:  # noqa: BLE001
        pass
    try:
        from .models import FamilyAlert
        out = set()
        for p in (FamilyAlert.objects.filter(user=viewer, kind="sos", dismissed=False,
                                              created_at__gte=now - timedelta(hours=24))
                  .values_list("payload", flat=True)):
            uid = (p or {}).get("from_user_id")
            if uid in ids:
                out.add(uid)
        return out
    except Exception:  # noqa: BLE001
        return set()


def _local_day(now):
    try:
        from zoneinfo import ZoneInfo
        return timezone.localtime(now, ZoneInfo("Asia/Dhaka")).date()
    except Exception:  # noqa: BLE001
        return now.date()


def _day_bounds(now):
    from zoneinfo import ZoneInfo
    from datetime import datetime, time
    tz = ZoneInfo("Asia/Dhaka")
    d = _local_day(now)
    start = datetime.combine(d, time(0, 0), tzinfo=tz)
    return start, start + timedelta(days=1)


def _carecall_today(ids, now):
    """{receiver_id: {done, missed, pending}} for Care Calls set AND received
    inside this family, today (Dhaka)."""
    out = {}
    try:
        from .models import CareCallRing
        start, end = _day_bounds(now)
        for r in (CareCallRing.objects.filter(
                care_call__receiver_id__in=ids, care_call__setter_id__in=ids,
                scheduled_at__gte=start, scheduled_at__lt=end)
                .values("care_call__receiver_id", "status")):
            row = out.setdefault(r["care_call__receiver_id"],
                                 {"done": 0, "missed": 0, "pending": 0})
            st = r["status"]
            row["done" if st == "done" else "missed" if st == "missed" else "pending"] += 1
    except Exception:  # noqa: BLE001
        pass
    return out


def _chip(status, brain, cc, now):
    """One chip per card (owner order d)."""
    st = status["state"]
    if st == "paused":
        return {"kind": "paused", "until": brain.get("paused_until")}
    if st == "stale":
        return {"kind": "no_news"}
    if cc and cc.get("missed"):
        return {"kind": "carecall_missed"}
    ev = brain.get("last_event") if isinstance(brain.get("last_event"), dict) else None
    if ev and ev.get("kind") in ("arrived", "left", "journey"):
        at = FS.parse_ts(ev.get("at"))
        if at is not None and now - at <= timedelta(hours=12):
            return {"kind": ev["kind"], "at": ev.get("at"), "place": ev.get("place") or "",
                    "eta": ev.get("eta"), "auto": bool(ev.get("auto", True))}
    if cc and cc.get("done"):
        return {"kind": "carecall_done"}
    return None


def member_rows(viewer, family_id, now=None):
    _, M, _ = _models()
    now = now or timezone.now()
    ms = list(M.objects.filter(family_id=family_id, state="active").select_related("user"))
    ids = [m.user_id for m in ms]
    sos = _sos_ids(viewer, family_id, set(ids), now)
    cc = _carecall_today(ids, now)
    rows = []
    for m in ms:
        u = m.user
        brain = _brain(viewer, u, now)
        flags = _amber_flags(m.alert, now)
        if u.id in sos:
            flags["sos"] = True
        if cc.get(u.id, {}).get("missed"):
            flags["carecall_missed"] = True
        status = FS.member_status(brain, now, flags)
        rows.append({
            "user_id": u.id, "name": _name(viewer, u), "label": m.label,
            "relation": m.relation, "role": m.role, "me": u.id == viewer.id,
            "phone": _phone(viewer, u) if u.id != viewer.id else "",
            "abroad_tz": m.abroad_tz,
            "brain": {k: brain.get(k) for k in
                      ("last_seen", "battery", "charging", "net", "bg_restricted",
                       "paused_until", "interval_s", "place_label", "place_kind",
                       "last_event", "brand") if k in brain},
            "status": status, "chip": _chip(status, brain, cc.get(u.id), now),
            "carecall": cc.get(u.id) or {"done": 0, "missed": 0, "pending": 0},
        })
    rows.sort(key=lambda r: (r["me"],) + FS.sort_key(r))
    return rows


def board(viewer, family_id, now=None):
    me = membership(viewer, family_id)
    if me is None:
        return None
    now = now or timezone.now()
    rows = member_rows(viewer, family_id, now)
    others = [{"user_id": r["user_id"], "name": r["label"] or r["name"],
               "state": r["status"]["state"], "reason": r["status"]["reason"]}
              for r in rows if not r["me"]]
    return {"family": {"id": me.family_id, "name": me.family.name},
            "me": {"role": me.role, "user_id": viewer.id},
            "line": FS.family_line(others), "members": rows,
            "tasks": open_tasks(viewer, family_id, now),
            "today": today_block(viewer, family_id, rows, now),
            "someone_abroad": any(r["abroad_tz"] for r in rows),
            "invited": invited_rows(viewer, family_id),
            "server_now": now.isoformat()}


def invited_rows(viewer, family_id):
    _, M, _ = _models()
    return [{"user_id": m.user_id, "name": _name(viewer, m.user), "role": m.role}
            for m in M.objects.filter(family_id=family_id, state="invited")
            .select_related("user")[:20]]


def today_block(viewer, family_id, rows, now):
    cc = {"done": 0, "missed": 0, "pending": 0}
    for r in rows:
        for k in cc:
            cc[k] += r["carecall"][k]
    _, _, T = _models()
    day = _local_day(now)
    bills = T.objects.filter(family_id=family_id, kind="bill", done_at__isnull=True,
                             due_date__isnull=False, due_date__lte=day + timedelta(days=3)).count()
    births = []
    try:
        from .models import Birthday
        for b in Birthday.objects.filter(user=viewer, kind="birthday", date__month=day.month,
                                         date__day=day.day)[:5]:
            births.append(b.name)
    except Exception:  # noqa: BLE001
        pass
    bazar = 0
    try:
        from .models import FamilyListItem
        bazar = FamilyListItem.objects.filter(owner_id__in=[r["user_id"] for r in rows],
                                              done=False).count()
    except Exception:  # noqa: BLE001
        pass
    return {"carecalls": cc, "bills_due": bills, "birthdays": births, "bazar_open": bazar}


def families_payload(user):
    ensure_default_family(user)
    _, M, _ = _models()
    fams = []
    for m in _active(user).select_related("family").order_by("id"):
        fams.append({"id": m.family_id, "name": m.family.name, "role": m.role,
                     "member_count": M.objects.filter(family_id=m.family_id,
                                                      state="active").count(),
                     "someone_abroad": someone_abroad(m.family_id)})
    inv = []
    for m in M.objects.filter(user=user, state="invited").select_related(
            "family", "invited_by")[:10]:
        inv.append({"membership_id": m.id, "family_id": m.family_id,
                    "family_name": m.family.name, "role": m.role,
                    "invited_by_name": _name(user, m.invited_by) if m.invited_by else ""})
    return {"families": fams, "invites": inv, "max_families": MAX_FAMILIES}


# ----------------------------------------------------------- member page
def member_page(viewer, member_user_id, family_id, now=None):
    """Today timeline + who can see this member. The viewer must share
    `family_id` with the member (or be the member)."""
    from .models import User
    now = now or timezone.now()
    if membership(viewer, family_id) is None:
        return None
    member = User.objects.filter(pk=member_user_id).first()
    if member is None or membership(member, family_id) is None:
        return None
    row = next((r for r in member_rows(viewer, family_id, now)
                if r["user_id"] == member.id), None)
    timeline = []
    try:
        from . import family_brain   # fcbrain (optional)
        fn = getattr(family_brain, "member_timeline", None)
        if fn:
            timeline = list(fn(viewer, member, _local_day(now)) or [])
    except ImportError:
        pass
    except Exception:  # noqa: BLE001
        timeline = []
    timeline += _own_timeline(viewer, member, family_id, now)
    timeline.sort(key=lambda e: str(e.get("at") or ""), reverse=True)
    return {"member": row, "timeline": timeline[:50],
            "seen_by": seen_by(viewer, member)}


def _own_timeline(viewer, member, family_id, now):
    out = []
    start, end = _day_bounds(now)
    try:
        from .models import CareCallRing
        ids = member_ids(family_id)
        for r in CareCallRing.objects.filter(care_call__receiver=member,
                                             care_call__setter_id__in=ids,
                                             scheduled_at__gte=start, scheduled_at__lt=end):
            out.append({"at": (r.answered_at or r.scheduled_at).isoformat(),
                        "kind": "carecall_" + ("done" if r.status == "done" else
                                               "missed" if r.status == "missed" else "pending"),
                        "text": ""})
    except Exception:  # noqa: BLE001
        pass
    _, _, T = _models()
    for t in T.objects.filter(family_id=family_id, taken_by=member, taken_at__gte=start):
        out.append({"at": t.taken_at.isoformat(), "kind": "task_taken", "text": t.title})
    for t in T.objects.filter(family_id=family_id, done_by=member, done_at__gte=start):
        out.append({"at": t.done_at.isoformat(), "kind": "task_done", "text": t.title})
    return out


def seen_by(viewer, member):
    """Everyone who can see `member` on a Family screen: active co-members
    across all the member's families (fcbrain's visibility narrows place)."""
    _, M, _ = _models()
    fams = {m.family_id: m.family.name for m in _active(member).select_related("family")}
    out = {}
    for m in (M.objects.filter(family_id__in=list(fams), state="active")
              .exclude(user_id=member.id).select_related("user")):
        r = out.setdefault(m.user_id, {"user_id": m.user_id, "name": _name(viewer, m.user),
                                       "families": []})
        r["families"].append(fams[m.family_id])
    hidden = set()
    try:
        from . import family_brain   # fcbrain: place visibility (optional)
        fn = getattr(family_brain, "place_hidden_from", None)
        if fn:
            hidden = set(fn(member) or [])
    except ImportError:
        pass
    except Exception:  # noqa: BLE001
        pass
    for r in out.values():
        r["sees_place"] = r["user_id"] not in hidden
    return sorted(out.values(), key=lambda r: r["name"].lower())
