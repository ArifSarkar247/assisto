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
    return bool(user is not None and
                getattr(user, "account_status", "active") in BLOCKED_STATUSES)


def blocked_message(lang):
    if lang == "en":
        return "This account is blocked. Please contact Assisto support."
    return "এই অ্যাকাউন্টটি বন্ধ করা হয়েছে। অনুগ্রহ করে Assisto সাপোর্টে যোগাযোগ করুন।"


class BlockAwareTokenAuthentication(TokenAuthentication):
    """DRF TokenAuthentication that refuses blocked accounts (401)."""

    def authenticate_credentials(self, key):
        user, token = super().authenticate_credentials(key)
        if is_blocked(user):
            raise exceptions.AuthenticationFailed("account_blocked")
        return user, token
