"""tagada2 — send order (Assisto free -> WhatsApp/own SIM free -> Assisto SMS
paid), VERIFIED-only matching, 1 tagada per customer per day across every
channel, Business allowance -> SMS pack deduction, never send without
balance, block / mute, My Dues privacy, shop <-> customer chat, invite to
Assisto, SMS-pack pricing (40 % rule) and Play gating. SMS and push are mocked
at their seams — no real SMS, no real push."""
from datetime import datetime, timedelta
from unittest import mock
from zoneinfo import ZoneInfo

from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core import sms_wallet
from core import tagada_engine as TE
from core.logic import tagada_route as TR
from core.models import (BusinessProfile, KhataChat, KhataEntry, KhataParty,
                         PhoneVerification, ShopPref, SmsLog, TagadaSend, User)
from core.tests_smsotp import alpha_ok, connect, set_cfg

DHAKA = ZoneInfo("Asia/Dhaka")
B = "/api/v1/business"
CUST_PHONE = "+8801712345678"


def noon():
    d = timezone.now().astimezone(DHAKA).date()
    return datetime(d.year, d.month, d.day, 12, 0, tzinfo=DHAKA)


def verified(name, phone):
    u = User.objects.create_user(name=name, phone=phone, password="pw123456")
    PhoneVerification.objects.create(user=u, phone=phone)
    return u


# ===================================================================== pure
class PureRouteTests(TestCase):
    def base(self, **kw):
        d = dict(assisto_user=True, reachable=True, phone_ok=True, sent_today=False,
                 sms_ready=True, parts_needed=1, parts_left=5)
        d.update(kw)
        return d

    def test_free_assisto_first(self):
        self.assertEqual(TR.decide(**self.base())["route"], "assisto")

    def test_share_when_not_an_assisto_user(self):
        d = TR.decide(**self.base(assisto_user=False))
        self.assertEqual(d["route"], "share")
        assisto = [o for o in d["options"] if o["channel"] == "assisto"][0]
        self.assertEqual(assisto["reason"], "not_assisto_user")

    def test_blocked_is_not_reachable_on_every_channel(self):
        d = TR.decide(**self.base(reachable=False))
        self.assertEqual(d["route"], "none")
        self.assertTrue(all(o["reason"] == "not_reachable" for o in d["options"]))

    def test_daily_limit_on_every_channel(self):
        d = TR.decide(**self.base(sent_today=True))
        self.assertTrue(all(o["reason"] == "daily_limit" for o in d["options"]))

    def test_gateway_never_without_balance(self):
        self.assertEqual(TR.refusal("gateway_sms", **self.base(parts_needed=2, parts_left=1)),
                         "no_balance")
        self.assertEqual(TR.refusal("gateway_sms", **self.base(parts_needed=2, parts_left=2)), "")

    def test_quiet_hours_only_stop_what_assisto_sends(self):
        b = self.base(quiet=True)
        self.assertEqual(TR.refusal("assisto", **b), "quiet_hours")
        self.assertEqual(TR.refusal("gateway_sms", **b), "quiet_hours")
        self.assertEqual(TR.refusal("whatsapp", **b), "")
        self.assertEqual(TR.refusal("own_sms", **b), "")

    def test_spend_split_allowance_first(self):
        self.assertEqual(TR.spend_split(3, 2, 10), {"allowance": 2, "pack": 1})
        self.assertEqual(TR.spend_split(3, 5, 0), {"allowance": 3, "pack": 0})
        self.assertIsNone(TR.spend_split(3, 1, 1))

    def test_pack_prices_keep_40_percent_profit(self):
        rows = {r["parts"]: r for r in TR.pack_table(0.35)}
        self.assertEqual((rows[100]["price"], rows[300]["price"], rows[1000]["price"]),
                         (149, 449, 1469))
        for r in rows.values():
            self.assertGreaterEqual(r["profit_pct"], 40.0)
            self.assertEqual(str(r["price"])[-1], "9")
        # exact formula: price/1.15*0.85 - 10 % - cost >= 40 % of price
        m = TR.margin(149, 100, 0.35)
        self.assertAlmostEqual(m["net"], 149 / 1.15 * 0.85, places=1)
        self.assertAlmostEqual(TR.cost_share_max(), 0.85 / 1.15 - 0.5, places=6)
        # a cheaper real cost lowers the prices, the rule still holds
        cheap = {r["parts"]: r["price"] for r in TR.pack_table(0.25)}
        self.assertLess(cheap[100], 149)

    def test_play_round(self):
        self.assertEqual([TR.play_round(x) for x in (146.36, 149, 150, 1463.6, 3)],
                         [149, 149, 159, 1469, 9])


