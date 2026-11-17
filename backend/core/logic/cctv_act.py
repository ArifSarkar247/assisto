"""
cctv_act.py — CCTV GUARD V3 parts D, E, F, G (owner order 9 Nov 15:15):
the PURE rules (no DB, no network). Glue: core/cctv_act_views.py.

D  learn_*      "Wrong alert" learning per SITE PATTERN (camera + type +
                kind + time band). Lowers that pattern's confidence and, after
                repeated wrong answers, keeps it quiet (saved, no push). Safety
                kinds (fire, smoke, fall, fight, weapon) and owner-away mode
                are NEVER quieted.
   pick_thana   the nearest police station from REAL map rows (Assisto
                places / Google / OpenStreetMap) — never an invented number.
F  sign/verify  the POS webhook signature: HMAC-SHA256 over
                "v1:<timestamp>:<raw body>", per-shop key, a 5-minute clock
                window, the event id is unique per shop (replay = duplicate).
   normalize_pos / parse_csv   one POS event / a CSV export -> rows.
   sales_match  "cash drawer opened with no sale" and "possible cash to
                pocket after a sale" — REVIEW-ONLY items, never an accusation,
                never a person's name.
E  closing_report   the day at closing time (hours, people counted with no
                identity, peak hours, empty-counter minutes, events, vehicles
                in/out, DVR health, table occupancy) — Bangla first.
G  parse_question / answer_lines   "who went to the cash between 2 and 3 pm"
                -> a structured filter over stored events (zones, colours,
                kinds, times). The answer text is built from the DATA, so the
                facts are always right; AI only helps to read the question.
"""
import csv
import hashlib
import hmac
import io
import json
import math
import re
from datetime import datetime, timedelta

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_EN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def bn(v):
    return str(v).translate(_BN)


def to_en_digits(s):
    return str(s or "").translate(_EN)


def pick(lang, b, e):
    return e if lang == "en" else b


def _d(v, lang):
    return str(v) if lang == "en" else bn(v)


# =================================================================== D: learn
LEARN_KEY = "_learn"
LEARN_MAX_KEYS = 200
LEARN_KEEP_DAYS = 60
LEARN_MIN_WRONG = 2          # one wrong answer changes nothing
LEARN_STEP = 0.12
LEARN_FLOOR = 0.40
QUIET_AT_NET = 4             # net wrong answers -> saved without a push
NEVER_QUIET_KINDS = ("fire", "smoke", "fall", "fight", "weapon", "knife", "gun",
                     "sos", "violence")
NEVER_QUIET_TYPES = ("camera_health",)
WRONG_REASONS = ("animal", "shadow", "staff", "family", "vehicle", "weather",
                 "other")


def time_band(hour):
    h = int(hour) % 24
    if h >= 22 or h < 6:
        return "night"
    if h < 12:
        return "morning"
    if h < 18:
        return "day"
    return "evening"


def pattern_key(etype, cam_id, kind, hour):
    return "%s|c%s|%s|%s" % (etype or "?", cam_id or 0, (kind or "-")[:16],
                             time_band(hour))


def learn_record(learn, key, verdict, ts, reason=""):
    """Mutates and returns the site's learn dict: {key: {w, c, at, r}}."""
    learn = learn if isinstance(learn, dict) else {}
    row = dict(learn.get(key) or {})
    if verdict == "wrong":
        row["w"] = int(row.get("w", 0) or 0) + 1
        if reason in WRONG_REASONS:
            rs = dict(row.get("r") or {})
            rs[reason] = int(rs.get(reason, 0) or 0) + 1
            row["r"] = rs
    elif verdict == "correct":
        row["c"] = int(row.get("c", 0) or 0) + 1
    elif verdict == "undo_wrong":
        row["w"] = max(0, int(row.get("w", 0) or 0) - 1)
    row["at"] = float(ts)
    learn[key] = row
    if len(learn) > LEARN_MAX_KEYS:
        for k, _ in sorted(learn.items(), key=lambda kv: kv[1].get("at", 0))[
                :len(learn) - LEARN_MAX_KEYS]:
            learn.pop(k, None)
    return learn


def net_wrong(row, now_ts):
    if not row or now_ts - float(row.get("at", 0) or 0) > LEARN_KEEP_DAYS * 86400:
        return 0
    # a "correct" answer weighs double: real events must never be lost
    return max(0, int(row.get("w", 0) or 0) - 2 * int(row.get("c", 0) or 0))


def learn_factor(row, now_ts):
    n = net_wrong(row, now_ts)
    if n < LEARN_MIN_WRONG:
        return 1.0
    return max(LEARN_FLOOR, round(1.0 - LEARN_STEP * (n - 1), 2))


def never_quiet(etype, kind, away):
    return bool(away) or etype in NEVER_QUIET_TYPES or (kind or "") in NEVER_QUIET_KINDS


def learn_apply(row, now_ts, confidence, etype, kind, away):
    """-> (confidence, quiet, factor). Safety never goes quiet; the
    confidence is only ever LOWERED, never raised."""
    f = learn_factor(row, now_ts)
    conf = round(float(confidence or 0.0) * f, 3)
    quiet = (net_wrong(row, now_ts) >= QUIET_AT_NET and
             not never_quiet(etype, kind, away))
    return conf, quiet, f


