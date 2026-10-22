import sys, os, json, numpy as np
sys.path.insert(0, "/home/ubuntu/wt/k1-wake/tools/wakeword")
import pipeline
from ww.features import FeatureSpec, StreamingFeatures
from ww.model import WakeNet
from ww import evaluate
W = sys.argv[1]
pipeline.main(["--work", W, "--tiny", "features", "synth", "prepare", "windows", "train"])
rng = np.random.default_rng(5)
x = (rng.standard_normal(16000 * 10) * 0.05).astype(np.float32)
t = np.arange(4800) / 16000
x[40000:44800] += 0.5 * np.sin(2 * np.pi * 440 * t)
pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
pcm.astype("<i2").tofile(os.path.join(W, "audio.raw"))
fx = StreamingFeatures(FeatureSpec("e2e", e2e_path=os.path.join(W, "features", "fake_e2e.onnx"), window_samples=2560))
net = WakeNet.load_npz(os.path.join(W, "model", "net.npz"))
sc = evaluate.stream_scores(fx, net, pcm, 16)
np.savetxt(os.path.join(W, "expected.txt"), sc)
print("expected", len(sc))
