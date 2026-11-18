"""settings_e2eproof ROOT_URLCONF: the normal URLs + the CI-only outbox / tick."""
from django.urls import path

from assisto_backend.urls import urlpatterns as _base

from . import views

urlpatterns = [
    path("api/v1/ci-e2e/outbox", views.OutboxView.as_view()),
    path("api/v1/ci-e2e/tick", views.TickView.as_view()),
    # camflows: fake vendor clouds (E2E_VENDOR_SIM=1)
    path("api/v1/ci-e2e/vendor-sim", views.VendorSimView.as_view()),
    path("api/v1/ci-e2e/hls/<str:vendor>/<str:serial>/<str:name>", views.FakeHlsView.as_view()),
    path("api/v1/ci-e2e/imou/h5", views.FakeImouH5View.as_view()),
    path("api/v1/ci-e2e/imou/h5/allow", views.FakeImouAllowView.as_view()),
    path("api/v1/ci-e2e/sj-sim", views.SjSimView.as_view()),   # sjproof
    path("api/v1/ci-e2e/train-sim", views.TrainSimView.as_view()),   # train-e2e
    path("api/v1/ci-e2e/pay", views.FakePayView.as_view()),    # plans-credits
] + list(_base)
