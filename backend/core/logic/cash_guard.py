"""
cash_guard.py — PURE rules for the CCTV Smart Cash Guard (owner order 28 Oct,
part A). NO Django, NO DB, NO network: plain values in, plain values out, so
every rule is pinned by fast unit tests (core/tests_cashguard.py).

1. WORDING — never accuse a person. Cash events say
   "সন্দেহজনক ক্যাশ সরানো — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন" /
   "Possible cash removal — watch the clip and decide". FORBIDDEN_WORDS is
   checked by tests against every string this module and the views emit.

2. OWNER-AWAY MODE — the owner taps "I'm away" (until a time) or sets an
   away schedule (zones-v2 schedule format). While away: every camera counts
   as ARMED, quiet hours are ignored and every alert is HIGH priority.
   The state is the SERVER's; a device can never claim it.

3. PLAN CAPS — cameras included / alerts per day / encrypted clips per day,
   per plan tier (free | premium | business), admin-editable through the
   pricing "shop" block, bounded (nothing is unlimited).

4. CLIP ENVELOPE — the edge (Shop Box / Guard Box) cuts a 3-5 s clip from the
   LOCAL stream and seals it end to end: a fresh per-event content key
   (ChaCha20-Poly1305), wrapped for every recipient's X25519 public key with
   the SAME construction the app's chat E2E uses (x25519-xchacha-fallback-v1:
   X25519 -> HKDF-SHA256(zero salt, info = "assisto-circle-<scheme>" + lo + hi)
   -> ChaCha20-Poly1305, aad = sender key id). The server only ever holds the
   ciphertext + this public metadata, for at most CLIP_TTL_S (24 h) or until
   the owner has watched it. clip_meta_problems() validates the metadata.

5. SERVER SNAPSHOT CHECK — for vendor-cloud / camera-push alarms the server
   has ONE still and, often, the camera's own target box. box_in_zone() is the
   cheap geometric check (no model); the optional detector pass is in the
   view, capped and off by default (2 vCPU box — the edge is preferred).

6. HAND-TO-POCKET — a label we may only show when its precision has been
   MEASURED on real labelled clips. HAND_TO_POCKET_LABEL stays False; the
   metric harness is tools/cashguard/precision_report.py. Not measured yet.
"""
import base64
import re
from datetime import datetime

# ---------------------------------------------------------------- wording
CASH_TYPES = ("hand_in_cash_zone", "drawer_open")
TITLE_BN = "সন্দেহজনক ক্যাশ সরানো — ক্লিপ দেখে আপনি সিদ্ধান্ত নিন"
TITLE_EN = "Possible cash removal — watch the clip and decide"
TITLE_NO_CLIP_BN = "সন্দেহজনক ক্যাশ সরানো — ছবি দেখে আপনি সিদ্ধান্ত নিন"
TITLE_NO_CLIP_EN = "Possible cash removal — look at the photo and decide"
AWAY_PREFIX_BN = "আপনি দূরে আছেন — "
AWAY_PREFIX_EN = "You are away — "
AFTER_HOURS_ZONE_BN = "দোকান বন্ধের সময়ে ক্যাশের জায়গায় কেউ আছে"
AFTER_HOURS_ZONE_EN = "Someone is at the cash area after closing time"
# never in any alert text (tests scan every string we emit)
FORBIDDEN_WORDS = ("চুরি", "চোর", "theft", "thief", "steal", "stole", "robbery")

HAND_TO_POCKET_LABEL = False          # not measured on real clips -> OFF
HAND_TO_POCKET_MIN_PRECISION = 0.90   # the bar before the label may ever show


def cash_title(lang, has_clip=True, away=False):
    if lang == "en":
        t = TITLE_EN if has_clip else TITLE_NO_CLIP_EN
        return (AWAY_PREFIX_EN + t) if away else t
    t = TITLE_BN if has_clip else TITLE_NO_CLIP_BN
    return (AWAY_PREFIX_BN + t) if away else t


def is_cash_event(etype, signals=None):
    """A cash-guard event: a hand/person at the cash zone (or the drawer)
    with no matching sale, or someone in the cash zone after closing."""
    if etype in CASH_TYPES:
        return True
    s = signals or {}
    return etype == "after_hours" and bool(s.get("person_in_zone"))


def accuses(text):
    low = (text or "").lower()
    return any(w in low for w in FORBIDDEN_WORDS)


# ---------------------------------------------------------------- away mode
def _parse_iso(v):
    if not isinstance(v, str) or not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None


def away_active(away, now_aware, local_dt, is_armed):
    """True while the owner is away: an explicit `until` in the future, or
    inside the away `schedule` (checked with the zones-v2 `is_armed`)."""
    if not isinstance(away, dict):
        return False
    until = _parse_iso(away.get("until"))
    if until is not None and until.tzinfo is not None and until > now_aware:
        return True
    sched = away.get("schedule")
    if isinstance(sched, dict) and sched.get("days"):
        return bool(is_armed(sched, local_dt))
    return False


