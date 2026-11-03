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


# Integrator (b294): ONE account counter — these delegate to agent/cctvcap's
# core/cctv_cap.py (monthly cctv_traffic doc: ai_used + bought AI packs), the
# same counter the visitor descriptions use. Names kept for cctv_ai_check.

def ai_check_status(camera, now=None):
    from .. import cctv_cap as CAP
    owner = camera.site.owner
    st = CAP.ai_state(owner.pk if hasattr(owner, "pk") else owner, now)
    used, cap = int(st.get("used", 0)), int(st.get("cap", 0))
    return {"used": used, "cap": cap, "left": max(0, cap - used), "month": _month(now)}


def ai_check_allowed(camera, now=None):
    try:
        s = ai_check_status(camera, now)
    except Exception:
        return False          # unknown budget -> no paid call (alert still goes)
    return s["used"] < s["cap"]


def ai_check_used(camera, now=None):
    """Take ONE unit before the paid call. True = taken; False = no room (or
    any failure) -> the caller must NOT make the paid call."""
    from .. import cctv_cap as CAP
    return bool(CAP.ai_try_take(camera.site.owner, now))
