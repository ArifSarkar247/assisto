"""
ads.py — PURE helpers for the AdMob client config (slot a6).

No Django, no DB, no network. The view (core/views_ads.py) reads the owner's
AdMob integration + kill-switch flags + PricingConfig ad caps and passes them
in; this module validates the IDs and shapes what the app receives.

Rules the app enforces (mirrored in app/lib/ads/ad_rules.dart and
app/lib/ads/ad_placements.dart, unit-tested there):
  * Free plan only — Premium/Business/annual/founder/probashi/trial see ZERO
    ads (owner 25 Oct: not even an opt-in rewarded ad).
  * Never on SOS, safety, anti-theft, family alerts, calls, chats, chat lock,
    payment, login, onboarding or permission screens — the app uses an
    ALLOWLIST (only listed screens may show an ad; new screens get none).
  * App-open at most once per `appopen_min_gap_sec` (owner 26 Oct: default and
    floor 3 h), max 6/day.
  * The app ships with Google's TEST unit ids. REAL unit ids are sent only
    when the owner turns `admob_real_ids` on (after production launch and
    AdMob app approval). Until then impressions credit nothing and rewarded
    ads are not offered (Google's SSV can only verify real units).
"""
import re

# Google's official, public sample IDs (https://developers.google.com/admob/android/test-ads)
TEST_APP_ID = "ca-app-pub-3940256099942544~3347511713"
TEST_UNITS = {
    "app_open": "ca-app-pub-3940256099942544/9257395921",
    "rewarded": "ca-app-pub-3940256099942544/5224354917",
    "banner": "ca-app-pub-3940256099942544/6300978111",
    "interstitial": "ca-app-pub-3940256099942544/1033173712",
    # h1-home: native advanced (the video sample is .../1044960115)
    "native": "ca-app-pub-3940256099942544/2247696110",
}
TEST_PUBLISHER = "ca-app-pub-3940256099942544"

# admob (owner 25 Oct): Assisto's REAL AdMob app + unit ids. The app id is in
# the APK manifest (required by the SDK and by app-ads.txt); the unit ids are
# served by /ads/config only when `admob_real_ids` is on. A valid set saved in
# Owner Admin -> Integrations -> AdMob overrides these.
OWNER_PUBLISHER = "pub-2506398550427515"
OWNER_APP_ID = "ca-app-pub-2506398550427515~5116255919"
OWNER_UNITS = {
    "app_open": "ca-app-pub-2506398550427515/1193237050",
    "rewarded": "ca-app-pub-2506398550427515/2426427676",
    "banner": "ca-app-pub-2506398550427515/4940910375",
    "interstitial": "ca-app-pub-2506398550427515/3547937658",
    "native": "ca-app-pub-2506398550427515/7259951959",
}

_APP_RE = re.compile(r"^ca-app-pub-\d{16}~\d{6,12}$")
_UNIT_RE = re.compile(r"^ca-app-pub-\d{16}/\d{6,12}$")

# integration field -> client unit key
UNIT_FIELDS = {"app_open_unit": "app_open", "rewarded_unit": "rewarded",
               "banner_unit": "banner", "interstitial_unit": "interstitial",
               "native_unit": "native"}

# Screens where an ad must NEVER appear (server copy; the app has the same
# hard list and treats any unknown screen as blocked).
BLOCKED_SCREENS = (
    "sos", "safety", "emergency", "voice_sos", "fall_detect", "journey",
    "lost_stolen", "my_lost_phone", "security",
    "payment", "topup", "checkout", "plans", "payment_ladder",
    "login", "otp", "signup", "reset_password",
    "call", "circle_call", "incoming_call",
    # admob (owner 25 Oct)
    "antitheft", "anti_theft", "family_alert", "alerts", "chat", "chat_lock",
    "vault", "onboarding", "permission", "language_picker",
    # budget-remittance: family money screens
    "remittance", "budget_remittance",
)

