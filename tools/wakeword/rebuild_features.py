#!/usr/bin/env python3
"""Licence-clean feature extractor: rebuild the speech-embedding model from
Google's ORIGINAL speech_embedding TF-Hub module (Apache-2.0) and convert it
to ONE ONNX model (raw 16 kHz audio window -> 96-d embedding).

Why: openWakeWord's README puts its "included pre-trained models" under
CC BY-NC-SA 4.0 and states no separate licence for its melspectrogram /
embedding ONNX files, so for a commercial app we do not rely on them unless
the maintainer confirms in writing (MODEL_LICENSES.md). Google's original
module is plainly Apache-2.0.

Runs in its own venv in CI (TensorFlow is big; never on the dev box):
  pip install "tensorflow-cpu==2.15.1" "tensorflow-hub==0.16.1" "tf2onnx==1.16.1" \
              "onnx==1.16.2" "onnxruntime==1.18.1" "numpy<2"
  python3 tools/wakeword/rebuild_features.py --out <work>/features

Writes <out>/assisto_embed_e2e.onnx + <out>/e2e_info.json. Verifies the ONNX
output against TensorFlow on random audio and checks the 80 ms hop. Exits
non-zero (and the workflow says so) if anything does not match — the honest
fallback is the "oww" backend with licence_cleared=false.
"""
import argparse
import json
import os
import sys

import numpy as np

HANDLES = [
    "https://tfhub.dev/google/speech_embedding/1",
    "https://www.kaggle.com/models/google/speech-embedding/TensorFlow1/speech-embedding/1",
]
HOP = 1280


def load_signature():
    import tensorflow as tf  # noqa: F401
    import tensorflow_hub as hub
    last = None
    for h in HANDLES:
        for tags in (None, set(), {"train"}):
            try:
                m = hub.load(h) if tags is None else hub.load(h, tags=tags)
                sig = m.signatures["default"]
                return m, sig, h
            except Exception as e:  # noqa: BLE001
                last = e
    raise SystemExit(f"could not load speech_embedding: {last}")


def out_len(sig, n):
    import tensorflow as tf
    r = sig(tf.zeros([1, n], tf.float32))
    y = list(r.values())[0].numpy()
    return y.shape, y


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    import tensorflow as tf
    import tf2onnx
    import onnxruntime as ort

    _m, sig, handle = load_signature()
    print("loaded", handle, "inputs:", sig.structured_input_signature, "outputs:", sig.structured_outputs)
    # smallest window that yields exactly one embedding
    window = None
    for n in range(12000, 20001, 80):
        try:
            shp, _ = out_len(sig, n)
        except Exception:  # noqa: BLE001
            continue
        t = int(np.prod(shp[1:-1])) if len(shp) > 2 else shp[0]
        if t >= 1:
            window = n
            break
    if window is None:
        raise SystemExit("no window length produced an embedding")
    shp1, _ = out_len(sig, window)
    shp2, _ = out_len(sig, window + HOP)
    print("window", window, "shape", shp1, "-> +1 hop", shp2)
    if shp2[1] != shp1[1] + 1:
        raise SystemExit(f"hop is not {HOP} samples ({shp1} -> {shp2}); runtime assumes 80 ms")
    if shp1[-1] != 96:
        raise SystemExit(f"embedding dim {shp1[-1]} != 96")
    in_name = list(sig.structured_input_signature[1].keys())[0]

    @tf.function(input_signature=[tf.TensorSpec([1, window], tf.float32, name="audio")])
    def f(x):
        y = list(sig(**{in_name: x}).values())[0]
        return tf.reshape(y[:, -1:], [1, 1, 1, 96])

    path = os.path.join(a.out, "assisto_embed_e2e.onnx")
    tf2onnx.convert.from_function(f, input_signature=f.input_signature, opset=13, output_path=path)
    sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(0)
    worst = 0.0
    for _ in range(5):
        x = (rng.standard_normal((1, window)) * 0.1).astype(np.float32)
        ref = f(tf.constant(x)).numpy()
        got = sess.run(None, {sess.get_inputs()[0].name: x})[0]
        worst = max(worst, float(np.max(np.abs(ref - got))))
    print("max |onnx - tf| =", worst)
    if worst > 1e-3:
        raise SystemExit("ONNX conversion mismatch")
    json.dump({"file": "assisto_embed_e2e.onnx", "window_samples": window, "hop_samples": HOP,
               "source": handle, "licence": "Apache-2.0 (Google speech_embedding TF-Hub module)",
               "max_abs_diff_vs_tf": worst, "input": sess.get_inputs()[0].name},
              open(os.path.join(a.out, "e2e_info.json"), "w"), indent=1)
    print("ok ->", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    sys.exit(main())
