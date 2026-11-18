"""bizassist (18 Nov): Personal Secretary brief (board row 17) + booking bot
(row 26) gaps — owner_actions/gaps/bizassist_BN.md.

S1 repeating reminders projected onto today · S2 the phone's own clock ·
S3 subscriptions in bills · S4 missed My Circle calls until returned ·
S5 today's bookings (shop + customer) · S8 morning brief line ·
CI-only reminder time travel. S1 + B1-B3 + the race live in
tests_bizassist_hotfix.py (shipped live 18 Nov)."""
from datetime import date, datetime, time, timedelta, timezone as dtz
from decimal import Decimal
from unittest import mock

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import booking_service as BS
from core import feature_flags as FF
from core import ps_service as S
from core.logic import booking as BL
from core.models import (Booking, BusinessProfile, CallRecord,
                         CallSession, CircleMember, FeatureFlag, Reminder,
                         Subscription, User)

V = "/api/v1"
DHAKA = dtz(timedelta(hours=6))
ALL_WEEK = {str(d): [["09:00", "21:00"]] for d in range(7)}


def flag(key, on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=key).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def dhaka(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=DHAKA)


# Wednesday 18 Nov 2026, 08:00 Dhaka
NOW = dhaka(2026, 11, 18, 8)


def section(b, key):
    for s in b["sections"]:
        if s["key"] == key:
            return s
    return None


class BriefSourcesTests(TestCase):
    def setUp(self):
        flag(S.FLAG)
        self.addCleanup(FF.invalidate)
        self.u = User.objects.create_user(name="Sec One", phone="01710000951", password="pw12345!")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    # ---- S2
    def test_phone_clock_offset(self):
        riyadh = timezone.now().astimezone(dtz(timedelta(hours=3)))
        Reminder.objects.create(user=self.u, title="Call home",
                                due_at=riyadh.replace(hour=7, minute=0, second=0, microsecond=0))
        r = self.c.get(V + "/ps/today?tz=180")          # Riyadh, UTC+3
        self.assertEqual(r.status_code, 200, r.content)
        self.assertIn("7:00 am — Call home", str(r.json()))
        for bad in ("abc", "99999"):                     # junk -> Dhaka
            local = S.clock(NOW.astimezone(dtz.utc), bad)
            self.assertEqual(local.utcoffset(), timedelta(hours=6))
        self.assertEqual(S.clock(NOW, "360").hour, 8)

    # ---- S3
    def test_subscriptions_in_bills(self):
        Subscription.objects.create(user=self.u, name="Link3 internet", amount=Decimal("1200"),
                                    next_due=date(2026, 11, 19))
        Subscription.objects.create(user=self.u, name="Paused TV", amount=Decimal("500"),
                                    next_due=date(2026, 11, 18), details={"status": "paused"})
        Subscription.objects.create(user=self.u, name="Far away", amount=Decimal("99"),
                                    next_due=date(2026, 12, 18))
        b = S.today(self.u, now=NOW)
        bills = section(b, "bills")["lines"]
        self.assertEqual(len(bills), 1)
        self.assertEqual(bills[0]["en"], "Link3 internet — ৳1,200 (in 1 day(s))")
        self.assertIn("৳১,২০০", bills[0]["bn"])
        self.assertEqual(bills[0]["src"]["kind"], "subscription")


class MissedCallTests(TestCase):
    def setUp(self):
        flag(S.FLAG)
        self.addCleanup(FF.invalidate)
        self.me = User.objects.create_user(name="Sec Two", phone="01710000952", password="pw12345!")
        self.rahim = User.objects.create_user(name="Rahim", phone="01710000953", password="pw12345!")
        self.edge = CircleMember.objects.create(user=self.me, name="Rahim Bhai", phone=self.rahim.phone,
                                                peer_user=self.rahim, state="accepted")

    def call(self, caller, callee, mins_ago, answered=False, reason="no_answer"):
        rec = CallRecord.objects.create(caller=caller, callee=callee, state="ended",
                                        duration_sec=60 if answered else 0)
        CallRecord.objects.filter(pk=rec.pk).update(
            started_at=timezone.now() - timedelta(minutes=mins_ago))
        CallSession.objects.create(call=rec, end_reason="hangup" if answered else reason)
        return rec

    def test_missed_until_returned(self):
        self.call(self.rahim, self.me, 90)
        self.call(self.rahim, self.me, 60)
        b = S.today(self.me)
        sec = section(b, "missed_calls")
        self.assertIsNotNone(sec)
        line = sec["lines"][0]
        self.assertIn("Rahim Bhai — 2 missed calls", line["en"])
        self.assertIn("২টি মিসড কল", line["bn"])
        self.assertEqual(line["circle"], [{"id": self.edge.id, "name": "Rahim Bhai"}])
        self.assertEqual(b["counts"]["missed_calls"], 1)
        # my call back (even unanswered) clears it
        self.call(self.me, self.rahim, 5)
        self.assertIsNone(section(S.today(self.me), "missed_calls"))

    def test_answered_later_clears_and_old_calls_ignored(self):
        self.call(self.rahim, self.me, 60 * 30)          # 30 h ago: out of the window
        self.assertIsNone(section(S.today(self.me), "missed_calls"))
        self.call(self.rahim, self.me, 50)
        self.call(self.rahim, self.me, 10, answered=True)
        self.assertIsNone(section(S.today(self.me), "missed_calls"))

    def test_caller_does_not_see_own_unanswered_as_missed(self):
        self.call(self.me, self.rahim, 20)
        self.assertIsNone(section(S.today(self.me), "missed_calls"))
        sec = section(S.today(self.rahim), "missed_calls")
        self.assertEqual(sec["lines"][0]["circle"], [])   # no edge on Rahim's side
        self.assertIn("Sec Two", sec["lines"][0]["en"])

    def test_morning_brief_line(self):
        self.call(self.rahim, self.me, 30)
        lines = S.proactive_lines(self.me, timezone.now())
        self.assertTrue(any("Rahim Bhai" in l["en"] for l in lines))


