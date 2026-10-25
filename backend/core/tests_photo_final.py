"""photo-final (owner order 24 Oct 2026): provider switch, fallback, cache,
daily spend cap, per-image log, free-enhance rules per account AND device,
Ultra HD quota, local look stage, owner page. Every HTTP client is mocked —
no test can reach Replicate / RunPod / fal.ai.
"""
import base64
import io
import json
import shutil
import tempfile
from datetime import timedelta
from unittest import mock

import numpy as np
from django.test import SimpleTestCase, TestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import photo_final as PFN
from core import photo_look as LK
from core import photo_restore as R
from core import photo_studio_service as S
from core import photo_worker as W
from core.logic import photo_final as PF
from core.logic import photo_studio as PS
from core.models import PhotoAdTicket, PhotoProviderRun, PhotoStudioJob, PhotoWorkItem, User


def _jpg(w=64, h=48, c=(150, 120, 100)):
    from PIL import Image
    b = io.BytesIO()
    Image.new("RGB", (w, h), c).save(b, "JPEG", quality=90)
    return b.getvalue()


def _opts(feature, plan="free", usage=None, cost_usd=0.0, **ps):
    return PS.funding_options(feature=feature, plan=plan, cost_usd=cost_usd, usd_bdt=120,
                              table_credits=9, net_floor=0.6, credit_bdt=1.0,
                              ps_cfg={"ad_value_bdt": 5.0, **ps}, ad_rewards={"ecpm_bdt": 30},
                              usage=usage)


# =========================================================================== pure rules
class FreeEnhanceRulesTests(SimpleTestCase):
    def test_three_free_for_life_then_one_a_week_until_admob_then_paywall(self):
        for used in range(3):
            q = _opts("enhance_server", usage={"lifetime_free": used})
            self.assertEqual(q["options"], [{"via": "gift", "trial": False}])
            self.assertEqual((q["free_kind"], q["free_left"]), ("lifetime", 3 - used))
        q = _opts("enhance_server", usage={"lifetime_free": 3, "week_free": 0})
        self.assertEqual((q["free_kind"], q["options"][0]["via"]), ("week", "gift"))
        q = _opts("enhance_server", usage={"lifetime_free": 3, "week_free": 1})
        self.assertEqual((q["ok"], q["reason"], q["paywall"]), (False, "week_free_used", True))

    def test_once_admob_is_live_each_enhance_costs_two_ads_with_a_daily_cap(self):
        q = _opts("enhance_server", usage={"lifetime_free": 3, "ads_live": True})
        self.assertEqual(q["options"], [{"via": "ads", "ads": 2, "trial": False}])
        q = _opts("enhance_server", usage={"lifetime_free": 3, "ads_live": True, "enhance_today": 3})
        self.assertEqual(q["reason"], "daily_limit")
        # every number editable in Owner Admin
        q = _opts("enhance_server", usage={"lifetime_free": 3, "ads_live": True},
                  enhance_unlock_ads=3, free_enhance_lifetime=5)
        self.assertEqual(q["options"][0]["via"], "gift")
        q = _opts("enhance_server", usage={"lifetime_free": 5, "ads_live": True},
                  enhance_unlock_ads=3, free_enhance_lifetime=5)
        self.assertEqual(q["options"][0]["ads"], 3)

    def test_premium_unchanged_no_ads_fair_use_cap(self):
        q = _opts("enhance_server", plan="premium", usage={"enhance_today": 99})
        self.assertEqual(q["options"], [{"via": "free"}])
        q = _opts("enhance_server", plan="premium", usage={"enhance_today": 100})
        self.assertEqual(q["reason"], "fair_use_cap")

    def test_ultra_hd_premium_only_and_quota(self):
        q = _opts("ultra_hd", plan="free", cost_usd=0.06)
        self.assertEqual((q["ok"], q["reason"]), (False, "premium_only"))
        q = _opts("ultra_hd", plan="premium", cost_usd=0.06, usage={"ultra_quota": 4, "ultra_month": 1})
        self.assertEqual((q["ok"], q["left_month"], q["options"]), (True, 3, [{"via": "free"}]))
        q = _opts("ultra_hd", plan="premium", cost_usd=0.06, usage={"ultra_quota": 4, "ultra_month": 4})
        self.assertEqual(q["reason"], "ultra_quota")
        q = _opts("ultra_hd", plan="premium", cost_usd=0.0, usage={"ultra_quota": 4})
        self.assertEqual(q["reason"], "provider_missing")      # never run unpriced

    def test_config_bounds_and_bools(self):
        c = PS.normalize_cfg({"rollout_replicate": 250, "daily_spend_cap_usd": -3,
                              "face_restore_gfpgan": "yes", "cap_fallback_local": True})
        self.assertEqual(c["rollout_replicate"], 100)
        self.assertEqual(c["daily_spend_cap_usd"], 0.0)
        self.assertFalse(c["face_restore_gfpgan"])            # locked off (owner 25 Oct)
        self.assertFalse(PS.normalize_cfg({"face_restore_gfpgan": True})["face_restore_gfpgan"])
        self.assertTrue(c["cap_fallback_local"])
        d = PS.normalize_cfg({})
        self.assertEqual((d["daily_spend_cap_usd"], d["free_enhance_lifetime"], d["enhance_unlock_ads"],
                          d["free_enhance_per_week_no_ads"], d["face_restore_gfpgan"]),
                         (1.0, 3, 2, 1, False))
        self.assertEqual(PS.validate_cfg({"face_restore_gfpgan": True, "rollout_replicate": 10}), [])


