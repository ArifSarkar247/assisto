"""m1-messenger (scope 2) — backends for app calls that hit routes which did
not exist: family accounting, circle chat list, community message-request
inbox, notification-centre Done, journey timeline, disaster feed, medicine-db
report, group media, and the NESTED group URL shapes the app uses
(circle/groups/<g>/polls/<p>/vote, circle/groups/<g>/members/<m>).

All money in family accounting is INTEGER POISHA via logic/famacct_engine.
"""
from datetime import date as _date, timedelta

from django.db import models as dj_models
from django.utils import timezone

from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import pick, req_lang
from .logic import famacct_engine as FA
from .models import (CircleGroup, CircleGroupMember, CircleMember,
                     CircleMessage, ChatList, CommunityMessageRequest,
                     FamExpense, FamilyMember, FamPool, GroupPoll, Journey,
                     JourneyPoint, JourneyWatcher, NotifDismissal,
                     SupportTicket)


def _nf():
    return Response({"detail": "not found"}, status=status.HTTP_404_NOT_FOUND)


def _bad(detail, **extra):
    return Response({"detail": detail, **extra},
                    status=status.HTTP_400_BAD_REQUEST)


# ===========================================================================
# FAMILY ACCOUNTING  (/family/accounting/*)
# ===========================================================================
SELF = "self"


def _month(request, data=None):
    m = str((data or {}).get("month") or request.query_params.get("month")
            or timezone.localdate().strftime("%Y-%m"))[:7]
    try:
        y, mo = m.split("-")
        _date(int(y), int(mo), 1)
    except Exception:
        return None
    return m


def _members(user):
    """{key: name} — 'self' plus the owner's FamilyMember ids (as str)."""
    out = {SELF: (user.name or "").strip() or "self"}
    for fm in FamilyMember.objects.filter(user=user):
        out[str(fm.id)] = fm.name
    return out


def _mkey(v):
    """Normalise an incoming member ref ('self' | int | '12') to the stored
    string key, or None."""
    if v is None:
        return None
    s = str(v).strip()
    if s == SELF:
        return SELF
    return s if s.isdigit() else None


def _out_member(k):
    return SELF if k == SELF else int(k)


def _eng(row):
    """FamExpense -> the famacct_engine expense dict."""
    return {"payer": row.payer, "total": int(row.total_poisha),
            "shares": [{"member": s["member"], "share": int(s["share"])}
                       for s in (row.shares or [])],
            "category": row.category, "shared": row.shared}


def _exp_dict(row, names):
    return {
        "id": row.id, "payer": _out_member(row.payer),
        "payer_name": names.get(row.payer, ""),
        "total_poisha": int(row.total_poisha), "category": row.category,
        "category_label": FA.BILL_CATEGORIES.get(row.category, ("", ""))[1],
        "mode": row.mode, "note": row.note, "date": row.date.isoformat(),
        "shared": row.shared, "ai_captured": row.ai_captured,
        "shares": [{"member": _out_member(s["member"]),
                    "name": names.get(s["member"], ""),
                    "share_poisha": int(s["share"])}
                   for s in (row.shares or [])],
    }


def _pool_block(user, month, names):
    p = FamPool.objects.filter(owner=user, month=month).first()
    target = int(p.target_poisha) if p else 0
    contribs = [{"member": c["member"], "amount": int(c["amount"])}
                for c in ((p.contributions if p else None) or [])]
    st = FA.pool_status(target, contribs)
    st["breakdown"] = [{"member": _out_member(b["member"]),
                        "name": names.get(b["member"], ""),
                        "amount": b["amount"]} for b in st["breakdown"]]
    st["month"] = month
    return st


def outstanding(user):
    """Net balances + minimal settle-up over ALL shared expenses and recorded
    settlements (debts carry across months). Returns (net, transfers)."""
    rows = [_eng(r) for r in FamExpense.objects.filter(owner=user, shared=True)]
    return FA.net_balances(rows), FA.settle_up(rows)


