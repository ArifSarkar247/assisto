"""
Secure "Delete my profile & all data" — Play-Store-compliant account deletion.

Deleting the whole account is treated as a SENSITIVE ACTION under Section 8
(Stolen-While-Unlocked Protection). The same rules apply:

  * require the Assisto Security PIN when one is set (the native app layers a
    biometric check on top before it ever calls this);
  * a 24h delay OUTSIDE a trusted place so the real owner can react;
  * BLOCKED while any theft signal is active in the last 7 days — a thief who
    just snatched an unlocked phone can NEVER wipe the owner's account;
  * an instant notice to the owner + every trusted contact carrying a one-tap
    "Cancel — this wasn't me" token.

On top of that we add a 7-DAY GRACE period (Play-compliant: the account stays
fully recoverable until effective_at). The account is NOT touched here — only
the purge_deletions management command (cron), running after effective_at on a
still-pending request, performs the real, complete, cascading hard delete.

Auth reuse:
  * password      -> user.check_password (Django).
  * OTP           -> o1-otp: a single-use `otp_proof` (purpose=delete_account,
    bound to the user's own phone) from auth/otp/verify. Required whenever the
    SMS gateway is CONNECTED and the user has a BD mobile (core/otp.py
    otp_required_for). With SMS not configured no code can be sent, so OTP
    degrades honestly to password + PIN (same as before).
  * Security PIN  -> views_security._verify_pin against the primary ProtectedPhone.
"""
import secrets

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from rest_framework import status
from rest_framework.permissions import IsAuthenticated, AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from datetime import timedelta

from .models import (AccountDeletionRequest, ProtectedPhone, AuditLog)
from .logic import security as sec
from .views_security import _primary_phone, _verify_pin, _notify_owner_and_circle

GRACE_DAYS = 7


def _log(user, action, **detail):
    AuditLog.objects.create(user=user, action=action, detail=detail)


# --------------------------------------------------------------------------
# what will be deleted — counts per data type (best-effort over the user's
# reverse relations; cheap and never raises).
# --------------------------------------------------------------------------

def _deletion_counts(user):
    counts = {}
    for rel in user._meta.related_objects:
        # Reverse relations (FK/O2O/M2M pointing AT the user). On hard delete
        # every CASCADE child goes with the user; SET_NULL ones are detached.
        name = rel.get_accessor_name()
        try:
            mgr = getattr(user, name)
            counts[name] = mgr.count()
        except Exception:
            continue
    # Drop zero-count rows to keep the preview readable.
    return {k: v for k, v in counts.items() if v}


def _otp_gate(user, proof):
    """o1-otp: (ok, reason). Proof is consumed (single use) only when required."""
    from . import otp as otp_mod
    if not otp_mod.otp_required_for(user):
        return True, None
    proof = str(proof or "").strip()
    if not proof:
        return False, "otp_required"
    if otp_mod.consume_proof(proof, "delete_account", user.phone) is None:
        return False, "bad_otp"
    return True, None


# --------------------------------------------------------------------------
# POST account/delete/preview  — what WILL be deleted; no side effects.
# --------------------------------------------------------------------------

class AccountDeletePreviewView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user
        req = getattr(user, "deletion_request", None)
        existing = None
        if req and req.state == AccountDeletionRequest.STATE_PENDING:
            existing = {"state": req.state,
                        "effective_at": req.effective_at.isoformat()}
        return Response({
            "counts": _deletion_counts(user),
            "export_first": True,
            "export_url": "export",   # GET export | export/excel | export/pdf
            "export_downloaded": bool(req.export_downloaded) if req else False,
            "reminder": ("Download your data first — deletion is permanent after "
                         "the 7-day grace period."),
            "grace_days": GRACE_DAYS,
            "existing_request": existing,
        })


# --------------------------------------------------------------------------
# POST account/delete/request  — schedule a deletion (Section-8 gated).
# --------------------------------------------------------------------------

