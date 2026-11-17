#!/usr/bin/env python3
"""Merge the per-group reality jobs (rt2 matrix) into ONE A/B/C/D table.

usage: merge_groups.py <dir>   (<dir>/<group>/ = that job's reality_out)

Every matrix job runs "start+<group>" on its own runner and emulator, so the
Start flows (01-03) appear in every job. A flow's verdict is taken ONLY from
the job that owns it (start flows from the "start" job, circle flows from the
"circle" job, ...), never the best of several copies. Flows nobody reported
are class D. Writes <dir>/reality_summary.{json,md}, appends the markdown to
$GITHUB_STEP_SUMMARY, always exits 0 (the Verdict step decides).
"""
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import summarize  # noqa: E402

FILE_GROUP = {
    "onboarding_flow": "start", "home_flow": "home", "personal_flow": "personal",
    "family_circle_flow": "family", "my_circle_add_flow": "circle", "invite_join_flow": "circle",
    "my_circle_ticks_flow": "circle", "circle_real_call_flow": "circle",
    "business_flow": "business", "docs_voice_settings_flow": "docs",
    "sweep_flow": "sweep",
    "safe_journey_flow": "family",   # journey100b: registered under the family group
    # qjourney: every flow file registered under a group whose name differs
    # from its file (results were dropped as class D "not selected")
    "family_alerts_flow": "family", "antitheft_snatch_flow": "family",
    "sos_journey_flow": "family", "journey_v2_flow": "family",
    "remmeter_flow": "personal", "budget_remittance_flow": "personal",
    "billing_flow": "personal", "crm100_flow": "business",
    "antitheft_e2e_flow": "atproof",   # antitheft-e2e (opt-in, e2e.yml)
}


OPTIN_GROUPS = {"mess"}   # keep in sync with reality.yml `optin`


def register_groups():
    """register function -> group, read from reality_all_test.dart
    (`if (on('business')) registerCrm100Flows();`). e2eproof: before this a
    flow file missing from FILE_GROUP (crm100, remmeter, qbiz, ...) was put in
    a group named after the FILE, so its results were dropped and it showed
    "D — not selected" in the verdict although it ran (run 42567594886)."""
    import re
    out = {}
    src = (summarize.ROOT / "app" / "integration_test" / "reality_all_test.dart").read_text()
    for line in src.splitlines():
        fn = re.search(r"\b(register\w+)\(\)", line)
        g = re.search(r"(?:on|contains)\('([a-z0-9_]+)'\)", line)
        if fn and g and fn.group(1) not in out:
            out[fn.group(1)] = g.group(1)
    return out


def owners():
    """flow id -> (group, section, feature), from the flow sources."""
    import re
    rx = re.compile(r"realityFlow\(\s*'([^']+)',\s*'([^']*)',\s*'([^']*)'", re.S)
    reg = register_groups()
    out = {}
    for f in sorted((summarize.ROOT / "app" / "integration_test" / "flows").glob("*.dart")):
        text = f.read_text()
        fns = re.findall(r"^void (register\w+)\(", text, re.M)
        g = FILE_GROUP.get(f.stem) or next((reg[n] for n in fns if n in reg), f.stem)
        for m in rx.finditer(text):
            out[m.group(1)] = (g, m.group(2), m.group(3))
    return out


def owner_of(fid, own):
    if fid in own:
        return own[fid][0]
    if fid.startswith("99_") or (fid[:1] == "S" and fid[1:].isdigit()):
        return "sweep"
    return None


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "groups")
    own = owners()
    picked, srcs, ran = {}, [], []
    for gdir in sorted(p for p in root.iterdir() if p.is_dir()):
        g = gdir.name
        ran.append(g)
        flows, src = summarize.load(gdir)
        if src:
            srcs.append(f"{g}: {src}")
        for f in flows:
            o = owner_of(f["id"], own)
            # gap-money: an opt-in single-feature job (reality.yml optin, e.g.
            # "mess") runs flows owned by a bigger group — keep its results
            if o is None or o == g or g in OPTIN_GROUPS:
                f.setdefault("_job", g)
                picked[f["id"]] = f
    flows = list(picked.values())
    for fid, (g, sec, feat) in own.items():
        if fid not in picked:
            why = "never ran (device/driver died first)" if g in ran else f"group {g} not selected / its job produced no evidence"
            flows.append({"id": fid, "section": sec, "feature": feat, "status": "notrun",
                          "steps": [], "error": why, "_job": g})
    flows.sort(key=lambda f: f["id"])  # 01_.. 23_, 99_sweep_boot, S001..
    rows = []
    for f in flows:
        bad = next((s for s in f.get("steps", []) if not s.get("ok")), None)
        rows.append({
            "id": f["id"], "job": f.get("_job", ""), "section": f.get("section", ""),
            "feature": f.get("feature", ""), "status": f["status"], "class": summarize.klass(f),
            "failed_step": bad["name"] if bad else "",
            "detail": (bad or {}).get("detail") or (f.get("error") or ""),
            "http_errors": [f"{h['m']} {h['p']} {h['s']}" for h in f.get("http_errors", [])],
            "shots": [s for st in f.get("steps", []) for s in st.get("shots", [])],
            "needs_key": f.get("needs_key", []), "note": f.get("note", ""),
        })
    counts = {k: sum(1 for r in rows if r["class"] == k) for k in "ABCD"}
    (root / "reality_summary.json").write_text(json.dumps(
        {"source": srcs, "jobs": ran, "counts": counts, "rows": rows}, indent=1))
    md = [f"## Reality audit (per-group jobs) — {len(rows)} flows: "
          f"A={counts['A']} B={counts['B']} C={counts['C']} D={counts['D']}",
          "", "jobs: " + ", ".join(ran), "",
          "| id | job | feature | class | failed step / detail | http errors | shots |",
          "|---|---|---|---|---|---|---|"]
    for r in rows:
        det = (r["failed_step"] + ": " + r["detail"]).strip(": ")[:160].replace("|", "/")
        md.append(f"| {r['id']} | {r['job']} | {r['feature'][:60]} | **{r['class']}** | {det} | "
                  f"{', '.join(r['http_errors'])[:120]} | {len(r['shots'])} |")
    text = "\n".join(md) + "\n"
    (root / "reality_summary.md").write_text(text)
    gs = os.environ.get("GITHUB_STEP_SUMMARY")
    if gs:
        with open(gs, "a") as fh:
            fh.write(text)
    print(text)


if __name__ == "__main__":
    main()
