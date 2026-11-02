"""finish1 (2 Nov): blood donor + My Circle finishing.

  * blood bank import tool: an owner-supplied OFFICIAL CSV with a named,
    linked, dated source -> the app list (district / text filters, nearest
    first); every bad row is reported and NOTHING is written; --clear goes
    back to the honest "source pending"; an unsourced file is never shown;
  * push-area honesty: the donor's own view says when the details were last
    checked and asks "still there?" after 180 days; "yes" is one tap;
  * group link previews: a per-member sealed preview (lp_ciphertext +
    lp_nonce) is accepted, size-capped, text-only, never plaintext.

Test rows below are TEST fixtures only (the product ships no entries)."""
import io
import os
import shutil
import tempfile
from datetime import timedelta
from unittest import mock

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APIClient

from core import blood_banks as BB
from core import blood_panel as BP
from core.logic import circle_groups as G
from core.models import BloodDonor, BloodEvent, User

_TMP = tempfile.mkdtemp(prefix="finish1-banks-")
STORE = os.path.join(_TMP, "blood_banks.json")

CSV_OK = (
    "name,district,phone,address,area,kind,hours,lat,lng\n"
    "Test Unit A,Dhaka,01700-000001,Test road 1,Shahbag,govt,24 hours,23.74,90.39\n"
    "Test Unit B,Chittagong,০১৭০০০০০০০২,,Panchlaish,red_crescent,,,\n"
    "Test Unit C,রাজশাহী,,Test road 3,,hospital,,,\n"
    "Test Unit A,dhaka,01700-000009,dup,,,,,\n"
)
CSV_BAD = (
    "name,district,phone,address\n"
    "Good Unit,Dhaka,01700000001,\n"
    ",Dhaka,01700000002,\n"
    "Bad District,Atlantis,01700000003,\n"
    "No Contact,Sylhet,,\n"
    "Bad Phone,Khulna,call us,\n"
)
SRC = dict(source_name="Test official list", source_url="https://example.gov.bd/blood",
           source_date="2026-10-01")


def _write(text):
    fd, p = tempfile.mkstemp(dir=_TMP, suffix=".csv")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    return p


@override_settings(BLOOD_BANKS_FILE=STORE)
class BankImport(TestCase):
    @classmethod
    def tearDownClass(cls):
        super().tearDownClass()
        shutil.rmtree(_TMP, ignore_errors=True)

    def setUp(self):
        BB.clear()
        p = mock.patch.object(BP, "flag_on", lambda u: True)
        p.start()
        self.addCleanup(p.stop)
        self.u = User.objects.create_user(name="Seeker", phone="01819000001", password="pw-123456")
        self.c = APIClient()
        self.c.force_authenticate(self.u)
        self.c.credentials(HTTP_ACCEPT_LANGUAGE="en")

    def banks(self, **q):
        return self.c.get("/api/v1/blood-panel/banks", q).json()

    def test_parse_good_rows_aliases_bangla_and_dedupe(self):
        rows, errs = BB.parse_csv(CSV_OK)
        self.assertEqual(errs, [])
        self.assertEqual([r["district"] for r in rows], ["dhaka", "chattogram", "rajshahi"])
        self.assertEqual(rows[1]["phone"], "01700000002")      # Bangla digits read
        self.assertEqual(rows[0]["lat"], 23.74)
        self.assertEqual(BB.district_code("Cox's Bazar"), "coxsbazar")
        self.assertEqual(BB.district_code("Comilla District"), "cumilla")

    def test_every_bad_row_named_and_nothing_written(self):
        rows, errs = BB.parse_csv(CSV_BAD)
        self.assertEqual(len(rows), 1)
        joined = "\n".join(errs)
        for n in ("row 3", "row 4", "row 5", "row 6"):
            self.assertIn(n, joined)
        with self.assertRaises(CommandError):
            call_command("import_blood_banks", _write(CSV_BAD), stdout=io.StringIO(),
                         stderr=io.StringIO(), **SRC)
        self.assertFalse(os.path.exists(STORE))
        self.assertTrue(self.banks()["source_pending"])
        _r, errs = BB.parse_csv("title,place\nx,y\n")
        self.assertIn("missing column", errs[0])

    def test_source_is_mandatory(self):
        for bad in (dict(SRC, source_name=""), dict(SRC, source_url="example.gov.bd"),
                    dict(SRC, source_date=(timezone.localdate() + timedelta(days=3)).isoformat())):
            with self.assertRaises(CommandError):
                call_command("import_blood_banks", _write(CSV_OK), stdout=io.StringIO(),
                             stderr=io.StringIO(), **bad)
        self.assertFalse(os.path.exists(STORE))

    def test_dry_run_then_import_then_clear(self):
        out = io.StringIO()
        call_command("import_blood_banks", _write(CSV_OK), dry_run=True, stdout=out, **SRC)
        self.assertIn("3 banks in 3 districts", out.getvalue())
        self.assertFalse(os.path.exists(STORE))
        call_command("import_blood_banks", _write(CSV_OK), stdout=io.StringIO(), **SRC)
        r = self.banks()
        self.assertFalse(r["source_pending"])
        self.assertEqual(r["source"]["name"], "Test official list")
        self.assertEqual(r["source"]["date"], "2026-10-01")
        self.assertEqual(r["total"], 3)
        self.assertEqual({d["code"] for d in r["districts"]}, {"dhaka", "chattogram", "rajshahi"})
        self.assertEqual([b["name"] for b in self.banks(district="chattogram")["banks"]],
                         ["Test Unit B"])
        self.assertEqual([b["name"] for b in self.banks(q="panchlaish")["banks"]],
                         ["Test Unit B"])
        near = self.banks(lat="23.75", lng="90.39")["banks"]
        self.assertEqual(near[0]["name"], "Test Unit A")          # nearest first
        self.assertFalse(near[0]["km_from_district"])
        self.assertTrue(near[1]["km_from_district"])              # no point: district centre
        call_command("import_blood_banks", clear=True, stdout=io.StringIO())
        self.assertTrue(self.banks()["source_pending"])
        self.assertEqual(self.banks()["banks"], [])

    def test_unsourced_file_is_never_shown(self):
        with open(STORE, "w", encoding="utf-8") as f:
            f.write('{"source": null, "banks": [{"name": "X", "district": "dhaka"}]}')
        BB._CACHE.clear()
        r = self.banks()
        self.assertTrue(r["source_pending"])
        self.assertEqual(r["banks"], [])


