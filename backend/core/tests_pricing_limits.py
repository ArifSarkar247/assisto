"""Every business price/limit is admin-editable in /admin/pricing and the edit
actually takes effect (a1-priority, owner master order). Covers: trial days +
trial credits, rewarded-ad daily cap, Business included cameras, Probashi USD
price, AI daily budget + per-user limit, referral points economy, the NET-margin
guarantees, plan storage, and validation of bad edits."""
from datetime import timedelta

from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import billing, plans
from core.logic import pricing as P
from core.models import User, ReferralGrant


class LimitsLogicTests(SimpleTestCase):
    def test_defaults_preserve_shipped_behaviour(self):
        c = P.normalize({})
        # p2-money: 3-day trial, started from the button (not at sign-up)
        self.assertEqual(c["limits"], {"trial_days": 3, "trial_credits": 15,
                                       "trial_on_signup": False,
                                       "business_included_cameras": 4,
                                       "voice_youtube_daily": 40,  # a3-voice
                                       "contact_lookups_per_hour": 30,  # c1
                                       "founding_member_months": 12,  # f1
                                       "feedback_per_hour": 5,  # f1
                                       "feedback_per_day": 20,  # f1
                                       "disk_alert_pct": 80,  # pr1
                                       "my_circle_min_version": 183,  # t1
                                       "message_request_max_msgs": 3,  # mr1 + connect-flow
                                       "message_requests_per_day": 20,  # mr1
                                       "message_requests_per_recipient_day": 50,  # connect-flow
                                       "circle_media_photo_max_mb": 16,  # md1
                                       "circle_media_voice_max_mb": 16,
                                       "circle_media_doc_max_mb": 25,
                                       "circle_media_video_max_mb": 32,  # mc-media2
                                       "circle_media_daily_mb": 300,
                                       "circle_media_uploads_per_hour": 60,
                                       "circle_media_keep_days": 30,
                                       "circle_media_max_days": 90})
        self.assertEqual(c["guarantees"], {"margin_net_floor": 0.60,
                                           "pool_cap_pct_of_net": 0.60})
        self.assertEqual(c["probashi_price_usd"], 4.99)
        self.assertEqual(c["ai_daily_budget_usd"], 0.0)   # 0 = env default
        self.assertEqual(c["ai_user_daily_limit"], 0)
        self.assertEqual(c["referral"]["points_per_premium_day"], 25)
        self.assertEqual(P.normalize(P.DEFAULTS()), P.normalize({}))
        self.assertEqual(P.validate_edit(P.DEFAULTS()), [])

    def test_normalize_clamps_garbage(self):
        c = P.normalize({"limits": {"trial_days": -3, "trial_credits": "x",
                                    "business_included_cameras": 999},
                         "guarantees": {"margin_net_floor": 5,
                                        "pool_cap_pct_of_net": -1},
                         "referral": {"points_per_premium_day": 0},
                         "probashi_price_usd": -2})
        self.assertEqual(c["limits"]["trial_days"], 0)
        self.assertEqual(c["limits"]["trial_credits"], 15)
        self.assertEqual(c["limits"]["business_included_cameras"], 64)
        self.assertEqual(c["guarantees"]["margin_net_floor"], 0.90)
        self.assertEqual(c["guarantees"]["pool_cap_pct_of_net"], 0.0)
        self.assertEqual(c["referral"]["points_per_premium_day"], 1)
        self.assertEqual(c["probashi_price_usd"], 0.0)

    def test_validation_codes(self):
        self.assertIn("bad_guarantee", P.validate_edit({"guarantees": {"margin_net_floor": 0.95}}))
        self.assertIn("bad_guarantee", P.validate_edit({"guarantees": {"margin_net_floor": 0.05}}))
        self.assertIn("bad_guarantee", P.validate_edit({"guarantees": "x"}))
        self.assertIn("limit_negative", P.validate_edit({"limits": {"trial_days": -1}}))
        self.assertIn("limit_negative", P.validate_edit({"referral": {"monthly_referral_cap": "lots"}}))
        self.assertIn("price_negative", P.validate_edit({"probashi_price_usd": -1}))
        self.assertIn("price_negative", P.validate_edit({"ai_daily_budget_usd": -5}))
        self.assertEqual(P.validate_edit({"limits": {"trial_days": 14}}), [])


class LimitsTakeEffectTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="U", phone="01710000701", password="pw")
        self.owner = User.objects.create_user(name="O", phone="01710000702", password="pw")
        self.owner.is_superuser = True
        self.owner.save()

    def _edit(self, patch, expect=200):
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/pricing", {"config": patch, "reason": "t"},
                             format="json")
        self.assertEqual(r.status_code, expect, getattr(r, "data", None))
        return r

    def test_non_owner_cannot_edit_limits(self):
        self.client.force_authenticate(self.u)
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"limits": {"trial_days": 30}}}, format="json")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(billing.cfg()["limits"]["trial_days"], 3)

    def test_trial_days_and_credits(self):
        self._edit({"limits": {"trial_days": 14, "trial_credits": 40}})
        before = timezone.now()
        plans.start_trial(self.u)
        self.u.refresh_from_db()
        self.assertGreaterEqual(self.u.trial_until, before + timedelta(days=14))
        self.assertLess(self.u.trial_until, before + timedelta(days=14, minutes=5))
        self.assertEqual(self.u.ai_credits, 40)

    def test_partial_limits_edit_keeps_siblings(self):
        self._edit({"limits": {"trial_days": 3}})
        lim = billing.cfg()["limits"]
        self.assertEqual((lim["trial_days"], lim["trial_credits"],
                          lim["business_included_cameras"]), (3, 15, 4))

    def test_rewarded_daily_cap(self):
        self._edit({"ad_rewards": {"rewarded_daily_cap": 2}})
        self.assertEqual(plans.reward_ad(self.u), (True, 1))
        self.assertEqual(plans.reward_ad(self.u), (True, 0))
        ok, left = plans.reward_ad(self.u)
        self.assertFalse(ok)
        self.assertEqual(left, 0)

    def test_business_included_cameras(self):
        from core.shop_views import _included_cameras
        self.u.plan = "business"
        self.u.plan_until = timezone.now() + timedelta(days=30)
        self.u.save()
        self.assertEqual(_included_cameras(self.u), 4)
        self._edit({"limits": {"business_included_cameras": 8}})
        self.assertEqual(_included_cameras(self.u), 8)
        free = User.objects.create_user(name="F", phone="01710000703", password="pw")
        self.assertEqual(_included_cameras(free), 0)

    def test_probashi_price(self):
        self._edit({"probashi_price_usd": 5.49})
        pro = next(p for p in plans.plans_public("en") if p["id"] == "probashi")
        self.assertEqual(pro["price"], 5.49)
        self.assertEqual(pro["cur"], "USD")

    @override_settings(AI_DAILY_BUDGET_USD=5.0, AI_USER_DAILY_LIMIT=40)
    def test_ai_budget_and_user_limit_override(self):
        from core import ai
        self.assertEqual(ai.daily_budget_usd(), 5.0)      # env default
        self.assertEqual(ai.user_daily_limit(), 40)
        self._edit({"ai_daily_budget_usd": 12.5, "ai_user_daily_limit": 80})
        self.assertEqual(ai.daily_budget_usd(), 12.5)
        self.assertEqual(ai.user_daily_limit(), 80)
        self.assertEqual(ai.status()["daily_budget_usd"], 12.5)
        self._edit({"ai_daily_budget_usd": 0})              # back to env
        self.assertEqual(ai.daily_budget_usd(), 5.0)

    def test_referral_rate_drives_redeem(self):
        ReferralGrant.objects.create(user=self.u, kind="grant", points=100,
                                     reason="referral_accept")
        self._edit({"referral": {"points_per_premium_day": 10,
                                 "min_redeem_points": 10}})
        self.client.force_authenticate(self.u)
        r = self.client.post("/api/v1/referral/redeem", {"points": 100}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["days"], 10)       # 100 / 10 (default would be 4)
        bal = self.client.get("/api/v1/referral/balance")
        self.assertEqual(bal.status_code, 200)

    def test_referral_min_redeem(self):
        ReferralGrant.objects.create(user=self.u, kind="grant", points=100,
                                     reason="referral_accept")
        self._edit({"referral": {"min_redeem_points": 80}})
        self.client.force_authenticate(self.u)
        r = self.client.post("/api/v1/referral/redeem", {"points": 50}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["code"], "below_minimum")

    def test_referral_award_uses_config(self):
        from core.views_build61 import award_referral_on_accept
        self._edit({"referral": {"points_per_referral": 70, "welcome_bonus_points": 5}})
        invitee = User.objects.create_user(name="I", phone="01710000704", password="pw")
        res = award_referral_on_accept(self.u.id, invitee.id, device_id="dev-x")
        self.assertTrue(res.get("ok"), res)
        self.assertEqual(ReferralGrant.objects.get(user=self.u, kind="grant").points, 70)
        # the invitee's welcome bonus is actually persisted (was dropped: None device_id)
        self.assertEqual(ReferralGrant.objects.get(user=invitee, kind="bonus").points, 5)

    def test_storage_quota_editable(self):
        self._edit({"plans": {"free": {"storage_bytes": 2 * P.GB}}})
        self.assertEqual(billing.storage_quota_bytes(self.u), 2 * P.GB)

    def test_config_can_never_make_a_plan_unlimited(self):
        # owner decision: nothing is unlimited — the edit is refused ...
        self._edit({"plans": {"free": {"unlimited_ai": True}}}, expect=400)
        # ... and even a stored row carrying it is ignored by normalize()
        row = billing.get_config()
        row.data["plans"]["free"]["unlimited_ai"] = True
        row.data["plans"]["premium"]["unlimited_ai"] = True
        row.save()
        self.assertFalse(billing.cfg()["plans"]["free"]["unlimited_ai"])
        self.assertFalse(billing.cfg()["plans"]["premium"]["unlimited_ai"])
        self.u.ai_credits = 3
        self.u.save()
        plans.consume_credit(self.u)
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 2)     # always debits

    def test_guarantee_edit_changes_floor(self):
        c0 = billing.cfg()
        self.assertEqual(P.action_credit_floor("ai_msg_strong", c0), 6)
        self._edit({"guarantees": {"margin_net_floor": 0.30}}, expect=400)  # strong(6) < new floor 12
        self._edit({"guarantees": {"margin_net_floor": 0.95}}, expect=400)  # out of bounds
        r = self._edit({"guarantees": {"margin_net_floor": 0.80}})
        self.assertEqual(r.data["config"]["guarantees"]["margin_net_floor"], 0.80)
        self.assertEqual(P.action_credit_floor("ai_msg_strong", billing.cfg()), 5)


