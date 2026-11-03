"""safeplans — Safety plans, monthly credits, prepaid packs and rewarded-ad
unlocks (owner order 3 Nov 18:40, PARTS 2 3 4 5). PURE logic: no DB, no
network. The DB side is core/safe_plans.py.

OWNER'S NUMBERS (never change them here without a written owner order; the
owner edits them in Owner Admin -> Safety plans, stored in PricingConfig under
"safe_plans"):
  Child Plan    30 tk / month: 1 child, 2 guardians, unlimited automatic school
                arrive/leave alerts, 15 location requests / month
  Safe Family   99 tk / month: up to 15 members, any number of children,
                150 credits / month (location request 1, live trip + ETA 3),
                30-day history, 5-minute updates
  School Safe   20 tk / student / month, minimum 100 students, invoiced to the
                school OUTSIDE Google Play; a school code unlocks it for
                parents; up to 4 guardians per student, bus live location,
                10 requests / student / month, gate attendance list, one-tap
                broadcast to all parents
  Credits       reset every month, NO rollover. Extra requests only with
                PREPAID Play consumable packs (smallest 10 tk = 10 requests),
                never postpaid, never cash.
  Rewarded ads  3 ads -> 1 day of Child Plan; 3 ads -> 1 request. Guardians
                only, never child accounts, never on SOS / safety screens.
  ALWAYS FREE   SOS, danger alerts and automatic school alerts are never
                blocked by plans, credits or ads (ALWAYS_FREE below; the
                service returns "allowed, nothing charged" for them BEFORE it
                looks at any plan, flag or balance).

ENGINEERING DEFAULTS chosen by safeplans (reversible, Owner Admin editable,
listed in the feature card):
  free (no plan)           3 requests / month
  pack validity            30 days from purchase (a pack bought on the 30th is
                           not lost the next day; still no rollover beyond)
  extra packs              30 tk = 30, 100 tk = 100 (same 1 tk / request)
  day pass requests        1 request inside the ad day pass
  ad caps                  1 day pass / day, 3 ad requests / day
  paid map calls           capped per account per month (child 8, family 30,
                           school 2 per student, free / ads / packs 0): beyond
                           the cap the phone's free geocoder and a straight-line
                           ETA are used. This cap is what keeps every plan at
                           >= 40 % worst case (profit_table).
"""
import math
import re

ALWAYS_FREE = frozenset({"sos", "danger_alert", "school_auto_alert"})
ACTIONS = ("location_request", "live_trip")
PLANS = ("free", "child", "family", "school")
SUB_PLANS = ("child", "family")

_PID_RE = re.compile(r"^[a-z][a-z0-9_.]{1,39}$")
_BASE_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_CODE_RE = re.compile(r"^[A-Z0-9]{4,12}$")

