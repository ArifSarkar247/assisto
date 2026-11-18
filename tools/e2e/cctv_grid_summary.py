"""cctv-accuracy: the Wi-Fi live grid proof from one cctv-grid.yml run.

Reads $E2E_DIR/grid_lines.txt (the app's own 10-s meter lines), mem.tsv
(host dumpsys meminfo every 30 s), run.log / crash_lines.txt, and writes
cctv_grid.json + a Markdown table (stdout -> the job summary). Exit 1 when a
hard check fails:
  * the run finished (GRID_E2E_DONE) after >= 10 minutes, the app never died,
    no OutOfMemory / low-memory kill;
  * in the 2x2 and 3x3 phases every tile played the SUB stream;
  * scrolled away, the off-screen cameras sent 0 bytes in 30 s;
  * the camera opened big played the MAIN stream, the grid tiles were off.
Frame rate and data per minute are REPORTED (with the targets: 2x2 >= 5 fps,
3x3 >= 2.5 fps per tile), not hidden when lower.
"""
from __future__ import annotations

import json
import os
import statistics
import sys


def load(d):
    lines, done = [], None
    p = os.path.join(d, "grid_lines.txt")
    for raw in open(p, encoding="utf-8", errors="replace") if os.path.exists(p) else []:
        raw = raw.strip()
        if raw.startswith("GRID_E2E_DONE "):
            try:
                done = json.loads(raw[len("GRID_E2E_DONE "):])
            except ValueError:
                pass
        elif raw.startswith("GRID_E2E "):
            try:
                lines.append(json.loads(raw[len("GRID_E2E "):]))
            except ValueError:
                pass
    mem = []
    p = os.path.join(d, "mem.tsv")
    for raw in open(p) if os.path.exists(p) else []:
        f = raw.rstrip("\n").split("\t")
        try:
            mem.append({"t": int(f[0]), "pss_kb": int(f[1]) if f[1] else None,
                        "rss_kb": int(f[2]) if len(f) > 2 and f[2] else None,
                        "avail_kb": int(f[3]) if len(f) > 3 and f[3] else None})
        except (ValueError, IndexError):
            pass
    return lines, done, mem


def phase_stats(lines, phase, skip_s=20):
    rows = [x for x in lines if x.get("phase") == phase]
    if not rows:
        return None
    t_first = rows[0].get("t_s", 0)
    rows = [x for x in rows if x.get("t_s", 0) - t_first >= skip_s] or rows
    fps, kb, mb, rss, qs = [], [], [], [], set()
    for r in rows:
        live = [t for t in r.get("tiles", []) if t.get("q") != "off"]
        fps += [t.get("fps", 0) for t in live]
        kb += [t.get("kb_min", 0) for t in live]
        mb.append(r.get("mb_min") or 0)
        if r.get("rss_mb"):
            rss.append(r["rss_mb"])
        qs |= {t.get("q") for t in r.get("tiles", [])}
    return {
        "samples": len(rows),
        "tile_fps_median": round(statistics.median(fps), 1) if fps else 0,
        "tile_fps_p10": round(sorted(fps)[max(0, len(fps) // 10 - 1)], 1) if fps else 0,
        "tile_kb_min_median": round(statistics.median(kb)) if kb else 0,
        "mb_per_min_median": round(statistics.median(mb), 2) if mb else 0,
        "rss_mb_max": max(rss) if rss else None,
        "qualities": sorted(q for q in qs if q),
    }


def main(d):
    lines, done, mem = load(d)
    run_log = open(os.path.join(d, "run.log")).read() if os.path.exists(os.path.join(d, "run.log")) else ""
    crash = open(os.path.join(d, "crash_lines.txt")).read().strip() if os.path.exists(
        os.path.join(d, "crash_lines.txt")) else ""
    out = {"phases": {p: phase_stats(lines, p) for p in ("grid4", "grid9", "scroll", "big")},
           "done": done, "died": "APP_DIED" in run_log, "crash_lines": crash.splitlines()[:10]}
    pss = [m["pss_kb"] for m in mem if m.get("pss_kb")]
    out["pss_mb_max"] = round(max(pss) / 1024) if pss else None
    out["pss_mb_median"] = round(statistics.median(pss) / 1024) if pss else None
    av = [m["avail_kb"] for m in mem if m.get("avail_kb")]
    out["device_avail_mb_min"] = round(min(av) / 1024) if av else None
    out["mem_samples"] = len(mem)

    checks = {}
    minutes = float((done or {}).get("minutes") or 0)
    checks["ran >= 10 min, finished"] = bool(done) and minutes >= 10
    checks["no crash / kill"] = not out["died"] and not any(
        k in crash for k in ("FATAL EXCEPTION", "OutOfMemory", "lowmemorykiller"))
    g4 = (done or {}).get("grid4") or []
    g9 = (done or {}).get("grid9") or []
    checks["2x2: all tiles SUB"] = len(g4) == 4 and all(q == "sub" for q in g4)
    checks["3x3: all tiles SUB"] = len(g9) == 9 and all(q == "sub" for q in g9)
    st = (done or {}).get("scroll_top") or {}
    off = [i for i, q in enumerate(st.get("quality") or []) if q == "off"]
    b30 = st.get("bytes_30s") or []
    checks["off-screen tiles OFF + 0 bytes"] = bool(off) and all(b30[i] == 0 for i in off if i < len(b30))
    big = (done or {}).get("big") or {}
    checks["big = MAIN, grid OFF"] = big.get("quality") == "main" and all(
        q == "off" for q in big.get("grid_while_big") or ["x"]) and (big.get("frames") or 0) > 0
    out["checks"] = checks
    with open(os.path.join(d, "cctv_grid.json"), "w") as f:
        json.dump(out, f, indent=1)

    print("### Wi-Fi live grid on a 2 GB API 33 emulator (cctv-accuracy)\n")
    print("| phase | tile fps (median / p10) | data per tile (KB/min) | all tiles (MB/min) | app RSS max (MB) | streams |")
    print("|---|---|---|---|---|---|")
    for p, s in out["phases"].items():
        if s:
            print("| %s | %s / %s | %s | %s | %s | %s |" % (
                p, s["tile_fps_median"], s["tile_fps_p10"], s["tile_kb_min_median"],
                s["mb_per_min_median"], s["rss_mb_max"], ",".join(s["qualities"])))
    print("\nPSS max %s MB (median %s), device MemAvailable min %s MB, %d samples; minutes %s" % (
        out["pss_mb_max"], out["pss_mb_median"], out["device_avail_mb_min"], len(mem), minutes))
    if big:
        print("big view: %s, %s fps, %s KB/min" % (big.get("quality"), big.get("fps"), big.get("kb_min")))
    if st:
        print("scrolled: quality %s, bytes in 30 s %s" % (st.get("quality"), b30))
    for k, v in checks.items():
        print("- %s: %s" % ("PASS" if v else "FAIL", k))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.environ.get("E2E_DIR", "/tmp/assisto-grid-e2e")))
