"""
msg_guard.py — ONE shared guard for every message a BUSINESS sends to its own
customers on its own initiative (retention automations today; the booking
bot's reminders can reuse it). Pure decisions first, then three small DB
helpers (lazy imports, so the pure part stays Django-free for tests).

The rules it enforces (owner rule, big-week item H):
  * QUIET HOURS 21:00-09:00 Asia/Dhaka — nothing automated goes out then
    (`in_quiet_hours`, `next_allowed_at`).
  * CAPS — per customer per day / per week, per business per day. The owner
    may LOWER them, never raise above the server max (`effective_caps`).
  * STOP / unsubscribe — one opt-out is honoured INSTANTLY across all
    automations of that business, whatever channel it came from
    (`is_stop_text`, `stop_footer`, DB: `is_opted_out` / `record_opt_out`).
  * META policy — free-form text only inside the 24 h customer-service
    window; outside it WhatsApp needs an APPROVED template of the right
    category (no promotional content in a UTILITY template) that carries a
    stop option; Messenger outside 24 h is refused (`meta_plan`).

API for other features (booking, later marketing):

    from core.logic import msg_guard as MG
    caps = MG.effective_caps(owner_caps, server_max)          # pure
    v = MG.decide(opted_out=..., now=..., sent_customer_day=...,
                  sent_customer_week=..., sent_business_day=..., caps=caps,
                  transactional=False)                         # pure -> Verdict
    plan = MG.meta_plan(channel, within_24h, template, purpose)  # pure
    MG.is_opted_out(business_id, key) / MG.record_opt_out(...)    # DB
    MG.opted_out_keys(business_id)                                # DB, one pass
    MG.gate(business_id, key, now=..., caps=..., extra_day=0, extra_week=0,
            opted_out_set=None)

`key` is the customer's normalised phone (business_selling.normalize_phone)
or a channel id such as "psid:<id>". `transactional=True` (a reminder the
customer ASKED for, e.g. their own booking) skips the weekly marketing cap but
never quiet hours or an opt-out.
"""
from collections import namedtuple
from datetime import datetime, timedelta

try:
    from zoneinfo import ZoneInfo
    DHAKA = ZoneInfo("Asia/Dhaka")
except Exception:  # pragma: no cover - zoneinfo ships with py3.9+
    from datetime import timezone as _tz
    DHAKA = _tz(timedelta(hours=6))

QUIET_START_MIN = 21 * 60      # 21:00
QUIET_END_MIN = 9 * 60         # 09:00

# Server maximums (the owner may lower, never raise). Pricing → "retention"
# block may lower these further; it can never exceed HARD_MAX.
DEFAULT_CAPS = {"per_customer_day": 1, "per_customer_week": 2, "business_daily": 100}
HARD_MAX = {"per_customer_day": 1, "per_customer_week": 2, "business_daily": 1000}
MIN_CAPS = {"per_customer_day": 1, "per_customer_week": 1, "business_daily": 1}

PURPOSE_MARKETING = "marketing"
PURPOSE_UTILITY = "utility"

Verdict = namedtuple("Verdict", "ok reason retry_at")


# ===================================================================== time
def local(now):
    """An aware datetime in Asia/Dhaka."""
    return now.astimezone(DHAKA)


# bizauto: the window is Owner-Admin editable (Pricing -> "retention":
# quiet_start_hour 20-22, quiet_end_hour 8-10), so it ALWAYS covers at least
# 22:00-08:00 Dhaka. Read lazily + cached a minute; any failure = defaults.
QUIET_START_BOUNDS = (20, 22)
QUIET_END_BOUNDS = (8, 10)
_WIN_CACHE = {"win": None, "at": 0.0}
_WIN_TTL_S = 60.0


