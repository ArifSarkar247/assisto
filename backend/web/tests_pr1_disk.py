"""pr1: the Owner Admin dashboard shows a red disk banner at/over the alert
threshold (default 80%) — in the panel's one language — and nothing under it;
the pricing editor no longer offers an 'unlimited_ai' switch."""
import shutil
from unittest import mock

from web.tests_o2_owner_admin import OwnerBase


def _du(total_gb, used_gb):
    g = 10 ** 9
    return shutil._ntuple_diskusage(total_gb * g, used_gb * g, (total_gb - used_gb) * g)


class DiskBannerTests(OwnerBase):
    def _get(self, used, lang=None):
        with mock.patch("core.disk_alert.disk_usage", return_value=_du(100, used)):
            return self.c.get("/owner/" + ("?lang=%s" % lang if lang else "")).content.decode()

    def test_banner_only_at_or_over_80(self):
        self.ready()
        self.assertNotIn('id="disk-alert"', self._get(79))
        html = self._get(80)
        self.assertIn('id="disk-alert"', html)
        self.assertIn('class="flash bad"', html)

    def test_banner_language(self):
        self.ready()
        from web.owner.i18n import strings
        html = self._get(85)
        bn, en = strings("bn"), strings("en")
        # exactly one language on the page (default panel language)
        self.assertTrue((bn["disk_h"] in html) != (en["disk_h"] in html))
        if bn["disk_h"] in html:
            self.assertIn("৮৫", html)          # Bangla digits
        else:
            self.assertIn("85.0%", html)
            self.assertIn("15.0 GB", html)


class PricingEditorNoUnlimitedTests(OwnerBase):
    def test_no_unlimited_switch(self):
        self.ready()
        html = self.c.get("/owner/pricing").content.decode()
        self.assertNotIn("unlimited_ai", html)
        self.assertIn("disk_alert_pct", html)        # admin-editable threshold
