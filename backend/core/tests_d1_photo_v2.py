"""d1-photo v2: Photo Studio pricing (owner order 6), the photo-worker queue,
FACE LOCK plumbing, safety additions, templates, "report this AI image",
the free-tier Profit Guard and the Owner Admin → Photo Studio page (blind A/B).

Heavy maths (Real-ESRGAN / YuNet / AuraFace) is exercised with fakes here;
the real-model checks live in tools/photo_eval (numbers in .phaseB/D1_EVAL.md).
"""
import base64
import io
import os
import shutil
import tempfile
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import photo_restore as R
from core import photo_studio_service as S
from core import photo_worker as W
from core.logic import photo_studio as PS
from core.models import (PhotoABPair, PhotoABVote, PhotoAdTicket, PhotoAIReport,
                         PhotoStudioJob, PhotoWorkItem, User)


def _opts(feature, plan="free", usage=None, cost_usd=0.04, **ps):
    return PS.funding_options(feature=feature, plan=plan, cost_usd=cost_usd, usd_bdt=120,
                              table_credits=9, net_floor=0.6, credit_bdt=1.0,
                              ps_cfg={"ad_value_bdt": 5.0, **ps}, ad_rewards={"ecpm_bdt": 30},
                              usage=usage)


# =========================================================================== pricing
class PricingRulesTests(SimpleTestCase):
    def test_free_hd_enhance_ads_route_daily_cap_then_paywall(self):
        # photo-final (owner 24 Oct) replaced "3 a day, 1 ad each": after the
        # 3 lifetime free ones, with AdMob live each enhance = 2 ads, still at
        # most free_enhance_per_day a day (core/tests_photo_final.py has the rest)
        base = {"lifetime_free": 3, "ads_live": True}
        for used in range(3):
            q = _opts("enhance_server", usage={**base, "enhance_today": used}, cost_usd=0)
            self.assertTrue(q["ok"])
            self.assertEqual(q["options"], [{"via": "ads", "ads": 2, "trial": False}])
            self.assertEqual(q["left_today"], 3 - used)
        q = _opts("enhance_server", usage={**base, "enhance_today": 3}, cost_usd=0)
        self.assertFalse(q["ok"])
        self.assertEqual(q["reason"], "daily_limit")
        self.assertTrue(q["paywall"])
        # editable in Owner Admin
        q = _opts("enhance_server", usage={**base, "enhance_today": 3}, cost_usd=0,
                  free_enhance_per_day=5, enhance_unlock_ads=1)
        self.assertEqual(q["options"][0]["ads"], 1)

    def test_premium_no_ads_fair_use_cap(self):
        q = _opts("enhance_server", plan="premium", usage={"enhance_today": 99}, cost_usd=0)
        self.assertEqual(q["options"], [{"via": "free"}])
        q = _opts("enhance_server", plan="premium", usage={"enhance_today": 100}, cost_usd=0)
        self.assertEqual((q["ok"], q["reason"]), (False, "fair_use_cap"))

    def test_free_ai_generation_two_gifts_then_one_a_week_after_three_ads(self):
        q = _opts("prompt_edit", usage={"gen_lifetime": 0})
        self.assertEqual(q["options"][0], {"via": "gift", "trial": True})
        self.assertEqual(q["gifts_left"], 2)
        q = _opts("prompt_edit", usage={"gen_lifetime": 2, "gen_week": 0})
        ads = [o for o in q["options"] if o["via"] == "ads"]
        self.assertEqual(ads[0]["ads"], 3)              # >= 3 even though 2 would cover it
        q = _opts("prompt_edit", usage={"gen_lifetime": 2, "gen_week": 1})
        self.assertEqual([o["via"] for o in q["options"]], ["credits"])
        self.assertEqual(q["reason"], "week_used")

    def test_paid_ad_options_never_lose_money(self):
        """Ads/credits options still never earn less than the cost; only the
        owner-approved 'gift' is a known free-tier cost (Profit Guard)."""
        for cost in (0.005, 0.02, 0.04, 0.08):
            for u in ({"gen_lifetime": 2, "gen_week": 0},):
                q = _opts("generate", usage=u, cost_usd=cost)
                for o in q["options"]:
                    rev = PS.option_revenue_bdt(o, ad_value=5.0, share=0.7, credit_bdt=1.0)
                    self.assertGreaterEqual(rev + 1e-9, cost * 120, (cost, o))


# =========================================================================== safety
class SafetyV2Tests(SimpleTestCase):
    def test_suggestive_edits_of_children_refused(self):
        v = PS.classify("make her look sexy", [], child_in_photo=True, feature="prompt_edit")
        self.assertFalse(v["allowed"])
        v = PS.classify("make it hot and bold look", [], child_in_photo=True, feature="prompt_edit")
        self.assertEqual(v["reason"], "child_suggestive")
        self.assertTrue(PS.classify("add a birthday cake", [], child_in_photo=True,
                                    feature="prompt_edit")["allowed"])

    def test_other_people_need_consent(self):
        v = PS.classify("change the background", [], others_in_photo=True,
                        feature="prompt_edit", consent=False)
        self.assertEqual(v["reason"], "consent_needed")
        self.assertTrue(PS.classify("change the background", [], others_in_photo=True,
                                    feature="prompt_edit", consent=True)["allowed"])
        # restore jobs are faithful: no consent gate
        self.assertTrue(PS.classify("", [], others_in_photo=True, feature="colorize",
                                    consent=False)["allowed"])


