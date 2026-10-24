from django.urls import path
from rest_framework.routers import DefaultRouter

from . import views
from . import media_sign
from . import views_module5 as m5
from . import views_build61 as b61
from . import views_m2 as m2
from . import views_p3_circle as p3c
from . import business_views as bz
from . import views_messenger as msg
from . import views_security as secv
from . import views_registry as reg
from . import views_lost as lost
from . import views_account_deletion as acctdel
from . import views_chat as chatv
from . import shop_views as shop
from . import views_push as pushv
from . import views_ads as ads_views
from . import views_voice as voicev

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
# PA Secretary Mode (§14) collections
router.register("pa/visitors", views.PaVisitorsViewSet, basename="pa-visitors")
router.register("pa/followups", views.PaFollowupsViewSet, basename="pa-followups")
router.register("pa_schedule", views.PaScheduleViewSet, basename="pa-schedule")
# Wave E generic collections (task manager #21 + Section-20 money modules)
for _name, _vs in views.GENERIC_COLLECTION_VIEWSETS.items():
    router.register(_name, _vs, basename="gencol-" + _name.replace("/", "-"))
router.register("autopay", views.AutoPayRuleViewSet, basename="autopay")
router.register("products", views.ProductViewSet, basename="product")
router.register("orders", views.OrderViewSet, basename="order")
router.register("nominees", views.NomineeViewSet, basename="nominee")
router.register("jobs", views.JobViewSet, basename="job")
# Payment / auto-pay LADDER (SPEC v2.1 §21) — one table, two kind-filtered tabs.
router.register("ladder-receivable", views.LadderReceivableViewSet,
                basename="ladder-receivable")
router.register("ladder-payable", views.LadderPayableViewSet,
                basename="ladder-payable")

