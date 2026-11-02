"""amarket — Assisto Market v1 (owner master order 3 Nov, P3-E).

Flag `assisto_market` (default OFF). Reverse auction + group-buy, Dhaka only,
cash on delivery only, no fees. Owner decisions that are NOT taken here
(documents for seller verification, commission, disputes, delivery partners,
banned-goods list, escrow) are listed in
owner_actions/FEATURE_CARD_ASSISTO_MARKET_BN.md §6.

Rules (all server-side):
  * a NEED: category, title/description, quantity + unit, optional budget
    (private unless the buyer turns `show_budget` on), a Dhaka area, a
    deadline (1 hour .. 30 days); 5 new needs a day, 10 open at once;
  * a SELLER = an existing BusinessProfile + a MarketSeller row the owner
    APPROVED in Owner Admin. No documents are collected;
  * bids are SEALED: a seller sees only their own bid, never another price
    or the number of bids; the buyer's name/number stay hidden until a deal;
  * ranking ([rank_bids]) is rule-based with TRANSPARENT weights (price 50,
    delivery 20, rating 20, distance 10), explained in plain Bangla, works
    without any AI key and NEVER hides the cheapest offer;
  * accept -> one COD MarketDeal per buyer (poster + group-buy joiners), a
    COD Order in the seller's Business orders, and a My Circle chat between
    each buyer and the seller (existing E2E chat via core.msgreq);
  * report (ModerationReport/Item, kinds mkt_need/mkt_bid/mkt_seller) and
    Market block (needs and bids of the two people never meet again).
Money is in POISHA everywhere; the app sends whole taka.
"""
import logging
import math
import re
from datetime import timedelta
from decimal import Decimal

from django.db import IntegrityError, transaction
from django.utils import timezone

log = logging.getLogger(__name__)

FLAG = "assisto_market"

# ------------------------------------------------------------------ catalogue
# Dhaka city areas (thana level, DNCC + DSCC). lat/lng = an APPROXIMATE
# centre of the area — distance is "about N km between area centres", never
# a shop address, and the screen says so.
DHAKA_AREAS = {
    "adabor": ("আদাবর", "Adabor", 23.7740, 90.3580),
    "badda": ("বাড্ডা", "Badda", 23.7806, 90.4261),
    "banani": ("বনানী", "Banani", 23.7937, 90.4066),
    "bangshal": ("বংশাল", "Bangshal", 23.7170, 90.4060),
    "bashundhara": ("বসুন্ধরা", "Bashundhara", 23.8193, 90.4526),
    "cantonment": ("ক্যান্টনমেন্ট", "Cantonment", 23.8173, 90.3990),
    "chawkbazar": ("চকবাজার", "Chawkbazar", 23.7170, 90.3960),
    "dakshinkhan": ("দক্ষিণখান", "Dakshinkhan", 23.8650, 90.4260),
    "darus_salam": ("দারুস সালাম", "Darus Salam", 23.7840, 90.3500),
    "demra": ("ডেমরা", "Demra", 23.7239, 90.4936),
    "dhanmondi": ("ধানমন্ডি", "Dhanmondi", 23.7461, 90.3742),
    "gendaria": ("গেন্ডারিয়া", "Gendaria", 23.7050, 90.4240),
    "gulshan": ("গুলশান", "Gulshan", 23.7925, 90.4078),
    "hazaribagh": ("হাজারীবাগ", "Hazaribagh", 23.7344, 90.3640),
    "jatrabari": ("যাত্রাবাড়ী", "Jatrabari", 23.7104, 90.4349),
    "kadamtali": ("কদমতলী", "Kadamtali", 23.7000, 90.4400),
    "kafrul": ("কাফরুল", "Kafrul", 23.7889, 90.3833),
    "kalabagan": ("কলাবাগান", "Kalabagan", 23.7480, 90.3800),
    "kamrangirchar": ("কামরাঙ্গীরচর", "Kamrangirchar", 23.7135, 90.3720),
    "khilgaon": ("খিলগাঁও", "Khilgaon", 23.7516, 90.4252),
    "khilkhet": ("খিলক্ষেত", "Khilkhet", 23.8318, 90.4245),
    "kotwali": ("কোতোয়ালি", "Kotwali", 23.7090, 90.4050),
    "lalbagh": ("লালবাগ", "Lalbagh", 23.7186, 90.3881),
    "mirpur": ("মিরপুর", "Mirpur", 23.8223, 90.3654),
    "mohammadpur": ("মোহাম্মদপুর", "Mohammadpur", 23.7662, 90.3589),
    "motijheel": ("মতিঝিল", "Motijheel", 23.7330, 90.4172),
    "mugda": ("মুগদা", "Mugda", 23.7300, 90.4320),
    "new_market": ("নিউ মার্কেট", "New Market", 23.7330, 90.3850),
    "pallabi": ("পল্লবী", "Pallabi", 23.8268, 90.3640),
    "paltan": ("পল্টন", "Paltan", 23.7340, 90.4130),
    "ramna": ("রমনা", "Ramna", 23.7413, 90.4011),
    "rampura": ("রামপুরা", "Rampura", 23.7613, 90.4219),
    "sabujbagh": ("সবুজবাগ", "Sabujbagh", 23.7400, 90.4300),
    "shah_ali": ("শাহ আলী", "Shah Ali", 23.8050, 90.3550),
    "shahbagh": ("শাহবাগ", "Shahbagh", 23.7385, 90.3958),
    "shahjahanpur": ("শাহজাহানপুর", "Shahjahanpur", 23.7420, 90.4210),
    "sher_e_bangla_nagar": ("শেরেবাংলা নগর", "Sher-e-Bangla Nagar", 23.7720, 90.3770),
    "shyampur": ("শ্যামপুর", "Shyampur", 23.6900, 90.4300),
    "sutrapur": ("সূত্রাপুর", "Sutrapur", 23.7110, 90.4140),
    "tejgaon": ("তেজগাঁও", "Tejgaon", 23.7639, 90.3925),
    "turag": ("তুরাগ", "Turag", 23.8933, 90.3741),
    "uttara": ("উত্তরা", "Uttara", 23.8759, 90.3795),
    "uttarkhan": ("উত্তরখান", "Uttarkhan", 23.8820, 90.4350),
    "vatara": ("ভাটারা", "Vatara", 23.8000, 90.4300),
    "wari": ("ওয়ারী", "Wari", 23.7176, 90.4196),
}

