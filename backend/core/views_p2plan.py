"""p2plan (owner PART 2, 3 Nov): Task manager sharing + Bangla quick-add,
Cost & time estimator templates, AI daily planner.

Builds ON existing modules — no new tables (no migration):
  * Task manager rows stay in the user's own `tasks_projects` / `tasks_items`
    PaCollectionItem collections. A project shared with My Circle people keeps
    `shared_with` on the OWNER's project row (the source of truth) and a
    server-only `tasks_sharedin` index row in each member's space (so a member
    can list "shared with me" without a JSON query). Every access re-checks
    the owner's row.
  * Estimator rates the OWNER typed live in WorldAdminValue ("est:…" keys,
    note = source, effective_date = date) — see core.logic.estimate_templates.
  * The daily planner reads PS schedule, Reminder, bills (Agent Core
    proactive._bill_rows) and tasks; core.logic.day_planner places them.
"""
from datetime import date

from django.db import transaction
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import is_play_flavour, pick, req_lang
from .logic import day_planner as DP
from .logic import estimate_templates as ET
from .logic import task_manager as TM

PROJECTS = "tasks_projects"
TASKS = "tasks_items"
SHAREDIN = "tasks_sharedin"
PLANNER_PREFS = "planner/prefs"
MAX_SHARED = 20
MAX_LIST_TASKS = 500
PLANNER_FLAG = "ai_daily_planner"


def _flag(user, key, request):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(key, user, is_play_flavour(request)))
    except Exception:
        return False