class PlanBenefitsFromConfigTests(APITestCase):
    """Free-plan benefit text is derived from the live pool (was a hardcoded
    "15 AI scans / month" while the configured pool is 0)."""
    def setUp(self):
        self.u = User.objects.create_user(name="U", phone="01710000901", password="pw")
        self.owner = User.objects.create_user(name="O", phone="01710000902", password="pw")
        self.owner.is_superuser = True
        self.owner.save()

    def _free(self, lang):
        return next(p for p in plans.plans_public(lang) if p["id"] == "free")["benefits"]

    def test_zero_pool_says_packs_or_ads(self):
        self.assertEqual(self._free("en")[0], "AI with credit packs or rewarded ads")
        self.assertNotIn("15", " ".join(self._free("en")))
        self.assertNotIn("১৫", " ".join(self._free("bn")))
        self.assertEqual(plans.entitlements(self.u, "en")["benefits"][0],
                         "AI with credit packs or rewarded ads")

    def test_pool_edit_flows_into_text_bn_and_en(self):
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"plans": {"free": {"credits": 20}}}}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(self._free("en")[0], "20 AI credits / month")
        self.assertEqual(self._free("bn")[0], "প্রতি মাসে ২০ AI ক্রেডিট")

    def test_premium_family_count_from_config(self):
        self.client.force_authenticate(self.owner)
        self.client.post("/api/v1/admin/pricing",
                         {"config": {"plans": {"premium": {"family": 8}}}}, format="json")
        prem = next(p for p in plans.plans_public("en") if p["id"] == "premium")
        self.assertIn("Up to 8-member Circle & caregiver dashboard", prem["benefits"])
        annual = next(p for p in plans.plans_public("bn") if p["id"] == "annual")
        self.assertTrue(any("৮ জন" in b for b in annual["benefits"]))