urlpatterns = [
    path("health", views.health),
    path("m/<path:name>", media_sign.serve_signed),
    path("version", views.version),
    path("app/latest", views.app_latest),
    path("ai/status", views.ai_status),

    path("auth/register", views.RegisterView.as_view()),
    path("auth/login", views.LoginView.as_view()),
    path("auth/logout", views.LogoutView.as_view()),
    path("auth/otp/request", views.OTPRequestView.as_view()),

    path("me", views.MeView.as_view()),
    path("me/avatar", views.MeAvatarView.as_view()),
    path("audit", views.AuditListView.as_view()),
    path("undo", views.UndoView.as_view()),
    # Action Center (SPEC v2.1 §21, feature #9) — pending-approval queue + log.
    path("actions/pending", views.PendingActionsView.as_view()),
    path("actions/<int:pk>/approve", views.PendingActionApproveView.as_view()),
    path("actions/<int:pk>/reject", views.PendingActionRejectView.as_view()),
    path("actions/log", views.ActionLogView.as_view()),
    path("sources", views.SourcePermissionView.as_view()),
    path("documents/<int:pk>/file", views.DocumentFileView.as_view()),
    path("emergency", views.EmergencyCardView.as_view()),
    path("money/summary", views.MoneySummaryView.as_view()),
    path("money/trends", views.MoneyTrendsView.as_view()),
    path("money/networth", views.MoneyNetWorthView.as_view()),
    path("money/wrapped", views.MoneyWrappedView.as_view()),
    # Advanced Budget module (feature #50). Specific sub-paths first so the bare
    # create/goal-link POST path doesn't swallow them.
    path("money/budget/month", views.MoneyBudgetView.as_view(), {"action": "month"}),
    path("money/budget/history", views.MoneyBudgetView.as_view(), {"action": "history"}),
    path("money/budget/plan", views.MoneyBudgetView.as_view(), {"action": "plan"}),
    path("money/budget/template", views.MoneyBudgetView.as_view(), {"action": "template"}),
    path("money/budget/goal-link", views.MoneyBudgetView.as_view(), {"action": "goal-link"}),
    path("money/budget/<int:pk>/delete", views.MoneyBudgetView.as_view(), {"action": "delete"}),
    path("money/budget/<int:pk>", views.MoneyBudgetView.as_view()),
    path("money/budget", views.MoneyBudgetView.as_view()),
    path("money/budget-detail", views.MoneyBudgetDetailView.as_view()),
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

    # ---- push (FCM HTTP v1, key-gated) ----
    path("devices/register", pushv.DeviceRegisterView.as_view()),
    path("devices/unregister", pushv.DeviceUnregisterView.as_view()),
    path("push/status", pushv.PushStatusView.as_view()),

    # ---- home notification centre + dynamic suggestions ----
    path("notif/reminders", views.notif_reminders),
    path("notif/reminders/<str:item_id>/snooze", views.notif_reminder_snooze),
    path("notif/feed", views.notif_feed),
    path("notif/read-all", views.notif_read_all),
    path("notif/<str:item_id>/seen", views.notif_seen),
    path("home/suggestions", views.home_suggestions),
    path("home/suggestions/dismiss", views.home_suggestions_dismiss),
    path("home/suggestions/tap", views.home_suggestions_tap),
    path("home/badges", views.home_badges),

    path("scan", views.LifeScanView.as_view()),
    path("agent", views.AgentView.as_view()),

    # AI Chat (Part 3) — ChatGPT-like multi-turn chat with history.
    path("chat/sessions", chatv.ChatSessionsView.as_view()),
    path("chat/sessions/<int:sid>", chatv.ChatSessionDetailView.as_view()),
    path("chat/sessions/<int:sid>/messages", chatv.ChatMessagesView.as_view()),
    path("chat/sessions/<int:sid>/send", chatv.ChatSendView.as_view()),
    path("chat/sessions/<int:sid>/stream", chatv.ChatStreamView.as_view()),
    path("chat/sessions/<int:sid>/regenerate", chatv.ChatRegenerateView.as_view()),
    path("wrapped", views.wrapped),
    path("invite", views.InviteView.as_view()),
    path("export", views.ExportView.as_view()),
    path("export/excel", views.ExportExcelView.as_view()),
    path("export/pdf", views.ExportPdfView.as_view()),
    path("account", views.DeleteAccountView.as_view()),
    # Secure "Delete my profile & all data" — Play-compliant 7-day grace,
    # gated like Section 8 (password + OTP + Security PIN, theft-blocked, delayed).
    path("account/delete/preview", acctdel.AccountDeletePreviewView.as_view()),
    path("account/delete/request", acctdel.AccountDeleteRequestView.as_view()),
    path("account/delete/cancel", acctdel.AccountDeleteCancelView.as_view()),
    path("account/delete/status", acctdel.AccountDeleteStatusView.as_view()),
    path("account/delete/start-fresh", acctdel.AccountStartFreshView.as_view()),  # dl1

    # Integrations admin (owner-only)
    path("admin/integrations", views.IntegrationsListView.as_view()),
    path("admin/integrations/<slug:slug>", views.IntegrationSaveView.as_view()),
    path("admin/integrations/<slug:slug>/test", views.IntegrationTestView.as_view()),

    # Monetization (P3)
    path("me/plan", views.PlanView.as_view()),
    path("credits/rewarded", views.RewardedAdView.as_view()),
    # Business Model Build 2 — credit packs + ad wallet
    path("credits/packs", b61.CreditPacksView.as_view()),
    path("credits/history", b61.CreditHistoryView.as_view()),
    path("credits/topup", b61.CreditTopupView.as_view()),
    path("credits/topup/confirm", b61.CreditTopupConfirmView.as_view()),
    path("ads/event", b61.AdEventView.as_view()),
    path("ads/wallet", b61.AdWalletView.as_view()),
    # Business Model Build 3 — storage meter + usage summary
    path("storage/meter", b61.StorageMeterView.as_view()),
    path("me/usage-summary", b61.UsageSummaryView.as_view()),
    path("waitlist", views.WaitlistView.as_view()),
    path("watch/feed", views.watch_feed),
    path("nearby", views.nearby),
    path("artist/favourite", views.FavouriteArtistView.as_view()),
    path("finance", views.FinanceView.as_view()),
    path("guides", views.govt_guide),
    path("me/elderly", views.ElderlyModeView.as_view()),
    path("autopay/stop-all", views.autopay_stop_all),
    path("ladder/stop-all", views.ladder_stop_all),
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
    # #67 Selective sharing (SPEC v2.1 §21) — server-enforced per-member,
    # per-item consent. MUST precede router.urls so the literal `family/sharing*`
    # routes win over the FamilyMember router's `family/<pk>`. Trailing slashes
    # match the client's createItem/listItems path convention (api.dart _withSlash).
    path("family/sharing/consent/", views.FamilySharingConsentView.as_view()),
    path("family/sharing/consent", views.FamilySharingConsentView.as_view()),
    path("family/sharing/grant/", views.FamilySharingGrantView.as_view()),
    path("family/sharing/grant", views.FamilySharingGrantView.as_view()),
    path("family/sharing/revoke-member/",
         views.FamilySharingRevokeMemberView.as_view()),
    path("family/sharing/revoke-member",
         views.FamilySharingRevokeMemberView.as_view()),
    path("family/sharing/revoke-all/",
         views.FamilySharingRevokeAllView.as_view()),
    path("family/sharing/revoke-all", views.FamilySharingRevokeAllView.as_view()),
    path("family/sharing/audit/", views.FamilySharingAuditView.as_view()),
    path("family/sharing/audit", views.FamilySharingAuditView.as_view()),
    path("family/shared/<int:member_id>/<slug:item>/",
         views.FamilySharedItemView.as_view()),
    path("family/shared/<int:member_id>/<slug:item>",
         views.FamilySharedItemView.as_view()),

    # ===== CCTV / shop loss-prevention (Business, Part 4) =====
    # DEVICE ingest — per-shop ENROLLMENT TOKEN (not a user login). No video.
    path("shop/ingest", shop.ShopIngestView.as_view()),
    path("shop/hook/<str:vendor>/<str:camera_token>", shop.ShopCameraHookView.as_view()),
    path("shop/pos", shop.ShopPosIngestView.as_view()),
    # OWNER endpoints — normal Token auth + owner gate.
    path("shop/sites", shop.ShopSitesView.as_view()),
    path("shop/sites/<int:pk>", shop.ShopSiteDetailView.as_view()),
    path("shop/sites/<int:pk>/cameras", shop.ShopCamerasView.as_view()),
    path("shop/events", shop.ShopEventsView.as_view()),
    path("shop/events/<int:pk>/mark", shop.ShopEventMarkView.as_view()),
    path("shop/summary", shop.ShopSummaryView.as_view()),

    path("nominees/<int:pk>/activate", views.nominee_activate),
    path("nominees/<int:pk>/request-release", views.nominee_request_release),
    path("nominees/<int:pk>/confirm-open", views.nominee_confirm_open),
    path("nominees/<int:pk>/cancel-release", views.nominee_cancel_release),
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
    # #87 Chat organise (per-user pin/archive/mute/read)
    path("messenger/chats/<int:pk>/pin", m5.ChatPinView.as_view()),
    path("messenger/chats/<int:pk>/archive", m5.ChatArchiveView.as_view()),
    path("messenger/chats/<int:pk>/mute", m5.ChatMuteView.as_view()),
    path("messenger/chats/<int:pk>/read", m5.ChatReadView.as_view()),
    # #95/#96 message requests + message-level privacy
    path("circle/settings/message-privacy", m5.MessagePrivacyView.as_view()),
    path("circle/blocked", m5.CircleBlockedView.as_view()),
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
    # p3: E2E stories (per-viewer ciphertext) replace the M2 tray/author/mine
    path("circle/status", p3c.StoryTrayView.as_view()),
    path("circle/status/mine", p3c.StoryMineView.as_view()),
    path("circle/status/privacy", p3c.CirclePrivacyDefaultsView.as_view()),
    path("circle/status/mute", m2.CircleStatusMuteView.as_view()),
    path("circle/status/author/<int:uid>", p3c.StoryAuthorView.as_view()),
    path("circle/status/<int:pk>/delete", p3c.StoryDeleteView.as_view()),
    path("circle/notes", p3c.CircleNotesView.as_view()),
    path("circle/notes/clear", p3c.CircleNoteClearView.as_view()),
    path("circle/assisto/quote", p3c.AssistoQuoteView.as_view()),
    path("circle/assisto/run", p3c.AssistoRunView.as_view()),
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
    # Self-hosted WebRTC TURN/STUN credentials (Step 6 M3)
    path("rtc/turn", b61.RtcTurnView.as_view()),
    path("rtc/health", b61.RtcHealthView.as_view()),   # calls-health
    # Client startup crash/ANR report (device → owner-readable log)
    path("client/crash-report", b61.ClientCrashReportView.as_view()),
    # Telegram bot sandbox (Step 6) — inert until a token is set
    path("telegram/webhook", b61.TelegramWebhookView.as_view()),
    # #178 Cost kill-switch & feature flags (owner-only)
    path("admin/flags", b61.AdminFlagsView.as_view()),
    path("admin/flags/flip", b61.AdminFlagsFlipView.as_view()),
    # Business Model (Build 1): owner-only server-side pricing config
    path("admin/pricing", b61.PricingConfigView.as_view()),
    # Business Model (Build 3): owner-only daily P&L dashboard
    path("admin/pnl", b61.AdminPnlView.as_view()),
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

    # ===== Messenger STEP 3 =====
    # 1. Contacts & invites + personal connection request (msg_contacts)
    path("messenger/contacts/match", msg.ContactsMatchView.as_view()),
    path("messenger/contacts/contract", msg.ContactHashingContractView.as_view()),
    path("messenger/invite/existing", msg.InviteExistingView.as_view()),
    path("messenger/invite/share-link", msg.InviteShareLinkView.as_view()),
    path("messenger/invite/sms", msg.InviteSmsView.as_view()),
    path("messenger/request", msg.ConnectionRequestCreateView.as_view()),
    path("messenger/request/<int:pk>/act", msg.ConnectionRequestActView.as_view()),
    path("messenger/request/<int:pk>/message",
         msg.ConnectionRequestMessageView.as_view()),
    path("messenger/request/<int:pk>/report",
         msg.ConnectionRequestReportView.as_view()),

    # 2. Communities (msg_community)
    path("community/create", msg.CommunityCreateView.as_view()),
    path("community/<int:pk>/group/create", msg.CommunityGroupCreateView.as_view()),
    path("community/group/<int:pk>", msg.CommunityGroupPatchView.as_view()),
    path("community/<int:pk>/groups", msg.CommunityGroupsListView.as_view()),
    path("community/group/<int:pk>/join", msg.CommunityGroupJoinView.as_view()),
    path("community/join-request/<int:pk>/<slug:action>",
         msg.CommunityJoinRequestActView.as_view()),
    path("community/group/<int:pk>/member/<int:uid>/remove",
         msg.CommunityMemberRemoveView.as_view()),
    path("community/group/<int:pk>/post", msg.CommunityGroupPostView.as_view()),
    path("community/<int:pk>/members", msg.CommunityMembersView.as_view()),
    path("me/show-phone", msg.MeShowPhoneView.as_view()),
    path("me/communities-who-can-msg", msg.MeWhoCanMsgView.as_view()),
    path("community/message", msg.CommunityMessageView.as_view()),
    path("community/message-request/<int:pk>/<slug:action>",
         msg.CommunityMsgReqActView.as_view()),
    path("community/message-request/<int:pk>/report",
         msg.CommunityMsgReqReportView.as_view()),
    path("community/call", msg.CommunityCallView.as_view()),

    # 3. Channels (msg_channel) — NOT E2E; follower privacy enforced
    path("channels", msg.ChannelsView.as_view()),
    path("channels/<int:pk>", msg.ChannelDetailView.as_view()),
    path("channels/<int:pk>/admins", msg.ChannelAdminsView.as_view()),
    path("channels/<int:pk>/follow", msg.ChannelFollowView.as_view()),
    path("channels/<int:pk>/unfollow", msg.ChannelUnfollowView.as_view()),
    path("channels/<int:pk>/mute", msg.ChannelMuteView.as_view()),
    path("channels/<int:pk>/my-visibility", msg.ChannelMyVisibilityView.as_view()),
    path("channels/<int:pk>/list-visibility",
         msg.ChannelListVisibilityView.as_view()),
    path("channels/<int:pk>/followers", msg.ChannelFollowersView.as_view()),
    path("channels/<int:pk>/posts", msg.ChannelPostsView.as_view()),
    path("channels/<int:pk>/posts/<int:pid>/react",
         msg.ChannelPostReactView.as_view()),
    path("channels/<int:pk>/posts/<int:pid>/view",
         msg.ChannelPostViewView.as_view()),
    path("channels/<int:pk>/posts/<int:pid>/pin",
         msg.ChannelPostPinView.as_view()),
    path("channels/<int:pk>/polls", msg.ChannelPollsView.as_view()),
    path("channels/<int:pk>/polls/<int:poll_id>/tally",
         msg.ChannelPollTallyView.as_view()),
    path("channels/<int:pk>/polls/<int:poll_id>/<slug:action>",
         msg.ChannelPollActView.as_view()),
    path("channels/<int:pk>/analytics", msg.ChannelAnalyticsView.as_view()),
    path("channels/<int:pk>/verify/request",
         msg.ChannelVerifyRequestView.as_view()),
    path("channels/<int:pk>/share-link", msg.ChannelShareLinkView.as_view()),
    path("admin/channels/<int:pk>/verify/<slug:action>",
         msg.ChannelVerifyGrantView.as_view()),

    # 4. Moderation + owner-admin (msg_moderation) — public surfaces only
    path("moderation/report", msg.ModerationReportView.as_view()),
    path("moderation/<int:pk>/appeal", msg.ModerationAppealView.as_view()),
    path("admin/moderation/queue", msg.AdminQueueView.as_view()),
    path("admin/moderation/<int:pk>", msg.AdminItemDetailView.as_view()),
    path("admin/moderation/<int:pk>/action", msg.AdminItemActionView.as_view()),
    path("admin/moderation/<int:pk>/reopen", msg.AdminItemReopenView.as_view()),
    path("admin/users", msg.AdminUsersView.as_view()),
    path("admin/users/<int:pk>/public", msg.AdminUserPublicView.as_view()),
    path("admin/users/<int:pk>/action", msg.AdminUserActionView.as_view()),

    # 5. Messenger FULL-UI — hub-⋮ + chat-⋮ actions (msg_messenger_ui)
    path("messenger/starred", msg.StarredView.as_view()),
    path("messenger/link/start", msg.LinkStartView.as_view()),
    path("messenger/link/confirm", msg.LinkConfirmView.as_view()),
    path("messenger/linked-devices", msg.LinkedDevicesView.as_view()),
    path("messenger/linked-devices/<str:device_id>/revoke",
         msg.LinkedDeviceRevokeView.as_view()),
    path("messenger/call-link", msg.CallLinkView.as_view()),
    path("messenger/schedule-call", msg.ScheduleCallView.as_view()),
    path("messenger/group-call", msg.GroupCallView.as_view()),
    path("messenger/chat/<int:member_id>/report", msg.ChatReportView.as_view()),
    path("messenger/read-all", msg.ReadAllView.as_view()),
    path("messenger/chat/<int:member_id>/settings", msg.ChatThemeView.as_view()),
    path("messenger/lists", msg.ChatListsView.as_view()),
    path("messenger/lists/<int:pk>", msg.ChatListDetailView.as_view()),
    path("messenger/broadcast-lists", msg.BroadcastListsView.as_view()),
    path("messenger/broadcast-lists/<int:pk>/send",
         msg.BroadcastSendView.as_view()),

    # Stolen-While-Unlocked Protection (server is source of truth)
    path("security/state", secv.SecurityStateView.as_view()),
    path("security/pin/set", secv.SecurityPinSetView.as_view()),
    path("security/pin/verify", secv.SecurityPinVerifyView.as_view()),
    path("security/action", secv.SecurityActionView.as_view()),
    path("security/action/<int:pk>/cancel", secv.SecurityActionCancelView.as_view()),
    path("security/action/<int:pk>/approve", secv.SecurityActionApproveView.as_view()),
    path("security/signal", secv.SecuritySignalView.as_view()),
    path("security/arm", secv.SecurityArmView.as_view()),
    path("security/approver", secv.SecuritySetApproverView.as_view()),

    # Anti-theft Batch 4 — stolen-IMEI registry + used-phone check + sell transfer
    path("registry/report-stolen", reg.ReportStolenView.as_view()),
    path("registry/recover", reg.RecoverView.as_view()),
    path("registry/check", reg.CheckView.as_view()),
    path("registry/neir-status", reg.NeirStatusView.as_view()),
    path("registry/tac", reg.TacLookupView.as_view()),
    path("sale/create", reg.SaleCreateView.as_view()),
    path("sale/authorize", reg.SaleAuthorizeView.as_view()),
    path("sale/accept", reg.SaleAcceptView.as_view()),
    path("sale/mine", reg.SaleMineView.as_view()),

    # Anti-theft Batch 5 — lost/stolen server-side (heartbeat, events, lost-mode)
    path("security/heartbeat", lost.HeartbeatView.as_view()),
    path("security/events", lost.CapturedEventsView.as_view()),
    path("security/lost-mode", lost.LostModeView.as_view()),
    path("security/lost-phone", lost.LostPhoneView.as_view()),
    path("security/event/<int:pk>/photo", lost.CapturedPhotoView.as_view()),
    # Recovery helpers (text + PDF; honest/coarse)
    path("recovery/gd-draft", lost.GdDraftView.as_view()),
    path("recovery/sp-letter", lost.SpLetterView.as_view()),
    path("recovery/evidence.pdf", lost.EvidencePdfView.as_view()),
    path("recovery/police-stations", lost.PoliceStationsView.as_view()),

    # ---- a6-leftovers ----
    # AdMob client config (key-gated; TEST ids until the owner saves real ones)
    path("ads/config", ads_views.AdsConfigView.as_view()),

    # ---- a1-priority ----
    # Owner DEFAULT home quick buttons (edited in /admin/pricing)
    path("app/home-defaults", b61.HomeDefaultsView.as_view()),

    # ---- a3-voice ---- Part 3 Assisto Voice (wake-word config, key-gated)
    path("voice/config", voicev.VoiceConfigView.as_view()),
    path("voice/youtube", voicev.VoiceYoutubeView.as_view()),
]

