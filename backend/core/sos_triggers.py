"""sosat — SOS triggers that do not need the app open, and fall alerts.

All three run INSIDE the existing opt-in Always-on protection foreground
service (AntiTheftService) — no new background service, no WorkManager — and
reach the server through the engine's scoped token (EngineIngestView):

  sos_lockscreen  the "SOS" button on the protection notification (works on
                  the lock screen). The phone already ran a 10 s cancel window.
  sos_power       5 power-button presses within 4 s (opt-in, default off).
                  The phone already ran a 10 s cancel window.
  fall            EXPERIMENTAL opt-in fall detector (free fall -> impact ->
                  stillness). The phone asks "Are you OK?"; the event arrives
                  with confirm=pending + window_s and the SERVER holds it for
                  that window, then alerts the family itself — even if the
                  phone was switched off or broke meanwhile.
  fall_ok         "I'm OK" for a held fall (data.ref = the fall's client id).

Rules (tests: core/tests_sosat.py):
  * SOS triggers go through family_alerts.sos (the same single SOS path as
    every other surface: idempotent per client id, rings in quiet hours,
    never rate-limited, FREE on every plan).
  * A trigger that only reaches the server more than SOS_LATE_MAX_S after it
    happened (phone was offline for hours) is stored on the timeline and NOT
    rung — ringing a family about a two-hour-old SOS as if it were live would
    be dishonest; the delivery says "too_late".
  * A fall is escalated at most once (atomic), never if "I'm OK" came first,
    and Assisto NEVER calls 999 by itself.
"""
import logging
from datetime import timedelta

from django.utils import timezone

log = logging.getLogger(__name__)

TRIGGER_KINDS = {"sos_lockscreen", "sos_power", "fall", "fall_ok"}
SOS_LATE_MAX_S = 2 * 3600
FALL_WINDOW_DEFAULT_S = 60
FALL_WINDOW_MIN_S, FALL_WINDOW_MAX_S = 30, 600
FALL_LATE_MAX_S = 2 * 3600


def clamp_window(v):
    try:
        n = int(v)
    except (TypeError, ValueError):
        return FALL_WINDOW_DEFAULT_S
    return max(FALL_WINDOW_MIN_S, min(FALL_WINDOW_MAX_S, n))


def _set(ev, **fields):
    from .models import AntiTheftEvent
    AntiTheftEvent.objects.filter(pk=ev.pk).update(**fields)
    for k, v in fields.items():
        setattr(ev, k, v)


def handle(phone, ev, now=None):
    """Called by EngineIngestView for a freshly stored trigger event. Returns
    the escalate_at of a held fall (for the in-process timer) or None. The
    caller drops the event from the generic anti-theft alert path."""
    from . import family_alerts as FA
    now = now or timezone.now()
    owner = phone.owner
    d = dict(ev.data or {})
    age = (now - ev.at).total_seconds()
    if ev.kind in ("sos_lockscreen", "sos_power"):
        if age > SOS_LATE_MAX_S:
            d["sos"] = "too_late"
            _set(ev, data=d, alerted=True, alerted_at=now, recipients=0)
            return None
        st = FA.sos(owner, lat=ev.lat, lng=ev.lng, client_id="e%s" % ev.client_id,
                    source=ev.kind, now=now)
        d["sos"] = "sent"
        _set(ev, data=d, alerted=True, alerted_at=now,
             recipients=min(32767, int(st.get("recipients", 0))))
        return None
    if ev.kind == "fall_ok":
        ref = str(d.get("ref") or "")[:64]
        if ref:
            cancel_fall(phone, client_id=ref, now=now)
        _set(ev, alerted=True)
        return None
    if ev.kind == "fall":
        if d.get("confirm") == "ok":     # answered on the phone before upload
            _set(ev, alerted=True)
            return None
        if age > FALL_LATE_MAX_S:
            d["fall"] = "too_late"
            _set(ev, data=d, alerted=True, alerted_at=now, recipients=0)
            return None
        win = clamp_window(d.get("window_s"))
        d["window_s"] = win
        esc = ev.at + timedelta(seconds=win)
        _set(ev, data=d, escalate_at=max(esc, now))
        if esc <= now:
            escalate_fall(ev, now)
            return None
        return esc
    return None


def cancel_fall(phone, client_id=None, now=None):
    """'I'm OK' — cancels the held fall (the newest pending one when no id)."""
    from .models import AntiTheftEvent
    now = now or timezone.now()
    qs = AntiTheftEvent.objects.filter(phone=phone, kind="fall", alerted=False,
                                       escalate_at__isnull=False)
    if client_id:
        qs = qs.filter(client_id=client_id)
    n = 0
    for ev in list(qs.order_by("-at")[:5]):
        d = dict(ev.data or {})
        d["confirm"] = "ok"
        n += AntiTheftEvent.objects.filter(
            pk=ev.pk, alerted=False, escalate_at__isnull=False).update(
            escalate_at=None, alerted=True, data=d)
        if not client_id:
            break
    return n


def escalate_fall(ev, now=None):
    """No answer within the window -> the family (accepted circle) gets a
    full-screen alert with the location. Atomic: at most once."""
    from . import family_alerts as FA
    from .models import AntiTheftEvent, ProtectedPhone
    now = now or timezone.now()
    won = AntiTheftEvent.objects.filter(
        pk=ev.pk, alerted=False, escalate_at__isnull=False).update(escalate_at=None)
    if not won:
        return False
    ev.refresh_from_db()
    d = dict(ev.data or {})
    if d.get("confirm") == "ok":
        AntiTheftEvent.objects.filter(pk=ev.pk).update(alerted=True)
        return False
    phone = ProtectedPhone.objects.select_related("owner").get(pk=ev.phone_id)
    mins = max(1, int(round(int(d.get("window_s") or FALL_WINDOW_DEFAULT_S) / 60.0)))
    st = FA.alert(phone.owner, "fall", "e%d" % ev.id,
                  payload={"window_min": mins, "experimental": True},
                  lat=ev.lat, lng=ev.lng, now=now)
    d["confirm"] = "timeout"
    d["fall"] = "sent"
    AntiTheftEvent.objects.filter(pk=ev.pk).update(
        alerted=True, alerted_at=now, data=d,
        recipients=min(32767, int(st.get("recipients", 0))))
    return True


def escalate_due(now=None, phone=None):
    from .models import AntiTheftEvent
    now = now or timezone.now()
    qs = AntiTheftEvent.objects.filter(kind="fall", alerted=False,
                                       escalate_at__lte=now)
    if phone is not None:
        qs = qs.filter(phone=phone)
    n = 0
    for ev in list(qs[:50]):
        try:
            if escalate_fall(ev, now):
                n += 1
        except Exception as e:
            log.warning("sos_triggers: fall escalate failed %s", type(e).__name__)
    return n


def pending_fall(user, now=None):
    """The user's newest held fall (for the app's "Are you OK?" screen)."""
    from .models import AntiTheftEvent
    ev = (AntiTheftEvent.objects.filter(phone__owner=user, kind="fall",
                                        alerted=False, escalate_at__isnull=False)
          .order_by("-at").first())
    if ev is None:
        return None
    now = now or timezone.now()
    return {"client_id": ev.client_id, "at": ev.at.isoformat(),
            "seconds_left": max(0, int((ev.escalate_at - now).total_seconds()))}