def learn_summary(row, now_ts, lang):
    # gap-cctv: nothing answered yet for this pattern — invite, never thank
    if not row or not (int(row.get("w", 0) or 0) or int(row.get("c", 0) or 0)):
        return pick(lang, "ভুল সতর্কতা হলে জানান — Assisto এই দোকানের জন্য শিখবে।",
                    "Tell us if this alert was wrong — Assisto learns for this shop.")
    n = net_wrong(row, now_ts)
    f = learn_factor(row, now_ts)
    if n >= QUIET_AT_NET:
        return pick(lang, "এই ধরনের সতর্কতা এখন চুপচাপ জমা থাকবে (ফোনে বাজবে না)। "
                          "তালিকায় সবই দেখতে পাবেন।",
                    "Alerts like this are now saved quietly (no phone ring). "
                    "You still see them all in the list.")
    if f < 1.0:
        return pick(lang, "বুঝেছি। এই ক্যামেরার এই সময়ের এমন সতর্কতা এখন কম নিশ্চিত ধরা হবে।",
                    "Got it. Alerts like this from this camera at this time "
                    "will now count as less certain.")
    return pick(lang, "ধন্যবাদ — আরও কয়েকবার বললে Assisto এই ধরনের ভুল কমাবে।",
                "Thanks — after a few more answers like this Assisto will "
                "send fewer of these.")


# =================================================================== D: thana
_THANA_WORDS = re.compile(r"(থানা|thana|police station|model thana|পুলিশ স্টেশন)", re.I)
_NOT_THANA = re.compile(r"(ফাঁড়ি|ফাড়ি|outpost|camp|box|tourist|traffic|ট্রাফিক|"
                        r"highway|হাইওয়ে|training|lines|barrack|headquarter)", re.I)


def haversine_km(a, b, c, d):
    r = 6371.0
    p1, p2 = math.radians(a), math.radians(c)
    dp, dl = math.radians(c - a), math.radians(d - b)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def clean_bd_phone(raw):
    """A dialable Bangladesh number from a map 'phone' tag, or ''. Takes the
    FIRST number when the tag lists several (';' or ',')."""
    if not raw:
        return ""
    first = re.split(r"[;,/]", to_en_digits(raw))[0]
    digits = re.sub(r"[^\d+]", "", first)
    if digits.startswith("+880"):
        digits = "0" + digits[4:]
    elif digits.startswith("880") and len(digits) >= 12:
        digits = "0" + digits[3:]
    digits = digits.replace("+", "")
    if re.fullmatch(r"01[3-9]\d{8}", digits) or re.fullmatch(r"0\d{6,10}", digits):
        return digits
    return ""


def pick_thana(rows, lat, lon, limit=3):
    """The nearest police stations from map rows [{name, lat, lng|lon,
    phone}] -> [{name, phone, distance_km, is_thana}], thanas first. Rows
    without coordinates are skipped. Never invents a number."""
    out = []
    for r in rows or []:
        if not isinstance(r, dict):
            continue
        try:
            la = float(r.get("lat"))
            lo = float(r.get("lng", r.get("lon")))
        except (TypeError, ValueError):
            continue
        name = str(r.get("name") or "").strip()
        if not name or _NOT_THANA.search(name):
            continue
        out.append({"name": name[:80],
                    "phone": clean_bd_phone(r.get("phone")),
                    "distance_km": round(haversine_km(lat, lon, la, lo), 1),
                    "is_thana": bool(_THANA_WORDS.search(name)),
                    "lat": round(la, 5), "lng": round(lo, 5)})
    out.sort(key=lambda x: (not x["is_thana"] and x["distance_km"] > 2.0,
                            x["distance_km"]))
    return out[:limit]


def valid_latlon(lat, lon):
    try:
        la, lo = float(lat), float(lon)
    except (TypeError, ValueError):
        return None
    # Bangladesh and a margin around it (a shop elsewhere still works with 999)
    if not (-90 <= la <= 90 and -180 <= lo <= 180):
        return None
    return round(la, 5), round(lo, 5)


# =================================================================== F: webhook
SIG_VERSION = "v1"
MAX_SKEW_S = 300
KEY_GRACE_S = 24 * 3600      # the old key still works for a day after rotation
MAX_BODY = 64 * 1024
MAX_BATCH = 100
POS_TYPES = {"sale": "sale", "refund": "refund", "void": "void",
             "discount": "discount", "cash_drawer": "drawer_open",
             "drawer_open": "drawer_open", "no_sale": "drawer_open"}
PAY_METHODS = ("cash", "card", "bkash", "nagad", "rocket", "upay", "bank", "due",
               "other")
_ID_RX = re.compile(r"^[A-Za-z0-9_.:\-]{1,64}$")
_KID_RX = re.compile(r"^ak_(\d{1,10})_([A-Za-z0-9]{6,16})$")


def canonical(ts, body):
    if isinstance(body, str):
        body = body.encode("utf-8")
    return b"%s:%s:%s" % (SIG_VERSION.encode(), str(ts).encode(), body)


def sign(key, ts, body):
    return hmac.new(key.encode("utf-8"), canonical(ts, body), hashlib.sha256).hexdigest()


