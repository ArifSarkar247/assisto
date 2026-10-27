"""invite-join — "tap the link, type your name, you're in" (owner order 27 Oct,
BEST_IN_CLASS gap #7: ~15-20 taps + a password today vs ~6 on imo/WhatsApp).

The invite is a SHORT random code (10 chars of an unambiguous alphabet,
32^10 ≈ 10^15) on https://lifeassisto.com/i/<code>. Unlike the older signed
token (`<user id>.<rel>.<exp>.<nonce>.<sig>`) it carries NO user id, so a
link never reveals or lets anyone count accounts.

Rules
* expiry: `INVITE_TTL_DAYS` (7); resend extends it; revoke ends it.
* single use by default; `max_uses` up to MAX_USES_CAP for a "family group"
  link. A user who is ALREADY in the inviter's circle never burns a use.
* abuse: create ≤ CREATE_PER_DAY per inviter; preview/join lookups are
  rate-limited per IP and every UNKNOWN code counts toward a per-IP lock
  (BAD_PER_10MIN) — guessing codes is pointless and quickly stopped. Unknown,
  revoked and malformed codes all answer the same "invalid" shape.
* sign-up from an invite: NO password. SMS on -> a phone OTP proof is
  required (purpose "signup", the existing o1-otp flow). SMS off -> the same
  trust level as today's password sign-up (launch gate
  auth_password_only_signup) plus a valid invite; the account can add a
  password later (set_password) and phone-OTP sign-in works once SMS is on.
* attribution: CircleInviteJoin row; for a NEW account the inviter's p5
  referral code is claimed through growth.claim() — which applies every
  existing referral rule (device, phone, window, cap). Credit rules unchanged.
* circle full: an accepted-member cap (`limits.circle_max_members`, default
  CIRCLE_MAX_DEFAULT) on BOTH sides, read from the billing config.
"""
import logging
import secrets
import time
from datetime import timedelta

from django.core.cache import cache
from django.db import IntegrityError, transaction
from django.db.models import F
from django.utils import timezone

log = logging.getLogger(__name__)

CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no O/0/I/1
CODE_LEN = 10
INVITE_TTL_DAYS = 7
MAX_USES_CAP = 20
CREATE_PER_DAY = 40
PREVIEW_PER_MIN = 30          # per IP
JOIN_PER_HOUR = 20            # per user
SIGNUP_PER_HOUR = 6           # per IP
BAD_PER_10MIN = 20            # unknown codes per IP before a lock
CIRCLE_MAX_DEFAULT = 256
VIA = ("link", "referrer", "paste", "qr", "code")


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ------------------------------------------------------------------ codes
def normalize_code(raw):
    """Any of: CODE, code, https://…/i/CODE, /i/CODE?x — -> 'CODE' or ''."""
    s = str(raw or "").strip()
    if "/i/" in s:
        s = s.split("/i/", 1)[1]
    s = s.split("?", 1)[0].split("#", 1)[0].strip().strip("/").upper()
    if len(s) != CODE_LEN or any(c not in CODE_ALPHABET for c in s):
        return ""
    return s


def looks_like_code(raw):
    return bool(normalize_code(raw))


def _new_code():
    from .models import CircleInvite, User
    for _ in range(12):
        c = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
        if not CircleInvite.objects.filter(code=c).exists() and \
                not User.objects.filter(referral_code=c).exists():
            return c
    raise RuntimeError("could not allocate an invite code")


def base_url():
    from .views_m3_circle import invite_base
    return invite_base()


def link_for(code):
    return "%s/i/%s" % (base_url(), code)


def play_link(code):
    """Play listing carrying the code as the install referrer (`ci=<code>`);
    the app reads it once after install and opens "Join X's circle"."""
    from . import growth
    return "https://play.google.com/store/apps/details?id=%s&referrer=ci%%3D%s" % (
        growth.play_package(), code)


