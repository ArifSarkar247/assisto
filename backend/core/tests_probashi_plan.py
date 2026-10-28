"""probashi-plan (owner decision 27 Oct): the expat family plan.

Seats (invite / accept / decline / remove / leave / transfer, cooldown,
one-seat-per-person anti-abuse), the SHARED pool (member spends only the
payer's plan bucket, per-member caps, ledger shows who, failed calls go
back), Premium + budget & remittance for live members, the Play lifecycle
(assisto_probashi monthly / annual -> plan, hold, refund), the monthly report
privacy, the flag, the catalog and the 40 % pricing rule."""
from datetime import timedelta
from decimal import Decimal
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.authtoken.models import Token
from rest_framework.test import APIClient

from core import billing, credits as CR, plans
from core import feature_flags as FF
from core import probashi_plan as PB
from core.logic import pricing as P
from core.logic import probashi_plan as L
from core.logic import probashi_pricing as PP
from core.models import (CircleMember, CreditLedger, FamilyAlert, FeatureFlag, InstallPing,
                         Journey, ProbashiReport, ProbashiSeat, User)
from core.payments import catalog

from .tests_pay1 import PlayBase, sub_body

_n = [0]


def _bd():
    _n[0] += 1
    return "0171%07d" % (6600000 + _n[0])


def flag(on=True, key="probashi_plan"):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def api(u):
    c = APIClient()
    c.credentials(HTTP_AUTHORIZATION="Token " + Token.objects.get_or_create(user=u)[0].key)
    return c


def mk(name, phone=None, plan=None, credits=0):
    u = User.objects.create_user(name=name, phone=phone or _bd(), password="x")
    if plan:
        u.plan, u.plan_until = plan, timezone.now() + timedelta(days=30)
    u.ai_credits = credits
    u.save()
    return u


def connect(a, b):
    now = timezone.now()
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                connected_at=now, relation="family")
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                connected_at=now, relation="family", direction="incoming")


class Base(TestCase):
    def setUp(self):
        FF.invalidate()
        flag(True)
        q = mock.patch("core.push.push_to_user", return_value=1)
        q.start()
        self.addCleanup(q.stop)
        self.addCleanup(FF.invalidate)
        self.payer = mk("Rahim", phone="+966501234567", plan="probashi")
        CR.settle(self.payer)
        self.payer.refresh_from_db()
        self.m = [mk("Ma"), mk("Bon"), mk("Bhai"), mk("Chacha"), mk("Mama")]
        for x in self.m:
            connect(self.payer, x)

    def seat(self, member, consent=None):
        s = PB.invite(self.payer, member.pk)
        return PB.respond(member, s.pk, True, consent or {})


class FlagAndEntryTests(Base):
    def test_flag_off_everything_hidden(self):
        flag(False)
        r = api(self.payer).get("/api/v1/probashi")
        self.assertEqual(r.status_code, 403)
        self.assertEqual(r.json()["error"], "feature_off")
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, self.m[0].pk)
        self.assertEqual(e.exception.code, "feature_off")
        # an existing seat gives nothing while the flag is off
        flag(True)
        self.seat(self.m[0])
        flag(False)
        self.assertEqual(plans.effective_plan(self.m[0]), "free")

    def test_registry(self):
        self.assertIn("probashi_plan", FF.KEYS)
        self.assertFalse(FF.default_row("probashi_plan")["enabled_all"])

    def test_overview_payer(self):
        r = api(self.payer).get("/api/v1/probashi", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.content)
        d = r.json()
        self.assertTrue(d["is_payer"])
        self.assertEqual(d["seats_max"], 4)
        self.assertEqual(d["pool"]["total"], 180)
        self.assertEqual(d["pool"]["left"], 180)
        self.assertEqual(len(d["benefits"]), 6)

    def test_candidates_reasons(self):
        abroad = mk("Abroad", phone="+971501234567")
        connect(self.payer, abroad)
        r = api(self.payer).get("/api/v1/probashi/candidates")
        rows = {c["id"]: c for c in r.json()["candidates"]}
        self.assertTrue(rows[self.m[0].pk]["eligible"])
        self.assertEqual(rows[abroad.pk]["reason"], "bd_phone_required")


