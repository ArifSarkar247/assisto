"""lpaudio: attach the CI-rendered IELTS listening audio (post-deploy).

    python manage.py lp_audio                 # newest DRAFT release lp-audio-staging-* -> private media -> re-seed
    python manage.py lp_audio --tag lp-audio-staging-<run>   # a given draft (rollback)
    python manage.py lp_audio --dir <folder>  # same from a local folder (manifest.json + .m4a)
    python manage.py lp_audio --dry-run       # only say what would change

Every file is checked: its plan hash must be the hash of the CURRENT script in
tools/lp/content/ielts (an edited part keeps no stale audio), its sha256 must
match the manifest, size <= 8 MB. Files go to private media lp/<sha>.m4a (served
only through signed links). The index lp/audio_index.json lets `lp_seed` keep
the audio on later runs. Safe to run again: unchanged parts are not re-downloaded.
"""
import hashlib
import json
import os
import subprocess

from django.conf import settings
from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from django.core.management.base import BaseCommand, CommandError

INDEX = "lp/audio_index.json"
MAX_BYTES = 8 * 1024 * 1024
REPO = "ArifSarkar247/assisto"
STAGING = "lp-audio-staging-"


def gh_bin():
    """The server's authenticated gh (drafts are not public: no anonymous download)."""
    return getattr(settings, "LP_AUDIO_GH", "") or os.path.expanduser("~/assisto/bin/gh")


def _gh(args, timeout=180):
    r = subprocess.run([gh_bin()] + list(args), capture_output=True, timeout=timeout)  # noqa: S603
    if r.returncode != 0:
        raise RuntimeError("gh %s: %s" % (args[:2], r.stderr.decode("utf-8", "replace")[:200]))
    return r.stdout


def newest_draft(rows):
    """[{tagName, isDraft, createdAt}] -> the newest lp-audio-staging-* draft tag ('' = none)."""
    ds = [r for r in rows or [] if r.get("isDraft") and str(r.get("tagName", "")).startswith(STAGING)]
    return max(ds, key=lambda r: r.get("createdAt") or "")["tagName"] if ds else ""


def gh_fetcher(tag):
    repo = getattr(settings, "LP_AUDIO_REPO", "") or REPO

    def fetch(name):
        blob = _gh(["release", "download", tag, "-R", repo, "-p", os.path.basename(name), "-O", "-"])
        if len(blob) > MAX_BYTES:
            raise ValueError("file too large")
        return blob
    return fetch


def find_tag():
    repo = getattr(settings, "LP_AUDIO_REPO", "") or REPO
    rows = json.loads(_gh(["release", "list", "-R", repo, "--limit", "50",
                           "--json", "tagName,isDraft,createdAt"]).decode("utf-8") or "[]")
    return newest_draft(rows)


def load_index():
    try:
        if default_storage.exists(INDEX):
            with default_storage.open(INDEX, "rb") as fh:
                return json.loads(fh.read().decode("utf-8"))
    except Exception:  # noqa: BLE001 — a broken index = no audio, never a crash
        pass
    return {}


def save_index(idx):
    if default_storage.exists(INDEX):
        default_storage.delete(INDEX)
    default_storage.save(INDEX, ContentFile(json.dumps(idx, ensure_ascii=False, indent=1).encode("utf-8")))


def current_plans(content):
    from core.logic import lp_audio as AU
    out = {}
    for fn in sorted(os.listdir(os.path.join(content, "ielts"))):
        if fn.startswith("ielts-") and fn.endswith(".json"):
            with open(os.path.join(content, "ielts", fn), encoding="utf-8") as fh:
                d = json.load(fh)
            for pl in AU.bundle_plans(d):
                out[(pl["bundle"], str(pl["part"]))] = pl
    for lang in sorted(AU.TRACK_VOICES):
        folder = os.path.join(content, lang)
        for fn in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            if fn.endswith(".json"):
                with open(os.path.join(folder, fn), encoding="utf-8") as fh:
                    d = json.load(fh)
                for pl in AU.track_plans(d, lang):
                    out[(pl["bundle"], str(pl["part"]))] = pl
    return out


