"""cctvconnect — CCTV Guard V3 A1 (brand clouds), A2/A3 hand-off, B (DVR health).

1. Pure DVR-health rules (logic/dvr_health.py).
2. Every brand adapter against its simulated cloud (logic/cctv_connect/mocks.py):
   wrong code, link, device list, live / playback URL, the camera's own AI
   event, cloud health, revoke. EZVIZ, Imou, Hik-Connect, DoLynk.
3. Sealed grants are bound to ONE site.
4. END TO END through the real API (owner logged in): providers list (OFF
   without a key), connect, list devices, import cameras, an AI event arrives
   as an alert + push, stream URLs only for the owner / allowed viewers (never
   staff), cloud health -> camera_health alert, revoke. Then the Guard Box
   path: the REAL camlink probe reads a simulated Hikvision / Dahua DVR over
   HTTP digest and posts to /shop/gateway/dvr-health -> problems + daily card.
Synthetic data only.
"""
import json
import os
import sys
import time
from datetime import timedelta
from unittest import mock

from cryptography.fernet import Fernet
from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import integrations
from core import tests_e2e_cctv as E2E
from core.logic import cctv_connect as CC
from core.logic import dvr_health as DH
from core.logic.cctv_connect import mocks as M

_KEY = Fernet.generate_key().decode()
EDGE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "edge", "shopbox"))


def setUpModule():
    os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
    integrations._FERNET = None


def tearDownModule():
    integrations._FERNET = None


def _clear_caches():
    from django.core.cache import cache
    cache.clear()            # the per-user link-try counter
    from core.logic import ezviz as EZ, imou as IM
    from core.logic.cctv_connect import dolynk as DL, hikconnect as HC
    DL._tokens.clear()
    DL._user_tokens.clear()
    EZ._token_cache.clear()
    IM._token_cache.clear()
    HC._token_cache.clear()


# ====================================================================== 1
class DvrHealthRulesTests(SimpleTestCase):
    NOW = 1_800_000_000.0

    def rep(self, **kw):
        base = {"source": "isapi", "device": "SIMHK1", "at": self.NOW,
                "disks": [{"id": "1", "state": "ok", "total_gb": 1000, "free_gb": 300}],
                "channels": [{"no": i, "online": True, "recording": True} for i in (1, 2)],
                "oldest_record": self.NOW - 10 * 86400, "latest_record": self.NOW - 60}
        base.update(kw)
        return DH.normalize_report(base, self.NOW)

    def kinds(self, rep, **kw):
        return sorted(p["kind"] for p in DH.evaluate(rep, self.NOW, **kw)["problems"])

    def test_healthy_is_green_with_bangla_digits(self):
        ev = DH.evaluate(self.rep(), self.NOW)
        self.assertEqual(ev["problems"], [])
        self.assertEqual(ev["recorded_days"], 10)
        c = DH.card([ev], now=self.NOW, lang="bn")
        self.assertEqual(c["status"], "green")
        self.assertIn("সব ঠিক আছে", c["title"])

    def test_each_problem(self):
        self.assertEqual(self.kinds(self.rep(disks=[{"id": "1", "state": "error"}])), ["hdd_fail"])
        self.assertEqual(self.kinds(self.rep(disks=[{"id": "1", "state": "none"}])), ["hdd_fail"])
        full = [{"id": "1", "state": "ok", "total_gb": 1000, "free_gb": 0}]
        self.assertEqual(self.kinds(self.rep(disks=full, overwrite=True)), [])   # overwrite = normal
        self.assertEqual(self.kinds(self.rep(disks=full, overwrite=False)), ["hdd_full"])
        off = [{"no": 1, "online": False, "recording": False}, {"no": 2, "online": True, "recording": True}]
        self.assertEqual(self.kinds(self.rep(channels=off)), ["cam_offline"])
        self.assertEqual(self.kinds(self.rep(channels=off), ignore_channels=[1]), [])
        norec = [{"no": 1, "online": True, "recording": False}]
        self.assertEqual(self.kinds(self.rep(channels=norec)), ["rec_stopped"])
        self.assertEqual(self.kinds(self.rep(latest_record=self.NOW - 3 * 3600)), ["rec_stopped"])
        self.assertEqual(self.kinds(self.rep(oldest_record=self.NOW - 3 * 86400)), ["few_days"])
        self.assertEqual(self.kinds(self.rep(oldest_record=self.NOW - 3 * 86400), target_days=3), [])

    def test_unknown_is_never_green(self):
        empty = DH.normalize_report({"device": "X"}, self.NOW)
        ev = DH.evaluate(empty, self.NOW)
        self.assertEqual(DH.card([ev], now=self.NOW, lang="en")["status"], "unknown")
        self.assertEqual(DH.card([], now=self.NOW, lang="en")["status"], "unknown")

    def test_card_lines_and_amber(self):
        ev = DH.evaluate(self.rep(oldest_record=self.NOW - 2 * 86400), self.NOW)
        c = DH.card([ev], now=self.NOW, lang="bn")
        self.assertEqual(c["status"], "amber")
        self.assertIn("২", c["lines"][0]["what"])
        ev2 = DH.evaluate(self.rep(disks=[{"id": "1", "state": "error"}]), self.NOW)
        c = DH.card([ev, ev2], [{"kind": "covered", "cam": "Gate"}], now=self.NOW, lang="en")
        self.assertEqual(c["status"], "red")
        self.assertEqual({l["kind"] for l in c["lines"]}, {"few_days", "hdd_fail", "covered"})
        self.assertTrue(any(l["what"].startswith("Gate — ") for l in c["lines"]))
        self.assertTrue(all(l["fix"] for l in c["lines"]))

    def test_normalize_bounds_and_junk(self):
        r = DH.normalize_report({"disks": [{"state": "weird"}] * 40, "channels": [{"no": "x"}],
                                 "at": self.NOW + 9e9, "overwrite": "yes"}, self.NOW)
        self.assertEqual(len(r["disks"]), DH.MAX_DISKS)
        self.assertEqual(r["disks"][0]["state"], "unknown")
        self.assertEqual(r["channels"], [])
        self.assertLessEqual(r["at"], self.NOW + 300)
        self.assertIs(r["overwrite"], True)


