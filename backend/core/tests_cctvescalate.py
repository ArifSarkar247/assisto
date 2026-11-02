"""cctvescalate — CCTV escalation plus (owner CCTV order 3 Nov, C3-C6).
Pure rules (alarm call ids / bounded ring order, 999 card facts + "never
automatic", capability table incl. honest "not on this camera", WAV check,
vendor calls built from the official docs) and the API on the real views:
chain of notices -> alarm CALL rings (same call push as My Circle) -> stops
when opened (+ call_cancel), never more than the bounded rounds; 999 card in
the alert actions; light (Imou whiteLight, off task), voice (EZVIZ upload
once + send), confirm-before-sound, cooldown, the owner's warning clip.
Vendor HTTP is mocked from the official request / answer shapes."""
import base64
import json
import struct
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase, override_settings
from django.utils import timezone

from core.logic import cctv_deter as CD
from core.logic import cctv_extras as CX
from core.logic import cash_guard as CG
from core.tests_cashguard import _MEDIA
from core.tests_cctvx import _X


def _wav(seconds=2.0, rate=16000):
    n = int(seconds * rate)
    data = b"\x00\x00" * n
    fmt = struct.pack("<HHIIHH", 1, 1, rate, rate * 2, 2, 16)
    body = b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt + b"data" + \
        struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


# ============================================================ pure
class PureTests(SimpleTestCase):
    def test_alarm_call_ids_never_collide_with_call_records(self):
        cid = CD.alarm_call_id(12, 7, 0)
        self.assertEqual(cid, "cctv-12-7-0")
        self.assertTrue(CD.is_alarm_call_id(cid))
        self.assertFalse(CD.is_alarm_call_id("123"))
        self.assertFalse(CD.is_alarm_call_id("cctv-1-x-0"))

    def test_ring_order_is_bounded(self):
        self.assertEqual(CD.call_order([5, 6]), [5, 6, 5, 6])
        self.assertEqual(len(CD.call_order([1, 2, 3], rounds=50)), CD.MAX_RINGS)
        self.assertEqual(CD.call_order([]), [])

    def test_settings_call_and_address(self):
        s = CX.settings_of({})
        self.assertTrue(s["escalate_call"])
        self.assertEqual(s["address"], "")
        g = CX.apply_settings({"_warn": {"name": "x"}, "_state": {}},
                              {"address": "  ১২ রোড,\n মিরপুর  " + "x" * 400,
                               "escalate_call": "false"}, set())
        self.assertFalse(g["escalate_call"])
        self.assertTrue(g["address"].startswith("১২ রোড, মিরপুর"))
        self.assertEqual(len(g["address"]), 200)
        self.assertEqual(g["_warn"], {"name": "x"})        # kept across a PUT

    def test_police_card_facts_only_never_automatic(self):
        f = {"site": "রহিম স্টোর", "address": "১২ রোড, মিরপুর", "when": "03/11/2026 02:10",
             "camera": "দরজা", "kind": "মানুষ", "event_id": 41, "has_photo": True}
        bn = CD.police_card("bn", f)
        self.assertIn("ঠিকানা: ১২ রোড, মিরপুর", bn)
        self.assertIn("০৩/১১/২০২৬ ০২:১০", bn)
        self.assertIn("৪১", bn)
        self.assertIn("ছবি সংযুক্ত", bn)
        en = CD.police_card("en", dict(f, address=""))
        self.assertIn("[write the address]", en)
        for t in (bn, en):
            self.assertFalse(CG.accuses(t))
        self.assertIn("does not call the police", CD.NO_AUTO_POLICE[1])
        self.assertIn("নিজে পুলিশকে কল করে না", CD.NO_AUTO_POLICE[0])

    def test_capability_table_is_honest(self):
        imou = {r["feature"]: r for r in CD.capability_table("imou", "D:0", "", False, {})}
        self.assertEqual((imou["siren"]["route"], imou["light"]["route"]),
                         ("imou_cloud", "imou_cloud"))
        self.assertFalse(imou["voice"]["supported"])
        self.assertIn("এই ক্যামেরায় নেই", imou["voice"]["text"])
        self.assertFalse(imou["talk"]["supported"])
        no_light = CD.capability("imou", "D:0", "", False, {"abilities": ["Siren"]}, "light")
        self.assertEqual(no_light, (None, "no"))
        learned = CD.capability("imou", "D:0", "", False,
                                CD.learn_no({}, "light"), "light")
        self.assertEqual(learned, (None, "learned_no"))
        ez = {r["feature"]: r for r in CD.capability_table("ezviz", "ezviz:SER", "", False, {})}
        self.assertEqual(ez["voice"]["route"], "ezviz_cloud")
        self.assertFalse(ez["siren"]["supported"])
        self.assertFalse(ez["light"]["supported"])
        self.assertEqual(CD.capability("ezviz", "ezviz:SER", "", False,
                                       {"support_talk": "0"}, "voice"),
                         (None, "voice_no_speaker"))
        self.assertEqual(CD.capability("phone", "", "", False, {}, "talk"),
                         (None, "talk_phone"))
        en = CD.capability_table("rtsp", "", "", False, {}, "en")
        self.assertTrue(all(r["text"] for r in en))

    def test_wav_check(self):
        self.assertAlmostEqual(CD.wav_seconds(_wav(2.0)), 2.0, places=1)
        self.assertIsNone(CD.wav_seconds(b"ID3" + b"\x00" * 100))
        self.assertIsNone(CD.wav_seconds(b""))

    def test_ezviz_ref(self):
        self.assertEqual(CD.ezviz_ref("ezviz:ABC123"), ("ABC123", 1))
        self.assertEqual(CD.ezviz_ref("ezviz:ABC123:2"), ("ABC123", 2))


