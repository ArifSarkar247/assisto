"""safeplans — Safety plans, credits, packs, rewarded unlocks (owner order
3 Nov 18:40, PARTS 2 3 4 5 7).

  * plan limits: free 3, Child Plan 15 (one child), Safe Family 150 credits
    (request 1, live trip 3), School Safe 10 per student, guardian limits
  * PROFIT RULE: every plan, pack and ad unlock >= 40 % worst case with the
    default caps — FAILS if anyone loosens a default too far
  * monthly reset WITHOUT rollover; packs 30 days; never postpaid
  * Play: subscription verified + acknowledged + revenue once; pack verified,
    granted once per token, consumed; refund removes unspent pack requests
  * rewarded ads: 3 -> 1 day / 3 -> 1 request, only on Google's SSV, daily
    caps, child accounts never get a ticket (nor a credit)
  * ALWAYS FREE: SOS, danger and automatic school alerts bypass every limit
  * switch OFF (default): nothing is ever charged or refused
  * PART 7: the privacy draft carries the "never sell location data" line
"""
from datetime import datetime, timedelta, timezone as dt_tz
from pathlib import Path
from unittest import mock

from django.core.cache import cache
from django.test import Client, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import safe_plans as S
from core.logic import safe_plans as SP
from core.models import CircleMember, PaCollectionItem, PhotoAdTicket, PlayPurchase, User
from core.payments import play

from .tests_pay1 import PlayBase, sub_body

V = "/api/v1"
ROOT = Path(__file__).resolve().parents[2]


def mk(phone, name):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!")


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def link_child(parent, child):
    CircleMember.objects.create(user=parent, peer_user=child, name=child.name,
                                relation="child", state="accepted")
    CircleMember.objects.create(user=child, peer_user=parent, name=parent.name,
                                relation="mother", state="accepted", direction="incoming")


def on():
    p = mock.patch("core.safe_plans.feature_on", return_value=True)
    p.start()
    return p


