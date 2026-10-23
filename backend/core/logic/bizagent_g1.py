"""
bizagent_g1.py — G1 "Night Salesman" decisions of the Business AI Agent. PURE.

No Django, no network, no clock (callers pass `now` as an aware datetime or a
minute-of-day). Covers:

  * WHO REPLIES (24/7 by default): business mode always | outside_hours | off,
    per-chat toggle (human = "I will reply"), a human reply pauses the AI in
    THAT chat only and the AI resumes after the seller's timeout (default 15
    min) when the customer is still waiting. Never two replies at once (the
    service layer holds a per-chat lease; see may_ai_reply()).
  * quiet hours (no follow-ups / seller pushes held for the morning summary),
  * follow-ups for silent customers (inside the 24 h window only, capped,
    opt-out honoured),
  * the order summary extras: bundle discount (never below the min price —
    enforced here in code), free-delivery nudge, one polite upsell,
  * payment screenshots → payment PENDING (never confirmed from a picture),
  * parsing the vision model's JSON (product description / text in image),
  * the agent report (chats, orders, revenue the agent brought, AI cost,
    profit) and the morning summary text.
"""
import json
import re
from decimal import Decimal

from . import bizagent as BZ
from . import business_ai as bai

pick = bai.pick

MODE_ALWAYS = "always"
MODE_OUTSIDE = "outside_hours"
MODE_OFF = "off"
MODES = (MODE_ALWAYS, MODE_OUTSIDE, MODE_OFF)

DEFAULT_RESUME_MIN = 15
MAX_RESUME_MIN = 24 * 60
LOCK_SECONDS = 90


def clamp_int(v, lo, hi, fb):
    try:
        n = int(v)
    except (TypeError, ValueError):
        return fb
    return max(lo, min(hi, n))


# ===================================================================== who replies
def may_ai_reply(*, mode, ai_enabled, in_business_hours, human_mode, paused_until_ts,
                 now_ts):
    """(allowed, reason). reason ∈ ok | ai_off | mode_off | business_hours |
    human_mode | paused. Pure: the caller passes epoch seconds."""
    if not ai_enabled:
        return False, "ai_off"
    if mode == MODE_OFF:
        return False, "mode_off"
    if human_mode:
        return False, "human_mode"
    if paused_until_ts and now_ts < paused_until_ts:
        return False, "paused"
    if mode == MODE_OUTSIDE and in_business_hours:
        return False, "business_hours"
    return True, "ok"


def pause_until_ts(now_ts, resume_minutes):
    m = clamp_int(resume_minutes, 1, MAX_RESUME_MIN, DEFAULT_RESUME_MIN)
    return now_ts + 60 * m


def customer_waiting(messages):
    """messages = newest-last [{direction, status}]. True when the last
    customer message has no reply after it (the AI may answer it once the
    human pause is over)."""
    for m in reversed(messages or []):
        if m.get("direction") == "out" and m.get("status") not in ("pending_approval",
                                                                   "rejected", "failed",
                                                                   "blocked", "approved"):
            return False
        if m.get("direction") == "in":
            return True
    return False


# ===================================================================== quiet hours
def in_window(hours, minute_of_day):
    """hours = {"start": "HH:MM", "end": "HH:MM"} (may wrap past midnight);
    empty = never."""
    h = hours or {}
    a, b = BZ._hm(h.get("start")), BZ._hm(h.get("end"))
    if a is None or b is None or a == b:
        return False
    if a < b:
        return a <= minute_of_day < b
    return minute_of_day >= a or minute_of_day < b


def in_business_hours(hours, minute_of_day):
    """Business hours {"start","end"}; unset = always open (so the
    outside_hours mode never silences the AI by accident... it then never
    replies — callers show the seller that hours are needed for this mode)."""
    h = hours or {}
    if not (h.get("start") and h.get("end")):
        return False
    return BZ.within_hours(h, minute_of_day)


# ===================================================================== follow-ups
_OPT_OUT = ("stop", "unsubscribe", "আর মেসেজ দিবেন না", "মেসেজ দিবেন না", "বিরক্ত করবেন না",
            "message diben na", "msg diben na", "disturb korben na", "বন্ধ করুন", "no more message")


def is_opt_out(text):
    low = (text or "").strip().lower()
    return low in ("stop", "স্টপ") or any(w in low for w in _OPT_OUT if len(w) > 4)