# ===================================================================== wallet
class WalletTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="O", phone="+8801999000111", password="pw")

    def business_plan(self):
        User.objects.filter(pk=self.owner.pk).update(
            plan="business", plan_until=timezone.now() + timedelta(days=20))
        self.owner.refresh_from_db()

    def test_no_allowance_without_a_paid_business_plan(self):
        self.assertEqual(sms_wallet.state(self.owner)["allowance_total"], 0)
        User.objects.filter(pk=self.owner.pk).update(
            plan="premium", plan_until=timezone.now() + timedelta(days=20))
        self.owner.refresh_from_db()
        self.assertEqual(sms_wallet.state(self.owner)["allowance_total"], 0)

    def test_allowance_first_then_pack_and_never_below_zero(self):
        self.business_plan()
        sms_wallet.grant_pack(self.owner, "smspack_100", 5, key="k1")
        st = sms_wallet.state(self.owner)
        self.assertEqual((st["allowance_total"], st["allowance_left"], st["pack_left"]),
                         (30, 30, 5))
        res = sms_wallet.reserve(self.owner, 32, ref="a")
        self.assertEqual((res["allowance"], res["pack"]), (30, 2))
        st = sms_wallet.state(self.owner)
        self.assertEqual((st["allowance_left"], st["pack_left"], st["parts_left"]), (0, 3, 3))
        self.assertIsNone(sms_wallet.reserve(self.owner, 4, ref="b"))   # short: nothing taken
        self.assertEqual(sms_wallet.state(self.owner)["pack_left"], 3)
        sms_wallet.release(self.owner, res)
        st = sms_wallet.state(self.owner)
        self.assertEqual((st["allowance_left"], st["pack_left"]), (30, 5))

    def test_allowance_resets_every_dhaka_month(self):
        self.business_plan()
        sms_wallet.reserve(self.owner, 10, now=noon())
        next_month = noon() + timedelta(days=32)
        self.assertEqual(sms_wallet.state(self.owner, next_month)["allowance_left"], 30)

    def test_owner_sets_allowance_and_low_line(self):
        self.business_plan()
        set_cfg("sms", business_monthly_parts=5, low_balance_parts=5)
        st = sms_wallet.state(self.owner)
        self.assertEqual(st["allowance_total"], 5)
        self.assertTrue(st["low"])

    def test_grant_and_revoke_are_once_per_key(self):
        self.assertEqual(sms_wallet.grant_pack(self.owner, "smspack_300", key="g"), 300)
        self.assertEqual(sms_wallet.grant_pack(self.owner, "smspack_300", key="g"), 0)
        sms_wallet.reserve(self.owner, 250)
        self.assertEqual(sms_wallet.revoke_pack(self.owner, 300, key="r"), 50)  # only unspent
        self.assertEqual(sms_wallet.revoke_pack(self.owner, 300, key="r"), 0)
        self.assertEqual(sms_wallet.state(self.owner)["pack_left"], 0)


