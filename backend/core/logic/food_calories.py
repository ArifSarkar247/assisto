"""
food_calories.py — the PURE brain of "food photo -> calories" (p2food).

No Django, no DB, no network, no clock.

  * TABLE — cited nutrition values per 100 g, GENERATED from the original
    source files by backend/core/food_table_gen.py (food_table_data.py). Two sources:
      fct  = Food Composition Table for Bangladesh 2013 (INFS, University of
             Dhaka, with FAO) — the primary source;
      usda = USDA FoodData Central, FNDDS (public domain) — only for cooked
             dishes the FCT does not have (biryani, curries, paratha ...).
    Dishes with NO cited value (fuchka, pitha, rosogolla ...) carry
    kcal=None and are NEVER given a number; the user may type their own.
  * The vision model only names dish IDS from this table — it never supplies a
    number (parse_dishes drops anything else).
  * Log math (day totals, 7-day series, goal) mirrored by the app.
  * Diabetes-friendly hints are GENERAL information with a named source —
    never a medicine, insulin or dose.
"""
import json
import re

from .food_table_data import ROWS

SOURCES = {
    "fct": {
        "short": {"bn": "FCT বাংলাদেশ ২০১৩", "en": "FCT Bangladesh 2013"},
        "cite": ("Shaheen N, Rahim ATMA, Mohiduzzaman M, et al. Food Composition "
                 "Table for Bangladesh. INFS, University of Dhaka, 2013 (with FAO). "
                 "ISBN 978-984-33-7522-3."),
        "url": "https://www.fao.org/fileadmin/templates/food_composition/documents/FCDB_7_4_14.xlsx",
        "carb": "available",
    },
    "usda": {
        "short": {"bn": "USDA FNDDS", "en": "USDA FNDDS"},
        "cite": ("U.S. Department of Agriculture, Agricultural Research Service. "
                 "FoodData Central — Food and Nutrient Database for Dietary Studies "
                 "(survey foods, release 2024-10-31). Public domain."),
        "url": "https://fdc.nal.usda.gov/",
        "carb": "by_difference",
    },
}

NOTES = {
    "foreign": {
        "bn": "দেশি রান্নার মান নেই — বিদেশি রেসিপির মান। তেল বেশি হলে ক্যালরি বেশি।",
        "en": "No Bangladeshi value — this is a foreign recipe. More oil means more calories.",
    },
    "near_match": {
        "bn": "এই খাবারের নিজস্ব মান নেই — সবচেয়ে কাছের খাবারের মান দেখানো হচ্ছে।",
        "en": "No value for this exact dish — the closest dish's value is shown.",
    },
    "add_oil": {
        "bn": "তেল ছাড়া মান — সরিষার তেল দিলে 'রান্নার তেল' আলাদা যোগ করুন।",
        "en": "Value without oil — add 'cooking oil' separately if mustard oil was used.",
    },
    "none": {
        "bn": "সূত্রসহ মান পাওয়া যায়নি — আমরা সংখ্যা বানাই না। চাইলে নিজে ক্যালরি লিখুন।",
        "en": "No cited value found — we never make up a number. You can type the calories yourself.",
    },
}

DISCLAIMER = {
    "bn": "এটি আনুমানিক হিসাব, চিকিৎসা-পরামর্শ নয়। ডায়েট বদলানোর আগে ডাক্তার বা পুষ্টিবিদের সাথে কথা বলুন।",
    "en": "This is an estimate, not medical advice. Talk to a doctor or dietitian before changing your diet.",
}

# General information only (named public sources) — never a medicine or dose.
HINTS = [
    {"bn": "প্লেটের অর্ধেক সবজি, এক-চতুর্থাংশ মাছ/মাংস/ডাল, এক-চতুর্থাংশ ভাত-রুটি।",
     "en": "Fill half the plate with vegetables, a quarter with fish/meat/dal, a quarter with rice or ruti.",
     "src": "American Diabetes Association — Diabetes Plate Method"},
    {"bn": "চিনি ও মিষ্টি পানীয় কমান — দিনের মোট ক্যালরির ১০%-এর কম চিনি থেকে।",
     "en": "Cut sugar and sweet drinks — keep free sugars under 10% of daily energy.",
     "src": "WHO Guideline: Sugars intake for adults and children (2015)"},
    {"bn": "সাদা ভাতের বদলে মাঝে মাঝে লাল চালের ভাত বা আটার রুটি নিন — আঁশ বেশি।",
     "en": "Sometimes swap white rice for brown rice or whole-wheat ruti — more fibre.",
     "src": "WHO Healthy diet fact sheet"},
    {"bn": "ডায়াবেটিস থাকলে খাবারের পরিকল্পনা ডাক্তার বা পুষ্টিবিদের সাথে ঠিক করুন।",
     "en": "If you have diabetes, plan meals with your doctor or dietitian.",
     "src": "General advice"},
]

GOAL_MIN, GOAL_MAX, GOAL_DEFAULT = 800, 5000, 2000
MAX_GRAMS = 3000
MAX_SELF_KCAL = 5000
NUTRIENTS = ("kcal", "protein", "fat", "carb", "fibre")

_BY_ID = {r["id"]: r for r in ROWS}
DISH_IDS = tuple(r["id"] for r in ROWS)


def _lang(lang):
    return "en" if lang == "en" else "bn"


def dish(dish_id):
    return _BY_ID.get(str(dish_id or ""))


def has_value(row):
    return bool(row) and row["per100"].get("kcal") is not None


def source_label(row, lang="bn"):
    """'FCT Bangladesh 2013 · 01_0041' — shown next to every number."""
    if not has_value(row):
        return ""
    s = SOURCES[row["src"]]["short"][_lang(lang)]
    return "%s · %s" % (s, row["code"])


