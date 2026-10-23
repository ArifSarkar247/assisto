"""
bizagent.py — P1 ASSISTO BUSINESS AI AGENT (F-commerce sellers): PURE logic.

No Django, no network, no clock (callers pass `now`). Builds on
core.logic.business_ai (language detection, intents, handoff triggers,
negotiate() with the min price enforced in code, 24h window, channel guard)
and keeps its HARD CONSTRAINTS:

 1. Prices / stock / delivery charges come ONLY from the seller's catalog and
    settings. Every AI draft is POST-CHECKED (check_numbers): a money or stock
    number that is not in the catalog facts BLOCKS the draft (it goes to the
    seller's approval queue, the customer gets an honest holding line).
 2. Official channels only: Messenger Platform, Instagram Messaging, WhatsApp
    Business Cloud API. Never a personal WhatsApp.
 3. We never hold money. Payment = cash on delivery, or a payment LINK from a
    licensed partner (see business_ai.payment_link_builder).
 4. The AI never claims to be human (disclosure line on the first AI reply of a
    thread and whenever the customer asks).
 5. Nothing is unlimited: replies come from a seller plan (monthly AI replies,
    admin-editable) or from purchased credits; out of both = the AI stops and
    the customer is told a person will reply (never silent).

All user-facing text is bn/en via pick(lang, bn, en).
"""
import hashlib
import hmac
import json
import math
import re
from decimal import Decimal, InvalidOperation

from . import business_ai as bai

pick = bai.pick

# ---------------------------------------------------------------- constants
CH_MESSENGER = "messenger"
CH_INSTAGRAM = "instagram"
CH_WHATSAPP = "whatsapp_cloud"
CHANNELS = (CH_MESSENGER, CH_INSTAGRAM, CH_WHATSAPP)

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def norm_digits(s):
    return (s or "").translate(_BN_DIGITS)


def _dec(v):
    if v is None or v == "":
        return None
    try:
        return Decimal(str(v).replace(",", "").replace("৳", "").strip())
    except (InvalidOperation, ValueError):
        return None


def _fmt_money(v):
    d = _dec(v) or Decimal(0)
    if d == d.to_integral_value():
        return str(int(d))
    return str(d.quantize(Decimal("0.01")))


# =========================================================================
# 1. WEBHOOK SIGNATURE (Meta: X-Hub-Signature-256 = "sha256=<hex hmac>")
# =========================================================================

def sign(app_secret, raw_body):
    """The header value Meta would send for `raw_body` (bytes)."""
    mac = hmac.new((app_secret or "").encode(), raw_body or b"", hashlib.sha256)
    return "sha256=" + mac.hexdigest()


def verify_signature(app_secret, raw_body, header):
    """Constant-time check of X-Hub-Signature-256. False when the secret or the
    header is missing — an unsigned POST is never processed."""
    if not app_secret or not header or not isinstance(header, str):
        return False
    if not header.startswith("sha256="):
        return False
    return hmac.compare_digest(sign(app_secret, raw_body), header.strip())


def verify_handshake(params, verify_token):
    """GET hub.mode=subscribe&hub.verify_token=..&hub.challenge=.. →
    the challenge string, or None (refuse)."""
    if not verify_token:
        return None
    if params.get("hub.mode") != "subscribe":
        return None
    if not hmac.compare_digest(str(params.get("hub.verify_token") or ""),
                               str(verify_token)):
        return None
    return str(params.get("hub.challenge") or "")


# =========================================================================
# 2. WEBHOOK PARSING → normalized events
# =========================================================================
# Every event: {source, channel, kind, account_id, user_id, event_id, text,
#               ts, name, comment_id, post_id, status, raw}
#   kind ∈ message | echo | postback | comment | status
#   account_id = page id (Messenger), IG professional account id (Instagram),
#                phone_number_id (WhatsApp) → selects the seller's channel row.

def _ev(**kw):
    base = {"source": "meta", "channel": "", "kind": "", "account_id": "",
            "user_id": "", "event_id": "", "text": "", "ts": 0, "name": "",
            "comment_id": "", "post_id": "", "status": "", "raw": {}, "attachments": []}
    base.update(kw)
    return base


def _messaging_events(entry, channel):
    out = []
    acct = str(entry.get("id") or "")
    for m in entry.get("messaging") or []:
        sender = str((m.get("sender") or {}).get("id") or "")
        recipient = str((m.get("recipient") or {}).get("id") or "")
        ts = int(m.get("timestamp") or entry.get("time") or 0)
        if ts > 10 ** 11:          # Meta sends ms
            ts //= 1000
        msg = m.get("message")
        if isinstance(msg, dict):
            mid = str(msg.get("mid") or "")
            if not mid:
                continue
            text = msg.get("text") or ""
            atts = []
            for a in msg.get("attachments") or []:
                if not isinstance(a, dict):
                    continue
                typ = str(a.get("type") or "")
                url = str((a.get("payload") or {}).get("url") or "")
                if typ in ("image", "audio") and url:
                    # data: URLs only work on self-test channels (checked later)
                    atts.append({"type": typ, "url": url[:1_500_000]})
            if not text and msg.get("attachments"):
                text = "[attachment]"
            if msg.get("is_echo"):
                # echo of a page-sent message: user is the RECIPIENT
                out.append(_ev(channel=channel, kind="echo",
                               account_id=sender or acct, user_id=recipient,
                               event_id=mid, text=text, ts=ts,
                               raw={"app_id": msg.get("app_id")}))
            else:
                out.append(_ev(channel=channel, kind="message",
                               account_id=recipient or acct, user_id=sender,
                               event_id=mid, text=text, ts=ts, attachments=atts))
            continue
        pb = m.get("postback")
        if isinstance(pb, dict):
            mid = str(pb.get("mid") or "pb-%s-%s" % (sender, ts))
            out.append(_ev(channel=channel, kind="postback",
                           account_id=recipient or acct, user_id=sender,
                           event_id=mid, text=pb.get("title") or pb.get("payload") or "",
                           ts=ts))
    return out


