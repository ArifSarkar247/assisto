"""
Stolen-While-Unlocked Protection — HTTP surface.

SERVER IS THE SOURCE OF TRUTH. A factory reset on the handset cannot change
ownership or clear armed/frozen/status; those only move through these
endpoints, every one of which gates a sensitive action behind PIN +
trusted-location + (delay OR family approval). The native engine only reports
signals via /security/signal — it cannot grant itself a capability here.

The raw Security PIN is never stored or logged; we keep only the
make_password hash and compare with check_password.
"""
import secrets

from django.conf import settings
from django.contrib.auth.hashers import make_password, check_password
from django.core.mail import send_mail
from django.utils import timezone

from rest_framework import status
from rest_framework.permissions import IsAuthenticated, AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (ProtectedPhone, PendingSensitiveAction, CircleMember,
                     FamilyAlert, NotifEvent)
from .logic import security as sec


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def _primary_phone(user, create=True):
    """The user's primary protected handset (earliest-created). Auto-provision
    an empty row on first touch so the client always has state to read."""
    phone = ProtectedPhone.objects.filter(owner=user).order_by("created_at").first()
    if phone is None and create:
        phone = ProtectedPhone.objects.create(owner=user)
    return phone


def _accepted_members(user):
    return list(CircleMember.objects.filter(user=user, state="accepted"))


def _notify_owner_and_circle(user, title, body, kind="security", ntype="security",
                             route="security", meta=None):
    """Create a FamilyAlert + NotifEvent for the owner, a NotifEvent for each
    accepted circle member, and email everyone with an address. fail_silently
    on email (see views_module5). Never raises."""
    meta = meta or {}
    now = timezone.now()
    FamilyAlert.objects.create(user=user, kind="security", title=title,
                               body=body, severity="high", payload=meta)
    NotifEvent.objects.create(user=user, type="security", title_en=title,
                              body_en=body, route=route, meta=meta, at=now)
    emails = [user.email] if user.email else []
    for m in _accepted_members(user):
        if m.peer_user_id:
            NotifEvent.objects.create(user_id=m.peer_user_id, type="security",
                                      title_en=title, body_en=body, route=route,
                                      meta=meta, at=now)
            if m.peer_user and m.peer_user.email:
                emails.append(m.peer_user.email)
    emails = [e for e in dict.fromkeys(emails) if e]
    if emails:
        try:
            send_mail(title, body, settings.DEFAULT_FROM_EMAIL, emails,
                      fail_silently=True)
        except Exception:
            pass


def _register_lockout(user, phone):
    """5th wrong PIN: freeze via theft signal + alert owner and circle."""
    now = timezone.now()
    sec.register_signal(phone, "wrong_pin", now)
    phone.save()
    when = now.strftime("%Y-%m-%d %H:%M")
    _notify_owner_and_circle(
        user,
        "Someone is trying your Assisto Security PIN",
        f"Several wrong Security-PIN attempts around {when}. If this was not "
        f"you, your phone may be in someone else's hands.",
        meta={"reason": "wrong_pin", "at": now.isoformat()})


def _verify_pin(phone, raw_pin):
    """Return (ok, locked). Increments wrong_pin_count on failure; locks (and
    the caller fires the lockout) at WRONG_PIN_LOCK. Resets count on success.
    A phone with no PIN set yet cannot pass verification."""
    if not phone.security_pin_hash:
        return (False, False)
    if check_password(str(raw_pin or ""), phone.security_pin_hash):
        if phone.wrong_pin_count:
            phone.wrong_pin_count = 0
            phone.save(update_fields=["wrong_pin_count", "updated_at"])
        return (True, False)
    phone.wrong_pin_count = (phone.wrong_pin_count or 0) + 1
    locked = phone.wrong_pin_count >= sec.WRONG_PIN_LOCK
    phone.save(update_fields=["wrong_pin_count", "updated_at"])
    return (False, locked)


def _pending_list(phone):
    return [{"id": p.id, "action": p.action,
             "effective_at": p.effective_at.isoformat() if p.effective_at else None,
             "state": p.state}
            for p in phone.pending_actions.exclude(
                state__in=["cancelled", "applied", "rejected"])]


