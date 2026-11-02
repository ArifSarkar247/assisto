"""
kid_audio.py — owner PART 1 b (2 Nov): CHILD EMERGENCY AUDIO.

During an ACTIVE emergency only, a VERIFIED parent may hear a few minutes of
live audio around their under-18 child — so they can send the right help.
Flag `child_emergency_audio` (default OFF).

THE RULES (each one has a test in core/tests_kidaudio.py):
  * ACTIVE EMERGENCY ONLY (active_emergency): the child pressed SOS (or a
    fall alert went out) in the last EMERGENCY_WINDOW_S and has not said
    "I'm safe"; OR a Safe Journey went late, the child got "Are you OK?"
    ("ঠিক আছো?") and did NOT answer, and the family was alerted; OR the
    child's paired kids watch raised SOS. Never in normal times.
  * VERIFIED PARENT ONLY (is_guardian — THE one guardian check; when
    core/guardianship.py guardians_of() lands it replaces this body): both
    My Circle edges agree parent/child (guardian -> child = "child", child ->
    guardian = father/mother/parent), accepted and unblocked.
  * UNDER 18, CONFIRMED (is_minor): the parent declares the birth year, the
    child confirms the same year on their own phone; re-checked on EVERY
    request, conservatively (born in year Y counts as an adult from 1 Jan of
    Y+18) — the feature stops by itself when the child grows up. Adults:
    never.
  * CONSENT IN ADVANCE BY BOTH (consent_ok): parent_ok_at AND child_ok_at,
    not revoked. Either side can revoke at any time (never flag-gated).
  * A FEW MINUTES: MAX_SESSION_S per session — the SERVER ends the call
    (rt poll hook), not only the phone; MAX_SESSIONS_PER_EMERGENCY per
    emergency; one live session per child.
  * FULL AUDIT: every request is a KidAudioSession row — granted AND refused
    (with the reason) — and BOTH the parent and the child see all of it.
  * PHONE = VISIBLE: the child's phone places an ordinary Circle voice call
    to the parent (the existing calls / WebRTC stack, the call screen on
    display) and shows the foreground notification "জরুরি অবস্থায় বাবা/মা
    শুনছেন" + Stop for the whole call. The session cannot go live unless the
    phone reports the notice is showing (notice_shown) — no silent mic path.
  * WATCH = A NORMAL CALL: no command of any kind asks the watch to listen
    (tracker.protocols.watch FORBIDDEN stays). The parent's own phone dials
    the watch's SIM number; the watch rings and shows the call. We queue only
    an on-screen MESSAGE ("parent calling") — an allowed, visible command.
  * Safety is free on every plan (nothing here charges).
"""
import logging
from datetime import datetime, timedelta, timezone as dt_tz

from django.db import transaction
from django.utils import timezone

log = logging.getLogger(__name__)

FLAG = "child_emergency_audio"
MAX_SESSION_S = 180
MAX_SESSIONS_PER_EMERGENCY = 3
EMERGENCY_WINDOW_S = 60 * 60
START_WINDOW_S = 120            # the child's phone must start within this
ADULT_AGE = 18
CHANNELS = ("phone", "watch")
CHILD_EDGE = "child"
PARENT_EDGES = ("father", "mother", "parent")
LIVE_KEY = "kidaudio:live:%s"
LIVE_KEY_TTL = 15 * 60

REASONS = ("flag_off", "not_guardian", "adult", "no_consent", "no_emergency",
           "session_cap", "busy", "no_watch", "no_child_phone")


def flag_on(user=None):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(FLAG, user))
    except Exception:
        return False


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ------------------------------------------------------------- the gates
def _edge(owner, peer):
    from .models import CircleMember
    if owner is None or peer is None:
        return None
    return (CircleMember.objects
            .filter(user=owner, peer_user=peer, state="accepted", blocked=False)
            .first())


def is_guardian(guardian, child):
    """THE guardian check (one function on purpose). Both sides must agree
    parent/child in My Circle."""
    if guardian is None or child is None or guardian.pk == child.pk:
        return False
    a, b = _edge(guardian, child), _edge(child, guardian)
    return bool(a and b and a.relation == CHILD_EDGE and b.relation in PARENT_EDGES)


def is_minor(birth_year, now=None):
    """Conservative: the child counts as an adult from 1 Jan of the year
    they turn 18 (never a day late)."""
    now = now or timezone.now()
    try:
        y = int(birth_year)
    except (TypeError, ValueError):
        return False
    age_max = now.year - y
    return 0 <= age_max < ADULT_AGE


