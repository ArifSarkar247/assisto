#!/usr/bin/env python3
"""Checks for Life English scenario + vocabulary files (same shape as app/assets/lp/*.json).

    python3 tools/lp/lifecheck.py      # checks tools/lp/content/life/*.json and content/vocab/*.json

Shape, counts, Bangla on every learner line, ids unique (also against the bundled app assets when present),
no duplicate sentences/words, copyright markers. Exit 1 on any error. Stdlib only.
"""
from __future__ import annotations

import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BN = re.compile(r"[ঀ-৿]")
BANNED = ["©", "copyright", "all rights reserved", "cambridge"]


def bn(s):
    return bool(BN.search(s or ""))


def load(pattern):
    out = []
    for p in sorted(glob.glob(pattern)):
        out.append((p, json.load(open(p, encoding="utf-8"))))
    return out


def check_life(files, app_ids, errs):
    ids = set(app_ids)
    sents = set()
    for p, d in files:
        name = os.path.basename(p)
        if d.get("language") != "en" or not isinstance(d.get("scenarios"), list):
            errs.append(f"{name}: needs language en + scenarios list")
            continue
        for s in d["scenarios"]:
            sid = s.get("id", "")
            w = f"{name}:{sid}"
            if not re.fullmatch(r"[a-z0-9_]+", sid) or sid in ids:
                errs.append(f"{w}: id missing/invalid/duplicate")
            ids.add(sid)
            for k in ("icon", "title_en", "role_en", "opening"):
                if not s.get(k):
                    errs.append(f"{w}: {k} missing")
            for k in ("title_bn", "role_bn"):
                if not bn(s.get(k)):
                    errs.append(f"{w}: {k} must be Bangla")
            if len(s.get("goals_en", [])) != 3 or len(s.get("goals_bn", [])) != 3 or \
                    not all(bn(g) for g in s.get("goals_bn", [])):
                errs.append(f"{w}: 3 goals_en + 3 Bangla goals_bn")
            if len(s.get("sentences", [])) < 8:
                errs.append(f"{w}: at least 8 sentences")
            for x in s.get("sentences", []):
                if not x.get("en") or not bn(x.get("bn")):
                    errs.append(f"{w}: sentence needs en + Bangla bn")
                k = x.get("en", "").lower().strip()
                if k in sents:
                    errs.append(f"{w}: duplicate sentence {k[:40]!r}")
                sents.add(k)
            if len(s.get("vocab", [])) < 8:
                errs.append(f"{w}: at least 8 vocab")
            for v in s.get("vocab", []):
                if not v.get("w") or not bn(v.get("bn")) or not v.get("ex"):
                    errs.append(f"{w}: vocab needs w, Bangla bn, ex")
            if len(s.get("drill", [])) < 5:
                errs.append(f"{w}: at least 5 drill items")
            for q in s.get("drill", []):
                if not q.get("q") or not q.get("a") or not bn(q.get("bn")):
                    errs.append(f"{w}: drill needs q, a, Bangla bn")
            low = json.dumps(s, ensure_ascii=False).lower()
            for m in BANNED:
                if m in low:
                    errs.append(f"{w}: banned marker {m!r}")
    return len(ids) - len(app_ids)


def check_vocab(files, app_topics, app_words, errs):
    tids = set(app_topics)
    words = set(app_words)
    n = 0
    for p, d in files:
        name = os.path.basename(p)
        for t in d.get("topics", []):
            tid = t.get("id", "")
            w = f"{name}:{tid}"
            if not re.fullmatch(r"(ielts|life)_[a-z0-9_]+", tid) or tid in tids:
                errs.append(f"{w}: topic id invalid/duplicate")
            tids.add(tid)
            if t.get("group") not in ("ielts", "life") or not t.get("title_en") or not bn(t.get("title_bn")):
                errs.append(f"{w}: group ielts|life, title_en, Bangla title_bn")
            if len(t.get("words", [])) < 10:
                errs.append(f"{w}: at least 10 words")
            for x in t.get("words", []):
                lw = x.get("w", "").lower().strip()
                if not lw or not bn(x.get("bn")) or not x.get("ex") or not x.get("pos") or not x.get("id"):
                    errs.append(f"{w}: word needs id, w, pos, Bangla bn, ex")
                if lw in words:
                    errs.append(f"{w}: word {lw!r} already exists")
                words.add(lw)
                if lw and lw.split()[0][:4] not in x.get("ex", "").lower():
                    print(f"WARN {w}: example for {lw!r} may not use the word")
                n += 1
    return n


def main():
    errs = []
    app_life = load(os.path.join(ROOT, "app", "assets", "lp", "life_*.json"))
    app_vocab = load(os.path.join(ROOT, "app", "assets", "lp", "vocab_*.json"))
    app_ids = [s["id"] for _, d in app_life for s in d.get("scenarios", [])]
    app_topics = [t["id"] for _, d in app_vocab for t in d.get("topics", [])]
    app_words = [w["w"].lower() for _, d in app_vocab for t in d.get("topics", []) for w in t["words"]]
    ns = check_life(load(os.path.join(HERE, "content", "life", "*.json")), app_ids, errs)
    nw = check_vocab(load(os.path.join(HERE, "content", "vocab", "*.json")), app_topics, app_words, errs)
    print(f"life scenarios: {ns} new (app assets: {len(app_ids)}); vocabulary words: {nw} new")
    for e in errs:
        print("ERROR", e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
