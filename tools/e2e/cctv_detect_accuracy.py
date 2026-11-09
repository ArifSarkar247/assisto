"""cctvdet: honest precision / recall of the stage-1 ZONE DETECTIONS
(CCTV Guard V3 part C) through the REAL Shop Box code — CameraAnalyzer +
shopbox/detect_rules.py + the YOLOX-Nano person model — on labelled
scenarios built from a licensed public set. CI only
(.github/workflows/cctv-detect-accuracy.yml); nothing downloaded is committed.

    python tools/e2e/cctv_detect_accuracy.py --ann instances_val2017.json \\
        --model edge/shopbox/models/yolox_nano.onnx --out cctv_detect.json [--n 40]

DATA. COCO val2017 (annotations CC BY 4.0; only images whose own licence is
CC BY 2.0, CC BY-SA 2.0, "no known copyright restrictions" or US Government
work — tools/e2e/cctv_accuracy.OK_LICENCES). Backgrounds = images with no
person at all; people = the largest person of a person image, cut out by its
labelled polygon. Every scenario is a timed frame sequence (640 x 360, JPEG
q60, sensor noise, flicker; night = grey IR + gamma + stronger noise) whose
TRUTH is known by construction:

  gate_person  pos: a person walks in and stands in the gate zone
               neg: a person stands just OUTSIDE it; nobody + nuisance
  loitering    pos: one visit of 150 s in a dwell zone (dwell_s = 120)
               neg: two short visits (40 s, 30 s apart); someone beside it
  post_empty   pos: the person at the counter leaves for 7 min (absent_min 5)
               neg: the person stays 10 min (moving a little)
  gate_open    a SYNTHETIC rolling shutter (slats) over a real background:
               pos: opened (fully / half) and left open 13 min (open_min 10),
                    day and night (the closed picture taken by day)
               neg: closed 15 min with light drift, a moving shadow, the
                    night IR switch, a person in front for 2 min, rain
  tamper       covered pos: hand (skin, blurred) / cloth over the lens 3 min
               moved   pos: the camera panned 30 % / turned 20 deg / to a wall
               neg (both): light drift, IR switch, a person close for 15 s

A positive counts (TP) when its detection fires after the event; a negative
counts (FP) when it fires at all. P = TP / (TP + FP), R = TP / (TP + FN).
FALSE ALERTS: each negative scenario's simulated duration is summed; the FP
count per camera-week (84 h) and its Poisson 95 % upper bound are reported.
Honest limits: synthetic composition (pasted people, a drawn shutter), not
real CCTV footage; the owner's own clips (cctv-accuracy.yml) are the real
test. Results feed cctv_thresholds.json["measured"] (the alert's confidence).
"""
import argparse
import json
import math
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

W, H = 640, 360
SEED = 20261110
GATE = [[0.3, 0.45], [0.7, 0.45], [0.7, 1.0], [0.3, 1.0]]
SHUTTER = [[0.25, 0.22], [0.75, 0.22], [0.75, 0.95], [0.25, 0.95]]
ALL_DAY = {"days": [0, 1, 2, 3, 4, 5, 6], "start": "00:00", "end": "00:00"}
T0 = None


def t0():
    global T0
    if T0 is None:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        T0 = datetime(2026, 11, 2, 12, 0, tzinfo=ZoneInfo("Asia/Dhaka")).timestamp()
    return T0


# ------------------------------------------------------------------ frames
def fit(img):
    import cv2
    h, w = img.shape[:2]
    s = max(W / w, H / h)
    r = cv2.resize(img, (int(math.ceil(w * s)), int(math.ceil(h * s))), interpolation=cv2.INTER_AREA)
    y = (r.shape[0] - H) // 2
    x = (r.shape[1] - W) // 2
    return r[y:y + H, x:x + W].astype(np.float32)


def scaled_cut(cut, height_frac, rnd):
    import cv2
    patch, mask = cut
    ph = int(H * height_frac)
    pw = max(4, int(patch.shape[1] * ph / patch.shape[0]))
    p = cv2.resize(patch, (pw, ph), interpolation=cv2.INTER_AREA).astype(np.float32)
    m = cv2.resize(mask, (pw, ph), interpolation=cv2.INTER_NEAREST) > 0
    return p, m


def paste(f, pm, cx, foot):
    p, m = pm
    ph, pw = m.shape
    x0, y0 = int(cx * W - pw / 2), int(foot * H - ph)
    xa, xb, ya, yb = max(0, x0), min(W, x0 + pw), max(0, y0), min(H, y0 + ph)
    if xb <= xa or yb <= ya:
        return
    roi = f[ya:yb, xa:xb]
    mm = m[ya - y0:yb - y0, xa - x0:xb - x0]
    roi[mm] = p[ya - y0:yb - y0, xa - x0:xb - x0][mm]