# ============================================================ vendor fakes
def _imou_http(calls, fail=None):
    def http(url, body, timeout):
        method = url.rsplit("/", 1)[1]
        calls.append((method, json.loads(body)["params"]))
        if method == "accessToken":
            return 200, json.dumps({"result": {"code": "0", "data": {
                "accessToken": "T", "expireTime": 3600}}})
        if fail and method in fail:
            return 200, json.dumps({"result": {"code": fail[method], "msg": "x"}})
        return 200, json.dumps({"result": {"code": "0", "data": {}}})
    return http


def _ezviz_http(calls, send_code="200"):
    def http(url, form, timeout):
        path = url.split(".com", 1)[-1]
        calls.append((path, dict(form)))
        if path.endswith("/token/get"):
            return 200, json.dumps({"code": "200", "data": {
                "accessToken": "AT", "areaDomain": "https://open.ezvizlife.com",
                "expireTime": 9999999999999}})
        if path.endswith("/voice/send"):
            return 200, json.dumps({"code": send_code, "msg": "m"})
        if path.endswith("/device/capacity"):
            return 200, json.dumps({"code": "200", "data": {"support_talk": "1"}})
        return 200, json.dumps({"code": "200", "data": {}})
    return http


class ImouVendorTests(SimpleTestCase):
    def test_siren_falls_back_to_the_older_call(self):
        from core.logic import imou as IM
        IM._token_cache.clear()
        calls = []
        c = IM.ImouClient("A", "S", http=_imou_http(calls, fail={"sirenStart": "OP1009"}))
        CD.imou_siren(c, "DEV", "0", on=True)
        names = [m for m, _ in calls if m != "accessToken"]
        self.assertEqual(names, ["sirenStart", "setDeviceCameraStatus"])
        self.assertEqual(calls[-1][1]["enableType"], "siren")

    def test_offline_does_not_fall_back(self):
        from core.logic import imou as IM
        IM._token_cache.clear()
        calls = []
        c = IM.ImouClient("A", "S", http=_imou_http(calls, fail={"sirenStart": "DV1007"}))
        with self.assertRaises(IM.ImouError):
            CD.imou_siren(c, "DEV", "0", on=True)
        self.assertNotIn("setDeviceCameraStatus", [m for m, _ in calls])

    def test_white_light(self):
        from core.logic import imou as IM
        IM._token_cache.clear()
        calls = []
        c = IM.ImouClient("A", "S", http=_imou_http(calls))
        CD.imou_light(c, "DEV", "1", on=True)
        p = calls[-1][1]
        self.assertEqual((calls[-1][0], p["enableType"], p["enable"], p["channelId"]),
                         ("setDeviceCameraStatus", "whiteLight", True, "1"))


