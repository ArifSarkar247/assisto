"""
Unseen World — ADVANCED travel companion (launch gap F / Appendix #41).

Surfaces lesser-known Bangladesh destinations (hidden gems) by DIVISION and
CATEGORY, with the facts a card needs: best time, how to get there, an
APPROXIMATE cost range, nearby spots and a practical tip.

Source policy (HONEST): content is sourced from the OWNER's own
unseenbangladesh.com plus open data (Wikivoyage / Wikipedia / Bangladesh
Tourism Board). Every destination carries a `source` so the app can attribute
it, and cost ranges are STABLE, widely-published APPROXIMATIONS tagged
`cost_approx: True` — they are NOT live prices and are never invented. We never
fabricate places, facts or exact prices; anything the app can't verify (live
prices, current road conditions) is left to the caller, not guessed.

Pure data + filtering/search/seasonal/trip logic — no Django, no network. A
later integrator step can pull live articles from unseenbangladesh.com (owner
key / feed); the shapes below map 1:1 onto that source. The app ships the same
curated dataset so the UX works fully offline; this module is the bilingual
mirror for the `/unseen` endpoint (and the live swap later).
"""
from .i18n import pick

SOURCE_SITE = "unseenbangladesh.com"
SOURCE_OPEN = "Wikivoyage / open data"

# The eight administrative divisions (ids match the app's Division enum names).
DIVISIONS = [
    ("dhaka", "ঢাকা", "Dhaka"),
    ("chattogram", "চট্টগ্রাম", "Chattogram"),
    ("sylhet", "সিলেট", "Sylhet"),
    ("khulna", "খুলনা", "Khulna"),
    ("rajshahi", "রাজশাহী", "Rajshahi"),
    ("barishal", "বরিশাল", "Barishal"),
    ("rangpur", "রংপুর", "Rangpur"),
    ("mymensingh", "ময়মনসিংহ", "Mymensingh"),
]

# Category ids match the app's TravelCat enum names.
CATEGORIES = [
    ("nature", "প্রকৃতি", "Nature"),
    ("historical", "ঐতিহাসিক", "Historical"),
    ("beach", "সমুদ্র সৈকত", "Beach"),
    ("hill", "পাহাড়", "Hill"),
    ("religious", "ধর্মীয়", "Religious"),
    ("island", "দ্বীপ", "Island"),
    ("waterfall", "জলপ্রপাত", "Waterfall"),
]