def finish(f, night, rng, noise=4.0, gain=1.0):
    import cv2
    f = f * gain
    if night:
        g = cv2.cvtColor(np.clip(f, 0, 255).astype(np.uint8), cv2.COLOR_BGR2GRAY).astype(np.float32)
        g = 255.0 * np.power(g / 255.0, 1.5) * 0.7
        f = np.repeat(g[..., None], 3, axis=2)
        noise = max(noise, 8.0)
    f = f + rng.normal(0, noise, f.shape[:2])[..., None]
    return CA.jpeg(np.clip(f, 0, 255).astype(np.uint8), 60)


# ------------------------------------------------------------------ pipeline
def analyzer(zones, det, schedule=None):
    from shopbox.analyzer import CameraAnalyzer
    from shopbox.config import CameraConfig, DetectionConfig
    from shopbox.hours import Hours
    from shopbox.zone import normalize_zones_v2
    cam = CameraConfig(id="c1", name="Eval", rtsp_url="rtsp://x", zone=[])
    cam.zones_v2 = normalize_zones_v2({"v": 2, "zones": zones, "schedule": schedule,
                                       "sensitivity": "medium"})
    # open all day: the after-hours rule stays out of the way (it is measured
    # by cctv_accuracy.py)
    return CameraAnalyzer(cam, Hours(open="00:00", close="00:00"), DetectionConfig(), det)


def run(an, frames, want):
    """frames: [(t_offset, frame)] -> list of (t_offset, type) of `want`."""
    out = []
    for dt, f in frames:
        an.process(f, now=t0() + dt)
        for x in an.take_extra():
            if x.type in want:
                out.append((dt, x.type, dict(x.signals)))
    return out


def tally(rows):
    tp = sum(1 for r in rows if r["pos"] and r["hit"])
    fn = sum(1 for r in rows if r["pos"] and not r["hit"])
    fp = sum(1 for r in rows if not r["pos"] and r["hit"])
    tn = sum(1 for r in rows if not r["pos"] and not r["hit"])
    res = CA.prf(tp, fp, fn, tn)
    neg_h = sum(r["dur"] for r in rows if not r["pos"]) / 3600.0
    res["neg_hours"] = round(neg_h, 2)
    weeks = neg_h / 84.0 if neg_h else 0.0
    res["false_per_camera_week"] = round(fp / weeks, 3) if weeks else None
    res["false_upper95_per_camera_week"] = round(CA.poisson_upper95(fp) / weeks, 3) if weeks else None
    by = {}
    for r in rows:
        k = r["kind"]
        b = by.setdefault(k, {"n": 0, "hit": 0})
        b["n"] += 1
        b["hit"] += int(r["hit"])
    res["by_scenario"] = by
    return res


# ------------------------------------------------------------------ scenarios
def _nuis(rnd):
    return {"flicker": rnd.uniform(0.02, 0.07), "noise": rnd.uniform(3, 6)}


def gate_person(bgs, cuts, det, n, rnd):
    rows = []
    for i in range(n):
        for night in (False, True):
            for kind in ("pos", "outside", "nobody"):
                bg = fit(bgs[rnd.randrange(len(bgs))])
                pm = scaled_cut(cuts[rnd.randrange(len(cuts))], rnd.uniform(0.45, 0.6), rnd)
                rng = np.random.default_rng(rnd.randrange(1 << 30))
                nu = _nuis(rnd)
                an = analyzer([{"id": "g1", "type": "gate", "points": GATE}], det)
                cx = rnd.uniform(0.42, 0.58) if kind == "pos" else rnd.choice(
                    [rnd.uniform(0.04, 0.16), rnd.uniform(0.84, 0.96)])
                foot = rnd.uniform(0.85, 0.98)
                frames = []
                for k in range(8):                     # empty scene, motion warms up
                    frames.append((k * 1.0, finish(bg.copy(), night, rng, nu["noise"],
                                                   1 + rnd.uniform(-nu["flicker"], nu["flicker"]))))
                for k in range(8):                     # someone arrives and stays
                    f = bg.copy()
                    if kind != "nobody":
                        paste(f, pm, cx + rnd.uniform(-0.01, 0.01), foot)
                    frames.append((8.0 + k * 2.0, finish(f, night, rng, nu["noise"],
                                                         1 + rnd.uniform(-nu["flicker"], nu["flicker"]))))
                hits = run(an, frames, {"gate_person"})
                rows.append({"pos": kind == "pos", "hit": bool(hits), "kind": "%s_%s" % (
                    kind, "night" if night else "day"), "dur": frames[-1][0]})
    return tally(rows)


