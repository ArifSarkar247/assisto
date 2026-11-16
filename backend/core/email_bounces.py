"""
emailrel (16 Nov): read bounce reports (DSN, RFC 3464) from the company
mailbox and put dead addresses on the suppression list.

Gmail's SMTP accepts most mail first and reports a dead address LATER, as a
"Delivery Status Notification (Failure)" from mailer-daemon into the sender's
own inbox. `poll()` reads those over IMAP with the same app password as the
SMTP entry (imap.gmail.com:993), marks them read, and suppresses an address
only when
  * the report says Action: failed + Status 5.1.x / 5.4.4 (dead mailbox /
    domain) — or Gmail's plain "Address not found" text when there is no
    machine-readable part, and
  * we really mailed that address in the last 14 days (EmailLog hash) — so a
    forged report cannot silence someone's security mail.
Mailbox-full (5.2.x) and policy refusals are only counted, never suppressed.

Run every 15 minutes:  python manage.py email_bounces
Never logs a full address (masked only). Network seam: `imap_cls`.
"""
import email
import imaplib
import logging
import re
from datetime import timedelta
from email import policy

from django.utils import timezone

log = logging.getLogger("assisto.email")
MAX_PER_RUN = 200
LOOKBACK_DAYS = 14
_ADDR = re.compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")


def _val(v):
    """'rfc822; a@b.c' -> 'a@b.c'."""
    v = str(v or "").strip()
    return v.split(";", 1)[1].strip() if ";" in v else v


def parse_dsn(raw):
    """[(recipient, status, action, diag)] from one bounce message (bytes)."""
    msg = email.message_from_bytes(raw if isinstance(raw, bytes) else str(raw).encode(),
                                   policy=policy.compat32)
    out = []
    for part in msg.walk():
        if part.get_content_type() != "message/delivery-status":
            continue
        payload = part.get_payload()
        blocks = payload if isinstance(payload, list) else []
        if not blocks and isinstance(payload, str):
            blocks = [email.message_from_string(b) for b in payload.split("\n\n") if b.strip()]
        for b in blocks:
            rcpt = _val(b.get("Final-Recipient") or b.get("Original-Recipient"))
            if not rcpt:
                continue
            out.append((rcpt.strip("<>").lower(), str(b.get("Status") or "").strip(),
                        str(b.get("Action") or "").strip().lower(),
                        " ".join(str(b.get("Diagnostic-Code") or "").split())[:160]))
    if out:
        return out
    # no machine-readable part: Gmail's human text
    text = ""
    for part in msg.walk():
        if part.get_content_type() == "text/plain":
            try:
                text += part.get_payload(decode=True).decode("utf-8", "replace")
            except Exception:  # noqa: BLE001
                pass
    low = text.lower()
    if "address not found" in low or "wasn't delivered to" in low or "does not exist" in low:
        m = re.search(r"delivered to\s+(" + _ADDR.pattern + ")", text, re.I) or _ADDR.search(text)
        if m:
            addr = m.group(1) if m.lastindex else m.group(0)
            out.append((addr.lower(), "5.1.1", "failed", "address not found"))
    return out


def is_hard(status, action, diag=""):
    if action and action != "failed":
        return False
    s = str(status or "")
    if s.startswith("5.1.") or s == "5.4.4":
        return True
    low = (diag or "").lower()
    return s.startswith("5.") and not s.startswith("5.2.") and any(
        w in low for w in ("does not exist", "user unknown", "no such user",
                           "address not found", "unknown user"))


def _from_daemon(raw):
    try:
        msg = email.message_from_bytes(raw, policy=policy.compat32)
        frm = str(msg.get("From") or "").lower()
        return "mailer-daemon" in frm or "postmaster" in frm
    except Exception:  # noqa: BLE001
        return False


def apply_reports(raws, now=None):
    """Suppress hard-bounced addresses we mailed. Returns counts."""
    from .email_sender import email_hash, mask_email, suppress
    from .models import EmailLog
    now = now or timezone.now()
    res = {"reports": 0, "hard": 0, "soft": 0, "ignored": 0}
    for raw in raws:
        if not _from_daemon(raw):
            res["ignored"] += 1
            continue
        res["reports"] += 1
        for rcpt, status, action, diag in parse_dsn(raw):
            ours = EmailLog.objects.filter(
                to_hash=email_hash(rcpt), status="sent",
                created_at__gt=now - timedelta(days=LOOKBACK_DAYS)).exists()
            if not ours:
                res["ignored"] += 1
                continue
            if is_hard(status, action, diag):
                suppress(rcpt, "hard_bounce", status, ("DSN %s %s" % (status, diag))[:200])
                res["hard"] += 1
            else:
                res["soft"] += 1
                log.info("email soft bounce to=%s status=%s", mask_email(rcpt), status or "-")
    return res


def _imap_host(cfg):
    h = str(cfg.get("imap_host") or "").strip()
    if h:
        return h
    smtp = str(cfg.get("host") or "smtp.gmail.com").strip()
    return smtp.replace("smtp.", "imap.", 1) if smtp.startswith("smtp.") else smtp


def poll(imap_cls=None, now=None):
    """One IMAP pass. Returns {ok, detail, ...counts}; also leaves an
    EmailLog row (status='poll') so Owner Admin shows the last check."""
    from . import integrations
    from .email_sender import _log
    imap_cls = imap_cls or imaplib.IMAP4_SSL
    cfg = dict(integrations.get("smtp_email") or {})
    user = str(cfg.get("username") or "").strip()
    pw = str(cfg.get("app_password") or "").replace(" ", "").strip()
    if not (user and pw):
        return {"ok": False, "detail": "email not set up"}
    res = {"reports": 0, "hard": 0, "soft": 0, "ignored": 0}
    try:
        M = imap_cls(_imap_host(cfg), 993, timeout=20)
        try:
            M.login(user, pw)
            M.select("INBOX")
            ids = []
            for who in ("mailer-daemon", "postmaster"):
                typ, data = M.search(None, "(UNSEEN FROM \"%s\")" % who)
                if typ == "OK" and data and data[0]:
                    ids += data[0].split()
            ids = list(dict.fromkeys(ids))[:MAX_PER_RUN]
            raws = []
            for i in ids:
                typ, data = M.fetch(i, "(BODY.PEEK[])")
                if typ == "OK" and data and isinstance(data[0], tuple):
                    raws.append(data[0][1])
                M.store(i, "+FLAGS", "\\Seen")
            res = apply_reports(raws, now=now)
        finally:
            try:
                M.logout()
            except Exception:  # noqa: BLE001
                pass
        detail = "reports %d · hard %d · soft %d" % (res["reports"], res["hard"], res["soft"])
        ok = True
    except imaplib.IMAP4.error:
        ok, detail = False, "IMAP login refused — app password / IMAP access"
    except Exception as e:  # noqa: BLE001
        ok, detail = False, "IMAP error: %s" % type(e).__name__
    _log("", "bouncecheck", "imap", "poll", detail, kind="" if ok else "temp", attempts=0)
    return dict(res, ok=ok, detail=detail)


TICK_MINUTES = 15


def tick(now=None, imap_cls=None):
    """minute_jobs entry: poll at most every TICK_MINUTES, only when the
    email entry is connected. Idle = one indexed read."""
    from .email_sender import configured
    from .models import EmailLog
    now = now or timezone.now()
    if EmailLog.objects.filter(status="poll",
                               created_at__gt=now - timedelta(minutes=TICK_MINUTES)).exists():
        return None
    if not configured():
        return None
    return poll(imap_cls=imap_cls, now=now)
