#!/usr/bin/env python3
"""website v3: copy the CI gallery screenshots the site uses into the site
assets — real app screens only (app/test/screenshots_test.dart → checks.yml
artifacts shots-*), never stock images.

  python tools/website/site_shots.py <shots dir>   # refresh from artifacts
  python tools/website/site_shots.py --check       # every shot present?
  python tools/website/site_shots.py --sources     # rewrite backend/web/site_shot_sources.json

<shots dir> = a folder holding the downloaded shots-* artifacts (or the PNGs
directly). For every name in web.site_v3.shot_names() and both languages it
takes <name>_<lang>_light.png and writes compressed WebP at 360 and 720 px
wide to backend/web/site_assets/shots3/<name>_<lang>_<w>.webp. Pages link
them with ?v=<content hash>, so a refreshed shot gets a new URL (immutable
cache, no stale image). Needs Pillow (CI: pip install Pillow).

BANGLA DIGITS (sitelive, 3 Nov): app/test/launch_bn_sweep_test.dart checks
every site shot's bn gallery screen for English digits and writes the failing
screen names to launch_bn_sweep_failures.json inside the shots-* artifacts.
A refresh refuses (exit 1, nothing written) when a site shot is on that list,
or when no failure list is in the artifacts at all (sweep did not run = no
proof). backend/web/site_shot_sources.json is the name list the sweep reads.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from web import site_v3  # noqa: E402

OUT = ROOT / "backend" / "web" / "site_assets" / "shots3"
SOURCES = ROOT / "backend" / "web" / "site_shot_sources.json"
FAILS = "launch_bn_sweep_failures.json"
LANGS = ("bn", "en")
WIDTHS = (360, 720)


def outputs(name, lang):
    return [OUT / ("%s_%s_%d.webp" % (name, lang, w)) for w in WIDTHS]


def check():
    missing = [str(p.relative_to(ROOT)) for n in site_v3.shot_names() for lang in LANGS
               for p in outputs(n, lang) if not p.is_file()]
    for m in missing:
        print("MISSING", m)
    print("site shots: %d names x %d langs, %d missing" % (len(site_v3.shot_names()), len(LANGS), len(missing)))
    return 1 if missing else 0


def write_sources():
    import json
    SOURCES.write_text(json.dumps({"names": site_v3.shot_names()}, indent=1) + "\n")
    print("wrote", SOURCES.relative_to(ROOT))
    return 0


def sweep_failures(src):
    """{screen name: [findings]} merged from every shard's failure list, or
    None when the artifacts hold no failure list (the sweep did not run)."""
    import json
    files = list(Path(src).rglob(FAILS))
    if not files:
        return None
    out = {}
    for f in files:
        for k, v in (json.loads(f.read_text()).get("failures") or {}).items():
            out.setdefault(k, []).extend(v)
    return out


def blocked(names, failures):
    """Site shot names that the bn sweep failed (English digits in Bangla)."""
    return sorted(n for n in names if n in (failures or {}))


def refresh(src):
    failures = sweep_failures(src)
    if failures is None:
        print("NO %s in the artifacts — the bn sweep did not run; refusing" % FAILS)
        return 1
    bad_bn = blocked(site_v3.shot_names(), failures)
    for n in bad_bn:
        print("BLOCKED (bn sweep failure)", n, failures[n][:3])
    if bad_bn:
        return 1
    from PIL import Image
    index = {}
    for p in Path(src).rglob("*_light.png"):
        index.setdefault(p.name, p)
    OUT.mkdir(parents=True, exist_ok=True)
    bad = 0
    for name in site_v3.shot_names():
        for lang in LANGS:
            p = index.get("%s_%s_light.png" % (name, lang))
            if p is None:
                print("NOT IN ARTIFACTS", name, lang)
                bad += 1
                continue
            im = Image.open(p).convert("RGB")
            for w, dst in zip(WIDTHS, outputs(name, lang)):
                h = round(im.height * w / im.width)
                im.resize((w, h), Image.LANCZOS).save(dst, "WEBP", quality=74, method=6)
    write_sources()
    print("refreshed into", OUT.relative_to(ROOT), "problems:", bad)
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--check":
        sys.exit(check())
    if len(sys.argv) == 2 and sys.argv[1] == "--sources":
        sys.exit(write_sources())
    if len(sys.argv) == 2:
        sys.exit(refresh(sys.argv[1]))
    print(__doc__)
    sys.exit(2)