def followup_due(*, enabled, opted_out, human_mode, paused, quiet, last_dir, last_out_kind,
                 last_at_ts, last_inbound_ts, now_ts, sent, max_n, after_hours, window_h=24):
    """True when ONE gentle follow-up may go to a customer who went silent
    after the agent asked something (order details / confirm). Only inside
    Meta's 24 h window; capped per chat; never after an opt-out, in quiet
    hours, while a human handles the chat."""
    if not enabled or opted_out or human_mode or paused or quiet:
        return False
    if last_dir != "out" or last_out_kind not in ("order", "text"):
        return False
    if sent >= clamp_int(max_n, 0, 3, 1):
        return False
    if not last_at_ts or not last_inbound_ts:
        return False
    wait = 3600 * clamp_int(after_hours, 1, 20, 3)
    if now_ts - last_at_ts < wait:
        return False
    # must still be inside the 24 h customer-service window when we send
    return now_ts - last_inbound_ts < window_h * 3600 - 300


def followup_text(lang, draft):
    d = draft or {}
    if d.get("state") == "awaiting_confirm":
        return pick(lang, "আপনার অর্ডারটি কি কনফার্ম করবেন? \"হ্যাঁ\" লিখলেই অর্ডার হয়ে যাবে। আর মেসেজ না চাইলে \"stop\" লিখুন।",
                    "Would you like to confirm your order? Just reply \"yes\". Reply \"stop\" for no more messages.")
    if d.get("product"):
        return pick(lang, f"{d['product']} এখনো নিতে চাইলে নাম, মোবাইল নম্বর ও ঠিকানা লিখুন। আর মেসেজ না চাইলে \"stop\" লিখুন।",
                    f"Still interested in {d['product']}? Send your name, mobile number and address. Reply \"stop\" for no more messages.")
    return pick(lang, "আর কোনো প্রশ্ন থাকলে জানাবেন, আমরা আছি। আর মেসেজ না চাইলে \"stop\" লিখুন।",
                "Let us know if you have any other question. Reply \"stop\" for no more messages.")


def opt_out_ack(lang):
    return pick(lang, "ঠিক আছে, আর নিজে থেকে মেসেজ দেব না। প্রশ্ন থাকলে যেকোনো সময় লিখুন।",
                "Okay, we won't message you first again. Write any time if you need us.")


# ===================================================================== order extras
def normalize_bundle_rules(raw):
    out = []
    for r in raw if isinstance(raw, list) else []:
        if not isinstance(r, dict):
            continue
        try:
            q = int(r.get("min_qty"))
            pct = float(r.get("off_pct"))
        except (TypeError, ValueError):
            continue
        if not (2 <= q <= 999) or not (0 < pct <= 50):
            continue
        out.append({"min_qty": q, "off_pct": round(pct, 2)})
    out.sort(key=lambda r: r["min_qty"])
    return out[:5]


def bundle_unit_price(unit, min_price, qty, rules):
    """Unit price after the best bundle rule for `qty`. NEVER below the
    product's minimum price (unset minimum = no discount at all)."""
    unit = BZ._dec(unit) or Decimal(0)
    floor = BZ._dec(min_price) or Decimal(0)
    if floor <= 0:
        return unit, None
    best = None
    for r in normalize_bundle_rules(rules):
        if int(qty or 0) >= r["min_qty"]:
            best = r
    if not best:
        return unit, None
    disc = (unit * Decimal(str(best["off_pct"])) / 100).quantize(Decimal("1"))
    new = max(floor, unit - disc)
    if new >= unit:
        return unit, None
    return new, best


def free_delivery_nudge(lang, subtotal, delivery):
    free = BZ._dec((delivery or {}).get("free_over"))
    sub = BZ._dec(subtotal)
    if not free or sub is None or sub >= free:
        return "", None
    gap = free - sub
    return (pick(lang, f"আর ৳{BZ._fmt_money(gap)}-এর পণ্য নিলে ডেলিভারি ফ্রি।",
                 f"Add ৳{BZ._fmt_money(gap)} more for free delivery."), gap)


def pick_upsell(catalog, product_id, exclude=()):
    """One matching in-stock product: same category first, then any; never
    the ordered product itself."""
    prod = next((p for p in catalog or [] if p.get("id") == product_id), None)
    if prod is None:
        return None
    cat = (prod.get("category") or "").strip().lower()
    pool = [p for p in catalog if p.get("id") != product_id and p.get("id") not in exclude
            and int(p.get("stock") or 0) > 0 and (BZ._dec(p.get("price")) or 0) > 0]
    same = [p for p in pool if cat and (p.get("category") or "").strip().lower() == cat]
    cands = same or []
    if not cands:
        return None
    cands.sort(key=lambda p: BZ._dec(p.get("price")) or 0)
    return cands[0]


def upsell_line(lang, p):
    return pick(lang, f"সাথে {p['name']} (৳{BZ._fmt_money(p['price'])}) দেখতে পারেন — চাইলে জানাবেন, একই পার্সেলে পাঠিয়ে দেব।",
                f"You may also like {p['name']} (৳{BZ._fmt_money(p['price'])}) — tell us and we'll add it to the same parcel.")


