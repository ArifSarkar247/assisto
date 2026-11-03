"""
cctv_activity.py — the CCTV ACTIVITY BRAIN glue (cctvactivity, owner CCTV
order 3 Nov E1 E2 E3(visitor log) E5 E6 E7 E10 F2). Pure rules live in
core/logic/cctv_brief.py.

HOOKS (never raise into the caller)
  observe(site, cam, cam_event, now)  top of shop_views._ingest_event — every
                                      camera event, armed or not: hourly
                                      visits, entry-line counts, first/last
                                      person on the shop cameras, watchman
                                      presence. Counts only — no photo kept.
  tick_site(site, now)                from cctvx_views.tick (shop_guard_tick,
                                      every minute; no new cron): health copy
                                      every 10 min, the hourly WATCHMAN check,
                                      the MORNING SUMMARY at the owner's hour.
  describe_due(now)                   from the same tick: up to DESC_PER_TICK
                                      AI descriptions of visitor photos —
                                      ONLY with a vision key AND inside the
                                      per-account monthly cap.

API (owner + family viewer read; owner writes) — behind the EXISTING
home_watchman / cctv_watchman switches:
  GET  shop/sites/<id>/activity?date=       the day: visitors per hour next to
                                            POS sales, conversion, peak hours,
                                            open/close, watchman, health,
                                            summary lines, settings
  PUT  shop/sites/<id>/activity/settings    owner settings
  POST shop/sites/<id>/activity/confirm     owner confirms / corrects the
                                            opening + closing time of a day
  GET  shop/sites/<id>/visitors?date=&days=&q=&from=&to=
                                            visitor log (photo + description),
                                            search by time and words
  GET  shop/sites/<id>/timelapse?date=&camera=
                                            the day's stored photos (links) +
                                            the frame plan; the PHONE builds
                                            the 30-s film (no server video)
"""
import logging
from datetime import datetime, timedelta

from django.db import transaction
from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang, pick
from .logic import cctv_brief as CB

log = logging.getLogger("assisto.shop")

ACT_KEY = "_activity"
DESC_PER_TICK = 2
DESC_MAX_AGE_H = 24
VISITOR_MAX_DAYS = 31
VISITOR_PAGE = 60


# ---------------------------------------------------------------- gate
def feature_on_for(user):
    try:
        from . import feature_flags as FF
    except ImportError:
        return True
    try:
        return bool(FF.is_on("home_watchman", user) or FF.is_on("cctv_watchman", user))
    except Exception:
        return True


class _Base(APIView):
    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not feature_on_for(request.user):
            from rest_framework.exceptions import PermissionDenied
            lang = req_lang(request)
            raise PermissionDenied(detail={
                "error": "feature_off",
                "detail": pick(lang, "এই ফিচারটি এখনো চালু হয়নি।",
                               "This feature is not available yet.")})


def _err(lang, bn, en, status=400, **extra):
    return Response(dict({"error": extra.pop("code", "error"),
                          "detail": pick(lang, bn, en)}, **extra), status=status)


# ---------------------------------------------------------------- state
def _local(dt):
    return timezone.localtime(dt)


def act_of(site):
    g = site.guard if isinstance(site.guard, dict) else {}
    a = g.get(ACT_KEY)
    return a if isinstance(a, dict) else {}


def cfg_of(site):
    return CB.normalize_cfg(act_of(site).get("cfg"))


def act_update(site, fn):
    """Atomically change site.guard["_activity"]; fn(act) mutates and returns
    a result. Never raises (None on failure)."""
    from .models import ShopSite
    try:
        with transaction.atomic():
            row = ShopSite.objects.select_for_update().only("id", "guard").get(pk=site.pk)
            g = dict(row.guard) if isinstance(row.guard, dict) else {}
            act = dict(g.get(ACT_KEY) or {})
            out = fn(act)
            g[ACT_KEY] = act
            ShopSite.objects.filter(pk=site.pk).update(guard=g)
            site.guard = g
            return out
    except Exception:
        log.exception("activity state update failed")
        return None