class FamSummaryView(APIView):
    """GET /family/accounting/summary?month=YYYY-MM"""

    def get(self, request):
        month = _month(request)
        if month is None:
            return _bad("bad_month")
        names = _members(request.user)
        y, mo = month.split("-")
        rows = FamExpense.objects.filter(owner=request.user, shared=True,
                                         kind="expense", date__year=int(y),
                                         date__month=int(mo))
        summ = FA.monthly_summary([_eng(r) for r in rows],
                                  member_ids=list(names.keys()))
        net, transfers = outstanding(request.user)
        members = []
        for m in summ["members"]:
            members.append({"member": _out_member(m["member"]),
                            "name": names.get(m["member"], ""),
                            "paid_poisha": m["paid"],
                            "share_poisha": m["share_total"],
                            "net_poisha": m["net"],
                            "outstanding_poisha": int(net.get(m["member"], 0))})
        settlements = [{
            "from": _out_member(t["from"]), "to": _out_member(t["to"]),
            "amount_poisha": t["amount"],
            "message": {"bn": FA.settle_message(names.get(t["from"], ""),
                                                names.get(t["to"], ""),
                                                t["amount"], "bn"),
                        "en": FA.settle_message(names.get(t["from"], ""),
                                                names.get(t["to"], ""),
                                                t["amount"], "en")},
        } for t in transfers]
        return Response({"month": month, "total_poisha": summ["total"],
                         "expense_count": summ["expense_count"],
                         "by_category": summ["by_category"],
                         "members": members, "settlements": settlements,
                         "pool": _pool_block(request.user, month, names)})


class FamExpensesView(APIView):
    """GET  /family/accounting/expenses?month= -> {expenses:[...]}
       POST /family/accounting/expenses {payer, total_poisha, category, note,
            date, mode: equal|shares|exact, members:[..] | parts:[{member,
            weight|amount_poisha}], shared?} -> the created expense."""

    def get(self, request):
        month = _month(request)
        if month is None:
            return _bad("bad_month")
        names = _members(request.user)
        y, mo = month.split("-")
        rows = FamExpense.objects.filter(owner=request.user, kind="expense",
                                         date__year=int(y), date__month=int(mo))
        return Response({"month": month,
                         "expenses": [_exp_dict(r, names) for r in rows]})

    def post(self, request):
        d = request.data or {}
        names = _members(request.user)
        payer = _mkey(d.get("payer", SELF))
        if payer not in names:
            return _bad("unknown_payer")
        mode = str(d.get("mode", "equal"))
        if mode not in ("equal", "shares", "exact"):
            return _bad("bad_mode")
        try:
            total = int(d.get("total_poisha", 0))
        except (TypeError, ValueError):
            return _bad("bad_total")
        if mode == "exact":
            parts = []
            for p in d.get("parts") or []:
                k = _mkey(p.get("member"))
                if k not in names:
                    return _bad("unknown_member")
                try:
                    amt = int(p.get("amount_poisha", 0))
                except (TypeError, ValueError):
                    return _bad("bad_amount")
                if amt < 0:
                    return _bad("bad_amount")
                parts.append({"member": k, "share": amt})
            if not parts:
                return _bad("no_members")
            shares = parts
            total = sum(p["share"] for p in parts)
        elif mode == "shares":
            parts = []
            for p in d.get("parts") or []:
                k = _mkey(p.get("member"))
                if k not in names:
                    return _bad("unknown_member")
                parts.append({"member": k, "weight": int(p.get("weight", 1) or 0)})
            if not parts:
                return _bad("no_members")
            shares = FA.split_shares(total, parts)
        else:
            ids = []
            for m in d.get("members") or []:
                k = _mkey(m)
                if k not in names:
                    return _bad("unknown_member")
                if k not in ids:
                    ids.append(k)
            if not ids:
                return _bad("no_members")
            shares = FA.split_equal(total, ids)
        if total <= 0:
            return _bad("bad_total")
        try:
            day = _date.fromisoformat(str(d.get("date"))[:10]) if d.get("date") \
                else timezone.localdate()
        except ValueError:
            return _bad("bad_date")
        cat = str(d.get("category") or "other")
        if cat not in FA.BILL_CATEGORIES:
            cat = "other"
        row = FamExpense.objects.create(
            owner=request.user, payer=payer, total_poisha=total, category=cat,
            mode=mode, note=str(d.get("note") or "")[:200], date=day,
            shares=[{"member": s["member"], "share": int(s["share"])}
                    for s in shares],
            shared=bool(d.get("shared", True)),
            ai_captured=bool(d.get("ai_captured", False)))
        return Response(_exp_dict(row, names), status=status.HTTP_201_CREATED)