class ProviderPickTests(SimpleTestCase):
    def test_nothing_configured_means_local(self):
        ps = PS.normalize_cfg({"rollout_replicate": 100})
        self.assertEqual(PF.pick_provider(7, ps, set()), "local_worker")

    def test_rollout_percentages_are_stable_and_roughly_right(self):
        ps = PS.normalize_cfg({"rollout_replicate": 30, "rollout_assisto_face": 10})
        conf = {"replicate", "assisto_face"}
        picks = [PF.pick_provider(u, ps, conf) for u in range(2000)]
        self.assertAlmostEqual(picks.count("assisto_face") / 2000, 0.10, delta=0.03)
        self.assertAlmostEqual(picks.count("replicate") / 2000, 0.30, delta=0.04)
        self.assertEqual(picks, [PF.pick_provider(u, ps, conf) for u in range(2000)])   # stable

    def test_chain_falls_back_to_local_never_to_a_second_paid(self):
        self.assertEqual(PF.chain("replicate"), ["replicate", "local_worker"])
        self.assertEqual(PF.chain("local_worker"), ["local_worker"])

    def test_cap_cache_quota_cost_maths(self):
        self.assertTrue(PF.cap_allows(0.9, 0.1, 1.0))
        self.assertFalse(PF.cap_allows(0.95, 0.1, 1.0))
        self.assertTrue(PF.cap_allows(5, 0, 1.0))            # free runs never blocked
        self.assertNotEqual(PF.cache_key("h", "natural", "replicate", "v1"),
                            PF.cache_key("h", "strong", "replicate", "v1"))
        self.assertEqual(PF.fit_mp(4080, 3060, 2), PF.fit_mp(4080, 3060, 2))
        w, h = PF.fit_mp(4080, 3060, 2)
        self.assertLessEqual(w * h, 2_000_000)
        self.assertEqual(PF.fit_mp(800, 600, 2), (800, 600))  # never upscaled
        net = PF.plan_net_bdt(199, play_fee=0.15)
        q = PF.ultra_quota(plan_net_bdt_=net, budget_pct=25, cost_usd=0.064, usd_bdt=122)
        self.assertLessEqual(q * 0.064 * 122, net * 0.25 + 1e-6)   # cost never above the budget
        self.assertGreater(q, 0)
        self.assertEqual(PF.ultra_quota(plan_net_bdt_=net, budget_pct=25, cost_usd=0, usd_bdt=122), 0)
        self.assertEqual(PF.run_cost_usd(seconds=4, usd_per_second=0.000975), 0.0039)


# =========================================================================== look stage
class LookTests(SimpleTestCase):
    def _portrait(self):
        rng = np.random.default_rng(1)
        img = np.full((480, 400, 3), 0.25, np.float32)
        yy, xx = np.mgrid[0:480, 0:400]
        face = ((xx - 200) / 90.0) ** 2 + ((yy - 200) / 116.0) ** 2 < 1
        img[face] = (0.45, 0.30, 0.22)                    # darker skin tone
        img += rng.normal(0, 0.02, img.shape).astype(np.float32)
        faces = [{"box": [110, 84, 180, 232],             # big enough for skin smoothing
                  "pts": [[164, 170], [236, 170], [200, 210], [172, 256], [228, 256]]}]
        return np.clip(img, 0, 1), faces

    def test_presets_change_the_photo_and_never_whiten_the_face(self):
        img, faces = self._portrait()
        n, rn = LK.apply(img, faces, preset="natural")
        s, rs = LK.apply(img, faces, preset="strong")
        self.assertGreater(float(np.abs(n - img).mean()), 0.005)       # not "unchanged"
        self.assertGreater(float(np.abs(s - n).mean()), 0.002)                # presets differ
        m = LK.face_ellipses(img.shape, faces) > 0.6
        g = float(LK.luma(s).mean()) / float(LK.luma(img).mean())
        face_ratio = float(LK.luma(s)[m].mean()) / float(LK.luma(img)[m].mean())
        self.assertLessEqual(face_ratio, max(1.03, g) + 0.01)          # skin not lightened alone
        self.assertGreater(rn["skin_area"], 0)

    def test_bg_blur_only_with_a_usable_mask(self):
        img, faces = self._portrait()
        self.assertEqual(LK.bg_blur(img, None, LK.PRESETS["natural"]), (img, False))
        mask = LK.face_ellipses(img.shape, faces, grow=1.3)
        out, ok = LK.bg_blur(img, mask, LK.PRESETS["strong"])
        self.assertTrue(ok)
        corner = (slice(0, 30), slice(0, 30))
        self.assertLess(float(out[corner].std()), float(img[corner].std()))   # background smoother


# =========================================================================== stateful
REP = {"api_token": "r8_test", "upscale_version": "v-esrgan", "face_version": "",
       "usd_per_second": "0.000975", "cost_per_image_usd": "0.01"}
FAL = {"api_key": "fal_test", "usd_per_megapixel": "0.016", "scale": "2", "input_mp": "1"}


class _Resp:
    def __init__(self, status=200, j=None, content=b""):
        self.status_code, self._j, self.content = status, j or {}, content

    def json(self):
        return self._j


