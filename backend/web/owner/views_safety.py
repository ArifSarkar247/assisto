"""adminsafe (owner 3 Nov 04:22): Owner Admin -> Users stats + filters, user
detail safety section, account actions with a required reason, the Appeals
queue and Staff roles. Rules: core/admin_safety.py, counts: core/admin_stats.py.

PRIVACY WALL: nothing here (or in the templates) reads My Circle messages or
calls, vault documents, private photos, CCTV video/snapshots or live
location — web/tests_adminsafe.py greps this package and fails if it does.
Every user-detail VIEW and every action is written to the owner audit log."""
from django.contrib.auth import get_user_model
from django.core.paginator import Paginator
from django.db.models import Q
from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import charts
from . import security as S
from .base import done, owner_view, page, to_int
from .i18n import strings

User = get_user_model()


def _T(request):
    return strings(request.owner_lang)


def mask_phone(v):
    v = str(v or "")
    return (v[:3] + "•" * max(0, len(v) - 6) + v[-3:]) if len(v) > 6 else ("•" * len(v))


def mask_email(v):
    v = str(v or "")
    if "@" not in v:
        return mask_phone(v)
    name, dom = v.split("@", 1)
    return (name[:1] + "•••@" + dom) if name else "•••@" + dom


# ================================================================== stats
TILES = (   # (filter key, label key, definition key)
    ("all", "as_total", "as_def_total"),
    ("active_today", "as_active_today", "as_def_active_today"),
    ("active_7", "as_active_7", "as_def_active_7"),
    ("active_30", "as_active_30", "as_def_active_30"),
    ("inactive_30", "as_inactive_30", "as_def_inactive_30"),
    ("uninstalled", "as_uninstalled", "as_def_uninstalled"),
    ("new_today", "as_new_today", "as_def_new_today"),
    ("new_7", "as_new_7", "as_def_new_7"),
    ("plan_free", "as_plan_free", "as_def_plan_free"),
    ("plan_paid", "as_plan_paid", "as_def_plan_paid"),
    ("plan_trial", "as_plan_trial", "as_def_plan_trial"),
    ("suspended", "as_suspended", "as_def_suspended"),
    ("banned", "as_banned", "as_def_banned"),
    ("restricted", "as_restricted", "as_def_restricted"),
    ("appeal_open", "as_appeal_open", "as_def_appeal_open"),
)


def stats_ctx(request):
    """Tiles + 30-day trend chart; shared by Users and Overview."""
    from core import admin_stats
    T = _T(request)
    st = admin_stats.cached(force=request.GET.get("fresh") == "1")
    c = st["counts"]
    tiles = [{"key": k, "label": T[lk], "def": T[dk], "n": c.get(k)} for k, lk, dk in TILES]
    tr = st["trend"]
    chart = ""
    if any(a or s for _, a, s in tr):
        chart = charts.bars([d for d, _, _ in tr],
                            [(T["as_trend_active"], "s1", [a for _, a, _ in tr]),
                             (T["as_trend_signups"], "s2", [s for _, _, s in tr])],
                            height=180)
    return {"as_tiles": tiles, "as_chart": chart, "as_at": st["at"],
            "as_cache_sec": admin_stats.CACHE_SEC}


# ================================================================== users
def _search(qs, q):
    q = (q or "").strip()
    if not q:
        return qs
    cond = Q(name__icontains=q) | Q(username__icontains=q) | Q(email__icontains=q)
    from core.phone import canonical_phone, variants
    canon = canonical_phone(q)
    if canon:
        cond |= Q(phone__in=variants(canon))
    digits = "".join(ch for ch in q if ch.isdigit())
    if digits and len(digits) >= 4:
        cond |= Q(phone__contains=digits[-10:])
    qid = q.lstrip("#")
    if qid.isdigit():
        cond |= Q(pk=int(qid))
    return qs.filter(cond)


@require_http_methods(["GET"])
@owner_view(perm="users")
def users(request):
    from core import admin_stats, plans
    T = _T(request)
    q = request.GET.get("q", "")
    f = request.GET.get("f", "all")
    if f not in admin_stats.FILTERS:
        f = "all"
    qs = _search(admin_stats.queryset(f), q).order_by("-date_joined", "-id")
    pg = Paginator(qs, 50).get_page(to_int(request.GET.get("page"), 1) or 1)
    pii = S.has_perm(request.owner_role, "pii")
    rows = []
    for u in pg.object_list:
        try:
            eff = plans.effective_plan(u)
        except Exception:
            eff = u.plan
        rows.append({"u": u, "eff": eff,
                     "phone": (u.phone or u.username) if pii else mask_phone(u.phone or u.username)})
    labels = {k: T[lk] for k, lk, _ in TILES}
    ctx = {"q": q, "f": f, "f_label": labels.get(f, ""), "rows": rows, "pg": pg,
           "total": pg.paginator.count}
    ctx.update(stats_ctx(request))
    return page(request, "owner/users.html", ctx, nav="users")