class FamExpenseDeleteView(APIView):
    """POST /family/accounting/expenses/delete {id} -> {ok}. Owner only."""

    def post(self, request):
        try:
            pk = int((request.data or {}).get("id"))
        except (TypeError, ValueError):
            return _bad("bad_id")
        n, _ = FamExpense.objects.filter(owner=request.user, pk=pk,
                                         kind="expense").delete()
        if not n:
            return _nf()
        return Response({"ok": True})


class FamPoolView(APIView):
    """GET  /family/accounting/pool?month= -> pool block
       POST /family/accounting/pool {target_poisha, month?} -> pool block"""

    def get(self, request):
        month = _month(request)
        if month is None:
            return _bad("bad_month")
        return Response(_pool_block(request.user, month, _members(request.user)))

    def post(self, request):
        d = request.data or {}
        month = _month(request, d)
        if month is None:
            return _bad("bad_month")
        try:
            target = int(d.get("target_poisha"))
        except (TypeError, ValueError):
            return _bad("bad_target")
        if target < 0:
            return _bad("bad_target")
        p, _ = FamPool.objects.get_or_create(owner=request.user, month=month)
        p.target_poisha = target
        p.save(update_fields=["target_poisha"])
        return Response(_pool_block(request.user, month, _members(request.user)))


class FamPoolContributeView(APIView):
    """POST /family/accounting/pool/contribute {member, amount_poisha, month?}"""

    def post(self, request):
        d = request.data or {}
        month = _month(request, d)
        if month is None:
            return _bad("bad_month")
        names = _members(request.user)
        k = _mkey(d.get("member"))
        if k not in names:
            return _bad("unknown_member")
        try:
            amt = int(d.get("amount_poisha"))
        except (TypeError, ValueError):
            return _bad("bad_amount")
        if amt <= 0:
            return _bad("bad_amount")
        p, _ = FamPool.objects.get_or_create(owner=request.user, month=month)
        p.contributions = list(p.contributions or []) + [
            {"member": k, "amount": amt, "at": timezone.now().isoformat()}]
        p.save(update_fields=["contributions"])
        return Response(_pool_block(request.user, month, names))


class FamSettleView(APIView):
    """POST /family/accounting/settle {from, to, amount_poisha} — record that
    `from` paid `to`. Validated against the CURRENT outstanding: `from` must
    owe (net < 0), `to` must be owed (net > 0) and the amount may not exceed
    either side. Stored as a settlement row (payer=from, share to=amount), so
    the next settle-up nets it out exactly."""

    def post(self, request):
        d = request.data or {}
        names = _members(request.user)
        frm, to = _mkey(d.get("from")), _mkey(d.get("to"))
        if frm not in names or to not in names or frm == to:
            return _bad("bad_members")
        try:
            amt = int(d.get("amount_poisha"))
        except (TypeError, ValueError):
            return _bad("bad_amount")
        if amt <= 0:
            return _bad("bad_amount")
        net, _ = outstanding(request.user)
        owes = -int(net.get(frm, 0))
        owed = int(net.get(to, 0))
        if owes <= 0 or owed <= 0:
            return _bad("nothing_outstanding")
        if amt > min(owes, owed):
            return _bad("exceeds_outstanding", max_poisha=min(owes, owed))
        FamExpense.objects.create(
            owner=request.user, kind="settlement", payer=frm,
            total_poisha=amt, category="other", mode="exact",
            note="settle-up", date=timezone.localdate(),
            shares=[{"member": to, "share": amt}], shared=True)
        net2, transfers = outstanding(request.user)
        return Response({"ok": True, "remaining": [
            {"from": _out_member(t["from"]), "to": _out_member(t["to"]),
             "amount_poisha": t["amount"]} for t in transfers]})


