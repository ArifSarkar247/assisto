"""
Secure "Delete my profile & all data" — Play-Store-compliant account deletion.

Deleting the whole account is treated as a SENSITIVE ACTION under Section 8
(Stolen-While-Unlocked Protection). The same rules apply:

  * require the Assisto Security PIN when one is set (the native app layers a
    biometric check on top before it ever calls this);
  * a 24h delay OUTSIDE a trusted place so the real owner can react;
  * BLOCKED while any theft signal is active in the last 7 days — a thief who
    just snatched an unlocked phone can NEVER wipe the owner's account;
  * an instant notice to the owner + every trusted contact carrying a one-tap
    "Cancel — this wasn't me" token.

On top of that we add a 7-DAY GRACE period (Play-compliant: the account stays
fully recoverable until effective_at). The account is NOT touched here — only
the purge_deletions management command (cron), running after effective_at on a
still-pending request, performs the real, complete, cascading hard delete.

Auth reuse:
  * password      -> user.check_password (Django).
  * OTP           -> o1-otp: a single-use `otp_proof` (purpose=delete_account,
    bound to the user's own phone) from auth/otp/verify. Required whenever the
    SMS gateway is CONNECTED and the user has a BD mobile (core/otp.py
    otp_required_for). With SMS not configured no code can be sent, so OTP
    degrades honestly to password + PIN (same as before).
  * Security PIN  -> views_security._verify_pin against the primary ProtectedPhone.
"""
import secrets

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from rest_framework import status
from rest_framework.permissions import IsAuthenticated, AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from datetime import timedelta

from .models import (AccountDeletionRequest, ProtectedPhone, AuditLog)
from .logic import security as sec
from .views_security import _primary_phone, _verify_pin, _notify_owner_and_circle

GRACE_DAYS = 7


def _log(user, action, **detail):
    AuditLog.objects.create(user=user, action=action, detail=detail)


# --------------------------------------------------------------------------
# what will be deleted — counts per data type (best-effort over the user's
# reverse relations; cheap and never raises).
# --------------------------------------------------------------------------

def _deletion_counts(user):
    counts = {}
    for rel in user._meta.related_objects:
        # Reverse relations (FK/O2O/M2M pointing AT the user). On hard delete
        # every CASCADE child goes with the user; SET_NULL ones are detached.
        name = rel.get_accessor_name()
        try:
            mgr = getattr(user, name)
            counts[name] = mgr.count()
        except Exception:
            continue
    # Drop zero-count rows to keep the preview readable.
    return {k: v for k, v in counts.items() if v}


def _otp_gate(user, proof):
    """o1-otp: (ok, reason). Proof is consumed (single use) only when required."""
    from . import otp as otp_mod
    if not otp_mod.otp_required_for(user):
        return True, None
    proof = str(proof or "").strip()
    if not proof:
        return False, "otp_required"
    if otp_mod.consume_proof(proof, "delete_account", user.phone) is None:
        return False, "bad_otp"
    return True, None


# --------------------------------------------------------------------------
# dl1: idempotent pending response + link-free, bilingual notices.
# --------------------------------------------------------------------------

def _already_pending(req):
    """The response for a second "delete my account" while one is pending:
    the SAME request, unchanged (no new token, notice or date)."""
    return Response({"state": req.state,
                     "effective_at": req.effective_at.isoformat(),
                     "id": req.id, "already_pending": True})


_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_BN_MONTHS = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
              "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")


def fmt_when(dt, lang):
    """A readable local (Asia/Dhaka) date for notices: "29 Oct 2026" /
    "২৯ অক্টোবর ২০২৬"."""
    loc = timezone.localtime(dt)
    if lang == "bn":
        return (f"{loc.day} {_BN_MONTHS[loc.month - 1]} {loc.year}"
                ).translate(_BN_DIGITS)
    return loc.strftime("%d %b %Y").lstrip("0")


