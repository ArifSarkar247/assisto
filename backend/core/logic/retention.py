"""
retention.py — RETENTION AUTOMATION for a business's OWN customers (big-week
item H). PURE: no Django, no clock (callers pass `now`), no network.

Builds on what exists: the business AI agent (COD confirmation, 24 h follow-up,
courier) handles live chats; this module adds the SCHEDULED, owner-set
automations to people who already bought / are in the khata / asked:

  thanks_review  "thank you + review ask" N days after a purchase
  winback        "we miss you" after X days without a purchase
  khata_due      polite due-payment reminder (khata), every N days while due
  back_in_stock  a product a customer ASKED for is back in stock
  birthday       a wish on the birthday the customer gave the shop

Audience is ALWAYS the business's own records — never a purchased list, never
a stranger, no import endpoint exists. Caps / quiet hours / STOP / Meta rules
live in msg_guard (shared with booking).
"""
import re
from datetime import date, timedelta

from . import msg_guard as MG

KIND_THANKS = "thanks_review"
KIND_WINBACK = "winback"
KIND_KHATA = "khata_due"
KIND_STOCK = "back_in_stock"
KIND_BIRTHDAY = "birthday"
KINDS = (KIND_THANKS, KIND_WINBACK, KIND_KHATA, KIND_STOCK, KIND_BIRTHDAY)

CH_IN_APP = "in_app"
CH_WHATSAPP = "whatsapp"
CH_MESSENGER = "messenger"
CH_SMS = "sms"
CHANNELS = (CH_IN_APP, CH_WHATSAPP, CH_MESSENGER, CH_SMS)

MAX_TEMPLATE = 400
MAX_NAME = 80
SEND_HOUR_MIN, SEND_HOUR_MAX = 9, 20       # inside the 09:00-21:00 window
DEFAULT_SEND_HOUR = 11
MAX_AUTOMATIONS = 10                        # per business (server max)

# kind -> purpose (Meta template category), params {name: (min, max, default)},
# allowed template variables
CATALOG = {
    KIND_THANKS: {"purpose": MG.PURPOSE_MARKETING,
                  "params": {"days_after": (1, 30, 2)},
                  "vars": ("name", "shop", "product")},
    KIND_WINBACK: {"purpose": MG.PURPOSE_MARKETING,
                   "params": {"days_without": (14, 365, 45)},
                   "vars": ("name", "shop", "days")},
    KIND_KHATA: {"purpose": MG.PURPOSE_UTILITY,
                 "params": {"min_due_taka": (1, 1000000, 100), "every_days": (7, 60, 14)},
                 "vars": ("name", "shop", "due")},
    KIND_STOCK: {"purpose": MG.PURPOSE_MARKETING, "params": {},
                 "vars": ("name", "shop", "product")},
    KIND_BIRTHDAY: {"purpose": MG.PURPOSE_MARKETING, "params": {},
                    "vars": ("name", "shop")},
}

DEFAULT_TEMPLATES = {
    KIND_THANKS: ("{name}, {shop} থেকে কেনাকাটার জন্য ধন্যবাদ! {product} কেমন লাগল? "
                  "এক লাইনে জানালে আমরা আরও ভালো করতে পারব।",
                  "{name}, thank you for shopping at {shop}! How do you like the "
                  "{product}? One line from you helps us do better."),
    KIND_WINBACK: ("{name}, অনেক দিন দেখা হয়নি! {shop}-এ নতুন জিনিস এসেছে — "
                   "সময় পেলে একবার ঘুরে যাবেন।",
                   "{name}, we miss you! New things have arrived at {shop} — "
                   "drop by when you have time."),
    KIND_KHATA: ("{name}, {shop}-এর খাতায় আপনার ৳{due} বাকি আছে। সুবিধামতো সময়ে "
                 "পরিশোধ করলে কৃতজ্ঞ থাকব। ভুল মনে হলে জানাবেন।",
                 "{name}, a gentle note: ৳{due} is due in {shop}'s book. Please "
                 "pay when convenient. Tell us if this looks wrong."),
    KIND_STOCK: ("{name}, আপনি যে {product} চেয়েছিলেন সেটা {shop}-এ আবার এসেছে।",
                 "{name}, the {product} you asked for is back in stock at {shop}."),
    KIND_BIRTHDAY: ("শুভ জন্মদিন, {name}! {shop}-এর পক্ষ থেকে অনেক শুভেচ্ছা।",
                    "Happy birthday, {name}! Warm wishes from all of us at {shop}."),
}

