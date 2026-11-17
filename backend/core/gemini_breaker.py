"""geminioff (owner 9 Nov 13:30): the Gemini PROVIDER circuit breaker.

The prepaid Gemini credit is empty (HTTP 402) and the owner will not top it
up for now. A billing error will not fix itself in minutes, so the geminifix
15-minute skip (core/ai_health.py) still cost one doomed call per worker
every 15 minutes and showed "Gemini" errors on Owner Admin only.

  * note_failure(code, reason) — every Gemini caller reports its error here
    (through ai_health.mark_down or directly). HTTP 402, or a 403 / 404 /
    429 whose message is about billing / prepaid credit, OPENS the breaker
    for 24 hours: Gemini is then "not connected" for every feature (chat
    levels, vision, voice, web search, Photo Studio, exam, Business AI,
    health checks) and they all run on Claude or on the phone. No retries.
  * is_open() — one indexed read of a unique slug (no process memo: a
    stale "on" in one worker would cost a doomed call; tests stay isolated).
  * daily_probe() — run by the minute_jobs tick (no new cron line): while
    open, ONE tiny generateContent call (1 output token) once the 24 h are
    over. 200 closes the breaker; a billing error re-opens it for 24 h; any
    other failure keeps it open and checks again in 24 h (never a retry
    loop). The owner's own "Test" in Integrations is not touched.
  * state() — the Owner Admin line "Gemini: off (402) — last check …".

State lives in one AIProviderState row (slug "gemini:off"), shared by every
gunicorn worker — no migration. Never a key in a log, a row or a page."""
import logging
import re
from datetime import timedelta

from django.utils import timezone

log = logging.getLogger(__name__)

SLUG = "gemini:off"
OFF_HOURS = 24
PROBE_TIMEOUT_S = 15
_BILLING = re.compile(r"billing|prepa(?:y|id)|credit|payment|quota exceeded for|"
                      r"insufficient|balance|top.?up|spend(?:ing)? (?:limit|cap)", re.I)


def should_trip(code, reason=""):
    """True for the errors that mean "no money on the Gemini account":
    HTTP 402 always; 403 / 404 / 429 only when the message says billing."""
    c = str(code or "").replace("http_", "").strip()
    if c == "402":
        return True
    if c in ("403", "404", "429") and _BILLING.search(str(reason or "")):
        return True
    return False


def _row():
    from .models import AIProviderState
    try:
        return AIProviderState.objects.filter(slug=SLUG).first()
    except Exception:  # noqa: BLE001 — never block traffic on a DB hiccup
        return None


def is_open(now=None):
    """Gemini must not be called right now (prepaid credit / billing off)."""
    r = _row()
    return bool(r is not None and r.state == "open")


def available():
    return not is_open()


def trip(code="http_402", reason="", now=None, extend=False):
    """Open the breaker for OFF_HOURS. Returns True (now open). A breaker
    that is already open keeps its next-check time (a late error from a
    call already in flight never pushes the daily check back) unless
    `extend` (the daily check itself failed)."""
    from .models import AIProviderState
    from .ai_health import clean_reason
    now = now or timezone.now()
    code = str(code or "http_402")
    if not code.startswith("http_"):
        code = "http_" + code
    text = ("gemini|*|billing|%s|%s" % (code, clean_reason(reason)))[:120]
    try:
        obj, created = AIProviderState.objects.get_or_create(slug=SLUG)
        was_open = obj.state == "open" and not created
        until = now + timedelta(hours=OFF_HOURS)
        if was_open and not extend and obj.probe_until:
            until = obj.probe_until
        AIProviderState.objects.filter(pk=obj.pk).update(
            state="open", opened_at=obj.opened_at if was_open and obj.opened_at else now,
            probe_until=until, last_failure_at=now, last_error=text)
    except Exception as e:  # noqa: BLE001
        log.warning("gemini_breaker.trip: %s", type(e).__name__)
        return False
    if not was_open:
        log.warning("ai: Gemini OFF for %dh (%s) — all Gemini work runs on Claude / the "
                    "phone until the daily check passes", OFF_HOURS, code)
    return True


def close(now=None):
    from .models import AIProviderState
    now = now or timezone.now()
    try:
        AIProviderState.objects.filter(slug=SLUG).update(
            state="closed", probe_until=None, last_success_at=now,
            last_health_at=now, last_health_ok=True)
    except Exception:  # noqa: BLE001
        return False
    log.warning("ai: Gemini back ON (daily check passed)")
    return True


