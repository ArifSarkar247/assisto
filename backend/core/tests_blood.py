"""blood (owner 2 Nov): Blood donor panel — separate consent, coarse-only
privacy (no exact point, phone/e-mail private by default), eligibility
interval + reminder, search by group + radius, urgent request push targeting
(compatible, eligible, nearby, opted-in, caps), responses + private threads,
My Circle by the donor's acceptance only, reports -> auto-hide -> admin,
posting ban, expiry, slip verification (photo deleted), banks honesty,
flag gating."""
import base64
import io
import os
import shutil
import tempfile
from datetime import timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import blood_panel as BP
from core.logic import blood_rules as BR
from core.models import (BloodDonor, BloodEvent, BloodRecipient, BloodReport, BloodRequest,
                         BloodThread, BloodVerification, User)

_TMP = tempfile.mkdtemp(prefix="blood-media-")
# Mirpur 10, Dhaka; ~3 km away (Agargaon); ~20 km away (Savar)
MIRPUR = (23.81, 90.37)
NEAR = (23.78, 90.38)
FAR = (23.85, 90.17)


def _jpeg_b64():
    from PIL import Image
    im = Image.new("RGB", (40, 30), (200, 40, 40))
    out = io.BytesIO()
    im.save(out, "JPEG")
    return base64.b64encode(out.getvalue()).decode()


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn, ben, data, high=False):
        self.calls.append({"user": user.id, "kind": kind, "ten": ten, "ben": ben,
                           "data": dict(data)})
        return 1

    def to(self, user, event=None):
        return [c for c in self.calls if c["user"] == user.id
                and (event is None or c["data"].get("event") == event)]


@override_settings(MEDIA_ROOT=_TMP, PUSH_SYNC=True)
class Base(TestCase):
    n = 0

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_TMP, ignore_errors=True)

    def mk(self, name, days_old=30):
        Base.n += 1
        u = User.objects.create_user(name=name, phone="0181%07d" % Base.n, password="pw-123456",
                                     email="u%d@example.com" % Base.n)
        u.date_joined = timezone.now() - timedelta(days=days_old)
        u.language = "en"
        u.save()
        return u

    def setUp(self):
        self.p1 = mock.patch.object(BP, "flag_on", lambda u: True)
        self.p1.start()
        self.spy = Spy()
        self.p2 = mock.patch.object(BP, "_send_push", self.spy)
        self.p2.start()
        self.addCleanup(self.p1.stop)
        self.addCleanup(self.p2.stop)
        self.req_user = self.mk("Rahim Uddin")

    def api(self, user):
        c = APIClient()
        c.force_authenticate(user)
        return c

    def donor(self, name, group="A+", pt=MIRPUR, last_days=None, sex="m", **kw):
        u = self.mk(name)
        d = BloodDonor.objects.create(
            user=u, enabled=True, consent_at=timezone.now(), consent_version=BR.CONSENT_VERSION,
            blood_group=group, sex=sex, district="dhaka", area_text="Mirpur",
            lat=pt[0] if pt else None, lng=pt[1] if pt else None,
            last_donation=(timezone.localdate() - timedelta(days=last_days)) if last_days else None,
            **kw)
        return u, d

    def req_body(self, **kw):
        b = {"blood_group": "A+", "units": 2, "hospital": "Dhaka Medical College Hospital",
             "area_text": "Mirpur", "district": "dhaka", "lat": MIRPUR[0], "lng": MIRPUR[1],
             "needed_by": (timezone.now() + timedelta(hours=5)).isoformat()}
        b.update(kw)
        return b

    def post_req(self, user=None, **kw):
        return self.api(user or self.req_user).post("/api/v1/blood-panel/requests",
                                                    self.req_body(**kw), format="json")


