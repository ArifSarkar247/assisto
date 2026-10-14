"""
price_radar.py — pure, deterministic MARKET PRICE RADAR math (#34, SPEC v2.1
§21, ADVANCED).

A manual price tracker for items the user cares about (bazar goods, building
materials, …). The user LOGS prices themselves: one entry per (item, ৳, date,
market). This module computes, per item, a trend over the user's OWN logged
prices: latest price, high / low / average, and the % change between the two
most recent logs. It is PURE, like money_engine.py / in_chat_ai.py: no Django,
no DB, no network, **no AI**, no clock, no external feed. Same inputs → same
output, so the on-device Dart mirror matches offline and the tests pin it.

NO FABRICATION — ONLY THE USER'S LOGGED PRICES
----------------------------------------------
We NEVER invent, scrape, or guess a market price. Every number returned is
computed from the prices the user themselves logged. With one log we can show
the latest price but cannot show a trend/%-change (and say so honestly). With
zero logs for an item it simply does not appear.

HONEST LIVE-FEED SEAM (KEY-GATED)
---------------------------------
A real-time market/bazar price feed is a DOCUMENTED seam only: `feed_seam()`
returns {required, mock, query_shape} describing what a live-feed route would
look like. Nothing here calls a feed; `live_required=True` is the honest
"connect a market-data key for live prices" state. There is NO price-feed key in
the Integrations REGISTRY yet — the integrator adds one when a real provider is
chosen; until then this manual tracker is the whole, honest feature.

MONEY
-----
All money is INTEGER POISHA (mirror of the Dart `_RMath`): `to_minor`
"42.50"→4250, `fmt_bdt` 4250→"৳42.50". % change is a signed number (one
decimal) derived from the two latest logs. Holds no money.

Hand-verified in price_radar_tests_snippets.py.
"""

MARKER_KEY = "price_manual"            # "your logged prices — not a live feed"
# A unit is a stable slug the UI localises (kg, litre, piece, dozen, …). We
# never do unit conversion — a trend is only meaningful within ONE unit, so
# items are keyed by (name, unit) and we warn when a single name mixes units.
UNITS = ("kg", "g", "litre", "ml", "piece", "dozen", "bag", "other")


# ------------------------------------------------------------------ money

