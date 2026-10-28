"""
Vehicle tracking HTTP API (v1-vehicle). All routes under /api/vehicle/.

ACCESS (server-enforced, tested for every denied case):
  * owner                      -> view + command + manage
  * family grant (can_command?)-> view (+ command). Valid only while the grantee
                                  is still an ACCEPTED, unblocked circle peer.
  * fleet grant (can_command?) -> view (+ command). Valid only while the grantee
                                  is still ACTIVE staff of the owner's business.
  * anyone else                -> 404 (we do not even confirm the tracker exists)
Commands additionally need the REQUESTER's own Assisto Security PIN (the
"admin PIN for remote control"), and engine cut is refused server-side unless
the latest fix is fresh and the vehicle is stopped / under the speed cap.
"""
import json
import re
from datetime import timedelta

from django.conf import settings
from django.utils import timezone
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import vehicle_tracking as VT
from .logic import obd_dtc
from . import vehicle_service as VS

R = Response
HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
MAX_GEOFENCES = 10
MAX_TRACKERS_PER_USER = 25
MAX_CARMODE_POINTS = 5000
MAX_ROUTES = 5
MAX_ROUTE_POINTS = 300


# --------------------------------------------------------------- access

def _grant_valid(g, owner):
    from .models import CircleMember, BusinessStaff
    if g.kind == "family":
        return CircleMember.objects.filter(
            user=owner, peer_user=g.grantee, state="accepted",
            blocked=False).exists()
    return BusinessStaff.objects.filter(
        business__user=owner, member=g.grantee, active=True).exists()


def access_for(user, tracker):
    """{'view','command','manage'} booleans for `user` on `tracker`."""
    if not user or not user.is_authenticated:
        return {"view": False, "command": False, "manage": False}
    if tracker.owner_id == user.id:
        return {"view": True, "command": True, "manage": True, "user": user}
    g = tracker.grants.filter(grantee=user).first()
    if g is None or not _grant_valid(g, tracker.owner):
        return {"view": False, "command": False, "manage": False}
    return {"view": True, "command": bool(g.can_command), "manage": False, "user": user}


def _load(request, pk, need="view"):
    """(tracker, access, None) or (None, None, error Response)."""
    from .models import VehicleTracker
    t = VehicleTracker.objects.filter(pk=pk).select_related(
        "owner", "vehicle_record", "approver").first()
    if t is None:
        return None, None, R({"reason": "not_found", "ok": False}, status=404)
    acc = access_for(request.user, t)
    if not acc["view"]:
        return None, None, R({"reason": "not_found", "ok": False}, status=404)
    if not acc[need]:
        return None, None, R({"reason": "forbidden", "ok": False}, status=403)
    return t, acc, None


def _iso(dt):
    return dt.isoformat() if dt else None


def _tracker_json(t, acc, now, cfg):
    online = VT.is_online(t.last_seen_at, now, cfg["online_window_s"])
    fix_age = int((now - t.last_fix_at).total_seconds()) if t.last_fix_at else None
    out = {
        "id": t.id, "name": VS._vehicle_name(t), "imei_tail": t.imei[-4:],
        "protocol": t.protocol, "state": t.state,
        "disabled_reason": t.disabled_reason,
        "pair_expires_at": _iso(t.pair_expires_at), "paired_at": _iso(t.paired_at),
        "billed_until": _iso(t.billed_until),
        "vehicle_record_id": t.vehicle_record_id,
        "online": online, "last_seen_at": _iso(t.last_seen_at),
        "live": None if t.last_lat is None else {
            "lat": t.last_lat, "lng": t.last_lng, "speed_kmh": t.last_speed_kmh,
            "course": t.last_course, "at": _iso(t.last_fix_at), "fix_age_s": fix_age,
            "moving": (t.last_speed_kmh or 0) >= VT.MOVING_KMH},
        "ignition": t.ignition, "relay_cut": t.relay_cut,
        "ext_voltage_v": t.ext_voltage_v, "battery_v": t.battery_v,
        "access": {k: v for k, v in acc.items() if k != "user"},
        "is_owner": acc["manage"],
        "odometer_km": t.odometer_km,
        "engine_cut_enabled": engine_cut_on(acc.get("user")),
    }
    try:
        from . import vehicle100 as V1
        sh = V1.current_shift(t)
        out["driver"] = V1.shift_json(sh) if sh else None
    except Exception:
        out["driver"] = None
    if acc["manage"]:
        out["imei"] = t.imei
        out["settings"] = {
            "moving_interval_s": t.moving_interval_s,
            "parked_interval_s": t.parked_interval_s,
            "speed_limit_kmh": t.speed_limit_kmh,
            "night_ignition_alert": t.night_ignition_alert,
            "night_start": t.night_start, "night_end": t.night_end,
            "geofences": VS.split_fences(t.geofences)[0],
            "routes": VS.split_fences(t.geofences)[1],
            "cutoff_requires_approval": t.cutoff_requires_approval,
            "approver_member_id": t.approver_id,
            "alert_prefs": VS.alert_prefs(t),
            "odometer_base_km": t.odometer_base_km,
        }
    return out


