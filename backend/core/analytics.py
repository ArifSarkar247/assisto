"""
Privacy-friendly product analytics — on OUR OWN backend only (feature: launch
gap B). NO third-party trackers / SDKs. We record anonymous, PII-free events
(a stable hashed user id, an event name from a fixed allow-list, a day-bucket
and a tiny whitelisted props dict) and aggregate them for an owner-admin
dashboard: D1/D7/D30 retention, invites, and the free->paid funnel.

Design rules enforced here:
- Consent first. ingest() drops everything unless the user opted in.
- No PII ever. The user is identified only by an opaque HMAC id (uid_hash),
  never phone/email/name. Event props are filtered against a tiny allow-list
  of scalar, non-identifying keys.
- Event names come from a fixed allow-list (EVENTS); anything else is dropped.
- Aggregation is pure counting over AnalyticsEvent rows — no AI, no guessing.

Integrator wires: AnalyticsEvent model (see MIGRATION NOTE in the handoff),
the ingest endpoint and the owner-admin dashboard endpoint. This module is
pure logic over those rows + inputs, with no network calls.
"""
import hashlib
import hmac
from datetime import date, datetime, timedelta

# Fixed allow-list of event names. The client may only send these; the backend
# drops anything else. Keep in lock-step with the Dart Analytics helper.
EVENTS = {
    # lifecycle
    "app_open",
    "session_start",
    "onboarding_complete",
    # activation / invites / funnel
    "feature_used",
    "invite_sent",
    "invite_accepted",
    "plan_viewed",
    "upgrade_started",
    "upgrade_completed",   # free -> paid conversion
}

# Only these prop keys survive sanitisation, and only as short scalars. None of
# them identify a person. "feature" lets us slice feature_used; "plan"/"source"
# help the funnel; "locale" is bn/en only.
_ALLOWED_PROP_KEYS = {"feature", "plan", "source", "locale", "step"}
_MAX_PROP_LEN = 40


def _hmac_secret():
    """Server secret used to turn a raw user id into an opaque, stable hash.

    FAIL CLOSED (security): there is NO hardcoded fallback. A guessable, shipped
    constant would make every uid_hash attacker-reproducible (an offline table
    of hash(known_user_id) that re-identifies the anonymised analytics store).
    We require a real server secret — ANALYTICS_HMAC_KEY, else Django SECRET_KEY
    — and refuse (raise) if neither is configured, rather than silently using a
    weak key.
    """
    try:
        from django.conf import settings
        secret = (getattr(settings, "ANALYTICS_HMAC_KEY", "")
                  or getattr(settings, "SECRET_KEY", ""))
    except Exception as exc:
        raise RuntimeError(
            "analytics uid_hash requires Django settings with ANALYTICS_HMAC_KEY "
            "or SECRET_KEY; none available"
        ) from exc
    if not secret:
        raise RuntimeError(
            "analytics uid_hash requires ANALYTICS_HMAC_KEY or SECRET_KEY to be "
            "set; refusing to use a guessable fallback key"
        )
    return secret.encode("utf-8")


def uid_hash(user_id):
    """Opaque, stable, non-reversible id for a user. We never store the raw id
    against events, so a leaked analytics table cannot be tied back to a
    person without the server secret."""
    raw = str(user_id if user_id is not None else "anon").encode("utf-8")
    return hmac.new(_hmac_secret(), raw, hashlib.sha256).hexdigest()[:32]


def _sanitize_props(props):
    """Keep only whitelisted keys, coerce to short strings, drop everything
    else. Guarantees no free-text / PII leaks into the event store."""
    out = {}
    if not isinstance(props, dict):
        return out
    for k, v in props.items():
        if k not in _ALLOWED_PROP_KEYS:
            continue
        if isinstance(v, bool):
            out[k] = v
        elif isinstance(v, (int, float)):
            out[k] = v
        elif isinstance(v, str):
            s = v.strip()[:_MAX_PROP_LEN]
            if s:
                out[k] = s
        # anything else (dict/list/None) is dropped
    return out


