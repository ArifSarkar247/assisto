"""p5-growth: invite-code referral (credits for both only after activation,
anti-abuse, monthly cap, cost booked), Founding seats, daily activity via
token auth, install ping, funnel numbers."""
from datetime import timedelta
from decimal import Decimal

from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import billing, funnel, growth as G
from core.models import (ActiveDay, CreditLedger, DailyLedger, FoundingSeat,
                         InstallPing, PaymentEvent, ReferralClaim, User)


def mk(name, phone, joined_days_ago=0):
    u = User.objects.create_user(name=name, phone=phone, password="pw12345678")
    if joined_days_ago:
        User.objects.filter(pk=u.pk).update(
            date_joined=timezone.now() - timedelta(days=joined_days_ago))
        u.refresh_from_db()
    return u


def set_cfg(**kw):
    row = billing.get_config()
    data = dict(row.data)
    ref = dict(data.get("referral") or {})
    ref.update(kw)
    data["referral"] = ref
    row.data = data
    row.save()


def active_on(user, *offsets):
    """Mark the user active on day `joined + offset` for each offset."""
    cohort = timezone.localdate(user.date_joined)
    for o in offsets:
        ActiveDay.objects.get_or_create(user=user, day=cohort + timedelta(days=o),
                                        defaults={"cohort_day": cohort, "since_signup": o})


class ReferralTests(TestCase):
    def setUp(self):
        set_cfg(founding_auto_seats=0)
        self.inviter = mk("Inviter", "01711000001", joined_days_ago=20)
        self.friend = mk("Friend", "01811000002", joined_days_ago=1)
        self.code = G.ensure_code(self.inviter)

    def test_code_is_stable_and_unique(self):
        self.assertEqual(G.ensure_code(self.inviter), self.code)
        self.assertRegex(self.code, r"^[A-Z2-9]{8}$")
        self.assertNotEqual(G.ensure_code(self.friend), self.code)
        self.assertEqual(G.normalize_code(" %s " % self.code.lower()), self.code)
        self.assertEqual(G.normalize_code("https://lifeassisto.com/i/%s" % self.code), self.code)

    def test_no_reward_until_activated_then_both_get_credits(self):
        ok, reason, row = G.claim(self.friend, self.code, device_id="dev-friend")
        self.assertTrue(ok, reason)
        self.assertEqual(row.state, "pending")
        self.assertEqual(User.objects.get(pk=self.friend.pk).ai_credits, 0)
        self.assertEqual(User.objects.get(pk=self.inviter.pk).ai_credits, 0)
        active_on(self.friend, 0)
        G.evaluate(self.friend)
        self.assertEqual(ReferralClaim.objects.get(pk=row.pk).state, "pending")
        active_on(self.friend, 1)
        G.evaluate(self.friend)
        row.refresh_from_db()
        self.assertEqual(row.state, "rewarded")
        self.assertEqual(User.objects.get(pk=self.inviter.pk).ai_credits, 20)
        self.assertEqual(User.objects.get(pk=self.friend.pk).ai_credits, 10)
        self.assertTrue(CreditLedger.objects.filter(user=self.inviter, note="referral:inviter").exists())
        # cost booked in Profit Guard (estimated provider cost of 30 credits)
        self.assertGreater(row.cost_bdt, Decimal("0"))
        led = DailyLedger.objects.get(date=timezone.localdate())
        self.assertAlmostEqual(float(led.variable_cost_by_type["growth"]), float(row.cost_bdt), 2)
        # idempotent
        G.evaluate(self.friend)
        self.assertEqual(User.objects.get(pk=self.inviter.pk).ai_credits, 20)

    def test_self_and_bad_and_double(self):
        self.assertEqual(G.claim(self.inviter, self.code)[1], "too_late")
        new_self = mk("Same", "01911000003")
        self.assertEqual(G.claim(new_self, "ZZZZZZZZ")[1], "bad_code")
        self.assertEqual(G.claim(new_self, G.ensure_code(new_self))[1], "self")
        self.assertTrue(G.claim(self.friend, self.code, device_id="dev-friend")[0])
        self.assertEqual(G.claim(self.friend, self.code, device_id="dev-friend")[1], "already_claimed")

    def test_inviter_must_be_older(self):
        older = mk("Older", "01911000004", joined_days_ago=5)
        # friend (1 day old) cannot be the inviter of an older account
        self.assertEqual(G.claim(older, G.ensure_code(self.friend))[1], "not_eligible")

    def test_inviter_own_device_is_self_referral(self):
        G.install_ping("i" * 20, user=self.inviter, device_id="shared-phone")
        self.assertEqual(G.claim(self.friend, self.code, device_id="shared-phone")[1], "self")

    def test_one_reward_per_device(self):
        self.assertTrue(G.claim(self.friend, self.code, device_id="d1")[0])
        other = mk("Other", "01911000005")
        self.assertEqual(G.claim(other, self.code, device_id="d1")[1], "device_used")

    def test_phone_reused_after_account_deletion(self):
        self.assertTrue(G.claim(self.friend, self.code, device_id="dev-friend")[0])
        self.friend.delete()
        again = mk("Again", "01811000002")
        self.assertEqual(G.claim(again, self.code, device_id="dev-again")[1], "phone_used")

    def test_no_device_id_no_referral(self):
        # billing-v2 rule P: the device check can no longer be skipped
        self.assertEqual(G.claim(self.friend, self.code)[1], "device_required")

    def test_claim_window(self):
        late = mk("Late", "01911000006", joined_days_ago=15)
        self.assertEqual(G.claim(late, self.code)[1], "too_late")

    def test_monthly_cap_gives_friend_but_not_inviter(self):
        set_cfg(invite_monthly_cap=1)
        a = mk("A", "01911000011", joined_days_ago=1)
        b = mk("B", "01911000012", joined_days_ago=1)
        for u in (a, b):
            self.assertTrue(G.claim(u, self.code, device_id="dev-%d" % u.pk)[0])
            active_on(u, 0, 1)
            G.evaluate(u)
        rows = ReferralClaim.objects.order_by("id")
        self.assertEqual([r.inviter_credits for r in rows], [20, 0])
        self.assertEqual(rows[1].reason, "inviter_cap")
        self.assertEqual(User.objects.get(pk=b.pk).ai_credits, 10)
        self.assertEqual(User.objects.get(pk=self.inviter.pk).ai_credits, 20)

    def test_not_activated_in_window_is_rejected(self):
        self.assertTrue(G.claim(self.friend, self.code, device_id="dev-friend")[0])
        User.objects.filter(pk=self.friend.pk).update(
            date_joined=timezone.now() - timedelta(days=16))
        self.friend.refresh_from_db()
        G.evaluate(self.friend)
        row = ReferralClaim.objects.get(invitee=self.friend)
        self.assertEqual((row.state, row.reason), ("rejected", "not_activated"))
        self.assertEqual(User.objects.get(pk=self.inviter.pk).ai_credits, 0)

    def test_no_phone_no_reward(self):
        nophone = User.objects.create_user(name="E", email="e@example.com", password="pw12345678")
        self.assertTrue(G.claim(nophone, self.code, device_id="dev-np")[0])
        active_on(nophone, 0, 1, 2)
        G.evaluate(nophone)
        self.assertEqual(ReferralClaim.objects.get(invitee=nophone).state, "pending")


