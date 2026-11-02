"""sitev3: Owner Admin → Website. The go-live switch for website v3.

GET  /owner/website  → state (current site / new site live), preview links
POST /owner/website  → action=golive | rollback  (one tap each; audited in
                       AdminFlagState.audit and OwnerAudit "flag.flip")
"""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page


@require_http_methods(["GET", "POST"])
@owner_view()
def website(request):
    from web import views_site3 as V
    live = V.is_live()
    status, problems = 200, []
    if request.method == "POST":
        act = request.POST.get("action")
        if act in ("golive", "rollback"):
            value = act == "golive"
            ok, payload = V.flip(request.owner.id, value)
            if ok:
                S.audit(request, request.owner, "flag.flip", "flag:%s" % V.FLAG,
                        before={V.FLAG: live}, after={V.FLAG: value})
                return done("/owner/website", "saved")
            problems = payload.get("problems") or []
            status = 400
        else:
            problems, status = ["bad_value"], 400
    return page(request, "owner/website.html",
                {"live": live, "problems": problems,
                 "previews": [("/preview/", "/preview/?lang=en"), ("/preview/features/safety", "/preview/features/safety?lang=en")]},
                status=status, nav="website")
