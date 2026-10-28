"""
antitheft2 — escalate held "grab" alerts whose "Are you OK?" window passed.

The owner's phone asks "Are you OK?" first (60 s). With no answer the SERVER
sends the grab to the trusted contacts (so a thief who switches the phone off
cannot stop it). An in-process timer and every engine check-in already do
this; this cron is the backstop (cheap: one indexed query). Run every minute:
  * * * * *  nice -n10 <venv>/python manage.py antitheft_escalate
"""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Escalate held anti-theft grab alerts whose confirm window passed."
    # minutejobs: a per-minute cron job needs no system checks — they import
    # the whole URLconf / every view (~0.7 s CPU per run). call_command (and
    # so minute_jobs) never ran them anyway.
    requires_system_checks = []

    @track_job("antitheft_escalate")
    def handle(self, *args, **opts):
        # minutejobs: nearly every minute nothing is due — answer that with the
        # same indexed filter escalate_due uses, without importing the views
        # module (DRF views/serializers, ~0.1 s CPU) just to get 0.
        from django.utils import timezone
        from core.models import AntiTheftEvent
        if not AntiTheftEvent.objects.filter(kind="snatch", alerted=False,
                                             escalate_at__lte=timezone.now()).exists():
            return
        from core.views_antitheft import escalate_due
        n = escalate_due()
        if n:
            self.stdout.write("antitheft_escalate: escalated=%d" % n)