# Honest, bilingual seed — mirrors app/lib/widgets/unseen_data.dart. Facts kept
# to stable, widely-published basics. `cost_low`/`cost_high` are APPROXIMATE
# per-person round-trip-from-Dhaka BDT estimates (budget travel), always flagged
# cost_approx. No invented ratings or live prices. `months` drives seasonal.
_SEED = [
    {
        "slug": "nijhum-dwip", "division": "chattogram", "type": "island",
        "name_bn": "নিঝুম দ্বীপ", "name_en": "Nijhum Dwip",
        "lat": 22.0167, "lon": 91.0167, "months": [11, 12, 1, 2],
        "best_bn": "নভেম্বর–ফেব্রুয়ারি", "best_en": "Nov-Feb",
        "how_bn": "ঢাকা থেকে নোয়াখালী, এরপর হাতিয়া হয়ে নৌকায় নিঝুম দ্বীপ।",
        "how_en": "Dhaka to Noakhali, then boat via Hatiya to Nijhum Dwip.",
        "cost_low": 4000, "cost_high": 7000,
        "nearby_bn": ["হাতিয়া", "নামার বাজার সৈকত"], "nearby_en": ["Hatiya", "Namar Bazar beach"],
        "tip_bn": "চিত্রল হরিণ ও ম্যানগ্রোভের জন্য ভোরে যান; জোয়ার-ভাটা দেখে নিন।",
        "tip_en": "Go at dawn for spotted deer and mangroves; check tide times.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "jaflong", "division": "sylhet", "type": "nature",
        "name_bn": "জাফলং", "name_en": "Jaflong",
        "lat": 25.1667, "lon": 92.0167, "months": [7, 8, 9, 10],
        "best_bn": "জুলাই–অক্টোবর", "best_en": "Jul-Oct",
        "how_bn": "ঢাকা থেকে বাস/ট্রেনে সিলেট, এরপর সিএনজি/গাড়িতে জাফলং।",
        "how_en": "Dhaka to Sylhet by bus/train, then local CNG/car to Jaflong.",
        "cost_low": 2500, "cost_high": 5000,
        "nearby_bn": ["লালাখাল", "শ্রীমঙ্গল চা-বাগান"], "nearby_en": ["Lalakhal", "Sremangal tea gardens"],
        "tip_bn": "বর্ষার পরে পাথুরে নদী ও মেঘালয়ের পাহাড় সবচেয়ে সুন্দর।",
        "tip_en": "After the monsoon the stone river and Meghalaya hills look best.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "ratargul", "division": "sylhet", "type": "nature",
        "name_bn": "রাতারগুল জলাবন", "name_en": "Ratargul Swamp Forest",
        "lat": 25.0030, "lon": 91.9730, "months": [6, 7, 8, 9],
        "best_bn": "জুন–সেপ্টেম্বর", "best_en": "Jun-Sep",
        "how_bn": "সিলেট শহর থেকে সিএনজি/গাড়িতে গোয়াইনঘাট, এরপর নৌকা।",
        "how_en": "From Sylhet city, CNG/car to Gowainghat, then country boat.",
        "cost_low": 2500, "cost_high": 4500,
        "nearby_bn": ["বিছনাকান্দি", "জাফলং"], "nearby_en": ["Bisnakandi", "Jaflong"],
        "tip_bn": "বর্ষায় নৌকায় ঘুরুন; গাছের ডাল ভাঙবেন না।",
        "tip_en": "Tour by boat in the wet season; do not break the branches.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "nafakhum", "division": "chattogram", "type": "waterfall",
        "name_bn": "নাফাখুম জলপ্রপাত", "name_en": "Nafakhum Waterfall",
        "lat": 21.7500, "lon": 92.5330, "months": [10, 11, 12],
        "best_bn": "অক্টোবর–ডিসেম্বর", "best_en": "Oct-Dec",
        "how_bn": "বান্দরবান থেকে থানচি, নৌকায় রেমাক্রি, এরপর গাইডসহ ট্রেক।",
        "how_en": "Bandarban to Thanchi, boat to Remakri, then a guided trek.",
        "cost_low": 5000, "cost_high": 9000,
        "nearby_bn": ["রেমাক্রি", "আমিয়াখুম"], "nearby_en": ["Remakri", "Amiakhum"],
        "tip_bn": "রেমাক্রি থেকে নৌকা ও ট্রেক দরকার; স্থানীয় গাইড নিন।",
        "tip_en": "Needs a boat from Remakri and a trek; hire a local guide.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "sajek", "division": "chattogram", "type": "hill",
        "name_bn": "সাজেক ভ্যালি", "name_en": "Sajek Valley",
        "lat": 23.3820, "lon": 92.2920, "months": [9, 10, 11, 12, 1, 2, 3],
        "best_bn": "সেপ্টেম্বর–মার্চ", "best_en": "Sep-Mar",
        "how_bn": "খাগড়াছড়ি থেকে চান্দের গাড়িতে কনভয়ে সাজেক।",
        "how_en": "Khagrachari, then Chander Gari (jeep) convoy up to Sajek.",
        "cost_low": 4000, "cost_high": 7000,
        "nearby_bn": ["কংলাক পাহাড়", "হাজাছড়া ঝর্ণা"], "nearby_en": ["Konglak hill", "Hajachara waterfall"],
        "tip_bn": "ভোরের মেঘ দেখতে আগের রাতেই পৌঁছান; পানি সঙ্গে রাখুন।",
        "tip_en": "Arrive the night before for the morning clouds; carry water.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "kuakata", "division": "barishal", "type": "beach",
        "name_bn": "কুয়াকাটা", "name_en": "Kuakata",
        "lat": 21.8170, "lon": 90.1200, "months": [11, 12, 1, 2, 3],
        "best_bn": "নভেম্বর–মার্চ", "best_en": "Nov-Mar",
        "how_bn": "ঢাকা থেকে বাসে পটুয়াখালী/কুয়াকাটা; লঞ্চও যায়।",
        "how_en": "Dhaka to Patuakhali/Kuakata by bus; launch is an option too.",
        "cost_low": 3000, "cost_high": 6000,
        "nearby_bn": ["ফাতরার চর", "গঙ্গামতি বন"], "nearby_en": ["Fatrar Char", "Gangamati forest"],
        "tip_bn": "একই সৈকত থেকে সূর্যোদয় ও সূর্যাস্ত—দুটোই দেখা যায়।",
        "tip_en": "See both sunrise and sunset from the same beach.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "paharpur", "division": "rajshahi", "type": "historical",
        "name_bn": "পাহাড়পুর (সোমপুর মহাবিহার)", "name_en": "Paharpur (Somapura Mahavihara)",
        "lat": 25.0310, "lon": 88.9770, "months": [11, 12, 1, 2],
        "best_bn": "নভেম্বর–ফেব্রুয়ারি", "best_en": "Nov-Feb",
        "how_bn": "ঢাকা থেকে নওগাঁ/জয়পুরহাট, এরপর স্থানীয় গাড়িতে পাহাড়পুর।",
        "how_en": "Dhaka to Naogaon/Jaypurhat, then local transport to Paharpur.",
        "cost_low": 2500, "cost_high": 5000,
        "nearby_bn": ["মহাস্থানগড়", "কুসুম্বা মসজিদ"], "nearby_en": ["Mahasthangarh", "Kusumba Mosque"],
        "tip_bn": "ইউনেস্কো সাইট; সকালে যান ও নির্ধারিত পথে হাঁটুন।",
        "tip_en": "UNESCO site; go in the cool morning and keep to marked paths.",
        "source": SOURCE_OPEN,
    },
    {
        "slug": "mahasthangarh", "division": "rajshahi", "type": "historical",
        "name_bn": "মহাস্থানগড়", "name_en": "Mahasthangarh",
        "lat": 24.9670, "lon": 89.3420, "months": [11, 12, 1, 2],
        "best_bn": "নভেম্বর–ফেব্রুয়ারি", "best_en": "Nov-Feb",
        "how_bn": "ঢাকা থেকে বাসে বগুড়া, এরপর স্থানীয় গাড়িতে উত্তরে।",
        "how_en": "Dhaka to Bogura by bus, then local transport north.",
        "cost_low": 2000, "cost_high": 4000,
        "nearby_bn": ["পাহাড়পুর", "বগুড়া শহর"], "nearby_en": ["Paharpur", "Bogura town"],
        "tip_bn": "অঞ্চলের প্রাচীনতম নগর-কেন্দ্রের একটি; জাদুঘর দেখুন।",
        "tip_en": "One of the oldest urban sites in the region; visit the museum.",
        "source": SOURCE_OPEN,
    },
    {
        "slug": "srimangal", "division": "sylhet", "type": "nature",
        "name_bn": "শ্রীমঙ্গল", "name_en": "Srimangal",
        "lat": 24.3060, "lon": 91.7300, "months": [10, 11, 12, 1, 2],
        "best_bn": "অক্টোবর–ফেব্রুয়ারি", "best_en": "Oct-Feb",
        "how_bn": "ঢাকা থেকে ট্রেন বা বাসে শ্রীমঙ্গল (চায়ের রাজধানী লাইন)।",
        "how_en": "Dhaka to Srimangal by train or bus (tea-capital line).",
        "cost_low": 2500, "cost_high": 5000,
        "nearby_bn": ["লাউয়াছড়া বন", "মাধবপুর লেক"], "nearby_en": ["Lawachara forest", "Madhabpur lake"],
        "tip_bn": "সাত রঙের চা চেখে দেখুন; পাখির জন্য বনে সকালে যান।",
        "tip_en": "Try seven-layer tea; the forest is best early for birds.",
        "source": SOURCE_SITE,
    },
    {
        "slug": "sundarbans", "division": "khulna", "type": "nature",
        "name_bn": "সুন্দরবন", "name_en": "Sundarbans",
        "lat": 21.9497, "lon": 89.1833, "months": [11, 12, 1, 2],
        "best_bn": "নভেম্বর–ফেব্রুয়ারি", "best_en": "Nov-Feb",
        "how_bn": "খুলনা/মোংলা, এরপর অনুমোদিত লঞ্চ ট্যুরে বনে।",
        "how_en": "Khulna/Mongla, then a licensed launch tour into the forest.",
        "cost_low": 8000, "cost_high": 15000,
        "nearby_bn": ["করমজল", "কটকা"], "nearby_en": ["Karamjal", "Kotka"],
        "tip_bn": "নিবন্ধিত ট্যুর অপারেটরে বুক করুন; একা বনে ঢুকবেন না।",
        "tip_en": "Book a registered tour operator; never travel the forest alone.",
        "source": SOURCE_OPEN,
    },
    {
        "slug": "mainamati", "division": "chattogram", "type": "historical",
        "name_bn": "ময়নামতি", "name_en": "Mainamati",
        "lat": 23.4330, "lon": 91.1330, "months": [11, 12, 1, 2],
        "best_bn": "নভেম্বর–ফেব্রুয়ারি", "best_en": "Nov-Feb",
        "how_bn": "ঢাকা থেকে বাস/ট্রেনে কুমিল্লা, এরপর অল্প পথ স্থানীয় গাড়িতে।",
        "how_en": "Dhaka to Cumilla by bus/train, then a short local hop.",
        "cost_low": 1500, "cost_high": 3500,
        "nearby_bn": ["শালবন বিহার", "কুমিল্লা শহর"], "nearby_en": ["Shalban Vihara", "Cumilla town"],
        "tip_bn": "বৌদ্ধ নিদর্শন ও জাদুঘর; শালবন বিহারের সঙ্গে মিলিয়ে দেখুন।",
        "tip_en": "Buddhist ruins and museum; combine with Shalban Vihara.",
        "source": SOURCE_OPEN,
    },
    {
        "slug": "bisnakandi", "division": "sylhet", "type": "nature",
        "name_bn": "বিছনাকান্দি", "name_en": "Bisnakandi",
        "lat": 25.1830, "lon": 91.8670, "months": [6, 7, 8, 9],
        "best_bn": "জুন–সেপ্টেম্বর", "best_en": "Jun-Sep",
        "how_bn": "সিলেট থেকে সিএনজিতে গোয়াইনঘাট, এরপর নৌকায় বিছনাকান্দি।",
        "how_en": "From Sylhet, CNG to Gowainghat, then boat to Bisnakandi.",
        "cost_low": 2500, "cost_high": 4500,
        "nearby_bn": ["রাতারগুল", "পাংথুমাই"], "nearby_en": ["Ratargul", "Pangthumai"],
        "tip_bn": "বর্ষায় পাহাড়ের নিচে পাথুরে নদী ভরে যায়; ড্রাই ব্যাগ নিন।",
        "tip_en": "Monsoon fills the stone riverbed below the hills; carry a dry bag.",
        "source": SOURCE_SITE,
    },
]