def parse_meta(payload):
    """Messenger (object=page) + Instagram (object=instagram) webhooks."""
    events = []
    if not isinstance(payload, dict):
        return events
    obj = payload.get("object")
    if obj not in ("page", "instagram"):
        return events
    channel = CH_MESSENGER if obj == "page" else CH_INSTAGRAM
    for entry in payload.get("entry") or []:
        if not isinstance(entry, dict):
            continue
        acct = str(entry.get("id") or "")
        events.extend(_messaging_events(entry, channel))
        for ch in entry.get("changes") or []:
            field = ch.get("field")
            v = ch.get("value") or {}
            if obj == "page" and field == "feed" and v.get("item") == "comment" \
                    and v.get("verb") == "add":
                frm = v.get("from") or {}
                cid = str(v.get("comment_id") or "")
                if not cid:
                    continue
                events.append(_ev(channel=CH_MESSENGER, kind="comment",
                                  account_id=acct, user_id=str(frm.get("id") or ""),
                                  name=frm.get("name") or "", event_id="c-" + cid,
                                  comment_id=cid, post_id=str(v.get("post_id") or ""),
                                  text=v.get("message") or "",
                                  ts=int(v.get("created_time") or entry.get("time") or 0)))
            elif obj == "instagram" and field == "comments":
                frm = v.get("from") or {}
                cid = str(v.get("id") or "")
                if not cid:
                    continue
                events.append(_ev(channel=CH_INSTAGRAM, kind="comment",
                                  account_id=acct, user_id=str(frm.get("id") or ""),
                                  name=frm.get("username") or "", event_id="c-" + cid,
                                  comment_id=cid,
                                  post_id=str((v.get("media") or {}).get("id") or ""),
                                  text=v.get("text") or "",
                                  ts=int(entry.get("time") or 0)))
    return events


def parse_whatsapp(payload):
    """WhatsApp Cloud API webhook (object=whatsapp_business_account):
    inbound messages + delivery statuses (with pricing/conversation info)."""
    events = []
    if not isinstance(payload, dict) or payload.get("object") != "whatsapp_business_account":
        return events
    for entry in payload.get("entry") or []:
        for ch in (entry or {}).get("changes") or []:
            if ch.get("field") != "messages":
                continue
            v = ch.get("value") or {}
            pnid = str((v.get("metadata") or {}).get("phone_number_id") or "")
            names = {str(c.get("wa_id")): (c.get("profile") or {}).get("name") or ""
                     for c in v.get("contacts") or []}
            for m in v.get("messages") or []:
                wamid = str(m.get("id") or "")
                if not wamid:
                    continue
                typ = m.get("type")
                if typ == "text":
                    text = (m.get("text") or {}).get("body") or ""
                elif typ == "button":
                    text = (m.get("button") or {}).get("text") or ""
                elif typ == "interactive":
                    it = m.get("interactive") or {}
                    text = ((it.get("button_reply") or it.get("list_reply") or {})
                            .get("title") or "")
                else:
                    text = "[%s]" % (typ or "message")
                atts = []
                if typ in ("image", "audio") and isinstance(m.get(typ), dict):
                    media = m[typ]
                    att = {"type": typ, "media_id": str(media.get("id") or ""),
                           "mime": str(media.get("mime_type") or "")}
                    if media.get("link"):          # self-test payloads (test channels only)
                        att["url"] = str(media["link"])[:1_500_000]
                    if att["media_id"] or att.get("url"):
                        atts.append(att)
                    if typ == "image" and media.get("caption"):
                        text = str(media["caption"])
                frm = str(m.get("from") or "")
                events.append(_ev(source="whatsapp", channel=CH_WHATSAPP,
                                  kind="message", account_id=pnid, user_id=frm,
                                  name=names.get(frm, ""), event_id=wamid, text=text,
                                  ts=int(m.get("timestamp") or 0), attachments=atts))
            for s in v.get("statuses") or []:
                wamid = str(s.get("id") or "")
                st = str(s.get("status") or "")
                if not wamid or not st:
                    continue
                errs = s.get("errors") or []
                events.append(_ev(source="whatsapp", channel=CH_WHATSAPP,
                                  kind="status", account_id=pnid,
                                  user_id=str(s.get("recipient_id") or ""),
                                  event_id="%s:%s" % (wamid, st), status=st,
                                  ts=int(s.get("timestamp") or 0),
                                  raw={"wamid": wamid,
                                       "pricing": s.get("pricing") or {},
                                       "conversation": s.get("conversation") or {},
                                       "error": (errs[0].get("title") or errs[0].get("message")
                                                 or "") if errs else ""}))
    return events


def wa_billable(status_event):
    """From a WhatsApp status event → (billable, category, dedupe_key) or None.
    Works for both Meta pricing models: per-conversation (CBP, dedupe by the
    conversation id) and per-message (PMP, dedupe by the message id). Only the
    first 'sent' status is considered (Meta repeats pricing on later ones)."""
    if status_event.get("kind") != "status" or status_event.get("status") != "sent":
        return None
    raw = status_event.get("raw") or {}
    pr = raw.get("pricing") or {}
    if not pr or not pr.get("billable"):
        return None
    cat = str(pr.get("category") or "service").lower()
    conv = (raw.get("conversation") or {}).get("id") or ""
    model = str(pr.get("pricing_model") or "").upper()
    key = ("conv:" + conv) if (conv and model == "CBP") else ("msg:" + raw.get("wamid", ""))
    return (True, cat, key)


# =========================================================================
# 3. CATALOG MATCHING + NUMBER POST-CHECK (never ship an invented number)
# =========================================================================

_WORD_RE = re.compile(r"[\wঀ-৿]+", re.UNICODE)


def _tokens(s):
    return [t for t in _WORD_RE.findall((s or "").lower()) if len(t) >= 2]


def match_products(text, catalog, limit=3):
    """Products whose name tokens appear in `text` (best first)."""
    low = norm_digits((text or "").lower())
    toks = set(_tokens(low))
    scored = []
    for p in catalog or []:
        name = (p.get("name") or "").lower()
        if not name:
            continue
        ntoks = _tokens(name)
        if not ntoks:
            continue
        if name in low:
            score = 100 + len(name)
        else:
            hit = sum(1 for t in ntoks if t in toks)
            if hit == 0:
                continue
            score = int(100 * hit / len(ntoks))
            if score < 50:
                continue
        scored.append((score, p))
    scored.sort(key=lambda x: -x[0])
    return [p for _, p in scored[:limit]]


