"""d1-photo v2: the Photo Studio worker loop (run by the separate
`assisto-photo-worker` systemd service — deploy/photo_worker/).

  manage.py photo_worker            # forever (SIGTERM = finish the job, exit)
  manage.py photo_worker --once     # one item (cron/debug)
"""
import signal

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Photo Studio worker: run queued heavy photo jobs + FACE LOCK"

    def add_arguments(self, parser):
        parser.add_argument("--once", action="store_true")
        parser.add_argument("--idle", type=float, default=1.0)

    def handle(self, *args, **opts):
        from core import photo_worker
        stop = {"v": False}

        def _term(*_a):
            stop["v"] = True
        signal.signal(signal.SIGTERM, _term)
        signal.signal(signal.SIGINT, _term)
        n = photo_worker.loop(once=opts["once"], idle_sleep=opts["idle"], stop=lambda: stop["v"])
        self.stdout.write("photo_worker: %d job(s)" % n)
