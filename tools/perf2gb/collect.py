#!/usr/bin/env python3
"""perf2gb: turn one run's evidence (tools/perf2gb/run_perf.sh) into
perf2gb.json + perf2gb.md.

usage: collect.py <perf_out dir> [--profile 2gb] [--run-id N]

Targets (owner order 27 Oct): cold start to interactive home <= 3.0 s on the
2 GB profile (quality bar: < 3.5 s on 2 GB, < 2 s on a mid phone), screen open
<= 800 ms, frame p90 <= 16 ms with < 5 % janky frames, PSS <= 250 MB, no
low-memory kill.
"""
import json
import re
import statistics
import sys
from pathlib import Path

TARGET = {"cold_home_ms": 3000, "open_ms": 800, "frame_p90_ms": 16.0,
          "janky_pct": 5.0, "pss_mb": 250}
COLD_BAR = {"2gb": 3500, "mid": 2000}


def _read(p):
    try:
        return Path(p).read_text(errors="replace")
    except OSError:
        return ""


def parse_device(out):
    d = {}
    for line in _read(out / "device.txt").splitlines():
        if "=" in line and not line.startswith(" "):
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
        m = re.match(r"MemTotal:\s+(\d+) kB", line)
        if m:
            d["mem_total_mb"] = round(int(m.group(1)) / 1024)
    return d


# ------------------------------------------------------------------ logcat
LINE = re.compile(r"^\s*(\d+\.\d+)\s+\d+\s+\d+\s+([VDIWEF])\s+(\S+?)\s*:\s?(.*)$")


def logcat_lines(out):
    for raw in _read(out / "live_logcat.txt").splitlines():
        m = LINE.match(raw)
        if m:
            yield float(m.group(1)) * 1000, m.group(3), m.group(4)


def parse_cold(out):
    """One row per cold start: am start -W TotalTime + app marks relative to
    the ActivityTaskManager START line (both device clock)."""
    lines = list(logcat_lines(out))
    starts = [(ts, msg) for ts, tag, msg in lines
              if tag.startswith("ActivityTaskManager") and "START u0" in msg
              and "com.assisto.assisto" in msg]
    marks = []
    for ts, tag, msg in lines:
        m = re.search(r"ASSISTO_PERF (\w+) (\d{12,})", msg)
        if m:
            marks.append((int(m.group(2)), m.group(1)))
    displayed = []
    for ts, tag, msg in lines:
        m = re.search(r"Displayed com\.assisto\.assisto/\S+: \+(?:(\d+)s)?(\d+)ms", msg)
        if m:
            displayed.append((ts, int(m.group(1) or 0) * 1000 + int(m.group(2))))
    begins = []
    for line in _read(out / "cold" / "markers.txt").splitlines():
        p = line.split()
        if len(p) == 4 and p[0] == "COLD_BEGIN":
            begins.append((p[1], int(p[2]), int(p[3])))
    rows = []
    for label, i, host_t in begins:
        am = _read(out / "cold" / f"{label}_{i}.txt")
        tt = re.search(r"TotalTime:\s*(\d+)", am)
        row = {"label": label, "n": i, "am_total_ms": int(tt.group(1)) if tt else None}
        # the START line closest after this begin (clocks are the same host)
        cand = [s for s in starts if s[0] >= host_t - 3000]
        if cand:
            t0 = cand[0][0]
            nxt = [s[0] for s in starts if s[0] > t0 + 1]
            t1 = nxt[0] if nxt else t0 + 20000
            for ts, name in marks:
                if t0 - 500 <= ts < t1:
                    row.setdefault(name + "_ms", int(ts - t0))
            for ts, ms in displayed:
                if t0 <= ts < t1:
                    row.setdefault("displayed_ms", ms)
        rows.append(row)
    def med(label, key):
        v = [r[key] for r in rows if r["label"] == label and r.get(key) is not None]
        return int(statistics.median(v)) if v else None
    summary = {}
    for label, screen in (("fresh", "language_frame_ms"), ("home", "home_frame_ms")):
        summary[label] = {
            "runs": len([r for r in rows if r["label"] == label]),
            "am_total_ms_median": med(label, "am_total_ms"),
            "first_frame_ms_median": med(label, "first_frame_ms"),
            "screen_ms_median": med(label, screen),
            "displayed_ms_median": med(label, "displayed_ms"),
        }
    return {"runs": rows, "summary": summary}