def consent_ok(c):
    return bool(c and c.parent_ok_at and c.child_ok_at and not c.revoked_at)


def _iso(dt):
    return dt.isoformat() if dt else None


def active_emergency(child, now=None, watch=None):
    """-> {"kind", "ref", "since"} for the child's newest ACTIVE emergency,
    or None. Kinds: sos | fall | journey_late | watch_sos."""
    from .models import FamilyAlertDelivery, Journey, KidsWatch
    now = now or timezone.now()
    since = now - timedelta(seconds=EMERGENCY_WINDOW_S)
    found = []
    last = (FamilyAlertDelivery.objects
            .filter(sender=child, kind__in=("sos", "fall"), created_at__gte=since)
            .order_by("-created_at").first())
    if last is not None:
        resolved = FamilyAlertDelivery.objects.filter(
            sender=child, kind="sos_resolved", created_at__gte=last.created_at).exists()
        if not resolved:
            found.append({"kind": last.kind, "ref": "fa:%s" % last.event_key[:60],
                          "since": last.created_at})
    for j in (Journey.objects.filter(traveller=child, status="active",
                                     ask_sent_at__isnull=False,
                                     escalated_at__gte=since)
              .order_by("-escalated_at")[:3]):
        if j.responded_at is None or j.responded_at < j.ask_sent_at:
            found.append({"kind": "journey_late", "ref": "j:%d" % j.pk,
                          "since": j.escalated_at})
            break
    watches = [watch] if watch is not None else list(
        KidsWatch.objects.filter(child_user=child, state="paired")[:3])
    for w in watches:
        key = str((w.alert_state or {}).get("sos_direct") or "")
        try:
            at = datetime.fromtimestamp(int(key.split(":", 1)[1]) * 60, tz=dt_tz.utc)
        except (IndexError, ValueError, OverflowError):
            continue
        if at >= since:
            found.append({"kind": "watch_sos", "ref": "kw:%s" % key[:60], "since": at})
    if not found:
        return None
    return max(found, key=lambda e: e["since"])


def check(guardian, child, consent, channel="phone", now=None):
    """-> (ok, reason, emergency). The order is the order of the rules."""
    from .models import KidAudioSession
    now = now or timezone.now()
    if not flag_on(guardian):
        return False, "flag_off", None
    if not is_guardian(guardian, child):
        return False, "not_guardian", None
    if consent is None or consent.guardian_id != guardian.pk or consent.child_id != child.pk:
        return False, "no_consent", None
    if not is_minor(consent.birth_year, now):
        return False, "adult", None
    if not consent_ok(consent):
        return False, "no_consent", None
    if channel == "watch" and not (consent.watch_id and consent.watch_phone
                                   and consent.watch.child_user_id == child.pk):
        return False, "no_watch", None
    em = active_emergency(child, now,
                          watch=consent.watch if channel == "watch" else None)
    if em is None and channel == "watch":
        em = active_emergency(child, now)
    if em is None:
        return False, "no_emergency", None
    used = KidAudioSession.objects.filter(
        child=child, emergency_ref=em["ref"]).exclude(status="refused").count()
    if used >= MAX_SESSIONS_PER_EMERGENCY:
        return False, "session_cap", em
    if KidAudioSession.objects.filter(child=child, status__in=("requested", "live"),
                                      created_at__gte=now - timedelta(seconds=MAX_SESSION_S + START_WINDOW_S)
                                      ).exists():
        return False, "busy", em
    return True, "", em


# ------------------------------------------------------------- notices
def _notify(user, tbn, ten, bbn, ben, data=None, high=False):
    """A visible notice (push + in-app row). Never raises."""
    from . import push
    from .models import NotifEvent
    d = {"route": "kid_audio", **(data or {})}
    try:
        NotifEvent.objects.create(user=user, type="security", title_bn=tbn[:200],
                                  title_en=ten[:200], body_bn=bbn, body_en=ben,
                                  route="kid_audio", meta=dict(d))
    except Exception as e:
        log.warning("kidaudio: in-app row failed %s", type(e).__name__)
    try:
        push.safe_push(user, "family_alert", tbn, ten, bbn, ben, data=d,
                       high_priority=high)
    except Exception:
        pass


def _name(viewer, user):
    from . import push
    return push.seen_name(viewer, user)


