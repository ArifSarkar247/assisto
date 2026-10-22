"""x1-calls A1-e: ONE-TIME cleanup of stale live call rows.

  python manage.py calls_cleanup_stale            # dry run: lists rows only
  python manage.py calls_cleanup_stale --apply    # ends them (no pushes)

Ends every live row (ringing / connecting / active / reconnecting) that the
timeouts say is dead, or that is older than 3 h, WITHOUT any push or
missed-call alert (old rows must not ring or alert anyone).
"""
from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "End stale live CallRecord rows left by the old double-start bug."

    def add_arguments(self, parser):
        parser.add_argument("--apply", action="store_true",
                            help="really end them (default: dry run)")

    def handle(self, *args, **opts):
        from core.views_c2_calls import stale_cleanup
        apply = bool(opts.get("apply"))
        rows = stale_cleanup(apply=apply)
        for cid, state, reason in rows:
            self.stdout.write("call #%s %s -> %s" % (cid, state, reason))
        self.stdout.write("%s %d stale live call row(s)." % (
            "Ended" if apply else "DRY RUN: would end", len(rows)))
