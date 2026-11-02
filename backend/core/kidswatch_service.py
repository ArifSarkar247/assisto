"""
kidswatch_service.py — the ORM side of Kids Watch + Child School Mode
(owner idea 2, 28 Oct; flag `kids_watch`, OFF until the owner's real-watch
test). Synchronous ORM code called by BOTH the tracker daemon (from its
single DB worker thread, see tracker/server.py) and the HTTP views
(core/kidswatch_views.py) and the minute job (school_mode_tick).

Rules baked in (each one has a test in core/tests_kidswatch.py):
  * SAFETY IS FREE ON EVERY PLAN: watch SOS goes through the family SOS path
    (core.family_alerts — never charged, never capped, rings in quiet hours);
    school-mode alerts (arrived / left / late with last location) and the
    phone check-in button cost nothing. An unpaid watch is never refused —
    it runs in SAFETY-ONLY mode (no history, no voice, no live map refresh
    beyond the last location).
  * VOICE: 0 credits per note. Stored Fernet-encrypted on disk, deleted after
    VOICE_DAYS. The optional Bangla transcript is paid plans only, charged
    `kids_voice_transcript` (40% rule, core/logic/pricing.py) with a daily cap.
  * NO REMOTE LISTENING: commands are built only by
    tracker.protocols.watch.command_content(), which refuses MONITOR & co.
  * Location of a child goes only to the owner and the guardians the owner
    chose who are STILL accepted, unblocked Circle peers.
"""
import base64
import hashlib
import logging
import os
import secrets
from datetime import timedelta
from zoneinfo import ZoneInfo

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from .logic import school_mode as SM

log = logging.getLogger(__name__)

LOCAL_TZ = ZoneInfo("Asia/Dhaka")
PAIR_WINDOW_MIN = 30
BILLING_PERIOD_DAYS = 30
RETENTION_DAYS = 30            # position history (full mode)
VOICE_DAYS = 14                # voice notes auto-delete
MAX_VOICE_BYTES = 96 * 1024    # ~30 s AMR-NB; the watch's limit is 15 s
VOICE_UP_DAILY_CAP = 60        # per watch per day (abuse guard); SOS never capped
VOICE_DOWN_DAILY_CAP = 40      # parent replies per watch per day
TRANSCRIPT_DAILY_CAP = 20      # per user per day, paid plans only
CMD_TIMEOUT_S = 180            # sent, no ACK -> failed (no_reply)
CMD_QUEUE_MAX_H = 24           # queued but the watch never came online
ALARM_COOLDOWN_S = 1800        # low battery / removed / fall: one push per 30 min
MAX_WATCHES_PER_USER = 5
MAX_GUARDIANS = 6
BLIND_MAX_AGE_S = 600          # older re-sent (UD2) fixes are history only

MONTH_ACTION = "kids_watch_month"
TRANSCRIPT_ACTION = "kids_voice_transcript"


# --------------------------------------------------------------- basics

def normalize_id(raw):
    return "".join(ch for ch in str(raw or "") if ch.isdigit())


def id_valid(code):
    """The watch registration code: 10 digits on most SeTracker watches
    (printed under the QR code / sent back by `pw,123456,ts#`); some
    firmwares use the 15-digit IMEI."""
    return code.isdigit() and 10 <= len(code) <= 15


def audit(watch, action, **detail):
    log.info("kidswatch %s watch=%s %s", action, getattr(watch, "id", None),
             {k: v for k, v in detail.items() if k != "audio"})


def full_mode(w, now=None):
    now = now or timezone.now()
    return bool(w.billed_until and w.billed_until > now)


def month_credits():
    from . import billing
    from .logic import pricing
    try:
        return pricing.credits_for(MONTH_ACTION, 1, billing.cfg())
    except Exception:
        return 0


def charge_month(w, now=None):
    """One month of full mode for this watch. True on success."""
    from . import shop_views as SV
    now = now or timezone.now()
    need = month_credits()
    if need > 0:
        got = SV._debit_camera_credits(w.owner, need, note=MONTH_ACTION)
        if got < need:
            return False
    base = w.billed_until if (w.billed_until and w.billed_until > now) else now
    w.billed_until = base + timedelta(days=BILLING_PERIOD_DAYS)
    w.save(update_fields=["billed_until", "updated_at"])
    return True


# --------------------------------------------------------------- audience

def _peer_ok(owner, user_id):
    from .models import CircleMember
    return CircleMember.objects.filter(user=owner, peer_user_id=user_id,
                                       state="accepted", blocked=False).exists()


def clean_guardians(owner, ids):
    """Only the owner's accepted, unblocked Circle peers (never the owner)."""
    out = []
    for raw in ids or []:
        try:
            uid = int(raw)
        except (TypeError, ValueError):
            continue
        if uid != owner.id and uid not in out and _peer_ok(owner, uid):
            out.append(uid)
    return out[:MAX_GUARDIANS]


def guardians(owner, ids):
    """[owner] + still-valid guardians (re-checked on every delivery: someone
    who left the Circle stops getting the child's location at once)."""
    from .models import User
    valid = clean_guardians(owner, ids)
    return [owner] + list(User.objects.filter(pk__in=valid))


def can_view_watch(user, w):
    if not user or not user.is_authenticated:
        return False
    if w.owner_id == user.id:
        return True
    return user.id in (w.guardian_ids or []) and _peer_ok(w.owner, user.id)