# admob: the only screens an ad may appear on (the app has the same
# allowlist in ad_placements.dart; it can only narrow it from the server's
# banner_screens / interstitial_moments).
NATIVE_SCREENS = ("home",)
APP_OPEN_SCREENS = ("home",)
REWARDED_SCREENS = ("credits", "photo_studio")
# same tuples as core/logic/pricing.py (the owner can only narrow them)
BANNER_SCREENS = ("saved_items", "dictionary", "health_tips")
INTERSTITIAL_MOMENTS = ("photo_saved", "task_done")


def _s(v):
    return str(v or "").strip()


def is_test_id(v):
    return _s(v).startswith(TEST_PUBLISHER)


def validate_admob_ids(cfg):
    """(ok, detail). App ID + at least one unit must be well-formed REAL ids
    from the same publisher. Test ids are refused (they'd earn nothing)."""
    cfg = cfg or {}
    app_id = _s(cfg.get("app_id"))
    if not _APP_RE.match(app_id):
        return False, "App ID must look like ca-app-pub-XXXXXXXXXXXXXXXX~NNNNNNNNNN"
    if is_test_id(app_id):
        return False, "That is Google's TEST App ID — paste your real one"
    pub = app_id.split("~", 1)[0]
    units = 0
    for field in UNIT_FIELDS:
        v = _s(cfg.get(field))
        if not v:
            continue
        if not _UNIT_RE.match(v):
            return False, "%s must look like ca-app-pub-XXXXXXXXXXXXXXXX/NNNNNNNNNN" % field
        if is_test_id(v):
            return False, "%s is a Google TEST unit — paste your real one" % field
        if v.split("/", 1)[0] != pub:
            return False, "%s is from a different AdMob account than the App ID" % field
        units += 1
    if not units:
        return False, "Add at least one ad unit ID (rewarded or app-open)"
    return True, "IDs look valid — verified on first ad load"


# p2-money: app entry sources after which no app-open ad is ever shown.
BLOCKED_ENTRIES = ("notification", "deeplink", "call", "sos", "share",
                   "widget", "assist")

# h1-home: AdMob asks for >= 60 s between refreshes of one native slot.
HERO_MIN_REFRESH_SEC = 60


def hero_refresh_sec(value):
    """The home hero native-ad refresh, never faster than AdMob allows."""
    try:
        v = int(value)
    except (TypeError, ValueError):
        v = 90
    return max(HERO_MIN_REFRESH_SEC, min(3600, v))


_DEVICE_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


def ump_test_devices(value):
    """Comma/space separated UMP hashed test-device ids -> clean list (max 20)."""
    out = []
    for part in re.split(r"[\s,;]+", _s(value)):
        if _DEVICE_RE.match(part) and part not in out:
            out.append(part)
    return out[:20]


def _csv(value, allowed):
    out = []
    parts = value if isinstance(value, (list, tuple)) else _s(value).split(",")
    for p in parts:
        p = _s(p).lower()
        if p in allowed and p not in out:
            out.append(p)
    return out


def serving_units(caps, admob_cfg=None, admob_working=False):
    """(real, app_id, units) — what the app may load right now.

    real=False (default until the owner turns `admob_real_ids` on): Google's
    public TEST units (any app id may load them). real=True: the owner's
    saved Integrations ids when they validate, else Assisto's OWNER ids."""
    caps = caps or {}
    if not caps.get("admob_real_ids", False):
        return False, "", dict(TEST_UNITS)
    admob_cfg = admob_cfg or {}
    ok, _ = validate_admob_ids(admob_cfg)
    if admob_working and ok:
        units = dict(OWNER_UNITS)
        for field, key in UNIT_FIELDS.items():
            v = _s(admob_cfg.get(field))
            if v:
                units[key] = v
        return True, _s(admob_cfg.get("app_id")), units
    return True, OWNER_APP_ID, dict(OWNER_UNITS)


