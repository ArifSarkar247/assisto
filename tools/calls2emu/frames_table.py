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
    # calls-quality: measured windows (rows with per-side "a"/"b" dicts) get their own table
    qrows = [r for r in rows if isinstance(r.get("a"), dict)]
    rows = [r for r in rows if not isinstance(r.get("a"), dict)]
    for r in rows:
        out.append("| %s | %s | %s | %s | %s |" % (
            r.get("case"), cell(r.get("a_to_b"), r.get("need_a_to_b", True)),
            cell(r.get("b_to_a"), r.get("need_b_to_a", True)),
            "yes" if r.get("audio") else "**NO**", str(r.get("line", "")).replace("|", "/")[:220]))
    if not rows:
        out.append("| - | no samples (no case reached the media proof) | | | |")
    if qrows:
        out += ["", "### Call quality windows (calls-quality)", "",
                "| window | A video frames / max gap ms | B video frames / max gap ms | A audio pk / gap | B audio pk / gap | RTT ms | path |",
                "|---|---|---|---|---|---|---|"]
        for r in qrows:
            a, b = r["a"], r.get("b") or {}
            out.append("| %s | %s / %s | %s / %s | %s / %s | %s / %s | %s | %s->%s |" % (
                r.get("case"), a.get("video_frames"), a.get("video_max_gap_ms"),
                b.get("video_frames"), b.get("video_max_gap_ms"), a.get("audio_packets"),
                a.get("audio_max_gap_ms"), b.get("audio_packets"), b.get("audio_max_gap_ms"),
                a.get("rtt_median_ms"), (a.get("local") or {}).get("type"), (a.get("remote") or {}).get("type")))
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
