"""
world_feeds.py — the PURE side of Unseen World's "Today" cards (p4-world).

No Django, no DB, no network, no wall clock: callers pass raw bytes / dicts
and `now`. core/world_service.py fetches, caches and calls these.

Source policy (see .phaseB/P4_PLAN.md §3):
  * NEWS — only publishers' OWN official RSS feeds. We keep the headline, the
    feed's OWN short summary (`description` / `summary`, HTML stripped, cut to
    200 characters) and the link. We never read `content:encoded` (the full
    article) and never fetch the article page. An empty summary stays empty.
  * WEATHER — MET Norway Locationforecast 2.0 (CC BY 4.0; attribution shown).
  * CURRENCY — ExchangeRate-API open access (attribution link shown).
  * PRAYER — computed locally with core/logic/ramadan.prayer_times.
  * GOLD / FUEL — owner-entered (no official API), labelled as such.
  * SPORTS — licensed APIs only (API-Football, CricketData.org), key-gated.
"""
import html
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

SNIPPET_MAX = 200
USER_AGENT = "AssistoBot/1.0 (+https://lifeassisto.com; support@lifeassisto.com)"

# ------------------------------------------------------------------ cards
# Card ids (stable; the app maps them to titles/icons). Default on/off.
CARDS = ("prayer", "weather", "currency", "gold", "fuel", "news_bd",
         "news_world", "cricket", "football")
DEFAULT_ON = {c: True for c in CARDS}


def merge_cards(stored):
    """User's stored {card: bool} over the defaults; unknown keys dropped."""
    out = dict(DEFAULT_ON)
    for k, v in (stored or {}).items():
        if k in out and isinstance(v, bool):
            out[k] = v
    return out


# ------------------------------------------------------------------ cities
# Division HQs + large cities. Coordinates truncated to 4 decimals (MET rule).
CITIES = [
    ("dhaka", "ঢাকা", "Dhaka", 23.8103, 90.4125),
    ("chattogram", "চট্টগ্রাম", "Chattogram", 22.3569, 91.7832),
    ("sylhet", "সিলেট", "Sylhet", 24.8949, 91.8687),
    ("khulna", "খুলনা", "Khulna", 22.8456, 89.5403),
    ("rajshahi", "রাজশাহী", "Rajshahi", 24.3745, 88.6042),
    ("barishal", "বরিশাল", "Barishal", 22.7010, 90.3535),
    ("rangpur", "রংপুর", "Rangpur", 25.7439, 89.2752),
    ("mymensingh", "ময়মনসিংহ", "Mymensingh", 24.7471, 90.4203),
    ("cumilla", "কুমিল্লা", "Cumilla", 23.4607, 91.1809),
    ("gazipur", "গাজীপুর", "Gazipur", 23.9999, 90.4203),
    ("narayanganj", "নারায়ণগঞ্জ", "Narayanganj", 23.6238, 90.5000),
    ("coxsbazar", "কক্সবাজার", "Cox's Bazar", 21.4272, 92.0058),
    ("bogura", "বগুড়া", "Bogura", 24.8465, 89.3773),
    ("jashore", "যশোর", "Jashore", 23.1664, 89.2081),
    ("dinajpur", "দিনাজপুর", "Dinajpur", 25.6217, 88.6355),
    ("noakhali", "নোয়াখালী", "Noakhali", 22.8696, 91.0995),
    ("faridpur", "ফরিদপুর", "Faridpur", 23.6070, 89.8429),
    ("tangail", "টাঙ্গাইল", "Tangail", 24.2513, 89.9167),
]
_CITY = {c[0]: c for c in CITIES}


def city(slug):
    return _CITY.get(slug) or _CITY["dhaka"]


def cities_public(lang):
    return [{"id": c[0], "name": c[1] if lang == "bn" else c[2]} for c in CITIES]