def client_config(*, plan, paid, admob_cfg, admob_working, flag_rewarded,
                  flag_app_open, ad_caps, hero_refresh=90):
    """The /ads/config payload.

    `configured` (= `real_ids`) is True only after the owner turned
    `admob_real_ids` on; until then `units` ARE Google's test units and the
    server credits nothing for an impression. Premium/Business: ads_enabled
    false and every placement off (zero ads)."""
    admob_cfg = admob_cfg or {}
    caps = ad_caps or {}
    paid = bool(paid)
    real, app_id, units = serving_units(caps, admob_cfg, admob_working)
    gap = int(caps.get("appopen_min_gap_sec", 10800) or 0)
    i_gap = int(caps.get("interstitial_min_gap_sec", 300) or 0)

    def on(key):
        return bool(caps.get(key, True)) and not paid

    app_open_cap = int(caps.get("appopen_daily_cap", 0) or 0)
    inter_cap = int(caps.get("interstitial_daily_cap", 0) or 0)
    rew_cap = int(caps.get("rewarded_daily_cap", 0) or 0)
    hero = bool(caps.get("hero_enabled", False)) and not paid
    banner_screens = _csv(caps.get("banner_screens", ",".join(BANNER_SCREENS)),
                          BANNER_SCREENS)
    moments = _csv(caps.get("interstitial_moments", ",".join(INTERSTITIAL_MOMENTS)),
                   INTERSTITIAL_MOMENTS)
    placements = {
        "app_open": bool(flag_app_open) and on("place_app_open") and app_open_cap > 0,
        "native_home": hero,
        "banner": on("place_banner") and bool(banner_screens),
        "interstitial": on("place_interstitial") and inter_cap > 0 and bool(moments),
        # Google's SSV can only verify REAL rewarded units: never offered on
        # test ids (a test ad could never unlock anything — no showpiece).
        "rewarded": bool(flag_rewarded) and on("place_rewarded") and rew_cap > 0 and real,
    }
    return {
        "configured": real,
        "real_ids": real,
        "ads_enabled": not paid,
        "app_id": app_id,
        "units": units,
        "test_app_id": TEST_APP_ID,
        "test_units": dict(TEST_UNITS),
        "plan": plan,
        "paid": paid,
        # personalised ads only when the owner allows it AND UMP consent does
        "personalized": bool(caps.get("admob_personalized", False)) and not paid,
        "placements": placements,
        "rewarded_enabled": placements["rewarded"],
        "app_open_enabled": placements["app_open"],
        "appopen_min_gap_sec": max(10800, gap),
        "appopen_daily_cap": app_open_cap,
        "appopen_min_bg_sec": max(5, min(3600, int(caps.get("appopen_min_bg_sec", 30) or 30))),
        "rewarded_daily_cap": rew_cap,
        "interstitial_min_gap_sec": max(300, i_gap),
        "interstitial_daily_cap": inter_cap,
        "banner_screens": banner_screens if placements["banner"] else [],
        "interstitial_moments": moments if placements["interstitial"] else [],
        "native_screens": list(NATIVE_SCREENS) if hero else [],
        "blocked_screens": list(BLOCKED_SCREENS),
        # o2-admin: hero ad slot (Free only); start muted unless owner says not
        "hero_enabled": hero,
        "hero_start_muted": bool(caps.get("hero_start_muted", True)),
        # h1-home: home hero native-ad refresh (admin: pricing home_hero)
        "hero_refresh_sec": hero_refresh_sec(hero_refresh),
        # l3-ump: Google UMP debug knobs (Owner Admin -> Ads).
        "consent_debug_eea": bool(caps.get("consent_debug_eea", False)),
        "consent_test_devices": ump_test_devices(admob_cfg.get("ump_test_devices"))
                                if caps.get("consent_debug_eea") else [],
        # p2-money: app-open rules (server re-checks every one in /ads/slot)
        "appopen_start_day": max(1, int(caps.get("appopen_start_day", 2) or 1)),
        "appopen_skip_after_s": max(5, min(15, int(caps.get("appopen_skip_after_s", 5) or 5))),
        "sponsors_enabled": bool(caps.get("sponsors_enabled", True)) and not paid,
        "community_sponsored_enabled": bool(caps.get("community_sponsored_enabled", True))
                                       and not paid,
        "community_sponsored_min_members": int(caps.get("community_sponsored_min_members", 500)
                                               or 500),
        "offers_enabled": bool(caps.get("offers_enabled", True)),
        "offer_notif_daily_cap": int(caps.get("offer_notif_daily_cap", 2) or 0),
        "blocked_entries": list(BLOCKED_ENTRIES),
    }