# ---- a2-cctv ---- CCTV Part 4 round 2: camera settings, device heartbeat /
# config / pair, EOD cash check, POS void, WebRTC live-view SIGNALING (no media).
from . import shop_ops_views as shopops  # noqa: E402
from . import sale_void_views as salevoid  # noqa: E402
urlpatterns += [
    path("shop/cameras/<int:pk>", shopops.ShopCameraDetailView.as_view()),
    path("shop/pair/check", shopops.ShopPairCheckView.as_view()),
    path("shop/heartbeat", shopops.ShopHeartbeatView.as_view()),
    path("shop/config", shopops.ShopDeviceConfigView.as_view()),
    path("shop/sites/<int:pk>/eod", shopops.ShopEodView.as_view()),
    path("shop/live/start", shopops.ShopLiveStartView.as_view()),
    path("shop/live/pending", shopops.ShopLivePendingView.as_view()),
    path("shop/live/<int:pk>/signal", shopops.ShopLiveSignalView.as_view()),
    path("shop/live/<int:pk>/end", shopops.ShopLiveEndView.as_view()),
    path("business/sales/<int:pk>/void", salevoid.SaleVoidView.as_view()),
]
# ---- /a2-cctv ----

# ---- m1-messenger ---- real backends for the 1:1 / group / community ⋮ menus
# and the Messenger settings screens. PREPENDED so the literal group routes win
# over the single-segment `circle/groups/<pk>/<slug:setting>` catch-all above.
from . import views_m1_messenger as m1  # noqa: E402
from . import views_m1_routes as m1r  # noqa: E402
urlpatterns[:0] = [
    # 1:1
    path("circle/<int:pk>/info", m1.ChatInfoView.as_view()),
    path("circle/<int:pk>/clear", m1.ChatClearView.as_view()),
    # group ⋮
    path("circle/groups/<int:pk>/mute", m1.GroupMuteView.as_view()),
    path("circle/groups/<int:pk>/disappearing",
         m1.GroupDisappearingView.as_view()),
    path("circle/groups/<int:pk>/theme", m1.GroupThemeView.as_view()),
    path("circle/groups/<int:pk>/favourite", m1.GroupFavouriteView.as_view()),
    path("circle/groups/<int:pk>/clear", m1.GroupClearView.as_view()),
    path("circle/groups/<int:pk>/export", m1.GroupExportView.as_view()),
    path("circle/groups/<int:pk>/ai/<slug:task>", m1.GroupAiView.as_view()),
    path("circle/groups/<int:pk>/messages/<int:mid>/<slug:action>",
         m1.GroupMessageActView.as_view()),
    # community ⋮
    path("community/<int:pk>/notifications",
         m1.CommunityNotificationsView.as_view()),
    path("community/<int:pk>/leave", m1.CommunityLeaveView.as_view()),
    # account
    path("circle/account/two-step", m1.TwoStepView.as_view()),
    path("circle/account/two-step/verify", m1.TwoStepVerifyView.as_view()),
    path("circle/account/change-number", m1.ChangeNumberStatusView.as_view()),
    path("circle/account/change-number/request",
         m1.ChangeNumberRequestView.as_view()),
    path("circle/account/change-number/confirm",
         m1.ChangeNumberConfirmView.as_view()),
    # privacy: message requests (stranger first messages, ciphertext only)
    path("circle/message-requests", m1.MessageRequestsView.as_view()),
    path("circle/message-requests/<int:pk>", m1.MessageRequestsView.as_view()),
    # settings
    path("circle/settings/notifications", m1.NotificationPrefsView.as_view()),
    path("circle/settings/calls", m1.CallPrefsView.as_view()),
    path("circle/settings/storage", m1.StoragePrefsView.as_view()),
    # chat list + community request inbox
    path("circle/chats", m1r.CircleChatsView.as_view()),
    path("community/message-requests",
         m1r.CommunityMessageRequestsListView.as_view()),
    # group: canonical NESTED shapes (old flat routes stay as aliases)
    path("circle/groups/<int:pk>/polls/<int:pid>/<slug:action>",
         m1r.GroupPollActNestedView.as_view()),
    path("circle/groups/<int:pk>/members/<int:mid>",
         m1r.GroupMemberNestedView.as_view()),
    path("circle/groups/<int:pk>/media", m1r.GroupMediaView.as_view()),
    # family accounting (integer poisha)
    path("family/accounting/summary", m1r.FamSummaryView.as_view()),
    path("family/accounting/expenses", m1r.FamExpensesView.as_view()),
    path("family/accounting/expenses/delete",
         m1r.FamExpenseDeleteView.as_view()),
    path("family/accounting/pool", m1r.FamPoolView.as_view()),
    path("family/accounting/pool/contribute",
         m1r.FamPoolContributeView.as_view()),
    path("family/accounting/settle", m1r.FamSettleView.as_view()),
    # notification centre, journey, disaster, medicine-db
    path("notif/reminders/<str:item_id>/done",
         m1r.NotifReminderDoneView.as_view()),
    path("journey/<int:pk>/timeline", m1r.JourneyTimelineView.as_view()),
    path("disaster/feed", m1r.DisasterFeedView.as_view()),
    path("medicine-db/report", m1r.MedicineDbReportView.as_view()),
    # connection-request list (GET; POST create unchanged) + channel discover
    path("messenger/request", m1r.ConnectionRequestsView.as_view()),
    path("channels/discover", m1r.ChannelDiscoverView.as_view()),
]
# ---- /m1-messenger ----

