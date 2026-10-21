"""Tests for the Discover cards manager + sponsored cards (slot d1-discover)."""
import re
from datetime import timedelta
from pathlib import Path

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import discover as D
from core.models import DiscoverCard, DiscoverDailyStat, User

SEED_KEYS = ["photo_enhance", "phone_safety", "journey", "messages",
             "used_phone_check", "vehicles", "security", "plans", "asalify",
             "axon"]


def _row(**kw):
    base = {"id": kw.pop("id", 1), "type": "FEATURE", "enabled": True,
            "start_at": None, "end_at": None, "audience": "all",
            "min_build": None, "order": 0}
    base.update(kw)
    return base


class RulesPureTests(TestCase):
    now = timezone.now()

    def ids(self, rows, seg, build=None):
        return [r["id"] for r in D.visible_cards(rows, seg, build, self.now)]

    def test_sponsored_reaches_all_plans_admob_free_only(self):
        # owner decision 21 Oct: SPONSORED -> every plan (audience can narrow);
        # ADMOB stays Free-only (paid-plan benefit).
        rows = [_row(id=1), _row(id=2, type="SPONSORED", audience="premium"),
                _row(id=3, type="ADMOB"), _row(id=4, type="SPONSORED")]
        self.assertEqual(self.ids(rows, "premium"), [1, 2, 4])
        self.assertEqual(self.ids(rows, "business"), [1, 4])
        self.assertEqual(self.ids(rows, "free"), [1, 4])
        for r in D.visible_cards(rows, "premium", None, self.now):
            if r["type"] == "SPONSORED":
                self.assertEqual(D.label_for(r["type"]), "sponsored")

    def test_admob_only_free_and_only_without_sponsor(self):
        rows = [_row(id=1), _row(id=3, type="ADMOB", order=5)]
        self.assertEqual(self.ids(rows, "free"), [1, 3])
        rows.append(_row(id=4, type="SPONSORED"))
        self.assertEqual(self.ids(rows, "free"), [1, 4])

    def test_admob_fills_when_sponsor_expired_and_max_one(self):
        past = self.now - timedelta(days=1)
        rows = [_row(id=3, type="ADMOB"), _row(id=5, type="ADMOB"),
                _row(id=4, type="SPONSORED", end_at=past)]
        self.assertEqual(self.ids(rows, "free"), [3])

    def test_audience(self):
        rows = [_row(id=1, audience="free"), _row(id=2, audience="premium"),
                _row(id=3, audience="business"), _row(id=4)]
        self.assertEqual(self.ids(rows, "free"), [1, 4])
        self.assertEqual(self.ids(rows, "premium"), [2, 4])
        self.assertEqual(self.ids(rows, "business"), [3, 4])

    def test_window_min_build_disabled(self):
        rows = [_row(id=1, end_at=self.now), _row(id=2, start_at=self.now + timedelta(hours=1)),
                _row(id=3, min_build=150), _row(id=4, enabled=False), _row(id=5)]
        self.assertEqual(self.ids(rows, "free", 149), [5])
        self.assertEqual(self.ids(rows, "free", 150), [3, 5])
        self.assertEqual(self.ids(rows, "free", None), [5])

    def test_order(self):
        rows = [_row(id=1, order=20), _row(id=2, order=10), _row(id=3, order=10)]
        self.assertEqual(self.ids(rows, "free"), [2, 3, 1])

    def test_labels(self):
        self.assertEqual(D.label_for("OUR_PRODUCT"), "our_products")
        self.assertEqual(D.label_for("SPONSORED"), "sponsored")
        self.assertEqual(D.label_for("FEATURE"), "")

    def test_safety_rejects(self):
        bad = [
            {"title_en": "Best online casino"},
            {"desc_en": "Guaranteed profit every day"},
            {"title_bn": "জুয়া খেলুন"},
            {"desc_bn": "টাকা দ্বিগুণ করুন"},
            {"title_en": "Adults only videos"},
            {"desc_bn": "পর্ন দেখুন"},
            {"desc_en": "Double your money in a week"},
            {"url": "http://example.com"},
            {"url": "https://bit.ly/abc"},
            {"url": "https://tinyurl.com/x"},
            {"url": "https://1.2.3.4/x"},
            {"desc_en": "Visit https://evil.example now"},
        ]
        for f in bad:
            self.assertTrue(D.safety_issues(f), f)

    def test_safety_accepts_normal_copy(self):
        ok = {"title_en": "Fresh groceries", "title_bn": "তাজা বাজার",
              "desc_en": "Order vegetables delivered to your door.",
              "desc_bn": "ঘরে বসে সবজি অর্ডার করুন।", "url": "https://shop.example.com"}
        self.assertEqual(D.safety_issues(ok), [])

    def test_route_keys_match_chatnav(self):
        p = Path(__file__).resolve().parents[2] / "app/lib/widgets/chatnav.dart"
        if not p.exists():
            self.skipTest("app source not present")
        src = p.read_text()
        start = src.index("routes = {")
        block = src[start:src.index("};", start)]
        keys = re.findall(r"^\s*'([a-z_0-9]+)':", block, re.M)
        self.assertEqual(sorted(keys), sorted(D.ROUTE_KEYS))

    def test_revenue_spread(self):
        tz = timezone.get_current_timezone()
        s = timezone.datetime(2026, 10, 1, 0, 0, tzinfo=tz)
        e = timezone.datetime(2026, 10, 11, 0, 0, tzinfo=tz)
        r = D.revenue_by_day({"type": "SPONSORED", "sponsor_revenue": 1000,
                              "start_at": s, "end_at": e}, timezone.localdate)
        self.assertEqual(len(r), 10)
        self.assertAlmostEqual(sum(r.values()), 1000)
        self.assertEqual(D.revenue_by_day({"type": "FEATURE", "sponsor_revenue": 5,
                                           "start_at": s}, timezone.localdate), {})


