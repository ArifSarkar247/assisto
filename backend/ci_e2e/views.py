"""CI-only endpoints (mounted by ci_e2e.urls under settings_e2eproof ONLY).

GET  /api/v1/ci-e2e/outbox?since=<ts>&kind=push|sms|ai|vision|maps&user=me|<id>
     -> {now, rows:[...]}   what the fakes "sent" (proof of delivery)
POST /api/v1/ci-e2e/tick {job, advance_min}
     -> runs one real server job with the clock moved forward (fake clock):
        job = push_due_reminders | carecall_tick | journey_sweep
              | ezviz_poll_alarms | cctv_connect_tick (camflows)
camflows (E2E_VENDOR_SIM=1, see vendor_sim.py):
POST /api/v1/ci-e2e/vendor-sim {op: add_device|push_alarm|repush|state, vendor, serial, ...}
GET  /api/v1/ci-e2e/hls/<vendor>/<serial>/<file>   the fake vendor HLS (phone plays it)
GET  /api/v1/ci-e2e/imou/h5?state=                 the fake Imou consent page
GET  /api/v1/ci-e2e/imou/h5/allow?state=           "Allow" -> our real redirect URI
plans-credits (fake_gateway.py — no money, no network):
POST /api/v1/ci-e2e/pay {op: on|off|drain}  or  {tx, result: paid|failed|cancelled|paid_wrong_amount}
"""
import io
import threading
import time
from datetime import timedelta
from unittest import mock

from django.core.management import call_command, get_commands
from django.utils import timezone
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from . import fakes

JOBS = ("push_due_reminders", "carecall_tick", "journey_sweep",
        "ezviz_poll_alarms", "cctv_connect_tick")  # camflows: the two CCTV cloud jobs
_TICK_LOCK = threading.Lock()


class OutboxView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        q = request.query_params
        try:
            since = float(q.get("since") or 0)
        except ValueError:
            since = 0.0
        who = q.get("user") or ""
        uid = request.user.pk if who == "me" else (int(who) if who.isdigit() else None)
        return Response({"now": time.time(),
                         "rows": fakes.read_outbox(since, q.get("kind") or "", uid)[-200:]})


class TickView(APIView):
    permission_classes = [IsAuthenticated]

    def post(self, request):
        job = str((request.data or {}).get("job") or "")
        if job not in JOBS:
            return Response({"ok": False, "reason": "unknown_job", "jobs": JOBS}, status=400)
        if job not in get_commands():
            return Response({"ok": False, "reason": "job_missing", "job": job}, status=404)
        try:
            adv = max(0, min(24 * 60, int((request.data or {}).get("advance_min") or 0)))
        except (TypeError, ValueError):
            adv = 0
        real_now = timezone.now
        fake_now = real_now() + timedelta(minutes=adv)
        out = io.StringIO()
        with _TICK_LOCK, mock.patch("django.utils.timezone.now", lambda: fake_now):
            call_command(job, stdout=out, stderr=out)
        fakes.record("tick", job=job, advance_min=adv, fake_now=fake_now.isoformat(),
                     out=out.getvalue()[-400:])
        return Response({"ok": True, "job": job, "fake_now": fake_now.isoformat(),
                         "output": out.getvalue()[-400:]})


