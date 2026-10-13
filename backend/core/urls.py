from django.urls import path
from rest_framework.routers import DefaultRouter

from . import views

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
router.register("school", views.SchoolItemViewSet, basename="school")
router.register("watchers", views.WatcherViewSet, basename="watcher")

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
    path("medicines/<int:pk>/taken", views.MedicineTakenView.as_view()),
    path("medicines/today", views.MedicineTodayView.as_view()),
    path("scam/check", views.ScamCheckView.as_view()),
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
]

urlpatterns += router.urls
