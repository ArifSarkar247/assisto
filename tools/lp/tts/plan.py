#!/usr/bin/env python3
"""Turn Listening parts of content bundles into a render plan (stdlib only).

    python3 tools/lp/tts/plan.py --out work/plan.json [bundle.json ...]   (default: all bundles)

The plan lists, per output file (one per Listening part), an ordered list of items:
  {"kind": "speech", "clip": <sha1>, "role": "narrator"|<spk>, "text": ...}
  {"kind": "silence", "s": 30, "why": "preview"}
  {"kind": "cue", "questions": [7, 10]}       (zero-length marker -> start time in the manifest)
and a "clips" table {sha1: {engine, voice, lang, text, gender, fallback?}} that the synth step renders
(deduplicated, cacheable by sha1). Narrator lines follow the real exam's pattern and are generated here,
never authored.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
LP = os.path.dirname(HERE)
VOICES = json.load(open(os.path.join(HERE, "voices.json"), encoding="utf-8"))
ORD = {1: "first", 2: "second", 3: "third", 4: "fourth"}
KIND_WORD = {"everyday_dialogue": "conversation", "everyday_monologue": "talk",
             "academic_discussion": "discussion", "academic_lecture": "lecture"}


def clip_id(v: dict, text: str) -> str:
    return hashlib.sha1(f"{v['engine']}|{v['voice']}|{text}".encode()).hexdigest()[:16]


def assign_voices(bid: str, part: dict) -> dict:
    """Deterministic, distinct voices per part; narrator voice never used for a character."""
    used = {VOICES["narrator"]["voice"]}
    out = {}
    for key in sorted(part["speakers"]):
        s = part["speakers"][key]
        pool = VOICES["pools"][f"{s['accent']}/{s['gender']}"]
        h = int(hashlib.sha1(f"{bid}|{part['part']}|{key}".encode()).hexdigest(), 16)
        cand = [pool[(h + i) % len(pool)] for i in range(len(pool))]
        pick = next((v for v in cand if v["voice"] not in used or v["engine"] == "melo"), cand[0])
        used.add(pick["voice"])
        out[key] = dict(pick)
        if s.get("voice"):
            out[key]["voice"] = s["voice"]
    return out


def say_range(q):
    return f"questions {q[0]} to {q[1]}" if q[0] != q[1] else f"question {q[0]}"


def part_plan(b: dict, part: dict, clips: dict, total_parts: int, check_s: int) -> dict:
    bid = b["bundle_id"]
    pn = part["part"]
    narr = VOICES["narrator"]
    voices = assign_voices(bid, part)
    gaps = VOICES["gaps_s"]
    items = []

    def speech(role, v, text, gender=None):
        text = re.sub(r"\s+", " ", text).strip()
        cid = clip_id(v, text)
        c = {"engine": v["engine"], "voice": v["voice"], "lang": v["lang"], "text": text,
             "gender": gender}
        if v["engine"] == "melo":
            fb = VOICES["au_fallback"][gender or "F"]
            c["fallback"] = {**fb, "clip": clip_id(fb, text)}
            clips[c["fallback"]["clip"]] = {"engine": fb["engine"], "voice": fb["voice"],
                                            "lang": fb["lang"], "text": text, "gender": gender}
        clips[cid] = c
        items.append({"kind": "speech", "clip": cid, "role": role})

    def silence(s, why):
        items.append({"kind": "silence", "s": round(float(s), 2), "why": why})

    word = KIND_WORD.get(part["context"], "recording")
    segs = part["segments"]
    if pn == 1:
        speech("narrator", narr, f"Assisto practice test. {b['title']['en']}. Listening.")
        silence(1.0, "narrator")
    speech("narrator", narr, f"Part {pn}. {part['intro']}")
    silence(gaps["after_narrator"], "narrator")
    for i, seg in enumerate(segs):
        q = seg["questions"]
        if i == 0:
            first = "First, you" if len(segs) > 1 else "You"
            speech("narrator", narr, f"{first} have some time to look at {say_range(q)}.")
        else:
            speech("narrator", narr, f"Before you hear the rest of the {word}, you have some time "
                                     f"to look at {say_range(q)}.")
        silence(seg["preview_s"], "preview")
        speech("narrator", narr, f"Now listen carefully and answer {say_range(q)}.")
        silence(gaps["before_narrator"], "narrator")
        items.append({"kind": "cue", "questions": q})
        prev = None
        for t in seg["turns"]:
            if "pause" in t:
                silence(t["pause"], "pause")
                prev = None
                continue
            if prev is not None:
                silence(gaps["speaker_change"] if t["spk"] != prev else gaps["same_speaker"], "turn")
            sp = part["speakers"][t["spk"]]
            speech(t["spk"], voices[t["spk"]], t["text"], sp["gender"])
            prev = t["spk"]
        silence(gaps["before_narrator"], "narrator")
    if pn < total_parts:
        speech("narrator", narr, f"That is the end of Part {pn}. You now have {check_s} seconds "
                                 f"to check your answers.")
    else:
        speech("narrator", narr, f"That is the end of Part {pn}, and the end of the listening test. "
                                 f"You now have {check_s} seconds to check your answers.")
    silence(check_s, "check")
    return {"id": f"{bid}-L{pn}", "file": f"{bid}-L{pn}.mp3", "bundle": bid, "part": pn,
            "speakers": {k: {**part["speakers"][k], "engine": voices[k]["engine"],
                             "voice": voices[k]["voice"]} for k in part["speakers"]},
            "items": items}


def build(paths: list[str]) -> dict:
    clips: dict = {}
    files = []
    for p in sorted(paths):
        b = json.load(open(p, encoding="utf-8"))
        lis = b.get("listening")
        if not isinstance(lis, dict):
            continue
        parts = lis.get("parts", [])
        for part in parts:
            files.append(part_plan(b, part, clips, len(parts), lis.get("check_s", 30)))
    return {"format": "assisto.lp.ttsplan/1", "files": files, "clips": clips}


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("bundles", nargs="*")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    paths = a.bundles or sorted(glob.glob(os.path.join(LP, "content", "*", "ielts-*-[0-9][0-9][0-9].json")))
    plan = build(paths)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    json.dump(plan, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    eng = {}
    for c in plan["clips"].values():
        eng[c["engine"]] = eng.get(c["engine"], 0) + 1
    print(f"{len(plan['files'])} files, {len(plan['clips'])} clips {eng}")


if __name__ == "__main__":
    main()
