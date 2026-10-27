"""invite-join API (see core/invite_join.py for the rules).

  POST /circle/invite/code        {relation?, label?, max_uses?}   (auth)
       -> {ok, id, code, link, play_link, share_text, expires_at}
  GET  /circle/invite/sent                                          (auth)
       -> {results: [{id, code, link, label, status, joined, ...}]}
  POST /circle/invite/<id>/resend                                   (auth)
  POST /circle/invite/<id>/revoke                                   (auth)
  POST /invite/preview            {code}          (any)  -> {ok, state, inviter_name, ...}
  POST /invite/join               {code, via?}    (auth) -> {ok, member, inviter, already}
  POST /invite/signup             {code, name, phone?, email?, otp_proof?, via?,
                                   device_id?}    (any)  -> {token, user, member, inviter}
  POST /auth/set-password         {password}      (auth, only while none is set)

Every error: {ok:false, reason, detail} with a bilingual detail. Unknown,
revoked and malformed codes give the SAME "invalid" answer, and every one of
them counts toward a per-IP lock (no enumeration).
"""
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.db import transaction
from rest_framework import status
from rest_framework.authtoken.models import Token
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from . import invite_join as IJ
from . import otp
from .i18n import req_lang


def _err(request, reason, code=status.HTTP_400_BAD_REQUEST, **extra):
    lang = req_lang(request)
    body = {"ok": False, "reason": reason, "detail": IJ.message(reason, lang)}
    body.update(extra)
    return Response(body, status=code)


def _member_payload(mine, inviter, already):
    from .views_module5 import _member_dict
    return {"ok": True, "already": bool(already), "member": _member_dict(mine),
            "inviter": {"name": IJ.first_name(inviter)}}


