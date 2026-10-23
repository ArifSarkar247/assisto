"""
sponsor.py — PURE rules for Assisto's own monetization (p2-money).

No Django, no DB, no network, no clock: callers pass plain dicts + `now`.

Owner order (P2):
  * Free plan only. Never on safety/SOS, payment, login, call screens, and
    never when the app was opened from a notification / deep link (that tap
    may be an SOS, a call or a payment).
  * App-open: from day N after sign-up (default 2), at most `appopen_daily_cap`
    a day (default 3) with a minimum gap, skippable after 5 s.
  * Direct sponsors FIRST (our own server-served creatives); AdMob only fills
    a slot that has no live direct campaign, and only once AdMob is linked.
  * Brand offers by interest: max `offer_notif_daily_cap` offer notifications
    a day (default 2), mute any brand, all offer notifications off, Premium
    never (unless the owner flips `offers_premium_notifs`).
  * Nothing is unlimited; every count is capped.
"""
from datetime import date, datetime, timedelta

PLACEMENTS = ("app_open", "hero", "discover", "community_post", "brand_offer")

# Interest categories a user can follow (Settings -> Offers & brands) and a
# campaign can target. Labels live in the app ARB (offerCat_<id>).
CATEGORIES = ("mobile", "electronics", "fashion", "grocery", "food", "health",
              "beauty", "education", "travel", "home", "kids", "auto",
              "telecom", "banking")

# Bangladesh's 8 divisions (optional location targeting).
DIVISIONS = ("dhaka", "chattogram", "rajshahi", "khulna", "barishal",
             "sylhet", "rangpur", "mymensingh")

# Screens where an ad must never appear (mirrors core.logic.ads.BLOCKED_SCREENS
# and the app's AdRules.blockedTokens). Substring match, default-deny.
SENSITIVE_TOKENS = ("sos", "safety", "emergency", "fall_detect", "journey",
                    "lost", "security", "pay", "topup", "top_up", "checkout",
                    "billing", "plans", "login", "otp", "signup", "register",
                    "password", "call")

# App entry sources after which an app-open ad is NEVER shown (the user came
# for something specific — maybe an SOS, a call or a payment).
BLOCKED_ENTRIES = ("notification", "deeplink", "call", "sos", "share",
                   "widget", "assist")

# The content-safety checklist the owner must tick before approving.
CHECKLIST = ("no_scam", "no_gambling", "no_adult", "no_fake_claims",
             "landing_page_checked", "sponsor_verified")

# Counted impressions per user per campaign per day (anti-inflation; a CPM
# sponsor is only billed for these).
MAX_COUNTED_IMPS_PER_USER_DAY = 3

# Exposure buckets for the retention-impact report (ad impressions a user saw
# in their first 7 days).
EXPOSURE_BUCKETS = (("none", 0, 0), ("light", 1, 6), ("medium", 7, 20),
                    ("heavy", 21, 10 ** 9))
SMALL_SAMPLE = 30


def is_sensitive_screen(screen):
    s = (screen or "").strip().lower()
    if not s or s == "unknown":
        return True
    return any(t in s for t in SENSITIVE_TOKENS)


# ------------------------------------------------------------------ app open
def signup_day_number(date_joined_local, today_local):
    """1 on the sign-up (local) day, 2 the next day, ..."""
    if date_joined_local is None:
        return 1
    return (today_local - date_joined_local).days + 1