class _Base(APITestCase):
    def setUp(self):
        self.free = User.objects.create_user(name="F", phone="01000000401", password="pw")
        self.free.plan, self.free.trial_until = "free", None
        self.free.save()
        self.prem = User.objects.create_user(name="P", phone="01000000402", password="pw")
        self.prem.plan = "premium"
        self.prem.plan_until = timezone.now() + timedelta(days=30)
        self.prem.save()
        self.media = tempfile.mkdtemp()
        self._m = override_settings(MEDIA_ROOT=self.media, PHOTO_WORKER=True)
        self._m.enable()
        self.addCleanup(self._m.disable)
        self.addCleanup(shutil.rmtree, self.media, True)
        p = mock.patch.object(R, "status", side_effect=lambda f, lang="bn": {
            "ready": True, "where": "server", "cost_usd": 0.0, "needs": ""})
        p.start()
        self.addCleanup(p.stop)
        self.integ = {}
        p2 = mock.patch.object(PFN, "_integration", side_effect=lambda slug: self.integ.get(slug))
        p2.start()
        self.addCleanup(p2.stop)
        # local pipeline = a fast fake (the real one is exercised by tools/photo_bench)
        p3 = mock.patch.object(PFN, "local_enhance", side_effect=lambda raw, **k: (_jpg(80, 60), {"fake": 1}))
        self.local = p3.start()
        self.addCleanup(p3.stop)
        p4 = mock.patch.object(W, "_apply_face_lock", side_effect=lambda raw, out, rep: out)
        p4.start()
        self.addCleanup(p4.stop)

    def post(self, user, path, data, **extra):
        self.client.force_authenticate(user)
        return self.client.post("/api/v1/photo-studio/" + path, data, format="json", **extra)

    def job(self, user=None, ps=None, **opts):
        return PhotoStudioJob.objects.create(user=user or self.prem, feature="enhance_server",
                                             status="funded", funding="free",
                                             options={"strength": "natural", **opts})


class FreeEnhanceApiTests(_Base):
    def test_three_free_then_weekly_then_paywall_and_device_cannot_reset(self):
        hdr = {"HTTP_X_DEVICE_ID": "android-abcdef123456"}
        for i in range(3):
            r = self.post(self.free, "jobs", {"feature": "enhance_server", "via": "gift"}, **hdr)
            self.assertEqual(r.status_code, 201, r.content)
            j = PhotoStudioJob.objects.get(pk=r.json()["job"]["id"])
            self.assertEqual((j.status, j.funding, j.flags["free_kind"]), ("funded", "gift", "lifetime"))
            self.assertTrue(j.device_key)
        r = self.post(self.free, "jobs", {"feature": "enhance_server", "via": "gift"}, **hdr)
        self.assertEqual(PhotoStudioJob.objects.get(pk=r.json()["job"]["id"]).flags["free_kind"], "week")
        r = self.post(self.free, "jobs", {"feature": "enhance_server", "via": "gift"}, **hdr)
        self.assertEqual((r.status_code, r.json()["reason"]), (409, "week_free_used"))
        # a NEW account on the SAME phone (reinstall + new sign-up) gets nothing new
        other = User.objects.create_user(name="G", phone="01000000403", password="pw")
        other.plan, other.trial_until = "free", None
        other.save()
        r = self.post(other, "jobs", {"feature": "enhance_server", "via": "gift"}, **hdr)
        self.assertEqual(r.json()["reason"], "week_free_used")
        # ... while a different phone + account still has its own 3
        r = self.post(other, "jobs", {"feature": "enhance_server", "via": "gift"},
                      HTTP_X_DEVICE_ID="android-zzzzzz999999")
        self.assertEqual(r.status_code, 201)

    def test_failed_free_job_does_not_use_up_a_free_enhance(self):
        PhotoStudioJob.objects.create(user=self.free, feature="enhance_server", status="failed",
                                      funding="gift", flags={"free_kind": "lifetime"})
        self.assertEqual(PFN.enhance_usage(self.free)["lifetime_free"], 0)

    def test_ads_live_switches_to_two_ads(self):
        for _ in range(3):
            PhotoStudioJob.objects.create(user=self.free, feature="enhance_server", status="done",
                                          funding="gift", flags={"free_kind": "lifetime"},
                                          )
        PhotoStudioJob.objects.filter(funding="gift").update(created_at=timezone.now() - timedelta(days=9))
        with mock.patch.object(S, "_ad_units", return_value={"_configured": True}):
            r = self.post(self.free, "jobs", {"feature": "enhance_server", "via": "ads"})
        self.assertEqual(r.status_code, 201, r.content)
        self.assertEqual(r.json()["job"]["ads_required"], 2)

    def test_config_reports_capability_honestly(self):
        self.client.force_authenticate(self.free)
        j = self.client.get("/api/v1/photo-studio/config").json()
        self.assertEqual(j["enhance"]["providers"], [])
        self.assertFalse(j["enhance"]["ultra_hd"]["available"])
        self.assertFalse(j["face_restore"]["available"])
        self.assertEqual(j["features"]["ultra_hd"]["reason"], "premium_only")
        self.assertEqual(j["limits"]["free_enhance_lifetime"], 3)


