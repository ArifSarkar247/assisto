"""cctv-accuracy: REAL-CLIP alert accuracy of the CCTV smart alerts.

Openly licensed clips (clips.json / SOURCES.md, Wikimedia Commons, SHA-1
pinned) with HUMAN labels (person / vehicle time intervals, written from the
contact sheets of sheets.py — never from model output) go through the same
alert paths the product runs:

  * shopbox  — the Shop Box / Linux Guard Box engine: shopbox.analyzer
               .CameraAnalyzer (motion.py + motion_gate, night.model_input,
               NightConfirm, confirm_frames) + the engine's per-type Cooldown
               (guard camera: person 60 s / motion 180 s), 3 frames a second.
  * ipcam    — the phone that watches an IP camera (app/lib/ipcam/
               ipcam_guard_screen.dart _tick/_onMotion + ipcam_logic.dart
               AlertClock): grid gate on the 160-px grey plane, a person
               check at most every 5 s, cool-down 60 s, NightConfirm.
  * phone    — the phone used as a camera (phonecam/phone_camera_screen.dart):
               gate + pixel check, same clock, a night person seen once is
               checked again on the next picture.

The person model is the shipped YOLOX-Nano (same file + SHA-256 as the phone
and the box); its boxes are computed ONCE per analysed frame (score >= 0.10)
and every simulated setting filters that cache, so a threshold sweep is
exactly what each setting would have seen.

Scoring (per alert, honest):
  * a person alert is CORRECT when it falls inside a labelled person interval
    (1 s before .. 2 s after); otherwise it is a FALSE alert;
  * a person VISIT (one labelled interval) is FOUND when a correct alert
    falls in it, or a correct alert came < cool-down earlier (the owner was
    alerted moments ago — the cool-down rightly stays quiet);
  * false alerts per camera-day = false alerts / labelled seconds x 86 400:
    i.e. if that scene (rain, a tree in wind, headlights ...) lasted all day.

Settings are TUNED on the development clips (odd ids) and REPORTED on the
held-out clips (even ids); numbers on all clips are shown as well.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import os
import sys
import time
from dataclasses import dataclass, field, replace
from typing import Dict, List, Optional, Tuple

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "edge", "shopbox"))

from fetch import load_clips, local_name  # noqa: E402

FPS = 3.0                 # Shop Box sample_fps = phone ~3 pictures a second
CACHE_THR = 0.10
PERSON_TYPES = ("person_detected", "zone_intrusion", "line_crossing",
                "hand_in_cash_zone", "after_hours")


# ----------------------------------------------------------------- settings
@dataclass(frozen=True)
class Setting:
    """One alert setting. The SHIPPED values come from the shared thresholds
    files (cctv_thresholds.json / guard_thresholds.json) — see shipped()."""
    name: str
    day_thr: float
    night_thr: float
    check_every_s: float = 5.0       # phone / ipcam person check spacing
    person_cool_s: float = 60.0
    motion_cool_s: float = 180.0
    ipcam_night_recheck: bool = False  # ipcam re-checks a pending night person
    day_confirm: int = 1             # phone / ipcam: day checks in a row
    min_box_h: float = 0.0           # smallest person box (share of frame height)
    model: bool = True               # False = motion-only fallback

    def short(self) -> str:
        return ("day %.2f night %.2f confirm %d minH %.2f recheck %s" %
                (self.day_thr, self.night_thr, self.day_confirm, self.min_box_h,
                 "on" if self.ipcam_night_recheck else "off"))


def shipped(name: str = "before") -> Setting:
    from shopbox import thresholds as T
    from shopbox.night import PERSON_SCORE_NIGHT

    t = T.load()
    return Setting(name=name, day_thr=float(t["person_score"]),
                   night_thr=float(PERSON_SCORE_NIGHT),
                   check_every_s=float(t["check_every_s"]),
                   person_cool_s=float(t["person_cooldown_s"]),
                   motion_cool_s=float(t["motion_cooldown_s"]))


# ----------------------------------------------------------------- frames
@dataclass
class Frame:
    t: float
    img: np.ndarray          # 640-px-wide BGR (analysis size)
    gray160: np.ndarray      # the ipcam decoder's grey plane (gw = 160)
    gray: np.ndarray         # 640-px grey (phone stream stand-in)
    night: bool = False
    people: List[Tuple[float, float, float, float, float]] = field(default_factory=list)
    vehicles: List[Tuple[float, float, float, float, float]] = field(default_factory=list)


def decode(path: str, fps: float = FPS, width: int = 640, max_s: float = 0.0):
    import cv2

    cap = cv2.VideoCapture(path)
    src = cap.get(cv2.CAP_PROP_FPS) or 25.0
    if src <= 0 or src > 240:
        src = 25.0
    out, i, t_next = [], 0, 0.0
    while True:
        ok, f = cap.read()
        if not ok:
            break
        t = i / src
        i += 1
        if max_s and t > max_s:
            break
        if t + 1e-6 < t_next:
            continue
        t_next += 1.0 / fps
        h, w = f.shape[:2]
        if w != width:
            f = cv2.resize(f, (width, max(1, int(round(h * width / w)))),
                           interpolation=cv2.INTER_AREA)
        g = cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)
        g160 = cv2.resize(g, (160, max(1, int(round(g.shape[0] * 160 / g.shape[1])))),
                          interpolation=cv2.INTER_AREA)
        out.append(Frame(t=t, img=f, gray160=g160, gray=g))
    cap.release()
    return out


def run_model(frames: List[Frame], det) -> None:
    """Boxes once per frame on exactly the model input the product builds
    (night frames are fit to 416 and enhanced: night.model_input)."""
    from shopbox.night import model_input
    from shopbox.person import VEHICLE_CLASS_IDS  # noqa: F401  (documented classes)

    for fr in frames:
        img, night = model_input(fr.img)
        fr.night = bool(night)
        if hasattr(det, "detect_all"):
            ppl, veh = det.detect_all(img, score_thr=CACHE_THR, vehicle_thr=0.2)
        else:
            ppl, veh = det.detect(img, score_thr=CACHE_THR), []
        fr.people = [(d.x1, d.y1, d.x2, d.y2, d.score) for d in ppl]
        fr.vehicles = [(v.x1, v.y1, v.x2, v.y2, v.score) for v in veh]


def people_at(fr: Frame, s: Setting) -> list:
    thr = s.night_thr if fr.night else s.day_thr
    return [b for b in fr.people if b[4] >= thr and (b[3] - b[1]) >= s.min_box_h]


# ----------------------------------------------------------------- paths
_MOTION: Dict[Tuple[int, str], List[bool]] = {}


def phone_motion(frames: List[Frame], kind: str) -> List[bool]:
    """The phone's motion decision per frame (does not depend on the person
    setting, so it is computed once per clip and path)."""
    key = (id(frames), kind)
    if key not in _MOTION:
        from shopbox.motion_gate import PhoneMotion

        m = PhoneMotion(pixel=(kind == "phone"))
        _MOTION[key] = [m.feed(f.gray160 if kind == "ipcam" else f.gray) for f in frames]
    return _MOTION[key]


def sim_phone_like(frames: List[Frame], s: Setting, kind: str) -> List[Tuple[float, str]]:
    """ipcam / phone Guard Box loop (see module doc). NightConfirm is the
    phone's rule (guard_box_model.dart NightConfirm = night.NightConfirm)."""
    from shopbox.night import NightConfirm

    moved_at = phone_motion(frames, kind)
    confirm = NightConfirm()
    last_alert = last_check = None
    alerts: List[Tuple[float, str]] = []
    pending = False
    for i, fr in enumerate(frames):
        if not moved_at[i]:
            continue
        t = fr.t
        cool = s.person_cool_s if s.model else s.motion_cool_s
        if last_alert is not None and t - last_alert < cool:
            continue
        may_pending = pending and kind == "phone"
        if last_check is not None and t - last_check < s.check_every_s and not may_pending:
            continue
        last_check = t
        if not s.model:
            alerts.append((t, "motion"))
            last_alert = t
            continue
        boxes = people_at(fr, s)
        ok = confirm.check(bool(boxes), fr.night, t)
        pending = confirm.pending
        recheck = kind == "phone" or s.ipcam_night_recheck
        if not ok and pending and recheck and i + 1 < len(frames):
            nx = frames[i + 1]       # the next picture (~0.33 s later)
            b2 = people_at(nx, s)
            ok = confirm.check(bool(b2), nx.night, nx.t)
            pending = confirm.pending
        if ok and not fr.night and s.day_confirm > 1:
            j = i
            for _ in range(s.day_confirm - 1):   # the next picture(s) must agree
                j += 1
                if j >= len(frames) or not people_at(frames[j], s):
                    ok = False
                    break
        if ok:
            alerts.append((t, "person_detected"))
            last_alert = t
    return alerts