# ===========================================================================
# CIRCLE chat list  (GET /circle/chats)
# ===========================================================================
class CircleChatsView(APIView):
    """GET /circle/chats -> {results:[{id, member, last (E2E envelope, the
    device decrypts), last_text:'' , unread, at, pinned, archived, muted,
    favourite, lists:[ids]}]} — one row per ACCEPTED member, newest first."""

    def get(self, request):
        from .views_module5 import _member_dict, _organise_map
        from .views_m1_messenger import (member_favourite, visible_conversation)
        from . import b2_badges as B2
        uid = request.user.id
        org = _organise_map(request.user)
        lists = list(ChatList.objects.filter(user=request.user))
        out = []
        # mr1: my OUTGOING message requests show as normal chats too (the
        # chat says "Waiting for <name> to accept"), once I sent something.
        edges = list(CircleMember.objects.filter(user=request.user,
                                                 state="accepted"))
        edges += list(CircleMember.objects.filter(
            user=request.user, state="pending", direction="outgoing",
            peer_user__isnull=False, messages__isnull=False).distinct())
        for m in edges:
            rows = visible_conversation(request.user, m)
            if m.state != "accepted" and not rows:
                continue
            last = rows[-1] if rows else None
            # b2-badges: the SAME count the home badge sums (blocked = 0,
            # deleted-for-everyone never counted).
            unread = B2.member_unread(request.user, m, rows)
            o = org.get(str(m.id), {})
            out.append({
                "id": str(m.id), "member": _member_dict(m),
                "last_text": "",
                "last": ({"id": last.id, "ciphertext": last.ciphertext,
                          "nonce": last.nonce, "scheme": last.scheme,
                          "content_type": last.content_type,
                          "mine": last.sender_id == uid,
                          "deleted": last.deleted or ""} if last else None),
                "unread": unread,
                "at": last.created_at.isoformat() if last else None,
                "status": "",
                "pinned": bool(o.get("pinned")),
                "archived": bool(o.get("archived")),
                "muted": bool(o.get("muted")),
                "favourite": member_favourite(request.user, m.id),
                "request": "outgoing" if m.state != "accepted" else None,
                "lists": [cl.id for cl in lists
                          if m.id in (cl.member_refs or [])
                          or str(m.id) in [str(x) for x in (cl.member_refs or [])]],
            })
        out.sort(key=lambda r: r["at"] or "", reverse=True)
        # c3-msg: my last message's tick, sender names, decrypt key hint,
        # GROUP chats, and the manual "marked unread" flag.
        from . import views_c3_msg as C3
        try:   # x2-ticks: the chat list fetch is a delivered ack too
            C3.sync_delivered(request.user)
        except Exception:
            pass
        out = C3.augment_chat_rows(request.user, out)
        out = B2.fix_chat_rows(request.user, out)
        # a1-circle: one row per peer user, same-name hint, "hasn't opened
        # Assisto yet", the peer's earlier keys for the preview decrypt.
        from . import a1_circle as A1
        out = A1.polish_chat_rows(out, edges)
        return Response({"results": out})


# ===========================================================================
# COMMUNITY message-request inbox  (GET /community/message-requests)
# ===========================================================================
class CommunityMessageRequestsListView(APIView):
    """GET /community/message-requests -> {results:[...]} pending only, for
    the recipient. Ciphertext only; `envelope` is what the device decrypts."""

    def get(self, request):
        from .views_m1_messenger import _req_dict
        rows = (CommunityMessageRequest.objects
                .filter(recipient=request.user, state="pending")
                .select_related("sender", "community"))
        out = []
        for r in rows:
            d = _req_dict(r)
            d["envelope"] = {"ciphertext": r.first_ciphertext,
                             "nonce": r.first_nonce,
                             "sender_key_id": r.sender_key_id, "scheme": ""}
            d["sender"] = {"id": r.sender_id, "name": d["name"],
                           "photo": d["photo"]}
            from . import e2_keys  # e2-keys: the per-user key directory
            d["sender_public_key"] = e2_keys.key_of(r.sender_id)[0] or ""
            out.append(d)
        return Response({"results": out})