# ================================================================ observe
def observe(site, cam, cam_event, now=None):
    """Count one camera event (armed or not). Never raises."""
    try:
        now = now or timezone.now()
        etype = cam_event.get("type")
        sig = cam_event.get("signals") if isinstance(cam_event.get("signals"), dict) else {}
        if etype not in CB.MOVEMENT_TYPES and not CB.is_person(etype, sig):
            return False
        local = _local(now)
        cfg = cfg_of(site)
        cid = cam.id if cam is not None else 0

        def f(act):
            CB.observe(act, cfg, cid, etype, sig, local, now.timestamp())
            CB.prune(act, local.date().isoformat())
            return True
        return bool(act_update(site, f))
    except Exception:
        log.exception("activity observe failed")
        return False


# ================================================================ helpers
def _day_bounds(date_str):
    d = datetime.strptime(date_str, "%Y-%m-%d").date()
    tz = timezone.get_current_timezone()
    lo = timezone.make_aware(datetime(d.year, d.month, d.day), tz)
    return lo, lo + timedelta(days=1)


def sales_by_hour(site, date_str):
    counts, amounts = [0] * 24, [0.0] * 24
    lo, hi = _day_bounds(date_str)
    try:
        for kind, amount, at in site.pos_events.filter(
                kind="sale", at__gte=lo, at__lt=hi).values_list("kind", "amount", "at")[:5000]:
            h = _local(at).hour
            counts[h] += 1
            # the Assisto POS mirror (shop_ops_views.mirror_pos) stores
            # Sale.total in TAKA (int), whatever the old model comment says
            amounts[h] += float(amount or 0)
    except Exception:
        log.exception("sales by hour failed")
    return counts, amounts


def alerts_on(site, date_str):
    lo, hi = _day_bounds(date_str)
    return site.events.filter(created__gte=lo, created__lt=hi, pending=False).count()


def _cams(site):
    return list(site.cameras.filter(enabled=True).only(
        "id", "name", "compat", "last_seen", "vendor", "preview"))


def _sd_of(cam):
    c = cam.compat if isinstance(cam.compat, dict) else {}
    st = c.get("alert_state") if isinstance(c.get("alert_state"), dict) else {}
    s = (st.get("sd") or {}).get("state") if isinstance(st.get("sd"), dict) else None
    return s if s in ("ok", "problem", "none") else "unknown"


def offline_minutes_now(site, now):
    """{key: minutes today} from the cctvx guard's own offline log."""
    from . import cctvx_views as CXV
    d = CXV.day_of(site, now)
    rows = d.get("offline_log") or []
    start = _local(now).replace(hour=0, minute=0, second=0, microsecond=0)
    out = {}
    for key in {r[0] for r in rows if r}:
        out[key] = CXV._union_minutes([(a, b) for k, a, b in rows if k == key],
                                      start.timestamp(), now.timestamp())
    return out


def last_photo(site, cam, date_str=None):
    qs = site.events.filter(camera=cam, pending=False).exclude(snapshot="").exclude(
        snapshot__isnull=True)
    if date_str:
        lo, hi = _day_bounds(date_str)
        qs = qs.filter(created__gte=lo, created__lt=hi)
    e = qs.order_by("-created").only("created").first()
    return _local(e.created).strftime("%H:%M") if e else None


def health_rows(site, day, date_str, now, live=False):
    om = (day or {}).get("om") or {}
    sd = (day or {}).get("sd") or {}
    gw = int(om.get("g", 0) or 0)
    rows = []
    for c in _cams(site):
        rows.append({"camera": c.id, "name": c.name or "",
                     "offline_min": max(int(om.get("c%d" % c.id, 0) or 0), gw),
                     "sd": (_sd_of(c) if live else sd.get(str(c.id))) or "unknown",
                     "last_photo": last_photo(site, c, date_str),
                     "last_seen": c.last_seen.isoformat() if c.last_seen else None})
    return rows


