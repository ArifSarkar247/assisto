"""ring-everywhere — owner 24 Oct: "CALLS MUST RING LIKE WHATSAPP ON EVERY
PHONE" (testers: no ring when Assisto is closed / swiped away / in the
background on many OEM phones).

What this module adds to the c2-calls signalling (views_c2_calls):

  * DELIVERED ACK from the phone's NATIVE FCM service (AssistoFcmService.kt)
    the moment the ring push arrives — before (and without) the Flutter
    engine. It cannot use the account token (that lives in the Flutter
    secure store), so the ring push carries `ack_sig` = HMAC(SECRET_KEY,
    "call-ack:<call_id>:<callee_id>"): it lets that ONE phone confirm
    delivery / ringing / decline of that ONE call, nothing else.
      POST circle/calls/<id>/ack {sig, stage: delivered|ringing|decline,
                                   brand, model, sdk}
  * BOUNDED RESEND: still no delivered / ringing ack RESEND_AFTER_S after the
    last ring push -> the push is sent again (MAX_RESENDS times at most,
    idempotent per call: a conditional UPDATE picks one winner even when both
    phones poll at once; same collapse key call-<id>; the phone shows ONE
    notification per call id). Evaluated lazily from sweep() — the caller's
    call screen polls every ~0.5 s while "Calling…", so no timer thread.
  * MISSED CALL ON RECONNECT: a call that ended unanswered and was NEVER
    delivered (no delivered / ringing ack) is flagged `missed_pending`; the
    phone fetches it once when it next comes online (app start / resume /
    token registration) and draws a "Missed call" notification.
  * DELIVERY STATS by phone brand / model / Android version for Owner Admin
    -> Calls (brand/model/sdk come from the ack or token registration; no
    PII, no phone numbers).

Never raises into a request.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
from datetime import timedelta

from django.conf import settings
from django.utils import timezone

log = logging.getLogger("assisto.rt")

RESEND_AFTER_S = 4      # no delivered/ringing ack this long after a push
MAX_RESENDS = 2         # -> resend at ~4 s and ~8 s, never more
STAGES = ("delivered", "ringing", "decline")
PENDING_DAYS = 7        # a never-delivered missed call older than this is dropped

ANDROID = {26: "8.0", 27: "8.1", 28: "9", 29: "10", 30: "11", 31: "12",
           32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17"}


# ---------------------------------------------------------------- signature
def sign(call_id, callee_id):
    key = (getattr(settings, "SECRET_KEY", "") or "assisto").encode()
    msg = ("call-ack:%s:%s" % (int(call_id), int(callee_id or 0))).encode()
    return hmac.new(key, msg, hashlib.sha256).hexdigest()[:32]


def verify(call_id, callee_id, sig):
    try:
        return bool(sig) and hmac.compare_digest(sign(call_id, callee_id),
                                                 str(sig)[:64])
    except Exception:
        return False


# ---------------------------------------------------------------- device facts
def clean_facts(data):
    """(brand, model, sdk) from a request body — short, printable, no PII."""
    def _s(k, n):
        v = str((data or {}).get(k, "") or "").strip()
        v = "".join(ch for ch in v if ch.isprintable())
        return v[:n]
    try:
        sdk = int(str((data or {}).get("sdk", (data or {}).get("sdk_int", 0)) or 0))
    except (TypeError, ValueError):
        sdk = 0
    if sdk < 0 or sdk > 100:
        sdk = 0
    return _s("brand", 32).lower(), _s("model", 48), sdk


def android_label(sdk):
    if not sdk:
        return "?"
    return "Android %s (%d)" % (ANDROID.get(int(sdk), "?"), int(sdk))


# ---------------------------------------------------------------- resend
def due_resend(state, now, started_at, last_push_at, push_sent, ringing_at,
               delivered_at, resends):
    """Pure rule: should the ring push go out again now?"""
    if state != "ringing" or not push_sent:
        return False
    if ringing_at is not None or delivered_at is not None:
        return False
    if int(resends or 0) >= MAX_RESENDS:
        return False
    last = last_push_at or started_at
    if last is None:
        return False
    return (now - last).total_seconds() >= RESEND_AFTER_S


def maybe_resend(rec, sess, now=None):
    """Resend the ring push once more when it is due (see module doc).
    Returns True when THIS call to it sent the resend. Never raises."""
    try:
        now = now or timezone.now()
        if not due_resend(rec.state, now, rec.started_at,
                          getattr(sess, "last_push_at", None),
                          getattr(sess, "push_sent", False), sess.ringing_at,
                          getattr(sess, "delivered_at", None),
                          getattr(sess, "push_resends", 0)):
            return False
        from .models import CallSession
        n = int(sess.push_resends or 0)
        won = CallSession.objects.filter(
            pk=sess.pk, push_resends=n, ringing_at__isnull=True,
            delivered_at__isnull=True).update(push_resends=n + 1,
                                              last_push_at=now)
        if not won:
            return False
        sess.push_resends = n + 1
        sess.last_push_at = now
        from . import push as PUSH
        PUSH.hook_call_placed(rec.caller, rec.circle, rec, attempt=n + 1)
        try:
            from . import call_health
            call_health.log_event("push", "resend_%d" % (n + 1),
                                  user=rec.callee, call_id=rec.id)
        except Exception:
            pass
        return True
    except Exception:
        log.exception("ring: maybe_resend failed (call=%s)", getattr(rec, "pk", None))
        return False


# ---------------------------------------------------------------- ack
def apply_ack(rec, stage, data, now=None):
    """The native phone's ack. Returns the JSON body. Idempotent."""
    from . import views_c2_calls as C
    from .logic import call_signal as CS
    now = now or timezone.now()
    C.sweep(rec, now)
    sess = C.session_of(rec)
    brand, model, sdk = clean_facts(data)
    upd = []
    if stage in ("delivered", "ringing") and sess.delivered_at is None:
        sess.delivered_at = now
        upd.append("delivered_at")
    if brand and not sess.callee_brand:
        sess.callee_brand, sess.callee_model, sess.callee_sdk = brand, model, sdk
        upd += ["callee_brand", "callee_model", "callee_sdk"]
    if upd:
        sess.save(update_fields=upd)
    if stage == "ringing":
        if rec.state == "ringing" and sess.ringing_at is None:
            sess.ringing_at = now
            sess.save(update_fields=["ringing_at"])
            C.publish_state(rec)
    elif stage == "decline":
        C.apply_event(rec, "callee", "decline", now=now)
        rec.refresh_from_db()
    ended = not CS.is_live(rec.state)
    return {"ok": True, "phase": CS.phase(rec.state, sess.ringing_at),
            "ended": ended, "state": rec.state}


