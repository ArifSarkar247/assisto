"""fcbrain — Family Care v3 BRAIN 2-7 + ask bar (core/family_brain.py,
core/notif_budget.py, core/logic/fc_ask.py).

Proof the owner asked for: fake-GPS auto arrive end to end (phone event ->
server -> family push, latency measured), notification budget, pause,
consent, admin never sees locations, 15 % battery once, night news (AI +
template fallback, never charged), Probashi receiver time zone."""
import json
import re
from datetime import date, datetime, timedelta, timezone as dt_tz
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import family_brain as FB
from core import notif_budget as NB
from core.logic import fc_ask as ASK
from core.models import (CircleMember, Device, FamilyAlert, FamilyAlertDelivery,
                         PaCollectionItem, User)

V = "/api/v1"
ROOT = Path(__file__).resolve().parents[2]


def mk(phone, name, lang="en", **kw):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang, **kw)


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE=getattr(u, "language", "en"))
    return c


def pair(a, b, **kw):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted", **kw)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                direction="incoming")


class Spy:
    def __init__(self):
        self.calls = []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "tbn": tbn,
                           "ben": ben, "bbn": bbn, "data": dict(data or {})})
        return True

    def to(self, u):
        return [c for c in self.calls if c["user"] == u.pk]


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.kid = mk("01711200001", "Rafi")
        self.mom = mk("01711200002", "Rahima", lang="bn")
        self.dad = mk("01711200003", "Karim")
        self.stranger = mk("01711200004", "Stranger")
        self.staff = mk("01711200005", "Owner", is_staff=True, is_superuser=True)
        pair(self.kid, self.mom, sharing={"location": True})
        pair(self.kid, self.dad)
        pair(self.mom, self.dad)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p.start()
        self.addCleanup(p.stop)
        self.now = timezone.now()

    def ping(self, user, **body):
        return cl(user).post("%s/family/brain/ping" % V, body, format="json")

    def arrive(self, user, eid="e1", crossed_s=40, kind="arrive", place="home", label=""):
        at = timezone.now()
        return self.ping(user, battery=70, charging=False, net="wifi", watch_on=True,
                         events=[{"id": eid, "kind": kind, "at": at.isoformat(),
                                  "crossed_at": (at - timedelta(seconds=crossed_s)).isoformat(),
                                  "place_kind": place, "place_label": label}])


# ------------------------------------------------------------ 2 auto arrive
class AutoArriveE2ETests(Base):
    def test_fake_gps_arrival_reaches_family_within_two_minutes(self):
        """E2E (server half): the phone's on-device fence fired (fake GPS
        trace in app/test/fc_brain_test.dart) -> ping -> both parents get a
        push + card; the crossing->server latency is recorded for the board."""
        cl(self.kid).post("%s/family/brain/prefs" % V, {"auto_arrive": True}, format="json")
        r = self.arrive(self.kid, "trip-1-arrive", crossed_s=45, place="school")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["accepted"], 1)
        self.assertEqual(sorted(c["user"] for c in self.spy.calls),
                         sorted([self.mom.pk, self.dad.pk]))
        mom = self.spy.to(self.mom)[0]
        self.assertEqual(mom["data"]["alert_kind"], "auto_arrived")
        self.assertIn("স্কুল", mom["tbn"])
        self.assertIn("School", self.spy.to(self.dad)[0]["ten"])
        self.assertEqual(mom["data"]["lat"], "")            # arrival never carries coordinates
        self.assertTrue(FamilyAlert.objects.filter(user=self.mom, kind="auto_arrived").exists())
        st = FB.latency_stats()
        self.assertEqual(st["n"], 1)
        self.assertLessEqual(st["p95_s"], 120)
        self.assertEqual(st["within_2min_pct"], 100.0)
        # the card data shows the place
        b = FB.member_brain_state(self.mom, self.kid)
        self.assertEqual(b["place_kind"], "school")
        self.assertEqual(b["last_event"]["kind"], "arrive")

    def test_retry_is_idempotent(self):
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        self.arrive(self.kid, "same")
        r = self.arrive(self.kid, "same")
        self.assertEqual(r.json()["duplicate"], 1)
        self.assertEqual(len(self.spy.calls), 2)

    def test_leave_is_quiet_unless_member_chose_leave_news(self):
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        self.arrive(self.kid, "l1", kind="leave")
        self.assertEqual(self.spy.calls, [])
        self.assertEqual(FB.member_brain_state(self.mom, self.kid)["last_event"]["kind"], "leave")
        FB.set_prefs(self.kid, self.kid, {"leave_news": True})
        self.arrive(self.kid, "l2", kind="leave")
        self.assertEqual({c["data"]["alert_kind"] for c in self.spy.calls}, {"auto_left"})

    def test_auto_arrive_off_by_default_tells_nobody(self):
        self.arrive(self.kid, "x1")
        self.assertEqual(self.spy.calls, [])

    def test_stranger_never_notified(self):
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        self.arrive(self.kid, "s1")
        self.assertEqual(self.spy.to(self.stranger), [])

    def test_future_phone_clock_is_clamped(self):
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        self.ping(self.kid, events=[{"id": "f1", "kind": "arrive", "place_kind": "home",
                                     "at": (timezone.now() + timedelta(days=2)).isoformat()}])
        at = FB._parse(FB.state_of(self.kid)["last_event"]["at"])
        self.assertLessEqual(at, timezone.now() + timedelta(minutes=1))


