"""cctvtoday + cctvacc: honest precision / recall of the CCTV checks on
LABELED test sets (run in CI only: .github/workflows/cctv-accuracy.yml).

    python tools/e2e/cctv_accuracy.py --ann instances_val2017.json \
        --model models/yolox_nano.onnx --out results.json \
        [--owner-clips DIR]   # optional, private, never committed

Data (built fresh each run, fixed seed, nothing committed):
  * COCO val2017 (annotations CC BY 4.0, cocodataset.org). Only images whose
    own licence is CC BY 2.0 (id 4), CC BY-SA 2.0 (id 5), "No known copyright
    restrictions" (7) or "United States Government Work" (8) are used.
  * POSITIVE = at least one non-crowd person box >= MIN_PERSON_FRAC of the
    image; NEGATIVE = no person annotation at all (tiny / crowd-only images
    are left out as ambiguous).

PERSON check = the Shop Box code (YOLOX-Nano) with the PRODUCTION threshold
rule (shopbox/night.py: 0.45 by day, 0.30 on grey / IR / dark frames; the
phone's native channel applies the same rule). Each image is scored as-is,
"cctv" (640 px, blur, JPEG q40), "night_ir" (grey, dark, noise) and
"night_ir2" (a DIFFERENT night simulation: vignette, softer, stronger noise,
IR bloom) that was never used to pick anything.
Overfitting guard: the night RULE is chosen on a CALIBRATION half of
night_ir; P/R are reported on the HELD-OUT half and on night_ir2.
cctvacc2: the night rule is a grid — pre-processing (none / gamma / CLAHE,
shopbox/night.py enhance, the same maths as the phone), frames to confirm
(1 or 2: each night image is scored as two frames with independent noise)
and threshold; pick = highest calibration recall at precision >= 0.92.
"before" = the cctvacc rule (raw frame, one check, 0.30), re-measured on
exactly the same frames.

MOTION check = 24-frame synthetic sequences (3 fps) on real no-person
backgrounds; positives have a real person cut-out (COCO polygon mask)
walking in at frame 14, each negative is the SAME sequence without the
person (same nuisance). Sets: "basic" (flicker, noise, shake — the cctvtoday
set), "hard" (strong flicker, auto exposure ramps, rain streaks, swaying
trees, a lamp switching on, shake) and "night" (the hard set as grey IR with
an IR / light switch). Measured three ways:
  legacy = the old frame-difference detector, any frame (the "before");
  box    = the Shop Box after-hours decision (CameraAnalyzer, 3 frames);
  phone  = cctvacc2: the phone's MotionGate AND its pixel-level check
           (motion_gate.PhoneMotion), 3 frames;
  phone_gate_only = the cctvacc phone (gate only) — the "before".
A positive counts only when the alert fires at a frame where its no-person
twin does not (so nuisance alerts never count as recall).

FALSE NIGHT ALERTS = long simulated nights (grey IR noise, flicker, AE
drift, swaying trees, rain spells, light / IR switches) through the box and
phone motion decisions with the box's 180 s cool-down; reported per camera
per week (84 night hours) with a Poisson 95% upper bound; each motion alert
frame is then also run through the person model at the night threshold
(the phone sends nothing without a person).
"""
import argparse
import csv
import json
import math
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
THRS = [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
VARIANTS = ("clean", "cctv", "night_ir", "night_ir2")
SEQ_T, SEQ_ENTER = 24, 14
FPS = 3.0
NIGHT_HOURS_PER_WEEK = 84.0


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
    rng = np.random.default_rng(rnd.randrange(1 << 30))
    g = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32)
    if name == "night_ir":            # grey, darker, noisy (cctvtoday)
        g = 255.0 * np.power(g / 255.0, 1.6) * 0.75
        g += rng.normal(0, 10, g.shape)
    else:                             # night_ir2: a different simulation
        hh, ww = g.shape
        yy, xx = np.mgrid[0:hh, 0:ww]
        r2 = ((xx - ww / 2) / (ww / 2)) ** 2 + ((yy - hh / 2) / (hh / 2)) ** 2
        g = 255.0 * np.power(g / 255.0, 1.25) * (0.95 - 0.45 * np.clip(r2, 0, 1.5))
        bloom = cv2.GaussianBlur(np.clip(g - 170, 0, None), (0, 0), 6)
        g = cv2.GaussianBlur(g, (5, 5), 0) + 0.8 * bloom
        g += rng.normal(0, 14, g.shape)
    g = np.clip(g, 0, 255).astype(np.uint8)
    return jpeg(cv2.cvtColor(g, cv2.COLOR_GRAY2BGR), 40)


