"""safety-plan (board row 49) — the FAMILY SAFETY PLAN: where we meet, which
numbers to call, and who to call first, written once and shared with the
family so every phone has it — also with no internet (the app keeps the last
copy on the phone).

Benchmark: Life360 has no written family plan; ready.gov / Red Cross
"family emergency plan" cards are paper. Ours is shared live, in Bangla,
pre-filled with Bangladesh national numbers (999, fire, ambulance via 999,
women & children 109, child helpline 1098, disaster 1090) and picks people
from My Circle in one tap.

Storage: ONE PaCollectionItem row per owner (collection "safety_plan") — no
migration. Rules:
  * only the owner edits their plan;
  * it is visible to the owner and to the Circle members the owner shared it
    with (accepted, unblocked, with an account) — re-checked on every read;
  * the "who to call" list holds the owner's own Circle member ids; a reader
    gets the names and numbers resolved from the OWNER's Circle (never the
    reader's other contacts);
  * never paywalled, no ads; nothing here charges (billing.SAFETY_EXEMPT spirit);
  * newly shared members get one notice ("<name> shared a family safety plan").
"""
from __future__ import annotations

import logging
import re

from django.utils import timezone

log = logging.getLogger(__name__)

COLLECTION = "safety_plan"
MAX_NUMBERS = 8
MAX_CALL = 6
MAX_SHARE = 20
MAX_TEXT = 160
MAX_NOTE = 500
_PHONE = re.compile(r"^\+?[0-9][0-9 \-]{1,19}$")

# Bangladesh national numbers (public, free to call). Shown as suggestions;
# the owner may keep, drop or add.
DEFAULT_NUMBERS = [
    {"key": "999", "number": "999", "label_bn": "জাতীয় জরুরি সেবা (পুলিশ, ফায়ার, অ্যাম্বুলেন্স)",
     "label_en": "National emergency (police, fire, ambulance)"},
    {"key": "109", "number": "109", "label_bn": "নারী ও শিশু নির্যাতন প্রতিরোধ",
     "label_en": "Violence against women & children"},
    {"key": "1098", "number": "1098", "label_bn": "শিশু সহায়তা", "label_en": "Child helpline"},
    {"key": "1090", "number": "1090", "label_bn": "দুর্যোগের আগাম বার্তা",
     "label_en": "Disaster early warning"},
    {"key": "16263", "number": "16263", "label_bn": "স্বাস্থ্য বাতায়ন (ডাক্তারের পরামর্শ)",
     "label_en": "Health line (doctor advice)"},
]


class PlanError(Exception):
    def __init__(self, code, status=400):
        super().__init__(code)
        self.code, self.status = code, status


def _clean_text(v, n=MAX_TEXT):
    return re.sub(r"\s+", " ", str(v or "")).strip()[:n]


def _coord(v, lo, hi):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f, 6) if lo <= f <= hi else None


def _point(raw):
    if not isinstance(raw, dict):
        return None
    name = _clean_text(raw.get("name"))
    if not name:
        return None
    lat, lng = _coord(raw.get("lat"), -90, 90), _coord(raw.get("lng"), -180, 180)
    out = {"name": name, "note": _clean_text(raw.get("note"))}
    if lat is not None and lng is not None and not (lat == 0 and lng == 0):
        out.update(lat=lat, lng=lng)
    return out


def _numbers(raw):
    out, seen = [], set()
    for r in raw if isinstance(raw, list) else []:
        if not isinstance(r, dict):
            continue
        num = re.sub(r"[ \-]", "", str(r.get("number") or "").strip())
        if not num or not _PHONE.match(num) or num in seen:
            continue
        seen.add(num)
        out.append({"number": num, "label": _clean_text(r.get("label"), 80)})
        if len(out) >= MAX_NUMBERS:
            break
    return out


def _my_members(owner, ids, limit):
    """Owner's own accepted, unblocked Circle members among `ids` (order kept)."""
    from .models import CircleMember
    want = []
    for x in ids if isinstance(ids, list) else []:
        if str(x).isdigit() and int(x) not in want:
            want.append(int(x))
    rows = {m.pk: m for m in CircleMember.objects.filter(
        user=owner, pk__in=want, state="accepted", blocked=False)}
    return [rows[i] for i in want if i in rows][:limit]


def validate(owner, d):
    """Clean the owner's input. Raises PlanError on nothing useful."""
    d = d if isinstance(d, dict) else {}
    meet = _point(d.get("meeting_point"))
    meet2 = _point(d.get("meeting_point_far"))
    nums = _numbers(d.get("numbers"))
    call = [m.pk for m in _my_members(owner, d.get("call_order"), MAX_CALL)]
    share = [m.pk for m in _my_members(owner, d.get("shared_with"), MAX_SHARE)
             if m.peer_user_id]
    note = _clean_text(d.get("note"), MAX_NOTE)
    if not (meet or meet2 or nums or call):
        raise PlanError("empty")
    return {"meeting_point": meet, "meeting_point_far": meet2, "numbers": nums,
            "call_order": call, "shared_with": share, "note": note}