DEFAULTS = {
    # selling switch: OFF until the owner has created the Play products
    "on_sale": False,
    # --- PART 2 plans (owner prices)
    "child_price_bdt": 30,
    "child_requests": 15,
    "child_children": 1,
    "child_guardians": 2,
    "child_history_days": 7,
    "child_update_min": 15,
    "family_price_bdt": 99,
    "family_credits": 150,
    "family_members": 15,
    "family_history_days": 30,
    "family_update_min": 5,
    "school_price_bdt": 20,          # per student per month (invoice)
    "school_min_students": 100,
    "school_guardians": 4,
    "school_requests": 10,           # per student per month
    "free_requests": 3,
    "free_guardians": 2,
    # credit costs
    "cost_location_request": 1,
    "cost_live_trip": 3,
    # --- PART 3 packs (prepaid Play consumables)
    "pack_valid_days": 30,
    "packs": [{"id": "safe_req_10", "requests": 10, "price_bdt": 10},
              {"id": "safe_req_30", "requests": 30, "price_bdt": 30},
              {"id": "safe_req_100", "requests": 100, "price_bdt": 100}],
    # Play ids (owner creates them in Play Console; we never do)
    "child_product_id": "safe_child",
    "family_product_id": "safe_family",
    "base_plan_id": "monthly",
    # --- PART 4 rewarded ads
    "ads_for_day": 3,
    "ads_for_request": 3,
    "day_pass_hours": 24,
    "day_pass_requests": 1,
    "day_unlocks_per_day": 1,
    "request_unlocks_per_day": 3,
    # --- worst-case cost assumptions (for the 40 % table)
    "usd_bdt": 125.0,
    "paid_map_call_usd": 0.005,      # Geocoding / Routes ~5 USD per 1000
    "request_server_bdt": 0.02,      # push + DB rows per request
    "member_server_bdt": 0.5,        # per member per month (5-min updates incl.)
    "sms_bdt": 0.35,                 # one SMS part (fallback alerts)
    "sms_per_account": 2,            # worst-case SMS fallbacks / account / month
    "sms_per_student": 4,
    "paid_maps_child": 8,            # paid map calls / account / month (cap)
    "paid_maps_family": 30,
    "paid_maps_school": 2,           # per student
    "ad_value_bdt_low": 0.25,        # worst-case value of one verified rewarded ad
    "invoice_fee": 0.02,             # bank / collection cost on school invoices
    "play_fee": 0.15,
    "vat": 0.15,
    # --- School Safe customers (added by the owner; never sold in the app)
    "schools": {},
}

_INT = {"child_price_bdt": (1, 5000), "child_requests": (0, 10000),
        "child_children": (1, 10), "child_guardians": (1, 10),
        "child_history_days": (0, 365), "child_update_min": (1, 60),
        "family_price_bdt": (1, 10000), "family_credits": (0, 100000),
        "family_members": (2, 50), "family_history_days": (0, 365),
        "family_update_min": (1, 60),
        "school_price_bdt": (1, 1000), "school_min_students": (1, 100000),
        "school_guardians": (1, 10), "school_requests": (0, 1000),
        "free_requests": (0, 100), "free_guardians": (1, 10),
        "cost_location_request": (1, 100), "cost_live_trip": (1, 100),
        "pack_valid_days": (1, 365),
        "ads_for_day": (1, 20), "ads_for_request": (1, 20),
        "day_pass_hours": (1, 72), "day_pass_requests": (0, 20),
        "day_unlocks_per_day": (0, 10), "request_unlocks_per_day": (0, 50),
        "sms_per_account": (0, 100), "sms_per_student": (0, 100),
        "paid_maps_child": (0, 1000), "paid_maps_family": (0, 5000),
        "paid_maps_school": (0, 100)}
_NUM = {"usd_bdt": (1.0, 1000.0), "paid_map_call_usd": (0.0, 1.0),
        "request_server_bdt": (0.0, 50.0), "member_server_bdt": (0.0, 100.0),
        "sms_bdt": (0.0, 10.0), "ad_value_bdt_low": (0.0, 50.0),
        "invoice_fee": (0.0, 0.5), "play_fee": (0.0, 0.5), "vat": (0.0, 0.5)}


def _int(v, d):
    try:
        if isinstance(v, bool):
            return d
        return int(float(v))
    except (TypeError, ValueError):
        return d


def _num(v, d):
    try:
        if isinstance(v, bool):
            return d
        f = float(v)
        return f if math.isfinite(f) else d
    except (TypeError, ValueError):
        return d


def _pid(v, d):
    s = str(v or "").strip()
    return s if _PID_RE.match(s) else d


def norm_code(v):
    return re.sub(r"[^A-Z0-9]", "", str(v or "").upper())[:12]


