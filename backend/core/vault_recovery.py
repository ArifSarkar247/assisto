"""vault100 — forgotten vault PIN: prove it is you, then the PHONE resets it.

How the vault is protected (read before changing anything here):
  * Documents (file + metadata) live on OUR server under the user's account,
    served only through auth-checked views (DocumentFileView, signed media).
    They are NOT end-to-end encrypted and the vault PIN is NOT a key: it is a
    device lock (salted hash kept only on the phone, core never sees it).
  * "Available offline" copies on the phone are sealed with a random
    per-install key in the app's encrypted sandbox store — also not derived
    from the PIN.
  => A forgotten PIN never makes a document unreadable, and resetting it does
     not weaken any encryption. What a reset MUST guarantee is that the person
     holding an unlocked phone is really the account owner.

Recovery flow (server side = verification only):
  GET  vault/recovery/status   which methods this account can use right now
                               (SMS code / email code / account password) +
                               the last reset time. No PIN data at all.
  POST vault/recovery/verify   {method: "otp", otp_proof}   (purpose vault_reset,
                               SMS to the account's own number or email to its
                               verified address — core/otp, all its limits)
                               {method: "password", password}
       -> {ok, reset_at}. The phone then deletes its local PIN hash and asks
          for a new PIN. The NEW PIN never comes here.

Guarantees (tested in tests_vault100):
  * any request carrying a PIN / recovery code / key field is REFUSED (400
    never_send_pin) so a buggy client can't leak one into logs;
  * password tries: MAX_PASSWORD_FAILS per hour per user, then 429 locked;
  * at most MAX_RESETS_PER_DAY successful resets per user per day;
  * every reset is in the user's audit log and pushed to all their devices
    ("your vault PIN was reset — not you? change your password").
"""
from datetime import timedelta

from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from . import otp
from .i18n import pick, req_lang
from .models import AuditLog

MAX_PASSWORD_FAILS = 5          # per user per rolling hour
MAX_RESETS_PER_DAY = 3          # successful resets per user per rolling 24 h
FORBIDDEN_KEYS = ("pin", "new_pin", "old_pin", "vault_pin", "pin_hash",
                  "recovery_code", "recovery_key", "key", "offline_key")

A_RESET = "vault.pin_reset"
A_FAIL = "vault.pin_reset_fail"

_MSG = {
    "never_send_pin": ("নিরাপত্তার জন্য PIN বা রিকভারি কোড কখনো সার্ভারে পাঠানো হয় না।",
                       "For your safety a PIN or recovery code is never sent to the server."),
    "bad_method": ("এই পদ্ধতি চেনা যায়নি।", "Unknown recovery method."),
    "bad_password": ("পাসওয়ার্ড মেলেনি।", "That password didn't match."),
    "no_password": ("এই অ্যাকাউন্টে পাসওয়ার্ড সেট করা নেই — কোড দিয়ে যাচাই করুন।",
                    "This account has no password set — verify with a code instead."),
    "locked": ("অনেকবার ভুল পাসওয়ার্ড। এক ঘণ্টা পরে আবার চেষ্টা করুন।",
               "Too many wrong passwords. Please try again in an hour."),
    "reset_cap": ("আজ অনেকবার PIN রিসেট হয়েছে। কাল আবার চেষ্টা করুন।",
                  "The vault PIN was reset too many times today. Please try tomorrow."),
    "bad_otp": ("যাচাই কোড সঠিক নয় বা মেয়াদ শেষ। আবার কোড চান।",
                "The verification is invalid or expired. Ask for a new code."),
    "verified": ("যাচাই হয়েছে। এখন নতুন PIN দিন।", "Verified. Now set a new PIN."),
}


def _m(key, lang):
    bn, en = _MSG[key]
    return pick(lang, bn, en)


def _fail(key, lang, code, **extra):
    return Response({"ok": False, "reason": key, "message": _m(key, lang), **extra},
                    status=code)


def _has_forbidden(data):
    try:
        keys = {str(k).lower() for k in (data or {}).keys()}
    except Exception:  # noqa: BLE001
        return False
    return any(k in keys for k in FORBIDDEN_KEYS)


