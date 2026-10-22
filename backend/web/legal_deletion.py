"""l1-launch — the web path for "delete my Assisto account" (Google Play
requires one for people who no longer have the app).

Two halves, both deliberately boring:

* `submit(...)` validates the public form and files a WebDeletionRequest
  TICKET. It never deletes, schedules or changes an account, and it answers
  the same way whether or not the contact belongs to a user (no probing).
* `schedule_verified(...)` is run by the owner from the Django admin AFTER
  verifying the requester. It hands over to the existing in-app flow
  (AccountDeletionRequest: 7-day grace, one-tap cancel token sent to the
  account owner + trusted contacts, real delete only by purge_deletions).
"""
import secrets
from datetime import timedelta

from django.core.exceptions import ValidationError
from django.core.validators import validate_email
from django.db import transaction
from django.utils import timezone

# Per hashed IP. Generous for a real person, useless for a flood.
RATE_PER_HOUR = 3
RATE_PER_DAY = 10
GRACE_DAYS = 7          # same as core.views_account_deletion.GRACE_DAYS

ERR = {
    "bn": {
        "contact": "সঠিক মোবাইল নম্বর (যেমন 01XXXXXXXXX) বা ইমেইল দিন — যেটি দিয়ে অ্যাকাউন্ট খুলেছিলেন।",
        "confirm": "অনুরোধ পাঠাতে নিশ্চিতকরণ বক্সে টিক দিন।",
        "long": "লেখাটি অনেক বড় — ১০০০ অক্ষরের মধ্যে রাখুন।",
    },
    "en": {
        "contact": "Enter a valid mobile number (e.g. 01XXXXXXXXX) or email — the one you signed up with.",
        "confirm": "Tick the confirmation box to send the request.",
        "long": "That text is too long — keep it under 1000 characters.",
    },
}


def normalize_contact(raw):
    """(kind, canonical) or (None, None). Phone -> E.164, email -> lower-case."""
    from core.phone import canonical_phone
    s = (raw or "").strip()
    if not s or len(s) > 190:
        return None, None
    if "@" in s:
        try:
            validate_email(s)
        except ValidationError:
            return None, None
        return "email", s.lower()
    canon = canonical_phone(s)
    return ("phone", canon) if canon else (None, None)


def _match_user(kind, contact):
    from core.models import User
    if kind == "email":
        return User.objects.filter(email__iexact=contact).first()
    from core.phone import variants
    try:
        forms = list(variants(contact))
    except Exception:
        forms = [contact]
    return User.objects.filter(phone__in=forms or [contact]).first()


def rate_ok(ip_hash):
    from core.models import WebDeletionRequest
    now = timezone.now()
    qs = WebDeletionRequest.objects.filter(ip_hash=ip_hash)
    if qs.filter(created_at__gte=now - timedelta(hours=1)).count() >= RATE_PER_HOUR:
        return False
    if qs.filter(created_at__gte=now - timedelta(days=1)).count() >= RATE_PER_DAY:
        return False
    return True


def submit(data, *, ip_hash, lang):
    """Validate + file a ticket. Returns (ok, errors, ticket_or_None).

    A bot that fills the hidden honeypot gets ok=True and NO ticket (it must
    not learn it was caught). A repeat for the same contact within 24h while
    the first ticket is still open re-uses that ticket (ok=True)."""
    from core.models import WebDeletionRequest
    E = ERR.get(lang, ERR["bn"])
    errors = {}
    if (data.get("website") or "").strip():          # honeypot
        return True, {}, None
    kind, contact = normalize_contact(data.get("contact"))
    if not contact:
        errors["contact"] = E["contact"]
    if not data.get("confirm"):
        errors["confirm"] = E["confirm"]
    name = (data.get("name") or "").strip()
    reason = (data.get("reason") or "").strip()
    if len(name) > 120 or len(reason) > 1000:
        errors["reason"] = E["long"]
    if errors:
        return False, errors, None

    since = timezone.now() - timedelta(days=1)
    open_states = (WebDeletionRequest.STATUS_NEW, WebDeletionRequest.STATUS_VERIFIED)
    dup = (WebDeletionRequest.objects
           .filter(contact=contact, status__in=open_states, created_at__gte=since)
           .first())
    if dup is not None:
        return True, {}, dup
    user = _match_user(kind, contact)
    t = WebDeletionRequest.objects.create(
        contact=contact, contact_kind=kind, name=name, reason=reason,
        lang=lang if lang in ("bn", "en") else "bn", matched_user=user,
        ip_hash=ip_hash,
        status=(WebDeletionRequest.STATUS_NEW if user is not None
                else WebDeletionRequest.STATUS_NO_ACCOUNT))
    return True, {}, t


def schedule_verified(queryset, actor=None):
    """Owner action. Only VERIFIED tickets with a matching account are handed
    to the normal deletion flow; everything else is skipped. Returns
    (scheduled, skipped)."""
    from core.models import AccountDeletionRequest, AuditLog, WebDeletionRequest
    done = skipped = 0
    now = timezone.now()
    for t in queryset.select_related("matched_user"):
        user = t.matched_user
        if t.status != WebDeletionRequest.STATUS_VERIFIED or user is None:
            skipped += 1
            continue
        effective_at = now + timedelta(days=GRACE_DAYS)
        token = secrets.token_urlsafe(24)
        with transaction.atomic():
            AccountDeletionRequest.objects.update_or_create(
                user=user,
                defaults={"requested_at": now, "effective_at": effective_at,
                          "state": AccountDeletionRequest.STATE_PENDING,
                          "cancel_token": token,
                          "reason": f"web request #{t.pk}"})
            t.status = WebDeletionRequest.STATUS_SCHEDULED
            t.save(update_fields=["status", "updated_at"])
            AuditLog.objects.create(user=user, action="account.delete.web_request",
                                    detail={"ticket": t.pk,
                                            "effective_at": effective_at.isoformat(),
                                            "by": getattr(actor, "pk", None)})
        # Same "this wasn't me" safety net as the in-app request: the account
        # owner and their trusted contacts get the notice + cancel token.
        try:
            from django.conf import settings
            from core.views_security import _notify_owner_and_circle
            base = getattr(settings, "APP_DEEP_LINK_BASE", "assisto://")
            _notify_owner_and_circle(
                user, "Account deletion scheduled",
                ("A request (made on lifeassisto.com) to delete this Assisto "
                 "account and ALL its data was verified. It takes effect on "
                 f"{effective_at:%Y-%m-%d %H:%M}. If this was NOT you, cancel: "
                 f"{base}account/delete/cancel?token={token}"),
                kind="security", ntype="security", route="account/delete",
                meta={"effective_at": effective_at.isoformat(),
                      "cancel_token": token})
        except Exception:
            pass
        done += 1
    return done, skipped
