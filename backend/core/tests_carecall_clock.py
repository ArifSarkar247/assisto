"""carecallfix — Care Call tick with a FROZEN clock (regression for the
nightly E2E e2e8 'carecall_tick made 0', red since 11 Nov).

Root cause: since fcbrain (9 Nov, Probashi) a Care Call time is on the
RECEIVER's clock — the zone their phone reports on every app open. The CI
emulator runs on UTC, so the receiver's clock was UTC while the E2E typed the
time on the Dhaka clock: the slot landed 6 h later and the +3 min tick made 0.

These tests replay the E2E path through the real API + the real
`carecall_tick` command (exactly what /ci-e2e/tick runs) with the clock
frozen at several moments — including just after Dhaka midnight and around
the UTC date change — for a Dhaka phone, a UTC phone and a Dubai phone."""
import io
from datetime import datetime, timedelta, timezone as dt_tz
from unittest import mock

from django.core.cache import cache
from django.core.management import call_command

from core import carecall as CC
from core import family_brain as FB
from core.models import CareCall, CareCallRing

from .tests_carecall import TZ, V, Base

# Dhaka wall-clock moments (y, m, d, h, mi)
MOMENTS = [
    (2026, 11, 16, 9, 0),     # morning
    (2026, 11, 16, 7, 16),    # the failing nightly ran at 07:16 Dhaka
    (2026, 11, 16, 23, 58),   # just before Dhaka midnight (slot crosses it)
    (2026, 11, 17, 0, 1),     # just after Dhaka midnight (UTC is still the 16th)
    (2026, 11, 17, 0, 30),
    (2026, 11, 17, 5, 59),    # just before UTC midnight
    (2026, 11, 17, 6, 1),     # just after UTC midnight
    (2026, 11, 30, 23, 59),   # month end (monthly ring cap window)
]
PHONES = [None, 0, 240]       # receiver phone: never pinged (Dhaka) / UTC / Dubai


def frozen(t):
    return mock.patch("django.utils.timezone.now", lambda: t)


def tick_made(t):
    out = io.StringIO()
    with frozen(t):
        call_command("carecall_tick", stdout=out)
    s = out.getvalue()
    return int(s.split("made ")[1].split()[0]), s


class FrozenClockTickTests(Base):
    def setUp(self):
        cache.clear()
        super().setUp()

    def _phone(self, off, t):
        """The receiver's phone tells the server its clock (FcWatch ping)."""
        if off is None:
            return TZ
        with frozen(t):
            FB.ping(self.ammu, {"tz_offset_min": off}, now=t)
        cache.clear()
        rz = CC.rtz(self.ammu)
        self.assertEqual(rz.utcoffset(None) if hasattr(rz, "utcoffset") else None,
                         timedelta(minutes=off), "ping did not set the receiver's clock")
        return rz

    def _reset(self):
        CareCallRing.objects.all().delete()
        CareCall.objects.all().delete()
        self.spy.calls.clear()

    def test_once_in_two_minutes_rings_at_plus_three_every_moment_every_zone(self):
        first = True
        for off in PHONES:
            for m in MOMENTS:
                with self.subTest(phone_offset=off, dhaka=m):
                    self._reset()
                    t = datetime(*m, tzinfo=TZ)
                    rz = self._phone(off, t)
                    at = (t + timedelta(minutes=2)).astimezone(rz)
                    # quiet hours far from the slot (as the E2E does)
                    q = (t + timedelta(hours=12)).astimezone(rz)
                    with frozen(t):
                        self.m.post(V + "/carecall/quiet",
                                    {"start": q.strftime("%H:%M"),
                                     "end": (q + timedelta(minutes=1)).strftime("%H:%M")},
                                    format="json")
                        r = self.new(repeat="once", time=at.strftime("%H:%M"),
                                     date=at.date().isoformat())
                        self.assertEqual(r.status_code, 201, r.content)
                        if first:
                            self.assertEqual(self.accept().status_code, 200, "consent")
                            first = False
                    cc = CareCall.objects.get()
                    self.assertEqual(cc.next_at, at.replace(second=0, microsecond=0),
                                     "slot is not 2 min ahead on the receiver's clock")
                    self.assertEqual(tick_made(t + timedelta(minutes=1))[0], 0)  # not yet
                    made, s = tick_made(t + timedelta(minutes=3))
                    self.assertEqual(made, 1, s)
                    self.assertIn("carecall", self.spy.kinds(self.ammu), s)
                    cc.refresh_from_db()
                    self.assertFalse(cc.active)              # a once is used up
                    self.assertEqual(tick_made(t + timedelta(minutes=4))[0], 0)  # never twice

    def test_daily_just_after_midnight_on_the_receivers_clock(self):
        for off in PHONES:
            with self.subTest(phone_offset=off):
                self._reset()
                t0 = datetime(2026, 11, 16, 12, 0, tzinfo=dt_tz.utc)
                rz = self._phone(off, t0)
                with frozen(t0):
                    self.assertEqual(self.new(time="00:01").status_code, 201)
                    self.accept()
                cc = CareCall.objects.get()
                loc = cc.next_at.astimezone(rz)
                self.assertEqual((loc.hour, loc.minute), (0, 1))
                for day in range(3):                   # three nights in a row
                    slot = cc.next_at
                    made, s = tick_made(slot + timedelta(minutes=1))
                    self.assertEqual(made, 1, s)
                    cc.refresh_from_db()
                    self.assertEqual(cc.next_at, slot + timedelta(days=1))

    def test_dhaka_typed_time_on_a_utc_phone_is_six_hours_later(self):
        """Documents the design the old E2E missed: the time is the
        RECEIVER's, so a Dhaka-clock time for a UTC phone is 6 h away and
        the +3 min tick correctly makes nothing."""
        t = datetime(2026, 11, 16, 7, 16, tzinfo=TZ)
        self._phone(0, t)
        at = t + timedelta(minutes=2)                # Dhaka wall clock
        with frozen(t):
            self.new(repeat="once", time=at.strftime("%H:%M"), date=at.date().isoformat())
            self.accept()
        cc = CareCall.objects.get()
        self.assertEqual(cc.next_at - at.replace(second=0), timedelta(hours=6))
        self.assertEqual(tick_made(t + timedelta(minutes=3))[0], 0)

    def test_once_without_date_is_today_on_the_receivers_clock(self):
        """Just after Dhaka midnight a UTC-phone receiver is still on the
        previous day: a dateless 'once' at 23:00 is tonight on THEIR clock."""
        t = datetime(2026, 11, 17, 0, 1, tzinfo=TZ)   # 16 Nov 18:01 UTC
        rz = self._phone(0, t)
        with frozen(t):
            self.assertEqual(self.new(repeat="once", time="23:00").status_code, 201)
            self.accept()
        cc = CareCall.objects.get()
        self.assertIsNotNone(cc.next_at)
        loc = cc.next_at.astimezone(rz)
        self.assertEqual((loc.day, loc.hour), (16, 23))
        self.assertEqual(tick_made(cc.next_at + timedelta(minutes=1))[0], 1)
