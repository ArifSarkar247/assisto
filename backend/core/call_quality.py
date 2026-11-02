"""callsbar (owner 2 Nov: "calls to the launch bar") — per-call quality.

Each phone sends ONE report per call when the call ends (what it measured
with WebRTC getStats: worst round-trip, highest loss, worst jitter, the
lowest available send bandwidth, TURN relay used, data used, seconds the
video was paused for a weak network, reconnects, low-data mode) and may add
the person's one-tap rating (good / bad + what went wrong) to the SAME row.

No media and no content ever reaches the server — numbers only.

summary() feeds Owner Admin -> Calls -> "Call quality" (last 7 days): how
many calls were rated bad and why, the measured network numbers, how often
TURN relay / low-data mode / the automatic video pause were needed.
Never raises into a caller.
"""
from __future__ import annotations

import logging
from datetime import timedelta

from django.utils import timezone

log = logging.getLogger(__name__)

RATINGS = ("good", "bad")
ISSUES = ("echo", "choppy", "delay", "video", "dropped", "noise", "other")
NETS = ("wifi", "cellular", "other", "")

# clamp ranges: a broken / hostile client can never store absurd numbers
_MAX_RTT = 60_000
_MAX_JITTER = 10_000
_MAX_KBPS = 1_000_000
_MAX_TALK = 24 * 3600
_MAX_DATA_KB = 4_000_000
_MAX_RECONNECTS = 500


def _int(v, hi, lo=0):
    try:
        if v is None or v == "":
            return None
        n = int(round(float(v)))
    except (TypeError, ValueError):
        return None
    return max(lo, min(hi, n))


def _float(v, hi, lo=0.0):
    try:
        if v is None or v == "":
            return None
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f:  # NaN
        return None
    return max(lo, min(hi, round(f, 2)))


def clean(data):
    """The fields a phone may send, validated + clamped. Unknown keys are
    ignored; a bad rating / issue is dropped (never an error: the metrics
    alone are still worth keeping)."""
    d = data or {}
    out = {}
    r = str(d.get("rating") or "").strip().lower()
    if r in RATINGS:
        out["rating"] = r
        issue = str(d.get("issue") or "").strip().lower()
        out["issue"] = issue if (r == "bad" and issue in ISSUES) else ""
    for b in ("video", "low_data", "relayed"):
        if b in d:
            out[b] = bool(d.get(b)) and str(d.get(b)).lower() not in ("false", "0")
    if "net" in d:
        net = str(d.get("net") or "").strip().lower()
        out["net"] = net if net in NETS else "other"
    for k, hi in (("rtt_ms", _MAX_RTT), ("jitter_ms", _MAX_JITTER),
                  ("min_kbps", _MAX_KBPS)):
        if k in d:
            out[k] = _int(d.get(k), hi)
    if "loss_pct" in d:
        out["loss_pct"] = _float(d.get("loss_pct"), 100.0)
    for k, hi in (("talk_s", _MAX_TALK), ("data_kb", _MAX_DATA_KB),
                  ("video_paused_s", _MAX_TALK),
                  ("reconnects", _MAX_RECONNECTS)):
        if k in d:
            out[k] = _int(d.get(k), hi) or 0
    return out


def record(rec, user, side, data):
    """Create / update THIS user's report for call `rec` (one row per call per
    side; the end-of-call metrics and a later tap merge). Returns the row."""
    from .models import CallQualityReport
    fields = clean(data)
    row, created = CallQualityReport.objects.get_or_create(
        call=rec, user=user, defaults={"side": side or "", **fields})
    if not created and fields:
        for k, v in fields.items():
            setattr(row, k, v)
        row.side = side or row.side
        row.save()
    return row


def as_dict(row):
    return {"id": row.id, "call_id": row.call_id, "rating": row.rating,
            "issue": row.issue, "video": row.video, "low_data": row.low_data,
            "relayed": row.relayed, "data_kb": row.data_kb,
            "talk_s": row.talk_s, "video_paused_s": row.video_paused_s,
            "reconnects": row.reconnects}


def _median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else round((xs[m - 1] + xs[m]) / 2.0, 1)


def summary(days=7, now=None):
    """Owner Admin numbers for the last `days`. Never raises (None on error)."""
    try:
        from .models import CallQualityReport
        now = now or timezone.now()
        rows = list(CallQualityReport.objects.filter(
            created_at__gte=now - timedelta(days=days)).values(
            "rating", "issue", "video", "low_data", "relayed", "net",
            "rtt_ms", "loss_pct", "jitter_ms", "min_kbps", "talk_s",
            "data_kb", "video_paused_s", "reconnects"))
        n = len(rows)
        rated = [r for r in rows if r["rating"]]
        good = sum(1 for r in rated if r["rating"] == "good")
        bad = sum(1 for r in rated if r["rating"] == "bad")
        issues = {}
        for r in rated:
            if r["rating"] == "bad":
                k = r["issue"] or "other"
                issues[k] = issues.get(k, 0) + 1
        talk = sum(r["talk_s"] or 0 for r in rows)
        data_kb = sum(r["data_kb"] or 0 for r in rows)
        voice = [r for r in rows if not r["video"] and (r["talk_s"] or 0) >= 30]
        video = [r for r in rows if r["video"] and (r["talk_s"] or 0) >= 30]

        def kb_min(rs):
            t = sum(r["talk_s"] for r in rs)
            return round(sum(r["data_kb"] for r in rs) * 60.0 / t) if t else None

        def pct(k):
            return round(100.0 * sum(1 for r in rows if r[k]) / n) if n else None

        return {
            "days": days, "reports": n, "rated": len(rated), "good": good,
            "bad": bad,
            "bad_pct": round(100.0 * bad / len(rated)) if rated else None,
            "issues": sorted(issues.items(), key=lambda kv: -kv[1]),
            "rtt_median": _median([r["rtt_ms"] for r in rows]),
            "loss_median": _median([r["loss_pct"] for r in rows]),
            "jitter_median": _median([r["jitter_ms"] for r in rows]),
            "relayed_pct": pct("relayed"), "low_data_pct": pct("low_data"),
            "video_paused_calls": sum(1 for r in rows if r["video_paused_s"]),
            "reconnect_calls": sum(1 for r in rows if r["reconnects"]),
            "talk_min": round(talk / 60.0),
            "data_mb": round(data_kb / 1024.0, 1),
            "voice_kb_min": kb_min(voice), "video_kb_min": kb_min(video),
            "nets": {k: sum(1 for r in rows if (r["net"] or "") == k)
                     for k in ("wifi", "cellular", "other")},
        }
    except Exception:
        log.exception("callsbar: quality summary failed")
        return None
