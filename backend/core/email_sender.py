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

emailrel (16 Nov): every failure is classified (classify): temporary errors
(network, 4xx) are retried after 1 s and 3 s, permanent ones never; a 5xx
about the recipient (5.1.x) puts the address on EmailSuppression ("please
check your email address"), Gmail bounce reports are read by
core/email_bounces.py; Gmail's "5.4.5 quota" pauses all mail for an hour and
tells the owner; under the cap codes + security mail go first, reports stop
at bulk_cap_pct (CATEGORY). Mail is plain text + branded HTML
(core/email_templates.py). Owner Admin → Email health = health().
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
FOOTER_BN = "Assisto — Axon Dynamics"
FOOTER_EN = "Assisto by Axon Dynamics"


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

    def send(self, to, subject, body, html=None, headers=None):
        """(ok, detail) — the old two-value form (Integrations Test)."""
        ok, _kind, _code, detail = self.send_ex(to, subject, body, html, headers)
        return ok, detail

    def build(self, to, subject, body, html=None, headers=None):
        msg = EmailMessage()
        msg["Subject"] = subject
        msg["From"] = formataddr((self.from_name, self.from_email))
        msg["To"] = to
        msg["Message-ID"] = make_msgid(domain=(self.from_email.partition("@")[2] or None))
        msg["Auto-Submitted"] = "auto-generated"
        msg["X-Auto-Response-Suppress"] = "All"
        for k, v in (headers or {}).items():
            msg[k] = v
        msg.set_content(body)           # plain-text part always (no tracking)
        if html:
            msg.add_alternative(html, subtype="html")   # emailrel: branded part
        return msg

    def send_ex(self, to, subject, body, html=None, headers=None):
        """(ok, kind, smtp_code, detail). kind: ok | temp | quota | bounce |
        rejected | auth | config — see classify()."""
        if not self.complete():
            return False, "config", "", "config: host / username / app password missing"
        msg = self.build(to, subject, body, html, headers)
        try:
            s = self._connect()
            try:
                s.send_message(msg)
            finally:
                try:
                    s.quit()
                except Exception:  # noqa: BLE001
                    pass
            return True, "ok", "250", "accepted"
        except Exception as e:  # noqa: BLE001 — classified below, never raised
            kind, code, detail = classify(e)
            return False, kind, code, detail


# emailrel: SMTP reply -> what to do. Temporary = try again (4xx, network);
# permanent = never retry. A 5xx about the RECIPIENT (5.1.x, "user unknown")
# is a hard bounce: the address goes on the suppression list.
_BOUNCE_WORDS = ("does not exist", "user unknown", "no such user", "address not found",
                 "unknown user", "mailbox unavailable", "invalid recipient",
                 "recipient address rejected", "no mailbox")
_QUOTA_WORDS = ("5.4.5", "quota", "sending limit", "limit exceeded")


def _enhanced(txt):
    import re
    m = re.search(r"\b([245])\.(\d{1,3})\.(\d{1,3})\b", txt or "")
    return m.group(0) if m else ""


def classify_reply(code, txt):
    """(kind) for one SMTP reply code + text."""
    try:
        code = int(code)
    except (TypeError, ValueError):
        code = 0
    low = (txt or "").lower()
    enh = _enhanced(txt)
    if code in (534, 535, 530) or enh.startswith("5.7.8") or enh.startswith("5.7.9"):
        return "auth"
    if enh.startswith("5.2.") or enh.startswith("4.2."):
        # the recipient's mailbox is full / disabled for now: not our quota,
        # not a dead address — no retry now, no suppression
        return "rejected" if code >= 500 else "temp"
    if any(w in low for w in _QUOTA_WORDS) and (code >= 500 or code in (421, 450, 451, 452)):
        # Gmail: 550 5.4.5 daily quota; 421 4.7.0 / 452 4.5.3 = slow down
        return "quota" if (code >= 500 or "5.4.5" in low) else "temp"
    if 400 <= code < 500:
        return "temp"
    if code >= 500:
        if enh.startswith("5.1.") or enh == "5.4.4" or any(w in low for w in _BOUNCE_WORDS):
            return "bounce"
        return "rejected"   # policy / spam / mailbox full / message refused
    return "temp"


def classify(e):
    """(kind, smtp_code, detail) for an exception from smtplib / sockets.
    The detail is the owner-facing Bangla / English line (no secrets)."""
    if isinstance(e, smtplib.SMTPAuthenticationError):
        return "auth", str(e.smtp_code), (
            "%s লগইন প্রত্যাখ্যাত — App password ভুল / bad credentials — check the app password"
            % e.smtp_code)
    if isinstance(e, smtplib.SMTPRecipientsRefused):
        vals = [v for v in (e.recipients or {}).values() if isinstance(v, tuple) and v]
        code = str(vals[0][0]) if vals else ""
        txt = _smtp_text(vals[0][1]) if vals and len(vals[0]) > 1 else ""
        kind = classify_reply(code or 550, txt)
        if kind == "rejected" and not _enhanced(txt).startswith("5.2."):
            kind = "bounce"          # the server refused THIS recipient
        return kind, code, ("%s প্রাপকের ঠিকানা গ্রহণ হয়নি — ঠিকানা দেখুন / recipient "
                            "refused — check the address %s" % (code, txt)).strip()[:280]
    if isinstance(e, (smtplib.SMTPDataError, smtplib.SMTPSenderRefused)):
        txt = _smtp_text(getattr(e, "smtp_error", b""))
        kind = classify_reply(e.smtp_code, txt)
        if kind == "quota":
            return kind, str(e.smtp_code), (
                "%s Gmail-এর দৈনিক পাঠানোর সীমা শেষ / daily sending quota reached (%s)"
                % (e.smtp_code, txt))[:280]
        return kind, str(e.smtp_code), ("%s SMTP ত্রুটি / SMTP error (%s)"
                                        % (e.smtp_code, txt))[:280]
    if isinstance(e, smtplib.SMTPResponseException):
        txt = _smtp_text(e.smtp_error)
        return classify_reply(e.smtp_code, txt), str(e.smtp_code), (
            "%s SMTP ত্রুটি / SMTP error (%s)" % (e.smtp_code, txt))[:280]
    if isinstance(e, (socket.timeout, TimeoutError)):
        return "temp", "", "নেটওয়ার্ক টাইমআউট / network timeout — the SMTP server did not answer"
    if isinstance(e, (smtplib.SMTPException, socket.error, OSError)):
        return "temp", "", "নেটওয়ার্ক ত্রুটি / network error: %s" % type(e).__name__
    return "temp", "", "ত্রুটি / error: %s" % type(e).__name__


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


# ------------------------------------------------------------------ priority
# emailrel: which mail may still go when the 24 h cap gets close.
#   critical — codes + security + account mail: up to the cap
#   normal   — notices (owner alerts, receipts): up to near_cap_pct
#   bulk     — reports / digests / marketing: up to bulk_cap_pct; unsubscribe
CATEGORY = {"otp": "critical", "security_alert": "critical", "security": "critical",
            "account": "critical", "reset": "critical", "test": "critical",
            "notice": "normal", "owner_alert": "normal", "receipt": "normal",
            "report": "bulk", "digest": "bulk", "marketing": "bulk"}
RETRY_DELAYS = (1.0, 3.0)      # seconds before attempt 2 and 3 (temporary errors only)
RETRY_BUDGET = 30.0            # never keep a request waiting longer than this
QUOTA_PAUSE_MIN = 60           # after Gmail says "daily quota", pause all mail this long
_sleep = time.sleep            # test seam


def category_of(purpose):
    return CATEGORY.get(str(purpose or ""), "normal")


# ------------------------------------------------------------------ cap
def cap_state(now=None):
    from .models import EmailLog
    now = now or timezone.now()
    caps = _cfg_caps()
    cap = int(caps["daily_cap"])
    used = EmailLog.objects.filter(created_at__gt=now - timedelta(hours=24),
                                   status="sent").count()
    near_at = (cap * int(caps["near_cap_pct"])) // 100
    bulk_at = (cap * int(caps.get("bulk_cap_pct", 70))) // 100
    quota_row = (EmailLog.objects.filter(
        created_at__gt=now - timedelta(minutes=QUOTA_PAUSE_MIN), error_kind="quota")
        .order_by("-created_at").first())
    provider_quota = quota_row is not None
    return {"cap": cap, "used": used, "left": max(0, cap - used),
            "near": cap > 0 and used >= near_at, "blocked": used >= cap or provider_quota,
            "near_at": near_at, "bulk_at": bulk_at, "bulk_stop": used >= bulk_at,
            "provider_quota": provider_quota,
            "quota_until": (quota_row.created_at + timedelta(minutes=QUOTA_PAUSE_MIN))
            if quota_row else None}


def allowed(category, st):
    """May mail of this category go now? (st = cap_state())."""
    if st["blocked"]:
        return False
    if category == "bulk":
        return not st["bulk_stop"]
    if category == "normal":
        return not st["near"]
    return True


def available():
    if not configured():
        return False
    try:
        return not cap_state()["blocked"]
    except Exception:  # noqa: BLE001
        return False


# ------------------------------------------------------------------ suppression
def suppression(addr, category="critical"):
    """The EmailSuppression row that stops mail of `category` to `addr`, or
    None. 'unsubscribed' stops bulk mail only."""
    from .models import EmailSuppression
    try:
        row = EmailSuppression.objects.filter(to_hash=email_hash(addr)).first()
    except Exception:  # noqa: BLE001
        return None
    if row is None:
        return None
    if row.reason == "unsubscribed" and category != "bulk":
        return None
    return row


def is_bouncing(addr):
    r = suppression(addr, "critical")
    return bool(r and r.reason in ("hard_bounce", "complaint"))


def suppress(addr, reason="hard_bounce", code="", detail=""):
    """Add / refresh an address on the suppression list. Never raises."""
    from .models import EmailSuppression
    a = normalize_email(addr)
    if not a:
        return None
    now = timezone.now()
    try:
        row, made = EmailSuppression.objects.get_or_create(
            to_hash=email_hash(a),
            defaults={"to_masked": mask_email(a)[:80], "reason": reason,
                      "code": str(code)[:12], "detail": str(detail)[:200]})
        if not made:
            row.hits += 1
            row.last_at = now
            # a bounce outranks an unsubscribe (it stops all mail)
            if reason != "unsubscribed":
                row.reason = reason
            row.code, row.detail = str(code)[:12] or row.code, str(detail)[:200] or row.detail
            row.save(update_fields=["hits", "last_at", "reason", "code", "detail"])
        log.info("email suppress to=%s reason=%s code=%s", mask_email(a), reason, code or "-")
        return row
    except Exception as e:  # noqa: BLE001
        log.warning("email suppress failed (%s)", type(e).__name__)
        return None


def unsuppress(addr):
    """The user proved the address again (re-verified) — mail may go."""
    from .models import EmailSuppression
    try:
        EmailSuppression.objects.filter(to_hash=email_hash(addr)).exclude(
            reason="unsubscribed").delete()
    except Exception:  # noqa: BLE001
        pass


def unsubscribe_token(addr):
    from django.core import signing
    return signing.dumps({"h": email_hash(addr), "m": mask_email(addr)},
                         salt="assisto.email.unsub")


def unsubscribe_url(addr):
    from django.conf import settings
    from .public_url import public_base_url
    base = public_base_url()
    return "%s/api/v1/email/unsubscribe?t=%s" % (base, unsubscribe_token(addr))


def _log(to, purpose, provider, status, detail="", ms=None, kind="", attempts=1):
    from .models import EmailLog
    masked = mask_email(to)
    log.info("email send purpose=%s to=%s provider=%s result=%s kind=%s tries=%s ms=%s detail=%s",
             purpose, masked or "-", provider, status, kind or "-", attempts,
             "-" if ms is None else int(ms), str(detail or "")[:160])
    try:
        EmailLog.objects.create(purpose=purpose[:16], to_hash=email_hash(to),
                                to_masked=masked[:80], provider=provider[:16],
                                status=status, detail=str(detail or "")[:200],
                                error_kind=str(kind or "")[:10],
                                category=category_of(purpose), attempts=attempts)
    except Exception as e:  # noqa: BLE001
        log.warning("email log row not saved (%s) purpose=%s to=%s",
                    type(e).__name__, purpose, masked or "-")


def _quota_hit_alert():
    """First provider-quota stop in 24 h -> tell the owner (push + in-app)."""
    from .models import EmailLog
    try:
        earlier = EmailLog.objects.filter(
            error_kind="quota", created_at__gt=timezone.now() - timedelta(hours=24)).count()
        if earlier > 1:
            return
        from . import push
        push.notify_owner(
            "ইমেইল: Gmail-এর দৈনিক সীমা শেষ / Email daily limit reached",
            "Gmail আজ আর ইমেইল নিচ্ছে না — কোড SMS-এ যাচ্ছে। Owner Admin → ইমেইল স্বাস্থ্য দেখুন। "
            "/ Gmail refused more mail today; codes go by SMS. See Owner Admin → Email health.")
    except Exception:  # noqa: BLE001
        pass


_REASON = {"temp": "send_failed", "quota": "email_daily_cap", "bounce": "email_bouncing",
           "rejected": "email_rejected", "auth": "send_failed", "config": "send_failed"}


def send_email(to, subject, body, purpose="otp", html=None, category=None,
               headers=None, bypass_suppression=False):
    """Send one email (plain text + optional HTML) through the configured
    sender. Returns {ok, reason, provider, kind, attempts}; reason ∈ ok |
    bad_email | email_not_configured | email_daily_cap (cap / provider quota /
    held for codes) | email_bouncing (address bounced — 'check your email
    address') | email_unsubscribed | email_rejected (refused, not retried) |
    send_failed (temporary, after retries).
    Temporary errors are retried (RETRY_DELAYS); permanent ones never."""
    cat = category or category_of(purpose)
    addr = normalize_email(to)
    out = {"ok": False, "reason": "", "provider": "", "kind": "", "attempts": 0}
    if not addr:
        return dict(out, reason="bad_email")
    if not configured():
        return dict(out, reason="email_not_configured", kind="config")
    snd = _sender()
    out["provider"] = snd.name
    sup = None if bypass_suppression else suppression(addr, cat)
    if sup is not None:
        unsub = sup.reason == "unsubscribed"
        _log(addr, purpose, snd.name, "suppressed", sup.reason, kind="unsub" if unsub else "bounce",
             attempts=0)
        return dict(out, reason="email_unsubscribed" if unsub else "email_bouncing",
                    kind="unsub" if unsub else "bounce")
    st = cap_state()
    if not allowed(cat, st):
        _log(addr, purpose, snd.name, "blocked",
             "provider quota" if st["provider_quota"] else "daily cap (%s)" % cat,
             kind="cap", attempts=0)
        return dict(out, reason="email_daily_cap", kind="cap")
    if cat == "bulk" and "List-Unsubscribe" not in (headers or {}):
        u = unsubscribe_url(addr)
        headers = dict(headers or {}, **{"List-Unsubscribe": "<%s>" % u,
                                         "List-Unsubscribe-Post": "List-Unsubscribe=One-Click"})
    t0 = time.monotonic()
    attempts, ok, kind, code, detail = 0, False, "temp", "", ""
    while True:
        attempts += 1
        ok, kind, code, detail = snd.send_ex(addr, subject, body, html, headers)
        if ok or kind != "temp" or attempts > len(RETRY_DELAYS):
            break
        delay = RETRY_DELAYS[attempts - 1]
        if time.monotonic() - t0 + delay > RETRY_BUDGET:
            break
        _sleep(delay)
    ms = (time.monotonic() - t0) * 1000
    _log(addr, purpose, snd.name, "sent" if ok else "failed", detail, ms=ms,
         kind="" if ok else kind, attempts=attempts)
    if ok:
        return dict(out, ok=True, reason="ok", kind="ok", attempts=attempts)
    if kind == "bounce":
        suppress(addr, "hard_bounce", code, detail)
    elif kind == "quota":
        _quota_hit_alert()
    return dict(out, reason=_REASON.get(kind, "send_failed"), kind=kind, attempts=attempts)


def send_notice(users_or_addrs, subject, text, html=None, purpose="notice"):
    """emailrel: background notices (security alerts, account notices, owner
    alerts) to several people. Through the company sender when it is
    connected; otherwise through Django's mail backend (as before) — and when
    that is only the console / dummy backend the attempt is LOGGED as 'not
    configured', never a silent success. Returns {sent, failed, results}.
    Never raises."""
    addrs = []
    for x in users_or_addrs or []:
        a = normalize_email(getattr(x, "email", x))
        if a and a not in addrs:
            addrs.append(a)
    res = {"sent": 0, "failed": 0, "results": []}
    if not addrs:
        return res
    use_company = configured()
    for a in addrs:
        if use_company:
            r = send_email(a, subject, text, purpose=purpose, html=html)
        else:
            r = _django_send(a, subject, text, html, purpose)
        res["results"].append({"to": mask_email(a), "ok": r["ok"], "reason": r["reason"]})
        res["sent" if r["ok"] else "failed"] += 1
    return res


def _django_backend_real():
    from django.conf import settings
    b = str(getattr(settings, "EMAIL_BACKEND", "") or "").lower()
    return bool(b) and not any(x in b for x in ("console", "dummy", "filebased"))


def _django_send(addr, subject, text, html, purpose):
    if not _django_backend_real():
        _log(addr, purpose, "none", "failed", "email not set up (Integrations → Email)",
             kind="config", attempts=0)
        return {"ok": False, "reason": "email_not_configured"}
    try:
        from django.conf import settings
        from django.core.mail import EmailMultiAlternatives
        m = EmailMultiAlternatives(subject, text, settings.DEFAULT_FROM_EMAIL, [addr])
        if html:
            m.attach_alternative(html, "text/html")
        n = m.send(fail_silently=False)
        return {"ok": bool(n), "reason": "ok" if n else "send_failed"}
    except Exception as e:  # noqa: BLE001
        kind, code, detail = classify(e)
        _log(addr, purpose, "django", "failed", detail, kind=kind)
        if kind == "bounce":
            suppress(addr, "hard_bounce", code, detail)
        return {"ok": False, "reason": _REASON.get(kind, "send_failed")}


# ------------------------------------------------------------------ health
def health(now=None):
    """Owner Admin → Email health card (numbers + masked addresses only)."""
    from .models import EmailLog, EmailSuppression
    now = now or timezone.now()
    day0 = now.astimezone(BD_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    st = cap_state(now)
    today = EmailLog.objects.filter(created_at__gte=day0).exclude(status="poll")
    kinds = {}
    for k in today.filter(status__in=("failed", "blocked", "suppressed")).values_list(
            "error_kind", flat=True):
        kinds[k or "other"] = kinds.get(k or "other", 0) + 1
    poll = EmailLog.objects.filter(status="poll").order_by("-created_at").first()
    caps = _cfg_caps()
    return {
        "configured": configured(), "provider": caps.get("provider") or "smtp",
        "cap": st["cap"], "used_24h": st["used"], "left": st["left"],
        "near_at": st["near_at"], "bulk_at": st["bulk_at"], "near": st["near"],
        "bulk_stop": st["bulk_stop"], "blocked": st["blocked"],
        "provider_quota": st["provider_quota"],
        "quota_until": st["quota_until"].astimezone(BD_TZ).strftime("%H:%M")
        if st["quota_until"] else "",
        "sent_today": today.filter(status="sent").count(),
        "failed_today": today.filter(status="failed").count(),
        "held_today": today.filter(status__in=("blocked", "suppressed")).count(),
        "retried_today": today.filter(status="sent", attempts__gt=1).count(),
        "kinds_today": sorted(kinds.items()),
        "bounces_7d": EmailSuppression.objects.filter(
            reason="hard_bounce", last_at__gte=now - timedelta(days=7)).count(),
        "suppressed": EmailSuppression.objects.exclude(reason="unsubscribed").count(),
        "unsubscribed": EmailSuppression.objects.filter(reason="unsubscribed").count(),
        "last_poll": poll.created_at.astimezone(BD_TZ).strftime("%d %b %H:%M") if poll else "",
        "last_poll_detail": poll.detail if poll else "",
        "recent_failures": [
            {"at": r.created_at.astimezone(BD_TZ).strftime("%d %b %H:%M"),
             "to": r.to_masked, "purpose": r.purpose, "kind": r.error_kind or r.status,
             "detail": r.detail[:120]}
            for r in EmailLog.objects.filter(status__in=("failed", "blocked", "suppressed"))
            .order_by("-created_at")[:10]],
        "suppression_rows": [
            {"id": r.id, "to": r.to_masked, "reason": r.reason, "code": r.code,
             "hits": r.hits, "at": r.last_at.astimezone(BD_TZ).strftime("%d %b %H:%M")}
            for r in EmailSuppression.objects.order_by("-last_at")[:30]],
    }


# ------------------------------------------------------------------ template
def otp_email(code, lang, ttl_seconds):
    """(subject, body) — plain bilingual text: no images, no links, no
    tracking, no personal names. The primary language comes first."""
    from . import email_templates as T
    subject, text, _html = T.render_otp(code, lang, ttl_seconds)
    return subject, text


def otp_email_html(code, lang, ttl_seconds):
    """emailrel: (subject, text, html) — the branded HTML part as well."""
    from . import email_templates as T
    return T.render_otp(code, lang, ttl_seconds)


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