# General travel tips (verifiable, non-fabricated advice).
_TIPS = [
    {"bn": "যাত্রার আগে আবহাওয়া ও স্থানীয় পরিস্থিতি যাচাই করুন।",
     "en": "Check the weather and local conditions before you travel."},
    {"bn": "স্থানীয় গাইড ও অনুমোদিত পরিবহন ব্যবহার করুন।",
     "en": "Use local guides and licensed transport."},
    {"bn": "পরিবেশ পরিষ্কার রাখুন—ময়লা ফেলবেন না।",
     "en": "Keep the environment clean — don't litter."},
    {"bn": "জরুরি নম্বর ও পরিবারকে আপনার পরিকল্পনা জানিয়ে রাখুন।",
     "en": "Share your plan and emergency numbers with family."},
]

# Curated multi-stop trip ideas (ids are stop slugs; same-region pairings).
_TRIPS = [
    {"slug": "sylhet-green", "days": 3, "stops": ["srimangal", "jaflong", "ratargul"]},
    {"slug": "hill-adventure", "days": 4, "stops": ["sajek", "nafakhum"]},
    {"slug": "heritage-north", "days": 3, "stops": ["mahasthangarh", "paharpur"]},
    {"slug": "coast-escape", "days": 3, "stops": ["kuakata", "nijhum-dwip"]},
]


