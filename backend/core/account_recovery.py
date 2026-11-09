"""
Account & security + account recovery (recovery, owner order Part 8, 3 Nov).

  * identity changes (email / phone): the NEW one is proven by a code (the
    existing email_verify / change_number flows); the OLD one gets an alert
    with a single-use "This was not me" link. Tapping it reverts the change,
    signs the account out everywhere and locks identity changes for 7 days.
  * phone and email cannot both change within 24 hours.
  * the gentle "add an email" nudge: at most twice (once, then once more
    after 5 days), never again after "Later" twice or after an email exists.
  * forgot password: which channels a code can go to for a phone (SMS, the
    account's verified email — masked).
  * support recovery (lost phone + no verified email): proof results, a My
    Circle family member's confirmation, a 48 h hold, a human review in
    Owner Admin. Never instant. Reviewers see match RESULTS, never content.
"""
import hashlib
import secrets
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

from .i18n import pick

HOLD_HOURS = 48
IDENTITY_COOLDOWN = timedelta(hours=24)
UNDO_TTL = timedelta(days=7)
LOCK_AFTER_NOT_ME = timedelta(days=7)
NUDGE_GAP = timedelta(days=5)
NUDGE_MAX = 2
COMPLETE_WINDOW = timedelta(days=7)     # after the hold, an approval lasts 7 days
REQ_PER_IP_DAY = 3
REQ_PER_ACCOUNT_30D = 3


def _sha(raw):
    return hashlib.sha256(str(raw).encode()).hexdigest()


def _log(user, action, **detail):
    try:
        from .models import AuditLog
        AuditLog.objects.create(user=user, action=action, detail=detail)
    except Exception:  # noqa: BLE001
        pass


def state(user):
    from .models import AccountSecurityState
    st, _ = AccountSecurityState.objects.get_or_create(user=user)
    return st


def base_url():
    return (getattr(settings, "ASSISTO_BASE_URL", "") or "").rstrip("/")


# ------------------------------------------------------------ identity rules
def identity_block(user, kind, now=None):
    """None when `kind` ('email' | 'phone') may change now, else
    (reason, until) with reason identity_locked | identity_cooldown."""
    now = now or timezone.now()
    from .models import AccountSecurityState
    st = AccountSecurityState.objects.filter(user=user).first()
    if st is None:
        return None
    if st.identity_locked_until and st.identity_locked_until > now:
        return "identity_locked", st.identity_locked_until
    other = st.last_phone_change_at if kind == "email" else st.last_email_change_at
    if other and now - other < IDENTITY_COOLDOWN:
        return "identity_cooldown", other + IDENTITY_COOLDOWN
    return None


BLOCK_MSG = {
    "identity_locked": (
        "নিরাপত্তার জন্য এই অ্যাকাউন্টে ইমেইল/নম্বর বদল কিছুদিন বন্ধ আছে (কেউ 'এটা আমি নই' চেপেছেন)।",
        "For safety, email and phone changes are paused on this account for a few days "
        "(someone tapped 'This was not me')."),
    "identity_cooldown": (
        "২৪ ঘণ্টার মধ্যে ফোন নম্বর আর ইমেইল দুটোই বদলানো যায় না। কাল আবার চেষ্টা করুন।",
        "Your phone number and email can't both change within 24 hours. Please try again tomorrow."),
}


def block_body(reason, until, lang):
    bn, en = BLOCK_MSG[reason]
    return {"ok": False, "reason": reason, "detail": pick(lang, bn, en),
            "message": pick(lang, bn, en), "until": until.isoformat()}


def _mask_value(kind, value):
    if not value:
        return ""
    if kind == "email":
        from .email_sender import mask_email
        return mask_email(value)
    from .otp import mask, normalize_bd_phone
    c = normalize_bd_phone(value)
    return mask(c) if c else value[:3] + "…"


