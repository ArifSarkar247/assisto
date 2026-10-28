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
router.register("wa-templates", views.WhatsAppTemplateViewSet,
                basename="crm-wa-template")
# Company 360: tags + custom-field definitions (now served).
router.register("tags", views.TagViewSet, basename="crm-tag")
router.register("tagged-items", views.TaggedItemViewSet, basename="crm-tagged")
router.register("custom-fields", views.CustomFieldDefViewSet,
                basename="crm-customfield")
# After-sale (§7): orders, installments, AMC, complaints.
router.register("orders", views.OrderViewSet, basename="crm-order")
router.register("installments", views.InstallmentViewSet,
                basename="crm-installment")
router.register("amcs", views.AMCViewSet, basename="crm-amc")
router.register("complaints", views.ComplaintViewSet, basename="crm-complaint")
# Team (#8): targets. Automation (#11): rules.
router.register("targets", views.TargetViewSet, basename="crm-target")
router.register("automation-rules", views.AutomationRuleViewSet,
                basename="crm-automation")

from . import views_crm100 as v100

urlpatterns = [
    # ---- crm100: one customer history page, shop quotes, send from CRM ----
    path("customers/", v100.CustomerListView.as_view()),
    path("customers/history/", v100.CustomerHistoryView.as_view()),
    path("shop-quotes/", v100.ShopQuoteListView.as_view()),
    path("shop-quotes/catalog/", v100.ShopQuoteCatalogView.as_view()),
    path("shop-quotes/<int:pk>/", v100.ShopQuoteDetailView.as_view()),
    path("shop-quotes/<int:pk>/<str:op>/", v100.ShopQuoteDetailView.as_view()),
    path("send/preview", v100.SendPreviewView.as_view()),
    path("send/log", v100.SendLogView.as_view()),
    path("send/sms", v100.SendSmsView.as_view()),
    path("send/bulk", v100.SendBulkView.as_view()),
    # ---- advanced quotes (§6): public tokenized acceptance page (session-less).
    path("accept/<str:token>/", views.QuoteAcceptView.as_view()),
    # ---- after-sale (§7) aggregation endpoints ----
    path("collections/summary", views.CollectionSummaryView.as_view()),
    path("upsell", views.UpsellView.as_view()),
    path("deals/<int:deal>/erp_handoff/", views.ErpHandoffView.as_view()),
    path("deals/<int:deal>/erp_handoff/transition/",
         views.ErpHandoffView.as_view()),
    # ---- team (#8) ----
    path("leaderboard/", views.LeaderboardView.as_view()),
    path("commission-config/", views.CommissionConfigView.as_view()),
    # ---- automation (#11) evaluator ----
    path("automation-rules/evaluate/", views.AutomationEvaluateView.as_view()),
    # ---- capture / dedupe (#1) ----
    path("capture/card", views.CaptureCardView.as_view()),
    path("capture/form", views.CaptureFormView.as_view()),
    path("capture/duplicates/", views.CaptureDuplicatesView.as_view()),
    path("capture/merge_preview", views.CaptureMergePreviewView.as_view()),
    path("capture/merge", views.CaptureMergeView.as_view()),
    # Opt-in bulk WhatsApp send to a filtered lead set (official Cloud API only,
    # MOCK + key-gated, fans out to individual 1:1 sends — never a group).
    path("whatsapp/bulk", views.WhatsAppBulkSendView.as_view()),
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
