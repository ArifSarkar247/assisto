"""ps1-photo: Photo Studio — pure funding/Profit-Guard math ("a loss-making edit
is impossible"), safety refusals (en / Bangla / Banglish), admin-editable
config, the AdMob SSV ad-reward ledger (real ECDSA signatures with a test key),
the ONE export gate on every exit path, Premium/Business never shown ads,
cloud run with a mocked provider, and the owner P&L feed."""
import base64
import io
import itertools
from datetime import timedelta
from unittest import mock
from urllib.parse import urlencode

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import billing
from core import photo_studio_service as S
from core.logic import photo_studio as PS
from core.logic import pricing as P
from core.models import (AdWallet, CreditLedger, PhotoAdTicket, PhotoExport,
                         PhotoStudioJob, PricingConfig, User)

EXPORTS = ("save", "share", "wallpaper", "copy", "open_in")


# =========================================================================== pure
class FundingMathTests(SimpleTestCase):
    def test_ads_needed_formula(self):
        # cost ÷ (70% × ad value), rounded UP
        self.assertEqual(PS.ads_needed(4.8, 5.0, 0.70), 2)       # 4.8/3.5 = 1.37
        self.assertEqual(PS.ads_needed(3.5, 5.0, 0.70), 1)
        self.assertEqual(PS.ads_needed(3.51, 5.0, 0.70), 2)
        self.assertIsNone(PS.ads_needed(1.0, 0.0))                # no ad value
        self.assertEqual(PS.ads_needed(0, 5.0), 0)
        # share can never be counted above 70%
        self.assertEqual(PS.ads_needed(7.0, 10.0, 0.99), 1)
        self.assertEqual(PS.ads_needed(7.01, 10.0, 0.99), 2)

    def test_ad_value_override_and_ecpm_fallback(self):
        self.assertAlmostEqual(PS.ad_value_bdt({}, {"ecpm_bdt": 150}), 0.15)
        self.assertEqual(PS.ad_value_bdt({"ad_value_bdt": 2.5}, {"ecpm_bdt": 150}), 2.5)

    def _opts(self, **kw):
        base = dict(feature="prompt_edit", plan="free", cost_usd=0.04, usd_bdt=120,
                    table_credits=9, net_floor=0.60, credit_bdt=1.0,
                    ps_cfg={"ad_value_bdt": 5.0}, ad_rewards={"ecpm_bdt": 30})
        base.update(kw)
        return PS.funding_options(**base)

    def test_a_loss_making_edit_is_impossible(self):
        """Grid over costs / ad values / shares / credit bases / net floors /
        features / plans: every offered option earns >= the provider cost, and
        credit options also hold the NET floor."""
        costs = [0.0005, 0.004, 0.01, 0.04, 0.08, 0.2]
        ad_values = [0.0, 0.03, 0.3, 1.0, 5.0, 20.0]
        shares = [0.3, 0.7, 0.95]
        credit_bdts = [0.5, 1.0, 2.0]
        floors = [0.3, 0.6, 0.9]
        tables = [0, 1, 9]
        checked = 0
        for (c, av, sh, cb, nf, tb, feat, plan) in itertools.product(
                costs, ad_values, shares, credit_bdts, floors, tables,
                PS.CLOUD_FEATURES, ("free", "premium", "business")):
            q = PS.funding_options(
                feature=feat, plan=plan, cost_usd=c, usd_bdt=120, table_credits=tb,
                net_floor=nf, credit_bdt=cb,
                ps_cfg={"ad_value_bdt": av, "ad_value_share": sh},
                ad_rewards={"ecpm_bdt": 30})
            cost_bdt = c * 120
            for o in q["options"]:
                rev = PS.option_revenue_bdt(o, ad_value=PS.ad_value_bdt(
                    {"ad_value_bdt": av}, {"ecpm_bdt": 30}), share=min(sh, 0.70),
                    credit_bdt=cb)
                self.assertGreaterEqual(rev + 1e-9, cost_bdt, (c, av, sh, cb, nf, o))
                if o["via"] in ("credits", "pool"):
                    self.assertGreaterEqual(o["credits"] * cb + 1e-9, cost_bdt / nf)
                if o["via"] == "ads":
                    self.assertLessEqual(o["ads"], 3)
                checked += 1
        self.assertGreater(checked, 1000)

    def test_unpriced_cloud_job_is_refused(self):
        q = self._opts(cost_usd=0.0)
        self.assertFalse(q["ok"])
        self.assertEqual(q["reason"], "unpriced")
        self.assertEqual(q["options"], [])

    def test_provider_missing(self):
        q = self._opts(provider_ready=False)
        self.assertEqual(q["reason"], "provider_missing")

    def test_more_than_three_ads_means_credits_only(self):
        q = self._opts(ps_cfg={"ad_value_bdt": 0.03})   # ~229 ads needed
        self.assertTrue(q["ok"])
        self.assertEqual([o["via"] for o in q["options"]], ["credits"])
        self.assertEqual(q["reason"], "too_many_ads")

    def test_admin_cannot_raise_max_ads_above_three(self):
        cfg = PS.normalize_cfg({"max_ads_per_job": 10, "ad_value_share": 0.95,
                                "enhance_hd_ads": 9, "entry_interstitial_gap_min": 1})
        self.assertEqual(cfg["max_ads_per_job"], 3)
        self.assertEqual(cfg["ad_value_share"], 0.70)
        self.assertEqual(cfg["enhance_hd_ads"], 3)
        self.assertEqual(cfg["entry_interstitial_gap_min"], 5)

    def test_one_free_trial_per_day(self):
        q0 = self._opts(trials_used_today=0)
        self.assertEqual(q0["options"][0]["via"], "ads")
        self.assertTrue(q0["options"][0]["trial"])
        q1 = self._opts(trials_used_today=1)
        self.assertEqual([o["via"] for o in q1["options"]], ["credits"])
        self.assertEqual(q1["reason"], "trial_used")

    def test_guard_over_blocks_free_cloud(self):
        q = self._opts(guard_over=True)
        self.assertFalse(q["ok"])
        self.assertEqual(q["reason"], "guard_over")

    def test_paid_plans_never_get_ads(self):
        for plan in ("premium", "business", "annual", "founder"):
            for f in PS.FEATURES:
                q = self._opts(feature=f, plan=plan)
                self.assertTrue(all(o["via"] != "ads" for o in q["options"]), (plan, f))

    def test_enhance_hd_free_is_two_ads_or_credits(self):
        q = self._opts(feature="enhance_hd", cost_usd=0)
        self.assertEqual(q["options"][0], {"via": "ads", "ads": 2, "trial": False})
        self.assertEqual(q["options"][1]["via"], "credits")
        qp = self._opts(feature="enhance_hd", plan="premium", cost_usd=0)
        self.assertEqual(qp["options"], [{"via": "free"}])

    def test_feature_stats(self):
        out = PS.feature_stats([
            {"date": "2026-10-20", "feature": "prompt_edit", "ad_revenue_bdt": 7.0,
             "cost_bdt": 4.8, "jobs": 1, "ads": 2},
            {"date": "2026-10-20", "feature": "entry", "ad_revenue_bdt": 0.5, "ads": 1},
        ])
        self.assertEqual(out["totals"]["revenue"], 750)
        self.assertEqual(out["totals"]["cost"], 480)
        f = {x["feature"]: x for x in out["features"]}
        self.assertEqual(f["prompt_edit"]["margin"], 220)

    def test_ssv_split(self):
        m, sig, kid = PS.ssv_split("ad_network=1&custom_data=abc&signature=XYZ&key_id=42")
        self.assertEqual(m, "ad_network=1&custom_data=abc")
        self.assertEqual(sig, "XYZ")
        self.assertEqual(kid, "42")
        self.assertEqual(PS.ssv_split("a=1"), (None, None, None))


