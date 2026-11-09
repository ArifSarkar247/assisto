"""
Account & security HTTP surface (recovery, owner order Part 8).

Signed in:
  GET  account/security                      -> overview (phone, email, devices, nudge, requests)
  POST account/security/password             {current_password, new_password}
                                             -> {ok, token?}  (other devices signed out)
  POST account/security/devices/<sid>/signout
  POST account/security/devices/signout-others
  POST account/security/nudge                {action: later|added}
  POST account/security/recovery/<id>/cancel (the account owner: "this was not me")
  POST account/security/recovery/family/<id> {decision: confirm|deny}  (family member)

Public (no account token):
  POST auth/recovery/options                 {phone} -> {sms, email, email_masked, support}
  POST auth/recovery/support/start           {account_phone, contact_phone, contact_otp_proof,
                                              name, signup_year?, signup_month?,
                                              circle_names?[], old_password?, family_phone?}
                                             -> {ok, ref, secret, hold_until, hold_hours}
  POST auth/recovery/support/status          {ref, secret} -> {state, hold_until, ...}
  POST auth/recovery/support/complete        {ref, secret, otp_proof, password} -> {token, user}
  GET/POST account/not-me/<token>            the "This was not me" page (one button)
"""
from django.core.cache import cache
from django.http import HttpResponse
from django.utils import timezone
from django.utils.html import escape
from rest_framework import status
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.throttling import AnonRateThrottle
from rest_framework.views import APIView

from . import account_recovery as AR
from . import device_sessions as DS
from . import otp
from .i18n import pick, req_lang


class _RecoveryThrottle(AnonRateThrottle):
    scope = "recovery_public"
    rate = "20/hour"


def _fail(reason, lang, code, text=None, **extra):
    t = text or AR.msg(reason, lang)
    return Response({"ok": False, "reason": reason, "detail": t, "message": t, **extra},
                    status=code)


def _current_id(auth):
    if DS.is_session(auth):
        return "s%d" % auth.pk
    return "legacy" if auth is not None else ""


class AccountSecurityView(APIView):
    def get(self, request):
        u = request.user
        lang = req_lang(request)
        from .models import PhoneVerification
        pv = PhoneVerification.objects.filter(user=u).first()
        canon = otp.user_phone(u)
        ve = otp.verified_email(u)
        cur = (u.email or "").strip().lower()
        now = timezone.now()
        blk_e = AR.identity_block(u, "email", now)
        blk_p = AR.identity_block(u, "phone", now)
        return Response({
            "phone": u.phone or "",
            "phone_verified": bool(pv and canon and pv.phone == canon),
            "email": ve or cur,
            "email_verified": bool(ve) and (not cur or ve == cur),
            "email_enabled": otp.email_available(),
            "sms_enabled": otp.sms_available(),
            "has_password": u.has_usable_password(),
            # No Google sign-in exists in Assisto yet -> no button (honest).
            "google": {"available": False},
            "devices": DS.listing(u, request.auth, lang),
            "current_device": _current_id(request.auth),
            "nudge": AR.nudge(u, now),
            "email_change_blocked": blk_e[0] if blk_e else "",
            "phone_change_blocked": blk_p[0] if blk_p else "",
            "blocked_until": (blk_e or blk_p)[1].isoformat() if (blk_e or blk_p) else None,
            "recovery_requests": AR.open_for_owner(u),
            "family_requests": AR.open_for_family(u),
        })


class ChangePasswordView(APIView):
    """Change (or first set) the password. Signs out every OTHER device. A
    caller on the legacy single Token gets a fresh per-device token back."""

    def post(self, request):
        lang = req_lang(request)
        u = request.user
        d = request.data or {}
        new = str(d.get("new_password") or "")
        key = "acctsec:pw:%d" % u.pk
        if (cache.get(key) or 0) >= 5:
            return _fail("rate_limited", lang, status.HTTP_429_TOO_MANY_REQUESTS,
                         text=otp.message("rate_limited", lang))
        if u.has_usable_password() and not u.check_password(str(d.get("current_password") or "")):
            try:
                cache.set(key, (cache.get(key) or 0) + 1, 3600)
            except Exception:  # noqa: BLE001
                pass
            return _fail("wrong_password", lang, status.HTTP_400_BAD_REQUEST,
                         text=pick(lang, "এখনকার পাসওয়ার্ড মেলেনি।",
                                   "Your current password didn't match."))
        from . import reset as reset_logic
        ok_pw, pw_msg = reset_logic.validate_password(new, lang)
        if not ok_pw:
            return _fail("weak_password", lang, status.HTTP_400_BAD_REQUEST, text=pw_msg)
        if u.has_usable_password() and u.check_password(new):
            return _fail("same_password", lang, status.HTTP_400_BAD_REQUEST,
                         text=pick(lang, "নতুন পাসওয়ার্ড আগেরটার থেকে আলাদা হতে হবে।",
                                   "The new password must be different from the old one."))
        u.set_password(new)
        u.save(update_fields=["password"])
        AR.note_password_changed(u)
        out = {"ok": True,
               "message": pick(lang, "পাসওয়ার্ড বদলানো হয়েছে। বাকি সব ডিভাইস থেকে সাইন-আউট হয়েছে।",
                               "Password changed. Every other device was signed out.")}
        if DS.is_session(request.auth):
            n = DS.revoke_all(u, keep=request.auth, reason="password_changed")
        else:
            # legacy token = possibly shared by old builds: drop it, give THIS
            # device its own session so it stays signed in.
            n = DS.revoke_all(u, reason="password_changed")
            raw, _s = DS.create(u, request, reason="password_changed")
            out["token"] = raw
        out["signed_out"] = n
        AR._log(u, "account.password_changed", signed_out=n)
        return Response(out)


