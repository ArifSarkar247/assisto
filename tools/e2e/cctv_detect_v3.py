"""cctvdet3: zone-detection precision / recall, TUNED ON ONE HALF, REPORTED ON
THE OTHER. CI only (cctv-detect-accuracy.yml, mode=v3); nothing downloaded
is committed.

TWO TEST SETS
  old   the stage-2 scenarios (tools/e2e/cctv_detect_accuracy.py): COCO
        val2017 people / vehicles cut out by their polygon and pasted on
        random licensed COCO pictures.
  real  vehicles in REAL Bangladeshi street photos (tools/e2e/cctv_real_set.py,
        Sylhet, CC BY 4.0): a parked vehicle IN ITS OWN PHOTO (zone drawn
        around it), an empty spot of a real photo, and a rectangular crop of
        a real vehicle (with its own road / shadow) moving through or
        parking in another photo of the same set.

SPLIT  every image (COCO by id, Sylhet by name) is CALIBRATION or HELD-OUT by
a hash (cctv_real_set.split_of). Each grid below is searched on CALIBRATION
scenarios only; the pick = highest recall with precision >= P_MIN on every
set of that group (ties -> the cheaper / earlier option). BASELINE (the
stage-2 settings) and the PICK are then run on HELD-OUT scenarios — those
are the reported numbers.

Model outputs are cached per input picture (one forward pass serves every
threshold of the grid: NMS on the lower threshold then filtering gives the
same boxes as NMS on the higher one).
"""
import argparse
import hashlib
import json
import os
import random
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "edge", "shopbox"))
sys.path.insert(0, HERE)

import cctv_accuracy as CA  # noqa: E402
import cctv_detect_accuracy as DA  # noqa: E402
import cctv_real_set as RS  # noqa: E402

W, H = 640, 360
P_MIN = 0.92
FLOOR = 0.08


# ------------------------------------------------------------------ cache
class Cached:
    """Duck-types shopbox.person.YoloxPersonDetector (detect / detect_all /
    detect_vehicles) over ONE cached forward pass per picture."""

    def __init__(self, path, name, threads=4):
        from shopbox.person import YoloxPersonDetector
        self.d = YoloxPersonDetector(path, score_thr=0.45, threads=threads)
        self.name = name
        self.available = True
        self.cache = {}
        self.calls = 0

    def _raw(self, img):
        from shopbox.person import VEHICLE_CLASS_IDS, _decode, _letterbox
        k = hashlib.blake2b(img.tobytes(), digest_size=16)
        k.update(str(img.shape).encode())
        k = k.digest()
        r = self.cache.get(k)
        if r is None:
            self.calls += 1
            h, w = img.shape[:2]
            blob, ratio = _letterbox(img, 416)
            out = self.d._sess.run(None, {self.d._input: blob})[0][0]
            r = {c: _decode(out, self.d._grids, self.d._expanded_strides, ratio, w, h,
                            FLOOR, self.d.nms_thr, cls=c) for c in (0,) + VEHICLE_CLASS_IDS}
            self.cache[k] = r
        return r

    def detect(self, img, score_thr=None):
        thr = 0.45 if score_thr is None else float(score_thr)
        return [d for d in self._raw(img)[0] if d.score >= thr]

    def detect_vehicles(self, img, vehicle_thr=0.35):
        from shopbox.person import VEHICLE_CLASS_IDS, Vehicle, class_thr
        r = self._raw(img)
        return [Vehicle(d.x1, d.y1, d.x2, d.y2, d.score, c) for c in VEHICLE_CLASS_IDS
                for d in r[c] if d.score >= class_thr(c, vehicle_thr)]

    def detect_all(self, img, score_thr=None, vehicle_thr=0.35):
        return self.detect(img, score_thr), self.detect_vehicles(img, vehicle_thr)


# ------------------------------------------------------------------ config
BASE_RULES = {"TRACK_JUMP_CAP": 0.25, "CROSS_MARGIN": 0.0, "DWELL_KEEP_SCORE": 1.0,
              "CROWD_SCORE": 1.0, "CROWD_KEEP_S": -1.0, "POST_WEAK_HITS": 1,
              "PRESENCE_GAP_S": 10.0, "POST_PRESENCE_SCORE": 0.25, "VEH_START_SCORE": 0.0,
              "VEH_PRESENT_FRAC": 0.0}