def loitering(bgs, cuts, det, n, rnd):
    rows = []
    zone = {"id": "z1", "type": "restricted", "points": GATE, "opts": {"dwell_s": 120}}
    for i in range(n):
        for night in (False, True):
            for kind in ("pos", "two_visits", "beside"):
                bg = fit(bgs[rnd.randrange(len(bgs))])
                pm = scaled_cut(cuts[rnd.randrange(len(cuts))], rnd.uniform(0.45, 0.6), rnd)
                rng = np.random.default_rng(rnd.randrange(1 << 30))
                nu = _nuis(rnd)
                an = analyzer([zone], det)
                frames = []
                for k in range(6):
                    frames.append((k * 1.0, finish(bg.copy(), night, rng, nu["noise"])))
                cx = rnd.uniform(0.42, 0.58)
                if kind == "beside":
                    cx = rnd.choice([rnd.uniform(0.04, 0.16), rnd.uniform(0.84, 0.96)])
                t = 6.0
                end = 6.0 + 160.0
                while t <= end:
                    rel = t - 6.0
                    present = True
                    if kind == "two_visits":
                        present = rel < 40 or 70 <= rel < 110
                    f = bg.copy()
                    if present:
                        paste(f, pm, cx + rnd.uniform(-0.02, 0.02), rnd.uniform(0.88, 0.97))
                    frames.append((t, finish(f, night, rng, nu["noise"],
                                             1 + rnd.uniform(-nu["flicker"], nu["flicker"]))))
                    t += 2.0
                hits = run(an, frames, {"loitering"})
                rows.append({"pos": kind == "pos", "hit": bool(hits),
                             "kind": "%s_%s" % (kind, "night" if night else "day"), "dur": end})
    return tally(rows)


def post_empty(bgs, cuts, det, n, rnd):
    rows = []
    zone = {"id": "p1", "type": "post", "points": GATE, "schedule": ALL_DAY,
            "opts": {"absent_min": 5}}
    for i in range(n):
        for night in (False, True):
            for kind in ("pos", "stays"):
                bg = fit(bgs[rnd.randrange(len(bgs))])
                pm = scaled_cut(cuts[rnd.randrange(len(cuts))], rnd.uniform(0.45, 0.6), rnd)
                rng = np.random.default_rng(rnd.randrange(1 << 30))
                nu = _nuis(rnd)
                an = analyzer([zone], det)
                frames = []
                cx = rnd.uniform(0.42, 0.58)
                for k in range(21):                    # every 30 s for 10 min
                    t = k * 30.0
                    present = kind == "stays" or t < 120
                    f = bg.copy()
                    if present:
                        paste(f, pm, cx + rnd.uniform(-0.04, 0.04), rnd.uniform(0.86, 0.98))
                    frames.append((t, finish(f, night, rng, nu["noise"],
                                             1 + rnd.uniform(-nu["flicker"], nu["flicker"]))))
                hits = run(an, frames, {"post_empty"})
                ok = bool(hits) and (kind != "pos" or hits[0][0] >= 120 + 300)
                rows.append({"pos": kind == "pos", "hit": ok if kind == "pos" else bool(hits),
                             "kind": "%s_%s" % (kind, "night" if night else "day"), "dur": 600.0})
    return tally(rows)


def shutter(bg, inside, openness, rnd_seed):
    """The shutter zone of `bg` drawn closed (slats) or opened by `openness`
    (0 = closed, 1 = fully up) showing `inside`."""
    r = random.Random(rnd_seed)
    f = bg.copy()
    x1, y1 = int(SHUTTER[0][0] * W), int(SHUTTER[0][1] * H)
    x2, y2 = int(SHUTTER[2][0] * W), int(SHUTTER[2][1] * H)
    hh = y2 - y1
    f[y1:y2, x1:x2] = inside[y1:y2, x1:x2] * 0.55       # a dim shop inside
    base = r.uniform(110, 170)
    period = r.choice([8, 10, 12, 14])
    down = int(hh * (1.0 - openness))
    for y in range(y1, y1 + down):
        k = (y - y1) % period
        v = base + (25 if k < 2 else (-30 if k == period - 1 else 0))
        f[y, x1:x2] = v + np.linspace(-15, 15, x2 - x1)[:, None]
    return f


