"""sjkids — Children Corner (Safe Journey v2, owner order 9 Nov 11:15).

Fake-GPS proof (made-up coordinates only):
  * child in an UNKNOWN place during school hours -> ONE question to the
    guardians after 10 min (never a red alarm, never to a stranger), "I know"
    stops it for that window, back inside a safe place closes it;
  * at a relative's house (a safe place) during school hours -> no question;
  * coaching window on chosen days: travel grace, then the question;
  * WATCH place (river / market) entry -> guardians told once per 30 min;
  * the same rules through the REAL pipelines: kids watch ingest, the child's
    phone (live-location feed), and fcbrain's on-phone fence events;
  * no coordinates in notification rows; the child sees questions without
    coordinates and cannot answer for the guardians;
  * school_mode's late alert is sent ONCE (the tick now saves the day).
"""
from datetime import timedelta, timezone as dtz
from unittest import mock

from django.test import TestCase

from core import kids_corner as KCS
from core import kidswatch_service as KW
from core import sj_live as SL
from core.logic import kids_corner as KC
from core.logic import school_mode as SM
from core.models import NotifEvent, SchoolEvent, SchoolPlan
from core.tests_kidswatch import CFG, HOME, SCHOOL, V, L, _Base, _east, cl

RELATIVE = _east(*HOME, 5000)
COACHING = _east(*HOME, 3500)
RIVER = _east(*HOME, 8000)
UNKNOWN = _east(*SCHOOL, 1200)

# Nov 1 2026 = Sunday (school day); Nov 2 = Monday
PLACES = [
    {"kind": "relative", "name": "Khala's house", "lat": RELATIVE[0], "lng": RELATIVE[1]},
    {"kind": "coaching", "name": "", "lat": COACHING[0], "lng": COACHING[1],
     "windows": [{"days": [0, 2], "start": "16:00", "end": "18:00"}]},
    {"kind": "river", "name": "", "lat": RIVER[0], "lng": RIVER[1]},
]


def cfg_with(places=PLACES):
    c = dict(CFG)
    c["kc_places"] = places
    return SM.validate(c)


def run(cfg, steps, day=None):
    """steps: [(local_dt, (lat, lng) | None)] — None = a clock tick."""
    evs = []
    for at, pos in steps:
        if pos is None:
            day, ev = KC.on_tick(cfg, day, at)
            day, ev2 = SM.on_tick(cfg, day, at)
            ev = ev + KC.suppress_sm(ev2)
        else:
            day, ev = KC.step_fix(cfg, day, at, pos[0], pos[1])
        evs += [(at, e) for e in ev]
    return day, evs


def kinds(evs, notify=None):
    return [e["kind"] for _, e in evs if notify is None or e.get("notify") == notify]


class CornerPlacesTests(TestCase):
    def test_clean_places(self):
        out = KC.clean_places(PLACES)
        self.assertEqual([p["id"] for p in out], [1, 2, 3])
        self.assertEqual([p["role"] for p in out], ["safe", "safe", "watch"])
        self.assertEqual(out[2]["radius_m"], 200)            # river default
        self.assertEqual(out[2]["windows"], [])
        self.assertEqual(KC.clean_places(out), out)          # idempotent
        for bad, reason in (([{"kind": "zoo", "lat": 23.7, "lng": 90.4}], "bad_kind"),
                            ([{"kind": "market", "lat": 0, "lng": 0}], "bad_location"),
                            ([{"kind": "coaching", "lat": 23.7, "lng": 90.4,
                               "windows": [{"days": [1], "start": "18:00",
                                            "end": "16:00"}]}], "bad_window"),
                            ([{"kind": "coaching", "lat": 23.7, "lng": 90.4,
                               "windows": [{"days": [9], "start": "16:00",
                                            "end": "18:00"}]}], "bad_window"),
                            ([PLACES[0]] * 13, "too_many_places")):
            with self.assertRaises(ValueError) as cm:
                KC.clean_places(bad)
            self.assertEqual(str(cm.exception), reason)

    def test_active_windows(self):
        cfg = cfg_with()
        self.assertEqual([w["kind"] for w in KC.active_windows(cfg, L(1, 9, 0))], ["school"])
        self.assertEqual(KC.active_windows(cfg, L(1, 16, 30)), [])    # Sunday: no coaching
        self.assertEqual([w["kind"] for w in KC.active_windows(cfg, L(2, 16, 30))],
                         ["coaching"])
        hol = dict(cfg, holidays=["2026-11-01"])
        self.assertEqual(KC.active_windows(hol, L(1, 9, 0)), [])


