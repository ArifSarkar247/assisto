"""qbiz — the customer due link (board row 8): signed + expiring, customer
book only, least data (no notes / phone / other customers), bn digits,
noindex + no-store, archived customer → dead link."""
from datetime import timedelta
from unittest import mock

from django.core.cache import cache
from django.utils import timezone
from rest_framework.test import APITestCase

from core import khata_duelink as KD
from core.models import BusinessProfile, KhataEntry, KhataParty, User

API = "/api/v1/business/khata/parties"


class DueLinkTests(APITestCase):
    def setUp(self):
        cache.clear()
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000211",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712345678")
        self.other = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Selim Other", phone="01712345679")
        self.sup = KhataParty.objects.create(business=self.biz, book="supplier",
                                             name="Supplier Co", phone="01712345670")
        now = timezone.now()
        KhataEntry.objects.create(party=self.party, direction="gave", amount_poisha=50000,
                                  at=now - timedelta(days=2), note="SECRET-REMARK late payer")
        KhataEntry.objects.create(party=self.party, direction="got", amount_poisha=20000, at=now)
        KhataEntry.objects.create(party=self.other, direction="gave", amount_poisha=99900, at=now)
        self.client.force_authenticate(self.owner)

    def _link(self, pk, lang="bn"):
        return self.client.post(f"{API}/{pk}/due-link", {}, format="json",
                                HTTP_ACCEPT_LANGUAGE=lang)

    def test_link_and_page_show_only_this_customer(self):
        r = self._link(self.party.id)
        self.assertEqual(r.status_code, 200, r.content)
        self.assertEqual(r.data["expires_days"], 30)
        self.assertIn("/kh/", r.data["url"])
        self.assertIn(r.data["url"], r.data["text"])
        self.assertIn("৩০", r.data["text"])           # Bangla digits in the bn text
        path = r.data["url"][r.data["url"].index("/kh/"):]
        self.client.force_authenticate(None)            # the customer has no login
        page = self.client.get(path)
        self.assertEqual(page.status_code, 200)
        html = page.content.decode()
        self.assertIn("Karim", html)
        self.assertIn("Rahim Store", html)
        self.assertIn("৳৩০০.০০", html)                 # 500 - 200 due, Bangla digits
        self.assertNotIn("SECRET-REMARK", html)         # notes never leave the shop
        self.assertNotIn("01712345678", html)           # no phone
        self.assertNotIn("Selim Other", html)           # no other customer
        self.assertNotIn("999.00", html)
        self.assertEqual(page["Cache-Control"], "no-store")
        self.assertIn("noindex", page["X-Robots-Tag"])
        en = self.client.get(path + "?lang=en").content.decode()
        self.assertIn("You owe: ৳300.00", en)

    def test_forged_expired_supplier_archived(self):
        self.assertEqual(self._link(self.sup.id).status_code, 404)   # supplier book: never
        self.client.force_authenticate(None)
        tok = KD.token_for(self.party.id)
        self.assertEqual(self.client.get("/kh/" + tok[:-2] + "xx").status_code, 404)
        self.assertEqual(self.client.get("/kh/" + KD.token_for(self.sup.id)).status_code, 404)
        later = timezone.now() + timedelta(days=KD.LINK_DAYS + 1)
        with mock.patch("django.core.signing.time.time", return_value=later.timestamp()):
            self.assertIsNone(KD.parse_token(tok))
        self.assertEqual(KD.parse_token(tok), self.party.id)
        self.party.archived = True
        self.party.save(update_fields=["archived"])
        self.assertEqual(self.client.get("/kh/" + tok).status_code, 404)

    def test_other_business_cannot_make_a_link(self):
        u2 = User.objects.create_user(name="Other", phone="+8801999000212", password="pw123456")
        BusinessProfile.objects.create(user=u2, shop_name="Other Shop")
        self.client.force_authenticate(u2)
        self.assertEqual(self._link(self.party.id).status_code, 404)