# ------------------------------------------------------------------ pure rules
class PureRuleTests(TestCase):
    def setUp(self):
        self.c = SP.defaults()

    def test_owner_numbers(self):
        c = self.c
        self.assertEqual((c["child_price_bdt"], c["child_requests"], c["child_guardians"],
                          c["child_children"]), (30, 15, 2, 1))
        self.assertEqual((c["family_price_bdt"], c["family_credits"], c["family_members"],
                          c["family_history_days"], c["family_update_min"]),
                         (99, 150, 15, 30, 5))
        self.assertEqual((c["school_price_bdt"], c["school_min_students"],
                          c["school_guardians"], c["school_requests"]), (20, 100, 4, 10))
        self.assertEqual((c["cost_location_request"], c["cost_live_trip"]), (1, 3))
        self.assertEqual(c["packs"][0], {"id": "safe_req_10", "requests": 10, "price_bdt": 10})
        self.assertEqual((c["ads_for_day"], c["ads_for_request"]), (3, 3))
        self.assertFalse(c["on_sale"])

    def test_plan_limits(self):
        c = self.c
        self.assertEqual(SP.allowance(c, "free"), 3)
        self.assertEqual(SP.allowance(c, "child"), 15)
        self.assertEqual(SP.allowance(c, "family"), 150)
        self.assertEqual(SP.guardian_limit(c, "child"), 2)
        self.assertEqual(SP.guardian_limit(c, "free"), 2)
        self.assertEqual(SP.guardian_limit(c, "free", school=True), 4)
        s, now = {}, 1_000_000
        for _ in range(15):
            ok, s, _ = SP.spend(c, s, "child", 1, now)
            self.assertTrue(ok)
        ok, s2, _ = SP.spend(c, s, "child", 1, now)
        self.assertFalse(ok)
        self.assertEqual(s2, s)                       # all or nothing
        s = {}
        for _ in range(50):
            ok, s, _ = SP.spend(c, s, "family", SP.action_cost(c, "live_trip"), now)
            self.assertTrue(ok)
        self.assertFalse(SP.spend(c, s, "family", 1, now)[0])

    def test_profit_rule_at_least_40_everywhere(self):
        t = SP.profit_table()
        self.assertTrue(t["ok"], t)
        self.assertGreaterEqual(t["min_pct"], 40.0)
        rows = {r["plan"]: r for r in t["rows"]}
        self.assertAlmostEqual(rows["child"]["pct"], 48.9, places=1)
        self.assertAlmostEqual(rows["family"]["pct"], 43.7, places=1)
        self.assertAlmostEqual(rows["school"]["pct"], 58.5, places=1)

    def test_without_paid_map_cap_the_prices_fail_40_and_min_price_is_reported(self):
        c = dict(self.c, paid_maps_child=15, paid_maps_family=50)
        t = SP.profit_table(c)
        self.assertFalse(t["ok"])
        self.assertEqual(set(t["fails"]), {"child", "family"})
        self.assertEqual(SP.min_price_for_40(c, "child"), 36)
        self.assertEqual(SP.min_price_for_40(c, "family"), 126)

    def test_monthly_reset_no_rollover(self):
        c = self.c
        s = SP.roll_period({}, "2026-10")
        ok, s, _ = SP.spend(c, s, "child", 2, 0)
        s["ad_requests"] = 4
        self.assertEqual(SP.balance(c, s, "child", 0)["monthly"], 13)
        s = SP.roll_period(s, "2026-11")
        b = SP.balance(c, s, "child", 0)
        self.assertEqual(b["monthly"], 15)            # fresh 15, NOT 13 + 15
        self.assertEqual(b["ads"], 0)                 # ad requests wiped too
        self.assertEqual(SP.roll_period(s, "2026-11"), s)   # same month: unchanged

    def test_packs_expire_after_valid_days_and_spend_order(self):
        c = self.c
        now = 10_000_000
        _, s = SP.add_pack(c, {"period": "x"}, "tok", 10, now)
        added, s = SP.add_pack(c, s, "tok", 10, now)
        self.assertFalse(added)                       # once per token
        ok, s, took = SP.spend(c, s, "free", 4, now)
        self.assertEqual(took, {"monthly": 3, "packs": 1})
        self.assertEqual(SP.balance(c, s, "free", now)["packs"], 9)
        late = now + 31 * 86400
        self.assertEqual(SP.balance(c, s, "free", late)["packs"], 0)   # no rollover
        s = SP.refund(s, took)
        self.assertEqual(SP.balance(c, s, "free", now)["packs"], 10)

    def test_ads_ratio_and_daily_caps(self):
        c = self.c
        s, now = {}, 5_000_000
        for i in range(2):
            s, u = SP.ad_verified(c, s, "request", now, "d1")
            self.assertIsNone(u)
        s, u = SP.ad_verified(c, s, "request", now, "d1")
        self.assertEqual(u, "request")
        self.assertEqual(s["ad_requests"], 1)
        for _ in range(6):
            s, _ = SP.ad_verified(c, s, "request", now, "d1")
        self.assertEqual(s["ad_requests"], 3)
        self.assertFalse(SP.ad_can_start(c, s, "request", "d1"))     # cap 3 / day
        s, u = SP.ad_verified(c, s, "request", now, "d1")
        self.assertIsNone(u)
        self.assertTrue(SP.ad_can_start(c, s, "request", "d2"))      # next day
        for _ in range(3):
            s, u = SP.ad_verified(c, s, "day", now, "d1")
        self.assertEqual(u, "day")
        self.assertEqual(s["day_pass_until"], now + 24 * 3600)
        self.assertFalse(SP.ad_can_start(c, s, "day", "d1"))

    def test_owner_edit_bounds_and_school_minimum(self):
        self.assertEqual(SP.problems({"child_price_bdt": -5}), ["bad_safe_plans"])
        self.assertIn("school_below_minimum",
                      SP.problems({"schools": {"ABCD1": {"students": 40}}}))
        n = SP.normalize_cfg({"schools": {"abcd-12": {"students": 150, "admin_ids": [3, "x"]}},
                              "packs": [{"id": "safe_req_10", "requests": 10, "price_bdt": 10}]})
        self.assertEqual(list(n["schools"]), ["ABCD12"])
        self.assertEqual(n["schools"]["ABCD12"]["admin_ids"], [3])

    def test_play_products_list(self):
        ids = [(p["type"], p["product_id"], p["price_bdt"]) for p in SP.play_products()]
        self.assertEqual(ids, [("subscription", "safe_child", 30),
                               ("subscription", "safe_family", 99),
                               ("consumable", "safe_req_10", 10),
                               ("consumable", "safe_req_30", 30),
                               ("consumable", "safe_req_100", 100)])

    def test_always_free_costs_nothing(self):
        for k in ("sos", "danger_alert", "school_auto_alert"):
            self.assertEqual(SP.action_cost(self.c, k), 0)


