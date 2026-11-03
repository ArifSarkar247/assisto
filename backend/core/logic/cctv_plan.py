"""cctvprice — the CCTV plan (owner's final CCTV order 3 Nov, section H + G7
+ the video add-on prices in D). PURE logic: no DB, no network.

OWNER'S NUMBERS (never change them here without a written owner order):
  base plan     500 tk / month = 2 cameras
  extra camera  250 tk / month each (3 = 750 ... 10 = 2,500)
  more than 10  "contact us" (not sold in the app)
  yearly        exactly 12 x monthly (no free months)
  free trial    7 days on the BASE plan, once per Google account
  video add-on  per camera per month: 7-day clips 100 tk, 30-day clips 150 tk
  phone cameras count as cameras

PLAY BILLING MODEL (why "one product, one base plan per camera count"):
  Play subscriptions have NO quantity (multi-quantity exists only for one-time
  products), so "per-camera" must be expressed as base plans. All counts live
  in ONE subscription product (`cctv_plan`) as base plans c02-monthly ...
  c10-monthly and c02-yearly ... c10-yearly. Changing the count (or monthly
  <-> yearly) is then a Play REPLACEMENT inside the same product
  (linkedPurchaseToken), never a second subscription, and the app already
  uses ReplacementMode.WITH_TIME_PRORATION, which Play accepts for every
  direction (more cameras, fewer cameras, monthly <-> yearly): the switch is
  immediate and the unused paid time is credited by Google. The free trial is
  ONE offer on c02-monthly with Play's eligibility "new customer: never had
  this subscription" -> once per Google account for the whole product (any
  count, any period). The video add-on is a second product (`cctv_video`)
  with base plans d7-c01 ... d7-c10 and d30-c01 ... d30-c10 (monthly).

COST GUARDS (owner_actions/CCTV_DEVICES_COST_BN.md, "pending owner yes"):
  relay live 0.3 GB per camera per month (P2P / LAN unlimited),
  AI snapshot checks 50 per camera per month. Defaults here; editable in
  Owner Admin -> Pricing -> "cctv_plan".
"""
import math
import re

# ---------------------------------------------------------------- prices
BASE_PRICE_BDT = 500
BASE_CAMERAS = 2
EXTRA_CAMERA_BDT = 250
MAX_CAMERAS = 10                 # above this: "contact us"
TRIAL_DAYS = 7
PERIODS = ("monthly", "yearly")
PERIOD_MONTHS = {"monthly": 1, "yearly": 12}
ADDON_DAYS = (7, 30)
ADDON_PRICE_BDT = {7: 100, 30: 150}      # per camera per month

_PLAN_RE = re.compile(r"^c(\d{2})-(monthly|yearly)$")
_ADDON_RE = re.compile(r"^d(7|30)-c(\d{2})$")


def billed_cameras(cameras):
    """The tier a camera count pays for: 1 camera pays the 2-camera base."""
    return max(BASE_CAMERAS, int(cameras))


def monthly_price(cameras):
    """BDT per month for `cameras` (1..10); None above 10 (contact us)."""
    n = int(cameras)
    if n < 1:
        raise ValueError("cameras must be >= 1")
    if n > MAX_CAMERAS:
        return None
    return BASE_PRICE_BDT + EXTRA_CAMERA_BDT * (billed_cameras(n) - BASE_CAMERAS)


def price(cameras, period="monthly"):
    """Exact price of one billing period. Yearly = exactly 12 x monthly."""
    m = monthly_price(cameras)
    if m is None:
        return None
    return m * PERIOD_MONTHS[period]


def addon_price(days, cameras=1):
    if days not in ADDON_PRICE_BDT:
        raise ValueError("add-on is 7 or 30 days")
    return ADDON_PRICE_BDT[days] * int(cameras)


def base_plan_id(cameras, period="monthly"):
    if period not in PERIODS:
        raise ValueError("period")
    n = billed_cameras(cameras)
    if n > MAX_CAMERAS:
        raise ValueError("contact us above %d" % MAX_CAMERAS)
    return "c%02d-%s" % (n, period)


