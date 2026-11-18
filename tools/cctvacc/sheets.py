"""cctv-accuracy: contact sheets for HUMAN labelling (one thumbnail per 1-2 s
with the clip id and time stamped on it). The labels in clips.json were
written by looking at these sheets, never from any model output.

    python tools/cctvacc/sheets.py --clips /tmp/clips --out sheets/
"""
from __future__ import annotations

import argparse
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fetch import load_clips, local_name  # noqa: E402

COLS, ROWS, TW = 6, 6, 256


def frames_every(path: str, step: float):
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    t_next, i = 0.0, 0
    while True:
        ok, f = cap.read()
        if not ok:
            break
        t = i / fps
        i += 1
        if t + 1e-6 >= t_next:
            yield t, f
            t_next += step
    cap.release()
    return n


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    only = {x for x in a.only.split(",") if x}
    for c in load_clips():
        if only and c["id"] not in only:
            continue
        p = os.path.join(a.clips, local_name(c))
        if not os.path.exists(p):
            print("missing", c["id"])
            continue
        step = 1.0 if (c.get("duration") or 0) <= 60 else 2.0
        thumbs = []
        for t, f in frames_every(p, step):
            h, w = f.shape[:2]
            th = cv2.resize(f, (TW, max(1, int(h * TW / w))), interpolation=cv2.INTER_AREA)
            cv2.rectangle(th, (0, 0), (TW, 18), (0, 0, 0), -1)
            cv2.putText(th, "%s t=%.0fs" % (c["id"], t), (3, 13), cv2.FONT_HERSHEY_SIMPLEX,
                        0.45, (255, 255, 255), 1, cv2.LINE_AA)
            thumbs.append(th)
        if not thumbs:
            print("undecodable", c["id"])
            continue
        th_h = max(t.shape[0] for t in thumbs)
        per = COLS * ROWS
        for k in range(0, len(thumbs), per):
            chunk = thumbs[k:k + per]
            rows = (len(chunk) + COLS - 1) // COLS
            sheet = np.zeros((rows * th_h, COLS * TW, 3), np.uint8)
            for j, t in enumerate(chunk):
                r, q = divmod(j, COLS)
                sheet[r * th_h:r * th_h + t.shape[0], q * TW:(q + 1) * TW] = t
            name = "%s_%s_%02d.jpg" % (c["id"], c["scene"], k // per)
            cv2.imwrite(os.path.join(a.out, name), sheet, [cv2.IMWRITE_JPEG_QUALITY, 80])
        print("sheets %s: %d thumbs (step %.0fs)" % (c["id"], len(thumbs), step))
    return 0


if __name__ == "__main__":
    sys.exit(main())