class SafetyTests(SimpleTestCase):
    def no(self, prompt, reason, **kw):
        v = PS.classify(prompt, **kw)
        self.assertFalse(v["allowed"], prompt)
        self.assertEqual(v["reason"], reason, prompt)

    def ok(self, prompt, **kw):
        v = PS.classify(prompt, **kw)
        self.assertTrue(v["allowed"], (prompt, v))
        return v

    def test_sexual_and_undressing(self):
        for p in ("remove her clothes", "make it nude", "Undress him",
                  "kapor khulo", "উলঙ্গ করে দাও", "জামা খুলে দাও", "sexy bikini"):
            self.no(p, "sexual")

    def test_real_person_fake_scene(self):
        for p in ("put me in jail", "make him look drunk", "face swap with my friend",
                  "show her taking a bribe", "জেলে বসিয়ে দাও", "make me look like a celebrity"):
            self.no(p, "fake_scene")

    def test_document_money_seal_fraud(self):
        for p in ("change the date on my certificate", "edit NID name",
                  "add an official seal", "change the text", "make a 1000 taka note",
                  "সার্টিফিকেটের নাম বদল", "সিলমোহর বসাও"):
            self.no(p, "document_fraud")
        # a document photo: only faithful cleanup / crop
        self.ok("", options=["document_cleanup"], photo_kind="document",
                feature="enhance_hd")
        self.no("", "document_fraud", options=["bg_change"], photo_kind="document")

    def test_identity_change_and_beauty_list(self):
        for p in ("make my skin fair", "slim face", "bigger eyes", "make me younger",
                  "ফর্সা করে দাও", "forsa koro"):
            self.no(p, "identity_change")
        self.no("", "identity_change", options=["beauty_retouch"], beauty_ops=["nose"])
        self.no("", "beauty_not_allowed", options=["beauty_retouch"], beauty_ops=["laser_eyes"])
        self.ok("", options=["beauty_retouch"],
                beauty_ops=["skin_smooth", "blemish_remove", "under_eye", "even_tone",
                            "glow", "teeth_whiten", "eye_brighten", "hair_tidy",
                            "light_makeup"])

    def test_children(self):
        self.no("", "child_beauty", options=["beauty_retouch"], beauty_ops=["glow"],
                child_in_photo=True)
        self.no("my baby on the moon", "child_generation", feature="generate")
        v = self.ok("change background for my baby", options=["bg_change"])
        self.assertTrue(v["flags"]["child_caution"])

    def test_consent_reminder(self):
        v = self.ok("blur the background", options=["bg_blur"], own_photo=False)
        self.assertTrue(v["flags"]["consent_reminder"])
        self.assertTrue(v["flags"]["face_lock"])

    def test_normal_edits_pass(self):
        for p in ("change the background to a beach", "make the sky blue",
                  "remove the people behind me", "আকাশ নীল করো",
                  "studio white background for my product", "rotate 90 degree",
                  "brighter lighting", "ব্যাকগ্রাউন্ড ঝাপসা করো", "Sylhet tea garden",
                  "change the background colour to white", "even out my skin tone"):
            self.ok(p)

    def test_unknown_option(self):
        self.no("", "bad_option", options=["xray"])