def day_view(site, date_str, now, lang):
    act = act_of(site)
    cfg = CB.normalize_cfg(act.get("cfg"))
    day = (act.get("days") or {}).get(date_str) or CB.new_day()
    today = _local(now).date().isoformat()
    foot, src = CB.footfall(day, cfg["foot_dir"])
    sc, sa = sales_by_hour(site, date_str)
    fv = CB.footfall_vs_sales(foot, sc, sa)
    oc = CB.open_close(day, _local(now) if date_str == today else None)
    wm = CB.wm_totals(day)
    health = health_rows(site, day, date_str, now, live=(date_str == today))
    if date_str == today:
        live_om = offline_minutes_now(site, now)
        gw = int(live_om.get("g", 0) or 0)
        for r in health:
            r["offline_min"] = max(int(live_om.get("c%d" % r["camera"], 0) or 0), gw)
    info = {"foot": fv, "foot_src": src, "oc": oc, "wm": wm,
            "alerts": alerts_on(site, date_str), "health": health}
    return {"site": site.id, "date": date_str, "today": date_str == today,
            "foot": fv, "foot_src": src, "open_close": oc,
            "hours": site.hours if isinstance(site.hours, dict) else {},
            "watchman": {"on": cfg["wm_on"], "totals": wm,
                         "hours": [{"hour": int(k), "result": v}
                                   for k, v in sorted((day.get("wm") or {}).items())]},
            "health": health, "alerts": info["alerts"],
            "lines": CB.summary_lines(info, lang),
            "days": sorted((act.get("days") or {}).keys())[-CB.KEEP_DAYS:],
            "ai_used": False}


# ================================================================ tick
def _snapshot_health(site, now):
    om = offline_minutes_now(site, now)
    sd = {str(c.id): _sd_of(c) for c in _cams(site)}
    date = _local(now).date().isoformat()
    act = act_of(site)
    d = (act.get("days") or {}).get(date) or {}
    if d.get("om") == om and d.get("sd") == sd:
        return False

    def f(a):
        dd = CB.day_rec(a, date)
        dd["om"], dd["sd"] = om, sd
        CB.prune(a, date)
        return True
    return bool(act_update(site, f))


def _wm_cams_offline(site, cfg, now):
    """Were the watchman cameras (or the gateway) offline per the cctvx
    guard's own offline state (which includes the vendor-cloud check)?
    Offline -> the hour is 'unknown', never a missed watchman."""
    prev = ((site.guard or {}).get("_state") or {}).get("offline") or {}
    if "g" in prev:
        return True
    rows = [c for c in _cams(site) if not cfg.get("wm_cams") or c.id in cfg["wm_cams"]]
    if not rows:
        return True
    # a camera that never reported is not "online" either
    return all(("c%d" % c.id) in prev or c.last_seen is None for c in rows)


def run_watchman(site, now):
    act = act_of(site)
    cfg = CB.normalize_cfg(act.get("cfg"))
    due = CB.watchman_due(cfg, _local(now), act)
    if not due:
        return None
    date, hour = due
    offline = _wm_cams_offline(site, cfg, now)
    hk = "%02d" % hour

    def f(a):
        d = CB.day_rec(a, date)
        if hk in d["wm"]:
            return None
        v = CB.watchman_verdict(d, hour, offline)
        d["wm"][hk] = v
        night = a.get("wm_night") or {}
        key = cfg["wm_start"] + date if hour * 60 >= int(cfg["wm_start"][:2]) * 60 else \
            cfg["wm_start"] + (datetime.strptime(date, "%Y-%m-%d").date()
                               - timedelta(days=1)).isoformat()
        sent = int(night.get("n", 0)) if night.get("key") == key else 0
        send = v == "miss" and sent < CB.MAX_WM_ALERTS_NIGHT
        if send:
            a["wm_night"] = {"key": key, "n": sent + 1}
        return v, send
    out = act_update(site, f)
    if not out:
        return None
    v, send = out
    if send:
        from . import cctvx_views as CXV
        CXV.notice_site(site, "watchman_missing",
                        lambda lang: CB.watchman_text(lang, site.name, hour),
                        quiet=False, severity="med",
                        data={"hour": hour, "date": date})
    return v


