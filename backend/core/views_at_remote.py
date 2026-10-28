"""
at100 (owner 27 Oct) — REMOTE SWITCHES for a protected phone + the
intruder-photo consent rules.

  POST security/engine/command            {kind, phone_id?, message?, contact?}
  GET  security/engine/commands[?phone_id]
  POST security/engine/command/<id>/cancel

kinds: lost_mode · alarm · alarm_stop · lock · message.  "wipe" is NOT
offered (we never request the device-admin wipe policy — see
owner_actions/ANTITHEFT_PLAY_DECLARATION_BN.md); asking for it returns an
honest 400 pointing to Google Find Hub.

WHO may switch: the phone's OWNER (signed in on any device) and the trusted
contacts the owner approved (approved_family_users). Everyone else gets 404 —
we never reveal that a phone exists. A trusted contact may always turn lost
mode ON (protective); alarm / lock / message only while the phone is in lost
mode, has gone dark, or raised a theft alert in the last 48 h — so this is
never a way to harass the owner.

Every switch is rate-limited (per person per phone per hour, alarms tighter,
per phone per day) and AUDITED (AuditLog on the owner's account, and on the
trusted contact's account when they pressed it).

DELIVERY (honest): the command is stored ("queued"), a silent HIGH-priority
wake-up push goes to the owner's devices ("sent" when Google accepted it),
the protected phone's engine fetches it on its next check-in ("delivered" =
it reached the phone) and reports the outcome ("done" / "failed" + why).
A phone that is switched off or has no internet receives nothing — no app
can reach it. The command waits until expires_at and runs the moment the
phone checks in again; after that it is "expired".
"""
from datetime import timedelta

from django.conf import settings
from django.db import close_old_connections
from django.http import Http404
from django.utils import timezone

from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import antitheft as at
from .models import (AntiTheftCommand, AntiTheftEvent, AuditLog, NotifEvent,
                     ProtectedPhone)

COMMAND_KINDS = ("lost_mode", "alarm", "alarm_stop", "lock", "message")
TTL = {"lost_mode": timedelta(days=7), "alarm": timedelta(hours=24),
       "alarm_stop": timedelta(hours=1), "lock": timedelta(hours=24),
       "message": timedelta(days=7)}
RATE_PER_HOUR = 12        # one person, one phone, all kinds
ALARM_PER_HOUR = 4        # one person, one phone, loud alarm
PHONE_PER_DAY = 40        # everyone together, one phone
ACTIVE_WINDOW_H = 48
DELIVER_MAX = 5
PENDING = ("queued", "sent")
IN_FLIGHT = ("queued", "sent", "delivered")
THEFT_KINDS = ("snatch", "sim_change", "failed_unlock", "intruder_photo",
               "shutdown", "offline", "went_dark", "low_battery")
FIND_HUB_URL = "https://www.google.com/android/find"
ALARM_SECONDS = 60        # the phone rings this long (MUST match RemoteCommands.kt)

# Intruder photo: the consent screen's version. Raise it when the consent
# text changes materially — older consents then stop counting.
INTRUDER_CONSENT_VERSION = 1


# --------------------------------------------------------------------------
# intruder photo consent
# --------------------------------------------------------------------------

def intruder_on(eng):
    """The intruder photo is ON only with the owner's current consent. A
    legacy engine switched on before the consent screen existed counts as
    OFF (the owner is asked again)."""
    return bool(eng is not None and eng.intruder_photo and
                (eng.intruder_consent_v or 0) >= INTRUDER_CONSENT_VERSION)


def apply_intruder_choice(request, eng):
    """Handle `intruder_photo` on enable/settings. Returns None when fine,
    else the 400 Response (switching it ON needs `intruder_consent` = the
    current version, sent by the consent screen's "I agree")."""
    from .views_antitheft import _bool
    want = _bool(request.data.get("intruder_photo"), None)
    if want is None:
        return None
    if not want:
        eng.intruder_photo = False
        return None
    given = at.i_or_none(request.data.get("intruder_consent"))
    if (given or 0) < INTRUDER_CONSENT_VERSION:
        return Response({"ok": False, "reason": "consent_required",
                         "consent_version": INTRUDER_CONSENT_VERSION},
                        status=status.HTTP_400_BAD_REQUEST)
    eng.intruder_photo = True
    eng.intruder_consent_v = INTRUDER_CONSENT_VERSION
    eng.intruder_consent_at = timezone.now()
    try:
        AuditLog.objects.create(
            user=eng.phone.owner, action="antitheft.intruder_consent",
            detail={"phone_id": eng.phone_id, "version": INTRUDER_CONSENT_VERSION,
                    "at": eng.intruder_consent_at.isoformat()})
    except Exception:
        pass
    return None