class ProviderSwitchTests(_Base):
    def _rollout(self, **kw):
        # (Replicate / RunPod run Real-ESRGAN: these tests are the
        # owner-allowed world; RealEsrganFlagTests covers the default off)
        kw.setdefault("realesrgan_allowed", True)
        cfg = S._cfg()
        ps = dict(cfg.get("photo_studio") or {})
        ps.update(kw)
        return mock.patch.object(S, "ps_cfg", return_value=PS.normalize_cfg(ps))

    def test_default_is_local_worker_free_and_logged(self):
        out, cost, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual((rep["path"], cost), ("local_worker", 0.0))
        run = PhotoProviderRun.objects.get()
        self.assertEqual((run.provider, run.ok, run.cost_usd, run.cache_hit), ("local_worker", True, 0.0, False))

    def test_replicate_rollout_runs_mocked_http_logs_real_cost_and_caches(self):
        self.integ["photo_enhance_replicate"] = REP
        calls = []

        def post(url, **k):
            calls.append(url)
            return _Resp(201, {"status": "succeeded", "output": "https://replicate.delivery/x.jpg",
                               "metrics": {"predict_time": 4.0}})

        rq = mock.Mock(post=mock.Mock(side_effect=post),
                       get=mock.Mock(return_value=_Resp(200, content=_jpg(128, 96))))
        with self._rollout(rollout_replicate=100), mock.patch.object(PFN, "_http", return_value=rq), \
                mock.patch.object(LK, "apply", side_effect=lambda img, faces, **k: (img, {"preset": "natural"})):
            out, cost, rep = PFN.run_enhance(self.job(), _jpg())
            self.assertEqual(rep["path"], "replicate")
            self.assertAlmostEqual(cost, 0.0039, places=6)
            body = json.loads(rq.post.call_args.kwargs["data"])
            self.assertEqual(body["input"]["face_enhance"], False)     # GFPGAN never by default
            self.assertEqual(len(calls), 1)                            # no GFPGAN call (switch OFF)
            # same photo + preset again: cache hit, nothing paid, no HTTP
            out2, cost2, rep2 = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual((cost2, rep2.get("cache_hit")), (0.0, True))
        self.assertEqual(len(calls), 1)
        runs = list(PhotoProviderRun.objects.order_by("created_at"))
        self.assertEqual([(r.provider, r.cache_hit) for r in runs], [("replicate", False), ("replicate", True)])
        self.assertEqual(runs[0].model_version, "v-esrgan")

    def test_gfpgan_is_never_called_even_if_a_stored_switch_says_on(self):
        self.integ["photo_enhance_replicate"] = {**REP, "face_version": "v-gfpgan"}
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(201, {
            "status": "succeeded", "output": "https://replicate.delivery/x.jpg", "metrics": {"predict_time": 2}})),
            get=mock.Mock(return_value=_Resp(200, content=_jpg(128, 96))))
        fake_faces = [{"box": [20, 20, 40, 40], "pts": [[30, 30]] * 5, "score": 0.9}]
        with self._rollout(rollout_replicate=100, face_restore_gfpgan=True), \
                mock.patch.object(PFN, "_http", return_value=rq), \
                mock.patch("core.photo_models.server_model", return_value="/x.onnx"), \
                mock.patch("core.photo_facelock.detect", return_value=fake_faces), \
                mock.patch.object(R, "_session", return_value=None), \
                mock.patch.object(LK, "apply", side_effect=lambda img, faces, **k: (img, {})):
            _o, cost, rep = PFN.run_enhance(self.job(), _jpg())
        versions = [json.loads(c.kwargs["data"])["version"] for c in rq.post.call_args_list]
        self.assertEqual(versions, ["v-esrgan"])
        self.assertEqual(rep["steps"]["face_restore"], "off")
        self.assertFalse(json.loads(rq.post.call_args.kwargs["data"])["input"]["face_enhance"])
        self.assertNotIn("gfpgan", PhotoProviderRun.objects.get().model_version)

    def test_provider_error_falls_back_to_local_and_logs_both(self):
        self.integ["photo_enhance_replicate"] = REP
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(500)))
        with self._rollout(rollout_replicate=100), mock.patch.object(PFN, "_http", return_value=rq):
            _o, cost, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual((rep["path"], rep["fallback_from"], cost), ("local_worker", "replicate", 0.0))
        rows = list(PhotoProviderRun.objects.order_by("created_at").values_list("provider", "ok", "error"))
        self.assertEqual(rows, [("replicate", False, "http_500"), ("local_worker", True, "")])

    def test_unconfigured_rollout_is_ignored(self):
        with self._rollout(rollout_replicate=100):
            _o, _c, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual(rep["path"], "local_worker")

    def test_daily_spend_cap_makes_the_job_wait_in_the_queue(self):
        self.integ["photo_enhance_replicate"] = REP
        PhotoProviderRun.objects.create(provider="replicate", ok=True, cost_usd=0.995)
        rq = mock.Mock()
        with self._rollout(rollout_replicate=100), mock.patch.object(PFN, "_http", return_value=rq):
            job = self.job()
            W.enqueue(job, _jpg())
            W.loop(once=True)
        rq.post.assert_not_called()
        job.refresh_from_db()
        item = PhotoWorkItem.objects.get(job=job)
        self.assertEqual((job.status, job.flags["waiting"], item.state), ("queued", "spend_cap", "queued"))
        self.assertGreater(item.not_before, timezone.now())
        self.assertIsNone(W.claim("w2"))                    # not picked again before tomorrow
        self.client.force_authenticate(self.prem)
        j = self.client.get("/api/v1/photo-studio/jobs/%d" % job.pk).json()["job"]
        self.assertEqual(j["status"], "queued")

    def test_cap_fallback_local_switch(self):
        self.integ["photo_enhance_replicate"] = REP
        PhotoProviderRun.objects.create(provider="replicate", ok=True, cost_usd=1.0)
        with self._rollout(rollout_replicate=100, cap_fallback_local=True):
            _o, _c, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual((rep["path"], rep["fallback_from"]), ("local_worker", "replicate"))

    def test_runpod_contract(self):
        self.integ["photo_runpod"] = {"api_key": "rp", "endpoint_id": "ep1", "usd_per_second": "0.0002",
                                      "cost_per_image_usd": "0.004"}
        b64 = base64.b64encode(_jpg(100, 80)).decode()
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(200, {
            "status": "COMPLETED", "executionTime": 5000, "output": {"image_b64": b64}})))
        with self._rollout(rollout_runpod_serverless=100), mock.patch.object(PFN, "_http", return_value=rq):
            _o, cost, rep = PFN.run_enhance(self.job(strength="strong", bg_blur=True), _jpg())
        self.assertEqual(rep["path"], "runpod_serverless")
        self.assertAlmostEqual(cost, 0.001)
        url = rq.post.call_args.args[0]
        self.assertEqual(url, "https://api.runpod.ai/v2/ep1/runsync")
        body = json.loads(rq.post.call_args.kwargs["data"])["input"]
        self.assertEqual((body["preset"], body["bg_blur"], body["face_blend"]), ("strong", True, 0.7))

    def test_remote_image_must_be_https_and_decode(self):
        self.integ["photo_enhance_replicate"] = REP
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(201, {"status": "succeeded",
                                                               "output": "http://evil/x.jpg"})))
        with self._rollout(rollout_replicate=100), mock.patch.object(PFN, "_http", return_value=rq):
            _o, _c, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual(rep["path"], "local_worker")
        self.assertEqual(PhotoProviderRun.objects.filter(ok=False).get().error, "no_image_url")


