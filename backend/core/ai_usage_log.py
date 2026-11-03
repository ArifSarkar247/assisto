"""aifinal (owner AI order 3 Nov 23:15, PART 2): the AI usage log for Owner
Admin. One AIUsage row per AI request (written by core/ai.py generate and the
vision path): time, pseudonymous user id, feature, answer level, provider +
model, tokens in/out, cost USD + BDT, latency and the result
(success | fallback(reason) | error(reason) | refunded).

NEVER stores or shows message text: the AIUsage table has no text column and
this module never reads chat messages. The user id is shown only as a keyed
hash (HMAC-SHA256 with the server secret), so the owner can follow one
account's usage without seeing who it is. Rows older than RETENTION_DAYS are
deleted by `manage.py ai_usage_purge` (inside minute_jobs)."""
import hashlib
import hmac
from datetime import timedelta

from django.conf import settings
from django.db.models import Count, Sum
from django.utils import timezone

RETENTION_DAYS = 90
PURGE_BATCH = 5000
RESULTS = ("success", "fallback", "error", "refunded")
LEVELS = ("normal", "better", "best")


def pseudo_id(user_id):
    """Stable pseudonym for a user id ('' for none). Not reversible without
    the server secret; never the phone, name or raw id."""
    if not user_id:
        return ""
    key = ("ailog:" + str(settings.SECRET_KEY)).encode()
    return "u-" + hmac.new(key, str(user_id).encode(), hashlib.sha256).hexdigest()[:10]


def _first_failure(attempts):
    for a in (attempts or "").split("|"):
        if ":" in a and not a.endswith(":ok"):
            prov, why = a.split(":", 1)
            return "%s %s" % (prov, why)
    return ""


def result_of(row):
    """(result, reason) for one AIUsage row."""
    if int(getattr(row, "refunded", 0) or 0) > 0:
        return "refunded", (row.error_kind or _first_failure(row.attempts) or "")
    if not row.ok:
        return "error", (row.error_kind or _first_failure(row.attempts) or "failed")
    if int(row.hops or 0) > 0:
        return "fallback", _first_failure(row.attempts)
    return "success", ""


def usd_bdt():
    try:
        from . import billing
        return float(billing.cfg().get("usd_bdt") or 0) or 120.0
    except Exception:  # noqa: BLE001
        return 120.0


def _since(now, period):
    from . import ai_router as R
    day0 = R.day_start(now)
    if period == "month":
        return day0.replace(day=1)
    return day0


def _filtered(qs, f):
    if f.get("provider"):
        qs = qs.filter(provider=f["provider"])
    if f.get("feature"):
        qs = qs.filter(feature__startswith=f["feature"])
    if f.get("level"):
        qs = qs.filter(level=f["level"])
    r = f.get("result")
    if r == "success":
        qs = qs.filter(ok=True, hops=0, refunded=0)
    elif r == "fallback":
        qs = qs.filter(ok=True, hops__gt=0, refunded=0)
    elif r == "error":
        qs = qs.filter(ok=False, refunded=0)
    elif r == "refunded":
        qs = qs.filter(refunded__gt=0)
    return qs


def clean_filters(get):
    """Only known values pass (the page is owner-only, still: no free text
    reaches a query except the feature prefix, which is bounded)."""
    from . import ai_config as C
    f = {}
    p = str(get.get("provider") or "")
    if p in C.PROVIDERS:
        f["provider"] = p
    lv = str(get.get("level") or "")
    if lv in LEVELS:
        f["level"] = lv
    r = str(get.get("result") or "")
    if r in RESULTS:
        f["result"] = r
    feat = "".join(ch for ch in str(get.get("feature") or "")[:40]
                   if ch.isalnum() or ch in "._-").lower()
    if feat:
        f["feature"] = feat
    u = str(get.get("user") or "").strip()[:14]
    if u.startswith("u-"):
        f["user"] = u
    try:
        d = int(get.get("days") or 1)
    except (TypeError, ValueError):
        d = 1
    f["days"] = max(1, min(RETENTION_DAYS, d))
    return f


