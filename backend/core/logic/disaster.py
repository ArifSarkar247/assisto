"""
disaster.py — Assisto BD DISASTER ALERTS logic (no AI key; pure Python,
deterministic, unit-testable).  SPEC v2.1 §21 / Appendix-A #44: good → advanced.

WHAT THIS IS
    Bangladesh-specific disaster & weather-warning logic: cyclone signal
    numbers, river-flood danger levels, heat-index bands and earthquake
    awareness.  This module is the SINGLE deterministic source the Flutter
    screen mirrors for: severity bands, "what to do" safety steps, a
    preparedness checklist, and family-location-aware matching (is a family
    member inside an affected area?).

CRITICAL — OFFICIAL SOURCES ONLY, NEVER FABRICATE A WARNING
    Every piece of data here is either (a) static, source-noted reference
    content (the meaning of cyclone signals, flood danger levels, heat bands,
    per-disaster safety steps, preparedness lists, hotlines) condensed from the
    official Bangladesh authorities, OR (b) a classifier over an ACTIVE warning
    the integrator has fetched from an official feed.

    This module NEVER invents an active warning.  `active_warnings()` returns
    ONLY what the caller passes in from the official feed; with no feed key /
    no data it returns an empty list and the UI must show the honest
    "connect the official feed" state (see `feed_state`).  The curated SAMPLE
    content below is explicitly flagged `sample=True` / `is_live=False` so the
    UI can label it "example — not a live warning" and can NEVER be mistaken
    for a real active alert.

OFFICIAL SOURCES (source-noted throughout)
    BMD   — Bangladesh Meteorological Department (bmd.gov.bd): cyclone signals,
            heat / weather warnings.
    FFWC  — Flood Forecasting & Warning Centre (ffwc.gov.bd): river water
            levels vs danger level.
    DDM   — Department of Disaster Management (ddm.gov.bd): preparedness,
            coordination.
    Hotlines: 999 (national emergency) and 1090 (toll-free disaster / weather
            warning IVR, BMD/DDM).

Run self-tests:
    python3 -c "import core.logic.disaster_tests_snippets as t; t.run_all()"
"""

# ---------------------------------------------------------------------------
# bilingual helper (strings the server may hand the UI in either language)
# ---------------------------------------------------------------------------

def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# official hotlines (never changes; source-noted)
# ---------------------------------------------------------------------------

HOTLINE_EMERGENCY = "999"    # national emergency (police / fire / ambulance)
HOTLINE_DISASTER = "1090"    # toll-free disaster / weather warning IVR (BMD/DDM)


# ---------------------------------------------------------------------------
# severity bands — one shared vocabulary across every disaster kind
# ---------------------------------------------------------------------------

SEV_INFO = "info"        # awareness / watch, no current threat
SEV_ADVISORY = "advisory"
SEV_WARNING = "warning"
SEV_SEVERE = "severe"
SEV_EXTREME = "extreme"

_SEV_RANK = {
    SEV_INFO: 0, SEV_ADVISORY: 1, SEV_WARNING: 2, SEV_SEVERE: 3, SEV_EXTREME: 4,
}


def severity_rank(sev):
    return _SEV_RANK.get(sev, 0)


# ---------------------------------------------------------------------------
# disaster kinds
# ---------------------------------------------------------------------------

KIND_CYCLONE = "cyclone"
KIND_FLOOD = "flood"
KIND_HEAT = "heat"
KIND_EARTHQUAKE = "earthquake"

KINDS = (KIND_CYCLONE, KIND_FLOOD, KIND_HEAT, KIND_EARTHQUAKE)


# ---------------------------------------------------------------------------
# CYCLONE — BMD "Great Danger / Danger" signal system (reference meaning only).
# The Bangladesh maritime-port signal scale runs 1–11.  We map each signal to a
# severity band.  This is the MEANING of a signal, not a claim one is active.
# Source: BMD (bmd.gov.bd) storm-warning signal system.
# ---------------------------------------------------------------------------

CYCLONE_SIGNAL_MIN = 1
CYCLONE_SIGNAL_MAX = 11


