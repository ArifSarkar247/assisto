#!/usr/bin/env python3
"""ads-nine: count network traffic to Google's AD hosts per proof phase.

Input (written by tools/reality/run_flows.sh for the opt-in "ads" group):
  <out>/ads.pcap          host capture (tcpdump -i any) of DNS + 443 traffic
  <out>/ads_phases.log    "<epoch seconds> <phase> begin|end" (host clock)

For every phase window it counts, from the RUNNER side (independent of the
app's own request log):
  dns   DNS queries for an ad host name (the emulator's resolver goes
        through the runner)
  tls   TLS ClientHellos whose SNI is an ad host
  data  packets with payload on a TCP flow that began with such a hello
        (a kept-alive connection reused for a later request still counts)
  quic  UDP/443 packets to an IP an ad host name resolved to

Writes <out>/ads_net.json and <out>/ads_net.md. Pure stdlib; never raises on
a bad packet. Usage: ads_netcount.py <out_dir>
"""
import json
import struct
import sys
from pathlib import Path

AD_HOST_PARTS = (
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "admob.com", "adservice.google.", "googleads.", "imasdk.googleapis.com",
    "pagead", "ads.google.com",
)


def is_ad_host(name):
    n = (name or "").lower().rstrip(".")
    return any(p in n for p in AD_HOST_PARTS)


