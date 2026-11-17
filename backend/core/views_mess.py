"""
views_mess.py — MESS AND BACHELOR V2 (owner order 10 Nov 01:20, Part 2 A–L).

A SHARED mess on the server (V1 was a per-user JSON collection 'mess/*'):
  * create with a NAME (required), optional address + month start day;
  * members ONLY from the adder's My Circle (accepted edge with an Assisto
    account); roles admin (one or more) / monthly manager / member;
  * a My Circle GROUP with the mess name is created automatically when the
    first member is added (a normal CircleGroup: messages stay E2E — the server
    only keeps the roster); mess member add/remove = group add/remove;
  * meals ON by default; each member edits only own meals until the cut-off
    (default 22:00 the day before); manager/admin may correct any entry;
  * bazar (+ receipt photo, signed media), bazar turns (reminder the night
    before via `minute_jobs` -> mess_tick), deposits (+ optional advance),
    service charges (equal or seat share, NOT in the meal rate);
  * month close freezes a summary + carry-forward; closed months are
    immutable; every write is in the edit history (who / when / before/after);
  * every write takes an optional `client_id` so offline re-sends are
    idempotent (the app queues writes while offline).

Pure math: core/logic/mess_v2.py. All money INTEGER POISHA, meals MILLI-MEALS.
"""
from __future__ import annotations

import base64
import datetime as dt
import io

from django.core.files.base import ContentFile
from django.db import transaction
from django.http import HttpResponse
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .logic import mess_v2 as M
from .logic.mess_accounting import fmt_poisha
from .models import (CircleGroup, CircleGroupMember, CircleMember, Mess,
                     MessEditLog, MessEntry, MessMember, MessMonth)

FREE_MESS_LIMIT = 1          # Premium extra: several messes
PREMIUM_MESS_LIMIT = 10
ENTRY_KINDS = ("bazar", "deposit", "charge", "turn")
PHOTO_MAX = 3 * 1024 * 1024


# ------------------------------------------------------------------ helpers
def _today():
    return timezone.localdate()


def _now_local():
    return timezone.localtime()


def _premium(user):
    try:
        from .chat_decor import is_premium
        return bool(is_premium(user))
    except Exception:
        return False


def _err(lang, code, bn, en, st=400):
    return Response({"detail": pick(lang, bn, en), "code": code}, status=st)


def _date(v):
    try:
        return dt.date.fromisoformat(str(v)[:10])
    except (TypeError, ValueError):
        return None


def _poisha(v):
    try:
        p = int(v)
    except (TypeError, ValueError):
        return None
    return p if 0 < p <= 10_000_000_00 else None


def _me(mess, user):
    return MessMember.objects.filter(mess=mess, user=user, status="active").first()


def _is_admin(mm):
    return bool(mm and mm.role == "admin")


def _is_staff(mm):
    """admin OR this month's manager — may correct any entry."""
    return bool(mm and (mm.role == "admin" or mm.is_manager))


def _get_mess(request, pk):
    mess = Mess.objects.filter(pk=pk).first()
    if mess is None:
        return None, None
    mm = _me(mess, request.user)
    if mm is None:
        return None, None
    return mess, mm


def _not_found(lang):
    return _err(lang, "not_found", "মেসটি পাওয়া যায়নি।", "Mess not found.", 404)


def _log(mess, user, action, entry_id=None, before=None, after=None):
    MessEditLog.objects.create(mess=mess, actor=user, action=action[:24],
                               entry_id=entry_id, before=before or {}, after=after or {})


def _period(mess, day):
    return M.period_for(day, mess.month_start_day)


def _closed_key(mess, day):
    """The closed MessMonth that contains `day`, or None."""
    start, _ = _period(mess, day)
    m = MessMonth.objects.filter(mess=mess, key=M.month_key(start)).first()
    if m is not None:
        return m
    # a month closed under an older start-day setting still covers its dates
    return MessMonth.objects.filter(mess=mess, start__lte=day, end__gte=day).first()


def _locked(lang):
    return _err(lang, "month_closed", "এই মাস বন্ধ — বন্ধ মাসের হিসাব আর বদলানো যায় না।",
                "This month is closed — a closed month can't be changed.", 409)


def _member_rows(mess, include_left=True):
    qs = MessMember.objects.filter(mess=mess).select_related("user")
    if not include_left:
        qs = qs.filter(status="active")
    return list(qs)


def _member_dict(m):
    return {
        "id": m.id, "user_id": m.user_id,
        "name": (m.user.name if m.user_id and m.user and m.user.name else m.name) or "",
        "role": m.role, "is_manager": m.is_manager, "seat_share": m.seat_share,
        "status": m.status, "linked": bool(m.user_id),
        "joined_on": m.joined_on.isoformat(),
        "left_on": m.left_on.isoformat() if m.left_on else None,
    }


def _math_members(rows):
    return [{"id": m.id, "name": _member_dict(m)["name"], "seat_share": m.seat_share,
             "joined_on": m.joined_on, "left_on": m.left_on} for m in rows]


def _day_rows(mess, start, end):
    out = {}
    for e in MessEntry.objects.filter(mess=mess, kind="meal", deleted=False,
                                      date__gte=start, date__lte=end):
        out[(e.member_id, e.date)] = e.data
    return out


def _carry_in(mess, start):
    prev = MessMonth.objects.filter(mess=mess, end__lt=start).order_by("-end").first()
    if prev is None:
        return {}
    return {int(k): int(v) for k, v in (prev.carry or {}).items()}


def _entry_dict(e, names):
    d = {"id": e.id, "kind": e.kind, "member_id": e.member_id,
         "member_name": names.get(e.member_id, ""), "date": e.date.isoformat(),
         "amount": e.amount, "amount_display": fmt_poisha(e.amount),
         "data": e.data or {}, "client_id": e.client_id,
         "created_by": e.created_by_id, "updated_at": e.updated_at.isoformat()}
    if e.photo:
        try:
            d["photo_url"] = e.photo.url          # short-lived signed link
        except Exception:
            d["photo_url"] = None
    return d


