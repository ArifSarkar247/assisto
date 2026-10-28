"""
veh100 — what ONE tracked vehicle costs us per month, and whether the monthly
price keeps the owner's 40 % profit rule (owner_actions/PRICING_40PCT_BN.md:
we keep 74 % of the price after Google 15 % + VAT; profit must be >= 40 % of
the PRICE, worst case). PURE: every number is an argument with a stated,
conservative default — nothing here is measured on a live vehicle yet (no real
tracker has ever connected), so the owner can re-run it with real numbers:

    cd backend && python3 -c "from core.logic import vehicle_costs as C; print(C.report())"
"""
NET_PCT = 0.74          # owner: price / 1.15 VAT x (1 - 0.15 Google)
PROFIT_PCT = 0.40       # owner: profit >= 40 % of the price
USD_BDT = 125.0         # strict rate (pricing_40.STRICT_RATE)

DEFAULTS = {
    # tracker reporting (core.logic.pricing _VEHICLE_DEFAULTS)
    "moving_interval_s": 5, "parked_interval_s": 180, "drive_hours_per_day": 3.0,
    "retention_days": 30, "row_bytes": 300,             # position row + index
    # server: the box ($60/month all-in, estimate) and the share of it the
    # tracker daemon + ingest + reports use, spread over this many vehicles
    "box_usd_month": 60.0, "tracker_share": 0.25, "vehicles_on_box": 500,
    "storage_usd_gb_month": 0.08,                        # gp3-class block storage
    # app traffic: map open minutes per day, tiles per session after the
    # phone's tile cache, tile price (MapTiler-class, estimate)
    "map_sessions_per_day": 1.5, "tiles_per_session": 40,
    "tile_usd_per_1000": 0.10,
    "api_kb_per_day": 150, "egress_usd_gb": 0.09,
    # pushes are free (FCM); setup SMS is sent from the OWNER's own phone;
    # alerts never use paid SMS
    "push_usd": 0.0, "sms_usd": 0.0,
}


def month_cost_bdt(a=None):
    """Itemised monthly cost of one vehicle in ৳ (dict incl. 'total')."""
    p = dict(DEFAULTS, **(a or {}))
    day_s = 86400.0
    drive_s = p["drive_hours_per_day"] * 3600.0
    fixes_day = drive_s / p["moving_interval_s"] + (day_s - drive_s) / p["parked_interval_s"]
    stored_gb = fixes_day * p["retention_days"] * p["row_bytes"] / 1e9
    storage = stored_gb * p["storage_usd_gb_month"]
    server = p["box_usd_month"] * p["tracker_share"] / max(1, p["vehicles_on_box"])
    tiles = 30 * p["map_sessions_per_day"] * p["tiles_per_session"] / 1000.0 \
        * p["tile_usd_per_1000"]
    egress = 30 * p["api_kb_per_day"] / 1e6 * p["egress_usd_gb"]
    items = {"storage": storage, "server": server, "map_tiles": tiles, "egress": egress,
             "push": p["push_usd"], "sms": p["sms_usd"]}
    out = {k: round(v * USD_BDT, 2) for k, v in items.items()}
    out["total"] = round(sum(items.values()) * USD_BDT, 2)
    out["fixes_per_day"] = int(fixes_day)
    out["stored_mb"] = round(stored_gb * 1000, 1)
    return out


def margin(price_bdt, cost_bdt):
    """{net, profit, profit_pct, ok} for a monthly price (worst-case rule)."""
    net = price_bdt * NET_PCT
    profit = net - cost_bdt
    pct = profit / price_bdt if price_bdt > 0 else 0.0
    return {"price": round(price_bdt, 2), "net": round(net, 2), "cost": round(cost_bdt, 2),
            "profit": round(profit, 2), "profit_pct": round(pct, 3),
            "ok": pct >= PROFIT_PCT}


def min_price_bdt(cost_bdt):
    """Lowest monthly price that still keeps >= 40 % profit."""
    return round(cost_bdt / (NET_PCT - PROFIT_PCT), 2)


def report(credits=50, bdt_per_credit=(0.83, 3.16, 3.58)):   # pragma: no cover
    c = month_cost_bdt()
    lines = ["cost/vehicle/month ৳%s %s" % (c["total"], c)]
    for r in bdt_per_credit:
        lines.append("%d credits @ ৳%.2f -> %s" % (credits, r, margin(credits * r, c["total"])))
    lines.append("min price ৳%s" % min_price_bdt(c["total"]))
    return "\n".join(lines)