def _mark_live(*users):
    try:
        from django.core.cache import cache
        for u in users:
            cache.set(LIVE_KEY % u.pk, 1, LIVE_KEY_TTL)
    except Exception:
        pass


# ------------------------------------------------------------- consent
def set_consent(guardian, child, birth_year, watch=None, watch_phone="", now=None):
    """The parent's side. -> (consent|None, reason). Terms that change clear
    the child's agreement (the child must agree to what is really set)."""
    from .models import KidAudioConsent
    now = now or timezone.now()
    if not is_guardian(guardian, child):
        return None, "not_guardian"
    if not is_minor(birth_year, now):
        return None, "adult"
    if watch is not None and watch.child_user_id != child.pk:
        return None, "no_watch"
    phone = "".join(ch for ch in str(watch_phone or "") if ch.isdigit() or ch == "+")[:20]
    c, created = KidAudioConsent.objects.get_or_create(
        guardian=guardian, child=child, defaults={"birth_year": int(birth_year)})
    changed = created or c.birth_year != int(birth_year) or \
        c.watch_id != (watch.pk if watch else None) or c.watch_phone != phone or \
        c.revoked_at is not None
    c.birth_year = int(birth_year)
    c.watch = watch
    c.watch_phone = phone if watch is not None else ""
    c.parent_ok_at = now
    if changed:
        c.child_ok_at = None
    c.revoked_at, c.revoked_by = None, ""
    c.save()
    if changed:
        n = _name(child, guardian)
        _notify(child, "%s জরুরি অডিওর অনুমতি চাইছেন" % n,
                "%s asks for emergency audio permission" % n,
                "শুধু আপনি বিপদে থাকলে, কয়েক মিনিট, আপনি সবসময় দেখবেন। পড়ে সিদ্ধান্ত নিন।",
                "Only if you are in danger, a few minutes, always visible to you. Read and decide.",
                data={"event": "consent_asked", "consent_id": c.pk})
    return c, ""


def child_agree(child, consent, birth_year, now=None):
    now = now or timezone.now()
    if consent is None or consent.child_id != child.pk or consent.revoked_at \
            or not consent.parent_ok_at:
        return False, "no_consent"
    try:
        same = int(birth_year) == consent.birth_year
    except (TypeError, ValueError):
        same = False
    if not same:
        return False, "year_mismatch"
    if not is_minor(consent.birth_year, now):
        return False, "adult"
    consent.child_ok_at = now
    consent.save(update_fields=["child_ok_at", "updated_at"])
    n = _name(consent.guardian, child)
    _notify(consent.guardian, "%s জরুরি অডিওতে রাজি হয়েছে" % n,
            "%s agreed to emergency audio" % n,
            "শুধু সক্রিয় জরুরি অবস্থায় কাজ করবে।", "It works only during an active emergency.",
            data={"event": "consent_agreed", "consent_id": consent.pk})
    return True, ""


def revoke(user, consent, now=None):
    """Either side, any time, never flag-gated. Ends a live session too."""
    now = now or timezone.now()
    if consent is None or user.pk not in (consent.guardian_id, consent.child_id):
        return False
    side = "child" if user.pk == consent.child_id else "guardian"
    consent.revoked_at, consent.revoked_by = now, side
    consent.child_ok_at = None
    consent.save(update_fields=["revoked_at", "revoked_by", "child_ok_at", "updated_at"])
    for s in consent.sessions.filter(status__in=("requested", "live")):
        end_session(s, "revoked", by=side, now=now)
    other = consent.guardian if side == "child" else consent.child
    n = _name(other, user)
    _notify(other, "%s জরুরি অডিওর অনুমতি বন্ধ করেছেন" % n,
            "%s turned emergency audio off" % n, "আবার চালু করতে দুজনের সম্মতি লাগবে।",
            "Both of you must agree again to turn it back on.",
            data={"event": "consent_revoked", "consent_id": consent.pk})
    return True


