"""
booking.py — BOOKING BOT (big-week item I): PURE rules. No Django, no DB, no
network, no clock (callers pass `now`, timezone-aware).

What lives here
  * validation of the business' setup (weekly hours, days off, services,
    capacity, policies) — every number bounded, nothing unlimited;
  * the free-slot engine: candidate starts on the business' grid inside its
    opening hours, minus days off, minimum notice, the booking horizon and
    the existing bookings per resource (staff member or shared seats);
  * the 5-minute lock granules a booking holds (the DB turns them into
    UNIQUE rows, which is what makes double booking impossible);
  * the booking lifecycle (who may move a booking to which state, the
    customer's cancel / reschedule window);
  * reminder timing: 24 h + 2 h before, max per booking, quiet hours
    22:00-08:00 Asia/Dhaka, STOP honoured by the caller;
  * the chat helpers the AI agent uses (does this message ask for a booking,
    which offered option did the customer pick, which day did they mean) and
    the bot's bilingual lines. The bot only ever lists slots this engine
    computed from the business' real calendar — it never invents a time.

All times are Asia/Dhaka (UTC+6, no DST).
"""
import re
from datetime import date, datetime, time, timedelta, timezone as _tz

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo("Asia/Dhaka")
except Exception:  # pragma: no cover - tzdata missing
    TZ = _tz(timedelta(hours=6))

GRANULE_MIN = 5
QUIET_START = 22          # 22:00
QUIET_END = 8             # 08:00
MAX_INTERVALS_PER_DAY = 3
MAX_SERVICES = 30
MAX_STAFF = 20
MAX_DAYS_OFF = 120
MAX_SLOTS_SHOWN = 60
BOT_OPTIONS = 5           # slots the chat bot offers at once

BOUNDS = {
    "capacity": (1, 20),
    "step_min": (5, 120),
    "min_notice_min": (0, 7 * 24 * 60),
    "max_days_ahead": (1, 90),
    "cancel_hours": (0, 72),
    "max_pending_per_phone": (1, 5),
}
DEFAULTS = {"capacity": 1, "step_min": 30, "min_notice_min": 60, "max_days_ahead": 30,
            "cancel_hours": 2, "max_pending_per_phone": 2}

STATUSES = ("requested", "confirmed", "done", "no_show", "cancelled")
ACTIVE = ("requested", "confirmed")
# who may move a booking from -> to
_BIZ_MOVES = {
    "requested": ("confirmed", "cancelled"),
    "confirmed": ("done", "no_show", "cancelled"),
}
_CUSTOMER_MOVES = {"requested": ("cancelled",), "confirmed": ("cancelled",)}

REMINDERS = (("24h", 24 * 60), ("2h", 120))
MAX_REMINDERS = 2

_BN_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")
_HHMM = re.compile(r"^([01]?\d|2[0-3]):([0-5]\d)$")
_SLUG = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$")


def pick(lang, bn, en):
    return en if lang == "en" else bn


def bn_digits(s):
    return str(s).translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))


def num(lang, v):
    return bn_digits(v) if lang == "bn" else str(v)


def _int(v, fb):
    try:
        return int(str(v).translate(_BN_DIGITS).strip())
    except (TypeError, ValueError):
        return fb


def local(dt):
    return dt.astimezone(TZ)


# ======================================================================= setup
def parse_hhmm(s):
    m = _HHMM.match(str(s or "").translate(_BN_DIGITS).strip())
    if not m:
        return None
    return int(m.group(1)) * 60 + int(m.group(2))


