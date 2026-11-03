"""langkoja — phone-voice LISTENING practice for language packs (Korean, Japanese).

The Language Partner framework (logic/langpacks.py) only allows a listening
section with LICENSED audio (`audio_url`). We have no licensed recordings for
EPS-TOPIK / JFT-style listening, so this module serves a separate, honestly
labelled practice set: each question carries a short line (`say`) that the
phone reads with its own text-to-speech voice in the course language. It is
NEVER mixed into a mock test score and never presented as exam audio.

Data: backend/core/data/langpacks_listening/<code>.json
  {"format": 1, "lang": "ko", "tts_locale": "ko-KR", "label_en", "label_bn",
   "questions": [{id, type:"mcq", skill:"listening", say, text, options, answer,
                  explain_bn, explain_en}]}

PURE except for reading the files: no Django, no DB, no network.
"""
import json
import os
import re

DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "data", "langpacks_listening")
FORMAT = 1
_LOCALE = re.compile(r"^[a-z]{2}-[A-Z]{2}$")
_BANNED = re.compile(r"official (past )?paper|©|copyright|all rights reserved", re.I)
MAX_SAY = 300


class ListenError(ValueError):
    pass


def _need(cond, msg):
    if not cond:
        raise ListenError(msg)


def validate(d):
    _need(isinstance(d, dict) and d.get("format") == FORMAT, "format must be 1")
    _need(isinstance(d.get("lang"), str) and len(d["lang"]) == 2, "lang")
    _need(_LOCALE.match(str(d.get("tts_locale") or "")), "tts_locale like ko-KR")
    _need(d.get("label_en") and d.get("label_bn"), "label_en + label_bn")
    qs = d.get("questions") or []
    _need(len(qs) >= 5, "need >= 5 questions")
    seen = set()
    for q in qs:
        _need(isinstance(q, dict) and q.get("id") and q["id"] not in seen, "unique id")
        seen.add(q["id"])
        _need(q.get("type") == "mcq" and q.get("skill") == "listening", f"{q['id']}: mcq/listening")
        _need(isinstance(q.get("say"), str) and 0 < len(q["say"]) <= MAX_SAY, f"{q['id']}: say")
        _need(q.get("text"), f"{q['id']}: text")
        opts = q.get("options")
        _need(isinstance(opts, list) and len(opts) >= 2 and len(set(opts)) == len(opts),
              f"{q['id']}: options")
        _need(isinstance(q.get("answer"), int) and 0 <= q["answer"] < len(opts), f"{q['id']}: answer")
        _need(q.get("explain_bn") and q.get("explain_en"), f"{q['id']}: explanations")
    _need(not _BANNED.search(json.dumps(d, ensure_ascii=False)), "looks copied")
    return d


_CACHE = {}


def load(code):
    """The validated listening set for `code`, or None."""
    if not isinstance(code, str) or not re.fullmatch(r"[a-z]{2}", code):
        return None
    path = os.path.join(DIR, f"{code}.json")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return None
    hit = _CACHE.get(code)
    if hit and hit[0] == mtime:
        return hit[1]
    try:
        with open(path, encoding="utf-8") as f:
            d = validate(json.load(f))
        if d["lang"] != code:
            d = None
    except (OSError, ValueError):
        d = None
    _CACHE[code] = (mtime, d)
    return d


def public(d):
    """Questions without answer keys / explanations (graded on the server)."""
    hide = ("answer", "explain_bn", "explain_en")
    return {"lang": d["lang"], "tts_locale": d["tts_locale"],
            "label_en": d["label_en"], "label_bn": d["label_bn"],
            "questions": [{k: v for k, v in q.items() if k not in hide} for q in d["questions"]]}


def grade(d, answers):
    rows = []
    for q in d["questions"]:
        given = (answers or {}).get(q["id"])
        try:
            given = int(given)
        except (TypeError, ValueError):
            given = None
        rows.append({"id": q["id"], "given": given, "answer": q["answer"],
                     "correct": given == q["answer"],
                     "explain_bn": q["explain_bn"], "explain_en": q["explain_en"]})
    answered = [r for r in rows if r["given"] is not None]
    correct = sum(r["correct"] for r in rows)
    return {"correct": correct, "total": len(rows), "answered": len(answered),
            "score_pct": round(100 * correct / len(rows)) if rows else 0,
            "rows": rows, "estimate": True}
