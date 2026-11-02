"""
cctv_rules.py — W3 smart alert TYPES (cctvalerts, owner CCTV order 3 Nov,
audit rows B1 B2 B6 B7 B9 B10 B11). PURE: no Django, no DB, no network.

What a camera alert is ABOUT, honestly mapped from what each vendor really
reports, plus the few rules the server can compute itself at zero cost:

  kind      who reports it
  --------  ----------------------------------------------------------------
  person    camera AI flag (Hik AcuSense detectionTarget, Dahua ObjectType /
            SmartMotionHuman, Imou msgType human / e_multiVideoAiPerArea,
            EZVIZ "pedestrian/human" type) or the Shop Box detector
  vehicle   same sources, vehicle words (Dahua SmartMotionVehicle, Hik
            detectionTarget vehicle, ...)
  animal    ONLY where a vendor names an animal / pet (some Imou / EZVIZ
            models). Hikvision ISAPI and Dahua SMD report human|vehicle only:
            for them the setting says "not on this camera".
  line      the camera's own line-crossing rule (Hik linedetection, Dahua
            CrossLineDetection + Direction, EZVIZ 10013) or the Shop Box line.
            Counted per day (and per direction where the vendor says it).
  loiter    SERVER rule: a person present on the same camera continuously
            (gaps <= LOITER_GAP_S) for >= LOITER_NEED_S during the NIGHT
            window (= the camera's own guard schedule; else after closing
            time; else 22:00-06:00). Vendor-native loitering (Hik loitering,
            Dahua WanderDetection, EZVIZ 10027) counts at once.
  covered   camera tamper alarm (Hik shelteralarm / defocus, Dahua VideoBlind,
            EZVIZ 10011/10021) or SERVER: two uniform stills in a row
  moved     camera scene-change alarm (Hik scenechangedetection, Dahua
            SceneChange, EZVIZ 10020) or SERVER: two stills >= 2 min apart
            that agree with each other but not with the remembered scene
  dark      SERVER: two near-black stills in a row (power cut, IR broken)
  sd_fail   Hik diskerror/diskfull, Dahua Storage*, Imou SD status message,
            EZVIZ storage-status call (checked every few hours)
  sound     Hik audioexception, Dahua AudioMutation/AudioAnomaly, Imou /
            EZVIZ sound / baby-cry alarms (some models only)

The stills the server looks at are the ones it ALREADY receives (alarm
pictures, webhook JPEGs) plus — only when the owner keeps covered/moved/dark
ON — one health still per camera every HEALTH_STILL_MIN in the guard window.
No AI model, no face recognition (AI snapshot check is package W4).
"""
import math
import re

KINDS = ("person", "vehicle", "animal", "line", "loiter",
         "covered", "moved", "dark", "sd_fail", "sound")
OBJECT_KINDS = ("person", "vehicle", "animal")
HEALTH_KINDS = ("covered", "moved", "dark", "sd_fail")
# animals (street dogs / cats) and sounds are noisy in Bangladesh -> off until
# the owner turns them on; everything else on.
DEFAULT_ON = {k: k not in ("animal", "sound") for k in KINDS}

LOITER_GAP_S = 90         # presence events further apart = a new visit
LOITER_NEED_S = 120       # owner order: loitering > 2 min at night
NIGHT_DEFAULT = {"start": "22:00", "end": "06:00"}
HEALTH_REFIRE_S = 6 * 3600   # the same camera-health problem: at most every 6 h
MOVED_MIN_GAP_S = 120
BAD_PERSIST_S = 60        # dark / covered must last >= 1 min (not a flicker)
SD_CHECK_EVERY_S = 6 * 3600

# support levels: yes = the vendor reports it; some = only some models;
# server = Assisto computes it from what arrives; no = impossible here.
YES, SOME, SERVER, NO = "yes", "some", "server", "no"

_GATEWAY = {"person": YES, "vehicle": NO, "animal": NO, "line": YES,
            "loiter": SERVER, "covered": SERVER, "moved": SERVER,
            "dark": SERVER, "sd_fail": NO, "sound": NO}