def cyclone_signal_severity(signal):
    """Map a BMD cyclone signal number (1-11) to a severity band.

    1-3  distant / cautionary  -> advisory
    4-6  local warning         -> warning
    7-9  danger                -> severe
    10-11 great danger         -> extreme
    Out-of-range / None -> info.
    """
    try:
        s = int(signal)
    except (TypeError, ValueError):
        return SEV_INFO
    if s < CYCLONE_SIGNAL_MIN or s > CYCLONE_SIGNAL_MAX:
        return SEV_INFO
    if s <= 3:
        return SEV_ADVISORY
    if s <= 6:
        return SEV_WARNING
    if s <= 9:
        return SEV_SEVERE
    return SEV_EXTREME


def cyclone_signal_label(signal, lang="bn"):
    """Short human label for a signal number. Reference meaning (BMD)."""
    sev = cyclone_signal_severity(signal)
    bn = {
        SEV_ADVISORY: "দূরবর্তী সতর্ক সংকেত",
        SEV_WARNING: "স্থানীয় সতর্ক সংকেত",
        SEV_SEVERE: "বিপদ সংকেত",
        SEV_EXTREME: "মহাবিপদ সংকেত",
        SEV_INFO: "সংকেত নেই",
    }[sev]
    en = {
        SEV_ADVISORY: "Distant cautionary signal",
        SEV_WARNING: "Local warning signal",
        SEV_SEVERE: "Danger signal",
        SEV_EXTREME: "Great danger signal",
        SEV_INFO: "No signal",
    }[sev]
    return pick(lang, bn, en)


# ---------------------------------------------------------------------------
# FLOOD — FFWC river water level vs danger level (reference bands).
# FFWC publishes, per station, the current level and the "danger level" (DL).
# metres ABOVE danger level -> severity.  Source: FFWC (ffwc.gov.bd).
# ---------------------------------------------------------------------------

def flood_level_severity(above_danger_m):
    """Severity from metres above the FFWC danger level.
    below 0 (under DL) -> info ; 0 to <0.5 -> advisory ; 0.5 to <1 -> warning ;
    1 to <1.5 -> severe ; >=1.5 -> extreme."""
    try:
        d = float(above_danger_m)
    except (TypeError, ValueError):
        return SEV_INFO
    if d < 0:
        return SEV_INFO
    if d < 0.5:
        return SEV_ADVISORY
    if d < 1.0:
        return SEV_WARNING
    if d < 1.5:
        return SEV_SEVERE
    return SEV_EXTREME


# ---------------------------------------------------------------------------
# HEAT — BMD heatwave classification by max temperature (°C).  Reference bands.
# BMD: mild 36-38, moderate 38-40, severe 40-42, very severe >=42.
# Source: BMD (bmd.gov.bd) heatwave definitions.
# ---------------------------------------------------------------------------

def heat_severity(temp_c):
    """Severity from a max temperature in °C (BMD heatwave bands)."""
    try:
        t = float(temp_c)
    except (TypeError, ValueError):
        return SEV_INFO
    if t < 36:
        return SEV_INFO
    if t < 38:
        return SEV_ADVISORY     # mild heatwave
    if t < 40:
        return SEV_WARNING      # moderate heatwave
    if t < 42:
        return SEV_SEVERE       # severe heatwave
    return SEV_EXTREME          # very severe heatwave


def heat_index_c(temp_c, humidity_pct):
    """Approximate 'feels-like' heat index in °C (NOAA Rothfusz regression,
    converted from °F).  For displaying how hot it feels — advisory only.
    Returns rounded float, or None if inputs are invalid."""
    try:
        t = float(temp_c)
        h = float(humidity_pct)
    except (TypeError, ValueError):
        return None
    # heat index only meaningful at warm temperatures
    if t < 27:
        return round(t, 1)
    tf = t * 9.0 / 5.0 + 32.0
    hi = (
        -42.379 + 2.04901523 * tf + 10.14333127 * h
        - 0.22475541 * tf * h - 0.00683783 * tf * tf
        - 0.05481717 * h * h + 0.00122874 * tf * tf * h
        + 0.00085282 * tf * h * h - 0.00000199 * tf * tf * h * h
    )
    return round((hi - 32.0) * 5.0 / 9.0, 1)


# ---------------------------------------------------------------------------
# per-disaster SAFETY STEPS ("what to do") — static, source-noted guidance
# condensed from DDM / Red Crescent (BDRCS) public preparedness material.
# Never a promise of safety; always ends with "call 999 in an emergency".
# ---------------------------------------------------------------------------

