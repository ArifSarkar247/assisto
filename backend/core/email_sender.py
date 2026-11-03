"""
Company email sender (smsotp) — OTP backup by email. Pluggable, capped,
never logs the body or the full address.

    send_email(to, subject, body, purpose="otp") -> {ok, reason, provider}
    cap_state()                                 -> {cap, used, left, near, blocked}
    available()                                 -> bool (entry CONNECTED + under cap)
    otp_email(code, lang, ttl_seconds)          -> (subject, body)
    check(cfg, test_to=None)                    -> (ok, detail)  (Integrations Test)

Sender today: SMTP (Gmail, smtp.gmail.com:587 STARTTLS, app password) from
the "smtp_email" integration entry. Amazon SES later: add a class with the
same `send(to, subject, body) -> (ok, detail)` and register it in SENDERS;
Owner Admin → Pricing → email.provider picks it. Nothing else changes.

Gmail limit: consumer Gmail allows about 500 recipients per rolling 24 h
(Google Workspace about 2,000). Our cap (Pricing → email.daily_cap, default
400) is counted over the same rolling 24 h from EmailLog; past `near_cap_pct`
the app is told to prefer SMS, at the cap email OTP is refused honestly.
Network seam for tests: `smtplib.SMTP` (patched in tests — no real mail).
"""
import hashlib
import logging
import smtplib
import socket
import time
from datetime import timedelta
from email.message import EmailMessage
from email.utils import formataddr, make_msgid

from zoneinfo import ZoneInfo

from django.utils import timezone

TIMEOUT = 20
BD_TZ = ZoneInfo("Asia/Dhaka")
# smtpfix: every send attempt + result goes to the backend log (journalctl) —
# masked address, purpose, ok/error, duration; never the body, code or password
# Production has no LOGGING dict (root = WARNING), so like core/push.py this
# logger carries its own stderr handler (gunicorn -> journal):
#   journalctl -u assisto | grep "email send"
log = logging.getLogger("assisto.email")
if not log.handlers:
    _h = logging.StreamHandler()
    _h.setFormatter(logging.Formatter("%(levelname)s %(name)s %(message)s"))
    log.addHandler(_h)
    log.setLevel(logging.INFO)
    log.propagate = False
FOOTER_BN = "Assisto — AXON Dynamic"
FOOTER_EN = "Assisto by AXON Dynamic"


# ------------------------------------------------------------------ helpers
def normalize_email(raw):
    """Lower-cased, trimmed address or None when it doesn't look like one."""
    s = str(raw or "").strip().lower()
    if len(s) > 254 or s.count("@") != 1 or any(c.isspace() for c in s):
        return None
    local, _, dom = s.partition("@")
    if not local or "." not in dom or dom.startswith(".") or dom.endswith(".") \
            or ".." in dom:
        return None
    return s


def mask_email(addr):
    a = normalize_email(addr) or ""
    if not a:
        return ""
    local, _, dom = a.partition("@")
    keep = local[:2] if len(local) > 2 else local[:1]
    return "%s%s@%s" % (keep, "•" * max(1, len(local) - len(keep)), dom)


def email_hash(addr):
    return hashlib.sha256((normalize_email(addr) or "").encode("utf-8")).hexdigest()


def _cfg_caps():
    from .logic import pricing as P
    try:
        from . import billing
        return P.email_cfg(billing.get_config().data)
    except Exception:  # noqa: BLE001
        return P.email_cfg({})