def recovery_methods(user):
    phone = otp.user_phone(user)
    email = otp.verified_email(user) or ""
    sms = bool(phone) and otp.sms_available()
    em = bool(phone) and bool(email) and otp.email_available()
    pw = bool(user.has_usable_password())
    return {
        "sms": sms, "phone_masked": otp.mask(phone) if phone else "",
        "email": em, "email_masked": _mask_email(email) if em else "",
        "email_verified": bool(email),
        "password": pw,
        "any": sms or em or pw,
    }


def _mask_email(addr):
    if not addr or "@" not in addr:
        return ""
    name, dom = addr.split("@", 1)
    return (name[:1] + "•••" + "@" + dom) if name else ("•••@" + dom)


def _count(user, action, since):
    return AuditLog.objects.filter(user=user, action=action, created_at__gte=since).count()


def _notify(user, method):
    try:
        from . import push
        push.push_to_user(
            user, "reminder",
            "ভল্টের PIN রিসেট হয়েছে", "Your vault PIN was reset",
            "আপনি না করে থাকলে এখনই অ্যাকাউন্টের পাসওয়ার্ড বদলান।",
            "If this wasn't you, change your account password now.",
            data={"route": "vault", "event": "vault_pin_reset"})
    except Exception:  # noqa: BLE001
        pass


class VaultRecoveryStatusView(APIView):
    def get(self, request):
        u = request.user
        m = recovery_methods(u)
        last = (AuditLog.objects.filter(user=u, action=A_RESET)
                .order_by("-created_at").values_list("created_at", flat=True).first())
        day_ago = timezone.now() - timedelta(days=1)
        m.update({
            "ok": True,
            # honest model facts the app shows in "How your vault is protected"
            "end_to_end_encrypted": False,
            "pin_on_server": False,
            "last_reset_at": last.isoformat() if last else None,
            "resets_left_today": max(0, MAX_RESETS_PER_DAY - _count(u, A_RESET, day_ago)),
        })
        return Response(m)


class VaultRecoveryVerifyView(APIView):
    def post(self, request):
        lang = req_lang(request)
        u = request.user
        data = request.data or {}
        if _has_forbidden(data):
            return _fail("never_send_pin", lang, status.HTTP_400_BAD_REQUEST)
        method = str(data.get("method") or "").strip()
        if method not in ("otp", "password"):
            return _fail("bad_method", lang, status.HTTP_400_BAD_REQUEST)
        now = timezone.now()
        if _count(u, A_RESET, now - timedelta(days=1)) >= MAX_RESETS_PER_DAY:
            return _fail("reset_cap", lang, status.HTTP_429_TOO_MANY_REQUESTS,
                         retry_after=24 * 3600)
        if method == "password":
            hour_ago = now - timedelta(hours=1)
            fails = _count(u, A_FAIL, hour_ago)
            if fails >= MAX_PASSWORD_FAILS:
                return _fail("locked", lang, status.HTTP_429_TOO_MANY_REQUESTS,
                             retry_after=3600)
            if not u.has_usable_password():
                return _fail("no_password", lang, status.HTTP_400_BAD_REQUEST)
            if not u.check_password(str(data.get("password") or "")):
                AuditLog.objects.create(user=u, action=A_FAIL, detail={"method": "password"})
                left = max(0, MAX_PASSWORD_FAILS - fails - 1)
                return _fail("bad_password", lang, status.HTTP_403_FORBIDDEN,
                             attempts_left=left)
        else:
            proof = str(data.get("otp_proof") or "")
            row = otp.consume_proof_row(proof, "vault_reset", phone=otp.user_phone(u) or "x") \
                if proof else None
            if row is None:
                AuditLog.objects.create(user=u, action=A_FAIL, detail={"method": "otp"})
                return _fail("bad_otp", lang, status.HTTP_403_FORBIDDEN)
            method = "otp_" + (row.channel or "sms")
        AuditLog.objects.create(user=u, action=A_RESET, detail={"method": method})
        _notify(u, method)
        return Response({"ok": True, "method": method, "reset_at": now.isoformat(),
                         "message": _m("verified", lang)})
