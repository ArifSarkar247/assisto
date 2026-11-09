"""lpcore: add a known copyrighted text to the Language Partner copyright guard
WITHOUT storing the text: only 8-word shingle hashes go into
core/data/lp_known_fingerprints.json (commit that file).

    python manage.py lp_fingerprint --add some_text.txt
    python manage.py lp_fingerprint --check some_text.txt   # how many runs match"""
import json

from django.core.management.base import BaseCommand


class Command(BaseCommand):
    help = "Add / check known-text fingerprints for the Language Partner content guard."

    def add_arguments(self, parser):
        parser.add_argument("--add")
        parser.add_argument("--check")

    def handle(self, *args, **opts):
        from core import lp_service as LS
        from core.logic import lp_checks as CK
        if opts.get("add"):
            with open(opts["add"], encoding="utf-8") as fh:
                new = set(CK.fingerprints(fh.read()))
            with open(LS._FP_FILE, encoding="utf-8") as fh:
                j = json.load(fh)
            have = set(j.get("hashes") or [])
            j["hashes"] = sorted(have | new)
            with open(LS._FP_FILE, "w", encoding="utf-8") as fh:
                json.dump(j, fh, indent=0)
            self.stdout.write("added %d hashes (%d total)" % (len(new - have), len(j["hashes"])))
        if opts.get("check"):
            with open(opts["check"], encoding="utf-8") as fh:
                fails = CK.copyright_failures(fh.read(), LS.known_fingerprints())
            self.stdout.write(json.dumps(fails))
