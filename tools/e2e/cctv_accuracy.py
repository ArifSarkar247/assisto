"""cctvtoday: honest precision / recall of the CCTV person + motion checks on a
LABELED public test set (run in CI only: .github/workflows/cctv-accuracy.yml).

    python tools/e2e/cctv_accuracy.py --ann instances_val2017.json \
        --model models/yolox_nano.onnx --out results.json

Test set (built fresh each run, fixed seed, nothing committed):
  * COCO val2017 (annotations CC BY 4.0, cocodataset.org). Only images whose
    own licence is CC BY 2.0 (id 4), CC BY-SA 2.0 (id 5), "No known copyright
    restrictions" (7) or "United States Government Work" (8) are used.
  * POSITIVE = at least one non-crowd person box >= MIN_PERSON_FRAC of the
    image (a person a camera should alert on); NEGATIVE = no person
    annotation at all. Images with only tiny / crowd persons are left out
    (ambiguous) — the rule is reported with the numbers.
  * Each image is scored three ways: as-is, "cctv" (long side 640, blur,
    JPEG q40) and "night_ir" (grey, dark, sensor noise, JPEG q40).
Person check = the SAME code the Shop Box runs (edge/shopbox YOLOX-Nano,
score threshold 0.45; the phone's Kotlin channel uses the same model and
threshold). Motion = the Shop Box frame-difference detector on synthetic
6-frame sequences: a real person cut-out (COCO mask) walking over a real
no-person background (positive) vs the same background with lighting
flicker, sensor noise and 1-2 px camera shake (negative).
"""
import argparse
import io
import json
import os
import random
import sys
import time
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "edge", "shopbox"))

OK_LICENCES = {4: "CC BY 2.0", 5: "CC BY-SA 2.0", 7: "No known copyright restrictions",
               8: "United States Government Work"}
MIN_PERSON_FRAC = 0.01
SEED = 20261109


def build_set(ann, n_pos, n_neg):
    persons = {}
    any_person = set()
    for a in ann["annotations"]:
        if a["category_id"] != 1:
            continue
        any_person.add(a["image_id"])
        if not a.get("iscrowd"):
            persons.setdefault(a["image_id"], []).append(a)
    pos, neg = [], []
    for im in ann["images"]:
        if im.get("license") not in OK_LICENCES:
            continue
        area = float(im["width"] * im["height"])
        big = [a for a in persons.get(im["id"], []) if a["area"] / area >= MIN_PERSON_FRAC]
        if big:
            pos.append((im, big))
        elif im["id"] not in any_person:
            neg.append((im, []))
    rnd = random.Random(SEED)
    rnd.shuffle(pos)
    rnd.shuffle(neg)
    return pos[:n_pos], neg[:n_neg]


def fetch(im, cache):
    import cv2
    p = os.path.join(cache, im["file_name"])
    if not os.path.exists(p):
        for attempt in range(3):
            try:
                with urllib.request.urlopen(im["coco_url"], timeout=30) as r:
                    data = r.read()
                with open(p, "wb") as f:
                    f.write(data)
                break
            except Exception:
                time.sleep(2 + attempt * 3)
        else:
            return None
    return cv2.imread(p)


def jpeg(img, q):
    import cv2
    ok, b = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])
    return cv2.imdecode(b, cv2.IMREAD_COLOR)


def variant(img, name, rnd):
    import cv2
    if name == "clean":
        return img
    h, w = img.shape[:2]
    s = 640.0 / max(h, w)
    small = cv2.resize(img, (max(1, int(w * s)), max(1, int(h * s))), interpolation=cv2.INTER_AREA)
    if name == "cctv":
        return jpeg(cv2.GaussianBlur(small, (3, 3), 0), 40)
    # night_ir: grey, darker, noisy
    g = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32)
    g = 255.0 * np.power(g / 255.0, 1.6) * 0.75
    g += np.random.default_rng(rnd.randrange(1 << 30)).normal(0, 10, g.shape)
    g = np.clip(g, 0, 255).astype(np.uint8)
    return jpeg(cv2.cvtColor(g, cv2.COLOR_GRAY2BGR), 40)


def prf(tp, fp, fn, tn):
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    acc = (tp + tn) / max(1, tp + fp + fn + tn)
    return {"precision": round(p, 4), "recall": round(r, 4), "f1": round(f, 4),
            "accuracy": round(acc, 4), "tp": tp, "fp": fp, "fn": fn, "tn": tn}


def eval_person(det, items, rnd):
    """-> {variant: {thr: counts}} using the max person score per image."""
    thrs = [0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6]
    scores = {v: [] for v in ("clean", "cctv", "night_ir")}
    for img, label in items:
        for v in scores:
            x = variant(img, v, rnd)
            ds = det.detect(x, score_thr=0.2)
            scores[v].append((max([d.score for d in ds] or [0.0]), label))
    out = {}
    for v, rows in scores.items():
        out[v] = {}
        for t in thrs:
            tp = sum(1 for s, l in rows if l and s >= t)
            fn = sum(1 for s, l in rows if l and s < t)
            fp = sum(1 for s, l in rows if not l and s >= t)
            tn = sum(1 for s, l in rows if not l and s < t)
            out[v]["%.2f" % t] = prf(tp, fp, fn, tn)
    return out


