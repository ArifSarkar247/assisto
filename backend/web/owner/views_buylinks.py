"""chipbuy2 (owner 3 Nov): Owner Admin -> Buy links. The owner's list of
links to his own shop asalifymart (per device type). No prices. Audited in
AdminFlagState(key="buy_links").audit and OwnerAudit "buy_links.save"."""
from django.views.decorators.http import require_http_methods

from .base import done, owner_view, page

EXTRA_ROWS = 3


@require_http_methods(["GET", "POST"])
@owner_view()
def buy_links(request):
    from core import buy_links as BL
    problems, status = [], 200
    if request.method == "POST":
        P = request.POST
        cats, tbn, ten = P.getlist("category"), P.getlist("title_bn"), P.getlist("title_en")
        urls, ons = P.getlist("url"), set(P.getlist("on"))
        rows = [{"category": cats[i] if i < len(cats) else "",
                 "title_bn": tbn[i] if i < len(tbn) else "",
                 "title_en": ten[i] if i < len(ten) else "",
                 "url": urls[i], "on": str(i) in ons} for i in range(len(urls))]
        ok, problems, before, after = BL.save(rows, actor=request.owner)
        if ok:
            from . import security as S
            S.audit(request, request.owner, "buy_links.save", "buy_links",
                    before={"items": before}, after={"items": after})
            return done("/owner/buy-links")
        status = 400
    lang = getattr(request, "owner_lang", "bn")
    from .i18n import strings
    T = strings(lang)
    cats = [(c, T["bl_cat_" + c]) for c in BL.CATEGORIES]
    rows = list(BL.items()) + [{"category": "chip", "title_bn": "", "title_en": "",
                                "url": "", "on": True}] * EXTRA_ROWS
    return page(request, "owner/buy_links.html",
                {"rows": rows, "cats": cats, "problems": problems},
                status=status, nav="buy_links")
