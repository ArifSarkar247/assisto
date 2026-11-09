"""fcsos — Family Care v3 SOS sender (SCREEN 2) + receiver (SCREEN 3).

SOS reaches 3 family accounts (My Circle UNION Family Care v3 families, one
swap point); cancel after sending tells everyone it was a mistake; the
receiver's alarm page has who / when / live location / 30 s audio / who is
going / nearest police + hospital (own Nearby list) / emergency info only when
the sender shares it; strangers get 404; the 10-second target is measured
(server path, push seam timestamps) and printed as FCSOS_LATENCY."""
import base64
import shutil
import sys
import tempfile
import time
import types
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import family_alerts as FA
from core import family_sos_v3 as SV
from core.models import (CircleMember, EmergencyCard, FamilyAlertDelivery,
                         NearbyPlace, User)

V = "/api/v1"


def mk(phone, name, lang="en"):
    return User.objects.create_user(name=name, phone=phone, password="pw12345!",
                                    language=lang)


def cl(u):
    c = APIClient()
    c.force_authenticate(u)
    c.credentials(HTTP_ACCEPT_LANGUAGE="en")
    return c


def pair(a, b):
    CircleMember.objects.create(user=a, peer_user=b, name=b.name, state="accepted",
                                phone=b.phone)
    CircleMember.objects.create(user=b, peer_user=a, name=a.name, state="accepted",
                                direction="incoming", phone=a.phone)


class Spy:
    def __init__(self):
        self.calls = []

    def safe_push(self, user, kind, tbn, ten, bbn="", ben="", data=None, **kw):
        self.calls.append({"user": user.pk, "kind": kind, "tbn": tbn, "ten": ten,
                           "ben": ben, "data": dict(data or {}), "t": time.monotonic(),
                           "high": kw.get("high_priority", False)})
        return True

    def to(self, u):
        return [c for c in self.calls if c["user"] == u.pk]


def fake_family_v3(members_by_user, family_members=None):
    """A stand-in for fcscreen's core.family_v3 (merged separately)."""
    m = types.ModuleType("core.family_v3")
    m.members_of = lambda u: [dict(user_id=x.pk, name=x.name) for x in
                              members_by_user.get(u.pk, [])]
    m.member_ids = lambda fid: [x.pk for x in (family_members or {}).get(fid, [])]
    return m


class Base(TestCase):
    def setUp(self):
        cache.clear()
        self.media = tempfile.mkdtemp()
        o = override_settings(MEDIA_ROOT=self.media)
        o.enable()
        self.addCleanup(o.disable)
        self.addCleanup(shutil.rmtree, self.media, True)
        self.rina = mk("01711200001", "Rina")              # sender
        self.ammu = mk("01711200002", "Ammu", lang="bn")   # circle
        self.bhai = mk("01711200003", "Bhai")              # circle
        self.abbu = mk("01711200004", "Abbu", lang="bn")   # family v3 ONLY
        self.x = mk("01711200005", "Stranger")
        pair(self.rina, self.ammu)
        pair(self.rina, self.bhai)
        self.spy = Spy()
        p = mock.patch("core.push.safe_push", side_effect=self.spy.safe_push)
        p.start()
        self.addCleanup(p.stop)
        fam = fake_family_v3({self.rina.pk: [self.abbu, self.ammu]},
                             {7: [self.rina, self.ammu, self.abbu]})
        p2 = mock.patch.dict(sys.modules, {"core.family_v3": fam})
        p2.start()
        self.addCleanup(p2.stop)
        import core
        core.family_v3 = fam
        self.addCleanup(lambda: delattr(core, "family_v3") if hasattr(core, "family_v3") else None)

    def sos(self, **kw):
        body = {"lat": 23.7501, "lng": 90.3901, "source": "family_v3",
                "client_id": "c%d" % time.monotonic_ns()}
        body.update(kw)
        return cl(self.rina).post(V + "/family/sos", body, format="json")

    def did(self, u):
        return FamilyAlertDelivery.objects.get(recipient=u, kind="sos").id


class SosToThreeTests(Base):
    def test_sos_reaches_circle_and_family_v3_once_each(self):
        r = self.sos()
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["recipients"], 3)
        for u in (self.ammu, self.bhai, self.abbu):
            calls = [c for c in self.spy.to(u) if c["kind"] == "sos"]
            self.assertEqual(len(calls), 1, u.name)
            self.assertTrue(calls[0]["high"])
            self.assertEqual(calls[0]["data"]["lat"], 23.7501)
        self.assertEqual(self.spy.to(self.x), [])
        self.assertEqual(self.spy.to(self.rina), [])

    def test_without_family_v3_circle_still_gets_it(self):
        sys.modules.pop("core.family_v3", None)
        import core
        if hasattr(core, "family_v3"):
            delattr(core, "family_v3")
        with mock.patch.dict(sys.modules, {"core.family_v3": None}):
            r = self.sos()
        self.assertEqual(r.data["recipients"], 2)

    def test_sos_latency_under_10_seconds(self):
        """The 10-second target, server side: request in -> every family
        phone's push handed to FCM (push seam timestamps). Printed for CI."""
        t0 = time.monotonic()
        r = self.sos()
        self.assertEqual(r.data["sent"], 3)
        worst = max(c["t"] for c in self.spy.calls if c["kind"] == "sos") - t0
        print("FCSOS_LATENCY server_to_fcm_ms=%d recipients=3" % (worst * 1000))
        self.assertLess(worst, 10.0)
        # the phone's receipt closes the loop (quality bar: received - created)
        for u in (self.ammu, self.bhai, self.abbu):
            cl(u).post(V + "/family/alerts/received", {"ids": [self.did(u)]}, format="json")
        for d in FamilyAlertDelivery.objects.filter(kind="sos"):
            self.assertIsNotNone(d.received_at)
            self.assertLess((d.received_at - d.created_at).total_seconds(), 10)