class _Base(APITestCase):
    def setUp(self):
        self.free = User.objects.create_user(name="F", phone="01710009001", password="pw")
        self.prem = User.objects.create_user(name="P", phone="01710009002", password="pw")
        self.prem.plan = "premium"
        self.prem.plan_until = timezone.now() + timedelta(days=30)
        self.prem.save()
        self.biz = User.objects.create_user(name="B", phone="01710009003", password="pw")
        self.biz.plan = "business"
        self.biz.plan_until = timezone.now() + timedelta(days=30)
        self.biz.save()
        self.owner = User.objects.create_user(name="O", phone="01710009004", password="pw",
                                              is_staff=True, is_superuser=True)

    def feed(self, user, build=None):
        self.client.force_authenticate(user)
        q = "" if build is None else "?build=%d" % build
        r = self.client.get("/api/v1/discover/cards" + q)
        self.assertEqual(r.status_code, 200)
        return r.data["cards"]

    def admin_create(self, **data):
        self.client.force_authenticate(self.owner)
        return self.client.post("/api/v1/admin/discover/cards", data, format="json")


class SeedAndFeedTests(_Base):
    def test_seed_matches_old_hardcoded_list(self):
        cards = self.feed(self.free)
        self.assertEqual([c["key"] for c in cards], SEED_KEYS)
        asal = next(c for c in cards if c["key"] == "asalify")
        self.assertEqual(asal["url"], "https://asalify.com")
        self.assertEqual(asal["label"], "our_products")
        axon = next(c for c in cards if c["key"] == "axon")
        self.assertEqual(axon["url"], "https://axonerpsoftware.com")
        self.assertEqual(cards[0]["route"], "photo_enhance")
        self.assertEqual(cards[0]["title"]["en"], "Enhance photo")
        self.assertTrue(cards[0]["title"]["bn"])

    def test_seed_copy_passes_safety(self):
        for c in DiscoverCard.objects.all():
            f = {k: getattr(c, k) for k in ("title_bn", "title_en", "desc_bn",
                                            "desc_en", "url")}
            self.assertEqual(D.safety_issues(f), [], c.key)

    def test_feed_requires_auth(self):
        self.assertEqual(self.client.get("/api/v1/discover/cards").status_code, 401)


