"""p2-money: app-open caps + day-2 rule, never-on-sensitive screens/entries,
Free-only, direct-first slot priority, community sponsored post threshold,
brand offers (notif cap, mute, notifs off, Premium flag), SSV-only rewarded
credits, 3-day trial once, annual discount clamp, report math, owner admin."""
import base64
from datetime import date, datetime, timedelta, timezone as dt_timezone
from unittest import mock
from urllib.parse import urlencode

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import billing, plans
from core import photo_studio_service as PSS
from core import sponsor_service as SS
from core.logic import pricing as P
from core.logic import sponsor as SP
from core.models import (AdEvent, AdExposure, NotifEvent, OfferNotifLog, OfferPrefs,
                         PhotoAdTicket, Sponsor, SponsorCampaign, SponsorDailyStat, User)

REAL_APP = "ca-app-pub-1234567890123456~1234567890"
REAL_REW = "ca-app-pub-1234567890123456/1111111111"
CAPS = P.DEFAULTS()["ad_rewards"]
UTC = dt_timezone.utc


def _dt(*a):
    return datetime(*a, tzinfo=UTC)


# ======================================================================= pure
class AppOpenRuleTests(SimpleTestCase):
    def dec(self, **kw):
        base = dict(paid=False, flag_on=True, caps=CAPS, date_joined_local=date(2026, 10, 1),
                    today_local=date(2026, 10, 2), shown_today=0, last_shown_at=None,
                    now=_dt(2026, 10, 2, 12), screen="home", entry="")
        base.update(kw)
        return SP.appopen_decision(**base)

    def test_owner_defaults(self):
        # admob (owner 25 Oct): max 6 a day, at most once per hour
        self.assertEqual(CAPS["appopen_daily_cap"], 6)
        self.assertEqual(CAPS["appopen_min_gap_sec"], 10800)   # owner 26 Oct: 3 h
        self.assertEqual(CAPS["appopen_start_day"], 2)
        self.assertEqual(CAPS["appopen_skip_after_s"], 5)
        self.assertEqual(SP.skip_after_s(CAPS), 5)

    def test_day2_rule(self):
        self.assertEqual(self.dec(today_local=date(2026, 10, 1)), (False, "too_new"))
        self.assertEqual(self.dec(), (True, "ok"))

    def test_daily_cap_and_gap(self):
        self.assertEqual(self.dec(shown_today=6), (False, "daily_cap"))
        self.assertEqual(self.dec(shown_today=5), (True, "ok"))
        self.assertEqual(self.dec(last_shown_at=_dt(2026, 10, 2, 9, 30)), (False, "too_soon"))
        self.assertEqual(self.dec(last_shown_at=_dt(2026, 10, 2, 8, 59)), (True, "ok"))

    def test_free_only_and_switch(self):
        self.assertEqual(self.dec(paid=True), (False, "paid_plan"))
        self.assertEqual(self.dec(flag_on=False), (False, "disabled"))
        self.assertEqual(self.dec(caps=dict(CAPS, appopen_daily_cap=0)), (False, "disabled"))

    def test_never_on_sensitive_screens(self):
        for s in ("sos", "voice_sos", "safety", "emergency", "payment", "checkout",
                  "plans", "topup", "login", "otp", "signup", "call", "circle_call",
                  "incoming_call", "lost_stolen", "journey", "", "unknown", "chat"):
            ok, why = self.dec(screen=s)
            self.assertFalse(ok, s)
            self.assertEqual(why, "blocked_screen", s)

    def test_never_from_notification_or_deeplink(self):
        for e in ("notification", "deeplink", "call", "sos", "widget", "assist", "share"):
            self.assertEqual(self.dec(entry=e), (False, "blocked_entry"), e)
        self.assertEqual(self.dec(entry="cold_start"), (True, "ok"))

    def test_bounds_clamp(self):
        n = P.normalize({"ad_rewards": {"appopen_daily_cap": 99, "appopen_skip_after_s": 1,
                                        "appopen_start_day": 0,
                                        "appopen_min_gap_sec": 5}})["ad_rewards"]
        self.assertEqual((n["appopen_daily_cap"], n["appopen_skip_after_s"],
                          n["appopen_start_day"], n["appopen_min_gap_sec"]), (6, 5, 1, 10800))
        self.assertIn("bad_ad_cap", P.validate_edit({"ad_rewards": {"appopen_daily_cap": 50}}))
        self.assertIn("bad_ad_cap", P.validate_edit({"ad_rewards": {"offer_notif_daily_cap": 9}}))
        self.assertEqual(P.validate_edit({"ad_rewards": {"appopen_daily_cap": 4,
                                                         "offer_notif_daily_cap": 1}}), [])