SUPPORT = {
    "hikvision": {"person": SOME, "vehicle": SOME, "animal": NO, "line": YES,
                  "loiter": SOME, "covered": YES, "moved": SOME,
                  "dark": SERVER, "sd_fail": YES, "sound": SOME},
    "dahua": {"person": SOME, "vehicle": SOME, "animal": NO, "line": YES,
              "loiter": SOME, "covered": YES, "moved": SOME,
              "dark": SERVER, "sd_fail": YES, "sound": SOME},
    "imou": {"person": YES, "vehicle": SOME, "animal": SOME, "line": SOME,
             "loiter": SERVER, "covered": SERVER, "moved": SERVER,
             "dark": SERVER, "sd_fail": SOME, "sound": SOME},
    "ezviz": {"person": SOME, "vehicle": SOME, "animal": SOME, "line": SOME,
              "loiter": SOME, "covered": SOME, "moved": SOME,
              "dark": SERVER, "sd_fail": SOME, "sound": SOME},
}

# ---------------------------------------------------------------- words
LABELS = {
    "person": ("মানুষ", "Person"),
    "vehicle": ("গাড়ি / মোটরসাইকেল", "Vehicle"),
    "animal": ("প্রাণী (কুকুর / বিড়াল)", "Animal (dog / cat)"),
    "line": ("রেখা পার হওয়া", "Line crossing"),
    "loiter": ("রাতে ২ মিনিটের বেশি ঘোরাঘুরি", "Loitering over 2 min at night"),
    "covered": ("ক্যামেরা ঢাকা / ঝাপসা", "Camera covered / blurred"),
    "moved": ("ক্যামেরা সরানো / ঘোরানো", "Camera moved / turned"),
    "dark": ("ছবি একদম অন্ধকার", "Picture completely dark"),
    "sd_fail": ("SD কার্ডে সমস্যা", "SD card problem"),
    "sound": ("জোরে শব্দ", "Loud sound"),
}
# what the alert says (never an accusation, always "please check")
WHAT = {
    "person": ("একজন মানুষ দেখা গেছে", "A person was seen"),
    "vehicle": ("একটি গাড়ি / মোটরসাইকেল দেখা গেছে", "A vehicle was seen"),
    "animal": ("একটি প্রাণী দেখা গেছে (কুকুর / বিড়াল হতে পারে)",
               "An animal was seen (maybe a dog or cat)"),
    "line": ("কেউ বা কিছু রেখা পার হয়েছে", "Something crossed the line"),
    "loiter": ("রাতে ২ মিনিটের বেশি সময় কেউ একই জায়গায় আছেন",
               "Someone has stayed in view for over 2 minutes at night"),
    "covered": ("ক্যামেরা ঢাকা পড়েছে বা ঝাপসা দেখাচ্ছে",
                "The camera looks covered or blurred"),
    "moved": ("ক্যামেরা সরানো বা ঘোরানো হয়েছে মনে হচ্ছে",
              "The camera seems to have been moved or turned"),
    "dark": ("ক্যামেরার ছবি একদম অন্ধকার — বাতি / বিদ্যুৎ দেখে নিন",
             "The camera picture is completely dark — check the light / power"),
    "sd_fail": ("ক্যামেরার SD কার্ডে সমস্যা — রেকর্ডিং না-ও হতে পারে",
                "The camera's SD card has a problem — it may not be recording"),
    "sound": ("ক্যামেরার কাছে জোরে শব্দ হয়েছে", "A loud sound near the camera"),
}
DIRECTION = {"a_to_b": ("ক → খ দিকে", "A → B"), "b_to_a": ("খ → ক দিকে", "B → A")}
SUPPORT_TEXT = {
    YES: ("এই ক্যামেরা নিজে জানায়", "This camera reports it"),
    SOME: ("কিছু মডেলে আছে — আপনার ক্যামেরা এখনো পাঠায়নি",
           "Some models only — your camera has not sent one yet"),
    SERVER: ("Assisto নিজে ধরে (ক্যামেরার ছবি / সতর্কতা থেকে)",
             "Assisto works it out (from the camera's pictures / alerts)"),
    NO: ("এই ক্যামেরায় নেই", "Not on this camera"),
}
SEEN_TEXT = ("এই ক্যামেরা পাঠিয়েছে", "This camera has sent it")