def parse_base_plan(bp):
    """'c03-yearly' -> (3, 'yearly'); None when not ours."""
    m = _PLAN_RE.match(str(bp or ""))
    if not m:
        return None
    n = int(m.group(1))
    if not BASE_CAMERAS <= n <= MAX_CAMERAS:
        return None
    return n, m.group(2)


def addon_plan_id(days, cameras):
    n = int(cameras)
    if days not in ADDON_DAYS or not 1 <= n <= MAX_CAMERAS:
        raise ValueError("add-on")
    return "d%d-c%02d" % (days, n)


def parse_addon_plan(bp):
    """'d7-c03' -> (7, 3); None when not ours."""
    m = _ADDON_RE.match(str(bp or ""))
    if not m:
        return None
    n = int(m.group(2))
    if not 1 <= n <= MAX_CAMERAS:
        return None
    return int(m.group(1)), n


def plan_sku(cameras, period):
    return "cctv_c%02d_%s" % (cameras, "m" if period == "monthly" else "y")


def addon_sku(days, cameras):
    return "cctvv_d%d_c%02d" % (days, cameras)


def all_base_plans():
    return [base_plan_id(n, p) for p in PERIODS
            for n in range(BASE_CAMERAS, MAX_CAMERAS + 1)]


def all_addon_plans():
    return [addon_plan_id(d, n) for d in ADDON_DAYS
            for n in range(1, MAX_CAMERAS + 1)]


def tiers():
    """The tier picker: 1..10 cameras with exact monthly + yearly prices."""
    return [{"cameras": n, "billed_cameras": billed_cameras(n),
             "monthly": price(n, "monthly"), "yearly": price(n, "yearly"),
             "base_plan_monthly": base_plan_id(n, "monthly"),
             "base_plan_yearly": base_plan_id(n, "yearly")}
            for n in range(1, MAX_CAMERAS + 1)]


# ---------------------------------------------------------------- config
DEFAULTS = {
    # selling switch: off until the owner has created the Play products
    "on_sale": False,
    "product_id": "cctv_plan",
    "addon_product_id": "cctv_video",
    "trial_offer_id": "trial-7d",
    # cost guards (pending owner yes)
    "limits_owner_confirmed": False,
    "relay_mb_per_camera": 300,          # 0.3 GB relay live / camera / month
    "ai_checks_per_camera": 50,          # AI snapshot checks / camera / month
    # cctvcap (owner 3 Nov 10:40): one-tap "extra pack" for THIS month, paid
    # with credits. Prices keep the profit table >= 40 % (relay worst case
    # 50 tk/GB -> 150 tk = 40.6 %; AI 100 x 0.25 tk -> 80 tk = 42.7 %).
    "extra_relay_mb": 1000,              # relay pack: +1 GB this month
    "extra_relay_bdt": 150,
    "extra_ai_checks": 100,              # AI pack: +100 checks this month
    "extra_ai_bdt": 80,
    # unpaid end -> unbind -> keep -> delete
    "unbind_after_days": 3,
    "keep_days": 30,
    # worst-case cost assumptions (CCTV_DEVICES_COST_BN.md, 2 Nov 2026)
    "usd_bdt": 125.0,
    "ezviz_device_usd_year": 4.5,
    "ezviz_traffic_usd_gb": 0.4,
    "imou_device_bdt_month": 10.8,
    "imou_traffic_usd_gb": 0.25,
    "turn_bdt_per_gb": 11.0,             # phone camera relayed by our TURN
    "ai_check_usd": 0.002,
    "server_bdt_per_camera": 8.0,
    "snapshot_bdt_per_camera": 0.2,
    "clip_mb": 0.64,
    "clips_per_day": 30,
    "storage_usd_gb_month": 0.023,
    "play_fee": 0.15,
    "vat": 0.15,
}
_INT_BOUNDS = {"relay_mb_per_camera": (0, 5000), "ai_checks_per_camera": (0, 1000),
               "unbind_after_days": (1, 30), "keep_days": (30, 90),
               "clips_per_day": (0, 100),
               "extra_relay_mb": (100, 10000), "extra_relay_bdt": (10, 5000),
               "extra_ai_checks": (10, 1000), "extra_ai_bdt": (10, 5000)}
