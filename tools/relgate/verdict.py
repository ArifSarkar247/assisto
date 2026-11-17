"""relgate: one flow leg's verdict. Every REQUIRED flow id must have passed
(class A in reality_summary.json, written by tools/reality/summarize.py).
B (skipped / needs a key), C (failed), D (never ran) and a missing id = FAIL.

usage: verdict.py <reality_out> <leg> <id,id,...>
"""
import json
import os
import sys
from pathlib import Path


def main():
    out, leg, ids = Path(sys.argv[1]), sys.argv[2], [i for i in sys.argv[3].split(",") if i]
    try:
        rows = {r["id"]: r for r in json.loads((out / "reality_summary.json").read_text())["rows"]}
    except Exception as e:  # no summary = the app never wrote results
        rows = {}
        print("no reality_summary.json: %r" % e)
    lines = ["### Release gate leg `%s`" % leg, "", "| flow | result | detail |", "|---|---|---|"]
    bad = 0
    for fid in ids:
        r = rows.get(fid)
        if r is None:
            cls, det = "MISSING", "no result (flow never ran or was not registered)"
        else:
            cls = r["class"]
            det = (r.get("failed_step") + ": " if r.get("failed_step") else "") + (r.get("detail") or r.get("note") or "")
        ok = cls == "A"
        bad += not ok
        lines.append("| %s | %s | %s |" % (fid, "PASS" if ok else "**FAIL (%s)**" % cls,
                                         det.replace("|", "/").replace("\n", " ")[:180]))
        if not ok:
            print("::error::%s: %s %s %s" % (leg, fid, cls, det[:300]))
    # gatefix (owner 17 Nov): two-phone items the owner checks on the closed-
    # testing build before production. Printed, never part of the verdict.
    checks = [(fid, c) for fid in ids for c in (rows.get(fid) or {}).get("owner_checks") or []]
    if checks:
        lines += ["", "Owner two-phone checklist (not provable on one CI emulator):"]
        lines += ["- `%s`: %s" % (fid, c) for fid, c in checks]
    verdict = "PASS" if not bad and ids else "FAIL"
    lines += ["", "**%s: %s** (%d/%d required flows passed)" % (leg, verdict, len(ids) - bad, len(ids)), ""]
    text = "\n".join(lines) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(text)
    (out / "gate_leg.json").write_text(json.dumps({"leg": leg, "verdict": verdict, "failed": bad, "required": ids,
                                                  "owner_checks": [{"flow": f, "check": c} for f, c in checks]}))
    sys.exit(0 if verdict == "PASS" else 1)


if __name__ == "__main__":
    main()
