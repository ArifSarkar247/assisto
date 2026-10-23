#!/usr/bin/env python3
"""d1-photo: install the two NEW Photo Studio models next to Real-ESRGAN and
rewrite manifest.json (upscale entry stays FIRST — older apps take the first
file as the upscaler).

  segment          U2-Net-p (u2netp.onnx, 4.6 MB, phone download, background
                   blur mask). Apache-2.0 (github.com/xuebinqin/U-2-Net LICENSE).
                   ONNX export as published by the rembg project (MIT tool),
                   release v0.0.0, sha256 pinned below — the weights are the
                   authors' unmodified u2netp.pth.
  server_colorize  DDColor-tiny 512x512 ONNX (~270 MB, SERVER ONLY, never sent
                   to phones). Apache-2.0 code (github.com/piddnad/DDColor) and
                   Apache-2.0 weights (huggingface.co/piddnad/ddcolor_paper_tiny).
                   Produced by tools/photo_model/convert_ddcolor.py (needs torch;
                   run it in a scratch venv, NOT the backend venv) — pass the
                   resulting file with --ddcolor.

Usage (light, numpy only):
  python3 tools/photo_model/install_d1_models.py --dir backend/core/photo_models \
      [--ddcolor /path/to/ddcolor_tiny_512.onnx]
Then on the server: pip install onnxruntime==1.19.2 (backend venv) so the
colorize / old-photo restore jobs can run (the app hides them until then).
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.request

U2NETP_URL = "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx"
U2NETP_SHA256 = "309c8469258dda742793dce0ebea8e6dd393174f89934733ecc8b14c76f4ddd8"
U2NETP_LICENCE = "Apache-2.0 (U-2-Net, Copyright (c) 2020 Xuebin Qin)"
DDCOLOR_LICENCE = "Apache-2.0 (DDColor code + ddcolor_paper_tiny weights, piddnad)"


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--ddcolor", default="")
    ap.add_argument("--u2netp", default="", help="local copy instead of downloading")
    a = ap.parse_args()
    man_p = os.path.join(a.dir, "manifest.json")
    m = json.load(open(man_p))
    files = [f for f in m.get("files", []) if f.get("role") == "upscale"]
    if not files:
        sys.exit("manifest has no upscale entry — run convert_realesrgan.py first")

    seg = os.path.join(a.dir, "u2netp.onnx")
    if a.u2netp:
        shutil.copyfile(a.u2netp, seg)
    elif not os.path.exists(seg):
        print("downloading", U2NETP_URL)
        urllib.request.urlretrieve(U2NETP_URL, seg + ".download")
        os.replace(seg + ".download", seg)
    if sha256_file(seg) != U2NETP_SHA256:
        os.remove(seg)
        sys.exit("u2netp.onnx sha256 mismatch — deleted")
    files.append({"role": "segment", "name": "u2netp.onnx", "sha256": U2NETP_SHA256,
                  "size": os.path.getsize(seg), "licence": U2NETP_LICENCE})

    if a.ddcolor:
        dst = os.path.join(a.dir, "ddcolor_tiny_512.onnx")
        if os.path.abspath(a.ddcolor) != os.path.abspath(dst):
            shutil.copyfile(a.ddcolor, dst)
        files.append({"role": "server_colorize", "name": "ddcolor_tiny_512.onnx",
                      "sha256": sha256_file(dst), "size": os.path.getsize(dst),
                      "licence": DDCOLOR_LICENCE})
    m["files"] = files
    m["seg_side"] = 320
    m["licence"] = ("BSD-3-Clause (Real-ESRGAN, Copyright (c) 2021 Xintao Wang); "
                    + U2NETP_LICENCE + ("; " + DDCOLOR_LICENCE if a.ddcolor else ""))
    tmp = man_p + ".tmp"
    json.dump(m, open(tmp, "w"), indent=2)
    os.replace(tmp, man_p)
    print("manifest:", [(f["role"], f["name"], f["size"]) for f in files])


if __name__ == "__main__":
    main()
