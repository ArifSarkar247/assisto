"""x1-calls A1-e: run the call timeouts on every live call row.

Cron (every minute, as the app user, from backend/):
  * * * * * ubuntu cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py calls_sweep >/dev/null 2>&1

Ringing > 45 s -> no_answer; never acked > 20 s -> offline; accepted but not
connected > 20 s -> failed; a phone silent > 15 s -> lost/failed. Both
phones get call.state ended (+ the FCM nudge) so nobody is left on
"Connecting…".
"""
from django.core.management.base import BaseCommand
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    # cron every minute: skip the ~0.7 s system checks (URLconf import) per
    # run — call_command never ran them either (minutejobs, 28 Oct)
    requires_system_checks = []
    help = "End stale live calls (ringing/connecting/no heartbeat)."

    @track_job("calls_sweep")
    def handle(self, *args, **opts):
        from core.views_c2_calls import prune_events, sweep_all
        out = sweep_all()
        n = sum(out.values())
        if n:
            self.stdout.write("calls_sweep: ended %d (%s)" % (
                n, ", ".join("%s=%d" % kv for kv in sorted(out.items()))))
        # circle2: old real-time rows of phones that stopped polling
        gone = prune_events()
        if gone:
            self.stdout.write("calls_sweep: pruned %d old rt events" % gone)
