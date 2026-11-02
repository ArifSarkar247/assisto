"""
cctv_alerts.py — W3 smart alert types (cctvalerts, 3 Nov): the Django glue
around the pure rules in logic/cctv_rules.py.

  * prepare()          — called at the top of shop_views._ingest_event for
                         every camera event: records the kinds a camera really
                         sends, counts line crossings, applies the owner's
                         per-camera type switches, runs the night LOITERING
                         rule and the dark / covered / moved still check on the
                         one still that already came with the event.
  * vendor_type()      — Imou / EZVIZ alarm -> camera_alarm | camera_health.
  * imou_status()      — Imou SD-card status callback -> camera_health.
  * ezviz_sd_check()   — EZVIZ storage status every few hours (poll pass).
  * health_still()     — one health still per cloud camera every
                         HEALTH_STILL_MIN in the guard window, only while the
                         owner keeps covered / moved / dark on (cctvx tick).
  * CameraAlertTypesView — GET/PUT shop/cameras/<id>/alert-types: the
                         per-camera switches + honest support per vendor.

Gated by the EXISTING switches (home_watchman / cctv_watchman), no new flag.
State lives in ShopCamera.compat["alert_state"] (kept across gateway checks,
watchman_views.COMPAT_KEEP); switches in zone_config["alert_types"].
Never raises into the ingest path.
"""
import io
import logging

from django.utils import timezone
from rest_framework.response import Response
from rest_framework.views import APIView

from .i18n import req_lang
from .logic import cctv_rules as CR

log = logging.getLogger(__name__)

STATE_KEY = "alert_state"
PRESENCE_TYPES = ("motion", "person_detected", "zone_intrusion", "line_crossing",
                  "camera_alarm", "after_hours", "hand_in_cash_zone")
HEALTH_STILL_MIN = 120
HEALTH_RECHECK_S = 5 * 60


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


def _cfg_int(key, default):
    from . import billing
    try:
        return int((billing.cfg().get("shop") or {}).get(key, default))
    except Exception:
        return default


# ---------------------------------------------------------------- state
def load_state(cam):
    c = cam.compat if isinstance(cam.compat, dict) else {}
    st = c.get(STATE_KEY)
    return dict(st) if isinstance(st, dict) else {}


def save_state(cam, st):
    """Merge into the FRESH compat (another writer may have changed other
    keys since `cam` was loaded)."""
    from .models import ShopCamera
    try:
        row = ShopCamera.objects.filter(pk=cam.pk).values_list("compat", flat=True).first()
        compat = dict(row or {})
        compat[STATE_KEY] = st
        ShopCamera.objects.filter(pk=cam.pk).update(compat=compat)
        cam.compat = compat
    except Exception:
        log.exception("alert_state save failed for camera %s", getattr(cam, "pk", None))


def toggles_of(cam):
    zc = cam.zone_config if isinstance(cam.zone_config, dict) else {}
    return CR.normalize_toggles(zc.get("alert_types"))


def _local(now):
    return timezone.localtime(now)


def night_window(cam):
    """Which window counts as NIGHT for loitering: the camera's own guard
    schedule, else after the closing time, else 22:00-06:00."""
    from .logic import watchman as WM
    from .shop_views import effective_zone_config
    zc = effective_zone_config(cam)
    v2 = WM.zone_v2(zc)
    if v2 and v2.get("schedule"):
        s = v2["schedule"]
        return {"source": "schedule", "start": s.get("start"), "end": s.get("end")}
    h = zc.get("hours") if isinstance(zc.get("hours"), dict) else None
    if h and h.get("open") and h.get("close"):
        return {"source": "hours", "start": h.get("close"), "end": h.get("open")}
    return dict(CR.NIGHT_DEFAULT, source="default")


def is_night(cam, now):
    from .logic import watchman as WM
    from .logic import camera_hooks as CH
    from .shop_views import effective_zone_config
    zc = effective_zone_config(cam)
    local = _local(now)
    v2 = WM.zone_v2(zc)
    if v2 and v2.get("schedule"):
        return WM.is_armed(v2["schedule"], local)
    if isinstance(zc.get("hours"), dict) and zc["hours"].get("open"):
        return CH.is_after_hours(zc["hours"], local)
    return WM.in_window(CR.NIGHT_DEFAULT, local)