SAFETY_STEPS = {
    KIND_CYCLONE: {
        "source": "DDM / BDRCS / BMD",
        "bn": [
            "সরকারি সংকেত ও নির্দেশ মেনে চলুন; গুজবে কান দেবেন না।",
            "বিপদ/মহাবিপদ সংকেতে দ্রুত নিকটস্থ ঘূর্ণিঝড় আশ্রয়কেন্দ্রে যান।",
            "শুকনো খাবার, খাওয়ার পানি, ওষুধ ও জরুরি কাগজপত্র সঙ্গে নিন।",
            "গবাদিপশু ও মূল্যবান জিনিস নিরাপদ উঁচু স্থানে সরান।",
            "বিদ্যুৎ ও গ্যাসের মূল সংযোগ বন্ধ করে ঘর ছাড়ুন।",
            "জরুরি প্রয়োজনে ৯৯৯, আবহাওয়া তথ্যে ১০৯০-এ কল করুন।",
        ],
        "en": [
            "Follow official signals and instructions; ignore rumours.",
            "On a danger / great-danger signal, move quickly to the nearest cyclone shelter.",
            "Carry dry food, drinking water, medicines and important documents.",
            "Move livestock and valuables to safe, raised ground.",
            "Switch off the main power and gas before leaving home.",
            "Call 999 in an emergency; call 1090 for weather information.",
        ],
    },
    KIND_FLOOD: {
        "source": "DDM / FFWC / BDRCS",
        "bn": [
            "FFWC-এর পানির স্তর ও বিপৎসীমার তথ্য নিয়মিত দেখুন।",
            "প্রয়োজনীয় কাগজ, ওষুধ ও শুকনো খাবার পানিরোধী ব্যাগে উঁচুতে রাখুন।",
            "বন্যার পানিতে হাঁটা বা গাড়ি চালানো থেকে বিরত থাকুন।",
            "খাওয়ার পানি ফুটিয়ে বা বিশুদ্ধ করে পান করুন।",
            "বিদ্যুতের তার ও সকেট থেকে দূরে থাকুন।",
            "জরুরি প্রয়োজনে ৯৯৯, পূর্বাভাসে ১০৯০-এ কল করুন।",
        ],
        "en": [
            "Watch FFWC water levels against the danger level regularly.",
            "Keep documents, medicines and dry food in a waterproof bag, raised high.",
            "Do not walk or drive through flood water.",
            "Boil or purify drinking water.",
            "Stay away from electric wires and sockets.",
            "Call 999 in an emergency; call 1090 for the forecast.",
        ],
    },
    KIND_HEAT: {
        "source": "DGHS / BMD",
        "bn": [
            "দুপুর ১২টা–৩টা রোদে বাইরে যাওয়া এড়িয়ে চলুন।",
            "বারবার পানি ও খাবার স্যালাইন পান করুন; তৃষ্ণা না পেলেও।",
            "হালকা রঙের ঢিলা সুতির কাপড় পরুন, ছাতা/টুপি ব্যবহার করুন।",
            "শিশু, বৃদ্ধ ও অসুস্থদের ছায়া ও ঠান্ডা স্থানে রাখুন।",
            "মাথা ঘোরা/বমি/জ্ঞান হারানো হলে ছায়ায় নিয়ে ঠান্ডা করুন, ৯৯৯-এ কল করুন।",
        ],
        "en": [
            "Avoid going out in the sun between 12pm and 3pm.",
            "Drink water and oral saline often — even if you aren't thirsty.",
            "Wear light-coloured, loose cotton clothes; use an umbrella or cap.",
            "Keep children, the elderly and the unwell in shade and cool places.",
            "If someone faints or vomits, cool them in shade and call 999.",
        ],
    },
    KIND_EARTHQUAKE: {
        "source": "DDM / BDRCS",
        "bn": [
            "কাঁপুনি শুরু হলে: নিচু হোন, মজবুত টেবিলের নিচে আশ্রয় নিন, ধরে রাখুন।",
            "জানালা, কাচ ও ভারী আসবাব থেকে দূরে থাকুন; লিফট ব্যবহার করবেন না।",
            "কাঁপুনি থামলে শান্তভাবে খোলা জায়গায় বেরিয়ে যান।",
            "আফটারশকের জন্য প্রস্তুত থাকুন; ক্ষতিগ্রস্ত ভবনে ঢুকবেন না।",
            "গ্যাসের গন্ধ পেলে সংযোগ বন্ধ করুন; আটকা পড়লে শব্দ করে সাহায্য চান।",
            "জরুরি প্রয়োজনে ৯৯৯-এ কল করুন।",
        ],
        "en": [
            "When shaking starts: Drop, take cover under a sturdy table, and Hold on.",
            "Stay away from windows, glass and heavy furniture; never use a lift.",
            "When the shaking stops, leave calmly for open ground.",
            "Expect aftershocks; do not re-enter a damaged building.",
            "If you smell gas, turn it off; if trapped, make noise to signal for help.",
            "Call 999 in an emergency.",
        ],
    },
}