def record_change(user, kind, old, new, lang="bn", now=None):
    """After an email / phone change: log it, stamp the 24 h rule and alert
    the OLD address / number (+ push) with a "This was not me" link."""
    from .models import IdentityChange
    now = now or timezone.now()
    raw = secrets.token_urlsafe(24)
    ch = IdentityChange.objects.create(
        user=user, kind=kind, old_value=old or "", new_value=new or "",
        created_at=now, undo_hash=_sha(raw), undo_expires_at=now + UNDO_TTL)
    st = state(user)
    if kind == "email":
        st.last_email_change_at = now
        st.save(update_fields=["last_email_change_at"])
    else:
        st.last_phone_change_at = now
        st.save(update_fields=["last_phone_change_at"])
    sent = []
    link = "%s/api/v1/account/not-me/%s" % (base_url(), raw)
    new_m = _mask_value(kind, new)
    if kind == "email":
        if old and _alert_email(old, kind, new_m, link, lang):
            sent.append("email")
    else:
        if old and _alert_sms(user, old, link, lang):
            sent.append("sms")
        from .otp import verified_email
        ve = verified_email(user)
        if ve and _alert_email(ve, kind, new_m, link, lang):
            sent.append("email")
    if _alert_push(user, kind, new_m):
        sent.append("push")
    ch.alert_sent = ",".join(sent)[:40]
    ch.save(update_fields=["alert_sent"])
    _log(user, "account.identity_change", kind=kind, alerts=ch.alert_sent)
    return ch, raw


def _alert_email(to, kind, new_masked, link, lang):
    try:
        from . import email_sender
        what_bn = "ইমেইল" if kind == "email" else "ফোন নম্বর"
        what_en = "email" if kind == "email" else "phone number"
        bn = ("আপনার Assisto অ্যাকাউন্টের %s বদলানো হয়েছে (নতুন: %s)।\n\n"
              "আপনি করে থাকলে কিছু করতে হবে না।\n"
              "আপনি না করলে এই লিংক খুলে 'এটা আমি নই' চাপুন — বদল ফিরে যাবে, "
              "সব ফোন থেকে সাইন-আউট হবে আর ৭ দিন বদল বন্ধ থাকবে:\n%s"
              % (what_bn, new_masked, link))
        en = ("The %s on your Assisto account was changed (new: %s).\n\n"
              "If this was you, there is nothing to do.\n"
              "If it was NOT you, open this link and tap 'This was not me' — the "
              "change is undone, every device is signed out and changes are "
              "locked for 7 days:\n%s" % (what_en, new_masked, link))
        subj = pick(lang, "Assisto: আপনার %s বদলানো হয়েছে / Your %s was changed"
                    % (what_bn, what_en),
                    "Assisto: your %s was changed" % what_en)
        body = (bn + "\n\n— — —\n\n" + en) if lang != "en" else (en + "\n\n— — —\n\n" + bn)
        return bool(email_sender.send_email(to, subj, body, purpose="security_alert")["ok"])
    except Exception:  # noqa: BLE001
        return False


def _alert_sms(user, to, link, lang):
    try:
        from . import otp, sms_service
        if not otp.sms_available():
            return False
        text = pick(lang,
                    "Assisto: আপনার অ্যাকাউন্টের নম্বর বদলানো হয়েছে। আপনি না করলে: %s" % link,
                    "Assisto: your account's phone number was changed. Not you? %s" % link)
        return bool(sms_service.send_sms(to, text, "otp", user=user)["ok"])
    except Exception:  # noqa: BLE001
        return False


def _alert_push(user, kind, new_masked):
    try:
        from .push import push_to_user
        if kind == "email":
            t_bn, t_en = "আপনার ইমেইল বদলানো হয়েছে", "Your email was changed"
        else:
            t_bn, t_en = "আপনার ফোন নম্বর বদলানো হয়েছে", "Your phone number was changed"
        return push_to_user(user, "family_alert", t_bn, t_en,
                            "আপনি না করলে সেটিংস → অ্যাকাউন্ট ও নিরাপত্তা দেখুন।",
                            "Not you? Open Settings → Account & security.",
                            data={"type": "account_security"}) > 0
    except Exception:  # noqa: BLE001
        return False


