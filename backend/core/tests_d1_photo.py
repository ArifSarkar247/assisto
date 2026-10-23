"""d1-photo: Photo Studio heavy restore jobs + manifest roles.

* manifest roles: upscale (first) + segment (phone) + server_colorize (server
  only, never listed for / served to phones);
* photo_restore maths with FAKE ONNX sessions (no onnxruntime needed): Lab
  round trip, colorize keeps the photo's lightness, tiling parity (x4 tiles ==
  x4 of the whole photo), face-lock merge, scratch cleanup, old-photo pipeline;
* availability: hidden until the runtime + model (server) or the GPU key +
  cost (deblur) are really there; face restoration is never offered;
* money: priced before work (Profit Guard), funds kept on failure / busy,
  refunded after 3 real failures, cost booked only on a real result;
* GPU adapter request shape with a mocked HTTP layer.
"""
import base64
import hashlib
import io
import json
import os
import shutil
import tempfile
from datetime import timedelta
from unittest import mock

from django.test import SimpleTestCase, override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from core import photo_models as PM
from core import photo_restore as R
from core import photo_studio_service as S
from core.logic import photo_studio as PS
from core.models import PhotoStudioJob, User

try:
    import numpy as np
    from PIL import Image
    HAVE_NP = True
except Exception:  # pragma: no cover
    HAVE_NP = False

BLOB = bytes(range(256)) * 8


def _manifest(d, files, cleared=True, **extra):
    m = {"version": "2026.10.2", "kind": "upscale", "model": "realesr-general-x4v3",
         "licence": "BSD-3-Clause", "licence_cleared": cleared, "scale": 4, "tile": 144,
         "pad": 8, "files": []}
    for role, name in files:
        with open(os.path.join(d, name), "wb") as f:
            f.write(BLOB)
        m["files"].append({"role": role, "name": name, "size": len(BLOB),
                           "sha256": hashlib.sha256(BLOB).hexdigest()})
    m.update(extra)
    with open(os.path.join(d, "manifest.json"), "w") as f:
        json.dump(m, f)


class _Dir:
    def setUp(self):
        super().setUp()
        self.d = tempfile.mkdtemp()
        self._o = override_settings(PHOTO_MODEL_DIR=self.d)
        self._o.enable()

    def tearDown(self):
        self._o.disable()
        shutil.rmtree(self.d, ignore_errors=True)
        super().tearDown()


class ManifestRoleTests(_Dir, SimpleTestCase):
    def test_phone_gets_upscale_and_segment_never_the_server_model(self):
        _manifest(self.d, [("upscale", "r.onnx"), ("segment", "u2netp.onnx"),
                           ("server_colorize", "ddc.onnx")], seg_side=320)
        c = PM.client_manifest()
        self.assertTrue(c["available"])
        self.assertEqual([f["role"] for f in c["files"]], ["upscale", "segment"])
        self.assertEqual(c["files"][0]["name"], "r.onnx")   # old apps take the first
        self.assertEqual(c["seg_side"], 320)
        self.assertEqual(PM.server_model("server_colorize"), os.path.join(self.d, "ddc.onnx"))

    def test_server_model_is_not_downloadable(self):
        _manifest(self.d, [("upscale", "r.onnx"), ("server_colorize", "ddc.onnx")])
        r = self.client.get("/api/v1/photo-studio/model/ddc.onnx")
        self.assertEqual(r.status_code, 404)
        r = self.client.get("/api/v1/photo-studio/model/r.onnx")
        self.assertEqual(r.status_code, 200)

    def test_upscale_must_be_first_and_roles_known(self):
        _manifest(self.d, [("segment", "u2netp.onnx"), ("upscale", "r.onnx")])
        self.assertIsNone(PM.load_manifest())
        _manifest(self.d, [("upscale", "r.onnx"), ("face_restore", "gfpgan.onnx")])
        self.assertIsNone(PM.load_manifest())

    def test_not_cleared_hides_server_model_too(self):
        _manifest(self.d, [("upscale", "r.onnx"), ("server_colorize", "ddc.onnx")], cleared=False)
        self.assertIsNone(PM.server_model("server_colorize"))