# ============================================================ user detail
def detail_ctx(request, u):
    """Extra, privacy-safe context for the user page: device + app facts,
    reports against the user (counts + reporter-shared text only), support
    tickets, account actions, restrictions and appeals."""
    from core import admin_safety as AS
    from core.models import (AccountAction, AccountAppeal, Device, ModerationItem,
                             ModerationReport, SupportTicket, TrainChatReport)
    dev = Device.objects.filter(user=u).order_by("-last_seen", "-id").first()
    pii = S.has_perm(request.owner_role, "pii")
    reports = (ModerationReport.objects.filter(target_kind="person", target_id=str(u.pk))
               .order_by("-created_at"))
    items = ModerationItem.objects.filter(target_kind="person", target_id=str(u.pk))
    return {
        "as_pii": pii,
        "as_phone": (u.phone or "—") if pii else mask_phone(u.phone),
        "as_email": (u.email or "") if pii else mask_email(u.email),
        "as_device": dev,
        "as_devices_n": Device.objects.filter(user=u).count(),
        "as_push_dead": hasattr(u, "push_dead_mark") and not Device.objects.filter(
            user=u).exclude(push_token="").exists(),
        "as_reports_n": reports.count() + TrainChatReport.objects.filter(reported=u).count(),
        "as_reports": [{"at": r.created_at, "cats": ", ".join(r.categories or []),
                        "note": (r.note or "")[:200], "source": r.snapshot_source or "—"}
                       for r in reports[:10]],
        "as_items_open": items.exclude(queue_state="resolved").count(),
        "as_tickets": SupportTicket.objects.filter(user=u).only(
            "kind", "message", "resolved", "created_at")[:10],
        "as_actions": AccountAction.objects.filter(user=u).select_related("actor")[:20],
        "as_restrictions": list(AS.active_restrictions(u)),
        "as_appeals": AccountAppeal.objects.filter(user=u).select_related("action")[:10],
        "as_kinds": AS.RESTRICT_KINDS,
        "as_suspend_end": AS._suspend_end(u) if u.account_status == "suspended" else None,
        "as_can_support": S.has_perm(request.owner_role, "act_support"),
        "as_can_moderate": S.has_perm(request.owner_role, "act_moderate"),
        "as_can_money": request.owner_role == "owner",
    }


def audit_view(request, u):
    """Every open of a user page is audited (who looked at whom, when)."""
    S.audit(request, request.owner, "user.view", "user:%s" % u.pk,
            after={"role": getattr(request, "owner_role", "owner")})


@require_http_methods(["POST"])
@owner_view(perm="users")
def user_act(request, pk):
    from core import admin_safety as AS
    from core import admin_stats
    T = _T(request)
    u = User.objects.filter(pk=pk).first()
    if u is None:
        raise Http404
    kind = request.POST.get("kind", "")
    perm = S.ACTION_PERM.get(kind)
    if perm is None:
        raise Http404
    if not S.has_perm(request.owner_role, perm):
        S.audit(request, request.owner, "staff.denied", "user:%s" % u.pk,
                after={"role": request.owner_role, "action": kind}, ok=False)
        return page(request, "owner/forbidden.html", {"need": perm}, status=403)
    # staff never act on another staff account; only the owner may
    if request.owner_role != "owner" and S.panel_role(u) is not None:
        return page(request, "owner/forbidden.html", {"need": "owner"}, status=403)
    reason = request.POST.get("reason", "")
    before = {"status": u.account_status,
              "restrictions": sorted(r.kind for r in AS.active_restrictions(u))}
    try:
        act = AS.apply_action(u, kind, reason, request.owner,
                              days=request.POST.get("days"),
                              kinds=request.POST.getlist("kinds"))
    except AS.ActionError as e:
        S.audit(request, request.owner, "user.%s" % kind, "user:%s" % u.pk,
                after={"error": e.code}, ok=False)
        from .views_sections import user_detail_render
        return user_detail_render(request, u, error=T.get(e.code, e.code), status=400)
    u.refresh_from_db()
    S.audit(request, request.owner, "user.%s" % kind, "user:%s" % u.pk, before=before,
            after={"status": u.account_status,
                   "restrictions": sorted(r.kind for r in AS.active_restrictions(u)),
                   "action_id": act.id, "until": act.until.isoformat() if act.until else None,
                   "_reason": act.reason, "detail": act.detail})
    admin_stats.invalidate()
    return done("/owner/users/%d" % u.pk)


