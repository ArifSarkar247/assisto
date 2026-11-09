"""CI-only endpoints (mounted by ci_e2e.urls under settings_e2eproof ONLY).

GET  /api/v1/ci-e2e/outbox?since=<ts>&kind=push|sms|ai|vision|maps&user=me|<id>
     -> {now, rows:[...]}   what the fakes "sent" (proof of delivery)
POST /api/v1/ci-e2e/tick {job, advance_min}
     -> runs one real server job with the clock moved forward (fake clock):
        job = push_due_reminders | carecall_tick | journey_sweep
              | ezviz_poll_alarms | cctv_connect_tick (camflows)
camflows (E2E_VENDOR_SIM=1, see vendor_sim.py):
POST /api/v1/ci-e2e/vendor-sim {op: add_device|push_alarm|state, vendor, serial, ...}
GET  /api/v1/ci-e2e/hls/<vendor>/<serial>/<file>   the fake vendor HLS (phone plays it)
GET  /api/v1/ci-e2e/imou/h5?state=                 the fake Imou consent page
GET  /api/v1/ci-e2e/imou/h5/allow?state=           "Allow" -> our real redirect URI
"""
import io
import threading
import time
from datetime import timedelta
from unittest import mock

from django.core.management import call_command, get_commands
from django.utils import timezone
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import fakes

JOBS = ("push_due_reminders", "carecall_tick", "journey_sweep",
        "ezviz_poll_alarms", "cctv_connect_tick")  # camflows: the two CCTV cloud jobs
_TICK_LOCK = threading.Lock()


class OutboxView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        q = request.query_params
        try:
            since = float(q.get("since") or 0)
        except ValueError:
            since = 0.0
        who = q.get("user") or ""
        uid = request.user.pk if who == "me" else (int(who) if who.isdigit() else None)
        return Response({"now": time.time(),
                         "rows": fakes.read_outbox(since, q.get("kind") or "", uid)[-200:]})


class TickView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        job = str((request.data or {}).get("job") or "")
        if job not in JOBS:
            return Response({"ok": False, "reason": "unknown_job", "jobs": JOBS}, status=400)
        if job not in get_commands():
            return Response({"ok": False, "reason": "job_missing", "job": job}, status=404)
        try:
            adv = max(0, min(24 * 60, int((request.data or {}).get("advance_min") or 0)))
        except (TypeError, ValueError):
            adv = 0
        real_now = timezone.now
        fake_now = real_now() + timedelta(minutes=adv)
        out = io.StringIO()
        with _TICK_LOCK, mock.patch("django.utils.timezone.now", lambda: fake_now):
            call_command(job, stdout=out, stderr=out)
        fakes.record("tick", job=job, advance_min=adv, fake_now=fake_now.isoformat(),
                     out=out.getvalue()[-400:])
        return Response({"ok": True, "job": job, "fake_now": fake_now.isoformat(),
                         "output": out.getvalue()[-400:]})


# ---------------------------------------------------------------- camflows
class VendorSimView(APIView):
    """The test's handle on the fake vendor clouds (devices, alarms, state)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from . import vendor_sim as VS
        d = request.data or {}
        op = str(d.get("op") or "")
        vendor = str(d.get("vendor") or "")
        serial = str(d.get("serial") or "").upper()
        if vendor not in ("imou", "ezviz", "dolynk", "hikconnect") or not serial:
            return Response({"ok": False, "reason": "vendor_serial"}, status=400)
        if op == "add_device":
            out = VS.add_device(vendor, serial, str(d.get("code") or ""),
                                int(d.get("channels") or 1), d.get("name") or None,
                                bool(d.get("oauth_user")))
        elif op == "push_alarm":
            try:
                out = VS.push_alarm(vendor, serial, int(d.get("channel") or 0),
                                    str(d.get("kind") or "human"), str(d.get("deliver") or "store"))
            except KeyError:
                return Response({"ok": False, "reason": "unknown_device"}, status=404)
        elif op == "state":
            out = VS.state(vendor, serial)
        else:
            return Response({"ok": False, "reason": "unknown_op"}, status=400)
        fakes.record("vendor_sim", op=op, vendor=vendor, serial=serial, out=out)
        return Response(dict(out, ok=True))


class FakeHlsView(APIView):
    """A real HLS stream (ffmpeg test pattern in E2E_HLS_DIR) at the address
    the fake vendor cloud handed out. Every fetch is recorded: proof that the
    phone's player really opened the vendor stream."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request, vendor, serial, name):
        import os
        from django.http import HttpResponse, Http404
        from . import vendor_sim as VS
        base = os.environ.get("E2E_HLS_DIR", "")
        fn = "index.m3u8" if name.endswith(".m3u8") else name
        if not base or "/" in fn or ".." in fn:
            raise Http404()
        path = os.path.join(base, fn)
        if not os.path.isfile(path):
            raise Http404()
        VS.HITS["hls"].append("%s/%s/%s" % (vendor, serial.upper(), name))
        with open(path, "rb") as fh:
            body = fh.read()
        ctype = "application/vnd.apple.mpegurl" if fn.endswith(".m3u8") else "video/mp2t"
        resp = HttpResponse(body, content_type=ctype)
        resp["Cache-Control"] = "no-store"
        return resp


def _imou_redirect_uri():
    from django.conf import settings
    from core.logic.cctv_connect.imou import ImouAdapter
    return str(settings.ASSISTO_BASE_URL).rstrip("/") + ImouAdapter.oauth_redirect_path


class FakeImouH5View(APIView):
    """Stand-in for Imou's "User Authorization H5 Page" (the browser leg)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from django.http import HttpResponse
        from django.utils.html import escape
        state = str(request.query_params.get("state") or "")[:128]
        html = ("<!doctype html><meta charset=utf-8><title>Imou Life (CI fake)</title>"
                "<h1>Imou Life</h1><p>Assisto Camera Link wants to see your cameras "
                "(device info, live, messages).</p>"
                "<a id=allow href='/api/v1/ci-e2e/imou/h5/allow?state=%s'>Allow</a> "
                "<a id=deny href='%s?error=access_denied&state=%s'>Deny</a>"
                % (escape(state), escape(_imou_redirect_uri()), escape(state)))
        return HttpResponse(html)


class FakeImouAllowView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from urllib.parse import urlencode
        from django.http import HttpResponseRedirect
        from . import vendor_sim as VS
        state = str(request.query_params.get("state") or "")[:128]
        code = VS.new_oauth_code()
        fakes.record("imou_h5_allow", state_len=len(state))
        return HttpResponseRedirect("%s?%s" % (_imou_redirect_uri(),
                                               urlencode({"code": code, "state": state})))