def engine_cut_on(user):
    """veh100: remote engine cut is behind the `vehicle_engine_cut` flag (OFF
    until a real relay test). Owner / staff / allow-listed testers preview."""
    try:
        from . import feature_flags as FF
        return bool(FF.is_on("vehicle_engine_cut", user))
    except Exception:
        return False


def _cmd_json(c):
    return {"id": c.id, "kind": c.kind, "state": c.state,
            "fail_reason": c.fail_reason, "response": c.response,
            "requested_by_me": None, "created_at": _iso(c.created_at),
            "sent_at": _iso(c.sent_at), "done_at": _iso(c.done_at)}


def _server_info():
    host = getattr(settings, "TRACKER_PUBLIC_HOST", "track.lifeassisto.com")
    port = int(getattr(settings, "TRACKER_PUBLIC_PORT", 5023))
    return {"host": host, "port": port,
            # Concox: SERVER,1,<domain>,<port>,0#  (1 = domain, last 0 = TCP)
            # Teltonika SMS (empty login/pass -> two leading spaces):
            #   "  setparam 2004:<domain>;2005:<port>;2006:0"  (2006 0 = TCP)
            # Sinotrack ST-901 (H02): 804<pass> <ip|domain> <port>, default pass 0000
            "setup_sms": {"gt06": "SERVER,1,%s,%d,0#" % (host, port),
                          "h02": "8040000 %s %d" % (host, port),
                          "teltonika": "  setparam 2004:%s;2005:%d;2006:0" % (host, port)}}


def map_config():
    """Map tiles for the app's real map (flutter_map). Server-configured so the
    provider / key can change without an app release. EMPTY url = the app
    falls back to its tile-free route canvas. Never tile.openstreetmap.org in
    production (OSMF tile usage policy forbids app traffic)."""
    url = str(getattr(settings, "MAP_TILE_URL", "") or "")
    if "tile.openstreetmap.org" in url:
        url = ""
    return {"tile_url": url,
            "attribution": str(getattr(settings, "MAP_TILE_ATTRIBUTION", "")
                               or "© OpenStreetMap contributors"),
            "max_zoom": int(getattr(settings, "MAP_TILE_MAX_ZOOM", 19) or 19),
            "user_agent_package": "com.assisto.app"}


# --------------------------------------------------------------- config

class VehicleConfigView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        cfg = VS.vcfg()
        return R({"month_credits": VS.month_credits(),
                  "cutoff_max_speed_kmh": cfg["cutoff_max_speed_kmh"],
                  "cutoff_max_fix_age_s": cfg["cutoff_max_fix_age_s"],
                  "pair_window_min": cfg["pair_window_min"],
                  "retention_days": cfg["retention_days"],
                  "moving_interval_s": cfg["moving_interval_s"],
                  "parked_interval_s": cfg["parked_interval_s"],
                  "server": _server_info(),
                  "map": map_config(),
                  "transport_note": "plain_tcp_device_leg"})


# --------------------------------------------------------------- list / pair

class TrackerListView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import VehicleTracker
        now = timezone.now()
        cfg = VS.vcfg()
        own = list(VehicleTracker.objects.filter(owner=request.user)
                   .select_related("vehicle_record"))
        shared = []
        for t in VehicleTracker.objects.filter(grants__grantee=request.user) \
                .select_related("owner", "vehicle_record").distinct():
            acc = access_for(request.user, t)
            if acc["view"]:
                shared.append((t, acc))
        full = {"view": True, "command": True, "manage": True, "user": request.user}
        return R({"trackers": [_tracker_json(t, full, now, cfg) for t in own] +
                  [_tracker_json(t, a, now, cfg) for t, a in shared],
                  "month_credits": VS.month_credits()})

    def post(self, request):
        from .models import VehicleTracker, PaCollectionItem
        d = request.data or {}
        imei = VS.normalize_imei(d.get("imei"))
        if not VS.imei_valid(imei, d.get("protocol")):
            return R({"reason": "bad_imei", "ok": False}, status=400)
        now = timezone.now()
        cfg = VS.vcfg()
        existing = VehicleTracker.objects.filter(imei=imei).first()
        if existing is not None and existing.owner_id != request.user.id:
            VS.audit(existing, "pair_conflict", actor=request.user)
            return R({"reason": "imei_taken", "ok": False}, status=409)
        rec = None
        if d.get("vehicle_record_id"):
            rec = PaCollectionItem.objects.filter(
                pk=d.get("vehicle_record_id"), user=request.user,
                collection="vehicle/records").first()
            if rec is None:
                return R({"reason": "bad_vehicle", "ok": False}, status=400)
        if existing is None and VehicleTracker.objects.filter(
                owner=request.user).count() >= MAX_TRACKERS_PER_USER:
            return R({"reason": "too_many", "ok": False}, status=400)
        need = VS.month_credits()
        paid_through = existing and existing.billed_until and existing.billed_until > now
        if need > 0 and not paid_through and int(request.user.ai_credits or 0) < need:
            return R({"reason": "no_credits", "ok": False, "need": need,
                      "balance": int(request.user.ai_credits or 0)}, status=402)
        proto = d.get("protocol") if d.get("protocol") in ("gt06", "h02", "teltonika",
                                                            "tk103") \
            else "auto"
        t = existing or VehicleTracker(owner=request.user, imei=imei)
        t.name = str(d.get("name") or t.name or "")[:80]
        t.vehicle_record = rec or t.vehicle_record
        t.protocol = proto if existing is None or proto != "auto" else t.protocol
        if t.state != "paired":
            t.state = "pending"
            t.disabled_reason = ""
            t.pair_expires_at = now + timedelta(minutes=cfg["pair_window_min"])
        if existing is None:
            t.moving_interval_s = cfg["moving_interval_s"]
            t.parked_interval_s = cfg["parked_interval_s"]
        t.save()
        VS.audit(t, "pair_requested", actor=request.user)
        full = {"view": True, "command": True, "manage": True, "user": request.user}
        return R({"ok": True, "tracker": _tracker_json(t, full, now, cfg),
                  "server": _server_info(), "month_credits": need},
                 status=201 if existing is None else 200)