AWAY_MAX_HOURS = 24 * 14      # an "I'm away" tap lasts at most two weeks


def away_until_from_hours(hours, now_aware):
    """until = now + hours (bounded 1 h .. 14 days); None for bad input."""
    from datetime import timedelta
    try:
        h = float(hours)
    except (TypeError, ValueError):
        return None
    if h != h or h <= 0:
        return None
    h = max(1.0, min(float(AWAY_MAX_HOURS), h))
    return now_aware + timedelta(hours=h)


# ---------------------------------------------------------------- plan caps
TIERS = ("free", "premium", "business")
# (default, (min, max)) per knob — pricing "shop" block keys
CAP_DEFAULTS = {
    "cashguard_free_cameras": (1, (0, 4)),
    "cashguard_premium_cameras": (2, (1, 8)),
    # business cameras come from limits.business_included_cameras (default 4)
    # alerts / clips are per OWNER per day (all their sites together)
    "cashguard_free_alerts_day": (5, (1, 50)),
    "cashguard_premium_alerts_day": (12, (1, 200)),
    "cashguard_business_alerts_day": (30, (1, 500)),
    "cashguard_free_clips_day": (1, (0, 20)),
    "cashguard_premium_clips_day": (2, (0, 100)),
    "cashguard_business_clips_day": (10, (0, 400)),
    "cashguard_clip_kb": (900, (100, 2048)),
}


def knob(shop_cfg, key):
    default, (lo, hi) = CAP_DEFAULTS[key]
    raw = (shop_cfg or {}).get(key, default)
    try:
        v = int(float(raw))
    except (TypeError, ValueError):
        v = default
    if isinstance(raw, bool):
        v = default
    return max(lo, min(hi, v))


def caps_for(tier, shop_cfg, business_cameras=4):
    tier = tier if tier in TIERS else "free"
    cams = (int(business_cameras) if tier == "business"
            else knob(shop_cfg, "cashguard_%s_cameras" % tier))
    return {"tier": tier, "cameras": cams,
            "alerts_day": knob(shop_cfg, "cashguard_%s_alerts_day" % tier),
            "clips_day": knob(shop_cfg, "cashguard_%s_clips_day" % tier),
            "clip_kb": knob(shop_cfg, "cashguard_clip_kb")}


# ---------------------------------------------------------------- clips
CLIP_TTL_S = 24 * 3600
CLIP_MIN_S, CLIP_MAX_S = 3.0, 5.0
CLIP_SCHEME = "x25519-xchacha-fallback-v1"     # = the app's kFallbackScheme
CLIP_ALG = "chacha20poly1305"
CLIP_AAD = "assisto-cashguard-clip-v1"
CLIP_FORMAT = "acg1"          # our JPEG-sequence container (no video codec)
CLIP_UPLOAD_WINDOW_S = 15 * 60  # a clip must arrive within 15 min of its event
_REF_RE = re.compile(r"^[0-9a-f]{16,64}$")
_KEYID_RE = re.compile(r"^[0-9a-f]{6,64}$")
MAX_WRAPS = 8


def clean_clip_ref(v):
    v = (str(v or "")).strip().lower()
    return v if _REF_RE.match(v) else ""


def _b64len(v):
    try:
        return len(base64.b64decode(str(v), validate=True))
    except Exception:
        return -1


def clip_meta_problems(meta):
    """[] when the public clip metadata is well formed, else problem codes.
    The server can NOT check the ciphertext itself — that is the point."""
    if not isinstance(meta, dict):
        return ["bad_meta"]
    out = []
    if meta.get("v") != 1:
        out.append("bad_version")
    if meta.get("alg") != CLIP_ALG or meta.get("scheme") != CLIP_SCHEME:
        out.append("bad_alg")
    if meta.get("format") != CLIP_FORMAT:
        out.append("bad_format")
    if meta.get("aad") != CLIP_AAD:
        out.append("bad_aad")
    if _b64len(meta.get("nonce")) != 12:
        out.append("bad_nonce")
    if _b64len(meta.get("eph_pub")) != 32:
        out.append("bad_eph_pub")
    if not _KEYID_RE.match(str(meta.get("eph_key_id") or "")):
        out.append("bad_eph_key_id")
    try:
        dur = float(meta.get("duration_s"))
    except (TypeError, ValueError):
        dur = -1
    if not (CLIP_MIN_S - 0.5 <= dur <= CLIP_MAX_S + 0.5):
        out.append("bad_duration")
    try:
        frames = int(meta.get("frames"))
    except (TypeError, ValueError):
        frames = 0
    if not 3 <= frames <= 200:
        out.append("bad_frames")
    wraps = meta.get("wraps")
    if not isinstance(wraps, dict) or not wraps or len(wraps) > MAX_WRAPS:
        out.append("bad_wraps")
    else:
        for uid, w in wraps.items():
            if not str(uid).isdigit() or not isinstance(w, dict):
                out.append("bad_wraps")
                break
            # a wrapped 32-byte key is base64 text (44 chars) + 16-byte tag
            if _b64len(w.get("nonce")) != 12 or not 40 <= _b64len(w.get("ct")) <= 80:
                out.append("bad_wraps")
                break
            if not _KEYID_RE.match(str(w.get("key_id") or "")):
                out.append("bad_wraps")
                break
    return out


