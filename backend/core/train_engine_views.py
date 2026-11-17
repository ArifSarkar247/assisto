"""train-engine — HTTP API of the live engine (Train Tracker V2). Flag
`train_tracker` (OFF). Stopping a trip is a privacy control: never gated.

  POST /train/<no>/trip      {date, cells}          anonymous trip token (shown once)
  POST /train/ping           {token, points:[..]}   rider points (<= 240 per batch)
  POST /train/trip/stop      {token}                one tap, never gated
  GET  /train/<no>/now?date=                        tiny gzip payload for 2G
  POST /train/<no>/checkin   {date, station_id, kind, at?, lat?, lng?, acc?}
  POST /train/<no>/onboard   {date, points:[..]}    "Are you on this train?" signal (not stored)
  POST /train/text           {text, no?, date?, source, at?, lat?, lng?, acc?}
                             any shared/pasted text; 200 with parsed=null when unplaceable
  POST /train/share-text     (same, alias)
  POST /train/sms16318       {text, no?, date?}     (same parser; app contract name)
  GET  /train/offline/meta                          {version, size_bytes, updated_at}
  GET  /train/offline/pack?have=<version>           gzip JSON {version, trains, towers}
  GET  /train/points                                my helper points (not money)
"""
import gzip
import json

from django.http import HttpResponse
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import train_engine as TE
from . import train_service as TS
from . import train_source as SRC
from .train_views import _bad, _off, flag_on

R = Response


def _train_date(no, raw_date):
    """The OFFICIAL train (all 322 directions) + a service date (yesterday ..
    tomorrow, Dhaka)."""
    t = SRC.train(no)
    if t is None:
        return None, None, _bad("unknown_train", 404)
    d = TS.parse_date(raw_date)
    if d is None:
        return t, None, _bad("bad_date")
    return t, d, None


def _date_or_today(raw):
    return raw or TS.today().isoformat()


class TripOpenView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, _date_or_today(request.data.get("date")))
        if err:
            return err
        token, trip = TE.open_trip(request.user, t, d, bool(request.data.get("cells")))
        if token is None:
            return _bad(trip, 429)
        return R({"ok": True, "token": token, "status": trip.status})


class PingView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        trip = TE.trip_by_token(request.data.get("token"))
        if trip is None:
            return _bad("not_found", 404)
        if not flag_on(request.user):
            trip.status = "ended"
            trip.save(update_fields=["status"])
            return R({"ok": True, "status": "ended"})
        pts = request.data.get("points")
        if not isinstance(pts, list):
            return _bad("bad_points")
        return R(dict(TE.ingest(trip, pts), ok=True))


class TripStopView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        trip = TE.trip_by_token(request.data.get("token"))
        if trip is None:
            return R({"ok": True, "status": "ended"})
        if trip.status == "active":
            trip.status = "ended"
            trip.save(update_fields=["status"])
        return R({"ok": True, "status": trip.status})


class NowView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, _date_or_today(request.query_params.get("date")))
        if err:
            return err
        raw = json.dumps(TE.read(t, d), separators=(",", ":"), ensure_ascii=False).encode()
        if "gzip" in (request.META.get("HTTP_ACCEPT_ENCODING") or "") and len(raw) > 200:
            resp = HttpResponse(gzip.compress(raw, 6), content_type="application/json")
            resp["Content-Encoding"] = "gzip"
        else:
            resp = HttpResponse(raw, content_type="application/json")
        resp["Cache-Control"] = "private, max-age=15"
        resp["Vary"] = "Accept-Encoding"
        return resp


class CheckinView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, no):
        if not flag_on(request.user):
            return _off()
        q = request.data
        t, d, err = _train_date(no, _date_or_today(q.get("date")))
        if err:
            return err
        out = TE.checkin(request.user, t, d, str(q.get("station_id") or ""),
                         str(q.get("kind") or ""), q.get("at"), q.get("lat"), q.get("lng"),
                         q.get("acc"))
        return R(out, status=200 if out["ok"] else (429 if out.get("reason") == "rate_limited"
                                                     else 400))


class OnboardView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, _date_or_today(request.data.get("date")))
        if err:
            return err
        pts = request.data.get("points")
        if not isinstance(pts, list):
            return _bad("bad_points")
        return R(dict(TE.onboard_check(t, d, pts), ok=True))


class ShareTextView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if not flag_on(request.user):
            return _off()
        q = request.data
        text = q.get("text")
        soft = request.path.rstrip("/").endswith("/train/text")   # 200 + parsed:null
        if not isinstance(text, str) or not text.strip() or len(text) > 2000:
            if soft:
                return R({"ok": True, "parsed": None, "applied": False, "reason": "unparsed"})
            return _bad("unparsed")
        no = str(q.get("no") or "").strip() or None
        d = None
        if q.get("date"):
            d = TS.parse_date(q.get("date"))
            if d is None:
                return _bad("bad_date")
        if no and SRC.train(no) is None:
            no = None
        code, body = TE.share_text(request.user, text, no=no, date=d, lat=q.get("lat"),
                                   lng=q.get("lng"), acc=q.get("acc"))
        if soft and code == 400:
            return R({"ok": True, "parsed": None, "applied": False, "reason": "unparsed"})
        return R(body, status=code)


class OfflineMetaView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not flag_on(request.user):
            return _off()
        meta, _ = TE.offline_pack()
        return R({k: meta[k] for k in ("version", "size_bytes", "updated_at")})


class OfflinePackView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not flag_on(request.user):
            return _off()
        meta, blob = TE.offline_pack()
        if request.query_params.get("have") == meta["version"]:
            return R({"version": meta["version"], "same": True})
        if "gzip" in (request.META.get("HTTP_ACCEPT_ENCODING") or ""):
            resp = HttpResponse(blob, content_type="application/json")
            resp["Content-Encoding"] = "gzip"
        else:
            resp = HttpResponse(gzip.decompress(blob), content_type="application/json")
        resp["Cache-Control"] = "private, max-age=3600"
        resp["Vary"] = "Accept-Encoding"
        return resp


class PointsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        return R({"ok": True, "points": TE.points_balance(request.user),
                  "money": False})
