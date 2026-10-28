"""ops-watch: every 5 minutes — is every scheduled job running on time and
succeeding, is every system service up, is the 7-day crash / ANR rate under
the owner's bars, is the monthly backup-restore drill done? Alerts ONLY the
owner admin (core.push.notify_owner: active superusers, push + email), once
when a check turns bad, a reminder at most once a day while it stays bad, and
a recovery message. Dedupe state: core.OpsAlertState. Read-only towards the
system (systemctl show, crontab -l, /etc/cron.d).

  */5 * * * * ubuntu cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-ops-watch.lock nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py ops_watch >> /home/ubuntu/assisto/backend/logs/ops_watch.log 2>&1

--dry-run: print the checks, change nothing, alert nobody.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Watch cron jobs, services, crash/ANR rate; alert the owner on change."

    def add_arguments(self, parser):
        parser.add_argument("--dry-run", action="store_true")

    @track_job("ops_watch")
    def handle(self, *args, **opts):
        from core import crash_rate, ops_health as H
        snap = H.snapshot()
        checks = H.checks_from(snap)
        try:
            checks += crash_rate.alert_checks()
        except Exception as e:  # noqa: BLE001 — a stats error never stops the watch
            self.stdout.write("crash-rate check skipped (%s)" % type(e).__name__)
        stamp = timezone.now().isoformat(timespec="seconds")
        bad = [c for c in checks if c[1]]
        if opts.get("dry_run"):
            for key, is_bad, detail, _ in checks:
                self.stdout.write("%s %s" % ("BAD " if is_bad else "ok  ", detail))
            return
        new_bad, remind, recovered = H.evaluate(checks)
        msg = H.compose(new_bad, remind, recovered)
        sent = None
        if msg:
            from core.push import notify_owner
            sent = notify_owner(*msg)
        self.stdout.write("%s ops_watch checks=%d bad=%d new=%d remind=%d recovered=%d%s" % (
            stamp, len(checks), len(bad), len(new_bad), len(remind), len(recovered),
            (" sent=%s" % sent) if sent else ""))
