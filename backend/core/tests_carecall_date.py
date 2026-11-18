"""gap-carecall — the one-time ("once") Care Call date bug (board row 21).

The server runs on UTC; a Care Call time is on the RECEIVER's clock (Dhaka
UTC+6 by default, the phone's zone for a Probashi). Before the fix:
  * a "once" with no date meant "today" even when that time had passed —
    saved as ON, next_at None: it could never ring and nobody was told;
  * a date + time already past was saved the same way (silently dead);
  * a "once" whose time passed while waiting for consent stayed ON forever;
  * editing a "once" that already rang to a new time never re-armed it;
  * the app had no way to know the receiver's clock (it planned "today /
    tomorrow" and the receiver's own alarms on Dhaka's calendar).
Every test here failed before the fix (frozen clocks, UTC server)."""
from datetime import datetime, timedelta, timezone as dt_tz
from unittest import mock

from django.core.cache import cache

from core import carecall as CC
from core import family_brain as FB
from core.models import CareCall

from .tests_carecall import TZ, V, Base


def frozen(t):
    return mock.patch("django.utils.timezone.now", lambda: t)


def dhaka(y, mo, d, h, mi):
    return datetime(y, mo, d, h, mi, tzinfo=TZ)


class OnceDateTests(Base):
    def setUp(self):
        cache.clear()
        super().setUp()

    def _phone(self, off, t):
        with frozen(t):
            FB.ping(self.ammu, {"tz_offset_min": off}, now=t)
        cache.clear()
        return CC.rtz(self.ammu)

    def test_dateless_once_after_the_time_passed_is_tomorrow(self):
        # 18 Nov 10:00 Dhaka = 04:00 UTC on the server
        t = dhaka(2026, 11, 18, 10, 0)
        with frozen(t):
            r = self.new(repeat="once", time="09:00")
        self.assertEqual(r.status_code, 201, r.content)
        cc = CareCall.objects.get()
        self.assertTrue(cc.active)
        self.assertEqual(cc.next_at, dhaka(2026, 11, 19, 9, 0), "a dead 'once' was saved (next_at None)")
        self.assertEqual(r.json()["care_call"]["date"], "2026-11-19")

    def test_dateless_once_just_after_dhaka_midnight_uses_dhakas_day(self):
        # 18 Nov 00:30 Dhaka = 17 Nov 18:30 UTC: the server's own date is the 17th
        t = dhaka(2026, 11, 18, 0, 30)
        self.assertEqual(t.astimezone(dt_tz.utc).day, 17)
        with frozen(t):
            self.assertEqual(self.new(repeat="once", time="00:10").status_code, 201)
            self.assertEqual(self.new(repeat="once", time="23:00").status_code, 201)
        a, b = CareCall.objects.order_by("id")
        self.assertEqual(a.next_at, dhaka(2026, 11, 19, 0, 10))   # passed today -> tomorrow
        self.assertEqual(b.next_at, dhaka(2026, 11, 18, 23, 0))   # tonight, Dhaka's 18th

    def test_past_date_and_time_is_refused_never_saved_dead(self):
        t = dhaka(2026, 11, 18, 10, 0)
        with frozen(t):
            r = self.new(repeat="once", time="09:30", date="2026-11-18")
            r2 = self.new(repeat="once", time="09:00", date="2026-11-17")
            ok = self.new(repeat="once", time="10:05", date="2026-11-18")
        self.assertEqual(r.status_code, 400, r.content)
        self.assertEqual(r.json()["reason"], "past_time")
        self.assertIn("passed", r.json()["detail"])
        self.assertEqual(r2.status_code, 400)
        self.assertEqual(ok.status_code, 201, ok.content)
        self.assertEqual(CareCall.objects.count(), 1)
        self.assertEqual(CareCall.objects.get().next_at, dhaka(2026, 11, 18, 10, 5))

    def test_past_time_message_in_bangla(self):
        t = dhaka(2026, 11, 18, 10, 0)
        with frozen(t):
            self.a.credentials(HTTP_ACCEPT_LANGUAGE="bn")
            r = self.new(repeat="once", time="09:30", date="2026-11-18")
        self.assertIn("পেরিয়ে গেছে", r.json()["detail"])

    def test_receiver_ahead_of_dhaka_date_is_on_their_calendar(self):
        # 18 Nov 23:00 Dhaka = 19 Nov 01:00 for a parent in Malaysia (+8)
        t = dhaka(2026, 11, 18, 23, 0)
        rz = self._phone(480, t)
        with frozen(t):
            dead = self.new(repeat="once", time="23:30", date="2026-11-18")   # Dhaka's day
            good = self.new(repeat="once", time="23:30")                      # no date
        self.assertEqual(dead.status_code, 400, "a past slot on THEIR clock was saved dead")
        self.assertEqual(good.status_code, 201)
        loc = CareCall.objects.get().next_at.astimezone(rz)
        self.assertEqual((loc.day, loc.hour, loc.minute), (19, 23, 30))

    def test_the_app_is_told_the_receivers_clock(self):
        t = dhaka(2026, 11, 18, 10, 0)
        with frozen(t):
            ppl = self.a.get(V + "/carecall/people").json()
            row = next(p for p in (ppl.get("results") or ppl.get("people") or ppl)
                       if p["user_id"] == self.ammu.pk)
            self.assertEqual(row["tz_offset_min"], 360)
            self.new(time="11:00")
        self._phone(0, t)                       # the receiver's phone is on UTC
        with frozen(t):
            mine = self.m.get(V + "/carecall").json()
            sent = self.a.get(V + "/carecall").json()["sent"][0]
        self.assertEqual(sent["receiver_offset_min"], 0)
        ppl = self.a.get(V + "/carecall/people").json()
        row = next(p for p in (ppl.get("results") or ppl.get("people") or ppl)
                   if p["user_id"] == self.ammu.pk)
        self.assertEqual(row["tz_offset_min"], 0)
        self.assertIn("received", mine)

    def test_once_that_passed_before_consent_turns_off(self):
        t = dhaka(2026, 11, 18, 10, 0)
        with frozen(t):
            self.assertEqual(self.new(repeat="once", time="10:30").status_code, 201)
        with frozen(t + timedelta(hours=2)):    # accepted at 12:00: 10:30 is gone
            self.assertEqual(self.accept().status_code, 200)
        cc = CareCall.objects.get()
        self.assertIsNone(cc.next_at)
        self.assertFalse(cc.active, "a 'once' that can never ring was left ON")

    def test_editing_a_rung_once_to_a_new_time_re_arms_it(self):
        t = dhaka(2026, 11, 18, 10, 0)
        with frozen(t):
            cid = self.new(repeat="once", time="10:05").json()["care_call"]["id"]
            self.accept()
        CC.tick(now=dhaka(2026, 11, 18, 10, 5))
        cc = CareCall.objects.get()
        self.assertFalse(cc.active)                 # used up
        with frozen(dhaka(2026, 11, 18, 11, 0)):
            r = self.a.post(V + "/carecall/%d" % cid,
                            {"text": "again", "time": "09:00", "repeat": "once", "date": "2026-11-19"},
                            format="json")
        self.assertEqual(r.status_code, 200, r.content)
        cc.refresh_from_db()
        self.assertTrue(cc.active, "the edited one-time call stayed OFF")
        self.assertEqual(cc.next_at, dhaka(2026, 11, 19, 9, 0))
