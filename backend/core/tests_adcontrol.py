"""adcontrol — OWNER FINAL ORDER ADS (10 Nov 03:45), parts A–F, server side.

* the placement registry (core.logic.ad_control) == the app's mirror
  (app/lib/ads/ad_control.dart), key by key, type by type;
* part C: the OFF list is default OFF + safety; part D: the ON list is
  default ON with the owner's type;
* part A: /ads/config sends every placement OFF for Premium AND Plus (and
  child accounts); Free gets the defaults;
* Owner Admin -> Ad control: grouped page, on/off + type saved LIVE into
  PricingConfig.data["ad_control"] and served by /ads/config; a SAFETY
  placement needs the "are you sure?" confirmation; caps clamped; per-day
  impressions / income with an honest "estimate" label; audit rows;
* part F: the ৳49 = 15 credits pack (c15) by the 40 % formula.
"""
import os
import re
from datetime import timedelta

from django.test import SimpleTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from core.logic import ad_control as AC
from core.logic import ads as A
from core.logic import plan_book as BOOK
from core.logic import pricing as P
from core.models import AdPlacementStat, User
from web.tests_o2_owner_admin import OwnerBase

_DART = os.path.join(os.path.dirname(__file__), "..", "..", "app", "lib", "ads", "ad_control.dart")
_SPOT = re.compile(r"AdSpot\('([a-z0-9_]+)', '([a-z]+)', '([a-z_,]+)', (true|false), '([a-z_]+)'"
                   r"(, safety: true)?\)")


def _cfg(plan="free", paid=False, ad_control=None):
    return A.client_config(plan=plan, paid=paid, admob_cfg={}, admob_working=False,
                           flag_rewarded=True, flag_app_open=True,
                           ad_caps=P.DEFAULTS()["ad_rewards"], ad_control=ad_control)


class RegistryTests(SimpleTestCase):
    def test_app_mirror_matches_key_by_key(self):
        with open(_DART, encoding="utf-8") as f:
            dart = {m.group(1): m for m in _SPOT.finditer(f.read())}
        self.assertEqual(set(dart), set(AC.BY_KEY), "app and server registries differ")
        for k, p in AC.BY_KEY.items():
            m = dart[k]
            self.assertEqual(m.group(2), p["group"], k)
            self.assertEqual(tuple(m.group(3).split(",")), p["allowed"], k)
            self.assertEqual(m.group(4) == "true", p["on"], k)
            self.assertEqual(m.group(5), p["type"], k)
            self.assertEqual(bool(m.group(6)), p["safety"], k)

    def test_keys_types_groups(self):
        for p in AC.PLACEMENTS:
            self.assertRegex(p["key"], r"^[a-z][a-z0-9_]{1,39}$")
            self.assertIn(p["type"], p["allowed"], p["key"])
            self.assertTrue(set(p["allowed"]) <= set(AC.TYPES), p["key"])
            self.assertIn(p["group"], AC.GROUP_IDS, p["key"])
            self.assertTrue(p["bn"] and p["en"], p["key"])
        self.assertEqual(len(AC.BY_KEY), len(AC.PLACEMENTS))

    def test_part_c_off_list_is_default_off_and_safety(self):
        for k in AC.OWNER_OFF_LIST:
            self.assertFalse(AC.BY_KEY[k]["on"], k)
            self.assertTrue(AC.BY_KEY[k]["safety"], k)
        for p in AC.PLACEMENTS:
            if p["safety"]:
                self.assertFalse(p["on"], p["key"])

    def test_part_d_on_list(self):
        for k, t in AC.OWNER_ON_LIST.items():
            self.assertTrue(AC.BY_KEY[k]["on"], k)
            self.assertEqual(AC.BY_KEY[k]["type"], t, k)
            self.assertFalse(AC.BY_KEY[k]["safety"], k)

    def test_every_interstitial_moment_is_a_registered_spot(self):
        for m in A.INTERSTITIAL_MOMENTS:
            self.assertIn("interstitial", AC.BY_KEY[m]["allowed"], m)

    def test_normalize_drops_unknown_and_wrong_types(self):
        n = AC.normalize({"placements": {"sos": {"on": True, "type": "rewarded"},
                                         "nope": {"on": True},
                                         "notes_home": {"type": "native"}},
                          "caps": {"interstitial_min_gap_sec": 10, "interstitial_daily_cap": 99,
                                   "list_native_every": 50}})
        self.assertNotIn("nope", n["placements"])
        self.assertEqual(n["placements"]["sos"]["type"], "banner")   # rewarded does not fit
        self.assertEqual(n["placements"]["notes_home"], {"on": True, "type": "native"})
        self.assertEqual(n["caps"]["interstitial_min_gap_sec"], 180)
        self.assertEqual(n["caps"]["interstitial_daily_cap"], 12)
        self.assertEqual(n["caps"]["list_native_every"], 20)

    def test_safety_needs_confirmation(self):
        cur, why = AC.apply_change({}, "sos", on=True)
        self.assertIsNone(cur)
        self.assertEqual(why, "needs_safety_confirm")
        cur, why = AC.apply_change({}, "sos", on=True, confirm_safety=True)
        self.assertIsNone(why)
        self.assertTrue(cur["placements"]["sos"]["on"])
        _, why = AC.apply_change({}, "notes_home", typ="rewarded")
        self.assertEqual(why, "type_not_allowed")
        _, why = AC.apply_change({}, "made_up", on=True)
        self.assertEqual(why, "unknown_placement")

    def test_blocked_categories_and_rating(self):
        self.assertEqual(set(AC.BLOCKED_CATEGORIES),
                         {"dating", "gambling", "alcohol", "adult", "politics"})
        self.assertEqual(AC.MAX_AD_CONTENT_RATING, "T")


