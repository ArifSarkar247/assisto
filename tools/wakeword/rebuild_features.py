#!/usr/bin/env python3
"""Licence-clean feature extractor: rebuild the speech-embedding model from
Google's ORIGINAL speech_embedding module (TF-Hub / Kaggle Models, Apache-2.0)
as ONE ONNX model: raw 16 kHz audio window [1, 12400] -> one 96-d embedding
[1, 1, 1, 96] (same I/O contract as before, so ww/features.py and the phone's
OwwEngine.kt "e2e" backend are unchanged).

Why not convert the whole module: its graph wraps the log-mel front end in a
TF1 `tf.map_fn` while-loop (TensorArrayV3 / Enter / Exit / LoopCond) over the
batch, and puts RFFT + ComplexAbs inside it. tf2onnx cannot convert that loop
("Conversion of Loop requries output shape [map/while/LogicalAnd:0]") and,
because the loop output has no known shape, every Conv2D after it fails too
("Conv is not supported"). So we split it the way openWakeWord does:

  1. front end  — rebuilt here as plain ONNX ops (Gather framing, Hann window
     folded into DFT matrices -> MatMul, magnitude, mel MatMul, log(x+0.001)).
     Parameters read from the module graph: 25 ms / 10 ms STFT (400 / 160,
     fft 512, periodic Hann), 32 mel bins 60-3800 Hz, log offset 0.001.
  2. conv net   — the module's own "MudpuppyLite" graph, cut at its input
     tensor (`Squeeze:0`, log-mel [batch, frames, 32]), variables frozen,
     fed with a FIXED [1, 76, 32] placeholder -> no loop, static shapes.
     Converted with tf2onnx.
  3. merged into one model and VERIFIED against the untouched TF module on
     random noise, tones, eSpeak speech and (if given) real speech from the
     prepared LibriSpeech / SLR53 streams, plus a streaming check (TF on a
     long clip vs ONNX on sliding windows). Exits non-zero if the max abs
     embedding difference exceeds --tol (default 1e-3).

Runs in its own venv in CI (TensorFlow is big; never on the dev box):
  pip install "tensorflow-cpu==2.15.1" "tf2onnx==1.16.1" "onnx==1.16.2" \
              "onnxruntime==1.18.1" "numpy==1.26.4"
  python3 tools/wakeword/rebuild_features.py --out <work>/features \
      [--real-audio <work>/prepared/eval_en.npy,<work>/prepared/eval_bn.npy]

Writes <out>/assisto_embed_e2e.onnx + <out>/e2e_info.json (incl. the licence
text fetched from the Kaggle Models API at build time).
"""
import argparse
import datetime as _dt
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import wave

import numpy as np

SR = 16000
HOP = 1280            # 8 log-mel frames = 80 ms per embedding
FRAMES = 76           # log-mel frames per embedding (module docs: 12400 samples)
FRAME_LEN = 400       # 25 ms
FRAME_STEP = 160      # 10 ms
FFT = 512
N_MEL = 32
MEL_LO, MEL_HI = 60.0, 3800.0
LOG_OFFSET = 0.001
WINDOW = FRAME_LEN + (FRAMES - 1) * FRAME_STEP  # 12400
EMB = 96

DOWNLOADS = [
    "https://tfhub.dev/google/speech_embedding/1?tf-hub-format=compressed",
    "https://www.kaggle.com/api/v1/models/google/speech-embedding/tensorFlow1/speech-embedding/1/download",
]
SOURCE_PAGE = "https://www.kaggle.com/models/google/speech-embedding (was tfhub.dev/google/speech_embedding/1)"
LICENCE_API = "https://www.kaggle.com/api/v1/models/google/speech-embedding/get"
IN_TENSOR = "samples:0"
MEL_TENSOR = "Squeeze:0"  # log-mel [batch, frames, 32] = input of MudpuppyLite
OUT_NODE = "embeddings_apply_default/MudpuppyLite/Conv_18/Conv2D"


def log(*a):
    print("[rebuild]", *a, flush=True)