def totals(now=None, period="today"):
    """Per-provider totals for today / this month (Asia/Dhaka calendar)."""
    from .models import AIUsage
    now = now or timezone.now()
    rate = usd_bdt()
    qs = (AIUsage.objects.filter(created_at__gte=_since(now, period))
          .values("provider")
          .annotate(n=Count("id"), tin=Sum("input_tokens"), tout=Sum("output_tokens"),
                    usd=Sum("cost_usd"))
          .order_by("provider"))
    rows = []
    for r in qs:
        usd = float(r["usd"] or 0)
        rows.append({"provider": r["provider"] or "-", "requests": r["n"],
                     "tokens_in": int(r["tin"] or 0), "tokens_out": int(r["tout"] or 0),
                     "usd": round(usd, 4), "bdt": round(usd * rate, 2)})
    tot = {"provider": "total", "requests": sum(r["requests"] for r in rows),
           "tokens_in": sum(r["tokens_in"] for r in rows),
           "tokens_out": sum(r["tokens_out"] for r in rows),
           "usd": round(sum(r["usd"] for r in rows), 4),
           "bdt": round(sum(r["bdt"] for r in rows), 2)}
    return {"rows": rows, "total": tot}


def recent(f=None, now=None, limit=200):
    """The newest rows matching the filters, as display dicts (no text)."""
    from .models import AIUsage
    f = f or {}
    now = now or timezone.now()
    rate = usd_bdt()
    qs = _filtered(AIUsage.objects.filter(
        created_at__gte=now - timedelta(days=f.get("days", 1))), f).order_by("-created_at")
    out = []
    want = f.get("user")
    for row in qs.iterator(chunk_size=500):
        pid = pseudo_id(row.user_id)
        if want and pid != want:
            continue
        res, why = result_of(row)
        out.append({
            "time": timezone.localtime(row.created_at).strftime("%Y-%m-%d %H:%M:%S"),
            "user": pid or "-", "feature": row.feature, "level": row.level or "-",
            "provider": row.provider or "-", "model": row.model or "-",
            "tokens_in": row.input_tokens, "tokens_out": row.output_tokens,
            "usd": round(row.cost_usd or 0, 6), "bdt": round((row.cost_usd or 0) * rate, 4),
            "latency_ms": row.latency_ms, "result": res, "reason": why,
            "credits": row.credits_charged, "refunded": row.refunded})
        if len(out) >= limit:
            break
    return out


def mark_refunded(user, credits, why, now=None):
    """Book a refund on this user's newest successful row of the last 5
    minutes (the turn that was paid for and then given back)."""
    from .models import AIUsage
    if user is None or int(credits or 0) <= 0:
        return 0
    now = now or timezone.now()
    row = (AIUsage.objects.filter(user=user, ok=True, refunded=0,
                                  created_at__gte=now - timedelta(minutes=5))
           .order_by("-created_at").first())
    if row is None:
        return 0
    return AIUsage.objects.filter(pk=row.pk).update(refunded=int(credits),
                                                    error_kind=str(why)[:30])


def purge(now=None, days=RETENTION_DAYS, batch=PURGE_BATCH):
    """Delete rows older than `days` (bounded batch per run). Returns count."""
    from .models import AIUsage
    now = now or timezone.now()
    ids = list(AIUsage.objects.filter(created_at__lt=now - timedelta(days=days))
               .order_by("id").values_list("id", flat=True)[:batch])
    if not ids:
        return 0
    return AIUsage.objects.filter(id__in=ids).delete()[0]


_VISION_PROVIDER = {"vision_claude": "anthropic", "vision_gemini": "gemini",
                    "vision_openai": "openai"}


def log_vision(user, slug, conf, cost_usd, latency_ms, ok, hops=0, error="",
               charged=0, refunded=0):
    """One AIUsage row for a chat-vision request (tokens are not reported by
    the vision path, so they stay 0; cost is the configured per-image cost)."""
    try:
        from .models import AIUsage
        AIUsage.objects.create(
            user=user, feature="chat_vision", model=str((conf or {}).get("model") or slug)[:40],
            provider=_VISION_PROVIDER.get(slug, str(slug)[:20]), cost_usd=float(cost_usd or 0),
            latency_ms=int(latency_ms or 0), ok=bool(ok), hops=int(hops or 0),
            error_kind=str(error or "")[:30], credits_charged=int(charged or 0),
            refunded=int(refunded or 0), tier="vision", task_class="vision")
    except Exception:  # noqa: BLE001 — logging never breaks the answer
        pass
