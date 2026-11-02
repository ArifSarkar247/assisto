#!/usr/bin/env python3
"""website v3: copy the CI gallery screenshots the site uses into the site
assets — real app screens only (app/test/screenshots_test.dart → checks.yml
artifacts shots-*), never stock images.

  python tools/website/site_shots.py <shots dir>   # refresh from artifacts
  python tools/website/site_shots.py --check       # every shot present?

<shots dir> = a folder holding the downloaded shots-* artifacts (or the PNGs
directly). For every name in web.site_v3.shot_names() and both languages it
takes <name>_<lang>_light.png and writes compressed WebP at 360 and 720 px
wide to backend/web/site_assets/shots3/<name>_<lang>_<w>.webp. Pages link
them with ?v=<content hash>, so a refreshed shot gets a new URL (immutable
cache, no stale image). Needs Pillow (CI: pip install Pillow).
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
from web import site_v3  # noqa: E402

OUT = ROOT / "backend" / "web" / "site_assets" / "shots3"
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


def refresh(src):
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
    print("refreshed into", OUT.relative_to(ROOT), "problems:", bad)
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--check":
        sys.exit(check())
    if len(sys.argv) == 2:
        sys.exit(refresh(sys.argv[1]))
    print(__doc__)
    sys.exit(2)
