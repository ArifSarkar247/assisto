"""
cctvx_views.py — CCTV extras (owner order 28 Oct: "beat every CCTV app").
The rules are pure in core/logic/cctv_extras.py; this file is the DB / push
/ API glue. Builds on shop_views (ingest, alert text), cashguard_views
(encrypted clips) and watchman_views (gateway tasks).

OWNER (Token auth, flag home_watchman)
  GET/PUT shop/sites/<id>/guard           settings (no-sale window, escalation
                                          chain, offline / late / opened, shop
                                          phone, closed days) + Circle people
                                          + today's usage vs the plan caps
  GET  shop/sites/<id>/guard/report       today's guard report (= the evening
                                          brief section, 0 credits)
  GET  shop/sites/<id>/privacy-kit        sticker + staff notice (bn + en)
  GET  shop/cameras/<id>/placement        placement helper (image stats)
ANYONE WHO MAY SEE THE ALERT (owner, family viewer, escalated person,
shared-clip person)
  GET  shop/events/<id>                   the alert + what can be done from it
  POST shop/events/<id>/opened            "I have seen it" -> escalation stops
OWNER (+ an escalated manager for the siren)
  POST shop/events/<id>/siren             camera siren where a documented API
                                          exists (Imou cloud, Hikvision LAN)
  GET  shop/events/<id>/share-targets     Circle people with a phone key
  POST shop/events/<id>/clip/share        re-wrapped clip key for ONE member
  GET  shop/events/<id>/evidence          facts + GD draft for the evidence
                                          pack the PHONE builds (no media here)

SERVER JOBS (no WorkManager): shop_guard_tick every minute runs the due
no-sale checks, escalation steps, siren-off steps, the offline check, the
late-opening check and (every 10 min) vendor-cloud online checks.
"""
import hashlib
import json
import logging
from datetime import timedelta

from django.db import transaction
from django.utils import timezone
from rest_framework.response import Response

from .i18n import req_lang, pick
from . import shop_views as SV
from .logic import cash_guard as CG
from .logic import cctv_extras as CX
from .watchman_views import _OwnerBase

log = logging.getLogger("assisto.shop")

MOVEMENT_TYPES = ("motion", "person_detected", "zone_intrusion", "line_crossing",
                  "camera_alarm", "hand_in_cash_zone", "drawer_open", "pose_possible")
TICK_SITE_LIMIT = 2000           # bounded work per minute


def _err(lang, bn, en, status=400, **extra):
    return SV._err(lang, bn, en, status=status, **extra)


def settings_for(site):
    return CX.settings_of(site.guard if isinstance(site.guard, dict) else {})


def _lang_of(user):
    lang = getattr(user, "language", None)
    return lang if lang in ("bn", "en") else "bn"


# ---------------------------------------------------------------- state
def _local(now):
    return timezone.localtime(now)


def _fresh_day(st, today):
    d = st.get("day") if isinstance(st.get("day"), dict) else {}
    if d.get("date") != today:
        d = {"date": today, "counts": {}, "drawer_sale": 0, "opened_at": None,
             "late_sent": False, "offline_log": []}
        st["day"] = d
    d.setdefault("counts", {})
    d.setdefault("offline_log", [])
    return d


def update_state(site, fn, now=None):
    """Atomically change site.guard["_state"] (never the owner's settings).
    `fn(state, day)` mutates; returns its result. Never raises."""
    from .models import ShopSite
    now = now or timezone.now()
    today = _local(now).date().isoformat()
    try:
        with transaction.atomic():
            row = ShopSite.objects.select_for_update().get(pk=site.pk)
            g = dict(row.guard) if isinstance(row.guard, dict) else {}
            st = dict(g.get("_state") or {})
            day = _fresh_day(st, today)
            out = fn(st, day)
            g["_state"] = st
            ShopSite.objects.filter(pk=site.pk).update(guard=g)
            site.guard = g
            return out
    except Exception:
        log.exception("guard state update failed")
        return None


def day_of(site, now=None):
    now = now or timezone.now()
    g = site.guard if isinstance(site.guard, dict) else {}
    st = g.get("_state") or {}
    d = st.get("day") if isinstance(st.get("day"), dict) else {}
    return d if d.get("date") == _local(now).date().isoformat() else {}


def extra_caps_for(owner):
    from . import billing
    caps = SV.owner_caps(owner)
    try:
        shop = billing.cfg().get("shop") or {}
    except Exception:
        shop = {}
    return CX.extra_caps(caps["tier"], shop)


def used_today(owner, key, now=None):
    from .models import ShopSite
    n = 0
    for s in ShopSite.objects.filter(owner=owner).only("id", "guard"):
        n += int((day_of(s, now).get("counts") or {}).get(key, 0) or 0)
    return n


def take_cap(site, key, now=None):
    """One more `key` (offline_day / escalations_day / sirens_day /
    notices_day) for the site OWNER today, if the plan allows."""
    now = now or timezone.now()
    limit = extra_caps_for(site.owner)[key]
    if used_today(site.owner, key, now) >= limit:
        return False

    def bump(st, day):
        day["counts"][key] = int(day["counts"].get(key, 0)) + 1
        return True
    return bool(update_state(site, bump, now))


def site_quiet(site, now):
    """Quiet hours (first camera with a v2 quiet window), unless away."""
    from .logic import watchman as WM
    if SV.away_now(site, now):
        return False
    local = _local(now)
    for cam in site.cameras.filter(enabled=True):
        v2 = WM.zone_v2(cam.zone_config)
        if v2 and v2.get("quiet_hours"):
            return bool(WM.in_window(v2.get("quiet_hours"), local))
    return False


# ---------------------------------------------------------------- notices
def notice(user, site, kind, title_bn, title_en, body_bn, body_en, *,
           quiet=False, severity="med", data=None, high=False):
    """A guard notice (offline, recovered, opened, late, escalation, shared
    clip): FamilyAlert + NotifEvent feed row + (unless quiet) FCM shop_alert,
    in the RECIPIENT's language. Never accusatory. Never raises."""
    data = dict(data or {})
    try:
        from .models import FamilyAlert, NotifEvent
        lang = _lang_of(user)
        meta = dict({"source": "shop_guard", "notice": kind, "site_id": site.id,
                     "label": "suspicious_please_check", "quiet": bool(quiet)}, **data)
        FamilyAlert.objects.create(
            user=user, kind="shop_guard",
            title=(title_en if lang == "en" else title_bn)[:160],
            body=body_en if lang == "en" else body_bn,
            severity="info" if quiet else severity, payload=meta)
        NotifEvent.objects.create(
            user=user, type="business", title_bn=title_bn[:200],
            title_en=title_en[:200], body_bn=body_bn, body_en=body_en,
            route="business", meta=meta)
    except Exception:
        log.exception("guard notice row failed")
        return False
    if quiet:
        return True
    try:
        from . import push
        push.safe_push(user, "shop_alert", title_bn, title_en, body_bn, body_en,
                       data=dict({"site_id": site.id, "notice": kind,
                                  "route": "watchman" if site.gateway else
                                  "business/shop-box"}, **data),
                       high_priority=high)
    except Exception:
        pass
    return True


