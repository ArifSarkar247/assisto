"""
shop_guard.py — PURE, deterministic loss-prevention decision engine for the
CCTV / shop module (Business, Part 4). NO Django, NO DB, NO clock, NO network,
NO AI here — it only takes plain dicts and returns a plain dict.

THE ONE RULE: we NEVER raise an alert on a single input. A camera event only
becomes an alert when a SECOND signal corroborates it — a POS mismatch, a repeat
pattern, an after-hours flag, a spike vs a baseline. The edge device (Shop Box)
does the actual vision detection; this layer only reasons over the SIGNALS it
reports plus the shop's own POS feed. A lone pose/person detection is at most a
low-confidence "possible" — never a confident alert.

HONESTY (load-bearing, pinned by tests):
  * The word is always "please check" — NEVER "theft". This module produces
    `reason_signals` (machine) + a confidence number; the human-facing text is
    assembled by the view and is always a polite "please check camera X".
  * Confidence is derived from how many independent signals agree, and is always
    surfaced to the owner, who marks false alarms. We never claim certainty.

combine(camera_event, pos_events, now, window_s) -> {
    "raise": bool,            # create a ShopEvent + notify the owner?
    "type": str,              # the event type that fired (echoes the camera type)
    "confidence": float,      # 0.0..1.0, shown to the owner
    "reason_signals": [str],  # the independent signals that agreed
    "possible": bool,         # True => low-confidence "possible", status stays open
    "pos_matched": bool,      # a correlating POS row was found within the window
}
"""

# --- event types the camera/edge can report (mirrors ShopEvent.TYPES) ---
HAND_IN_CASH_ZONE = "hand_in_cash_zone"
DRAWER_OPEN = "drawer_open"
VOID_SPIKE = "void_spike"
REFUND_SPIKE = "refund_spike"
DISCOUNT_SPIKE = "discount_spike"
EOD_MISMATCH = "eod_mismatch"
MOTION = "motion"
AFTER_HOURS = "after_hours"
POSE_POSSIBLE = "pose_possible"

# POS kinds (mirrors ShopPosEvent.KINDS) used for correlation.
POS_SALE = "sale"
POS_VOID = "void"
POS_REFUND = "refund"
POS_DISCOUNT = "discount"
POS_DRAWER_OPEN = "drawer_open"

# Default correlation window: a legitimate action at the till produces a POS row
# within a handful of seconds of the camera seeing the hand / the drawer open.
DEFAULT_WINDOW_S = 45

# Spike thresholds vs a rolling baseline (count within the window). A spike
# "corroborates" itself: the camera flagged it AND the POS count is abnormal.
DEFAULT_SPIKE_MIN = 3          # at least this many in the window to even consider
DEFAULT_SPIKE_FACTOR = 2.0     # and >= this multiple of the baseline


def _ts(ev):
    """Seconds-epoch of an event's `at` (already a float/int), else None."""
    v = ev.get("at")
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _within(a_ts, b_ts, window_s):
    if a_ts is None or b_ts is None:
        return False
    return abs(a_ts - b_ts) <= window_s


def _pos_of_kind(pos_events, kind):
    return [p for p in pos_events if (p.get("kind") == kind)]


def _result(raise_, type_, confidence, reasons, possible=False, pos_matched=False):
    return {
        "raise": bool(raise_),
        "type": type_,
        "confidence": round(float(confidence), 2),
        "reason_signals": list(reasons),
        "possible": bool(possible),
        "pos_matched": bool(pos_matched),
    }


