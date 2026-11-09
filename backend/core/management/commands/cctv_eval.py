"""bizai pillar 4: measured CCTV accuracy on a labelled clip test set.

    manage.py cctv_eval --manifest path/to/manifest.json [--window 30]

Prints precision / recall / F1 per kind and whether each meets the 90 %
target on >= 20 events (core/bizai_cctv.py). Format:
core/testdata/cctv_clips/manifest.example.json. No clip ships in git."""
import json

from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Precision / recall per alert kind on a labelled clip manifest."

    def add_arguments(self, parser):
        parser.add_argument("--manifest", required=True)
        parser.add_argument("--window", type=int, default=30)

    def handle(self, *args, **opts):
        from core import bizai_cctv as C
        try:
            with open(opts["manifest"], encoding="utf-8") as fh:
                m = json.load(fh)
        except (OSError, ValueError) as e:
            raise CommandError("cannot read manifest: %s" % e)
        per_clip = [C.match(c.get("truth") or [], c.get("alerts") or [], opts["window"])
                    for c in m.get("clips") or []]
        tot = C.combine(*per_clip)
        self.stdout.write("clips=%d window=%ds target=%.0f%%" % (
            len(per_clip), opts["window"], C.TARGET * 100))
        for k, v in tot.items():
            self.stdout.write("%-8s tp=%d fp=%d fn=%d precision=%s recall=%s f1=%s %s" % (
                k, v["tp"], v["fp"], v["fn"], v["precision"], v["recall"], v["f1"],
                "MEETS" if v["meets_target"] else ("below" if v["enough"] else "not-enough-events")))
        return None