# ---------------------------------------------------------------- stills
def grid_of(raw):
    """8x8 luminance grid + mean + std + ir (grey picture) of a still, or
    None. PIL on a <=640 px still: a few ms."""
    try:
        from PIL import Image, ImageStat
        im = Image.open(io.BytesIO(raw))
        im.draft("RGB", (160, 160))
        rgb = im.convert("RGB")
        rgb.thumbnail((160, 160))
        r, g, b = ImageStat.Stat(rgb).mean
        ir = abs(r - g) < 3 and abs(g - b) < 3
        grey = rgb.convert("L")
        st = ImageStat.Stat(grey)
        small = grey.resize((8, 8))
        return {"grid": [float(v) for v in small.getdata()], "mean": st.mean[0],
                "std": st.stddev[0], "ir": bool(ir)}
    except Exception:
        return None


def _snapshot_bytes(snapshot):
    if snapshot is None:
        return None
    try:
        snapshot.seek(0)
        raw = snapshot.read()
        snapshot.seek(0)
        return raw
    except Exception:
        return None


def assess(cam, st, raw, now):
    """Run the still check; returns (state, kind or None)."""
    g = grid_of(raw) if raw else None
    if g is None:
        return st, None
    sst, kind = CR.assess_still(st.get("still"), g["grid"], g["mean"], g["std"],
                                g["ir"], now.timestamp())
    st["still"] = sst
    return st, kind


def _health_event(kind, source, ts, extra=None):
    sig = {"kind": kind, "source": source, "health": True}
    sig.update(extra or {})
    return {"type": "camera_health", "signals": sig, "at": ts}


# ---------------------------------------------------------------- prepare
def prepare(site, cam, cam_event, now, snapshot=None):
    """-> (cam_event, extra_events, muted_reason). Never raises: on any error
    the event goes on unchanged."""
    try:
        return _prepare(site, cam, cam_event, now, snapshot)
    except Exception:
        log.exception("cctv_alerts.prepare failed")
        return cam_event, [], None


def _prepare(site, cam, cam_event, now, snapshot):
    if cam is None or not feature_on_for(site.owner):
        return cam_event, [], None
    etype = cam_event.get("type")
    sig = dict(cam_event.get("signals") or {})
    kind, obj = sig.get("kind"), sig.get("object")
    if not kind and etype == "person_detected":
        kind = obj = "person"
    if not kind and sig.get("human"):
        kind = obj = "person"
    if kind and not sig.get("kind"):
        sig["kind"] = kind
    ts = now.timestamp()
    st = load_state(cam)
    toggles = toggles_of(cam)
    extra = []

    # 1. kinds this camera has really sent (upgrades "some models" -> yes)
    seen = list(st.get("seen") or [])
    for k in (kind, obj):
        if k in CR.KINDS and k not in seen and not sig.get("health_still"):
            seen.append(k)
    st["seen"] = seen

    # 2. line crossings are counted even when the alert is switched off
    if kind == "line" or etype == "line_crossing":
        day = _local(now).date().isoformat()
        st["line"] = CR.line_count(st.get("line"), day, sig.get("direction"))

    # 3. the owner's switch for this type
    if kind and CR.muted(toggles, kind, obj):
        save_state(cam, st)
        return dict(cam_event, signals=sig), [], "type_off"

    # 4. camera-health: at most once per kind per 6 h
    if etype == "camera_health":
        fired = dict(st.get("health_fired") or {})
        if not CR.health_due(fired, kind, ts):
            save_state(cam, st)
            return dict(cam_event, signals=sig), [], "health_recent"
        fired[kind] = ts
        st["health_fired"] = fired

    # 5. LOITERING (person present >= 2 min at night)
    person = (obj == "person" or kind == "person" or etype == "person_detected"
              or bool(sig.get("human")))
    native = kind == "loiter"
    if (person or native) and etype in PRESENCE_TYPES + ("loitering",):
        night = is_night(cam, now)
        lst, fire, dur = CR.loiter_step(st.get("loiter"), float(cam_event.get("at") or ts),
                                        night, native=native)
        st["loiter"] = lst
        if fire and toggles.get("loiter"):
            ev = {"type": "loitering", "at": ts,
                  "signals": {"kind": "loiter", "object": "person", "human": True,
                              "night": True, "seconds": dur,
                              "source": sig.get("source") or "server_rule",
                              "vendor_native": native}}
            if native:
                cam_event, sig = ev, ev["signals"]
            else:
                extra.append(ev)

    # 6. dark / covered / moved from the still that came with the event
    if snapshot is not None and any(toggles.get(k) for k in ("covered", "moved", "dark")) \
            and etype != "camera_health":
        st, hk = assess(cam, st, _snapshot_bytes(snapshot), now)
        if hk and toggles.get(hk):
            fired = dict(st.get("health_fired") or {})
            if CR.health_due(fired, hk, ts):
                fired[hk] = ts
                st["health_fired"] = fired
                extra.append(_health_event(hk, "server_still", ts))
    save_state(cam, st)
    return dict(cam_event, signals=sig), extra, None