_MONEY_BEFORE = r"(?:৳|tk\.?|taka|টাকা|bdt|rs\.?)\s*"
_NUM = r"(\d[\d,]*(?:\.\d+)?)"
_MONEY_AFTER = r"\s*(?:৳|/-|tk\b|taka|টাকা|bdt)"
_STOCK_AFTER = (r"\s*(?:pcs|pieces|piece|pc|টি|টা(?!কা)|ta\b|ti\b|items|units|stock|"
                r"স্টক|পিস|left|available|আছে)")
_MONEY_RE1 = re.compile(_MONEY_BEFORE + _NUM, re.IGNORECASE)
_MONEY_RE2 = re.compile(_NUM + _MONEY_AFTER, re.IGNORECASE)
_STOCK_RE = re.compile(_NUM + _STOCK_AFTER, re.IGNORECASE)
_ANY_NUM_RE = re.compile(r"\d[\d,]*(?:\.\d+)?")


def _num_of(s):
    try:
        return Decimal(s.replace(",", ""))
    except InvalidOperation:
        return None


def allowed_numbers(context, customer_text="", extra=()):
    """Every number the reply may legitimately contain."""
    money, stock, other = set(), set(), set()
    for p in context.get("catalog") or []:
        for k in ("price",):
            d = _dec(p.get(k))
            if d is not None:
                money.add(d)
        for v in p.get("variants") or []:
            d = _dec(v.get("price"))
            if d is not None:
                money.add(d)
            if v.get("stock") is not None:
                stock.add(Decimal(int(v.get("stock") or 0)))
        stock.add(Decimal(int(p.get("stock") or 0)))
    dl = context.get("delivery") or {}
    for k in ("inside_dhaka", "outside_dhaka", "free_over"):
        d = _dec(dl.get(k))
        if d is not None:
            money.add(d)
    for x in extra or ():
        d = _dec(x)
        if d is not None:
            money.add(d)
            other.add(d)
    # numbers the customer wrote (their phone, qty, an offer) and numbers in
    # the seller's own policy text (hours, return days) are not inventions
    src = norm_digits(customer_text) + " " + norm_digits(
        " ".join(str(v) for v in (context.get("policies") or {}).values()))
    for m in _ANY_NUM_RE.findall(src):
        d = _num_of(m)
        if d is not None:
            other.add(d)
    return {"money": money, "stock": stock, "other": other}


def check_numbers(reply, context, customer_text="", extra=()):
    """Post-check an AI draft. Returns a list of problems (empty == OK):
      {"type": "money"|"stock"|"number"|"stock_claim", "value": str}
    * a money-tagged number must be a catalog price / delivery charge / a total
      we computed (`extra`);
    * a stock-tagged number must be a real stock count (or a number the
      customer wrote, e.g. their qty);
    * any other number >= 10 must appear somewhere in the facts or the
      customer's own text;
    * an out-of-stock product must not be described as available."""
    text = norm_digits(reply or "")
    al = allowed_numbers(context, customer_text, extra)
    every = al["money"] | al["stock"] | al["other"]
    problems = []
    seen = set()
    spans = []
    for rx, kind, pool in ((_MONEY_RE1, "money", al["money"]),
                           (_MONEY_RE2, "money", al["money"]),
                           (_STOCK_RE, "stock", al["stock"] | al["other"])):
        for m in rx.finditer(text):
            if kind == "stock" and any(a <= m.start(1) < b for a, b in spans):
                continue          # already judged as money ("১২০০ টাকা")
            spans.append(m.span(1))
            d = _num_of(m.group(1))
            if d is None:
                continue
            if d not in pool and (kind, d) not in seen:
                seen.add((kind, d))
                problems.append({"type": kind, "value": _fmt_money(d)})
    for m in _ANY_NUM_RE.finditer(text):
        if any(a <= m.start() < b for a, b in spans):
            continue
        d = _num_of(m.group(0))
        if d is None or d < 10:
            continue
        if d not in every and ("number", d) not in seen:
            # phone-like 11-digit numbers the customer did not write = invented
            seen.add(("number", d))
            problems.append({"type": "number", "value": _fmt_money(d)})
    low = (reply or "").lower()
    avail = ("in stock", "available", "স্টকে আছে", "পাওয়া যাচ্ছে", "ache", "আছে")
    neg = ("out of stock", "স্টক নেই", "নেই", "not available", "unavailable", "sold out")
    if any(a in low for a in avail) and not any(n in low for n in neg):
        for p in context.get("catalog") or []:
            nm = (p.get("name") or "").lower()
            if nm and nm in low and int(p.get("stock") or 0) <= 0:
                problems.append({"type": "stock_claim", "value": p.get("name")})
    return problems


# =========================================================================
# 4. RISK — what must go to the seller's approval queue
# =========================================================================

RISK_COMPLAINT = "complaint"
RISK_REFUND = "refund"
RISK_BELOW_MIN = "below_min"
RISK_UNKNOWN_PRODUCT = "unknown_product"
RISK_LOW_CONF = "low_confidence"
RISK_NUMBERS = "unverified_number"
RISK_BIG_ORDER = "big_order"
RISK_APPROVE_ALL = "seller_approves_all"
RISKS = (RISK_COMPLAINT, RISK_REFUND, RISK_BELOW_MIN, RISK_UNKNOWN_PRODUCT,
         RISK_LOW_CONF, RISK_NUMBERS, RISK_BIG_ORDER, RISK_APPROVE_ALL)

_HUMAN_Q = ("are you human", "are you a bot", "are you real", "bot naki", "robot",
            "মানুষ", "রোবট", "বট", "manush", "ai naki", "are you ai")


def asks_if_human(text):
    low = (text or "").lower()
    return any(w in low for w in _HUMAN_Q)


def pre_risk(customer_text, intent, matched, offer_decision=None):
    """Risk BEFORE drafting (deterministic). Returns a reason or None."""
    trig = bai.handoff_trigger(customer_text)
    if trig == bai.HANDOFF_REFUND:
        return RISK_REFUND
    if trig == bai.HANDOFF_ANGRY:
        return RISK_COMPLAINT
    if offer_decision == bai.ACTION_DEFER:
        return RISK_BELOW_MIN
    if intent in ("price_stock", "bargain") and not matched:
        return RISK_UNKNOWN_PRODUCT
    return None


