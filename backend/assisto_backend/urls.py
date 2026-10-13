from django.contrib import admin
from django.urls import path, include

urlpatterns = [
    path("admin/", admin.site.urls),
    path("api/v1/", include("core.urls")),
    path("api/v1/crm/", include("crm.urls")),  # app uses /api/v1 prefix (fix: was only /api/crm/)
    path("api/crm/", include("crm.urls")),
    path("crm/", include("crm.weburls")),
    path("", include("web.urls")),
]