def signature_header(key, ts, body):
    return "%s=%s" % (SIG_VERSION, sign(key, ts, body))


def kid_site(kid):
    m = _KID_RX.match(str(kid or ""))
    return int(m.group(1)) if m else None


def verify(keys, ts_header, sig_header, body, now_ts):
    """keys: the shop's usable secrets (current + the rotated one in its
    grace day). -> (ok, code). Codes: no_signature, bad_timestamp,
    stale, bad_signature."""
    if not sig_header:
        return False, "no_signature"
    try:
        ts = int(str(ts_header or "").strip())
    except ValueError:
        return False, "bad_timestamp"
    if abs(now_ts - ts) > MAX_SKEW_S:
        return False, "stale"
    given = []
    for part in str(sig_header).split(","):
        v, _, h = part.strip().partition("=")
        if v == SIG_VERSION and re.fullmatch(r"[0-9a-fA-F]{64}", h or ""):
            given.append(h.lower())
    if not given:
        return False, "bad_signature"
    for k in keys:
        if not k:
            continue
        want = sign(k, ts, body)
        if any(hmac.compare_digest(want, g) for g in given):
            return True, ""
    return False, "bad_signature"


def _money_poisha(v):
    """'1,250.50' / 1250.5 / '১২৫০' -> 125050 poisha; None when not a number."""
    if v is None or v == "":
        return 0
    s = to_en_digits(v).replace(",", "").strip()
    if not re.fullmatch(r"-?\d{1,12}(\.\d{1,2})?", s):
        return None
    whole, _, frac = s.lstrip("-").partition(".")
    p = int(whole) * 100 + int((frac + "00")[:2])
    return -p if s.startswith("-") else p


def parse_when(v, now):
    """ISO 8601 (with offset), epoch seconds, 'YYYY-MM-DD HH:MM[:SS]' or
    'DD/MM/YYYY HH:MM' (Dhaka time) -> aware datetime, or None."""
    from datetime import timezone as dtz
    if v is None or v == "":
        return now
    s = to_en_digits(v).strip()
    if re.fullmatch(r"\d{9,11}(\.\d+)?", s):
        try:
            return datetime.fromtimestamp(float(s), tz=dtz.utc)
        except (OverflowError, ValueError, OSError):
            return None
    dhaka = dtz(timedelta(hours=6))
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M%z"):
        try:
            return datetime.strptime(s.replace("Z", "+0000"), fmt)
        except ValueError:
            pass
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M",
                "%d/%m/%Y %H:%M:%S", "%d/%m/%Y %H:%M", "%d-%m-%Y %H:%M"):
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=dhaka)
        except ValueError:
            pass
    return None


def normalize_pos(d, now, source):
    """One partner event -> (row, error_code). Only the fields below are
    kept — a cashier's name or a customer's phone is DROPPED, never stored.
    row: {kind, ext_id, amount_taka, at, meta}"""
    if not isinstance(d, dict):
        return None, "bad_event"
    eid = str(d.get("event_id") or d.get("id") or "").strip()
    if not _ID_RX.match(eid):
        return None, "bad_event_id"
    kind = POS_TYPES.get(str(d.get("type") or d.get("kind") or "").strip().lower())
    if not kind:
        return None, "bad_type"
    p = _money_poisha(d.get("amount"))
    if p is None:
        return None, "bad_amount"
    cur = str(d.get("currency") or "BDT").upper()
    if cur != "BDT":
        return None, "bad_currency"
    at = parse_when(d.get("at") or d.get("time"), now)
    if at is None:
        return None, "bad_time"
    if at > now + timedelta(minutes=10) or at < now - timedelta(days=31):
        return None, "bad_time"
    meta = {"poisha": abs(p)}
    pay = str(d.get("payment_method") or d.get("payment") or "").lower()
    if pay in PAY_METHODS:
        meta["pay"] = pay
    reg = str(d.get("register") or d.get("till") or "").strip()
    if reg and re.fullmatch(r"[A-Za-z0-9 _\-]{1,24}", reg):
        meta["register"] = reg
    ref = str(d.get("sale_ref") or d.get("receipt") or "").strip()
    if ref and _ID_RX.match(ref):
        meta["ref"] = ref
    try:
        n = int(d.get("items") or 0)
        if 0 < n < 10000:
            meta["items"] = n
    except (TypeError, ValueError):
        pass
    return {"kind": kind, "ext_id": eid, "amount_taka": int(round(abs(p) / 100.0)),
            "at": at, "meta": dict(meta, src=source)}, ""


CSV_MAX_ROWS = 5000
_CSV_ALIASES = {"time": ("time", "at", "date", "datetime", "সময়", "তারিখ"),
                "type": ("type", "kind", "event", "ধরন"),
                "amount": ("amount", "total", "taka", "টাকা", "পরিমাণ"),
                "id": ("id", "event_id", "receipt", "invoice", "রসিদ")}