def holding_message(lang, reason, hours_text=""):
    """The honest line the customer gets while the seller reviews."""
    m = {
        RISK_COMPLAINT: pick(lang, "দুঃখিত আপনার অসুবিধার জন্য। দোকানের একজন বিষয়টি দেখে আপনাকে জানাবেন।",
                             "Sorry for the trouble. Someone from the shop will look into it and reply."),
        RISK_REFUND: pick(lang, "রিটার্ন/রিফান্ডের বিষয়ে দোকানের একজন আপনাকে জানাবেন।",
                          "Someone from the shop will help you with the return/refund."),
        RISK_BELOW_MIN: pick(lang, "এই দামের বিষয়ে আমি দোকানের মালিকের সাথে কথা বলে জানাচ্ছি।",
                             "Let me check this price with the shop owner and get back to you."),
        RISK_UNKNOWN_PRODUCT: pick(lang, "এই পণ্যটি আমি খুঁজে পাচ্ছি না। দোকানের একজন দেখে জানাবেন।",
                                   "I couldn't find this product. Someone from the shop will check and reply."),
        RISK_BIG_ORDER: pick(lang, "বড় অর্ডারের জন্য দোকানের মালিক নিজে আপনাকে জানাবেন।",
                             "For a large order the shop owner will reply to you personally."),
    }
    base = m.get(reason) or pick(lang, "দোকানের একজন শীঘ্রই আপনাকে উত্তর দেবেন।",
                                 "Someone from the shop will reply to you soon.")
    if hours_text:
        base += pick(lang, f" (দোকান খোলা: {hours_text})", f" (Shop hours: {hours_text})")
    return base


# =========================================================================
# 5. ORDER EXTRACTION (across messages)
# =========================================================================

_PHONE_RE = re.compile(r"(?:\+?88)?\s*0\s*1\s*[3-9](?:[\s-]*\d){8}")


def normalize_bd_phone(raw):
    """'+880 1712-345678' / '০১৭১২৩৪৫৬৭৮' → '01712345678', or '' if not a valid
    Bangladesh mobile number (01[3-9] + 8 digits)."""
    d = re.sub(r"\D", "", norm_digits(raw or ""))
    if d.startswith("880"):
        d = d[2:]
    elif d.startswith("88") and len(d) == 13:
        d = d[2:]
    if re.fullmatch(r"01[3-9]\d{8}", d):
        return d
    return ""


def find_phone(text):
    for m in _PHONE_RE.finditer(norm_digits(text or "")):
        p = normalize_bd_phone(m.group(0))
        if p:
            return p
    return ""


_QTY_WORDS = {"ek": 1, "ekta": 1, "akta": 1, "one": 1, "এক": 1, "একটা": 1, "একটি": 1,
              "dui": 2, "duita": 2, "two": 2, "দুই": 2, "দুইটা": 2, "দুইটি": 2, "দুটো": 2,
              "tin": 3, "tinta": 3, "three": 3, "তিন": 3, "তিনটা": 3, "তিনটি": 3,
              "char": 4, "charta": 4, "four": 4, "চার": 4, "চারটা": 4, "চারটি": 4,
              "pach": 5, "pachta": 5, "five": 5, "পাঁচ": 5, "পাঁচটা": 5, "পাঁচটি": 5}
_QTY_RE = re.compile(r"(\d{1,3})\s*(?:ta|ti|টা|টি|pcs|pc|piece|pieces|x|পিস|জোড়া|set)\b"
                     r"|(?:qty|quantity|x|পরিমাণ)\s*[:=]?\s*(\d{1,3})", re.IGNORECASE)


def find_qty(text):
    t = norm_digits((text or "").lower())
    m = _QTY_RE.search(t)
    if m:
        n = int(m.group(1) or m.group(2))
        return n if 1 <= n <= 999 else None
    for w in _tokens(t):
        if w in _QTY_WORDS:
            return _QTY_WORDS[w]
    return None


DHAKA_AREAS = (
    "dhaka", "ঢাকা", "mirpur", "মিরপুর", "dhanmondi", "ধানমন্ডি", "uttara", "উত্তরা",
    "gulshan", "গুলশান", "banani", "বনানী", "mohammadpur", "মোহাম্মদপুর", "badda", "বাড্ডা",
    "rampura", "রামপুরা", "motijheel", "মতিঝিল", "jatrabari", "যাত্রাবাড়ী", "bashundhara",
    "বসুন্ধরা", "khilgaon", "খিলগাঁও", "tejgaon", "তেজগাঁও", "farmgate", "ফার্মগেট",
    "mohakhali", "মহাখালী", "lalbagh", "লালবাগ", "shyamoli", "শ্যামলী", "wari", "ওয়ারী",
    "malibagh", "মালিবাগ", "moghbazar", "মগবাজার", "khilkhet", "খিলক্ষেত", "cantonment",
    "ক্যান্টনমেন্ট", "demra", "ডেমরা", "pallabi", "পল্লবী", "kafrul", "কাফরুল",
    "shahbagh", "শাহবাগ", "azimpur", "আজিমপুর", "hazaribagh", "হাজারীবাগ", "agargaon",
    "আগারগাঁও", "kamrangirchar", "কামরাঙ্গীরচর", "sabujbagh", "সবুজবাগ", "mugda", "মুগদা",
)
OUTSIDE_DISTRICTS = (
    "chittagong", "chattogram", "চট্টগ্রাম", "sylhet", "সিলেট", "rajshahi", "রাজশাহী",
    "khulna", "খুলনা", "barishal", "barisal", "বরিশাল", "rangpur", "রংপুর", "mymensingh",
    "ময়মনসিংহ", "comilla", "cumilla", "কুমিল্লা", "gazipur", "গাজীপুর", "narayanganj",
    "নারায়ণগঞ্জ", "bogura", "bogra", "বগুড়া", "jessore", "jashore", "যশোর", "noakhali",
    "নোয়াখালী", "feni", "ফেনী", "cox", "কক্সবাজার", "tangail", "টাঙ্গাইল", "savar", "সাভার",
    "keraniganj", "কেরানীগঞ্জ", "dinajpur", "দিনাজপুর", "pabna", "পাবনা", "kushtia", "কুষ্টিয়া",
    "faridpur", "ফরিদপুর", "brahmanbaria", "ব্রাহ্মণবাড়িয়া", "chandpur", "চাঁদপুর",
    "narsingdi", "নরসিংদী", "manikganj", "মানিকগঞ্জ", "munshiganj", "মুন্সীগঞ্জ",
)


