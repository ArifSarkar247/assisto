"""carecall (owner order 4 Nov 01:50) — Care Call / কেয়ার কল.

A family member (the SETTER) schedules a reminder for a loved one (the
RECEIVER): any text — NEVER filtered, blocked or rewritten (medicine words
included) — plus an optional recording in the setter's OWN voice (no AI
voice, ever; the phone falls back to a normal Bangla TTS voice reading the
text). At the time the receiver's phone rings full-screen like a real call.

Ring ladder per slot (CareCallRing), reusing the old hidden medicine module's
escalation rule (logic/medicine.py: reminder -> re-remind -> caregiver alert,
quiet hours deferred, never woken at night):
    T            ring #1 (push; the receiver's phone ALSO rings from its own
                 alarm, so a phone without internet still rings)
    T+3 min      no Done / Snooze -> miss #1, retry at T+10 min
    T+10 min     ring #2
    T+13 min     no answer -> miss #2 -> the setter is told (amber card +
                 push "did not answer twice", Call now / See location)
    Done         -> green card "confirmed" for the setter (also after a late,
                 offline-queued Done: "confirmed late")
    Snooze       -> ring again 10 min later (a snoozed ring that is not
                 answered counts as a miss like any other)

Rules (tests in core/tests_carecall.py):
  * CONSENT — one link per (setter, receiver): the receiver accepts once
    ("Arif wants to send you Care Calls, accept?") and can stop any time;
    nothing rings unless the link is accepted. Only accepted, unblocked
    My Circle members (family_alerts.consenting_members) can be picked.
  * QUIET HOURS — the receiver's own Care Call window (default 22:00-07:00
    copied from Circle privacy DND when it is on): a ring due inside it waits
    until the window ends.
  * FAIR LIMITS — free, owner-editable (Owner Admin -> Pricing -> limits):
    active schedules per setter, rings per receiver per day, voice seconds,
    text characters. Over a limit = a clear refusal, never a silent cut.
  * Safety-adjacent, so never charged and never shows ads.
"""
import base64
import logging
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from django.core.files.base import ContentFile
from django.db import IntegrityError, transaction
from django.utils import timezone

log = logging.getLogger(__name__)

FLAG = "care_call"
TZ = ZoneInfo("Asia/Dhaka")
RETRY_MIN = 10          # owner: "retry after 10 minutes"
ANSWER_WAIT_MIN = 3     # a ring without Done / Snooze within 3 min = a miss
SNOOZE_MIN = 10         # "Remind me in 10 minutes"
MAX_MISSES = 2          # "did not answer twice" -> tell the setter
MAX_SNOOZES = 6
STALE_MIN = 30          # a slot more than 30 min old (server was down) never rings late
VOICE_MAX_BYTES = 900 * 1024
REPEATS = ("once", "daily", "days")
DEFAULT_QUIET = ("22:00", "07:00")

LIMIT_DEFAULTS = {
    "carecall_active_per_setter": 10,
    "carecall_rings_per_receiver_day": 20,
    "carecall_voice_max_seconds": 30,
    "carecall_text_max_chars": 300,
}

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_num(v):
    return str(v).translate(_BN)


def limits():
    out = dict(LIMIT_DEFAULTS)
    try:
        from . import billing
        lim = billing.cfg()["limits"]
        for k in out:
            if k in lim:
                out[k] = int(lim[k])
    except Exception:  # noqa: BLE001 — a config glitch never blocks a Care Call
        pass
    return out


# ------------------------------------------------------------------ time
def hhmm_min(s):
    try:
        h, m = (int(x) for x in str(s).split(":"))
        if 0 <= h < 24 and 0 <= m < 60:
            return h * 60 + m
    except (TypeError, ValueError):
        pass
    return None


def valid_hhmm(s):
    return hhmm_min(s) is not None and len(str(s)) == 5


def in_quiet(local_dt, qs, qe):
    """Same rule as logic.medicine.in_quiet_hours (overnight wrap; empty or
    equal ends = never quiet)."""
    from .logic.medicine import in_quiet_hours
    if not valid_hhmm(qs) or not valid_hhmm(qe) or qs == qe:
        return False
    return in_quiet_hours(local_dt.time(), qs, qe)


