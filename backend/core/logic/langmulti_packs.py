"""
langmulti_packs.py — content packs for Language Partner languages 4-8
(Arabic for Gulf work, German, French, Spanish, Chinese; owner order 3 Nov).

PURE: no Django, no DB, no network, no AI. Packs are JSON files under
core/data/language_packs/<code>.json (provisional format
"assisto-langpack/0-provisional" until agent/p2lang's LANGUAGE_PACK_FORMAT
lands — then the packs are converted, this module stays as the validator).

CONTENT POLICY: every question, sentence and dialogue was written for
Assisto. Only the public FORMAT of Goethe-Zertifikat / DELF-DALF / DELE / HSK
(sections, timings, task types) is followed — no logos, no real papers.
Every score is an estimate: `estimate_label` is shown with each result.

Functions:
  load(code) / codes()        read packs
  validate(pack) -> [errors]  structural + honesty checks (used by tests)
  normalize(text, pack)       per-language text folding for answer/speech match
  tokens(text, pack)          word tokens, or characters for Chinese
  align(target, heard, pack)  word/char alignment for the pronunciation check
  check_list(task, text, pack) key-free writing/speaking checklist
  estimate(pack, results)     ladder level estimate + weak skills
"""
import json
import os
import re
import unicodedata

PACK_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "language_packs")
ORDER = ("ar", "de", "fr", "es", "zh")
PLACES = ("airport", "workplace", "doctor", "renting", "shopping")
SKILLS = ("listening", "reading", "writing", "speaking")
_BN = re.compile(r"[ঀ-৿]")
_LEVEL_TAG = re.compile(r"\b(?:[ABC][12]|HSK ?[1-6]|W[1-3])\b")


def codes():
    return [c for c in ORDER if os.path.exists(os.path.join(PACK_DIR, c + ".json"))]


