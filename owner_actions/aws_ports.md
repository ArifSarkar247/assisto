# AWS Security Group — ports to open for Assisto calling (Step 6 M3)

**You must open these inbound ports in the EC2 instance's AWS Security Group.**
I cannot touch the AWS console (separation rule), so this is yours to do. Until
they are open, voice/video calls fall back gracefully — the app shows an honest
**"call server not reachable"** state and never hangs (the backend reports
`configured:true` but the relay is unreachable, so the client degrades).

Instance: the one running Asalify + Assisto. Public IP **65.2.155.10**,
private **172.31.7.16**. The TURN server (coturn) is already installed, running,
hard-capped, and verified (its STUN listener answers and correctly reports the
public IP). It only needs the firewall opened.

## Inbound rules to add

| Port range   | Protocol | Source      | Why |
|--------------|----------|-------------|-----|
| **3478**     | **UDP**  | 0.0.0.0/0   | STUN + TURN primary. Almost all WebRTC calls use this. UDP is the normal media path. |
| **3478**     | **TCP**  | 0.0.0.0/0   | TURN over TCP — fallback when a user's network blocks UDP (some office/mobile firewalls). |
| **49200-49300** | **UDP** | 0.0.0.0/0 | TURN **relay** port range. When two users can't connect directly, coturn relays their media through one of these ports. **Hard-capped to 100 ports** (= bounded concurrent relays) on purpose. |

Source `0.0.0.0/0` is required because users connect from any mobile/home
network. This is standard and safe for a TURN server — see the security notes
below (coturn is locked down so it can only relay between call participants,
never into our own network).

> IPv6: if the instance has a public IPv6, add the same three rules for `::/0`.
> TLS (turns:// on 5349/tcp) is **not** enabled yet (needs a cert); plain
> `turn://` on 3478 is enough for M3. I'll add TLS later if you want it.

## After you open them — tell me, and I will:
- Re-run the end-to-end relay test from an outside host to confirm a real TURN
  allocation + media relay succeeds (not just STUN).
- Flip the app's call flow from "fallback" to live (it already reads the ICE
  servers from `GET /api/v1/rtc/turn`; no rebuild needed for the server side).

## Security — why opening 0.0.0.0/0 here is safe
coturn is configured (in `/etc/turnserver.conf`) to **deny relaying to all
private / loopback / link-local ranges** (`127.0.0.0/8`, `10/8`, `172.16/12`,
`192.168/16`, `169.254/16`, `::1`, `fc00::/7`, `fe80::/10`). So even though the
port is world-reachable, it **cannot** be abused to reach Asalify, Postgres,
Redis, or anything on the box — it can only shuttle call media between two
Assisto users. Auth is **time-limited HMAC credentials** minted per call by the
backend (`/rtc/turn`); there are no static username/passwords.

## Hard caps already in force (so Asalify is never starved)
- systemd: `MemoryMax=256M`, `MemoryHigh=192M`, `CPUQuota=40%` (of 2 vCPUs),
  `Nice=5` (coturn yields CPU to Asalify), auto-restart on failure.
- coturn: `total-quota=100` (max concurrent allocations), `user-quota=6`,
  `max-bps=160000` (~1.3 Mbit/s per session cap), relay range limited to 100
  ports (`49200-49300`).
- Backend auto-throttle: `GET /rtc/turn` returns `throttled:true` (and the app
  backs off BEFORE starting a call) whenever 1-min load > 2×vCPU or available
  RAM < 250 MB — i.e. **calls are sacrificed before Asalify can slow down.**

## SFU (large group calls) — deferred, needs a bigger box
coturn/TURN handles 1:1 and small-group **mesh** calls fully. A dedicated **SFU**
(for calls with many participants) needs real RAM headroom this instance does
not have right now (3.7 GB total, ~1.8 GB free, swap already ~65% used). If you
want large group calls, enlarge the instance (more RAM; +a few GB EBS) and tell
me — I'll add a hard-capped SFU then. The app's call flow is already built to
use an SFU URL when one exists, and to fall back to mesh/TURN when it doesn't.