# v1 category list (the owner may narrow it for the pilot — decision §6.9).
CATEGORIES = {
    "grocery": ("মুদি ও খাবার", "Groceries & food"),
    "household": ("ঘরের জিনিস", "Household items"),
    "electronics": ("ইলেকট্রনিক্স", "Electronics"),
    "clothing": ("পোশাক ও কাপড়", "Clothing & fabric"),
    "furniture": ("আসবাব", "Furniture"),
    "building": ("নির্মাণসামগ্রী", "Building materials"),
    "stationery": ("স্টেশনারি ও অফিস", "Stationery & office"),
    "beauty": ("প্রসাধনী ও যত্ন", "Beauty & care"),
    "other": ("অন্যান্য", "Other"),
}

UNITS = {
    "piece": ("পিস", "piece"),
    "kg": ("কেজি", "kg"),
    "litre": ("লিটার", "litre"),
    "dozen": ("ডজন", "dozen"),
    "bag": ("বস্তা", "bag"),
    "box": ("বাক্স", "box"),
    "metre": ("মিটার", "metre"),
    "set": ("সেট", "set"),
}

# Transparent ranking weights (shown on the screen). Sum = 100.
WEIGHTS = {"price": 50, "delivery": 20, "rating": 20, "distance": 10}
NEUTRAL = 0.5          # no rating yet / unknown distance = the middle
DIST_CAP_KM = 25.0     # >= 25 km between area centres scores 0 on distance

LIMITS = {
    "needs_per_day": 5,
    "open_needs": 10,
    "bids_per_day": 50,
    "joins_per_day": 20,
    "reports_per_day": 20,
    "max_qty": 100000,
    "max_unit_taka": 10000000,     # ৳১ কোটি per unit
    "max_hours": 720,              # 30 days
    "deadline_min_h": 1,
    "deadline_max_d": 30,
    "accept_grace_h": 48,          # buyer may still accept after the deadline
    "new_need_push_cap": 50,
    "hide_after_reporters": 3,
}

# Clearly illegal goods only (weapons, drugs, explosives). The full banned
# list is an OWNER decision (§6.8). English words match whole words only
# ("begun" = eggplant must not match "gun").
_BANNED_BN = ("অস্ত্র", "পিস্তল", "বন্দুক", "ইয়াবা", "গাঁজা", "হেরোইন",
              "ফেনসিডিল", "বিস্ফোরক", "বোমা", "কোকেন")
_BANNED_EN = re.compile(
    r"\b(pistol|guns?|rifle|ammo|ammunition|yaba|ganja|heroin|phensedyl|"
    r"cocaine|explosives?|bombs?)\b", re.IGNORECASE)

REPORT_CATEGORIES = ("scam_fraud", "spam", "harassment", "impersonation",
                     "misinformation", "other")
SEVERE = ("scam_fraud",)
REPORT_KINDS = {"need": "mkt_need", "bid": "mkt_bid", "seller": "mkt_seller"}

_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


# ------------------------------------------------------------------ helpers
def pick(lang, bn, en):
    return en if lang == "en" else bn


def num(v, lang):
    s = str(v)
    return s.translate(_BN_DIGITS) if lang != "en" else s


def taka(poisha, lang="bn"):
    """৳1,234 (whole taka; paisa shown only when not whole)."""
    p = int(poisha or 0)
    whole, rest = divmod(abs(p), 100)
    s = "{:,}".format(whole) + (".%02d" % rest if rest else "")
    return "৳" + ("-" if p < 0 else "") + num(s, lang)


def area_label(key, lang="bn"):
    a = DHAKA_AREAS.get(key)
    return pick(lang, a[0], a[1]) if a else ""


def category_label(key, lang="bn"):
    c = CATEGORIES.get(key)
    return pick(lang, c[0], c[1]) if c else ""


def unit_label(key, lang="bn"):
    u = UNITS.get(key)
    return pick(lang, u[0], u[1]) if u else key


def distance_km(a, b):
    """Approximate km between two Dhaka area centres (None if unknown)."""
    pa, pb = DHAKA_AREAS.get(a), DHAKA_AREAS.get(b)
    if not pa or not pb:
        return None
    if a == b:
        return 0.0
    lat1, lon1, lat2, lon2 = map(math.radians, (pa[2], pa[3], pb[2], pb[3]))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    km = 2 * 6371.0 * math.asin(math.sqrt(h))
    return round(km * 2) / 2.0      # nearest 0.5 km — it is approximate


def banned(text):
    t = text or ""
    if any(w in t for w in _BANNED_BN):
        return True
    return bool(_BANNED_EN.search(t))


def _int(v, default=None):
    try:
        if isinstance(v, bool):
            return default
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def areas_payload(lang):
    return [{"key": k, "label": pick(lang, v[0], v[1])}
            for k, v in sorted(DHAKA_AREAS.items(), key=lambda kv: kv[1][1])]


def catalogue(lang):
    return {
        "areas": areas_payload(lang),
        "categories": [{"key": k, "label": pick(lang, *v)} for k, v in CATEGORIES.items()],
        "units": [{"key": k, "label": pick(lang, *v)} for k, v in UNITS.items()],
        "weights": dict(WEIGHTS),
        "limits": {k: LIMITS[k] for k in ("needs_per_day", "open_needs",
                                          "bids_per_day", "max_qty")},
    }


