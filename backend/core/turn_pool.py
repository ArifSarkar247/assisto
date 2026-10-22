"""t9-turnscale: the TURN server LIST as config, not code.

Where the list comes from (first non-empty wins):
  1. Owner Admin → Call relay (TurnConfig.servers_text, DB),
  2. env TURN_SERVERS,
  3. nothing  -> rtc.ice_servers() keeps its old single-TURN_HOST output
                 byte-for-byte (this module returns None).

Formats (both sources accept both):
  JSON  [{"host": "turn.lifeassisto.com", "port": 3478, "tls_port": 5349,
          "weight": 1, "region": "ap-south-1", "secret_env": "TURN_STATIC_SECRET",
          "enabled": true}, ...]
  list  one entry per comma or line:  host[:port][|w=2][|tls=5349|tls=0]
                                       [|region=sg][|secret_env=TURN2_SECRET][|off]

Secrets never live in the list — `secret_env` names an environment variable;
entries without one share settings.TURN_STATIC_SECRET. Adding a second TURN
box = a DNS name + one entry; the phones get it on their next /rtc/turn call.

Per user the hosts are ordered by weighted rendezvous hashing (stable for a
user, spread across users in proportion to weight) and capped at
TURN_MAX_ICE_HOSTS. WebRTC prefers relay candidates from earlier servers, so
the order spreads relay load. Hosts the turn_monitor STUN probe saw failing
twice in a row (fresh < 10 min) are left out — unless ALL are failing, then
all are handed out (fail-open: a maybe-down relay beats no relay).

Optional managed-TURN overflow (Cloudflare Calls TURN): see overflow_ice().
"""
import hashlib
import json
import math
import os
import re
import time

MAX_SERVERS = 8
HEALTH_FRESH_S = 600
HEALTH_FAILS_DOWN = 2
_HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")


class ConfigError(ValueError):
    pass


# ------------------------------------------------------------------ parsing
def _entry(d, default_port=3478):
    host = str(d.get("host", "")).strip().lower()
    if not host or not _HOST_RE.match(host):
        raise ConfigError("bad host %r" % host[:80])

    def _port(v, name, allow_zero=False):
        try:
            p = int(v)
        except (TypeError, ValueError):
            raise ConfigError("bad %s for %s" % (name, host))
        if (p == 0 and allow_zero) or 1 <= p <= 65535:
            return p
        raise ConfigError("bad %s for %s" % (name, host))

    port = _port(d.get("port", default_port), "port")
    tls = _port(d.get("tls_port", 5349), "tls_port", allow_zero=True)
    try:
        weight = float(d.get("weight", 1))
    except (TypeError, ValueError):
        raise ConfigError("bad weight for %s" % host)
    if not (0 < weight <= 100):
        raise ConfigError("weight must be 0-100 for %s" % host)
    secret_env = str(d.get("secret_env", "") or "").strip()
    if secret_env and not _ENV_RE.match(secret_env):
        raise ConfigError("secret_env must be an ENV_VAR_NAME for %s" % host)
    return {"host": host, "port": port, "tls_port": tls, "weight": weight,
            "region": str(d.get("region", "") or "")[:32],
            "secret_env": secret_env,
            "enabled": bool(d.get("enabled", True))}


def parse_servers(raw):
    """Text (JSON or comma/line list) -> list of normalised entries.
    Empty/blank -> []. Raises ConfigError on anything malformed (the owner
    form shows the message; the runtime path then falls back)."""
    raw = (raw or "").strip()
    if not raw:
        return []
    items = []
    if raw[:1] in "[{":
        try:
            data = json.loads(raw)
        except ValueError as e:
            raise ConfigError("JSON: %s" % e)
        if isinstance(data, dict):
            data = [data]
        if not isinstance(data, list):
            raise ConfigError("JSON must be a list of servers")
        for d in data:
            if not isinstance(d, dict):
                raise ConfigError("each JSON server must be an object")
            items.append(_entry(d))
    else:
        for tok in re.split(r"[,\n]", raw):
            tok = tok.strip()
            if not tok or tok.startswith("#"):
                continue
            parts = [p.strip() for p in tok.split("|")]
            hp, d = parts[0], {}
            if ":" in hp:
                hp, d["port"] = hp.rsplit(":", 1)
            d["host"] = hp
            for opt in parts[1:]:
                k, _, v = opt.partition("=")
                k = k.strip().lower()
                if k in ("w", "weight"):
                    d["weight"] = v
                elif k in ("tls", "tls_port"):
                    d["tls_port"] = v
                elif k == "region":
                    d["region"] = v
                elif k == "secret_env":
                    d["secret_env"] = v.strip()
                elif k == "off":
                    d["enabled"] = False
                elif k:
                    raise ConfigError("unknown option %r" % k)
            items.append(_entry(d))
    if len(items) > MAX_SERVERS:
        raise ConfigError("at most %d servers" % MAX_SERVERS)
    seen = set()
    for it in items:
        key = (it["host"], it["port"])
        if key in seen:
            raise ConfigError("duplicate server %s:%s" % key)
        seen.add(key)
    return items