# ------------------------------------------------------------------ service
class ChargeTests(TestCase):
    def setUp(self):
        cache.clear()
        self.mom = mk("01712200001", "Mom")
        self.kid = mk("01712200002", "Kid")
        self.kid2 = mk("01712200003", "Kid2")
        link_child(self.mom, self.kid)
        link_child(self.mom, self.kid2)

    def test_switch_off_never_charges_or_refuses(self):
        for _ in range(10):
            r = S.charge(self.mom, "location_request", child=self.kid)
            self.assertTrue(r["ok"])
            self.assertEqual(r["charged"], 0)
        self.assertFalse(PaCollectionItem.objects.filter(collection=S.STATE).exists())

    def test_free_requests_then_out_sheet(self):
        p = on()
        self.addCleanup(p.stop)
        api = cl(self.mom)
        for _ in range(3):
            r = api.post(V + "/safe-plans/use", {"action": "location_request",
                                                  "child_id": self.kid.pk}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
        r = api.post(V + "/safe-plans/use", {"action": "location_request"}, format="json")
        self.assertEqual(r.status_code, 402)
        sheet = r.json()["sheet"]
        self.assertEqual(set(sheet["options"]), {"buy", "ads", "upgrade"})
        self.assertEqual(sheet["packs"][0]["id"], "safe_req_10")
        st = api.get(V + "/safe-plans").json()
        self.assertEqual(st["plan"], "free")
        self.assertEqual(st["balance"]["total"], 0)

    def test_always_free_bypasses_with_zero_balance_and_switch_on(self):
        p = on()
        self.addCleanup(p.stop)
        for _ in range(3):
            S.charge(self.mom, "location_request")
        self.assertFalse(S.charge(self.mom, "location_request")["ok"])
        for k in ("sos", "danger_alert", "school_auto_alert"):
            r = S.charge(self.mom, k)
            self.assertTrue(r["ok"])
            self.assertEqual(r["charged"], 0)

    def test_new_month_resets_no_rollover(self):
        p = on()
        self.addCleanup(p.stop)
        oct_ = datetime(2026, 10, 20, 6, tzinfo=dt_tz.utc)
        S.charge(self.mom, "location_request", now=oct_)
        self.assertEqual(S.status(self.mom, now=oct_)["balance"]["monthly"], 2)
        nov = datetime(2026, 11, 2, 6, tzinfo=dt_tz.utc)
        self.assertEqual(S.status(self.mom, now=nov)["balance"]["monthly"], 3)

    def test_child_plan_covers_one_child_only(self):
        p = on()
        self.addCleanup(p.stop)
        exp = timezone.now() + timedelta(days=20)
        PlayPurchase.objects.create(user=self.mom, kind="sub", product_id="safe_child",
                                    purchase_token="t", token_hash="th1", sku="safe_child_m",
                                    state="SUBSCRIPTION_STATE_ACTIVE", expires_at=exp)
        self.assertEqual(S.current_plan(self.mom)[0], "child")
        for _ in range(15):
            self.assertTrue(S.charge(self.mom, "location_request", child=self.kid)["ok"])
        self.assertFalse(S.charge(self.mom, "location_request", child=self.kid)["ok"])
        # the second child is not on the Child Plan -> the free allowance
        r = S.charge(self.mom, "location_request", child=self.kid2)
        self.assertEqual(r["plan"], "free")
        self.assertEqual(S.max_guardians(self.kid), 2)

    def test_journey_request_charges_live_trip_and_refunds_on_error(self):
        p = on()
        self.addCleanup(p.stop)
        self.assertEqual(SP.action_cost(S.cfg(), "live_trip"), 3)
        r = S.charge(self.mom, "live_trip", child=self.kid)
        self.assertTrue(r["ok"])
        self.assertEqual(S.status(self.mom)["balance"]["monthly"], 0)
        S.refund_charge(self.mom, r)
        self.assertEqual(S.status(self.mom)["balance"]["monthly"], 3)

    def test_never_postpaid(self):
        p = on()
        self.addCleanup(p.stop)
        for _ in range(3):
            S.charge(self.mom, "location_request")
        self.assertFalse(S.charge(self.mom, "live_trip")["ok"])
        self.assertEqual(S.status(self.mom)["balance"]["total"], 0)
        self.assertEqual(S.get_state(self.mom)["used"], 3)     # no negative balance


class SchoolTests(TestCase):
    def setUp(self):
        cache.clear()
        self.mom = mk("01712300001", "Mom")
        self.kid = mk("01712300002", "Kid")
        self.staff = mk("01712300003", "Teacher")
        link_child(self.mom, self.kid)
        from core import billing
        row = billing.get_config()
        d = dict(row.data or {})
        d["safe_plans"] = {"schools": {"SUNBEAM1": {
            "name": "Sunbeam", "students": 120, "admin_ids": [self.staff.pk],
            "driver_ids": [self.staff.pk], "active": True}}}
        row.data = d
        row.save()
        self.p = on()
        self.addCleanup(self.p.stop)

    def test_code_unlocks_four_guardians_ten_requests_and_tools(self):
        api = cl(self.mom)
        r = api.post(V + "/safe-plans/school/redeem", {"code": "sunbeam1",
                                                       "child_id": self.kid.pk}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(S.school_for_child(self.kid.pk), "SUNBEAM1")
        self.assertEqual(S.max_guardians(self.kid), 4)
        for _ in range(13):     # 10 school + 3 free
            self.assertTrue(S.charge(self.mom, "location_request", child=self.kid)["ok"])
        self.assertFalse(S.charge(self.mom, "location_request", child=self.kid)["ok"])
        # school staff: attendance (times only) + broadcast; parents read the bus
        sc = cl(self.staff)
        a = sc.get(V + "/safe-plans/school/SUNBEAM1/attendance").json()
        self.assertEqual(a["students"], 1)
        self.assertNotIn("lat", str(a))
        with mock.patch("core.push.safe_push", return_value=True) as push:
            b = sc.post(V + "/safe-plans/school/SUNBEAM1/broadcast", {"text": "Closed tomorrow"},
                        format="json").json()
        self.assertEqual((b["parents"], b["sent"]), (1, 1))
        self.assertEqual(push.call_args[0][0], self.mom)
        sc.post(V + "/safe-plans/school/SUNBEAM1/bus", {"lat": 23.8, "lng": 90.4}, format="json")
        bus = api.get(V + "/safe-plans/school/SUNBEAM1/bus").json()["bus"]
        self.assertEqual(bus["lat"], 23.8)
        # a parent is not school staff
        self.assertEqual(api.get(V + "/safe-plans/school/SUNBEAM1/attendance").status_code, 404)

    def test_bad_code_and_not_your_child(self):
        api = cl(self.mom)
        r = api.post(V + "/safe-plans/school/redeem", {"code": "NOPE99", "child_id": self.kid.pk},
                     format="json")
        self.assertEqual(r.json()["reason"], "bad_code")
        other = mk("01712300009", "Other")
        r = api.post(V + "/safe-plans/school/redeem", {"code": "SUNBEAM1", "child_id": other.pk},
                     format="json")
        self.assertEqual(r.json()["reason"], "not_your_child")

    def test_app_never_sees_the_school_price(self):
        st = cl(self.mom).get(V + "/safe-plans").json()
        self.assertNotIn("price_bdt", st["plans"]["school"])


# ------------------------------------------------------------------ Play
class SafePlayTests(PlayBase):
    def setUp(self):
        super().setUp()
        cache.clear()

    def test_child_plan_subscription_verified_acknowledged_once(self):
        self.g.subs["sc1"] = sub_body(self.u, product="safe_child", base_plan="monthly",
                                      price_units="30")
        r = self.verify("sc1", product="safe_child")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertTrue(r.json()["entitled"])
        self.assertEqual(r.json()["plan"], "child")
        self.assertEqual(self.g.acks, ["sc1"])
        self.verify("sc1", product="safe_child")
        from core.models import PaymentEvent
        self.assertEqual(PaymentEvent.objects.filter(kind="play.charge").count(), 1)
        self.assertEqual(S.current_plan(self.u)[0], "child")
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "free")           # not the app's Premium
        self.assertIsNone(play.sub_status(self.u))

    def test_pack_purchase_granted_once_consumed_and_refund_removes_rest(self):
        self.g.products["pk1"] = {"purchaseState": 0, "consumptionState": 0,
                                  "orderId": "GPA.5555-1", "acknowledgementState": 0,
                                  "obfuscatedExternalAccountId": play.account_id(self.u)}
        r = self.verify("pk1", kind="pack", product="safe_req_10")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["granted"], 10)
        self.assertEqual(self.g.consumed, ["pk1"])
        r = self.verify("pk1", kind="pack", product="safe_req_10")
        self.assertEqual(r.json()["granted"], 0)        # once per token
        self.assertEqual(S.status(self.u)["balance"]["packs"], 10)
        with mock.patch("core.safe_plans.feature_on", return_value=True):
            for _ in range(5):                          # 3 free + 2 from the pack
                self.assertTrue(S.charge(self.u, "location_request")["ok"])
        self.assertEqual(S.status(self.u)["balance"]["packs"], 8)
        play.revoke_token("pk1", "refund")
        self.assertEqual(S.status(self.u)["balance"]["packs"], 0)

    def test_pending_pack_grants_nothing(self):
        self.g.products["pk2"] = {"purchaseState": 2, "consumptionState": 0,
                                  "obfuscatedExternalAccountId": play.account_id(self.u)}
        r = self.verify("pk2", kind="pack", product="safe_req_10")
        self.assertEqual(r.json()["state"], "pending")
        self.assertEqual(S.status(self.u)["balance"]["packs"], 0)