class TrackerDetailView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        return R(_tracker_json(t, acc, timezone.now(), VS.vcfg()))

    def patch(self, request, pk):
        from .models import CircleMember, PaCollectionItem
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        d = request.data or {}
        cfg = VS.vcfg()
        from .logic.pricing import _VEHICLE_BOUNDS as B
        changed_interval = False
        if "name" in d:
            t.name = str(d["name"] or "")[:80]
        if "speed_limit_kmh" in d:
            try:
                v = int(d["speed_limit_kmh"])
            except (TypeError, ValueError):
                return R({"reason": "bad_speed", "ok": False}, status=400)
            if not 0 <= v <= 200:
                return R({"reason": "bad_speed", "ok": False}, status=400)
            t.speed_limit_kmh = v
        if "night_ignition_alert" in d:
            t.night_ignition_alert = bool(d["night_ignition_alert"])
        for k in ("night_start", "night_end"):
            if k in d:
                if not HHMM.match(str(d[k])):
                    return R({"reason": "bad_time", "ok": False}, status=400)
                setattr(t, k, str(d[k]))
        for k, ck in (("moving_interval_s", "moving_interval_s"),
                      ("parked_interval_s", "parked_interval_s")):
            if k in d:
                try:
                    v = int(d[k])
                except (TypeError, ValueError):
                    return R({"reason": "bad_interval", "ok": False}, status=400)
                lo, hi = B[ck]
                if not lo <= v <= hi:
                    return R({"reason": "bad_interval", "ok": False}, status=400)
                if getattr(t, k) != v:
                    setattr(t, k, v)
                    changed_interval = True
        if "geofences" in d:
            fences = d["geofences"]
            if not isinstance(fences, list) or len(fences) > MAX_GEOFENCES:
                return R({"reason": "bad_geofence", "ok": False}, status=400)
            clean = []
            for i, f in enumerate(fences):
                c = _clean_fence(f, i)
                if c is None:
                    return R({"reason": "bad_geofence", "ok": False}, status=400)
                clean.append(c)
            t.geofences = clean + VS.split_fences(t.geofences)[1]
        if "routes" in d:
            routes, bad = _clean_routes(d["routes"])
            if bad:
                return R({"reason": "bad_route", "ok": False}, status=400)
            t.geofences = VS.split_fences(t.geofences)[0] + routes
        if "alert_prefs" in d:
            ap = d["alert_prefs"]
            if not isinstance(ap, dict):
                return R({"reason": "bad_prefs", "ok": False}, status=400)
            for k in ("quiet_start", "quiet_end"):
                if ap.get(k) not in (None, "") and not HHMM.match(str(ap[k])):
                    return R({"reason": "bad_time", "ok": False}, status=400)
            merged = dict(t.alert_prefs or {})
            merged.update({k: ap[k] for k in VS.PREF_DEFAULTS if k in ap})
            t.alert_prefs = merged
            t.alert_prefs = VS.alert_prefs(t)        # bounded + normalized
        if "odometer_km" in d:
            try:
                v = float(d["odometer_km"])
            except (TypeError, ValueError):
                return R({"reason": "bad_odometer", "ok": False}, status=400)
            if not 0 <= v <= 2000000:
                return R({"reason": "bad_odometer", "ok": False}, status=400)
            t.odometer_base_km = round(v, 1)
            t.odometer_base_m = t.odometer_m or 0
        if "cutoff_requires_approval" in d:
            t.cutoff_requires_approval = bool(d["cutoff_requires_approval"])
        if "approver_member_id" in d:
            mid = d["approver_member_id"]
            if mid in (None, "", 0):
                t.approver = None
            else:
                m = CircleMember.objects.filter(pk=mid, user=request.user,
                                                state="accepted", blocked=False,
                                                peer_user__isnull=False).first()
                if m is None:
                    return R({"reason": "bad_approver", "ok": False}, status=400)
                t.approver = m
        if t.cutoff_requires_approval and t.approver is None:
            return R({"reason": "approver_required", "ok": False}, status=400)
        if "vehicle_record_id" in d:
            vid = d["vehicle_record_id"]
            if vid in (None, "", 0):
                t.vehicle_record = None
            else:
                rec = PaCollectionItem.objects.filter(
                    pk=vid, user=request.user, collection="vehicle/records").first()
                if rec is None:
                    return R({"reason": "bad_vehicle", "ok": False}, status=400)
                t.vehicle_record = rec
        if "enabled" in d:
            if not bool(d["enabled"]) and t.state == "paired":
                t.state, t.disabled_reason = "disabled", "owner"
            elif bool(d["enabled"]) and t.state == "disabled" \
                    and t.disabled_reason == "owner":
                t.state, t.disabled_reason = "paired", ""
        t.save()
        if changed_interval and t.state == "paired":
            VS.queue_interval(t, actor=request.user)
        VS.audit(t, "settings_changed", actor=request.user,
                 keys=sorted(k for k in d.keys())[:20])
        return R(_tracker_json(t, acc, timezone.now(), cfg))

    def delete(self, request, pk):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        imei = t.imei
        t.delete()
        VS.audit(None, "tracker_removed", actor=request.user, imei=imei)
        return R({"ok": True})


