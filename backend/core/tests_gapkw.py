"""gap-kidswatch (17 Nov) — the kids-watch gaps a real parent would hit:

  1 P0 a watch paired with no SOS numbers had an SOS button that called
    nobody -> the parent's own phone is the default first SOS number, and it
    is queued to the watch on connect;
  2 P0 SOS numbers typed on a Bangla keyboard ('০১৭…') were stored as Bangla
    digits (str.isdigit() is True for them) -> converted to 0-9;
  3 P1 the watch's SIM number is saved (pair + edit) so guardians can CALL
    the watch in one tap; the SOS push / alert carries it;
  4 P1 an active watch SOS shows on the watch card (sos_at) for an hour;
  5 P1 the watch can be linked to the child's own Assisto account after
    pairing (Circle peers only);
  6 P1 a watch that goes silent (battery dead / data over / off) is told to
    its guardians once per silence, daytime only;
  7 the honest line holds: none of this ever builds a listening command.
"""
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from django.core.cache import cache
from django.test import TestCase

from core import kidswatch_service as KW
from core.models import FamilyAlert, KidsWatch, KidsWatchCommand
from core.tests_kidswatch import HOME, V, cl, flag, mk, pair_circle
from tracker.protocols import watch as WP

DHAKA = ZoneInfo("Asia/Dhaka")


class _Spy:
    def __init__(self):
        self.calls = []

    def __call__(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "ten": ten, "ben": ben,
                           "tbn": tbn, "bbn": bbn, "data": dict(data or {})})
        return True

    def to(self, u, kind=None):
        return [c for c in self.calls if c["user"] == u.pk and (kind is None or
                                                                c["kind"] == kind)]


