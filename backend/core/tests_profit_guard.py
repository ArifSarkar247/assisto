"""Profit Guard / NET-margin guarantee — thorough tests (a1-priority).

Pure engine (core.logic.pricing + core.logic.profit_guard): every action holds
the NET floor, the included-pool cap, the auto-reprice helper, the trailing
guard state machine, and edge cases (zero cost, fee/FX changes, garbage rows).
Plus the stateful layer (billing.charge/guard_can) reading the admin-editable
thresholds. The annual-plan margin check is owned by slot a6 (not here)."""
import math

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import pricing as P
from core.logic import profit_guard as PG
from core.models import User


def _cost_bdt(c, aid):
    return c["action_costs"][aid]["provider_cost"] * c["usd_bdt"]


def _face_bdt(c, aid):
    return c["action_costs"][aid]["credits"] * c["credit_bdt"]


class ActionFloorTests(SimpleTestCase):
    def test_every_default_action_holds_net_floor(self):
        c = P.normalize(P.DEFAULTS())
        floor = c["guarantees"]["margin_net_floor"]
        for aid in c["action_costs"]:
            with self.subTest(action=aid):
                # cost must be <= floor share of the face value we charge
                self.assertLessEqual(_cost_bdt(c, aid), floor * _face_bdt(c, aid) + 1e-9)
                self.assertGreaterEqual(c["action_costs"][aid]["credits"],
                                        P.action_credit_floor(aid, c))

    def test_floor_formula(self):
        c = P.normalize({})
        for aid, row in c["action_costs"].items():
            with self.subTest(action=aid):
                if row["provider_cost"] <= 0:
                    self.assertEqual(P.action_credit_floor(aid, c), 0)
                else:
                    want = max(1, math.ceil(row["provider_cost"] * c["usd_bdt"] / 0.60
                                            / c["credit_bdt"] - 1e-12))
                    self.assertEqual(P.action_credit_floor(aid, c), want)

    def test_one_credit_below_floor_is_refused(self):
        for aid in ("ai_msg_cheap", "ai_msg_medium", "ai_msg_strong", "scan_ocr",
                    "ivr_call", "voice_clone"):
            c = P.DEFAULTS()
            fl = P.action_credit_floor(aid, c)
            c["action_costs"][aid]["credits"] = fl - 1
            with self.subTest(action=aid):
                self.assertIn("action_breaks_margin", P.validate_edit(c))
            c["action_costs"][aid]["credits"] = fl
            with self.subTest(action=aid, at_floor=True):
                self.assertNotIn("action_breaks_margin", P.validate_edit(c))

    def test_custom_owner_action_also_guarded(self):
        c = P.DEFAULTS()
        c["action_costs"]["new_thing"] = {"provider_cost": 0.05, "credits": 1}
        self.assertIn("action_breaks_margin", P.validate_edit(c))
        c["action_costs"]["new_thing"]["credits"] = P.action_credit_floor("new_thing", c)
        self.assertEqual(P.validate_edit(c), [])

    def test_unknown_action_costs_nothing(self):
        c = P.DEFAULTS()
        self.assertEqual(P.credit_cost("nope", c), 0)
        self.assertEqual(P.action_credit_floor("nope", c), 0)
        self.assertEqual(P.recompute_from_provider_cost("nope", c), 0)
        self.assertEqual(P.credits_for("ai_msg_strong", 0, c), P.credit_cost("ai_msg_strong", c))


class ZeroCostTests(SimpleTestCase):
    def test_zero_cost_action_has_no_floor_and_keeps_owner_price(self):
        c = P.DEFAULTS()
        self.assertEqual(c["action_costs"]["shop_extra_camera"]["provider_cost"], 0.0)
        self.assertEqual(P.action_credit_floor("shop_extra_camera", c), 0)
        self.assertEqual(P.recompute_from_provider_cost("shop_extra_camera", c), 0)
        out = P.recompute_all(c)
        self.assertEqual(out["action_costs"]["shop_extra_camera"]["credits"], 20)
        c["action_costs"]["shop_extra_camera"]["credits"] = 0     # owner may make it free
        self.assertEqual(P.validate_edit(c), [])

    def test_all_zero_costs_never_blocks(self):
        c = P.DEFAULTS()
        for row in c["action_costs"].values():
            row["provider_cost"] = 0.0
        self.assertNotIn("action_breaks_margin", P.validate_edit(c))

    def test_free_plan_zero_price_has_no_pool_cap(self):
        c = P.normalize({})
        self.assertEqual(P.net_plan_revenue("free", c), 0.0)
        bad = P.DEFAULTS()
        bad["plans"]["free"]["credits"] = 50      # net == 0 -> pool cap not applied
        self.assertNotIn("pool_exceeds_net", P.validate_edit(bad))