def support_for(vendor, kind, seen=()):
    """Effective support of `kind` on a camera of `vendor`, upgraded to YES
    once the camera has actually sent that kind. Loiter needs person
    detection: no person -> no loiter."""
    table = SUPPORT.get(vendor or "", _GATEWAY)
    if kind in seen:
        return YES
    lvl = table.get(kind, NO)
    if kind == "loiter" and table.get("person", NO) == NO:
        return NO
    return lvl


# ---------------------------------------------------------------- toggles
def normalize_toggles(raw, base=None):
    """{kind: bool} for every kind (unknown keys dropped, defaults filled)."""
    out = dict(DEFAULT_ON)
    if isinstance(base, dict):
        out.update({k: bool(v) for k, v in base.items() if k in KINDS})
    if isinstance(raw, dict):
        out.update({k: bool(v) for k, v in raw.items() if k in KINDS})
    return out


def muted(toggles, kind, obj=None):
    """True when the owner switched this alert type off for the camera: the
    kind itself, or a vehicle / animal that crossed the line (a PERSON on
    the line still alerts when "person" is off — the line is the rule)."""
    t = normalize_toggles(toggles)
    if kind in KINDS and not t[kind]:
        return True
    if obj in ("vehicle", "animal") and obj != kind and not t[obj]:
        return True
    return False


# ---------------------------------------------------------------- tokens
_SPLIT = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+")


def _tokens(text):
    """'e_multiVideoAiPerArea' -> {'e','multi','video','ai','per','area'}."""
    return {t.lower() for t in _SPLIT.findall(str(text or ""))}


def _blob(text):
    return re.sub(r"[^a-z0-9]", "", str(text or "").lower())


_HUMAN = ("human", "person", "people", "pedestrian", "humanoid", "humanbody",
          "aiper", "人形", "人体")
_VEHICLE_SUB = ("vehicle", "motorvehicle", "nonmotor", "motorcycle", "bicycle",
                "车")
_VEHICLE_TOK = {"car", "truck", "bus", "bike", "vehicle"}
_ANIMAL_SUB = ("animal", "宠物", "动物")
_ANIMAL_TOK = {"pet", "dog", "cat", "animal", "pets"}


def object_of(text):
    """person / vehicle / animal from a vendor's target / type text."""
    b, toks = _blob(text), _tokens(text)
    raw = str(text or "")
    if any(w in b for w in _ANIMAL_SUB) or toks & _ANIMAL_TOK or \
            any(w in raw for w in _ANIMAL_SUB):
        return "animal"
    if any(w in b for w in _VEHICLE_SUB) or toks & _VEHICLE_TOK or "车" in raw:
        return "vehicle"
    if any(w in b for w in _HUMAN) or any(w in raw for w in _HUMAN):
        return "person"
    return None


# event-code families (lower-cased, punctuation removed)
_LINE = ("linedetection", "crosslinedetection", "tripwire", "crossline",
         "linecross", "linecrossing", "越界")
_LOITER = ("loitering", "loiter", "wanderdetection", "wander", "徘徊")
_COVERED = ("shelteralarm", "videotampering", "videoblind", "tamperdetection",
            "tamper", "defocusdetection", "defocus", "shelter", "videomask",
            "遮挡", "虚焦")
_MOVED = ("scenechangedetection", "scenechange", "场景变更")
_SD = ("diskerror", "diskfull", "hderror", "hdfull", "storagefailure",
       "storagenotexist", "storagelowspace", "storageabnormal", "sdcarderror",
       "sdcardabnormal", "sdcardfail", "sderror")
_SOUND = ("audioexception", "audiomutation", "audioanomaly", "audiodetection",
          "abnormalsound", "sounddetection", "loudsound", "babycry", "crydetection",
          "noise", "decibel", "婴儿啼哭", "音频异常", "声音")
_SOUND_TOK = {"sound", "audio", "cry", "noise", "scream"}


def _family(text):
    b, raw, toks = _blob(text), str(text or ""), _tokens(text)

    def has(words):
        return any(w in b or w in raw for w in words)
    if has(_SD):
        return "sd_fail"
    if has(_COVERED):
        return "covered"
    if has(_MOVED):
        return "moved"
    if has(_SOUND) or toks & _SOUND_TOK:
        return "sound"
    if has(_LOITER):
        return "loiter"
    if has(_LINE):
        return "line"
    return None