def _norm_packs(raw):
    out, seen = [], set()
    for p in raw if isinstance(raw, list) else []:
        if not isinstance(p, dict):
            continue
        pid = _pid(p.get("id"), "")
        n = _int(p.get("requests"), 0)
        price = _int(p.get("price_bdt"), 0)
        if not pid or pid in seen or not (1 <= n <= 10000) or not (1 <= price <= 10000):
            continue
        seen.add(pid)
        out.append({"id": pid, "requests": n, "price_bdt": price})
    if not out:
        out = [dict(p) for p in DEFAULTS["packs"]]
    return sorted(out, key=lambda p: p["price_bdt"])[:6]


def _norm_school(code, s):
    s = s if isinstance(s, dict) else {}
    ids = []
    for key in ("admin_ids", "driver_ids"):
        ids.append(sorted({_int(i, 0) for i in (s.get(key) or []) if _int(i, 0) > 0})[:20])
    return {"code": code, "name": str(s.get("name") or "")[:80],
            "students": max(0, _int(s.get("students"), 0)),
            "paid_until": str(s.get("paid_until") or "")[:10],
            "invoice_ref": str(s.get("invoice_ref") or "")[:40],
            "active": s.get("active") is not False,
            "admin_ids": ids[0], "driver_ids": ids[1]}


def normalize_cfg(raw):
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    for k, d in DEFAULTS.items():
        v = raw.get(k, d)
        if k in _INT:
            lo, hi = _INT[k]
            out[k] = max(lo, min(hi, _int(v, d)))
        elif k in _NUM:
            lo, hi = _NUM[k]
            out[k] = max(lo, min(hi, _num(v, d)))
        elif k == "on_sale":
            out[k] = v if isinstance(v, bool) else d
        elif k in ("child_product_id", "family_product_id"):
            out[k] = _pid(v, d)
        elif k == "base_plan_id":
            s = str(v or "").strip()
            out[k] = s if _BASE_RE.match(s) else d
        elif k == "packs":
            out[k] = _norm_packs(v)
        elif k == "schools":
            sc = {}
            for code, s in (v.items() if isinstance(v, dict) else []):
                c = norm_code(code)
                if _CODE_RE.match(c):
                    sc[c] = _norm_school(c, s)
            out[k] = sc
    if out["family_product_id"] == out["child_product_id"]:
        out["child_product_id"], out["family_product_id"] = (
            DEFAULTS["child_product_id"], DEFAULTS["family_product_id"])
    return out


def defaults():
    return normalize_cfg({})


def problems(raw):
    """Refused (not clamped) edits so the owner sees the reason."""
    if raw is None:
        return []
    if not isinstance(raw, dict):
        return ["bad_safe_plans"]
    out = []
    for k, (lo, hi) in list(_INT.items()) + list(_NUM.items()):
        if k in raw:
            v = _num(raw.get(k), None)
            if v is None or v < lo or v > hi:
                out.append("bad_safe_plans")
    for code, s in (raw.get("schools") or {}).items() if isinstance(raw.get("schools"), dict) else []:
        if not _CODE_RE.match(norm_code(code)):
            out.append("bad_school_code")
        elif isinstance(s, dict) and 0 < _int(s.get("students"), 0) < _int(
                raw.get("school_min_students", DEFAULTS["school_min_students"]), 100):
            out.append("school_below_minimum")
    return sorted(set(out))


# ---------------------------------------------------------------- products
def pack(c, product_id):
    for p in c["packs"]:
        if p["id"] == product_id:
            return p
    return None


def plan_for_product(c, product_id):
    if product_id == c["child_product_id"]:
        return "child"
    if product_id == c["family_product_id"]:
        return "family"
    return None


def play_products(c=None):
    """Every Play Console item the OWNER must create (never created by us)."""
    c = normalize_cfg(c)
    subs = [{"type": "subscription", "product_id": c["child_product_id"],
             "base_plan_id": c["base_plan_id"], "period": "P1M",
             "price_bdt": c["child_price_bdt"], "renewal": "auto-renewing",
             "name_en": "Child Plan", "name_bn": "চাইল্ড প্ল্যান"},
            {"type": "subscription", "product_id": c["family_product_id"],
             "base_plan_id": c["base_plan_id"], "period": "P1M",
             "price_bdt": c["family_price_bdt"], "renewal": "auto-renewing",
             "name_en": "Safe Family", "name_bn": "সেফ ফ্যামিলি"}]
    packs = [{"type": "consumable", "product_id": p["id"], "price_bdt": p["price_bdt"],
              "requests": p["requests"],
              "name_en": "%d location requests" % p["requests"],
              "name_bn": "%d লোকেশন অনুরোধ" % p["requests"]} for p in c["packs"]]
    return subs + packs