class ClientConfigTests(SimpleTestCase):
    def test_free_gets_the_defaults(self):
        c = _cfg()
        ctl = c["control"]["placements"]
        for k, p in AC.BY_KEY.items():
            self.assertEqual(ctl[k]["on"], p["on"], k)
            self.assertEqual(ctl[k]["type"], p["type"], k)
            self.assertEqual(ctl[k]["safety"], p["safety"], k)
        self.assertEqual(c["control"]["caps"]["interstitial_min_gap_sec"], 180)

    def test_part_a_premium_and_plus_never_get_admob(self):
        everything = {"placements": {k: {"on": True} for k in AC.BY_KEY}}
        for plan in ("premium", "plus", "business", "premium_pro"):
            c = _cfg(plan=plan, paid=True, ad_control=everything)
            self.assertFalse(c["ads_enabled"], plan)
            self.assertFalse(any(r["on"] for r in c["control"]["placements"].values()), plan)
            self.assertFalse(any(c["placements"].values()), plan)

    def test_owner_switch_reaches_hero_app_open_and_moments(self):
        off = {"placements": {"home": {"on": False}, "app_open": {"on": False},
                              "photo_after_save": {"on": False}}}
        c = _cfg(ad_control=dict(off))
        self.assertFalse(c["hero_enabled"])
        self.assertFalse(c["placements"]["app_open"])
        self.assertNotIn("photo_after_save", c["interstitial_moments"])
        # a safety moment is never an interstitial moment, even if switched on
        c = _cfg(ad_control={"placements": {"sos": {"on": True, "type": "interstitial"}}})
        self.assertNotIn("sos", c["interstitial_moments"])

    def test_pricing_normalize_keeps_ad_control(self):
        n = P.normalize({"ad_control": {"placements": {"notes_home": {"on": False}}}})
        self.assertFalse(n["ad_control"]["placements"]["notes_home"]["on"])
        self.assertTrue(P.normalize({})["ad_control"]["placements"]["notes_home"]["on"])


