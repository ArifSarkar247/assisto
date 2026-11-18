"""plans-credits (board row 7): ONE price source.

Every price / credit number the app or the website shows comes from the
server's pricing table (PricingConfig — Owner Admin -> Plans & prices) or the
server's CCTV plan; nothing is typed into a page. These tests:

  * GUARD: no website template carries a typed taka price or a typed
    "N credits" (one known example — the scam checker's "You won 50,000
    BDT" sample message — is the only allowed line);
  * an owner price edit shows in GET /plans AND on the website /pricing;
  * the khata-free page's SMS cost follows action_costs.sms (it used to say
    "1 credit" while the code charged 2);
  * core.plans.PLANS fallback numbers equal the pricing engine's DEFAULTS
    (the old Premium 90 vs 160 / Business 499 vs 999 split can't come back).
"""
import pathlib
import re

from django.core.cache import cache
from django.test import TestCase

from . import billing, plans
from .logic import pricing

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE_DIRS = [ROOT / "web" / "templates", ROOT / "core" / "templates"]

BN = "০-৯"
NZ = "1-9১-৯"           # a non-zero first digit (৳0 is a balance, fine)
PRICE_RE = re.compile(
    "৳\\s?[" + NZ + "]"                        # ৳500 / ৳৫০০
    "|\\bTk\\.?\\s?[1-9]|\\bBDT\\s?[1-9]"            # Tk 500 / BDT 500
    "|[" + NZ + "][0-9" + BN + ",]*\\s?(?:taka|টাকা)"  # 500 taka / ৫০০ টাকা
    "|[" + NZ + "][0-9" + BN + "]*\\s?(?:AI )?(?:credits?\\b|ক্রেডিট)")
# file name -> substrings of the only lines allowed to carry such a number
ALLOWED = {
    "scam.html": ("50,000",),       # a sample scam SMS, not an Assisto price
}


def _hits():
    out = []
    for base in TEMPLATE_DIRS:
        if not base.exists():
            continue
        for f in sorted(base.rglob("*.html")):
            allowed = ALLOWED.get(f.name, ())
            for no, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                # numbers rendered from the context ({{ x }} ক্রেডিট) are fine
                text = re.sub(r"\{\{.*?\}\}|\{%.*?%\}", " ", line)
                if PRICE_RE.search(text) and not any(a in line for a in allowed):
                    out.append(f"{f.relative_to(ROOT)}:{no}: {line.strip()[:120]}")
    return out


class TypedPriceGuardTests(TestCase):
    def test_no_typed_price_in_templates(self):
        hits = _hits()
        self.assertEqual(hits, [], "typed prices in templates — render them from "
                         "PricingConfig / the CCTV plan instead:\n" + "\n".join(hits))

    def test_guard_catches_a_typed_price(self):
        for bad in ("Premium ৳449 a month", "মাসে ৳৪৪৯", "১৬০ ক্রেডিট",
                    "160 credits", "Tk 199", "500 taka"):
            self.assertRegex(bad, PRICE_RE)
        for ok in ("৳0", "{{ price }} credits", "৳{{ p }}"):
            self.assertIsNone(PRICE_RE.search(re.sub(r"\{\{.*?\}\}", " ", ok)), ok)


class OneSourceTests(TestCase):
    def setUp(self):
        cache.clear()

    def _edit(self, fn):
        row = billing.get_config()
        data = row.data
        fn(data)
        row.data = data
        row.save()

    def test_owner_price_edit_shows_in_app_and_website(self):
        def f(d):
            d["plans"]["premium"]["price"] = 333
            d["plans"]["premium"]["credits"] = 77
        self._edit(f)
        rows = {r["id"]: r for r in self.client.get("/api/v1/plans?lang=en").json()}
        self.assertEqual(rows["premium"]["price"], 333)
        self.assertEqual(rows["premium"]["credits"], 77)
        cache.clear()
        bn = self.client.get("/pricing").content.decode()
        self.assertIn("৳৩৩৩", bn)

    def test_khata_free_sms_cost_follows_config(self):
        self._edit(lambda d: d["action_costs"]["sms"].update(credits=7))
        n = billing.cfg()["action_costs"]["sms"]["credits"]
        en = self.client.get("/khata-free?lang=en").content.decode()
        self.assertIn("(%d credits per SMS part)" % n, en)
        bn = self.client.get("/khata-free").content.decode()
        self.assertIn("প্রতি SMS অংশে %s ক্রেডিট" % str(n).translate(
            str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")), bn)
        self.assertNotIn("1 credit per SMS part", en)

    def test_plans_fallback_numbers_equal_pricing_defaults(self):
        d = pricing.DEFAULTS()
        for pid, row in d["plans"].items():
            if pid in plans.PLANS:
                self.assertEqual(plans.PLANS[pid]["price"], row["price"], pid)
                self.assertEqual(plans.PLANS[pid]["credits"], row["credits"], pid)
        for pid in ("annual", "founder", "probashi"):
            self.assertEqual(plans.PLANS[pid]["credits"], d["plans"]["premium"]["credits"], pid)
        self.assertFalse(hasattr(plans, "TOPUP_PACKS"))   # dead second pack list gone
