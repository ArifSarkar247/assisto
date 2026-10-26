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

# calls95: resend schedule — seconds after PLACEMENT at which the ring push
# goes out again while the callee phone has not acked (first push is
# immediate). Front-loaded (a phone whose FCM socket was stale after idle
# often takes the 2nd/3rd copy), then spread across the 45 s ring window so a
# phone coming back online mid-ring still gets a fresh (30 s TTL) copy.
RESEND_SCHEDULE_S = (2, 4, 8, 16, 24)
RESEND_MIN_GAP_S = 1.5  # never two sends closer than this
RESEND_AFTER_S = RESEND_SCHEDULE_S[0]   # (old name: first resend)
MAX_RESENDS = len(RESEND_SCHEDULE_S)
EARLY_CANCEL_S = 4      # caller hung up this fast -> not a delivery attempt
TARGET_PCT = 95         # owner goal: >= 95 % overall and per brand
# calls95: brands whose battery manager is known to delay / drop FCM for an
# idle app (Bangladesh fleet + dontkillmyapp.com). Owner Admin flags them and
# the app offers the per-brand setup checklist.
PROBLEM_BRANDS = ("realme", "oppo", "oneplus", "vivo", "iqoo", "xiaomi",
                  "redmi", "poco", "infinix", "tecno", "itel", "huawei",
                  "honor", "samsung")
# first app build with the native delivered ack (ring-everywhere, 24 Oct)
NATIVE_ACK_BUILD = 10224
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


def clean_app(data):
    """App version string from an ack ("1.0.244+10244"), short + printable."""
    v = str((data or {}).get("app", (data or {}).get("app_version", "")) or "")
    v = "".join(ch for ch in v.strip() if ch.isprintable() and ch != " ")
    return v[:24]


def app_build(version):
    """10244 from "1.0.244+10244" (0 when unknown)."""
    try:
        tail = str(version or "").rsplit("+", 1)[1] if "+" in str(version or "") else ""
        return int(tail) if tail.isdigit() else 0
    except Exception:
        return 0


def stamp_callee_device(sess, callee):
    """At placement: remember the callee's newest registered phone's app
    version on the session, so the per-app-version stats describe the build
    AT CALL TIME (a later update must not rewrite history). The native ack
    overwrites it with the version of the phone that answered. Brand / model
    / sdk come from the ack (fallback: the Device row). Returns the
    update_fields list (caller saves). Never raises."""
    try:
        from .models import Device
        d = (Device.objects.filter(user=callee).exclude(push_token="")
             .order_by("-last_seen", "-id").only("app_version").first())
        if d is None:
            return []
        upd = []
        if d.app_version and not getattr(sess, "callee_app", ""):
            sess.callee_app = d.app_version[:24]
            upd.append("callee_app")
        return upd
    except Exception:
        return []


def android_label(sdk):
    if not sdk:
        return "?"
    return "Android %s (%d)" % (ANDROID.get(int(sdk), "?"), int(sdk))


# ---------------------------------------------------------------- resend
def next_resend_at_s(resends):
    """Seconds after placement when resend number `resends`+1 is due, or None
    when the schedule is used up."""
    n = int(resends or 0)
    return RESEND_SCHEDULE_S[n] if 0 <= n < len(RESEND_SCHEDULE_S) else None


