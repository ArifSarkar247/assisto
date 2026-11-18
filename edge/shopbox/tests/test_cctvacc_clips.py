"""cctv-accuracy: the real-clip harness (tools/cctvacc/run_clips.py) — its
alert loops and scoring on synthetic frames (no model, no download), and the
clip list's licence / label hygiene."""
import json
import os
import sys

import numpy as np
import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.abspath(os.path.join(HERE, "..", "..", "..", "tools", "cctvacc"))
sys.path.insert(0, TOOLS)

rc = pytest.importorskip("run_clips")


def _frames(n, night=False, people=True, fps=3.0):
    out = []
    for i in range(n):
        g = np.zeros((90, 160), np.uint8)
        f = rc.Frame(t=i / fps, img=np.zeros((360, 640, 3), np.uint8), gray160=g,
                     gray=np.zeros((360, 640), np.uint8), night=night)
        if people:
            f.people = [(0.4, 0.2, 0.6, 0.9, 0.62)]
        out.append(f)
    return out


def _moving(frames, kind):
    rc._MOTION[(id(frames), kind)] = [True] * len(frames)


def test_ipcam_night_person_needs_the_immediate_recheck():
    """The bug the real IR clips found: with a 5-s check spacing the night
    2-check rule (<= 2 s apart) never confirms on the IP-camera Guard Box."""
    fr = _frames(60, night=True)
    _moving(fr, "ipcam")
    s = rc.shipped()
    assert rc.sim_phone_like(fr, s, "ipcam") == []
    fixed = rc.replace(s, ipcam_night_recheck=True)
    al = rc.sim_phone_like(fr, fixed, "ipcam")
    assert al and al[0][1] == "person_detected"
    # the phone camera always re-checked the next picture
    _moving(fr, "phone")
    assert rc.sim_phone_like(fr, s, "phone")


def test_day_person_alerts_once_per_cooldown_and_thresholds_filter():
    fr = _frames(3 * 130)                      # 130 s of a person in view
    _moving(fr, "ipcam")
    s = rc.shipped()
    al = rc.sim_phone_like(fr, s, "ipcam")
    assert [round(t) for t, _ in al] == [0, 60, 120]     # 60-s cool-down
    strict = rc.replace(s, day_thr=0.7)                  # the 0.62 box is too weak
    assert rc.sim_phone_like(fr, strict, "ipcam") == []
    tall = rc.replace(s, min_box_h=0.8)                  # the box is 0.7 high
    assert rc.sim_phone_like(fr, tall, "ipcam") == []


def test_day_confirm_needs_the_next_picture_too():
    fr = _frames(30)
    for i, f in enumerate(fr):
        if i % 2:
            f.people = []                      # flickering single-frame box
    _moving(fr, "ipcam")
    s = rc.replace(rc.shipped(), day_confirm=2)
    assert rc.sim_phone_like(fr, s, "ipcam") == []


def test_motion_only_fallback_uses_the_motion_cooldown():
    fr = _frames(3 * 400, people=False)
    _moving(fr, "ipcam")
    mo = rc.replace(rc.shipped(), model=False)
    al = rc.sim_phone_like(fr, mo, "ipcam")
    assert [round(t) for t, _ in al] == [0, 180, 360]
    assert all(k == "motion" for _, k in al)


def test_scoring_visits_false_alerts_and_per_day_rate():
    clip = {"labels": {"person": [[10, 20], [100, 110]]}}
    alerts = [(11.0, "person_detected"), (50.0, "person_detected"), (101.0, "person_detected")]
    r = rc.score_clip(clip, alerts, 200.0, 60.0)
    assert (r["tp"], r["fp"], r["visits"], r["found"]) == (2, 1, 2, 2)
    assert r["delays"] == [1.0, 1.0]
    # a visit that starts inside the cool-down of a correct alert counts as found
    clip2 = {"labels": {"person": [[10, 20], [40, 45]]}}
    r2 = rc.score_clip(clip2, [(11.0, "person_detected")], 60.0, 60.0)
    assert r2["found"] == 2
    g = rc.aggregate([r])
    assert g["precision"] == round(2 / 3, 3)
    assert g["fp_per_cam_day"] == round(1 / (200 / 86400), 1)
    assert g["fp_per_cam_day_u95"] > g["fp_per_cam_day"]
    assert rc.poisson_upper95(0) == pytest.approx(2.996, abs=1e-3)


def test_shopbox_path_runs_the_real_analyzer_on_cached_boxes():
    fr = _frames(30)
    # moving content so motion.py sees motion: a bright block walking right
    for i, f in enumerate(fr):
        f.img = np.empty((360, 640, 3), np.uint8)
        f.img[:] = (60, 140, 200)              # a colour day scene (not IR grey)
        x = 40 + i * 18
        f.img[100:300, x:x + 60] = (200, 60, 40)
    al = rc.sim_shopbox(fr, rc.shipped())
    assert al and al[0][1] == "person_detected"
    none = rc.sim_shopbox(fr, rc.replace(rc.shipped(), day_thr=0.9))
    assert none == []


def test_clip_list_is_licensed_sourced_and_labelled_by_hand():
    clips = json.load(open(os.path.join(TOOLS, "clips.json"), encoding="utf-8"))
    ok = ("CC0", "Public domain", "CC BY", "CC BY-SA")
    used = [c for c in clips if c.get("labels")]
    assert len(used) >= 20
    for c in clips:
        assert c["url"].startswith("https://upload.wikimedia.org/")
        assert c["page"].startswith("https://commons.wikimedia.org/")
        assert len(c["sha1"]) == 40
        assert c["licence"].startswith(ok), c["id"]
        assert c.get("labels") or c.get("dropped") or c["id"] in PENDING, c["id"]
    for c in used:
        for a, b in c["labels"]["person"]:
            assert 0 <= a < b <= (c["duration"] or 0) + 1, c["id"]
    scenes = {c["scene"] for c in used}
    for need in ("rain", "tree", "night_ir", "pet", "headlights"):
        assert need in scenes
    src = open(os.path.join(TOOLS, "SOURCES.md"), encoding="utf-8").read()
    for c in used:
        assert c["id"] in src and c["licence"] in src


PENDING = set()
