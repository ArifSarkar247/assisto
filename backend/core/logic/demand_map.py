"""
demand_map.py — pure, deterministic DEMAND MAP math (#145, SPEC v2.1 §21,
ADVANCED).

A manual demand tracker for a business. The user LOGS demand SIGNALS they
observe — product, area, period (month/season/label), a demand level, and an
optional note — and this module computes a deterministic HEAT summary over the
user's OWN signals: which products and which areas are "hot", and a
product×area grid. It is PURE, like price_radar.py / supplier_market.py: no
Django, no DB, no network, **no AI**, no clock, no external market feed. Same
inputs → same output, so the on-device Dart mirror matches offline and the
tests pin it.

ONLY THE USER'S LOGGED SIGNALS — NEVER FABRICATE MARKET DATA
------------------------------------------------------------
Every number returned is aggregated from the demand signals the user themselves
logged. We NEVER invent, scrape, or guess real market/trade demand. With zero
signals the map is simply empty (honest welcome state on the client). The
"heat" is a sum of the user's own level scores, not a claim about the real
market.

HONEST LIVE TRADE-DATA SEAM (KEY-GATED)
---------------------------------------
LIVE trade/market demand data is a DOCUMENTED seam only: `trade_seam()` returns
{required, mock, query_shape} describing what a live trade-data route would look
like. Nothing here fetches anything and it returns NO market figures —
`trade_required=True` is the honest "connect a trade-data source" state. There
is NO trade-data key in the Integrations REGISTRY yet; the integrator adds one
(slug e.g. `trade_data`) when a real provider is chosen. Until then this manual
tracker is the whole, honest feature.

LEVELS
------
Demand level is one of LEVELS (low/medium/high/surge) → a fixed integer score
(1/2/3/4). Heat is the SUM of scores for a bucket; a bucket's level BAND is
derived from its average score so the UI can colour it without us ever claiming
a market figure.

Hand-verified in demand_map_tests_snippets.py.
"""

MARKER_KEY = "demand_manual"        # "your logged demand signals — not a feed"

# Demand levels → fixed integer scores. Order matters for display. The UI
# localises the slugs.
LEVELS = ("low", "medium", "high", "surge")
_LEVEL_SCORE = {"low": 1, "medium": 2, "high": 3, "surge": 4}

# Heat BANDS for an average score (used to colour a bucket). A band is derived
# ONLY from the user's own averaged scores — never from market data. Thresholds
# are on the 1..4 score scale.
#   avg < 1.5           -> low
#   1.5 <= avg < 2.5    -> medium
#   2.5 <= avg < 3.5    -> high
#   avg >= 3.5          -> surge


# ------------------------------------------------------------------ helpers

def _clean(text):
    return " ".join(str(text or "").split()).strip()


def _level(v):
    """Normalise a demand level to a known slug; junk/blank → 'medium'."""
    s = _clean(v).lower()
    return s if s in LEVELS else "medium"


def _score(level):
    return _LEVEL_SCORE.get(level, 2)


def _band(avg):
    """Average score (float, 1..4) → a heat band slug the UI colours."""
    if avg < 1.5:
        return "low"
    if avg < 2.5:
        return "medium"
    if avg < 3.5:
        return "high"
    return "surge"


def normalize(row):
    """One raw demand-signal dict → a normalised signal (pure). Keeps id/raw."""
    level = _level(row.get("level"))
    return {
        "id": row.get("id"),
        "product": _clean(row.get("product")),
        "area": _clean(row.get("area")),
        "period": _clean(row.get("period")),
        "level": level,
        "score": _score(level),
        "note": _clean(row.get("note")),
        "marker": MARKER_KEY,
        "raw": row,
    }


def _bucket(items, keyfn, labelfn):
    """Aggregate normalised signals into heat buckets keyed by keyfn.

    Each bucket: {key, label, count, total (summed score), avg (1dp), band,
    top_level}. Sorted by total DESC then label ASC (stable, deterministic)."""
    groups = {}
    labels = {}
    for s in items:
        k = keyfn(s)
        if not k:
            continue
        groups.setdefault(k, []).append(s)
        labels.setdefault(k, labelfn(s))
    out = []
    for k, sigs in groups.items():
        total = sum(s["score"] for s in sigs)
        count = len(sigs)
        avg = round(total * 10.0 / count) / 10.0
        # top level in the bucket = the highest-scoring level present
        top = max(sigs, key=lambda s: s["score"])["level"]
        out.append({
            "key": k,
            "label": labels[k],
            "count": count,
            "total": total,
            "avg": avg,
            "band": _band(avg),
            "top_level": top,
        })
    out.sort(key=lambda b: (-b["total"], b["label"].lower()))
    return out


def heat(rows):
    """Full demand heat summary over the user's OWN logged signals (pure).

    Returns:
      * by_product — heat buckets per product (hottest first)
      * by_area     — heat buckets per area (hottest first)
      * grid        — product×area cells (each a bucket) for a heat grid,
                      sorted by total DESC then product, area ASC
      * hottest_product / hottest_area — the top bucket key (None if empty)
      * signal_count / product_count / area_count

    Everything is a sum/average of the user's own level scores; no market claim.
    """
    items = [normalize(r) for r in (rows or [])
             if _clean(r.get("product")) or _clean(r.get("area"))]

    by_product = _bucket(items, lambda s: s["product"].lower(),
                         lambda s: s["product"])
    by_area = _bucket(items, lambda s: s["area"].lower() or "",
                      lambda s: s["area"])

    # product×area grid cells
    def _cellkey(s):
        p = s["product"].lower()
        a = s["area"].lower()
        if not p or not a:
            return ""
        return p + "␟" + a      # unit-separator joins the two keys
    grid = _bucket(items, _cellkey,
                   lambda s: s["product"] + "  ·  " + s["area"])

    return {
        "by_product": by_product,
        "by_area": by_area,
        "grid": grid,
        "hottest_product": by_product[0]["label"] if by_product else None,
        "hottest_area": by_area[0]["label"] if by_area else None,
        "signal_count": len(items),
        "product_count": len(by_product),
        "area_count": len(by_area),
        "marker": MARKER_KEY,
        "trade_required": False,       # the manual tracker needs no key
        "mock": True,
    }


# ------------------------------------------------------------------ trade seam

def trade_seam(product=None, area=None, period=None):
    """DOCUMENTED, key-gated seam for LIVE trade/market demand data — not wired.

    Returns the query shape a real trade-data route would use, with
    `trade_required=True` as the honest "connect a trade-data source" state.
    Nothing here fetches anything and it returns NO market figures — only the
    user's own logged signals (via `heat`) are ever shown; we NEVER fabricate
    market data. There is no trade-data key in the Integrations REGISTRY yet;
    the integrator adds one (slug e.g. `trade_data`) when a real provider is
    chosen."""
    return {
        "trade_required": True,
        "mock": True,
        "marker": MARKER_KEY,
        "integration": "trade_data",     # NOT yet in REGISTRY — documented only
        "query_shape": {"product": product, "area": area, "period": period},
        # explicitly no market data: we never fabricate a demand figure
        "signals": [],
        "note_key": "demandTradeSeamBody",
    }