def _direction(v):
    b = _blob(v)
    if b in ("lefttoright", "atob", "a2b", "in", "enter", "lefttorightin"):
        return "a_to_b"
    if b in ("righttoleft", "btoa", "b2a", "out", "leave", "exit"):
        return "b_to_a"
    return None


def _pack(kind, obj, direction=None):
    out = {}
    if kind:
        out["kind"] = kind
    if obj:
        out["object"] = obj
    if direction:
        out["direction"] = direction
    return out


def classify_hook(ev):
    """Hikvision / Dahua parsed event (camera_hooks) -> {kind, object,
    direction} (empty dict = plain motion / intrusion with no type)."""
    code = str((ev or {}).get("event") or "")
    target = str((ev or {}).get("target") or "")
    fam = _family(code)
    obj = object_of(target)
    if obj is None and code in ("smartmotionhuman",):
        obj = "person"
    if obj is None and code in ("smartmotionvehicle",):
        obj = "vehicle"
    kind = fam or obj
    return _pack(kind, obj if fam in (None, "line", "loiter") else None,
                 _direction(ev.get("direction")) if fam == "line" else None)


def classify_imou(msg):
    """Imou callback / getAlarmMessage row -> {kind, object}."""
    if not isinstance(msg, dict):
        return {}
    text = " ".join(str(msg.get(k) or "") for k in
                    ("msgType", "labelType", "name", "alarmType"))
    fam = _family(text)
    obj = object_of(text)
    return _pack(fam or obj, obj if fam in (None, "line", "loiter") else None)


# EZVIZ / Ys7 open-platform numeric alarm types (public alarm-type table;
# NOT yet verified on a real EZVIZ camera — see testdata SOURCES.json)
EZVIZ_CODES = {10003: "sound", 10011: "covered", 10013: "line",
               10020: "moved", 10021: "covered", 10022: "sound",
               10027: "loiter"}


def classify_ezviz(row):
    """EZVIZ alarm-list row -> {kind, object}. alarmName is the DEVICE name
    on EZVIZ (e.g. "C6N(BD1234567)") so it is never read for the type."""
    if not isinstance(row, dict):
        return {}
    t = row.get("alarmType")
    try:
        code = int(t)
    except (TypeError, ValueError):
        code = None
    if code is not None:
        return _pack(EZVIZ_CODES.get(code), None)
    fam = _family(t)
    obj = object_of(t)
    return _pack(fam or obj, obj if fam in (None, "line", "loiter") else None)


_SD_BAD = ("abnormal", "error", "fail", "damage", "broken", "exception",
           "unformat", "notformat", "readonly", "bad")


def imou_sd_problem(msg):
    """Imou SD-card STATUS message (msgType sdcardStatus/...) ->
    "problem" | "ok" | None (not an SD message / unknown value)."""
    if not isinstance(msg, dict):
        return None
    mt = _blob(msg.get("msgType"))
    if not (mt.startswith("sdcard") or mt.startswith("storage")):
        return None
    vals = " ".join(_blob(msg.get(k)) for k in
                    ("status", "state", "value", "sdcardStatus", "msg", "content"))
    if any(w in vals for w in _SD_BAD):
        return "problem"
    if "normal" in vals or "ok" in vals.split():
        return "ok"
    return None


def ezviz_sd_state(rows):
    """EZVIZ storage-status rows [{index, name, status}] -> "ok" | "problem"
    | "none" (no card). status 0 normal, 1 storage error, 2 not formatted,
    3 formatting."""
    if not isinstance(rows, list) or not rows:
        return "none"
    for r in rows:
        try:
            st = int((r or {}).get("status"))
        except (TypeError, ValueError, AttributeError):
            continue
        if st in (1, 2):
            return "problem"
    return "ok"


# ---------------------------------------------------------------- loitering
def loiter_step(state, ts, night, native=False,
                gap_s=LOITER_GAP_S, need_s=LOITER_NEED_S):
    """One person-presence event at `ts` on a camera. Returns
    (new_state, fire, seconds_present). Fires once per visit, only at night."""
    st = dict(state) if isinstance(state, dict) else {}
    try:
        start, last = float(st["start"]), float(st["last"])
    except (KeyError, TypeError, ValueError):
        start = last = None
    if last is None or ts - last > gap_s or ts < start:
        st = {"start": ts, "last": ts, "fired": False}
    else:
        st["last"] = max(last, ts)
    dur = st["last"] - st["start"]
    fire = bool(night) and not st.get("fired") and (native or dur >= need_s)
    if fire:
        st["fired"] = True
    return st, fire, int(dur)


