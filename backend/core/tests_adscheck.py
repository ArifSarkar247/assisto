"""Owner ads check (28 Oct).

1. AdMob tuning-log counting: per ad instance (`ad_event_id`) one
   impression / one click / one paid; a click only after that instance's
   impression; old builds (no id): one click per placement per minute; a
   placement's clicks never exceed its impressions. The reported bug
   ("interstitial_photo_saved: 2 impressions, 3 clicks") is replayed.
   Sponsored (direct) cards: a click without an impression is not counted.
2. Placement -> screen map (server copy): no banner key, interstitial moment
   or rewarded screen is an ad-free screen; banner "money" is the tracker.
3. Rewarded 0.70 profit table (owner_actions/ADS_PROFIT_BN.md) recomputed.
4. Brand-offer notifications are OPT-IN only (default OFF, explicit switch,
   server-enforced, Bangla explanation served).
5. Nothing rewards viewing a NON-rewarded ad or clicking any ad.
"""
import importlib
import re
from datetime import timedelta
from pathlib import Path
from unittest import mock

from django.apps import apps as django_apps
from django.core.cache import cache
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import admob_service as AS
from core import billing
from core import sponsor_service as SS
from core.logic import ads as A
from core.logic import pricing_40 as P40
from core.models import (AdEvent, AdEventSeen, AdPlacementStat, OfferPrefs, Sponsor,
                         SponsorCampaign, SponsorDailyStat, User)

PL = "interstitial_photo_saved"


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
        self.free = self.mk("01999300101")
        self.prem = self.mk("01999300102", "premium")

    def post(self, **d):
        self.client.force_authenticate(self.free)
        return self.client.post("/api/v1/ads/event", d, format="json").json()

    def row(self, placement=PL):
        rows = AdPlacementStat.objects.filter(placement=placement, currency="")
        return (sum(r.impressions for r in rows), sum(r.clicks for r in rows))


