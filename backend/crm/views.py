"""
CRM DRF views. All access is multi-tenant and member-gated: a request only ever
sees orgs the user belongs to (via CrmMember). The capture webhook degrades to a
needs-key state when WhatsApp isn't connected; the dashboard forecast is an
honest estimate computed from REAL pipeline data (never fabricated).

This module backs the WHOLE in-app CRM (CRM_SPEC). Beyond the original
orgs/leads/conversations/proposals/dashboard surface it adds DRF ViewSets for
deals, pipelines + stages, activities (timeline + quick-log), members/team +
routing, companies, contacts and the price book, plus two aggregation
endpoints: a "Today" screen feed and a rule-based paste-extraction helper that
pulls phone/email/company/name guesses out of pasted text WITHOUT any AI key.
"""
import re

from django.db.models import Count, Sum
from django.shortcuts import get_object_or_404
from django.utils import timezone
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from django.db import transaction

from . import logic, pipeline as pl, forecast as fc, reports as rp, cadence, quoting
from . import errors as crm_errors
from . import whatsapp as wa
from .models import (CrmOrg, CrmMember, Lead, Conversation, Message, Proposal,
                     Company, Contact, Pipeline, Stage, Deal, Activity,
                     Product, Territory, RoutingRule, AuditEntry,
                     WhatsAppTemplate, WhatsAppOptIn)
from .serializers import (CrmOrgSerializer, CrmMemberSerializer, LeadSerializer,
                          ConversationSerializer, MessageSerializer,
                          ProposalSerializer, CompanySerializer,
                          ContactSerializer, PipelineSerializer, StageSerializer,
                          DealSerializer, ActivitySerializer, ProductSerializer,
                          TerritorySerializer, RoutingRuleSerializer,
                          WhatsAppTemplateSerializer)


# --------------------------------------------------------------- error handling
class CrmErrorMixin:
    """Route every exception raised inside a CRM view through the CRM exception
    handler so it gets a reference code that is ALSO written to the server log
    (crm.errors.crm_exception_handler). Applied per-view so non-CRM apps are
    untouched — the client shows the same code, support greps the log for it."""

    def get_exception_handler(self):
        return crm_errors.crm_exception_handler


# --------------------------------------------------------------- helpers
def _member_org_ids(user):
    """Org ids the user can access (member of). Empty → sees nothing."""
    return list(CrmMember.objects.filter(user=user).values_list("org_id", flat=True))


def _member_for(user, org_id):
    return CrmMember.objects.filter(user=user, org_id=org_id).first()


def _can_manage(member):
    """Owners/managers can route and reassign; sales can act on own leads."""
    return bool(member and member.role in (CrmMember.OWNER, CrmMember.MANAGER))


def _require_member(user, org):
    """Resolve + verify membership for a write. Raises PermissionDenied."""
    org_id = org.id if hasattr(org, "id") else org
    member = _member_for(user, org_id)
    if not member:
        raise PermissionDenied("আপনি এই org-এর সদস্য নন / Not a member of this org")
    return member


# --------------------------------------------------------------- WhatsApp helpers
def _wa_has_key():
    """True only when the owner has CONNECTED the official Meta WhatsApp Cloud
    integration (status='working'). Until then every live send is MOCKED and the
    client shows the key-gated "connect WhatsApp Business" state."""
    try:
        from core import integrations
        return integrations.is_enabled("whatsapp")
    except Exception:
        return False


def _wa_optin(lead):
    """The lead's WhatsApp opt-in / service-window row (created lazily)."""
    row, _ = WhatsAppOptIn.objects.get_or_create(lead=lead)
    return row


def _wa_dest(lead):
    """Preferred WhatsApp destination for a lead: its whatsapp number, else the
    primary phone. Digits only (E.164-ish) — the Cloud API wants a bare number."""
    return wa.normalize_wa_number(lead.whatsapp or lead.phone or "")


def _log_wa_activity(lead, member, direction, text):
    """AUTO-LOG a WhatsApp send/receive onto the lead's timeline as an Activity
    (kind='whatsapp'). This is the KEY VALUE of the integration — every comm is
    recorded without the rep writing notes. Reuses the existing Activity model;
    no new log table is needed."""
    arrow = "→" if direction == "out" else "←"
    return Activity.objects.create(
        org=lead.org, kind=Activity.WHATSAPP, lead=lead, actor=member,
        subject=f"WhatsApp {arrow}",
        body=(text or "")[:4000])


def _backing_deal(lead):
    """The Deal that represents this lead's opportunity, if one exists. A lead
    can have several deals; we treat the most recent as the backing opportunity
    for win/lost close-out."""
    return lead.deals.order_by("-created_at").first()


def _ensure_deal_for(lead):
    """Return the lead's backing Deal, creating one on the org's default pipeline
    if none exists yet. Placed on the first (lowest-order) stage so moving it to
    a won/lost stage is a real pipeline transition (keeps forecast/reports sane).
    """
    deal = _backing_deal(lead)
    if deal:
        return deal
    pipe = pl.ensure_default_pipeline(lead.org)
    first_stage = pipe.stages.order_by("order").first()
    return Deal.objects.create(
        org=lead.org, title=lead.company or lead.name or f"Lead #{lead.id}",
        pipeline=pipe, stage=first_stage, lead=lead,
        owner=lead.assigned_to, source=lead.source)


class _OrgScopedViewSet(CrmErrorMixin, viewsets.ModelViewSet):
    """Base for every org-owned model: queryset auto-scoped to the caller's
    memberships, writes verified against the `org` in the payload. This is the
    one place the multi-tenant rule lives, so no ViewSet can leak across tenants.
    """
    permission_classes = [IsAuthenticated]
    model = None
    org_path = "org_id__in"   # lookup from model → CrmOrg ids

    def get_queryset(self):
        return self.model.objects.filter(
            **{self.org_path: _member_org_ids(self.request.user)})

    def perform_create(self, serializer):
        org = serializer.validated_data.get("org")
        _require_member(self.request.user, org)
        serializer.save()


