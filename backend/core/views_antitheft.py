"""
b6-antitheft — HTTP surface of the native always-on Lost/Stolen engine.

  GET  security/engine/state                 owner: settings + honest status
  POST security/engine/enable   {pin, ...}   owner: turn ON (returns engine token ONCE)
  POST security/engine/disable  {pin}        owner: turn OFF (Security PIN, Section 8)
  POST security/engine/settings {pin, ...}   owner: change options / who is alerted
  POST security/engine/ingest                ENGINE TOKEN: heartbeats + events (batch,
                                             store-and-forward, original timestamps)
  POST security/engine/photo                 ENGINE TOKEN: one intruder photo (multipart)
  GET  security/engine/timeline[?phone_id]   owner or approved family; others 404
  GET  security/engine/watching              phones whose alerts I (family) receive
  GET  security/engine/event/<id>/photo-link owner or approved family; others 404
  GET  security/engine/event/<id>/photo      short-lived signed link (decrypts)

PRIVACY: the only people who ever see an event, a location or a photo are the
owner and the family members the OWNER approved (the Section-8 family approver
plus members the owner ticked for alerts). Everyone else gets 404 — we never
reveal that a phone or event exists.

The engine token is SCOPED: it can only write evidence for one phone. It can't
read anything back and can't act as the user, so a copy of it is worth little.
"""
import json
import uuid
from datetime import timedelta

from django.core.files.base import ContentFile
from django.db import IntegrityError, transaction
from django.db.models import Q
from django.http import Http404, HttpResponse
from django.utils import timezone

from rest_framework import status
from rest_framework.parsers import FormParser, JSONParser, MultiPartParser
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import antitheft as at
from .logic import security as sec
from .models import (AntiTheftEngine, AntiTheftEvent, CircleMember, FamilyAlert,
                     NotifEvent, PhoneHeartbeat, ProtectedPhone, User)
from .views_security import _primary_phone, _register_lockout, _verify_pin


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _engine(phone, create=True):
    eng = AntiTheftEngine.objects.filter(phone=phone).first()
    if eng is None and create:
        eng = AntiTheftEngine.objects.create(phone=phone)
    return eng


def engine_enabled(phone):
    try:
        return bool(phone.engine.enabled)
    except AntiTheftEngine.DoesNotExist:
        return False
    except Exception:
        return False


def _owner_name(user):
    try:
        from . import push
        return push.display_name(user)
    except Exception:
        return getattr(user, "name", "") or ""


def approved_members(phone):
    """The owner's ACCEPTED, unblocked CircleMember rows approved for alerts:
    the Section-8 family approver + the members ticked in alert_member_ids."""
    ids = set()
    if phone.family_approver_id:
        ids.add(phone.family_approver_id)
    eng = AntiTheftEngine.objects.filter(phone=phone).first()
    if eng is not None:
        for x in (eng.alert_member_ids or []):
            try:
                ids.add(int(x))
            except (TypeError, ValueError):
                continue
    if not ids:
        return []
    return list(CircleMember.objects.filter(
        id__in=ids, user=phone.owner, state="accepted", blocked=False))


def approved_family_users(phone):
    """Users (with an Assisto account) who may receive/see this phone's alerts."""
    from . import push
    out, seen = [], {phone.owner_id}
    for m in approved_members(phone):
        peer = push.member_peer_user(m)
        if peer is not None and peer.pk not in seen:
            seen.add(peer.pk)
            out.append(peer)
    return out


def can_view(phone, user):
    if user is None or not getattr(user, "is_authenticated", False):
        return False
    if phone.owner_id == user.id:
        return True
    return any(u.pk == user.pk for u in approved_family_users(phone))


def notify(phone, kind, te, be, tb, bb, meta=None, owner_only=False,
           family_only=False):
    """ONE in-app record (a bilingual NotifEvent, type "security") + ONE FCM
    push per recipient: the owner and approved family ONLY. Never raises (an
    alert failure must not lose the stored event).

    at-heartbeat (owner 24 Oct): this used to ALSO create a FamilyAlert, so the
    same event showed twice (Family + Security in the notification centre).
    The NotifEvent is now the single record; the foreground /alerts poll reads
    it too (alert_rows_for), so phones without working push still see it.

    at-falsealarm: recipients are de-duplicated by user id, so one person
    (e.g. the owner who is also linked as a family member's peer) gets ONE
    push per alert. family_only=True skips the owner (the all-clear after the
    owner's own "It was me", went-dark and back-online)."""
    from . import push
    meta = dict(meta or {})
    meta.update({"phone_id": phone.id, "owner_id": phone.owner_id,
                 "antitheft_kind": kind})
    owner = phone.owner
    # Owner 25 Oct: the device owner NEVER gets an anti-theft/safety alert about
    # his OWN phone (battery, offline, grab, SIM, went dark … every kind) — only
    # approved family do. The one exception is an owner-only kind (the "test"
    # alarm he pressed himself). family_only is kept for callers' clarity.
    if owner_only:
        recips = [owner]
    else:
        recips = list(approved_family_users(phone))
    now = timezone.now()
    sent = 0
    seen = set()
    for u in recips:
        if u is None or u.pk in seen:
            continue
        if family_only and u.pk == phone.owner_id:
            continue
        seen.add(u.pk)
        try:
            NotifEvent.objects.create(
                user=u, type="security", title_bn=tb[:200], title_en=te[:200],
                body_bn=bb, body_en=be, route="security/lost-phone",
                meta=meta, at=now)
            push.safe_push(u, "family_alert", tb, te, bb, be,
                           data={"alert_kind": "antitheft", "route": "security/lost-phone",
                                 "phone_id": phone.id, "antitheft_kind": kind,
                                 # grab-guard: the app drops pushes about
                                 # its own phone (2nd line of defence)
                                 "owner_id": phone.owner_id},
                           high_priority=True)
            sent += 1
        except Exception:
            continue
    return sent


