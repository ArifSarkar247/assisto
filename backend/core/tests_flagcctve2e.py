"""flag-cctv-e2e (W3) — the CCTV alert -> action path on the server, the
part the emulator flow (app/integration_test/flows/cctv_alert_flow.dart)
leans on:

1. a SIGNED DoLynk person alarm pushed to the PUBLIC callback link raises ONE
   alert with its snapshot, and pushes the owner AND the family viewer, with
   the ids the phone needs (event, site, camera, snapshot link);
2. a second alarm from the same camera 10 s later is MERGED into that alert
   (count 2, no second push) and the callback says "grouped" (it said
   "raised" before this lane);
3. the vendor re-sending the SAME message (it thinks we missed it) never
   alerts again; a wrong sign is refused;
4. the alert row carries what the card needs (snapshot, live path, count).
Synthetic data only.
"""
import json
import time

from rest_framework.test import APIClient

from core import tests_cctvconnect as TC
from core import tests_e2e_cctv as E2E


class CctvAlertActionTests(E2E._Base):
    setUp = TC.ConnectApiE2ETests.setUp
    connect = TC.ConnectApiE2ETests.connect

    def _post(self, path, msg):
        return APIClient().post(path, json.dumps([msg]), content_type="application/json")

    def test_signed_push_alert_merge_repush_and_viewer(self):
        from core import cctv_connect_views as V
        from core.models import ShopEvent
        link, serial, ch, cam = self.connect("dolynk")
        url = V.dolynk_callback_url(self.sim.cfg("dolynk")["access_key"])
        self.assertTrue(url.startswith("http"), url)          # the PUBLIC link
        path = url[url.index("/api/v1/"):]
        self.pushes.clear()
        now = time.time()
        a1 = {"id": "%s-1" % serial, "channel": int(ch), "type": "smdHuman", "at": now,
              "pic": "https://cloudreadproxy-online-sg.imoulife.com/a1_img/Alarm/0/a.jpg"}
        m1 = self.sim.dl_msg(serial, a1)

        # a forged sign never alerts
        r = self._post(path, dict(m1, sign="0" * 128))
        self.assertEqual(r.data["events"][0], {"ignored": "bad_sign"})
        self.assertFalse(ShopEvent.objects.filter(camera_id=cam["id"]).exists())

        r = self._post(path, m1)
        self.assertEqual((r.status_code, r.data["events"][0]), (200, {"result": "raised"}), r.data)
        ev = ShopEvent.objects.get(camera_id=cam["id"])
        self.assertTrue(ev.snapshot)
        users = sorted(a[0].pk for a, _k in self.pushes if a[1] == "shop_alert")
        self.assertEqual(users, sorted([self.owner.pk, self.family.pk]), self.pushes)
        data = [k["data"] for a, k in self.pushes if a[0].pk == self.owner.pk][0]
        self.assertEqual((data["event_id"], data["site_id"], data["camera_id"]),
                         (ev.id, self.sid, cam["id"]))
        self.assertIn("snapshot_url", data)
        self.assertFalse(data["viewer"])
        fam = [k["data"] for a, k in self.pushes if a[0].pk == self.family.pk][0]
        self.assertTrue(fam["viewer"])                  # opens read-only on B's phone
        n_push = len(self.pushes)

        # 10 s later the same camera sees the person again -> merged, no spam
        a2 = dict(a1, id="%s-2" % serial, at=now + 10,
                  pic="https://cloudreadproxy-online-sg.imoulife.com/a2_img/Alarm/0/a.jpg")
        r = self._post(path, self.sim.dl_msg(serial, a2))
        self.assertEqual(r.data["events"][0], {"result": "grouped"}, r.data)
        self.assertEqual(ShopEvent.objects.filter(camera_id=cam["id"]).count(), 1)
        ev.refresh_from_db()
        self.assertEqual(ev.count, 2)
        self.assertEqual(len(self.pushes), n_push, "a merged repeat must not push again")

        # the vendor re-sends message 1 (it thinks we missed it) -> nothing new
        r = self._post(path, m1)
        self.assertEqual(r.data["events"][0], {"result": "duplicate"}, r.data)
        ev.refresh_from_db()
        self.assertEqual(ev.count, 2)
        self.assertEqual(len(self.pushes), n_push)

        # the owner's card: photo, merged count, Live opens the vendor stream
        r = self.client.get("/api/v1/shop/events?site=%d&camera=%d" % (self.sid, cam["id"]))
        self.assertEqual(r.status_code, 200, r.data)
        row = [e for e in r.data["events"] if e["id"] == ev.id][0]
        self.assertTrue(row["snapshot_url"])
        self.assertEqual(row["count"], 2)
        self.assertEqual(row.get("live_path"), "vendor")

        # the family viewer sees the same alert (read-only)
        c = APIClient()
        c.force_authenticate(self.family)
        r = c.get("/api/v1/shop/events?site=%d" % self.sid)
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIn(ev.id, [e["id"] for e in r.data["events"]])
