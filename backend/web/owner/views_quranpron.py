"""quranpron: Owner Admin -> Quran pronunciation review queue.

Per surah / ayah an alem or qari sees the Arabic (verbatim Tanzil), the
rule-based Bangla pronunciation and its tajweed rules, and can
approve / reject with a note / request a rule correction (note + optional
suggested text). Every action is an append-only review row plus an owner
audit row. A review counts only while the engine output is unchanged."""
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

FILTERS = ("all", "under_review", "approved", "rejected", "needs_fix")


@require_http_methods(["GET"])
@owner_view()
def quran_pron(request):
    from core import quran_pron as QP
    from core import quran_pron_review as RV
    surah = to_int(request.GET.get("surah"), 1) or 1
    surah = min(114, max(1, surah))
    st = request.GET.get("status") or "all"
    if st not in FILTERS:
        st = "all"
    err = ""
    rows = []
    try:
        items = QP.surah_items(surah)
        smap = RV.status_map(surah)
        tiles = RV.counts()
    except (OSError, QP.PronError) as e:
        items, smap, tiles, err = (), {}, {}, str(e)[:200]
    for a, ar, r in items:
        e = smap.get(a, {})
        status = e.get("status", "under_review")
        if st != "all" and status != st:
            continue
        rows.append({"ayah": a, "ar": ar, "bn": r["bn"], "rules": r["rules"],
                     "status": status, "history": e.get("history", [])[:5]})
    return page(request, "owner/quran_pron.html", {
        "rows": rows, "surah": surah, "st": st, "filters": FILTERS, "err": err,
        "surahs": range(1, 115), "tiles": tiles, "engine": QP.ENGINE_VERSION,
        "bismillah": QP.bismillah_bn() if (not err and QP.has_bismillah(surah)) else "",
    }, nav="quran_pron")


@require_http_methods(["POST"])
@owner_view()
def quran_pron_act(request):
    from core import quran_pron_review as RV
    surah = to_int(request.POST.get("surah"), 0) or 0
    ayah = to_int(request.POST.get("ayah"), 0) or 0
    action = request.POST.get("action") or ""
    back = "/owner/quran-pron?surah=%d&status=%s" % (min(114, max(1, surah)),
                                                     request.POST.get("status") or "all")
    try:
        row, err = RV.record(request.owner, surah, ayah, action,
                             request.POST.get("note") or "", request.POST.get("suggestion") or "")
    except OSError:
        row, err = None, "text_unavailable"
    S.audit(request, request.owner, "quran_pron." + (action if action in RV.ACTIONS else "invalid"),
            "quran:%s:%s" % (surah, ayah), before=None,
            after={"row": row.pk if row else None, "error": err or "",
                   "note": (request.POST.get("note") or "")[:200]}, ok=not err)
    return done(back, "invalid" if err else "saved")
