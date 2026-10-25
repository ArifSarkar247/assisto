"""
Business AI Agent v2 HTTP surface (under /api/v1/bizagent/), next to
views_bizagent (p1) and views_bizagent_g1:

  GET  inbox?status=agent|owner|attention&channel=&q=&unread=1
                                 Business inbox across every connected channel
  POST threads/<id>/read         mark the chat read (opening it also does)
  POST orders/<id>/confirm       owner confirms an image DRAFT order (stock −)
  POST orders/<id>/cancel        owner cancels a draft
  GET  audit                     recent agent/owner actions (owner only)
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import bizagent_guard as GD
from .business_views import _err
from .i18n import req_lang
from .views_bizagent import _ctx, _thread, _thread_row, meta_ready


class InboxView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        qp = request.query_params
        status = qp.get("status") or ""
        rows, counts = GD.inbox(prof, status=status if status in GD.STATUSES else "",
                                channel=(qp.get("channel") or "")[:20], q=qp.get("q") or "",
                                unread_only=qp.get("unread") in ("1", "true"))
        return Response({"threads": [_thread_row(t) for t, _st, _un in rows],
                         "counts": counts,
                         "features": GD.features(prof, meta_ready(), False)})


class ThreadReadView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        t = _thread(prof, pk)
        if not t:
            return _err(req_lang(request), "পাওয়া যায়নি।", "Not found.", status=404)
        GD.mark_read(t)
        return Response({"ok": True})


def _draft(prof, pk):
    from .models import Order
    return Order.objects.filter(pk=pk, business=prof, via_agent=True).first()


class DraftConfirmView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        lang = req_lang(request)
        o = _draft(prof, pk)
        if not o:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        res = GD.owner_confirm(o, actor=request.user, lang=lang)
        if not res["ok"] and res["reason"] == "not_draft":
            return _err(lang, "এটি আর খসড়া অর্ডার নয়।", "This is no longer a draft order.",
                        status=409, code="not_draft")
        if not res["ok"]:
            return _err(lang, "স্টক নেই — অর্ডার নিশ্চিত করা যায়নি।",
                        "Out of stock — the order was not confirmed.", status=409,
                        code="out_of_stock")
        return Response({"ok": True, "status": o.status})


class DraftCancelView(APIView):
    def post(self, request, pk):
        prof, role, a, bad = _ctx(request, owner=False)
        if bad:
            return bad
        lang = req_lang(request)
        o = _draft(prof, pk)
        if not o:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        res = GD.owner_cancel(o, actor=request.user)
        if not res["ok"]:
            return _err(lang, "এটি আর খসড়া অর্ডার নয়।", "This is no longer a draft order.",
                        status=409, code="not_draft")
        return Response({"ok": True, "status": o.status})


class AuditView(APIView):
    def get(self, request):
        prof, role, a, bad = _ctx(request)
        if bad:
            return bad
        return Response({"audit": GD.recent_audit(prof)})
