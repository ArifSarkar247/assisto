"""fcbrain — per-minute Family Care brain tick (inside minute_jobs).

Night news at each member's chosen local time (default 21:30, can be off)
and the monthly "who can see you" in-app card. Idempotent per local day.
"""
from django.core.management.base import BaseCommand
from django.utils import timezone

from core.ops_health import track_job


class Command(BaseCommand):
    help = "Family Care brain: night news + monthly visibility reminder."
    requires_system_checks = []

    def add_arguments(self, parser):
        parser.add_argument("--quiet", action="store_true")

    @track_job("family_brain_tick")
    def handle(self, *args, **opts):
        from core import family_brain
        stats = family_brain.tick()
        busy = {k: v for k, v in stats.items() if v}
        if busy or not opts.get("quiet"):
            self.stdout.write("%s family_brain_tick %s" % (
                timezone.now().isoformat(timespec="seconds"),
                " ".join("%s=%s" % kv for kv in sorted(busy.items())) or "idle"))
