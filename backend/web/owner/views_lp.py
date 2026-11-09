"""lpcore (owner 9 Nov 21:45, part G): Owner Admin -> Language content.
The review queue of Language Partner items (mocks, sections, questions,
life scenarios, vocabulary): automatic-check results, approve / reject /
re-check / edit (JSON, saved as a NEW version). Every action goes to the
item's review log and the owner audit log. Moderators may review too, so
the owner can add IELTS / language reviewers later without full access."""
import json

from django.http import Http404
from django.views.decorators.http import require_http_methods

from . import security as S
from .base import done, owner_view, page, to_int

_PAGE = 30
FILTERS = ("queue", "draft", "ai_checked", "human_approved", "rejected", "all")
KINDS = ("all", "mock", "section", "question", "scenario", "vocab")


@require_http_methods(["GET"])
@owner_view(perm="reports")
def lp_review(request):
    from core.models import LpItem, LpReviewLog
    st = request.GET.get("status") or "queue"
    st = st if st in FILTERS else "queue"
    kind = request.GET.get("kind") or "all"
    kind = kind if kind in KINDS else "all"
    qs = LpItem.objects.all()
    if st == "queue":
        qs = qs.filter(status__in=("draft", "ai_checked"))
    elif st != "all":
        qs = qs.filter(status=st)
    if kind != "all":
        qs = qs.filter(kind=kind)
    pg = max(1, to_int(request.GET.get("page"), 1) or 1)
    total = qs.count()
    rows = list(qs.order_by("status", "-updated_at")[(pg - 1) * _PAGE: pg * _PAGE])
    logs = {}
    for lg in LpReviewLog.objects.filter(item__in=rows).select_related("actor").order_by("-id")[:300]:
        logs.setdefault(lg.item_id, []).append(lg)
    for r in rows:
        r.log_rows = logs.get(r.id, [])[:6]
        r.json_text = json.dumps(r.data, ensure_ascii=False, indent=1)[:60000]
        r.fail_rows = (r.checks or {}).get("failures") or []
    tiles = [(s, LpItem.objects.filter(status=s).count()) for s in LpItem.STATUSES]
    return page(request, "owner/lp_review.html", {
        "rows": rows, "st": st, "kind": kind, "total": total, "page_no": pg,
        "has_next": pg * _PAGE < total, "tiles": tiles, "filters": FILTERS, "kinds": KINDS,
    }, nav="lp")


@require_http_methods(["POST"])
@owner_view(perm="reports")
def lp_review_action(request, pk):
    from core import lp_service as LS
    from core.models import LpItem
    item = LpItem.objects.filter(pk=pk).first()
    if item is None:
        raise Http404
    action = request.POST.get("action") or ""
    back = "/owner/lp?status=%s&kind=%s" % (request.POST.get("status") or "queue",
                                             request.POST.get("kind") or "all")
    if action not in LS.REVIEW_ACTIONS:
        return done(back, "invalid")
    data = None
    if action == "edit":
        try:
            data = json.loads(request.POST.get("data") or "")
        except ValueError:
            return done(back, "invalid")
    before = {"status": item.status, "version": item.version}
    new, err = LS.review(item, action, request.owner, (request.POST.get("note") or "")[:300], data)
    S.audit(request, request.owner, "lp_item." + action, "lp_item:%s" % item.key,
            before=before, after={"status": new.status, "version": new.version, "error": err or ""},
            ok=not err)
    return done(back, "invalid" if err else "saved")
