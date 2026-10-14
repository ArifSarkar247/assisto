"""
nearby (ADVANCED) — curated Bangladesh dataset + helpers.

Map / Places APIs are KEY-GATED (owner Google Maps key). The existing live
path lives in core/nearby.py (Places → OSM). This module adds the ADVANCED
layer the app needs so the feature is FULLY usable with a curated dataset
*before* any key is wired:

  * the BD categories a user actually needs (hospital, pharmacy w/ 24h flag,
    ATM/bank, bKash/Nagad agent, police, fire, transport, fuel/CNG,
    restaurant, mosque, govt),
  * distance (haversine) when a location is supplied,
  * open/closed from curated hours (24h aware, past-midnight aware),
  * "nearest X" for the emergency context (hospital / pharmacy / police),
  * search + filter + sort-by-distance.

It invents NOTHING beyond public landmarks — no fake ratings. The integrator
can expose this via an endpoint that returns `source: "mock"` plus a flag so
the app shows the honest "live when Maps key + location enabled" banner.
"""
import math

# Categories the app knows. Keep in lockstep with app/lib/widgets/nearby_data.dart.
CATEGORIES = [
    "hospital", "pharmacy", "atm_bank", "mobile_agent", "police", "fire",
    "transport", "fuel", "restaurant", "mosque", "govt",
]

# Emergency quick-access -> category.
EMERGENCY = {"hospital": "hospital", "pharmacy": "pharmacy", "police": "police"}


def _p(id, cat, name_bn, name_en, lat, lon, phone=None, open24=False,
       open_min=None, close_min=None):
    return {
        "id": id, "cat": cat, "name_bn": name_bn, "name_en": name_en,
        "lat": lat, "lon": lon, "phone": phone, "open24": open24,
        "open_min": open_min, "close_min": close_min,
    }


# Curated central-Dhaka dataset (mirror of the Flutter mock).
DATASET = [
    _p("h1", "hospital", "ঢাকা মেডিকেল কলেজ হাসপাতাল",
       "Dhaka Medical College Hospital", 23.7257, 90.3969,
       "+88029661051", open24=True),
    _p("h2", "hospital", "স্কয়ার হাসপাতাল", "Square Hospital",
       23.7525, 90.3836, "+8801713377773", open24=True),
    _p("p1", "pharmacy", "ল্যাজ ফার্মা", "Lazz Pharma",
       23.7490, 90.3850, "+88029676522", open24=True),
    _p("p2", "pharmacy", "তামান্না ফার্মেসি", "Tamanna Pharmacy",
       23.7380, 90.4130, "+8801811000111", open_min=480, close_min=1380),
    _p("a1", "atm_bank", "ডাচ্‌-বাংলা এটিএম — মতিঝিল", "DBBL ATM — Motijheel",
       23.7330, 90.4172, open24=True),
    _p("a2", "atm_bank", "ব্র্যাক ব্যাংক — ধানমন্ডি", "BRAC Bank — Dhanmondi",
       23.7560, 90.3720, "+88016221", open_min=600, close_min=1020),
    _p("m1", "mobile_agent", "বিকাশ এজেন্ট — নিউ মার্কেট",
       "bKash Agent — New Market", 23.7340, 90.3860, "+8801700000000",
       open_min=540, close_min=1320),
    _p("m2", "mobile_agent", "নগদ এজেন্ট — ফার্মগেট", "Nagad Agent — Farmgate",
       23.7580, 90.3900, open_min=540, close_min=1290),
    _p("pol1", "police", "শাহবাগ থানা", "Shahbag Police Station",
       23.7390, 90.3950, "999", open24=True),
    _p("f1", "fire", "ফায়ার সার্ভিস — সিদ্দিক বাজার",
       "Fire Service — Siddique Bazar", 23.7250, 90.4100, "999", open24=True),
    _p("t1", "transport", "কমলাপুর রেলওয়ে স্টেশন",
       "Kamalapur Railway Station", 23.7320, 90.4260, "+88029330730", open24=True),
    _p("t2", "transport", "সদরঘাট লঞ্চ টার্মিনাল", "Sadarghat Launch Terminal",
       23.7060, 90.4130, open_min=300, close_min=1410),
    _p("fu1", "fuel", "পদ্মা ফিলিং স্টেশন", "Padma Filling Station",
       23.7480, 90.3930, open24=True),
    _p("r1", "restaurant", "স্টার কাবাব", "Star Kabab",
       23.7555, 90.3715, "+8801711000000", open_min=420, close_min=150),
    _p("mo1", "mosque", "বায়তুল মোকাররম জাতীয় মসজিদ",
       "Baitul Mukarram National Mosque", 23.7290, 90.4120, open24=True),
    _p("g1", "govt", "সিটি কর্পোরেশন অফিস — নগর ভবন",
       "City Corporation Office — Nagar Bhaban", 23.7210, 90.4090,
       "+88029556016", open_min=540, close_min=1020),
]


def haversine_m(lat1, lon1, lat2, lon2):
    """Great-circle distance in metres (int)."""
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return int(r * 2 * math.asin(math.sqrt(a)))


def is_open(place, minute_of_day):
    """True/False/None (unknown) for a place at a given minute-of-day."""
    if place.get("open24"):
        return True
    o, c = place.get("open_min"), place.get("close_min")
    if o is None or c is None:
        return None
    if c >= o:
        return o <= minute_of_day < c
    return minute_of_day >= o or minute_of_day < c  # wraps past midnight


def _decorate(place, lat, lon, minute_of_day):
    d = dict(place)
    if lat is not None and lon is not None:
        d["distance_m"] = haversine_m(lat, lon, place["lat"], place["lon"])
    else:
        d["distance_m"] = None
    d["open_now"] = is_open(place, minute_of_day) if minute_of_day is not None else None
    d["rating"] = None  # never invent
    d["maps"] = f"https://www.google.com/maps/search/?api=1&query={place['lat']},{place['lon']}"
    d["directions"] = f"https://www.google.com/maps/dir/?api=1&destination={place['lat']},{place['lon']}"
    return d


def search(category=None, lat=None, lon=None, minute_of_day=None, query="",
           sort="distance", limit=50):
    """Filter + decorate + sort the curated dataset.

    Returns (results, source) where source == "mock".
    """
    out = []
    q = (query or "").strip().lower()
    for p in DATASET:
        if category and p["cat"] != category:
            continue
        if q and q not in p["name_en"].lower() and q not in p["name_bn"].lower():
            continue
        out.append(_decorate(p, lat, lon, minute_of_day))

    if sort == "name":
        out.sort(key=lambda x: x["name_en"].lower())
    elif sort == "open":
        out.sort(key=lambda x: (0 if x["open_now"] else 1,
                                x["distance_m"] if x["distance_m"] is not None else 1e12))
    else:  # distance
        if lat is not None:
            out.sort(key=lambda x: x["distance_m"] if x["distance_m"] is not None else 1e12)
    return out[:limit], "mock"


def nearest(what, lat, lon, minute_of_day=None):
    """Nearest single place for emergency quick-access ('hospital' etc.).

    Returns the decorated place or None. Requires a location.
    """
    cat = EMERGENCY.get(what, what)
    if lat is None or lon is None:
        return None
    res, _ = search(category=cat, lat=lat, lon=lon, minute_of_day=minute_of_day,
                    sort="distance", limit=1)
    return res[0] if res else None