def compute_month(mess, start, end, until=None):
    """Live settlement for [start, min(end, until)]."""
    rows = _member_rows(mess)
    members = [m for m in _math_members(rows)
               if m["joined_on"] <= end and (m["left_on"] is None or m["left_on"] > start)]
    last = min(end, until) if until else end
    meals = M.meals_by_member(members, _day_rows(mess, start, last), start, last,
                              mess.breakfast_milli) if last >= start else {m["id"]: 0 for m in members}
    ent = list(MessEntry.objects.filter(mess=mess, deleted=False, date__gte=start,
                                        date__lte=end).exclude(kind="meal"))
    bazar = [{"amount": e.amount} for e in ent if e.kind == "bazar"]
    charges = [{"amount": e.amount, "kind": (e.data or {}).get("kind", "other"),
                "split": (e.data or {}).get("split", "equal"),
                "members": (e.data or {}).get("members") or []}
               for e in ent if e.kind == "charge"]
    deposits = [{"member": e.member_id, "amount": e.amount} for e in ent if e.kind == "deposit"]
    s = M.settle(members, meals, bazar, charges, deposits, _carry_in(mess, start),
                 period=(start, end))
    s["counted_until"] = last.isoformat() if last >= start else None
    for r in s["members"]:
        for k in ("meal_cost", "service", "deposits", "carry_in"):
            r[k + "_display"] = fmt_poisha(r[k])
        r["due_display"] = fmt_poisha(abs(r["due"]))
        r["meals"] = M.fmt_meals(r["meals_milli"])
    s["bazar_total_display"] = fmt_poisha(s["bazar_total"])
    s["charges_total_display"] = fmt_poisha(s["charges_total"])
    s["deposits_total_display"] = fmt_poisha(s["deposits_total"])
    s["meals_total"] = M.fmt_meals(s["meals_total_milli"])
    return s


def today_card(mess):
    """Pinned group card: today's total meals, bazar today, who has not set
    tomorrow's meals (no explicit row yet — default is ON)."""
    today = _today()
    tomorrow = today + dt.timedelta(days=1)
    rows = [m for m in _member_rows(mess, include_left=False)]
    members = _math_members(rows)
    day_rows = _day_rows(mess, today, tomorrow)
    total = 0
    for m in members:
        if M.in_mess_on(m, today):
            total += M.day_milli(day_rows.get((m["id"], today), M.DEFAULT_DAY), mess.breakfast_milli)
    bazar = sum(MessEntry.objects.filter(mess=mess, kind="bazar", deleted=False,
                                         date=today).values_list("amount", flat=True))
    not_set = [m["name"] for m in members
               if M.in_mess_on(m, tomorrow) and (m["id"], tomorrow) not in day_rows]
    turn = MessEntry.objects.filter(mess=mess, kind="turn", deleted=False, date=today).first()
    names = {m["id"]: m["name"] for m in members}
    return {"mess_id": mess.id, "name": mess.name, "date": today.isoformat(),
            "meals_today": M.fmt_meals(total), "meals_today_milli": total,
            "bazar_today": bazar, "bazar_today_display": fmt_poisha(bazar),
            "not_set_tomorrow": not_set,
            "bazar_turn_today": names.get(turn.member_id, "") if turn else ""}


def _mess_dict(mess, mm):
    return {"id": mess.id, "name": mess.name, "address": mess.address,
            "month_start_day": mess.month_start_day, "breakfast_milli": mess.breakfast_milli,
            "cutoff_hour": mess.cutoff_hour, "status": mess.status,
            "group_id": mess.group_id, "my_member_id": mm.id if mm else None,
            "my_role": mm.role if mm else None,
            "i_am_manager": bool(mm and mm.is_manager),
            "can_manage": _is_staff(mm), "is_admin": _is_admin(mm)}


# ------------------------------------------------------------------ group sync
def _ensure_group(mess):
    """The mess's My Circle group (created on the first member add)."""
    g = mess.group
    if g is not None:
        return g
    g = CircleGroup.objects.create(creator=mess.creator, name=mess.name[:100],
                                   description="")
    mess.group = g
    mess.save(update_fields=["group"])
    for m in MessMember.objects.filter(mess=mess, status="active").exclude(user=None):
        _group_add(g, m.user, admin=(m.role == "admin"))
    return g


def _group_add(g, user, admin=False):
    row = CircleGroupMember.objects.filter(group=g, member=user).first()
    role = "admin" if admin else "member"
    if row is None:
        CircleGroupMember.objects.create(group=g, member=user, role=role, status="active")
    elif row.status != "active" or (admin and row.role != "admin"):
        row.status = "active"
        if admin:
            row.role = "admin"
        row.save(update_fields=["status", "role"])


def _group_remove(g, user):
    if g is None or user is None:
        return
    CircleGroupMember.objects.filter(group=g, member=user, status="active").update(status="removed")


def _push(user, title_bn, title_en, body_bn="", body_en="", mess=None):
    try:
        from . import push
        push.push_to_user(user, "reminder", title_bn, title_en, body_bn, body_en,
                          data={"route": "mess", "mess_id": str(mess.id) if mess else ""})
    except Exception:
        pass


# ------------------------------------------------------------------ views
class MessListView(APIView):
    """GET  mess/v2 -> my messes + whether I may create another.
       POST mess/v2 {name, address?, month_start_day?, breakfast_milli?,
            cutoff_hour?} -> the new mess (I am admin + manager)."""

    def get(self, request):
        rows = MessMember.objects.filter(user=request.user, status="active").select_related("mess")
        messes = [_mess_dict(r.mess, r) for r in rows]
        active = sum(1 for m in messes if m["status"] == "active")
        prem = _premium(request.user)
        from .models import PaCollectionItem
        legacy = PaCollectionItem.objects.filter(
            user=request.user, collection__startswith="mess/").exists()
        imported = Mess.objects.filter(creator=request.user, legacy__has_key="imported_at").exists()
        return Response({"messes": messes, "premium": prem,
                         "can_create": active < (PREMIUM_MESS_LIMIT if prem else FREE_MESS_LIMIT),
                         "free_limit": FREE_MESS_LIMIT,
                         "legacy_available": legacy and not imported})

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        name = " ".join(str(d.get("name") or "").split())[:80]
        if not name:
            return _err(lang, "name_required", "মেসের নাম দিন (যেমন রামপুরা মেস)।",
                        "Enter the mess name (for example Rampura Mess).")
        cid = str(d.get("client_id") or "")[:64]
        if cid:
            dup = Mess.objects.filter(creator=request.user, legacy__client_id=cid).first()
            if dup:
                return Response(_mess_dict(dup, _me(dup, request.user)), status=200)
        prem = _premium(request.user)
        active = MessMember.objects.filter(user=request.user, status="active",
                                           mess__status="active").count()
        if active >= (PREMIUM_MESS_LIMIT if prem else FREE_MESS_LIMIT):
            return _err(lang, "premium_needed",
                        "ফ্রিতে একটি মেস চালানো যায়। একসাথে কয়েকটি মেস চালাতে Premium নিন।",
                        "Free runs one mess. Get Premium to run several messes.", 402)
        bm = 1000 if str(d.get("breakfast_milli")) == "1000" else 500
        with transaction.atomic():
            mess = Mess.objects.create(
                creator=request.user, name=name,
                address=" ".join(str(d.get("address") or "").split())[:200],
                month_start_day=M.clamp_start_day(d.get("month_start_day") or 1),
                breakfast_milli=bm,
                cutoff_hour=M._int(d.get("cutoff_hour", M.DEFAULT_CUTOFF_HOUR), 0, 23),
                legacy={"client_id": cid} if cid else {})
            mm = MessMember.objects.create(mess=mess, user=request.user,
                                           name=request.user.name or "", role="admin",
                                           is_manager=True, joined_on=_today())
            _log(mess, request.user, "mess.create", after={"name": name})
        return Response(_mess_dict(mess, mm), status=201)


