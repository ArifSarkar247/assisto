"""fcrest — Family Care V3 rest (owner order 9 Nov 10:50, items left after
fcscreen / fcbrain / fcsos / fcelder):

* d) a member outside every saved place shows the AREA name from their own
  phone's Geocoder — only with their own "tell my family" switch on, never
  while paused, never coordinates, gone after 3 h, a saved place wins;
* BRAIN 3) the 15 % battery last location reaches the v3 Family board;
* 6) Probashi: a member sets their own abroad time zone (nobody else can),
  the family then sees someone_abroad;
* admin tools the app now shows: rename a family, edit a label, remove.
All data below is made up."""
from datetime import timedelta
from unittest import mock

from django.utils import timezone

from core import family_brain as FB
from core.tests_fcscreen import Base, V


class FcRestBase(Base):
    def setUp(self):
        super().setUp()
        self.fid = self.fam()["families"][0]["id"]
        self.join(self.ab, self.cb, self.fid)          # Ammu joins Rina's family

    def board_row(self, uid, client=None):
        r = (client or self.ca).get(f"{V}/family/v3/families/{self.fid}/board")
        self.assertEqual(r.status_code, 200, r.content)
        return next(m for m in r.json()["members"] if m["user_id"] == uid)

    def ping(self, client, **body):
        r = client.post(f"{V}/family/brain/ping", body, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def auto_on(self, client):
        r = client.post(f"{V}/family/brain/prefs", {"auto_arrive": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)


class AreaTest(FcRestBase):
    def test_area_needs_own_switch(self):
        self.ping(self.cb, battery=80, area={"label": "Dhanmondi"})
        self.assertIsNone(self.board_row(self.b.id)["brain"].get("place_kind"))

    def test_area_shown_then_expires(self):
        self.auto_on(self.cb)
        self.ping(self.cb, battery=80, area={"label": "  Dhanmondi   27 "})
        br = self.board_row(self.b.id)["brain"]
        self.assertEqual(br["place_kind"], "area")
        self.assertEqual(br["place_label"], "Dhanmondi 27")
        st = FB.state_of(self.b)
        self.assertNotIn("lat", st["area"])                 # a name only
        later = timezone.now() + timedelta(hours=FB.AREA_TTL_H, minutes=5)
        self.assertIsNone(FB.member_brain_state(self.a, self.b, now=later).get("place_kind"))

    def test_saved_place_wins_and_clears_area(self):
        self.auto_on(self.cb)
        self.ping(self.cb, area={"label": "Mirpur"})
        self.ping(self.cb, events=[{"id": "e1", "kind": "arrive", "place_kind": "home",
                                    "place_label": "", "at": timezone.now().isoformat()}])
        br = self.board_row(self.b.id)["brain"]
        self.assertEqual(br["place_kind"], "home")
        self.assertNotIn("area", FB.state_of(self.b))
        # while at home a stray area report is ignored
        self.ping(self.cb, area={"label": "Mirpur"})
        self.assertEqual(self.board_row(self.b.id)["brain"]["place_kind"], "home")

    def test_paused_member_shares_no_area(self):
        self.auto_on(self.cb)
        r = self.cb.post(f"{V}/family/brain/pause", {"hours": 1}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.ping(self.cb, area={"label": "Gulshan"})
        self.assertNotIn("area", FB.state_of(self.b))
        self.assertIsNone(self.board_row(self.b.id)["brain"].get("place_label"))

    def test_stranger_never_sees_area(self):
        self.auto_on(self.cb)
        self.ping(self.cb, area={"label": "Uttara"})
        self.assertIsNone(FB.member_brain_state(self.x, self.b))


class LowBatteryTest(FcRestBase):
    def test_last_location_on_the_board(self):
        self.ping(self.cb, battery=60)
        now = timezone.now().isoformat()
        with mock.patch("core.family_alerts.alert", return_value={"recipients": 1}):
            self.ping(self.cb, battery=14, events=[
                {"id": "b1", "kind": "battery_low", "at": now, "lat": 23.75, "lng": 90.39, "acc": 30}])
        loc = self.board_row(self.b.id)["brain"]["last_location"]
        self.assertEqual(loc["why"], "battery_low")
        self.assertAlmostEqual(loc["lat"], 23.75)


class ProbashiAndAdminTest(FcRestBase):
    def test_only_self_sets_abroad_tz(self):
        url = f"{V}/family/v3/families/{self.fid}/members/{self.b.id}"
        self.assertNotEqual(self.ca.post(url, {"abroad_tz": "Asia/Riyadh"}, format="json").status_code, 200)
        self.assertEqual(self.cb.post(url, {"abroad_tz": "Bad/Zone"}, format="json").status_code, 400)
        self.assertEqual(self.cb.post(url, {"abroad_tz": "Asia/Riyadh"}, format="json").status_code, 200)
        r = self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()
        self.assertTrue(r["someone_abroad"])
        self.assertEqual(self.board_row(self.b.id)["abroad_tz"], "Asia/Riyadh")
        # back home: empty clears it
        self.assertEqual(self.cb.post(url, {"abroad_tz": ""}, format="json").status_code, 200)
        self.assertFalse(self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()["someone_abroad"])

    def test_admin_rename_label_remove(self):
        r = self.cb.post(f"{V}/family/v3/families/{self.fid}/rename", {"name": "Hacked"}, format="json")
        self.assertNotEqual(r.status_code, 200)
        r = self.ca.post(f"{V}/family/v3/families/{self.fid}/rename", {"name": "Parents home"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(self.fam()["families"][0]["name"], "Parents home")
        url = f"{V}/family/v3/families/{self.fid}/members/{self.b.id}"
        self.assertEqual(self.ca.post(url, {"label": "Ammu"}, format="json").status_code, 200)
        self.assertEqual(self.board_row(self.b.id)["label"], "Ammu")
        r = self.ca.post(f"{V}/family/v3/families/{self.fid}/remove/{self.b.id}")
        self.assertEqual(r.status_code, 200, r.content)
        ids = [m["user_id"] for m in self.ca.get(f"{V}/family/v3/families/{self.fid}/board").json()["members"]]
        self.assertNotIn(self.b.id, ids)