# --------------------------------------------------------------- orgs
class CrmOrgViewSet(CrmErrorMixin, viewsets.ModelViewSet):
    """Create/list the sales orgs (tenants) the user belongs to.

    FIRST-RUN "Start your company's CRM": POST /crm/orgs/ with
    {name, industry, team_size} creates the org, seeds the creator as its OWNER
    member AND a default pipeline + stages (pl.ensure_default_pipeline — the same
    DEFAULT_STAGES the web org_create uses) so the kanban board works
    immediately. A unique invite code is minted for the org (teammates join with
    POST /crm/join). The invite code is owner-only (see `invite` below)."""
    serializer_class = CrmOrgSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return CrmOrg.objects.filter(id__in=_member_org_ids(self.request.user))

    @transaction.atomic
    def perform_create(self, serializer):
        org = serializer.save(owner=self.request.user)
        CrmMember.objects.get_or_create(
            org=org, user=self.request.user,
            defaults={"role": CrmMember.OWNER})
        # Seed a sample pipeline with the default stages so the new owner lands
        # on a working board, not an empty one (reuse the web create logic).
        pl.ensure_default_pipeline(org)

    # ----- owner-only invite code (GET to read, POST to rotate) -----
    @action(detail=True, methods=["get", "post"])
    def invite(self, request, pk=None):
        """Read (GET) or rotate (POST) the org's team invite code. Owners and
        managers only — a salesperson must not be able to pull the code and
        recruit members. Scoped: get_object() already 404s for non-members, and
        we additionally require manage rights."""
        org = self.get_object()
        member = _member_for(request.user, org.id)
        if not _can_manage(member):
            raise PermissionDenied(
                "শুধু owner/manager ইনভাইট কোড দেখতে পারেন / "
                "Only an owner or manager can view the invite code")
        if request.method == "POST":
            org.rotate_invite_code()
        return Response({"ok": True, "org": org.id, "invite_code": org.invite_code})