def appopen_decision(*, paid, flag_on, caps, date_joined_local, today_local,
                     shown_today, last_shown_at, now, screen="home", entry="",
                     logged_in=True):
    """(allowed, reason) for ONE app-open ad (direct or AdMob). Pure.

    caps = normalized ad_rewards dict. shown_today = app-open ads this user
    really saw today (server count). last_shown_at = aware datetime or None."""
    if not logged_in:
        return False, "logged_out"
    if paid:
        return False, "paid_plan"
    if not flag_on:
        return False, "disabled"
    if (entry or "").strip().lower() in BLOCKED_ENTRIES:
        return False, "blocked_entry"
    if is_sensitive_screen(screen) or (screen or "") != "home":
        return False, "blocked_screen"
    cap = int(caps.get("appopen_daily_cap", 0) or 0)
    if cap <= 0:
        return False, "disabled"
    start_day = max(1, int(caps.get("appopen_start_day", 2) or 1))
    if signup_day_number(date_joined_local, today_local) < start_day:
        return False, "too_new"
    if int(shown_today or 0) >= cap:
        return False, "daily_cap"
    gap = int(caps.get("appopen_min_gap_sec", 3 * 3600) or 0)
    if last_shown_at is not None and (now - last_shown_at).total_seconds() < gap:
        return False, "too_soon"
    return True, "ok"


def skip_after_s(caps):
    """Seconds before the Skip button works (owner: 5 s; bounded 5..15)."""
    try:
        v = int(caps.get("appopen_skip_after_s", 5))
    except (TypeError, ValueError):
        v = 5
    return max(5, min(15, v))


# --------------------------------------------------------------- campaigns
def _in_window(c, now):
    s, e = c.get("start_at"), c.get("end_at")
    if s is not None and now < s:
        return False
    if e is not None and now >= e:
        return False
    return True


def campaign_live(c, now):
    """Approved, sponsor active, inside its window, budget not used up."""
    if c.get("status") != "approved" or not c.get("sponsor_active", True):
        return False
    if not _in_window(c, now):
        return False
    if c.get("pricing") == "cpm":
        cap = cpm_impression_cap(c.get("price_bdt"), c.get("budget_bdt"))
        if cap is not None and int(c.get("total_impressions") or 0) >= cap:
            return False
    return True


def cpm_impression_cap(cpm_bdt, budget_bdt):
    """Impressions a CPM budget buys (None when no budget set = no cap from
    budget; the owner's daily cap still applies)."""
    try:
        cpm, budget = float(cpm_bdt or 0), float(budget_bdt or 0)
    except (TypeError, ValueError):
        return None
    if cpm <= 0 or budget <= 0:
        return None
    return int(budget / cpm * 1000)


def audience_ok(c, user):
    """Free users only, always. Optional interest + division targeting.

    user = {paid, categories:[...], division, muted_brands:[...],
            hidden_campaigns:[...]}."""
    if user.get("paid"):
        return False
    if c.get("sponsor_id") in set(user.get("muted_brands") or ()):
        return False
    if c.get("id") in set(user.get("hidden_campaigns") or ()):
        return False
    divs = [d for d in (c.get("divisions") or []) if d]
    if divs and (user.get("division") or "") not in divs:
        return False
    return True


def interest_match(c, user):
    cats = set(c.get("categories") or ())
    if not cats:
        return False
    return bool(cats & set(user.get("categories") or ())) or (
        c.get("sponsor_id") in set(user.get("brands") or ()))


def pacing_ok(c, served_today, now=None):
    """Daily impression cap and even pacing of a CPM budget over the run."""
    served_today = int(served_today or 0)
    cap = int(c.get("daily_imp_cap") or 0)
    if cap and served_today >= cap:
        return False
    if c.get("pricing") == "cpm" and now is not None:
        total_cap = cpm_impression_cap(c.get("price_bdt"), c.get("budget_bdt"))
        e = c.get("end_at")
        if total_cap is not None and e is not None:
            remaining = max(0, total_cap - int(c.get("total_impressions") or 0))
            days_left = max(1, (e - now).days + 1)
            # even pacing, with 20% headroom so a quiet morning can catch up
            per_day = max(1, int(remaining / days_left * 1.2) + 1)
            if served_today >= per_day:
                return False
    return True