# ====================================================================== 2
class AdapterMockTests(SimpleTestCase):
    def setUp(self):
        _clear_caches()
        self.sim = M.VendorSims()
        for v in ("ezviz", "imou", "hikconnect", "dolynk"):
            self.sim.add_device(v, "SIM%sDVR1" % v[:2].upper(), "ABC123", channels=4)
            self.sim.add_device(v, "SIM%sOTHER" % v[:2].upper(), "ZZZ999", channels=1)

    def ad(self, v):
        return CC.adapter(v, http=self.sim.http, cfg=self.sim.cfg(v))

    def run_vendor(self, v):
        a, serial = self.ad(v), "SIM%sDVR1" % v[:2].upper()
        self.assertTrue(a.configured(), v)
        with self.assertRaises(CC.ConnectError) as e:
            a.link_device(serial, "WRONG1")
        self.assertEqual(e.exception.hint, "wrong_code")
        g = a.link_device(serial, "ABC123")
        self.assertEqual(g, {"mode": "device_code", "serials": [serial]})
        devs = a.devices(g)
        self.assertEqual([d["serial"] for d in devs], [serial])
        self.assertEqual(len(devs[0]["channels"]), 4)
        self.assertEqual(devs[0]["kind"], "nvr")
        ch = devs[0]["channels"][1]["no"]
        live = a.live(g, serial, ch)
        self.assertTrue(live["url"].startswith("https://") and live["proto"] == "hls", live)
        self.assertTrue(CC.base.host_allowed(live["url"], a.pic_hosts), live)
        # the camera's own AI event (a person)
        t0 = time.time() - 5
        self.sim.push_alarm(v, serial, int(ch), "human")
        evs = (a.account_events(t0) if a.events_scope == "account"
               else a.events(g, serial, t0, channels=[str(ch)]))
        self.assertEqual(len(evs), 1, evs)
        self.assertEqual((evs[0]["kind"], evs[0]["serial"]), ("person", serial))
        self.assertTrue(evs[0]["picture"].startswith("https://"), evs)
        # disk failure shows in the cloud health report
        self.sim.set_disk(v, serial, "error")
        rep = DH.normalize_report(a.health(g, serial))
        kinds = [p["kind"] for p in DH.evaluate(rep)["problems"]]
        self.assertIn("hdd_fail", kinds)
        # scope: another device of the same developer account is not ours
        self.assertFalse(a.owns(g, "SIM%sOTHER" % v[:2].upper()))
        # revoke releases the device at the vendor
        a.unlink(g)
        self.assertIsNone(self.sim.devs[v][serial].owner)

    def test_ezviz(self):
        self.run_vendor("ezviz")

    def test_imou(self):
        self.run_vendor("imou")

    def test_hikconnect(self):
        self.run_vendor("hikconnect")

    def test_dolynk(self):
        self.run_vendor("dolynk")

    def test_taken_and_offline_and_network(self):
        a = self.ad("ezviz")
        self.sim.devs["ezviz"]["SIMEZDVR1"].owner = "someone-else"
        with self.assertRaises(CC.ConnectError) as e:
            a.link_device("SIMEZDVR1", "ABC123")
        self.assertEqual(e.exception.hint, "taken")
        h = self.ad("hikconnect")
        g = h.link_device("SIMHIDVR1", "ABC123")
        self.sim.devs["hikconnect"]["SIMHIDVR1"].online = False
        with self.assertRaises(CC.ConnectError) as e:
            h.live(g, "SIMHIDVR1", 1)
        self.assertEqual(e.exception.hint, "offline")
        self.sim.fail_network.add("imou")
        with self.assertRaises(CC.ConnectError) as e:
            self.ad("imou").link_device("SIMIMDVR1", "ABC123")
        self.assertEqual(e.exception.hint, "network")

    def test_playback_urls(self):
        for v in ("ezviz", "hikconnect"):
            a, s = self.ad(v), "SIM%sDVR1" % v[:2].upper()
            g = a.link_device(s, "ABC123")
            pb = a.playback(g, s, 1, time.time() - 600, time.time() - 540)
            self.assertIn("pb", pb["url"])
        a = self.ad("imou")
        g = a.link_device("SIMIMDVR1", "ABC123")
        pb = a.playback(g, "SIMIMDVR1", 0, time.time() - 600, time.time() - 540)
        self.assertEqual((pb["url"], pb["proto"]), ("", "sdk_only"))   # honest
        self.assertTrue(pb["records"])

    def test_foreign_hosts_refused(self):
        self.assertFalse(CC.base.host_allowed("http://pic.ezvizlife.com/a.jpg", (".ezvizlife.com",)))
        self.assertFalse(CC.base.host_allowed("https://ezvizlife.com.evil.test/a", (".ezvizlife.com",)))
        self.assertTrue(CC.base.host_allowed("https://a.ezvizlife.com/x", (".ezvizlife.com",)))
        a = CC.adapter("hikconnect", http=self.sim.http,
                       cfg=dict(self.sim.cfg("hikconnect"), api_base="https://evil.test"))
        self.assertEqual(a._base(), "https://ieu.hik-connect.com")

    def test_off_without_keys(self):
        self.assertFalse(CC.adapter("dolynk", cfg={"app_id": "x", "app_secret": "y"}).configured())
        with self.assertRaises(CC.ConnectError):
            CC.adapter("ezviz", cfg={}).client()