def normalize_event(user_id, name, props=None, consent=True, day=None):
    """Validate + sanitise one incoming event into a dict ready to persist,
    or None if it must be dropped (no consent / unknown event name).

    The returned dict intentionally contains NO raw user id — only uid_hash.
    """
    if not consent:
        return None
    if name not in EVENTS:
        return None
    d = day or date.today()
    if isinstance(d, datetime):
        d = d.date()
    return {
        "uid_hash": uid_hash(user_id),
        "name": name,
        "day": d.isoformat(),
        "props": _sanitize_props(props),
    }


def ingest(user_id, events, consent=True, day=None):
    """Turn a batch of raw client events into persist-ready rows. Integrator
    saves each returned dict as an AnalyticsEvent. Dropped events are counted
    so the client can be told how many were accepted (but never why, to avoid
    leaking the allow-list as an oracle)."""
    rows = []
    if isinstance(events, dict):
        events = [events]
    for e in events or []:
        if not isinstance(e, dict):
            continue
        row = normalize_event(user_id, e.get("name"),
                              e.get("props"), consent=consent, day=day)
        if row:
            rows.append(row)
    return {"accepted": len(rows), "rows": rows}


# ---------------------------------------------------------------------------
# Aggregation (owner-admin dashboard). Pure counting over event dicts; works on
# AnalyticsEvent querysets too if the integrator maps rows to {uid_hash,name,
# day,props} dicts first (helper _as_dicts below).
# ---------------------------------------------------------------------------

def _as_dicts(events):
    """Accept either dicts (tests) or model rows (production) uniformly."""
    out = []
    for e in events:
        if isinstance(e, dict):
            day = e.get("day")
            out.append({
                "uid_hash": e.get("uid_hash"),
                "name": e.get("name"),
                "day": day if isinstance(day, str) else (
                    day.isoformat() if day else None),
                "props": e.get("props") or {},
            })
        else:
            d = getattr(e, "day", None)
            out.append({
                "uid_hash": getattr(e, "uid_hash", None),
                "name": getattr(e, "name", None),
                "day": d.isoformat() if hasattr(d, "isoformat") else d,
                "props": getattr(e, "props", None) or {},
            })
    return out


def _first_seen(events):
    """uid_hash -> earliest day (as date)."""
    first = {}
    for e in events:
        if e["name"] not in ("app_open", "session_start", "onboarding_complete"):
            continue
        if not e["uid_hash"] or not e["day"]:
            continue
        d = date.fromisoformat(e["day"])
        cur = first.get(e["uid_hash"])
        if cur is None or d < cur:
            first[e["uid_hash"]] = d
    return first


def retention(events):
    """D1/D7/D30 retention: of users whose first-seen day was >= N days ago,
    what fraction returned (had any open/session event) exactly N days after
    their first-seen day. Classic cohort retention, computed with no PII."""
    evs = _as_dicts(events)
    first = _first_seen(evs)

    # Set of (uid_hash, day) that count as a "return/active" signal.
    active = set()
    for e in evs:
        if e["name"] in ("app_open", "session_start") and e["uid_hash"] and e["day"]:
            active.add((e["uid_hash"], e["day"]))

    def _ret(n):
        eligible = 0
        returned = 0
        for uid, f in first.items():
            target = f + timedelta(days=n)
            eligible += 1
            if (uid, target.isoformat()) in active:
                returned += 1
        pct = round(100.0 * returned / eligible, 1) if eligible else 0.0
        return {"eligible": eligible, "returned": returned, "pct": pct}

    return {"d1": _ret(1), "d7": _ret(7), "d30": _ret(30),
            "new_users": len(first)}


