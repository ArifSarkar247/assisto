#!/usr/bin/env python3
"""Turn stage-2/3 listening scripts (FORMAT.md §10.2) into a TTS job list. No synthesis here.

    python3 tools/lp/tts/plan_tracks.py <out_dir>   # writes <out_dir>/tts_jobs_tracks.json

One job per listening question (tests) or listening practice item (lessons):
{id, lang, audio: "audio/<id>.mp3", plays, segments: [{voice, text, rate} | {silence_s}], blocked?}
Voices come from VOICES_TRACKS.json (cleared voices only); speakers get voices by gender, alternating
so two speakers of the same gender sound different. A job whose language has no cleared voice is
marked blocked (never synthesised with an uncleared voice).
"""
from __future__ import annotations

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT = os.path.join(HERE, "..", "content")


def load_voices():
    with open(os.path.join(HERE, "VOICES_TRACKS.json"), encoding="utf-8") as f:
        v = json.load(f)
    out = {}
    for lang, lst in v["voices"].items():
        ok = [x for x in lst if x.get("cleared") and not x.get("fallback")]
        out[lang] = {"F": [x["id"] for x in ok if x["gender"] == "F"],
                     "M": [x["id"] for x in ok if x["gender"] == "M"]}
    return out, v.get("speech_rate", {})


def assign(lang, speakers, voices):
    used = {"F": 0, "M": 0}
    res = {}
    pool = voices.get(lang, {"F": [], "M": []})
    for sid, s in sorted(speakers.items()):
        g = s.get("gender", "F")
        cands = pool.get(g) or pool.get("F" if g == "M" else "M") or []
        res[sid] = cands[used[g] % len(cands)] if cands else None
        used[g] += 1
    return res


def job(jid, lang, script, voices, rates):
    vmap = assign(lang, script.get("speakers", {}), voices)
    segs = []
    for t in script.get("turns", []):
        if "pause" in t:
            segs.append({"silence_s": float(t["pause"])})
        else:
            segs.append({"voice": vmap.get(t.get("spk")), "text": t.get("text", ""), "rate": rates.get(lang, 1.0)})
    j = {"id": jid, "lang": lang, "audio": f"audio/{jid}.mp3", "plays": script.get("repeat", 1),
         "gap_between_plays_s": 3, "segments": segs}
    if any(s.get("voice") is None for s in segs if "text" in s):
        j["blocked"] = "no licence-cleared voice for this language yet"
    return j


def main(argv):
    out = argv[0] if argv else "out/tts"
    voices, rates = load_voices()
    jobs = []
    for lang in ("ja", "ko", "de", "zh", "fr", "ar"):
        for p in sorted(glob.glob(os.path.join(CONTENT, lang, "*.json"))):
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
            if d.get("format") == "assisto.lp.test/1":
                for s in d.get("sections", []):
                    for part in s.get("parts", []):
                        for q in part.get("questions", []):
                            if q.get("script"):
                                jobs.append(job(f"{d['bundle_id']}-q{q['n']}", lang, q["script"], voices, rates))
            elif d.get("format") == "assisto.lp.lessons/1":
                for l in d.get("lessons", []):
                    for it in (l.get("practice") or {}).get("listening", []):
                        if it.get("script"):
                            jobs.append(job(it["id"], lang, it["script"], voices, rates))
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "tts_jobs_tracks.json"), "w", encoding="utf-8") as f:
        json.dump({"format": "assisto.lp.tts_jobs/1", "jobs": jobs}, f, ensure_ascii=False, indent=1)
    blocked = sum(1 for j in jobs if j.get("blocked"))
    print(f"{len(jobs)} TTS jobs ({blocked} blocked: no cleared voice) -> {out}/tts_jobs_tracks.json")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
