"""t9-turnscale: coturn capacity monitoring + relay cost (Profit Guard).

Sources (each optional; a missing source leaves its fields NULL, never 0):
  * relay sockets  — `ss -Huan`: UNCONN UDP sockets on the relay IP inside the
                     relay port range = live allocations (works with today's
                     coturn config, no password needed; no-tcp-relay = UDP only).
  * coturn CLI     — telnet 127.0.0.1:5766 `ps` (needs cli-password in
                     turnserver.conf + TURN_CLI_PASSWORD env): sessions + live
                     relay bytes/s.
  * NIC counters   — /proc/net/dev delta: WHOLE-BOX bytes/s (API traffic too),
                     used for the bandwidth alert only when the CLI is off.
  * turnserver CPU — /proc/<pid>/stat delta, % of ONE vCPU; steal from /proc/stat.
  * coturn log     — new lines since the last run: 486 quota / bandwidth quota,
                     allocation failures, auth failures, and 'usage' byte lines
                     of closed sessions (the latter need `verbose` in coturn).

Pure helpers (parse_*, usage_pcts, evaluate_alerts, cost math) take plain
values so the tests can drive them without a coturn.
"""
import glob
import json
import os
import re
import socket
import struct
import time

# ------------------------------------------------------------------ limits
DEFAULT_THRESHOLDS = {
    "alloc_pct": 70.0,       # % of the effective allocation limit
    "bw_pct": 70.0,          # % of the relay bandwidth budget
    "cpu_pct": 60.0,         # turnserver % of ONE vCPU (t3 baseline is 30%/vCPU)
    "steal_pct": 10.0,       # hypervisor steal (credit exhaustion / noisy host)
    "quota_window_min": 5,   # any 486 in this window -> alert
    "realert_min": 60,       # re-send a still-active alert after this long
}


def limits(thresholds=None):
    """Effective limits from settings (+ owner overrides in thresholds)."""
    from django.conf import settings
    t = dict(DEFAULT_THRESHOLDS)
    t.update({k: v for k, v in (thresholds or {}).items() if k in DEFAULT_THRESHOLDS})
    total_quota = int(getattr(settings, "TURN_TOTAL_QUOTA", 600) or 0)
    bps_cap = int(getattr(settings, "TURN_BPS_CAPACITY", 0) or 0)
    max_bps = int(getattr(settings, "TURN_MAX_BPS", 0) or 0)
    return {"total_quota": total_quota, "bps_capacity": bps_cap, "max_bps": max_bps,
            "alloc_limit": effective_alloc_limit(total_quota, bps_cap, max_bps),
            "bw_budget": int(getattr(settings, "TURN_RELAY_BUDGET_BYTES_S", 31250000) or 0),
            "thresholds": t}