def intruder_snap_due(phone):
    """A wrong Security PIN typed INSIDE Assisto (the app is open, so the
    front camera may be used in the foreground). True = the app should take
    one front photo now: the owner consented, and this is at least the
    owner's threshold of wrong attempts in a row."""
    try:
        eng = phone.engine
    except Exception:
        return False
    if not (eng.enabled and intruder_on(eng)):
        return False
    th = max(at.THRESHOLD_MIN, min(at.THRESHOLD_MAX, eng.failed_unlock_threshold or 3))
    from .logic import security as sec
    th = min(th, sec.WRONG_PIN_LOCK)
    return (phone.wrong_pin_count or 0) >= th


# --------------------------------------------------------------------------
# who / when
# --------------------------------------------------------------------------

def role_for(phone, user):
    from .views_antitheft import trusted_contacts
    if user is None or not getattr(user, "is_authenticated", False):
        return None
    if phone.owner_id == user.id:
        return "owner"
    if any(u.pk == user.pk for u in trusted_contacts(phone)):
        return "trusted"
    return None


def phone_active(phone, now=None):
    """Lost mode on, gone dark, or a real theft alert in the last 48 h."""
    now = now or timezone.now()
    if phone.lost_mode:
        return True
    from .views_lost import _went_dark_since
    if _went_dark_since(phone, now) is not None:
        return True
    for ev in AntiTheftEvent.objects.filter(
            phone=phone, kind__in=THEFT_KINDS, alerted=True,
            at__gte=now - timedelta(hours=ACTIVE_WINDOW_H)).only("data")[:50]:
        d = ev.data or {}
        if d.get("false_alarm") or d.get("suppressed") or d.get("silent") \
                or d.get("ignored"):
            continue
        return True
    return False


def presence(phone, eng, now=None):
    """Is the phone checking in right now? (honest, from the engine's last
    upload — not a guess)."""
    now = now or timezone.now()
    last = eng.last_ingest_at if eng is not None else None
    iv = max(1, phone.heartbeat_interval_min or at.INTERVAL_NORMAL)
    online = bool(last and (now - last) <= timedelta(minutes=iv * 2 + 2))
    caps = (eng.capabilities if eng is not None else None) or {}
    return {"protection_on": bool(eng and eng.enabled),
            "online": online,
            "last_seen": last.isoformat() if last else None,
            "interval_min": iv,
            "lost_mode": bool(phone.lost_mode),
            "device_admin": caps.get("deviceAdmin"),
            "notifications": caps.get("notifications")}


def can_map(phone, role, eng, now=None):
    if eng is None or not eng.enabled or role is None:
        return {k: False for k in COMMAND_KINDS}
    if role == "owner":
        return {k: True for k in COMMAND_KINDS}
    active = phone_active(phone, now)
    return {k: (k == "lost_mode" or active) for k in COMMAND_KINDS}


def expire_stale(phone, now=None):
    now = now or timezone.now()
    try:
        return AntiTheftCommand.objects.filter(
            phone=phone, state__in=PENDING, expires_at__lt=now).update(
            state="expired", detail="phone_never_online")
    except Exception:
        return 0


def _name(user):
    from .views_antitheft import _owner_name
    return _owner_name(user) if user is not None else ""