# ------------------------------------------------------------------ senders
class SmtpSender:
    """SMTP with STARTTLS (port 587) or implicit TLS (port 465)."""
    name = "smtp"

    def __init__(self, cfg):
        c = dict(cfg or {})
        self.host = str(c.get("host") or "smtp.gmail.com").strip()
        try:
            self.port = int(str(c.get("port") or "587").strip())
        except ValueError:
            self.port = 587
        self.username = str(c.get("username") or "").strip()
        # Google shows the app password in 4 groups of 4 — spaces are not part of it
        self.password = str(c.get("app_password") or "").replace(" ", "").strip()
        self.from_name = str(c.get("from_name") or "Assisto").strip()[:60]
        self.from_email = str(c.get("from_email") or self.username).strip()

    def complete(self):
        return bool(self.host and self.username and self.password and self.from_email)

    def _connect(self):
        if self.port == 465:
            s = smtplib.SMTP_SSL(self.host, self.port, timeout=TIMEOUT)
        else:
            s = smtplib.SMTP(self.host, self.port, timeout=TIMEOUT)
            s.ehlo()
            s.starttls()
            s.ehlo()
        s.login(self.username, self.password)
        return s

    def login_check(self):
        if not self.complete():
            return False, "config: host / username / app password missing"
        try:
            s = self._connect()
            try:
                s.quit()
            except Exception:  # noqa: BLE001
                pass
            return True, "login OK"
        except smtplib.SMTPAuthenticationError:
            return False, ("login refused — check the 16-character app password "
                           "(2-Step Verification must be on)")
        except (smtplib.SMTPException, socket.error, OSError) as e:
            return False, "network: %s" % type(e).__name__

    def send(self, to, subject, body):
        if not self.complete():
            return False, "config: host / username / app password missing"
        msg = EmailMessage()
        msg["Subject"] = subject
        msg["From"] = formataddr((self.from_name, self.from_email))
        msg["To"] = to
        msg["Message-ID"] = make_msgid(domain=(self.from_email.partition("@")[2] or None))
        msg["Auto-Submitted"] = "auto-generated"
        msg.set_content(body)           # plain text only: no images, no tracking
        try:
            s = self._connect()
            try:
                s.send_message(msg)
            finally:
                try:
                    s.quit()
                except Exception:  # noqa: BLE001
                    pass
            return True, "accepted"
        except smtplib.SMTPAuthenticationError as e:
            return False, "%s লগইন প্রত্যাখ্যাত — App password ভুল / bad credentials — check the app password" % e.smtp_code
        except smtplib.SMTPRecipientsRefused as e:
            codes = [str(v[0]) for v in (e.recipients or {}).values()
                     if isinstance(v, tuple) and v]
            return False, ("%s প্রাপকের ঠিকানা গ্রহণ হয়নি — ঠিকানা দেখুন / recipient refused — check the address"
                           % (codes[0] if codes else "")).strip()
        except (smtplib.SMTPDataError, smtplib.SMTPSenderRefused) as e:
            # Gmail 550 5.4.5 "Daily user sending quota exceeded"
            txt = _smtp_text(getattr(e, "smtp_error", b""))
            if "5.4.5" in txt or "quota" in txt.lower():
                return False, ("%s Gmail-এর দৈনিক পাঠানোর সীমা শেষ / daily sending quota reached (%s)"
                               % (e.smtp_code, txt))[:280]
            return False, ("%s SMTP ত্রুটি / SMTP error (%s)" % (e.smtp_code, txt))[:280]
        except smtplib.SMTPResponseException as e:
            return False, ("%s SMTP ত্রুটি / SMTP error (%s)"
                           % (e.smtp_code, _smtp_text(e.smtp_error)))[:280]
        except (socket.timeout, TimeoutError):
            return False, "নেটওয়ার্ক টাইমআউট / network timeout — the SMTP server did not answer"
        except (smtplib.SMTPException, socket.error, OSError) as e:
            return False, "নেটওয়ার্ক ত্রুটি / network error: %s" % type(e).__name__


def _smtp_text(raw):
    """Short one-line server reply (Gmail never echoes the password)."""
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    return " ".join(str(raw or "").split())[:90]


# Amazon SES drops in here later (see owner_actions/SMS_EMAIL_SETUP_BN.md).
SENDERS = {"smtp": SmtpSender}


def _sender():
    from . import integrations
    caps = _cfg_caps()
    cls = SENDERS.get(caps.get("provider") or "smtp", SmtpSender)
    return cls(integrations.get("smtp_email"))


def configured():
    """The email entry is CONNECTED (its honest Test passed)."""
    try:
        from . import integrations
        return integrations.is_enabled("smtp_email")
    except Exception:  # noqa: BLE001
        return False


# ------------------------------------------------------------------ cap
def cap_state(now=None):
    from .models import EmailLog
    now = now or timezone.now()
    caps = _cfg_caps()
    cap = int(caps["daily_cap"])
    used = EmailLog.objects.filter(created_at__gt=now - timedelta(hours=24),
                                   status="sent").count()
    near_at = (cap * int(caps["near_cap_pct"])) // 100
    return {"cap": cap, "used": used, "left": max(0, cap - used),
            "near": cap > 0 and used >= near_at, "blocked": used >= cap}


def available():
    if not configured():
        return False
    try:
        return not cap_state()["blocked"]
    except Exception:  # noqa: BLE001
        return False


def _log(to, purpose, provider, status, detail="", ms=None):
    from .models import EmailLog
    masked = mask_email(to)
    log.info("email send purpose=%s to=%s provider=%s result=%s ms=%s detail=%s",
             purpose, masked or "-", provider, status,
             "-" if ms is None else int(ms), str(detail or "")[:160])
    try:
        EmailLog.objects.create(purpose=purpose[:16], to_hash=email_hash(to),
                                to_masked=masked[:80], provider=provider[:16],
                                status=status, detail=str(detail or "")[:200])
    except Exception as e:  # noqa: BLE001
        log.warning("email log row not saved (%s) purpose=%s to=%s",
                    type(e).__name__, purpose, masked or "-")


