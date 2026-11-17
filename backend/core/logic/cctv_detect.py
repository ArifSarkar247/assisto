"""
cctv_detect.py — PURE server rules for the CCTV Guard V3 zone detections
(agent/cctvdet, owner order 9 Nov 15:15 part C, stage 1). No Django, no DB.

The box / phone decides (edge/shopbox/shopbox/detect_rules.py = the app's
lib/cctv/detect_rules.dart); the SERVER stays the authority on:
  * the zone's own schedule (a device can never claim "armed")  -> zone_gate()
  * the honest confidence = the precision MEASURED in CI for that detection
    (MEASURED below == edge/shopbox/shopbox/cctv_thresholds.json["measured"],
    a backend test asserts they are equal)                      -> measured()
  * the plain words (bn/en) + the template description         -> words()

Never identity: a person box, never a face, a name or who it is.
"""

GATE_PERSON = "gate_person"
LOITERING = "loitering"
POST_EMPTY = "post_empty"
GATE_OPEN = "gate_open"
CAMERA_HEALTH = "camera_health"

CROWD = "crowd"
VEHICLE_IN_OUT = "vehicle_in_out"
PARKING_OVERSTAY = "parking_overstay"
WRONG_PARKING = "wrong_parking"
VEHICLE_TYPES = (VEHICLE_IN_OUT, PARKING_OVERSTAY, WRONG_PARKING)

# the zone detections (one per zone per visit / state change): stage 1 + 2
ZONE_TYPES = (GATE_PERSON, POST_EMPTY, GATE_OPEN, CROWD) + VEHICLE_TYPES
# cctvdet3 (lead decision, reversible): vehicle detections are a LOG + daily
# report (saved, no ringing push) until the owner's own clips confirm >= 90/90
# precision / recall; the owner turns ringing on per zone (opts.notify).
# Person / gate alerts are unchanged.
REPORT_ONLY_TYPES = VEHICLE_TYPES


def report_only(v2, etype, signals):
    """True when this detection is saved quietly (no ringing push)."""
    if etype not in REPORT_ONLY_TYPES:
        return False
    z = find_zone(v2, _inputs(signals).get("zone"))
    return not ((z or {}).get("opts") or {}).get("notify")
# alert types whose box clip is the 10 s detection clip (ACG1 preview envelope)
LONG_CLIP_TYPES = (GATE_PERSON, LOITERING, POST_EMPTY, GATE_OPEN, CAMERA_HEALTH,
                   CROWD) + VEHICLE_TYPES
# later stages: server types exist (one migration), nothing emits them yet
LATER_TYPES = ("smoke_fire", "fight", "fall", "weapon_review", "loud_sound")

# precision / recall per detection, measured by the cctv-accuracy CI job
# (tools/e2e/cctv_accuracy.py --detections). Empty = not measured yet: the
# alert then says so instead of showing a made-up number.
MEASURED = {
    "camera_health": {
        "n": 330,
        "p": 1.0,
        "r": 0.9133
    },
    "crowd": {
        "n": 240,
        "p": 0.962,
        "r": 0.842
    },
    "gate_open": {
        "n": 240,
        "p": 1.0,
        "r": 0.9556
    },
    "gate_person": {
        "n": 180,
        "p": 0.931,
        "r": 0.9
    },
    "loitering": {
        "n": 180,
        "p": 0.889,
        "r": 0.667
    },
    "parking_overstay": {
        "n": 261,
        "p": 0.874,
        "r": 0.826
    },
    "post_empty": {
        "n": 120,
        "p": 0.941,
        "r": 0.8
    },
    "vehicle_in_out": {
        "n": 300,
        "p": 0.589,
        "r": 0.608
    },
    "wrong_parking": {
        "n": 180,
        "p": 0.769,
        "r": 0.5
    }
}
MEASURED_RUN = "42726621893 (stage 2); cctvdet3 HELD-OUT 43967156868 (crowd / post / loitering / gate, old set) + 44021451977 (vehicles with the published model c0189c8f: in/out + overstay on the real Bangladeshi set, wrong parking on the old set - its real-set run timed out)"
MEASURED_SET = 'stage 2: COCO val2017 synthetic scenarios n=30/kind; cctvdet3: same + Sylhet street photos (CC BY 4.0), calibration/held-out split'

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")

