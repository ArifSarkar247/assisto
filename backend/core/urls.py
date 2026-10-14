from django.urls import path
from rest_framework.routers import DefaultRouter

from . import views
from . import views_module5 as m5
from . import views_build61 as b61
from . import views_m2 as m2
from . import business_views as bz

router = DefaultRouter()
router.register("memory", views.MemoryViewSet, basename="memory")
router.register("reminders", views.ReminderViewSet, basename="reminder")
router.register("notes", views.NoteViewSet, basename="note")
router.register("todos", views.TodoViewSet, basename="todo")
router.register("support", views.SupportViewSet, basename="support")
router.register("documents", views.DocumentViewSet, basename="document")
router.register("accounts", views.AccountViewSet, basename="account")
router.register("transactions", views.TransactionViewSet, basename="transaction")
router.register("budgets", views.BudgetViewSet, basename="budget")
router.register("loans", views.LoanViewSet, basename="loan")
router.register("goals", views.SavingsGoalViewSet, basename="goal")
router.register("subscriptions", views.SubscriptionViewSet, basename="subscription")
router.register("family", views.FamilyMemberViewSet, basename="family")
router.register("medicines", views.MedicineViewSet, basename="medicine")
router.register("doctors", views.DoctorViewSet, basename="doctor")
router.register("prescriptions", views.PrescriptionViewSet, basename="prescription")
router.register("school", views.SchoolItemViewSet, basename="school")
router.register("watchers", views.WatcherViewSet, basename="watcher")
router.register("contacts", views.ContactViewSet, basename="contact")
router.register("meetings", views.MeetingViewSet, basename="meeting")
router.register("autopay", views.AutoPayRuleViewSet, basename="autopay")
router.register("products", views.ProductViewSet, basename="product")
router.register("orders", views.OrderViewSet, basename="order")
router.register("nominees", views.NomineeViewSet, basename="nominee")
router.register("jobs", views.JobViewSet, basename="job")

