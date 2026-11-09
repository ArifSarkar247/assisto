"""bizai pillar 4 — CCTV accuracy is MEASURED, never claimed: precision /
recall per kind from reviews + missed reports, live test sessions on the
real camera (taps matched to alerts within 30 s), and the clip-manifest
runner. Below 20 events = "not enough", never a 90 % badge."""
import json
import os
import tempfile
from datetime import timedelta
from io import StringIO

from django.core.management import call_command
from django.test import SimpleTestCase, TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from core import bizai_cctv as C
from core.models import ShopEvent, ShopSite, User

API = "/api/v1/"


class PureTests(SimpleTestCase):
    def test_prf_and_target_needs_enough_events(self):
        r = C.prf(9, 1, 1)
        self.assertEqual((r["precision"], r["recall"]), (0.9, 0.9))
        self.assertFalse(r["enough"])              # 11 events < 20
        self.assertFalse(r["meets_target"])
        r = C.prf(19, 1, 1)
        self.assertTrue(r["meets_target"])
        self.assertIsNone(C.prf(0, 0, 0)["precision"])

    def test_match_tp_fp_fn_with_window(self):
        truth = [{"kind": "person", "at": 100}, {"kind": "person", "at": 300},
                 {"kind": "line", "at": 500}]
        alerts = [{"type": "person_detected", "at": 110},     # TP (10 s)
                  {"type": "person_detected", "at": 1000},    # FP (no truth near)
                  {"type": "line_crossing", "at": 560}]       # 60 s late → FP + line FN
        r = C.match(truth, alerts, window_s=30)
        self.assertEqual((r["person"]["tp"], r["person"]["fn"]), (1, 1))
        self.assertEqual(r["line"]["fn"], 1)
        self.assertEqual(r["person"]["fp"] + r.get("line", {}).get("fp", 0), 2)

    def test_each_alert_matches_once(self):
        truth = [{"kind": "person", "at": 100}, {"kind": "person", "at": 101}]
        r = C.match(truth, [{"type": "motion", "at": 100}])
        self.assertEqual((r["person"]["tp"], r["person"]["fn"]), (1, 1))


class ApiTests(TestCase):
    def setUp(self):
        self.u = User.objects.create_user(email="cam@example.invalid", name="Cam", password="x")
        self.site = ShopSite.objects.create(owner=self.u, name="Shop")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def ev(self, typ, status="open", at=None):
        e = ShopEvent.objects.create(site=self.site, type=typ, status=status)
        if at:
            ShopEvent.objects.filter(pk=e.pk).update(created=at)
        return e

    def test_reviews_give_precision_and_missed_give_recall(self):
        for _ in range(8):
            self.ev("person_detected", "checked")
        for _ in range(2):
            self.ev("person_detected", "false_alarm")
        self.ev("person_detected")                                  # unreviewed
        r = self.c.post(API + "bizai/cctv/missed", {"site": self.site.pk, "kind": "person"},
                        format="json")
        self.assertEqual(r.status_code, 201)
        d = self.c.get(API + "bizai/cctv/accuracy").data
        p = d["reviews"]["per_type"]["person"]
        self.assertEqual((p["tp"], p["fp"], p["fn"]), (8, 2, 1))
        self.assertEqual(p["precision"], 0.8)
        self.assertEqual(d["reviews"]["unreviewed"], 1)
        self.assertFalse(p["meets_target"])

    def test_other_owners_site_refused(self):
        other = User.objects.create_user(email="o@example.invalid", name="O", password="x")
        s2 = ShopSite.objects.create(owner=other)
        self.assertEqual(self.c.post(API + "bizai/cctv/missed", {"site": s2.pk},
                                     format="json").status_code, 404)
        self.assertEqual(self.c.post(API + "bizai/cctv/test", {"site": s2.pk},
                                     format="json").status_code, 404)

    def test_live_test_session_matches_taps_to_alerts(self):
        r = self.c.post(API + "bizai/cctv/test", {"site": self.site.pk}, format="json").data
        tid = r["id"]
        self.c.post(API + "bizai/cctv/test/%d/mark" % tid, {"kind": "person"}, format="json")
        self.c.post(API + "bizai/cctv/test/%d/mark" % tid, {"kind": "cash"}, format="json")
        self.ev("person_detected")                     # the camera saw the person
        r = self.c.post(API + "bizai/cctv/test/%d/stop" % tid, format="json").data
        self.assertEqual(r["result"]["person"]["tp"], 1)
        self.assertEqual(r["result"]["cash"]["fn"], 1)   # cash zone missed
        d = self.c.get(API + "bizai/cctv/accuracy").data
        self.assertEqual(d["live_tests"]["sessions"], 1)
        self.assertEqual(d["live_tests"]["per_type"]["person"]["tp"], 1)
        # a stopped session takes no more taps
        self.assertEqual(self.c.post(API + "bizai/cctv/test/%d/mark" % tid, {"kind": "person"},
                                     format="json").status_code, 404)

    def test_clip_manifest_runner(self):
        m = {"clips": [{"file": "a.mp4", "truth": [{"kind": "person", "at": 4}],
                        "alerts": [{"type": "person_detected", "at": 5}]}]}
        fd, path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(fd, "w") as fh:
            json.dump(m, fh)
        self.addCleanup(os.remove, path)
        out = StringIO()
        call_command("cctv_eval", "--manifest", path, stdout=out)
        self.assertIn("person", out.getvalue())
        self.assertIn("tp=1 fp=0 fn=0", out.getvalue())
        self.assertIn("not-enough-events", out.getvalue())
        here = os.path.dirname(os.path.abspath(C.__file__))
        out = StringIO()
        call_command("cctv_eval", "--manifest",
                     os.path.join(here, "testdata", "cctv_clips", "manifest.example.json"),
                     stdout=out)
        self.assertIn("clips=1", out.getvalue())