_NUM_BOUNDS = {"usd_bdt": (50.0, 500.0), "ezviz_device_usd_year": (0.0, 100.0),
               "ezviz_traffic_usd_gb": (0.0, 10.0), "imou_device_bdt_month": (0.0, 1000.0),
               "imou_traffic_usd_gb": (0.0, 10.0), "turn_bdt_per_gb": (0.0, 500.0),
               "ai_check_usd": (0.0, 1.0), "server_bdt_per_camera": (0.0, 500.0),
               "snapshot_bdt_per_camera": (0.0, 100.0), "clip_mb": (0.0, 50.0),
               "storage_usd_gb_month": (0.0, 1.0), "play_fee": (0.0, 0.5),
               "vat": (0.0, 0.5)}
_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_.]{1,39}$")
_OFFER_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


def _int(v, d):
    try:
        if isinstance(v, bool):
            raise TypeError
        return int(float(v))
    except (TypeError, ValueError):
        return d


def _num(v, d):
    try:
        if isinstance(v, bool):
            raise TypeError
        x = float(v)
        return x if math.isfinite(x) else d
    except (TypeError, ValueError):
        return d


def _pid(v, d):
    """A Play product id; never an `assisto_*` id (the app's plan-change code
    treats every assisto_* subscription as ONE family — a CCTV purchase must
    never replace the Premium/Business subscription)."""
    s = str(v or "").strip()
    if not _ID_RE.match(s) or s.startswith("assisto_"):
        return d
    return s


def normalize_cfg(raw):
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    for k, d in DEFAULTS.items():
        v = raw.get(k, d)
        if k in _INT_BOUNDS:
            lo, hi = _INT_BOUNDS[k]
            out[k] = max(lo, min(hi, _int(v, d)))
        elif k in _NUM_BOUNDS:
            lo, hi = _NUM_BOUNDS[k]
            out[k] = max(lo, min(hi, _num(v, d)))
        elif k in ("on_sale", "limits_owner_confirmed"):
            out[k] = v if isinstance(v, bool) else d
        elif k in ("product_id", "addon_product_id"):
            out[k] = _pid(v, d)
        elif k == "trial_offer_id":
            s = str(v or "").strip()
            out[k] = s if _OFFER_RE.match(s) else d
    if out["addon_product_id"] == out["product_id"]:
        out["addon_product_id"] = DEFAULTS["addon_product_id"]
        if out["product_id"] == out["addon_product_id"]:
            out["product_id"] = DEFAULTS["product_id"]
    return out


def defaults():
    return dict(DEFAULTS)


# ---------------------------------------------------------------- costs (G7)
VENDORS = ("ezviz", "imou", "phone")


def net_share(c):
    """What reaches us from 1 tk of price: VAT is inside the price, Play takes
    its fee from the rest (0.85 / 1.15 = 0.739, PRICING_40PCT_BN.md)."""
    return (1.0 - c["play_fee"]) / (1.0 + c["vat"])


def camera_cost_bdt(c, vendor):
    """Worst case cost of ONE camera for one month at the current guards
    (every relay MB used, every AI check used)."""
    usd = c["usd_bdt"]
    relay_gb = c["relay_mb_per_camera"] / 1000.0
    common = (c["snapshot_bdt_per_camera"] + c["server_bdt_per_camera"]
              + c["ai_checks_per_camera"] * c["ai_check_usd"] * usd)
    if vendor == "ezviz":
        dev = c["ezviz_device_usd_year"] / 12.0 * usd
        relay = relay_gb * c["ezviz_traffic_usd_gb"] * usd
    elif vendor == "imou":
        dev = c["imou_device_bdt_month"]
        relay = relay_gb * c["imou_traffic_usd_gb"] * usd
    elif vendor == "phone":
        dev = 0.0
        relay = relay_gb * c["turn_bdt_per_gb"]
    else:
        raise ValueError(vendor)
    return {"vendor": vendor, "device": round(dev, 2), "relay": round(relay, 2),
            "snapshots_server_ai": round(common, 2),
            "total": round(dev + relay + common, 2)}