def parse_csv(text, now):
    """A POS export -> (rows, errors[{line, code}]). Header row required
    (time, type, amount, id — Bangla names work too). Rows without an id get
    a stable one from their content, so importing the same file twice adds
    nothing."""
    rows, errors = [], []
    try:
        rd = csv.reader(io.StringIO(text or ""))
        header = next(rd, None)
    except csv.Error:
        return [], [{"line": 1, "code": "bad_csv"}]
    if not header:
        return [], [{"line": 1, "code": "no_header"}]
    import unicodedata
    hmap = {}
    for i, h in enumerate(header):
        h = unicodedata.normalize("NFC", (h or "").strip().lower().lstrip("\ufeff"))
        for k, al in _CSV_ALIASES.items():
            if h in {unicodedata.normalize("NFC", a) for a in al} and k not in hmap:
                hmap[k] = i
    if "time" not in hmap or "type" not in hmap:
        return [], [{"line": 1, "code": "no_header"}]
    for n, rec in enumerate(rd, start=2):
        if n - 1 > CSV_MAX_ROWS:
            errors.append({"line": n, "code": "too_many"})
            break
        if not any((c or "").strip() for c in rec):
            continue

        def col(k):
            i = hmap.get(k)
            return rec[i].strip() if i is not None and i < len(rec) else ""
        eid = col("id") or "csv_" + hashlib.sha1(
            ("|".join(c.strip() for c in rec)).encode("utf-8")).hexdigest()[:20]
        row, err = normalize_pos({"event_id": eid[:64], "type": col("type"),
                                  "amount": col("amount"), "at": col("time")},
                                 now, "csv")
        if err:
            errors.append({"line": n, "code": err})
        else:
            rows.append(row)
    return rows, errors


# =================================================================== F: match
DRAWER_WINDOW_S = 120        # a sale/khata within ±2 min explains a drawer
AFTER_SALE_MIN_S = 3
AFTER_SALE_MAX_S = 90
CASH_EVENT_TYPES = ("hand_in_cash_zone", "drawer_open")
POCKET_SIGNALS = ("pocket", "hand_to_pocket", "pose_pocket")
REVIEW_NOTE = ("শুধু দেখার জন্য — এটা কোনো অভিযোগ নয়; স্বাভাবিক কারণও থাকতে পারে "
               "(খুচরা দেওয়া, ড্রয়ার গোছানো)। নিজে ক্লিপ দেখে সিদ্ধান্ত নিন।",
               "For review only — this is not an accusation; there may be a "
               "normal reason (giving change, tidying the drawer). Watch the "
               "clip and decide yourself.")


def _pocketish(sig):
    sig = sig if isinstance(sig, dict) else {}
    inp = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else sig
    vals = {str(inp.get(k) or "").lower() for k in ("pose", "kind", "gesture")}
    return any(v in POCKET_SIGNALS for v in vals) or bool(inp.get("pocket"))


def sales_match(drawers, sales, cam_events, window_s=DRAWER_WINDOW_S):
    """drawers: [{id, at(ts), source: 'pos'|'camera', event_id?}];
    sales: [{at(ts), kind: sale|khata, amount}];
    cam_events: [{id, at(ts), type, signals, camera, has_clip}].
    -> review items, newest first. Never a name; never 'theft'."""
    sale_ts = sorted(s["at"] for s in sales if s.get("kind") in ("sale", "khata"))
    items = []

    def near_sale(ts, lo, hi):
        for s in sale_ts:
            if ts + lo <= s <= ts + hi:
                return s
        return None

    def clip_for(ts, prefer_id=None):
        best, bd = None, None
        for e in cam_events:
            if prefer_id and e["id"] == prefer_id:
                return e
            if e["type"] not in CASH_EVENT_TYPES + ("pose_possible", "motion",
                                                    "person_detected"):
                continue
            dd = abs(e["at"] - ts)
            if dd <= 60 and (bd is None or dd < bd):
                best, bd = e, dd
        return best

    seen_events = set()
    for d in drawers:
        if near_sale(d["at"], -window_s, window_s) is not None:
            continue
        ev = clip_for(d["at"], d.get("event_id"))
        if ev is not None:
            if ev["id"] in seen_events:
                continue
            seen_events.add(ev["id"])
        items.append({"kind": "drawer_no_sale", "at": d["at"],
                      "source": d.get("source") or "pos",
                      "pos_id": d.get("id") if d.get("source") == "pos" else None,
                      "event_id": ev["id"] if ev else None,
                      "camera": ev.get("camera") if ev else None,
                      "has_clip": bool(ev and ev.get("has_clip"))})
    for e in cam_events:
        if e["type"] not in ("pose_possible", "hand_in_cash_zone") or not _pocketish(e.get("signals")):
            continue
        s = near_sale(e["at"], -AFTER_SALE_MAX_S, -AFTER_SALE_MIN_S)
        if s is None or e["id"] in seen_events:
            continue
        seen_events.add(e["id"])
        items.append({"kind": "after_sale_check", "at": e["at"], "source": "camera",
                      "pos_id": None, "event_id": e["id"], "camera": e.get("camera"),
                      "has_clip": bool(e.get("has_clip")),
                      "after_sale_s": int(round(e["at"] - s))})
    items.sort(key=lambda x: -x["at"])
    return items


