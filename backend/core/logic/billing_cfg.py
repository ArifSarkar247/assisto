"""billing_cfg — PURE defaults + bounds for the billing-v2 knobs the owner
edits in Owner Admin -> Pricing & plans -> "billing" (owner order 27 Oct).

  unlock_pct            % of a new paid period's plan allowance usable at once
                        (rule I; default 20, 0..100)
  unlock_hours          hours until the rest unlocks (default 48, 0..168)
  refund_window_hours   refund window from each purchase / renewal
                        (rule J; only 24 or 48, default 48)
  profit_guard_min_bdt  per-user Profit Guard alerts only above this cost (৳)
  profit_guard_push     also push the alert to staff (default off)
"""

BOUNDS = {"unlock_pct": (0, 100), "unlock_hours": (0, 168),
          "profit_guard_min_bdt": (0, 100000)}
WINDOWS = (24, 48)


def defaults():
    return {"unlock_pct": 20, "unlock_hours": 48, "refund_window_hours": 48,
            "profit_guard_min_bdt": 20, "profit_guard_push": False}


def _int(v, fb):
    try:
        if isinstance(v, bool):
            return fb
        return int(float(v))
    except (TypeError, ValueError):
        return fb


def normalize(raw):
    d = raw if isinstance(raw, dict) else {}
    base = defaults()
    out = {}
    for k, (lo, hi) in BOUNDS.items():
        out[k] = max(lo, min(hi, _int(d.get(k), base[k])))
    w = _int(d.get("refund_window_hours"), base["refund_window_hours"])
    out["refund_window_hours"] = w if w in WINDOWS else base["refund_window_hours"]
    pv = d.get("profit_guard_push", base["profit_guard_push"])
    out["profit_guard_push"] = pv in (True, 1, "1", "true", "True", "on")
    return out


def problems(raw):
    """Problem codes for an edit (refused, not clamped, so the owner sees it)."""
    if raw is None:
        return []
    if not isinstance(raw, dict):
        return ["bad_billing"]
    out = []
    for k, (lo, hi) in BOUNDS.items():
        if k in raw:
            v = _int(raw.get(k), None)
            if v is None or v < lo or v > hi:
                out.append("bad_billing")
    if "refund_window_hours" in raw and _int(raw.get("refund_window_hours"), None) not in WINDOWS:
        out.append("bad_refund_window")
    return sorted(set(out))