class ReportTests(SimpleTestCase):
    def test_estimate_until_google_values_then_real(self):
        rows = [
            {"date": "2026-11-09", "placement": "banner_notes_home", "fmt": "banner",
             "currency": "", "impressions": 1000, "paid_events": 0, "revenue_micros": 0},
            {"date": "2026-11-10", "placement": "native_finance_home", "fmt": "native",
             "currency": "USD", "impressions": 0, "paid_events": 500, "revenue_micros": 1500000},
            {"date": "2026-11-10", "placement": "native_finance_home", "fmt": "native",
             "currency": "", "impressions": 500, "paid_events": 0, "revenue_micros": 0},
        ]
        r = AC.report(rows, {}, ["2026-11-10", "2026-11-09"])
        n = r["notes_home"]
        self.assertEqual(n["impressions"], 1000)
        self.assertEqual(n["income_estimate_bdt"], 20.0)       # 1000 x ৳20 / 1000
        self.assertTrue(n["ecpm_is_estimate"])
        self.assertTrue(n["days"][1]["estimate"])
        f = r["finance_home"]
        self.assertEqual(f["income_real"], 1.5)
        self.assertEqual(f["currency"], "USD")
        self.assertFalse(f["days"][0]["estimate"])
        self.assertEqual(f["days"][0]["ecpm"], 3.0)            # $1.5 / 500 x 1000

    def test_stat_key(self):
        self.assertEqual(AC.stat_key("banner_circle_list"), "circle_list")
        self.assertEqual(AC.stat_key("interstitial_photo_after_save"), "photo_after_save")
        self.assertEqual(AC.stat_key("home_native"), "home")
        self.assertEqual(AC.stat_key("banner_unknown_thing"), "")


class PackTests(SimpleTestCase):
    def test_49_tk_pack_is_15_credits_within_the_40_percent_rule(self):
        self.assertEqual(BOOK.credits_for_price(49), 15)
        self.assertIn({"id": "c15", "price": 49, "valid_months": 12}, BOOK.V2_PACKS)
        # every credit still within the per-credit AI cap at the dearest answer
        self.assertLessEqual(15 * BOOK.MIN_BDT_PER_CREDIT, 49)
        # the big products are unchanged (round to 10)
        self.assertEqual(BOOK.credits_for_price(179), 60)
        self.assertEqual(BOOK.credits_for_price(199), 70)


class AdsConfigViewTests(APITestCase):
    def test_free_user_gets_control_plus_user_none(self):
        u = User.objects.create_user(phone="01700000101", name="Free", password="x")
        self.client.force_authenticate(u)
        j = self.client.get("/api/v1/ads/config").json()
        self.assertTrue(j["control"]["placements"]["notes_home"]["on"])
        self.assertFalse(j["control"]["placements"]["sos"]["on"])
        from core import plans
        from unittest import mock
        with mock.patch.object(plans, "effective_plan", return_value="plus"):
            j = self.client.get("/api/v1/ads/config").json()
        self.assertFalse(j["ads_enabled"])
        self.assertFalse(any(r["on"] for r in j["control"]["placements"].values()))