def run_brief(site, now):
    act = act_of(site)
    cfg = CB.normalize_cfg(act.get("cfg"))
    local = _local(now)
    yday = CB.brief_due(cfg, local, act)
    if not yday:
        return False
    today = local.date().isoformat()
    claimed = act_update(site, lambda a: (a.get("brief") != today) and
                         (a.__setitem__("brief", today) or True))
    if not claimed:
        return False
    # a site set up today has no "yesterday": no summary (and no push) for it
    created = getattr(site, "created", None)
    if created is not None and _local(created).date().isoformat() > yday:
        return False
    from . import cctvx_views as CXV
    views = {lg: day_view(site, yday, now, lg) for lg in ("bn", "en")}
    if not (views["bn"]["foot"]["visitors"] or views["bn"]["alerts"] or
            views["bn"]["open_close"]["open"] or views["bn"]["health"]):
        return False
    d_bn = datetime.strptime(yday, "%Y-%m-%d").strftime("%d/%m")

    def texts(lang):
        return (CB.summary_title(lang, site.name, d_bn), "\n".join(views[lang]["lines"]))
    CXV.notice_site(site, "daily_brief", texts, quiet=False, severity="info",
                    data={"date": yday})
    return True


def tick_site(site, now):
    """Called by cctvx_views.tick for every site with cameras. Never raises."""
    out = {}
    try:
        if _local(now).minute % 10 == 0:
            out["health"] = _snapshot_health(site, now)
    except Exception:
        log.exception("activity health copy failed")
    try:
        out["watchman"] = run_watchman(site, now)
    except Exception:
        log.exception("activity watchman failed")
    try:
        out["brief"] = run_brief(site, now)
    except Exception:
        log.exception("activity brief failed")
    return out


# ================================================================ descriptions
def snapshot_bytes(ev):
    """The event photo's plain bytes — through the encrypted store when it
    is merged (agent/cctvevidence core/logic/cctv_store.py), else the file."""
    if not ev.snapshot:
        return None
    try:
        from .logic import cctv_store as CS      # noqa: F401
        try:
            return CS.get(ev.snapshot.name)
        except Exception:
            log.exception("cctv_store read failed")
            return None
    except ImportError:
        pass
    try:
        with ev.snapshot.open("rb") as fh:
            return fh.read(2 * 1024 * 1024)
    except Exception:
        return None


def ai_per_camera():
    """Monthly AI snapshot checks per camera: agent/cctvprice's cctv_plan
    config when merged (Owner Admin -> Pricing), else the same default 50."""
    try:
        from . import billing
        raw = billing.cfg().get("cctv_plan")
    except Exception:
        raw = None
    try:
        from .logic import cctv_plan as CP
        return int(CP.normalize_cfg(raw).get("ai_checks_per_camera", CB.AI_CHECKS_PER_CAMERA))
    except Exception:
        try:
            return int((raw or {}).get("ai_checks_per_camera", CB.AI_CHECKS_PER_CAMERA))
        except Exception:
            return CB.AI_CHECKS_PER_CAMERA


def owner_cap(owner):
    from .models import ShopCamera
    n = ShopCamera.objects.filter(site__owner=owner, enabled=True).count()
    return CB.ai_cap(ai_per_camera(), n)


def _owner_ai_used(owner, month):
    from .models import ShopSite
    used = 0
    for s in ShopSite.objects.filter(owner=owner).only("id", "guard"):
        a = act_of(s).get("ai") or {}
        if a.get("month") == month:
            used += int(a.get("used", 0) or 0)
    return used


def vision_ready():
    try:
        from . import chat_vision_service as CVS
        slug, conf, _cost = CVS._active()
        return (slug, conf) if slug else (None, None)
    except Exception:
        return None, None


def desc_of(ev, lang="bn"):
    sig = ev.signals if isinstance(ev.signals, dict) else {}
    d = sig.get("desc") if isinstance(sig.get("desc"), dict) else None
    if not d:
        inputs = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else {}
        d = CB.template_desc(ev.type, inputs, ev.camera.name if ev.camera_id and ev.camera else "",
                             _local(ev.created), ev.count)
    return d


