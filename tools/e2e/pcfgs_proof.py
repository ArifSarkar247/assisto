#!/usr/bin/env python3
"""guardbox-play: the phone-camera + camera-FGS E2E verdict (guardbox-fgs.yml).

usage: pcfgs_proof.py <reality_out_dir>
Green only when the flow pcfgs1_phone_camera_fgs passed AND the shell's own
dumpsys agrees: while running, PhoneCamService is a FOREGROUND service with
its notification; after each Stop it is gone. Writes pcfgs_proof.json + a
table to the job summary; exit 1 otherwise.
"""
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "reality"))
import summarize  # noqa: E402

FLOW = "pcfgs1_phone_camera_fgs"


def dumps(out):
    rows = []
    for p in sorted(out.glob("pcfgs_dump*_services.txt"), key=lambda p: int("".join(c for c in p.name.split("_")[1] if c.isdigit()) or 0)):
        tag = p.name.split("_")[1]
        s = p.read_text(errors="replace")
        n = out / ("pcfgs_%s_notif.txt" % tag)
        rows.append({"tag": tag, "service": "PhoneCamService" in s,
                     "foreground": "PhoneCamService" in s and "isForeground=true" in s,
                     "notification": n.exists() and n.stat().st_size > 0})
    return rows


def main():
    out = Path(sys.argv[1])
    flows, _ = summarize.load(out)
    f = next((x for x in flows if x["id"] == FLOW), None) or {"status": "notrun", "steps": [], "error": "never ran"}
    d = dumps(out)
    bad = []
    if f["status"] != "pass":
        bad.append("flow %s" % f["status"])
    # dump order in the flow: started, screen off, stopped (notification), stopped (screen)
    want = [True, True, False, False]
    if len(d) < 4:
        bad.append("only %d dumps" % len(d))
    else:
        for i, w in enumerate(want):
            if w and not (d[i]["foreground"] and d[i]["notification"]):
                bad.append("dump %s: service not foreground / no notification" % d[i]["tag"])
            if not w and (d[i]["service"] or d[i]["notification"]):
                bad.append("dump %s: service or notification still there after Stop" % d[i]["tag"])
    proof = {"run": os.environ.get("GITHUB_RUN_ID", ""), "commit": os.environ.get("GITHUB_SHA", ""),
             "flow": {"status": f["status"], "note": f.get("note", ""), "error": f.get("error"),
                      "steps": [{"name": s.get("name"), "ok": s.get("ok"), "ms": s.get("ms")}
                                for s in f.get("steps", [])]},
             "dumps": d, "problems": bad, "green": not bad}
    (out / "pcfgs_proof.json").write_text(json.dumps(proof, indent=2, ensure_ascii=False))
    lines = ["## Phone camera + camera FGS (emulator)", "",
             "flow: **%s** %s" % (f["status"], f.get("note", "")), "", "| step | ok | ms |", "|---|---|---|"]
    lines += ["| %s | %s | %s |" % (s.get("name"), "✅" if s.get("ok") else "❌", s.get("ms")) for s in f.get("steps", [])]
    lines += ["", "| dump | service | foreground | notification |", "|---|---|---|---|"]
    lines += ["| %(tag)s | %(service)s | %(foreground)s | %(notification)s |" % r for r in d]
    lines += ["", "problems: %s" % (", ".join(bad) or "none")]
    summ = os.environ.get("GITHUB_STEP_SUMMARY")
    if summ:
        with open(summ, "a") as fh:
            fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