def find_undo(raw):
    from .models import IdentityChange
    if not raw or len(raw) > 128:
        return None
    return IdentityChange.objects.select_related("user").filter(undo_hash=_sha(raw)).first()


def undo_change(ch, now=None):
    """'This was not me': revert, sign out everywhere, lock 7 days.
    Returns 'ok' | 'done_already' | 'expired'."""
    now = now or timezone.now()
    if ch.undone_at:
        return "done_already"
    if ch.undo_expires_at <= now:
        return "expired"
    from .models import IdentityChange, User
    if not IdentityChange.objects.filter(pk=ch.pk, undone_at__isnull=True).update(undone_at=now):
        return "done_already"
    u = User.objects.get(pk=ch.user_id)
    reverted = False
    if ch.kind == "email":
        from .models import EmailVerification
        from . import otp
        if ch.old_value and not otp.email_taken_by_other(u, ch.old_value):
            EmailVerification.objects.update_or_create(
                user=u, defaults={"email": ch.old_value, "verified_at": now})
            u.email = ch.old_value
            u.save(update_fields=["email"])
            reverted = True
        else:
            EmailVerification.objects.filter(user=u).delete()
    else:
        from .phone import variants, sync_phone_hash, canonical_phone
        old = ch.old_value
        taken = old and User.objects.filter(phone__in=variants(canonical_phone(old) or old)
                                            or [old]).exclude(pk=u.pk).exists()
        if old and not taken:
            fields = ["phone"]
            if u.username == u.phone and not User.objects.filter(username=old).exclude(
                    pk=u.pk).exists():
                u.username = old
                fields.append("username")
            u.phone = old
            u.save(update_fields=fields)
            try:
                sync_phone_hash(u)
                from .otp import mark_verified
                mark_verified(u, canonical_phone(old) or old)
            except Exception:  # noqa: BLE001
                pass
            reverted = True
    from .device_sessions import revoke_all
    revoke_all(u, reason="not_me")
    st = state(u)
    st.identity_locked_until = now + LOCK_AFTER_NOT_ME
    st.save(update_fields=["identity_locked_until"])
    _log(u, "account.identity_not_me", kind=ch.kind, reverted=reverted)
    return "ok"


def note_password_changed(user, now=None):
    st = state(user)
    st.password_changed_at = now or timezone.now()
    st.save(update_fields=["password_changed_at"])


# ------------------------------------------------------------------- nudge
def nudge(user, now=None):
    """{"show": bool, "stage": 0|1} — the gentle 'add an email' card."""
    now = now or timezone.now()
    from .otp import verified_email
    if verified_email(user) or not (user.phone or "").strip():
        return {"show": False, "stage": None}
    from .models import AccountSecurityState
    st = AccountSecurityState.objects.filter(user=user).first()
    n = st.email_nudge_count if st else 0
    if n <= 0:
        return {"show": True, "stage": 0}
    if n < NUDGE_MAX and st.email_nudge_last_at and now - st.email_nudge_last_at >= NUDGE_GAP:
        return {"show": True, "stage": 1}
    return {"show": False, "stage": None}


def nudge_seen(user, action, now=None):
    st = state(user)
    st.email_nudge_count = NUDGE_MAX if action == "added" else min(
        NUDGE_MAX, st.email_nudge_count + 1)
    st.email_nudge_last_at = now or timezone.now()
    st.save(update_fields=["email_nudge_count", "email_nudge_last_at"])
    return nudge(user)


# --------------------------------------------------------- forgot password
def recovery_options(canon):
    """Where a password-reset code can go for this phone. SMS only when the
    account has no verified email (or email sending is off)."""
    from . import otp
    from .email_sender import mask_email
    user = otp.find_user_by_phone(canon) if canon else None
    em = ""
    if user is not None and user.is_active and otp.email_available():
        v = otp.verified_email(user)
        em = mask_email(v) if v else ""
    return {"ok": True, "sms": otp.sms_available(), "email": bool(em),
            "email_masked": em, "support": True}