def plan_watchers(plan):
    return guardians(plan.owner, plan.watcher_ids)


def can_view_plan(user, plan):
    if not user or not user.is_authenticated:
        return False
    if plan.owner_id == user.id or plan.child_user_id == user.id:
        return True
    return user.id in (plan.watcher_ids or []) and _peer_ok(plan.owner, user.id)


# --------------------------------------------------------------- notify

def _send(users, title_bn, title_en, body_bn, body_en, meta, push_kind="family_alert",
          family_alert=True, push_it=True, high=False, route="kids_watch"):
    from .models import NotifEvent, FamilyAlert
    from . import push
    for u in users:
        try:
            NotifEvent.objects.create(user=u, type="security", title_bn=title_bn[:200],
                                      title_en=title_en[:200], body_bn=body_bn,
                                      body_en=body_en, route=route, meta=meta)
        except Exception:
            pass
        if family_alert:
            try:
                lang = push.user_lang(u)
                FamilyAlert.objects.create(
                    user=u, kind="kids_watch",
                    title=(title_en if lang == "en" else title_bn)[:160],
                    body=body_en if lang == "en" else body_bn,
                    severity="high" if high else "med",
                    payload={**meta, "title_bn": title_bn, "body_bn": body_bn,
                             "title_en": title_en, "body_en": body_en})
            except Exception:
                pass
        if push_it:
            try:
                push.safe_push(u, push_kind, title_bn, title_en, body_bn, body_en,
                               data={"route": route,
                                     **{k: str(v) for k, v in meta.items()}},
                               high_priority=high)
            except Exception:
                pass


def _bn(v):
    return str(v).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


def _clock(dt, lang):
    t = dt.astimezone(LOCAL_TZ)
    h = t.hour % 12 or 12
    s = "%d:%02d" % (h, t.minute)
    return _bn(s) if lang == "bn" else s + (" am" if t.hour < 12 else " pm")


EVENT_TEXT = {
    # kind: (title_bn, title_en, body_bn, body_en)
    "left_home": ("{n} বাসা থেকে রওনা দিয়েছে", "{n} left home",
                  "{t}-এ রওনা দিয়েছে। স্কুলে পৌঁছালে জানাব।",
                  "Left at {t}. We will tell you when {n} reaches school."),
    "arrived_school": ("{n} স্কুলে পৌঁছেছে", "{n} reached school",
                       "{t}-এ স্কুলে পৌঁছেছে।", "Reached school at {t}."),
    "left_school_early": ("{n} স্কুলের সীমার বাইরে", "{n} left the school area",
                          "স্কুলের সময়ে {t}-এ স্কুলের সীমার বাইরে গেছে। শেষ অবস্থান দেখুন।",
                          "During school hours, at {t}, {n} went outside the school "
                          "area. See the last location."),
    "back_in_school": ("{n} আবার স্কুলে", "{n} is back at school",
                       "{t}-এ আবার স্কুলের সীমার ভিতরে।", "Back inside the school area at {t}."),
    "left_school": ("{n} স্কুল থেকে রওনা দিয়েছে", "{n} left school",
                    "{t}-এ রওনা দিয়েছে। বাসায় পৌঁছালে জানাব।",
                    "Left at {t}. We will tell you when {n} is home."),
    "reached_home": ("{n} বাসায় পৌঁছেছে", "{n} is home",
                     "{t}-এ বাসায় পৌঁছেছে।", "Reached home at {t}."),
    "late_school": ("{n} এখনো স্কুলে পৌঁছায়নি", "{n} has not reached school",
                    "নির্ধারিত সময় পার হয়েছে ({t})। শেষ জানা অবস্থান দেখুন ও ফোন করুন।",
                    "It is past the expected time ({t}). See the last known location "
                    "and call."),
    "late_home": ("{n} এখনো বাসায় পৌঁছায়নি", "{n} is not home yet",
                  "নির্ধারিত সময় পার হয়েছে ({t})। শেষ জানা অবস্থান দেখুন ও ফোন করুন।",
                  "It is past the expected time ({t}). See the last known location "
                  "and call."),
    "child_ok": ("{n} জানিয়েছে সে ঠিক আছে", "{n} says they are OK",
                 "{t}-এ জানিয়েছে ঠিক আছে, এখনো পৌঁছায়নি।",
                 "Said they are OK at {t}; not there yet."),
}


def event_texts(kind, name, at, lang_pair=("bn", "en")):
    tb, te, bb, be = EVENT_TEXT[kind]
    return (tb.format(n=name), te.format(n=name),
            bb.format(n=name, t=_clock(at, "bn")), be.format(n=name, t=_clock(at, "en")))


