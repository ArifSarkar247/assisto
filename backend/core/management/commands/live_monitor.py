"""livemon (owner 17 Nov): READ-ONLY daily live-health snapshot (core/live_monitor.py)
— Play crash / ANR rates, top crashes, server 5xx, signups + DAU/WAU, signup
success, payments — written to backend/logs/live_monitor_latest.json and a
one-line Bangla summary in backend/logs/live_monitor_bn.txt (the lead copies
it to the top of STATUS each morning); P0 flags inside the JSON.

Runs inside `manage.py minute_jobs` (owner: no new cron lines) with --tick:
once a Dhaka day from 06:00. Plain `manage.py live_monitor` runs it now;
`--print` also prints the Bangla line. Aggregate counts only — no phone
numbers, names, emails, IPs or message text are read into the report.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core import ops_health as H
from core.ops_health import track_job


class Command(BaseCommand):
    help = "Daily live health (Play vitals, crashes, 5xx, signups, payments) — read-only."
    requires_system_checks = []   # runs every minute inside minute_jobs

    def add_arguments(self, parser):
        parser.add_argument("--tick", action="store_true",
                            help="minute_jobs slice: run only once a day from 06:00 Dhaka")
        parser.add_argument("--print", action="store_true", dest="print_line",
                            help="print the Bangla line")

    @track_job("live_monitor")
    def handle(self, *args, **opts):
        from core import live_monitor as LM
        now = timezone.now()
        if opts.get("tick") and not LM.is_due(now, H.stamp_get("live_monitor")):
            return
        msgs = []
        rep = LM.collect(now=now, log=msgs.append)
        d = LM.write(rep)
        H.stamp_set("live_monitor", now)
        for m in msgs[:20]:
            self.stdout.write("live_monitor: %s" % m)
        self.stdout.write("%s live_monitor p0=%d play=%s dir=%s" % (
            now.isoformat(timespec="seconds"), len(rep["p0"]),
            "ok" if (rep.get("play") or {}).get("ok") else
            ((rep.get("play") or {}).get("skipped") or "error"), d))
        if opts.get("print_line"):
            self.stdout.write(rep["bn_line"])
