"""
cctv_ai_budget.py — the ONE monthly CCTV AI allowance (agent/cctvaicheck).

    ai_check_allowed(camera) -> bool   room left this month for one more AI
                                        look at a camera photo?
    ai_check_used(camera)    -> int    take ONE unit (call BEFORE the paid
                                        call: a paid call is never free);
                                        returns the account's new month total
    ai_check_status(camera)  -> {"used", "cap", "left", "month"}

The allowance is per ACCOUNT (owner order B4: "monthly AI cost cap per
account"), sized `ai_checks_per_camera` (cctv_plan, default 50, owner
approved) x the owner's enabled cameras. Visitor descriptions
(core/cctv_activity.py) and alert-snapshot checks (core/cctv_ai_check.py)
draw from the SAME counter, so the profit table's worst case
(ai_checks_per_camera x ai_check_usd per camera) is never exceeded.

The counter itself is the existing per-site `act["ai"] = {month, used}` in
the site's activity blob (cctv_activity.act_update) — no new table, no
migration. Same names as agent/cctvcap's planned shared counter so the
integrator can point these three functions at it in one place.
"""
from django.utils import timezone


def _month(now=None):
    from .. import cctv_activity as CACT
    return CACT._local(now or timezone.now()).strftime("%Y-%m")


def ai_check_status(camera, now=None):
    from .. import cctv_activity as CACT
    owner = camera.site.owner
    month = _month(now)
    cap = CACT.owner_cap(owner)
    used = CACT._owner_ai_used(owner, month)
    return {"used": used, "cap": cap, "left": max(0, cap - used), "month": month}


def ai_check_allowed(camera, now=None):
    try:
        s = ai_check_status(camera, now)
    except Exception:
        return False          # unknown budget -> no paid call (alert still goes)
    return s["used"] < s["cap"]


def ai_check_used(camera, now=None):
    from .. import cctv_activity as CACT
    from . import cctv_brief as CB
    month = _month(now)
    return CACT.act_update(camera.site, lambda act: CB.ai_take(act, month)) or 0