class FoundingSeatTests(TestCase):
    def test_first_n_activated_get_numbered_seat_once(self):
        set_cfg(founding_auto_seats=2, founding_seat_credits=5)
        us = [mk("U%d" % i, "0171100010%d" % i, joined_days_ago=3) for i in range(3)]
        for u in us:
            active_on(u, 0)
            G.evaluate(u)
        self.assertEqual(FoundingSeat.objects.count(), 0)   # not activated yet
        for u in us:
            active_on(u, 1)
            G.evaluate(u)
            G.evaluate(u)
        self.assertEqual(list(FoundingSeat.objects.values_list("number", flat=True)), [1, 2])
        self.assertEqual(User.objects.get(pk=us[0].pk).ai_credits, 5)
        self.assertEqual(User.objects.get(pk=us[2].pk).ai_credits, 0)   # seats full

    def test_off_when_zero(self):
        set_cfg(founding_auto_seats=0)
        u = mk("U", "01711000200", joined_days_ago=3)
        active_on(u, 0, 1)
        G.evaluate(u)
        self.assertFalse(FoundingSeat.objects.exists())


class ApiTests(TestCase):
    def setUp(self):
        set_cfg(founding_auto_seats=0)
        self.inviter = mk("Inviter", "01711000301", joined_days_ago=10)
        self.friend = mk("Friend", "01811000302")
        self.c = APIClient()
        tok = Token.objects.create(user=self.friend)
        self.c.credentials(HTTP_AUTHORIZATION="Token " + tok.key, HTTP_X_DEVICE_ID="dev-x")

    def test_me_and_claim_and_touch(self):
        r = self.c.get("/api/v1/growth/me?lang=en")
        self.assertEqual(r.status_code, 200)
        d = r.json()
        self.assertTrue(d["link"].endswith("/i/" + d["code"]))
        self.assertIn(d["code"], d["share_text"])
        self.assertTrue(d["can_claim"])
        self.assertEqual(d["rules"]["inviter_credits"], 20)
        # token auth recorded today's activity once
        self.assertEqual(ActiveDay.objects.filter(user=self.friend).count(), 1)
        self.c.get("/api/v1/growth/me")
        self.assertEqual(ActiveDay.objects.filter(user=self.friend).count(), 1)
        r = self.c.post("/api/v1/growth/claim", {"code": "nope"}, format="json")
        self.assertEqual(r.status_code, 400)
        r = self.c.post("/api/v1/growth/claim?lang=en",
                        {"code": G.ensure_code(self.inviter)}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["me"]["my_claim"]["state"], "pending")
        self.assertFalse(r.json()["me"]["can_claim"])
        self.assertEqual(ReferralClaim.objects.get(invitee=self.friend).device_hash,
                         G._h("dev:dev-x"))

    def test_claim_rate_limited(self):
        from django.core.cache import cache
        cache.delete("p5claim:%s" % self.friend.pk)
        for _ in range(10):
            self.c.post("/api/v1/growth/claim", {"code": "BAD"}, format="json")
        r = self.c.post("/api/v1/growth/claim", {"code": "BAD"}, format="json")
        self.assertEqual(r.status_code, 429)
        cache.delete("p5claim:%s" % self.friend.pk)

    def test_install_ping_anonymous_then_linked(self):
        anon = APIClient()
        r = anon.post("/api/v1/growth/install", {"install_id": "a" * 32, "app_version": "1.0+215"},
                      format="json")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["new"])
        r = anon.post("/api/v1/growth/install", {"install_id": "a" * 32}, format="json")
        self.assertFalse(r.json()["new"])
        self.assertEqual(InstallPing.objects.count(), 1)
        self.assertIsNone(InstallPing.objects.get().user)
        self.c.post("/api/v1/growth/install", {"install_id": "a" * 32}, format="json")
        self.assertEqual(InstallPing.objects.get().user_id, self.friend.pk)
        # the raw id is never stored
        self.assertNotIn("a" * 32, InstallPing.objects.get().id_hash)
        self.assertEqual(anon.post("/api/v1/growth/install", {"install_id": "short"},
                                   format="json").json()["new"], False)

    def test_legacy_invite_uses_same_code_and_new_link(self):
        r = self.c.get("/api/v1/invite?lang=en")
        self.friend.refresh_from_db()
        self.assertEqual(r.json()["code"], G.ensure_code(self.friend))
        self.assertIn("lifeassisto.com/i/", r.json()["share_text"])
        self.assertNotIn("asalify", r.json()["share_text"])


