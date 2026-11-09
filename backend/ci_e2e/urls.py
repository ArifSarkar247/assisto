"""settings_e2e ROOT_URLCONF: the normal URLs + the CI-only outbox / tick."""
from django.urls import path

from assisto_backend.urls import urlpatterns as _base

from . import views

urlpatterns = [
    path("api/v1/ci-e2e/outbox", views.OutboxView.as_view()),
    path("api/v1/ci-e2e/tick", views.TickView.as_view()),
] + list(_base)
