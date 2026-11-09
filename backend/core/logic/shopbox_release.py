"""cctvtoday: where the Assisto Shop Box PC program (CCTV gateway) is
downloaded. CI (.github/workflows/shopbox.yml, job `publish`) puts the zip and
shopbox-latest.json on the fixed GitHub pre-release `shopbox-windows`. Here
we read that small JSON (cached) so lifeassisto.com/get and the app can show
the version and SHA-256. Never raises; without the JSON the plain link stays."""
import re

REPO = "ArifSarkar247/assisto"
BASE = "https://github.com/%s/releases/download/shopbox-windows/" % REPO
ZIP_URL = BASE + "AssistoShopBox-windows-x64.zip"
MANIFEST_URL = BASE + "shopbox-latest.json"
CACHE_KEY = "shopbox_release_v1"
_SHA = re.compile(r"^[0-9a-f]{64}$")


def clean(raw):
    """The manifest fields we trust and show (nothing else passes)."""
    out = {"url": ZIP_URL, "available": False}
    if not isinstance(raw, dict):
        return out
    sha = str(raw.get("sha256") or "").lower()
    ver = str(raw.get("version") or "")[:40]
    if not _SHA.match(sha) or not re.match(r"^[0-9A-Za-z.+\-]{1,40}$", ver):
        return out
    try:
        size = int(raw.get("size_bytes") or 0)
    except (TypeError, ValueError):
        size = 0
    out.update({"available": True, "version": ver, "sha256": sha,
                "size_mb": round(size / 1048576.0, 1) if size > 0 else None,
                "built_at": str(raw.get("built_at") or "")[:20],
                "signed": bool(raw.get("signed"))})
    return out


def latest(fetch=None, timeout=3):
    from django.core.cache import cache
    try:
        hit = cache.get(CACHE_KEY)
        if hit is not None:
            return hit
    except Exception:
        hit = None
    raw = None
    try:
        from django.conf import settings
        if fetch is not None:
            raw = fetch()
        elif not getattr(settings, "SHOPBOX_RELEASE_FETCH", True):
            raw = None              # tests: never reach GitHub
        else:
            import requests
            r = requests.get(MANIFEST_URL, timeout=timeout)
            if r.status_code == 200 and len(r.content) < 4096:
                raw = r.json()
    except Exception:
        raw = None
    out = clean(raw)
    try:
        cache.set(CACHE_KEY, out, 1800 if out["available"] else 300)
    except Exception:
        pass
    return out
