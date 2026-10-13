"""
CRM URL patterns. DEFINED ONLY — not included anywhere. Wire it later from the
root urls.py, e.g.:  path("api/crm/", include("crm.urls"))
"""
from django.urls import path
from rest_framework.routers import DefaultRouter

from . import views

router = DefaultRouter()
router.register("orgs", views.CrmOrgViewSet, basename="crm-org")
router.register("leads", views.LeadViewSet, basename="crm-lead")
router.register("conversations", views.ConversationViewSet, basename="crm-conversation")
router.register("proposals", views.ProposalViewSet, basename="crm-proposal")

urlpatterns = [
    # Omnichannel capture webhook (gated on WhatsApp integration).
    path("capture", views.CaptureWebhookView.as_view()),
    # Management dashboard (?org=<id>): status counts + high-priority + forecast.
    path("dashboard", views.DashboardView.as_view()),
]

urlpatterns += router.urls