def review_text(item, lang, hhmm):
    if item["kind"] == "drawer_no_sale":
        t = pick(lang, "%s-এ ক্যাশ ড্রয়ার খোলা — আশেপাশে কোনো বিক্রি/খাতা নেই" % bn(hhmm),
                 "Cash drawer opened at %s — no sale or khata entry nearby" % hhmm)
    else:
        s = item.get("after_sale_s") or 0
        t = pick(lang, "%s-এ বিক্রির %s সেকেন্ড পর ক্যাশের কাছে হাতের নড়াচড়া" % (bn(hhmm), bn(s)),
                 "Hand movement near the cash %s s after a sale at %s" % (s, hhmm))
    return t


# =================================================================== E: report
def _hm(v):
    m = re.fullmatch(r"(\d{1,2}):(\d{2})", str(v or "").strip())
    if not m:
        return None
    h, mi = int(m.group(1)), int(m.group(2))
    return h * 60 + mi if h < 24 and mi < 60 else None


def report_due(hours, local_minute, sent_date, today, after_close_min=15,
               default_close="22:00"):
    """The closing report goes once a day, `after_close_min` after the
    owner's closing time (22:00 when no hours are set)."""
    if sent_date == today:
        return False
    c = _hm((hours or {}).get("close")) if isinstance(hours, dict) else None
    c = c if c is not None else _hm(default_close)
    due = c + after_close_min
    if due >= 24 * 60:          # closes near midnight: report at 23:59
        due = 24 * 60 - 1
    return local_minute >= due


def peak_hours(hourly, n=2):
    pairs = [(v, h) for h, v in enumerate(hourly or []) if v]
    pairs.sort(key=lambda x: (-x[0], x[1]))
    return [h for _, h in pairs[:n]]


def hour_label(h, lang):
    if lang == "en":
        return "%d %s" % (h % 12 or 12, "am" if h < 12 else "pm")
    part = ("রাত" if h < 5 else "ভোর" if h < 6 else "সকাল" if h < 12 else
            "দুপুর" if h < 15 else "বিকেল" if h < 18 else "সন্ধ্যা" if h < 20 else "রাত")
    return "%s %sটা" % (part, bn(h % 12 or 12))


def _mins(lang, m):
    m = int(m)
    if m >= 60:
        h, r = divmod(m, 60)
        return (pick(lang, "%s ঘণ্টা %s মিনিট" % (bn(h), bn(r)), "%d h %d min" % (h, r))
                if r else pick(lang, "%s ঘণ্টা" % bn(h), "%d h" % h))
    return pick(lang, "%s মিনিট" % bn(m), "%d min" % m)