def _get(url, timeout=120):
    req = urllib.request.Request(url, headers={"User-Agent": "assisto-wakeword-build"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def fetch_module(cache):
    d = os.path.join(cache, "google_speech_embedding_1")
    if os.path.exists(os.path.join(d, "saved_model.pb")):
        return d, "cache"
    last = None
    for url in DOWNLOADS:
        try:
            blob = _get(url)
            tmp = tempfile.mkdtemp(dir=cache)
            with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf_:
                for m in tf_.getmembers():  # no absolute paths / .. / links
                    if m.name.startswith("/") or ".." in m.name.split("/") or not (m.isfile() or m.isdir()):
                        raise RuntimeError("unsafe archive member " + m.name)
                tf_.extractall(tmp)
            if not os.path.exists(os.path.join(tmp, "saved_model.pb")):
                raise RuntimeError("archive has no saved_model.pb")
            shutil.rmtree(d, ignore_errors=True)
            os.replace(tmp, d)
            return d, url
        except Exception as e:  # noqa: BLE001
            last = e
            log("download failed:", url.split("?")[0], e)
    raise SystemExit(f"could not download speech_embedding: {last}")


def fetch_licence():
    """The model page's own licence field, recorded verbatim in e2e_info.json."""
    try:
        j = json.loads(_get(LICENCE_API, timeout=60))
        inst = [i for i in j.get("instances", []) if i.get("framework", "").lower() == "tensorflow1"]
        return {"api": LICENCE_API, "fetched_utc": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
                "title": j.get("title"), "author": j.get("author"),
                "licenseName": [i.get("licenseName") for i in inst] or None,
                "instance_url": [i.get("url") for i in inst]}
    except Exception as e:  # noqa: BLE001
        return {"api": LICENCE_API, "error": str(e)}


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


# ---- 1. front end as ONNX ----------------------------------------------------

def frontend_nodes(mel_matrix, out_name, variant="dft"):
    """[1, WINDOW] audio -> [1, FRAMES, 32] log-mel, as ONNX nodes + initialisers.

    variant "dft":    ONNX DFT op (opset 17; ORT runs a radix-2 FFT for 512) — same
                      algorithm family as TF's RFFT, so near-silent bins agree best.
    variant "matmul": Hann-folded DFT matrices + MatMul (any opset; fallback)."""
    from onnx import helper, numpy_helper
    n = np.arange(FRAME_LEN, dtype=np.float64)
    hann = 0.5 - 0.5 * np.cos(2.0 * np.pi * n / FRAME_LEN)  # periodic, = tf.signal.hann_window
    idx = (np.arange(FRAMES)[:, None] * FRAME_STEP + np.arange(FRAME_LEN)[None, :]).astype(np.int64)
    inits = [numpy_helper.from_array(idx, "fe_idx"),
             numpy_helper.from_array(mel_matrix.astype(np.float32), "fe_mel"),
             numpy_helper.from_array(np.array(LOG_OFFSET, np.float32), "fe_eps")]
    nodes = [helper.make_node("Gather", ["audio", "fe_idx"], ["fe_frames"], axis=1)]  # [1, 76, 400]
    if variant == "dft":
        inits += [numpy_helper.from_array(hann.astype(np.float32), "fe_hann"),
                  numpy_helper.from_array(np.array([0, 0, 0, 0, 0, FFT - FRAME_LEN], np.int64), "fe_pads"),
                  numpy_helper.from_array(np.array([3], np.int64), "fe_ax3")]
        nodes += [
            helper.make_node("Mul", ["fe_frames", "fe_hann"], ["fe_win"]),
            helper.make_node("Pad", ["fe_win", "fe_pads"], ["fe_pad"]),               # [1, 76, 512]
            helper.make_node("Unsqueeze", ["fe_pad", "fe_ax3"], ["fe_real"]),         # [1, 76, 512, 1]
            helper.make_node("DFT", ["fe_real"], ["fe_spec"], axis=2, onesided=1),    # [1, 76, 257, 2]
            helper.make_node("Mul", ["fe_spec", "fe_spec"], ["fe_sq"]),
            helper.make_node("ReduceSum", ["fe_sq", "fe_ax3"], ["fe_pow"], keepdims=0),
        ]
    else:
        k = np.arange(FFT // 2 + 1, dtype=np.float64)
        ang = 2.0 * np.pi * np.outer(n, k) / FFT  # zero-padding to 512 is implicit
        inits += [numpy_helper.from_array((hann[:, None] * np.cos(ang)).astype(np.float32), "fe_cos"),
                  numpy_helper.from_array((hann[:, None] * -np.sin(ang)).astype(np.float32), "fe_sin")]
        nodes += [
            helper.make_node("MatMul", ["fe_frames", "fe_cos"], ["fe_re"]),           # [1, 76, 257]
            helper.make_node("MatMul", ["fe_frames", "fe_sin"], ["fe_im"]),
            helper.make_node("Mul", ["fe_re", "fe_re"], ["fe_re2"]),
            helper.make_node("Mul", ["fe_im", "fe_im"], ["fe_im2"]),
            helper.make_node("Add", ["fe_re2", "fe_im2"], ["fe_pow"]),
        ]
    nodes += [
        helper.make_node("Sqrt", ["fe_pow"], ["fe_mag"]),
        helper.make_node("MatMul", ["fe_mag", "fe_mel"], ["fe_melspec"]),             # [1, 76, 32]
        helper.make_node("Add", ["fe_melspec", "fe_eps"], ["fe_mel_eps"]),
        helper.make_node("Log", ["fe_mel_eps"], [out_name]),
    ]
    return nodes, inits


# ---- 2. the module's conv net, cut + frozen ----------------------------------

def check_module_params(gd):
    """Fail loudly if the module's front-end constants differ from ours."""
    from tensorflow.python.framework import tensor_util
    want = {"map/while/stft/frame_length": FRAME_LEN, "map/while/stft/frame_step": FRAME_STEP,
            "map/while/stft/fft_length": FFT, "map/while/linear_to_mel_weight_matrix/lower_edge_hertz": MEL_LO,
            "map/while/linear_to_mel_weight_matrix/upper_edge_hertz": MEL_HI,
            "map/while/linear_to_mel_weight_matrix/sample_rate/x": SR,
            "map/while/add_1/y": LOG_OFFSET, "map/while/stft/hann_window/periodic": True}
    seen = {}
    for nd in gd.node:
        if nd.name in want and nd.op == "Const":
            seen[nd.name] = tensor_util.MakeNdarray(nd.attr["value"].tensor).item()
    bad = {k: (seen.get(k), v) for k, v in want.items()
           if k not in seen or not np.isclose(float(seen[k]), float(v), rtol=1e-6)}
    if bad:
        raise SystemExit(f"module front-end constants differ (got, expected): {bad}")
    if "map/while/log_mel_spectrogram" not in {nd.name for nd in gd.node}:
        raise SystemExit("module graph has no map/while/log_mel_spectrogram")
    return seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--cache", default=os.environ.get("TFHUB_CACHE_DIR", os.path.expanduser("~/.cache/tfhub_modules")))
    ap.add_argument("--real-audio", default="", help="comma-separated int16 .npy streams (prepared real speech)")
    ap.add_argument("--tol", type=float, default=1e-3)
    ap.add_argument("--opset", type=int, default=17)  # 17 = first opset with DFT
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    os.makedirs(a.cache, exist_ok=True)

    import onnx
    import onnxruntime as ort
    import tensorflow as tf
    import tf2onnx
    from onnx import helper
    tf.compat.v1.disable_eager_execution()

    mod_dir, got_from = fetch_module(a.cache)
    licence = fetch_licence()
    log("module", mod_dir, "from", got_from, "| licence field:", licence.get("licenseName"), licence.get("error", ""))

    g = tf.Graph()
    sess = tf.compat.v1.Session(graph=g)
    with g.as_default():
        tf.compat.v1.saved_model.loader.load(sess, [], mod_dir)  # inference meta-graph (tags = {})
        gd = g.as_graph_def()
        params = check_module_params(gd)
        log("front-end constants OK:", params)
        S, M = g.get_tensor_by_name(IN_TENSOR), g.get_tensor_by_name(MEL_TENSOR)
        O = g.get_tensor_by_name(OUT_NODE + ":0")
        mel_w = sess.run(tf.signal.linear_to_mel_weight_matrix(N_MEL, FFT // 2 + 1, SR, MEL_LO, MEL_HI))
        frozen = tf.compat.v1.graph_util.convert_variables_to_constants(sess, gd, [OUT_NODE])

    def tf_run(x):
        return sess.run([M, O], {S: x})

    # contract of the original module
    _, e1 = tf_run(np.zeros((1, WINDOW), np.float32))
    _, e2 = tf_run(np.zeros((1, WINDOW + HOP), np.float32))
    if e1.shape != (1, 1, 1, EMB) or e2.shape != (1, 2, 1, EMB):
        raise SystemExit(f"unexpected module output shapes {e1.shape} / {e2.shape}")

    g2 = tf.Graph()
    with g2.as_default():
        ph = tf.compat.v1.placeholder(tf.float32, [1, FRAMES, N_MEL], name="logmel")
        tf.import_graph_def(frozen, input_map={MEL_TENSOR: ph}, name="m")
        net_gd = tf.compat.v1.graph_util.extract_sub_graph(g2.as_graph_def(), ["m/" + OUT_NODE])
    ops = sorted({nd.op for nd in net_gd.node})
    log("conv-net subgraph:", len(net_gd.node), "nodes, ops:", ops)
    loopish = {"Enter", "Exit", "LoopCond", "TensorArrayV3", "TensorArrayGatherV3", "RFFT", "ComplexAbs"} & set(ops)
    if loopish:
        raise SystemExit(f"cut failed — loop/FFT ops still in the conv-net graph: {loopish}")

    net, _ = tf2onnx.convert.from_graph_def(net_gd, input_names=["logmel:0"],
                                            output_names=["m/" + OUT_NODE + ":0"], opset=a.opset)
    net_in, net_out = net.graph.input[0].name, net.graph.output[0].name

    net_path = os.path.join(a.out, "speech_embedding_net.onnx")  # conv net alone: [1,76,32] log-mel -> 96
    onnx.save(net, net_path)
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    netx = ort.InferenceSession(net_path, so, providers=["CPUExecutionProvider"])

    def build(variant):
        fe_nodes, fe_inits = frontend_nodes(mel_w, net_in, variant)
        graph = helper.make_graph(
            fe_nodes + list(net.graph.node) + [helper.make_node("Identity", [net_out], ["embedding"])],
            "assisto_embed_e2e",
            [helper.make_tensor_value_info("audio", onnx.TensorProto.FLOAT, [1, WINDOW])],
            [helper.make_tensor_value_info("embedding", onnx.TensorProto.FLOAT, [1, 1, 1, EMB])],
            fe_inits + list(net.graph.initializer))
        model = helper.make_model(graph, opset_imports=list(net.opset_import),
                                  producer_name="assisto-rebuild_features")
        model.ir_version = net.ir_version
        model.doc_string = ("Google speech_embedding v1 (Apache-2.0) rebuilt for Assisto: log-mel front end ("
                            + variant + ") as ONNX ops + the module's frozen MudpuppyLite conv net. "
                            "Input: 12400 samples, 16 kHz, [-1, 1]. Output: one 96-d embedding.")
        onnx.checker.check_model(model, full_check=True)
        p = os.path.join(a.out, f"assisto_embed_e2e.{variant}.onnx")
        onnx.save(model, p)
        return p

    # ---- 3. verification ------------------------------------------------------
    rng = np.random.default_rng(0)
    tests = []
    for s in (0.003, 0.03, 0.3):
        for _ in range(3):
            tests.append((f"noise{s}", (rng.standard_normal(WINDOW) * s)))
    tests.append(("near-silence", rng.standard_normal(WINDOW) * 1e-4))
    t = np.arange(WINDOW) / SR
    tests.append(("sweep", 0.5 * np.sin(2 * np.pi * (100 + 1900 * t / t[-1]) * t)))
    tests.append(("clipped-square", np.sign(np.sin(2 * np.pi * 440 * t)) * 0.99))
    for name, x in espeak_clips():
        tests.append((name, x))
    for name, x in real_snippets(a.real_audio, rng):
        tests.append((name, x))
    refs = []
    worst_net = 0.0
    for name, x in tests:
        x = np.clip(np.asarray(x, np.float32), -1, 1)[None, :WINDOW]
        mel_ref, emb_ref = tf_run(x)
        refs.append((name, x, mel_ref, emb_ref))
        net_got = netx.run(None, {net_in: mel_ref.astype(np.float32)})[0]
        worst_net = max(worst_net, float(np.max(np.abs(net_got - emb_ref))))

    results = {}
    for variant in ("dft", "matmul"):
        try:
            p = build(variant)
            sess_v = ort.InferenceSession(p, so, providers=["CPUExecutionProvider"])
        except Exception as e:  # noqa: BLE001
            log(f"front end {variant}: build/load failed: {e}")
            continue
        rows, worst = [], 0.0
        for name, x, _mel, emb_ref in refs:
            d = float(np.max(np.abs(sess_v.run(None, {"audio": x})[0] - emb_ref)))
            rows.append({"test": name, "max_abs": d, "ref_max": float(np.max(np.abs(emb_ref)))})
            worst = max(worst, d)
        results[variant] = (worst, rows, p, sess_v)
        log(f"front end {variant}: worst max|onnx-tf| = {worst:.2e}")
    if not results:
        raise SystemExit("no front-end variant could be built")
    variant = min(results, key=lambda v: results[v][0])
    worst, rows, vpath, e2e = results[variant]
    path = os.path.join(a.out, "assisto_embed_e2e.onnx")
    shutil.copyfile(vpath, path)
    worst_mel = max(float(np.max(np.abs(onnx_logmel(x, mel_w) - mel[0]))) for _, x, mel, _ in refs)

    # streaming: TF on one long clip == ONNX on sliding 12400 windows every 1280
    stream_src = next((x for n, x in tests if n.startswith("real")), None)
    if stream_src is None:
        stream_src = next((x for n, x in tests if n.startswith("espeak")), tests[4][1])
    long = np.tile(np.asarray(stream_src, np.float32), 3)[: WINDOW + 10 * HOP]
    long = np.clip(long + rng.standard_normal(len(long)).astype(np.float32) * 0.01, -1, 1)[None, :]
    _, full = tf_run(long)
    k_n = full.shape[1]
    if k_n != 11:
        raise SystemExit(f"streaming: expected 11 embeddings from {long.shape[1]} samples, got {k_n}")
    stream = 0.0
    for k in range(k_n):
        got = e2e.run(None, {"audio": long[:, k * HOP: k * HOP + WINDOW]})[0]
        stream = max(stream, float(np.max(np.abs(got[0, 0, 0] - full[0, k, 0]))))
    for r in rows:
        log(f"  {r['test']:<22} max|onnx-tf| = {r['max_abs']:.2e}   (|emb| max {r['ref_max']:.1f})")
    log(f"worst e2e {worst:.2e} | conv-net alone {worst_net:.2e} | numpy-fp64 log-mel vs TF {worst_mel:.2e} | "
        f"streaming (11 hops) {stream:.2e} | tol {a.tol}")
    info = {
        "file": "assisto_embed_e2e.onnx", "window_samples": WINDOW, "hop_samples": HOP,
        "input": "audio", "output": "embedding", "input_range": "[-1, 1] float32, 16 kHz mono",
        "source": SOURCE_PAGE, "downloaded_from": got_from.split("?")[0],
        "licence": "Apache-2.0 (Google speech_embedding v1, TF-Hub / Kaggle Models)",
        "licence_check": licence,
        "front_end": {"variant": variant, "variants_worst": {k: v[0] for k, v in results.items()},
                      "stft": [FRAME_LEN, FRAME_STEP, FFT], "window": "hann periodic", "mel_bins": N_MEL,
                      "mel_hz": [MEL_LO, MEL_HI], "log_offset": LOG_OFFSET, "module_constants": params},
        "verify": {"tol": a.tol, "max_abs_diff_vs_tf": worst, "conv_net_only": worst_net,
                   "numpy_fp64_logmel_vs_tf": worst_mel, "streaming_11_hops": stream, "tests": rows},
        "max_abs_diff_vs_tf": max(worst, stream),
        "sha256": sha256(path), "size": os.path.getsize(path),
        "versions": {"tensorflow": tf.__version__, "tf2onnx": tf2onnx.__version__, "onnx": onnx.__version__,
                     "onnxruntime": ort.__version__, "opset": a.opset},
    }
    with open(os.path.join(a.out, "e2e_info.json"), "w") as f:
        json.dump(info, f, indent=1)
    if max(worst, stream) > a.tol:
        raise SystemExit(f"ONNX vs TensorFlow mismatch {max(worst, stream):.2e} > tol {a.tol}")
    lic = licence.get("licenseName") or []
    if lic and not all("apache" in (x or "").lower() for x in lic):
        raise SystemExit(f"model page licence is not Apache: {lic} — do not ship")
    log("ok ->", path, os.path.getsize(path), "bytes")


def onnx_logmel(x, mel_w):
    """Front end in numpy float64 — diagnostic: how far TF's own float32 log-mel is from exact."""
    idx = np.arange(FRAMES)[:, None] * FRAME_STEP + np.arange(FRAME_LEN)[None, :]
    fr = x[0][idx].astype(np.float32)
    n = np.arange(FRAME_LEN)
    hann = 0.5 - 0.5 * np.cos(2.0 * np.pi * n / FRAME_LEN)
    spec = np.abs(np.fft.rfft(fr * hann, FFT))
    return np.log(spec @ mel_w + LOG_OFFSET).astype(np.float32)


def espeak_clips():
    """Synthetic speech (eSpeak NG, GPL tool used only to make test audio — not shipped)."""
    exe = shutil.which("espeak-ng")
    if not exe:
        log("espeak-ng not found — skipping speech tests")
        return []
    out = []
    for voice, text in (("en-us", "hey assisto, what is the weather today"),
                        ("en-gb", "hey assisto"), ("bn", "আমার নাম আসিস্টো, তুমি কেমন আছো")):
        with tempfile.TemporaryDirectory() as td:
            w = os.path.join(td, "s.wav")
            r = subprocess.run([exe, "-v", voice, "-w", w, text], capture_output=True)
            if r.returncode or not os.path.exists(w):
                continue
            with wave.open(w) as f:
                sr, x = f.getframerate(), np.frombuffer(f.readframes(f.getnframes()), np.int16) / 32768.0
        x = np.interp(np.arange(0, len(x) / sr, 1 / SR), np.arange(len(x)) / sr, x)
        x = np.pad(x, (0, max(0, WINDOW - len(x))))
        out.append((f"espeak-{voice}", x[:WINDOW] * 0.9 / (np.abs(x).max() + 1e-9)))
    return out


def real_snippets(spec, rng, per_file=6):
    out = []
    for p in [s for s in spec.split(",") if s]:
        if not os.path.exists(p):
            log("real audio missing:", p)
            continue
        a = np.load(p, mmap_mode="r")
        got = 0
        for _ in range(400):
            if got >= per_file or len(a) <= WINDOW:
                break
            i = int(rng.integers(0, len(a) - WINDOW))
            x = np.asarray(a[i: i + WINDOW], np.float32) / 32768.0
            if np.sqrt(np.mean(x ** 2)) > 0.02:  # mostly speech, not silence
                out.append((f"real-{os.path.basename(p).split('.')[0]}-{got}", x))
                got += 1
    return out


if __name__ == "__main__":
    sys.exit(main())
