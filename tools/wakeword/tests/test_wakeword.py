"""Unit tests for the wake-word pipeline on tiny SYNTHETIC data (no downloads,
no TTS, seconds of CPU). Run:  python3 -m unittest discover tools/wakeword/tests
"""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from ww import audio  # noqa: E402
from ww.detector import Decider, count_triggers  # noqa: E402
from ww.evaluate import false_accepts, pick_thresholds  # noqa: E402
from ww.model import WakeNet  # noqa: E402

HAS_ONNX = all(importlib.util.find_spec(m) for m in ("onnx", "onnxruntime"))


class DeciderTests(unittest.TestCase):
    # Same cases as app/test/va_wake_logic_test.dart and OwwEngine.kt.
    def test_threshold(self):
        d = Decider(threshold=0.5)
        self.assertFalse(d.feed(0.49))
        self.assertTrue(d.feed(0.5))

    def test_patience_two_frames(self):
        d = Decider(threshold=0.5, patience=2)
        self.assertFalse(d.feed(0.9))
        self.assertFalse(d.feed(0.1))  # run broken
        self.assertFalse(d.feed(0.9))
        self.assertTrue(d.feed(0.9))

    def test_cooldown_blocks_double_trigger(self):
        d = Decider(threshold=0.5, cooldown_ms=2000)
        self.assertTrue(d.feed(0.9, 0))
        self.assertFalse(d.feed(0.9, 80))
        self.assertFalse(d.feed(0.9, 1999))
        self.assertTrue(d.feed(0.9, 2000))

    def test_levels(self):
        th = {"low": 0.8, "normal": 0.6, "high": 0.4}
        self.assertEqual(Decider.for_level("low", th).patience, 2)
        self.assertEqual(Decider.for_level("high", th).threshold, 0.4)
        self.assertEqual(Decider.for_level("bogus", th).threshold, 0.6)

    def test_count_and_fa_per_hour(self):
        sc = np.zeros(45000)  # 1 hour of 80 ms frames
        sc[[100, 101, 5000, 30000]] = 0.95
        th = {"low": 0.97, "normal": 0.9, "high": 0.5}
        self.assertEqual(count_triggers(sc, Decider(threshold=0.9)), 3)  # 100/101 = one wake
        fa = false_accepts(sc, th, 1.0)
        self.assertEqual(fa["normal"]["false_accepts"], 3)
        self.assertEqual(fa["normal"]["per_10h"], 30.0)
        self.assertEqual(fa["low"]["false_accepts"], 0)


class AudioTests(unittest.TestCase):
    def test_mix_at_snr(self):
        rng = np.random.default_rng(0)
        s = np.sin(np.arange(16000) / 10).astype(np.float32)
        n = rng.standard_normal(16000).astype(np.float32)
        y = audio.mix_at_snr(s, n, 10.0)
        snr = 20 * np.log10(audio.rms(s) / audio.rms(y - s))
        self.assertAlmostEqual(snr, 10.0, places=3)

    def test_rir_and_speed(self):
        rng = np.random.default_rng(1)
        h = audio.synthetic_rir(rng, rt60=0.4, distance_m=2.0)
        self.assertLessEqual(np.max(np.abs(h)), 1.0 + 1e-6)
        x = np.ones(16000, np.float32)
        self.assertEqual(len(audio.convolve(x, h)), 16000)
        self.assertAlmostEqual(len(audio.speed(x, 1.25)), 12800, delta=2)
        self.assertEqual(len(audio.pitch_shift(x, 2.0)), 16000)

    def test_wav_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.wav")
            x = (np.sin(np.arange(8000) / 7) * 0.5).astype(np.float32)
            audio.write_wav(p, x)
            y = audio.read_audio(p)
            self.assertEqual(len(y), 8000)
            self.assertLess(np.max(np.abs(x - y)), 1e-3)


def _toy(rng, n, shift):
    x = rng.standard_normal((n, 16, 96)).astype(np.float32)
    x[:, -4:, :8] += shift
    return x


