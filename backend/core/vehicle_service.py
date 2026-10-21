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


def imei_valid(imei):
    """15-digit IMEI with a correct Luhn check digit."""
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
        alert_state = dict(t.alert_state or {})
        settings = {"speed_limit_kmh": t.speed_limit_kmh,
                    "night_start": t.night_start, "night_end": t.night_end,
                    "night_ignition": t.night_ignition_alert,
                    "geofences": t.geofences or []}
        for f in fixes:
            at = f.get("at") or now
            if at > now + timedelta(minutes=5):   # device clock in the future
                at = now
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
            for a in alerts:
                pending_alerts.append((t, a))
        fields["alert_state"] = alert_state
        VehicleTracker.objects.filter(pk=tid).update(**fields)
    if rows:
        VehiclePosition.objects.bulk_create(rows, batch_size=500)
    for t, a in pending_alerts:
        deliver_alert(t, a)
    return len(rows)


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


def mark_reply(tracker_id, text, ok, server_flag=None, now=None):
    """Attach a device reply to the oldest 'sent' command (matching the GT06
    server flag when given). ok True -> acked, False -> failed, None -> acked
    only if the device-reported relay state agrees later; we store it as
    'failed' with reason 'unclear_reply' so nobody is misled."""
    from .models import VehicleCommand, VehicleTracker
    now = now or timezone.now()
    qs = VehicleCommand.objects.filter(tracker_id=tracker_id, state="sent")
    if server_flag:
        qs = qs.filter(server_flag=server_flag)
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
          severity="high"):
    from .models import NotifEvent, FamilyAlert
    for u in users:
        try:
            NotifEvent.objects.create(user=u, type="security", title_bn=title_bn[:200],
                                      title_en=title_en[:200], body_bn=body_bn,
                                      body_en=body_en, route="vehicles", meta=meta)
        except Exception:
            pass
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


def deliver_alert(tracker, alert):
    name = _vehicle_name(tracker)
    tb, bb = VT.alert_text(alert, name, "bn")
    te, be = VT.alert_text(alert, name, "en")
    meta = {"tracker_id": tracker.id, "alert": alert["kind"]}
    if alert.get("lat") is not None:
        meta.update(lat=alert["lat"], lng=alert["lng"])
    audit(tracker, "alert_" + alert["kind"], **{k: v for k, v in alert.items()
                                               if k != "kind"})
    _send(_viewers(tracker), tb, te, bb, be, meta, family_alert_for=tracker.owner,
          severity="high" if alert["kind"] in ("night_ignition", "geofence_exit")
          else "med")


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