MAX_POLY_POINTS = 50


def _clean_fence(f, i):
    """A circle {lat, lng, radius_m} or (veh100) a polygon {points:[[lat,lng]..]}
    with 3-50 vertices; optional alert 'both' | 'enter' | 'exit'. None = bad."""
    if not isinstance(f, dict):
        return None
    alert = f.get("alert") if f.get("alert") in ("both", "enter", "exit") else "both"
    base = {"id": str(f.get("id") or i + 1)[:12], "name": str(f.get("name") or "")[:40],
            "alert": alert}
    pts = f.get("points")
    if pts is not None:
        if not isinstance(pts, list) or not 3 <= len(pts) <= MAX_POLY_POINTS:
            return None
        clean = []
        for p in pts:
            try:
                lat, lng = (float(p[0]), float(p[1])) if isinstance(p, (list, tuple)) \
                    else (float(p["lat"]), float(p["lng"]))
            except (KeyError, TypeError, ValueError, IndexError):
                return None
            if not (-90 <= lat <= 90 and -180 <= lng <= 180):
                return None
            clean.append([round(lat, 6), round(lng, 6)])
        lats = [p[0] for p in clean]
        lngs = [p[1] for p in clean]
        # centre + rough radius so the old app / list view can still draw it
        clat, clng = sum(lats) / len(lats), sum(lngs) / len(lngs)
        rad = max(VT.haversine_m(clat, clng, p[0], p[1]) for p in clean)
        if rad > 50000 or rad < 20:
            return None
        return {**base, "type": "polygon", "points": clean, "lat": round(clat, 6),
                "lng": round(clng, 6), "radius_m": int(rad)}
    try:
        lat, lng = float(f["lat"]), float(f["lng"])
        rad = int(f.get("radius_m") or 300)
    except (KeyError, TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lng <= 180 and 50 <= rad <= 50000):
        return None
    return {**base, "lat": lat, "lng": lng, "radius_m": rad}


def _clean_routes(raw):
    """Planned routes for off-route / long-stop alerts. Stored inside the
    geofences JSON as {"type": "route", ...} (no extra column / migration).
    Returns (routes, bad)."""
    if not isinstance(raw, list) or len(raw) > MAX_ROUTES:
        return [], True
    out = []
    for i, r in enumerate(raw):
        if not isinstance(r, dict):
            return [], True
        pts = r.get("points")
        if not isinstance(pts, list) or not 2 <= len(pts) <= MAX_ROUTE_POINTS:
            return [], True
        clean_pts = []
        for p in pts:
            try:
                lat, lng = (float(p[0]), float(p[1])) if isinstance(p, (list, tuple)) \
                    else (float(p["lat"]), float(p["lng"]))
            except (KeyError, TypeError, ValueError, IndexError):
                return [], True
            if not (-90 <= lat <= 90 and -180 <= lng <= 180):
                return [], True
            clean_pts.append([round(lat, 6), round(lng, 6)])
        try:
            corridor = int(r.get("corridor_m") or 300)
            stop_min = int(r.get("stop_alert_min") or 0)
        except (TypeError, ValueError):
            return [], True
        if not (50 <= corridor <= 5000 and 0 <= stop_min <= 720):
            return [], True
        out.append({"type": "route", "id": str(r.get("id") or "r%d" % (i + 1))[:12],
                    "name": str(r.get("name") or "")[:40], "points": clean_pts,
                    "corridor_m": corridor, "stop_alert_min": stop_min})
    return out, False


# --------------------------------------------------------------- history

def _positions(t, hours):
    from .models import VehiclePosition
    since = timezone.now() - timedelta(hours=hours)
    return [{"at": p.at, "lat": p.lat, "lng": p.lng, "speed_kmh": p.speed_kmh,
             "ignition": p.ignition, "valid": True,
             "local_hour": p.at.astimezone(VS.LOCAL_TZ).hour}
            for p in VehiclePosition.objects.filter(tracker=t, at__gte=since)
            .order_by("at")[:50000]]


def _night(t):
    return (VT._parse_hhmm(t.night_start, 23), VT._parse_hhmm(t.night_end, 5))


def _summary_json(s):
    def tj(x):
        return {k: (_iso(v) if hasattr(v, "isoformat") else v) for k, v in x.items()}
    return {"trips": [tj(x) for x in s["trips"]], "stops": [tj(x) for x in s["stops"]],
            "total_km": s["total_km"], "moving_s": s["moving_s"],
            "max_speed_kmh": s["max_speed_kmh"], "point_count": s["points"]}


