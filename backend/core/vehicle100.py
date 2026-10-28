"""
veh100 — the Django side of the vehicle-tracking "100" work (owner order 28 Oct):

  * share live location link   lifeassisto.com/v/<token>  (signed random token,
    only its SHA-256 stored; expiring, revocable, no login, current position
    only — never history; rate-limited per IP in web/views_vehicle_share.py)
  * drivers                    driver records (PaCollectionItem
    'vehicle/drivers') + VehicleDriverShift (who drove when)
  * reports                    one Dhaka day (live from positions) / one month
    (VehicleDailyStat rows rolled up nightly + today live); bn/en; CSV export
  * reminders                  BRTA tax token / fitness / insurance / route
    permit expiry + maintenance by km AND date + driver licence expiry —
    pushes with a claim (at-most-once), 1 push/user/Dhaka day, quiet hours
  * setup guide                per-brand SMS commands (GT06 / H02 / TK103 /
    Teltonika) with the operator APN filled in

Every function is synchronous ORM code with an injectable `now`.
"""
import csv
import hashlib
import io
import logging
import secrets
from collections import defaultdict
from datetime import date, datetime, time, timedelta

from django.db import IntegrityError, transaction
from django.utils import timezone

from .logic import vehicle_tracking as VT
from . import vehicle_service as VS

log = logging.getLogger(__name__)

LOCAL_TZ = VS.LOCAL_TZ
_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn(v):
    return str(v).translate(_BN)


# =========================================================================== share links

SHARE_HOURS = (1, 4, 8, 24, 72)       # the only lifetimes offered (max 3 days)
MAX_ACTIVE_SHARES = 5                  # per tracker
FRESH_S = 120                          # "live" when the last fix is this fresh
LOST_S = 15 * 60                       # older than this = "lost"


def _hash(token):
    return hashlib.sha256(str(token).encode()).hexdigest()


def site():
    from .journey_watch import site as _site
    return _site()


def create_share(tracker, user, hours, label="", now=None):
    """Returns (link, token) or raises ValueError(reason)."""
    from .models import VehicleShareLink
    now = now or timezone.now()
    try:
        hours = int(hours)
    except (TypeError, ValueError):
        raise ValueError("bad_hours")
    if hours not in SHARE_HOURS:
        raise ValueError("bad_hours")
    active = VehicleShareLink.objects.filter(tracker=tracker, revoked_at__isnull=True,
                                             expires_at__gt=now).count()
    if active >= MAX_ACTIVE_SHARES:
        raise ValueError("too_many_links")
    token = secrets.token_urlsafe(24)
    link = VehicleShareLink.objects.create(
        tracker=tracker, created_by=user, token_hash=_hash(token),
        label=str(label or "")[:40], expires_at=now + timedelta(hours=hours))
    VS.audit(tracker, "share_created", actor=user, link_id=link.id, hours=hours)
    return link, token


def share_url(token):
    return "%s/v/%s" % (site(), token)


def share_json(link, now=None, token=None):
    now = now or timezone.now()
    st = ("revoked" if link.revoked_at else
          "expired" if link.expires_at <= now else "active")
    out = {"id": link.id, "label": link.label, "state": st,
           "expires_at": link.expires_at.isoformat(),
           "created_at": link.created_at.isoformat() if link.created_at else None,
           "views": link.views,
           "last_view_at": link.last_view_at.isoformat() if link.last_view_at else None}
    if token:
        out["url"] = share_url(token)
    return out


def revoke_share(link, user, now=None):
    if link.revoked_at is None:
        link.revoked_at = now or timezone.now()
        link.save(update_fields=["revoked_at"])
        VS.audit(link.tracker, "share_revoked", actor=user, link_id=link.id)
    return link