# =========================================================================== maths
class _NearestX4:
    """Fake Real-ESRGAN: nearest x4 of a FIXED 1x3x144x144 input."""
    def __init__(self, side=144):
        self.side = side
        self.calls = 0

    def get_inputs(self):
        return [mock.Mock(name="input", shape=[1, 3, self.side, self.side])]

    def run(self, _out, feeds):
        x = list(feeds.values())[0]
        assert x.shape == (1, 3, self.side, self.side), x.shape
        self.calls += 1
        return [x.repeat(4, axis=2).repeat(4, axis=3)]


class _FakeColor:
    """Fake DDColor: spatially varying ab (like real colours: not a function
    of the lightness) at 512x512."""
    def get_inputs(self):
        return [mock.Mock(name="input", shape=[1, 3, 512, 512])]

    def run(self, _out, feeds):
        x = list(feeds.values())[0]
        assert x.shape == (1, 3, 512, 512)
        yy, xx = np.mgrid[0:512, 0:512].astype(np.float32)
        ab = np.zeros((1, 2, 512, 512), dtype=np.float32)
        ab[0, 0] = 25.0 * np.sin(xx / 40.0)
        ab[0, 1] = 30.0 * np.cos(yy / 50.0)
        return [ab]


def _grey_photo(w=300, h=200, seed=3):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w]
    v = 0.5 + 0.3 * np.sin(xx / 13.0) * np.cos(yy / 9.0) + rng.normal(0, 0.02, (h, w))
    return np.repeat(np.clip(v, 0, 1)[..., None], 3, axis=-1).astype(np.float32)


def _enc(rgb, fmt="PNG"):
    buf = io.BytesIO()
    Image.fromarray((np.clip(rgb, 0, 1) * 255).astype(np.uint8)).save(buf, fmt)
    return buf.getvalue()


