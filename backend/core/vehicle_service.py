"""
vehicle_service.py — the Django/ORM side of vehicle tracking (v1-vehicle).

Called by BOTH the standalone tracker daemon (backend/tracker/server.py, from
its single DB worker thread) and the HTTP views (core/views_vehicle.py). Every
function here is synchronous ORM code; the daemon never touches the ORM from
its event loop directly.

Honesty rules baked in:
  * a command is only 'acked' when the DEVICE replied success;
  * 'sent' without a reply inside command_timeout_s becomes 'failed'
    (reason 'no_reply') — we never pretend the relay moved;
  * unknown IMEIs are refused and logged (rate-limited log rows).
"""
import secrets
from datetime import timedelta
from zoneinfo import ZoneInfo

from django.db import transaction
from django.utils import timezone

from .logic import vehicle_tracking as VT

LOCAL_TZ = ZoneInfo("Asia/Dhaka")
BILLING_PERIOD_DAYS = 30


def vcfg():
    from . import billing
    from .logic import pricing
    try:
        return pricing.vehicle_cfg(billing.cfg())
    except Exception:
        return pricing.vehicle_cfg({})


def month_credits():
    from . import billing
    from .logic import pricing
    try:
        return pricing.credits_for("vehicle_tracking_month", 1, billing.cfg())
    except Exception:
        return 0


def audit(tracker, action, actor=None, imei="", **detail):
    from .models import VehicleAuditLog
    try:
        VehicleAuditLog.objects.create(
            tracker=tracker, actor=actor, action=action[:32],
            imei=(imei or (tracker.imei if tracker else ""))[:20],
            detail={k: (v.isoformat() if hasattr(v, "isoformat") else v)
                    for k, v in detail.items()})
    except Exception:
        pass


def normalize_imei(raw):
    return "".join(ch for ch in str(raw or "") if ch.isdigit())


def imei_valid(imei, protocol=None):
    """15-digit IMEI with a correct Luhn check digit. H02 trackers (Sinotrack
    ST-901 family) report a 10-digit DEVICE ID instead (printed on the label /
    returned by SMS), so for protocol 'h02' any 10-15 digit id is accepted."""
    if protocol == "h02" and imei.isdigit() and 10 <= len(imei) <= 15 \
            and len(imei) != 15:
        return True
    if len(imei) != 15 or not imei.isdigit():
        return False
    total = 0
    for i, ch in enumerate(imei):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


# --------------------------------------------------------------- billing

def charge_month(tracker, now=None):
    """Debit one month of vehicle_tracking_month credits; extend billed_until.
    Returns True on success (or when the action is priced at 0)."""
    from . import shop_views as SV
    now = now or timezone.now()
    need = month_credits()
    if need > 0:
        got = SV._debit_camera_credits(tracker.owner, need,
                                       note="vehicle_tracking_month")
        if got < need:
            return False
    base = tracker.billed_until if (tracker.billed_until and
                                    tracker.billed_until > now) else now
    tracker.billed_until = base + timedelta(days=BILLING_PERIOD_DAYS)
    tracker.save(update_fields=["billed_until", "updated_at"])
    return True


# --------------------------------------------------------------- connect / pair

_unknown_logged = {}     # imei -> last log time (in-process rate limit)
UNKNOWN_LOG_EVERY_S = 600