def quiet_window_from(cfg_block=None):
    """(start_min, end_min) from a normalized pricing "retention" block,
    clamped so the window always covers 22:00-08:00. Pure."""
    b = cfg_block if isinstance(cfg_block, dict) else {}
    sh = max(QUIET_START_BOUNDS[0], min(QUIET_START_BOUNDS[1],
                                        _int(b.get("quiet_start_hour"), QUIET_START_MIN // 60)))
    eh = max(QUIET_END_BOUNDS[0], min(QUIET_END_BOUNDS[1],
                                      _int(b.get("quiet_end_hour"), QUIET_END_MIN // 60)))
    return sh * 60, eh * 60


def reset_window_cache():
    _WIN_CACHE["win"], _WIN_CACHE["at"] = None, 0.0


def quiet_window():
    """The live (start_min, end_min). Never raises."""
    import time
    if _WIN_CACHE["win"] is not None and time.monotonic() - _WIN_CACHE["at"] < _WIN_TTL_S:
        return _WIN_CACHE["win"]
    try:
        from .. import billing
        win = quiet_window_from(billing.cfg().get("retention"))
    except Exception:
        return QUIET_START_MIN, QUIET_END_MIN
    _WIN_CACHE["win"], _WIN_CACHE["at"] = win, time.monotonic()
    return win


def quiet_label(window=None):
    """{"start": "21:00", "end": "09:00"} for the screens."""
    a, b = window or quiet_window()
    return {"start": "%02d:%02d" % (a // 60, a % 60), "end": "%02d:%02d" % (b // 60, b % 60)}


def in_quiet_hours(now, window=None):
    a, b = window or quiet_window()
    m = local(now)
    mod = m.hour * 60 + m.minute
    return mod >= a or mod < b


def next_allowed_at(now, window=None):
    """`now` when outside quiet hours, else the next end of the window."""
    win = window or quiet_window()
    if not in_quiet_hours(now, win):
        return now
    m = local(now)
    end_h, end_m = divmod(win[1], 60)
    day = m.date() if (m.hour * 60 + m.minute) < win[1] else (m + timedelta(days=1)).date()
    return datetime(day.year, day.month, day.day, end_h, end_m, tzinfo=DHAKA)


def day_start(now):
    """Start of the Dhaka calendar day containing `now` (aware)."""
    m = local(now)
    return datetime(m.year, m.month, m.day, tzinfo=DHAKA)


# ===================================================================== caps
def _int(v, fb):
    try:
        return int(v)
    except (TypeError, ValueError):
        return fb


def server_caps(cfg_block=None):
    """The server max after the Owner-Admin pricing block (clamped to
    HARD_MAX; the block can only lower)."""
    b = cfg_block if isinstance(cfg_block, dict) else {}
    out = {}
    for k, dflt in DEFAULT_CAPS.items():
        v = _int(b.get("max_" + k), dflt)
        out[k] = max(MIN_CAPS[k], min(HARD_MAX[k], v))
    return out


def effective_caps(owner_caps, server_max):
    """Owner's chosen caps clamped into [MIN, server_max]. Missing = max."""
    o = owner_caps if isinstance(owner_caps, dict) else {}
    out = {}
    for k, mx in server_max.items():
        out[k] = max(MIN_CAPS[k], min(mx, _int(o.get(k), mx)))
    return out


def validate_owner_caps(owner_caps, server_max):
    """Problem codes for an owner edit: raising above the server max is
    refused (not silently clamped) so the owner sees why."""
    problems = []
    for k, v in (owner_caps or {}).items():
        if k not in server_max:
            continue
        n = _int(v, None)
        if n is None or n < MIN_CAPS[k]:
            problems.append("cap_too_low")
        elif n > server_max[k]:
            problems.append("cap_above_server_max")
    return list(dict.fromkeys(problems))


# ===================================================================== decide
def decide(*, opted_out, now, sent_customer_day, sent_customer_week,
           sent_business_day, caps, transactional=False, sent_all_day=None):
    """May ONE automated message go to this customer right now?
    reason ∈ ok | opted_out | quiet_hours | business_daily_cap |
    customer_daily_cap | customer_weekly_cap. retry_at = when it is worth
    trying again (None = never for this event)."""
    if opted_out:
        return Verdict(False, "opted_out", None)
    if in_quiet_hours(now):
        return Verdict(False, "quiet_hours", next_allowed_at(now))
    tomorrow = day_start(now) + timedelta(days=1, hours=9)
    if sent_business_day >= caps["business_daily"]:
        return Verdict(False, "business_daily_cap", tomorrow)
    if sent_customer_day >= caps["per_customer_day"]:
        return Verdict(False, "customer_daily_cap", tomorrow)
    # bizauto: EVERY business message to this customer today (retention +
    # tagada / CRM SMS ...) under one more cap, when the caller counted them
    if sent_all_day is not None and sent_all_day >= caps.get("all_per_customer_day", 10 ** 6):
        return Verdict(False, "customer_daily_cap", tomorrow)
    if not transactional and sent_customer_week >= caps["per_customer_week"]:
        return Verdict(False, "customer_weekly_cap", tomorrow)
    return Verdict(True, "ok", None)


# ===================================================================== STOP
_STOP_WORDS = ("stop", "স্টপ", "unsubscribe", "বন্ধ", "বন্ধ করুন")


def is_stop_text(text):
    """STOP in any form the business agent already understands (one source
    of truth: bizagent_g1.is_opt_out) plus the bare words above."""
    low = (text or "").strip().lower()
    if not low:
        return False
    if low in _STOP_WORDS:
        return True
    try:
        from . import bizagent_g1 as G1
        return G1.is_opt_out(low)
    except Exception:
        return False


def stop_footer(lang, channel, link=""):
    """The unsubscribe line every automated message carries. Never empty."""
    bn = lang != "en"
    if channel == "in_app":
        return ("আর মেসেজ না চাইলে \"বন্ধ করুন\" চাপুন।" if bn
                else "Tap \"Stop\" to get no more messages.")
    if channel == "sms":
        if link:
            return ("বন্ধ করতে: " + link) if bn else ("Stop: " + link)
        return "বন্ধ করতে STOP লিখুন" if bn else "Reply STOP to stop"
    return ("আর মেসেজ না চাইলে STOP লিখুন।" if bn
            else "Reply STOP for no more messages.")


# ===================================================================== META
def meta_plan(channel, within_24h, template=None, purpose=PURPOSE_MARKETING):
    """How (and whether) a message may go on a Meta channel.
    Returns (mode, reason): mode ∈ free_form | template | blocked.

      * inside the 24 h window → free-form text (any channel);
      * Messenger / Instagram outside it → blocked (no promotional message
        tags exist; we never use a tag to get around the window);
      * WhatsApp outside it → ONLY an APPROVED template, whose category fits
        the purpose (promotional content may not use a UTILITY template) and
        which carries a stop option."""
    if channel not in ("whatsapp", "messenger", "instagram"):
        return "free_form", "ok"
    if within_24h:
        return "free_form", "ok"
    if channel != "whatsapp":
        return "blocked", "outside_24h_window"
    t = template if isinstance(template, dict) else {}
    if not (t.get("name") or "").strip():
        return "blocked", "outside_24h_window_template_required"
    if not t.get("approved"):
        return "blocked", "template_not_approved"
    cat = (t.get("category") or "").lower()
    if cat not in (PURPOSE_MARKETING, PURPOSE_UTILITY):
        return "blocked", "bad_template_category"
    if purpose == PURPOSE_MARKETING and cat == PURPOSE_UTILITY:
        return "blocked", "promo_in_utility_template"
    if not t.get("has_stop"):
        return "blocked", "template_needs_stop_option"
    return "template", "ok"


# ===================================================================== DB helpers
SENT_STATES = ("sent", "delivered", "read")


def _thread_keys_opted_out(business_id, key):
    """The business AI agent's per-chat STOP (ChatThread.opted_out) counts
    too: an opt-out said in WhatsApp/Messenger stops every automation."""
    from ..models import ChatThread
    from .business_selling import normalize_phone
    if key.startswith("psid:"):
        return ChatThread.objects.filter(business_id=business_id, opted_out=True,
                                         external_user_id=key[5:]).exists()
    for p in (ChatThread.objects.filter(business_id=business_id, opted_out=True)
              .exclude(customer_phone="").values_list("customer_phone", flat=True)[:2000]):
        if normalize_phone(p) == key:
            return True
    return False


def is_opted_out(business_id, key):
    from ..models import BizOptOut
    if not key:
        return False
    if BizOptOut.objects.filter(business_id=business_id, key=key).exists():
        return True
    try:
        return _thread_keys_opted_out(business_id, key)
    except Exception:
        return False


def opted_out_keys(business_id):
    """Every opted-out key of one business as a set (one pass) — for a run
    over many customers; `gate(..., opted_out_set=...)` uses it."""
    from ..models import BizOptOut, ChatThread
    from .business_selling import normalize_phone
    keys = set(BizOptOut.objects.filter(business_id=business_id).values_list("key", flat=True))
    for phone, ext in ChatThread.objects.filter(business_id=business_id, opted_out=True).values_list(
            "customer_phone", "external_user_id")[:20000]:
        if phone:
            keys.add(normalize_phone(phone))
        if ext:
            keys.add("psid:" + ext)
    return keys


def record_opt_out(business_id, key, source="in_app"):
    """Idempotent; returns True when this call created the opt-out. Also
    marks the business agent's chats with this customer opted out so its own
    follow-ups stop as well."""
    from ..models import BizOptOut, ChatThread
    from .business_selling import normalize_phone
    if not key:
        return False
    _, created = BizOptOut.objects.get_or_create(
        business_id=business_id, key=key[:80], defaults={"source": source[:16]})
    try:
        ids = []
        for t in ChatThread.objects.filter(business_id=business_id, opted_out=False).only(
                "id", "customer_phone", "external_user_id")[:5000]:
            if (key.startswith("psid:") and t.external_user_id == key[5:]) or (
                    t.customer_phone and normalize_phone(t.customer_phone) == key):
                ids.append(t.id)
        if ids:
            ChatThread.objects.filter(id__in=ids).update(opted_out=True)
    except Exception:
        pass
    return created


def sent_counts(business_id, key, now):
    """(customer today, customer last 7 days, business today) — automated
    messages actually sent (blocked / failed ones never count)."""
    from ..models import RetentionSend
    ds = day_start(now)
    base = RetentionSend.objects.filter(business_id=business_id, status__in=SENT_STATES)
    cust = base.filter(audience_key=key)
    return (cust.filter(created_at__gte=ds).count(),
            cust.filter(created_at__gte=now - timedelta(days=7)).count(),
            base.filter(created_at__gte=ds).count())


def gate(business_id, key, *, now, caps, extra_day=0, extra_week=0,
         extra_business=0, transactional=False, opted_out_set=None):
    """DB-backed `decide` for one customer. `extra_*` lets another feature
    (booking) add its own sends to the counts until it shares the send log.
    `opted_out_set` = opted_out_keys(business_id) precomputed for a batch."""
    d, w, b = sent_counts(business_id, key, now)
    out = (key in opted_out_set) if opted_out_set is not None else is_opted_out(business_id, key)
    all_day = None
    if "all_per_customer_day" in caps:
        all_day = d + other_paths_sent_today(business_id, key, now) + extra_day
    return decide(opted_out=out, now=now,
                  sent_customer_day=d + extra_day, sent_customer_week=w + extra_week,
                  sent_business_day=b + extra_business, caps=caps,
                  transactional=transactional, sent_all_day=all_day)


# ===================================================================== bizauto
# One cap across EVERY path a business reaches its customer by (retention /
# crmauto sends + tagada / CRM Assisto SMS), and a signed STOP link that works
# for any of them (an SMS reply never reaches us: one-way sender IDs).
BUSINESS_SMS_PURPOSES = ("tagada", "crm")
DEFAULT_ALL_PER_CUSTOMER_DAY = 2


def all_cap(cfg_block=None):
    """Owner-Admin "retention" -> max_all_per_customer_day (1-3)."""
    b = cfg_block if isinstance(cfg_block, dict) else {}
    return max(1, min(3, _int(b.get("max_all_per_customer_day"), DEFAULT_ALL_PER_CUSTOMER_DAY)))


def _last10(key):
    digits = "".join(ch for ch in str(key or "") if ch.isdigit())
    return digits[-10:] if len(digits) >= 10 else ""


def other_paths_sent_today(business_id, key, now):
    """Business SMS (tagada / crm) actually sent to this customer today."""
    from ..models import SmsLog
    tail = _last10(key)
    if not tail or str(key).startswith("psid:"):
        return 0
    return SmsLog.objects.filter(business_id=business_id, purpose__in=BUSINESS_SMS_PURPOSES,
                                 status="sent", created_at__gte=day_start(now),
                                 phone__endswith=tail).count()


def all_paths_sent_today(business_id, key, now):
    """Every business→customer message sent today, all paths."""
    from ..models import RetentionSend
    tail = _last10(key)
    n = RetentionSend.objects.filter(business_id=business_id, status__in=SENT_STATES,
                                     created_at__gte=day_start(now))
    n = n.filter(audience_key=key).count()
    return n + (other_paths_sent_today(business_id, key, now) if tail else 0)


# ---- signed STOP link for any business message (no DB row needed) -----------
def _b36(n):
    chars, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    n = int(n)
    while True:
        n, r = divmod(n, 36)
        out = chars[r] + out
        if not n:
            return out


def _stop_sig(business_id, key):
    import hashlib
    import hmac
    from django.conf import settings
    k = (settings.SECRET_KEY + ":biz-stop").encode()
    return hmac.new(k, ("%s|%s" % (business_id, key)).encode(), hashlib.sha256).hexdigest()[:10]


def stop_token(business_id, key):
    """'k<biz b36>x<phone b36>-<sig>' — only for phone keys (01XXXXXXXXX)."""
    digits = "".join(ch for ch in str(key or "") if ch.isdigit())
    if len(digits) != 11 or not digits.startswith("0"):
        return ""
    return "k%sx%s-%s" % (_b36(business_id), _b36(int(digits)), _stop_sig(business_id, digits))


def parse_stop_token(token):
    """(business_id, key) for a valid token, else None."""
    import hmac
    t = str(token or "")
    if not t.startswith("k") or "-" not in t or "x" not in t:
        return None
    try:
        body, sig = t[1:].split("-", 1)
        b, p = body.split("x", 1)
        biz, num = int(b, 36), int(p, 36)
    except (ValueError, TypeError):
        return None
    key = "0%d" % num if num < 10 ** 10 else ""
    if len(key) != 11 or not hmac.compare_digest(sig, _stop_sig(biz, key)):
        return None
    return biz, key


def stop_link(business_id, key):
    """Absolute stop URL (served by retention/u/<token>), '' when unknown."""
    from django.conf import settings
    tok = stop_token(business_id, key)
    base = (getattr(settings, "ASSISTO_BASE_URL", "") or "").rstrip("/")
    return "%s/api/v1/retention/u/%s" % (base, tok) if (tok and base) else ""