def _db_text():
    try:
        from .models import TurnConfig
        row = TurnConfig.objects.filter(pk=1).only("servers_text", "health").first()
        return (row.servers_text if row else ""), (row.health if row else {})
    except Exception:
        return "", {}


def configured_servers():
    """(servers, source, health). source in {'owner', 'env', ''}."""
    from django.conf import settings
    text, health = _db_text()
    for src, raw in (("owner", text), ("env", getattr(settings, "TURN_SERVERS", ""))):
        if (raw or "").strip():
            try:
                lst = [s for s in parse_servers(raw) if s["enabled"]]
            except ConfigError:
                continue          # a broken owner entry never breaks calls
            if lst:
                return lst, src, health or {}
    return [], "", health or {}


# ------------------------------------------------------------------ health
def _is_down(s, health, now_ts):
    h = (health or {}).get("%s:%s" % (s["host"], s["port"])) or {}
    try:
        fresh = now_ts - float(h.get("ts", 0)) < HEALTH_FRESH_S
    except (TypeError, ValueError):
        fresh = False
    return fresh and int(h.get("fails", 0) or 0) >= HEALTH_FAILS_DOWN


def healthy(servers, health, now_ts):
    """(hosts to hand out, all_down). Drops hosts with a FRESH record of
    >= HEALTH_FAILS_DOWN consecutive probe failures; when ALL are down every
    host is returned (fail-open) and all_down=True (overflow may kick in)."""
    up = [s for s in servers if not _is_down(s, health, now_ts)]
    if servers and not up:
        return list(servers), True
    return up, False


def order_for(servers, user_id):
    """Weighted rendezvous ordering: stable per user, spread by weight."""
    def score(s):
        h = hashlib.sha256(("%s|%s:%s" % (user_id, s["host"], s["port"])).encode()).digest()
        u = (int.from_bytes(h[:8], "big") + 1) / float(2 ** 64 + 2)   # (0,1)
        return -s["weight"] / math.log(u)
    return sorted(servers, key=score, reverse=True)


# ------------------------------------------------------------------ build
def _secret_for(s, default_secret):
    if s["secret_env"]:
        return os.getenv(s["secret_env"], "") or ""
    return default_secret


def build_ice(servers, user_id, now_ts, ttl, default_secret, default_creds=None,
              max_hosts=3):
    """iceServers for the given (already ordered) servers. A server whose own
    secret env is empty is skipped (it could only fail auth)."""
    from .logic import rtc as RTC
    out = []
    for s in servers:
        if len([x for x in out if "username" in x]) >= max_hosts:
            break
        secret = _secret_for(s, default_secret)
        if not secret:
            continue
        if default_creds and secret == default_secret:
            creds = default_creds
        else:
            creds = RTC.turn_credentials(secret, user_id, now_ts, ttl=ttl)
        h, p = s["host"], s["port"]
        urls = ["turn:%s:%s?transport=udp" % (h, p),
                "turn:%s:%s?transport=tcp" % (h, p)]
        if s["tls_port"]:
            urls.append("turns:%s:%s?transport=tcp" % (h, s["tls_port"]))
        out.append({"urls": ["stun:%s:%s" % (h, p)]})
        out.append({"urls": urls, "username": creds["username"],
                    "credential": creds["credential"]})
    return out


def _parse_creds(creds):
    """rtc.turn_credentials() output -> (user_id, now_ts, ttl)."""
    username = str(creds.get("username", ""))
    exp, _, uid = username.partition(":")
    ttl = int(creds.get("ttl", 3600))
    return uid, int(exp) - ttl, ttl