def worst_camera_cost_bdt(c):
    return max(camera_cost_bdt(c, v)["total"] for v in VENDORS)


def _worst_traffic_bdt_gb(c):
    usd = c["usd_bdt"]
    return max(c["ezviz_traffic_usd_gb"] * usd, c["imou_traffic_usd_gb"] * usd,
               c["turn_bdt_per_gb"])


def addon_cost_bdt(c, days):
    """Worst case: the clip cap is full every day of the month."""
    usd = c["usd_bdt"]
    month_gb = c["clips_per_day"] * 30 * c["clip_mb"] / 1000.0
    kept_gb = c["clips_per_day"] * days * c["clip_mb"] / 1000.0
    traffic = month_gb * _worst_traffic_bdt_gb(c)
    storage = kept_gb * c["storage_usd_gb_month"] * usd
    return round(traffic + storage, 2)


# cctvcap: the extra packs (Play one-time products later — the seam; today
# they are paid with Assisto credits). Kinds and their Play product ids.
PACK_KINDS = ("relay", "ai")
PACK_PLAY_PRODUCTS = {"relay": "cctv_extra_relay_1gb", "ai": "cctv_extra_ai_100"}


def pack_cost_bdt(c, kind):
    """Worst case cost of one extra pack, fully used."""
    if kind == "relay":
        return round(c["extra_relay_mb"] / 1000.0 * _worst_traffic_bdt_gb(c), 2)
    if kind == "ai":
        return round(c["extra_ai_checks"] * c["ai_check_usd"] * c["usd_bdt"], 2)
    raise ValueError(kind)


def packs(cfg=None):
    """The two packs as the app shows them: size + price (tk)."""
    c = normalize_cfg(cfg)
    return {"relay": {"kind": "relay", "mb": c["extra_relay_mb"],
                      "price_bdt": c["extra_relay_bdt"],
                      "play_product": PACK_PLAY_PRODUCTS["relay"]},
            "ai": {"kind": "ai", "checks": c["extra_ai_checks"],
                   "price_bdt": c["extra_ai_bdt"],
                   "play_product": PACK_PLAY_PRODUCTS["ai"]}}


def _row(price_bdt, cost, share):
    net = price_bdt * share
    profit = net - cost
    return {"price": price_bdt, "net": round(net, 2), "cost": round(cost, 2),
            "profit": round(profit, 2),
            "pct": round(100.0 * profit / price_bdt, 1) if price_bdt else 0.0}


def profit_table(cfg=None, target_pct=40.0):
    """Per tier 1..10 (monthly; yearly is 12x price AND 12x cost, so the
    percent is the same) + the two add-ons, worst case after Play fee + VAT.
    `ok` is False when ANY row is below `target_pct`."""
    c = normalize_cfg(cfg)
    share = net_share(c)
    per_cam = worst_camera_cost_bdt(c)
    rows = []
    for n in range(1, MAX_CAMERAS + 1):
        r = _row(monthly_price(n), per_cam * n, share)
        r.update(cameras=n, yearly_price=price(n, "yearly"))
        rows.append(r)
    adds = []
    for d in ADDON_DAYS:
        r = _row(ADDON_PRICE_BDT[d], addon_cost_bdt(c, d), share)
        r.update(days=d)
        adds.append(r)
    pk = []
    for k in PACK_KINDS:
        r = _row(c["extra_%s_bdt" % k], pack_cost_bdt(c, k), share)
        r.update(kind=k)
        pk.append(r)
    low = min(r["pct"] for r in rows + adds + pk)
    return {"tiers": rows, "addons": adds, "packs": pk, "per_camera_cost": per_cam,
            "per_vendor": [camera_cost_bdt(c, v) for v in VENDORS],
            "net_share": round(share, 4), "min_pct": low,
            "target_pct": target_pct, "ok": low >= target_pct,
            "limits": {"relay_mb_per_camera": c["relay_mb_per_camera"],
                       "ai_checks_per_camera": c["ai_checks_per_camera"],
                       "owner_confirmed": c["limits_owner_confirmed"]}}