class UltraTests(_Base):
    def test_ultra_quota_from_plan_price_and_run_on_fal(self):
        self.integ["photo_fal"] = FAL
        q = S.quote(self.prem, "ultra_hd")
        self.assertTrue(q["ok"], q)
        quota = q["quota"]
        self.assertGreater(quota, 0)
        from core import billing
        c = billing.cfg()
        net = PF.plan_net_bdt(c["plans"]["premium"]["price"], c.get("play_fee", 0.15), c.get("vat", 0),
                              c.get("gateway_fee", 0))
        self.assertLessEqual(quota * PFN.ultra_cost_usd(PFN.ultra_conf()) * c["usd_bdt"], net * 0.25 + 1e-6)
        self.assertEqual(S.quote(self.free, "ultra_hd")["reason"], "premium_only")
        r = self.post(self.prem, "jobs", {"feature": "ultra_hd"})
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(200, {"image": {"url": "https://fal.media/o.jpg"}})),
                       get=mock.Mock(return_value=_Resp(200, content=_jpg(200, 150))))
        with mock.patch.object(PFN, "_http", return_value=rq), override_settings(PHOTO_WORKER_INLINE=True):
            r = self.post(self.prem, "jobs/%d/run" % jid, {"image_b64": base64.b64encode(_jpg()).decode()})
        self.assertIn(r.status_code, (200, 202), r.content)
        job = PhotoStudioJob.objects.get(pk=jid)
        self.assertEqual(job.status, "done", job.error)
        self.assertEqual(rq.post.call_args.args[0], "https://fal.run/clarityai/crystal-upscaler")
        run = PhotoProviderRun.objects.get(provider="fal")
        self.assertGreater(run.cost_usd, 0)
        for _ in range(quota):
            PhotoStudioJob.objects.create(user=self.prem, feature="ultra_hd", status="done", funding="free")
        self.assertEqual(S.quote(self.prem, "ultra_hd")["reason"], "ultra_quota")


class OwnerProviderLogTests(TestCase):
    def test_owner_photo_page_shows_provider_log(self):
        from web.tests_o2_owner_admin import OwnerBase
        case = OwnerBase(methodName="setUp")
        case.setUp()
        case.ready()
        PhotoProviderRun.objects.create(provider="replicate", model_version="v-esrgan", ok=True,
                                        cost_usd=0.0039, seconds=4.2, preset="natural")
        r = case.c.get("/owner/photo?lang=en")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "v-esrgan")
        self.assertContains(r, 'id="providers"')
        self.assertContains(r, "Enhance providers")


# =========================================================================== photo-final 25 Oct
FAL_TOPAZ = {"api_key": "fal_test", "topaz_usd_per_image": "0.08"}
FAL_CRYSTAL = {"api_key": "fal_test", "crystal_usd_per_megapixel": "0.016"}
REAL_UNITS = {"_configured": True, "rewarded": "ca-app-pub-1234567890123456/1111111111"}