# ------------------------------------------------------------------ validation
def clean_need(d, now=None):
    """Validate a need form. Returns (clean dict, None) or (None, reason)."""
    now = now or timezone.now()
    d = d or {}
    category = str(d.get("category", "")).strip()
    if category not in CATEGORIES:
        return None, "bad_category"
    title = " ".join(str(d.get("title", "")).split())[:120]
    if len(title) < 3:
        return None, "title_required"
    desc = str(d.get("description", "")).strip()[:1000]
    if banned(title) or banned(desc):
        return None, "banned_item"
    qty = _int(d.get("quantity"))
    if qty is None or qty < 1 or qty > LIMITS["max_qty"]:
        return None, "bad_quantity"
    unit = str(d.get("unit", "piece")).strip() or "piece"
    if unit not in UNITS:
        return None, "bad_unit"
    area = str(d.get("area", "")).strip()
    if area not in DHAKA_AREAS:
        return None, "dhaka_only"
    bmin = _int(d.get("budget_min")) if d.get("budget_min") not in (None, "") else None
    bmax = _int(d.get("budget_max")) if d.get("budget_max") not in (None, "") else None
    for b in (bmin, bmax):
        if b is not None and (b < 1 or b > LIMITS["max_unit_taka"] * 10):
            return None, "bad_budget"
    if bmin is not None and bmax is not None and bmin > bmax:
        return None, "bad_budget"
    hours = _int(d.get("deadline_hours"))
    if hours is None:
        return None, "bad_deadline"
    if hours < LIMITS["deadline_min_h"] or hours > LIMITS["deadline_max_d"] * 24:
        return None, "bad_deadline"
    return {
        "category": category, "title": title, "description": desc,
        "quantity": qty, "unit": unit, "area": area,
        "budget_min": bmin * 100 if bmin is not None else None,
        "budget_max": bmax * 100 if bmax is not None else None,
        "show_budget": bool(d.get("show_budget")) and (bmin is not None or bmax is not None),
        "group_open": bool(d.get("group_open")),
        "deadline": now + timedelta(hours=hours),
    }, None


def clean_bid(d):
    d = d or {}
    price = _int(d.get("unit_price"))
    if price is None or price < 1 or price > LIMITS["max_unit_taka"]:
        return None, "bad_price"
    hours = _int(d.get("delivery_hours"))
    if hours is None or hours < 1 or hours > LIMITS["max_hours"]:
        return None, "bad_delivery"
    notes = " ".join(str(d.get("notes", "")).split())[:300]
    if banned(notes):
        return None, "banned_item"
    return {"unit_price": price * 100, "delivery_hours": hours, "notes": notes}, None


# ------------------------------------------------------------------ ranking
def _hours_text(h, lang):
    h = int(h)
    if h % 24 == 0 and h >= 24:
        d = h // 24
        return pick(lang, "%s দিনে" % num(d, lang), "in %d day%s" % (d, "" if d == 1 else "s"))
    return pick(lang, "%s ঘণ্টায়" % num(h, lang), "in %d hour%s" % (h, "" if h == 1 else "s"))


def _km_text(km, lang):
    s = ("%g" % km)
    return pick(lang, "আনুমানিক %s কিমি দূরে" % num(s, lang), "about %s km away" % s)