class MistakeTests(Base):
    def test_cancel_after_send_tells_everyone_it_was_a_mistake(self):
        self.sos()
        r = cl(self.rina).post(V + "/family/sos/resolve", {"reason": "mistake"}, format="json")
        self.assertEqual(r.data["recipients"], 3)
        for u in (self.ammu, self.bhai, self.abbu):
            m = [c for c in self.spy.to(u) if c["data"].get("event") == "sos_mistake"]
            self.assertEqual(len(m), 1, u.name)
            self.assertIn("by mistake", m[0]["ten"])
            self.assertIn("ভুল করে", m[0]["tbn"])
            self.assertEqual(m[0]["data"]["reason"], "mistake")
        ev = cl(self.ammu).get(V + "/family/sos/event/%d" % self.did(self.ammu)).data
        self.assertEqual(ev["state"], "mistake")

    def test_plain_safe_is_not_called_a_mistake(self):
        self.sos()
        cl(self.rina).post(V + "/family/sos/resolve", {}, format="json")
        ev = cl(self.bhai).get(V + "/family/sos/event/%d" % self.did(self.bhai)).data
        self.assertEqual(ev["state"], "safe")
        self.assertFalse(any(c["data"].get("event") == "sos_mistake" for c in self.spy.calls))


class ReceiverTests(Base):
    def test_event_detail_who_when_where(self):
        self.sos()
        r = cl(self.ammu).get(V + "/family/sos/event/%d" % self.did(self.ammu))
        self.assertEqual(r.status_code, 200)
        d = r.data
        self.assertEqual(d["state"], "active")
        self.assertEqual(d["sender"]["id"], self.rina.pk)
        self.assertEqual(d["sender"]["phone"], self.rina.phone)
        self.assertEqual(d["location"]["lat"], 23.7501)
        self.assertIsNone(d["info"])          # not shared by default
        self.assertEqual(d["going"], [])
        self.assertFalse(d["me_going"])

    def test_stranger_and_sender_cannot_open_someone_elses_row(self):
        self.sos()
        did = self.did(self.ammu)
        self.assertEqual(cl(self.x).get(V + "/family/sos/event/%d" % did).status_code, 404)
        self.assertEqual(cl(self.bhai).get(V + "/family/sos/event/%d" % did).status_code, 404)

    def test_i_am_going_shows_in_everyones_list(self):
        self.sos()
        cl(self.bhai).post(V + "/family/alerts/%d/responding" % self.did(self.bhai))
        d = cl(self.ammu).get(V + "/family/sos/event/%d" % self.did(self.ammu)).data
        self.assertEqual([g["me"] for g in d["going"]], [False])
        d2 = cl(self.bhai).get(V + "/family/sos/event/%d" % self.did(self.bhai)).data
        self.assertTrue(d2["me_going"])
        st = cl(self.rina).get(V + "/family/sos/status").data
        self.assertEqual(st["state"], "active")
        self.assertEqual(len(st["going"]), 1)

    def test_emergency_info_only_when_shared(self):
        EmergencyCard.objects.create(user=self.rina, blood_group="B+",
                                     contacts=[{"name": "Dr", "phone": "01711999999"}])
        self.sos()
        did = self.did(self.ammu)
        self.assertIsNone(cl(self.ammu).get(V + "/family/sos/event/%d" % did).data["info"])
        r = cl(self.rina).post(V + "/family/sos/settings", {"share_info": True}, format="json")
        self.assertTrue(r.data["share_info"])
        info = cl(self.ammu).get(V + "/family/sos/event/%d" % did).data["info"]
        self.assertEqual(info["blood_group"], "B+")
        self.assertEqual(info["contacts"][0]["phone"], "01711999999")

    def test_nearest_police_and_hospital_from_own_list(self):
        for cat, name, dlat in (("police", "Dhanmondi Thana", 0.01),
                                ("police", "Far Thana", 0.30),
                                ("hospital", "Square Hospital", 0.005),
                                ("pharmacy", "Not this", 0.001)):
            NearbyPlace.objects.create(country="BD", category=cat, name=name,
                                       name_en=name, lat=23.7501 + dlat, lon=90.3901,
                                       phone="0255000000")
        self.sos()
        d = cl(self.ammu).get(V + "/family/sos/event/%d" % self.did(self.ammu)).data
        self.assertEqual(d["nearby"]["police"][0]["name"], "Dhanmondi Thana")
        self.assertEqual(d["nearby"]["hospital"][0]["name"], "Square Hospital")
        self.assertLess(d["nearby"]["hospital"][0]["distance_m"], 1000)
        self.assertEqual(d["country"], "BD")
        self.assertIn("OpenStreetMap", d["nearby"]["attribution"])