# ---------------------------------------------------------------- periods
def period_key(dt):
    """Calendar month (Asia/Dhaka is applied by the caller). Credits reset
    on the 1st; nothing carries over."""
    return "%04d-%02d" % (dt.year, dt.month)


def day_key(dt):
    return "%04d-%02d-%02d" % (dt.year, dt.month, dt.day)


def roll_period(state, pkey):
    """Start a new month: the monthly allowance and ad-earned requests are
    WIPED (no rollover). Packs keep their own 30-day expiry."""
    s = dict(state or {})
    if s.get("period") != pkey:
        s["period"] = pkey
        s["used"] = 0
        s["school_used"] = {}
        s["ad_requests"] = 0
        s["paid_maps"] = 0
    return s


def allowance(c, plan):
    return {"free": c["free_requests"], "child": c["child_requests"],
            "family": c["family_credits"], "school": 0}.get(plan, 0)


def action_cost(c, action):
    if action in ALWAYS_FREE:
        return 0
    if action == "live_trip":
        return c["cost_live_trip"]
    return c["cost_location_request"]


def guardian_limit(c, plan, school=False):
    if school:
        return c["school_guardians"]
    if plan == "child":
        return c["child_guardians"]
    if plan == "family":
        return c["family_members"]
    return c["free_guardians"]


def live_packs(state, now_ts):
    return [p for p in (state.get("packs") or [])
            if p.get("left", 0) > 0 and p.get("exp", 0) > now_ts and not p.get("revoked")]


def balance(c, state, plan, now_ts, school_left=0):
    """{monthly, school, day_pass, ads, packs, total} requests/credits left."""
    monthly = max(0, allowance(c, plan) - int(state.get("used") or 0))
    dp = 0
    if (state.get("day_pass_until") or 0) > now_ts:
        dp = max(0, int(state.get("day_pass_left") or 0))
    ads = max(0, int(state.get("ad_requests") or 0))
    packs = sum(p["left"] for p in live_packs(state, now_ts))
    return {"monthly": monthly, "school": max(0, school_left), "day_pass": dp,
            "ads": ads, "packs": packs,
            "total": monthly + max(0, school_left) + dp + ads + packs}


def spend(c, state, plan, cost, now_ts, school_left=0):
    """Take `cost` from the buckets in order: school (per student) -> monthly
    plan -> ad day pass -> ad requests -> packs (soonest expiry first).
    Returns (ok, new_state, took) — took = {bucket: n} (school as 'school').
    All or nothing: when the total is short nothing changes."""
    s = dict(state or {})
    if cost <= 0:
        return True, s, {}
    b = balance(c, s, plan, now_ts, school_left)
    if b["total"] < cost:
        return False, state, {}
    need, took = cost, {}

    def take(bucket, avail):
        nonlocal need
        n = min(need, avail)
        if n > 0:
            took[bucket] = took.get(bucket, 0) + n
            need -= n
        return n

    take("school", b["school"])
    s["used"] = int(s.get("used") or 0) + take("monthly", b["monthly"])
    s["day_pass_left"] = int(s.get("day_pass_left") or 0) - take("day_pass", b["day_pass"])
    s["ad_requests"] = int(s.get("ad_requests") or 0) - take("ads", b["ads"])
    if need > 0:
        packs = [dict(p) for p in (s.get("packs") or [])]
        for p in sorted([p for p in packs if p.get("left", 0) > 0
                         and p.get("exp", 0) > now_ts and not p.get("revoked")],
                        key=lambda p: p.get("exp", 0)):
            n = take("packs", p["left"])
            p["left"] -= n
            if need <= 0:
                break
        s["packs"] = packs
    return True, s, took