def describe_one(ev, slug, conf, now):
    """AI description for ONE event photo; template stays on any failure."""
    from .models import ShopEvent
    from . import vision_providers as VP
    site = ev.site
    month = _local(now).strftime("%Y-%m")
    sig = dict(ev.signals or {})
    stop = None
    if _owner_ai_used(site.owner, month) >= owner_cap(site.owner):
        stop = "cap"
    elif not CB.normalize_cfg(act_of(site).get("cfg")).get("ai_desc"):
        stop = "off"
    if stop:
        # keeps its labelled template text; never retried (no queue starvation)
        sig["desc_try"] = 3
        ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
        return stop
    raw = snapshot_bytes(ev)
    if not raw:
        sig["desc_try"] = int(sig.get("desc_try", 0)) + 3
        ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
        return "no_photo"
    # the cap is taken BEFORE the call: a paid call is never free
    act_update(site, lambda a: CB.ai_take(a, month))
    try:
        reply = VP.ask(slug, conf, image_bytes=raw,
                       mime="image/png" if raw[:4] == b"\x89PNG" else "image/jpeg",
                       system=CB.AI_SYSTEM, question="Describe this camera photo.")
        d = CB.clean_ai_desc(reply)
    except Exception:
        d = None
    if d is None:
        sig["desc_try"] = int(sig.get("desc_try", 0)) + 1
        ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
        return "failed"
    sig["desc"] = d
    ShopEvent.objects.filter(pk=ev.pk).update(signals=sig)
    return "ai"


def describe_due(now=None, limit=DESC_PER_TICK):
    """Bounded AI pass over fresh visitor photos. Never raises."""
    now = now or timezone.now()
    out = {"ai": 0, "skipped": 0}
    try:
        slug, conf = vision_ready()
        if not slug:
            return out
        from .models import ShopEvent
        qs = (ShopEvent.objects.filter(created__gte=now - timedelta(hours=DESC_MAX_AGE_H),
                                       pending=False, type__in=CB.VISITOR_TYPES)
              .exclude(snapshot="").exclude(snapshot__isnull=True)
              .select_related("site", "site__owner", "camera").order_by("-created")[:40])
        for ev in qs:
            if out["ai"] >= limit:
                break
            sig = ev.signals if isinstance(ev.signals, dict) else {}
            if (sig.get("desc") or {}).get("src") == "ai" or int(sig.get("desc_try", 0)) >= 3:
                continue
            if not feature_on_for(ev.site.owner):
                continue
            r = describe_one(ev, slug, conf, now)
            if r == "ai":
                out["ai"] += 1
            else:
                out["skipped"] += 1
    except Exception:
        log.exception("activity describe pass failed")
    return out


# ================================================================ views
def _site_for(request, pk, owner_only=False):
    from . import shop_views as SV
    if owner_only:
        s = SV._owner_site(request, pk)
        return s, ("owner" if s else None)
    return SV._viewable_site(request, pk)