def person_cutout(img, anns):
    """(rgb patch, mask) of the biggest person with a polygon mask."""
    import cv2
    a = max(anns, key=lambda z: z["area"])
    seg = a.get("segmentation")
    if not isinstance(seg, list) or not seg:
        return None
    m = np.zeros(img.shape[:2], np.uint8)
    for poly in seg:
        pts = np.array(poly, np.float32).reshape(-1, 2).astype(np.int32)
        cv2.fillPoly(m, [pts], 255)
    x, y, w, h = [int(v) for v in a["bbox"]]
    if w < 8 or h < 16:
        return None
    return img[y:y + h, x:x + w].copy(), m[y:y + h, x:x + w].copy()


def eval_motion(pos, neg, rnd, n):
    """Synthetic sequences on real backgrounds -> motion detector P/R."""
    import cv2
    from shopbox.motion import MotionDetector
    tp = fp = fn = tn = 0
    bgs = [img for img, _ in neg]
    cuts = [c for c in (person_cutout(img, anns) for img, anns in pos) if c is not None]
    for i in range(min(n, len(bgs), len(cuts))):
        bg = cv2.resize(bgs[i], (640, 360))
        patch, mask = cuts[i]
        ph = rnd.randint(110, 220)
        pw = min(560, max(8, int(patch.shape[1] * ph / patch.shape[0])))
        patch = cv2.resize(patch, (pw, ph))
        mask = cv2.resize(mask, (pw, ph)) > 127
        for positive in (True, False):
            md = MotionDetector()
            fired = False
            y0 = 360 - ph - rnd.randint(0, 20)
            for k in range(6):
                f = bg.astype(np.float32)
                if positive and k >= 3:          # walks in after warm-up
                    x0 = max(0, min(640 - pw, 40 + (k - 3) * 90 + i % 50))
                    roi = f[y0:y0 + ph, x0:x0 + pw]
                    roi[mask] = patch[mask]
                else:
                    f *= 1.0 + rnd.uniform(-0.06, 0.06)            # light flicker
                    dx, dy = rnd.randint(-2, 2), rnd.randint(-1, 1)  # shake
                    f = np.roll(np.roll(f, dx, axis=1), dy, axis=0)
                f += np.random.default_rng(rnd.randrange(1 << 30)).normal(0, 4, f.shape)
                frame = jpeg(np.clip(f, 0, 255).astype(np.uint8), 60)
                if md.update(frame).motion:
                    fired = True
            if positive:
                tp, fn = tp + fired, fn + (not fired)
            else:
                fp, tn = fp + fired, tn + (not fired)
    return prf(tp, fp, fn, tn)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ann", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", default="cctv_accuracy.json")
    ap.add_argument("--cache", default="/tmp/coco_eval")
    ap.add_argument("--n", type=int, default=300)
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    from shopbox.person import load_detector
    det = load_detector(a.model, score_thr=0.45)
    assert getattr(det, "name", "") == "yolox_nano", "person model did not load"
    ann = json.load(open(a.ann))
    pos, neg = build_set(ann, a.n, a.n)
    rnd = random.Random(SEED)
    items, pos_imgs, neg_imgs, ids = [], [], [], []
    for im, anns in pos + neg:
        img = fetch(im, a.cache)
        if img is None:
            continue
        items.append((img, bool(anns)))
        ids.append({"id": im["id"], "label": "person" if anns else "no_person",
                    "licence": OK_LICENCES[im["license"]], "url": im["coco_url"],
                    "flickr": im.get("flickr_url", "")})
        (pos_imgs if anns else neg_imgs).append((img, anns))
    person = eval_person(det, items, rnd)
    motion = eval_motion(pos_imgs, neg_imgs, rnd, 200)
    res = {"set": {"source": "COCO val2017", "positives": len(pos_imgs),
                   "negatives": len(neg_imgs), "min_person_frac": MIN_PERSON_FRAC,
                   "licences": sorted(set(OK_LICENCES.values())), "seed": SEED},
           "person_check": person, "production_threshold": "0.45",
           "motion_check": motion, "images": ids}
    json.dump(res, open(a.out, "w"), indent=1)
    print("TEST SET: %d person / %d no-person images" % (len(pos_imgs), len(neg_imgs)))
    for v, by in person.items():
        r = by["0.45"]
        best = max(by.items(), key=lambda kv: kv[1]["f1"])
        print("PERSON %-8s thr0.45  P=%.3f R=%.3f F1=%.3f | best thr %s P=%.3f R=%.3f"
              % (v, r["precision"], r["recall"], r["f1"], best[0],
                 best[1]["precision"], best[1]["recall"]))
    print("MOTION synthetic  P=%.3f R=%.3f (n=%d seq pairs)"
          % (motion["precision"], motion["recall"], (motion["tp"] + motion["fn"])))


if __name__ == "__main__":
    main()