# ------------------------------------------------------------ 1. counting
class CountingTests(_Base):
    def ev(self, kind, eid=None, placement=PL, fmt="interstitial", **kw):
        d = dict(kind=kind, format=fmt, placement=placement, **kw)
        if eid:
            d["ad_event_id"] = eid
        return self.post(**d)

    def test_reported_bug_replayed_clicks_never_exceed_impressions(self):
        # two interstitials; old client: impression via onAdShowed AND
        # onAdImpression, three onAdClicked on the first ad (repeat taps)
        for eid in ("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb"):
            self.assertTrue(self.ev("impression", eid)["counted"])
            self.assertFalse(self.ev("impression", eid)["counted"])
        r = [self.ev("click", "aaaaaaaaaaaaaaaa") for _ in range(3)]
        self.assertEqual([x["counted"] for x in r], [True, False, False])
        self.assertEqual(r[1]["reason"], "duplicate")
        self.assertEqual(self.row(), (2, 1))

    def test_click_without_its_impression_not_counted(self):
        self.ev("impression", "aaaaaaaaaaaaaaaa")
        r = self.ev("click", "cccccccccccccccc")
        self.assertFalse(r["counted"])
        self.assertEqual(r["reason"], "click_without_impression")
        self.assertEqual(self.row(), (1, 0))

    def test_legacy_clicks_one_per_minute_and_capped_by_impressions(self):
        r = self.ev("click")                              # no impression at all
        self.assertEqual(r["reason"], "clicks_capped")
        self.assertEqual(self.row(), (0, 0))
        AdEventSeen.objects.all().delete()
        self.ev("impression")
        self.ev("impression")
        self.assertTrue(self.ev("click")["counted"])
        self.assertEqual(self.ev("click")["reason"], "duplicate")   # same minute
        self.assertEqual(self.row(), (2, 1))
        AdEventSeen.objects.all().delete()               # = the next minute
        self.assertTrue(self.ev("click")["counted"])
        AdEventSeen.objects.all().delete()
        # a 3rd click with only 2 impressions: refused by the conditional update
        self.assertEqual(self.ev("click")["reason"], "clicks_capped")
        self.assertEqual(self.row(), (2, 2))

    def test_every_format_deduped(self):
        for fmt, pl in (("banner", "banner_money"), ("native", "home_native"),
                        ("app_open", "app_open"), ("rewarded", "rewarded_credits"),
                        ("interstitial", "interstitial_task_done")):
            eid = ("%s0000000000" % fmt)[:16].replace("_", "x")
            for _ in range(3):
                self.ev("impression", eid, placement=pl, fmt=fmt)
                self.ev("click", eid, placement=pl, fmt=fmt)
                self.ev("paid", eid, placement=pl, fmt=fmt, value_micros=1000,
                        currency="USD", precision="precise")
            self.assertEqual(self.row(pl), (1, 1), fmt)
            paid = AdPlacementStat.objects.get(placement=pl, currency="USD")
            self.assertEqual((paid.paid_events, paid.revenue_micros), (1, 1000), fmt)

    def test_dedupe_is_per_user(self):
        other = self.mk("01999300103")
        self.ev("impression", "aaaaaaaaaaaaaaaa")
        self.client.force_authenticate(other)
        r = self.client.post("/api/v1/ads/event", dict(
            kind="impression", format="interstitial", placement=PL,
            ad_event_id="aaaaaaaaaaaaaaaa"), format="json").json()
        self.assertTrue(r["counted"])
        self.assertEqual(self.row(), (2, 0))

    def test_bad_event_id_treated_as_legacy(self):
        self.assertEqual(A.clean_event_id("short"), "")
        self.assertEqual(A.clean_event_id("x" * 65), "")
        self.assertEqual(A.clean_event_id("a1b2c3d4e5f60718"), "a1b2c3d4e5f60718")
        self.assertEqual(A.clean_event_id("a b c d e f g h"), "")

    def test_duplicate_impression_never_reaches_the_wallet_path(self):
        with mock.patch.object(billing, "ad_event", return_value={"ok": True}) as m:
            self.ev("impression", "dddddddddddddddd")
            self.ev("impression", "dddddddddddddddd")
        self.assertEqual(m.call_count, 1)

    def test_dedupe_rows_hold_no_readable_ids_and_are_purged(self):
        self.ev("impression", "eeeeeeeeeeeeeeee")
        k = AdEventSeen.objects.get().key
        self.assertRegex(k, r"^[0-9a-f]{64}$")
        self.assertNotIn(str(self.free.pk) + "|", k)
        AdEventSeen.objects.update(at=timezone.now() - timedelta(days=3))
        AS._purge_old(timezone.now(), odds=1.0)          # never patch random globally
        self.assertEqual(AdEventSeen.objects.count(), 0)
        self.ev("impression", "ffffffffffffffff")
        self.assertEqual(AdEventSeen.objects.count(), 1)


class SponsoredClickTests(_Base):
    def test_sponsored_click_needs_an_impression(self):
        sp = Sponsor.objects.create(name="Brand A", category="mobile")
        now = timezone.now()
        c = SponsorCampaign.objects.create(
            sponsor=sp, name="C", placement="app_open", status="approved", pricing="flat",
            price_bdt=1000, title_bn="অফার", title_en="Offer", body_bn="ভালো",
            body_en="Good", link_url="https://example.com",
            start_at=now - timedelta(days=1), end_at=now + timedelta(days=9))
        self.client.force_authenticate(self.free)
        r = self.client.get("/api/v1/ads/slot?placement=app_open&screen=home").json()
        tok = r["creative"]["token"]
        self.assertFalse(SS.record_event(self.free, tok, "click")["counted"])
        self.assertTrue(SS.record_event(self.free, tok, "impression")["counted"])
        self.assertTrue(SS.record_event(self.free, tok, "click")["counted"])
        self.assertFalse(SS.record_event(self.free, tok, "click")["counted"])
        st = SponsorDailyStat.objects.get(campaign=c)
        self.assertEqual((st.impressions, st.clicks), (1, 1))