def deletion_notice_texts(user, effective_at):
    """(owner, circle) notice texts as {title_bn,title_en,body_bn,body_en}.
    No link and no token anywhere — the owner cancels with the in-app
    "Cancel deletion" button; circle contacts get a neutral heads-up."""
    bn_d, en_d = fmt_when(effective_at, "bn"), fmt_when(effective_at, "en")
    owner = {
        "title_bn": "আপনার অ্যাকাউন্ট মুছে ফেলার অনুরোধ নেওয়া হয়েছে",
        "title_en": "Your account is scheduled for deletion",
        "body_bn": (f"আপনার Assisto অ্যাকাউন্ট ও এর সব তথ্য {bn_d} তারিখে মুছে "
                    "যাবে। মত বদলেছেন, বা অনুরোধটি আপনি করেননি? Assisto খুলে "
                    "“মুছে ফেলা বাতিল করুন” চাপুন।"),
        "body_en": (f"Your Assisto account and all its data will be deleted on "
                    f"{en_d}. Changed your mind, or wasn't this you? Open "
                    "Assisto and tap “Cancel deletion”."),
    }
    name = (getattr(user, "name", "") or "").strip()
    circle = {
        "title_bn": (f"{name} তাঁর Assisto অ্যাকাউন্ট মুছে ফেলার অনুরোধ করেছেন"
                     if name else "আপনার সার্কেলের একজন Assisto অ্যাকাউন্ট "
                                  "মুছে ফেলার অনুরোধ করেছেন"),
        "title_en": (f"{name} asked to delete their Assisto account" if name
                     else "Someone in your circle asked to delete their "
                          "Assisto account"),
        "body_bn": (f"এটি {bn_d} তারিখে কার্যকর হবে। অনুরোধটি তাঁর নিজের না "
                    "মনে হলে সরাসরি তাঁর সঙ্গে কথা বলুন।"),
        "body_en": (f"It takes effect on {en_d}. If you think it wasn't them, "
                    "please check with them directly."),
    }
    return owner, circle


def notify_deletion_scheduled(user, req):
    """In-app notice (route account/delete -> the "Cancel deletion" screen) +
    push + email for the owner; a neutral notice for accepted circle
    contacts. Never carries a link or the cancel token. Never raises."""
    from django.core.mail import send_mail
    from .models import NotifEvent
    from .views_security import _accepted_members
    now = timezone.now()
    owner, circle = deletion_notice_texts(user, req.effective_at)
    meta = {"kind": "account_delete", "action": "cancel_deletion",
            "effective_at": req.effective_at.isoformat(), "request_id": req.id}
    try:
        NotifEvent.objects.create(user=user, type="security", route="account/delete",
                                  meta=meta, at=now, **owner)
    except Exception:
        pass
    peers = []
    try:
        for m in _accepted_members(user):
            if m.peer_user_id and m.peer_user_id != user.id:
                peers.append(m.peer_user)
    except Exception:
        peers = []
    peers = list({p.id: p for p in peers if p is not None}.values())
    for p in peers:
        try:
            NotifEvent.objects.create(
                user=p, type="security", route="",
                meta={"kind": "account_delete_circle"}, at=now, **circle)
        except Exception:
            pass
    try:
        from . import push
        push.safe_push(user, "family_alert", owner["title_bn"], owner["title_en"],
                       owner["body_bn"], owner["body_en"],
                       data={"alert_kind": "account_delete",
                             "route": "account/delete"},
                       high_priority=True)
        for p in peers:
            push.safe_push(p, "family_alert", circle["title_bn"],
                           circle["title_en"], circle["body_bn"],
                           circle["body_en"],
                           data={"alert_kind": "account_delete_circle",
                                 "route": "alerts"})
    except Exception:
        pass
    # Email (fail_silently): owner + circle, in each person's language.
    def _mail(u, t):
        if not getattr(u, "email", None):
            return
        bn = (getattr(u, "language", "bn") or "bn") == "bn"
        try:
            send_mail(t["title_bn"] if bn else t["title_en"],
                      t["body_bn"] if bn else t["body_en"],
                      settings.DEFAULT_FROM_EMAIL, [u.email], fail_silently=True)
        except Exception:
            pass
    _mail(user, owner)
    for p in peers:
        _mail(p, circle)


# --------------------------------------------------------------------------
# POST account/delete/preview  — what WILL be deleted; no side effects.
# --------------------------------------------------------------------------

class AccountDeletePreviewView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user
        req = AccountDeletionRequest.objects.filter(user=user).first()
        existing = None
        if req and req.state == AccountDeletionRequest.STATE_PENDING:
            existing = {"state": req.state,
                        "effective_at": req.effective_at.isoformat()}
        return Response({
            "counts": _deletion_counts(user),
            "export_first": True,
            "export_url": "export",   # GET export | export/excel | export/pdf
            "export_downloaded": bool(req.export_downloaded) if req else False,
            "reminder": ("Download your data first — deletion is permanent after "
                         "the 7-day grace period."),
            "grace_days": GRACE_DAYS,
            "existing_request": existing,
        })


# --------------------------------------------------------------------------
# POST account/delete/request  — schedule a deletion (Section-8 gated).
# --------------------------------------------------------------------------