def safety_steps(kind, lang="bn"):
    """Source-noted 'what to do' steps for a disaster kind. Never a diagnosis
    or a promise of safety. Returns {'source', 'steps': [..]} or None."""
    spec = SAFETY_STEPS.get(kind)
    if not spec:
        return None
    return {"source": spec["source"], "steps": list(pick(lang, spec["bn"], spec["en"]))}


# ---------------------------------------------------------------------------
# preparedness checklist (before-the-event) — DDM / BDRCS "go-bag" guidance.
# ---------------------------------------------------------------------------

PREPAREDNESS = {
    "source": "DDM / BDRCS",
    "bn": [
        "জরুরি ব্যাগ: শুকনো খাবার, খাওয়ার পানি, খাবার স্যালাইন।",
        "টর্চলাইট, বাড়তি ব্যাটারি ও পাওয়ার ব্যাংক।",
        "প্রাথমিক চিকিৎসার বাক্স ও নিয়মিত ওষুধ।",
        "জরুরি কাগজপত্রের কপি পানিরোধী ব্যাগে (NID, দলিল)।",
        "কিছু নগদ টাকা ও জরুরি যোগাযোগ নম্বরের তালিকা।",
        "পরিবারের মিলনস্থল ও নিকটস্থ আশ্রয়কেন্দ্র আগেই ঠিক করে রাখুন।",
        "জরুরি নম্বর সংরক্ষণ: ৯৯৯ ও দুর্যোগ পূর্বাভাস ১০৯০।",
    ],
    "en": [
        "Go-bag: dry food, drinking water, oral saline.",
        "Torch, spare batteries and a power bank.",
        "First-aid kit and your regular medicines.",
        "Copies of key documents in a waterproof bag (NID, deeds).",
        "Some cash and a list of emergency contact numbers.",
        "Agree a family meeting point and nearest shelter in advance.",
        "Save the hotlines: 999 and disaster forecast 1090.",
    ],
}


def preparedness_checklist(lang="bn"):
    """Static, source-noted preparedness checklist (before any disaster)."""
    return {"source": PREPAREDNESS["source"],
            "items": list(pick(lang, PREPAREDNESS["bn"], PREPAREDNESS["en"]))}


# ---------------------------------------------------------------------------
# emergency contacts for the disaster screen (official hotlines only)
# ---------------------------------------------------------------------------

def emergency_contacts(lang="bn"):
    """The two official hotlines the disaster screen must always show:
    999 (national emergency) and 1090 (disaster / weather warning)."""
    return [
        {"key": "national", "number": HOTLINE_EMERGENCY, "primary": True,
         "source": "999 (NTMC)",
         "label": pick(lang, "জাতীয় জরুরি সেবা", "National Emergency"),
         "note": pick(lang, "পুলিশ • ফায়ার • অ্যাম্বুলেন্স (টোল-ফ্রি, ২৪/৭)",
                      "Police • Fire • Ambulance (toll-free, 24/7)")},
        {"key": "disaster", "number": HOTLINE_DISASTER, "primary": False,
         "source": "BMD / DDM",
         "label": pick(lang, "দুর্যোগ পূর্বাভাস", "Disaster Warning"),
         "note": pick(lang, "আবহাওয়া ও দুর্যোগ পূর্বাভাস (টোল-ফ্রি)",
                      "Weather & disaster forecast (toll-free)")},
    ]


# ---------------------------------------------------------------------------
# ACTIVE WARNINGS — classifier over an OFFICIAL feed. NEVER invents a warning.
# ---------------------------------------------------------------------------