class OwnerAdControlTests(OwnerBase):
    def setUp(self):
        super().setUp()
        self.ready()

    def _stored(self):
        from core import billing
        return (billing.get_config().data or {}).get("ad_control") or {}

    def test_page_grouped_with_every_placement_and_estimate_label(self):
        AdPlacementStat.objects.create(date=timezone.localdate(), placement="banner_notes_home",
                                       fmt="banner", impressions=40)
        html = self.c.get("/owner/ad-control?lang=en").content.decode()
        from django.utils.html import escape
        for _, _, en in AC.GROUPS:
            self.assertIn(escape(en), html)
        for k in AC.BY_KEY:
            self.assertIn('name="seen_%s"' % k, html)
        self.assertIn("estimate", html)
        self.assertIn("Emergency / safety screen", html)
        d = self.c.get("/owner/ad-control/notes_home?lang=en")
        self.assertEqual(d.status_code, 200)
        self.assertEqual(self.c.get("/owner/ad-control/nope").status_code, 404)

    def _form(self, **over):
        eff = AC.normalize(self._stored())
        d = {}
        for k, row in eff["placements"].items():
            d["seen_" + k] = "1"
            d["t_" + k] = row["type"]
            if row["on"]:
                d["on_" + k] = "1"
        d.update(over)
        return {k: v for k, v in d.items() if v is not None}

    def test_switch_and_type_saved_live_and_audited(self):
        from core.models import OwnerAudit
        r = self.post("/owner/ad-control", self._form(on_notes_home=None, t_all_services="banner"))
        self.assertEqual(r.status_code, 302)
        st = AC.normalize(self._stored())["placements"]
        self.assertFalse(st["notes_home"]["on"])
        self.assertEqual(st["all_services"]["type"], "banner")
        self.assertTrue(OwnerAudit.objects.filter(action="ad_control_placements").exists())
        # live: the app's next /ads/config carries it
        u = User.objects.create_user(phone="01700000102", name="Free", password="x")
        from rest_framework.test import APIClient
        api = APIClient()
        api.force_authenticate(u)
        j = api.get("/api/v1/ads/config").json()
        self.assertFalse(j["control"]["placements"]["notes_home"]["on"])
        self.assertEqual(j["control"]["placements"]["all_services"]["type"], "banner")

    def test_safety_placement_needs_are_you_sure(self):
        r = self.post("/owner/ad-control?lang=en", self._form(on_sos="1"))
        self.assertEqual(r.status_code, 200)
        self.assertIn("emergency or safety screen", r.content.decode())
        self.assertFalse(AC.normalize(self._stored())["placements"]["sos"]["on"])
        r = self.post("/owner/ad-control", self._form(on_sos="1", confirm_safety="sos"))
        self.assertEqual(r.status_code, 302)
        self.assertTrue(AC.normalize(self._stored())["placements"]["sos"]["on"])

    def test_caps_clamped(self):
        r = self.post("/owner/ad-control", {"what": "caps", "interstitial_min_gap_sec": "30",
                                            "interstitial_daily_cap": "4",
                                            "list_native_every": "18", "ecpm_rewarded": "350"})
        self.assertEqual(r.status_code, 302)
        caps = AC.normalize(self._stored())["caps"]
        self.assertEqual(caps["interstitial_min_gap_sec"], 180)
        self.assertEqual(caps["interstitial_daily_cap"], 4)
        self.assertEqual(caps["list_native_every"], 18)
        self.assertEqual(AC.normalize(self._stored())["ecpm_estimate"]["rewarded"], 350.0)


class AppAdsExtraTests(SimpleTestCase):
    def test_partner_lines_validated(self):
        from unittest import mock
        from web import views_legal as V
        raw = ("facebook.com, 1234567890, RESELLER, c3e20eee3f780d68\njunk line\n"
               "appLovin.com, abc123def, DIRECT; google.com, pub-3940256099942544, DIRECT")
        with mock.patch("core.integrations.get", return_value={"app_ads_extra": raw}):
            self.assertEqual(V.app_ads_extra_lines(),
                             ["facebook.com, 1234567890, RESELLER, c3e20eee3f780d68",
                              "appLovin.com, abc123def, DIRECT"])


class PlacementOnTests(APITestCase):
    def test_server_gate_follows_the_owner_switch(self):
        from core import billing
        from core.admob_service import placement_on
        self.assertTrue(placement_on("photo_studio"))
        self.assertFalse(placement_on("made_up"))
        row = billing.get_config()
        data = dict(row.data or {})
        data["ad_control"] = {"placements": {"photo_studio": {"on": False}}}
        row.data = data
        row.save()
        self.assertFalse(placement_on("photo_studio"))
        self.assertTrue(placement_on("lp_unlock"))