def deliver_event(plan, ev, now=None, lat=None, lng=None, voice=None):
    """Store the history row and tell the right people. 'alert' = high push +
    family card, 'push' = normal push, 'in_app' = notification centre only,
    'child' = ask the CHILD (phone) "ঠিক আছো?", 'none' = history only."""
    from .models import SchoolEvent
    now = now or timezone.now()
    kind = ev["kind"]
    lk = plan.last_known or {}
    if lat is None and kind in ("late_school", "late_home", "left_school_early"):
        lat, lng = lk.get("lat"), lk.get("lng")
    try:
        SchoolEvent.objects.create(plan=plan, kind=kind[:24], at=now, lat=lat, lng=lng,
                                   source=str(ev.get("source") or "")[:8], voice=voice,
                                   detail={k: v for k, v in ev.items()
                                           if k in ("leg", "place_match", "notify")})
    except Exception:
        log.warning("school event not stored")
    name = plan.child_name or "?"
    notify = ev.get("notify")
    if notify == "child":
        if plan.child_user_id:
            leg_bn = "স্কুলে" if ev.get("leg") == "school" else "বাসায়"
            leg_en = "school" if ev.get("leg") == "school" else "home"
            _send([plan.child_user], "ঠিক আছো?", "Are you OK?",
                  "%s পৌঁছানোর সময় পার হয়েছে। পৌঁছালে 'পৌঁছেছি' চাপো, না হলে "
                  "'আমি ঠিক আছি' চাপো।" % leg_bn,
                  "It is past your %s time. Tap 'Reached' when you are there, or "
                  "'I'm OK'." % leg_en,
                  {"plan_id": plan.id, "event": "ask_ok", "leg": ev.get("leg", "")},
                  family_alert=False, high=True, route="school_mode")
        return
    if notify == "none" or kind not in EVENT_TEXT:
        return
    tb, te, bb, be = event_texts(kind, name, now)
    if ev.get("place_match") == "inside":
        bb += " অবস্থান মিলেছে।"
        be += " Location matches."
    elif ev.get("place_match") == "outside":
        bb += " অবস্থান জায়গার সীমার বাইরে দেখাচ্ছে।"
        be += " The location shows outside the saved place."
    if voice is not None:
        bb += " একটি ভয়েস মেসেজ আছে।"
        be += " There is a voice message."
    meta = {"plan_id": plan.id, "event": kind}
    if lat is not None and lng is not None:
        meta.update(lat=lat, lng=lng)
    if voice is not None:
        meta["voice_id"] = voice.id
    _send(plan_watchers(plan), tb, te, bb, be, meta,
          family_alert=notify == "alert", push_it=notify in ("alert", "push"),
          high=notify == "alert")


# --------------------------------------------------------------- watch SOS

def watch_sos(w, lat=None, lng=None, now=None):
    """Watch SOS button -> the FAMILY SOS path (free on every plan, never
    capped, rings in quiet hours). With the child's own Assisto account the
    child's whole family Circle gets the standard SOS; the watch's owner and
    guardians always get it too (direct, if the Circle path did not reach
    them). Returns {'circle': stats|None, 'direct': [user ids]}."""
    from . import family_alerts as FA
    from . import push
    from .models import FamilyAlert, NotifEvent
    now = now or timezone.now()
    bucket = int(now.timestamp()) // FA.SOS_BUCKET_S
    name = w.child_name or "?"

    def texts(_seen_name, lang):
        if lang == "en":
            return ("SOS: %s pressed SOS on the watch" % name,
                    "Call now. Tap to see where the watch is.")
        return ("জরুরি: %s ঘড়ির SOS চেপেছে" % name,
                "এখনই ফোন করুন। ঘড়ি কোথায় দেখতে ট্যাপ করুন।")

    reached = set()
    circle = None
    if w.child_user_id:
        circle = FA.alert(w.child_user, "sos", "kw%d:%d" % (w.id, bucket),
                          payload={"source": "watch", "watch_id": w.id},
                          texts=texts, lat=lat, lng=lng, now=now)
        reached = {u.pk for u, _m in FA.consenting_members(w.child_user)}
    else:
        others = [u for u in guardians(w.owner, w.guardian_ids) if u.pk != w.owner_id]
        if others:
            circle = FA.alert(w.owner, "sos", "kw%d:%d" % (w.id, bucket),
                              payload={"source": "watch", "watch_id": w.id},
                              recipients=others, texts=texts, lat=lat, lng=lng, now=now)
            reached = {u.pk for u, _m in FA.consenting_members(w.owner)} & \
                {u.pk for u in others}
    direct = []
    key = "sos_direct:%d" % bucket
    st = dict(w.alert_state or {})
    if st.get("sos_direct") == key:
        return {"circle": circle, "direct": direct}
    st["sos_direct"] = key
    type(w).objects.filter(pk=w.pk).update(alert_state=st)
    w.alert_state = st
    for u in guardians(w.owner, w.guardian_ids):
        if u.pk in reached:
            continue
        lang = push.user_lang(u)
        tb, bb = texts(name, "bn")
        te, be = texts(name, "en")
        data = {"route": "safety/sos", "alert_kind": "sos", "event": "sos",
                "source": "watch", "watch_id": w.id, "from_name": name,
                "lat": lat if lat is not None else "", "lng": lng if lng is not None else "",
                "silent": False}
        try:
            FamilyAlert.objects.create(user=u, kind="sos",
                                       title=(te if lang == "en" else tb)[:160],
                                       body=be if lang == "en" else bb, severity="high",
                                       payload={**data, "title_bn": tb, "body_bn": bb})
            NotifEvent.objects.create(user=u, type="security", title_bn=tb, title_en=te,
                                      body_bn=bb, body_en=be, route="kids_watch",
                                      meta={"watch_id": w.id, "event": "sos",
                                            "lat": lat, "lng": lng})
        except Exception:
            pass
        push.safe_push(u, "sos", tb, te, bb, be, data=data, high_priority=True)
        direct.append(u.pk)
    plan = _plan_of(w)
    if plan is not None:
        deliver_event(plan, {"kind": "sos", "notify": "none", "source": "watch"},
                      now, lat, lng)
    audit(w, "sos", circle=bool(circle), direct=len(direct))
    return {"circle": circle, "direct": direct}