# ---------------------------------------------------------------- vendors
def vendor_type(etype, cls):
    """A vendor-cloud alarm whose kind is a camera-health problem is a
    camera_health event (not gated by the guard schedule). Tamper/covered
    stays the camera's own alarm, as before."""
    if etype == "camera_alarm" and (cls or {}).get("kind") in ("moved", "sd_fail", "dark"):
        return "camera_health"
    return etype


def ingest_health(cam, kind, now, source, snapshot=None, extra=None):
    """Raise a camera_health event through the normal guard path."""
    from . import shop_views as SV
    return SV._ingest_event(cam.site, cam, _health_event(kind, source, now.timestamp(), extra),
                            now, snapshot)


def note_sd(cam, state_value, now, source):
    """Remember an SD state; a change ok/none -> problem raises one alert."""
    st = load_state(cam)
    prev = (st.get("sd") or {}).get("state")
    st["sd"] = {"state": state_value, "at": now.timestamp()}
    seen = list(st.get("seen") or [])
    if "sd_fail" not in seen and state_value in ("ok", "problem"):
        seen.append("sd_fail")
        st["seen"] = seen
    save_state(cam, st)
    if state_value == "problem" and prev != "problem" and feature_on_for(cam.site.owner):
        return ingest_health(cam, "sd_fail", now, source)
    return None


def imou_status(msg, now):
    """An Imou SD-card status callback. Returns True when it was one."""
    from .models import ShopCamera
    v = CR.imou_sd_problem(msg)
    if v is None:
        return False
    did = str(msg.get("did") or msg.get("deviceId") or "").strip().upper()
    if not did:
        return True
    for cam in ShopCamera.objects.filter(vendor_ref__startswith=did + ":",
                                         enabled=True).select_related("site")[:4]:
        try:
            note_sd(cam, v, now, "imou_status")
        except Exception:
            log.exception("imou sd status failed")
    return True


def ezviz_sd_check(cam, client, serial, now):
    """Every SD_CHECK_EVERY_S per EZVIZ camera (inside the poll pass)."""
    st = load_state(cam)
    last = float((st.get("sd") or {}).get("checked") or 0)
    if now.timestamp() - last < CR.SD_CHECK_EVERY_S:
        return None
    try:
        rows = client.sd_status(serial)   # shared with cctv_evidence.sd_health
    except Exception:
        return None
    v = CR.ezviz_sd_state(rows)
    out = note_sd(cam, v, now, "ezviz_storage")
    st = load_state(cam)
    sd = dict(st.get("sd") or {})
    sd["checked"] = now.timestamp()
    st["sd"] = sd
    save_state(cam, st)
    return out


# ---------------------------------------------------------------- health stills
def health_still(cam, now, clients, fetch=None):
    """One health still for a cloud camera (Imou / EZVIZ) when it is due.
    Returns the raised event or None. Never raises."""
    try:
        return _health_still(cam, now, clients, fetch)
    except Exception:
        log.exception("health still failed for camera %s", cam.pk)
        return None


def _health_still(cam, now, clients, fetch):
    if cam.vendor not in ("imou", "ezviz") or not cam.vendor_ref:
        return None
    every = _cfg_int("health_still_min", HEALTH_STILL_MIN)
    if every <= 0:
        return None
    toggles = toggles_of(cam)
    if not any(toggles.get(k) for k in ("covered", "moved", "dark")):
        return None
    from .logic import watchman as WM
    v2 = WM.zone_v2(cam.zone_config)
    if v2 and v2.get("schedule") and not WM.is_armed(v2["schedule"], _local(now)):
        return None
    st = load_state(cam)
    last = float(st.get("still_at") or 0)
    bad = (st.get("still") or {}).get("bad")
    wait = HEALTH_RECHECK_S if bad else every * 60
    if now.timestamp() - last < wait:
        return None
    if not feature_on_for(cam.site.owner):
        return None
    st["still_at"] = now.timestamp()
    save_state(cam, st)
    raw = (fetch or _fetch_still)(cam, clients)
    if not raw:
        return None
    from . import shop_views as SV
    if SV.looks_like_video(raw):
        return None
    st = load_state(cam)
    st, kind = assess(cam, st, raw, now)
    save_state(cam, st)
    if not kind or not toggles.get(kind):
        return None
    snap = SV._small_jpeg(raw, "health%d.jpg" % cam.id) \
        if cam.site.snapshot_retention_days > 0 else None
    return ingest_health(cam, kind, now, "server_still", snap, {"health_still": True})