def _localise_dest(d, lang):
    """Localized card shape. Cost is an APPROX range flagged cost_approx; never
    a live price. Source is always attributed."""
    div_name = next((pick(lang, b, e) for (i, b, e) in DIVISIONS
                     if i == d["division"]), d["division"])
    return {
        "slug": d["slug"],
        "name": pick(lang, d["name_bn"], d["name_en"]),
        "division": d["division"],
        "region": div_name,  # back-compat: localized division name
        "type": d["type"],
        "lat": d["lat"], "lon": d["lon"],
        "best_season": pick(lang, d["best_bn"], d["best_en"]),
        "how_to_get": pick(lang, d["how_bn"], d["how_en"]),
        "cost_low": d["cost_low"], "cost_high": d["cost_high"],
        "cost_approx": True,
        "nearby": pick(lang, d["nearby_bn"], d["nearby_en"]),
        "tip": pick(lang, d["tip_bn"], d["tip_en"]),
        "source": d["source"],
    }


def destinations(lang="bn", division=None, dtype=None, query=None, region=None):
    """Filtered, localized destination list. division/type/query optional.
    `division`/`dtype` match on the stable id (division id or category id).
    `region` (back-compat) matches the division id OR its localized name in
    either language. `query` matches localized name + how-to-get + nearby."""
    out = []
    q = (query or "").strip().lower()
    div = (division or region or "")

    def _div_match(d):
        if not div:
            return True
        want = div.strip().lower()
        if want == d["division"]:
            return True
        for (i, b, e) in DIVISIONS:
            if i == d["division"] and want in (b.lower(), e.lower()):
                return True
        return False

    for d in _SEED:
        if not _div_match(d):
            continue
        if dtype and dtype.strip().lower() != d["type"]:
            continue
        if q:
            hay = " ".join([
                d["name_bn"], d["name_en"], d["how_bn"], d["how_en"],
                " ".join(d["nearby_bn"]), " ".join(d["nearby_en"]),
            ]).lower()
            if q not in hay:
                continue
        out.append(_localise_dest(d, lang))
    return out