# --------------------------------------------------------------- join a team
class JoinOrgView(CrmErrorMixin, APIView):
    """FIRST-RUN "Join a team": POST /crm/join {code} → add the caller as a
    SALES member of the org that owns that invite code. Idempotent (already a
    member → returns the existing membership). No IDOR: the ONLY way in is a
    valid code, and the joiner always lands as a plain salesperson — never owner
    or manager."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        code = (request.data.get("code") or "").strip().upper()
        if not code:
            raise ValidationError(
                {"code": "ইনভাইট কোড দিন / Enter an invite code"})
        org = CrmOrg.objects.filter(invite_code=code).first()
        if org is None:
            raise ValidationError(
                {"code": "কোডটি সঠিক নয় / That invite code is not valid"})
        member, created = CrmMember.objects.get_or_create(
            org=org, user=request.user,
            defaults={"role": CrmMember.SALES})
        return Response({
            "ok": True, "joined": created, "org": CrmOrgSerializer(org).data,
            "role": member.role,
        })


# --------------------------------------------------------------- leads
class LeadViewSet(CrmErrorMixin, viewsets.ModelViewSet):
    """CRUD for leads, scoped to the user's orgs. Supports ?priority=, ?status=,
    ?industry=, ?org= and ?q= (name/company/phone search). Score/priority stay
    server-computed."""
    serializer_class = LeadSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = Lead.objects.filter(org_id__in=_member_org_ids(self.request.user))
        p = self.request.query_params
        if p.get("priority"):
            qs = qs.filter(priority=p["priority"])
        if p.get("status"):
            qs = qs.filter(status=p["status"])
        if p.get("industry"):
            qs = qs.filter(industry=p["industry"])
        if p.get("org"):
            qs = qs.filter(org_id=p["org"])
        q = (p.get("q") or "").strip()
        if q:
            from django.db.models import Q
            qs = qs.filter(Q(name__icontains=q) | Q(company__icontains=q) |
                           Q(phone__icontains=q) | Q(email__icontains=q))
        return qs

    def perform_create(self, serializer):
        org = serializer.validated_data.get("org")
        member = _require_member(self.request.user, org)
        # Deterministic routing by industry/size/source (first matching rule).
        assigned = serializer.validated_data.get("assigned_to")
        if not assigned:
            routed, _terr = pl.route_lead(
                org,
                industry=serializer.validated_data.get("industry", "other"),
                source=serializer.validated_data.get("source", "manual"),
                company_size=serializer.validated_data.get("company_size", 0) or 0)
            if routed:
                assigned = routed
        lead = serializer.save(assigned_to=assigned)
        logic.score_lead(lead)

    # ----- predictive follow-up (spec §4) -----
    @action(detail=True, methods=["get"])
    def followup(self, request, pk=None):
        return Response(logic.suggest_followup(self.get_object()))

    # ----- proposal generation (spec §5) — needs-key safe -----
    @action(detail=True, methods=["post"])
    def proposal(self, request, pk=None):
        lead = self.get_object()
        requirements = (request.data.get("requirements") or "")[:4000]
        return Response(logic.generate_proposal(lead, requirements))

    # ----- mark a lead WON: close/create the backing deal (spec §6) -----
    @action(detail=True, methods=["post"])
    def mark_won(self, request, pk=None):
        """Mark the lead won. Closes (or creates) the backing Deal onto the
        pipeline's Won stage so pipeline value / weighted forecast /
        dashboard-won stay correct, sets lead.status=won and writes an audit
        entry — all atomically. The client confirms before calling this; the
        ERP handoff (`onboard`) is a SEPARATE step that runs on an already-won
        lead, so it never causes the win as a side effect."""
        lead = self.get_object()
        member = _member_for(request.user, lead.org_id)
        with transaction.atomic():
            deal = _ensure_deal_for(lead)
            won_stage = deal.pipeline.stages.filter(is_won=True).first()
            if won_stage is None:
                raise ValidationError(
                    {"stage": "Won stage not configured on this pipeline"})
            if deal.state != Deal.WON:
                pl.move_deal(deal, won_stage, member=member,
                             note=(request.data.get("note") or "")[:200])
            if lead.status != "won":
                lead.status = "won"
                lead.save(update_fields=["status", "updated_at"])
            AuditEntry.objects.create(
                org=lead.org, member=member, action="lead.won",
                entity=f"lead#{lead.id}", detail=f"deal#{deal.id}")
        lead.refresh_from_db()
        return Response({"ok": True, "lead": LeadSerializer(lead).data,
                         "deal": DealSerializer(deal).data})

    # ----- mark a lead LOST: mandatory reason recorded on the backing deal -----
    @action(detail=True, methods=["post"])
    def mark_lost(self, request, pk=None):
        """Mark the lead lost. A loss_reason is MANDATORY (CRM_SPEC §6); it is
        recorded on the backing Deal (created on a Lost stage if none exists) so
        reports.win_loss picks it up — not just dropped into free-text notes.
        Writes an audit entry and sets lead.status=lost, atomically."""
        lead = self.get_object()
        member = _member_for(request.user, lead.org_id)
        reason = (request.data.get("loss_reason") or "").strip()
        valid = {code for code, _ in Deal.LOSS_REASONS}
        if reason not in valid:
            raise ValidationError(
                {"loss_reason": "হারানোর কারণ দিন / A valid loss reason is required"})
        note = (request.data.get("loss_note") or "")[:2000]
        competitor = (request.data.get("competitor") or "")[:120]
        with transaction.atomic():
            deal = _ensure_deal_for(lead)
            lost_stage = deal.pipeline.stages.filter(is_lost=True).first()
            if lost_stage is None:
                raise ValidationError(
                    {"stage": "Lost stage not configured on this pipeline"})
            deal.loss_reason = reason
            deal.loss_note = note
            deal.competitor = competitor
            deal.save(update_fields=["loss_reason", "loss_note", "competitor"])
            if deal.state != Deal.LOST:
                pl.move_deal(deal, lost_stage, member=member,
                             note=f"lost: {reason}")
            if lead.status != "lost":
                lead.status = "lost"
                lead.save(update_fields=["status", "updated_at"])
            AuditEntry.objects.create(
                org=lead.org, member=member, action="lead.lost",
                entity=f"lead#{lead.id}", detail=f"{reason} · deal#{deal.id}")
        lead.refresh_from_db()
        return Response({"ok": True, "lead": LeadSerializer(lead).data,
                         "deal": DealSerializer(deal).data})

    # ----- one-click ERP onboarding on Won (spec §6) — needs-integration safe -----
    @action(detail=True, methods=["post"])
    def onboard(self, request, pk=None):
        """ERP handoff for an already-won lead. This is the implementation-team
        handoff, NOT the win itself: if the lead is not yet won we refuse and
        tell the caller to mark it won first (mark_won closes the backing deal).
        Keeping the two separate stops the ERP stub from quietly flipping a
        lead to won and polluting the pipeline/forecast."""
        lead = self.get_object()
        if lead.status != "won":
            return Response({
                "ok": False, "reason": "not_won",
                "message": "আগে Won হিসেবে চিহ্নিত করুন / Mark the lead won first",
            }, status=409)
        return Response(logic.onboard_to_erp(lead))

    # ----- in-app quote builder → create a Proposal from the price book -----
    @action(detail=True, methods=["post"])
    def quote(self, request, pk=None):
        """Build a Proposal from selected price-book products (CRM_SPEC §5 quote
        builder). Amounts come ONLY from the owner-configured price book via
        quoting.make_quote — no price or tax is ever invented. If any selected
        product is not owner-reviewed the resulting proposal is flagged
        prices_reviewed=False ("TO REVIEW BY OWNER") and can't be approved/sent
        until reviewed. selections = [{"sku","qty"}, ...]."""
        lead = self.get_object()
        member = _member_for(request.user, lead.org_id)
        selections = request.data.get("selections") or []
        if not isinstance(selections, list) or not selections:
            raise ValidationError(
                {"selections": "অন্তত একটি প্রোডাক্ট দিন / Select at least one product"})
        # Discount/tax are numeric inputs; tax defaults to 0 (owner must set VAT).
        def _num(key):
            try:
                return float(request.data.get(key) or 0)
            except (TypeError, ValueError):
                return 0
        deal = _backing_deal(lead)
        prop = quoting.make_quote(
            lead, selections,
            requirements=(request.data.get("requirements") or "")[:4000],
            discount_pct=_num("discount_pct"), tax_pct=_num("tax_pct"),
            title=(request.data.get("title") or "")[:200],
            created_by=member, deal=deal)
        AuditEntry.objects.create(
            org=lead.org, member=member, action="proposal.quote",
            entity=f"proposal#{prop.id}", detail=f"lead#{lead.id}")
        return Response(ProposalSerializer(prop).data)

    # ----- full timeline for the detail screen (messages + activities) -----
    @action(detail=True, methods=["get"])
    def timeline(self, request, pk=None):
        lead = self.get_object()
        msgs = Message.objects.filter(conversation__lead=lead).order_by("at")
        acts = Activity.objects.filter(lead=lead).order_by("-created_at")
        conv = lead.conversations.first()
        return Response({
            "ok": True,
            "insight": conv.insight if conv else "",
            "messages": MessageSerializer(msgs, many=True).data,
            "activities": ActivitySerializer(acts, many=True).data,
        })

    # ----- add a message to a lead's conversation (logs + rescores) -----
    @action(detail=True, methods=["post"])
    def message(self, request, pk=None):
        lead = self.get_object()
        text = (request.data.get("text") or "")[:8000]
        direction = request.data.get("direction", Message.IN)
        if direction not in (Message.IN, Message.OUT):
            direction = Message.IN
        conv = lead.conversations.first() or Conversation.objects.create(
            lead=lead, channel=lead.source)
        msg = logic.add_message(conv, direction, text)
        return Response(MessageSerializer(msg).data)

    # ----- quick-action logging (call/WhatsApp/email each become an Activity) -----
    @action(detail=True, methods=["post"])
    def log_action(self, request, pk=None):
        """Log a tap on a quick action (call/whatsapp/email). CRM_SPEC requires
        every quick action to be recorded as a timeline activity."""
        lead = self.get_object()
        member = _member_for(request.user, lead.org_id)
        kind = request.data.get("kind", Activity.CALL)
        if kind not in dict(Activity.KINDS):
            kind = Activity.CALL
        act = Activity.objects.create(
            org=lead.org, kind=kind, lead=lead, actor=member,
            subject=(request.data.get("subject") or "")[:240],
            body=(request.data.get("body") or "")[:4000])
        return Response(ActivitySerializer(act).data)

    # ----- WhatsApp opt-in / service-window status for this lead -----
    @action(detail=True, methods=["get"])
    def whatsapp_status(self, request, pk=None):
        """Honest WhatsApp state for the lead-detail sheet: whether the owner has
        connected the official Cloud API (needs_key), the lead's opt-in flag and
        whether we are inside the 24h free-form window. Drives the UI's gated vs
        send states — never pretends to be live."""
        lead = self.get_object()
        row = _wa_optin(lead)
        now_ts = timezone.now().timestamp()
        last_ts = row.last_inbound_at.timestamp() if row.last_inbound_at else None
        return Response({
            "ok": True,
            "org": lead.org_id,
            "has_key": _wa_has_key(),
            "opted_in": row.opted_in,
            "in_window": wa.within_service_window(last_ts, now_ts),
            "last_inbound_at": row.last_inbound_at,
            "to": _wa_dest(lead),
            "window_hours": wa.SERVICE_WINDOW_HOURS,
        })

    # ----- set the lead's WhatsApp opt-in flag (consent) -----
    @action(detail=True, methods=["post"])
    def whatsapp_optin(self, request, pk=None):
        """Record the lead's WhatsApp consent. Opt-in is REQUIRED before any
        send (1:1 or bulk). Owner/rep sets this from the lead sheet once the lead
        has agreed to be contacted on WhatsApp."""
        lead = self.get_object()
        row = _wa_optin(lead)
        row.opted_in = bool(request.data.get("opted_in", True))
        row.opted_in_at = timezone.now() if row.opted_in else None
        row.save(update_fields=["opted_in", "opted_in_at"])
        return Response({"ok": True, "opted_in": row.opted_in})

    # ----- SEND a WhatsApp message/template from the CRM (MOCK + key-gated) -----
    @action(detail=True, methods=["post"])
    def whatsapp_send(self, request, pk=None):
        """Send a WhatsApp message to the lead via the OFFICIAL Business Cloud
        API — NEVER personal WhatsApp (whatsapp.plan_send guards the channel).

        LIVE SEND IS MOCKED + KEY-GATED: with no Meta key connected we return a
        'needs_key' / drafted state (we never fake a delivery). When the 24h
        service window has lapsed, a free-form text is refused and an approved
        PAID template is required.

        Regardless of live vs mock, the attempt is AUTO-LOGGED onto the lead's
        timeline as a whatsapp Activity (the key value). Body: {text?} for a
        free-form message, or {template_id, params[]} for a template."""
        lead = self.get_object()
        member = _member_for(request.user, lead.org_id)
        row = _wa_optin(lead)
        now_ts = timezone.now().timestamp()
        last_ts = row.last_inbound_at.timestamp() if row.last_inbound_at else None

        text = (request.data.get("text") or "")[:4000]
        template_name = None
        template_body = None
        template_params = request.data.get("params") or []
        tpl_id = request.data.get("template_id")
        if tpl_id:
            tpl = get_object_or_404(WhatsAppTemplate, id=tpl_id, org=lead.org)
            template_name = tpl.meta_name or tpl.name
            template_body = tpl.body
            # An unapproved template can never be sent outside the 24h window.
            if not tpl.approved and not wa.within_service_window(last_ts, now_ts):
                return Response({
                    "ok": False, "state": "template_not_approved",
                    "message": "টেমপ্লেট Meta-তে অনুমোদিত নয় / "
                               "Template is not approved in Meta yet",
                }, status=409)

        try:
            plan = wa.plan_send(
                last_inbound_ts=last_ts, now_ts=now_ts, has_key=_wa_has_key(),
                opted_in=row.opted_in, text=text, template_name=template_name,
                template_body=template_body, template_params=template_params,
                to=_wa_dest(lead))
        except wa.PersonalWhatsAppBanned as e:   # defensive — never reachable
            raise ValidationError({"channel": str(e)})

        if not plan.get("allowed"):
            # opt-out or outside-window-without-template: refuse honestly.
            return Response({"ok": False, "state": plan["state"],
                             "reason": plan.get("reason")}, status=409)

        # AUTO-LOG the outbound on the timeline (mock or live — a real attempt).
        rendered = plan.get("rendered") or ""
        act = _log_wa_activity(lead, member, "out", rendered)
        return Response({
            "ok": True,
            "state": plan["state"],           # 'queued' (key) or 'needs_key'
            "mode": plan["mode"],
            "paid_template": plan["paid_template"],
            "rendered": rendered,
            "activity": ActivitySerializer(act).data,
            # Graph request descriptor the integrator POSTs once the key is live.
            # Returned for transparency; the live POST happens server-side later.
            "send": plan.get("send"),
        })

    # ----- RECEIVE an inbound WhatsApp message (webhook relay) -----
    @action(detail=True, methods=["post"])
    def whatsapp_receive(self, request, pk=None):
        """Record an INBOUND WhatsApp message for the lead (fed by the official
        Cloud API webhook relay). Stamps the 24h window, implies opt-in, and
        AUTO-LOGS the message as a whatsapp Activity + a Conversation Message so
        the reply shows up on the same timeline as outbound sends."""
        lead = self.get_object()
        member = _member_for(request.user, lead.org_id)
        text = (request.data.get("text") or "")[:8000]
        row = _wa_optin(lead)
        with transaction.atomic():
            row.last_inbound_at = timezone.now()
            if not row.opted_in:
                row.opted_in = True       # inbound = implicit consent to reply
                row.opted_in_at = row.last_inbound_at
            row.save(update_fields=["last_inbound_at", "opted_in", "opted_in_at"])
            act = _log_wa_activity(lead, member, "in", text)
            conv = lead.conversations.first() or Conversation.objects.create(
                lead=lead, channel="whatsapp")
            logic.add_message(conv, Message.IN, text)
        return Response({"ok": True, "activity": ActivitySerializer(act).data})


# --------------------------------------------------------------- conversations
class ConversationViewSet(CrmErrorMixin, viewsets.ReadOnlyModelViewSet):
    """Read conversations + messages for the user's orgs (timeline view)."""
    serializer_class = ConversationSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return Conversation.objects.filter(
            lead__org_id__in=_member_org_ids(self.request.user))