class RulesTests(TestCase):
    def test_interval_conservative_120_days_for_everyone(self):
        self.assertEqual(BR.INTERVAL_DAYS, {"m": 120, "f": 120})
        self.assertEqual(BR.interval_days(""), 120)
        d = timezone.localdate()
        self.assertEqual(BR.next_eligible(d - timedelta(days=10), "f"), d + timedelta(days=110))
        self.assertTrue(BR.is_eligible(None, "m", d))
        self.assertFalse(BR.is_eligible(d - timedelta(days=119), "m", d))
        self.assertTrue(BR.is_eligible(d - timedelta(days=120), "f", d))

    def test_groups_and_compat(self):
        self.assertEqual(BR.normalise_group(" a+ "), "A+")
        self.assertEqual(BR.normalise_group("AB negative"), "AB-")
        self.assertEqual(BR.normalise_group("C+"), "")
        g = BR.donor_groups_for("A+")
        self.assertEqual(g[0], "A+")
        self.assertIn("O-", g)
        self.assertNotIn("B+", g)

    def test_text_and_distance(self):
        self.assertTrue(BR.has_contact("call 01712345678"))
        self.assertTrue(BR.has_contact("০১৭১২-৩৪৫৬৭৮"))
        self.assertTrue(BR.has_contact("mail a@b.com"))
        self.assertFalse(BR.has_contact("Dhaka Medical, ward 5"))
        self.assertEqual(BR.shown_km(0.2), 1)
        self.assertEqual(BR.shown_km(2.1), 3)
        self.assertEqual(BR.first_name("Rahim Uddin"), "Rahim")