def on_device_connect(imei, protocol, remote="", now=None):
    """Decide whether a connecting device may talk to us.

    Returns (tracker_id or None, reason). reason in
      'paired'            known, paired, enabled
      'newly_paired'      pending + connected inside the pairing window
      'unknown'           no such IMEI (refused, logged)
      'expired'           pending but the window passed (refused)
      'disabled'          owner turned it off / unpaid (refused)
    """
    from .models import VehicleTracker
    now = now or timezone.now()
    imei = normalize_imei(imei)
    t = VehicleTracker.objects.filter(imei=imei).select_related("owner").first()
    if t is None:
        t = _alias_match(imei, now)
        if t is not None:
            audit(t, "imei_alias_matched", remote=remote, reported=imei,
                  protocol=protocol)
            t.imei = imei                     # the id the device really sends
            t.save(update_fields=["imei", "updated_at"])
    if t is None:
        last = _unknown_logged.get(imei)
        if last is None or (now - last).total_seconds() >= UNKNOWN_LOG_EVERY_S:
            _unknown_logged[imei] = now
            if len(_unknown_logged) > 5000:
                _unknown_logged.clear()
            audit(None, "unknown_imei", imei=imei, remote=remote, protocol=protocol)
        return None, "unknown"
    if t.state == "disabled":
        audit(t, "refused_disabled", remote=remote)
        return None, "disabled"
    if t.state in ("pending", "expired"):
        if t.pair_expires_at is None or now > t.pair_expires_at:
            if t.state != "expired":
                t.state = "expired"
                t.save(update_fields=["state", "updated_at"])
            audit(t, "refused_pair_expired", remote=remote)
            return None, "expired"
        with transaction.atomic():
            t.state = "paired"
            t.paired_at = now
            if t.protocol == "auto":
                t.protocol = protocol
            t.save(update_fields=["state", "paired_at", "protocol", "updated_at"])
        if not charge_month(t, now):
            t.state = "disabled"
            t.disabled_reason = "no_credits"
            t.save(update_fields=["state", "disabled_reason", "updated_at"])
            audit(t, "pair_no_credits", remote=remote)
            _notify_owner(t, "pair_no_credits")
            return None, "disabled"
        audit(t, "paired", remote=remote, protocol=protocol)
        queue_interval(t)
        _notify_owner(t, "paired")
        return t.id, "newly_paired"
    if t.billed_until and t.billed_until < now:
        # renewal is the billing cron's job; a lapsed tracker is refused until paid
        audit(t, "refused_unpaid", remote=remote)
        return None, "disabled"
    return t.id, "paired"


def _alias_match(reported, now):
    """veh100 setup helper: Sinotrack / Coban labels print a 10-12 digit
    DEVICE ID while the box says a 15-digit IMEI (or the reverse). A device
    whose id is contained in (or contains) exactly ONE pending tracker's
    number, inside that tracker's pairing window, is that tracker. Never for
    paired / disabled trackers, never ambiguous, never under 10 digits."""
    from .models import VehicleTracker
    if not reported or len(reported) < 10:
        return None
    cands = [t for t in VehicleTracker.objects.filter(
        state="pending", pair_expires_at__gte=now).select_related("owner")[:500]
        if len(t.imei) >= 10 and t.imei != reported
        and (reported in t.imei or t.imei in reported)]
    if len(cands) != 1:
        return None
    if VehicleTracker.objects.filter(imei=reported).exists():
        return None
    return cands[0]


def touch(tracker_id, now=None):
    from .models import VehicleTracker
    VehicleTracker.objects.filter(pk=tracker_id).update(
        last_seen_at=now or timezone.now())


def queue_interval(tracker, actor=None):
    """Queue a set_interval command (moving/parked periods). Protocol support
    varies by model; the device reply is stored so failure is visible."""
    from .models import VehicleCommand
    VehicleCommand.objects.filter(tracker=tracker, kind="set_interval",
                                  state="queued").update(state="cancelled")
    return VehicleCommand.objects.create(
        tracker=tracker, kind="set_interval", state="queued",
        requested_by=actor,
        payload={"moving_s": tracker.moving_interval_s,
                 "parked_s": tracker.parked_interval_s})


# --------------------------------------------------------------- positions