def destination(slug, lang="bn"):
    for d in _SEED:
        if d["slug"] == slug:
            return _localise_dest(d, lang)
    return None


def _haversine_m(la1, lo1, la2, lo2):
    import math
    r = 6371000.0
    rad = math.radians
    d_la = rad(la2 - la1)
    d_lo = rad(lo2 - lo1)
    a = (math.sin(d_la / 2) ** 2 +
         math.cos(rad(la1)) * math.cos(rad(la2)) * math.sin(d_lo / 2) ** 2)
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def near_me(lat, lon, lang="bn", limit=None):
    """Destinations sorted by distance from (lat, lon). Adds `distance_m`.
    No GPS? The caller simply doesn't call this — the plain list still works."""
    out = []
    for d in _SEED:
        item = _localise_dest(d, lang)
        item["distance_m"] = round(_haversine_m(lat, lon, d["lat"], d["lon"]))
        out.append(item)
    out.sort(key=lambda x: x["distance_m"])
    return out[:limit] if limit else out


def seasonal(month, lang="bn"):
    """Destinations whose best-season window includes `month` (1..12)."""
    return [_localise_dest(d, lang) for d in _SEED if month in d["months"]]


def trip_ideas(lang="bn"):
    """Curated multi-stop trips with an APPROX total (sum of stop ranges)."""
    out = []
    for tr in _TRIPS:
        stops = [destination(s, lang) for s in tr["stops"]]
        stops = [s for s in stops if s]
        out.append({
            "slug": tr["slug"],
            "days": tr["days"],
            "stops": stops,
            "cost_low": sum(s["cost_low"] for s in stops),
            "cost_high": sum(s["cost_high"] for s in stops),
            "cost_approx": True,
        })
    return out


def tips(lang="bn"):
    return [pick(lang, t["bn"], t["en"]) for t in _TIPS]


def regions(lang="bn"):
    """Back-compat: distinct localized division names present in the seed."""
    seen = []
    for d in _SEED:
        name = next((pick(lang, b, e) for (i, b, e) in DIVISIONS if i == d["division"]), d["division"])
        if name not in seen:
            seen.append(name)
    return seen


def divisions(lang="bn"):
    return [{"id": i, "name": pick(lang, b, e)} for (i, b, e) in DIVISIONS]


def categories(lang="bn"):
    return [{"id": i, "name": pick(lang, b, e)} for (i, b, e) in CATEGORIES]


def companion(lang="bn"):
    """Everything the travel-companion screen needs in one call, with the
    owner-site attribution and an honest approx-cost disclaimer shown."""
    import datetime
    month = datetime.date.today().month
    return {
        "source": SOURCE_SITE,
        "attribution": pick(
            lang,
            f"তথ্যসূত্র: {SOURCE_SITE} ও উন্মুক্ত তথ্য ({SOURCE_OPEN})। খরচ আনুমানিক।",
            f"Sources: {SOURCE_SITE} and open data ({SOURCE_OPEN}). Costs are approximate.",
        ),
        "destinations": destinations(lang),
        "divisions": divisions(lang),
        "categories": categories(lang),
        "regions": regions(lang),
        "seasonal": seasonal(month, lang),
        "trip_ideas": trip_ideas(lang),
        "tips": tips(lang),
    }