def invites(events):
    """Invite funnel: sent -> accepted, plus acceptance rate."""
    evs = _as_dicts(events)
    sent = sum(1 for e in evs if e["name"] == "invite_sent")
    accepted = sum(1 for e in evs if e["name"] == "invite_accepted")
    rate = round(100.0 * accepted / sent, 1) if sent else 0.0
    return {"sent": sent, "accepted": accepted, "accept_rate_pct": rate}


def paid_funnel(events):
    """Free -> paid funnel: plan_viewed -> upgrade_started -> upgrade_completed,
    counted by distinct users at each step so one user can't inflate a stage."""
    evs = _as_dicts(events)
    stage_users = {"plan_viewed": set(), "upgrade_started": set(),
                   "upgrade_completed": set()}
    for e in evs:
        if e["name"] in stage_users and e["uid_hash"]:
            stage_users[e["name"]].add(e["uid_hash"])
    viewed = len(stage_users["plan_viewed"])
    started = len(stage_users["upgrade_started"])
    completed = len(stage_users["upgrade_completed"])

    def _pct(num, den):
        return round(100.0 * num / den, 1) if den else 0.0

    return {
        "viewed": viewed,
        "started": started,
        "completed": completed,
        "view_to_start_pct": _pct(started, viewed),
        "start_to_paid_pct": _pct(completed, started),
        "view_to_paid_pct": _pct(completed, viewed),
    }


def _day_span(events):
    """(min_day, max_day) as dates over all events that carry a day, else
    (None, None). Used to build dense daily trend series with honest gaps."""
    days = [date.fromisoformat(e["day"]) for e in events if e["day"]]
    if not days:
        return None, None
    return min(days), max(days)


def active_users(events, window_days=30):
    """DAU / WAU / MAU plus a dense daily-active-users trend series.

    "Active" = any app_open / session_start on a day. DAU is the most recent
    day in the data; WAU / MAU are distinct users active within the trailing
    7 / 30 day windows ending on that most-recent day. The `series` is a dense
    list of {day, users} for the trailing `window_days` (zero-filled so the
    client can draw an honest sparkline with real gaps, never interpolated).

    All counts are distinct uid_hash — PII-free. If there is no activity we
    return zeros and an empty series so the client shows a "no data yet" state
    rather than a fabricated line."""
    evs = _as_dicts(events)
    # uid_hash active on each day.
    by_day = {}
    for e in evs:
        if e["name"] not in ("app_open", "session_start"):
            continue
        if not e["uid_hash"] or not e["day"]:
            continue
        by_day.setdefault(e["day"], set()).add(e["uid_hash"])

    if not by_day:
        return {"dau": 0, "wau": 0, "mau": 0, "series": []}

    last = max(date.fromisoformat(d) for d in by_day)

    def _window(n):
        seen = set()
        for i in range(n):
            day = (last - timedelta(days=i)).isoformat()
            seen |= by_day.get(day, set())
        return len(seen)

    dau = len(by_day.get(last.isoformat(), set()))
    wau = _window(7)
    mau = _window(30)

    # Dense trailing series (oldest -> newest) for the sparkline.
    series = []
    for i in range(window_days - 1, -1, -1):
        day = (last - timedelta(days=i)).isoformat()
        series.append({"day": day, "users": len(by_day.get(day, set()))})

    return {"dau": dau, "wau": wau, "mau": mau, "series": series}


def daily_series(events, name_set, window_days=30):
    """Dense trailing per-day COUNT series for a set of event names (e.g. new
    signups). Zero-filled, oldest -> newest. Honest: real zeros, no smoothing."""
    evs = _as_dicts(events)
    by_day = {}
    for e in evs:
        if e["name"] in name_set and e["day"]:
            by_day[e["day"]] = by_day.get(e["day"], 0) + 1
    if not by_day:
        return []
    last = max(date.fromisoformat(d) for d in by_day)
    out = []
    for i in range(window_days - 1, -1, -1):
        day = (last - timedelta(days=i)).isoformat()
        out.append({"day": day, "count": by_day.get(day, 0)})
    return out