def load(code):
    if code not in ORDER:
        return None
    path = os.path.join(PACK_DIR, code + ".json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ------------------------------------------------------------- normalise
_HARAKAT = re.compile(r"[ً-ٰٟـ]")
_AR_DIGITS = str.maketrans("٠١٢٣٤٥٦٧٨٩", "0123456789")
_ZH_PUNCT = re.compile(r"[，。！？、；：“”‘’（）《》\s]")


def normalize(text, pack):
    t = unicodedata.normalize("NFC", str(text or "")).lower()
    rules = (pack.get("match") or {}).get("normalize", [])
    if "strip_harakat" in rules:
        t = _HARAKAT.sub("", t)
    if "unify_alef" in rules:
        t = re.sub("[إأآٱ]", "ا", t)
    if "unify_taa_marbuta" in rules:
        t = t.replace("ة", "ه").replace("ى", "ي")
    if "arabic_digits" in rules:
        t = t.translate(_AR_DIGITS)
    if "strip_accents" in rules:
        t = "".join(c for c in unicodedata.normalize("NFD", t)
                    if unicodedata.category(c) != "Mn")
        t = t.replace("ß", "ss")
    return t


def tokens(text, pack):
    t = normalize(text, pack)
    if (pack.get("match") or {}).get("tokenize") == "chars":
        return [c for c in _ZH_PUNCT.sub("", t) if not c.isspace() and c.isalnum()]
    return re.findall(r"[^\W_]+(?:'[^\W_]+)?", t)


def align(target, heard, pack):
    """Same Levenshtein-with-backtrace as ielts.align_words, but on the pack's
    tokens (words, or characters for Chinese). Returns (rows, score 0..100)."""
    t, h = tokens(target, pack), tokens(heard, pack)
    n, m = len(t), len(h)
    if n == 0:
        return [], 0
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        d[i][0] = i
    for j in range(m + 1):
        d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            cost = 0 if t[i - 1] == h[j - 1] else 1
            d[i][j] = min(d[i - 1][j - 1] + cost, d[i - 1][j] + 1, d[i][j - 1] + 1)
    rows, i, j = [], n, m
    while i > 0:
        if j > 0 and t[i - 1] == h[j - 1] and d[i][j] == d[i - 1][j - 1]:
            rows.append({"word": t[i - 1], "status": "ok", "heard": h[j - 1]})
            i, j = i - 1, j - 1
        elif j > 0 and d[i][j] == d[i][j - 1] + 1:
            j -= 1
        elif d[i][j] == d[i - 1][j] + 1:
            rows.append({"word": t[i - 1], "status": "miss", "heard": ""})
            i -= 1
        else:
            rows.append({"word": t[i - 1], "status": "sub", "heard": h[j - 1]})
            i, j = i - 1, j - 1
    rows.reverse()
    ok = sum(1 for r in rows if r["status"] == "ok")
    return rows, round(100 * ok / n)


# ------------------------------------------------------------- checklists
def check_list(task, text, pack):
    """Key-free checklist for a write/speak task: length + required elements."""
    toks = tokens(text, pack)
    norm = normalize(text, pack)
    chars = (pack.get("match") or {}).get("tokenize") == "chars"
    n = len(toks)
    items = [{"id": "length", "ok": n >= task.get("min_words", 0), "value": n,
              "en": f"Length: {n} (aim for at least {task.get('min_words', 0)}"
                    f" {'characters' if chars else 'words'}).",
              "bn": "দৈর্ঘ্য: কমপক্ষে প্রয়োজনীয় পরিমাণ লিখুন/বলুন।"}]
    for k, c in enumerate(task.get("checks", [])):
        hit = any(normalize(a, pack) in norm for a in c["any"])
        items.append({"id": f"c{k}", "ok": hit, "en": c["en"], "bn": c["bn"]})
    if task.get("max_words") and n > task["max_words"]:
        items.append({"id": "too_long", "ok": False, "value": n,
                      "en": f"Too long for this task (max about {task['max_words']}).",
                      "bn": "এই কাজের জন্য বেশি লম্বা।"})
    passed = sum(1 for i in items if i["ok"])
    return {"items": items, "passed": passed, "total": len(items), "estimate": True}


# ------------------------------------------------------------- scoring
def estimate(pack, results):
    """results: [{"level", "skill", "ok": bool}] for every graded item (mcq /
    order exact; write/speak count as ok when the checklist fully passed).
    Ladder: the estimated level is the highest level L such that every level
    up to and including L scored >= pass_pct. Returns level id (or None =
    'below the first level'), per-level and per-skill percentages, weak skills."""
    order = [lv["id"] for lv in pack["levels"]]
    need = (pack.get("scoring") or {}).get("pass_pct", 60)
    by_level, by_skill = {}, {}
    for r in results or []:
        if r.get("level") not in order:
            continue
        a = by_level.setdefault(r["level"], [0, 0])
        a[0] += 1 if r.get("ok") else 0
        a[1] += 1
        s = by_skill.setdefault(r.get("skill", "?"), [0, 0])
        s[0] += 1 if r.get("ok") else 0
        s[1] += 1
    pct = lambda a: round(100 * a[0] / a[1]) if a[1] else None
    level = None
    for lv in order:
        if lv not in by_level:
            break
        if pct(by_level[lv]) >= need:
            level = lv
        else:
            break
    skills = {k: pct(v) for k, v in by_skill.items()}
    weak = sorted((k for k, v in skills.items() if v is not None and v < need),
                  key=lambda k: skills[k])
    return {"level": level, "levels": {k: pct(v) for k, v in by_level.items()},
            "skills": skills, "weak": weak, "estimate": True,
            "label": pack["estimate_label"]}


def grade_item(item, answer, pack):
    """Grade one auto-gradable item; returns bool or None (not auto-gradable)."""
    if item.get("type") == "mcq":
        try:
            return int(answer) == item["answer"]
        except (TypeError, ValueError):
            return False
    if item.get("type") == "order":
        given = answer if isinstance(answer, list) else [answer]
        return [normalize(x, pack) for x in given] == [normalize(x, pack) for x in item["answer"]]
    return None


# ------------------------------------------------------------- validation
def _walk_L(obj, path, errs):
    """Every {"en","bn"} pair: both non-empty, bn really Bangla, no ASCII
    digits in bn outside level tags (Bangla-digit rule)."""
    if isinstance(obj, dict):
        if "en" in obj and "bn" in obj:
            if not str(obj["en"]).strip() or not str(obj["bn"]).strip():
                errs.append(f"{path}: empty en/bn")
            elif not _BN.search(obj["bn"]):
                errs.append(f"{path}: bn has no Bangla")
            elif re.search(r"[0-9]", _LEVEL_TAG.sub("", obj["bn"])):
                errs.append(f"{path}: ASCII digit in bn: {obj['bn'][:40]}")
        for k, v in obj.items():
            if k in ("t", "tr", "text", "tokens", "answer", "any", "ai_brief", "model_answer"):
                continue
            _walk_L(v, f"{path}.{k}", errs)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            _walk_L(v, f"{path}[{i}]", errs)


def _items(pack):
    yield from pack["placement"]
    for sec in pack["mock"]["sections"]:
        yield from sec["items"]


def validate(pack):
    errs = []
    for k in ("code", "name", "levels", "estimate_label", "placement", "lessons",
              "scenarios", "pronunciation", "mock", "tts_locale", "stt_locale", "match"):
        if k not in pack:
            errs.append(f"missing {k}")
    if errs:
        return errs
    lv = [x["id"] for x in pack["levels"]]
    est = pack["estimate_label"]
    if "estimated" not in est["en"].lower() or "not an official" not in est["en"].lower() \
            or "আনুমানিক" not in est["bn"]:
        errs.append("estimate label must say estimated / not official")
    ids = set()

    def uid(x):
        if x in ids:
            errs.append(f"duplicate id {x}")
        ids.add(x)

    for it in _items(pack):
        uid(it["id"])
        if it["level"] not in lv:
            errs.append(f"{it['id']}: unknown level {it['level']}")
        if it["skill"] not in SKILLS:
            errs.append(f"{it['id']}: unknown skill")
        if it["type"] == "mcq":
            opts = it["options"]
            if len(opts) < 2 or not 0 <= it["answer"] < len(opts):
                errs.append(f"{it['id']}: bad options/answer")
            keys = [json.dumps(o, sort_keys=True, ensure_ascii=False) for o in opts]
            if len(set(keys)) != len(keys):
                errs.append(f"{it['id']}: duplicate options")
            if it.get("audio") and not it.get("text"):
                errs.append(f"{it['id']}: audio item without text for TTS")
        elif it["type"] == "order":
            if sorted(it["tokens"]) != sorted(it["answer"]) or it["tokens"] == it["answer"]:
                errs.append(f"{it['id']}: order tokens must be a shuffle of the answer")
        elif it["type"] in ("write", "speak"):
            if not it["checks"] or it["min_words"] < 1:
                errs.append(f"{it['id']}: write/speak needs checks + min_words")
    for need in lv:
        if not any(q["level"] == need for q in pack["placement"]):
            errs.append(f"placement has no item for level {need}")
    for ls in pack["lessons"]:
        uid(ls["id"])
        if ls["level"] not in lv or len(ls["items"]) < 6:
            errs.append(f"{ls['id']}: bad level or fewer than 6 items")
        for x in ls["items"]:
            if not x.get("t") or not x.get("en") or not x.get("bn"):
                errs.append(f"{ls['id']}: item missing t/en/bn")
    places = {s["place"] for s in pack["scenarios"]}
    for p in PLACES:
        if p not in places:
            errs.append(f"no scenario for {p}")
    for s in pack["scenarios"]:
        uid(s["id"])
        whos = {t["who"] for t in s["turns"]}
        if whos != {"you", "them"} or len(s["turns"]) < 4 or len(s["ai_brief"]) < 40:
            errs.append(f"{s['id']}: needs both speakers, >=4 turns, an AI brief")
    if len(pack["pronunciation"]) < 10:
        errs.append("fewer than 10 pronunciation sentences")
    for p in pack["pronunciation"]:
        uid(p["id"])
        if not tokens(p["t"], pack):
            errs.append(f"{p['id']}: no tokens")
    secs = pack["mock"]["sections"]
    if {s["skill"] for s in secs} != set(SKILLS):
        errs.append("mock must have listening, reading, writing, speaking")
    if sum(s["minutes"] for s in secs) != pack["mock"]["minutes"]:
        errs.append("mock minutes do not add up")
    graded = [it for s in secs for it in s["items"] if it["type"] in ("mcq", "order")]
    for need in pack.get("mock_levels", lv):
        if sum(1 for it in graded if it["level"] == need) < 2:
            errs.append(f"mock has < 2 graded items at {need}")
    _walk_L({k: v for k, v in pack.items() if k not in ("native",)}, pack["code"], errs)
    return errs