def due_resend(state, now, started_at, last_push_at, push_sent, ringing_at,
               delivered_at, resends):
    """Pure rule: should the ring push go out again now?
    calls95: resend k is due RESEND_SCHEDULE_S[k] s after placement (and at
    least RESEND_MIN_GAP_S after the previous send) until the phone acks."""
    if state != "ringing" or not push_sent:
        return False
    if ringing_at is not None or delivered_at is not None:
        return False
    at = next_resend_at_s(resends)
    if at is None:
        return False
    start = started_at or last_push_at
    if start is None:
        return False
    if (now - start).total_seconds() < at:
        return False
    if last_push_at is not None and \
            (now - last_push_at).total_seconds() < RESEND_MIN_GAP_S:
        return False
    return True


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
    app = clean_app(data)
    upd = []
    first_delivery = False
    if stage in ("delivered", "ringing") and sess.delivered_at is None:
        sess.delivered_at = now
        upd.append("delivered_at")
        first_delivery = sess.ringing_at is None
    if brand and not sess.callee_brand:
        sess.callee_brand, sess.callee_model, sess.callee_sdk = brand, model, sdk
        upd += ["callee_brand", "callee_model", "callee_sdk"]
    if app and app != getattr(sess, "callee_app", ""):
        # the phone that ACKED is the truth (placement stamped the newest
        # registered device's version)
        sess.callee_app = app
        upd.append("callee_app")
    if upd:
        sess.save(update_fields=upd)
    if first_delivery and stage == "delivered" and rec.state == "ringing":
        # calls95: caller flips "Calling" -> "Ringing" on delivery
        C.publish_state(rec)
    if stage == "ringing":
        if rec.state == "ringing" and sess.ringing_at is None:
            sess.ringing_at = now
            sess.save(update_fields=["ringing_at"])
            C.publish_state(rec)
    elif stage == "decline":
        C.apply_event(rec, "callee", "decline", now=now)
        rec.refresh_from_db()
    ended = not CS.is_live(rec.state)
    return {"ok": True,
            "phase": CS.phase(rec.state, sess.ringing_at, sess.delivered_at),
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
MISS_CAUSES = ("old_build", "push_error", "late_ack", "woke_late", "offline")


def judge(rec, sess, dev=None, push_errors=frozenset()):
    """calls95: one call's verdict for the delivery stats.

    Returns None when the call is not a delivery attempt (self call, no ring
    push went to a device, still ringing and not acked yet), else a dict
    {early_cancel, delivered, cause, brand, model, sdk, app}.

      early_cancel  caller hung up < EARLY_CANCEL_S after placing (shown
                    separately, NOT in the rate: no phone could ring that fast)
      delivered     the callee phone acked (native delivered or ringing) while
                    the call was still ringing / live
      cause         for a miss: old_build (app older than the native ack) |
                    push_error (FCM refused every token / no device) |
                    late_ack (the ack came after the call ended: phone asleep,
                    OEM delay) | woke_late (no ack, but the phone polled after
                    the end) | offline (never heard from: no network / off)
    """
    from .logic import call_signal as CS
    if sess is None or rec.callee_id == rec.caller_id:
        return None
    if not getattr(sess, "push_sent", False):
        return None
    acks = [t for t in (getattr(sess, "delivered_at", None), sess.ringing_at)
            if t is not None]
    first_ack = min(acks) if acks else None
    live = CS.is_live(rec.state)
    if first_ack is None and live:
        return None                       # not judged yet
    end = rec.ended_at
    early = (sess.end_reason == "canceled" and sess.ended_by == "caller"
             and end is not None and rec.started_at is not None
             and (end - rec.started_at).total_seconds() < EARLY_CANCEL_S)
    delivered = first_ack is not None and (live or end is None or first_ack <= end)
    dbrand, dmodel, dsdk, dapp = dev or ("", "", 0, "")
    if sess.callee_brand:
        brand, model, sdk = sess.callee_brand, sess.callee_model, sess.callee_sdk
    else:
        brand, model, sdk = dbrand, dmodel, dsdk
    app = getattr(sess, "callee_app", "") or dapp or ""
    cause = ""
    if not delivered and not early:
        b = app_build(app)
        if b and b < NATIVE_ACK_BUILD:
            cause = "old_build"
        elif rec.id in push_errors:
            cause = "push_error"
        elif first_ack is not None:
            cause = "late_ack"
        elif sess.callee_seen_at is not None and end is not None \
                and sess.callee_seen_at > end:
            cause = "woke_late"
        else:
            cause = "offline"
    return {"early_cancel": bool(early), "delivered": bool(delivered),
            "cause": cause, "brand": (brand or "?").lower(),
            "model": model or "?", "sdk": int(sdk or 0), "app": app or "?"}


def _verdicts(since, until=None):
    """[(rec, verdict)] for calls placed in [since, until)."""
    from .models import CallHealthEvent, CallRecord, Device
    qs = CallRecord.objects.filter(started_at__gte=since)
    if until is not None:
        qs = qs.filter(started_at__lt=until)
    recs = list(qs.select_related("session").order_by("started_at"))
    ids = [r.id for r in recs]
    errs = set()
    if ids:
        errs = set(CallHealthEvent.objects.filter(
            step="push", code__in=("no_device", "send_fail"),
            call_id__in=ids).values_list("call_id", flat=True))
    dev_cache = {}

    def _dev(uid):
        if uid not in dev_cache:
            d = (Device.objects.filter(user_id=uid)
                 .order_by("-last_seen", "-id").first())
            dev_cache[uid] = ((d.brand, d.model, d.sdk_int, d.app_version)
                              if d else ("", "", 0, ""))
        return dev_cache[uid]

    out = []
    for r in recs:
        sess = getattr(r, "session", None)
        if sess is None or not getattr(sess, "push_sent", False):
            continue
        v = judge(r, sess, _dev(r.callee_id), errs)
        if v is not None:
            out.append((r, v))
    return out


def _pct(a, d):
    return round(100.0 * d / a) if a else None


def _agg(verdicts):
    """Counts for a list of verdicts (early cancels excluded from the rate)."""
    total = ok = early = 0
    by = {"rows": {}, "brand": {}, "android": {}, "app": {}}
    causes = {}
    for r, v in verdicts:
        if v["early_cancel"]:
            early += 1
            continue
        total += 1
        ok += int(v["delivered"])
        if v["cause"]:
            causes[v["cause"]] = causes.get(v["cause"], 0) + 1
        res = int(getattr(r.session, "push_resends", 0) or 0)
        for kind, key in (("rows", (v["brand"], v["model"], v["sdk"])),
                          ("brand", v["brand"]), ("android", v["sdk"]),
                          ("app", v["app"])):
            b = by[kind].setdefault(key, [0, 0, 0])
            b[0] += 1
            b[1] += int(v["delivered"])
            b[2] += res
    return total, ok, early, by, causes


def _row(a, d):
    p = _pct(a, d)
    return {"attempts": a, "delivered": d, "pct": p,
            "below": p is not None and p < TARGET_PCT}


def delivery_stats(hours=24 * 7, now=None):
    """Owner Admin: call ring delivery overall + by brand / model / Android /
    app version, against the TARGET_PCT goal.

    Counted: calls in the window whose ring push went to a device of the
    callee (push_sent). Delivered = the callee phone acked (native delivered
    ack, or the ringing ack from Dart / in-app) while the call still rang.
    Calls still ringing and not yet acked are not judged yet; calls the
    caller hung up within EARLY_CANCEL_S are counted separately
    (`early_cancels`) and left out of the rate."""
    now = now or timezone.now()
    since = now - timedelta(hours=hours)
    total, ok, early, by, causes = _agg(_verdicts(since))
    out_rows = [dict(_row(v[0], v[1]), brand=k[0], model=k[1], sdk=k[2],
                     android=android_label(k[2]), resends=v[2])
                for k, v in by["rows"].items()]
    out_rows.sort(key=lambda x: (-x["attempts"], x["brand"], x["model"]))
    brands = [dict(_row(v[0], v[1]), brand=k, problem=k in PROBLEM_BRANDS)
              for k, v in by["brand"].items()]
    brands.sort(key=lambda x: (-x["attempts"], x["brand"]))
    androids = [dict(_row(v[0], v[1]), sdk=k, android=android_label(k))
                for k, v in by["android"].items()]
    androids.sort(key=lambda x: -x["sdk"])
    apps = [dict(_row(v[0], v[1]), app=k, build=app_build(k),
                 native_ack=app_build(k) >= NATIVE_ACK_BUILD)
            for k, v in by["app"].items()]
    apps.sort(key=lambda x: (-x["build"], x["app"]))
    miss = [{"cause": c, "count": causes[c]} for c in MISS_CAUSES
            if causes.get(c)]
    pct = _pct(total, ok)
    return {"hours": hours, "days": max(1, round(hours / 24)),
            "attempts": total, "delivered": ok, "pct": pct,
            "target": TARGET_PCT, "below": pct is not None and pct < TARGET_PCT,
            "early_cancels": early, "rows": out_rows[:60], "brands": brands,
            "androids": androids, "apps": apps, "causes": miss,
            "brands_below": [b["brand"] for b in brands if b["below"]]}


# ---------------------------------------------------------------- daily trend
def snapshot_days(days=30, now=None):
    """Upsert one CallDeliveryDaily row per calendar day (server TZ) for the
    last `days` days. A finished day that already has a row is skipped;
    today (and yesterday, for late acks) are re-written on every run.
    Called from Owner Admin -> Calls and `manage.py calls_delivery_snapshot`.
    Returns the number of rows written. Never raises."""
    try:
        from .models import CallDeliveryDaily
        now = now or timezone.now()
        today = timezone.localdate(now)
        days = max(1, int(days))
        first = today - timedelta(days=days - 1)
        have = set(CallDeliveryDaily.objects.filter(
            date__gte=first).values_list("date", flat=True))
        n = 0
        for i in range(days):
            day = first + timedelta(days=i)
            if day in have and day < today - timedelta(days=1):
                continue
            start = timezone.make_aware(
                timezone.datetime(day.year, day.month, day.day))
            total, ok, early, by, causes = _agg(
                _verdicts(start, start + timedelta(days=1)))
            if not (total or early) and day not in have and day != today:
                continue                  # no calls that day: no row

            def _m(d):
                return {str(k): [v[0], v[1]] for k, v in d.items()}
            CallDeliveryDaily.objects.update_or_create(date=day, defaults={
                "attempts": total, "delivered": ok, "early_cancels": early,
                "by_brand": _m(by["brand"]), "by_android": _m(by["android"]),
                "by_app": _m(by["app"]), "causes": causes})
            n += 1
        return n
    except Exception:
        log.exception("ring: snapshot_days failed")
        return 0


def trend(days=30, now=None):
    """Daily rows (oldest first) for the Owner Admin trend table."""
    try:
        from .models import CallDeliveryDaily
        now = now or timezone.now()
        first = timezone.localdate(now) - timedelta(days=int(days) - 1)
        rows = []
        for d in CallDeliveryDaily.objects.filter(
                date__gte=first).order_by("date"):
            row = _row(d.attempts, d.delivered)
            row.update(date=d.date, early_cancels=d.early_cancels,
                       bar=row["pct"] if row["pct"] is not None else 0)
            rows.append(row)
        return rows
    except Exception:
        log.exception("ring: trend failed")
        return []