# --------------------------------------------------------------- companies / contacts
class CompanyViewSet(_OrgScopedViewSet):
    model = Company
    serializer_class = CompanySerializer


class ContactViewSet(_OrgScopedViewSet):
    model = Contact
    serializer_class = ContactSerializer


# --------------------------------------------------------------- pipelines / stages
class PipelineViewSet(_OrgScopedViewSet):
    model = Pipeline
    serializer_class = PipelineSerializer

    def get_queryset(self):
        qs = super().get_queryset()
        if self.request.query_params.get("org"):
            qs = qs.filter(org_id=self.request.query_params["org"])
        return qs


class StageViewSet(CrmErrorMixin, viewsets.ModelViewSet):
    """Stages are scoped via their pipeline's org."""
    serializer_class = StageSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return Stage.objects.filter(
            pipeline__org_id__in=_member_org_ids(self.request.user))

    def perform_create(self, serializer):
        pipeline = serializer.validated_data.get("pipeline")
        _require_member(self.request.user, pipeline.org_id)
        serializer.save()


# --------------------------------------------------------------- deals (kanban)
class DealViewSet(_OrgScopedViewSet):
    model = Deal
    serializer_class = DealSerializer

    def get_queryset(self):
        qs = super().get_queryset()
        p = self.request.query_params
        if p.get("org"):
            qs = qs.filter(org_id=p["org"])
        if p.get("pipeline"):
            qs = qs.filter(pipeline_id=p["pipeline"])
        if p.get("state"):
            qs = qs.filter(state=p["state"])
        return qs

    # ----- drag a deal to a new stage (kanban) -----
    @action(detail=True, methods=["post"])
    def move(self, request, pk=None):
        """Move a deal to another stage. On a Lost stage a loss_reason is
        MANDATORY (CRM_SPEC §6); we refuse the move without one."""
        deal = self.get_object()
        member = _member_for(request.user, deal.org_id)
        stage_id = request.data.get("stage")
        stage = get_object_or_404(Stage, id=stage_id, pipeline=deal.pipeline)
        if stage.is_lost:
            reason = request.data.get("loss_reason")
            if not reason:
                raise ValidationError(
                    {"loss_reason": "হারানোর কারণ দিন / A loss reason is required"})
            deal.loss_reason = reason
            deal.loss_note = (request.data.get("loss_note") or "")[:2000]
            deal.competitor = (request.data.get("competitor") or "")[:120]
            deal.save(update_fields=["loss_reason", "loss_note", "competitor"])
        pl.move_deal(deal, stage, member=member,
                     note=(request.data.get("note") or "")[:200])
        deal.refresh_from_db()
        return Response(DealSerializer(deal).data)

    # ----- set/clear the mandatory next step -----
    @action(detail=True, methods=["post"])
    def set_next_step(self, request, pk=None):
        deal = self.get_object()
        deal.next_step = (request.data.get("next_step") or "")[:240]
        due = request.data.get("next_step_due")
        deal.next_step_due = due or None
        deal.save(update_fields=["next_step", "next_step_due", "updated_at"])
        return Response(DealSerializer(deal).data)

    # ----- stuck-deal warnings for this org -----
    @action(detail=False, methods=["get"])
    def stuck(self, request):
        org_id = request.query_params.get("org")
        _require_member(request.user, org_id)
        return Response({"ok": True,
                         "stuck": pl.stuck_deals(Deal.objects.filter(org_id=org_id))})