def ingest(batch, now=None):
    """Persist a batch of fixes from the daemon.

    batch: {tracker_id: {"fixes": [fix...], "status": {...}|None}}
    One bulk_create for all positions, one live-state UPDATE per tracker, then
    alert evaluation on the new fixes. Returns number of positions written."""
    from .models import VehicleTracker, VehiclePosition
    now = now or timezone.now()
    rows = []
    trackers = {t.id: t for t in VehicleTracker.objects.filter(
        pk__in=list(batch.keys())).select_related("owner")}
    pending_alerts = []
    delivered = []
    for tid, item in batch.items():
        t = trackers.get(tid)
        if t is None:
            continue
        fixes = sorted(item.get("fixes") or [], key=lambda f: f["at"] or now)
        fields = {"last_seen_at": now}
        st = item.get("status") or {}
        if "ignition" in st:
            fields["ignition"] = st["ignition"]
        if "relay_cut" in st:
            fields["relay_cut"] = st["relay_cut"]
        for k in ("ext_voltage_v", "battery_v"):
            if st.get(k) is not None:
                fields[k] = st[k]
        alert_state = dict(t.alert_state or {})
        circles, routes = split_fences(t.geofences)
        prefs = alert_prefs(t)
        settings = {"speed_limit_kmh": t.speed_limit_kmh,
                    "night_start": t.night_start, "night_end": t.night_end,
                    "night_ignition": t.night_ignition_alert,
                    "geofences": circles, "routes": routes,
                    "ignition_on": prefs["ignition_on"],
                    "ignition_off": prefs["ignition_off"],
                    "stop_alert_min": prefs["stop_alert_min"]}
        odo_m = float(t.odometer_m or 0)
        last_pt = alert_state.get("odo_pt")      # [lat, lng, iso] of the last counted fix
        # Idempotency: a tracker that never got our ACK (or a flaky link)
        # re-sends the same fix. One fix per (tracker, device time): skip any
        # `at` already stored or already seen in this batch.
        ats = [f.get("at") for f in fixes if f.get("at") is not None]
        seen = set(VehiclePosition.objects.filter(tracker_id=tid, at__in=ats)
                   .values_list("at", flat=True)) if ats else set()
        for f in fixes:
            at = f.get("at") or now
            if at > now + timedelta(minutes=5):   # device clock in the future
                at = now
            if f.get("at") is not None and f.get("valid", True):
                if at in seen:
                    continue
                seen.add(at)
            ign = f.get("ignition")
            io = {}
            for k in ("ext_voltage_v", "battery_v", "relay_cut", "movement", "obd"):
                if f.get(k) is not None:
                    io[k] = f[k]
            if f.get("valid", True):
                rows.append(VehiclePosition(
                    tracker_id=tid, at=at, lat=f["lat"], lng=f["lng"],
                    speed_kmh=float(f.get("speed_kmh") or 0),
                    course=int(f.get("course") or 0), sats=int(f.get("sats") or 0),
                    valid=True, ignition=ign, io=io))
                if t.last_fix_at is None or at >= t.last_fix_at:
                    t.last_fix_at = at
                    fields.update(last_fix_at=at, last_lat=f["lat"], last_lng=f["lng"],
                                  last_speed_kmh=float(f.get("speed_kmh") or 0),
                                  last_course=int(f.get("course") or 0))
            if ign is not None:
                fields["ignition"] = ign
            for k in ("ext_voltage_v", "battery_v", "relay_cut"):
                if f.get(k) is not None:
                    fields[k] = f[k]
            if f.get("obd"):
                merged = dict(t.obd or {})
                merged.update(f["obd"])
                merged["at"] = at.isoformat()
                t.obd = merged
                fields["obd"] = merged
            local_hour = at.astimezone(LOCAL_TZ).hour
            alert_state, alerts = VT.evaluate_alerts(alert_state, f, settings,
                                                     local_hour)
            # veh100: device alarms (levels or events) + power signals
            alert_state, dev = VT.evaluate_device(
                alert_state, f.get("alarms") or (), {
                    "ext_voltage_v": f.get("ext_voltage_v"),
                    "battery_v": f.get("battery_v")})
            for a in alerts + dev:
                if a.get("lat") is None and f.get("valid", True):
                    a.update(lat=f.get("lat"), lng=f.get("lng"))
                pending_alerts.append((t, a, at))
            # veh100: server odometer (valid, jump-free, parked wander ignored)
            if f.get("valid", True) and f.get("lat") is not None:
                odo_m, last_pt = _odo_step(odo_m, last_pt, f, at)
        # status reports (GT06 heartbeat terminal-info bits, TK103 keyword
        # frames): their own alarm slot, so a GPS fix without alarm bits never
        # "clears" a heartbeat alarm (and re-alerts it on the next heartbeat).
        if "ignition" in st and st["ignition"] is not None and \
                not any(f.get("ignition") is not None for f in fixes):
            # ACC from a heartbeat / keyword frame (GT06 0x13, TK103 "acc on"):
            # same ignition rules as a fix, without a location.
            alert_state, alerts = VT.evaluate_alerts(
                alert_state, {"ignition": bool(st["ignition"]), "valid": False, "at": now},
                settings, now.astimezone(LOCAL_TZ).hour)
            for a in alerts:
                a.update(lat=t.last_lat, lng=t.last_lng)
                pending_alerts.append((t, a, now))
        if st:
            alert_state, dev = VT.evaluate_device(
                alert_state, st.get("alarms") or (), {
                    "ext_voltage_v": st.get("ext_voltage_v"),
                    "battery_v": st.get("battery_v"),
                    "voltage_level": st.get("voltage_level")}, slot="st_alarms")
            for a in dev:
                a.update(lat=t.last_lat, lng=t.last_lng)
                pending_alerts.append((t, a, now))
        if last_pt is not None:
            alert_state["odo_pt"] = last_pt
        alert_state.pop("silent_for", None)       # seen again: re-arm "silent"
        if odo_m != float(t.odometer_m or 0):
            fields["odometer_m"] = round(odo_m, 1)
        # caps / cooldown / quiet hours (pure gate; state kept in alert_state)
        gated = []
        cap = alert_state.get("cap")
        for (tt, a, a_at) in [x for x in pending_alerts if x[0] is t]:
            # cooldown on the EVENT time (a batch can hold minutes of fixes)
            decision, cap = VT.gate_alert(cap, a, min(a_at, now).astimezone(LOCAL_TZ),
                                          prefs)
            gated.append((tt, a, decision))
        pending_alerts = [x for x in pending_alerts if x[0] is not t]
        delivered.extend(gated)
        if cap is not None:
            alert_state["cap"] = cap
        fields["alert_state"] = alert_state
        VehicleTracker.objects.filter(pk=tid).update(**fields)
    if rows:
        VehiclePosition.objects.bulk_create(rows, batch_size=500)
    for t, a, decision in delivered:
        if decision != "drop":
            deliver_alert(t, a, push=decision == "push")
        else:
            audit(t, "alert_dropped", kind=a.get("kind"), alarm=a.get("alarm"))
    return len(rows)