class DonorAreaHonesty(TestCase):
    def setUp(self):
        p = mock.patch.object(BP, "flag_on", lambda u: True)
        p.start()
        self.addCleanup(p.stop)
        self.u = User.objects.create_user(name="Donor", phone="01819000002", password="pw-123456")

    def test_stale_after_180_days_and_one_tap_keeps_it(self):
        d = BloodDonor.objects.create(user=self.u, enabled=True, consent_at=timezone.now(),
                                      consent_version=99, blood_group="O+", district="dhaka")
        j = BP.donor_json(d, "en")
        self.assertFalse(j["details_stale"])
        BloodDonor.objects.filter(pk=d.pk).update(
            updated_at=timezone.now() - timedelta(days=BP.DETAILS_STALE_DAYS + 1))
        d.refresh_from_db()
        self.assertTrue(BP.donor_json(d, "en")["details_stale"])
        d2, err, _f = BP.save_donor(self.u, {"area_confirmed": True})
        self.assertIsNone(err)
        self.assertFalse(BP.donor_json(d2, "en")["details_stale"])
        self.assertEqual(d2.district, "dhaka")                     # nothing else changed
        self.assertTrue(BloodEvent.objects.filter(kind="area_confirmed").exists())


class GroupLinkPreviewEnvelope(TestCase):
    def env(self, **lp):
        sub = {"ciphertext": "Y3Q=", "nonce": "bm9uY2U=", **lp}
        return {"group_id": 1, "sender_id": 1, "recipient_ids": [2], "content_type": "text",
                "ciphertext": "Y3Q=", "nonce": "bm9uY2U=", "per_recipient": {"2": sub},
                "sender_key_id": "k", "scheme": "x25519-xsalsa20poly1305-v1"}

    def test_sealed_preview_accepted_and_capped(self):
        ok, why = G.validate_group_envelope(self.env(lp_ciphertext="bHA=", lp_nonce="bg=="))
        self.assertTrue(ok, why)
        ok, _ = G.validate_group_envelope(self.env(lp_ciphertext="bHA="))
        self.assertFalse(ok)                                        # nonce required
        ok, _ = G.validate_group_envelope(
            self.env(lp_ciphertext="A" * (G.GROUP_LP_CT_MAX + 1), lp_nonce="bg=="))
        self.assertFalse(ok)
        e = self.env(lp_ciphertext="bHA=", lp_nonce="bg==")
        e["content_type"] = "location"
        self.assertFalse(G.validate_group_envelope(e)[0])
        e = self.env(lp_ciphertext="bHA=", lp_nonce="bg==", text="https://x.y")
        self.assertFalse(G.validate_group_envelope(e)[0])            # never plaintext


# --------------------------------------------------------------------------
# Owner FINAL blood spec (2 Nov 17:25): never hide a donor; sort; exact days;
# the list moves by itself daily; green + push when the interval ends; header
# counts; privacy; both sides agree on the thank-you; people helped.
from core.tests_blood import MIRPUR, NEAR, Base as BloodBase  # noqa: E402
from core.logic import blood_rules as BR  # noqa: E402
from core.models import BloodRequest, BloodRecipient  # noqa: E402