BASELINE = {"rules": dict(BASE_RULES), "veh_model": "nano", "veh_thr": 0.35, "veh_zoom": False,
            "veh_union": False}
VEH = {}                      # name -> Cached


def apply(cfg):
    from shopbox import analyzer as AN
    from shopbox import detect_rules as DR
    from shopbox import person as P
    for k, v in cfg["rules"].items():
        setattr(DR, k, v)
    P.VEHICLE_SCORES.clear()
    P.VEHICLE_SCORES.update({int(k): float(v) for k, v in (cfg.get("veh_cls") or {}).items()})
    AN.VEH_SCORE = float(cfg["veh_thr"])
    AN.VEH_ZOOM = bool(cfg["veh_zoom"])
    AN.VEH_UNION = bool(cfg.get("veh_union"))
    AN.VEH_COCO_SCORE = 0.35
    AN.VEH_TINY_SCORE = float(cfg["veh_thr"])
    AN.VEH_PERSON_IOU = float(cfg.get("veh_person_iou", 1.0))
    vd = VEH.get(cfg["veh_model"]) if cfg["veh_model"] != "nano" else None

    def analyzer(zones, det, schedule=None):
        an = ORIG_ANALYZER(zones, det, schedule)
        an.vehicle_detector = vd
        return an
    DA.analyzer = analyzer


ORIG_ANALYZER = DA.analyzer


def merged(base, **kw):
    c = json.loads(json.dumps(base))
    for k, v in kw.items():
        if k == "rules":
            c["rules"].update(v)
        else:
            c[k] = v
    return c


# ------------------------------------------------------------------ real scenarios
LINE = [[0.5, 0.0], [0.5, 1.0]]


def _clear_target(it):
    out = []
    for b in it["boxes"]:
        _, x1, y1, x2, y2 = b
        if y2 - y1 < 0.12 or x2 - x1 > 0.45 or x1 < 0.01 or x2 > 0.99 or y2 > 0.99:
            continue
        if any(o is not b and RS.iou((x1, y1, x2, y2), o[1:]) > 0.3 for o in it["boxes"]):
            continue
        out.append(b)
    return out


def _rect(x1, y1, x2, y2):
    return [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]


def _empty_spot(it, bw, bh, rnd):
    """A zone of (bw, bh) in `it` with no labelled object touching it."""
    for _ in range(60):
        cx, cy = rnd.uniform(bw / 2 + 0.02, 1 - bw / 2 - 0.02), rnd.uniform(0.45, 0.9 - bh / 2)
        z = (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)
        if z[1] < 0.02 or z[3] > 0.98:
            continue
        if all(RS.iou(z, b[1:]) == 0.0 for b in it["boxes"]):
            return z
    return None


def _fin(f, rng, rnd):
    return DA.finish(f, False, rng, rnd.uniform(3, 6), 1 + rnd.uniform(-0.04, 0.04))