class PoolCapTests(SimpleTestCase):
    def test_default_pools_within_cap(self):
        c = P.normalize({})
        for pid, row in c["plans"].items():
            with self.subTest(plan=pid):
                net = P.net_plan_revenue(pid, c)
                self.assertLessEqual(row["credits"] * c["credit_bdt"], 0.60 * net + 1e-9)

    def test_pool_cap_boundary(self):
        c = P.DEFAULTS()
        limit = math.floor(0.60 * P.net_plan_revenue("business", c))   # 248
        c["plans"]["business"]["credits"] = limit
        self.assertNotIn("pool_exceeds_net", P.validate_edit(c))
        c["plans"]["business"]["credits"] = limit + 1
        self.assertIn("pool_exceeds_net", P.validate_edit(c))

    def test_price_cut_breaks_pool(self):
        c = P.DEFAULTS()
        c["plans"]["premium"]["price"] = 99      # NET 82.2 -> cap 49 < pool 90
        self.assertIn("pool_exceeds_net", P.validate_edit(c))

    def test_editable_pool_cap(self):
        c = P.DEFAULTS()
        c["guarantees"] = {"pool_cap_pct_of_net": 0.30}    # tighter
        self.assertIn("pool_exceeds_net", P.validate_edit(c))
        c["guarantees"] = {"pool_cap_pct_of_net": 1.0}
        c["plans"]["premium"]["credits"] = 150
        self.assertNotIn("pool_exceeds_net", P.validate_edit(c))


class FeeAndFxChangeTests(SimpleTestCase):
    def test_store_fee_rise_shrinks_net_and_trips_pool_cap(self):
        c = P.DEFAULTS()
        c["play_fee"] = 0.30                           # NET 0.68
        self.assertAlmostEqual(P.net_fraction(c), 0.68)
        # business pool 240 > 0.60 * 499 * 0.68 = 203.6
        self.assertIn("pool_exceeds_net", P.validate_edit(c))

    def test_fee_change_does_not_move_action_floor(self):
        c0 = P.DEFAULTS()
        c1 = P.DEFAULTS()
        c1["gateway_fee"] = 0.10
        for aid in c0["action_costs"]:
            self.assertEqual(P.action_credit_floor(aid, c0), P.action_credit_floor(aid, c1))

    def test_fees_summing_to_one_or_out_of_range_refused(self):
        for patch in ({"play_fee": 0.6, "gateway_fee": 0.3, "vat": 0.1},
                      {"vat": 1.0}, {"play_fee": -0.1}):
            c = P.DEFAULTS()
            c.update(patch)
            with self.subTest(patch=patch):
                self.assertIn("bad_fee", P.validate_edit(c))
        c = P.normalize({"play_fee": 0.5, "gateway_fee": 0.45, "vat": 0.2})
        self.assertGreater(P.net_fraction(c), 0)        # clamped, never <= 0

    def test_fx_jump_breaks_margin_and_auto_reprice_fixes_it(self):
        c = P.DEFAULTS()
        c["usd_bdt"] = 240.0                          # taka halves
        self.assertIn("action_breaks_margin", P.validate_edit(c))
        fixed = P.recompute_all(c)
        self.assertNotIn("action_breaks_margin", P.validate_edit(fixed))

    def test_provider_cost_spike_then_reprice(self):
        c = P.DEFAULTS()
        c["action_costs"]["ai_msg_strong"]["provider_cost"] = 0.20
        self.assertIn("action_breaks_margin", P.validate_edit(c))
        new = P.recompute_from_provider_cost("ai_msg_strong", c)
        self.assertEqual(new, max(math.ceil(0.20 * 120 * 1.40), math.ceil(0.20 * 120 / 0.60)))
        self.assertEqual(new, 40)


