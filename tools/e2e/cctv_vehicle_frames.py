"""cctvdet3 DIAGNOSTIC: are the stage-2 test scenes the problem? Frame-level
precision / recall of the box's detector on

  old_paste     the stage-2 scenes: a COCO vehicle cut out by its polygon and
                pasted on a random COCO picture (often indoors)
  coco_insitu   the SAME COCO vehicles in their own photo
  sylhet        REAL Bangladeshi street photos (cctv_real_set.py, CC BY 4.0),
                day, night (street light) and day turned to grey IR
  person_paste / person_insitu   the same question for people

for YOLOX-Nano (the box's model today) and YOLOX-Tiny (Apache-2.0, 20.2 MB,
under model_fetch.MODEL_MAX_BYTES), on the whole frame and on the zone crop
(the "second look"). Every number is split CALIBRATION / HELD-OUT.
CI only (cctv-detect-accuracy.yml, mode=frames); nothing downloaded is committed.
"""
import argparse
import json
import os
import random
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "edge", "shopbox"))
sys.path.insert(0, HERE)

import cctv_accuracy as CA  # noqa: E402
import cctv_detect_accuracy as DA  # noqa: E402
import cctv_real_set as RS  # noqa: E402

W, H = 640, 360
THRS = [0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]
VEH = (1, 2, 3, 5, 7)


class Raw:
    """One forward pass -> every (cls, score, box) above 0.08 (NMS per class),
    so all thresholds are read from the same pass."""

    def __init__(self, path, name):
        from shopbox.person import YoloxPersonDetector
        self.d = YoloxPersonDetector(path, score_thr=0.08)
        self.name = name

    def __call__(self, img_bgr):
        from shopbox.night import model_input
        from shopbox.person import _decode, _letterbox
        img, _n = model_input(img_bgr)
        h, w = img.shape[:2]
        blob, ratio = _letterbox(img, 416)
        out = self.d._sess.run(None, {self.d._input: blob})[0][0]
        res = []
        for c in (0,) + VEH:
            for d in _decode(out, self.d._grids, self.d._expanded_strides, ratio, w, h,
                             0.08, 0.45, cls=c):
                res.append((c, d.score, (d.x1, d.y1, d.x2, d.y2)))
        return res


def score_frame(dets, gts, want, min_h=0.06):
    """-> per threshold (tp, fp, fn). gts: [(box, counts)] counts=True when
    big enough to be required; dets matched greedily by IoU >= 0.3."""
    out = []
    for t in THRS:
        ds = sorted([d for d in dets if d[0] in want and d[1] >= t], key=lambda d: -d[1])
        used = set()
        tp = fn = fp = 0
        for gb, req in gts:
            best, bi = None, 0.3
            for i, d in enumerate(ds):
                if i in used:
                    continue
                v = RS.iou(gb, d[2])
                if v >= bi:
                    best, bi = i, v
            if best is not None:
                used.add(best)
                tp += int(req)
            elif req:
                fn += 1
        for i, d in enumerate(ds):
            if i not in used and d[2][3] - d[2][1] >= min_h:
                # unmatched: FP unless it overlaps any labelled object
                if not any(RS.iou(gb, d[2]) >= 0.3 for gb, _ in gts):
                    fp += 1
        out.append((tp, fp, fn))
    return out


def zoom_crop(img, box):
    """The analyzer's second-look crop of a zone drawn around `box`."""
    x1, y1, x2, y2 = box
    bw, bh = x2 - x1, y2 - y1
    zx1, zy1, zx2, zy2 = x1 - .25 * bw, y1 - .25 * bh, x2 + .25 * bw, y2 + .25 * bh
    px, py = (zx2 - zx1) * .15, (zy2 - zy1) * .15
    X1, Y1 = max(0., zx1 - px), max(0., zy1 - py)
    X2, Y2 = min(1., zx2 + px), min(1., zy2 + py)
    crop = img[int(Y1 * H):max(int(Y1 * H) + 2, int(Y2 * H)), int(X1 * W):max(int(X1 * W) + 2, int(X2 * W))]
    nb = ((x1 - X1) / (X2 - X1), (y1 - Y1) / (Y2 - Y1), (x2 - X1) / (X2 - X1), (y2 - Y1) / (Y2 - Y1))
    return crop, nb


class Acc:
    def __init__(self):
        self.r = {}

    def add(self, key, res):
        a = self.r.setdefault(key, [[0, 0, 0] for _ in THRS])
        for i, (tp, fp, fn) in enumerate(res):
            a[i][0] += tp
            a[i][1] += fp
            a[i][2] += fn


