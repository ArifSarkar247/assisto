"""
cctv_video_addon.py — PURE rules for the CCTV video add-on and evidence
retention (owner CCTV order 3 Nov, part D; package W7). No DB, no network.

  * base plan: person-alert PHOTOS kept 7 days in the cloud (cctv_store);
  * video add-on, PER CAMERA, per month:
        "7d"  -> 10-s SD-card clip per person alert kept 7 days   = 100 tk
        "30d" -> the same kept 30 days (photos too)               = 150 tk
    max 30 clips per camera per day; NO 24/7 cloud recording ever (24/7
    stays on the camera's SD card).

PLAY SEAM: the pricing package (W8) wires Play Billing; it only has to call
core.cctv_evidence.grant_addon(camera, tier, months, source="play", ref=<token>)
for the product ids in PLAY_PRODUCTS. Until then the add-on is bought with
Assisto credits through the existing credits engine (core/credits.spend).

40 % RULE: worst_case_month() prices a camera that fires the full 30 clips
every day, at the clip-size cap, against the vendor's over-plan traffic price
and object-storage price; profit_ok() must hold after the Play fee and VAT
(core.tests_cctvevidence proves it for both tiers).
"""
import math

TIERS = {
    "7d": {"days": 7, "price_tk": 100},
    "30d": {"days": 30, "price_tk": 150},
}
BASE_PHOTO_DAYS = 7
CLIP_SECONDS = 10
CLIP_BEFORE_S = 4                 # 4 s before the alert, 6 s after
MAX_CLIPS_PER_CAMERA_DAY = 30
MAX_CLIP_BYTES = 900 * 1024       # SD (sub-stream) quality; the 40 % rule needs it
PERIOD_DAYS = 30                  # one paid month
PERSON_TYPES = ("person_detected", "zone_intrusion", "line_crossing")

# Play Billing product ids — the pricing package creates these in Play
# Console (owner) and calls grant_addon(); nothing here talks to Play.
PLAY_PRODUCTS = {"7d": "cctv_video_7d", "30d": "cctv_video_30d"}

# ---- cost inputs (worst case, editable here with a test) ----
USD_BDT = 122.0
PLAY_FEE = 0.15                   # Google Play service fee (subscriptions)
VAT = 0.15                        # Bangladesh VAT on the consumer price
VENDOR_TRAFFIC_USD_GB = 0.40      # EZVIZ traffic over the plan (CCTV order G)
STORAGE_USD_GB_MONTH = 0.015      # Cloudflare R2 standard (egress free)
OPS_USD_PER_MILLION = 4.50        # R2 class A ops (PUT) — worst case
SERVER_EGRESS_USD_GB = 0.0        # served from our own box (included traffic)


def tier_ok(tier):
    return tier in TIERS


def clip_days(tier):
    """How long a clip is kept for this tier (0 = no add-on, no clips)."""
    return TIERS[tier]["days"] if tier in TIERS else 0


def photo_days(site_days, tier=None):
    """Effective photo retention: the owner's own setting, capped at the base
    7 days — or 30 with the 30-day add-on. 0 = keep no photos at all."""
    try:
        site_days = int(site_days)
    except (TypeError, ValueError):
        site_days = BASE_PHOTO_DAYS
    cap = 30 if tier == "30d" else BASE_PHOTO_DAYS
    return max(0, min(site_days, cap))


def credits_for(tier, credit_bdt, months=1):
    """Credits for `months` of the add-on at the credit's taka value."""
    if tier not in TIERS:
        return 0
    try:
        cb = float(credit_bdt)
    except (TypeError, ValueError):
        cb = 1.0
    cb = cb if cb > 0 else 1.0
    return int(math.ceil(TIERS[tier]["price_tk"] * max(1, int(months)) / cb))


def is_person_alert(etype, signals=None):
    """A person alert = a person / zone / line event, or the camera's own
    alarm when the vendor said it was a human."""
    if etype in PERSON_TYPES:
        return True
    if etype == "camera_alarm":
        inputs = (signals or {}).get("inputs") or {}
        return bool(inputs.get("human") or (signals or {}).get("human"))
    return False


def clip_window(alert_ts):
    """(start_ts, end_ts) of the 10-s clip around the alert."""
    start = float(alert_ts) - CLIP_BEFORE_S
    return start, start + CLIP_SECONDS


def can_add_clip(clips_today):
    return int(clips_today or 0) < MAX_CLIPS_PER_CAMERA_DAY


# ---------------------------------------------------------------- SD health
def sd_days_estimate(total_bytes, bitrate_kbps=1024):
    """How many days of 24/7 recording the card holds at `bitrate_kbps`
    (main stream ~1 Mbps H.265 1080p). None when the size is unknown."""
    try:
        total = float(total_bytes)
    except (TypeError, ValueError):
        return None
    if total <= 0 or bitrate_kbps <= 0:
        return None
    per_day = bitrate_kbps * 1000 / 8.0 * 86400
    return round(total / per_day, 1)


SD_STATES = ("ok", "error", "unformatted", "formatting", "none", "unknown")


# ---------------------------------------------------------------- 40 % rule
def worst_case_month(tier):
    """Worst-case cost (BDT) of ONE camera for one month on this tier."""
    days = clip_days(tier)
    clips = MAX_CLIPS_PER_CAMERA_DAY * PERIOD_DAYS
    gb_month = clips * MAX_CLIP_BYTES / 1e9
    held_gb = MAX_CLIPS_PER_CAMERA_DAY * days * MAX_CLIP_BYTES / 1e9
    # photos for the same alerts (<= 120 KB each, 640 px), held as long
    photo_gb = MAX_CLIPS_PER_CAMERA_DAY * max(days, BASE_PHOTO_DAYS) * 120 * 1024 / 1e9
    usd = (gb_month * VENDOR_TRAFFIC_USD_GB
           + (held_gb + photo_gb) * STORAGE_USD_GB_MONTH
           + clips * 2 / 1e6 * OPS_USD_PER_MILLION
           + gb_month * SERVER_EGRESS_USD_GB)
    return round(usd * USD_BDT, 2)


def net_revenue(tier):
    """What Assisto keeps of the monthly price after VAT and the Play fee."""
    price = TIERS[tier]["price_tk"]
    ex_vat = price / (1 + VAT)
    return round(ex_vat * (1 - PLAY_FEE), 2)


def profit_margin(tier):
    net = net_revenue(tier)
    return round((net - worst_case_month(tier)) / net, 4) if net else 0.0


def profit_ok(tier, floor=0.40):
    return profit_margin(tier) >= floor


def cost_table():
    """Rows for the owner (Bangla STATUS table + the app's info sheet)."""
    return [{"tier": t, "price_tk": TIERS[t]["price_tk"], "days": TIERS[t]["days"],
             "net_tk": net_revenue(t), "worst_cost_tk": worst_case_month(t),
             "margin": profit_margin(t)} for t in TIERS]