# ===========================================================================
# NOTIFICATION CENTRE — Done  (POST /notif/reminders/<id>/done)
# ===========================================================================
class NotifReminderDoneView(APIView):
    """Dispatch Done to the owning record:
      reminder:<pk>            -> Reminder.done (recurring: due_at advances)
      todo:<pk>                -> Todo.done
      medicine:<pk>:<HH:MM>    -> today's MedicineLog taken
      subscription:<pk>        -> next_due advances one cycle (mark paid)
      meeting|appointment|birthday:... -> this occurrence is dismissed."""

    def post(self, request, item_id):
        from .models import Medicine, MedicineLog, Reminder, Subscription, Todo
        u = request.user
        kind, _, rest = str(item_id).partition(":")
        if kind == "reminder" and rest.isdigit():
            r = Reminder.objects.filter(user=u, pk=int(rest)).first()
            if r is None:
                return _nf()
            if r.recurrence and r.recurrence != "none" and r.due_at:
                step = {"daily": timedelta(days=1), "weekly": timedelta(days=7)}
                if r.recurrence in step:
                    r.due_at = r.due_at + step[r.recurrence]
                elif r.recurrence == "monthly":
                    from .logic.subscriptions import advance_due
                    nd = advance_due(r.due_at.date(), "monthly")
                    r.due_at = r.due_at.replace(year=nd.year, month=nd.month,
                                                day=nd.day)
                elif r.recurrence == "yearly":
                    try:
                        r.due_at = r.due_at.replace(year=r.due_at.year + 1)
                    except ValueError:
                        r.due_at = r.due_at + timedelta(days=365)
                r.save(update_fields=["due_at", "updated_at"])
                return Response({"ok": True, "id": item_id, "next": r.due_at.isoformat()})
            r.done = True
            r.save(update_fields=["done", "updated_at"])
            return Response({"ok": True, "id": item_id})
        if kind == "todo" and rest.isdigit():
            n = Todo.objects.filter(user=u, pk=int(rest)).update(done=True)
            return Response({"ok": True, "id": item_id}) if n else _nf()
        if kind == "medicine":
            pk, _, slot = rest.partition(":")
            med = Medicine.objects.filter(user=u, pk=int(pk)).first() \
                if pk.isdigit() else None
            if med is None or not slot:
                return _nf()
            MedicineLog.objects.update_or_create(
                medicine=med, date=timezone.localdate(), slot=slot[:12],
                defaults={"taken": True, "skipped": False, "at": timezone.now()})
            return Response({"ok": True, "id": item_id})
        if kind == "subscription" and rest.isdigit():
            s = Subscription.objects.filter(user=u, pk=int(rest)).first()
            if s is None or s.next_due is None:
                return _nf()
            from .logic.subscriptions import advance_due
            days = (s.details or {}).get("custom_days")
            s.next_due = advance_due(s.next_due, s.cycle, interval_days=days)
            s.save(update_fields=["next_due", "updated_at"])
            return Response({"ok": True, "id": item_id,
                             "next_due": s.next_due.isoformat()})
        if kind in ("meeting", "appointment", "birthday") and rest:
            NotifDismissal.objects.get_or_create(user=u, item_id=str(item_id)[:80])
            return Response({"ok": True, "id": item_id, "dismissed": True})
        return _nf()


def dismissed_ids(user):
    return set(NotifDismissal.objects.filter(user=user)
               .values_list("item_id", flat=True))


# ===========================================================================
# SAFE JOURNEY timeline  (GET /journey/<pk>/timeline)
# ===========================================================================
def _journey_viewer_ok(j, user):
    if j.traveller_id == user.id:
        return True
    from . import push
    for w in JourneyWatcher.objects.filter(journey=j).select_related("member"):
        peer = push.member_peer_user(w.member)
        if peer is not None and peer.pk == user.id:
            return True
    return False