def gate_open(bgs, det, n, rnd):
    rows = []
    for i in range(n):
        for kind in ("pos_full", "pos_half", "pos_night", "neg_light", "neg_shadow",
                     "neg_night", "neg_person", "neg_rain"):
            bg = fit(bgs[rnd.randrange(len(bgs))])
            inside = fit(bgs[rnd.randrange(len(bgs))])
            seed = rnd.randrange(1 << 30)
            rng = np.random.default_rng(seed)
            zone = {"id": "g1", "type": "gate", "points": SHUTTER,
                    "opts": {"watch_open": True, "open_min": 10, "closed_at": t0() - 5}}
            an = analyzer([zone], det)
            frames = []
            opened_at = 60.0 if kind != "pos_night" else 300.0
            cutp = None
            for k in range(91):                         # every 10 s for 15 min
                t = k * 10.0
                pos = kind.startswith("pos")
                openness = (1.0 if kind != "pos_half" else 0.5) if (pos and t >= opened_at) else 0.0
                f = shutter(bg, inside, openness, seed)
                night = (kind in ("pos_night", "neg_night")) and t >= 150
                gain = 1.0
                if kind == "neg_light":
                    gain = 0.6 + 0.8 * (k / 90.0)
                if kind == "neg_shadow":
                    xs = int((k / 90.0) * W)
                    f[:, max(0, xs - 120):xs] *= 0.55
                if kind == "neg_person" and 300 <= t < 420:
                    if cutp is None and CUTS:
                        cutp = scaled_cut(CUTS[rnd.randrange(len(CUTS))], 0.6, rnd)
                    if cutp is not None:
                        paste(f, cutp, 0.5, 0.97)
                if kind == "neg_rain":
                    for _ in range(80):
                        x, y = rng.integers(0, W), rng.integers(0, H - 20)
                        f[y:y + 18, x:x + 1] += 60
                frames.append((t, finish(f, night, rng, 5.0, gain)))
            hits = run(an, frames, {"gate_open"})
            pos = kind.startswith("pos")
            hit = bool(hits) and (not pos or hits[0][0] >= opened_at + 600 - 10)
            rows.append({"pos": pos, "hit": hit if pos else bool(hits), "kind": kind, "dur": 900.0})
    return tally(rows)


def tamper(bgs, det, n, rnd):
    import cv2
    rows_c, rows_m = [], []
    for i in range(n):
        for kind in ("covered_hand", "covered_cloth", "moved_pan", "moved_turn", "moved_wall",
                     "neg_light", "neg_ir", "neg_person"):
            bg = fit(bgs[rnd.randrange(len(bgs))])
            other = fit(bgs[rnd.randrange(len(bgs))])
            rng = np.random.default_rng(rnd.randrange(1 << 30))
            an = analyzer([], det)
            frames = []
            for k in range(25):                           # every 15 s for 6 min
                t = k * 15.0
                f = bg.copy()
                night = False
                gain = 1.0
                after = t >= 60
                if kind == "covered_hand" and after:
                    f = np.full_like(bg, 0) + np.array([95, 125, 175], np.float32)
                    f = cv2.GaussianBlur(f, (0, 0), 25)
                elif kind == "covered_cloth" and after:
                    f = np.full_like(bg, rnd.uniform(60, 140))
                elif kind == "moved_pan" and after:
                    f = np.roll(bg, int(W * 0.3), axis=1)
                elif kind == "moved_turn" and after:
                    m = cv2.getRotationMatrix2D((W / 2, H / 2), 20, 1.15)
                    f = cv2.warpAffine(bg, m, (W, H), borderMode=cv2.BORDER_REFLECT)
                elif kind == "moved_wall" and after:
                    f = other.copy()
                elif kind == "neg_light":
                    gain = 1.0 - 0.4 * min(1.0, t / 300.0)
                elif kind == "neg_ir":
                    night = t >= 120
                elif kind == "neg_person" and 150 <= t < 165 and CUTS:
                    paste(f, scaled_cut(CUTS[rnd.randrange(len(CUTS))], 0.95, rnd), 0.5, 1.0)
                noise = 2.0 if kind.startswith("covered") and after else 4.0
                frames.append((t, finish(f, night, rng, noise, gain)))
            hits = run(an, frames, {"camera_health"})
            kinds = {h[2].get("kind") for h in hits}
            if kind.startswith("covered"):
                rows_c.append({"pos": True, "hit": "covered" in kinds, "kind": kind, "dur": 360.0})
            elif kind.startswith("moved"):
                rows_m.append({"pos": True, "hit": "moved" in kinds, "kind": kind, "dur": 360.0})
            else:
                rows_c.append({"pos": False, "hit": "covered" in kinds, "kind": kind, "dur": 360.0})
                rows_m.append({"pos": False, "hit": "moved" in kinds, "kind": kind, "dur": 360.0})
    return tally(rows_c), tally(rows_m)