ALARM_TEXT = {
    "low_battery": ("{n}-এর ঘড়ির চার্জ কম", "{n}'s watch battery is low",
                    "চার্জ শেষ হলে অবস্থান ও SOS কাজ করবে না। আজই চার্জ দিন।",
                    "When it runs out, location and SOS stop. Charge it today."),
    "removed": ("{n}-এর ঘড়ি হাত থেকে খোলা হয়েছে", "{n}'s watch was taken off",
                "ঘড়িটি হাত থেকে খোলা হয়েছে বলে জানিয়েছে।",
                "The watch reports it was taken off the wrist."),
    "fall": ("{n}-এর ঘড়ি পড়ে যাওয়া শনাক্ত করেছে", "{n}'s watch detected a fall",
             "ঘড়ি পড়ে যাওয়ার সংকেত পাঠিয়েছে। ফোন করে খোঁজ নিন।",
             "The watch sent a fall signal. Call to check."),
    "alarm": ("{n}-এর ঘড়ি একটি সতর্কসংকেত পাঠিয়েছে", "{n}'s watch sent an alarm",
              "ঘড়ি একটি সতর্কসংকেত পাঠিয়েছে। ফোন করে খোঁজ নিন।",
              "The watch sent an alarm. Call to check."),
}


def watch_alarm(w, alarm, lat=None, lng=None, now=None):
    now = now or timezone.now()
    if alarm == "sos":
        return watch_sos(w, lat, lng, now)
    if alarm not in ALARM_TEXT:
        return None
    st = dict(w.alert_state or {})
    last = st.get("al_" + alarm)
    if last and (now.timestamp() - float(last)) < ALARM_COOLDOWN_S:
        return None
    st["al_" + alarm] = now.timestamp()
    type(w).objects.filter(pk=w.pk).update(alert_state=st)
    w.alert_state = st
    n = w.child_name or "?"
    tb, te, bb, be = (x.format(n=n) for x in ALARM_TEXT[alarm])
    meta = {"watch_id": w.id, "event": "alarm_" + alarm}
    if lat is not None:
        meta.update(lat=lat, lng=lng)
    _send(guardians(w.owner, w.guardian_ids), tb, te, bb, be, meta,
          high=alarm in ("fall", "alarm"))
    return alarm


# --------------------------------------------------------------- pairing / connect

_unknown_logged = {}


def on_watch_connect(dev_id, maker="", remote="", now=None):
    """(watch_id | None, reason, tz_min). Unknown ids are refused (rate-limited
    log). Pending + inside the pairing window -> paired (the first month of
    full mode is charged; without credits the watch still pairs, in
    SAFETY-ONLY mode). An unpaid watch is NEVER refused: safety is free."""
    from .models import KidsWatch
    now = now or timezone.now()
    code = normalize_id(dev_id)
    w = KidsWatch.objects.filter(imei=code).select_related("owner").first()
    if w is None and len(code) == 15:
        # a firmware that sends the IMEI while the box shows the 10-digit code
        cands = list(KidsWatch.objects.filter(state="pending", pair_expires_at__gte=now)
                     .exclude(imei=code)[:200])
        cands = [c for c in cands if len(c.imei) == 10 and c.imei in code]
        if len(cands) == 1:
            w = cands[0]
            w.imei = code
            w.save(update_fields=["imei", "updated_at"])
    if w is None:
        last = _unknown_logged.get(code)
        if last is None or (now - last).total_seconds() > 600:
            _unknown_logged[code] = now
            if len(_unknown_logged) > 5000:
                _unknown_logged.clear()
            log.info("kidswatch unknown id %s from %s", code[-4:], remote)
        return None, "unknown", 360
    if w.state == "disabled":
        return None, "disabled", w.tz_min
    if w.state in ("pending", "expired"):
        if w.pair_expires_at is None or now > w.pair_expires_at:
            if w.state != "expired":
                KidsWatch.objects.filter(pk=w.pk).update(state="expired")
            return None, "expired", w.tz_min
        with transaction.atomic():
            w.state = "paired"
            w.paired_at = now
            w.maker = (maker or "")[:4]
            w.save(update_fields=["state", "paired_at", "maker", "updated_at"])
        paid = charge_month(w, now)
        setup_commands(w)
        n = w.child_name or "?"
        _send([w.owner], "ঘড়ি যুক্ত হয়েছে", "Watch connected",
              ("%s-এর ঘড়ি Assisto-তে যুক্ত হয়েছে।" % n) +
              ("" if paid else " ক্রেডিট না থাকায় এখন শুধু নিরাপত্তা-মোড: SOS ও স্কুল-মোডের "
               "সতর্কতা চলবে।"),
              ("%s's watch is connected to Assisto." % n) +
              ("" if paid else " Without credits it runs in safety-only mode: SOS and "
               "school-mode alerts still work."),
              {"watch_id": w.id, "event": "paired"}, family_alert=False)
        audit(w, "paired", paid=paid, remote=remote)
        return w.id, "newly_paired", w.tz_min
    if maker and w.maker != maker[:4]:
        KidsWatch.objects.filter(pk=w.pk).update(maker=maker[:4])
    return w.id, "paired", w.tz_min