class CachedDetector:
    """Gives CameraAnalyzer the cached boxes of the frame being processed."""
    name = "yolox_nano"
    available = True

    def __init__(self, setting: Setting):
        self.s = setting
        self.cur: Optional[Frame] = None

    def detect(self, img, score_thr=None):
        from shopbox.person import Detection

        thr = CACHE_THR if score_thr is None else float(score_thr)
        fr = self.cur
        return [Detection(*b[:4], b[4]) for b in fr.people
                if b[4] >= thr and (b[3] - b[1]) >= self.s.min_box_h]


def sim_shopbox(frames: List[Frame], s: Setting) -> List[Tuple[float, str]]:
    from shopbox.analyzer import CameraAnalyzer
    from shopbox.config import AppConfig, CameraConfig, DetectionConfig
    from shopbox.cooldown import Cooldown
    from shopbox.person import NullDetector

    cam = CameraConfig.from_dict({"id": "c", "name": "bench", "rtsp_url": "",
                                  "guard": True,
                                  "zones_v2": {"v": 2, "zones": []}})
    app = AppConfig(cameras=[cam])
    cfg = DetectionConfig()
    cfg.person_score, cfg.person_score_night = s.day_thr, s.night_thr
    det = CachedDetector(s) if s.model else NullDetector()
    clock = {"t": 0.0}
    an = CameraAnalyzer(cam, app.hours_for(cam), cfg, det, clock=lambda: clock["t"])
    cool = Cooldown(180.0, clock=lambda: clock["t"])
    base = 1_700_000_000.0
    alerts: List[Tuple[float, str]] = []
    for fr in frames:
        clock["t"] = base + fr.t
        if s.model:
            det.cur = fr
        trig = an.process(fr.img, now=base + fr.t)
        if trig is None:
            continue
        sec = s.person_cool_s if trig.type in PERSON_TYPES else s.motion_cool_s
        if cool.allow(("c", trig.type), sec):
            alerts.append((fr.t, trig.type))
    return alerts