def _date_arg(request, now):
    raw = (request.query_params.get("date") or "").strip()
    if not raw:
        return _local(now).date().isoformat()
    try:
        d = datetime.strptime(raw.translate(str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")),
                              "%Y-%m-%d").date()
    except ValueError:
        return None
    today = _local(now).date()
    if d > today or (today - d).days > 400:
        return None
    return d.isoformat()


_CFG_ERR = {"bad_hour": ("সময় ০–২৩ ঘণ্টার মধ্যে দিন।", "Pick an hour from 0 to 23."),
            "bad_window": ("পাহারার শুরু ও শেষ সময় ঠিক করে দিন (দুটো আলাদা)।",
                           "Set a valid watchman start and end time (not equal)."),
            "bad_cameras": ("এই দোকানের ক্যামেরা বাছাই করুন।", "Pick cameras of this site."),
            "bad_direction": ("দিক ঠিক নয়।", "Invalid direction."),
            "bad_time": ("সময় HH:MM আকারে দিন।", "Give the time as HH:MM.")}


def _cfg_out(site, lang):
    cfg = cfg_of(site)
    slug, _c = vision_ready()
    month = _local(timezone.now()).strftime("%Y-%m")
    cap = owner_cap(site.owner)
    return dict(cfg, cameras=[{"id": c.id, "name": c.name or ""} for c in _cams(site)],
                ai={"ready": bool(slug), "cap": cap,
                    "used": _owner_ai_used(site.owner, month),
                    "note": pick(lang,
                                 "AI বর্ণনা: ক্যামেরা প্রতি মাসে %s ছবি। AI চাবি না থাকলে বা সীমা শেষে ধরন-সময় থেকে লেখা (AI নয়)।",
                                 "AI descriptions: %s photos per camera per month. Without an AI key or past the limit: text from type and time (not AI).")
                    % (CB._d(ai_per_camera(), lang))})


class ActivityView(_Base):
    def get(self, request, pk):
        lang = req_lang(request)
        lang = lang if lang in ("bn", "en") else "bn"
        site, role = _site_for(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404, code="not_found")
        now = timezone.now()
        date = _date_arg(request, now)
        if date is None:
            return _err(lang, "তারিখ ঠিক নয়।", "Invalid date.", code="bad_date")
        out = day_view(site, date, now, lang)
        out["role"] = role
        if role == "owner":
            out["settings"] = _cfg_out(site, lang)
        return Response(out)


class ActivitySettingsView(_Base):
    def put(self, request, pk):
        lang = req_lang(request)
        site, _r = _site_for(request, pk, owner_only=True)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404, code="not_found")
        allowed = {c.id for c in _cams(site)}
        body = request.data if isinstance(request.data, dict) else {}
        cur = cfg_of(site)
        # a camera removed since the last save must not block this save
        for k in ("shop_cams", "wm_cams"):
            cur[k] = [c for c in cur.get(k) or [] if c in allowed]
        merged = dict(cur, **{k: v for k, v in body.items() if k in CB.defaults()})
        try:
            clean = CB.normalize_cfg(merged, allowed, strict=True)
        except CB.CfgError as e:
            b, en = _CFG_ERR.get(e.code, _CFG_ERR["bad_hour"])
            return _err(lang, b, en, status=422, code=e.code)
        act_update(site, lambda a: a.__setitem__("cfg", clean))
        return Response(_cfg_out(site, lang if lang in ("bn", "en") else "bn"))

    post = put


class ActivityConfirmView(_Base):
    def post(self, request, pk):
        lang = req_lang(request)
        site, _r = _site_for(request, pk, owner_only=True)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404, code="not_found")
        now = timezone.now()
        body = request.data if isinstance(request.data, dict) else {}
        raw = str(body.get("date") or "")
        try:
            d = datetime.strptime(raw, "%Y-%m-%d").date()
        except ValueError:
            return _err(lang, "তারিখ ঠিক নয়।", "Invalid date.", code="bad_date")
        if d > _local(now).date() or (_local(now).date() - d).days > CB.KEEP_DAYS:
            return _err(lang, "তারিখ ঠিক নয়।", "Invalid date.", code="bad_date")
        o, c = body.get("open"), body.get("close")
        for v in (o, c):
            if v not in (None, "") and CB.WM.parse_hhmm(v) is None:
                b, en = _CFG_ERR["bad_time"]
                return _err(lang, b, en, status=422, code="bad_time")

        def f(a):
            day = CB.day_rec(a, d.isoformat())
            CB.confirm_times(day, o, c)
            CB.prune(a, _local(now).date().isoformat())
            return day.get("ok")
        ok = act_update(site, f)
        return Response({"date": d.isoformat(), "confirmed": ok or {},
                         "open_close": CB.open_close((act_of(site).get("days") or {}).get(d.isoformat()))})


def _visitor_row(ev, request, lang):
    from . import shop_views as SV
    row = SV._event_row(ev, request)
    d = desc_of(ev)
    return {"id": ev.id, "type": ev.type, "at": ev.created.isoformat(),
            "time": _local(ev.created).strftime("%H:%M"),
            "date": _local(ev.created).date().isoformat(),
            "camera": ev.camera_id, "camera_name": row.get("camera_name") or "",
            "count": ev.count, "snapshot_url": row.get("snapshot_url"),
            "what": row.get("what"), "status": ev.status,
            "desc": d.get(lang) or d.get("bn"), "desc_bn": d.get("bn"), "desc_en": d.get("en"),
            "desc_src": d.get("src", "template")}


