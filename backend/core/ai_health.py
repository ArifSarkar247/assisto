"""geminifix (live bug 4 Nov): provider / model HEALTH for hard errors.

A provider answer of HTTP 404 (model retired / not offered to this key),
402 (billing not enabled) or 401/403 (key / project permission) will not
fix itself in a few seconds, so the normal circuit breaker (60 s cooldown,
3 failures) is the wrong tool: every user would keep paying the latency of
a doomed call and Owner Admin would only see "circuit open".

  * mark_down(provider, model, kind, code, reason) — the (provider, model)
    pair (404) or the whole provider key (402/401/403) is skipped for
    `down_min` minutes (router circuit config, default 15). The router
    then falls back to the next SAME-OR-CHEAPER provider (core/ai.py).
  * is_down(provider, model)
  * last_error(provider) / alert_lines(provider) — the last REAL error for
    Owner Admin (AI levels + Integrations): a red line in Bangla + English
    while it is newer than the provider's last successful answer.

State lives in AIProviderState rows (shared by every gunicorn worker, no
migration): slug "x:<16 hex>" per (provider, model|*), last_error =
"provider|model|kind|code|reason". The reason is the provider's own error
message, masked + stripped of anything key-like — never the key."""
import hashlib
import logging
import re
from datetime import timedelta

from django.utils import timezone

log = logging.getLogger(__name__)

HARD_KINDS = ("not_found", "billing", "auth")
PROVIDER_WIDE = ("billing", "auth")       # the key / project, not one model
DEFAULT_DOWN_MIN = 15
_KEYLIKE = re.compile(r"(AIza[0-9A-Za-z_\-]{10,}|sk-[0-9A-Za-z_\-]{10,}|key=[^&\s]+)")


def _slug(provider, model):
    h = hashlib.sha1(("%s|%s" % (provider, model or "*")).encode()).hexdigest()[:16]
    return "x:" + h


def clean_reason(text):
    """Provider error message safe for a log / the owner page."""
    s = _KEYLIKE.sub("[redacted]", str(text or ""))
    s = s.replace("|", "/").replace("\n", " ").strip()
    try:
        from .agentcore import trust as _T
        s = _T.Vault().mask(s)
    except Exception:  # noqa: BLE001
        pass
    return s[:80]


def _down_min(conf=None):
    try:
        if conf is None:
            from . import ai_router as R
            conf = R.cfg()
        return int((conf.get("circuit") or {}).get("down_min") or DEFAULT_DOWN_MIN)
    except Exception:  # noqa: BLE001
        return DEFAULT_DOWN_MIN


def mark_down(provider, model, kind, code="", reason="", conf=None):
    """Book a hard error. Returns True when the pair is now skipped."""
    if kind not in HARD_KINDS:
        return False
    from .models import AIProviderState
    target = "*" if kind in PROVIDER_WIDE else (model or "*")
    now = timezone.now()
    until = now + timedelta(minutes=_down_min(conf))
    why = clean_reason(reason)
    text = ("%s|%s|%s|%s|%s" % (provider, model or "*", kind, code or "", why))[:120]
    try:
        obj, _ = AIProviderState.objects.get_or_create(slug=_slug(provider, target))
        AIProviderState.objects.filter(pk=obj.pk).update(
            state="open", opened_at=now, probe_until=until, last_failure_at=now,
            last_error=text)
    except Exception as e:  # noqa: BLE001 — never block traffic on a DB hiccup
        log.warning("ai_health.mark_down %s: %s", provider, type(e).__name__)
        return False
    log.warning("ai: %s model %s unavailable (%s %s) — skipped %d min: %s",
                provider, model or "*", kind, code or "-", _down_min(conf), why or "-")
    return True


def is_down(provider, model=""):
    from .models import AIProviderState
    slugs = [_slug(provider, "*")] + ([_slug(provider, model)] if model else [])
    try:
        return AIProviderState.objects.filter(slug__in=slugs,
                                              probe_until__gt=timezone.now()).exists()
    except Exception:  # noqa: BLE001
        return False


def last_error(provider):
    """The newest hard error for `provider` -> dict, or None. `active` =
    no successful answer from that provider since (so the owner must act)."""
    from .models import AIProviderState
    try:
        r = (AIProviderState.objects.filter(slug__startswith="x:",
                                            last_error__startswith=provider + "|")
             .order_by("-last_failure_at").first())
        if r is None:
            return None
        parts = (r.last_error.split("|") + [""] * 5)[:5]
        main = AIProviderState.objects.filter(slug=provider).first()
        ok_at = main.last_success_at if main else None
        active = ok_at is None or (r.last_failure_at and r.last_failure_at > ok_at)
        return {"provider": parts[0], "model": parts[1], "kind": parts[2],
                "code": parts[3], "reason": parts[4], "at": r.last_failure_at,
                "down": bool(r.probe_until and r.probe_until > timezone.now()),
                "active": bool(active)}
    except Exception:  # noqa: BLE001
        return None


_NAMES = {"gemini": "Gemini", "anthropic": "Claude", "openai": "OpenAI"}


def alert_lines(provider):
    """(bn, en) red line for Owner Admin, or None when nothing to fix."""
    e = last_error(provider)
    if not e or not e["active"]:
        return None
    n = _NAMES.get(provider, provider)
    code = e["code"] or ""
    m = e["model"] if e["model"] != "*" else ""
    if e["kind"] == "billing":
        bn = "%s: বিলিং চালু নেই (HTTP 402) — Google AI Studio / Cloud-এ বিলিং চালু করুন" % n
        en = "%s: billing not enabled (HTTP 402) — enable billing in Google AI Studio / Cloud" % n
        if provider != "gemini":
            bn = "%s: বিলিং/ক্রেডিট নেই (HTTP 402) — প্রোভাইডারের কনসোলে বিলিং চালু করুন" % n
            en = "%s: billing / credit missing (HTTP 402) — enable billing in the provider console" % n
    elif e["kind"] == "not_found":
        bn = "%s: মডেল %s বাতিল / এই key-তে নেই (404) — AI লেভেল পাতায় চলতি মডেল দিন" % (n, m)
        en = "%s: model %s retired / not offered to this key (404) — set a current model on AI levels" % (n, m)
    else:
        c = code.replace("http_", "") or "403"
        bn = "%s: key-এর অনুমতি নেই (HTTP %s) — key ও প্রজেক্টে API চালু আছে কিনা দেখুন" % (n, c)
        en = "%s: permission denied (HTTP %s) — check the key and that the API is enabled for the project" % (n, c)
    return bn, en


def alerts():
    """Every provider's active red line: [{"provider", "bn", "en", "reason", "at"}]."""
    out = []
    for p in ("gemini", "anthropic", "openai"):
        lines = alert_lines(p)
        if lines:
            e = last_error(p) or {}
            out.append({"provider": p, "bn": lines[0], "en": lines[1],
                        "reason": e.get("reason", ""), "at": e.get("at")})
    return out
