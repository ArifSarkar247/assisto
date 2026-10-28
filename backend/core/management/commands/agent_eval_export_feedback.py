"""
manage.py agent_eval_export_feedback — AF-12: append every APPROVED, not yet
exported feedback case (Owner Admin -> Agent runs -> Feedback queue) to
core/agentcore/evals/feedback/<topic>.jsonl, which the integrator commits.

    python manage.py agent_eval_export_feedback              write + mark exported
    python manage.py agent_eval_export_feedback --dry-run    print, change nothing
    python manage.py agent_eval_export_feedback --out DIR    write somewhere else

Idempotent: case id fb-<run id>; an id already in the file is never written
twice. Only masked text exists in the queue; a case that still looks like a
phone / NID / account / e-mail is never written.
"""
import json

from django.core.management.base import BaseCommand

from core.agentcore import feedback_cases as FB


class Command(BaseCommand):
    help = "Export approved agent feedback cases to the eval set files (JSONL)."

    def add_arguments(self, parser):
        parser.add_argument("--out", default="", help="directory (default: core/agentcore/evals/feedback)")
        parser.add_argument("--dry-run", action="store_true", help="print only; write and mark nothing")

    def handle(self, *args, **o):
        r = FB.export(out_dir=o["out"] or None, dry_run=o["dry_run"])
        self.stdout.write(json.dumps(r, ensure_ascii=False))
        self.stdout.write(self.style.SUCCESS(
            "%s %d case(s)%s" % ("would write" if o["dry_run"] else "wrote", r["written"],
                                  " — commit: " + ", ".join(r["files"]) if r["files"] else "")))