# ------------------------------------------------------------ event logging
# POST /ads/event {placement, format, kind: impression|click|paid, ...}
EVENT_KINDS = ("impression", "click", "paid")
FORMATS = ("app_open", "native", "banner", "interstitial", "rewarded")
_PLACEMENT_RE = re.compile(r"^[a-z][a-z0-9_]{1,39}$")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")
PRECISIONS = ("unknown", "estimated", "publisher_provided", "precise")
# one paid event is ONE impression's value; above this it is not believable
MAX_PAID_MICROS = 50 * 1000000


def clean_event(d):
    """Validate one client ad event. (event_dict, None) or (None, reason)."""
    d = d if isinstance(d, dict) else {}
    kind = _s(d.get("kind")).lower()
    if kind not in EVENT_KINDS:
        return None, "bad_kind"
    fmt = _s(d.get("format")).lower()
    if fmt not in FORMATS:
        return None, "bad_format"
    placement = _s(d.get("placement")).lower()
    if not _PLACEMENT_RE.match(placement):
        return None, "bad_placement"
    out = {"kind": kind, "format": fmt, "placement": placement,
           "value_micros": 0, "currency": "", "precision": ""}
    if kind == "paid":
        try:
            v = int(d.get("value_micros"))
        except (TypeError, ValueError):
            return None, "bad_value"
        if v < 0 or v > MAX_PAID_MICROS:
            return None, "bad_value"
        cur = _s(d.get("currency")).upper()
        if not _CURRENCY_RE.match(cur):
            return None, "bad_currency"
        prec = _s(d.get("precision")).lower()
        out.update(value_micros=v, currency=cur,
                   precision=prec if prec in PRECISIONS else "unknown")
    return out, None


def placement_report(rows):
    """rows: [{placement, format, impressions, clicks, paid_events,
    revenue_micros, currency}] -> per-placement totals, highest revenue first.
    Revenue stays per currency (AdMob reports in the account currency)."""
    by = {}
    for r in rows or []:
        key = (r.get("placement") or "", r.get("format") or "")
        a = by.setdefault(key, {"placement": key[0], "format": key[1],
                                "impressions": 0, "clicks": 0, "paid_events": 0,
                                "revenue": {}})
        a["impressions"] += int(r.get("impressions") or 0)
        a["clicks"] += int(r.get("clicks") or 0)
        a["paid_events"] += int(r.get("paid_events") or 0)
        cur = r.get("currency") or ""
        if cur:
            a["revenue"][cur] = a["revenue"].get(cur, 0) + int(r.get("revenue_micros") or 0)
    out = []
    for a in by.values():
        a["revenue_text"] = ", ".join("%s %.2f" % (c, m / 1e6)
                                      for c, m in sorted(a["revenue"].items())) or "—"
        a["ctr_pct"] = (round(100.0 * a["clicks"] / a["impressions"], 2)
                        if a["impressions"] else 0.0)
        out.append(a)
    out.sort(key=lambda a: (-sum(a["revenue"].values()), -a["impressions"], a["placement"]))
    return out