def pooled_ice_servers(creds):
    """Called by rtc.ice_servers(). None when no list is configured (caller
    keeps the legacy output). Otherwise the pooled list + overflow."""
    from django.conf import settings
    servers, _src, health = configured_servers()
    uid, now_ts, ttl = _parse_creds(creds)
    if not servers:
        return None
    default_secret = getattr(settings, "TURN_STATIC_SECRET", "") or ""
    live, all_down = healthy(servers, health, time.time())
    ice = build_ice(order_for(live, uid), uid, now_ts, ttl, default_secret,
                    default_creds=creds,
                    max_hosts=max(1, int(getattr(settings, "TURN_MAX_ICE_HOSTS", 3))))
    return ice + overflow_ice(uid, ttl, own_down=all_down)


def with_overflow(legacy, creds):
    """Legacy (no-list) path: append overflow only when it is switched on."""
    uid, _now, ttl = _parse_creds(creds)
    extra = overflow_ice(uid, ttl)
    return legacy + extra if extra else legacy


# ------------------------------------------------------------------ overflow
OVERFLOW_SLUG = "turn_overflow"
CF_URL = ("https://rtc.live.cloudflare.com/v1/turn/keys/%s/credentials/"
          "generate-ice-servers")


def _truthy(v):
    return str(v or "").strip().lower() in ("1", "on", "yes", "true", "y")


def overflow_settings():
    """{active, mode, threshold_pct, key_id, api_token} — active only when the
    integration is saved, its Test passed (status working) AND enabled=on."""
    off = {"active": False}
    try:
        from . import integrations as I
        if not I.is_enabled(OVERFLOW_SLUG):
            return off
        cfg = I.get(OVERFLOW_SLUG)
    except Exception:
        return off
    if not (cfg.get("key_id") and cfg.get("api_token") and _truthy(cfg.get("enabled"))):
        return off
    mode = str(cfg.get("mode") or "overflow").strip().lower()
    try:
        pct = float(cfg.get("threshold_pct") or 70)
    except (TypeError, ValueError):
        pct = 70.0
    return {"active": True, "mode": "always" if mode == "always" else "overflow",
            "threshold_pct": pct, "key_id": str(cfg["key_id"]).strip(),
            "api_token": str(cfg["api_token"]).strip()}


def own_usage_pct():
    """Our own relay usage (% of the tighter of allocation / bandwidth limits)
    from the latest fresh TurnSample; None when no fresh sample."""
    try:
        from django.utils import timezone
        from datetime import timedelta
        from .models import TurnSample
        from . import turn_monitor as M
        s = TurnSample.objects.filter(
            at__gte=timezone.now() - timedelta(minutes=5)).order_by("-at").first()
        if s is None:
            return None
        return M.usage_pcts(s, M.limits())["max"]
    except Exception:
        return None


def cf_generate(key_id, api_token, ttl, timeout=4):
    """Cloudflare Calls TURN: POST .../generate-ice-servers {"ttl": n}
    (Authorization: Bearer <api token>). Returns a list of iceServers.
    Accepts both documented response shapes ({"iceServers": [..]} and the
    older {"iceServers": {urls, username, credential}})."""
    import urllib.request
    req = urllib.request.Request(
        CF_URL % key_id, data=json.dumps({"ttl": int(ttl)}).encode(), method="POST",
        headers={"Authorization": "Bearer %s" % api_token,
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = json.loads(r.read().decode() or "{}")
    ice = body.get("iceServers")
    if isinstance(ice, dict):
        ice = [ice]
    out = []
    for e in ice or []:
        if isinstance(e, dict) and e.get("urls"):
            urls = e["urls"] if isinstance(e["urls"], list) else [e["urls"]]
            item = {"urls": [str(u) for u in urls]}
            if e.get("username"):
                item["username"] = str(e["username"])
                item["credential"] = str(e.get("credential", ""))
            out.append(item)
    return out


def overflow_ice(user_id, ttl, own_down=False):
    """Managed-TURN entries to APPEND after our own servers ([] when off).
    Minted server-side (the provider key never reaches the app), cached per
    user for half the TTL, and any provider error simply yields []."""
    st = overflow_settings()
    if not st["active"]:
        return []
    if st["mode"] == "overflow" and not own_down:
        pct = own_usage_pct()
        if pct is None or pct < st["threshold_pct"]:
            return []
    ttl = max(300, min(int(ttl or 3600), 86400))
    try:
        from django.core.cache import cache
        key = "t9:cfturn:%s:%s" % (user_id, ttl)
        hit = cache.get(key)
        if hit is not None:
            return hit
        ice = cf_generate(st["key_id"], st["api_token"], ttl)
        # Only TURN relay entries: our own STUN already covers reflexive.
        ice = [e for e in ice if "username" in e]
        cache.set(key, ice, ttl // 2)
        return ice
    except Exception:
        return []
