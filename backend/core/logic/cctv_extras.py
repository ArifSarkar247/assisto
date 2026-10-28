"""
cctv_extras.py — PURE rules for the CCTV extras (owner order 28 Oct, "beat
every CCTV app"). NO Django, NO DB, NO network: plain values in, plain values
out; every rule is pinned by core/tests_cctvx.py.

  1. NO-SALE DRAWER OPEN — a cash-zone touch with no sale (Assisto POS) and
     no khata entry within the owner's window (default 2 min, 1..10, server
     bounds) -> "Drawer opened with no sale — watch the clip and decide".
  2. ACTIONS FROM THE ALERT — which siren route a camera has (only where an
     official / documented API exists), the shop's phone number, 999.
  3. CAMERA / SHOP BOX / INTERNET OFFLINE — 10 min of silence -> one alert,
     one recovery notice (offline_transitions()).
  4. ESCALATION — owner's ordered chain (<= 3 people from their Circle);
     each step waits `escalate_min` (default 2) for someone to open it.
  5. SHOP OPEN / CLOSE — first movement after opening time, late opening.
  6. NIGHTLY GUARD REPORT — lines for the evening brief (0 credits).
  7. PLACEMENT HELPER — deterministic image statistics -> Bangla tips.
  8. EVIDENCE PACK — the GD-ready summary text (the phone builds the pack).
  9. PRIVACY KIT — sticker + staff notice text (truthful; no legal claims).
 10. CAPS + COST — every new alert type is capped per plan tier and the
     worst case fits the 40 % rule on top of the Smart Cash Guard's own
     worst case (core/logic/cash_guard.py).

NEVER ACCUSE: no string here names or blames a person; cash_guard.
FORBIDDEN_WORDS is checked by the tests against every string we emit.
"""
import re

from . import cash_guard as CG

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(v):
    return str(v).translate(_BN)


def _d(v, lang):
    return bn_digits(v) if lang == "bn" else str(v)


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ================================================================ settings
# key: (default, (lo, hi)) for the integers; booleans / lists separately.
INT_SETTINGS = {
    "nosale_min": (2, (1, 10)),        # owner tunes the no-sale window
    "escalate_min": (2, (1, 10)),      # wait before the next person
    "offline_min": (10, (5, 60)),      # silence that counts as offline
    "late_min": (30, (10, 180)),       # "not opened yet" after opening time
}
BOOL_SETTINGS = {"nosale_on": True, "offline_on": True, "late_on": True,
                 "opened_on": True}
MAX_CHAIN = 3
_PHONE_RE = re.compile(r"^\+?[0-9]{3,15}$")


def default_settings():
    out = {k: v[0] for k, v in INT_SETTINGS.items()}
    out.update(BOOL_SETTINGS)
    out.update({"escalation": [], "closed_days": [], "shop_phone": ""})
    return out


def clean_phone(v):
    """A dialable number: digits with an optional leading +, 3..15 digits
    (BD mobiles 01XXXXXXXXX, +8801..., landlines, 999). '' when empty;
    None when malformed."""
    s = re.sub(r"[\s\-().]", "", str(v or ""))
    if not s:
        return ""
    return s if _PHONE_RE.match(s) else None


def settings_of(guard):
    """The effective settings: stored values bounded, defaults elsewhere."""
    g = guard if isinstance(guard, dict) else {}
    out = default_settings()
    for k, (default, (lo, hi)) in INT_SETTINGS.items():
        v = g.get(k, default)
        try:
            if isinstance(v, bool):
                raise TypeError
            v = int(float(v))
        except (TypeError, ValueError):
            v = default
        out[k] = max(lo, min(hi, v))
    for k, default in BOOL_SETTINGS.items():
        v = g.get(k, default)
        out[k] = v if isinstance(v, bool) else default
    chain = g.get("escalation")
    if isinstance(chain, list):
        seen, clean = set(), []
        for u in chain:
            try:
                u = int(u)
            except (TypeError, ValueError):
                continue
            if u > 0 and u not in seen:
                seen.add(u)
                clean.append(u)
        out["escalation"] = clean[:MAX_CHAIN]
    days = g.get("closed_days")
    if isinstance(days, list):
        out["closed_days"] = sorted({int(x) for x in days
                                     if isinstance(x, int) and not isinstance(x, bool)
                                     and 0 <= x <= 6})
    ph = clean_phone(g.get("shop_phone"))
    out["shop_phone"] = ph or ""
    return out