class SponsoredFeedTests(_Base):
    def setUp(self):
        super().setUp()
        self.sp = DiscoverCard.objects.create(
            key="sp1", type="SPONSORED", title_bn="তাজা বাজার", title_en="Fresh market",
            url="https://shop.example.com", sponsor_name="Shop", order=1)
        self.ad = DiscoverCard.objects.create(key="ad1", type="ADMOB", order=2)

    def keys(self, user, build=None):
        return [c["key"] for c in self.feed(user, build)]

    def test_premium_business_see_sponsored_labelled_never_admob(self):
        for u in (self.prem, self.biz):
            cards = self.feed(u)
            sp = next(c for c in cards if c["key"] == "sp1")
            self.assertEqual(sp["label"], "sponsored")
            self.assertNotIn("ad1", [c["key"] for c in cards])

    def test_free_sees_sponsor_with_label_and_no_admob(self):
        cards = self.feed(self.free)
        sp = next(c for c in cards if c["key"] == "sp1")
        self.assertEqual(sp["label"], "sponsored")
        self.assertNotIn("ad1", [c["key"] for c in cards])

    def test_admob_fills_when_no_sponsor(self):
        self.sp.enabled = False
        self.sp.save()
        cards = self.feed(self.free)
        ad = next(c for c in cards if c["key"] == "ad1")
        self.assertEqual(ad["type"], "ADMOB")

    def test_audience_and_min_build_on_feed(self):
        DiscoverCard.objects.create(key="biz-only", type="FEATURE", title_bn="ক",
                                    title_en="B", route="business", audience="business")
        DiscoverCard.objects.create(key="new-only", type="FEATURE", title_bn="ক",
                                    title_en="N", route="plans", min_build=200)
        self.assertIn("biz-only", self.keys(self.biz))
        self.assertNotIn("biz-only", self.keys(self.prem))
        self.assertNotIn("new-only", self.keys(self.free, 199))
        self.assertIn("new-only", self.keys(self.free, 200))


