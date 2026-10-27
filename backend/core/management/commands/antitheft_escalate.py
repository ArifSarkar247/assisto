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

    @track_job("antitheft_escalate")
    def handle(self, *args, **opts):
        from core.views_antitheft import escalate_due
        n = escalate_due()
        if n:
            self.stdout.write("antitheft_escalate: escalated=%d" % n)