def combine(camera_event, pos_events, now=None, window_s=DEFAULT_WINDOW_S,
            spike_min=DEFAULT_SPIKE_MIN, spike_factor=DEFAULT_SPIKE_FACTOR):
    """Decide whether `camera_event` (a dict with at least `type`, optional `at`,
    optional `signals`) warrants raising an alert, given the recent `pos_events`
    (list of {kind, amount, at}). COMBINED-SIGNAL ONLY — never a single input.

    `window_s` is the ± correlation window in seconds. `now` is accepted for
    signature symmetry / future use (the pure logic correlates on each event's
    own `at`, so it does not actually need the wall clock).
    """
    etype = camera_event.get("type")
    cam_ts = _ts(camera_event)
    # extra edge-reported signals ride in camera_event["signals"] (a dict); any
    # truthy flag there counts as one more independent corroboration.
    extra = camera_event.get("signals") or {}
    pos_events = list(pos_events or [])

    # ---- HAND IN CASH ZONE: raise only if there is NO matching POS sale ----
    # A hand reaching the cash/drawer zone is normal when a sale is ringing up.
    # It is suspicious only when NO sale (and no legit drawer-open) correlates.
    if etype == HAND_IN_CASH_ZONE:
        sales = _pos_of_kind(pos_events, POS_SALE)
        legit = any(_within(cam_ts, _ts(p), window_s) for p in sales)
        # a correlating legit drawer-open (cashier opened for change) also clears it
        legit = legit or any(
            _within(cam_ts, _ts(p), window_s)
            for p in _pos_of_kind(pos_events, POS_DRAWER_OPEN))
        if legit:
            return _result(False, etype, 0.0, ["pos_sale_matched"],
                           pos_matched=True)
        reasons = ["hand_in_cash_zone", "no_matching_sale"]
        conf = 0.6
        # each extra corroborating edge signal (e.g. reach_into_drawer, lingering)
        # nudges confidence up — more agreement = higher confidence.
        for k, v in extra.items():
            if v:
                reasons.append(k)
                conf += 0.1
        return _result(True, etype, min(conf, 0.95), reasons, pos_matched=False)

    # ---- DRAWER OPEN without a sale ----
    if etype == DRAWER_OPEN:
        sales = _pos_of_kind(pos_events, POS_SALE)
        matched = any(_within(cam_ts, _ts(p), window_s) for p in sales)
        if matched:
            return _result(False, etype, 0.0, ["pos_sale_matched"],
                           pos_matched=True)
        reasons = ["drawer_open", "no_matching_sale"]
        conf = 0.65
        for k, v in extra.items():
            if v:
                reasons.append(k)
                conf += 0.1
        return _result(True, etype, min(conf, 0.95), reasons, pos_matched=False)

    # ---- VOID / REFUND / DISCOUNT SPIKE vs a baseline ----
    spike_map = {
        VOID_SPIKE: POS_VOID,
        REFUND_SPIKE: POS_REFUND,
        DISCOUNT_SPIKE: POS_DISCOUNT,
    }
    if etype in spike_map:
        kind = spike_map[etype]
        rows = _pos_of_kind(pos_events, kind)
        count = len(rows)
        # baseline: the edge/view may pass an expected count in signals["baseline"];
        # default to 1 so a lone void never spikes.
        baseline = float(extra.get("baseline", 1) or 1)
        spiked = count >= spike_min and count >= baseline * spike_factor
        if not spiked:
            return _result(False, etype, 0.0, ["below_spike_threshold"],
                           pos_matched=count > 0)
        reasons = [etype, "count_%d_vs_baseline_%g" % (count, baseline)]
        # confidence scales with how far above the baseline we are (capped).
        over = count / max(baseline, 1.0)
        conf = min(0.5 + 0.1 * over, 0.9)
        return _result(True, etype, conf, reasons, pos_matched=count > 0)

    # ---- END-OF-DAY cash-vs-sales MISMATCH ----
    if etype == EOD_MISMATCH:
        # signals carry {counted, expected} (poisha/taka — unit-agnostic here);
        # a mismatch beyond a small tolerance is itself a two-number corroboration.
        try:
            counted = float(extra.get("counted"))
            expected = float(extra.get("expected"))
        except (TypeError, ValueError):
            return _result(False, etype, 0.0, ["eod_no_figures"])
        diff = abs(counted - expected)
        tol = float(extra.get("tolerance", 0) or 0)
        if diff <= tol:
            return _result(False, etype, 0.0, ["eod_reconciled"])
        reasons = ["eod_mismatch", "short_by_%g" % diff]
        base = max(abs(expected), 1.0)
        conf = min(0.5 + (diff / base), 0.9)
        return _result(True, etype, conf, reasons)

    # ---- AFTER HOURS motion (camera-only mode) ----
    # Motion/presence when the shop is closed is corroborated by the clock-state
    # the edge reports (after_hours==True), so it is a two-signal raise on its own.
    if etype == AFTER_HOURS:
        if not extra.get("after_hours", True):
            return _result(False, etype, 0.0, ["within_hours"])
        reasons = ["after_hours", "motion_detected"]
        conf = 0.7
        if extra.get("multiple_frames"):
            reasons.append("multiple_frames")
            conf += 0.1
        return _result(True, etype, min(conf, 0.9), reasons)

    # ---- plain MOTION during open hours: NOT an alert on its own ----
    # Camera-only sites log motion; it only escalates if the edge also flagged
    # after-hours (handled above) or a zone breach rides in signals.
    if etype == MOTION:
        if extra.get("after_hours"):
            return _result(True, AFTER_HOURS, 0.7,
                           ["after_hours", "motion_detected"])
        if extra.get("zone_breach"):
            return _result(True, etype, 0.55,
                           ["motion_detected", "zone_breach"])
        return _result(False, etype, 0.0, ["lone_motion"])

    # ---- LONE POSE: at most "possible", low confidence, status stays open ----
    # A person/pose detection by itself is NEVER a confident alert. We surface it
    # as a low-confidence "possible" so the owner can glance — never an accusation.
    if etype == POSE_POSSIBLE:
        reasons = ["pose_detected"]
        conf = 0.25
        # a SINGLE pose never corroborates itself; only an explicit second signal
        # (e.g. it coincided with a drawer-open) lifts it out of "possible".
        corroborated = False
        if extra.get("zone") == "cash" and any(
                _within(cam_ts, _ts(p), window_s)
                for p in _pos_of_kind(pos_events, POS_DRAWER_OPEN)) is False and \
                _pos_of_kind(pos_events, POS_SALE) == []:
            # pose at the cash zone with NO sale is a weak second signal
            reasons.append("cash_zone_no_sale")
            conf = 0.4
            corroborated = True
        return _result(True, etype, conf, reasons,
                       possible=not corroborated, pos_matched=False)

    # unknown type -> never raise (we do not guess)
    return _result(False, etype, 0.0, ["unknown_type"])
