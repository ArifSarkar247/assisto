#!/usr/bin/env python3
"""e2eproof: build e2e_proof.json + e2e_proof.md from one e2e.yml run.

usage: proof.py <reality_out_dir> <outbox.jsonl> <device_label>
Reads the flows' results (tools/reality/summarize.load: results.json, the
driver response, or the REALITY_RESULT log lines), the CI fakes' outbox and
writes, per proof flow: status, the quality-board rows it proves, every step
with its start offset + duration, screenshots and the server evidence count.
A flow that never ran is listed as "notrun" (never green by omission).
Exit 1 when any flow is not "pass" (skip = honest, listed, not a failure
only for flows whose module is not on this build yet: see ALLOW_SKIP).
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "reality"))
import summarize  # noqa: E402

# flow id -> quality-board rows (owner_actions/QUALITY_BOARD_BN.md "#")
BOARD = {
    "e2e1_signup_login_otp": [52, 55],
    "e2e2_ai_chat_bn": [1],
    "e2e3_circle_media": [2, 48],
    "e2e4_safe_journey_chandra": [4, 49],
    "e2e5_sos_guardian": [10, 6],
    "e2e6_reminder_fires": [13, 6],
    "e2e7_khata_expense_confirm": [8, 1],
    "e2e8_care_call": [21],
}
ALLOW_SKIP = {"e2e8_care_call"}   # skips only while Care Call is not merged


def expected():
    src = (ROOT / "app/integration_test/flows/e2e_proof_flows.dart").read_text()
    return re.findall(r"realityFlow\(\s*'(e2e\d[^']*)',\s*'[^']*',\s*'([^']*)'", src, re.S)


def main():
    out, outbox, label = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    flows, src = summarize.load(out)
    by_id = {f["id"]: f for f in flows}
    ob = []
    if outbox.exists():
        for line in outbox.read_text(encoding="utf-8").splitlines():
            try:
                ob.append(json.loads(line))
            except ValueError:
                pass
    rows, bad = [], []
    for fid, feat in expected():
        f = by_id.get(fid) or {"status": "notrun", "steps": [], "error": "never ran"}
        steps = [{"name": s.get("name"), "ok": s.get("ok"), "at_ms": s.get("at_ms"),
                  "ms": s.get("ms"), "detail": s.get("detail", ""), "shots": s.get("shots", [])}
                 for s in f.get("steps", [])]
        rows.append({"id": fid, "feature": feat, "board_rows": BOARD.get(fid, []),
                     "status": f["status"], "seconds": f.get("seconds"),
                     "note": f.get("note", ""), "error": f.get("error"),
                     "http_errors": f.get("http_errors", []), "steps": steps})
        if f["status"] != "pass" and not (f["status"] == "skip" and fid in ALLOW_SKIP):
            bad.append(fid)
    kinds = {}
    for r in ob:
        kinds[r.get("kind", "?")] = kinds.get(r.get("kind", "?"), 0) + 1
    proof = {"device": label, "run": os.environ.get("GITHUB_RUN_ID", ""),
             "run_url": "%s/%s/actions/runs/%s" % (os.environ.get("GITHUB_SERVER_URL", ""),
                                                   os.environ.get("GITHUB_REPOSITORY", ""),
                                                   os.environ.get("GITHUB_RUN_ID", "")),
             "commit": os.environ.get("GITHUB_SHA", ""), "source": src,
             "green": not bad, "not_green": bad, "server_outbox": kinds, "flows": rows}
    (out / "e2e_proof.json").write_text(json.dumps(proof, ensure_ascii=False, indent=1))
    md = ["## E2E proof — %s — %s" % (label, "GREEN" if not bad else "NOT green: " + ", ".join(bad)),
          "", "| flow | board rows | status | time | failed step |", "|---|---|---|---|---|"]
    for r in rows:
        fs = next((s for s in r["steps"] if not s["ok"]), None)
        md.append("| %s | %s | %s | %ss | %s |" % (
            r["id"], ", ".join(map(str, r["board_rows"])), r["status"],
            round(r["seconds"] or 0), (fs["name"] + ": " + (fs["detail"] or ""))[:120] if fs else ""))
    md += ["", "server outbox: `%s`" % json.dumps(kinds)]
    (out / "e2e_proof.md").write_text("\n".join(md) + "\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write("\n".join(md) + "\n")
    print("\n".join(md))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
