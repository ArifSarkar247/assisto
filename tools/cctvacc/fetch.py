"""cctv-accuracy: download the pinned, openly licensed clips (clips.json) from
Wikimedia Commons into a cache dir and verify each file's SHA-1 (the hash
Commons publishes for the original upload), then re-encode each one ONCE with
the system ffmpeg to H.264 mp4 (<= 1280 px wide, same frame times) so every
clip decodes the same way in OpenCV (some originals are VP9 4K / AV1 / Theora
that the OpenCV wheel cannot read). Nothing downloaded is committed.

    python tools/cctvacc/fetch.py --out /tmp/clips [--only c01,c02]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
UA = "AssistoCCTVBench/1.0 (https://lifeassisto.com; CI accuracy bench)"


def load_clips(path: str = os.path.join(HERE, "clips.json")):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def sha1_file(p: str) -> str:
    h = hashlib.sha1()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def local_name(clip: dict) -> str:
    """The re-encoded clip every tool reads."""
    return clip["id"] + ".mp4"


def _orig_name(clip: dict) -> str:
    ext = os.path.splitext(clip["url"].split("?", 1)[0])[1].lower() or ".webm"
    return clip["id"] + ".orig" + ext


def transcode(src: str, dst: str) -> None:
    import subprocess

    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                    "-vf", "scale='min(1280,iw)':-2", "-an", "-c:v", "libx264",
                    "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                    dst + ".part.mp4"], check=True, timeout=1800)
    os.replace(dst + ".part.mp4", dst)


def fetch(clip: dict, out: str, tries: int = 5) -> str:
    final = os.path.join(out, local_name(clip))
    if os.path.exists(final):
        return final
    dst = os.path.join(out, _orig_name(clip))
    if not (os.path.exists(dst) and sha1_file(dst) == clip["sha1"]):
        _download(clip, dst, tries)
    transcode(dst, final)
    os.remove(dst)          # keep the runner's disk small
    return final


def _download(clip: dict, dst: str, tries: int) -> str:
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(clip["url"], headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120) as r, open(dst + ".part", "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            got = sha1_file(dst + ".part")
            if got != clip["sha1"]:
                raise ValueError("sha1 mismatch %s != %s" % (got, clip["sha1"]))
            os.replace(dst + ".part", dst)
            return dst
        except Exception as e:  # network blips / 429: back off and retry
            last = e
            time.sleep(10 * (i + 1))
    raise RuntimeError("%s: %s" % (clip["id"], last))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    only = {x for x in a.only.split(",") if x}
    bad = 0
    for c in load_clips():
        if (only and c["id"] not in only) or c.get("dropped"):
            continue
        try:
            p = fetch(c, a.out)
            print("ok   %s %-12s %s" % (c["id"], c["scene"], os.path.basename(p)))
        except Exception as e:
            bad += 1
            print("FAIL %s %s" % (c["id"], e))
        time.sleep(1)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
