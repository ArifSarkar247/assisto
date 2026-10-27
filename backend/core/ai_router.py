"""
ai_router.py — the stateful side of the AI router: per-provider circuit
breaker + health, daily spend caps, the 80% / 100% owner alerts, and the
cost aggregations Owner Admin and Profit Guard read.

State lives in the DB (AIProviderState rows, AIUsage rows) so every gunicorn
worker sees the same circuit and the same spend; settings has no shared cache
backend (LocMem is per-process), and no new infrastructure is added.

Circuit breaker, per provider:
  closed     -> normal traffic.
  open       -> skipped; after `cooldown_s` exactly ONE worker wins a
                conditional UPDATE to half_open and sends one real call (the
                probe). Others keep skipping until the probe finishes.
  half_open  -> probe success -> closed; probe failure -> open again.
  opens when `fail_threshold` failures in a row, OR the error rate in the
  `window_s` window reaches `error_rate_pct` after `min_calls` calls (slow
  successes count against the rate, not against the in-a-row counter).
Refusals, over-cap skips and 400 bad requests never touch the circuit.

Never raises into the caller: every public function is wrapped.
"""
import logging
from datetime import datetime, time, timedelta

from django.db import IntegrityError, transaction
from django.db.models import Q, Sum
from django.utils import timezone

from . import ai_config as C

log = logging.getLogger(__name__)

# legacy AIUsage rows (before the router) have provider="" — attribute them
# by model prefix so today's spend is right on the deploy day too.
_LEGACY_PREFIX = {"anthropic": ("claude",), "openai": ("gpt", "o1", "o3", "o4"),
                  "gemini": ("gemini",)}

ALERT_CACHE_KEY = "ai_router:owner_alert"
ALERT_CACHE_S = 60


# ------------------------------------------------------------------ config
def cfg():
    """Normalized router config from the PricingConfig row (defaults if the
    row/block is missing or the DB is unavailable)."""
    try:
        from . import billing
        return C.normalize((billing.get_config().data or {}).get("ai_router"))
    except Exception:
        return C.normalize({})


def save_cfg(new_block):
    """Persist a (validated) router block into PricingConfig.data. The owner
    page writes the OwnerAudit entry. Returns (old, new) normalized blocks."""
    from . import billing
    row = billing.get_config()
    data = dict(row.data or {})
    old = C.normalize(data.get("ai_router"))
    data["ai_router"] = C.normalize(new_block)
    row.data = data
    row.save(update_fields=["data", "updated_at"])
    return old, data["ai_router"]


# ------------------------------------------------------------------ time
def day_start(now=None):
    now = timezone.localtime(now or timezone.now())
    return timezone.make_aware(datetime.combine(now.date(), time.min),
                               timezone.get_current_timezone())


def today():
    return timezone.localdate()


# ------------------------------------------------------------------ circuit
def _state(slug):
    from .models import AIProviderState
    try:
        obj, _ = AIProviderState.objects.get_or_create(slug=slug)
        return obj
    except IntegrityError:
        return AIProviderState.objects.get(slug=slug)


def _probe_ttl(conf):
    return timedelta(seconds=max(30, int(conf["timeouts_s"]["main"]) + 5))


def allow(slug, conf=None):
    """May a call go to `slug` right now? Handles open -> half_open."""
    from .models import AIProviderState
    conf = conf or cfg()
    try:
        r = _state(slug)
        now = timezone.now()
        if r.state == "closed":
            return True
        if r.state == "open":
            cool = timedelta(seconds=conf["circuit"]["cooldown_s"])
            if r.opened_at is None or now - r.opened_at >= cool:
                n = AIProviderState.objects.filter(
                    pk=r.pk, state="open", opened_at=r.opened_at).update(
                    state="half_open", probe_until=now + _probe_ttl(conf))
                return n == 1          # only the winner probes
            return False
        # half_open: one probe at a time; a crashed probe expires
        if r.probe_until is None or r.probe_until <= now:
            n = AIProviderState.objects.filter(
                pk=r.pk, state="half_open", probe_until=r.probe_until).update(
                probe_until=now + _probe_ttl(conf))
            return n == 1
        return False
    except Exception as e:  # noqa: BLE001 — never block traffic on a DB hiccup
        log.warning("ai_router.allow %s: %s", slug, type(e).__name__)
        return True


