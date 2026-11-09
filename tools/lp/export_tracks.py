#!/usr/bin/env python3
"""Export stage-2 track content to lpcore's import bundle (LANGUAGE_PARTNER_API.md §6; FORMAT.md §10.6).

    python3 tools/lp/export_tracks.py <out_dir> [--index out/tracks_index.json]

Writes <out_dir>/bundle.json {"schema":1, "bundle":"lp-tracks-<date>", "source":"ai", "items":[...]}.
Each item carries `status` from the CI index (ai-checked only when every check passed; otherwise draft)
and `beta: true` (nothing here is human-approved yet). Audio paths point at audio/<id>.mp3 produced by
the TTS job list (tts/plan_tracks.py); audio itself never lives in git.
"""
from __future__ import annotations

import argparse
import copy
import datetime
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CONTENT = os.path.join(HERE, "content")
LEVELS = {"jlpt_n5": "N5", "jft_basic": "A2", "eps_topik": "EPS", "de_a1": "A1"}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--index")
    a = ap.parse_args(argv)
    status = {}
    if a.index:
        with open(a.index, encoding="utf-8") as f:
            for e in json.load(f).get("files", []):
                status[e["file"]] = e["status"]
    items = []
    for lang in ("ja", "ko", "de"):
        for p in sorted(glob.glob(os.path.join(CONTENT, lang, "*.json"))):
            rel = os.path.relpath(p, REPO)
            st = status.get(rel, "draft")
            with open(p, encoding="utf-8") as f:
                d = json.load(f)
            fmt = d.get("format")
            base = {"status": st, "beta": True, "version": d.get("version", 1)}
            if fmt == "assisto.lp.syllabus/1":
                items.append({"kind": "syllabus", "key": f"syl-{d['track']}", "track": d["track"],
                              "level": d["level"], "data": d, **base})
            elif fmt == "assisto.lp.lessons/1":
                tr = d["tracks"][0]
                for l in d["lessons"]:
                    data = copy.deepcopy(l)
                    data.update({"lang": lang, "week": d["week"], "tracks": d["tracks"],
                                 "practice_label": d["practice_label"]})
                    for it in data.get("practice", {}).get("listening", []):
                        it["audio"] = f"audio/{it['id']}.mp3"
                    items.append({"kind": "lesson", "key": l["id"], "track": tr, "level": LEVELS[tr],
                                  "data": data, **base})
            elif fmt == "assisto.lp.test/1":
                data = {"title_en": d["title"]["en"], "title_bn": d["title"]["bn"], "exam": d["exam"],
                        "lang": lang, "practice_label": d["practice_label"], "scoring": d["scoring"],
                        "sections": copy.deepcopy(d["sections"])}
                for s in data["sections"]:
                    for part in s.get("parts", []):
                        for q in part.get("questions", []):
                            if q.get("script"):
                                q["audio"] = f"audio/{d['bundle_id']}-q{q['n']}.mp3"
                items.append({"kind": "mock", "key": d["bundle_id"], "track": d["track"],
                              "level": LEVELS[d["track"]], "data": data, **base})
    os.makedirs(a.out, exist_ok=True)
    bundle = {"schema": 1, "bundle": f"lp-tracks-{datetime.date.today().isoformat()}", "source": "ai",
              "items": items}
    with open(os.path.join(a.out, "bundle.json"), "w", encoding="utf-8") as f:
        json.dump(bundle, f, ensure_ascii=False, indent=1)
    kinds = {}
    for it in items:
        kinds[it["kind"]] = kinds.get(it["kind"], 0) + 1
    print(f"exported {len(items)} items {kinds} -> {a.out}/bundle.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