# ====================================================================== 3
class SealTests(SimpleTestCase):
    def setUp(self):
        os.environ["INTEGRATIONS_FERNET_KEY"] = _KEY
        integrations._FERNET = None

    def test_bound_to_site(self):
        blob = CC.seal(7, {"mode": "oauth", "access_token": "secret-token"})
        self.assertNotIn("secret-token", blob)
        self.assertEqual(CC.unseal(7, blob)["access_token"], "secret-token")
        self.assertEqual(CC.unseal(8, blob), {})
        self.assertEqual(CC.unseal(7, "garbage"), {})


# ====================================================================== 4
def _enable(slug, cfg):
    from core.models import Integration
    Integration.objects.update_or_create(slug=slug, defaults={
        "enc_blob": integrations._encrypt(cfg), "status": "working",
        # DoLynk switches on only after a SIGNED sign-in passed the Test
        "detail": CC.SIGNED_IN[slug] + " (test)" if slug in CC.SIGNED_IN else ""})


class ConnectApiE2ETests(E2E._Base):
    def setUp(self):
        super().setUp()
        _clear_caches()
        self.sim = M.VendorSims()
        for v in ("ezviz", "imou", "hikconnect", "dolynk"):
            self.sim.add_device(v, "SIM%sDVR1" % v[:2].upper(), "ABC123", channels=4)
        p = mock.patch("core.logic.cctv_connect.base.default_http", self.sim.http)
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch("core.shop_views._included_cameras", return_value=10)
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch("core.cctv_connect_views._fetch_picture",
                       return_value=E2E._jpeg())
        p.start()
        self.addCleanup(p.stop)
        self.sid = self.site["id"]
        # the Assisto owner's own account (developer-account binds = owner test devices)
        self.owner.is_staff = True
        self.owner.save(update_fields=["is_staff"])
        # owner-away mode: every camera armed whatever the clock says (CI runs
        # at any hour; the home schedule may be "not armed" right now)
        from core.models import ShopSite
        ShopSite.objects.filter(pk=self.sid).update(
            away={"until": (timezone.now() + timedelta(days=1)).isoformat()})

    def providers(self):
        r = self.client.get("/api/v1/cctv/connect/providers?site=%d" % self.sid)
        self.assertEqual(r.status_code, 200, r.data)
        return [p["id"] for p in r.data["providers"]]

    def test_off_until_key_and_test_pass(self):
        self.assertEqual(self.providers(), [])
        from core.models import Integration
        Integration.objects.create(slug="hikconnect", status="failing",
                                   enc_blob=integrations._encrypt(self.sim.cfg("hikconnect")))
        self.assertEqual(self.providers(), [])
        r = self.client.post("/api/v1/cctv/connect/hikconnect/link",
                             {"site": self.sid, "serial": "SIMHIDVR1", "code": "ABC123", "consent": True},
                             format="json")
        self.assertEqual((r.status_code, r.data["error"]), (503, "not_configured"))
        ok, detail = integrations.test_hikconnect(self.sim.cfg("hikconnect"), http=self.sim.http)
        self.assertTrue(ok, detail)
        Integration.objects.filter(slug="hikconnect").update(status="working")
        self.assertEqual(self.providers(), ["hikconnect"])

    def connect(self, v):
        serial = "SIM%sDVR1" % v[:2].upper()
        _enable(v, self.sim.cfg(v))
        r = self.client.post("/api/v1/cctv/connect/%s/link" % v,
                             {"site": self.sid, "serial": serial, "code": "WRONG1", "consent": True}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (422, "vendor_wrong_code"))
        r = self.client.post("/api/v1/cctv/connect/%s/link" % v,
                             {"site": self.sid, "serial": serial.lower(), "code": "ABC123", "consent": True},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        link = r.data["link"]
        self.assertEqual(link["serials"], [serial])
        r = self.client.get("/api/v1/cctv/connect/links/%d/devices" % link["id"])
        self.assertEqual(r.status_code, 200, r.data)
        dev = r.data["devices"][0]
        self.assertEqual(len(dev["channels"]), 4)
        ch = dev["channels"][0]["no"]
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link["id"],
                             {"items": [{"serial": serial, "channel": ch, "name": "Gate %s" % v}]},
                             format="json")
        self.assertEqual(r.status_code, 201, r.data)
        cam = r.data["added"][0]
        r = self.client.get("/api/v1/cctv/connect/links/%d/devices" % link["id"])
        self.assertTrue(r.data["devices"][0]["channels"][0]["added"])
        return link, serial, ch, cam

    def run_vendor(self, v):
        from core.models import CctvCloudLink, ShopCamera, ShopEvent
        from core import cctv_connect_views as V
        link, serial, ch, cam = self.connect(v)
        row = CctvCloudLink.objects.get(pk=link["id"])
        self.assertNotIn("ABC123", row.grant_blob + str(row.serials) + str(row.state))
        self.assertEqual(CC.unseal(self.sid, row.grant_blob)["serials"], [serial])
        # live + playback URL for the OWNER (the cctvplay hook)
        r = self.client.post("/api/v1/cctv/connect/cameras/%d/stream" % cam["id"],
                             {"kind": "live"}, format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["url"].startswith("https://"), r.data)
        # the camera's own AI event -> alert (Hik-Connect / DoLynk via
        # our sync; EZVIZ / Imou keep their existing poll / callback)
        if v in ("hikconnect", "dolynk"):
            before = ShopEvent.objects.count()
            self.sim.push_alarm(v, serial, int(ch), "human")
            tot = V.sync_all()
            self.assertEqual(tot["events"], 1, tot)
            ev = ShopEvent.objects.order_by("-id").first()
            self.assertEqual(ShopEvent.objects.count(), before + 1)
            self.assertEqual(ev.camera_id, cam["id"])
            self.assertTrue(ev.snapshot, "no snapshot stored for %s" % v)
            self.assertTrue(self.shop_pushes(), "no push for %s: %r" % (v, self.pushes))
            # the same vendor event again is never a second alert
            self.sim.hik_queue = []
            if v == "dolynk":
                V.sync_all()
                self.assertEqual(ShopEvent.objects.count(), before + 1)
        else:
            c = ShopCamera.objects.get(pk=cam["id"])
            want = ("EZ:%s:%s" % (serial, ch)) if v == "ezviz" else "%s:%s" % (serial, ch)
            self.assertEqual(c.vendor_ref, want)
        # cloud health: disk failed -> one camera_health alert
        self.sim.set_disk(v, serial, "error")
        lk = CctvCloudLink.objects.get(pk=link["id"])
        lk.state = dict(lk.state or {}, health_at=0)      # health is due now
        lk.save(update_fields=["state"])
        V.sync_all()
        self.assertTrue(ShopEvent.objects.filter(type="camera_health",
                                                 camera_id=cam["id"]).exists(),
                        "no camera_health for %s: %r" % (v, list(ShopEvent.objects.values_list(
                            "type", "camera_id"))))
        # revoke: grant wiped, device released, camera unlinked
        r = self.client.delete("/api/v1/cctv/connect/links/%d" % link["id"])
        self.assertEqual(r.status_code, 200, r.data)
        row.refresh_from_db()
        self.assertEqual((row.status, row.grant_blob, row.serials), ("revoked", "", []))
        self.assertIsNone(self.sim.devs[v][serial].owner)
        self.assertEqual(ShopCamera.objects.get(pk=cam["id"]).vendor_ref, "")

    def test_e2e_hikconnect(self):
        self.run_vendor("hikconnect")

    def test_e2e_dolynk(self):
        self.run_vendor("dolynk")

    def test_e2e_ezviz(self):
        self.run_vendor("ezviz")

    def test_e2e_imou(self):
        self.run_vendor("imou")

    def test_stream_never_for_staff_or_viewer_without_live(self):
        from core.models import User
        link, serial, ch, cam = self.connect("hikconnect")
        staff = User.objects.create_user(name="Admin", phone="01710003009", password="pw")
        staff.is_staff = staff.is_superuser = True
        staff.save()
        c = APIClient()
        c.force_authenticate(staff)
        r = c.post("/api/v1/cctv/connect/cameras/%d/stream" % cam["id"], {}, format="json")
        self.assertEqual(r.status_code, 404)
        c.force_authenticate(self.family)           # a viewer, live not allowed
        r = c.post("/api/v1/cctv/connect/cameras/%d/stream" % cam["id"], {}, format="json")
        self.assertEqual(r.status_code, 404)
        r = c.get("/api/v1/cctv/connect/links/%d/devices" % link["id"])
        self.assertEqual(r.status_code, 404)        # viewers never manage links
        r = c.post("/api/v1/cctv/connect/hikconnect/link",
                   {"site": self.sid, "serial": serial, "code": "ABC123", "consent": True}, format="json")
        self.assertEqual(r.status_code, 404)

    def test_same_device_cannot_join_two_sites_and_tries_are_limited(self):
        from core.models import ShopSite
        self.connect("ezviz")
        other = ShopSite.objects.create(owner=self.family, name="Other")
        c = APIClient()
        c.force_authenticate(self.family)
        r = c.post("/api/v1/cctv/connect/ezviz/link",
                   {"site": other.id, "serial": "SIMEZDVR1", "code": "ABC123", "consent": True}, format="json")
        self.assertIn(r.status_code, (403, 409))
        from core import cctv_connect_views as V
        with mock.patch.object(V, "LINK_TRIES_PER_HOUR", 0):
            r = self.client.post("/api/v1/cctv/connect/ezviz/link",
                                 {"site": self.sid, "serial": "SIMEZDVR1", "code": "ABC123", "consent": True},
                                 format="json")
        self.assertEqual(r.status_code, 429)

    def test_devbind_needs_consent_and_is_owner_only_unless_switched_on(self):
        from core.models import ShopCamera, ShopSite
        link, serial, ch, cam = self.connect("ezviz")
        self.assertTrue(ShopCamera.objects.get(pk=cam["id"]).compat.get("owner_test"))
        r = self.client.post("/api/v1/cctv/connect/ezviz/link",
                             {"site": self.sid, "serial": serial, "code": "ABC123"}, format="json")
        self.assertEqual((r.status_code, r.data["error"]), (422, "consent_required"))
        # a customer: the brand is hidden and a direct call is refused
        site = ShopSite.objects.create(owner=self.family, name="Customer")
        c = APIClient()
        c.force_authenticate(self.family)
        r = c.get("/api/v1/cctv/connect/providers?site=%d" % site.id)
        self.assertEqual(r.data["providers"], [])
        r = c.post("/api/v1/cctv/connect/ezviz/link",
                   {"site": site.id, "serial": "SIMEZX", "code": "ABC123", "consent": True},
                   format="json")
        self.assertEqual((r.status_code, r.data["error"]), (403, "devbind_owner_only"))
        # the owner switches it on for customers in Owner Admin
        _enable("ezviz", dict(self.sim.cfg("ezviz"), devbind_customers="on"))
        r = c.get("/api/v1/cctv/connect/providers?site=%d" % site.id)
        self.assertEqual([p["id"] for p in r.data["providers"]], ["ezviz"])
        self.assertIn("I own this camera", r.data["providers"][0]["consent_en"])

    def test_dolynk_callback_token_signed_push_and_safe_log(self):
        """dolynkreal: the Open IoT push (Doc Center "Event message format
        definition") — secret URL token + sign = HMAC-SHA512(id, SK)."""
        from core import cctv_connect_views as V
        from core.models import ShopEvent
        link, serial, ch, cam = self.connect("dolynk")
        url = V.dolynk_callback_url(self.sim.cfg("dolynk")["access_key"])
        path = url[url.index("/api/v1/"):]
        r = APIClient().post(path.rsplit("/", 1)[0] + "/wrong", "{}", content_type="application/json")
        self.assertEqual(r.status_code, 404)
        a = {"id": "%s-7" % serial, "channel": int(ch), "type": "smdHuman", "at": time.time(),
             "pic": "https://cloudreadproxy-online-sg.imoulife.com/x_img/Alarm/0/a.jpg"}
        msg = self.sim.dl_msg(serial, a)
        with self.assertLogs("assisto.shop", level="INFO") as logs:
            r = APIClient().post(path, json.dumps(dict(msg, sign="0" * 128)),
                                 content_type="application/json")
        self.assertEqual(r.status_code, 200)
        self.assertEqual(r.data["events"][0], {"ignored": "bad_sign"})
        out = "\n".join(logs.output)
        self.assertIn("msgType", out)                        # keys only, never values
        self.assertNotIn(serial, out)
        r = APIClient().post(path, json.dumps(msg), content_type="application/json")
        self.assertEqual(r.data["events"][0], {"result": "raised"}, r.data)
        self.assertEqual((r.data["code"], r.data["msg"]), (200, "success"))
        self.assertTrue(ShopEvent.objects.filter(camera_id=cam["id"]).exists())
        rows = {x["slug"]: x for x in integrations.list_all("en")}
        self.assertIn("/api/v1/cctv/dolynk/callback/", rows["dolynk"]["usage"])

    def test_dolynk_on_only_after_signed_signin(self):
        from core.models import Integration
        Integration.objects.create(slug="dolynk", status="working",
                                   enc_blob=integrations._encrypt(self.sim.cfg("dolynk")),
                                   detail="DoLynk keys saved; server reachable (HTTP 404).")
        self.assertNotIn("dolynk", self.providers())          # keys alone: OFF
        bad = dict(self.sim.cfg("dolynk"), secret_key="wrong")
        ok, detail = integrations.test_dolynk(bad, http=self.sim.http)
        self.assertFalse(ok)
        self.assertNotIn(CC.DOLYNK_OK, detail)
        self.assertIn("PRM0016", detail)                       # the raw code is shown
        self.assertNotIn("wrong", detail)                      # never a key
        ok, detail = integrations.test_dolynk(self.sim.cfg("dolynk"), http=self.sim.http)
        self.assertTrue(ok)
        self.assertIn(CC.DOLYNK_OK, detail)
        self.assertNotIn("dlsk", detail)
        Integration.objects.filter(slug="dolynk").update(detail=detail)
        self.assertIn("dolynk", self.providers())

    def test_import_respects_plan(self):
        _enable("imou", self.sim.cfg("imou"))
        r = self.client.post("/api/v1/cctv/connect/imou/link",
                             {"site": self.sid, "serial": "SIMIMDVR1", "code": "ABC123", "consent": True},
                             format="json")
        lid = r.data["link"]["id"]
        with mock.patch("core.shop_views._included_cameras", return_value=1):
            r = self.client.post("/api/v1/cctv/connect/links/%d/import" % lid,
                                 {"items": [{"serial": "SIMIMDVR1", "channel": c} for c in (0, 1)]},
                                 format="json")
        self.assertEqual(len(r.data["added"]), 1)
        self.assertEqual(r.data["skipped"][0]["why"], "plan_full")
        self.assertTrue(r.data["message"])
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % lid,
                             {"items": [{"serial": "NOTMINE", "channel": 0}]}, format="json")
        self.assertEqual(r.data["skipped"][0]["why"], "not_in_link")