def record(slug, ok, conf=None, slow=False, error=""):
    """Book one call outcome into the circuit for `slug`."""
    from .models import AIProviderState
    conf = conf or cfg()
    cc = conf["circuit"]
    try:
        _state(slug)
        with transaction.atomic():
            r = AIProviderState.objects.select_for_update().get(slug=slug)
            now = timezone.now()
            if (r.window_start is None
                    or now - r.window_start > timedelta(seconds=cc["window_s"])):
                r.window_start, r.window_calls, r.window_failures = now, 0, 0
            r.window_calls += 1
            if ok:
                r.last_success_at = now
                r.consecutive_failures = 0
                if slow:
                    r.window_failures += 1
                if r.state != "closed":
                    r.state, r.opened_at, r.probe_until = "closed", None, None
            else:
                r.window_failures += 1
                r.consecutive_failures += 1
                r.last_failure_at = now
                r.last_error = (error or "error")[:120]
                if r.state == "half_open":
                    r.state, r.opened_at, r.probe_until = "open", now, None
            if r.state == "closed":
                rate_hit = (r.window_calls >= cc["min_calls"] and
                            r.window_failures * 100 >= cc["error_rate_pct"] * r.window_calls)
                if r.consecutive_failures >= cc["fail_threshold"] or rate_hit:
                    r.state, r.opened_at, r.probe_until = "open", now, None
            r.save()
            return r.state
    except Exception as e:  # noqa: BLE001
        log.warning("ai_router.record %s: %s", slug, type(e).__name__)
        return ""


def mark_health(slug, ok, detail="", conf=None):
    """Result of the periodic health check (free list-models endpoints).
    Failure counts like a real failure; success on an OPEN circuit only moves
    it to half_open (real traffic must prove generation works)."""
    from .models import AIProviderState
    conf = conf or cfg()
    now = timezone.now()
    try:
        r = _state(slug)
        AIProviderState.objects.filter(pk=r.pk).update(last_health_at=now,
                                                       last_health_ok=bool(ok))
        if ok:
            if r.state == "open":
                AIProviderState.objects.filter(pk=r.pk, state="open").update(
                    state="half_open", probe_until=None)
        else:
            record(slug, False, conf, error=("health:" + (detail or ""))[:120])
    except Exception as e:  # noqa: BLE001
        log.warning("ai_router.mark_health %s: %s", slug, type(e).__name__)


def states():
    from .models import AIProviderState
    out = {}
    try:
        for r in AIProviderState.objects.filter(slug__in=C.PROVIDERS):
            out[r.slug] = r
    except Exception:
        pass
    return out


# ------------------------------------------------------------------ spend
def _usage_today():
    from .models import AIUsage
    return AIUsage.objects.filter(created_at__gte=day_start())


def _provider_q(provider):
    q = Q(provider=provider)
    legacy = Q()
    for p in _LEGACY_PREFIX.get(provider, ()):
        legacy |= Q(model__startswith=p)
    return q | (Q(provider="") & legacy)


def spend_today(provider=None):
    try:
        qs = _usage_today()
        if provider:
            qs = qs.filter(_provider_q(provider))
        return float(qs.aggregate(s=Sum("cost_usd"))["s"] or 0.0)
    except Exception:
        return 0.0


def total_cap(conf=None):
    """Effective total daily cap = the SMALLER of the AI page total cap and the
    legacy kill-switch (ai_daily_budget_usd override, else env
    AI_DAILY_BUDGET_USD). One number, so both old and new pages stay honest."""
    conf = conf or cfg()
    from . import ai
    caps = [c for c in (conf["caps_usd"]["total"], ai.daily_budget_usd()) if c is not None]
    return min(caps) if caps else 0.0


def provider_capped(provider, conf=None):
    """True when this provider reached its own daily cap (cap 0 = provider
    switched off by the owner)."""
    conf = conf or cfg()
    cap = float(conf["caps_usd"].get(provider, 0.0))
    if cap <= 0:
        return True
    return spend_today(provider) >= cap


def total_capped(conf=None):
    conf = conf or cfg()
    return spend_today() >= total_cap(conf)


def user_cost_today(user):
    """Profit Guard: today's provider cost (USD) of one user."""
    try:
        return float(_usage_today().filter(user=user).aggregate(s=Sum("cost_usd"))["s"] or 0.0)
    except Exception:
        return 0.0


def top_users_today(n=10):
    try:
        rows = (_usage_today().exclude(user=None).values("user_id")
                .annotate(cost=Sum("cost_usd")).order_by("-cost")[:n])
        return [{"user_id": r["user_id"], "cost_usd": round(r["cost"] or 0.0, 4)} for r in rows]
    except Exception:
        return []