def _hours(request, default=24, cap=24 * 7):
    try:
        return max(1, min(cap, int(request.query_params.get("hours", default))))
    except (TypeError, ValueError):
        return default


class TrackerRouteView(APIView):
    """24 h (default) route for playback + server-side trips / stops / mileage."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        pts = _positions(t, _hours(request))
        summary = VT.compute_trips(pts, night=_night(t))
        route = VT.downsample(pts, 800)
        return R({"points": [{"at": _iso(p["at"]), "lat": p["lat"], "lng": p["lng"],
                              "speed_kmh": p["speed_kmh"]} for p in route],
                  **_summary_json(summary)})


class TrackerTripsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        pts = _positions(t, _hours(request, 24, 24 * 31))
        return R(_summary_json(VT.compute_trips(pts, night=_night(t))))


# --------------------------------------------------------------- commands

def _verify_requester_pin(request):
    """The requester's OWN Security PIN (reuses the Section-8 PIN + lockout)."""
    from .views_security import _primary_phone, _verify_pin, _register_lockout
    phone = _primary_phone(request.user)
    if not phone.security_pin_hash:
        return R({"reason": "no_pin", "ok": False}, status=403)
    ok, locked = _verify_pin(phone, request.data.get("pin"))
    if ok:
        return None
    if locked:
        _register_lockout(request.user, phone)
        return R({"reason": "locked", "ok": False, "locked": True}, status=403)
    return R({"reason": "bad_pin", "ok": False}, status=403)


def _cutoff_gate(t, now, cfg):
    """Engine cut is allowed only when the tracker is online, the latest fix is
    fresh, the vehicle is under the crawl speed AND (veh100) the last
    VT.STOPPED_FIXES stored fixes were ALL stopped — never while moving."""
    from .models import VehiclePosition
    online = VT.is_online(t.last_seen_at, now, cfg["online_window_s"])
    ok, reason = VT.decide_cutoff(t.last_fix_at, t.last_speed_kmh, now,
                                  cfg["cutoff_max_speed_kmh"], cfg["cutoff_max_fix_age_s"],
                                  online=online)
    if not ok:
        return ok, reason
    recent = [{"at": p.at, "speed_kmh": p.speed_kmh} for p in
              VehiclePosition.objects.filter(tracker=t).order_by("-at")[:VT.STOPPED_FIXES]]
    return VT.stopped_for(recent, now, VT.STOPPED_FIXES, cfg["cutoff_max_speed_kmh"],
                          cfg["cutoff_max_fix_age_s"])


CONFIRM_WITHIN_S = 60


def _confirm_hash(token):
    import hashlib
    return hashlib.sha256(str(token or "").encode()).hexdigest()


class TrackerCommandView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        rows = []
        for c in t.commands.exclude(kind="set_interval")[:30]:
            j = _cmd_json(c)
            j["requested_by_me"] = c.requested_by_id == request.user.id
            rows.append(j)
        return R({"commands": rows})

    def post(self, request, pk):
        from .models import VehicleCommand
        t, acc, err = _load(request, pk, "command")
        if err:
            return err
        kind = str((request.data or {}).get("kind") or "")
        if kind not in ("engine_cut", "engine_restore"):
            return R({"reason": "bad_kind", "ok": False}, status=400)
        if kind == "engine_cut" and not engine_cut_on(request.user):
            VS.audit(t, "command_denied", actor=request.user, kind=kind,
                     reason="feature_off")
            return R({"reason": "feature_off", "ok": False}, status=403)
        if t.state != "paired":
            return R({"reason": "not_paired", "ok": False}, status=409)
        bad = _verify_requester_pin(request)
        if bad is not None:
            VS.audit(t, "command_denied", actor=request.user, kind=kind,
                     reason=bad.data.get("reason"))
            return bad
        now = timezone.now()
        cfg = VS.vcfg()
        ok, reason = _cutoff_gate(t, now, cfg) if kind == "engine_cut" else (True, "ok")
        if not ok:
            VS.audit(t, "command_denied", actor=request.user, kind=kind, reason=reason,
                     speed=t.last_speed_kmh, fix_at=t.last_fix_at)
            return R({"reason": reason, "ok": False,
                      "max_speed_kmh": cfg["cutoff_max_speed_kmh"],
                      "max_fix_age_s": cfg["cutoff_max_fix_age_s"]}, status=409)
        # an unconfirmed engine-cut that timed out never blocks a new request
        t.commands.filter(state="awaiting_confirm",
                          created_at__lt=now - timedelta(seconds=CONFIRM_WITHIN_S)) \
            .update(state="expired", done_at=now)
        if t.commands.filter(kind__in=["engine_cut", "engine_restore"],
                             state__in=["awaiting_confirm", "awaiting_approval",
                                        "queued", "sent"]).exists():
            return R({"reason": "busy", "ok": False}, status=409)
        payload = {"speed_kmh": t.last_speed_kmh,
                   "fix_age_s": int((now - t.last_fix_at).total_seconds())
                   if t.last_fix_at else None}
        if kind == "engine_cut":
            # veh100: a SECOND, separate confirmation (fresh token, 60 s) —
            # the gate is checked again at confirm time.
            import secrets
            token = secrets.token_urlsafe(16)
            c = VehicleCommand.objects.create(
                tracker=t, kind=kind, requested_by=request.user,
                state="awaiting_confirm", confirm_hash=_confirm_hash(token),
                payload=payload)
            VS.audit(t, "command_requested", actor=request.user, kind=kind,
                     command_id=c.id, state=c.state)
            return R({"ok": True, "command": _cmd_json(c), "confirm_token": token,
                      "confirm_within_s": CONFIRM_WITHIN_S}, status=202)
        c = VehicleCommand.objects.create(tracker=t, kind=kind, requested_by=request.user,
                                          state="queued", payload=payload)
        VS.audit(t, "command_requested", actor=request.user, kind=kind,
                 command_id=c.id, state=c.state)
        return R({"ok": True, "command": _cmd_json(c)}, status=201)


