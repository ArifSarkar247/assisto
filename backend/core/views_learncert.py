"""learncert — app API for the Assisto Learning Certificate (flag
`learning_certificate`, OFF until the owner's real-phone proof).

  GET  /learn/certs                    {items:[card], default_name, enabled}
  POST /learn/certs/claim              {token, name?}  -> card (201 new / 200 existing)
  GET  /learn/certs/<id>               card
  GET  /learn/certs/<id>/pdf?lang=bn   application/pdf
  POST /learn/certs/<id>/revoke        the owner of the certificate revokes it
  POST /learn/certs/revoke-code        {code}  staff only (abuse reports)

`token` comes from core.learn_cert.result_token(...) in the Language
Partner / Quran reading server code — the app can never mint a certificate
on its own. The public check page is web.views_learncert (/verify/<code>).
"""
from django.http import HttpResponse
from rest_framework.permissions import IsAdminUser
from rest_framework.response import Response
from rest_framework.views import APIView

from . import learn_cert as LC
from .i18n import req_lang

R = Response


def flag_on(user):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(LC.FLAG, user))
    except Exception:  # noqa: BLE001
        return False


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _mine(request, pk):
    return LC._rows(request.user).filter(pk=pk).first()


class CertListView(APIView):
    def get(self, request):
        if not flag_on(request.user):
            return _off()
        lang = req_lang(request)
        items = [LC.as_dict(r, lang) for r in LC._rows(request.user)]
        return R({"ok": True, "items": items,
                  "default_name": getattr(request.user, "name", "") or ""})


class CertClaimView(APIView):
    def post(self, request):
        if not flag_on(request.user):
            return _off()
        try:
            course, level, score = LC.read_token(request.user, request.data.get("token"))
            before = LC._rows(request.user).count()
            row = LC.issue_certificate(request.user, course, level, score,
                                       name=request.data.get("name") or None)
        except LC.CertError as e:
            return R({"ok": False, "reason": e.reason}, status=400)
        created = LC._rows(request.user).count() > before
        return R({"ok": True, "created": created, "cert": LC.as_dict(row, req_lang(request))},
                 status=201 if created else 200)


class CertDetailView(APIView):
    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        row = _mine(request, pk)
        if row is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        return R({"ok": True, "cert": LC.as_dict(row, req_lang(request))})


class CertPdfView(APIView):
    def get(self, request, pk):
        if not flag_on(request.user):
            return _off()
        row = _mine(request, pk)
        if row is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        lang = request.query_params.get("lang")
        lang = lang if lang in ("bn", "en") else req_lang(request)
        resp = HttpResponse(LC.pdf_bytes(row, lang), content_type="application/pdf")
        resp["Content-Disposition"] = 'attachment; filename="assisto-certificate-%s.pdf"' % (
            (row.data or {}).get("code") or row.id)
        resp["Cache-Control"] = "no-store"
        return resp


class CertRevokeView(APIView):
    def post(self, request, pk):
        if not flag_on(request.user):
            return _off()
        row = _mine(request, pk)
        if row is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        LC.revoke(row, by="holder")
        return R({"ok": True, "cert": LC.as_dict(row, req_lang(request))})


class CertRevokeCodeView(APIView):
    permission_classes = [IsAdminUser]

    def post(self, request):
        row = LC.find(request.data.get("code"))
        if row is None:
            return R({"ok": False, "reason": "not_found"}, status=404)
        LC.revoke(row, by="staff:%s" % request.user.pk)
        return R({"ok": True, "code": (row.data or {}).get("code"), "valid": False})