class SlotPriorityTests(SimpleTestCase):
    now = _dt(2026, 10, 10, 12)

    def camp(self, **kw):
        c = dict(id=1, sponsor_id=1, placement="hero", status="approved", pricing="flat",
                 price_bdt=1000, budget_bdt=0, start_at=_dt(2026, 10, 1), end_at=_dt(2026, 10, 30),
                 categories=[], divisions=[], daily_imp_cap=0, priority=0,
                 sponsor_active=True, total_impressions=0)
        c.update(kw)
        return c

    user = {"paid": False, "categories": [], "brands": [], "muted_brands": [],
            "hidden_campaigns": [], "division": ""}

    def test_direct_first_admob_fills(self):
        self.assertEqual(SP.slot_source({"id": 1}, True), "direct")
        self.assertEqual(SP.slot_source(None, True), "admob")
        self.assertEqual(SP.slot_source(None, False), "none")

    def test_free_only_mute_hide_window(self):
        c = self.camp()
        self.assertEqual(SP.pick_campaign([c], "hero", self.user, self.now)["id"], 1)
        self.assertIsNone(SP.pick_campaign([c], "hero", dict(self.user, paid=True), self.now))
        self.assertIsNone(SP.pick_campaign([c], "hero", dict(self.user, muted_brands=[1]), self.now))
        self.assertIsNone(SP.pick_campaign([c], "hero", dict(self.user, hidden_campaigns=[1]), self.now))
        self.assertIsNone(SP.pick_campaign([self.camp(status="draft")], "hero", self.user, self.now))
        self.assertIsNone(SP.pick_campaign([self.camp(end_at=_dt(2026, 10, 5))], "hero",
                                           self.user, self.now))
        self.assertIsNone(SP.pick_campaign([c], "app_open", self.user, self.now))

    def test_interest_then_priority(self):
        a = self.camp(id=1, priority=5)
        b = self.camp(id=2, sponsor_id=2, categories=["mobile"])
        self.assertEqual(SP.pick_campaign([a, b], "hero", self.user, self.now)["id"], 1)
        u = dict(self.user, categories=["mobile"])
        self.assertEqual(SP.pick_campaign([a, b], "hero", u, self.now)["id"], 2)

    def test_division_and_pacing(self):
        c = self.camp(divisions=["sylhet"])
        self.assertIsNone(SP.pick_campaign([c], "hero", self.user, self.now))
        self.assertEqual(SP.pick_campaign([c], "hero", dict(self.user, division="sylhet"),
                                          self.now)["id"], 1)
        capped = self.camp(daily_imp_cap=10)
        self.assertIsNone(SP.pick_campaign([capped], "hero", self.user, self.now, {1: 10}))
        cpm = self.camp(pricing="cpm", price_bdt=100, budget_bdt=100, total_impressions=1000)
        self.assertIsNone(SP.pick_campaign([cpm], "hero", self.user, self.now))

    def test_community_threshold(self):
        ok = dict(paid=False, enabled=True, member_count=500, threshold=500,
                  shown_today=0, daily_cap=6)
        self.assertEqual(SP.community_post_ok(**ok), (True, "ok"))
        self.assertEqual(SP.community_post_ok(**dict(ok, member_count=499)), (False, "too_small"))
        self.assertEqual(SP.community_post_ok(**dict(ok, paid=True)), (False, "paid_plan"))
        self.assertEqual(SP.community_post_ok(**dict(ok, shown_today=6)), (False, "daily_cap"))
        self.assertEqual(SP.community_post_ok(**dict(ok, is_admin=True)), (False, "own_space"))