def _row(owner):
    from .models import PaCollectionItem
    return PaCollectionItem.objects.filter(user=owner, collection=COLLECTION).first()


def save(owner, d, now=None):
    from .models import PaCollectionItem
    now = now or timezone.now()
    clean = validate(owner, d)
    row = _row(owner)
    before = set((row.data or {}).get("shared_with") or []) if row else set()
    clean["updated_at"] = now.isoformat()
    clean["version"] = int(((row.data or {}).get("version") or 0) if row else 0) + 1
    if row is None:
        row = PaCollectionItem.objects.create(user=owner, collection=COLLECTION, data=clean)
    else:
        row.data = clean
        row.save(update_fields=["data", "updated_at"])
    new = [m for m in _my_members(owner, clean["shared_with"], MAX_SHARE)
           if m.pk not in before and m.peer_user_id]
    _tell_shared(owner, new)
    return row


def delete(owner):
    from .models import PaCollectionItem
    PaCollectionItem.objects.filter(user=owner, collection=COLLECTION).delete()


def _tell_shared(owner, members):
    if not members:
        return
    try:
        from . import kidswatch_service as KW
        from . import push as PUSH
        for m in members:
            u = m.peer_user
            nm = PUSH.seen_name(u, owner) or ""
            KW._send([u], "পরিবারের নিরাপত্তা পরিকল্পনা", "Family safety plan",
                     "%s আপনার সঙ্গে পরিবারের নিরাপত্তা পরিকল্পনা শেয়ার করেছেন: কোথায় দেখা হবে, কাকে আগে ফোন করবেন। ইন্টারনেট ছাড়াও দেখা যাবে।" % nm,
                     "%s shared a family safety plan with you: where to meet and who to call first. It opens without internet too." % nm,
                     {"event": "safety_plan_shared", "owner": owner.pk},
                     family_alert=False, route="safety_plan")
    except Exception:  # noqa: BLE001
        log.warning("safety_plan: notify failed")


def _resolve(owner, data, viewer):
    from . import push as PUSH
    from .models import CircleMember
    call = []
    for m in _my_members(owner, data.get("call_order") or [], MAX_CALL):
        # only the number the OWNER saved for this person (never a peer's
        # account phone the owner did not write down)
        phone = (m.phone or "").strip()
        if m.peer_user_id and viewer.pk != owner.pk and viewer.pk != m.peer_user_id:
            name = PUSH.seen_name(viewer, m.peer_user) or m.name
        else:
            name = m.name
        call.append({"member_id": m.pk, "name": (name or "").strip()[:60],
                     "relation": m.relation, "phone": phone[:40],
                     "is_you": bool(m.peer_user_id and m.peer_user_id == viewer.pk)})
    shared = []
    if viewer.pk == owner.pk:
        for m in CircleMember.objects.filter(user=owner, pk__in=data.get("shared_with") or [],
                                             state="accepted", blocked=False):
            shared.append({"member_id": m.pk, "name": (m.name or "")[:60]})
    return {"meeting_point": data.get("meeting_point"),
            "meeting_point_far": data.get("meeting_point_far"),
            "numbers": data.get("numbers") or [], "call_order": call,
            "shared_with": shared if viewer.pk == owner.pk else None,
            "note": data.get("note") or "", "updated_at": data.get("updated_at"),
            "version": data.get("version") or 1}


def can_view(owner, viewer, data=None):
    from .models import CircleMember
    if owner.pk == viewer.pk:
        return True
    data = data if data is not None else ((_row(owner).data or {}) if _row(owner) else {})
    return CircleMember.objects.filter(
        user=owner, pk__in=data.get("shared_with") or [], peer_user=viewer,
        state="accepted", blocked=False).exists()


def overview(viewer, lang="bn"):
    """{mine, shared:[{owner_id, owner_name, plan}], defaults, limits}."""
    from . import push as PUSH
    from .models import CircleMember, PaCollectionItem
    row = _row(viewer)
    mine = _resolve(viewer, row.data or {}, viewer) if row else None
    owners = set(CircleMember.objects.filter(peer_user=viewer, state="accepted", blocked=False)
                 .values_list("user_id", flat=True))
    shared = []
    for r in (PaCollectionItem.objects.filter(collection=COLLECTION, user_id__in=owners)
              .select_related("user").order_by("-updated_at")[:10]):
        data = r.data or {}
        if not can_view(r.user, viewer, data):
            continue
        shared.append({"owner_id": r.user_id,
                       "owner_name": (PUSH.seen_name(viewer, r.user) or "").strip()[:60],
                       "plan": _resolve(r.user, data, viewer)})
    en = lang == "en"
    return {"mine": mine, "shared": shared,
            "defaults": [{"number": n["number"], "label": n["label_en" if en else "label_bn"]}
                         for n in DEFAULT_NUMBERS],
            "limits": {"numbers": MAX_NUMBERS, "call": MAX_CALL, "share": MAX_SHARE}}
