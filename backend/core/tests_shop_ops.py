"""a2-cctv: CCTV Part 4 round 2 — camera settings, device heartbeat/config/pair,
POS mirror + void + spikes, EOD cash check, extra-camera billing, live-view
signaling. Honesty: owner-facing text says "please check", never theft."""
import json
from datetime import timedelta
from unittest import mock

from django.test import override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core.models import User

BANNED = ("theft", "thief", "steal", "stole", "চুরি", "চোর")


def _assert_honest(tc, *texts):
    for t in texts:
        low = (t or "").lower()
        for w in BANNED:
            tc.assertNotIn(w, low, "banned word %r in %r" % (w, t))


class _Base(APITestCase):
    def setUp(self):
        from unittest import mock as _m
        from core.models import ShopSite, ShopCamera
        # billing-v2: an owner-edited Business plan (no payment) gets its
        # month of allowance on the first spend; these tests count the
        # purchased balance only, so the base month is switched off here.
        _p = _m.patch("core.credits._base_allowance", return_value=0)
        _p.start()
        self.addCleanup(_p.stop)
        self.owner = User.objects.create_user(name="Owner", phone="01710001001",
                                              password="pw")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.ai_credits = 100
        self.owner.language = "en"
        self.owner.save()
        self.site = ShopSite.objects.create(owner=self.owner, name="Main")
        self.cam = ShopCamera.objects.create(site=self.site, name="Till",
                                             kind="shopbox")
        self.client.force_authenticate(self.owner)

    def dev(self):
        """A client with NO user login (device calls)."""
        from rest_framework.test import APIClient
        return APIClient()