# ===================================================================== catalog / Play
class PackCatalogTests(TestCase):
    def test_sms_packs_not_sold_until_owner_and_play_both_say_yes(self):
        from core.payments import catalog, play_verify
        self.assertIn("smspack_100", catalog.all_skus())
        self.assertEqual(catalog.base_price("smspack_100"), 149)
        self.assertEqual(catalog.play_product("smspack_300"), ("assisto_sms_300", ""))
        self.assertEqual(catalog.sku_for_play("assisto_sms_1000"), "smspack_1000")
        self.assertEqual(catalog.sku_for_play("assisto_sms_7"), "")
        self.assertEqual(catalog.describe("smspack_100")["sms_parts"], 100)
        self.assertIsNone(catalog.price("smspack_100", "play"))       # default: off
        set_cfg("sms", packs_on_sale=1)
        self.assertIsNone(catalog.price("smspack_100", "play"))       # Play not verified
        play_verify.check_all(api=lambda m, p: {"status": "active"} if "inappproducts" in p
                              else {"basePlans": []})
        self.assertEqual(catalog.price("smspack_100", "play"), 149)
        self.assertIsNone(catalog.price("smspack_100", "gateway"))    # Play only
        self.assertIn("smspack_100", [r["sku"] for r in play_verify.status_rows()])

    def test_real_cost_reprices(self):
        from core.payments import catalog
        set_cfg("sms", default_cost_per_segment_bdt=0.25)
        self.assertEqual(catalog.base_price("smspack_100"), 109)

    def test_play_sync_grants_sms_parts_not_credits(self):
        from core.payments import play
        u = User.objects.create_user(name="O", phone="+8801999000112", password="pw")
        js = {"purchaseState": 0, "consumptionState": 1, "orderId": "GPA.T-1",
              "obfuscatedExternalAccountId": play.account_id(u)}
        with mock.patch.object(play, "get_product", return_value=js), \
                mock.patch.object(play, "_real_price", return_value=(149, "BDT", "catalog")), \
                mock.patch.object(play, "_charge_once"):
            r = play.sync_pack("tok-1", "assisto_sms_100", u)
            again = play.sync_pack("tok-1", "assisto_sms_100", u)
        self.assertTrue(r["ok"])
        self.assertEqual(r["granted"], 100)
        self.assertEqual(again["granted"], 0)                       # idempotent
        u.refresh_from_db()
        self.assertEqual(u.ai_credits, 0)
        self.assertEqual(sms_wallet.state(u)["pack_left"], 100)