# Owner-configurable monthly price per plan (minor currency unit agnostic — the
# number is whatever the owner sets). We NEVER invent revenue: if a plan has no
# configured price, its revenue is reported as null (client shows an estimate /
# unknown badge instead of a fabricated figure).
def revenue_by_plan(events, price_map=None):
    """Plan breakdown of PAID users (distinct uid_hash with upgrade_completed),
    grouped by the sanitised `plan` prop. Revenue is counts x configured price;
    when a price is unknown it stays null so nothing is fabricated.

    Returns {"plans": [{"plan","paid_users","price","revenue"}...],
             "total_paid_users": int, "total_revenue": int|null,
             "revenue_known": bool}. total_revenue is null unless EVERY present
    plan has a configured price (otherwise any sum would be a guess)."""
    evs = _as_dicts(events)
    price_map = price_map or {}
    by_plan = {}
    for e in evs:
        if e["name"] != "upgrade_completed" or not e["uid_hash"]:
            continue
        plan = (e["props"] or {}).get("plan") or "unspecified"
        by_plan.setdefault(plan, set()).add(e["uid_hash"])

    plans = []
    total_users = 0
    total_rev = 0
    all_priced = True
    for plan in sorted(by_plan, key=lambda p: (-len(by_plan[p]), p)):
        users = len(by_plan[plan])
        total_users += users
        price = price_map.get(plan)
        if price is None:
            all_priced = False
            rev = None
        else:
            rev = users * price
            total_rev += rev
        plans.append({"plan": plan, "paid_users": users,
                      "price": price, "revenue": rev})

    revenue_known = bool(plans) and all_priced
    return {
        "plans": plans,
        "total_paid_users": total_users,
        "total_revenue": total_rev if revenue_known else None,
        "revenue_known": revenue_known,
    }


def feature_usage(events, top=10):
    """Most-used features (from feature_used events' 'feature' prop), by distinct
    users — a privacy-safe popularity ranking for the owner dashboard."""
    evs = _as_dicts(events)
    by_feature = {}
    for e in evs:
        if e["name"] != "feature_used":
            continue
        f = (e["props"] or {}).get("feature")
        if not f or not e["uid_hash"]:
            continue
        by_feature.setdefault(f, set()).add(e["uid_hash"])
    ranked = sorted(((f, len(u)) for f, u in by_feature.items()),
                    key=lambda x: (-x[1], x[0]))
    return [{"feature": f, "users": n} for f, n in ranked[:top]]


def dashboard(events, price_map=None, window_days=30):
    """One call the owner-admin view can render. Pure aggregation, no PII.

    ADVANCED payload (superset of the original — all existing keys preserved so
    the signature stays `dashboard(rows)`-compatible for the unchanged view):
      - active:        DAU / WAU / MAU + dense daily-active trend series
      - signups_series: dense daily new-signup counts (trend sparkline)
      - revenue:       plan breakdown; revenue null unless priced (no guessing)
      - range:         {start, end} actual day span of the data (honest window)
    Everything is distinct-user / count aggregation; no names, phones, emails.
    `price_map` is owner-configured ({plan: monthly_price}); omit it and revenue
    is reported as unknown rather than fabricated."""
    evs = _as_dicts(events)
    start, end = _day_span(evs)
    return {
        "retention": retention(evs),
        "invites": invites(evs),
        "paid_funnel": paid_funnel(evs),
        "top_features": feature_usage(evs),
        "active": active_users(evs, window_days=window_days),
        "signups_series": daily_series(
            evs,
            ("onboarding_complete",),
            window_days=window_days,
        ),
        "revenue": revenue_by_plan(evs, price_map=price_map),
        "range": {
            "start": start.isoformat() if start else None,
            "end": end.isoformat() if end else None,
        },
        "total_events": len(evs),
    }