def detect_area(text):
    """'inside' / 'outside' Dhaka, or '' when unknown. A named district beats
    the generic word 'Dhaka' (e.g. 'Savar, Dhaka' is outside the city)."""
    low = (text or "").lower()
    if any(w in low for w in OUTSIDE_DISTRICTS):
        return "outside"
    if any(w in low for w in DHAKA_AREAS):
        return "inside"
    return ""


_ADDR_HINT = ("address", "addr", "ঠিকানা", "thikana", "road", "rd", "house", "বাসা",
              "রোড", "বাড়ি", "flat", "ফ্ল্যাট", "thana", "থানা", "জেলা", "zilla",
              "district", "upazila", "উপজেলা", "sector", "সেক্টর", "block", "ব্লক",
              "lane", "লেন", "para", "পাড়া", "village", "গ্রাম", "post", "পোস্ট")
_NAME_RE = re.compile(r"(?:name|nam|নাম)\s*[:=\-]?\s*(?:is\s+|holo\s+|হলো\s+)?"
                      r"([A-Za-zঀ-৿ .]{2,40})", re.IGNORECASE)
_ADDR_RE = re.compile(r"(?:address|addr|ঠিকানা|thikana)\s*[:=\-]?\s*(.{6,200})", re.IGNORECASE)


def find_name(text):
    m = _NAME_RE.search(text or "")
    if m:
        v = m.group(1).strip(" .")
        v = re.split(r"\b(?:phone|mobile|address|ঠিকানা|ফোন|মোবাইল)\b", v,
                     flags=re.IGNORECASE)[0].strip(" .,")
        return v[:60]
    return ""


def find_address(text):
    t = text or ""
    m = _ADDR_RE.search(t)
    if m:
        return re.split(r"\b(?:phone|mobile|ফোন|মোবাইল)\b", m.group(1),
                        flags=re.IGNORECASE)[0].strip(" ,.")[:240]
    # multi-line order message: a long line with address words / an area
    for line in re.split(r"[\n;]+", t):
        ln = line.strip()
        if len(ln) < 8 or find_phone(ln) and len(re.sub(r"[\d\s+\-]", "", ln)) < 6:
            continue
        low = ln.lower()
        if any(h in low for h in _ADDR_HINT) or detect_area(ln):
            return re.sub(_PHONE_RE, "", norm_digits(ln)).strip(" ,.")[:240]
    return ""


def _variant_match(text, product):
    low = (text or "").lower()
    for v in product.get("variants") or []:
        parts = [x for x in (v.get("size"), v.get("colour")) if x]
        if parts and all(str(x).lower() in low for x in parts):
            return v
    return None


ORDER_FIELDS = ("product", "qty", "name", "phone", "address", "area")


def extract_order(text, draft, catalog):
    """Merge whatever this message adds into the running `draft` dict. Never
    invents a value: a field is only set from the customer's own words (or the
    single obvious default qty=1 once a product is chosen)."""
    d = dict(draft or {})
    t = text or ""
    prods = match_products(t, catalog, limit=2)
    low = norm_digits(t.lower())
    full = [p for p in prods if (p.get("name") or "").lower() in low]
    if full:
        prods = full[:1]
    elif len(prods) > 1 or (prods and d.get("product_id")):
        # g1: a PARTIAL name hit is ambiguous ("Name: Selftest Buyer" vs the
        # products "Selftest Panjabi" / "Selftest Pajama") — it never picks a
        # product, and never replaces the one already chosen (e.g. by photo)
        prods = []
    if prods:
        p = prods[0]
        d["product_id"] = p.get("id")
        d["product"] = p.get("name")
        v = _variant_match(t, p)
        if v:
            d["variant"] = v.get("vkey") or "%s/%s" % (v.get("size", ""), v.get("colour", ""))
            d["variant_label"] = " ".join(x for x in (v.get("size"), v.get("colour")) if x)
    q = find_qty(t)
    if q:
        d["qty"] = q
    ph = find_phone(t)
    if ph:
        d["phone"] = ph
    elif re.search(r"(?:\+?88)?0\d{6,}", norm_digits(t)) and not d.get("phone"):
        d["phone_invalid"] = True
    nm = find_name(t)
    if nm:
        d["name"] = nm
    ad = find_address(t)
    if ad:
        d["address"] = ad
        ar = detect_area(ad)
        if ar:
            d["area"] = ar
    if not d.get("area"):
        ar = detect_area(t)
        if ar:
            d["area"] = ar
    if d.get("product") and not d.get("qty"):
        d["qty"] = 1
    if d.get("phone"):
        d.pop("phone_invalid", None)
    return d


def missing_fields(draft):
    return [f for f in ORDER_FIELDS if not (draft or {}).get(f)]


def delivery_charge(area, delivery, subtotal=None):
    dl = delivery or {}
    free_over = _dec(dl.get("free_over"))
    if free_over and subtotal is not None and _dec(subtotal) is not None \
            and _dec(subtotal) >= free_over:
        return Decimal(0)
    key = "inside_dhaka" if area == "inside" else "outside_dhaka"
    return _dec(dl.get(key)) or Decimal(0)


def price_order(draft, catalog, delivery):
    """{unit, qty, subtotal, delivery, total, stock_ok, product} from the REAL
    catalog row (never from the conversation)."""
    prod = next((p for p in catalog or [] if p.get("id") == draft.get("product_id")), None)
    if prod is None:
        return None
    unit = _dec(prod.get("price")) or Decimal(0)
    stock = int(prod.get("stock") or 0)
    if draft.get("variant"):
        for v in prod.get("variants") or []:
            if (v.get("vkey") or "") == draft["variant"]:
                unit = _dec(v.get("price")) or unit
                stock = int(v.get("stock") or 0)
    ag = draft.get("agreed") or {}
    if ag.get("product_id") == prod.get("id") and _dec(ag.get("price")) is not None:
        # a price agreed by negotiate() (never below the minimum, enforced there)
        unit = _dec(ag["price"])
    qty = int(draft.get("qty") or 1)
    sub = unit * qty
    dc = delivery_charge(draft.get("area"), delivery, sub)
    return {"product": prod.get("name"), "unit": unit, "qty": qty, "subtotal": sub,
            "delivery": dc, "total": sub + dc, "stock": stock,
            "stock_ok": stock >= qty}


