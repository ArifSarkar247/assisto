"""Self-hosted WebRTC signalling helpers (Step 6 M3) — TURN/STUN credentials
+ an auto-throttle decision so calls never starve the shared box (and thus
Asalify).  PURE: no Django, no DB, no clock (caller passes `now_ts`).

TURN REST API (coturn `use-auth-secret`): the backend mints a short-lived
username/credential pair from the shared static secret; coturn verifies the HMAC
itself, so the secret never leaves the server and credentials expire on their
own.  The client puts these into its WebRTC `iceServers`.
"""
import base64
import hashlib
import hmac

TURN_DEFAULT_TTL = 3600            # credentials valid for 1 hour
THROTTLE_LOAD_FACTOR = 2.0         # throttle when 1-min load > factor * cpus
THROTTLE_MIN_MEM_MB = 250         # throttle when available RAM drops below this


def turn_credentials(secret, user_id, now_ts, ttl=TURN_DEFAULT_TTL):
    """Time-limited coturn REST credential.

    username   = "<expiry_unix>:<user_id>"
    credential = base64( HMAC-SHA1(username, secret) )

    coturn with `use-auth-secret` recomputes the same HMAC and also rejects an
    expired `expiry`, so a leaked credential self-expires and can't be replayed
    past its window.
    """
    expiry = int(now_ts) + int(ttl)
    username = f"{expiry}:{user_id}"
    digest = hmac.new(secret.encode(), username.encode(), hashlib.sha1).digest()
    credential = base64.b64encode(digest).decode()
    return {"username": username, "credential": credential,
            "ttl": int(ttl), "expiry": expiry}


def ice_servers(host, port, creds, tls_port=0):
    """The `iceServers` array the client feeds to RTCPeerConnection: a STUN entry
    (for reflexive candidates; host is a DOMAIN so a server move = DNS change) + a TURN entry over UDP and TCP (relay fallback
    when a direct/NAT path fails)."""
    urls = [
        f"turn:{host}:{port}?transport=udp",
        f"turn:{host}:{port}?transport=tcp",
    ]
    if tls_port:
        # x1-calls: TURN over TLS (coturn tls-listening-port with the Let's
        # Encrypt cert of `host`) — gets through networks that block UDP and
        # odd TCP ports. ALWAYS the last URL, so udp/tcp 3478 are tried first.
        urls.append(f"turns:{host}:{int(tls_port)}?transport=tcp")
    return [
        {"urls": [f"stun:{host}:{port}"]},
        {
            "urls": urls,
            "username": creds["username"],
            "credential": creds["credential"],
        },
    ]


def throttle_decision(loadavg1, cpus, mem_avail_mb, *,
                      load_factor=THROTTLE_LOAD_FACTOR,
                      min_mem_mb=THROTTLE_MIN_MEM_MB):
    """Protect the shared server (and therefore Asalify): if the box is under
    load or low on memory, THROTTLE new calls first.  Returns
    {throttled: bool, reason: 'load'|'memory'|''}.

    This is intentionally conservative — a call that never starts is far better
    than Asalify slowing down.  The client shows an honest 'call server busy'
    state and the user can retry.
    """
    cpus = cpus or 1
    if loadavg1 > load_factor * cpus:
        return {"throttled": True, "reason": "load"}
    if mem_avail_mb < min_mem_mb:
        return {"throttled": True, "reason": "memory"}
    return {"throttled": False, "reason": ""}