def rank_bids(bids, qty, budget_max=None, lang="bn"):
    """Rank sealed bids for the BUYER. `bids`: dicts with id, unit_price
    (poisha), delivery_hours, rating_avg (None = no rating yet), rating_count,
    km (None = unknown). Returns {"bids": [...ranked, each with score 0-100,
    parts, total, cheapest/fastest/recommended/over_budget flags, reasons],
    "summary": plain-language explanation, "weights": WEIGHTS}.
    Never drops a bid: every offer — the cheapest above all — is returned."""
    if not bids:
        return {"bids": [], "summary": "", "weights": dict(WEIGHTS)}
    qty = max(1, int(qty or 1))
    min_price = min(int(b["unit_price"]) for b in bids)
    min_hours = min(max(1, int(b["delivery_hours"])) for b in bids)
    out = []
    for b in bids:
        price = max(1, int(b["unit_price"]))
        hours = max(1, int(b["delivery_hours"]))
        avg, cnt = b.get("rating_avg"), int(b.get("rating_count") or 0)
        km = b.get("km")
        parts = {
            "price": min_price / price,
            "delivery": min_hours / hours,
            "rating": ((float(avg) - 1) / 4.0) if (avg is not None and cnt > 0) else NEUTRAL,
            "distance": (max(0.0, 1 - float(km) / DIST_CAP_KM) if km is not None else NEUTRAL),
        }
        score = sum(WEIGHTS[k] * v for k, v in parts.items())
        total = price * qty
        r = dict(b)
        r.update(score=round(score, 1), total=total,
                 parts={k: round(v * WEIGHTS[k], 1) for k, v in parts.items()},
                 cheapest=price == min_price, fastest=hours == min_hours,
                 over_budget=bool(budget_max) and total > int(budget_max),
                 recommended=False)
        reasons = []
        if price == min_price:
            reasons.append(pick(lang, "সবচেয়ে কম দাম", "Lowest price"))
        else:
            more = (price - min_price) * qty
            pct = round(100.0 * (price - min_price) / min_price)
            reasons.append(pick(lang,
                                "সবচেয়ে কম দামের চেয়ে %s বেশি (%s%%)" % (taka(more, lang), num(pct, lang)),
                                "%s more than the lowest price (%d%%)" % (taka(more, lang), pct)))
        reasons.append(pick(lang, "ডেলিভারি %s" % _hours_text(hours, lang),
                            "Delivery %s" % _hours_text(hours, lang))
                       + (pick(lang, " — সবচেয়ে দ্রুত", " — fastest") if hours == min_hours and len(bids) > 1 else ""))
        if avg is not None and cnt > 0:
            reasons.append(pick(lang, "রেটিং %s/৫ (%sটি ডিল)" % (num("%.1f" % float(avg), lang), num(cnt, lang)),
                                "Rating %.1f/5 (%d deals)" % (float(avg), cnt)))
        else:
            reasons.append(pick(lang, "নতুন বিক্রেতা — এখনো রেটিং নেই (মাঝামাঝি ধরা হয়েছে)",
                                "New seller — no rating yet (counted as average)"))
        if km is not None:
            reasons.append(_km_text(km, lang))
        if r["over_budget"]:
            reasons.append(pick(lang, "আপনার বাজেটের চেয়ে বেশি", "Above your budget"))
        r["reasons"] = reasons
        out.append(r)
    out.sort(key=lambda r: (-r["score"], r["unit_price"], r["delivery_hours"], r.get("id") or 0))
    out[0]["recommended"] = True
    best = out[0]
    cheapest = min(out, key=lambda r: (r["unit_price"], r["delivery_hours"]))
    name = best.get("seller_name") or pick(lang, "এই বিক্রেতা", "this seller")
    if best["cheapest"]:
        summary = pick(
            lang,
            "সুপারিশ: %s — এটাই সবচেয়ে কম দাম (মোট %s), ডেলিভারি %s। "
            "হিসাব: দাম ৫০%%, ডেলিভারির সময় ২০%%, রেটিং ২০%%, দূরত্ব ১০%%।"
            % (name, taka(best["total"], lang), _hours_text(best["delivery_hours"], lang)),
            "Suggested: %s — the lowest price (total %s), delivery %s. "
            "Weights: price 50%%, delivery time 20%%, rating 20%%, distance 10%%."
            % (name, taka(best["total"], lang), _hours_text(best["delivery_hours"], lang)))
    else:
        more = best["total"] - cheapest["total"]
        why = []
        if best["delivery_hours"] < cheapest["delivery_hours"]:
            why.append(pick(lang, "ডেলিভারি দ্রুত", "faster delivery"))
        if best["parts"]["rating"] > cheapest["parts"]["rating"]:
            why.append(pick(lang, "রেটিং ভালো", "better rating"))
        if best["parts"]["distance"] > cheapest["parts"]["distance"]:
            why.append(pick(lang, "কাছে", "closer"))
        why_s = pick(lang, " ও ", " and ").join(why) or pick(lang, "সব মিলিয়ে", "overall")
        cname = cheapest.get("seller_name") or pick(lang, "আরেক বিক্রেতা", "another seller")
        summary = pick(
            lang,
            "সুপারিশ: %s — দাম সবচেয়ে কমের চেয়ে %s বেশি, কিন্তু %s। "
            "সবচেয়ে কম দাম: %s (মোট %s) — চাইলে সেটাই নিন। "
            "হিসাব: দাম ৫০%%, ডেলিভারির সময় ২০%%, রেটিং ২০%%, দূরত্ব ১০%%।"
            % (name, taka(more, lang), why_s, cname, taka(cheapest["total"], lang)),
            "Suggested: %s — %s more than the lowest price, but %s. "
            "Lowest price: %s (total %s) — pick it if you prefer. "
            "Weights: price 50%%, delivery time 20%%, rating 20%%, distance 10%%."
            % (name, taka(more, lang), why_s, cname, taka(cheapest["total"], lang)))
    if budget_max and all(r["over_budget"] for r in out):
        summary += pick(lang, " সব অফার আপনার বাজেটের চেয়ে বেশি।",
                        " Every offer is above your budget.")
    return {"bids": out, "summary": summary, "weights": dict(WEIGHTS)}


# ================================================================== DB layer
def _m():
    from . import models
    return models


def biz_of(user):
    return _m().BusinessProfile.objects.filter(user=user).first()


def seller_row(user):
    return _m().MarketSeller.objects.filter(user=user).first()


def is_approved(user):
    s = seller_row(user)
    return bool(s and s.status == "approved")


def blocked_between(a_id, b_id):
    MB = _m().MarketBlock
    return MB.objects.filter(user_id=a_id, blocked_id=b_id).exists() or \
        MB.objects.filter(user_id=b_id, blocked_id=a_id).exists()


def _blocked_ids(user):
    MB = _m().MarketBlock
    a = set(MB.objects.filter(user=user).values_list("blocked_id", flat=True))
    b = set(MB.objects.filter(blocked=user).values_list("user_id", flat=True))
    return a | b


def _today(now=None):
    now = now or timezone.now()
    return now - timedelta(hours=24)


def total_qty(need):
    s = sum(need.joins.values_list("quantity", flat=True))
    return int(need.quantity) + int(s or 0)


def effective_status(need, now=None):
    """open / closed (past deadline + grace) / accepted / cancelled.
    'bidding' is open AND before the deadline."""
    now = now or timezone.now()
    if need.status == "open" and now > need.deadline + timedelta(hours=LIMITS["accept_grace_h"]):
        return "closed"
    return need.status


def bidding_open(need, now=None):
    now = now or timezone.now()
    return (need.status == "open" and now <= need.deadline
            and need.content_status in ("visible", "restored"))


def _visible(obj):
    return obj.content_status in ("visible", "restored")


# ---------------------------------------------------------------- seller
def apply_seller(user, area, categories):
    """Apply (or update area/categories). Needs a BusinessProfile. A
    suspended / rejected seller can update details but stays as decided."""
    biz = biz_of(user)
    if biz is None:
        return None, "need_business"
    if area not in DHAKA_AREAS:
        return None, "dhaka_only"
    cats = [c for c in (categories or []) if c in CATEGORIES]
    cats = list(dict.fromkeys(cats))
    if not cats:
        return None, "bad_category"
    MS = _m().MarketSeller
    s = MS.objects.filter(user=user).first()
    if s is None:
        s = MS.objects.create(user=user, business=biz, area=area, categories=cats)
    else:
        s.area, s.categories, s.business = area, cats, biz
        s.save(update_fields=["area", "categories", "business"])
    return s, None


def seller_payload(s, lang):
    if s is None:
        return None
    avg = (s.rating_sum / s.rating_count) if s.rating_count else None
    return {"status": s.status, "area": s.area, "area_label": area_label(s.area, lang),
            "categories": list(s.categories or []),
            "shop_name": (s.business.shop_name if s.business_id and s.business else ""),
            "rating_avg": round(avg, 1) if avg else None, "rating_count": s.rating_count}