class AdminTests(_Base):
    def test_non_owner_forbidden_everywhere(self):
        self.client.force_authenticate(self.prem)
        c = DiscoverCard.objects.first()
        for m, url in [("get", "/api/v1/admin/discover/cards"),
                       ("post", "/api/v1/admin/discover/cards"),
                       ("patch", "/api/v1/admin/discover/cards/%d" % c.id),
                       ("delete", "/api/v1/admin/discover/cards/%d" % c.id),
                       ("post", "/api/v1/admin/discover/reorder"),
                       ("get", "/api/v1/admin/discover/meta"),
                       ("get", "/api/v1/admin/discover/preview"),
                       ("get", "/api/v1/admin/discover/cards/%d/report" % c.id),
                       ("get", "/api/v1/admin/discover/cards/%d/report.csv" % c.id)]:
            r = getattr(self.client, m)(url, {}, format="json")
            self.assertEqual(r.status_code, 403, url)
        self.assertTrue(DiscoverCard.objects.filter(pk=c.id).exists())

    def test_create_rejects_unsafe_and_bad_fields(self):
        r = self.admin_create(type="SPONSORED", title_bn="ক্যাসিনো", title_en="Casino",
                              url="https://win.example.com", sponsor_name="X")
        self.assertEqual(r.status_code, 400)
        self.assertIn("banned_wording", r.data["safety"])
        r = self.admin_create(type="OUR_PRODUCT", title_bn="ক", title_en="A",
                              url="http://plain.example.com")
        self.assertIn("url_not_https", r.data["safety"])
        r = self.admin_create(type="FEATURE", title_bn="ক", title_en="A",
                              route="nope")
        self.assertEqual(r.data["errors"]["route"], "unknown_route")
        r = self.admin_create(type="SPONSORED", title_bn="ক", title_en="A",
                              url="https://ok.example.com")
        self.assertEqual(r.data["errors"]["sponsor_name"], "required")

    def test_edit_reorder_toggle_delete_meta_preview(self):
        r = self.admin_create(type="FEATURE", title_bn="নোট", title_en="Notes",
                              route="notes", icon="lightbulb")
        self.assertEqual(r.status_code, 201)
        pk = r.data["id"]
        r = self.client.patch("/api/v1/admin/discover/cards/%d" % pk,
                              {"enabled": False}, format="json")
        self.assertFalse(r.data["enabled"])
        self.assertNotIn("Notes", [c["title"]["en"] for c in self.feed(self.free)])
        self.client.force_authenticate(self.owner)
        r = self.client.patch("/api/v1/admin/discover/cards/%d" % pk,
                              {"enabled": True, "desc_en": "Free money now"}, format="json")
        self.assertEqual(r.status_code, 400)
        ids = list(DiscoverCard.objects.values_list("id", flat=True))
        ids = [pk] + [i for i in ids if i != pk]
        r = self.client.post("/api/v1/admin/discover/reorder", {"ids": ids}, format="json")
        self.assertEqual(r.status_code, 200)
        self.client.patch("/api/v1/admin/discover/cards/%d" % pk, {"enabled": True}, format="json")
        self.assertEqual(self.feed(self.free)[0]["key"], DiscoverCard.objects.get(pk=pk).key)
        self.client.force_authenticate(self.owner)
        m = self.client.get("/api/v1/admin/discover/meta").data
        self.assertIn("photo_enhance", m["routes"])
        p = self.client.get("/api/v1/admin/discover/preview?segment=premium").data
        self.assertEqual(p["segment"], "premium")
        r = self.client.delete("/api/v1/admin/discover/cards/%d" % pk)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(DiscoverCard.objects.filter(pk=pk).exists())

    def test_image_upload_signed_url(self):
        import io
        import tempfile
        from django.test import override_settings
        with tempfile.TemporaryDirectory() as tmp, override_settings(MEDIA_ROOT=tmp):
            self._upload()

    def _upload(self):
        import io
        from PIL import Image
        from django.core.files.uploadedfile import SimpleUploadedFile
        c = DiscoverCard.objects.get(key="asalify")
        buf = io.BytesIO()
        Image.new("RGB", (8, 8), "blue").save(buf, "PNG")
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/discover/cards/%d/image" % c.id,
                             {"image": SimpleUploadedFile("a.png", buf.getvalue(), "image/png")},
                             format="multipart")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["image_url"].startswith("/api/v1/m/discover/"))
        r = self.client.post("/api/v1/admin/discover/cards/%d/image" % c.id,
                             {"image": SimpleUploadedFile("a.png", b"notimage", "image/png")},
                             format="multipart")
        self.assertEqual(r.status_code, 400)
        c.refresh_from_db()
        c.image.delete(save=True)

    def test_end_to_end_add_then_expires(self):
        end = timezone.now() + timedelta(days=2)
        r = self.admin_create(type="SPONSORED", title_bn="তাজা বাজার",
                              title_en="Fresh market", desc_en="Vegetables at home",
                              desc_bn="ঘরে বসে সবজি", url="https://shop.example.com",
                              sponsor_name="Shop Ltd", sponsor_revenue=500,
                              end_at=end.isoformat(), audience="free")
        self.assertEqual(r.status_code, 201, r.data)
        key = r.data["key"]
        cards = self.feed(self.free)
        sp = next(c for c in cards if c["key"] == key)
        self.assertEqual(sp["label"], "sponsored")
        self.assertNotIn(key, [c["key"] for c in self.feed(self.prem)])
        # time passes beyond the end date -> gone
        from unittest import mock
        with mock.patch("django.utils.timezone.now", return_value=end + timedelta(minutes=1)):
            self.assertNotIn(key, [c["key"] for c in self.feed(self.free)])