def share_state(token, now=None, count_view=True):
    """Public JSON for /v/<token>. Location ONLY while the link is active and
    the tracker paired; never route history. Returns (dict, http_status)."""
    from .models import VehicleShareLink
    now = now or timezone.now()
    if not token or len(str(token)) > 64:
        return {"state": "bad"}, 404
    link = VehicleShareLink.objects.filter(token_hash=_hash(token)) \
        .select_related("tracker", "tracker__vehicle_record").first()
    if link is None:
        return {"state": "bad"}, 404
    if link.revoked_at is not None:
        return {"state": "revoked"}, 200
    if link.expires_at <= now:
        return {"state": "expired"}, 200
    t = link.tracker
    if count_view:
        from django.db.models import F
        VehicleShareLink.objects.filter(pk=link.pk).update(views=F("views") + 1,
                                                           last_view_at=now)
    out = {"name": VS._vehicle_name(t) or "", "label": link.label,
           "expires_at": link.expires_at.isoformat()}
    if t.state != "paired":
        return {**out, "state": "paused"}, 200
    if t.last_fix_at is None or t.last_lat is None:
        return {**out, "state": "waiting"}, 200
    age = int((now - t.last_fix_at).total_seconds())
    state = "live" if age <= FRESH_S else ("stale" if age < LOST_S else "lost")
    out.update(state=state, lat=round(t.last_lat, 6), lng=round(t.last_lng, 6),
               at=t.last_fix_at.isoformat(), age_s=max(0, age),
               speed_kmh=round(float(t.last_speed_kmh or 0)),
               course=int(t.last_course or 0),
               moving=(t.last_speed_kmh or 0) >= VT.MOVING_KMH)
    return out, 200


# =========================================================================== drivers

DRIVERS = "vehicle/drivers"


def owner_driver(user, driver_id):
    from .models import PaCollectionItem
    try:
        did = int(driver_id)
    except (TypeError, ValueError):
        return None
    return PaCollectionItem.objects.filter(pk=did, user=user, collection=DRIVERS).first()


def driver_name(item):
    d = item.data if isinstance(getattr(item, "data", None), dict) else {}
    return str(d.get("name") or "")[:60]


def current_shift(tracker):
    return tracker.driver_shifts.filter(ended_at__isnull=True).select_related("driver").first()


def assign_driver(tracker, driver_item, by, now=None):
    """End the open shift (if any) and start one for driver_item (None = no
    driver). Returns the new shift or None."""
    from .models import VehicleDriverShift
    now = now or timezone.now()
    with transaction.atomic():
        cur = current_shift(tracker)
        if cur is not None:
            if driver_item is not None and cur.driver_id == driver_item.id:
                return cur
            cur.ended_at = now
            cur.save(update_fields=["ended_at"])
        shift = None
        if driver_item is not None:
            shift = VehicleDriverShift.objects.create(tracker=tracker, driver=driver_item,
                                                      started_at=now, by=by)
    VS.audit(tracker, "driver_assigned", actor=by,
             driver_id=driver_item.id if driver_item else None)
    return shift


def shift_json(sh):
    return {"id": sh.id, "driver_id": sh.driver_id, "driver_name": driver_name(sh.driver),
            "started_at": sh.started_at.isoformat(),
            "ended_at": sh.ended_at.isoformat() if sh.ended_at else None,
            "tracker_id": sh.tracker_id}


# =========================================================================== reports

def day_bounds(d):
    start = datetime.combine(d, time(0, 0), tzinfo=LOCAL_TZ)
    return start, start + timedelta(days=1)


def _fixes(tracker_id, start, end, cap=60000):
    from .models import VehiclePosition
    return [{"at": p.at, "lat": p.lat, "lng": p.lng, "speed_kmh": p.speed_kmh,
             "ignition": p.ignition, "valid": True,
             "local_hour": p.at.astimezone(LOCAL_TZ).hour}
            for p in VehiclePosition.objects.filter(
                tracker_id=tracker_id, at__gte=start, at__lt=end).order_by("at")[:cap]]


def _night(t):
    return (VT._parse_hhmm(t.night_start, 23), VT._parse_hhmm(t.night_end, 5))


def _iso(v):
    return v.isoformat() if hasattr(v, "isoformat") else v