def _lookup(request, raw):
    """(invite, error_response). Locks an IP that keeps trying unknown codes."""
    ip = otp.client_ip(request)
    if IJ.ip_locked(ip):
        return None, _err(request, "rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
    inv = IJ.find(raw)
    if inv is None or inv.revoked:
        IJ.note_bad(ip)
        return None, _err(request, "invalid", status.HTTP_404_NOT_FOUND, state="invalid")
    return inv, None


# ------------------------------------------------------------------ inviter
class InviteCodeCreateView(APIView):
    def post(self, request):
        lang = req_lang(request)
        if not IJ.create_rate_ok(request.user):
            return _err(request, "rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
        d = request.data or {}
        inv = IJ.create_invite(request.user, relation=str(d.get("relation") or "friend"),
                               max_uses=d.get("max_uses") or 1,
                               label=str(d.get("label") or ""))
        return Response({"ok": True, "id": inv.id, "code": inv.code,
                         "link": IJ.link_for(inv.code), "play_link": IJ.play_link(inv.code),
                         "share_text": IJ.share_text(request.user, inv.code, lang),
                         "max_uses": inv.max_uses,
                         "expires_at": inv.expires_at.isoformat()},
                        status=status.HTTP_201_CREATED)


class InviteSentView(APIView):
    def get(self, request):
        return Response({"results": IJ.sent_list(request.user, req_lang(request))})


class _OwnInvite(APIView):
    def _inv(self, request, pk):
        from .models import CircleInvite
        return CircleInvite.objects.filter(pk=pk, inviter=request.user,
                                           code__isnull=False).first()


class InviteResendView(_OwnInvite):
    def post(self, request, pk):
        inv = self._inv(request, pk)
        if inv is None or inv.revoked:
            return _err(request, "invalid", status.HTTP_404_NOT_FOUND)
        if inv.use_count >= inv.max_uses:
            return _err(request, "used", status.HTTP_409_CONFLICT)
        IJ.resend(inv)
        return Response({"ok": True, "id": inv.id, "link": IJ.link_for(inv.code),
                         "share_text": IJ.share_text(request.user, inv.code, req_lang(request)),
                         "expires_at": inv.expires_at.isoformat()})


class InviteRevokeView(_OwnInvite):
    def post(self, request, pk):
        inv = self._inv(request, pk)
        if inv is None:
            return _err(request, "invalid", status.HTTP_404_NOT_FOUND)
        inv.revoked = True
        inv.save(update_fields=["revoked"])
        return Response({"ok": True})


# ------------------------------------------------------------------ invitee
class InvitePreviewView(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        if not IJ.preview_rate_ok(otp.client_ip(request)):
            return _err(request, "rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
        inv, bad = _lookup(request, (request.data or {}).get("code"))
        if bad is not None:
            return bad
        out = IJ.preview(inv, req_lang(request), viewer=request.user)
        if not out["ok"]:
            out["reason"] = out["state"]
            out["detail"] = IJ.message(out["state"], req_lang(request))
        return Response(out)


class InviteJoinView(APIView):
    def post(self, request):
        if not IJ.join_rate_ok(request.user.id):
            return _err(request, "rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
        d = request.data or {}
        inv, bad = _lookup(request, d.get("code"))
        if bad is not None:
            return bad
        try:
            mine, inviter, already = IJ.join(inv, request.user,
                                             via=str(d.get("via") or "link"))
        except IJ.JoinError as e:
            return _err(request, e.reason, e.status)
        return Response(_member_payload(mine, inviter, already))


class InviteSignupView(APIView):
    """Create the account (NO password) and join in one step."""
    permission_classes = [AllowAny]

    def post(self, request):
        from .models import User
        from .phone import canonical_phone, variants
        d = request.data or {}
        ip = otp.client_ip(request)
        inv, bad = _lookup(request, d.get("code"))
        if bad is not None:
            return bad
        st = IJ.state_of(inv)
        if st != "ok":
            return _err(request, st, status.HTTP_410_GONE if st == "expired"
                        else status.HTTP_409_CONFLICT, state=st)
        name = str(d.get("name") or "").strip()[:120]
        if not name:
            return _err(request, "need_name")
        if not IJ.signup_rate_ok(ip):
            return _err(request, "rate_limited", status.HTTP_429_TOO_MANY_REQUESTS)
        phone_raw = str(d.get("phone") or "").strip()
        email = str(d.get("email") or "").strip().lower()[:254]
        proof = str(d.get("otp_proof") or "").strip()
        sms_on = otp.sms_available()
        canon = None
        verified = False
        if sms_on and (phone_raw or not email):
            # OTP-first: the code proves the number before we say anything
            # about it (no "is this number registered?" oracle).
            if not phone_raw:
                return _err(request, "need_phone")
            canon = otp.normalize_bd_phone(phone_raw)
            if not canon:
                return _err(request, "bad_phone")
            if not proof:
                return _err(request, "need_otp", status.HTTP_403_FORBIDDEN)
            if otp.consume_proof(proof, "signup", canon) is None:
                return _err(request, "bad_otp", status.HTTP_403_FORBIDDEN)
            verified = True
        else:
            # SMS off, or "SMS didn't come -> use email": the same trust level
            # as today's password sign-up (launch gate), plus a valid invite.
            if not otp.password_only_signup_allowed():
                return _err(request, "signup_closed", status.HTTP_403_FORBIDDEN)
            if not phone_raw and not email:
                return _err(request, "need_phone")
            if phone_raw:
                canon = canonical_phone(phone_raw)
                if not canon:
                    return _err(request, "bad_phone")
            if email and ("@" not in email or "." not in email.split("@")[-1]):
                return _err(request, "bad_email")
        if canon and User.objects.filter(phone__in=variants(canon)).exists():
            return _err(request, "has_account", status.HTTP_409_CONFLICT)
        if email and User.objects.filter(email=email).exists():
            return _err(request, "has_account", status.HTTP_409_CONFLICT)
        with transaction.atomic():
            user = User.objects.create_user(name=name, phone=canon or None,
                                            email=email or None, password=None)
            if verified:
                otp.mark_verified(user, canon)
            lang = req_lang(request)
            if lang in ("bn", "en") and getattr(user, "language", None) != lang:
                User.objects.filter(pk=user.pk).update(language=lang)
                user.language = lang
            try:
                mine, inviter, already = IJ.join(
                    inv, user, via=str(d.get("via") or "link"), new_account=True,
                    attribute=False)
            except IJ.JoinError as e:
                transaction.set_rollback(True)
                return _err(request, e.reason, e.status)
        # outside the atomic block: referral attribution uses its own rules
        IJ.attribute_referral(user, inviter, otp.device_id(request))
        token, _ = Token.objects.get_or_create(user=user)
        from . import plans
        try:
            if plans.trial_on_signup():
                plans.start_trial(user)
        except Exception:  # noqa: BLE001
            pass
        from .serializers import UserSerializer
        from .views import log
        log(user, "account.register", via="invite")
        body = _member_payload(mine, inviter, already)
        body.update({"token": token.key,
                     "user": UserSerializer(user, context={"request": request}).data,
                     "has_password": False, "phone_verified": verified})
        return Response(body, status=status.HTTP_201_CREATED)


class SetPasswordView(APIView):
    """A passwordless (invite) account adds a password so it can sign in on
    another phone. Refused once a password exists (use reset instead)."""

    def post(self, request):
        if request.user.has_usable_password():
            return _err(request, "has_password", status.HTTP_409_CONFLICT)
        pw = str((request.data or {}).get("password") or "")
        try:
            validate_password(pw, request.user)
        except ValidationError as e:
            return Response({"ok": False, "reason": "weak_password",
                             "detail": " ".join(e.messages)},
                            status=status.HTTP_400_BAD_REQUEST)
        request.user.set_password(pw)
        request.user.save(update_fields=["password"])
        return Response({"ok": True})


class PasswordStateView(APIView):
    def get(self, request):
        return Response({"has_password": request.user.has_usable_password()})