class ModelTests(unittest.TestCase):
    def test_learns_separable_toy_data(self):
        rng = np.random.default_rng(0)
        pos, neg = _toy(rng, 400, 2.0), _toy(rng, 4000, 0.0)
        net = WakeNet(hidden=16, seed=0)
        net.fit(pos, neg, steps=300, batch=128, lr=3e-3, max_neg_weight=5.0)
        tp, tn = _toy(rng, 200, 2.0), _toy(rng, 2000, 0.0)
        self.assertGreater((net.predict(tp) >= 0.5).mean(), 0.9)
        self.assertLess((net.predict(tn) >= 0.5).mean(), 0.05)

    def test_npz_roundtrip(self):
        net = WakeNet(hidden=8, seed=3)
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "n.npz")
            net.save_npz(p)
            x = np.random.default_rng(0).standard_normal((5, 16, 96)).astype(np.float32)
            np.testing.assert_allclose(WakeNet.load_npz(p).predict(x), net.predict(x), rtol=1e-6)

    def test_pick_thresholds(self):
        rng = np.random.default_rng(2)
        neg = rng.uniform(0, 0.6, 45000)  # 1 h validation
        neg[[10, 2000]] = [0.83, 0.71]
        pos = rng.uniform(0.7, 1.0, 300)
        th = pick_thresholds(neg, 1.0, pos, target_fa_per_hour=0.1)["thresholds"]
        self.assertGreater(th["normal"], 0.83)  # above every validation false accept
        self.assertGreaterEqual(th["low"], th["normal"])
        self.assertLessEqual(th["high"], th["normal"])


@unittest.skipUnless(HAS_ONNX, "onnx / onnxruntime not installed")
class OnnxTests(unittest.TestCase):
    def test_onnx_matches_numpy(self):
        import onnxruntime as ort
        net = WakeNet(hidden=8, seed=1)
        rng = np.random.default_rng(0)
        net.fit(_toy(rng, 64, 2.0), _toy(rng, 256, 0.0), steps=20, batch=32)
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "w.onnx")
            net.to_onnx(p)
            s = ort.InferenceSession(p, providers=["CPUExecutionProvider"])
            x = _toy(rng, 7, 1.0)
            got = s.run(None, {"input": x})[0][:, 0]
            np.testing.assert_allclose(got, net.predict(x), rtol=1e-4, atol=1e-5)
            got1 = s.run(None, {"input": x[:1]})[0]
            self.assertEqual(got1.shape, (1, 1))

    def test_streaming_features_chunk_invariant(self):
        from ww.features import HOP, FeatureSpec, StreamingFeatures, make_fake_e2e
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "f.onnx")
            make_fake_e2e(p, window_samples=2560)
            fx = StreamingFeatures(FeatureSpec("e2e", e2e_path=p, window_samples=2560))
            x = np.random.default_rng(0).standard_normal(16000).astype(np.float32) * 0.1
            a = fx.clip_embeddings(x)
            fx.reset()
            parts, i = [], 0
            for n in (100, 3000, 1, 5000, 7899):
                parts.append(fx.push(x[i:i + n]))
                i += n
            b = np.concatenate(parts)
            np.testing.assert_allclose(a, b, rtol=1e-5)
            # 12 full hops; first embedding once 2560 samples (2 hops) were seen
            self.assertEqual(len(a), 16000 // HOP - 2 + 1)

    def test_tiny_pipeline_end_to_end(self):
        import pipeline
        with tempfile.TemporaryDirectory() as d:
            pipeline.main(["--work", d, "--tiny", "all"])
            out = os.path.join(d, "out")
            with open(os.path.join(out, "manifest.json")) as f:
                m = json.load(f)
            self.assertFalse(m["licence_cleared"])  # smoke models are never shippable
            self.assertEqual({f["role"] for f in m["files"]}, {"wake", "e2e"})
            for f in m["files"]:
                self.assertTrue(os.path.exists(os.path.join(out, f["name"])))
                self.assertEqual(len(f["sha256"]), 64)
            self.assertIn("eval_bn", m["eval"]["false_accepts"])
            self.assertTrue(os.path.exists(os.path.join(out, "eval_report.md")))


if __name__ == "__main__":
    unittest.main()