# -------------------------------------------------------- support recovery
class RecoveryError(Exception):
    def __init__(self, reason, status=400, **extra):
        super().__init__(reason)
        self.reason, self.status, self.extra = reason, status, extra


MSG = {
    "bad_phone": ("সঠিক বাংলাদেশি মোবাইল নম্বর দিন (01XXXXXXXXX)।",
                  "Enter a valid Bangladeshi mobile number (01XXXXXXXXX)."),
    "same_phone": ("নতুন নম্বরটি হারানো নম্বর থেকে আলাদা হতে হবে।",
                   "The new number must be different from the lost one."),
    "bad_otp": ("নতুন নম্বরের যাচাই কোড সঠিক নয় বা মেয়াদ শেষ। আবার কোড চান।",
                "The code for your new number is wrong or expired. Ask for a new one."),
    "name_required": ("অ্যাকাউন্টে যে নাম ছিল সেটি লিখুন।", "Type the name on the account."),
    "use_email": ("এই অ্যাকাউন্টে যাচাই-করা ইমেইল আছে — 'পাসওয়ার্ড ভুলে গেছি' থেকে ইমেইলে কোড নিন।",
                  "This account has a verified email — use 'Forgot password' and get the code by email."),
    "already_open": ("এই নম্বরের একটি অনুরোধ আগে থেকেই খোলা আছে।",
                     "A request for this number is already open."),
    "rate_limited": ("অনেকবার চেষ্টা হয়েছে। কাল আবার চেষ্টা করুন।",
                     "Too many requests. Please try again tomorrow."),
    "not_found": ("অনুরোধটি পাওয়া যায়নি।", "Request not found."),
    "not_ready": ("এখনো শেষ করা যাবে না — নিরাপত্তা অপেক্ষা বা রিভিউ চলছে।",
                  "Not yet — the security hold or the review is still running."),
    "weak_password": ("পাসওয়ার্ড অন্তত ৮ অক্ষরের হতে হবে।", "Use at least 8 characters."),
    "sent": ("অনুরোধ পাঠানো হয়েছে। নিরাপত্তার জন্য অন্তত ৪৮ ঘণ্টা লাগবে।",
             "Request sent. For your safety it takes at least 48 hours."),
    "done": ("অ্যাকাউন্ট ফেরত পেয়েছেন। নতুন পাসওয়ার্ড দিয়ে ঢুকেছেন।",
             "Your account is back. You're signed in with the new password."),
}


def msg(reason, lang):
    bn, en = MSG.get(reason, ("কিছু একটা ভুল হয়েছে।", "Something went wrong."))
    return pick(lang, bn, en)


def _norm_name(s):
    return " ".join(str(s or "").casefold().split())


def _score(user, data):
    """Match RESULTS only (booleans / counts) — the raw answers are not kept
    (the typed name is, so a reviewer can compare spelling)."""
    proof = {}
    pts = 0
    typed = _norm_name(data.get("name"))
    real = _norm_name(getattr(user, "name", ""))
    if typed and real and typed == real:
        proof["name"] = "exact"
        pts += 25
    elif typed and real and (set(typed.split()) & set(real.split())):
        proof["name"] = "partial"
        pts += 12
    else:
        proof["name"] = "no"
    try:
        y = int(data.get("signup_year") or 0)
        m = int(data.get("signup_month") or 0)
    except (TypeError, ValueError):
        y, m = 0, 0
    joined = timezone.localtime(user.date_joined) if getattr(user, "date_joined", None) else None
    if joined and y == joined.year:
        if m and m == joined.month:
            proof["signup"] = "month"
            pts += 20
        else:
            proof["signup"] = "year"
            pts += 10
    else:
        proof["signup"] = "no" if y else "skipped"
    names = [_norm_name(n) for n in (data.get("circle_names") or [])[:3] if _norm_name(n)]
    hits = 0
    if names:
        from .models import CircleMember
        known = set()
        for cm in (CircleMember.objects.filter(user=user, state="accepted")
                   .select_related("peer_user")[:500]):
            for n in (cm.name, getattr(cm.peer_user, "name", "") if cm.peer_user else ""):
                if _norm_name(n):
                    known.add(_norm_name(n))
        for n in names:
            if n in known or any(n in k or k in n for k in known if len(k) >= 3 and len(n) >= 3):
                hits += 1
    proof["circle"] = "%d/%d" % (hits, len(names))
    pts += 10 * hits
    pw = str(data.get("old_password") or "")
    if pw:
        ok = bool(user.has_usable_password() and user.check_password(pw))
        proof["password"] = "yes" if ok else "no"
        pts += 25 if ok else 0
    else:
        proof["password"] = "skipped"
    proof["account_age_days"] = (timezone.now() - user.date_joined).days \
        if getattr(user, "date_joined", None) else None
    return proof, min(100, pts)


