"""agentmem — weekly life-graph "learning" + retention sweep
(core/agentcore/memory.weekly_tick). Flag `agent_core` OFF -> nothing runs.

Rule-based only: no AI call, no credits. It proposes SUGGESTIONS from the
user's own data (recurring expenses, family in My Circle, Safe Journey
routines) — nothing becomes a fact until the user taps "Keep". Skips users
who paused learning; never proposes health / religion / politics.
Idempotent: every proposal has a stable fingerprint (also kept for rejected
ones) and a pass inside 6 days of the last is skipped, so a repeated or
overlapping run proposes nothing twice; flock keeps it to one at a time.

Crontab (Sunday 23:00 Asia/Dhaka = 17:00 UTC, low priority):
    0 17 * * 0  cd /home/ubuntu/assisto/backend && flock -n /tmp/assisto-agent-memory.lock nice -n10 /home/ubuntu/assisto/.venv/bin/python manage.py agent_memory_learn --quiet >> /home/ubuntu/assisto/logs/agent_memory_learn.log 2>&1
"""
from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = "Agent Core life-graph weekly learning (suggestions only) + retention (flag agent_core)."

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true", help="print only when something happened")
        parser.add_argument("--user", type=int, default=0, help="only this user id (still flag-gated)")
        parser.add_argument("--force", action="store_true",
                            help="ignore the once-a-week guard (fingerprints still dedupe)")

    def handle(self, *args, **opts):
        from core.agentcore import memory as MEM
        from core.models import User
        users = None
        if opts.get("user"):
            users = list(User.objects.filter(pk=opts["user"]))
        stats = MEM.weekly_tick(users=users, force=bool(opts.get("force")))
        busy = {k: v for k, v in stats.items() if v}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s agent_memory_learn %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