# ============================================================ API
@override_settings(MEDIA_ROOT=_MEDIA)
class AlarmCallTests(_X):
    def _calls(self):
        return [(a[0].pk, k["data"]) for a, k in self.pushes if a[1] == "call"]

    def test_chain_then_alarm_calls_then_stop_when_opened(self):
        from core.models import ShopGuardTask
        self.guard(escalation=[self.mgr.id], address="১২ রোড, মিরপুর")
        ev_id = self.ingest().data["event_id"]
        self.tick(minutes=3)                         # notice to the manager
        self.assertEqual(self._calls(), [])
        self.tick(minutes=6)                         # + escalate_min -> CALL
        calls = self._calls()
        self.assertEqual(len(calls), 1)
        uid, data = calls[0]
        self.assertEqual(uid, self.mgr.pk)
        self.assertEqual(data["cctv_event_id"], ev_id)
        self.assertTrue(CD.is_alarm_call_id(data["call_id"]))
        self.assertIn("snapshot_url", data)
        self.assertEqual(data["caller_photo"], data["snapshot_url"])
        self.assertFalse(data["video"])
        self.assertEqual(data["route"], "watchman/inbox")
        self.assertFalse(ShopGuardTask.objects.get(kind="escalate").done)
        # the manager opens it -> the ring is cancelled, no more calls
        self.m.post("/api/v1/shop/events/%d/opened" % ev_id, {}, format="json")
        cancels = [k["data"] for a, k in self.pushes if a[1] == "call_cancel"]
        self.assertEqual(cancels[0]["call_id"], data["call_id"])
        self.tick(minutes=20)
        self.assertEqual(len(self._calls()), 1)

    def test_never_loops_forever(self):
        self.guard(escalation=[self.mgr.id])
        with mock.patch("core.cctvx_views.take_cap", return_value=True):
            self.ingest()
            for m in range(3, 80, 3):
                self.tick(minutes=m)
        self.assertEqual(len(self._calls()), CD.CALL_ROUNDS)    # 1 person x rounds

    def test_call_off_setting_and_blocked_person(self):
        from core.models import CircleMember
        self.guard(escalation=[self.mgr.id], escalate_call=False)
        self.ingest()
        for m in (3, 6, 9):
            self.tick(minutes=m)
        self.assertEqual(self._calls(), [])
        # on again, but the manager blocked the owner -> never rung
        from core.models import ShopEvent
        ShopEvent.objects.update(status="checked")
        self.guard(escalate_call=True)
        CircleMember.objects.create(user=self.mgr, peer_user=self.owner, state="accepted",
                                    name="Owner", relation="friend", blocked=True)
        with mock.patch("core.cctvx_views.take_cap", return_value=True):
            self.ingest()
            for m in (3, 6, 9, 12):
                self.tick(minutes=m)
        self.assertEqual(self._calls(), [])
        self.assertTrue(any(a[0].pk == self.mgr.pk and a[1] == "shop_alert"
                            for a, k in self.pushes))      # the notice still went

    def test_police_card_in_the_actions(self):
        self.guard(address="১২ রোড, মিরপুর")
        ev_id = self.ingest().data["event_id"]
        d = self.client.get("/api/v1/shop/events/%d" % ev_id).data["actions"]
        p = d["police"]
        self.assertEqual((p["number"], p["auto"], p["address_missing"]), ("999", False, False))
        self.assertIn("১২ রোড, মিরপুর", p["card_bn"])
        self.assertIn("does not call the police", p["note_en"])
        self.assertEqual(d["emergency"], "999")