urlpatterns = [
    path("health", views.health),
    path("version", views.version),
    path("app/latest", views.app_latest),
    path("ai/status", views.ai_status),

    path("auth/register", views.RegisterView.as_view()),
    path("auth/login", views.LoginView.as_view()),
    path("auth/logout", views.LogoutView.as_view()),
    path("auth/otp/request", views.OTPRequestView.as_view()),

    path("me", views.MeView.as_view()),
    path("audit", views.AuditListView.as_view()),
    path("undo", views.UndoView.as_view()),
    path("sources", views.SourcePermissionView.as_view()),
    path("documents/<int:pk>/file", views.DocumentFileView.as_view()),
    path("emergency", views.EmergencyCardView.as_view()),
    path("money/summary", views.MoneySummaryView.as_view()),
    path("money/trends", views.MoneyTrendsView.as_view()),
    path("money/networth", views.MoneyNetWorthView.as_view()),
    path("money/budget", views.MoneyBudgetDetailView.as_view()),
    path("money/report", views.MoneyReportView.as_view()),
    path("money/report.pdf", views.MoneyReportExportView.as_view(), {"fmt": "pdf"}),
    path("money/report.xlsx", views.MoneyReportExportView.as_view(), {"fmt": "xlsx"}),
    path("money/parse", views.MoneyParseView.as_view()),
    path("money/learn-category", views.MoneyLearnCategoryView.as_view()),
    path("medicines/<int:pk>/taken", views.MedicineTakenView.as_view()),
    path("medicines/<int:pk>/escalation", views.MedicineEscalationView.as_view()),
    path("medicines/today", views.MedicineTodayView.as_view()),
    path("medicines/history", views.MedicineHistoryView.as_view()),
    path("medicines/caregiver", views.CaregiverDashboardView.as_view()),
    path("medicines/doctor-pdf", views.DoctorVisitPdfView.as_view()),
    path("scam/check", views.ScamCheckView.as_view()),
    path("scam/library", views.ScamLibraryView.as_view()),
    path("scam/report", views.ScamReportView.as_view()),
    path("safety/checkin", views.SafetyCheckinView.as_view()),
    path("safety/checkin/arrived", views.SafetyCheckinArrivedView.as_view()),
    path("reminders/parse", views.ReminderParseView.as_view()),
    path("memory/search", views.MemorySearchView.as_view()),
    path("plans", views.PlansPublicView.as_view()),
    path("briefing", views.briefing),
    path("alerts", views.alerts),
    path("scan", views.LifeScanView.as_view()),
    path("agent", views.AgentView.as_view()),
    path("wrapped", views.wrapped),
    path("invite", views.InviteView.as_view()),
    path("export", views.ExportView.as_view()),
    path("export/excel", views.ExportExcelView.as_view()),
    path("export/pdf", views.ExportPdfView.as_view()),
    path("account", views.DeleteAccountView.as_view()),

    # Integrations admin (owner-only)
    path("admin/integrations", views.IntegrationsListView.as_view()),
    path("admin/integrations/<slug:slug>", views.IntegrationSaveView.as_view()),
    path("admin/integrations/<slug:slug>/test", views.IntegrationTestView.as_view()),

    # Monetization (P3)
    path("me/plan", views.PlanView.as_view()),
    path("credits/rewarded", views.RewardedAdView.as_view()),
    path("waitlist", views.WaitlistView.as_view()),
    path("watch/feed", views.watch_feed),
    path("nearby", views.nearby),
    path("artist/favourite", views.FavouriteArtistView.as_view()),
    path("finance", views.FinanceView.as_view()),
    path("guides", views.govt_guide),
    path("me/elderly", views.ElderlyModeView.as_view()),
    path("autopay/stop-all", views.autopay_stop_all),
    path("studio", views.AgentStudioView.as_view()),
    path("inbox", views.InboxView.as_view()),
    path("business/reply", views.BusinessReplyView.as_view()),
    path("business/order", views.BusinessOrderCaptureView.as_view()),
    path("webhook/whatsapp", views.WhatsAppWebhookView.as_view()),

    # ===== Business v2 (Phase B) — khata + selling + AI assistant =====
    # BUSINESS PROFILES (§1) — list / create / select
    path("business/profiles", bz.ProfilesView.as_view()),
    path("business/profiles/select", bz.ProfileSelectView.as_view()),

    # SELLING (§3) — catalog, quick-sell cart, checkout, customers, reports
    path("business/products", bz.ProductsView.as_view()),
    path("business/products/<int:pk>", bz.ProductDetailView.as_view()),
    path("business/products/import", bz.ProductImportView.as_view()),
    path("business/products/<int:pk>/variants", bz.ProductVariantView.as_view()),
    path("business/cart/add", bz.CartAddView.as_view()),
    path("business/cart/line/<int:line_id>/price", bz.CartSetPriceView.as_view()),
    path("business/cart/line/<int:line_id>/qty", bz.CartSetQtyView.as_view()),
    path("business/cart/line/<int:line_id>", bz.CartRemoveView.as_view()),
    path("business/cart/line/<int:line_id>/remove", bz.CartRemovePostView.as_view()),
    path("business/cart/discount/preview", bz.CartDiscountPreviewView.as_view()),
    path("business/sales/checkout", bz.CheckoutView.as_view()),
    path("business/sales/<int:pk>/receipt", bz.ReceiptView.as_view()),
    path("business/sales/<int:pk>/receipt.pdf", bz.ReceiptPdfView.as_view()),
    path("business/customers", bz.CustomersView.as_view()),
    path("business/customers/dedupe", bz.CustomerDedupeView.as_view()),
    path("business/customers/<str:phone>/history", bz.CustomerHistoryView.as_view()),
    path("business/reports", bz.ReportsView.as_view()),
    path("business/reports/bank-loan", bz.BankLoanReportView.as_view()),

    # KHATA + CASHBOX
    path("business/khata/parties", bz.KhataPartiesView.as_view()),
    path("business/khata/parties/<int:pk>/statement", bz.KhataStatementView.as_view()),
    path("business/khata/parties/<int:pk>/statement.pdf", bz.KhataStatementPdfView.as_view()),
    path("business/khata/parties/<int:pk>/entries", bz.KhataEntryView.as_view()),
    path("business/khata/parties/<int:pk>/payment", bz.KhataPaymentView.as_view()),
    path("business/khata/net-position", bz.KhataNetPositionView.as_view()),
    path("business/khata/tagada/single/<int:pk>", bz.TagadaSingleView.as_view()),
    path("business/khata/tagada/bulk", bz.TagadaBulkView.as_view()),
    path("business/khata/tagada/schedule", bz.TagadaScheduleView.as_view()),
    path("business/cashbox/<str:day>", bz.CashboxView.as_view()),
    path("business/cashbox/<str:day>/opening", bz.CashboxOpeningView.as_view()),
    path("business/cashbox/<str:day>/entries", bz.CashboxEntryView.as_view()),
    path("business/cashbox/<str:day>/reconcile", bz.CashboxReconcileView.as_view()),

    # AI SALES ASSISTANT (§4) — PAID + key-gated
    path("business/ai/reply", bz.AiReplyView.as_view()),
    path("business/ai/bargain", bz.AiBargainView.as_view()),
    path("business/ai/disclose", bz.AiDiscloseView.as_view()),
    path("business/ai/morning-summary", bz.MorningSummaryView.as_view()),
    path("business/ai/voice-entry", bz.VoiceEntryView.as_view()),
    path("business/ai/paper-khata", bz.PaperKhataView.as_view()),
    path("business/ai/match-payment", bz.MatchPaymentView.as_view()),
    path("business/ai/insights", bz.InsightsView.as_view()),
    # AI chat inbox + channels (official platforms only; PAID + key-gated)
    path("business/ai/channels", bz.AiChannelsView.as_view()),
    path("business/ai/threads", bz.AiThreadsView.as_view()),
    path("business/ai/threads/<int:pk>", bz.AiThreadDetailView.as_view()),
    path("business/ai/threads/<int:pk>/send", bz.AiThreadSendView.as_view()),
    path("business/ai/threads/<int:pk>/takeover", bz.AiThreadTakeoverView.as_view()),
    # per-product bargaining ladders (PAID; min_price read-only floor)
    path("business/bargain/rules", bz.BargainRulesView.as_view()),
    path("business/bargain/rules/<int:pk>", bz.BargainRuleSaveView.as_view()),
    # shop policies (FREE; feeds AI context)
    path("business/policies", bz.PoliciesView.as_view()),
    # orders list + detail (FREE, scoped)
    path("business/orders", bz.OrdersListView.as_view()),
    path("business/orders/<int:pk>", bz.OrderDetailView.as_view()),
    path("business/orders/<int:pk>/advance", bz.OrderAdvanceView.as_view()),
    path("business/orders/<int:pk>/parcel", bz.OrderParcelView.as_view()),
    path("business/outbound/plan", bz.OutboundPlanView.as_view()),
    path("business/webhook/send", bz.WebhookSendView.as_view()),
    path("business/webhook/incoming", bz.WebhookIncomingView.as_view()),
    path("business/payments/qr", bz.MerchantQrView.as_view()),
    path("business/payments/link", bz.PaymentLinkView.as_view()),
    path("nominees/<int:pk>/activate", views.nominee_activate),
    path("jobs/<int:pk>/tailor", views.JobTailorView.as_view()),

    # ===== Module 5 (P13+) =====
    # Health
    path("health/tips", m5.HealthTipsView.as_view()),
    path("health/tips/emergency", m5.HealthEmergencyView.as_view()),
    path("medicine-db/search", m5.MedicineDbSearchView.as_view()),
    path("medicine-db/lookup", m5.MedicineDbLookupView.as_view()),
    path("birthdays", m5.BirthdaysView.as_view()),
    path("birthdays/drafts", m5.BirthdayDraftsView.as_view()),
    path("birthdays/<int:pk>/delete", m5.BirthdayDeleteView.as_view()),
    # Life
    path("appointments/", m5.AppointmentsView.as_view()),
    path("dictionary/lookup", m5.DictionaryLookupView.as_view()),
    path("ramadan/times", m5.RamadanTimesView.as_view()),
    path("ramadan/eid-card", m5.RamadanEidCardView.as_view()),
    path("exam/watcher", m5.ExamWatcherView.as_view()),
    # Launch gaps
    path("auth/reset/request", m5.ResetRequestView.as_view()),
    path("auth/reset/confirm", m5.ResetConfirmView.as_view()),
    path("analytics/ingest", m5.AnalyticsIngestView.as_view()),
    path("analytics/dashboard", m5.AnalyticsDashboardView.as_view()),
    path("legal", m5.LegalIndexView.as_view()),
    path("legal/<slug:key>", m5.LegalPageView.as_view()),
    path("name/about", m5.NameAboutView.as_view()),
    path("photo/plan", m5.PhotoPlanView.as_view()),
    path("unseen", m5.UnseenView.as_view()),
    # Connected Circle
    path("circle/members", m5.CircleMembersView.as_view()),
    path("circle/requests", m5.CircleRequestsView.as_view()),
    path("circle/keys", m5.CircleKeysView.as_view()),
    path("circle/request", m5.CircleRequestCreateView.as_view()),
    path("circle/request/<int:pk>/act", m5.CircleRequestActView.as_view()),
    path("circle/invite", m5.CircleInviteView.as_view()),
    path("circle/<int:pk>/sharing", m5.CircleSharingView.as_view()),
    path("circle/<int:pk>/report", m5.CircleReportView.as_view()),
    path("circle/<int:pk>/messages", m5.CircleMessagesView.as_view()),
    path("circle/<int:pk>/see/<slug:scope>", m5.CircleScopedReadView.as_view()),
    path("circle/messages/<int:pk>/<slug:action>", m5.CircleMessageActionView.as_view()),
    # --- build-61: Messenger M1 calls + privacy ---
    path("circle/calls", b61.CircleCallsView.as_view()),
    path("circle/<int:pk>/call", b61.CirclePlaceCallView.as_view()),
    path("circle/<int:pk>/call/answer", b61.CircleAnswerCallView.as_view()),
    path("circle/calls/<int:call_id>/event", b61.CircleCallEventView.as_view()),
    path("circle/privacy", b61.CirclePrivacyView.as_view()),
    path("circle/<int:pk>/controls", b61.CircleMemberControlsView.as_view()),
    # --- M2: Groups (item 7) ---
    path("circle/groups", m2.CircleGroupsView.as_view()),
    path("circle/groups/messages/<int:mid>/<slug:action>",
         m2.CircleGroupMessageActionView.as_view()),
    path("circle/groups/polls/<int:pid>/<slug:action>",
         m2.CircleGroupPollActionView.as_view()),
    path("circle/groups/<int:pk>", m2.CircleGroupDetailView.as_view()),
    path("circle/groups/<int:pk>/members", m2.CircleGroupMembersView.as_view()),
    path("circle/groups/<int:pk>/members/<int:mid>/<slug:event>",
         m2.CircleGroupMemberActionView.as_view()),
    path("circle/groups/<int:pk>/messages", m2.CircleGroupMessagesView.as_view()),
    path("circle/groups/<int:pk>/polls", m2.CircleGroupPollsView.as_view()),
    path("circle/groups/<int:pk>/invite", m2.CircleGroupInviteView.as_view()),
    path("circle/groups/<int:pk>/leave", m2.CircleGroupLeaveView.as_view()),
    path("circle/groups/<int:pk>/report", m2.CircleGroupReportView.as_view()),
    path("circle/groups/<int:pk>/call", m2.CircleGroupCallView.as_view()),
    # catch-all for single-segment group settings — MUST be last of the
    # circle/groups/<pk>/<x> routes so the literals above win.
    path("circle/groups/<int:pk>/<slug:setting>",
         m2.CircleGroupSettingsView.as_view()),  # announcements | size-limit
    # --- M2: Status / Stories (item 8) ---
    path("circle/status", m2.CircleStatusView.as_view()),
    path("circle/status/mine", m2.CircleStatusMineView.as_view()),
    path("circle/status/mute", m2.CircleStatusMuteView.as_view()),
    path("circle/status/author/<int:uid>", m2.CircleStatusAuthorView.as_view()),
    path("circle/status/<int:pk>/view", m2.CircleStatusViewView.as_view()),
    path("circle/status/<int:pk>/reply", m2.CircleStatusReplyView.as_view()),
    # --- M2: Extras (items 9 + 10) ---
    path("circle/broadcast", m2.CircleBroadcastView.as_view()),
    path("circle/backup", m2.CircleBackupView.as_view()),
    path("circle/devices", m2.CircleDevicesView.as_view()),
    path("circle/devices/link", m2.CircleDeviceLinkView.as_view()),
    path("circle/devices/<str:device_id>/revoke",
         m2.CircleDeviceRevokeView.as_view()),
    path("circle/scheduled/<int:pk>/cancel",
         m2.CircleScheduledCancelView.as_view()),
    path("circle/<int:pk>/settings", m2.CircleChatSettingsView.as_view()),
    path("circle/<int:pk>/scheduled", m2.CircleScheduledView.as_view()),
    # --- build-61: referral points ---
    path("referral/balance", b61.ReferralBalanceView.as_view()),
    path("referral/history", b61.ReferralHistoryView.as_view()),
    path("referral/redeem", b61.ReferralRedeemView.as_view()),
    # --- build-61: Safe Journey ---
    path("journey/start", b61.JourneyStartView.as_view()),
    path("journey/active", b61.JourneyActiveView.as_view()),
    path("journey/<int:pk>/location", b61.JourneyLocationView.as_view()),
    path("journey/<int:pk>/arrived", b61.JourneyArrivedView.as_view()),
    path("journey/<int:pk>/stop", b61.JourneyStopView.as_view()),
    path("journey/<int:pk>/respond", b61.JourneyRespondView.as_view()),
    path("journey/<int:pk>/web-link", b61.JourneyWebLinkView.as_view()),
    path("journey/sos", b61.JourneySosView.as_view()),
    path("journey/duress-pin", b61.JourneyDuressPinView.as_view()),
    path("journey/nearest-help", b61.JourneyNearestHelpView.as_view()),
    path("journey/places", b61.SavedPlacesView.as_view()),
    path("journey/routines", b61.JourneyRoutinesView.as_view()),
    path("journey/wellness", b61.WellnessView.as_view()),
    path("journey/wellness/ping", b61.WellnessPingView.as_view()),
]

urlpatterns += router.urls