def pick_campaign(campaigns, placement, user, now, served_today_by_id=None):
    """The ONE direct campaign to serve in `placement` for `user`, or None.
    Order: interest match first, then priority (high first), then the least
    served today (spreads impressions between sponsors), then id."""
    served = served_today_by_id or {}
    pool = []
    for c in campaigns or []:
        if c.get("placement") != placement:
            continue
        if not campaign_live(c, now) or not audience_ok(c, user):
            continue
        if not pacing_ok(c, served.get(c.get("id"), 0), now):
            continue
        pool.append(c)
    if not pool:
        return None
    pool.sort(key=lambda c: (0 if interest_match(c, user) else 1,
                             -int(c.get("priority") or 0),
                             int(served.get(c.get("id"), 0)),
                             int(c.get("id") or 0)))
    return pool[0]


def slot_source(direct, admob_ready):
    """Direct sponsor first; AdMob fills an EMPTY slot only when linked."""
    if direct is not None:
        return "direct"
    if admob_ready:
        return "admob"
    return "none"


def why_lines(c, user, lang="bn"):
    """Honest "why am I seeing this" reasons (no tracking beyond this)."""
    bn = lang == "bn"
    out = [("আপনি ফ্রি প্ল্যানে আছেন — প্রিমিয়ামে কোনো বিজ্ঞাপন নেই।" if bn else
            "You are on the Free plan — Premium has no ads.")]
    if interest_match(c, user):
        out.append("আপনার বেছে নেওয়া পছন্দের বিভাগ বা ব্র্যান্ডের সাথে মিলেছে।" if bn else
                   "It matches a category or brand you picked.")
    if c.get("divisions"):
        out.append("স্পনসর আপনার বিভাগ বেছে নিয়েছেন।" if bn else
                   "The sponsor chose your division.")
    out.append("আমরা আপনার মেসেজ, কন্টাক্ট বা অবস্থান বিজ্ঞাপনদাতাকে দিই না।" if bn else
               "We never share your messages, contacts or location with sponsors.")
    return out


# ----------------------------------------------------------- community post
def community_post_ok(*, paid, enabled, member_count, threshold, shown_today,
                      daily_cap, is_admin=False):
    """(allowed, reason) for a Sponsored post at the end of a community /
    channel. The admins of that community/channel never see it in their own."""
    if paid:
        return False, "paid_plan"
    if not enabled:
        return False, "disabled"
    if is_admin:
        return False, "own_space"
    if int(member_count or 0) < int(threshold or 0):
        return False, "too_small"
    if int(daily_cap or 0) <= 0 or int(shown_today or 0) >= int(daily_cap):
        return False, "daily_cap"
    return True, "ok"


# --------------------------------------------------------------- offers
def offer_notif_ok(*, paid, premium_allowed, offers_enabled, notifs_on,
                   sent_today, daily_cap, muted, already_sent):
    """(allowed, reason) for ONE offer notification to one user."""
    if not offers_enabled:
        return False, "disabled"
    if paid and not premium_allowed:
        return False, "paid_plan"
    if not notifs_on:
        return False, "notifs_off"
    if muted:
        return False, "muted"
    if already_sent:
        return False, "already_sent"
    if int(daily_cap or 0) <= 0 or int(sent_today or 0) >= int(daily_cap):
        return False, "daily_cap"
    return True, "ok"


def clean_categories(values):
    out = []
    for v in values or []:
        v = str(v or "").strip().lower()
        if v in CATEGORIES and v not in out:
            out.append(v)
    return out


def clean_divisions(values):
    out = []
    for v in values or []:
        v = str(v or "").strip().lower()
        if v in DIVISIONS and v not in out:
            out.append(v)
    return out


def clean_ids(values, limit=200):
    out = []
    for v in values or []:
        try:
            i = int(v)
        except (TypeError, ValueError):
            continue
        if i > 0 and i not in out:
            out.append(i)
    return out[-limit:]


# --------------------------------------------------------------- approval
def checklist_complete(checklist):
    cl = checklist or {}
    return all(bool(cl.get(k)) for k in CHECKLIST)