class AutoRepriceTests(SimpleTestCase):
    def test_reprice_holds_both_margin_and_floor(self):
        c = P.normalize(P.DEFAULTS())
        for aid, row in c["action_costs"].items():
            if row["provider_cost"] <= 0:
                continue
            n = P.recompute_from_provider_cost(aid, c)
            with self.subTest(action=aid):
                self.assertGreaterEqual(n, P.action_credit_floor(aid, c))
                self.assertGreaterEqual(n * c["credit_bdt"],
                                        _cost_bdt(c, aid) * (1 + c["margin"]) - 1e-9)
                self.assertGreaterEqual(n, 1)

    def test_recompute_all_is_valid_idempotent_and_pure(self):
        c = P.DEFAULTS()
        snapshot = repr(c)
        once = P.recompute_all(c)
        self.assertEqual(repr(c), snapshot)                 # input untouched
        self.assertEqual(P.validate_edit(once), [])
        self.assertEqual(P.recompute_all(once)["action_costs"], once["action_costs"])
        self.assertEqual(once["plans"], P.normalize(c)["plans"])  # plans untouched

    def test_higher_margin_target_raises_price(self):
        c = P.DEFAULTS()
        c["action_costs"]["ivr_call"]["provider_cost"] = 0.05
        lo = P.recompute_from_provider_cost("ivr_call", c)
        c["margin"] = 2.0
        hi = P.recompute_from_provider_cost("ivr_call", c)
        self.assertGreater(hi, lo)

    def test_margin_below_target_refused(self):
        self.assertIn("margin_below_target", P.validate_edit({"margin": 0.2}))
        self.assertIn("margin_negative", P.validate_edit({"margin": -1}))


class GuardStateTests(SimpleTestCase):
    def rows(self, rev, cost):
        return [{"date": "2026-10-20", "revenue_by_source": {"subs": rev},
                 "variable_cost_by_type": {"ai": cost}}]

    def test_bootstrap_zero_revenue_never_blocks(self):
        st = PG.guard_state(self.rows(0, 50))
        self.assertEqual(st["state"], "ok")
        self.assertEqual(st["ratio"], float("inf"))
        self.assertEqual(PG.guard_state(self.rows(0, 0))["ratio"], 0.0)
        self.assertEqual(PG.guard_state([])["state"], "ok")

    def test_boundaries(self):
        # rev 1000 -> cap 600; near from 0.80*600 = 480
        self.assertEqual(PG.guard_state(self.rows(1000, 479.99))["state"], "ok")
        self.assertEqual(PG.guard_state(self.rows(1000, 480))["state"], "near")
        self.assertEqual(PG.guard_state(self.rows(1000, 600))["state"], "near")
        self.assertEqual(PG.guard_state(self.rows(1000, 600.01))["state"], "over")

    def test_custom_thresholds(self):
        self.assertEqual(PG.guard_state(self.rows(1000, 450), spend_cap_pct=0.40)["state"], "over")
        self.assertEqual(PG.guard_state(self.rows(1000, 100), approach_pct=0.1)["state"], "near")
        # spend cap 0 -> any cost is over
        self.assertEqual(PG.guard_state(self.rows(1000, 1), spend_cap_pct=0)["state"], "over")

    def test_sums_all_sources_and_types_over_trailing_rows(self):
        rows = [{"date": f"2026-10-{d:02d}",
                 "revenue_by_source": {"ads": 10, "subs": 100, "packs": 20, "commissions": 5},
                 "variable_cost_by_type": {"ai": 30, "sms": 5, "ivr": 2, "video": 1, "storage": 2}}
                for d in range(14, 21)]
        st = PG.guard_state(rows)
        self.assertEqual(st["rev7d"], 135 * 7)
        self.assertEqual(st["cost7d"], 40 * 7)
        self.assertEqual(st["state"], "ok")

    def test_garbage_rows_ignored(self):
        rows = [{"revenue_by_source": {"subs": "abc", "ads": True, "packs": None,
                                       "bogus": 999},
                 "variable_cost_by_type": "nope"}, None, {}]
        st = PG.guard_state(rows)
        self.assertEqual((st["rev7d"], st["cost7d"], st["state"]), (0.0, 0.0, "ok"))

    def test_cheaper_tier(self):
        self.assertEqual(PG.cheaper_tier("strong"), "medium")
        self.assertEqual(PG.cheaper_tier("medium"), "cheap")
        self.assertEqual(PG.cheaper_tier("cheap"), "cheap")
        self.assertEqual(PG.cheaper_tier(None), "cheap")
        self.assertEqual(PG.cheaper_tier("weird"), "cheap")


