"""missing (owner 2 Nov): Missing person alert — gates (adult GD, child
guardian / co-signer), push targeting (opt-in, coarse areas, app-open point,
one push per alert per user, daily cap), photo deletion on every end (signed
link 404), expiry + renewal, I-am-safe privacy + cooling period, reports ->
auto-hide -> Owner Admin, private tips, posting limits, flag gating."""
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

from core import missing_alert as MS
from core.logic import missing_rules as MR
from core.models import (CircleMember, FamilyMember, MissingAlert, MissingEvent,
                         MissingRecipient, MissingReport, MissingTipThread,
                         NearbyAlertPref, NotifEvent, User)

_TMP = tempfile.mkdtemp(prefix="missing-media-")


def _jpeg_b64():
    from PIL import Image
    im = Image.new("RGB", (40, 30), (200, 120, 40))
    out = io.BytesIO()
    im.save(out, "JPEG")
    return base64.b64encode(out.getvalue()).decode()


def _flag_on(user):
    return True


class Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, tbn, ten, bbn, ben, data, high=False):
        self.calls.append({"user": user.id, "tbn": tbn, "ten": ten, "bbn": bbn,
                           "ben": ben, "data": dict(data)})
        return 1

    def to(self, user, event=None):
        return [c for c in self.calls if c["user"] == user.id
                and (event is None or c["data"].get("event") == event)]


def link(a, b, rel_ab, rel_ba):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, relation=rel_ab, state="accepted")
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, relation=rel_ba, state="accepted")


@override_settings(MEDIA_ROOT=_TMP, PUSH_SYNC=True)
class Base(TestCase):
    n = 0

    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_TMP, ignore_errors=True)

    def mk(self, name, days_old=30):
        Base.n += 1
        u = User.objects.create_user(name=name, phone="0171%07d" % Base.n, password="pw-123456")
        u.date_joined = timezone.now() - timedelta(days=days_old)
        u.language = "en"
        u.save()
        return u

    def setUp(self):
        self.p1 = mock.patch.object(MS, "flag_on", _flag_on)
        self.p1.start()
        self.spy = Spy()
        self.p2 = mock.patch.object(MS, "_send_push", self.spy)
        self.p2.start()
        self.addCleanup(self.p1.stop)
        self.addCleanup(self.p2.stop)
        self.mum = self.mk("Mum")
        self.dad = self.mk("Dad")
        link(self.mum, self.dad, "husband", "wife")

    def api(self, user):
        c = APIClient()
        c.force_authenticate(user)
        return c

    def optin(self, user, district="dhaka", lat=None, lng=None, open_pt=None, open_age_h=1):
        p = NearbyAlertPref.objects.create(user=user, enabled=True, district=district,
                                           home_lat=lat, home_lng=lng)
        if open_pt:
            p.use_open_location = True
            p.open_lat, p.open_lng = open_pt
            p.open_at = timezone.now() - timedelta(hours=open_age_h)
            p.save()
        return p

    def body(self, **kw):
        b = {"name": "Rafi", "age": 9, "relation": "son", "area_text": "Mirpur 10 bus stand",
             "district": "dhaka", "lat": 23.8069, "lng": 90.3687, "radius_km": 10,
             "description": "Blue school shirt, about 4 feet",
             "last_seen_at": (timezone.now() - timedelta(hours=2)).isoformat(),
             "confirm_is_family": True, "confirm_no_address": True, "confirm_false_post": True}
        b.update(kw)
        return b

    def adult(self, **kw):
        b = self.body(name="Karim", age=34, relation="brother", gd_number="GD No. 512/2026",
                      gd_thana="Mirpur Model", gd_date=timezone.localdate().isoformat())
        b.update(kw)
        return b


