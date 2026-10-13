"""
CRM DRF views. All access is multi-tenant and member-gated: a request only ever
sees orgs the user belongs to (via CrmMember). The capture webhook degrades to a
needs-key state when WhatsApp isn't connected; the dashboard forecast is an
honest estimate computed from REAL pipeline data (never fabricated).
"""
from django.db.models import Count
from django.shortcuts import get_object_or_404
from rest_framework import viewsets
from rest_framework.decorators import action
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import logic
from .models import CrmOrg, CrmMember, Lead, Conversation, Message, Proposal
from .serializers import (CrmOrgSerializer, LeadSerializer,
                          ConversationSerializer, MessageSerializer,
                          ProposalSerializer)


# --------------------------------------------------------------- helpers
def _member_org_ids(user):
    """Org ids the user can access (member of). Empty → sees nothing."""
    return list(CrmMember.objects.filter(user=user).values_list("org_id", flat=True))


def _member_for(user, org_id):
    return CrmMember.objects.filter(user=user, org_id=org_id).first()


def _can_manage(member):
    """Owners/managers can route and reassign; sales can act on own leads."""
    return bool(member and member.role in (CrmMember.OWNER, CrmMember.MANAGER))


# --------------------------------------------------------------- orgs
class CrmOrgViewSet(viewsets.ModelViewSet):
    """Create/list the sales orgs (tenants) the user belongs to. Creating an org
    seeds the creator as its owner member."""
    serializer_class = CrmOrgSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return CrmOrg.objects.filter(id__in=_member_org_ids(self.request.user))

    def perform_create(self, serializer):
        org = serializer.save(owner=self.request.user)
        CrmMember.objects.get_or_create(
            org=org, user=self.request.user,
            defaults={"role": CrmMember.OWNER})


# --------------------------------------------------------------- leads
class LeadViewSet(viewsets.ModelViewSet):
    """CRUD for leads, scoped to the user's orgs. Supports ?priority= and
    ?status= and ?org= filters. Score/priority stay server-computed."""
    serializer_class = LeadSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        qs = Lead.objects.filter(org_id__in=_member_org_ids(self.request.user))
        priority = self.request.query_params.get("priority")
        status_f = self.request.query_params.get("status")
        org = self.request.query_params.get("org")
        if priority:
            qs = qs.filter(priority=priority)
        if status_f:
            qs = qs.filter(status=status_f)
        if org:
            qs = qs.filter(org_id=org)
        return qs

    def perform_create(self, serializer):
        org = serializer.validated_data.get("org")
        member = _member_for(self.request.user, org.id if org else None)
        if not member:
            from rest_framework.exceptions import PermissionDenied
            raise PermissionDenied("আপনি এই org-এর সদস্য নন / Not a member of this org")
        lead = serializer.save()
        # Score any text captured at creation time (manual leads usually none).
        logic.score_lead(lead)

    # ----- predictive follow-up (spec §4) -----
    @action(detail=True, methods=["get"])
    def followup(self, request, pk=None):
        lead = self.get_object()
        return Response(logic.suggest_followup(lead))

    # ----- proposal generation (spec §5) — needs-key safe -----
    @action(detail=True, methods=["post"])
    def proposal(self, request, pk=None):
        lead = self.get_object()
        requirements = (request.data.get("requirements") or "")[:4000]
        return Response(logic.generate_proposal(lead, requirements))

    # ----- one-click ERP onboarding (spec §6) — needs-integration safe -----
    @action(detail=True, methods=["post"])
    def onboard(self, request, pk=None):
        lead = self.get_object()
        if lead.status != "won":
            lead.status = "won"
            lead.save(update_fields=["status", "updated_at"])
        return Response(logic.onboard_to_erp(lead))

    # ----- add a message to a lead's conversation -----
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


# --------------------------------------------------------------- conversations
class ConversationViewSet(viewsets.ReadOnlyModelViewSet):
    """Read conversations + messages for the user's orgs (timeline view)."""
    serializer_class = ConversationSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return Conversation.objects.filter(
            lead__org_id__in=_member_org_ids(self.request.user))


class ProposalViewSet(viewsets.ReadOnlyModelViewSet):
    serializer_class = ProposalSerializer
    permission_classes = [IsAuthenticated]

    def get_queryset(self):
        return Proposal.objects.filter(
            lead__org_id__in=_member_org_ids(self.request.user))


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


# --------------------------------------------------------------- dashboard
class DashboardView(APIView):
    """Management view (spec §Dashboard): status counts, high-priority leads and
    an HONEST predictive forecast computed from real pipeline data.

    The forecast is explicitly labelled as an estimate derived from the org's
    own high-score leads — it never fabricates a probability out of thin air.
    """
    permission_classes = [IsAuthenticated]

    def get(self, request):
        org_id = request.query_params.get("org")
        member = _member_for(request.user, org_id)
        if not member:
            return Response({"ok": False, "reason": "forbidden",
                             "message": "Not a member of this org"}, status=403)

        leads = Lead.objects.filter(org_id=org_id)

        # Status counts (real).
        counts = {k: 0 for k, _ in Lead.STATUSES}
        for row in leads.values("status").annotate(n=Count("id")):
            counts[row["status"]] = row["n"]

        high = leads.filter(priority=Lead.HIGH).exclude(
            status__in=["won", "lost"]).order_by("-score")[:25]

        forecast = self._forecast(leads)

        return Response({
            "ok": True,
            "status_counts": counts,
            "high_priority_leads": LeadSerializer(high, many=True).data,
            "forecast": forecast,
        })

    @staticmethod
    def _forecast(leads):
        """Honest, data-grounded 30-day close estimate.

        Method (transparent, not a black box): take OPEN high-priority leads
        (score ≥ 90, not won/lost). Estimate expected closes as the sum of each
        lead's score/100 (a lead scoring 95 contributes a 0.95 expectation).
        This is clearly a heuristic ESTIMATE from the org's own pipeline — we do
        not invent a percentage. If there are no qualifying leads, we say so.
        """
        open_high = list(leads.filter(priority=Lead.HIGH)
                         .exclude(status__in=["won", "lost"]))
        n = len(open_high)
        if n == 0:
            return {
                "estimated_closes_30d": 0,
                "basis_leads": 0,
                "is_estimate": True,
                "message": "এই মুহূর্তে কোনো হাই-স্কোর ওপেন লিড নেই — পূর্বাভাস দেওয়া "
                           "যাচ্ছে না / No open high-score leads to forecast from yet.",
            }
        expected = round(sum(l.score for l in open_high) / 100.0, 1)
        return {
            "estimated_closes_30d": expected,
            "basis_leads": n,
            "is_estimate": True,
            "method": "sum(lead.score/100) over open high-priority leads",
            "message": (f"আনুমানিক: আগামী ৩০ দিনে ~{expected}টি হাই-স্কোর ডিল ক্লোজ "
                        f"হতে পারে ({n}টি ওপেন হাই-প্রায়োরিটি লিডের ভিত্তিতে)। "
                        f"Estimate only, from real pipeline data."),
        }