class PricingIntegrationTests(SimpleTestCase):
    def test_defaults_validate_and_hold_margin(self):
        d = P.DEFAULTS()
        self.assertEqual(P.validate_edit(d), [])
        for a in ("photo_enhance_cloud", "photo_prompt_edit", "photo_generate"):
            self.assertGreaterEqual(d["action_costs"][a]["credits"], P.action_credit_floor(a, d))
        self.assertEqual(P.normalize(d)["photo_studio"]["entry_interstitial_gap_min"], 30)

    def test_bad_photo_studio_edit_rejected(self):
        self.assertIn("photo_studio_bad", P.validate_edit({"photo_studio": {"enhance_hd_ads": -1}}))
        self.assertIn("photo_studio_bad", P.validate_edit({"photo_studio": "x"}))


# =========================================================================== API
_SSV_KEY = ec.generate_private_key(ec.SECP256R1())
_SSV_PEM = _SSV_KEY.public_key().public_bytes(
    serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
_SSV_KID = "3335741209"


def _ssv_query(nonce, user_id, txn, key=_SSV_KEY, kid=_SSV_KID):
    msg = urlencode([("ad_network", "5450213213286189855"),
                     ("ad_unit", "1234567890"), ("custom_data", nonce),
                     ("reward_amount", "1"), ("reward_item", "unlock"),
                     ("timestamp", "1700000000000"), ("transaction_id", txn),
                     ("user_id", user_id)])
    sig = key.sign(msg.encode(), ec.ECDSA(hashes.SHA256()))
    s64 = base64.urlsafe_b64encode(sig).decode().rstrip("=")
    return "%s&signature=%s&key_id=%s" % (msg, s64, kid)


def _png(w=64, h=48, color=(200, 120, 40)):
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, "PNG")
    return buf.getvalue()