# ------------------------------------------------------------------ news
# Official publisher RSS feeds. `on` = shipped default. Daily Star is OFF
# because its public feed was stale at review time (2026-10-23).
NEWS_FEEDS = [
    {"slug": "news_bbc_bangla", "group": "bd", "lang": "bn", "name_bn": "বিবিসি বাংলা",
     "name_en": "BBC Bangla", "url": "https://feeds.bbci.co.uk/bengali/rss.xml", "on": True},
    {"slug": "news_prothomalo", "group": "bd", "lang": "bn", "name_bn": "প্রথম আলো",
     "name_en": "Prothom Alo", "url": "https://www.prothomalo.com/feed/", "on": True},
    {"slug": "news_prothomalo_en", "group": "bd", "lang": "en", "name_bn": "প্রথম আলো (ইংরেজি)",
     "name_en": "Prothom Alo English", "url": "https://en.prothomalo.com/feed/", "on": True},
    {"slug": "news_dailystar", "group": "bd", "lang": "en", "name_bn": "দ্য ডেইলি স্টার",
     "name_en": "The Daily Star", "url": "https://www.thedailystar.net/frontpage/rss.xml", "on": False},
    {"slug": "news_bbc_world", "group": "world", "lang": "en", "name_bn": "বিবিসি নিউজ (বিশ্ব)",
     "name_en": "BBC News (World)", "url": "https://feeds.bbci.co.uk/news/world/rss.xml", "on": True},
    {"slug": "news_aljazeera", "group": "world", "lang": "en", "name_bn": "আল জাজিরা",
     "name_en": "Al Jazeera", "url": "https://www.aljazeera.com/xml/rss/all.xml", "on": True},
]
NEWS_BY_SLUG = {f["slug"]: f for f in NEWS_FEEDS}
NEWS_MAX_AGE_H = 48          # older items are hidden (stale feeds show nothing)
NEWS_PER_FEED = 8

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")
_ENTITY_RE = re.compile(r"&([A-Za-z][A-Za-z0-9]*);")
_XML_ENTITIES = {"amp", "lt", "gt", "quot", "apos"}


def clean_text(raw):
    """HTML -> plain one-line text."""
    t = html.unescape(_TAG_RE.sub(" ", raw or ""))
    return _WS_RE.sub(" ", t).strip()


def clamp_snippet(raw, limit=SNIPPET_MAX):
    """The feed's own summary, plain text, at most `limit` characters, cut on
    a word boundary with an ellipsis. Never longer than `limit`."""
    t = clean_text(raw)
    if len(t) <= limit:
        return t
    cut = t[:limit - 1]
    sp = cut.rfind(" ")
    if sp > limit * 0.6:
        cut = cut[:sp]
    return cut.rstrip(" ,;:-") + "…"


def _fix_entities(text):
    """Feeds sometimes carry HTML named entities (&nbsp;, &rsquo;) that XML
    does not define — turn them into characters so the parser survives."""
    def rep(m):
        name = m.group(1)
        if name in _XML_ENTITIES:
            return m.group(0)
        ch = html.unescape(m.group(0))
        if ch == m.group(0):
            return ""
        return {"&": "&amp;", "<": "&lt;", ">": "&gt;"}.get(ch, ch)
    return _ENTITY_RE.sub(rep, text)


def _local(tag):
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _child_text(el, *names):
    for c in el:
        if _local(c.tag) in names:
            if _local(c.tag) == "link" and c.get("href"):
                return c.get("href")
            if c.text and c.text.strip():
                return c.text.strip()
    return ""


def parse_date(raw):
    """RFC-822 (RSS) or ISO-8601 (Atom) -> aware UTC datetime, or None."""
    s = (raw or "").strip()
    if not s:
        return None
    from email.utils import parsedate_to_datetime
    try:
        d = parsedate_to_datetime(s)
        if d is not None:
            if d.tzinfo is None:
                d = d.replace(tzinfo=timezone.utc)
            # "01 Jun 26" (2-digit year) parses as year 26 — fix the century
            if d.year < 100:
                d = d.replace(year=d.year + 2000)
            return d.astimezone(timezone.utc)
    except (TypeError, ValueError, IndexError):
        pass
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d.astimezone(timezone.utc)
    except ValueError:
        return None


class FeedError(Exception):
    pass


def parse_rss(raw_bytes, source_name="", limit=NEWS_PER_FEED):
    """RSS 2.0 / Atom bytes -> [{title, snippet, link, published, source}].

    Only headline + the feed's own summary + link. `content:encoded` and any
    other full-text element are IGNORED by design."""
    if not raw_bytes:
        raise FeedError("empty response")
    text = raw_bytes.decode("utf-8", errors="replace") if isinstance(raw_bytes, bytes) else str(raw_bytes)
    head = text.lstrip()[:200].lower()
    if head.startswith("<!doctype html") or head.startswith("<html"):
        raise FeedError("not a feed (HTML page)")
    try:
        root = ET.fromstring(_fix_entities(text).encode("utf-8"))
    except ET.ParseError as e:
        raise FeedError("bad XML: %s" % e)
    items = [el for el in root.iter() if _local(el.tag) in ("item", "entry")]
    out, seen = [], set()
    for it in items:
        title = clean_text(_child_text(it, "title"))
        link = _child_text(it, "link")
        if not title or not link.startswith(("http://", "https://")):
            continue
        if link in seen:
            continue
        seen.add(link)
        summary = _child_text(it, "description", "summary")
        out.append({
            "title": title[:240],
            "snippet": clamp_snippet(summary),
            "link": link[:600],
            "published": (lambda d: d.isoformat() if d else "")(
                parse_date(_child_text(it, "pubDate", "published", "updated", "date"))),
            "source": source_name,
        })
        if len(out) >= limit:
            break
    if not out and not items:
        raise FeedError("no items")
    return out


