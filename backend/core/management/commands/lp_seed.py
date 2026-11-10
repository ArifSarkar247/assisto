"""lpfinish: import the repo's ORIGINAL Language Partner content into the DB.

    python manage.py lp_seed            # IELTS mocks + 6 language tracks + Life English + vocabulary
    python manage.py lp_seed --dry-run  # only count what would be imported

Sources (all written by Assisto, no Cambridge or other published material):
  tools/lp/content/ielts/*.json   original IELTS practice tests (assisto.lp.ielts/1)
  tools/lp/content/<lang>/*.json  Japanese, Korean, German, Chinese, French, Arabic tracks
  app/assets/lp/*.json            Life English scenarios + vocabulary
Safe to run again after every deploy: unchanged items stay as they are (no new
version); changed ones get a new version and the automatic checks run again.
Nothing becomes human_approved here — that stays the Owner Admin review queue."""
import json
import os

from django.conf import settings
from django.core.management.base import BaseCommand, CommandError


def repo_root():
    return os.path.abspath(os.path.join(str(settings.BASE_DIR), ".."))


class Command(BaseCommand):
    help = "Import the repo's original Language Partner content (IELTS mocks, language tracks, life English)."

    def add_arguments(self, parser):
        parser.add_argument("--content", default="", help="content dir (default <repo>/tools/lp/content)")
        parser.add_argument("--assets", default="", help="app lp assets (default <repo>/app/assets/lp)")
        parser.add_argument("--dry-run", action="store_true")

    def handle(self, *args, **opts):
        from core import lp_service as LS
        from core.logic import lp_seed as SD
        root = repo_root()
        content = opts["content"] or os.path.join(root, "tools", "lp", "content")
        assets = opts["assets"] or os.path.join(root, "app", "assets", "lp")
        if not os.path.isdir(content):
            raise CommandError("content dir missing: %s" % content)
        items = SD.all_items(content)
        out = {"items": len(items), "by_kind": {}}
        for it in items:
            out["by_kind"][it["kind"]] = out["by_kind"].get(it["kind"], 0) + 1
        if opts["dry_run"]:
            self.stdout.write(json.dumps(out, ensure_ascii=False, indent=1))
            return
        known = LS.known_fingerprints()
        res = {"new": 0, "same": 0, "ai_checked": 0, "draft": 0, "rejected": 0, "errors": [], "not_live": []}
        for raw in items:
            try:
                for item, created in LS.import_item(raw, "ai", "lp-seed", known):
                    res["new" if created else "same"] += 1
                    if created:
                        res[item.status if item.status in res else "draft"] += 1
                    elif item.status == "draft":     # checks improved since the last run
                        LS.run_checks(item, known)
                    if item.status not in ("ai_checked", "human_approved"):
                        res["not_live"].append("%s (%s): %s" % (item.key, item.status, json.dumps(
                            (item.checks or {}).get("failures", [])[:3], ensure_ascii=False)[:300]))
            except Exception as e:  # noqa: BLE001 — report, keep importing
                res["errors"].append("%s: %s" % (raw.get("key"), str(e)[:160]))
        if os.path.isdir(assets):
            res["app_assets"] = LS.import_app_assets(assets)
        out.update(res)
        self.stdout.write(json.dumps(out, ensure_ascii=False, indent=1))
        if res["errors"] or res["not_live"]:
            raise CommandError("some items are not live: %s" % "; ".join((res["errors"] + res["not_live"])[:6]))
