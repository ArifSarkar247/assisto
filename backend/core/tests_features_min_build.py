"""owner 18 Nov (10378 live): a feature with a minimum app build is hidden from
older or unknown builds, shown from that build on; owner preview unchanged."""
from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from core import feature_flags as FF
from core.models import Device, FeatureFlag


class MinBuildTests(TestCase):
    def setUp(self):
        cache.clear()
        FF._cache["at"], FF._cache["rows"] = 0.0, None
        FeatureFlag.objects.update_or_create(
            key="invoice_designs",
            defaults={"enabled_all": True, "enabled_play": True, "rollout_pct": 100})
        FF._cache["at"], FF._cache["rows"] = 0.0, None
        self.u = get_user_model().objects.create_user(
            phone="01711000111", password="x-pass-123")
        self.c = APIClient()
        self.c.force_authenticate(self.u)

    def _on(self, **hdr):
        r = self.c.get("/api/v1/features", **hdr)
        self.assertEqual(r.status_code, 200)
        return r.json()["features"]["invoice_designs"]

    def test_unknown_build_hidden(self):
        self.assertFalse(self._on())

    def test_old_header_hidden_new_header_shown(self):
        self.assertFalse(self._on(HTTP_X_APP_VERSION="1.0.338+10338"))
        self.assertTrue(self._on(HTTP_X_APP_VERSION="1.0.378+10378"))

    def test_newest_registered_phone_counts(self):
        Device.objects.create(user=self.u, push_token="t-old", app_version="1.0.338+10338")
        self.assertFalse(self._on())
        Device.objects.create(user=self.u, push_token="t-new", app_version="1.0.378+10378")
        self.assertTrue(self._on())

    def test_flag_off_stays_off(self):
        FeatureFlag.objects.filter(key="invoice_designs").update(enabled_all=False)
        FF._cache["at"], FF._cache["rows"] = 0.0, None
        self.assertFalse(self._on(HTTP_X_APP_VERSION="1.0.378+10378"))