def effective_alloc_limit(total_quota, bps_capacity, max_bps):
    """coturn RESERVES max-bps from bps-capacity for every allocation and
    refuses the next one with 486 'Allocation Bandwidth Quota Reached' once the
    capacity is used up — so with both set, the real allocation ceiling is
    min(total-quota, bps-capacity // max-bps). 0 = unlimited."""
    lims = [x for x in (total_quota,) if x > 0]
    if bps_capacity > 0 and max_bps > 0:
        lims.append(bps_capacity // max_bps)
    return min(lims) if lims else 0


def usage_pcts(sample, lim):
    """{alloc, bw, max} percent of limits for a TurnSample-like object."""
    alloc = None
    if getattr(sample, "allocations", None) is not None and lim["alloc_limit"]:
        alloc = 100.0 * sample.allocations / lim["alloc_limit"]
    bw = None
    out = getattr(sample, "relay_out_bps", None)
    if out is None:
        out = getattr(sample, "nic_out_bps", None)
    if out is not None and lim["bw_budget"]:
        bw = 100.0 * out / lim["bw_budget"]
    vals = [v for v in (alloc, bw) if v is not None]
    return {"alloc": alloc, "bw": bw, "max": max(vals) if vals else None}


# ------------------------------------------------------------------ parsers
def parse_ss_relays(text, port_min, port_max, relay_ip=""):
    """Count unconnected UDP sockets on the relay IP in the relay port range
    (`ss -Huan` output; header line tolerated)."""
    n = 0
    for line in (text or "").splitlines():
        f = line.split()
        if len(f) < 5 or f[0] != "UNCONN":
            continue
        local, peer = f[3], f[4]
        if peer not in ("*:*", "0.0.0.0:*", "[::]:*") and not peer.endswith(":*"):
            continue
        addr, _, port = local.rpartition(":")
        addr = addr.split("%")[0].strip("[]")
        try:
            port = int(port)
        except ValueError:
            continue
        if not (port_min <= port <= port_max):
            continue
        if relay_ip and addr != relay_ip:
            continue
        n += 1
    return n


_TOTAL_SESS = re.compile(r"Total sessions:\s*(\d+)", re.I)
_RATE = re.compile(r"rate:\s*r=(\d+),\s*s=(\d+)", re.I)


def parse_cli_ps(text):
    """coturn CLI `ps` -> {sessions, in_bps, out_bps} (bytes/s). The rate
    line is 'rate: r=<recv>, s=<sent>, total=<..> (bytes per sec)'."""
    m = _TOTAL_SESS.search(text or "")
    rin = rout = 0
    for a, b in _RATE.findall(text or ""):
        rin += int(a)
        rout += int(b)
    return {"sessions": int(m.group(1)) if m else None, "in_bps": rin, "out_bps": rout}


_USAGE = re.compile(r"(peer )?usage: realm=<[^>]*>, username=<([^>]*)>, "
                    r"rp=(\d+), rb=(\d+), sp=(\d+), sb=(\d+)")
_SESSION = re.compile(r"session (\d+)")
PATTERNS = {
    "bw_quota": re.compile(r"Allocation Bandwidth Quota Reached", re.I),
    "quota": re.compile(r"Allocation Quota Reached|error 486\b|\b486\b.*[Qq]uota", re.I),
    "alloc": re.compile(r"Cannot complete Allocation|cannot create (relay|socket)|"
                        r"Insufficient Capacity|error 508\b", re.I),
    "auth": re.compile(r"check_stun_auth|Unauthorized|error 401\b|"
                       r"wrong message integrity|Stale nonce", re.I),
}


def parse_log_lines(lines):
    """Count error classes + collect closed-session usage.
    Returns {quota, bw_quota, alloc, auth, usages:[{user_id, bytes_in, bytes_out}]}.
    A 'usage' line (client side: rb=bytes from phone, sb=bytes to phone) and its
    'peer usage' line (sb=bytes sent to the peer) are merged per session:
    egress = client sb + peer sb; without a peer line egress ~= sb + rb."""
    out = {"quota": 0, "bw_quota": 0, "alloc": 0, "auth": 0, "usages": []}
    sess = {}
    order = []
    for line in lines:
        if PATTERNS["bw_quota"].search(line):
            out["bw_quota"] += 1
        elif PATTERNS["quota"].search(line):
            out["quota"] += 1
        if PATTERNS["alloc"].search(line):
            out["alloc"] += 1
        if PATTERNS["auth"].search(line):
            out["auth"] += 1
        m = _USAGE.search(line)
        if m:
            sm = _SESSION.search(line)
            sid = sm.group(1) if sm else "u%d" % len(order)
            peer, user = bool(m.group(1)), m.group(2)
            rb, sb = int(m.group(4)), int(m.group(6))
            if sid not in sess:
                sess[sid] = {"user": user, "rb": 0, "sb": 0, "peer_sb": None, "peer_rb": 0}
                order.append(sid)
            if peer:
                sess[sid]["peer_sb"] = sb
                sess[sid]["peer_rb"] = rb
            else:
                sess[sid]["rb"], sess[sid]["sb"] = rb, sb
    for sid in order:
        s = sess[sid]
        uid = s["user"].rpartition(":")[2]
        egress = s["sb"] + (s["peer_sb"] if s["peer_sb"] is not None else s["rb"])
        ingress = s["rb"] + s["peer_rb"]
        out["usages"].append({"user_id": int(uid) if uid.isdigit() else None,
                              "bytes_in": ingress, "bytes_out": egress})
    return out


def parse_proc_net_dev(text, iface=""):
    """-> (iface, rx_bytes, tx_bytes) of the named / first non-lo interface."""
    for line in (text or "").splitlines():
        if ":" not in line:
            continue
        name, _, rest = line.partition(":")
        name = name.strip()
        if name == "lo" or (iface and name != iface):
            continue
        f = rest.split()
        if len(f) >= 9:
            return name, int(f[0]), int(f[8])
    return None, None, None


def rate(prev, cur, dt):
    if prev is None or cur is None or not dt or dt <= 0 or cur < prev:
        return None          # first run / counter reset (reboot, restart)
    return int((cur - prev) / dt)


# ------------------------------------------------------------------ alerts
def evaluate_alerts(sample, lim, recent_quota_errors, server_health=None):
    """-> {key: (active, message)} for the current sample. Pure."""
    t = lim["thresholds"]
    p = usage_pcts(sample, lim)
    res = {}
    if p["alloc"] is not None:
        res["alloc"] = (p["alloc"] >= t["alloc_pct"],
                        "TURN allocations %d of %d (%.0f%%)" % (
                            sample.allocations, lim["alloc_limit"], p["alloc"]))
    if p["bw"] is not None:
        src = "relay" if getattr(sample, "relay_out_bps", None) is not None else "whole-box NIC"
        out = sample.relay_out_bps if src == "relay" else sample.nic_out_bps
        res["bw"] = (p["bw"] >= t["bw_pct"],
                     "TURN bandwidth (%s) %.0f Mbit/s of %.0f Mbit/s budget (%.0f%%)" % (
                         src, out * 8 / 1e6, lim["bw_budget"] * 8 / 1e6, p["bw"]))
    res["quota"] = (recent_quota_errors > 0,
                    "%d TURN '486 quota reached' error(s) in the last %s min — calls are "
                    "being refused" % (recent_quota_errors, t["quota_window_min"]))
    cpu = getattr(sample, "turn_cpu_pct", None)
    if cpu is not None:
        res["cpu"] = (cpu >= t["cpu_pct"], "turnserver CPU %.0f%% of one vCPU" % cpu)
    steal = getattr(sample, "steal_pct", None)
    if steal is not None:
        res["steal"] = (steal >= t["steal_pct"],
                        "CPU steal %.0f%% (T3 credits exhausted or noisy host)" % steal)
    for key, h in (server_health or {}).items():
        res["down:" + key] = (int(h.get("fails", 0) or 0) >= 2,
                              "TURN server %s not answering STUN" % key)
    return res


def dedupe(evals, state, now_ts, realert_min):
    """Alert de-duplication. Returns (to_send [(key, kind, msg)], new_state).
    kind 'fire' on a new or re-armed (after realert_min) condition, 'clear'
    once when it goes away. Pure."""
    state = dict(state or {})
    send = []
    for key, (active, msg) in evals.items():
        st = dict(state.get(key) or {})
        if active:
            last = float(st.get("sent", 0) or 0)
            if not st.get("active") or now_ts - last >= realert_min * 60:
                send.append((key, "fire", msg))
                st["sent"] = now_ts
            st["active"] = True
        elif st.get("active"):
            send.append((key, "clear", msg))
            st = {"active": False, "sent": st.get("sent", 0)}
        state[key] = st
    return send, state


def deliver(sends):
    """Owner alert path: core.push.notify_owner (FCM + email) and an in-app
    FamilyAlert row for each superuser (kind turn_capacity)."""
    if not sends:
        return 0
    from .push import notify_owner
    from .models import FamilyAlert, User
    fires = [m for _k, kind, m in sends if kind == "fire"]
    clears = [m for _k, kind, m in sends if kind == "clear"]
    if fires:
        body = "\n".join(fires) + "\nSee Owner Admin → Call relay. Guide: owner_actions/CALL_SCALING.md"
        notify_owner("Assisto call relay near its limit", body)
        for o in User.objects.filter(is_superuser=True)[:5]:
            FamilyAlert.objects.create(user=o, kind="turn_capacity",
                                       title="Call relay (TURN) near its limit",
                                       body=body[:2000], severity="high",
                                       payload={"source": "turn_monitor"})
    if clears:
        notify_owner("Assisto call relay back to normal",
                     "Recovered: " + "; ".join(clears))
    return len(sends)


# ------------------------------------------------------------------ probes
def stun_probe(host, port, timeout=1.5):
    """One STUN Binding request over UDP; True on a Binding success response."""
    txn = os.urandom(12)
    req = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + txn
    try:
        infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(timeout)
            s.sendto(req, infos[0][4])
            data, _ = s.recvfrom(2048)
        return len(data) >= 20 and data[:2] == b"\x01\x01" and data[8:20] == txn
    except (OSError, IndexError):
        return False


def cli_ps(host, port, password, timeout=3):
    """coturn CLI over telnet: password, `ps`, quit. Returns raw text or None."""
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            s.settimeout(timeout)
            buf = b""

            def read_until(tokens, limit=2_000_000):
                nonlocal buf
                end = time.time() + timeout
                while time.time() < end and len(buf) < limit:
                    if any(t in buf for t in tokens):
                        return
                    try:
                        chunk = s.recv(65536)
                    except socket.timeout:
                        return
                    if not chunk:
                        return
                    buf += chunk
            read_until([b"assword", b">"])
            s.sendall(password.encode() + b"\r\n")
            read_until([b">"])
            buf = b""
            s.sendall(b"ps\r\n")
            read_until([b"Total sessions"])
            read_until([b"\n> ", b"> "])
            try:
                s.sendall(b"quit\r\n")
            except OSError:
                pass
        # strip telnet IAC negotiation bytes
        return re.sub(rb"\xff[\xfb-\xfe].|\xff.", b"", buf).decode("utf-8", "replace")
    except OSError:
        return None


def turnserver_pid():
    for p in glob.glob("/proc/[0-9]*/comm"):
        try:
            if open(p).read().strip() == "turnserver":
                return int(p.split("/")[2])
        except OSError:
            continue
    return None


def proc_cpu_ticks(pid):
    try:
        f = open("/proc/%d/stat" % pid).read().rpartition(")")[2].split()
        return int(f[11]) + int(f[12])          # utime + stime (fields 14,15)
    except (OSError, ValueError, IndexError):
        return None


def proc_stat_cpu():
    """-> (total_jiffies, steal_jiffies) from /proc/stat."""
    try:
        f = open("/proc/stat").readline().split()[1:]
        vals = [int(x) for x in f]
        return sum(vals[:8]), (vals[7] if len(vals) > 7 else 0)
    except (OSError, ValueError):
        return None, None


def newest_log(pattern):
    files = [f for f in glob.glob(pattern) if os.path.isfile(f)]
    return max(files, key=os.path.getmtime) if files else None


def read_new_log(path, state):
    """New lines since the stored (path, inode, offset). A new file / rotation
    / truncation restarts at 0; the very first run starts at END (no backfill
    of an old log into 'last 5 min')."""
    try:
        st = os.stat(path)
    except OSError:
        return [], state
    prev = state.get("log") or {}
    same = prev.get("path") == path and prev.get("ino") == st.st_ino
    if not prev:
        off = st.st_size
    elif same and prev.get("off", 0) <= st.st_size:
        off = prev.get("off", 0)
    else:
        off = 0
    lines = []
    try:
        with open(path, "rb") as fh:
            fh.seek(off)
            data = fh.read(8_000_000)
            off += len(data)
        lines = data.decode("utf-8", "replace").splitlines()
    except OSError:
        pass
    state = dict(state)
    state["log"] = {"path": path, "ino": st.st_ino, "off": off}
    return lines, state


# ------------------------------------------------------------------ cost
GIB = 1024 ** 3     # AWS bills data transfer per GB = 2^30 bytes


def bytes_per_min_estimate(kbps_per_direction):
    """Egress bytes per relayed minute: both directions leave the server once."""
    return kbps_per_direction * 1000.0 / 8.0 * 2 * 60


def usd_for_bytes(n_bytes, usd_per_gb):
    return n_bytes / GIB * usd_per_gb


def relay_cost(days=30, now=None):
    """Profit Guard: real cost per relayed VOICE / VIDEO minute.
    Measured (TurnRelayUsage bytes ÷ minutes of the matched relayed calls)
    when >= 3 matched calls of that kind exist in the window, else the
    documented bitrate ESTIMATE (clearly flagged). Totals use relayed minutes
    from CallSession.relayed + CallRecord.duration_sec (+ shop live view)."""
    from datetime import timedelta
    from django.conf import settings
    from django.db.models import Sum
    from django.utils import timezone
    from .models import CallRecord, ShopLiveSession, TurnRelayUsage
    now = now or timezone.now()
    since = now - timedelta(days=days)
    price = float(getattr(settings, "TURN_EGRESS_USD_PER_GB", 0.1093))
    try:
        from .billing import cfg as _cfg
        usd_bdt = float(_cfg().get("usd_bdt") or 0) or 120.0
    except Exception:
        usd_bdt = 120.0
    est = {"voice": float(getattr(settings, "TURN_EST_VOICE_KBPS", 52)),
           "video": float(getattr(settings, "TURN_EST_VIDEO_KBPS", 1000))
           + float(getattr(settings, "TURN_EST_VOICE_KBPS", 52))}
    rows = {}
    for kind in ("voice", "video"):
        calls = CallRecord.objects.filter(kind=kind, started_at__gte=since,
                                          session__relayed=True)
        relayed_min = (calls.aggregate(s=Sum("duration_sec"))["s"] or 0) / 60.0
        used = TurnRelayUsage.objects.filter(call_kind=kind, at__gte=since,
                                             call_id__isnull=False)
        ids = set(used.values_list("call_id", flat=True))
        matched_min = (CallRecord.objects.filter(id__in=ids).aggregate(
            s=Sum("duration_sec"))["s"] or 0) / 60.0
        b = used.aggregate(s=Sum("bytes_out"))["s"] or 0
        measured = len(ids) >= 3 and matched_min > 0
        bpm = (b / matched_min) if measured else bytes_per_min_estimate(est[kind])
        usd_min = usd_for_bytes(bpm, price)
        rows[kind] = {
            "measured": measured, "estimate": not measured,
            "matched_calls": len(ids),
            "bytes_per_min": int(bpm), "mb_per_min": round(bpm / 1e6, 2),
            "usd_per_min": round(usd_min, 6), "bdt_per_min": round(usd_min * usd_bdt, 4),
            "relayed_calls": calls.count(), "relayed_min": round(relayed_min, 1),
            "total_bdt": round(usd_min * usd_bdt * relayed_min, 2),
            "est_kbps": est[kind]}
    live_s = ShopLiveSession.objects.filter(created__gte=since, relayed=True).aggregate(
        s=Sum("seconds"))["s"] or 0
    live_min = live_s / 60.0
    vid = rows["video"]
    rows["live"] = {"relayed_min": round(live_min, 1),
                    "bdt_per_min": vid["bdt_per_min"], "estimate": vid["estimate"],
                    "total_bdt": round(vid["bdt_per_min"] * live_min, 2)}
    return {"days": days, "usd_per_gb": price, "usd_bdt": usd_bdt,
            "free_tier_note": True, "rows": rows,
            "total_bdt": round(sum(r["total_bdt"] for r in rows.values()), 2)}


def match_usage_to_call(user_id, at, window_min=20):
    """The relayed call this closed TURN session most likely carried: the
    user's most recent relayed call that ended within window_min before `at`
    (or is still running). -> (call_id, kind) or (None, '')."""
    from datetime import timedelta
    from django.db.models import Q
    from .models import CallRecord
    if not user_id:
        return None, ""
    c = (CallRecord.objects.filter(Q(caller_id=user_id) | Q(callee_id=user_id),
                                   session__relayed=True,
                                   started_at__lte=at)
         .filter(Q(ended_at__isnull=True) | Q(ended_at__gte=at - timedelta(minutes=window_min)))
         .order_by("-started_at").first())
    return (c.id, c.kind) if c else (None, "")


# ------------------------------------------------------------------ run
def run_once(state, now=None, probe=stun_probe, ss_text=None, log_lines=None,
             cli_text=None, net_text=None, cpu=None):
    """Take one sample, store it, prune, evaluate + deliver alerts. Every
    source can be injected (tests). Returns (TurnSample, sends, state)."""
    from datetime import timedelta
    import subprocess
    from django.conf import settings
    from django.utils import timezone
    from .models import TurnConfig, TurnRelayUsage, TurnSample
    from . import turn_pool as P
    now = now or timezone.now()
    now_ts = now.timestamp()
    state = dict(state or {})
    srcs = []
    s = TurnSample(at=now)
    dt = now_ts - float(state.get("ts", 0) or 0) if state.get("ts") else None

    # relay sockets
    if ss_text is None:
        try:
            ss_text = subprocess.run(["ss", "-Huan"], capture_output=True, text=True,
                                     timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            ss_text = None
    if ss_text is not None:
        s.allocations = parse_ss_relays(
            ss_text, settings.TURN_RELAY_PORT_MIN, settings.TURN_RELAY_PORT_MAX,
            settings.TURN_RELAY_IP)
        srcs.append("ss")

    # coturn CLI
    if cli_text is None and settings.TURN_CLI_PASSWORD:
        cli_text = cli_ps(settings.TURN_CLI_HOST, settings.TURN_CLI_PORT,
                          settings.TURN_CLI_PASSWORD)
    if cli_text:
        ps = parse_cli_ps(cli_text)
        if ps["sessions"] is not None:
            s.cli_sessions = ps["sessions"]
            s.relay_in_bps, s.relay_out_bps = ps["in_bps"], ps["out_bps"]
            srcs.append("cli")

    # NIC
    if net_text is None:
        try:
            net_text = open("/proc/net/dev").read()
        except OSError:
            net_text = ""
    name, rx, tx = parse_proc_net_dev(net_text, settings.TURN_NET_IFACE)
    prev = state.get("nic") or {}
    if name and prev.get("name") == name:
        s.nic_in_bps = rate(prev.get("rx"), rx, dt)
        s.nic_out_bps = rate(prev.get("tx"), tx, dt)
    if name:
        state["nic"] = {"name": name, "rx": rx, "tx": tx}
        srcs.append("nic")

    # CPU
    if cpu is None:
        pid = turnserver_pid()
        tot, steal = proc_stat_cpu()
        cpu = {"pid": pid, "ticks": proc_cpu_ticks(pid) if pid else None,
               "total": tot, "steal": steal, "hz": os.sysconf("SC_CLK_TCK"),
               "ncpu": os.cpu_count() or 1}
    pc = state.get("cpu") or {}
    if cpu.get("ticks") is not None and pc.get("pid") == cpu.get("pid") and dt:
        d = cpu["ticks"] - (pc.get("ticks") or 0)
        if d >= 0:
            s.turn_cpu_pct = round(100.0 * d / cpu["hz"] / dt, 1)
    if cpu.get("total") is not None and pc.get("total") is not None:
        dtot = cpu["total"] - pc["total"]
        if dtot > 0:
            s.steal_pct = round(100.0 * (cpu["steal"] - pc["steal"]) / dtot, 1)
    state["cpu"] = cpu

    # log
    if log_lines is None:
        path = newest_log(settings.TURN_LOG_PATH)
        log_lines, state = read_new_log(path, state) if path else ([], state)
        if path:
            srcs.append("log")
    parsed = parse_log_lines(log_lines)
    s.quota_errors, s.bw_quota_errors = parsed["quota"], parsed["bw_quota"]
    s.alloc_errors, s.auth_errors = parsed["alloc"], parsed["auth"]
    s.relay_bytes_out = sum(u["bytes_out"] for u in parsed["usages"])

    # server health (STUN probe per configured host)
    cfg = TurnConfig.load()
    servers, _src, _h = P.configured_servers()
    if not servers:
        host = getattr(settings, "TURN_HOST", "")
        servers = [{"host": host, "port": getattr(settings, "TURN_PORT", 3478)}] if host else []
    health = dict(cfg.health or {})
    keys = set()
    for sv in servers:
        key = "%s:%s" % (sv["host"], sv["port"])
        keys.add(key)
        ok = bool(probe(sv["host"], sv["port"]))
        h = dict(health.get(key) or {})
        h["fails"] = 0 if ok else int(h.get("fails", 0) or 0) + 1
        h["ok"], h["ts"] = ok, now_ts
        health[key] = h
    health = {k: v for k, v in health.items() if k in keys}
    s.healthy_servers = sum(1 for v in health.values() if v.get("ok"))
    s.sources = ",".join(srcs)[:60]
    s.save()

    for u in parsed["usages"]:
        cid, kind = match_usage_to_call(u["user_id"], now)
        TurnRelayUsage.objects.create(at=now, user_id=u["user_id"], bytes_in=u["bytes_in"],
                                      bytes_out=u["bytes_out"], call_kind=kind, call_id=cid)

    keep = timezone.now() - timedelta(days=int(getattr(settings, "TURN_SAMPLE_KEEP_DAYS", 14)))
    TurnSample.objects.filter(at__lt=keep).delete()
    TurnRelayUsage.objects.filter(at__lt=keep).delete()

    lim = limits(cfg.thresholds)
    win = now - timedelta(minutes=int(lim["thresholds"]["quota_window_min"]))
    from django.db.models import Sum
    agg = TurnSample.objects.filter(at__gt=win).aggregate(q=Sum("quota_errors"),
                                                          b=Sum("bw_quota_errors"))
    recent_quota = (agg["q"] or 0) + (agg["b"] or 0)
    evals = evaluate_alerts(s, lim, recent_quota, health)
    sends, cfg.alert_state = dedupe(evals, cfg.alert_state, now_ts,
                                    float(lim["thresholds"]["realert_min"]))
    cfg.health = health
    cfg.save(update_fields=["health", "alert_state", "updated_at"])
    deliver(sends)
    state["ts"] = now_ts
    return s, sends, state


def panel_summary(now=None):
    """Owner panel: current sample, 24h peaks, recent rows, limits, alerts."""
    from datetime import timedelta
    from django.db.models import Max, Sum
    from django.utils import timezone
    from .models import FamilyAlert, TurnConfig, TurnSample
    now = now or timezone.now()
    cfg = TurnConfig.load()
    lim = limits(cfg.thresholds)
    cur = TurnSample.objects.order_by("-at").first()
    day = TurnSample.objects.filter(at__gte=now - timedelta(hours=24))
    peak = day.aggregate(alloc=Max("allocations"), sess=Max("cli_sessions"),
                         rout=Max("relay_out_bps"), nout=Max("nic_out_bps"),
                         cpu=Max("turn_cpu_pct"), steal=Max("steal_pct"),
                         q=Sum("quota_errors"), bq=Sum("bw_quota_errors"),
                         ae=Sum("alloc_errors"), au=Sum("auth_errors"))
    stale = cur is None or (now - cur.at) > timedelta(minutes=5)
    pc = usage_pcts(cur, lim) if cur else {"alloc": None, "bw": None, "max": None}
    alerts = FamilyAlert.objects.filter(kind="turn_capacity").order_by("-id")[:10]
    return {"cur": cur, "stale": stale, "pct": pc, "peak": peak, "lim": lim,
            "recent": list(TurnSample.objects.order_by("-at")[:30]),
            "alert_state": cfg.alert_state or {}, "health": cfg.health or {},
            "alerts": [{"title": a.title, "body": a.body,
                        "at": timezone.localtime(a.created_at).strftime("%Y-%m-%d %H:%M")}
                       for a in alerts]}


def load_state(path):
    try:
        return json.loads(open(path).read())
    except (OSError, ValueError):
        return {}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)
