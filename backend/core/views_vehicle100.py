"""
veh100 HTTP API (all under /api/v1/vehicle/, same access rules as
core.views_vehicle: anyone without view access gets 404).

  GET/POST  trackers/<pk>/share              list / create a live-location link (owner)
  DELETE    trackers/<pk>/share/<lid>        revoke it (owner)
  GET       trackers/<pk>/report?period=day&date=YYYY-MM-DD | period=month&month=YYYY-MM
            [&driver=<id>] [&export=csv&lang=bn|en]
  GET/POST  trackers/<pk>/driver             current driver + recent shifts / assign (owner)
  GET       drivers/<id>/report?month=YYYY-MM  one driver across the owner's vehicles
  GET       maintenance                      every vehicle record: papers + rules + due state
  GET       setup-guide?brand=&operator=     per-brand SMS commands (APN filled in)
"""
from datetime import date, timedelta

from django.http import HttpResponse
from django.utils import timezone
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .logic import vehicle_tracking as VT
from . import vehicle100 as V1
from . import vehicle_service as VS
from .views_vehicle import _load, _server_info

R = Response


class TrackerShareView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        now = timezone.now()
        return R({"links": [V1.share_json(x, now) for x in t.share_links.all()[:20]],
                  "hours": list(V1.SHARE_HOURS), "max_active": V1.MAX_ACTIVE_SHARES})

    def post(self, request, pk):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        if t.state != "paired":
            return R({"reason": "not_paired", "ok": False}, status=409)
        d = request.data or {}
        try:
            link, token = V1.create_share(t, request.user, d.get("hours"), d.get("label"))
        except ValueError as e:
            return R({"reason": str(e), "ok": False}, status=400)
        return R({"ok": True, "link": V1.share_json(link, token=token)}, status=201)


class TrackerShareRevokeView(APIView):
    permission_classes = [IsAuthenticated]

    def delete(self, request, pk, lid):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        link = t.share_links.filter(pk=lid).first()
        if link is None:
            return R({"reason": "not_found", "ok": False}, status=404)
        V1.revoke_share(link, request.user)
        return R({"ok": True, "link": V1.share_json(link)})


def _parse_day(v, today):
    if not v:
        return today
    try:
        return date.fromisoformat(str(v)[:10])
    except ValueError:
        return None


def _parse_month(v, today):
    if not v:
        return today.year, today.month
    try:
        y, m = str(v)[:7].split("-")
        y, m = int(y), int(m)
        if 2020 <= y <= 2100 and 1 <= m <= 12:
            return y, m
    except ValueError:
        pass
    return None


def _csv_response(rep, lang, fname):
    resp = HttpResponse(V1.report_csv(rep, lang), content_type="text/csv; charset=utf-8")
    resp["Content-Disposition"] = 'attachment; filename="%s"' % fname
    resp["Cache-Control"] = "no-store"
    return resp


class TrackerReportView(APIView):
    """Daily / monthly trip + distance report (server aggregation)."""
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        q = request.query_params
        now = timezone.now()
        today = now.astimezone(VS.LOCAL_TZ).date()
        lang = "en" if q.get("lang") == "en" else "bn"
        period = q.get("period") or "day"
        try:
            driver_id = int(q.get("driver") or 0)
        except ValueError:
            driver_id = 0
        if period == "month":
            ym = _parse_month(q.get("month"), today)
            if ym is None or date(ym[0], ym[1], 1) > today:
                return R({"reason": "bad_month", "ok": False}, status=400)
            rep = V1.month_report(t, ym[0], ym[1], now=now, driver_id=driver_id)
            fname = "assisto-vehicle-%d-%04d-%02d.csv" % (t.id, ym[0], ym[1])
        elif period == "day":
            d = _parse_day(q.get("date"), today)
            if d is None or d > today or (today - d).days > 400:
                return R({"reason": "bad_date", "ok": False}, status=400)
            rep = V1.day_report(t, d, now=now)
            if not rep["in_retention"]:
                # raw fixes are gone: serve the rolled-up row honestly
                from .models import VehicleDailyStat
                row = VehicleDailyStat.objects.filter(tracker=t, day=d, driver_id=0).first()
                rep["totals"] = V1._stat_dict(row) if row else rep["totals"]
                rep["from_rollup"] = row is not None
            fname = "assisto-vehicle-%d-%s.csv" % (t.id, d.isoformat())
        else:
            return R({"reason": "bad_period", "ok": False}, status=400)
        if q.get("export") == "csv":     # NOT ?format= (DRF content negotiation)
            return _csv_response(rep, lang, fname)
        return R(rep)


