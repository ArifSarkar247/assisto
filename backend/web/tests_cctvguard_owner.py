"""cctvguard: Owner Admin -> CCTV traffic (numbers only, bn/en)."""
from django.utils import timezone

from core.logic import cctv_traffic as T
from core.models import ShopCamera, ShopSite, User
from web.tests_o2_owner_admin import OwnerBase


class CctvTrafficPageTests(OwnerBase):
    def test_page_lists_accounts_heaviest_first(self):
        from core import cctv_traffic as CT
        a = User.objects.create_user(name="Dokan A", phone="01710007101", password="pw")
        b = User.objects.create_user(name="Dokan B", phone="01710007102", password="pw")
        for u, mb in ((a, 3), (b, 40)):
            site = ShopSite.objects.create(owner=u, name="S")
            cam = ShopCamera.objects.create(site=site, name="C", kind="shopbox")

            def fn(doc, cam=cam, mb=mb):
                doc, _, _ = T.add_live(doc, cam.pk, 1, mb * 10 ** 6, 10 ** 6, "relay")
                return T.add_vendor(doc, cam.pk, 120)
            CT._update(u.pk, timezone.now(), fn)
        self.ready()
        r = self.c.get("/owner/cctv-traffic")
        self.assertEqual(r.status_code, 200)
        html = r.content.decode()
        self.assertIn("সিসিটিভি ট্রাফিক", html)
        self.assertIn('id="cctv-traffic"', html)
        self.assertLess(html.index("Dokan B"), html.index("Dokan A"))
        self.assertIn("গোনা হচ্ছে", html)          # not enforced until owner yes
        r = self.c.get("/owner/cctv-traffic?lang=en&month=1999-01")
        self.assertContains(r, "No live traffic this month.")

    def test_needs_login(self):
        r = self.c.get("/owner/cctv-traffic")
        self.assertIn(r.status_code, (302, 403))