# How long an unseen anti-theft alert stays in the foreground /alerts poll.
ALERT_POLL_HOURS = 48


def alert_rows_for(user, lang="bn", now=None, limit=10):
    """at-heartbeat: unseen, unresolved anti-theft alerts for the foreground
    /alerts poll (same shape as a FamilyAlert row there). Never raises."""
    now = now or timezone.now()
    out = []
    try:
        qs = (NotifEvent.objects.filter(
            user=user, type="security", seen=False,
            at__gte=now - timedelta(hours=ALERT_POLL_HOURS),
            meta__has_key="antitheft_kind").order_by("-at")[:limit])
        for n in qs:
            m = n.meta or {}
            if m.get("resolved_at"):
                continue
            # owner 24 Oct: never put alerts about the user's OWN device in his
            # own urgent card / briefing (he is holding it); family still gets them
            if m.get("owner_id") == user.id:
                continue
            en = lang == "en"
            title = (n.title_en if en else n.title_bn) or n.title_en or n.title_bn
            body = (n.body_en if en else n.body_bn) or n.body_en or n.body_bn
            out.append({"type": "antitheft", "text": body or title,
                        "title": title, "severity": "high",
                        "kind": m.get("antitheft_kind") or "",
                        # own-device: lets the app's urgent card drop rows
                        # about the user's own phone (2nd line of defence)
                        "owner_id": m.get("owner_id"),
                        "phone_id": m.get("phone_id")})
    except Exception:
        return out
    return out


def resolve_went_dark(phone, now=None):
    """at-heartbeat: the phone is checking in again -> every went-dark record
    about it (this one and any older ones) is resolved: NotifEvents marked
    seen + resolved_at, legacy FamilyAlerts dismissed, the timeline event
    flagged. Returns how many in-app records changed. Never raises."""
    now = now or timezone.now()
    stamp = now.isoformat()
    changed = 0
    try:
        for n in NotifEvent.objects.filter(
                type="security", meta__phone_id=phone.id,
                meta__antitheft_kind="went_dark"):
            m = dict(n.meta or {})
            if m.get("resolved_at") and n.seen:
                continue
            m.setdefault("resolved_at", stamp)
            n.meta, n.seen = m, True
            n.save(update_fields=["meta", "seen"])
            changed += 1
        changed += FamilyAlert.objects.filter(
            kind="antitheft", payload__phone_id=phone.id,
            payload__antitheft_kind="went_dark", dismissed=False,
        ).update(dismissed=True)
        # legacy (pre-engine) went-dark rows carry went_dark_at, no phone_id
        changed += FamilyAlert.objects.filter(
            user=phone.owner, kind="security", payload__has_key="went_dark_at",
            dismissed=False).update(dismissed=True)
        for ev in AntiTheftEvent.objects.filter(phone=phone, kind="went_dark"):
            d = dict(ev.data or {})
            if d.get("resolved_at"):
                continue
            d["resolved_at"] = stamp
            AntiTheftEvent.objects.filter(pk=ev.pk).update(data=d)
    except Exception:
        pass
    return changed


def _config(phone, eng, interval=None):
    return {
        "enabled": bool(eng.enabled),
        "interval_min": interval or phone.heartbeat_interval_min or at.INTERVAL_NORMAL,
        "lost_mode": phone.lost_mode,
        "lost_message": phone.lost_message,
        "lost_contact": phone.lost_contact,
        "snatch_lock": eng.snatch_lock,
        "intruder_photo": eng.intruder_photo,
        "failed_unlock_threshold": eng.failed_unlock_threshold,
    }


# at-falsealarm: an older engine (before the SIM baseline) reported the
# CURRENT SIM as "sim_change inserted" seconds after protection was switched on
# (a sticky Android broadcast). Such legacy events (no data.v) arriving within
# this window after enabling are stored for the timeline but never freeze the
# phone or alert anyone. The new engine sends data.v=2 and is trusted.
LEGACY_SIM_GRACE_S = 120