def _family_for(user, raw_phone):
    """The My Circle FAMILY member (accepted, unblocked, with an account)
    whose number was typed, or None."""
    from .phone import canonical_phone, variants
    c = canonical_phone(raw_phone or "")
    if not c:
        return None
    from .circle_family import family_member_ids
    from .models import CircleMember
    ids = family_member_ids(user)
    if not ids:
        return None
    vs = variants(c) or [c]
    for cm in CircleMember.objects.filter(pk__in=ids).select_related("peer_user"):
        pu = cm.peer_user
        if pu is None or not pu.is_active:
            continue
        if (cm.phone and cm.phone in vs) or (pu.phone and pu.phone in vs):
            return pu
    return None


def start_request(data, request=None, lang="bn", now=None):
    """Create a support recovery request. Returns (row, raw_secret)."""
    from . import otp
    from .models import RecoveryRequest
    now = now or timezone.now()
    acct = otp.normalize_bd_phone(data.get("account_phone"))
    contact = otp.normalize_bd_phone(data.get("contact_phone"))
    if not acct or not contact:
        raise RecoveryError("bad_phone")
    if acct == contact:
        raise RecoveryError("same_phone")
    if not _norm_name(data.get("name")):
        raise RecoveryError("name_required")
    ip = otp.client_ip(request) if request is not None else ""
    if ip and RecoveryRequest.objects.filter(
            ip=ip, created_at__gt=now - timedelta(days=1)).count() >= REQ_PER_IP_DAY:
        raise RecoveryError("rate_limited", 429)
    if RecoveryRequest.objects.filter(
            account_phone=acct, created_at__gt=now - timedelta(days=30)).count() \
            >= REQ_PER_ACCOUNT_30D:
        raise RecoveryError("rate_limited", 429)
    if RecoveryRequest.objects.filter(account_phone=acct,
                                      state__in=("pending", "approved")).exists():
        raise RecoveryError("already_open", 409)
    # the NEW number must be proven by an SMS code (purpose account_recovery)
    if otp.consume_proof(data.get("contact_otp_proof"), "account_recovery", contact) is None:
        raise RecoveryError("bad_otp", 403)
    user = otp.find_user_by_phone(acct)
    if user is not None and not user.is_active:
        user = None
    if user is not None and otp.verified_email(user):
        from .email_sender import mask_email
        raise RecoveryError("use_email", 409, email_masked=mask_email(otp.verified_email(user)))
    raw = secrets.token_urlsafe(24)
    ref = secrets.token_hex(4).upper()
    while RecoveryRequest.objects.filter(ref=ref).exists():
        ref = secrets.token_hex(4).upper()
    row = RecoveryRequest(
        user=user, ref=ref, secret_hash=_sha(raw), account_phone=acct,
        contact_phone=contact, typed_name=str(data.get("name") or "")[:120],
        hold_until=now + timedelta(hours=HOLD_HOURS), created_at=now, ip=ip,
        device_id=(otp.device_id(request) if request is not None else "")[:64])
    if user is None:
        # unknown number: the same answer (no enumeration), nothing to review
        row.state = "rejected"
        row.review_note = "no_account"
        row.save()
        return row, raw
    row.proof, row.score = _score(user, data)
    fam = _family_for(user, data.get("family_phone"))
    if fam is not None:
        row.family_user = fam
        row.family_state = "pending"
    row.proof["family_asked"] = bool(str(data.get("family_phone") or "").strip())
    row.proof["family_matched"] = fam is not None
    row.save()
    _notify_owner_devices(user, row)
    if fam is not None:
        _notify_family(fam, user)
    _log(user, "account.recovery_requested", ref=ref, family=row.family_state)
    return row, raw


