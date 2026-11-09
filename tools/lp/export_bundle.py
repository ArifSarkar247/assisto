#!/usr/bin/env python3
"""Export checked content bundles to lpcore's import directory (LANGUAGE_PARTNER_API.md §6).

    python3 tools/lp/export_bundle.py --index out/index.json --out out/lp_bundle \
        [--audio out/audio] [--img out/img] [--bundle-id ielts-mocks-b1]

Only bundles whose index entry has checks_passed=true are exported. Result:
  <out>/bundle.json   {"schema":1,"bundle":...,"source":"ai","items":[mock..., question...]}
  <out>/audio/*.mp3   (copied from --audio when given; listed in audio_manifest.json)
  <out>/img/*.png     (copied from --img when given)
Then on the server: manage.py lp_import <out>.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ACC = {"GB": "uk", "US": "us", "AU": "au"}


def qk(sec: str, g: dict, q: dict) -> dict:
    t = g["type"]
    d = {"n": q["n"], "type": t, "instructions": g.get("instructions", ""),
         "prompt": q.get("prompt") or g.get("prompt", ""),
         "explain_en": q.get("explain_en", ""), "explain_bn": q.get("explain_bn", ""),
         "tag": q.get("skill"), "group": g["range"]}
    if g.get("title"):
        d["group_title"] = g["title"]
    opts = q.get("options") or g.get("options")
    if opts:
        d["options"] = opts
    if g.get("word_limit"):
        d["word_limit"] = g["word_limit"]
    if t == "mcq_multi":
        d["answer"] = sorted(g["answers"])
        d["choose"] = g["choose"]
        d["prompt"] = g.get("prompt", "")
        d["marking"] = "each question in the group scores one distinct letter of the set, any order"
    elif "answer" in q and isinstance(q["answer"], str) and t in (
            "form_completion", "note_completion", "table_completion", "flow_chart_completion",
            "sentence_completion", "summary_completion", "short_answer", "diagram_label"):
        d["answer"] = [q["answer"]] + list(q.get("accept", []))
    else:
        d["answer"] = q.get("answer")
    if q.get("evidence") or g.get("evidence"):
        d["evidence"] = q.get("evidence") or g.get("evidence")
    if q.get("rationale"):
        d["rationale"] = q["rationale"]
    return d


def transcript(part: dict) -> str:
    lines = []
    for seg in part["segments"]:
        for tn in seg["turns"]:
            if "text" in tn:
                lines.append(f"{part['speakers'][tn['spk']].get('name', tn['spk'])}: {tn['text']}")
    return "\n".join(lines)


def dominant_accent(part: dict) -> str:
    cnt = {}
    for seg in part["segments"]:
        for tn in seg["turns"]:
            if "text" in tn:
                a = part["speakers"][tn["spk"]]["accent"]
                cnt[a] = cnt.get(a, 0) + len(tn["text"].split())
    return ACC[max(cnt, key=cnt.get)]


def mock_items(b: dict, audio_man: dict) -> list[dict]:
    bid = b["bundle_id"]
    track = "ielts_ac" if b["module"] == "academic" else "ielts_gt"
    items = []
    lparts = []
    for p in b["listening"]["parts"]:
        qs = [qk("listening", g, q) for g in p["groups"] for q in g["questions"]]
        groups = [{k: v for k, v in g.items() if k != "questions"} for g in p["groups"]]
        for g in groups:
            if g.get("visual"):
                g["image"] = f"img/{bid}-L{g['range'][0]}.png"
        am = audio_man.get(f"{bid}-L{p['part']}", {})
        lparts.append({"n": p["part"], "audio": f"audio/{bid}-L{p['part']}.mp3",
                       "accent": dominant_accent(p),
                       "accents": sorted({ACC[s["accent"]] for s in p["speakers"].values()}),
                       "speakers": len(p["speakers"]),
                       "speaker_list": [{"key": k, **v} for k, v in sorted(p["speakers"].items())],
                       "intro": p["intro"], "transcript": transcript(p), "groups": groups,
                       "cues": am.get("cues", []), "audio_sha256": am.get("sha256"),
                       "audio_duration_s": am.get("duration_s"), "questions": qs})
        for q in qs:
            items.append({"kind": "question", "key": f"{bid}-L{q['n']:02d}", "track": track,
                          "level": "band6", "data": {"section": "listening",
                                                     "audio": f"audio/{bid}-L{p['part']}.mp3",
                                                     "transcript": lparts[-1]["transcript"], "q": q}})
    rparts = []
    for p in b["reading"]["parts"]:
        qs = [qk("reading", g, q) for g in p["groups"] for q in g["questions"]]
        texts = p["texts"]
        body = []
        for tx in texts:
            if len(texts) > 1 and tx.get("title"):
                body.append(tx["title"].upper())
            for para in tx["paragraphs"]:
                body.append((f"{para['label']} " if para.get("label") else "") + para["text"])
        title = " / ".join(tx.get("title", "") for tx in texts)
        rparts.append({"n": p["part"], "title": title, "text": "\n\n".join(body), "texts": texts,
                       "groups": [{k: v for k, v in g.items() if k != "questions"} for g in p["groups"]],
                       "questions": qs})
        for q in qs:
            items.append({"kind": "question", "key": f"{bid}-R{q['n']:02d}", "track": track,
                          "level": "band6", "data": {"section": "reading", "passage": title,
                                                     "q": q}})
    tasks = []
    for tk in b["writing"]["tasks"]:
        d = {"n": tk["task"], "prompt": tk["prompt"], "min_words": tk["min_words"],
             "minutes": tk["minutes"], "kind": tk["kind"], "key_features": tk["key_features"],
             "model_answer": tk.get("model_answer")}
        for k in ("letter", "essay_type", "visual"):
            if tk.get(k):
                d[k] = tk[k]
        if tk.get("visual"):
            d["image"] = f"img/{bid}-W{tk['task']}.png"
        tasks.append(d)
    sp = b["speaking"]
    speaking = {"duration_sec": sp["minutes"] * 60, "parts": [
        {"n": 1, "topics": sp["part1"], "questions": [q for tp in sp["part1"] for q in tp["questions"]]},
        {"n": 2, "cue_card": sp["part2"]["cue_card"], "prep_sec": sp["part2"]["prep_s"],
         "talk_sec": sp["part2"]["talk_s"], "follow_up": sp["part2"].get("follow_up", [])},
        {"n": 3, "themes": sp["part3"], "questions": [q for th in sp["part3"] for q in th["questions"]]}]}
    mock = {"kind": "mock", "key": bid, "track": track, "level": "band6", "data": {
        "title_en": b["title"]["en"], "title_bn": b["title"]["bn"],
        "practice_label_en": b["practice_label"]["en"], "practice_label_bn": b["practice_label"]["bn"],
        "module": b["module"], "version": b["version"], "status": "ai-checked",
        "listening": {"duration_sec": b["listening"]["minutes"] * 60, "check_sec": b["listening"]["check_s"],
                      "parts": lparts},
        "reading": {"duration_sec": b["reading"]["minutes"] * 60, "passages": rparts},
        "writing": {"duration_sec": b["writing"]["minutes"] * 60, "tasks": tasks},
        "speaking": speaking}}
    return [mock] + items


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--audio")
    ap.add_argument("--img")
    ap.add_argument("--bundle-id", default="ielts-mocks")
    a = ap.parse_args(argv)
    idx = json.load(open(a.index, encoding="utf-8"))
    audio_man = {}
    if a.audio and os.path.exists(os.path.join(a.audio, "audio_manifest.json")):
        m = json.load(open(os.path.join(a.audio, "audio_manifest.json"), encoding="utf-8"))
        audio_man = {f["id"]: f for f in m["files"]}
    os.makedirs(a.out, exist_ok=True)
    items = []
    skipped = []
    for e in idx["bundles"]:
        if not e["checks_passed"]:
            skipped.append(e["bundle_id"])
            continue
        b = json.load(open(os.path.join(ROOT, e["file"]), encoding="utf-8"))
        items += mock_items(b, audio_man)
    for lp in sorted(glob.glob(os.path.join(HERE, "content", "life", "*.json"))):
        for sc in json.load(open(lp, encoding="utf-8")).get("scenarios", []):
            items.append({"kind": "scenario", "key": f"life-{sc['id']}", "track": "life",
                          "level": "A2", "data": sc})
    for vp in sorted(glob.glob(os.path.join(HERE, "content", "vocab", "*.json"))):
        for tp in json.load(open(vp, encoding="utf-8")).get("topics", []):
            items.append({"kind": "vocab", "key": f"vocab-{tp['id']}", "track": "vocab",
                          "level": "B1" if tp.get("group") == "ielts" else "A2", "data": tp})
    bundle = {"schema": 1, "bundle": a.bundle_id, "source": "ai",
              "source_note": "Original items authored by Claude for Assisto (no paid API in CI); "
                             "status ai-checked by tools/lp/lpcheck.py; human review pending in Owner Admin.",
              "items": items}
    json.dump(bundle, open(os.path.join(a.out, "bundle.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    missing = []
    for sub, src in (("audio", a.audio), ("img", a.img)):
        if src and os.path.isdir(src):
            os.makedirs(os.path.join(a.out, sub), exist_ok=True)
            for fn in os.listdir(src):
                if fn.endswith((".mp3", ".png", ".json")):
                    shutil.copy2(os.path.join(src, fn), os.path.join(a.out, sub, fn))
    if a.audio:
        for it in items:
            if it["kind"] == "mock":
                for p in it["data"]["listening"]["parts"]:
                    if not os.path.exists(os.path.join(a.out, p["audio"])):
                        missing.append(p["audio"])
    n_m = sum(1 for i in items if i["kind"] == "mock")
    kinds = {}
    for it in items:
        kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
    print(f"exported {kinds}; skipped (failed checks): {skipped}")
    if missing:
        print("missing audio:", missing, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