class LiveLocationTests(Base):
    def test_live_location_updates_and_is_throttled(self):
        self.sos(lat=None, lng=None)
        did = self.did(self.ammu)
        self.assertIsNone(cl(self.ammu).get(V + "/family/sos/event/%d" % did).data["location"])
        r = cl(self.rina).post(V + "/family/sos/location", {"lat": 23.8, "lng": 90.4}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["updated"], 3)
        loc = cl(self.ammu).get(V + "/family/sos/event/%d" % did).data["location"]
        self.assertEqual((loc["lat"], loc["live"]), (23.8, True))
        r2 = cl(self.rina).post(V + "/family/sos/location", {"lat": 23.9, "lng": 90.4}, format="json")
        self.assertTrue(r2.data.get("throttled"))

    def test_no_active_sos_no_location(self):
        r = cl(self.rina).post(V + "/family/sos/location", {"lat": 23.8, "lng": 90.4}, format="json")
        self.assertEqual(r.status_code, 409)
        self.sos()
        cl(self.rina).post(V + "/family/sos/resolve", {}, format="json")
        r = cl(self.rina).post(V + "/family/sos/location", {"lat": 23.8, "lng": 90.4}, format="json")
        self.assertEqual(r.status_code, 409)


class AudioTests(Base):
    AUDIO = base64.b64encode(b"\x00\x00\x00\x18ftypM4A " + b"x" * 2000).decode()

    def test_audio_upload_and_play_by_family_only(self):
        self.sos()
        r = cl(self.rina).post(V + "/family/sos/audio", {"audio_b64": self.AUDIO, "sec": 30},
                               format="json")
        self.assertEqual(r.status_code, 200)
        did = self.did(self.ammu)
        self.assertEqual(cl(self.ammu).get(V + "/family/sos/event/%d" % did).data["audio_sec"], 30)
        a = cl(self.ammu).get(V + "/family/sos/event/%d/audio" % did)
        self.assertEqual(a.status_code, 200)
        self.assertEqual(a["Content-Type"], "audio/mp4")
        self.assertEqual(cl(self.x).get(V + "/family/sos/event/%d/audio" % did).status_code, 404)

    def test_audio_rules(self):
        r = cl(self.rina).post(V + "/family/sos/audio", {"audio_b64": self.AUDIO, "sec": 5},
                               format="json")
        self.assertEqual(r.status_code, 409)          # no SOS -> never recorded
        self.sos()
        r = cl(self.rina).post(V + "/family/sos/audio", {"audio_b64": self.AUDIO, "sec": 45},
                               format="json")
        self.assertEqual(r.status_code, 400)          # > 30 s
        r = cl(self.rina).post(V + "/family/sos/audio", {"audio_b64": "%%%", "sec": 5},
                               format="json")
        self.assertEqual(r.status_code, 400)

    def test_old_recordings_are_purged(self):
        self.sos()
        cl(self.rina).post(V + "/family/sos/audio", {"audio_b64": self.AUDIO, "sec": 3},
                           format="json")
        self.assertEqual(SV.purge_audio(timezone.now()), 0)
        self.assertEqual(SV.purge_audio(timezone.now() + timedelta(days=8)), 1)


class FamilyBoardHookTests(Base):
    def test_active_sos_user_ids_for_family_screen(self):
        self.assertEqual(SV.active_sos_user_ids(7), set())
        self.sos()
        self.assertEqual(SV.active_sos_user_ids(7), {self.rina.pk})
        cl(self.rina).post(V + "/family/sos/resolve", {"reason": "mistake"}, format="json")
        self.assertEqual(SV.active_sos_user_ids(7), set())
        self.assertEqual(SV.active_sos_user_ids(99), set())

    def test_sos_free_never_debits(self):
        with mock.patch("core.billing.charge", side_effect=AssertionError("charged")) as m, \
                mock.patch("core.credits.spend", side_effect=AssertionError("spent")) as s:
            self.sos()
            did = self.did(self.ammu)
            cl(self.ammu).get(V + "/family/sos/event/%d" % did)
            cl(self.rina).post(V + "/family/sos/location", {"lat": 23.8, "lng": 90.4}, format="json")
            cl(self.rina).post(V + "/family/sos/resolve", {"reason": "mistake"}, format="json")
        m.assert_not_called()
        s.assert_not_called()

    def test_rering_reaches_family_v3_member(self):
        self.sos()
        d = FamilyAlertDelivery.objects.get(recipient=self.abbu, kind="sos")
        self.assertTrue(FA._still_reachable(d))