def site_people(site):
    out = [site.owner]
    try:
        out += [v.user for v in site.viewers.select_related("user")]
    except Exception:
        pass
    return out


def notice_site(site, kind, texts, *, quiet=False, severity="med", data=None,
                high=False):
    """texts(lang) -> (title, body). One notice to the owner + viewers."""
    for u in site_people(site):
        tb, bb = texts("bn")
        te, be = texts("en")
        notice(u, site, kind, tb, te, bb, be, quiet=quiet, severity=severity,
               data=data, high=high)


# ================================================================ 1. NO-SALE
def uses_records(site, now):
    """Does this shop record sales (Assisto POS mirror) or khata entries in
    Assisto? Only then can a 'no sale' mean something."""
    from .models import KhataEntry
    since = now - timedelta(days=CX.LOOKBACK_DAYS)
    try:
        # any sale row for this site counts: the Assisto POS mirror (pos_link)
        # or a Shop Box / POS posting to shop/pos
        if site.pos_events.filter(kind="sale", at__gte=since).exists():
            return True
        return KhataEntry.objects.filter(party__business__user_id=site.owner_id,
                                         created_at__gte=since).exists()
    except Exception:
        return False


def nosale_mode(site, etype, now):
    s = settings_for(site)
    if etype not in CX.NOSALE_TYPES or not s["nosale_on"]:
        return False
    return CX.nosale_applies(etype, s, uses_records(site, now))


def schedule_nosale(site, ev, now):
    from .models import ShopGuardTask
    w = settings_for(site)["nosale_min"] * 60
    ShopGuardTask.objects.create(site=site, event=ev, kind="nosale",
                                 due_at=now + timedelta(seconds=w),
                                 state={"window_s": w, "first_at": now.timestamp()})


def bump_nosale(ev, now):
    """A repeat touch of a pending episode: the check waits for the LAST
    touch + the window (debounced — one alert per episode)."""
    from .models import ShopGuardTask
    for t in ShopGuardTask.objects.filter(event=ev, kind="nosale", done=False):
        w = int((t.state or {}).get("window_s") or 120)
        t.due_at = now + timedelta(seconds=w)
        t.save(update_fields=["due_at"])


def _records_in(site, lo, hi):
    from datetime import datetime, timezone as dtz
    from .models import KhataEntry
    a = datetime.fromtimestamp(lo, tz=dtz.utc)
    b = datetime.fromtimestamp(hi, tz=dtz.utc)
    if site.pos_events.filter(kind__in=("sale", "drawer_open"), at__gte=a,
                              at__lte=b).exists():
        return True
    return KhataEntry.objects.filter(party__business__user_id=site.owner_id,
                                     created_at__gte=a, created_at__lte=b).exists()


def _discard_event(ev):
    """A cleared touch: nothing is kept — clip bytes, snapshot, the row."""
    from . import cashguard_views as CGV
    try:
        if SV.hasattr_clip(ev):
            CGV._drop_blob(ev.clip, "expired")
    except Exception:
        pass
    try:
        if ev.snapshot:
            ev.snapshot.delete(save=False)
    except Exception:
        pass
    ev.delete()