def driver_splits(tracker, start, end, fixes):
    """{driver_id: [fixes]} for the shifts overlapping [start, end)."""
    from .models import VehicleDriverShift
    out = {}
    shifts = VehicleDriverShift.objects.filter(tracker=tracker, started_at__lt=end) \
        .exclude(ended_at__lt=start).select_related("driver")
    for sh in shifts:
        a = max(sh.started_at, start)
        b = min(sh.ended_at or end, end)
        part = [f for f in fixes if a <= f["at"] < b]
        if part:
            out.setdefault(sh.driver_id, {"name": driver_name(sh.driver), "fixes": []})
            out[sh.driver_id]["fixes"].extend(part)
    return out


def _alerts_count(tracker, start, end):
    from .models import VehicleAuditLog
    return VehicleAuditLog.objects.filter(tracker=tracker, action__startswith="alert_",
                                          at__gte=start, at__lt=end).count()


def day_report(tracker, d, now=None):
    """One Dhaka day from raw positions (inside retention). Includes trips,
    behaviour and the per-driver split."""
    now = now or timezone.now()
    start, end = day_bounds(d)
    fixes = _fixes(tracker.id, start, min(end, now + timedelta(minutes=1)))
    stats = VT.day_stats(fixes, tracker.speed_limit_kmh, night=_night(tracker))
    trips = VT.compute_trips(fixes, night=_night(tracker))["trips"]
    drivers = []
    for did, part in driver_splits(tracker, start, end, fixes).items():
        ds = VT.day_stats(part["fixes"], tracker.speed_limit_kmh, night=_night(tracker))
        drivers.append({"driver_id": did, "name": part["name"], **ds})
    retention = VS.vcfg()["retention_days"]
    in_retention = (now.astimezone(LOCAL_TZ).date() - d).days < retention
    return {"period": "day", "date": d.isoformat(), "tracker_id": tracker.id,
            "name": VS._vehicle_name(tracker), "totals": stats,
            "band": VT.score_band(stats["score"]),
            "trips": [{k: _iso(v) for k, v in tp.items()} for tp in trips],
            "drivers": drivers, "alerts": _alerts_count(tracker, start, end),
            "in_retention": in_retention,
            "speed_limit_kmh": tracker.speed_limit_kmh or VT.DEFAULT_LIMIT_KMH,
            "limit_default": not bool(tracker.speed_limit_kmh)}


def rollup_day(tracker, d, now=None):
    """Upsert VehicleDailyStat rows (driver 0 = vehicle, >0 = each driver)."""
    from .models import VehicleDailyStat
    rep = day_report(tracker, d, now=now)
    rows = [(0, rep["totals"])] + [(x["driver_id"], x) for x in rep["drivers"]]
    for did, st in rows:
        VehicleDailyStat.objects.update_or_create(
            tracker=tracker, day=d, driver_id=did,
            defaults={k: st.get(k) if k == "score" else (st.get(k) or 0) for k in (
                "km", "trips", "moving_s", "idle_s", "max_kmh", "overspeed_s",
                "harsh_brake", "harsh_accel", "night_trips", "score", "coverage")}
            | {"alerts": rep["alerts"] if did == 0 else 0})
    return len(rows)


def rollup(now=None, days_back=2):
    """Nightly: the last `days_back` COMPLETE Dhaka days for every tracker
    that has positions then (idempotent upsert)."""
    from .models import VehiclePosition, VehicleTracker
    now = now or timezone.now()
    today = now.astimezone(LOCAL_TZ).date()
    n = 0
    for back in range(1, days_back + 1):
        d = today - timedelta(days=back)
        start, end = day_bounds(d)
        tids = set(VehiclePosition.objects.filter(at__gte=start, at__lt=end)
                   .values_list("tracker_id", flat=True).distinct())
        for t in VehicleTracker.objects.filter(pk__in=tids):
            n += rollup_day(t, d, now=now)
    return n