class RealEsrganFlagTests(_Base):
    """realesrgan_allowed (default False): no Real-ESRGAN use anywhere."""

    def test_default_off_everywhere(self):
        from core import photo_models as PM
        self.assertFalse(PS.normalize_cfg({})["realesrgan_allowed"])
        self.assertFalse(PM.realesrgan_allowed())
        self.integ["photo_enhance_replicate"] = REP
        self.integ["photo_runpod"] = {"api_key": "rp", "endpoint_id": "ep1",
                                      "cost_per_image_usd": "0.004"}
        self.assertIsNone(PFN.provider_conf("replicate"))
        self.assertIsNone(PFN.provider_conf("runpod_serverless"))
        with mock.patch.object(PM, "load_manifest", return_value={
                "licence_cleared": True, "version": "v1", "model": "realesr", "licence": "BSD-3",
                "scale": 4, "tile": 144, "pad": 8, "seg_side": 320,
                "files": [{"role": "upscale", "name": "r.onnx", "sha256": "0" * 64, "size": 9},
                          {"role": "server_face", "name": "y.onnx", "sha256": "1" * 64, "size": 9}]}):
            self.assertIsNone(PM.server_model("upscale"))
            self.assertTrue(PM.server_model("server_face"))
            m = PM.client_manifest()
            self.assertFalse(m["available"])               # the phone's AI step stays hidden
            self.assertEqual(m["files"], [])
        self.assertFalse(PFN.capability(self.free)["realesrgan"])

    def test_rollout_to_replicate_without_the_flag_stays_local_and_free(self):
        self.integ["photo_enhance_replicate"] = REP
        rq = mock.Mock()
        ps = PS.normalize_cfg({**(S._cfg().get("photo_studio") or {}), "rollout_replicate": 100})
        with mock.patch.object(S, "ps_cfg", return_value=ps), \
                mock.patch.object(PFN, "_http", return_value=rq):
            _o, cost, rep = PFN.run_enhance(self.job(), _jpg())
        rq.post.assert_not_called()
        self.assertEqual((rep["path"], cost), ("local_worker", 0.0))
        self.assertEqual(PhotoProviderRun.objects.get().model_version, "local-clean-2026.10")


class CleanPathTests(SimpleTestCase):
    @override_settings(PHOTO_WORKER=True)
    def test_enhance_and_old_restore_ready_without_real_esrgan(self):
        from core import photo_models as PM
        face_only = mock.patch.object(PM, "server_model",
                                      side_effect=lambda r: "/m/y.onnx" if r == "server_face" else None)
        with mock.patch.object(R, "_runtime_ok", return_value=True), face_only, \
                mock.patch.object(PM, "realesrgan_allowed", return_value=False):
            self.assertTrue(R.status("enhance_server", "en")["ready"])
            self.assertTrue(R.status("old_restore", "en")["ready"])
        face_only = mock.patch.object(PM, "server_model",
                                      side_effect=lambda r: "/m/y.onnx" if r == "server_face" else None)
        with mock.patch.object(R, "_runtime_ok", return_value=True), face_only, \
                mock.patch.object(PM, "realesrgan_allowed", return_value=True):
            self.assertFalse(R.status("enhance_server", "en")["ready"])   # allowed but not installed

    def test_clean_local_pipeline_upscales_without_any_weights(self):
        from PIL import Image
        out, steps = PFN.local_enhance(_jpg(64, 48), preset="natural",
                                       paths={"upscale": None, "server_face": None, "segment": None},
                                       faces=[])
        self.assertEqual(Image.open(io.BytesIO(out)).size, (128, 96))
        self.assertEqual(steps["upscaler"], "lanczos+unsharp")
        self.assertFalse(steps["global_ai"])

    def test_clean_upscale_keeps_colour(self):
        img = np.full((20, 30, 3), [0.6, 0.45, 0.35], dtype=np.float32)
        up = R.clean_upscale(img, 2)
        self.assertEqual(up.shape, (40, 60, 3))
        self.assertLess(float(np.abs(up.mean(axis=(0, 1)) - img.mean(axis=(0, 1))).max()), 0.02)

    def test_two_megapixel_cap(self):
        self.assertEqual(PF.fit_mp(4000, 3000, 2), (1632, 1224))
        self.assertEqual(PF.fit_mp(800, 600, 2), (800, 600))           # never upscaled here


