"""gap-quranblood (owner order 17 Nov 10:10, feature gap sweep): Blood donor
gaps B1 (a donor who blocked someone disappears for that person: search,
push targets, responders, number) and B7 (helped count on listed cards).
Gap list: owner_actions/gaps/blood_BN.md."""
from core import blood_panel as BP
from core.models import BloodRecipient, BloodRequest, BloodThread

from .tests_blood import MIRPUR, NEAR, Base


class BlockedDonorHiddenTests(Base):
    def _block(self, donor_user, seeker):
        th = BloodThread.objects.create(donor=donor_user, seeker=seeker)
        r = self.api(donor_user).post("/api/v1/blood-panel/threads/%d/block" % th.id,
                                      {"on": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        return th

    def _search_ids(self, user):
        r = self.api(user).get("/api/v1/blood-panel/donors",
                               {"group": "A+", "lat": MIRPUR[0], "lng": MIRPUR[1]})
        self.assertEqual(r.status_code, 200, r.content)
        return [x["id"] for x in r.json()["donors"]]

    def test_blocked_seeker_no_longer_finds_donor_or_number(self):
        a, d = self.donor("Ahad Khan", "A+", NEAR, phone_public=True)
        _b, other = self.donor("Bari", "A+", NEAR)
        self.assertIn(d.id, self._search_ids(self.req_user))
        th = self._block(a, self.req_user)
        ids = self._search_ids(self.req_user)
        self.assertNotIn(d.id, ids)                 # hidden from the blocked person
        self.assertIn(other.id, ids)                # nobody else is hidden
        stranger = self.mk("Stranger Two")
        self.assertIn(d.id, self._search_ids(stranger))   # still listed to everyone else
        # the blocked person's thread never carries the number
        t = self.api(self.req_user).get("/api/v1/blood-panel/threads/%d" % th.id).json()
        self.assertIsNone(t["thread"]["phone"])

    def test_seeker_blocking_donor_does_not_hide_donor(self):
        a, d = self.donor("Ahad", "A+", NEAR)
        th = BloodThread.objects.create(donor=a, seeker=self.req_user)
        self.api(self.req_user).post("/api/v1/blood-panel/threads/%d/block" % th.id,
                                     {"on": True}, format="json")
        self.assertIn(d.id, self._search_ids(self.req_user))

    def test_blocked_seeker_request_not_pushed_and_not_listed_as_responder(self):
        a, _d = self.donor("Ahad", "A+", NEAR)
        b, _e = self.donor("Bari", "A+", NEAR)
        self._block(a, self.req_user)
        r = self.post_req()
        self.assertEqual(r.status_code, 201, r.content)
        req = BloodRequest.objects.get(pk=r.json()["request"]["id"])
        BP.fan_out(req.id)
        users = set(BloodRecipient.objects.filter(request=req).values_list("user_id", flat=True))
        self.assertNotIn(a.id, users)
        self.assertIn(b.id, users)
        # even an old "I can" row from that donor is not shown to the requester
        BloodRecipient.objects.create(request=req, user=a, response="can")
        names = [x["name"] for x in BP.responders(req, "en")]
        self.assertNotIn("Ahad", names)


class HelpedOnCardsTests(Base):
    def test_listed_card_carries_helped_count(self):
        a, d = self.donor("Ahad", "A+", NEAR)
        r = self.post_req()
        req = BloodRequest.objects.get(pk=r.json()["request"]["id"])
        BloodRecipient.objects.update_or_create(request=req, user=a,
                                                defaults={"response": "donated"})
        seeker = self.mk("Someone Else")
        rows = self.api(seeker).get("/api/v1/blood-panel/donors",
                                    {"group": "A+", "lat": MIRPUR[0], "lng": MIRPUR[1]}).json()["donors"]
        card = {x["id"]: x for x in rows}[d.id]
        self.assertEqual(card["helped"], 1)
        self.assertNotIn("phone_number", card)