def simulate(frames, s: Setting, path: str):
    return sim_shopbox(frames, s) if path == "shopbox" else sim_phone_like(frames, s, path)


# ----------------------------------------------------------------- scoring
def _inside(t, iv, pre=1.0, post=2.0):
    return any(a - pre <= t <= b + post for a, b in iv)


def score_clip(clip: dict, alerts, dur: float, cool_s: float) -> dict:
    lab = clip["labels"]
    iv = [tuple(x) for x in lab.get("person") or []]
    tp = [t for t, _ in alerts if _inside(t, iv)]
    fp = [t for t, _ in alerts if not _inside(t, iv)]
    found = 0
    for a, b in iv:
        if any(a - 1.0 <= t <= b + 2.0 for t in tp) or any(a - cool_s <= t < a for t in tp):
            found += 1
    return {"alerts": len(alerts), "tp": len(tp), "fp": len(fp), "visits": len(iv),
            "found": found, "seconds": dur, "fp_times": [round(t, 1) for t in fp]}


def detector_pr(clip: dict, frames: List[Frame], s: Setting, kind="person") -> dict:
    """Per-second detector quality (no motion gate / cool-down): a frame is
    positive when a box >= the setting's threshold is present."""
    lab = clip["labels"]
    iv = [tuple(x) for x in lab.get(kind) or []]
    tp = fp = fn = tn = 0
    nxt = 0.0
    for fr in frames:
        if fr.t + 1e-6 < nxt:
            continue
        nxt += 1.0
        # skip the 1-s fuzzy edges of each interval (labels are 1-2 s grained)
        truth = any(a + 1.0 <= fr.t <= b - 1.0 for a, b in iv)
        edge = any(a - 1.0 <= fr.t <= b + 1.0 for a, b in iv) and not truth
        if edge:
            continue
        if kind == "person":
            pred = bool(people_at(fr, s))
        else:
            pred = any(v[4] >= 0.35 for v in fr.vehicles)
        tp += pred and truth
        fp += pred and not truth
        fn += (not pred) and truth
        tn += (not pred) and (not truth)
    return {"tp": tp, "fp": fp, "fn": fn, "tn": tn}


