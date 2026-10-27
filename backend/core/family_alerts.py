"""
family_alerts.py — family100: ONE server function for every family-facing
alert, delivered by FCM push at the moment it happens.

WorkManager is gone for good (it crashed on launch on ColorOS), so a phone
cannot be trusted to wake itself up and poll. Everything that must reach the
family goes through `alert()` here, from the view that saw it happen (SOS from
any surface, a scam report) or from the per-minute `journey_sweep` cron (a
missed safe-arrival check-in, an unanswered wellness "Are you OK?", releasing
quiet-hours holds). The foreground `/alerts` poll stays as the fallback: every
delivery also writes the recipient's in-app FamilyAlert card.

Rules (each one has a test in core/tests_family100.py):
  * RECIPIENTS — only accepted, unblocked circle members of the sender who
    have an account, and who have not blocked the sender from their side.
    Explicit recipient lists are intersected with that set, so someone who
    left the circle gets nothing, immediately, and a held alert is revoked.
  * LOCATION — lat/lng go only to members the sender shares location with
    (CircleMember.sharing["location"]); SOS is the exception: pressing SOS is
    the sender's explicit consent to show family where they are right now.
  * IDEMPOTENT — one FamilyAlertDelivery row per (event_key, recipient),
    UNIQUE in the database: a retry, a double tap or two racing sweeps can
    never ring a phone twice for the same event.
  * RATE LIMIT — non-urgent kinds: at most RATE_PER_HOUR pushes per
    (sender -> recipient) per hour; above that the in-app card is still
    written but nothing rings. Urgent safety kinds are never capped.
  * QUIET HOURS — the recipient's own Do-Not-Disturb (CirclePrivacy.dnd_*);
    with "family may still reach me" OFF, non-SOS alerts are held (card
    written, push sent when the window ends — `sweep()`). SOS and the
    all-clear always ring.
  * AUDIT — the same row records status, push time, the phone's receipt time
    (delivery-time quality bar) and when the recipient saw it.

Safety is always free (billing.SAFETY_EXEMPT): nothing here debits credits.
"""
import logging
from datetime import datetime, timedelta

from django.db import IntegrityError, transaction
from django.utils import timezone

log = logging.getLogger(__name__)

RATE_PER_HOUR = 6
HOLD_MAX_HOURS = 12           # a held alert older than this is not pushed late
SEEN_LIST_DAYS = 7
SOS_BUCKET_S = 60             # repeated SOS taps within a minute = one event

# kind -> push kind, deep-link route, urgent (never capped), rings in quiet hours
KINDS = {
    "sos":             {"push": "sos", "route": "safety/sos", "urgent": True, "quiet_ok": True},
    "sos_resolved":    {"push": "family_alert", "route": "family/alerts", "urgent": True, "quiet_ok": True},
    "checkin_overdue": {"push": "family_alert", "route": "family/alerts", "urgent": True, "quiet_ok": False},
    "wellness_alert":  {"push": "family_alert", "route": "family/alerts", "urgent": True, "quiet_ok": False},
    "scam_report":     {"push": "family_alert", "route": "family/alerts", "urgent": False, "quiet_ok": False},
}
SEVERITY = {"sos": "high", "sos_resolved": "info", "checkin_overdue": "high",
            "wellness_alert": "high", "scam_report": "high"}

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_num(v):
    return str(v).translate(_BN)


# ------------------------------------------------------------------ audience
def _edge(owner, other):
    """owner's CircleMember row that points at `other` (peer_user, else phone)."""
    from .models import CircleMember
    e = CircleMember.objects.filter(user=owner, peer_user=other).first()
    if e is None and (getattr(other, "phone", "") or "").strip():
        e = CircleMember.objects.filter(user=owner, phone=other.phone.strip()).first()
    return e


def consenting_members(sender):
    """[(recipient_user, sender_edge)] — accepted, unblocked circle members of
    `sender` with an account, who have not blocked / declined the sender on
    their own side. Never the sender."""
    from .models import CircleMember
    from .push import member_peer_user
    out, seen = [], {sender.pk}
    for m in CircleMember.objects.filter(user=sender, state="accepted", blocked=False):
        u = member_peer_user(m)
        if u is None or u.pk in seen:
            continue
        back = _edge(u, sender)
        if back is not None and (back.blocked or back.state in ("blocked", "declined")):
            continue
        seen.add(u.pk)
        out.append((u, m))
    return out


def is_member(sender, user):
    return any(u.pk == user.pk for u, _m in consenting_members(sender))


def _shares_location(edge):
    try:
        from .logic import circle
        return circle.can_see(edge.sharing or {}, "location")
    except Exception:
        return False