_YES = ("yes", "yes.", "ha", "hya", "hae", "hmm ha", "ji", "jee", "ok", "okay", "confirm",
        "confirmed", "হ্যাঁ", "হা", "জি", "জ্বি", "ঠিক আছে", "কনফার্ম", "ঠিক", "done", "sure")
_NO = ("no", "na", "nah", "cancel", "না", "বাতিল", "lagbe na", "লাগবে না", "dorkar nai")


def is_yes(text):
    low = (text or "").strip().lower().strip("!.। ")
    return low in _YES or any(low.startswith(y + " ") for y in ("yes", "ha", "হ্যাঁ", "জি", "ok"))


def is_no(text):
    low = (text or "").strip().lower().strip("!.। ")
    return low in _NO or "cancel" in low or "বাতিল" in low


def ask_missing(lang, missing, phone_invalid=False):
    labels = {
        "product": pick(lang, "কোন পণ্যটি নিতে চান", "which product you want"),
        "qty": pick(lang, "কয়টি", "how many"),
        "name": pick(lang, "আপনার নাম", "your name"),
        "phone": pick(lang, "মোবাইল নম্বর (০১XXXXXXXXX)", "mobile number (01XXXXXXXXX)"),
        "address": pick(lang, "পূর্ণ ঠিকানা", "full address"),
        "area": pick(lang, "ঢাকার ভিতরে না বাইরে", "inside or outside Dhaka"),
    }
    parts = [labels[f] for f in missing if f in labels]
    pre = ""
    if phone_invalid:
        pre = pick(lang, "নম্বরটি সঠিক বাংলাদেশি মোবাইল নম্বর মনে হচ্ছে না। ",
                   "That doesn't look like a valid Bangladesh mobile number. ")
    return pre + pick(lang, "অর্ডার করতে অনুগ্রহ করে জানান: " + ", ".join(parts) + "।",
                      "To place the order please send: " + ", ".join(parts) + ".")


def order_summary(lang, draft, priced):
    """The confirm-before-order summary with the COD amount."""
    item = priced["product"] + ((" (" + draft["variant_label"] + ")")
                                if draft.get("variant_label") else "")
    area = pick(lang, "ঢাকার ভিতরে", "inside Dhaka") if draft.get("area") == "inside" \
        else pick(lang, "ঢাকার বাইরে", "outside Dhaka")
    return pick(
        lang,
        f"অর্ডারের সারাংশ:\n- {item} × {priced['qty']} = ৳{_fmt_money(priced['subtotal'])}\n"
        f"- ডেলিভারি ({area}): ৳{_fmt_money(priced['delivery'])}\n"
        f"- মোট (ক্যাশ অন ডেলিভারি): ৳{_fmt_money(priced['total'])}\n"
        f"- নাম: {draft.get('name')}, ফোন: {draft.get('phone')}\n- ঠিকানা: {draft.get('address')}\n"
        "সব ঠিক থাকলে \"হ্যাঁ\" লিখুন, বাতিল করতে \"না\"।",
        f"Order summary:\n- {item} × {priced['qty']} = ৳{_fmt_money(priced['subtotal'])}\n"
        f"- Delivery ({area}): ৳{_fmt_money(priced['delivery'])}\n"
        f"- Total (cash on delivery): ৳{_fmt_money(priced['total'])}\n"
        f"- Name: {draft.get('name')}, phone: {draft.get('phone')}\n- Address: {draft.get('address')}\n"
        "Reply \"yes\" to confirm or \"no\" to cancel.")


def out_of_stock_line(lang, name, stock):
    if stock <= 0:
        return pick(lang, f"দুঃখিত, {name} এখন স্টকে নেই।", f"Sorry, {name} is out of stock right now.")
    return pick(lang, f"দুঃখিত, {name} এখন মাত্র {stock}টি আছে।",
                f"Sorry, only {stock} of {name} left right now.")


def invoice_text(lang, order, shop_name=""):
    """Plain-text invoice the customer receives after confirming."""
    lines = [pick(lang, f"ইনভয়েস #{order['id']}" + (f" — {shop_name}" if shop_name else ""),
                  f"Invoice #{order['id']}" + (f" — {shop_name}" if shop_name else ""))]
    for it in order.get("items") or []:
        lines.append(f"- {it.get('name')} × {it.get('qty')} = ৳{_fmt_money(_dec(it.get('price')) * int(it.get('qty') or 1))}")
    lines.append(pick(lang, f"ডেলিভারি চার্জ: ৳{_fmt_money(order.get('delivery_charge'))}",
                      f"Delivery: ৳{_fmt_money(order.get('delivery_charge'))}"))
    lines.append(pick(lang, f"মোট (ক্যাশ অন ডেলিভারি): ৳{_fmt_money(order.get('total'))}",
                      f"Total (cash on delivery): ৳{_fmt_money(order.get('total'))}"))
    lines.append(pick(lang, "ধন্যবাদ! পার্সেল পাঠানো হলে ট্র্যাকিং জানিয়ে দেব।",
                      "Thank you! We'll send the tracking once the parcel ships."))
    return "\n".join(lines)


def order_cancelled_line(lang):
    return pick(lang, "ঠিক আছে, অর্ডারটি বাতিল করা হলো।", "Okay, the order has been cancelled.")


# =========================================================================
# 6. FIXED CUSTOMER / SELLER LINES
# =========================================================================

def out_of_replies_customer(lang):
    return pick(lang, "ধন্যবাদ! দোকানের একজন শীঘ্রই আপনাকে উত্তর দেবেন।",
                "Thank you! Someone from the shop will reply to you soon.")


def out_of_replies_seller(lang):
    return (pick(lang, "AI উত্তর শেষ", "AI replies used up"),
            pick(lang, "এই মাসের AI উত্তর ও ক্রেডিট শেষ। গ্রাহকদের জানানো হয়েছে যে একজন মানুষ উত্তর দেবেন। প্ল্যান বা ক্রেডিট নিন।",
                 "This month's AI replies and credits are used up. Customers were told a person will reply. Get a plan or credits."))