CUTS = []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ann", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", default="cctv_detect.json")
    ap.add_argument("--cache", default="/tmp/coco_eval")
    ap.add_argument("--n", type=int, default=40)
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    from shopbox.person import load_detector
    det = load_detector(a.model, score_thr=0.45)
    assert getattr(det, "name", "") == "yolox_nano", "person model did not load"
    ann = json.load(open(a.ann))
    pos, neg = CA.build_set(ann, 160, 160)
    bgs, ids = [], []
    for im, anns in neg:
        img = CA.fetch(im, a.cache)
        if img is not None:
            bgs.append(img)
            ids.append({"id": im["id"], "role": "background", "licence": CA.OK_LICENCES[im["license"]]})
    for im, anns in pos:
        img = CA.fetch(im, a.cache)
        if img is None:
            continue
        c = CA.person_cutout(img, anns)
        if c is not None and c[0].shape[0] >= 120 and c[0].shape[0] > c[0].shape[1]:
            CUTS.append(c)              # tall, big enough: a standing person
            ids.append({"id": im["id"], "role": "person", "licence": CA.OK_LICENCES[im["license"]]})
    print("backgrounds %d, people %d" % (len(bgs), len(CUTS)), flush=True)
    rnd = random.Random(SEED)
    res = {"set": {"source": "COCO val2017 (CC BY 4.0 annotations; licensed images only)",
                   "backgrounds": len(bgs), "people": len(CUTS), "seed": SEED,
                   "scenarios_per_kind": a.n, "images": ids}}
    for name, fn in (("gate_person", lambda: gate_person(bgs, CUTS, det, a.n, rnd)),
                     ("loitering", lambda: loitering(bgs, CUTS, det, a.n, rnd)),
                     ("post_empty", lambda: post_empty(bgs, CUTS, det, a.n, rnd)),
                     ("gate_open", lambda: gate_open(bgs, det, a.n, rnd))):
        t = time.time()
        res[name] = fn()
        print("%s %.0fs" % (name, time.time() - t), flush=True)
    t = time.time()
    res["tamper_covered"], res["tamper_moved"] = tamper(bgs, det, a.n, rnd)
    print("tamper %.0fs" % (time.time() - t), flush=True)
    json.dump(res, open(a.out, "w"), indent=1)
    print("DETECTION            P      R      F1   n(pos/neg)  false/cam-week (95%% <=)")
    for k in ("gate_person", "loitering", "post_empty", "gate_open", "tamper_covered", "tamper_moved"):
        r = res[k]
        print("%-18s %.3f  %.3f  %.3f  %3d/%-3d     %s (%s)" % (
            k, r["precision"], r["recall"], r["f1"], r["tp"] + r["fn"], r["fp"] + r["tn"],
            r["false_per_camera_week"], r["false_upper95_per_camera_week"]))
        print("    by scenario: " + ", ".join("%s %d/%d" % (s, b["hit"], b["n"])
                                             for s, b in sorted(r["by_scenario"].items())))
    # the table the shared thresholds file keeps (the alert's confidence)
    measured = {}
    for k, src in (("gate_person", "gate_person"), ("loitering", "loitering"),
                   ("post_empty", "post_empty"), ("gate_open", "gate_open")):
        r = res[src]
        measured[k] = {"p": r["precision"], "r": r["recall"], "n": r["tp"] + r["fp"] + r["fn"] + r["tn"]}
    tc, tm = res["tamper_covered"], res["tamper_moved"]
    tp, fp, fn = tc["tp"] + tm["tp"], tc["fp"] + tm["fp"], tc["fn"] + tm["fn"]
    measured["camera_health"] = {"p": round(tp / (tp + fp), 4) if tp + fp else 0.0,
                                 "r": round(tp / (tp + fn), 4) if tp + fn else 0.0,
                                 "n": tc["tp"] + tc["fp"] + tc["fn"] + tc["tn"] + tm["tp"] + tm["fp"] + tm["fn"] + tm["tn"]}
    print("MEASURED_JSON " + json.dumps(measured, sort_keys=True))


if __name__ == "__main__":
    main()
