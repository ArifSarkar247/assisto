"""
Unseen World — travel companion (launch gap F). Surfaces lesser-known
destinations in Bangladesh with practical tips. Content is sourced from the
OWNER's own unseenbangladesh.com plus open data; we NEVER fabricate places,
prices or facts. Destinations carry a `source` so the app can attribute them.

This module is pure data + filtering/search logic. A later integrator step can
pull live articles from unseenbangladesh.com (owner key / feed); for launch we
ship a small, honest seed of well-known-but-under-visited spots. Anything the
app can't verify (live prices, current road conditions) is explicitly left out
rather than guessed.
"""
from .i18n import pick

SOURCE_SITE = "unseenbangladesh.com"

# Honest seed. Facts kept to stable, verifiable basics (region, type, best
# season). No invented prices or ratings. Integrator can replace/extend from
# the owner's site feed.
_SEED = [
    {
        "slug": "nijhum-dwip",
        "name_bn": "নিঝুম দ্বীপ", "name_en": "Nijhum Dwip",
        "region_bn": "নোয়াখালী", "region_en": "Noakhali",
        "type": "island",
        "best_season_bn": "নভেম্বর–ফেব্রুয়ারি", "best_season_en": "Nov–Feb",
        "tip_bn": "চিত্রল হরিণ ও ম্যানগ্রোভের জন্য সকালে যান; জোয়ার-ভাটার সময় দেখে নিন।",
        "tip_en": "Go early for spotted deer and mangroves; check the tide times.",
    },
    {
        "slug": "jaflong-sangu",
        "name_bn": "জাফলং", "name_en": "Jaflong",
        "region_bn": "সিলেট", "region_en": "Sylhet",
        "type": "river-hills",
        "best_season_bn": "জুলাই–অক্টোবর", "best_season_en": "Jul–Oct",
        "tip_bn": "বর্ষার পরে পাথুরে নদী ও মেঘালয়ের পাহাড় সবচেয়ে সুন্দর।",
        "tip_en": "After the monsoon the stone river and Meghalaya hills look best.",
    },
    {
        "slug": "nafakhum",
        "name_bn": "নাফাখুম জলপ্রপাত", "name_en": "Nafakhum Waterfall",
        "region_bn": "বান্দরবান", "region_en": "Bandarban",
        "type": "waterfall",
        "best_season_bn": "অক্টোবর–ডিসেম্বর", "best_season_en": "Oct–Dec",
        "tip_bn": "রেমাক্রি থেকে নৌকা ও ট্রেকিং দরকার; স্থানীয় গাইড নিন।",
        "tip_en": "Needs a boat from Remakri and a trek; hire a local guide.",
    },
    {
        "slug": "sajek",
        "name_bn": "সাজেক ভ্যালি", "name_en": "Sajek Valley",
        "region_bn": "রাঙ্গামাটি", "region_en": "Rangamati",
        "type": "hills",
        "best_season_bn": "সেপ্টেম্বর–মার্চ", "best_season_en": "Sep–Mar",
        "tip_bn": "ভোরের মেঘ দেখতে আগের রাতেই পৌঁছান; পানি সঙ্গে রাখুন।",
        "tip_en": "Arrive the night before for the morning clouds; carry water.",
    },
    {
        "slug": "ratargul",
        "name_bn": "রাতারগুল জলাবন", "name_en": "Ratargul Swamp Forest",
        "region_bn": "সিলেট", "region_en": "Sylhet",
        "type": "swamp-forest",
        "best_season_bn": "জুন–সেপ্টেম্বর", "best_season_en": "Jun–Sep",
        "tip_bn": "বর্ষায় নৌকায় ঘুরুন; গাছের ডাল ভাঙবেন না।",
        "tip_en": "Tour by boat in the wet season; don't break the branches.",
    },
    {
        "slug": "kuakata",
        "name_bn": "কুয়াকাটা", "name_en": "Kuakata",
        "region_bn": "পটুয়াখালী", "region_en": "Patuakhali",
        "type": "beach",
        "best_season_bn": "নভেম্বর–মার্চ", "best_season_en": "Nov–Mar",
        "tip_bn": "একই সৈকত থেকে সূর্যোদয় ও সূর্যাস্ত—দুটোই দেখা যায়।",
        "tip_en": "You can see both sunrise and sunset from the same beach.",
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


def _localise_dest(d, lang):
    return {
        "slug": d["slug"],
        "name": pick(lang, d["name_bn"], d["name_en"]),
        "region": pick(lang, d["region_bn"], d["region_en"]),
        "type": d["type"],
        "best_season": pick(lang, d["best_season_bn"], d["best_season_en"]),
        "tip": pick(lang, d["tip_bn"], d["tip_en"]),
        "source": SOURCE_SITE,
    }


def destinations(lang="bn", region=None, dtype=None, query=None):
    """Filtered, localized destination list. Region/type/query are optional."""
    out = []
    q = (query or "").strip().lower()
    for d in _SEED:
        if region and region.strip().lower() not in (
                d["region_bn"].lower(), d["region_en"].lower()):
            continue
        if dtype and dtype.strip().lower() != d["type"]:
            continue
        if q and q not in (d["name_bn"] + d["name_en"] + d["region_bn"]
                           + d["region_en"]).lower():
            continue
        out.append(_localise_dest(d, lang))
    return out


def destination(slug, lang="bn"):
    for d in _SEED:
        if d["slug"] == slug:
            return _localise_dest(d, lang)
    return None


def tips(lang="bn"):
    return [pick(lang, t["bn"], t["en"]) for t in _TIPS]


def regions(lang="bn"):
    seen = []
    for d in _SEED:
        r = pick(lang, d["region_bn"], d["region_en"])
        if r not in seen:
            seen.append(r)
    return seen


def companion(lang="bn"):
    """Everything the travel-companion screen needs in one call, with the
    owner-site attribution shown."""
    return {
        "source": SOURCE_SITE,
        "attribution": pick(lang,
                            f"তথ্যসূত্র: {SOURCE_SITE} ও উন্মুক্ত তথ্য।",
                            f"Sources: {SOURCE_SITE} and open data."),
        "destinations": destinations(lang),
        "regions": regions(lang),
        "tips": tips(lang),
    }