def _off(request):
    lang = req_lang(request)
    return Response({"error": "feature_off",
                     "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                                    "This feature is not available yet.")}, status=403)


def _err(request, code, bn, en, status=400):
    return Response({"error": code, "detail": pick(req_lang(request), bn, en)}, status=status)


def _name(u):
    return (getattr(u, "name", "") or "").strip() or (getattr(u, "phone", "") or "")


def _push(to, tbn, ten, bbn, ben):
    """Task notifications ride the existing 'reminder' push kind (every build's
    tray draws it); quiet hours respected like Family Care."""
    try:
        from . import famcare as FC
        if FC._quiet(to):
            return False
        from . import push
        return bool(push.safe_push(to, "reminder", tbn, ten, bbn, ben,
                                   data={"route": "tasks", "kind": "task_list"}))
    except Exception:
        return False


# ============================================================ quick add parse

class TaskParseView(APIView):
    """POST /tasks/parse {text} — Bangla/English quick-add (typed or spoken):
    the proven reminders parser for date/time/repeat + priority words. Nothing
    is saved; the app pre-fills the task form."""
    def post(self, request):
        from .logic import nlp_datetime
        lang = req_lang(request)
        text = " ".join(str((request.data or {}).get("text") or "").split())[:300]
        if not text:
            return _err(request, "empty", "কিছু বলুন বা লিখুন।", "Say or type something.")
        priority, rest = TM.voice_priority(text)
        r = nlp_datetime.parse(rest or text, lang=lang)
        rule = r.get("recurrence_rule") or {}
        freq = str(rule.get("freq") or "")
        repeat = freq if freq in (TM.REPEAT_DAILY, TM.REPEAT_WEEKLY, TM.REPEAT_MONTHLY) else ""
        due = r.get("datetime") or ""
        if repeat and not due:
            repeat = ""          # a repeat needs a first due date
        return Response({"title": (r.get("clean_title") or rest or text).strip(),
                         "due": due, "date_only": bool(r.get("date_only", False)),
                         "repeat": repeat, "priority": priority,
                         "confidence": r.get("confidence", 0.0)})


# ============================================================ shared lists

def _rows(user_id, collection, **flt):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(user_id=user_id, collection=collection, **flt)


def _project(pid):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(pk=pid, collection=PROJECTS).first()


def _shared_with(proj):
    out = []
    for s in (proj.data or {}).get("shared_with") or []:
        try:
            out.append({"uid": int(s.get("uid")), "name": str(s.get("name") or "")[:120],
                        "circle_id": s.get("circle_id")})
        except (TypeError, ValueError, AttributeError):
            continue
    return out


def _role(user, proj):
    if proj is None:
        return None
    if proj.user_id == user.id:
        return "owner"
    if any(s["uid"] == user.id for s in _shared_with(proj)):
        return "member"
    return None


def _people(proj):
    """Everyone on the list: owner first, then members (uid, name, role)."""
    out = [{"uid": proj.user_id, "name": _name(proj.user), "role": "owner"}]
    out += [{"uid": s["uid"], "name": s["name"], "role": "member"} for s in _shared_with(proj)]
    return out


def _task_out(it):
    d = TM.normalize_task(dict(it.data or {}, id=it.id))
    d["created_by"] = (it.data or {}).get("created_by")
    d["done_by"] = (it.data or {}).get("done_by")
    return d


def _list_tasks(proj):
    return [_task_out(it) for it in _rows(proj.user_id, TASKS).order_by("id")[:MAX_LIST_TASKS]
            if str((it.data or {}).get("project_id")) == str(proj.id)]


def _project_out(proj, user):
    d = dict(proj.data or {})
    now = timezone.localtime().replace(tzinfo=None)
    tasks = _list_tasks(proj)
    return {"id": proj.id, "name": str(d.get("name") or ""), "description": str(d.get("description") or ""),
            "color": str(d.get("color") or ""), "role": _role(user, proj),
            "owner": {"uid": proj.user_id, "name": _name(proj.user)},
            "people": _people(proj), "summary": TM.progress_summary(tasks, now)}


def _guard(request, pid):
    if not _flag(request.user, "task_manager", request):
        return None, None, _off(request)
    proj = _project(pid)
    role = _role(request.user, proj)
    if role is None:
        return None, None, _err(request, "not_found", "তালিকাটি পাওয়া যায়নি বা আপনার সাথে আর ভাগ করা নেই।",
                                "List not found or no longer shared with you.", 404)
    return proj, role, None


class SharedListsView(APIView):
    """GET /tasks/shared — lists other people shared with me (role member).
    Stale index rows (unshared / deleted) are cleaned up as we go."""
    def get(self, request):
        if not _flag(request.user, "task_manager", request):
            return _off(request)
        out = []
        for row in _rows(request.user.id, SHAREDIN).order_by("-id")[:100]:
            proj = _project((row.data or {}).get("project_id"))
            if _role(request.user, proj) != "member":
                row.delete()
                continue
            out.append(_project_out(proj, request.user))
        return Response({"lists": out})


class SharedListView(APIView):
    """GET /tasks/lists/<pid> — project + tasks + people (owner or member)."""
    def get(self, request, pid):
        proj, role, bad = _guard(request, pid)
        if bad:
            return bad
        return Response({**_project_out(proj, request.user), "tasks": _list_tasks(proj)})


_EDITABLE = ("title", "description", "status", "priority", "due", "progress",
             "parent_id", "repeat", "est_min", "assignee_uid")


def _clean_changes(body):
    return {k: body[k] for k in _EDITABLE if k in body}


def _assignee_ok(proj, uid):
    return uid is None or any(p["uid"] == uid for p in _people(proj))


def _after_change(request, proj, before, after, actor):
    """Notifications + recurring spawn after a shared-list task changed."""
    from .models import User
    title = after.get("title") or ""
    an = _name(actor)
    lst = str((proj.data or {}).get("name") or "")
    # assigned to someone new (not the actor)
    uid = after.get("assignee_uid")
    if uid and uid != before.get("assignee_uid") and uid != actor.id:
        to = User.objects.filter(pk=uid).first()
        if to:
            _push(to, "%s আপনাকে একটি কাজ দিয়েছেন" % an, "%s gave you a task" % an,
                  "%s — %s" % (title, lst), "%s — %s" % (title, lst))
    # marked done -> tell the list owner and whoever created it (not the actor)
    if after.get("status") == TM.STATUS_DONE and before.get("status") != TM.STATUS_DONE:
        notify = {proj.user_id, before.get("created_by")} - {actor.id, None}
        for to in User.objects.filter(pk__in=[u for u in notify if u]):
            _push(to, "%s কাজ শেষ করেছেন" % an, "%s finished a task" % an,
                  "%s — %s" % (title, lst), "%s — %s" % (title, lst))
        nxt = TM.spawn_next(after, timezone.localtime().replace(tzinfo=None))
        if nxt:
            return _create_task(proj, nxt, actor)
    return None


def _create_task(proj, data, actor):
    from .models import PaCollectionItem
    d = TM.normalize_task(data)
    d.pop("id", None)
    d["project_id"] = proj.id
    d["created_by"] = actor.id
    return PaCollectionItem.objects.create(user_id=proj.user_id, collection=TASKS, data=d)


class SharedListTasksView(APIView):
    """POST /tasks/lists/<pid>/tasks — add a task to a list I own or share."""
    def post(self, request, pid):
        proj, role, bad = _guard(request, pid)
        if bad:
            return bad
        body = dict(request.data or {})
        probs = TM.validate_task(body)
        if probs:
            return Response({"error": "invalid", "problems": probs}, status=400)
        if _rows(proj.user_id, TASKS).count() >= 5000:
            return _err(request, "limit", "তালিকায় আর কাজ যোগ করা যাবে না।", "This list is full.")
        clean = TM.normalize_task(body)
        if not _assignee_ok(proj, clean["assignee_uid"]):
            return _err(request, "not_on_list", "এই মানুষটি তালিকায় নেই।", "That person is not on this list.")
        it = _create_task(proj, clean, request.user)
        _after_change(request, proj, {"assignee_uid": None, "status": clean["status"],
                                      "created_by": request.user.id},
                      TM.normalize_task(it.data), request.user)
        return Response(_task_out(it), status=201)


class SharedListTaskView(APIView):
    """PATCH / DELETE /tasks/lists/<pid>/tasks/<tid>."""
    def _task(self, proj, tid):
        it = _rows(proj.user_id, TASKS, pk=tid).first()
        if it is None or str((it.data or {}).get("project_id")) != str(proj.id):
            return None
        return it

    def patch(self, request, pid, tid):
        proj, role, bad = _guard(request, pid)
        if bad:
            return bad
        with transaction.atomic():
            it = self._task(proj, tid)
            if it is None:
                return _err(request, "not_found", "কাজটি পাওয়া যায়নি।", "Task not found.", 404)
            before = dict(it.data or {})
            changes = _clean_changes(dict(request.data or {}))
            merged = dict(before, **changes)
            probs = TM.validate_task(merged)
            if probs:
                return Response({"error": "invalid", "problems": probs}, status=400)
            after = TM.normalize_task(merged)
            if not _assignee_ok(proj, after["assignee_uid"]):
                return _err(request, "not_on_list", "এই মানুষটি তালিকায় নেই।", "That person is not on this list.")
            data = dict(before, **{k: after[k] for k in after if k != "id"})
            if after["status"] == TM.STATUS_DONE and before.get("status") != TM.STATUS_DONE:
                data["done_by"] = request.user.id
            it.data = data
            it.save(update_fields=["data"])
        spawned = _after_change(request, proj, TM.normalize_task(before) | {"created_by": before.get("created_by")},
                                after, request.user)
        out = _task_out(it)
        if spawned is not None:
            out["spawned"] = _task_out(spawned)
        return Response(out)

    def delete(self, request, pid, tid):
        proj, role, bad = _guard(request, pid)
        if bad:
            return bad
        it = self._task(proj, tid)
        if it is None:
            return _err(request, "not_found", "কাজটি পাওয়া যায়নি।", "Task not found.", 404)
        if role != "owner" and (it.data or {}).get("created_by") != request.user.id:
            return _err(request, "not_allowed", "শুধু তালিকার মালিক বা যিনি যোগ করেছেন তিনিই মুছতে পারেন।",
                        "Only the list owner or whoever added it can delete it.", 403)
        # subtasks go with their parent
        for sub in _rows(proj.user_id, TASKS):
            if (sub.data or {}).get("parent_id") == it.id:
                sub.delete()
        it.delete()
        return Response(status=204)


class SharedListShareView(APIView):
    """POST /tasks/lists/<pid>/share {circle_ids:[…]} — owner shares the list
    with ACCEPTED My Circle people who are on Assisto."""
    def post(self, request, pid):
        from .famcare import _accepted_edges
        from .models import PaCollectionItem
        from .push import member_peer_user
        proj, role, bad = _guard(request, pid)
        if bad:
            return bad
        if role != "owner":
            return _err(request, "not_allowed", "শুধু তালিকার মালিক ভাগ করতে পারেন।",
                        "Only the list owner can share it.", 403)
        ids = (request.data or {}).get("circle_ids") or []
        if not isinstance(ids, list) or not ids:
            return _err(request, "empty", "My Circle থেকে কাউকে বেছে নিন।", "Pick someone from My Circle.")
        shared = _shared_with(proj)
        added, skipped = [], []
        edges = {e.id: e for e in _accepted_edges(request.user).filter(pk__in=[
            int(i) for i in ids if str(i).isdigit()][:MAX_SHARED])}
        for raw in ids[:MAX_SHARED]:
            e = edges.get(int(raw)) if str(raw).isdigit() else None
            peer = member_peer_user(e) if e else None
            if e is None:
                skipped.append({"circle_id": raw, "reason": "not_in_circle"})
                continue
            if peer is None or peer.id == request.user.id:
                skipped.append({"circle_id": raw, "reason": "not_on_assisto"})
                continue
            if any(s["uid"] == peer.id for s in shared):
                continue
            if len(shared) >= MAX_SHARED:
                skipped.append({"circle_id": raw, "reason": "limit"})
                continue
            from .famcare import _edge_name
            shared.append({"uid": peer.id, "name": _edge_name(e) or _name(peer), "circle_id": e.id})
            added.append(peer)
        with transaction.atomic():
            d = dict(proj.data or {})
            d["shared_with"] = shared
            proj.data = d
            proj.save(update_fields=["data"])
            for peer in added:
                if not _rows(peer.id, SHAREDIN).filter(data__project_id=proj.id).exists():
                    PaCollectionItem.objects.create(user=peer, collection=SHAREDIN,
                                                    data={"project_id": proj.id, "owner_id": proj.user_id})
        an, lst = _name(request.user), str(d.get("name") or "")
        for peer in added:
            _push(peer, "%s একটি কাজের তালিকা ভাগ করেছেন" % an, "%s shared a task list with you" % an, lst, lst)
        return Response({"ok": True, "people": _people(proj), "skipped": skipped})


class SharedListUnshareView(APIView):
    """POST /tasks/lists/<pid>/unshare {uid} — the owner removes someone; a
    member may remove only themself (leave)."""
    def post(self, request, pid):
        proj, role, bad = _guard(request, pid)
        if bad:
            return bad
        try:
            uid = int((request.data or {}).get("uid") or request.user.id)
        except (TypeError, ValueError):
            return _err(request, "invalid", "ভুল অনুরোধ।", "Bad request.")
        if role != "owner" and uid != request.user.id:
            return _err(request, "not_allowed", "শুধু তালিকার মালিক অন্যকে সরাতে পারেন।",
                        "Only the list owner can remove others.", 403)
        with transaction.atomic():
            d = dict(proj.data or {})
            d["shared_with"] = [s for s in _shared_with(proj) if s["uid"] != uid]
            proj.data = d
            proj.save(update_fields=["data"])
            _rows(uid, SHAREDIN).filter(data__project_id=proj.id).delete()
        return Response({"ok": True, "people": _people(proj)})


# ============================================================ estimator

def estimate_rates():
    """{key: {value, source, date}} — only the OWNER's "est:" rows."""
    from .models import WorldAdminValue
    out = {}
    for r in WorldAdminValue.objects.filter(key__startswith=ET.RATE_PREFIX + ":"):
        out[r.key] = {"value": float(r.value) if r.value is not None else None,
                      "source": r.note or "",
                      "date": r.effective_date.isoformat() if r.effective_date else ""}
    return out


def set_estimate_rate(owner, key, value, source, effective_date):
    """Owner Admin edit. value None clears. A rate needs a source AND a date."""
    from .models import WorldAdminValue
    if key not in {k[0] for k in ET.rate_keys()}:
        raise ValueError("unknown key")
    if value is not None and (not (source or "").strip() or effective_date is None):
        raise ValueError("source_and_date_required")
    row, _ = WorldAdminValue.objects.get_or_create(key=key)
    before = {"value": float(row.value) if row.value is not None else None, "source": row.note,
              "date": row.effective_date.isoformat() if row.effective_date else ""}
    row.value = value
    row.note = (source or "").strip()[:200] if value is not None else ""
    row.effective_date = effective_date if value is not None else None
    row.updated_by = owner
    row.save()
    after = {"value": float(value) if value is not None else None, "source": row.note,
             "date": row.effective_date.isoformat() if row.effective_date else ""}
    return before, after


class EstimateTemplatesView(APIView):
    """GET /estimate/templates — the 5 BD job templates + their questions."""
    def get(self, request):
        if not _flag(request.user, "cost_estimator", request):
            return _off(request)
        lang = req_lang(request)
        rates = estimate_rates()
        cat = ET.catalog(lang)
        for t in cat:
            t["owner_rates"] = sum(1 for k, *_ in ET.rate_keys()
                                   if k.startswith("est:%s:" % t["id"]) and k.endswith(":c")
                                   and ET._rate(rates, k))
        return Response({"templates": cat})


class EstimateComputeView(APIView):
    """POST /estimate/templates/<tid> {inputs:{…}} — the template's lines with
    quantities and (owner) rates or an honest "no rate"."""
    def post(self, request, tid):
        if not _flag(request.user, "cost_estimator", request):
            return _off(request)
        if tid not in ET.TEMPLATES:
            return _err(request, "not_found", "এই ছাঁচটি নেই।", "No such template.", 404)
        inputs = (request.data or {}).get("inputs") or {}
        if not isinstance(inputs, dict):
            inputs = {}
        return Response(ET.compute(tid, inputs, estimate_rates(), req_lang(request)))


# ============================================================ daily planner

def planner_prefs(user):
    row = _rows(user.id, PLANNER_PREFS).order_by("id").first()
    return DP.clean_prefs(row.data if row else {})


def save_planner_prefs(user, body):
    from .models import PaCollectionItem
    p = DP.clean_prefs(dict(planner_prefs(user), **{k: body[k] for k in ("day_start", "day_end", "prayer")
                                                     if k in (body or {})}))
    row = _rows(user.id, PLANNER_PREFS).order_by("id").first()
    if row:
        row.data = p
        row.save(update_fields=["data"])
    else:
        PaCollectionItem.objects.create(user=user, collection=PLANNER_PREFS, data=p)
    return p


def _my_tasks(user):
    """Own tasks + tasks assigned to me on lists shared with me."""
    out = []
    for it in _rows(user.id, TASKS).order_by("id")[:MAX_LIST_TASKS]:
        d = dict(it.data or {}, id=it.id)
        if TM._int_or_none(d.get("assignee_uid")) not in (None, user.id):
            continue        # on my shared list but given to someone else
        out.append(d)
    for row in _rows(user.id, SHAREDIN)[:50]:
        proj = _project((row.data or {}).get("project_id"))
        if _role(user, proj) != "member":
            continue
        for t in _list_tasks(proj):
            if t.get("assignee_uid") == user.id:
                out.append(t)
    return out


def _prayer_times(user, day):
    try:
        from . import world_service as W
        from .logic import ramadan
        from .logic import world_feeds as WF
        c = WF.city(W.prefs(user).city)
        return ramadan.prayer_times(day, c[3], c[4], tz_offset_hours=6.0, asr=ramadan.ASR_HANAFI)
    except Exception:
        return None


def _bills(user, today):
    from . import ps_service as PS
    sec = PS._bills_section(user, today)
    if not sec:
        return []
    out = []
    for line in sec.get("lines") or []:
        # only today / overdue (the PS section also shows "in 2 days")
        if "দিন পরে" in line.get("bn", ""):
            continue
        out.append(line)
    return out


def build_plan(user, now=None):
    from .ps_service import _reminders, _rows as ps_rows
    now = now or timezone.now()
    local = timezone.localtime(now)
    naive = local.replace(tzinfo=None)
    prefs = planner_prefs(user)
    meetings = []
    for s in ps_rows(user, "schedule"):
        st = str(s.get("status") or "")
        if st in ("cancelled", "canceled"):
            continue
        meetings.append(s)
    return DP.build(naive, prefs=prefs, meetings=meetings,
                    reminders=_reminders(user, local), tasks=_my_tasks(user),
                    bills=_bills(user, local.date()),
                    prayer_times=_prayer_times(user, local.date()) if prefs["prayer"] else None)


class PlannerTodayView(APIView):
    """GET /planner/today — today's time-blocked plan (template, 0 credits)."""
    def get(self, request):
        if not _flag(request.user, PLANNER_FLAG, request):
            return _off(request)
        plan = build_plan(request.user)
        plan["prefs"] = planner_prefs(request.user)
        plan["polish_credits"] = _polish_cost()
        return Response(plan)


class PlannerPrefsView(APIView):
    """GET/POST /planner/prefs {day_start, day_end, prayer}."""
    def get(self, request):
        if not _flag(request.user, PLANNER_FLAG, request):
            return _off(request)
        return Response(planner_prefs(request.user))

    def post(self, request):
        if not _flag(request.user, PLANNER_FLAG, request):
            return _off(request)
        return Response(save_planner_prefs(request.user, dict(request.data or {})))


def _polish_cost():
    try:
        from . import billing
        from .logic import pricing
        return pricing.credit_cost("day_plan_polish", billing.cfg())
    except Exception:
        return None


POLISH_TASK = (
    "You are Assisto's day-planning helper for a user in Bangladesh. DATA holds "
    "today's plan already built by rules: time blocks (meeting, reminder, prayer, "
    "task with priority), tasks that do not fit, and bills. Write 3 to 5 short, "
    "practical bullet lines of advice in {lang}: what to start with, where to rest, "
    "what to move to tomorrow, which bill to pay first. NEVER change, add or invent "
    "times, tasks, people, amounts or prices; refer only to items in DATA. No "
    "greetings, no markdown headings, one line per bullet starting with '- '.")


class PlannerPolishView(APIView):
    """POST /planner/today/polish — optional AI advice ON TOP of the template
    plan (the blocks never move). Charged `day_plan_polish` credits by the AI
    router; no key / no credits -> an honest message, the plan still stands."""
    def post(self, request):
        from . import ai
        lang = req_lang(request)
        if not _flag(request.user, PLANNER_FLAG, request):
            return _off(request)
        plan = build_plan(request.user)
        if plan["empty"]:
            return _err(request, "empty", "আজকের পরিকল্পনায় কিছু নেই — আগে কাজ বা মিটিং যোগ করুন।",
                        "Nothing planned today — add a task or meeting first.")
        task = POLISH_TASK.replace("{lang}", "Bangla (Bangla digits)" if lang == "bn" else "English")
        try:
            text, _cost = ai.generate(task, data=DP.ai_data(plan), tier="cheap", max_tokens=400,
                                      feature="day_planner", user=request.user,
                                      charge_action="day_plan_polish", pii=True,
                                      digits="bn" if lang == "bn" else None)
        except ai.AIUnavailable as e:
            msg = {"no_key": ("AI এখনো যুক্ত হয়নি — নিয়ম-মাফিক পরিকল্পনাটি ঠিকই আছে।",
                              "AI is not connected yet — your rule-based plan still works."),
                   "credits": ("যথেষ্ট ক্রেডিট নেই — নিয়ম-মাফিক পরিকল্পনাটি ঠিকই আছে।",
                               "Not enough credits — your rule-based plan still works."),
                   "user_limit": ("আজকের AI সীমা শেষ।", "Today's AI limit is reached."),
                   "budget": ("আজ AI সাময়িক বন্ধ — কাল আবার চেষ্টা করুন।", "AI is paused for today — try tomorrow.")}
            bn_m, en_m = msg.get(e.reason, ("এখন AI দিয়ে সাজানো গেল না — কোনো ক্রেডিট কাটা হয়নি।",
                                           "Couldn't polish with AI now — no credits were used."))
            return Response({"ok": False, "reason": e.reason, "detail": pick(lang, bn_m, en_m)},
                            status=402 if e.reason == "credits" else 503)
        lines = [ln.strip()[2:].strip() if ln.strip().startswith("- ") else ln.strip()
                 for ln in str(text or "").splitlines() if ln.strip()][:5]
        return Response({"ok": True, "advice": lines, "charged": _polish_cost(),
                         "balance": int(getattr(request.user, "ai_credits", 0) or 0),
                         "ai": True})