def decide_seller(owner, seller_id, decision, note=""):
    """Owner Admin: approve / suspend / reject / reopen (back to pending)."""
    if decision not in ("approved", "suspended", "rejected", "pending"):
        return None
    s = _m().MarketSeller.objects.filter(pk=seller_id).first()
    if s is None:
        return None
    s.status = decision
    s.owner_note = (note or "")[:300]
    s.decided_at = timezone.now()
    s.decided_by = owner
    s.save(update_fields=["status", "owner_note", "decided_at", "decided_by"])
    if decision == "suspended":
        # a suspended seller's open bids stop counting at once
        _m().MarketBid.objects.filter(seller=s.user, status="active").update(status="withdrawn")
    try:
        from . import push
        if decision == "approved":
            push.push_to_user(s.user, "market", "আপনি এখন Market বিক্রেতা",
                              "You are now a Market seller",
                              "ক্রেতাদের চাহিদা দেখে অফার দিন।",
                              "See buyers' needs and send offers.",
                              data={"route": "market", "tab": "sell"})
    except Exception:  # noqa: BLE001
        pass
    return s


# ---------------------------------------------------------------- needs
def create_need(user, data, now=None):
    now = now or timezone.now()
    clean, err = clean_need(data, now)
    if err:
        return None, err
    MN = _m().MarketNeed
    if MN.objects.filter(buyer=user, created_at__gte=_today(now)).count() >= LIMITS["needs_per_day"]:
        return None, "rate_limited"
    if MN.objects.filter(buyer=user, status="open", deadline__gte=now).count() >= LIMITS["open_needs"]:
        return None, "too_many_open"
    need = MN.objects.create(buyer=user, **clean)
    transaction.on_commit(lambda: notify_sellers_new_need(need.pk))
    return need, None


def notify_sellers_new_need(need_id):
    """Push approved sellers of the category (capped, block-aware)."""
    try:
        from . import push
        m = _m()
        need = m.MarketNeed.objects.filter(pk=need_id).first()
        if need is None:
            return 0
        blocked = _blocked_ids(need.buyer)
        sent = 0
        rows = (m.MarketSeller.objects.filter(status="approved")
                .exclude(user_id=need.buyer_id).select_related("user")
                .order_by("-rating_count", "id"))
        for s in rows:
            if sent >= LIMITS["new_need_push_cap"]:
                break
            if need.category not in (s.categories or []) or s.user_id in blocked:
                continue
            push.push_to_user(
                s.user, "market", "নতুন চাহিদা: %s" % need.title[:60],
                "New need: %s" % need.title[:60],
                "%s · %s" % (area_label(need.area, "bn"), category_label(need.category, "bn")),
                "%s · %s" % (area_label(need.area, "en"), category_label(need.category, "en")),
                data={"route": "market", "tab": "sell", "need_id": str(need.pk)})
            sent += 1
        return sent
    except Exception:  # noqa: BLE001
        log.warning("market.notify_sellers_new_need failed")
        return 0


def need_payload(need, viewer, lang, now=None, with_bids=False):
    """What `viewer` may see of a need. The buyer's identity is hidden from
    sellers; budget only when the buyer chose to show it."""
    now = now or timezone.now()
    is_buyer = viewer is not None and need.buyer_id == viewer.pk
    joined = None
    if viewer is not None and not is_buyer:
        j = need.joins.filter(user=viewer).first()
        joined = j.quantity if j else None
    tq = total_qty(need)
    p = {
        "id": need.pk, "category": need.category,
        "category_label": category_label(need.category, lang),
        "title": need.title, "description": need.description,
        "quantity": need.quantity, "total_quantity": tq,
        "unit": need.unit, "unit_label": unit_label(need.unit, lang),
        "area": need.area, "area_label": area_label(need.area, lang),
        "deadline": need.deadline.isoformat(),
        "group_open": need.group_open,
        "joiners": need.joins.count(),
        "status": effective_status(need, now),
        "bidding_open": bidding_open(need, now),
        "hidden": not _visible(need),
        "mine": is_buyer, "joined_qty": joined,
        "created_at": need.created_at.isoformat() if need.created_at else None,
    }
    if is_buyer or need.show_budget:
        p["budget_min"] = need.budget_min
        p["budget_max"] = need.budget_max
        p["show_budget"] = need.show_budget
    if is_buyer:
        p["bid_count"] = need.bids.filter(status__in=("active", "accepted")).count()
    if with_bids and (is_buyer or joined is not None):
        p["ranking"] = ranked_for(need, lang)
        p["can_accept"] = is_buyer and need.status == "open" and \
            now <= need.deadline + timedelta(hours=LIMITS["accept_grace_h"])
    return p


def ranked_for(need, lang):
    m = _m()
    rows = list(need.bids.filter(status__in=("active", "accepted"))
                .exclude(content_status__in=("hidden", "removed"))
                .select_related("seller"))
    sellers = {s.user_id: s for s in m.MarketSeller.objects.filter(
        user_id__in=[b.seller_id for b in rows]).select_related("business")}
    data = []
    for b in rows:
        s = sellers.get(b.seller_id)
        if s is None or (s.status != "approved" and b.status != "accepted"):
            continue
        name = (s.business.shop_name if s.business_id and s.business else "") or \
            (b.seller.name or "")
        data.append({
            "id": b.pk, "unit_price": b.unit_price, "delivery_hours": b.delivery_hours,
            "notes": b.notes, "status": b.status, "seller_name": name.strip()[:80],
            "seller_area": area_label(s.area, lang),
            "rating_avg": (s.rating_sum / s.rating_count) if s.rating_count else None,
            "rating_count": s.rating_count,
            "km": distance_km(s.area, need.area),
        })
    return rank_bids(data, total_qty(need), need.budget_max, lang)


def my_needs(user, lang):
    rows = _m().MarketNeed.objects.filter(buyer=user).order_by("-created_at")[:50]
    return [need_payload(n, user, lang) for n in rows]