# ================================================================ appeals
@require_http_methods(["GET"])
@owner_view(perm="appeals")
def appeals(request):
    from core.models import AccountAppeal
    st = request.GET.get("status", "open")
    qs = AccountAppeal.objects.select_related("user", "action", "decided_by")
    qs = qs.filter(state="open") if st == "open" else qs.exclude(state="open")
    S.audit(request, request.owner, "appeal.list", "appeals:%s" % st)
    return page(request, "owner/appeals.html",
                {"rows": qs[:100], "st": st,
                 "n_open": AccountAppeal.objects.filter(state="open").count(),
                 "can_decide": S.has_perm(request.owner_role, "appeals_decide")},
                nav="appeals")


@require_http_methods(["POST"])
@owner_view(perm="appeals_decide")
def appeal_decide(request, pk):
    from core import admin_safety as AS
    from core import admin_stats
    from core.models import AccountAppeal
    ap = AccountAppeal.objects.select_related("user", "action").filter(pk=pk).first()
    if ap is None:
        raise Http404
    decision = request.POST.get("decision", "")
    try:
        AS.decide_appeal(ap, decision, request.POST.get("note", ""), request.owner)
    except AS.ActionError as e:
        S.audit(request, request.owner, "appeal.decide", "appeal:%s" % pk,
                after={"error": e.code}, ok=False)
        return done("/owner/appeals", "invalid")
    S.audit(request, request.owner, "appeal.%s" % decision, "appeal:%s" % pk,
            before={"state": "open"},
            after={"state": ap.state, "user": ap.user_id, "_reason": ap.decision_note})
    admin_stats.invalidate()
    return done("/owner/appeals")


# ================================================================== staff
@require_http_methods(["GET", "POST"])
@owner_view()            # owner only
def staff(request):
    from core.models import AdminStaffRole, OwnerSession, OwnerTOTP
    T = _T(request)
    err = ""
    if request.method == "POST":
        act = request.POST.get("action", "")
        reason = request.POST.get("reason", "").strip()[:200]
        if not reason:
            err = T["err_reason"]
        elif act == "grant":
            from .views_sections import _search_users
            role = request.POST.get("role", "")
            found = list(_search_users(request.POST.get("who", "")))[:2]
            if role not in S.STAFF_ROLES:
                err = T["as_err_role"]
            elif len(found) != 1 or found[0].is_superuser:
                err = T["as_err_who"]
            else:
                u = found[0]
                row, _ = AdminStaffRole.objects.update_or_create(
                    user=u, defaults={"role": role, "active": True,
                                      "granted_by": request.owner, "note": reason})
                S.audit(request, request.owner, "staff.grant", "user:%s" % u.pk,
                        after={"role": role, "_reason": reason})
                return done("/owner/staff", "granted")
        elif act in ("revoke", "reset2fa"):
            row = AdminStaffRole.objects.filter(pk=to_int(request.POST.get("id"))).first()
            if row is None:
                raise Http404
            if act == "revoke":
                row.active = False
                row.save(update_fields=["active", "updated_at"])
                OwnerSession.objects.filter(user=row.user).delete()
            else:
                OwnerTOTP.objects.filter(user=row.user).delete()
                OwnerSession.objects.filter(user=row.user).delete()
            S.audit(request, request.owner, "staff.%s" % act, "user:%s" % row.user_id,
                    after={"role": row.role, "_reason": reason})
            return done("/owner/staff", "revoked" if act == "revoke" else "saved")
        else:
            raise Http404
    rows = list(AdminStaffRole.objects.select_related("user", "granted_by")
                .order_by("-active", "role"))
    enrolled = set(OwnerTOTP.objects.filter(confirmed_at__isnull=False,
                                            user__in=[r.user for r in rows])
                   .values_list("user_id", flat=True))
    for r in rows:
        r.has_2fa = r.user_id in enrolled
    return page(request, "owner/staff.html",
                {"rows": rows, "roles": S.STAFF_ROLES, "error": err,
                 "perm_rows": [(p, [r for r in ("owner",) + S.STAFF_ROLES
                                    if S.has_perm(r, p)]) for p in S.PERMS]},
                status=400 if err else 200, nav="staff")
