"""journey100 — Safe Journey to 100: sweeper transitions, watcher recipients,
idempotency + rate limits, extend / respond / duress / SOS cancel, offline
batches, low battery, prolonged stop, off route, signal lost, wellness,
check-ins, routines, ride photo, the public watcher page (token expiry,
honest states, noindex, rate limit, bn/en) and the privacy auto-delete."""
import base64
import io
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import journey_watch as JW
from core.models import (CircleMember, FamilyAlert, Journey, JourneyEvent,
                         JourneyPoint, JourneyRoutine, JourneyWatcher,
                         NotifEvent, SafetyCheckin, User, WellnessWatch)

V = "/api/v1"
HOME = {"name": "Home", "lat": 23.8000, "lng": 90.4000}
ORIGIN = {"name": "Office", "lat": 23.7500, "lng": 90.3900}


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang)


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def edge(a, b, **kw):
    return CircleMember.objects.create(user=a, peer_user=b, name=b.name,
                                       state=kw.pop("state", "accepted"), **kw)


class PushSpy:
    """Records core.push.safe_push / hook_sos calls (FCM is never hit)."""

    def __init__(self):
        self.calls, self.sos = [], []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "ben": ben,
                           "tbn": tbn, "bbn": bbn, "data": data or {},
                           "high": kw.get("high_priority", False)})
        return True

    def hook_sos(self, user, lat=None, lng=None, silent=False, journey_id=None, **kw):
        self.sos.append({"user": user.pk, "silent": silent, "journey_id": journey_id,
                         "lat": lat})
        return True

    def to(self, user):
        return [c for c in self.calls if c["user"] == user.pk]


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.a = mk("01711000001", "Rina")
        self.b = mk("01711000002", "Mother", lang="bn")
        self.c = mk("01711000003", "Stranger")
        self.ab = edge(self.a, self.b)
        self.ca, self.cb, self.cc = cl(self.a), cl(self.b), cl(self.c)
        self.spy = PushSpy()
        p1 = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p2 = mock.patch("core.push.hook_sos", side_effect=self.spy.hook_sos)
        p1.start(), p2.start()
        self.addCleanup(p1.stop)
        self.addCleanup(p2.stop)

    def start(self, eta_min=30, **kw):
        body = {"destination": HOME, "origin": ORIGIN,
                "eta": (timezone.now() + timedelta(minutes=eta_min)).isoformat(),
                "watcher_ids": [self.ab.id], "overdue_grace_min": 10,
                "location_retention_hours": 24}
        body.update(kw)
        r = self.ca.post("%s/journey/start" % V, body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        # started a while ago, so back-dated fixes (offline queue) are in-trip
        Journey.objects.filter(pk=r.json()["id"]).update(
            created_at=timezone.now() - timedelta(minutes=45))
        return Journey.objects.get(pk=r.json()["id"]), r.json()

    def fix(self, j, lat, lng, battery=None, at=None):
        p = {"lat": lat, "lng": lng}
        if battery is not None:
            p["battery"] = battery
        if at is not None:
            p["at"] = at.isoformat()
        return self.ca.post("%s/journey/%d/location" % (V, j.id), p, format="json")

    def events(self, j, kind=None):
        q = JourneyEvent.objects.filter(journey=j)
        return list(q.filter(kind=kind) if kind else q)


class StartArriveTests(Base):
    def test_start_pushes_watcher_with_live_link(self):
        j, body = self.start(vehicle={"plate": "DHA-11-2233", "mode": "cng"})
        self.assertTrue(body["web_link"].startswith("https://"))
        self.assertIn("/j/", body["web_link"])
        self.assertEqual(body["watchers"], 1)
        ev = self.events(j, "started")
        self.assertEqual(len(ev), 1)
        self.assertEqual(ev[0].recipients, 1)
        pb = self.spy.to(self.b)
        self.assertEqual(len(pb), 1)
        self.assertEqual(pb[0]["data"]["route"], "journey/watch")
        self.assertEqual(pb[0]["data"]["journey_id"], j.id)
        self.assertIn("Rina", pb[0]["ten"] + pb[0]["ben"])
        self.assertEqual(self.spy.to(self.a), [])          # never the traveller
        n = NotifEvent.objects.get(user=self.b, type="safe_journey")
        import re
        self.assertNotRegex(re.sub(r"https?://\S+", "", n.body_bn), r"[0-9]")  # Bangla digits
        self.assertFalse(FamilyAlert.objects.filter(user=self.b).exists())  # info only

    def test_watcher_rules_blocked_pending_strangers(self):
        d = mk("01711000004", "Blocked")
        e = mk("01711000005", "Pending")
        bd = edge(self.a, d, blocked=True)
        pe = edge(self.a, e, state="pending")
        foreign = edge(self.c, self.b)                       # not A's member
        j, body = self.start(watcher_ids=[self.ab.id, bd.id, pe.id, foreign.id])
        self.assertEqual(body["watchers"], 1)
        self.assertEqual({c["user"] for c in self.spy.calls}, {self.b.pk})

    def test_watcher_cap_and_daily_cap(self):
        r = self.ca.post("%s/journey/start" % V, {
            "destination": HOME, "watcher_ids": list(range(1, JW.MAX_WATCHERS + 2))},
            format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["detail"], "too_many_watchers")
        with mock.patch.object(JW, "DAILY_JOURNEY_CAP", 2):
            self.start(), self.start()
            r = self.ca.post("%s/journey/start" % V, {"destination": HOME}, format="json")
            self.assertEqual(r.status_code, 429)

    def test_one_active_journey_at_a_time(self):
        j1, _ = self.start()
        j2, _ = self.start()
        j1.refresh_from_db()
        self.assertEqual(j1.status, "stopped")
        self.assertEqual(self.ca.get("%s/journey/active" % V).json()["id"], j2.id)

    def test_live_then_geofence_arrival_pushes_and_ends(self):
        j, _ = self.start()
        r = self.fix(j, 23.7600, 90.3920, battery=80).json()
        self.assertEqual(r["status"], "active")
        self.assertEqual(r["overdue_state"], "on_time")
        r = self.fix(j, 23.80005, 90.40005).json()
        self.assertTrue(r["arrived"])
        j.refresh_from_db()
        self.assertEqual(j.status, "arrived")
        self.assertIsNotNone(j.stopped_at)
        self.assertAlmostEqual((j.expires_at - j.stopped_at).total_seconds(), 24 * 3600, delta=5)
        self.assertEqual(len(self.events(j, "arrived")), 1)
        # the phone's next post learns the journey is over (stops its service)
        r = self.fix(j, 23.8, 90.4).json()
        self.assertEqual(r["status"], "arrived")
        self.assertEqual(r["accepted"], 0)
        # manual "I'm safe" afterwards never re-sends
        self.ca.post("%s/journey/%d/arrived" % (V, j.id), {}, format="json")
        self.assertEqual(len(self.events(j, "arrived")), 1)

    def test_offline_batch_store_and_forward(self):
        j, _ = self.start()
        now = timezone.now()
        pts = [{"lat": 23.751 + i * 0.001, "lng": 90.39, "battery": 60,
                "at": (now - timedelta(minutes=10 - i)).isoformat()} for i in range(5)]
        pts.append({"lat": 999, "lng": 0})                                   # junk dropped
        pts.append({"lat": 23.7, "lng": 90.3, "at": (now - timedelta(days=2)).isoformat()})  # pre-trip
        r = self.ca.post("%s/journey/%d/location" % (V, j.id), {"points": pts},
                         format="json").json()
        self.assertEqual(r["accepted"], 5)
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 5)
        j.refresh_from_db()
        self.assertAlmostEqual(j.last_location["lat"], 23.755, places=4)   # newest wins

    def test_low_battery_alert_once_per_step(self):
        j, _ = self.start()
        for b in (40, 14, 13, 12, 9, 8):
            self.fix(j, 23.76, 90.392, battery=b)
        self.assertEqual([e.payload["battery"] for e in self.events(j, "low_battery")], [14, 9])
        self.assertTrue(FamilyAlert.objects.filter(user=self.b, kind="journey").exists())


