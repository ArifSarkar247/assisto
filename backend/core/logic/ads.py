"""
ads.py — PURE helpers for the AdMob client config (slot a6).

No Django, no DB, no network. The view (core/views_ads.py) reads the owner's
AdMob integration + kill-switch flags + PricingConfig ad caps and passes them
in; this module validates the IDs and shapes what the app receives.

Rules the app enforces (mirrored in app/lib/ads/ad_rules.dart, unit-tested
there):
  * Free plan only — Premium/Business/annual/founder/probashi see NO ads, except
    a rewarded ad the user explicitly opts into for credits.
  * Never on safety/SOS, payment/top-up/checkout, login/OTP or call screens.
  * App-open at most once per `appopen_min_gap_sec` (default 3 h).
  * Until the owner saves REAL ids, the app only ever uses Google's official
    TEST ids, and real-money crediting stays off (billing.ad_event refuses).
"""
import re

# Google's official, public sample IDs (https://developers.google.com/admob/android/test-ads)
TEST_APP_ID = "ca-app-pub-3940256099942544~3347511713"
TEST_UNITS = {
    "app_open": "ca-app-pub-3940256099942544/9257395921",
    "rewarded": "ca-app-pub-3940256099942544/5224354917",
    "banner": "ca-app-pub-3940256099942544/6300978111",
}
TEST_PUBLISHER = "ca-app-pub-3940256099942544"

_APP_RE = re.compile(r"^ca-app-pub-\d{16}~\d{6,12}$")
_UNIT_RE = re.compile(r"^ca-app-pub-\d{16}/\d{6,12}$")

# integration field -> client unit key
UNIT_FIELDS = {"app_open_unit": "app_open", "rewarded_unit": "rewarded",
               "banner_unit": "banner"}

# Screens where an ad must NEVER appear (server copy; the app has the same
# hard list and treats any unknown screen as blocked).
BLOCKED_SCREENS = (
    "sos", "safety", "emergency", "voice_sos", "fall_detect", "journey",
    "lost_stolen", "my_lost_phone", "security",
    "payment", "topup", "checkout", "plans", "payment_ladder",
    "login", "otp", "signup", "reset_password",
    "call", "circle_call", "incoming_call",
)


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


def client_config(*, plan, paid, admob_cfg, admob_working, flag_rewarded,
                  flag_app_open, ad_caps):
    """The /ads/config payload. `configured` is True only for owner-saved REAL
    ids that pass validation; otherwise the app falls back to TEST ids and the
    server never credits real money."""
    admob_cfg = admob_cfg or {}
    ok, _ = validate_admob_ids(admob_cfg)
    configured = bool(admob_working and ok)
    units = {k: "" for k in UNIT_FIELDS.values()}
    if configured:
        for field, key in UNIT_FIELDS.items():
            units[key] = _s(admob_cfg.get(field))
    caps = ad_caps or {}
    gap = int(caps.get("appopen_min_gap_sec", 3 * 3600) or 0)
    return {
        "configured": configured,
        "app_id": _s(admob_cfg.get("app_id")) if configured else "",
        "units": units,
        "test_app_id": TEST_APP_ID,
        "test_units": dict(TEST_UNITS),
        "plan": plan,
        "paid": bool(paid),
        "rewarded_enabled": bool(flag_rewarded) and int(caps.get("rewarded_daily_cap", 0) or 0) > 0,
        "app_open_enabled": bool(flag_app_open) and not paid
                            and int(caps.get("appopen_daily_cap", 0) or 0) > 0,
        "appopen_min_gap_sec": max(3 * 3600, gap),
        "appopen_daily_cap": int(caps.get("appopen_daily_cap", 0) or 0),
        "rewarded_daily_cap": int(caps.get("rewarded_daily_cap", 0) or 0),
        "blocked_screens": list(BLOCKED_SCREENS),
    }
