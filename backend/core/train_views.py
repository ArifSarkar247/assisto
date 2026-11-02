"""train — Train Tracker HTTP API (owner priority C). Flag `train_tracker`
(OFF; owner / staff / allow-listed testers preview). Stopping a share and
leaving a chat are privacy controls and are NEVER flag-gated.

  GET  /train/config                         map tiles, SMS 16318, hotlines, data sources
  GET  /train/search?q=                      trains (number / name / station)
  GET  /train/<no>/live?date=YYYY-MM-DD      live (fused crowd) or estimate
  POST /train/<no>/share     {date}          "I am on this train"
  POST /train/share/<id>/fixes {points:[..]} validated server-side
  POST /train/share/<id>/stop                one tap (never gated)
  GET  /train/<no>/chat?date=&after=         nickname-only room
  POST /train/<no>/chat/join {date, nickname}
  POST /train/<no>/chat      {date, text}    -> emergency flag + 999 / 131
  POST /train/<no>/chat/leave {date}         (never gated)
  POST /train/chat/msg/<id>/report|block|circle
  POST /train/chat/request/<id>/accept|decline
"""
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import train_service as TS
from .logic import train_chat as TC
from .logic import train_geo as TG
from .models import TrainChatMessage, TrainCircleRequest, TrainShare

R = Response
FLAG = "train_tracker"


def flag_on(user, key=FLAG):
    try:
        from . import feature_flags as FF
        return bool(FF.is_on(key, user))
    except Exception:
        return False


def _off():
    return R({"ok": False, "reason": "feature_off"}, status=403)


def _bad(reason, status=400):
    return R({"ok": False, "reason": reason}, status=status)


def _train_date(no, raw_date):
    t = TG.train(no)
    if t is None:
        return None, None, _bad("unknown_train", 404)
    d = TS.parse_date(raw_date)
    if d is None:
        return t, None, _bad("bad_date")
    return t, d, None


class ConfigView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from .views_vehicle import map_config
        return R({"enabled": flag_on(request.user),
                  "dest_alarm": flag_on(request.user, "dest_alarm"),
                  "map": map_config(),
                  "attribution": "© OpenStreetMap contributors (ODbL)",
                  "sms": {"to": TC.SMS_TO, "cost_bdt": TC.SMS_COST_BDT},
                  "hotlines": {"police": TC.POLICE, "rail": TC.RAIL_HOTLINE},
                  "today": TS.today().isoformat(),
                  "data": TS.data_meta()})


class SearchView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        if not flag_on(request.user):
            return _off()
        return R({"trains": TS.search(request.query_params.get("q", ""))})


class LiveView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, request.query_params.get("date") or TS.today().isoformat())
        if err:
            return err
        return R(TS.live_view(t, d, request.user))


class ShareStartView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, request.data.get("date"))
        if err:
            return err
        s = TS.start_share(request.user, t, d)
        return R({"ok": True, "share": {"id": s.id, "status": s.status,
                                        "ends_at": s.ends_at.isoformat()}})


def _my_share(request, pk):
    return TrainShare.objects.filter(pk=pk, user=request.user).first()


class ShareFixesView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        s = _my_share(request, pk)
        if s is None:
            return _bad("not_found", 404)
        if not flag_on(request.user):
            TS.stop_share(s)
            return R({"ok": True, "status": s.status})
        pts = request.data.get("points")
        if not isinstance(pts, list):
            return _bad("bad_points")
        return R(dict(TS.add_fixes(s, pts), ok=True))


class ShareStopView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        s = _my_share(request, pk)
        if s is None:
            return _bad("not_found", 404)
        TS.stop_share(s)
        return R({"ok": True, "status": s.status})


class ChatView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, request.query_params.get("date"))
        if err:
            return err
        try:
            after = int(request.query_params.get("after") or 0)
        except ValueError:
            after = 0
        return R(TS.room(request.user, t["no"], d, after))

    def post(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, request.data.get("date"))
        if err:
            return err
        me = TS.member_of(request.user, t["no"], d)
        if me is None:
            return _bad("join_first", 409)
        m, why = TS.post(me, request.data.get("text"))
        if m is None:
            return _bad(why, 429 if why == "rate_limited" else 400)
        return R({"ok": True, "message": TS.msg_json(m, me), "emergency": m.emergency,
                  "hotlines": {"police": TC.POLICE, "rail": TC.RAIL_HOTLINE}})


class ChatJoinView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, no):
        if not flag_on(request.user):
            return _off()
        t, d, err = _train_date(no, request.data.get("date"))
        if err:
            return err
        m, why = TS.join(request.user, t, d, request.data.get("nickname"))
        if m is None:
            return _bad(why)
        return R({"ok": True, "me": {"nickname": m.nickname}})


class ChatLeaveView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, no):
        d = TS.parse_date(request.data.get("date"))
        if d is None:
            return _bad("bad_date")
        TS.leave(request.user, str(no), d)
        return R({"ok": True})


class MessageActionView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk, action):
        if not flag_on(request.user):
            return _off()
        m = TrainChatMessage.objects.filter(pk=pk).select_related("member").first()
        if m is None:
            return _bad("not_found", 404)
        me = TS.member_of(request.user, m.train_no, m.service_date)
        if me is None:
            return _bad("not_found", 404)   # outsiders learn nothing
        if action == "report":
            r = TS.report(request.user, m, request.data.get("reason"))
        elif action == "block":
            r = TS.block(request.user, m)
        elif action == "circle":
            _, r = TS.circle_request(me, m)
        else:
            return _bad("unknown_action", 404)
        if r != "ok":
            return _bad(r, 429 if r == "rate_limited" else 400)
        return R({"ok": True})


class RequestActView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request, pk, action):
        if action not in ("accept", "decline"):
            return _bad("unknown_action", 404)
        req = TrainCircleRequest.objects.filter(pk=pk).select_related(
            "from_member__user", "to_member").first()
        if req is None:
            return _bad("not_found", 404)
        r = TS.act_request(request.user, req, action == "accept")
        if r != "ok":
            return _bad(r, 404)
        return R({"ok": True, "state": req.state})