class _Base(APITestCase):
    def setUp(self):
        self.free = User.objects.create_user(name="F", phone="01710000901", password="pw")
        self.free.plan = "free"
        self.free.trial_until = None
        self.free.save()
        self.prem = User.objects.create_user(name="P", phone="01710000902", password="pw")
        self.prem.plan = "premium"
        self.prem.plan_until = timezone.now() + timedelta(days=30)
        self.prem.save()
        # pr1: the monthly pool is a real grant now (Premium 90 / Business 240)
        from core import billing as _b
        _b.grant_monthly_pool(self.prem)
        self.prem.refresh_from_db()
        self.biz = User.objects.create_user(name="B", phone="01710000903", password="pw")
        self.biz.plan = "business"
        self.biz.plan_until = timezone.now() + timedelta(days=30)
        self.biz.save()
        _b.grant_monthly_pool(self.biz)
        self.biz.refresh_from_db()
        self.owner = User.objects.create_user(name="O", phone="01710000904", password="pw")
        self.owner.is_superuser = True
        self.owner.save()
        self._keys = mock.patch.object(S, "_ssv_keys", return_value={_SSV_KID: _SSV_PEM})
        self._keys.start()
        self.addCleanup(self._keys.stop)

    def set_ps(self, **kw):
        row = billing.get_config()
        d = dict(row.data)
        ps = dict(d.get("photo_studio") or {})
        ps.update(kw)
        d["photo_studio"] = ps
        row.data = d
        row.save()

    def provider(self, cost="0.04", on=True):
        def is_enabled(slug):
            return on and slug == "photo_gemini"

        def get(slug):
            if on and slug == "photo_gemini":
                return {"api_key": "test-not-a-real-key", "cost_per_image_usd": cost}
            return {}
        p1 = mock.patch("core.integrations.is_enabled", side_effect=is_enabled)
        p2 = mock.patch("core.integrations.get", side_effect=get)
        p1.start(); p2.start()
        self.addCleanup(p1.stop); self.addCleanup(p2.stop)

    def as_(self, u):
        self.client.force_authenticate(u)

    def job(self, feature="enhance_hd", via="ads", **extra):
        r = self.client.post("/api/v1/photo-studio/jobs",
                             {"feature": feature, "via": via, **extra}, format="json")
        return r

    def ssv(self, nonce, user, txn):
        return self.client.get("/api/v1/ads/ssv?" + _ssv_query(nonce, str(user.pk), txn))

    def ticket(self, jid):
        return self.client.post("/api/v1/photo-studio/jobs/%d/ad-ticket" % jid, {},
                                format="json")

    def unlock(self, jid, kind):
        return self.client.post("/api/v1/photo-studio/jobs/%d/unlock" % jid,
                                {"kind": kind}, format="json")


