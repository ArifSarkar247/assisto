"""homefeed: Today-feed sample for the CI emulator backend ONLY (seed_reality).

Loads the RECORDED provider responses in core/test_data_p4 (MET Norway,
ExchangeRate-API) into the shared WorldFeed rows the way world_refresh stores
them, with times moved to "now", so the emulator flow sees real shapes:

* weather: last good copy 5 h ago and the source failing since (an outage)
  -> the app must show the real last value + "not responding, 5 h ago";
* currency: fresh (20 min ago);
* gold: an owner-entered price 20 days old -> "may have changed";
  fuel: entered this week.
Never called on the live server (seed_reality refuses non-CI databases).
"""
import json
from datetime import timedelta
from pathlib import Path

from django.utils import timezone

DATA = Path(__file__).resolve().parent / "test_data_p4"


def _shift_met(p, now, ok_at):
    p = dict(p)
    p["time"] = p["updated"] = ok_at.isoformat()
    base = now.replace(minute=0, second=0, microsecond=0)
    steps = []
    for i, s in enumerate(p.get("next") or []):
        s = dict(s)
        s["time"] = (base + timedelta(hours=6 * (i + 1))).isoformat()
        steps.append(s)
    p["next"] = steps
    return p


def load(now=None):
    from .logic import world_feeds as WF
    from .models import WorldAdminValue, WorldFeed
    now = now or timezone.now()
    met = WF.parse_met(json.loads((DATA / "met_dhaka.json").read_bytes()))
    fx = WF.parse_fx(json.loads((DATA / "er_usd.json").read_bytes()))
    ok_w = now - timedelta(hours=5)
    fx["updated"] = (now - timedelta(hours=6)).isoformat()
    WorldFeed.objects.update_or_create(slug="weather_dhaka", defaults={
        "kind": "weather", "enabled": True, "payload": _shift_met(met, now, ok_w),
        "last_ok_at": ok_w, "fetched_at": now, "last_error": "HTTP 503 (CI sample outage)",
        "last_error_at": now})
    WorldFeed.objects.update_or_create(slug="fx_usd", defaults={
        "kind": "fx", "enabled": True, "payload": fx,
        "last_ok_at": now - timedelta(minutes=20), "fetched_at": now - timedelta(minutes=20)})
    day = timezone.localdate(now)
    for key, value, back in (("gold_22k", 152000, 20), ("fuel_octane", 126, 3)):
        WorldAdminValue.objects.update_or_create(key=key, defaults={
            "value": value, "effective_date": day - timedelta(days=back),
            "note": "CI sample"})
    return {"weather_ok_at": ok_w.isoformat(), "gold_date": (day - timedelta(days=20)).isoformat()}
