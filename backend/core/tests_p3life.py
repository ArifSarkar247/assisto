"""p3life — travel legs/docs, wedding schedule/vendors/gifts, food log
collections + signed read-only share links and guest RSVP links."""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from rest_framework.test import APITestCase

from core import life_share as LS
from core.models import PaCollectionItem

User = get_user_model()
API = "/api/v1/"


class P3LifeTests(APITestCase):
    def setUp(self):
        cache.clear()
        mk = User.objects.create_user
        self.u = mk(name="Host", phone="01710009001", password="pw")
        self.o = mk(name="Other", phone="01710009002", password="pw")
        self.client.force_authenticate(self.u)

    def _mk(self, path, body):
        r = self.client.post(API + path + "/", body, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return r.json()["id"]

    def _link(self, kind, rid, user=None):
        if user:
            self.client.force_authenticate(user)
        r = self.client.post(API + "life/share", {"kind": kind, "id": rid},
                             format="json")
        self.client.force_authenticate(self.u)
        return r

    # ---- new generic collections ----
    def test_new_collections_round_trip_and_scoped(self):
        for path, body in [
            ("travel/legs", {"trip_id": 1, "mode": "train", "from": "Dhaka",
                             "to": "Sylhet", "date": "2026-12-01", "ref": "705"}),
            ("travel/docs", {"trip_id": 1, "kind": "passport",
                             "expiry": "2027-01-01"}),
            ("wedding/schedule", {"title": "Gaye holud", "date": "2026-12-10"}),
            ("wedding/vendors", {"name": "Decor", "quote": 5000000, "paid": 0}),
            ("wedding/gifts", {"giver": "Mama", "gift": "cash",
                               "amount": 500000}),
            ("food/orders", {"date": "2026-11-03", "provider": "foodpanda",
                             "amount": 45000}),
        ]:
            rid = self._mk(path, body)
            rows = self.client.get(API + path + "/").json()
            self.assertEqual(rows[0]["id"], rid)
            self.client.force_authenticate(self.o)
            self.assertEqual(self.client.get(API + path + "/").json(), [])
            self.client.force_authenticate(self.u)

    # ---- share links ----
    def test_trip_link_shows_plan_never_budget(self):
        tid = self._mk("travel/trips", {"destination": "Sreemangal",
                                        "start": "2026-12-01", "end": "2026-12-03"})
        self._mk("travel/days", {"trip_id": tid, "day": 1, "title": "Tea garden",
                                 "activities": [{"what": "Walk", "place": "Lawachara"}]})
        self._mk("travel/legs", {"trip_id": tid, "mode": "train", "from": "Dhaka",
                                 "to": "Sreemangal", "date": "2026-12-01",
                                 "time": "06:40", "ref": "Parabat 709"})
        self._mk("travel/budget", {"trip_id": tid, "category": "stay",
                                   "estimate": 777777})
        self._mk("travel/docs", {"trip_id": tid, "kind": "nid", "label": "SECRETDOC"})
        r = self._link("trip", tid)
        self.assertEqual(r.status_code, 200)
        url = r.json()["url"]
        self.assertIn("/p/", url)
        page = self.client.get(url[url.index("/p/"):])
        self.assertEqual(page.status_code, 200)
        body = page.content.decode()
        self.assertIn("Sreemangal", body)
        self.assertIn("Lawachara", body)
        self.assertIn("Parabat 709", body)
        self.assertIn("ট্রেন", body)
        self.assertIn("১ ডিসেম্বর ২০২৬", body)
        self.assertNotIn("777777", body)
        self.assertNotIn("SECRETDOC", body)
        self.assertEqual(page["X-Robots-Tag"], "noindex, nofollow")
        en = self.client.get(url[url.index("/p/"):] + "?lang=en").content.decode()
        self.assertIn("1 Dec 2026", en)

    def test_cannot_link_someone_elses_row(self):
        tid = self._mk("travel/trips", {"destination": "X"})
        self.assertEqual(self._link("trip", tid, user=self.o).status_code, 404)
        self.assertEqual(self._link("nope", tid).status_code, 400)
        self.assertEqual(self._link("trip", "abc").status_code, 400)

    def test_revoke_kills_old_link_and_new_link_works(self):
        tid = self._mk("travel/trips", {"destination": "Bandarban"})
        url = self._link("trip", tid).json()["url"]
        path = url[url.index("/p/"):]
        r = self.client.post(API + "life/share/revoke", {"kind": "trip", "id": tid},
                             format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.client.get(path).status_code, 410)
        url2 = self._link("trip", tid).json()["url"]
        self.assertNotEqual(url, url2)
        self.assertEqual(self.client.get(url2[url2.index("/p/"):]).status_code, 200)
        self.assertEqual(self.client.get(path).status_code, 410)

    def test_bad_and_tampered_tokens(self):
        self.assertEqual(self.client.get("/p/garbage").status_code, 404)
        tid = self._mk("travel/trips", {"destination": "Y"})
        url = self._link("trip", tid).json()["url"]
        tok = url.split("/p/")[1]
        self.assertEqual(self.client.get("/p/" + tok[:-2] + "xx").status_code, 404)
        # a trip token is not a guest RSVP token
        self.assertEqual(self.client.get("/rsvp/" + tok).status_code, 404)

    def test_event_link_counts_and_hides_money(self):
        eid = self._mk("wedding/event", {"title": "Rina weds Karim",
                                         "event_date": "2026-12-12", "venue": "Senakunja"})
        self._mk("wedding/schedule", {"title": "Bou-bhat", "date": "2026-12-14",
                                      "time": "19:00", "place": "Home"})
        self._mk("wedding/guests", {"name": "SECRETGUEST", "rsvp": "yes", "plus_ones": 2})
        self._mk("wedding/gifts", {"giver": "GIFTGIVER", "amount": 999999})
        url = self._link("event", eid).json()["url"]
        body = self.client.get(url[url.index("/p/"):]).content.decode()
        self.assertIn("Rina weds Karim", body)
        self.assertIn("Bou-bhat", body)
        self.assertIn("১৯:০০", body)
        self.assertIn('<span class="lp-n">৩</span>', body)  # 1 + 2 confirmed
        self.assertNotIn("SECRETGUEST", body)
        self.assertNotIn("GIFTGIVER", body)

    # ---- RSVP ----
    def test_guest_rsvp_link_records_answer(self):
        self._mk("wedding/event", {"title": "Akika", "event_date": "2026-12-20"})
        gid = self._mk("wedding/guests", {"name": "Shila", "rsvp": "invited",
                                          "plus_ones": 0, "phone": "01700000000"})
        self._mk("wedding/guests", {"name": "OTHERGUEST"})
        url = self._link("guest", gid).json()["url"]
        self.assertIn("/rsvp/", url)
        path = url[url.index("/rsvp/"):]
        self.client.force_authenticate(None)
        page = self.client.get(path)
        self.assertEqual(page.status_code, 200)
        self.assertIn("Shila", page.content.decode())
        self.assertNotIn("OTHERGUEST", page.content.decode())
        self.assertNotIn("01700000000", page.content.decode())
        r = self.client.post(path, {"answer": "yes", "plus_ones": "2"})
        self.assertEqual(r.status_code, 200)
        g = PaCollectionItem.objects.get(id=gid).data
        self.assertEqual((g["rsvp"], g["plus_ones"], g["rsvp_via"]), ("yes", 2, "link"))
        self.assertEqual(g["name"], "Shila")  # merged, not replaced
        # bad input is refused and changes nothing
        self.assertEqual(self.client.post(path, {"answer": "sure"}).status_code, 400)
        self.assertEqual(self.client.post(path, {"answer": "yes",
                                                 "plus_ones": "99"}).status_code, 400)
        self.assertEqual(PaCollectionItem.objects.get(id=gid).data["plus_ones"], 2)
        # "no" clears companions
        self.client.post(path, {"answer": "no", "plus_ones": "3"})
        g = PaCollectionItem.objects.get(id=gid).data
        self.assertEqual((g["rsvp"], g["plus_ones"]), ("no", 0))

    def test_guest_link_revoked(self):
        gid = self._mk("wedding/guests", {"name": "A"})
        url = self._link("guest", gid).json()["url"]
        self.client.post(API + "life/share/revoke", {"kind": "guest", "id": gid},
                         format="json")
        path = url[url.index("/rsvp/"):]
        self.assertEqual(self.client.get(path).status_code, 410)
        self.assertEqual(self.client.post(path, {"answer": "yes"}).status_code, 410)

    # ---- pure helpers ----
    def test_nice_date_and_digits(self):
        self.assertEqual(LS.nice_date("2026-02-05"), "৫ ফেব্রুয়ারি ২০২৬")
        self.assertEqual(LS.nice_date("2026-02-05", "en"), "5 Feb 2026")
        self.assertEqual(LS.nice_date("junk"), "")
        self.assertEqual(LS.nice_date(None), "")
        self.assertIsNone(LS.read_token("x:y:z"))
        self.assertEqual(LS.leg_view({"mode": "rocket"})["mode"], "other")


class P3LifeCsrfTests(APITestCase):
    """The RSVP form must work with real CSRF checks (a browser posting the
    form it was served)."""

    def test_rsvp_form_posts_with_csrf(self):
        from django.test import Client
        u = User.objects.create_user(name="H", phone="01710009011", password="pw")
        g = PaCollectionItem.objects.create(user=u, collection="wedding/guests",
                                            data={"name": "Mina"})
        url = LS.issue(u, "guest", g.id)
        path = url[url.index("/rsvp/"):]
        c = Client(enforce_csrf_checks=True)
        page = c.get(path)
        self.assertEqual(page["Referrer-Policy"], "same-origin")
        tok = page.cookies["csrftoken"].value
        r = c.post(path, {"answer": "maybe", "plus_ones": "1",
                          "csrfmiddlewaretoken": tok})
        self.assertEqual(r.status_code, 200)
        self.assertEqual(PaCollectionItem.objects.get(id=g.id).data["rsvp"], "maybe")