# ===================================================================== shop side
@mock.patch("core.push.push_to_user_async", return_value=True)
@mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False)
class SendOrderTests(APITestCase):
    def setUp(self):
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000111",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712-345678",
                                               note="PRIVATE shop note")
        KhataEntry.objects.create(party=self.party, direction="gave", amount_poisha=50000,
                                  note="চাল ৫ কেজি", at=timezone.now())
        self.client.force_authenticate(self.owner)

    def send(self, channel, **kw):
        return self.client.post("%s/khata/tagada/send/%d" % (B, self.party.pk),
                                {"channel": channel, **kw}, format="json",
                                HTTP_ACCEPT_LANGUAGE="bn")

    def bulk(self):
        return self.client.post(B + "/khata/tagada/bulk", {"party_ids": [self.party.pk]},
                                format="json")

    def test_phone_canon_is_kept(self, *_):
        self.assertEqual(self.party.phone_canon, CUST_PHONE)
        self.party.phone = "০১৮১১১১১১১১"
        self.party.save(update_fields=["phone"])
        self.party.refresh_from_db()
        self.assertEqual(self.party.phone_canon, "+8801811111111")

    def test_unverified_account_is_never_matched(self, *_):
        User.objects.create_user(name="Fake", phone=CUST_PHONE, password="pw")
        from core import billing
        self.assertTrue(billing.flag_on("contacts_match_unverified", True))  # test-build flag ON
        row = self.bulk().data["reminders"][0]
        self.assertFalse(row["assisto_user"])
        self.assertEqual(row["route"], "share")
        r = self.send("assisto")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "not_assisto_user"))

    def test_verified_customer_gets_it_free_in_assisto(self, _q, push):
        cust = verified("Karim", CUST_PHONE)
        row = self.bulk().data["reminders"][0]
        self.assertEqual((row["assisto_user"], row["route"], row["invite_status"]),
                         (True, "assisto", "joined"))
        r = self.send("assisto")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertTrue(r.data["free"])
        m = KhataChat.objects.get()
        self.assertEqual((m.customer, m.sender, m.kind), (cust, "shop", "tagada"))
        push.assert_called_once()
        self.assertEqual(push.call_args.args[1], "dues")
        self.assertEqual(push.call_args.kwargs["data"]["route"], "my_dues")
        self.assertFalse(SmsLog.objects.exists())                   # no SMS, no cost

    def test_one_tagada_per_customer_per_day_across_channels(self, *_):
        verified("Karim", CUST_PHONE)
        r = self.send("whatsapp")
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.data["url"].startswith("https://wa.me/8801712345678"))
        for ch in ("whatsapp", "own_sms", "assisto", "gateway_sms"):
            r = self.send(ch)
            self.assertEqual((r.status_code, r.data["reason"]), (429, "daily_limit"), ch)
        row = self.bulk().data["reminders"][0]
        self.assertEqual((row["sent_today"], row["sent_today_channel"]), (True, "whatsapp"))
        self.assertEqual(TagadaSend.objects.count(), 1)

    def test_same_number_twice_in_the_book_still_one_a_day(self, *_):
        dup = KhataParty.objects.create(business=self.biz, book="customer", name="Karim 2",
                                        phone="+8801712345678")
        KhataEntry.objects.create(party=dup, direction="gave", amount_poisha=100,
                                  at=timezone.now())
        self.assertEqual(self.send("own_sms").status_code, 200)
        r = self.client.post("%s/khata/tagada/send/%d" % (B, dup.pk),
                             {"channel": "whatsapp"}, format="json")
        self.assertEqual(r.data["reason"], "daily_limit")

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_gateway_uses_allowance_then_pack_and_never_without_balance(self, http, *_):
        r = self.send("gateway_sms")
        self.assertEqual((r.status_code, r.data["reason"]), (402, "no_balance"))
        self.assertIn("sms", r.data)
        self.assertEqual(http.call_count, 0)
        self.assertFalse(TagadaSend.objects.exists())               # slot not burnt
        User.objects.filter(pk=self.owner.pk).update(
            plan="business", plan_until=timezone.now() + timedelta(days=20))
        self.owner.refresh_from_db()
        self.client.force_authenticate(self.owner)
        r = self.send("gateway_sms")
        self.assertEqual(r.status_code, 200, r.data)
        self.assertFalse(r.data["free"])
        self.assertEqual((r.data["from_allowance"], r.data["from_pack"]), (r.data["parts"], 0))
        self.assertEqual(r.data["sms"]["allowance_left"], 30 - r.data["parts"])
        self.assertEqual(SmsLog.objects.get().credits, 0)            # no AI credits

    def test_staff_cannot_spend_sms_parts(self, *_):
        from core.models import BusinessStaff
        staff = User.objects.create_user(name="S", phone="+8801999000222", password="pw")
        BusinessStaff.objects.create(business=self.biz, member=staff, role="staff", active=True)
        self.client.force_authenticate(staff)
        r = self.client.post("%s/khata/tagada/send/%d?business=%d" % (B, self.party.pk,
                                                                      self.biz.pk),
                             {"channel": "gateway_sms", "business": self.biz.pk}, format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (403, "owner_only"))
        r = self.client.post("%s/khata/tagada/send/%d" % (B, self.party.pk),
                             {"channel": "whatsapp", "business": self.biz.pk}, format="json")
        self.assertEqual(r.status_code, 200)                         # free routes: fine

    def test_block_means_not_reachable_everywhere(self, _q, push):
        cust = verified("Karim", CUST_PHONE)
        ShopPref.objects.create(user=cust, business=self.biz, blocked=True)
        for ch in ("assisto", "whatsapp", "own_sms", "gateway_sms"):
            r = self.send(ch)
            self.assertEqual((r.status_code, r.data["reason"]), (409, "not_reachable"), ch)
            self.assertNotIn("ব্লক", r.data["detail"])
        r = self.client.post("%s/khata/parties/%d/chat" % (B, self.party.pk),
                             {"text": "hi"}, format="json")
        self.assertEqual(r.data["reason"], "not_reachable")
        self.assertFalse(self.bulk().data["reminders"][0]["reachable"])
        push.assert_not_called()

    def test_mute_keeps_the_message_but_no_push(self, _q, push):
        cust = verified("Karim", CUST_PHONE)
        ShopPref.objects.create(user=cust, business=self.biz, muted=True)
        r = self.send("assisto")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(r.data["pushed"])
        push.assert_not_called()
        self.assertEqual(KhataChat.objects.count(), 1)

    def test_quiet_hours_refuse_assisto_but_not_whatsapp(self, q, _p):
        q.return_value = True
        verified("Karim", CUST_PHONE)
        self.assertEqual(self.send("assisto").data["reason"], "quiet_hours")
        self.assertEqual(self.bulk().data["reminders"][0]["route"], "share")
        self.assertEqual(self.send("whatsapp").status_code, 200)

    def test_stop_opt_out_refuses_assisto(self, *_):
        verified("Karim", CUST_PHONE)
        from core.logic import msg_guard as MG
        from core.logic.business_selling import normalize_phone
        MG.record_opt_out(self.biz.pk, normalize_phone(CUST_PHONE))
        self.assertEqual(self.send("assisto").data["reason"], "opted_out")

    def test_no_due_and_bad_channel(self, *_):
        self.assertEqual(self.send("fax").data["reason"], "bad_channel")
        KhataEntry.objects.create(party=self.party, direction="got", amount_poisha=50000,
                                  at=timezone.now())
        self.assertEqual(self.send("whatsapp").data["reason"], "no_due")

    def test_invite_then_joined(self, *_):
        url = "%s/khata/parties/%d/invite" % (B, self.party.pk)
        self.assertEqual(self.client.get(url).data["status"], "none")
        r = self.client.post(url, {}, format="json", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertEqual(r.data["status"], "invited")
        self.assertIn("/i/" + r.data["code"], r.data["link"])
        self.assertIn("বিনা খরচে", r.data["share_text"])
        self.assertTrue(r.data["wa_url"].startswith("https://wa.me/"))
        self.assertEqual(self.client.get(url).data["status"], "invited")
        verified("Karim", CUST_PHONE)
        self.assertEqual(self.client.post(url, {}, format="json").data["status"], "joined")
        self.assertEqual(self.bulk().data["reminders"][0]["route"], "assisto")

    def test_sms_balance_screen(self, *_):
        r = self.client.get(B + "/sms/balance")
        self.assertEqual(r.status_code, 200)
        self.assertEqual([p["parts"] for p in r.data["packs"]], [100, 300, 1000])
        self.assertFalse(r.data["packs_on_sale"])
        self.assertEqual(r.data["parts_left"], 0)
        self.assertTrue(r.data["low"])


# ===================================================================== customer side
@mock.patch("core.push.push_to_user_async", return_value=True)
class MyDuesTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000111",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712345678",
                                               note="PRIVATE shop note")
        KhataEntry.objects.create(party=self.party, direction="gave", amount_poisha=50000,
                                  note="চাল ৫ কেজি", at=timezone.now())
        KhataEntry.objects.create(party=self.party, direction="got", amount_poisha=10000,
                                  at=timezone.now())
        # same number in ANOTHER shop's SUPPLIER book + another customer here
        other = BusinessProfile.objects.create(
            user=User.objects.create_user(name="X", phone="+8801999000333", password="pw"),
            shop_name="Other")
        sup = KhataParty.objects.create(business=other, book="supplier", name="Karim",
                                        phone="01712345678")
        KhataEntry.objects.create(party=sup, direction="got", amount_poisha=999900,
                                  at=timezone.now())
        stranger = KhataParty.objects.create(business=self.biz, book="customer", name="Z",
                                             phone="01811111111")
        KhataEntry.objects.create(party=stranger, direction="gave", amount_poisha=777700,
                                  at=timezone.now())
        self.cust = verified("Karim", CUST_PHONE)
        self.client.force_authenticate(self.cust)

    def test_lists_only_what_shops_recorded_for_my_verified_number(self, _p):
        r = self.client.get("/api/v1/me/dues", HTTP_ACCEPT_LANGUAGE="bn")
        self.assertTrue(r.data["verified"])
        self.assertEqual(len(r.data["shops"]), 1)                 # supplier book never shown
        s = r.data["shops"][0]
        self.assertEqual((s["shop_name"], s["balance_poisha"], s["owes"]),
                         ("Rahim Store", 40000, True))
        self.assertEqual(r.data["total_display"]["bn"], "৳৪০০.০০")
        d = self.client.get("/api/v1/me/dues/%d" % self.biz.pk).data
        self.assertEqual(sorted(e["kind"] for e in d["entries"]), ["due", "paid"])
        self.assertIn("চাল ৫ কেজি", [e["note"] for e in d["entries"]])   # line notes: yes
        body = str(d)
        self.assertNotIn("PRIVATE", body)                           # party note never
        self.assertNotIn("7777", body)                              # other customers never
        self.assertNotIn("9999", body)

    def test_unverified_sees_nothing(self, _p):
        u = User.objects.create_user(name="Imp", phone="+8801712345679", password="pw")
        KhataParty.objects.filter(pk=self.party.pk).update(phone="01712345679",
                                                           phone_canon="+8801712345679")
        self.client.force_authenticate(u)
        r = self.client.get("/api/v1/me/dues")
        self.assertEqual((r.data["verified"], r.data["shops"]), (False, []))
        self.assertEqual(self.client.get("/api/v1/me/dues/%d" % self.biz.pk).status_code, 403)

    def test_a_shop_that_never_recorded_me_is_404(self, _p):
        other = BusinessProfile.objects.create(
            user=User.objects.create_user(name="Y", phone="+8801999000444", password="pw"),
            shop_name="Second")
        self.assertEqual(self.client.get("/api/v1/me/dues/%d" % other.pk).status_code, 404)
        self.assertEqual(self.client.post("/api/v1/me/dues/%d/prefs" % other.pk,
                                          {"blocked": True}, format="json").status_code, 404)

    def test_pay_methods_from_shop_wallet_and_last_reminder(self, _p):
        from core.models import OwnerWallet
        OwnerWallet.objects.create(user=self.owner, business=self.biz, provider="bkash",
                                   merchant_number="01999000111")
        TagadaSend.objects.create(business=self.biz, party=self.party,
                                  phone_key=CUST_PHONE, day=timezone.now().date(),
                                  channel="whatsapp",
                                  pay_hint={"method": "Nagad", "number": "০১৮৮৮৮৮৮৮৮৮"})
        m = self.client.get("/api/v1/me/dues/%d" % self.biz.pk).data["pay"]["methods"]
        self.assertEqual(m, [{"provider": "bkash", "number": "01999000111", "kind": "merchant"},
                             {"provider": "nagad", "number": "01888888888", "kind": "personal"}])

    def test_chat_both_ways_unread_and_block(self, push):
        self.client.force_authenticate(self.owner)
        r = self.client.post("%s/khata/parties/%d/chat" % (B, self.party.pk),
                             {"text": "ভাই, বাকিটা দেবেন?"}, format="json")
        self.assertEqual(r.status_code, 201, r.data)
        self.client.force_authenticate(self.cust)
        self.assertEqual(self.client.get("/api/v1/me/dues").data["shops"][0]["unread"], 1)
        r = self.client.get("/api/v1/me/dues/%d/chat" % self.biz.pk)
        self.assertEqual([m["from"] for m in r.data["messages"]], ["shop"])
        self.assertEqual(self.client.get("/api/v1/me/dues").data["shops"][0]["unread"], 0)
        r = self.client.post("/api/v1/me/dues/%d/chat" % self.biz.pk, {"text": "কাল দেব"},
                             format="json")
        self.assertEqual(r.status_code, 201)
        self.assertEqual(push.call_args.args[0], self.owner)        # the shop is told
        self.assertEqual(push.call_args.kwargs["data"]["open"], "chat")
        r = self.client.post("/api/v1/me/dues/%d/prefs" % self.biz.pk, {"blocked": True},
                             format="json")
        self.assertEqual(r.data, {"muted": False, "blocked": True})
        r = self.client.post("/api/v1/me/dues/%d/chat" % self.biz.pk, {"text": "x"},
                             format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (409, "blocked"))
        self.client.force_authenticate(self.owner)
        r = self.client.get("%s/khata/parties/%d/chat" % (B, self.party.pk))
        self.assertEqual([m["from"] for m in r.data["messages"]], ["shop", "customer"])
        self.assertFalse(r.data["reachable"])

    def test_empty_text_and_rate_limit(self, _p):
        r = self.client.post("/api/v1/me/dues/%d/chat" % self.biz.pk, {"text": "  "},
                             format="json")
        self.assertEqual(r.data["reason"], "empty")
        with mock.patch.object(TE, "CUSTOMER_MSGS_PER_HOUR", 1):
            self.client.post("/api/v1/me/dues/%d/chat" % self.biz.pk, {"text": "a"},
                             format="json")
            r = self.client.post("/api/v1/me/dues/%d/chat" % self.biz.pk, {"text": "b"},
                                 format="json")
        self.assertEqual((r.status_code, r.data["reason"]), (429, "rate_limited"))

    def test_owner_never_sees_own_shop_as_dues(self, _p):
        verified_owner_phone = self.owner.phone
        PhoneVerification.objects.create(user=self.owner, phone=verified_owner_phone)
        KhataParty.objects.create(business=self.biz, book="customer", name="me",
                                  phone=verified_owner_phone)
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.get("/api/v1/me/dues").data["shops"], [])