def _notify_owner_devices(user, row):
    """The account's signed-in phones (if any are still with the owner) get a
    push, and the account number an SMS: 'not you? cancel'."""
    try:
        from .push import push_to_user
        push_to_user(user, "family_alert",
                     "কেউ আপনার অ্যাকাউন্ট ফেরত চেয়েছেন", "Someone asked to recover your account",
                     "আপনি না হলে সেটিংস → অ্যাকাউন্ট ও নিরাপত্তা থেকে বাতিল করুন।",
                     "Not you? Cancel it in Settings → Account & security.",
                     data={"type": "account_security"})
    except Exception:  # noqa: BLE001
        pass
    try:
        from . import otp, sms_service
        if otp.sms_available():
            sms_service.send_sms(
                row.account_phone,
                "Assisto: কেউ আপনার অ্যাকাউন্ট ফেরত চেয়েছেন (৪৮ ঘণ্টা অপেক্ষা)। আপনি না হলে "
                "অ্যাপে সেটিংস > অ্যাকাউন্ট ও নিরাপত্তা থেকে বাতিল করুন।",
                "otp", user=user)
    except Exception:  # noqa: BLE001
        pass


def _notify_family(fam, user):
    try:
        from .push import push_to_user
        nm = (user.name or "").strip() or "—"
        push_to_user(fam, "family_alert",
                     "%s অ্যাকাউন্ট ফেরত চাইছেন — আপনি নিশ্চিত করবেন?" % nm,
                     "%s is recovering their account — can you confirm?" % nm,
                     "সেটিংস → অ্যাকাউন্ট ও নিরাপত্তা খুলুন।",
                     "Open Settings → Account & security.",
                     data={"type": "account_security"})
    except Exception:  # noqa: BLE001
        pass


def by_secret(ref, raw):
    from .models import RecoveryRequest
    if not ref or not raw:
        return None
    row = RecoveryRequest.objects.filter(ref=str(ref).strip().upper()[:12]).first()
    if row is None or not secrets.compare_digest(row.secret_hash, _sha(raw)):
        return None
    return row


def public_state(row, now=None):
    """What the person on the new phone sees. A request for an unknown
    number looks exactly like a pending one until its hold ends."""
    now = now or timezone.now()
    _expire(row, now)
    st = row.state
    if row.user_id is None:
        st = "pending" if now < row.hold_until else "rejected"
    elif st == "approved":
        st = "ready" if now >= row.hold_until else "approved_waiting"
    from .otp import mask
    return {"ok": True, "ref": row.ref, "state": st,
            "hold_until": row.hold_until.isoformat(),
            "hold_hours": HOLD_HOURS,
            "family_state": row.family_state if row.user_id else "none",
            "contact_masked": mask(row.contact_phone)}


def _expire(row, now):
    if row.state == "approved" and now > row.hold_until + COMPLETE_WINDOW:
        row.state = "expired"
        row.save(update_fields=["state"])
    elif row.state == "pending" and now > row.hold_until + timedelta(days=30):
        row.state = "expired"
        row.save(update_fields=["state"])