class RulesTests(TestCase):
    def test_gd_number_formats(self):
        self.assertEqual(MR.clean_gd_number("জিডি নং ১২৩/২০২৬"), "123/2026")
        self.assertEqual(MR.clean_gd_number("GD No. 512 / 2026"), "512/2026")
        self.assertEqual(MR.clean_gd_number("1450"), "1450")
        for bad in ("", "abc", "0", "12345678", "12/ab", "call 01711000000"):
            self.assertIsNone(MR.clean_gd_number(bad), bad)

    def test_gd_date_window(self):
        today = timezone.localdate()
        _, bad = MR.gd_problems("12", "Mirpur", (today + timedelta(days=1)).isoformat(), today)
        self.assertIn("gd_date", bad)
        _, bad = MR.gd_problems("12", "Mirpur", (today - timedelta(days=61)).isoformat(), today)
        self.assertIn("gd_date", bad)
        ok, bad = MR.gd_problems("12", "Mirpur", today.isoformat(), today)
        self.assertEqual(bad, [])
        self.assertEqual(ok["gd_number"], "12")

    def test_child_and_coarse(self):
        self.assertTrue(MR.is_child(17))
        self.assertFalse(MR.is_child(18))
        self.assertEqual(MR.coarse(23.80691234), 23.81)
        self.assertEqual(len(MR.DISTRICTS), 64)
        self.assertEqual(len({d[0] for d in MR.DISTRICTS}), 64)

    def test_nearby_math(self):
        a = MR.area_of(23.81, 90.37, "dhaka")
        self.assertTrue(MR.is_nearby(a, 10, (23.85, 90.40, 0)))      # ~5 km
        self.assertFalse(MR.is_nearby(a, 5, (24.75, 90.42, 0)))      # Mymensingh
        self.assertTrue(MR.is_nearby(MR.area_of(None, None, "dhaka"), 5,
                                     MR.area_of(None, None, "gazipur")))   # district fuzz

    def test_address_and_phone_refused(self):
        self.assertTrue(MR.looks_like_address("House 12, Mirpur"))
        self.assertTrue(MR.looks_like_address("বাসা নং ৫"))
        self.assertFalse(MR.looks_like_address("Mirpur 10 bus stand"))
        self.assertTrue(MR.has_phone("call 01711-000000"))
        self.assertFalse(MR.has_phone("4 feet tall, age 9"))