class AccountDeleteRequestView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user

        # 1) password (always required)
        if not user.check_password(str(request.data.get("password", ""))):
            return Response({"ok": False, "reason": "bad_password"},
                            status=status.HTTP_403_FORBIDDEN)

        # 2) Security PIN — required ONLY when the user has set one.
        phone = _primary_phone(user, create=False)
        if phone and phone.security_pin_hash:
            ok, locked = _verify_pin(phone, request.data.get("security_pin"))
            if not ok:
                return Response({"ok": False, "reason": "locked" if locked else "bad_pin"},
                                status=status.HTTP_403_FORBIDDEN)

        # 3) OTP proof (o1-otp) — required when SMS is connected; checked after
        #    password + PIN so a wrong PIN doesn't burn the single-use proof.
        ok_otp, why = _otp_gate(user, request.data.get("otp_proof"))
        if not ok_otp:
            return Response({"ok": False, "reason": why, "purpose": "delete_account"},
                            status=status.HTTP_403_FORBIDDEN)

        now = timezone.now()

        # 4) theft gate — a thief must not be able to delete the owner's data.
        if phone and (sec.recent_theft_signal(phone, now, days=7)
                      or sec.is_frozen(phone, now)):
            return Response({"state": "blocked", "reason": "theft_signal"},
                            status=status.HTTP_423_LOCKED)

        # 5) location -> Section-8 24h delay when untrusted.
        lat = request.data.get("lat")
        lng = request.data.get("lng")
        lat = float(lat) if lat not in (None, "") else None
        lng = float(lng) if lng not in (None, "") else None
        trusted = sec.is_trusted_location(user, lat, lng)
        section8_at = now if trusted else now + timedelta(hours=sec.DELAY_HOURS)

        # effective_at never shortens either protection.
        effective_at = max(now + timedelta(days=GRACE_DAYS), section8_at)

        token = secrets.token_urlsafe(24)
        with transaction.atomic():
            req, _created = AccountDeletionRequest.objects.update_or_create(
                user=user,
                defaults={
                    "requested_at": now,
                    "effective_at": effective_at,
                    "state": AccountDeletionRequest.STATE_PENDING,
                    "cancel_token": token,
                    "reason": str(request.data.get("reason", "")),
                },
            )

        eff = effective_at.strftime("%Y-%m-%d %H:%M")
        cancel_link = (f"{getattr(settings, 'APP_DEEP_LINK_BASE', 'assisto://')}"
                       f"account/delete/cancel?token={token}")
        _notify_owner_and_circle(
            user,
            "Account deletion scheduled",
            (f"A request to delete this Assisto account and ALL its data was made. "
             f"It will take effect on {eff}. If this was NOT you, cancel it now: "
             f"{cancel_link}"),
            kind="security", ntype="security", route="account/delete",
            meta={"effective_at": effective_at.isoformat(),
                  "cancel_token": token, "request_id": req.id})

        _log(user, "account.delete.request",
             effective_at=effective_at.isoformat(), trusted=trusted,
             request_id=req.id)

        return Response({"state": req.state,
                         "effective_at": effective_at.isoformat(),
                         "id": req.id})


# --------------------------------------------------------------------------
# POST account/delete/cancel  — owner (authed) OR correct token ("not me").
# --------------------------------------------------------------------------

class AccountDeleteCancelView(APIView):
    permission_classes = [AllowAny]   # token path works with no auth

    def post(self, request):
        token = str(request.data.get("token", ""))
        req = None
        if request.user and request.user.is_authenticated:
            req = AccountDeletionRequest.objects.filter(user=request.user).first()
        if req is None and token:
            req = AccountDeletionRequest.objects.filter(cancel_token=token).first()

        if req is None:
            return Response({"ok": False, "reason": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)

        is_owner = (request.user and request.user.is_authenticated
                    and req.user_id == request.user.id)
        token_ok = bool(req.cancel_token) and bool(token) and \
            secrets.compare_digest(token, req.cancel_token)
        if not (is_owner or token_ok):
            return Response({"ok": False, "reason": "forbidden"},
                            status=status.HTTP_403_FORBIDDEN)

        if req.state != AccountDeletionRequest.STATE_PENDING:
            return Response({"ok": True, "state": req.state})

        req.state = AccountDeletionRequest.STATE_CANCELLED
        req.save(update_fields=["state"])
        _log(req.user, "account.delete.cancel", request_id=req.id,
             by="owner" if is_owner else "token")
        return Response({"ok": True, "state": "cancelled"})


# --------------------------------------------------------------------------
# GET account/delete/status  — current request or none.
# --------------------------------------------------------------------------

class AccountDeleteStatusView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        req = getattr(request.user, "deletion_request", None)
        if req is None:
            return Response({"state": None})
        return Response({
            "state": req.state,
            "effective_at": req.effective_at.isoformat() if req.effective_at else None,
            "export_downloaded": req.export_downloaded,
        })