# ---------------------------------------------------------------- camflows
class VendorSimView(APIView):
    """The test's handle on the fake vendor clouds (devices, alarms, state)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from . import vendor_sim as VS
        d = request.data or {}
        op = str(d.get("op") or "")
        vendor = str(d.get("vendor") or "")
        serial = str(d.get("serial") or "").upper()
        if vendor not in ("imou", "ezviz", "dolynk", "hikconnect") or not serial:
            return Response({"ok": False, "reason": "vendor_serial"}, status=400)
        if op == "add_device":
            out = VS.add_device(vendor, serial, str(d.get("code") or ""),
                                int(d.get("channels") or 1), d.get("name") or None,
                                bool(d.get("oauth_user")))
        elif op == "push_alarm":
            try:
                out = VS.push_alarm(vendor, serial, int(d.get("channel") or 0),
                                    str(d.get("kind") or "human"), str(d.get("deliver") or "store"))
            except KeyError:
                return Response({"ok": False, "reason": "unknown_device"}, status=404)
        elif op == "repush" and vendor == "dolynk":
            # flag-cctv-e2e: the vendor re-sends a message it thinks we missed
            try:
                out = VS.dolynk_repush(serial, str(d.get("msg_id") or ""))
            except (KeyError, IndexError):
                return Response({"ok": False, "reason": "unknown_device"}, status=404)
        elif op == "state":
            out = VS.state(vendor, serial)
        else:
            return Response({"ok": False, "reason": "unknown_op"}, status=400)
        fakes.record("vendor_sim", op=op, vendor=vendor, serial=serial, out=out)
        return Response(dict(out, ok=True))


class FakeHlsView(APIView):
    """A real HLS stream (ffmpeg test pattern in E2E_HLS_DIR) at the address
    the fake vendor cloud handed out. Every fetch is recorded: proof that the
    phone's player really opened the vendor stream."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request, vendor, serial, name):
        import os
        from django.http import HttpResponse, Http404
        from . import vendor_sim as VS
        base = os.environ.get("E2E_HLS_DIR", "")
        fn = "index.m3u8" if name.endswith(".m3u8") else name
        if not base or "/" in fn or ".." in fn:
            raise Http404()
        path = os.path.join(base, fn)
        if not os.path.isfile(path):
            raise Http404()
        VS.HITS["hls"].append("%s/%s/%s" % (vendor, serial.upper(), name))
        with open(path, "rb") as fh:
            body = fh.read()
        # flag-cctv-e2e: data use per live minute (what the phone downloaded)
        with VS._LOCK:
            VS.HITS["hls_bytes"][serial.upper()] = VS.HITS["hls_bytes"].get(serial.upper(), 0) + len(body)
        ctype = "application/vnd.apple.mpegurl" if fn.endswith(".m3u8") else "video/mp2t"
        resp = HttpResponse(body, content_type=ctype)
        resp["Cache-Control"] = "no-store"
        return resp


def _imou_redirect_uri():
    from django.conf import settings
    from core.logic.cctv_connect.imou import ImouAdapter
    return str(settings.ASSISTO_BASE_URL).rstrip("/") + ImouAdapter.oauth_redirect_path


class FakeImouH5View(APIView):
    """Stand-in for Imou's "User Authorization H5 Page" (the browser leg)."""
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from django.http import HttpResponse
        from django.utils.html import escape
        state = str(request.query_params.get("state") or "")[:128]
        html = ("<!doctype html><meta charset=utf-8><title>Imou Life (CI fake)</title>"
                "<h1>Imou Life</h1><p>Assisto Camera Link wants to see your cameras "
                "(device info, live, messages).</p>"
                "<a id=allow href='/api/v1/ci-e2e/imou/h5/allow?state=%s'>Allow</a> "
                "<a id=deny href='%s?error=access_denied&state=%s'>Deny</a>"
                % (escape(state), escape(_imou_redirect_uri()), escape(state)))
        return HttpResponse(html)


class FakeImouAllowView(APIView):
    permission_classes = [AllowAny]
    authentication_classes = []

    def get(self, request):
        from urllib.parse import urlencode
        from django.http import HttpResponseRedirect
        from . import vendor_sim as VS
        state = str(request.query_params.get("state") or "")[:128]
        code = VS.new_oauth_code()
        fakes.record("imou_h5_allow", state_len=len(state))
        return HttpResponseRedirect("%s?%s" % (_imou_redirect_uri(),
                                               urlencode({"code": code, "state": state})))