# ------------------------------------------------------------------ memory
def parse_meminfo(text):
    if not text.strip():
        return None
    m = {}
    t = re.search(r"TOTAL PSS:\s+(\d+)", text) or re.search(r"^\s*TOTAL\s+(\d+)", text, re.M)
    if t:
        m["pss_mb"] = round(int(t.group(1)) / 1024, 1)
    r = re.search(r"TOTAL RSS:\s+(\d+)", text)
    if r:
        m["rss_mb"] = round(int(r.group(1)) / 1024, 1)
    for k in ("Java Heap", "Native Heap", "Code", "Stack", "Graphics", "Private Other", "System"):
        x = re.search(r"^\s*%s:\s+(\d+)" % re.escape(k), text, re.M)
        if x:
            m[k.lower().replace(" ", "_") + "_mb"] = round(int(x.group(1)) / 1024, 1)
    return m or None


def parse_mem(out):
    mem = {}
    for f in sorted((out / "mem").glob("*.txt")):
        v = parse_meminfo(_read(f))
        if v:
            mem[f.stem] = v
    return mem


def parse_rss_peak(out):
    peak = 0
    for line in _read(out / "rss_samples.txt").splitlines():
        for k in ("VmHWM", "VmRSS"):
            m = re.search(k + r":\s*(\d+) kB", line)
            if m:
                peak = max(peak, int(m.group(1)))
    return round(peak / 1024, 1) if peak else None


def parse_lmk(out):
    text = _read(out / "exit_info.txt") + "\n" + _read(out / "exit_info_after_flows.txt")
    low = len(re.findall(r"LOW_MEMORY", text))
    lines = [l for _, tag, l in logcat_lines(out)
             if ("lowmemorykiller" in tag or "lmkd" in tag or "lowmemorykiller" in l)
             and "com.assisto.assisto" in l]
    deaths = [l for l in _read(out / "deaths.txt").splitlines() if l.strip()]
    return {"exit_info_low_memory": low, "lmkd_kills": len(lines), "lmkd_lines": lines[:5],
            "app_deaths_during_flows": deaths}


def parse_battery(out):
    text = _read(out / "batterystats.txt")
    if not text.strip():
        return None
    cpu = re.search(r"Cpu:\s*([0-9hms ]+?)\s*usr\s*\+\s*([0-9hms ]+?)\s*krn", text)

    def ms(s):
        t = 0
        for v, u in re.findall(r"(\d+)(ms|s|m|h)", s or ""):
            t += int(v) * {"ms": 1, "s": 1000, "m": 60000, "h": 3600000}[u]
        return t
    wake = re.findall(r"Wake lock\s+(\S+).*?:\s*([0-9hms ]+)\s*(?:partial|realtime)", text)
    alarms = re.findall(r"Wakeup alarm\s+.*?:\s*(\d+)\s+times", text)
    return {
        "cpu_ms": (ms(cpu.group(1)) + ms(cpu.group(2))) if cpu else None,
        "wakelocks": len(wake),
        "wakeup_alarms": sum(int(a) for a in alarms),
        "lines": [l.strip() for l in text.splitlines()
                  if re.search(r"Cpu:|Wake lock|Wakeup alarm|Foreground|Job |Mobile network|Wi-Fi network", l)][:25],
    }


# ------------------------------------------------------------------ flows
def parse_flows(out):
    p = out / "device" / "perf.json"
    flows = {}
    try:
        for f in json.loads(_read(p) or "{}").get("flows", []):
            flows[f["id"]] = f
    except ValueError:
        pass
    parts = {}
    for _, tag, msg in logcat_lines(out):
        m = re.match(r"PERF_RESULT (\w+) (\d+)/(\d+) (.*)$", msg)
        if m:
            parts.setdefault(m.group(1), {})[int(m.group(2))] = (int(m.group(3)), m.group(4))
    for fid, ch in parts.items():
        n = next(iter(ch.values()))[0]
        if fid in flows or len(ch) != n:
            continue
        try:
            flows[fid] = json.loads("".join(ch[i][1] for i in range(1, n + 1)))
        except ValueError:
            pass
    return [flows[k] for k in sorted(flows)]


