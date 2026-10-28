"""
OTP HTTP surface (o1-otp). All logic lives in core/otp.py; these views only
map requests → helper calls → honest, localized responses.

  GET  auth/otp/status            -> {sms_enabled, password_only_signup, code_length, expires_in, resend_in}
  POST auth/otp/request           {phone, purpose, device_id?}   (resend = same call; cooldown enforced)
  POST auth/otp/resend            alias of request
  POST auth/otp/verify            {phone, purpose, code}  -> {ok, otp_proof, expires_in}
  POST auth/otp/login             {phone, otp_proof}      -> {token, user}
  POST auth/otp/reset             {phone, otp_proof, password} -> {ok, message}

smsotp (email backup — same codes, same limits):
  POST auth/otp/email/request     {purpose, phone? | email?}  code by EMAIL
       login / password_reset: neutral answer whether or not the account (or
       its verified email) exists. delete_account / section8 / email_verify:
       signed in. Verify with auth/otp/verify ({phone, ...} or {email, ...}).
  POST auth/otp/email/confirm     {email, code}   (signed in) -> email verified
  GET  auth/otp/email/me          -> {email, verified, email_enabled}
  auth/otp/login and auth/otp/reset also accept {email, otp_proof}.

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
                     "sms_enabled": False,
                     # smsotp: the app offers "get the code by email" instead
                     "email_enabled": otp.email_available()},
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
    if purpose in otp.OWN_ACCOUNT_PURPOSES:
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
        if purpose not in otp.PURPOSES or purpose == "email_verify":
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
        neutral = purpose in ("login", "password_reset")
        try:
            out = otp.issue(canon, purpose, request=request,
                            user=_authed(request), lang=lang, send=send)
        except otp.OtpError as e:
            if e.reason == "sms_not_configured":
                return _sms_off(lang)
            if neutral and e.reason == "send_failed":
                # smsotp: a gateway failure only happens for a REAL account —
                # answer exactly like the unknown-number path (no enumeration);
                # the app always offers "send the code by email instead".
                out = {"ok": True, "sms_enabled": True, "purpose": purpose,
                       "phone_masked": otp.mask(canon),
                       "expires_in": otp.limits()["ttl_seconds"],
                       "resend_in": otp.limits()["resend_cooldown_seconds"],
                       "code_length": otp.CODE_LENGTH}
            else:
                return _err(e, lang)
        out["email_enabled"] = otp.email_available()
        out["message"] = otp.message("sent_neutral" if neutral else "sent", lang)
        return Response(out)


class OtpVerifyView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        lang = req_lang(request)
        purpose = str((request.data or {}).get("purpose") or "login").strip()
        if purpose not in otp.PURPOSES:
            return _fail("bad_purpose", lang, status.HTTP_400_BAD_REQUEST)
        data = request.data or {}
        email = str(data.get("email") or "").strip()
        if email and not str(data.get("phone") or "").strip() and \
                purpose in ("login", "password_reset", "email_verify"):
            if purpose == "email_verify" and _authed(request) is None:
                return _fail("auth_required", lang, status.HTTP_401_UNAUTHORIZED)
            try:   # smsotp: email-only identity
                proof = otp.verify(None, purpose, data.get("code"), email=email)
            except otp.OtpError as e:
                return _err(e, lang)
            return Response({"ok": True, "otp_proof": proof, "purpose": purpose,
                             "expires_in": otp.limits()["proof_ttl_seconds"]})
        canon, bad = _resolve_phone(request, purpose, lang)
        if bad is not None:
            return bad
        try:
            proof = otp.verify(canon, purpose, data.get("code"))
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
        user, row, bad = _proof_user(data, "login", lang, status.HTTP_401_UNAUTHORIZED)
        if bad is not None:
            return bad
        canon = row.phone
        from .account_block import is_blocked, blocked_message
        if is_blocked(user):   # o2-admin: blocked accounts cannot sign in
            return Response({"ok": False, "reason": "account_blocked",
                             "detail": blocked_message(lang)},
                            status=status.HTTP_403_FORBIDDEN)
        if canon and row.channel == "sms":   # only an SMS code proves the phone
            otp.mark_verified(user, canon)
        token, _ = Token.objects.get_or_create(user=user)
        _log(user, "account.login", method="otp", channel=row.channel)
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
        user, row, bad = _proof_user(data, "password_reset", lang,
                                     status.HTTP_400_BAD_REQUEST)
        if bad is not None:
            return bad
        user.set_password(pw)
        user.save(update_fields=["password"])
        Token.objects.filter(user=user).delete()
        if row.phone and row.channel == "sms":
            otp.mark_verified(user, row.phone)
        _log(user, "account.password_reset", method="otp", channel=row.channel)
        return Response({"ok": True, "message": reset_logic.confirm_message(lang, "ok")})


class _ProofInfo:
    __slots__ = ("phone", "channel", "email")

    def __init__(self, phone, channel, email):
        self.phone, self.channel, self.email = phone, channel, email


def _proof_user(data, purpose, lang, code):
    """(user, proof_row, None) or (None, None, error_response) for
    {phone|email, otp_proof}. The same 'bad_otp' answer for every failure."""
    phone = str(data.get("phone") or "").strip()
    email = str(data.get("email") or "").strip()
    if phone or not email:
        canon = otp.normalize_bd_phone(phone)
        if not canon:
            return None, None, _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
        res = otp.consume_proof(data.get("otp_proof"), purpose, canon, row=True)
        row = None
        if res:
            row = _ProofInfo(canon, getattr(res, "channel", "sms") or "sms",
                             getattr(res, "email", "") or "")
        user = otp.find_user_by_phone(canon) if row is not None else None
        # a phone proof delivered by email must still go to that verified address
        if row is not None and row.channel == "email" and user is not None and \
                otp.verified_email(user) != (row.email or ""):
            user = None
    else:
        row = otp.consume_proof_row(data.get("otp_proof"), purpose, email=email)
        user = otp.find_user_by_verified_email(row.email) if row is not None else None
    if row is None or user is None or not user.is_active:
        return None, None, _fail("bad_otp", lang, code)
    return user, row, None


class OtpEmailRequestView(APIView):
    """smsotp: send the code by EMAIL (backup when SMS fails / user choice).
    login / password_reset answer neutrally: the same 200 whether or not the
    account exists or has a verified email (no enumeration, no mail sent)."""
    permission_classes = [AllowAny]

    def post(self, request):
        from . import email_sender
        lang = req_lang(request)
        data = request.data or {}
        purpose = str(data.get("purpose") or "login").strip()
        if purpose not in otp.PURPOSES:
            return _fail("bad_purpose", lang, status.HTTP_400_BAD_REQUEST)
        if purpose not in otp.EMAIL_PURPOSES:
            return _fail("email_purpose_not_allowed", lang, status.HTTP_400_BAD_REQUEST)
        if not email_sender.configured():
            return Response({"ok": False, "reason": "email_not_configured",
                             "message": otp.message("email_not_configured", lang),
                             "email_enabled": False},
                            status=status.HTTP_503_SERVICE_UNAVAILABLE)
        user = _authed(request)
        raw_email = str(data.get("email") or "").strip()
        raw_phone = str(data.get("phone") or data.get("identifier") or "").strip()
        neutral = purpose in ("login", "password_reset")
        kw = {"request": request, "lang": lang}
        if purpose == "email_verify":
            if user is None:
                return _fail("auth_required", lang, status.HTTP_401_UNAUTHORIZED)
            addr = email_sender.normalize_email(raw_email)
            if not addr:
                return _fail("bad_email", lang, status.HTTP_400_BAD_REQUEST)
            # an address another account owns: same answer, nothing sent
            kw.update(email=addr, target=addr,
                      send=not otp.email_taken_by_other(user, addr))
        elif purpose in otp.OWN_ACCOUNT_PURPOSES:
            if user is None:
                return _fail("auth_required", lang, status.HTTP_401_UNAUTHORIZED)
            mine = otp.user_phone(user)
            if not mine:
                return _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
            tgt = otp.verified_email(user)
            if not tgt:
                return _fail("no_verified_email", lang, status.HTTP_400_BAD_REQUEST)
            kw.update(phone=mine, target=tgt)
        else:   # login / password_reset
            if raw_phone:
                canon = otp.normalize_bd_phone(raw_phone)
                if not canon:
                    return _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
                acct = otp.find_user_by_phone(canon)
                kw.update(phone=canon)
            else:
                addr = email_sender.normalize_email(raw_email)
                if not addr:
                    return _fail("bad_email", lang, status.HTTP_400_BAD_REQUEST)
                acct = otp.find_user_by_verified_email(addr)
                kw.update(email=addr)
            tgt = otp.verified_email(acct) if (acct is not None and acct.is_active) else ""
            kw.update(target=tgt, send=bool(tgt))
        try:
            out = otp.issue_email(purpose, **kw)
        except otp.OtpError as e:
            if neutral and e.reason == "send_failed":
                out = {"ok": True, "channel": "email", "purpose": purpose,
                       "email_enabled": True,
                       "expires_in": otp.limits()["ttl_seconds"],
                       "resend_in": otp.limits()["resend_cooldown_seconds"],
                       "code_length": otp.CODE_LENGTH, "prefer_sms": False}
            else:
                return _err(e, lang)
        if neutral:
            out.pop("email_masked", None)
            out["message"] = otp.message("sent_email_neutral", lang)
        else:
            out["message"] = otp.message("sent_email", lang)
        return Response(out)


class OtpEmailConfirmView(APIView):
    """smsotp: signed-in user proves an email address {email, code}."""

    def post(self, request):
        from . import email_sender
        lang = req_lang(request)
        data = request.data or {}
        addr = email_sender.normalize_email(data.get("email"))
        if not addr:
            return _fail("bad_email", lang, status.HTTP_400_BAD_REQUEST)
        try:
            proof = otp.verify(None, "email_verify", data.get("code"), email=addr)
        except otp.OtpError as e:
            return _err(e, lang)
        row = otp.consume_proof_row(proof, "email_verify", email=addr)
        if row is None or otp.email_taken_by_other(request.user, addr):
            return _fail("bad_otp", lang, status.HTTP_400_BAD_REQUEST)
        otp.mark_email_verified(request.user, addr)
        _log(request.user, "account.email_verified")
        return Response({"ok": True, "email": addr, "verified": True,
                         "message": otp.message("email_verified", lang)})


class OtpEmailMeView(APIView):
    """smsotp: the signed-in user's email + whether it is verified."""

    def get(self, request):
        v = otp.verified_email(request.user)
        cur = (request.user.email or "").strip().lower()
        return Response({"email": v or cur, "verified": bool(v) and (not cur or v == cur),
                         "email_enabled": otp.email_available()})


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
