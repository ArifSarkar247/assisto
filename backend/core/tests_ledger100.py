"""ledger100 — digital khata to 100: offline sync idempotency + conflicts,
the app-facing contract (balances / statement lines / net position),
per-customer bulk tagada, scheduled tagada cron (idempotency, quiet hours,
caps, credits, paid-stop) and the "free forever" core (no plan gate, no
credits). SMS + push are mocked at their seams — no real SMS, no real push."""
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.management import call_command
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import tagada_cron
from core.logic import business_khata as K
from core.models import (BusinessProfile, KhataEntry, KhataParty, SmsLog,
                         TagadaSchedule, User)
from core.tests_smsotp import alpha_ok, connect, set_cfg

DHAKA = ZoneInfo("Asia/Dhaka")
B = "/api/v1/business/khata"


def at_dhaka(h, m=0, day=None):
    d = day or timezone.now().astimezone(DHAKA).date()
    return datetime(d.year, d.month, d.day, h, m, tzinfo=DHAKA)


class _Shop(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000111",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712345678")
        self.client.force_authenticate(self.owner)

    def due(self, party, poisha, direction="gave"):
        return KhataEntry.objects.create(party=party, direction=direction,
                                         amount_poisha=poisha, at=timezone.now())


# ============================================================== pure helpers
class PureTests(TestCase):
    def test_bd_msisdn_and_links(self):
        self.assertEqual(K.bd_msisdn("01712-345678"), "8801712345678")
        self.assertEqual(K.bd_msisdn("+8801712345678"), "8801712345678")
        self.assertEqual(K.bd_msisdn("০১৭১২৩৪৫৬৭৮"), "8801712345678")
        self.assertEqual(K.bd_msisdn("12345"), "")
        self.assertEqual(K.bd_msisdn("01212345678"), "")      # not a mobile prefix
        self.assertTrue(K.wa_link("01712345678", "বাকি ৳৫০০").startswith(
            "https://wa.me/8801712345678?text=%E0%A6"))
        self.assertEqual(K.wa_link("", "x"), "")
        self.assertTrue(K.sms_uri("01712345678", "a b").startswith("sms:+8801712345678?body=a%20b"))

    def test_next_fire_at(self):
        t = timezone.now()
        self.assertIsNone(K.next_fire_at(t, 0, t))
        self.assertEqual(K.next_fire_at(t, 3, t), t + timedelta(days=3))
        # server was down 10 days: ONE firing, the next slot is in the future
        old = t - timedelta(days=10)
        n = K.next_fire_at(old, 3, t)
        self.assertGreater(n, t)
        self.assertLessEqual(n, t + timedelta(days=3))

    def test_day_label_bangla_digits(self):
        self.assertEqual(K.day_label("2026-10-27T10:00:00+06:00"),
                         {"bn": "২৭ অক্টো ২০২৬", "en": "27 Oct 2026"})