WORDS = {
    GATE_PERSON: ("শাটার / গেটের সামনে কেউ আছেন", "Someone is at the shutter / gate"),
    POST_EMPTY: ("কাউন্টার / পোস্ট ফাঁকা পড়ে আছে", "The counter / post has been left empty"),
    GATE_OPEN: ("গেট / শাটার খোলা রয়ে গেছে", "The gate / shutter has been left open"),
    "crowd": ("ভিড় / লম্বা লাইন", "A crowd / long queue"),
    "vehicle_in_out": ("গাড়ি ঢুকেছে / বের হয়েছে", "A vehicle came in / went out"),
    "parking_overstay": ("গাড়ি নির্ধারিত সময়ের বেশি দাঁড়িয়ে আছে", "A vehicle has overstayed"),
    "wrong_parking": ("ভুল জায়গায় গাড়ি রাখা", "A vehicle is parked in the wrong place"),
    "smoke_fire": ("ধোঁয়া / আগুন দেখা যাচ্ছে মনে হচ্ছে", "Possible smoke / fire"),
    "fight": ("ধস্তাধস্তি হতে পারে — দেখে নিন", "Possible scuffle — please check"),
    "fall": ("কেউ পড়ে গেছেন মনে হচ্ছে", "Someone may have fallen"),
    "weapon_review": ("অস্ত্রের মতো কিছু — শুধু দেখে যাচাই করুন",
                      "Something like a weapon — review only"),
    "loud_sound": ("জোরে আওয়াজ / চিৎকারের মাত্রা", "A loud sound / shouting level"),
}


def bn(v):
    return str(v).translate(_BN)


def _inputs(signals):
    sig = signals if isinstance(signals, dict) else {}
    inner = sig.get("inputs")
    return inner if isinstance(inner, dict) else sig


def find_zone(v2, zone_id):
    for z in (v2 or {}).get("zones") or []:
        if str(z.get("id")) == str(zone_id or ""):
            return z
    return None


def zone_gate(v2, etype, signals, local_dt, is_armed):
    """None when the server lets this zone detection through, else a reason
    code. `is_armed(schedule, local_dt)` = core.logic.watchman.is_armed.
      * the zone must exist in the owner's CURRENT config (deleted = silent)
      * gate_person / dwell loitering: the zone's schedule, else the camera's
      * post_empty: the zone's own schedule only (when someone must be there)
      * gate_open: the zone's own schedule, else always
    """
    if etype not in ZONE_TYPES and not (etype == LOITERING and
                                        _inputs(signals).get("zone_dwell")):
        return None
    sig = _inputs(signals)
    if v2 is None:
        return "no_zones"
    z = find_zone(v2, sig.get("zone"))
    if z is None:
        return "zone_gone"
    sched = z.get("schedule") if isinstance(z.get("schedule"), dict) else None
    if etype == POST_EMPTY:
        if sched is None or not is_armed(sched, local_dt):
            return "post_off_hours"
        return None
    if etype in (GATE_OPEN, CROWD) + VEHICLE_TYPES:
        # an open gate / a vehicle: the zone's own schedule, else always
        return None if (sched is None or is_armed(sched, local_dt)) else "not_armed"
    use = sched if sched is not None else v2.get("schedule")
    return None if is_armed(use, local_dt) else "not_armed"


def measured(etype):
    """{"p", "r", "n"} measured in CI for this detection, or None."""
    m = MEASURED.get(etype)
    if not isinstance(m, dict) or m.get("p") is None:
        return None
    return {"p": float(m["p"]), "r": float(m.get("r") or 0.0), "n": int(m.get("n") or 0)}


def confidence(etype, default):
    """The confidence the alert shows: the MEASURED precision of this kind of
    alert when we have it (honest), else the guard's own estimate."""
    m = measured(etype)
    return round(m["p"], 3) if m else default


def measured_text(etype, lang):
    m = measured(etype)
    if not m:
        return ("এই ধরনের সতর্কতার সঠিকতা এখনো মাপা হয়নি"
                if lang == "bn" else "Accuracy of this alert type is not measured yet")
    pct = int(round(m["p"] * 100))
    if lang == "bn":
        return "পরীক্ষায় এই ধরনের সতর্কতা %s%% সঠিক (%sটি নমুনায় মাপা)" % (bn(pct), bn(m["n"]))
    return "In tests this alert type was right %d%% of the time (%d samples)" % (pct, m["n"])


def words(etype, lang):
    w = WORDS.get(etype)
    if not w:
        return None
    return w[0] if lang == "bn" else w[1]


