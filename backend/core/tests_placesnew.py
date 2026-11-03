"""placesnew (owner 3 Nov 19:55): the Google Places test and Safe Journey place
search use Places API (New) + Geocoding — never the legacy Places web service
— and never echo the key."""
import io
import json
import subprocess
import urllib.error
from unittest import mock

from django.conf import settings
from django.test import SimpleTestCase

from core import integrations as I
from core import journey_geo as G

KEY = "fake-test-key-not-real-0001"


def _resp(obj):
    return io.BytesIO(json.dumps(obj).encode())


def _http_err(code, obj):
    return urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(json.dumps(obj).encode()))


class PlacesNewTest(SimpleTestCase):
    def test_both_ok(self):
        seen = []

        def fake(req, timeout=0):
            seen.append(req.full_url)
            if "places.googleapis.com/v1/places:searchText" in req.full_url:
                self.assertEqual(req.get_header("X-goog-api-key"), KEY)
                self.assertTrue(req.get_header("X-goog-fieldmask"))
                return _resp({"places": [{"id": "x"}]})
            return _resp({"status": "OK", "results": []})
        with mock.patch("urllib.request.urlopen", fake):
            ok, detail = I.test_google_places({"api_key": KEY})
        self.assertTrue(ok, detail)
        self.assertIn("Places API (New)", detail)
        self.assertIn("Geocoding", detail)
        self.assertFalse(any("maps/api/place" in u for u in seen))

    def test_separate_results_and_google_reason_without_key(self):
        def fake(req, timeout=0):
            if "places.googleapis.com" in req.full_url:
                raise _http_err(403, {"error": {"status": "PERMISSION_DENIED",
                                                "message": "Places API (New) has not been used for key " + KEY}})
            return _resp({"status": "REQUEST_DENIED", "error_message": "This API key is not authorized"})
        with mock.patch("urllib.request.urlopen", fake):
            ok, detail = I.test_google_places({"api_key": KEY})
        self.assertFalse(ok)
        self.assertIn("PERMISSION_DENIED", detail)
        self.assertIn("REQUEST_DENIED", detail)
        self.assertIn("not authorized", detail)
        self.assertIn("অনুমতি নেই", detail)
        self.assertNotIn(KEY, detail)

    def test_journey_search_uses_places_new(self):
        def fake(req, timeout=0):
            self.assertIn("places.googleapis.com/v1/places:searchText", req.full_url)
            body = json.loads(req.data.decode())
            self.assertEqual(body["textQuery"], "Mirpur 10")
            self.assertIn("locationBias", body)
            return _resp({"places": [{"displayName": {"text": "Mirpur 10"},
                                      "formattedAddress": "Dhaka",
                                      "location": {"latitude": 23.8, "longitude": 90.36}}]})
        with mock.patch("urllib.request.urlopen", fake):
            rows = G._places_text("Mirpur 10", KEY, "bn", near=(23.8, 90.4))
        self.assertEqual(rows, [{"name": "Mirpur 10", "address": "Dhaka", "lat": 23.8, "lng": 90.36}])

    def test_no_legacy_places_directions_or_distance_matrix_in_backend(self):
        root = str(settings.BASE_DIR)
        out = subprocess.run(
            ["grep", "-rnE", "maps/api/(place|directions|distancematrix)", root,
             "--include=*.py", "--exclude=tests_placesnew.py"],
            capture_output=True, text=True).stdout
        self.assertEqual(out.strip(), "", out)
