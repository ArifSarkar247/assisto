"""Career endpoints (p2career; flag career_plus, OFF until proven).

GET  career/status                    flags + AI/Careerjet readiness + roles/formats/portals
GET  career/cv/prefill                profile -> CV header (name/phone/email)
GET  career/cv/ats                    rule-based ATS checklist of the saved CV
GET  career/cv/pdf                    ATS-friendly English PDF (Bangla -> print page)
POST career/cv/print-link {lang}      signed 30-min print page URL (any language)
GET  career/cv/print/<token>          the printable page (token = auth; no login)
POST career/cv/polish {lang}          AI polish via the router (credits, never invents)
GET  career/jobs/search?q=&loc=       Careerjet partner API + the user's company feeds
POST career/jobs/sources/test         check a Greenhouse / Lever / RSS source before saving
POST career/jobs/deadline             set/clear deadline reminders for a tracked job
GET  career/interview/roles[/<id>]    role-based question sets
POST career/interview/feedback        rubric (always) + optional AI feedback
"""
from datetime import date

from django.http import HttpResponse
from rest_framework.response import Response
from rest_framework.views import APIView

from . import career_service as S
from .i18n import is_play_flavour, pick, req_lang
from .logic import career_content as CC


def _off(request):
    if S.flag_on(request.user, is_play_flavour(request)):
        return None
    return Response({"detail": pick(req_lang(request), "এই সুবিধা এখনো চালু হয়নি।",
                                    "This feature is not switched on yet."),
                     "enabled": False}, status=403)


class CareerStatusView(APIView):
    def get(self, request):
        from . import ai
        from . import world_service as WS
        from .logic import world_content as WC
        lang = req_lang(request)
        pub = WC.jobs_public(lang)
        return Response({
            "enabled": S.flag_on(request.user, is_play_flavour(request)),
            "ai_ready": bool(ai.available()),
            "careerjet_ready": bool(WS.careerjet_ready()),
            "formats": list(CC.CV_FORMATS), "cv_langs": list(CC.CV_LANGS),
            "roles": CC.roles_public(lang),
            "portals": pub["portals"], "safety": pub["safety"], "feeds_note": pub["feeds_note"],
            "ai_caps": {"interview": S.AI_INTERVIEW_DAILY_CAP, "polish": S.AI_POLISH_DAILY_CAP},
        })


class CvPrefillView(APIView):
    def get(self, request):
        return _off(request) or Response(S.prefill(request.user))


class CvAtsView(APIView):
    def get(self, request):
        off = _off(request)
        if off:
            return off
        row = S.cv_row(request.user)
        if row is None:
            return Response({"detail": "no_cv"}, status=404)
        return Response(CC.ats_check(CC.normalize_cv(row)))