# ------------------------------------------------------------- rate limits
def _bump(key, window_s):
    k = "ij:%s:%d" % (key, int(time.time() // window_s))
    cache.add(k, 0, window_s + 30)
    try:
        return cache.incr(k)
    except ValueError:
        return 1


def _peek(key, window_s):
    return int(cache.get("ij:%s:%d" % (key, int(time.time() // window_s))) or 0)


def ip_locked(ip):
    return bool(ip) and _peek("bad:%s" % ip, 600) >= BAD_PER_10MIN


def note_bad(ip):
    if ip:
        _bump("bad:%s" % ip, 600)


def preview_rate_ok(ip):
    return _bump("pv:%s" % (ip or "-"), 60) <= PREVIEW_PER_MIN


def join_rate_ok(user_id):
    return _bump("jn:%s" % user_id, 3600) <= JOIN_PER_HOUR


def signup_rate_ok(ip):
    return _bump("su:%s" % (ip or "-"), 3600) <= SIGNUP_PER_HOUR


def create_rate_ok(user):
    from .models import CircleInvite
    since = timezone.now() - timedelta(hours=24)
    return CircleInvite.objects.filter(inviter=user, code__isnull=False,
                                       created_at__gte=since).count() < CREATE_PER_DAY


# ---------------------------------------------------------------- inviter
def first_name(user):
    n = (getattr(user, "name", "") or "").strip()
    return n.split()[0][:40] if n else ""


def share_text(inviter, code, lang="bn"):
    name = first_name(inviter)
    link = link_for(code)
    if lang == "en":
        who = ("%s invited you" % name) if name else "You're invited"
        return ("%s to My Circle on Assisto — chat, calls and family safety "
                "in one app. Tap to join:\n%s" % (who, link))
    who = ("%s আপনাকে" % name) if name else "আপনাকে"
    return ("%s Assisto-তে “আমার সার্কেল”-এ ডেকেছেন — চ্যাট, কল আর পরিবারের "
            "নিরাপত্তা এক অ্যাপে। যোগ দিতে ট্যাপ করুন:\n%s" % (who, link))


def create_invite(inviter, relation="friend", max_uses=1, label="", ttl_days=INVITE_TTL_DAYS):
    from .logic import circle
    from .models import CircleInvite
    try:
        mu = int(max_uses or 1)
    except (TypeError, ValueError):
        mu = 1
    mu = max(1, min(MAX_USES_CAP, mu))
    now = timezone.now()
    rel = circle.normalize_relation(relation or "friend")
    code = _new_code()
    return CircleInvite.objects.create(
        inviter=inviter, relation=rel, relation_code=rel, token=code, code=code,
        max_uses=mu, label=str(label or "").strip()[:60],
        expires_at=now + timedelta(days=ttl_days), last_sent_at=now)


def state_of(inv, now=None):
    now = now or timezone.now()
    if inv is None or inv.revoked:
        return "invalid"
    if inv.use_count >= inv.max_uses:
        return "used"
    if inv.expires_at and inv.expires_at <= now:
        return "expired"
    return "ok"


def resend(inv, ttl_days=INVITE_TTL_DAYS):
    """Extend a not-fully-used invite (also revives an expired one)."""
    now = timezone.now()
    inv.expires_at = now + timedelta(days=ttl_days)
    inv.last_sent_at = now
    inv.save(update_fields=["expires_at", "last_sent_at"])
    return inv


def sent_list(inviter, lang="bn", limit=50):
    """The inviter's code invites: joined (with names) / waiting / expired."""
    from .models import CircleInvite
    now = timezone.now()
    out = []
    qs = (CircleInvite.objects.filter(inviter=inviter, code__isnull=False, revoked=False)
          .prefetch_related("joins__user").order_by("-created_at")[:limit])
    for inv in qs:
        joined = [{"name": (j.user.name or "").strip(), "at": j.created_at.isoformat()}
                  for j in inv.joins.all()]
        st = state_of(inv, now)
        if st == "used":
            status = "joined"
        elif st == "ok":
            status = "waiting"      # may already list some joins (multi-use)
        else:
            status = "joined" if joined else "expired"
        out.append({
            "id": inv.id, "code": inv.code, "link": link_for(inv.code),
            "label": inv.label, "relation": inv.relation,
            "status": status, "state": st, "joined": joined,
            "uses": inv.use_count, "max_uses": inv.max_uses,
            "expires_at": inv.expires_at.isoformat() if inv.expires_at else None,
            "created_at": inv.created_at.isoformat(),
            "last_sent_at": inv.last_sent_at.isoformat() if inv.last_sent_at else None,
            "share_text": share_text(inviter, inv.code, lang),
        })
    return out


# ---------------------------------------------------------------- invitee
def find(code):
    from .models import CircleInvite
    c = normalize_code(code)
    if not c:
        return None
    return (CircleInvite.objects.select_related("inviter")
            .filter(code=c).first())


def circle_cap():
    try:
        from . import billing
        v = int(billing.cfg()["limits"].get("circle_max_members", CIRCLE_MAX_DEFAULT))
        return max(2, v)
    except Exception:  # noqa: BLE001
        return CIRCLE_MAX_DEFAULT


def accepted_count(user):
    from .models import CircleMember
    return CircleMember.objects.filter(user=user, state="accepted",
                                       peer_user__isnull=False).count()


def is_member(user, peer):
    from .models import CircleMember
    if user is None or peer is None:
        return False
    return CircleMember.objects.filter(user=user, peer_user=peer,
                                       state="accepted").exists()


def preview(inv, lang="bn", viewer=None):
    """What the join screen may show. Never the phone / email / user id."""
    from . import otp
    st = state_of(inv)
    out = {"ok": st == "ok", "state": st}
    try:
        email_on = bool(getattr(otp, "email_available", lambda: False)())
    except Exception:  # noqa: BLE001
        email_on = False
    out.update({"sms_enabled": otp.sms_available(),
                "email_enabled": email_on,
                "signup_open": otp.sms_available() or otp.password_only_signup_allowed()})
    if inv is None or st == "invalid":
        return out
    inviter = inv.inviter
    if not inviter.is_active or getattr(inviter, "account_status", "active") != "active":
        out.update(ok=False, state="invalid")
        return out
    name = first_name(inviter)
    out.update({"inviter_name": name,
                "inviter_initial": (name[:1] or "A"),
                "relation": inv.relation,
                "expires_at": inv.expires_at.isoformat() if inv.expires_at else None})
    if viewer is not None and getattr(viewer, "is_authenticated", False):
        if viewer.pk == inviter.pk:
            out.update(ok=False, state="self")
        elif is_member(viewer, inviter):
            out.update(state="already", ok=True)
    return out


class JoinError(Exception):
    def __init__(self, reason, status=400):
        super().__init__(reason)
        self.reason = reason
        self.status = status


MESSAGES = {
    "invalid": ("এই আমন্ত্রণ লিংকটি সঠিক নয়। যিনি পাঠিয়েছেন তার কাছে নতুন লিংক চেয়ে নিন।",
                "This invite link isn't valid. Ask the person who sent it for a new one."),
    "expired": ("এই আমন্ত্রণের মেয়াদ শেষ। যিনি পাঠিয়েছেন তাকে আবার পাঠাতে বলুন।",
                "This invite has expired. Ask them to send it again."),
    "used": ("এই আমন্ত্রণ আগেই ব্যবহার হয়েছে। নতুন লিংক চেয়ে নিন।",
             "This invite was already used. Ask for a new link."),
    "self": ("এটি আপনার নিজের আমন্ত্রণ — যাকে যোগ করতে চান তাকে পাঠান।",
             "This is your own invite — send it to the person you want to add."),
    "blocked": ("এই সংযোগটি করা যাচ্ছে না।", "This connection isn't possible."),
    "circle_full": ("সার্কেল পূর্ণ — এখন আর কাউকে যোগ করা যাচ্ছে না।",
                    "This circle is full — no one else can join right now."),
    "rate_limited": ("একটু বেশি চেষ্টা হয়েছে। কিছুক্ষণ পরে আবার চেষ্টা করুন।",
                     "Too many tries. Please try again in a little while."),
    "signup_closed": ("এখন অ্যাপে নতুন অ্যাকাউন্ট খোলা যাচ্ছে না। পরে আবার চেষ্টা করুন।",
                      "New accounts can't be created right now. Please try later."),
    "need_name": ("আপনার নাম লিখুন।", "Please type your name."),
    "need_phone": ("আপনার মোবাইল নম্বর দিন।", "Please enter your mobile number."),
    "bad_phone": ("মোবাইল নম্বরটি সঠিক নয়। যেমন: ০১৭১২৩৪৫৬৭৮",
                  "That mobile number doesn't look right. Example: 01712345678"),
    "bad_email": ("ইমেইলটি সঠিক নয়।", "That email doesn't look right."),
    "need_otp": ("আগে SMS-এ পাঠানো কোডটি দিন।", "Enter the code we sent by SMS first."),
    "bad_otp": ("কোডটি মেলেনি বা মেয়াদ শেষ — আবার কোড নিন।",
                "That code didn't match or has expired — get a new code."),
    "has_account": ("এই নম্বরে আগে থেকেই অ্যাকাউন্ট আছে — সাইন ইন করে লিংকটি আবার খুলুন।",
                    "This number already has an account — sign in, then open the link again."),
    "has_password": ("আপনার অ্যাকাউন্টে আগে থেকেই পাসওয়ার্ড আছে।",
                     "Your account already has a password."),
}


def message(reason, lang="bn"):
    bn, en = MESSAGES.get(reason, MESSAGES["invalid"])
    return pick(lang, bn, en)


def join(inv, user, via="link", new_account=False, device_id="", attribute=True):
    """Connect `user` to the inviter (both edges ACCEPTED). Returns
    (my_member_row, inviter, already). Raises JoinError."""
    from .logic import circle
    from .models import CircleInvite, CircleInviteJoin, CircleMember
    from .views_m3_circle import _edge
    st = state_of(inv)
    inviter = inv.inviter if inv is not None else None
    if inviter is None or st == "invalid" or not inviter.is_active or \
            getattr(inviter, "account_status", "active") != "active":
        raise JoinError("invalid")
    if inviter.pk == user.pk:
        raise JoinError("self")
    if CircleMember.objects.filter(user__in=(inviter, user),
                                   peer_user__in=(inviter, user),
                                   state="blocked").exists():
        raise JoinError("blocked", 403)
    already = is_member(user, inviter)
    if not already:
        if st != "ok":
            raise JoinError(st, 410 if st == "expired" else 409)
        cap = circle_cap()
        if accepted_count(inviter) >= cap or accepted_count(user) >= cap:
            raise JoinError("circle_full", 409)
    rel_inviter = circle.normalize_relation(inv.relation or "friend")
    via = via if via in VIA else "link"
    with transaction.atomic():
        if not already:
            # burn one use atomically (two people racing for the last use:
            # exactly one wins)
            n = CircleInvite.objects.filter(pk=inv.pk, revoked=False,
                                            use_count__lt=F("max_uses")).update(
                use_count=F("use_count") + 1)
            if not n:
                raise JoinError("used", 409)
            inv.refresh_from_db(fields=["use_count"])
            if inv.use_count >= inv.max_uses and not inv.used:
                CircleInvite.objects.filter(pk=inv.pk).update(used=True)
        _edge(inviter, user, "outgoing", rel_inviter)
        mine = _edge(user, inviter, "incoming", circle.reciprocal_relation(rel_inviter))
        try:
            with transaction.atomic():
                CircleInviteJoin.objects.create(invite=inv, user=user, via=via,
                                                new_account=bool(new_account))
        except IntegrityError:
            pass
    from . import connect_flow, e2_keys
    try:
        e2_keys.ensure_pair_keys(user, inviter)
    except Exception:  # noqa: BLE001 — keys self-heal on next open
        log.warning("invite-join: ensure_pair_keys failed", exc_info=True)
    if not already:
        try:
            connect_flow.on_connected(mine)
            mine.refresh_from_db()
        except Exception:  # noqa: BLE001 — the connection itself is done
            log.warning("invite-join: on_connected failed", exc_info=True)
    if new_account and attribute:
        attribute_referral(user, inviter, device_id)
    return mine, inviter, already


def attribute_referral(new_user, inviter, device_id=""):
    """A NEW account that came from a circle invite claims the inviter's p5
    referral code — growth.claim() decides (every existing rule applies;
    nothing is granted here, only on activation)."""
    try:
        from . import growth
        code = growth.ensure_code(inviter)
        return growth.claim(new_user, code, device_id=device_id or "")
    except Exception:  # noqa: BLE001 — attribution must never break a join
        log.warning("invite-join: referral claim failed", exc_info=True)
        return False, "error", None
