"""
cctv_brief.py — the CCTV ACTIVITY BRAIN, pure rules (cctvactivity, owner CCTV
order 3 Nov section E + F2; audit package W10 + visitor log E2).

No Django, no DB, no network — every function takes plain dicts / datetimes,
so it is unit-tested without a server. The glue is core/cctv_activity.py.

STATE (one small JSON under ShopSite.guard["_activity"], bounded):
  {"cfg":  owner settings (normalize_cfg),
   "days": {"YYYY-MM-DD": day record (new_day)} — the last KEEP_DAYS days,
   "lv":   {"<camera id>": ts of the last person seen} — visit de-duplication,
   "brief": "YYYY-MM-DD" of the last morning summary sent,
   "ai":   {"month": "YYYY-MM", "used": n} — AI descriptions this month}

A day record:
  h  [24] person VISITS per hour (estimate: one person on one camera, seen
          again within VISIT_GAP_S, is the same visit)
  la/lb/lt [24] entry-line crossings a->b / b->a / total per hour
  m  [24] movement events per hour (any camera)
  first/last "HH:MM" first / last person-or-movement on the SHOP cameras
          inside the activity window (05:00-23:59, outside the watchman
          window) — the camera's opening / closing time, owner confirms
  ok {"open": "HH:MM", "close": "HH:MM"} the owner-confirmed times
  wp [hours] hours with presence on the WATCHMAN cameras
  wm {"HH": "ok" | "miss" | "unknown"} hourly watchman results
  om {"<key>": minutes} offline minutes per camera ("c<id>") / gateway ("g")
  sd {"<camera id>": "ok" | "problem" | "none" | "unknown"}
  al alerts saved that day (counted by the glue)

NEVER face recognition, never a name, never an accusation.
"""
import re
from datetime import timedelta

from . import watchman as WM

KEEP_DAYS = 35
VISIT_GAP_S = 60
HOURS = 24
ACT_START_MIN = 5 * 60          # 05:00 — earlier movement is night, not "opening"
MAX_WM_ALERTS_NIGHT = 3         # then the morning summary carries the rest
AI_CHECKS_PER_CAMERA = 50       # default; agent/cctvprice's cctv_plan wins
DESC_MAX = 160

MOVEMENT_TYPES = ("motion", "person_detected", "zone_intrusion", "line_crossing",
                  "camera_alarm", "hand_in_cash_zone", "drawer_open", "pose_possible",
                  "loitering", "after_hours")
PERSON_TYPES = ("person_detected", "zone_intrusion", "line_crossing", "loitering",
                "hand_in_cash_zone", "pose_possible")
# the visitor log: alerts that are about a person being there
VISITOR_TYPES = PERSON_TYPES + ("motion", "camera_alarm", "after_hours")

_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")
_EN = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


def bn(v):
    return str(v).translate(_BN)


def _d(v, lang):
    return bn(v) if lang == "bn" else str(v)


def pick(lang, b, e):
    return e if lang == "en" else b


# ================================================================ settings
def defaults():
    return {"brief_on": True, "brief_hour": 8, "shop_cams": [],
            "wm_on": False, "wm_start": "22:00", "wm_end": "06:00", "wm_cams": [],
            "foot_dir": "both", "ai_desc": True}


class CfgError(ValueError):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _hhmm(v, code):
    t = WM.parse_hhmm(v)
    if t is None:
        raise CfgError(code)
    return t.strftime("%H:%M")


def _cams(v, allowed):
    if v in (None, ""):
        return []
    if not isinstance(v, list):
        raise CfgError("bad_cameras")
    out = []
    for x in v[:20]:
        try:
            x = int(x)
        except (TypeError, ValueError):
            raise CfgError("bad_cameras")
        if allowed is not None and x not in allowed:
            raise CfgError("bad_cameras")
        if x not in out:
            out.append(x)
    return out


