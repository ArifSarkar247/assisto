#!/usr/bin/env python3
"""faststart: turn one start-speed run (tools/startspeed/run_start.sh) into
startspeed.json + startspeed.md.

usage: collect.py <start_out dir> [--profile 2gb] [--run-id N]

Owner targets (10 Nov 00:55): cold start to usable Home < 2 s on a low-end
phone, warm start < 1 s, My Circle chat list < 1 s after the tap — all with
no internet.

Per run: `am start -W` TotalTime + LaunchState, and every ASSISTO_PERF step
mark (app/lib/perf/perf_marks.dart) in ms from the ActivityTaskManager
START line (same device clock). "screen" = which root screen the run reached
(home / login / language), so "offline -> login screen" is visible.
"""
import json
import re
import statistics
import sys
from pathlib import Path

TARGET = {"cold_home_ms": 2000, "warm_ms": 1000, "circle_ms": 1000}
STEPS = ["dart_main", "init_begin", "init_prefs", "init_flags", "init_token",
         "init_db", "init_auth", "first_frame", "language_frame", "login_frame",
         "home_frame", "post_frame_begin", "notifications_ready",
         "home_widget_ready", "push_begin", "push_ready", "ao_open_circle",
         "circle_list_frame", "circle_list_fresh", "circle_list_failed"]
LINE = re.compile(r"^\s*(\d+\.\d+)\s+\d+\s+\d+\s+([VDIWEF])\s+(\S+?)\s*:\s?(.*)$")


def _read(p):
    try:
        return Path(p).read_text(errors="replace")
    except OSError:
        return ""


def lines(out):
    for raw in _read(out / "live_logcat.txt").splitlines():
        m = LINE.match(raw)
        if m:
            yield float(m.group(1)) * 1000, m.group(3), m.group(4)


def parse(out):
    ls = list(lines(out))
    starts = sorted(ts for ts, tag, msg in ls
                    if tag.startswith("ActivityTaskManager") and "START u0" in msg
                    and "com.assisto.assisto" in msg)
    marks = []
    for ts, tag, msg in ls:
        m = re.search(r"ASSISTO_PERF (\w+) (\d{12,})", msg)
        if m:
            marks.append((int(m.group(2)), m.group(1)))
    begins, ends = [], {}
    for line in _read(out / "runs" / "markers.txt").splitlines():
        p = line.split()
        if len(p) == 4 and p[0] == "BEGIN":
            begins.append((p[1], int(p[2]), int(p[3])))
        elif len(p) == 4 and p[0] == "END":
            ends[(p[1], int(p[2]))] = int(p[3])
    rows = []
    for label, i, t_begin in begins:
        am = _read(out / "runs" / f"{label}_{i}.txt")
        tt = re.search(r"TotalTime:\s*(\d+)", am)
        st = re.search(r"LaunchState:\s*(\w+)", am)
        row = {"label": label, "n": i,
               "am_total_ms": int(tt.group(1)) if tt else None,
               "launch_state": st.group(1) if st else None}
        t_end = ends.get((label, i), t_begin + 40000)
        cand = [s for s in starts if t_begin - 3000 <= s <= t_end]
        t0 = cand[0] if cand else t_begin
        row["t0_from"] = "start_line" if cand else "host_begin"
        for ts, name in marks:
            if t0 - 500 <= ts <= t_end:
                row.setdefault(name + "_ms", int(ts - t0))
        screen = None
        for s in ("home", "login", "language"):
            if row.get(s + "_frame_ms") is not None:
                screen = s
                break
        row["screen"] = screen
        a, b = row.get("ao_open_circle_ms"), row.get("circle_list_frame_ms")
        if a is not None and b is not None:
            row["circle_open_ms"] = b - a
        f = row.get("circle_list_fresh_ms")
        if a is not None and f is not None:
            row["circle_fresh_ms"] = f - a
        if row.get("circle_list_failed_ms") is not None:
            row["circle_failed"] = True
        rows.append(row)
    return rows


def med(rows, label, key):
    v = [r[key] for r in rows if r["label"] == label and r.get(key) is not None]
    return int(statistics.median(v)) if v else None


