"""
Axon Dynamics CRM — server-rendered web app (desktop, bilingual bn/en).

Session-authenticated (django.contrib.auth); all data is multi-tenant and
member-gated through CrmMember, exactly like the DRF layer. Every user-facing
string comes from crm/i18n.py so bn/en never mix inside a label. The pipeline is
a drag-and-drop kanban (HTML5 DnD → a small JSON endpoint). Forecasts come only
from real pipeline data (forecast.py); AI features show a clear needs-key state.

Reached at /crm/ once the integrator adds the root include (see report).
"""
import csv
import io
import re
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

from django.contrib.auth import authenticate, login as dj_login, logout as dj_logout
from django.contrib.auth.decorators import login_required
from django.db.models import Count, Q, Sum
from django.http import (HttpResponse, HttpResponseRedirect, JsonResponse,
                         Http404, HttpResponseForbidden)
from django.shortcuts import render, redirect, get_object_or_404
from django.urls import reverse
from django.utils import timezone
from django.views.decorators.http import require_http_methods, require_POST

from . import forecast as fc
from . import reports as rp
from . import pipeline as pl
from . import quoting, dupes, porting, cadence
from .audit import log as audit_log
from .i18n import tdict
from . import logic as core_logic
from .models import (CrmOrg, CrmMember, Lead, Conversation, Message, Proposal,
                     Company, Contact, Pipeline, Stage, Deal, Activity, Mention,
                     Tag, Product, Territory, RoutingRule, Target, Cadence,
                     CadenceStep, AuditEntry, CustomFieldDef)


# --------------------------------------------------------------- session helpers
def _lang(request):
    """Per-session language. ?lang=bn|en sets it; default bn."""
    q = request.GET.get("lang")
    if q in ("bn", "en"):
        request.session["crm_lang"] = q
    return request.session.get("crm_lang", "bn")


def _member_orgs(user):
    return CrmOrg.objects.filter(
        id__in=CrmMember.objects.filter(user=user).values_list("org_id", flat=True))


def _current_org(request):
    """Resolve the active org from ?org= or session, falling back to the user's
    first membership. Stores the choice in the session."""
    orgs = list(_member_orgs(request.user))
    if not orgs:
        return None
    q = request.GET.get("org") or request.session.get("crm_org")
    chosen = None
    if q:
        chosen = next((o for o in orgs if str(o.id) == str(q)), None)
    chosen = chosen or orgs[0]
    request.session["crm_org"] = str(chosen.id)
    return chosen


def _member(request, org):
    if not org:
        return None
    return CrmMember.objects.filter(user=request.user, org=org).first()


def _can_manage(member):
    return bool(member and member.role in (CrmMember.OWNER, CrmMember.MANAGER))


def _ctx(request, org, member, **extra):
    """Base template context: language dict, orgs list, active org/member."""
    lang = _lang(request)
    ctx = {
        "lang": lang,
        "t": tdict(lang),
        "orgs": list(_member_orgs(request.user)),
        "org": org,
        "member": member,
        "can_manage": _can_manage(member),
        "ai_on": _ai_available(),
    }
    ctx.update(extra)
    return ctx


def _ai_available():
    try:
        from core import ai
        return bool(ai.available())
    except Exception:
        return False


def _dec(v, default="0"):
    try:
        return Decimal(str(v or default))
    except (InvalidOperation, ValueError, TypeError):
        return Decimal(default)


def _parse_date(v):
    if not v:
        return None
    try:
        return datetime.strptime(v, "%Y-%m-%d").date()
    except (ValueError, TypeError):
        return None


# --------------------------------------------------------------- auth
@require_http_methods(["GET", "POST"])
def crm_login(request):
    lang = _lang(request)
    t = tdict(lang)
    error = ""
    if request.method == "POST":
        user = authenticate(request,
                            username=request.POST.get("username", ""),
                            password=request.POST.get("password", ""))
        if user:
            dj_login(request, user)
            return redirect("crm_dashboard")
        error = {"bn": "ভুল ইউজারনেম বা পাসওয়ার্ড",
                 "en": "Wrong username or password"}[lang]
    return render(request, "crm/login.html",
                  {"lang": lang, "t": t, "error": error})