class GuardBoxHealthE2ETests(E2E._Base):
    """The REAL camlink probe (edge/shopbox) reads a simulated DVR over HTTP
    digest and posts to the REAL server endpoint with the SITE token."""

    def setUp(self):
        super().setUp()
        for p in (EDGE, os.path.join(EDGE, "tests")):
            if p not in sys.path:
                sys.path.insert(0, p)
        from core.models import ShopSite
        self.token = ShopSite.objects.get(pk=self.site["id"]).enrollment_token
        self.cam = self.add_camera("hikvision", "Counter")

    def post(self, url, body, headers):
        path = url[url.index("/api/v1/"):]
        r = APIClient().post(path, body, format="json",
                             HTTP_X_SHOP_TOKEN=headers.get("X-Shop-Token", ""))
        self.last = r
        return r.status_code

    def run_probe(self, sim, vendor):
        from shopbox.camlink import health_probe as HP
        from dvr_sim import PASSWORD, USER
        rep = HP.probe(vendor, "127.0.0.1", sim.port, USER, PASSWORD)
        self.assertNotIn("error", rep)
        return HP.post_reports(self.post, "https://assisto.test", self.token, [rep])

    def test_hikvision_isapi_healthy_then_disk_and_recording_alerts(self):
        from dvr_sim import DvrSim
        from core.models import ShopEvent
        with DvrSim("hikvision", channels=2) as sim:
            self.assertEqual(self.run_probe(sim, "hikvision"), 200, self.last.data)
            card = self.client.get("/api/v1/cctv/health/sites/%d" % self.site["id"]).data
            self.assertEqual(card["status"], "green", card)
            self.assertGreaterEqual(card["recorded_days"], 11)
            # the family viewer sees the same card (read-only)
            c = APIClient()
            c.force_authenticate(self.family)
            self.assertEqual(c.get("/api/v1/cctv/health/sites/%d" % self.site["id"]).status_code, 200)
            sim.state.disk = "error"
            sim.state.not_recording.add(1)
            self.assertEqual(self.run_probe(sim, "hikvision"), 200)
            self.assertGreaterEqual(ShopEvent.objects.filter(type="camera_health").count(), 1)
            card = self.client.get("/api/v1/cctv/health/sites/%d" % self.site["id"]).data
            self.assertEqual(card["status"], "red")
            self.assertEqual({l["kind"] for l in card["lines"]} >= {"hdd_fail", "rec_stopped"}, True)
            # the same problems again: no new alert (6 h guard)
            n = ShopEvent.objects.filter(type="camera_health").count()
            self.run_probe(sim, "hikvision")
            self.assertEqual(ShopEvent.objects.filter(type="camera_health").count(), n)

    def test_dahua_full_disk_without_overwrite_and_target_days(self):
        from dvr_sim import DvrSim
        with DvrSim("dahua", channels=2) as sim:
            sim.state.disk = "full"
            sim.state.overwrite = False
            sim.state.offline.add(2)
            self.assertEqual(self.run_probe(sim, "dahua"), 200)
        card = self.client.get("/api/v1/cctv/health/sites/%d" % self.site["id"]).data
        self.assertEqual({l["kind"] for l in card["lines"]}, {"hdd_full", "cam_offline"})
        self.assertEqual(card["checks"]["days"], "unknown")    # Dahua: not read (honest)
        r = self.client.put("/api/v1/cctv/health/sites/%d" % self.site["id"],
                            {"target_days": 30}, format="json")
        self.assertEqual((r.status_code, r.data["target_days"]), (200, 30))
        c = APIClient()
        c.force_authenticate(self.family)
        r = c.put("/api/v1/cctv/health/sites/%d" % self.site["id"], {"target_days": 3},
                  format="json")
        self.assertEqual(r.status_code, 404)

    def test_wrong_token_and_secrets_refused(self):
        r = APIClient().post("/api/v1/shop/gateway/dvr-health", {"reports": [{"device": "x"}]},
                             format="json", HTTP_X_SHOP_TOKEN="nope")
        self.assertEqual(r.status_code, 401)
        r = APIClient().post("/api/v1/shop/gateway/dvr-health",
                             {"reports": [{"device": "x", "password": "p"}]},
                             format="json", HTTP_X_SHOP_TOKEN=self.token)
        self.assertEqual((r.status_code, r.data["error"]), (422, "secret_refused"))

    def test_daily_green_check_once_a_day(self):
        from core import cctv_connect_views as V
        V.store_report(self.cam_site(), {"source": "isapi", "device": "SIMHK",
                                         "disks": [{"id": "1", "state": "ok"}],
                                         "channels": [{"no": 1, "online": True, "recording": True}],
                                         "oldest_record": time.time() - 9 * 86400,
                                         "latest_record": time.time() - 30})
        sent = []
        at9 = timezone.localtime(timezone.now()).replace(hour=9, minute=5)
        n = V.daily_checks(now=at9, push=lambda *a: sent.append(a))
        self.assertEqual(n, 1)
        self.assertEqual(len(sent), 2)            # owner + the family viewer
        self.assertEqual(sent[0][5]["status"], "green")
        self.assertIn("all good", sent[0][2].lower() + sent[0][3].lower())
        self.assertEqual(V.daily_checks(now=at9, push=lambda *a: sent.append(a)), 0)
        at7 = at9.replace(hour=7)
        self.assertEqual(V.daily_checks(now=at7 + timedelta(days=1),
                                        push=lambda *a: sent.append(a)), 0)

    def cam_site(self):
        from core.models import ShopSite
        return ShopSite.objects.get(pk=self.site["id"])