# ---------------------------------------------------------------- missed
def mark_missed_pending(rec, sess, reason):
    """end_call: an unanswered call the callee's phone never got -> show it
    as a missed call when that phone next comes online."""
    from .logic import call_signal as CS
    if reason not in CS.MISSED_REASONS or rec.callee_id == rec.caller_id:
        return False
    if sess.ringing_at is not None or getattr(sess, "delivered_at", None):
        return False
    sess.missed_pending = True
    return True


def take_missed_pending(user, lang="bn", now=None):
    """Rows of never-delivered missed calls for `user` (oldest first), each
    returned ONCE (the flag is cleared)."""
    from .models import CallSession
    from . import push as PUSH
    from .views_c2_calls import missed_streak, photo_of
    now = now or timezone.now()
    qs = (CallSession.objects.filter(
        missed_pending=True, call__callee=user,
        call__started_at__gte=now - timedelta(days=PENDING_DAYS))
        .select_related("call", "call__caller").order_by("call__started_at"))
    rows, ids = [], []
    for sess in qs[:20]:
        rec = sess.call
        ids.append(sess.pk)
        caller = rec.caller
        name = PUSH.seen_name(user, caller)
        video = rec.kind == "video"
        n = missed_streak(rec)
        if n > 1:
            title_bn = title_en = "%s (%d)" % (name, n)
            body_bn, body_en = "%dটি মিসড কল" % n, "%d missed calls" % n
        else:
            title_bn, title_en = "%s-এর মিসড কল" % name, "Missed call from %s" % name
            body_bn = "ভিডিও কল" if video else "ভয়েস কল"
            body_en = "Video call" if video else "Voice call"
        en = lang == "en"
        photo, ver = photo_of(caller)
        edge = PUSH._reverse_edge(user, caller)
        rows.append({
            "kind": "missed_call", "call_id": str(rec.id),
            "caller_id": str(caller.id), "caller_name": name,
            "video": "true" if video else "false",
            "missed_count": str(n), "group_key": "caller-%s" % caller.id,
            "caller_photo": photo, "caller_photo_v": ver,
            "chat_id": str(edge.id) if edge is not None else "",
            "title": title_en if en else title_bn,
            "body": body_en if en else body_bn,
            "lang": "en" if en else "bn", "channel": "missed_calls",
            "route": "circle/calls", "started_at": rec.started_at.isoformat(),
            "reconnect": "true",
        })
    if ids:
        CallSession.objects.filter(pk__in=ids).update(missed_pending=False)
    return rows