def _packets(path):
    """(ts, linktype, frame bytes) from a classic pcap file."""
    data = Path(path).read_bytes()
    if len(data) < 24:
        return
    magic = data[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        e = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        e = ">"
    else:
        return
    nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    link = struct.unpack(e + "I", data[20:24])[0]
    i = 24
    while i + 16 <= len(data):
        sec, frac, incl, _orig = struct.unpack(e + "IIII", data[i:i + 16])
        i += 16
        frame = data[i:i + incl]
        i += incl
        yield sec + frac / (1e9 if nano else 1e6), link, frame


def _l3(link, f):
    """-> (ip_version, ip_packet) or (None, None)."""
    try:
        if link == 1:          # Ethernet
            et, off = struct.unpack("!H", f[12:14])[0], 14
            if et == 0x8100:
                et, off = struct.unpack("!H", f[16:18])[0], 18
        elif link == 113:      # Linux cooked v1
            et, off = struct.unpack("!H", f[14:16])[0], 16
        elif link == 276:      # Linux cooked v2
            et, off = struct.unpack("!H", f[0:2])[0], 20
        elif link in (12, 101, 228, 229):  # raw IP
            v = f[0] >> 4
            return (v, f) if v in (4, 6) else (None, None)
        else:
            return None, None
        if et == 0x0800:
            return 4, f[off:]
        if et == 0x86DD:
            return 6, f[off:]
    except Exception:
        pass
    return None, None


def _l4(v, p):
    """-> (proto, src, dst, sport, dport, payload)."""
    if v == 4:
        ihl = (p[0] & 0x0F) * 4
        proto = p[9]
        src, dst = p[12:16], p[16:20]
        seg = p[ihl:]
    else:
        proto = p[6]
        src, dst = p[8:24], p[24:40]
        seg = p[40:]
    if proto == 6 and len(seg) >= 20:
        sp, dp = struct.unpack("!HH", seg[:4])
        off = (seg[12] >> 4) * 4
        return "tcp", src, dst, sp, dp, seg[off:]
    if proto == 17 and len(seg) >= 8:
        sp, dp = struct.unpack("!HH", seg[:4])
        return "udp", src, dst, sp, dp, seg[8:]
    return None, src, dst, 0, 0, b""


def _qname(msg, off):
    labels, jumps = [], 0
    while off < len(msg) and jumps < 20:
        n = msg[off]
        if n == 0:
            return ".".join(labels), off + 1
        if n & 0xC0 == 0xC0:
            ptr = ((n & 0x3F) << 8) | msg[off + 1]
            name, _ = _qname(msg, ptr)
            labels.append(name)
            return ".".join(labels), off + 2
        labels.append(msg[off + 1:off + 1 + n].decode("ascii", "replace"))
        off += 1 + n
        jumps += 1
    return ".".join(labels), off


def dns_parse(msg):
    """-> (is_response, qname, [answer ip bytes])."""
    if len(msg) < 12:
        return None
    flags, qd, an = struct.unpack("!HHH", msg[2:8])
    if qd < 1:
        return None
    name, off = _qname(msg, 12)
    off += 4
    ips = []
    for _ in range(an):
        try:
            _, off = _qname(msg, off)
            typ, _cls, _ttl, rdl = struct.unpack("!HHIH", msg[off:off + 10])
            off += 10
            if typ in (1, 28):
                ips.append(bytes(msg[off:off + rdl]))
            off += rdl
        except Exception:
            break
    return bool(flags & 0x8000), name, ips


def tls_sni(payload):
    """SNI of a TLS ClientHello at the start of [payload], else None."""
    try:
        if len(payload) < 43 or payload[0] != 0x16 or payload[5] != 0x01:
            return None
        p = 9 + 2 + 32
        sid = payload[p]
        p += 1 + sid
        cs = struct.unpack("!H", payload[p:p + 2])[0]
        p += 2 + cs
        cm = payload[p]
        p += 1 + cm
        ext_end = p + 2 + struct.unpack("!H", payload[p:p + 2])[0]
        p += 2
        while p + 4 <= ext_end:
            et, el = struct.unpack("!HH", payload[p:p + 4])
            if et == 0:
                n = struct.unpack("!H", payload[p + 7:p + 9])[0]
                return payload[p + 9:p + 9 + n].decode("ascii", "replace")
            p += 4 + el
    except Exception:
        return None
    return None


def phases(path):
    """{name: [begin, end]} from the host-stamped log (last pair wins)."""
    out, open_ = {}, {}
    try:
        lines = Path(path).read_text().splitlines()
    except Exception:
        return out
    for ln in lines:
        parts = ln.split()
        if len(parts) != 3:
            continue
        try:
            t = float(parts[0])
        except ValueError:
            continue
        name, edge = parts[1], parts[2]
        if edge == "begin":
            open_[name] = t
        elif edge == "end" and name in open_:
            out[name] = [open_.pop(name), t]
    return out


def count(pcap, windows):
    ad_ips, ad_flows = set(), set()
    events = []   # (ts, kind, detail)
    for ts, link, frame in _packets(pcap):
        v, ip = _l3(link, frame)
        if v is None:
            continue
        try:
            proto, src, dst, sp, dp, pl = _l4(v, ip)
        except Exception:
            continue
        if proto == "udp" and 53 in (sp, dp):
            d = dns_parse(pl)
            if not d:
                continue
            resp, name, ips = d
            if is_ad_host(name):
                if resp:
                    ad_ips.update(ips)
                else:
                    events.append((ts, "dns", name))
        elif proto == "tcp" and pl:
            key = frozenset(((src, sp), (dst, dp)))
            sni = tls_sni(pl)
            if sni and is_ad_host(sni):
                ad_flows.add(key)
                events.append((ts, "tls", sni))
            elif key in ad_flows:
                events.append((ts, "data", ""))
        elif proto == "udp" and 443 in (sp, dp) and (dst in ad_ips or src in ad_ips):
            events.append((ts, "quic", ""))
    # DNS queries go out twice with -i any (lo + eth0) and are retried:
    # one per name per second is one lookup
    seen, uniq = set(), []
    for ts, k, d in sorted(events):
        key = (k, d, int(ts)) if k in ("dns", "tls") else (k, ts)
        if key in seen:
            continue
        seen.add(key)
        uniq.append((ts, k, d))
    res = {}
    for name, (b, e) in windows.items():
        inside = [x for x in uniq if b <= x[0] <= e]
        res[name] = {
            "seconds": round(e - b, 1),
            "dns": sum(1 for x in inside if x[1] == "dns"),
            "tls": sum(1 for x in inside if x[1] == "tls"),
            "data": sum(1 for x in inside if x[1] == "data"),
            "quic": sum(1 for x in inside if x[1] == "quic"),
            "hosts": sorted({x[2] for x in inside if x[2]}),
        }
    return res, {"ad_ips": len(ad_ips), "ad_flows": len(ad_flows),
                 "events_total": len(uniq)}


def main(out):
    out = Path(out)
    pcap, log = out / "ads.pcap", out / "ads_phases.log"
    if not pcap.exists():
        print("ads_netcount: no ads.pcap")
        return 0
    windows = phases(log)
    res, meta = count(pcap, windows)
    zero = [n for n in res if not n.startswith("free_banner")]
    verdict = {
        "zero_phases_clean": all(sum(res[n][k] for k in ("dns", "tls", "data", "quic")) == 0
                                 for n in zero),
        "banner_phase_seen_ads": bool(res.get("free_banner")
                                      and (res["free_banner"]["dns"] + res["free_banner"]["tls"]
                                           + res["free_banner"]["data"] + res["free_banner"]["quic"]) > 0),
    }
    (out / "ads_net.json").write_text(json.dumps(
        {"phases": res, "meta": meta, "verdict": verdict}, indent=2))
    rows = ["| phase | seconds | DNS ad-host queries | TLS hellos to ad hosts | data pkts on ad flows | QUIC to ad IPs |",
            "|---|---|---|---|---|---|"]
    for n, r in res.items():
        rows.append("| %s | %s | %d | %d | %d | %d |" % (n, r["seconds"], r["dns"], r["tls"],
                                                       r["data"], r["quic"]))
    md = ("## Ads network count (runner packet capture)\n\n" + "\n".join(rows)
          + "\n\nverdict: %s · meta: %s\n" % (json.dumps(verdict), json.dumps(meta)))
    (out / "ads_net.md").write_text(md)
    print(md)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "reality_out"))
