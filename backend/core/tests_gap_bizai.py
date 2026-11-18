"""gap-bizai (17 Nov): Business AI gaps a real shop owner would notice.
  * win-back ladder: the in-app path reaches ONLY customers on Assisto — the
    ladder now says how many (never implies all N get it);
  * approving a draft in one language never resets the other language to
    the default; the owner's own edit gets a reason they can fix;
  * daily summary: chase rows carry what the app needs to open THAT
    customer's tagada; dues are summed in the DB; "ক্যাশ" for cash (never
    "নগদ", which is also the Nagad wallet)."""
from datetime import timedelta

from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from core.models import (BusinessProfile, Customer, KhataEntry, KhataParty,
                         RetentionAutomation, Sale, User)
from core.tests_retention import _Base

API = "/api/v1/"


class LadderGapTests(_Base):
    def sale_(self, cust, days_ago):
        s = Sale.objects.create(user=self.owner, business=self.biz, customer=cust, total=50000)
        Sale.objects.filter(pk=s.pk).update(created_at=timezone.now() - timedelta(days=days_ago))

    def test_ladder_says_how_many_are_on_assisto(self):
        babu = Customer.objects.create(user=self.owner, business=self.biz, name="Babu",
                                       phone="01710000077", phone_key="01710000077")
        self.sale_(self.cust, 40)        # Karim — has an Assisto account
        self.sale_(babu, 41)             # Babu — not on Assisto
        r = self.oc.get(API + "bizai/crm/ladder").data
        st = {s["stage"]: s for s in r["stages"]}
        self.assertEqual((st["wb30"]["audience"], st["wb30"]["on_assisto"]), (2, 1))
        self.assertEqual(st["wb60"]["on_assisto"], 0)

    def test_one_language_draft_keeps_the_other(self):
        r = self.oc.post(API + "bizai/crm/ladder",
                         {"drafts": {"wb30": {"en": "Hi {name}, come by {shop} soon."}}},
                         format="json")
        self.assertEqual(r.status_code, 200, r.data)
        r = self.oc.post(API + "bizai/crm/ladder",
                         {"drafts": {"wb30": {"bn": "{name}, {shop}-এ একবার আসুন।"}}},
                         format="json")
        self.assertEqual(r.status_code, 200, r.data)
        a = RetentionAutomation.objects.get(business=self.biz, name="Win-back 30")
        self.assertEqual(a.template_en, "Hi {name}, come by {shop} soon.")
        self.assertEqual(a.template_bn, "{name}, {shop}-এ একবার আসুন।")

    def test_owner_edit_problem_is_explained(self):
        r = self.oc.post(API + "bizai/crm/ladder",
                         {"drafts": {"wb30": {"bn": "{name} {price}"}}}, format="json",
                         HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 400)
        self.assertEqual(r.data["reason"], "unknown_variable")
        self.assertIn("{name}", r.data["detail"])
        # a Bangla word in braces is caught too (the customer never gets "{দাম}")
        r = self.oc.post(API + "bizai/crm/ladder",
                         {"drafts": {"wb30": {"bn": "{name}, {দাম} কমেছে"}}}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "unknown_variable"))


class DailyGapTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Rahim", phone="01710000951",
                                              password="pw-123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.oc = APIClient()
        self.oc.force_authenticate(self.owner)
        now = timezone.now()
        self.karim = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712000051")
        self.selim = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Selim", phone="01712000052")
        for d, a, ago in (("gave", 30000, 20), ("gave", 20000, 10), ("got", 10000, 5),
                          ("gave", 5000, 1)):
            KhataEntry.objects.create(party=self.karim, direction=d, amount_poisha=a,
                                      at=now - timedelta(days=ago))
        KhataEntry.objects.create(party=self.selim, direction="gave", amount_poisha=60000,
                                  at=now - timedelta(days=3))
        KhataEntry.objects.create(party=self.selim, direction="got", amount_poisha=60000,
                                  at=now - timedelta(days=2))      # Selim owes nothing
        s = Sale.objects.create(user=self.owner, business=self.biz, total=50000,
                                payment_method="cash")
        Sale.objects.create(user=self.owner, business=self.biz, total=20000,
                            payment_method="nagad")
        self.assertTrue(s.pk)

    def test_chase_rows_open_the_tagada_and_sums_are_right(self):
        r = self.oc.get(API + "bizai/daily", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["business_id"], self.biz.pk)
        self.assertEqual(r.data["shop"], "Rahim Store")
        self.assertEqual(len(r.data["chase"]), 1)
        c = r.data["chase"][0]
        self.assertEqual((c["party_id"], c["name"], c["due_poisha"]),
                         (self.karim.pk, "Karim", 45000))
        self.assertNotIn("01712000051", str(r.data))      # still no phone numbers
        text = " ".join(r.data["lines"])
        self.assertIn("ক্যাশ ৳৫০০.০০", text)
        self.assertIn("নগদ (Nagad) ৳২০০.০০", text)
        self.assertNotIn("নগদ ৳৫০০", text)