def detail(etype, signals, lang):
    """The extra line under the title: zone name, minutes / seconds."""
    sig = _inputs(signals)
    label = str(sig.get("zone_label") or "")[:40]
    parts = []
    if label:
        parts.append(label)
    try:
        mins = int(sig.get("minutes") or 0)
    except (TypeError, ValueError):
        mins = 0
    try:
        secs = int(sig.get("seconds") or 0)
    except (TypeError, ValueError):
        secs = 0
    if etype in (POST_EMPTY, GATE_OPEN) and mins > 0:
        parts.append("%s মিনিট ধরে" % bn(mins) if lang == "bn" else "for %d min" % mins)
    if etype == LOITERING and secs > 0:
        m = max(1, secs // 60)
        parts.append("%s মিনিটের বেশি" % bn(m) if lang == "bn" else "over %d min" % m)
    if etype == CROWD and sig.get("count"):
        c = int(sig.get("count") or 0)
        parts.append("%s জন" % bn(c) if lang == "bn" else "%d people" % c)
    if etype in VEHICLE_TYPES:
        cls = VEHICLE_WORDS.get(str(sig.get("cls") or ""), VEHICLE_WORDS["vehicle"])
        parts.append(cls[0] if lang == "bn" else cls[1])
        if etype == VEHICLE_IN_OUT:
            parts.append(("ঢুকেছে" if sig.get("dir") == "in" else "বের হয়েছে") if lang == "bn"
                         else ("in" if sig.get("dir") == "in" else "out"))
        if etype == PARKING_OVERSTAY and mins > 0:
            parts.append("%s মিনিট ধরে" % bn(mins) if lang == "bn" else "for %d min" % mins)
        if etype == WRONG_PARKING and secs > 0:
            m = max(1, secs // 60)
            parts.append("%s মিনিট ধরে" % bn(m) if lang == "bn" else "for %d min" % m)
        p = plate_of(signals)
        if p:
            parts.append(("নম্বর: " + p["bn"]) if lang == "bn" else ("Plate: " + p["en"]))
    return " · ".join(parts)


VEHICLE_WORDS = {"car": ("গাড়ি", "car"), "motorbike": ("মোটরসাইকেল", "motorbike"),
                 "bus": ("বাস", "bus"), "truck": ("ট্রাক", "truck"),
                 "cycle": ("সাইকেল / রিকশা", "cycle / rickshaw"), "vehicle": ("যানবাহন", "vehicle")}


def plate_of(signals):
    """The vehicle's plate: read on the box, else read by the AI from the
    photo (signals["plate"] beside "inputs"). Plates are not faces."""
    sig = signals if isinstance(signals, dict) else {}
    for p in (_inputs(sig).get("plate"), sig.get("plate")):
        if isinstance(p, dict) and p.get("number"):
            return {"bn": str(p.get("bn") or p["number"])[:40], "en": str(p.get("en") or p["number"])[:40],
                    "number": str(p["number"])[:16], "partial": bool(p.get("partial")),
                    "source": str(p.get("source") or "")[:12]}
    return None


def event_fields(etype, signals, lang):
    """What the app shows for a detection alert (None for other types)."""
    if etype not in LONG_CLIP_TYPES and etype not in LATER_TYPES:
        return None
    sig = _inputs(signals)
    return {"title": words(etype, lang), "detail": detail(etype, signals, lang),
            "zone": str(sig.get("zone") or "") or None,
            "measured": measured(etype), "measured_text": measured_text(etype, lang),
            "review_only": etype == "weapon_review",
            "plate": plate_of(signals) if etype in VEHICLE_TYPES else None,
            "source": "edge" if sig.get("source") == "edge" else "server"}


# ---------------------------------------------------------------- zone config
ZONE_OPTS = {"dwell_s": (0, 3600), "absent_min": (1, 240), "open_min": (1, 720),
             "closed_at": (0, 4102444800), "crowd_n": (0, 50), "crowd_s": (10, 1800),
             "overstay_min": (5, 1440), "wrong_s": (30, 3600)}
POST_DEFAULT_SCHEDULE = {"days": [0, 1, 2, 3, 4, 5, 6], "start": "10:00", "end": "21:00"}


def clean_opts(raw, ztype):
    """Per-zone options (numbers clamped; unknown keys dropped)."""
    out = {}
    if not isinstance(raw, dict):
        raw = {}
    for k, (lo, hi) in ZONE_OPTS.items():
        if k not in raw or raw[k] in (None, ""):
            continue
        try:
            v = float(raw[k])
        except (TypeError, ValueError):
            continue
        if v != v:
            continue
        v = min(max(v, lo), hi)
        out[k] = int(v) if k != "closed_at" else round(v, 1)
    if ztype == "gate" and raw.get("watch_open") is True:
        out["watch_open"] = True
    if ztype == "entry_line":
        if raw.get("vehicles") is True:
            out["vehicles"] = True
        if raw.get("notify") is True:
            out["notify"] = True
        if raw.get("in_side") in ("left", "right"):
            out["in_side"] = raw["in_side"]
        out.pop("crowd_n", None)
        out.pop("crowd_s", None)
    if ztype in ("parking", "no_parking"):
        if raw.get("notify") is True:
            out["notify"] = True
        out.pop("crowd_n", None)
        out.pop("crowd_s", None)
        out.pop("dwell_s", None)
    if ztype != "parking":
        out.pop("overstay_min", None)
    if ztype != "no_parking":
        out.pop("wrong_s", None)
    if ztype == "parking" and "overstay_min" not in out:
        out["overstay_min"] = 60
    if ztype == "no_parking" and "wrong_s" not in out:
        out["wrong_s"] = 120
    if out.get("crowd_n", 1) < 2:
        out.pop("crowd_n", None)
        out.pop("crowd_s", None)
    if ztype == "entry_line":
        out.pop("dwell_s", None)
    if ztype != "post":
        out.pop("absent_min", None)
    if ztype != "gate":
        out.pop("open_min", None)
        out.pop("closed_at", None)
    if ztype == "post" and "absent_min" not in out:
        out["absent_min"] = 5
    if ztype == "gate" and out.get("watch_open") and "open_min" not in out:
        out["open_min"] = 10
    if out.get("dwell_s") == 0:
        out.pop("dwell_s")
    return out
