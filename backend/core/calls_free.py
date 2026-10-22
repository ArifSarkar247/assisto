"""dl1 — "Free calls (testing)": the ONE switch every My Circle call gate reads.

While ON, voice + video calls (1:1, group, scheduled, call links; relayed or
peer-to-peer) cost 0 credits and never hit the Premium/upgrade gate, for every
plan. Relay usage and its real cost are still recorded (TurnRelayUsage +
CallRecord.free_testing) so the owner's P&L shows the cost with zero revenue.

Stored as the owner kill-switch `calls_free_testing` in AdminFlagState (Owner
Admin -> Pricing, or the in-app flags console; every flip is audited). With no
stored value the default is settings.CALLS_FREE_TESTING_DEFAULT (True in
production -> live is ON right after deploy; the test settings set it False so
the existing plan-gate tests keep exercising the paid behaviour).
"""
from django.conf import settings

FLAG = "calls_free_testing"


def calls_free():
    """True while the owner's "Free calls (testing)" switch is ON. Never raises."""
    default = bool(getattr(settings, "CALLS_FREE_TESTING_DEFAULT", True))
    try:
        from .models import AdminFlagState
        from .logic import admin_flags as AF
        row = AdminFlagState.objects.filter(key="global").first()
        raw = (row.state if row else None) or {}
        if FLAG in raw:
            return AF._as_bool(raw[FLAG], default)
    except Exception:
        pass
    return default


def entitle(caller):
    """A caller descriptor for the pure call gates (circle_calls /
    circle_groups / msg_messenger_ui): while calls are free it carries the
    video entitlement, so no plan/credit gate can refuse a call."""
    caller = dict(caller or {})
    if calls_free():
        caller["video_unlocked"] = True
        caller["calls_free"] = True
    return caller