def _odo_step(odo_m, last_pt, f, at):
    """Add the distance from the last counted fix to this one, unless it is
    parked wander (< JITTER_M), an implied >MAX_JUMP_KMH jump, or a fix older
    than the last counted one (out-of-order re-send)."""
    if last_pt:
        try:
            from datetime import datetime as _dt
            p_at = _dt.fromisoformat(last_pt[2])
        except (ValueError, IndexError, TypeError):
            p_at = None
        if p_at is not None and at <= p_at:
            return odo_m, last_pt
        d = VT.haversine_m(float(last_pt[0]), float(last_pt[1]), f["lat"], f["lng"])
        dt = (at - p_at).total_seconds() if p_at else 0
        if dt > 0 and d / dt * 3.6 > VT.MAX_JUMP_KMH:
            return odo_m, last_pt                      # GPS jump: ignore the fix
        if d < VT.JITTER_M:
            return odo_m, last_pt                      # parked wander: keep anchor
        odo_m += d
    return odo_m, [f["lat"], f["lng"], at.isoformat()]


PREF_DEFAULTS = {"ignition_on": False, "ignition_off": False, "stop_alert_min": 0,
                 "silent_min": 30, "quiet_start": "", "quiet_end": "",
                 "daily_push_cap": VT.DAILY_PUSH_CAP}