# ---------------------------------------------------------- 3 battery 15 %
class BatteryLowTests(Base):
    def test_shares_last_location_once_per_discharge(self):
        self.ping(self.kid, battery=40)
        self.ping(self.kid, battery=15, charging=False,
                  events=[{"id": "b1", "kind": "battery_low", "lat": 23.75, "lng": 90.39, "acc": 30}])
        calls = [c for c in self.spy.calls if c["data"].get("alert_kind") == "battery_low_loc"]
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.spy.to(self.mom)[0]["data"]["lat"], 23.75)    # shares location
        self.assertEqual(self.spy.to(self.dad)[0]["data"]["lat"], "")       # no location consent
        self.ping(self.kid, battery=12)
        self.ping(self.kid, battery=9)
        self.assertEqual(len(self.spy.calls), 2)                           # ONCE
        loc = FB.member_brain_state(self.mom, self.kid)["last_location"]
        self.assertEqual(loc["why"], "battery_low")
        # charging re-arms it
        self.ping(self.kid, battery=20, charging=True)
        self.ping(self.kid, battery=14, charging=False)
        self.assertEqual(len(self.spy.calls), 4)

    def test_battery_alert_is_safety_not_budgeted(self):
        for i in range(NB.LIMIT):
            self.assertTrue(NB.allow(self.mom, "offer"))
        self.ping(self.kid, battery=50)
        self.ping(self.kid, battery=10)
        self.assertEqual(len(self.spy.to(self.mom)), 1)


# ---------------------------------------------------------- 7 budget
class BudgetTests(Base):
    def test_three_non_safety_per_day_then_silent(self):
        self.assertEqual([NB.allow(self.dad, "offer") for _ in range(5)],
                         [True, True, True, False, False])
        self.assertEqual(NB.status(self.dad)["used"], 3)
        self.assertEqual(NB.status(self.dad)["skipped"], 2)

    def test_safety_always_passes_and_is_not_counted(self):
        for _ in range(3):
            NB.allow(self.dad, "channel_post")
        for k in ("sos", "call", "message", "carecall", "carecall_status", "shop_alert", "reminder"):
            self.assertTrue(NB.allow(self.dad, k), k)
        for fk in ("sos", "fall", "auto_arrived", "battery_low_loc", "checkin_overdue"):
            self.assertTrue(NB.allow(self.dad, "family_alert", family_kind=fk), fk)
        self.assertEqual(NB.used_today(self.dad), 3)

    def test_unknown_new_kind_is_budgeted(self):
        self.assertFalse(NB.is_safety("brand_new_nudge"))

    def test_new_day_resets(self):
        for _ in range(3):
            NB.allow(self.dad, "offer")
        self.assertFalse(NB.allow(self.dad, "offer"))
        self.assertTrue(NB.allow(self.dad, "offer", now=timezone.now() + timedelta(days=1)))

    def test_night_news_keeps_its_reserved_slot(self):
        # dad has family + night news on (default) -> ordinary kinds get 2
        FB.ping(self.dad, {"battery": 80})
        res = [NB.allow(self.dad, "agent_nudge") for _ in range(3)]
        self.assertEqual(res, [True, True, False])
        self.assertTrue(NB.allow(self.dad, "family_alert", family_kind="night_news"))
        self.assertFalse(NB.allow(self.dad, "family_alert", family_kind="night_news"))

    def test_push_to_user_central_gate(self):
        from core import push
        Device.objects.create(user=self.dad, push_token="tok-dad")
        with mock.patch.object(push, "is_available", return_value=True), \
                mock.patch.object(push, "send_to_token", return_value=True) as s:
            got = [push.push_to_user(self.dad, "offer", "t", "t") for _ in range(4)]
            self.assertEqual(got, [1, 1, 1, 0])
            self.assertEqual(push.push_to_user(self.dad, "sos", "t", "t"), 1)
            self.assertEqual(s.call_count, 4)

    def test_family_alert_over_budget_keeps_card_but_does_not_ring(self):
        from core import family_alerts as FA
        for _ in range(3):
            NB.allow(self.mom, "offer")
        st = FA.alert(self.kid, "night_news", "nn-1", recipients=[self.mom],
                      payload={"title_en": "x", "title_bn": "x"})
        self.assertEqual(st.get("budget"), 1)
        self.assertEqual(self.spy.to(self.mom), [])
        self.assertTrue(FamilyAlert.objects.filter(user=self.mom, kind="night_news").exists())
        self.assertEqual(FamilyAlertDelivery.objects.get(recipient=self.mom).status, "budget")