class CommandConfirmView(APIView):
    """veh100: the second confirmation of an engine cut. Only the requester,
    within CONFIRM_WITHIN_S, with the one-time token; the stopped-only gate
    runs AGAIN here (the car may have started moving in between)."""
    permission_classes = [IsAuthenticated]

    def post(self, request, cid):
        from .models import VehicleCommand
        c = VehicleCommand.objects.filter(pk=cid).select_related(
            "tracker", "tracker__approver", "tracker__owner").first()
        if c is None or c.requested_by_id != request.user.id:
            return R({"reason": "not_found", "ok": False}, status=404)
        t = c.tracker
        if not access_for(request.user, t)["command"]:
            return R({"reason": "not_found", "ok": False}, status=404)
        if c.state != "awaiting_confirm":
            return R({"reason": "not_pending", "ok": False, "state": c.state}, status=409)
        now = timezone.now()
        if (now - c.created_at).total_seconds() > CONFIRM_WITHIN_S:
            c.state, c.done_at = "expired", now
            c.save(update_fields=["state", "done_at"])
            VS.audit(t, "command_expired", actor=request.user, command_id=c.id,
                     reason="confirm_timeout")
            return R({"reason": "confirm_timeout", "ok": False}, status=409)
        import hmac
        if not hmac.compare_digest(c.confirm_hash or "x",
                                   _confirm_hash((request.data or {}).get("confirm_token"))):
            VS.audit(t, "command_denied", actor=request.user, command_id=c.id,
                     reason="bad_confirm")
            return R({"reason": "bad_confirm", "ok": False}, status=403)
        if not engine_cut_on(request.user):
            return R({"reason": "feature_off", "ok": False}, status=403)
        cfg = VS.vcfg()
        ok, reason = _cutoff_gate(t, now, cfg)
        if not ok:
            c.state, c.done_at, c.fail_reason = "cancelled", now, reason[:24]
            c.save(update_fields=["state", "done_at", "fail_reason"])
            VS.audit(t, "command_denied", actor=request.user, command_id=c.id,
                     reason=reason, speed=t.last_speed_kmh, fix_at=t.last_fix_at)
            return R({"reason": reason, "ok": False,
                      "max_speed_kmh": cfg["cutoff_max_speed_kmh"],
                      "max_fix_age_s": cfg["cutoff_max_fix_age_s"]}, status=409)
        approver_user = t.approver.peer_user if t.approver_id else None
        needs_ok = (t.cutoff_requires_approval and approver_user is not None
                    and approver_user.id != request.user.id)
        c.state = "awaiting_approval" if needs_ok else "queued"
        c.confirm_hash = ""
        c.save(update_fields=["state", "confirm_hash"])
        VS.audit(t, "command_confirmed", actor=request.user, command_id=c.id,
                 state=c.state)
        if needs_ok:
            VS.notify_approval_needed(c, approver_user)
        return R({"ok": True, "command": _cmd_json(c)}, status=201)


class CommandApproveView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, cid):
        from .models import VehicleCommand
        c = VehicleCommand.objects.filter(pk=cid).select_related(
            "tracker", "tracker__approver", "tracker__owner").first()
        if c is None:
            return R({"reason": "not_found", "ok": False}, status=404)
        t = c.tracker
        appr = t.approver.peer_user_id if t.approver_id else None
        if appr is None or appr != request.user.id:
            return R({"reason": "not_found", "ok": False}, status=404)
        if c.state != "awaiting_approval":
            return R({"reason": "not_pending", "ok": False, "state": c.state}, status=409)
        if not engine_cut_on(request.user) and not engine_cut_on(c.requested_by):
            return R({"reason": "feature_off", "ok": False}, status=403)
        bad = _verify_requester_pin(request)
        if bad is not None:
            return bad
        now = timezone.now()
        ok, reason = _cutoff_gate(t, now, VS.vcfg())
        if not ok:
            VS.audit(t, "approval_denied", actor=request.user, command_id=c.id,
                     reason=reason)
            return R({"reason": reason, "ok": False}, status=409)
        c.state, c.approved_by = "queued", request.user
        c.save(update_fields=["state", "approved_by"])
        VS.audit(t, "command_approved", actor=request.user, command_id=c.id)
        return R({"ok": True, "command": _cmd_json(c)})