class TrackingReportTests(_Base):
    def setUp(self):
        super().setUp()
        self.sp = DiscoverCard.objects.create(
            key="sp1", type="SPONSORED", title_bn="তাজা", title_en="Fresh",
            url="https://shop.example.com", sponsor_name="Shop", order=1)

    def track(self, user, event, card=None):
        self.client.force_authenticate(user)
        return self.client.post("/api/v1/discover/track",
                                {"card_id": (card or self.sp).id, "event": event},
                                format="json")

    def test_impression_dedupe_per_user_per_day(self):
        self.assertEqual(self.track(self.free, "impression").data["counted"], 1)
        self.assertEqual(self.track(self.free, "impression").data["counted"], 0)
        other = User.objects.create_user(name="F2", phone="01710009005", password="pw")
        self.assertEqual(self.track(other, "impression").data["counted"], 1)
        self.track(self.free, "click")
        st = DiscoverDailyStat.objects.get(card=self.sp)
        self.assertEqual((st.impressions, st.clicks), (2, 1))

    def test_premium_events_on_sponsored_counted(self):
        # sponsored cards now reach Premium too, so their views count for the sponsor
        self.assertEqual(self.track(self.prem, "impression").data["counted"], 1)
        self.assertTrue(DiscoverDailyStat.objects.filter(card=self.sp).exists())

    def test_bad_payload_is_200(self):
        self.client.force_authenticate(self.free)
        r = self.client.post("/api/v1/discover/track", {"card_id": "x", "event": "boom"},
                             format="json")
        self.assertEqual(r.status_code, 200)

    def test_report_json_csv_pdf(self):
        today = timezone.localdate()
        DiscoverDailyStat.objects.create(card=self.sp, date=today - timedelta(days=1),
                                         impressions=200, clicks=10)
        self.track(self.free, "impression")
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/admin/discover/cards/%d/report?days=7" % self.sp.id)
        self.assertEqual(len(r.data["rows"]), 7)
        self.assertEqual(r.data["totals"], {"impressions": 201, "clicks": 10, "ctr": 4.98})
        y = next(x for x in r.data["rows"] if x["date"] == (today - timedelta(days=1)).isoformat())
        self.assertEqual(y["ctr"], 5.0)
        r = self.client.get("/api/v1/admin/discover/cards/%d/report.csv?days=7" % self.sp.id)
        self.assertEqual(r.status_code, 200)
        body = r.content.decode()
        self.assertIn("date,impressions,clicks,ctr_percent", body)
        self.assertIn("total,201,10,4.98", body)
        r = self.client.get("/api/v1/admin/discover/cards/%d/report.pdf" % self.sp.id)
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.content.startswith(b"%PDF"))
        r = self.client.get("/api/v1/admin/discover/cards/%d/report.xls" % self.sp.id)
        self.assertEqual(r.status_code, 404)
        lst = self.client.get("/api/v1/admin/discover/cards").data["cards"]
        mine = next(c for c in lst if c["id"] == self.sp.id)
        self.assertEqual(mine["stats"]["impressions"], 201)


class PnlInclusionTests(_Base):
    def test_sponsor_revenue_in_pnl(self):
        now = timezone.now()
        DiscoverCard.objects.create(
            key="sp-pnl", type="SPONSORED", title_bn="ক", title_en="A",
            url="https://shop.example.com", sponsor_name="S", sponsor_revenue=700,
            start_at=now - timedelta(days=3), end_at=now + timedelta(days=4))
        self.client.force_authenticate(self.owner)
        r = self.client.get("/api/v1/admin/pnl?days=30")
        self.assertEqual(r.status_code, 200)
        # 7 or 8 local dates are touched depending on time of day; the days up
        # to today are inside the window, future days are not yet booked.
        total = r.data["sponsored"]["total"]
        self.assertGreater(total, 0)
        self.assertLess(total, 700)
        self.assertAlmostEqual(r.data["totals"]["revenue"], total, places=1)
        today = next(d for d in r.data["series"]
                     if d["date"] == timezone.localdate().isoformat())
        self.assertGreater(today["revenue"]["sponsored"], 0)

    def test_non_sponsored_revenue_zeroed(self):
        r = self.admin_create(type="FEATURE", title_bn="ক", title_en="A",
                              route="plans", sponsor_revenue=999, sponsor_name="Z")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["sponsor_revenue"], 0)
        r = self.client.get("/api/v1/admin/pnl?days=7")
        self.assertEqual(r.data["sponsored"]["total"], 0)
