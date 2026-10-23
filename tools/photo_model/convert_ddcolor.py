#!/usr/bin/env python3
"""d1-photo: DDColor-tiny (Apache-2.0 code + Apache-2.0 weights) -> ONNX,
FIXED input [1,3,512,512] -> output ab [1,2,512,512].

HEAVY (torch ~1 GB install, ~3 GB RAM peak): run in a SCRATCH venv, never the
backend venv, and through ~/assisto/bin/heavy.sh:

  python3 -m venv /tmp/ddc && /tmp/ddc/bin/pip install torch --index-url \
      https://download.pytorch.org/whl/cpu && /tmp/ddc/bin/pip install \
      numpy onnx onnxruntime opencv-python-headless timm
  git clone https://github.com/piddnad/DDColor /tmp/ddc_src   # Apache-2.0
  (pinned commit used for the shipped file: 2adb63f2656ac41cbdf7b894cddd94121a3faf13)
  curl -L -o /tmp/ddc_w.bin \
      https://huggingface.co/piddnad/ddcolor_paper_tiny/resolve/main/pytorch_model.bin
  /tmp/ddc/bin/python tools/photo_model/convert_ddcolor.py --src /tmp/ddc_src \
      --weights /tmp/ddc_w.bin --out /tmp/ddcolor_tiny_512.onnx

Then: python3 tools/photo_model/install_d1_models.py --dir backend/core/photo_models \
          --ddcolor /tmp/ddcolor_tiny_512.onnx

Checked on 23 Oct 2026 (2 vCPU Xeon 8259CL): 0 missing / 0 unexpected weight
keys, ONNX vs torch max |diff| 6e-4, 3.4 s per photo with ONNX Runtime.
"""
import argparse
import hashlib
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="DDColor repo checkout")
    ap.add_argument("--weights", required=True, help="ddcolor_paper_tiny pytorch_model.bin")
    ap.add_argument("--out", required=True)
    ap.add_argument("--size", type=int, default=512)
    a = ap.parse_args()
    sys.path.insert(0, a.src)
    import numpy as np
    import torch
    from ddcolor import DDColor

    m = DDColor(encoder_name="convnext-t", decoder_name="MultiScaleColorDecoder",
                input_size=[a.size, a.size], num_output_channels=2, last_norm="Spectral",
                do_normalize=False, num_queries=100, num_scales=3, dec_layers=9)
    sd = torch.load(a.weights, map_location="cpu")
    if isinstance(sd, dict) and "params" in sd:
        sd = sd["params"]
    res = m.load_state_dict(sd, strict=False)
    if res.missing_keys or res.unexpected_keys:
        sys.exit("weights do not match: missing %d unexpected %d"
                 % (len(res.missing_keys), len(res.unexpected_keys)))
    m.eval()
    x = torch.rand(1, 3, a.size, a.size)
    with torch.no_grad():
        y = m(x)
        torch.onnx.export(m, x, a.out, opset_version=17, input_names=["input"],
                          output_names=["output"], dynamo=False)
    import onnxruntime as ort
    s = ort.InferenceSession(a.out, providers=["CPUExecutionProvider"])
    t = time.perf_counter()
    r = s.run(None, {"input": x.numpy()})[0]
    print("onnx run %.2f s, max|diff| vs torch %.2e" % (time.perf_counter() - t,
                                                        float(np.abs(r - y.numpy()).max())))
    h = hashlib.sha256(open(a.out, "rb").read()).hexdigest()
    print("wrote", a.out, "sha256", h)


if __name__ == "__main__":
    main()