def crm_logout(request):
    dj_logout(request)
    return redirect("crm_login")


def _require_org(request):
    """Return (org, member) or render the no-org page response (raised via a
    sentinel). Views call this and check for None."""
    org = _current_org(request)
    member = _member(request, org)
    return org, member


# --------------------------------------------------------------- dashboard
@login_required(login_url="/crm/login")
def dashboard(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    pl.ensure_default_pipeline(org)

    deals = Deal.objects.filter(org=org)
    forecast = fc.weighted_forecast(deals)

    month_start = date.today().replace(day=1)
    won_month = deals.filter(state="won", closed_at__date__gte=month_start)
    won_month_value = won_month.aggregate(s=Sum("value"))["s"] or Decimal(0)

    high_leads = (Lead.objects.filter(org=org, priority="high")
                  .exclude(status__in=["won", "lost"]).order_by("-score")[:10])
    stuck = pl.stuck_deals(deals)
    follow = cadence.due_followups(org, deals)

    # SLA breaches: high-priority leads past sla_due with no first response.
    now = timezone.now()
    sla_breaches = list(Lead.objects.filter(
        org=org, sla_due__lt=now, first_response_at__isnull=True)
        .exclude(status__in=["won", "lost"]).order_by("sla_due")[:10])

    my_tasks = []
    if member:
        my_tasks = list(Activity.objects.filter(
            org=org, kind=Activity.TASK, done=False, actor=member)
            .order_by("due_at")[:10])

    ctx = _ctx(request, org, member,
               forecast=forecast,
               won_month_value=won_month_value,
               won_month_count=won_month.count(),
               open_count=deals.filter(state="open").count(),
               high_leads=high_leads,
               stuck=stuck[:8],
               overdue=follow["overdue_next_steps"][:8],
               missing_next=follow["missing_next_step"][:8],
               sla_breaches=sla_breaches,
               my_tasks=my_tasks)
    return render(request, "crm/dashboard.html", ctx)


# --------------------------------------------------------------- org create / switch
@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def org_create(request):
    lang = _lang(request)
    if request.method == "POST":
        name = (request.POST.get("name") or "").strip()
        if name:
            org = CrmOrg.objects.create(name=name, owner=request.user)
            CrmMember.objects.get_or_create(
                org=org, user=request.user,
                defaults={"role": CrmMember.OWNER})
            pl.ensure_default_pipeline(org)
            request.session["crm_org"] = str(org.id)
            return redirect("crm_dashboard")
    return render(request, "crm/org_create.html",
                  {"lang": lang, "t": tdict(lang)})


# --------------------------------------------------------------- pipeline (kanban)
@login_required(login_url="/crm/login")
def pipeline_board(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    pl.ensure_default_pipeline(org)

    pipe_id = request.GET.get("pipeline")
    pipe = None
    if pipe_id:
        pipe = org.pipelines.filter(id=pipe_id).first()
    pipe = pipe or org.pipelines.filter(is_default=True).first() or org.pipelines.first()

    stages = list(pipe.stages.order_by("order"))
    deals = list(Deal.objects.filter(org=org, pipeline=pipe)
                 .select_related("stage", "company", "owner__user"))
    stuck_ids = {s["deal_id"] for s in pl.stuck_deals(Deal.objects.filter(org=org, pipeline=pipe))}

    columns = []
    now = timezone.now()
    for s in stages:
        col_deals = [d for d in deals if d.stage_id == s.id]
        col_value = sum((d.value or Decimal(0)) for d in col_deals)
        rows = []
        for d in col_deals:
            age = (now - d.stage_entered_at).days
            rows.append({"d": d, "age": age, "stuck": d.id in stuck_ids})
        columns.append({"stage": s, "deals": rows, "value": col_value,
                        "count": len(col_deals)})

    ctx = _ctx(request, org, member,
               pipeline=pipe,
               pipelines=list(org.pipelines.all()),
               columns=columns)
    return render(request, "crm/pipeline.html", ctx)


@login_required(login_url="/crm/login")
@require_POST
def deal_move(request):
    """Kanban drag endpoint: move a deal to a new stage. JSON in/out."""
    org, member = _require_org(request)
    if not org:
        return JsonResponse({"ok": False, "error": "no_org"}, status=400)
    deal = get_object_or_404(Deal, id=request.POST.get("deal"), org=org)
    stage = get_object_or_404(Stage, id=request.POST.get("stage"),
                              pipeline=deal.pipeline)
    # Won/Lost need extra data — the board asks the user via the detail page.
    if stage.is_lost and not request.POST.get("loss_reason"):
        return JsonResponse({"ok": False, "need_loss_reason": True,
                             "deal": deal.id})
    if stage.is_lost:
        deal.loss_reason = request.POST.get("loss_reason", "other")
        deal.loss_note = request.POST.get("loss_note", "")
        deal.save(update_fields=["loss_reason", "loss_note"])
    pl.move_deal(deal, stage, member=member)
    return JsonResponse({"ok": True, "deal": deal.id, "stage": stage.id,
                         "state": deal.state})


# --------------------------------------------------------------- leads
@login_required(login_url="/crm/login")
def lead_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    qs = Lead.objects.filter(org=org)
    q = (request.GET.get("q") or "").strip()
    if q:
        qs = qs.filter(Q(name__icontains=q) | Q(company__icontains=q) |
                       Q(email__icontains=q) | Q(phone__icontains=q))
    prio = request.GET.get("priority")
    if prio in ("high", "normal"):
        qs = qs.filter(priority=prio)
    status_f = request.GET.get("status")
    if status_f:
        qs = qs.filter(status=status_f)
    ctx = _ctx(request, org, member, leads=qs[:300], q=q,
               statuses=Lead.STATUSES, industries=Lead.INDUSTRIES,
               sources=Lead.SOURCES)
    return render(request, "crm/lead_list.html", ctx)


@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def lead_create(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    if request.method == "POST":
        assignee, _terr = pl.route_lead(
            org,
            industry=request.POST.get("industry", "other"),
            source=request.POST.get("source", "manual"),
            company_size=int(request.POST.get("company_size") or 0))
        lead = core_logic.capture_lead(
            org=org,
            source=request.POST.get("source", "manual"),
            contact={"phone": request.POST.get("phone", ""),
                     "email": request.POST.get("email", "")},
            first_message=request.POST.get("message", ""),
            name=request.POST.get("name", ""),
            company=request.POST.get("company", ""),
            industry=request.POST.get("industry", "other"),
            company_size=int(request.POST.get("company_size") or 0),
            assigned_to=assignee or member)
        # SLA first-response timer: high-priority leads get a tight 4h window,
        # others 24h. This is a sensible default the owner can tune later; it is
        # a target, not a promise, and never fabricates activity.
        hours = 4 if lead.priority == "high" else 24
        lead.sla_due = timezone.now() + timezone.timedelta(hours=hours)
        lead.save(update_fields=["sla_due"])
        audit_log(org, member, "lead.create", f"lead#{lead.id}", lead.name)
        return redirect("crm_lead_detail", pk=lead.id)
    ctx = _ctx(request, org, member, industries=Lead.INDUSTRIES,
               sources=Lead.SOURCES)
    return render(request, "crm/lead_form.html", ctx)


@login_required(login_url="/crm/login")
def lead_detail(request, pk):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    lead = get_object_or_404(Lead, pk=pk, org=org)
    convs = lead.conversations.prefetch_related("messages").all()
    acts = Activity.objects.filter(lead=lead).order_by("-created_at")[:50]
    proposals = lead.proposals.all()
    followup = core_logic.suggest_followup(lead)
    members = CrmMember.objects.filter(org=org).select_related("user")
    ctx = _ctx(request, org, member, lead=lead, conversations=convs,
               activities=acts, proposals=proposals, followup=followup,
               members=members, statuses=Lead.STATUSES,
               deals=lead.deals.all())
    return render(request, "crm/lead_detail.html", ctx)


@login_required(login_url="/crm/login")
@require_POST
def lead_update(request, pk):
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    lead = get_object_or_404(Lead, pk=pk, org=org)
    status_f = request.POST.get("status")
    if status_f in dict(Lead.STATUSES):
        lead.status = status_f
    assignee_id = request.POST.get("assigned_to")
    if assignee_id:
        m = CrmMember.objects.filter(org=org, id=assignee_id).first()
        if m:
            lead.assigned_to = m
    lead.save()
    audit_log(org, member, "lead.update", f"lead#{lead.id}", lead.status)
    return redirect("crm_lead_detail", pk=lead.id)


@login_required(login_url="/crm/login")
@require_POST
def lead_message(request, pk):
    """Quick-log an outbound/inbound message (also used by click-to-act)."""
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    lead = get_object_or_404(Lead, pk=pk, org=org)
    text = (request.POST.get("text") or "")[:8000]
    direction = request.POST.get("direction", Message.IN)
    if direction not in (Message.IN, Message.OUT):
        direction = Message.IN
    conv = lead.conversations.first() or Conversation.objects.create(
        lead=lead, channel=lead.source)
    core_logic.add_message(conv, direction, text)
    # First outbound reply sets the SLA first-response timestamp.
    if direction == Message.OUT and not lead.first_response_at:
        lead.first_response_at = timezone.now()
        lead.save(update_fields=["first_response_at"])
    audit_log(org, member, "lead.message", f"lead#{lead.id}", direction)
    return redirect("crm_lead_detail", pk=lead.id)


@login_required(login_url="/crm/login")
def lead_export(request):
    org, member = _require_org(request)
    if not org:
        raise Http404
    leads = Lead.objects.filter(org=org)
    fmt = request.GET.get("fmt", "csv")
    if fmt == "xlsx":
        res = porting.leads_to_xlsx(leads)
        if res:
            data, fname = res
            resp = HttpResponse(
                data,
                content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            resp["Content-Disposition"] = f'attachment; filename="{fname}"'
            return resp
        # fall through to CSV if openpyxl absent
    csv_text = porting.leads_to_csv(leads)
    resp = HttpResponse(csv_text, content_type="text/csv; charset=utf-8")
    resp["Content-Disposition"] = 'attachment; filename="leads.csv"'
    return resp


@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def lead_import(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    summary = None
    if request.method == "POST" and request.FILES.get("file"):
        summary = porting.import_leads_csv(org, request.FILES["file"],
                                           assigned_to=member)
        audit_log(org, member, "lead.import", "", str(summary))
    return render(request, "crm/lead_import.html",
                  _ctx(request, org, member, summary=summary))


# --------------------------------------------------------------- companies & contacts
@login_required(login_url="/crm/login")
def company_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    companies = Company.objects.filter(org=org).select_related("parent")
    return render(request, "crm/company_list.html",
                  _ctx(request, org, member, companies=companies,
                       industries=Lead.INDUSTRIES))


@login_required(login_url="/crm/login")
@require_POST
def company_create(request):
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    parent = None
    if request.POST.get("parent"):
        parent = Company.objects.filter(org=org, id=request.POST["parent"]).first()
    c = Company.objects.create(
        org=org, name=(request.POST.get("name") or "").strip() or "Company",
        parent=parent, industry=request.POST.get("industry", "other"),
        size=int(request.POST.get("size") or 0),
        website=request.POST.get("website", ""),
        phone=request.POST.get("phone", ""),
        address=request.POST.get("address", ""), owner=member)
    audit_log(org, member, "company.create", f"company#{c.id}", c.name)
    return redirect("crm_companies")


@login_required(login_url="/crm/login")
def contact_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    contacts = Contact.objects.filter(org=org).select_related("company")
    companies = Company.objects.filter(org=org)
    return render(request, "crm/contact_list.html",
                  _ctx(request, org, member, contacts=contacts, companies=companies))


@login_required(login_url="/crm/login")
@require_POST
def contact_create(request):
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    company = None
    if request.POST.get("company"):
        company = Company.objects.filter(org=org, id=request.POST["company"]).first()
    c = Contact.objects.create(
        org=org, company=company,
        name=(request.POST.get("name") or "").strip() or "Contact",
        title=request.POST.get("title", ""), phone=request.POST.get("phone", ""),
        email=request.POST.get("email", ""),
        whatsapp=request.POST.get("whatsapp", ""), owner=member)
    audit_log(org, member, "contact.create", f"contact#{c.id}", c.name)
    return redirect("crm_contacts")


# --------------------------------------------------------------- deals
@login_required(login_url="/crm/login")
def deal_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    qs = Deal.objects.filter(org=org).select_related("stage", "company", "owner__user")
    state = request.GET.get("state")
    if state in ("open", "won", "lost"):
        qs = qs.filter(state=state)
    return render(request, "crm/deal_list.html",
                  _ctx(request, org, member, deals=qs[:300]))


@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def deal_create(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    pl.ensure_default_pipeline(org)
    if request.method == "POST":
        pipe = org.pipelines.filter(id=request.POST.get("pipeline")).first() \
            or org.pipelines.filter(is_default=True).first()
        stage = pipe.stages.filter(id=request.POST.get("stage")).first() \
            or pipe.stages.order_by("order").first()
        lead = None
        if request.POST.get("lead"):
            lead = Lead.objects.filter(org=org, id=request.POST["lead"]).first()
        company = None
        if request.POST.get("company"):
            company = Company.objects.filter(org=org, id=request.POST["company"]).first()
        d = Deal.objects.create(
            org=org, title=(request.POST.get("title") or "Deal").strip(),
            pipeline=pipe, stage=stage, lead=lead, company=company,
            value=_dec(request.POST.get("value")),
            probability=int(request.POST.get("probability") or stage.probability),
            expected_close=_parse_date(request.POST.get("expected_close")),
            next_step=request.POST.get("next_step", ""),
            next_step_due=_parse_date(request.POST.get("next_step_due")),
            source=request.POST.get("source", "manual"), owner=member)
        audit_log(org, member, "deal.create", f"deal#{d.id}", d.title)
        return redirect("crm_deal_detail", pk=d.id)
    pipes = list(org.pipelines.prefetch_related("stages").all())
    leads = Lead.objects.filter(org=org).exclude(status__in=["won", "lost"])[:200]
    companies = Company.objects.filter(org=org)
    return render(request, "crm/deal_form.html",
                  _ctx(request, org, member, pipelines=pipes, leads=leads,
                       companies=companies, sources=Lead.SOURCES))


@login_required(login_url="/crm/login")
def deal_detail(request, pk):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    deal = get_object_or_404(Deal, pk=pk, org=org)
    acts = Activity.objects.filter(deal=deal).order_by("-created_at")[:50]
    age = (timezone.now() - deal.stage_entered_at).days
    stuck = age > (deal.stage.stuck_after_days or 10**9)
    ctx = _ctx(request, org, member, deal=deal, activities=acts,
               stages=deal.pipeline.stages.order_by("order"),
               proposals=deal.proposals.all(),
               cadences=Cadence.objects.filter(org=org, active=True),
               loss_reasons=Deal.LOSS_REASONS, age=age, stuck=stuck)
    return render(request, "crm/deal_detail.html", ctx)


@login_required(login_url="/crm/login")
@require_POST
def deal_update(request, pk):
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    deal = get_object_or_404(Deal, pk=pk, org=org)
    deal.title = (request.POST.get("title") or deal.title).strip()
    deal.value = _dec(request.POST.get("value"), str(deal.value))
    if request.POST.get("probability"):
        deal.probability = int(request.POST["probability"])
    deal.expected_close = _parse_date(request.POST.get("expected_close")) or deal.expected_close
    deal.next_step = request.POST.get("next_step", deal.next_step)
    deal.next_step_due = _parse_date(request.POST.get("next_step_due")) or deal.next_step_due
    deal.save()
    audit_log(org, member, "deal.update", f"deal#{deal.id}", deal.title)
    return redirect("crm_deal_detail", pk=deal.id)


@login_required(login_url="/crm/login")
@require_POST
def deal_stage(request, pk):
    """Move a deal to a stage from the detail page (enforces loss reason)."""
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    deal = get_object_or_404(Deal, pk=pk, org=org)
    stage = get_object_or_404(Stage, id=request.POST.get("stage"),
                              pipeline=deal.pipeline)
    if stage.is_lost:
        reason = request.POST.get("loss_reason")
        if not reason:
            # Mandatory loss reason (spec §6).
            return render(request, "crm/deal_detail.html",
                          _ctx(request, org, member, deal=deal,
                               stages=deal.pipeline.stages.order_by("order"),
                               activities=Activity.objects.filter(deal=deal)[:50],
                               proposals=deal.proposals.all(),
                               cadences=Cadence.objects.filter(org=org, active=True),
                               loss_reasons=Deal.LOSS_REASONS, age=0, stuck=False,
                               loss_required=True))
        deal.loss_reason = reason
        deal.loss_note = request.POST.get("loss_note", "")
        deal.competitor = request.POST.get("competitor", "")
        deal.save(update_fields=["loss_reason", "loss_note", "competitor"])
    pl.move_deal(deal, stage, member=member)
    return redirect("crm_deal_detail", pk=deal.id)


@login_required(login_url="/crm/login")
@require_POST
def deal_onboard(request, pk):
    """Won → Axon ERP onboarding hand-off (gated, needs-integration safe)."""
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    deal = get_object_or_404(Deal, pk=pk, org=org)
    result = {}
    if deal.lead:
        result = core_logic.onboard_to_erp(deal.lead)
    else:
        result = {"ok": False, "reason": "no_lead",
                  "message": "এই ডিলে কোনো লিড লিঙ্ক নেই / No lead linked to this deal"}
    audit_log(org, member, "deal.onboard", f"deal#{deal.id}", str(result.get("ok")))
    return render(request, "crm/onboard_result.html",
                  _ctx(request, org, member, deal=deal, result=result))


@login_required(login_url="/crm/login")
@require_POST
def deal_enroll(request, pk):
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    deal = get_object_or_404(Deal, pk=pk, org=org)
    cad = Cadence.objects.filter(org=org, id=request.POST.get("cadence")).first()
    if cad:
        cadence.enroll(deal, cad, member=member)
        audit_log(org, member, "deal.enroll", f"deal#{deal.id}", cad.name)
    return redirect("crm_deal_detail", pk=deal.id)


# --------------------------------------------------------------- activities
_MENTION_RE = re.compile(r"@([A-Za-z0-9_.-]+)")


@login_required(login_url="/crm/login")
@require_POST
def activity_log(request):
    """Quick-log a call/meeting/note/task against a lead or deal + @mentions."""
    org, member = _require_org(request)
    if not org:
        return JsonResponse({"ok": False}, status=400)
    kind = request.POST.get("kind", Activity.NOTE)
    if kind not in dict(Activity.KINDS):
        kind = Activity.NOTE
    lead = Lead.objects.filter(org=org, id=request.POST.get("lead")).first()
    deal = Deal.objects.filter(org=org, id=request.POST.get("deal")).first()
    due = request.POST.get("due_at")
    due_at = None
    if due:
        due_at = _parse_date(due)
        if due_at:
            due_at = timezone.make_aware(datetime.combine(due_at, datetime.min.time()))
    act = Activity.objects.create(
        org=org, kind=kind, subject=request.POST.get("subject", ""),
        body=request.POST.get("body", ""), lead=lead, deal=deal,
        actor=member, due_at=due_at)
    # Parse @mentions (match member usernames) → Mention rows.
    for uname in set(_MENTION_RE.findall(act.body or "")):
        m = CrmMember.objects.filter(
            org=org, user__username=uname).first()
        if m:
            Mention.objects.create(activity=act, member=m)
    audit_log(org, member, f"activity.{kind}", f"activity#{act.id}",
              act.subject or act.body[:40])
    nxt = request.POST.get("next") or request.META.get("HTTP_REFERER") or "/crm/"
    return redirect(nxt)


@login_required(login_url="/crm/login")
@require_POST
def activity_done(request, pk):
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    act = get_object_or_404(Activity, pk=pk, org=org)
    act.done = True
    act.done_at = timezone.now()
    act.save(update_fields=["done", "done_at"])
    nxt = request.POST.get("next") or request.META.get("HTTP_REFERER") or "/crm/"
    return redirect(nxt)


@login_required(login_url="/crm/login")
def activity_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    qs = Activity.objects.filter(org=org).select_related("actor__user", "lead", "deal")
    show = request.GET.get("show")
    if show == "open_tasks":
        qs = qs.filter(kind=Activity.TASK, done=False)
    mentions = []
    if member:
        mentions = Mention.objects.filter(member=member, seen=False)\
            .select_related("activity")[:20]
    return render(request, "crm/activity_list.html",
                  _ctx(request, org, member, activities=qs[:200],
                       mentions=mentions, kinds=Activity.KINDS))


# --------------------------------------------------------------- proposals / quotes
@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def proposal_build(request, lead_pk):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    lead = get_object_or_404(Lead, pk=lead_pk, org=org)
    products = Product.objects.filter(org=org, active=True)
    if request.method == "POST":
        selections = []
        for p in products:
            qty = request.POST.get(f"qty_{p.sku}")
            if qty and int(qty) > 0:
                selections.append({"sku": p.sku, "qty": int(qty)})
        body = ""
        if request.POST.get("ai_draft") and _ai_available():
            res = core_logic.generate_proposal(
                lead, request.POST.get("requirements", ""))
            if res.get("ok"):
                body = res.get("body", "")
        prop = quoting.make_quote(
            lead, selections,
            requirements=request.POST.get("requirements", ""),
            discount_pct=_dec(request.POST.get("discount_pct")),
            tax_pct=_dec(request.POST.get("tax_pct")),
            title=request.POST.get("title", ""),
            created_by=member, body=body,
            deal=lead.deals.filter(state="open").first())
        audit_log(org, member, "proposal.create",
                  f"proposal#{prop.id}", f"v{prop.version} ৳{prop.total}")
        return redirect("crm_proposal_detail", pk=prop.id)
    ctx = _ctx(request, org, member, lead=lead, products=products,
               threshold=quoting.DISCOUNT_APPROVAL_THRESHOLD)
    return render(request, "crm/proposal_build.html", ctx)


@login_required(login_url="/crm/login")
def proposal_detail(request, pk):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    prop = get_object_or_404(Proposal, pk=pk, lead__org=org)
    return render(request, "crm/proposal_detail.html",
                  _ctx(request, org, member, p=prop))


@login_required(login_url="/crm/login")
@require_POST
def proposal_action(request, pk):
    """Approve / send / mark viewed / accepted / declined — the approval + status
    workflow (spec §5)."""
    org, member = _require_org(request)
    if not org:
        return redirect("crm_org_create")
    prop = get_object_or_404(Proposal, pk=pk, lead__org=org)
    act = request.POST.get("action")
    now = timezone.now()
    if act == "approve" and _can_manage(member):
        prop.status = Proposal.APPROVED
        prop.approved_by = member
        prop.approved_at = now
        prop.discount_needs_approval = False
    elif act == "send":
        # Block sending an unapproved discounted quote (approval workflow).
        if prop.discount_needs_approval and prop.status != Proposal.APPROVED:
            return redirect("crm_proposal_detail", pk=prop.id)
        prop.status = Proposal.SENT
        prop.sent_at = now
    elif act == "viewed":
        prop.status = Proposal.VIEWED
        prop.viewed_at = now
    elif act == "accepted":
        prop.status = Proposal.ACCEPTED
        prop.accepted_at = now
    elif act == "declined":
        prop.status = Proposal.DECLINED
    prop.save()
    audit_log(org, member, "proposal.action", f"proposal#{prop.id}", act)
    return redirect("crm_proposal_detail", pk=prop.id)


@login_required(login_url="/crm/login")
def proposal_pdf(request, pk):
    """Print-optimised quotation page (browser → Save as PDF). No PDF lib needed
    on this shared server; the layout is clean A4-styled HTML."""
    org, member = _require_org(request)
    if not org:
        raise Http404
    prop = get_object_or_404(Proposal, pk=pk, lead__org=org)
    return render(request, "crm/proposal_pdf.html",
                  _ctx(request, org, member, p=prop))


@login_required(login_url="/crm/login")
def proposal_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    props = Proposal.objects.filter(lead__org=org).select_related("lead")[:200]
    return render(request, "crm/proposal_list.html",
                  _ctx(request, org, member, proposals=props))


# --------------------------------------------------------------- price book
@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def product_list(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    if request.method == "POST" and _can_manage(member):
        sku = (request.POST.get("sku") or "").strip()
        if sku:
            Product.objects.update_or_create(
                org=org, sku=sku,
                defaults={
                    "name": request.POST.get("name", sku),
                    "description": request.POST.get("description", ""),
                    "unit_price": _dec(request.POST.get("unit_price")),
                    "billing": request.POST.get("billing", Product.ONE_TIME),
                    "price_reviewed": bool(request.POST.get("price_reviewed")),
                    "active": True})
            audit_log(org, member, "product.save", sku, "")
        return redirect("crm_products")
    products = Product.objects.filter(org=org)
    return render(request, "crm/product_list.html",
                  _ctx(request, org, member, products=products,
                       billing=Product.BILLING))


# --------------------------------------------------------------- reports
@login_required(login_url="/crm/login")
def reports(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    deals = Deal.objects.filter(org=org)
    pipe = org.pipelines.filter(is_default=True).first() or org.pipelines.first()
    acts = Activity.objects.filter(org=org)
    ctx = _ctx(request, org, member,
               funnel=rp.funnel(pipe, deals) if pipe else {"has_data": False, "rows": []},
               win_loss=rp.win_loss(deals),
               sales_cycle=rp.sales_cycle(deals),
               source_attr=rp.source_attribution(deals),
               by_industry=rp.pipeline_by_industry(deals),
               rep_perf=rp.rep_performance(org, deals),
               leaderboard=rp.activity_leaderboard(org, acts),
               forecast=fc.weighted_forecast(deals))
    return render(request, "crm/reports.html", ctx)


# --------------------------------------------------------------- team & settings
@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def team(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    if request.method == "POST" and _can_manage(member):
        if request.POST.get("add_member"):
            from django.contrib.auth import get_user_model
            U = get_user_model()
            u = U.objects.filter(username=request.POST.get("username", "")).first()
            if u:
                CrmMember.objects.get_or_create(
                    org=org, user=u,
                    defaults={"role": request.POST.get("role", CrmMember.SALES)})
                audit_log(org, member, "member.add", u.username,
                          request.POST.get("role", ""))
        elif request.POST.get("set_target"):
            m = CrmMember.objects.filter(org=org, id=request.POST.get("member")).first()
            if m:
                Target.objects.update_or_create(
                    org=org, member=m, period=request.POST.get("period", ""),
                    defaults={"amount": _dec(request.POST.get("amount")),
                              "deals_target": int(request.POST.get("deals_target") or 0)})
        return redirect("crm_team")
    members = CrmMember.objects.filter(org=org).select_related("user")
    targets = Target.objects.filter(org=org).select_related("member__user")
    territories = Territory.objects.filter(org=org)
    return render(request, "crm/team.html",
                  _ctx(request, org, member, members=members, targets=targets,
                       territories=territories, roles=CrmMember.ROLES))


@login_required(login_url="/crm/login")
def audit_view(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    entries = AuditEntry.objects.filter(org=org).select_related("member__user")[:300]
    return render(request, "crm/audit.html",
                  _ctx(request, org, member, entries=entries))


# --------------------------------------------------------------- duplicates
@login_required(login_url="/crm/login")
@require_http_methods(["GET", "POST"])
def duplicates(request):
    org, member = _require_org(request)
    if not org:
        return render(request, "crm/no_org.html", _ctx(request, None, None))
    if request.method == "POST":
        survivor_id = request.POST.get("survivor")
        raw_dup_ids = request.POST.getlist("dup")
        if survivor_id and raw_dup_ids:
            # Scope everything to this org so a forged lead id from another
            # tenant can never be merged/deleted (cross-tenant IDOR).
            survivor = get_object_or_404(Lead, id=survivor_id, org=org)
            dup_ids = list(Lead.objects.filter(
                org=org, id__in=[int(x) for x in raw_dup_ids if str(x).isdigit()])
                .values_list("id", flat=True))
            if dup_ids:
                dupes.merge_leads(survivor.id, dup_ids, org)
                audit_log(org, member, "lead.merge", f"lead#{survivor.id}",
                          ",".join(str(i) for i in dup_ids))
        return redirect("crm_duplicates")
    groups = dupes.find_lead_duplicates(org)
    # attach lead objects for display
    rich = []
    for g in groups:
        leads = list(Lead.objects.filter(org=org, id__in=g["lead_ids"]))
        rich.append({"match_on": g["match_on"], "leads": leads})
    return render(request, "crm/duplicates.html",
                  _ctx(request, org, member, groups=rich))