def normalize_cfg(raw, allowed_cams=None, strict=False):
    """Bounded settings. strict=True (an owner PUT) raises CfgError on bad
    values; strict=False (reading stored state) falls back to defaults."""
    c = defaults()
    raw = raw if isinstance(raw, dict) else {}
    for k in ("brief_on", "wm_on", "ai_desc"):
        if k in raw:
            v = raw[k]
            if isinstance(v, str):
                v = v.strip().lower() in ("1", "true", "yes", "on")
            c[k] = bool(v)
    try:
        if "brief_hour" in raw:
            h = int(raw["brief_hour"])
            if not 0 <= h <= 23:
                raise CfgError("bad_hour")
            c["brief_hour"] = h
        for k in ("wm_start", "wm_end"):
            if k in raw:
                c[k] = _hhmm(raw[k], "bad_window")
        if c["wm_start"] == c["wm_end"]:
            raise CfgError("bad_window")
        for k in ("shop_cams", "wm_cams"):
            if k in raw:
                c[k] = _cams(raw[k], allowed_cams)
        if "foot_dir" in raw:
            if raw["foot_dir"] not in ("both", "a_to_b", "b_to_a"):
                raise CfgError("bad_direction")
            c["foot_dir"] = raw["foot_dir"]
    except (CfgError, TypeError, ValueError) as e:
        if strict:
            raise e if isinstance(e, CfgError) else CfgError("bad_hour")
        base = defaults()
        base.update({k: c[k] for k in ("brief_on", "wm_on", "ai_desc")})
        return base
    return c


def wm_window(cfg):
    return {"start": cfg["wm_start"], "end": cfg["wm_end"]}


# ================================================================ day state
def new_day():
    return {"h": [0] * HOURS, "la": [0] * HOURS, "lb": [0] * HOURS,
            "lt": [0] * HOURS, "m": [0] * HOURS, "first": None, "last": None,
            "ok": {}, "wp": [], "wm": {}, "om": {}, "sd": {}, "al": 0}


def day_rec(act, date):
    days = act.setdefault("days", {})
    d = days.get(date)
    if not isinstance(d, dict):
        d = new_day()
        days[date] = d
    for k, v in new_day().items():
        if k not in d or (isinstance(v, list) and len(d[k]) != len(v) and k != "wp"):
            d[k] = v
    return d


def prune(act, today, keep=KEEP_DAYS):
    days = act.get("days") or {}
    if len(days) > keep:
        for k in sorted(days)[:-keep]:
            days.pop(k, None)
    # visit memory older than a day is useless
    lv = act.get("lv") or {}
    act["lv"] = dict(list(lv.items())[-50:])
    return act


def is_person(etype, sig):
    sig = sig if isinstance(sig, dict) else {}
    if etype in PERSON_TYPES:
        if etype == "line_crossing" and sig.get("object") not in (None, "", "person"):
            return False
        if etype == "zone_intrusion" and sig.get("object") not in (None, "", "person"):
            return False
        return True
    return (sig.get("object") == "person" or sig.get("kind") == "person"
            or bool(sig.get("human")))


def _in_list(cam_id, cams):
    return not cams or cam_id in cams


def observe(act, cfg, cam_id, etype, sig, local_dt, ts):
    """Record ONE camera event into the activity state (mutates + returns
    act). Runs for every event, armed or not, before any alert decision."""
    sig = sig if isinstance(sig, dict) else {}
    if sig.get("health_still") or etype == "camera_health":
        return act
    date = local_dt.date().isoformat()
    h = local_dt.hour
    d = day_rec(act, date)
    movement = etype in MOVEMENT_TYPES
    person = is_person(etype, sig)
    if not (movement or person):
        return act
    d["m"][h] += 1
    line = etype == "line_crossing" or sig.get("kind") == "line"
    if line and person:
        d["lt"][h] += 1
        if sig.get("direction") == "a_to_b":
            d["la"][h] += 1
        elif sig.get("direction") == "b_to_a":
            d["lb"][h] += 1
    elif person:
        lv = act.setdefault("lv", {})
        last = lv.get(str(cam_id))
        if last is None or ts - float(last) >= VISIT_GAP_S or ts < float(last):
            d["h"][h] += 1
        lv[str(cam_id)] = ts
    hhmm = local_dt.strftime("%H:%M")
    mins = h * 60 + local_dt.minute
    night = cfg.get("wm_on") and WM.in_window(wm_window(cfg), local_dt)
    if _in_list(cam_id, cfg.get("shop_cams")) and mins >= ACT_START_MIN and not night:
        if not d["first"] or hhmm < d["first"]:
            d["first"] = hhmm
        if not d["last"] or hhmm > d["last"]:
            d["last"] = hhmm
    if night and _in_list(cam_id, cfg.get("wm_cams")) and h not in d["wp"]:
        d["wp"].append(h)
    return act