class _BizBase(TestCase):
    def setUp(self):
        flag(BS.FLAG)
        flag(S.FLAG)
        self.addCleanup(FF.invalidate)
        self.owner = User.objects.create_user(name="Salon Owner", phone="01710000961", password="pw")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.save()
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rupa Salon")
        self.cust = User.objects.create_user(name="Karim", phone="01810000962", password="pw")
        self.o = APIClient()
        self.o.force_authenticate(self.owner)
        self.c = APIClient()
        self.c.force_authenticate(self.cust)
        p = mock.patch("core.push.safe_push", return_value=1)
        p.start()
        self.addCleanup(p.stop)

    def setup_page(self, capacity=1, auto=True):
        r = self.o.post(V + "/booking/biz/services",
                        {"name": "Haircut", "duration_min": 30, "buffer_min": 10,
                         "price_bdt": 300}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.svc = r.data["id"]
        r = self.o.put(V + "/booking/biz", {"weekly_hours": ALL_WEEK, "capacity": capacity,
                                            "auto_confirm": auto, "slug": "rupa-salon",
                                            "enabled": True, "cancel_hours": 2,
                                            "min_notice_min": 60}, format="json")
        self.assertEqual(r.status_code, 200, r.data)

    def start(self, days=1, hh=16):
        d = BL.local(timezone.now()).date() + timedelta(days=days)
        return datetime.combine(d, time(hh, 0), tzinfo=BL.TZ)

    def book(self, client, start):
        return client.post(V + "/booking/p/rupa-salon/book",
                           {"service": self.svc, "start": start.isoformat()}, format="json")


class BookingFixTests(_BizBase):
    # ---- S5
    def test_brief_shows_todays_bookings_both_sides(self):
        self.setup_page(auto=False)
        st = timezone.now() + timedelta(hours=2)
        svc = self.biz.booking_services.get()
        b = Booking.objects.create(business=self.biz, service=svc, service_name="Haircut",
                                   customer_user=self.cust, customer_name="Karim", start=st,
                                   end=st + timedelta(minutes=30),
                                   block_end=st + timedelta(minutes=40), status="requested")
        shop = section(S.today(self.owner), "bookings")
        if BL.local(st).date() != BL.local(timezone.now()).date():
            self.skipTest("late-night run: +2 h is tomorrow")
        self.assertIn("Haircut · Karim · please confirm", shop["lines"][0]["en"])
        self.assertEqual(shop["lines"][0]["src"], {"kind": "booking_biz", "id": b.id})
        mine = section(S.today(self.cust), "bookings")
        self.assertIn("Haircut at Rupa Salon", mine["lines"][0]["en"])
        self.assertEqual(mine["lines"][0]["src"]["kind"], "booking_mine")
        BS.transition(b, "cancelled", "business")
        self.assertIsNone(section(S.today(self.cust), "bookings"))


class CiReminderCommandTests(_BizBase):
    def test_ci_time_travel_only_in_reality_ci(self):
        from django.core.management import call_command
        from django.core.management.base import CommandError
        from django.test import override_settings
        self.setup_page()
        b, _ = BS.create(BS.page_for(self.biz), self.biz.booking_services.get(),
                         self.start(days=2, hh=12), name="K", user=self.cust, actor="customer")
        with override_settings(REALITY_CI=False):
            with self.assertRaises(CommandError):
                call_command("booking_reminders", "--ci-24h-before")
        with override_settings(REALITY_CI=True):
            call_command("booking_reminders", "--ci-24h-before")
        b.refresh_from_db()
        self.assertEqual(b.reminded, ["24h"])
        self.assertIn("STOP", str(list(b.history)) + str(
            list(self.cust.notif_events.values_list("body_en", flat=True))))