def poisson_upper95(k: int) -> float:
    """Exact one-sided 95 % upper bound of a Poisson count (chi-square)."""
    if k == 0:
        return 2.996
    # Wilson-Hilferty approximation of chi2(0.95, 2k+2)/2
    df = 2 * k + 2
    z = 1.6449
    return df * (1 - 2 / (9 * df) + z * math.sqrt(2 / (9 * df))) ** 3 / 2


def aggregate(rows: List[dict]) -> dict:
    tp = sum(r["tp"] for r in rows)
    fp = sum(r["fp"] for r in rows)
    visits = sum(r["visits"] for r in rows)
    found = sum(r["found"] for r in rows)
    sec = sum(r["seconds"] for r in rows) or 1.0
    days = sec / 86400.0
    return {"alerts": tp + fp, "tp": tp, "fp": fp,
            "precision": round(tp / (tp + fp), 3) if tp + fp else None,
            "visits": visits, "found": found,
            "recall": round(found / visits, 3) if visits else None,
            "seconds": round(sec, 1),
            "fp_per_cam_day": round(fp / days, 1),
            "fp_per_cam_day_u95": round(poisson_upper95(fp) / days, 1)}


def evaluate(clips, frames_by, setting: Setting, path: str, ids=None):
    per = {}
    for c in clips:
        if ids is not None and c["id"] not in ids:
            continue
        fr = frames_by.get(c["id"])
        if not fr:
            continue
        al = simulate(fr, setting, path)
        dur = fr[-1].t + 1.0 / FPS
        cool = setting.person_cool_s if setting.model else setting.motion_cool_s
        per[c["id"]] = score_clip(c, al, dur, cool)
    return per


def by_scene(clips, per):
    out = {}
    for c in clips:
        if c["id"] in per:
            out.setdefault(c["scene"], []).append(per[c["id"]])
    return {k: aggregate(v) for k, v in sorted(out.items())}


# ----------------------------------------------------------------- tuning
def candidates(base: Setting):
    for d, n, conf, mh in itertools.product((0.40, 0.45, 0.50, 0.55, 0.60),
                                            (0.25, 0.30, 0.35, 0.40, 0.45),
                                            (1, 2), (0.0, 0.05, 0.10)):
        yield replace(base, name="cand", day_thr=d, night_thr=n, day_confirm=conf,
                      min_box_h=mh, ipcam_night_recheck=True)


def pick(clips, frames_by, base: Setting, dev_ids) -> Tuple[Setting, list]:
    """On DEV clips only (the two phone paths): keep the settings
    that find at least as many people as the shipped setting, then the
    fewest false alerts (ties: the shipped-closest threshold)."""
    def tot(s):
        # the phone paths (motion cached -> fast); the Shop Box shares the
        # same thresholds and is reported before / after below
        a = {"fp": 0, "found": 0}
        for p in ("ipcam", "phone"):
            g = aggregate(list(evaluate(clips, frames_by, s, p, dev_ids).values()))
            a["fp"] += g["fp"]
            a["found"] += g["found"]
        return a

    ref = tot(replace(base, ipcam_night_recheck=True))
    table = []
    for s in candidates(base):
        r = tot(s)
        table.append((s, r))
    ok = [(s, r) for s, r in table if r["found"] >= ref["found"]]
    ok.sort(key=lambda x: (x[1]["fp"], -x[1]["found"], abs(x[0].day_thr - base.day_thr)
                           + abs(x[0].night_thr - base.night_thr), x[0].day_confirm,
                           x[0].min_box_h))
    best = ok[0][0] if ok else replace(base, ipcam_night_recheck=True)
    return replace(best, name="after"), [
        {"setting": s.short(), "dev_fp": r["fp"], "dev_found": r["found"]}
        for s, r in sorted(table, key=lambda x: (x[1]["fp"], -x[1]["found"]))[:15]]


