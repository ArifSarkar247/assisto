"""booking-bot (big-week item I) — two accounts end to end.

Business (Business plan) sets up the page (3-step wizard: service, hours,
switch on) · a second account (customer) books in the app, a guest books on
the public link with an SMS code · double booking refused — also when two
requests pass the free-slot check at the same time (the UNIQUE lock rows
decide) · capacity 2 = two seats · staff are separate resources · business
confirms, reschedules, marks done / no-show; customer cancels / reschedules
inside the policy window and is refused after it · reminders: 24 h + 2 h,
max 2, quiet hours 22:00-08:00, STOP honoured, SMS only when switched on,
paid from credits and capped · flag OFF → 403 feature_off everywhere (public
→ 404) · rate limits (per IP, per phone pending, blocked number) · the AI
agent offers ONLY real free slots in a chat and books through the same
locks · the customer's phone is visible only to that business."""
from datetime import datetime, time, timedelta
from unittest import mock

from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import booking_service as S
from core import feature_flags as FF
from core.logic import booking as L
from core.models import (Booking, BookingContact, BookingSlotLock, BusinessProfile,
                         FeatureFlag, NotifEvent, PhoneVerification, User)

ALL_WEEK = {str(d): [["09:00", "21:00"]] for d in range(7)}


def flag(on=True):
    FF.ensure_seeded()
    FeatureFlag.objects.filter(key=S.FLAG).update(enabled_all=on, enabled_play=on)
    FF.invalidate()


def at(day, hh, mm=0):
    return datetime.combine(day, time(hh, mm), tzinfo=L.TZ)


def tomorrow():
    return L.local(timezone.now()).date() + timedelta(days=1)


class FakeSms:
    def __init__(self):
        self.sent = []
        self.cfg = {}

    def send(self, to, text, secret=""):
        self.sent.append((to, text))
        return True, "ok"