# ------------------------------------------------------- 2. placement map
class PlacementMapTests(SimpleTestCase):
    FORBIDDEN = re.compile(
        r"pay|checkout|paywall|plans|credit|topup|top_up|refund|purchase|billing|"
        r"sos|safety|safe|journey|fall|theft|lost|alarm|call|chat|conversation|"
        r"login|otp|signup|sign_up|password|permission|onboarding|language")

    def test_no_ad_free_screen_in_any_server_list(self):
        for s in A.BANNER_SCREENS:
            self.assertFalse(A.is_blocked_screen(s), s)
            if s == "circle_list":      # the owner-approved Chats LIST banner
                continue
            self.assertIsNone(self.FORBIDDEN.search(s), s)
        for s in A.NATIVE_SCREENS + A.APP_OPEN_SCREENS:
            self.assertEqual(s, "home")
        for s in A.INTERSTITIAL_MOMENTS:
            self.assertIsNone(self.FORBIDDEN.search(s), s)

    def test_money_banner_is_not_a_payment_screen(self):
        self.assertIn("money", A.BANNER_SCREENS)
        for s in ("payment", "checkout", "topup", "credits_topup", "plans",
                  "payment_ladder", "business_plans", "remittance"):
            self.assertTrue(A.is_blocked_screen(s), s)
            self.assertNotIn(s, A.BANNER_SCREENS)

    def test_circle_list_only_never_a_conversation_or_call(self):
        self.assertIn("circle_list", A.BANNER_SCREENS)
        for s in ("circle_chat", "chat_conversation", "group_chat", "messenger_chat",
                  "circle_call", "in_call", "incoming_call", "call_log"):
            self.assertTrue(A.is_blocked_screen(s), s)

    def test_server_cannot_be_talked_into_a_forbidden_banner(self):
        caps = {"banner_screens": "money,payment,checkout,circle_chat,sos,login,permission"}
        c = A.client_config(plan="free", paid=False, admob_cfg={}, admob_working=False,
                            flag_rewarded=True, flag_app_open=True, ad_caps=caps)
        self.assertEqual(c["banner_screens"], ["money"])


# ------------------------------------------------------- 3. profit table
# owner_actions/ADS_PROFIT_BN.md — the numbers recomputed here.
USD_BDT = 125.0
SAFE_COST_PER_CREDIT = 0.63          # ৳, the 40 % ceiling per consumed credit
FLOOR_ECPM_BDT = 30.0                # PricingConfig ad_rewards.ecpm_bdt default
SHARE = 0.70


def rewarded_row(ecpm_usd, floor_bdt=FLOOR_ECPM_BDT, share=SHARE,
                 cost_per_credit=SAFE_COST_PER_CREDIT, usd_bdt=USD_BDT):
    revenue = ecpm_usd * usd_bdt / 1000.0                 # ৳ per rewarded view
    credits = floor_bdt / 1000.0 * share                  # credits (৳1 face) per view
    cost = credits * cost_per_credit                       # worst-case AI cost
    margin = (revenue - cost) / revenue if revenue else -1
    return revenue, credits, cost, margin


class RewardedProfitTests(SimpleTestCase):
    def test_worst_case_credit_cost_within_safe_ceiling(self):
        worst = max(P40.v2_per_credit_usd(m) for m in ("smart", "pro", "agent")) * USD_BDT
        self.assertLessEqual(worst, SAFE_COST_PER_CREDIT)

    def test_share_is_capped_at_070(self):
        from core.logic import pricing as P
        n = P.normalize({"ad_rewards": {"revenue_share": 0.95}})
        self.assertLessEqual(n["ad_rewards"]["revenue_share"], 0.70)

    def test_low_mid_high_ecpm_keep_40pct(self):
        for ecpm_usd in (0.30, 1.00, 3.00):
            _, _, _, m = rewarded_row(ecpm_usd)
            self.assertGreaterEqual(m, 0.40, ecpm_usd)

    def test_break_point(self):
        # margin >= 40 % <=> revenue >= cost / 0.6
        brk_bdt = FLOOR_ECPM_BDT * SHARE * SAFE_COST_PER_CREDIT / 0.6
        self.assertAlmostEqual(brk_bdt, 22.05, places=2)
        self.assertLess(rewarded_row(brk_bdt / USD_BDT - 0.001)[3], 0.40)
        self.assertGreaterEqual(rewarded_row(brk_bdt / USD_BDT + 0.001)[3], 0.40)

    def test_photo_unlock_not_a_credit_grant(self):
        # Photo Studio rewarded ads fund a job (value booked as ad revenue);
        # only placement "credits" grants credits — through ad_event(verified)
        src = Path(__file__).with_name("photo_studio_service.py").read_text()
        self.assertIn('billing.ad_event(t.user, "rewarded"', src)
        self.assertEqual(src.count("billing.ad_event("), 1)