# ---------------------------------------------------------------- unpaid end
# status: "active" (paid or trial or Google's grace) | "hold" (payment failed,
# Google's account hold / paused: no access, still recoverable) | "ended"
# (expired / cancelled / revoked) | "none" (never had the plan)
def lifecycle_step(state, status, now_ts, c):
    """The next action for one account. `state` is the stored dict (epoch
    seconds), returns (action, new_state). Actions:
      none | restore | notice_hold | notice_ended | notice_unbind_soon |
      unbind | notice_delete_soon | delete
    A clear Bangla notice goes out BEFORE each step (ended -> reminder 1 day
    before unbind -> unbind -> reminder 3 days before delete -> delete)."""
    s = dict(state or {})
    sent = list(s.get("sent") or [])
    day = 86400
    if status == "active":
        if s.get("ended_at") or s.get("hold_at"):
            keep = {k: s[k] for k in ("addon_cams",) if k in s}
            keep["disabled_ids"] = s.get("disabled_ids") or []
            return ("restore" if s.get("ended_at") else "none"), keep
        return "none", s
    if status == "hold":
        if not s.get("hold_at"):
            s["hold_at"] = now_ts
            s["sent"] = sent + ["hold"]
            return "notice_hold", s
        return "none", s
    if status != "ended":
        return "none", s
    if s.get("deleted_at"):
        return "none", s
    if not s.get("ended_at"):
        s["ended_at"] = now_ts
        s["unbind_at"] = now_ts + c["unbind_after_days"] * day
        s["sent"] = sent + ["ended"]
        return "notice_ended", s
    if not s.get("unbound_at"):
        if now_ts >= s["unbind_at"]:
            s["unbound_at"] = now_ts
            s["delete_at"] = now_ts + c["keep_days"] * day
            s["sent"] = sent + ["unbound"]
            return "unbind", s
        if now_ts >= s["unbind_at"] - day and "unbind_soon" not in sent:
            s["sent"] = sent + ["unbind_soon"]
            return "notice_unbind_soon", s
        return "none", s
    if now_ts >= s["delete_at"]:
        s["deleted_at"] = now_ts
        s["sent"] = sent + ["deleted"]
        return "delete", s
    if now_ts >= s["delete_at"] - 3 * day and "delete_soon" not in sent:
        s["sent"] = sent + ["delete_soon"]
        return "notice_delete_soon", s
    return "none", s


_BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_num(x):
    return str(x).translate(_BN_DIGITS)


