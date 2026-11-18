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
    "e2e2c_ai_continue": [1],   # gap-aichat
    "e2e2r_ai_romanized": [1],  # aichat-nine: romanized Bangla + streamed first words
    "e2e3_circle_media": [2, 48],
    "e2e4_safe_journey_chandra": [4, 49],
    "e2e5_sos_guardian": [10, 6],
    "e2e6_reminder_fires": [13, 6],
    "e2e7_khata_expense_confirm": [8, 1],
    "e2e8_care_call": [21],
    "e2e9_offline_first": [2],   # offline1st: My Circle (+ start) with no internet
    # sjproof: Safe Journey V2 proof (e2e.yml group=start+sjproof)
    "sjp01_place_search_budget": [4], "sjp02_normal_trip": [4],
    "sjp03_route_change_extend": [4], "sjp04_tea_stop_near_destination": [4],
    "sjp05_impossible_early_arrival": [4], "sjp06_danger_pin_silent_red": [4],
    "sjp07_two_journeys": [4], "sjp08_child_unknown_place": [4],
    "sjp09_train_three_passengers": [4], "sjp10_offline_destination_alarm": [4],
}
ALLOW_SKIP = set()   # Care Call is on main since build 314: a skip is NOT green


def expected():
    files = ["app/integration_test/flows/e2e_proof_flows.dart",
             "app/integration_test/flows/offline_first_flow.dart"]   # offline1st
    if os.environ.get("REALITY_ONLY", "e2e") == "offline":
        files = files[1:]   # the offline proof run alone (e2e.yml input group=offline)
    pat = r"realityFlow\(\s*'(e2e\d[^']*)',\s*'[^']*',\s*'([^']*)'"
    if "sjproof" in os.environ.get("REALITY_ONLY", ""):
        # sjproof: the Safe Journey V2 proof run (e2e.yml input group=start+sjproof)
        files = ["app/integration_test/flows/sj_proof_flow.dart"]
        pat = r"realityFlow\(\s*'(sjp\d\d[^']*)',\s*'[^']*',\s*'([^']*)'"
    if "aichat" in os.environ.get("REALITY_ONLY", "") and "e2e" not in os.environ.get(
            "REALITY_ONLY", "").split("+"):
        # aichat-nine: the AI chat proof flows alone (e2e.yml group=start+aichat)
        pat = r"realityFlow\(\s*'(e2e2[^']*)',\s*'[^']*',\s*'([^']*)'"
        files = files[:1]
    out = []
    for f in files:
        p = ROOT / f
        if p.exists():
            out += re.findall(pat, p.read_text(), re.S)
    return out


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
        # offline1st: real phones in Test Lab have no host adb to switch airplane mode
        allow = ALLOW_SKIP | ({"e2e9_offline_first"} if label.startswith("Test Lab") else set())
        if f["status"] != "pass" and not (f["status"] == "skip" and fid in allow):
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