@mock.patch("core.push.push_to_user", return_value=1)
class CronSendOrderTests(TestCase):
    def setUp(self):
        connect("sms_alpha", {"api_key": "AK", "cost_per_segment_bdt": "0.30"})
        self.owner = User.objects.create_user(name="Owner", phone="+8801999000111",
                                              password="pw123456")
        self.biz = BusinessProfile.objects.create(user=self.owner, shop_name="Rahim Store")
        self.party = KhataParty.objects.create(business=self.biz, book="customer",
                                               name="Karim", phone="01712345678")
        KhataEntry.objects.create(party=self.party, direction="gave", amount_poisha=50000,
                                  at=timezone.now())

    @mock.patch("core.sms_gateway._http", side_effect=alpha_ok)
    def test_sms_schedule_goes_free_in_assisto_for_a_verified_customer(self, http, _push):
        from core import tagada_cron
        from core.models import TagadaSchedule
        verified("Karim", CUST_PHONE)
        s = TagadaSchedule.objects.create(party=self.party, next_at=noon() - timedelta(minutes=1),
                                          interval_days=3, channel="sms")
        with mock.patch("core.logic.msg_guard.in_quiet_hours", return_value=False):
            st = tagada_cron.sweep(now=noon())
        self.assertEqual(st["assisto_sent"], 1)
        self.assertEqual(http.call_count, 0)                        # no paid SMS
        s.refresh_from_db()
        self.assertEqual((s.last_result, s.awaiting_owner), ("assisto_sent", False))
        self.assertEqual(KhataChat.objects.get().kind, "tagada")
