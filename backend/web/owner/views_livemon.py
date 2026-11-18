"""livemon: Owner Admin home → "Live health" card. READ-ONLY: shows the last
report written by `manage.py live_monitor` (logs/live_monitor_latest.json) —
Play crash / ANR, own crash reports, server 5xx, signups, DAU/WAU, signup
success, payments, and a red P0 line. Aggregate counts only."""
from django.utils.dateparse import parse_datetime


def _fmt(lang):
    from core.live_monitor import bn

    def num(v):
        if v is None:
            return "—"
        return bn(v) if lang == "bn" else str(v)

    def pct(rate):
        if rate is None:
            return "—"
        s = "%.2f%%" % (rate * 100)
        return bn(s) if lang == "bn" else s
    return num, pct


def live_ctx(lang):
    """{'live': {...}} for the dashboard template, or {'live': None}."""
    from core import live_monitor as LM
    from .i18n import strings
    T = strings(lang)
    rep = LM.latest()
    if not isinstance(rep, dict):
        return {"live": None}
    num, pct = _fmt(lang)
    play = rep.get("play") or {}
    own = rep.get("own_crashes") or {}
    s = rep.get("server") or {}
    u = rep.get("users") or {}
    p = rep.get("payments") or {}
    p0_codes = [f.get("code", "") for f in rep.get("p0") or []]
    tiles = [
        {"k": "lh_crash", "v": pct(play.get("crash_1d")) if play.get("ok") else "—",
         "sub": pct(play.get("crash_7d")) if play.get("ok") else (play.get("skipped") or ""),
         "bad": any(c.startswith("play_crash") for c in p0_codes)},
        {"k": "lh_anr", "v": pct(play.get("anr_1d")) if play.get("ok") else "—",
         "sub": pct(play.get("anr_7d")) if play.get("ok") else "",
         "bad": any(c.startswith("play_anr") for c in p0_codes)},
        {"k": "lh_own", "v": pct(own.get("crash_1d")),
         "sub": num(own.get("user_days_1d")), "bad": "own_crash_1d" in p0_codes},
        {"k": "lh_5xx", "v": num(s.get("errors_5xx")) if s.get("ok") else "—",
         "sub": num(s.get("requests")) if s.get("ok") else "",
         "bad": "server_5xx_spike" in p0_codes},
        {"k": "lh_users", "v": num(u.get("signups_24h")),
         "sub": "%s / %s" % (num(u.get("dau")), num(u.get("wau"))), "bad": False},
        {"k": "lh_signup", "v": pct(u.get("signup_success")),
         "sub": "%s / %s" % (num(u.get("signup_otp_verified")), num(u.get("signup_otp_attempts"))),
         "bad": "signup_broken" in p0_codes or "register_5xx" in p0_codes},
        {"k": "lh_pay", "v": num(p.get("verified")),
         "sub": num((p.get("failed_events") or 0) + (p.get("failed_orders") or 0)),
         "bad": False},
    ]
    for t in tiles:
        t["label"], t["sub_label"] = T[t["k"]], T[t["k"] + "_sub"]
    return {"live": {
        "at": parse_datetime(str(rep.get("generated_at") or "")),
        "tiles": tiles, "p0": p0_codes,
        "p0_labels": [T["lh_p0_" + c] for c in p0_codes],
        "line": rep.get("bn_line", "") if lang == "bn" else "",
        "top_failing": [dict(f, count=num(f.get("count"))) for f in (s.get("top_failing") or [])[:5]],
        "issues": [dict(i, users=num(i.get("users"))) for i in (play.get("top_issues") or [])[:5]],
    }}