def finish_u8(f, night, rng):
    return DA.finish(f.astype(np.float32), night, rng)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ann", required=True)
    ap.add_argument("--model", action="append", required=True,
                    help="name=path.onnx (repeat); the first one also scores people")
    ap.add_argument("--out", default="cctv_frames.json")
    ap.add_argument("--cache", default="/tmp/coco_eval")
    ap.add_argument("--real-cache", default="/tmp/sylhet")
    ap.add_argument("--n", type=int, default=200)
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    models = [Raw(p, n) for n, p in (m.split("=", 1) for m in a.model)]
    ann = json.load(open(a.ann))
    rnd = random.Random(DA.SEED + 99)
    acc = Acc()
    per_cls = {}
    # ---- COCO: backgrounds, people, vehicles (licensed images only)
    pos, neg = CA.build_set(ann, 160, 160)
    bgs = [(im["id"], CA.fetch(im, a.cache)) for im, _ in neg]
    bgs = [(i, b) for i, b in bgs if b is not None]
    people = []
    for im, anns in pos:
        img = CA.fetch(im, a.cache)
        if img is None:
            continue
        c = CA.person_cutout(img, anns)
        if c is not None and c[0].shape[0] >= 120 and c[0].shape[0] > c[0].shape[1]:
            people.append((im, img, anns, c))
    vcuts, vids = DA.vehicle_cutouts(ann, a.cache, 160)
    vimgs = {}
    for v in vids:
        im = next(x for x in ann["images"] if x["id"] == v["id"])
        vimgs[v["id"]] = (im, CA.fetch(im, a.cache))
    vann = {}
    for an in ann["annotations"]:
        if an["image_id"] in vimgs and an["category_id"] in DA.VEH_CATS and not an.get("iscrowd"):
            vann.setdefault(an["image_id"], []).append(an)
    print("coco: bgs %d people %d vehicles %d" % (len(bgs), len(people), len(vcuts)), flush=True)

    def split_id(i):
        return RS.split_of("coco%d" % i)

    # old_paste: exactly the stage-2 composition
    for k, (cut, vid) in enumerate(zip(vcuts, vids)):
        for night in (False, True):
            bi, bg = bgs[rnd.randrange(len(bgs))]
            f = DA.fit(bg)
            pm = DA.scaled_w(cut, rnd.uniform(0.25, 0.35))
            cx, foot = rnd.uniform(0.25, 0.75), rnd.uniform(0.8, 0.95)
            DA.paste(f, pm, cx, foot)
            ph, pw = pm[1].shape
            ys, xs = np.nonzero(pm[1])
            x0, y0 = cx * W - pw / 2, foot * H - ph
            gb = ((x0 + xs.min()) / W, max(0, y0 + ys.min()) / H, min(W, x0 + xs.max()) / W,
                  min(H, y0 + ys.max()) / H)
            img = finish_u8(f, night, np.random.default_rng(k))
            for m in models:
                acc.add(("old_paste", m.name, "full", "night" if night else "day",
                         split_id(vid["id"])), score_frame(m(img), [(gb, True)], VEH))
    # coco_insitu: the same vehicles in their own photo
    for vid in vids:
        im, img = vimgs[vid["id"]]
        if img is None:
            continue
        h0, w0 = img.shape[:2]
        s = max(W / w0, H / h0)
        ox, oy = (w0 * s - W) / 2, (h0 * s - H) / 2
        gts = []
        for an in vann.get(vid["id"], []):
            x, y, bw, bh = an["bbox"]
            b = ((x * s - ox) / W, (y * s - oy) / H, ((x + bw) * s - ox) / W, ((y + bh) * s - oy) / H)
            cb = (max(0, b[0]), max(0, b[1]), min(1, b[2]), min(1, b[3]))
            if cb[2] <= cb[0] or cb[3] <= cb[1]:
                continue
            vis = (cb[2] - cb[0]) * (cb[3] - cb[1]) / max(1e-6, (b[2] - b[0]) * (b[3] - b[1]))
            gts.append((cb, vis > 0.7 and cb[3] - cb[1] >= 0.08))
        if not any(r for _, r in gts):
            continue
        f = DA.fit(img)
        for night in (False, True):
            fr = finish_u8(f, night, np.random.default_rng(vid["id"]))
            for m in models:
                acc.add(("coco_insitu", m.name, "full", "night" if night else "day",
                         split_id(vid["id"])), score_frame(m(fr), gts, VEH))
    # people: pasted (stage-2 scenes) vs in their own photo
    for k, (im, img, anns, cut) in enumerate(people):
        sp = split_id(im["id"])
        for night in (False, True):
            bi, bg = bgs[rnd.randrange(len(bgs))]
            f = DA.fit(bg)
            pm = DA.scaled_cut(cut, rnd.uniform(0.45, 0.6), rnd)
            cx, foot = rnd.uniform(0.3, 0.7), rnd.uniform(0.86, 0.98)
            DA.paste(f, pm, cx, foot)
            ph, pw = pm[1].shape
            gb = ((cx * W - pw / 2) / W, max(0, foot * H - ph) / H, (cx * W + pw / 2) / W, foot * H / H)
            fr = finish_u8(f, night, np.random.default_rng(k))
            m = models[0]
            acc.add(("person_paste", m.name, "full", "night" if night else "day", sp),
                    score_frame(m(fr), [(gb, True)], (0,)))
            h0, w0 = img.shape[:2]
            s = max(W / w0, H / h0)
            ox, oy = (w0 * s - W) / 2, (h0 * s - H) / 2
            gts = []
            for an in anns:
                x, y, bw, bh = an["bbox"]
                b = ((x * s - ox) / W, (y * s - oy) / H, ((x + bw) * s - ox) / W, ((y + bh) * s - oy) / H)
                cb = (max(0, b[0]), max(0, b[1]), min(1, b[2]), min(1, b[3]))
                if cb[2] > cb[0] and cb[3] > cb[1]:
                    gts.append((cb, cb[3] - cb[1] >= 0.25))
            if any(r for _, r in gts):
                fr = finish_u8(DA.fit(img), night, np.random.default_rng(k + 7))
                acc.add(("person_insitu", m.name, "full", "night" if night else "day", sp),
                        score_frame(m(fr), gts, (0,)))
    print("coco done", flush=True)
    # ---- REAL Bangladeshi street photos
    real = RS.load(a.n, a.n, a.real_cache)
    print("sylhet: %d photos (%d day, %d night)" % (
        len(real), sum(r["light"] == "day" for r in real), sum(r["light"] == "night" for r in real)),
        flush=True)
    for k, it in enumerate(real):
        gts = [((b[1], b[2], b[3], b[4]), b[4] - b[2] >= 0.08) for b in it["boxes"]]
        views = [("night" if it["light"] == "night" else "day", False)]
        if it["light"] == "day":
            views.append(("day_ir", True))
        for light, ir in views:
            fr = finish_u8(it["img"], ir, np.random.default_rng(k))
            for m in models:
                dets = m(fr)
                acc.add(("sylhet", m.name, "full", light, it["split"]), score_frame(dets, gts, VEH))
                # per class recall at 0.25 / 0.35 (full frame)
                for b in it["boxes"]:
                    if b[4] - b[2] < 0.08:
                        continue
                    pc = per_cls.setdefault("%s|%s|%s" % (m.name, light, b[0]), [0, 0, 0])
                    pc[0] += 1
                    hit = [d for d in dets if d[0] in VEH and RS.iou((b[1], b[2], b[3], b[4]), d[2]) >= 0.3]
                    pc[1] += int(any(d[1] >= 0.25 for d in hit))
                    pc[2] += int(any(d[1] >= 0.35 for d in hit))
                # the second look: each required vehicle in its zone crop
                big = [g for g in gts if g[1]][:2]
                for gb, _ in big:
                    crop, nb = zoom_crop(fr, gb)
                    cd = m(crop)
                    acc.add(("sylhet", m.name, "zoom", light, it["split"]),
                            score_frame(cd, [(nb, True)], VEH, min_h=10.0))
    # ---- the independent held-out set (Dhaka / Sirajganj), never trained on
    br = RS.load_banglaroad(a.real_cache + "_br")
    print("banglaroad: %d photos" % len(br), flush=True)
    for k, it in enumerate(br):
        gts = []
        for b in it["boxes"]:
            bb = (b[1], b[2], b[3], b[4])
            gts.append((bb, b[0] in RS.BR_VEHICLES and b[4] - b[2] >= 0.08))
        fr = finish_u8(it["img"], False, np.random.default_rng(k))
        for m in models:
            dets = m(fr)
            acc.add(("banglaroad", m.name, "full", "day", "held"), score_frame(dets, gts, VEH))
            for b in it["boxes"]:
                if b[0] not in RS.BR_VEHICLES or b[4] - b[2] < 0.08:
                    continue
                pc = per_cls.setdefault("%s|br|%s" % (m.name, b[0]), [0, 0, 0])
                pc[0] += 1
                hit = [d for d in dets if d[0] in VEH and RS.iou((b[1], b[2], b[3], b[4]), d[2]) >= 0.3]
                pc[1] += int(any(d[1] >= 0.25 for d in hit))
                pc[2] += int(any(d[1] >= 0.35 for d in hit))
    res = {"sources": {"coco": "COCO val2017 (CC BY 4.0 annotations; licensed images only)",
                       "sylhet": RS.SOURCE, "banglaroad": RS.BANGLAROAD},
           "thresholds": THRS, "counts": {"|".join(k): v for k, v in acc.r.items()},
           "per_class": per_cls}
    json.dump(res, open(a.out, "w"), indent=1)
    print("SET          MODEL VIEW LIGHT  SPLIT  " + "  ".join("t%.2f P/R" % t for t in THRS))
    for k in sorted(acc.r):
        cells = []
        for tp, fp, fn in acc.r[k]:
            p = tp / (tp + fp) if tp + fp else 0.0
            r = tp / (tp + fn) if tp + fn else 0.0
            cells.append("%.2f/%.2f" % (p, r))
        n = acc.r[k][0][0] + acc.r[k][0][2]
        print("%-12s %-5s %-4s %-6s %-5s n=%-4d %s" % (k + (n, " ".join(cells))))
    print("PER CLASS recall (full frame) @0.25 / @0.35")
    for k in sorted(per_cls):
        n, a25, a35 = per_cls[k]
        print("  %-32s n=%-4d %.2f %.2f" % (k, n, a25 / n if n else 0, a35 / n if n else 0))


if __name__ == "__main__":
    main()
