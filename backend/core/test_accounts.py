"""sjp0 (owner P0 9 Nov 19:40): tests, E2E, verify and seed tools NEVER use
the owner's real account or its quota — only dedicated test accounts.

refuse_real_account(user_or_phone) raises RealAccountRefused when the target
is a superuser / staff account (the owner) or one of the owner's phone
numbers. The owner numbers come from the server environment
(ASSISTO_OWNER_PHONES, comma separated) — never from the public repo."""
import os


class RealAccountRefused(Exception):
    pass


def _digits(p):
    d = "".join(ch for ch in str(p or "") if ch.isdigit())
    return d[-10:]          # 01XXXXXXXXX / +8801XXXXXXXXX -> the same 10 digits


def owner_phones():
    return {_digits(p) for p in os.environ.get("ASSISTO_OWNER_PHONES", "").split(",")
            if len(_digits(p)) == 10}


def is_real_owner(user=None, phone=None):
    if user is not None:
        if getattr(user, "is_superuser", False) or getattr(user, "is_staff", False):
            return True
        phone = phone or getattr(user, "phone", None)
    return bool(phone) and _digits(phone) in owner_phones()


def refuse_real_account(user=None, phone=None, tool=""):
    if is_real_owner(user, phone):
        raise RealAccountRefused(
            "%s refuses to run against the owner / a staff account — use a "
            "dedicated test account (owner rule 9 Nov)." % (tool or "this tool"))
