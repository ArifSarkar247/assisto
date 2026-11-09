"""lpcore: import Language Partner content.

    python manage.py lp_import <bundle_dir>            # lpcontent CI artifact (bundle.json + audio/ + img/)
    python manage.py lp_import --app-assets <dir>      # seed scenarios / vocab from app/assets/lp/*.json

Upsert by key: unchanged content -> nothing; changed -> a new version in draft,
then the automatic checks move it to ai_checked (or keep it in draft with the
failures; Cambridge / known-text hits are rejected). Audio and images go to
private media and are served only through signed links. Nothing becomes
human_approved here — that is the review queue in Owner Admin."""
import json
import os

from django.core.management.base import BaseCommand, CommandError


class Command(BaseCommand):
    help = "Import a Language Partner content bundle (or the app's bundled lp assets)."

    def add_arguments(self, parser):
        parser.add_argument("path")
        parser.add_argument("--app-assets", action="store_true")

    def handle(self, *args, **opts):
        from core import lp_service as LS
        path = opts["path"]
        if not os.path.isdir(path):
            raise CommandError("not a directory: %s" % path)
        if opts["app_assets"]:
            out = LS.import_app_assets(path)
        else:
            if not os.path.isfile(os.path.join(path, "bundle.json")):
                raise CommandError("bundle.json missing in %s" % path)
            out = LS.import_bundle(path)
        self.stdout.write(json.dumps(out, ensure_ascii=False, indent=1))
