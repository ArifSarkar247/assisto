#!/usr/bin/env python3
"""RunPod Serverless handler — the contract `core/photo_final._run_runpod`
speaks (providers `runpod_serverless` and `assisto_face`). NOT DEPLOYED.

  input : {"image_b64": JPEG, "preset": "natural"|"strong", "bg_blur": bool,
           "face_blend": 0..1}
  output: {"image_b64": JPEG, "steps": {...}}

The worker image (Dockerfile in the plan) contains: this file, onnxruntime-gpu,
opencv-python-headless, the model ONNX (Real-ESRGAN x2 BSD-3 now, later
`assisto_face_x2.onnx`), YuNet (MIT) for faces. Scale-to-zero: min workers 0,
max workers 1-2, idle timeout 5 s, so there is no always-on GPU bill.
Our server still runs the look stage settings and FACE LOCK on the result.
"""
import base64
import io
import os

import numpy as np

MODEL = os.environ.get("MODEL_PATH", "/models/assisto_face_x2.onnx")
_SESS = None


def _session():
    global _SESS
    if _SESS is None:
        import onnxruntime as ort
        _SESS = ort.InferenceSession(MODEL, providers=["CUDAExecutionProvider", "CPUExecutionProvider"])
    return _SESS


def _run(rgb):
    s = _session()
    x = rgb.transpose(2, 0, 1)[None].astype(np.float16 if "float16" in s.get_inputs()[0].type else np.float32)
    y = s.run(None, {s.get_inputs()[0].name: x})[0][0].transpose(1, 2, 0)
    return np.clip(y.astype(np.float32), 0, 1)


def handler(job):
    from PIL import Image
    inp = job.get("input") or {}
    raw = base64.b64decode(inp.get("image_b64") or "")
    im = Image.open(io.BytesIO(raw)).convert("RGB")
    if im.width * im.height > 2_000_000:          # same 2 MP cap as the server
        f = (2_000_000 / (im.width * im.height)) ** 0.5
        im = im.resize((int(im.width * f), int(im.height * f)), Image.LANCZOS)
    rgb = np.asarray(im, np.float32) / 255.0
    out = _run(rgb)
    b = io.BytesIO()
    Image.fromarray(np.uint8(out * 255 + 0.5)).save(b, "JPEG", quality=95)
    return {"image_b64": base64.b64encode(b.getvalue()).decode(),
            "steps": {"model": os.path.basename(MODEL), "in": list(im.size),
                      "preset": inp.get("preset", "natural")}}


if __name__ == "__main__":
    import runpod  # provided in the worker image
    runpod.serverless.start({"handler": handler})