# --------------------------------------------------------------- activities (timeline)
class ActivityViewSet(_OrgScopedViewSet):
    model = Activity
    serializer_class = ActivitySerializer

    def get_queryset(self):
        qs = super().get_queryset()
        p = self.request.query_params
        if p.get("org"):
            qs = qs.filter(org_id=p["org"])
        if p.get("lead"):
            qs = qs.filter(lead_id=p["lead"])
        if p.get("deal"):
            qs = qs.filter(deal_id=p["deal"])
        if p.get("open_tasks"):
            qs = qs.filter(kind=Activity.TASK, done=False)
        return qs

    def perform_create(self, serializer):
        org = serializer.validated_data.get("org")
        member = _require_member(self.request.user, org)
        serializer.save(actor=member)

    @action(detail=True, methods=["post"])
    def complete(self, request, pk=None):
        act = self.get_object()
        act.done = True
        act.done_at = timezone.now()
        act.save(update_fields=["done", "done_at"])
        return Response(ActivitySerializer(act).data)


# --------------------------------------------------------------- team / routing
class MemberViewSet(CrmErrorMixin, viewsets.ModelViewSet):
    """Team roster. Only owners/managers may add or change members; everyone in
    the org can read it (to pick an assignee)."""
    serializer_class = CrmMemberSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = CrmMember.objects.filter(
            org_id__in=_member_org_ids(self.request.user)).select_related("user")
        if self.request.query_params.get("org"):
            qs = qs.filter(org_id=self.request.query_params["org"])
        return qs

    def perform_create(self, serializer):
        org = serializer.validated_data.get("org")
        member = _require_member(self.request.user, org)
        if not _can_manage(member):
            raise PermissionDenied("শুধু owner/manager টিম এডিট করতে পারেন / "
                                   "Only owner/manager can edit the team")
        serializer.save()


