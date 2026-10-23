from django.contrib import admin
from django.urls import path, include

from core.views_bizagent_g1 import widget_js   # g1: website chat widget script

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/v1/", include("core.urls")),
    path("api/v1/crm/", include("crm.urls")),  # app uses /api/v1 prefix (fix: was only /api/crm/)
    path("api/crm/", include("crm.urls")),
    path("crm/", include("crm.weburls")),
    path("w/chat.js", widget_js),   # g1: embeddable chat widget (served from our domain)
    path("", include("web.urls")),
]