def to_minor(v):
    """Parse str/int/float/None money → integer poisha. '42.50'→4250, junk→0.
    Never raises. Mirrors the app-wide money parse."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(round(v * 100))
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, _, frac = s.partition(".")
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    if not (whole.isdigit() and frac.isdigit()):
        return 0
    minor = int(whole) * 100 + int(frac) // 10
    if int(frac) % 10 >= 5:
        minor += 1
    return -minor if neg else minor


def _group(n):
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


def fmt_bdt(poisha):
    """Integer poisha → '৳42.50' (৳ is a currency glyph)."""
    neg = poisha < 0
    poisha = abs(int(poisha))
    taka, paisa = poisha // 100, poisha % 100
    return ("-" if neg else "") + "৳" + _group(taka) + "." + f"{paisa:02d}"


def _pct_change(old, new):
    """Signed % change old→new, one decimal, as a float. 0.0 when old<=0."""
    if old is None or old <= 0:
        return 0.0
    return round((new - old) * 1000.0 / old) / 10.0


# ------------------------------------------------------------------ keys

def _unit(v):
    u = (v or "other")
    if not isinstance(u, str):
        u = str(u)
    u = u.strip().lower() or "other"
    return u if u in UNITS else "other"


def item_key(name, unit):
    """Stable grouping key for an item at a unit. Case-insensitive on name so
    'Rice' and 'rice' group together; unit normalised to a known slug."""
    nm = (name or "").strip()
    return (nm.lower(), _unit(unit)), nm


# ------------------------------------------------------------------ trend

def item_trend(logs):
    """Trend stats for ONE item's logs (all same name+unit).

    logs: list of {price, date[, market, note]}. Sorted by date ascending
    (ties keep input order — stable). Returns latest / first / high / low /
    average (all integer poisha) + the %-change between the two most recent
    logs. With a single log: has_trend=False, change=None (honest). All derived
    from the user's own logs; nothing invented.
    """
    clean = []
    for r in logs or []:
        price = to_minor(r.get("price"))
        if price <= 0:
            continue
        clean.append({
            "price": price,
            "date": str(r.get("date") or ""),
            "market": r.get("market") or "",
            "raw": r,
        })
    clean.sort(key=lambda x: x["date"])    # stable; empty dates sort first
    count = len(clean)
    if count == 0:
        return {"count": 0, "has_trend": False}

    prices = [c["price"] for c in clean]
    latest = clean[-1]
    first = clean[0]
    high = max(prices)
    low = min(prices)
    avg = sum(prices) // count            # integer poisha, floored (exact-ish)

    has_trend = count >= 2
    prev = clean[-2]["price"] if has_trend else None
    change = (latest["price"] - prev) if has_trend else None
    change_pct = _pct_change(prev, latest["price"]) if has_trend else None

    return {
        "count": count,
        "has_trend": has_trend,
        "latest": latest["price"],
        "latest_display": fmt_bdt(latest["price"]),
        "latest_date": latest["date"],
        "latest_market": latest["market"],
        "previous": prev,
        "previous_display": (fmt_bdt(prev) if prev is not None else None),
        "change": change,
        "change_display": (fmt_bdt(change) if change is not None else None),
        "change_pct": change_pct,          # signed float 1dp, None w/ one log
        "up": (change > 0) if change is not None else None,
        "down": (change < 0) if change is not None else None,
        "first": first["price"],
        "first_display": fmt_bdt(first["price"]),
        "high": high,
        "high_display": fmt_bdt(high),
        "low": low,
        "low_display": fmt_bdt(low),
        "avg": avg,
        "avg_display": fmt_bdt(avg),
        "logs": [{"price": c["price"], "price_display": fmt_bdt(c["price"]),
                  "date": c["date"], "market": c["market"], "raw": c["raw"]}
                 for c in clean],
    }


def radar(logs):
    """Group ALL the user's logs by (name, unit) and compute a trend per item.

    logs: list of {item, price, date[, unit, market, note]}. Returns one trend
    row per distinct (name, unit), sorted by item name then unit. Flags when a
    single name appears under more than one unit (so the UI can warn that prices
    across different units aren't directly comparable — we never convert).
    """
    groups = {}
    display_name = {}
    names_units = {}
    for r in logs or []:
        key, shown = item_key(r.get("item"), r.get("unit"))
        name_lc, unit = key
        if not name_lc:
            continue
        groups.setdefault(key, []).append(r)
        display_name.setdefault(key, shown)
        names_units.setdefault(name_lc, set()).add(unit)

    items = []
    for key in sorted(groups.keys()):
        name_lc, unit = key
        trend = item_trend(groups[key])
        trend["item"] = display_name[key]
        trend["unit"] = unit
        trend["mixed_units"] = len(names_units.get(name_lc, set())) > 1
        trend["marker"] = MARKER_KEY
        items.append(trend)

    total_logs = sum(t["count"] for t in items)
    return {
        "items": items,
        "item_count": len(items),
        "log_count": total_logs,
        "marker": MARKER_KEY,
        "live_required": False,       # the manual tracker needs no key
        "mock": True,
    }


# ------------------------------------------------------------------ feed seam

def feed_seam(item=None, market=None):
    """DOCUMENTED, key-gated seam for a LIVE market-price feed — not wired.

    Returns the query shape a real feed route would use, with `live_required=
    True` as the honest "connect a market-data key for live prices" state.
    Nothing here fetches anything and it returns NO prices — only the user's
    logged prices (via `radar`) are ever shown. There is no price-feed key in
    the Integrations REGISTRY yet; the integrator adds one (slug e.g.
    `price_feed`) when a real provider is chosen.
    """
    return {
        "live_required": True,
        "mock": True,
        "marker": MARKER_KEY,
        "integration": "price_feed",     # NOT yet in REGISTRY — documented only
        "query_shape": {"item": item, "market": market},
        # explicitly no prices: we never fabricate a live quote
        "prices": [],
        "note_key": "price_live_seam",
    }