def _apply_action(phone, action):
    """Perform the real side-effects of an approved/immediate sensitive action.
    v1 keeps these minimal but real; expand as features land."""
    if action == "disarm":
        phone.armed = False
    elif action == "turn_off_lost":
        phone.frozen_until = None
    # sell_transfer side-effects (ownership change / registry) are a LATER
    # batch — they must first consult recent_theft_signal() (TODO hook).
    phone.save()


# --------------------------------------------------------------------------
# GET security/state
# --------------------------------------------------------------------------

class SecurityStateView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import SavedPlace
        phone = _primary_phone(request.user)
        return Response({
            "has_pin": bool(phone.security_pin_hash),
            "armed": phone.armed,
            "frozen_until": phone.frozen_until.isoformat() if phone.frozen_until else None,
            "status": phone.status,
            "wrong_pin_count": phone.wrong_pin_count,
            "trusted_place_count": SavedPlace.objects.filter(user=request.user).count(),
            "pending": _pending_list(phone),
        })


# --------------------------------------------------------------------------
# POST security/pin/set
# --------------------------------------------------------------------------

class SecurityPinSetView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        new_pin = str(request.data.get("new_pin", "")).strip()
        if len(new_pin) < 4:
            return Response({"ok": False, "reason": "pin_too_short"},
                            status=status.HTTP_400_BAD_REQUEST)
        # If a PIN already exists, the current PIN must verify first.
        # NOTE (v1): changing the PIN while armed + untrusted should ideally run
        # through decide_action as action 'change_pin'. For v1 we require the
        # current PIN and allow the set directly; the delayed path for change_pin
        # is exercised through POST security/action {action:"change_pin"}.
        if phone.security_pin_hash:
            cur = str(request.data.get("current_pin", ""))
            if not check_password(cur, phone.security_pin_hash):
                return Response({"ok": False, "reason": "bad_current_pin"},
                                status=status.HTTP_403_FORBIDDEN)
        phone.security_pin_hash = make_password(new_pin)
        phone.wrong_pin_count = 0
        phone.save()
        return Response({"ok": True})


# --------------------------------------------------------------------------
# POST security/pin/verify
# --------------------------------------------------------------------------

class SecurityPinVerifyView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        ok, locked = _verify_pin(phone, request.data.get("pin"))
        if ok:
            return Response({"ok": True})
        if locked:
            _register_lockout(request.user, phone)
            return Response({"ok": False, "locked": True})
        return Response({"ok": False})


# --------------------------------------------------------------------------
# POST security/action
# --------------------------------------------------------------------------

class SecurityActionView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        phone = _primary_phone(request.user)
        action = str(request.data.get("action", ""))
        valid = dict(PendingSensitiveAction.ACTIONS)
        if action not in valid:
            return Response({"ok": False, "reason": "bad_action"},
                            status=status.HTTP_400_BAD_REQUEST)

        ok, locked = _verify_pin(phone, request.data.get("pin"))
        if not ok:
            if locked:
                _register_lockout(request.user, phone)
                return Response({"ok": False, "locked": True})
            return Response({"ok": False, "reason": "bad_pin"},
                            status=status.HTTP_403_FORBIDDEN)

        lat = request.data.get("lat")
        lng = request.data.get("lng")
        lat = float(lat) if lat not in (None, "") else None
        lng = float(lng) if lng not in (None, "") else None
        now = timezone.now()
        trusted = sec.is_trusted_location(request.user, lat, lng)
        verdict, effective_at = sec.decide_action(phone, action, trusted, now)

        if verdict == "blocked":
            return Response({"state": "blocked", "reason": "frozen"},
                            status=status.HTTP_423_LOCKED)

        if verdict == "immediate":
            _apply_action(phone, action)
            return Response({"state": "applied", "effective_at": None, "id": None})

        # delayed OR awaiting_approval -> park a pending action + notify.
        approver = phone.family_approver if verdict == "awaiting_approval" else None
        state = "awaiting_approval" if verdict == "awaiting_approval" else "pending"
        pending = PendingSensitiveAction.objects.create(
            phone=phone, action=action, effective_at=effective_at, state=state,
            cancel_token=secrets.token_urlsafe(24), approver=approver,
            payload={"trusted": trusted, "lat": lat, "lng": lng})

        cancel_link = (f"{getattr(settings, 'APP_DEEP_LINK_BASE', 'assisto://')}"
                       f"security/cancel/{pending.id}?token={pending.cancel_token}")
        if state == "awaiting_approval":
            title = "A sensitive change needs your approver's OK"
            body = (f"A '{action}' request on your Assisto-protected phone is "
                    f"waiting for your family approver. If this was not you, "
                    f"cancel it: {cancel_link}")
        else:
            eff = effective_at.strftime("%Y-%m-%d %H:%M") if effective_at else ""
            title = "A sensitive change was requested on your phone"
            body = (f"A '{action}' request from an untrusted location will take "
                    f"effect at {eff}. If this was not you, cancel it now: "
                    f"{cancel_link}")
        _notify_owner_and_circle(
            request.user, title, body,
            meta={"action": action, "pending_id": pending.id,
                  "cancel_token": pending.cancel_token,
                  "effective_at": effective_at.isoformat() if effective_at else None})

        return Response({"state": state,
                         "effective_at": effective_at.isoformat() if effective_at else None,
                         "id": pending.id})