def refund(state, took):
    """Give back what spend() took (the request could not be sent)."""
    s = dict(state or {})
    s["used"] = max(0, int(s.get("used") or 0) - took.get("monthly", 0))
    s["day_pass_left"] = int(s.get("day_pass_left") or 0) + took.get("day_pass", 0)
    s["ad_requests"] = int(s.get("ad_requests") or 0) + took.get("ads", 0)
    n = took.get("packs", 0)
    if n:
        packs = [dict(p) for p in (s.get("packs") or [])]
        for p in sorted(packs, key=lambda p: -p.get("exp", 0)):
            if p.get("revoked"):
                continue
            give = min(n, int(p.get("n", 0)) - int(p.get("left", 0)))
            p["left"] += give
            n -= give
            if n <= 0:
                break
        s["packs"] = packs
    return s


def add_pack(c, state, token_hash, requests, now_ts):
    """Grant a verified pack once per token (idempotent)."""
    s = dict(state or {})
    packs = [dict(p) for p in (s.get("packs") or [])]
    if any(p.get("t") == token_hash for p in packs):
        return False, s
    packs.append({"t": token_hash, "n": int(requests), "left": int(requests),
                  "at": now_ts, "exp": now_ts + c["pack_valid_days"] * 86400})
    # keep the list small: drop packs that ended more than 60 days ago
    s["packs"] = [p for p in packs if p["exp"] > now_ts - 60 * 86400][-50:]
    return True, s


def revoke_pack(state, token_hash):
    s = dict(state or {})
    packs = [dict(p) for p in (s.get("packs") or [])]
    hit = False
    for p in packs:
        if p.get("t") == token_hash and not p.get("revoked"):
            p["revoked"], p["left"], hit = True, 0, True
    s["packs"] = packs
    return hit, s


# ---------------------------------------------------------------- rewarded ads
GOALS = ("day", "request")


def ad_progress(state, dkey):
    a = dict(state.get("ads") or {})
    if a.get("day") != dkey:
        a = {"day": dkey, "day_n": 0, "req_n": 0, "day_unlocks": 0, "req_unlocks": 0}
    return a


def ad_can_start(c, state, goal, dkey):
    a = ad_progress(state, dkey)
    if goal == "day":
        return a["day_unlocks"] < c["day_unlocks_per_day"]
    return a["req_unlocks"] < c["request_unlocks_per_day"]


def ad_verified(c, state, goal, now_ts, dkey):
    """One Google-verified rewarded ad toward `goal`. Returns (new_state,
    unlocked: None | 'day' | 'request'). Over the daily cap nothing counts."""
    s = dict(state or {})
    a = ad_progress(s, dkey)
    unlocked = None
    if goal == "day":
        if a["day_unlocks"] >= c["day_unlocks_per_day"]:
            return s, None
        a["day_n"] += 1
        if a["day_n"] >= c["ads_for_day"]:
            a["day_n"] = 0
            a["day_unlocks"] += 1
            old_until = int(s.get("day_pass_until") or 0)
            carry = int(s.get("day_pass_left") or 0) if old_until > now_ts else 0
            s["day_pass_until"] = max(now_ts, old_until) + c["day_pass_hours"] * 3600
            s["day_pass_left"] = c["day_pass_requests"] + carry
            s["unlocks_day"] = int(s.get("unlocks_day") or 0) + 1
            unlocked = "day"
    else:
        if a["req_unlocks"] >= c["request_unlocks_per_day"]:
            return s, None
        a["req_n"] += 1
        if a["req_n"] >= c["ads_for_request"]:
            a["req_n"] = 0
            a["req_unlocks"] += 1
            s["ad_requests"] = int(s.get("ad_requests") or 0) + 1
            s["unlocks_request"] = int(s.get("unlocks_request") or 0) + 1
            unlocked = "request"
    s["ads"] = a
    return s, unlocked


