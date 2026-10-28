"""agent-proactive — Agent Core nudges + morning brief / evening recap
(core/agentcore/proactive.tick). Flag `agent_core` OFF -> nothing runs.

Template-only: no AI call, no credits. Idempotent: every nudge and brief is
UNIQUE per (user, trigger, dedupe key), so overlapping or repeated runs never
send anything twice; flock in the cron line keeps it to one at a time anyway.

Crontab (every 15 minutes, low priority):
    */15 * * * *  cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-agent-nudges.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py agent_nudges --quiet >> /home/ubuntu/assisto/logs/agent_nudges.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = "Agent Core proactive nudges + morning brief / evening recap (flag agent_core)."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true",
                            help="print only when something happened")
        parser.add_argument("--user", type=int, default=0,
                            help="only this user id (still flag-gated)")

    def handle(self, *args, **opts):
        from core.agentcore import proactive as P
        from core.models import User
        users = None
        if opts.get("user"):
            users = list(User.objects.filter(pk=opts["user"]))
        stats = P.tick(users=users)
        busy = {k: v for k, v in stats.items() if v}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s agent_nudges %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