def alert_prefs(t):
    """The tracker's alert switches with defaults + bounds (never unbounded)."""
    raw = t.alert_prefs if isinstance(t.alert_prefs, dict) else {}
    out = dict(PREF_DEFAULTS)
    for k in ("ignition_on", "ignition_off"):
        if k in raw:
            out[k] = bool(raw[k])
    for k, lo, hi in (("stop_alert_min", 0, 720), ("silent_min", 0, 1440),
                      ("daily_push_cap", 1, 100)):
        try:
            out[k] = max(lo, min(hi, int(raw.get(k, out[k]))))
        except (TypeError, ValueError):
            pass
    for k in ("quiet_start", "quiet_end"):
        v = str(raw.get(k) or "")
        if len(v) == 5 and v[2] == ":" and v[:2].isdigit() and v[3:].isdigit():
            out[k] = v
    return out


def sweep_silent(now=None):
    """Tracker went silent (veh100). Run by the tracker daemon's housekeeper
    every 30 s: a PAIRED tracker last seen > silent_min ago alerts once per
    silence (re-armed by the next packet in ingest)."""
    from .models import VehicleTracker
    now = now or timezone.now()
    n = 0
    qs = VehicleTracker.objects.filter(
        state="paired", last_seen_at__isnull=False,
        last_seen_at__lt=now - timedelta(minutes=10),
        last_seen_at__gte=now - timedelta(days=2)).select_related("owner")
    for t in qs[:2000]:
        prefs = alert_prefs(t)
        st = dict(t.alert_state or {})
        st2, alert = VT.silent_alert(st, t.last_seen_at, now, prefs["silent_min"],
                                     was_moving=(t.last_speed_kmh or 0) >= VT.MOVING_KMH)
        if alert is None:
            continue
        alert.update(lat=t.last_lat, lng=t.last_lng)
        decision, cap = VT.gate_alert(st2.get("cap"), alert, now.astimezone(LOCAL_TZ), prefs)
        st2["cap"] = cap
        VehicleTracker.objects.filter(pk=t.pk).update(alert_state=st2)
        if decision != "drop":
            deliver_alert(t, alert, push=decision == "push")
            n += 1
    return n


def split_fences(raw):
    """t.geofences holds circle fences AND planned routes ({"type": "route"})
    in one JSON list (no extra column). Returns (circles, routes)."""
    circles, routes = [], []
    for f in raw or []:
        if isinstance(f, dict):
            (routes if f.get("type") == "route" else circles).append(f)
    return circles, routes


def prune(now=None):
    """Hard-delete positions older than retention_days. Returns rows deleted."""
    from .models import VehiclePosition
    now = now or timezone.now()
    cutoff = now - timedelta(days=vcfg()["retention_days"])
    n, _ = VehiclePosition.objects.filter(at__lt=cutoff).delete()
    return n


# --------------------------------------------------------------- commands

def pending_for(tracker_ids):
    """Queued commands for the connected trackers, oldest first."""
    from .models import VehicleCommand
    return list(VehicleCommand.objects.filter(
        tracker_id__in=list(tracker_ids), state="queued")
        .order_by("created_at").values("id", "tracker_id", "kind", "payload"))


def mark_sent(cmd_id, text, server_flag, now=None):
    from .models import VehicleCommand
    VehicleCommand.objects.filter(pk=cmd_id, state="queued").update(
        state="sent", text=text[:120], server_flag=server_flag,
        sent_at=now or timezone.now())


