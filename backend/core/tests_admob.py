"""admob (owner 25 Oct): server side of the AdMob integration.

* /ads/config: Free only (Premium/Business: zero ads, every placement off),
  Google TEST unit ids until the owner turns `admob_real_ids` on, then the
  real ids; per-placement switches; caps (app-open 1 h + 6/day, interstitial
  5 min + daily cap); banner/interstitial allowlists the server can only
  narrow.
* Rewarded SSV: Google's ECDSA signature verified with the published key
  (here: a keypair generated in the test, injected as the verifier key);
  bad signature / unknown key / replayed transaction_id rejected; the reward
  is granted ONCE; no ticket for paid users or on test ids.
* POST /ads/event tuning log (impression / click / paid) + rate limit +
  Owner Admin table.
* app-ads.txt + legal pages (EN + BN) mention ads and the Advertising ID.
"""
import base64
from unittest import mock
from urllib.parse import urlencode

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from django.core.cache import cache
from django.test import Client, SimpleTestCase
from django.utils import timezone
from datetime import timedelta
from rest_framework.test import APITestCase

from core import admob_service as AS
from core import billing
from core import photo_studio_service as PSS
from core.logic import ads as A
from core.logic import pricing as P
from core.models import AdEvent, AdPlacementStat, PhotoAdTicket, User

OWNER_UNITS = {
    "app_open": "ca-app-pub-2506398550427515/1193237050",
    "rewarded": "ca-app-pub-2506398550427515/2426427676",
    "banner": "ca-app-pub-2506398550427515/4940910375",
    "interstitial": "ca-app-pub-2506398550427515/3547937658",
    "native": "ca-app-pub-2506398550427515/7259951959",
}
GOOGLE_TEST_UNITS = {
    "app_open": "ca-app-pub-3940256099942544/9257395921",
    "banner": "ca-app-pub-3940256099942544/6300978111",
    "interstitial": "ca-app-pub-3940256099942544/1033173712",
    "rewarded": "ca-app-pub-3940256099942544/5224354917",
    "native": "ca-app-pub-3940256099942544/2247696110",
}


def _cfg(**kw):
    base = dict(plan="free", paid=False, admob_cfg={}, admob_working=False,
                flag_rewarded=True, flag_app_open=True,
                ad_caps=P.DEFAULTS()["ad_rewards"])
    base.update(kw)
    return A.client_config(**base)


