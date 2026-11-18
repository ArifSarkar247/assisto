"""
gap-recovery (board row 52): "new sign-in" alert — Google Account standard.

Before this, a sign-in on a NEW phone (a thief who learned the password, or
the owner recovering after losing a phone) told nobody: the other signed-in
phones got no push and the verified email got no mail. Now every sign-in
that creates a device session on a phone this account never used before:

  * pushes "New sign-in on <phone name>" to the account's OTHER phones, and
  * emails the VERIFIED address (security mail = critical category, so the
    daily cap keeps it ahead of reports),

both with the way out: "Not you? Account & security -> sign out that phone
and change your password". Nothing is sent for the first ever sign-in
(sign-up), for a phone that was signed in before, or for older builds that
do not send a device id. It never blocks or slows the sign-in: the mail
goes in a background thread after the response (PUSH_SYNC=True runs it
inline for tests / CI). No phone, address or code is logged.
"""
import logging
import threading

from django.conf import settings
from django.db import transaction
from django.utils import timezone

log = logging.getLogger("assisto.signin_alert")

METHOD_TEXT = {
    "password": ("পাসওয়ার্ড দিয়ে", "with the password"),
    "code": ("একবারের কোড দিয়ে", "with a one-time code"),
    "support": ("সাপোর্টের মাধ্যমে অ্যাকাউন্ট উদ্ধার করে", "through support account recovery"),
}


def is_new_device(user, session):
    """True when `session` is on a phone this account never signed in on
    before AND the account had an earlier sign-in (so sign-up is quiet)."""
    from .models import DeviceSession
    from rest_framework.authtoken.models import Token
    if session is None or not (session.device_id or "").strip():
        return False
    earlier = DeviceSession.objects.filter(user=user).exclude(pk=session.pk)
    if not earlier.exists() and not Token.objects.filter(user=user).exists():
        return False
    return not earlier.filter(device_id=session.device_id,
                              device_name=session.device_name).exists()


BN_MONTHS = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
             "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")


def _bd_time(now, lang="en"):
    from datetime import timedelta, timezone as dtz
    from .email_templates import bn_digits
    t = now.astimezone(dtz(timedelta(hours=6)))
    if lang == "bn":
        return bn_digits("%d %s %d, %02d:%02d" % (t.day, BN_MONTHS[t.month - 1], t.year,
                                                  t.hour, t.minute))
    return t.strftime("%d %b %Y, %H:%M")


def texts(device_name, method, now, lang="bn"):
    """(title_bn, title_en, body_bn, body_en) — plain words, no PII except
    the phone model name the person's own phone reported."""
    name = (device_name or "").strip()[:60] or "Android"
    m_bn, m_en = METHOD_TEXT.get(method, METHOD_TEXT["password"])
    title_bn = "নতুন ফোনে আপনার Assisto-তে সাইন-ইন: %s" % name
    title_en = "New sign-in to your Assisto on %s" % name
    body_bn = ("%s (বাংলাদেশ সময়) আপনার অ্যাকাউন্টে নতুন একটি ফোন (%s) থেকে %s সাইন-ইন হয়েছে।\n\n"
               "আপনি হলে কিছু করতে হবে না।\n\n"
               "আপনি না হলে এখনই: Assisto খুলুন → সেটিংস → অ্যাকাউন্ট ও নিরাপত্তা → ঐ ফোনের পাশে "
               "\"সাইন-আউট\" চাপুন, তারপর পাসওয়ার্ড বদলান। ফোন হারালে একই পাতায় "
               "\"অন্য সব ফোন থেকে সাইন-আউট\" চাপুন।"
               % (_bd_time(now, "bn"), name, m_bn))
    body_en = ("At %s (Bangladesh time) your account was signed in %s on a new phone (%s).\n\n"
               "If this was you, there is nothing to do.\n\n"
               "If it was NOT you: open Assisto → Settings → Account & security → tap "
               "\"Sign out\" next to that phone, then change your password. Lost a phone? "
               "Tap \"Sign out all other phones\" on the same page."
               % (_bd_time(now), m_en, name))
    return title_bn, title_en, body_bn, body_en


def _send(user_id, session_id, method):
    from .models import DeviceSession, User
    from . import email_sender, email_templates as ET, otp
    try:
        user = User.objects.get(pk=user_id)
        s = DeviceSession.objects.get(pk=session_id)
    except Exception:  # noqa: BLE001
        return {"push": 0, "email": False}
    lang = "en" if (getattr(user, "language", "") or "").startswith("en") else "bn"
    tb, te, bb, be = texts(s.device_name, method, s.created_at or timezone.now(), lang)
    out = {"push": 0, "email": False}
    try:
        from .push import push_to_user
        out["push"] = push_to_user(
            user, "family_alert", tb, te,
            "আপনি না হলে: সেটিংস → অ্যাকাউন্ট ও নিরাপত্তা → ঐ ফোন সাইন-আউট করুন।",
            "Not you? Settings → Account & security → sign that phone out.",
            data={"type": "account_security", "reason": "new_signin"}) or 0
    except Exception:  # noqa: BLE001
        pass
    addr = otp.verified_email(user)
    if addr:
        try:
            subject, text, html = ET.render_notice(lang, tb, te, bb, be)
            r = email_sender.send_email(addr, subject, text, purpose="security_alert", html=html)
            out["email"] = bool(r.get("ok"))
        except Exception:  # noqa: BLE001
            pass
    log.info("signin alert method=%s push=%s email=%s", method, out["push"], out["email"])
    return out


def maybe_alert(user, session, method="password"):
    """Called right after a device session was created. Never raises."""
    try:
        if not is_new_device(user, session):
            return False
        uid, sid = user.pk, session.pk
        if getattr(settings, "PUSH_SYNC", False):
            transaction.on_commit(lambda: _send(uid, sid, method))
        else:
            transaction.on_commit(lambda: threading.Thread(
                target=_send, args=(uid, sid, method), daemon=True).start())
        return True
    except Exception:  # noqa: BLE001
        return False