class AccountDeleteRequestView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        user = request.user

        # 0) dl1: idempotent — a request is already scheduled. Return it as-is
        #    (same date, no new token / notification / alert).
        cur = AccountDeletionRequest.objects.filter(user=user).first()
        if cur is not None and cur.state == AccountDeletionRequest.STATE_PENDING:
            return _already_pending(cur)

        # 1) password (always required)
        if not user.check_password(str(request.data.get("password", ""))):
            return Response({"ok": False, "reason": "bad_password"},
                            status=status.HTTP_403_FORBIDDEN)

        # 2) Security PIN — required ONLY when the user has set one.
        phone = _primary_phone(user, create=False)
        if phone and phone.security_pin_hash:
            ok, locked = _verify_pin(phone, request.data.get("security_pin"))
            if not ok:
                return Response({"ok": False, "reason": "locked" if locked else "bad_pin"},
                                status=status.HTTP_403_FORBIDDEN)

        # 3) OTP proof (o1-otp) — required when SMS is connected; checked after
        #    password + PIN so a wrong PIN doesn't burn the single-use proof.
        ok_otp, why = _otp_gate(user, request.data.get("otp_proof"))
        if not ok_otp:
            return Response({"ok": False, "reason": why, "purpose": "delete_account"},
                            status=status.HTTP_403_FORBIDDEN)

        now = timezone.now()

        # 4) theft gate — a thief must not be able to delete the owner's data.
        if phone and (sec.recent_theft_signal(phone, now, days=7)
                      or sec.is_frozen(phone, now)):
            return Response({"state": "blocked", "reason": "theft_signal"},
                            status=status.HTTP_423_LOCKED)

        # 5) location -> Section-8 24h delay when untrusted.
        lat = request.data.get("lat")
        lng = request.data.get("lng")
        lat = float(lat) if lat not in (None, "") else None
        lng = float(lng) if lng not in (None, "") else None
        trusted = sec.is_trusted_location(user, lat, lng)
        section8_at = now if trusted else now + timedelta(hours=sec.DELAY_HOURS)

        # effective_at never shortens either protection.
        effective_at = max(now + timedelta(days=GRACE_DAYS), section8_at)

        token = secrets.token_urlsafe(24)
        with transaction.atomic():
            # Re-check under a row lock: a double tap racing past the early
            # already-pending check must not reset the date or re-notify.
            existing = (AccountDeletionRequest.objects.select_for_update()
                        .filter(user=user).first())
            if existing is not None and \
                    existing.state == AccountDeletionRequest.STATE_PENDING:
                return _already_pending(existing)
            req, _created = AccountDeletionRequest.objects.update_or_create(
                user=user,
                defaults={
                    "requested_at": now,
                    "effective_at": effective_at,
                    "state": AccountDeletionRequest.STATE_PENDING,
                    # Server-side only (support use); never put in any text,
                    # notification, push or email (dl1).
                    "cancel_token": token,
                    "reason": str(request.data.get("reason", "")),
                },
            )

        notify_deletion_scheduled(user, req)

        _log(user, "account.delete.request",
             effective_at=effective_at.isoformat(), trusted=trusted,
             request_id=req.id)

        return Response({"state": req.state,
                         "effective_at": effective_at.isoformat(),
                         "id": req.id})


# --------------------------------------------------------------------------
# POST account/delete/cancel  — owner (authed) OR correct token ("not me").
# --------------------------------------------------------------------------

class AccountDeleteCancelView(APIView):
    permission_classes = [AllowAny]   # token path works with no auth

    def post(self, request):
        token = str(request.data.get("token", ""))
        req = None
        if request.user and request.user.is_authenticated:
            req = AccountDeletionRequest.objects.filter(user=request.user).first()
        if req is None and token:
            req = AccountDeletionRequest.objects.filter(cancel_token=token).first()

        if req is None:
            return Response({"ok": False, "reason": "not_found"},
                            status=status.HTTP_404_NOT_FOUND)

        is_owner = (request.user and request.user.is_authenticated
                    and req.user_id == request.user.id)
        token_ok = bool(req.cancel_token) and bool(token) and \
            secrets.compare_digest(token, req.cancel_token)
        if not (is_owner or token_ok):
            return Response({"ok": False, "reason": "forbidden"},
                            status=status.HTTP_403_FORBIDDEN)

        if req.state != AccountDeletionRequest.STATE_PENDING:
            return Response({"ok": True, "state": req.state})

        req.state = AccountDeletionRequest.STATE_CANCELLED
        req.save(update_fields=["state"])
        _log(req.user, "account.delete.cancel", request_id=req.id,
             by="owner" if is_owner else "token")
        return Response({"ok": True, "state": "cancelled"})