@override_settings(MEDIA_ROOT=_MEDIA)
class DeterTests(_X):
    def _cam(self, vendor, ref):
        from core.models import ShopCamera
        r = self.client.post("/api/v1/shop/sites/%d/cameras" % self.site["id"],
                             {"name": "Door", "kind": "shopbox", "vendor": vendor},
                             format="json")
        ShopCamera.objects.filter(pk=r.data["id"]).update(vendor_ref=ref)
        return ShopCamera.objects.get(pk=r.data["id"])

    def _deter(self, ev, cam, feature, confirm=True, client=None):
        return (client or self.client).post(
            "/api/v1/shop/events/%d/deter" % ev,
            {"feature": feature, "camera_id": cam.id, "confirm": confirm, "seconds": 15},
            format="json")

    def test_imou_light_needs_confirm_then_on_and_off(self):
        from core.logic import imou as IM
        cam = self._cam("imou", "6E0ABC:0")
        ev = self.ingest().data["event_id"]
        IM._token_cache.clear()
        calls = []
        client = IM.ImouClient("APP", "SEC", http=_imou_http(calls))
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.logic.imou.ImouClient.from_integration", return_value=client):
            self.assertEqual(self._deter(ev, cam, "light", confirm=False).status_code, 428)
            r = self._deter(ev, cam, "light")
            self.assertEqual(r.status_code, 200, r.data)
            self.assertEqual((r.data["route"], r.data["seconds"]), ("imou_cloud", 15))
            on = [p for m, p in calls if m == "setDeviceCameraStatus"]
            self.assertEqual((on[0]["enableType"], on[0]["enable"]), ("whiteLight", True))
            self.assertEqual(self._deter(ev, cam, "light").status_code, 429)   # cooldown
            self.tick(seconds=20)
            off = [p for m, p in calls if m == "setDeviceCameraStatus"]
            self.assertEqual((off[-1]["enableType"], off[-1]["enable"]), ("whiteLight", False))

    def test_imou_light_unsupported_is_learned(self):
        from core.logic import imou as IM
        cam = self._cam("imou", "6E0ABC:0")
        ev = self.ingest().data["event_id"]
        IM._token_cache.clear()
        client = IM.ImouClient("APP", "SEC", http=_imou_http(
            [], fail={"setDeviceCameraStatus": "DV1036"}))
        with mock.patch("core.watchman_views.imou_cloud_on", return_value=True), \
                mock.patch("core.logic.imou.ImouClient.from_integration", return_value=client):
            r = self._deter(ev, cam, "light")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "learned_no"))
        t = self.client.get("/api/v1/shop/cameras/%d/deter" % cam.id).data["table"]
        light = [x for x in t if x["feature"] == "light"][0]
        self.assertFalse(light["supported"])
        self.assertIn("not on this camera", light["text"])      # owner reads English

    def test_voice_needs_a_recorded_clip_then_ezviz_upload_once_and_send(self):
        from core.logic import ezviz as EZ
        cam = self._cam("ezviz", "ezviz:SER9:1")
        ev = self.ingest().data["event_id"]
        bad = self.client.put("/api/v1/shop/sites/%d/warn-clip" % self.site["id"],
                              {"wav_b64": base64.b64encode(b"not a wav").decode()},
                              format="json")
        self.assertEqual(bad.status_code, 422)
        EZ._token_cache.clear()
        calls, ups = [], []
        client = EZ.EzvizClient("K", "S", http=_ezviz_http(calls))

        def multipart(url, fields, files, timeout):
            ups.append((url, fields, files))
            return 200, json.dumps({"code": "200", "data": {"url": "https://x.ezvizlife.com/v.wav"}})
        with mock.patch("core.logic.ezviz.EzvizClient.from_integration", return_value=client), \
                mock.patch("core.logic.cctv_deter._default_multipart", side_effect=multipart):
            r = self._deter(ev, cam, "voice")
            self.assertEqual((r.status_code, r.data["error"]), (409, "no_clip"))
            ok = self.client.put("/api/v1/shop/sites/%d/warn-clip" % self.site["id"],
                                 {"wav_b64": base64.b64encode(_wav(3)).decode()},
                                 format="json")
            self.assertEqual(ok.status_code, 200, ok.data)
            self.assertTrue(ok.data["has_clip"])
            r = self._deter(ev, cam, "voice")
            self.assertEqual((r.status_code, r.data["status"]), (200, "playing"))
            send = [f for p, f in calls if p.endswith("/voice/send")][0]
            self.assertEqual((send["deviceSerial"], send["channelNo"], send["fileUrl"]),
                             ("SER9", 1, "https://x.ezvizlife.com/v.wav"))
            self.assertEqual(ups[0][1]["accessToken"], "AT")
            # second time: no new upload (cached url)
            from core.models import ShopCamera
            ShopCamera.objects.filter(pk=cam.id).update(compat={})
            self._deter(ev, cam, "voice")
            self.assertEqual(len(ups), 1)

    def test_voice_unsupported_device(self):
        from core.logic import ezviz as EZ
        cam = self._cam("ezviz", "ezviz:SER9")
        ev = self.ingest().data["event_id"]
        self.client.put("/api/v1/shop/sites/%d/warn-clip" % self.site["id"],
                        {"wav_b64": base64.b64encode(_wav(2)).decode()}, format="json")
        EZ._token_cache.clear()
        client = EZ.EzvizClient("K", "S", http=_ezviz_http([], send_code="20015"))
        with mock.patch("core.logic.ezviz.EzvizClient.from_integration", return_value=client), \
                mock.patch("core.logic.cctv_deter._default_multipart",
                           return_value=(200, json.dumps({"code": "200", "data": {"url": "u"}}))):
            r = self._deter(ev, cam, "voice")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "voice_no_speaker"))

    def test_only_owner_or_escalated_and_actions_table(self):
        cam = self._cam("imou", "6E0ABC:0")
        ev = self.ingest().data["event_id"]
        r = self._deter(ev, cam, "light", client=self.m)
        self.assertEqual(r.status_code, 404)              # manager not escalated
        a = self.client.get("/api/v1/shop/events/%d" % ev).data["actions"]
        feats = {x["feature"]: x for x in a["deter"]["table_bn"]}   # the onvif till camera
        self.assertFalse(feats["light"]["supported"])
        self.assertIn("এই ক্যামেরায় নেই", feats["light"]["text"])
        self.assertFalse(feats["talk"]["supported"])
        t = self.client.get("/api/v1/shop/cameras/%d/deter" % cam.id).data["table"]
        self.assertTrue([x for x in t if x["feature"] == "light"][0]["supported"])
        self.assertTrue(a["deter"]["allowed"])
        self.assertFalse(a["deter"]["warn_clip"])

    def test_ezviz_capacity_refresh(self):
        from core.logic import ezviz as EZ
        cam = self._cam("ezviz", "ezviz:SER9")
        EZ._token_cache.clear()
        client = EZ.EzvizClient("K", "S", http=_ezviz_http([]))
        with mock.patch("core.logic.ezviz.EzvizClient.from_integration", return_value=client):
            t = self.client.get("/api/v1/shop/cameras/%d/deter?refresh=1" % cam.id).data
        from core.models import ShopCamera
        self.assertEqual(ShopCamera.objects.get(pk=cam.id).compat["support_talk"], "1")
        voice = [x for x in t["table"] if x["feature"] == "voice"][0]
        self.assertTrue(voice["supported"])
