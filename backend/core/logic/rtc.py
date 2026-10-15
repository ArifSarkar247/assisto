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


def ice_servers(public_ip, port, creds):
    """The `iceServers` array the client feeds to RTCPeerConnection: a STUN entry
    (for reflexive candidates) + a TURN entry over UDP and TCP (relay fallback
    when a direct/NAT path fails)."""
    return [
        {"urls": [f"stun:{public_ip}:{port}"]},
        {
            "urls": [
                f"turn:{public_ip}:{port}?transport=udp",
                f"turn:{public_ip}:{port}?transport=tcp",
            ],
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
