"""flag-vehicle: Owner Admin -> Tracker packets (raw log of the first real
ST-906 packets). Ids masked except the last 4 digits; parse errors and
refused ids shown; anything older than 72 h never shown; owner-only."""
import json
import os
import tempfile
import time

from django.test import Client

from tracker import rawlog
from tracker.protocols import h02
from web.tests_o2_owner_admin import OwnerBase


class TrackerPacketsPageTests(OwnerBase):
    def setUp(self):
        super().setUp()
        d = tempfile.mkdtemp()
        self.path = os.path.join(d, "raw.jsonl")
        old = os.environ.get("TRACKER_RAW_LOG")
        os.environ["TRACKER_RAW_LOG"] = self.path
        self.addCleanup(lambda: os.environ.pop("TRACKER_RAW_LOG", None) if old is None
                        else os.environ.__setitem__("TRACKER_RAW_LOG", old))

    def test_empty_then_masked_rows_errors_and_retention(self):
        self.ready()
        r = self.c.get("/owner/tracker-packets")
        self.assertEqual(r.status_code, 200)
        self.assertIn('id="tracker-packets-empty"', r.content.decode())
        fr = (b"*HQ,9171234567,V1,121300,A,2345.0360,N,09022.4220,E,000.00,000,"
              b"171126,FFFFFBFF,470,01,0,0,6#")
        rawlog.record("h02", "9171234567", fr, h02.parse_frame(fr), known=True)
        rawlog.record("h02", "9179999999", fr, h02.parse_frame(fr), known=False,
                      error="refused_unknown")
        rawlog.record("h02", "", b"*HQ,1#", error="short")
        rawlog.record("unknown", "", b"\x78\x78\x0d\x01", error="unknown_protocol")
        with open(self.path, "a") as fh:            # an old row (73 h) never shows
            fh.write(json.dumps({"ts": time.time() - 73 * 3600, "proto": "h02",
                                 "imei": "9170000000", "hex": "", "fields": {}}) + "\n")
        html = self.c.get("/owner/tracker-packets").content.decode()
        self.assertIn('id="tracker-packets"', html)
        self.assertNotIn("9171234567", html)
        self.assertIn("••••••4567", html)
        self.assertIn("refused_unknown", html)
        self.assertIn("unknown_protocol", html)
        self.assertIn("২৩.৭৫০৬০", html)            # parsed latitude
        self.assertNotIn("••••••0000", html)       # 73-hour-old row dropped
        self.assertEqual(len(rawlog.recent(50)), 4)

    def test_owner_only(self):
        r = Client().get("/owner/tracker-packets", secure=True)
        self.assertIn(r.status_code, (302, 403, 404))