# =========================================================================== API + queue
def _png():
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (64, 48), (120, 120, 120)).save(b, "PNG")
    return b.getvalue()


class _Base(APITestCase):
    def setUp(self):
        self.free = User.objects.create_user(name="F", phone="01000000301", password="pw")
        self.free.plan = "free"
        self.free.trial_until = None
        self.free.save()
        self.prem = User.objects.create_user(name="P", phone="01000000302", password="pw")
        self.prem.plan = "premium"
        self.prem.plan_until = timezone.now() + timedelta(days=30)
        self.prem.save()
        self.media = tempfile.mkdtemp()
        self._m = override_settings(MEDIA_ROOT=self.media, PHOTO_WORKER=True)
        self._m.enable()
        p = mock.patch.object(R, "status", side_effect=lambda f, lang="bn": {
            "ready": True, "where": "gpu" if f == "deblur" else "server", "cost_usd": 0.0, "needs": ""})
        p.start()
        self.addCleanup(p.stop)

    def tearDown(self):
        self._m.disable()
        shutil.rmtree(self.media, ignore_errors=True)

    def post(self, user, path, data):
        self.client.force_authenticate(user)
        return self.client.post("/api/v1/photo-studio/" + path, data, format="json")


class QueueTests(_Base):
    def test_api_only_enqueues_then_the_worker_runs_it(self):
        r = self.post(self.prem, "jobs", {"feature": "enhance_server"})
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        self.assertEqual(r.json()["job"]["funding"], "free")
        r = self.post(self.prem, "jobs/%d/run" % jid, {"image_b64": base64.b64encode(_png()).decode()})
        self.assertEqual(r.status_code, 202, r.content)                 # queued, not run
        self.assertEqual(r.json()["job"]["status"], "queued")
        self.assertEqual(r.json()["job"]["queue_position"], 1)
        item = PhotoWorkItem.objects.get(job_id=jid)
        self.assertTrue(os.path.exists(os.path.join(W._queue_dir(), item.input_name)))

        def fake_exec(job, raw, it):
            return _png(), 0.0, {"path": "cpu", "face_lock": {
                "faces": 1, "kept": 0, "restored": 1, "min_score": 0.97,
                "action": "restored_original_face", "method": "auraface"}}
        with mock.patch.object(W, "_execute", side_effect=fake_exec):
            self.assertEqual(W.loop(once=True), 1)
        job = PhotoStudioJob.objects.get(pk=jid)
        self.assertEqual(job.status, "done")
        self.assertEqual(job.flags["face_lock"]["action"], "restored_original_face")
        self.assertEqual(PhotoWorkItem.objects.get(job_id=jid).state, "done")
        self.assertFalse(os.path.exists(os.path.join(W._queue_dir(), item.input_name)))
        self.client.force_authenticate(self.prem)
        j = self.client.get("/api/v1/photo-studio/jobs/%d" % jid).json()["job"]
        self.assertEqual(j["face_lock"]["min_score"], 0.97)

    def test_paid_jobs_jump_the_queue_and_stale_running_rows_come_back(self):
        jobs = []
        for u in (self.free, self.prem):
            j = PhotoStudioJob.objects.create(user=u, feature="colorize", status="funded",
                                              funding="ads" if u == self.free else "pool")
            W.enqueue(j, _png())
            jobs.append(j)
        it = W.claim("t1")
        self.assertEqual(it.job_id, jobs[1].pk)                         # premium first
        PhotoWorkItem.objects.filter(pk=it.pk).update(claimed_at=timezone.now() - timedelta(hours=1))
        self.assertEqual(W.requeue_stale(), 1)

    def test_worker_failure_keeps_funds_then_refunds_after_three(self):
        from core import billing
        billing.grant_monthly_pool(self.prem)
        r = self.post(self.prem, "jobs", {"feature": "colorize"})
        jid = r.json()["job"]["id"]
        self.prem.refresh_from_db()
        before = self.prem.ai_credits
        img = {"image_b64": base64.b64encode(_png()).decode()}
        with mock.patch.object(W, "_execute", side_effect=W.JobFailed("ort_run:X")):
            for i in range(3):
                self.post(self.prem, "jobs/%d/run" % jid, img)
                W.loop(once=True)
                st = PhotoStudioJob.objects.get(pk=jid).status
                self.assertEqual(st, "failed" if i == 2 else "funded")
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, before + PhotoStudioJob.objects.get(pk=jid).credits_charged)

    def test_free_enhance_needs_its_ad_then_daily_limit(self):
        # photo-final: the 3 lifetime free ones are used, AdMob is live
        for _ in range(3):
            PhotoStudioJob.objects.create(user=self.free, feature="enhance_server", status="done",
                                          funding="gift", flags={"free_kind": "lifetime"},
                                          )
        PhotoStudioJob.objects.filter(funding="gift").update(created_at=timezone.now() - timedelta(days=9))
        p = mock.patch.object(S, "_ad_units", return_value={"_configured": True})
        p.start()
        self.addCleanup(p.stop)
        r = self.post(self.free, "jobs", {"feature": "enhance_server", "via": "ads"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["job"]["ads_required"], 2)
        jid = r.json()["job"]["id"]
        r = self.post(self.free, "jobs/%d/run" % jid, {"image_b64": base64.b64encode(_png()).decode()})
        self.assertEqual(r.status_code, 402)                            # no ad yet: no bypass
        for _ in range(2):
            PhotoStudioJob.objects.create(user=self.free, feature="enhance_server", status="done")
        r = self.post(self.free, "jobs", {"feature": "enhance_server", "via": "ads"})
        self.assertEqual(r.status_code, 409)
        self.assertEqual(r.json()["reason"], "daily_limit")

    def test_gift_generation_is_funded_without_ads(self):
        with mock.patch.object(S, "_active_provider", return_value=("photo_gemini", {}, 0.04)):
            r = self.post(self.free, "jobs", {"feature": "prompt_edit", "via": "gift",
                                              "prompt": "studio background"})
        self.assertEqual(r.status_code, 201, r.content)
        j = PhotoStudioJob.objects.get(pk=r.json()["job"]["id"])
        self.assertEqual((j.status, j.funding, j.trial), ("funded", "gift", True))

    def test_template_prompt_is_server_owned(self):
        with mock.patch.object(S, "_active_provider", return_value=("photo_gemini", {}, 0.04)):
            r = self.post(self.prem, "jobs", {"feature": "prompt_edit", "template": "linkedin"})
        j = PhotoStudioJob.objects.get(pk=r.json()["job"]["id"])
        self.assertIn("Professional profile photo", j.prompt)
        ids = [t["id"] for t in S.templates("en")]
        for t in ("hd_portrait", "old_restore", "passport_bd", "visa_bd", "linkedin", "eid_outfit",
                  "puja_outfit", "wedding_outfit", "studio_bg", "product_shop"):
            self.assertIn(t, ids)

    def test_report_ai_image(self):
        j = PhotoStudioJob.objects.create(user=self.free, feature="prompt_edit", status="done")
        r = self.post(self.free, "jobs/%d/report" % j.pk, {"reason": "face_changed", "note": "not me"})
        self.assertEqual(r.status_code, 201)
        self.assertEqual(PhotoAIReport.objects.get().reason, "face_changed")
        other = PhotoStudioJob.objects.create(user=self.prem, feature="prompt_edit", status="done")
        self.assertEqual(self.post(self.free, "jobs/%d/report" % other.pk, {}).status_code, 404)

    def test_free_tier_guard_alerts_when_losing_money(self):
        PhotoStudioJob.objects.create(user=self.free, feature="prompt_edit", status="done",
                                      funding="gift", cost_bdt=4.8)
        g = S.free_tier_guard(30)
        self.assertTrue(g["alert"])
        self.assertEqual(g["losing_users"], 1)
        PhotoAdTicket.objects.create(user=self.free, nonce="n1", status="verified", value_bdt=6.0)
        self.assertFalse(S.free_tier_guard(30)["alert"])

    def test_config_carries_templates_limits_and_usage(self):
        self.client.force_authenticate(self.free)
        j = self.client.get("/api/v1/photo-studio/config").json()
        self.assertEqual(j["limits"]["free_enhance_per_day"], 3)
        self.assertIn("enhance_server", j["restore"])
        self.assertEqual(j["usage"]["enhance_today"], 0)
        self.assertTrue(j["templates"])


class WorkerOffTests(TestCase):
    def test_without_the_worker_heavy_features_stay_hidden(self):
        with override_settings(PHOTO_WORKER=False):
            for f in ("enhance_server", "colorize", "old_restore", "deblur"):
                self.assertFalse(R.status(f, "en")["ready"], f)


# =========================================================================== owner page
class OwnerPhotoPageTests(TestCase):
    def test_page_renders_and_blind_vote_is_recorded(self):
        from web.tests_o2_owner_admin import OwnerBase
        case = OwnerBase(methodName="setUp")
        case.setUp()
        case.ready()
        p = PhotoABPair.objects.create(name="01_portrait.jpg", category="portrait",
                                       input_name="x_in.jpg", assisto_name="x_a.jpg",
                                       remini_name="x_r.jpg")
        for lang, word in (("en", "Blind A/B test"), ("bn", "অন্ধ A/B")):
            r = case.c.get("/owner/photo?lang=" + lang)
            self.assertEqual(r.status_code, 200)
            self.assertContains(r, word)
        r = case.post("/owner/photo", {"action": "vote", "pair": p.pk, "pick": "right",
                                       "left_was": "remini"})
        self.assertEqual(r.status_code, 302)
        v = PhotoABVote.objects.get()
        self.assertEqual(v.choice, "assisto")              # right side was Assisto
        r = case.c.get("/owner/photo?lang=en")
        self.assertContains(r, "You have voted on every pair.")