class SeatTests(Base):
    def test_invite_needs_probashi_plan(self):
        free = mk("Free", phone="+447700900123")
        connect(free, self.m[0])
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(free, self.m[0].pk)
        self.assertEqual(e.exception.code, "not_probashi")

    def test_invite_rules(self):
        stranger = mk("Stranger")
        for target, code in ((self.payer, "self"), (stranger, "not_in_circle")):
            with self.assertRaises(PB.SeatError) as e:
                PB.invite(self.payer, target.pk)
            self.assertEqual(e.exception.code, code)
        abroad = mk("Abroad", phone="+60123456789")
        connect(self.payer, abroad)
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, abroad.pk)
        self.assertEqual(e.exception.code, "bd_phone_required")
        # one-sided circle edge is not enough
        half = mk("Half")
        CircleMember.objects.create(user=self.payer, peer_user=half, state="accepted")
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, half.pk)
        self.assertEqual(e.exception.code, "not_in_circle")

    def test_invite_accept_gives_premium_and_remittance(self):
        r = api(self.payer).post("/api/v1/probashi/seats", {"member_id": self.m[0].pk},
                                 format="json")
        self.assertEqual(r.status_code, 201, r.content)
        sid = r.json()["id"]
        self.assertEqual(plans.effective_plan(self.m[0]), "free")       # not before accepting
        self.assertTrue(FamilyAlert.objects.filter(user=self.m[0], kind="probashi").exists())
        r = api(self.m[0]).post("/api/v1/probashi/seats/%d/respond" % sid,
                                {"accept": True, "consent": {"journeys": True, "evil": True}},
                                format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["consent"], {"journeys": True, "sos": False, "budget": False,
                                               "reminders": False, "report": False})
        self.assertEqual(plans.effective_plan(self.m[0]), "premium")
        ent = plans.entitlements(self.m[0])
        self.assertFalse(ent["ads"])
        from core import entitlements_service as ES
        self.assertTrue(ES._paid_active(self.m[0]))
        self.assertFalse(FF.is_on("budget_remittance", self.m[1]))      # not a member
        self.assertTrue(FF.is_on("budget_remittance", self.m[0]))
        self.assertTrue(FF.is_on("budget_remittance", self.payer))

    def test_decline(self):
        s = PB.invite(self.payer, self.m[0].pk)
        s = PB.respond(self.m[0], s.pk, False)
        self.assertEqual(s.status, "declined")
        self.assertEqual(plans.effective_plan(self.m[0]), "free")
        with self.assertRaises(PB.SeatError):
            PB.respond(self.m[0], s.pk, True)

    def test_only_member_can_answer(self):
        s = PB.invite(self.payer, self.m[0].pk)
        with self.assertRaises(PB.SeatError) as e:
            PB.respond(self.m[1], s.pk, True)
        self.assertEqual(e.exception.code, "seat_not_found")

    def test_invite_expires(self):
        s = PB.invite(self.payer, self.m[0].pk)
        ProbashiSeat.objects.filter(pk=s.pk).update(invited_at=timezone.now() - timedelta(days=8))
        with self.assertRaises(PB.SeatError) as e:
            PB.respond(self.m[0], s.pk, True)
        self.assertEqual(e.exception.code, "not_pending")

    def test_four_seats_then_full_and_cooldown(self):
        seats = [self.seat(x) for x in self.m[:4]]
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, self.m[4].pk)
        self.assertEqual(e.exception.code, "seats_full")
        PB.remove(self.payer, seats[0].pk)
        self.assertEqual(plans.effective_plan(self.m[0]), "free")
        # the removed seat holds its slot for the cooldown
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, self.m[4].pk)
        self.assertEqual(e.exception.code, "seats_full")
        self.assertIsNotNone(e.exception.extra.get("free_at"))
        ProbashiSeat.objects.filter(pk=seats[0].pk).update(
            ended_at=timezone.now() - timedelta(days=31))
        self.assertEqual(PB.invite(self.payer, self.m[4].pk).status, "invited")

    def test_three_seats_when_owner_picks_three(self):
        row = billing.get_config()
        d = dict(row.data or {})
        d["probashi_plan"] = {"seats": 3}
        row.data = d
        row.save()
        for x in self.m[:3]:
            self.seat(x)
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, self.m[3].pk)
        self.assertEqual(e.exception.code, "seats_full")

    def test_cancel_invite_frees_slot_at_once(self):
        for x in self.m[:3]:
            self.seat(x)
        s = PB.invite(self.payer, self.m[3].pk)
        PB.remove(self.payer, s.pk)
        self.assertEqual(ProbashiSeat.objects.get(pk=s.pk).status, "expired")
        self.assertEqual(PB.invite(self.payer, self.m[4].pk).status, "invited")

    def test_one_seat_per_person_anywhere(self):
        self.seat(self.m[0])
        other = mk("Other", phone="+97455123456", plan="probashi")
        connect(other, self.m[0])
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(other, self.m[0].pk)
        self.assertEqual(e.exception.code, "person_seated")

    def test_same_device_new_account_cannot_hop(self):
        InstallPing.objects.create(id_hash="i1", device_hash="dev-abc", user=self.m[0])
        s = self.seat(self.m[0])
        PB.leave(self.m[0], s.pk)
        # a NEW account on the same device joins another family: refused
        twin = mk("Twin")
        InstallPing.objects.create(id_hash="i2", device_hash="dev-abc", user=twin)
        other = mk("Other", phone="+6581234567", plan="probashi")
        connect(other, twin)
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(other, twin.pk)
        self.assertEqual(e.exception.code, "person_cooldown")

    def test_leave_by_member(self):
        s = self.seat(self.m[0])
        r = api(self.m[0]).post("/api/v1/probashi/seats/%d/leave" % s.pk)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.json()["status"], "left")
        self.assertEqual(plans.effective_plan(self.m[0]), "free")
        self.assertTrue(FamilyAlert.objects.filter(user=self.payer, kind="probashi").exists())

    def test_transfer_once_per_window(self):
        a = self.seat(self.m[0])
        new = PB.transfer(self.payer, a.pk, self.m[1].pk)
        self.assertEqual(new.status, "invited")
        self.assertEqual(ProbashiSeat.objects.get(pk=a.pk).status, "transferred")
        PB.respond(self.m[1], new.pk, True)
        with self.assertRaises(PB.SeatError) as e:
            PB.transfer(self.payer, new.pk, self.m[2].pk)
        self.assertEqual(e.exception.code, "transfer_limit")

    def test_failed_transfer_keeps_the_seat(self):
        a = self.seat(self.m[0])
        stranger = mk("Stranger")
        with self.assertRaises(PB.SeatError):
            PB.transfer(self.payer, a.pk, stranger.pk)
        self.assertEqual(ProbashiSeat.objects.get(pk=a.pk).status, "active")

    def test_member_cannot_be_a_probashi_payer(self):
        rich = mk("Rich", plan="probashi")
        connect(self.payer, rich)
        with self.assertRaises(PB.SeatError) as e:
            PB.invite(self.payer, rich.pk)
        self.assertEqual(e.exception.code, "member_is_payer")


