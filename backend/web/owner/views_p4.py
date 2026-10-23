"""p4-world: Owner Admin → Unseen World. Data-source status (last refresh,
errors, calls + cost today, on/off), key readiness, web-answer cost, and the
owner-entered gold/fuel prices (every edit audited)."""
from datetime import date

from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_num


def _T(request):
    from .i18n import strings
    return strings(getattr(request, "owner_lang", "bn"))


@require_http_methods(["GET", "POST"])
@owner_view()
def world(request):
    from core import world_service as W
    from core.logic import world_feeds as WF
    T = _T(request)
    ctx, status = {}, 200
    if request.method == "POST":
        action = request.POST.get("action")
        if action == "feed":
            slug = request.POST.get("slug", "")
            on = request.POST.get("on") == "1"
            try:
                before, after = W.set_feed_enabled(slug, on)
            except ValueError:
                raise Http404
            S.audit(request, request.owner, "world.feed", "world:feed:%s" % slug,
                    before={"enabled": before}, after={"enabled": after})
            return done("/owner/world")
        if action == "value":
            key = request.POST.get("key", "")
            if key not in WF.ADMIN_VALUES:
                raise Http404
            raw = request.POST.get("value", "").strip()
            val = None
            if raw:
                n = to_num(raw)
                if n is None or n <= 0 or n > 10_000_000:
                    ctx["problems"] = [T["p_invalid_number"]]
                    status = 400
                else:
                    val = n
            eff = None
            d = request.POST.get("effective_date", "").strip()
            if d and status == 200:
                try:
                    eff = date.fromisoformat(d)
                except ValueError:
                    ctx["problems"] = [T["p_invalid_number"]]
                    status = 400
            if status == 200:
                before, after = W.set_admin_value(request.owner, key, val, eff or (date.today() if val else None))
                S.audit(request, request.owner, "world.value", "world:value:%s" % key,
                        before=before, after=after)
                return done("/owner/world")
        else:
            raise Http404
    st = W.status_rows()
    lang = getattr(request, "owner_lang", "bn")
    values = []
    for r in W.admin_rows():
        meta = WF.ADMIN_VALUES[r["key"]]
        src = WF.ADMIN_SOURCES[meta[2]]
        values.append(dict(r, label=meta[0] if lang == "bn" else meta[1], url=src[2]))
    ctx.update({"feeds": st["feeds"], "keys": sorted(st["keys"].items()), "web": st["web"],
                "values": values})
    return page(request, "owner/world.html", ctx, status=status, nav="world")