# ====================================================================== 5
class ImouSignTests(SimpleTestCase):
    def test_sign_v2_matches_imou_docs_example(self):
        from core.logic import imou as IM
        self.assertEqual(IM.sign_v2(1706511734, "f5a1ae2d-c09c-4d39-a744-83a5c2c653c2",
                                    "test123456789test123456789"),
                         "xjhCQBoJ9hRDsCjyDcHjtDNzRZ3ZJezcawsfWeiaoxU=")


class ImouOAuthE2ETests(E2E._Base):
    """Owner 9 Nov 16:50: a shop / home owner links his OWN Imou account in
    one tap (OAuth 2.0, Imou public docs), then device list, live, alarms and
    people counting flow in, inside the free monthly quota."""

    def setUp(self):
        super().setUp()
        _clear_caches()
        from core.models import ShopSite
        self.sim = M.VendorSims()
        d = self.sim.add_device("imou", "SIMIMOUSER1", "ZZZ999", channels=2)
        d.oauth_user = True
        for target, value in (("core.logic.cctv_connect.base.default_http", self.sim.http),
                              ("core.shop_views._included_cameras", mock.Mock(return_value=10)),
                              ("core.logic.imou.fetch_snapshot", mock.Mock(return_value=E2E._jpeg()))):
            p = mock.patch(target, value)
            p.start()
            self.addCleanup(p.stop)
        _enable("imou", self.sim.cfg("imou"))
        self.sid = self.site["id"]
        ShopSite.objects.filter(pk=self.sid).update(
            away={"until": (timezone.now() + timedelta(days=1)).isoformat()})

    def start(self):
        r = self.client.post("/api/v1/cctv/connect/imou/oauth/start", {"site": self.sid},
                             format="json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIn("/api/v1/cctv/connect/oauth/go?state=", r.data["url"])
        return r.data["state"]

    def test_one_tap_link_devices_live_alarm_people_quota(self):
        from core import cctv_connect_views as V
        from core.models import CctvCloudLink, CctvVendorUsage, ShopEvent
        r = self.client.get("/api/v1/cctv/connect/providers?site=%d" % self.sid)
        imou = [p for p in r.data["providers"] if p["id"] == "imou"][0]
        self.assertIn("oauth", imou["modes"])
        state = self.start()
        browser = APIClient()
        go = browser.get("/api/v1/cctv/connect/oauth/go", {"state": state})
        self.assertEqual(go.status_code, 302)
        self.assertTrue(go["Location"].startswith("https://open.imoulife.com/oauth/h5?project=sim&state="))
        self.assertIn(V.OAUTH_COOKIE, go.cookies)
        # Imou sends the browser back to the URL registered in its console
        cb = browser.get("/api/v1/cctv/imou/oauth/callback", {"code": "good-code", "state": state})
        self.assertEqual(cb.status_code, 200, cb.content[:300])
        self.assertEqual(cb["Cache-Control"], "no-store")
        link = CctvCloudLink.objects.get(site_id=self.sid, provider="imou")
        self.assertEqual((link.mode, link.serials), ("oauth", ["SIMIMOUSER1"]))
        self.assertNotIn("Ot_sim", link.grant_blob)
        g = CC.unseal(self.sid, link.grant_blob)
        self.assertEqual(g["access_token"], "Ot_sim")
        self.assertGreater(g["auth_until"], time.time() + 89 * 86400)
        self.assertIn(("imou", "alarm,deviceStatus,capabilityEvent,numberstat"), self.sim.callbacks)
        # the state is one-time: a replay links nothing new
        browser.get("/api/v1/cctv/imou/oauth/callback", {"code": "good-code", "state": state})
        self.assertEqual(CctvCloudLink.objects.filter(site_id=self.sid).count(), 1)
        # device list -> import -> live (RTSP when Imou gives no HLS to OAuth)
        r = self.client.get("/api/v1/cctv/connect/links/%d/devices" % link.id)
        self.assertEqual(len(r.data["devices"][0]["channels"]), 2)
        self.assertEqual(r.data["link"]["auth_days_left"], 89)
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link.id,
                             {"items": [{"serial": "SIMIMOUSER1", "channel": 0}]}, format="json")
        cam = r.data["added"][0]
        r = self.client.post("/api/v1/cctv/connect/cameras/%d/stream" % cam["id"], {}, format="json")
        self.assertEqual((r.status_code, r.data["proto"]), (200, "rtsp"), r.data)
        self.assertTrue(r.data["url"].startswith("rtsp://live.lechange.com/"))
        # an alarm PUSHED by Imou -> alert; marks the link "push works"
        from core.logic import imou as IM
        from django.conf import settings
        path = "/api/v1/shop/imou/callback/%s" % IM.callback_token("imid", settings.SECRET_KEY)
        alarm = {"msgType": "human", "did": "SIMIMOUSER1", "cid": "0", "alarmId": "a-1",
                 "time": int(time.time()), "picurlArray": ["https://pic.easy4ip.com/a/1.jpg"]}
        r = APIClient().post(path, json.dumps(alarm), content_type="application/json")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["events"][0]["raised"], r.data)
        self.assertEqual(ShopEvent.objects.get(camera_id=cam["id"]).type, "camera_alarm")
        link.refresh_from_db()
        self.assertTrue(link.state.get("push_at"))
        self.assertFalse(V.imou_poll_due(link, timezone.now()))    # push works: no polling
        # people counting (numberstat) -> the daily-report feed, never an alarm
        ppl = {"msgType": "numberstat", "did": "SIMIMOUSER1", "cid": "0", "inNum": 3, "outNum": 1}
        r = APIClient().post(path, json.dumps(ppl), content_type="application/json")
        self.assertEqual(r.data["events"][0], {"people": True})
        self.assertEqual(ShopEvent.objects.filter(camera_id=cam["id"]).count(), 1)
        from core.models import ShopSite
        pc = V.people_counts(ShopSite.objects.get(pk=self.sid))
        self.assertEqual((pc["in"], pc["out"]), (3, 1))
        # the free quota is counted
        u = CctvVendorUsage.objects.get(provider="imou")
        self.assertGreater(u.api_calls, 3)
        self.assertEqual(u.messages, 2)
        self.assertGreater(u.traffic_mb, 0)
        rows = {r["slug"]: r for r in integrations.list_all("en")}
        self.assertIn("Free quota this month", rows["imou"]["usage"])

    def test_cookie_fallback_when_imou_drops_state_and_bad_code(self):
        from core.models import CctvCloudLink
        state = self.start()
        browser = APIClient()
        browser.get("/api/v1/cctv/connect/oauth/go", {"state": state})
        self.sim.oauth_codes["code-2"] = "Ot_sim"
        r = browser.get("/api/v1/cctv/imou/oauth/callback", {"code": "code-2"})
        self.assertEqual(r.status_code, 200, r.content[:200])
        self.assertTrue(CctvCloudLink.objects.filter(site_id=self.sid, mode="oauth").exists())
        state = self.start()
        browser = APIClient()
        browser.get("/api/v1/cctv/connect/oauth/go", {"state": state})
        r = browser.get("/api/v1/cctv/imou/oauth/callback", {"code": "wrong", "state": state})
        self.assertEqual(r.status_code, 400)
        self.assertEqual(CctvCloudLink.objects.filter(site_id=self.sid).count(), 1)

    def test_poll_fallback_and_quota_warning(self):
        from core import cctv_connect_views as V
        from core.models import CctvCloudLink, CctvVendorUsage, ShopEvent
        from core.logic.cctv_connect import quota as Q
        state = self.start()
        b = APIClient()
        b.get("/api/v1/cctv/connect/oauth/go", {"state": state})
        b.get("/api/v1/cctv/imou/oauth/callback", {"code": "good-code", "state": state})
        link = CctvCloudLink.objects.get(site_id=self.sid)
        r = self.client.post("/api/v1/cctv/connect/links/%d/import" % link.id,
                             {"items": [{"serial": "SIMIMOUSER1", "channel": 1}]}, format="json")
        cam = r.data["added"][0]
        # no push seen -> the poll fallback picks the camera's own alarm up
        self.sim.push_alarm("imou", "SIMIMOUSER1", 1, "human")
        tot = V.sync_all()
        self.assertEqual(tot["events"], 1, tot)
        self.assertTrue(ShopEvent.objects.filter(camera_id=cam["id"]).exists())
        link.refresh_from_db()
        self.assertFalse(V.imou_poll_due(link, timezone.now()))        # 15 min gap
        # 80 % of the free API calls -> ONE owner warning, polling slows down
        lim = Q.limits("imou")["api_calls"]
        CctvVendorUsage.objects.filter(provider="imou").update(api_calls=int(lim * 0.8))
        with mock.patch("core.push.notify_owner") as n:
            Q.bump("imou", api=1)
            Q.bump("imou", api=1)
        self.assertEqual(n.call_count, 1)
        self.assertTrue(Q.saving("imou"))
        st = dict(link.state, poll_at=time.time() - 1000, push_at=0)
        CctvCloudLink.objects.filter(pk=link.pk).update(state=st)
        link.refresh_from_db()
        self.assertFalse(V.imou_poll_due(link, timezone.now()))        # now hourly
        CctvVendorUsage.objects.filter(provider="imou").update(api_calls=lim)
        st["poll_at"] = 0
        CctvCloudLink.objects.filter(pk=link.pk).update(state=st)
        link.refresh_from_db()
        self.assertFalse(V.imou_poll_due(link, timezone.now()))        # 100 %: stopped

    def test_card_says_waiting_for_imou_until_oauth_keys(self):
        _enable("imou", {"app_id": "imid", "app_secret": "ims"})
        rows = {r["slug"]: r for r in integrations.list_all("en")}
        self.assertIn("waiting for Imou approval (ticket 483)", rows["imou"]["usage"])
        _enable("imou", self.sim.cfg("imou"))
        rows = {r["slug"]: r for r in integrations.list_all("en")}
        self.assertNotIn("ticket 483", rows["imou"]["usage"])
        # the callback stays live: an unknown visit gets a clean, no-store page
        r = APIClient().get("/api/v1/cctv/imou/oauth/callback")
        self.assertEqual((r.status_code, r["Cache-Control"]), (400, "no-store"))

    def test_owner_admin_test_checks_oauth_keys(self):
        ok, detail = integrations.test_imou(self.sim.cfg("imou"), http=self.sim.http)
        self.assertTrue(ok, detail)
        self.assertIn("OAuth keys accepted", detail)
        bad = dict(self.sim.cfg("imou"), oauth_sk="wrong")
        ok, detail = integrations.test_imou(bad, http=self.sim.http)
        self.assertFalse(ok)
        self.assertIn("not accepted", detail)
