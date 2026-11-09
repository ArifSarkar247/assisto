#!/usr/bin/env python3
"""playvideos: cut the raw screen recording into one <=30 s Play video.

usage: compose.py <out_dir> <vid a|b> <lang>
Reads <out>/<vid>/chunks.txt ("<file> <start_s>" per screenrecord chunk,
seconds since the recording started) and <out>/<vid>/events.txt
("<name> <t_s>"), writes:
  <out>/final/play_<name>_<lang>.mp4   the <=30 s declaration video
  <out>/final/raw_<name>_<lang>.mp4    the whole recording (reference)
  <out>/frames/<vid>_<lang>_<event>.png one frame per timeline mark (review)
"""
import json
import os
import subprocess
import sys

NAMES = {"a": "location_fgs", "b": "hey_assisto_mic"}
# (event, seconds before, seconds after, optional end event that caps "after")
SPEC = {
    "b": [("settings", 0, 3.5, None), ("disclosure", 0, 9.0, "agree"),
          ("perm_mic_seen", 0.3, 6.0, "perm_mic_tapped"), ("perm_notif_seen", 0.3, 6.0, "perm_notif_tapped"),
          ("listening", 0, 3.0, None), ("shade_b", 0, 6.0, None)],
    "a": [("form", 0, 3.0, None), ("disclosure", 0.3, 6.0, None),
          ("perm_loc_seen", 0.3, 6.0, "perm_loc_tapped"), ("live", 0, 3.5, None),
          ("home_a", 0.2, 1.5, None), ("shade_a", 0, 6.5, None), ("reopen", 0, 3.0, None)],
}
CAP = 30.0


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print("ffmpeg failed:", " ".join(cmd)[:300], r.stderr[-800:])
    return r.returncode == 0


def duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                        "-of", "csv=p=0", path], capture_output=True, text=True)
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def main():
    out, vid, lang = sys.argv[1], sys.argv[2], sys.argv[3]
    d = os.path.join(out, vid)
    chunks = []
    for line in open(os.path.join(d, "chunks.txt")):
        p = line.split()
        f = os.path.join(d, p[0])
        if len(p) == 2 and os.path.exists(f) and os.path.getsize(f) > 0:
            chunks.append((f, float(p[1]), duration(f)))
    ev = {}
    for line in open(os.path.join(d, "events.txt")):
        p = line.split()
        if len(p) == 2:
            ev.setdefault(p[0], float(p[1]))  # first occurrence wins
    os.makedirs(os.path.join(out, "final"), exist_ok=True)
    os.makedirs(os.path.join(out, "frames"), exist_ok=True)
    name = NAMES[vid]
    report = {"vid": vid, "lang": lang, "events": ev, "chunks": [(os.path.basename(c[0]), c[1], c[2]) for c in chunks],
              "missing": [], "segments": []}
    if not chunks:
        report["error"] = "no recording"
        print(json.dumps(report))
        return 1

    def locate(t):  # global t -> (chunk file, local t, chunk dur)
        best = chunks[0]
        for c in chunks:
            if c[1] <= t:
                best = c
        return best[0], max(0.0, t - best[1]), best[2]

    # raw = every chunk back to back
    lst = os.path.join(d, "concat.txt")
    with open(lst, "w") as f:
        for c in chunks:
            f.write("file '%s'\n" % c[0])
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", lst,
         "-vf", "scale=720:-2,fps=30", "-c:v", "libx264", "-preset", "veryfast", "-crf", "26",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart",
         os.path.join(out, "final", "raw_%s_%s.mp4" % (name, lang))])

    segs = []
    for evn, pre, post, until in SPEC[vid]:
        if evn not in ev:
            report["missing"].append(evn)
            continue
        s, e = ev[evn] - pre, ev[evn] + post
        if until and until in ev and ev[until] > ev[evn]:
            e = min(e, ev[until] + 0.6)
        f, ls, cd = locate(s)
        le = min(ls + (e - s), cd if cd > 0 else ls + (e - s))
        if le - ls < 0.4:
            report["missing"].append(evn + "(empty)")
            continue
        if segs and segs[-1][0] == f and ls <= segs[-1][2] + 0.05:  # overlap -> merge
            segs[-1] = (f, segs[-1][1], max(segs[-1][2], le), segs[-1][3] + "+" + evn)
        else:
            segs.append((f, ls, le, evn))
    total, kept = 0.0, []
    for f, a, b, evn in segs:
        if total >= CAP - 0.3:
            break
        b = min(b, a + (CAP - total))
        kept.append((f, a, b, evn))
        total += b - a
    report["segments"] = [(os.path.basename(f), round(a, 2), round(b, 2), e) for f, a, b, e in kept]
    report["total_s"] = round(total, 2)
    if kept:
        cmd = ["ffmpeg", "-y", "-loglevel", "error"]
        for f, a, b, _ in kept:
            cmd += ["-ss", "%.2f" % a, "-t", "%.2f" % (b - a), "-i", f]
        fc = "".join("[%d:v]fps=30,scale=720:-2,setsar=1,setpts=PTS-STARTPTS[v%d];" % (i, i)
                     for i in range(len(kept)))
        fc += "".join("[v%d]" % i for i in range(len(kept))) + "concat=n=%d:v=1:a=0[o]" % len(kept)
        cmd += ["-filter_complex", fc, "-map", "[o]", "-c:v", "libx264", "-preset", "veryfast",
                "-crf", "23", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                os.path.join(out, "final", "play_%s_%s.mp4" % (name, lang))]
        report["final_ok"] = run(cmd)
    # review frames: one per mark, ~1 s after it
    for evn, t in ev.items():
        f, lt, cd = locate(t + 1.0)
        if cd and lt > cd:
            lt = max(0.0, cd - 0.2)
        run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "%.2f" % lt, "-i", f, "-frames:v", "1",
             "-vf", "scale=540:-2", os.path.join(out, "frames", "%s_%s_%s.png" % (vid, lang, evn))])
    with open(os.path.join(out, "final", "report_%s_%s.json" % (name, lang)), "w") as fh:
        json.dump(report, fh, indent=1)
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
