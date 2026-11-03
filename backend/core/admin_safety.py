"""
adminsafe (owner 3 Nov 04:22): account actions, restrictions, bans, appeals
and the 'likely uninstalled' signal. The Owner Admin pages (web/owner/
views_safety.py) and the app endpoints (core/views_safety.py) both call
these functions; nothing here reads message, call, vault, photo, camera or
location content.

Actions (every one needs a reason; the reason is shown to the user):
  warn            notice only
  restrict        stranger_msg / channel_post / community_join, optional N days
  unrestrict      lift restrictions
  suspend         N days (1-365): account blocked, all sessions revoked,
                  auto-expires at the end (lazy, on the next auth / stats run)
  ban             permanent: blocked, sessions revoked, the phone and email
                  (Google account) hashed into BannedIdentity -> sign-up refused
  unblock         back to active, ban identities lifted
  force_logout    every token / linked device / panel session revoked
  remove_content  the user's REPORTED public content (channel posts with an
                  open report, train-chat messages) is removed
"""
import hashlib
import hmac
from datetime import timedelta

from django.conf import settings
from django.core import signing
from django.db import transaction
from django.utils import timezone

RESTRICT_KINDS = ("stranger_msg", "channel_post", "community_join")
ACTIONS = ("warn", "restrict", "unrestrict", "suspend", "ban", "unblock",
           "force_logout", "remove_content")
APPEALABLE = ("warn", "restrict", "suspend", "ban", "remove_content")
SUSPEND_MAX_DAYS = 365
RESTRICT_MAX_DAYS = 365
APPEAL_MIN, APPEAL_MAX = 10, 1000
APPEAL_TOKEN_DAYS = 7
_SALT = "adminsafe-appeal-v1"


