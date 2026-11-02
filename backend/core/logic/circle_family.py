"""
circle_family.py — "Family / Others" separation for My Circle (circlea, 2 Nov).

Pure, deterministic, no DB.  Every place that lists people (chat list,
people, map, every My Circle picker — SOS, CCTV viewers, vehicle drivers,
missing-person alert ...) asks the SAME question: "is this person Family or
Others?".  The answer is:

  1. what the user explicitly marked (CircleMember.circle_group =
     "family" | "others"), else
  2. AUTO: Family when the relation is a family relation (father, mother,
     child, spouse, sibling, relative ...) or the edge is already linked to a
     family entry (Family Care picked them) or a guardian link exists;
     Others otherwise.

So existing family-link data shows as Family with no data migration, and a
user's own mark always wins (WhatsApp/Telegram folders + Life360 Circles
benchmark: the user decides who is family; we only suggest).

Shared by: core.circle_family (DB helpers), core.views_module5._member_dict,
core.famcare.circle_candidates, the missing-person alert (agent/missing).
"""
from __future__ import annotations

GROUP_FAMILY = "family"
GROUP_OTHERS = "others"
GROUPS = (GROUP_FAMILY, GROUP_OTHERS)
# accepted on input to clear the explicit mark (back to automatic)
AUTO_WORDS = ("", "auto", "none", "reset")

# Relations that default to Family.  Wider than circle.CLOSE_FAMILY on
# purpose: in Bangladesh an "আত্মীয়" (relative) is family.
FAMILY_RELATIONS = frozenset({
    "father", "mother", "child", "parent", "husband", "wife", "spouse",
    "brother", "sister", "sibling", "relative", "grandparent", "grandchild",
    "uncle", "aunt", "cousin", "family",
})


def normalize_group(value):
    """'family' | 'others' | '' (auto).  Raises ValueError on anything else so
    the endpoint answers 400 instead of storing junk."""
    v = (value or "").strip().lower()
    if v in AUTO_WORDS:
        return ""
    if v in ("other", "others", "friends", "অন্যরা"):
        return GROUP_OTHERS
    if v in ("family", "পরিবার"):
        return GROUP_FAMILY
    raise ValueError("bad group")


def auto_group(relation, family_linked=False, guardian_linked=False):
    """The suggested group when the user has not marked one."""
    if family_linked or guardian_linked:
        return GROUP_FAMILY
    if (relation or "").strip().lower() in FAMILY_RELATIONS:
        return GROUP_FAMILY
    return GROUP_OTHERS


def effective_group(explicit, relation, family_linked=False, guardian_linked=False):
    """(group, is_auto).  The explicit mark always wins."""
    e = (explicit or "").strip().lower()
    if e in GROUPS:
        return e, False
    return auto_group(relation, family_linked, guardian_linked), True


def filter_rows(rows, group="all", query=""):
    """Filter already-annotated rows ({'circle_group', 'name', 'phone', ...})
    by chip + search.  group: 'all' | 'family' | 'others'."""
    g = (group or "all").strip().lower()
    q = (query or "").strip().lower()
    out = []
    for r in rows:
        if g in GROUPS and (r.get("circle_group") or GROUP_OTHERS) != g:
            continue
        if q:
            hay = " ".join(str(r.get(k) or "") for k in
                           ("name", "display_name", "phone", "relation_label",
                            "custom_label", "nickname")).lower()
            if q not in hay:
                continue
        out.append(r)
    return out


def sectioned(rows):
    """[('family', [...]), ('others', [...])] — Family first, empty sections
    dropped, order inside a section preserved."""
    fam = [r for r in rows if (r.get("circle_group") or "") == GROUP_FAMILY]
    oth = [r for r in rows if (r.get("circle_group") or "") != GROUP_FAMILY]
    return [(k, v) for k, v in ((GROUP_FAMILY, fam), (GROUP_OTHERS, oth)) if v]