def public(cmd, viewer=None):
    return {
        "id": cmd.id, "kind": cmd.kind, "state": cmd.state,
        "detail": cmd.detail or "",
        "by_owner": cmd.by_owner,
        "by": "" if cmd.by_owner else _name(cmd.requested_by),
        "mine": bool(viewer is not None and cmd.requested_by_id == viewer.pk),
        "message": cmd.message, "contact": cmd.contact,
        "created_at": cmd.created_at.isoformat() if cmd.created_at else None,
        "sent_at": cmd.sent_at.isoformat() if cmd.sent_at else None,
        "delivered_at": cmd.delivered_at.isoformat() if cmd.delivered_at else None,
        "done_at": cmd.done_at.isoformat() if cmd.done_at else None,
        "expires_at": cmd.expires_at.isoformat() if cmd.expires_at else None,
        "push_sent": cmd.push_sent,
    }


def _audit(phone, user, action, detail):
    """One row on the OWNER's audit trail, and one on the trusted contact's
    own trail when they pressed it. Never raises."""
    try:
        d = dict(detail)
        d.setdefault("phone_id", phone.id)
        AuditLog.objects.create(user=phone.owner, action=action, detail=d)
        if user is not None and user.pk != phone.owner_id:
            AuditLog.objects.create(user=user, action=action, detail=d)
    except Exception:
        pass


def _target_phone(request, pid_raw):
    if pid_raw not in (None, ""):
        pid = at.i_or_none(pid_raw)
        phone = ProtectedPhone.objects.filter(pk=pid).first() if pid is not None else None
    else:
        phone = ProtectedPhone.objects.filter(
            owner=request.user).order_by("created_at").first()
    return phone


# --------------------------------------------------------------------------
# wake-up push
# --------------------------------------------------------------------------

def _wake_now(cmd_id):
    from . import push
    try:
        cmd = AntiTheftCommand.objects.select_related("phone__owner").filter(
            pk=cmd_id).first()
        if cmd is None or cmd.state != "queued":
            return 0
        n = push.push_to_user(
            cmd.phone.owner, "at_command", "", "", "", "",
            data={"phone_id": cmd.phone_id, "command_id": cmd.id, "silent": "1"},
            high_priority=True, data_only=True)
        if n:
            AntiTheftCommand.objects.filter(pk=cmd.pk, state="queued").update(
                state="sent", sent_at=timezone.now(), push_sent=n)
        return n
    except Exception:
        return 0


def _wake_worker(cmd_id):
    try:
        _wake_now(cmd_id)
    finally:
        try:
            close_old_connections()
        except Exception:
            pass


def wake(cmd):
    """Silent HIGH-priority data push so the protected phone checks in now
    instead of at its next heartbeat. "sent" only when Google accepted it.
    Never raises; without push credentials the command simply stays queued
    (the phone still gets it at its next check-in)."""
    from . import push
    try:
        if not push.is_available():
            return False
        if getattr(settings, "PUSH_SYNC", False):
            return _wake_now(cmd.id) > 0
        push._get_executor().submit(_wake_worker, cmd.id)
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------
# result texts (bilingual) for the trusted contact who pressed it
# --------------------------------------------------------------------------

_KIND_TXT = {
    "lost_mode": ("Lost mode", "হারানো মোড"),
    "alarm": ("Loud alarm", "জোরে অ্যালার্ম"),
    "alarm_stop": ("Stop alarm", "অ্যালার্ম থামানো"),
    "lock": ("Lock screen", "স্ক্রিন লক"),
    "message": ("Lock-screen message", "লক-স্ক্রিনে বার্তা"),
}
_FAIL_TXT = {
    "no_admin": ("device admin is off on that phone, so it cannot be locked",
                 "ওই ফোনে ডিভাইস অ্যাডমিন বন্ধ, তাই লক করা যায়নি"),
    "no_sound": ("the phone could not play a sound",
                 "ফোনটি শব্দ বাজাতে পারেনি"),
    "notif_blocked": ("notifications are blocked on that phone",
                      "ওই ফোনে নোটিফিকেশন বন্ধ"),
    "expired": ("it arrived too late", "অনেক দেরিতে পৌঁছেছে"),
}