class CommandCancelView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, cid):
        from .models import VehicleCommand
        c = VehicleCommand.objects.filter(pk=cid).select_related("tracker").first()
        if c is None:
            return R({"reason": "not_found", "ok": False}, status=404)
        t = c.tracker
        acc = access_for(request.user, t)
        appr = t.approver.peer_user_id if t.approver_id else None
        if not (acc["manage"] or c.requested_by_id == request.user.id
                or appr == request.user.id):
            return R({"reason": "not_found", "ok": False}, status=404)
        if c.state not in ("awaiting_confirm", "awaiting_approval", "queued"):
            return R({"reason": "too_late", "ok": False, "state": c.state}, status=409)
        c.state = "rejected" if (appr == request.user.id and
                                 c.state == "awaiting_approval") else "cancelled"
        c.done_at = timezone.now()
        c.save(update_fields=["state", "done_at"])
        VS.audit(t, "command_" + c.state, actor=request.user, command_id=c.id)
        return R({"ok": True, "command": _cmd_json(c)})


class TrackerAuditView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        return R({"audit": [{"action": a.action, "at": _iso(a.at),
                             "actor_id": a.actor_id, "detail": a.detail}
                            for a in t.audit.all()[:100]]})


# --------------------------------------------------------------- grants

class TrackerGrantsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        return R({"grants": [{"id": g.id, "kind": g.kind, "can_command": g.can_command,
                              "grantee_id": g.grantee_id,
                              "name": g.grantee.name if hasattr(g.grantee, "name") else "",
                              "valid": _grant_valid(g, t.owner)}
                             for g in t.grants.select_related("grantee")]})

    def post(self, request, pk):
        from .models import CircleMember, BusinessStaff, VehicleAccessGrant
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        d = request.data or {}
        kind = d.get("kind") if d.get("kind") in ("family", "fleet") else "family"
        grantee = None
        if kind == "family":
            m = CircleMember.objects.filter(pk=d.get("member_id"), user=request.user,
                                            state="accepted", blocked=False,
                                            peer_user__isnull=False).first()
            grantee = m.peer_user if m else None
        else:
            from . import plans
            if plans.effective_plan(request.user) not in ("business", "founder"):
                return R({"reason": "business_only", "ok": False}, status=403)
            s = BusinessStaff.objects.filter(pk=d.get("staff_id"),
                                             business__user=request.user,
                                             active=True).first()
            grantee = s.member if s else None
        if grantee is None or grantee.id == request.user.id:
            return R({"reason": "bad_grantee", "ok": False}, status=400)
        g, _ = VehicleAccessGrant.objects.update_or_create(
            tracker=t, grantee=grantee,
            defaults={"kind": kind, "can_command": bool(d.get("can_command"))})
        VS.audit(t, "grant_added", actor=request.user, grantee_id=grantee.id,
                 kind=kind, can_command=g.can_command)
        return R({"ok": True, "id": g.id}, status=201)


class TrackerGrantDeleteView(APIView):
    permission_classes = [IsAuthenticated]

    def delete(self, request, pk, gid):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        n, _ = t.grants.filter(pk=gid).delete()
        VS.audit(t, "grant_removed", actor=request.user, grant_id=gid)
        return R({"ok": bool(n)})


# --------------------------------------------------------------- OBD

class TrackerObdView(APIView):
    """Latest OBD snapshot the 4G tracker reported (only on OBD-capable models)."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        obd = dict(t.obd or {})
        return R({"available": bool(obd), "obd": obd,
                  "battery_v": t.ext_voltage_v,
                  "dtc": obd_dtc.explain_all(obd.get("dtc") or [])})


class ObdDecodeView(APIView):
    """Plain-language meanings for DTCs read by the phone (ELM327 Bluetooth)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        codes = (request.data or {}).get("codes") or []
        if not isinstance(codes, list):
            return R({"reason": "bad_codes", "ok": False}, status=400)
        return R({"dtc": obd_dtc.explain_all(codes[:50])})


# --------------------------------------------------------------- AI summary

class TrackerAiSummaryView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        lang = (request.data or {}).get("lang") or getattr(request.user, "language", "bn")
        lang = "en" if lang == "en" else "bn"
        summary = VT.compute_trips(_positions(t, 24), night=_night(t))
        facts = VT.unusual_trip_facts(summary, t.speed_limit_kmh)
        rule = VT.rule_summary(summary, facts, lang)
        base = {"facts": [{k: (_iso(v) if hasattr(v, "isoformat") else v)
                           for k, v in f.items()} for f in facts],
                "rule_summary": rule, "total_km": summary["total_km"],
                "trips": len(summary["trips"])}
        if not facts:
            return R({**base, "ai": False, "reason": "nothing_unusual", "text": rule})
        from . import ai
        task = ("Summarise this vehicle's unusual trips for its owner in %s, in 2-3 "
                "short sentences. Facts only. Never accuse anyone; say 'please check'."
                % ("Bangla" if lang == "bn" else "English"))
        try:
            text, _cost = ai.generate(task, data=json.dumps(base["facts"])[:4000],
                                      tier="cheap", max_tokens=250,
                                      feature="vehicle_summary", user=request.user)
            from . import ai_guard
            if ai_guard.accusations(text):
                # aieval: never accuse anyone — the factual rule summary instead
                return R({**base, "ai": False, "reason": "guard", "text": rule})
            return R({**base, "ai": True, "text": text})
        except ai.AIUnavailable as e:
            return R({**base, "ai": False, "reason": e.reason, "text": rule})