class LandingTests(TestCase):
    def test_invite_landing(self):
        u = mk("Inviter", "01711000401")
        code = G.ensure_code(u)
        r = self.client.get("/i/%s?lang=en" % code)
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, code)
        self.assertContains(r, "referrer=ref%3D" + code)
        self.assertNotContains(r, "Inviter")          # never the inviter's name
        self.assertNotContains(r, "01711000401")
        r = self.client.get("/i/%s" % code)
        self.assertContains(r, "আমন্ত্রণ কোড")
        self.assertEqual(self.client.get("/i/NOPE1234").status_code, 404)


class FunnelTests(TestCase):
    def test_numbers(self):
        set_cfg(founding_auto_seats=0)
        now = timezone.now()
        a = mk("A", "01711000501", joined_days_ago=20)
        b = mk("B", "01711000502", joined_days_ago=20)
        mk("C", "01711000503", joined_days_ago=2)
        active_on(a, 0, 1, 7)
        active_on(b, 0)
        InstallPing.objects.create(id_hash="x" * 64)
        PaymentEvent.objects.create(user=a, kind="order.paid", amount_bdt=Decimal("100"),
                                    net_bdt=Decimal("97"))
        PaymentEvent.objects.create(user=a, kind="order.refunded", amount_bdt=Decimal("-100"),
                                    net_bdt=Decimal("-97"))
        PaymentEvent.objects.create(user=b, kind="play.charge", amount_bdt=Decimal("200"),
                                    net_bdt=Decimal("170"))
        h = funnel.headline(30, now)
        self.assertEqual(h["installs"], 1)
        self.assertEqual(h["signups"], 3)
        self.assertEqual(h["activated"], 1)
        self.assertEqual(h["closed_signups"], 2)
        self.assertEqual(h["closed_activated_pct"], 50.0)
        self.assertEqual(h["paying_users"], 2)
        self.assertAlmostEqual(h["net"], 170.0)
        ret = funnel.retention(now)
        cohort_rows = [r for r in ret["rows"] if r["size"]]
        d1 = [x for r in cohort_rows for x in r["ret"] if x["n"] == 1 and x["base"]]
        self.assertEqual(sum(x["got"] for x in d1), 1)
        self.assertEqual(sum(x["base"] for x in d1), 3)   # A, B and C (2 days old)
        d30 = [x for r in cohort_rows for x in r["ret"] if x["n"] == 30]
        self.assertTrue(all(x["pct"] is None for x in d30))   # not yet measurable
        data = funnel.dashboard(30, now)
        self.assertEqual(len(data["series"]), 30)