def build_index(manifest, plans, fetch, old=None):
    """manifest + current plans -> (index, report). `fetch(file)` returns bytes."""
    old = old or {}
    idx, rep = {}, {"attached": 0, "reused": 0, "stale": [], "bad": []}
    for e in manifest.get("parts") or []:
        key = (str(e.get("bundle")), str(e.get("part")))
        pl = plans.get(key)
        if pl is None or pl["hash"] != e.get("plan_hash") or pl["file"] != e.get("file"):
            rep["stale"].append("%s p%s" % key)
            continue
        prev = (old.get(key[0]) or {}).get(key[1]) or {}
        if prev.get("sha256") == e.get("sha256") and prev.get("audio") and default_storage.exists(prev["audio"]):
            idx.setdefault(key[0], {})[key[1]] = prev
            rep["reused"] += 1
            continue
        try:
            blob = fetch(e["file"])
            if hashlib.sha256(blob).hexdigest() != e.get("sha256"):
                raise ValueError("sha256 mismatch")
            name = "lp/%s.m4a" % e["sha256"][:40]
            if not default_storage.exists(name):
                default_storage.save(name, ContentFile(blob))
        except Exception as ex:  # noqa: BLE001 — report, keep going
            rep["bad"].append("%s: %s" % (e.get("file"), str(ex)[:120]))
            continue
        idx.setdefault(key[0], {})[key[1]] = {
            "audio": name, "sha256": e["sha256"], "bytes": len(blob), "plan_hash": e["plan_hash"],
            "duration_sec": float(e.get("duration_sec") or 0), "accents": list(e.get("accents") or []),
            "preview_sec": int(e.get("preview_sec") or 30), "check_sec": int(e.get("check_sec") or 30)}
        rep["attached"] += 1
    return idx, rep


class Command(BaseCommand):
    help = "Attach the CI-rendered listening audio (release lp-audio) and re-seed the IELTS mocks + track tests."

    def add_arguments(self, parser):
        parser.add_argument("--dir", default="", help="local folder with manifest.json + .m4a files")
        parser.add_argument("--tag", default="", help="draft release tag (default: newest lp-audio-staging-*)")
        parser.add_argument("--content", default="", help="content dir (default <repo>/tools/lp/content)")
        parser.add_argument("--dry-run", action="store_true")

    def handle(self, *args, **opts):
        from core import lp_service as LS
        from core.logic import lp_seed as SD
        from core.management.commands.lp_seed import repo_root
        content = opts["content"] or os.path.join(repo_root(), "tools", "lp", "content")
        if opts["dir"]:
            def fetch(f):
                with open(os.path.join(opts["dir"], os.path.basename(f)), "rb") as fh:
                    return fh.read()
        else:
            try:
                tag = opts["tag"] or find_tag()
            except Exception as e:  # noqa: BLE001
                raise CommandError("gh release list failed: %s" % str(e)[:160])
            if not tag:
                raise CommandError("no lp-audio-staging-* draft release found")
            self.stderr.write("lp_audio: fetching draft release %s" % tag)
            fetch = gh_fetcher(tag)
        try:
            manifest = json.loads(fetch("manifest.json").decode("utf-8"))
        except Exception as e:  # noqa: BLE001
            raise CommandError("no audio manifest: %s" % str(e)[:160])
        plans = current_plans(content)
        if opts["dry_run"]:
            ok = sum(1 for e in manifest.get("parts") or []
                     if (plans.get((str(e.get("bundle")), str(e.get("part")))) or {}).get("hash") == e.get("plan_hash"))
            self.stdout.write(json.dumps({"manifest_parts": len(manifest.get("parts") or []),
                                          "current_parts": len(plans), "matching": ok}))
            return
        idx, rep = build_index(manifest, plans, fetch, load_index())
        save_index(idx)
        known = LS.known_fingerprints()
        res = {"new": 0, "same": 0, "not_live": []}
        tracks = {b for b, _ in plans} - {r["key"] for r in SD.ielts_items(content)}
        raws = SD.ielts_items(content, idx) + [r for r in SD.track_items(content, idx)
                                               if r["kind"] == "mock" and r["key"] in tracks]
        for raw in raws:
            for item, created in LS.import_item(raw, "ai", "lp-audio", known):
                res["new" if created else "same"] += 1
                if item.status not in ("ai_checked", "human_approved"):
                    res["not_live"].append("%s (%s)" % (item.key, item.status))
        rep.update(res)
        rep["parts_with_audio"] = sum(len(v) for v in idx.values())
        rep["parts_total"] = len(plans)
        self.stdout.write(json.dumps(rep, ensure_ascii=False, indent=1))
        if rep["bad"] or res["not_live"]:
            raise CommandError("audio not fully attached: %s" % "; ".join((rep["bad"] + res["not_live"])[:6]))