# ===================================================================== payment screenshots
_PAY_WORDS = ("bkash", "bikash", "বিকাশ", "nagad", "নগদ", "rocket", "রকেট", "upay", "send money",
              "সেন্ড মানি", "payment done", "payment korechi", "taka pathiyechi", "টাকা পাঠিয়েছি",
              "পেমেন্ট করেছি", "পেমেন্ট দিয়েছি", "trxid", "trx id", "transaction id", "txnid",
              "ট্রানজেকশন", "advance diyechi", "অগ্রিম দিয়েছি", "paid", "cash out", "receipt",
              "payment successful", "successful", "সফল")
_TRX_RE = re.compile(r"\b(?:trx\s*id|txn\s*id|transaction\s*id|ট্রানজেকশন\s*আইডি)\s*[:#]?\s*[A-Z0-9]{6,}",
                     re.IGNORECASE)


def is_payment_proof(caption="", image_text="", vision_kind=""):
    """A picture that claims a payment (bKash/Nagad/bank screenshot). We can
    NEVER confirm a payment from it (fake screenshots are common) — the order
    becomes payment-pending and the owner verifies in their own wallet."""
    if vision_kind == "payment":
        return True
    blob = " ".join((caption or "", image_text or "")).lower()
    if _TRX_RE.search(blob):
        return True
    hits = sum(1 for w in _PAY_WORDS if w in blob)
    return hits >= 1 and bool(caption or image_text)


def payment_pending_reply(lang, order_id=None):
    if order_id:
        return pick(lang, f"ধন্যবাদ, স্ক্রিনশট পেয়েছি। অর্ডার #{order_id}-এর পেমেন্ট দোকানের মালিক নিজে যাচাই করে জানাবেন — যাচাইয়ের আগে এটি পরিশোধিত ধরা হবে না।",
                    f"Thanks, we got the screenshot. The owner will verify the payment for order #{order_id} — it is not marked as paid until then.")
    return pick(lang, "ধন্যবাদ, স্ক্রিনশট পেয়েছি। দোকানের মালিক নিজে পেমেন্ট যাচাই করে জানাবেন — যাচাইয়ের আগে এটি পরিশোধিত ধরা হবে না।",
                "Thanks, we got the screenshot. The owner will verify the payment themselves — it is not treated as paid until then.")


# ===================================================================== vision JSON
VISION_KINDS = ("product", "payment", "address", "size_chart", "other")


def vision_task(lang, catalog_names):
    """Trusted instruction for the vision model. It DESCRIBES and READS; it
    never prices (prices come from the catalog in code)."""
    names = ", ".join(n for n in catalog_names[:60] if n)
    return (
        "You look at ONE photo a customer sent to an online shop in Bangladesh. "
        "Return ONLY JSON: {\"kind\": \"product|payment|address|size_chart|other\", "
        "\"description\": \"short English description: item type, colour, pattern, material\", "
        "\"colours\": [\"...\"], \"category\": \"...\", \"text\": \"all text visible in the image\", "
        "\"phone\": \"a phone number written in the image or empty\", "
        "\"address\": \"a postal address written in the image or empty\", "
        "\"best_match\": \"the closest product name from this list or empty\"}. "
        "payment = a mobile-banking/bank payment screenshot. Never guess a price. "
        "Never identify a person. Shop products: " + (names or "(none)"))


def parse_vision(raw):
    t = (raw or "").strip()
    m = re.search(r"\{.*\}", t, re.DOTALL)
    js = {}
    if m:
        try:
            js = json.loads(m.group(0))
        except ValueError:
            js = {}
    if not isinstance(js, dict):
        js = {}
    kind = str(js.get("kind") or "other").lower()
    return {"kind": kind if kind in VISION_KINDS else "other",
            "description": str(js.get("description") or (t if not js else ""))[:500],
            "colours": [str(c)[:30] for c in (js.get("colours") or []) if c][:5]
            if isinstance(js.get("colours"), list) else [],
            "category": str(js.get("category") or "")[:60],
            "text": str(js.get("text") or "")[:1500],
            "phone": BZ.normalize_bd_phone(str(js.get("phone") or "")),
            "address": str(js.get("address") or "")[:240],
            "best_match": str(js.get("best_match") or "")[:160]}


def text_match_scores(vision, catalog):
    """Score catalog products against the vision description (name tokens,
    category, colours, description words). Returns [(score 0..1, product)]."""
    words = set(re.findall(r"[a-zঀ-৿]{3,}", " ".join([
        vision.get("description") or "", vision.get("category") or "",
        " ".join(vision.get("colours") or []), vision.get("best_match") or ""]).lower()))
    best = (vision.get("best_match") or "").strip().lower()
    out = []
    for p in catalog or []:
        name = (p.get("name") or "").lower()
        if not name:
            continue
        pw = set(re.findall(r"[a-zঀ-৿]{3,}", " ".join([
            name, p.get("category") or "", p.get("description") or "",
            " ".join((v.get("colour") or "") for v in p.get("variants") or [])]).lower()))
        if not pw:
            continue
        s = len(words & pw) / max(3, len(pw))
        if best and (best == name or best in name or name in best):
            s += 0.6
        out.append((min(1.0, round(s, 3)), p))
    out.sort(key=lambda x: -x[0])
    return out