def run_nosale(task, now):
    from .logic import watchman as WM
    ev = task.event
    if ev is None or not ev.pending:
        return "gone"
    site = ev.site
    st = task.state or {}
    w = int(st.get("window_s") or 120)
    last = (ev.last_at or ev.created).timestamp()
    lo, hi = CX.nosale_window(float(st.get("first_at") or ev.created.timestamp()),
                              last, w)
    if _records_in(site, lo, hi):
        update_state(site, lambda s, d: d.__setitem__(
            "drawer_sale", int(d.get("drawer_sale", 0)) + 1), now)
        _discard_event(ev)
        return "cleared"
    sig = dict(ev.signals or {})
    sig["nosale"] = {"window_min": w // 60, "checked_at": now.isoformat()}
    ev.signals = sig
    ev.pending = False
    ev.save(update_fields=["signals", "pending"])
    cam = ev.camera
    quiet = False
    if cam is not None:
        v2 = WM.zone_v2(cam.zone_config)
        if v2 is not None:
            quiet = WM.in_window(v2.get("quiet_hours"), _local(now)) and \
                not SV.away_now(site, now)
    SV.ShopIngestView._notify_owner(site, cam, ev, quiet=quiet)
    after_notify(site, ev, quiet, now)
    return "alerted"


def nosale_text(ev, cam_name):
    """(title_bn, title_en, body_bn, body_en) for a confirmed no-sale alert."""
    sig = ev.signals or {}
    inputs = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else {}
    away = bool(inputs.get("away"))
    clip = bool(sig.get("clip_ref"))
    mins = int((sig.get("nosale") or {}).get("window_min") or 2)
    pct = int(round(ev.confidence * 100))
    return ("%s: %s" % (CX.nosale_title("bn", clip, away), cam_name),
            "%s: %s" % (CX.nosale_title("en", clip, away), cam_name),
            CX.nosale_body("bn", mins, pct), CX.nosale_body("en", mins, pct))


# ================================================================ 4. ESCALATION
def circle_people(owner):
    """[{uid, name, has_key, key_id, pub}] — accepted Circle peers (the
    only people an owner may escalate to or share a clip with)."""
    from . import push
    from .models import UserPublicKey
    peers = push.circle_family_users(owner)
    keys = {k.user_id: k for k in UserPublicKey.objects.filter(
        user_id__in=[p.pk for p in peers]).exclude(public_key="")}
    out = []
    for p in peers:
        k = keys.get(p.pk)
        out.append({"uid": p.pk, "name": getattr(p, "name", "") or "",
                    "has_key": k is not None,
                    "key_id": k.key_id if k else "", "pub": k.public_key if k else ""})
    return out


def after_notify(site, ev, quiet, now):
    """Start the escalation chain for a fresh alert (not for a quiet-hours
    or 'possible' one — those never woke the owner either)."""
    from .models import ShopGuardTask
    try:
        s = settings_for(site)
        if not s["escalation"] or ev.possible or quiet:
            return None
        return ShopGuardTask.objects.create(
            site=site, event=ev, kind="escalate",
            due_at=now + timedelta(minutes=s["escalate_min"]),
            state={"step": 0, "chain": list(s["escalation"]), "log": []})
    except Exception:
        log.exception("escalation start failed")
        return None


def _escalated(ev):
    return [int(u) for u in ((ev.signals or {}).get("escalated_to") or [])
            if str(u).isdigit()]


def run_escalate(task, now):
    from .models import ShopEvent, User
    ev = task.event
    st = dict(task.state or {})
    logrows = list(st.get("log") or [])
    if ev is None:
        return "gone"
    ev.refresh_from_db()
    if ev.opened_at is not None or ev.status != "open":
        logrows.append({"at": now.isoformat(), "stop": "opened"})
        task.state = dict(st, log=logrows)
        return "opened"
    chain = [int(u) for u in st.get("chain") or []]
    step = int(st.get("step") or 0)
    site = ev.site
    allowed = {p["uid"] for p in circle_people(site.owner)}
    while step < len(chain) and chain[step] not in allowed:
        logrows.append({"at": now.isoformat(), "uid": chain[step], "skip": "not_in_circle"})
        step += 1
    if step >= len(chain):
        task.state = dict(st, step=step, log=logrows)
        return "end"
    if not take_cap(site, "escalations_day", now):
        logrows.append({"at": now.isoformat(), "stop": "cap"})
        task.state = dict(st, step=step, log=logrows)
        return "cap"
    user = User.objects.filter(pk=chain[step]).first()
    if user is None:
        task.state = dict(st, step=step + 1, log=logrows)
        return "next"
    sig = dict(ev.signals or {})
    to = _escalated(ev)
    if user.pk not in to:
        to.append(user.pk)
    sig["escalated_to"] = to
    ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
    ev.signals = sig
    cam = ev.camera
    owner_name = getattr(site.owner, "name", "") or ""
    tb, te, bb, be = _event_texts(ev, cam, "bn")
    notice(user, site, "escalation",
           CX.escalate_title("bn", owner_name, tb), CX.escalate_title("en", owner_name, te),
           bb, be, severity="high", high=True,
           data={"event_id": ev.id, "escalated": True, "route": "watchman/inbox",
                 **({"snapshot_url": SV._abs_snapshot_url(ev)}
                    if SV._abs_snapshot_url(ev) else {})})
    logrows.append({"at": now.isoformat(), "uid": user.pk, "step": step, "sent": True})
    step += 1
    task.state = dict(st, step=step, log=logrows)
    if step < len(chain):
        task.due_at = now + timedelta(minutes=settings_for(site)["escalate_min"])
        return "wait"
    return "end"


def nosale_feedback(ev, verdict):
    """The owner's Correct / Wrong on a no-sale alert: count wrong answers in
    a row (a tip to widen the window appears at 3 — never an automatic
    change of the owner's setting)."""
    if not (ev.signals or {}).get("nosale"):
        return

    def f(st, day):
        st["nosale_wrong"] = int(st.get("nosale_wrong", 0) or 0) + 1 \
            if verdict == "wrong" else 0
    update_state(ev.site, f)


def _event_texts(ev, cam, lang):
    name = (cam.name if cam else "") or SV._subject_label(ev.type, lang)
    if (ev.signals or {}).get("nosale"):
        return nosale_text(ev, name)
    return SV._alert_text(name, ev)


# ================================================================ siren
def run_siren_off(task, now):
    from .models import ShopCamera
    st = task.state or {}
    cam = ShopCamera.objects.filter(pk=st.get("camera_id")).first()
    if cam is None or not cam.vendor_ref:
        return "gone"
    from .logic import imou as IM
    from .watchman_views import imou_cloud_on
    client = IM.ImouClient.from_integration() if imou_cloud_on() else None
    if client is None:
        return "no_client"
    dev, _, ch = cam.vendor_ref.partition(":")
    try:
        client.siren(dev, ch or "0", on=False)
    except IM.ImouError:
        return "error"
    return "off"


# ================================================================ tick
def run_due(now=None, limit=200):
    """Every due guard task (no-sale, escalation, siren-off). Returns counts."""
    from .models import ShopGuardTask
    now = now or timezone.now()
    out = {}
    rows = list(ShopGuardTask.objects.filter(done=False, due_at__lte=now)
                .select_related("event", "site")[:limit])
    for t in rows:
        try:
            if t.kind == "nosale":
                r = run_nosale(t, now)
                t.done = True
            elif t.kind == "escalate":
                r = run_escalate(t, now)
                t.done = r != "wait"
            else:
                r = run_siren_off(t, now)
                t.done = True
        except Exception:
            log.exception("guard task %s failed", t.pk)
            r, t.done = "error", True
        out[r] = out.get(r, 0) + 1
        try:
            t.save(update_fields=["done", "state", "due_at"])
        except Exception:
            pass          # the event (and so the task) was deleted
    return out


def _cloud_check(cam, now, clients):
    """Vendor-cloud online status for a cloud camera without a gateway,
    at most every CLOUD_CHECK_EVERY_S. Key-gated; never raises."""
    from .models import ShopCamera
    compat = dict(cam.compat or {})
    last = compat.get("cloud_checked_at")
    if last and now.timestamp() - float(last) < CX.CLOUD_CHECK_EVERY_S:
        return
    online = None
    try:
        if cam.vendor == "imou" and clients.get("imou"):
            dev = cam.vendor_ref.partition(":")[0]
            online = clients["imou"].is_online(dev)
        elif cam.vendor == "ezviz" and clients.get("ezviz"):
            serial = cam.vendor_ref.split(":")[1]
            online = clients["ezviz"].is_online(serial)
    except Exception:
        online = None
    compat["cloud_checked_at"] = now.timestamp()
    if online:
        compat["cloud_online_at"] = now.timestamp()
    elif online is False and not compat.get("cloud_online_at"):
        compat["cloud_online_at"] = now.timestamp() - 1   # start counting now
    ShopCamera.objects.filter(pk=cam.pk).update(compat=compat)
    cam.compat = compat


def _cloud_clients():
    out = {}
    try:
        from .watchman_views import imou_cloud_on
        from .logic import imou as IM
        if imou_cloud_on():
            out["imou"] = IM.ImouClient.from_integration()
    except Exception:
        pass
    try:
        from .cashguard_views import ezviz_on
        from .logic import ezviz as EZ
        if ezviz_on():
            out["ezviz"] = EZ.EzvizClient.from_integration()
    except Exception:
        pass
    return out


def site_entities(site, now, clients=None):
    """What can go silent at a site: its gateway and each enabled camera
    (a gateway camera by its stream heartbeat, a cloud-only camera by the
    vendor's online status)."""
    ents = []
    gw = site.gateway in ("shopbox", "pc", "phone")
    if gw and site.last_seen:
        ents.append({"key": "g", "kind": "gateway", "name": "",
                     "last_ts": site.last_seen.timestamp()})
    for c in site.cameras.filter(enabled=True):
        if c.vendor_ref and not gw:
            if clients is not None:
                _cloud_check(c, now, clients)
            t = (c.compat or {}).get("cloud_online_at")
            if t:
                ents.append({"key": "c%d" % c.id, "kind": "cloud", "name": c.name,
                             "last_ts": float(t)})
        elif c.last_seen:
            ents.append({"key": "c%d" % c.id, "kind": "camera", "name": c.name,
                         "last_ts": c.last_seen.timestamp()})
    return ents


def run_offline(site, now, clients=None):
    """One offline pass for a site. Returns (#offline notices, #recovered)."""
    s = settings_for(site)
    if not s["offline_on"]:
        return 0, 0
    ents = site_entities(site, now, clients)
    prev = ((site.guard or {}).get("_state") or {}).get("offline") or {}
    new, went, back = CX.offline_transitions(ents, now.timestamp(), prev,
                                             s["offline_min"] * 60)
    gw_down = "g" in new
    sent = 0
    if went:
        # a silent gateway explains its cameras: ONE notice for the gateway
        # (cameras going quiet behind an already-reported gateway: none)
        main = [e for e in went if e["kind"] == "gateway"] if gw_down else went
        names = ", ".join(e["name"] for e in main if e.get("name"))
        kind = main[0]["kind"] if len(main) == 1 else "camera"
        mins = s["offline_min"]
        if main and take_cap(site, "offline_day", now):
            quiet = site_quiet(site, now)
            notice_site(site, "offline",
                        lambda lang: CX.offline_text(lang, kind, names, mins),
                        quiet=quiet, severity="high", high=True,
                        data={"keys": [e["key"] for e in main]})
            sent = 1
    for e, mins in back:
        notice_site(site, "recovered",
                    lambda lang, e=e, mins=mins: CX.recovered_text(lang, e["kind"], e["name"], mins),
                    quiet=site_quiet(site, now), severity="info",
                    data={"keys": [e["key"]], "minutes": mins})

    def save(st, day):
        st["offline"] = new
        logrows = day["offline_log"]
        for e in went:
            logrows.append([e["key"], float(e["last_ts"]), None])
        for e, _m in back:
            for row in logrows:
                if row[0] == e["key"] and row[2] is None:
                    row[2] = float(e["last_ts"])
        # an outage that started yesterday still counts from midnight
        open_keys = {r[0] for r in logrows if r[2] is None}
        for k, v in new.items():
            if k not in open_keys:
                logrows.append([k, float(v["since"]), None])
        day["offline_log"] = logrows[-50:]
    if went or back or new != prev:
        update_state(site, save, now)
    return sent, len(back)


def note_motion(site, at_dt, now=None):
    """Movement seen at the site (edge heartbeat motion_at, or any movement
    event). The first movement after opening time today -> 'shop opened'
    (once a day; only for real opening hours)."""
    now = now or timezone.now()
    hours = site.hours if isinstance(site.hours, dict) else {}
    if not hours:
        return False
    s = settings_for(site)
    local = _local(at_dt)
    if local.date() != _local(now).date():
        return False
    lm = local.hour * 60 + local.minute
    d = day_of(site, now)
    opened_ok = CX.open_notice_due(hours, lm, local.weekday(),
                                   dict(s, opened_on=True), d)
    if not opened_ok:
        return False
    hhmm = local.strftime("%H:%M")
    update_state(site, lambda st, day: day.__setitem__("opened_at", hhmm), now)
    if s["opened_on"] and take_cap(site, "notices_day", now):
        notice_site(site, "opened",
                    lambda lang: CX.opened_text(lang, site.name, hhmm, hours.get("open")),
                    quiet=site_quiet(site, now), severity="info")
    return True


def run_late(site, now):
    hours = site.hours if isinstance(site.hours, dict) else {}
    if not hours:
        return False
    s = settings_for(site)
    local = _local(now)
    lm = local.hour * 60 + local.minute
    online = SV.is_online(site.last_seen, now) or any(
        SV.is_online(c.last_seen, now) for c in site.cameras.filter(enabled=True))
    if not CX.late_due(hours, lm, local.weekday(), s, day_of(site, now), online):
        return False
    update_state(site, lambda st, day: day.__setitem__("late_sent", True), now)
    if take_cap(site, "notices_day", now):
        o = CX._hm(hours.get("open")) or 0
        notice_site(site, "late",
                    lambda lang: CX.late_text(lang, site.name, hours.get("open"), lm - o),
                    quiet=site_quiet(site, now), severity="med")
    return True


def tick(now=None):
    """The whole minute job. Never raises; returns counts for the log."""
    from .models import ShopSite
    now = now or timezone.now()
    out = {"tasks": {}, "offline": 0, "recovered": 0, "late": 0, "sites": 0}
    try:
        out["tasks"] = run_due(now)
    except Exception:
        log.exception("guard tasks failed")
    clients = _cloud_clients()
    qs = (ShopSite.objects.filter(cameras__enabled=True).distinct()
          .select_related("owner").order_by("id")[:TICK_SITE_LIMIT])
    for site in qs:
        out["sites"] += 1
        try:
            a, b = run_offline(site, now, clients)
            out["offline"] += a
            out["recovered"] += b
            out["late"] += 1 if run_late(site, now) else 0
        except Exception:
            log.exception("guard tick failed for site %s", site.pk)
    return out


# ================================================================ 6. REPORT
def report_counts(site, now=None):
    """Today's numbers for the nightly guard report (local day)."""
    now = now or timezone.now()
    start = _local(now).replace(hour=0, minute=0, second=0, microsecond=0)
    evs = site.events.filter(created__gte=start, pending=False)
    nosale = sum(1 for e in evs.filter(type__in=CX.NOSALE_TYPES)
                 if (e.signals or {}).get("nosale"))
    away = sum(1 for e in evs if ((e.signals or {}).get("inputs") or {}).get("away"))
    esc = sum(1 for e in evs if (e.signals or {}).get("escalated_to"))
    d = day_of(site, now)
    rows = [(a, b) for _k, a, b in d.get("offline_log") or []]
    om = _union_minutes(rows, start.timestamp(), now.timestamp())
    return {"drawer_nosale": nosale, "drawer_sale": int(d.get("drawer_sale", 0) or 0),
            "away_events": away, "offline_min": om, "escalated": esc,
            "after_hours": evs.filter(type="after_hours").count(),
            "opened_at": d.get("opened_at"), "late": bool(d.get("late_sent"))}


def _union_minutes(rows, day0, now_ts):
    iv = []
    for a, b in rows:
        a = max(float(a), day0)
        b = min(float(b if b is not None else now_ts), now_ts)
        if b > a:
            iv.append((a, b))
    iv.sort()
    total, cur = 0.0, None
    for a, b in iv:
        if cur is None or a > cur[1]:
            if cur:
                total += cur[1] - cur[0]
            cur = [a, b]
        else:
            cur[1] = max(cur[1], b)
    if cur:
        total += cur[1] - cur[0]
    return int(total // 60)


def brief_lines(user, now=None):
    """[{bn, en}] for the evening brief: one block per site with cameras."""
    from .models import ShopSite
    out = []
    sites = list(ShopSite.objects.filter(owner=user, cameras__enabled=True).distinct()[:5])
    for s in sites:
        lines = CX.report_lines(report_counts(s, now))
        if len(sites) > 1:
            lines = [{"bn": "%s — %s" % (s.name or "দোকান", ln["bn"]),
                      "en": "%s — %s" % (s.name or "Shop", ln["en"])} for ln in lines]
        out.extend(lines)
    return out


# ================================================================ access
def event_access(request, pk):
    """(event, role) — role owner | viewer | escalated | shared — or (None, None)."""
    from .models import ShopEvent
    try:
        ev = ShopEvent.objects.select_related("site", "camera").get(pk=int(pk))
    except (ShopEvent.DoesNotExist, TypeError, ValueError):
        return None, None
    if ev.pending:
        return None, None
    s, role = SV._viewable_site(request, ev.site_id)
    if s is not None:
        return ev, role
    uid = request.user.pk
    if uid in _escalated(ev):
        return ev, "escalated"
    try:
        shared = (ev.clip.meta or {}).get("share") or {}
        if str(uid) in shared:
            return ev, "shared"
    except Exception:
        pass
    return None, None


def mark_opened(ev, user, now=None):
    from .models import ShopEvent, ShopGuardTask
    now = now or timezone.now()
    if ev.opened_at is None:
        ShopEvent.objects.filter(pk=ev.pk, opened_at__isnull=True).update(opened_at=now)
        ev.opened_at = now
        for t in ShopGuardTask.objects.filter(event=ev, kind="escalate"):
            st = dict(t.state or {})
            st["log"] = list(st.get("log") or []) + [
                {"at": now.isoformat(), "opened_by": user.pk}]
            t.state = st
            t.done = True
            t.save(update_fields=["state", "done"])
    return ev.opened_at


def actions_for(ev, role):
    """What the phone may offer from this alert (honest per camera)."""
    site = ev.site
    s = settings_for(site)
    cam = ev.camera
    route, why = (None, "no_camera") if cam is None else CX.siren_route(
        cam.vendor, cam.vendor_ref, site.gateway, bool((cam.source or {}).get("host")))
    siren = {"supported": route is not None, "route": route, "reason": why or None}
    if route is None and why in CX.SIREN_REASONS:
        siren["detail_bn"], siren["detail_en"] = CX.SIREN_REASONS[why]
    clip = None
    try:
        c = ev.clip
        clip = c.status if c.created + timedelta(seconds=CG.CLIP_TTL_S) > timezone.now() \
            else "expired"
    except Exception:
        clip = None
    return {"siren": dict(siren, allowed=role in ("owner", "escalated")),
            "call_shop": s["shop_phone"] or None,
            "emergency": "999",
            "share_clip": role == "owner" and clip in ("ready", "viewed"),
            "evidence": role == "owner"}


# ================================================================ views
class GuardSettingsView(_OwnerBase):
    def _out(self, site, request):
        s = settings_for(site)
        caps = SV.owner_caps(site.owner)
        extra = extra_caps_for(site.owner)
        now = timezone.now()
        people = [{"uid": p["uid"], "name": p["name"], "has_key": p["has_key"]}
                  for p in circle_people(site.owner)]
        st = (site.guard or {}).get("_state") or {}
        usage = {k: used_today(site.owner, k, now)
                 for k in ("offline_day", "escalations_day", "sirens_day", "notices_day")}
        return {"site": site.id, "settings": s, "circle": people,
                "bounds": {k: list(v[1]) for k, v in CX.INT_SETTINGS.items()},
                "max_chain": CX.MAX_CHAIN, "caps": dict(extra, clips_day=caps["clips_day"],
                                                        alerts_day=caps["alerts_day"]),
                "usage": usage, "uses_records": uses_records(site, now),
                "tip": CX.nosale_tip(int(st.get("nosale_wrong", 0) or 0), s["nosale_min"]),
                "hand_to_pocket": {"enabled": CG.HAND_TO_POCKET_LABEL, "measured": False},
                "ads": False}

    def get(self, request, pk):
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(self._out(site, request))

    def put(self, request, pk):
        from .models import ShopSite
        lang = req_lang(request)
        site = SV._owner_site(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        allowed = {p["uid"] for p in circle_people(request.user)}
        errs = {
            "bad_escalation": ("কাকে পাঠাবেন, তালিকাটি ঠিক নেই।", "The escalation list is not valid."),
            "chain_too_long": ("সর্বোচ্চ ৩ জনকে বেছে নেওয়া যায়।", "You can choose at most 3 people."),
            "not_in_circle": ("শুধু আপনার সার্কেলের যুক্ত মানুষকে বেছে নেওয়া যায়।",
                              "You can only choose people connected in your Circle."),
            "bad_days": ("বন্ধের দিন ঠিক নেই।", "The closed days are not valid."),
            "bad_phone": ("দোকানের ফোন নম্বর ঠিক নেই — যেমন 01712345678।",
                          "The shop's phone number is not valid — e.g. 01712345678."),
        }
        try:
            with transaction.atomic():
                row = ShopSite.objects.select_for_update().get(pk=site.pk)
                clean = CX.apply_settings(row.guard, request.data, allowed)
                ShopSite.objects.filter(pk=site.pk).update(guard=clean)
                site.guard = clean
        except CX.SettingsError as e:
            bn, en = errs.get(e.code, errs["bad_escalation"])
            return _err(lang, bn, en, status=422, code=e.code)
        return Response(self._out(site, request))

    post = put


class GuardReportView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s, role = SV._viewable_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        r = report_counts(s)
        return Response({"site": s.id, "counts": r,
                         "lines": [ln[lang if lang in ("bn", "en") else "bn"]
                                   for ln in CX.report_lines(r)],
                         "credits": 0, "ai_used": False})


class PrivacyKitView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        s = SV._owner_site(request, pk)
        if s is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(dict(CX.privacy_kit(s.name, s.snapshot_retention_days),
                             site=s.id))


def image_stats(raw, poly):
    """Luminance statistics of a still (PIL, ~20 ms at 640 px) inside the
    cash polygon. None when the image cannot be read."""
    import io
    try:
        from PIL import Image, ImageDraw, ImageFilter, ImageStat
        im = Image.open(io.BytesIO(raw)).convert("L")
        im.thumbnail((320, 320))
        w, h = im.size
        if not poly or len(poly) < 3:
            return {"frame_mean": ImageStat.Stat(im).mean[0], "zone_area": 0}
        pts = [(max(0.0, min(1.0, float(x))) * (w - 1),
                max(0.0, min(1.0, float(y))) * (h - 1)) for x, y in poly]
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).polygon(pts, fill=255)
        area = sum(1 for v in mask.getdata() if v) / float(w * h)
        if area <= 0:
            return {"zone_area": 0}
        st = ImageStat.Stat(im, mask)
        hist = im.histogram(mask)
        n = float(sum(hist)) or 1.0
        edges = im.filter(ImageFilter.FIND_EDGES)
        eh = edges.histogram(mask)
        xs = [p[0] / (w - 1) for p in pts]
        ys = [p[1] / (h - 1) for p in pts]
        margin = min(min(xs), min(ys), 1 - max(xs), 1 - max(ys))
        return {"frame_mean": ImageStat.Stat(im).mean[0],
                "frame_std": ImageStat.Stat(im).stddev[0],
                "zone_mean": st.mean[0], "zone_std": st.stddev[0],
                "zone_dark": sum(hist[:30]) / n, "zone_bright": sum(hist[246:]) / n,
                "zone_area": area, "zone_margin": max(0.0, margin),
                "zone_edges": sum(eh[40:]) / (float(sum(eh)) or 1.0)}
    except Exception:
        return None


class CameraPlacementView(_OwnerBase):
    """GET — the placement helper for the camera's latest still (the check
    preview, else the newest alert photo). Deterministic, no AI, 0 credits."""

    def get(self, request, pk):
        from .watchman_views import _owner_cam
        lang = req_lang(request)
        cam = _owner_cam(request, pk)
        if cam is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        f, src = None, None
        if cam.preview:
            f, src = cam.preview, "check"
        else:
            ev = cam.events.exclude(snapshot="").exclude(snapshot=None).first()
            if ev is not None:
                f, src = ev.snapshot, "event"
        if f is None:
            return _err(lang, "এখনো কোনো ছবি নেই — আগে ক্যামেরা পরীক্ষা চালান।",
                        "No picture yet — run the camera check first.",
                        status=404, code="no_preview")
        try:
            with f.open("rb") as fh:
                raw = fh.read(4 * 1024 * 1024)
        except Exception:
            raw = b""
        zone = CG.cash_zone_of(SV.effective_zone_config(cam))
        stats = image_stats(raw, zone) if raw else None
        if stats is None:
            return _err(lang, "ছবিটি পড়া গেল না — আবার পরীক্ষা চালান।",
                        "Could not read the picture — run the check again.",
                        status=422, code="bad_preview")
        rep = CX.placement_report(stats, lang)
        return Response(dict(rep, camera=cam.id, source=src,
                             stats={k: round(v, 3) for k, v in stats.items()},
                             ai_used=False, credits=0,
                             honest=pick(lang, "এটি আলো, স্পষ্টতা আর ফ্রেমের হিসাব — লেন্সের সামনে কী আছে তা বোঝে না।",
                                         "This checks light, clarity and framing — it cannot tell what is in front of the lens.")))


class EventDetailView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        row = SV._event_row(ev, request)
        if role in ("escalated", "shared"):
            row.pop("signals", None)
        return Response({"event": row, "role": role, "site_name": ev.site.name,
                         "actions": actions_for(ev, role),
                         "opened_at": SV._iso(ev.opened_at)})


INBOX_HOURS = 48


class GuardInboxView(_OwnerBase):
    """GET shop/guard/inbox — alerts other owners PASSED to me (escalated)
    or clips they SHARED with me, newest first, last 48 h."""

    def get(self, request):
        from .models import ShopEvent, ShopEventClip
        uid = request.user.pk
        since = timezone.now() - timedelta(hours=INBOX_HOURS)
        rows, seen = [], set()
        for ev in (ShopEvent.objects.filter(created__gte=since, pending=False,
                                            signals__has_key="escalated_to")
                   .select_related("site", "camera").order_by("-created")[:300]):
            if uid in _escalated(ev):
                rows.append((ev, "escalated"))
                seen.add(ev.pk)
        for c in (ShopEventClip.objects.filter(created__gte=since, meta__has_key="share")
                  .select_related("event", "event__site", "event__camera")
                  .order_by("-created")[:300]):
            if str(uid) in ((c.meta or {}).get("share") or {}) and c.event_id not in seen:
                rows.append((c.event, "shared"))
        rows.sort(key=lambda r: r[0].created, reverse=True)
        out = []
        for ev, role in rows[:50]:
            row = SV._event_row(ev, request)
            row.pop("signals", None)
            out.append(dict(row, role=role, site_name=ev.site.name,
                            owner_name=getattr(ev.site.owner, "name", "") or ""))
        return Response({"events": out, "hours": INBOX_HOURS})


class EventOpenedView(_OwnerBase):
    def post(self, request, pk):
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        at = mark_opened(ev, request.user)
        return Response({"ok": True, "opened_at": SV._iso(at), "role": role})


SIREN_ERRS = {
    "imou_off": ("Imou ক্লাউড এখনো চালু হয়নি — সাইরেন বাজানো যাচ্ছে না।",
                 "The Imou cloud is not switched on yet — the siren cannot be sounded."),
    "vendor_error": ("ক্যামেরা সাইরেনের অনুরোধ নেয়নি — এই মডেলে সাইরেন নাও থাকতে পারে, বা ক্যামেরা অফলাইন।",
                     "The camera did not accept the siren request — this model may have no siren, or it is offline."),
    "too_soon": ("এইমাত্র বাজানো হয়েছে — কয়েক সেকেন্ড পরে আবার চেষ্টা করুন।",
                 "It was just sounded — try again in a few seconds."),
    "cap": ("আজকের সাইরেনের সীমা শেষ।", "Today's siren limit is used up."),
}


class EventSirenView(_OwnerBase):
    def post(self, request, pk):
        from .models import ShopCamera, ShopGatewayTask, ShopGuardTask
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        if role not in ("owner", "escalated"):
            return _err(lang, "শুধু মালিক বা যাঁকে পাঠানো হয়েছে তিনি সাইরেন বাজাতে পারেন।",
                        "Only the owner or the person this alert was passed to can sound the siren.",
                        status=403, code="not_allowed")
        cam = ev.camera
        cid = request.data.get("camera_id")
        if cid not in (None, ""):
            try:
                cam = ShopCamera.objects.filter(site=ev.site, pk=int(cid)).first() or cam
            except (TypeError, ValueError):
                pass
        if cam is None:
            bn, en = CX.SIREN_REASONS["vendor_no_api"]
            return _err(lang, bn, en, status=409, code="siren_unsupported", reason="no_camera")
        site = ev.site
        route, why = CX.siren_route(cam.vendor, cam.vendor_ref, site.gateway,
                                    bool((cam.source or {}).get("host")))
        if route is None:
            bn, en = CX.SIREN_REASONS.get(why, CX.SIREN_REASONS["vendor_no_api"])
            return _err(lang, bn, en, status=409, code="siren_unsupported", reason=why)
        try:
            secs = int(request.data.get("seconds") or CX.SIREN_DEFAULT_S)
        except (TypeError, ValueError):
            secs = CX.SIREN_DEFAULT_S
        secs = max(CX.SIREN_SECONDS[0], min(CX.SIREN_SECONDS[1], secs))
        now = timezone.now()
        last = (cam.compat or {}).get("siren_at")
        if last and now.timestamp() - float(last) < 20:
            bn, en = SIREN_ERRS["too_soon"]
            return _err(lang, bn, en, status=429, code="too_soon")
        if not take_cap(site, "sirens_day", now):
            bn, en = SIREN_ERRS["cap"]
            return _err(lang, bn, en, status=429, code="siren_cap")
        ShopCamera.objects.filter(pk=cam.pk).update(
            compat=dict(cam.compat or {}, siren_at=now.timestamp()))
        audit = {"at": now.isoformat(), "by": request.user.pk, "camera": cam.id,
                 "route": route, "seconds": secs}
        sig = dict(ev.signals or {})
        sig["sirens"] = (list(sig.get("sirens") or []) + [audit])[-5:]
        type(ev).objects.filter(pk=ev.pk).update(signals=sig)
        if route == "imou_cloud":
            from .logic import imou as IM
            from .watchman_views import imou_cloud_on
            client = IM.ImouClient.from_integration() if imou_cloud_on() else None
            if client is None:
                bn, en = SIREN_ERRS["imou_off"]
                return _err(lang, bn, en, status=503, code="imou_not_configured")
            dev, _, ch = cam.vendor_ref.partition(":")
            try:
                client.siren(dev, ch or "0", on=True)
            except IM.ImouError as e:
                bn, en = SIREN_ERRS["vendor_error"]
                return _err(lang, bn, en, status=502, code="siren_failed",
                            vendor_code=e.code)
            ShopGuardTask.objects.create(site=site, event=ev, kind="siren_off",
                                         due_at=now + timedelta(seconds=secs),
                                         state={"camera_id": cam.id})
            return Response({"ok": True, "route": route, "seconds": secs,
                             "status": "sounding"})
        # Hikvision on the LAN: the Shop Box runs it (it holds the password)
        src = cam.source or {}
        t = ShopGatewayTask.objects.create(
            site=site, camera=cam, action="siren",
            request={"vendor": "hikvision", "host": src.get("host"),
                     "http_port": int(src.get("http_port") or 80),
                     "channel": int(src.get("channel") or 1), "seconds": secs})
        return Response({"ok": True, "route": route, "seconds": secs,
                         "status": "queued", "task_id": t.id}, status=202)


class ShareTargetsView(_OwnerBase):
    def get(self, request, pk):
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None or role != "owner":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        rows = [p for p in circle_people(request.user)]
        left = 0
        if SV.hasattr_clip(ev):
            left = max(0, SHARE_PEOPLE_MAX - len(clip_people(ev.clip, ev.site.owner_id)))
        return Response({"people": rows, "shares_left": left})


# A clip's cost budget (cash_guard COST_PER_CLIP) counts TWO downloads: a
# clip sealed only for the owner may be shown to ONE more person inside it
# (a re-upload from the phone is ingress — free). Nothing is unlimited.
SHARE_PEOPLE_MAX = 2


def clip_people(clip, owner_id):
    m = clip.meta or {}
    return ({str(owner_id)} | set((m.get("wraps") or {}).keys())
            | set((m.get("share") or {}).keys()))


SHARE_ERRS = {
    "no_clip": ("এই সতর্কতার কোনো ক্লিপ নেই।", "This alert has no clip."),
    "expired": ("২৪ ঘণ্টা পেরিয়ে গেছে — ক্লিপটি আর শেয়ার করা যায় না।",
                "24 hours have passed — the clip can no longer be shared."),
    "not_circle": ("শুধু আপনার সার্কেলের যুক্ত মানুষকে ক্লিপ দেখানো যায়।",
                   "You can only share with people connected in your Circle."),
    "no_key": ("এই মানুষটির ফোনে এখনো তালার চাবি তৈরি হয়নি — তাঁকে একবার Assisto খুলতে বলুন।",
               "This person's phone has no lock key yet — ask them to open Assisto once."),
    "bad_wrap": ("ক্লিপের চাবি ঠিকভাবে মোড়ানো হয়নি।", "The clip key was not wrapped correctly."),
    "need_blob": ("সার্ভারের কপি মুছে গেছে — ফোন থেকে তালাবদ্ধ ক্লিপটি আবার পাঠাতে হবে।",
                  "The server copy was deleted — the locked clip must be sent again from the phone."),
    "bad_blob": ("পাঠানো ক্লিপটি আসল ক্লিপের সাথে মেলেনি।", "The clip sent does not match the original."),
    "cap": ("প্রতিটি ক্লিপ শুধু আর একজনকে দেখানো যায় — এটি আগেই দেখানো হয়েছে।",
            "Each clip can be shown to one more person only — this one already was."),
}


def _wrap_ok(w, key_id):
    import base64
    if not isinstance(w, dict):
        return False

    def blen(v):
        try:
            return len(base64.b64decode(str(v), validate=True))
        except Exception:
            return -1
    return (blen(w.get("nonce")) == 12 and 40 <= blen(w.get("ct")) <= 80
            and blen(w.get("sender_pub")) == 32
            and bool(CG._KEYID_RE.match(str(w.get("sender_key_id") or "")))
            and str(w.get("key_id") or "") == str(key_id))


class ClipShareView(_OwnerBase):
    """POST {uid, wrap: {key_id, nonce, ct, sender_pub, sender_key_id}}
    (+ multipart `blob` when the server copy is gone). The OWNER's phone
    unwrapped the clip key with its private key and re-wrapped it for the
    member's PUBLIC key (the chat E2E construction) — the server never sees
    the key or the clip. Same 24 h window; the member's view deletes it."""

    def post(self, request, pk):
        from django.core.files.base import ContentFile
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None or role != "owner":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)

        def e(code, status=422):
            bn, en = SHARE_ERRS[code]
            return _err(lang, bn, en, status=status, code="share_" + code)
        if not SV.hasattr_clip(ev):
            return e("no_clip", 404)
        clip = ev.clip
        now = timezone.now()
        if clip.created + timedelta(seconds=CG.CLIP_TTL_S) <= now or clip.status == "expired":
            return e("expired", 410)
        try:
            uid = int(request.data.get("uid"))
        except (TypeError, ValueError):
            return e("not_circle", 403)
        people = {p["uid"]: p for p in circle_people(request.user)}
        p = people.get(uid)
        if p is None:
            return e("not_circle", 403)
        if not p["has_key"]:
            return e("no_key", 409)
        w = request.data.get("wrap")
        if isinstance(w, str):
            try:
                w = json.loads(w)
            except ValueError:
                w = None
        if not _wrap_ok(w, p["key_id"]):
            return e("bad_wrap")
        meta = dict(clip.meta or {})
        share = dict(meta.get("share") or {})
        fresh = str(uid) not in share
        if fresh and len(clip_people(clip, ev.site.owner_id) | {str(uid)}) > SHARE_PEOPLE_MAX:
            return e("cap", 429)
        fields = ["meta"]
        if clip.status != "ready" or not clip.blob:
            up = request.FILES.get("blob")
            if up is None:
                return e("need_blob", 409)
            limit = SV.owner_caps(ev.site.owner)["clip_kb"] * 1024
            raw = up.read(limit + 1)
            if len(raw) > limit or CG.looks_like_plain_media(raw) or \
                    hashlib.sha256(raw).hexdigest() != clip.sha256:
                return e("bad_blob")
            clip.blob.save("e%d_share.bin" % ev.id, ContentFile(raw), save=False)
            if clip.status == "viewed":
                meta["owner_viewed"] = True       # the owner already watched it
            clip.status = "ready"
            fields += ["blob", "status"]
        wraps = dict(meta.get("wraps") or {})
        wraps[str(uid)] = {k: str(w[k]) for k in ("key_id", "nonce", "ct",
                                                  "sender_pub", "sender_key_id")}
        share[str(uid)] = {"at": now.isoformat(), "viewed": False}
        meta["wraps"] = wraps
        meta["share"] = share
        clip.meta = meta
        clip.save(update_fields=fields)
        if fresh:
            from .models import User
            u = User.objects.filter(pk=uid).first()
            if u is not None:
                owner_name = getattr(request.user, "name", "") or ""
                tb, bb = CX.shared_text("bn", owner_name, ev.site.name)
                te, be = CX.shared_text("en", owner_name, ev.site.name)
                notice(u, ev.site, "shared_clip", tb, te, bb, be, severity="med",
                       data={"event_id": ev.id, "shared": True,
                             "route": "watchman/inbox"})
        return Response({"ok": True, "uid": uid, "expires_at": SV._iso(clip.expires_at),
                         "status": clip.status}, status=201 if fresh else 200)


class EventEvidenceView(_OwnerBase):
    """The FACTS for the evidence pack + a GD draft. The phone adds the photo
    and the clip frames it decrypted, hashes every file (SHA-256) and the
    manifest, and shares the ZIP — the server never sees the plain clip.
    POST {manifest_sha256, files} returns the draft with the final hash."""

    def _facts(self, ev, lang, extra=None):
        site, cam = ev.site, ev.camera
        what_bn, what_en = SV.EVENT_WORDS.get(ev.type, SV.EVENT_WORDS["motion"])
        if (ev.signals or {}).get("nosale"):
            what_bn, what_en = CX.NOSALE_TITLE_BN.split(" — ")[0], CX.NOSALE_TITLE_EN.split(" — ")[0]
        local = _local(ev.created)
        f = {"owner": getattr(site.owner, "name", "") or "",
             "shop": site.name or "", "camera": (cam.name if cam else "") or "",
             "when": local.strftime("%Y-%m-%d %H:%M:%S"),
             "event_id": ev.id, "kind_bn": what_bn, "kind_en": what_en,
             "files": 0, "manifest_sha256": "…"}
        f.update(extra or {})
        return f

    def get(self, request, pk):
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None or role != "owner":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        f = self._facts(ev, lang)
        return Response({"facts": {k: f[k] for k in ("shop", "camera", "when",
                                                     "event_id", "kind_bn", "kind_en")},
                         "created": ev.created.isoformat(),
                         "last_at": SV._iso(ev.last_at or ev.created),
                         "confidence": ev.confidence, "type": ev.type,
                         "tz": "Asia/Dhaka", "hash": "sha256",
                         "gd_draft": CX.gd_draft(lang, f)})

    def post(self, request, pk):
        import re
        lang = req_lang(request)
        ev, role = event_access(request, pk)
        if ev is None or role != "owner":
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        h = str(request.data.get("manifest_sha256") or "").lower()
        if not re.fullmatch(r"[0-9a-f]{64}", h):
            return _err(lang, "manifest-এর আঙুলছাপ ঠিক নেই।", "The manifest fingerprint is not valid.",
                        status=422, code="bad_hash")
        try:
            n = max(0, min(500, int(request.data.get("files") or 0)))
        except (TypeError, ValueError):
            n = 0
        f = self._facts(ev, lang, {"files": n, "manifest_sha256": h})
        sig = dict(ev.signals or {})
        sig["evidence"] = (list(sig.get("evidence") or []) +
                           [{"at": timezone.now().isoformat(), "sha256": h, "files": n}])[-5:]
        type(ev).objects.filter(pk=ev.pk).update(signals=sig)
        return Response({"gd_draft": CX.gd_draft(lang, f), "manifest_sha256": h,
                         "recorded": True})
