#!/usr/bin/env python3
"""train-e2e: the Train Tracker E2E verdict (train-e2e.yml).

usage: train_proof.py <reality_out_dir>
Every flow in app/integration_test/flows/train_proof_flow.dart must be
"pass" (a flow that never ran is "notrun", never green by omission) AND the
API proof (tools/e2e/train_e2e_driver.py -> train_e2e.json) must be ok.
Writes train_proof.json + a table to the job summary; exit 1 unless green.
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "reality"))
import summarize  # noqa: E402


def expected():
    src = (ROOT / "app/integration_test/flows/train_proof_flow.dart").read_text()
    return re.findall(r"realityFlow\('(tp\d+_[a-z0-9_]+)'", src)


def main():
    out = Path(sys.argv[1])
    flows, src = summarize.load(out)
    by_id = {f["id"]: f for f in flows}
    rows, bad = [], []
    for fid in expected():
        f = by_id.get(fid) or {"status": "notrun", "steps": [], "error": "never ran"}
        fs = next((s for s in f.get("steps", []) if not s.get("ok")), None)
        rows.append({"id": fid, "status": f["status"], "seconds": f.get("seconds"),
                     "note": f.get("note", ""), "error": f.get("error"),
                     "failed_step": (fs or {}).get("name"),
                     "steps": [{"name": s.get("name"), "ok": s.get("ok"), "ms": s.get("ms")}
                               for s in f.get("steps", [])]})
        if f["status"] != "pass":
            bad.append(fid)
    api = {}
    try:
        api = json.loads((out / "train_e2e.json").read_text())
    except (OSError, ValueError):
        api = {"ok": False, "steps": [], "metrics": {}}
    if not api.get("ok"):
        bad.append("api_proof")
    proof = {"run": os.environ.get("GITHUB_RUN_ID", ""), "commit": os.environ.get("GITHUB_SHA", ""),
             "source": src, "green": not bad, "not_green": bad, "flows": rows,
             "api_ok": bool(api.get("ok")), "metrics": api.get("metrics", {})}
    (out / "train_proof.json").write_text(json.dumps(proof, ensure_ascii=False, indent=1))
    md = ["## Train Tracker E2E (Rangpur Express 771) — %s" % (
        "GREEN" if not bad else "NOT green: " + ", ".join(bad)),
          "", "metrics: `%s`" % json.dumps(api.get("metrics", {}))[:600],
          "", "| flow | status | time | failed step | error |", "|---|---|---|---|---|"]
    for r in rows:
        md.append("| %s | %s | %ss | %s | %s |" % (
            r["id"], r["status"], round(r["seconds"] or 0), r["failed_step"] or "",
            (r["error"] or "").replace("\n", " ").replace("|", "/")[:160]))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write("\n".join(md) + "\n")
    print("\n".join(md))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
