"""t9-turnscale: one coturn capacity sample per run + owner alerts BEFORE the
limits are hit (see core/turn_monitor.py for the sources and thresholds).

Idempotent; light (a few /proc reads, one `ss`, one STUN probe per TURN host,
the new tail of the coturn log). State (log offset, counters) in
logs/turn_monitor_state.json. Cron (every minute):
  * * * * * ubuntu nice -n15 <venv>/python <backend>/manage.py turn_monitor >/dev/null 2>&1
"""
from pathlib import Path

from django.conf import settings
from django.core.management.base import BaseCommand

from core import turn_monitor as M
from core.ops_health import track_job  # ops-watch heartbeat


class Command(BaseCommand):
    # cron every minute: skip the ~0.7 s system checks (URLconf import) per
    # run — call_command never ran them either (minutejobs, 28 Oct)
    requires_system_checks = []
    help = "Sample coturn (allocations, bandwidth, CPU, errors) and alert the owner."

    def add_arguments(self, parser):
        parser.add_argument("--print", action="store_true", help="print the sample")

    @track_job("turn_monitor")
    def handle(self, *args, **opts):
        path = Path(settings.BASE_DIR) / "logs" / "turn_monitor_state.json"
        path.parent.mkdir(exist_ok=True)
        state = M.load_state(str(path))
        s, sends, state = M.run_once(state)
        M.save_state(str(path), state)
        if opts.get("print"):
            self.stdout.write(
                "allocations=%s cli_sessions=%s relay_out_Bps=%s nic_out_Bps=%s "
                "turn_cpu=%s%% steal=%s%% quota=%s bw_quota=%s alloc_err=%s auth_err=%s "
                "healthy_servers=%s sources=%s alerts_sent=%d" % (
                    s.allocations, s.cli_sessions, s.relay_out_bps, s.nic_out_bps,
                    s.turn_cpu_pct, s.steal_pct, s.quota_errors, s.bw_quota_errors,
                    s.alloc_errors, s.auth_errors, s.healthy_servers, s.sources,
                    len(sends)))