class MoneyMathTests(SimpleTestCase):
    def test_flat_spread_and_cpm(self):
        c = {"pricing": "flat", "price_bdt": 1000, "start_at": _dt(2026, 10, 1, 0),
             "end_at": _dt(2026, 10, 11, 0)}
        rev = SP.revenue_by_day(c, {}, lambda d: d.date())
        self.assertEqual(len(rev), 10)
        self.assertAlmostEqual(sum(rev.values()), 1000, places=1)
        cpm = {"pricing": "cpm", "price_bdt": 50, "budget_bdt": 60}
        r = SP.revenue_by_day(cpm, {date(2026, 10, 1): 1000, date(2026, 10, 2): 1000}, None)
        self.assertEqual(r[date(2026, 10, 1)], 50.0)
        self.assertEqual(r[date(2026, 10, 2)], 10.0)          # budget clamp
        self.assertEqual(SP.cpm_impression_cap(50, 60), 1200)

    def test_report_rows_ctr(self):
        c = {"pricing": "cpm", "price_bdt": 100, "budget_bdt": 0}
        rep = SP.report_rows(c, {date(2026, 10, 1): {"impressions": 200, "clicks": 5}},
                             date(2026, 10, 1), date(2026, 10, 2), None)
        self.assertEqual(rep["totals"]["impressions"], 200)
        self.assertEqual(rep["totals"]["ctr"], 2.5)
        self.assertEqual(rep["totals"]["revenue"], 20.0)
        self.assertEqual(len(rep["rows"]), 2)

    def test_admob_estimate_and_pnl(self):
        self.assertEqual(SP.admob_estimate_bdt(1000, 30, 0.7), 21.0)
        out = SP.placement_pnl({("hero", date(2026, 10, 1)): 100},
                               {("app_open", date(2026, 10, 1)): 2000}, 30, 0.7)
        self.assertEqual(out["summary"]["hero"]["direct"], 100)
        self.assertEqual(out["summary"]["app_open"]["admob_est"], 42.0)

    def test_retention_buckets_small_sample(self):
        today = date(2026, 10, 30)
        users = [{"joined": date(2026, 10, 1), "last_active": date(2026, 10, 29), "ads_first7": 0},
                 {"joined": date(2026, 10, 1), "last_active": date(2026, 10, 1), "ads_first7": 25}]
        b = SP.retention_by_bucket(users, today)
        self.assertEqual(b["none"]["d7_pct"], 100.0)
        self.assertEqual(b["heavy"]["d1_pct"], 0.0)
        self.assertEqual(b["heavy"]["stopped_pct"], 100.0)
        self.assertTrue(b["none"]["small_sample"])

    def test_offer_notif_rule(self):
        ok = dict(paid=False, premium_allowed=False, offers_enabled=True, notifs_on=True,
                  sent_today=0, daily_cap=2, muted=False, already_sent=False)
        self.assertEqual(SP.offer_notif_ok(**ok), (True, "ok"))
        self.assertEqual(SP.offer_notif_ok(**dict(ok, sent_today=2)), (False, "daily_cap"))
        self.assertEqual(SP.offer_notif_ok(**dict(ok, paid=True)), (False, "paid_plan"))
        self.assertEqual(SP.offer_notif_ok(**dict(ok, paid=True, premium_allowed=True)),
                         (True, "ok"))
        self.assertEqual(SP.offer_notif_ok(**dict(ok, muted=True)), (False, "muted"))
        self.assertEqual(SP.offer_notif_ok(**dict(ok, notifs_on=False)), (False, "notifs_off"))


class AnnualClampTests(SimpleTestCase):
    def test_sold_price_is_clamped_stored_value_kept(self):
        c = P.DEFAULTS()
        self.assertEqual(c["annual_discount_pct"], 20)
        self.assertEqual(P.max_safe_annual_discount_pct("premium", c), 9)
        self.assertEqual(P.effective_annual_discount_pct("premium", c), 9)
        self.assertEqual(P.annual_price("premium", c), round(199 * 12 * 0.91))
        self.assertEqual(P.stored_annual_price("premium", c), 1910)
        ann = next(p for p in P.plan_public("en", c) if p["id"] == "annual")
        self.assertEqual(ann["price"], 2173)
        self.assertEqual(ann["discount_pct"], 9)
        self.assertEqual(P.normalize(c)["annual_discount_pct"], 20)   # untouched
        codes = [w["code"] for w in P.margin_warnings(c)]
        self.assertIn("annual_discount_clamped", codes)

    def test_lower_discount_is_used_as_is(self):
        c = P.DEFAULTS()
        c["annual_discount_pct"] = 5
        self.assertEqual(P.effective_annual_discount_pct("premium", c), 5)
        self.assertNotIn("annual_discount_clamped", [w["code"] for w in P.margin_warnings(c)])