def summarize(rows):
    labels = []
    for r in rows:
        if r["label"] not in labels:
            labels.append(r["label"])
    s = {}
    for lb in labels:
        rs = [r for r in rows if r["label"] == lb]
        screens = sorted({r["screen"] or "?" for r in rs})
        d = {"runs": len(rs), "screens": screens,
             "am_total_ms": med(rows, lb, "am_total_ms"),
             "launch_state": sorted({r["launch_state"] or "?" for r in rs}),
             "circle_open_ms": med(rows, lb, "circle_open_ms"),
             "circle_fresh_ms": med(rows, lb, "circle_fresh_ms"),
             "circle_failed_runs": sum(1 for r in rs if r.get("circle_failed"))}
        for st in STEPS:
            d[st + "_ms"] = med(rows, lb, st + "_ms")
        s[lb] = d
    return s


def verdicts(s):
    v = {}
    for env in ("online", "offline", "liefi"):
        h = s.get("home_" + env) or {}
        hf = h.get("home_frame_ms")
        v["cold_home_" + env] = {
            "ms": hf, "target": TARGET["cold_home_ms"], "screens": h.get("screens"),
            "ok": hf is not None and hf < TARGET["cold_home_ms"] and h.get("screens") == ["home"]}
        c = s.get("circle_" + env) or {}
        co = c.get("circle_open_ms")
        v["circle_" + env] = {
            "ms": co, "target": TARGET["circle_ms"],
            # offline the background refresh fails by design; the LIST must show
            "ok": co is not None and co < TARGET["circle_ms"]}
    for kind in ("hot", "warm"):
        for env in ("online", "offline"):
            w = s.get(f"{kind}_{env}") or {}
            ms = w.get("am_total_ms")
            if kind == "warm" and w.get("home_frame_ms") is not None:
                ms = max(ms or 0, w["home_frame_ms"])
            v[f"{kind}_{env}"] = {"ms": ms, "target": TARGET["warm_ms"],
                                  "ok": ms is not None and ms < TARGET["warm_ms"]}
    return v


def render_md(r):
    s, v = r["summary"], r["verdicts"]
    o = [f"# Start speed — profile {r['profile']} (run {r.get('run_id')})", "",
         "Device: " + ", ".join(f"{k}={r['device'].get(k)}" for k in
                                ("ro.build.version.sdk", "mem_total_mb", "nproc", "wm_size")), "",
         "## Verdicts (median)", "", "| check | ms | target | screen | ok |", "|---|---|---|---|---|"]
    for k, x in v.items():
        o.append(f"| {k} | {x['ms']} | < {x['target']} | {','.join(x.get('screens') or [])} | "
                 f"{'PASS' if x['ok'] else 'FAIL'} |")
    o += ["", "## Every run kind (median ms from the Android START line)", ""]
    cols = ["am_total_ms", "dart_main_ms", "init_prefs_ms", "init_flags_ms", "init_token_ms",
            "init_db_ms", "init_auth_ms", "first_frame_ms", "home_frame_ms", "login_frame_ms",
            "language_frame_ms", "notifications_ready_ms", "push_ready_ms", "circle_open_ms",
            "circle_fresh_ms"]
    o.append("| run | n | state | screen | " + " | ".join(c[:-3] for c in cols) + " |")
    o.append("|" + "---|" * (len(cols) + 4))
    for lb, d in s.items():
        o.append(f"| {lb} | {d['runs']} | {','.join(d['launch_state'])} | {','.join(d['screens'])} | "
                 + " | ".join(str(d.get(c)) for c in cols) + " |")
    return "\n".join(o) + "\n"


def device(out):
    d = {}
    for line in _read(out / "device.txt").splitlines():
        if "=" in line:
            k, val = line.split("=", 1)
            d[k.strip()] = val.strip()
        m = re.match(r"MemTotal:\s+(\d+) kB", line)
        if m:
            d["mem_total_mb"] = round(int(m.group(1)) / 1024)
    return d


def main():
    out = Path(sys.argv[1])
    profile = sys.argv[sys.argv.index("--profile") + 1] if "--profile" in sys.argv else "2gb"
    run_id = sys.argv[sys.argv.index("--run-id") + 1] if "--run-id" in sys.argv else None
    rows = parse(out)
    s = summarize(rows)
    r = {"profile": profile, "run_id": run_id, "device": device(out), "targets": TARGET,
         "summary": s, "verdicts": verdicts(s), "runs": rows,
         "net_state": _read(out / "net_state.txt").splitlines()}
    (out / "startspeed.json").write_text(json.dumps(r, indent=1, ensure_ascii=False))
    (out / "startspeed.md").write_text(render_md(r))
    print(render_md(r))


if __name__ == "__main__":
    main()
