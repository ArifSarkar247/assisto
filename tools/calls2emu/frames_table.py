"""calls-2emu: per-case video/audio table from the control channel's
samples.jsonl (one line per proof: A out -> B in, B out -> A in, audio).
Appends it to the job summary. Evidence only; the verdict is verdict.py.

usage: frames_table.py <reality_out/calls2emu>
"""
import json
import os
import sys
from pathlib import Path


def main():
    d = Path(sys.argv[1])
    rows = []
    p = d / "samples.jsonl"
    if p.exists():
        for ln in p.read_text().splitlines():
            try:
                rows.append(json.loads(ln))
            except ValueError:
                pass

    def cell(ok, need):
        if ok:
            return "flowing"
        return "**NOT flowing**" if need else "off (expected)"

    out = ["### Two-emulator calls: video both ways per case", "",
           "| case | A -> B video | B -> A video | audio both ways | numbers (A out enc -> B in dec; B out enc -> A in dec) |",
           "|---|---|---|---|---|"]
    for r in rows:
        out.append("| %s | %s | %s | %s | %s |" % (
            r.get("case"), cell(r.get("a_to_b"), r.get("need_a_to_b", True)),
            cell(r.get("b_to_a"), r.get("need_b_to_a", True)),
            "yes" if r.get("audio") else "**NO**", str(r.get("line", "")).replace("|", "/")[:220]))
    if not rows:
        out.append("| - | no samples (no case reached the media proof) | | | |")
    ev = sorted(x.name for x in (d / "evidence").glob("*.json")) if (d / "evidence").is_dir() else []
    vids = sorted(x.name for x in (d / "videos").glob("*.mp4")) if (d / "videos").is_dir() else []
    out += ["", "evidence files: %d (SDP + transceivers + rtp, per case/side/3 s/10 s); screen recordings: %d"
            % (len(ev), len(vids)), ""]
    text = "\n".join(out) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(text)


if __name__ == "__main__":
    main()
