"""
OTP HTTP surface (o1-otp). All logic lives in core/otp.py; these views only
map requests → helper calls → honest, localized responses.

  GET  auth/otp/status            -> {sms_enabled, password_only_signup, code_length, expires_in, resend_in}
  POST auth/otp/request           {phone, purpose, device_id?}   (resend = same call; cooldown enforced)
  POST auth/otp/resend            alias of request
  POST auth/otp/verify            {phone, purpose, code}  -> {ok, otp_proof, expires_in}
  POST auth/otp/login             {phone, otp_proof}      -> {token, user}
  POST auth/otp/reset             {phone, otp_proof, password} -> {ok, message}

Sign-up (auth/register), account/delete/request and security/action accept
`otp_proof` directly (see their views).
"""
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import otp
from .i18n import req_lang, pick
from .models import AuditLog


def _log(user, action, **detail):
    try:
        AuditLog.objects.create(user=user, action=action, detail=detail)
    except Exception:  # noqa: BLE001
        pass


def _err(e, lang):
    return Response(e.body(lang), status=e.http_status)


def _sms_off(lang):
    # The SAME honest body the pre-OTP endpoint returned (app relies on it).
    return Response({"ok": False, "reason": "sms_not_configured",
                     "detail": otp.message("sms_not_configured", lang),
                     "message": otp.message("sms_not_configured", lang),
                     "sms_enabled": False},
                    status=status.HTTP_503_SERVICE_UNAVAILABLE)


def _fail(reason, lang, code, **extra):
    return Response({"ok": False, "reason": reason,
                     "message": otp.message(reason, lang), **extra}, status=code)


def _authed(request):
    u = getattr(request, "user", None)
    return u if (u is not None and u.is_authenticated) else None


def _resolve_phone(request, purpose, lang):
    """(canon, error_response). For own-account purposes the phone defaults to
    (and must equal) the signed-in user's number."""
    data = request.data or {}
    raw = str(data.get("phone") or data.get("identifier") or "").strip()
    user = _authed(request)
    if purpose in otp.AUTHED_PURPOSES and user is None:
        return None, _fail("auth_required", lang, status.HTTP_401_UNAUTHORIZED)
    if purpose in ("delete_account", "section8"):
        mine = otp.user_phone(user)
        if not mine:
            return None, _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
        if raw and otp.normalize_bd_phone(raw) != mine:
            return None, _fail("phone_mismatch", lang, status.HTTP_403_FORBIDDEN)
        return mine, None
    canon = otp.normalize_bd_phone(raw)
    if not canon:
        intl = _intl_no_sms(raw, lang)
        if intl is not None:
            return None, intl
        return None, _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
    return canon, None


def _intl_no_sms(raw, lang):
    """probashi-otp: a VALID non-Bangladesh number (+966, +971, +44, ...).
    Our SMS gateways reach Bangladeshi mobiles only, so instead of the
    misleading "enter a valid Bangladeshi number" say exactly that and point
    to the paths that DO work abroad: email code / password. No SMS is sent,
    so there is no international SMS cost and no SMS-pumping surface."""
    from .phone import canonical_phone
    c = canonical_phone(raw)
    if not c or c.startswith("+880"):
        return None
    msg = pick(lang,
               "SMS কোড শুধু বাংলাদেশের মোবাইল নম্বরে যায়। বিদেশি নম্বরে ইমেইলে কোড নিন, "
               "অথবা পাসওয়ার্ড দিয়ে ঢুকুন।",
               "SMS codes go only to Bangladeshi mobile numbers. With a number "
               "abroad, get the code by email or sign in with your password.")
    return Response({"ok": False, "reason": "intl_sms_unavailable", "message": msg,
                     "detail": msg, "intl": True, "use_email": True},
                    status=status.HTTP_400_BAD_REQUEST)


class OtpStatusView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        return Response(otp.public_status())


class OtpRequestView(APIView):
    """Issue (or re-issue) a code. Off-state is the honest 503 'SMS not
    configured' (never 501). Login / password_reset to an unknown number get
    the SAME neutral 200 without any SMS being sent (no enumeration, no cost)."""
    permission_classes = [AllowAny]

    def post(self, request):
        lang = req_lang(request)
        purpose = str((request.data or {}).get("purpose") or "login").strip()
        if purpose not in otp.PURPOSES:
            return _fail("bad_purpose", lang, status.HTTP_400_BAD_REQUEST)
        if not otp.sms_available():
            return _sms_off(lang)
        canon, bad = _resolve_phone(request, purpose, lang)
        if bad is not None:
            return bad
        existing = otp.find_user_by_phone(canon)
        send = True
        if purpose in ("signup", "change_number") and existing is not None:
            return _fail("already_registered", lang, status.HTTP_409_CONFLICT)
        if purpose in ("login", "password_reset"):
            send = bool(existing is not None and existing.is_active)
        try:
            out = otp.issue(canon, purpose, request=request,
                            user=_authed(request), lang=lang, send=send)
        except otp.OtpError as e:
            if e.reason == "sms_not_configured":
                return _sms_off(lang)
            return _err(e, lang)
        neutral = purpose in ("login", "password_reset")
        out["message"] = otp.message("sent_neutral" if neutral else "sent", lang)
        return Response(out)