# --------------------------------------------------------------- quiet hours
def _hhmm(s):
    try:
        h, m = (int(x) for x in str(s).split(":"))
        return h * 60 + m
    except (TypeError, ValueError):
        return None


def in_quiet_hours(user, now=None):
    """The recipient's own DND (Circle privacy) blocks family alerts right now?
    'Family may still reach me' (dnd_family_exception, default ON) = never."""
    from .models import CirclePrivacy
    row = CirclePrivacy.objects.filter(user=user).first()
    if row is None or not row.dnd_enabled or row.dnd_family_exception:
        return False
    a, b = _hhmm(row.dnd_start), _hhmm(row.dnd_end)
    if a is None or b is None or a == b:
        return False
    lt = timezone.localtime(now or timezone.now())
    t = lt.hour * 60 + lt.minute
    return (a <= t < b) if a < b else (t >= a or t < b)


def _rate_ok(sender, recipient, now):
    from .models import FamilyAlertDelivery
    n = FamilyAlertDelivery.objects.filter(
        sender=sender, recipient=recipient, status="sent",
        created_at__gte=now - timedelta(hours=1)).exclude(
        kind__in=[k for k, v in KINDS.items() if v["urgent"]]).count()
    return n < RATE_PER_HOUR


# ----------------------------------------------------------------- texts
def default_texts(kind, name, lang, payload=None):
    """(title, body) for the built-in kinds, in one language only."""
    p = payload or {}
    en = lang == "en"
    if kind == "sos":
        if en:
            return ("SOS: %s needs help" % name,
                    "Call them now. Tap to see where they are.")
        return ("জরুরি: %s সাহায্য চাইছেন" % name,
                "এখনই ফোন করুন। কোথায় আছেন দেখতে ট্যাপ করুন।")
    if kind == "sos_resolved":
        if en:
            return ("%s is safe now" % name, "They turned off the SOS.")
        return ("%s এখন নিরাপদ" % name, "উনি SOS বন্ধ করেছেন।")
    t = p.get("title_en" if en else "title_bn") or ""
    b = p.get("body_en" if en else "body_bn") or ""
    return t or ("Assisto" if en else "Assisto"), b


# ----------------------------------------------------------------- delivery
def _push(d, fa, kind, title_bn, title_en, body_bn, body_en, data):
    """Send one push for delivery row `d`. Returns the new status."""
    from . import push
    from .models import Device
    cfg = KINDS[kind]
    ok = False
    try:
        ok = push.safe_push(d.recipient, cfg["push"], title_bn, title_en,
                            body_bn, body_en, data=data, high_priority=True)
    except Exception:
        ok = False
    if ok:
        return "sent"
    if not push.is_available():
        return "push_off"
    if not Device.objects.filter(user=d.recipient).exclude(push_token="").exists():
        return "no_device"
    return "failed"


def alert(sender, kind, event_key, payload=None, recipients=None, texts=None,
          lat=None, lng=None, now=None):
    """Deliver family alert `kind` about `sender` to their consenting circle.

    event_key  — stable id of the real-world event (e.g. "checkin:42");
                 combined with kind + sender it is the idempotency key.
    payload    — extra push/in-app data (strings/ints). For kinds without
                 built-in wording: title_bn/title_en/body_bn/body_en with a
                 "{name}" placeholder for the sender's name as each recipient
                 sees it.
    recipients — optional subset (users); intersected with the consenting set.
    texts      — optional callable(name, lang) -> (title, body).
    Returns a stats dict. Never raises into the caller."""
    stats = {"recipients": 0, "sent": 0, "duplicate": 0, "held": 0,
             "rate_limited": 0, "no_device": 0, "push_off": 0, "failed": 0,
             "delivery_ids": []}
    try:
        return _alert(sender, kind, event_key, payload, recipients, texts,
                      lat, lng, now, stats)
    except Exception as e:
        log.warning("family_alerts: %s failed %s", kind, type(e).__name__)
        return stats