# ---- o1-otp ---- SMS OTP: status / request / resend / verify / login / reset.
from . import views_otp as otpv  # noqa: E402
urlpatterns += [
    path("auth/otp/status", otpv.OtpStatusView.as_view()),
    path("auth/otp/resend", otpv.OtpRequestView.as_view()),
    path("auth/otp/verify", otpv.OtpVerifyView.as_view()),
    path("auth/otp/login", otpv.OtpLoginView.as_view()),
    path("auth/otp/reset", otpv.OtpResetView.as_view()),
]
# ---- /o1-otp ----

# ---- v1-vehicle ---- Vehicle tracking: GT06/Teltonika trackers, live map,
# 24h route + trips, engine cut (PIN + speed gate + approval), grants, OBD,
# AI trip summary, Car Mode trips, Business fleet dashboard.
from . import views_vehicle as veh  # noqa: E402
urlpatterns += [
    path("vehicle/config", veh.VehicleConfigView.as_view()),
    path("vehicle/trackers", veh.TrackerListView.as_view()),
    path("vehicle/trackers/<int:pk>", veh.TrackerDetailView.as_view()),
    path("vehicle/trackers/<int:pk>/route", veh.TrackerRouteView.as_view()),
    path("vehicle/trackers/<int:pk>/trips", veh.TrackerTripsView.as_view()),
    path("vehicle/trackers/<int:pk>/commands", veh.TrackerCommandView.as_view()),
    path("vehicle/trackers/<int:pk>/audit", veh.TrackerAuditView.as_view()),
    path("vehicle/trackers/<int:pk>/grants", veh.TrackerGrantsView.as_view()),
    path("vehicle/trackers/<int:pk>/grants/<int:gid>", veh.TrackerGrantDeleteView.as_view()),
    path("vehicle/trackers/<int:pk>/obd", veh.TrackerObdView.as_view()),
    path("vehicle/trackers/<int:pk>/ai-summary", veh.TrackerAiSummaryView.as_view()),
    path("vehicle/commands/<int:cid>/approve", veh.CommandApproveView.as_view()),
    path("vehicle/commands/<int:cid>/cancel", veh.CommandCancelView.as_view()),
    path("vehicle/obd/decode", veh.ObdDecodeView.as_view()),
    path("vehicle/carmode/trip", veh.CarModeTripView.as_view()),
    path("vehicle/fleet", veh.FleetDashboardView.as_view()),
]
# ---- /v1-vehicle ----