class _Base(TestCase):
    def setUp(self):
        flag(True)
        self.addCleanup(FF.invalidate)
        self.owner = User.objects.create_user(name="Salon Owner", phone="01710000001", password="pw")
        self.owner.plan = "business"
        self.owner.plan_until = timezone.now() + timedelta(days=30)
        self.owner.save()
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rupa Salon")
        self.cust = User.objects.create_user(name="Karim", phone="01810000002", password="pw")
        self.other = User.objects.create_user(name="Other Shop", phone="01910000003", password="pw")
        self.o = APIClient()
        self.o.force_authenticate(self.owner)
        self.c = APIClient()
        self.c.force_authenticate(self.cust)
        self.g = APIClient()        # guest (public page)
        self.pushes = []
        p = mock.patch("core.push.safe_push", side_effect=lambda *a, **k: self.pushes.append((a, k)) or 1)
        p.start()
        self.addCleanup(p.stop)

    def setup_page(self, capacity=1, auto=True, **extra):
        r = self.o.post("/api/v1/booking/biz/services",
                        {"name": "Haircut", "duration_min": 30, "buffer_min": 10,
                         "price_bdt": 300}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.svc = r.data["id"]
        body = {"weekly_hours": ALL_WEEK, "capacity": capacity, "auto_confirm": auto,
                "slug": "rupa-salon", "enabled": True, "cancel_hours": 2, "min_notice_min": 60}
        body.update(extra)
        r = self.o.put("/api/v1/booking/biz", body, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["enabled"])
        return r.data

    def app_book(self, client, start, **kw):
        body = {"service": self.svc, "start": start.isoformat()}
        body.update(kw)
        return client.post("/api/v1/booking/p/rupa-salon/book", body, format="json")


# ===================================================================== pure
class PureTests(TestCase):
    def test_hours_validation_and_slots(self):
        h, p = L.clean_hours({"0": [["09:00", "12:00"], ["14:00", "18:00"]], "1": [["18:00", "09:00"]]})
        self.assertEqual(p, ["hours_1"])
        self.assertEqual(h["0"], [["09:00", "12:00"], ["14:00", "18:00"]])
        _, p = L.clean_hours({"2": [["09:00", "12:00"], ["11:00", "13:00"]]})
        self.assertEqual(p, ["hours_2"])           # overlap refused
        day = tomorrow()
        now = at(day, 6)
        cfg = {"weekly_hours": ALL_WEEK, "days_off": [], "step_min": 30,
               "min_notice_min": 60, "max_days_ahead": 30}
        svc = {"duration_min": 30, "buffer_min": 10}
        s = L.free_slots(day, now, cfg, svc, [(0, 1)], {})
        self.assertEqual(L.local(s[0]["start"]).hour, 9)
        self.assertEqual(L.local(s[-1]["start"]).strftime("%H:%M"), "20:30")
        busy = {0: [(at(day, 9), at(day, 9, 40))]}
        s2 = L.free_slots(day, now, cfg, svc, [(0, 1)], busy)
        self.assertNotIn(at(day, 9), [x["start"] for x in s2])
        self.assertNotIn(at(day, 9, 30), [x["start"] for x in s2])   # buffer overlaps
        cfg_off = dict(cfg, days_off=[day.isoformat()])
        self.assertEqual(L.free_slots(day, now, cfg_off, svc, [(0, 1)], {}), [])
        # past the horizon → nothing
        self.assertEqual(L.free_slots(day + timedelta(days=40), now, cfg, svc, [(0, 1)], {}), [])

    def test_reminder_timing_quiet_hours_and_cap(self):
        day = tomorrow() + timedelta(days=1)
        start = at(day, 15)
        made = start - timedelta(days=3)
        self.assertIsNone(L.due_reminder(start, made, start - timedelta(hours=30), []))
        self.assertEqual(L.due_reminder(start, made, start - timedelta(hours=23), []), "24h")
        self.assertEqual(L.due_reminder(start, made, start - timedelta(hours=2), ["24h"]), "2h")
        self.assertIsNone(L.due_reminder(start, made, start - timedelta(hours=1), ["24h", "2h"]))
        self.assertIsNone(L.due_reminder(start, made, start - timedelta(minutes=30), ["24h"], max_reminders=1))
        early = at(day, 9)          # 24 h before = 09:00 ok; 2 h before = 07:00 → quiet
        self.assertIsNone(L.due_reminder(early, made, at(day, 7), ["24h"]))
        self.assertEqual(L.due_reminder(early, made, at(day, 8), ["24h"]), "2h")
        late = at(day, 23)          # 24 h before = 23:00 → quiet, waits for 08:00
        self.assertIsNone(L.due_reminder(late, made, at(day - timedelta(days=1), 23), []))
        self.assertEqual(L.due_reminder(late, made, at(day, 8), []), "24h")
        # booked only 1 h ahead → no reminder at all
        self.assertIsNone(L.due_reminder(start, start - timedelta(hours=1),
                                         start - timedelta(minutes=30), []))

    def test_chat_parsing(self):
        self.assertTrue(L.wants_booking("ami ekta appointment nite chai"))
        self.assertTrue(L.wants_booking("কাল সিরিয়াল দেওয়া যাবে?"))
        self.assertFalse(L.wants_booking("panjabi dam koto"))
        self.assertEqual(L.pick_option("২", 3), 2)
        self.assertIsNone(L.pick_option("2 ta panjabi dao", 3))
        self.assertIsNone(L.pick_option("7", 3))
        today = datetime(2026, 10, 26).date()          # a Monday
        self.assertEqual(L.parse_day("kal", today), today + timedelta(days=1))
        self.assertEqual(L.parse_day("শুক্রবার সকালে", today), datetime(2026, 10, 30).date())
        self.assertIsNone(L.parse_day("money matters this month", today))
        self.assertEqual(L.parse_day("25/11", today), datetime(2026, 11, 25).date())

    def test_lifecycle_rules(self):
        self.assertTrue(L.can_move("requested", "confirmed", "business"))
        self.assertFalse(L.can_move("requested", "confirmed", "customer"))
        self.assertTrue(L.can_move("confirmed", "cancelled", "customer"))
        self.assertFalse(L.can_move("done", "cancelled", "business"))
        self.assertFalse(L.can_move("cancelled", "confirmed", "business"))


# ===================================================================== journey
class JourneyTests(_Base):
    def test_flag_off_everything_hidden(self):
        flag(False)
        self.owner.is_staff = False
        for path in ("/api/v1/booking/biz", "/api/v1/booking/mine",
                     "/api/v1/booking/biz/bookings"):
            r = self.c.get(path)
            self.assertEqual(r.status_code, 403, path)
            self.assertEqual(r.data["error"], "feature_off")
        self.assertEqual(self.o.post("/api/v1/booking/biz/services", {"name": "X"},
                                     format="json").status_code, 403)
        # the public link of a business whose flag is off does not exist
        flag(True)
        self.setup_page()
        flag(False)
        self.assertEqual(self.g.get("/api/v1/booking/p/rupa-salon").status_code, 404)
        # registry default is OFF (hidden)
        self.assertFalse(FF.default_row(S.FLAG)["enabled_all"])

    def test_owner_staff_preview_when_flag_off(self):
        flag(False)
        self.owner.is_staff = True
        self.owner.save()
        self.assertEqual(self.o.get("/api/v1/booking/biz").status_code, 200)

    def test_wizard_needs_business_plan_and_ready_setup(self):
        free = User.objects.create_user(name="Free", phone="01610000009", password="pw")
        BusinessProfile.objects.create(user=free, shop_name="Free shop")
        fc = APIClient()
        fc.force_authenticate(free)
        r = fc.put("/api/v1/booking/biz", {"enabled": True}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (402, "upgrade_required"))
        r = self.o.put("/api/v1/booking/biz", {"enabled": True}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "not_ready"))
        self.assertIn("no_services", r.data["ready_problems"])
        r = self.o.put("/api/v1/booking/biz", {"weekly_hours": {"0": [["10:00", "09:00"]]}},
                       format="json")
        self.assertEqual(r.status_code, 400)
        d = self.setup_page()
        self.assertEqual(d["public_url"].rsplit("/", 1)[-1], "rupa-salon")
        self.assertEqual(d["ready_problems"], [])

    def test_two_accounts_book_reschedule_cancel_done_noshow(self):
        self.setup_page(auto=False)
        day = tomorrow()
        # customer (second account) sees the public card + free times
        r = self.c.get("/api/v1/booking/p/rupa-salon")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["taking_bookings"])
        self.assertNotIn("staff", r.data)
        r = self.c.get("/api/v1/booking/p/rupa-salon/slots", {"service": self.svc, "day": day.isoformat()})
        self.assertIn(at(day, 10).isoformat(), [s["start"] for s in r.data["slots"]])
        r = self.app_book(self.c, at(day, 10))
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual(r.data["status"], "requested")
        self.assertNotIn("customer_phone", r.data)
        bid = r.data["id"]
        # the business got a notification (in-app + push)
        self.assertTrue(NotifEvent.objects.filter(user=self.owner, route="booking").exists())
        # the slot is gone for everybody
        r = self.g.get("/api/v1/booking/p/rupa-salon/slots", {"service": self.svc, "day": day.isoformat()})
        self.assertNotIn(at(day, 10).isoformat(), [s["start"] for s in r.data["slots"]])
        # double booking refused
        r = self.app_book(self.c, at(day, 10))
        self.assertEqual((r.status_code, r.data["error"]), (409, "slot_taken"))
        # business sees it today/upcoming WITH the phone; another account cannot
        r = self.o.get("/api/v1/booking/biz/bookings", {"scope": "upcoming"})
        row = r.data["bookings"][0]
        self.assertEqual(row["customer_phone"], "+8801810000002")
        self.assertIn("confirmed", row["can"])
        oc = APIClient()
        oc.force_authenticate(self.other)
        self.assertEqual(oc.get("/api/v1/booking/biz/bookings/%d" % bid).status_code, 404)
        # confirm → customer told in-app
        r = self.o.post("/api/v1/booking/biz/bookings/%d/action" % bid, {"action": "confirmed"}, format="json")
        self.assertEqual(r.data["status"], "confirmed")
        self.assertTrue(NotifEvent.objects.filter(user=self.cust, route="my_bookings").exists())
        # done / no-show only after the start
        r = self.o.post("/api/v1/booking/biz/bookings/%d/action" % bid, {"action": "done"}, format="json")
        self.assertEqual(r.data["error"], "not_started")
        # customer reschedules (inside the window) → back to requested
        r = self.c.get("/api/v1/booking/mine")
        self.assertEqual(r.data["upcoming"][0]["id"], bid)
        self.assertIn("reschedule", r.data["upcoming"][0]["can"])
        r = self.c.get("/api/v1/booking/mine/%d/slots" % bid, {"day": day.isoformat()})
        self.assertIn(at(day, 10).isoformat(), [s["start"] for s in r.data["slots"]])  # own slot offered
        r = self.c.post("/api/v1/booking/mine/%d/action" % bid,
                        {"action": "reschedule", "start": at(day, 12).isoformat()}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["status"], "requested")
        self.assertEqual(BookingSlotLock.objects.filter(booking_id=bid).count(), 8)  # 40 min / 5
        self.assertEqual(BookingSlotLock.objects.filter(booking_id=bid,
                                                        at=at(day, 10)).count(), 0)
        # 10:00 is free again
        self.assertEqual(self.app_book(self.g, at(day, 10)).data["error"], "bad_phone")
        # customer cancels
        r = self.c.post("/api/v1/booking/mine/%d/action" % bid, {"action": "cancelled"}, format="json")
        self.assertEqual(r.data["status"], "cancelled")
        self.assertEqual(BookingSlotLock.objects.filter(booking_id=bid).count(), 0)
        # done / no-show on started bookings
        b2 = self.app_book(self.c, at(day, 14)).data["id"]
        b3 = self.app_book(self.c, at(day, 15)).data["id"]
        Booking.objects.filter(pk__in=[b2, b3]).update(status="confirmed",
                                                       start=timezone.now() - timedelta(minutes=5))
        r = self.o.post("/api/v1/booking/biz/bookings/%d/action" % b2, {"action": "done"}, format="json")
        self.assertEqual(r.data["status"], "done")
        r = self.o.post("/api/v1/booking/biz/bookings/%d/action" % b3, {"action": "no_show"}, format="json")
        self.assertEqual(r.data["status"], "no_show")
        r = self.c.get("/api/v1/booking/mine")
        self.assertEqual({b["status"] for b in r.data["past"]}, {"cancelled", "done", "no_show"})

    def test_customer_window_closed(self):
        self.setup_page(cancel_hours=48)
        b = self.app_book(self.c, at(tomorrow(), 11)).data
        r = self.c.post("/api/v1/booking/mine/%d/action" % b["id"], {"action": "cancelled"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (409, "too_late"))
        self.assertEqual(b["can"], [])
        # the business may still cancel and the customer is told
        r = self.o.post("/api/v1/booking/biz/bookings/%d/action" % b["id"], {"action": "cancelled"},
                        format="json")
        self.assertEqual(r.data["status"], "cancelled")

    def test_race_refused_by_db_constraint(self):
        """Two requests both pass the free-slot check; the UNIQUE lock rows
        let exactly one win."""
        self.setup_page()
        page = S.page_for(self.biz)
        svc = page.business.booking_services.get()
        start = at(tomorrow(), 16)
        S.create(page, svc, start, name="A", phone="+8801810000011", actor="customer")
        with mock.patch.object(S, "_valid_start", return_value=True):
            with self.assertRaises(S.BookingError) as cm:
                S.create(page, svc, start + timedelta(minutes=15), name="B",
                         phone="+8801810000012", actor="customer")
        self.assertEqual(cm.exception.code, "slot_taken")
        self.assertEqual(Booking.objects.filter(business=self.biz).count(), 1)

    def test_capacity_and_staff(self):
        self.setup_page(capacity=2)
        start = at(tomorrow(), 17)
        self.assertEqual(self.app_book(self.c, start).status_code, 201)
        c2 = APIClient()
        c2.force_authenticate(self.other)
        self.assertEqual(self.app_book(c2, start).status_code, 201)       # second seat
        u3 = User.objects.create_user(name="Third", phone="01510000004", password="pw")
        c3 = APIClient()
        c3.force_authenticate(u3)
        self.assertEqual(self.app_book(c3, start).data["error"], "slot_taken")
        # staff: each staff member is one resource
        r1 = self.o.post("/api/v1/booking/biz/staff", {"name": "Mina"}, format="json").data
        self.o.post("/api/v1/booking/biz/staff", {"name": "Joy"}, format="json")
        s2 = at(tomorrow(), 19)
        self.assertEqual(self.app_book(self.c, s2, staff=r1["id"]).status_code, 201)
        r = self.app_book(c2, s2)
        self.assertEqual(r.status_code, 201)
        self.assertEqual(r.data["staff"], "Joy")
        self.assertEqual(self.app_book(c3, s2).data["error"], "slot_taken")

    def test_guest_public_booking_needs_otp(self):
        self.setup_page()
        start = at(tomorrow(), 13)
        r = self.app_book(self.g, start, name="Guest", phone="01310000005")
        self.assertEqual((r.status_code, r.data["error"]), (401, "otp_required"))
        r = self.g.post("/api/v1/booking/p/rupa-salon/otp", {"phone": "01310000005"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (503, "sms_off"))
        fake = FakeSms()
        with mock.patch("core.otp.sms_available", return_value=True), \
                mock.patch("core.sms_gateway.adapter", return_value=fake), \
                mock.patch("core.otp._gen_code", return_value="123456"):
            r = self.g.post("/api/v1/booking/p/rupa-salon/otp", {"phone": "01310000005"}, format="json")
            self.assertEqual(r.status_code, 200, r.data)
            r = self.app_book(self.g, start, name="Guest", phone="01310000005", code="000000")
            self.assertEqual(r.data["error"], "bad_code")
            r = self.app_book(self.g, start, name="Guest", phone="01310000005", code="123456")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertTrue(r.data["manage_token"])
        self.assertEqual(Booking.objects.get(pk=r.data["id"]).channel, "web")

    def test_abuse_limits_pending_blocked_ip(self):
        self.setup_page()
        day = tomorrow()
        self.assertEqual(self.app_book(self.c, at(day, 9)).status_code, 201)
        self.assertEqual(self.app_book(self.c, at(day, 10)).status_code, 201)
        r = self.app_book(self.c, at(day, 11))
        self.assertEqual((r.status_code, r.data["error"]), (429, "too_many_pending"))
        # business blocks the number
        r = self.o.post("/api/v1/booking/biz/blocks", {"phone": "01810000002"}, format="json")
        self.assertTrue(r.data["blocked"])
        Booking.objects.filter(customer_user=self.cust).update(status="cancelled")
        r = self.app_book(self.c, at(day, 11))
        self.assertEqual((r.status_code, r.data["error"]), (403, "blocked"))
        # per-IP hourly cap
        BookingContact.objects.all().delete()
        Booking.objects.all().delete()
        with mock.patch.object(S, "knob", side_effect=lambda k: 2 if k == "booking_ip_per_hour" else S.KNOBS[k]):
            users = [User.objects.create_user(name="U%d" % i, phone="0171000010%d" % i, password="pw")
                     for i in range(3)]
            codes = []
            for i, u in enumerate(users):
                cl = APIClient()
                cl.force_authenticate(u)
                codes.append(self.app_book(cl, at(day, 12 + i)).status_code)
        self.assertEqual(codes, [201, 201, 429])

    def test_manual_booking_and_phone_privacy(self):
        self.setup_page()
        r = self.o.post("/api/v1/booking/biz/bookings",
                        {"service": self.svc, "start": at(tomorrow(), 18).isoformat(),
                         "name": "Walk-in", "phone": "01710000077"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.assertEqual((r.data["status"], r.data["channel"]), ("confirmed", "manual"))
        # the public page never lists bookings or phones
        r = self.g.get("/api/v1/booking/p/rupa-salon")
        self.assertNotIn("01710000077", str(r.data))
        self.assertNotIn("+8801710000077", str(r.data))


# ===================================================================== reminders
class ReminderTests(_Base):
    def _booking(self, hours_ahead=30, made_days=3):
        self.setup_page()
        start = timezone.now() + timedelta(hours=hours_ahead)
        start = L.granule_floor(start)
        page = S.page_for(self.biz)
        svc = page.business.booking_services.get()
        with mock.patch.object(S, "_valid_start", return_value=True):
            b, _ = S.create(page, svc, start, name="K", phone="+8801810000002",
                            user=self.cust, actor="customer")
        Booking.objects.filter(pk=b.pk).update(created_at=start - timedelta(days=made_days))
        b.refresh_from_db()
        return b

    def _now(self, b, before, hour=None):
        n = b.start - before
        return n

    def test_24h_then_2h_then_nothing(self):
        b = self._booking()
        n24 = b.start - timedelta(hours=23)
        with mock.patch.object(L, "in_quiet_hours", return_value=False):
            self.assertEqual(S.send_due_reminders(now=n24), 1)
            self.assertEqual(S.send_due_reminders(now=n24 + timedelta(minutes=5)), 0)
            self.assertEqual(S.send_due_reminders(now=b.start - timedelta(hours=1, minutes=55)), 1)
            self.assertEqual(S.send_due_reminders(now=b.start - timedelta(minutes=30)), 0)
        b.refresh_from_db()
        self.assertEqual((b.reminders_sent, b.reminded), (2, ["24h", "2h"]))
        self.assertEqual(NotifEvent.objects.filter(user=self.cust, route="my_bookings").count(), 2)

    def test_quiet_hours_send_nothing(self):
        b = self._booking()
        with mock.patch.object(L, "in_quiet_hours", return_value=True):
            self.assertEqual(S.send_due_reminders(now=b.start - timedelta(hours=23)), 0)
        b.refresh_from_db()
        self.assertEqual(b.reminders_sent, 0)
        # real clock check: 23:30 Dhaka is quiet, 08:00 is not
        self.assertTrue(L.in_quiet_hours(at(tomorrow(), 23, 30)))
        self.assertFalse(L.in_quiet_hours(at(tomorrow(), 8)))

    def test_stop_honoured(self):
        b = self._booking()
        S.set_contact(self.biz, b.customer_phone, stop=True)
        with mock.patch.object(L, "in_quiet_hours", return_value=False):
            S.send_due_reminders(now=b.start - timedelta(hours=23))
        b.refresh_from_db()
        self.assertEqual(b.reminded, ["24h"])          # counted, never sent
        self.assertFalse(NotifEvent.objects.filter(user=self.cust, route="my_bookings").exists())
        self.assertEqual(b.history[-1]["what"], "reminder_skipped_stop")

    def test_sms_only_when_on_paid_and_capped(self):
        b = self._booking()
        Booking.objects.filter(pk=b.pk).update(customer_user=None)      # guest: no app
        fake = FakeSms()
        page = S.page_for(self.biz)
        with mock.patch.object(L, "in_quiet_hours", return_value=False), \
                mock.patch("core.sms_gateway.adapter", return_value=fake):
            S.send_due_reminders(now=b.start - timedelta(hours=23))     # SMS off → nothing
            self.assertEqual(fake.sent, [])
            page.sms_reminders = True
            page.save()
            with mock.patch("core.billing.charge",
                            return_value={"ok": False, "reason": "insufficient", "charged": 0}):
                S.send_due_reminders(now=b.start - timedelta(hours=1, minutes=55))   # no credits
            self.assertEqual(fake.sent, [])
        b2 = Booking.objects.get(pk=b.pk)
        self.assertEqual(b2.reminders_sent, 2)
        # with credits: one SMS, one credit charged
        b3 = self._booking_more(hours_ahead=40)
        self.owner.refresh_from_db()
        self.owner.ai_credits = 10
        self.owner.save()
        with mock.patch.object(L, "in_quiet_hours", return_value=False), \
                mock.patch("core.sms_gateway.adapter", return_value=fake):
            S.send_due_reminders(now=b3.start - timedelta(hours=23))
        self.assertEqual(len(fake.sent), 1)
        from core.models import CreditLedger
        self.assertEqual(CreditLedger.objects.filter(user=self.owner, note="booking.reminder",
                                                     reason="consume").count(), 1)
        # cap 0 → none
        b4 = self._booking_more(hours_ahead=50)
        with mock.patch.object(L, "in_quiet_hours", return_value=False), \
                mock.patch("core.sms_gateway.adapter", return_value=fake), \
                mock.patch.object(S, "knob", side_effect=lambda k: 0 if k == "booking_sms_per_biz_day" else S.KNOBS[k]):
            S.send_due_reminders(now=b4.start - timedelta(hours=23))
        self.assertEqual(len(fake.sent), 1)

    def _booking_more(self, hours_ahead):
        page = S.page_for(self.biz)
        svc = page.business.booking_services.get()
        start = L.granule_floor(timezone.now() + timedelta(hours=hours_ahead))
        with mock.patch.object(S, "_valid_start", return_value=True):
            b, _ = S.create(page, svc, start, name="G", phone="+8801310000009", actor="customer")
        Booking.objects.filter(pk=b.pk).update(created_at=start - timedelta(days=3))
        b.refresh_from_db()
        return b


# ===================================================================== chat bot
from core.tests_p1_bizagent import Base as _BizBase, wapayload, setUpModule, tearDownModule  # noqa: E402,F401


@override_settings(BIZAGENT_SYNC=True)
class ChatBotTests(_BizBase):
    def setUp(self):
        super().setUp()
        flag(True)
        self.addCleanup(FF.invalidate)
        self.user.plan = "business"
        self.user.plan_until = timezone.now() + timedelta(days=30)
        self.user.save()
        page = S.page_for(self.biz)
        page.weekly_hours = ALL_WEEK
        page.enabled = True
        page.auto_confirm = True
        page.min_notice_min = 0
        page.save()
        from core.models import BookingService
        self.svc = BookingService.objects.create(business=self.biz, name="Facial",
                                                 duration_min=60, price_bdt=800)
        p = mock.patch("core.push.safe_push", return_value=0)
        p.start()
        self.addCleanup(p.stop)

    def say(self, text, n):
        self.post_wa(wapayload(text, "wamid.bk%d" % n, frm="8801710000055"))
        return self.outs(self.thread(self.wa))[-1].text

    def test_bot_offers_real_slots_and_books(self):
        reply = self.say("ami kal ekta appointment nite chai", 1)
        self.assertIn("Facial", reply)
        t = self.thread(self.wa)
        offered = t.order_draft["bk"]["slots"]
        self.assertTrue(1 <= len(offered) <= L.BOT_OPTIONS)
        page = S.page_for(self.biz)
        day = datetime.fromisoformat(offered[0]["start"]).date()
        real = [L.local(s["start"]).isoformat() for s in S.slots(page, self.svc, day)]
        for o in offered:
            self.assertIn(o["start"], real)                  # never invented
        reply = self.say("1", 2)
        # WhatsApp gives the phone; the customer name came from the profile
        self.assertTrue("হ্যাঁ" in reply or "yes" in reply.lower())
        reply = self.say("ha", 3)
        b = Booking.objects.get(business=self.biz)
        self.assertEqual((b.status, b.channel, b.thread_id), ("confirmed", "whatsapp_cloud", t.pk))
        self.assertEqual(b.start.isoformat(), datetime.fromisoformat(offered[0]["start"]).astimezone(b.start.tzinfo).isoformat())
        self.assertEqual(b.customer_phone, "+8801710000055")
        self.assertNotIn("bk", self.thread(self.wa).order_draft)
        # cancel by chat
        reply = self.say("booking ta cancel korte chai", 4)
        b.refresh_from_db()
        self.assertEqual(b.status, "cancelled")

    def test_bot_silent_when_flag_off(self):
        flag(False)
        self.say("appointment chai", 5)
        self.assertFalse(self.thread(self.wa).order_draft.get("bk"))

    def test_slot_taken_meanwhile(self):
        self.say("appointment chai", 6)
        self.say("1", 7)
        t = self.thread(self.wa)
        st = t.order_draft["bk"]
        page = S.page_for(self.biz)
        start = datetime.fromisoformat(st["start"])
        S.create(page, self.svc, start, name="Walk-in", actor="business")
        reply = self.say("yes", 8)
        self.assertIn("1.", reply)          # fresh real options listed again
        self.assertEqual(Booking.objects.filter(business=self.biz).count(), 1)


# ===================================================================== web page
class WebPageTests(_Base):
    def test_public_web_page_book_with_code_then_manage(self):
        self.setup_page(cancel_hours=2)
        from django.test import Client
        w = Client()
        day = tomorrow()
        r = w.get("/b/rupa-salon")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "Haircut")
        self.assertEqual(r["X-Robots-Tag"], "noindex")
        r = w.get("/b/rupa-salon", {"service": self.svc, "day": day.isoformat(), "lang": "en"})
        start = at(day, 11).isoformat()
        self.assertContains(r, start)                  # a real free time is offered
        fake = FakeSms()
        with mock.patch("core.otp.sms_available", return_value=True), \
                mock.patch("core.sms_gateway.adapter", return_value=fake), \
                mock.patch("core.otp._gen_code", return_value="654321"):
            form = {"service": self.svc, "day": day.isoformat(), "start": start,
                    "name": "Web Guest", "phone": "01310000044"}
            r = w.post("/b/rupa-salon?lang=en", dict(form, action="send"))
            self.assertContains(r, "6-digit code")
            self.assertEqual(len(fake.sent), 1)
            r = w.post("/b/rupa-salon?lang=en", dict(form, action="book", code="111111"))
            self.assertContains(r, "did not match", status_code=400)
            r = w.post("/b/rupa-salon?lang=en", dict(form, action="book", code="654321"))
        self.assertEqual(r.status_code, 302)
        manage = r["Location"]
        self.assertTrue(manage.startswith("/b/m/"))
        b = Booking.objects.get(customer_phone="+8801310000044")
        self.assertEqual((b.status, b.channel), ("confirmed", "web"))
        r = w.get(manage)
        self.assertContains(r, "Booked")
        token = manage.split("/b/m/")[1].split("?")[0]
        r = w.post("/b/m/%s?lang=en" % token, {"action": "stop"})
        self.assertContains(r, "Reminders are stopped")
        self.assertTrue(BookingContact.objects.get(phone="+8801310000044").stop)
        r = w.post("/b/m/%s?lang=en" % token, {"action": "cancel"})
        self.assertContains(r, "cancelled")
        b.refresh_from_db()
        self.assertEqual(b.status, "cancelled")
        self.assertEqual(w.get("/b/m/not-a-real-token").status_code, 404)

    def test_web_page_hidden_when_flag_off_and_sms_off_honest(self):
        self.setup_page()
        from django.test import Client
        w = Client()
        day = tomorrow()
        form = {"service": self.svc, "day": day.isoformat(), "start": at(day, 11).isoformat(),
                "name": "G", "phone": "01310000045", "action": "send"}
        r = w.post("/b/rupa-salon", form)
        self.assertEqual(r.status_code, 503)
        self.assertContains(r, "SMS", status_code=503)
        flag(False)
        self.assertEqual(w.get("/b/rupa-salon").status_code, 404)
