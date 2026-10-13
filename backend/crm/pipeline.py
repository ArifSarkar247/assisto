"""
Pipeline helpers: seed a sensible default pipeline for a new org, move a deal
between stages (with audit + stage-age reset), detect "stuck N days" deals, and
route a new lead/deal to a member via RoutingRule (deterministic, first match).

All stage probabilities here are defaults the owner can edit — they drive the
weighted forecast but are clearly editable, not hard-coded truth.
"""
from django.utils import timezone

from .models import (Pipeline, Stage, Deal, CrmMember, RoutingRule, Territory,
                     AuditEntry)

# A standard B2B sales pipeline. Probabilities are editable defaults.
DEFAULT_STAGES = [
    # (name, probability, stuck_after_days, is_won, is_lost)
    ("নতুন / New", 10, 7, False, False),
    ("যোগাযোগ / Qualified", 25, 10, False, False),
    ("ডেমো / Demo", 45, 14, False, False),
    ("প্রপোজাল / Proposal", 65, 14, False, False),
    ("নেগোসিয়েশন / Negotiation", 80, 10, False, False),
    ("জিতেছি / Won", 100, 0, True, False),
    ("হারিয়েছি / Lost", 0, 0, False, True),
]


def ensure_default_pipeline(org):
    """Create the org's default pipeline + stages if none exist. Idempotent."""
    pipe = org.pipelines.filter(is_default=True).first()
    if pipe:
        return pipe
    pipe = Pipeline.objects.create(org=org, name="Axon Sales", is_default=True)
    for i, (name, prob, stuck, won, lost) in enumerate(DEFAULT_STAGES):
        Stage.objects.create(pipeline=pipe, name=name, order=i, probability=prob,
                             stuck_after_days=stuck, is_won=won, is_lost=lost)
    return pipe


def move_deal(deal, new_stage, member=None, note=""):
    """Move a deal to a new stage: update stage + probability default + reset the
    stage-age clock, set won/lost state and closed_at, and write an audit entry.
    Loss reason enforcement is done in the view (needs the reason from the form).
    """
    old = deal.stage
    deal.stage = new_stage
    deal.stage_entered_at = timezone.now()
    deal.probability = new_stage.probability
    if new_stage.is_won:
        deal.state = Deal.WON
        deal.closed_at = timezone.now()
    elif new_stage.is_lost:
        deal.state = Deal.LOST
        deal.closed_at = timezone.now()
    else:
        deal.state = Deal.OPEN
        deal.closed_at = None
    deal.save()
    AuditEntry.objects.create(
        org=deal.org, member=member, action="deal.stage_change",
        entity=f"deal#{deal.id}",
        detail=f"{old.name} → {new_stage.name}" + (f" · {note}" if note else ""))
    return deal


def stuck_deals(deals_qs):
    """Return open deals that have sat in their current stage longer than the
    stage's `stuck_after_days`. Each row includes the age so the UI can warn."""
    now = timezone.now()
    out = []
    for d in deals_qs.filter(state="open").select_related("stage"):
        thresh = d.stage.stuck_after_days or 0
        if thresh <= 0:
            continue
        age = (now - d.stage_entered_at).days
        if age > thresh:
            out.append({"deal_id": d.id, "title": d.title, "stage": d.stage.name,
                        "days": age, "threshold": thresh})
    out.sort(key=lambda r: -r["days"])
    return out


def route_lead(org, industry="other", source="manual", company_size=0):
    """Pick the member a new lead/deal should be assigned to, by the first active
    RoutingRule that matches. Returns (member_or_None, territory_or_None).
    Deterministic: rules are ordered; first match wins; no random assignment."""
    for rule in RoutingRule.objects.filter(org=org, active=True).order_by("order", "id"):
        if rule.match_industry and rule.match_industry != industry:
            continue
        if rule.match_source and rule.match_source != source:
            continue
        if rule.min_company_size and (company_size or 0) < rule.min_company_size:
            continue
        return rule.assign_to, rule.territory
    return None, None
