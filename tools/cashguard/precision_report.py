"""Hand-to-pocket label — the MEASUREMENT HARNESS (owner rule 28 Oct, item 6:
the label may only ever show if its precision on REAL clips is high, and the
number is reported). Until real labelled shop clips exist the label stays OFF
(core/logic/cash_guard.py HAND_TO_POCKET_LABEL = False) and the report says
"not measured".

Folder layout (clips never leave the owner's machine; nothing is uploaded):

    clips/
      labels.csv          file,label    (label 1 = hand goes to a pocket with
                                         cash, 0 = anything else)
      0001.mp4 | 0001.acg | 0001/ (a folder of JPEG frames) ...

    python tools/cashguard/precision_report.py clips/ \
        --detector mypkg.mymodule:predict   # predict(frames) -> score 0..1
        [--threshold 0.5] [--out report.json]
    python tools/cashguard/precision_report.py --self-test

Output: JSON {n, positives, tp, fp, fn, tn, precision, recall, f1, threshold,
min_precision, label_allowed}. label_allowed is true only with >= 200 real
clips, >= 50 positives and precision >= 0.90 (cash_guard.HAND_TO_POCKET_MIN_PRECISION).
"""
import argparse
import csv
import importlib
import json
import os
import sys

MIN_PRECISION = 0.90
MIN_CLIPS, MIN_POSITIVES = 200, 50


def metrics(labels, scores, threshold=0.5):
    tp = fp = fn = tn = 0
    for y, s in zip(labels, scores):
        p = s >= threshold
        if p and y:
            tp += 1
        elif p and not y:
            fp += 1
        elif not p and y:
            fn += 1
        else:
            tn += 1
    prec = tp / (tp + fp) if tp + fp else None
    rec = tp / (tp + fn) if tp + fn else None
    f1 = (2 * prec * rec / (prec + rec)) if prec and rec else None
    n, pos = len(labels), sum(1 for y in labels if y)
    allowed = (n >= MIN_CLIPS and pos >= MIN_POSITIVES and prec is not None
               and prec >= MIN_PRECISION)
    r4 = lambda v: None if v is None else round(v, 4)  # noqa: E731
    return {"n": n, "positives": pos, "tp": tp, "fp": fp, "fn": fn, "tn": tn,
            "precision": r4(prec), "recall": r4(rec), "f1": r4(f1),
            "threshold": threshold, "min_precision": MIN_PRECISION,
            "label_allowed": allowed}


def load_frames(path):
    """JPEG frames of one clip: a folder of .jpg, an ACG1 clip, or a video
    (OpenCV, sampled at ~5 fps)."""
    if os.path.isdir(path):
        out = []
        for n in sorted(os.listdir(path)):
            if n.lower().endswith((".jpg", ".jpeg")):
                with open(os.path.join(path, n), "rb") as f:
                    out.append(f.read())
        return out
    with open(path, "rb") as f:
        head = f.read(4)
    if head == b"ACG1":
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "edge", "shopbox"))
        from shopbox.clip import decode_container
        with open(path, "rb") as f:
            return decode_container(f.read())[1]
    import cv2
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 25
    step = max(1, int(round(fps / 5)))
    out, i = [], 0
    while True:
        ok, fr = cap.read()
        if not ok:
            break
        if i % step == 0:
            out.append(cv2.imencode(".jpg", fr)[1].tobytes())
        i += 1
    cap.release()
    return out


def run(folder, predict, threshold):
    labels, scores = [], []
    with open(os.path.join(folder, "labels.csv"), newline="") as f:
        for row in csv.DictReader(f):
            frames = load_frames(os.path.join(folder, row["file"]))
            labels.append(int(row["label"]) == 1)
            scores.append(float(predict(frames)))
    return metrics(labels, scores, threshold)


def self_test():
    r = metrics([1, 1, 0, 0, 1], [0.9, 0.2, 0.7, 0.1, 0.8])
    assert (r["tp"], r["fp"], r["fn"], r["tn"]) == (2, 1, 1, 1), r
    assert r["precision"] == 0.6667 and r["recall"] == 0.6667 and not r["label_allowed"]
    big = metrics([1] * 60 + [0] * 160, [0.9] * 58 + [0.1] * 2 + [0.1] * 157 + [0.9] * 3)
    assert big["precision"] == round(58 / 61, 4) and big["label_allowed"], big
    print(json.dumps({"self_test": "ok"}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("folder", nargs="?")
    ap.add_argument("--detector", default="")
    ap.add_argument("--threshold", type=float, default=0.5)
    ap.add_argument("--out", default="")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not a.folder or not a.detector:
        print(json.dumps({"status": "not measured",
                          "why": "no labelled real clips / no detector given"}))
        return
    mod, fn = a.detector.split(":")
    rep = run(a.folder, getattr(importlib.import_module(mod), fn), a.threshold)
    print(json.dumps(rep, indent=1))
    if a.out:
        with open(a.out, "w") as f:
            json.dump(rep, f, indent=1)


if __name__ == "__main__":
    main()