class GateTests(Base):
    def test_adult_needs_gd_and_never_claims_verified(self):
        c = self.api(self.mum)
        r = c.post("/api/v1/missing-alerts", self.adult(gd_number=""), format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.json()["reason"], "gd_required")
        r = c.post("/api/v1/missing-alerts", self.adult(gd_number="hello"), format="json")
        self.assertEqual(r.json()["reason"], "gd_required")
        self.assertIn("gd_number", r.json()["fields"])
        self.assertTrue(MissingEvent.objects.filter(kind="refused").exists())
        r = c.post("/api/v1/missing-alerts", self.adult(), format="json")
        self.assertEqual(r.status_code, 201, r.content)
        a = r.json()["alert"]
        self.assertEqual(a["state"], "active")
        self.assertEqual(a["basis"], "gd")
        self.assertEqual(a["gd"]["number"], "512/2026")
        self.assertIs(a["gd"]["verified"], False)

    def test_child_mutual_parent_link_is_verified(self):
        kid = self.mk("Rafi")
        link(self.mum, kid, "child", "mother")
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.body(subject_user_id=kid.id), format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["alert"]["basis"], "circle_mutual")
        self.assertEqual(r.json()["alert"]["state"], "active")

    def test_one_sided_parent_claim_is_not_enough(self):
        kid = self.mk("Rafi")
        link(self.mum, kid, "child", "sibling")   # the child did not confirm a parent
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.body(subject_user_id=kid.id), format="json")
        self.assertEqual(r.json()["alert"]["state"], "pending")

    def test_child_without_account_needs_cosigner_then_activates(self):
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.body(cosigner_id=self.dad.id), format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.json()["needs"], "cosign")
        aid = r.json()["alert"]["id"]
        self.assertTrue(self.spy.to(self.dad, "cosign"))
        stranger = self.mk("Stranger")
        self.assertEqual(self.api(stranger).post("/api/v1/missing-alerts/%d/cosign" % aid,
                                                 {"confirm": True}, format="json").status_code, 404)
        r = self.api(self.dad).post("/api/v1/missing-alerts/%d/cosign" % aid,
                                    {"confirm": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        a = MissingAlert.objects.get(pk=aid)
        self.assertEqual((a.state, a.basis, a.cosigner_id), ("active", "cosigned", self.dad.id))

    def test_pending_child_alert_activates_with_gd(self):
        r = self.api(self.mum).post("/api/v1/missing-alerts", self.body(), format="json")
        aid = r.json()["alert"]["id"]
        self.assertEqual(r.json()["alert"]["state"], "pending")
        r = self.api(self.mum).post("/api/v1/missing-alerts/%d/gd" % aid,
                                    {"gd_number": "77", "gd_thana": "Mirpur",
                                     "gd_date": timezone.localdate().isoformat()}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(MissingAlert.objects.get(pk=aid).state, "active")

    def test_cosigner_must_be_close_family(self):
        friend = self.mk("Friend")
        link(self.mum, friend, "friend", "friend")
        g = MS.guardian_check(self.mum, None, None, cosigner=friend)
        self.assertFalse(g["ok"])
        self.assertTrue(MS.guardian_check(self.mum, None, None, cosigner=self.dad)["ok"])

    def test_not_family_refused(self):
        other = self.mk("Other")
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.adult(subject_user_id=other.id), format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "not_family")

    def test_home_address_and_phone_refused(self):
        c = self.api(self.mum)
        r = c.post("/api/v1/missing-alerts", self.body(area_text="House 12, Road 3, Mirpur"),
                   format="json")
        self.assertIn("address", r.json()["fields"])
        r = c.post("/api/v1/missing-alerts", self.body(description="call 01711000000"),
                   format="json")
        self.assertIn("phone", r.json()["fields"])
        r = c.post("/api/v1/missing-alerts", self.body(confirm_no_address=False), format="json")
        self.assertIn("confirm_no_address", r.json()["fields"])

    def test_posting_limits(self):
        c = self.api(self.mum)
        self.assertEqual(c.post("/api/v1/missing-alerts", self.adult(), format="json").status_code, 201)
        self.assertEqual(c.post("/api/v1/missing-alerts", self.adult(name="Selim"),
                                format="json").status_code, 201)
        r = c.post("/api/v1/missing-alerts", self.adult(name="Third"), format="json")
        self.assertEqual(r.status_code, 429)
        self.assertEqual(r.json()["reason"], "too_many_active")

    def test_duplicate_active_refused(self):
        c = self.api(self.mum)
        c.post("/api/v1/missing-alerts", self.adult(), format="json")
        MissingAlert.objects.update(state="pending")   # still live
        r = c.post("/api/v1/missing-alerts", self.adult(), format="json")
        self.assertEqual(r.json()["reason"], "already_active")

    def test_flag_off(self):
        with mock.patch.object(MS, "flag_on", lambda u: False):
            r = self.api(self.mum).post("/api/v1/missing-alerts", self.adult(), format="json")
            self.assertEqual(r.status_code, 403)
            # turning nearby alerts OFF is never gated
            r = self.api(self.mum).post("/api/v1/missing-alerts/nearby", {"enabled": False},
                                        format="json")
            self.assertEqual(r.status_code, 200)

    def test_photo_exif_stripped_and_resized(self):
        from PIL import Image
        im = Image.new("RGB", (3000, 2000), (10, 10, 10))
        exif = Image.Exif()
        exif[0x010F] = "SecretCam"   # camera make (any metadata must go)
        out = io.BytesIO()
        im.save(out, "JPEG", exif=exif)
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.adult(photo_b64=base64.b64encode(out.getvalue()).decode()),
                                    format="json")
        self.assertEqual(r.status_code, 201, r.content)
        a = MissingAlert.objects.get()
        saved = Image.open(a.photo.path)
        self.assertLessEqual(max(saved.size), MR.PHOTO_MAX_SIDE)
        self.assertEqual(len(saved.getexif()), 0)


class TargetingTests(Base):
    def test_only_opted_in_nearby_get_one_push(self):
        near = self.mk("Near")
        self.optin(near, "dhaka", 23.83, 90.37)
        far = self.mk("Far")
        self.optin(far, "rangpur", 25.74, 89.28)
        silent = self.mk("NotOptedIn")
        visitor = self.mk("Visitor")       # home far, opened the app near 1 h ago
        self.optin(visitor, "sylhet", 24.89, 91.87, open_pt=(23.81, 90.36))
        stale = self.mk("Stale")            # app-open point 13 h old
        self.optin(stale, "sylhet", 24.89, 91.87, open_pt=(23.81, 90.36), open_age_h=13)
        district_only = self.mk("DistrictOnly")
        self.optin(district_only, "dhaka")
        r = self.api(self.mum).post("/api/v1/missing-alerts", self.adult(), format="json")
        aid = r.json()["alert"]["id"]
        for u in (near, visitor, district_only):
            self.assertEqual(len(self.spy.to(u, "new")), 1, u.name)
        for u in (far, silent, stale, self.mum):
            self.assertEqual(self.spy.to(u, "new"), [], u.name)
        self.assertEqual(len(self.spy.to(self.dad, "new_family")), 1)   # close family
        # recipients' push carries no name / photo / poster
        c = self.spy.to(near, "new")[0]
        self.assertNotIn("Karim", c["ben"] + c["ten"])
        self.assertNotIn("Mum", c["ben"])
        self.assertEqual(MissingRecipient.objects.filter(alert_id=aid).count(), 4)
        # idempotent: one push per alert per user
        MS.fan_out(aid)
        self.assertEqual(len(self.spy.to(near, "new")), 1)
        # the recipient sees it in the list, without the poster's identity
        lst = self.api(near).get("/api/v1/missing-alerts").json()
        self.assertEqual([x["id"] for x in lst["near"]], [aid])
        blob = str(lst)
        self.assertNotIn(self.mum.phone, blob)
        self.assertNotIn("Mum", blob)
        self.assertNotIn("'lat'", blob)
        # someone who is not a recipient cannot open it
        self.assertEqual(self.api(silent).get("/api/v1/missing-alerts/%d" % aid).status_code, 404)

    def test_daily_push_cap_then_listed_only(self):
        near = self.mk("Near")
        self.optin(near, "dhaka", 23.83, 90.37)
        posters = [self.mk("P%d" % i) for i in range(MR.MAX_PUSH_PER_USER_DAY + 1)]
        for p in posters:
            MS.create(p, self.adult())
        self.assertEqual(len(self.spy.to(near, "new")), MR.MAX_PUSH_PER_USER_DAY)
        self.assertEqual(MissingRecipient.objects.filter(user=near).count(),
                         MR.MAX_PUSH_PER_USER_DAY + 1)
        self.assertEqual(MissingRecipient.objects.filter(user=near, pushed_at__isnull=True).count(), 1)

    def test_subject_is_told_and_not_counted_as_nearby(self):
        bro = self.mk("Karim")
        link(self.mum, bro, "brother", "sister")
        self.optin(bro, "dhaka", 23.81, 90.37)
        MS.create(self.mum, self.adult(subject_user_id=bro.id))
        self.assertEqual(len(self.spy.to(bro, "about_you")), 1)
        self.assertEqual(self.spy.to(bro, "new"), [])


class EndTests(Base):
    def _alert(self, **kw):
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.adult(photo_b64=_jpeg_b64(), **kw), format="json")
        self.assertEqual(r.status_code, 201, r.content)
        return MissingAlert.objects.get(pk=r.json()["alert"]["id"])

    def test_found_deletes_photo_and_pushes_same_recipients(self):
        near = self.mk("Near")
        self.optin(near, "dhaka", 23.83, 90.37)
        late = self.mk("Late")
        a = self._alert()
        path, url = a.photo.path, a.photo.url
        self.assertTrue(os.path.exists(path))
        self.assertEqual(APIClient().get(url).status_code, 200)
        self.optin(late, "dhaka", 23.83, 90.37)   # opted in after: no "found" push
        r = self.api(self.mum).post("/api/v1/missing-alerts/%d/found" % a.id,
                                    {"share_ok": True}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["alert"]["state"], "found")
        self.assertIsNone(r.json()["alert"]["photo_url"])
        self.assertFalse(os.path.exists(path))
        self.assertEqual(APIClient().get(url).status_code, 404)   # signed link dead
        ended = self.spy.to(near, "ended")
        self.assertEqual(len(ended), 1)
        self.assertNotIn("Karim", ended[0]["ben"] + ended[0]["ten"])
        self.assertEqual(self.spy.to(late), [])
        a.refresh_from_db()
        self.assertTrue(a.share_agreed)
        self.assertTrue(MissingEvent.objects.filter(alert=a, kind="photo_deleted").exists())
        # the recipient still sees "found", without photo or description
        d = self.api(near).get("/api/v1/missing-alerts/%d" % a.id).json()["alert"]
        self.assertEqual((d["state"], d["photo_url"], d["description"]), ("found", None, ""))

    def test_expiry_deletes_photo(self):
        a = self._alert()
        path = a.photo.path
        MS.sweep(at=timezone.now() + timedelta(days=MR.EXPIRY_DAYS, minutes=1))
        a.refresh_from_db()
        self.assertEqual(a.state, "expired")
        self.assertFalse(a.photo)
        self.assertFalse(os.path.exists(path))

    def test_purge_job_runs_the_sweep(self):
        from django.core.management import call_command
        a = self._alert()
        MissingAlert.objects.filter(pk=a.id).update(expires_at=timezone.now() - timedelta(minutes=1))
        call_command("purge_deletions", stdout=io.StringIO())
        a.refresh_from_db()
        self.assertEqual(a.state, "expired")

    def test_renew_window_and_adult_gd_reconfirm(self):
        a = self._alert()
        c = self.api(self.mum)
        r = c.post("/api/v1/missing-alerts/%d/renew" % a.id, {}, format="json")
        self.assertEqual(r.json()["reason"], "too_early")
        MissingAlert.objects.filter(pk=a.id).update(expires_at=timezone.now() + timedelta(hours=10))
        r = c.post("/api/v1/missing-alerts/%d/renew" % a.id, {"gd_still_open": True,
                                                              "gd_number": "999"}, format="json")
        self.assertEqual(r.json()["reason"], "gd_reconfirm")
        r = c.post("/api/v1/missing-alerts/%d/renew" % a.id, {"gd_still_open": True,
                                                              "gd_number": "512/2026"}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        a.refresh_from_db()
        self.assertEqual(a.renewals, 1)
        self.assertGreater(a.expires_at, timezone.now() + timedelta(days=7))

    def test_close_by_family_deletes_photo(self):
        a = self._alert()
        path = a.photo.path
        self.api(self.mum).post("/api/v1/missing-alerts/%d/close" % a.id, {}, format="json")
        self.assertFalse(os.path.exists(path))
        self.assertEqual(MissingAlert.objects.get(pk=a.id).state, "closed")


class SafeTests(Base):
    def setUp(self):
        super().setUp()
        self.bro = self.mk("Karim")
        link(self.mum, self.bro, "brother", "sister")

    def test_adult_i_am_safe_closes_without_location(self):
        a, _ = MS.create(self.mum, self.adult(subject_user_id=self.bro.id))
        about = self.api(self.bro).get("/api/v1/missing-alerts").json()["about_me"]
        self.assertEqual([x["id"] for x in about], [a.id])
        r = self.api(self.bro).post("/api/v1/missing-alerts/%d/safe" % a.id,
                                    {"lat": 23.7, "lng": 90.4}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        a.refresh_from_db()
        self.assertEqual(a.state, "safe")
        fam = self.api(self.mum).get("/api/v1/missing-alerts/%d" % a.id).json()["alert"]
        self.assertTrue(fam["safe_said"])
        self.assertEqual(fam["state"], "safe")
        blob = str(fam)
        self.assertNotIn("23.7", blob)
        self.assertNotIn("90.4,", blob)
        told = self.spy.to(self.mum, "said_safe")
        self.assertEqual(len(told), 1)
        self.assertNotIn("23.7", told[0]["ben"])
        # the family cannot reopen with the SAME GD during the cooling period
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.adult(subject_user_id=self.bro.id), format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["reason"], "cooling")
        r = self.api(self.mum).post("/api/v1/missing-alerts",
                                    self.adult(subject_user_id=self.bro.id, gd_number="601/2026"),
                                    format="json")
        self.assertEqual(r.status_code, 201, r.content)

    def test_safe_works_with_flag_off_and_only_for_subject(self):
        a, _ = MS.create(self.mum, self.adult(subject_user_id=self.bro.id))
        self.assertEqual(self.api(self.mum).post("/api/v1/missing-alerts/%d/safe" % a.id,
                                                 {}, format="json").status_code, 403)
        with mock.patch.object(MS, "flag_on", lambda u: False):
            r = self.api(self.bro).post("/api/v1/missing-alerts/%d/safe" % a.id, {}, format="json")
        self.assertEqual(r.status_code, 200)

    def test_child_saying_safe_tells_family_but_keeps_alert(self):
        kid = self.mk("Rafi")
        link(self.mum, kid, "child", "mother")
        a, _ = MS.create(self.mum, self.body(subject_user_id=kid.id))
        self.api(kid).post("/api/v1/missing-alerts/%d/safe" % a.id, {}, format="json")
        a.refresh_from_db()
        self.assertEqual(a.state, "active")
        self.assertIsNotNone(a.safe_said_at)
        self.assertEqual(len(self.spy.to(self.mum, "said_safe")), 1)


class ReportTipTests(Base):
    def setUp(self):
        super().setUp()
        self.rs = []
        for i in range(4):
            u = self.mk("R%d" % i)
            self.optin(u, "dhaka", 23.82, 90.37)
            self.rs.append(u)
        self.young = self.mk("Young", days_old=0)
        self.optin(self.young, "dhaka", 23.82, 90.37)
        self.a, _ = MS.create(self.mum, self.adult())

    def rep(self, u, reason="fake"):
        return self.api(u).post("/api/v1/missing-alerts/%d/report" % self.a.id,
                                {"reason": reason, "note": "not real"}, format="json")

    def test_three_independent_reports_hide_then_admin_restores(self):
        self.assertEqual(self.rep(self.young).json()["status"], "ok")
        self.assertFalse(MissingReport.objects.get(reporter=self.young).counted)
        self.rep(self.rs[0])
        self.assertEqual(self.rep(self.rs[0]).json()["status"], "already")
        self.rep(self.rs[1])
        self.assertEqual(MissingAlert.objects.get(pk=self.a.id).state, "active")
        r = self.rep(self.rs[2])
        self.assertTrue(r.json()["hidden"])
        self.assertEqual(MissingAlert.objects.get(pk=self.a.id).state, "hidden")
        self.assertEqual(self.api(self.rs[3]).get("/api/v1/missing-alerts/%d" % self.a.id).status_code, 404)
        self.assertEqual(self.spy.to(self.mum, "hidden")[0]["data"]["alert_id"], self.a.id)
        a = MissingAlert.objects.get(pk=self.a.id)
        self.assertIsNone(MS.admin_action(a, "restore", None))
        self.assertEqual(MissingAlert.objects.get(pk=self.a.id).state, "active")
        self.assertEqual(MissingReport.objects.filter(status="dismissed").count(), 4)

    def test_remove_with_ban_blocks_posting(self):
        a = MissingAlert.objects.get(pk=self.a.id)
        MS.admin_action(a, "remove_ban", None)
        a.refresh_from_db()
        self.assertEqual(a.state, "removed")
        r = self.api(self.mum).post("/api/v1/missing-alerts", self.adult(name="Other"), format="json")
        self.assertEqual(r.json()["reason"], "banned")

    def test_private_tips(self):
        t1, t2 = self.rs[0], self.rs[1]
        r = self.api(t1).post("/api/v1/missing-alerts/%d/tips" % self.a.id,
                              {"text": "Saw him near the station", "lat": 23.812345,
                               "lng": 90.371234}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        self.api(t2).post("/api/v1/missing-alerts/%d/tips" % self.a.id,
                          {"text": "Bus 7", "share_identity": True}, format="json")
        self.assertEqual(len(self.spy.to(self.mum, "tip")), 2)
        fam = self.api(self.mum).get("/api/v1/missing-alerts/%d/tips" % self.a.id).json()
        labels = {t["tipster"] for t in fam["threads"]}
        self.assertIn("R1", labels)                      # agreed to share
        self.assertNotIn("R0", labels)                   # anonymous
        anon = [t for t in fam["threads"] if t["tipster"] != "R1"][0]
        self.assertIsNone(anon["tipster_phone"])
        self.assertEqual(anon["messages"][0]["point"], {"lat": 23.81, "lng": 90.37})   # coarse
        # tipster sees only their own thread
        mine = self.api(t2).get("/api/v1/missing-alerts/%d/tips" % self.a.id).json()
        self.assertEqual(len(mine["threads"]), 1)
        self.assertNotIn("Saw him", str(mine))
        # family replies; another user cannot read the thread
        tid = anon["id"]
        self.assertEqual(self.api(self.mum).post("/api/v1/missing-alerts/tips/%d" % tid,
                                                 {"text": "Thank you, which station?"},
                                                 format="json").status_code, 200)
        self.assertEqual(len(self.spy.to(t1, "tip_reply")), 1)
        self.assertEqual(self.api(t2).get("/api/v1/missing-alerts/tips/%d" % tid).status_code, 404)
        th = self.api(t1).get("/api/v1/missing-alerts/tips/%d" % tid).json()["thread"]
        self.assertEqual([m["by_family"] for m in th["messages"]], [False, True])
        # no public comments: a non-recipient cannot tip
        out = self.mk("Outsider")
        self.assertEqual(self.api(out).post("/api/v1/missing-alerts/%d/tips" % self.a.id,
                                            {"text": "x x"}, format="json").status_code, 404)

    def test_tip_thread_rate_limit(self):
        with mock.patch.object(MR, "MAX_TIP_MSGS_DAY", 2):
            c = self.api(self.rs[0])
            url = "/api/v1/missing-alerts/%d/tips" % self.a.id
            self.assertEqual(c.post(url, {"text": "one"}, format="json").status_code, 201)
            self.assertEqual(c.post(url, {"text": "two"}, format="json").status_code, 201)
            self.assertEqual(c.post(url, {"text": "three"}, format="json").status_code, 429)


class PrefTests(Base):
    def test_optin_coarse_and_off_clears(self):
        u = self.mk("U")
        c = self.api(u)
        r = c.post("/api/v1/missing-alerts/nearby", {"enabled": True}, format="json")
        self.assertEqual(r.json()["reason"], "area_required")
        r = c.post("/api/v1/missing-alerts/nearby", {"enabled": True, "lat": 23.812345,
                                                     "lng": 90.36789, "use_open_location": True},
                   format="json")
        self.assertEqual(r.status_code, 200, r.content)
        p = NearbyAlertPref.objects.get(user=u)
        self.assertEqual((p.home_lat, p.home_lng, p.district), (23.81, 90.37, "dhaka"))
        self.assertEqual(c.post("/api/v1/missing-alerts/where-i-am", {"lat": 22.3561,
                                                                      "lng": 91.7832},
                                format="json").status_code, 200)
        p.refresh_from_db()
        self.assertEqual((p.open_lat, p.open_lng), (22.36, 91.78))
        c.post("/api/v1/missing-alerts/nearby", {"enabled": False}, format="json")
        p.refresh_from_db()
        self.assertEqual((p.enabled, p.home_lat, p.open_lat, p.open_at), (False, None, None, None))
        self.assertEqual(c.post("/api/v1/missing-alerts/where-i-am", {"lat": 23.8, "lng": 90.4},
                                format="json").status_code, 409)

    def test_config_lists_districts_and_family(self):
        r = self.api(self.mum).get("/api/v1/missing-alerts/config").json()
        self.assertEqual(len(r["districts"]), 64)
        self.assertEqual([x["id"] for x in r["cosigners"]], [self.dad.id])
        self.assertFalse(r["optin"]["enabled"])