class ConfigApiTests(_Base):
    def test_free_config(self):
        self.as_(self.free)
        r = self.client.get("/api/v1/photo-studio/config", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 200)
        j = r.json()
        self.assertTrue(j["free"])
        self.assertTrue(j["ads_shown"])
        self.assertTrue(j["entry_ad"]["due"])
        self.assertEqual(j["entry_ad"]["gap_min"], 30)
        self.assertEqual(j["features"]["enhance_hd"]["options"][0]["ads"], 2)
        # no provider connected -> honest "needs key" state, no fake option
        self.assertFalse(j["providers"]["ready"])
        self.assertIn("key", j["providers"]["needs"])
        self.assertEqual(j["features"]["prompt_edit"]["reason"], "provider_missing")
        self.assertEqual(j["trials_left_today"], 1)

    def test_premium_and_business_never_ads(self):
        for u in (self.prem, self.biz):
            self.as_(u)
            j = self.client.get("/api/v1/photo-studio/config").json()
            self.assertFalse(j["ads_shown"])
            self.assertFalse(j["entry_ad"]["due"])
            for q in j["features"].values():
                self.assertTrue(all(o["via"] != "ads" for o in q.get("options", [])))
            r = self.client.post("/api/v1/photo-studio/entry-ad", {"shown": True}, format="json")
            self.assertEqual(r.status_code, 409)

    def test_entry_ad_cap_admin_editable(self):
        self.as_(self.free)
        r = self.client.post("/api/v1/photo-studio/entry-ad", {"shown": True}, format="json")
        self.assertEqual(r.status_code, 200)
        self.assertFalse(self.client.get("/api/v1/photo-studio/config").json()["entry_ad"]["due"])
        r = self.client.post("/api/v1/photo-studio/entry-ad", {"shown": True}, format="json")
        self.assertEqual(r.status_code, 409)
        # 31 min later -> due again
        PhotoAdTicket.objects.filter(placement="entry").update(
            created_at=timezone.now() - timedelta(minutes=31))
        self.assertTrue(self.client.get("/api/v1/photo-studio/config").json()["entry_ad"]["due"])
        # owner raises the cap to 60 min via /admin/pricing
        self.as_(self.owner)
        r = self.client.post("/api/v1/admin/pricing",
                             {"config": {"photo_studio": {"entry_interstitial_gap_min": 60}}},
                             format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.as_(self.free)
        self.assertFalse(self.client.get("/api/v1/photo-studio/config").json()["entry_ad"]["due"])

    def test_safety_endpoint(self):
        self.as_(self.free)
        r = self.client.post("/api/v1/photo-studio/safety", {"prompt": "remove her clothes"},
                             format="json", HTTP_ACCEPT_LANGUAGE="bn")
        j = r.json()
        self.assertFalse(j["allowed"])
        self.assertEqual(j["reason"], "sexual")
        self.assertTrue(j["message"])


class ExportGateTests(_Base):
    def test_every_export_path_requires_unlock_for_free(self):
        self.as_(self.free)
        r = self.job("enhance_hd", "ads")
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        self.assertEqual(r.json()["job"]["ads_required"], 2)
        for k in EXPORTS:
            self.assertEqual(self.unlock(jid, k).status_code, 402, k)
        # first ad
        t1 = self.ticket(jid).json()
        self.assertEqual(t1["user_id"], str(self.free.pk))
        self.assertEqual(self.ssv(t1["nonce"], self.free, "txn-1").status_code, 200)
        for k in EXPORTS:
            self.assertEqual(self.unlock(jid, k).status_code, 402, k)
        # second ad -> funded
        t2 = self.ticket(jid).json()
        self.assertNotEqual(t1["nonce"], t2["nonce"])
        self.ssv(t2["nonce"], self.free, "txn-2")
        self.assertEqual(PhotoStudioJob.objects.get(pk=jid).status, "funded")
        for k in EXPORTS:
            r = self.unlock(jid, k)
            self.assertEqual(r.status_code, 200, k)
            self.assertTrue(r.json()["corner_mark"])
        self.assertEqual(PhotoExport.objects.filter(job_id=jid).count(), len(EXPORTS))

    def test_no_fill_or_client_claim_never_unlocks(self):
        self.as_(self.free)
        jid = self.job("enhance_hd", "ads").json()["job"]["id"]
        self.ticket(jid)
        # ad failed to load: nothing reaches /ads/ssv -> still locked
        self.assertEqual(self.unlock(jid, "save").status_code, 402)
        # unsigned / forged callbacks are rejected
        t = PhotoAdTicket.objects.filter(job_id=jid).first()
        r = self.client.get("/api/v1/ads/ssv?custom_data=%s&transaction_id=x" % t.nonce)
        self.assertEqual(r.status_code, 400)
        other = ec.generate_private_key(ec.SECP256R1())
        r = self.client.get("/api/v1/ads/ssv?" + _ssv_query(t.nonce, str(self.free.pk),
                                                             "forged", key=other))
        self.assertEqual(r.status_code, 403)
        self.assertEqual(PhotoAdTicket.objects.get(pk=t.pk).status, "pending")
        self.assertEqual(self.unlock(jid, "share").status_code, 402)

    def test_replay_and_wrong_user_ignored(self):
        self.as_(self.free)
        jid = self.job("enhance_hd", "ads").json()["job"]["id"]
        t1 = self.ticket(jid).json()
        self.ssv(t1["nonce"], self.free, "txn-A")
        t2 = self.ticket(jid).json()
        # replay of txn-A against the second ticket
        self.ssv(t2["nonce"], self.free, "txn-A")
        self.assertEqual(PhotoAdTicket.objects.get(nonce=t2["nonce"]).status, "pending")
        # signed for another user
        self.ssv(t2["nonce"], self.prem, "txn-B")
        self.assertEqual(PhotoAdTicket.objects.get(nonce=t2["nonce"]).status, "pending")
        self.assertEqual(self.unlock(jid, "copy").status_code, 402)

    def test_ticket_farming_capped(self):
        self.as_(self.free)
        jid = self.job("enhance_hd", "ads").json()["job"]["id"]
        nonces = {self.ticket(jid).json()["nonce"] for _ in range(6)}
        self.assertLessEqual(len(nonces), 2)

    def test_credits_route_debits_first(self):
        self.as_(self.free)
        r = self.job("enhance_hd", "credits")
        self.assertEqual(r.status_code, 402)               # 0 credits
        self.free.ai_credits = 5
        self.free.save()
        r = self.job("enhance_hd", "credits")
        self.assertEqual(r.status_code, 201)
        self.free.refresh_from_db()
        self.assertEqual(self.free.ai_credits, 3)
        jid = r.json()["job"]["id"]
        self.assertEqual(self.unlock(jid, "wallpaper").status_code, 200)

    def test_no_fill_then_credits_charges_full_price(self):
        self.as_(self.free)
        jid = self.job("enhance_hd", "ads").json()["job"]["id"]
        t = self.ticket(jid).json()
        self.ssv(t["nonce"], self.free, "half")            # 1 of 2 ads watched
        r = self.client.post("/api/v1/photo-studio/jobs/%d/fund" % jid, {}, format="json")
        self.assertEqual(r.status_code, 402)               # no credits: still locked
        self.assertEqual(self.unlock(jid, "save").status_code, 402)
        self.free.ai_credits = 2
        self.free.save()
        r = self.client.post("/api/v1/photo-studio/jobs/%d/fund" % jid, {}, format="json")
        self.assertEqual(r.status_code, 200)
        self.free.refresh_from_db()
        self.assertEqual(self.free.ai_credits, 0)           # full price, no discount
        self.assertEqual(self.unlock(jid, "open_in").status_code, 200)

    def test_premium_clean_path_no_ads(self):
        for u in (self.prem, self.biz):
            self.as_(u)
            r = self.job("enhance_hd")
            self.assertEqual(r.status_code, 201)
            j = r.json()["job"]
            self.assertEqual(j["status"], "funded")
            self.assertEqual(j["ads_required"], 0)
            for k in EXPORTS:
                r = self.unlock(j["id"], k)
                self.assertEqual(r.status_code, 200)
                self.assertFalse(r.json()["corner_mark"])
            self.assertFalse(PhotoAdTicket.objects.filter(user=u).exists())

    def test_cannot_unlock_someone_elses_job(self):
        self.as_(self.prem)
        jid = self.job("enhance_hd").json()["job"]["id"]
        self.as_(self.free)
        self.assertEqual(self.unlock(jid, "save").status_code, 404)

    def test_bad_export_kind(self):
        self.as_(self.prem)
        jid = self.job("enhance_hd").json()["job"]["id"]
        self.assertEqual(self.unlock(jid, "print").status_code, 400)


class CloudJobTests(_Base):
    def test_refusal_is_honest_and_creates_no_cost(self):
        self.provider()
        self.as_(self.free)
        r = self.client.post(
            "/api/v1/photo-studio/jobs", {"feature": "prompt_edit", "via": "credits",
                                          "prompt": "make my skin fair"},
            format="json", HTTP_ACCEPT_LANGUAGE="en")
        self.assertEqual(r.status_code, 422)
        self.assertTrue(r.json()["refused"])
        self.assertIn("skin colour", r.json()["message"])
        self.assertEqual(PhotoStudioJob.objects.get().status, "refused")

    def test_no_provider_needs_key(self):
        self.as_(self.free)
        r = self.job("prompt_edit", "credits", prompt="blue sky")
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "provider_missing")

    def test_provider_without_cost_is_never_used(self):
        self.provider(cost="")
        self.as_(self.prem)
        j = self.client.get("/api/v1/photo-studio/config").json()
        self.assertFalse(j["providers"]["ready"])

    def test_free_trial_ads_taken_before_work_then_run(self):
        self.provider(cost="0.04")
        # d1-photo v2: lifetime gifts used up -> 1 per week after >= 3 ads
        # (4.8 ÷ (0.7 × 5) = 2 ads would cover the cost; the owner's minimum is 3)
        self.set_ps(ad_value_bdt=5.0, free_gen_lifetime=0)
        self.as_(self.free)
        r = self.job("prompt_edit", "ads", prompt="change the background to a beach",
                     options=["bg_change"])
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        self.assertEqual(r.json()["job"]["ads_required"], 3)
        # cannot run before the ads
        r = self.client.post("/api/v1/photo-studio/jobs/%d/run" % jid,
                             {"image_b64": base64.b64encode(_png()).decode()}, format="json")
        self.assertEqual(r.status_code, 402)
        for i in range(3):
            t = self.ticket(jid).json()
            self.ssv(t["nonce"], self.free, "trial-%d" % i)
        out = _png(color=(10, 200, 30))
        with mock.patch("core.photo_providers.run", return_value=out) as run, \
                override_settings(MEDIA_ROOT=self._tmp()):
            r = self.client.post("/api/v1/photo-studio/jobs/%d/run" % jid,
                                 {"image_b64": base64.b64encode(_png()).decode(),
                                  "face_boxes": [[0.3, 0.2, 0.3, 0.4]]}, format="json")
            self.assertEqual(r.status_code, 200, r.content)
            self.assertEqual(run.call_count, 1)
            job = PhotoStudioJob.objects.get(pk=jid)
            self.assertEqual(job.status, "done")
            self.assertTrue(job.preview_name)
            # revenue (3 ads × 5 × 0.7 = 10.5) >= booked cost (4.8)
            self.assertGreaterEqual(0.7 * job.revenue_bdt + 1e-9, job.cost_bdt)
            r = self.unlock(jid, "share")
            self.assertEqual(r.status_code, 200)
            self.assertIn("/api/v1/m/", r.json()["result"])
        # second one this week -> ads closed, credits only
        q = self.client.get("/api/v1/photo-studio/config").json()["features"]["prompt_edit"]
        self.assertEqual([o["via"] for o in q["options"]], ["credits"])
        r = self.job("prompt_edit", "ads", prompt="blue sky")
        self.assertEqual(r.status_code, 409)

    def test_provider_failure_keeps_funds_for_retry_then_refunds(self):
        from core.photo_providers import ProviderError
        self.provider(cost="0.04")
        self.as_(self.prem)
        r = self.job("generate", prompt="a cup of tea on a table")
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, 90 - 9)          # pool debited first
        with mock.patch("core.photo_providers.run", side_effect=ProviderError("http_500")):
            for i in range(3):
                r = self.client.post("/api/v1/photo-studio/jobs/%d/run" % jid, {}, format="json")
                self.assertEqual(r.status_code, 502)
        self.assertEqual(PhotoStudioJob.objects.get(pk=jid).status, "failed")
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, 90)              # refunded
        self.assertEqual(self.unlock(jid, "save").status_code, 402)

    def test_premium_pool_empty_is_honest(self):
        self.provider(cost="0.04")
        self.prem.ai_credits = 2
        self.prem.save()
        self.as_(self.prem)
        r = self.job("prompt_edit", prompt="blue sky")
        self.assertEqual(r.status_code, 402)
        self.assertEqual(r.json()["reason"], "insufficient")

    def test_provider_cost_above_table_raises_credits(self):
        self.provider(cost="0.20")                # 24 ৳ -> 40 credits at floor 0.6
        self.as_(self.prem)
        q = self.client.get("/api/v1/photo-studio/config").json()["features"]["prompt_edit"]
        self.assertEqual(q["options"][0]["credits"], 40)

    def _tmp(self):
        import tempfile
        d = tempfile.mkdtemp(prefix="ps1test")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        return d