# ------------------------------------------------------------- sessions
def request_listen(guardian, consent, channel="phone", now=None):
    """The parent asks. ALWAYS writes one audit row (granted or refused).
    -> (session, reason)."""
    from .models import KidAudioSession
    now = now or timezone.now()
    channel = channel if channel in CHANNELS else "phone"
    child = consent.child if consent is not None else None
    if child is None:
        return None, "no_consent"
    with transaction.atomic():
        ok, reason, em = check(guardian, child, consent, channel, now)
        s = KidAudioSession.objects.create(
            consent=consent, guardian=guardian, child=child, channel=channel,
            status="requested" if ok else "refused", reason=reason,
            emergency_kind=(em or {}).get("kind", ""),
            emergency_ref=(em or {}).get("ref", ""), limit_s=MAX_SESSION_S)
    log.info("kidaudio request guardian=%s child=%s channel=%s ok=%s reason=%s",
             guardian.pk, child.pk, channel, ok, reason)
    if not ok:
        if reason not in ("flag_off", "not_guardian"):
            # the child sees refused attempts too (abuse is visible)
            n = _name(child, guardian)
            _notify(child, "%s শোনার চেষ্টা করেছিলেন — অনুমতি দেওয়া হয়নি" % n,
                    "%s tried to listen — it was refused" % n,
                    "কারণ দেখতে খাতা খুলুন।", "Open the log to see why.",
                    data={"event": "refused", "session_id": s.pk})
        return s, reason
    gname = _name(child, guardian)
    if channel == "watch":
        # the GSM call happens outside Assisto: we log the dial, not a length
        s.status, s.started_at = "dialled", now
        s.save(update_fields=["status", "started_at"])
        _watch_message(consent.watch, guardian)
    else:
        _mark_live(guardian, child)
        _notify(child, "জরুরি: %s শুনতে চাইছেন" % gname,
                "Emergency: %s wants to listen" % gname,
                "আপনার ফোন %s-কে কল দেবে, নোটিফিকেশনে বন্ধ করুন বোতাম থাকবে। সর্বোচ্চ ৩ মিনিট।" % gname,
                "Your phone will call %s; Stop is on the notification. 3 minutes at most." % gname,
                data={"event": "listen", "session_id": s.pk}, high=True)
    return s, ""


def _watch_message(watch, guardian):
    """The ONLY thing we send the watch: an on-screen text (allowed MESSAGE
    command). Never a listen / call command."""
    if watch is None:
        return
    try:
        from . import kidswatch_service as KW
        KW.queue(watch, "message", {"text": "SOS: parent is calling you now"},
                 actor=guardian)
    except Exception as e:
        log.warning("kidaudio: watch message failed %s", type(e).__name__)


def pending_for_child(child, now=None):
    """The child's phone asks on open / resume / push: a requested session to
    start now (still inside the start window, emergency still active)."""
    from .models import KidAudioSession
    now = now or timezone.now()
    for s in KidAudioSession.objects.filter(child=child, status="requested", channel="phone"):
        if now - s.created_at > timedelta(seconds=START_WINDOW_S):
            end_session(s, "not_started", by="server", now=now, status="missed")
            continue
        return s
    return None


def child_member_id(session):
    """The CHILD's My Circle row for the guardian (the call is placed on it)."""
    e = _edge(session.child, session.guardian)
    return e.pk if e else None


def child_started(child, session, notice_shown, now=None):
    """The child's phone reports the call started. Refused unless the
    foreground notice is on screen (no silent mic path)."""
    now = now or timezone.now()
    if session.child_id != child.pk or session.status != "requested":
        return False, "not_pending"
    if notice_shown is not True:
        end_session(session, "notice_failed", by="child", now=now, status="ended")
        return False, "notice_required"
    ok, reason, _em = _still_allowed(session, now)
    if not ok:
        end_session(session, reason, by="server", now=now)
        return False, reason
    session.status, session.started_at, session.notice_shown = "live", now, True
    session.save(update_fields=["status", "started_at", "notice_shown"])
    _link_call(session)
    _mark_live(session.guardian, session.child)
    return True, ""


def _still_allowed(session, now):
    """Consent / guardian / age / emergency still hold (re-checked while live)."""
    c = session.consent
    if c is None or not consent_ok(c):
        return False, "no_consent", None
    if not is_guardian(session.guardian, session.child):
        return False, "not_guardian", None
    if not is_minor(c.birth_year, now):
        return False, "adult", None
    em = active_emergency(session.child, now)
    if em is None:
        return False, "emergency_over", None
    return True, "", em


def _link_call(session):
    from .models import CallRecord
    if session.call_id:
        return session.call
    rec = (CallRecord.objects.filter(caller=session.child, callee=session.guardian,
                                     started_at__gte=session.created_at)
           .order_by("-started_at").first())
    if rec is not None:
        session.call = rec
        session.save(update_fields=["call"])
    return rec


