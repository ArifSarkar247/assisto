"""fcelder — Silent Watch + Elder setup by a child (server side).

E2E with a FAKE CLOCK: child makes a QR code -> elder's one spoken YES ->
the elder's phone raises the ONE alert event -> ladder setter (now) -> all
family (+15) -> nearby person (+30); "I am OK" stops it and tells everyone
told; "I am checking" stops the ladder. Care Call missed after retries ->
the server asks the elder first, then the same ladder. Privacy: the token
is stored hashed, wrong phone / expired / stranger refused, no tracking.
"""
from datetime import timedelta
from unittest import mock

from django.test import TestCase
from django.utils import timezone

from core import carecall as CC
from core import silent_watch as SW
from core.models import CareCall, CareCallLink, CareCallRing, PaCollectionItem
from core.tests_carecall import V, cl, mk, pair


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "tbn": tbn, "ten": ten,
                           "bbn": bbn, "ben": ben, "data": dict(data or {})})
        return True

    def to(self, u, kind=None):
        return [c for c in self.calls if c["user"] == u.pk and (kind is None or c["kind"] == kind)]


class Base(TestCase):
    def setUp(self):
        self.arif = mk("01711100001", "Arif Hasan")             # son, sets it up
        self.ammu = mk("01711100002", "Rahima", lang="bn")      # elder
        self.bina = mk("01711100003", "Bina")                   # daughter
        self.nabil = mk("01711100004", "Nabil")                 # nearby neighbour
        self.stranger = mk("01711100005", "Stranger")
        pair(self.arif, self.ammu)
        pair(self.bina, self.ammu, "Ammu", "Bina")
        pair(self.arif, self.nabil, "Nabil", "Arif")
        self.spy = Spy()
        for mod in (SW, CC):
            p = mock.patch.object(mod, "_push", self.spy)
            p.start()
            self.addCleanup(p.stop)
        self.a, self.m = cl(self.arif), cl(self.ammu, "bn")
        self.t0 = timezone.now()

    def setup_elder(self, **kw):
        body = {"elder_user_id": self.ammu.pk, "hours": 4, "nearby_user_id": self.nabil.pk}
        body.update(kw)
        r = self.a.post(V + "/family/elder-setup", body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        code = r.json()["code"]
        self.assertEqual(r.json()["url"], "https://lifeassisto.com/e/" + code)
        p = self.m.get(V + "/family/elder-setup/" + code)
        self.assertEqual(p.status_code, 200, p.content)
        self.assertEqual(p.json()["child_name"], "Arif")
        y = self.m.post(V + "/family/elder-setup/%s/accept" % code, {"yes": True}, format="json")
        self.assertEqual(y.status_code, 200, y.content)
        return y.json()


class SetupTests(Base):
    def test_qr_yes_configures_everything(self):
        out = self.setup_elder()
        self.assertTrue(out["config"]["enabled"])
        self.assertEqual(out["config"]["hours"], 4)
        self.assertEqual(out["config"]["setter_id"], self.arif.pk)
        self.assertEqual(out["config"]["nearby_user_id"], self.nabil.pk)
        self.assertTrue(out["plan"]["easy_home"])
        # Care Call accepted by the same YES
        link = CareCallLink.objects.get(setter=self.arif, receiver=self.ammu)
        self.assertEqual(link.status, "accepted")
        # token stored only as a hash
        row = PaCollectionItem.objects.get(user=self.ammu, collection="sw_cfg")
        self.assertNotIn(out["token"], str(row.data))
        self.assertEqual(SW.elder_for_token(out["token"]), self.ammu)
        self.assertEqual(len(self.spy.to(self.arif, "elder_setup_done")), 1)
        # Easy Home's one-tap call buttons: the elder's family with phone + relation
        fam = self.m.get(V + "/family/silent-watch").json()["family"]
        son = [f for f in fam if f["user_id"] == self.arif.pk][0]
        self.assertEqual((son["relation"], son["phone"]), ("son", self.arif.phone))

    def test_code_single_use_wrong_phone_expired_stranger(self):
        r = self.a.post(V + "/family/elder-setup", {"elder_user_id": self.ammu.pk}, format="json")
        code = r.json()["code"]
        # someone else's phone
        self.assertEqual(cl(self.bina).get(V + "/family/elder-setup/" + code).status_code, 403)
        # no YES = nothing
        self.assertEqual(self.m.post(V + "/family/elder-setup/%s/accept" % code, {}, format="json").status_code, 404)
        self.assertEqual(self.m.post(V + "/family/elder-setup/%s/accept" % code, {"yes": True},
                                     format="json").status_code, 200)
        self.assertEqual(self.m.post(V + "/family/elder-setup/%s/accept" % code, {"yes": True},
                                     format="json").status_code, 404)        # single use
        # stranger is not family
        r = self.a.post(V + "/family/elder-setup", {"elder_user_id": self.stranger.pk}, format="json")
        self.assertEqual(r.status_code, 404)
        # expired
        r = self.a.post(V + "/family/elder-setup", {"elder_user_id": self.ammu.pk}, format="json")
        out, err = SW.preview_pair(self.ammu, r.json()["code"], now=self.t0 + timedelta(minutes=16))
        self.assertEqual(err, "code_expired")
        # nearby person must be family / circle
        r = self.a.post(V + "/family/elder-setup", {"elder_user_id": self.ammu.pk,
                                                    "nearby_user_id": self.stranger.pk}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "nearby_not_family")

    def test_bad_token_refused_and_nothing_tracked(self):
        self.setup_elder()
        c = cl(self.stranger)
        c.logout()
        r = c.post(V + "/family/silent-watch/alert", {"token": "x" * 40}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertFalse(PaCollectionItem.objects.filter(collection="sw_alert").exists())
        # the elder's phone never sends activity: no such route exists
        from django.urls import Resolver404, resolve
        with self.assertRaises(Resolver404):
            resolve(V + "/family/silent-watch/activity")

    def test_elder_can_turn_off_and_setter_is_told(self):
        self.setup_elder()
        r = self.m.post(V + "/family/silent-watch", {"enabled": False}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.json()["config"]["enabled"])
        self.assertEqual(len(self.spy.to(self.arif, "silentwatch_off")), 1)
        r = self.m.post(V + "/family/silent-watch", {"hours": 30}, format="json")
        self.assertEqual(r.status_code, 400)


class LadderE2E(Base):
    """The proof the owner asked for: the full ladder on a fake clock."""

    def test_inactivity_ladder_setter_family_nearby_then_ok(self):
        tok = self.setup_elder()["token"]
        anon = cl(self.stranger)
        anon.logout()
        # the PHONE: 3 unanswered "Are you OK?" rings -> ONE event
        with mock.patch("django.utils.timezone.now", return_value=self.t0):
            r = anon.post(V + "/family/silent-watch/alert",
                          {"token": tok, "kind": "inactivity", "silent_min": 300}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["step"], 1)
        # step 1: setter only, at once
        self.assertEqual(len(self.spy.to(self.arif, "silentwatch_alert")), 1)
        self.assertIn("Check on Ammu", self.spy.to(self.arif, "silentwatch_alert")[0]["ten"])
        self.assertEqual(self.spy.to(self.bina, "silentwatch_alert"), [])
        self.assertEqual(self.spy.to(self.nabil, "silentwatch_alert"), [])
        # idempotent: the phone retrying does not start a second ladder
        with mock.patch("django.utils.timezone.now", return_value=self.t0 + timedelta(minutes=1)):
            anon.post(V + "/family/silent-watch/alert", {"token": tok}, format="json")
        self.assertEqual(len(self.spy.to(self.arif, "silentwatch_alert")), 1)
        # +14 min: nothing new
        SW.tick(now=self.t0 + timedelta(minutes=14))
        self.assertEqual(self.spy.to(self.bina, "silentwatch_alert"), [])
        # +15: all family (Bina), setter not told twice
        SW.tick(now=self.t0 + timedelta(minutes=15, seconds=1))
        self.assertEqual(len(self.spy.to(self.bina, "silentwatch_alert")), 1)
        self.assertEqual(len(self.spy.to(self.arif, "silentwatch_alert")), 1)
        self.assertEqual(self.spy.to(self.nabil, "silentwatch_alert"), [])
        # +30: the chosen nearby person
        SW.tick(now=self.t0 + timedelta(minutes=30, seconds=2))
        self.assertEqual(len(self.spy.to(self.nabil, "silentwatch_alert")), 1)
        self.assertIn("asking you", self.spy.to(self.nabil, "silentwatch_alert")[0]["ten"])
        # ladder ends: no more pushes ever
        n = len(self.spy.calls)
        SW.tick(now=self.t0 + timedelta(hours=3))
        self.assertEqual(len(self.spy.calls), n)
        # family sees it
        w = self.a.get(V + "/family/silent-watch").json()["watching"]
        self.assertEqual(w[0]["elder_id"], self.ammu.pk)
        self.assertEqual(w[0]["alert"]["status"], "open")
        # ONE tap "I am OK" (native button: token, no account)
        r = anon.post(V + "/family/silent-watch/ok", {"token": tok}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["resolved"])
        for u in (self.arif, self.bina, self.nabil):
            self.assertEqual(len(self.spy.to(u, "silentwatch_ok")), 1, u.name)
        self.assertIsNone(SW.open_alert(self.ammu))

    def test_i_am_checking_stops_the_ladder(self):
        tok = self.setup_elder()["token"]
        r, _ = SW.raise_alert(self.ammu, "inactivity", 280, now=self.t0)
        res = cl(self.arif).post(V + "/family/silent-watch/alerts/%d/ack" % r.pk, {}, format="json")
        self.assertEqual(res.status_code, 200, res.content)
        self.assertEqual(res.json()["alert"]["status"], "checking")
        SW.tick(now=self.t0 + timedelta(hours=1))
        self.assertEqual(self.spy.to(self.bina, "silentwatch_alert"), [])   # nobody else woken
        # a stranger cannot ack
        self.assertEqual(cl(self.stranger).post(V + "/family/silent-watch/alerts/%d/ack" % r.pk, {},
                                                format="json").status_code, 404)
        self.assertTrue(tok)

    def test_carecall_missed_asks_elder_first_then_ladder(self):
        self.setup_elder()
        self.spy.calls.clear()
        r = self.a.post(V + "/carecall", {"receiver_id": self.ammu.pk, "text": "Are you well?",
                                          "time": "10:00", "repeat": "daily"}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        t0 = CareCall.objects.get().next_at
        CC.tick(now=t0 + timedelta(seconds=5))
        CC.tick(now=t0 + timedelta(minutes=4))
        CC.tick(now=t0 + timedelta(minutes=10, seconds=10))
        CC.tick(now=t0 + timedelta(minutes=14))                 # missed twice
        self.assertEqual(CareCallRing.objects.get().status, "missed")
        # the ELDER is asked first; family not woken yet
        self.assertEqual(len(self.spy.to(self.ammu, "silentwatch_ask")), 1)
        self.assertEqual(self.spy.to(self.arif, "silentwatch_alert"), [])
        CC.tick(now=t0 + timedelta(minutes=14 + SW.ASK_WAIT_MIN, seconds=30))
        self.assertEqual(len(self.spy.to(self.arif, "silentwatch_alert")), 1)
        self.assertEqual(self.spy.to(self.arif, "silentwatch_alert")[0]["data"]["kind"], "carecall")
        self.assertIn("Care Call", self.spy.to(self.arif, "silentwatch_alert")[0]["ben"])

    def test_elder_ok_while_asking_means_no_family_alert(self):
        self.setup_elder()
        r, err = SW.start_test(self.arif, self.ammu, now=self.t0)
        self.assertIsNone(err)
        self.assertEqual(len(self.spy.to(self.ammu, "silentwatch_ask")), 1)
        self.m.post(V + "/family/silent-watch/ok", {}, format="json")
        SW.tick(now=self.t0 + timedelta(hours=1))
        self.assertEqual(self.spy.to(self.arif, "silentwatch_alert"), [])
        # only the setter can run a test
        _, err = SW.start_test(self.bina, self.ammu, now=self.t0)
        self.assertEqual(err, "not_setter")

    def test_off_watch_raises_nothing(self):
        tok = self.setup_elder(silent_watch=False)["token"]
        anon = cl(self.stranger)
        anon.logout()
        r = anon.post(V + "/family/silent-watch/alert", {"token": tok}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertIsNone(SW.on_carecall_missed(self.ammu))


class LandingTests(TestCase):
    def test_e_link_fallback_page(self):
        from rest_framework.test import APIClient
        r = APIClient().get("/e/abcd2345")
        self.assertEqual(r.status_code, 200)
        self.assertIn("ABCD2345", r.content.decode())
        self.assertEqual(r["Cache-Control"], "no-store")
        r = APIClient().get("/e/<script>")
        self.assertNotIn("<script>", r.content.decode().split("<body>")[1])


class BanglaDigitCodeTests(Base):
    def test_code_typed_with_bangla_digits_works(self):
        r = self.a.post(V + "/family/elder-setup", {"elder_user_id": self.ammu.pk}, format="json")
        code = r.json()["code"]
        bn = code.translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")).lower()
        out, err = SW.preview_pair(self.ammu, bn)
        self.assertIsNone(err)
        self.assertEqual(out["child_name"], "Arif")