class GapKidsWatchTests(TestCase):
    def setUp(self):
        cache.clear()
        flag(True)
        self.owner = mk("01711500001", "Abba", credits=500)
        self.mom = mk("01711500002", "Ammu")
        self.child = mk("01711500003", "Rina")
        self.x = mk("01711500004", "Stranger")
        pair_circle(self.owner, self.mom)
        pair_circle(self.owner, self.child)
        self.spy = _Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy)
        p.start()
        self.addCleanup(p.stop)
        self.c = cl(self.owner)

    def pair(self, **kw):
        body = {"code": "8800000077", "child_name": "Rina", "guardian_ids": [self.mom.id]}
        body.update(kw)
        r = self.c.post(V + "/kids-watch/watches", body, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        return r, KidsWatch.objects.get(pk=r.data["watch"]["id"])

    # ---- 1 P0: SOS button always calls someone
    def test_no_sos_numbers_defaults_to_parent_phone_and_reaches_the_watch(self):
        r, w = self.pair()
        self.assertTrue(r.data["sos_defaulted"])
        self.owner.refresh_from_db()      # stored normalised (e.g. +880...)
        own = "".join(ch for ch in self.owner.phone if ch.isdigit() or ch == "+")
        self.assertEqual(w.sos_numbers, [own])
        self.assertTrue(r.data["watch"]["sos_ready"])
        KW.on_watch_connect("8800000077", "3G")
        cmd = KidsWatchCommand.objects.get(watch=w, kind="sos_numbers")
        content, typ = WP.command_content(cmd.kind, cmd.payload)
        self.assertEqual(typ, "SOS")
        self.assertIn(own.encode(), content)

    def test_given_numbers_are_kept_not_defaulted(self):
        r, w = self.pair(sos_numbers=["01811000002"])
        self.assertFalse(r.data["sos_defaulted"])
        self.assertEqual(w.sos_numbers, ["01811000002"])

    # ---- 2 P0: Bangla keyboard digits
    def test_bangla_digits_become_latin_and_other_scripts_refused(self):
        _r, w = self.pair(sos_numbers=["০১৭১১-০০০০০৯"], sim_phone="০১৯১১ ০০০০০৮")
        self.assertEqual(w.sos_numbers, ["01711000009"])
        self.assertEqual(w.sim_phone, "01911000008")
        r = self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                         {"sos_numbers": ["٠١٧١١٠٠٠٠٠٩"]}, format="json")   # Arabic-Indic
        self.assertEqual(r.status_code, 400)
        r = self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                         {"sim_phone": "12"}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "bad_phone"))

    # ---- 3 P1: call the watch + SOS carries the number
    def test_sim_phone_edit_visible_to_guardian_and_sos_push_carries_it(self):
        _r, w = self.pair()
        r = self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                         {"sim_phone": "01911000008", "sos_numbers": ["01711500001",
                                                                       "01711500002"]},
                         format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["watch"]["sim_phone"], "01911000008")
        KW.on_watch_connect("8800000077", "3G")
        mine = cl(self.mom).get(V + "/kids-watch/watches").data["watches"]
        self.assertEqual(mine[0]["sim_phone"], "01911000008")      # guardian can call
        self.assertNotIn("code", mine[0])                           # but never manages
        r = cl(self.mom).patch(V + "/kids-watch/watches/%d" % w.id,
                               {"sim_phone": "01911000009"}, format="json")
        self.assertEqual(r.status_code, 403)
        w.refresh_from_db()
        KW.ingest({w.id: {"fixes": [], "alarms": [["sos", HOME[0], HOME[1]]]}})
        sos = self.spy.to(self.owner, "sos")            # owner: the direct path
        self.assertTrue(sos)
        self.assertEqual(sos[0]["data"].get("watch_phone"), "01911000008")
        fa = FamilyAlert.objects.filter(user=self.owner, kind="sos").last()
        self.assertEqual(fa.payload.get("watch_phone"), "01911000008")

    # ---- 4 P1: active SOS on the card for an hour
    def test_sos_at_shown_for_an_hour_then_gone(self):
        _r, w = self.pair()
        KW.on_watch_connect("8800000077", "3G")
        w.refresh_from_db()
        self.assertIsNone(self.c.get(V + "/kids-watch/watches").data["watches"][0]["sos_at"])
        KW.ingest({w.id: {"fixes": [], "alarms": [["sos", HOME[0], HOME[1]]]}})
        row = self.c.get(V + "/kids-watch/watches").data["watches"][0]
        self.assertTrue(row["sos_at"])
        w.refresh_from_db()
        later = KW.timezone.now() + timedelta(seconds=KW.SOS_ACTIVE_S + 5)
        self.assertIsNone(KW.sos_active_at(w, later))
        # a second press in the same minute still refreshes the time
        KW.ingest({w.id: {"fixes": [], "alarms": [["sos", HOME[0], HOME[1]]]}})
        w.refresh_from_db()
        self.assertIn("sos_direct", w.alert_state)

    # ---- 5 P1: link the child's own account later
    def test_link_child_account_after_pairing_circle_peers_only(self):
        _r, w = self.pair()
        r = self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                         {"child_user_id": self.x.id}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (400, "child_not_in_circle"))
        r = self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                         {"child_user_id": self.child.id}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertEqual(r.data["watch"]["child_user_id"], self.child.id)
        r = self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                         {"child_user_id": None}, format="json")
        self.assertIsNone(r.data["watch"]["child_user_id"])

    # ---- 6 P1: a silent watch is told once, daytime only
    def test_quiet_watch_told_once_in_daytime(self):
        _r, w = self.pair()
        KW.on_watch_connect("8800000077", "3G")
        day = datetime(2026, 11, 17, 11, 0, tzinfo=DHAKA)
        KidsWatch.objects.filter(pk=w.pk).update(last_seen_at=day - timedelta(minutes=80))
        self.assertEqual(KW.quiet_check(day), 0)                   # not yet 90 min
        KidsWatch.objects.filter(pk=w.pk).update(last_seen_at=day - timedelta(minutes=100))
        self.assertEqual(KW.quiet_check(day), 1)
        self.assertEqual(KW.quiet_check(day + timedelta(minutes=5)), 0)   # once
        got = [c for c in self.spy.to(self.mom) if c["data"].get("event") == "watch_quiet"]
        self.assertEqual(len(got), 1)
        self.assertIn("Rina", got[0]["ten"])
        self.assertIn("১:৪০", got[0]["bbn"])               # 100 min, Bangla digits
        self.assertIn("1:40", got[0]["ben"])
        # night: silent, even for a new silence
        night = datetime(2026, 11, 17, 23, 30, tzinfo=DHAKA)
        KidsWatch.objects.filter(pk=w.pk).update(last_seen_at=night - timedelta(hours=3))
        self.assertEqual(KW.quiet_check(night), 0)
        # ... told in the morning
        self.assertEqual(KW.quiet_check(night + timedelta(hours=8)), 1)

    def test_tick_runs_quiet_check(self):
        with mock.patch.object(KW, "quiet_check", return_value=0) as q:
            out = KW.tick()
        q.assert_called_once()
        self.assertEqual(out["quiet_told"], 0)

    # ---- 7 honest: still no listening anywhere
    def test_nothing_new_builds_a_listen_command(self):
        _r, w = self.pair(sim_phone="01911000008")
        KW.on_watch_connect("8800000077", "3G")
        self.c.patch(V + "/kids-watch/watches/%d" % w.id,
                     {"sos_numbers": ["01711500001"], "child_user_id": self.child.id},
                     format="json")
        KW.ingest({w.id: {"fixes": [], "alarms": [["sos", HOME[0], HOME[1]]]}})
        for cmd in KidsWatchCommand.objects.filter(watch=w):
            content, typ = WP.command_content(cmd.kind, cmd.payload)
            self.assertNotIn(typ, WP.FORBIDDEN)
            self.assertNotIn(b"MONITOR", content.upper())
