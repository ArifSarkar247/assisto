"""
ai_cost_alert.py — pricing-40 (owner decision 27 Oct, step 5): an automatic
owner alert when the REAL AI cost per credit rises above the safe level.

  real cost per credit = Σ AIUsage.cost_usd x usd_bdt ÷ Σ AIUsage.credits_charged
      over successful calls that charged credits, trailing 1 and 7 days,
      overall and per model (and per tier).
  safe level           = the cheapest ৳ we sell one credit for (monthly plans,
      annual plans, packs — from the live PricingConfig) x the AI budget
      (billing.cost_alert_budget_pct, default 24 = 74 % net - 10 % overhead
      - 40 % profit), or the owner's own billing.cost_alert_safe_paisa.

Above it -> push + email to OWNER ADMIN accounts (superusers; push.notify_owner)
and a FamilyAlert row each, at most ONCE per day per breach key, plus the
Owner Admin banner. ALERT ONLY: it never changes a price, a credit, a model or
a user. Free calls (0 credits: the free quick-reply quota, cron briefings) are
reported separately and never mixed into the per-credit number.

Runs as a step of `manage.py billing_daily` (and `manage.py ai_cost_check`).
Never raises into the caller.
"""
import logging
from datetime import timedelta

from django.db.models import Count, Sum
from django.utils import timezone

log = logging.getLogger(__name__)

KIND = "ai_cost_credit"            # FamilyAlert.kind (<= 24 chars)
WINDOWS = (1, 7)
BANNER_CACHE_KEY = "ai_cost_alert:banner"
BANNER_CACHE_S = 60


def knobs(cfg=None):
    from . import billing
    c = cfg or billing.cfg()
    b = c.get("billing") or {}
    return {"enabled": bool(b.get("cost_alert_enabled", True)),
            "budget_pct": int(b.get("cost_alert_budget_pct", 24)),
            "min_credits": int(b.get("cost_alert_min_credits", 100)),
            "safe_paisa": int(b.get("cost_alert_safe_paisa", 0))}


def safe_level(cfg=None):
    """Safe ৳ of AI cost per consumed credit (0.0 when nothing is sold)."""
    from . import billing
    from .logic import pricing_40 as P40
    c = cfg or billing.cfg()
    k = knobs(c)
    if k["safe_paisa"] > 0:
        return round(k["safe_paisa"] / 100.0, 4)
    return P40.safe_bdt_per_credit(c, k["budget_pct"] / 100.0)


def _cpc(cost_bdt, credits):
    return round(cost_bdt / credits, 4) if credits else None


def compute(days, now=None, cfg=None):
    """Cost-per-credit report for the trailing `days`."""
    from . import billing
    from .models import AIUsage
    c = cfg or billing.cfg()
    rate = float(c.get("usd_bdt") or 120.0)
    now = now or timezone.now()
    qs = AIUsage.objects.filter(ok=True, created_at__gte=now - timedelta(days=days))
    charged = qs.filter(credits_charged__gt=0)
    tot = charged.aggregate(cost=Sum("cost_usd"), credits=Sum("credits_charged"), n=Count("id"))
    free = qs.filter(credits_charged=0).aggregate(cost=Sum("cost_usd"), n=Count("id"))
    cost_bdt = float(tot["cost"] or 0) * rate
    credits = int(tot["credits"] or 0)
    groups = []
    for field in ("model", "tier"):
        for r in (charged.values(field).annotate(cost=Sum("cost_usd"), credits=Sum("credits_charged"),
                                                  n=Count("id")).order_by(field)):
            cb = float(r["cost"] or 0) * rate
            groups.append({"by": field, "key": r[field] or "-", "calls": r["n"],
                           "credits": int(r["credits"] or 0), "cost_bdt": round(cb, 2),
                           "cpc": _cpc(cb, int(r["credits"] or 0))})
    return {"days": days, "calls": tot["n"] or 0, "credits": credits,
            "cost_bdt": round(cost_bdt, 2), "cpc": _cpc(cost_bdt, credits),
            "free_calls": free["n"] or 0,
            "free_cost_bdt": round(float(free["cost"] or 0) * rate, 2),
            "groups": groups}


def breaches(now=None, cfg=None):
    """[(key, cpc, safe, credits, days)] above the safe level."""
    from . import billing
    c = cfg or billing.cfg()
    k = knobs(c)
    safe = safe_level(c)
    out = []
    if safe <= 0:
        return out, safe, []
    reports = [compute(d, now, c) for d in WINDOWS]
    for r in reports:
        if r["cpc"] is not None and r["credits"] >= k["min_credits"] and r["cpc"] > safe:
            out.append(("%dd:all" % r["days"], r["cpc"], safe, r["credits"], r["days"]))
        for g in r["groups"]:
            if g["cpc"] is not None and g["credits"] >= k["min_credits"] and g["cpc"] > safe:
                out.append(("%dd:%s:%s" % (r["days"], g["by"], g["key"]), g["cpc"], safe,
                            g["credits"], r["days"]))
    return out, safe, reports


