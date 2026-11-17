"""gap-safejourney (feature gap lane, 17 Nov): what a real user noticed was
missing on Safe Journey.

* the watcher's in-app card now carries the ride / number-plate photo
  (before: only the web page had it) — only while the trip is live;
* the traveller's own journey carries the names of the people watching.

Made-up people and places only.
"""
import base64
import io
import tempfile
from datetime import timedelta

from django.test import override_settings
from django.utils import timezone

from core.models import Journey
from core.tests_journey100 import V, Base, edge, mk


def _png():
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (40, 30), (10, 120, 200)).save(buf, "PNG")
    return base64.b64encode(buf.getvalue()).decode()


class WatcherRidePhotoTests(Base):
    def test_photo_on_watcher_card_only_while_live(self):
        with tempfile.TemporaryDirectory() as tmp, override_settings(MEDIA_ROOT=tmp):
            j, _ = self.start()
            row = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
            self.assertIsNone(row["ride_photo"])          # no photo yet
            r = self.ca.post("%s/journey/%d/vehicle-photo" % (V, j.id),
                             {"image_b64": _png(), "plate": "DHA-METRO-GA-11"}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            row = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
            self.assertTrue(row["ride_photo"].startswith("/api/v1/m/"), row)
            self.assertIn("s=", row["ride_photo"])        # signed, short-lived
            self.assertEqual(row["ride"]["plate"], "DHA-METRO-GA-11")
            # a stranger never sees it
            self.assertEqual(self.cc.get("%s/journey/watching" % V).json()["journeys"], [])
            # trip over -> no photo link any more (privacy)
            Journey.objects.filter(pk=j.pk).update(status="arrived")
            row = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
            self.assertIsNone(row["ride_photo"])


class TravellerSeesWatchersTests(Base):
    def test_active_journey_lists_watcher_names(self):
        d = mk("01711000009", "Dad")
        ad = edge(self.a, d)
        self.start(watcher_ids=[self.ab.id, ad.id])
        r = self.ca.get("%s/journey/active" % V).json()
        self.assertEqual(r["watcher_names"], ["Mother", "Dad"])

    def test_watcher_never_gets_the_list(self):
        j, _ = self.start()
        row = self.cb.get("%s/journey/watching" % V).json()["journeys"][0]
        self.assertNotIn("watcher_names", row)
        self.assertEqual(j.watchers.count(), 1)

    def test_blank_names_skipped(self):
        d = mk("01711000008", "Dad")
        ad = edge(self.a, d)
        ad.name = "  "
        ad.save(update_fields=["name"])
        self.start(watcher_ids=[self.ab.id, ad.id],
                   eta=(timezone.now() + timedelta(minutes=30)).isoformat())
        r = self.ca.get("%s/journey/active" % V).json()
        self.assertEqual(r["watcher_names"], ["Mother"])