def mark_reply(tracker_id, text, ok, server_flag=None, now=None, kind=None):
    """Attach a device reply to the oldest 'sent' command (matching the GT06
    server flag when given). ok True -> acked, False -> failed, None -> acked
    only if the device-reported relay state agrees later; we store it as
    'failed' with reason 'unclear_reply' so nobody is misled."""
    from .models import VehicleCommand, VehicleTracker
    now = now or timezone.now()
    qs = VehicleCommand.objects.filter(tracker_id=tracker_id, state="sent")
    if server_flag:
        qs = qs.filter(server_flag=server_flag)
    if kind:                       # TK103 'jt' / 'kt' say which command they confirm
        qs = qs.filter(kind=kind)
    cmd = qs.order_by("sent_at").first()
    if cmd is None:
        return None
    cmd.response = (text or "")[:500]
    cmd.done_at = now
    if ok:
        cmd.state = "acked"
        if cmd.kind in ("engine_cut", "engine_restore"):
            VehicleTracker.objects.filter(pk=tracker_id).update(
                relay_cut=(cmd.kind == "engine_cut"))
    else:
        cmd.state = "failed"
        cmd.fail_reason = "device_error" if ok is False else "unclear_reply"
    cmd.save(update_fields=["response", "done_at", "state", "fail_reason"])
    audit(cmd.tracker, "command_" + cmd.state, kind=cmd.kind, command_id=cmd.id,
          response=cmd.response[:120])
    if cmd.kind != "set_interval":
        _notify_command(cmd)
    return cmd.id


def expire_commands(now=None):
    """sent > timeout -> failed(no_reply); queued > 24h -> expired;
    awaiting_approval > 30 min -> expired."""
    from .models import VehicleCommand
    now = now or timezone.now()
    timeout = vcfg()["command_timeout_s"]
    n = 0
    for cmd in VehicleCommand.objects.filter(
            state="sent", sent_at__lt=now - timedelta(seconds=timeout)):
        cmd.state, cmd.fail_reason, cmd.done_at = "failed", "no_reply", now
        cmd.save(update_fields=["state", "fail_reason", "done_at"])
        audit(cmd.tracker, "command_failed", kind=cmd.kind, command_id=cmd.id,
              reason="no_reply")
        if cmd.kind != "set_interval":
            _notify_command(cmd)
        n += 1
    n += VehicleCommand.objects.filter(
        state="queued", created_at__lt=now - timedelta(hours=24)).update(
        state="expired", done_at=now)
    n += VehicleCommand.objects.filter(
        state="awaiting_approval",
        created_at__lt=now - timedelta(minutes=30)).update(
        state="expired", done_at=now)
    n += VehicleCommand.objects.filter(       # veh100: second confirmation never came
        state="awaiting_confirm",
        created_at__lt=now - timedelta(minutes=2)).update(
        state="expired", done_at=now)
    return n


def new_cancel_token():
    return secrets.token_urlsafe(16)


# --------------------------------------------------------------- notify

def _viewers(tracker):
    """Owner + users explicitly granted view access (never the whole circle —
    location is only shared with people the owner chose)."""
    out = [tracker.owner]
    for g in tracker.grants.select_related("grantee"):
        if g.grantee_id != tracker.owner_id:
            out.append(g.grantee)
    return out


def _vehicle_name(tracker):
    if tracker.name:
        return tracker.name
    try:
        if tracker.vehicle_record and isinstance(tracker.vehicle_record.data, dict):
            return str(tracker.vehicle_record.data.get("name") or "")
    except Exception:
        pass
    return ""


def _send(users, title_bn, title_en, body_bn, body_en, meta, family_alert_for=None,
          severity="high", push_it=True):
    from .models import NotifEvent, FamilyAlert
    for u in users:
        try:
            NotifEvent.objects.create(user=u, type="security", title_bn=title_bn[:200],
                                      title_en=title_en[:200], body_bn=body_bn,
                                      body_en=body_en, route="vehicles", meta=meta)
        except Exception:
            pass
        if not push_it:
            continue          # quiet hours / daily cap: in-app only (veh100)
        try:
            from . import push
            push.safe_push(u, "family_alert", title_bn, title_en, body_bn, body_en,
                           data={"route": "vehicles", **{k: str(v) for k, v in meta.items()}})
        except Exception:
            pass
    if family_alert_for is not None:
        try:
            FamilyAlert.objects.create(user=family_alert_for, kind="vehicle",
                                       title=title_en[:160], body=body_en,
                                       severity=severity,
                                       payload={**meta, "title_bn": title_bn,
                                                "body_bn": body_bn})
        except Exception:
            pass