# ---------------------------------------------------------------------------
class CameraSettingsTests(_Base):
    def test_patch_name_hours_restricted_and_rotate(self):
        old = self.cam.camera_token
        r = self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id, {
            "name": "Counter", "hours": {"open": "9:00", "close": "21:30"},
            "restricted_zone": False, "rotate_token": True}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["name"], "Counter")
        self.assertEqual(r.data["hours"], {"open": "09:00", "close": "21:30"})
        self.assertFalse(r.data["restricted_zone"])
        self.assertNotEqual(r.data["camera_token"], old)
        self.cam.refresh_from_db()
        self.assertEqual(self.cam.camera_token, r.data["camera_token"])
        # the old token no longer authenticates a device
        r2 = self.dev().post("/api/v1/shop/pair/check", {"camera_token": old},
                             format="json")
        self.assertEqual(r2.status_code, 401)

    def test_get_reveals_token_and_webhook_paths_owner_only(self):
        r = self.client.get("/api/v1/shop/cameras/%d" % self.cam.id)
        self.assertEqual(r.data["camera_token"], self.cam.camera_token)
        self.assertEqual(r.data["webhook_paths"]["hikvision"],
                         "shop/hook/hikvision/%s" % self.cam.camera_token)
        other = User.objects.create_user(name="Y", phone="01710001998", password="pw")
        self.client.force_authenticate(other)
        self.assertEqual(self.client.get("/api/v1/shop/cameras/%d" % self.cam.id
                                         ).status_code, 404)

    def test_bad_hours_422_and_clear_hours(self):
        r = self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                              {"hours": {"open": "25:00", "close": "x"}}, format="json")
        self.assertEqual(r.status_code, 422)
        self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                          {"hours": {"open": "09:00", "close": "22:00"}}, format="json")
        r = self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                              {"hours": None}, format="json")
        self.assertIsNone(r.data["hours"])

    def test_zone_config_keeps_hours(self):
        self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                          {"hours": {"open": "09:00", "close": "22:00"}}, format="json")
        r = self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                              {"zone_config": {"cash_zone": [[0.1, 0.1], [0.5, 0.1],
                                                             [0.5, 0.5]]}}, format="json")
        self.assertEqual(r.data["zone_config"]["hours"]["open"], "09:00")
        self.assertIn("cash_zone", r.data["zone_config"])

    def test_disable_and_delete_owner_only(self):
        other = User.objects.create_user(name="X", phone="01710001999", password="pw")
        self.client.force_authenticate(other)
        r = self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                              {"enabled": False}, format="json")
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.client.delete("/api/v1/shop/cameras/%d" % self.cam.id
                                            ).status_code, 404)
        self.client.force_authenticate(self.owner)
        r = self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                              {"enabled": False}, format="json")
        self.assertFalse(r.data["enabled"])
        r = self.client.delete("/api/v1/shop/cameras/%d" % self.cam.id)
        self.assertEqual(r.status_code, 200)
        from core.models import ShopCamera
        self.assertFalse(ShopCamera.objects.filter(pk=self.cam.id).exists())

    def test_reenable_extra_camera_needs_credits(self):
        from core.models import ShopCamera
        for i in range(4):
            ShopCamera.objects.create(site=self.site, name="c%d" % i)
        extra = ShopCamera.objects.create(site=self.site, name="extra", enabled=False)
        self.owner.ai_credits = 5
        self.owner.save()
        r = self.client.patch("/api/v1/shop/cameras/%d" % extra.id,
                              {"enabled": True}, format="json")
        self.assertEqual(r.status_code, 402)
        self.owner.ai_credits = 50
        self.owner.save()
        r = self.client.patch("/api/v1/shop/cameras/%d" % extra.id,
                              {"enabled": True}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["charged_credits"], 20)
        self.assertIsNotNone(r.data["billed_until"])

    def test_create_cap_counts_across_sites_and_sets_billed_until(self):
        from core.models import ShopSite, ShopCamera
        s2 = ShopSite.objects.create(owner=self.owner, name="Second")
        for i in range(3):
            ShopCamera.objects.create(site=s2, name="c%d" % i)
        # 4 enabled across both sites -> the next one is extra
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site.id,
                             {"name": "new"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["charged_credits"], 20)
        self.assertIsNotNone(r.data["billed_until"])

    def test_site_hours_and_pos_link_patch(self):
        r = self.client.patch("/api/v1/shop/sites/%d" % self.site.id,
                              {"hours": {"open": "10:00", "close": "20:00"},
                               "pos_link": False}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["hours"]["close"], "20:00")
        self.assertFalse(r.data["pos_link"])


# ---------------------------------------------------------------------------
HIK = (b'<?xml version="1.0"?><EventNotificationAlert xmlns="http://www.hikvision.com/'
       b'ver20/XMLSchema"><channelID>1</channelID><eventType>linedetection</eventType>'
       b'<eventState>active</eventState></EventNotificationAlert>')


class WebhookHoursFallbackTests(_Base):
    def test_site_hours_used_when_camera_has_none(self):
        from core.models import ShopEvent
        now_local = timezone.localtime()
        # site "open" only for a 1-minute window far from now -> after hours
        h = (now_local + timedelta(hours=6)).strftime("%H:%M")
        h2 = (now_local + timedelta(hours=6, minutes=1)).strftime("%H:%M")
        self.site.hours = {"open": h, "close": h2}
        self.site.save()
        r = self.client.generic("POST", "/api/v1/shop/hook/hikvision/%s" %
                                self.cam.camera_token, HIK,
                                content_type="application/xml")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(ShopEvent.objects.filter(type="after_hours").count(), 1)
        self.cam.refresh_from_db()
        self.assertIsNotNone(self.cam.last_seen)

    def test_camera_hours_override_site(self):
        from core.models import ShopEvent
        self.site.hours = {"open": "00:00", "close": "00:01"}   # always closed
        self.site.save()
        self.cam.zone_config = {"hours": {"open": "00:00", "close": "23:59"},
                                "restricted_zone": False}
        self.cam.save()
        self.client.generic("POST", "/api/v1/shop/hook/hikvision/%s" %
                            self.cam.camera_token, HIK, content_type="application/xml")
        # camera open nearly all day + not restricted -> lone motion, no alert
        if timezone.localtime().strftime("%H:%M") < "23:59":
            self.assertEqual(ShopEvent.objects.count(), 0)