# ---- d1-discover ----
from . import views_discover as disc  # noqa: E402

urlpatterns += [
    path("discover/cards", disc.DiscoverCardsView.as_view()),
    path("discover/track", disc.DiscoverTrackView.as_view()),
    path("admin/discover/cards", disc.AdminDiscoverCardsView.as_view()),
    path("admin/discover/cards/<int:pk>", disc.AdminDiscoverCardView.as_view()),
    path("admin/discover/cards/<int:pk>/image", disc.AdminDiscoverImageView.as_view()),
    path("admin/discover/cards/<int:pk>/report", disc.AdminDiscoverReportView.as_view()),
    path("admin/discover/cards/<int:pk>/report.<str:fmt>",
         disc.AdminDiscoverReportExportView.as_view()),
    path("admin/discover/reorder", disc.AdminDiscoverReorderView.as_view()),
    path("admin/discover/meta", disc.AdminDiscoverMetaView.as_view()),
    path("admin/discover/preview", disc.AdminDiscoverPreviewView.as_view()),
]
# ---- /d1-discover ----

# ---- c1-contacts ----
urlpatterns += [
    path("messenger/contacts/lookup", msg.ContactLookupView.as_view()),
]
# ---- /c1-contacts ----

# ---- m3-circle ----
from . import views_m3_circle as m3c  # noqa: E402
urlpatterns += [
    path("circle/invite/redeem", m3c.CircleInviteRedeemView.as_view()),
]
# ---- /m3-circle ----