class DeviceSignOutView(APIView):
    def post(self, request, sid):
        lang = req_lang(request)
        r = DS.revoke_by_id(request.user, sid, request.auth)
        if r == "current":
            return _fail("current_device", lang, status.HTTP_400_BAD_REQUEST,
                         text=pick(lang, "এই ফোন থেকে বের হতে 'লগআউট' ব্যবহার করুন।",
                                   "Use 'Log out' to sign out of this phone."))
        if r != "ok":
            return _fail("not_found", lang, status.HTTP_404_NOT_FOUND,
                         text=pick(lang, "ডিভাইসটি আর তালিকায় নেই।", "That device is no longer listed."))
        AR._log(request.user, "account.device_signed_out", id=sid)
        return Response({"ok": True, "devices": DS.listing(request.user, request.auth)})


class DeviceSignOutOthersView(APIView):
    def post(self, request):
        u = request.user
        if DS.is_session(request.auth):
            n = DS.revoke_all(u, keep=request.auth, reason="signed_out_others")
            out = {"ok": True, "signed_out": n}
        else:
            n = DS.revoke_all(u, reason="signed_out_others")
            raw, _s = DS.create(u, request)
            out = {"ok": True, "signed_out": n, "token": raw}
        AR._log(u, "account.devices_signed_out_others", n=n)
        out["devices"] = DS.listing(u, DS.lookup(out["token"]) if "token" in out else request.auth)
        return Response(out)


class NudgeView(APIView):
    def post(self, request):
        action = str((request.data or {}).get("action") or "later")
        if action not in ("later", "added"):
            action = "later"
        return Response({"ok": True, "nudge": AR.nudge_seen(request.user, action)})


class OwnerCancelRecoveryView(APIView):
    def post(self, request, pk):
        lang = req_lang(request)
        if not AR.cancel_by_owner(request.user, pk):
            return _fail("not_found", lang, status.HTTP_404_NOT_FOUND)
        return Response({"ok": True, "message": pick(
            lang, "অনুরোধ বাতিল হয়েছে। আপনার অ্যাকাউন্ট নিরাপদ।",
            "Request cancelled. Your account is safe.")})


class FamilyDecideView(APIView):
    def post(self, request, pk):
        lang = req_lang(request)
        decision = str((request.data or {}).get("decision") or "")
        if not AR.family_decide(request.user, pk, decision):
            return _fail("not_found", lang, status.HTTP_404_NOT_FOUND)
        return Response({"ok": True, "message": pick(
            lang, "ধন্যবাদ। আপনার উত্তর রিভিউ দলের কাছে গেছে।",
            "Thank you. Your answer went to the review team.")})


# ------------------------------------------------------------------ public
class RecoveryOptionsView(APIView):
    permission_classes = [AllowAny]
    throttle_classes = [_RecoveryThrottle]

    def post(self, request):
        lang = req_lang(request)
        canon = otp.normalize_bd_phone((request.data or {}).get("phone"))
        if not canon:
            return _fail("bad_phone", lang, status.HTTP_400_BAD_REQUEST)
        return Response(AR.recovery_options(canon))


class SupportStartView(APIView):
    permission_classes = [AllowAny]
    throttle_classes = [_RecoveryThrottle]

    def post(self, request):
        lang = req_lang(request)
        d = dict(request.data or {})
        names = (request.data or {}).get("circle_names") or []
        d["circle_names"] = [str(n)[:80] for n in names][:3] if isinstance(names, list) else []
        try:
            row, raw = AR.start_request(d, request=request, lang=lang)
        except AR.RecoveryError as e:
            return _fail(e.reason, lang, e.status, **e.extra)
        return Response({"ok": True, "ref": row.ref, "secret": raw,
                         "hold_until": row.hold_until.isoformat(),
                         "hold_hours": AR.HOLD_HOURS, "message": AR.msg("sent", lang)},
                        status=status.HTTP_201_CREATED)