# ---------------------------------------------------------- 5 trust: pause
class PauseTests(Base):
    def test_pause_1_2_8_only(self):
        c = cl(self.kid)
        for h in (1, 2, 8):
            self.assertEqual(c.post("%s/family/brain/pause" % V, {"hours": h}, format="json").status_code, 200)
        self.assertEqual(c.post("%s/family/brain/pause" % V, {"hours": 3}, format="json").status_code, 400)

    def test_paused_shows_paused_never_a_location(self):
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        self.arrive(self.kid, "a1", place="home")
        self.ping(self.kid, battery=40)
        self.ping(self.kid, battery=10, events=[{"id": "b", "kind": "battery_low", "lat": 23.7, "lng": 90.4}])
        self.spy.calls.clear()
        cl(self.kid).post("%s/family/brain/pause" % V, {"hours": 2}, format="json")
        b = FB.member_brain_state(self.mom, self.kid)
        self.assertTrue(b["paused_until"])
        for k in ("place_kind", "place_label", "battery", "last_location", "last_event"):
            self.assertNotIn(k, b)
        # events while paused: nothing recorded, nobody told
        self.arrive(self.kid, "a2", place="school")
        self.assertEqual(self.spy.calls, [])
        self.assertNotIn("a2", json.dumps(FB.state_of(self.kid).get("timeline")))
        # SOS still works while paused
        r = cl(self.kid).post("%s/family/sos" % V, {"lat": 23.7, "lng": 90.4}, format="json")
        self.assertEqual(r.json()["recipients"], 2)
        # after the pause ends, the old place is not shown as current
        later = timezone.now() + timedelta(hours=3)
        b = FB.member_brain_state(self.mom, self.kid, now=later)
        self.assertIsNone(b["paused_until"])
        self.assertIsNone(b["place_kind"])

    def test_resume(self):
        FB.pause(self.kid, 8)
        cl(self.kid).post("%s/family/brain/pause" % V, {"resume": True}, format="json")
        self.assertIsNone(FB.member_brain_state(self.mom, self.kid)["paused_until"])


