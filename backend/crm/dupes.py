"""
Duplicate detection + merge (spec §Leads/contacts/companies).

Detection is deterministic: two leads (or contacts, or companies) are candidate
duplicates when a normalised key matches — email (lowercased), phone (digits
only, last 10), or a normalised company+name. We never auto-merge; we surface
candidates and a human confirms. Merge folds all related rows (conversations,
activities, deals, proposals) onto the survivor and deletes the duplicate.
"""
import re
from collections import defaultdict

from .models import Lead, Contact, Company, Conversation, Activity, Deal, Proposal


def _norm_phone(p):
    digits = re.sub(r"\D", "", p or "")
    return digits[-10:] if len(digits) >= 10 else digits


def _norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def find_lead_duplicates(org):
    """Group leads of an org by email / phone / (company+name). Returns a list of
    groups, each a list of lead ids with ≥2 members (true candidate dupes)."""
    buckets = defaultdict(list)
    for lead in Lead.objects.filter(org=org):
        keys = set()
        if lead.email:
            keys.add(("email", _norm(lead.email)))
        ph = _norm_phone(lead.phone)
        if ph:
            keys.add(("phone", ph))
        if lead.company and lead.name:
            keys.add(("cn", _norm(lead.company) + "|" + _norm(lead.name)))
        for k in keys:
            buckets[k].append(lead.id)
    groups = []
    seen = set()
    for key, ids in buckets.items():
        ids = sorted(set(ids))
        if len(ids) >= 2:
            sig = tuple(ids)
            if sig not in seen:
                seen.add(sig)
                groups.append({"match_on": key[0], "lead_ids": ids})
    return groups


def merge_leads(survivor_id, duplicate_ids, org):
    """Fold duplicate leads into the survivor, then delete the duplicates.

    All child rows (conversations, activities, deals, proposals) are re-pointed
    to the survivor. The survivor keeps its own field values; blank fields are
    backfilled from the first duplicate that has them (no data invented).
    Returns the survivor Lead.

    Every query is scoped to ``org`` so a merge can never reach across tenants,
    even if a caller forgets to pre-scope the ids (defence in depth).
    """
    survivor = Lead.objects.get(id=survivor_id, org=org)
    dups = list(Lead.objects.filter(org=org, id__in=duplicate_ids)
                .exclude(id=survivor_id))
    for d in dups:
        Conversation.objects.filter(lead=d).update(lead=survivor)
        Activity.objects.filter(org=org, lead=d).update(lead=survivor)
        Deal.objects.filter(org=org, lead=d).update(lead=survivor)
        Proposal.objects.filter(lead=d).update(lead=survivor)
        # Backfill blank survivor fields from the duplicate (never overwrite).
        for f in ("name", "company", "phone", "email"):
            if not getattr(survivor, f) and getattr(d, f):
                setattr(survivor, f, getattr(d, f))
        if survivor.company_size == 0 and d.company_size:
            survivor.company_size = d.company_size
    survivor.save()
    for d in dups:
        d.delete()
    return survivor


def find_company_duplicates(org):
    buckets = defaultdict(list)
    for c in Company.objects.filter(org=org):
        buckets[_norm(c.name)].append(c.id)
    return [{"match_on": "name", "company_ids": sorted(ids)}
            for ids in buckets.values() if len(ids) >= 2]