class GuardStatefulTests(APITestCase):
    def setUp(self):
        self.u = User.objects.create_user(name="F", phone="01710000801", password="pw")
        self.owner = User.objects.create_user(name="O", phone="01710000802", password="pw")
        self.owner.is_superuser = True
        self.owner.save()

    def _ledger(self, rev, cost):
        from core.models import DailyLedger
        DailyLedger.objects.update_or_create(
            date=timezone.localdate(),
            defaults={"revenue_by_source": {"subs": rev},
                      "variable_cost_by_type": {"ai": cost}})

    def _edit(self, patch):
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/pricing", {"config": patch}, format="json")
        self.assertEqual(r.status_code, 200, r.data)

    def test_admin_spend_cap_edit_takes_effect(self):
        from core import billing
        self._ledger(1000, 500)
        self.assertEqual(billing.guard_state()["state"], "near")
        self._edit({"profit_guard": {"spend_cap_pct": 0.40}})
        self.assertEqual(billing.guard_state()["state"], "over")
        self._edit({"profit_guard": {"spend_cap_pct": 0.90, "approach_pct": 0.95}})
        self.assertEqual(billing.guard_state()["state"], "ok")

    def test_over_blocks_free_preflight_and_charge_without_debit(self):
        from core import billing
        self.u.ai_credits = 30
        self.u.save()
        self._ledger(1000, 700)
        self.assertEqual(billing.guard_can(self.u, "ai_msg_cheap"), (False, "guard_over"))
        r = billing.charge(self.u, "ai_msg_cheap")
        self.assertEqual((r["ok"], r["reason"], r["charged"]), (False, "guard_over", 0))
        self.u.refresh_from_db()
        self.assertEqual(self.u.ai_credits, 30)

    def test_alert_text_uses_configured_cap(self):
        from core import billing
        from core.models import FamilyAlert
        self.u.ai_credits = 30
        self.u.save()
        self._edit({"profit_guard": {"spend_cap_pct": 0.50}})
        self._ledger(1000, 600)
        billing.charge(self.u, "ai_msg_cheap")
        a = FamilyAlert.objects.get(user=self.owner, kind="cost_guard")
        self.assertIn("50%", a.body)

    def test_safety_never_blocked_or_charged(self):
        from core import billing
        self._ledger(1000, 10_000)
        for action in ("sos", "sos_sms", "safe_journey", "anti_theft_alert",
                       "health_reminder", "elderly_checkin", "login_otp", "payment_bkash"):
            with self.subTest(action=action):
                r = billing.charge(self.u, action)
                self.assertEqual((r["ok"], r["charged"]), (True, 0))
                self.assertEqual(billing.guard_can(self.u, action), (True, "exempt"))

    def test_ok_state_charges_exact_config_price(self):
        from core import billing
        self.u.ai_credits = 30
        self.u.save()
        self._ledger(1000, 100)
        self._edit({"action_costs": {"scan_ocr": {"credits": 4}}})
        r = billing.charge(self.u, "scan_ocr", qty=2)
        self.assertEqual((r["ok"], r["charged"], r["balance"]), (True, 8, 22))

    def test_admin_refuses_loss_making_edit_end_to_end(self):
        self.client.force_authenticate(self.owner)
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"usd_bdt": 300}}, format="json")
        self.assertEqual(r.status_code, 400)
        self.assertIn("action_breaks_margin", r.data["problems"])
        # same edit with auto_reprice still fails validation first (alert mode is
        # the default; the owner must reprice explicitly) -> verify reprice path:
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"action_costs": {"ai_msg_strong": {"provider_cost": 0.05}}},
                              "auto_reprice": True}, format="json")
        self.assertEqual(r.status_code, 400)   # validated before reprice