class CvPdfView(APIView):
    def get(self, request):
        off = _off(request)
        if off:
            return off
        lang = request.query_params.get("lang", "en")
        if lang == "bn":
            return Response({"use_print": True, "detail": pick(
                req_lang(request),
                "বাংলা সিভির জন্য প্রিন্ট পাতা খুলুন → PDF হিসেবে সেভ করুন।",
                "For a Bangla CV open the print page → Save as PDF.")}, status=400)
        row = S.cv_row(request.user)
        if row is None:
            return Response({"detail": "no_cv"}, status=404)
        resp = HttpResponse(S.cv_pdf(row, "en"), content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="cv.pdf"'
        resp["Cache-Control"] = "no-store"
        return resp


class CvPrintLinkView(APIView):
    def post(self, request):
        off = _off(request)
        if off:
            return off
        if S.cv_row(request.user) is None:
            return Response({"detail": "no_cv"}, status=404)
        lang = "bn" if request.data.get("lang") == "bn" else "en"
        token = S.print_token(request.user, lang)
        return Response({"url": request.build_absolute_uri("/api/v1/career/cv/print/" + token),
                         "path": "/career/cv/print/" + token,
                         "expires_in": S.PRINT_TTL_S})


def cv_print_page(request, token):
    """Plain Django view: the signed token is the only credential."""
    from .models import User
    uid, lang = S.read_print_token(token)
    user = User.objects.filter(pk=uid, is_active=True).first() if uid else None
    row = S.cv_row(user) if user is not None else None
    if user is None or row is None or not S.flag_on(user):
        return HttpResponse("Link expired / লিংকের মেয়াদ শেষ", status=410,
                            content_type="text/plain; charset=utf-8")
    resp = HttpResponse(S.print_html(row, lang), content_type="text/html; charset=utf-8")
    resp["Cache-Control"] = "no-store"
    resp["X-Robots-Tag"] = "noindex, nofollow"
    resp["Referrer-Policy"] = "no-referrer"
    return resp


class CvPolishView(APIView):
    def post(self, request):
        off = _off(request)
        if off:
            return off
        row = S.cv_row(request.user)
        if row is None:
            return Response({"detail": "no_cv"}, status=404)
        lang = "bn" if request.data.get("lang", req_lang(request)) == "bn" else "en"
        return Response(S.polish_cv(request.user, row, lang))


class JobSearchView(APIView):
    def get(self, request):
        off = _off(request)
        if off:
            return off
        return Response(S.search(request.user, request.query_params.get("q", "")[:120],
                                 request.query_params.get("loc", "")[:60]))


class JobSourceTestView(APIView):
    def post(self, request):
        off = _off(request)
        if off:
            return off
        lang = req_lang(request)
        kind = request.data.get("kind", "")
        value = str(request.data.get("value", ""))[:500]
        try:
            S.source_url(kind, value)
        except ValueError as e:
            return Response({"ok": False, "error": str(e), "detail": pick(
                lang, "ঠিকানাটা ঠিক নয় — উদাহরণ দেখে আবার লিখুন।",
                "That does not look right — check the example and try again.")}, status=400)
        if kind == "link":
            return Response({"ok": True, "count": 0, "sample": [], "link_only": True})
        try:
            return Response(S.test_source(kind, value, request.data.get("label", "")))
        except Exception:  # noqa: BLE001
            return Response({"ok": False, "error": "failed", "detail": pick(
                lang, "এই উৎস থেকে চাকরি পড়া গেল না — নাম/লিংক ঠিক আছে কিনা দেখুন।",
                "Could not read jobs from this source — check the name/link.")})


class JobDeadlineView(APIView):
    def post(self, request):
        off = _off(request)
        if off:
            return off
        title = str(request.data.get("title", "")).strip()
        ref = str(request.data.get("ref", "")).strip()
        raw = str(request.data.get("deadline", "")).strip()
        if not title or not ref:
            return Response({"detail": "title_ref_required"}, status=400)
        d = None
        if raw:
            try:
                d = date.fromisoformat(raw[:10])
            except ValueError:
                return Response({"detail": "bad_date"}, status=400)
        return Response({"reminders": S.set_deadline(request.user, title, d, ref)})


class InterviewRolesView(APIView):
    def get(self, request, role=None):
        off = _off(request)
        if off:
            return off
        lang = request.query_params.get("lang") or req_lang(request)
        if role is None:
            return Response({"roles": CC.roles_public(lang)})
        out = CC.role_questions(role, lang)
        if out is None:
            return Response({"detail": "unknown_role"}, status=404)
        return Response(out)


class InterviewFeedbackView(APIView):
    def post(self, request):
        off = _off(request)
        if off:
            return off
        lang = "bn" if request.data.get("lang", req_lang(request)) == "bn" else "en"
        out = S.interview_feedback(request.user, str(request.data.get("qid", "")),
                                   str(request.data.get("answer", ""))[:6000], lang,
                                   want_ai=bool(request.data.get("ai")))
        if out is None:
            return Response({"detail": "unknown_question"}, status=404)
        return Response(out)