class PoolTests(Base):
    def test_member_spends_pool_with_ledger(self):
        self.seat(self.m[0])
        res = billing.charge(self.m[0], "ai_msg_cheap", note="chat")
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["reason"], "family_pool")
        self.assertTrue(res["spend_ref"].startswith("fam:%d:" % self.payer.pk))
        row = CreditLedger.objects.filter(user=self.payer, reason="consume").latest("id")
        self.assertEqual(row.source_type, "fam:%d" % self.m[0].pk)
        self.assertEqual(row.bucket, "plan")
        self.assertEqual(PB.member_used(self.payer, self.m[0].pk), 1)
        self.assertEqual(PB.pool_left(self.payer), 179)
        self.assertTrue(CR.verify(self.payer)["ok"])
        led = PB.pool_ledger(self.payer, "en")
        self.assertEqual(led["rows"][0]["who"], "Ma")
        self.assertEqual(led["per_member"][0]["used"], 1)

    def test_own_credits_first(self):
        self.seat(self.m[0])
        self.m[0].ai_credits = 5
        self.m[0].save()
        CR.settle(self.m[0])
        res = billing.charge(self.m[0], "ai_msg_cheap", note="chat")
        self.assertNotEqual(res["reason"], "family_pool")
        self.assertEqual(PB.member_used(self.payer, self.m[0].pk), 0)

    def test_cap_enforced_and_guard_agrees(self):
        s = self.seat(self.m[0])
        r = api(self.payer).post("/api/v1/probashi/seats/%d/cap" % s.pk, {"cap": 2}, format="json")
        self.assertEqual(r.json()["monthly_cap"], 2)
        self.assertTrue(billing.charge(self.m[0], "ai_msg_cheap")["ok"])
        self.assertTrue(billing.guard_can(self.m[0], "ai_msg_cheap")[0])
        self.assertTrue(billing.charge(self.m[0], "ai_msg_cheap")["ok"])
        self.assertFalse(billing.guard_can(self.m[0], "ai_msg_cheap")[0])
        res = billing.charge(self.m[0], "ai_msg_cheap")
        self.assertFalse(res["ok"])
        self.assertEqual(res["reason"], "family_cap")
        self.assertEqual(PB.pool_left(self.payer), 178)

    def test_bad_cap(self):
        s = self.seat(self.m[0])
        for v in (-1, "x", None):
            with self.assertRaises(PB.SeatError):
                PB.set_cap(self.payer, s.pk, v)
        self.assertEqual(PB.set_cap(self.payer, s.pk, 99999).monthly_cap, 180)

    def test_members_never_touch_payer_packs(self):
        self.seat(self.m[0])
        PB.set_cap(self.payer, ProbashiSeat.objects.get(member=self.m[0]).pk, 180)
        CR.grant(self.payer, CR.PACK, 50, reason="topup", source_type="pack", source_id="p50")
        for _ in range(180):
            self.assertTrue(billing.charge(self.m[0], "ai_msg_cheap")["ok"])
        res = billing.charge(self.m[0], "ai_msg_cheap")
        self.assertFalse(res["ok"])
        self.payer.refresh_from_db()
        self.assertEqual(CR.buckets(self.payer)["pack"], 50)

    def test_failed_call_returns_to_payer(self):
        self.seat(self.m[0])
        res = billing.charge(self.m[0], "ai_msg_cheap", note="chat")
        billing.credit(self.m[0], "adjust", 1, note="ai_refund", spend_ref=res["spend_ref"])
        self.assertEqual(PB.pool_left(self.payer), 180)
        self.assertEqual(PB.member_used(self.payer, self.m[0].pk), 0)
        self.assertTrue(CR.verify(self.payer)["ok"])
        self.assertEqual(int(self.m[0].ai_credits or 0), 0)

    def test_pool_not_cash_no_withdraw_endpoint(self):
        from django.urls import get_resolver
        names = [str(p.pattern) for p in get_resolver().url_patterns]
        flat = " ".join(names)
        self.assertNotIn("probashi/withdraw", flat)


