"""c1-contacts — THE one canonical phone helper (server side).

Every surface that accepts or compares a phone number goes through here:
register, login, profile phone change, OTP (core/otp.py), circle request,
invite, manual number search and contacts/match. The app mirrors the exact
same rules on device in app/lib/services/phone_canon.dart (keep them in
lockstep — tests on both sides pin the same examples).

Canonical form
--------------
* Bangladesh mobile numbers -> E.164 ``+8801XXXXXXXXX`` (13 chars).
  Accepted input: ``01XXXXXXXXX``, ``1XXXXXXXXX``, ``8801…``, ``+880…``,
  ``00880…``, ``+880 01…`` (a stray trunk 0 after the country code), with any
  spaces, dashes, dots or brackets, and Bangla digits (U+09E6..U+09EF).
  The operator digit must be 3-9 (013..019), like the OTP rule.
* Other countries are accepted ONLY when written explicitly international
  (``+<cc>…`` or ``00<cc>…``, 8..15 digits) -> ``+<digits>``. A stray trunk
  ``0`` after the country code is dropped for SA/AE/MY/GB/AU (TRUNK0_CC).
* Anything else is rejected honestly: ``canonical_phone`` returns ``None``.

Contact-match hashing contract (v1, served at GET /messenger/contacts/contract)
-------------------------------------------------------------------------------
``hash = hex(HMAC-SHA256(key=match_salt, msg=canonical_phone))[:32]``

``match_salt`` is ``settings.SERVER_MATCH_SALT`` when set, otherwise a value
DERIVED from SECRET_KEY (HMAC(SECRET_KEY, "assisto-contact-match-v1")) — the
SECRET_KEY itself is never handed out. The salt is given to signed-in clients
because the device must hash its own phonebook; it is not an auth secret. It
only stops a precomputed cross-service rainbow table. Phone numbers have low
entropy, so the real protections are: the server stores hashes ONLY for
registered users (UserPhoneHash), never for the uploaded phonebook, matching
needs a signed-in account, and lookups are rate-limited.
"""
import hashlib
import hmac
import re

from django.conf import settings

HASH_HEX_LEN = 32
SALT_VERSION = "v1"
_DERIVE_LABEL = b"assisto-contact-match-v1"

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_SEPARATORS = re.compile(r"[\s\-(). ​/]")
_BD_SUBSCRIBER = re.compile(r"^1[3-9]\d{8}$")
# probashi-otp: country codes whose NATIONAL trunk prefix is "0" and where a
# "0" right after the country code is never part of the number, so
# "+966 050 123 4567" / "+44 07700 900123" mean the same phone as without the
# 0 (a very common way expats and their families type it). Italy (+39) is
# deliberately NOT here: Italian landlines keep their leading 0 in E.164.
# E.164 country codes are prefix-free, so a plain startswith is unambiguous.
TRUNK0_CC = ("966", "971", "60", "44", "61")


def to_ascii_digits(raw):
    return str(raw or "").translate(_BN_DIGITS)


def canonical_phone(raw):
    """Return the canonical E.164 string, or None when it is not a number."""
    s = _SEPARATORS.sub("", to_ascii_digits(raw).strip())
    if not s:
        return None
    explicit_intl = False
    if s.startswith("+"):
        s, explicit_intl = s[1:], True
    elif s.startswith("00"):
        s, explicit_intl = s[2:], True
    if not s.isdigit():
        return None
    # --- Bangladesh -----------------------------------------------------
    bd = None
    if s.startswith("880"):
        bd = s[3:]
        if bd.startswith("0"):          # "+880 01XXXXXXXXX"
            bd = bd[1:]
    elif not explicit_intl:
        bd = s[1:] if s.startswith("0") else s
    if bd is not None:
        if _BD_SUBSCRIBER.match(bd):
            return "+880" + bd
        if s.startswith("880") or not explicit_intl:
            return None                  # a BD-looking number that is invalid
    # --- other countries: only when explicitly international ------------
    if explicit_intl:
        for cc in TRUNK0_CC:
            if s.startswith(cc + "0"):
                s = cc + s[len(cc) + 1:]
                break
    if explicit_intl and 8 <= len(s) <= 15 and s[0] != "0":
        return "+" + s
    return None


