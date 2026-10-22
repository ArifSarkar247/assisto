#!/usr/bin/env python3
"""Real-ESRGAN `realesr-general-x4v3` (.pth, BSD-3-Clause) -> ONNX, WITHOUT torch.

p2-photo (Photo Studio AI restore/upscale). The architecture is SRVGGNetCompact
(Real-ESRGAN `realesrgan/archs/srvgg_arch.py`): conv3x3(3->64) + PReLU,
32 x [conv3x3(64->64) + PReLU], conv3x3(64->48), PixelShuffle(4), plus the
nearest-x4-upsampled input. We read the PyTorch zip checkpoint with a tiny
unpickler (numpy only) and write the same graph with the `onnx` helper API.

Output: a STATIC-shape model [1,3,T,T] -> [1,3,4T,4T] (T = tile + 2*pad, default
144 = 128 + 2*8) because Android NNAPI only accelerates static shapes. The
phone (PhotoUpscaler.kt) feeds reflect-padded tiles of exactly T x T.

Usage (light: a few seconds, ~200 MB RAM):
  python3 convert_realesrgan.py --out backend/core/photo_models
     [--pth realesr-general-x4v3.pth --wdn realesr-general-wdn-x4v3.pth]
                       (default: download both from the official GitHub
                        release and check their sha256)
     [--denoise 0.5]   (Real-ESRGAN's own denoise_strength: weights =
                        d*x4v3 + (1-d)*wdn; 0.5 keeps skin texture —
                        1.0 makes faces waxy, see .phaseB/photo_studio_eval)
     [--tile 144]
Writes <out>/realesr_general_x4v3_t144.onnx + <out>/manifest.json.
Needs: numpy, onnx (pip install numpy==1.26.4 onnx==1.16.2).
"""
import argparse
import hashlib
import io
import json
import os
import pickle
import sys
import urllib.request
import zipfile

import numpy as np

PTH_URL = ("https://github.com/xinntao/Real-ESRGAN/releases/download/"
           "v0.2.5.0/realesr-general-x4v3.pth")
PTH_SHA256 = "8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292"
# the "weak denoise" twin from the same release; Real-ESRGAN's own
# inference_realesrgan.py blends the two (DNI) for its --denoise_strength
WDN_URL = ("https://github.com/xinntao/Real-ESRGAN/releases/download/"
           "v0.2.5.0/realesr-general-wdn-x4v3.pth")
WDN_SHA256 = "1641f8c4464b9f097c9fdda5589273713f67cf59f3d909e0bd688f0cee269dca"
NUM_CONV = 32
NUM_FEAT = 64
SCALE = 4

_DT = {"FloatStorage": np.float32, "HalfStorage": np.float16,
       "DoubleStorage": np.float64, "LongStorage": np.int64, "IntStorage": np.int32}


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


class _Storage:
    def __init__(self, dtype, data):
        self.dtype, self.data = dtype, data


def _rebuild_tensor_v2(storage, offset, size, stride, *_a, **_k):
    arr = np.frombuffer(storage.data, dtype=storage.dtype)
    itemsize = arr.itemsize
    return np.lib.stride_tricks.as_strided(
        arr[offset:], shape=tuple(size),
        strides=tuple(s * itemsize for s in stride)).copy()


def load_torch_zip(path):
    """Minimal torch.load for a zip checkpoint of plain tensors (no code run:
    only whitelisted globals are resolved)."""
    zf = zipfile.ZipFile(path)
    names = zf.namelist()
    root = names[0].split("/")[0]
    pkl = zf.read(f"{root}/data.pkl")

    class U(pickle.Unpickler):
        def find_class(self, mod, name):
            if mod == "torch._utils" and name == "_rebuild_tensor_v2":
                return _rebuild_tensor_v2
            if mod == "torch" and name in _DT:
                return name
            if mod == "collections" and name == "OrderedDict":
                import collections
                return collections.OrderedDict
            raise pickle.UnpicklingError(f"blocked global {mod}.{name}")

        def persistent_load(self, pid):
            _tag, stype, key, _loc, _numel = pid
            return _Storage(_DT[stype], zf.read(f"{root}/data/{key}"))

    return U(io.BytesIO(pkl)).load()