def note_failure(code, reason="", kind=""):
    """A Gemini call failed. Trips the breaker on billing errors."""
    if "(breaker)" in str(reason or ""):
        return False          # our own guard's refusal, not a Gemini answer
    if kind == "billing" or should_trip(code, reason):
        return trip(code if str(code or "").strip() else "http_402", reason)
    return False


def guard():
    """For the HTTP seams: True = do NOT call Gemini now."""
    return is_open()


# ------------------------------------------------------------------ probe
def _key():
    try:
        from . import integrations
        if integrations.is_enabled("gemini"):
            return (integrations.get("gemini") or {}).get("api_key") or ""
    except Exception:  # noqa: BLE001
        pass
    return ""


def _probe_call(key):
    """(status_code, reason). One generateContent with ONE output token —
    the only request that really shows whether the prepaid credit is there
    (the free list-models call answers 200 even with no credit)."""
    import requests
    from . import gemini_models as GM
    m = GM.resolve(GM.get("text"), "text")
    url = "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % m
    body = {"contents": [{"role": "user", "parts": [{"text": "ok"}]}],
            "generationConfig": {"maxOutputTokens": 1}}
    try:
        r = requests.post(url, json=body, timeout=PROBE_TIMEOUT_S,
                          headers={"x-goog-api-key": key, "content-type": "application/json"})
    except Exception as e:  # noqa: BLE001
        return 0, type(e).__name__
    if r.status_code == 200:
        return 200, ""
    from .ai import _error_message
    return r.status_code, _error_message(r)


def daily_probe(now=None, call=None):
    """minute_jobs tick. Returns 'closed' | 'waiting' | 'no_key' | 'on' |
    'still_off' | 'error'. At most ONE Gemini request per OFF_HOURS."""
    r = _row()
    if r is None or r.state != "open":
        return "closed"
    now = now or timezone.now()
    if r.probe_until and r.probe_until > now:
        return "waiting"
    from .models import AIProviderState
    key = _key()
    if not key:
        # no key = nothing to check; look again tomorrow, no request
        AIProviderState.objects.filter(pk=r.pk).update(
            probe_until=now + timedelta(hours=OFF_HOURS), last_health_at=now,
            last_health_ok=False)
        return "no_key"
    code, reason = (call or _probe_call)(key)
    if code == 200:
        close(now)
        return "on"
    if should_trip(code, reason):
        trip("http_%d" % code, reason, now=now, extend=True)
        AIProviderState.objects.filter(pk=r.pk).update(last_health_at=now, last_health_ok=False)
        return "still_off"
    # timeout / 5xx / other: stay off, ONE more check in 24 h (no retry loop)
    from .ai_health import clean_reason
    AIProviderState.objects.filter(pk=r.pk).update(
        probe_until=now + timedelta(hours=OFF_HOURS), last_health_at=now,
        last_health_ok=False,
        last_error=("gemini|*|billing|%s|%s" % (
            ("http_%d" % code) if code else "net", clean_reason(reason)))[:120])
    return "error"


# ------------------------------------------------------------------ owner
def state():
    """Owner Admin: {open, code, since, last_check, next_check, bn, en} or
    {open: False}."""
    r = _row()
    if r is None or r.state != "open":
        return {"open": False}
    parts = ((r.last_error or "").split("|") + [""] * 5)[:5]
    code = (parts[3] or "http_402").replace("http_", "")
    last = r.last_health_at or r.last_failure_at
    nxt = r.probe_until
    loc = timezone.localtime

    def fmt(d):
        return loc(d).strftime("%d %b %H:%M") if d else "-"
    bn = ("Gemini: বন্ধ (%s) — প্রিপেইড ক্রেডিট শেষ। সব AI এখন Claude ও ফোনে চলছে। "
          "শেষ যাচাই %s, পরের যাচাই %s (দিনে একবার)।" % (code, fmt(last), fmt(nxt)))
    en = ("Gemini: off (%s) — last check %s, next check %s (once a day). Everything runs "
          "on Claude and on the phone; see owner_actions/GEMINI_OFF_LIMITS_BN.md."
          % (code, fmt(last), fmt(nxt)))
    return {"open": True, "code": code, "since": r.opened_at, "last_check": last,
            "next_check": nxt, "reason": parts[4], "bn": bn, "en": en}