def _text(key, cpc, safe, credits, days):
    pct = int(round(100.0 * cpc / safe)) if safe else 0
    subject = "Assisto: প্রতি ক্রেডিটে AI খরচ নিরাপদ সীমার উপরে (%s)" % key
    body = ("শেষ %d দিনে %s: প্রতি ক্রেডিটে আসল AI খরচ ৳%.2f, নিরাপদ সীমা ৳%.2f (%d%%), "
            "%d ক্রেডিট কাটা হয়েছে। ৪০%% লাভের নিয়ম ঝুঁকিতে। দাম বা ক্রেডিট কিছুই নিজে "
            "বদলায়নি — Owner Admin → AI ও Pricing দেখুন (সীমা, মডেল, ক্রেডিট খরচ)।"
            % (days, key, cpc, safe, pct, credits))
    return subject, body


def check(now=None, notify=True, cfg=None):
    """Daily job body. Returns {enabled, safe, breaches, sent, reports}."""
    from . import billing
    out = {"enabled": False, "safe": 0.0, "breaches": 0, "sent": 0}
    try:
        c = cfg or billing.cfg()
        k = knobs(c)
        out["enabled"] = k["enabled"]
        if not k["enabled"]:
            return out
        found, safe, reports = breaches(now, c)
        out.update({"safe": safe, "breaches": len(found),
                    "cpc_1d": reports[0]["cpc"] if reports else None,
                    "cpc_7d": reports[1]["cpc"] if len(reports) > 1 else None})
        if not found or not notify:
            return out
        from django.contrib.auth import get_user_model
        from .models import FamilyAlert
        owners = list(get_user_model().objects.filter(is_superuser=True, is_active=True)[:5])
        day = timezone.localdate(now) if now else timezone.localdate()
        for key, cpc, sf, credits, days in found:
            subject, body = _text(key, cpc, sf, credits, days)
            title = ("%s %s" % (key, day.isoformat()))[:160]
            first = False
            for o in owners:
                _, created = FamilyAlert.objects.get_or_create(
                    user=o, kind=KIND, title=title,
                    defaults={"body": body, "severity": "high",
                              "payload": {"source": "ai_cost_alert", "key": key,
                                          "cpc": cpc, "safe": sf, "day": day.isoformat()}})
                first = first or created
            if first:                     # once per day per breach key
                try:
                    from . import push
                    push.notify_owner(subject, body)
                except Exception:  # noqa: BLE001
                    pass
                out["sent"] += 1
        _clear_banner()
    except Exception as e:  # noqa: BLE001 — a report never breaks billing_daily
        log.warning("ai_cost_alert.check: %s", type(e).__name__)
        out["error"] = type(e).__name__
    return out


def _clear_banner():
    try:
        from django.core.cache import cache
        cache.delete(BANNER_CACHE_KEY)
    except Exception:  # noqa: BLE001
        pass


def banner():
    """Owner Admin banner: today's breaches [{key, cpc, safe}] or None."""
    try:
        from django.core.cache import cache
        hit = cache.get(BANNER_CACHE_KEY)
        if hit is not None:
            return hit or None
    except Exception:  # noqa: BLE001
        cache = None
    rows, seen = [], set()
    try:
        from .models import FamilyAlert
        today = timezone.localdate().isoformat()
        for a in FamilyAlert.objects.filter(kind=KIND, payload__day=today).order_by("-created_at")[:20]:
            key = (a.payload or {}).get("key")
            if key and key not in seen:
                seen.add(key)
                rows.append({"key": key, "cpc": a.payload.get("cpc"), "safe": a.payload.get("safe")})
    except Exception:  # noqa: BLE001
        rows = []
    try:
        if cache is not None:
            cache.set(BANNER_CACHE_KEY, rows, BANNER_CACHE_S)
    except Exception:  # noqa: BLE001
        pass
    return rows or None


# ------------------------------------------------------------------ monthly
MONTH_KIND = "ai_usage_month"
MODE_FEATURES = (("quick", "chat.quick"), ("smart", "chat.smart"),
                 ("upgrade", "chat.upgrade"), ("pro", "chat.pro"))


def _p90(vals):
    if not vals:
        return None
    v = sorted(vals)
    return v[min(len(v) - 1, int(round(0.9 * (len(v) - 1))))]


