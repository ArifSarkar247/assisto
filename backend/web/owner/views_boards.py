"""adminboards (owner 9 Nov): Owner Admin -> Vision checklist + Quality board.
Read-only pages over owner_actions/OWNER_VISION_CHECKLIST_BN.md and
owner_actions/QUALITY_BOARD_BN.md (parsed live, small mtime cache; no DB copy).
Owner-only (perm "owner"); every view is written to the owner audit log.
Searchable; filterable by status, launch importance and below-9."""
from django.views.decorators.http import require_http_methods

from . import boards as B
from . import security as S
from .base import owner_view, page

VISION_STATUS = ("all",) + B.STATUSES
IMPORTANCE = ("all", "1", "2", "3")
QUALITY_VIEWS = ("all", "below9", "ready")


def _q(request):
    return (request.GET.get("q") or "").strip()[:80]


def _match(q, *fields):
    if not q:
        return True
    ql = q.lower()
    return any(ql in (f or "").lower() for f in fields)


def _pick(v, allowed, default="all"):
    return v if v in allowed else default


@require_http_methods(["GET"])
@owner_view()
def vision(request):
    data = B.vision()
    q = _q(request)
    st = _pick(request.GET.get("status"), VISION_STATUS)
    imp = _pick(request.GET.get("imp"), IMPORTANCE)
    owner_only = request.GET.get("owner") == "1"
    items = []
    if data is not None:
        for it in data["items"]:
            if st != "all" and it["status"] != st:
                continue
            if imp != "all" and str(it["importance"]) != imp:
                continue
            if owner_only and not it["owner_items"].strip(" —-"):
                continue
            if not _match(q, it["feature"], it["missing"], it["plan"], it["owner_items"],
                          it["status_text"], str(it["n"])):
                continue
            items.append(it)
    quality = B.quality()
    S.audit(request, request.owner, "boards.view", target="vision")
    return page(request, "owner/boards_vision.html", {
        "data": data, "items": items, "q": q, "st": st, "imp": imp,
        "owner_only": owner_only, "statuses": VISION_STATUS, "imps": IMPORTANCE,
        "quality": quality, "shown": len(items),
    }, nav="vision")


@require_http_methods(["GET"])
@owner_view()
def quality(request):
    data = B.quality()
    q = _q(request)
    view = _pick(request.GET.get("view"), QUALITY_VIEWS)
    rows = []
    if data is not None:
        for r in data["rows"]:
            if view == "below9" and r["ready"]:
                continue
            if view == "ready" and not r["ready"]:
                continue
            if not _match(q, r["feature"], r["best_app"], r["missing"], str(r["n"])):
                continue
            rows.append(r)
        if view == "below9":
            # 7 Nov-style list: weakest first, then board order
            rows.sort(key=lambda r: (r["total"] if r["total"] is not None else -1, r["n"]))
    S.audit(request, request.owner, "boards.view", target="quality:" + view)
    return page(request, "owner/boards_quality.html", {
        "data": data, "rows": rows, "q": q, "view": view, "views": QUALITY_VIEWS,
        "pass_score": B.PASS_SCORE, "shown": len(rows),
    }, nav="quality")
