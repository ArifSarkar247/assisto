#!/usr/bin/env python3
"""speedproof guard — fail when a measured screen got > 20% slower.

    python3 tools/speedproof/guard.py perf_out/perf2gb.json [tools/speedproof/baseline.json]
    python3 tools/speedproof/guard.py perf_out/perf2gb.json --write-baseline out.json

Input: perf2gb.json from tools/perf2gb/collect.py (perf2gb.yml, 2 GB
emulator profile). Every timed screen open of every perf flow is a "screen"
(`ready_ms`: tap -> page fully shown, no spinner), plus the process-cold
route opens (`route_cold`, app killed -> icon -> screen first frame).

A screen REGRESSES when it is slower than baseline by more than `slack_pct`
percent AND by more than `floor_ms` (one or two emulator frames of jitter on
a 300 ms screen are not a regression). A screen in the baseline that was not
measured (or timed out) also fails: a broken measurement must not pass.
Baselines are only ever LOWERED by hand after a real speed fix (see
owner_actions/SPEED_PROOF_BN.md); a "provisional" baseline only reports.
"""
import json
import math
import sys


def measured(perf):
    """{screen label: ready ms or None} from a perf2gb.json dict."""
    out = {}
    for f in perf.get("flows") or []:
        for label, o in (f.get("opens") or {}).items():
            if not isinstance(o, dict):
                continue
            out[label] = None if o.get("timed_out") else o.get("ready_ms")
    for route, v in ((perf.get("route_cold") or {}).get("summary") or {}).items():
        out["proc_" + route] = v.get("frame_ms_median")
    return out


def compare(base, got):
    slack = float(base.get("slack_pct", 20)) / 100.0
    floor = float(base.get("floor_ms", 50))
    bad = []
    for screen, ref in sorted((base.get("screens") or {}).items()):
        ms = got.get(screen)
        if ms is None:
            bad.append({"screen": screen, "baseline_ms": ref, "ms": None, "why": "not measured / timed out"})
            continue
        if ms > ref * (1 + slack) and ms - ref > floor:
            bad.append({"screen": screen, "baseline_ms": ref, "ms": ms,
                        "why": "+%d%% (+%d ms)" % (round((ms / ref - 1) * 100), ms - ref)})
    return bad


def baseline_from(got, run_id=""):
    """A new baseline from one run: each screen rounded UP to 10 ms."""
    return {"slack_pct": 20, "floor_ms": 50, "run_id": run_id, "provisional": False,
            "screens": {k: int(math.ceil(v / 10.0) * 10) for k, v in sorted(got.items())
                        if isinstance(v, (int, float)) and v > 0}}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    perf = json.load(open(argv[1]))
    got = measured(perf)
    if "--write-baseline" in argv:
        out = argv[argv.index("--write-baseline") + 1]
        json.dump(baseline_from(got, str(perf.get("run_id", ""))), open(out, "w"), indent=1)
        print("baseline written: %s (%d screens)" % (out, len(got)))
        return 0
    bpath = argv[2] if len(argv) > 2 and not argv[2].startswith("--") else "tools/speedproof/baseline.json"
    base = json.load(open(bpath))
    bad = compare(base, got)
    print("| screen | baseline ms | now ms | |")
    print("|---|---|---|---|")
    for s in sorted(set(base.get("screens", {})) | set(got)):
        ref = base.get("screens", {}).get(s)
        b = [x for x in bad if x["screen"] == s]
        print("| %s | %s | %s | %s |" % (s, ref if ref is not None else "new", got.get(s),
                                       ("REGRESSED " + b[0]["why"]) if b else "ok"))
    if bad and not base.get("provisional"):
        for b in bad:
            print("::error::speed regression %s: %s (baseline %s ms, now %s ms)"
                  % (b["screen"], b["why"], b["baseline_ms"], b["ms"]))
        return 1
    if bad:
        print("provisional baseline: %d differences reported, not failing" % len(bad))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