# ======================================================================== API
_SSV_KEY = ec.generate_private_key(ec.SECP256R1())
_SSV_PEM = _SSV_KEY.public_key().public_bytes(
    serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
_SSV_KID = "424242"


def _ssv_query(nonce, user_id, txn):
    msg = urlencode([("ad_network", "5450213213286189855"), ("ad_unit", "1111111111"),
                     ("custom_data", nonce), ("reward_amount", "1"),
                     ("reward_item", "credit"), ("timestamp", "1700000000000"),
                     ("transaction_id", txn), ("user_id", user_id)])
    sig = _SSV_KEY.sign(msg.encode(), ec.ECDSA(hashes.SHA256()))
    return "%s&signature=%s&key_id=%s" % (
        msg, base64.urlsafe_b64encode(sig).decode().rstrip("="), _SSV_KID)


class _Base(APITestCase):
    def mk(self, name, phone, plan="free", days_ago=3):
        u = User.objects.create_user(name=name, phone=phone, password="pw")
        u.plan = plan
        if plan != "free":
            u.plan_until = timezone.now() + timedelta(days=30)
        u.date_joined = timezone.now() - timedelta(days=days_ago)
        u.save()
        return u

    def setUp(self):
        self.free = self.mk("F", "01999000101")
        self.new = self.mk("N", "01999000102", days_ago=0)
        self.prem = self.mk("P", "01999000103", plan="premium")
        self.sp = Sponsor.objects.create(name="Brand A", category="mobile")
        now = timezone.now()
        self.win = dict(start_at=now - timedelta(days=1), end_at=now + timedelta(days=9))

    def camp(self, placement="app_open", **kw):
        d = dict(sponsor=self.sp, name="C", placement=placement, status="approved",
                 pricing="flat", price_bdt=1000, title_bn="অফার", title_en="Offer",
                 body_bn="ভালো দাম", body_en="Good price", link_url="https://example.com",
                 **self.win)
        d.update(kw)
        return SponsorCampaign.objects.create(**d)

    def as_(self, u):
        self.client.force_authenticate(u)

    def slot(self, placement="app_open", **q):
        qs = urlencode({"placement": placement, **q})
        return self.client.get("/api/v1/ads/slot?" + qs).json()


class AppOpenApiTests(_Base):
    def test_direct_sponsor_served_and_counted_with_caps(self):
        c = self.camp()
        self.as_(self.free)
        r = self.slot()
        self.assertTrue(r["show"])
        self.assertEqual(r["source"], "direct")
        self.assertEqual(r["skip_after_s"], 5)
        self.assertEqual(r["creative"]["label"], "sponsored")
        tok = r["creative"]["token"]
        e = self.client.post("/api/v1/ads/sponsor/event", {"token": tok, "kind": "impression"},
                             format="json").json()
        self.assertTrue(e["counted"])
        self.assertEqual(SponsorDailyStat.objects.get(campaign=c).impressions, 1)
        # min gap: the next one is too soon
        self.assertEqual(self.slot()["reason"], "too_soon")
        # 6/day cap even without the gap
        AdExposure.objects.filter(user=self.free).update(count=6,
                                                         last_at=timezone.now() - timedelta(hours=5))
        self.assertEqual(self.slot()["reason"], "daily_cap")

    def test_day2_free_only_blocked_entries(self):
        self.camp()
        self.as_(self.new)
        self.assertEqual(self.slot()["reason"], "too_new")
        self.as_(self.prem)
        self.assertEqual(self.slot()["reason"], "paid_plan")
        self.as_(self.free)
        self.assertEqual(self.slot(entry="notification")["reason"], "blocked_entry")
        self.assertEqual(self.slot(screen="circle_call")["reason"], "blocked_screen")
        self.assertEqual(self.slot(screen="payment")["reason"], "blocked_screen")

    def test_no_campaign_no_admob_is_no_fill(self):
        self.as_(self.free)
        with mock.patch.object(SS, "admob_ready", return_value=False):
            r = self.slot()
        self.assertFalse(r["show"])
        self.assertEqual(r["reason"], "no_fill")

    def test_admob_fills_empty_app_open_by_default_with_test_ids(self):
        # admob (owner 25 Oct): AdMob fills an empty app-open slot (TEST units
        # until admob_real_ids); the owner switch place_app_open turns it off
        self.as_(self.free)
        self.assertEqual(self.slot()["source"], "admob")
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, place_app_open=False)
        row.data = d
        row.save()
        self.assertEqual(self.slot()["reason"], "no_fill")

    def test_admob_fills_empty_slot_when_linked(self):
        self.as_(self.free)
        with mock.patch.object(SS, "admob_ready", return_value=True):
            r = self.slot()
            self.assertEqual(r["source"], "admob")
            self.camp()
            self.assertEqual(self.slot()["source"], "direct")

    def test_kill_switch(self):
        self.camp()
        self.as_(self.free)
        with mock.patch.object(SS, "flag", return_value=False):
            self.assertEqual(self.slot()["reason"], "disabled")

    def test_hide_and_mute(self):
        c = self.camp()
        self.as_(self.free)
        tok = self.slot()["creative"]["token"]
        self.client.post("/api/v1/ads/sponsor/event", {"token": tok, "kind": "mute"}, format="json")
        self.assertIn(self.sp.id, OfferPrefs.objects.get(user=self.free).muted_brands)
        AdExposure.objects.all().delete()
        with mock.patch.object(SS, "admob_ready", return_value=False):
            self.assertEqual(self.slot()["reason"], "no_fill")
        why = self.client.get("/api/v1/ads/why?" + urlencode({"token": tok})).json()
        self.assertEqual(why["sponsor"], "Brand A")
        # a token from another user is refused
        self.as_(self.prem)
        r = self.client.post("/api/v1/ads/sponsor/event", {"token": tok, "kind": "click"},
                             format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(c.daily.count(), 1)

    def test_impressions_capped_per_user_day(self):
        c = self.camp(placement="hero")
        self.as_(self.free)
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, hero_enabled=True)
        row.data = d
        row.save()
        tok = self.slot("hero")["creative"]["token"]
        for _ in range(5):
            self.client.post("/api/v1/ads/sponsor/event", {"token": tok, "kind": "impression"},
                             format="json")
        self.assertEqual(SponsorDailyStat.objects.get(campaign=c).impressions, 3)