def complete(row, data, request=None, lang="bn", now=None):
    """Approved + hold over + new-number code: new password, the account's
    phone moves to the proven new number, every old device signed out.
    Returns the sign-in token."""
    from . import otp
    from .device_sessions import login_token, revoke_all
    now = now or timezone.now()
    _expire(row, now)
    if row.user_id is None or row.state != "approved" or now < row.hold_until \
            or row.family_state == "denied":
        raise RecoveryError("not_ready", 409)
    pw = str(data.get("password") or "")
    from . import reset as reset_logic
    ok_pw, pw_msg = reset_logic.validate_password(pw, lang)
    if not ok_pw:
        raise RecoveryError("weak_password", 400, message=pw_msg)
    if otp.consume_proof(data.get("otp_proof"), "account_recovery", row.contact_phone) is None:
        raise RecoveryError("bad_otp", 403)
    from .models import RecoveryRequest, User
    if not RecoveryRequest.objects.filter(pk=row.pk, state="approved").update(
            state="completed", completed_at=now):
        raise RecoveryError("not_ready", 409)
    u = User.objects.get(pk=row.user_id)
    u.set_password(pw)
    u.save(update_fields=["password"])
    revoke_all(u, reason="recovered")
    note_password_changed(u, now)
    old = u.phone or ""
    from .phone import variants, sync_phone_hash
    if row.contact_phone != otp.normalize_bd_phone(old) and not User.objects.filter(
            phone__in=variants(row.contact_phone) or [row.contact_phone]).exclude(
            pk=u.pk).exists():
        fields = ["phone"]
        if old and u.username == old and not User.objects.filter(
                username=row.contact_phone).exclude(pk=u.pk).exists():
            u.username = row.contact_phone
            fields.append("username")
        u.phone = row.contact_phone
        u.save(update_fields=fields)
        try:
            sync_phone_hash(u)
        except Exception:  # noqa: BLE001
            pass
        record_change(u, "phone", old, row.contact_phone, lang=lang, now=now)
    otp.mark_verified(u, row.contact_phone)
    _log(u, "account.recovered", ref=row.ref)
    return u, login_token(u, request)


def cancel_by_owner(user, pk):
    from .models import RecoveryRequest
    n = RecoveryRequest.objects.filter(pk=pk, user=user,
                                       state__in=("pending", "approved")).update(
        state="cancelled", reviewed_at=timezone.now(), review_note="cancelled_by_owner")
    if n:
        _log(user, "account.recovery_cancelled", id=pk)
    return bool(n)


def family_decide(fam_user, pk, decision):
    from .models import RecoveryRequest
    if decision not in ("confirm", "deny"):
        return False
    n = RecoveryRequest.objects.filter(pk=pk, family_user=fam_user, family_state="pending",
                                       state__in=("pending", "approved")).update(
        family_state="confirmed" if decision == "confirm" else "denied",
        family_decided_at=timezone.now())
    return bool(n)


def admin_decide(row, action, actor, note=""):
    """Owner Admin review. Approve never skips the hold (complete() checks
    hold_until); a family 'denied' cannot be approved."""
    from .models import RecoveryRequest
    now = timezone.now()
    if row.user_id is None or row.state != "pending":
        return "invalid"
    if action == "approve":
        if row.family_state == "denied":
            return "family_denied"
        st = "approved"
    elif action == "reject":
        st = "rejected"
    else:
        return "invalid"
    n = RecoveryRequest.objects.filter(pk=row.pk, state="pending").update(
        state=st, reviewed_at=now, reviewed_by=actor, review_note=(note or "")[:300])
    if not n:
        return "invalid"
    return ""


def open_for_owner(user):
    from .models import RecoveryRequest
    from .otp import mask
    return [{"id": r.id, "created_at": r.created_at.isoformat(),
             "hold_until": r.hold_until.isoformat(), "state": r.state,
             "contact_masked": mask(r.contact_phone)}
            for r in RecoveryRequest.objects.filter(user=user,
                                                    state__in=("pending", "approved"))[:5]]


def open_for_family(fam_user):
    from .models import RecoveryRequest
    return [{"id": r.id, "name": (r.user.name or "").strip() if r.user else "",
             "created_at": r.created_at.isoformat()}
            for r in RecoveryRequest.objects.filter(
                family_user=fam_user, family_state="pending",
                state__in=("pending", "approved")).select_related("user")[:5]]
