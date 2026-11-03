"""p3docs (runs inside `manage.py minute_jobs`, no own cron line) — delete the ciphertext of vault share links that can never open
again (expired / used up / revoked). Links also purge lazily on use; this
cron catches links nobody opens. Safe to run any time (idempotent)."""
from django.core.management.base import BaseCommand

from core import vault_e2e
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Delete ciphertext of expired / used / revoked vault share links."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("vault_share_purge")
    def handle(self, *args, **opts):
        total = 0
        while True:
            n = vault_e2e.purge_shares(limit=200)
            total += n
            if n < 200:
                break
        if not opts.get("quiet"):
            self.stdout.write("purged %d" % total)