def meta_for(meta, user_id):
    """The metadata one recipient gets: only THEIR wrap (other people's
    wrapped keys are useless to them, but we still do not hand them out)."""
    if not isinstance(meta, dict):
        return {}
    out = {k: v for k, v in meta.items() if k != "wraps"}
    w = (meta.get("wraps") or {}).get(str(user_id))
    out["wrap"] = w if isinstance(w, dict) else None
    return out


def looks_like_plain_media(raw):
    """Ciphertext is uniformly random; a JPEG/PNG/video header means the edge
    sent PLAIN media — refused (we never keep a readable clip)."""
    head = bytes(raw[:16])
    if head[:3] == b"\xff\xd8\xff" or head[:8] == b"\x89PNG\r\n\x1a\n":
        return True
    if head[:4] in (b"ACG1",):
        return True
    return (head[4:8] in (b"ftyp", b"moov", b"mdat", b"wide")
            or head[:4] == b"\x1aE\xdf\xa3"
            or (head[:4] == b"RIFF" and raw[8:12] == b"AVI ")
            or head[:3] == b"FLV")


# ---------------------------------------------------------------- server check
def _poly_contains(x, y, poly):
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            xc = (xj - xi) * (y - yi) / ((yj - yi) or 1e-12) + xi
            if x < xc:
                inside = not inside
        j = i
    return inside


def box_in_zone(box, poly, min_hits=2):
    """Does a normalised (x1, y1, x2, y2) target box overlap the cash polygon?
    Samples a 3x3 grid inside the box; `min_hits` grid points must fall in
    the polygon (cheap, deterministic — no model, no image decode)."""
    if not poly or len(poly) < 3:
        return False
    try:
        x1, y1, x2, y2 = (float(v) for v in box)
    except (TypeError, ValueError):
        return False
    if x2 < x1:
        x1, x2 = x2, x1
    if y2 < y1:
        y1, y2 = y2, y1
    hits = 0
    for fx in (0.15, 0.5, 0.85):
        for fy in (0.15, 0.5, 0.85):
            if _poly_contains(x1 + (x2 - x1) * fx, y1 + (y2 - y1) * fy, poly):
                hits += 1
    return hits >= min_hits


def cash_zone_of(zone_config):
    zc = zone_config if isinstance(zone_config, dict) else {}
    for z in zc.get("zones") or []:
        if isinstance(z, dict) and z.get("type") == "cash" and z.get("points"):
            return z["points"]
    return zc.get("cash_zone") or None


# ---------------------------------------------------------------- 40% rule
# WORST-CASE cost, BDT, stated assumptions (the same table is in
# owner_actions/CCTV_VENDOR_ACCOUNTS_BN.md):
#   push (FCM)                             0        free
#   ONE snapshot <= 150 KB, kept <= 30 d   0.0015   disk ~৳10/GB-month
#   its traffic: up + 2 downloads 0.45 MB  0.005    ~৳11/GB (AWS overage $0.09)
#   optional server check, 60 ms 1 core    0.0001   2 vCPU box ~৳4,000/month
#   => per alert                           0.006
#   ONE clip <= 900 KB, kept <= 24 h       0.0003
#   its traffic: up + 2 downloads 2.7 MB   0.03
#   => per clip (on top of its alert)      0.03
COST_PER_ALERT_BDT = 0.006
COST_PER_CLIP_BDT = 0.03
# Headroom ABOVE 40 % that each paid tier's AI worst case leaves (PRICING_
# 40PCT_BN.md, at ৳125/USD): (margin - 40 %) x price. The premium tier's
# cheapest plan is Plus ৳199 at 42.2 % -> ৳4.38; Business ৳1,299 at 41.5 %.
HEADROOM_BDT = {"premium": round(199 * 0.022, 2), "business": round(1299 * 0.015, 2)}


def monthly_cost_bdt(caps, days=30):
    """Worst case: every alert and every clip of the cap, every day."""
    return round(days * (caps["alerts_day"] * COST_PER_ALERT_BDT
                         + caps["clips_day"] * COST_PER_CLIP_BDT), 2)


def inside_40_rule(tier, caps):
    """True when the cash-guard worst case fits in the tier's headroom (Free
    is a marketing cost, like the free daily AI answers)."""
    if tier not in HEADROOM_BDT:
        return True
    return monthly_cost_bdt(caps) <= HEADROOM_BDT[tier]