class UnknownPlaceInSchoolHoursTests(TestCase):
    """E2E (pure, fake GPS): the owner's 'unknown place during school hours'."""

    def morning(self):
        return [(L(1, 7, 0), HOME), (L(1, 7, 10), HOME), (L(1, 7, 30), _east(*HOME, 1000)),
                (L(1, 7, 31), _east(*HOME, 1200)), (L(1, 7, 50), SCHOOL),
                (L(1, 10, 0), SCHOOL)]

    def test_asks_guardian_once_after_ten_minutes(self):
        cfg = cfg_with()
        day, evs = run(cfg, self.morning() + [
            (L(1, 10, 5), UNKNOWN), (L(1, 10, 6), UNKNOWN),
            (L(1, 10, 10), None), (L(1, 10, 14), UNKNOWN)])
        self.assertNotIn("kc_ask_unknown", kinds(evs))      # < 10 min outside
        # school_mode's immediate alarm became history only (no push)
        self.assertEqual([e.get("notify") for _, e in evs if e["kind"] == "left_school_early"],
                         ["none"])
        day, evs = run(cfg, [(L(1, 10, 15), None), (L(1, 10, 16), UNKNOWN),
                             (L(1, 10, 30), None)], day)
        asks = [(at, e) for at, e in evs if e["kind"] == "kc_ask_unknown"]
        self.assertEqual(len(asks), 1)
        at, ask = asks[0]
        self.assertEqual(at, L(1, 10, 15))
        self.assertEqual((ask["notify"], ask["place_kind"]), ("ask", "school"))
        self.assertAlmostEqual(ask["lat"], UNKNOWN[0])
        self.assertNotIn("alert", [e.get("notify") for _, e in evs])  # never red
        # a guardian: "I know" -> no more questions for this window today
        a = KC.answer(day, ask["ask_id"], "ok", L(1, 10, 31), "Ammu")
        self.assertEqual((a["state"], a["by"]), ("ok", "Ammu"))
        day, evs = run(cfg, [(L(1, 11, 0), UNKNOWN), (L(1, 12, 0), None)], day)
        self.assertNotIn("kc_ask_unknown", kinds(evs))
        view = KC.today_view(cfg, day, L(1, 12, 0))
        self.assertEqual(view["where"], "outside")
        self.assertEqual(view["asks"][0]["state"], "ok")

    def test_back_at_school_closes_the_question(self):
        cfg = cfg_with()
        day, evs = run(cfg, self.morning() + [(L(1, 10, 5), UNKNOWN), (L(1, 10, 6), UNKNOWN),
                                               (L(1, 10, 20), None), (L(1, 10, 25), SCHOOL)])
        k = kinds(evs)
        self.assertLess(k.index("kc_ask_unknown"), k.index("kc_back_safe"))
        self.assertEqual(KC.today_view(cfg, day, L(1, 10, 26))["asks"][0]["state"],
                         "back_safe")
        self.assertEqual(KC.today_view(cfg, day, L(1, 10, 26))["where"], "safe")

    def test_relative_house_is_safe_no_question(self):
        cfg = cfg_with()
        day, evs = run(cfg, self.morning() + [
            (L(1, 10, 5), RELATIVE), (L(1, 10, 30), None), (L(1, 11, 0), RELATIVE)])
        self.assertNotIn("kc_ask_unknown", kinds(evs))
        self.assertIn("kc_arrive", kinds(evs, "family"))     # news for Family Care
        self.assertEqual(KC.today_view(cfg, day, L(1, 11, 0))["place_kind"], "relative")

    def test_not_arrived_yet_is_school_modes_late_alert_not_a_question(self):
        cfg = cfg_with()
        day, evs = run(cfg, [(L(1, 7, 0), HOME), (L(1, 7, 30), UNKNOWN),
                             (L(1, 7, 31), UNKNOWN), (L(1, 8, 40), None)])
        self.assertNotIn("kc_ask_unknown", kinds(evs))
        self.assertIn("late_school", kinds(evs))

    def test_coaching_window_grace_then_question(self):
        cfg = cfg_with()
        day, evs = run(cfg, [(L(2, 15, 30), HOME), (L(2, 15, 50), UNKNOWN),
                             (L(2, 16, 10), None), (L(2, 16, 19), None)])
        self.assertNotIn("kc_ask_unknown", kinds(evs))       # travel grace (20 min)
        day, evs = run(cfg, [(L(2, 16, 20), None)], day)
        self.assertEqual(kinds(evs), ["kc_ask_unknown"])
        self.assertEqual(evs[0][1]["place_kind"], "coaching")
        # reaching coaching closes it, then leaving is plain news
        day, evs = run(cfg, [(L(2, 16, 25), COACHING), (L(2, 18, 5), HOME)], day)
        self.assertEqual(kinds(evs), ["kc_arrive", "kc_back_safe", "kc_leave"])

    def test_old_position_never_starts_a_question(self):
        cfg = cfg_with()
        day, _ = run(cfg, self.morning() + [(L(1, 10, 5), UNKNOWN), (L(1, 10, 6), UNKNOWN)])
        day, evs = run(cfg, [(L(1, 11, 0), None)], day)       # 54 min with no fix
        self.assertNotIn("kc_ask_unknown", kinds(evs))

    def test_paused_day_does_nothing(self):
        cfg = cfg_with()
        day, _ = run(cfg, self.morning())
        day["paused"] = True
        day, evs = run(cfg, [(L(1, 10, 5), UNKNOWN), (L(1, 10, 30), None)], day)
        self.assertEqual(kinds(evs), [])