class SupportStatusView(APIView):
    permission_classes = [AllowAny]
    throttle_classes = [_RecoveryThrottle]

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        row = AR.by_secret(d.get("ref"), d.get("secret"))
        if row is None:
            return _fail("not_found", lang, status.HTTP_404_NOT_FOUND)
        return Response(AR.public_state(row))


class SupportCompleteView(APIView):
    permission_classes = [AllowAny]
    throttle_classes = [_RecoveryThrottle]

    def post(self, request):
        lang = req_lang(request)
        d = request.data or {}
        row = AR.by_secret(d.get("ref"), d.get("secret"))
        if row is None:
            return _fail("not_found", lang, status.HTTP_404_NOT_FOUND)
        try:
            user, token = AR.complete(row, d, request=request, lang=lang)
        except AR.RecoveryError as e:
            return _fail(e.reason, lang, e.status,
                         text=e.extra.get("message") or None)
        from .serializers import UserSerializer
        return Response({"ok": True, "token": token, "message": AR.msg("done", lang),
                         "user": UserSerializer(user, context={"request": request}).data})


_PAGE = """<!doctype html><html lang="{lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title>
<meta name="robots" content="noindex"><style>body{{font-family:system-ui,sans-serif;max-width:32rem;
margin:2rem auto;padding:0 1rem;line-height:1.6;color:#111;background:#fff}}button{{font-size:1.1rem;
min-height:48px;padding:0 1.5rem;border-radius:8px;border:0;background:#C62839;color:#fff}}
@media(prefers-color-scheme:dark){{body{{background:#111;color:#eee}}}}</style></head>
<body><h1>{title}</h1><p>{body}</p>{form}</body></html>"""


class NotMeView(APIView):
    """'This was not me' link from the alert. GET shows ONE button (link
    previews and mail scanners never undo anything); POST undoes + locks."""
    permission_classes = [AllowAny]
    authentication_classes = []
    throttle_classes = [_RecoveryThrottle]

    def _page(self, lang, title, body, form="", code=200):
        return HttpResponse(_PAGE.format(lang=lang, title=escape(title), body=escape(body),
                                         form=form), status=code,
                            content_type="text/html; charset=utf-8")

    def _lang(self, request):
        return "en" if request.GET.get("lang") == "en" else "bn"

    def get(self, request, token):
        lang = self._lang(request)
        ch = AR.find_undo(token)
        if ch is None or ch.undo_expires_at <= timezone.now():
            return self._page(lang, pick(lang, "লিংক ঠিক নয়", "Link not valid"),
                              pick(lang, "এই লিংকটি আর কাজ করে না। দরকার হলে Assisto সাপোর্টে যোগাযোগ করুন।",
                                   "This link no longer works. Contact Assisto support if you need help."),
                              code=404)
        if ch.undone_at:
            return self._done(lang)
        what = pick(lang, "ইমেইল" if ch.kind == "email" else "ফোন নম্বর",
                    "email" if ch.kind == "email" else "phone number")
        form = ('<form method="post"><button type="submit">%s</button></form>'
                % escape(pick(lang, "এটা আমি নই — বদল ফিরিয়ে দিন", "This was not me — undo it")))
        return self._page(lang, pick(lang, "আপনি কি এই বদল করেছেন?", "Did you make this change?"),
                          pick(lang,
                               "আপনার Assisto অ্যাকাউন্টের %s বদলানো হয়েছে। আপনি না করলে নিচে চাপুন: বদল ফিরে যাবে, "
                               "সব ফোন থেকে সাইন-আউট হবে, আর ৭ দিন ইমেইল/নম্বর বদল বন্ধ থাকবে।" % what,
                               "The %s on your Assisto account was changed. If it was not you, tap below: the "
                               "change is undone, every device is signed out and email/phone changes are "
                               "locked for 7 days." % what), form)

    def _done(self, lang):
        return self._page(lang, pick(lang, "বদল ফিরিয়ে দেওয়া হয়েছে", "Change undone"),
                          pick(lang, "সব ফোন থেকে সাইন-আউট করা হয়েছে। এখন 'পাসওয়ার্ড ভুলে গেছি' দিয়ে নতুন "
                                     "পাসওয়ার্ড দিন।",
                               "Every device was signed out. Now use 'Forgot password' to set a new password."))

    def post(self, request, token):
        lang = self._lang(request)
        ch = AR.find_undo(token)
        if ch is None:
            return self.get(request, token)
        r = AR.undo_change(ch)
        if r in ("ok", "done_already"):
            return self._done(lang)
        return self.get(request, token)