def after_quiet(dt, qs, qe):
    """`dt` (aware) moved to the end of the receiver's quiet window when it
    falls inside it; unchanged otherwise."""
    loc = dt.astimezone(TZ)
    if not in_quiet(loc, qs, qe):
        return dt
    e = hhmm_min(qe)
    end = loc.replace(hour=e // 60, minute=e % 60, second=0, microsecond=0)
    if end <= loc:
        end += timedelta(days=1)
    return end


def slot_of(dt):
    return dt.astimezone(TZ).strftime("%Y%m%d%H%M")


def slot_dt(slot):
    try:
        return datetime.strptime(str(slot), "%Y%m%d%H%M").replace(tzinfo=TZ)
    except (TypeError, ValueError):
        return None


def next_slot(repeat, time_hhmm, days, once_date, after):
    """The first scheduled ring strictly after `after` (aware), or None.
    days: 0 = Monday ... 6 = Sunday (Python weekday)."""
    m = hhmm_min(time_hhmm)
    if m is None:
        return None
    t = time(m // 60, m % 60)
    loc = after.astimezone(TZ)
    if repeat == "once":
        if not once_date:
            return None
        d = datetime.combine(once_date, t).replace(tzinfo=TZ)
        return d if d > loc else None
    wanted = None if repeat == "daily" else {int(x) for x in (days or []) if str(x).isdigit() and 0 <= int(x) <= 6}
    if repeat == "days" and not wanted:
        return None
    for i in range(0, 8):
        day = loc.date() + timedelta(days=i)
        d = datetime.combine(day, t).replace(tzinfo=TZ)
        if d <= loc:
            continue
        if wanted is None or day.weekday() in wanted:
            return d
    return None


def time_label(dt, lang):
    """'9:02 AM' / 'সকাল ৯:০২' (Dhaka time)."""
    loc = dt.astimezone(TZ)
    h, mi = loc.hour, loc.minute
    h12 = h % 12 or 12
    if lang == "en":
        return "%d:%02d %s" % (h12, mi, "AM" if h < 12 else "PM")
    part = ("রাত" if h < 4 else "ভোর" if h < 6 else "সকাল" if h < 12 else
            "দুপুর" if h < 15 else "বিকাল" if h < 18 else "সন্ধ্যা" if h < 20 else "রাত")
    return "%s %s" % (part, bn_num("%d:%02d" % (h12, mi)))


# --------------------------------------------------------------- people
def _edge(owner, other):
    from .family_alerts import _edge as fa_edge
    return fa_edge(owner, other)


def name_for(viewer, other):
    """`other` as `viewer` saved them in My Circle (e.g. 'Ammu'), else the
    public display name."""
    try:
        e = _edge(viewer, other)
        if e is not None:
            n = (e.name or "").strip()
            if not n:
                from .famcare import _edge_name
                n = (_edge_name(e) or "").strip()
            if n:
                return n
    except Exception:  # noqa: BLE001
        pass
    from .push import display_name
    return display_name(other)


def initial(name):
    n = (name or "").strip()
    return n[:1].upper() if n else "?"


def is_family(setter, receiver):
    from .family_alerts import is_member
    return receiver.pk != setter.pk and is_member(setter, receiver)


def link_of(setter, receiver):
    from .models import CareCallLink
    return CareCallLink.objects.filter(setter=setter, receiver=receiver).first()


def _default_quiet(receiver):
    """A new link copies the receiver's own quiet window: an existing Care
    Call link of theirs, else Circle privacy DND when on, else 22:00-07:00."""
    from .models import CareCallLink, CirclePrivacy
    other = CareCallLink.objects.filter(receiver=receiver).order_by("-id").first()
    if other is not None:
        return other.quiet_start, other.quiet_end
    row = CirclePrivacy.objects.filter(user=receiver).first()
    if row is not None and row.dnd_enabled and valid_hhmm(row.dnd_start) and valid_hhmm(row.dnd_end):
        return row.dnd_start, row.dnd_end
    return DEFAULT_QUIET


def can_see_location(setter, receiver):
    """'See location' only where location sharing ALREADY exists for this
    pair: the receiver has an active Safe Journey that the setter watches."""
    try:
        from .models import CircleMember, Journey
        edges = CircleMember.objects.filter(user=receiver, peer_user=setter).values_list("id", flat=True)
        return Journey.objects.filter(traveller=receiver, status="active",
                                      watchers__member_id__in=list(edges)).exists()
    except Exception:  # noqa: BLE001
        return False


def people(setter):
    """My Circle family I can send Care Calls to (Family group first)."""
    from .family_alerts import consenting_members
    out = []
    for u, m in consenting_members(setter):
        name = name_for(setter, u)
        ln = link_of(setter, u)
        out.append({
            "user_id": u.pk, "name": name, "initial": initial(name),
            "relation": m.relation or "", "circle_group": getattr(m, "circle_group", "") or "",
            "link": ln.status if ln else "none",
            "quiet_start": ln.quiet_start if ln else "", "quiet_end": ln.quiet_end if ln else "",
        })
    out.sort(key=lambda r: (0 if r["circle_group"] == "family" else 1, r["name"].lower()))
    return out


# --------------------------------------------------------------- pushes
def _push(user, kind, tbn, ten, bbn="", ben="", data=None, high=False):
    try:
        from .push import push_to_user_async
        return push_to_user_async(user, kind, tbn, ten, bbn, ben, data=data or {},
                                  high_priority=high)
    except Exception:  # noqa: BLE001
        return False


def _invite_push(link):
    s_name = name_for(link.receiver, link.setter)
    _push(link.receiver, "carecall_invite",
          "%s আপনাকে কেয়ার কল পাঠাতে চান" % s_name,
          "%s wants to send you Care Calls" % s_name,
          "রাজি হলে উনি ঠিক সময়ে আপনাকে কল করে মনে করিয়ে দেবেন। খুলে হ্যাঁ বা না বলুন।",
          "If you agree, they can remind you at the right time with a call. Open to accept or decline.",
          data={"route": "carecall", "setter_id": str(link.setter_id)})


def _ring_push(ring):
    cc = ring.care_call
    s_name = name_for(cc.receiver, cc.setter)
    data = {
        "route": "carecall", "care_call_id": str(cc.pk), "slot": ring.slot,
        "slot_key": "%s-%s" % (cc.pk, ring.slot), "attempt": str(ring.attempts),
        "setter_id": str(cc.setter_id), "setter_name": s_name,
        "setter_initial": initial(s_name), "text": cc.text,
        "voice_rev": str(cc.voice_rev if cc.voice else 0),
    }
    return _push(cc.receiver, "carecall",
                 "%s আপনাকে মনে করিয়ে দিচ্ছেন" % s_name,
                 "%s is reminding you" % s_name,
                 cc.text, cc.text, data=data, high=True)


def _status_push(ring, what):
    cc = ring.care_call
    r_name = name_for(cc.setter, cc.receiver)
    at = ring.answered_at if what in ("done", "late") else (ring.escalated_at or timezone.now())
    tbn_t, ten_t = time_label(at, "bn"), time_label(at, "en")
    if what == "missed":
        tbn = "কেয়ার কল %s — %s দুবার ধরেননি" % (tbn_t, r_name)
        ten = "Care Call %s — %s did not answer twice" % (ten_t, r_name)
        bbn, ben = "এখনই কল করুন। “%s”" % cc.text, "Call them now. “%s”" % cc.text
    elif what == "late":
        tbn = "কেয়ার কল %s — %s দেরিতে নিশ্চিত করেছেন ✓" % (tbn_t, r_name)
        ten = "Care Call %s — %s confirmed late ✓" % (ten_t, r_name)
        bbn = ben = cc.text
    else:
        tbn = "কেয়ার কল %s — %s নিশ্চিত করেছেন ✓" % (tbn_t, r_name)
        ten = "Care Call %s — %s confirmed ✓" % (ten_t, r_name)
        bbn = ben = cc.text
    _push(cc.setter, "carecall_status", tbn, ten, bbn, ben,
          data={"route": "carecall", "ring_id": str(ring.pk), "status": what},
          high=what == "missed")


def _link_push(link, what):
    r_name = name_for(link.setter, link.receiver)
    if what == "accepted":
        tbn, ten = "%s কেয়ার কলে রাজি হয়েছেন" % r_name, "%s accepted your Care Calls" % r_name
        bbn, ben = "এখন থেকে আপনার কেয়ার কল ঠিক সময়ে বাজবে।", "Your Care Calls will now ring on time."
    else:
        tbn, ten = "%s কেয়ার কল বন্ধ করেছেন" % r_name, "%s turned off your Care Calls" % r_name
        bbn, ben = "উনি আবার চালু না করা পর্যন্ত কোনো কেয়ার কল বাজবে না।", "No Care Call will ring until they turn it back on."
    _push(link.setter, "carecall_status", tbn, ten, bbn, ben,
          data={"route": "carecall", "status": what})


# --------------------------------------------------------------- schedules
def _clean(data, lim):
    """(fields, error). The text is kept EXACTLY as written (only outer
    whitespace trimmed) — never filtered, blocked or rewritten."""
    text = str((data or {}).get("text") or "").strip()
    has_voice = bool((data or {}).get("voice_b64")) or bool((data or {}).get("keep_voice"))
    if not text and not has_voice:
        return None, "text_required"
    if len(text) > lim["carecall_text_max_chars"]:
        return None, "text_too_long"
    t = str((data or {}).get("time") or "").strip()
    if not valid_hhmm(t):
        return None, "bad_time"
    repeat = str((data or {}).get("repeat") or "daily")
    if repeat not in REPEATS:
        return None, "bad_repeat"
    days = []
    once = None
    if repeat == "days":
        raw = (data or {}).get("days") or []
        days = sorted({int(x) for x in raw if str(x).isdigit() and 0 <= int(x) <= 6})
        if not days:
            return None, "bad_days"
    if repeat == "once":
        try:
            once = date.fromisoformat(str((data or {}).get("date") or "")[:10])
        except ValueError:
            once = timezone.localtime(timezone.now(), TZ).date()
    return {"text": text, "time_hhmm": t, "repeat": repeat, "days": days, "once_date": once}, None


def _voice(data, lim):
    """(bytes or None, seconds, error)."""
    b64 = (data or {}).get("voice_b64")
    if not b64:
        return None, 0, None
    try:
        raw = base64.b64decode(str(b64), validate=False)
    except Exception:  # noqa: BLE001
        return None, 0, "bad_voice"
    try:
        sec = int(float((data or {}).get("voice_sec") or 0))
    except (TypeError, ValueError):
        sec = 0
    if not raw or len(raw) > VOICE_MAX_BYTES or sec > lim["carecall_voice_max_seconds"] + 1:
        return None, 0, "voice_too_long"
    return raw, max(1, sec), None


def active_count(setter):
    from .models import CareCall
    return CareCall.objects.filter(setter=setter, active=True).count()


def create(setter, data):
    """(care_call, link, error)."""
    from django.contrib.auth import get_user_model
    from .models import CareCall, CareCallLink
    lim = limits()
    try:
        rid = int((data or {}).get("receiver_id"))
    except (TypeError, ValueError):
        return None, None, "not_in_circle"
    receiver = get_user_model().objects.filter(pk=rid).first()
    if receiver is None or not is_family(setter, receiver):
        return None, None, "not_in_circle"
    link = link_of(setter, receiver)
    if link is not None and link.status in ("declined", "stopped"):
        return None, link, "receiver_stopped"
    if active_count(setter) >= lim["carecall_active_per_setter"]:
        return None, link, "limit_active"
    fields, err = _clean(data, lim)
    if err:
        return None, link, err
    raw, sec, err = _voice(data, lim)
    if err:
        return None, link, err
    now = timezone.now()
    with transaction.atomic():
        if link is None:
            qs, qe = _default_quiet(receiver)
            try:
                with transaction.atomic():
                    link = CareCallLink.objects.create(setter=setter, receiver=receiver,
                                                       quiet_start=qs, quiet_end=qe)
                new_link = True
            except IntegrityError:
                link = link_of(setter, receiver)
                new_link = False
        else:
            new_link = False
        cc = CareCall(setter=setter, receiver=receiver, **fields)
        cc.next_at = next_slot(cc.repeat, cc.time_hhmm, cc.days, cc.once_date, now)
        if raw:
            cc.voice.save("cc_%s_%s.m4a" % (setter.pk, int(now.timestamp())), ContentFile(raw), save=False)
            cc.voice_rev, cc.voice_sec = 1, sec
        cc.save()
    if new_link or link.status == "pending":
        if new_link:
            _invite_push(link)
    return cc, link, None


def update(setter, cc_id, data):
    from .models import CareCall
    cc = CareCall.objects.filter(pk=cc_id, setter=setter).first()
    if cc is None:
        return None, "not_found"
    lim = limits()
    fields, err = _clean(dict(data or {}, keep_voice=bool(cc.voice) and not (data or {}).get("delete_voice")), lim)
    if err:
        return None, err
    raw, sec, err = _voice(data, lim)
    if err:
        return None, err
    for k, v in fields.items():
        setattr(cc, k, v)
    if raw:
        cc.voice.save("cc_%s_%s.m4a" % (setter.pk, int(timezone.now().timestamp())), ContentFile(raw), save=False)
        cc.voice_rev, cc.voice_sec = cc.voice_rev + 1, sec
    elif (data or {}).get("delete_voice") and cc.voice:
        cc.voice.delete(save=False)
        cc.voice = None
        cc.voice_rev, cc.voice_sec = cc.voice_rev + 1, 0
    if "active" in (data or {}):
        want = bool((data or {}).get("active"))
        if want and not cc.active and active_count(setter) >= lim["carecall_active_per_setter"]:
            return None, "limit_active"
        cc.active = want
    cc.next_at = next_slot(cc.repeat, cc.time_hhmm, cc.days, cc.once_date, timezone.now()) if cc.active else None
    cc.save()
    return cc, None


def delete(setter, cc_id):
    from .models import CareCall
    cc = CareCall.objects.filter(pk=cc_id, setter=setter).first()
    if cc is None:
        return False
    if cc.voice:
        try:
            cc.voice.delete(save=False)
        except Exception:  # noqa: BLE001
            pass
    cc.delete()
    return True


# --------------------------------------------------------------- consent
def decide(receiver, setter_id, accept):
    """Receiver: accept / decline (or stop) a setter. Returns link or None."""
    from .models import CareCallLink
    link = CareCallLink.objects.filter(receiver=receiver, setter_id=setter_id).first()
    if link is None:
        return None
    was = link.status
    link.status = "accepted" if accept else ("stopped" if was == "accepted" else "declined")
    link.decided_at = timezone.now()
    link.save(update_fields=["status", "decided_at"])
    if accept and was != "accepted":
        from .models import CareCall
        now = timezone.now()
        for cc in CareCall.objects.filter(setter_id=setter_id, receiver=receiver, active=True):
            cc.next_at = next_slot(cc.repeat, cc.time_hhmm, cc.days, cc.once_date, now)
            cc.save(update_fields=["next_at"])
        _link_push(link, "accepted")
    elif not accept and was == "accepted":
        # stop at once: rings already waiting never go out
        from .models import CareCallRing
        CareCallRing.objects.filter(care_call__setter_id=setter_id, care_call__receiver=receiver,
                                    status__in=("pending", "ringing", "snoozed")).update(status="off", due_at=None)
        _link_push(link, "stopped")
    return link


def set_quiet(receiver, qs, qe):
    """The receiver's own Care Call quiet hours ("" + "" = none), applied to
    every setter at once."""
    from .models import CareCallLink
    if (qs or qe) and not (valid_hhmm(qs) and valid_hhmm(qe)):
        return False
    CareCallLink.objects.filter(receiver=receiver).update(quiet_start=qs or "", quiet_end=qe or "")
    return True


# --------------------------------------------------------------- answers
def ack(receiver, cc_id, slot, action, now=None):
    """Receiver's Done / Snooze for one slot (live or from the offline
    queue). Idempotent. Returns (ring, error)."""
    from .models import CareCall, CareCallRing
    now = now or timezone.now()
    cc = CareCall.objects.filter(pk=cc_id, receiver=receiver).select_related("setter", "receiver").first()
    if cc is None:
        return None, "not_found"
    sd = slot_dt(slot)
    if sd is None or action not in ("done", "snooze"):
        return None, "bad_ack"
    ring, _ = CareCallRing.objects.get_or_create(
        care_call=cc, slot=slot_of(sd),
        defaults={"scheduled_at": sd, "status": "ringing", "attempts": 1, "last_ring_at": now})
    if ring.status == "done":
        return ring, None
    if action == "done":
        late = ring.status == "missed"
        ring.status, ring.answered_at, ring.due_at, ring.late = "done", now, None, late
        ring.save(update_fields=["status", "answered_at", "due_at", "late"])
        _status_push(ring, "late" if late else "done")
        return ring, None
    if ring.status == "off":
        return ring, None
    if ring.snoozes >= MAX_SNOOZES:
        return ring, "snooze_limit"
    ring.status, ring.snoozes = "snoozed", ring.snoozes + 1
    ring.due_at = now + timedelta(minutes=SNOOZE_MIN)
    ring.save(update_fields=["status", "snoozes", "due_at"])
    return ring, None


# --------------------------------------------------------------- the tick
def _rings_today(receiver, now):
    from .models import CareCallRing
    start = timezone.localtime(now, TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    return CareCallRing.objects.filter(care_call__receiver=receiver, scheduled_at__gte=start).count()


def tick(now=None):
    """One minute of Care Call work. Idempotent; returns counters."""
    from .models import CareCall, CareCallLink, CareCallRing
    now = now or timezone.now()
    out = {"made": 0, "rang": 0, "missed": 0, "escalated": 0, "skipped": 0}
    lim = limits()
    # 1. materialise due slots
    for cc in CareCall.objects.filter(active=True, next_at__isnull=False, next_at__lte=now)[:500]:
        link = CareCallLink.objects.filter(setter_id=cc.setter_id, receiver_id=cc.receiver_id).first()
        sched = cc.next_at
        ok = (link is not None and link.status == "accepted"
              and now - sched <= timedelta(minutes=STALE_MIN)
              and _rings_today(cc.receiver, now) < lim["carecall_rings_per_receiver_day"])
        if ok:
            _, made = CareCallRing.objects.get_or_create(
                care_call=cc, slot=slot_of(sched),
                defaults={"scheduled_at": sched, "status": "pending",
                          "due_at": after_quiet(sched, link.quiet_start, link.quiet_end)})
            out["made"] += int(made)
        else:
            out["skipped"] += 1
        cc.next_at = next_slot(cc.repeat, cc.time_hhmm, cc.days, cc.once_date, sched)
        if cc.repeat == "once" and cc.next_at is None:
            cc.active = False
        cc.save(update_fields=["next_at", "active", "updated_at"])
    # 2. rings due (first ring, retry, snooze)
    due = (CareCallRing.objects.filter(status__in=("pending", "snoozed"), due_at__lte=now)
           .select_related("care_call", "care_call__setter", "care_call__receiver")[:500])
    for ring in due:
        cc = ring.care_call
        link = CareCallLink.objects.filter(setter_id=cc.setter_id, receiver_id=cc.receiver_id).first()
        if link is None or link.status != "accepted":
            ring.status, ring.due_at = "off", None
            ring.save(update_fields=["status", "due_at"])
            continue
        later = after_quiet(now, link.quiet_start, link.quiet_end)
        if later > now:
            ring.due_at = later
            ring.save(update_fields=["due_at"])
            continue
        ring.attempts += 1
        ring.status, ring.last_ring_at = "ringing", now
        ring.due_at = now + timedelta(minutes=ANSWER_WAIT_MIN)
        ring.save(update_fields=["attempts", "status", "last_ring_at", "due_at"])
        _ring_push(ring)
        out["rang"] += 1
    # 3. unanswered rings
    for ring in (CareCallRing.objects.filter(status="ringing", due_at__lte=now)
                 .select_related("care_call", "care_call__setter", "care_call__receiver")[:500]):
        ring.misses += 1
        out["missed"] += 1
        if ring.misses >= MAX_MISSES:
            ring.status, ring.escalated_at, ring.due_at = "missed", now, None
            ring.save(update_fields=["misses", "status", "escalated_at", "due_at"])
            _status_push(ring, "missed")
            out["escalated"] += 1
            continue
        link = CareCallLink.objects.filter(setter_id=ring.care_call.setter_id,
                                           receiver_id=ring.care_call.receiver_id).first()
        nxt = (ring.last_ring_at or now) + timedelta(minutes=RETRY_MIN)
        if link is not None:
            nxt = after_quiet(nxt, link.quiet_start, link.quiet_end)
        ring.status, ring.due_at = "pending", nxt
        ring.save(update_fields=["misses", "status", "due_at"])
    return out


# --------------------------------------------------------------- views data
def cc_dict(cc, viewer):
    other = cc.receiver if viewer.pk == cc.setter_id else cc.setter
    name = name_for(viewer, other)
    link = CareCallLinkCache.get(cc.setter_id, cc.receiver_id)
    return {
        "id": cc.pk, "text": cc.text, "time": cc.time_hhmm, "repeat": cc.repeat,
        "days": list(cc.days or []), "date": cc.once_date.isoformat() if cc.once_date else "",
        "active": cc.active, "next_at": cc.next_at.isoformat() if cc.next_at else None,
        "has_voice": bool(cc.voice), "voice_rev": cc.voice_rev, "voice_sec": cc.voice_sec,
        "setter_id": cc.setter_id, "receiver_id": cc.receiver_id,
        "other_name": name, "other_initial": initial(name),
        "link": link.status if link else "none",
        "quiet_start": link.quiet_start if link else "", "quiet_end": link.quiet_end if link else "",
    }


class CareCallLinkCache:
    """Tiny per-call memo (a list view reads the same link many times)."""
    _memo = {}

    @classmethod
    def get(cls, setter_id, receiver_id):
        from .models import CareCallLink
        k = (setter_id, receiver_id)
        if k not in cls._memo:
            cls._memo[k] = CareCallLink.objects.filter(setter_id=setter_id, receiver_id=receiver_id).first()
        return cls._memo[k]

    @classmethod
    def reset(cls):
        cls._memo = {}


def feed(setter, limit=30):
    """Screen 3: the setter's confirmed / did-not-answer cards, newest first."""
    from .models import CareCallRing
    rows = []
    q = (CareCallRing.objects.filter(care_call__setter=setter, status__in=("done", "missed"))
         .select_related("care_call", "care_call__receiver").order_by("-scheduled_at", "-id")[:limit])
    edges = {}
    for r in q:
        cc = r.care_call
        rec = cc.receiver
        if rec.pk not in edges:
            e = _edge(setter, rec)
            edges[rec.pk] = (e.pk if e else None, can_see_location(setter, rec))
        name = name_for(setter, rec)
        at = r.answered_at if r.status == "done" else (r.escalated_at or r.scheduled_at)
        rows.append({
            "ring_id": r.pk, "care_call_id": cc.pk,
            "kind": ("late" if r.late else "confirmed") if r.status == "done" else "missed",
            "at": at.isoformat() if at else None, "scheduled_at": r.scheduled_at.isoformat(),
            "receiver_id": rec.pk, "receiver_name": name, "receiver_initial": initial(name),
            "text": cc.text, "misses": r.misses, "edge_id": edges[rec.pk][0],
            "can_see_location": edges[rec.pk][1],
        })
    return rows


def mine(user):
    """Everything the Care Call screens need in one read."""
    from .models import CareCall, CareCallLink
    CareCallLinkCache.reset()
    sent = [cc_dict(cc, user) for cc in CareCall.objects.filter(setter=user).select_related("receiver")[:100]]
    accepted = set(CareCallLink.objects.filter(receiver=user, status="accepted").values_list("setter_id", flat=True))
    received = [cc_dict(cc, user) for cc in CareCall.objects.filter(
        receiver=user, active=True, setter_id__in=list(accepted)).select_related("setter")[:100]]
    links = []
    for ln in CareCallLink.objects.filter(receiver=user).select_related("setter").order_by("-id"):
        name = name_for(user, ln.setter)
        links.append({"setter_id": ln.setter_id, "name": name, "initial": initial(name),
                      "status": ln.status})
    q = CareCallLink.objects.filter(receiver=user).order_by("-id").first()
    lim = limits()
    return {
        "sent": sent, "received": received, "links": links,
        "invites": [x for x in links if x["status"] == "pending"],
        "feed": feed(user),
        "quiet_start": q.quiet_start if q else DEFAULT_QUIET[0],
        "quiet_end": q.quiet_end if q else DEFAULT_QUIET[1],
        "limits": {"active_per_setter": lim["carecall_active_per_setter"],
                   "active_used": active_count(user),
                   "voice_max_seconds": lim["carecall_voice_max_seconds"],
                   "text_max_chars": lim["carecall_text_max_chars"],
                   "retry_min": RETRY_MIN, "snooze_min": SNOOZE_MIN},
    }


def voice_for(user, cc_id):
    """The voice file if `user` is the setter or an accepted receiver."""
    from .models import CareCall
    cc = CareCall.objects.filter(pk=cc_id).first()
    if cc is None or not cc.voice:
        return None
    if user.pk == cc.setter_id:
        return cc
    if user.pk == cc.receiver_id:
        ln = link_of(cc.setter, cc.receiver)
        if ln is not None and ln.status == "accepted":
            return cc
    return None
