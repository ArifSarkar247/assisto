"""
WP-BIZBUILDER — business agent builder HTTP surface (/api/v1/bizagent/builder/…).
Shop OWNER only (staff may read the takeover inbox); behind the existing
`business_agent` flag.

  GET  builder                 card state: live + draft + versions + catalog + AI cost + hard rules
  POST builder/parse  {form}   parse only (what the agent understood / refused), nothing saved
  POST builder/draft  {form}   save the draft card
  POST builder/draft/discard
  POST builder/publish         draft → live (syncs tone/hours/delivery/min prices)
  POST builder/rollback {version}
  POST builder/preview {samples?, form?}      how the agent would reply (rules only, nothing sent)
  POST builder/test {session, text, allow_ai?, use?, reset?}   test chat (nothing sent)
  GET  builder/inbox           takeover inbox: chats that need you / that you hold
"""
from rest_framework.exceptions import PermissionDenied
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import bizbuilder_service as BBS
from .business_views import _err, _owner_only, _require_business
from .i18n import is_play_flavour, req_lang
from .logic import bizbuilder as BB
from .logic import business_ai as bai


class _Builder(APIView):
    permission_classes = [IsAuthenticated]
    owner = True

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        try:
            from . import feature_flags as FF
            on = FF.is_on(BBS.FLAG, request.user, is_play_flavour(request))
        except Exception:  # noqa: BLE001
            on = False
        if not on:
            raise PermissionDenied(detail={"error": "feature_off", "detail": bai.pick(
                req_lang(request), "এই সুবিধা এখন বন্ধ আছে।", "This feature is off right now.")})

    @property
    def lang(self):
        return req_lang(self.request)

    def biz(self, request):
        prof, role, bad = _require_business(request)
        if bad:
            return None, bad
        if self.owner:
            g = _owner_only(request, role)
            if g:
                return None, g
        return prof, None

    def form(self, request):
        f = (request.data or {}).get("form")
        return f if isinstance(f, dict) else None


class BuilderStateView(_Builder):
    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        return Response(BBS.state(prof, request.user, self.lang))


class BuilderParseView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        f = self.form(request)
        if f is None:
            return _err(self.lang, "ফর্ম পাওয়া যায়নি।", "No form sent.", status=422, code="no_form")
        card = BBS.build(prof, BBS.clean_form(f))
        return Response({"card": card, "summary": BB.summary(card, self.lang),
                         "understood": card["understood"], "rejected": card["rejected"],
                         "warnings": card["warnings"]})


class BuilderDraftView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        f = self.form(request)
        if f is None:
            return _err(self.lang, "ফর্ম পাওয়া যায়নি।", "No form sent.", status=422, code="no_form")
        row = BBS.save_draft(prof, request.user, f)
        return Response({"ok": True, "draft": BBS._row_out(row, self.lang)})


class BuilderDiscardView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        return Response({"ok": True, "deleted": BBS.discard_draft(prof)})


class BuilderPublishView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        row = BBS.publish(prof, request.user)
        if row is None:
            return _err(self.lang, "প্রকাশ করার মতো খসড়া নেই — আগে সেভ করুন।",
                        "There is no draft to publish — save it first.", status=409, code="no_draft")
        return Response({"ok": True, "live": BBS._row_out(row, self.lang)})


class BuilderRollbackView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        try:
            v = int((request.data or {}).get("version"))
        except (TypeError, ValueError):
            return _err(self.lang, "ভার্সন নম্বর দিন।", "Give a version number.", status=422,
                        code="bad_version")
        row = BBS.rollback(prof, request.user, v)
        if row is None:
            return _err(self.lang, "এই ভার্সন পাওয়া যায়নি।", "Version not found.", status=404,
                        code="not_found")
        return Response({"ok": True, "live": BBS._row_out(row, self.lang)})


class BuilderPreviewView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        samples = (request.data or {}).get("samples")
        if samples is not None and not isinstance(samples, list):
            return _err(self.lang, "নমুনা মেসেজ তালিকা দিন।", "Send samples as a list.", status=422,
                        code="bad_samples")
        out = BBS.preview(prof, request.user, samples, form=self.form(request), lang=self.lang)
        return Response({"results": out["results"], "sent": 0})


class BuilderTestView(_Builder):
    def post(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        d = request.data or {}
        session = str(d.get("session") or "")[:40]
        if not session:
            return _err(self.lang, "সেশন দরকার।", "A session id is needed.", status=422,
                        code="no_session")
        text = str(d.get("text") or "")[:BB.MAX_A]
        use = "live" if d.get("use") == "live" else "draft"
        out = BBS.test_chat(prof, request.user, session, text, allow_ai=bool(d.get("allow_ai")),
                            use=use, reset=bool(d.get("reset")), lang=self.lang)
        out["sent"] = 0
        return Response(out)


class BuilderInboxView(_Builder):
    owner = False

    def get(self, request):
        prof, bad = self.biz(request)
        if bad:
            return bad
        return Response(BBS.takeover_inbox(prof, self.lang))