# ------------------------------------------------------- 5 trust: consent
class ConsentTests(Base):
    def test_adult_cannot_switch_on_tracking_for_another_adult(self):
        r = cl(self.mom).post("%s/family/brain/prefs" % V,
                              {"member_id": self.dad.pk, "auto_arrive": True}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertFalse(FB.prefs_of(FB.state_of(self.dad))["auto_arrive"])

    def test_guardian_may_switch_on_for_a_child_but_not_night_choices(self):
        with mock.patch("core.guardian_links.is_guardian", return_value=True):
            r = cl(self.mom).post("%s/family/brain/prefs" % V,
                                  {"member_id": self.kid.pk, "auto_arrive": True}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            p = FB.prefs_of(FB.state_of(self.kid))
            self.assertTrue(p["auto_arrive"])
            self.assertEqual(p["auto_arrive_by"], self.mom.pk)
            r = cl(self.mom).post("%s/family/brain/prefs" % V,
                                  {"member_id": self.kid.pk, "night": {"items": []}}, format="json")
            self.assertEqual(r.status_code, 403)

    def test_self_consent_recorded(self):
        cl(self.dad).post("%s/family/brain/prefs" % V, {"auto_arrive": True}, format="json")
        p = FB.prefs_of(FB.state_of(self.dad))
        self.assertEqual(p["auto_arrive_by"], "self")
        self.assertTrue(p["auto_arrive_at"])

    def test_everyone_sees_who_can_see_them(self):
        r = cl(self.kid).get("%s/family/brain/visibility" % V)
        names = sorted(p["name"] for p in r.json()["people"])
        self.assertEqual(names, ["Karim", "Rahima"])
        self.assertFalse(r.json()["admin_sees_location"])

    def test_monthly_reminder_card(self):
        FB.ping(self.kid, {"battery": 80})
        FB.tick(now=self.now)                       # starts the clock
        self.assertFalse(FamilyAlert.objects.filter(user=self.kid, kind="visibility").exists())
        FB.tick(now=self.now + timedelta(days=31))
        self.assertTrue(FamilyAlert.objects.filter(user=self.kid, kind="visibility").exists())
        FB.tick(now=self.now + timedelta(days=32))
        self.assertEqual(FamilyAlert.objects.filter(user=self.kid, kind="visibility").count(), 1)

    def test_leave_endpoint_answers(self):
        r = cl(self.kid).post("%s/family/brain/leave" % V, {"family_id": 999}, format="json")
        self.assertIn(r.status_code, (200, 400))


# ------------------------------------------------ admin never sees location
class AdminNeverSeesLocationTests(Base):
    def test_staff_outside_the_family_gets_nothing(self):
        self.ping(self.kid, battery=40)
        self.ping(self.kid, battery=10, events=[{"id": "b", "kind": "battery_low", "lat": 23.7, "lng": 90.4}])
        self.assertIsNone(FB.member_brain_state(self.staff, self.kid))
        self.assertEqual(FB.member_timeline(self.staff, self.kid), [])
        r = cl(self.staff).get("%s/family/brain/member/%d" % (V, self.kid.pk))
        self.assertEqual(r.status_code, 403)
        self.assertIsNone(FB.member_brain_state(self.stranger, self.kid))

    def test_no_admin_or_owner_page_reads_the_brain_store(self):
        bad = []
        for path in list((ROOT / "backend" / "web").rglob("*.py")) + \
                list((ROOT / "backend" / "core").glob("admin*.py")):
            src = path.read_text(encoding="utf-8")
            if re.search(r"family_brain|fc_brain", src):
                bad.append(str(path))
        self.assertEqual(bad, [])

    def test_admin_registry_has_no_location_model_for_brain(self):
        from django.contrib import admin
        self.assertNotIn(PaCollectionItem, admin.site._registry)


# ------------------------------------------------------------- 4 night news
class NightNewsTests(Base):
    def _prep(self):
        FB.ping(self.kid, {"battery": 60, "tz_offset_min": 360})
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        FB.ping(self.kid, {"events": [{"id": "n1", "kind": "arrive", "place_kind": "home"}]})
        FB.ping(self.mom, {"battery": 90})
        self.spy.calls.clear()

    def _at(self, hh, mm):
        d = timezone.now().astimezone(ZoneInfo("Asia/Dhaka")).replace(hour=hh, minute=mm, second=5)
        return d

    def test_sent_once_at_chosen_time_with_template_when_ai_down(self):
        from core import ai
        self._prep()
        with mock.patch.object(ai, "generate", side_effect=ai.AIUnavailable("no_key")):
            FB.tick(now=self._at(21, 0))
            self.assertFalse(FamilyAlert.objects.filter(user=self.mom, kind="night_news").exists())
            FB.tick(now=self._at(21, 31))
            FB.tick(now=self._at(21, 40))
        cards = FamilyAlert.objects.filter(user=self.mom, kind="night_news")
        self.assertEqual(cards.count(), 1)
        self.assertIn("Rafi", cards[0].body)
        self.assertIn("বাড়ি", cards[0].body)
        self.assertEqual(FB.state_of(self.mom)["night_last"]["source"], "template")

    def test_ai_writes_from_structured_facts_and_is_never_charged(self):
        from core import ai
        self._prep()
        seen = {}

        def gen(task, data="", **kw):
            seen.update(kw, data=data)
            return ("আজ রাতে Rafi বাড়িতে আছে, Karim-এর নতুন খবর নেই।", 0.0)
        with mock.patch.object(ai, "generate", side_effect=gen):
            FB.tick(now=self._at(21, 35))
        self.assertIsNone(seen["user"])                       # nobody pays
        self.assertEqual(seen["feature"], "family.night_news")
        from core import ai_levels_service as ALS
        self.assertTrue(ALS.exempt("family.night_news"))
        facts = json.loads(seen["data"])
        self.assertTrue(all(set(f) <= {"name", "place", "moves", "battery", "carecall",
                                        "no_news", "paused"} for f in facts))
        self.assertNotIn("23.", seen["data"])
        self.assertEqual(FB.state_of(self.mom)["night_last"]["source"], "ai")

    def test_made_up_ai_card_falls_back(self):
        from core import ai
        self._prep()
        with mock.patch.object(ai, "generate", return_value=("Everyone is fine!", 0.0)):
            FB.tick(now=self._at(21, 35))
        self.assertEqual(FB.state_of(self.mom)["night_last"]["source"], "template")

    def test_off_and_custom_time(self):
        self._prep()
        FB.set_prefs(self.mom, self.mom, {"night": {"on": False}})
        FB.tick(now=self._at(21, 35))
        self.assertFalse(FamilyAlert.objects.filter(user=self.mom, kind="night_news").exists())
        FB.set_prefs(self.mom, self.mom, {"night": {"on": True, "time": "22:15"}})
        with mock.patch("core.ai.generate", side_effect=Exception("down")):
            FB.tick(now=self._at(21, 35))
            self.assertFalse(FamilyAlert.objects.filter(user=self.mom, kind="night_news").exists())
            FB.tick(now=self._at(22, 16))
        self.assertTrue(FamilyAlert.objects.filter(user=self.mom, kind="night_news").exists())
        self.assertEqual(cl(self.mom).post("%s/family/brain/prefs" % V,
                                           {"night": {"time": "25:00"}}, format="json").status_code, 400)

    def test_member_chooses_what_about_them_goes_in(self):
        self._prep()
        FB.set_prefs(self.kid, self.kid, {"night": {"items": ["battery"]}})
        facts = FB.night_facts(self.mom)
        kid = [f for f in facts if f["name"] == "Rafi"][0]
        self.assertNotIn("place", kid)
        self.assertNotIn("moves", kid)
        self.assertEqual(kid["battery"], 60)

    def test_card_endpoint_preview_without_ai(self):
        self._prep()
        with mock.patch("core.ai.generate") as g:
            r = cl(self.mom).get("%s/family/brain/night-news" % V)
            g.assert_not_called()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["card"]["source"], "preview")
        self.assertEqual(r.json()["night"]["time"], "21:30")


# -------------------------------------------------------------- ask bar
class AskTests(Base):
    def test_shared_case_table(self):
        t = json.loads((ROOT / "app/test/fixtures/fc_ask_cases.json").read_text(encoding="utf-8"))
        now = datetime.fromisoformat(t["now"].replace("Z", "+00:00"))
        for c in t["cases"]:
            a = ASK.answer(c["q"], t["members"], c["lang"], now)
            if c.get("none"):
                self.assertIsNone(a, c["q"])
                continue
            self.assertIsNotNone(a, c["q"])
            self.assertEqual(a["member_user_id"], c["member"], c["q"])
            self.assertEqual(a["action"], c["action"], c["q"])
            for s in c["contains"]:
                self.assertIn(s, a["text"], c["q"])

    def test_never_green_for_stale(self):
        now = timezone.now()
        a = ASK.answer("is rafi ok", [{"user_id": 1, "name": "Rafi", "state": "stale",
                                       "reason": "never", "last_seen": None}], "en", now)
        self.assertNotIn("Yes", a["text"])

    def test_endpoint_parser_first_ai_only_when_needed(self):
        FB.ping(self.mom, {"battery": 80, "interval_s": 3600})
        with mock.patch("core.ai.generate") as g:
            r = cl(self.kid).post("%s/family/brain/ask" % V, {"q": "Is Rahima OK"}, format="json")
            g.assert_not_called()
        self.assertEqual(r.json()["source"], "parser")
        self.assertEqual(r.json()["member_user_id"], self.mom.pk)
        self.assertIn("Yes", r.json()["text"])
        with mock.patch("core.ai.generate", return_value=("Assisto does not know.", 0.0)) as g:
            r = cl(self.kid).post("%s/family/brain/ask" % V, {"q": "did mom eat lunch"}, format="json")
            self.assertEqual(g.call_args.kwargs["feature"], "family.ask")
            self.assertIsNone(g.call_args.kwargs["user"])
        self.assertEqual(r.json()["source"], "ai")


# -------------------------------------------------------------- 6 Probashi
class ProbashiTests(Base):
    def test_carecall_slot_is_in_the_receivers_zone(self):
        from core import carecall as CC
        FB.ping(self.mom, {"tz": "Asia/Dubai", "tz_offset_min": 240})
        tz = CC.rtz(self.mom)
        after = datetime(2026, 11, 9, 0, 0, tzinfo=dt_tz.utc)
        nxt = CC.next_slot("daily", "09:00", [], None, after, tz)
        self.assertEqual(nxt.astimezone(ZoneInfo("Asia/Dubai")).hour, 9)
        self.assertEqual(CC.rtz(self.dad), CC.TZ)   # at home -> Dhaka

    def test_both_clocks(self):
        FB.ping(self.mom, {"tz": "Asia/Dubai"})
        c = FB.clocks(self.kid, self.mom)
        self.assertTrue(c["different"])
        self.assertEqual(c["diff_min"], -120)

    def test_member_endpoint(self):
        FB.ping(self.mom, {"battery": 50})
        r = cl(self.kid).get("%s/family/brain/member/%d" % (V, self.mom.pk))
        self.assertEqual(r.status_code, 200, r.content)
        self.assertIn("clocks", r.json())
        self.assertEqual(r.json()["brain"]["battery"], 50)


class TickCommandTests(Base):
    def test_command_runs(self):
        call_command("family_brain_tick", quiet=True)


class WatchTokenTests(Base):
    """The native FamilyWatchService posts with a SCOPED token, never the
    user's session; off = revoked at once."""
    def test_token_only_after_own_consent_and_revoked_when_off(self):
        from core.models import SavedPlace
        SavedPlace.objects.create(user=self.kid, label="school", name="Ideal School",
                                  lat=23.74, lng=90.37)
        c = cl(self.kid)
        self.assertEqual(c.post("%s/family/brain/watch" % V, {}, format="json").status_code, 409)
        c.post("%s/family/brain/prefs" % V, {"auto_arrive": True}, format="json")
        r = c.post("%s/family/brain/watch" % V, {}, format="json")
        self.assertEqual(r.status_code, 200)
        tok = r.json()["token"]
        self.assertEqual(r.json()["fences"][0]["kind"], "school")
        self.assertEqual(r.json()["fences"][0]["r"], 150)
        anon = APIClient()
        body = {"battery": 66, "watch_on": True, "events": [
            {"id": "w1", "kind": "arrive", "place_kind": "school", "place_id": 1}]}
        r = anon.post("%s/family/brain/watch-ping" % V, body, format="json", HTTP_X_FC_WATCH=tok)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["accepted"], 1)
        self.assertEqual(len(self.spy.calls), 2)
        self.assertEqual(anon.post("%s/family/brain/watch-ping" % V, body, format="json",
                                   HTTP_X_FC_WATCH="junk").status_code, 401)
        c.post("%s/family/brain/prefs" % V, {"auto_arrive": False}, format="json")
        self.assertEqual(anon.post("%s/family/brain/watch-ping" % V, body, format="json",
                                   HTTP_X_FC_WATCH=tok).status_code, 401)
        self.assertFalse(FB.state_of(self.kid)["watch_on"])

    def test_token_cannot_read_anything(self):
        FB.set_prefs(self.kid, self.kid, {"auto_arrive": True})
        tok = FB.watch_token(self.kid)
        r = APIClient().get("%s/family/brain/visibility" % V, HTTP_X_FC_WATCH=tok)
        self.assertIn(r.status_code, (401, 403))