# ------------------------------------------------- 4. offers opt-in only
class OfferOptInTests(_Base):
    def test_default_off_with_bangla_explanation(self):
        self.client.force_authenticate(self.free)
        j = self.client.get("/api/v1/offers/prefs").json()
        self.assertFalse(j["notifs_on"])
        self.assertTrue(j["notifs_opt_in"])
        self.assertIn("বন্ধ থাকলে", j["notifs_note"]["bn"])
        self.assertIn("default", j["notifs_note"]["en"])
        # saving categories never switches notifications on
        j = self.client.post("/api/v1/offers/prefs", {"categories": ["mobile"],
                                                       "onboarding_done": True},
                             format="json").json()
        self.assertFalse(j["notifs_on"])
        self.assertFalse(OfferPrefs.objects.get(user=self.free).notifs_on)

    def test_only_an_explicit_true_opts_in_and_off_clears_it(self):
        self.client.force_authenticate(self.free)
        for junk in ("true", 1, "yes"):
            j = self.client.post("/api/v1/offers/prefs", {"notifs_on": junk},
                                 format="json").json()
            self.assertFalse(j["notifs_on"], junk)
        j = self.client.post("/api/v1/offers/prefs", {"notifs_on": True}, format="json").json()
        self.assertTrue(j["notifs_on"])
        self.assertIsNotNone(OfferPrefs.objects.get(user=self.free).notifs_opted_in_at)
        j = self.client.post("/api/v1/offers/prefs", {"notifs_on": False}, format="json").json()
        self.assertFalse(j["notifs_on"])
        self.assertIsNone(OfferPrefs.objects.get(user=self.free).notifs_opted_in_at)

    def test_sender_skips_everyone_who_did_not_opt_in(self):
        sp = Sponsor.objects.create(name="Brand B", category="mobile")
        now = timezone.now()
        c = SponsorCampaign.objects.create(
            sponsor=sp, name="O", placement="brand_offer", status="approved", pricing="flat",
            price_bdt=1000, title_bn="অফার", title_en="Offer", body_bn="ভালো",
            body_en="Good", link_url="https://example.com", categories=["mobile"],
            start_at=now - timedelta(days=1), end_at=now + timedelta(days=9))
        # an old row: notifs_on True by the OLD default, never an opt-in
        OfferPrefs.objects.create(user=self.free, categories=["mobile"], notifs_on=True)
        with mock.patch("core.push.push_to_user_async", return_value=True) as push:
            self.assertEqual(SS.send_offer_notifications(c)["sent"], 0)
        push.assert_not_called()
        OfferPrefs.objects.filter(user=self.free).update(notifs_opted_in_at=now)
        with mock.patch("core.push.push_to_user_async", return_value=True):
            self.assertEqual(SS.send_offer_notifications(c)["sent"], 1)

    def test_migration_switches_old_default_rows_off(self):
        OfferPrefs.objects.create(user=self.free, notifs_on=True)
        OfferPrefs.objects.create(user=self.prem, notifs_on=True,
                                  notifs_opted_in_at=timezone.now())
        mig = importlib.import_module("core.migrations.0117_adscheck")
        mig.offers_opt_in_only(django_apps, None)
        self.assertFalse(OfferPrefs.objects.get(user=self.free).notifs_on)
        self.assertTrue(OfferPrefs.objects.get(user=self.prem).notifs_on)

    def test_model_default_is_off(self):
        self.assertFalse(OfferPrefs._meta.get_field("notifs_on").default)