def fresh_items(items, now, max_age_h=NEWS_MAX_AGE_H):
    """Drop items older than max_age_h (an undated item is kept only if the
    feed was fetched within that window — callers pass fetch-time items)."""
    cutoff = now - timedelta(hours=max_age_h)
    keep = []
    for it in items or []:
        d = parse_date(it.get("published"))
        if d is None or d >= cutoff:
            keep.append(it)
    return keep


def news_card(feeds_payloads, group, now, per_card=10):
    """Merge fresh items of every enabled feed in a group, newest first."""
    merged = []
    for slug, items in feeds_payloads:
        meta = NEWS_BY_SLUG.get(slug)
        if not meta or meta["group"] != group:
            continue
        merged.extend(fresh_items(items, now))
    merged.sort(key=lambda it: parse_date(it.get("published")) or now, reverse=True)
    return merged[:per_card]


# ------------------------------------------------------------------ weather
# MET Norway symbol codes -> (bn, en, icon). The suffix _day/_night/_polartwilight
# is dropped before lookup.
_SYMBOLS = {
    "clearsky": ("পরিষ্কার আকাশ", "Clear sky", "sun"),
    "fair": ("মোটামুটি পরিষ্কার", "Fair", "sun"),
    "partlycloudy": ("আংশিক মেঘলা", "Partly cloudy", "cloud_sun"),
    "cloudy": ("মেঘলা", "Cloudy", "cloud"),
    "fog": ("কুয়াশা", "Fog", "fog"),
    "lightrain": ("হালকা বৃষ্টি", "Light rain", "rain"),
    "rain": ("বৃষ্টি", "Rain", "rain"),
    "heavyrain": ("ভারী বৃষ্টি", "Heavy rain", "rain"),
    "lightrainshowers": ("হালকা বৃষ্টির ঝাপটা", "Light showers", "rain"),
    "rainshowers": ("বৃষ্টির ঝাপটা", "Showers", "rain"),
    "heavyrainshowers": ("ভারী বৃষ্টির ঝাপটা", "Heavy showers", "rain"),
    "rainandthunder": ("বজ্রসহ বৃষ্টি", "Rain and thunder", "storm"),
    "lightrainandthunder": ("বজ্রসহ হালকা বৃষ্টি", "Light rain and thunder", "storm"),
    "heavyrainandthunder": ("বজ্রসহ ভারী বৃষ্টি", "Heavy rain and thunder", "storm"),
    "rainshowersandthunder": ("বজ্রসহ বৃষ্টির ঝাপটা", "Showers and thunder", "storm"),
    "lightrainshowersandthunder": ("বজ্রসহ হালকা ঝাপটা", "Light showers and thunder", "storm"),
    "heavyrainshowersandthunder": ("বজ্রসহ ভারী ঝাপটা", "Heavy showers and thunder", "storm"),
}


def symbol_label(code, lang):
    base = (code or "").split("_")[0]
    bn, en, icon = _SYMBOLS.get(base, ("আবহাওয়া", "Weather", "cloud"))
    return (bn if lang == "bn" else en), icon


def parse_met(doc):
    """MET Norway compact JSON -> {now:{temp, humidity, wind, symbol}, next:[...6 h steps], updated}.
    Raises FeedError on an unexpected shape."""
    try:
        ts = doc["properties"]["timeseries"]
        first = ts[0]
    except (KeyError, IndexError, TypeError):
        raise FeedError("unexpected weather payload")
    det = first["data"]["instant"]["details"]
    nxt = first["data"].get("next_1_hours") or first["data"].get("next_6_hours") or {}
    sym = (nxt.get("summary") or {}).get("symbol_code", "")
    rain = (nxt.get("details") or {}).get("precipitation_amount")
    steps = []
    for row in ts[1:]:
        d = row.get("data") or {}
        n6 = d.get("next_6_hours")
        if not n6:
            continue
        t = parse_date(row.get("time"))
        if t and t.hour % 6 == 0:
            steps.append({"time": row["time"],
                          "temp": (d.get("instant") or {}).get("details", {}).get("air_temperature"),
                          "symbol": (n6.get("summary") or {}).get("symbol_code", ""),
                          "rain_mm": (n6.get("details") or {}).get("precipitation_amount")})
        if len(steps) >= 4:
            break
    return {"time": first.get("time", ""),
            "temp": det.get("air_temperature"),
            "humidity": det.get("relative_humidity"),
            "wind": det.get("wind_speed"),
            "symbol": sym, "rain_mm": rain, "next": steps,
            "updated": (doc.get("properties", {}).get("meta") or {}).get("updated_at", "")}