# ---------------------------------------------------------------- Prochar scheduler
from core import bizai_prochar as BP  # noqa: E402
from core import mktengine_service as MS  # noqa: E402
from core.models import Reminder  # noqa: E402
from core.tests_bizai import API as BAPI, ShopChatBase  # noqa: E402


class ProcharRemindTests(ShopChatBase):
    """gap-bizai: "schedule at the best time" — honestly, without Meta: a
    reminder at the shop's best posting hour carrying the tracked text."""
    def setUp(self):
        super().setUp()
        MS._store_plan(self.user, self.biz, {"items": [
            {"id": "post1", "section": "content", "kind": "post", "title": "Post: Panjabi",
             "body": "Eid Panjabi — ৳1200", "product": "Panjabi", "status": "approved"}]})
        self.c.force_authenticate(self.user)

    def test_remind_creates_one_reminder_with_the_tracked_text(self):
        r = self.c.post(BAPI + "bizai/prochar/remind", {"item_id": "post1"}, format="json",
                        HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual((r.data["basis"], r.data["hour"]), ("default", BP.DEFAULT_POST_HOUR))
        self.assertIn("রাত ৮টা", r.data["when"])
        rem = Reminder.objects.get(user=self.user)
        self.assertIn(BP.post_ref(self.biz, "post1"), rem.notes)     # tracked code inside
        self.assertIn("Eid Panjabi", rem.notes)
        self.assertEqual(rem.link["type"], "prochar")
        self.assertGreater(rem.due_at, timezone.now())
        # asking again moves the same reminder — never a pile of duplicates
        r = self.c.post(BAPI + "bizai/prochar/remind", {"item_id": "post1", "hour": 9},
                        format="json")
        self.assertEqual(r.data["hour"], 9)
        self.assertEqual(Reminder.objects.filter(user=self.user).count(), 1)
        self.assertEqual(self.c.post(BAPI + "bizai/prochar/remind", {"item_id": "nope"},
                                     format="json").status_code, 404)

    def test_hour_labels_are_plain_words(self):
        self.assertEqual(BP.hour_label(20, "bn"), "রাত ৮টা")
        self.assertEqual(BP.hour_label(10, "bn"), "সকাল ১০টা")
        self.assertEqual(BP.hour_label(17, "bn"), "বিকেল ৫টা")
        self.assertEqual(BP.hour_label(0, "en"), "12 am")
        self.assertEqual(BP.hour_label(13, "en"), "1 pm")


# ---------------------------------------------------------------- booking reminders
from unittest import mock  # noqa: E402

from core import booking_service as BS  # noqa: E402
from core.logic import booking as BL  # noqa: E402
from core.logic import msg_guard as MG  # noqa: E402
from core.logic.business_selling import normalize_phone  # noqa: E402
from core.models import Booking, NotifEvent  # noqa: E402
from core.tests_booking_bot import _Base as _BookBase  # noqa: E402


class BookingStopTests(_BookBase):
    """gap-bizai: a STOP from the shop's shared list (an SMS stop link, an
    in-app Stop) also silences booking reminders — not just the booking
    page's own contact flag."""
    def test_shop_wide_stop_silences_booking_reminders(self):
        self.setup_page()
        start = BL.granule_floor(timezone.now() + timedelta(hours=30))
        page = BS.page_for(self.biz)
        svc = page.business.booking_services.get()
        with mock.patch.object(BS, "_valid_start", return_value=True):
            b, _ = BS.create(page, svc, start, name="K", phone="+8801810000002",
                             user=self.cust, actor="customer")
        Booking.objects.filter(pk=b.pk).update(created_at=start - timedelta(days=3))
        b.refresh_from_db()
        MG.record_opt_out(self.biz.pk, normalize_phone("+8801810000002"))
        with mock.patch.object(BL, "in_quiet_hours", return_value=False):
            BS.send_due_reminders(now=b.start - timedelta(hours=23))
        b.refresh_from_db()
        self.assertEqual(b.reminded, ["24h"])          # counted, never sent
        self.assertFalse(NotifEvent.objects.filter(user=self.cust, route="my_bookings").exists())