# ------------------------------------- 5. no reward for viewing / clicking
class NoIncentiveTests(_Base):
    def _admob_live(self):
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, admob_real_ids=True,
                               ecpm_bdt=3000.0)
        row.data = d
        row.save()
        for p in (mock.patch("core.integrations.is_enabled", return_value=True),
                  mock.patch.object(billing, "flag_on", return_value=True)):
            p.start()
            self.addCleanup(p.stop)

    def test_non_rewarded_impressions_never_credit(self):
        self._admob_live()
        for kind in ("app_open", "interstitial", "native"):
            r = billing.ad_event(self.free, kind, device_id="D-%s" % kind)
            self.assertTrue(r["ok"], kind)
            self.assertEqual(r["reason"], "not_rewarded_format", kind)
            self.assertEqual(r["credited_credits"], 0, kind)
        self.free.refresh_from_db()
        self.assertEqual(self.free.ai_credits or 0, 0)
        self.assertEqual(billing.ad_wallet_credits(self.free), 0)
        self.assertFalse(AdEvent.objects.filter(credited_paisa__gt=0).exists())

    def test_only_a_verified_rewarded_view_credits(self):
        self._admob_live()
        self.assertEqual(billing.ad_event(self.free, "rewarded")["reason"], "ssv_required")
        self.assertTrue(billing.ad_event(self.free, "rewarded", verified=True)["ok"])
        self.assertGreater(billing.ad_wallet_credits(self.free), 0)

    def test_clicks_never_reach_any_credit_path(self):
        self._admob_live()
        # a plain dict: a bare MagicMock here once made DRF's encoder loop
        # for ever (.tolist() -> new mock -> ...) and ate 5 GB
        with mock.patch.object(billing, "ad_event",
                               return_value={"ok": True, "reason": "ok"}) as m:
            self.post(kind="impression", format="interstitial", placement=PL,
                      ad_event_id="1111111111111111")
            self.post(kind="click", format="interstitial", placement=PL,
                      ad_event_id="1111111111111111")
        self.assertEqual(m.call_count, 1)                 # the impression only
        src = Path(__file__).with_name("views_build61.py").read_text()
        self.assertIn('kind == "impression"', src)

    def test_wallet_result_of_any_shape_is_safe_to_render(self):
        """Regression guard (5 GB runaway): whatever ad_event returns, the
        /ads/event response holds only plain JSON scalars and renders."""
        from core import views_build61 as V
        self.assertIsNone(V._json_scalar(mock.MagicMock()))
        self.assertIsNone(V._json_scalar(object()))
        self.assertEqual(V._json_scalar("ok"), "ok")
        for bad in (mock.MagicMock(), None, ["x"], {"ok": mock.MagicMock(), "reason": 3}):
            AdEventSeen.objects.all().delete()
            with mock.patch.object(billing, "ad_event", return_value=bad):
                r = self.post(kind="impression", format="native", placement="home_native",
                              ad_event_id="2222222222222222")
            self.assertTrue(r["ok"], bad)
            for v in (r.get("wallet") or {}).values():
                self.assertIn(type(v), (type(None), bool, int, float, str))

    def test_no_test_uses_a_bare_mock_for_ad_event(self):
        src = Path(__file__).read_text()
        self.assertNotIn("patch.object(billing, " + '"ad_event") as', src)

    def test_server_copy_never_asks_for_ad_clicks(self):
        en = re.compile(r"(click|tap)\w*\s+(on\s+)?(the\s+|an\s+)?(ad|ads|banner)\b"
                        r"|(click|tap)\w*\s+to\s+(earn|win)", re.I)
        bn = re.compile(r"(বিজ্ঞাপন|অ্যাড|ব্যানার)\S*\s*(এ|তে)?\s*(ক্লিক|ট্যাপ)"
                        r"|(ক্লিক|ট্যাপ)\s*(করুন|করে|করলে)\s*.{0,20}"
                        r"((ক্রেডিট|পুরস্কার|বোনাস)\s*(পান|নিন|পাবেন)|জিতুন)")
        here = Path(__file__).resolve().parent
        files = [here / "sponsor_service.py", here / "billing.py", here / "legal.py",
                 here.parent / "web" / "owner" / "i18n.py",
                 here.parent / "web" / "legal_content.py"]
        bad = []
        for f in files:
            for i, line in enumerate(f.read_text().splitlines(), 1):
                if en.search(line) or bn.search(line):
                    bad.append("%s:%d %s" % (f.name, i, line.strip()))
        self.assertEqual(bad, [])