def closing_report(inp, lang):
    """inp: {site_kind, hours{open,close}, open_at, close_at ('HH:MM' or
    None), visitors, hourly[24], alerts{total, wrong, by_type{}}, counter_empty_min
    (None = not measured), vehicles{in,out} or None, tables{avg_pct, peak_pct,
    peak_hour} or None, health[{name, offline_min, sd, recorded_days}],
    sales{count, taka} or None, review_items}
    -> {sections: [...], lines: [...], ok: bool}"""
    L = []
    sec = {}
    hours = inp.get("hours") or {}
    o_set, c_set = _hm(hours.get("open")), _hm(hours.get("close"))
    o_at, c_at = _hm(inp.get("open_at")), _hm(inp.get("close_at"))
    oc = {"open_at": inp.get("open_at"), "close_at": inp.get("close_at"),
          "open_set": hours.get("open"), "close_set": hours.get("close"),
          "late_min": None, "early_min": None}
    if o_at is not None:
        line = pick(lang, "খুলেছে %s" % bn(inp["open_at"]), "Opened %s" % inp["open_at"])
        if o_set is not None and o_at - o_set >= 10:
            oc["late_min"] = o_at - o_set
            line += pick(lang, " — নির্ধারিত সময়ের %s পরে" % _mins(lang, o_at - o_set),
                         " — %s after the set time" % _mins(lang, o_at - o_set))
        elif o_set is not None:
            line += pick(lang, " — সময়মতো", " — on time")
        L.append(line)
    else:
        L.append(pick(lang, "আজ খোলার সময় ধরা যায়নি", "No opening time seen today"))
    if c_at is not None:
        line = pick(lang, "শেষ নড়াচড়া %s" % bn(inp["close_at"]), "Last movement %s" % inp["close_at"])
        if c_set is not None and c_set - c_at >= 15:
            oc["early_min"] = c_set - c_at
            line += pick(lang, " — নির্ধারিত বন্ধের %s আগে" % _mins(lang, c_set - c_at),
                         " — %s before the set closing" % _mins(lang, c_set - c_at))
        L.append(line)
    sec["open_close"] = oc
    v = int(inp.get("visitors") or 0)
    peaks = peak_hours(inp.get("hourly"))
    sec["people"] = {"visitors": v, "peak_hours": peaks, "hourly": list(inp.get("hourly") or [])}
    if v:
        line = pick(lang, "মানুষ এসেছেন প্রায় %s জন (পরিচয় ছাড়া গোনা)" % bn(v),
                    "About %d people came in (counted, no identity)" % v)
        if peaks:
            line += pick(lang, "; সবচেয়ে ব্যস্ত: %s" % ", ".join(hour_label(h, lang) for h in peaks),
                         "; busiest: %s" % ", ".join(hour_label(h, lang) for h in peaks))
        L.append(line)
    else:
        L.append(pick(lang, "আজ মানুষ গোনা হয়নি (ঢোকার রেখা আঁকা নেই বা ক্যামেরা চুপ ছিল)",
                      "No people counted today (no entry line drawn, or cameras were quiet)"))
    ce = inp.get("counter_empty_min")
    sec["counter_empty_min"] = ce
    if ce is not None:
        L.append(pick(lang, "খোলা সময়ে কাউন্টার খালি ছিল %s" % _mins(lang, ce),
                      "Counter left empty for %s while open" % _mins(lang, ce)))
    a = inp.get("alerts") or {}
    sec["alerts"] = a
    tot = int(a.get("total") or 0)
    L.append(pick(lang, "সতর্কতা %s টি" % bn(tot), "%d alerts" % tot) +
             (pick(lang, " (ভুল বলে চিহ্নিত %s)" % bn(a.get("wrong") or 0),
                   " (%d marked wrong)" % (a.get("wrong") or 0)) if a.get("wrong") else ""))
    rv = len(inp.get("review_items") or [])
    sec["review"] = rv
    if rv:
        L.append(pick(lang, "দেখার জন্য %s টি ক্যাশ-ক্লিপ (অভিযোগ নয়)" % bn(rv),
                      "%d cash clips to review (not accusations)" % rv))
    s = inp.get("sales")
    sec["sales"] = s
    if s and s.get("count"):
        L.append(pick(lang, "বিক্রি %s টি, মোট ৳%s" % (bn(s["count"]), bn(s.get("taka") or 0)),
                      "%d sales, total Tk %s" % (s["count"], s.get("taka") or 0)))
    veh = inp.get("vehicles")
    sec["vehicles"] = veh
    if veh is not None:
        L.append(pick(lang, "গাড়ি ঢুকেছে %s, বের হয়েছে %s" % (bn(veh.get("in", 0)), bn(veh.get("out", 0))),
                      "Vehicles in %d, out %d" % (veh.get("in", 0), veh.get("out", 0))))
    tb = inp.get("tables")
    sec["tables"] = tb
    if tb is not None:
        L.append(pick(lang, "টেবিল গড়ে %s%% ভরা, সবচেয়ে বেশি %s%% (%s)" % (
            bn(tb.get("avg_pct", 0)), bn(tb.get("peak_pct", 0)), hour_label(tb.get("peak_hour", 0), lang)),
            "Tables %d%% full on average, peak %d%% (%s)" % (
            tb.get("avg_pct", 0), tb.get("peak_pct", 0), hour_label(tb.get("peak_hour", 0), lang))))
    dvr = inp.get("dvr") if isinstance(inp.get("dvr"), dict) else None
    if dvr and dvr.get("recorded_days") is not None:
        sec["dvr"] = {k: dvr.get(k) for k in ("status", "recorded_days", "target_days")}
        L.append(pick(lang, "DVR-এ রেকর্ড আছে %s দিনের" % bn(dvr["recorded_days"]),
                      "The DVR holds %s days of recording" % dvr["recorded_days"]) +
                 (pick(lang, " (লক্ষ্য %s দিন)" % bn(dvr["target_days"]),
                       " (target %s days)" % dvr["target_days"]) if dvr.get("target_days") else ""))
        for ln in (dvr.get("lines") or [])[:2]:
            if isinstance(ln, dict) and ln.get("sev") in ("red", "amber", "high", "med") and ln.get("what"):
                L.append(str(ln["what"])[:160])
    health = inp.get("health") or []
    bad = [h for h in health if (h.get("offline_min") or 0) >= 10 or h.get("sd") == "problem"]
    sec["health"] = {"cameras": len(health), "problems": len(bad), "rows": health}
    if health and not bad:
        L.append(pick(lang, "সব %s টি ক্যামেরা ঠিক ছিল ✓" % bn(len(health)),
                      "All %d cameras were fine ✓" % len(health)))
    for h in bad[:3]:
        if h.get("sd") == "problem":
            L.append(pick(lang, "%s: রেকর্ডিং/হার্ডডিস্কে সমস্যা — দেখে নিন" % h.get("name"),
                          "%s: recording / hard disk problem — please check" % h.get("name")))
        else:
            L.append(pick(lang, "%s: %s বন্ধ ছিল" % (h.get("name"), _mins(lang, h["offline_min"])),
                          "%s: offline for %s" % (h.get("name"), _mins(lang, h["offline_min"]))))
    dvr_bad = bool(dvr and dvr.get("status") == "red")
    return {"sections": sec, "lines": L, "ok": not bad and not rv and not dvr_bad}


def report_title(lang, site_name, date_label):
    return pick(lang, "আজকের হিসাব — %s (%s)" % (site_name or "দোকান", bn(date_label)),
                "Today's report — %s (%s)" % (site_name or "Shop", date_label))