# ---- mr1 ---- My Circle message requests (WhatsApp-like)
from . import views_mr1 as mr1  # noqa: E402
urlpatterns += [
    path("circle/message-request/start", mr1.MessageRequestStartView.as_view()),
    path("circle/request/<int:pk>/msgreq", mr1.MessageRequestActView.as_view()),
]
# ---- /mr1 ----

urlpatterns += router.urls

# ---- ps1-photo ---- Photo Studio: config, safety, entry ad, jobs (funding taken
# first), rewarded-ad tickets + AdMob SSV callback, cloud run, export gate, owner P&L.
from . import views_ps1_photo as ps1  # noqa: E402
urlpatterns += [
    path("photo-studio/config", ps1.PhotoStudioConfigView.as_view()),
    path("photo-studio/safety", ps1.PhotoStudioSafetyView.as_view()),
    path("photo-studio/entry-ad", ps1.PhotoStudioEntryAdView.as_view()),
    path("photo-studio/jobs", ps1.PhotoStudioJobsView.as_view()),
    path("photo-studio/jobs/<int:pk>", ps1.PhotoStudioJobView.as_view()),
    path("photo-studio/jobs/<int:pk>/ad-ticket", ps1.PhotoStudioTicketView.as_view()),
    path("photo-studio/jobs/<int:pk>/fund", ps1.PhotoStudioFundView.as_view()),
    path("photo-studio/jobs/<int:pk>/run", ps1.PhotoStudioRunView.as_view()),
    path("photo-studio/jobs/<int:pk>/unlock", ps1.PhotoStudioUnlockView.as_view()),
    path("photo-studio/jobs/<int:pk>/report", ps1.PhotoStudioReportView.as_view()),  # d1-photo v2
    path("ads/ssv", ps1.AdMobSsvView.as_view()),
    path("admin/photo-studio/pnl", ps1.AdminPhotoStudioPnlView.as_view()),
    # ---- p2-photo ---- on-device AI model: manifest + resumable file download
    path("photo-studio/model", ps1.PhotoModelManifestView.as_view()),
    path("photo-studio/model/<str:name>", ps1.PhotoModelFileView.as_view()),
    # ---- /p2-photo ----
]
# ---- /ps1-photo ----

# ---- w1-webphoto ---- the app claims a lifeassisto.com/photo result by its
# deep-link token (login, once, <= 1h) into a Photo Studio job (normal gate).
from . import views_w1_webphoto as w1wp  # noqa: E402
urlpatterns += [
    path("web-photo/claim", w1wp.WebPhotoClaimView.as_view()),
]
# ---- /w1-webphoto ----

# ---- h1-home ---- image in chat: on-device first; detailed cloud vision answer
# funded by the ps1 ad-ticket/SSV ledger (free) or the monthly pool (paid).
from . import views_h1_home as h1  # noqa: E402
urlpatterns += [
    path("chat-vision/config", h1.ChatVisionConfigView.as_view()),
    path("chat-vision/jobs", h1.ChatVisionJobsView.as_view()),
    path("chat-vision/jobs/<int:pk>", h1.ChatVisionJobView.as_view()),
    path("chat-vision/jobs/<int:pk>/ad-ticket", h1.ChatVisionTicketView.as_view()),
    path("chat-vision/jobs/<int:pk>/fund", h1.ChatVisionFundView.as_view()),
    path("chat-vision/jobs/<int:pk>/answer", h1.ChatVisionAnswerView.as_view()),
]
# ---- /h1-home ----
# ---- f1-founders ---- in-app "Send feedback / report a problem" (own reports
# only; screenshots via signed media). Founding Members are owner-panel only.
from . import views_f1_feedback as f1fb  # noqa: E402
urlpatterns += [
    path("feedback", f1fb.FeedbackView.as_view()),
    path("feedback/<int:pk>", f1fb.FeedbackDetailView.as_view()),
]
# ---- /f1-founders ----

# ---- c3-msg ---- ticks (receipts), seen, notification pull, message info,
# mark unread, presence/typing snapshot (live presence + typing ride the
# shared rt/events queue; views_c3_msg registers its producers there).
# PREPENDED so the literal paths win over the
# circle/messages/<pk>/<action> and circle/groups/<pk>/<setting> catch-alls.
from . import views_c3_msg as c3m  # noqa: E402
urlpatterns[:0] = [
    path("circle/receipts", c3m.ReceiptsView.as_view()),
    path("circle/receipts/sync", c3m.ReceiptsSyncView.as_view()),
    path("circle/<int:pk>/seen", c3m.ChatSeenView.as_view()),
    path("circle/groups/<int:pk>/seen", c3m.GroupChatSeenView.as_view()),
    path("circle/messages/<int:pk>/info", c3m.MessageInfoView.as_view()),
    path("circle/chats/unread", c3m.ChatUnreadFlagView.as_view()),
    path("circle/notify/pull", c3m.NotifyPullView.as_view()),
    path("circle/rt/state", c3m.RtStateView.as_view()),
]
# ---- /c3-msg ----
# ---- c2-calls ---- REAL call signalling + the shared real-time event queue
# (call.* here; presence.* / typing.* producers + the presence heartbeat
# poll hook are registered by views_c3_msg).
from . import views_c2_calls as c2calls  # noqa: E402
urlpatterns += [
    path("rt/events", c2calls.RtEventsView.as_view()),
    path("rt/send", c2calls.RtSendView.as_view()),
    path("circle/calls/incoming", c2calls.IncomingCallsView.as_view()),
    path("circle/calls/<int:call_id>", c2calls.CallStatusView.as_view()),
]
# ---- /c2-calls ----
# ---- b2-badges ---- bell / Reminders-tab badge watermark (opening clears
# the badge; items stay unread until tapped; SOS/family alerts keep counting)
urlpatterns += [
    path("notif/opened", views.notif_opened),
]
# ---- /b2-badges ----

