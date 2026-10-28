"""Measure the OPTIONAL server snapshot check (core/cashguard_detect.py) on
THIS box: YOLOX-Nano, 1 intra-op thread, one 640-wide JPEG still.

  python tools/cashguard/server_detect_bench.py MODEL.onnx IMAGE [runs]

Prints JSON: load_ms, p50_ms, p95_ms, cpu_ms_per_check, people found.
No Django settings needed (the detector is imported standalone)."""
import io
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "backend"))


def main():
    model, image = sys.argv[1], sys.argv[2]
    runs = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    from PIL import Image
    im = Image.open(image).convert("RGB")
    im.thumbnail((640, 640))
    b = io.BytesIO()
    im.save(b, "JPEG", quality=75)
    jpeg = b.getvalue()
    from core import cashguard_detect as D
    D.PER_MIN = 10 ** 6
    t0 = time.perf_counter()
    D._session(model)
    load_ms = (time.perf_counter() - t0) * 1000
    times, cpu = [], []
    found = None
    for _ in range(runs):
        c0, t0 = time.process_time(), time.perf_counter()
        found = D.detect_people(jpeg)
        times.append((time.perf_counter() - t0) * 1000)
        cpu.append((time.process_time() - c0) * 1000)
    times.sort()
    print(json.dumps({"load_ms": round(load_ms, 1),
                      "p50_ms": round(times[len(times) // 2], 1),
                      "p95_ms": round(times[int(len(times) * 0.95) - 1], 1),
                      "cpu_ms_per_check": round(sum(cpu) / len(cpu), 1),
                      "people": len(found or []), "image_bytes": len(jpeg),
                      "cpus": os.cpu_count()}))


if __name__ == "__main__":
    main()
