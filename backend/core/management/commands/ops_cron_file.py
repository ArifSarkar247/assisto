"""cronbar — print the full RECOMMENDED /etc/cron.d/assisto-app from
core.ops_health.JOBS, so the owner can diff it against what is installed.
READ-ONLY: never writes a crontab or a file.

  manage.py ops_cron_file            # the recommended file (stdout)
  manage.py ops_cron_file --diff     # vs installed (crontab -l + /etc/cron.d/*):
                                     #   MISSING / DOUBLE / OLD STAND-ALONE / NOT IN JOBS
Owner diff (nothing changes):
  cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py ops_cron_file \
      > /tmp/assisto-app.recommended && diff /etc/cron.d/assisto-app /tmp/assisto-app.recommended
"""
from django.core.management.base import BaseCommand

from core import ops_health as H


class Command(BaseCommand):
    help = "Print the recommended /etc/cron.d/assisto-app (read-only); --diff vs installed."

    def add_arguments(self, parser):
        parser.add_argument("--diff", action="store_true",
                            help="compare with the installed cron (read-only)")

    def handle(self, *args, **opts):
        if not opts.get("diff"):
            self.stdout.write(H.render_cron_file(), ending="")
            return
        text = H.installed_cron_text()
        if not text.strip():
            self.stdout.write("installed cron: not readable here (no crontab -l / "
                              "/etc/cron.d) — nothing to compare")
            return
        d = H.cron_diff(text)
        self.stdout.write("MISSING (%d) — add these lines:" % len(d["missing"]))
        seen = set()
        for name, line in d["missing"]:
            self.stdout.write("  [%s]" % name)
            if line not in seen:
                self.stdout.write("  " + line)
                seen.add(line)
        self.stdout.write("DOUBLE (%d) — more than one installed line runs it:" % len(d["double"]))
        for name, n in d["double"]:
            self.stdout.write("  %s: %d lines" % (name, n))
        self.stdout.write("OLD STAND-ALONE LINES (%d) — must stay off (minute_jobs runs them):"
                          % len(d["old_lines"]))
        for name, line in d["old_lines"]:
            self.stdout.write("  %s: %s" % (name, line))
        self.stdout.write("NOT IN JOBS (%d) — scheduled but no ops_watch row: %s"
                          % (len(d["unknown"]), " ".join(d["unknown"]) or "-"))