class ConfigPureTests(SimpleTestCase):
    def test_defaults_are_google_test_ids_and_owner_caps(self):
        c = _cfg()
        self.assertFalse(c["real_ids"])
        self.assertEqual(c["units"], GOOGLE_TEST_UNITS)
        self.assertTrue(c["ads_enabled"])
        self.assertEqual(c["appopen_min_gap_sec"], 10800)   # owner 26 Oct: 3 h
        self.assertEqual(c["appopen_daily_cap"], 6)
        self.assertEqual(c["interstitial_min_gap_sec"], 300)
        self.assertEqual(c["interstitial_daily_cap"], 6)
        self.assertGreaterEqual(c["appopen_min_bg_sec"], 5)
        self.assertEqual(c["banner_screens"], ["saved_items", "dictionary", "health_tips"])
        self.assertEqual(c["interstitial_moments"], ["photo_saved", "task_done"])
        self.assertEqual(c["native_screens"], ["home"])
        p = c["placements"]
        self.assertTrue(p["app_open"] and p["native_home"] and p["banner"] and p["interstitial"])
        # Google's SSV never verifies a test unit: no rewarded on test ids
        self.assertFalse(p["rewarded"])
        self.assertFalse(c["personalized"])

    def test_real_flag_serves_owner_ids_without_app_update(self):
        caps = dict(P.DEFAULTS()["ad_rewards"], admob_real_ids=True)
        c = _cfg(ad_caps=caps)
        self.assertTrue(c["real_ids"] and c["configured"])
        self.assertEqual(c["app_id"], "ca-app-pub-2506398550427515~5116255919")
        self.assertEqual(c["units"], OWNER_UNITS)
        self.assertTrue(c["placements"]["rewarded"])

    def test_valid_integration_ids_override_owner_ids(self):
        caps = dict(P.DEFAULTS()["ad_rewards"], admob_real_ids=True)
        cfg = {"app_id": "ca-app-pub-1111222233334444~1234567890",
               "banner_unit": "ca-app-pub-1111222233334444/1111111111"}
        c = _cfg(ad_caps=caps, admob_cfg=cfg, admob_working=True)
        self.assertEqual(c["app_id"], cfg["app_id"])
        self.assertEqual(c["units"]["banner"], cfg["banner_unit"])

    def test_premium_and_business_get_zero_ads(self):
        caps = dict(P.DEFAULTS()["ad_rewards"], admob_real_ids=True)
        for plan in ("premium", "business", "founder", "annual"):
            c = _cfg(plan=plan, paid=True, ad_caps=caps)
            self.assertFalse(c["ads_enabled"], plan)
            self.assertFalse(any(c["placements"].values()), plan)
            self.assertFalse(c["hero_enabled"], plan)
            self.assertEqual(c["banner_screens"], [], plan)
            self.assertEqual(c["interstitial_moments"], [], plan)

    def test_per_placement_switches_and_allowlist_narrowing(self):
        caps = dict(P.DEFAULTS()["ad_rewards"], place_banner=False, place_app_open=False,
                    interstitial_moments="task_done, vault, sos")
        c = _cfg(ad_caps=caps)
        self.assertFalse(c["placements"]["banner"])
        self.assertEqual(c["banner_screens"], [])
        self.assertFalse(c["app_open_enabled"])
        # the server can only narrow the app's list — never add sos/vault
        self.assertEqual(c["interstitial_moments"], ["task_done"])

    def test_pricing_bounds(self):
        n = P.normalize({"ad_rewards": {"interstitial_min_gap_sec": 10,
                                        "appopen_min_bg_sec": 0,
                                        "banner_screens": "sos,dictionary,login"}})["ad_rewards"]
        self.assertEqual(n["interstitial_min_gap_sec"], 300)
        self.assertEqual(n["appopen_min_bg_sec"], 5)
        self.assertEqual(n["banner_screens"], "dictionary")
        self.assertIn("bad_ad_cap", P.validate_edit({"ad_rewards": {"interstitial_min_gap_sec": 60}}))
        self.assertFalse(P.DEFAULTS()["ad_rewards"]["admob_real_ids"])

    def test_clean_event(self):
        ok, why = A.clean_event({"kind": "paid", "format": "banner", "placement": "banner_dictionary",
                                 "value_micros": 1500, "currency": "usd", "precision": "PRECISE"})
        self.assertIsNone(why)
        self.assertEqual((ok["currency"], ok["precision"]), ("USD", "precise"))
        for bad in ({"kind": "x", "format": "banner", "placement": "p1"},
                    {"kind": "impression", "format": "popup", "placement": "p1"},
                    {"kind": "impression", "format": "banner", "placement": "Bad Name!"},
                    {"kind": "paid", "format": "banner", "placement": "p1", "value_micros": -1,
                     "currency": "USD"},
                    {"kind": "paid", "format": "banner", "placement": "p1",
                     "value_micros": 10 ** 12, "currency": "USD"},
                    {"kind": "paid", "format": "banner", "placement": "p1", "value_micros": 5,
                     "currency": "dollars"}):
            self.assertIsNone(A.clean_event(bad)[0], bad)


class _Base(APITestCase):
    def mk(self, phone, plan="free"):
        u = User.objects.create_user(name="U" + phone[-2:], phone=phone, password="pw")
        u.plan = plan
        if plan != "free":
            u.plan_until = timezone.now() + timedelta(days=30)
        u.date_joined = timezone.now() - timedelta(days=5)
        u.save()
        return u

    def setUp(self):
        cache.clear()
        self.free = self.mk("01999100201")
        self.prem = self.mk("01999100202", "premium")
        self.biz = self.mk("01999100203", "business")

    def caps(self, **kw):
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, **kw)
        row.data = d
        row.save()