def cancel_need(user, need_id):
    m = _m()
    with transaction.atomic():
        need = m.MarketNeed.objects.select_for_update().filter(pk=need_id, buyer=user).first()
        if need is None:
            return None, "not_found"
        if need.status != "open":
            return None, "not_open"
        need.status = "cancelled"
        need.save(update_fields=["status", "updated_at"])
        m.MarketBid.objects.filter(need=need, status="active").update(status="lost")
    return need, None


def group_feed(user, area, lang, now=None):
    """Open group-buy needs others posted (nearest area first)."""
    now = now or timezone.now()
    blocked = _blocked_ids(user)
    rows = (_m().MarketNeed.objects.filter(group_open=True, status="open",
                                           deadline__gte=now,
                                           content_status__in=("visible", "restored"))
            .exclude(buyer=user).exclude(buyer_id__in=blocked)
            .order_by("-created_at")[:100])
    out = [need_payload(n, user, lang, now) for n in rows]
    if area in DHAKA_AREAS:
        out.sort(key=lambda p: distance_km(area, p["area"]) or 0.0)
    return out


def join_need(user, need_id, qty, now=None):
    now = now or timezone.now()
    m = _m()
    qty = _int(qty)
    if qty is None or qty < 1 or qty > LIMITS["max_qty"]:
        return None, "bad_quantity"
    need = m.MarketNeed.objects.filter(pk=need_id).first()
    if need is None or not _visible(need):
        return None, "not_found"
    if need.buyer_id == user.pk:
        return None, "own_need"
    if not need.group_open or not bidding_open(need, now):
        return None, "not_open"
    if blocked_between(user.pk, need.buyer_id):
        return None, "not_found"
    j = m.MarketJoin.objects.filter(need=need, user=user).first()
    if j is None:
        if m.MarketJoin.objects.filter(user=user, created_at__gte=_today(now)).count() >= LIMITS["joins_per_day"]:
            return None, "rate_limited"
        try:
            j = m.MarketJoin.objects.create(need=need, user=user, quantity=qty)
        except IntegrityError:
            j = m.MarketJoin.objects.get(need=need, user=user)
    j.quantity = qty
    j.save(update_fields=["quantity"])
    return j, None


def leave_need(user, need_id):
    need = _m().MarketNeed.objects.filter(pk=need_id).first()
    if need is None:
        return "not_found"
    if need.status != "open":
        return "not_open"
    _m().MarketJoin.objects.filter(need=need, user=user).delete()
    return None


# ---------------------------------------------------------------- seller feed / bids
def seller_feed(user, lang, now=None):
    """Open needs in the approved seller's categories (nearest first), each
    with ONLY this seller's own bid (sealed)."""
    now = now or timezone.now()
    s = seller_row(user)
    if s is None or s.status != "approved":
        return []
    blocked = _blocked_ids(user)
    m = _m()
    rows = list(m.MarketNeed.objects.filter(status="open", deadline__gte=now,
                                            category__in=list(s.categories or []),
                                            content_status__in=("visible", "restored"))
                .exclude(buyer=user).exclude(buyer_id__in=blocked)
                .order_by("-created_at")[:100])
    mine = {b.need_id: b for b in m.MarketBid.objects.filter(
        seller=user, need_id__in=[n.pk for n in rows])}
    out = []
    for n in rows:
        p = need_payload(n, user, lang, now)
        p["km"] = distance_km(s.area, n.area)
        b = mine.get(n.pk)
        p["my_bid"] = bid_payload(b) if b else None
        out.append(p)
    out.sort(key=lambda p: (p["my_bid"] is not None, p["km"] if p["km"] is not None else 99))
    return out


def bid_payload(b):
    return {"id": b.pk, "unit_price": b.unit_price, "delivery_hours": b.delivery_hours,
            "notes": b.notes, "status": b.status, "hidden": not _visible(b)}


def place_bid(user, need_id, data, now=None):
    now = now or timezone.now()
    m = _m()
    s = seller_row(user)
    if s is None or s.status != "approved":
        return None, "not_seller"
    clean, err = clean_bid(data)
    if err:
        return None, err
    need = m.MarketNeed.objects.filter(pk=need_id).first()
    if need is None or not _visible(need) or blocked_between(user.pk, need.buyer_id):
        return None, "not_found"
    if need.buyer_id == user.pk:
        return None, "own_need"
    if need.category not in (s.categories or []):
        return None, "not_your_category"
    if not bidding_open(need, now):
        return None, "not_open"
    b = m.MarketBid.objects.filter(need=need, seller=user).first()
    if b is None:
        if m.MarketBid.objects.filter(seller=user, created_at__gte=_today(now)).count() >= LIMITS["bids_per_day"]:
            return None, "rate_limited"
        try:
            b = m.MarketBid.objects.create(need=need, seller=user, **clean)
        except IntegrityError:
            b = m.MarketBid.objects.get(need=need, seller=user)
        first = True
    else:
        first = False
        if b.status not in ("active", "withdrawn") or not _visible(b):
            return None, "not_open"
    for k, v in clean.items():
        setattr(b, k, v)
    b.status = "active"
    b.save()
    if first:
        transaction.on_commit(lambda: _push_new_bid(need.pk))
    return b, None


def _push_new_bid(need_id):
    try:
        from . import push
        need = _m().MarketNeed.objects.select_related("buyer").filter(pk=need_id).first()
        if need is None:
            return
        push.push_to_user(need.buyer, "market", "নতুন অফার এসেছে", "A new offer arrived",
                          need.title[:80], need.title[:80],
                          data={"route": "market", "need_id": str(need.pk)})
    except Exception:  # noqa: BLE001
        pass


def withdraw_bid(user, need_id):
    b = _m().MarketBid.objects.filter(need_id=need_id, seller=user).first()
    if b is None:
        return "not_found"
    if b.status != "active":
        return "not_open"
    b.status = "withdrawn"
    b.save(update_fields=["status", "updated_at"])
    return None