class ActionError(ValueError):
    """code is an i18n key of the owner panel (as_err_*)."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


# ------------------------------------------------------------ identity hash
def _norm(kind, value):
    v = str(value or "").strip()
    if not v:
        return ""
    if kind == "phone":
        try:
            from .phone import canonical_phone
            return canonical_phone(v) or ""
        except Exception:
            return "".join(ch for ch in v if ch.isdigit())
    return v.lower()


def ident_hash(kind, value):
    """Keyed HMAC-SHA256 of a normalised phone / email ('' when empty).
    The plain value is never stored."""
    n = _norm(kind, value)
    if not n:
        return ""
    key = ("adminsafe-ban:%s:%s" % (kind, settings.SECRET_KEY)).encode()
    return hmac.new(key, n.encode(), hashlib.sha256).hexdigest()


def banned_identity(phone=None, email=None):
    """True when this phone or email belongs to a permanently banned account."""
    from .models import BannedIdentity
    hashes = [(k, ident_hash(k, v)) for k, v in (("phone", phone), ("email", email))]
    for kind, h in hashes:
        if h and BannedIdentity.objects.filter(kind=kind, value_hash=h,
                                               lifted_at__isnull=True).exists():
            return True
    return False


def banned_message(lang):
    if lang == "en":
        return ("Sign-up is not possible with this phone number or email "
                "because an account using it was banned.")
    return ("এই ফোন নম্বর বা ইমেইল দিয়ে নতুন অ্যাকাউন্ট খোলা যাবে না, কারণ এটি "
            "দিয়ে খোলা একটি অ্যাকাউন্ট নিষিদ্ধ করা হয়েছে।")


# ------------------------------------------------------------- restrictions
def _active_q(now=None):
    from django.db.models import Q
    now = now or timezone.now()
    return Q(lifted_at__isnull=True) & (Q(until__isnull=True) | Q(until__gt=now))


def active_restrictions(user):
    from .models import UserRestriction
    if user is None or not getattr(user, "pk", None):
        return UserRestriction.objects.none()
    return UserRestriction.objects.filter(_active_q(), user_id=user.pk)


def restricted(user, kind):
    """The active UserRestriction of this kind for `user`, else None."""
    try:
        return active_restrictions(user).filter(kind=kind).select_related(
            "action").order_by("-created_at").first()
    except Exception:
        return None


_DENY = {
    "stranger_msg": ("নতুন মানুষকে মেসেজ পাঠানো আপনার অ্যাকাউন্টে সাময়িকভাবে বন্ধ আছে।",
                     "Messaging people you are not connected with is limited on your account."),
    "channel_post": ("চ্যানেলে পোস্ট করা আপনার অ্যাকাউন্টে সাময়িকভাবে বন্ধ আছে।",
                     "Posting in channels is limited on your account."),
    "community_join": ("কমিউনিটিতে যোগ দেওয়া আপনার অ্যাকাউন্টে সাময়িকভাবে বন্ধ আছে।",
                       "Joining communities is limited on your account."),
}


def deny_response(request, row):
    """403 {detail: 'account_restricted', kind, reason, until, message}.
    The app shows `message` and can open Account status (route
    account_standing) where the reason and the appeal button are."""
    from rest_framework import status
    from rest_framework.response import Response
    from .i18n import req_lang
    lang = req_lang(request)
    bn, en = _DENY.get(row.kind, _DENY["stranger_msg"])
    reason = row.action.reason if row.action_id and row.action else ""
    msg = en if lang == "en" else bn
    # `detail` is the human sentence (every app build shows `detail` as the
    # error text); `reason` is the machine code.
    return Response({"detail": msg, "reason": "account_restricted",
                     "kind": row.kind, "until": row.until.isoformat() if row.until else None,
                     "admin_reason": reason, "route": "account_standing",
                     "message": msg},
                    status=status.HTTP_403_FORBIDDEN)


def gate(request, kind):
    """None when allowed, else the 403 Response. Never raises."""
    try:
        row = restricted(request.user, kind)
    except Exception:
        row = None
    return deny_response(request, row) if row is not None else None


# ----------------------------------------------------------------- sessions
def revoke_sessions(user):
    """Force logout on every device: API tokens, linked devices, pending link
    tokens, Owner Admin sessions and push registrations (re-made on login)."""
    from rest_framework.authtoken.models import Token
    from .models import Device, DeviceLinkToken, LinkedDevice, OwnerSession
    n = {"tokens": Token.objects.filter(user=user).delete()[0]}
    n["linked"] = LinkedDevice.objects.filter(user=user, revoked=False).update(revoked=True)
    n["link_tokens"] = DeviceLinkToken.objects.filter(user=user).delete()[0]
    n["panel"] = OwnerSession.objects.filter(user=user).delete()[0]
    n["push"] = Device.objects.filter(user=user).delete()[0]
    return n


# ------------------------------------------------------------ suspend expiry
def _suspend_end(user):
    from .models import AccountAction
    a = (AccountAction.objects.filter(user_id=user.pk, kind__in=("suspend", "ban", "unblock"))
         .order_by("-created_at", "-id").first())
    if a is None or a.kind != "suspend":
        return None
    return a.until


def expire_if_due(user, now=None):
    """A suspension whose end passed -> active again (recorded as an
    automatic 'unblock'). Returns True when it changed the account."""
    from .models import AccountAction, User
    try:
        if getattr(user, "account_status", "") != "suspended":
            return False
        now = now or timezone.now()
        end = _suspend_end(user)
        if end is None or end > now:
            return False
        n = User.objects.filter(pk=user.pk, account_status="suspended").update(
            account_status="active")
        user.account_status = "active"
        if n:
            AccountAction.objects.create(user_id=user.pk, kind="unblock",
                                         reason="suspension ended",
                                         detail={"auto": True})
        return bool(n)
    except Exception:
        return False


def sweep_expired(now=None):
    """Expire every due suspension (used before counting)."""
    from .models import User
    n = 0
    for u in User.objects.filter(account_status="suspended").only("id", "account_status")[:2000]:
        n += 1 if expire_if_due(u, now) else 0
    return n


# ------------------------------------------------------------------- notice
_NOTICE = {
    "warn": ("Assisto থেকে সতর্কবার্তা", "A warning from Assisto"),
    "restrict": ("আপনার অ্যাকাউন্টে কিছু সুবিধা সীমিত করা হয়েছে",
                 "Some features are limited on your account"),
    "unrestrict": ("আপনার অ্যাকাউন্টের সীমা তুলে নেওয়া হয়েছে",
                   "The limits on your account were lifted"),
    "force_logout": ("নিরাপত্তার জন্য সব ডিভাইস থেকে সাইন-আউট করা হয়েছে",
                     "You were signed out on all devices for safety"),
    "remove_content": ("রিপোর্ট হওয়া আপনার একটি কনটেন্ট সরানো হয়েছে",
                       "Reported content of yours was removed"),
    "unblock": ("আপনার অ্যাকাউন্ট আবার চালু হয়েছে", "Your account is active again"),
}


def _notify(user, action):
    """In-app notice (notification centre, opens Account status). Suspend /
    ban are shown at sign-in instead (the account cannot open the app)."""
    if action.kind not in _NOTICE:
        return
    from .models import NotifEvent
    tbn, ten = _NOTICE[action.kind]
    try:
        NotifEvent.objects.create(
            user=user, type="security", title_bn=tbn, title_en=ten,
            body_bn="কারণ: %s" % action.reason, body_en="Reason: %s" % action.reason,
            route="account_standing",
            meta={"kind": "account_action", "action_id": action.id})
    except Exception:
        pass


# ----------------------------------------------------------------- content
def remove_reported_content(user, actor, reason):
    """Remove ONLY this user's content that someone reported: channel posts
    with a report item, and their train-chat messages when a person report
    exists. Returns counts."""
    from .logic import msg_moderation as mmod
    from .models import ChannelPost, ModerationAudit, ModerationItem
    out = {"posts": 0, "train_messages": 0}
    post_ids = [str(i) for i in ChannelPost.objects.filter(author=user)
                .values_list("id", flat=True)]
    items = list(ModerationItem.objects.filter(target_kind="post", target_id__in=post_ids)
                 .exclude(content_status="removed"))
    for it in items:
        new_item, audit = mmod.apply_admin_action(
            {"id": it.id, "target_kind": it.target_kind, "target_id": it.target_id,
             "content_status": it.content_status, "legal_retention": it.legal_retention},
            mmod.A_REMOVE, getattr(actor, "pk", None), reason)
        it.content_status = new_item["content_status"]
        it.queue_state = new_item["queue_state"]
        it.decision = new_item["decision"]
        it.resolved_at = timezone.now()
        it.save(update_fields=["content_status", "queue_state", "decision", "resolved_at"])
        ChannelPost.objects.filter(pk=int(it.target_id)).update(content_status=it.content_status)
        ModerationAudit.objects.create(actor=actor, action=audit["action"],
                                       target_kind=it.target_kind, target_id=it.target_id,
                                       reason=reason, extra={"via": "adminsafe"})
        out["posts"] += 1
    if ModerationItem.objects.filter(target_kind="person", target_id=str(user.pk)).exists():
        try:
            from .models import TrainChatMessage
            out["train_messages"] = TrainChatMessage.objects.filter(
                member__user_id=user.pk, hidden=False).update(hidden=True)
        except Exception:
            pass
    return out


# ------------------------------------------------------------------ actions
def _days(v, hi):
    try:
        d = int(str(v).strip())
    except (TypeError, ValueError):
        return None
    return d if 1 <= d <= hi else None


def apply_action(user, kind, reason, actor, days=None, kinds=None):
    """Do one action; returns the AccountAction. Raises ActionError(code)."""
    from .models import AccountAction, BannedIdentity, ModerationAudit, UserRestriction, User
    reason = (reason or "").strip()[:300]
    if kind not in ACTIONS:
        raise ActionError("as_err_action")
    if not reason:
        raise ActionError("err_reason")
    if user.is_superuser or (actor is not None and actor.pk == user.pk):
        raise ActionError("err_block_owner")
    now = timezone.now()
    until, detail = None, {}
    if kind == "suspend":
        d = _days(days, SUSPEND_MAX_DAYS)
        if d is None:
            raise ActionError("as_err_days")
        until, detail["days"] = now + timedelta(days=d), d
    if kind in ("restrict", "unrestrict"):
        ks = [k for k in (kinds or []) if k in RESTRICT_KINDS]
        if kind == "restrict" and not ks:
            raise ActionError("as_err_kinds")
        if kind == "unrestrict" and not ks:
            ks = list(RESTRICT_KINDS)
        detail["kinds"] = ks
        if kind == "restrict" and str(days or "").strip():
            d = _days(days, RESTRICT_MAX_DAYS)
            if d is None:
                raise ActionError("as_err_days")
            until, detail["days"] = now + timedelta(days=d), d
    with transaction.atomic():
        act = AccountAction.objects.create(user=user, kind=kind, reason=reason,
                                           detail=detail, until=until, actor=actor)
        if kind == "restrict":
            UserRestriction.objects.filter(_active_q(now), user=user,
                                           kind__in=detail["kinds"]).update(lifted_at=now)
            UserRestriction.objects.bulk_create(
                [UserRestriction(user=user, kind=k, action=act, until=until)
                 for k in detail["kinds"]])
        elif kind == "unrestrict":
            UserRestriction.objects.filter(_active_q(now), user=user,
                                           kind__in=detail["kinds"]).update(lifted_at=now)
        elif kind in ("suspend", "ban"):
            User.objects.filter(pk=user.pk).update(
                account_status="suspended" if kind == "suspend" else "banned")
            detail["sessions"] = revoke_sessions(user)
            if kind == "ban":
                rows = []
                emails = {user.email or ""}
                try:
                    from . import otp
                    emails.add(otp.verified_email(user) or "")
                except Exception:
                    pass
                for k, v in [("phone", user.phone)] + [("email", e) for e in emails]:
                    h = ident_hash(k, v)
                    if h:
                        rows.append(BannedIdentity(kind=k, value_hash=h, user=user, action=act))
                BannedIdentity.objects.bulk_create(rows)
                detail["identities"] = len(rows)
        elif kind == "unblock":
            User.objects.filter(pk=user.pk).update(account_status="active")
            BannedIdentity.objects.filter(user=user, lifted_at__isnull=True).update(lifted_at=now)
        elif kind == "force_logout":
            detail["sessions"] = revoke_sessions(user)
        elif kind == "remove_content":
            detail["removed"] = remove_reported_content(user, actor, reason)
        act.detail = detail
        act.save(update_fields=["detail"])
        ModerationAudit.objects.create(
            actor=actor, action=("acct_" + kind)[:20], target_kind="person",
            target_id=str(user.pk), reason=reason,
            extra={"via": "owner_admin", "action_id": act.id,
                   "until": until.isoformat() if until else None})
    user.refresh_from_db()
    _notify(user, act)
    return act


# ------------------------------------------------------------------ standing
def _act_dict(a, appeals):
    ap = appeals.get(a.id)
    return {"id": a.id, "kind": a.kind, "reason": a.reason,
            "at": a.created_at.isoformat(),
            "until": a.until.isoformat() if a.until else None,
            "appealable": a.kind in APPEALABLE and ap is None,
            "appeal": ({"state": ap.state, "created_at": ap.created_at.isoformat(),
                        "decision_note": ap.decision_note} if ap else None)}


def standing(user):
    """What the user may see about their own account: status, active
    restrictions, the last actions with their reasons, and appeal states."""
    from .models import AccountAction, AccountAppeal
    expire_if_due(user)
    acts = [a for a in AccountAction.objects.filter(user=user)[:30]
            if not (a.detail or {}).get("auto")][:20]
    appeals = {}
    for ap in AccountAppeal.objects.filter(user=user, action__in=acts).order_by("created_at"):
        appeals[ap.action_id] = ap
    rs = [{"kind": r.kind, "until": r.until.isoformat() if r.until else None,
           "reason": r.action.reason if r.action else ""}
          for r in active_restrictions(user).select_related("action")]
    end = _suspend_end(user) if user.account_status == "suspended" else None
    return {"status": user.account_status,
            "until": end.isoformat() if end else None,
            "restrictions": rs,
            "notices": [_act_dict(a, appeals) for a in acts if a.kind != "unrestrict"],
            "can_appeal": any(a.kind in APPEALABLE and a.id not in appeals for a in acts)}


# ------------------------------------------------------------------- appeals
def appeal_token(user):
    return signing.dumps({"u": user.pk}, salt=_SALT, compress=True)


def user_from_appeal_token(tok):
    from .models import User
    try:
        d = signing.loads(str(tok or ""), salt=_SALT,
                          max_age=APPEAL_TOKEN_DAYS * 86400)
    except Exception:
        return None
    return User.objects.filter(pk=d.get("u")).first()


def create_appeal(user, action_id, text):
    """Returns (appeal, error_code). error_code in bad_text / not_found /
    not_appealable / already_appealed."""
    from .models import AccountAction, AccountAppeal
    text = (text or "").strip()
    if not (APPEAL_MIN <= len(text) <= APPEAL_MAX):
        return None, "bad_text"
    a = AccountAction.objects.filter(pk=action_id, user=user).first() \
        if str(action_id or "").isdigit() else None
    if a is None:
        return None, "not_found"
    if a.kind not in APPEALABLE:
        return None, "not_appealable"
    if AccountAppeal.objects.filter(user=user, action=a).exists():
        return None, "already_appealed"
    ap = AccountAppeal.objects.create(user=user, action=a, text=text)
    try:
        from . import push
        push.notify_owner("New appeal #%d" % ap.id,
                          "An account appeal is waiting in Owner Admin -> Appeals.")
    except Exception:
        pass
    return ap, None


def decide_appeal(appeal, decision, note, actor):
    """decision 'lift' -> undo the action (unblock / unrestrict) + notice;
    'uphold' -> keep it; the user sees the note either way."""
    if appeal.state != "open":
        raise ActionError("as_err_decided")
    note = (note or "").strip()[:300]
    if not note:
        raise ActionError("err_reason")
    a = appeal.action
    if decision == "lift":
        if a is not None and a.kind in ("suspend", "ban"):
            apply_action(appeal.user, "unblock", note, actor)
        elif a is not None and a.kind == "restrict":
            apply_action(appeal.user, "unrestrict", note, actor,
                         kinds=(a.detail or {}).get("kinds"))
        appeal.state = "lifted"
    elif decision == "uphold":
        appeal.state = "upheld"
    else:
        raise ActionError("as_err_action")
    appeal.decided_by, appeal.decided_at, appeal.decision_note = actor, timezone.now(), note
    appeal.save(update_fields=["state", "decided_by", "decided_at", "decision_note"])
    if decision == "uphold":
        from .models import NotifEvent
        try:
            NotifEvent.objects.create(
                user=appeal.user, type="security",
                title_bn="আপনার আপিলের উত্তর এসেছে", title_en="Your appeal was answered",
                body_bn=note, body_en=note, route="account_standing",
                meta={"kind": "appeal", "appeal_id": appeal.id})
        except Exception:
            pass
    return appeal


# ---------------------------------------------------------- push dead marker
def note_token_dropped(user_ids):
    """Called by push._drop_token after FCM said a token is dead: a user with
    no live token left gets a PushDeadMark (the 'likely uninstalled' count)."""
    from .models import Device, PushDeadMark
    for uid in set(user_ids or ()):
        try:
            if not Device.objects.filter(user_id=uid).exclude(push_token="").exists():
                PushDeadMark.objects.get_or_create(user_id=uid)
        except Exception:
            pass


def note_token_registered(user):
    from .models import PushDeadMark
    try:
        PushDeadMark.objects.filter(user=user).delete()
    except Exception:
        pass