# ---------------------------------------------------------------- sjproof
class SjSimView(APIView):
    """sjproof: the Safe Journey V2 proof's fake-GPS clock (CI only).

    A real trip needs real minutes (2-minute dwell, 5-minute private ask,
    30-minute stop near the destination); the e2e cannot wait an hour per
    scenario. Like core/tests_sjduring.Sim, `replay` moves the CALLER's own
    journey back in time and feeds its fixes minute by minute through the
    same server code as POST /journey/<id>/location + the every-minute
    sweeper, each step at its own (fake) time. The app on the emulator then
    shows what the server decided (private ask, states, PIN, watcher board).

    POST /api/v1/ci-e2e/sj-sim
      {op: whoami}                       -> {me, name, peers:[{user_id, member_id, name}]}
      {op: replay, journey, minutes_ago, points:[[min, lat|null, lng|null, battery?]...]}
           (minutes_ago only on the first call: the trip then started that long ago)
      {op: maps, global_day: n|null}     -> autocomplete global day cap (null = default)
      {op: school, points:[[min_ago, lat, lng]...]}  (the caller = the child's phone)
      {op: train}                        -> 3 fake passengers on a train running now
    """
    permission_classes = [IsAuthenticated]

    def post(self, request):
        d = request.data or {}
        op = str(d.get("op") or "")
        fn = getattr(self, "_" + op, None) if op in ("whoami", "replay", "maps", "school",
                                                    "train") else None
        if fn is None:
            return Response({"ok": False, "reason": "unknown_op"}, status=400)
        with _TICK_LOCK:
            out = fn(request, d)
        if isinstance(out, Response):
            return out
        fakes.record("sj_sim", op=op, out={k: v for k, v in out.items() if k != "points"})
        return Response(dict(out, ok=True))

    def _whoami(self, request, d):
        from core.models import CircleMember
        rows = CircleMember.objects.filter(user=request.user, state="accepted",
                                           peer_user__isnull=False)
        return {"me": request.user.pk, "name": request.user.name,
                "peers": [{"user_id": m.peer_user_id, "member_id": m.pk,
                           "name": m.name or getattr(m.peer_user, "name", "")} for m in rows]}

    def _replay(self, request, d):
        from collections import Counter
        from core import journey_during as JDUR
        from core import journey_watch as JW
        from core.models import Journey, JourneyEvent, JourneyPoint
        j = Journey.objects.filter(traveller=request.user, pk=int(d.get("journey") or 0)).first()
        if j is None:
            return Response({"ok": False, "reason": "not_your_journey"}, status=404)
        now = timezone.now()
        ago = d.get("minutes_ago")
        if ago not in (None, ""):
            t0 = now - timedelta(minutes=max(0, min(600, int(ago))))
            shift = j.created_at - t0
            Journey.objects.filter(pk=j.pk).update(
                created_at=t0, eta=(j.eta - shift) if j.eta else None,
                expires_at=(j.expires_at - shift) if j.expires_at else None)
            # the phone's own fixes before the replay (if any) are not this story
            JourneyPoint.objects.filter(journey=j).delete()
            Journey.objects.filter(pk=j.pk).update(last_location=None, during={})
            j = Journey.objects.get(pk=j.pk)
        t0 = j.created_at
        for row in sorted(d.get("points") or [], key=lambda r: float(r[0])):
            t = t0 + timedelta(minutes=float(row[0]))
            if t > now + timedelta(seconds=5):
                break
            lat, lng = row[1], row[2]
            batt = int(row[3]) if len(row) > 3 and row[3] is not None else 80
            with mock.patch("django.utils.timezone.now", lambda t=t: t):
                if j.status == "active" and lat is not None:
                    JourneyPoint.objects.create(journey=j, lat=lat, lng=lng, battery=batt, at=t)
                    JW.on_location(j, lat, lng, t, batt, now=t)
                    j.last_location = JW.location_row(j.last_location, lat, lng, t, batt, "app")
                    j.last_activity_at = t
                    j.save()
                    if JDUR.enabled(j) and JDUR.auto_arrival(j, t, 10) == "arrived":
                        JW.on_arrived(j, t)
                        j.save()
                if j.status == "active":
                    JW._sweep_journey(j, t, Counter())
            j = Journey.objects.get(pk=j.pk)
        dur = j.during or {}
        return {"journey": j.pk, "status": j.status,
                "state": (dur.get("state") or {}).get("state"),
                "ask": dur.get("ask"), "pin_wait": dur.get("pin_wait"),
                "events": list(JourneyEvent.objects.filter(journey=j)
                               .values_list("kind", flat=True))}

    def _maps(self, request, d):
        from core import maps_cost
        v = d.get("global_day")
        n = maps_cost.DEFAULTS["autocomplete"]["global_day"] if v in (None, "") else int(v)
        maps_cost.save_config("autocomplete", {"global_day": n})
        return {"global_day": n}

    def _school(self, request, d):
        from core import kidswatch_service as KW
        from core import sj_live as SL
        now = timezone.now()
        n = 0
        for row in sorted(d.get("points") or [], key=lambda r: -float(r[0])):
            t = now - timedelta(minutes=float(row[0]))
            with mock.patch("django.utils.timezone.now", lambda t=t: t):
                n += SL.feed_school(request.user, [(t, row[1], row[2], 80, "gps", 10)], t)
        KW.tick(now)
        return {"events": n}

    def _train(self, request, d):
        """Three made-up passengers share a train that runs NOW (Dhaka), ten
        minutes late, for the last 20 minutes: every fix through the real
        validation. Returns the true position to check the fused one."""
        from datetime import timedelta as td
        import random
        from core import train_service as TS
        from core.logic import train_geo as TG
        from core.models import User
        now = timezone.now()
        delay = td(minutes=10)
        pick = None
        trains = TG.timetable()["trains"]
        trains = sorted(trains, key=lambda t: (0 if "express" in str(t.get("name", "")).lower()
                                               else 1, str(t.get("no"))))
        # today's trains first; at night an overnight train that left yesterday
        for day in (TS.today(), TS.today() - td(days=1)):
            for t in trains:
                rt = TG.route(t["no"])
                if rt is None or not TG.runs_on(t, day):
                    continue
                dep, arr = TG.times(t, day)
                if dep + delay + td(minutes=25) <= now <= arr + delay - td(minutes=20):
                    pick = (t, rt)
                    break
            if pick:
                break
        if pick is None:
            return Response({"ok": False, "reason": "no_train_running_now"}, status=409)
        t, rt = pick
        rng = random.Random(7)
        users = []
        for i in range(3):
            phone = "0199900000%d" % i
            u = User.objects.filter(phone=phone).first() or User.objects.create_user(
                name="Sample passenger %d" % i, phone=phone, password="ci-e2e-sample-%d" % i)
            users.append(u)
        shares = [TS.start_share(u, t, day, now=now - td(minutes=20)) for u in users]
        lags = (0.0, 120.0, 260.0)
        acc = 0
        for k in range(21):
            at = now - td(minutes=20 - k)
            for s, lag in zip(shares, lags):
                ch = max(0.0, TG.sched_chainage(t, rt, day, at - delay) - lag)
                lat, lng = rt.point_at(ch)
                lat += rng.uniform(-25, 25) / 111320.0
                with mock.patch("django.utils.timezone.now", lambda at=at: at):
                    r = TS.add_fixes(s, [{"lat": lat, "lng": lng, "acc": 20, "at": at.isoformat(),
                                          "speed_kmh": 60, "bearing": round(rt.heading_at(ch), 1)}],
                                     now=at)
                acc += int(r.get("accepted") or 0)
        true_ch = TG.sched_chainage(t, rt, day, now - delay)
        v = TS.live_view(t, day, None, now=now)
        live = v.get("live") or {}
        err = abs(float(live.get("chainage_m", 1e9)) - true_ch) if live else None
        return {"no": t["no"], "name": t.get("name", ""), "date": day.isoformat(),
                "accepted": acc, "sharers": v.get("sharers"), "mode": v.get("mode"),
                "true_chainage_m": round(true_ch), "error_m": None if err is None else round(err)}


