from django.contrib import admin
from django.urls import path, include
from django.http import JsonResponse


def root(_request):
    return JsonResponse({"app": "Assisto", "api": "/api/v1/"})


urlpatterns = [
    path("", root),
    path("admin/", admin.site.urls),
    path("api/v1/", include("core.urls")),
]