def end_session(session, reason, by="server", now=None, status="ended"):
    """Idempotent. Ends the linked live call on the SERVER too."""
    now = now or timezone.now()
    if session.status not in ("requested", "live"):
        return session
    session.status = status
    session.reason = (reason or "")[:24]
    session.ended_at = now
    session.ended_by = by
    session.save(update_fields=["status", "reason", "ended_at", "ended_by"])
    rec = session.call if session.call_id else None
    if rec is not None:
        try:
            from . import views_c2_calls as C2
            C2.end_call(rec, "hangup", by="server", now=now)   # publishes call.state
        except Exception as e:
            log.warning("kidaudio: end call failed %s", type(e).__name__)
    if status == "ended" and session.started_at:
        secs = int((now - session.started_at).total_seconds())
        n = _name(session.child, session.guardian)
        _notify(session.child, "জরুরি অডিও বন্ধ হয়েছে",
                "Emergency audio ended",
                "%s শুনেছেন %s সেকেন্ড। খাতায় সব আছে।" % (n, bn_num(secs)),
                "%s listened for %d seconds. It is all in the log." % (n, secs),
                data={"event": "ended", "session_id": session.pk})
    return session


def bn_num(v):
    return str(v).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


def enforce(user, now=None):
    """Runs on the user's rt/events poll (both phones poll during a call):
    link the call, end it at the time limit, when the emergency is over, or
    when consent / age / guardian no longer hold. Cheap when nothing is live
    (one cache read)."""
    from .models import KidAudioSession
    try:
        from django.core.cache import cache
        if not cache.get(LIVE_KEY % user.pk):
            return 0
    except Exception:
        return 0
    now = now or timezone.now()
    n = 0
    for s in (KidAudioSession.objects.filter(status__in=("requested", "live"), channel="phone")
              .filter(child=user) | KidAudioSession.objects.filter(
                  status__in=("requested", "live"), channel="phone", guardian=user)):
        if s.status == "requested":
            if now - s.created_at > timedelta(seconds=START_WINDOW_S):
                end_session(s, "not_started", now=now, status="missed")
                n += 1
            continue
        _link_call(s)
        if now - s.started_at >= timedelta(seconds=s.limit_s):
            end_session(s, "time_limit", now=now)
            n += 1
            continue
        ok, reason, _em = _still_allowed(s, now)
        if not ok:
            end_session(s, reason, now=now)
            n += 1
            continue
        rec = s.call
        if rec is not None:
            from .logic import call_signal as CS
            if not CS.is_live(rec.state):
                end_session(s, "call_ended", by="", now=now)
                n += 1
    return n


def _poll_hook(request, now):
    enforce(request.user, now)


def register():
    try:
        from . import views_c2_calls as C2
        C2.register_poll_hook(_poll_hook)
    except Exception:  # pragma: no cover
        pass


# ------------------------------------------------------------- API shapes
def session_row(s, viewer, lang="bn"):
    secs = None
    if s.started_at:
        secs = int(((s.ended_at or timezone.now()) - s.started_at).total_seconds())
        secs = max(0, min(secs, s.limit_s)) if s.channel == "phone" else None
    return {"id": s.id, "channel": s.channel, "status": s.status, "reason": s.reason,
            "role": "guardian" if viewer.pk == s.guardian_id else "child",
            "guardian_name": _name(viewer, s.guardian), "child_name": _name(viewer, s.child),
            "emergency_kind": s.emergency_kind, "requested_at": _iso(s.created_at),
            "started_at": _iso(s.started_at), "ended_at": _iso(s.ended_at),
            "ended_by": s.ended_by, "seconds": secs, "limit_s": s.limit_s,
            "notice_shown": s.notice_shown}


def consent_row(c, viewer, now=None):
    now = now or timezone.now()
    other = c.child if viewer.pk == c.guardian_id else c.guardian
    return {"id": c.id, "role": "guardian" if viewer.pk == c.guardian_id else "child",
            "other_id": other.pk, "other_name": _name(viewer, other),
            "birth_year": c.birth_year, "minor": is_minor(c.birth_year, now),
            "parent_ok_at": _iso(c.parent_ok_at), "child_ok_at": _iso(c.child_ok_at),
            "revoked_at": _iso(c.revoked_at), "revoked_by": c.revoked_by,
            "active": consent_ok(c) and is_minor(c.birth_year, now),
            "watch_id": c.watch_id, "has_watch_phone": bool(c.watch_phone)}
