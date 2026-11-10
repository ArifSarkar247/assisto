"""cctvdet: zone detections — the shared cases (also run by the phone app,
app/test/cctv_detect_parity_test.dart) + the constants equal the shared
thresholds file."""
import json
import os

from shopbox import detect_rules as dr

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(os.path.join(HERE, "..", "shopbox", "cctv_thresholds.json")))
FIX = json.load(open(os.path.join(HERE, "fixtures", "detect_cases.json")))


def patch_of(p):
    w, h = dr.PATCH_W, dr.PATCH_H
    out = []
    for j in range(h):
        for i in range(w):
            k = j if p["pattern"] == "h" else i
            out.append(float(p["lo"] if k % 2 == 0 else p["hi"]))
    return out


def test_constants_match_the_shared_spec():
    d = SPEC["detect"]
    for k, v in d.items():
        assert getattr(dr, k.upper()) == v, k


def _match(got, want):
    assert len(got) == len(want), (got, want)
    for g, w in zip(got, want):
        for k, v in w.items():
            assert g.get(k) == v, (k, g, w)


def run_case(case):
    rules = dr.ZoneRules(case["zones"], case.get("cam_schedule"))
    for s in case["steps"]:
        if "check" in s:
            assert rules.needs_person_check(s["t"], s["wd"], s["min"],
                                            s["check"]["last"]) == s["check"]["expect"], s
        if "set_ref" in s:
            r = s["set_ref"]
            rules.set_ref(r["zone"], patch_of(r["patch"]), r["night"], r["t"])
        patches = {k: patch_of(v) for k, v in (s.get("patches") or {}).items()} or None
        got = rules.step(s["t"], s["wd"], s["min"], s["boxes"], s["night"], patches,
                         min_score=s.get("min_score", 0.0), vehicles=s.get("vehicles"))
        _match(got, s["expect"])
        for zid, want in (s.get("expect_wants_ref") or {}).items():
            assert rules.wants_ref(zid) == want, s


def test_shared_cases():
    names = []
    for case in FIX["cases"]:
        run_case(case)
        names.append(case["name"])
    assert len(names) >= 13


def test_tamper_cases():
    for name, seq in FIX["tamper"].items():
        st = {}
        for s in seq:
            st, kind = dr.assess_still(st, s["grid"], s["mean"], s["std"], s["ir"], s["ts"])
            assert kind == s["expect"], (name, s["ts"], kind)


def test_patch_cases():
    for c in FIX["patches"]:
        got = dr.zone_patch(c["gray"], c["w"], c["h"], c["poly"], c["pw"], c["ph"])
        assert got == c["expect"]


def test_similarity_cases():
    for c in FIX["similarity"]:
        got = dr.similarity(patch_of(c["a"]), patch_of(c["b"]), c["grad_only"])
        assert abs(got - c["expect"]) < 1e-3, c


def test_no_model_never_guesses_presence_or_absence():
    post = {"id": "p", "type": "post", "points": [[0, 0], [1, 0], [1, 1], [0, 1]],
            "schedule": {"days": list(range(7)), "start": "00:00", "end": "00:00"},
            "opts": {"absent_min": 1}}
    gate = {"id": "g", "type": "gate", "points": [[0, 0], [1, 0], [1, 1], [0, 1]],
            "opts": {"dwell_s": 10}}
    r = dr.ZoneRules([post, gate])
    for t in range(0, 600, 5):
        assert r.step(float(t), 2, 600, None) == []


def test_tamper_check_reports_only_covered_and_moved():
    tc = dr.TamperCheck()
    assert tc.due(0.0)
    assert tc.check([5] * 64, 5, 1, False, 0.0) is None
    assert not tc.due(10.0)
    # dark (a night with the lights off) is never reported as tamper
    assert tc.check([5] * 64, 5, 1, False, 90.0) is None


def test_still_stats_flat_and_gradient():
    g, mean, std = dr.still_stats([100] * 64, 8, 8)
    assert g == [100.0] * 64 and mean == 100 and std == 0
    grey = [x * 30 for _y in range(8) for x in range(8)]
    g, mean, std = dr.still_stats(grey, 8, 8)
    assert g[:8] == [0.0, 30.0, 60.0, 90.0, 120.0, 150.0, 180.0, 210.0]
    assert abs(mean - 105) < 1e-9 and std > 60


def test_schedule_like_the_server():
    s = {"days": [4], "start": "22:00", "end": "06:00"}
    assert dr.schedule_armed(s, 4, 23 * 60)          # Fri 23:00
    assert dr.schedule_armed(s, 5, 5 * 60)           # Sat 05:00 (Fri's night)
    assert not dr.schedule_armed(s, 5, 23 * 60)
    assert dr.schedule_armed(None, 0, 0)
    assert dr.schedule_armed({"days": [1], "start": "00:00", "end": "00:00"}, 1, 700)


def test_unknown_and_line_zones_are_left_to_the_analyzer():
    r = dr.ZoneRules([{"id": "c", "type": "cash", "points": [[0, 0], [1, 0], [1, 1]]},
                      {"id": "l", "type": "entry_line", "points": [[0, 0], [1, 1]]},
                      {"id": "x", "type": "weird", "points": [[0, 0], [1, 0], [1, 1]]}])
    assert r.zones == []


def test_shape_cases_camera_moved_by_shapes():
    for name, seq in FIX["shape"].items():
        st = {}
        for s in seq:
            st, kind = dr.assess_shape(st, patch_of(s["shape"]), s["ir"], s["ts"])
            assert kind == s["expect"], (name, s["ts"], kind)


def test_tamper_check_uses_shapes_when_the_grid_rule_is_unsure():
    tc = dr.TamperCheck()
    grid = [float(i % 8) * 20 + 40 for i in range(64)]
    h = patch_of({"pattern": "h", "lo": 50, "hi": 200})
    v = patch_of({"pattern": "v", "lo": 50, "hi": 200})
    # the grid stays alike (corr 1) -> only the shape rule can see the turn
    assert tc.check(grid, 110, 46, False, 0, h) is None
    assert tc.check(grid, 110, 46, False, 30, v) is None
    assert tc.check(grid, 110, 46, False, 160, v) == "moved"


def test_bd_plate_cases():
    from shopbox.plates import parse_bd_plate
    for c in FIX["plates"]:
        got = parse_bd_plate(c["text"])
        if c["bn"] is None:
            assert got is None, c
            continue
        for k in ("bn", "en", "number", "partial"):
            assert got[k] == c[k], (k, got, c)


def test_vehicle_signals_carry_plate_but_never_identity():
    from shopbox import payload
    s = payload.build_signals(payload.VEHICLE_IN_OUT, detector="yolox_nano", det={
        "zone": "l1", "dir": "in", "cls": "car",
        "plate": {"bn": "ঢাকা মেট্রো-গ ১২-৩৪৫৬", "en": "DHAKA METRO-GA 12-3456",
                  "number": "12-3456", "partial": False, "source": "box_ocr"}})
    assert s["vehicle"] and s["dir"] == "in" and s["plate"]["number"] == "12-3456"
    assert "face" not in str(s) and "name" not in s
    c = payload.build_signals(payload.CROWD, detector="yolox_nano", det={"zone": "q", "count": 7})
    assert c["crowd"] and c["count"] == 7