def weather_public(payload, lang):
    if not payload or payload.get("temp") is None:
        return None
    label, icon = symbol_label(payload.get("symbol"), lang)
    nxt = []
    for s in payload.get("next") or []:
        lb, ic = symbol_label(s.get("symbol"), lang)
        nxt.append({"time": s.get("time"), "temp": s.get("temp"), "label": lb,
                    "icon": ic, "rain_mm": s.get("rain_mm")})
    return {"temp": payload.get("temp"), "humidity": payload.get("humidity"),
            "wind": payload.get("wind"), "rain_mm": payload.get("rain_mm"),
            "label": label, "icon": icon, "next": nxt,
            "updated": payload.get("updated") or payload.get("time"),
            "source": "MET Norway (CC BY 4.0)", "source_url": "https://api.met.no/"}


# ------------------------------------------------------------------ currency
# Currencies that matter to Bangladeshi families + expats (BDT per 1 unit).
FX_CODES = ("USD", "SAR", "AED", "QAR", "OMR", "KWD", "MYR", "SGD", "GBP", "EUR", "INR")
FX_NAMES = {
    "USD": ("মার্কিন ডলার", "US dollar"), "SAR": ("সৌদি রিয়াল", "Saudi riyal"),
    "AED": ("আমিরাত দিরহাম", "UAE dirham"), "QAR": ("কাতারি রিয়াল", "Qatari riyal"),
    "OMR": ("ওমানি রিয়াল", "Omani rial"), "KWD": ("কুয়েতি দিনার", "Kuwaiti dinar"),
    "MYR": ("মালয়েশিয়ান রিংগিত", "Malaysian ringgit"), "SGD": ("সিঙ্গাপুর ডলার", "Singapore dollar"),
    "GBP": ("ব্রিটিশ পাউন্ড", "British pound"), "EUR": ("ইউরো", "Euro"), "INR": ("ভারতীয় রুপি", "Indian rupee"),
}


def parse_fx(doc):
    """ExchangeRate-API open payload (base USD) -> {rates:{CODE: BDT per 1}, updated}."""
    if not isinstance(doc, dict) or doc.get("result") != "success":
        raise FeedError("currency feed returned no data")
    rates = doc.get("rates") or {}
    bdt = rates.get("BDT")
    if not bdt:
        raise FeedError("no BDT rate")
    out = {}
    for c in FX_CODES:
        r = rates.get(c)
        if r:
            out[c] = round(float(bdt) / float(r), 2)
    upd = parse_date(doc.get("time_last_update_utc", ""))
    return {"rates": out, "updated": upd.isoformat() if upd else ""}


def fx_public(payload, lang):
    if not payload or not payload.get("rates"):
        return None
    rows = [{"code": c, "name": FX_NAMES[c][0 if lang == "bn" else 1],
             "bdt": payload["rates"][c]} for c in FX_CODES if c in payload["rates"]]
    return {"rows": rows, "updated": payload.get("updated", ""),
            "source": "ExchangeRate-API", "source_url": "https://www.exchangerate-api.com",
            "note_bn": "বাজার দরের নির্দেশক হার — ব্যাংক/মানি এক্সচেঞ্জের হার আলাদা হতে পারে।",
            "note_en": "Indicative market rate — bank and exchange-house rates differ."}


