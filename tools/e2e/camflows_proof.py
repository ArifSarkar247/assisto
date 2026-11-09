#!/usr/bin/env python3
"""camflows: the CCTV brand-cloud E2E verdict (camflows.yml).

usage: camflows_proof.py <reality_out_dir>
Every brand flow in app/integration_test/flows/camflows_flow.dart must be
"pass" (a flow that never ran is "notrun", never green by omission). Writes
camflows_proof.json + a table to the job summary; exit 1 unless all passed.
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
    src = (ROOT / "app/integration_test/flows/camflows_flow.dart").read_text()
    return re.findall(r"_Brand\('(cf\d_[a-z_]+)'", src)


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
    proof = {"run": os.environ.get("GITHUB_RUN_ID", ""), "commit": os.environ.get("GITHUB_SHA", ""),
             "source": src, "green": not bad, "not_green": bad, "flows": rows}
    (out / "camflows_proof.json").write_text(json.dumps(proof, ensure_ascii=False, indent=1))
    md = ["## CCTV brand clouds E2E — %s" % ("GREEN" if not bad else "NOT green: " + ", ".join(bad)),
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