# ----------------------------------------------------------------- main
def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", required=True, help="dir with the fetched clips")
    ap.add_argument("--model", required=True)
    ap.add_argument("--out", default="cctv_clips.json")
    ap.add_argument("--only", default="")
    a = ap.parse_args(argv)

    from shopbox.person import load_detector

    det = load_detector(a.model, score_thr=CACHE_THR)
    clips = [c for c in load_clips() if c.get("labels")]
    only = {x for x in a.only.split(",") if x}
    if only:
        clips = [c for c in clips if c["id"] in only]
    frames_by: Dict[str, List[Frame]] = {}
    t0 = time.time()
    for c in clips:
        p = os.path.join(a.clips, local_name(c))
        if not os.path.exists(p):
            print("missing", c["id"])
            continue
        fr = decode(p, max_s=float(c["labels"].get("use_s") or 0))
        run_model(fr, det)
        frames_by[c["id"]] = fr
        print("decoded %s %-12s %4d frames  night %3d%%" % (
            c["id"], c["scene"], len(fr), 100 * sum(f.night for f in fr) / max(1, len(fr))))
    print("decode + model: %.0f s" % (time.time() - t0))

    ids = [c["id"] for c in clips if c["id"] in frames_by]
    dev = {i for i in ids if int(i[1:]) % 2 == 1}
    held = {i for i in ids if int(i[1:]) % 2 == 0}
    before = shipped("before")
    after, sweep = pick(clips, frames_by, before, dev)

    report = {"clips": len(ids), "seconds": round(sum(f[-1].t + 1 / FPS for f in frames_by.values()), 1),
              "dev": sorted(dev), "held_out": sorted(held),
              "before": before.short(), "after": after.short(), "sweep_top": sweep,
              "paths": {}}
    for path in ("shopbox", "ipcam", "phone"):
        rp = {}
        for label, s in (("before", before), ("after", after)):
            per_all = evaluate(clips, frames_by, s, path)
            rp[label] = {
                "all": aggregate(list(per_all.values())),
                "held_out": aggregate([v for k, v in per_all.items() if k in held]),
                "dev": aggregate([v for k, v in per_all.items() if k in dev]),
                "by_scene": by_scene(clips, per_all),
                "per_clip": per_all,
            }
        report["paths"][path] = rp
    # motion-only fallback (model could not load / old phone): what it costs
    mo = replace(before, name="motion_only", model=False)
    report["motion_only"] = {p: aggregate(list(evaluate(clips, frames_by, mo, p).values()))
                             for p in ("shopbox", "ipcam", "phone")}
    # detector-only per-second quality (no gate / no cool-down)
    for label, s in (("before", before), ("after", after)):
        tot = {"tp": 0, "fp": 0, "fn": 0, "tn": 0}
        vt = {"tp": 0, "fp": 0, "fn": 0, "tn": 0}
        for c in clips:
            if c["id"] not in frames_by:
                continue
            r = detector_pr(c, frames_by[c["id"]], s)
            for k in tot:
                tot[k] += r[k]
            if c["labels"].get("vehicle") is not None:
                rv = detector_pr(c, frames_by[c["id"]], s, kind="vehicle")
                for k in vt:
                    vt[k] += rv[k]
        report["detector_%s" % label] = tot
        report["vehicle_frames"] = vt

    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)

    print("\nclips %d, %.1f min; dev %d / held-out %d" % (
        len(ids), report["seconds"] / 60, len(dev), len(held)))
    print("before: %s\nafter : %s" % (before.short(), after.short()))
    for path, rp in report["paths"].items():
        for label in ("before", "after"):
            for part in ("held_out", "all"):
                g = rp[label][part]
                print("%-7s %-6s %-8s alerts %3d  precision %-5s  recall %-5s (%d/%d visits)"
                      "  false/cam-day %6.1f (95%% up %6.1f)" % (
                          path, label, part, g["alerts"], g["precision"], g["recall"],
                          g["found"], g["visits"], g["fp_per_cam_day"], g["fp_per_cam_day_u95"]))
        for sc, g in rp["after"]["by_scene"].items():
            b = rp["before"]["by_scene"][sc]
            print("    %-13s false %3d -> %3d   found %d/%d -> %d/%d" % (
                sc, b["fp"], g["fp"], b["found"], b["visits"], g["found"], g["visits"]))
    print("motion-only fallback:", json.dumps(report["motion_only"]))
    print("detector per second before:", report["detector_before"],
          "after:", report["detector_after"], "vehicles:", report["vehicle_frames"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
