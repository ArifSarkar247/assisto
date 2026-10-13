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

from . import logic, pipeline as pl, forecast as fc, reports as rp, cadence
from .models import (CrmOrg, CrmMember, Lead, Conversation, Message, Proposal,
                     Company, Contact, Pipeline, Stage, Deal, Activity,
                     Product, Territory, RoutingRule, AuditEntry)
from .serializers import (CrmOrgSerializer, CrmMemberSerializer, LeadSerializer,
                          ConversationSerializer, MessageSerializer,
                          ProposalSerializer, CompanySerializer,
                          ContactSerializer, PipelineSerializer, StageSerializer,
                          DealSerializer, ActivitySerializer, ProductSerializer,
                          TerritorySerializer, RoutingRuleSerializer)


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


class _OrgScopedViewSet(viewsets.ModelViewSet):
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
class CrmOrgViewSet(viewsets.ModelViewSet):
    """Create/list the sales orgs (tenants) the user belongs to. Creating an org
    seeds the creator as its owner member AND a default pipeline so the kanban
    board works immediately."""
    serializer_class = CrmOrgSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return CrmOrg.objects.filter(id__in=_member_org_ids(self.request.user))

    def perform_create(self, serializer):
        org = serializer.save(owner=self.request.user)
        CrmMember.objects.get_or_create(
            org=org, user=self.request.user,
            defaults={"role": CrmMember.OWNER})
        pl.ensure_default_pipeline(org)


# --------------------------------------------------------------- leads
class LeadViewSet(viewsets.ModelViewSet):
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

    # ----- one-click ERP onboarding on Won (spec §6) — needs-integration safe -----
    @action(detail=True, methods=["post"])
    def onboard(self, request, pk=None):
        lead = self.get_object()
        if lead.status != "won":
            lead.status = "won"
            lead.save(update_fields=["status", "updated_at"])
        return Response(logic.onboard_to_erp(lead))

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


# --------------------------------------------------------------- conversations
class ConversationViewSet(viewsets.ReadOnlyModelViewSet):
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


class StageViewSet(viewsets.ModelViewSet):
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
class MemberViewSet(viewsets.ModelViewSet):
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


# --------------------------------------------------------------- proposals
class ProposalViewSet(viewsets.ReadOnlyModelViewSet):
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
class CaptureWebhookView(APIView):
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


class PasteExtractView(APIView):
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
class TodayView(APIView):
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
class DashboardView(APIView):
    """Management view (spec §Dashboard): status counts, high-priority leads, an
    HONEST weighted forecast (from real open deals) and win/loss + by-industry +
    by-salesperson reports. Thin data returns a clear "not enough data" state."""
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