# ================================================================ footfall
def footfall(day, foot_dir="both"):
    """(per-hour list, source) — source 'line' (entry line counted by the
    camera), 'estimate' (person visits) or 'none'."""
    day = day or {}
    lt = list(day.get("lt") or [0] * HOURS)
    if sum(lt):
        if foot_dir == "a_to_b":
            return list(day.get("la") or [0] * HOURS), "line"
        if foot_dir == "b_to_a":
            return list(day.get("lb") or [0] * HOURS), "line"
        # both directions crossed: in + out ~ 2 crossings per visitor
        return [(n + 1) // 2 for n in lt], "line"
    h = list(day.get("h") or [0] * HOURS)
    return h, ("estimate" if sum(h) else "none")


def footfall_vs_sales(foot, sales, sales_amt=None):
    """Hourly rows + conversion + peak hours. `sales` = sale count per hour."""
    sales_amt = sales_amt or [0] * HOURS
    rows = []
    for hr in range(HOURS):
        f, s = int(foot[hr] or 0), int(sales[hr] or 0)
        if f or s:
            rows.append({"hour": hr, "visitors": f, "sales": s,
                         "amount": round(float(sales_amt[hr] or 0), 2),
                         "conversion": (round(min(100.0, 100.0 * s / f), 1) if f else None)})
    tf, ts = sum(int(x or 0) for x in foot), sum(int(x or 0) for x in sales)
    peaks = [r["hour"] for r in sorted((r for r in rows if r["visitors"]),
                                       key=lambda r: (-r["visitors"], r["hour"]))[:3]]
    return {"rows": rows, "visitors": tf, "sales": ts,
            "amount": round(sum(float(x or 0) for x in sales_amt), 2),
            "conversion": (round(min(100.0, 100.0 * ts / tf), 1) if tf else None),
            "peak_hours": sorted(peaks)}


def hour_label(hr, lang):
    a, b = "%02d:00" % hr, "%02d:00" % ((hr + 1) % 24)
    return _d("%s–%s" % (a, b), lang)


# ================================================================ open / close
def open_close(day, now_local=None, quiet_after_min=60):
    """What the camera says about opening / closing, plus the owner's
    confirmed times. `close` is only final once the shop has been quiet for
    quiet_after_min (or the day is over)."""
    day = day or {}
    ok = day.get("ok") or {}
    first, last = day.get("first"), day.get("last")
    final = True
    if now_local is not None and last:
        lm = int(last[:2]) * 60 + int(last[3:5])
        nm = now_local.hour * 60 + now_local.minute
        final = nm - lm >= quiet_after_min
    return {"open": ok.get("open") or first, "close": ok.get("close") or (last if final else None),
            "camera_open": first, "camera_close": last if final else None,
            "last_seen": last, "confirmed": bool(ok.get("open") or ok.get("close"))}


def confirm_times(day, open_at=None, close_at=None):
    ok = dict(day.get("ok") or {})
    if open_at is not None:
        ok["open"] = _hhmm(open_at, "bad_time") if open_at else None
    if close_at is not None:
        ok["close"] = _hhmm(close_at, "bad_time") if close_at else None
    day["ok"] = {k: v for k, v in ok.items() if v}
    return day


# ================================================================ watchman
def watchman_due(cfg, local_now, act):
    """The just-finished hour to check, as (date, hour), or None. An hour
    counts when it STARTS inside the watchman window."""
    if not cfg.get("wm_on"):
        return None
    hstart = local_now.replace(minute=0, second=0, microsecond=0) - timedelta(hours=1)
    if not WM.in_window(wm_window(cfg), hstart):
        return None
    date = hstart.date().isoformat()
    d = (act.get("days") or {}).get(date) or {}
    if ("%02d" % hstart.hour) in (d.get("wm") or {}):
        return None
    return date, hstart.hour


def watchman_verdict(day, hour, cams_offline):
    """ok (someone moved on a watchman camera that hour), unknown (the
    cameras were offline — we cannot know; never blame the watchman) or miss."""
    if hour in (day.get("wp") or []):
        return "ok"
    if cams_offline:
        return "unknown"
    return "miss"


def watchman_text(lang, site, hour):
    t = pick(lang, "পাহারাদারকে গত ঘণ্টায় ক্যামেরায় দেখা যায়নি",
             "No movement from the watchman in the last hour")
    b = pick(lang,
             "%s: %s সময়ে পাহারার ক্যামেরায় কোনো নড়াচড়া আসেনি। একবার ফোন করে খোঁজ নিন — হয়তো তিনি ক্যামেরার বাইরে বসে আছেন।",
             "%s: no movement on the watchman camera(s) during %s. Please call and check — they may be sitting outside the camera view.") % (
        site or pick(lang, "দোকান", "Shop"), hour_label(hour, lang))
    return t, b


# ================================================================ descriptions
_KIND_BN = {"person_detected": "একজন মানুষ দেখা গেছে", "zone_intrusion": "কেউ নিষিদ্ধ জায়গায় ঢুকেছে",
            "line_crossing": "কেউ প্রবেশ-রেখা পার হয়েছে", "loitering": "কেউ অনেকক্ষণ দাঁড়িয়ে/ঘোরাঘুরি করছে",
            "motion": "নড়াচড়া দেখা গেছে", "camera_alarm": "ক্যামেরার নিজের সতর্কতা",
            "after_hours": "বন্ধের সময়ে নড়াচড়া", "hand_in_cash_zone": "ক্যাশের জায়গায় হাত",
            "pose_possible": "সম্ভবত কেউ ঝুঁকে আছে", "drawer_open": "ক্যাশ ড্রয়ার খোলা"}
_KIND_EN = {"person_detected": "A person was seen", "zone_intrusion": "Someone entered a restricted zone",
            "line_crossing": "Someone crossed the entry line", "loitering": "Someone stayed / loitered for a while",
            "motion": "Movement was seen", "camera_alarm": "The camera's own alert",
            "after_hours": "Movement after closing time", "hand_in_cash_zone": "A hand in the cash zone",
            "pose_possible": "Possibly someone bending", "drawer_open": "Cash drawer open"}
_OBJ = {"vehicle": ("একটি গাড়ি", "A vehicle"), "animal": ("একটি প্রাণী", "An animal")}


def template_desc(etype, sig, cam_name, local_dt, count=1):
    """Plain text from the event type / zone / time — NOT AI, labelled so."""
    sig = sig if isinstance(sig, dict) else {}
    obj = sig.get("object")
    if obj in _OBJ and etype in ("motion", "camera_alarm", "zone_intrusion", "line_crossing"):
        what_bn, what_en = _OBJ[obj][0] + " দেখা গেছে", _OBJ[obj][1] + " was seen"
    else:
        what_bn = _KIND_BN.get(etype, "ক্যামেরায় কিছু দেখা গেছে")
        what_en = _KIND_EN.get(etype, "Something was seen on the camera")
    zone = str(sig.get("zone") or "")[:40]
    where_bn = (" — %s" % cam_name) if cam_name else ""
    where_en = (" — %s" % cam_name) if cam_name else ""
    if zone:
        where_bn += " (%s)" % zone
        where_en += " (%s)" % zone
    t = local_dt.strftime("%H:%M")
    more_bn = ("، %sবার" % bn(count)) if count and count > 1 else ""
    more_en = (", %d times" % count) if count and count > 1 else ""
    return {"bn": "%s%s, %s%s" % (what_bn, where_bn, bn(t), more_bn),
            "en": "%s%s, %s%s" % (what_en, where_en, t, more_en),
            "src": "template"}


AI_SYSTEM = (
    "You describe ONE security-camera still for a shop or home owner in Bangladesh. "
    "Reply with ONE short Bangla sentence (max 20 words), then a line '||', then the same "
    "sentence in English. Say only what is visible: how many people, clothing colours, "
    "what they carry or do, vehicles, animals, where in the picture. NEVER identify, name "
    "or guess who a person is, their religion, ethnicity or age group; never say thief, "
    "criminal or suspicious; no face recognition. If the image is dark or empty, say so.")

_BAD = re.compile(r"(চোর|ডাকাত|অপরাধী|সন্দেহজনক|thief|criminal|robber|burglar|suspicious|"
                  r"\bhindu\b|\bmuslim\b|হিন্দু|মুসলিম)", re.I)


def clean_ai_desc(text):
    """{bn, en, src: 'ai'} or None when the reply is unusable / unsafe."""
    if not isinstance(text, str) or not text.strip():
        return None
    parts = text.replace("\r", "").split("||")
    b = " ".join(parts[0].split())[:DESC_MAX]
    e = " ".join(parts[1].split())[:DESC_MAX] if len(parts) > 1 else ""
    if not b or _BAD.search(b) or _BAD.search(e):
        return None
    return {"bn": b, "en": e or b, "src": "ai"}


def ai_cap(per_camera, cameras):
    return max(0, int(per_camera)) * max(0, int(cameras))


def ai_allowed(act, month, cap):
    a = act.get("ai") or {}
    used = int(a.get("used", 0)) if a.get("month") == month else 0
    return used < cap, used


def ai_take(act, month):
    a = act.get("ai") or {}
    used = int(a.get("used", 0)) if a.get("month") == month else 0
    act["ai"] = {"month": month, "used": used + 1}
    return used + 1


# ================================================================ search
def norm(s):
    return " ".join(str(s or "").translate(_EN).lower().split())


def matches(row_text, q):
    """Every word of q appears in the row (Bangla digits == ASCII digits)."""
    words = norm(q).split()
    t = norm(row_text)
    return all(w in t for w in words)


# ================================================================ summary
def health_lines(cams, lang):
    """cams: [{name, offline_min, sd, last_photo ("HH:MM" | None), online}]"""
    out = []
    for c in cams:
        name = c.get("name") or pick(lang, "ক্যামেরা", "Camera")
        om = int(c.get("offline_min") or 0)
        sd = {"ok": pick(lang, "SD ঠিক", "SD OK"), "problem": pick(lang, "SD-তে সমস্যা", "SD problem"),
              "none": pick(lang, "SD কার্ড নেই", "no SD card")}.get(c.get("sd"),
                                                                   pick(lang, "SD-র খবর নেই", "SD status unknown"))
        off = (pick(lang, "%s মিনিট বন্ধ ছিল", "offline %s min") % _d(om, lang)) if om \
            else pick(lang, "সারাদিন চালু", "on all day")
        last = c.get("last_photo")
        lp = (pick(lang, "শেষ ছবি %s", "last photo %s") % _d(last, lang)) if last \
            else pick(lang, "ছবি নেই", "no photo")
        out.append("%s: %s, %s, %s" % (name, off, sd, lp))
    return out


def summary_lines(info, lang):
    """The morning Bangla summary (counts only, no AI). info = {date_label,
    foot: footfall_vs_sales(), foot_src, oc: open_close(), alerts,
    wm: {"ok", "miss", "unknown"}, health: [...], visitors_logged}."""
    out = []
    f = info.get("foot") or {}
    src = info.get("foot_src")
    if src == "none":
        out.append(pick(lang, "আগন্তুক: ক্যামেরা কোনো মানুষ-ঘটনা পাঠায়নি।",
                        "Visitors: the cameras sent no person events."))
    else:
        tag = "" if src == "line" else pick(lang, " (আনুমানিক)", " (estimate)")
        line = pick(lang, "আগন্তুক: %sজন%s", "Visitors: %s%s") % (_d(f.get("visitors", 0), lang), tag)
        if f.get("peak_hours"):
            line += pick(lang, "; ভিড়ের সময় %s", "; busiest %s") % ", ".join(
                hour_label(h, lang) for h in f["peak_hours"][:2])
        out.append(line + pick(lang, "।", "."))
    if f.get("sales"):
        conv = f.get("conversion")
        out.append(pick(lang, "বিক্রি: %sটি (৳%s)%s।", "Sales: %s (Tk %s)%s.") % (
            _d(f["sales"], lang), _d(int(f.get("amount") or 0), lang),
            (pick(lang, " — কনভার্সন %s%%", " — conversion %s%%") % _d(conv, lang)) if conv is not None else ""))
    oc = info.get("oc") or {}
    if oc.get("open") or oc.get("close"):
        out.append(pick(lang, "দোকান খুলেছে %s, বন্ধ %s%s।", "Opened %s, closed %s%s.") % (
            _d(oc.get("open") or "—", lang), _d(oc.get("close") or "—", lang),
            "" if oc.get("confirmed") else pick(lang, " (ক্যামেরা দেখে — নিশ্চিত করুন)",
                                                " (from the camera — please confirm)")))
    wm = info.get("wm") or {}
    if any(wm.get(k) for k in ("ok", "miss", "unknown")):
        out.append(pick(lang, "পাহারাদার: %s ঘণ্টা দেখা গেছে, %s ঘণ্টা দেখা যায়নি%s।",
                        "Watchman: seen %s h, not seen %s h%s.") % (
            _d(wm.get("ok", 0), lang), _d(wm.get("miss", 0), lang),
            (pick(lang, ", %s ঘণ্টা ক্যামেরা বন্ধ ছিল", ", %s h cameras offline") % _d(wm["unknown"], lang))
            if wm.get("unknown") else ""))
    out.append(pick(lang, "সতর্কতা: %sটি।", "Alerts: %s.") % _d(info.get("alerts", 0), lang))
    out.extend(health_lines(info.get("health") or [], lang))
    return out


def summary_title(lang, site, date_label):
    return pick(lang, "%s — কালকের সারাংশ (%s)", "%s — yesterday's summary (%s)") % (
        site or pick(lang, "দোকান", "Shop"), _d(date_label, lang))


def wm_totals(day):
    wm = (day or {}).get("wm") or {}
    out = {"ok": 0, "miss": 0, "unknown": 0}
    for v in wm.values():
        if v in out:
            out[v] += 1
    return out


def brief_due(cfg, local_now, act):
    """Morning summary for YESTERDAY at the owner's hour, once a day."""
    if not cfg.get("brief_on"):
        return None
    if local_now.hour < int(cfg.get("brief_hour", 8)):
        return None
    today = local_now.date().isoformat()
    if act.get("brief") == today:
        return None
    return (local_now.date() - timedelta(days=1)).isoformat()


# ================================================================ time-lapse
def timelapse_plan(n_frames, seconds=30, max_frames=120):
    """Frames to use and the per-frame delay so the film lasts ~`seconds`
    (GIF delays are in 1/100 s; at least 0.1 s, at most 2 s per frame)."""
    n = min(int(n_frames), max_frames)
    if n <= 0:
        return {"frames": 0, "delay_cs": 0, "seconds": 0}
    delay = max(10, min(200, int(round(seconds * 100.0 / n))))
    return {"frames": n, "delay_cs": delay, "seconds": round(n * delay / 100.0, 1)}


def spread(items, n):
    """n items evenly spread over the list (keeps first and last)."""
    if n >= len(items):
        return list(items)
    if n <= 1:
        return items[:1]
    step = (len(items) - 1) / float(n - 1)
    return [items[int(round(i * step))] for i in range(n)]