def result_text(cmd, owner_name):
    ke, kb = _KIND_TXT.get(cmd.kind, (cmd.kind, cmd.kind))
    if cmd.state == "done":
        te = "%s: done on %s's phone" % (ke, owner_name)
        tb = "%s: %s-এর ফোনে হয়েছে" % (kb, owner_name)
        if cmd.kind == "alarm":
            be = "The alarm is ringing on the phone for %d seconds." % ALARM_SECONDS
            bb = "ফোনে %d সেকেন্ড ধরে অ্যালার্ম বাজছে।" % ALARM_SECONDS
        else:
            be = "The phone confirmed it at %s." % timezone.localtime(
                cmd.done_at or timezone.now()).strftime("%I:%M %p")
            bb = "ফোনটি %s-এ নিশ্চিত করেছে।" % timezone.localtime(
                cmd.done_at or timezone.now()).strftime("%I:%M %p")
        return te, be, tb, bb
    fe, fb = _FAIL_TXT.get(cmd.detail, ("the phone could not do it",
                                        "ফোনটি কাজটি করতে পারেনি"))
    return ("%s did not work" % ke, "%s's phone: %s." % (owner_name, fe),
            "%s হয়নি" % kb, "%s-এর ফোন: %s।" % (owner_name, fb))


def _tell_requester(cmd):
    """The trusted contact who pressed the switch gets the outcome (in-app +
    push). The owner sees it on the switches card. Never raises."""
    from . import push
    try:
        u = cmd.requested_by
        if u is None or cmd.by_owner or u.pk == cmd.phone.owner_id:
            return 0
        if cmd.kind == "alarm_stop" and cmd.state == "done":
            return 0
        te, be, tb, bb = result_text(cmd, _name(cmd.phone.owner))
        from .views_antitheft import watch_path
        NotifEvent.objects.create(
            user=u, type="security", title_bn=tb[:200], title_en=te[:200],
            body_bn=bb, body_en=be, route="security/watch-phone",
            meta={"phone_id": cmd.phone_id, "owner_id": cmd.phone.owner_id,
                  "antitheft_kind": "command_result", "command_id": cmd.id,
                  "state": cmd.state, "web_path": watch_path(cmd.phone, u)},
            at=timezone.now())
        push.safe_push(u, "family_alert", tb, te, bb, be,
                       data={"alert_kind": "antitheft",
                             "route": "security/watch-phone",
                             "phone_id": cmd.phone_id,
                             "antitheft_kind": "command_result",
                             "owner_id": cmd.phone.owner_id},
                       high_priority=True)
        return 1
    except Exception:
        return 0


# --------------------------------------------------------------------------
# engine side (called from EngineIngestView)
# --------------------------------------------------------------------------

def phone_texts(kind, lang, message, contact):
    """What the protected phone itself shows (its owner's language): the
    lock-screen title/body and the alarm's Stop label."""
    en = lang == "en"
    if kind == "alarm":
        return ({"title": "Assisto alarm: this phone was reported lost" if en
                 else "Assisto অ্যালার্ম: এই ফোনটি হারানো বলে জানানো হয়েছে",
                 "body": ("If you found it, please press Stop and call the owner%s."
                          % ((": " + contact) if contact else "")) if en else
                 ("ফোনটি পেয়ে থাকলে Stop চাপুন এবং মালিককে ফোন করুন%s।"
                  % ((": " + contact) if contact else "")),
                 "stop": "Stop" if en else "থামান"})
    body = message or ("Please return this phone to its owner." if en
                       else "দয়া করে ফোনটি মালিককে ফেরত দিন।")
    if contact:
        body += ("\nOwner: " if en else "\nমালিকের নম্বর: ") + contact
    return {"title": "This phone is lost" if en else "এই ফোনটি হারানো গেছে",
            "body": body, "stop": "Stop" if en else "থামান"}


def deliver(phone, now=None):
    """Commands for the engine's ingest response; each is marked delivered
    (it reached the phone). Oldest first, at most DELIVER_MAX."""
    from . import push
    now = now or timezone.now()
    out = []
    try:
        lang = push.user_lang(phone.owner)
        expire_stale(phone, now)
        rows = list(AntiTheftCommand.objects.filter(
            phone=phone, state__in=PENDING).order_by("created_at", "id")[:DELIVER_MAX])
        for c in rows:
            AntiTheftCommand.objects.filter(pk=c.pk, state__in=PENDING).update(
                state="delivered", delivered_at=now)
            msg = c.message or phone.lost_message or ""
            contact = c.contact or phone.lost_contact or ""
            row = {"id": c.id, "kind": c.kind, "message": msg[:300],
                   "contact": contact[:120], "by_owner": c.by_owner,
                   "alarm_s": ALARM_SECONDS,
                   "ttl_s": max(0, int((c.expires_at - now).total_seconds()))}
            row.update(phone_texts(c.kind, lang, msg[:300], contact[:120]))
            out.append(row)
    except Exception:
        return out
    return out