def fmt_hhmm(minutes):
    return "%02d:%02d" % (minutes // 60, minutes % 60)


def clean_hours(raw):
    """{"0".."6": [["HH:MM","HH:MM"], ...]} (Mon=0) -> (clean, problems).
    Each interval must be start < end, same day, max 3 per day, no overlap."""
    out, problems = {}, []
    raw = raw if isinstance(raw, dict) else {}
    for d in range(7):
        ivs = raw.get(str(d)) or raw.get(d) or []
        if not isinstance(ivs, list):
            problems.append("hours_%d" % d)
            continue
        got = []
        for iv in ivs[:MAX_INTERVALS_PER_DAY + 1]:
            if not isinstance(iv, (list, tuple)) or len(iv) != 2:
                problems.append("hours_%d" % d)
                continue
            a, b = parse_hhmm(iv[0]), parse_hhmm(iv[1])
            if a is None or b is None or a >= b:
                problems.append("hours_%d" % d)
                continue
            got.append((a, b))
        if len(got) > MAX_INTERVALS_PER_DAY:
            problems.append("hours_%d" % d)
            got = got[:MAX_INTERVALS_PER_DAY]
        got.sort()
        for i in range(1, len(got)):
            if got[i][0] < got[i - 1][1]:
                problems.append("hours_%d" % d)
        if got:
            out[str(d)] = [[fmt_hhmm(a), fmt_hhmm(b)] for a, b in got]
    return out, sorted(set(problems))


def clean_days_off(raw, today=None):
    out = []
    for s in (raw if isinstance(raw, list) else [])[:MAX_DAYS_OFF * 2]:
        try:
            d = date.fromisoformat(str(s)[:10])
        except ValueError:
            continue
        if today and d < today:
            continue                     # past days off are dropped
        if d.isoformat() not in out:
            out.append(d.isoformat())
    return sorted(out)[:MAX_DAYS_OFF]


def clean_settings(raw, base=None):
    """Bounded policy numbers + booleans. Pure."""
    base = dict(DEFAULTS, **(base or {}))
    raw = raw if isinstance(raw, dict) else {}
    out = {}
    for k, (lo, hi) in BOUNDS.items():
        out[k] = max(lo, min(hi, _int(raw.get(k, base.get(k)), base[k])))
    return out


def clean_slug(s):
    s = re.sub(r"[^a-z0-9-]+", "-", str(s or "").lower()).strip("-")
    s = re.sub(r"-{2,}", "-", s)[:40].strip("-")
    return s if _SLUG.match(s or "") else ""


def clean_service(raw):
    """-> (clean, problems)."""
    raw = raw if isinstance(raw, dict) else {}
    problems = []
    name = str(raw.get("name") or "").strip()[:80]
    if not name:
        problems.append("name")
    dur = _int(raw.get("duration_min"), 30)
    if not 5 <= dur <= 480 or dur % GRANULE_MIN:
        problems.append("duration_min")
    buf = _int(raw.get("buffer_min"), 0)
    if not 0 <= buf <= 120 or buf % GRANULE_MIN:
        problems.append("buffer_min")
    price = _int(raw.get("price_bdt"), 0)
    if not 0 <= price <= 1_000_000:
        problems.append("price_bdt")
    staff = []
    for x in (raw.get("staff_ids") or [])[:MAX_STAFF]:
        i = _int(x, 0)
        if i > 0 and i not in staff:
            staff.append(i)
    return ({"name": name, "duration_min": max(5, min(480, dur)),
             "buffer_min": max(0, min(120, buf)), "price_bdt": max(0, price),
             "staff_ids": staff, "active": raw.get("active", True) is not False},
            problems)


# ======================================================================= slots
def granule_floor(dt):
    dt = dt.replace(second=0, microsecond=0)
    return dt - timedelta(minutes=dt.minute % GRANULE_MIN)


def granules(start, block_end):
    """Every 5-minute granule start in [start, block_end)."""
    out = []
    t = granule_floor(start)
    while t < block_end:
        out.append(t)
        t += timedelta(minutes=GRANULE_MIN)
    return out


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


def day_open_intervals(day, weekly_hours, days_off):
    """[(start_dt, end_dt)] local-aware for `day` (a date)."""
    if day.isoformat() in (days_off or []):
        return []
    out = []
    for a, b in (weekly_hours or {}).get(str(day.weekday()), []) or []:
        sa, sb = parse_hhmm(a), parse_hhmm(b)
        if sa is None or sb is None or sa >= sb:
            continue
        base = datetime.combine(day, time(0, 0), tzinfo=TZ)
        out.append((base + timedelta(minutes=sa), base + timedelta(minutes=sb)))
    return out


def bookable_day(day, now, cfg):
    today = local(now).date()
    return today <= day <= today + timedelta(days=cfg["max_days_ahead"])


def free_slots(day, now, cfg, service, resources, busy, limit=MAX_SLOTS_SHOWN):
    """Free start times for `service` on `day`.

    cfg: {weekly_hours, days_off, step_min, min_notice_min, max_days_ahead}
    service: {duration_min, buffer_min}
    resources: [(resource_id, seats)] — staff members (seats=1) or [(0, capacity)]
    busy: {resource_id: [(start, block_end), ...]} of ACTIVE bookings.
    Returns [{"start": dt, "end": dt, "resources": [ids with a free seat]}]."""
    if not resources or not bookable_day(day, now, cfg):
        return []
    dur = timedelta(minutes=int(service["duration_min"]))
    blk = dur + timedelta(minutes=int(service.get("buffer_min") or 0))
    earliest = now + timedelta(minutes=int(cfg.get("min_notice_min") or 0))
    step = timedelta(minutes=max(GRANULE_MIN, int(cfg.get("step_min") or 30)))
    out = []
    for o0, o1 in day_open_intervals(day, cfg.get("weekly_hours"), cfg.get("days_off")):
        t = o0
        while t + dur <= o1:
            # the buffer may run past closing; the service itself may not
            if t >= earliest:
                free = []
                for rid, seats in resources:
                    used = sum(1 for b0, b1 in busy.get(rid, ()) if overlaps(t, t + blk, b0, b1))
                    if used < seats:
                        free.append(rid)
                if free:
                    out.append({"start": t, "end": t + dur, "resources": free})
                    if len(out) >= limit:
                        return out
            t += step
    return out


def slot_is_on_grid(start, day_cfg_intervals, step_min):
    for o0, o1 in day_cfg_intervals:
        if o0 <= start < o1:
            return ((start - o0).total_seconds() / 60) % max(GRANULE_MIN, step_min) == 0
    return False


# ======================================================================= lifecycle
def can_move(old, new, actor):
    """actor: business | customer | system."""
    if actor == "business":
        return new in _BIZ_MOVES.get(old, ())
    if actor == "customer":
        return new in _CUSTOMER_MOVES.get(old, ())
    if actor == "system":
        return old in ACTIVE and new in ("cancelled",)
    return False


def customer_window_open(start, now, cancel_hours):
    """Customers may cancel / reschedule until `cancel_hours` before start."""
    return now <= start - timedelta(hours=int(cancel_hours or 0))


def status_label(lang, s):
    return {
        "requested": pick(lang, "অনুরোধ (নিশ্চিত হয়নি)", "Requested (not confirmed)"),
        "confirmed": pick(lang, "নিশ্চিত", "Confirmed"),
        "done": pick(lang, "সম্পন্ন", "Done"),
        "no_show": pick(lang, "আসেননি", "No-show"),
        "cancelled": pick(lang, "বাতিল", "Cancelled"),
    }.get(s, s)


# ======================================================================= reminders
def in_quiet_hours(dt):
    h = local(dt).hour
    return h >= QUIET_START or h < QUIET_END


def due_reminder(start, created_at, now, sent, max_reminders=MAX_REMINDERS):
    """Which reminder (if any) may go out NOW. sent = kinds already sent.
      * never during quiet hours (22:00-08:00) — it waits for 08:00;
      * the 24 h one only if the booking was made > 24 h ahead, and not once
        the 2 h one is due; the 2 h one only if booked > 2 h ahead;
      * never after the start; never more than `max_reminders` in all."""
    if now >= start or len(sent) >= max_reminders or in_quiet_hours(now):
        return None
    lead = start - created_at
    two = REMINDERS[1]
    if "2h" not in sent and lead > timedelta(minutes=two[1]) and \
            now >= start - timedelta(minutes=two[1]):
        return "2h"
    day = REMINDERS[0]
    if "24h" not in sent and lead > timedelta(minutes=day[1]) and \
            start - timedelta(minutes=day[1]) <= now < start - timedelta(minutes=two[1]):
        return "24h"
    return None


def when_text(lang, start):
    s = local(start)
    months_bn = ("জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই",
                 "আগস্ট", "সেপ্টেম্বর", "অক্টোবর", "নভেম্বর", "ডিসেম্বর")
    days_bn = ("সোমবার", "মঙ্গলবার", "বুধবার", "বৃহস্পতিবার", "শুক্রবার", "শনিবার", "রবিবার")
    h12 = s.hour % 12 or 12
    if lang == "en":
        return "%s %d %s, %d:%02d %s" % (s.strftime("%a"), s.day, s.strftime("%b"),
                                         h12, s.minute, "AM" if s.hour < 12 else "PM")
    part = ("ভোর" if s.hour < 6 else "সকাল" if s.hour < 12 else "দুপুর" if s.hour < 15
            else "বিকাল" if s.hour < 18 else "সন্ধ্যা" if s.hour < 20 else "রাত")
    return "%s, %s %s, %s %s:%s" % (days_bn[s.weekday()], bn_digits(s.day),
                                     months_bn[s.month - 1], part, bn_digits(h12),
                                     bn_digits("%02d" % s.minute))


def day_label(lang, day):
    """'Mon 27 Oct' / 'সোমবার, ২৭ অক্টোবর' for a date."""
    base = datetime.combine(day, time(12, 0), tzinfo=TZ)
    return ", ".join(when_text(lang, base).split(", ")[:2]) if lang == "bn" else \
        when_text(lang, base).split(",")[0]


def time_text(lang, start):
    s = local(start)
    h12 = s.hour % 12 or 12
    if lang == "en":
        return "%d:%02d %s" % (h12, s.minute, "AM" if s.hour < 12 else "PM")
    return when_text("bn", start).split(", ")[-1]


def reminder_text(lang, kind, biz_name, service, start, now=None):
    w = when_text(lang, start)
    same_day = now is not None and local(now).date() == local(start).date()
    if kind == "2h" or same_day:
        return pick(lang,
                    "মনে করিয়ে দিচ্ছি: %s-এ আপনার \"%s\" বুকিং আজ %s। আসতে না পারলে বাতিল করুন। রিমাইন্ডার বন্ধ করতে STOP লিখুন।" % (biz_name, service, time_text("bn", start)),
                    "Reminder: your \"%s\" booking at %s is today at %s. Can't come? Please cancel. Reply STOP to stop reminders." % (service, biz_name, time_text("en", start)))
    return pick(lang,
                "মনে করিয়ে দিচ্ছি: %s-এ আপনার \"%s\" বুকিং আগামীকাল — %s। রিমাইন্ডার বন্ধ করতে STOP লিখুন।" % (biz_name, service, w),
                "Reminder: your \"%s\" booking at %s is tomorrow — %s. Reply STOP to stop reminders." % (service, biz_name, w))


# ======================================================================= chat bot
_BOOK_WORDS = ("book", "booking", "appointment", "appoinment", "apointment", "slot",
               "schedule", "reserve", "serial", "seriyal", "সিরিয়াল", "সিরিয়াল", "বুক",
               "বুকিং", "অ্যাপয়েন্টমেন্ট", "এপয়েন্টমেন্ট", "অ্যাপয়েন্টমেন্ট", "সময় নিতে",
               "সময় চাই", "time nite", "somoy nite", "somoy chai", "সিট")
_STOP_WORDS = ("stop", "unsubscribe", "বন্ধ", "স্টপ")
_CANCEL_WORDS = ("cancel", "batil", "বাতিল")


def _norm(text):
    return " " + re.sub(r"\s+", " ", (text or "").lower().translate(_BN_DIGITS)).strip() + " "


def wants_booking(text):
    t = _norm(text)
    return any(w in t for w in _BOOK_WORDS)


def is_stop(text):
    t = _norm(text).strip()
    return t in _STOP_WORDS


def is_cancel(text):
    t = _norm(text)
    return any(w in t for w in _CANCEL_WORDS)


def pick_option(text, n):
    """The 1-based option number a customer typed ("2", "২", "option 2"), or
    None. Only a short message that is just a number counts."""
    t = _norm(text).strip()
    m = re.fullmatch(r"(?:no\.?|option|#|নং)?\s*(\d{1,2})\s*(?:no|নং|নম্বর|ta|টা)?", t)
    if not m:
        return None
    i = int(m.group(1))
    return i if 1 <= i <= n else None


_DAYS_EN = (("mon", "monday"), ("tue", "tues", "tuesday"), ("wed", "wednesday"),
            ("thu", "thur", "thurs", "thursday"), ("fri", "friday"),
            ("sat", "saturday"), ("sun", "sunday"))
_DAYS_BN = ("সোম", "মঙ্গল", "বুধ", "বৃহস্পতি", "শুক্র", "শনি", "রবি")


def parse_day(text, today):
    """today / tomorrow / weekday name / dd-mm in the message -> a date, else None."""
    t = _norm(text)
    words = set(re.findall(r"[\wঀ-৿]+", t))
    if words & {"today", "aj", "aaj", "আজ", "আজকে"}:
        return today
    if words & {"tomorrow", "kal", "kaal", "agamikal", "আগামীকাল", "কাল", "কালকে"}:
        return today + timedelta(days=1)
    if words & {"porshu", "পরশু"} or "day after" in t:
        return today + timedelta(days=2)
    m = re.search(r"\b(\d{1,2})[/\-.](\d{1,2})\b", t)
    if m:
        d, mo = int(m.group(1)), int(m.group(2))
        for y in (today.year, today.year + 1):
            try:
                cand = date(y, mo, d)
            except ValueError:
                return None
            if cand >= today:
                return cand
    for i, (en, bn) in enumerate(zip(_DAYS_EN, _DAYS_BN)):
        if words & set(en) or bn in t:
            ahead = (i - today.weekday()) % 7
            return today + timedelta(days=ahead)
    return None


def bot_pick_service(lang, services):
    lines = [pick(lang, "কোন সেবার জন্য বুক করবেন? নম্বর লিখুন:",
                  "Which service would you like to book? Reply with the number:")]
    for i, s in enumerate(services, 1):
        p = (" — ৳%s" % num(lang, s["price_bdt"])) if s.get("price_bdt") else ""
        lines.append("%s. %s (%s %s)%s" % (num(lang, i), s["name"], num(lang, s["duration_min"]),
                                            pick(lang, "মিনিট", "min"), p))
    return "\n".join(lines)


def bot_offer_slots(lang, service_name, slots):
    lines = [pick(lang, "\"%s\"-এর জন্য এই সময়গুলো খালি আছে — নম্বর লিখুন:" % service_name,
                  "These times are free for \"%s\" — reply with the number:" % service_name)]
    for i, s in enumerate(slots, 1):
        lines.append("%s. %s" % (num(lang, i), when_text(lang, s["start"])))
    lines.append(pick(lang, "অন্য দিন চাইলে দিনটি লিখুন (যেমন: আগামীকাল, শুক্রবার, ২৫/১১)।",
                      "For another day, type the day (e.g. tomorrow, Friday, 25/11)."))
    return "\n".join(lines)


def bot_no_slots(lang, service_name):
    return pick(lang,
                "দুঃখিত, সামনের কয়েক দিনে \"%s\"-এর কোনো খালি সময় নেই। অন্য দিন লিখুন, অথবা আমরা মালিককে জানিয়ে দিচ্ছি।" % service_name,
                "Sorry, there is no free time for \"%s\" in the next few days. Type another day, or we'll let the owner know." % service_name)


def bot_ask_name(lang):
    return pick(lang, "বুকিংটি কার নামে হবে? আপনার নাম লিখুন।", "Whose name is the booking under? Please type your name.")


def bot_ask_phone(lang):
    return pick(lang, "আপনার মোবাইল নম্বর লিখুন (01XXXXXXXXX)।", "Please type your mobile number (01XXXXXXXXX).")


def bot_confirm_q(lang, service_name, start, name):
    return pick(lang,
                "নিশ্চিত করবেন? \"%s\" — %s, নাম: %s। হ্যাঁ লিখলে বুক হবে, না লিখলে বাতিল।" % (service_name, when_text("bn", start), name),
                "Confirm? \"%s\" — %s, name: %s. Reply yes to book, no to stop." % (service_name, when_text("en", start), name))


def bot_booked(lang, service_name, start, confirmed):
    if confirmed:
        return pick(lang,
                    "বুকিং নিশ্চিত হয়েছে ✅ \"%s\" — %s। আগের দিন ও ২ ঘণ্টা আগে মনে করিয়ে দেব। বাতিল করতে \"বাতিল\" লিখুন।" % (service_name, when_text("bn", start)),
                    "Booked ✅ \"%s\" — %s. We'll remind you the day before and 2 hours before. To cancel, type \"cancel\"." % (service_name, when_text("en", start)))
    return pick(lang,
                "অনুরোধ পাঠানো হয়েছে: \"%s\" — %s। ব্যবসা নিশ্চিত করলে জানিয়ে দেব।" % (service_name, when_text("bn", start)),
                "Request sent: \"%s\" — %s. We'll tell you when the business confirms." % (service_name, when_text("en", start)))


def bot_slot_gone(lang):
    return pick(lang, "দুঃখিত, এই সময়টি এইমাত্র অন্য কেউ নিয়েছেন। নতুন খালি সময়গুলো দেখুন:",
                "Sorry, someone just took that time. Here are the free times now:")


def bot_refused(lang, code):
    return {
        "blocked": pick(lang, "দুঃখিত, এই নম্বর থেকে অনলাইনে বুকিং নেওয়া যাচ্ছে না। সরাসরি ব্যবসার সাথে যোগাযোগ করুন।",
                        "Sorry, online booking isn't available for this number. Please contact the business directly."),
        "too_many_pending": pick(lang, "আপনার আগের বুকিং এখনো বাকি আছে। নতুন বুকিংয়ের আগে সেটি শেষ বা বাতিল করুন।",
                                 "You already have bookings waiting. Please finish or cancel one before booking again."),
        "daily_cap": pick(lang, "আজকের অনলাইন বুকিংয়ের সীমা পূর্ণ হয়েছে। মালিক শিগগির আপনার সাথে যোগাযোগ করবেন।",
                          "Today's online booking limit is reached. The owner will get back to you soon."),
    }.get(code, pick(lang, "বুকিং করা যায়নি। মালিককে জানানো হয়েছে, শিগগির উত্তর পাবেন।",
                     "Could not book. The owner has been told and will reply soon."))


def bot_cancelled(lang):
    return pick(lang, "ঠিক আছে, বুকিং করা হয়নি।", "Okay, nothing was booked.")


def bot_booking_cancelled(lang, service_name, start):
    return pick(lang, "আপনার \"%s\" বুকিং (%s) বাতিল করা হয়েছে।" % (service_name, when_text("bn", start)),
                "Your \"%s\" booking (%s) is cancelled." % (service_name, when_text("en", start)))


def bot_stopped(lang):
    return pick(lang, "ঠিক আছে, আর কোনো রিমাইন্ডার পাঠানো হবে না।", "Okay, no more reminders will be sent.")


def status_message(lang, status, service_name, start, biz_name):
    w = when_text(lang, start)
    if status == "confirmed":
        return pick(lang, "%s আপনার \"%s\" বুকিং নিশ্চিত করেছে — %s।" % (biz_name, service_name, w),
                    "%s confirmed your \"%s\" booking — %s." % (biz_name, service_name, w))
    if status == "cancelled":
        return pick(lang, "%s আপনার \"%s\" বুকিং (%s) বাতিল করেছে।" % (biz_name, service_name, w),
                    "%s cancelled your \"%s\" booking (%s)." % (biz_name, service_name, w))
    if status == "rescheduled":
        return pick(lang, "%s আপনার \"%s\" বুকিংয়ের সময় বদলেছে — নতুন সময় %s।" % (biz_name, service_name, w),
                    "%s moved your \"%s\" booking — new time %s." % (biz_name, service_name, w))
    return ""