class ConfigApiTests(_Base):
    def test_free_gets_test_ids_paid_gets_nothing(self):
        self.client.force_authenticate(self.free)
        j = self.client.get("/api/v1/ads/config").json()
        self.assertTrue(j["ads_enabled"])
        self.assertFalse(j["real_ids"])
        self.assertEqual(j["units"]["native"], GOOGLE_TEST_UNITS["native"])
        self.assertTrue(j["placements"]["native_home"])
        for u in (self.prem, self.biz):
            self.client.force_authenticate(u)
            j = self.client.get("/api/v1/ads/config").json()
            self.assertFalse(j["ads_enabled"])
            self.assertTrue(j["paid"])
            self.assertFalse(any(j["placements"].values()))

    def test_real_flag_switches_units_server_side(self):
        self.caps(admob_real_ids=True)
        self.client.force_authenticate(self.free)
        j = self.client.get("/api/v1/ads/config").json()
        self.assertTrue(j["real_ids"])
        self.assertEqual(j["units"], OWNER_UNITS)


# ----------------------------------------------------------------- SSV
_KEY = ec.generate_private_key(ec.SECP256R1())
_PEM = _KEY.public_key().public_bytes(
    serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
_OTHER = ec.generate_private_key(ec.SECP256R1())
_KID = "3335741209"


def _ssv(nonce, user_id, txn, key=_KEY, kid=_KID, tamper=False):
    msg = urlencode([("ad_network", "5450213213286189855"), ("ad_unit", "2426427676"),
                     ("custom_data", nonce), ("reward_amount", "1"),
                     ("reward_item", "credit"), ("timestamp", "1761390000000"),
                     ("transaction_id", txn), ("user_id", user_id)])
    sig = key.sign(msg.encode(), ec.ECDSA(hashes.SHA256()))
    if tamper:
        msg = msg.replace("reward_amount=1", "reward_amount=99")
    return "%s&signature=%s&key_id=%s" % (
        msg, base64.urlsafe_b64encode(sig).decode().rstrip("="), kid)


class SsvTests(_Base):
    def setUp(self):
        super().setUp()
        k = mock.patch.object(PSS, "_ssv_keys", return_value={_KID: _PEM})
        self.keys = k.start()
        self.addCleanup(k.stop)
        # the wallet credits only with the AdMob integration linked
        e = mock.patch("core.integrations.is_enabled", side_effect=lambda s: s == "admob")
        e.start()
        self.addCleanup(e.stop)
        self.caps(admob_real_ids=True, ecpm_bdt=3000.0)

    def ticket(self, user=None):
        self.client.force_authenticate(user or self.free)
        return self.client.post("/api/v1/credits/rewarded/ticket", {}, format="json").json()

    def credited(self):
        return AdEvent.objects.filter(user=self.free, kind="rewarded",
                                      credited_paisa__gt=0).count()

    def test_valid_signature_rewards_once(self):
        t = self.ticket()
        self.assertTrue(t["ok"], t)
        self.assertEqual(t["custom_data"], t["nonce"])
        self.assertEqual(t["user_id"], str(self.free.pk))
        self.assertEqual(t["rewarded_unit"], OWNER_UNITS["rewarded"])
        r = Client().get("/api/v1/ads/ssv?" + _ssv(t["nonce"], str(self.free.pk), "txn-1"))
        self.assertEqual(r.status_code, 200)
        self.assertEqual(self.credited(), 1)
        self.assertEqual(PhotoAdTicket.objects.get(nonce=t["nonce"]).status, "verified")
        # the same callback again (Google retries / an attacker replays)
        Client().get("/api/v1/ads/ssv?" + _ssv(t["nonce"], str(self.free.pk), "txn-1"))
        self.assertEqual(self.credited(), 1)

    def test_replayed_transaction_on_a_new_ticket_rejected(self):
        t1 = self.ticket()
        Client().get("/api/v1/ads/ssv?" + _ssv(t1["nonce"], str(self.free.pk), "txn-9"))
        t2 = self.ticket()
        self.assertNotEqual(t1["nonce"], t2["nonce"])
        r = Client().get("/api/v1/ads/ssv?" + _ssv(t2["nonce"], str(self.free.pk), "txn-9"))
        self.assertEqual(r.json().get("ignored"), "replay")
        self.assertEqual(self.credited(), 1)
        self.assertEqual(PhotoAdTicket.objects.get(nonce=t2["nonce"]).status, "pending")

    def test_bad_signature_rejected(self):
        t = self.ticket()
        r = Client().get("/api/v1/ads/ssv?" + _ssv(t["nonce"], str(self.free.pk), "t2",
                                                    tamper=True))
        self.assertEqual(r.status_code, 403)
        r = Client().get("/api/v1/ads/ssv?" + _ssv(t["nonce"], str(self.free.pk), "t3",
                                                    key=_OTHER))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(self.credited(), 0)

    def test_unknown_key_rejected_after_one_refetch(self):
        t = self.ticket()
        r = Client().get("/api/v1/ads/ssv?" + _ssv(t["nonce"], str(self.free.pk), "t4",
                                                    key=_OTHER, kid="999"))
        self.assertEqual(r.status_code, 403)
        # the cache was refreshed once (forced) before giving up
        self.assertTrue(any(c.kwargs.get("force") or (c.args and c.args[0])
                            for c in self.keys.call_args_list))
        self.assertEqual(self.credited(), 0)

    def test_unsigned_and_wrong_user_rejected(self):
        t = self.ticket()
        self.assertEqual(Client().get("/api/v1/ads/ssv?custom_data=%s" % t["nonce"]).status_code,
                         400)
        Client().get("/api/v1/ads/ssv?" + _ssv(t["nonce"], str(self.prem.pk), "t5"))
        self.assertEqual(self.credited(), 0)

    def test_no_ticket_for_paid_plans_or_on_test_ids(self):
        for u in (self.prem, self.biz):
            self.assertEqual(self.ticket(u)["reason"], "paid_plan")
        self.caps(admob_real_ids=False)
        self.assertEqual(self.ticket()["reason"], "ads_not_configured")
        self.assertFalse(PhotoAdTicket.objects.filter(placement="credits").exists())


# ----------------------------------------------------------------- events
class EventLogTests(_Base):
    def post(self, user=None, **d):
        self.client.force_authenticate(user or self.free)
        return self.client.post("/api/v1/ads/event", d, format="json")

    def test_impression_click_paid_aggregate_per_placement(self):
        for _ in range(3):
            self.assertEqual(self.post(kind="impression", format="banner",
                                       placement="banner_dictionary").status_code, 200)
        self.post(kind="click", format="banner", placement="banner_dictionary")
        self.post(kind="paid", format="banner", placement="banner_dictionary",
                  value_micros=2500, currency="USD", precision="precise")
        self.post(kind="paid", format="banner", placement="banner_dictionary",
                  value_micros=500, currency="USD", precision="estimated")
        rows = AdPlacementStat.objects.filter(placement="banner_dictionary")
        self.assertEqual(sum(r.impressions for r in rows), 3)
        self.assertEqual(sum(r.clicks for r in rows), 1)
        paid = rows.get(currency="USD")
        self.assertEqual((paid.paid_events, paid.revenue_micros, paid.precise_events),
                         (2, 3000, 1))
        rep = AS.placement_stats(7)
        self.assertEqual(rep[0]["placement"], "banner_dictionary")
        self.assertEqual(rep[0]["impressions"], 3)
        self.assertEqual(rep[0]["revenue_text"], "USD 0.00")
        self.assertEqual(rep[0]["ctr_pct"], 33.33)

    def test_bad_events_and_paid_users_refused(self):
        self.assertEqual(self.post(kind="impression", format="popup",
                                   placement="x1").status_code, 400)
        r = self.post(user=self.prem, kind="impression", format="banner", placement="banner_x")
        self.assertEqual(r.json()["reason"], "not_free")
        self.assertFalse(AdPlacementStat.objects.exists())

    def test_rate_limited(self):
        with mock.patch.object(AS, "RATE_PER_HOUR", 3):
            codes = [self.post(kind="impression", format="native",
                               placement="home_native").status_code for _ in range(5)]
        self.assertEqual(codes, [200, 200, 200, 429, 429])
        self.assertEqual(AdPlacementStat.objects.get(placement="home_native").impressions, 3)

    def test_impression_of_test_ad_credits_nothing(self):
        e = mock.patch("core.integrations.is_enabled", side_effect=lambda s: s == "admob")
        e.start()
        self.addCleanup(e.stop)
        r = self.post(kind="impression", format="app_open", placement="app_open").json()
        self.assertTrue(r["ok"])
        self.assertEqual(r["wallet"]["reason"], "ads_not_configured")
        self.assertEqual(AdEvent.objects.filter(credited_paisa__gt=0).count(), 0)

    def test_legacy_kind_still_works(self):
        r = self.post(kind="rewarded").json()
        self.assertEqual(r["reason"], "ssv_required")


# ----------------------------------------------------------------- web
class PublicPagesTests(SimpleTestCase):
    databases = "__all__"

    def test_app_ads_txt(self):
        r = Client().get("/app-ads.txt")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r["Content-Type"].startswith("text/plain"))
        self.assertIn("google.com, pub-2506398550427515, DIRECT, f08c47fec0942fa0",
                      r.content.decode())

    def test_privacy_mentions_ads_and_advertising_id_en_bn(self):
        en = Client().get("/privacy?lang=en").content.decode()
        for s in ("Google AdMob", "Advertising ID", "com.google.android.gms.permission.AD_ID",
                  "Premium and Business plans have no ads", "non-personalised",
                  "Personalised vs non-personalised", "UMP", "US states",
                  "Ad privacy choices", "Android Settings → Privacy → Ads", "2026-10-26"):
            self.assertIn(s, en.replace("&#x27;", "'"), s)
        self.assertNotIn("shows no ads today", en)
        bn = Client().get("/privacy").content.decode()
        for s in ("Google AdMob", "Advertising ID", "প্রিমিয়াম ও বিজনেস প্ল্যানে কোনো বিজ্ঞাপন নেই",
                  "নন-পার্সোনালাইজড", "পার্সোনালাইজড বনাম নন-পার্সোনালাইজড",
                  "বিজ্ঞাপনের গোপনীয়তা"):
            self.assertIn(s, bn, s)
        self.assertNotIn("এখন অ্যাপে কোনো বিজ্ঞাপন নেই", bn)

    def test_in_app_legal_privacy_en_bn(self):
        en = Client().get("/api/v1/legal/privacy", HTTP_ACCEPT_LANGUAGE="en").json()
        body = en["body"] if isinstance(en.get("body"), str) else str(en)
        self.assertIn("Advertising ID", body)
        self.assertIn("Google AdMob", body)
        self.assertNotIn("contains no advertising SDK", body)
        self.assertEqual(en.get("last_updated", "2026-10-26"), "2026-10-26")
        bn = Client().get("/api/v1/legal/privacy", HTTP_ACCEPT_LANGUAGE="bn").json()
        body = bn["body"] if isinstance(bn.get("body"), str) else str(bn)
        self.assertIn("Advertising ID", body)
        self.assertIn("প্রিমিয়াম ও বিজনেসে কোনো", body)


