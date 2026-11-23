from django.contrib import admin
from django.urls import path, include

from core import views_halaladz as _hzv  # halaladz

urlpatterns = [
    path("admin/", admin.site.urls),
    # halaladz: HalalAdz -> Assisto webhook at EXACTLY this path (the order
    # names it); every other API lives under /api/v1/. HMAC-signed, no token.
    path("api/integrations/halaladz/notify", _hzv.HalalAdzNotifyView.as_view()),
    path("api/v1/", include("core.urls")),
    path("api/v1/crm/", include("crm.urls")),  # app uses /api/v1 prefix (fix: was only /api/crm/)
    path("api/crm/", include("crm.urls")),
    path("crm/", include("crm.weburls")),
    path("", include("web.urls")),
]