def _alert(sender, kind, event_key, payload, recipients, texts, lat, lng, now, stats):
    from . import push
    from .models import FamilyAlert, FamilyAlertDelivery
    if sender is None or kind not in KINDS:
        return stats
    now = now or timezone.now()
    cfg = KINDS[kind]
    key = ("%s:%s:%s" % (kind, sender.pk, event_key))[:120]
    members = consenting_members(sender)
    if recipients is not None:
        want = {getattr(u, "pk", u) for u in recipients}
        members = [(u, m) for u, m in members if u.pk in want]
    p = dict(payload or {})
    for u, edge in members:
        stats["recipients"] += 1
        name = push.seen_name(u, sender)
        if texts is not None:
            tbn, bbn = texts(name, "bn")
            ten, ben = texts(name, "en")
        else:
            tp = {k: str(v).replace("{name}", name) for k, v in p.items()
                  if k in ("title_bn", "title_en", "body_bn", "body_en")}
            tbn, bbn = default_texts(kind, name, "bn", tp)
            ten, ben = default_texts(kind, name, "en", tp)
        with_loc = lat is not None and lng is not None and (
            kind == "sos" or _shares_location(edge))
        try:
            with transaction.atomic():
                d = FamilyAlertDelivery.objects.create(
                    event_key=key, kind=kind, sender=sender, recipient=u,
                    status="pending", with_location=with_loc)
        except IntegrityError:
            stats["duplicate"] += 1
            continue
        lang = push.user_lang(u)
        data = {k: v for k, v in p.items()
                if k not in ("title_bn", "title_en", "body_bn", "body_en")}
        data.update({"route": cfg["route"], "alert_kind": kind,
                     "event": data.get("event") or kind,
                     "delivery_id": d.id, "from_user_id": sender.pk,
                     "from_name": name,
                     "lat": lat if with_loc else "", "lng": lng if with_loc else ""})
        if kind == "sos":
            # the sender's own screen may be quiet (duress); the family's
            # phones always ring — `silent` on a recipient's payload would
            # suppress its full-screen intent, so it is never set here.
            data["duress"] = bool(p.get("duress"))
            data["silent"] = False
        fa = FamilyAlert.objects.create(
            user=u, kind=kind[:24],
            title=(ten if lang == "en" else tbn)[:160],
            body=ben if lang == "en" else bbn,
            severity=SEVERITY.get(kind, "high"), payload=dict(data))
        d.alert = fa
        if not cfg["quiet_ok"] and in_quiet_hours(u, now):
            d.status = "held"
        elif not cfg["urgent"] and not _rate_ok(sender, u, now):
            d.status = "rate_limited"
        else:
            d.status = _push(d, fa, kind, tbn, ten, bbn, ben, data)
            d.pushed_at = timezone.now()
        d.save(update_fields=["alert", "status", "pushed_at"])
        stats[d.status] = stats.get(d.status, 0) + 1
        stats["delivery_ids"].append(d.id)
    log.info("family_alerts: kind=%s recipients=%d sent=%d", kind,
             stats["recipients"], stats["sent"])
    return stats


