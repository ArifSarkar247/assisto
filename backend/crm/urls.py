"""
CRM URL patterns. DEFINED ONLY — not included anywhere. Wire it later from the
root urls.py, e.g.:  path("api/crm/", include("crm.urls"))

This is the JSON API that backs the whole IN-APP Flutter CRM module. The web
layer (weburls.py / webviews.py) is a separate, unlinked surface — do not mix.
"""
from django.urls import path
from rest_framework.routers import DefaultRouter

from . import views

router = DefaultRouter()
router.register("orgs", views.CrmOrgViewSet, basename="crm-org")
router.register("leads", views.LeadViewSet, basename="crm-lead")
router.register("conversations", views.ConversationViewSet, basename="crm-conversation")
router.register("proposals", views.ProposalViewSet, basename="crm-proposal")
router.register("companies", views.CompanyViewSet, basename="crm-company")
router.register("contacts", views.ContactViewSet, basename="crm-contact")
router.register("pipelines", views.PipelineViewSet, basename="crm-pipeline")
router.register("stages", views.StageViewSet, basename="crm-stage")
router.register("deals", views.DealViewSet, basename="crm-deal")
router.register("activities", views.ActivityViewSet, basename="crm-activity")
router.register("members", views.MemberViewSet, basename="crm-member")
router.register("routing-rules", views.RoutingRuleViewSet, basename="crm-routing")
router.register("territories", views.TerritoryViewSet, basename="crm-territory")
router.register("products", views.ProductViewSet, basename="crm-product")

urlpatterns = [
    # Omnichannel capture webhook (gated on WhatsApp integration).
    path("capture", views.CaptureWebhookView.as_view()),
    # Rule-based paste extraction (no AI/scraping): POST {text} → field guesses.
    path("extract", views.PasteExtractView.as_view()),
    # FIRST-RUN "Join a team": POST {code} → join an existing org as a member.
    path("join", views.JoinOrgView.as_view()),
    # Today screen feed (?org=<id>): follow-ups, new 90+ leads, stuck deals.
    path("today", views.TodayView.as_view()),
    # Management dashboard (?org=<id>): counts + forecast + reports.
    path("dashboard", views.DashboardView.as_view()),
]

urlpatterns += router.urls
