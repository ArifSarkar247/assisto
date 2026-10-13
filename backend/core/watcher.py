"""
Server-side watcher engine (P4). Plain-code change detection FIRST; AI only when
something actually changes. Public RSS / official APIs / public pages only, with
robots.txt respected and polite rate limits. We store only a short ORIGINAL note
and the detected value — never source article content.

Plan limits: free = 2 watchers; premium = 20. Check interval per watcher
(default 6h) keeps us polite.
"""
import hashlib
import re
import urllib.request
import urllib.robotparser
from urllib.parse import urlparse

from django.utils import timezone

from . import ai

_UA = "AssistoWatcher/1.0 (+https://assisto.asalify.com; polite)"
MAX_WATCHERS = {"free": 2, "premium": 20, "family": 20, "probashi": 20,
                "business": 50, "annual": 20, "founder": 50}


def max_watchers(user):
    from . import plans
    return MAX_WATCHERS.get(plans.effective_plan(user), 2)


def _robots_ok(url):
    try:
        p = urlparse(url)
        rp = urllib.robotparser.RobotFileParser()
        rp.set_url(f"{p.scheme}://{p.netloc}/robots.txt")
        rp.read()
        return rp.can_fetch(_UA, url)
    except Exception:
        return True   # if robots unreachable, proceed politely (GET only)


def _fetch(url, timeout=20):
    if not _robots_ok(url):
        raise PermissionError("robots.txt disallows")
    req = urllib.request.Request(url, headers={"User-Agent": _UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


# -------- per-kind value extraction (plain code, no AI) --------
def _rss_latest_title(xml):
    m = re.search(r"<item>.*?<title>(.*?)</title>", xml, re.S | re.I)
    if not m:
        m = re.search(r"<entry>.*?<title[^>]*>(.*?)</title>", xml, re.S | re.I)
    t = (m.group(1) if m else "").strip()
    t = re.sub(r"<!\[CDATA\[(.*?)\]\]>", r"\1", t, flags=re.S)
    return re.sub(r"<[^>]+>", "", t).strip()[:200]


def _usd_bdt_rate():
    # open, no-key FX endpoint; returns a plain number
    data = _fetch("https://open.er-api.com/v6/latest/USD")
    m = re.search(r'"BDT"\s*:\s*([0-9.]+)', data)
    return (f"{float(m.group(1)):.2f}" if m else "")


def _page_number(url, selector_regex):
    html = _fetch(url)
    m = re.search(selector_regex, html)
    return (m.group(1).strip() if m else hashlib.md5(html.encode()).hexdigest()[:12])


def extract_value(w):
    """Return the current plain value/signal for a watcher (no AI)."""
    c = w.config or {}
    if w.kind == "usd_bdt":
        return _usd_bdt_rate()
    if w.kind in ("rss", "job", "exam", "visa", "news", "offer"):
        return _rss_latest_title(_fetch(c["url"]))
    if w.kind in ("page", "price", "flight"):
        if c.get("regex"):
            return _page_number(c["url"], c["regex"])
        html = _fetch(c["url"])
        return hashlib.md5(html.encode()).hexdigest()[:16]
    if w.kind == "weather":
        # open-meteo: no key; current weather for a lat/lon (parents' district)
        lat, lon = c.get("lat", "23.8"), c.get("lon", "90.4")
        data = _fetch(f"https://api.open-meteo.com/v1/forecast?latitude={lat}"
                      f"&longitude={lon}&current=weather_code,temperature_2m")
        m = re.search(r'"weather_code"\s*:\s*([0-9]+)', data)
        return (m.group(1) if m else "")
    return ""


def _note(w, old, new):
    """Short ORIGINAL bilingual note — never source content."""
    lbl = w.label
    if w.kind == "usd_bdt":
        try:
            up = float(new) > float(old or 0)
            return f"{lbl}: USD/BDT {old} → {new} ({'↑' if up else '↓'})"
        except ValueError:
            return f"{lbl}: USD/BDT = {new}"
    if w.kind in ("rss", "job", "exam", "visa", "news", "offer"):
        return f"{lbl}: নতুন আপডেট — “{new[:120]}”"
    if w.kind in ("price", "flight"):
        return f"{lbl}: দামে পরিবর্তন হয়েছে — দেখে নিন।"
    if w.kind == "weather":
        return f"{lbl}: আবহাওয়ার পরিবর্তন — সতর্ক থাকুন।"
    return f"{lbl}: পরিবর্তন ধরা পড়েছে।"


def check(w):
    """Check one watcher. Returns a WatchHit or None. AI only on change."""
    from .models import WatchHit
    try:
        value = extract_value(w)
    except Exception:
        w.last_checked = timezone.now()
        w.save(update_fields=["last_checked"])
        return None
    h = hashlib.sha256((value or "").encode()).hexdigest()
    changed = bool(w.last_hash) and h != w.last_hash and value != ""
    first = not w.last_hash
    old = w.last_value
    w.last_hash, w.last_value, w.last_checked = h, (value or "")[:200], timezone.now()
    w.save(update_fields=["last_hash", "last_value", "last_checked"])
    if first or not changed:
        return None
    summary = _note(w, old, value)
    sev = "high" if w.kind in ("weather", "visa", "job") else "info"
    return WatchHit.objects.create(watcher=w, summary=summary[:300],
                                   old_value=old[:200], new_value=(value or "")[:200],
                                   severity=sev)


def due(w):
    if not w.enabled:
        return False
    if not w.last_checked:
        return True
    age = (timezone.now() - w.last_checked).total_seconds() / 60.0
    return age >= w.interval_min