def validate_campaign(f):
    """Structural errors {field: reason} for an owner save (pure)."""
    err = {}
    if (f.get("placement") or "") not in PLACEMENTS:
        err["placement"] = "invalid"
    if f.get("pricing") not in ("flat", "cpm"):
        err["pricing"] = "invalid"
    if not (f.get("name") or "").strip():
        err["name"] = "required"
    for k in ("title_bn", "title_en"):
        if not (f.get(k) or "").strip():
            err[k] = "required"
    try:
        if float(f.get("price_bdt") or 0) < 0:
            err["price_bdt"] = "negative"
    except (TypeError, ValueError):
        err["price_bdt"] = "invalid"
    try:
        if float(f.get("budget_bdt") or 0) < 0:
            err["budget_bdt"] = "negative"
    except (TypeError, ValueError):
        err["budget_bdt"] = "invalid"
    s, e = f.get("start_at"), f.get("end_at")
    if s is None or e is None:
        err["end_at"] = "dates_required"
    elif e <= s:
        err["end_at"] = "before_start"
    elif (e - s).days > 366:
        err["end_at"] = "too_long"
    return err


# --------------------------------------------------------------- money math
def _local_days(s, e, tz_localdate):
    d0 = tz_localdate(s)
    d1 = tz_localdate(e - timedelta(microseconds=1))
    return [d0 + timedelta(days=i) for i in range((d1 - d0).days + 1)]


def revenue_by_day(c, impressions_by_day, tz_localdate):
    """{date: ৳} a campaign earned. Flat: the price spread evenly over every
    local day of its run. CPM: counted impressions x CPM / 1000 (never more
    than the budget, when a budget is set)."""
    price = float(c.get("price_bdt") or 0)
    if price <= 0:
        return {}
    if c.get("pricing") == "cpm":
        out, total = {}, 0.0
        budget = float(c.get("budget_bdt") or 0)
        for d in sorted(impressions_by_day or {}):
            v = int(impressions_by_day[d] or 0) * price / 1000.0
            if budget > 0:
                v = max(0.0, min(v, budget - total))
            total += v
            if v > 0:
                out[d] = round(v, 2)
        return out
    s, e = c.get("start_at"), c.get("end_at")
    if s is None or e is None or e <= s:
        return {}
    days = _local_days(s, e, tz_localdate)
    per = price / len(days)
    return {d: round(per, 2) for d in days}


def ctr(impressions, clicks):
    imp = int(impressions or 0)
    return round(100.0 * int(clicks or 0) / imp, 2) if imp > 0 else 0.0


def report_rows(c, stats_by_day, date_from, date_to, tz_localdate):
    """Daily rows {date, impressions, clicks, ctr, hides, revenue} + totals
    for one campaign over [date_from, date_to] (inclusive)."""
    imps = {d: int((v or {}).get("impressions") or 0)
            for d, v in (stats_by_day or {}).items()}
    rev = revenue_by_day(c, imps, tz_localdate)
    rows = []
    d = date_from
    tot = {"impressions": 0, "clicks": 0, "hides": 0, "revenue": 0.0}
    while d <= date_to:
        v = (stats_by_day or {}).get(d) or {}
        r = {"date": d.isoformat(), "impressions": int(v.get("impressions") or 0),
             "clicks": int(v.get("clicks") or 0), "hides": int(v.get("hides") or 0),
             "revenue": round(float(rev.get(d, 0.0)), 2)}
        r["ctr"] = ctr(r["impressions"], r["clicks"])
        for k in ("impressions", "clicks", "hides"):
            tot[k] += r[k]
        tot["revenue"] += r["revenue"]
        rows.append(r)
        d += timedelta(days=1)
    tot["revenue"] = round(tot["revenue"], 2)
    tot["ctr"] = ctr(tot["impressions"], tot["clicks"])
    return {"rows": rows, "totals": tot}


def admob_estimate_bdt(impressions, ecpm_bdt, revenue_share):
    """AdMob ESTIMATE (owner formula): eCPM x impressions / 1000 x share.
    Labelled an estimate everywhere — AdMob's own report is the truth."""
    try:
        return round(int(impressions or 0) * float(ecpm_bdt or 0) / 1000.0
                     * float(revenue_share or 0), 2)
    except (TypeError, ValueError):
        return 0.0