class RoutingRuleViewSet(_OrgScopedViewSet):
    model = RoutingRule
    serializer_class = RoutingRuleSerializer

    def perform_create(self, serializer):
        org = serializer.validated_data.get("org")
        member = _require_member(self.request.user, org)
        if not _can_manage(member):
            raise PermissionDenied("শুধু owner/manager রাউটিং এডিট করতে পারেন / "
                                   "Only owner/manager can edit routing")
        serializer.save()


class TerritoryViewSet(_OrgScopedViewSet):
    model = Territory
    serializer_class = TerritorySerializer


# --------------------------------------------------------------- price book
class ProductViewSet(_OrgScopedViewSet):
    model = Product
    serializer_class = ProductSerializer

    def get_queryset(self):
        qs = super().get_queryset()
        if self.request.query_params.get("org"):
            qs = qs.filter(org_id=self.request.query_params["org"])
        return qs


# --------------------------------------------------------------- WhatsApp templates
class WhatsAppTemplateViewSet(_OrgScopedViewSet):
    """Owner-defined WhatsApp message templates (list + create + use). `body` is
    text the OWNER wrote — the CRM never invents template content. Templates are
    referenced by id from lead.whatsapp_send and the bulk-send endpoint."""
    model = WhatsAppTemplate
    serializer_class = WhatsAppTemplateSerializer

    def get_queryset(self):
        qs = super().get_queryset()
        if self.request.query_params.get("org"):
            qs = qs.filter(org_id=self.request.query_params["org"])
        if self.request.query_params.get("active"):
            qs = qs.filter(active=True)
        return qs