class WatchPlaceTests(TestCase):
    def test_entry_once_per_cooldown_any_day(self):
        cfg = cfg_with()
        fri = L(6, 15, 0)                                       # a Friday, no school
        day, evs = run(cfg, [(fri, HOME), (fri + timedelta(minutes=10), RIVER),
                             (fri + timedelta(minutes=12), HOME),
                             (fri + timedelta(minutes=15), RIVER),
                             (fri + timedelta(minutes=30), HOME),
                             (fri + timedelta(minutes=45), RIVER)])
        w = [(at, e) for at, e in evs if e["kind"] == "kc_watch_enter"]
        self.assertEqual([at for at, _ in w], [fri + timedelta(minutes=10),
                                               fri + timedelta(minutes=45)])
        self.assertEqual((w[0][1]["notify"], w[0][1]["place_kind"]), ("push", "river"))
        self.assertNotIn("kc_ask_unknown", kinds(evs))           # no window on Friday


class CornerServiceTests(_Base):
    """The same rules through the real pipelines + API + trust rules."""

    def plan(self, **kw):
        body = dict(CFG, kc_places=PLACES, watcher_ids=[self.mom.id])
        body.update(kw)
        r = self.c.post(V + "/school-mode/plans", body, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r.data["plan"]

    def feed(self, w, steps):
        for at, pos in steps:
            at = at.astimezone(dtz.utc)
            if pos is None:
                KW.tick(at)
            else:
                KW.ingest({w.id: {"fixes": [{"at": at, "valid": True, "lat": pos[0],
                                             "lng": pos[1], "wifi": []}]}}, at)

    def test_watch_child_unknown_place_asks_guardians_and_answer(self):
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        p = self.plan(watch_id=w.id)
        self.assertEqual([x["kind"] for x in p["config"]["kc_places"]],
                         ["relative", "coaching", "river"])
        self.feed(w, [(L(1, 7, 0), HOME), (L(1, 7, 30), _east(*HOME, 1000)),
                      (L(1, 7, 31), _east(*HOME, 1200)), (L(1, 7, 50), SCHOOL),
                      (L(1, 10, 0), SCHOOL), (L(1, 10, 5), UNKNOWN), (L(1, 10, 6), UNKNOWN)])
        self.assertFalse(any(c["data"].get("event") == "left_school_early"
                             for c in self.spy.calls))       # no immediate red alarm
        self.spy.calls.clear()
        self.feed(w, [(L(1, 10, 16), None)])
        for u in (self.owner, self.mom):
            asks = [c for c in self.spy.to(u) if c["data"].get("event") == "kc_ask_unknown"]
            self.assertEqual(len(asks), 1, u.name)
            self.assertFalse(asks[0]["high"])
            self.assertNotIn("lat", asks[0]["data"])            # no coordinates in pushes
            self.assertIn("Rina", asks[0]["ten"])
        self.assertEqual(self.spy.to(self.x), [])               # stranger guardian id dropped
        self.assertFalse(NotifEvent.objects.filter(meta__has_key="lat",
                                                   route="kids_corner").exists())
        self.assertTrue(SchoolEvent.objects.filter(kind="kc_ask_unknown").exists())
        # guardian view has the last position; the answer stops the question
        clock = mock.patch("django.utils.timezone.now",
                           return_value=L(1, 10, 20).astimezone(dtz.utc))
        clock.start()
        r = cl(self.mom).get(V + "/school-mode/plans/%d" % p["id"])
        kc = r.data["plan"]["kids_corner"]
        ask = kc["asks"][0]
        self.assertAlmostEqual(ask["lat"], UNKNOWN[0])
        self.assertEqual(cl(self.x).post(V + "/school-mode/plans/%d/kc-answer" % p["id"],
                                         {"ask_id": ask["id"]}, format="json").status_code, 404)
        r = cl(self.mom).post(V + "/school-mode/plans/%d/kc-answer" % p["id"],
                              {"ask_id": ask["id"], "answer": "ok"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["plan"]["kids_corner"]["asks"][0]["state"], "ok")
        clock.stop()
        self.spy.calls.clear()
        self.feed(w, [(L(1, 11, 0), UNKNOWN), (L(1, 11, 30), None)])
        self.assertFalse(any(c["data"].get("event") == "kc_ask_unknown" for c in self.spy.calls))

    def test_watch_place_entry_reaches_guardians(self):
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        self.plan(watch_id=w.id)
        self.feed(w, [(L(6, 15, 0), HOME), (L(6, 15, 9), RIVER)])
        for u in (self.owner, self.mom):
            got = [c for c in self.spy.to(u) if c["data"].get("event") == "kc_watch_enter"]
            self.assertEqual(len(got), 1)
            self.assertIn("নদী", got[0]["tbn"])
            self.assertIn("river", got[0]["ten"])

    def test_child_phone_live_feed_and_child_view(self):
        p = self.plan(child_user_id=self.child.id)
        cc = cl(self.child)
        cc.post(V + "/school-mode/plans/%d/accept" % p["id"])
        for at, pos in ((L(6, 15, 0), HOME), (L(6, 15, 9), RIVER)):
            SL.feed_school(self.child, [(at.astimezone(dtz.utc), pos[0], pos[1], 80, "gps", 10)],
                           at.astimezone(dtz.utc))
        self.assertTrue(any(c["data"].get("event") == "kc_watch_enter"
                            for c in self.spy.to(self.owner)))
        self.assertFalse(any(c["data"].get("event") == "kc_watch_enter"
                             for c in self.spy.to(self.child)))
        # transparency: the child sees the plan + places; cannot answer
        r = cc.get(V + "/school-mode/mine")
        self.assertIn("kids_corner", r.data["plans"][0])
        self.assertEqual(cc.post(V + "/school-mode/plans/%d/kc-answer" % p["id"],
                                 {"ask_id": "x"}, format="json").status_code, 403)

    def test_fcbrain_fence_seam(self):
        p = self.plan(child_user_id=self.child.id)
        cl(self.child).post(V + "/school-mode/plans/%d/accept" % p["id"])
        f = KCS.fences_for(self.child)
        self.assertEqual(len(f), 3)
        river = [x for x in f if x["label"] == "নদী"][0]
        self.assertEqual(KC.parse_fence_id(river["id"]), (p["id"], 3))
        self.assertEqual(river["r"], 200)
        self.assertEqual(KCS.fences_for(self.x), [])           # nobody else's places
        at = L(6, 15, 9).astimezone(dtz.utc)
        self.assertEqual(KCS.on_brain_event(self.child, {"kind": "arrive", "at": at,
                                                         "place_id": river["id"],
                                                         "place_kind": "place"}, at),
                         "guardians")
        self.assertTrue(any(c["data"].get("event") == "kc_watch_enter"
                            for c in self.spy.to(self.mom)))
        rel = [x for x in f if x["label"] == "Khala's house"][0]
        self.assertEqual(KCS.on_brain_event(self.child, {"kind": "arrive", "at": at,
                                                         "place_id": rel["id"]}, at), "family")
        self.assertIsNone(KCS.on_brain_event(self.child, {"kind": "arrive", "at": at,
                                                          "place_id": 12,
                                                          "place_kind": "place"}, at))
        # on-phone school leave in school hours -> the tick asks the guardians
        for hh, mm, kind in ((7, 50, "arrive"), (10, 5, "leave")):
            t = L(1, hh, mm).astimezone(dtz.utc)
            KCS.on_brain_event(self.child, {"kind": kind, "at": t, "place_kind": "school",
                                            "place_id": 77}, t)
        self.spy.calls.clear()
        KW.tick(L(1, 10, 16).astimezone(dtz.utc))
        self.assertTrue(any(c["data"].get("event") == "kc_ask_unknown"
                            for c in self.spy.to(self.owner)))
        # the phone fence proved school: no false "are you OK? / late" for the child
        self.assertFalse(any(c["data"].get("event") in ("ask_ok", "late_school")
                             for c in self.spy.calls))

    def test_patch_places_and_validation(self):
        p = self.plan(child_user_id=self.child.id)
        r = self.c.patch(V + "/school-mode/plans/%d" % p["id"],
                         {"kc_places": PLACES[:1]}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(len(r.data["plan"]["config"]["kc_places"]), 1)
        r = self.c.patch(V + "/school-mode/plans/%d" % p["id"],
                         {"kc_places": [{"kind": "coaching", "lat": 23.7, "lng": 90.4,
                                         "windows": [{"days": [1], "start": "9:00",
                                                      "end": "8:00"}]}]}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "bad_window")
        # a watcher (co-guardian) cannot change the places
        self.assertEqual(cl(self.mom).patch(V + "/school-mode/plans/%d" % p["id"],
                                            {"kc_places": []}, format="json").status_code, 403)

    def test_late_alert_sent_once(self):
        """Found while wiring the corner: the minute tick mutated the stored
        day in place, so the late alert was never saved as sent."""
        w = self.pair_watch()
        KW.on_watch_connect("8800000015", "SG")
        p = self.plan(watch_id=w.id)
        self.feed(w, [(L(1, 7, 0), HOME)])
        for mm in (16, 17, 18):
            KW.tick(L(1, 8, mm).astimezone(dtz.utc))
        late = [c for c in self.spy.to(self.mom) if c["data"].get("event") == "late_school"]
        self.assertEqual(len(late), 1)
        self.assertTrue(SchoolPlan.objects.get(pk=p["id"]).day["alerts"].get("late_school"))


try:                                  # fcbrain (Family Care v3) — merged by integration
    from core import family_brain as _FB
except Exception:  # noqa: BLE001
    _FB = None


@__import__("unittest").skipUnless(_FB is not None and hasattr(_FB, "ping"),
                                   "fcbrain not merged on this branch")
class FcbrainPingSeamTests(_Base):
    """fcbrain's ping() with a corner WATCH fence: guardians get the entry,
    the family gets no arrive/leave fan-out. The hook must run even when the
    child has no Family v3 group yet (before ping's 'no_family' return)."""

    def test_watch_fence_through_ping(self):
        r = self.c.post(V + "/school-mode/plans",
                        dict(CFG, kc_places=PLACES, watcher_ids=[self.mom.id],
                             child_user_id=self.child.id), format="json")
        pid = r.data["plan"]["id"]
        cl(self.child).post(V + "/school-mode/plans/%d/accept" % pid)
        self.spy.calls.clear()
        at = L(6, 15, 9).astimezone(dtz.utc)
        _FB.ping(self.child, {"events": [{
            "id": "kc-river-1", "kind": "arrive", "at": at.isoformat(),
            "place_id": KC.fence_id(pid, 3), "place_kind": "place",
            "place_label": "নদী"}]}, now=at)
        for u in (self.owner, self.mom):
            self.assertTrue(any(c["data"].get("event") == "kc_watch_enter"
                                for c in self.spy.to(u)), u.name)
        self.assertFalse(any(c["data"].get("event") in ("auto_arrived", "auto_left")
                             for c in self.spy.calls))