def send_email(to, subject, body, purpose="otp"):
    """Send one plain-text email through the configured sender, inside the
    rolling-24 h cap. Returns {ok, reason, provider}; reason ∈ ok |
    bad_email | email_not_configured | email_daily_cap | send_failed."""
    addr = normalize_email(to)
    if not addr:
        return {"ok": False, "reason": "bad_email", "provider": ""}
    if not configured():
        return {"ok": False, "reason": "email_not_configured", "provider": ""}
    st = cap_state()
    snd = _sender()
    if st["blocked"]:
        _log(addr, purpose, snd.name, "blocked", "daily cap")
        return {"ok": False, "reason": "email_daily_cap", "provider": snd.name}
    t0 = time.monotonic()
    ok, detail = snd.send(addr, subject, body)
    _log(addr, purpose, snd.name, "sent" if ok else "failed", detail,
         ms=(time.monotonic() - t0) * 1000)
    return {"ok": bool(ok), "reason": "ok" if ok else "send_failed", "provider": snd.name}


# ------------------------------------------------------------------ template
def otp_email(code, lang, ttl_seconds):
    """(subject, body) — plain bilingual text: no images, no links, no
    tracking, no personal names. The primary language comes first."""
    mins = max(1, int(ttl_seconds) // 60)
    bn_digits = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
    bn = ("আপনার Assisto যাচাই কোড: %s\n\n"
          "কোডটি %s মিনিট পর্যন্ত কাজ করবে। কাউকে এই কোড বলবেন না — "
          "Assisto কখনো ফোন বা মেসেজে এই কোড চায় না।\n"
          "আপনি এই কোড না চাইলে এই ইমেইলটি উপেক্ষা করুন; আপনার অ্যাকাউন্ট নিরাপদ আছে।"
          % (code, str(mins).translate(bn_digits)))
    en = ("Your Assisto verification code: %s\n\n"
          "It works for %d minutes. Never share this code — Assisto will never "
          "ask for it by phone or message.\n"
          "If you didn't ask for this code, ignore this email; your account is safe."
          % (code, mins))
    footer = ("\n\n—\n%s\n%s\nএটি স্বয়ংক্রিয় ইমেইল, উত্তর দেবেন না। / "
              "This is an automated email; please don't reply." % (FOOTER_BN, FOOTER_EN))
    if lang == "en":
        subject = "Your Assisto code: %s" % code
        body = en + "\n\n— — —\n\n" + bn + footer
    else:
        subject = "Assisto কোড: %s / Your Assisto code" % code
        body = bn + "\n\n— — —\n\n" + en + footer
    return subject, body


def test_email():
    subject = "Assisto test email / পরীক্ষামূলক ইমেইল"
    body = ("এটি Assisto-র ইমেইল সেটআপের একটি পরীক্ষা। এটি পেয়ে থাকলে সব ঠিক আছে।\n\n"
            "This is a test of Assisto's email setup. If you received it, it works."
            "\n\n—\n%s" % FOOTER_EN)
    return subject, body


def check(cfg, test_to=None):
    """Integrations Test: SMTP login (no mail sent) or, with a typed address,
    ONE real test email. Honest: never 'working' on a format check alone."""
    caps = _cfg_caps()
    snd = SENDERS.get(caps.get("provider") or "smtp", SmtpSender)(cfg)
    if test_to:
        addr = normalize_email(test_to)
        if not addr:
            return False, ("✗ টেস্ট ঠিকানাটি সঠিক ইমেইল নয় / "
                           "the test address is not a valid email")
        subject, body = test_email()
        t0 = time.monotonic()
        ok, detail = snd.send(addr, subject, body)
        _log(addr, "test", snd.name, "sent" if ok else "failed", detail,
             ms=(time.monotonic() - t0) * 1000)
        # smtpfix: the card shows exactly where + when it went, or why not
        when = timezone.now().astimezone(BD_TZ).strftime("%d %b %H:%M")
        masked = mask_email(addr)
        if ok:
            return True, ("✓ %s-এ পাঠানো হয়েছে, %s (বাংলাদেশ সময়) / Sent to %s at %s BD time"
                          " — check the inbox (and Spam)" % (masked, when, masked, when))
        return False, ("✗ %s · %s BD — যায়নি / not sent: %s"
                       % (masked, when, detail))[:300]
    ok, detail = snd.login_check()
    if ok:
        return True, "✓ SMTP লগইন সফল / SMTP login OK"
    return False, detail
