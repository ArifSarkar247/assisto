"""publicurl: rotate the vendor callback link(s) and tell the vendor the new one.

    python manage.py cctv_callback_rotate --vendor dolynk
    python manage.py cctv_callback_rotate --vendor imou
    python manage.py cctv_callback_rotate --all        # every vendor with keys

Only the CALLBACK token changes (a new random salt in the integration
config); the vendor API keys are never touched. Prints only "rotated" and the
registration result, never the token or any key. The owner copies the new
link from Owner Admin -> Integrations -> <vendor> card.
"""
from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Rotate a vendor callback link (DoLynk / DoLynk ARC / Imou) and re-register it."

    def add_arguments(self, parser):
        parser.add_argument("--vendor", action="append", default=[],
                            help="dolynk | dolynk_arc | imou (repeatable)")
        parser.add_argument("--all", action="store_true")
        parser.add_argument("--no-register", action="store_true",
                            help="rotate only; do not call the vendor API")

    def handle(self, *args, **o):
        from core import callback_links as CL
        from core.public_url import problem
        why = problem()
        if why:
            raise CommandError("public base not ready: %s" % why)
        slugs = list(CL.CALLBACK_SLUGS) if o["all"] else o["vendor"]
        if not slugs:
            raise CommandError("give --vendor <slug> or --all")
        for slug in slugs:
            if slug not in CL.CALLBACK_SLUGS:
                raise CommandError("unknown vendor %s" % slug)
            if not CL.rotate(slug):
                self.stdout.write("%s: no keys saved, nothing to rotate" % slug)
                continue
            reg = "skipped" if o["no_register"] else CL.reregister(slug)
            self.stdout.write("%s: rotated; vendor registration: %s" % (slug, reg))