def _legacy_arming_sim(eng, kind, ev_at, data):
    if kind != "sim_change" or not eng.enabled_at:
        return False
    try:
        if int((data or {}).get("v") or 0) >= 2:
            return False
    except (TypeError, ValueError):
        pass
    delta = (ev_at - eng.enabled_at).total_seconds()
    return -30 <= delta <= LEGACY_SIM_GRACE_S


def _member_brief(m):
    return {"id": m.id, "name": m.name or ""}


def _clean_member_ids(user, raw):
    if raw is None:
        return None
    if not isinstance(raw, list):
        return []
    want = []
    for x in raw[:20]:
        try:
            want.append(int(x))
        except (TypeError, ValueError):
            continue
    ok = CircleMember.objects.filter(user=user, state="accepted", blocked=False,
                                     id__in=want).values_list("id", flat=True)
    return sorted(set(ok))


def _bool(v, default=None):
    if v is None:
        return default
    if isinstance(v, bool):
        return v
    return str(v).lower() in ("1", "true", "yes", "on")


def _pin_gate(request, phone):
    """Security PIN (+ Section-8 SMS proof when a gateway is connected).
    Returns None when OK, else the Response to send."""
    if not phone.security_pin_hash:
        return Response({"ok": False, "reason": "no_pin"},
                        status=status.HTTP_400_BAD_REQUEST)
    ok, locked = _verify_pin(phone, request.data.get("pin"))
    if not ok:
        if locked:
            _register_lockout(request.user, phone)
            return Response({"ok": False, "locked": True},
                            status=status.HTTP_403_FORBIDDEN)
        return Response({"ok": False, "reason": "bad_pin"},
                        status=status.HTTP_403_FORBIDDEN)
    return None


def _otp_gate(request):
    from . import otp as otp_mod
    try:
        required = otp_mod.otp_required_for(request.user)
    except Exception:
        required = False
    if not required:
        return None
    proof = str(request.data.get("otp_proof") or "").strip()
    if not proof:
        return Response({"ok": False, "reason": "otp_required", "purpose": "section8"},
                        status=status.HTTP_403_FORBIDDEN)
    if otp_mod.consume_proof(proof, "section8", request.user.phone) is None:
        return Response({"ok": False, "reason": "bad_otp", "purpose": "section8"},
                        status=status.HTTP_403_FORBIDDEN)
    return None


def _event_json(ev, viewer_is_owner=True):
    return {
        "id": ev.id, "kind": ev.kind,
        "at": ev.at.isoformat(),
        "received_at": ev.received_at.isoformat() if ev.received_at else None,
        "late": ev.late,
        "data": ev.data or {},
        "lat": ev.lat, "lng": ev.lng, "accuracy_m": ev.accuracy_m,
        "battery": ev.battery,
        "has_photo": bool(ev.photo),
    }


def _went_dark_since(phone):
    from .views_lost import _went_dark_since as wd
    return wd(phone)


def prune_phone(phone, now=None):
    """Hard-delete this phone's events (and their encrypted photos) past the
    retention cap. Cheap; runs on ingest so no extra cron is needed."""
    now = now or timezone.now()
    cutoff = now - timedelta(days=at.EVENT_RETENTION_DAYS)
    old = AntiTheftEvent.objects.filter(phone=phone, at__lt=cutoff)
    for ev in old.exclude(photo=""):
        try:
            ev.photo.delete(save=False)
        except Exception:
            pass
    old.delete()


# --------------------------------------------------------------------------
# owner endpoints
# --------------------------------------------------------------------------

class EngineStateView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        phone = _primary_phone(request.user)
        eng = _engine(phone)
        now = timezone.now()
        dark = _went_dark_since(phone)
        approver = phone.family_approver if phone.family_approver_id else None
        members = CircleMember.objects.filter(user=request.user, state="accepted",
                                              blocked=False)
        recent = [_event_json(e) for e in phone.engine_events.all()[:5]]
        return Response({
            # grab-guard: the app remembers its own protected phone id
            "phone_id": phone.id,
            "enabled": eng.enabled,
            "enabled_at": eng.enabled_at.isoformat() if eng.enabled_at else None,
            "has_pin": bool(phone.security_pin_hash),
            "snatch_lock": eng.snatch_lock,
            "intruder_photo": eng.intruder_photo,
            "failed_unlock_threshold": eng.failed_unlock_threshold,
            "approver": _member_brief(approver) if approver else None,
            "alert_member_ids": list(eng.alert_member_ids or []),
            "alert_members": [_member_brief(m) for m in approved_members(phone)],
            "candidates": [_member_brief(m) for m in members],
            "capabilities": eng.capabilities or {},
            "last_ingest_at": eng.last_ingest_at.isoformat() if eng.last_ingest_at else None,
            "last_heartbeat_at": (phone.last_heartbeat_at.isoformat()
                                  if phone.last_heartbeat_at else None),
            "went_dark_at": dark.isoformat() if dark else None,
            "interval_min": phone.heartbeat_interval_min,
            "frozen": sec.is_frozen(phone, now),
            "frozen_until": (phone.frozen_until.isoformat()
                             if sec.is_frozen(phone, now) else None),
            "theft_signal": bool(_recent_signals(phone, now)),
            "lost_mode": phone.lost_mode,
            "recent": recent,
        })