def normalize_warning(raw):
    """Coerce one raw official-feed warning dict into a complete, classified
    item. The raw dict MUST originate from an official feed; this function only
    classifies / fills defaults and NEVER manufactures a warning on its own.

    Recognised input keys (all optional except `kind`):
        kind (cyclone|flood|heat|earthquake), area, title, text,
        signal (cyclone), above_danger_m (flood), temp_c / humidity_pct (heat),
        magnitude (earthquake), severity (override), source, issued_at.

    Returns the item with a derived `severity`, `severity_rank`, `is_live`
    (True — it came from the feed) and `sample` (False). Returns None if there
    is no `kind` (so callers can filter junk cheaply).
    """
    if not isinstance(raw, dict):
        return None
    kind = raw.get("kind")
    if kind not in KINDS:
        return None
    out = dict(raw)
    # derive severity from the kind-specific metric unless explicitly provided
    sev = raw.get("severity")
    if sev not in _SEV_RANK:
        if kind == KIND_CYCLONE:
            sev = cyclone_signal_severity(raw.get("signal"))
        elif kind == KIND_FLOOD:
            sev = flood_level_severity(raw.get("above_danger_m"))
        elif kind == KIND_HEAT:
            sev = heat_severity(raw.get("temp_c"))
        else:  # earthquake — magnitude bands (reference)
            sev = _quake_severity(raw.get("magnitude"))
    out["severity"] = sev
    out["severity_rank"] = severity_rank(sev)
    out["is_live"] = True
    out["sample"] = False
    out["source"] = raw.get("source") or _default_source(kind)
    return out


def _quake_severity(magnitude):
    try:
        m = float(magnitude)
    except (TypeError, ValueError):
        return SEV_INFO
    if m < 4.0:
        return SEV_INFO
    if m < 5.0:
        return SEV_ADVISORY
    if m < 6.0:
        return SEV_WARNING
    if m < 7.0:
        return SEV_SEVERE
    return SEV_EXTREME


def _default_source(kind):
    return {
        KIND_CYCLONE: "BMD", KIND_HEAT: "BMD",
        KIND_FLOOD: "FFWC", KIND_EARTHQUAKE: "DDM",
    }.get(kind, "BMD")


def active_warnings(feed_items):
    """Classify + sort the warnings coming FROM an official feed.
    `feed_items` is whatever the integrator fetched from the official source;
    with no feed (None / []) this returns [] — the UI then shows the honest
    'connect official feed' state. It NEVER returns a fabricated warning.
    Sorted most-severe first."""
    out = []
    for raw in (feed_items or []):
        item = normalize_warning(raw)
        if item is not None:
            out.append(item)
    out.sort(key=lambda w: w["severity_rank"], reverse=True)
    return out


def feed_state(has_feed_key, feed_items):
    """What state the live-warnings panel is in (honest, key-gated).

    Returns one of:
      'no_key'   — no official-feed key connected -> show 'connect feed' + sample.
      'empty'    — feed connected but reports no active warnings (good news).
      'active'   — feed connected and there are active warnings.
    The live feed is always key-gated so the app never fabricates an alert."""
    if not has_feed_key:
        return "no_key"
    if active_warnings(feed_items):
        return "active"
    return "empty"


# ---------------------------------------------------------------------------
# curated SAMPLE warnings — clearly flagged, NEVER mistaken for a live alert.
# These exist only so the 'no official feed connected' state can show the user
# what a real warning WILL look like. Every item carries is_live=False,
# sample=True and a source note; the UI must badge them "example".
# ---------------------------------------------------------------------------