# ---- e2-keys ---- per-user public key directory: peer key lookup (live) +
# silent key_request. PREPENDED so the literal paths win over catch-alls.
from . import views_e2_keys as e2k  # noqa: E402
urlpatterns[:0] = [
    path("circle/keys/peer/<int:pk>", e2k.CirclePeerKeyView.as_view()),
    path("circle/keys/request", e2k.CircleKeyRequestView.as_view()),
    path("circle/keys/users", e2k.CircleUserKeysView.as_view()),
]
# ---- /e2-keys ----
# ---- t1-ticks ---- My Circle minimum-version gate (+ peer build banner).
from . import views_t1_ticks as t1ticks  # noqa: E402
urlpatterns[:0] = [
    path("circle/t1/gate", t1ticks.McGateView.as_view()),
]
# ---- /t1-ticks ----
# ---- b6-antitheft ---- Batch 6: native always-on Lost/Stolen engine (opt-in,
# per-phone engine token for ingestion; alerts only to owner + approved family).
from . import views_antitheft as atv  # noqa: E402
urlpatterns += [
    path("security/engine/state", atv.EngineStateView.as_view()),
    path("security/engine/enable", atv.EngineEnableView.as_view()),
    path("security/engine/disable", atv.EngineDisableView.as_view()),
    path("security/engine/settings", atv.EngineSettingsView.as_view()),
    path("security/engine/false-alarm", atv.FalseAlarmView.as_view()),
    path("security/engine/ingest", atv.EngineIngestView.as_view()),
    path("security/engine/photo", atv.EnginePhotoView.as_view()),
    path("security/engine/timeline", atv.EngineTimelineView.as_view()),
    path("security/engine/watching", atv.EngineWatchingView.as_view()),
    path("security/engine/event/<int:pk>/photo-link", atv.EnginePhotoLinkView.as_view()),
    path("security/engine/event/<int:pk>/photo", atv.EnginePhotoBytesView.as_view()),
]
# ---- /b6-antitheft ----

# ---- pay1 ---- payments: Google Play Billing + gateway (EPS), ONE
# entitlement service (core/payments/). RTDN + IPN are unauthenticated by
# DRF but verified inside (Pub/Sub OIDC/secret; gateway status API).
from . import views_pay1 as pay1  # noqa: E402
urlpatterns += [
    path("payments/config", pay1.PaymentsConfigView.as_view()),
    path("payments/state", pay1.PaymentsStateView.as_view()),
    path("payments/checkout", pay1.PaymentsCheckoutView.as_view()),
    path("payments/orders/<int:pk>", pay1.PaymentsOrderView.as_view()),
    path("payments/play/precheck", pay1.PlayPrecheckView.as_view()),
    path("payments/play/verify", pay1.PlayVerifyView.as_view()),
    path("payments/play/rtdn", pay1.PlayRtdnView.as_view()),
    path("payments/gateway/ipn", pay1.GatewayIpnView.as_view()),
]
# ---- /pay1 ----

# ---- md1 ---- My Circle E2E media blobs (ciphertext only; core/circle_blobs).
# PREPENDED so the literal circle/media/... paths always win.
from . import views_md1_media as md1  # noqa: E402
urlpatterns[:0] = [
    path("circle/media/limits", md1.MediaLimitsView.as_view()),
    path("circle/media/blobs", md1.MediaBlobsView.as_view()),
    path("circle/media/blobs/<str:ref>", md1.MediaBlobView.as_view()),
    path("circle/media/blobs/<str:ref>/finish",
         md1.MediaBlobFinishView.as_view()),
    path("circle/media/blobs/<str:ref>/url", md1.MediaBlobUrlView.as_view()),
    path("circle/media/dl/<str:ref>", md1.MediaBlobDownloadView.as_view()),
]
# ---- /md1 ----

# ---- p1-bizagent ---- Business AI Agent (webhooks are public: signature = auth)
from . import views_bizagent as p1  # noqa: E402
urlpatterns += [
    path("bizagent/webhook/meta", p1.webhook_meta),
    path("bizagent/webhook/whatsapp", p1.webhook_whatsapp),
    path("bizagent/setup", p1.SetupView.as_view()),
    path("bizagent/settings", p1.SettingsView.as_view()),
    path("bizagent/channels", p1.ChannelsView.as_view()),
    path("bizagent/channels/<int:pk>/toggle", p1.ChannelToggleView.as_view()),
    path("bizagent/channels/<int:pk>/delete", p1.ChannelDeleteView.as_view()),
    path("bizagent/couriers/<str:courier>", p1.CourierKeysView.as_view()),
    path("bizagent/approvals", p1.ApprovalsView.as_view()),
    path("bizagent/approvals/<int:pk>/approve", p1.ApprovalApproveView.as_view()),
    path("bizagent/approvals/<int:pk>/reject", p1.ApprovalRejectView.as_view()),
    path("bizagent/threads", p1.ThreadsView.as_view()),
    path("bizagent/threads/<int:pk>", p1.ThreadDetailView.as_view()),
    path("bizagent/threads/<int:pk>/handover", p1.ThreadHandoverView.as_view()),
    path("bizagent/threads/<int:pk>/send", p1.ThreadSendView.as_view()),
    path("bizagent/threads/<int:pk>/template", p1.ThreadTemplateView.as_view()),
    path("bizagent/orders/<int:pk>/book", p1.OrderBookView.as_view()),
    path("bizagent/orders/<int:pk>/status", p1.OrderStatusView.as_view()),
    path("bizagent/reports", p1.ReportsView.as_view()),
    path("bizagent/plan", p1.PlanView.as_view()),
    path("bizagent/plan/trial", p1.PlanTrialView.as_view()),
    path("bizagent/plan/checkout", p1.PlanCheckoutView.as_view()),
]
# ---- g1-bizagent ---- advanced agent: per-chat toggle, FAQ, post links, report, widget
from . import views_bizagent_g1 as g1  # noqa: E402
urlpatterns += [
    path("bizagent/threads/<int:pk>/mode", g1.ThreadModeView.as_view()),
    path("bizagent/faqs", g1.FaqsView.as_view()),
    path("bizagent/faqs/learn", g1.FaqLearnView.as_view()),
    path("bizagent/faqs/<int:pk>", g1.FaqDetailView.as_view()),
    path("bizagent/faqs/<int:pk>/delete", g1.FaqDeleteView.as_view()),
    path("bizagent/post-links", g1.PostLinksView.as_view()),
    path("bizagent/post-links/<int:pk>/delete", g1.PostLinkDeleteView.as_view()),
    path("bizagent/agent-report", g1.AgentReportView.as_view()),
    path("bizagent/widget", g1.WidgetView.as_view()),
    path("bizagent/orders/<int:pk>/payment", g1.OrderPaymentView.as_view()),
    path("bizagent/chat.js", g1.widget_js),          # embeddable website chat script
    path("bizagent/widget/<str:key>/send", g1.widget_send),
    path("bizagent/widget/<str:key>/messages", g1.widget_messages),
]
# ---- /p1-bizagent ----