class SettingsError(ValueError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def apply_settings(guard, body, allowed_uids):
    """Merge an owner's PUT body into the stored guard dict. Out-of-range
    numbers are CLAMPED (server-enforced bounds); a malformed phone, an
    escalation person who is not in the owner's Circle, or a too-long chain
    raise SettingsError(code). The server-only `_state` is never touched."""
    g = dict(guard) if isinstance(guard, dict) else {}
    body = body if isinstance(body, dict) else {}
    for k in INT_SETTINGS:
        if k in body:
            g[k] = body[k]
    for k in BOOL_SETTINGS:
        if k in body:
            v = body[k]
            if isinstance(v, str):
                v = v.strip().lower() in ("1", "true", "yes", "on")
            g[k] = bool(v)
    if "escalation" in body:
        raw = body["escalation"]
        if raw in (None, ""):
            raw = []
        if not isinstance(raw, list):
            raise SettingsError("bad_escalation")
        if len(raw) > MAX_CHAIN:
            raise SettingsError("chain_too_long")
        ids = []
        for u in raw:
            try:
                u = int(u)
            except (TypeError, ValueError):
                raise SettingsError("bad_escalation")
            if u not in allowed_uids:
                raise SettingsError("not_in_circle")
            if u not in ids:
                ids.append(u)
        g["escalation"] = ids
    if "closed_days" in body:
        raw = body["closed_days"] or []
        if not isinstance(raw, list) or any(
                not isinstance(x, int) or isinstance(x, bool) or not 0 <= x <= 6
                for x in raw):
            raise SettingsError("bad_days")
        g["closed_days"] = sorted(set(raw))
    if "shop_phone" in body:
        ph = clean_phone(body["shop_phone"])
        if ph is None:
            raise SettingsError("bad_phone")
        g["shop_phone"] = ph
    # store the bounded form (plus the untouched server state)
    clean = settings_of(g)
    if "_state" in g:
        clean["_state"] = g["_state"]
    return clean


# ================================================================ wording
NOSALE_TITLE_BN = "বিক্রি ছাড়া ড্রয়ার খোলা — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন"
NOSALE_TITLE_EN = "Drawer opened with no sale — watch the clip and decide"
NOSALE_TITLE_NO_CLIP_BN = "বিক্রি ছাড়া ড্রয়ার খোলা — ছবি দেখে আপনি সিদ্ধান্ত নিন"
NOSALE_TITLE_NO_CLIP_EN = "Drawer opened with no sale — look at the photo and decide"


def nosale_title(lang, has_clip=True, away=False):
    if lang == "en":
        t = NOSALE_TITLE_EN if has_clip else NOSALE_TITLE_NO_CLIP_EN
        return (CG.AWAY_PREFIX_EN + t) if away else t
    t = NOSALE_TITLE_BN if has_clip else NOSALE_TITLE_NO_CLIP_BN
    return (CG.AWAY_PREFIX_BN + t) if away else t


def nosale_body(lang, minutes, pct):
    if lang == "en":
        return ("Someone was at the cash area, but no sale or khata entry was "
                "recorded within %d minute(s) (confidence %d%%). Please check it "
                "yourself — there may be a simple reason." % (minutes, pct))
    return ("ক্যাশের জায়গায় কেউ ছিলেন, কিন্তু %s মিনিটের মধ্যে কোনো বিক্রি বা খাতার "
            "লেখা হয়নি (আত্মবিশ্বাস %s%%)। অনুগ্রহ করে নিজে দেখে নিন — এর সহজ কারণও "
            "থাকতে পারে।" % (bn_digits(minutes), bn_digits(pct)))


# offline: what went silent
OFFLINE_WHAT = {
    "gateway": ("দোকানের Shop Box / গেটওয়ে", "The shop's Shop Box / gateway"),
    "camera": ("ক্যামেরা", "Camera"),
    "cloud": ("ক্যামেরা (ভেন্ডরের ক্লাউড)", "Camera (vendor cloud)"),
}


def offline_text(lang, kind, name, minutes):
    what_bn, what_en = OFFLINE_WHAT.get(kind, OFFLINE_WHAT["camera"])
    if lang == "en":
        title = "%s%s is silent — power or internet may be cut" % (
            what_en, (" " + name) if name else "")
        body = ("No signal for %d minutes. The power or the shop's internet may "
                "be off — please call the shop or check." % minutes)
        return title, body
    title = "%s%s থেকে সাড়া নেই — বিদ্যুৎ বা ইন্টারনেট বন্ধ হতে পারে" % (
        what_bn, (" " + name) if name else "")
    body = ("%s মিনিট ধরে কোনো সংকেত নেই। বিদ্যুৎ বা দোকানের ইন্টারনেট বন্ধ হতে "
            "পারে — দোকানে ফোন করে দেখে নিন।" % bn_digits(minutes))
    return title, body


def recovered_text(lang, kind, name, minutes):
    what_bn, what_en = OFFLINE_WHAT.get(kind, OFFLINE_WHAT["camera"])
    if lang == "en":
        return ("%s%s is back online" % (what_en, (" " + name) if name else ""),
                "It was silent for about %d minutes." % minutes)
    return ("%s%s আবার চালু হয়েছে" % (what_bn, (" " + name) if name else ""),
            "প্রায় %s মিনিট বন্ধ ছিল।" % bn_digits(minutes))


def opened_text(lang, shop, hhmm, open_at):
    if lang == "en":
        return ("%s has opened" % (shop or "The shop"),
                "First movement today at %s (opening time %s)." % (hhmm, open_at))
    return ("%s খুলেছে" % (shop or "দোকান"),
            "আজ প্রথম নড়াচড়া %s-এ (খোলার সময় %s)।" % (bn_digits(hhmm), bn_digits(open_at)))


def late_text(lang, shop, open_at, minutes):
    if lang == "en":
        return ("%s has not opened yet" % (shop or "The shop"),
                "Opening time was %s; no movement for %d minutes since. It may "
                "simply be a late start — please check." % (open_at, minutes))
    return ("%s এখনো খোলেনি" % (shop or "দোকান"),
            "খোলার সময় ছিল %s; তারপর %s মিনিট কোনো নড়াচড়া নেই। দেরিতে খোলাও হতে "
            "পারে — একটু খোঁজ নিন।" % (bn_digits(open_at), bn_digits(minutes)))


ESCALATE_PREFIX_BN = "মালিক এখনো দেখেননি — "
ESCALATE_PREFIX_EN = "The owner has not seen this yet — "


def escalate_title(lang, owner_name, title):
    if lang == "en":
        return "%s%s" % (ESCALATE_PREFIX_EN, title) if not owner_name else \
            "%s has not seen this yet — %s" % (owner_name, title)
    return "%s%s" % (ESCALATE_PREFIX_BN, title) if not owner_name else \
        "%s এখনো দেখেননি — %s" % (owner_name, title)


def shared_text(lang, owner_name, shop):
    if lang == "en":
        return ("%s shared a short clip with you" % (owner_name or "A shop owner"),
                "From %s. It opens only on your phone and is deleted after you "
                "watch it or within 24 hours." % (shop or "their shop"))
    return ("%s আপনাকে একটি ছোট ক্লিপ দেখতে দিয়েছেন" % (owner_name or "একজন দোকান-মালিক"),
            "%s থেকে। শুধু আপনার ফোনে খোলে; দেখার পরে বা ২৪ ঘণ্টার মধ্যে মুছে "
            "যায়।" % (shop or "তাঁর দোকান"))


# ================================================================ no-sale
NOSALE_TYPES = ("hand_in_cash_zone", "drawer_open")
LOOKBACK_DAYS = 14     # "this shop records sales/khata in Assisto" window


def nosale_applies(etype, settings, uses_records):
    """Defer a cash-zone touch to the no-sale check? Only when the owner has
    it on AND the shop records its sales / khata in Assisto (otherwise no
    sale can ever arrive and the immediate cash alert is the honest one)."""
    return (etype in NOSALE_TYPES and bool(settings.get("nosale_on"))
            and bool(uses_records))


def nosale_window(first_ts, last_ts, window_s):
    """[from, to] (epoch s) in which a sale / drawer-open / khata entry
    clears the touch: from `window_s` before the first touch to `window_s`
    after the last one (a group of touches is one episode — debounced)."""
    a, b = float(first_ts), float(last_ts)
    if b < a:
        a, b = b, a
    return a - window_s, b + window_s


def nosale_cleared(window, record_ts):
    lo, hi = window
    return any(lo <= float(t) <= hi for t in record_ts)


def nosale_tip(wrong_count, window_min):
    """A tip (never an automatic change) after repeated 'wrong' answers."""
    if wrong_count >= 3 and window_min < INT_SETTINGS["nosale_min"][1][1]:
        return "raise_window"
    return None


# ================================================================ offline
def offline_transitions(entities, now_ts, state, offline_s):
    """entities: [{key, kind, name, last_ts}] (last_ts None = never seen ->
    ignored). state: {key: {"since": ts, "alerted": bool}} (server-kept).
    Returns (new_state, went_offline, recovered): went_offline = entities
    silent >= offline_s that were not alerted yet (one alert per outage);
    recovered = [(entity, minutes)] for entities alerted earlier that spoke
    again. Pure; bounded (unknown keys dropped)."""
    new, went, back = {}, [], []
    prev = state if isinstance(state, dict) else {}
    for e in entities:
        k = str(e["key"])
        last = e.get("last_ts")
        if last is None:
            continue
        silent = now_ts - float(last)
        p = prev.get(k) if isinstance(prev.get(k), dict) else {}
        if silent >= offline_s:
            row = {"since": float(last), "alerted": bool(p.get("alerted"))}
            if not row["alerted"]:
                went.append(e)
                row["alerted"] = True
            new[k] = row
        elif p.get("alerted"):
            mins = max(1, int(round((float(last) - float(p.get("since", last))) / 60.0)))
            back.append((e, mins))
    return new, went, back


def offline_minutes_today(rows, day_start_ts, now_ts):
    """Minutes of silence inside today for [(since_ts, until_ts|None)]."""
    total = 0.0
    for since, until in rows:
        a = max(float(since), day_start_ts)
        b = min(float(until if until is not None else now_ts), now_ts)
        if b > a:
            total += b - a
    return int(total // 60)


# ================================================================ open / close
def _hm(s):
    try:
        h, m = str(s).split(":")
        h, m = int(h), int(m)
    except (TypeError, ValueError):
        return None
    if 0 <= h <= 23 and 0 <= m <= 59:
        return h * 60 + m
    return None


def is_open_now(hours, local_min):
    """Inside opening hours? open == close means open all day (the E2E and
    24 h shops). An overnight span (close < open) is handled."""
    if not isinstance(hours, dict):
        return None
    o, c = _hm(hours.get("open")), _hm(hours.get("close"))
    if o is None or c is None:
        return None
    if o == c:
        return True
    if o < c:
        return o <= local_min < c
    return local_min >= o or local_min < c


def open_notice_due(hours, local_min, weekday, settings, day_state):
    """'opened' when movement is seen after opening time today (once a day,
    only for real hours — not for all-day shops; never on a closed day)."""
    if not settings.get("opened_on") or weekday in settings.get("closed_days", []):
        return False
    o, c = _hm((hours or {}).get("open")), _hm((hours or {}).get("close"))
    if o is None or c is None or o == c:
        return False
    if (day_state or {}).get("opened_at"):
        return False
    return bool(is_open_now(hours, local_min)) and local_min >= o


def late_due(hours, local_min, weekday, settings, day_state, gateway_online):
    """'late opening' when `late_min` minutes after opening time there was
    no movement today. Not on a closed day, not for all-day shops, once a
    day, and NOT when the gateway itself is offline (that is the offline
    alert's job — we cannot see the shop then)."""
    if not settings.get("late_on") or weekday in settings.get("closed_days", []):
        return False
    o, c = _hm((hours or {}).get("open")), _hm((hours or {}).get("close"))
    if o is None or c is None or o == c:
        return False
    ds = day_state or {}
    if ds.get("opened_at") or ds.get("late_sent"):
        return False
    if not gateway_online:
        return False
    if not is_open_now(hours, local_min):
        return False
    return local_min - o >= int(settings.get("late_min", 30)) if local_min >= o else False


# ================================================================ siren
SIREN_SECONDS = (5, 30)        # bounds of one siren tap
SIREN_DEFAULT_S = 15


def siren_route(vendor, vendor_ref, gateway, has_host):
    """(route, reason). route: 'imou_cloud' (Imou Open Platform
    setDeviceCameraStatus enableType=siren — documented), 'hik_lan'
    (Hikvision ISAPI over the shop's LAN through the Shop Box: the audio
    alarm test + alarm output 1), or None with an honest reason code."""
    if vendor == "imou":
        if vendor_ref:
            return "imou_cloud", ""
        return None, "imou_not_linked"
    if vendor == "hikvision":
        if gateway in ("shopbox", "pc") and has_host:
            return "hik_lan", ""
        return None, "hik_needs_gateway"
    if vendor == "ezviz":
        # EZVIZ Open Platform: no documented public call that sounds a
        # camera's siren on demand (only alarm-list / capture / defence
        # settings) — we do not use the private app API.
        return None, "ezviz_no_api"
    return None, "vendor_no_api"


SIREN_REASONS = {
    "imou_not_linked": ("এই Imou ক্যামেরা এখনো Imou ক্লাউডে যুক্ত নয় — ক্যামেরার ⋮ → Imou ক্লাউড লিংক করুন।",
                        "This Imou camera is not linked to the Imou cloud yet — camera ⋮ → link Imou cloud."),
    "hik_needs_gateway": ("Hikvision সাইরেন শুধু দোকানের Shop Box / কম্পিউটার গেটওয়ে দিয়ে বাজানো যায়।",
                          "A Hikvision siren can only be sounded through the shop's Shop Box / computer gateway."),
    "ezviz_no_api": ("EZVIZ-এর খোলা প্ল্যাটফর্মে সাইরেন বাজানোর কোনো অফিসিয়াল উপায় নেই — EZVIZ অ্যাপ থেকে বাজান।",
                     "EZVIZ's open platform has no official way to sound the siren — use the EZVIZ app."),
    "vendor_no_api": ("এই ক্যামেরায় দূর থেকে সাইরেন বাজানোর অফিসিয়াল উপায় আমরা পাইনি।",
                      "We found no official way to sound this camera's siren remotely."),
    "not_supported": ("এই ক্যামেরা মডেলটি দূর থেকে সাইরেন সমর্থন করে না।",
                      "This camera model does not support a remote siren."),
}


# ================================================================ caps + cost
# Per tier, per OWNER per day (all sites). New alert types; the no-sale
# alert itself is a cash alert and counts in cash_guard's alerts_day.
EXTRA_CAP_DEFAULTS = {
    "free": {"offline_day": 2, "escalations_day": 2, "sirens_day": 3,
             "notices_day": 2},
    "premium": {"offline_day": 4, "escalations_day": 4, "sirens_day": 5,
                "notices_day": 2},
    "business": {"offline_day": 12, "escalations_day": 30, "sirens_day": 20,
                 "notices_day": 4},
}
EXTRA_CAP_BOUNDS = {"offline_day": (0, 48), "escalations_day": (0, 100),
                    "sirens_day": (0, 50), "notices_day": (0, 10)}
# A share: ONE more person per clip. Each clip's cost (cash_guard
# COST_PER_CLIP, 2.7 MB) already budgets one upload + TWO downloads; a clip
# sealed only for the owner may be shown to one Circle member inside that
# budget (a re-upload from the phone is ingress, which is free).


def extra_caps(tier, shop_cfg=None):
    tier = tier if tier in EXTRA_CAP_DEFAULTS else "free"
    cfg = shop_cfg or {}
    out = {"tier": tier}
    for k, default in EXTRA_CAP_DEFAULTS[tier].items():
        lo, hi = EXTRA_CAP_BOUNDS[k]
        raw = cfg.get("cctvx_%s_%s" % (tier, k), default)
        try:
            if isinstance(raw, bool):
                raise TypeError
            v = int(float(raw))
        except (TypeError, ValueError):
            v = default
        out[k] = max(lo, min(hi, v))
    return out


# WORST-CASE cost, BDT, stated assumptions (also in
# owner_actions/CCTV_EXTRAS_BN.md):
#   FCM push                                   0        free
#   FamilyAlert + NotifEvent rows, ~5 ms CPU   0.0002
#   escalation: + recipient opens the ONE snapshot (<=150 KB, ~৳11/GB)
#                                              0.002
#   offline / opened / late notice (no image)  0.0002
#   siren: one vendor API call / LAN task      0.0001
#   no-sale check (2-3 indexed queries)        0.0001 per cash alert
#   minute tick: <=0.1 ms CPU per site per minute (bulk queries)
#                at ৳0.00077 per core-second   0.0033 per site per month
#   vendor-cloud online check every 10 min, ~5 ms CPU per call
#                                              0.017 per cloud camera / month
COST_ROW_BDT = 0.0002
COST_ESCALATION_BDT = 0.002
COST_NOTICE_BDT = 0.0002
COST_SIREN_BDT = 0.0001
COST_NOSALE_CHECK_BDT = 0.0001
COST_TICK_SITE_MONTH_BDT = 0.0033
COST_CLOUD_CAM_MONTH_BDT = 0.017
CLOUD_CHECK_EVERY_S = 600


def extras_monthly_cost_bdt(caps, extra, sites=1, cloud_cameras=None, days=30):
    """Worst case: every capped action every day + the tick + cloud checks."""
    cams = caps["cameras"] if cloud_cameras is None else cloud_cameras
    daily = (extra["escalations_day"] * COST_ESCALATION_BDT
             + extra["offline_day"] * COST_NOTICE_BDT
             + extra["notices_day"] * COST_NOTICE_BDT
             + extra["sirens_day"] * COST_SIREN_BDT
             + caps["alerts_day"] * COST_NOSALE_CHECK_BDT)
    return round(days * daily + sites * COST_TICK_SITE_MONTH_BDT
                 + cams * COST_CLOUD_CAM_MONTH_BDT, 3)


def inside_40_rule(tier, caps, extra):
    """Cash Guard worst case + extras worst case <= the tier's headroom above
    40 % (Free is a marketing cost)."""
    if tier not in CG.HEADROOM_BDT:
        return True
    total = CG.monthly_cost_bdt(caps) + extras_monthly_cost_bdt(caps, extra)
    return total <= CG.HEADROOM_BDT[tier]


# ================================================================ placement
# Deterministic image statistics (no AI, no credits). Inputs are computed by
# the view from the camera's latest still with PIL:
#   frame_mean, frame_std         0..255 luminance of the whole picture
#   zone_mean, zone_std           inside the cash zone
#   zone_dark, zone_bright        fraction of zone pixels < 30 / > 245
#   zone_area                     zone polygon area / frame area (0..1)
#   zone_margin                   smallest distance of the zone to the frame
#                                 edge (0..0.5, fraction of the frame)
#   zone_edges                    fraction of zone pixels on an edge (0..1)
PLACEMENT_TIPS = {
    "no_zone": ("আগে ছবির ওপর ক্যাশ ড্রয়ারের জায়গাটি আঙুলে এঁকে দিন।",
                "First draw the cash drawer area on the picture with your finger."),
    "too_dark": ("ক্যাশের জায়গাটি অন্ধকার — ড্রয়ারের ওপর একটি বাতি দিন বা ক্যামেরা আলোর দিকে ঘোরান।",
                 "The cash area is dark — add a light over the drawer or turn the camera towards the light."),
    "glare": ("ক্যাশের জায়গায় খুব উজ্জ্বল ঝলক — বাতি বা জানালার আলো সরাসরি ক্যামেরায় পড়ছে, একটু কোণ বদলান।",
              "Strong glare on the cash area — a lamp or window shines into the camera; change the angle a little."),
    "low_contrast": ("ক্যাশের জায়গাটি ঝাপসা বা ঢাকা মনে হচ্ছে — লেন্স মুছুন, সামনে কিছু থাকলে সরান।",
                     "The cash area looks blurred or covered — wipe the lens and move anything in front of it."),
    "zone_small": ("ক্যাশের জায়গাটি ছবিতে খুব ছোট — ক্যামেরা ড্রয়ারের আরও কাছে বা ওপরে লাগান।",
                   "The cash area is very small in the picture — mount the camera closer to or above the drawer."),
    "zone_large": ("ক্যাশের জায়গা প্রায় পুরো ছবি — শুধু ড্রয়ারটি আঁকুন, যাতে দোকানের সাধারণ নড়াচড়ায় সতর্কতা না যায়।",
                   "The cash area covers almost the whole picture — draw only the drawer so normal shop movement does not alert."),
    "zone_edge": ("ক্যাশের জায়গাটি ছবির একদম কিনারে — হাত ফ্রেমের বাইরে চলে যেতে পারে, ক্যামেরা একটু ঘোরান।",
                  "The cash area touches the edge of the picture — hands may leave the frame; turn the camera a little."),
    "ok": ("ঠিক আছে — ক্যাশের জায়গা পরিষ্কার দেখা যাচ্ছে, আলোও যথেষ্ট।",
           "Looks good — the cash area is clearly visible and the light is enough."),
}
PLACEMENT_LIMITS = {"dark_mean": 45, "dark_frac": 0.45, "bright_frac": 0.20,
                    "min_std": 12.0, "min_edges": 0.015, "min_area": 0.02,
                    "max_area": 0.60, "min_margin": 0.01}


def placement_report(stats, lang="bn"):
    """{ok, score 0..100, checks: [{key, ok, value, tip}], tips: [str]}.
    Honest: this checks light, contrast and framing of the cash zone — it can
    not tell WHAT is in front of the lens."""
    L = PLACEMENT_LIMITS
    checks = []

    def add(key, ok, value, tip_key):
        bn, en = PLACEMENT_TIPS[tip_key]
        checks.append({"key": key, "ok": bool(ok), "value": value,
                       "tip": None if ok else pick(lang, bn, en)})

    if not stats or stats.get("zone_area") in (None, 0):
        bn, en = PLACEMENT_TIPS["no_zone"]
        return {"ok": False, "score": 0, "checks": [
            {"key": "zone", "ok": False, "value": None, "tip": pick(lang, bn, en)}],
            "tips": [pick(lang, bn, en)]}
    zm, zs = float(stats.get("zone_mean", 0)), float(stats.get("zone_std", 0))
    dark, bright = float(stats.get("zone_dark", 0)), float(stats.get("zone_bright", 0))
    area, margin = float(stats.get("zone_area", 0)), float(stats.get("zone_margin", 0))
    edges = float(stats.get("zone_edges", 0))
    add("light", zm >= L["dark_mean"] and dark <= L["dark_frac"], round(zm, 1), "too_dark")
    add("glare", bright <= L["bright_frac"], round(bright, 3), "glare")
    add("clear", zs >= L["min_std"] and edges >= L["min_edges"],
        round(zs, 1), "low_contrast")
    add("size_small", area >= L["min_area"], round(area, 3), "zone_small")
    add("size_large", area <= L["max_area"], round(area, 3), "zone_large")
    add("edge", margin >= L["min_margin"], round(margin, 3), "zone_edge")
    good = sum(1 for c in checks if c["ok"])
    score = int(round(100.0 * good / len(checks)))
    tips = [c["tip"] for c in checks if c["tip"]]
    if not tips:
        tips = [pick(lang, *PLACEMENT_TIPS["ok"])]
    return {"ok": good == len(checks), "score": score, "checks": checks, "tips": tips}


# ================================================================ report
def report_lines(r):
    """[{bn, en}] for the evening brief's guard section, from the day's
    counts r = {drawer_nosale, drawer_sale, away_events, offline_min,
    escalated, after_hours, opened_at, late}. Empty when nothing happened
    and no camera exists (the caller decides)."""
    out = []
    ns, sl = int(r.get("drawer_nosale", 0)), int(r.get("drawer_sale", 0))
    out.append({"bn": "ক্যাশ ড্রয়ার: বিক্রিসহ %sবার, বিক্রি ছাড়া %sবার।" % (
        bn_digits(sl), bn_digits(ns)),
        "en": "Cash drawer: %d time(s) with a sale, %d without." % (sl, ns)})
    aw = int(r.get("away_events", 0))
    if aw:
        out.append({"bn": "আপনি দূরে থাকার সময় সতর্কতা: %sটি।" % bn_digits(aw),
                    "en": "Alerts while you were away: %d." % aw})
    ah = int(r.get("after_hours", 0))
    if ah:
        out.append({"bn": "বন্ধের সময়ে নড়াচড়া: %sবার।" % bn_digits(ah),
                    "en": "Movement after closing time: %d." % ah})
    om = int(r.get("offline_min", 0))
    out.append({"bn": ("ক্যামেরা/ইন্টারনেট বন্ধ ছিল: %s মিনিট।" % bn_digits(om)) if om
                else "ক্যামেরা ও ইন্টারনেট সারাদিন চালু ছিল।",
                "en": ("Camera/internet silent: %d min." % om) if om
                else "Cameras and internet stayed on all day."})
    es = int(r.get("escalated", 0))
    if es:
        out.append({"bn": "আপনি না দেখায় অন্যকে পাঠানো সতর্কতা: %sটি।" % bn_digits(es),
                    "en": "Alerts passed on because you had not seen them: %d." % es})
    if r.get("opened_at"):
        out.append({"bn": "দোকান খুলেছে %s-এ।" % bn_digits(r["opened_at"]),
                    "en": "The shop opened at %s." % r["opened_at"]})
    elif r.get("late"):
        out.append({"bn": "আজ দোকান খোলার সময়ে কোনো নড়াচড়া দেখা যায়নি।",
                    "en": "No movement was seen at opening time today."})
    return out


# ================================================================ evidence
def gd_draft(lang, f):
    """A General Diary draft for the police from the alert's FACTS only —
    never says who did it, never says 'theft' (the owner writes what they
    know). f = {owner, shop, camera, when, event_id, kind_bn, kind_en,
    files: n, manifest_sha256}."""
    owner = f.get("owner") or pick(lang, "[আপনার নাম]", "[your name]")
    shop = f.get("shop") or pick(lang, "[দোকানের নাম ও ঠিকানা]", "[shop name and address]")
    if lang == "en":
        return (
            "To\nThe Officer-in-Charge\n[Police Station]\n\n"
            "Subject: General Diary about an incident recorded by CCTV\n\n"
            "Sir,\n"
            "I, %s, owner of %s, respectfully state that on %s the CCTV camera "
            "\"%s\" recorded the following: %s.\n\n"
            "I am attaching an evidence pack exported from the Assisto app "
            "(alert no. %s): %d file(s) — the photo and the short clip frames "
            "with their times. Each file's SHA-256 fingerprint is listed in "
            "manifest.json; the fingerprint of the manifest is %s.\n\n"
            "[Write here what you know and what is missing, in your own words.]\n\n"
            "I request that this General Diary be recorded.\n\n"
            "Yours faithfully,\n%s\n[your phone] [date]"
            % (owner, shop, f.get("when", ""), f.get("camera", ""),
               f.get("kind_en", ""), f.get("event_id", ""), int(f.get("files", 0)),
               f.get("manifest_sha256", ""), owner))
    return (
        "বরাবর\nভারপ্রাপ্ত কর্মকর্তা\n[থানার নাম]\n\n"
        "বিষয়: সিসিটিভিতে ধরা পড়া একটি ঘটনা সম্পর্কে সাধারণ ডায়েরি\n\n"
        "জনাব,\n"
        "আমি %s, %s-এর মালিক, বিনীতভাবে জানাচ্ছি যে %s সময়ে \"%s\" সিসিটিভি "
        "ক্যামেরায় এটি ধরা পড়ে: %s।\n\n"
        "Assisto অ্যাপ থেকে নেওয়া প্রমাণের প্যাকেট (সতর্কতা নং %s) সংযুক্ত করছি: "
        "%sটি ফাইল — ছবি এবং ছোট ক্লিপের ফ্রেম, সময়সহ। প্রতিটি ফাইলের SHA-256 "
        "আঙুলছাপ manifest.json-এ আছে; manifest-এর আঙুলছাপ %s।\n\n"
        "[আপনি যা জানেন ও যা হারিয়েছে, নিজের ভাষায় এখানে লিখুন।]\n\n"
        "অনুগ্রহ করে একটি সাধারণ ডায়েরি লিপিবদ্ধ করুন।\n\n"
        "নিবেদক,\n%s\n[আপনার ফোন] [তারিখ]"
        % (owner, shop, bn_digits(f.get("when", "")), f.get("camera", ""),
           f.get("kind_bn", ""), bn_digits(f.get("event_id", "")),
           bn_digits(int(f.get("files", 0))), f.get("manifest_sha256", ""), owner))


# ================================================================ privacy kit
def privacy_kit(place, retention_days):
    """Printable sticker + staff notice, Bangla AND English (a sticker shows
    both). Truthful: what this system does — not legal advice, no claims
    about any law."""
    place = (place or "").strip()[:80]
    days = max(0, min(30, int(retention_days or 0)))
    sticker = {
        "bn": ["সিসিটিভি চালু আছে",
               "নিরাপত্তা ও ক্যাশ হিসাবের জন্য এই %s ক্যামেরায় দেখা হয়।" % (place or "দোকান"),
               "শব্দ রেকর্ড হয় না · মুখ চেনার ব্যবস্থা নেই",
               "প্রশ্ন থাকলে মালিকের সাথে কথা বলুন"],
        "en": ["CCTV in operation",
               "This %s is watched by cameras for safety and cash checks." % (place or "shop"),
               "No sound recording · No face recognition",
               "Questions? Please ask the owner"],
    }
    snap_bn = ("একটি ছবি %s দিনের মধ্যে মুছে যায়" % bn_digits(days)) if days else \
        "কোনো ছবি রাখা হয় না"
    snap_en = ("one photo, deleted within %d days" % days) if days else "no photo is kept"
    staff = {
        "bn": ("কর্মীদের জন্য বিজ্ঞপ্তি\n\n"
               "এই %s-এ সিসিটিভি ক্যামেরা চালু আছে — দোকান, মালামাল ও ক্যাশের নিরাপত্তার জন্য।\n"
               "• ক্যামেরা শুধু ঠিক করা জায়গাগুলো দেখে (যেমন ক্যাশ ড্রয়ার ও দরজা)। টয়লেট বা কাপড় বদলানোর জায়গায় ক্যামেরা নেই।\n"
               "• কোনো কিছু অস্বাভাবিক মনে হলে মালিকের ফোনে সতর্কতা যায়: %s, এবং ৩–৫ সেকেন্ডের একটি ক্লিপ, যা তালাবদ্ধ (এনক্রিপ্টেড) — শুধু মালিকের ফোনে খোলে, দেখার পরে বা ২৪ ঘণ্টার মধ্যে মুছে যায়।\n"
               "• সতর্কতা কাউকে দোষী বলে না — মালিক নিজে দেখে সিদ্ধান্ত নেন। ভুল সতর্কতাও হতে পারে।\n"
               "• শব্দ রেকর্ড হয় না, মুখ চেনার কোনো ব্যবস্থা নেই।\n"
               "• বিক্রি বা খাতার লেখা ঠিক সময়ে করলে ভুল সতর্কতা কম হয়।\n"
               "• কোনো প্রশ্ন বা আপত্তি থাকলে মালিকের সাথে কথা বলুন।\n\n"
               "মালিকের স্বাক্ষর: ____________  তারিখ: ____________\n"
               "কর্মীর স্বাক্ষর (পড়েছি): ____________"
               % (place or "দোকান", snap_bn)),
        "en": ("Notice for staff\n\n"
               "CCTV cameras are in operation in this %s — for the safety of the shop, goods and cash.\n"
               "• The cameras only watch chosen areas (such as the cash drawer and the door). There are no cameras in toilets or changing areas.\n"
               "• If something looks unusual, the owner's phone gets an alert: %s, and a 3-5 second clip that is locked (encrypted) — it opens only on the owner's phone and is deleted after viewing or within 24 hours.\n"
               "• An alert never says anyone did anything wrong — the owner looks and decides. Alerts can be mistaken.\n"
               "• No sound is recorded and there is no face recognition.\n"
               "• Entering sales or khata entries on time means fewer mistaken alerts.\n"
               "• Please talk to the owner about any question or objection.\n\n"
               "Owner's signature: ____________  Date: ____________\n"
               "Staff signature (I have read this): ____________"
               % (place or "shop", snap_en)),
    }
    return {"sticker": sticker, "staff_notice": staff,
            "sizes": ["A4", "A5"], "legal_note": False}


def all_strings():
    """Every human string this module can emit (for the never-accuse test)."""
    out = [NOSALE_TITLE_BN, NOSALE_TITLE_EN, NOSALE_TITLE_NO_CLIP_BN,
           NOSALE_TITLE_NO_CLIP_EN, ESCALATE_PREFIX_BN, ESCALATE_PREFIX_EN]
    for lang in ("bn", "en"):
        out.append(nosale_body(lang, 2, 70))
        for k in OFFLINE_WHAT:
            out.extend(offline_text(lang, k, "X", 10))
            out.extend(recovered_text(lang, k, "X", 10))
        out.extend(opened_text(lang, "S", "09:05", "09:00"))
        out.extend(late_text(lang, "S", "09:00", 30))
        out.extend(shared_text(lang, "O", "S"))
        out.append(escalate_title(lang, "O", "T"))
        out.append(gd_draft(lang, {"event_id": 1, "files": 2}))
        kit = privacy_kit("দোকান", 7)
        out.extend(kit["sticker"][lang])
        out.append(kit["staff_notice"][lang])
    for bn, en in list(PLACEMENT_TIPS.values()) + list(SIREN_REASONS.values()):
        out.extend([bn, en])
    for ln in report_lines({"drawer_nosale": 1, "drawer_sale": 2, "away_events": 1,
                            "offline_min": 3, "escalated": 1, "after_hours": 1,
                            "opened_at": "09:00"}):
        out.extend([ln["bn"], ln["en"]])
    return out