def placement_pnl(direct_by_place_day, admob_imps_by_place_day, ecpm_bdt,
                  revenue_share):
    """{placement: {direct, admob_est, total, admob_impressions}} summed over
    the window + per-day rows [{date, placement, direct, admob_est}]."""
    places = sorted(set(PLACEMENTS) | {"rewarded", "interstitial"})
    summary = {p: {"direct": 0.0, "admob_est": 0.0, "admob_impressions": 0,
                   "total": 0.0} for p in places}
    days = {}
    for (p, d), v in (direct_by_place_day or {}).items():
        summary.setdefault(p, {"direct": 0.0, "admob_est": 0.0,
                               "admob_impressions": 0, "total": 0.0})
        summary[p]["direct"] += float(v or 0)
        days.setdefault((d, p), [0.0, 0.0])[0] += float(v or 0)
    for (p, d), n in (admob_imps_by_place_day or {}).items():
        summary.setdefault(p, {"direct": 0.0, "admob_est": 0.0,
                               "admob_impressions": 0, "total": 0.0})
        est = admob_estimate_bdt(n, ecpm_bdt, revenue_share)
        summary[p]["admob_est"] += est
        summary[p]["admob_impressions"] += int(n or 0)
        days.setdefault((d, p), [0.0, 0.0])[1] += est
    for p, v in summary.items():
        v["direct"] = round(v["direct"], 2)
        v["admob_est"] = round(v["admob_est"], 2)
        v["total"] = round(v["direct"] + v["admob_est"], 2)
    rows = [{"date": d.isoformat() if isinstance(d, (date, datetime)) else str(d),
             "placement": p, "direct": round(a, 2), "admob_est": round(b, 2),
             "total": round(a + b, 2)}
            for (d, p), (a, b) in sorted(days.items(), reverse=True)]
    return {"summary": summary, "rows": rows}


# ----------------------------------------------------------- retention
def bucket_of(n):
    n = int(n or 0)
    for name, lo, hi in EXPOSURE_BUCKETS:
        if lo <= n <= hi:
            return name
    return "heavy"


def retention_by_bucket(users, today):
    """Compare D1 / D7 retention and an uninstall PROXY between ad-exposure
    buckets. users = [{joined: date, last_active: date|None, ads_first7: int}].

    D1 = came back on/after day 1; D7 = active on/after day 7 (only users who
    joined >= 7 days ago count for D7). Uninstall proxy = no activity for 14+
    days (we cannot see real uninstalls). Each bucket carries n and a
    small-sample flag (n < SMALL_SAMPLE) — the owner must not over-read it."""
    out = {name: {"n": 0, "d1_n": 0, "d1": 0, "d7_n": 0, "d7": 0,
                  "stopped_n": 0, "stopped": 0}
           for name, _, _ in EXPOSURE_BUCKETS}
    for u in users or []:
        j = u.get("joined")
        if j is None:
            continue
        b = out[bucket_of(u.get("ads_first7"))]
        la = u.get("last_active")
        age = (today - j).days
        b["n"] += 1
        if age >= 1:
            b["d1_n"] += 1
            if la is not None and (la - j).days >= 1:
                b["d1"] += 1
        if age >= 7:
            b["d7_n"] += 1
            if la is not None and (la - j).days >= 7:
                b["d7"] += 1
        if age >= 14:
            b["stopped_n"] += 1
            if la is None or (today - la).days >= 14:
                b["stopped"] += 1
    for b in out.values():
        b["d1_pct"] = round(100.0 * b["d1"] / b["d1_n"], 1) if b["d1_n"] else None
        b["d7_pct"] = round(100.0 * b["d7"] / b["d7_n"], 1) if b["d7_n"] else None
        b["stopped_pct"] = (round(100.0 * b["stopped"] / b["stopped_n"], 1)
                            if b["stopped_n"] else None)
        b["small_sample"] = b["n"] < SMALL_SAMPLE
    return out