# --------------------------------------------------------------- WhatsApp bulk send
class WhatsAppBulkSendView(CrmErrorMixin, APIView):
    """Opt-in bulk WhatsApp send to a FILTERED lead set (CRM_SPEC §5).

    POST {org, template_id?, text?, params[]?, lead_ids[]? | filters} →

      * Respects the OPT-IN flag: leads that haven't opted in are skipped.
      * Respects the 24h service window + paid-template rule: outside the window
        a free-form text is refused per-lead; an approved template is required.
      * FANS OUT TO INDIVIDUAL 1:1 SENDS — never a WhatsApp group (ToS + spec).
      * MOCK + key-gated: with no Meta key every send is 'needs_key' (drafted),
        never a faked delivery. Each allowed attempt is AUTO-LOGGED as a
        whatsapp Activity on that lead's timeline.

    Official WhatsApp Business Cloud API ONLY (whatsapp.plan_send guards the
    channel; personal WhatsApp is refused)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        org_id = request.data.get("org")
        member = _require_member(request.user, org_id)
        if not _can_manage(member):
            raise PermissionDenied("শুধু owner/manager বাল্ক পাঠাতে পারেন / "
                                   "Only owner/manager can bulk-send")

        # Resolve the filtered lead set (explicit ids OR status/priority filter).
        qs = Lead.objects.filter(org_id=org_id).exclude(
            status__in=["won", "lost"])
        ids = request.data.get("lead_ids")
        if isinstance(ids, list) and ids:
            qs = qs.filter(id__in=ids)
        else:
            if request.data.get("status"):
                qs = qs.filter(status=request.data["status"])
            if request.data.get("priority"):
                qs = qs.filter(priority=request.data["priority"])
            if request.data.get("industry"):
                qs = qs.filter(industry=request.data["industry"])
        leads = list(qs[:500])   # hard cap — a bulk send is not unbounded

        template_name = None
        template_body = None
        tpl_id = request.data.get("template_id")
        if tpl_id:
            tpl = get_object_or_404(WhatsAppTemplate, id=tpl_id, org_id=org_id)
            template_name = tpl.meta_name or tpl.name
            template_body = tpl.body

        now_ts = timezone.now().timestamp()
        has_key = _wa_has_key()
        text = (request.data.get("text") or "")[:4000]
        params = request.data.get("params") or []

        rows = []
        for lead in leads:
            row = _wa_optin(lead)
            last_ts = (row.last_inbound_at.timestamp()
                       if row.last_inbound_at else None)
            rows.append({"id": lead.id, "to": _wa_dest(lead),
                         "opted_in": row.opted_in, "last_inbound_ts": last_ts,
                         "_lead": lead})

        plan = wa.bulk_fanout_plan(
            leads=[{k: v for k, v in r.items() if k != "_lead"} for r in rows],
            now_ts=now_ts, has_key=has_key, template_name=template_name,
            template_body=template_body, template_params=params, text=text)

        # AUTO-LOG each allowed (queued/needs_key) attempt on its timeline.
        by_id = {r["id"]: r["_lead"] for r in rows}
        for res in plan["results"]:
            if res["allowed"] and res["state"] in ("queued", "needs_key"):
                _log_wa_activity(by_id[res["lead"]], member, "out",
                                 res.get("rendered") or "")
        return Response(plan)


# --------------------------------------------------------------- proposals
class ProposalViewSet(CrmErrorMixin, viewsets.ReadOnlyModelViewSet):
    serializer_class = ProposalSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = Proposal.objects.filter(
            lead__org_id__in=_member_org_ids(self.request.user))
        if self.request.query_params.get("lead"):
            qs = qs.filter(lead_id=self.request.query_params["lead"])
        return qs

    # ----- approval workflow transitions (CRM_SPEC §Proposal) -----
    @action(detail=True, methods=["post"])
    def transition(self, request, pk=None):
        """Move a proposal through its status workflow. Sending is only allowed
        after approval; approval is gated on prices being owner-reviewed, so an
        unreviewed price book can never be sent to a buyer."""
        prop = self.get_object()
        member = _member_for(request.user, prop.lead.org_id)
        to = request.data.get("to")
        now = timezone.now()
        if to == Proposal.APPROVED:
            if not _can_manage(member):
                raise PermissionDenied("শুধু owner/manager অনুমোদন করতে পারেন / "
                                       "Only owner/manager can approve")
            if not prop.prices_reviewed:
                raise ValidationError({"prices_reviewed":
                    "দাম পর্যালোচনা বাকি / Prices must be reviewed by owner first"})
            prop.status = Proposal.APPROVED
            prop.approved_by = member
            prop.approved_at = now
        elif to == Proposal.SENT:
            if prop.status != Proposal.APPROVED:
                raise ValidationError({"status":
                    "পাঠানোর আগে অনুমোদন দরকার / Approve before sending"})
            prop.status = Proposal.SENT
            prop.sent_at = now
        elif to == Proposal.VIEWED:
            prop.status = Proposal.VIEWED
            prop.viewed_at = now
        elif to == Proposal.ACCEPTED:
            prop.status = Proposal.ACCEPTED
            prop.accepted_at = now
        elif to == Proposal.DECLINED:
            prop.status = Proposal.DECLINED
        else:
            raise ValidationError({"to": "অজানা স্ট্যাটাস / Unknown status"})
        prop.save()
        AuditEntry.objects.create(
            org=prop.lead.org, member=member, action=f"proposal.{to}",
            entity=f"proposal#{prop.id}")
        return Response(ProposalSerializer(prop).data)


# --------------------------------------------------------------- capture webhook
class CaptureWebhookView(CrmErrorMixin, APIView):
    """Omnichannel capture endpoint (spec §1). Gated on the WhatsApp/Messenger
    integration: if not connected, returns a clean needs-key state instead of
    accepting data — so the feature never pretends to be live."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        try:
            from core import integrations
            connected = integrations.is_enabled("whatsapp")
        except Exception:
            connected = False
        if not connected:
            return Response({
                "ok": False, "needs_key": True, "reason": "no_key",
                "message": "চালু হবে যখন WhatsApp যোগ হবে / "
                           "Available when WhatsApp is connected",
            })

        org_id = request.data.get("org")
        member = _member_for(request.user, org_id)
        if not member:
            return Response({"ok": False, "reason": "forbidden",
                             "message": "Not a member of this org"}, status=403)
        org = get_object_or_404(CrmOrg, id=org_id)

        lead = logic.capture_lead(
            org=org,
            source=request.data.get("source", "whatsapp"),
            contact={"phone": request.data.get("phone", ""),
                     "email": request.data.get("email", "")},
            first_message=(request.data.get("message") or "")[:8000],
            name=request.data.get("name", ""),
            company=request.data.get("company", ""),
            industry=request.data.get("industry", "other"),
            company_size=int(request.data.get("company_size") or 0),
        )
        return Response({"ok": True, "lead": LeadSerializer(lead).data})


# --------------------------------------------------------------- paste extractor
_PHONE_RE = re.compile(r"(?:\+?88)?0?1[3-9]\d{8}")        # BD mobile
_PHONE_ANY_RE = re.compile(r"\+?\d[\d\s\-()]{7,}\d")      # generic fallback
_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
_COMPANY_HINT = re.compile(
    r"([A-Z][A-Za-z0-9&.\- ]{1,60}?(?:\s(?:Ltd|Limited|Inc|LLC|Group|Industries|"
    r"Garments|Pharma|Pharmaceuticals|Textiles|Corporation|Corp|Co|Company|"
    r"Enterprise|Trading|Fashions|Apparels)))", re.MULTILINE)


