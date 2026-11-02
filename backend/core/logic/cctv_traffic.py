"""cctvguard (owner CCTV order G, 3 Nov): pure traffic-meter + relay-cap logic.

What is measured, per account and per camera, per calendar month (Asia/Dhaka):
  * relay bytes  — our WebRTC live view through OUR TURN relay (costs us);
                   client-reported (getStats of the selected candidate pair),
                   capped server-side at seconds x MAX_LIVE_BYTES_S so a buggy
                   or hostile client can never inflate or poison the meter.
  * direct bytes — the same, when the pair is host/srflx (P2P or same Wi-Fi):
                   free for us, shown so the user sees "direct is unlimited".
  * vendor       — Imou / EZVIZ cloud live (HLS): seconds watched and an
                   ESTIMATE of bytes = bitrate x seconds (SD / HD), always
                   labelled "estimate" — the vendor bill is the truth.
  * turn_bytes   — what coturn itself logged for this account's relayed live
                   sessions (closed-session 'usage' lines, core.turn_monitor):
                   account-level only, used as a floor for the account total.

Enforcement (only when cctv_plan.limits_owner_confirmed is ON):
  per camera, relay MB this month vs relay_mb_per_camera:
    < 80 %  -> "ok"
    >= 80 % -> "notice"  (gentle Bangla note, relay still on)
    >= 100% -> "paused"  (relay live off; P2P / LAN keep working)
  An active SOS / fall alert of the viewer or the camera owner -> never paused.
Everything here is pure (plain values in, plain values out) for the tests.
"""
import math

# A relayed live view never carries more than HD 1.5 Mbps video + overhead;
# 2.5 Mbps = 312,500 B/s is the hard ceiling we accept per second of session.
MAX_LIVE_BYTES_S = 312_500
SLACK_BYTES = 256 * 1024                # ICE / DTLS handshakes
# Vendor HLS bitrates used for the ESTIMATE (Imou/EZVIZ sub vs main stream)
VENDOR_KBPS = {"sd": 512, "hd": 2048}
VENDOR_IDLE_S = 300                     # order G: 5 minutes without a touch
VENDOR_MAX_S = 1800                     # one vendor live view, hard cap
NOTICE_PCT = 80
PAUSE_PCT = 100
PATHS = ("relay", "direct", "lan", "unknown")
KEEP_SESSIONS = 60                      # per-month row: last N session ids


def month_key(dt):
    """'YYYY-MM' of an aware datetime in Dhaka time (UTC+6, no DST)."""
    from datetime import timedelta
    return (dt + timedelta(hours=6)).strftime("%Y-%m") if dt.tzinfo else \
        dt.strftime("%Y-%m")


def _int(v):
    try:
        if isinstance(v, bool):
            return 0
        x = float(v)
        return int(x) if math.isfinite(x) and x > 0 else 0
    except (TypeError, ValueError):
        return 0


def sane_bytes(total_bytes, seconds):
    """Clamp a client-reported cumulative byte count to what `seconds` of
    live video can physically carry."""
    b, s = _int(total_bytes), _int(seconds)
    return min(b, s * MAX_LIVE_BYTES_S + SLACK_BYTES)


def norm_path(p):
    p = str(p or "").strip().lower()
    return p if p in PATHS else "unknown"


def vendor_estimate_bytes(seconds, hd=False):
    return int(_int(seconds) * VENDOR_KBPS["hd" if hd else "sd"] * 1000 / 8)


def empty_cam():
    return {"relay_bytes": 0, "direct_bytes": 0, "live_s": 0, "relay_s": 0,
            "vendor_s": 0, "vendor_est_bytes": 0, "vendor_hd_s": 0}


def add_live(doc, cam_id, sid, total_bytes, seconds, path):
    """Fold one live session's CUMULATIVE report into the month doc.
    Only the increase since the session's last report is added, so reports
    can repeat (every minute + at the end) without double counting. A session
    that was relayed once stays relayed (its later bytes count as relay).
    Returns (doc, added_relay_bytes, added_direct_bytes)."""
    doc = dict(doc or {})
    cams = dict(doc.get("cams") or {})
    sess = dict(doc.get("sess") or {})
    key = str(cam_id)
    c = dict(empty_cam(), **(cams.get(key) or {}))
    s = dict(sess.get(str(sid)) or {"b": 0, "s": 0, "relay": False})
    path = norm_path(path)
    b = sane_bytes(total_bytes, seconds)
    secs = _int(seconds)
    relay = bool(s.get("relay")) or path == "relay"
    db = max(0, b - _int(s.get("b")))
    ds = max(0, secs - _int(s.get("s")))
    add_r = db if relay else 0
    add_d = 0 if relay else db
    c["relay_bytes"] += add_r
    c["direct_bytes"] += add_d
    c["live_s"] += ds
    if relay:
        c["relay_s"] += ds
    s = {"b": max(b, _int(s.get("b"))), "s": max(secs, _int(s.get("s"))),
         "relay": relay, "cam": key}
    sess[str(sid)] = s
    if len(sess) > KEEP_SESSIONS:
        for k in sorted(sess, key=lambda x: _int(x) if str(x).isdigit() else 0)[
                :len(sess) - KEEP_SESSIONS]:
            sess.pop(k, None)
    cams[key] = c
    doc["cams"], doc["sess"] = cams, sess
    return doc, add_r, add_d


