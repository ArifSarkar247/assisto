"""ops-watch: record a heartbeat for a job that is not a management command
(shell scripts: migration/backup.sh, migration/restore_test.sh).

  manage.py ops_heartbeat backup --start
  manage.py ops_heartbeat backup --rc 0 --duration-ms 81234
Never fails the caller: always exits 0.
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Record a start/finish heartbeat for a shell job."

    def add_arguments(self, parser):
        parser.add_argument("name")
        parser.add_argument("--start", action="store_true")
        parser.add_argument("--rc", type=int, default=0)
        parser.add_argument("--duration-ms", type=int, default=0)
        parser.add_argument("--error", default="")

    def handle(self, *args, **o):
        from core import ops_health as H
        name = (o["name"] or "")[:48]
        if name not in H.JOB_BY_NAME:
            self.stdout.write("ops_heartbeat: unknown job %r (ignored)" % name)
            return
        if o["start"]:
            H.record_start(name)
        else:
            H.record_finish(name, o["rc"], o["duration_ms"], o["error"])