MATCH_SURE = 0.80        # perceptual (hash) similarity counted as "this product"
MATCH_TEXT_SURE = 0.6


def matched_reply(lang, p, card):
    return pick(lang, "ছবির পণ্যটি আমাদের কাছে আছে: ", "We have the product in your photo: ") + card


def closest_reply(lang, prods):
    if not prods:
        return pick(lang, "ছবির পণ্যটি আমি নিশ্চিতভাবে খুঁজে পাইনি। দোকানের একজন দেখে জানাবেন।",
                    "I couldn't match the product in your photo for sure. Someone from the shop will check.")
    lines = []
    for p in prods[:3]:
        lines.append("- %s — ৳%s" % (p["name"], BZ._fmt_money(p["price"])) +
                     ("" if int(p.get("stock") or 0) > 0 else pick(lang, " (স্টক নেই)", " (out of stock)")))
    return pick(lang, "হুবহু এটি পাইনি, তবে কাছাকাছি এগুলো আছে:\n", "Not an exact match, but these are close:\n") + \
        "\n".join(lines) + pick(lang, "\nকোনটি নিতে চান লিখুন।", "\nTell us which one you want.")


# ===================================================================== reports
def agent_report(*, chats, orders, revenue, gross_profit, cost_known, ai_cost_bdt,
                 rule_replies, ai_replies, images=0, voice=0):
    """Numbers for the seller's agent report. revenue / gross_profit are from
    orders the AGENT took (cancelled excluded). ai_cost = what the seller paid
    for AI replies/images/voice (credits × credit price)."""
    rev = float(revenue or 0)
    gp = float(gross_profit or 0)
    ai = float(ai_cost_bdt or 0)
    return {"chats": int(chats or 0), "orders": int(orders or 0), "revenue": round(rev, 2),
            "gross_profit": round(gp, 2) if cost_known else None,
            "ai_cost": round(ai, 2),
            "profit": round(gp - ai, 2) if cost_known else None,
            "rule_replies": int(rule_replies or 0), "ai_replies": int(ai_replies or 0),
            "rule_share": round(100.0 * int(rule_replies or 0) /
                                max(1, int(rule_replies or 0) + int(ai_replies or 0)), 1),
            "images": int(images or 0), "voice": int(voice or 0),
            "cost_known": bool(cost_known)}


def morning_text(lang, s):
    """s: {orders, revenue, pending_approvals, unanswered, chats}."""
    title = pick(lang, "সুপ্রভাত! রাতে এজেন্ট যা করেছে", "Good morning! What the agent did overnight")
    body = pick(lang,
                f"অর্ডার {s.get('orders', 0)}টি, মোট ৳{BZ._fmt_money(s.get('revenue', 0))}। "
                f"চ্যাট {s.get('chats', 0)}টি। অনুমোদনের অপেক্ষায় {s.get('pending_approvals', 0)}টি, "
                f"উত্তর বাকি {s.get('unanswered', 0)}টি প্রশ্ন।",
                f"{s.get('orders', 0)} orders, total ৳{BZ._fmt_money(s.get('revenue', 0))}. "
                f"{s.get('chats', 0)} chats. {s.get('pending_approvals', 0)} waiting for approval, "
                f"{s.get('unanswered', 0)} questions unanswered.")
    if s.get("payment_pending"):
        body += pick(lang, f" পেমেন্ট যাচাই বাকি {s['payment_pending']}টি অর্ডারে।",
                     f" {s['payment_pending']} orders need you to verify a payment.")
    return {"title": title, "body": body}


# ===================================================================== widget
_VISITOR_RE = re.compile(r"^[A-Za-z0-9_-]{12,64}$")


def valid_visitor(v):
    return bool(_VISITOR_RE.match(str(v or "")))


def origin_allowed(origin, allowed_text):
    """allowed_text = one origin per line ("https://shop.example"); empty =
    any https origin. http only for localhost testing."""
    o = (origin or "").strip().rstrip("/").lower()
    allowed = [a.strip().rstrip("/").lower() for a in re.split(r"[\s,]+", allowed_text or "")
               if a.strip()]
    if not o:
        return not allowed
    if allowed:
        return o in allowed
    return o.startswith("https://") or o.startswith("http://localhost") or \
        o.startswith("http://127.0.0.1")