class PasteExtractView(CrmErrorMixin, APIView):
    """Rule-based paste extraction (CRM_SPEC: RICH MANUAL ENTRY without AI).

    POST {text} → best-effort {phone, phones, email, company, name} guesses,
    pulled deterministically from pasted chat / LinkedIn text / business-card
    OCR text. NO AI, NO scraping, NO automation — the user still completes the
    form by hand; this just saves re-typing. Returns `ai_available` so the app
    can offer the richer AI auto-fill when a key is present.
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        text = (request.data.get("text") or "")[:8000]

        phones = []
        for m in _PHONE_RE.findall(text):
            digits = re.sub(r"\D", "", m)
            tail = digits[-11:]
            if tail not in phones:
                phones.append(tail)
        if not phones:
            for m in _PHONE_ANY_RE.findall(text):
                digits = re.sub(r"\D", "", m)
                if len(digits) >= 9 and digits not in phones:
                    phones.append(digits)

        emails = _EMAIL_RE.findall(text)
        company = ""
        cm = _COMPANY_HINT.search(text)
        if cm:
            company = cm.group(1).strip()

        # Name heuristic: first non-empty line that is short, has no digits/@,
        # and looks like a person's name (1–4 words). Honest best-effort only.
        name = ""
        for raw in text.splitlines():
            line = raw.strip()
            if not line or "@" in line or any(c.isdigit() for c in line):
                continue
            words = line.split()
            if 1 <= len(words) <= 4 and len(line) <= 48:
                name = line
                break

        try:
            from core import ai
            ai_available = ai.available()
        except Exception:
            ai_available = False

        return Response({
            "ok": True,
            "ai_available": ai_available,
            "phone": phones[0] if phones else "",
            "phones": phones[1:],
            "whatsapp": phones[0] if phones else "",
            "email": emails[0] if emails else "",
            "company": company,
            "name": name,
            "note_bn": ("স্বয়ংক্রিয় পূরণ AI key যোগ হলে চালু হবে — এখন শুধু "
                        "ফোন/ইমেইল/কোম্পানি বের করা হলো"),
            "note_en": ("AI auto-fill available when a key is added — for now "
                        "we only extracted phone/email/company"),
        })


# --------------------------------------------------------------- Today feed
class TodayView(CrmErrorMixin, APIView):
    """CRM_SPEC Today screen aggregation: follow-ups due/overdue, new high-score
    (90+) leads, stuck deals and suggested drafts — all from REAL data, scoped
    to the caller's org."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        org_id = request.query_params.get("org")
        member = _member_for(request.user, org_id)
        if not member:
            return Response({"ok": False, "reason": "forbidden",
                             "message": "Not a member of this org"}, status=403)

        org = get_object_or_404(CrmOrg, id=org_id)
        leads = Lead.objects.filter(org_id=org_id)
        deals = Deal.objects.filter(org_id=org_id)
        today = timezone.now().date()

        # Person-centric Today for a sales rep: only their own leads/deals.
        # Owners and managers keep the org-wide view (spec §Today).
        if member.role == CrmMember.SALES:
            leads = leads.filter(assigned_to=member)
            deals = deals.filter(owner=member)

        # New high-score (90+) open leads — the ones to call first.
        high = leads.filter(score__gte=90).exclude(
            status__in=["won", "lost"]).order_by("-score")[:25]

        # Follow-ups: lead.next_follow_up due/overdue + deal cadence engine.
        lead_followups = list(leads.filter(
            next_follow_up__isnull=False,
            next_follow_up__lte=today).exclude(
            status__in=["won", "lost"]).order_by("next_follow_up")
            .values("id", "name", "company", "next_follow_up", "priority"))
        fu = cadence.due_followups(org, deals)

        stuck = pl.stuck_deals(deals)

        return Response({
            "ok": True,
            "high_score_leads": LeadSerializer(high, many=True).data,
            "lead_followups": lead_followups,
            "overdue_next_steps": fu["overdue_next_steps"],
            "missing_next_step": fu["missing_next_step"],
            "due_tasks": fu["due_tasks"],
            "stuck_deals": stuck,
        })


# --------------------------------------------------------------- dashboard
class DashboardView(CrmErrorMixin, APIView):
    """Management view (spec §Dashboard): status counts, high-priority leads, an
    HONEST weighted forecast (from real open deals) and win/loss + by-industry +
    by-salesperson reports. Thin data returns a clear "not enough data" state.

    ROLE GATE: the dashboard is the MANAGEMENT financial view — pipeline value,
    weighted forecast, won value, per-rep performance. A plain salesperson can
    SELL but must not see the team's money/forecast: for a SALES member we
    return a clean `restricted` state (NOT an error) instead of the financials,
    so their client shows a friendly "ask your manager" panel rather than a
    broken screen."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        org_id = request.query_params.get("org")
        member = _member_for(request.user, org_id)
        if not member:
            return Response({"ok": False, "reason": "forbidden",
                             "message": "Not a member of this org"}, status=403)

        # Salesperson: no profit/forecast/cost. Honest restricted payload.
        if member.role == CrmMember.SALES:
            return Response({
                "ok": True, "restricted": True,
                "message_bn": "ড্যাশবোর্ডের আর্থিক তথ্য শুধু owner/manager দেখতে পারেন",
                "message_en": "Financial dashboard is visible to owners and "
                              "managers only",
            })

        org = get_object_or_404(CrmOrg, id=org_id)
        leads = Lead.objects.filter(org_id=org_id)
        deals = Deal.objects.filter(org_id=org_id)

        counts = {k: 0 for k, _ in Lead.STATUSES}
        for row in leads.values("status").annotate(n=Count("id")):
            counts[row["status"]] = row["n"]

        high = leads.filter(priority=Lead.HIGH).exclude(
            status__in=["won", "lost"]).order_by("-score")[:25]

        # Pipeline value + honest weighted forecast (method shown).
        open_deals = deals.filter(state="open")
        pipeline_value = float(open_deals.aggregate(s=Sum("value"))["s"] or 0)
        forecast = fc.weighted_forecast(deals)

        won_month = float(deals.filter(state="won").aggregate(
            s=Sum("value"))["s"] or 0)

        return Response({
            "ok": True,
            "status_counts": counts,
            "pipeline_value": pipeline_value,
            "won_value": won_month,
            "high_priority_leads": LeadSerializer(high, many=True).data,
            "forecast": forecast,
            "win_loss": rp.win_loss(deals),
            "by_industry": rp.pipeline_by_industry(deals),
            "by_salesperson": rp.rep_performance(org, deals),
        })
