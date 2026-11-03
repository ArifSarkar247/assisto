"""chipbuy2 (owner 3 Nov): tracker chip LEFT-BEHIND alert + FIND NOW, and
the owner-editable "Buy — our own shop asalifymart" link list.

  * left-behind: opt-in; chip still > N min at a spot that is not a safe
    place -> ONE push to owner + guardian (child wording), not at night,
    not at home/school (School Mode places) or an owner-marked safe place,
    marking the spot safe stops it; bad minutes refused;
  * find now: queues a 10 s interval command (owner or guardian), once per
    10 min, 'acked' only from the device, normal intervals re-queued after
    10 min; a stranger gets 404;
  * buy links: Owner Admin list only (no price field), https asalifymart
    only, utm added, off rows hidden, max 3 per type, audited.
"""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase
from django.utils import timezone

from core import buy_links as BL
from core import chip_service as CS
from core import vehicle_service as VS
from core.models import OwnerAudit, VehicleCommand, VehicleTracker
from core.tests_chipbuy import V, _Base, fix_from_wire
from core.tests_kidswatch import CFG, HOME, SCHOOL, L, _east, cl
from web.tests_o2_owner_admin import OwnerBase

SHOP = _east(*HOME, 5000)          # a tuition centre, not home or school


def feed(t, at, pos, serial=1):
    VS.ingest({t.id: {"fixes": [fix_from_wire(at, *pos, serial=serial, speed=0)]}},
              now=at + timedelta(seconds=10))


