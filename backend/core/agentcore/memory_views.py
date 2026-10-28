"""Life-graph memory API (/api/v1/agent-core/memory...), flag `agent_core`
(OFF -> 403 feature_off, like every agent-core endpoint). Token auth; every
query is filtered by request.user — a user only ever sees their own graph.

  GET    agent-core/memory?type=&status=active|suggested   facts + counts + prefs
  POST   agent-core/memory                  {type,label,value,relation?,when?,sensitive?,use_in_ai?}
  GET    agent-core/memory/<id>
  PATCH  agent-core/memory/<id>             any of the fields above
  DELETE agent-core/memory/<id>
  POST   agent-core/memory/<id>/approve     a suggestion -> a fact (or applies an update)
  POST   agent-core/memory/<id>/reject      a suggestion -> wiped (never proposed again)
  POST   agent-core/memory/<id>/confirm     "still right?" -> yes
  POST   agent-core/memory/delete-all       {confirm: "DELETE"} -> every row really deleted
  GET    agent-core/memory/export           JSON attachment for the user's own download
  GET/POST agent-core/memory/prefs          {learning_paused, retention_months}
"""
from django.http import HttpResponse
from rest_framework.response import Response

from ..i18n import pick, req_lang
from . import memory as MEM
from .views import _Gated

_ERR = {
    "not_found": ("পাওয়া যায়নি।", "Not found."),
    "bad_type": ("ধরন বেছে নিন।", "Choose a type."),
    "empty": ("কিছু লিখুন।", "Write something."),
    "secret_refused": ("পাসওয়ার্ড, পিন, OTP বা কার্ডের গোপন নম্বর মেমরিতে রাখা যায় না — এগুলো কাউকে দেবেন না।",
                       "Passwords, PINs, OTPs and card secrets can never be saved in memory — never share them."),
    "id_refused": ("NID, কার্ড বা অ্যাকাউন্ট নম্বর মেমরিতে রাখা যায় না — এগুলো ডকুমেন্ট ভল্টে রাখুন।",
                   "NID, card or account numbers can't be saved in memory — keep them in the Document Vault."),
    "memory_full": ("মেমরি পূর্ণ — কিছু পুরনো তথ্য মুছুন।", "Memory is full — delete some old facts."),
    "confirm_needed": ("সব মুছতে নিশ্চিত করুন।", "Confirm to delete everything."),
    "bad_input": ("তথ্যগুলো ঠিক নেই।", "Some details are not right."),
}


def _err(lang, code, status=400):
    bn, en = _ERR.get(code, _ERR["bad_input"])
    return Response({"error": code, "detail": pick(lang, bn, en)}, status=status)


class _MemGated(_Gated):
    def handle_exception(self, exc):
        if isinstance(exc, MEM.MemoryError_):
            return _err(req_lang(self.request), exc.code, exc.status)
        return super().handle_exception(exc)


def _body(request):
    return request.data if isinstance(request.data, dict) else {}


class MemoryListView(_MemGated):
    def get(self, request):
        q = request.query_params
        kind = q.get("type") or ""
        if kind and kind not in MEM.TYPES:
            kind = ""
        return Response(MEM.listing(request.user, req_lang(request), kind=kind,
                                    status=q.get("status") or "active"))

    def post(self, request):
        return Response(MEM.create_fact(request.user, _body(request), req_lang(request)), status=201)


class MemoryItemView(_MemGated):
    def get(self, request, pk):
        return Response(MEM.fact_out(MEM._get(request.user, pk), req_lang(request)))

    def patch(self, request, pk):
        return Response(MEM.update_fact(request.user, pk, _body(request), req_lang(request)))

    def delete(self, request, pk):
        MEM.delete_fact(request.user, pk)
        return Response(status=204)


class MemoryActionView(_MemGated):
    def post(self, request, pk, action):
        lang = req_lang(request)
        if action == "approve":
            return Response(MEM.approve(request.user, pk, lang))
        if action == "reject":
            MEM.reject(request.user, pk)
            return Response({"ok": True})
        if action == "confirm":
            return Response(MEM.confirm_fact(request.user, pk, lang))
        return _err(lang, "not_found", 404)


class MemoryDeleteAllView(_MemGated):
    def post(self, request):
        if str(_body(request).get("confirm") or "") != "DELETE":
            return _err(req_lang(request), "confirm_needed")
        return Response({"ok": True, "deleted": MEM.delete_all(request.user)})


class MemoryExportView(_MemGated):
    def get(self, request):
        data = MEM.export(request.user, req_lang(request))
        resp = HttpResponse(MEM.json_bytes(data), content_type="application/json; charset=utf-8")
        resp["Content-Disposition"] = 'attachment; filename="assisto-life-graph.json"'
        resp["Cache-Control"] = "no-store"
        return resp


class MemoryPrefsView(_MemGated):
    def get(self, request):
        return Response(MEM.prefs_out(MEM.prefs_for(request.user)))

    def post(self, request):
        return Response(MEM.set_prefs(request.user, _body(request)))
