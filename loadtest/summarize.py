"""Summarise a Locust CSV run -> summary.json + summary.md (CI artifact).
usage: summarize.py <csv_prefix> <label> <out_dir>"""
import csv
import json
import os
import sys


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main(prefix, label, out_dir):
    rows = list(csv.DictReader(open(prefix + "_stats.csv")))
    eps = []
    agg = None
    for r in rows:
        d = {"name": r["Name"], "method": r["Type"],
             "n": int(r["Request Count"]), "fail": int(r["Failure Count"]),
             "p50": num(r["50%"]), "p95": num(r["95%"]), "p99": num(r["99%"]),
             "max": num(r["Max Response Time"]), "rps": num(r["Requests/s"])}
        d["err_pct"] = round(100.0 * d["fail"] / d["n"], 2) if d["n"] else 0.0
        if r["Name"] == "Aggregated":
            agg = d
        else:
            eps.append(d)
    eps.sort(key=lambda d: -(d["p95"] or 0))
    # capacity: the highest user count whose window p95 <= 300 ms and
    # failures < 1 % (from the per-second history during the ramp)
    cap = None
    first_bad = None
    hist = prefix + "_stats_history.csv"
    pts = []
    if os.path.exists(hist):
        t0 = None
        for r in csv.DictReader(open(hist)):
            if r.get("Name") != "Aggregated":
                continue
            ts = num(r.get("Timestamp")) or 0
            t0 = ts if t0 is None else t0
            users = int(num(r.get("User Count")) or 0)
            p95 = num(r.get("95%"))
            rps = num(r.get("Requests/s")) or 0
            fps = num(r.get("Failures/s")) or 0
            if ts - t0 < 30 or not users or p95 is None or rps <= 0:
                continue      # skip the first 30 s (cold start, first syncs)
            pts.append((users, p95, rps, fps))
    # the bar is "broken" only when it stays broken (3 samples in a row);
    # capacity = the most users seen while every sample so far was good.
    for i, (users, p95, rps, fps) in enumerate(pts):
        bad = lambda q: q[1] > 300 or q[3] > 0.01 * q[2]   # noqa: E731
        if bad(pts[i]) and all(bad(q) for q in pts[i:i + 3]) and len(pts[i:i + 3]) == 3:
            first_bad = {"users": users, "p95": p95, "rps": round(rps, 1),
                         "fail_rps": round(fps, 1)}
            break
        if not bad(pts[i]):
            cap = {"users": users, "p95": p95, "rps": round(rps, 1)}
    peak = max(pts, key=lambda q: q[2]) if pts else None
    fails = []
    fpath = prefix + "_failures.csv"
    if os.path.exists(fpath):
        for r in csv.DictReader(open(fpath)):
            fails.append({"name": r.get("Name"), "error": (r.get("Error") or "")[:160],
                          "n": int(num(r.get("Occurrences")) or 0)})
        fails.sort(key=lambda d: -d["n"])
    out = {"label": label, "aggregate": agg, "endpoints": eps,
           "capacity_p95_le_300ms": cap, "first_over_bar": first_bad,
           "peak_rps": peak and {"users": peak[0], "rps": round(peak[2], 1),
                                 "p95": peak[1]},
           "top_failures": fails[:15]}
    os.makedirs(out_dir, exist_ok=True)
    json.dump(out, open(os.path.join(out_dir, "summary.json"), "w"), indent=1)
    md = ["## Load test: %s" % label, ""]
    if agg:
        md.append("**All requests:** n=%d, p50 %s ms, p95 %s ms, p99 %s ms, "
                  "errors %.2f%%, %.1f req/s" % (agg["n"], agg["p50"], agg["p95"],
                                                agg["p99"], agg["err_pct"], agg["rps"] or 0))
    md.append("")
    md.append("Capacity (window p95 <= 300 ms, errors < 1%%): %s" % (
        cap and "%d users @ %.1f req/s" % (cap["users"], cap["rps"]) or "never met"))
    if peak:
        md.append("Peak throughput: %.1f req/s at %d users (window p95 %s ms)"
                  % (peak[2], peak[0], peak[1]))
    md.append("First over the bar (3 samples in a row): %s" % (
        first_bad and "%d users (p95 %s ms, %.1f req/s, %.1f fail/s)" % (
            first_bad["users"], first_bad["p95"], first_bad["rps"],
            first_bad["fail_rps"]) or "never"))
    md += ["", "| endpoint | n | p50 | p95 | p99 | max | err % |",
           "|---|---|---|---|---|---|---|"]
    for d in eps:
        md.append("| %s %s | %d | %s | %s | %s | %s | %.2f |" % (
            d["method"], d["name"], d["n"], d["p50"], d["p95"], d["p99"],
            d["max"], d["err_pct"]))
    if fails:
        md += ["", "Top failures:", ""]
        md += ["- %s × %s: %s" % (f["n"], f["name"], f["error"]) for f in fails[:15]]
    open(os.path.join(out_dir, "summary.md"), "w").write("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main(*sys.argv[1:4])