# --------------------------------------------------------------- Car Mode trip

class CarModeTripView(APIView):
    """A trip logged by the Android head unit's own GPS while Car Mode was open.
    Stored in the generic per-user collection 'vehicle/trips'."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from datetime import datetime, timezone as dt_timezone
        from .models import PaCollectionItem
        d = request.data or {}
        raw = d.get("points")
        if not isinstance(raw, list) or not raw or len(raw) > MAX_CARMODE_POINTS:
            return R({"reason": "bad_points", "ok": False}, status=400)
        pts = []
        for p in raw:
            try:
                at = datetime.fromisoformat(str(p["at"]).replace("Z", "+00:00"))
                if at.tzinfo is None:
                    at = at.replace(tzinfo=dt_timezone.utc)
                pts.append({"at": at, "lat": float(p["lat"]), "lng": float(p["lng"]),
                            "speed_kmh": float(p.get("speed_kmh") or 0), "valid": True,
                            "local_hour": at.astimezone(VS.LOCAL_TZ).hour})
            except (KeyError, TypeError, ValueError):
                return R({"reason": "bad_points", "ok": False}, status=400)
        vid = d.get("vehicle_record_id")
        if vid and not PaCollectionItem.objects.filter(
                pk=vid, user=request.user, collection="vehicle/records").exists():
            return R({"reason": "bad_vehicle", "ok": False}, status=400)
        s = _summary_json(VT.compute_trips(pts, night=(23, 5)))
        # Same alert engine as the hardware tracker, replayed over the phone's
        # trip (the app shows these live on screen; this is the server record).
        alerts = []
        try:
            limit = max(0, min(200, int(d.get("speed_limit_kmh") or 0)))
        except (TypeError, ValueError):
            limit = 0
        routes = []
        if d.get("route"):
            routes, bad = _clean_routes([d["route"]])
            if bad:
                return R({"reason": "bad_route", "ok": False}, status=400)
        if limit or routes:
            st = {}
            cfg = {"speed_limit_kmh": limit, "night_ignition": False,
                   "geofences": [], "routes": routes}
            for p in sorted(pts, key=lambda x: x["at"]):
                st, al = VT.evaluate_alerts(st, p, cfg, p["local_hour"])
                alerts.extend({k: (_iso(v) if hasattr(v, "isoformat") else v)
                               for k, v in a.items()} | {"at": _iso(p["at"])}
                              for a in al)
        item = PaCollectionItem.objects.create(
            user=request.user, collection="vehicle/trips",
            data={"source": "headunit", "vehicle_record_id": vid or None,
                  "start": _iso(pts[0]["at"]), "end": _iso(pts[-1]["at"]),
                  "total_km": s["total_km"], "moving_s": s["moving_s"],
                  "max_speed_kmh": s["max_speed_kmh"], "trips": len(s["trips"]),
                  "alerts": [a["kind"] for a in alerts][:50]})
        return R({"ok": True, "id": item.id, **s, "alerts": alerts[:50]}, status=201)


# --------------------------------------------------------------- fleet

class FleetDashboardView(APIView):
    """Business-plan fleet view: every owned tracker + fleet grants."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from . import plans
        from .models import VehicleTracker, VehiclePosition, VehicleAuditLog
        if plans.effective_plan(request.user) not in ("business", "founder"):
            return R({"reason": "business_only", "ok": False}, status=403)
        now = timezone.now()
        cfg = VS.vcfg()
        local_midnight = now.astimezone(VS.LOCAL_TZ).replace(
            hour=0, minute=0, second=0, microsecond=0)
        rows = []
        cand = list(VehicleTracker.objects.filter(owner=request.user)[:100])
        for t in VehicleTracker.objects.filter(grants__grantee=request.user,
                                               grants__kind="fleet").distinct()[:100]:
            if access_for(request.user, t)["view"]:
                cand.append(t)
        totals = {"vehicles": 0, "online": 0, "moving": 0, "km_today": 0.0,
                  "alerts_today": 0}
        for t in cand:
            acc = access_for(request.user, t)
            j = _tracker_json(t, acc, now, cfg)
            pts = [{"at": p.at, "lat": p.lat, "lng": p.lng, "speed_kmh": p.speed_kmh}
                   for p in VehiclePosition.objects.filter(tracker=t, at__gte=local_midnight)
                   .order_by("at")[:20000]]
            km = VT.compute_trips(pts)["total_km"]
            alerts = VehicleAuditLog.objects.filter(
                tracker=t, action__startswith="alert_", at__gte=local_midnight).count()
            j.update(km_today=km, alerts_today=alerts)
            rows.append(j)
            totals["vehicles"] += 1
            totals["online"] += 1 if j["online"] else 0
            totals["moving"] += 1 if (j["live"] or {}).get("moving") else 0
            totals["km_today"] = round(totals["km_today"] + km, 2)
            totals["alerts_today"] += alerts
        return R({"ok": True, "totals": totals, "vehicles": rows,
                  "month_credits": VS.month_credits()})