def client_row(row, lang="bn"):
    lg = _lang(lang)
    note = row["note"] or ("none" if not has_value(row) else "")
    return {
        "id": row["id"], "group": row["group"], "name": row[lg],
        "name_bn": row["bn"], "name_en": row["en"], "syn": row["syn"],
        "has_value": has_value(row), "per100": dict(row["per100"]),
        "src": row["src"] if has_value(row) else "", "code": row["code"],
        "src_name": row["src_name"], "source": source_label(row, lg),
        "note": NOTES[note][lg] if note else "",
        "portions": [{"id": p["id"], "label": p[lg], "g": p["g"],
                      "approx": p["basis"] == "home"} for p in row["portions"]],
    }


def table(lang="bn"):
    lg = _lang(lang)
    return {
        "dishes": [client_row(r, lg) for r in ROWS],
        "sources": {k: {"short": v["short"][lg], "cite": v["cite"], "url": v["url"],
                        "carb": v["carb"]} for k, v in SOURCES.items()},
        "disclaimer": DISCLAIMER[lg],
        "hints": [{"text": h[lg], "src": h["src"]} for h in HINTS],
        "goal": {"min": GOAL_MIN, "max": GOAL_MAX, "default": GOAL_DEFAULT},
    }


def nutrients(dish_id, grams):
    """Cited nutrients for `grams` of a dish, or None (no cited value / bad
    input). Never invents: a dish without a value returns None."""
    row = dish(dish_id)
    if not has_value(row):
        return None
    try:
        g = float(grams)
    except (TypeError, ValueError):
        return None
    if not (0 < g <= MAX_GRAMS):
        return None
    out = {}
    for k in NUTRIENTS:
        v = row["per100"].get(k)
        out[k] = None if v is None else round(v * g / 100.0, 1)
    out["kcal"] = int(round(row["per100"]["kcal"] * g / 100.0))
    return out


def entry_kcal(e):
    """kcal of one logged entry: the cited value, or the user's own number
    (self=True). None = unknown (not counted, reported separately)."""
    if not isinstance(e, dict):
        return None
    v = e.get("kcal")
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if v < 0 or v > MAX_SELF_KCAL * 2:
        return None
    return float(v)


def day_totals(entries, date):
    tot = {k: 0.0 for k in NUTRIENTS}
    count = unknown = 0
    for e in entries or []:
        if not isinstance(e, dict) or str(e.get("date") or "") != date:
            continue
        count += 1
        k = entry_kcal(e)
        if k is None:
            unknown += 1
            continue
        tot["kcal"] += k
        for n in ("protein", "fat", "carb", "fibre"):
            v = e.get(n)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                tot[n] += float(v)
    out = {k: round(v, 1) for k, v in tot.items()}
    out["kcal"] = int(round(tot["kcal"]))
    out.update({"date": date, "count": count, "unknown": unknown})
    return out


def week(entries, dates):
    """dates: the 7 'YYYY-MM-DD' strings oldest -> today (the caller owns the
    clock). Returns [{date, kcal, count, unknown}]."""
    return [{k: d[k] for k in ("date", "kcal", "count", "unknown")}
            for d in (day_totals(entries, x) for x in dates)]


def clean_goal(raw):
    try:
        v = int(float(raw))
    except (TypeError, ValueError):
        return None
    return v if GOAL_MIN <= v <= GOAL_MAX else None


def goal_state(eaten_kcal, goal):
    g = clean_goal(goal) or GOAL_DEFAULT
    left = g - int(eaten_kcal or 0)
    return {"goal": g, "eaten": int(eaten_kcal or 0), "left": max(0, left),
            "over": max(0, -left), "ratio": round(min(1.0, max(0.0, (eaten_kcal or 0) / g)), 3)}


# ------------------------------------------------------------------ vision
def vision_prompt():
    """Extra system text for chat_vision purpose 'food': the model names dish
    IDS from our table only — never a calorie number."""
    ids = ", ".join("%s (%s)" % (r["id"], r["en"]) for r in ROWS)
    return (
        "Purpose: the photo shows a meal. Identify each food you can see, but "
        "ONLY by choosing ids from this list of Bangladeshi foods: " + ids + ". "
        "Add to the JSON a field \"dishes\": [{\"id\": \"<id from the list>\", "
        "\"confidence\": \"high|medium|low\"}] (max 6, most visible first). If a "
        "food is not on the list, do not invent an id — mention it in the answer "
        "text instead. Do NOT give calorie, nutrient or portion numbers: the app "
        "takes them from a cited nutrition table. In the answer, name the foods "
        "simply and say the user should confirm them. Do not give medical or "
        "diet advice. Use kind \"food\".")


_CONF = ("high", "medium", "low")


def parse_dishes(raw):
    """Provider text -> [{'id', 'confidence'}] keeping ONLY known ids (dedup,
    max 6). Any number the model might add is ignored."""
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", (raw or "").strip())
    m = re.search(r"\{.*\}", t, re.S)
    if not m:
        return []
    try:
        j = json.loads(m.group(0))
    except (ValueError, TypeError):
        return []
    items = j.get("dishes") if isinstance(j, dict) else None
    out, seen = [], set()
    for it in items if isinstance(items, list) else []:
        did = it.get("id") if isinstance(it, dict) else it
        did = str(did or "").strip().lower()
        if did in _BY_ID and did not in seen:
            seen.add(did)
            c = str(it.get("confidence") or "").lower() if isinstance(it, dict) else ""
            out.append({"id": did, "confidence": c if c in _CONF else "low"})
        if len(out) >= 6:
            break
    return out