class MessDetailView(APIView):
    """GET mess/v2/<id>?month=YYYY-MM -> everything one screen needs."""

    def get(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        today = _today()
        key = request.query_params.get("month")
        if key:
            per = M.period_from_key(key, mess.month_start_day)
            if per is None:
                return _err(lang, "bad_month", "মাস ঠিক নেই।", "Invalid month.")
            start, end = per
        else:
            start, end = _period(mess, today)
            key = M.month_key(start)
        closed = MessMonth.objects.filter(mess=mess, key=key).first()
        months = list(MessMonth.objects.filter(mess=mess).values_list("key", flat=True))
        prem = _premium(request.user)
        # Free: the current month + the LAST closed month in full; Premium:
        # every old month in full.
        full = True
        if closed is not None and not prem and months and closed.key != months[0]:
            full = False
        if closed is not None:
            summary = closed.summary if full else {
                k: closed.summary.get(k) for k in ("bazar_total_display", "meals_total",
                                                   "meal_rate_display", "charges_total_display")}
        else:
            summary = compute_month(mess, start, end, until=min(end, today))
        rows = _member_rows(mess)
        names = {m.id: _member_dict(m)["name"] for m in rows}
        entries = []
        if full:
            entries = [_entry_dict(e, names) for e in MessEntry.objects.filter(
                mess=mess, deleted=False, date__gte=start, date__lte=end).exclude(kind="meal")
                .order_by("-date", "-id")]
        # my meals: the next 14 days + the month so far (own row or default)
        my_days = []
        first = max(start, today - dt.timedelta(days=31))
        last = max(today + dt.timedelta(days=14), end) if not closed else end
        mine = {e.date: e.data for e in MessEntry.objects.filter(
            mess=mess, kind="meal", member=mm, deleted=False, date__gte=first, date__lte=last)}
        spans = list(MessMonth.objects.filter(mess=mess).values_list("start", "end"))
        now = _now_local()
        staff = _is_staff(mm)
        for d in M.days(first, last):
            row = mine.get(d)
            locked = any(a <= d <= b for a, b in spans)
            my_days.append({"date": d.isoformat(), "set": row is not None,
                            **M.clean_day(row if row is not None else M.DEFAULT_DAY),
                            "locked": locked,
                            "can_edit": (not locked and (staff or M.can_member_edit_day(
                                d, now, mess.cutoff_hour)))})
        return Response({
            "mess": _mess_dict(mess, mm),
            "members": [_member_dict(m) for m in rows],
            "month": {"key": key, "start": start.isoformat(), "end": end.isoformat(),
                      "closed": closed is not None, "full": full,
                      "closed_at": closed.closed_at.isoformat() if closed else None},
            "months_closed": months,
            "summary": summary,
            "entries": entries,
            "my_days": my_days,
            "today": today_card(mess) if mess.status == "active" else None,
            "premium": prem,
        })


class MessEditView(APIView):
    """POST mess/v2/<id>/edit {name?, address?, month_start_day?,
    breakfast_milli?, cutoff_hour?} — admins only; renames the group too."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        if not _is_admin(mm):
            return _err(lang, "not_admin", "শুধু অ্যাডমিন মেসের তথ্য বদলাতে পারেন।",
                        "Only an admin can change the mess details.", 403)
        d = request.data or {}
        before = {"name": mess.name, "address": mess.address,
                  "month_start_day": mess.month_start_day,
                  "breakfast_milli": mess.breakfast_milli, "cutoff_hour": mess.cutoff_hour}
        if "name" in d:
            name = " ".join(str(d.get("name") or "").split())[:80]
            if not name:
                return _err(lang, "name_required", "মেসের নাম দিন।", "Enter the mess name.")
            mess.name = name
        if "address" in d:
            mess.address = " ".join(str(d.get("address") or "").split())[:200]
        if "month_start_day" in d:
            mess.month_start_day = M.clamp_start_day(d.get("month_start_day"))
        if "breakfast_milli" in d:
            mess.breakfast_milli = 1000 if str(d.get("breakfast_milli")) == "1000" else 500
        if "cutoff_hour" in d:
            mess.cutoff_hour = M._int(d.get("cutoff_hour"), 0, 23)
        mess.save()
        if mess.group_id and mess.group.name != mess.name[:100]:
            mess.group.name = mess.name[:100]
            mess.group.save(update_fields=["name"])
        after = {k: getattr(mess, k) for k in before}
        _log(mess, request.user, "mess.edit", before=before, after=after)
        return Response(_mess_dict(mess, mm))


def _circle_people(user):
    """My accepted, unblocked My Circle edges -> (edge, peer User|None)."""
    from . import push
    out = []
    for e in CircleMember.objects.filter(user=user, state="accepted", blocked=False):
        out.append((e, push.member_peer_user(e)))
    return out


class MessCirclePickView(APIView):
    """GET mess/v2/<id>/circle-pick -> my My Circle people (one tap to add).
    Only accepted edges with an Assisto account can be added; everyone else
    goes through "Invite to My Circle" in the app."""

    def get(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        in_mess = set(MessMember.objects.filter(mess=mess, status="active")
                      .exclude(user=None).values_list("user_id", flat=True))
        rows, seen = [], set()
        for e, peer in _circle_people(request.user):
            if peer is None or peer.pk == request.user.pk or peer.pk in seen:
                continue
            seen.add(peer.pk)
            rows.append({"circle_member_id": e.id, "user_id": peer.pk,
                         "name": e.name or peer.name or "", "relation": e.relation,
                         "custom_label": e.custom_label, "in_mess": peer.pk in in_mess})
        legacy = [_member_dict(m) for m in MessMember.objects.filter(
            mess=mess, status="active", user=None)]
        return Response({"results": rows, "unlinked": legacy})


class MessMembersView(APIView):
    """POST mess/v2/<id>/members {circle_member_id, link_member_id?} — admin
    adds a My Circle person (or links a V1-imported name to that person).
    Creates the mess group on the first add and adds them to it."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        if not _is_admin(mm):
            return _err(lang, "not_admin", "শুধু অ্যাডমিন সদস্য যোগ করতে পারেন।",
                        "Only an admin can add members.", 403)
        if mess.status != "active":
            return _err(lang, "mess_closed", "মেসটি বন্ধ।", "This mess is closed.", 409)
        d = request.data or {}
        edge = CircleMember.objects.filter(user=request.user, pk=d.get("circle_member_id"),
                                           state="accepted", blocked=False).first()
        from . import push
        peer = push.member_peer_user(edge) if edge else None
        if peer is None or peer.pk == request.user.pk:
            return _err(lang, "not_in_circle",
                        "শুধু My Circle-এর মানুষ যোগ করা যায়। আগে তাঁকে My Circle-এ আমন্ত্রণ দিন।",
                        "Only people in your My Circle can be added. Invite them to My Circle first.",
                        403)
        with transaction.atomic():
            row = MessMember.objects.filter(mess=mess, user=peer).first()
            link = d.get("link_member_id")
            if row is None and link:
                row = MessMember.objects.filter(mess=mess, pk=link, user=None).first()
                if row is not None:
                    row.user = peer
            if row is not None and row.status == "active" and row.user_id == peer.pk \
                    and not link:
                return Response({"ok": True, "already": True, "member": _member_dict(row)})
            if row is None:
                row = MessMember(mess=mess, user=peer, joined_on=_today())
            row.status = "active"
            row.left_on = None
            row.name = edge.name or peer.name or ""
            row.save()
            g = _ensure_group(mess)
            _group_add(g, peer, admin=(row.role == "admin"))
            _log(mess, request.user, "member.add", after={"member_id": row.id, "name": row.name})
        _push(peer, "মেসে যোগ হয়েছেন", "Added to a mess",
              "%s আপনাকে \"%s\" মেসে যোগ করেছেন।" % (request.user.name or "", mess.name),
              "%s added you to \"%s\"." % (request.user.name or "", mess.name), mess)
        return Response({"ok": True, "member": _member_dict(row), "group_id": g.id},
                        status=201)


class MessMemberActionView(APIView):
    """POST mess/v2/<id>/members/<mid> {action: remove|make_admin|
    remove_admin|make_manager|seat_share, value?} — admins only (a member may
    'remove' = leave themselves). Last admin can't be removed/demoted."""

    def post(self, request, pk, mid):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        target = MessMember.objects.filter(mess=mess, pk=mid, status="active").first()
        if target is None:
            return _not_found(lang)
        act = str((request.data or {}).get("action") or "")
        self_leave = act == "remove" and target.id == mm.id
        if not _is_admin(mm) and not self_leave:
            return _err(lang, "not_admin", "শুধু অ্যাডমিন এটা করতে পারেন।",
                        "Only an admin can do this.", 403)
        admins = MessMember.objects.filter(mess=mess, status="active", role="admin").count()
        before = _member_dict(target)
        if act in ("remove", "remove_admin") and target.role == "admin" and admins <= 1:
            return _err(lang, "last_admin", "মেসে অন্তত একজন অ্যাডমিন থাকতে হবে। আগে আরেকজনকে অ্যাডমিন করুন।",
                        "A mess needs at least one admin. Make someone else admin first.", 409)
        if act == "remove":
            target.status = "left"
            target.left_on = _today() + dt.timedelta(days=1)   # today's meals still count
            target.is_manager = False
            target.save()
            _group_remove(mess.group, target.user)
        elif act == "make_admin":
            target.role = "admin"
            target.save(update_fields=["role"])
            if mess.group_id and target.user_id:
                _group_add(mess.group, target.user, admin=True)
        elif act == "remove_admin":
            target.role = "member"
            target.save(update_fields=["role"])
        elif act == "make_manager":
            # the monthly meal manager rotates: exactly one at a time
            MessMember.objects.filter(mess=mess, is_manager=True).update(is_manager=False)
            target.is_manager = True
            target.save(update_fields=["is_manager"])
        elif act == "seat_share":
            target.seat_share = M._int((request.data or {}).get("value"), 0, 20)
            target.save(update_fields=["seat_share"])
        else:
            return _err(lang, "bad_action", "অজানা কাজ।", "Unknown action.")
        _log(mess, request.user, "member." + act, entry_id=target.id,
             before=before, after=_member_dict(target))
        return Response({"ok": True, "member": _member_dict(target)})


def _resolve_member(mess, mm, d, lang):
    """The member an entry is for. Plain members may only write for
    themselves; admin/manager may write for anyone (correction)."""
    mid = d.get("member_id")
    if mid in (None, "", mm.id):
        return mm, None
    if not _is_staff(mm):
        return None, _err(lang, "own_only", "আপনি শুধু নিজের হিসাব লিখতে পারেন।",
                          "You can only enter your own records.", 403)
    t = MessMember.objects.filter(mess=mess, pk=mid).first()
    if t is None:
        return None, _not_found(lang)
    return t, None


class MessMealsView(APIView):
    """POST mess/v2/<id>/meals {date, b, l, d, gb, gl, gd, member_id?,
    client_id?} — set one day. Own meals until the cut-off; manager/admin may
    correct any open-month day."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        d = request.data or {}
        day = _date(d.get("date"))
        if day is None:
            return _err(lang, "bad_date", "তারিখ ঠিক নেই।", "Invalid date.")
        who, err = _resolve_member(mess, mm, d, lang)
        if err:
            return err
        return _set_meal_days(request, mess, mm, who, [day], M.clean_day(d), lang)


class MessMealsOffView(APIView):
    """POST mess/v2/<id>/meals/off {from, to, member_id?} — turn meals OFF
    for several days at once (e.g. going home for a week). `on: true` turns
    them back on."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        d = request.data or {}
        a, b = _date(d.get("from")), _date(d.get("to"))
        if a is None or b is None or b < a:
            return _err(lang, "bad_range", "শুরু আর শেষের তারিখ ঠিক করে দিন।",
                        "Pick a valid start and end date.")
        if (b - a).days + 1 > M.MAX_RANGE_DAYS:
            return _err(lang, "range_too_long", "একসাথে সর্বোচ্চ ৬২ দিন বন্ধ করা যায়।",
                        "You can turn off at most 62 days at once.")
        who, err = _resolve_member(mess, mm, d, lang)
        if err:
            return err
        on = bool(d.get("on"))
        data = dict(M.DEFAULT_DAY) if on else {"b": 0, "l": 0, "d": 0, "gb": 0, "gl": 0, "gd": 0}
        return _set_meal_days(request, mess, mm, who, list(M.days(a, b)), data, lang)


def _saved_at(request):
    """The phone's saved-at time of an OFFLINE-queued write (aware ->
    Dhaka local), or None. Only sent by the outbox (with a client_id)."""
    d = request.data or {}
    if not d.get("client_id") or not d.get("saved_at"):
        return None
    from django.utils.dateparse import parse_datetime
    try:
        t = parse_datetime(str(d.get("saved_at"))[:40])
    except (TypeError, ValueError):
        return None
    if t is None or timezone.is_naive(t):
        return None
    return timezone.localtime(t)


def _set_meal_days(request, mess, mm, who, day_list, data, lang):
    staff = _is_staff(mm)
    now = _now_local()
    saved = _saved_at(request)
    late_ok = False
    for day in day_list:
        if _closed_key(mess, day) is not None:
            return _locked(lang)
        if not staff and not M.can_member_edit_day(day, now, mess.cutoff_hour) \
                and M.offline_saved_ok(day, saved, now, mess.cutoff_hour):
            late_ok = True      # saved offline before the cut-off (gap-money)
            continue
        if not staff and not M.can_member_edit_day(day, now, mess.cutoff_hour):
            return _err(lang, "cutoff",
                        "সময় শেষ — এই দিনের মিল আগের দিন %s:০০-এর মধ্যে বদলাতে হয়। ম্যানেজারকে বলুন।"
                        % M.to_bn_digits("%02d" % mess.cutoff_hour),
                        "Too late — meals for this day had to be changed by %02d:00 the day before. "
                        "Ask the manager." % mess.cutoff_hour, 409)
    changed = 0
    with transaction.atomic():
        for day in day_list:
            row = MessEntry.objects.filter(mess=mess, kind="meal", member=who, date=day,
                                           deleted=False).first()
            if row is None:
                row = MessEntry.objects.create(mess=mess, kind="meal", member=who, date=day,
                                               data=data, created_by=request.user,
                                               updated_by=request.user)
                before = {}
            else:
                if row.data == data:
                    continue
                before = dict(row.data or {})
                row.data = data
                row.updated_by = request.user
                row.save(update_fields=["data", "updated_by", "updated_at"])
            changed += 1
            if who.id != mm.id or before or late_ok:
                after = {"date": day.isoformat(), "member_id": who.id, **data}
                if late_ok:
                    # trust: everyone sees it arrived after the cut-off
                    after["offline_saved_at"] = saved.isoformat()
                _log(mess, request.user, "meal.set", entry_id=row.id,
                     before={"date": day.isoformat(), "member_id": who.id, **before},
                     after=after)
    return Response({"ok": True, "changed": changed, "days": len(day_list)})


def _save_photo(entry, b64):
    if not b64:
        return None
    try:
        raw = base64.b64decode(str(b64).split(",")[-1], validate=False)
    except Exception:
        return "bad"
    if not raw or len(raw) > PHOTO_MAX:
        return "bad"
    try:
        from PIL import Image
        im = Image.open(io.BytesIO(raw))
        im.verify()
        ext = (im.format or "jpeg").lower().replace("jpeg", "jpg")
        if ext not in ("jpg", "png", "webp"):
            return "bad"
    except Exception:
        return "bad"
    entry.photo.save("m%d_%d.%s" % (entry.mess_id, entry.id, ext), ContentFile(raw), save=True)
    return None


class MessEntriesView(APIView):
    """POST mess/v2/<id>/entries {kind: bazar|deposit|charge|turn, date,
    amount (poisha), member_id?, data?, photo_b64?, client_id?}.
      bazar   {items}                      — buyer = member (own, or staff)
      deposit {advance: bool}              — counted only when entered
      charge  {kind: khala|electricity|gas|water|wifi|rent|other, split:
               equal|seat, members:[ids], title}  — staff only, NOT in rate
      turn    {}                           — bazar turn for `member` on date"""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        d = request.data or {}
        kind = str(d.get("kind") or "")
        if kind not in ENTRY_KINDS:
            return _err(lang, "bad_kind", "অজানা এন্ট্রি।", "Unknown entry type.")
        cid = str(d.get("client_id") or "")[:64]
        if cid:
            dup = MessEntry.objects.filter(mess=mess, client_id=cid).first()
            if dup is not None:
                names = {m.id: _member_dict(m)["name"] for m in _member_rows(mess)}
                return Response({"ok": True, "entry": _entry_dict(dup, names), "dedup": True})
        day = _date(d.get("date")) or _today()
        if _closed_key(mess, day) is not None:
            return _locked(lang)
        if kind in ("charge", "turn") and not _is_staff(mm):
            return _err(lang, "staff_only", "এটা ম্যানেজার বা অ্যাডমিন লেখেন।",
                        "Only the manager or an admin can enter this.", 403)
        who, err = _resolve_member(mess, mm, d, lang)
        if err:
            return err
        amount = 0
        if kind != "turn":
            amount = _poisha(d.get("amount"))
            if amount is None:
                return _err(lang, "bad_amount", "টাকার পরিমাণ লিখুন (যেমন ৫০০)।",
                            "Enter the amount (for example 500).")
        raw = d.get("data") or {}
        data = {}
        if kind == "bazar":
            data["items"] = str(raw.get("items") or "")[:300]
        elif kind == "deposit":
            data["advance"] = bool(raw.get("advance"))
            data["note"] = str(raw.get("note") or "")[:120]
        elif kind == "charge":
            ck = str(raw.get("kind") or "other")
            data["kind"] = ck if ck in M.CHARGE_KINDS else "other"
            data["split"] = "seat" if raw.get("split") == "seat" else "equal"
            data["title"] = str(raw.get("title") or "")[:80]
            ids = set(MessMember.objects.filter(mess=mess).values_list("id", flat=True))
            data["members"] = [int(x) for x in (raw.get("members") or [])
                               if str(x).isdigit() and int(x) in ids]
            who = None
        with transaction.atomic():
            if kind == "turn":
                MessEntry.objects.filter(mess=mess, kind="turn", date=day, deleted=False).update(
                    deleted=True, updated_by=request.user)
            e = MessEntry.objects.create(mess=mess, kind=kind, member=who, date=day,
                                         amount=amount, data=data, client_id=cid,
                                         created_by=request.user, updated_by=request.user)
            if kind == "bazar" and d.get("photo_b64"):
                if _save_photo(e, d.get("photo_b64")) == "bad":
                    transaction.set_rollback(True)
                    return _err(lang, "bad_photo", "রসিদের ছবিটি পড়া যায়নি (৩ MB পর্যন্ত JPG/PNG)।",
                                "The receipt photo could not be read (JPG/PNG up to 3 MB).")
            _log(mess, request.user, kind + ".add", entry_id=e.id,
                 after={"date": day.isoformat(), "amount": amount,
                        "member_id": e.member_id, **data})
        names = {m.id: _member_dict(m)["name"] for m in _member_rows(mess)}
        return Response({"ok": True, "entry": _entry_dict(e, names)}, status=201)


class MessEntryActionView(APIView):
    """POST mess/v2/<id>/entries/<eid> {action: update|delete, amount?,
    date?, data?} — the entry's author or staff; open months only."""

    def post(self, request, pk, eid):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        e = MessEntry.objects.filter(mess=mess, pk=eid, deleted=False).exclude(kind="meal").first()
        if e is None:
            return _not_found(lang)
        if not (_is_staff(mm) or e.created_by_id == request.user.id):
            return _err(lang, "not_allowed", "যিনি লিখেছেন বা ম্যানেজার এটা বদলাতে পারেন।",
                        "Only the person who entered it or the manager can change this.", 403)
        if _closed_key(mess, e.date) is not None:
            return _locked(lang)
        d = request.data or {}
        before = {"date": e.date.isoformat(), "amount": e.amount, **(e.data or {})}
        if d.get("action") == "delete":
            e.deleted = True
            e.updated_by = request.user
            e.save(update_fields=["deleted", "updated_by", "updated_at"])
            _log(mess, request.user, e.kind + ".delete", entry_id=e.id, before=before)
            return Response({"ok": True})
        if "amount" in d and e.kind != "turn":
            a = _poisha(d.get("amount"))
            if a is None:
                return _err(lang, "bad_amount", "টাকার পরিমাণ লিখুন।", "Enter the amount.")
            e.amount = a
        if "date" in d:
            nd = _date(d.get("date"))
            if nd is None:
                return _err(lang, "bad_date", "তারিখ ঠিক নেই।", "Invalid date.")
            if _closed_key(mess, nd) is not None:
                return _locked(lang)
            e.date = nd
        raw = d.get("data") or {}
        data = dict(e.data or {})
        for k in ("items", "note", "title"):
            if k in raw:
                data[k] = str(raw.get(k) or "")[:300]
        if e.kind == "charge":
            if "split" in raw:
                data["split"] = "seat" if raw.get("split") == "seat" else "equal"
            if "kind" in raw:
                data["kind"] = raw["kind"] if raw["kind"] in M.CHARGE_KINDS else "other"
        if e.kind == "deposit" and "advance" in raw:
            data["advance"] = bool(raw.get("advance"))
        e.data = data
        e.updated_by = request.user
        e.save()
        _log(mess, request.user, e.kind + ".edit", entry_id=e.id, before=before,
             after={"date": e.date.isoformat(), "amount": e.amount, **data})
        names = {m.id: _member_dict(m)["name"] for m in _member_rows(mess)}
        return Response({"ok": True, "entry": _entry_dict(e, names)})


class MessCloseMonthView(APIView):
    """POST mess/v2/<id>/close {month?: YYYY-MM} — admin/manager closes a
    month whose last day has come. Freezes the summary + carry-forward, then
    tells every member their number inside Assisto (free, no SMS)."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        if not _is_staff(mm):
            return _err(lang, "staff_only", "মাস বন্ধ করেন ম্যানেজার বা অ্যাডমিন।",
                        "Only the manager or an admin can close the month.", 403)
        today = _today()
        key = (request.data or {}).get("month")
        if key:
            per = M.period_from_key(key, mess.month_start_day)
            if per is None:
                return _err(lang, "bad_month", "মাস ঠিক নেই।", "Invalid month.")
        else:
            per = _period(mess, today)
        start, end = per
        key = M.month_key(start)
        if MessMonth.objects.filter(mess=mess, key=key).exists():
            return _locked(lang)
        if today < end:
            return _err(lang, "month_not_over",
                        "মাসের শেষ দিন থেকে মাস বন্ধ করা যায়।",
                        "You can close the month from its last day.", 409)
        s = compute_month(mess, start, end, until=end)
        with transaction.atomic():
            mon = MessMonth.objects.create(mess=mess, key=key, start=start, end=end,
                                           counted_until=end, summary=s,
                                           carry={str(k): v for k, v in M.carry_out(s).items()},
                                           closed_by=request.user)
            _log(mess, request.user, "month.close", after={"month": key})
        by_id = {m.id: m for m in _member_rows(mess)}
        for r in s["members"]:
            m = by_id.get(r["id"])
            if m is None or m.user is None:
                continue
            if r["state"] == "will_pay":
                bn = "%s মাসে আপনি দেবেন %s।" % (M.to_bn_digits(key), M.to_bn_digits(r["due_display"]))
                en = "For %s you will pay %s." % (key, r["due_display"])
            elif r["state"] == "gets_back":
                bn = "%s মাসে আপনি ফেরত পাবেন %s।" % (M.to_bn_digits(key), M.to_bn_digits(r["due_display"]))
                en = "For %s you get back %s." % (key, r["due_display"])
            else:
                bn, en = "%s মাসের হিসাব সমান।" % M.to_bn_digits(key), "%s is all clear." % key
            _push(m.user, "%s: মাসের হিসাব" % mess.name, "%s: month closed" % mess.name, bn, en, mess)
        return Response({"ok": True, "month": key, "summary": mon.summary,
                         "report": M.report_text(mess.name, key, s, lang)})


class MessRemindView(APIView):
    """POST mess/v2/<id>/remind {member_id?} — staff sends a free due
    reminder inside Assisto (push; no paid SMS) for the latest closed month."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        if not _is_staff(mm):
            return _err(lang, "staff_only", "রিমাইন্ডার পাঠান ম্যানেজার বা অ্যাডমিন।",
                        "Only the manager or an admin can send reminders.", 403)
        mon = MessMonth.objects.filter(mess=mess).order_by("-end").first()
        if mon is None:
            return _err(lang, "no_closed_month", "আগে মাস বন্ধ করুন, তারপর বকেয়া মনে করাতে পারবেন।",
                        "Close a month first, then you can send due reminders.", 409)
        target = (request.data or {}).get("member_id")
        by_id = {m.id: m for m in _member_rows(mess)}
        paid = paid_since_close(mess, mon)
        sent = 0
        for r in mon.summary.get("members", []):
            if r.get("state") != "will_pay" or (target and r["id"] != target):
                continue
            m = by_id.get(r["id"])
            if m is None or m.user is None:
                continue
            # gap-money: money given to the manager AFTER the close first
            # clears the old due — never remind someone who already paid.
            left = int(r.get("due") or 0) - paid.get(r["id"], 0)
            if left <= 0:
                continue
            shown = fmt_poisha(left)
            _push(m.user, "%s: বকেয়া মনে করিয়ে দেওয়া" % mess.name, "%s: due reminder" % mess.name,
                  "%s মাসের বকেয়া %s। ম্যানেজারকে দিন।" % (M.to_bn_digits(mon.key),
                                                          M.to_bn_digits(shown)),
                  "Your %s due is %s. Please pay the manager." % (mon.key, shown),
                  mess)
            sent += 1
        _log(mess, request.user, "due.remind", after={"month": mon.key, "sent": sent})
        return Response({"ok": True, "sent": sent})


def paid_since_close(mess, mon):
    """{member_id: poisha} deposited after the closed month `mon` ended."""
    out = {}
    for mid, amt in MessEntry.objects.filter(mess=mess, kind="deposit", deleted=False,
                                             date__gt=mon.end).values_list("member_id", "amount"):
        out[mid] = out.get(mid, 0) + int(amt or 0)
    return out


class MessHistoryView(APIView):
    """GET mess/v2/<id>/history -> edit history (who / when / before / after)."""

    def get(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        rows = MessEditLog.objects.filter(mess=mess).select_related("actor")[:300]
        return Response({"results": [{
            "id": r.id, "action": r.action, "entry_id": r.entry_id,
            "actor": (r.actor.name if r.actor else "") or "",
            "at": r.at.isoformat(), "before": r.before, "after": r.after} for r in rows]})


class MessReportView(APIView):
    """GET mess/v2/<id>/report?month=&pdf=1 — the month report (text, or PDF).
    Text is shared into the E2E group by the app; PDF streams here. Free: the
    open month + the last closed month; Premium: every old month."""

    def get(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        key = request.query_params.get("month")
        today = _today()
        mon = MessMonth.objects.filter(mess=mess, key=key).first() if key else None
        if mon is not None:
            latest = MessMonth.objects.filter(mess=mess).order_by("-end").first()
            if latest and latest.id != mon.id and not _premium(request.user):
                return _err(lang, "premium_needed",
                            "পুরনো মাসের পূর্ণ রিপোর্ট Premium-এ। শেষ বন্ধ মাসের রিপোর্ট ফ্রি।",
                            "Full reports of older months are in Premium. The last closed month is free.",
                            402)
            s, key = mon.summary, mon.key
        else:
            start, end = _period(mess, today)
            key = M.month_key(start)
            s = compute_month(mess, start, end, until=min(end, today))
        text = M.report_text(mess.name, key, s, lang)
        # NB: not `?format=` — DRF reserves it for renderer negotiation (404)
        if request.query_params.get("pdf") != "1":
            return Response({"month": key, "text": text})
        pdf = _pdf(mess, key, s, lang, closed=mon is not None)
        resp = HttpResponse(pdf, content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="mess-%s.pdf"' % key
        return resp


def _pdf(mess, key, s, lang, closed=False):
    """gap-money: the month report PDF through pdf_bn (HarfBuzz-shaped Bangla,
    lakh grouping, Bangla digits) as a real table — the old raw reportlab
    drawString broke every Bangla conjunct and vowel sign (মি, ক্ষ, ে)."""
    from decimal import Decimal

    from . import pdf_bn as P
    bn = lang != "en"
    lg = "bn" if bn else "en"

    def tk(p):
        return P.taka(Decimal(int(round(p or 0))) / Decimal(100), lg)

    def L(b, e):
        return b if bn else e

    d = P.Doc("%s %s" % (mess.name, key), lg)
    d.title(L("%s — %s মাসের হিসাব", "%s — %s month report") % (mess.name, P.digits(key, lg)))
    if mess.address:
        d.meta(mess.address)
    if closed:
        d.meta(L("মাস বন্ধ — এই হিসাব আর বদলাবে না।", "Month closed — these numbers are final."))
    elif s.get("counted_until"):
        d.meta(L("চলতি মাস — %s পর্যন্ত গোনা", "Open month — counted until %s")
               % P.digits(s["counted_until"], lg))
    d.heading(L("মোট হিসাব", "Totals"))
    d.row(L("মোট বাজার", "Total bazar"), tk(s.get("bazar_total")))
    d.row(L("মোট মিল", "Total meals"), P.digits(M.fmt_meals(s.get("meals_total_milli") or 0), lg))
    d.row(L("মিল রেট (বাজার ÷ মিল)", "Meal rate (bazar ÷ meals)"), tk(s.get("meal_rate") or 0))
    d.row(L("সার্ভিস চার্জ (মিল রেটের বাইরে)", "Service charges (not in the meal rate)"),
          tk(s.get("charges_total")))
    d.row(L("মোট জমা", "Total deposits"), tk(s.get("deposits_total")))
    rows = s.get("members") or []
    carry = any(int(r.get("carry_in") or 0) for r in rows)
    head = [L("সদস্য", "Member"), L("মিল", "Meals"), L("মিলের খরচ", "Meal cost"),
            L("সার্ভিস", "Service"), L("জমা", "Deposits")]
    widths = [0.22, 0.10, 0.15, 0.14, 0.14]
    if carry:
        head.append(L("আগের মাস", "Last month"))
        widths.append(0.12)
    head.append(L("ফল", "Result"))
    widths.append(1.0 - sum(widths))
    body = []
    for r in rows:
        due = int(r.get("due") or 0)
        if due > 0:
            res = L("দেবেন %s", "Will pay %s") % tk(due)
        elif due < 0:
            res = L("ফেরত পাবেন %s", "Gets back %s") % tk(-due)
        else:
            res = L("হিসাব সমান", "All clear")
        line = [r.get("name") or "", P.digits(M.fmt_meals(r.get("meals_milli") or 0), lg),
                tk(r.get("meal_cost")), tk(r.get("service")), tk(r.get("deposits"))]
        if carry:
            # carry_in + = credit from last month, − = still owed
            line.append(tk(r.get("carry_in")))
        line.append(res)
        body.append(line)
    d.heading(L("প্রত্যেকের হিসাব", "Each member"))
    d.table(head, body, widths, align=["left"] + ["right"] * (len(head) - 1))
    d.meta(L("হিসাব: মিল × মিল রেট + সার্ভিস চার্জ − জমা − আগের মাসের জমা = দেবেন / ফেরত পাবেন।",
             "Formula: meals × meal rate + service charges − deposits − last month's credit "
             "= will pay / gets back."))
    d.meta(L("সার্ভিস বিল (Wi-Fi, খালা, ভাড়া…) ভাগ হয় মেসে থাকা দিনের হিসাবে: মাসের মাঝে এলে বা "
             "চলে গেলে শুধু থাকা দিনগুলোর ভাগ; ভাড়া সিটের ভাগ × দিন।",
             "Service bills (Wi-Fi, khala, rent…) are shared by days in the mess: joining or leaving "
             "mid-month pays only for the days present; rent by seat share × days."))
    if s.get("reconciles"):
        d.meta(L("মিলের খরচ মিলিয়ে ঠিক মোট বাজার, সার্ভিসের ভাগ মিলিয়ে ঠিক মোট বিল — এক পয়সাও এদিক-ওদিক নেই।",
                 "Meal costs add up exactly to the bazar and service shares exactly to the bills — "
                 "not one poisha off."))
    return d.pdf()


class MessCloseMessView(APIView):
    """POST mess/v2/<id>/close-mess — admin closes the whole mess. The group
    chat keeps its history; the pinned card disappears."""

    def post(self, request, pk):
        lang = req_lang(request)
        mess, mm = _get_mess(request, pk)
        if mess is None:
            return _not_found(lang)
        if not _is_admin(mm):
            return _err(lang, "not_admin", "শুধু অ্যাডমিন মেস বন্ধ করতে পারেন।",
                        "Only an admin can close the mess.", 403)
        mess.status = "closed"
        mess.closed_at = timezone.now()
        mess.save(update_fields=["status", "closed_at"])
        _log(mess, request.user, "mess.close")
        return Response({"ok": True})


class MessByGroupView(APIView):
    """GET mess/v2/by-group/<gid> -> {card} for the pinned group card, or
    {card: null} when the group is not an ACTIVE mess the viewer is in."""

    def get(self, request, gid):
        mess = Mess.objects.filter(group_id=gid, status="active").first()
        if mess is None or _me(mess, request.user) is None:
            return Response({"card": None})
        return Response({"card": today_card(mess)})


class MessImportLegacyView(APIView):
    """POST mess/v2/import-legacy {name?} — copy the caller's V1 per-user
    'mess/*' rows into a NEW shared mess. V1 rows are NOT deleted (backup
    path: they stay in PaCollectionItem; a full JSON snapshot is also kept in
    Mess.legacy). V1 names become unlinked members the admin links to a My
    Circle person later; V1 monthly meal counts are kept in the snapshot and
    as per-member opening meal notes (not double-counted)."""

    def post(self, request):
        lang = req_lang(request)
        from .models import PaCollectionItem
        rows = list(PaCollectionItem.objects.filter(user=request.user,
                                                    collection__startswith="mess/"))
        if not rows:
            return _err(lang, "no_legacy", "পুরনো মেসের কোনো হিসাব নেই।",
                        "There is no old mess data.", 404)
        done = Mess.objects.filter(creator=request.user, legacy__has_key="imported_at").first()
        if done is not None:
            return Response({"ok": True, "mess_id": done.id, "already": True})
        snap = {}
        for r in rows:
            snap.setdefault(r.collection, []).append({"id": r.id, **(r.data or {})})
        name = " ".join(str((request.data or {}).get("name") or "").split())[:80] or \
            pick(lang, "আমার মেস", "My mess")
        today = _today()
        with transaction.atomic():
            mess = Mess.objects.create(creator=request.user, name=name,
                                       legacy={"imported_at": timezone.now().isoformat(),
                                               "snapshot": snap})
            me = MessMember.objects.create(mess=mess, user=request.user,
                                           name=request.user.name or "", role="admin",
                                           is_manager=True, joined_on=today)
            idmap = {}
            for m in snap.get("mess/members", []):
                nm = str(m.get("name") or "").strip()[:120]
                if not nm:
                    continue
                if nm.lower() == (request.user.name or "").strip().lower():
                    idmap[m["id"]] = me
                    continue
                idmap[m["id"]] = MessMember.objects.create(mess=mess, user=None, name=nm,
                                                           joined_on=today)
            from .logic.mess_accounting import to_poisha

            def _mem(v):
                try:
                    return idmap.get(int(v))
                except (TypeError, ValueError):
                    return None
            n = 0
            for b in snap.get("mess/bazar", []):
                p = to_poisha(b.get("amount"))
                if p > 0:
                    MessEntry.objects.create(mess=mess, kind="bazar", member=me, date=today,
                                             amount=p, created_by=request.user,
                                             data={"items": str(b.get("title") or "")[:300],
                                                   "legacy": True})
                    n += 1
            for d in snap.get("mess/deposits", []):
                p = to_poisha(d.get("amount"))
                if p > 0:
                    MessEntry.objects.create(mess=mess, kind="deposit", member=_mem(d.get("member")) or me,
                                             date=today, amount=p, created_by=request.user,
                                             data={"legacy": True})
                    n += 1
            for c in snap.get("mess/charges", []):
                p = to_poisha(c.get("amount"))
                if p > 0:
                    MessEntry.objects.create(mess=mess, kind="charge", member=None, date=today,
                                             amount=p, created_by=request.user,
                                             data={"kind": "other", "split": "equal",
                                                   "title": str(c.get("title") or "")[:80],
                                                   "members": [], "legacy": True})
                    n += 1
            _log(mess, request.user, "mess.import_v1", after={"entries": n,
                                                             "members": len(idmap)})
        return Response({"ok": True, "mess_id": mess.id, "entries": n,
                         "members": len(idmap)}, status=201)


def turn_reminders(now=None):
    """minute_jobs -> mess_tick: from 20:00 Dhaka, remind tomorrow's bazar
    turn holder once. Idle = one indexed query."""
    now = now or _now_local()
    if now.hour < 20:
        return 0
    tomorrow = now.date() + dt.timedelta(days=1)
    sent = 0
    for e in MessEntry.objects.filter(kind="turn", date=tomorrow, deleted=False,
                                      mess__status="active").select_related("member__user", "mess"):
        if (e.data or {}).get("reminded") or e.member is None or e.member.user is None:
            continue
        _push(e.member.user, "%s: কাল আপনার বাজারের পালা" % e.mess.name,
              "%s: your bazar turn tomorrow" % e.mess.name,
              "কাল বাজার করবেন। রসিদের ছবি তুলে রাখুন।",
              "You do the bazar tomorrow. Keep a photo of the receipt.", e.mess)
        e.data = {**(e.data or {}), "reminded": True}
        e.save(update_fields=["data"])
        sent += 1
    return sent