class RestoreMathTests(SimpleTestCase):
    def setUp(self):
        if not HAVE_NP:
            self.skipTest("numpy/Pillow not installed")

    def test_lab_round_trip(self):
        x = np.random.default_rng(1).random((40, 40, 3)).astype(np.float32)
        self.assertLess(float(np.abs(R.lab_to_rgb(R.rgb_to_lab(x)) - x).max()), 1e-3)
        lab = R.rgb_to_lab(np.ones((1, 1, 3), dtype=np.float32))
        self.assertAlmostEqual(float(lab[0, 0, 0]), 100.0, places=2)

    def test_tiling_parity_with_the_phone(self):
        """x4 tiles of 128 (+8 mirrored context) == nearest x4 of the whole photo."""
        for (w, h) in ((300, 200), (128, 128), (40, 30), (257, 129)):
            img = np.random.default_rng(w).random((h, w, 3)).astype(np.float32)
            s = _NearestX4()
            out = R.upscale_x4(img, s)
            ref = img.repeat(4, axis=0).repeat(4, axis=1)
            self.assertEqual(out.shape, ref.shape)
            self.assertLess(float(np.abs(out - ref).max()), 1e-6, (w, h))
            self.assertEqual(s.calls, -(-w // 128) * -(-h // 128))

    def test_wrong_model_shape_refused(self):
        with self.assertRaises(R.RestoreError):
            R.upscale_x4(np.zeros((50, 50, 3), np.float32), _NearestX4(side=160))
        with self.assertRaises(R.RestoreError):
            R.colorize_rgb(np.zeros((50, 50, 3), np.float32), _NearestX4())

    def test_colorize_keeps_the_photo_lightness(self):
        g = _grey_photo()
        out = R.colorize_rgb(g, _FakeColor())
        self.assertEqual(out.shape, g.shape)
        dl = np.abs(R.rgb_to_lab(out)[..., 0] - R.rgb_to_lab(g)[..., 0])
        self.assertLess(float(np.mean(dl)), 1.0)     # gamut clipping only
        self.assertFalse(R.is_grey(out))
        self.assertTrue(R.is_grey(g))
        # a sepia print (colour = a function of lightness) counts as monochrome
        y = R.luma_of(g)
        sepia = np.stack([y + 0.06, y * 0.9 + 0.04, y * 0.72 + 0.02], -1).clip(0, 1)
        self.assertTrue(R.is_grey(sepia))

    def test_face_lock_merge(self):
        base = np.full((100, 100, 3), 0.5, np.float32)
        ai = np.full((100, 100, 3), 0.7, np.float32)
        out = R.merge_keep_faces(ai, base, [[0.3, 0.3, 0.4, 0.4]])
        # outside faces: full AI luminance detail; face centre: only 25 %
        self.assertAlmostEqual(float(out[5, 5, 0]), 0.7, places=4)
        self.assertAlmostEqual(float(out[50, 50, 0]), 0.5 + 0.2 * 0.25, places=4)
        # colours come from base (grey stays grey)
        self.assertAlmostEqual(float(out[5, 5, 0]), float(out[5, 5, 2]), places=5)

    def test_scratch_cleanup_removes_thin_lines_only(self):
        g = _grey_photo(200, 150)
        damaged = g.copy()
        damaged[:, 77] = 1.0          # a white vertical scratch
        damaged[40, 20:180] = 0.0     # a dark horizontal crack
        fixed, share = R.scratch_cleanup(damaged)
        self.assertGreater(share, 0)
        err_before = float(np.abs(damaged - g)[:, 77].mean())
        err_after = float(np.abs(fixed - g)[:, 77].mean())
        self.assertLess(err_after, err_before * 0.3)
        clean, share2 = R.scratch_cleanup(g)
        self.assertLess(float(np.abs(clean - g).mean()), 0.01)

    def test_process_old_restore_end_to_end_with_fakes(self):
        g = _grey_photo(300, 200)
        sessions = {"u": _NearestX4(), "c": _FakeColor()}
        png, info = R.process("old_restore", _enc(g), {"upscale": "u", "server_colorize": "c"},
                              faces=[[0.3, 0.2, 0.4, 0.5]], colorize=True,
                              session=lambda p: sessions[p])
        im = Image.open(io.BytesIO(png))
        self.assertEqual(im.size, (1200, 800))
        self.assertTrue(info["colorized"])
        png2, info2 = R.process("old_restore", _enc(g), {"upscale": "u", "server_colorize": "c"},
                                colorize=False, session=lambda p: sessions[p])
        self.assertFalse(info2["colorized"])
        with self.assertRaises(R.RestoreError):
            R.process("old_restore", _enc(g), {}, session=lambda p: sessions[p])
        with self.assertRaises(R.RestoreError):
            R.process("old_restore", b"not an image", {"upscale": "u"}, session=lambda p: sessions[p])

    def test_process_colorize(self):
        g = _grey_photo(640, 480)
        png, info = R.process("colorize", _enc(g, "JPEG"), {"server_colorize": "c"},
                              session=lambda p: _FakeColor())
        self.assertEqual(Image.open(io.BytesIO(png)).size, (640, 480))


# =========================================================================== status
@override_settings(PHOTO_WORKER=True)
class RestoreStatusTests(_Dir, SimpleTestCase):
    def test_server_features_need_runtime_and_model(self):
        with mock.patch.object(R, "_runtime_ok", return_value=False):
            st = R.status("colorize", "en")
            self.assertFalse(st["ready"])
            self.assertIn("onnxruntime", st["needs"])
        with mock.patch.object(R, "_runtime_ok", return_value=True):
            self.assertFalse(R.status("colorize", "en")["ready"])   # no model yet
            _manifest(self.d, [("upscale", "r.onnx"), ("server_colorize", "ddc.onnx")])
            self.assertTrue(R.status("colorize", "en")["ready"])
            self.assertTrue(R.status("old_restore", "en")["ready"])

    def test_deblur_needs_key_version_and_cost(self):
        with mock.patch.object(R, "_gpu_conf", return_value=None):
            self.assertFalse(R.status("deblur", "bn")["ready"])
        with mock.patch.object(R, "_gpu_conf", return_value={"api_token": "t", "deblur_version": "v"}):
            self.assertFalse(R.status("deblur", "en")["ready"])      # no cost -> never unpriced
        with mock.patch.object(R, "_gpu_conf", return_value={
                "api_token": "t", "deblur_version": "v", "cost_per_run_usd": "0.02"}):
            st = R.status("deblur", "en")
            self.assertTrue(st["ready"])
            self.assertEqual(st["cost_usd"], 0.02)

    def test_worker_required(self):
        with override_settings(PHOTO_WORKER=False):
            st = R.status("colorize", "en")
            self.assertFalse(st["ready"])
            self.assertIn("worker", st["needs"])

    def test_busy_lock_and_memory_gate(self):
        d = tempfile.mkdtemp()
        try:
            with override_settings(MEDIA_ROOT=d):
                with R._heavy_lock():
                    with self.assertRaises(R.RestoreBusy):
                        with R._heavy_lock(wait_s=0.3):
                            pass
        finally:
            shutil.rmtree(d, ignore_errors=True)


class GpuAdapterTests(SimpleTestCase):
    def test_replicate_request_shape_and_honest_failures(self):
        calls = {}

        class Resp:
            def __init__(self, code, js=None, content=b""):
                self.status_code, self._js, self.content = code, js, content

            def json(self):
                return self._js

        class Rq:
            def post(self, url, timeout, headers, data):
                calls["url"], calls["headers"], calls["body"] = url, headers, json.loads(data)
                return Resp(201, {"status": "succeeded", "output": "https://replicate.delivery/x.png"})

            def get(self, url, timeout):
                return Resp(200, content=b"PNGDATA")

        with mock.patch.object(R, "_http", return_value=Rq()):
            out = R.gpu_deblur(b"img", {"api_token": "tok", "deblur_version": "abc"})
        self.assertEqual(out, b"PNGDATA")
        self.assertEqual(calls["body"]["version"], "abc")
        self.assertEqual(calls["body"]["input"]["task_type"], R.DEFAULT_DEBLUR_TASK)
        self.assertTrue(calls["body"]["input"]["image"].startswith("data:image/jpeg;base64,"))
        self.assertEqual(calls["headers"]["Authorization"], "Bearer tok")

        class Fail(Rq):
            def post(self, *a, **k):
                return Resp(200, {"status": "processing"})
        with mock.patch.object(R, "_http", return_value=Fail()):
            with self.assertRaises(R.RestoreError):
                R.gpu_deblur(b"img", {"api_token": "tok", "deblur_version": "abc"})
        with self.assertRaises(R.RestoreError):
            R.gpu_deblur(b"img", {"api_token": "tok"})


# =========================================================================== money + API
def _png_bytes():
    from PIL import Image as _I
    b = io.BytesIO()
    _I.new("RGB", (64, 48), (120, 120, 120)).save(b, "PNG")
    return b.getvalue()


@override_settings(PHOTO_WORKER=True, PHOTO_WORKER_INLINE=True)
class RestoreApiTests(APITestCase):
    def setUp(self):
        self.prem = User.objects.create_user(name="P", phone="01000000201", password="pw")
        self.prem.plan = "premium"
        self.prem.plan_until = timezone.now() + timedelta(days=30)
        self.prem.save()
        from core import billing
        billing.grant_monthly_pool(self.prem)
        self.prem.refresh_from_db()
        self.free = User.objects.create_user(name="F", phone="01000000202", password="pw")
        self.free.plan = "free"
        self.free.trial_until = None
        self.free.save()
        self.media = tempfile.mkdtemp()
        self._m = override_settings(MEDIA_ROOT=self.media)
        self._m.enable()

    def tearDown(self):
        self._m.disable()
        shutil.rmtree(self.media, ignore_errors=True)

    def ready(self, on=True, where="server", cost=0.0):
        def st(feature, lang="bn"):
            return {"ready": on, "where": "gpu" if feature == "deblur" else where,
                    "cost_usd": cost, "needs": "" if on else "x"}
        p = mock.patch.object(R, "status", side_effect=st)
        p.start()
        self.addCleanup(p.stop)

    def test_hidden_until_ready_and_face_restore_never(self):
        self.ready(on=False)
        self.client.force_authenticate(self.free)
        j = self.client.get("/api/v1/photo-studio/config").json()
        for f in ("deblur", "colorize", "old_restore"):
            self.assertFalse(j["features"][f]["ok"])
            self.assertEqual(j["features"][f]["reason"], "provider_missing")
            self.assertFalse(j["restore"][f]["ready"])
        self.assertFalse(j["face_restore"]["available"])

    def test_priced_never_a_loss(self):
        self.ready(on=True)
        self.client.force_authenticate(self.free)
        from core import billing
        c = billing.cfg()
        for f in ("colorize", "old_restore", "deblur"):
            q = S.quote(self.free, f, c)
            self.assertTrue(q["ok"], (f, q))
            self.assertGreater(q["cost_bdt"], 0)                  # never "free"
            for o in q["options"]:
                rev = PS.option_revenue_bdt(
                    o, ad_value=PS.ad_value_bdt(c.get("photo_studio"), c["ad_rewards"]),
                    share=0.70, credit_bdt=c["credit_bdt"])
                self.assertGreaterEqual(rev + 1e-9, q["cost_bdt"], (f, o))

    def test_run_success_books_cost_and_keeps_colour_choice(self):
        self.ready(on=True)
        self.client.force_authenticate(self.prem)
        r = self.client.post("/api/v1/photo-studio/jobs",
                             {"feature": "old_restore", "restore_colorize": False}, format="json")
        self.assertEqual(r.status_code, 201, r.content)
        jid = r.json()["job"]["id"]
        out = _png_bytes()
        with mock.patch.object(R, "process", return_value=(out, {"colorized": False})) as run, \
                mock.patch("core.photo_worker._apply_face_lock",
                           side_effect=lambda raw, o, rep: (rep.update(face_lock={
                               "faces": 1, "kept": 1, "restored": 0, "min_score": 0.93,
                               "action": "kept", "method": "auraface"}) or o)):
            r = self.client.post("/api/v1/photo-studio/jobs/%d/run" % jid,
                                 {"image_b64": base64.b64encode(_png_bytes()).decode(),
                                  "face_boxes": [[0.3, 0.2, 0.3, 0.4]]}, format="json")
        self.assertEqual(r.status_code, 200, r.content)
        self.assertFalse(run.call_args.kwargs["colorize"])
        self.assertEqual(run.call_args.kwargs["faces"], [[0.3, 0.2, 0.3, 0.4]])
        job = PhotoStudioJob.objects.get(pk=jid)
        self.assertEqual(job.status, "done")
        self.assertEqual(job.provider, "server_cpu")
        self.assertEqual(r.json()["job"]["face_lock"]["action"], "kept")
        self.assertEqual(job.work.state, "done")
        self.assertGreater(job.cost_bdt, 0)
        self.assertTrue(job.flags["ai_edited"])
        self.assertTrue(r.json()["job"]["preview"])
        u = self.client.post("/api/v1/photo-studio/jobs/%d/unlock" % jid, {"kind": "save"},
                             format="json")
        self.assertEqual(u.status_code, 200)

    def test_failure_keeps_funds_busy_is_free_then_refund(self):
        self.ready(on=True)
        self.client.force_authenticate(self.prem)
        r = self.client.post("/api/v1/photo-studio/jobs", {"feature": "colorize"}, format="json")
        jid = r.json()["job"]["id"]
        self.prem.refresh_from_db()
        before = self.prem.ai_credits
        img = {"image_b64": base64.b64encode(_png_bytes()).decode()}
        with mock.patch.object(R, "process", side_effect=R.RestoreBusy("busy")):
            r = self.client.post("/api/v1/photo-studio/jobs/%d/run" % jid, img, format="json")
        self.assertEqual(r.status_code, 502)
        self.assertEqual(PhotoStudioJob.objects.get(pk=jid).runs, 0)   # busy is not an attempt
        self.assertEqual(PhotoStudioJob.objects.get(pk=jid).status, "funded")
        with mock.patch.object(R, "process", side_effect=R.RestoreError("ort_run:Fail")):
            for _ in range(3):
                r = self.client.post("/api/v1/photo-studio/jobs/%d/run" % jid, img, format="json")
                self.assertEqual(r.status_code, 502)
        job = PhotoStudioJob.objects.get(pk=jid)
        self.assertEqual(job.status, "failed")
        self.assertEqual(job.cost_bdt, 0)
        self.prem.refresh_from_db()
        self.assertEqual(self.prem.ai_credits, before + job.credits_charged)