# =================================================================== G: ask
_COLOURS = {
    "red": ("লাল", "red"), "white": ("সাদা", "white"), "black": ("কালো", "black"),
    "blue": ("নীল", "blue"), "green": ("সবুজ", "green"), "yellow": ("হলুদ", "yellow"),
    "silver": ("সিলভার", "silver", "রুপালি", "grey", "gray", "ছাই"),
    "orange": ("কমলা", "orange"), "brown": ("বাদামি", "brown"),
}
_KINDS = {
    "vehicle": ("গাড়ি", "গাড়ী", "car", "vehicle", "bike", "মোটরসাইকেল", "বাইক", "truck",
                "ট্রাক", "রিকশা", "rickshaw", "cng", "সিএনজি"),
    "person": ("কে ", "কেউ", "মানুষ", "লোক", "who", "person", "people", "someone"),
    "animal": ("কুকুর", "বিড়াল", "dog", "cat", "animal", "প্রাণী"),
}
_ZONES = {
    "cash": ("ক্যাশ", "ক্যাশে", "cash", "drawer", "ড্রয়ার", "counter", "কাউন্টার"),
    "gate": ("গেট", "gate", "দরজা", "door", "entrance", "ঢোকার"),
    "shutter": ("শাটার", "shutter"),
    "parking": ("পার্কিং", "parking", "গ্যারেজ", "garage"),
    "store": ("গুদাম", "store room", "warehouse", "স্টোর"),
}
_INTENTS = {
    "shutter_open": (r"(শাটার|shutter).*(খুল|open)", r"(open).*(shutter)"),
    "shop_close": (r"(বন্ধ|close|closed).*(কখন|when)", r"(কখন|when).*(বন্ধ|close)"),
}
_NUM = r"(\d{1,2})(?:[:.](\d{2}))?"
_PM_WORDS = ("pm", "দুপুর", "বিকাল", "বিকেল", "সন্ধ্যা", "রাত")
_AM_WORDS = ("am", "সকাল", "ভোর")


def _to24(h, words_before):
    w = words_before.lower()
    if any(x in w for x in _PM_WORDS) and h < 12:
        if "রাত" in w and h >= 9:
            return h + 12
        if "রাত" in w and h <= 4:
            return h
        return h + 12
    if any(x in w for x in _AM_WORDS):
        return 0 if h == 12 else h
    # no word: shop hours — 1..7 are afternoon
    return h + 12 if 1 <= h <= 7 else h


def parse_question(q, today):
    """A Bangla / English question -> filter {date, from_min, to_min, kind,
    colour, zone, intent}. Deterministic; the AI parse (views) may refine it
    but this always works offline and for free."""
    raw = (q or "").strip()
    s = to_en_digits(raw).lower()
    f = {"date": today.isoformat(), "from_min": None, "to_min": None, "kind": None,
         "colour": None, "zone": None, "intent": None, "q": raw[:200]}
    if re.search(r"(গতকাল|কাল রাত|yesterday)", s):
        f["date"] = (today - timedelta(days=1)).isoformat()
    m = re.search(r"(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?", s)
    if m and not re.search(r"\d{1,2}[/-]\d{1,2}\s*(টা|pm|am)", s):
        try:
            y = int(m.group(3)) if m.group(3) else today.year
            y = y + 2000 if y < 100 else y
            f["date"] = datetime(y, int(m.group(2)), int(m.group(1))).date().isoformat()
        except ValueError:
            pass
    rng = re.search(_NUM + r"\s*(?:টা|টার|pm|am|ta)?\s*(?:থেকে|to|till|until|-|–|and)\s*" + _NUM, s)
    if rng:
        pre = s[:rng.start()] + " " + s[rng.end():rng.end() + 6]
        h1 = _to24(int(rng.group(1)), pre + " " + s[rng.start():rng.end()])
        h2 = _to24(int(rng.group(3)), pre + " " + s[rng.start():rng.end()])
        if h2 < h1 and h2 + 12 < 24:
            h2 += 12
        f["from_min"] = h1 * 60 + int(rng.group(2) or 0)
        f["to_min"] = h2 * 60 + int(rng.group(4) or 0)
    else:
        one = re.search(_NUM + r"\s*(টা|টার|pm|am)", s)
        if one:
            h = _to24(int(one.group(1)), s[:one.start()] + one.group(3))
            f["from_min"] = h * 60 + int(one.group(2) or 0)
            f["to_min"] = f["from_min"] + 60
    if re.search(r"(রাতে|at night|last night|রাত)", s) and f["from_min"] is None:
        f["from_min"], f["to_min"] = 22 * 60, 24 * 60 + 6 * 60
    for k, words in _COLOURS.items():
        if any(w in s for w in words):
            f["colour"] = k
            break
    for k, words in _ZONES.items():
        if any(w in s for w in words):
            f["zone"] = k
            break
    for k, words in _KINDS.items():
        if any(w in s for w in words):
            f["kind"] = k
            break
    for k, pats in _INTENTS.items():
        if any(re.search(p, s) for p in pats):
            f["intent"] = k
            break
    if f["zone"] == "cash" and not f["kind"]:
        f["kind"] = "person"
    return f


def clean_ai_filter(d, base):
    """Merge an AI-parsed filter onto the deterministic one — only known
    keys and values; anything else is dropped (the AI never invents data)."""
    out = dict(base)
    if not isinstance(d, dict):
        return out
    for k, allowed in (("kind", tuple(_KINDS)), ("colour", tuple(_COLOURS)),
                       ("zone", tuple(_ZONES)), ("intent", tuple(_INTENTS))):
        v = d.get(k)
        if v in allowed:
            out[k] = v
    for k in ("from_min", "to_min"):
        v = d.get(k)
        if isinstance(v, int) and 0 <= v <= 30 * 60:
            out[k] = v
    v = d.get("date")
    if isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        out["date"] = v
    return out


