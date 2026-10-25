#!/usr/bin/env python3
"""Turn the device's reality results into a class table (A/B/C) + markdown.

usage: summarize.py <reality_out_dir>
Reads <dir>/device/reality/results.json (written by the app after EVERY flow,
so it survives a hang) or falls back to <dir>/driver_response.json. Writes
<dir>/reality_summary.json and <dir>/reality_summary.md, and appends the
markdown to $GITHUB_STEP_SUMMARY when set. Always exits 0 (evidence first).

Class rules (provisional, the audit doc has the final word):
  A  flow passed, no key needed
  B  flow passed (or skipped honestly) but a key / real device is needed
  C  flow failed: a step broke, a 404/405/5xx, an exception or a fake state
  D  flow never ran (the device/driver died first, or it was not selected) —
     no verdict either way; it is listed so a dead run can never look green

Sources, best first: the pulled results.json, the driver response, then the
`REALITY_RESULT <id> <i>/<n> <json>` lines the app prints after every flow
(reassembled from live_logcat.txt / drive.log), so a run where the device
died before the pull still keeps every verdict it reached. Screenshots are
host-side `adb screencap` PNGs in <dir>/shots/ (see run_flows.sh).
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_RES = re.compile(r"REALITY_RESULT (\S+) (\d+)/(\d+) (.*)$")


def from_logs(out):
    """Reassemble the per-flow JSON the app printed (last copy of each id wins)."""
    flows = {}
    for name in ("live_logcat.txt", "drive.log"):
        p = out / name
        if not p.exists():
            continue
        parts = {}
        for line in p.read_text(errors="replace").splitlines():
            m = _RES.search(line)
            if not m:
                continue
            fid, i, n, chunk = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4)
            if i == 1:
                parts[fid] = []
            parts.setdefault(fid, []).append(chunk)
            if i == n and len(parts[fid]) == n:
                try:
                    flows[fid] = json.loads("".join(parts[fid]))
                except ValueError:
                    pass
        if flows:
            return list(flows.values()), str(p) + " (REALITY_RESULT lines)"
    return [], None


def load(out):
    """Merge every source (flows run in groups, one app process each, so each
    results.json / driver_response holds only its own group; the logcat lines
    are cumulative). Later sources win per flow id."""
    merged, srcs = {}, []
    flows, src = from_logs(out)
    if flows:
        merged.update({f["id"]: f for f in flows})
        srcs.append(src)
    for p in (out / "driver_response.json", out / "device" / "reality" / "results.json",
              out / "device" / "results.json"):
        if not p.exists():
            continue
        try:
            d = json.loads(p.read_text()) or {}
        except ValueError:
            continue
        fl = d.get("flows") or []
        if fl:
            merged.update({f["id"]: f for f in fl})
            srcs.append(str(p))
    # rf1: a flow that was RUNNING when the drive died (run_flows.sh writes
    # device_deaths.txt: "<id>\t<emulator|app>\t<attempt>") and never
    # produced a verdict in a later attempt keeps that cause, instead of the
    # generic "never ran". emulator death = D (no verdict, never A);
    # app death with the device alive = C (the app crashed in that flow).
    deaths = {}
    dp = out / "device_deaths.txt"
    if dp.exists():
        for line in dp.read_text(errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) >= 2 and parts[0]:
                deaths.setdefault(parts[0], []).append(parts[1])
    if deaths:
        meta = {fid: (sec, feat) for fid, sec, feat in expected_flows()}
        for fid, kinds in deaths.items():
            if fid in merged:
                continue
            sec, feat = meta.get(fid, ("", ""))
            n = len(kinds)
            if "app" in kinds:
                merged[fid] = {"id": fid, "section": sec, "feature": feat, "status": "fail", "steps": [],
                               "error": "the app process died during this flow while the emulator stayed up "
                                        "(see logcat FATAL / drive.log)"}
            else:
                merged[fid] = {"id": fid, "section": sec, "feature": feat, "status": "notrun", "steps": [],
                               "error": f"emulator crashed DURING this flow ({n}x, host-side; no verdict) "
                                        "- see drive.log + host_diag.log"}
        srcs.append(str(dp))
    order = {f: i for i, f in enumerate(merged)}
    return sorted(merged.values(), key=lambda f: order[f["id"]]), (" + ".join(srcs) or None)


def expected_flows():
    """Every realityFlow id declared in app/integration_test/flows (for class D)."""
    ids = []
    rx = re.compile(r"realityFlow\(\s*'([^']+)',\s*'([^']*)',\s*'([^']*)'", re.S)
    for f in sorted((ROOT / "app" / "integration_test" / "flows").glob("*.dart")):
        for m in rx.finditer(f.read_text()):
            ids.append((m.group(1), m.group(2), m.group(3)))
    return ids


def klass(f):
    if f["status"] == "notrun":
        return "D"
    if f["status"] == "pass":
        return "B" if f.get("needs_key") else "A"
    if f["status"] == "skip":
        return "B"
    return "C"


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "reality_out")
    flows, src = load(out)
    seen = {f["id"] for f in flows}
    if not os.environ.get("REALITY_ONLY"):
        for fid, sec, feat in expected_flows():
            if fid not in seen:
                flows.append({"id": fid, "section": sec, "feature": feat, "status": "notrun",
                              "steps": [], "error": "never ran (device/driver died first)"})
    shots_dir = out / "shots"
    rows = []
    for f in flows:
        bad_step = next((s for s in f.get("steps", []) if not s.get("ok")), None)
        rows.append({
            "id": f["id"], "section": f.get("section", ""), "feature": f.get("feature", ""),
            "status": f["status"], "class": klass(f),
            "failed_step": bad_step["name"] if bad_step else "",
            "detail": (bad_step or {}).get("detail") or (f.get("error") or ""),
            "http_errors": [f"{h['m']} {h['p']} {h['s']}" for h in f.get("http_errors", [])],
            "shots": [s for st in f.get("steps", []) for s in st.get("shots", [])
                      if not shots_dir.exists() or (shots_dir / s).exists()
                      or (out / "device" / "reality" / "shots" / s).exists()],
            "needs_key": f.get("needs_key", []), "note": f.get("note", ""),
        })
    counts = {k: sum(1 for r in rows if r["class"] == k) for k in "ABCD"}
    (out / "reality_summary.json").write_text(json.dumps(
        {"source": src, "counts": counts, "rows": rows}, indent=1))
    md = [f"## Reality audit — {len(rows)} flows: A={counts['A']} B={counts['B']} C={counts['C']} D={counts['D']}",
          "", f"source: `{src}`", "",
          "| id | feature | class | failed step / detail | http errors | shots |",
          "|---|---|---|---|---|---|"]
    for r in rows:
        det = (r["failed_step"] + ": " + r["detail"]).strip(": ")[:160].replace("|", "/")
        md.append(f"| {r['id']} | {r['feature'][:60]} | **{r['class']}** | {det} | "
                  f"{', '.join(r['http_errors'])[:120]} | {len(r['shots'])} |")
    if not any(r["class"] != "D" for r in rows):
        md.append("| - | NO RESULTS (app never wrote results.json — see drive.log) | C | | | |")
    text = "\n".join(md) + "\n"
    (out / "reality_summary.md").write_text(text)
    gs = os.environ.get("GITHUB_STEP_SUMMARY")
    if gs:
        with open(gs, "a") as fh:
            fh.write(text)
    print(text)


if __name__ == "__main__":
    main()
