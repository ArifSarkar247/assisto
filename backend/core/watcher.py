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
from .i18n import pick

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
    """Short ORIGINAL note in the user's language — never source content."""
    lang = getattr(getattr(w, "user", None), "language", "bn")
    lbl = w.label
    if w.kind == "usd_bdt":
        try:
            up = float(new) > float(old or 0)
            return f"{lbl}: USD/BDT {old} → {new} ({'↑' if up else '↓'})"
        except ValueError:
            return f"{lbl}: USD/BDT = {new}"
    if w.kind in ("rss", "job", "exam", "visa", "news", "offer"):
        return pick(lang,
                    f"{lbl}: নতুন আপডেট — “{new[:120]}”",
                    f"{lbl}: new update — “{new[:120]}”")
    if w.kind in ("price", "flight"):
        return pick(lang,
                    f"{lbl}: দামে পরিবর্তন হয়েছে — দেখে নিন।",
                    f"{lbl}: the price has changed — take a look.")
    if w.kind == "weather":
        return pick(lang,
                    f"{lbl}: আবহাওয়ার পরিবর্তন — সতর্ক থাকুন।",
                    f"{lbl}: weather change — stay alert.")
    return pick(lang,
                f"{lbl}: পরিবর্তন ধরা পড়েছে।",
                f"{lbl}: a change was detected.")


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


# ---------------------------------------------------------------- lifebar
# Board rows "Watch feed" + "Exam result": a hit used to sit silently in the
# feed (nothing told the user) and ExamWatcher rows were never checked at all.
# Now: every hit is pushed once (reminder channel, opens the Watch feed) and
# exam-result pages are polled politely (6-hourly before the expected date,
# hourly on/after it, stop 45 days after) — a change means "the result page
# changed — the result may be out", never a fabricated result.

EXAM_STOP_AFTER_DAYS = 45
EXAM_MAX_FAILURES = 24


def notify_hit(hit):
    """Push one WatchHit to its owner. Never raises; returns devices sent."""
    try:
        from . import push
        w = hit.watcher
        return push.push_to_user(
            w.user, "reminder",
            title_bn=f"নজরদারি: {w.label}"[:80],
            title_en=f"Watch: {w.label}"[:80],
            body_bn=hit.summary, body_en=hit.summary,
            data={"route": "watch_feed", "hit_id": str(hit.id)})
    except Exception:
        return 0


def exam_due(ew, now=None):
    """Is this exam watcher due on this (hourly) cron run?"""
    from .logic import exam as exam_logic
    now = now or timezone.localtime()
    if not ew.url or ew.result_ready:
        return False
    if ew.consecutive_failures >= EXAM_MAX_FAILURES:
        return False
    if ew.expected_date:
        days_past = (now.date() - ew.expected_date).days
        if days_past > EXAM_STOP_AFTER_DAYS:
            return False
        if not exam_logic.is_result_day(ew.expected_date.isoformat(),
                                        now.replace(tzinfo=None)):
            return now.hour % 6 == 0          # sparse before result day
    return True                                 # result day / no date: hourly


def check_exam(ew):
    """Poll one exam watcher's PUBLIC page. Returns True when it changed
    (then result_ready is set and the user gets one push)."""
    from .logic import exam as exam_logic
    try:
        html = _fetch(ew.url)
    except Exception:
        ew.consecutive_failures += 1
        ew.save(update_fields=["consecutive_failures"])
        return False
    snap = hashlib.sha256(html.encode()).hexdigest()[:64]
    first = not ew.last_snapshot
    changed = (not first) and exam_logic.snapshot_changed(ew.last_snapshot, snap)
    ew.last_snapshot = snap
    ew.consecutive_failures = 0
    fields = ["last_snapshot", "consecutive_failures"]
    if changed:
        ew.result_ready = True
        fields.append("result_ready")
    ew.save(update_fields=fields)
    if changed:
        try:
            from . import push
            lbl = ew.label or "Result"
            push.push_to_user(
                ew.user, "reminder",
                title_bn=f"ফলের পাতা বদলেছে: {lbl}"[:80],
                title_en=f"Result page changed: {lbl}"[:80],
                body_bn="ফল বেরিয়ে থাকতে পারে — অফিসিয়াল পাতায় রোল দিয়ে দেখুন।",
                body_en="The result may be out — check the official page with your roll.",
                data={"route": "exam", "exam_watcher_id": str(ew.id)},
                high_priority=True)
        except Exception:
            pass
    return changed