def apply_result(phone, data, now=None):
    """An ingest item {kind:'command_result', data:{command_id, ok, detail}}.
    Idempotent. True when it named one of THIS phone's commands."""
    now = now or timezone.now()
    data = data if isinstance(data, dict) else {}
    cid = at.i_or_none(data.get("command_id"))
    if cid is None:
        return False
    cmd = AntiTheftCommand.objects.select_related(
        "phone__owner", "requested_by").filter(pk=cid, phone=phone).first()
    if cmd is None:
        return False
    if cmd.state in ("done", "failed", "cancelled"):
        return True
    ok = data.get("ok") is True or str(data.get("ok")).lower() == "true"
    detail = "".join(ch for ch in str(data.get("detail") or "")[:80]
                     if ch.isalnum() or ch in "_-. ")
    cmd.state = "done" if ok else "failed"
    cmd.detail = detail
    cmd.done_at = now
    cmd.delivered_at = cmd.delivered_at or now
    cmd.save(update_fields=["state", "detail", "done_at", "delivered_at"])
    _audit(phone, None, "antitheft.command_result",
           {"command_id": cmd.id, "kind": cmd.kind, "state": cmd.state,
            "detail": detail, "at": now.isoformat()})
    _tell_requester(cmd)
    return True


# --------------------------------------------------------------------------
# views
# --------------------------------------------------------------------------