def prf(tp, fp, fn, tn):
    p = tp / (tp + fp) if tp + fp else 0.0
    r = tp / (tp + fn) if tp + fn else 0.0
    f = 2 * p * r / (p + r) if p + r else 0.0
    acc = (tp + tn) / max(1, tp + fp + fn + tn)
    return {"precision": round(p, 4), "recall": round(r, 4), "f1": round(f, 4),
            "accuracy": round(acc, 4), "tp": tp, "fp": fp, "fn": fn, "tn": tn}


# ------------------------------------------------------------------ person
# cctvacc2: the NIGHT RULE is a grid of (pre-processing, frames to confirm,
# threshold). Each night image is scored as TWO frames: the same scene with
# independent sensor noise / JPEG (what a still person gives 0.3 s apart);
# the second frame uses its own RNG so frame 1 is exactly the cctvacc frame.
PRES = ("none", "gamma", "clahe")
CONFIRMS = (1, 2)
THRS_N = [0.15] + THRS


def night_rule_hit(row, pre, confirm, t, day_t):
    if not row["night"]:
        return row["raw"] >= day_t
    sc = row["s"][pre]
    return (sc[0] if confirm == 1 else min(sc[:confirm])) >= t


def rule_counts(rows, pre, confirm, t, day_t=None):
    from shopbox import night
    day_t = night.PERSON_SCORE_DAY if day_t is None else day_t
    tp = fp = fn = tn = 0
    for r in rows:
        hit = night_rule_hit(r, pre, confirm, t, day_t)
        if r["label"]:
            tp, fn = tp + hit, fn + (not hit)
        else:
            fp, tn = fp + hit, tn + (not hit)
    return prf(tp, fp, fn, tn)


def pick_night_rule(rows, p_min=0.92):
    """Calibration rule: the highest recall with precision >= p_min (margin
    over the 90 % target); ties -> fewer steps (no pre-processing, one
    frame), then the higher threshold. None reach p_min -> max F1."""
    cands = []
    for pre in PRES:
        for c in CONFIRMS:
            for t in THRS_N:
                m = rule_counts(rows, pre, c, t)
                cost = (pre != "none") + (c - 1)
                cands.append((m, pre, c, t, cost))
    ok = [x for x in cands if x[0]["precision"] >= p_min]
    if ok:
        best = max(ok, key=lambda x: (x[0]["recall"], x[0]["f1"], -x[4], x[3]))
    else:
        best = max(cands, key=lambda x: (x[0]["f1"], -x[4], x[3]))
    return {"pre": best[1], "confirm": best[2], "threshold": best[3]}