def add_vendor(doc, cam_id, seconds, hd=False):
    doc = dict(doc or {})
    cams = dict(doc.get("cams") or {})
    key = str(cam_id)
    c = dict(empty_cam(), **(cams.get(key) or {}))
    secs = min(_int(seconds), VENDOR_MAX_S)
    c["vendor_s"] += secs
    if hd:
        c["vendor_hd_s"] += secs
    c["vendor_est_bytes"] += vendor_estimate_bytes(secs, hd)
    cams[key] = c
    doc["cams"] = cams
    return doc


def vendor_seconds(start_ts, last_touch_ts, now_ts, reported, idle_s=VENDOR_IDLE_S):
    """Seconds of a vendor live view we accept: never more than the wall
    span, never past the idle stop after the last touch, never past the
    hard cap — whatever the client reports."""
    start, last, now = float(start_ts), float(last_touch_ts or start_ts), float(now_ts)
    stop = min(now, last + idle_s, start + VENDOR_MAX_S)
    wall = max(0, int(stop - start))
    rep = _int(reported)
    return min(rep, wall) if rep else wall


def cap_state(used_bytes, cap_mb, confirmed):
    """-> {"level", "pct", "cap_bytes", "used_bytes", "enforced"}."""
    cap = max(0, _int(cap_mb)) * 1000 * 1000
    used = _int(used_bytes)
    pct = int(math.floor(100.0 * used / cap)) if cap else 0
    if not confirmed:
        level = "off"
    elif cap == 0 or pct >= PAUSE_PCT:
        level = "paused"
    elif pct >= NOTICE_PCT:
        level = "notice"
    else:
        level = "ok"
    return {"level": level, "pct": pct, "cap_bytes": cap, "used_bytes": used,
            "enforced": bool(confirmed)}


def gate(state, emergency=False):
    """Relay allowed for a NEW live view? Emergency always wins."""
    if emergency:
        return True
    return state.get("level") != "paused"


def account_relay_bytes(doc):
    """Account total of PAID live traffic: our TURN relay (per-camera client
    sums, never below what coturn itself logged) + the vendor-cloud live
    estimate (Imou/EZVIZ cloud HLS is always relayed by the vendor and
    billed per GB). P2P / same-Wi-Fi bytes never count."""
    cams = (doc or {}).get("cams") or {}
    client = sum(_int((c or {}).get("relay_bytes")) for c in cams.values())
    vendor = sum(_int((c or {}).get("vendor_est_bytes")) for c in cams.values())
    return max(client, _int((doc or {}).get("turn_bytes"))) + vendor


BN_DIGITS = str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯")


def bn(x):
    return str(x).translate(BN_DIGITS)


def mb(b):
    return round(_int(b) / 1_000_000.0, 1)


def messages(level, pct, lang="bn"):
    """The honest notice for a level ('' when none). Bangla first."""
    if level == "notice":
        if lang == "bn":
            return ("এই ক্যামেরার রিলে-লাইভ সীমার %s%% এই মাসে ব্যবহার হয়েছে। "
                    "একই Wi-Fi-তে বা সরাসরি সংযোগে দেখলে সীমা খরচ হয় না।" % bn(pct))
        return ("%d%% of this camera's relay live allowance is used this month. "
                "Watching on the same Wi-Fi or a direct connection does not use it." % pct)
    if level == "paused_vendor":
        if lang == "bn":
            return ("এই মাসের ক্লাউড-লাইভ সীমা শেষ — ক্যামেরা কোম্পানির ক্লাউড দিয়ে লাইভ এখন বন্ধ। "
                    "একই Wi-Fi-তে ক্যামেরার নিজের অ্যাপে দেখা যাবে; সতর্কতা ও ছবি আগের মতো চলবে।")
        return ("This month's cloud live allowance is used up — live view through the "
                "camera maker's cloud is paused. It still works on the same Wi-Fi in the "
                "camera's own app; alerts and photos keep working.")
    if level == "paused":
        if lang == "bn":
            return ("এই মাসের রিলে-লাইভ সীমা শেষ — রিলে দিয়ে লাইভ এখন বন্ধ। "
                    "একই Wi-Fi-তে বা সরাসরি সংযোগে দেখা যাবে; সতর্কতা ও ছবি আগের মতো চলবে।")
        return ("This month's relay live allowance is used up — live view through "
                "the relay is paused. It still works on the same Wi-Fi or a direct "
                "connection; alerts and photos keep working.")
    return ""


def pool_mb(per_camera_mb, n_cameras):
    """The relay allowance is pooled per account (CCTV_DEVICES_COST_BN.md
    section gha): cameras x per-camera MB, at least one camera's worth."""
    return max(0, _int(per_camera_mb)) * max(1, _int(n_cameras))


def summary_rows(doc, cam_names):
    """App / admin view: one row per camera."""
    cams = (doc or {}).get("cams") or {}
    rows = []
    for cid, name in cam_names:
        c = dict(empty_cam(), **(cams.get(str(cid)) or {}))
        rows.append({"camera": cid, "name": name,
                     "live_min": int(math.ceil((c["live_s"] + c["vendor_s"]) / 60.0)),
                     "relay_min": int(math.ceil(c["relay_s"] / 60.0)),
                     "relay_mb": mb(c["relay_bytes"]), "direct_mb": mb(c["direct_bytes"]),
                     "vendor_min": int(math.ceil(c["vendor_s"] / 60.0)),
                     "vendor_est_mb": mb(c["vendor_est_bytes"])})
    return rows