def build_onnx(params, tile):
    import onnx
    from onnx import TensorProto, helper, numpy_helper
    inits, nodes = [], []

    def W(name, arr):
        inits.append(numpy_helper.from_array(np.ascontiguousarray(arr, dtype=np.float32), name))
        return name

    x = "input"
    cur = x
    idx = 0
    # body: [conv, prelu] * (NUM_CONV + 1), then conv_last
    for i in range(NUM_CONV + 1):
        w, b = params[f"body.{idx}.weight"], params[f"body.{idx}.bias"]
        out = f"c{i}"
        nodes.append(helper.make_node("Conv", [cur, W(f"w{i}", w), W(f"b{i}", b)], [out],
                                      kernel_shape=[3, 3], pads=[1, 1, 1, 1]))
        slope = params[f"body.{idx + 1}.weight"].reshape(-1, 1, 1)
        act = f"a{i}"
        nodes.append(helper.make_node("PRelu", [out, W(f"s{i}", slope)], [act]))
        cur, idx = act, idx + 2
    w, b = params[f"body.{idx}.weight"], params[f"body.{idx}.bias"]
    nodes.append(helper.make_node("Conv", [cur, W("wl", w), W("bl", b)], ["cl"],
                                  kernel_shape=[3, 3], pads=[1, 1, 1, 1]))
    nodes.append(helper.make_node("DepthToSpace", ["cl"], ["ps"], blocksize=SCALE, mode="CRD"))
    W("scales", np.array([1, 1, SCALE, SCALE], np.float32))
    nodes.append(helper.make_node("Resize", [x, "", "scales"], ["base"], mode="nearest",
                                  nearest_mode="floor",
                                  coordinate_transformation_mode="asymmetric"))
    nodes.append(helper.make_node("Add", ["ps", "base"], ["sum"]))
    W("lo", np.array(0, np.float32))
    W("hi", np.array(1, np.float32))
    nodes.append(helper.make_node("Clip", ["sum", "lo", "hi"], ["output"]))
    g = helper.make_graph(
        nodes, "realesr_general_x4v3",
        [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, tile, tile])],
        [helper.make_tensor_value_info("output", TensorProto.FLOAT,
                                       [1, 3, tile * SCALE, tile * SCALE])], inits)
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 13)],
                          producer_name="assisto-p2-photo")
    m.ir_version = 7  # ORT Mobile 1.23 reads IR 7..10
    onnx.checker.check_model(m)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--pth", default="")
    ap.add_argument("--wdn", default="")
    ap.add_argument("--denoise", type=float, default=0.5)
    ap.add_argument("--tile", type=int, default=144)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    def fetch(given, url, sha, tag):
        p = given
        if not p:
            p = os.path.join(a.out, tag + ".pth.download")
            if not os.path.exists(p):
                urllib.request.urlretrieve(url, p)
        got = sha256_file(p)
        if got != sha:
            sys.exit(f"sha256 mismatch for {p}: {got} (expected {sha})")
        ck = load_torch_zip(p)
        if not given:
            os.remove(p)
        return ck.get("params", ck)

    params = fetch(a.pth, PTH_URL, PTH_SHA256, "x4v3")
    d = min(1.0, max(0.0, a.denoise))
    if d < 1.0:
        wdn = fetch(a.wdn, WDN_URL, WDN_SHA256, "wdn")
        params = {k: d * params[k] + (1 - d) * wdn[k] for k in params}
    import onnx
    m = build_onnx(params, a.tile)
    name = f"realesr_general_x4v3_dn{int(round(d * 100)):03d}_t{a.tile}.onnx"
    path = os.path.join(a.out, name)
    onnx.save(m, path)
    manifest = {
        "version": "2026.10.1",
        "kind": "upscale",
        "model": "realesr-general-x4v3",
        "licence": "BSD-3-Clause (Real-ESRGAN, Copyright (c) 2021 Xintao Wang)",
        # The owner order names Real-ESRGAN as the allowed example; see
        # .phaseB/MODEL_LICENSES.md for the training-data note.
        "licence_cleared": True,
        "source": [PTH_URL, WDN_URL],
        "source_sha256": [PTH_SHA256, WDN_SHA256],
        "denoise_strength": d,
        "scale": SCALE, "tile": a.tile, "pad": 8,
        "input": "input", "output": "output", "layout": "NCHW_RGB_0_1",
        "files": [{"role": "upscale", "name": name, "sha256": sha256_file(path),
                   "size": os.path.getsize(path)}],
    }
    with open(os.path.join(a.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