class OwnerFinalList(BloodBase):
    def rows(self, **q):
        c = self.api(self.req_user)
        p = {"group": "A+", "lat": MIRPUR[0], "lng": MIRPUR[1]}
        p.update(q)
        r = c.get("/api/v1/blood-panel/donors", p)
        self.assertEqual(r.status_code, 200, r.content)
        return r.json()

    def test_sort_status_days_and_counts(self):
        _a, far_ok = self.donor("Far", "A+", NEAR)            # available, ~3 km
        _b, near_ok = self.donor("Near", "A+", MIRPUR)        # available, 0 km
        _c, w30 = self.donor("Wait", "A+", MIRPUR, last_days=90)    # 30 days left
        _d, w5 = self.donor("Soon", "A+", NEAR, last_days=115)      # 5 days left
        _e, today = self.donor("Today", "A+", MIRPUR, last_days=None)
        today.last_donation = timezone.localdate()
        today.save()
        _f, paused = self.donor("Paused", "A+", MIRPUR)
        paused.available = False
        paused.save()
        j = self.rows()
        ids = [x["id"] for x in j["donors"]]
        self.assertEqual(ids, [near_ok.id, far_ok.id, w5.id, w30.id, today.id, paused.id])
        by = {x["id"]: x for x in j["donors"]}
        self.assertEqual(by[w5.id]["status"], "waiting")
        self.assertEqual(by[w5.id]["days_left"], 5)
        self.assertEqual(by[today.id]["donated_days_ago"], 0)
        self.assertEqual(by[today.id]["days_left"], BR.interval_days("m"))
        self.assertFalse(by[today.id]["eligible"])           # never "available" inside the interval
        self.assertEqual(by[paused.id]["status"], "paused")  # shown, not hidden
        self.assertEqual(j["counts"], {"total": 6, "available": 2, "soon": 3, "paused": 1})

    def test_interval_never_shorter_than_who(self):
        self.assertGreaterEqual(BR.interval_days("m"), 84)    # WHO 12 weeks
        self.assertGreaterEqual(BR.interval_days("f"), 112)   # WHO 16 weeks
        self.assertGreaterEqual(BR.interval_days("m"), 120)   # BD national 4 months
        self.assertGreaterEqual(BR.interval_days("f"), 120)

    def test_list_moves_daily_turns_green_and_push(self):
        _u, d = self.donor("Moves", "A+", MIRPUR, last_days=119)
        on = timezone.localdate()
        self.assertEqual(BP.eligibility(d, on)["days_left"], 1)
        tomorrow = on + timedelta(days=1)
        el = BP.eligibility(d, tomorrow)
        self.assertEqual((el["eligible"], el["days_left"]), (True, 0))
        self.assertEqual(BP.donor_status(d, el), "available")
        BP.sweep(at=timezone.now() + timedelta(days=1))
        self.assertEqual(len(self.spy.to(d.user, "eligible")), 1)
        BP.sweep(at=timezone.now() + timedelta(days=1, hours=1))
        self.assertEqual(len(self.spy.to(d.user, "eligible")), 1)   # once

    def test_privacy_no_number_no_point(self):
        self.donor("Private", "A+", MIRPUR)
        raw = str(self.rows())
        self.assertNotIn("0181", raw)                         # no phone digits
        self.assertNotIn("90.37", raw)                        # no point
        self.assertNotIn("@example.com", raw)


class OwnerFinalShare(BloodBase):
    def test_both_sides_agree_and_helped(self):
        donor_u, d = self.donor("Helper", "A+", MIRPUR)
        r = self.post_req()
        rid = r.json()["request"]["id"]
        req = BloodRequest.objects.get(pk=rid)
        self.assertIsNone(BP.respond(req, donor_u, "can"))
        fam = self.api(self.req_user)
        don = self.api(donor_u)
        self.assertEqual(fam.post("/api/v1/blood-panel/requests/%d/share" % rid).status_code, 400)
        fam.post("/api/v1/blood-panel/requests/%d/found" % rid)
        s = fam.post("/api/v1/blood-panel/requests/%d/share" % rid).json()["share"]
        self.assertEqual((s["family_ok"], s["donor_ok"], s["can_share"]), (True, False, False))
        self.assertEqual(len(self.spy.to(donor_u, "share_ask")), 1)
        stranger = self.mk("Stranger")
        self.assertEqual(self.api(stranger).post(
            "/api/v1/blood-panel/requests/%d/share" % rid).status_code, 403)
        s = don.post("/api/v1/blood-panel/requests/%d/share" % rid).json()["share"]
        self.assertTrue(s["can_share"])
        self.assertTrue(fam.get("/api/v1/blood-panel/requests/%d" % rid).json()["share"]["can_share"])
        self.assertEqual(BP.donor_json(d, "en")["helped"], 1)
        self.assertEqual(BloodRecipient.objects.filter(request=req, response="can").count(), 1)