class TrackerDriverView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        t, acc, err = _load(request, pk)
        if err:
            return err
        sh = V1.current_shift(t)
        return R({"current": V1.shift_json(sh) if sh else None,
                  "recent": [V1.shift_json(x) for x in
                             t.driver_shifts.select_related("driver")[:20]]})

    def post(self, request, pk):
        t, acc, err = _load(request, pk, "manage")
        if err:
            return err
        did = (request.data or {}).get("driver_id")
        drv = None
        if did not in (None, "", 0):
            drv = V1.owner_driver(request.user, did)
            if drv is None:
                return R({"reason": "bad_driver", "ok": False}, status=400)
        sh = V1.assign_driver(t, drv, request.user)
        return R({"ok": True, "current": V1.shift_json(sh) if sh else None})


class DriverReportView(APIView):
    """One driver's month across ALL the owner's vehicles (per-driver trips)."""
    permission_classes = [IsAuthenticated]

    def get(self, request, did):
        from .models import VehicleTracker
        drv = V1.owner_driver(request.user, did)
        if drv is None:
            return R({"reason": "not_found", "ok": False}, status=404)
        now = timezone.now()
        today = now.astimezone(VS.LOCAL_TZ).date()
        ym = _parse_month(request.query_params.get("month"), today)
        if ym is None or date(ym[0], ym[1], 1) > today:
            return R({"reason": "bad_month", "ok": False}, status=400)
        tids = set(drv.vehicle_shifts.values_list("tracker_id", flat=True))
        per = []
        for t in VehicleTracker.objects.filter(pk__in=tids, owner=request.user):
            rep = V1.month_report(t, ym[0], ym[1], now=now, driver_id=drv.id)
            if rep["days"]:
                per.append({"tracker_id": t.id, "name": rep["name"],
                            "totals": rep["totals"], "days": rep["days"]})
        tot = VT.month_totals([d for p in per for d in p["days"]])
        return R({"driver_id": drv.id, "name": V1.driver_name(drv),
                  "month": "%04d-%02d" % ym, "vehicles": per, "totals": tot,
                  "band": VT.score_band(tot["score"])})


class MaintenanceView(APIView):
    """Every My Vehicles record with its papers + maintenance rules and what
    is due now (the same logic the reminder pushes use)."""
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .models import PaCollectionItem, VehicleTracker
        today = timezone.now().astimezone(VS.LOCAL_TZ).date()
        by_rec = {t.vehicle_record_id: t for t in VehicleTracker.objects.filter(
            owner=request.user, vehicle_record__isnull=False)}
        due = V1.due_items(request.user, today, by_rec)
        recs = []
        for rec in PaCollectionItem.objects.filter(user=request.user,
                                                   collection=V1.RECORDS)[:100]:
            d = V1.record_data(rec)
            odo, src = V1._odometer_for(rec, by_rec)
            rules = []
            for m in (d.get("maintenance") or [])[:20]:
                if isinstance(m, dict):
                    rules.append({**m, **VT.maintenance_due(m, odo, today)})
            papers = {}
            for k in VT.PAPER_KEYS:
                exp = V1._parse_date(d.get(k))
                papers[k] = None if exp is None else {
                    "date": exp.isoformat(), "days_left": (exp - today).days}
            recs.append({"id": rec.id, "name": str(d.get("name") or ""),
                         "odometer_km": odo, "odometer_source": src,
                         "tracker_id": by_rec[rec.id].id if rec.id in by_rec else None,
                         "papers": papers, "maintenance": rules})
        return R({"vehicles": recs, "due": due, "today": today.isoformat()})


class SetupGuideView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        q = request.query_params
        info = _server_info()
        brand = q.get("brand") or "concox"
        op = q.get("operator") or "gp"
        if brand not in V1.BRANDS or op not in V1.APN:
            return R({"reason": "bad_choice", "ok": False, "brands": list(V1.BRANDS),
                      "operators": list(V1.APN)}, status=400)
        from django.conf import settings
        ip = str(getattr(settings, "TRACKER_PUBLIC_IP", "16.4.105.173"))
        g = V1.setup_guide(brand, op, info["host"], info["port"], ip=ip,
                           password=str(q.get("password") or "")[:12])
        return R({**g, "server": info, "brands": list(V1.BRANDS),
                  "operators": list(V1.APN),
                  "pair_window_min": VS.vcfg()["pair_window_min"]})