def _words_of(e):
    sig = e.get("signals") if isinstance(e.get("signals"), dict) else {}
    inp = sig.get("inputs") if isinstance(sig.get("inputs"), dict) else sig
    parts = [str(e.get("camera_name") or ""), str(inp.get("zone") or ""),
             str(inp.get("zone_name") or ""), str(inp.get("kind") or ""),
             str(inp.get("colour") or inp.get("color") or ""),
             str(inp.get("object") or ""), str(inp.get("event") or "")]
    return " ".join(parts).lower(), inp


def event_matches(e, f):
    """e: {type, at_min (local minutes since that day's 00:00; +1440 next
    day), camera_name, signals}."""
    words, inp = _words_of(e)
    if f.get("from_min") is not None:
        lo, hi = f["from_min"], f["to_min"] if f.get("to_min") is not None else f["from_min"] + 60
        if not (lo <= e["at_min"] < hi):
            return False
    if f.get("zone"):
        zw = _ZONES[f["zone"]]
        if f["zone"] == "cash" and e["type"] in CASH_EVENT_TYPES:
            pass
        elif not any(w.strip() in words for w in zw):
            return False
    if f.get("kind") == "vehicle":
        if str(inp.get("kind") or inp.get("object") or "").lower() not in (
                "vehicle", "car", "bike", "motorcycle", "truck", "bus", "cng", "rickshaw"):
            return False
    elif f.get("kind") == "animal":
        if str(inp.get("kind") or "").lower() != "animal":
            return False
    elif f.get("kind") == "person":
        if str(inp.get("kind") or "").lower() in ("vehicle", "animal") or \
                e["type"] == "camera_health":
            return False
    if f.get("colour"):
        c = str(inp.get("colour") or inp.get("color") or "").lower()
        if c not in _COLOURS[f["colour"]] and c != f["colour"]:
            return False
    if f.get("intent") == "shutter_open":
        ev = str(inp.get("event") or inp.get("kind") or "").lower()
        if ev not in ("shutter_open", "gate_open", "door_open") and "shutter" not in words \
                and "শাটার" not in words:
            return False
    return True


def answer_lines(f, matches, lang, open_close=None):
    """The answer from the DATA only. matches: [{hhmm, camera_name, what}]."""
    n = len(matches)
    if f.get("intent") == "shutter_open" and not matches and open_close and \
            open_close.get("open"):
        return [pick(lang, "আজ প্রথম নড়াচড়া (দোকান খোলা) %s-এ দেখা গেছে।" % bn(open_close["open"]),
                     "The first movement today (shop opening) was at %s." % open_close["open"])]
    if f.get("intent") == "shop_close" and open_close and open_close.get("close"):
        return [pick(lang, "শেষ নড়াচড়া %s-এ দেখা গেছে।" % bn(open_close["close"]),
                     "The last movement was at %s." % open_close["close"])]
    if not n:
        return [pick(lang, "এই সময়ে এমন কিছু জমা থাকা ঘটনায় পাওয়া যায়নি।",
                     "Nothing like that was found in the saved events for that time."),
                pick(lang, "মনে রাখবেন: শুধু যে ঘটনাগুলো ক্যামেরা ধরেছে সেগুলোই খোঁজা যায়।",
                     "Note: only events the cameras picked up can be searched.")]
    first, last = matches[-1], matches[0]
    head = pick(lang, "%s টি ঘটনা পাওয়া গেছে" % bn(n), "Found %d events" % n)
    if n == 1:
        head = pick(lang, "১টি ঘটনা: %s, %s" % (bn(first["hhmm"]), first["camera_name"] or "ক্যামেরা"),
                    "1 event: %s, %s" % (first["hhmm"], first["camera_name"] or "camera"))
    else:
        head += pick(lang, " — প্রথম %s, শেষ %s।" % (bn(first["hhmm"]), bn(last["hhmm"])),
                     " — first %s, last %s." % (first["hhmm"], last["hhmm"]))
    out = [head]
    if f.get("kind") == "person" or f.get("zone") == "cash":
        out.append(pick(lang, "কারা ছিলেন তা Assisto বলে না (মুখ চেনা নেই) — ক্লিপ দেখে নিজে দেখুন।",
                        "Assisto does not say who it was (no face recognition) — watch the clips."))
    return out


AI_PARSE_TASK = (
    "You turn a shop owner's CCTV question (Bangla, romanized Bangla or English) "
    "into a JSON search filter. Reply with ONE JSON object only, keys: "
    "date (YYYY-MM-DD or null), from_min and to_min (minutes after local "
    "midnight, integers, or null), kind (person|vehicle|animal|null), colour "
    "(red|white|black|blue|green|yellow|silver|orange|brown|null), zone "
    "(cash|gate|shutter|parking|store|null), intent (shutter_open|shop_close|null). "
    "Never identify people. Today is %s.")


def parse_ai_json(text):
    if not text:
        return None
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        d = json.loads(m.group(0))
        return d if isinstance(d, dict) else None
    except ValueError:
        return None