class EngineEnableView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        gate = _pin_gate(request, phone)
        if gate is not None:
            return gate
        eng = _engine(phone)
        was_enabled = eng.enabled
        th = at.i_or_none(request.data.get("failed_unlock_threshold"))
        if th is not None:
            eng.failed_unlock_threshold = max(at.THRESHOLD_MIN, min(at.THRESHOLD_MAX, th))
        eng.snatch_lock = _bool(request.data.get("snatch_lock"), eng.snatch_lock)
        eng.intruder_photo = _bool(request.data.get("intruder_photo"), eng.intruder_photo)
        ids = _clean_member_ids(request.user, request.data.get("alert_member_ids"))
        if ids is not None:
            eng.alert_member_ids = ids
        caps = request.data.get("capabilities")
        if isinstance(caps, dict):
            eng.capabilities = at.clean_data(caps)
        try:  # own-device: the phone that turns protection on runs the engine
            from .own_device import remember as _own_remember
            _own_remember(eng, request)
        except Exception:
            pass
        raw, h = at.new_engine_token()   # rotates: any older token stops working
        eng.token_hash = h
        eng.enabled = True
        eng.enabled_at = timezone.now()
        eng.disabled_at = None
        eng.save()
        if not was_enabled:
            name = _owner_name(request.user)
            notify(phone, "protection_on",
                   "Lost/Stolen Protection is on",
                   ("%s turned on Lost/Stolen Protection. If the phone is "
                    "snatched, its SIM changes or it goes offline, alerts go to "
                    "the owner and the family members they chose." % name),
                   "হারানো/চুরি সুরক্ষা চালু হয়েছে",
                   ("%s হারানো/চুরি সুরক্ষা চালু করেছেন। ফোন ছিনতাই হলে, সিম "
                    "বদলালে বা ফোন অফলাইন হলে সতর্কবার্তা যাবে মালিক ও তাঁর বেছে "
                    "নেওয়া পরিবারের সদস্যদের কাছে।" % name))
        return Response({"ok": True, "engine_token": raw,
                         "ingest_path": "/security/engine/ingest",
                         "photo_path": "/security/engine/photo",
                         "config": _config(phone, eng)})


class EngineDisableView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        eng = _engine(phone)
        if not eng.enabled:
            return Response({"ok": True, "enabled": False})
        gate = _pin_gate(request, phone)
        if gate is not None:
            return gate
        gate = _otp_gate(request)
        if gate is not None:
            return gate
        now = timezone.now()
        if sec.is_frozen(phone, now):
            # A recent snatch / SIM-change froze sensitive actions: a thief who
            # learned the PIN still can't switch protection off for 48h.
            return Response({"ok": False, "state": "blocked", "reason": "frozen",
                             "frozen_until": phone.frozen_until.isoformat()},
                            status=status.HTTP_423_LOCKED)
        eng.enabled = False
        eng.token_hash = ""
        eng.disabled_at = now
        eng.save()
        name = _owner_name(request.user)
        notify(phone, "protection_off",
               "Lost/Stolen Protection was turned off",
               ("Protection on %s's phone was turned off with the Security PIN "
                "at %s. If that was not them, please check." %
                (name, timezone.localtime(now).strftime("%d %b %Y, %I:%M %p"))),
               "হারানো/চুরি সুরক্ষা বন্ধ করা হয়েছে",
               ("%s সময়ে সিকিউরিটি পিন দিয়ে %s-এর ফোনের সুরক্ষা বন্ধ করা হয়েছে। "
                "এটা তিনি না করে থাকলে একবার খোঁজ নিন।" %
                (timezone.localtime(now).strftime("%d %b %Y, %I:%M %p"), name)))
        return Response({"ok": True, "enabled": False})


class EngineSettingsView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        gate = _pin_gate(request, phone)
        if gate is not None:
            return gate
        eng = _engine(phone)
        th = at.i_or_none(request.data.get("failed_unlock_threshold"))
        if th is not None:
            eng.failed_unlock_threshold = max(at.THRESHOLD_MIN, min(at.THRESHOLD_MAX, th))
        eng.snatch_lock = _bool(request.data.get("snatch_lock"), eng.snatch_lock)
        eng.intruder_photo = _bool(request.data.get("intruder_photo"), eng.intruder_photo)
        ids = _clean_member_ids(request.user, request.data.get("alert_member_ids"))
        if ids is not None:
            eng.alert_member_ids = ids
        eng.save()
        return Response({"ok": True, "config": _config(phone, eng),
                         "alert_members": [_member_brief(m) for m in approved_members(phone)]})


# --------------------------------------------------------------------------
# at-falsealarm: owner's "It was me / false alarm"
# --------------------------------------------------------------------------