# ------------------------------------------------------------------ gold / fuel
ADMIN_VALUES = {
    "gold_22k": ("২২ ক্যারেট সোনা (প্রতি ভরি)", "Gold 22K (per bhori)", "gold"),
    "gold_21k": ("২১ ক্যারেট সোনা (প্রতি ভরি)", "Gold 21K (per bhori)", "gold"),
    "gold_18k": ("১৮ ক্যারেট সোনা (প্রতি ভরি)", "Gold 18K (per bhori)", "gold"),
    "gold_trad": ("সনাতন পদ্ধতির সোনা (প্রতি ভরি)", "Gold traditional (per bhori)", "gold"),
    "silver_22k": ("২২ ক্যারেট রুপা (প্রতি ভরি)", "Silver 22K (per bhori)", "gold"),
    "fuel_octane": ("অকটেন (প্রতি লিটার)", "Octane (per litre)", "fuel"),
    "fuel_petrol": ("পেট্রোল (প্রতি লিটার)", "Petrol (per litre)", "fuel"),
    "fuel_diesel": ("ডিজেল (প্রতি লিটার)", "Diesel (per litre)", "fuel"),
    "fuel_kerosene": ("কেরোসিন (প্রতি লিটার)", "Kerosene (per litre)", "fuel"),
    "lpg_12kg": ("এলপিজি ১২ কেজি সিলিন্ডার", "LPG 12 kg cylinder", "fuel"),
}
ADMIN_SOURCES = {
    "gold": ("বাংলাদেশ জুয়েলার্স অ্যাসোসিয়েশন (বাজুস)", "Bangladesh Jewellers Association (BAJUS)",
             "https://www.bajus.org/gold-price"),
    "fuel": ("বাংলাদেশ পেট্রোলিয়াম কর্পোরেশন (বিপিসি) / বিইআরসি", "Bangladesh Petroleum Corporation (BPC) / BERC",
             "https://bpc.gov.bd"),
}


def admin_card(group, rows, lang):
    """rows: [{key, value, effective_date, updated_at}] -> card or None when
    the owner has never entered a value (the card is then hidden)."""
    items = []
    latest = None
    for r in rows:
        meta = ADMIN_VALUES.get(r.get("key"))
        if not meta or meta[2] != group or r.get("value") in (None, ""):
            continue
        items.append({"key": r["key"], "label": meta[0 if lang == "bn" else 1],
                      "bdt": float(r["value"])})
        d = r.get("effective_date") or r.get("updated_at") or ""
        latest = max(latest or d, d)
    if not items:
        return None
    src = ADMIN_SOURCES[group]
    return {"rows": items, "updated": latest or "",
            "source": src[0 if lang == "bn" else 1], "source_url": src[2],
            "entered_by_assisto": True}


# ------------------------------------------------------------------ sports
def parse_football(doc):
    """API-Football /fixtures?live=all -> [{home, away, score, minute, league}]."""
    if not isinstance(doc, dict):
        raise FeedError("unexpected football payload")
    errs = doc.get("errors")
    if errs and (isinstance(errs, dict) and errs or isinstance(errs, list) and errs):
        raise FeedError("provider error: %s" % str(errs)[:120])
    out = []
    for f in doc.get("response") or []:
        try:
            out.append({"home": f["teams"]["home"]["name"], "away": f["teams"]["away"]["name"],
                        "score": "%s-%s" % (f["goals"]["home"] if f["goals"]["home"] is not None else 0,
                                            f["goals"]["away"] if f["goals"]["away"] is not None else 0),
                        "minute": (f.get("fixture") or {}).get("status", {}).get("elapsed"),
                        "status": (f.get("fixture") or {}).get("status", {}).get("short", ""),
                        "league": (f.get("league") or {}).get("name", "")})
        except (KeyError, TypeError):
            continue
    return out[:12]


def parse_cricket(doc):
    """CricketData.org /v1/currentMatches -> [{name, status, score, live}]."""
    if not isinstance(doc, dict) or doc.get("status") != "success":
        raise FeedError("cricket provider: %s" % (doc.get("reason") if isinstance(doc, dict) else "bad payload"))
    out = []
    for m in doc.get("data") or []:
        scores = []
        for s in m.get("score") or []:
            scores.append("%s %s/%s (%s)" % (s.get("inning", ""), s.get("r", 0), s.get("w", 0), s.get("o", 0)))
        out.append({"name": m.get("name", ""), "status": m.get("status", ""),
                    "score": "; ".join(scores)[:200],
                    "live": bool(m.get("matchStarted")) and not bool(m.get("matchEnded"))})
    out.sort(key=lambda m: not m["live"])
    return out[:12]


# ------------------------------------------------------------------ prayer
PRAYER_KEYS = ("fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha")


def prayer_card(times, now_hhmm):
    """ramadan.prayer_times() dict -> {times:{...}, next:key}."""
    t = {k: times.get(k) for k in PRAYER_KEYS if times.get(k)}
    nxt = ""
    for k in ("fajr", "dhuhr", "asr", "maghrib", "isha"):
        if t.get(k) and t[k] > now_hhmm:
            nxt = k
            break
    return {"times": t, "next": nxt or "fajr", "method": "Karachi (University of Islamic Sciences)",
            "note_bn": "স্থানীয় হিসাব — আপনার মসজিদের সময়ের সাথে কয়েক মিনিট পার্থক্য হতে পারে।",
            "note_en": "Local calculation — may differ by a few minutes from your mosque."}