def verdict_flow(f, mem):
    opens = f.get("opens") or {}
    worst_open = max([o.get("ready_ms") or 10 ** 6 if o.get("timed_out") else (o.get("ready_ms") or 0)
                      for o in opens.values()] or [0])
    jank = list((f.get("jank") or {}).values()) + [o.get("frames") or {} for o in opens.values()]
    jank = [j for j in jank if j and j.get("frames")]
    scroll = [j for j in (f.get("jank") or {}).values() if j and j.get("frames")]
    src = scroll or jank
    p90 = max([j["frame_ms_p90"] for j in src] or [0])
    ui90 = max([j["build_ms_p90"] for j in src] or [0])
    jp = max([j["janky_pct"] for j in src] or [0])
    jui = max([j["janky_ui_pct"] for j in src] or [0])
    pss = [v.get("pss_mb") for k, v in mem.items() if k.startswith(f["id"] + "__") and v.get("pss_mb")]
    peak_pss = max(pss) if pss else None
    ok_open = worst_open <= TARGET["open_ms"]
    ok_jank = p90 <= TARGET["frame_p90_ms"] and jp < TARGET["janky_pct"]
    ok_jank_ui = ui90 <= TARGET["frame_p90_ms"] and jui < TARGET["janky_pct"]
    ok_mem = peak_pss is not None and peak_pss <= TARGET["pss_mb"]
    return {"worst_open_ms": worst_open if worst_open < 10 ** 6 else None,
            "open_timed_out": any(o.get("timed_out") for o in opens.values()),
            "frame_p90_ms": p90, "janky_pct": jp, "ui_p90_ms": ui90, "janky_ui_pct": jui,
            "peak_pss_mb": peak_pss, "ok_open": ok_open, "ok_jank": ok_jank,
            "ok_jank_ui": ok_jank_ui, "ok_mem": ok_mem, "ran_ok": bool(f.get("ok")),
            "pass": ok_open and ok_jank and ok_mem and bool(f.get("ok"))}


def main():
    out = Path(sys.argv[1])
    profile = "2gb"
    run_id = ""
    if "--profile" in sys.argv:
        profile = sys.argv[sys.argv.index("--profile") + 1]
    if "--run-id" in sys.argv:
        run_id = sys.argv[sys.argv.index("--run-id") + 1]
    mem = parse_mem(out)
    flows = parse_flows(out)
    for f in flows:
        f["verdict"] = verdict_flow(f, mem)
    cold = parse_cold(out)
    lmk = parse_lmk(out)
    try:
        apk = json.loads(_read(out / "apk_sizes.json") or "{}")
    except ValueError:
        apk = {}
    home = cold["summary"]["home"]
    cold_home = home.get("screen_ms_median") or home.get("am_total_ms_median")
    res = {
        "profile": profile, "run_id": run_id, "device": parse_device(out),
        "targets": TARGET, "cold_bar_ms": COLD_BAR.get(profile),
        "cold": cold, "cold_home_ms": cold_home,
        "cold_ok": cold_home is not None and cold_home <= TARGET["cold_home_ms"],
        "cold_bar_ok": cold_home is not None and COLD_BAR.get(profile) and cold_home < COLD_BAR[profile],
        "flows": flows, "mem": mem, "rss_peak_mb": parse_rss_peak(out), "lmk": lmk,
        "lmk_ok": not lmk["lmkd_kills"] and not lmk["exit_info_low_memory"],
        "battery_bg": parse_battery(out), "apk": apk,
    }
    (out / "perf2gb.json").write_text(json.dumps(res, indent=1, ensure_ascii=False))
    md = render_md(res)
    (out / "perf2gb.md").write_text(md)
    print(md)


def _fmt(v, unit=""):
    return "—" if v is None else f"{v}{unit}"