# --------------------------------------------------------------------------
# GET account/delete/status  — current request or none.
# --------------------------------------------------------------------------

class AccountDeleteStatusView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        req = AccountDeletionRequest.objects.filter(user=request.user).first()
        if req is None:
            return Response({"state": None})
        from . import otp as otp_mod
        return Response({
            "state": req.state,
            "effective_at": req.effective_at.isoformat() if req.effective_at else None,
            "export_downloaded": req.export_downloaded,
            # dl1: tells the sign-in grace screen whether "Delete now and start
            # fresh" will ask for an SMS code (only when SMS is connected).
            "otp_required": bool(otp_mod.otp_required_for(request.user)),
        })


# --------------------------------------------------------------------------
# POST account/delete/start-fresh — dl1: signed in during the grace period and
# chose "Delete now and start fresh": purge the old account NOW (the same purge
# as purge_deletions) and hand back a clean new account for the same number.
# --------------------------------------------------------------------------

CONFIRM_WORDS = ("DELETE", "মুছুন")


def _confirm_ok(raw):
    return str(raw or "").strip().upper() in {w.upper() for w in CONFIRM_WORDS}


class AccountStartFreshView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from django.contrib.auth import get_user_model
        from rest_framework.authtoken.models import Token
        from . import otp as otp_mod
        from .account_purge import purge_user
        from .serializers import UserSerializer
        user = request.user
        d = request.data or {}

        req = AccountDeletionRequest.objects.filter(user=user).first()
        if req is None or req.state != AccountDeletionRequest.STATE_PENDING:
            return Response({"ok": False, "reason": "no_pending"},
                            status=status.HTTP_409_CONFLICT)

        # 1) the typed final confirmation ("DELETE" / "মুছুন").
        if not _confirm_ok(d.get("confirm_text")):
            return Response({"ok": False, "reason": "confirm_required"},
                            status=status.HTTP_400_BAD_REQUEST)

        # 2) password (always) — the same factor the delete request used.
        if not user.check_password(str(d.get("password", ""))):
            return Response({"ok": False, "reason": "bad_password"},
                            status=status.HTTP_403_FORBIDDEN)

        # 3) theft gate — a thief must not be able to wipe the account early.
        now = timezone.now()
        phone = _primary_phone(user, create=False)
        if phone and (sec.recent_theft_signal(phone, now, days=7)
                      or sec.is_frozen(phone, now)):
            return Response({"state": "blocked", "reason": "theft_signal"},
                            status=status.HTTP_423_LOCKED)

        # 4) SMS code when SMS is connected (checked last: a wrong password
        #    must not burn the single-use proof).
        otp_used = bool(otp_mod.otp_required_for(user))
        ok_otp, why = _otp_gate(user, d.get("otp_proof"))
        if not ok_otp:
            return Response({"ok": False, "reason": why, "purpose": "delete_account"},
                            status=status.HTTP_403_FORBIDDEN)

        # Identity carried to the new account; every piece of data is purged.
        User = get_user_model()
        keep = {"name": user.name or "", "phone": user.phone, "email": user.email,
                "password": user.password,
                "language": getattr(user, "language", "bn") or "bn",
                "had_trial": bool(getattr(user, "trial_until", None))}
        canon = otp_mod.user_phone(user) if otp_used else None
        old_id = user.id
        requested_at = req.requested_at
        with transaction.atomic():
            files = purge_user(user)
            new = User.objects.create_user(name=keep["name"], phone=keep["phone"],
                                           email=keep["email"], password=None)
            new.password = keep["password"]          # same password, no re-type
            new.language = keep["language"]
            new.save(update_fields=["password", "language"])
            if canon:
                otp_mod.mark_verified(new, canon)
            token, _ = Token.objects.get_or_create(user=new)
            AuditLog.objects.create(
                user=new, action="account.delete.start_fresh",
                detail={"old_user_id": old_id, "files_removed": files,
                        "requested_at": requested_at.isoformat(),
                        "purged_at": now.isoformat(), "otp": otp_used})
        # A NEW account gets the normal sign-up trial only if the old one never
        # had one (starting fresh must not be a way to repeat the trial).
        if not keep["had_trial"]:
            try:
                from . import plans
                plans.start_trial(new)
            except Exception:
                pass
        return Response({"ok": True, "start_fresh": True, "token": token.key,
                         "user": UserSerializer(new, context={"request": request}).data},
                        status=status.HTTP_201_CREATED)