class LifecycleTests(Base):
    def test_lapse_pauses_and_return_restores(self):
        self.seat(self.m[0])
        self.assertEqual(plans.effective_plan(self.m[0]), "premium")
        User.objects.filter(pk=self.payer.pk).update(plan_until=timezone.now() - timedelta(days=1))
        self.assertEqual(plans.effective_plan(self.m[0]), "free")
        self.assertIsNone(billing.charge(self.m[0], "ai_msg_cheap").get("spend_ref") or None)
        User.objects.filter(pk=self.payer.pk).update(plan_until=timezone.now() + timedelta(days=30))
        self.assertEqual(plans.effective_plan(self.m[0]), "premium")

    def test_close_lapsed_after_30_days_no_cooldown(self):
        s = self.seat(self.m[0])
        User.objects.filter(pk=self.payer.pk).update(plan_until=timezone.now() - timedelta(days=31))
        out = PB.close_lapsed()
        self.assertEqual(out["closed"], 1)
        s.refresh_from_db()
        self.assertEqual((s.status, s.counts_cooldown), ("expired", False))

    def test_on_plan_change_tells_members(self):
        self.seat(self.m[0])
        n = PB.on_plan_change(self.payer, "probashi", "free")
        self.assertEqual(n, 1)
        self.assertEqual(PB.on_plan_change(self.payer, "premium", "free"), 0)


