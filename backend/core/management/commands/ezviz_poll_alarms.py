"""
ezviz_poll_alarms — one polling pass over linked EZVIZ cameras' own alarms
(cashguard, owner 28 Oct). Does nothing until the owner saves the EZVIZ Open
Platform keys (Owner Admin -> Integrations) and links a camera. Real-time
push replaces this once EZVIZ approves our message subscription.
Every minute from cron:

  * * * * *  nice -n15 /home/ubuntu/assisto/.venv/bin/python /home/ubuntu/assisto/backend/manage.py ezviz_poll_alarms >/dev/null 2>&1
"""
from django.core.management.base import BaseCommand

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Poll linked EZVIZ cameras for new alarms."

    @track_job("ezviz_poll_alarms")
    def handle(self, *args, **options):
        from core.cashguard_views import poll_ezviz
        n = poll_ezviz()
        self.stdout.write("ezviz_poll_alarms: %d alarm(s)" % n)