def comment_public_reply(lang):
    """Short public reply under a comment — never a price in public."""
    return pick(lang, "ধন্যবাদ! বিস্তারিত আপনার ইনবক্সে পাঠানো হয়েছে।",
                "Thanks! We've sent you the details in your inbox.")


def courier_update_line(lang, order_id, courier, tracking, status_label):
    return pick(lang, f"অর্ডার #{order_id}: {status_label} ({courier} ট্র্যাকিং: {tracking})",
                f"Order #{order_id}: {status_label} ({courier} tracking: {tracking})")


def with_disclosure(lang, text, first):
    short = bai.assistant_disclosure(lang)["short"]
    if not first or short in (text or ""):
        return text
    return bai.assistant_disclosure(lang)["short"] + " " + text


# =========================================================================
# 7. LLM PROMPT + RESPONSE PARSE
# =========================================================================

def llm_task(context, lang, tone="friendly"):
    """Trusted instruction for core.ai.generate. The customer's message goes in
    `data` (untrusted, fenced)."""
    tones = {"friendly": "warm and friendly", "formal": "polite and formal",
             "short": "short and to the point"}
    language = "Bangla (Bengali script)" if lang == "bn" else "English"
    return (
        "You are the AI sales assistant of the online shop \"%s\" in Bangladesh. "
        "Reply to the customer's message in %s, %s, at most 3 short sentences. "
        "Use ONLY the facts below. NEVER state a price, stock count, delivery "
        "charge or discount that is not written in the facts. Never offer a "
        "discount. If the facts do not answer the question, say a person from the "
        "shop will reply. Do not ask for card or bKash PINs/passwords. "
        "Return ONLY JSON: {\"reply\": \"...\", \"confidence\": 0.0-1.0}.\n\nFACTS:\n%s"
        % (context.get("shop_name") or "shop", language, tones.get(tone, tones["friendly"]),
           context.get("facts") or "(no catalog yet)"))


def parse_llm(text):
    """{'text', 'confidence'} from the model output. A non-JSON answer is
    accepted as text with a medium confidence (still post-checked)."""
    t = (text or "").strip()
    m = re.search(r"\{.*\}", t, re.DOTALL)
    if m:
        try:
            js = json.loads(m.group(0))
            reply = str(js.get("reply") or "").strip()
            conf = float(js.get("confidence") or 0)
            if reply:
                return {"text": reply, "confidence": max(0.0, min(1.0, conf))}
        except (ValueError, TypeError):
            pass
    return {"text": t, "confidence": 0.6 if t else 0.0}


# =========================================================================
# 8. SELLER PLANS CONFIG (PricingConfig["seller_agent"]) — admin-editable
# =========================================================================

def cfg_defaults():
    return {
        # monthly AI replies per plan; price in whole taka (owner proposal,
        # BUSINESS_PLAN_BN.md). Sold through the payment gateway (EPS).
        "plans": {"starter": {"price": 1490, "replies": 1000},
                  "pro": {"price": 3990, "replies": 3000}},
        "trial_days": 7,
        "trial_replies": 100,
        # Meta's WhatsApp charge per BILLABLE message/conversation, in ৳, per
        # category. 0 = not set yet (Owner Admin shows a warning). We add the
        # pricing margin and charge it from the seller's credits.
        "wa_cost_bdt": {"marketing": 0.0, "utility": 0.0, "authentication": 0.0,
                        "service": 0.0},
        # per-channel kill switch (True = channel OFF for every seller)
        "kill": {CH_MESSENGER: False, CH_INSTAGRAM: False, CH_WHATSAPP: False},
        "ai_kill": False,              # stop ALL AI replies (manual still works)
        "low_stock_default": 3,
        "public_comment_reply": True,  # short public "sent to inbox" reply
    }


def _num(v, fb):
    try:
        if isinstance(v, bool):
            return fb
        return float(v)
    except (TypeError, ValueError):
        return fb


def _bool(v, fb):
    if isinstance(v, bool):
        return v
    if isinstance(v, str) and v.lower() in ("true", "false", "1", "0", "on", "off"):
        return v.lower() in ("true", "1", "on")
    return fb


def cfg_normalize(raw):
    base = cfg_defaults()
    raw = raw if isinstance(raw, dict) else {}
    plans = {}
    rp = raw.get("plans") if isinstance(raw.get("plans"), dict) else {}
    for pid, pdef in base["plans"].items():
        r = rp.get(pid) if isinstance(rp.get(pid), dict) else {}
        plans[pid] = {"price": max(0, int(_num(r.get("price"), pdef["price"]))),
                      "replies": max(0, int(_num(r.get("replies"), pdef["replies"])))}
    wa = raw.get("wa_cost_bdt") if isinstance(raw.get("wa_cost_bdt"), dict) else {}
    kill = raw.get("kill") if isinstance(raw.get("kill"), dict) else {}
    return {
        "plans": plans,
        "trial_days": max(0, min(30, int(_num(raw.get("trial_days"), base["trial_days"])))),
        "trial_replies": max(0, int(_num(raw.get("trial_replies"), base["trial_replies"]))),
        "wa_cost_bdt": {k: max(0.0, _num(wa.get(k), v)) for k, v in base["wa_cost_bdt"].items()},
        "kill": {k: _bool(kill.get(k), v) for k, v in base["kill"].items()},
        "ai_kill": _bool(raw.get("ai_kill"), base["ai_kill"]),
        "low_stock_default": max(0, int(_num(raw.get("low_stock_default"),
                                             base["low_stock_default"]))),
        "public_comment_reply": _bool(raw.get("public_comment_reply"),
                                      base["public_comment_reply"]),
    }


def reply_cost_bdt(pricing_cfg):
    """Worst-case provider cost of ONE AI reply (ai_sales provider_cost, USD→৳)."""
    ac = (pricing_cfg.get("action_costs") or {}).get("ai_sales") or {}
    return float(ac.get("provider_cost") or 0) * float(pricing_cfg.get("usd_bdt") or 120)