class CommunityPostTests(_Base):
    def test_threshold_and_admin(self):
        from core.models import Channel
        owner = self.mk("O", "01999000104")
        ch = Channel.objects.create(owner=owner, name="Big", handle="bigch", follower_count=499)
        self.camp(placement="community_post")
        self.as_(self.free)
        q = {"ctx_kind": "channel", "ctx_id": ch.id}
        self.assertEqual(self.slot("community_post", **q)["reason"], "too_small")
        ch.follower_count = 500
        ch.save()
        r = self.slot("community_post", **q)
        self.assertEqual(r["source"], "direct")
        self.as_(owner)
        self.assertEqual(self.slot("community_post", **q)["reason"], "own_space")
        self.as_(self.prem)
        self.assertEqual(self.slot("community_post", **q)["reason"], "paid_plan")


class OffersTests(_Base):
    def test_prefs_feed_and_notif_cap(self):
        self.as_(self.free)
        r = self.client.post("/api/v1/offers/prefs", {"categories": ["mobile", "bogus"]},
                             format="json").json()
        self.assertEqual(r["categories"], ["mobile"])
        # ads check 28 Oct: offer notifications are opt-in — the user turns them on
        self.assertFalse(r["notifs_on"])
        r = self.client.post("/api/v1/offers/prefs", {"notifs_on": True},
                             format="json").json()
        self.assertTrue(r["notifs_on"])
        self.assertEqual(r["notif_daily_cap"], 2)
        camps = [self.camp(placement="brand_offer", categories=["mobile"], name="C%d" % i)
                 for i in range(3)]
        feed = self.client.get("/api/v1/offers/feed").json()["offers"]
        self.assertEqual(len(feed), 3)
        self.assertTrue(feed[0]["matches_you"])
        with mock.patch("core.push.push_to_user_async", return_value=True):
            sent = [SS.send_offer_notifications(c)["sent"] for c in camps]
        self.assertEqual(sent, [1, 1, 0])                       # max 2/day
        self.assertEqual(OfferNotifLog.objects.filter(user=self.free).count(), 2)
        self.assertEqual(NotifEvent.objects.filter(user=self.free, type="offer").count(), 2)
        # once per campaign
        with mock.patch("core.push.push_to_user_async", return_value=True):
            self.assertEqual(SS.send_offer_notifications(camps[0])["sent"], 0)

    def test_mute_notifs_off_premium(self):
        c = self.camp(placement="brand_offer", categories=["mobile"])
        for u in (self.free, self.prem):
            OfferPrefs.objects.create(user=u, categories=["mobile"], notifs_on=True,
                                      notifs_opted_in_at=timezone.now())
        self.as_(self.free)
        self.client.post("/api/v1/offers/brands/%d/mute" % self.sp.id, {"muted": True},
                         format="json")
        with mock.patch("core.push.push_to_user_async", return_value=True):
            res = SS.send_offer_notifications(c)
        self.assertEqual(res["sent"], 0)
        self.assertEqual(res["skipped"].get("muted"), 1)
        self.assertEqual(res["skipped"].get("paid_plan"), 1)   # Premium: never by default
        self.assertEqual(self.client.get("/api/v1/offers/feed").json()["offers"], [])
        self.client.post("/api/v1/offers/brands/%d/mute" % self.sp.id, {"muted": False},
                         format="json")
        self.client.post("/api/v1/offers/prefs", {"notifs_on": False}, format="json")
        with mock.patch("core.push.push_to_user_async", return_value=True):
            self.assertEqual(SS.send_offer_notifications(c)["sent"], 0)
        self.as_(self.prem)
        self.assertEqual(self.client.get("/api/v1/offers/feed").json()["reason"],
                         "premium_no_ads")