class PlayLifecycleTests(PlayBase):
    def setUp(self):
        super().setUp()
        flag(True)
        self.addCleanup(FF.invalidate)
        self.mem = mk("Ma")
        connect(self.u, self.mem)

    def test_probashi_sub_monthly_and_annual(self):
        self.g.subs["pt"] = sub_body(self.u, product="assisto_probashi", base_plan="monthly")
        r = self.verify("pt", product="assisto_probashi")
        self.assertEqual(r.status_code, 200, r.content)
        self.u.refresh_from_db()
        self.assertEqual(self.u.plan, "probashi")
        # the pool is the plan allowance (staged unlock applies like any plan)
        lots = CR.buckets(self.u)
        self.assertGreater(lots["plan"], 0)
        self.assertLessEqual(lots["plan"], 180)
        self.assertEqual(catalog.sku_for_play("assisto_probashi", "annual"), "probashi_yearly")

        s = PB.invite(self.u, self.mem.pk)
        PB.respond(self.mem, s.pk, True)
        self.assertEqual(plans.effective_plan(self.mem), "premium")
        # on hold: benefits stop at once, members told
        self.g.subs["pt"] = sub_body(self.u, product="assisto_probashi",
                                     state="SUBSCRIPTION_STATE_ON_HOLD", expiry_days=-1)
        self.verify("pt", product="assisto_probashi")
        self.u.refresh_from_db()
        self.assertNotEqual(self.u.plan, "probashi")
        self.assertEqual(plans.effective_plan(self.mem), "free")
        self.assertTrue(FamilyAlert.objects.filter(user=self.mem, title__contains="বন্ধ").exists())
        # payment fixed: back again, the seat was kept
        self.g.subs["pt"] = sub_body(self.u, product="assisto_probashi",
                                     order="GPA.3300-0000-0000-00001")
        self.verify("pt", product="assisto_probashi")
        self.assertEqual(plans.effective_plan(self.mem), "premium")

    def test_annual_ten_times_credits(self):
        from core.models import CreditLot
        self.assertEqual(CR.plan_credits("probashi"), 180)
        self.assertEqual(CR.plan_credits("probashi", months=12), 150)
        self.g.subs["at"] = sub_body(self.u, product="assisto_probashi", base_plan="annual",
                                     expiry_days=365, order="GPA.3300-0000-0000-00777")
        r = self.verify("at", product="assisto_probashi")
        self.assertEqual(r.status_code, 200, r.content)
        lots = CreditLot.objects.filter(user=self.u, bucket="plan", source_type="play")
        total = sum(l.granted for l in lots)                     # 10 x 180, 150 a month
        self.assertTrue(1780 <= total <= 1801, total)            # Google's 365-day end vs 12 calendar months
        self.assertTrue(all(l.granted <= 150 for l in lots))

    def test_grace_keeps_benefits(self):
        self.g.subs["pt"] = sub_body(self.u, product="assisto_probashi")
        self.verify("pt", product="assisto_probashi")
        self.u.refresh_from_db()
        s = PB.invite(self.u, self.mem.pk)
        PB.respond(self.mem, s.pk, True)
        self.g.subs["pt"] = sub_body(self.u, product="assisto_probashi",
                                     state="SUBSCRIPTION_STATE_IN_GRACE_PERIOD", expiry_days=3)
        self.verify("pt", product="assisto_probashi")
        self.assertEqual(plans.effective_plan(self.mem), "premium")

    def test_refund_revokes_family(self):
        from core.payments import entitlement as E
        from core.payments import play
        self.g.subs["pt"] = sub_body(self.u, product="assisto_probashi")
        self.verify("pt", product="assisto_probashi")
        self.u.refresh_from_db()
        s = PB.invite(self.u, self.mem.pk)
        PB.respond(self.mem, s.pk, True)
        E.revoke_period("play", play.ref_for("pt"), reason="refund")
        self.u.refresh_from_db()
        self.assertEqual(plans.effective_plan(self.mem), "free")
        self.assertEqual(CR.buckets(self.u)["plan"], 0)

    def test_not_sold_on_gateway(self):
        self.assertIsNone(catalog.price("probashi_monthly", "gateway"))
        self.assertNotIn("probashi_monthly", catalog.all_skus())
        self.assertNotIn("probashi_monthly", [p["sku"] for p in catalog.products("play")])