FALSE_ALARM_WINDOW_H = sec.FREEZE_HOURS
FALSE_ALARM_MAX_PER_DAY = 5


def _sig_dt(s):
    from django.utils.dateparse import parse_datetime
    at_ = s.get("at") if isinstance(s, dict) else None
    try:
        return parse_datetime(at_) if isinstance(at_, str) else at_
    except Exception:
        return None


def _recent_signals(phone, now):
    cutoff = now - timedelta(hours=FALSE_ALARM_WINDOW_H)
    out = []
    for s in (phone.signals or []):
        dt = _sig_dt(s)
        if dt is not None and dt >= cutoff:
            out.append(s)
    return out


class FalseAlarmView(APIView):
    """POST security/engine/false-alarm {pin, phone_id?} — owner only.

    The owner says the theft signal was them (e.g. they switched protection on
    and their own SIM was reported). Needs the Security PIN, verified HERE
    (a wrong PIN counts toward the wrong-PIN lock). Then: the 48h freeze is
    lifted, theft signals of the last 48h are removed from the phone (kept in
    the AuditLog with the before-state), the matching AntiTheftEvents are
    marked data.false_alarm=true, the engine is told to re-record its SIM
    baseline on its next check-in, and approved family get ONE short
    all-clear (the owner gets no second push). Rate-limited per day."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from .models import AuditLog
        pid = at.i_or_none(request.data.get("phone_id"))
        qs = ProtectedPhone.objects.filter(owner=request.user)
        phone = (qs.filter(pk=pid).first() if pid is not None
                 else _primary_phone(request.user, create=False))
        if phone is None:
            raise Http404
        now = timezone.now()
        done_today = AuditLog.objects.filter(
            user=request.user, action="antitheft.false_alarm_cleared",
            created_at__gte=now - timedelta(hours=24)).count()
        if done_today >= FALSE_ALARM_MAX_PER_DAY:
            return Response({"ok": False, "reason": "rate_limited"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        # Always the PIN — also (and especially) in lost mode / reported
        # stolen: only the real owner can say "it was me".
        gate = _pin_gate(request, phone)
        if gate is not None:
            return gate
        phone.refresh_from_db()
        recent = _recent_signals(phone, now)
        was_frozen = sec.is_frozen(phone, now)
        if not recent and not was_frozen:
            return Response({"ok": True, "cleared": 0, "frozen": False})
        before = {"frozen_until": (phone.frozen_until.isoformat()
                                   if phone.frozen_until else None),
                  "signals": list(phone.signals or []),
                  "lost_mode": phone.lost_mode, "status": phone.status}
        cutoff = now - timedelta(hours=FALSE_ALARM_WINDOW_H)
        keep = []
        for s in (phone.signals or []):
            dt = _sig_dt(s)
            if dt is not None and dt >= cutoff:
                continue
            keep.append(s)
        phone.signals = keep
        phone.frozen_until = None
        phone.save()
        evs = list(AntiTheftEvent.objects.filter(
            phone=phone, kind__in=list(at.SIGNAL_KINDS),
            received_at__gte=cutoff))
        for ev in evs:
            d = dict(ev.data or {})
            d["false_alarm"] = True
            AntiTheftEvent.objects.filter(pk=ev.pk).update(data=d)
        eng = _engine(phone, create=False)
        if eng is not None:
            ls = dict(eng.last_sim or {})
            ls["rebaseline"] = True
            AntiTheftEngine.objects.filter(pk=eng.pk).update(last_sim=ls)
        AuditLog.objects.create(
            user=request.user, action="antitheft.false_alarm_cleared",
            detail={"phone_id": phone.id, "before": before,
                    "removed_signals": recent, "event_ids": [e.id for e in evs],
                    "at": now.isoformat()})
        name = _owner_name(request.user)
        sent = notify(phone, "all_clear",
                      "All clear: it was a false alarm",
                      ("%s confirmed with the Security PIN that the recent theft "
                       "alert was a false alarm. No action needed." % name),
                      "সব ঠিক আছে: ভুল সতর্কবার্তা ছিল",
                      ("%s সিকিউরিটি পিন দিয়ে নিশ্চিত করেছেন যে চুরির সাম্প্রতিক "
                       "সতর্কবার্তাটি ভুল ছিল। কিছু করতে হবে না।" % name),
                      family_only=True)
        return Response({"ok": True, "cleared": len(recent), "frozen": False,
                         "events_marked": len(evs), "family_notified": sent})


# --------------------------------------------------------------------------
# engine-token endpoints
# --------------------------------------------------------------------------

def _engine_from_request(request):
    raw = request.META.get("HTTP_X_ASSISTO_ENGINE", "") or ""
    if not raw or len(raw) > 200:
        return None
    return (AntiTheftEngine.objects.select_related("phone", "phone__owner")
            .filter(token_hash=at.hash_token(raw), enabled=True).first())


def _revoked():
    # stop:true tells the native engine to switch itself off and clear its
    # queue (protection was turned off, or the token was rotated).
    return Response({"ok": False, "reason": "engine_revoked", "stop": True},
                    status=status.HTTP_401_UNAUTHORIZED)


def _alert_new_events(phone, eng, new_events, now):
    """One alert per kind (newest wins), with a per-kind cooldown so a
    flapping signal never spams the family."""
    owner_name = _owner_name(phone.owner)
    newest = {}
    for ev in new_events:
        if ev.kind in at.SILENT_KINDS:
            continue
        if ev.kind == "failed_unlock":
            cnt = at.i_or_none((ev.data or {}).get("count")) or 0
            if cnt < eng.failed_unlock_threshold:
                continue
        cur = newest.get(ev.kind)
        if cur is None or ev.at > cur.at:
            newest[ev.kind] = ev
    for kind, ev in newest.items():
        cutoff = now - timedelta(minutes=at.ALERT_COOLDOWN_MIN)
        recently = (AntiTheftEvent.objects.filter(
            phone=phone, kind=kind, alerted=True, received_at__gte=cutoff)
            .exclude(pk=ev.pk).exists())
        if recently and kind != "test":
            continue
        te, be, tb, bb = at.alert_text(kind, owner_name, ev.at, ev.data, ev.lat,
                                       ev.lng, ev.battery, ev.late, now)
        notify(phone, kind, te, be, tb, bb,
               meta={"event_id": ev.id, "at": ev.at.isoformat(), "late": ev.late,
                     "lat": ev.lat, "lng": ev.lng},
               owner_only=kind in at.OWNER_ONLY_KINDS)
        AntiTheftEvent.objects.filter(pk=ev.pk).update(alerted=True)


class EngineIngestView(APIView):
    """Batch ingestion. Body:
      {sent_at, capabilities?, items:[{id, kind, at, lat?, lng?, acc?, battery?,
                                       charging?, network?, data?}]}
    kind 'heartbeat' goes to the PhoneHeartbeat trail; every other kind is an
    AntiTheftEvent. `id` is the device's unique id for the item (dedupe);
    `at` is when it happened (epoch ms or ISO). Items are processed in time
    order, so a store-and-forward backlog lands in the right order."""
    authentication_classes = []
    permission_classes = [AllowAny]
    parser_classes = [JSONParser]

    def post(self, request):
        eng = _engine_from_request(request)
        if eng is None:
            return _revoked()
        phone = eng.phone
        now = timezone.now()
        items = request.data.get("items") or []
        if not isinstance(items, list):
            return Response({"ok": False, "reason": "items_not_list"},
                            status=status.HTTP_400_BAD_REQUEST)
        items = items[:at.MAX_ITEMS_PER_POST]
        offset = at.clock_offset(request.data.get("sent_at"), now)


        if isinstance(request.data.get("capabilities"), dict):
            # at-heartbeat: MERGE (a heartbeat reports only a few live facts,
            # e.g. batteryOptimised; the enable-time facts must survive).
            caps = dict(eng.capabilities or {})
            caps.update(at.clean_data(request.data["capabilities"]))
            eng.capabilities = at.clean_data(caps)

        accepted, duplicate, rejected = [], [], []
        rows = []
        for it in items:
            if not isinstance(it, dict):
                continue
            cid = str(it.get("id") or "").strip()[:64]
            kind = str(it.get("kind") or "")
            if not cid:
                continue
            if kind != "heartbeat" and kind not in at.EVENT_KINDS:
                rejected.append({"id": cid, "reason": "bad_kind"})
                continue
            ev_at, ok = at.corrected_at(it.get("at"), offset, now)
            if not ok:
                rejected.append({"id": cid, "reason": "too_old"})
                continue
            rows.append((ev_at, cid, kind, it))
        rows.sort(key=lambda r: r[0])   # oldest first → correct replay order

        new_events = []
        for ev_at, cid, kind, it in rows:
            lat = at.f_or_none(it.get("lat"))
            lng = at.f_or_none(it.get("lng"))
            if not at.valid_latlng(lat, lng):
                lat = lng = None
            battery = at.i_or_none(it.get("battery"))
            network = str(it.get("network") or "")[:16]

            if kind == "heartbeat":
                if cid in (eng.recent_ids or []):
                    duplicate.append(cid)
                    continue
                PhoneHeartbeat.objects.create(phone=phone, lat=lat, lng=lng,
                                              battery=battery, network=network)
                ring = list(eng.recent_ids or [])
                ring.append(cid)
                eng.recent_ids = ring[-at.RECENT_IDS_KEEP:]
                phone.last_heartbeat_at = now
                # at-heartbeat: learn the interval the engine really uses
                # (battery-aware) so "went dark" waits the right time.
                iv = at.reported_interval(it, phone.lost_mode)
                if iv is not None:
                    phone.heartbeat_interval_min = iv
                if lat is not None and (eng.last_fix_at is None or ev_at >= eng.last_fix_at):
                    phone.last_lat, phone.last_lng = lat, lng
                    eng.last_fix_at = ev_at
                accepted.append(cid)
                continue

            # a real event (store-and-forward, deduped by (phone, client_id))
            try:
                with transaction.atomic():
                    ev = AntiTheftEvent.objects.create(
                        phone=phone, client_id=cid, kind=kind, at=ev_at,
                        late=at.is_late(ev_at, now),
                        data=at.clean_data(it.get("data")),
                        lat=lat, lng=lng,
                        accuracy_m=at.f_or_none(it.get("acc")), battery=battery)
            except IntegrityError:
                duplicate.append(cid)
                continue
            accepted.append(cid)
            new_events.append(ev)
            # a newer fix carried on an event also updates last location
            if lat is not None and (eng.last_fix_at is None or ev_at >= eng.last_fix_at):
                phone.last_heartbeat_at = phone.last_heartbeat_at or now
                phone.last_lat, phone.last_lng = lat, lng
                eng.last_fix_at = ev_at
            # a theft signal freezes Section-8 actions (snatch / sim_change)
            if kind in at.SIGNAL_KINDS:
                if _legacy_arming_sim(eng, kind, ev_at, ev.data):
                    d = dict(ev.data or {})
                    d["ignored"] = "arming_baseline"
                    AntiTheftEvent.objects.filter(pk=ev.pk).update(
                        data=d, alerted=True)
                    new_events.pop()
                    continue
                sec.register_signal(phone, at.SIGNAL_KINDS[kind], now)

        # phone is reporting again → clear the went-dark latch so a later gap
        # can re-alert, and tell the family it is back online (once).
        back_online = False
        if accepted or new_events:
            if phone.went_dark_alerted:
                back_online = True
            phone.went_dark_alerted = False
        eng.last_ingest_at = now
        try:  # own-device: the engine reports the app's id (same phone)
            from .own_device import remember as _own_remember
            _own_remember(eng, request)
        except Exception:
            pass
        phone.save()
        eng.save()

        if new_events:
            _alert_new_events(phone, eng, new_events, now)
        if back_online:
            # at-heartbeat: resolve the went-dark alert(s), then ONE
            # "back online" line to approved family only (never the owner).
            resolve_went_dark(phone, now)
            te, be, tb, bb = at.back_online_text(_owner_name(phone.owner),
                                                 phone.last_lat, phone.last_lng)
            notify(phone, "online", te, be, tb, bb, family_only=True,
                   meta={"lat": phone.last_lat, "lng": phone.last_lng})

        PhoneHeartbeat.prune(phone)
        prune_phone(phone, now)

        cfg = _config(phone, eng)
        # at-falsealarm: "It was me" asks the engine to re-record the SIM
        # baseline — delivered once, then consumed.
        ls = dict(eng.last_sim or {})
        if ls.pop("rebaseline", False):
            cfg["rebaseline_sim"] = True
            AntiTheftEngine.objects.filter(pk=eng.pk).update(last_sim=ls)

        return Response({
            "ok": True,
            "accepted": accepted, "duplicate": duplicate, "rejected": rejected,
            "config": cfg,
            "lost_mode": phone.lost_mode,
            "lost_message": phone.lost_message,
            "lost_contact": phone.lost_contact,
            "frozen": sec.is_frozen(phone, now),
        })


class EnginePhotoView(APIView):
    """One intruder photo (multipart: file + id + at? + data?). Stored
    ENCRYPTED at rest; there is no public URL. kind is fixed to
    intruder_photo. Deduped by (phone, client_id)."""
    authentication_classes = []
    permission_classes = [AllowAny]
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request):
        eng = _engine_from_request(request)
        if eng is None:
            return _revoked()
        phone = eng.phone
        now = timezone.now()
        # Opt-in: the owner must have switched "Intruder photo" on. A photo
        # taken before they switched it off is refused (403 = the engine drops
        # it, never retries).
        if not eng.intruder_photo:
            return Response({"ok": False, "reason": "intruder_photo_off"},
                            status=status.HTTP_403_FORBIDDEN)
        f = request.FILES.get("file") or request.FILES.get("photo")
        if f is None:
            return Response({"ok": False, "reason": "no_file"},
                            status=status.HTTP_400_BAD_REQUEST)
        if f.size and f.size > at.MAX_PHOTO_BYTES:
            return Response({"ok": False, "reason": "too_large"},
                            status=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE)
        day_ago = now - timedelta(days=1)
        if AntiTheftEvent.objects.filter(phone=phone, kind="intruder_photo",
                                         received_at__gte=day_ago).count() >= at.MAX_PHOTOS_PER_DAY:
            return Response({"ok": False, "reason": "rate_limited"},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        raw = f.read()
        if not at.looks_like_jpeg(raw):
            return Response({"ok": False, "reason": "not_jpeg"},
                            status=status.HTTP_400_BAD_REQUEST)
        cid = str(request.data.get("id") or uuid.uuid4().hex)[:64]
        data_raw = request.data.get("data")
        if isinstance(data_raw, str):
            try:
                data_raw = json.loads(data_raw)
            except Exception:
                data_raw = {}
        ev_at, ok = at.corrected_at(request.data.get("at"),
                                    at.clock_offset(request.data.get("sent_at"), now), now)
        if not ok:
            ev_at = now
        enc = at.encrypt_photo(raw)
        try:
            with transaction.atomic():
                ev = AntiTheftEvent.objects.create(
                    phone=phone, client_id=cid, kind="intruder_photo", at=ev_at,
                    late=at.is_late(ev_at, now), data=at.clean_data(data_raw),
                    lat=at.f_or_none(request.data.get("lat")),
                    lng=at.f_or_none(request.data.get("lng")),
                    battery=at.i_or_none(request.data.get("battery")))
                ev.photo.save("%s.enc" % uuid.uuid4().hex,
                              ContentFile(enc), save=True)
        except IntegrityError:
            return Response({"ok": True, "duplicate": True})
        _alert_new_events(phone, eng, [ev], now)
        return Response({"ok": True, "id": ev.id})


# --------------------------------------------------------------------------
# viewing (owner + approved family only; everyone else 404)
# --------------------------------------------------------------------------

class EngineTimelineView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        pid = request.query_params.get("phone_id")
        if pid:
            phone = ProtectedPhone.objects.filter(pk=pid).first()
        else:
            phone = _primary_phone(request.user)
        if phone is None or not can_view(phone, request.user):
            raise Http404
        is_owner = phone.owner_id == request.user.id
        evs = [_event_json(e, is_owner) for e in phone.engine_events.all()[:200]]
        eng = _engine(phone, create=False)
        dark = _went_dark_since(phone)
        return Response({
            "viewer": "owner" if is_owner else "family",
            "enabled": bool(eng and eng.enabled),
            "lost_mode": phone.lost_mode,
            "went_dark_at": dark.isoformat() if dark else None,
            "last_location": ({"lat": phone.last_lat, "lng": phone.last_lng,
                               "at": phone.last_heartbeat_at.isoformat()
                               if phone.last_heartbeat_at else None}
                              if phone.last_lat is not None else None),
            "events": evs,
        })


class EngineWatchingView(APIView):
    """Phones whose alerts THIS user (as approved family) receives. Lets a
    family member see the lost phones they're helping watch."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        me = request.user
        out = []
        # phones where I am the family approver
        q = ProtectedPhone.objects.filter(
            Q(family_approver__peer_user=me, family_approver__state="accepted")
        ).distinct()
        seen = set()
        for phone in q:
            if phone.owner_id == me.id:
                continue
            if phone.id in seen or not can_view(phone, me):
                continue
            seen.add(phone.id)
            out.append(self._brief(phone))
        # phones where I am ticked into alert_member_ids
        for eng in AntiTheftEngine.objects.filter(enabled=True).select_related(
                "phone", "phone__owner"):
            phone = eng.phone
            if phone.id in seen or phone.owner_id == me.id:
                continue
            if can_view(phone, me):
                seen.add(phone.id)
                out.append(self._brief(phone))
        return Response({"watching": out})

    def _brief(self, phone):
        from . import push
        dark = _went_dark_since(phone)
        return {"phone_id": phone.id, "owner": push.display_name(phone.owner),
                "model": phone.model_name, "lost_mode": phone.lost_mode,
                "went_dark_at": dark.isoformat() if dark else None}