# ---------------------------------------------------------------- train-e2e
class TrainSimView(APIView):
    """train-e2e: fake clock + scripted riders for the Train Tracker E2E
    (ci_e2e/train_sim.py). Every rider point still goes through the real
    /train endpoints; this only generates points and reads back state."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from . import train_sim as TSIM
        d = request.data or {}
        op = str(d.get("op") or "")
        fn = TSIM.OPS.get(op)
        if fn is None:
            return Response({"ok": False, "reason": "unknown_op", "ops": sorted(TSIM.OPS)},
                            status=400)
        try:
            with _TICK_LOCK:
                out = fn(d)
        except (ValueError, KeyError) as e:
            return Response({"ok": False, "reason": str(e)[:200]}, status=400)
        if out.get("ok") is False:
            return Response(out, status=409)
        fakes.record("train_sim", op=op, out={k: v for k, v in out.items()
                                              if k not in ("riders", "outlier", "stations")})
        return Response(dict(out, ok=True))
# ---------------------------------------------------------------- plans-credits
class FakePayView(APIView):
    """The e2e flow's handle on the CI fake gateway: switch it on/off, and
    say what the 'bank' answers for one order (by its merchant tx id, which
    only the order's owner can see in its redirect URL)."""
    permission_classes = [IsAuthenticated]

    def post(self, request):
        from core.models import PaymentOrder

        from . import fake_gateway as FG
        d = request.data or {}
        op = str(d.get("op") or "")
        if op in ("on", "off"):
            FG.set_on(op == "on")
            return Response({"ok": True, "on": op == "on"})
        if op == "drain":
            # "use the app until the credits run out", in one call: the REAL
            # spend path (core.credits.spend, owner's bucket order + ledger)
            # takes every usable credit of THIS user — nothing is faked.
            from core import credits as CR
            n = int(CR.state(request.user)["now_usable"])
            r = CR.spend(request.user, n, note="ci_drain") if n > 0 else {"ok": True, "charged": 0}
            left = int(CR.state(request.user)["now_usable"])
            fakes.record("pay_drain", user_id=request.user.pk, spent=n, left=left)
            return Response({"ok": bool(r.get("ok")), "spent": n, "now_usable": left})
        tx = str(d.get("tx") or "")
        res = str(d.get("result") or "")
        if res not in FG.RESULTS or not PaymentOrder.objects.filter(
                merchant_tx_id=tx, user=request.user).exists():
            return Response({"ok": False, "reason": "tx_or_result"}, status=400)
        FG.set_result(tx, res)
        return Response({"ok": True, "tx": tx, "result": res})