# ------------------------------------------------------------------ alerts
def _alert_text(slug, level, spent, cap):
    who = "মোট AI" if slug == "total" else slug.capitalize()
    pct = int(round(100 * spent / cap)) if cap else 100
    if level == "full":
        subject = "Assisto AI: %s দৈনিক সীমা শেষ" % who
        body = ("%s আজ $%.2f / $%.2f (%d%%) খরচ করেছে — আজ এটি আর ব্যবহার হবে না "
                "(অন্য প্রোভাইডারে চলবে)। Owner Admin → AI-তে সীমা বাড়াতে পারেন." %
                (who, spent, cap, pct))
    else:
        subject = "Assisto AI: %s দৈনিক সীমার %d%% খরচ হয়েছে" % (who, pct)
        body = ("%s আজ $%.2f / $%.2f খরচ করেছে। Owner Admin → AI দেখুন." % (who, spent, cap))
    return subject, body


def check_alerts(conf=None):
    """After a spend: alert OWNER ADMIN accounts (superusers: staff push +
    email via push.notify_owner, and the Owner Admin banner) once per provider
    per day at alert_pct, and once more at 100%. Returns the alerts sent."""
    from .models import AIProviderState
    conf = conf or cfg()
    sent = []
    d = today()
    try:
        targets = [(p, float(conf["caps_usd"][p]), spend_today(p)) for p in C.PROVIDERS]
        targets.append(("total", total_cap(conf), spend_today()))
        for slug, cap, spent in targets:
            if cap <= 0:
                continue
            pct = 100.0 * spent / cap
            for level, field, need in (("full", "alert_full_day", 100.0),
                                       ("warn", "alert_warn_day", float(conf["alert_pct"]))):
                if pct < need:
                    continue
                r = _state(slug)
                n = (AIProviderState.objects.filter(pk=r.pk)
                     .filter(Q(**{field: None}) | ~Q(**{field: d}))
                     .update(**{field: d}))
                if n == 1:
                    subject, body = _alert_text(slug, level, spent, cap)
                    try:
                        from . import push
                        push.notify_owner(subject, body)
                    except Exception:
                        pass
                    sent.append((slug, level))
        if sent:
            _clear_alert_cache()
    except Exception as e:  # noqa: BLE001
        log.warning("ai_router.check_alerts: %s", type(e).__name__)
    return sent


def _clear_alert_cache():
    try:
        from django.core.cache import cache
        cache.delete(ALERT_CACHE_KEY)
    except Exception:
        pass


def owner_alert():
    """Owner Admin banner: providers (and 'total') that crossed the alert
    threshold today, with their live %. Cached 60 s per process."""
    try:
        from django.core.cache import cache
        hit = cache.get(ALERT_CACHE_KEY)
        if hit is not None:
            return hit or None
    except Exception:
        cache = None
    out = []
    try:
        from .models import AIProviderState
        conf = cfg()
        for r in AIProviderState.objects.filter(alert_warn_day=today()):
            cap = total_cap(conf) if r.slug == "total" else float(conf["caps_usd"].get(r.slug, 0))
            spent = spend_today(None if r.slug == "total" else r.slug)
            out.append({"slug": r.slug, "pct": int(round(100 * spent / cap)) if cap else 100,
                        "full": r.alert_full_day == today()})
    except Exception:
        out = []
    try:
        if cache is not None:
            cache.set(ALERT_CACHE_KEY, out, ALERT_CACHE_S)
    except Exception:
        pass
    return out or None


# ------------------------------------------------------------------ owner page
def dashboard(conf=None):
    """Everything the Owner Admin AI page shows (owner-only data)."""
    from .models import AIUsage
    conf = conf or cfg()
    st = states()
    qs = _usage_today()
    rows = []
    from . import ai
    keys = dict(ai._providers())
    for p in C.PROVIDERS:
        r = st.get(p)
        pq = qs.filter(_provider_q(p))
        spent = spend_today(p)
        cap = float(conf["caps_usd"][p])
        rows.append({
            "slug": p, "key": p in keys,
            "state": r.state if r else "closed",
            "consecutive": r.consecutive_failures if r else 0,
            "last_error": r.last_error if r else "",
            "last_failure_at": r.last_failure_at if r else None,
            "last_success_at": r.last_success_at if r else None,
            "last_health_at": r.last_health_at if r else None,
            "last_health_ok": r.last_health_ok if r else None,
            "spent": round(spent, 4), "cap": cap,
            "pct": int(round(100 * spent / cap)) if cap else 0,
            "calls": pq.filter(ok=True).count(),
        })
    total = spend_today()
    tcap = total_cap(conf)
    return {
        "providers": rows,
        "total": {"spent": round(total, 4), "cap": tcap,
                  "pct": int(round(100 * total / tcap)) if tcap else 0,
                  "calls": qs.filter(ok=True).count(),
                  "failed": qs.filter(ok=False).count(),
                  "failovers": qs.filter(hops__gt=0).count()},
        "recent": list(AIUsage.objects.order_by("-created_at")[:40]),
        "top_users": top_users_today(10),
    }
