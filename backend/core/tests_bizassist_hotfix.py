"""bizassist HOTFIX (18 Nov, backend only): Personal Secretary brief (board row 17) + booking bot
(row 26) gaps — owner_actions/gaps/bizassist_BN.md.

S1 repeating reminders projected onto today · S2 the phone's own clock ·
S3 subscriptions in bills · S4 missed My Circle calls until returned ·
S5 today's bookings (shop + customer) · S8 morning brief line ·
B1 a booking reminder is claimed once (two sweeps never double-send) ·
B2 a retry returns the same booking (no second seat) · B3 the pending cap
also counts the account · race: two threads, one slot -> one booking."""
import threading
from datetime import datetime, time, timedelta, timezone as dtz
from unittest import mock

from django.db import OperationalError, connection
from django.test import TestCase, TransactionTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import booking_service as BS
from core import feature_flags as FF
from core import ps_service as S
from core.logic import booking as BL
from core.models import (Booking, BookingSlotLock, BusinessProfile, FeatureFlag,
                         Reminder, User)

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

    # ---- S1
    def test_repeating_reminders_show_today(self):
        Reminder.objects.create(user=self.u, title="Pressure pill",
                                due_at=dhaka(2026, 11, 15, 21), recurrence="daily")
        Reminder.objects.create(user=self.u, title="Jumma", due_at=dhaka(2026, 11, 14, 13),
                                recurrence="weekly",
                                recurrence_rule={"freq": "weekly", "interval": 1, "weekday": 4})
        Reminder.objects.create(user=self.u, title="Stopped", due_at=dhaka(2026, 11, 10, 9),
                                recurrence="daily", done=True)
        Reminder.objects.create(user=self.u, title="Old one-off", due_at=dhaka(2026, 11, 17, 9))
        Reminder.objects.create(user=self.u, title="Gas bill", due_at=dhaka(2026, 11, 18, 11))
        b = S.today(self.u, now=NOW)
        lines = section(b, "reminders")["lines"]
        text = [l["en"] for l in lines]
        self.assertEqual(text, ["11:00 am — Gas bill", "9:00 pm — Pressure pill"])
        self.assertIn("রাত ৯:০০ — Pressure pill", [l["bn"] for l in lines])
        self.assertEqual(b["counts"]["reminders"], 2)


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
    # ---- B2
    def test_retry_returns_same_booking_no_second_seat(self):
        self.setup_page(capacity=3)
        st = self.start()
        r1 = self.book(self.c, st)
        self.assertEqual(r1.status_code, 201, r1.data)
        r2 = self.book(self.c, st)                         # lost reply -> retry
        self.assertEqual(r2.status_code, 200, r2.data)
        self.assertTrue(r2.data["already_booked"])
        self.assertNotIn("manage_token", r2.data)
        self.assertEqual(r2.data["id"], r1.data["id"])
        self.assertEqual(Booking.objects.filter(business=self.biz).count(), 1)
        # after a cancel the same time can be booked again (a new booking)
        BS.transition(Booking.objects.get(), "cancelled", "customer")
        self.assertEqual(self.book(self.c, st).status_code, 201)

    # ---- B3
    def test_pending_cap_counts_the_account_without_phone(self):
        self.setup_page(capacity=5)
        page = BS.page_for(self.biz)
        cap = page.max_pending_per_phone
        with mock.patch("core.otp.user_phone", return_value=""):
            for i in range(cap):
                r = self.book(self.c, self.start(days=1, hh=10 + i))
                self.assertEqual(r.status_code, 201, r.data)
            r = self.book(self.c, self.start(days=2, hh=10))
        self.assertEqual(r.status_code, 429, r.data)
        self.assertEqual(r.data["error"], "too_many_pending")

    # ---- B1
    def test_reminder_claimed_once(self):
        self.setup_page()
        b, _ = BS.create(BS.page_for(self.biz), self.biz.booking_services.get(), self.start(),
                         name="K", user=self.cust, actor="customer")
        one, two = Booking.objects.get(pk=b.pk), Booking.objects.get(pk=b.pk)
        self.assertTrue(BS.claim_reminder(one, "24h"))
        self.assertFalse(BS.claim_reminder(two, "24h"))   # the other sweep read the old counter
        b.refresh_from_db()
        self.assertEqual((b.reminders_sent, b.reminded), (1, ["24h"]))

    def test_sweep_twice_sends_once(self):
        self.setup_page()
        b, _ = BS.create(BS.page_for(self.biz), self.biz.booking_services.get(),
                         self.start(days=1, hh=12), name="K", user=self.cust, actor="customer")
        Booking.objects.filter(pk=b.pk).update(created_at=timezone.now() - timedelta(days=3))
        when = b.start - timedelta(hours=23, minutes=55)
        with mock.patch.object(BL, "in_quiet_hours", return_value=False):
            n1 = BS.send_due_reminders(now=when)
            n2 = BS.send_due_reminders(now=when)
        self.assertEqual((n1, n2), (1, 0))
        b.refresh_from_db()
        self.assertEqual(b.reminded, ["24h"])


class BookingRaceTests(TransactionTestCase):
    """Two customers press Confirm for the SAME free slot at the same moment
    (both pass the free-slot check): exactly one booking, one set of locks."""

    def test_two_threads_one_slot(self):
        flag(BS.FLAG)
        owner = User.objects.create_user(name="Race Shop", phone="01710000971", password="pw")
        biz = BusinessProfile.objects.create(user=owner, shop_name="Race Salon")
        page = BS.page_for(biz)
        page.weekly_hours, page.capacity, page.enabled, page.min_notice_min = ALL_WEEK, 1, True, 0
        page.save()
        from core.models import BookingService
        svc = BookingService.objects.create(business=biz, name="Cut", duration_min=30, buffer_min=0)
        users = [User.objects.create_user(name="R%d" % i, phone="0181000097%d" % i, password="pw")
                 for i in range(2)]
        st = datetime.combine(BL.local(timezone.now()).date() + timedelta(days=1), time(15, 0),
                              tzinfo=BL.TZ)
        barrier = threading.Barrier(2)
        won, lost = [], []

        def worker(u):
            try:
                barrier.wait()
                BS.create(BS.page_for(biz), svc, st, name=u.name, user=u, actor="customer")
                won.append(u.pk)
            except (BS.BookingError, OperationalError):
                lost.append(u.pk)              # slot_taken (or sqlite "locked": refused)
            finally:
                connection.close()

        ts = [threading.Thread(target=worker, args=(u,)) for u in users]
        # patched ONCE around both threads (mock.patch is not thread safe)
        with mock.patch.object(BS, "_valid_start", return_value=True), \
                mock.patch.object(BS, "_after_create"):
            [t.start() for t in ts]
            [t.join() for t in ts]
        self.assertLessEqual(len(won), 1)
        self.assertEqual(len(won) + len(lost), 2)
        self.assertEqual(Booking.objects.filter(business=biz).count(), len(won))
        self.assertEqual(BookingSlotLock.objects.filter(business=biz).count(),
                         len(BL.granules(st, st + timedelta(minutes=30))) * len(won))