class RewardedSsvTests(_Base):
    def setUp(self):
        super().setUp()
        k = mock.patch.object(PSS, "_ssv_keys", return_value={_SSV_KID: _SSV_PEM})
        k.start()
        self.addCleanup(k.stop)

    def linked(self):
        def is_enabled(slug):
            return slug == "admob"

        def get(slug):
            return {"app_id": REAL_APP, "rewarded_unit": REAL_REW} if slug == "admob" else {}
        for t in (mock.patch("core.integrations.is_enabled", side_effect=is_enabled),
                  mock.patch("core.integrations.get", side_effect=get)):
            t.start()
            self.addCleanup(t.stop)
        # admob (owner 25 Oct): rewarded is offered only on REAL unit ids
        row = billing.get_config()
        d = dict(row.data or {})
        d["ad_rewards"] = dict(d.get("ad_rewards") or {}, admob_real_ids=True)
        row.data = d
        row.save()

    def test_honest_when_admob_not_linked(self):
        self.as_(self.free)
        r = self.client.post("/api/v1/credits/rewarded/ticket", {}, format="json").json()
        self.assertFalse(r["ok"])
        self.assertEqual(r["reason"], "ads_not_configured")
        self.assertFalse(PhotoAdTicket.objects.exists())

    def test_client_claim_earns_nothing(self):
        self.linked()
        self.as_(self.free)
        r = self.client.post("/api/v1/ads/event", {"kind": "rewarded"}, format="json").json()
        self.assertEqual(r["reason"], "ssv_required")
        r = self.client.post("/api/v1/credits/rewarded", {}, format="json").json()
        self.assertEqual(r["reason"], "ssv_required")
        self.assertEqual(billing.ad_wallet_credits(self.free), 0)

    def test_only_verified_ssv_credits_with_cap(self):
        self.linked()
        self.as_(self.free)
        t = self.client.post("/api/v1/credits/rewarded/ticket", {}, format="json").json()
        self.assertTrue(t["ok"])
        st = self.client.get("/api/v1/credits/rewarded/ticket/%s" % t["nonce"]).json()
        self.assertEqual(st["status"], "pending")
        self.client.get("/api/v1/ads/ssv?" + _ssv_query(t["nonce"], str(self.free.pk), "tx-1"))
        st = self.client.get("/api/v1/credits/rewarded/ticket/%s" % t["nonce"]).json()
        self.assertTrue(st["credited"])
        self.assertEqual(AdEvent.objects.filter(user=self.free, kind="rewarded",
                                                credited_paisa__gt=0).count(), 1)
        # a replayed transaction id credits nothing
        t2 = self.client.post("/api/v1/credits/rewarded/ticket", {}, format="json").json()
        self.client.get("/api/v1/ads/ssv?" + _ssv_query(t2["nonce"], str(self.free.pk), "tx-1"))
        self.assertEqual(AdEvent.objects.filter(user=self.free, credited_paisa__gt=0).count(), 1)
        # daily cap -> no ticket
        cap = billing.cfg()["ad_rewards"]["rewarded_daily_cap"]
        for i in range(cap):
            AdEvent.objects.create(user=self.free, kind="rewarded", credited_paisa=1)
        r = self.client.post("/api/v1/credits/rewarded/ticket", {}, format="json").json()
        self.assertEqual(r["reason"], "capped")