class JourneyTimelineView(APIView):
    """Traveller or a watcher only. Past the privacy expiry the points are
    deleted and an empty, honest timeline is returned."""

    def get(self, request, pk):
        j = Journey.objects.filter(pk=pk).first()
        if j is None or not _journey_viewer_ok(j, request.user):
            return _nf()
        now = timezone.now()
        expired = bool(j.expires_at and j.expires_at <= now)
        if expired:
            JourneyPoint.objects.filter(journey=j).delete()
        pts = [] if expired else [
            {"lat": p.lat, "lng": p.lng, "battery": p.battery,
             "at": p.at.isoformat()} for p in JourneyPoint.objects.filter(journey=j)]
        events = [{"kind": "started", "at": j.created_at.isoformat()}]
        if j.sos_active:
            events.append({"kind": "sos", "at": (j.last_activity_at or now).isoformat()})
        if j.status in ("arrived", "stopped", "expired"):
            events.append({"kind": j.status,
                           "at": (j.last_activity_at or now).isoformat()})
        return Response({"id": j.id, "status": j.status, "expired": expired,
                         "destination": j.destination, "eta":
                         j.eta.isoformat() if j.eta else None,
                         "last_location": None if expired else j.last_location,
                         "points": pts, "events": events,
                         "expires_at": j.expires_at.isoformat()
                         if j.expires_at else None})


def record_journey_point(j, lat, lng, battery=None):
    try:
        JourneyPoint.objects.create(journey=j, lat=float(lat), lng=float(lng),
                                    battery=int(battery) if battery not in
                                    (None, "") else None)
    except (TypeError, ValueError):
        pass


# ===========================================================================
# DISASTER feed + MEDICINE-DB report
# ===========================================================================
class DisasterFeedView(APIView):
    """GET /disaster/feed. There is NO official warning-feed integration in
    this codebase yet, so this honestly returns feed_state 'no_key' with an
    empty live list + clearly-flagged samples. It never fabricates a warning."""

    def get(self, request):
        from .logic import disaster as D
        lang = req_lang(request)
        return Response({"feed_state": D.feed_state(False, []),
                         "warnings": [],
                         "samples": D.sample_warnings(lang),
                         "message": pick(lang,
                                         "সরকারি সতর্কবার্তার ফিড এখনো যুক্ত হয়নি।",
                                         "The official warning feed isn't connected yet.")})


class MedicineDbReportView(APIView):
    """POST /medicine-db/report {brand, issue} -> stored as a support ticket
    (kind=bug) the owner sees in the support inbox."""

    def post(self, request):
        from .logic import medicine_db as MDB
        lang = req_lang(request)
        d = request.data or {}
        res = MDB.report_wrong_info(d.get("brand"), d.get("issue"), lang)
        if not res.get("ok"):
            return Response(res, status=status.HTTP_400_BAD_REQUEST)
        t = SupportTicket.objects.create(
            user=request.user, kind="bug",
            message=("[medicine-db] brand: %s | known: %s\n%s"
                     % (res["brand"][:120], res["known_record"],
                        res["issue"][:2000])))
        return Response({**res, "ticket_id": t.id},
                        status=status.HTTP_201_CREATED)


# ===========================================================================
# GROUP — nested canonical shapes + media
# ===========================================================================
def _g_me(request, pk):
    g = CircleGroup.objects.filter(pk=pk).first()
    if g is None:
        return None
    if not CircleGroupMember.objects.filter(group=g, member=request.user,
                                            status="active").exists():
        return None
    return g


class GroupPollActNestedView(APIView):
    """POST /circle/groups/<g>/polls/<p>/<action> (vote|close). Checks the
    poll belongs to <g>, then runs the existing poll gate."""

    def post(self, request, pk, pid, action):
        g = _g_me(request, pk)
        if g is None or not GroupPoll.objects.filter(pk=pid, group=g).exists():
            return _nf()
        from .views_m2 import CircleGroupPollActionView
        return CircleGroupPollActionView().post(request, pid, action)


class GroupMemberNestedView(APIView):
    """POST /circle/groups/<g>/members/<m> {event: remove|promote|demote}."""

    def post(self, request, pk, mid):
        event = str((request.data or {}).get("event", "")).strip()
        if not event:
            return _bad("event required")
        from .views_m2 import CircleGroupMemberActionView
        return CircleGroupMemberActionView().post(request, pk, mid, event)