class LeftBehindTests(_Base):
    def left_pushes(self):
        return [c for c in self.spy.calls if c["data"].get("alert") == "left_behind"]

    def test_still_at_unknown_place_alerts_once_to_guardians(self):
        t = self.pair()
        self.connect(t)
        r = self.c.patch(V + "/kids-watch/chips/%d" % t.id,
                         {"left_behind": {"on": True, "min": 30}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["chip"]["left_behind"]["min"], 30)
        n = 1
        for mm in (0, 10, 20, 31, 40, 50):
            feed(t, L(3, 15, mm), _east(*SHOP, n % 3), serial=n)   # GPS jitter only
            n += 1
        got = self.left_pushes()
        self.assertEqual(sorted(c["user"] for c in got), sorted([self.owner.id, self.mom.id]))
        self.assertIn("Rina", got[0]["ten"])
        self.assertIn("৩১", got[0]["bbn"])                      # Bangla digits
        self.assertEqual(got[0]["data"]["route"], "kids_watch")
        t.refresh_from_db()
        spot = CS.chip_json(t, self.owner)["left_behind"]["alerted_spot"]
        self.assertIsNotNone(spot)
        # owner marks the spot safe -> the card stops flagging it
        r = self.c.patch(V + "/kids-watch/chips/%d" % t.id,
                         {"left_behind": {"safe_add": {"lat": spot["lat"], "lng": spot["lng"],
                                                       "name": "Tuition"}}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIsNone(r.data["chip"]["left_behind"]["alerted_spot"])
        self.assertEqual(len(r.data["chip"]["left_behind"]["safe"]), 1)
        # moves away and back later: the safe place never alerts again
        feed(t, L(3, 17, 0), HOME, serial=50)
        for i, mm in enumerate((0, 40, 59)):
            feed(t, L(3, 18, mm), SHOP, serial=60 + i)
        self.assertEqual(len(self.left_pushes()), 2)

    def test_off_by_default_home_school_and_night_are_quiet(self):
        t = self.pair()
        self.connect(t)
        for i, mm in enumerate((0, 50)):
            feed(t, L(3, 10, mm), SHOP, serial=i + 1)
            feed(t, L(3, 11, mm), SHOP, serial=i + 10)
        self.assertEqual(self.left_pushes(), [])                # opt-in
        self.c.post(V + "/school-mode/plans", dict(CFG, chip_id=t.id), format="json")
        self.c.patch(V + "/kids-watch/chips/%d" % t.id,
                     {"left_behind": {"on": True, "min": 30}}, format="json")
        for i, mm in enumerate((0, 20, 45)):                     # at school all day
            feed(t, L(4, 12, mm), SCHOOL, serial=20 + i)
        for i, mm in enumerate((0, 20, 45)):                     # home in the evening
            feed(t, L(4, 18, mm), HOME, serial=30 + i)
        for i, (hh, mm) in enumerate(((22, 30), (23, 30), (23, 59))):   # night, away
            feed(t, L(4, hh, mm), SHOP, serial=40 + i)
        self.assertEqual(self.left_pushes(), [])

    def test_bad_settings_and_guardian_cannot_change(self):
        t = self.pair()
        r = self.c.patch(V + "/kids-watch/chips/%d" % t.id,
                         {"left_behind": {"min": 7}}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "bad_minutes"))
        r = self.c.patch(V + "/kids-watch/chips/%d" % t.id,
                         {"left_behind": {"safe_add": {"lat": "x"}}}, format="json")
        self.assertEqual(r.data["reason"], "bad_place")
        r = cl(self.mom).patch(V + "/kids-watch/chips/%d" % t.id,
                               {"left_behind": {"on": True}}, format="json")
        self.assertEqual(r.status_code, 403)

    def test_pure_anchor(self):
        now = timezone.now()
        st = CS.step_still({}, [{"at": now, "lat": SHOP[0], "lng": SHOP[1]}])
        st2 = CS.step_still(st, [{"at": now + timedelta(minutes=5),
                                  "lat": _east(*SHOP, 50)[0], "lng": _east(*SHOP, 50)[1]}])
        self.assertEqual(st2["since"], st["since"])                # jitter keeps the spot
        st3 = CS.step_still(st2, [{"at": now + timedelta(minutes=6), "lat": HOME[0],
                                   "lng": HOME[1]}])
        self.assertNotEqual(st3["since"], st["since"])              # moved = new spot


class FindNowTests(_Base):
    def test_find_queues_fast_interval_then_restores(self):
        t = self.pair()
        self.connect(t)
        r = cl(self.mom).post(V + "/kids-watch/chips/%d/find" % t.id)   # guardian may find
        self.assertEqual(r.status_code, 200, r.data)
        f = r.data["chip"]["find"]
        self.assertTrue(f["active"])
        self.assertEqual(f["command"], "queued")                   # not "done" until the chip says OK
        cmd = VehicleCommand.objects.get(tracker=t, state="queued")
        self.assertEqual(cmd.payload["moving_s"], CS.FIND_INTERVAL_S)
        r = self.c.post(V + "/kids-watch/chips/%d/find" % t.id)
        self.assertEqual((r.status_code, r.data["reason"]), (409, "too_soon"))
        VS.mark_sent(cmd.id, "TIMER,10,10#", 1)
        VS.mark_reply(t.id, "OK", True, 1)
        t.refresh_from_db()
        self.assertEqual(CS.chip_json(t, self.owner)["find"]["command"], "acked")
        later = timezone.now() + timedelta(minutes=CS.FIND_MIN + 1)
        self.assertTrue(CS.end_find_if_due(t, later))
        back = VehicleCommand.objects.filter(tracker=t, state="queued").get()
        self.assertEqual(back.payload["moving_s"], CS.MOVING_INTERVAL_S)
        self.assertFalse(CS.end_find_if_due(t, later))             # only once
        self.assertFalse(CS.chip_json(t, self.owner, later)["find"]["active"])

    def test_find_refusals(self):
        t = self.pair()                                              # not yet paired
        r = self.c.post(V + "/kids-watch/chips/%d/find" % t.id)
        self.assertEqual(r.data["reason"], "not_paired")
        r = cl(self.x).post(V + "/kids-watch/chips/%d/find" % t.id)
        self.assertEqual(r.status_code, 404)

    def test_chip_json_is_honest_about_range(self):
        t = self.pair()
        self.assertEqual(CS.chip_json(t, self.owner)["range"], "gps_network")


class BuyLinksTests(TestCase):
    def setUp(self):
        cache.clear()

    def test_url_rules(self):
        self.assertEqual(BL.clean_url("https://asalifymart.com/p/chip-4g"),
                         "https://asalifymart.com/p/chip-4g?utm_source=assisto")
        self.assertEqual(BL.clean_url("https://WWW.asalifymart.com/x?a=1&utm_source=z"),
                         "https://www.asalifymart.com/x?a=1&utm_source=assisto")
        for bad in ("http://asalifymart.com/", "https://asalifymart.com.evil.io/",
                    "https://evil.io/?asalifymart.com", "javascript:alert(1)",
                    "https://user:pw@asalifymart.com/", "https://asalifymart.com:8443/", ""):
            self.assertIsNone(BL.clean_url(bad), bad)

    def test_seed_then_owner_list_no_prices(self):
        self.assertEqual({i["category"] for i in BL.public()["items"]}, set(BL.CATEGORIES))
        ok, problems, _, _ = BL.save([
            {"category": "chip", "title_bn": "৪জি চিপ", "title_en": "4G chip",
             "url": "https://asalifymart.com/chip", "on": True, "price": 999},
            {"category": "chip", "url": "https://asalifymart.com/b", "on": False},
            {"category": "cctv", "url": "https://asalifymart.com/c", "on": True},
            {"category": "chip", "url": "", "title_bn": "removed"},
        ])
        self.assertTrue(ok, problems)
        pub = BL.public("chip")
        self.assertTrue(pub["own_shop"])
        self.assertEqual([i["title_en"] for i in pub["items"]], ["4G chip"])
        self.assertNotIn("price", pub["items"][0])
        self.assertEqual(BL.public("vehicle")["items"], [])        # owner removed it
        ok, problems, _, _ = BL.save([{"category": "chip", "url": "https://x.com/"}])
        self.assertFalse(ok)
        self.assertEqual(problems, ["bad_url:1"])

    def test_api(self):
        from core.tests_kidswatch import mk
        u = mk("01711399001", "Buyer")
        r = cl(u).get(V + "/app/buy-links?category=chip")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["shop"], "asalifymart")
        self.assertEqual(cl(u).get(V + "/app/buy-links?category=x").status_code, 400)


class BuyLinksOwnerAdminTests(OwnerBase):
    def test_owner_edits_list_with_audit(self):
        cache.clear()
        self.ready()
        r = self.c.get("/owner/buy-links?lang=bn")
        self.assertContains(r, "কেনার লিংক")
        r = self.post("/owner/buy-links", {
            "category": ["chip", "cctv"], "title_bn": ["চিপ", ""], "title_en": ["Chip", ""],
            "url": ["https://asalifymart.com/chip", ""], "on": ["0"]})
        self.assertEqual(r.status_code, 302)
        self.assertEqual([i["url"] for i in BL.items()],
                         ["https://asalifymart.com/chip?utm_source=assisto"])
        self.assertTrue(OwnerAudit.objects.filter(action="buy_links.save").exists())
        r = self.post("/owner/buy-links", {"category": ["chip"], "title_bn": [""],
                                           "title_en": [""], "url": ["https://evil.io/"]})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(len(BL.items()), 1)