class TrialAndPaywallTests(_Base):
    def test_trial_once_server_enforced(self):
        self.as_(self.free)
        offer = self.client.get("/api/v1/premium/offer?reason=out_of_credits").json()
        self.assertTrue(offer["trial_available"])
        self.assertEqual(offer["trial_days"], 3)
        self.assertEqual(offer["reason"], "out_of_credits")
        r = self.client.post("/api/v1/plans/trial/start", {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.free.refresh_from_db()
        left = self.free.trial_until - timezone.now()
        self.assertTrue(timedelta(days=2, hours=23) < left <= timedelta(days=3))
        self.assertEqual(plans.effective_plan(self.free), "premium")
        r = self.client.post("/api/v1/plans/trial/start", {}, format="json")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "trial_used")
        # expired trial is still a used trial
        self.free.trial_until = timezone.now() - timedelta(days=1)
        self.free.save()
        self.assertFalse(plans.trial_available(self.free))
        self.assertEqual(self.client.post("/api/v1/plans/trial/start", {},
                                          format="json").status_code, 409)

    def test_paid_users_cannot_trial(self):
        self.as_(self.prem)
        self.assertEqual(self.client.post("/api/v1/plans/trial/start", {},
                                          format="json").json()["reason"], "not_eligible")

    def test_signup_does_not_auto_start_trial(self):
        self.assertFalse(plans.trial_on_signup())

    def test_premium_benefits_honest_and_yearly_clamped(self):
        self.as_(self.free)
        o = self.client.get("/api/v1/premium/offer?reason=ad_free&lang=en").json()
        keys = [b["key"] for b in o["benefits"]]
        self.assertIn("credits", keys)
        self.assertIn("no_ads", keys)
        self.assertIn("family", keys)
        self.assertEqual(o["yearly_discount_pct"], 9)
        self.assertEqual(o["yearly_price"], 2173)
        self.assertEqual(self.client.get("/api/v1/premium/offer?reason=zzz").json()["reason"],
                         "generic")

    def test_ads_config_carries_new_caps(self):
        self.as_(self.free)
        j = self.client.get("/api/v1/ads/config").json()
        self.assertEqual(j["appopen_daily_cap"], 6)
        self.assertEqual(j["appopen_start_day"], 2)
        self.assertEqual(j["appopen_skip_after_s"], 5)
        self.assertIn("notification", j["blocked_entries"])


class OwnerReportTests(_Base):
    def test_campaign_report_and_pnl(self):
        c = self.camp(placement="hero", pricing="cpm", price_bdt=100, budget_bdt=0)
        SponsorDailyStat.objects.create(campaign=c, date=timezone.localdate(),
                                        impressions=500, clicks=10)
        rep = SS.campaign_report(c, timezone.localdate() - timedelta(days=1), timezone.localdate())
        self.assertEqual(rep["totals"]["revenue"], 50.0)
        self.assertEqual(rep["totals"]["ctr"], 2.0)
        self.assertIn("TOTAL", SS.report_csv(rep))
        pnl = SS.placement_pnl(7)
        self.assertEqual(pnl["summary"]["hero"]["direct"], 50.0)
        AdExposure.objects.create(user=self.free, date=timezone.localdate(), placement="app_open",
                                  source="admob", count=1000)
        pnl = SS.placement_pnl(7)
        ar = billing.cfg()["ad_rewards"]
        self.assertEqual(pnl["summary"]["app_open"]["admob_est"],
                         SP.admob_estimate_bdt(1000, ar["ecpm_bdt"], ar["revenue_share"]))
        ret = SS.retention_impact(30)
        self.assertIn("none", ret["buckets"])