def _fetch_still(cam, clients):
    if cam.vendor == "imou" and clients.get("imou"):
        from .logic import imou as IM
        dev, _, ch = cam.vendor_ref.partition(":")
        url = clients["imou"].snapshot_url(dev, ch or "0")
        if url and IM.snapshot_url_allowed(url):
            return IM.fetch_snapshot(url)
        return None
    if cam.vendor == "ezviz" and clients.get("ezviz"):
        from .logic import ezviz as EZ
        from .cashguard_views import _fetch_ezviz_pic
        try:
            _, serial, ch = cam.vendor_ref.split(":")
        except ValueError:
            return None
        url = clients["ezviz"].capture(serial, int(ch or 1))
        if url and EZ.snapshot_url_allowed(url):
            return _fetch_ezviz_pic(url, None)
    return None


# ---------------------------------------------------------------- view
def _bn(v):
    return str(v).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


def types_payload(cam, lang):
    li = 0 if lang == "bn" else 1
    st = load_state(cam)
    seen = set(st.get("seen") or [])
    toggles = toggles_of(cam)
    rows = []
    for k in CR.KINDS:
        sup = CR.support_for(cam.vendor, k, seen)
        note = CR.SEEN_TEXT[li] if k in seen else CR.SUPPORT_TEXT[sup][li]
        rows.append({"kind": k, "on": bool(toggles[k]) and sup != CR.NO,
                     "support": sup, "seen": k in seen,
                     "available": sup != CR.NO,
                     "label": CR.LABELS[k][li], "note": note})
    nw = night_window(cam)
    src = {"schedule": ("আপনার পাহারার সময়সূচি", "your guard schedule"),
           "hours": ("দোকান বন্ধের সময়", "after closing time"),
           "default": ("রাত ১০টা – সকাল ৬টা", "10 pm – 6 am")}[nw["source"]][li]
    start, end = nw.get("start") or "", nw.get("end") or ""
    if lang == "bn":
        start, end = _bn(start), _bn(end)
    line = st.get("line") or {}
    today = _local(timezone.now()).date().isoformat()
    if line.get("day") != today:
        line = {"day": today, "total": 0, "a_to_b": 0, "b_to_a": 0}
    sd = st.get("sd") or {}
    sd_state = sd.get("state") or "unknown"
    sd_text = {"ok": ("SD কার্ড ঠিক আছে", "SD card OK"),
               "problem": ("SD কার্ডে সমস্যা", "SD card problem"),
               "none": ("SD কার্ড নেই", "No SD card"),
               "unknown": ("SD কার্ডের খবর এখনো আসেনি", "No SD card status yet")}[sd_state][li]
    return {"camera": cam.id, "vendor": cam.vendor or "", "types": rows,
            "night": {"source": nw["source"], "start": start, "end": end,
                      "text": src},
            "line_today": {k: int(line.get(k, 0)) for k in ("total", "a_to_b", "b_to_a")},
            "sd": {"state": sd_state, "text": sd_text},
            "ai_used": False}


class CameraAlertTypesView(APIView):
    """GET/PUT shop/cameras/<id>/alert-types — owner only; behind the
    existing home_watchman / cctv_watchman switches."""

    def initial(self, request, *args, **kwargs):
        super().initial(request, *args, **kwargs)
        if not feature_on_for(request.user):
            from rest_framework.exceptions import PermissionDenied
            lang = req_lang(request)
            raise PermissionDenied(detail={
                "error": "feature_off",
                "detail": "এই ফিচারটি এখনো চালু হয়নি।" if lang == "bn"
                else "This feature is not available yet."})

    def get(self, request, pk):
        from . import watchman_views as WV
        lang = req_lang(request)
        cam = WV._owner_cam(request, pk)
        if cam is None:
            return WV._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        return Response(types_payload(cam, lang))

    def put(self, request, pk):
        from . import watchman_views as WV
        from .models import ShopCamera
        lang = req_lang(request)
        cam = WV._owner_cam(request, pk)
        if cam is None:
            return WV._err(lang, "পাওয়া যায়নি।", "Not found.", status=404)
        raw = request.data.get("types", request.data)
        if not isinstance(raw, dict):
            return WV._err(lang, "তথ্য ঠিক নেই।", "Invalid data.", status=422,
                           code="bad_types")
        zc = dict(cam.zone_config) if isinstance(cam.zone_config, dict) else {}
        zc["alert_types"] = CR.normalize_toggles(raw, zc.get("alert_types"))
        ShopCamera.objects.filter(pk=cam.pk).update(zone_config=zc)
        cam.zone_config = zc
        return Response(types_payload(cam, lang))

    post = put     # the app's JSON client speaks POST