# ---------------------------------------------------------------- 40 % table
def net_share(c):
    """Play: VAT is inside the price, Play's fee comes off the rest."""
    return (1.0 - c["play_fee"]) / (1.0 + c["vat"])


def invoice_share(c):
    """School invoice (outside Play): VAT inside, a small collection fee."""
    return (1.0 - c["invoice_fee"]) / (1.0 + c["vat"])


def paid_call_bdt(c):
    return c["paid_map_call_usd"] * c["usd_bdt"]


def _row(name, price, share, cost, **kw):
    net = price * share
    profit = net - cost
    r = {"plan": name, "price": price, "net": round(net, 2), "cost": round(cost, 2),
         "profit": round(profit, 2),
         "pct": round(100.0 * profit / price, 1) if price else 0.0}
    r.update(kw)
    return r


def plan_costs(c):
    """Worst case per month: every included credit used as the most
    expensive action, every capped paid map call used, every SMS fallback."""
    call = paid_call_bdt(c)
    req = c["request_server_bdt"]
    child = (c["child_requests"] * req + c["paid_maps_child"] * call
             + (c["child_children"] + c["child_guardians"]) * c["member_server_bdt"]
             + c["sms_per_account"] * c["sms_bdt"])
    family = (c["family_credits"] * req + c["paid_maps_family"] * call
              + c["family_members"] * c["member_server_bdt"]
              + c["sms_per_account"] * c["sms_bdt"])
    school = (c["school_requests"] * req + c["paid_maps_school"] * call
              + (1 + c["school_guardians"]) * c["member_server_bdt"]
              + c["sms_per_student"] * c["sms_bdt"])
    return {"child": child, "family": family, "school": school}


def profit_table(cfg=None, target_pct=40.0):
    c = normalize_cfg(cfg)
    costs = plan_costs(c)
    share = net_share(c)
    rows = [_row("child", c["child_price_bdt"], share, costs["child"], channel="play"),
            _row("family", c["family_price_bdt"], share, costs["family"], channel="play"),
            _row("school", c["school_price_bdt"], invoice_share(c), costs["school"],
                 channel="invoice", per="student")]
    for p in c["packs"]:   # pack requests never use paid map calls
        rows.append(_row(p["id"], p["price_bdt"], share,
                         p["requests"] * c["request_server_bdt"], channel="play"))
    # rewarded ads: the ad revenue must cover what the unlock costs us
    ad = c["ad_value_bdt_low"]
    day_cost = ((c["child_children"] + c["child_guardians"]) * c["member_server_bdt"] / 30.0
                + c["day_pass_requests"] * c["request_server_bdt"])
    rows.append(_row("ads_day", round(ad * c["ads_for_day"], 2), 1.0, day_cost, channel="ads"))
    rows.append(_row("ads_request", round(ad * c["ads_for_request"], 2), 1.0,
                     c["request_server_bdt"], channel="ads"))
    low = min(r["pct"] for r in rows)
    fails = [r["plan"] for r in rows if r["pct"] < target_pct]
    return {"rows": rows, "net_share": round(share, 4),
            "invoice_share": round(invoice_share(c), 4),
            "paid_call_bdt": round(paid_call_bdt(c), 3),
            "min_pct": low, "target_pct": target_pct, "ok": not fails, "fails": fails}


def min_price_for_40(c, plan):
    """The smallest whole-taka price that keeps `plan` at >= 40 %."""
    c = normalize_cfg(c)
    cost = plan_costs(c)[plan]
    share = invoice_share(c) if plan == "school" else net_share(c)
    # profit/price >= 0.4  <=>  price*(share-0.4) >= cost
    return int(math.ceil(cost / (share - 0.4))) if share > 0.4 else None