# ---- p2-money ---- sponsors / app-open / offers / rewarded SSV / trial
from . import views_p2_money as p2m  # noqa: E402

urlpatterns += [
    path("ads/slot", p2m.AdsSlotView.as_view()),
    path("ads/sponsor/event", p2m.SponsorEventView.as_view()),
    path("ads/why", p2m.SponsorWhyView.as_view()),
    path("offers/prefs", p2m.OfferPrefsView.as_view()),
    path("offers/feed", p2m.OfferFeedView.as_view()),
    path("offers/brands", p2m.OfferBrandsView.as_view()),
    path("offers/brands/<int:pk>/mute", p2m.OfferBrandMuteView.as_view()),
    path("credits/rewarded/ticket", p2m.RewardTicketView.as_view()),
    path("credits/rewarded/ticket/<str:nonce>", p2m.RewardTicketStateView.as_view()),
    path("premium/offer", p2m.PremiumOfferView.as_view()),
    path("plans/trial/start", p2m.TrialStartView.as_view()),
]
# ---- /p2-money ----
# ---- p4-world ---- Unseen World: Today cards, web answers, jobs, hubs, MCQ.
from . import views_world as p4w  # noqa: E402
urlpatterns += [
    path("world/config", p4w.WorldConfigView.as_view()),
    path("world/prefs", p4w.WorldPrefsView.as_view()),
    path("world/today", p4w.WorldTodayView.as_view()),
    path("world/ask", p4w.WorldAskView.as_view()),
    path("world/jobs", p4w.WorldJobsView.as_view()),
    path("world/mcq", p4w.WorldMcqView.as_view()),
    path("world/hub/<str:hub>", p4w.WorldHubView.as_view()),
    path("world/hub/<str:hub>/ai", p4w.WorldHubAiView.as_view()),
]
# ---- /p4-world ----
# ---- cde-chat ---- order 6 D + E: shared chat theme + nicknames.
from . import views_cde as cde  # noqa: E402
urlpatterns += [
    path("circle/decor/member/<int:pk>", cde.DecorMemberView.as_view()),
    path("circle/decor/group/<int:pk>", cde.DecorGroupView.as_view()),
]
# ---- /cde-chat ----


# ---- p5-growth ---- invite-code referral, Founding seat, install ping
from . import views_p5_growth as p5g  # noqa: E402
urlpatterns += [
    path("growth/me", p5g.GrowthMeView.as_view()),
    path("growth/claim", p5g.GrowthClaimView.as_view()),
    path("growth/install", p5g.InstallPingView.as_view()),
]
# ---- /p5-growth ----

# ---- e-gaps ---- (owner order E: view-once media). PREPENDED so the literal
# path wins over the circle/messages/<pk>/<action> catch-all.
from . import views_e_gaps as egv  # noqa: E402
urlpatterns[:0] = [
    path("circle/messages/<int:pk>/view-once-open",
         egv.ViewOnceOpenView.as_view()),
    path("circle/groups/<int:pk>/organise", egv.GroupOrganiseView.as_view()),
]
# ---- /e-gaps ----

# ---- e2e-recover ---- (key recovery: peer-assisted history resend + PIN-
# sealed key-ring backup). PREPENDED so the literal paths win.
from . import views_e2e_recover as e2r  # noqa: E402
urlpatterns[:0] = [
    path("e2/backup", e2r.E2BackupView.as_view()),
    path("e2/backup/open", e2r.E2BackupOpenView.as_view()),
    path("circle/e2/resend", e2r.E2ResendPendingView.as_view()),
    path("circle/<int:pk>/e2/resend", e2r.E2ResendAskView.as_view()),
    path("circle/<int:pk>/e2/copies", e2r.E2CopiesView.as_view()),
]
# ---- /e2e-recover ----

# ---- e2e-groups ---- (peer-assisted re-share for group chats). PREPENDED
# so the literal paths win over circle/groups/<pk>/<slug:setting>.
from . import views_e2e_groups as e2g  # noqa: E402
urlpatterns[:0] = [
    path("circle/groups/<int:pk>/e2/resend", e2g.E2GroupResendAskView.as_view()),
    path("circle/groups/<int:pk>/e2/copies", e2g.E2GroupCopiesView.as_view()),
]
# ---- /e2e-groups ----

# ---- ring-everywhere ---- native delivered/ringing/decline ack (per-call
# HMAC, no account token) + never-delivered missed calls on reconnect.
# PREPENDED so the literal paths win over circle/calls/<int:call_id>.
from . import views_ring as ringv  # noqa: E402
urlpatterns[:0] = [
    path("circle/calls/<int:call_id>/ack", ringv.RingAckView.as_view()),
    path("circle/calls/missed_pending", ringv.MissedPendingView.as_view()),
]
# ---- /ring-everywhere ----
