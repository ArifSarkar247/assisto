"""CI-only endpoints (mounted by ci_e2e.urls under settings_e2e ONLY).

GET  /api/v1/ci-e2e/outbox?since=<ts>&kind=push|sms|ai|vision|maps&user=me|<id>
     -> {now, rows:[...]}   what the fakes "sent" (proof of delivery)
POST /api/v1/ci-e2e/tick {job, advance_min}
     -> runs one real server job with the clock moved forward (fake clock):
        job = push_due_reminders | carecall_tick | journey_sweep
"""
import io
import threading
import time
from datetime import timedelta
from unittest import mock

from django.core.management import call_command, get_commands
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import fakes

JOBS = ("push_due_reminders", "carecall_tick", "journey_sweep")
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
