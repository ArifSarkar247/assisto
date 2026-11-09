"""fcscreen (Family Care v3, owner order 9 Nov 10:50) — PURE member status rules.

The owner's rule: "NEVER give false comfort: green only when fresh data proves
it". Everything here is a pure function of (brain dict, now, flags) so the
same case table (core/testdata/fc_status_cases.json) drives both the Python
tests and the Dart mirror (app/lib/family_v3/fc_status.dart).

States, strongest first:  sos (red) > paused > stale (gray, dashed card)
                          > check (amber) > ok (green).
GREEN only when: a last_seen exists, it is not in the future by more than
CLOCK_SKEW_S, now - last_seen <= interval, no amber flag, and the battery is
not low while unplugged. Unknown == never green.
"""
from datetime import datetime, timedelta, timezone as _tz

DEFAULT_INTERVAL_S = 3 * 3600
MIN_INTERVAL_S = 15 * 60
MAX_INTERVAL_S = 24 * 3600
CLOCK_SKEW_S = 5 * 60
LOW_BATTERY = 15
DEAD_BATTERY = 5

STATES = ("sos", "paused", "stale", "check", "ok")
RANK = {s: i for i, s in enumerate(STATES)}          # lower = more urgent
AMBER_FLAGS = ("watch", "carecall_missed", "journey_overdue")


def parse_ts(v):
    """ISO string / datetime / epoch seconds -> aware UTC datetime or None."""
    if v is None or v == "":
        return None
    try:
        if isinstance(v, datetime):
            d = v
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            d = datetime.fromtimestamp(float(v), tz=_tz.utc)
        else:
            s = str(v).strip()
            if s.endswith("Z"):
                s = s[:-1] + "+00:00"
            d = datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=_tz.utc)
        return d.astimezone(_tz.utc)
    except (ValueError, TypeError, OverflowError, OSError):
        return None


def clamp_interval(v):
    try:
        n = int(v)
    except (TypeError, ValueError):
        return DEFAULT_INTERVAL_S
    if n <= 0:
        return DEFAULT_INTERVAL_S
    return max(MIN_INTERVAL_S, min(MAX_INTERVAL_S, n))


def _int(v):
    try:
        if v is None or isinstance(v, bool):
            return None
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _iso(d):
    return d.astimezone(_tz.utc).isoformat().replace("+00:00", "Z") if d else None


def member_status(brain, now, flags=None):
    """-> {"state", "reason", "fresh_until", "age_s"}.

    brain: last_seen, battery, charging, net, bg_restricted, paused_until,
           interval_s (see owner_actions/FAMILY_CARE_V3_API.md §3).
    flags: sos, watch, carecall_missed, journey_overdue (bools), amber_reason (str).
    """
    brain = brain if isinstance(brain, dict) else {}
    flags = flags if isinstance(flags, dict) else {}
    now = parse_ts(now) or datetime.now(_tz.utc)
    seen = parse_ts(brain.get("last_seen"))
    interval = clamp_interval(brain.get("interval_s"))
    fresh_until = seen + timedelta(seconds=interval) if seen else None
    age = int((now - seen).total_seconds()) if seen else None
    out = {"state": "stale", "reason": "never", "fresh_until": None, "age_s": age}

    if flags.get("sos"):
        out.update(state="sos", reason="sos", fresh_until=None)
        return out

    paused = parse_ts(brain.get("paused_until"))
    if paused and paused > now:
        out.update(state="paused", reason="paused", fresh_until=None)
        return out

    if seen is None:
        return out
    if age < -CLOCK_SKEW_S:
        out.update(reason="clock")
        return out
    battery = _int(brain.get("battery"))
    charging = brain.get("charging") is True
    if now > fresh_until:
        if battery is not None and battery <= DEAD_BATTERY and not charging:
            reason = "battery_off"
        elif str(brain.get("net") or "") == "none":
            reason = "no_internet"
        else:
            # bg_restricted reported, or nothing else explains the silence:
            # the most common cause on Xiaomi/Realme/Oppo/Vivo/Tecno/Infinix.
            reason = "background_killed"
        out.update(state="stale", reason=reason, fresh_until=_iso(fresh_until))
        return out

    out["fresh_until"] = _iso(fresh_until)
    for f in AMBER_FLAGS:
        if flags.get(f):
            out.update(state="check", reason=f)
            return out
    if flags.get("amber_reason"):
        out.update(state="check", reason=str(flags["amber_reason"])[:24])
        return out
    if battery is not None and battery <= LOW_BATTERY and not charging:
        out.update(state="check", reason="battery_low")
        return out
    out.update(state="ok", reason="ok")
    return out


def family_line(rows):
    """rows: [{"user_id", "name", "state", "reason"}] for OTHER members (not the
    viewer). -> {"state": sos|check|stale|ok|empty, "reason", "name", "user_id",
    "count"}. Green only when there is at least one member and all are ok."""
    rows = [r for r in (rows or []) if isinstance(r, dict)]
    if not rows:
        return {"state": "empty", "reason": "", "name": "", "user_id": None, "count": 0}
    for want in ("sos", "check", "stale", "paused"):
        hit = [r for r in rows if r.get("state") == want]
        if hit:
            r = hit[0]
            return {"state": "stale" if want == "paused" else want,
                    "reason": r.get("reason") or "", "name": r.get("name") or "",
                    "user_id": r.get("user_id"), "count": len(hit)}
    if all(r.get("state") == "ok" for r in rows):
        return {"state": "ok", "reason": "ok", "name": "", "user_id": None,
                "count": len(rows)}
    r = next(x for x in rows if x.get("state") != "ok")   # unknown -> never green
    return {"state": "stale", "reason": "never", "name": r.get("name") or "",
            "user_id": r.get("user_id"), "count": 1}


def sort_key(row):
    """Alerts first: sos, check, stale, paused, ok; then name."""
    order = {"sos": 0, "check": 1, "stale": 2, "paused": 3, "ok": 4}
    return (order.get((row.get("status") or {}).get("state"), 2),
            (row.get("label") or row.get("name") or "").lower())
