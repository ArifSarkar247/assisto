"""circle_family.py — DB helpers for the My Circle "Family / Others" field
(circlea).  The pure rules live in core.logic.circle_family; this module only
reads/writes CircleMember.circle_group and the family-link signals.

Public API (stable — agent/missing builds on it):
    group_fields(member, ctx=None)   -> {"circle_group": "family"|"others",
                                         "circle_group_auto": bool}
    link_context(user)               -> ctx for many rows (2 queries total)
    family_member_ids(user)          -> set of the user's CircleMember ids in Family
    set_group(user, member_id, group)-> (member, error_code)
"""
from __future__ import annotations

from .logic import circle_family as CF


def _guardian_link_ids(user):
    """Circle edges of `user` that already guard / watch one of the user's
    children (kids watch guardians, school-mode watchers) -> Family."""
    ids = set()
    try:
        from .models import KidsWatch, SchoolPlan
        for g in KidsWatch.objects.filter(owner=user).values_list("guardian_ids", flat=True):
            ids.update(int(x) for x in (g or []) if str(x).isdigit())
        for w in SchoolPlan.objects.filter(owner=user).values_list("watcher_ids", flat=True):
            ids.update(int(x) for x in (w or []) if str(x).isdigit())
    except Exception:  # noqa: BLE001 — a listing never fails on a hint
        pass
    return ids


def link_context(user):
    """Pre-computed family-link signals for listing many edges of `user`."""
    from .models import FamilyMember
    fam = set(FamilyMember.objects.filter(user=user, circle_member__isnull=False)
              .values_list("circle_member_id", flat=True))
    return {"family": fam, "guardian": _guardian_link_ids(user)}


def group_fields(member, ctx=None):
    explicit = getattr(member, "circle_group", "") or ""
    if explicit in CF.GROUPS:
        return {"circle_group": explicit, "circle_group_auto": False}
    relation = getattr(member, "relation", "") or ""
    if (relation or "").strip().lower() in CF.FAMILY_RELATIONS:
        return {"circle_group": CF.GROUP_FAMILY, "circle_group_auto": True}
    if ctx is None:
        ctx = link_context(member.user)
    g, _ = CF.effective_group("", relation,
                              family_linked=member.id in ctx["family"],
                              guardian_linked=member.id in ctx["guardian"])
    return {"circle_group": g, "circle_group_auto": True}


def family_member_ids(user):
    """Accepted, unblocked Circle edges of `user` that are Family (explicit or
    auto).  Used by pickers that want "Family first" and by alert fan-out."""
    from .models import CircleMember
    ctx = link_context(user)
    out = set()
    for m in CircleMember.objects.filter(user=user, state="accepted", blocked=False):
        if group_fields(m, ctx)["circle_group"] == CF.GROUP_FAMILY:
            out.add(m.id)
    return out


def set_group(user, member_id, group):
    """Mark one of MY edges Family / Others / auto.  Returns (member, error)."""
    from .models import CircleMember
    try:
        g = CF.normalize_group(group)
    except ValueError:
        return None, "bad_group"
    m = CircleMember.objects.filter(user=user, pk=member_id).first()
    if m is None:
        return None, "not_found"
    if m.circle_group != g:
        m.circle_group = g
        m.save(update_fields=["circle_group"])
    return m, None