# ------------------------------------------------------------------- SOS
def sos(sender, lat=None, lng=None, duress=False, journey_id=None,
        client_id="", source="", now=None):
    """SOS from any surface. `client_id` (the phone's own id for this press)
    makes a retry idempotent; without one, presses within SOS_BUCKET_S are
    one event. Rings in quiet hours, never capped, always free."""
    now = now or timezone.now()
    cid = "".join(ch for ch in str(client_id or "") if ch.isalnum() or ch in "-_")[:40]
    ek = "c:%s" % cid if cid else "t:%d" % (int(now.timestamp()) // SOS_BUCKET_S)
    if journey_id:
        ek = "j%s:%s" % (journey_id, ek)
    data = {"source": str(source or "")[:24], "journey_id": journey_id or "",
            "duress": bool(duress)}
    return alert(sender, "sos", ek, payload=data, lat=lat, lng=lng, now=now)


def sos_resolved(sender, now=None):
    """'I'm safe now' — tells everyone who got an SOS in the last 24 h, and
    their SOS cards go stale."""
    from .models import FamilyAlert, FamilyAlertDelivery
    now = now or timezone.now()
    recent = FamilyAlertDelivery.objects.filter(
        sender=sender, kind="sos", created_at__gte=now - timedelta(hours=24))
    ids = set(recent.values_list("recipient_id", flat=True))
    if not ids:
        return {"recipients": 0, "sent": 0, "delivery_ids": []}
    FamilyAlert.objects.filter(kind="sos", dismissed=False, user_id__in=ids,
                               payload__from_user_id=sender.pk).update(dismissed=True)
    return alert(sender, "sos_resolved", "r:%d" % int(now.timestamp()),
                 recipients=list(ids), now=now)


# --------------------------------------------------------------- seen / ack
def mark_seen(user, delivery_id):
    from .models import FamilyAlertDelivery
    d = FamilyAlertDelivery.objects.filter(pk=delivery_id, recipient=user).first()
    if d is None:
        return None
    now = timezone.now()
    if d.seen_at is None:
        d.seen_at = now
    if d.received_at is None:
        d.received_at = now
    d.save(update_fields=["seen_at", "received_at"])
    if d.alert_id:
        from .models import FamilyAlert
        FamilyAlert.objects.filter(pk=d.alert_id).update(dismissed=True)
    return d


def mark_received(user, ids):
    """The recipient's phone got the push (any isolate). First receipt wins."""
    from .models import FamilyAlertDelivery
    ids = [int(i) for i in ids if str(i).isdigit()][:100]
    if not ids:
        return 0
    return FamilyAlertDelivery.objects.filter(
        pk__in=ids, recipient=user, received_at__isnull=True).update(
        received_at=timezone.now())


def delivery_stats(since=None):
    """Quality bar D/৭: push -> phone receipt seconds (p50/p95, within 60 s)."""
    from .models import FamilyAlertDelivery
    q = FamilyAlertDelivery.objects.filter(pushed_at__isnull=False,
                                           received_at__isnull=False)
    if since is not None:
        q = q.filter(pushed_at__gte=since)
    secs = sorted(max(0.0, (r - p).total_seconds())
                  for p, r in q.values_list("pushed_at", "received_at"))
    total = FamilyAlertDelivery.objects.filter(status="sent")
    if since is not None:
        total = total.filter(pushed_at__gte=since)

    def pct(x):
        if not secs:
            return None
        return round(secs[min(len(secs) - 1, int(round(x * (len(secs) - 1))))], 1)
    return {"sent": total.count(), "receipts": len(secs), "p50_s": pct(0.5),
            "p95_s": pct(0.95),
            "within_60s": sum(1 for s in secs if s <= 60)}


# ------------------------------------------------------------------- sweep
def sweep(now=None, stats=None):
    """Cron (inside journey_sweep, every minute): push held alerts whose
    quiet hours ended — after re-checking the recipient is STILL in the
    sender's circle (left = revoked, nothing sent). Idempotent."""
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    stats = stats if stats is not None else {}
    for d in FamilyAlertDelivery.objects.filter(status="held").select_related(
            "recipient", "sender", "alert"):
        if d.sender is None or d.alert is None or d.alert.dismissed or \
                now - d.created_at > timedelta(hours=HOLD_MAX_HOURS):
            d.status = "expired"
            d.save(update_fields=["status"])
            continue
        if not is_member(d.sender, d.recipient):
            d.status = "revoked"
            d.save(update_fields=["status"])
            d.alert.dismissed = True
            d.alert.save(update_fields=["dismissed"])
            stats["family_revoked"] = stats.get("family_revoked", 0) + 1
            continue
        if in_quiet_hours(d.recipient, now):
            continue
        fa = d.alert
        data = dict(fa.payload or {})
        # the held card was written in the recipient's language; push it as is
        d.status = _push(d, fa, d.kind, fa.title, fa.title, fa.body, fa.body, data)
        d.pushed_at = timezone.now()
        d.save(update_fields=["status", "pushed_at"])
        stats["family_released"] = stats.get("family_released", 0) + 1
    return stats


# ------------------------------------------------------------- API shapes
def _iso(dt):
    return dt.isoformat() if dt else None


def received_rows(user, now=None):
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    out = []
    for d in FamilyAlertDelivery.objects.filter(
            recipient=user, created_at__gte=now - timedelta(days=SEEN_LIST_DAYS)
    ).exclude(status="revoked").select_related("alert", "sender")[:50]:
        fa = d.alert
        p = (fa.payload if fa else {}) or {}
        out.append({
            "id": d.id, "kind": d.kind, "at": _iso(d.created_at),
            "title": fa.title if fa else "", "body": fa.body if fa else "",
            "from_user_id": d.sender_id, "from_name": p.get("from_name") or "",
            "lat": p.get("lat") if d.with_location else None,
            "lng": p.get("lng") if d.with_location else None,
            "seen": d.seen_at is not None, "status": d.status,
            "active": bool(fa) and not fa.dismissed,
        })
    return out


def sent_rows(user, now=None):
    """Events the user raised (SOS etc.) with per-recipient seen receipts."""
    from .models import FamilyAlertDelivery
    now = now or timezone.now()
    events = {}
    for d in FamilyAlertDelivery.objects.filter(
            sender=user, created_at__gte=now - timedelta(days=SEEN_LIST_DAYS)
    ).select_related("recipient").order_by("-created_at")[:200]:
        ev = events.setdefault(d.event_key, {"kind": d.kind, "at": _iso(d.created_at),
                                             "recipients": []})
        from .push import seen_name
        ev["recipients"].append({
            "name": seen_name(user, d.recipient), "status": d.status,
            "received": d.received_at is not None, "seen": d.seen_at is not None})
    return list(events.values())[:20]