def queue(w, kind, payload=None, actor=None, replace=True):
    """Queue a server->watch command (validated now, built at send time)."""
    from tracker.protocols import watch as WP
    from .models import KidsWatchCommand
    if kind not in WP.COMMAND_KINDS:
        raise WP.ForbiddenCommand(kind)
    p = dict(payload or {})
    if kind != "voice_down":
        WP.command_content(kind, p)          # raises on bad params / forbidden
    if replace and kind not in ("voice_down", "message"):
        KidsWatchCommand.objects.filter(watch=w, kind=kind, state="queued") \
            .update(state="cancelled", done_at=timezone.now())
    return KidsWatchCommand.objects.create(watch=w, kind=kind, payload=p,
                                           requested_by=actor)


def setup_commands(w):
    """First commands after pairing: Bangladesh time zone, step counter,
    low-battery alarm, the SOS numbers (if set) and the battery plan interval."""
    apply_phase(w, force=True)
    queue(w, "timezone", {"tz_hours": w.tz_min / 60.0, "lang": 1})
    if w.sos_numbers:
        queue(w, "sos_numbers", {"numbers": w.sos_numbers})
    queue(w, "steps_on")
    queue(w, "low_battery_alarm")


def apply_phase(w, now=None, force=False):
    """Battery plan: UPLOAD interval by the school schedule (1 min commuting,
    10 min at home / school, 60 min at night / days off). Queues a command
    only when the phase changes."""
    from tracker.protocols import watch as WP
    now = now or timezone.now()
    plan = _plan_of(w)
    if plan is not None and plan.enabled and plan.config:
        try:
            cfg = SM.validate(plan.config)
        except ValueError:
            cfg = None
    else:
        cfg = None
    local = now.astimezone(LOCAL_TZ)
    phase = SM.battery_phase(cfg, plan.day, local) if cfg else "off"
    if phase == w.phase and not force:
        return None
    type(w).objects.filter(pk=w.pk).update(phase=phase)
    w.phase = phase
    return queue(w, "set_interval", {"seconds": WP.interval_for(phase), "phase": phase})


def _plan_of(w):
    from .models import SchoolPlan
    return SchoolPlan.objects.filter(watch=w).select_related(
        "owner", "child_user").first()


# --------------------------------------------------------------- ingest

def ingest(batch, now=None):
    """Persist a batch from the daemon:
    {watch_id: {"fixes": [fix..], "link": {battery, steps}, "alarms":
    [[alarm, lat, lng]]}}. Returns positions written."""
    from .models import KidsWatch, KidsWatchPosition
    now = now or timezone.now()
    written = 0
    for w in KidsWatch.objects.filter(pk__in=list(batch.keys())).select_related(
            "owner", "child_user"):
        item = batch.get(w.id) or {}
        fields = {"last_seen_at": now}
        link = item.get("link") or {}
        if link.get("battery") is not None:
            fields["battery"] = int(link["battery"])
        if link.get("steps") is not None:
            fields["steps"] = int(link["steps"])
        full = full_mode(w, now)
        plan = _plan_of(w)
        cfg = None
        if plan is not None and plan.enabled and plan.config:
            try:
                cfg = SM.validate(plan.config)
            except ValueError:
                cfg = None
        rows = []
        learned = False
        for f in sorted(item.get("fixes") or [], key=lambda f: f.get("at") or now):
            at = f.get("at") or now
            if at > now + timedelta(minutes=5):
                at = now
            if f.get("battery") is not None:
                fields["battery"] = f["battery"]
            lat = f.get("lat") if f.get("valid") else None
            lng = f.get("lng") if f.get("valid") else None
            src = "gps" if f.get("valid") else ""
            if lat is None and cfg:
                # indoors, no GPS: a Wi-Fi MAC learned at home / school counts
                for pname in ("school", "home"):
                    if SM.relation(cfg.get(pname), None, None, f.get("wifi")) == "in":
                        lat, lng, src = cfg[pname]["lat"], cfg[pname]["lng"], "wifi"
                        break
            if lat is not None:
                if full:
                    rows.append(KidsWatchPosition(watch=w, at=at, lat=lat, lng=lng,
                                                  source=src, acc_m=f.get("acc_m"),
                                                  battery=f.get("battery")))
                if w.last_fix_at is None or at >= w.last_fix_at:
                    w.last_fix_at = at
                    fields.update(last_fix_at=at, last_lat=lat, last_lng=lng,
                                  last_acc_m=f.get("acc_m"), last_source=src)
            fresh = (now - at).total_seconds() <= BLIND_MAX_AGE_S and not f.get("blind")
            if plan is None or cfg is None or not fresh or plan.accepted_at is None:
                continue
            if src == "gps" and f.get("wifi"):
                for pname in ("school", "home"):
                    if cfg.get(pname) and SM.relation(cfg[pname], lat, lng) == "in":
                        macs = SM.learn_wifi(cfg[pname], f["wifi"])
                        if macs != cfg[pname].get("wifi"):
                            cfg[pname]["wifi"] = macs
                            learned = True
            local = at.astimezone(LOCAL_TZ)
            day, evs = SM.on_fix(cfg, plan.day, local, lat, lng, f.get("wifi"), src or "lbs")
            plan.day = day
            if lat is not None:
                plan.last_known = {"lat": lat, "lng": lng, "at": at.isoformat(),
                                   "source": src}
            for ev in evs:
                deliver_event(plan, ev, now, lat, lng)
        if plan is not None and cfg is not None:
            upd = {"day": plan.day, "last_known": plan.last_known}
            if learned:
                upd["config"] = cfg
            type(plan).objects.filter(pk=plan.pk).update(**upd)
        KidsWatch.objects.filter(pk=w.id).update(**fields)
        if rows:
            KidsWatchPosition.objects.bulk_create(rows)
            written += len(rows)
        for al in item.get("alarms") or []:
            alarm, lat, lng = (list(al) + [None, None])[:3]
            if lat is None:
                lat, lng = fields.get("last_lat", w.last_lat), fields.get("last_lng", w.last_lng)
            watch_alarm(w, alarm, lat, lng, now)
        if cfg is not None:
            apply_phase(w, now)
    return written