# ---------------------------------------------------------------- accept / deals
def _connect_chat(a, b):
    """Open the existing My Circle E2E chat between the two (both consented:
    the seller by bidding, the buyer by accepting). Returns a's edge or None
    (a block on either side wins, as in every My Circle chat)."""
    try:
        from . import msgreq
        edge, reason = msgreq.start(a, b, "custom")
        if edge is not None and edge.state == "accepted":
            return edge
        if edge is None:
            edge2, _ = msgreq.start(b, a, "custom")
            if edge2 is None:
                return None
            edge, _ = msgreq.start(a, b, "custom")
            return edge
        msgreq.start(b, a, "custom")   # converges both rows to accepted
        edge.refresh_from_db()
        return edge
    except Exception:  # noqa: BLE001
        log.warning("market._connect_chat failed")
        return None


def accept_bid(user, need_id, bid_id, now=None):
    now = now or timezone.now()
    m = _m()
    with transaction.atomic():
        need = m.MarketNeed.objects.select_for_update().filter(pk=need_id, buyer=user).first()
        if need is None:
            return None, "not_found"
        if need.status != "open" or effective_status(need, now) != "open":
            return None, "not_open"
        bid = m.MarketBid.objects.select_for_update().filter(pk=bid_id, need=need).first()
        if bid is None or bid.status != "active" or not _visible(bid):
            return None, "bid_gone"
        s = seller_row(bid.seller)
        if s is None or s.status != "approved":
            return None, "bid_gone"
        if blocked_between(user.pk, bid.seller_id):
            return None, "bid_gone"
        need.status = "accepted"
        need.accepted_bid = bid
        need.save(update_fields=["status", "accepted_bid", "updated_at"])
        bid.status = "accepted"
        bid.save(update_fields=["status", "updated_at"])
        m.MarketBid.objects.filter(need=need, status="active").update(status="lost")
        parties = [(user, need.quantity)]
        for j in need.joins.select_related("user"):
            if not blocked_between(j.user_id, bid.seller_id):
                parties.append((j.user, j.quantity))
        deals = []
        for buyer, q in parties:
            total = int(bid.unit_price) * int(q)
            order = m.Order.objects.create(
                user=bid.seller, business=s.business,
                customer_name=(buyer.name or "")[:120],
                customer_phone=(buyer.phone or "")[:40],
                items=[{"name": need.title[:120], "qty": int(q),
                        "price": float(Decimal(bid.unit_price) / 100)}],
                total=Decimal(total) / 100, status="new", payment="cod",
                channel="market")
            deals.append(m.MarketDeal.objects.create(
                need=need, bid=bid, buyer=buyer, seller=bid.seller, quantity=q,
                unit_price=bid.unit_price, total=total, order=order))
    deal_ids = [d.pk for d in deals]
    transaction.on_commit(lambda: _after_accept(deal_ids))
    return deals, None


def _after_accept(deal_ids):
    from . import push
    for d in _m().MarketDeal.objects.filter(pk__in=deal_ids).select_related("buyer", "seller", "need"):
        _connect_chat(d.buyer, d.seller)
        try:
            push.push_to_user(d.seller, "market", "আপনার অফার গ্রহণ হয়েছে",
                              "Your offer was accepted",
                              "%s · ক্যাশ অন ডেলিভারি" % d.need.title[:60],
                              "%s · cash on delivery" % d.need.title[:60],
                              data={"route": "market", "tab": "deals", "deal_id": str(d.pk)})
            if d.buyer_id != d.need.buyer_id:
                push.push_to_user(d.buyer, "market", "একসাথে কেনার অফার ঠিক হয়েছে",
                                  "Your group-buy has a deal",
                                  d.need.title[:80], d.need.title[:80],
                                  data={"route": "market", "tab": "deals", "deal_id": str(d.pk)})
        except Exception:  # noqa: BLE001
            pass


def deal_payload(d, viewer, lang):
    me_buyer = d.buyer_id == viewer.pk
    other = d.seller if me_buyer else d.buyer
    s = seller_row(d.seller)
    shop = (s.business.shop_name if s and s.business_id and s.business else "") if s else ""
    return {
        "id": d.pk, "need_id": d.need_id, "title": d.need.title,
        "role": "buyer" if me_buyer else "seller",
        "other_name": ((shop or other.name) if me_buyer else other.name or "")[:80],
        "quantity": d.quantity, "unit_label": unit_label(d.need.unit, lang),
        "unit_price": d.unit_price, "total": d.total, "payment": d.payment, "fee": d.fee,
        "status": d.status, "rating": d.rating,
        "can_rate": me_buyer and d.status == "delivered" and d.rating is None,
        "area_label": area_label(d.need.area, lang),
        "created_at": d.created_at.isoformat(),
    }


def my_deals(user, lang):
    from django.db.models import Q
    rows = (_m().MarketDeal.objects.filter(Q(buyer=user) | Q(seller=user))
            .select_related("need", "buyer", "seller").order_by("-created_at")[:100])
    return [deal_payload(d, user, lang) for d in rows]


def deal_act(user, deal_id, action, rating=None):
    m = _m()
    with transaction.atomic():
        d = m.MarketDeal.objects.select_for_update().filter(pk=deal_id).first()
        if d is None or user.pk not in (d.buyer_id, d.seller_id):
            return None, "not_found"
        if action == "delivered":
            if d.status != "confirmed":
                return None, "not_open"
            d.status, d.delivered_at = "delivered", timezone.now()
            d.save(update_fields=["status", "delivered_at"])
        elif action == "cancel":
            if d.status != "confirmed":
                return None, "not_open"
            d.status = "cancelled"
            d.cancelled_by = "buyer" if user.pk == d.buyer_id else "seller"
            d.save(update_fields=["status", "cancelled_by"])
            if d.order_id:
                m.Order.objects.filter(pk=d.order_id, status="new").update(status="cancelled")
        elif action == "rate":
            r = _int(rating)
            if user.pk != d.buyer_id or d.status != "delivered" or d.rating is not None:
                return None, "not_open"
            if r is None or r < 1 or r > 5:
                return None, "bad_rating"
            d.rating = r
            d.save(update_fields=["rating"])
            from django.db.models import F
            m.MarketSeller.objects.filter(user_id=d.seller_id).update(
                rating_sum=F("rating_sum") + r, rating_count=F("rating_count") + 1)
        else:
            return None, "bad_action"
    return d, None


