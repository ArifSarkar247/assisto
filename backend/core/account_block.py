"""
Account block (o2-admin). A user whose `account_status` is "suspended" or
"banned" (set by moderation or the web owner panel /owner/users) may not sign
in and may not use the API with an old token. The field already existed
(msg_moderation); this module is the single place that enforces it.
"""
from rest_framework import exceptions
from rest_framework.authentication import TokenAuthentication

BLOCKED_STATUSES = ("suspended", "banned")


def is_blocked(user):
    if user is None:
        return False
    st = getattr(user, "account_status", "active")
    if st == "suspended":
        # adminsafe: a suspension for N days ends by itself
        try:
            from .admin_safety import expire_if_due
            if expire_if_due(user):
                return False
        except Exception:
            pass
    return st in BLOCKED_STATUSES


def blocked_payload(user, lang):
    """adminsafe: the 403 body for a blocked sign-in — the reason, the end
    date of a suspension and a short-lived appeal token, so the app can show
    the reason and send an appeal without a session."""
    body = {"reason": "account_blocked", "detail": blocked_message(lang)}
    try:
        from . import admin_safety as AS
        body["standing"] = AS.standing(user)
        body["appeal_token"] = AS.appeal_token(user)
    except Exception:
        pass
    return body


def blocked_message(lang):
    if lang == "en":
        return "This account is blocked. Please contact Assisto support."
    return "এই অ্যাকাউন্টটি বন্ধ করা হয়েছে। অনুগ্রহ করে Assisto সাপোর্টে যোগাযোগ করুন।"


class BlockAwareTokenAuthentication(TokenAuthentication):
    """DRF TokenAuthentication that refuses blocked accounts (401)."""

    def authenticate(self, request):
        res = super().authenticate(request)
        if res is not None:
            # own-device: a request FROM the user's protected phone (same
            # X-Device-Id as its engine) resolves a went-dark latch. Cheap
            # (no header -> nothing), never raises.
            try:
                from .own_device import touch as _own_touch
                _own_touch(request, res[0])
            except Exception:
                pass
        return res

    def authenticate_credentials(self, key):
        try:
            user, token = super().authenticate_credentials(key)
        except exceptions.AuthenticationFailed:
            # recovery: a per-device session key (new builds). The legacy
            # single Token (above) is unchanged for older builds.
            from .device_sessions import lookup
            sess = lookup(key)
            if sess is None:
                raise
            if not sess.user.is_active:
                raise exceptions.AuthenticationFailed("User inactive or deleted.")
            user, token = sess.user, sess
        if is_blocked(user):
            raise exceptions.AuthenticationFailed("account_blocked")
        # p5-growth: once a local day, mark the account active (retention +
        # referral activation). Never raises, one cheap check otherwise.
        try:
            from .growth import touch
            touch(user)
        except Exception:
            pass
        return user, token