def deliver_alert(tracker, alert, push=True):
    """In-app notification + FamilyAlert for every viewer; a push too unless
    the gate (quiet hours / daily cap) said in-app only."""
    name = _vehicle_name(tracker)
    tb, bb = VT.alert_text(alert, name, "bn")
    te, be = VT.alert_text(alert, name, "en")
    meta = {"tracker_id": tracker.id, "alert": alert["kind"]}
    if alert.get("alarm"):
        meta["alarm"] = alert["alarm"]
    if alert.get("lat") is not None:
        meta.update(lat=alert["lat"], lng=alert["lng"])
    audit(tracker, "alert_" + alert["kind"], pushed=bool(push),
          **{k: v for k, v in alert.items() if k != "kind"})
    _send(_viewers(tracker), tb, te, bb, be, meta, family_alert_for=tracker.owner,
          severity="high" if alert["kind"] in ("night_ignition", "geofence_exit",
                                                 "off_route", "device_alarm",
                                                 "tracker_silent")
          else "med", push_it=push)


def _notify_owner(tracker, what):
    name = _vehicle_name(tracker) or tracker.imei[-4:]
    if what == "paired":
        tb, te = "ট্র্যাকার যুক্ত হয়েছে", "Tracker paired"
        bb = ("%s-এর ট্র্যাকার সংযুক্ত হয়েছে। এটি আপনার ডিভাইস না হলে এখনই "
              "সরিয়ে দিন।" % name)
        be = ("The tracker for %s connected and is now paired. If this is not "
              "your device, remove it now." % name)
    else:
        tb, te = "ট্র্যাকার চালু করা যায়নি", "Tracker could not start"
        bb = ("%s-এর ট্র্যাকার সংযুক্ত হয়েছিল, কিন্তু মাসিক ক্রেডিট যথেষ্ট নেই। "
              "ক্রেডিট যোগ করে আবার পেয়ার করুন।" % name)
        be = ("The tracker for %s connected, but there were not enough credits for "
              "the monthly fee. Add credits and pair again." % name)
    _send([tracker.owner], tb, te, bb, be, {"tracker_id": tracker.id, "event": what})


def _notify_command(cmd):
    t = cmd.tracker
    name = _vehicle_name(t) or t.imei[-4:]
    cut = cmd.kind == "engine_cut"
    if cmd.state == "acked":
        tb = "ইঞ্জিন বন্ধ নিশ্চিত" if cut else "ইঞ্জিন আবার চালু করা যাবে"
        te = "Engine cut confirmed" if cut else "Engine restore confirmed"
        bb = "%s-এর ট্র্যাকার নির্দেশটি গ্রহণ করেছে।" % name
        be = "The tracker in %s confirmed the command." % name
    else:
        tb = "নির্দেশ কার্যকর হয়নি"
        te = "Command did not go through"
        bb = ("%s-এর ট্র্যাকার নির্দেশটি নিশ্চিত করেনি। গাড়ির অবস্থা নিজে দেখে "
              "নিন।" % name)
        be = ("The tracker in %s did not confirm the command. Please check the "
              "vehicle yourself." % name)
    users = [t.owner]
    if cmd.requested_by_id and cmd.requested_by_id != t.owner_id:
        users.append(cmd.requested_by)
    _send(users, tb, te, bb, be, {"tracker_id": t.id, "command_id": cmd.id,
                                  "state": cmd.state})


def notify_approval_needed(cmd, approver_user):
    name = _vehicle_name(cmd.tracker) or cmd.tracker.imei[-4:]
    _send([approver_user], "ইঞ্জিন বন্ধের অনুমোদন দরকার", "Engine cut needs your approval",
          "%s-এর ইঞ্জিন বন্ধ করার অনুরোধ এসেছে। আপনি অনুমোদন দিলে তবেই পাঠানো হবে।" % name,
          "A request to cut the engine of %s needs your approval before it is sent." % name,
          {"tracker_id": cmd.tracker_id, "command_id": cmd.id})