class EnginePhotoLinkView(APIView):
    """Mint a short-lived signed link for an intruder photo (owner or approved
    family only). The link alone then streams the decrypted bytes."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        ev = AntiTheftEvent.objects.filter(pk=pk, kind="intruder_photo").first()
        if ev is None or not ev.photo or not can_view(ev.phone, request.user):
            raise Http404
        params = at.photo_link_params(ev.id, request.user.id)
        qs = "&".join("%s=%s" % (k, v) for k, v in params.items())
        return Response({"url": "/security/engine/event/%d/photo?%s" % (ev.id, qs)})


class EnginePhotoBytesView(APIView):
    """Stream the DECRYPTED intruder photo for a valid signed link. No auth
    header needed (works in an <img>), but the signature is bound to the
    viewer id that EnginePhotoLinkView minted, so a stranger's link is 404."""
    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request, pk):
        ev = AntiTheftEvent.objects.filter(pk=pk, kind="intruder_photo").first()
        if ev is None or not ev.photo:
            raise Http404
        v = request.GET.get("v")
        if not at.verify_photo_link(ev.id, v, request.GET.get("e"),
                                    request.GET.get("s")):
            raise Http404
        viewer = User.objects.filter(pk=v).first()
        if viewer is None or not can_view(ev.phone, viewer):
            raise Http404
        try:
            with ev.photo.open("rb") as fh:
                plain = at.decrypt_photo(fh.read())
        except Exception:
            raise Http404
        resp = HttpResponse(plain, content_type="image/jpeg")
        resp["Cache-Control"] = "private, max-age=300"
        resp["X-Content-Type-Options"] = "nosniff"
        return resp
