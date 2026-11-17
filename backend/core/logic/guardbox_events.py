"""gboxlinux — power-cut and internet-down events reported by a Guard Box
(Linux / Raspberry Pi / Windows; edge/shopbox/shopbox/boxstate.py) on its
heartbeat. PURE: cleaning + the owner's Bangla / English text. The view
(phonecam_views.note_box_events) de-duplicates and notifies.

Wire form (at most 10 per heartbeat):
  {"id": "a1b2c3", "kind": "power_back"|"power_cut"|"net_back",
   "from": epoch, "to": epoch|null, "queued_alerts": n, "after_reboot": bool,
   "on_battery": bool, "battery_pct": n|null}
"""
from datetime import datetime, timezone as dtz

KINDS = ("power_back", "power_cut", "net_back")
MAX_PER_BEAT = 10
MAX_AGE_S = 8 * 86400
TZ = "Asia/Dhaka"
_BN = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn_digits(s):
    return str(s).translate(_BN)


def _num(v):
    try:
        if isinstance(v, bool):
            return None
        return float(v)
    except (TypeError, ValueError):
        return None


def clean(raw, now_ts):
    """-> list of clean events (bad rows dropped). Never raises."""
    out = []
    if not isinstance(raw, list):
        return out
    for r in raw[:MAX_PER_BEAT]:
        if not isinstance(r, dict) or r.get("kind") not in KINDS:
            continue
        eid = "".join(ch for ch in str(r.get("id") or "") if ch.isalnum())[:24]
        start = _num(r.get("from"))
        if not eid or start is None or not (now_ts - MAX_AGE_S <= start <= now_ts + 300):
            continue
        end = _num(r.get("to"))
        if r["kind"] != "power_cut":
            if end is None or end > now_ts + 300:
                end = min(now_ts, max(start, end or now_ts))
            end = max(start, end)
        else:
            end = None
        q = _num(r.get("queued_alerts"))
        pct = _num(r.get("battery_pct"))
        out.append({"id": eid, "kind": r["kind"], "from": start, "to": end,
                    "minutes": None if end is None else int(round((end - start) / 60.0)),
                    "queued_alerts": int(q) if q is not None and 0 <= q <= 100000 else 0,
                    "after_reboot": r.get("after_reboot") is True,
                    "on_battery": r.get("on_battery") is True,
                    "battery_pct": int(pct) if pct is not None and 0 <= pct <= 100 else None})
    return out


def _clock(ts, tzname=TZ, ref=None):
    try:
        from zoneinfo import ZoneInfo
        tz = ZoneInfo(tzname or TZ)
    except Exception:
        tz = dtz.utc
    d = datetime.fromtimestamp(ts, tz=tz)
    hm = d.strftime("%H:%M")
    if ref is not None and datetime.fromtimestamp(ref, tz=tz).date() != d.date():
        hm = d.strftime("%d/%m ") + hm
    return hm


def text(ev, site_name, tzname=TZ, now_ts=None):
    """(title_bn, title_en, body_bn, body_en) for one clean event."""
    name = site_name or "Guard Box"
    k = ev["kind"]
    t_from = _clock(ev["from"], tzname, now_ts)
    if k == "power_cut":
        pct = ev.get("battery_pct")
        pbn = (" (চার্জ %s%%)" % bn_digits(pct)) if pct is not None else ""
        pen = (" (%d%% charge)" % pct) if pct is not None else ""
        return ("বিদ্যুৎ চলে গেছে — %s" % name, "Power cut — %s" % name,
                "%s থেকে বিদ্যুৎ নেই। পাহারা বক্স এখন ব্যাটারি/ইউপিএস-এ চলছে%s; চার্জ শেষ হলে পাহারা বন্ধ হবে।"
                % (bn_digits(t_from), pbn),
                "No mains power since %s. The Guard Box is running on battery / UPS%s; "
                "guarding stops when it runs out." % (t_from, pen))
    t_to = _clock(ev["to"], tzname, now_ts)
    mins = ev.get("minutes") or 0
    if k == "power_back":
        if ev.get("on_battery"):
            return ("বিদ্যুৎ ফিরেছে — %s" % name, "Power is back — %s" % name,
                    "%s মিনিট পর বিদ্যুৎ ফিরেছে (%s–%s)। এই সময় বক্স ব্যাটারি/ইউপিএস-এ পাহারা দিয়েছে।"
                    % (bn_digits(mins), bn_digits(t_from), bn_digits(t_to)),
                    "Power returned after %d minutes (%s–%s). The box kept guarding on battery / UPS."
                    % (mins, t_from, t_to))
        return ("বিদ্যুৎ ফিরেছে — %s" % name, "Power is back — %s" % name,
                "পাহারা বক্স প্রায় %s মিনিট বন্ধ ছিল (%s–%s) — সম্ভবত বিদ্যুৎ চলে গিয়েছিল। "
                "এই সময়ে ক্যামেরা পাহারা পায়নি; এখন আবার পাহারা চলছে। একটি ইউপিএস দিলে পাহারা বন্ধ হবে না।"
                % (bn_digits(mins), bn_digits(t_from), bn_digits(t_to)),
                "The Guard Box was off for about %d minutes (%s–%s) — most likely a power cut. "
                "Cameras were not guarded then; guarding is back on now. A small UPS keeps it guarding."
                % (mins, t_from, t_to))
    n = ev.get("queued_alerts") or 0
    if n:
        tail_bn = "এই সময়ের %sটি সতর্কতা এখন আসছে।" % bn_digits(n)
        tail_en = "%d alert%s from that time %s arriving now." % (n, "" if n == 1 else "s",
                                                               "is" if n == 1 else "are")
    else:
        tail_bn = "এই সময়ে বক্স পাহারা দিয়েছে; কোনো সতর্কতা হয়নি।"
        tail_en = "The box kept guarding; there were no alerts."
    return ("ইন্টারনেট ফিরেছে — %s" % name, "Internet is back — %s" % name,
            "%s–%s (%s মিনিট) ইন্টারনেট ছিল না। %s" % (bn_digits(t_from), bn_digits(t_to),
                                                     bn_digits(mins), tail_bn),
            "No internet from %s to %s (%d min). %s" % (t_from, t_to, mins, tail_en))