class GroupMediaView(APIView):
    """GET /circle/groups/<g>/media -> media messages (opaque blob refs).
    Encrypted media blob storage is not switched on, so backend_ready is
    false and the screen shows its honest 'available when storage is on'."""

    def get(self, request, pk):
        g = _g_me(request, pk)
        if g is None:
            return _nf()
        from .views_m1_messenger import visible_group_messages
        kinds = {"image": "photo", "photo": "photo", "video": "video",
                 "audio": "audio", "voice": "audio", "file": "doc",
                 "doc": "doc", "document": "doc"}
        items = [{"id": x.id, "kind": kinds[x.content_type],
                  "blob_ref": x.blob_ref, "sender_id": x.sender_id,
                  "at": x.created_at.isoformat()}
                 for x in visible_group_messages(g, request.user)
                 if x.content_type in kinds]
        return Response({"items": items, "backend_ready": False})


def resolve_add_member(request, g, data):
    """POST circle/groups/<g>/members accepts {user_id} OR the app's
    {member_id} (the caller's own CircleMember edge id) -> peer User id."""
    if data.get("user_id"):
        return data.get("user_id")
    mid = data.get("member_id")
    if mid is None:
        return None
    edge = CircleMember.objects.filter(user=request.user, pk=mid).first()
    if edge is None:
        return None
    from . import push
    peer = push.member_peer_user(edge)
    return peer.pk if peer else None


# ===========================================================================
# CONNECTION REQUESTS list  (GET /messenger/request) + CHANNEL DISCOVER
# ===========================================================================
from .views_messenger import ConnectionRequestCreateView as _CRCreate  # noqa: E402


class ConnectionRequestsView(_CRCreate):
    """GET /messenger/request -> {results:[...]} my PENDING connection
    requests, incoming (I may accept/decline/block) and outgoing (I may
    cancel). POST is the existing create (unchanged)."""

    def get(self, request):
        from .models import ConnectionRequest
        lang = req_lang(request)
        rows = (ConnectionRequest.objects
                .filter(dj_models.Q(requester=request.user)
                        | dj_models.Q(target=request.user), state="pending")
                .select_related("requester", "target"))
        out = []
        for cr in rows:
            incoming = cr.target_id == request.user.id
            other = cr.requester if incoming else cr.target
            d = self._dict(cr, lang)
            d.update({
                "direction": "incoming" if incoming else "outgoing",
                "actions": (["accept", "decline", "block"] if incoming
                            else ["cancel"]),
                "peer": {"id": other.id,
                         "name": (other.name or "").strip() or other.username,
                         "photo": other.photo_url},
            })
            out.append(d)
        return Response({"results": out})


class ChannelDiscoverView(APIView):
    """GET /channels/discover?q=&category=&language= -> {results, suggested,
    categories}. ONLY public-listed channels of active owners. `suggested` is
    popularity (+ the viewer's app language) — never contacts or messages."""

    def get(self, request):
        from .logic import msg_channel as mch
        from .models import Channel, ChannelFollower
        from .views_messenger import _channel_dict
        qp = request.query_params
        q = str(qp.get("q", "")).strip()[:80]
        cat = str(qp.get("category", "")).strip()[:20]
        lang = str(qp.get("language", "")).strip()[:8]
        base = Channel.objects.filter(list_visibility="public",
                                      owner__is_active=True).exclude(
            owner__account_status__in=["suspended", "banned"])
        following = set(ChannelFollower.objects.filter(user=request.user)
                        .values_list("channel_id", flat=True))

        def ser(ch):
            d = _channel_dict(ch)
            d["id"] = ch.id
            d["following"] = ch.id in following
            return d
        results = []
        if q or cat or lang:
            qs = base
            if q:
                qs = qs.filter(dj_models.Q(name__icontains=q)
                               | dj_models.Q(handle__icontains=q.lstrip("@"))
                               | dj_models.Q(description__icontains=q))
            if cat:
                qs = qs.filter(category=cat)
            if lang:
                qs = qs.filter(language=lang)
            results = [ser(c) for c in qs.order_by("-follower_count", "-id")[:50]]
        my_lang = getattr(request.user, "language", "bn")
        sug = list(base.filter(language=my_lang).order_by("-follower_count")[:10])
        if len(sug) < 10:
            sug += list(base.exclude(pk__in=[c.pk for c in sug])
                        .order_by("-follower_count")[:10 - len(sug)])
        return Response({"results": results,
                         "suggested": [ser(c) for c in sug
                                       if c.id not in following],
                         "categories": [c if isinstance(c, str) else c[0]
                                        for c in mch.CATEGORIES]})