# --------------------------------------------------------------- voice storage

def _fernet():
    from cryptography.fernet import Fernet, MultiFernet
    keys = []
    env = (os.getenv("KIDSVOICE_FERNET_KEY") or "").strip()
    if env:
        try:
            keys.append(Fernet(env.encode()))
        except Exception:
            log.warning("KIDSVOICE_FERNET_KEY is not a valid Fernet key")
    derived = base64.urlsafe_b64encode(hashlib.sha256(
        ("assisto-kidsvoice:" + settings.SECRET_KEY).encode()).digest())
    keys.append(Fernet(derived))
    return MultiFernet(keys)


def voice_dir():
    d = getattr(settings, "KIDSVOICE_ROOT", None) or os.path.join(
        str(settings.MEDIA_ROOT), "kidsvoice")
    os.makedirs(d, exist_ok=True)
    return d


def store_audio(data):
    name = "kv_%s.bin" % secrets.token_hex(12)
    with open(os.path.join(voice_dir(), name), "wb") as fh:
        fh.write(_fernet().encrypt(bytes(data)))
    return name


def read_audio(note):
    if not note.file_name:
        return b""
    try:
        with open(os.path.join(voice_dir(), note.file_name), "rb") as fh:
            return _fernet().decrypt(fh.read())
    except Exception:
        return b""


def delete_audio(note):
    if note.file_name:
        try:
            os.remove(os.path.join(voice_dir(), note.file_name))
        except OSError:
            pass


_AMR_SIZES = (12, 13, 15, 17, 19, 20, 26, 31, 5, 0, 0, 0, 0, 0, 0, 0)


def amr_duration(data):
    """Seconds of an AMR-NB file (20 ms per frame), or None if not AMR."""
    if not data.startswith(b"#!AMR\n"):
        return None
    i, frames = 6, 0
    while i < len(data):
        size = _AMR_SIZES[(data[i] >> 3) & 0x0F]
        i += 1 + size
        frames += 1
        if frames > 100000:
            break
    return round(frames * 0.02, 2)


def _voice_today(qs, now):
    start = now.astimezone(LOCAL_TZ).replace(hour=0, minute=0, second=0, microsecond=0)
    return qs.filter(created_at__gte=start).count()


def voice_up(watch_id, audio, now=None):
    """The child pressed the watch voice button. Stored encrypted, 0 credits,
    pushed to the guardians with time + last location. Full mode only (the
    watch is told TK,1 either way so it does not retry forever)."""
    from .models import KidsWatch, KidsVoiceNote
    now = now or timezone.now()
    w = KidsWatch.objects.filter(pk=watch_id).select_related("owner").first()
    if w is None or not audio:
        return None
    if len(audio) > MAX_VOICE_BYTES:
        audit(w, "voice_too_big", size=len(audio))
        return None
    if not full_mode(w, now):
        _send([w.owner], "ভয়েস মেসেজ এসেছিল", "A voice message arrived",
              "%s ঘড়ি থেকে ভয়েস পাঠিয়েছে, কিন্তু ঘড়িটি এখন শুধু নিরাপত্তা-মোডে। মাসিক "
              "ক্রেডিট দিলে ভয়েস মেসেজ চালু হবে।" % (w.child_name or "?"),
              "%s sent a voice message from the watch, but the watch is in safety-only "
              "mode. Add the monthly credits to turn voice messages on."
              % (w.child_name or "?"), {"watch_id": w.id, "event": "voice_safety_only"},
              family_alert=False)
        return None
    if _voice_today(KidsVoiceNote.objects.filter(watch=w, direction="up"), now) >= \
            VOICE_UP_DAILY_CAP:
        audit(w, "voice_cap")
        return None
    note = KidsVoiceNote.objects.create(
        watch=w, direction="up", file_name=store_audio(audio), mime="audio/amr",
        size=len(audio), duration_s=amr_duration(audio), lat=w.last_lat, lng=w.last_lng,
        at=now, state="stored", expires_at=now + timedelta(days=VOICE_DAYS))
    n = w.child_name or "?"
    meta = {"watch_id": w.id, "voice_id": note.id, "event": "voice"}
    if w.last_lat is not None:
        meta.update(lat=w.last_lat, lng=w.last_lng)
    _send(guardians(w.owner, w.guardian_ids), "%s ভয়েস পাঠিয়েছে" % n,
          "Voice message from %s" % n,
          "%s-এ পাঠানো। শুনতে ট্যাপ করুন।" % _clock(now, "bn"),
          "Sent at %s. Tap to listen." % _clock(now, "en"), meta, family_alert=False)
    return note