def render_md(r):
    d = r["device"]
    L = [f"# perf2gb — profile `{r['profile']}` (run {r['run_id'] or '?'})", "",
         f"Device: API {d.get('ro.build.version.sdk')}, {d.get('mem_total_mb')} MB RAM visible, "
         f"{d.get('nproc')} cores, {d.get('wm_size')} @ {d.get('wm_density')}, "
         f"heapgrowthlimit={d.get('dalvik.vm.heapgrowthlimit')}, low_ram={d.get('ro.config.low_ram') or 'false'}, "
         f"animations={d.get('window_animation_scale')}", ""]
    c = r["cold"]["summary"]
    L += ["## Cold start (profile APK, median)", "",
          "| start | runs | am TotalTime | first Flutter frame | screen shown | target |",
          "|---|---|---|---|---|---|",
          f"| fresh install → language picker | {c['fresh']['runs']} | {_fmt(c['fresh']['am_total_ms_median'], ' ms')} | "
          f"{_fmt(c['fresh']['first_frame_ms_median'], ' ms')} | {_fmt(c['fresh']['screen_ms_median'], ' ms')} | — |",
          f"| signed in → home | {c['home']['runs']} | {_fmt(c['home']['am_total_ms_median'], ' ms')} | "
          f"{_fmt(c['home']['first_frame_ms_median'], ' ms')} | {_fmt(c['home']['screen_ms_median'], ' ms')} | "
          f"≤ {TARGET['cold_home_ms']} ms {'PASS' if r['cold_ok'] else 'FAIL'} |", ""]
    L += ["## Flows", "",
          "| flow | ran | worst open (ready) | scroll frame p90 | janky % | UI p90 / janky % | peak PSS | verdict |",
          "|---|---|---|---|---|---|---|---|"]
    for f in r["flows"]:
        v = f["verdict"]
        L.append(f"| {f['id']} {f.get('feature', '')} | {'yes' if v['ran_ok'] else 'PARTIAL'} | "
                 f"{_fmt(v['worst_open_ms'], ' ms')}{' (timeout)' if v['open_timed_out'] else ''} | "
                 f"{v['frame_p90_ms']} ms | {v['janky_pct']} | {v['ui_p90_ms']} ms / {v['janky_ui_pct']} | "
                 f"{_fmt(v['peak_pss_mb'], ' MB')} | {'PASS' if v['pass'] else 'FAIL'} |")
    L += ["", "### Every screen open", "", "| flow | screen | first frame | ready |", "|---|---|---|---|"]
    for f in r["flows"]:
        for k, o in (f.get("opens") or {}).items():
            L.append(f"| {f['id']} | {k} | {_fmt(o.get('first_frame_ms'), ' ms')} | "
                     f"{_fmt(o.get('ready_ms'), ' ms')}{' TIMEOUT' if o.get('timed_out') else ''} |")
    L += ["", "## Memory snapshots (dumpsys meminfo)", "",
          "| when | PSS | RSS | Java heap | Native heap | Graphics |", "|---|---|---|---|---|---|"]
    for k, m in r["mem"].items():
        L.append(f"| {k} | {_fmt(m.get('pss_mb'), ' MB')} | {_fmt(m.get('rss_mb'), ' MB')} | "
                 f"{_fmt(m.get('java_heap_mb'), ' MB')} | {_fmt(m.get('native_heap_mb'), ' MB')} | "
                 f"{_fmt(m.get('graphics_mb'), ' MB')} |")
    lmk = r["lmk"]
    L += ["", f"Peak RSS (3 s sampler): {_fmt(r['rss_peak_mb'], ' MB')}. "
          f"Low-memory kills: lmkd {lmk['lmkd_kills']}, exit-info LOW_MEMORY {lmk['exit_info_low_memory']}, "
          f"app deaths during flows {len(lmk['app_deaths_during_flows'])}.", ""]
    b = r.get("battery_bg")
    if b:
        L += [f"Background 5 min (screen off, unplugged): CPU {_fmt(b['cpu_ms'], ' ms')}, "
              f"wakelocks {b['wakelocks']}, wakeup alarms {b['wakeup_alarms']}.", ""]
    if r.get("apk"):
        L += ["APK sizes: " + ", ".join(f"{k} {v}" for k, v in r["apk"].items()), ""]
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    main()