class FaceLockTests(SimpleTestCase):
    def test_composite_restores_original_face_pixels(self):
        from PIL import Image
        orig = _png(100, 100, (200, 0, 0))
        edit = _png(100, 100, (0, 0, 200))
        out = Image.open(io.BytesIO(S.composite_faces(orig, edit, [[0.3, 0.3, 0.4, 0.4]])))
        self.assertEqual(out.getpixel((50, 50))[:3], (200, 0, 0))   # face = original
        self.assertEqual(out.getpixel((5, 5))[:3], (0, 0, 200))     # scene = edited

    def test_preview_is_reduced(self):
        from PIL import Image
        prev = S.make_preview(_png(3000, 2000), 1024, watermark=True)
        im = Image.open(io.BytesIO(prev))
        self.assertLessEqual(max(im.size), 1024)


class OwnerDashboardTests(_Base):
    def test_photo_studio_in_pnl(self):
        self.as_(self.free)
        self.client.post("/api/v1/photo-studio/entry-ad", {"shown": True}, format="json")
        jid = self.job("enhance_hd", "ads").json()["job"]["id"]
        for i in range(2):
            t = self.ticket(jid).json()
            self.ssv(t["nonce"], self.free, "dash-%d" % i)
        self.assertEqual(self.client.get("/api/v1/admin/photo-studio/pnl").status_code, 403)
        self.as_(self.owner)
        j = self.client.get("/api/v1/admin/photo-studio/pnl").json()
        feats = {f["feature"] for f in j["features"]}
        self.assertIn("enhance_hd", feats)
        self.assertIn("entry", feats)
        self.assertTrue(j["days"])
        pnl = self.client.get("/api/v1/admin/pnl").json()
        self.assertIn("photo_studio", pnl)
        self.assertTrue(pnl["photo_studio"]["features"])