def voice_down(w, user, audio, mime="audio/amr", now=None):
    """A parent's voice reply -> queued TK push to the watch. AMR-NB only (the
    watch plays nothing else). Returns (note, reason)."""
    from .models import KidsVoiceNote
    now = now or timezone.now()
    if not full_mode(w, now):
        return None, "safety_only"
    if not audio or len(audio) > MAX_VOICE_BYTES:
        return None, "bad_audio"
    if not audio.startswith(b"#!AMR\n"):
        return None, "not_amr"
    if _voice_today(KidsVoiceNote.objects.filter(watch=w, direction="down"), now) >= \
            VOICE_DOWN_DAILY_CAP:
        return None, "daily_cap"
    note = KidsVoiceNote.objects.create(
        watch=w, direction="down", sender=user, file_name=store_audio(audio),
        mime="audio/amr", size=len(audio), duration_s=amr_duration(audio), at=now,
        state="queued", heard_by=[user.id], expires_at=now + timedelta(days=VOICE_DAYS))
    queue(w, "voice_down", {"voice_id": note.id}, actor=user, replace=False)
    return note, "queued"


def purge_voice(now=None):
    from .models import KidsVoiceNote
    now = now or timezone.now()
    n = 0
    for note in KidsVoiceNote.objects.filter(expires_at__lt=now)[:500]:
        delete_audio(note)
        note.delete()
        n += 1
    return n


def delete_note(note):
    delete_audio(note)
    note.delete()


# --------------------------------------------------------------- transcript

def transcript(note, user, now=None):
    """Optional Bangla transcript of a child's voice note. PAID plans only,
    `kids_voice_transcript` credits (40% rule), TRANSCRIPT_DAILY_CAP per user
    per day, refunded on a provider failure. Never invented: no speech key =
    no transcript ('no_key')."""
    from django.core.cache import cache
    from . import billing, plans
    from . import bizagent_media as BM
    from .models import KidsVoiceNote
    now = now or timezone.now()
    if note.transcript_state == "done":
        return {"ok": True, "text": note.transcript, "charged": 0}
    if plans.effective_plan(user) == "free":
        return {"ok": False, "reason": "paid_only"}
    ckey = "kv_tr:%d:%s" % (user.id, now.astimezone(LOCAL_TZ).date().isoformat())
    if int(cache.get(ckey) or 0) >= TRANSCRIPT_DAILY_CAP:
        return {"ok": False, "reason": "daily_cap"}
    conf = BM.stt_config()
    if not conf:
        return {"ok": False, "reason": "no_key"}
    data = read_audio(note)
    if not data:
        return {"ok": False, "reason": "gone"}
    res = billing.charge(user, TRANSCRIPT_ACTION, qty=1, note="kidswatch.transcript")
    if not res.get("ok"):
        return {"ok": False, "reason": res.get("reason") or "insufficient"}
    charged = int(res.get("charged") or 0)
    try:
        text = BM._transcriber(conf, data, note.mime, "bn")
    except Exception as e:  # noqa: BLE001
        if charged:
            billing.credit(user, "adjust", charged, note="kidswatch.transcript_refund")
        return {"ok": False, "reason": "stt_" + type(e).__name__}
    text = str(text or "")[:2000]
    KidsVoiceNote.objects.filter(pk=note.pk).update(transcript=text,
                                                   transcript_state="done")
    cache.set(ckey, int(cache.get(ckey) or 0) + 1, 26 * 3600)
    return {"ok": True, "text": text, "charged": charged}


# --------------------------------------------------------------- commands (daemon)

def pending_for(watch_ids):
    """Oldest queued command per watch, with voice audio attached."""
    from .models import KidsWatchCommand, KidsVoiceNote
    out, seen = [], set()
    for c in KidsWatchCommand.objects.filter(watch_id__in=list(watch_ids),
                                             state="queued").order_by("id")[:200]:
        if c.watch_id in seen:
            continue
        seen.add(c.watch_id)
        p = dict(c.payload or {})
        if c.kind == "voice_down":
            note = KidsVoiceNote.objects.filter(pk=p.get("voice_id")).first()
            audio = read_audio(note) if note else b""
            if not audio:
                KidsWatchCommand.objects.filter(pk=c.pk).update(
                    state="failed", error="audio_gone", done_at=timezone.now())
                continue
            p["audio"] = audio
        out.append({"id": c.id, "watch_id": c.watch_id, "kind": c.kind, "payload": p})
    return out


def mark_sent(cmd_id, ack_type, now=None):
    from .models import KidsWatchCommand, KidsVoiceNote
    now = now or timezone.now()
    c = KidsWatchCommand.objects.filter(pk=cmd_id).first()
    if c is None:
        return
    c.state, c.ack_type, c.sent_at = "sent", ack_type[:16], now
    c.save(update_fields=["state", "ack_type", "sent_at"])
    if c.kind == "voice_down":
        KidsVoiceNote.objects.filter(pk=(c.payload or {}).get("voice_id")).update(state="sent")


def mark_failed(cmd_id, error):
    from .models import KidsWatchCommand, KidsVoiceNote
    c = KidsWatchCommand.objects.filter(pk=cmd_id).first()
    if c is None:
        return
    KidsWatchCommand.objects.filter(pk=cmd_id).update(state="failed", error=error[:40],
                                                      done_at=timezone.now())
    if c.kind == "voice_down":
        KidsVoiceNote.objects.filter(pk=(c.payload or {}).get("voice_id")).update(
            state="failed")