class SweeperTests(Base):
    def test_overdue_ask_then_escalate_idempotent_and_capped(self):
        j, _ = self.start(eta_min=-1)
        self.fix(j, 23.76, 90.392)
        Journey.objects.filter(pk=j.pk).update(eta=timezone.now() - timedelta(minutes=12))
        self.spy.calls.clear()
        JW.sweep()
        ask = [c for c in self.spy.to(self.a) if c["data"].get("event") == "overdue_ask"]
        self.assertEqual(len(ask), 1)
        self.assertEqual(ask[0]["data"]["route"], "journey")
        JW.sweep()                                              # idempotent
        self.assertEqual(len([c for c in self.spy.to(self.a)
                              if c["data"].get("event") == "overdue_ask"]), 1)
        self.assertEqual(self.events(j, "overdue_alert"), [])
        # response window (10 min) over -> watchers alerted, once per sweep
        now = timezone.now() + timedelta(minutes=10)
        JW.sweep(now=now)
        JW.sweep(now=now)
        self.assertEqual(len(self.events(j, "overdue_alert")), 1)
        fa = FamilyAlert.objects.filter(user=self.b, kind="journey", dismissed=False)
        self.assertEqual(fa.count(), 1)
        pb = [c for c in self.spy.to(self.b) if c["data"]["event"] == "overdue_alert"]
        self.assertTrue(pb[0]["high"])
        # repeats every 15 min, never more than MAX_ESCALATIONS
        for k in range(1, 6):
            JW.sweep(now=now + timedelta(minutes=15 * k + 1))
        self.assertEqual(len(self.events(j, "overdue_alert")), JW.MAX_ESCALATIONS)

    def test_im_ok_after_escalation_tells_watchers_and_clears(self):
        j, _ = self.start(eta_min=-30)
        JW.sweep()
        self.assertEqual(len(self.events(j, "overdue_alert")), 1)
        r = self.ca.post("%s/journey/%d/respond" % (V, j.id), {"ok": True}, format="json").json()
        self.assertNotIn(r["overdue_state"], ("ask", "alert"))
        self.assertEqual(len(self.events(j, "ok_again")), 1)
        self.assertFalse(FamilyAlert.objects.filter(user=self.b, kind="journey",
                                                    dismissed=False).exists())
        JW.sweep()
        self.assertEqual(len(self.events(j, "overdue_alert")), 1)

    def test_extend_moves_deadline_and_tells_watchers(self):
        j, _ = self.start(eta_min=5)
        r = self.ca.post("%s/journey/%d/extend" % (V, j.id), {"minutes": 20}, format="json")
        self.assertEqual(r.status_code, 200)
        j2 = Journey.objects.get(pk=j.pk)
        self.assertAlmostEqual((j2.eta - j.eta).total_seconds(), 20 * 60, delta=2)
        self.assertEqual(len(self.events(j, "extended")), 1)
        self.assertEqual(r.json()["extend_left"], JW.MAX_EXTENSIONS - 1)
        for _ in range(JW.MAX_EXTENSIONS - 1):
            self.ca.post("%s/journey/%d/extend" % (V, j.id), {"minutes": 5}, format="json")
        r = self.ca.post("%s/journey/%d/extend" % (V, j.id), {"minutes": 5}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(self.cc.post("%s/journey/%d/extend" % (V, j.id), {},
                                      format="json").status_code, 404)

    def test_night_grace_is_tighter(self):
        j, _ = self.start(eta_min=-8, night=True)     # 8 min late, grace 10 -> night 7
        self.assertEqual(JW.overdue(Journey.objects.get(pk=j.pk), timezone.now())[0], "ask")
        j2, _ = self.start(eta_min=-8)
        self.assertEqual(JW.overdue(Journey.objects.get(pk=j2.pk), timezone.now())[0], "grace")

    def test_prolonged_stop_once_per_stop(self):
        j, _ = self.start(eta_min=120, stop_alert_min=20)
        self.fix(j, 23.76, 90.392)
        Journey.objects.filter(pk=j.pk).update(moved_at=timezone.now() - timedelta(minutes=25))
        self.fix(j, 23.76002, 90.39201)               # still there (< 60 m)
        JW.sweep()
        JW.sweep()
        self.assertEqual(len(self.events(j, "long_stop")), 1)
        self.fix(j, 23.77, 90.395)                     # moves on: clock resets
        JW.sweep()
        self.assertEqual(len(self.events(j, "long_stop")), 1)

    def test_off_route_corridor_and_planned_route(self):
        j, _ = self.start(eta_min=120, route_deviation_on=True)
        self.fix(j, 23.775, 90.395)                    # on the corridor
        JW.sweep()
        self.assertEqual(self.events(j, "off_route"), [])
        self.fix(j, 23.775, 90.47)                     # ~7 km east
        JW.sweep()
        JW.sweep()
        ev = self.events(j, "off_route")
        self.assertEqual(len(ev), 1)
        self.assertGreater(ev[0].payload["meters"], 3000)
        # planned route polyline
        j2, _ = self.start(eta_min=120, route_deviation_on=True,
                           planned_route=[{"lat": 23.75, "lng": 90.39}, {"lat": 23.75, "lng": 90.42},
                                          {"lat": 23.80, "lng": 90.42}])
        self.fix(j2, 23.7505, 90.405)                  # on the first leg
        JW.sweep()
        self.assertEqual(self.events(j2, "off_route"), [])
        off, d, thr = JW.offroute(Journey.objects.get(pk=j2.pk), 23.78, 90.39)
        self.assertTrue(off)

    def test_off_route_off_when_switch_off(self):
        j, _ = self.start(eta_min=120)
        self.fix(j, 23.775, 90.47)
        JW.sweep()
        self.assertEqual(self.events(j, "off_route"), [])

    def test_signal_lost_once_per_silence(self):
        j, _ = self.start(eta_min=120)
        self.fix(j, 23.76, 90.392, at=timezone.now() - timedelta(minutes=20))
        JW.sweep()
        JW.sweep()
        self.assertEqual(len(self.events(j, "signal_lost")), 1)
        self.fix(j, 23.761, 90.392)                    # back
        JW.sweep()
        JW.sweep(now=timezone.now() + timedelta(minutes=JW.LOST_FIX_MIN + 1))
        self.assertEqual(len(self.events(j, "signal_lost")), 2)

    def test_retry_undelivered_event(self):
        j, _ = self.start()
        ev = JourneyEvent.objects.create(journey=j, kind="extended", key="x",
                                         payload={"minutes": 5})
        JW.sweep()
        ev.refresh_from_db()
        self.assertIsNotNone(ev.delivered_at)
        self.assertEqual(ev.recipients, 1)

    def test_watcher_hourly_rate_limit_spares_emergencies(self):
        j, _ = self.start(eta_min=120)
        with mock.patch.object(JW, "WATCHER_HOURLY_CAP", 2):
            for i in range(5):
                JW.emit(j, "extended", key="r%d" % i, payload={"minutes": 5})
            JW.emit(j, "overdue_alert", key="r", payload={"minutes": 3})
        kinds = [c["data"]["event"] for c in self.spy.to(self.b)]
        self.assertEqual(kinds.count("extended"), 1)    # 'started' used one slot
        self.assertIn("overdue_alert", kinds)


class DuressSosTests(Base):
    def setUp(self):
        super().setUp()
        self.ca.post("%s/journey/duress-pin" % V, {"pin": "1234", "duress_pin": "9876"},
                     format="json")

    def test_pin_status_and_validation(self):
        self.assertTrue(self.ca.get("%s/journey/duress-pin" % V).json()["configured"])
        self.assertFalse(self.cb.get("%s/journey/duress-pin" % V).json()["configured"])
        bad = self.ca.post("%s/journey/duress-pin" % V, {"pin": "12", "duress_pin": "34"},
                           format="json")
        self.assertEqual(bad.status_code, 400)

    def test_stop_needs_pin_wrong_pin_stays(self):
        j, body = self.start()
        self.assertTrue(body["pin_required"])
        r = self.ca.post("%s/journey/%d/stop" % (V, j.id), {}, format="json")
        self.assertEqual(r.json()["pin"], "required")
        r = self.ca.post("%s/journey/%d/stop" % (V, j.id), {"pin": "0000"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(Journey.objects.get(pk=j.pk).status, "active")

    def test_normal_vs_duress_look_identical(self):
        j1, _ = self.start()
        r1 = self.ca.post("%s/journey/%d/stop" % (V, j1.id), {"pin": "1234"}, format="json")
        self.assertEqual(len(self.events(j1, "ended")), 1)
        self.assertEqual(self.spy.sos, [])
        j2, _ = self.start()
        self.fix(j2, 23.76, 90.392)
        r2 = self.ca.post("%s/journey/%d/stop" % (V, j2.id), {"pin": "9876"}, format="json")
        self.assertEqual(r1.status_code, r2.status_code)
        self.assertEqual(r1.json(), r2.json())
        j2.refresh_from_db()
        self.assertTrue(j2.sos_active and j2.silent)
        self.assertEqual(j2.status, "stopped")
        self.assertEqual(self.spy.sos, [{"user": self.a.pk, "silent": True,
                                         "journey_id": j2.id, "lat": 23.76}])
        self.assertEqual(len(self.events(j2, "duress")), 1)
        self.assertEqual(self.events(j2, "ended"), [])
        self.assertTrue(FamilyAlert.objects.filter(user=self.b, kind="journey",
                                                   payload__event="duress").exists())
        # nothing on the traveller's own screens gives it away
        self.assertEqual(self.spy.to(self.a), [])
        tl = self.ca.get("%s/journey/%d/timeline" % (V, j2.id)).json()
        self.assertNotIn("duress", [e["kind"] for e in tl["events"]])
        self.assertNotIn("sos", [e["kind"] for e in tl["events"]])
        # the watcher's page keeps showing the SOS with the last location
        from web.views_journey import public_state
        st, _ = public_state(JW.web_token(j2))
        self.assertEqual(st["state"], "sos")
        self.assertEqual(st["lat"], 23.76)

    def test_sos_cancel_pin_paths(self):
        r = self.ca.post("%s/journey/sos/cancel" % V, {}, format="json")
        self.assertEqual(r.json()["pin"], "required")
        r = self.ca.post("%s/journey/sos/cancel" % V, {"pin": "5555"}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.ca.post("%s/journey/sos/cancel" % V, {"pin": "1234"}, format="json")
        self.assertEqual(r.json()["outcome"], "cancel")
        self.assertEqual(self.spy.sos, [])
        j, _ = self.start()
        r2 = self.ca.post("%s/journey/sos/cancel" % V, {"pin": "9876", "journey_id": j.id,
                                                      "lat": 23.7, "lng": 90.4}, format="json")
        self.assertEqual(r.json(), r2.json())
        self.assertEqual(len(self.spy.sos), 1)
        self.assertTrue(self.spy.sos[0]["silent"])
        self.assertEqual(Journey.objects.get(pk=j.pk).status, "active")   # SOS cancel != stop
        # no PIN set: cancel is just a cancel
        self.assertEqual(self.cb.post("%s/journey/sos/cancel" % V, {}, format="json")
                         .json()["outcome"], "cancel")

    def test_wrong_pin_lockout(self):
        for _ in range(8):
            self.ca.post("%s/journey/sos/cancel" % V, {"pin": "0000"}, format="json")
        r = self.ca.post("%s/journey/sos/cancel" % V, {"pin": "1234"}, format="json")
        self.assertEqual(r.status_code, 429)

    def test_sos_is_free_and_reaches_family(self):
        j, _ = self.start()
        credits = User.objects.get(pk=self.a.pk).ai_credits
        r = self.ca.post("%s/journey/sos" % V, {"journey_id": j.id, "lat": 23.7, "lng": 90.4},
                         format="json")
        self.assertTrue(r.json()["web_link"])
        self.assertEqual(self.spy.sos[0]["silent"], False)
        self.assertEqual(User.objects.get(pk=self.a.pk).ai_credits, credits)


class WatchPageTests(Base):
    def page(self, token, lang=""):
        return self.client.get("/j/%s%s" % (token, "?lang=en" if lang == "en" else ""))

    def data(self, token):
        return self.client.get("/j/%s/data" % token)

    def test_live_stale_lost_states_and_headers(self):
        j, _ = self.start()
        tok = JW.web_token(j)
        self.assertEqual(self.data(tok).json()["state"], "waiting")
        self.fix(j, 23.76, 90.392, battery=55)
        d = self.data(tok)
        self.assertEqual(d.json()["state"], "live")
        self.assertEqual(d.json()["lat"], 23.76)
        self.assertEqual(d["X-Robots-Tag"], "noindex, nofollow")
        self.assertEqual(d["Cache-Control"], "no-store")
        Journey.objects.filter(pk=j.pk).update(last_location={
            "lat": 23.76, "lng": 90.392, "at": (timezone.now() - timedelta(minutes=5)).isoformat()})
        self.assertEqual(self.data(tok).json()["state"], "stale")
        Journey.objects.filter(pk=j.pk).update(last_location={
            "lat": 23.76, "lng": 90.392, "at": (timezone.now() - timedelta(minutes=40)).isoformat()})
        self.assertEqual(self.data(tok).json()["state"], "lost")
        p = self.page(tok)
        self.assertEqual(p.status_code, 200)
        self.assertEqual(p["X-Robots-Tag"], "noindex, nofollow")
        html = p.content.decode()
        self.assertIn("লাইভ যাত্রা", html)
        self.assertIn('lang="bn"', html)
        self.assertNotIn("tile.openstreetmap.org", html)
        en = self.page(tok, "en").content.decode()
        self.assertIn("Live journey", en)
        main = en.split("<main>")[1].split("<script")[0]   # (header = language switch)
        self.assertNotRegex(main, "[\u0980-\u09FF]")
        self.assertNotIn("journey100", en)                   # template comment not leaked

    def test_no_location_after_arrival_or_expiry_and_bad_tokens(self):
        j, _ = self.start()
        tok = JW.web_token(j)
        self.fix(j, 23.76, 90.392)
        self.ca.post("%s/journey/%d/arrived" % (V, j.id), {}, format="json")
        d = self.data(tok).json()
        self.assertEqual(d["state"], "arrived")
        self.assertNotIn("lat", d)
        Journey.objects.filter(pk=j.pk).update(expires_at=timezone.now() - timedelta(seconds=1))
        d = self.data(tok).json()
        self.assertEqual(d, {"state": "expired"})
        self.assertEqual(self.data("1.2.3").status_code, 404)
        forged = tok.rsplit(".", 1)[0] + ".000000000000000000000000"
        self.assertEqual(self.data(forged).status_code, 404)
        self.assertEqual(self.page(forged).status_code, 404)

    def test_link_life_ends_for_finished_trip(self):
        j, _ = self.start()
        tok = JW.web_token(j)
        Journey.objects.filter(pk=j.pk).update(
            status="stopped", stopped_at=timezone.now(),
            expires_at=timezone.now() + timedelta(days=5))
        later = timezone.now() + timedelta(hours=JW.LINK_HOURS + 1)
        from web.views_journey import public_state
        self.assertEqual(public_state(tok, now=later)[0], {"state": "expired"})
        self.assertEqual(public_state(tok)[0]["state"], "ended")

    def test_rate_limited(self):
        j, _ = self.start()
        tok = JW.web_token(j)
        codes = [self.data(tok).status_code for _ in range(45)]
        self.assertIn(429, codes)

    @override_settings(MAP_TILE_URL="https://tile.openstreetmap.org/{z}/{x}/{y}.png")
    def test_never_osm_tiles(self):
        self.assertEqual(JW.tile_config()["tile_url"], "")

    @override_settings(MAP_TILE_URL="https://maps.example.com/{z}/{x}/{y}.png?key=k")
    def test_configured_tiles_reach_page(self):
        j, _ = self.start()
        self.fix(j, 23.76, 90.392)
        html = self.page(JW.web_token(j)).content.decode()
        self.assertIn("maps.example.com", html)

    def test_watcher_in_app_list(self):
        j, _ = self.start()
        self.fix(j, 23.76, 90.392, battery=70)
        r = self.cb.get("%s/journey/watching" % V).json()["journeys"]
        self.assertEqual(len(r), 1)
        self.assertEqual(r[0]["lat"], 23.76)
        self.assertEqual(r[0]["name"], "Rina")
        self.assertTrue(r[0]["url"].startswith("https://"))
        self.assertEqual(self.cc.get("%s/journey/watching" % V).json()["journeys"], [])


class PrivacyAndExtrasTests(Base):
    def _png(self):
        from PIL import Image
        buf = io.BytesIO()
        Image.new("RGB", (40, 30), (200, 10, 10)).save(buf, "PNG")
        return base64.b64encode(buf.getvalue()).decode()

    def test_vehicle_photo_reencoded_shared_and_purged(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp, override_settings(MEDIA_ROOT=tmp):
            j, _ = self.start()
            r = self.ca.post("%s/journey/%d/vehicle-photo" % (V, j.id),
                             {"image_b64": self._png(), "plate": "DHA-1"}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            self.assertTrue(r.json()["photo_url"].startswith("/api/v1/m/"))
            j.refresh_from_db()
            self.assertTrue(j.vehicle_photo.name.endswith(".jpg"))
            self.assertEqual(len(self.events(j, "vehicle")), 1)
            bad = self.ca.post("%s/journey/%d/vehicle-photo" % (V, j.id),
                               {"image_b64": "bm90IGFuIGltYWdl"}, format="json")
            self.assertEqual(bad.status_code, 400)
            self.fix(j, 23.76, 90.392)
            Journey.objects.filter(pk=j.pk).update(expires_at=timezone.now() - timedelta(minutes=1))
            stats = JW.sweep()
            j.refresh_from_db()
            self.assertEqual(stats.get("expired", 0) + stats.get("purged", 0), 1)
            self.assertFalse(j.vehicle_photo)
            self.assertIsNone(j.last_location)
            self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)

    def test_retention_zero_deletes_on_next_sweep_and_hard_cap(self):
        j, _ = self.start(location_retention_hours=0)
        self.fix(j, 23.76, 90.392)
        self.ca.post("%s/journey/%d/stop" % (V, j.id), {}, format="json")
        JW.sweep(now=timezone.now() + timedelta(seconds=5))
        self.assertEqual(JourneyPoint.objects.filter(journey=j).count(), 0)
        j2, _ = self.start(location_retention_hours=168)
        JourneyPoint.objects.create(journey=j2, lat=1, lng=1,
                                    at=timezone.now() - timedelta(days=JW.TRAIL_MAX_DAYS + 1))
        JW.sweep()
        self.assertEqual(JourneyPoint.objects.filter(journey=j2).count(), 0)

    def test_wellness_prompt_then_family_alert_and_ping_resets(self):
        w = WellnessWatch.objects.create(parent=self.a, enabled=True, parent_opt_in=True,
                                         period_hours=2, response_window=30,
                                         quiet_start="00:00", quiet_end="00:00",
                                         last_activity_at=timezone.now() - timedelta(hours=3))
        JW.sweep()
        w.refresh_from_db()
        self.assertIsNotNone(w.prompt_sent_at)
        self.assertEqual([c["data"]["event"] for c in self.spy.to(self.a)], ["wellness_prompt"])
        JW.sweep(now=timezone.now() + timedelta(minutes=31))
        JW.sweep(now=timezone.now() + timedelta(minutes=32))
        self.assertEqual(len([c for c in self.spy.to(self.b)
                              if c["data"]["event"] == "wellness_alert"]), 1)
        self.ca.post("%s/journey/wellness/ping" % V, {}, format="json")
        w.refresh_from_db()
        self.assertIsNone(w.prompt_sent_at)
        self.assertIsNone(w.alert_sent_at)

    def test_overdue_checkin_reaches_family_once(self):
        SafetyCheckin.objects.create(user=self.a, place="Uttara",
                                     eta=timezone.now() - timedelta(minutes=40))
        JW.sweep()
        JW.sweep()
        rows = FamilyAlert.objects.filter(user=self.b, payload__event="checkin_overdue")
        self.assertEqual(rows.count(), 1)

    def test_routine_api_and_reminder_once(self):
        r = self.ca.post("%s/journey/routines" % V, {"days": ["xyz"], "time": "21:00"},
                         format="json")
        self.assertEqual(r.status_code, 400)
        local = timezone.localtime(timezone.now())
        day = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"][local.weekday()]
        home_by = local + timedelta(minutes=30)          # reminder fires now
        if home_by.date() != local.date():
            self.skipTest("too close to midnight for a same-day routine")
        r = self.ca.post("%s/journey/routines" % V, {
            "days": [day], "time": home_by.strftime("%H:%M"), "minutes": 30,
            "destination": {"name": "Home"}, "watcher_ids": [self.ab.id]}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(len(self.ca.get("%s/journey/routines" % V).json()["routines"]), 1)
        JW.sweep()
        JW.sweep()
        self.assertEqual(len([c for c in self.spy.to(self.a)
                              if c["data"]["event"] == "routine"]), 1)
        rid = r.json()["id"]
        self.assertEqual(self.cc.delete("%s/journey/routines/%d" % (V, rid)).status_code, 404)
        self.assertEqual(self.ca.delete("%s/journey/routines/%d" % (V, rid)).status_code, 200)
        self.assertEqual(JourneyRoutine.objects.count(), 0)

    def test_nearest_help_real_or_honest(self):
        rows = [{"name": "Gulshan PS", "lat": 23.79, "lon": 90.41, "distance_m": 900}]
        with mock.patch("core.nearby.search", return_value=(rows, "osm")):
            r = self.ca.get("%s/journey/nearest-help?lat=23.78&lon=90.41" % V).json()
        self.assertEqual(r["police"][0]["name"], "Gulshan PS")
        self.assertIn("directions", r["police"][0])
        self.assertEqual(r["state"], "ok")
        self.assertEqual([h["number"] for h in r["helplines"]], ["999", "109"])
        with mock.patch("core.nearby.search", side_effect=OSError("down")):
            r = self.ca.get("%s/journey/nearest-help?lat=23.78&lon=90.41" % V).json()
        self.assertEqual(r["state"], "failed")
        self.assertEqual(r["police"], [])
        self.assertEqual(len(r["helplines"]), 2)

    def test_geometry_helpers(self):
        self.assertLess(JW.point_segment_m((0.0, 0.5), (0.0, 0.0), (0.0, 1.0)), 1)
        self.assertAlmostEqual(JW.point_segment_m((0.01, 0.5), (0.0, 0.0), (0.0, 1.0)),
                               1113, delta=5)
        self.assertEqual(JW.bn_num("12:05"), "১২:০৫")

    def test_command_runs(self):
        from django.core.management import call_command
        out = io.StringIO()
        call_command("journey_sweep", stdout=out)
        self.assertIn("journey_sweep", out.getvalue())
