"""
Sales reports — all computed from REAL data (spec §Reports/dashboard):

  - funnel conversion by stage
  - win/loss reasons breakdown
  - average sales-cycle length (created → closed) for won deals
  - source attribution (which channels produce won revenue)
  - rep performance (per-member open/won/lost + won value vs target)
  - pipeline by industry
  - weighted forecast (delegated to forecast.py)

Every function takes already-org-scoped querysets so there is no tenant leak.
When there is no data a function returns zeros / empty lists with a clear
`has_data` flag so the template can show "পর্যাপ্ত ডাটা নেই / Not enough data"
instead of a misleading chart.
"""
from collections import OrderedDict
from decimal import Decimal

from django.db.models import Count, Sum

from .models import Deal, Stage


def funnel(pipeline, deals_qs):
    """Count of deals that have *reached* each stage, in stage order.

    A deal that is now at "Negotiation" has, by definition, passed every earlier
    stage, so for an honest funnel we count current-or-past. Because we only
    store the current stage, we approximate "reached" as: deals currently at this
    stage or any later stage (open) plus won deals (which passed everything).
    This is a documented approximation, not a fabrication.
    """
    stages = list(pipeline.stages.order_by("order"))
    if not stages:
        return {"has_data": False, "rows": []}
    order_of = {s.id: s.order for s in stages}
    deals = list(deals_qs.filter(pipeline=pipeline))
    if not deals:
        return {"has_data": False, "rows": []}

    rows = []
    prev = None
    for s in stages:
        reached = 0
        for d in deals:
            if d.state == "won" and not s.is_lost:
                reached += 1
            elif d.state == "lost":
                # a lost deal reached up to the stage it was lost in
                if order_of.get(d.stage_id, 0) >= s.order and not s.is_lost:
                    reached += 1
            else:  # open
                if order_of.get(d.stage_id, 0) >= s.order and not s.is_lost:
                    reached += 1
        conv = None
        if prev is not None and prev > 0:
            conv = round(reached / prev * 100.0, 1)
        rows.append({"stage": s.name, "reached": reached, "conversion_from_prev": conv})
        if not s.is_lost:
            prev = reached
    return {"has_data": True, "rows": rows}


def win_loss(deals_qs):
    """Win/loss counts + loss-reason breakdown from closed deals."""
    won = deals_qs.filter(state="won").count()
    lost_qs = deals_qs.filter(state="lost")
    lost = lost_qs.count()
    total_closed = won + lost
    reasons = OrderedDict()
    for code, label in Deal.LOSS_REASONS:
        reasons[code] = {"label": label, "count": 0}
    for row in lost_qs.values("loss_reason").annotate(n=Count("id")):
        code = row["loss_reason"] or "other"
        if code in reasons:
            reasons[code]["count"] = row["n"]
    win_rate = round(won / total_closed * 100.0, 1) if total_closed else None
    return {
        "has_data": total_closed > 0,
        "won": won, "lost": lost, "total_closed": total_closed,
        "win_rate": win_rate,
        "loss_reasons": list(reasons.values()),
    }


def sales_cycle(deals_qs):
    """Average days from deal creation to close, for WON deals only."""
    won = [d for d in deals_qs.filter(state="won") if d.closed_at and d.created_at]
    if not won:
        return {"has_data": False, "avg_days": None, "sample": 0}
    total = sum((d.closed_at - d.created_at).days for d in won)
    return {"has_data": True, "avg_days": round(total / len(won), 1), "sample": len(won)}


def source_attribution(deals_qs):
    """Won revenue + count grouped by original source channel."""
    rows = (deals_qs.filter(state="won")
            .values("source")
            .annotate(n=Count("id"), value=Sum("value"))
            .order_by("-value"))
    data = [{"source": r["source"], "count": r["n"],
             "value": float(r["value"] or 0)} for r in rows]
    return {"has_data": bool(data), "rows": data}


def win_rate_by_source(deals_qs):
    """Win RATE per source = won / (won + lost) closed deals of that source.

    Distinct from source_attribution (which gives WON revenue/count only): this
    exposes how EFFECTIVE each channel is at closing, not just how much it
    brought in. Open deals are not yet decided and are excluded. All from real
    data; `win_rate_pct` is None when a source has no closed deals yet.
    """
    rows = {}
    for d in deals_qs.filter(state__in=["won", "lost"]).values(
            "source", "state").annotate(n=Count("id")):
        r = rows.setdefault(d["source"], {"source": d["source"],
                                          "won": 0, "lost": 0})
        r[d["state"]] = d["n"]
    out = []
    for r in rows.values():
        closed = r["won"] + r["lost"]
        r["closed"] = closed
        r["win_rate_pct"] = (round(r["won"] / closed * 100.0, 1)
                             if closed else None)
        out.append(r)
    out.sort(key=lambda x: -(x["win_rate_pct"] or -1))
    return {"has_data": bool(out), "rows": out}


def pipeline_by_industry(deals_qs):
    """Open pipeline value grouped by company industry."""
    out = {}
    for d in deals_qs.filter(state="open").select_related("company"):
        ind = d.company.industry if d.company else "other"
        out.setdefault(ind, {"industry": ind, "count": 0, "value": Decimal(0)})
        out[ind]["count"] += 1
        out[ind]["value"] += (d.value or Decimal(0))
    rows = sorted(({"industry": v["industry"], "count": v["count"],
                    "value": float(v["value"])} for v in out.values()),
                  key=lambda r: -r["value"])
    return {"has_data": bool(rows), "rows": rows}


def rep_performance(org, deals_qs):
    """Per-member open/won/lost counts + won value, with target attainment."""
    from .models import CrmMember, Target
    from . import forecast as fc
    members = list(CrmMember.objects.filter(org=org).select_related("user"))
    rows = []
    for m in members:
        md = deals_qs.filter(owner=m)
        won_val = md.filter(state="won").aggregate(s=Sum("value"))["s"] or Decimal(0)
        tgt = Target.objects.filter(org=org, member=m).order_by("-period").first()
        attain = fc.target_attainment(won_val, tgt.amount) if tgt else None
        rows.append({
            "member_id": m.id,
            "name": getattr(m.user, "name", None) or getattr(m.user, "username", str(m.user_id)),
            "role": m.role,
            "open": md.filter(state="open").count(),
            "won": md.filter(state="won").count(),
            "lost": md.filter(state="lost").count(),
            "won_value": float(won_val),
            "target": float(tgt.amount) if tgt else None,
            "attainment_pct": attain,
        })
    rows.sort(key=lambda r: -r["won_value"])
    return {"has_data": bool(rows), "rows": rows}


def activity_leaderboard(org, activities_qs):
    """Logged-activity count per member (spec: activity leaderboard)."""
    rows = (activities_qs.values("actor")
            .annotate(n=Count("id")).order_by("-n"))
    from .models import CrmMember
    name_of = {m.id: (getattr(m.user, "name", None) or getattr(m.user, "username", str(m.user_id)))
               for m in CrmMember.objects.filter(org=org).select_related("user")}
    data = [{"member_id": r["actor"], "name": name_of.get(r["actor"], "—"),
             "activities": r["n"]} for r in rows if r["actor"]]
    return {"has_data": bool(data), "rows": data}