def mark_ack(watch_id, ack_type, now=None):
    """The watch echoed a command type -> the oldest SENT command of that type
    is acked (honest: only the watch's own reply acks a command)."""
    from .models import KidsWatch, KidsWatchCommand, KidsVoiceNote
    now = now or timezone.now()
    c = KidsWatchCommand.objects.filter(watch_id=watch_id, state="sent",
                                        ack_type=ack_type[:16]).order_by("id").first()
    if c is None:
        return None
    c.state, c.done_at = "acked", now
    c.save(update_fields=["state", "done_at"])
    if c.kind == "set_interval":
        KidsWatch.objects.filter(pk=watch_id).update(
            interval_s=int((c.payload or {}).get("seconds") or 0) or None)
    elif c.kind == "voice_down":
        KidsVoiceNote.objects.filter(pk=(c.payload or {}).get("voice_id")).update(
            state="acked")
    return c.id


def expire_commands(now=None):
    from .models import KidsWatchCommand, KidsVoiceNote
    now = now or timezone.now()
    n = 0
    for c in KidsWatchCommand.objects.filter(state="sent",
                                             sent_at__lt=now - timedelta(seconds=CMD_TIMEOUT_S)):
        c.state, c.error, c.done_at = "failed", "no_reply", now
        c.save(update_fields=["state", "error", "done_at"])
        if c.kind == "voice_down":
            KidsVoiceNote.objects.filter(pk=(c.payload or {}).get("voice_id")).update(
                state="failed")
        n += 1
    n += KidsWatchCommand.objects.filter(
        state="queued", created_at__lt=now - timedelta(hours=CMD_QUEUE_MAX_H)).update(
        state="failed", error="watch_offline", done_at=now)
    return n


def touch(watch_id, now=None):
    from .models import KidsWatch
    KidsWatch.objects.filter(pk=watch_id).update(last_seen_at=now or timezone.now())


# --------------------------------------------------------------- phone check-in

def phone_checkin(plan, kind, lat=None, lng=None, audio=None, mime="audio/mp4",
                  now=None):
    """The child's big button. Location only if the child allowed it at that
    moment; voice optional (stored encrypted, 0 credits). Returns events."""
    from .models import KidsVoiceNote
    now = now or timezone.now()
    cfg = SM.validate(plan.config)
    local = now.astimezone(LOCAL_TZ)
    day, evs = SM.on_checkin(cfg, plan.day, local, kind, lat, lng)
    voice = None
    if audio:
        if len(audio) > MAX_VOICE_BYTES * 2:
            raise ValueError("audio_too_big")
        voice = KidsVoiceNote.objects.create(
            plan=plan, direction="up", sender=plan.child_user,
            file_name=store_audio(audio), mime=mime[:24], size=len(audio),
            duration_s=amr_duration(audio), lat=lat, lng=lng, at=now, state="stored",
            heard_by=[plan.child_user_id] if plan.child_user_id else [],
            expires_at=now + timedelta(days=VOICE_DAYS))
    plan.day = day
    upd = {"day": day}
    if lat is not None and lng is not None:
        plan.last_known = {"lat": lat, "lng": lng, "at": now.isoformat(), "source": "phone"}
        upd["last_known"] = plan.last_known
    type(plan).objects.filter(pk=plan.pk).update(**upd)
    for ev in evs:
        deliver_event(plan, ev, now, lat, lng, voice=voice)
    return evs


# --------------------------------------------------------------- minute job

def tick(now=None):
    """school_mode_tick: late checks, school-over, battery phase, voice purge,
    stale commands, position prune, monthly renewal. Never raises per plan."""
    from .models import SchoolPlan, KidsWatch, KidsWatchPosition
    now = now or timezone.now()
    local = now.astimezone(LOCAL_TZ)
    out = {"plans": 0, "events": 0, "phase_cmds": 0}
    for plan in SchoolPlan.objects.filter(enabled=True, accepted_at__isnull=False) \
            .select_related("owner", "child_user", "watch")[:5000]:
        try:
            cfg = SM.validate(plan.config)
        except ValueError:
            continue
        try:
            day, evs = SM.on_tick(cfg, plan.day, local, phone=plan.watch_id is None)
            if day != plan.day:
                SchoolPlan.objects.filter(pk=plan.pk).update(day=day)
                plan.day = day
            for ev in evs:
                deliver_event(plan, ev, now)
            out["events"] += len(evs)
            if plan.watch_id and plan.watch.state == "paired":
                if apply_phase(plan.watch, now):
                    out["phase_cmds"] += 1
            out["plans"] += 1
        except Exception:
            log.exception("school plan %s tick failed", plan.pk)
    out["voice_purged"] = purge_voice(now)
    out["cmds_expired"] = expire_commands(now)
    out["pruned"] = KidsWatchPosition.objects.filter(
        at__lt=now - timedelta(days=RETENTION_DAYS)).delete()[0] if local.minute == 7 else 0
    renewed = 0
    for w in KidsWatch.objects.filter(state="paired", billed_until__lt=now,
                                      billed_until__gt=now - timedelta(days=2)) \
            .select_related("owner")[:200]:
        if charge_month(w, now):
            renewed += 1
    out["renewed"] = renewed
    return out