class FalFaceProviderTests(_Base):
    def _ps(self, **kw):
        ps = dict(S._cfg().get("photo_studio") or {})
        ps.update(kw)
        return mock.patch.object(S, "ps_cfg", return_value=PS.normalize_cfg(ps))

    def test_off_until_owner_choice_and_key_and_price(self):
        self.integ["photo_fal"] = FAL_TOPAZ
        with self._ps(rollout_fal_face=100):
            self.assertIsNone(PFN.provider_conf("fal_face"))          # no owner choice yet
            self.assertNotIn("fal_face", PFN.configured())
            self.assertFalse(PFN.capability(self.free)["face_restore"])
        with self._ps(rollout_fal_face=100, fal_face_model="crystal"):
            self.assertIsNone(PFN.provider_conf("fal_face"))          # no Crystal price
        self.integ.pop("photo_fal")
        with self._ps(rollout_fal_face=100, fal_face_model="topaz"):
            self.assertIsNone(PFN.provider_conf("fal_face"))          # no key
        self.assertEqual(PS.normalize_cfg({"fal_face_model": "gfpgan"})["fal_face_model"], "")
        self.assertEqual(PS.validate_cfg({"fal_face_model": "codeformer"}), ["photo_studio_bad"])
        self.assertEqual(PS.validate_cfg({"fal_face_model": "topaz"}), [])

    def test_topaz_runs_identity_safe_logs_flat_cost_and_caches(self):
        self.integ["photo_fal"] = FAL_TOPAZ
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(200, {"image": {"url": "https://fal.media/t.jpg"}})),
                       get=mock.Mock(return_value=_Resp(200, content=_jpg(128, 96))))
        with self._ps(rollout_fal_face=100, fal_face_model="topaz"), \
                mock.patch.object(PFN, "_http", return_value=rq), \
                mock.patch("core.photo_models.server_model", return_value=None), \
                mock.patch.object(LK, "apply", side_effect=lambda img, faces, **k: (img, {})):
            cap = PFN.capability(self.free)
            self.assertEqual((cap["face_restore"], cap["face_provider"]), (True, "topaz"))
            _o, cost, rep = PFN.run_enhance(self.job(strength="strong"), _jpg())
            self.assertEqual((rep["path"], cost), ("fal_face", 0.08))
            self.assertEqual(rq.post.call_args.args[0], "https://fal.run/fal-ai/topaz/upscale/image")
            body = json.loads(rq.post.call_args.kwargs["data"])
            self.assertEqual((body["model"], body["face_enhancement"], body["face_enhancement_creativity"],
                              body["face_enhancement_strength"], body["upscale_factor"]),
                             ("Standard V2", True, 0, 0.7, 2))
            self.assertTrue(body["image_url"].startswith("data:image/jpeg;base64,"))
            _o2, cost2, rep2 = PFN.run_enhance(self.job(strength="strong"), _jpg())
        self.assertEqual((cost2, rep2.get("cache_hit")), (0.0, True))
        self.assertEqual(rq.post.call_count, 1)                   # a cache hit costs nothing
        runs = list(PhotoProviderRun.objects.order_by("created_at").values_list(
            "provider", "cost_usd", "cache_hit", "preset"))
        self.assertEqual(runs, [("fal_face", 0.08, False, "strong"), ("fal_face", 0.0, True, "strong")])

    def test_crystal_cost_per_real_megapixel_and_natural_creativity_zero(self):
        self.integ["photo_fal"] = FAL_CRYSTAL
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(200, {"images": [{"url": "https://fal.media/c.jpg"}]})),
                       get=mock.Mock(return_value=_Resp(200, content=_jpg(1000, 1000))))
        with self._ps(rollout_fal_face=100, fal_face_model="crystal"), \
                mock.patch.object(PFN, "_http", return_value=rq), \
                mock.patch("core.photo_models.server_model", return_value=None), \
                mock.patch.object(LK, "apply", side_effect=lambda img, faces, **k: (img, {})):
            self.assertAlmostEqual(PFN.provider_conf("fal_face")["est"], 2 * 4 * 0.016)
            _o, cost, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual(rq.post.call_args.args[0], "https://fal.run/clarityai/crystal-upscaler")
        body = json.loads(rq.post.call_args.kwargs["data"])
        self.assertEqual((body["scale_factor"], body["creativity"]), (2, 0))
        self.assertAlmostEqual(cost, 0.016, places=6)              # 1.0 MP real output

    def test_fal_error_falls_back_to_local_free(self):
        self.integ["photo_fal"] = FAL_TOPAZ
        rq = mock.Mock(post=mock.Mock(return_value=_Resp(503)))
        with self._ps(rollout_fal_face=100, fal_face_model="topaz"), \
                mock.patch.object(PFN, "_http", return_value=rq):
            _o, cost, rep = PFN.run_enhance(self.job(), _jpg())
        self.assertEqual((rep["path"], rep["fallback_from"], cost), ("local_worker", "fal_face", 0.0))
        rows = list(PhotoProviderRun.objects.order_by("created_at").values_list("provider", "ok", "error"))
        self.assertEqual(rows, [("fal_face", False, "http_503"), ("local_worker", True, "")])

    def test_spend_cap_counts_fal_face_and_queues(self):
        self.integ["photo_fal"] = FAL_TOPAZ
        PhotoProviderRun.objects.create(provider="fal_face", ok=True, cost_usd=0.95)
        rq = mock.Mock()
        with self._ps(rollout_fal_face=100, fal_face_model="topaz"), \
                mock.patch.object(PFN, "_http", return_value=rq):
            with self.assertRaises(PFN.SpendCapWait):
                PFN.run_enhance(self.job(), _jpg())
        rq.post.assert_not_called()

    def test_rollout_split_between_paid_providers_is_stable(self):
        ps = PS.normalize_cfg({"rollout_fal_face": 30, "rollout_replicate": 20})
        picks = [PF.pick_provider(i, ps, {"fal_face", "replicate"}) for i in range(2000)]
        self.assertEqual(picks, [PF.pick_provider(i, ps, {"fal_face", "replicate"}) for i in range(2000)])
        share = {p: picks.count(p) / 2000 for p in set(picks)}
        self.assertAlmostEqual(share["fal_face"], 0.30, delta=0.05)
        self.assertAlmostEqual(share["replicate"], 0.20, delta=0.05)
        self.assertAlmostEqual(share["local_worker"], 0.50, delta=0.05)