class ConsentTests(Base):
    def test_enable_needs_separate_consent_group_and_area(self):
        c = self.api(self.req_user)
        r = c.post("/api/v1/blood-panel/me", {"enabled": True, "blood_group": "B+",
                                           "district": "dhaka"}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "consent_required")
        self.assertFalse(BloodDonor.objects.filter(user=self.req_user, enabled=True).exists())
        r = c.post("/api/v1/blood-panel/me", {"consent": True, "enabled": True, "blood_group": "B+"},
                   format="json")
        self.assertEqual(r.json()["reason"], "area_required")
        r = c.post("/api/v1/blood-panel/me", {"consent": True, "enabled": True, "blood_group": "b+",
                                           "lat": 23.806912, "lng": 90.368712, "sex": "f",
                                           "area_text": "Mirpur 10"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        me = r.json()["me"]
        self.assertTrue(me["enabled"] and me["consented"])
        self.assertEqual(me["blood_group"], "B+")
        self.assertFalse(me["phone_public"] or me["email_public"])   # private by default
        d = BloodDonor.objects.get(user=self.req_user)
        self.assertEqual((d.lat, d.lng), (23.81, 90.37))              # ~1 km only
        self.assertEqual(d.district, "dhaka")

    def test_refuses_address_phone_future_date_outside_bd(self):
        c = self.api(self.req_user)
        for bad in ({"area_text": "House no 12, Road 5"}, {"area_text": "01712345678"},
                    {"last_donation": (timezone.localdate() + timedelta(days=2)).isoformat()},
                    {"lat": 40.7, "lng": -74.0}, {"blood_group": "Z"}):
            r = c.post("/api/v1/blood-panel/me", bad, format="json")
            self.assertEqual(r.status_code, 400, bad)
            self.assertEqual(r.json()["reason"], "invalid")

    def test_off_and_leave_never_gated(self):
        u, d = self.donor("Karim")
        with mock.patch.object(BP, "flag_on", lambda x: False):
            c = self.api(u)
            self.assertEqual(c.post("/api/v1/blood-panel/me", {"enabled": True}, format="json").status_code, 403)
            self.assertEqual(c.get("/api/v1/blood-panel/me").status_code, 200)
            r = c.post("/api/v1/blood-panel/me", {"enabled": False}, format="json")
            self.assertEqual(r.status_code, 200)
            self.assertFalse(BloodDonor.objects.get(pk=d.pk).enabled)
            self.assertEqual(c.delete("/api/v1/blood-panel/me").status_code, 200)
        self.assertFalse(BloodDonor.objects.filter(user=u).exists())

    def test_available_again_date_and_donated(self):
        u, d = self.donor("Karim", last_days=30)
        me = self.api(u).get("/api/v1/blood-panel/me").json()
        self.assertFalse(me["eligible"])
        self.assertEqual(me["next_date"], (timezone.localdate() + timedelta(days=90)).isoformat())
        u2, d2 = self.donor("Nila")
        r = self.api(u2).post("/api/v1/blood-panel/me/donated", {}, format="json")
        self.assertEqual(r.json()["me"]["last_donation"], timezone.localdate().isoformat())
        self.assertFalse(r.json()["me"]["eligible"])


class SearchTests(Base):
    def test_privacy_radius_and_order(self):
        _a, near_ok = self.donor("Akash Ahmed", "A+", NEAR)
        _b, near_late = self.donor("Bina", "A+", NEAR, last_days=20)
        _c, far = self.donor("Chayan", "A+", FAR)
        _d, pub = self.donor("Dipu", "A+", MIRPUR, phone_public=True)
        _e, off = self.donor("Ena", "A+", MIRPUR)
        off.enabled = False
        off.save()
        _f, other = self.donor("Faruk", "B+", MIRPUR)
        c = self.api(self.req_user)
        r = c.get("/api/v1/blood-panel/donors", {"group": "A+", "lat": MIRPUR[0], "lng": MIRPUR[1]})
        self.assertEqual(r.status_code, 200, r.content)
        rows = r.json()["donors"]
        ids = [x["id"] for x in rows]
        self.assertEqual(set(ids), {near_ok.id, near_late.id, pub.id})   # 5 km default
        self.assertEqual(ids[-1], near_late.id)                            # not-eligible last
        for x in rows:
            self.assertNotIn("lat", x)
            self.assertNotIn("lng", x)
            self.assertIsInstance(x["km"], int)
            self.assertNotIn(" ", x["name"])                                # first name only
        byid = {x["id"]: x for x in rows}
        self.assertIsNone(byid[near_ok.id]["phone"])
        self.assertIsNone(byid[near_ok.id]["email"])
        self.assertTrue(byid[pub.id]["phone"])
        self.assertFalse(byid[near_late.id]["eligible"])
        self.assertTrue(byid[near_late.id]["next_date"])
        r = c.get("/api/v1/blood-panel/donors", {"group": "A+", "lat": MIRPUR[0], "lng": MIRPUR[1],
                                              "radius": 25, "eligible_only": "1"})
        ids = [x["id"] for x in r.json()["donors"]]
        self.assertIn(far.id, ids)
        self.assertNotIn(near_late.id, ids)
        self.assertNotIn(other.id, ids)

    def test_needs_area_and_rate_limit(self):
        c = self.api(self.req_user)
        self.assertEqual(c.get("/api/v1/blood-panel/donors", {"group": "A+"}).json()["reason"],
                         "area_required")
        for _ in range(BR.MAX_SEARCH_DAY):
            BloodEvent.objects.create(actor=self.req_user, kind="search")
        r = c.get("/api/v1/blood-panel/donors", {"group": "A+", "district": "dhaka"})
        self.assertEqual(r.status_code, 429)


class RequestTests(Base):
    def test_validation_and_limits(self):
        for kw in ({"hospital": "DMCH call 01712345678"}, {"units": 0},
                   {"needed_by": (timezone.now() + timedelta(hours=80)).isoformat()},
                   {"note": "email me x@y.com"}, {"blood_group": "Q"}):
            r = self.post_req(**kw)
            self.assertEqual(r.status_code, 400, kw)
        r = self.post_req(lat=None, lng=None, district="")
        self.assertEqual(r.json()["reason"], "area_required")
        self.assertEqual(self.post_req().status_code, 201)
        self.assertEqual(self.post_req().status_code, 201)
        r = self.post_req()
        self.assertEqual((r.status_code, r.json()["reason"]), (429, "too_many_active"))
        BloodRequest.objects.update(state="closed")
        self.assertEqual(self.post_req().status_code, 201)     # 3rd today
        r = self.post_req()
        self.assertEqual((r.status_code, r.json()["reason"]), (429, "too_many_requests"))

    def test_push_only_compatible_eligible_nearby_optedin(self):
        a, _ = self.donor("Ahad", "A+", NEAR)
        o, _ = self.donor("Omi", "O-", MIRPUR)
        late, _ = self.donor("Late", "A+", MIRPUR, last_days=40)
        far, _ = self.donor("Far", "A+", FAR)
        b, _ = self.donor("Bee", "B+", MIRPUR)
        paused, dp = self.donor("Paused", "A+", MIRPUR)
        dp.available = False
        dp.save()
        dist_only, _ = self.donor("Dist", "A+", None)     # district-only donor: fuzz
        r = self.post_req()
        self.assertEqual(r.status_code, 201, r.content)
        rid = r.json()["request"]["id"]
        pushed = {c["user"] for c in self.spy.calls if c["data"].get("event") == "request"}
        self.assertEqual(pushed, {a.id, o.id, dist_only.id})
        self.assertNotIn(self.req_user.id, pushed)
        call = self.spy.to(a, "request")[0]
        self.assertEqual(call["data"]["request_id"], rid)
        self.assertNotIn("0181", call["ben"])          # no phone in the push
        req = BloodRequest.objects.get(pk=rid)
        self.assertEqual(req.pushed, 3)
        # one push per request per donor (fan-out is idempotent)
        BP.fan_out(rid)
        self.assertEqual(len(self.spy.to(a, "request")), 1)

    def test_daily_push_cap_per_donor(self):
        a, _ = self.donor("Ahad", "A+", NEAR)
        for i in range(BR.MAX_PUSH_PER_DONOR_DAY + 1):
            u = self.mk("Req%d" % i)
            self.assertEqual(self.post_req(user=u).status_code, 201)
        self.assertEqual(len(self.spy.to(a, "request")), BR.MAX_PUSH_PER_DONOR_DAY)
        self.assertEqual(BloodRecipient.objects.filter(user=a).count(), BR.MAX_PUSH_PER_DONOR_DAY + 1)

    def test_respond_thread_and_responders_without_phone(self):
        a, d = self.donor("Ahad Khan", "A+", NEAR)
        rid = self.post_req().json()["request"]["id"]
        r = self.api(a).post("/api/v1/blood-panel/requests/%d/respond" % rid, {"answer": "can"},
                             format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["request"]["my_response"], "can")
        self.assertTrue(self.spy.to(self.req_user, "responder"))
        det = self.api(self.req_user).get("/api/v1/blood-panel/requests/%d" % rid).json()
        self.assertEqual(det["role"], "requester")
        resp = det["responders"][0]
        self.assertEqual(resp["name"], "Ahad")
        self.assertIsNone(resp["phone"])
        self.assertTrue(resp["thread_id"])
        th = BloodThread.objects.get(pk=resp["thread_id"])
        self.assertEqual((th.donor_id, th.seeker_id), (a.id, self.req_user.id))
        # donated -> the clock restarts
        self.api(a).post("/api/v1/blood-panel/requests/%d/respond" % rid, {"answer": "donated"},
                         format="json")
        d.refresh_from_db()
        self.assertEqual(d.last_donation, timezone.localdate())

    def test_respond_refuses_ineligible_incompatible_nondonor(self):
        late, _ = self.donor("Late", "A+", MIRPUR, last_days=10)
        b, _ = self.donor("Bee", "B+", MIRPUR)
        nobody = self.mk("Nobody")
        rid = self.post_req().json()["request"]["id"]
        url = "/api/v1/blood-panel/requests/%d/respond" % rid
        self.assertEqual(self.api(late).post(url, {"answer": "can"}, format="json").json()["reason"],
                         "not_eligible")
        self.assertEqual(self.api(b).post(url, {"answer": "can"}, format="json").json()["reason"],
                         "incompatible")
        self.assertEqual(self.api(nobody).post(url, {"answer": "can"}, format="json").status_code, 403)
        self.assertEqual(self.api(self.req_user).post(url, {"answer": "can"}, format="json").status_code, 403)

    def test_found_tells_responders_and_only_requester_may_end(self):
        a, _ = self.donor("Ahad", "A+", NEAR)
        rid = self.post_req().json()["request"]["id"]
        self.api(a).post("/api/v1/blood-panel/requests/%d/respond" % rid, {"answer": "can"}, format="json")
        self.assertEqual(self.api(a).post("/api/v1/blood-panel/requests/%d/found" % rid).status_code, 403)
        r = self.api(self.req_user).post("/api/v1/blood-panel/requests/%d/found" % rid)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.json()["request"]["state"], "fulfilled")
        self.assertEqual(r.json()["site"], "https://lifeassisto.com")
        self.assertTrue(self.spy.to(a, "ended"))
        self.assertEqual(self.api(self.req_user).post("/api/v1/blood-panel/requests/%d/close" % rid).status_code, 400)

    def test_near_list_for_donor(self):
        a, _ = self.donor("Ahad", "O-", FAR)
        rid = self.post_req(radius_km=25).json()["request"]["id"]
        near = self.api(a).get("/api/v1/blood-panel/requests").json()["near"]
        self.assertEqual([x["id"] for x in near], [rid])
        self.assertTrue(near[0]["compatible"])
        self.assertIsInstance(near[0]["km"], int)

    def test_expiry_and_eligibility_reminder_once(self):
        rid = self.post_req().json()["request"]["id"]
        BloodRequest.objects.filter(pk=rid).update(expires_at=timezone.now() - timedelta(minutes=1))
        u, d = self.donor("Rem", last_days=121)
        self.assertEqual(BP.sweep(), 1)
        self.assertEqual(BloodRequest.objects.get(pk=rid).state, "expired")
        self.assertEqual(len(self.spy.to(u, "eligible")), 1)
        self.assertEqual(self.spy.to(u, "eligible")[0]["kind"], "reminder")
        BP.sweep()
        self.assertEqual(len(self.spy.to(u, "eligible")), 1)


class ReportTests(Base):
    def test_three_independent_reports_hide_then_admin(self):
        rid = self.post_req().json()["request"]["id"]
        url = "/api/v1/blood-panel/requests/%d/report" % rid
        young = self.mk("Young", days_old=0)
        self.api(young).post(url, {"reason": "fake"}, format="json")
        self.assertEqual(self.api(self.req_user).post(url, {"reason": "fake"}, format="json").status_code, 403)
        reps = [self.mk("R%d" % i) for i in range(3)]
        self.api(reps[0]).post(url, {"reason": "fake"}, format="json")
        self.assertEqual(self.api(reps[0]).post(url, {"reason": "fake"}, format="json").status_code, 409)
        self.api(reps[1]).post(url, {"reason": "selling"}, format="json")
        self.assertEqual(BloodRequest.objects.get(pk=rid).state, "active")
        r = self.api(reps[2]).post(url, {"reason": "spam"}, format="json")
        self.assertTrue(r.json()["hidden"])
        self.assertEqual(BloodRequest.objects.get(pk=rid).state, "hidden")
        self.assertFalse(BloodReport.objects.get(reporter=young).counted)
        self.assertEqual(self.api(reps[0]).get("/api/v1/blood-panel/requests/%d" % rid).status_code, 404)
        self.assertEqual(self.api(self.req_user).get("/api/v1/blood-panel/requests/%d" % rid).status_code, 200)
        req = BloodRequest.objects.get(pk=rid)
        owner = self.mk("Owner")
        self.assertIsNone(BP.admin_action(req, "remove_ban", owner))
        self.assertEqual(req.state, "removed")
        r = self.post_req()
        self.assertEqual((r.status_code, r.json()["reason"]), (403, "banned"))


class ThreadTests(Base):
    def test_message_block_and_circle_by_donor_choice(self):
        a, d = self.donor("Ahad Khan", "A+", NEAR)
        c = self.api(self.req_user)
        r = c.post("/api/v1/blood-panel/donors/%d/message" % d.id, {"text": "Can you help tomorrow?"},
                   format="json")
        self.assertEqual(r.status_code, 201, r.content)
        tid = r.json()["thread"]["id"]
        self.assertIsNone(r.json()["thread"]["phone"])
        self.assertTrue(self.spy.to(a, "message"))
        msgs = self.api(a).get("/api/v1/blood-panel/threads/%d" % tid).json()["messages"]
        self.assertEqual(msgs[0]["text"], "Can you help tomorrow?")
        self.assertFalse(msgs[0]["mine"])
        stranger = self.mk("Stranger")
        self.assertEqual(self.api(stranger).get("/api/v1/blood-panel/threads/%d" % tid).status_code, 404)
        # My Circle: only the seeker asks, only the donor decides
        url = "/api/v1/blood-panel/threads/%d/circle" % tid
        self.assertEqual(self.api(a).post(url, {"action": "ask"}, format="json").status_code, 403)
        self.assertEqual(c.post(url, {"action": "ask"}, format="json").status_code, 200)
        self.assertTrue(self.spy.to(a, "circle_ask"))
        self.assertEqual(c.post(url, {"action": "accept"}, format="json").status_code, 403)
        r = self.api(a).post(url, {"action": "accept"}, format="json")
        self.assertEqual(r.json()["circle_to_user_id"], self.req_user.id)
        # block stops messages both ways
        self.api(a).post("/api/v1/blood-panel/threads/%d/block" % tid, {"on": True}, format="json")
        r = c.post("/api/v1/blood-panel/threads/%d" % tid, {"text": "hello?"}, format="json")
        self.assertEqual(r.json()["reason"], "blocked")

    def test_public_phone_shown_to_seeker_only_when_donor_chose(self):
        a, d = self.donor("Ahad", "A+", NEAR, phone_public=True)
        r = self.api(self.req_user).post("/api/v1/blood-panel/donors/%d/message" % d.id, {"text": "hi there"},
                                         format="json")
        self.assertEqual(r.json()["thread"]["phone"], a.phone)


class VerifyAndBanksTests(Base):
    def test_slip_reviewed_then_photo_deleted(self):
        a, d = self.donor("Ahad", "A+", NEAR)
        c = self.api(a)
        self.assertEqual(c.post("/api/v1/blood-panel/me/verify", {"photo_b64": "!!"}, format="json").status_code, 400)
        r = c.post("/api/v1/blood-panel/me/verify", {"photo_b64": _jpeg_b64()}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        v = BloodVerification.objects.get(user=a)
        path = v.photo.path
        self.assertTrue(os.path.exists(path))
        self.assertEqual(c.post("/api/v1/blood-panel/me/verify", {"photo_b64": _jpeg_b64()}, format="json").status_code, 409)
        self.assertIsNone(BP.review_slip(v, True, self.mk("Owner")))
        self.assertFalse(os.path.exists(path))
        v.refresh_from_db()
        self.assertEqual((v.state, v.photo.name), ("approved", ""))
        me = c.get("/api/v1/blood-panel/me").json()
        self.assertTrue(me["verified"])
        rows = self.api(self.req_user).get("/api/v1/blood-panel/donors",
                                           {"group": "A+", "district": "dhaka"}).json()["donors"]
        self.assertTrue(rows[0]["verified"])

    def test_banks_honest_empty(self):
        r = self.api(self.req_user).get("/api/v1/blood-panel/banks").json()
        self.assertEqual(r["banks"], [])
        self.assertTrue(r["source_pending"])
        self.assertIsNone(r["source"])


class FlagTests(Base):
    def test_flag_off_gates_panel(self):
        _a, d = self.donor("Ahad", "A+", NEAR)
        with mock.patch.object(BP, "flag_on", lambda u: False):
            c = self.api(self.req_user)
            self.assertEqual(c.get("/api/v1/blood-panel/donors", {"district": "dhaka"}).status_code, 403)
            self.assertEqual(self.post_req().status_code, 403)
            self.assertEqual(c.get("/api/v1/blood-panel/requests").json()["enabled"], False)
            self.assertEqual(c.get("/api/v1/blood-panel/banks").status_code, 403)
            self.assertFalse(c.get("/api/v1/blood-panel/config").json()["enabled"])
