"""vault100 — push "your passport / trade licence / insurance ... expires in
N days" (core/vault_expiry.sweep). Type + days only, never the title, numbers
or file. Stages 60/30/7/1 days; 1 push per user per Dhaka day (several due
documents share it); quiet hours 21:00-09:00; per-document opt-out.
Idempotent (UNIQUE claim per document+stage+expiry date); flock keeps it to
one run at a time anyway. Skips cleanly when push (FCM) is not configured.

Crontab (/etc/cron.d/assisto, hourly at :20):
    20 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-vault-expiry-alerts.lock nice -n15 ionice -c3 /home/ubuntu/assisto/.venv/bin/python manage.py vault_expiry_alerts --quiet >> /home/ubuntu/assisto/logs/vault_expiry_alerts.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    help = "Vault document-expiry pushes (60/30/7/1 days; capped; quiet hours)."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true",
                            help="print only when something happened")

    @track_job("vault_expiry_alerts")
    def handle(self, *args, **opts):
        from core import push, vault_expiry
        if not push.is_available():
            if not opts.get("quiet"):
                self.stdout.write("vault_expiry_alerts: push unavailable (no key) - skipped")
            return
        stats = vault_expiry.sweep()
        busy = {k: v for k, v in stats.items() if v}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s vault_expiry_alerts %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