def plan_margin_rows(pricing_cfg):
    """One row per seller plan: price, NET after the gateway fee (and, as a
    second view, after the Play fee), worst-case AI cost, margin %. Pure."""
    sa = cfg_normalize(pricing_cfg.get("seller_agent"))
    per = reply_cost_bdt(pricing_cfg)
    gw = float((pricing_cfg.get("payments") or {}).get("gateway_fee",
                                                       pricing_cfg.get("gateway_fee", 0.02)))
    play = float(pricing_cfg.get("play_fee", 0.15))
    vat = float(pricing_cfg.get("vat", 0.0))
    target = float(pricing_cfg.get("margin", 0.40))
    rows = []
    for pid, p in sa["plans"].items():
        cost = p["replies"] * per
        net_gw = p["price"] * (1 - gw - vat)
        net_play = p["price"] * (1 - play - vat)
        m_gw = (1 - cost / net_gw) if net_gw > 0 else None
        m_play = (1 - cost / net_play) if net_play > 0 else None
        rows.append({"plan": pid, "price": p["price"], "replies": p["replies"],
                     "cost": round(cost, 2), "net": round(net_gw, 2),
                     "margin_pct": None if m_gw is None else round(100 * m_gw, 1),
                     "net_play": round(net_play, 2),
                     "margin_play_pct": None if m_play is None else round(100 * m_play, 1),
                     "ok": m_gw is not None and m_gw + 1e-9 >= target,
                     "ok_play": m_play is not None and m_play + 1e-9 >= target})
    return rows


def validate_cfg(raw, pricing_cfg):
    """Problem codes for a proposed seller_agent block (blocking):
    'seller_plan_breaks_margin' — a plan's worst-case AI cost leaves less than
    the margin target (default 40%) of the gateway NET; 'seller_negative'."""
    probs = []
    if raw is None:
        return probs
    if not isinstance(raw, dict):
        return ["seller_negative"]
    for pid, p in (raw.get("plans") or {}).items():
        if isinstance(p, dict) and (_num(p.get("price"), 0) < 0 or _num(p.get("replies"), 0) < 0):
            probs.append("seller_negative")
    for v in (raw.get("wa_cost_bdt") or {}).values():
        if _num(v, 0) < 0:
            probs.append("seller_negative")
    trial = dict(pricing_cfg, seller_agent=raw)
    for row in plan_margin_rows(trial):
        if row["price"] > 0 and not row["ok"]:
            probs.append("seller_plan_breaks_margin")
            break
    return list(dict.fromkeys(probs))


def warnings(pricing_cfg):
    """Non-blocking warnings for Owner Admin."""
    sa = cfg_normalize(pricing_cfg.get("seller_agent"))
    out = []
    if all(v <= 0 for v in sa["wa_cost_bdt"].values()):
        out.append({"code": "wa_cost_unset"})
    for row in plan_margin_rows(pricing_cfg):
        if row["price"] > 0 and not row["ok_play"]:
            out.append({"code": "seller_plan_play_margin", "plan": row["plan"],
                        "margin_play_pct": row["margin_play_pct"]})
    return out


def wa_charge_credits(category, pricing_cfg):
    """Credits to charge the seller for one billable WhatsApp message /
    conversation of `category`: ceil(meta_cost × (1 + margin) / credit_bdt).
    0 while the owner has not set the rate."""
    sa = cfg_normalize(pricing_cfg.get("seller_agent"))
    cost = sa["wa_cost_bdt"].get(category, sa["wa_cost_bdt"].get("marketing", 0.0))
    if cost <= 0:
        return 0
    margin = float(pricing_cfg.get("margin", 0.40))
    cb = float(pricing_cfg.get("credit_bdt", 1.0)) or 1.0
    return max(1, int(math.ceil(cost * (1 + margin) / cb - 1e-9)))


# =========================================================================
# 9. QUOTA DECISION (plan replies first, then purchased credits)
# =========================================================================

def plan_state(plan, period_end_ts, replies_used, quota, now_ts):
    """{'active', 'left'} for the seller's current plan period."""
    active = bool(plan and plan != "none" and period_end_ts and now_ts < period_end_ts)
    left = max(0, int(quota or 0) - int(replies_used or 0)) if active else 0
    return {"active": active, "left": left}


# =========================================================================
# 10. BUSINESS HOURS + REPORTS
# =========================================================================

def _hm(s):
    try:
        h, m = str(s).split(":")
        return int(h) * 60 + int(m)
    except (ValueError, AttributeError):
        return None


def within_hours(hours, minute_of_day):
    """hours = {"always": true} or {"start": "10:00", "end": "22:00"}."""
    h = hours or {}
    if h.get("always", True) and not (h.get("start") and h.get("end")):
        return True
    a, b = _hm(h.get("start")), _hm(h.get("end"))
    if a is None or b is None:
        return True
    if a <= b:
        return a <= minute_of_day < b
    return minute_of_day >= a or minute_of_day < b


def hours_text(hours):
    h = hours or {}
    if h.get("start") and h.get("end"):
        return "%s–%s" % (h["start"], h["end"])
    return ""


def low_stock(catalog, default_threshold=3):
    out = []
    for p in catalog or []:
        th = p.get("low_stock_at")
        th = default_threshold if th is None else int(th)
        if int(p.get("stock") or 0) <= th:
            out.append({"id": p.get("id"), "name": p.get("name"),
                        "stock": int(p.get("stock") or 0), "threshold": th})
    return out


def daily_report(lang, stats):
    """stats: {orders, revenue, messages, ai_replies, pending_approvals,
    low_stock:[...]} → {title, body}."""
    ls = stats.get("low_stock") or []
    title = pick(lang, "আজকের বিক্রির সারাংশ", "Today's sales summary")
    body = pick(
        lang,
        f"অর্ডার {stats.get('orders', 0)}টি, মোট ৳{_fmt_money(stats.get('revenue', 0))}। "
        f"মেসেজ {stats.get('messages', 0)}টি, AI উত্তর {stats.get('ai_replies', 0)}টি, "
        f"অনুমোদনের অপেক্ষায় {stats.get('pending_approvals', 0)}টি।",
        f"{stats.get('orders', 0)} orders, total ৳{_fmt_money(stats.get('revenue', 0))}. "
        f"{stats.get('messages', 0)} messages, {stats.get('ai_replies', 0)} AI replies, "
        f"{stats.get('pending_approvals', 0)} waiting for your approval.")
    if ls:
        names = ", ".join("%s (%d)" % (x["name"], x["stock"]) for x in ls[:5])
        body += pick(lang, f" কম স্টক: {names}।", f" Low stock: {names}.")
    return {"title": title, "body": body}