def _stat_dict(r):
    return {"day": r.day.isoformat(), "km": r.km, "trips": r.trips, "moving_s": r.moving_s,
            "idle_s": r.idle_s, "max_kmh": r.max_kmh, "overspeed_s": r.overspeed_s,
            "harsh_brake": r.harsh_brake, "harsh_accel": r.harsh_accel,
            "night_trips": r.night_trips, "score": r.score, "coverage": r.coverage,
            "alerts": r.alerts}


def month_report(tracker, year, month, now=None, driver_id=0):
    """Calendar month: rolled-up days + TODAY live (if in the month). Days
    inside retention that were never rolled up (cron missed) are computed
    live too, so the report is never silently short."""
    from .models import VehicleDailyStat
    now = now or timezone.now()
    first = date(year, month, 1)
    nxt = date(year + (month // 12), month % 12 + 1, 1)
    today = now.astimezone(LOCAL_TZ).date()
    rows = {r.day: _stat_dict(r) for r in VehicleDailyStat.objects.filter(
        tracker=tracker, driver_id=driver_id, day__gte=first, day__lt=nxt)}
    retention = VS.vcfg()["retention_days"]
    d = first
    while d < nxt and d <= today:
        if (d not in rows or d == today) and (today - d).days < retention:
            rep = day_report(tracker, d, now=now)
            if driver_id:
                src = next((x for x in rep["drivers"] if x["driver_id"] == driver_id), None)
            else:
                src = rep["totals"]
            if src and (src.get("points") or src.get("km")):
                rows[d] = {"day": d.isoformat(), **{k: src.get(k) for k in (
                    "km", "trips", "moving_s", "idle_s", "max_kmh", "overspeed_s",
                    "harsh_brake", "harsh_accel", "night_trips", "score", "coverage")},
                    "alerts": rep["alerts"] if not driver_id else 0}
        d += timedelta(days=1)
    days = [rows[k] for k in sorted(rows)]
    tot = VT.month_totals(days)
    return {"period": "month", "month": "%04d-%02d" % (year, month),
            "tracker_id": tracker.id, "name": VS._vehicle_name(tracker),
            "driver_id": driver_id or None, "days": days, "totals": tot,
            "band": VT.score_band(tot["score"]),
            "speed_limit_kmh": tracker.speed_limit_kmh or VT.DEFAULT_LIMIT_KMH,
            "limit_default": not bool(tracker.speed_limit_kmh)}


CSV_HEAD = {
    "bn": ["তারিখ", "দূরত্ব (কিমি)", "যাত্রা", "চলার সময় (মিনিট)", "ইঞ্জিন চালু থেমে (মিনিট)",
           "সর্বোচ্চ গতি (কিমি/ঘণ্টা)", "সীমার বেশি (মিনিট)", "জোরে ব্রেক", "হঠাৎ গতি",
           "রাতের যাত্রা", "চালনা স্কোর", "সতর্কতা"],
    "en": ["Date", "Distance (km)", "Trips", "Driving (min)", "Idling (min)",
           "Top speed (km/h)", "Over limit (min)", "Harsh brakes", "Harsh accelerations",
           "Night trips", "Driving score", "Alerts"],
}


def report_csv(rep, lang="bn"):
    """CSV for a day or month report. Numbers stay in Western digits so a
    spreadsheet can add them up; headers in the user's language."""
    lang = "en" if lang == "en" else "bn"
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(CSV_HEAD[lang])
    rows = rep["days"] if rep["period"] == "month" else [{"day": rep["date"], **rep["totals"],
                                                         "alerts": rep["alerts"]}]
    for r in rows:
        w.writerow([r.get("day"), r.get("km") or 0, r.get("trips") or 0,
                    int((r.get("moving_s") or 0) / 60), int((r.get("idle_s") or 0) / 60),
                    int(r.get("max_kmh") or 0), int((r.get("overspeed_s") or 0) / 60),
                    r.get("harsh_brake") or 0, r.get("harsh_accel") or 0,
                    r.get("night_trips") or 0,
                    "" if r.get("score") is None else r["score"], r.get("alerts") or 0])
    if rep["period"] == "month":
        t = rep["totals"]
        w.writerow(["মোট" if lang == "bn" else "Total", t["km"], t["trips"],
                    int(t["moving_s"] / 60), int(t["idle_s"] / 60), int(t["max_kmh"]),
                    int(t["overspeed_s"] / 60), t["harsh_brake"], t["harsh_accel"],
                    t["night_trips"], "" if t["score"] is None else t["score"], ""])
    return "﻿" + buf.getvalue()        # BOM: Excel opens Bangla correctly


# =========================================================================== reminders

MAX_PUSHES_PER_DAY = 1
MAX_ITEMS_PER_PUSH = 3
RECORDS = "vehicle/records"


def _odometer_for(record, trackers_by_record):
    t = trackers_by_record.get(record.id)
    if t is not None and (t.odometer_m or t.odometer_base_km):
        return t.odometer_km, "tracker"
    d = record.data if isinstance(record.data, dict) else {}
    try:
        v = float(d.get("odometer_km"))
        return v, "manual"
    except (TypeError, ValueError):
        return None, None


def _parse_date(v):
    try:
        return date.fromisoformat(str(v)[:10])
    except (TypeError, ValueError):
        return None


def due_items(user, today, trackers_by_record=None):
    """Everything due for one user (pure-ish: reads the user's records).
    Returns [{key, kind, label_bn, label_en, name, days_left|km_left, stage}]."""
    from .models import PaCollectionItem, VehicleTracker
    if trackers_by_record is None:
        trackers_by_record = {t.vehicle_record_id: t for t in VehicleTracker.objects.filter(
            owner=user, vehicle_record__isnull=False)}
    out = []
    for rec in PaCollectionItem.objects.filter(user=user, collection=RECORDS)[:100]:
        d = rec.data if isinstance(rec.data, dict) else {}
        name = str(d.get("name") or "")[:40]
        for k in VT.PAPER_KEYS:
            exp = _parse_date(d.get(k))
            if exp is None:
                continue
            days = (exp - today).days
            st = VT.paper_stage(days)
            if st is None:
                continue
            bn_l, en_l = VT.PAPER_LABELS[k]
            out.append({"key": "paper:%d:%s:%s" % (rec.id, k, exp.isoformat()),
                        "stage": st, "kind": "paper", "field": k, "label_bn": bn_l,
                        "label_en": en_l, "name": name, "days_left": days,
                        "record_id": rec.id})
        odo, src = _odometer_for(rec, trackers_by_record)
        for m in (d.get("maintenance") or [])[:20]:
            if not isinstance(m, dict):
                continue
            res = VT.maintenance_due(m, odo, today)
            if not res["due"]:
                continue
            mname = str(m.get("name") or "")[:40]
            out.append({"key": "maint:%d:%s:%s:%s" % (rec.id, str(m.get("id") or mname)[:16],
                                                       m.get("last_km") or 0,
                                                       str(m.get("last_date") or "")[:10]),
                        "stage": 1 if res["overdue"] else 2, "kind": "maintenance",
                        "label_bn": mname or "সার্ভিসিং", "label_en": mname or "Service",
                        "name": name, "days_left": res["days_left"],
                        "km_left": res["km_left"], "by": res["by"],
                        "odometer_source": src, "record_id": rec.id})
    for drv in PaCollectionItem.objects.filter(user=user, collection=DRIVERS)[:100]:
        d = drv.data if isinstance(drv.data, dict) else {}
        exp = _parse_date(d.get("licence_expiry"))
        if exp is None:
            continue
        days = (exp - today).days
        st = VT.paper_stage(days)
        if st is None:
            continue
        bn_l, en_l = VT.PAPER_LABELS["licence_expiry"]
        out.append({"key": "licence:%d:%s" % (drv.id, exp.isoformat()), "stage": st,
                    "kind": "licence", "label_bn": bn_l, "label_en": en_l,
                    "name": str(d.get("name") or "")[:40], "days_left": days,
                    "driver_id": drv.id})
    out.sort(key=lambda x: (x.get("days_left") if x.get("days_left") is not None else 999,
                            x["key"]))
    return out


def _when(days, lang):
    if days is None:
        return ""
    if lang == "en":
        return "today" if days <= 0 else ("tomorrow" if days == 1 else "in %d days" % days)
    return "আজ" if days <= 0 else ("আগামীকাল" if days == 1 else "%s দিনে" % bn(days))


def _line(it, lang):
    label = it["label_en"] if lang == "en" else it["label_bn"]
    who = it.get("name") or ""
    if it["kind"] == "maintenance":
        if it.get("by") == "km" and it.get("km_left") is not None:
            km = int(it["km_left"])
            if lang == "en":
                what = ("%s: due now" % label) if km <= 0 else ("%s: in %d km" % (label, km))
            else:
                what = ("%s: এখনই করার সময়" % label) if km <= 0 else (
                    "%s: আর %s কিমি পরে" % (label, bn(km)))
        else:
            what = "%s: %s" % (label, _when(it.get("days_left"), lang))
    else:
        what = ("%s expires %s" % (label, _when(it["days_left"], "en"))) if lang == "en" \
            else ("%s-এর মেয়াদ %s শেষ" % (label, _when(it["days_left"], "bn")))
    return ("%s — %s" % (who, what)) if who else what


def build_message(items):
    """[due items] most urgent first -> {title:{bn,en}, body:{bn,en}}."""
    out = {"title": {}, "body": {}}
    if len(items) == 1:
        it = items[0]
        for lang in ("bn", "en"):
            out["title"][lang] = _line(it, lang)
        out["body"]["bn"] = ("আমার গাড়ি খুলে দেখুন — নবায়ন বা সার্ভিসিং করে তারিখ বদলে দিন।")
        out["body"]["en"] = ("Open My Vehicles to check — renew or service, then update the date.")
        return out
    n = len(items)
    out["title"]["bn"] = "গাড়ির %sটি কাজ শিগগির করতে হবে" % bn(n)
    out["title"]["en"] = "%d vehicle items due soon" % n
    for lang in ("bn", "en"):
        parts = [_line(it, lang) for it in items[:MAX_ITEMS_PER_PUSH]]
        if n > MAX_ITEMS_PER_PUSH:
            parts.append(("আরও %sটি" % bn(n - MAX_ITEMS_PER_PUSH)) if lang == "bn"
                         else "%d more" % (n - MAX_ITEMS_PER_PUSH))
        out["body"][lang] = "; ".join(parts)
    return out


def _claim(user, key, now):
    from .models import VehicleReminderClaim
    try:
        with transaction.atomic():
            return VehicleReminderClaim.objects.create(user=user, key=key[:120], sent_at=now)
    except IntegrityError:
        return None


def _already(user, key_base, stage):
    """This stage or a MORE urgent one already went for this exact due item."""
    from .models import VehicleReminderClaim
    keys = ["%s:s%d" % (key_base, s) for s in (1, 2, 7, 30) if s <= stage]
    return VehicleReminderClaim.objects.filter(user=user, key__in=keys).exists()


def sweep_reminders(now=None, push_fn=None):
    """Hourly. Quiet hours 21:00-09:00 Dhaka (msg_guard); 1 push per user per
    Dhaka day (several due items share it); at-most-once per (item, stage)."""
    from .logic import msg_guard as MG
    from .models import PaCollectionItem, User, VehicleReminderClaim
    from . import push as push_mod
    push_fn = push_fn or push_mod.push_to_user
    now = now or timezone.now()
    stats = defaultdict(int)
    if MG.in_quiet_hours(now):
        stats["quiet_hours"] = 1
        return dict(stats)
    today = MG.local(now).date()
    day0 = MG.day_start(now)
    uids = set(PaCollectionItem.objects.filter(collection__in=[RECORDS, DRIVERS])
               .values_list("user_id", flat=True).distinct()[:5000])
    for user in User.objects.filter(pk__in=uids, is_active=True):
        items = due_items(user, today)
        if not items:
            continue
        stats["users_due"] += 1
        if VehicleReminderClaim.objects.filter(user=user, sent_at__gte=day0) \
                .values("sent_at").distinct().count() >= MAX_PUSHES_PER_DAY:
            stats["capped"] += 1
            continue
        claimed = []
        for it in items:
            if _already(user, it["key"], it["stage"]):
                stats["already"] += 1
                continue
            c = _claim(user, "%s:s%d" % (it["key"], it["stage"]), now)
            if c is None:
                stats["already"] += 1
                continue
            claimed.append((c, it))
        if not claimed:
            continue
        msg = build_message([it for _, it in claimed])
        n = 0
        try:
            n = push_fn(user, "reminder", msg["title"]["bn"], msg["title"]["en"],
                        msg["body"]["bn"], msg["body"]["en"],
                        data={"route": "vehicles", "event": "vehicle_reminder",
                              "items": str(len(claimed))})
        except Exception:  # noqa: BLE001 - never crash the sweep
            log.exception("vehicle reminders: push failed")
        if n:
            VehicleReminderClaim.objects.filter(pk__in=[c.pk for c, _ in claimed]) \
                .update(delivered=min(int(n), 32767))
        stats["pushes"] += 1
        stats["items"] += len(claimed)
    return dict(stats)


# =========================================================================== setup guide

APN = {"gp": "gpinternet", "robi": "internet", "airtel": "internet",
       "banglalink": "blweb", "teletalk": "wap"}
BRANDS = ("sinotrack", "concox", "coban", "teltonika")
BRAND_PROTOCOL = {"sinotrack": "h02", "concox": "gt06", "coban": "tk103",
                  "teltonika": "teltonika"}


def setup_guide(brand, operator, host, port, ip="16.4.105.173", password=""):
    """SMS commands to send FROM the owner's phone TO the tracker's SIM,
    in order. `password` = the device password if the owner changed it
    (defaults: Sinotrack 0000, Coban 123456, Concox none / 666666 on some
    clones, Teltonika empty). Returns {protocol, id_hint, steps:[{sms, what}],
    reply_ok}. what = machine code the app turns into a localized line."""
    brand = brand if brand in BRANDS else "concox"
    apn = APN.get(operator, "gpinternet")
    pw = str(password or "")
    if brand == "sinotrack":
        p = pw or "0000"
        steps = [("803%s %s" % (p, apn), "apn"),
                 ("804%s %s %d" % (p, ip, port), "server"),
                 ("710%s" % p, "gprs_on")]
        hint, reply = "id_10", "SET OK"
    elif brand == "coban":
        p = pw or "123456"
        steps = [("begin%s" % p, "reset"), ("apn%s %s" % (p, apn), "apn"),
                 ("adminip%s %s %d" % (p, ip, port), "server"),
                 ("gprs%s" % p, "gprs_on"), ("t030s***n%s" % p, "interval")]
        hint, reply = "imei_15", "ok"
    elif brand == "teltonika":
        steps = [("  setparam 2001:%s" % apn, "apn"),
                 ("  setparam 2004:%s;2005:%d;2006:0" % (host, port), "server")]
        hint, reply = "imei_15", "New value"
    else:
        pre = ("%s," % pw) if pw else ""
        steps = [("APN,%s%s#" % (pre, apn), "apn"),
                 ("SERVER,%s1,%s,%d,0#" % (pre, host, port), "server"),
                 ("GPRSON,%s1#" % pre, "gprs_on"),
                 ("TIMER,%s10,180#" % pre, "interval")]
        hint, reply = "imei_15", "OK"
    return {"brand": brand, "protocol": BRAND_PROTOCOL[brand], "operator": operator,
            "apn": apn, "id_hint": hint, "reply_ok": reply,
            "steps": [{"sms": s, "what": w} for s, w in steps]}