# ---------------------------------------------------------------- stills
def _corr(a, b):
    if not a or not b or len(a) != len(b):
        return 0.0
    ma, mb = sum(a) / len(a), sum(b) / len(b)
    da = [x - ma for x in a]
    db = [y - mb for y in b]
    na = math.sqrt(sum(x * x for x in da))
    nb = math.sqrt(sum(y * y for y in db))
    if na < 1e-6 or nb < 1e-6:
        return 0.0
    return sum(x * y for x, y in zip(da, db)) / (na * nb)


def still_kind(mean, std):
    """dark / covered from a still's luminance (0..255) or None."""
    if mean < 20 and std < 8:
        return "dark"
    if std < 4:
        return "covered"          # uniform: a hand / cloth / tape on the lens
    return None


def assess_still(state, grid, mean, std, ir, ts):
    """One still (8x8 luminance grid, mean, std, ir=grey night picture) ->
    (new_state, kind or None). dark/covered: bad stills in a row spanning
    >= BAD_PERSIST_S (a light flicker or the IR switch-over is not a problem);
    moved = two stills >= MOVED_MIN_GAP_S apart that match EACH OTHER
    (corr >= 0.7) but not the remembered scene (corr < 0.35) — a person
    walking through never does that. Day and IR scenes are remembered
    separately (night IR looks nothing like day)."""
    st = dict(state) if isinstance(state, dict) else {}
    kind = still_kind(mean, std)
    if kind:
        prev = st.get("bad")
        st.pop("pending", None)
        if prev and prev.get("kind") == kind:
            first = float(prev.get("ts") or ts)
            if ts - first >= BAD_PERSIST_S:
                st["bad"] = {"kind": kind, "ts": ts}
                return st, kind
            return st, None              # keep the FIRST bad time
        st["bad"] = {"kind": kind, "ts": ts}
        return st, None
    st.pop("bad", None)
    key = "ref_ir" if ir else "ref_day"
    ref = st.get(key)
    if not ref:
        st[key] = [round(v, 1) for v in grid]
        return st, None
    c = _corr(grid, ref)
    if c >= 0.6:
        st[key] = [round(0.8 * r + 0.2 * g, 1) for r, g in zip(ref, grid)]
        st.pop("pending", None)
        return st, None
    if c < 0.35:
        p = st.get("pending")
        if p and p.get("ir") == bool(ir) and \
                ts - float(p.get("ts") or 0) >= MOVED_MIN_GAP_S and \
                _corr(grid, p.get("grid") or []) >= 0.7:
            st[key] = [round(v, 1) for v in grid]
            st.pop("pending", None)
            return st, "moved"
        if not p or p.get("ir") != bool(ir):
            st["pending"] = {"grid": [round(v, 1) for v in grid], "ts": ts,
                             "ir": bool(ir)}
    return st, None


def health_due(last_fired, kind, ts, every=HEALTH_REFIRE_S):
    """May a camera-health alert of `kind` fire again? (6 h per kind)."""
    try:
        return ts - float((last_fired or {}).get(kind) or 0) >= every
    except (TypeError, ValueError):
        return True


# ---------------------------------------------------------------- texts
def what(kind, lang, direction=None):
    bn, en = WHAT.get(kind, WHAT["person"])
    if kind == "line" and direction in DIRECTION:
        d = DIRECTION[direction]
        bn, en = "%s (%s)" % (bn, d[0]), "%s (%s)" % (en, d[1])
    return bn if lang == "bn" else en


def health_title(lang, cam_name):
    if lang == "bn":
        return "ক্যামেরার সমস্যা — একটু দেখে নিন: %s" % cam_name
    return "Camera problem — please check: %s" % cam_name


def line_count(state, day, direction=None):
    """Per-camera daily line-crossing counter."""
    st = dict(state) if isinstance(state, dict) else {}
    if st.get("day") != day:
        st = {"day": day, "total": 0, "a_to_b": 0, "b_to_a": 0}
    st["total"] = int(st.get("total", 0)) + 1
    if direction in ("a_to_b", "b_to_a"):
        st[direction] = int(st.get(direction, 0)) + 1
    return st