_VAR_RE = re.compile(r"\{([a-zA-Z_]+)\}")


def _int(v, fb):
    try:
        return int(v)
    except (TypeError, ValueError):
        return fb


# ===================================================================== params / templates
def normalize_params(kind, raw):
    """Clamp the trigger params of `kind` (unknown keys dropped)."""
    spec = CATALOG[kind]["params"]
    r = raw if isinstance(raw, dict) else {}
    out = {}
    for k, (lo, hi, dflt) in spec.items():
        out[k] = max(lo, min(hi, _int(r.get(k), dflt)))
    return out


def template_problems(kind, text):
    """Codes for one template body. Empty body is allowed (the other
    language is then used)."""
    t = (text or "").strip()
    if not t:
        return []
    out = []
    if len(t) > MAX_TEMPLATE:
        out.append("template_too_long")
    allowed = set(CATALOG[kind]["vars"])
    for v in _VAR_RE.findall(t):
        if v not in allowed:
            out.append("unknown_variable")
            break
    return out


def validate(data, *, channels_ready=None):
    """Owner form -> (clean, problems). Pure. `channels_ready` = the channels
    this business can use today (in_app always)."""
    d = data if isinstance(data, dict) else {}
    problems = []
    kind = d.get("kind")
    if kind not in KINDS:
        return {}, ["bad_kind"]
    ch = d.get("channel") or CH_IN_APP
    if ch not in CHANNELS:
        problems.append("bad_channel")
    elif channels_ready is not None and ch not in channels_ready:
        problems.append("channel_not_connected")
    bn = (d.get("template_bn") or "").strip()
    en = (d.get("template_en") or "").strip()
    if not bn and not en:
        problems.append("template_required")
    problems += template_problems(kind, bn) + template_problems(kind, en)
    hour = _int(d.get("send_hour"), DEFAULT_SEND_HOUR)
    if not SEND_HOUR_MIN <= hour <= SEND_HOUR_MAX:
        problems.append("bad_send_hour")
    wt = d.get("wa_template") if isinstance(d.get("wa_template"), dict) else {}
    wa = {"name": str(wt.get("name") or "").strip()[:120],
          "lang": (str(wt.get("lang") or "bn").strip() or "bn")[:8],
          "category": str(wt.get("category") or "").strip().lower()[:16],
          "approved": bool(wt.get("approved")),
          "has_stop": bool(wt.get("has_stop"))}
    if ch == CH_WHATSAPP and wa["name"]:
        purpose = CATALOG[kind]["purpose"]
        if wa["category"] not in (MG.PURPOSE_MARKETING, MG.PURPOSE_UTILITY):
            problems.append("bad_template_category")
        elif purpose == MG.PURPOSE_MARKETING and wa["category"] == MG.PURPOSE_UTILITY:
            problems.append("promo_in_utility_template")
    clean = {"kind": kind, "channel": ch,
             "name": (str(d.get("name") or "").strip())[:MAX_NAME],
             "params": normalize_params(kind, d.get("params")),
             "template_bn": bn[:MAX_TEMPLATE], "template_en": en[:MAX_TEMPLATE],
             "send_hour": max(SEND_HOUR_MIN, min(SEND_HOUR_MAX, hour)),
             "wa_template": wa,
             "enabled": bool(d.get("enabled", False))}
    return clean, list(dict.fromkeys(problems))


def pick_template(lang, bn, en):
    if lang == "en":
        return en or bn
    return bn or en


def _bn_digits(s):
    return "".join(chr(0x09E6 + int(c)) if c.isdigit() else c for c in str(s))


def money_text(poisha, lang):
    taka = int(poisha or 0) // 100
    s = "{:,}".format(taka)
    return _bn_digits(s) if lang != "en" else s


def render(text, values, lang):
    """Fill {vars}; a missing value becomes a friendly word, never '{x}'."""
    fallback = {"name": "গ্রাহক" if lang != "en" else "customer",
                "product": "পণ্যটি" if lang != "en" else "item",
                "shop": "আমাদের দোকান" if lang != "en" else "our shop"}
    v = dict(values or {})

    def rep(m):
        k = m.group(1)
        val = v.get(k)
        if val in (None, ""):
            val = fallback.get(k, "")
        return str(val)
    out = _VAR_RE.sub(rep, text or "")
    return re.sub(r"\s{2,}", " ", out).strip()


