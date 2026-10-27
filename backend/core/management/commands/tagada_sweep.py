"""ledger100 — scheduled tagada (due reminders), core/tagada_cron.sweep.

Every 5 minutes: due schedules → Assisto SMS (only when the owner chose it
and has credits; STOP, quiet hours and caps respected) or a push to the shop
owner "time to remind X" with one-tap send. Idempotent (conditional-update
claim per schedule); flock keeps it to one run at a time anyway.

Crontab (/etc/cron.d, every 5 minutes):
    */5 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-tagada-sweep.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py tagada_sweep --quiet >> /home/ubuntu/assisto/logs/tagada_sweep.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Scheduled tagada: Assisto SMS (credits) or a push to the owner."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true",
                            help="print only when something happened")

    @track_job("tagada_sweep")
    def handle(self, *args, **opts):
        from core import tagada_cron
        stats = tagada_cron.sweep()
        busy = {k: v for k, v in stats.items() if v and k != "looked"}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s tagada_sweep %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