def deal_chat_edge(user, deal_id):
    d = _m().MarketDeal.objects.select_related("buyer", "seller").filter(pk=deal_id).first()
    if d is None or user.pk not in (d.buyer_id, d.seller_id):
        return None, "not_found"
    other = d.seller if user.pk == d.buyer_id else d.buyer
    edge = (_m().CircleMember.objects.filter(user=user, peer_user=other, state="accepted")
            .order_by("-id").first())
    if edge is None:
        _connect_chat(user, other)
        edge = (_m().CircleMember.objects.filter(user=user, peer_user=other)
                .exclude(state__in=("declined", "blocked")).exclude(blocked=True)
                .order_by("-id").first())
    if edge is None:
        return None, "chat_blocked"
    return edge, None


# ---------------------------------------------------------------- report / block
def _report_target(user, kind, tid):
    """(target, owner_user_id) if `user` may see the target, else (None, None)."""
    m = _m()
    tid = _int(tid)
    if tid is None:
        return None, None
    if kind == "need":
        n = m.MarketNeed.objects.filter(pk=tid).first()
        return (n, n.buyer_id) if n else (None, None)
    if kind == "bid":
        b = m.MarketBid.objects.select_related("need").filter(pk=tid).first()
        if b is None:
            return None, None
        if user.pk == b.need.buyer_id or b.need.joins.filter(user=user).exists():
            return b, b.seller_id
        return None, None
    if kind == "seller":
        s = m.MarketSeller.objects.filter(user_id=tid).first()
        return (s, s.user_id) if s else (None, None)
    return None, None


def report(user, kind, tid, category, note="", now=None):
    now = now or timezone.now()
    m = _m()
    if kind not in REPORT_KINDS:
        return None, "bad_report"
    cat = category if category in REPORT_CATEGORIES else "other"
    target, owner_id = _report_target(user, kind, tid)
    if target is None:
        return None, "not_found"
    if owner_id == user.pk:
        return None, "own_item"
    tkind = REPORT_KINDS[kind]
    if m.ModerationReport.objects.filter(reporter=user, target_kind__startswith="mkt_",
                                         created_at__gte=_today(now)).count() >= LIMITS["reports_per_day"]:
        return None, "rate_limited"
    tid_s = str(target.user_id if kind == "seller" else target.pk)
    m.ModerationReport.objects.create(reporter=user, target_kind=tkind, target_id=tid_s,
                                      categories=[cat], note=(note or "")[:1000], valid=True)
    item = (m.ModerationItem.objects.filter(target_kind=tkind, target_id=tid_s)
            .exclude(queue_state="resolved").order_by("-opened_at").first())
    severe = cat in SEVERE
    if item is None:
        item = m.ModerationItem.objects.create(target_kind=tkind, target_id=tid_s,
                                               categories=[cat], severe=severe,
                                               content_status="visible")
    else:
        item.report_count += 1
        item.categories = sorted(set(item.categories or []) | {cat})
        item.severe = item.severe or severe
        item.save(update_fields=["report_count", "categories", "severe"])
    reporters = (m.ModerationReport.objects.filter(target_kind=tkind, target_id=tid_s)
                 .values("reporter_id").distinct().count())
    if reporters >= LIMITS["hide_after_reporters"] and kind in ("need", "bid") \
            and item.content_status == "visible":
        item.content_status = "hidden"
        item.save(update_fields=["content_status"])
        apply_status(tkind, tid_s, "hidden")
    return item, None


def apply_status(tkind, tid, status):
    """Owner Admin / auto-hide: persist a moderation status onto the target."""
    m = _m()
    t = _int(tid)
    if t is None:
        return
    if tkind == "mkt_need":
        m.MarketNeed.objects.filter(pk=t).update(content_status=status)
        if status == "removed":
            m.MarketNeed.objects.filter(pk=t, status="open").update(status="closed")
    elif tkind == "mkt_bid":
        m.MarketBid.objects.filter(pk=t).update(content_status=status)
        if status == "removed":
            m.MarketBid.objects.filter(pk=t, status="active").update(status="withdrawn")
    elif tkind == "mkt_seller":
        if status == "removed":
            m.MarketSeller.objects.filter(user_id=t).update(status="suspended")
            m.MarketBid.objects.filter(seller_id=t, status="active").update(status="withdrawn")


def block(user, kind, tid):
    """Block the person behind a need / bid / seller / deal inside Market."""
    m = _m()
    tid = _int(tid)
    other = None
    if kind == "need":
        n = m.MarketNeed.objects.filter(pk=tid).first()
        other = n.buyer_id if n else None
    elif kind == "bid":
        b = m.MarketBid.objects.select_related("need").filter(pk=tid).first()
        if b and (b.need.buyer_id == user.pk or b.need.joins.filter(user=user).exists()):
            other = b.seller_id
    elif kind == "seller":
        other = tid if m.MarketSeller.objects.filter(user_id=tid).exists() else None
    elif kind == "deal":
        d = m.MarketDeal.objects.filter(pk=tid).first()
        if d and user.pk in (d.buyer_id, d.seller_id):
            other = d.seller_id if d.buyer_id == user.pk else d.buyer_id
    if not other or other == user.pk:
        return "not_found"
    m.MarketBlock.objects.get_or_create(user=user, blocked_id=other)
    # their pending bid on my open needs, and mine on theirs, stop counting
    m.MarketBid.objects.filter(seller_id=other, need__buyer=user, status="active").update(status="lost")
    m.MarketBid.objects.filter(seller=user, need__buyer_id=other, status="active").update(status="withdrawn")
    m.MarketJoin.objects.filter(user_id=other, need__buyer=user, need__status="open").delete()
    return None


def unblock_all(user):
    _m().MarketBlock.objects.filter(user=user).delete()
