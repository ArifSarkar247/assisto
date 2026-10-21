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
"""
import json
import os
import sys
from pathlib import Path


def load(out):
    for p in (out / "device" / "reality" / "results.json", out / "device" / "results.json"):
        if p.exists():
            return json.loads(p.read_text())["flows"], str(p)
    p = out / "driver_response.json"
    if p.exists():
        return (json.loads(p.read_text()) or {}).get("flows", []), str(p)
    return [], None


def klass(f):
    if f["status"] == "pass":
        return "B" if f.get("needs_key") else "A"
    if f["status"] == "skip":
        return "B"
    return "C"


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "reality_out")
    flows, src = load(out)
    rows = []
    for f in flows:
        bad_step = next((s for s in f.get("steps", []) if not s.get("ok")), None)
        rows.append({
            "id": f["id"], "section": f.get("section", ""), "feature": f.get("feature", ""),
            "status": f["status"], "class": klass(f),
            "failed_step": bad_step["name"] if bad_step else "",
            "detail": (bad_step or {}).get("detail") or (f.get("error") or ""),
            "http_errors": [f"{h['m']} {h['p']} {h['s']}" for h in f.get("http_errors", [])],
            "shots": [s for st in f.get("steps", []) for s in st.get("shots", [])],
            "needs_key": f.get("needs_key", []), "note": f.get("note", ""),
        })
    counts = {k: sum(1 for r in rows if r["class"] == k) for k in "ABC"}
    (out / "reality_summary.json").write_text(json.dumps(
        {"source": src, "counts": counts, "rows": rows}, indent=1))
    md = [f"## Reality audit — {len(rows)} flows: A={counts['A']} B={counts['B']} C={counts['C']}",
          "", f"source: `{src}`", "",
          "| id | feature | class | failed step / detail | http errors | shots |",
          "|---|---|---|---|---|---|"]
    for r in rows:
        det = (r["failed_step"] + ": " + r["detail"]).strip(": ")[:160].replace("|", "/")
        md.append(f"| {r['id']} | {r['feature'][:60]} | **{r['class']}** | {det} | "
                  f"{', '.join(r['http_errors'])[:120]} | {len(r['shots'])} |")
    if not rows:
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