def compose(text, values, lang, channel, link=""):
    """The full message: rendered body + the STOP footer (never removable)."""
    body = render(text, values, lang)
    return (body + "\n" + MG.stop_footer(lang, channel, link)).strip()


def sms_segments(text):
    """GSM-7 160/153, Unicode (Bangla) 70/67 per part."""
    t = text or ""
    uni = any(ord(c) > 127 for c in t)
    single, multi = (70, 67) if uni else (160, 153)
    n = len(t)
    if n <= single:
        return 1
    return -(-n // multi)


# ===================================================================== triggers
def due_thanks(sales, now, days_after):
    """sales: [{sale_id, key, at, product}] (latest per customer is enough).
    A sale becomes due `days_after` days later and stays due 3 days (a cap
    may delay it), never later."""
    out = []
    for s in sales:
        age = now - s["at"]
        if timedelta(days=days_after) <= age < timedelta(days=days_after + 3):
            out.append({"key": s["key"], "ref": "sale:%s" % s["sale_id"],
                        "values": {"product": s.get("product") or ""}})
    return out


def due_winback(last_sales, now, days_without):
    """last_sales: [{key, last_sale_id, at}] = each customer's LATEST sale.
    One message per lapse (ref = that sale), only for customers who lapsed
    within the last year (older ones are not "our customer" any more)."""
    out = []
    for s in last_sales:
        age = (now - s["at"]).days
        if days_without <= age <= 365:
            out.append({"key": s["key"], "ref": "wb:%s" % s["last_sale_id"],
                        "values": {"days": age}})
    return out


def due_khata(parties, now, min_due_taka, every_days):
    """parties: [{party_id, key, due_poisha}] (due = customer owes the shop).
    One polite reminder per `every_days` bucket while the due stands."""
    out = []
    bucket = MG.local(now).date().toordinal() // max(1, every_days)
    for p in parties:
        if p["due_poisha"] >= min_due_taka * 100:
            out.append({"key": p["key"], "ref": "due:%s:%s" % (p["party_id"], bucket),
                        "values": {"due_poisha": p["due_poisha"]}})
    return out


def _bday_this_year(bd, year):
    try:
        return date(year, bd.month, bd.day)
    except ValueError:            # 29 Feb in a non-leap year
        return date(year, 2, 28)


def due_birthday(customers, now):
    """customers: [{key, birthday(date)}] -> due on the local birthday."""
    today = MG.local(now).date()
    out = []
    for c in customers:
        bd = c.get("birthday")
        if bd and _bday_this_year(bd, today.year) == today:
            out.append({"key": c["key"], "ref": "bday:%s" % today.year, "values": {}})
    return out


def due_stock(asks):
    """asks: [{ask_id, key, product, in_stock, notified}]"""
    return [{"key": a["key"], "ref": "stock:%s" % a["ask_id"],
             "values": {"product": a.get("product") or ""}}
            for a in asks if a.get("in_stock") and not a.get("notified")]


# ===================================================================== attribution
def attribute(sends, sales, window_days):
    """Honest last-touch attribution. sends: [{id, key, at}], sales:
    [{id, key, at, total}]. A sale counts for the LATEST send to that same
    customer before it, inside `window_days`; each sale once, each send at
    most its first sale. Returns {send_id: (sale_id, total)}."""
    by_key = {}
    for s in sorted(sends, key=lambda x: x["at"]):
        by_key.setdefault(s["key"], []).append(s)
    out = {}
    for sale in sorted(sales, key=lambda x: x["at"]):
        cands = [s for s in by_key.get(sale["key"], ())
                 if s["at"] < sale["at"] <= s["at"] + timedelta(days=window_days)]
        if not cands:
            continue
        s = cands[-1]
        if s["id"] in out:
            continue
        out[s["id"]] = (sale["id"], sale["total"])
    return out


def mask_phone(key):
    k = key or ""
    if k.startswith("psid:") or len(k) < 6:
        return "•••"
    return k[:3] + "•" * (len(k) - 6) + k[-3:]