class CommandView(APIView):
    """POST security/engine/command {kind, phone_id?, message?, contact?}."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from .views_antitheft import _engine, notify
        kind = str(request.data.get("kind") or "").strip()
        if kind in ("wipe", "erase"):
            return Response({"ok": False, "reason": "wipe_not_supported",
                             "use": FIND_HUB_URL},
                            status=status.HTTP_400_BAD_REQUEST)
        if kind not in COMMAND_KINDS:
            return Response({"ok": False, "reason": "bad_kind"},
                            status=status.HTTP_400_BAD_REQUEST)
        phone = _target_phone(request, request.data.get("phone_id"))
        if phone is None:
            raise Http404
        role = role_for(phone, request.user)
        if role is None:
            raise Http404
        eng = _engine(phone, create=False)
        if eng is None or not eng.enabled:
            return Response({"ok": False, "reason": "protection_off"},
                            status=status.HTTP_409_CONFLICT)
        now = timezone.now()
        if role == "trusted" and kind != "lost_mode" and not phone_active(phone, now):
            return Response({"ok": False, "reason": "not_active"},
                            status=status.HTTP_403_FORBIDDEN)
        mine = AntiTheftCommand.objects.filter(
            phone=phone, requested_by=request.user,
            created_at__gte=now - timedelta(hours=1))
        if mine.count() >= RATE_PER_HOUR or (
                kind == "alarm" and mine.filter(kind="alarm").count() >= ALARM_PER_HOUR) or \
                AntiTheftCommand.objects.filter(
                    phone=phone, created_at__gte=now - timedelta(days=1)).count() >= PHONE_PER_DAY:
            _audit(phone, request.user, "antitheft.command_rate_limited",
                   {"kind": kind, "role": role, "at": now.isoformat()})
            return Response({"ok": False, "reason": "rate_limited",
                             "retry_after_s": 3600},
                            status=status.HTTP_429_TOO_MANY_REQUESTS)
        message = str(request.data.get("message") or "").strip()[:300]
        contact = str(request.data.get("contact") or "").strip()[:120]
        if kind == "message" and not (message or phone.lost_message):
            return Response({"ok": False, "reason": "message_required"},
                            status=status.HTTP_400_BAD_REQUEST)

        # a newer switch of the same kind replaces a waiting one; "stop
        # alarm" also drops an alarm that has not reached the phone yet.
        same = [kind] + (["alarm"] if kind == "alarm_stop" else [])
        AntiTheftCommand.objects.filter(
            phone=phone, kind__in=same, state__in=PENDING).update(
            state="cancelled", detail="replaced", done_at=now)

        if kind == "lost_mode":
            was = phone.lost_mode
            phone.lost_mode = True
            if message:
                phone.lost_message = message
            if contact:
                phone.lost_contact = contact
            if phone.lost_since is None:
                phone.lost_since = now
            phone.save()
            if not was:
                who = _name(request.user)
                owner = _name(phone.owner)
                notify(phone, "lost_mode",
                       "Lost mode is on for %s's phone" % owner,
                       ("%s turned on lost mode. The phone checks in every few "
                        "minutes and shows the owner's message when it is online."
                        % who),
                       "%s-এর ফোনে হারানো মোড চালু" % owner,
                       ("%s হারানো মোড চালু করেছেন। ফোন অনলাইনে থাকলে কয়েক মিনিট "
                        "পরপর খবর দেবে আর মালিকের বার্তা দেখাবে।" % who),
                       family_only=True)

        cmd = AntiTheftCommand.objects.create(
            phone=phone, kind=kind, requested_by=request.user,
            by_owner=(role == "owner"), message=message, contact=contact,
            expires_at=now + TTL[kind])
        _audit(phone, request.user, "antitheft.command",
               {"command_id": cmd.id, "kind": kind, "role": role,
                "by_user_id": request.user.pk, "at": now.isoformat()})
        wake(cmd)
        cmd.refresh_from_db()
        return Response({"ok": True, "command": public(cmd, request.user),
                         "phone": presence(phone, eng, now)},
                        status=status.HTTP_201_CREATED)


def _web_path(phone, user):
    try:
        from .views_antitheft import watch_path
        return watch_path(phone, user)
    except Exception:
        return ""


class CommandListView(APIView):
    """GET security/engine/commands[?phone_id] — owner or trusted contact."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .views_antitheft import _engine
        phone = _target_phone(request, request.query_params.get("phone_id"))
        if phone is None:
            raise Http404
        role = role_for(phone, request.user)
        if role is None:
            raise Http404
        eng = _engine(phone, create=False)
        now = timezone.now()
        expire_stale(phone, now)
        rows = [public(c, request.user) for c in AntiTheftCommand.objects.filter(
            phone=phone).select_related("requested_by")[:20]]
        return Response({
            "role": role,
            "phone_id": phone.id,
            "owner": _name(phone.owner),
            "phone": presence(phone, eng, now),
            "can": can_map(phone, role, eng, now),
            "commands": rows,
            "in_flight": any(r["state"] in IN_FLIGHT for r in rows),
            "wipe": {"supported": False, "use": FIND_HUB_URL},
            "alarm_s": ALARM_SECONDS,
            # the viewer's own signed web view of this phone (7 days)
            "web_path": _web_path(phone, request.user),
        })


class CommandCancelView(APIView):
    """POST security/engine/command/<id>/cancel — the person who sent it or
    the owner, only while it has not reached the phone."""
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        cmd = AntiTheftCommand.objects.select_related("phone").filter(pk=pk).first()
        if cmd is None:
            raise Http404
        role = role_for(cmd.phone, request.user)
        if role is None:
            raise Http404
        if role != "owner" and cmd.requested_by_id != request.user.pk:
            raise Http404
        if cmd.state not in PENDING:
            return Response({"ok": False, "reason": "already_" + cmd.state,
                             "command": public(cmd, request.user)},
                            status=status.HTTP_409_CONFLICT)
        now = timezone.now()
        AntiTheftCommand.objects.filter(pk=cmd.pk, state__in=PENDING).update(
            state="cancelled", detail="by_" + role, done_at=now)
        _audit(cmd.phone, request.user, "antitheft.command_cancel",
               {"command_id": cmd.id, "kind": cmd.kind, "role": role,
                "at": now.isoformat()})
        cmd.refresh_from_db()
        return Response({"ok": True, "command": public(cmd, request.user)})