# ----------------------------------------------------------------- owner admin
from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class OwnerAdsPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def test_switches_and_placement_table_en_bn(self):
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="home_native",
                                       fmt="native", impressions=12, clicks=1)
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="home_native",
                                       fmt="native", currency="USD", paid_events=12,
                                       revenue_micros=4200000)
        en = self.c.get("/owner/ads?lang=en").content.decode()
        for s in ("Serve REAL AdMob unit ids", 'name="ad_rewards.admob_real_ids"',
                  'name="ad_rewards.banner_screens"', "Ads by placement", "home_native",
                  "USD 4.20", "Home native ad card"):
            self.assertIn(s, en, s)
        bn = self.c.get("/owner/ads?lang=bn&days=30").content.decode()
        for s in ("আসল AdMob ইউনিট আইডি", "জায়গা অনুযায়ী বিজ্ঞাপন", "১২", "৩০"):
            self.assertIn(s, bn, s)

    def test_owner_turns_real_ids_on(self):
        cfg = billing.cfg()
        data = {"action": "settings", "reason": "AdMob approved"}
        for k, v in cfg["ad_rewards"].items():
            if isinstance(v, bool):
                if v:
                    data["ad_rewards." + k] = "on"
            elif isinstance(v, (int, float, str)):
                data["ad_rewards." + k] = str(v)
        data["ad_rewards.admob_real_ids"] = "on"
        data["ad_rewards.banner_screens"] = "dictionary, sos"
        r = self.post("/owner/ads", data)
        self.assertEqual(r.status_code, 302, r.content[:400])
        c = billing.cfg()["ad_rewards"]
        self.assertTrue(c["admob_real_ids"])
        self.assertEqual(c["banner_screens"], "dictionary")
