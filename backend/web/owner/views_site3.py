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
    from web import site_v3_dist as DIST
    live = V.is_live()
    status, problems = 200, []
    if request.method == "POST":
        act = request.POST.get("action")
        if act in ("golive", "rollback"):
            value = act == "golive"
            ok, payload = V.flip(request.owner.id, value)
            if ok:
                S.audit(request, request.owner, "flag.flip", "flag:%s" % V.FLAG,
                        before={V.FLAG: not live}, after={V.FLAG: not value})
                return done("/owner/website", "saved")
            problems = payload.get("problems") or []
            status = 400
        elif act in ("play_auto", "play_public", "play_hidden"):
            from core.views_build61 import flags_flip
            want = {"play_auto": {"website_play_auto": True},
                    "play_public": {"website_play_auto": False, "website_play_public": True},
                    "play_hidden": {"website_play_auto": False, "website_play_public": False}}[act]
            before = DIST.play_mode()
            for fid, val in want.items():
                ok, payload = flags_flip(request.owner.id, fid, val, "website: Play listing state set by owner (%s)" % act)
                if not ok and "no_op" not in (payload.get("problems") or []):
                    problems = payload.get("problems") or []
            if not problems:
                from django.core.cache import cache
                cache.delete(DIST.PLAY_CACHE_KEY)
                S.audit(request, request.owner, "flag.flip", "website:play_listing",
                        before={"mode": before}, after={"mode": DIST.play_mode()})
                return done("/owner/website", "saved")
            status = 400
        else:
            problems, status = ["bad_value"], 400
    return page(request, "owner/website.html",
                {"live": live, "problems": problems, "play_mode": DIST.play_mode(),
                 "play_public": DIST.play_public(), "apk": DIST.apk_info(), "apk_url": DIST.apk_url(),
                 "previews": [("/preview/", "/preview/?lang=en"), ("/preview/features/safety", "/preview/features/safety?lang=en")]},
                status=status, nav="website")