# ====================================================== app contract (was broken)
class ContractTests(_Shop):
    def test_party_list_has_the_keys_the_app_reads(self):
        self.due(self.party, 150000)
        self.due(self.party, 50000, "got")
        r = self.client.get(B + "/parties?book=customer", HTTP_ACCEPT_LANGUAGE="bn")
        row = r.data["parties"][0]
        self.assertEqual(row["balance_poisha"], 100000)
        self.assertEqual(row["balance_display"]["bn"], "৳১০০০.০০")
        self.assertIn("bn", row["balance_status"])
        self.assertTrue(row["phone_ok"])
        self.assertTrue(r.data["free"])

    def test_list_is_one_balance_query_for_500_customers(self):
        parties = [KhataParty(business=self.biz, book="customer", name="C%03d" % i,
                              phone="0171%07d" % i) for i in range(500)]
        KhataParty.objects.bulk_create(parties)
        ps = list(KhataParty.objects.filter(business=self.biz))
        KhataEntry.objects.bulk_create([KhataEntry(party=p, direction="gave",
                                                   amount_poisha=100, at=timezone.now())
                                        for p in ps])
        from django.db import connection
        from django.test.utils import CaptureQueriesContext
        with CaptureQueriesContext(connection) as q:
            r = self.client.get(B + "/parties?book=customer")
        self.assertEqual(len(r.data["parties"]), 501)
        self.assertLess(len(q.captured_queries), 15)

    def test_statement_lines_and_net_position(self):
        self.due(self.party, 200000)
        self.due(self.party, 50000, "got")
        r = self.client.get(B + "/parties/%d/statement" % self.party.pk)
        lines = r.data["lines"]
        self.assertEqual(len(lines), 2)
        self.assertEqual(lines[0]["credit_display"]["en"], "৳500.00")    # newest first
        self.assertEqual(lines[1]["debit_display"]["en"], "৳2000.00")
        self.assertEqual(lines[0]["balance_display"]["en"], "৳1500.00")
        self.assertTrue(lines[0]["entry_id"] and lines[0]["version"] == 1)
        np = self.client.get(B + "/net-position").data
        self.assertEqual(np["receivable_display"]["en"], "৳1500.00")
        self.assertEqual(np["due_customers"], 1)

    def test_owner_picked_date_is_kept(self):
        r = self.client.post(B + "/parties/%d/entries" % self.party.pk,
                             {"direction": "gave", "amount": 1000,
                              "at": "2026-10-01"}, format="json")
        self.assertEqual(r.status_code, 201)
        e = KhataEntry.objects.get()
        self.assertEqual(e.at.astimezone(DHAKA).date().isoformat(), "2026-10-01")
        # far future → now (never a booking in next year)
        r = self.client.post(B + "/parties/%d/entries" % self.party.pk,
                             {"direction": "gave", "amount": 1000,
                              "at": "2099-01-01"}, format="json")
        self.assertLess(KhataEntry.objects.get(pk=r.data["entry_id"]).at,
                        timezone.now() + timedelta(minutes=1))


# ============================================================ offline sync
class OfflineSyncTests(_Shop):
    def post_entry(self, cid, amount=50000, kind="entries"):
        body = {"amount": amount, "client_id": cid, "note": "offline"}
        if kind == "entries":
            body["direction"] = "gave"
        return self.client.post(B + "/parties/%d/%s" % (self.party.pk, kind), body,
                                format="json")

    def test_replayed_client_id_books_once(self):
        r1 = self.post_entry("kx-abc123")
        self.assertEqual(r1.status_code, 201)
        r2 = self.post_entry("kx-abc123")         # the phone retried after a drop
        self.assertEqual(r2.status_code, 200)
        self.assertTrue(r2.data["duplicate"])
        self.assertEqual(r2.data["entry_id"], r1.data["entry_id"])
        self.assertEqual(KhataEntry.objects.count(), 1)
        self.assertEqual(r2.data["balance_poisha"], 50000)   # never double-counted

    def test_payment_replay_and_other_ids(self):
        self.post_entry("kx-due0001")
        self.post_entry("kx-pay0001", 20000, kind="payment")
        self.post_entry("kx-pay0001", 20000, kind="payment")
        r = self.post_entry("kx-due0002", 1000)
        self.assertEqual(KhataEntry.objects.count(), 3)
        self.assertEqual(r.data["balance_poisha"], 50000 - 20000 + 1000)

    def test_bad_client_id_is_ignored_not_trusted(self):
        self.post_entry("x")          # too short → treated as no id
        self.post_entry("x")
        self.assertEqual(KhataEntry.objects.count(), 2)
        self.assertEqual(set(KhataEntry.objects.values_list("client_id", flat=True)), {""})

    def test_edit_recomputes_and_bumps_version(self):
        eid = self.post_entry("kx-edit0001").data["entry_id"]
        r = self.client.post(B + "/entries/%d" % eid,
                             {"amount": 70000, "base_version": 1}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual((r.data["version"], r.data["balance_poisha"]), (2, 70000))

    def test_stale_offline_edit_is_a_conflict_not_an_overwrite(self):
        eid = self.post_entry("kx-edit0002").data["entry_id"]
        self.client.post(B + "/entries/%d" % eid, {"amount": 60000, "base_version": 1},
                         format="json")
        r = self.client.post(B + "/entries/%d" % eid, {"amount": 90000, "base_version": 1},
                             format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "conflict"))
        self.assertEqual(r.data["current"]["amount"], 60000)
        self.assertEqual(KhataEntry.objects.get(pk=eid).amount_poisha, 60000)

    def test_sale_linked_entry_cannot_be_edited(self):
        e = KhataEntry.objects.create(party=self.party, direction="gave",
                                      amount_poisha=100, note="বাকি বিক্রি [sale#5]",
                                      at=timezone.now())
        r = self.client.post(B + "/entries/%d" % e.pk, {"amount": 1}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "linked_entry"))

    def test_staff_cannot_edit_and_other_shop_cannot_touch(self):
        eid = self.post_entry("kx-edit0003").data["entry_id"]
        other = User.objects.create_user(name="X", phone="+8801888000222", password="pw123456")
        BusinessProfile.objects.create(user=other, shop_name="Other")
        self.client.force_authenticate(other)
        r = self.client.post(B + "/entries/%d" % eid, {"amount": 1}, format="json")
        self.assertEqual(r.status_code, 404)
        r = self.client.post(B + "/parties/%d/entries" % self.party.pk,
                             {"direction": "gave", "amount": 1, "client_id": "kx-evil01"},
                             format="json")
        self.assertEqual(r.status_code, 404)