def real_parking(items, det, n, rnd, ztype):
    rows = []
    if ztype == "parking":
        step, total, want = 30.0, 420.0, "parking_overstay"
        kinds = ("pos_real", "pos_paste", "neg_empty", "neg_leaves", "neg_turnover")
    else:
        step, total, want = 10.0, 240.0, "wrong_parking"
        kinds = ("pos_real", "pos_paste", "neg_empty", "neg_passing", "neg_short")
    for i in range(n):
        for light in ("day", "night"):
            pool = [it for it in items if it["light"] == light]
            src_pool = [(it, b) for it in pool for b in _clear_target(it)]
            if not pool or not src_pool:
                continue
            for kind in kinds:
                rng = np.random.default_rng(rnd.randrange(1 << 30))
                src, b = src_pool[rnd.randrange(len(src_pool))]
                crop = RS.vehicle_crop(src, b)
                bw, bh = (b[3] - b[1]) * 1.5, (b[4] - b[2]) * 1.5
                if kind == "pos_real":
                    it = src
                    cx, cy = (b[1] + b[3]) / 2, (b[2] + b[4]) / 2
                    zb = (max(0, cx - bw / 2), max(0, cy - bh / 2), min(1, cx + bw / 2), min(1, cy + bh / 2))
                else:
                    it = pool[rnd.randrange(len(pool))]
                    zb = _empty_spot(it, bw, bh, rnd)
                    if zb is None:
                        continue
                zcx, zcy = (zb[0] + zb[2]) / 2, (zb[1] + zb[3]) / 2
                others = [RS.vehicle_crop(s2, b2) for s2, b2 in
                          (src_pool[rnd.randrange(len(src_pool))] for _ in range(8))]
                zone = {"id": "pk", "type": ztype, "points": _rect(*zb),
                        "opts": {"overstay_min": 5} if ztype == "parking" else {"wrong_s": 120}}
                an = DA.analyzer([zone], det)
                bg = it["img"].astype(np.float32)
                frames = []
                t, k = 0.0, 0
                while t <= total:
                    f = bg.copy()
                    if kind == "pos_paste":
                        RS.blend(f, crop, zcx, zcy)
                    elif kind == "neg_leaves" and t < 180:
                        RS.blend(f, crop, zcx, zcy)
                    elif kind == "neg_short" and t < 60:
                        RS.blend(f, crop, zcx, zcy)
                    elif kind == "neg_turnover":
                        slot = int(t // 60)
                        RS.blend(f, others[slot % len(others)], zcx + (0.05 if slot % 2 else -0.05), zcy)
                    elif kind == "neg_passing":
                        RS.blend(f, others[k % len(others)], zcx + (-0.12, 0.0, 0.12)[k % 3], zcy)
                    frames.append((t, _fin(f, rng, rnd)))
                    t += step
                    k += 1
                hits = DA.run(an, frames, {want})
                rows.append({"pos": kind.startswith("pos"), "hit": bool(hits),
                             "kind": "%s_%s" % (kind, light), "dur": total})
    return DA.tally(rows)


def real_in_out(items, pcuts, det, n, rnd):
    rows = []
    zone = {"id": "l1", "type": "entry_line", "points": LINE, "opts": {"vehicles": True}}
    for i in range(n):
        for light in ("day", "night"):
            pool = [it for it in items if it["light"] == light]
            src_pool = [(it, b) for it in pool for b in _clear_target(it)]
            if not pool or not src_pool:
                continue
            for kind in ("pos_in", "pos_out", "neg_turn_back", "neg_person", "neg_static"):
                rng = np.random.default_rng(rnd.randrange(1 << 30))
                it = pool[rnd.randrange(len(pool))]
                src, b = src_pool[rnd.randrange(len(src_pool))]
                crop = RS.vehicle_crop(src, b)
                cy = min(0.9, max(0.3, (b[2] + b[4]) / 2))
                if kind == "neg_person":
                    pm = DA.scaled_cut(pcuts[rnd.randrange(len(pcuts))], 0.5, rnd)
                if kind in ("pos_in", "neg_person"):
                    path = [0.88 - 0.1 * j for j in range(9)]
                elif kind == "pos_out":
                    path = [0.12 + 0.1 * j for j in range(9)]
                elif kind == "neg_turn_back":
                    path = [0.9, 0.82, 0.74, 0.66, 0.6, 0.66, 0.74, 0.82, 0.9]
                else:
                    path = [None] * 9
                an = DA.analyzer([zone], det)
                bg = it["img"].astype(np.float32)
                frames = [(j * 1.0, _fin(bg.copy(), rng, rnd)) for j in range(6)]
                for j, x in enumerate(path):
                    f = bg.copy()
                    if x is not None and kind == "neg_person":
                        DA.paste(f, pm, x, min(0.98, cy + 0.2))
                    elif x is not None:
                        RS.blend(f, crop, x, cy)
                    frames.append((6.0 + j, _fin(f, rng, rnd)))
                hits = DA.run(an, frames, {"vehicle_in_out"})
                pos = kind.startswith("pos")
                want = "in" if kind == "pos_in" else "out"
                ok = any(h[2].get("dir") == want for h in hits) if pos else bool(hits)
                rows.append({"pos": pos, "hit": ok, "kind": "%s_%s" % (kind, light), "dur": 15.0})
    return DA.tally(rows)


# ------------------------------------------------------------------ the evaluation
def detections(pools, det):
    """name -> (group, set, fn(split, rnd))."""
    def P(split):
        return pools[split]
    return {
        ("vehicle_in_out", "old"): lambda s, r: DA.vehicle_in_out(P(s)["bgs"], P(s)["vcuts"], P(s)["cuts"], det, N_OLD, r),
        ("parking_overstay", "old"): lambda s, r: DA.parking(P(s)["bgs"], P(s)["vcuts"], det, N_OLD, r, "parking"),
        ("wrong_parking", "old"): lambda s, r: DA.parking(P(s)["bgs"], P(s)["vcuts"], det, N_OLD, r, "no_parking"),
        ("vehicle_in_out", "real"): lambda s, r: real_in_out(P(s)["real"], P(s)["cuts"], det, N_REAL, r),
        ("parking_overstay", "real"): lambda s, r: real_parking(P(s)["real"], det, N_REAL, r, "parking"),
        ("wrong_parking", "real"): lambda s, r: real_parking(P(s)["real"], det, N_REAL, r, "no_parking"),
        ("post_empty", "old"): lambda s, r: DA.post_empty(P(s)["bgs"], P(s)["cuts"], det, N_OLD, r),
        ("loitering", "old"): lambda s, r: DA.loitering(P(s)["bgs"], P(s)["cuts"], det, N_OLD, r),
        ("crowd", "old"): lambda s, r: DA.crowd(P(s)["bgs"], P(s)["cuts"], det, N_OLD, r),
        ("gate_person", "old"): lambda s, r: DA.gate_person(P(s)["bgs"], P(s)["cuts"], det, N_OLD, r),
    }


GROUPS = {
    "vehicles": [("vehicle_in_out", "old"), ("parking_overstay", "old"), ("wrong_parking", "old"),
                 ("vehicle_in_out", "real"), ("parking_overstay", "real"), ("wrong_parking", "real")],
    "post": [("post_empty", "old")],
    "loiter": [("loitering", "old"), ("gate_person", "old")],
    "crowd": [("crowd", "old")],
}


def grids():
    g = {}
    v = []
    if "bd" in VEH:
        # cctvdet3 runs 43923414622 + 43967156868 (calibration): the Bangladesh
        # model + union + zoom at 0.15 had the best recall; the start score did
        # not buy precision. Searched now: the presence share (parking after
        # the car left), the person-overlap filter (walkers called cycles) and
        # the line margin (a vehicle turning back near the line).
        for frac in (0.6, 0.75, 0.85):
            for piou in (1.0, 0.5):
                for margin in (0.02, 0.06):
                    v.append({"veh_model": "bd", "veh_zoom": True, "veh_thr": 0.15, "veh_union": True,
                              "veh_person_iou": piou,
                              "rules": {"TRACK_JUMP_CAP": 0.5, "CROSS_MARGIN": margin,
                                        "VEH_PRESENT_FRAC": frac}})
    else:
        for model in ("nano", "tiny"):
            for zoom in (False, True):
                for thr in (0.25, 0.35):
                    v.append({"veh_model": model, "veh_zoom": zoom, "veh_thr": thr,
                              "rules": {"TRACK_JUMP_CAP": 0.5, "CROSS_MARGIN": 0.02}})
    g["vehicles"] = v
    g["post"] = [{"rules": {"POST_WEAK_HITS": h, "POST_PRESENCE_SCORE": s}}
                 for h in (1, 2, 3) for s in (0.2, 0.25, 0.3)]
    g["loiter"] = [{"rules": {"DWELL_KEEP_SCORE": k, "PRESENCE_GAP_S": gap}}
                   for k in (1.0, 0.3, 0.2) for gap in (16.0, 20.0)]
    g["crowd"] = [{"rules": {"CROWD_SCORE": s, "CROWD_KEEP_S": keep}}
                  for s in (1.0, 0.3, 0.2) for keep in (10.0, 20.0, 30.0)]
    return g


def run_one(fns, key, split, cfg):
    apply(cfg)
    rnd = random.Random("%s|%s|%s" % (key[0], key[1], split))
    return fns[key](split, rnd)


def feasible_score(res):
    """(all precision >= P_MIN, min recall, mean recall)."""
    ok = all(r["precision"] >= P_MIN or (r["tp"] + r["fp"] == 0 and r["tp"] + r["fn"] == 0)
             for r in res)
    rec = [r["recall"] for r in res]
    return ok, min(rec), sum(rec) / len(rec)


N_OLD = 30
N_REAL = 30
POOLS = None
ARGS = None


def run_group(gname):
    """Tune one group on CALIBRATION, then baseline vs pick on HELD-OUT."""
    a = ARGS
    single = len([g for g in a.groups.split(",") if g]) == 1
    th = 4 if single else (2 if gname == "vehicles" else 1)
    det = Cached(a.nano, "yolox_nano", threads=th)
    if gname == "vehicles":
        VEH["tiny"] = Cached(a.tiny, "yolox_tiny", threads=th)
        if a.bd:
            VEH["bd"] = Cached(a.bd, "assisto_vehicle_bd", threads=th)
    fns = detections(POOLS, det)
    keys = GROUPS[gname]
    t0 = time.time()
    trials = []
    if a.fixed:
        best = {"opt": SHIPPED[gname], "ok": None}
        print("FIXED %s %s (picked on calibration in CI 43967156868)" % (gname, json.dumps(best["opt"])),
              flush=True)
        return held_out(fns, keys, best, trials, det, t0)
    for opt in grids()[gname]:
        cfg = merged(BASELINE, **opt)
        r = [run_one(fns, k, "cal", cfg) for k in keys]
        ok, mn, mean = feasible_score(r)
        trials.append({"opt": opt, "ok": ok, "min_r": mn, "mean_r": mean,
                       "cal": {"%s/%s" % k: {"p": x["precision"], "r": x["recall"],
                                             "by": x["by_scenario"]} for k, x in zip(keys, r)}})
        print("  cal %-8s %s ok=%s minR=%.3f %.0fs %s" % (gname, json.dumps(opt), ok, mn, time.time() - t0, " ".join(
            "%s/%s %.2f/%.2f" % (k[0][:10], k[1], x["precision"], x["recall"]) for k, x in zip(keys, r))),
            flush=True)
        for k, x in zip(keys, r):
            print("      %s/%s: %s" % (k[0], k[1], ", ".join("%s %d/%d" % (s_, b["hit"], b["n"])
                                                         for s_, b in sorted(x["by_scenario"].items()))),
                  flush=True)
    good = [t for t in trials if t["ok"]]
    if good:
        best = max(good, key=lambda t: (t["min_r"], t["mean_r"], -good.index(t)))
    else:
        # nothing reaches P_MIN everywhere: the most balanced (worst of every
        # precision and recall as high as possible), never recall alone
        best = max(trials, key=lambda t: (min(min(x["p"], x["r"]) for x in t["cal"].values()),
                                          t["mean_r"], -trials.index(t)))
    print("PICK %s %s (cal ok=%s) %.0fs" % (gname, json.dumps(best["opt"]), best["ok"], time.time() - t0),
          flush=True)
    return held_out(fns, keys, best, trials, det, t0)


SHIPPED = {
    "vehicles": {"veh_model": "bd", "veh_zoom": True, "veh_thr": 0.15, "veh_union": True,
                 "rules": {"TRACK_JUMP_CAP": 0.5, "CROSS_MARGIN": 0.02}},
    "crowd": {"rules": {"CROWD_SCORE": 0.3, "CROWD_KEEP_S": 20.0}},
    "post": {"rules": {}},
    "loiter": {"rules": {}},
}


def held_out(fns, keys, best, trials, det, t0):
    chosen = merged(BASELINE, **best["opt"])
    held = {}
    for key in keys:
        b = run_one(fns, key, "held", BASELINE)
        c = run_one(fns, key, "held", chosen)
        held["%s/%s" % key] = {"baseline": b, "chosen": c}
        print("  held %s/%s baseline %.3f/%.3f new %.3f/%.3f %.0fs" % (
            key[0], key[1], b["precision"], b["recall"], c["precision"], c["recall"], time.time() - t0), flush=True)
    calls = dict({"nano": det.calls}, **{k: v.calls for k, v in VEH.items()})
    return {"trials": trials, "pick": best["opt"], "ok": best["ok"], "held": held, "calls": calls}


def main():
    global N_OLD, N_REAL
    ap = argparse.ArgumentParser()
    ap.add_argument("--ann", required=True)
    ap.add_argument("--nano", required=True)
    ap.add_argument("--tiny", required=True)
    ap.add_argument("--bd", default="", help="the Bangladesh vehicle model (mode=train artifact)")
    ap.add_argument("--out", default="cctv_detect.json")
    ap.add_argument("--cache", default="/tmp/coco_eval")
    ap.add_argument("--real-cache", default="/tmp/sylhet")
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--real", type=int, default=240, help="Sylhet photos per light")
    ap.add_argument("--groups", default="vehicles,post,loiter,crowd")
    ap.add_argument("--fixed", action="store_true",
                    help="no calibration grid: the SHIPPED settings, held-out only (before vs after)")
    a = ap.parse_args()
    N_OLD = N_REAL = a.n
    os.makedirs(a.cache, exist_ok=True)
    ann = json.load(open(a.ann))
    pos, neg = CA.build_set(ann, 320, 320)
    pools = {s: {"bgs": [], "cuts": [], "vcuts": [], "real": []} for s in ("cal", "held")}
    sources = []
    for im, _ in neg:
        img = CA.fetch(im, a.cache)
        if img is not None:
            s = RS.split_of("coco%d" % im["id"])
            pools[s]["bgs"].append(img)
            sources.append({"id": im["id"], "role": "background", "split": s,
                            "licence": CA.OK_LICENCES[im["license"]]})
    for im, anns in pos:
        img = CA.fetch(im, a.cache)
        if img is None:
            continue
        c = CA.person_cutout(img, anns)
        if c is not None and c[0].shape[0] >= 120 and c[0].shape[0] > c[0].shape[1]:
            s = RS.split_of("coco%d" % im["id"])
            pools[s]["cuts"].append(c)
            sources.append({"id": im["id"], "role": "person", "split": s,
                            "licence": CA.OK_LICENCES[im["license"]]})
    DA.CUTS[:] = pools["held"]["cuts"]
    vcuts, vids = DA.vehicle_cutouts(ann, a.cache, 240)
    for c, v in zip(vcuts, vids):
        s = RS.split_of("coco%d" % v["id"])
        pools[s]["vcuts"].append(c)
        sources.append(dict(v, split=s))
    real = RS.load(a.real, a.real, a.real_cache) if "vehicles" in a.groups else []
    for it in real:
        pools[it["split"]]["real"].append(it)
    print("pools: " + "; ".join("%s bgs %d people %d vehicles %d real %d" % (
        s, len(p["bgs"]), len(p["cuts"]), len(p["vcuts"]), len(p["real"])) for s, p in pools.items()),
        flush=True)
    res = {"sets": {"old": "COCO val2017 (CC BY 4.0 annotations; licensed images only), pasted (stage 2)",
                    "real": RS.SOURCE},
           "split": "COCO: sha256(name)[0] % 2 (cal = even); Sylhet: valid/ = cal, test/ = held",
           "p_min": P_MIN, "baseline": BASELINE, "groups": {}, "images": sources,
           "real_images": [{"key": it["key"], "split": it["split"], "light": it["light"]} for it in real]}
    # one process per group (their rule constants do not overlap), each with
    # its own models (created after the fork) and cache; vehicles get 2 threads
    global POOLS, ARGS
    POOLS, ARGS = pools, a
    import multiprocessing as mp
    groups = [g for g in a.groups.split(",") if g]
    with mp.get_context("fork").Pool(len(groups)) as pool:
        outs = pool.map(run_group, groups)
    chosen = json.loads(json.dumps(BASELINE))
    report = {}
    calls = {}
    for gname, o in zip(groups, outs):
        res["groups"][gname] = {"trials": o["trials"], "pick": o["pick"], "pick_ok_on_cal": o["ok"]}
        chosen = merged(chosen, **o["pick"])
        report.update(o["held"])
        for k, v in o["calls"].items():
            calls[k] = calls.get(k, 0) + v
    for k, v in sorted(report.items()):
        b, c = v["baseline"], v["chosen"]
        print("HELD %-22s baseline P %.3f R %.3f | new P %.3f R %.3f  (n pos %d neg %d)" % (
            k, b["precision"], b["recall"], c["precision"], c["recall"], c["tp"] + c["fn"], c["fp"] + c["tn"]))
        print("     by scenario (new): " + ", ".join("%s %d/%d" % (s_, x["hit"], x["n"])
                                                    for s_, x in sorted(c["by_scenario"].items())))
    res["model_calls"] = calls
    res["chosen"] = chosen
    res["held"] = report
    json.dump(res, open(a.out, "w"), indent=1)
    print("CHOSEN_JSON " + json.dumps(chosen, sort_keys=True))
    measured = {}
    for k, v in report.items():
        name, st = k.split("/")
        c = v["chosen"]
        measured.setdefault(name, {})[st] = {"p": c["precision"], "r": c["recall"],
                                             "n": c["tp"] + c["fp"] + c["fn"] + c["tn"]}
    print("MEASURED_JSON " + json.dumps(measured, sort_keys=True))


if __name__ == "__main__":
    main()
