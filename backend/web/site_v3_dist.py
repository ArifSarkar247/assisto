"""website v3: where visitors get the app.

* play_public(): is the Assisto Play listing PUBLIC? Checked server-side
  (GET https://play.google.com/store/apps/details?id=<pkg>: 200 = public,
  404 = not yet), cached 1 h; the owner can override it in Owner Admin →
  Website (AdminFlagState: website_play_auto ON = auto-detect; when OFF,
  website_play_public decides). Until public the site says "Coming soon to
  Play Store" and the Install button offers the APK; it flips by itself.
* apk_info(): the ONE APK the website offers. Source = settings
  WEBSITE_APK_FILE (a path — e.g. the Play-signed universal APK) or, when
  empty, the file behind app_latest.json's apk_url (publish-apk.sh layout
  APK_PUBLIC_DIR/<token>/<name>). Version, size, date and SHA-256 are
  computed from that exact file, and /download/apk streams that same file.
  No in-app self-update is involved.
"""
import hashlib
import json
import os
import re
from datetime import datetime, timezone

from django.conf import settings
from django.core.cache import cache

from . import site_content as SC

PLAY_CACHE_KEY = "sitev3:play_public"
PLAY_TTL = 3600


def _flag(fid, default=True):
    try:
        from core.billing import flag_on
        return flag_on(fid, default)
    except Exception:  # noqa: BLE001
        return default


def fetch_play_status(pkg=SC.PLAY_ID, timeout=4):
    """True = listing public (HTTP 200), False = not found (404), None = unknown."""
    import urllib.error
    import urllib.request
    url = "https://play.google.com/store/apps/details?id=%s&hl=en" % pkg
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (lifeassisto.com listing check)"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:   # noqa: S310 (fixed https URL)
            return r.status == 200
    except urllib.error.HTTPError as e:
        return False if e.code == 404 else None
    except Exception:  # noqa: BLE001
        return None


def play_public():
    if not _flag("website_play_auto", True):
        return _flag("website_play_public", True)
    v = cache.get(PLAY_CACHE_KEY)
    if v is None:
        got = fetch_play_status()
        v = "1" if got else "0"
        # unknown (network trouble) → assume not public, retry in 10 min
        cache.set(PLAY_CACHE_KEY, v, PLAY_TTL if got is not None else 600)
    return v == "1"


def play_mode():
    if _flag("website_play_auto", True):
        return "auto"
    return "public" if _flag("website_play_public", True) else "hidden"


# ------------------------------------------------------------------- APK
_SHA = {}


def _latest():
    try:
        with open(settings.APP_LATEST_FILE) as f:
            return json.load(f)
    except Exception:  # noqa: BLE001
        return {}


def apk_path():
    p = getattr(settings, "WEBSITE_APK_FILE", "") or ""
    if p:
        return p
    url = _latest().get("apk_url") or ""
    m = re.search(r"/dl/([A-Za-z0-9_\-]+)/([A-Za-z0-9_.\-]+\.apk)$", url)
    if not m:
        return ""
    base = getattr(settings, "APK_PUBLIC_DIR", "") or os.path.join(os.path.dirname(settings.APP_LATEST_FILE), "apk_public")
    return os.path.join(base, m.group(1), m.group(2))


def apk_info():
    """{version, size_mb, date, sha256, name} of the served file, or None."""
    p = apk_path()
    try:
        st = os.stat(p)
    except OSError:
        return None
    key = (p, st.st_size, int(st.st_mtime))
    sha = _SHA.get(key)
    if sha is None:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        sha = h.hexdigest()
        _SHA.clear()
        _SHA[key] = sha
    name = os.path.basename(os.path.realpath(p))  # fixed URL may be a symlink to the build file
    ver = ""
    if not getattr(settings, "WEBSITE_APK_FILE", ""):
        ver = _latest().get("version_name") or ""
    if not ver:
        m = re.search(r"build(\d+)", name)
        ver = ("1.0.%s" % m.group(1)) if m else ""
    return {"version": ver, "size_mb": round(st.st_size / 1048576.0, 1), "sha256": sha, "name": name,
            "date": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).date()}


def apk_url():
    """Public URL of the same file apk_info() describes."""
    if getattr(settings, "WEBSITE_APK_FILE", ""):
        return getattr(settings, "WEBSITE_APK_URL", "") or "/download/apk"
    return _latest().get("apk_url") or ""


def apk_display(info, lang):
    if not info:
        return None
    n = lambda v: SC.bn_digits(v) if lang == "bn" else str(v)  # noqa: E731
    d = info["date"]
    if lang == "bn":
        months = ["জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই", "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর"]
        date = "%s %s %s" % (n(d.day), months[d.month - 1], n(d.year))
    else:
        date = d.strftime("%-d %b %Y")
    return {"version": n(info["version"]), "size": n(info["size_mb"]) + " MB", "date": date,
            "sha256": info["sha256"], "sha_short": info["sha256"][:12]}