# ============================================================ bulk tagada
class BulkTagadaTests(_Shop):
    def test_one_separate_reminder_per_picked_customer(self):
        self.due(self.party, 50000)
        p2 = KhataParty.objects.create(business=self.biz, book="customer", name="Rahim",
                                       phone="01811111111")
        self.due(p2, 120000)
        p3 = KhataParty.objects.create(business=self.biz, book="customer", name="Paid",
                                       phone="01911111111")
        r = self.client.post(B + "/tagada/bulk",
                             {"party_ids": [self.party.pk, p3.pk], "preset": "polite",
                              "pay_hint": {"method": "bKash", "number": "01700000000"}},
                             format="json", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200)
        rem = r.data["reminders"]
        self.assertEqual([x["party_id"] for x in rem], [self.party.pk])   # p2 not picked
        self.assertEqual(r.data["skipped"][0]["reason"], "no_due")         # p3 owes 0
        m = rem[0]["message"]
        self.assertIn("Karim", m)
        self.assertIn("Rahim Store", m)
        self.assertIn("৳৫০০.০০", m)
        self.assertIn("০১৭০০০০০০০০", m)                    # owner's own bKash number
        self.assertTrue(rem[0]["wa_url"].startswith("https://wa.me/8801712345678?text="))
        self.assertGreaterEqual(rem[0]["sms_credits"], 1)
        self.assertIn("balance", r.data["sms"])

    def test_staff_sees_no_assisto_sms(self):
        from core.models import BusinessStaff
        staff = User.objects.create_user(name="S", phone="+8801777000333", password="pw123456")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff",
                                     active=True)
        self.client.force_authenticate(staff)
        r = self.client.post(B + "/tagada/bulk", {"business": self.biz.pk}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(r.data["sms"]["available"])


# ============================================================ free forever
class FreeForeverTests(_Shop):
    """The digital khata core costs nothing on the FREE plan: no plan gate,
    no credit is ever charged for entries, balances, customers, statements
    or manual (WhatsApp / own-SMS) reminders."""

    def test_core_khata_path_on_free_plan_charges_nothing(self):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        calls = [
            ("post", B + "/parties", {"book": "customer", "name": "N", "phone": "01711111111"}),
            ("get", B + "/parties?book=customer", None),
            ("post", B + "/parties/%d/entries" % self.party.pk, {"direction": "gave", "amount": 5000}),
            ("post", B + "/parties/%d/payment" % self.party.pk, {"amount": 1000}),
            ("get", B + "/parties/%d/statement" % self.party.pk, None),
            ("post", B + "/parties/%d/statement.pdf" % self.party.pk, {}),
            ("get", B + "/net-position", None),
            ("post", B + "/tagada/single/%d" % self.party.pk, {}),
            ("post", B + "/tagada/bulk", {}),
            ("post", B + "/tagada/schedule", {"party": self.party.pk, "interval_days": 3}),
            ("get", B + "/tagada/schedule", None),
        ]
        with mock.patch("core.billing.charge") as charge:
            for m, url, body in calls:
                r = getattr(self.client, m)(url, body, format="json") if body is not None \
                    else getattr(self.client, m)(url)
                self.assertIn(r.status_code, (200, 201), (url, r.status_code, r.data))
            charge.assert_not_called()
        from core.models import CreditLedger
        self.assertFalse(CreditLedger.objects.filter(user=self.owner).exists())


# ============================================================ schedule API
class ScheduleApiTests(_Shop):
    def test_create_update_one_per_customer_ack_delete(self):
        r = self.client.post(B + "/tagada/schedule",
                             {"party": self.party.pk, "interval_days": 3, "channel": "sms",
                              "next_at": (timezone.now() + timedelta(days=1)).isoformat()},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual((r.data["mode"], r.data["until_paid"]), ("sms", True))
        r2 = self.client.post(B + "/tagada/schedule",
                              {"party": self.party.pk, "interval_days": 0}, format="json")
        self.assertEqual(r2.status_code, 200)
        self.assertEqual(TagadaSchedule.objects.count(), 1)
        self.assertEqual(r2.data["mode"], "push")
        sid = r2.data["id"]
        TagadaSchedule.objects.filter(pk=sid).update(awaiting_owner=True)
        self.assertEqual(len(self.client.get(B + "/tagada/schedule").data["awaiting"]), 1)
        self.client.post(B + "/tagada/schedule/%d" % sid, {"ack": True}, format="json")
        self.assertFalse(TagadaSchedule.objects.get(pk=sid).awaiting_owner)
        self.assertEqual(self.client.delete(B + "/tagada/schedule/%d" % sid).status_code, 200)
        self.assertFalse(TagadaSchedule.objects.exists())

    def test_bad_interval_refused(self):
        r = self.client.post(B + "/tagada/schedule", {"party": self.party.pk,
                                                      "interval_days": 400}, format="json")
        self.assertEqual(r.status_code, 422)


# ============================================================ the cron
@mock.patch("core.push.push_to_user", return_value=1)
class TagadaCronTests(_Shop):
    def setUp(self):
        super().setUp()
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})
        self.due(self.party, 50000)
        self.noon = at_dhaka(12)

    def sched(self, **kw):
        d = dict(party=self.party, next_at=self.noon - timedelta(minutes=1),
                 interval_days=3, channel="push")
        d.update(kw)
        return TagadaSchedule.objects.create(**d)

    def test_push_mode_nudges_the_owner_and_advances(self, push):
        s = self.sched()
        st = tagada_cron.sweep(now=self.noon)
        self.assertEqual(st["push_sent"], 1)
        args = push.call_args
        self.assertEqual(args.args[0], self.owner)
        self.assertEqual(args.args[1], "reminder")
        self.assertEqual(args.kwargs["data"]["route"], "business/khata")
        s.refresh_from_db()
        self.assertTrue(s.awaiting_owner)
        self.assertEqual((s.fire_count, s.last_result), (1, "push"))
        self.assertGreater(s.next_at, self.noon)
        self.assertFalse(SmsLog.objects.exists())          # nothing to the customer

    def test_idempotent_second_run_sends_nothing(self, push):
        self.sched()
        tagada_cron.sweep(now=self.noon)
        st = tagada_cron.sweep(now=self.noon + timedelta(minutes=5))
        self.assertEqual(push.call_count, 1)
        self.assertEqual(st["looked"], 0)

    def test_lost_claim_sends_nothing(self, push):
        s = self.sched()
        stale = TagadaSchedule.objects.select_related("party", "party__business",
                                                      "party__business__user").get(pk=s.pk)
        tagada_cron.sweep(now=self.noon)              # the other worker fired it
        from collections import Counter
        st = Counter()
        tagada_cron.fire_one(stale, self.noon, st)    # a racing copy of the same row
        self.assertEqual(st["lost_claim"], 1)
        self.assertEqual(push.call_count, 1)

    def test_quiet_hours_defer_to_9am(self, push):
        s = self.sched(next_at=at_dhaka(22) - timedelta(minutes=1))
        st = tagada_cron.sweep(now=at_dhaka(22))
        self.assertEqual(st["quiet_deferred"], 1)
        push.assert_not_called()
        s.refresh_from_db()
        nxt = s.next_at.astimezone(DHAKA)
        self.assertEqual((nxt.hour, nxt.minute), (9, 0))
        self.assertGreater(s.next_at, at_dhaka(22))

    def test_paid_customer_stops_until_paid(self, push):
        s = self.sched()
        self.due(self.party, 50000, "got")
        st = tagada_cron.sweep(now=self.noon)
        self.assertEqual(st["paid_stopped"], 1)
        s.refresh_from_db()
        self.assertFalse(s.enabled)
        push.assert_not_called()

    def test_one_off_disables_after_firing(self, push):
        s = self.sched(interval_days=0)
        tagada_cron.sweep(now=self.noon)
        s.refresh_from_db()
        self.assertFalse(s.enabled)
        self.assertEqual(s.fire_count, 1)

    def test_never_twice_a_day_for_one_customer(self, push):
        s = self.sched(interval_days=1)
        s.last_fired_at = self.noon - timedelta(hours=1)
        s.save()
        st = tagada_cron.sweep(now=self.noon)
        self.assertEqual(st["same_day_skipped"], 1)
        push.assert_not_called()

    def test_business_daily_cap(self, push):
        with mock.patch.object(tagada_cron, "PER_BUSINESS_DAY", 1):
            self.sched()
            p2 = KhataParty.objects.create(business=self.biz, book="customer", name="B",
                                           phone="01811111111")
            self.due(p2, 100)
            TagadaSchedule.objects.create(party=p2, next_at=self.noon - timedelta(seconds=30),
                                          interval_days=3)
            st = tagada_cron.sweep(now=self.noon)
        self.assertEqual((st["push_sent"], st["business_cap_deferred"]), (1, 1))

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_sms_mode_charges_credits(self, http, push):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        s = self.sched(channel="sms")
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False):
            st = tagada_cron.sweep(now=self.noon)
        self.assertEqual(st["sms_sent"], 1)
        push.assert_not_called()
        s.refresh_from_db()
        self.assertEqual((s.last_result, s.awaiting_owner), ("sms_sent", False))
        log = SmsLog.objects.get(status="sent")
        self.assertEqual(log.purpose, "tagada")
        self.assertLess(User.objects.get(pk=self.owner.pk).ai_credits, 10)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_sms_mode_at_zero_credits_falls_back_to_owner_push(self, http, push):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=0)
        s = self.sched(channel="sms")
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False):
            st = tagada_cron.sweep(now=self.noon)
        self.assertEqual(st["sms_refused"], 1)
        self.assertEqual(http.call_count, 0)              # nothing sent unpaid
        push.assert_called_once()
        s.refresh_from_db()
        self.assertEqual(s.last_result, "sms_insufficient_credits")
        self.assertTrue(s.awaiting_owner)

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_sms_respects_stop_opt_out(self, http, push):
        User.objects.filter(pk=self.owner.pk).update(ai_credits=10)
        from core.logic import msg_guard as MG
        from core.logic.business_selling import normalize_phone
        MG.record_opt_out(self.biz.pk, normalize_phone("+8801712345678"))
        s = self.sched(channel="sms")
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False):
            tagada_cron.sweep(now=self.noon)
        s.refresh_from_db()
        self.assertEqual(s.last_result, "sms_opted_out")
        self.assertEqual(http.call_count, 0)

    def test_management_command_runs(self, push):
        self.sched(next_at=timezone.now() - timedelta(minutes=1))
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False):
            call_command("tagada_sweep", "--quiet")
        from core.ops_health import JOB_BY_NAME
        self.assertIn("flock -n /tmp/assisto-tagada-sweep.lock",
                      JOB_BY_NAME["tagada_sweep"].cron_line())