def canonical_bd(raw):
    """Bangladesh-only variant (OTP / SMS can only reach BD mobiles)."""
    c = canonical_phone(raw)
    return c if c and c.startswith("+8801") else None


def is_bd(canon):
    return bool(canon) and canon.startswith("+8801") and len(canon) == 14


def local_form(canon):
    """'+8801XXXXXXXXX' -> '01XXXXXXXXX'; other numbers unchanged."""
    return "0" + canon[4:] if is_bd(canon) else (canon or "")


def variants(canon):
    """Every legacy spelling a stored User.phone / CircleMember.phone may still
    carry for this canonical number (rows written before 0051). Lookups use
    ``phone__in=variants(c)`` so a not-yet-normalized row still matches."""
    if not canon:
        return []
    out = [canon, canon[1:]]
    if is_bd(canon):
        out += [local_form(canon), "+880" + local_form(canon),
                "880" + local_form(canon)]
    return list(dict.fromkeys(out))


def find_user(raw_or_canon):
    """The User owning this number in ANY input format, else None."""
    from .models import User
    c = canonical_phone(raw_or_canon)
    if not c:
        return None
    return User.objects.filter(phone__in=variants(c)).order_by("id").first()


def mask(canon):
    lf = local_form(canon)
    if len(lf) < 7:
        return lf
    return lf[:3] + "•" * (len(lf) - 6) + lf[-3:]


# ---------------------------------------------------------------- hashing
def match_salt():
    explicit = getattr(settings, "SERVER_MATCH_SALT", None)
    if explicit:
        return str(explicit)
    return hmac.new(str(settings.SECRET_KEY).encode("utf-8"), _DERIVE_LABEL,
                    hashlib.sha256).hexdigest()


def hash_canonical(canon, salt=None):
    if not canon:
        return ""
    key = (match_salt() if salt is None else salt).encode("utf-8")
    return hmac.new(key, canon.encode("utf-8"),
                    hashlib.sha256).hexdigest()[:HASH_HEX_LEN]


def hash_raw(raw, salt=None):
    return hash_canonical(canonical_phone(raw), salt)


def sync_phone_hash(user):
    """Create / update / remove the user's UserPhoneHash so it always matches
    their current User.phone. Never raises; returns the stored hash or ""."""
    try:
        from .models import UserPhoneHash
        canon = canonical_phone(getattr(user, "phone", "") or "")
        if not canon:
            UserPhoneHash.objects.filter(user=user).delete()
            return ""
        h = hash_canonical(canon)
        clash = UserPhoneHash.objects.filter(phone_hash=h).exclude(
            user_id=user.pk).first()
        if clash is not None:
            # Two accounts carry the same number (a legacy collision reported
            # by migration 0051). Never steal or merge; leave both untouched.
            return ""
        UserPhoneHash.objects.update_or_create(
            user=user, defaults={"phone_hash": h, "salt_version": SALT_VERSION})
        return h
    except Exception:  # noqa: BLE001
        return ""


# ------------------------------------------------------------ discoverable
def allow_unverified_matching():
    """Admin flag `contacts_match_unverified` (default ON for test builds):
    ON  -> every registered account with a phone can be found by number /
           contacts match;
    OFF -> only OTP-verified numbers (PhoneVerification.phone == User.phone)
           are discoverable. Turn OFF before public launch."""
    from . import billing
    return billing.flag_on("contacts_match_unverified", True)


def is_discoverable(user, allow_unverified=None):
    if user is None or not getattr(user, "is_active", False):
        return False
    canon = canonical_phone(getattr(user, "phone", "") or "")
    if not canon:
        return False
    if allow_unverified is None:
        allow_unverified = allow_unverified_matching()
    if allow_unverified:
        return True
    pv = getattr(user, "phone_verification", None)
    try:
        return bool(pv) and canonical_phone(pv.phone) == canon
    except Exception:  # noqa: BLE001
        return False