class AdsLiveGateTests(_Base):
    """Rewarded unlocks only through Google's SSV, and never on TEST ids."""

    def test_test_ids_never_issue_an_ad_ticket_credits_still_unlock(self):
        with mock.patch.object(S, "_ad_units", return_value={"_configured": False}):
            q = S.quote(self.free, "enhance_hd")
            self.assertEqual(q.get("ads_off"), "test_ids")
            self.assertTrue(all(o.get("live") is False for o in q["options"] if o["via"] == "ads"))
            # released apps create the free export job as an ads job ...
            r = self.post(self.free, "jobs", {"feature": "enhance_hd", "via": "ads"})
            self.assertEqual(r.status_code, 201, r.content)
            jid = r.json()["job"]["id"]
            # ... but no ad ticket exists on test ids (Google's SSV never verifies them)
            r = self.post(self.free, "jobs/%d/ad-ticket" % jid, {}, HTTP_ACCEPT_LANGUAGE="bn")
            self.assertEqual((r.status_code, r.json()["reason"]), (409, "ads_not_live"))
            self.assertTrue(r.json()["message"])
            self.assertFalse(PhotoAdTicket.objects.filter(job_id=jid).exists())
            self.assertEqual(PhotoStudioJob.objects.get(pk=jid).status, "awaiting_funds")
            # credits still unlock it (the honest route)
            User.objects.filter(pk=self.free.pk).update(ai_credits=50)
            r = self.post(self.free, "jobs/%d/fund" % jid, {})
            self.assertEqual(r.status_code, 200, r.content)
            self.assertEqual(PhotoStudioJob.objects.get(pk=jid).status, "funded")
        with mock.patch.object(S, "_ad_units", return_value=REAL_UNITS):
            jid2 = self.post(self.free, "jobs", {"feature": "enhance_hd", "via": "ads"}).json()["job"]["id"]
            r = self.post(self.free, "jobs/%d/ad-ticket" % jid2, {})
        self.assertEqual(r.status_code, 201)
        self.assertEqual(PhotoStudioJob.objects.get(pk=jid2).status, "awaiting_funds")  # SSV only

    def test_after_three_free_enhances_test_ids_mean_weekly_free_not_ads(self):
        for _ in range(3):
            PhotoStudioJob.objects.create(user=self.free, feature="enhance_server", status="done",
                                          funding="gift", flags={"free_kind": "lifetime"})
        with mock.patch.object(S, "_ad_units", return_value={"_configured": False}):
            q = S.quote(self.free, "enhance_server")
        self.assertEqual((q["free_kind"], q["options"]), ("week", [{"via": "gift", "trial": False}]))
        with mock.patch.object(S, "_ad_units", return_value=REAL_UNITS):
            q = S.quote(self.free, "enhance_server")
        self.assertEqual(q["options"], [{"via": "ads", "ads": 2, "trial": False}])
        self.assertEqual(q["left_today"], 2)

    def test_pure_rule_marks_ads_not_live_on_test_ids(self):
        q = PS.funding_options(feature="enhance_hd", plan="free", cost_usd=0, usd_bdt=120,
                               table_credits=0, net_floor=0.6, credit_bdt=1.0, ps_cfg={},
                               ad_rewards={"ecpm_bdt": 30}, ads_live=False)
        self.assertEqual([(o["via"], o.get("live", True)) for o in q["options"]],
                         [("ads", False), ("credits", True)])


class FreeAiImagePerDeviceTests(_Base):
    def test_lifetime_free_ai_images_counted_per_account_and_device(self):
        hdr = {"HTTP_X_DEVICE_ID": "android-dev000111222"}
        with mock.patch.object(S, "_active_provider", return_value=("photo_gemini", {}, 0.04)):
            for _ in range(2):
                r = self.post(self.free, "jobs", {"feature": "prompt_edit", "via": "gift",
                                                  "prompt": "make the sky blue"}, **hdr)
                self.assertEqual(r.status_code, 201, r.content)
            other = User.objects.create_user(name="H", phone="01000000404", password="pw")
            other.plan, other.trial_until = "free", None
            other.save()
            r = self.post(other, "jobs", {"feature": "prompt_edit", "via": "gift",
                                          "prompt": "make the sky blue"}, **hdr)
            self.assertEqual(r.status_code, 409, r.content)            # same phone: used up
            r = self.post(other, "jobs", {"feature": "prompt_edit", "via": "gift",
                                          "prompt": "make the sky blue"},
                          HTTP_X_DEVICE_ID="android-dev999888777")
            self.assertEqual(r.status_code, 201, r.content)            # own phone: own gifts


class OwnerAdminPhotoFinalTests(TestCase):
    def test_owner_sets_face_model_and_realesrgan_with_labels(self):
        from web.tests_o2_owner_admin import OwnerBase
        from core import billing
        case = OwnerBase(methodName="setUp")
        case.setUp()
        case.ready()
        r = case.c.get("/owner/ads?lang=bn")
        self.assertEqual(r.status_code, 200)
        self.assertContains(r, "photo_studio.fal_face_model")
        self.assertContains(r, "Real-ESRGAN weights চালু")
        cfg = billing.cfg()
        data = {"action": "settings", "reason": "owner choice"}
        for blk in ("ad_rewards", "photo_studio"):
            for k, v in (cfg.get(blk) or {}).items():
                if isinstance(v, bool):
                    if v:
                        data["%s.%s" % (blk, k)] = "on"
                elif isinstance(v, (int, float)):
                    data["%s.%s" % (blk, k)] = str(v)
        data["photo_studio.fal_face_model"] = "topaz"
        data["photo_studio.rollout_fal_face"] = "10"
        data["photo_studio.realesrgan_allowed"] = "on"
        r = case.post("/owner/ads", data)
        self.assertEqual(r.status_code, 302, r.content[:400])
        ps = billing.cfg()["photo_studio"]
        self.assertEqual((ps["fal_face_model"], ps["rollout_fal_face"], ps["realesrgan_allowed"]),
                         ("topaz", 10, True))
        r = case.c.get("/owner/photo?lang=en")
        self.assertContains(r, "Face upscaler")