def monthly_usage(days=30, now=None, cfg=None):
    """REAL usage per chat mode over `days`: calls, average input / cached /
    output tokens, average and p90 cost per message (৳), vs the hard cap the
    plan credits were sized on — and the plan credits the REAL p90 cost would
    allow at the same >= 40 % rule (so the owner can give more messages)."""
    from . import billing
    from .logic import pricing_40 as P40
    from .models import AIUsage
    c = cfg or billing.cfg()
    rate = float(c.get("usd_bdt") or 120.0)
    now = now or timezone.now()
    qs = AIUsage.objects.filter(ok=True, created_at__gte=now - timedelta(days=days))
    modes = {}
    for mode, feat in MODE_FEATURES:
        rows = list(qs.filter(feature=feat).values_list(
            "input_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens", "cost_usd"))
        n = len(rows)
        cap_mode = "pro" if mode == "upgrade" else mode
        cap = P40.v2_cap_usd(cap_mode)
        if not n:
            modes[mode] = {"calls": 0, "cap_bdt": round(cap * rate, 3)}
            continue
        costs = [r[4] for r in rows]
        modes[mode] = {
            "calls": n,
            "avg_in": int(sum(r[0] for r in rows) / n),
            "avg_cache_read": int(sum(r[1] for r in rows) / n),
            "avg_cache_write": int(sum(r[2] for r in rows) / n),
            "avg_out": int(sum(r[3] for r in rows) / n),
            "avg_bdt": round(sum(costs) / n * rate, 3),
            "p90_bdt": round(_p90(costs) * rate, 3),
            "cap_bdt": round(cap * rate, 3),
            "p90_vs_cap": round(_p90(costs) / cap, 2) if cap else None,
        }
    # what the plans could give at the REAL p90 cost (only with enough data)
    suggest = {}
    sm, pr = modes.get("smart", {}), modes.get("pro", {})
    if sm.get("calls", 0) >= 200:
        f = max(sm["p90_vs_cap"], 0.3)
        for pid in P40.PLANS_V2:
            if "pro" in P40.PLANS_V2[pid]["modes"]:
                if pr.get("calls", 0) < 200:
                    continue
                f = max(pr["p90_vs_cap"], 0.3)
            suggest[pid] = int(P40.v2_plan_credits()[pid] / f) // 10 * 10
    return {"days": days, "modes": modes, "suggested_credits": suggest,
            "current_credits": {pid: int((c["plans"].get(pid) or {}).get("credits") or 0)
                                for pid in P40.PLANS_V2}}


def monthly_report(now=None, notify=True, cfg=None):
    """Monthly job: the real-usage numbers to the owner (push + email +
    FamilyAlert), once per calendar month. Report only — never changes a
    plan. When real cost runs clearly under the caps it says so plainly."""
    out = {"sent": False}
    try:
        rep = monthly_usage(30, now, cfg)
        out["report"] = rep
        sm = rep["modes"].get("smart", {})
        lines = []
        for mode, m in rep["modes"].items():
            if m.get("calls"):
                lines.append("%s: %d বার, গড় ৳%.2f, ৯০%% ক্ষেত্রে ≤ ৳%.2f (সীমা ৳%.2f)" % (
                    mode, m["calls"], m["avg_bdt"], m["p90_bdt"], m["cap_bdt"]))
        if not lines:
            lines.append("এই মাসে চ্যাট মোডে কোনো AI ব্যবহার নেই।")
        more = [pid for pid, n in rep["suggested_credits"].items()
                if n > rep["current_credits"].get(pid, 0)]
        if more:
            lines.append("আসল খরচ সীমার চেয়ে কম — ৪০% লাভ রেখেই বেশি মেসেজ দেওয়া যায়: " + ", ".join(
                "%s %d → %d ক্রেডিট" % (pid, rep["current_credits"][pid], rep["suggested_credits"][pid])
                for pid in more) + "। আপনার অনুমতি ছাড়া কিছু বদলাবে না।")
        elif sm.get("calls", 0) < 200:
            lines.append("বেশি মেসেজ দেওয়ার পরামর্শের জন্য অন্তত ২০০টি স্মার্ট মেসেজের ডেটা লাগবে।")
        body = "\n".join(lines)
        out["body"] = body
        if not notify:
            return out
        from django.contrib.auth import get_user_model
        from .models import FamilyAlert
        month = (timezone.localdate(now) if now else timezone.localdate()).strftime("%Y-%m")
        owners = list(get_user_model().objects.filter(is_superuser=True, is_active=True)[:5])
        first = False
        for o in owners:
            _, created = FamilyAlert.objects.get_or_create(
                user=o, kind=MONTH_KIND, title=("AI real usage %s" % month)[:160],
                defaults={"body": body, "severity": "info",
                          "payload": {"source": "ai_usage_month", "month": month}})
            first = first or created
        if first:
            from . import push
            push.notify_owner("Assisto: মাসিক আসল AI খরচ (%s)" % month, body)
            out["sent"] = True
    except Exception as e:  # noqa: BLE001
        log.warning("ai_cost_alert.monthly_report: %s", type(e).__name__)
        out["error"] = type(e).__name__
    return out
