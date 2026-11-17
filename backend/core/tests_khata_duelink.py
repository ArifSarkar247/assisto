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


# ===================================================================== bizai2
@mock.patch("core.push.push_to_user_async", return_value=True)
@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class TagadaCarriesDueLinkTests(APITestCase):
    """bizai2: the due link rides inside every FREE tagada (WhatsApp / own
    SMS, single + bulk) — never on the paid gateway SMS; the page shows how
    to pay with the shop's own number."""

    def setUp(self):
        cache.clear()
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000311",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712345688")
        KhataEntry.objects.create(party=self.party, direction="gave", amount_poisha=75000,
                                  at=timezone.now(), note="PRIVATE")
        self.client.force_authenticate(self.owner)

    def _send(self, channel, lang="bn"):
        return self.client.post("/api/v1/business/khata/tagada/send/%d" % self.party.pk,
                                {"channel": channel}, format="json",
                                HTTP_ACCEPT_LANGUAGE=lang)

    def test_whatsapp_tagada_has_the_working_due_link(self, *_):
        from urllib.parse import unquote
        r = self._send("whatsapp")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["due_link"])
        self.assertIn("/kh/", r.data["message"])
        self.assertIn("হিসাব ও পরিশোধের উপায় দেখুন", r.data["message"])
        text = unquote(r.data["url"].split("?text=", 1)[1])
        self.assertEqual(text, r.data["message"])          # what WhatsApp opens with
        path = text[text.index("/kh/"):].split()[0]
        self.client.force_authenticate(None)
        page = self.client.get(path)
        self.assertEqual(page.status_code, 200)
        self.assertIn("৳৭৫০.০০", page.content.decode())

    def test_own_sms_in_english_links_the_english_page(self, *_):
        r = self._send("own_sms", lang="en")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertIn("See your account and how to pay", r.data["message"])
        self.assertIn("?lang=en", r.data["message"])
        self.assertTrue(r.data["url"].startswith("sms:+8801712345688?body="))

    def test_bulk_rows_share_the_link_but_gateway_text_stays_short(self, *_):
        r = self.client.post("/api/v1/business/khata/tagada/bulk",
                             {"party_ids": [self.party.pk]}, format="json",
                             HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.status_code, 200, r.data)
        row = r.data["reminders"][0]
        self.assertNotIn("/kh/", row["message"])           # the paid SMS text: no link
        self.assertIn("/kh/", row["share_text"])
        self.assertIn("%2Fkh%2F", row["wa_url"])
        self.assertIn("%2Fkh%2F", row["sms_uri"])

    def test_page_shows_how_to_pay_only_while_due(self, *_):
        from core.models import OwnerWallet
        OwnerWallet.objects.create(user=self.owner, business=self.biz, provider="bkash",
                                   merchant_number="01800000001")
        self.client.force_authenticate(None)
        html = self.client.get(KD.link_path(self.party.id)).content.decode()
        self.assertIn("কীভাবে পরিশোধ করবেন", html)
        self.assertIn("bKash", html)
        self.assertIn("01800000001", html)
        self.assertNotIn("PRIVATE", html)
        KhataEntry.objects.create(party=self.party, direction="got", amount_poisha=75000,
                                  at=timezone.now())
        html = self.client.get(KD.link_path(self.party.id)).content.decode()
        self.assertNotIn("কীভাবে পরিশোধ করবেন", html)     # settled: no pay box

    def test_supplier_or_archived_never_gets_a_line(self, *_):
        sup = KhataParty.objects.create(business=self.biz, book="supplier", name="S")
        self.assertEqual(KD.tagada_line(sup, "bn"), "")
        self.party.archived = True
        self.assertEqual(KD.with_link("x", self.party, "bn"), "x")