def pending_count(user):
    try:
        from .models import CallSession
        return CallSession.objects.filter(missed_pending=True,
                                          call__callee=user).count()
    except Exception:
        return 0


# ---------------------------------------------------------------- stats
def delivery_stats(hours=24 * 7, now=None):
    """Owner Admin: call ring delivery by phone brand / model / Android.

    Counted: calls in the window whose ring push went to a device of the
    callee (push_sent). Delivered = the callee phone acked (native delivered
    ack, or the ringing ack from Dart / in-app). Calls still ringing and not
    yet acked are not judged yet."""
    from .models import CallRecord, Device
    from .logic import call_signal as CS
    now = now or timezone.now()
    since = now - timedelta(hours=hours)
    recs = list(CallRecord.objects.filter(started_at__gte=since)
                .select_related("session"))
    dev_cache = {}

    def _dev(uid):
        if uid not in dev_cache:
            d = (Device.objects.filter(user_id=uid).exclude(brand="")
                 .order_by("-last_seen", "-id").first())
            dev_cache[uid] = (d.brand, d.model, d.sdk_int) if d else ("", "", 0)
        return dev_cache[uid]

    rows, by_brand, by_android = {}, {}, {}
    total = ok = 0
    for r in recs:
        if r.callee_id == r.caller_id:
            continue
        sess = getattr(r, "session", None)
        if sess is None or not getattr(sess, "push_sent", False):
            continue
        delivered = bool(sess.delivered_at or sess.ringing_at)
        if not delivered and CS.is_live(r.state):
            continue
        if sess.callee_brand:
            brand, model, sdk = sess.callee_brand, sess.callee_model, sess.callee_sdk
        else:
            brand, model, sdk = _dev(r.callee_id)
        brand = brand or "?"
        total += 1
        ok += int(delivered)
        for bucket, key in ((rows, (brand, model or "?", int(sdk or 0))),
                            (by_brand, brand),
                            (by_android, int(sdk or 0))):
            b = bucket.setdefault(key, [0, 0, 0])
            b[0] += 1
            b[1] += int(delivered)
            b[2] += int(getattr(sess, "push_resends", 0) or 0)

    def _pct(a, d):
        return round(100.0 * d / a) if a else None

    out_rows = [{"brand": k[0], "model": k[1], "sdk": k[2],
                 "android": android_label(k[2]), "attempts": v[0],
                 "delivered": v[1], "resends": v[2], "pct": _pct(v[0], v[1])}
                for k, v in rows.items()]
    out_rows.sort(key=lambda x: (-x["attempts"], x["brand"], x["model"]))
    brands = [{"brand": k, "attempts": v[0], "delivered": v[1],
               "pct": _pct(v[0], v[1])} for k, v in by_brand.items()]
    brands.sort(key=lambda x: (-x["attempts"], x["brand"]))
    androids = [{"sdk": k, "android": android_label(k), "attempts": v[0],
                 "delivered": v[1], "pct": _pct(v[0], v[1])}
                for k, v in by_android.items()]
    androids.sort(key=lambda x: -x["sdk"])
    return {"hours": hours, "attempts": total, "delivered": ok,
            "pct": _pct(total, ok), "rows": out_rows[:60], "brands": brands,
            "androids": androids}