# ------------------------------------------------------------------ ads
class AdUnlockTests(TestCase):
    def setUp(self):
        cache.clear()
        self.mom = mk("01712400001", "Mom")
        self.kid = mk("01712400002", "Kid")
        link_child(self.mom, self.kid)
        for target in ("core.safe_plans.feature_on", "core.sponsor_service.admob_real",
                       "core.billing.flag_on"):
            p = mock.patch(target, return_value=True)
            p.start()
            self.addCleanup(p.stop)
        from core import photo_studio_service as PSS
        from .tests_admob import _KID, _PEM
        k = mock.patch.object(PSS, "_ssv_keys", return_value={_KID: _PEM})
        k.start()
        self.addCleanup(k.stop)

    def _watch(self, user, goal, txn):
        from .tests_admob import _ssv
        t = cl(user).post(V + "/safe-plans/ad/ticket", {"goal": goal}, format="json").json()
        self.assertTrue(t["ok"], t)
        r = Client().get(V + "/ads/ssv?" + _ssv(t["nonce"], str(user.pk), txn))
        self.assertEqual(r.status_code, 200)
        return t

    def test_child_accounts_never_get_ads(self):
        r = cl(self.kid).post(V + "/safe-plans/ad/ticket", {"goal": "request"},
                              format="json").json()
        self.assertFalse(r["ok"])
        self.assertEqual(r["reason"], "child_account")
        self.assertFalse(PhotoAdTicket.objects.filter(user=self.kid).exists())
        self.assertFalse(S.status(self.kid)["ads"]["eligible"])

    def test_non_guardian_gets_no_ads(self):
        x = mk("01712400009", "Stranger")
        r = cl(x).post(V + "/safe-plans/ad/ticket", {"goal": "day"}, format="json").json()
        self.assertEqual(r["reason"], "not_guardian")

    def test_three_ads_one_request_only_on_google_signature(self):
        self._watch(self.mom, "request", "tx1")
        self._watch(self.mom, "request", "tx2")
        self.assertEqual(S.status(self.mom)["balance"]["ads"], 0)
        t = self._watch(self.mom, "request", "tx3")
        self.assertEqual(S.status(self.mom)["balance"]["ads"], 1)
        # replayed transaction counts nothing
        from .tests_admob import _ssv
        Client().get(V + "/ads/ssv?" + _ssv(t["nonce"], str(self.mom.pk), "tx3"))
        self.assertEqual(S.status(self.mom)["balance"]["ads"], 1)
        st = cl(self.mom).get(V + "/safe-plans/ad/ticket/%s" % t["nonce"]).json()
        self.assertTrue(st["credited"])
        rep = S.admin_report()
        self.assertEqual((rep["ads_verified"], rep["unlocks_request"]), (3, 1))

    def test_three_ads_one_day_of_child_plan_then_cap(self):
        for i in range(3):
            self._watch(self.mom, "day", "d%d" % i)
        plan, src, _ = S.current_plan(self.mom)
        self.assertEqual((plan, src), ("child", "ads"))
        r = cl(self.mom).post(V + "/safe-plans/ad/ticket", {"goal": "day"}, format="json").json()
        self.assertEqual(r["reason"], "capped")         # 1 day pass per day