def sample_warnings(lang="bn"):
    """Illustrative (non-live) examples for the 'connect the feed' state.
    EVERY item is sample=True / is_live=False and MUST be labelled 'example'
    by the UI. These are NOT active warnings and must never be presented as
    such."""
    raw = [
        {"kind": KIND_CYCLONE, "signal": 7,
         "area": pick(lang, "উপকূলীয় জেলাসমূহ", "Coastal districts"),
         "title": pick(lang, "বিপদ সংকেত নং ৭ (উদাহরণ)",
                       "Danger signal No. 7 (example)"),
         "text": pick(lang,
                      "এটি একটি নমুনা — প্রকৃত সংকেতের জন্য BMD/১০৯০ দেখুন।",
                      "This is a sample — check BMD / 1090 for real signals."),
         "source": "BMD (sample)"},
        {"kind": KIND_FLOOD, "above_danger_m": 0.6,
         "area": pick(lang, "উত্তরাঞ্চলের নদী অববাহিকা", "Northern river basins"),
         "title": pick(lang, "বিপৎসীমার ০.৬ মি উপরে (উদাহরণ)",
                       "0.6 m above danger level (example)"),
         "text": pick(lang,
                      "এটি একটি নমুনা — প্রকৃত তথ্যের জন্য FFWC দেখুন।",
                      "This is a sample — check FFWC for real levels."),
         "source": "FFWC (sample)"},
        {"kind": KIND_HEAT, "temp_c": 40.5,
         "area": pick(lang, "ঢাকা ও পশ্চিমাঞ্চল", "Dhaka & western regions"),
         "title": pick(lang, "তীব্র তাপপ্রবাহ ~৪০.৫°সে (উদাহরণ)",
                       "Severe heatwave ~40.5°C (example)"),
         "text": pick(lang,
                      "এটি একটি নমুনা — প্রকৃত পূর্বাভাসের জন্য BMD দেখুন।",
                      "This is a sample — check BMD for the real forecast."),
         "source": "BMD (sample)"},
    ]
    out = []
    for r in raw:
        item = normalize_warning(r)
        if item is not None:
            item["is_live"] = False
            item["sample"] = True
            out.append(item)
    out.sort(key=lambda w: w["severity_rank"], reverse=True)
    return out


# ---------------------------------------------------------------------------
# FAMILY-LOCATION-AWARE — "are any of my family inside an affected area?"
# REUSES the circle / safe-journey model: each member carries an `area` label
# (and optional lat/lng). This matches them against the active warnings' areas.
# No new audience — the matched members are exactly circle members.
# ---------------------------------------------------------------------------

def _norm(s):
    return (s or "").strip().lower()


def area_matches(member_area, warning_area):
    """True if a family member's area label falls inside a warning's area.
    Case-insensitive substring match either way (a warning 'Coastal districts'
    matches a member whose area contains 'coastal'; a member 'Barishal' matches
    a warning mentioning 'Barishal'). Empty on either side -> no match."""
    m, w = _norm(member_area), _norm(warning_area)
    if not m or not w:
        return False
    return m in w or w in m


def affected_family(members, warnings):
    """Given circle members [{name, area, (lat,lng)…}] and classified active
    `warnings`, return the members who fall inside an affected area, each paired
    with the most-severe matching warning. REUSES the circle member list — it
    introduces no new contacts. Sorted most-severe first.

    Returns [{member, warning, severity, severity_rank}, …]."""
    out = []
    for mem in (members or []):
        if not isinstance(mem, dict):
            continue
        best = None
        for w in (warnings or []):
            if area_matches(mem.get("area"), w.get("area")):
                if best is None or w.get("severity_rank", 0) > best.get("severity_rank", 0):
                    best = w
        if best is not None:
            out.append({
                "member": mem,
                "warning": best,
                "severity": best.get("severity"),
                "severity_rank": best.get("severity_rank", 0),
            })
    out.sort(key=lambda x: x["severity_rank"], reverse=True)
    return out


# ---------------------------------------------------------------------------
# share text — a plain, shareable warning summary (reuses the warning dict).
# For SAMPLE items it explicitly says "example (not a live warning)".
# ---------------------------------------------------------------------------

def warning_share_text(warning, lang="bn"):
    """Render a warning as a compact shareable text block. Honest about sample
    vs live, and always carries the hotlines."""
    warning = warning or {}
    title = warning.get("title") or ""
    area = warning.get("area") or ""
    src = warning.get("source") or ""
    lines = [pick(lang, "দুর্যোগ সতর্কতা", "DISASTER ALERT")]
    if warning.get("sample") or not warning.get("is_live", False):
        lines[0] += pick(lang, " (উদাহরণ — সরাসরি সতর্কতা নয়)",
                         " (example — not a live warning)")
    if title:
        lines.append(title)
    if area:
        lines.append(pick(lang, f"এলাকা: {area}", f"Area: {area}"))
    if src:
        lines.append(pick(lang, f"সূত্র: {src}", f"Source: {src}"))
    lines.append(pick(lang,
                      f"জরুরি: {HOTLINE_EMERGENCY} • পূর্বাভাস: {HOTLINE_DISASTER}",
                      f"Emergency: {HOTLINE_EMERGENCY} • Forecast: {HOTLINE_DISASTER}"))
    return "\n".join(lines)