def notice_text(action, date_str_bn="", date_str_en=""):
    """(title_bn, title_en, body_bn, body_en) for each lifecycle notice."""
    d_bn, d_en = date_str_bn, date_str_en
    T = {
        "notice_hold": (
            "সিসিটিভি প্ল্যানের পেমেন্ট হয়নি",
            "CCTV plan payment failed",
            "Google Play-তে আপনার পেমেন্ট হয়নি, তাই ক্যামেরা দেখা এখন বন্ধ। "
            "Google Play → সাবস্ক্রিপশন থেকে পেমেন্ট ঠিক করুন — সাথে সাথে আবার চালু হবে। "
            "Google পেমেন্টের চেষ্টা বন্ধ করলে প্ল্যান শেষ হবে।",
            "Your Google Play payment failed, so camera viewing is paused. Fix the "
            "payment in Google Play -> Subscriptions and it switches back on at once. "
            "If Google stops retrying, the plan ends."),
        "notice_ended": (
            "সিসিটিভি প্ল্যান শেষ হয়েছে",
            "Your CCTV plan has ended",
            "পেমেন্ট ছাড়া প্ল্যান শেষ। %s তারিখে ক্যামেরাগুলো Assisto থেকে খুলে দেওয়া "
            "হবে (ক্যামেরা নিজের অ্যাপে আবার যোগ করতে পারবেন)। আপনার ছবি ও তথ্য এরপর "
            "৩০ দিন রাখা হবে, তারপর মুছে যাবে। আবার চালু করতে প্ল্যান কিনুন।" % d_bn,
            "The plan ended without payment. On %s the cameras will be released from "
            "Assisto (you can add them to their own app again). Your photos and data "
            "are then kept for 30 days and deleted after that. Buy the plan to keep "
            "them." % d_en),
        "notice_unbind_soon": (
            "আগামীকাল ক্যামেরা খুলে দেওয়া হবে",
            "Cameras will be released tomorrow",
            "%s তারিখে ক্যামেরাগুলো Assisto থেকে খুলে দেওয়া হবে। রাখতে চাইলে আজই প্ল্যান কিনুন।" % d_bn,
            "On %s the cameras will be released from Assisto. Buy the plan today "
            "to keep them." % d_en),
        "unbind": (
            "ক্যামেরা Assisto থেকে খুলে দেওয়া হয়েছে",
            "Cameras released from Assisto",
            "প্ল্যান না থাকায় ক্যামেরাগুলো খুলে দেওয়া হয়েছে। আপনার ছবি ও তথ্য %s পর্যন্ত "
            "রাখা হবে, তারপর মুছে যাবে। প্ল্যান কিনে ক্যামেরা আবার যোগ করলে সব ফিরে পাবেন।" % d_bn,
            "With no plan, the cameras were released. Your photos and data are kept "
            "until %s and deleted after that. Buy the plan and add the cameras again "
            "to get everything back." % d_en),
        "notice_delete_soon": (
            "৩ দিন পর সিসিটিভির তথ্য মুছে যাবে",
            "CCTV data will be deleted in 3 days",
            "%s তারিখে আপনার সিসিটিভির ছবি, সতর্কতা ও সেটিংস স্থায়ীভাবে মুছে যাবে। "
            "রাখতে চাইলে প্ল্যান কিনুন বা দরকারি ছবি এখনই সেভ করুন।" % d_bn,
            "On %s your CCTV photos, alerts and settings will be deleted for good. "
            "Buy the plan to keep them, or save the photos you need now." % d_en),
        "delete": (
            "সিসিটিভির তথ্য মুছে ফেলা হয়েছে",
            "CCTV data deleted",
            "৩০ দিন পার হওয়ায় আপনার সিসিটিভির তথ্য মুছে ফেলা হয়েছে। নতুন করে শুরু করতে প্ল্যান কিনুন।",
            "After 30 days your CCTV data was deleted. Buy the plan to start again."),
        "restore": (
            "সিসিটিভি প্ল্যান আবার চালু",
            "CCTV plan is back on",
            "স্বাগতম! প্ল্যান চালু হয়েছে। খুলে দেওয়া ক্লাউড ক্যামেরা থাকলে সেগুলো আবার যোগ করুন।",
            "Welcome back! The plan is on. If cameras were released, add them again."),
    }
    return T.get(action)


def unpaid_line():
    """The one clear line the plan screen shows (bn, en)."""
    return ("পেমেন্ট না হলে: Google-এর অপেক্ষার সময় শেষে ক্যামেরা Assisto থেকে খুলে "
            "দেওয়া হবে, আপনার তথ্য ৩০ দিন রাখা হবে, তারপর মুছে যাবে — প্রতিটি ধাপের "
            "আগে নোটিশ পাবেন।",
            "If unpaid: after Google's waiting time the cameras are released from "
            "Assisto, your data is kept 30 days and then deleted — you get a notice "
            "before every step.")
