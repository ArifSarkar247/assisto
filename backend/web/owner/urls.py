from django.http import Http404, HttpResponse, HttpResponseRedirect
from django.urls import path
from pathlib import Path

from . import security as S
from . import views_auth as A
from . import views_sections as V

_ASSETS = {"owner.css": "text/css; charset=utf-8",
           "owner.js": "application/javascript; charset=utf-8"}
_DIR = Path(__file__).resolve().parent / "assets"


def asset(request, name):
    if name not in _ASSETS:
        raise Http404
    resp = HttpResponse((_DIR / name).read_bytes(), content_type=_ASSETS[name])
    S.harden(resp)
    resp["Cache-Control"] = "private, max-age=3600"
    return resp


def robots(request):
    return S.harden(HttpResponse("User-agent: *\nDisallow: /\n",
                                 content_type="text/plain; charset=utf-8"))


def site_robots(request):
    """Root /robots.txt: keep crawlers off the owner panel. l1-launch: points
    crawlers at /sitemap.xml (privacy/terms/delete-account are listed there)."""
    from django.conf import settings
    site = getattr(settings, "WEB_PUBLIC_SITE", "https://lifeassisto.com").rstrip("/")
    return HttpResponse("User-agent: *\nDisallow: /owner/\n\nSitemap: %s/sitemap.xml\n" % site,
                        content_type="text/plain; charset=utf-8")


urlpatterns = [
    path("", V.dashboard),
    path("robots.txt", robots),
    path("assets/<str:name>", asset),
    path("login", A.login_view),
    path("2fa", A.mfa_view),
    path("enrol", A.enrol_view),
    path("logout", A.logout_view),
    path("discover", V.discover_list),
    path("discover/new", V.discover_new),
    path("discover/reorder", V.discover_reorder),
    path("discover/<int:pk>", V.discover_edit),
    path("discover/<int:pk>/toggle", V.discover_toggle),
    path("discover/<int:pk>/delete", V.discover_delete),
    path("discover/<int:pk>/report", V.discover_report),
    path("discover/<int:pk>/report.<str:fmt>", V.discover_report),
    path("pricing", V.pricing),
    path("pnl", V.pnl),
    path("ads", V.ads),
    path("integrations", V.integrations),
    path("users", V.users),
    path("users/<int:pk>", V.user_detail),
    path("reports", V.reports),
    path("audit", V.audit_log),
    path("security", V.security),
]