# ------------------------------------------------------------------ PART 5 / 7 guards
class AlwaysFreeGuardTests(TestCase):
    def test_sos_reaches_guardian_with_zero_credits_and_switch_on(self):
        mom, kid = mk("01712500001", "Mom"), mk("01712500002", "Kid")
        link_child(mom, kid)
        CircleMember.objects.filter(user=kid).update(sharing={"location": True})
        with mock.patch("core.safe_plans.feature_on", return_value=True):
            for _ in range(3):
                S.charge(mom, "location_request")
            self.assertFalse(S.charge(mom, "location_request")["ok"])
            with mock.patch("core.push.safe_push", return_value=True) as push:
                r = cl(kid).post(V + "/family/sos", {"lat": 23.7, "lng": 90.4}, format="json")
        self.assertIn(r.status_code, (200, 201), r.content)
        self.assertIn(mom.pk, [c[0][0].pk for c in push.call_args_list])

    def test_sos_danger_school_code_never_calls_charge(self):
        core = ROOT / "backend" / "core"
        for rel in ("family_alerts.py", "kidswatch_service.py", "logic/sos_ladder.py",
                    "logic/school_mode.py", "guardian_journey.py", "journey_watch.py"):
            src = (core / rel).read_text()
            self.assertNotIn("safe_plans", src, rel)

    def test_privacy_draft_has_never_sell_line(self):
        txt = (ROOT / "owner_actions" / "PRIVACY_UPDATE_DRAFT_BN.md").read_text()
        self.assertIn("We never sell location data.", txt)
        self.assertIn("আমরা কখনো লোকেশন ডেটা বিক্রি করি না", txt)


from web.tests_o2_owner_admin import OwnerBase  # noqa: E402


class SafePlansOwnerPageTests(OwnerBase):
    def test_page_shows_profit_products_and_saves_school(self):
        self.ready()
        r = self.c.get("/owner/safe-plans")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn('id="safe-profit"', html)
        self.assertIn("safe_req_10", html)
        self.assertIn("safe_family", html)
        self.assertIn("নিরাপত্তা প্ল্যান", html)

    def test_needs_login(self):
        r = self.c.get("/owner/safe-plans")
        self.assertIn(r.status_code, (302, 403))