class OtpVerifyView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        lang = req_lang(request)
        purpose = str((request.data or {}).get("purpose") or "login").strip()
        if purpose not in otp.PURPOSES:
            return _fail("bad_purpose", lang, status.HTTP_400_BAD_REQUEST)
        canon, bad = _resolve_phone(request, purpose, lang)
        if bad is not None:
            return bad
        try:
            proof = otp.verify(canon, purpose, (request.data or {}).get("code"))
        except otp.OtpError as e:
            return _err(e, lang)
        return Response({"ok": True, "otp_proof": proof, "purpose": purpose,
                         "expires_in": otp.limits()["proof_ttl_seconds"]})


class OtpLoginView(APIView):
    """Login by OTP. Password login (auth/login) is unchanged for everyone."""
    permission_classes = [AllowAny]

    def post(self, request):
        lang = req_lang(request)
        data = request.data or {}
        canon = otp.normalize_bd_phone(data.get("phone"))
        if not canon:
            return _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
        if otp.consume_proof(data.get("otp_proof"), "login", canon) is None:
            return _fail("bad_otp", lang, status.HTTP_401_UNAUTHORIZED)
        user = otp.find_user_by_phone(canon)
        if user is None or not user.is_active:
            return _fail("bad_otp", lang, status.HTTP_401_UNAUTHORIZED)
        from .account_block import is_blocked, blocked_message
        if is_blocked(user):   # o2-admin: blocked accounts cannot sign in
            return Response({"ok": False, "reason": "account_blocked",
                             "detail": blocked_message(lang)},
                            status=status.HTTP_403_FORBIDDEN)
        otp.mark_verified(user, canon)
        token, _ = Token.objects.get_or_create(user=user)
        _log(user, "account.login", method="otp")
        from .serializers import UserSerializer
        return Response({"token": token.key,
                         "user": UserSerializer(user, context={"request": request}).data})


class OtpResetView(APIView):
    """Forgot password by SMS: proof(password_reset) + new password. Signs the
    account out everywhere (all tokens dropped)."""
    permission_classes = [AllowAny]

    def post(self, request):
        from . import reset as reset_logic
        lang = req_lang(request)
        data = request.data or {}
        pw = str(data.get("password") or "")
        ok_pw, pw_msg = reset_logic.validate_password(pw, lang)
        if not ok_pw:
            return Response({"ok": False, "reason": "weak_password", "message": pw_msg},
                            status=status.HTTP_400_BAD_REQUEST)
        canon = otp.normalize_bd_phone(data.get("phone"))
        if not canon:
            return _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
        if otp.consume_proof(data.get("otp_proof"), "password_reset", canon) is None:
            return _fail("bad_otp", lang, status.HTTP_400_BAD_REQUEST)
        user = otp.find_user_by_phone(canon)
        if user is None or not user.is_active:
            return _fail("bad_otp", lang, status.HTTP_400_BAD_REQUEST)
        user.set_password(pw)
        user.save(update_fields=["password"])
        Token.objects.filter(user=user).delete()
        otp.mark_verified(user, canon)
        _log(user, "account.password_reset", method="otp")
        return Response({"ok": True, "message": reset_logic.confirm_message(lang, "ok")})


def signup_gate_response(lang):
    """403 body when the launch gate is CLOSED and no otp_proof was given."""
    return Response({"ok": False, "reason": "phone_verification_required",
                     "sms_enabled": otp.sms_available(),
                     "detail": pick(lang,
                                    "সাইন-আপ করতে ফোন নম্বর যাচাই করুন (SMS কোড)।",
                                    "Verify your phone number (SMS code) to sign up."),
                     "message": pick(lang,
                                     "সাইন-আপ করতে ফোন নম্বর যাচাই করুন (SMS কোড)।",
                                     "Verify your phone number (SMS code) to sign up.")},
                    status=status.HTTP_403_FORBIDDEN)