def eval_person(det, items, rnd):
    from shopbox import night
    rnd2 = random.Random(SEED + 31)
    rows = {v: [] for v in VARIANTS}
    for idx, (img, label) in enumerate(items):
        for v in VARIANTS:
            x = variant(img, v, rnd)
            x2 = variant(img, v, rnd2)
            raw = max([d.score for d in det.detect(x, score_thr=0.10)] or [0.0])
            row = {"i": idx, "label": label, "raw": raw, "night": night.is_night(x)}
            if row["night"]:
                raw2 = max([d.score for d in det.detect(x2, score_thr=0.10)] or [0.0])
                row["s"] = {"none": [raw, raw2]}
                for pre in PRES[1:]:
                    row["s"][pre] = [
                        max([d.score for d in det.detect(
                            night.enhance(night.fit_side(f), pre), score_thr=0.10)] or [0.0])
                        for f in (x, x2)]
            rows[v].append(row)
    prod = (night.NIGHT_PRE, night.NIGHT_CONFIRM, night.PERSON_SCORE_NIGHT)
    before = ("none", 1, 0.30)                     # the cctvacc rule
    out = {"production_rule": {"pre": prod[0], "confirm": prod[1], "threshold": prod[2]},
           "production": {}, "before": {}, "night_flag_rate": {}}
    for v, rs in rows.items():
        out["production"][v] = rule_counts(rs, *prod)
        out["before"][v] = rule_counts(rs, *before)
        out["night_flag_rate"][v] = round(sum(r["night"] for r in rs) / max(1, len(rs)), 4)
    # overfitting guard: split night_ir by image (stratified), pick on calib
    split = random.Random(SEED + 7)
    pos_i = [r["i"] for r in rows["night_ir"] if r["label"]]
    neg_i = [r["i"] for r in rows["night_ir"] if not r["label"]]
    split.shuffle(pos_i)
    split.shuffle(neg_i)
    calib = set(pos_i[: len(pos_i) // 2] + neg_i[: len(neg_i) // 2])
    cal = [r for r in rows["night_ir"] if r["i"] in calib]
    held = [r for r in rows["night_ir"] if r["i"] not in calib]
    pick = pick_night_rule(cal)
    grid = {}
    for pre in PRES:
        for c in CONFIRMS:
            for t in THRS_N:
                k = "%s/%d/%.2f" % (pre, c, t)
                grid[k] = {"calibration": rule_counts(cal, pre, c, t),
                           "held_out": rule_counts(held, pre, c, t),
                           "night_ir2": rule_counts(rows["night_ir2"], pre, c, t)}
    pk = (pick["pre"], pick["confirm"], pick["threshold"])
    out["night_split"] = {
        "calibration_n": len(cal), "held_out_n": len(held),
        "calibration_pick": pick,
        "production_matches_calibration_pick": (pk[0] == prod[0] and pk[1] == prod[1]
                                                and abs(pk[2] - prod[2]) < 1e-9),
        "held_out_at_production": rule_counts(held, *prod),
        "held_out_before": rule_counts(held, *before),
        "held_out_at_pick": rule_counts(held, *pk),
        "night_ir2_at_production": rule_counts(rows["night_ir2"], *prod),
        "night_ir2_before": rule_counts(rows["night_ir2"], *before),
        "night_ir2_at_pick": rule_counts(rows["night_ir2"], *pk),
        "grid": grid,
    }
    return out


# ------------------------------------------------------------------ motion
def person_cutout(img, anns):
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


def nuisance_plan(kind, rnd):
    hard = kind in ("hard", "night")
    p = {"flicker": 0.06 if not hard else 0.09, "noise": 4.0 if kind == "basic" else
         (5.0 if kind == "hard" else 8.0), "shake": True,
         "ae": None, "rain": 0, "tree": None, "lamp": None, "switch": None}
    if hard:
        if rnd.random() < 0.5:
            p["ae"] = (rnd.randint(2, SEQ_T - 6), rnd.uniform(0.7, 1.4))
        if rnd.random() < 0.5:
            p["rain"] = rnd.randint(150, 400)
        if rnd.random() < 0.6:
            p["tree"] = (rnd.uniform(0, 0.6), rnd.uniform(0, 0.3), rnd.uniform(0.25, 0.4),
                         rnd.uniform(0.3, 0.6), rnd.uniform(3, 7), rnd.uniform(3, 6))
        if rnd.random() < 0.4:
            p["lamp"] = (rnd.randint(3, SEQ_T - 2), rnd.uniform(0.1, 0.9), rnd.uniform(0.1, 0.9),
                         rnd.uniform(0.12, 0.3), rnd.uniform(30, 70))
    if kind == "night" and rnd.random() < 0.3:
        p["switch"] = (rnd.randint(3, SEQ_T - 2), rnd.choice([0.45, 0.55, 1.9, 2.2]))
    return p


def _tree(f, k, spec, w, h):
    import cv2
    x0, y0, ww, hh, amp, per = spec
    x0, y0 = int(x0 * w), int(y0 * h)
    ww, hh = max(8, int(ww * w)), max(8, int(hh * h))
    x1, y1 = min(w, x0 + ww), min(h, y0 + hh)
    reg = f[y0:y1, x0:x1]
    yy, xx = np.mgrid[0:reg.shape[0], 0:reg.shape[1]].astype(np.float32)
    shift = amp * np.sin(2 * math.pi * (yy / 23.0 + k / per)) * (0.6 + 0.4 * np.sin(k * 1.7))
    f[y0:y1, x0:x1] = cv2.remap(reg, xx + shift, yy, cv2.INTER_LINEAR,
                                borderMode=cv2.BORDER_REFLECT)


def _rain(f, n, rng):
    import cv2
    h, w = f.shape[:2]
    layer = np.zeros(f.shape[:2], np.float32)
    xs = rng.integers(0, w, n)
    ys = rng.integers(0, h, n)
    ls = rng.integers(8, 26, n)
    for x, y, ln in zip(xs, ys, ls):
        cv2.line(layer, (int(x), int(y)), (int(x + ln * 0.25), int(y + ln)), 1.0, 1)
    amp = rng.uniform(40, 90)
    f += (layer * amp)[..., None] if f.ndim == 3 else layer * amp


def _lamp(f, spec, w, h):
    _, cx, cy, r, amp = spec
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d2 = ((xx - cx * w) ** 2 + (yy - cy * h) ** 2) / (r * w) ** 2
    glow = amp * np.exp(-d2)
    f += glow[..., None] if f.ndim == 3 else glow


def make_sequence(bg, cut, kind, plan, positive, seq_seed, walk):
    """24 BGR frames (640 x 360)."""
    import cv2
    rnd = random.Random(seq_seed)          # the SAME nuisance for both twins
    rng = np.random.default_rng(seq_seed)
    h, w = bg.shape[:2]
    base = bg.astype(np.float32)
    if kind == "night":
        g = cv2.cvtColor(bg, cv2.COLOR_BGR2GRAY).astype(np.float32)
        g = 255.0 * np.power(g / 255.0, 1.5) * 0.7
        base = np.repeat(g[..., None], 3, axis=2)
    patch, mask, ph, pw, y0, speed, from_left = walk
    if kind == "night" and patch is not None:
        pg = cv2.cvtColor(patch.astype(np.uint8), cv2.COLOR_BGR2GRAY).astype(np.float32)
        patch = np.repeat((255.0 * np.power(pg / 255.0, 1.3) * 0.85)[..., None], 3, axis=2)
    frames = []
    gain = 1.0
    for k in range(SEQ_T):
        f = base.copy()
        if plan["tree"]:
            _tree(f, k, plan["tree"], w, h)
        if positive and k >= SEQ_ENTER:
            step = (k - SEQ_ENTER) * speed
            x0 = int(-pw * 0.5 + step) if from_left else int(w - pw * 0.5 - step)
            xa, xb = max(0, x0), min(w, x0 + pw)
            if xb > xa:
                roi = f[y0:y0 + ph, xa:xb]
                m = mask[:, xa - x0:xb - x0]
                roi[m] = patch[:, xa - x0:xb - x0][m]
        if plan["lamp"] and k >= plan["lamp"][0]:
            _lamp(f, plan["lamp"], w, h)
        if plan["ae"]:
            s, target = plan["ae"]
            if k >= s:
                gain = 1.0 + (target - 1.0) * min(1.0, (k - s + 1) / 4.0)
        if plan["switch"] and k >= plan["switch"][0]:
            f *= plan["switch"][1]
        f *= gain * (1.0 + rnd.uniform(-plan["flicker"], plan["flicker"]))
        if plan["rain"]:
            _rain(f, plan["rain"], rng)
        if plan["shake"]:
            dx, dy = rnd.randint(-2, 2), rnd.randint(-1, 1)
            f = np.roll(np.roll(f, dx, axis=1), dy, axis=0)
        f += rng.normal(0, plan["noise"], f.shape[:2])[..., None]
        frames.append(jpeg(np.clip(f, 0, 255).astype(np.uint8), 60))
    return frames


CLOSED_TS = None


def _closed_ts():
    from datetime import datetime
    from zoneinfo import ZoneInfo
    return datetime(2026, 10, 19, 23, 30, tzinfo=ZoneInfo("Asia/Dhaka")).timestamp()


PIX_SWEEP = [(18.0, 6), (25.0, 12), (32.0, 6)]    # diagnostic only (production = JSON)


def run_methods(frames):
    """-> {method: [bool per frame]} for legacy / box / phone / phone_gate_only
    (the cctvacc phone) / phone_pix_<diff>_<area> (diagnostic sweep)."""
    import cv2
    from shopbox import motion_gate as mg
    from shopbox.analyzer import CameraAnalyzer
    from shopbox.config import CameraConfig, DetectionConfig
    from shopbox.hours import Hours
    from shopbox.motion import MotionDetector
    from shopbox.person import NullDetector
    legacy = MotionDetector(gate=False)
    an = CameraAnalyzer(CameraConfig(id="c", name="c", rtsp_url="rtsp://x", zone=[]),
                        Hours(open="09:00", close="22:00"), DetectionConfig(), NullDetector())
    gate = mg.MotionGate()
    phone = mg.PhoneMotion()                    # cctvacc2: gate AND pixel check
    sweep = {"phone_pix_%d_%d" % (d, a): [mg.PixelCheck(d, a), 0] for d, a in PIX_SWEEP}
    t0 = _closed_ts()
    out = {"legacy": [], "box": [], "phone": [], "phone_gate_only": []}
    out.update({k: [] for k in sweep})
    for i, fr in enumerate(frames):
        out["legacy"].append(bool(legacy.update(fr).motion))
        out["box"].append(an.process(fr, now=t0 + i / FPS) is not None)
        y = cv2.cvtColor(cv2.resize(fr, (320, 180), interpolation=cv2.INTER_AREA),
                         cv2.COLOR_BGR2GRAY)   # phone analyses a small Y plane
        out["phone"].append(bool(phone.feed(y)))
        gr = gate.feed(mg.phone_grid(y))
        out["phone_gate_only"].append(bool(gr.confirmed))
        plane = mg.pixel_plane(y)
        for k, st in sweep.items():
            pix = st[0].feed(plane, gr.moved, scene=gr.scene_change or gr.warming_up)
            cand = gr.candidate and pix and not (gr.scene_change or gr.warming_up)
            st[1] = st[1] + 1 if cand else 0
            out[k].append(st[1] >= mg.CONFIRM_FRAMES)
    return out


def eval_motion(pos, neg, rnd, n, kind):
    import cv2
    bgs = [img for img, _ in neg]
    cuts = [c for c in (person_cutout(img, anns) for img, anns in pos) if c is not None]
    methods = ["legacy", "box", "phone", "phone_gate_only"] + [
        "phone_pix_%d_%d" % (d, a) for d, a in PIX_SWEEP]
    res = {m: [0, 0, 0, 0] for m in methods}   # tp fp fn tn
    for i in range(min(n, len(bgs), len(cuts))):
        bg = cv2.resize(bgs[i], (640, 360))
        patch, mask = cuts[i]
        ph = rnd.randint(90, 230)
        pw = min(560, max(8, int(patch.shape[1] * ph / patch.shape[0])))
        patch = cv2.resize(patch, (pw, ph)).astype(np.float32)
        mask = cv2.resize(mask, (pw, ph)) > 127
        walk = (patch, mask, ph, pw, 360 - ph - rnd.randint(0, 20), rnd.randint(15, 90),
                rnd.random() < 0.5)
        plan = nuisance_plan(kind, rnd)
        seed = rnd.randrange(1 << 30)
        neg_f = run_methods(make_sequence(bg, None, kind, plan, False, seed, walk))
        pos_f = run_methods(make_sequence(bg, None, kind, plan, True, seed, walk))
        for m in res:
            fired_neg = any(neg_f[m][1:])
            hit = any(pos_f[m][k] and not neg_f[m][k] for k in range(SEQ_ENTER, SEQ_T))
            if m == "legacy":   # the old harness: any frame at all
                hit = any(pos_f[m][SEQ_ENTER:])
            res[m][0] += hit
            res[m][2] += not hit
            res[m][1] += fired_neg
            res[m][3] += not fired_neg
    return {m: prf(*v) for m, v in res.items()}


# ------------------------------------------------------- false night alerts
def sim_false_night(neg, det, cam_hours, rnd):
    """Long simulated nights at 160 x 90 (the box itself analyses 320 px):
    motion alerts (box: pixel blobs AND gate; phone: gate AND its pixel check
    — cctvacc2) with a 180 s cool-down, then the person check on each alert:
    *_person = the production night rule (enhanced frame, NIGHT_CONFIRM
    checks on consecutive frames), *_person_before = the cctvacc rule (one
    raw frame at 0.30)."""
    import cv2
    from shopbox import motion_gate as mg
    from shopbox import night
    from shopbox.motion import MotionDetector
    W, H = 160, 90
    cams = max(1, min(24, len(neg)))
    frames_per_cam = int(cam_hours * 3600 * FPS / cams)
    cool = int(180 * FPS)
    rng = np.random.default_rng(SEED)
    bank = [rng.normal(0, 8, (H, W)).astype(np.float32) for _ in range(48)]
    alerts = {"box_motion": 0, "phone_motion": 0, "box_person": 0, "phone_person": 0,
              "box_person_before": 0, "phone_person_before": 0}
    thr_n = night.PERSON_SCORE_NIGHT

    def night_score(fr):
        big = cv2.cvtColor(cv2.resize(fr, (640, 360)), cv2.COLOR_GRAY2BGR)
        raw = max([d.score for d in det.detect(big, score_thr=0.10)] or [0.0])
        img, _ = night.model_input(big)
        prod = raw if img is big else max(
            [d.score for d in det.detect(img, score_thr=0.10)] or [0.0])
        return raw, prod
    for c in range(cams):
        g = cv2.cvtColor(cv2.resize(neg[c][0], (W, H), interpolation=cv2.INTER_AREA),
                         cv2.COLOR_BGR2GRAY).astype(np.float32)
        base = 255.0 * np.power(g / 255.0, 1.5) * 0.7
        tree = rnd.random() < 0.5
        tx, ty = rnd.randint(0, W // 2), rnd.randint(0, H // 3)
        box, phone = MotionDetector(), mg.PhoneMotion()
        pending = {}                  # who -> frames still to confirm (2-frame rule)
        box_hits = 0
        next_box = next_phone = 0
        gain = 1.0
        rain_left = 0
        light = 1.0
        for k in range(frames_per_cam):
            f = base.copy()
            if tree:
                amp = 1.5 + 1.0 * math.sin(k / 900.0)
                reg = f[ty:ty + 30, tx:tx + 50]
                yy, xx = np.mgrid[0:reg.shape[0], 0:reg.shape[1]].astype(np.float32)
                f[ty:ty + 30, tx:tx + 50] = cv2.remap(
                    reg, xx + amp * np.sin(yy / 6.0 + k / 4.0), yy, cv2.INTER_LINEAR,
                    borderMode=cv2.BORDER_REFLECT)
            if rain_left <= 0 and rnd.random() < 0.15 / (3600 * FPS):
                rain_left = int(rnd.uniform(600, 2400) * FPS)
            if rain_left > 0:
                rain_left -= 1
                pts = rng.integers(0, [W, H], (60, 2))
                for x, y in pts:
                    f[y:min(H, y + 5), x] += 50.0
            if rnd.random() < 0.5 / (3600 * FPS):          # a light / IR switch
                light = rnd.choice([0.5, 0.7, 1.4, 1.9]) if light == 1.0 else 1.0
            gain = min(1.15, max(0.85, gain + rnd.uniform(-0.002, 0.002)))
            f *= light * gain * (1.0 + rnd.uniform(-0.03, 0.03))
            f += bank[rnd.randrange(len(bank))]
            fr = np.clip(f, 0, 255).astype(np.uint8)
            m = box.update(fr)
            box_hits = box_hits + 1 if m.motion else 0
            ph = phone.feed(fr)
            if pending:               # cctvacc2: the 2nd night check, next frame
                sc = None
                for who in list(pending):
                    if sc is None:
                        sc = night_score(fr)
                    pending[who] -= 1
                    if sc[1] < thr_n:
                        del pending[who]
                    elif pending[who] <= 0:
                        alerts[who + "_person"] += 1
                        del pending[who]
            for who, hit in (("box", box_hits >= mg.CONFIRM_FRAMES), ("phone", ph)):
                nxt = next_box if who == "box" else next_phone
                if hit and k >= nxt:
                    alerts[who + "_motion"] += 1
                    raw, prod = night_score(fr)
                    alerts[who + "_person_before"] += raw >= 0.30
                    if prod >= thr_n:
                        if night.NIGHT_CONFIRM <= 1:
                            alerts[who + "_person"] += 1
                        else:
                            pending[who] = night.NIGHT_CONFIRM - 1
                    if who == "box":
                        next_box = k + cool
                    else:
                        next_phone = k + cool
    weeks = cam_hours / NIGHT_HOURS_PER_WEEK
    out = {"camera_hours": cam_hours, "cameras": cams, "camera_weeks": round(weeks, 3)}
    for k, v in alerts.items():
        out[k] = {"alerts": v, "per_camera_week": round(v / weeks, 3),
                  "upper95_per_camera_week": round(poisson_upper95(v) / weeks, 3)}
    return out


def poisson_upper95(k):
    """Exact one-sided 95% upper bound for a Poisson count (chi-square)."""
    if k == 0:
        return 3.0
    if k > 50:
        return k + 1.645 * math.sqrt(k) + 1.0
    lo, hi = float(k), float(k) * 4 + 10
    for _ in range(80):
        mid = (lo + hi) / 2
        cdf = sum(math.exp(-mid) * mid ** i / math.factorial(i) for i in range(k + 1))
        lo, hi = (mid, hi) if cdf > 0.05 else (lo, mid)
    return hi


# ------------------------------------------------------------- owner clips
def eval_owner_clips(root, det):
    """Private owner clips (never committed): ROOT/labels.csv with columns
    file,label[,night]  (label person|no_person). Images -> person check;
    videos -> the full box pipeline (motion gate 3 frames + person check at
    the production thresholds). Only aggregate numbers leave this function."""
    import cv2
    from shopbox import motion_gate as mg
    from shopbox import night
    from shopbox.motion import MotionDetector
    img_c, vid_c = [0, 0, 0, 0], [0, 0, 0, 0]
    with open(os.path.join(root, "labels.csv"), newline="") as fh:
        rows = list(csv.DictReader(fh))
    for row in rows:
        path = os.path.normpath(os.path.join(root, row["file"]))
        if not path.startswith(os.path.normpath(root)) or not os.path.exists(path):
            continue
        label = row.get("label", "").strip() == "person"
        hit = False
        if path.lower().endswith((".jpg", ".jpeg", ".png")):
            img = cv2.imread(path)
            if img is None:
                continue
            x, _ = night.model_input(img)          # a still: one check
            hit = bool(det.detect(x, score_thr=night.person_threshold(img)))
            c = img_c
        else:
            cap = cv2.VideoCapture(path)
            fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
            every = max(1, int(round(fps / FPS)))
            md, hits, i = MotionDetector(), 0, 0
            nc = night.NightConfirm()
            while True:
                ok, fr = cap.read()
                if not ok:
                    break
                i += 1
                if i % every:
                    continue
                fr = cv2.resize(fr, (640, int(640 * fr.shape[0] / fr.shape[1])))
                hits = hits + 1 if md.update(fr).motion else 0
                if hits >= mg.CONFIRM_FRAMES:
                    x, is_n = night.model_input(fr)
                    found = bool(det.detect(x, score_thr=night.person_threshold(fr)))
                    if nc.check(found, is_n, i / fps):
                        hit = True
                        break
            cap.release()
            c = vid_c
        if label:
            c[0] += hit
            c[2] += not hit
        else:
            c[1] += hit
            c[3] += not hit
    return {"images": prf(*img_c), "clips": prf(*vid_c), "rows": len(rows)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ann", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", default="cctv_accuracy.json")
    ap.add_argument("--cache", default="/tmp/coco_eval")
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--motion-n", type=int, default=200)
    ap.add_argument("--night-cam-hours", type=float, default=252.0)
    ap.add_argument("--owner-clips", default="")
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
    t = time.time()
    person = eval_person(det, items, rnd)
    print("person eval %.0fs" % (time.time() - t), flush=True)
    motion = {}
    for kind in ("basic", "hard", "night"):
        t = time.time()
        motion[kind] = eval_motion(pos_imgs, neg_imgs, random.Random(SEED + len(kind)),
                                   a.motion_n, kind)
        print("motion %s %.0fs" % (kind, time.time() - t), flush=True)
    t = time.time()
    false_night = sim_false_night(neg_imgs, det, a.night_cam_hours, random.Random(SEED + 99))
    print("night sim %.0fs" % (time.time() - t), flush=True)
    owner = None
    if a.owner_clips and os.path.isdir(a.owner_clips):
        owner = eval_owner_clips(a.owner_clips, det)
    res = {"set": {"source": "COCO val2017", "positives": len(pos_imgs),
                   "negatives": len(neg_imgs), "min_person_frac": MIN_PERSON_FRAC,
                   "licences": sorted(set(OK_LICENCES.values())), "seed": SEED},
           "person_check": person, "motion_check": motion,
           "false_night_alerts": false_night, "owner_clips": owner, "images": ids}
    json.dump(res, open(a.out, "w"), indent=1)

    print("TEST SET: %d person / %d no-person images" % (len(pos_imgs), len(neg_imgs)))
    for v in VARIANTS:
        r = person["production"][v]
        print("PERSON %-9s production rule  P=%.3f R=%.3f F1=%.3f (night-flagged %.0f%%)"
              % (v, r["precision"], r["recall"], r["f1"],
                 100 * person["night_flag_rate"][v]))
    for v in VARIANTS:
        r = person["before"][v]
        print("PERSON %-9s before (cctvacc) P=%.3f R=%.3f" % (v, r["precision"], r["recall"]))
    ns = person["night_split"]
    pr = person["production_rule"]
    pk = ns["calibration_pick"]

    def pr_(m):
        return "P=%.3f R=%.3f" % (m["precision"], m["recall"])
    print("NIGHT production %s/%d/%.2f | calib pick %s/%d/%.2f (match=%s)"
          % (pr["pre"], pr["confirm"], pr["threshold"], pk["pre"], pk["confirm"],
             pk["threshold"], ns["production_matches_calibration_pick"]))
    print("NIGHT held-out: before %s | production %s | pick %s"
          % (pr_(ns["held_out_before"]), pr_(ns["held_out_at_production"]),
             pr_(ns["held_out_at_pick"])))
    print("NIGHT night_ir2: before %s | production %s | pick %s"
          % (pr_(ns["night_ir2_before"]), pr_(ns["night_ir2_at_production"]),
             pr_(ns["night_ir2_at_pick"])))
    best = sorted(ns["grid"].items(), key=lambda kv: -kv[1]["calibration"]["f1"])[:12]
    for k, g in best:
        print("  grid %-14s calib %s | held %s | ir2 %s" % (
            k, pr_(g["calibration"]), pr_(g["held_out"]), pr_(g["night_ir2"])))
    for kind, by in motion.items():
        print("MOTION %-5s " % kind + " | ".join(
            "%s P=%.3f R=%.3f" % (m, r["precision"], r["recall"]) for m, r in by.items()))
    fn = false_night
    print("FALSE NIGHT ALERTS per camera-week (%.1f cam-weeks): " % fn["camera_weeks"] +
          " | ".join("%s %.2f (95%% <= %.2f)" % (k, fn[k]["per_camera_week"],
                                                 fn[k]["upper95_per_camera_week"])
                     for k in ("box_motion", "phone_motion", "box_person", "phone_person",
                               "box_person_before", "phone_person_before")))
    if owner:
        print("OWNER CLIPS images P=%.3f R=%.3f | clips P=%.3f R=%.3f (n=%d)"
              % (owner["images"]["precision"], owner["images"]["recall"],
                 owner["clips"]["precision"], owner["clips"]["recall"], owner["rows"]))


if __name__ == "__main__":
    main()