class ReportPrivacyTests(Base):
    def test_report_only_consented_sections(self):
        a = self.seat(self.m[0], {"report": True, "journeys": True, "budget": True})
        self.seat(self.m[1], {"journeys": True})          # no report consent
        Journey.objects.create(traveller=self.m[0], status="arrived")
        Journey.objects.create(traveller=self.m[1], status="arrived")
        now = timezone.now()
        made = PB.build_report(self.payer, now, now)
        self.assertEqual(made, 3)
        self.assertEqual(PB.build_report(self.payer, now, now), 0)       # idempotent
        rep = ProbashiReport.objects.get(recipient=self.payer)
        names = [s["member"]["name"] for s in rep.payload["sections"]]
        self.assertEqual(names, ["Ma"])
        lines = rep.payload["sections"][0]["lines"]["bn"]
        self.assertTrue(any("নিরাপদ যাত্রা" in x for x in lines))
        self.assertTrue(any("৳" in x for x in lines))
        # each member gets their OWN copy
        own = ProbashiReport.objects.get(recipient=self.m[1])
        self.assertEqual(own.payload["sections"][0]["member"]["name"], "Bon")
        r = api(self.payer).get("/api/v1/probashi/reports", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200)
        self.assertIn("Safe Journeys", " ".join(r.json()["reports"][0]["sections"][0]["lines"]))
        self.assertTrue(FamilyAlert.objects.filter(user=self.payer, kind="probashi_report").exists())
        self.assertIsNotNone(a)

    def test_dashboard_respects_consent(self):
        self.seat(self.m[0], {"journeys": True})
        self.seat(self.m[1], {})
        Journey.objects.create(traveller=self.m[1], status="arrived")
        d = api(self.payer).get("/api/v1/probashi/family").json()
        by = {x["member"]["name"]: x for x in d["members"]}
        self.assertIn("journeys", by["Ma"])
        self.assertNotIn("journeys", by["Bon"])
        self.assertNotIn("money", by["Bon"])
        self.assertNotIn("safety", by["Bon"])
        self.assertFalse(by["Bon"]["location_sharing"])

    def test_member_can_change_consent(self):
        s = self.seat(self.m[0], {})
        r = api(self.m[0]).post("/api/v1/probashi/seats/%d/consent" % s.pk,
                                {"consent": {"sos": True}}, format="json")
        self.assertTrue(r.json()["consent"]["sos"])
        r = api(self.payer).post("/api/v1/probashi/seats/%d/consent" % s.pk,
                                 {"consent": {"budget": True}}, format="json")
        self.assertEqual(r.status_code, 404)        # only the member decides

    def test_monthly_job_runs(self):
        self.seat(self.m[0], {"report": True})
        from django.core.management import call_command
        from io import StringIO
        out = StringIO()
        call_command("probashi_daily", "--report", stdout=out)
        self.assertIn("reports", out.getvalue())
        self.assertTrue(ProbashiReport.objects.filter(recipient=self.payer).exists())


class ConfigAndPricingTests(TestCase):
    def test_normalize_bounds(self):
        self.assertEqual(L.normalize({"seats": 9})["seats"], 4)
        self.assertEqual(L.normalize({"seats": 1})["seats"], 3)
        self.assertEqual(L.normalize({"pool_credits": "x"})["pool_credits"], 180)
        c = P.normalize({"probashi_plan": {"seats": 3}})
        self.assertEqual(c["probashi_plan"]["seats"], 3)
        self.assertEqual(P.normalize({})["probashi_plan"]["seats"], 4)

    def test_bd_phone(self):
        self.assertTrue(L.is_bd_phone("+8801711234567"))
        for x in ("+966501234567", "+880171123456", "01711234567", ""):
            self.assertFalse(L.is_bd_phone(x), x)

    def test_forty_percent_rule_every_country(self):
        w, label = PP.worst_cost_per_credit()
        self.assertEqual(w, Decimal("0.016"))
        rows, pool = PP.table(pool=180)
        self.assertEqual(len(rows), 13)
        for r in rows:
            self.assertTrue(r["ok"], r["code"])
            self.assertGreaterEqual(r["margin_annual"], PP.PROFIT_MIN, r["code"])
            self.assertGreaterEqual(r["margin_monthly"], PP.PROFIT_MIN, r["code"])
        # the largest pool every country carries
        _, maxpool = PP.table()
        self.assertGreaterEqual(maxpool, 180)
        # the heavy-context case would need a much smaller pool
        hw = PP.worst_cost_per_credit(actions=(PP.HEAVY,))[0]
        _, hpool = PP.table(per_credit_usd=hw)
        self.assertLess(hpool, 180)

    def test_annual_is_ten_times(self):
        for r in PP.COUNTRIES:
            self.assertEqual(Decimal(r[9]).quantize(Decimal("1")),
                             (Decimal(r[8]) * 10).quantize(Decimal("1")), r[0])