# ---------------------------------------------------------------------------
class DeviceEndpointTests(_Base):
    def test_pair_check_site_and_camera_token(self):
        r = self.dev().post("/api/v1/shop/pair/check",
                            {"site_token": self.site.enrollment_token}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["site"]["name"], "Main")
        self.assertEqual(r.data["token_kind"], "site")
        self.assertEqual(len(r.data["cameras"]), 1)
        r = self.dev().post("/api/v1/shop/pair/check",
                            {"camera_token": self.cam.camera_token}, format="json")
        self.assertEqual(r.data["camera"]["id"], self.cam.id)
        self.assertEqual(r.data["token_kind"], "camera")
        r = self.dev().post("/api/v1/shop/pair/check", {"site_token": "nope"},
                            format="json")
        self.assertEqual(r.status_code, 401)

    def test_heartbeat_updates_last_seen_and_config_version(self):
        c = self.dev()
        r = c.post("/api/v1/shop/heartbeat", {"camera_token": self.cam.camera_token,
                                              "caps": ["live"], "platform": "android"},
                   format="json")
        self.assertEqual(r.status_code, 200)
        v1 = r.data["config_version"]
        self.cam.refresh_from_db()
        self.site.refresh_from_db()
        self.assertIsNotNone(self.cam.last_seen)
        self.assertIsNotNone(self.site.last_seen)
        self.assertEqual(self.cam.device_info["caps"], ["live"])
        # owner sees it online
        rows = self.client.get("/api/v1/shop/sites/%d/cameras" % self.site.id).data
        self.assertTrue(rows["cameras"][0]["online"])
        self.assertTrue(rows["cameras"][0]["live_capable"])
        # a config change bumps the version
        self.client.patch("/api/v1/shop/cameras/%d" % self.cam.id,
                          {"restricted_zone": False}, format="json")
        r = c.post("/api/v1/shop/heartbeat", {"camera_token": self.cam.camera_token},
                   format="json")
        self.assertNotEqual(v1, r.data["config_version"])

    def test_offline_after_window(self):
        from core.models import ShopCamera
        ShopCamera.objects.filter(pk=self.cam.pk).update(
            last_seen=timezone.now() - timedelta(minutes=10))
        rows = self.client.get("/api/v1/shop/sites/%d/cameras" % self.site.id).data
        self.assertFalse(rows["cameras"][0]["online"])
        self.assertIsNotNone(rows["cameras"][0]["last_seen"])

    def test_heartbeat_site_token_with_camera_ids(self):
        r = self.dev().post("/api/v1/shop/heartbeat",
                            {"site_token": self.site.enrollment_token,
                             "camera_ids": [self.cam.id]}, format="json")
        self.assertEqual(r.status_code, 200)
        self.cam.refresh_from_db()
        self.assertIsNotNone(self.cam.last_seen)

    def test_config_via_header_and_site_hours_fallback(self):
        self.site.hours = {"open": "09:00", "close": "21:00"}
        self.site.save()
        r = self.dev().get("/api/v1/shop/config",
                           HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        self.assertEqual(r.status_code, 200)
        self.assertEqual(len(r.data["cameras"]), 1)
        self.assertEqual(r.data["cameras"][0]["hours"]["open"], "09:00")
        self.assertTrue(r.data["cameras"][0]["restricted_zone"])
        self.assertTrue(r.data["version"])
        self.assertEqual(self.dev().get("/api/v1/shop/config",
                                        HTTP_X_SHOP_TOKEN="bad").status_code, 401)

    def test_device_cannot_read_other_site(self):
        from core.models import ShopSite
        other_owner = User.objects.create_user(name="O2", phone="01710001002",
                                               password="pw")
        s2 = ShopSite.objects.create(owner=other_owner, name="Other")
        r = self.dev().get("/api/v1/shop/config",
                           HTTP_X_SHOP_TOKEN=s2.enrollment_token)
        self.assertEqual([c["id"] for c in r.data["cameras"]], [])


# ---------------------------------------------------------------------------
class PosMirrorVoidTests(_Base):
    def setUp(self):
        super().setUp()
        from core.models import BusinessProfile, Product, ProductVariant
        self.prof = BusinessProfile.objects.create(user=self.owner, shop_name="Dokan")
        self.p = Product.objects.create(user=self.owner, business=self.prof,
                                        name="Soap", price=100, min_price=50)
        self.v = ProductVariant.objects.create(product=self.p, vkey="__base__",
                                               sell_price=100, min_price=50,
                                               cost_price=60, stock=10)

    def _sell(self, qty=1, discount=0, method="cash", paid=None, phone=""):
        r = self.client.post("/api/v1/business/cart/add",
                             {"product": self.p.id, "qty": qty}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        body = {"cart": r.data["cart"], "payment_method": method,
                "discount": discount}
        if paid is not None:
            body["paid"] = paid
        if phone:
            body["customer_phone"] = phone
            body["customer_name"] = "Rahim"
        r = self.client.post("/api/v1/business/sales/checkout", body, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        return r.data["sale_id"]

    def test_checkout_mirrors_sale_and_discount(self):
        from core.models import ShopPosEvent, SaleLine
        sid = self._sell(qty=2, discount=10)
        kinds = sorted(ShopPosEvent.objects.filter(site=self.site)
                       .values_list("kind", flat=True))
        self.assertEqual(kinds, ["discount", "sale"])
        disc = ShopPosEvent.objects.get(site=self.site, kind="discount")
        self.assertEqual(disc.amount, 1000)
        line = SaleLine.objects.get(sale_id=sid)
        self.assertEqual(line.variant_key, "__base__")
        self.assertEqual(line.variant_id, self.v.id)

    def test_no_mirror_when_pos_link_off(self):
        from core.models import ShopPosEvent
        self.site.pos_link = False
        self.site.save()
        self._sell()
        self.assertEqual(ShopPosEvent.objects.count(), 0)

    def test_mirror_failure_never_breaks_checkout(self):
        with mock.patch("core.shop_ops_views.mirror_pos",
                        side_effect=RuntimeError("boom")):
            self._sell()

    def test_void_restores_stock_excludes_reports_and_mirrors(self):
        from core.models import Sale, ShopPosEvent
        sid = self._sell(qty=3)
        self.v.refresh_from_db()
        self.assertEqual(self.v.stock, 7)
        r = self.client.post("/api/v1/business/sales/%d/void" % sid, {},
                             format="json")
        self.assertEqual(r.status_code, 422)          # reason required
        r = self.client.post("/api/v1/business/sales/%d/void" % sid,
                             {"reason": "wrong item"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.v.refresh_from_db()
        self.assertEqual(self.v.stock, 10)
        self.assertTrue(Sale.objects.get(pk=sid).voided_at)
        self.assertTrue(ShopPosEvent.objects.filter(kind="void").exists())
        # again -> 409
        r = self.client.post("/api/v1/business/sales/%d/void" % sid,
                             {"reason": "again"}, format="json")
        self.assertEqual(r.status_code, 409)
        # receipt shows VOID
        rc = self.client.get("/api/v1/business/sales/%d/receipt" % sid)
        self.assertTrue(rc.data["voided"])
        self.assertIn("VOID", rc.data["status_text"])
        # reports exclude it
        rep = self.client.get("/api/v1/business/reports/?period=daily")
        if rep.status_code == 404:
            rep = self.client.get("/api/v1/business/reports?period=daily")
        self.assertEqual(rep.status_code, 200)
        self.assertNotIn('"total": %d' % 30000, json.dumps(rep.data))

    def test_void_old_sale_without_variant_is_honest(self):
        from core.models import SaleLine
        sid = self._sell(qty=1)
        SaleLine.objects.filter(sale_id=sid).update(variant=None, variant_key="")
        r = self.client.post("/api/v1/business/sales/%d/void" % sid,
                             {"reason": "test"}, format="json")
        self.assertEqual(r.data["stock_restore_skipped_lines"], 1)
        self.assertIn("by hand", r.data["note"])

    def test_void_reverses_khata_due_once(self):
        from core.models import KhataEntry
        sid = self._sell(method="due", paid=0, phone="01811111111")
        self.assertEqual(KhataEntry.objects.count(), 1)
        r = self.client.post("/api/v1/business/sales/%d/void" % sid,
                             {"reason": "returned"}, format="json")
        self.assertEqual(r.data["khata"]["status"], "reversed")
        got = KhataEntry.objects.get(direction="got")
        self.assertEqual(got.amount_poisha, 10000)
        self.assertIn("[void-sale#%d]" % sid, got.note)

    def test_staff_same_day_only(self):
        from core.models import BusinessStaff, Sale
        staff = User.objects.create_user(name="Staff", phone="01710001003",
                                         password="pw")
        BusinessStaff.objects.create(business=self.prof, member=staff)
        sid = self._sell()
        self.client.force_authenticate(staff)
        Sale.objects.filter(pk=sid).update(created_at=timezone.now() - timedelta(days=2))
        r = self.client.post("/api/v1/business/sales/%d/void" % sid,
                             {"reason": "x y", "business": self.prof.id}, format="json")
        self.assertEqual(r.status_code, 403)
        Sale.objects.filter(pk=sid).update(created_at=timezone.now())
        r = self.client.post("/api/v1/business/sales/%d/void" % sid,
                             {"reason": "x y", "business": self.prof.id}, format="json")
        self.assertEqual(r.status_code, 200, r.data)

    def test_void_spike_raises_please_check_once(self):
        from core.models import ShopEvent, NotifEvent
        from core import shop_ops_views as OPS
        for _ in range(3):
            OPS.mirror_pos(self.prof, "void", 1000)
        evs = ShopEvent.objects.filter(type="void_spike")
        self.assertEqual(evs.count(), 1)
        self.assertIn("count_3_vs_baseline_1", evs[0].signals["reason"][1])
        n = NotifEvent.objects.filter(user=self.owner).first()
        self.assertIn("please check", n.title_en.lower())
        self.assertIn("voided sales", n.title_en)
        _assert_honest(self, n.title_en, n.body_en, n.title_bn, n.body_bn)
        OPS.mirror_pos(self.prof, "void", 1000)
        self.assertEqual(ShopEvent.objects.filter(type="void_spike").count(), 1)

    def test_spike_uses_real_baseline(self):
        from core.models import ShopPosEvent, ShopEvent
        from core import shop_ops_views as OPS
        start, _ = OPS._local_day_bounds()
        # a busy history: 3 discounts/day for 14 days -> baseline 3
        for d in range(1, 15):
            for i in range(3):
                ShopPosEvent.objects.create(site=self.site, kind="discount",
                                            amount=100, at=start - timedelta(days=d,
                                                                             minutes=-i))
        self.assertAlmostEqual(OPS.spike_baseline(self.site, "discount", start), 3.0)
        for _ in range(4):
            OPS.mirror_pos(self.prof, "discount", 100)
        self.assertEqual(ShopEvent.objects.filter(type="discount_spike").count(), 0)
        for _ in range(2):
            OPS.mirror_pos(self.prof, "discount", 100)
        self.assertEqual(ShopEvent.objects.filter(type="discount_spike").count(), 1)


# ---------------------------------------------------------------------------
class EodTests(PosMirrorVoidTests):
    def test_eod_ok_short_and_list(self):
        from core.models import ShopEvent, NotifEvent
        self._sell(qty=2, method="cash", paid=500)      # total 200tk, change 300tk
        sid = self._sell(qty=1)
        self.client.post("/api/v1/business/sales/%d/void" % sid, {"reason": "oops"},
                         format="json")
        # expected = 20000 (voided sale excluded) + 5000 float
        r = self.client.post("/api/v1/shop/sites/%d/eod" % self.site.id,
                             {"counted_cash": 24990, "opening_float": 5000},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["expected"], 25000)
        self.assertEqual(r.data["status"], "ok")          # within ৳50
        r = self.client.post("/api/v1/shop/sites/%d/eod" % self.site.id,
                             {"counted_cash": 15000, "opening_float": 5000},
                             format="json")
        self.assertEqual(r.data["status"], "short")
        self.assertIn("please check", r.data["message"].lower())
        self.assertEqual(ShopEvent.objects.filter(type="eod_mismatch").count(), 1)
        n = NotifEvent.objects.filter(user=self.owner).first()
        self.assertIn("end-of-day cash count", n.title_en)
        _assert_honest(self, r.data["message"], n.title_en, n.body_en, n.title_bn,
                       n.body_bn)
        lst = self.client.get("/api/v1/shop/sites/%d/eod" % self.site.id)
        self.assertEqual(len(lst.data["checks"]), 2)
        self.assertEqual(lst.data["tolerance"], 5000)

    def test_eod_tolerance_admin_editable(self):
        from core import billing
        row = billing.get_config()
        data = dict(row.data or {})
        data["shop"] = {"eod_tolerance_poisha": 0}
        row.data = data
        row.save()
        r = self.client.post("/api/v1/shop/sites/%d/eod" % self.site.id,
                             {"counted_cash": 1}, format="json")
        self.assertEqual(r.data["status"], "over")

    def test_eod_bad_amount(self):
        r = self.client.post("/api/v1/shop/sites/%d/eod" % self.site.id,
                             {"counted_cash": "abc"}, format="json")
        self.assertEqual(r.status_code, 422)


# ---------------------------------------------------------------------------
class BillingTests(_Base):
    def _extra(self, n=5):
        from core.models import ShopCamera
        cams = [self.cam] + [ShopCamera.objects.create(site=self.site, name="c%d" % i)
                             for i in range(n - 1)]
        past = timezone.now() - timedelta(days=1)
        ShopCamera.objects.filter(pk=cams[-1].pk).update(billed_until=past)
        return cams

    def test_renews_extra_camera(self):
        from core.management.commands.shop_camera_billing import run_billing
        cams = self._extra(5)
        res = run_billing()
        self.assertEqual(res["renewed"], 1)
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.ai_credits, 80)
        cams[-1].refresh_from_db()
        self.assertGreater(cams[-1].billed_until, timezone.now() + timedelta(days=29))
        # second run the same day: nothing due
        self.assertEqual(run_billing()["renewed"], 0)

    def test_disables_when_insufficient_with_honest_notice(self):
        from core.models import NotifEvent
        from core.management.commands.shop_camera_billing import run_billing
        self.owner.ai_credits = 3
        self.owner.save()
        cams = self._extra(5)
        res = run_billing()
        self.assertEqual(res["disabled"], 1)
        cams[-1].refresh_from_db()
        self.assertFalse(cams[-1].enabled)
        n = NotifEvent.objects.get(user=self.owner)
        self.assertIn("20 credits", n.body_en)
        self.assertIn("ক্রেডিট", n.body_bn)
        _assert_honest(self, n.title_en, n.body_en, n.title_bn, n.body_bn)

    def test_included_cameras_never_charged(self):
        from core.management.commands.shop_camera_billing import run_billing
        from core.models import ShopCamera
        for i in range(3):
            ShopCamera.objects.create(site=self.site, name="c%d" % i,
                                      billed_until=timezone.now() - timedelta(days=5))
        self.assertEqual(run_billing(), {"renewed": 0, "disabled": 0, "credits": 0})

    def test_command_runs(self):
        from django.core.management import call_command
        from io import StringIO
        out = StringIO()
        call_command("shop_camera_billing", stdout=out)
        self.assertIn("shop_camera_billing", out.getvalue())


# ---------------------------------------------------------------------------
@override_settings(TURN_STATIC_SECRET="test-secret", TURN_HOST="turn.example.test",
                   TURN_PORT=3478)
class LiveViewTests(_Base):
    def _online(self, caps=("live",)):
        r = self.dev().post("/api/v1/shop/heartbeat",
                            {"camera_token": self.cam.camera_token,
                             "caps": list(caps)}, format="json")
        self.assertEqual(r.status_code, 200)
        return r

    def _start(self):
        with mock.patch("core.logic.rtc.throttle_decision",
                        return_value={"throttled": False, "reason": ""}):
            return self.client.post("/api/v1/shop/live/start",
                                    {"camera": self.cam.id}, format="json")

    def test_offline_device_is_honest_409(self):
        r = self._start()
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.data["error"], "device_offline")
        self.assertIn("offline", r.data["detail"])

    def test_device_without_live_cap(self):
        self._online(caps=())
        r = self._start()
        self.assertEqual(r.data["error"], "live_unsupported")

    def test_full_signaling_flow_p2p_free(self):
        from core.models import ShopLiveSession
        self._online()
        r = self._start()
        self.assertEqual(r.status_code, 201, r.data)
        sid = r.data["id"]
        self.assertEqual(r.data["max_seconds"], 600)
        urls = [u for x in r.data["ice"]["ice_servers"] for u in x["urls"]]
        self.assertTrue(any(u.startswith("turn:") for u in urls))  # relay allowed
        # device sees it pending (poll + heartbeat)
        dev = self.dev()
        p = dev.get("/api/v1/shop/live/pending", HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        self.assertEqual([s["id"] for s in p.data["sessions"]], [sid])
        hb = self._online()
        self.assertEqual(hb.data["live_pending"][0]["id"], sid)
        # owner offer -> device reads it
        self.client.post("/api/v1/shop/live/%d/signal" % sid,
                         {"kind": "offer", "payload": {"type": "offer", "sdp": "v=0"}},
                         format="json")
        g = dev.get("/api/v1/shop/live/%d/signal?after=0" % sid,
                    HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        self.assertEqual(g.data["messages"][0]["kind"], "offer")
        # device answer + candidate -> session active
        r = dev.post("/api/v1/shop/live/%d/signal" % sid,
                     {"kind": "answer", "payload": {"type": "answer", "sdp": "v=0"}},
                     format="json", HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        self.assertEqual(r.data["status"], "active")
        dev.post("/api/v1/shop/live/%d/signal" % sid,
                 {"kind": "candidate", "payload": {"candidate": "c"}}, format="json",
                 HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        g = self.client.get("/api/v1/shop/live/%d/signal?after=1" % sid)
        self.assertEqual([m["kind"] for m in g.data["messages"]], ["answer", "candidate"])
        # owner never sees its own messages; after= filters
        g2 = self.client.get("/api/v1/shop/live/%d/signal?after=%d" % (sid, g.data["seq"]))
        self.assertEqual(g2.data["messages"], [])
        # end P2P -> free
        e = self.client.post("/api/v1/shop/live/%d/end" % sid,
                             {"relayed": False, "seconds": 120}, format="json")
        self.assertEqual(e.data["charged_credits"], 0)
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.ai_credits, 100)
        self.assertEqual(ShopLiveSession.objects.get(pk=sid).status, "ended")
        # closed session refuses signals
        r = self.client.post("/api/v1/shop/live/%d/signal" % sid,
                             {"kind": "candidate", "payload": {}}, format="json")
        self.assertEqual(r.status_code, 410)

    def test_relayed_minutes_charged_and_clamped(self):
        from core.models import ShopLiveSession
        self._online()
        sid = self._start().data["id"]
        dev = self.dev()
        dev.post("/api/v1/shop/live/%d/signal" % sid, {"kind": "answer", "payload": {}},
                 format="json", HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        ShopLiveSession.objects.filter(pk=sid).update(
            answered_at=timezone.now() - timedelta(seconds=150))
        # client claims 9999 s — clamped to wall clock (~150 s) -> 3 started minutes
        e = self.client.post("/api/v1/shop/live/%d/end" % sid,
                             {"relayed": True, "seconds": 9999}, format="json")
        self.assertEqual(e.data["charged_credits"], 3)
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.ai_credits, 97)
        # a second end report never double-charges
        e = dev.post("/api/v1/shop/live/%d/end" % sid, {"relayed": True, "seconds": 150},
                     format="json", HTTP_X_SHOP_TOKEN=self.cam.camera_token)
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.ai_credits, 97)

    def test_no_credits_means_stun_only(self):
        self.owner.ai_credits = 0
        self.owner.save()
        self._online()
        r = self._start()
        self.assertFalse(r.data["relay_allowed"])
        urls = [u for x in r.data["ice"]["ice_servers"] for u in x["urls"]]
        self.assertTrue(urls and not any(u.startswith("turn") for u in urls))

    def test_session_expires_at_cap_and_pending_timeout(self):
        from core.models import ShopLiveSession
        from core import shop_ops_views as OPS
        self._online()
        sid = self._start().data["id"]
        ShopLiveSession.objects.filter(pk=sid).update(
            created=timezone.now() - timedelta(seconds=OPS.LIVE_PENDING_TIMEOUT_S + 5))
        OPS._sweep_live(timezone.now())
        self.assertEqual(ShopLiveSession.objects.get(pk=sid).status, "expired")
        sid2 = self._start().data["id"]
        ShopLiveSession.objects.filter(pk=sid2).update(
            status="active", expires_at=timezone.now() - timedelta(seconds=1))
        g = self.client.get("/api/v1/shop/live/%d/signal" % sid2)
        self.assertEqual(g.data["status"], "expired")

    def test_other_users_and_tokens_cannot_touch_session(self):
        from core.models import ShopSite
        self._online()
        sid = self._start().data["id"]
        other = User.objects.create_user(name="Z", phone="01710001004", password="pw")
        s2 = ShopSite.objects.create(owner=other, name="Z")
        self.client.force_authenticate(other)
        self.assertEqual(self.client.get("/api/v1/shop/live/%d/signal" % sid
                                         ).status_code, 404)
        r = self.dev().get("/api/v1/shop/live/%d/signal" % sid,
                           HTTP_X_SHOP_TOKEN=s2.enrollment_token)
        self.assertEqual(r.status_code, 404)
        self.assertEqual(self.client.post("/api/v1/shop/live/start",
                                          {"camera": self.cam.id}, format="json"
                                          ).status_code, 404)

    def test_no_media_fields_on_session(self):
        from core.models import ShopLiveSession
        names = {f.name for f in ShopLiveSession._meta.get_fields()}
        for bad in ("video", "recording", "clip", "frames", "media"):
            self.assertFalse(any(bad in n for n in names), names)

    def test_turn_not_configured_is_honest(self):
        self._online()
        with override_settings(TURN_STATIC_SECRET=""):
            r = self._start()
        self.assertEqual(r.status_code, 201)
        self.assertFalse(r.data["turn_configured"])

    def test_relay_price_admin_editable(self):
        from core.logic import pricing
        from core import billing
        self.assertEqual(pricing.credit_cost("shop_live_relay_min", billing.cfg()), 1)
        self.assertEqual(pricing.validate_edit(pricing.DEFAULTS()), [])