class VisitorLogView(_Base):
    def get(self, request, pk):
        lang = req_lang(request)
        lang = lang if lang in ("bn", "en") else "bn"
        site, _role = _site_for(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404, code="not_found")
        now = timezone.now()
        date = _date_arg(request, now)
        if date is None:
            return _err(lang, "তারিখ ঠিক নয়।", "Invalid date.", code="bad_date")
        try:
            days = max(1, min(VISITOR_MAX_DAYS, int(request.query_params.get("days") or 1)))
        except ValueError:
            days = 1
        lo, hi = _day_bounds(date)
        lo = lo - timedelta(days=days - 1)
        q = (request.query_params.get("q") or "")[:80]
        hf = request.query_params.get("from")
        ht = request.query_params.get("to")
        tf = CB.WM.parse_hhmm(hf) if hf else None
        tt = CB.WM.parse_hhmm(ht) if ht else None
        qs = (site.events.filter(created__gte=lo, created__lt=hi, pending=False,
                                 type__in=CB.VISITOR_TYPES)
              .select_related("camera").order_by("-created")[:1500])
        rows = []
        for ev in qs:
            t = _local(ev.created).time().replace(second=0, microsecond=0)
            if tf and tt:
                inside = (tf <= t < tt) if tf < tt else (t >= tf or t < tt)
                if not inside:
                    continue
            elif tf and t < tf:
                continue
            elif tt and t >= tt:
                continue
            r = _visitor_row(ev, request, lang)
            if q and not CB.matches(" ".join(str(x or "") for x in (
                    r["desc_bn"], r["desc_en"], r["camera_name"], r["what"], r["time"],
                    CB._KIND_BN.get(ev.type), CB._KIND_EN.get(ev.type))), q):
                continue
            rows.append(r)
            if len(rows) >= VISITOR_PAGE:
                break
        slug, _c = vision_ready()
        return Response({"site": site.id, "date": date, "days": days, "q": q,
                         "rows": rows, "more": len(rows) >= VISITOR_PAGE,
                         "ai_ready": bool(slug),
                         "label": pick(lang, "বর্ণনা: AI (চাবি ও মাসিক সীমা থাকলে) নয়তো ধরন-সময় থেকে স্বয়ংক্রিয় লেখা। মুখ চেনা হয় না।",
                                       "Descriptions: AI (when a key and the monthly limit allow), else automatic text from type and time. No face recognition.")})


class TimelapseView(_Base):
    MAX_FRAMES = 60          # the phone encodes each frame; ~0.5 s each

    def get(self, request, pk):
        from . import shop_views as SV
        lang = req_lang(request)
        lang = lang if lang in ("bn", "en") else "bn"
        site, _role = _site_for(request, pk)
        if site is None:
            return _err(lang, "পাওয়া যায়নি।", "Not found.", status=404, code="not_found")
        now = timezone.now()
        date = _date_arg(request, now)
        if date is None:
            return _err(lang, "তারিখ ঠিক নয়।", "Invalid date.", code="bad_date")
        lo, hi = _day_bounds(date)
        qs = (site.events.filter(created__gte=lo, created__lt=hi, pending=False)
              .exclude(snapshot="").exclude(snapshot__isnull=True)
              .select_related("camera").order_by("created"))
        cam = request.query_params.get("camera")
        if cam:
            try:
                qs = qs.filter(camera_id=int(cam))
            except ValueError:
                pass
        evs = CB.spread(list(qs[:2000]), self.MAX_FRAMES)
        frames = []
        for ev in evs:
            row = SV._event_row(ev, request)
            if row.get("snapshot_url"):
                frames.append({"url": row["snapshot_url"], "at": ev.created.isoformat(),
                               "time": _local(ev.created).strftime("%H:%M"),
                               "camera_name": row.get("camera_name") or ""})
        plan = CB.timelapse_plan(len(frames))
        return Response({"site": site.id, "date": date, "frames": frames, "plan": plan,
                         "server_video": False,
                         "note": pick(lang, "দিনের জমা ছবি ফোনেই জোড়া লাগানো হয় — সার্ভারে কোনো ভিডিও বানানো বা রাখা হয় না। এটি পুরো ভিডিও নয়, ছবির ধারা।",
                                      "Your phone joins the day's stored photos — no video is made or kept on the server. It is a photo sequence, not full video.")})