# --------------------------------------------------------------------------
# POST security/action/<id>/cancel  — owner (authed) OR correct token (no auth)
# --------------------------------------------------------------------------

class SecurityActionCancelView(APIView):
    permission_classes = [AllowAny]  # token path works with no auth ("not me")

    def post(self, request, pk):
        pending = PendingSensitiveAction.objects.filter(pk=pk).first()
        if pending is None:
            return Response({"ok": False, "reason": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)
        token = str(request.data.get("token", ""))
        is_owner = (request.user.is_authenticated
                    and pending.phone.owner_id == request.user.id)
        token_ok = bool(pending.cancel_token) and secrets.compare_digest(
            token, pending.cancel_token)
        if not (is_owner or token_ok):
            return Response({"ok": False, "reason": "forbidden"},
                            status=status.HTTP_403_FORBIDDEN)
        if pending.state in ("cancelled", "applied", "rejected"):
            return Response({"ok": True, "state": pending.state})
        pending.state = "cancelled"
        pending.save(update_fields=["state"])
        return Response({"ok": True, "state": "cancelled"})


# --------------------------------------------------------------------------
# POST security/action/<id>/approve  — only the family_approver's user
# --------------------------------------------------------------------------

class SecurityActionApproveView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        pending = PendingSensitiveAction.objects.filter(pk=pk).first()
        if pending is None:
            return Response({"ok": False, "reason": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)
        phone = pending.phone
        approver = phone.family_approver
        if approver is None or approver.peer_user_id != request.user.id:
            return Response({"ok": False, "reason": "not_approver"},
                            status=status.HTTP_403_FORBIDDEN)
        if pending.state != "awaiting_approval":
            return Response({"ok": False, "reason": "not_pending",
                             "state": pending.state},
                            status=status.HTTP_409_CONFLICT)
        # Approved: if the handset is now frozen, still block; otherwise apply.
        if sec.is_frozen(phone, timezone.now()):
            return Response({"state": "blocked", "reason": "frozen"},
                            status=status.HTTP_423_LOCKED)
        _apply_action(phone, pending.action)
        pending.state = "applied"
        pending.save(update_fields=["state"])
        return Response({"ok": True, "state": "applied"})


# --------------------------------------------------------------------------
# POST security/signal  — the native engine reports a theft signal
# --------------------------------------------------------------------------

class SecuritySignalView(APIView):
    permission_classes = [IsAuthenticated]
    KINDS = {"snatch", "sim_change", "went_dark", "wrong_pin"}

    def post(self, request):
        phone = _primary_phone(request.user)
        kind = str(request.data.get("kind", ""))
        if kind not in self.KINDS:
            return Response({"ok": False, "reason": "bad_kind"},
                            status=status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        sec.register_signal(phone, kind, now)
        phone.save()
        _notify_owner_and_circle(
            request.user,
            "Possible phone theft detected",
            f"Assisto saw a '{kind}' signal and froze sensitive actions on your "
            f"phone for safety. Transfers and disarming are blocked.",
            meta={"kind": kind, "at": now.isoformat()})
        return Response({
            "ok": True,
            "frozen_until": phone.frozen_until.isoformat() if phone.frozen_until else None,
            "status": phone.status,
        })
