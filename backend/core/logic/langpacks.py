"""
langpacks.py — the LANGUAGE PARTNER framework (owner design 3 Nov 11:45).

Eight languages in the owner's order, each backed by a DATA-ONLY pack:
backend/core/data/langpacks/<code>.json (format: owner_actions/LANGUAGE_PACK_FORMAT.md).
Adding a language = dropping a valid JSON file; no code change. A language
whose pack file is missing or invalid is listed with available=False and the
app shows it as a disabled card ("lessons for this language are not added
yet") — never a promise.

PURE except for reading the pack files: no Django, no DB, no network, no
clock, no AI. Grading is deterministic. AI role-play, quotas and result
storage live in core/learn_views.py.

HONESTY: every level here is an "Assisto practice estimate", never an official
IELTS / PTE / TOPIK / JLPT / JFT / CEFR / HSK result. Packs contain ORIGINAL
questions only (validated: no official-paper references in the text).
"""
import json
import os
import re

FORMAT = 1
PACK_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "data", "langpacks")

# Owner order (3 Nov). `exams_*` are exam NAMES for orientation only — we never
# claim their scores. `purpose` marks the work-abroad tracks.
LANGUAGES = [
    {"code": "en", "name_en": "English", "name_bn": "ইংরেজি", "native": "English",
     "exams_en": "IELTS · PTE style", "exams_bn": "IELTS · PTE ধাঁচ", "purpose": "study_work"},
    {"code": "ko", "name_en": "Korean", "name_bn": "কোরিয়ান", "native": "한국어",
     "exams_en": "EPS-TOPIK · TOPIK 1–6", "exams_bn": "EPS-TOPIK · TOPIK ১–৬", "purpose": "work_korea"},
    {"code": "ja", "name_en": "Japanese", "name_bn": "জাপানি", "native": "日本語",
     "exams_en": "JFT-Basic · JLPT N5–N1", "exams_bn": "JFT-Basic · JLPT N৫–N১", "purpose": "work_japan"},
    {"code": "ar", "name_en": "Arabic", "name_bn": "আরবি", "native": "العربية",
     "exams_en": "Work Arabic for the Gulf", "exams_bn": "উপসাগরীয় দেশে কাজের আরবি", "purpose": "work_gulf"},
    {"code": "de", "name_en": "German", "name_bn": "জার্মান", "native": "Deutsch",
     "exams_en": "CEFR A1–C2", "exams_bn": "CEFR A১–C২", "purpose": "study_work"},
    {"code": "fr", "name_en": "French", "name_bn": "ফরাসি", "native": "Français",
     "exams_en": "CEFR A1–C2", "exams_bn": "CEFR A১–C২", "purpose": "study_work"},
    {"code": "es", "name_en": "Spanish", "name_bn": "স্প্যানিশ", "native": "Español",
     "exams_en": "CEFR A1–C2", "exams_bn": "CEFR A১–C২", "purpose": "study_work"},
    {"code": "zh", "name_en": "Chinese", "name_bn": "চীনা", "native": "中文",
     "exams_en": "HSK 1–6", "exams_bn": "HSK ১–৬", "purpose": "study_work"},
]
CODES = tuple(l["code"] for l in LANGUAGES)
SKILLS = ("reading", "listening", "writing", "speaking", "grammar", "vocab")
SCENARIO_IDS = ("airport", "workplace", "doctor", "renting", "shopping")
WEAK_PCT = 60

ESTIMATE_LABEL = {
    "en": "Assisto practice estimate — not an official exam result.",
    "bn": "Assisto অনুশীলনের অনুমান — অফিসিয়াল পরীক্ষার ফল নয়।",
}

# Text that must never appear in a pack (copied official papers).
_BANNED = re.compile(r"cambridge ielts \d|official (past )?paper|©|copyright|all rights reserved",
                     re.I)


class PackError(ValueError):
    pass


def _need(cond, msg):
    if not cond:
        raise PackError(msg)


def _check_mcq(q, where):
    _need(isinstance(q, dict) and q.get("id"), f"{where}: question without id")
    _need(q.get("type") == "mcq", f"{where}/{q.get('id')}: only type 'mcq' is auto-graded")
    opts = q.get("options")
    _need(isinstance(opts, list) and len(opts) >= 2, f"{where}/{q['id']}: options")
    _need(isinstance(q.get("answer"), int) and 0 <= q["answer"] < len(opts),
          f"{where}/{q['id']}: answer index")
    _need(q.get("skill") in SKILLS, f"{where}/{q['id']}: skill")
    _need(q.get("explain_bn") and q.get("explain_en"), f"{where}/{q['id']}: explain_bn + explain_en")


def validate(pack):
    """Raise PackError with a readable reason; return the pack when valid."""
    _need(isinstance(pack, dict), "pack is not an object")
    _need(pack.get("format") == FORMAT, "format must be 1")
    _need(pack.get("lang") in CODES, "unknown lang")
    _need(pack.get("stt_locale"), "stt_locale")
    levels = pack.get("levels") or []
    _need(levels and all(l.get("id") and l.get("en") and l.get("bn") for l in levels), "levels")
    ids = [l["id"] for l in levels]
    pl = pack.get("placement") or {}
    _need(len(pl.get("questions") or []) >= 8, "placement needs >= 8 questions")
    for q in pl["questions"]:
        _check_mcq(q, "placement")
        _need(q.get("level") in ids, f"placement/{q['id']}: level not in levels")
    lessons = pack.get("lessons") or []
    _need(lessons, "lessons")
    for les in lessons:
        _need(les.get("id") and les.get("level") in ids, f"lesson {les.get('id')}: level")
        _need(les.get("title_en") and les.get("title_bn"), f"lesson {les['id']}: titles")
        _need(les.get("items"), f"lesson {les['id']}: items")
        for it in les["items"]:
            _need(it.get("target") and it.get("bn") and it.get("en"),
                  f"lesson {les['id']}: item needs target + bn + en")
    for sc in pack.get("scenarios") or []:
        _need(sc.get("id") in SCENARIO_IDS, f"scenario id {sc.get('id')}")
        for k in ("title_en", "title_bn", "ai_role", "opening", "goals_en", "goals_bn"):
            _need(sc.get(k), f"scenario {sc['id']}: {k}")
    for p in pack.get("pron") or []:
        _need(p.get("id") and p.get("text") and p.get("tip_bn") and p.get("tip_en"), "pron row")
    for m in pack.get("mock") or []:
        _need(m.get("id") and m.get("title_en") and m.get("title_bn"), "mock titles")
        _need(m.get("format_en") and m.get("format_bn"), f"mock {m['id']}: format text")
        _need(isinstance(m.get("minutes"), int) and m["minutes"] > 0, f"mock {m['id']}: minutes")
        _need(m.get("sections"), f"mock {m['id']}: sections")
        for s in m["sections"]:
            _need(s.get("id") and s.get("skill") in SKILLS, f"mock {m['id']}: section skill")
            for q in s.get("questions") or []:
                _check_mcq(q, f"mock {m['id']}/{s['id']}")
            if s["skill"] == "listening":
                # listening needs licensed audio; no audio -> no listening section
                _need(all(q.get("audio_url", "").startswith("https://")
                          for q in s.get("questions") or []),
                      f"mock {m['id']}/{s['id']}: listening needs audio_url (licensed)")
        bands = m.get("bands") or []
        _need(bands and bands[0].get("min_pct") == 0, f"mock {m['id']}: bands start at 0")
        _need(all(b.get("level") in ids for b in bands), f"mock {m['id']}: band level")
    _need(not _BANNED.search(json.dumps(pack, ensure_ascii=False)),
          "pack text looks copied from an official paper")
    return pack


_CACHE = {}


def load(code):
    """The validated pack for `code`, or None (missing / invalid file)."""
    if code not in CODES:
        return None
    path = os.path.join(PACK_DIR, f"{code}.json")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return None
    hit = _CACHE.get(code)
    if hit and hit[0] == mtime:
        return hit[1]
    try:
        with open(path, encoding="utf-8") as f:
            pack = validate(json.load(f))
    except (OSError, ValueError):
        pack = None
    _CACHE[code] = (mtime, pack)
    return pack


def catalog():
    """The 8 language cards in owner order, each with its real state."""
    out = []
    for l in LANGUAGES:
        p = load(l["code"])
        row = dict(l, available=p is not None)
        if p is not None:
            row.update({
                "levels": [x["id"] for x in p["levels"]],
                "counts": {"lessons": len(p["lessons"]),
                           "scenarios": len(p.get("scenarios") or []),
                           "mock": len(p.get("mock") or []),
                           "pron": len(p.get("pron") or [])},
            })
        out.append(row)
    return out


def public_pack(pack):
    """The pack as the app sees it: answer keys stay on the server."""
    def strip(q):
        return {k: v for k, v in q.items() if k not in ("answer", "explain_bn", "explain_en")}
    p = json.loads(json.dumps(pack))
    p["placement"]["questions"] = [strip(q) for q in p["placement"]["questions"]]
    for m in p.get("mock") or []:
        for s in m["sections"]:
            if s.get("questions"):
                s["questions"] = [strip(q) for q in s["questions"]]
    for sc in p.get("scenarios") or []:
        sc.pop("ai_role", None)  # the AI's instructions are server-side only
    return p


def _grade(questions, answers):
    rows = []
    for q in questions:
        given = (answers or {}).get(q["id"])
        try:
            given = int(given)
        except (TypeError, ValueError):
            given = None
        rows.append({"id": q["id"], "skill": q["skill"], "level": q.get("level"),
                     "given": given, "answer": q["answer"], "correct": given == q["answer"],
                     "explain_bn": q["explain_bn"], "explain_en": q["explain_en"]})
    return rows


def _by_skill(rows):
    agg = {}
    for r in rows:
        a = agg.setdefault(r["skill"], [0, 0])
        a[0] += r["correct"]
        a[1] += 1
    return {k: round(100 * c / n) for k, (c, n) in agg.items()}


def grade_placement(pack, answers):
    """Placed level = the highest level L such that every level up to L has
    >= pass_pct correct (the first level is always reached). Weak areas = skills
    under WEAK_PCT."""
    qs = pack["placement"]["questions"]
    pass_pct = int(pack["placement"].get("pass_pct") or 60)
    rows = _grade(qs, answers)
    order = [l["id"] for l in pack["levels"]]
    placed = order[0]
    for lvl in order:
        lr = [r for r in rows if r["level"] == lvl]
        if not lr:
            continue
        if 100 * sum(r["correct"] for r in lr) / len(lr) >= pass_pct:
            placed = lvl
        else:
            break
    skills = _by_skill(rows)
    correct = sum(r["correct"] for r in rows)
    return {"level": placed, "correct": correct, "total": len(rows),
            "score_pct": round(100 * correct / len(rows)) if rows else 0,
            "skills": skills, "weak": sorted(k for k, v in skills.items() if v < WEAK_PCT),
            "rows": rows, "estimate": True}


def mock_test(pack, mock_id):
    return next((m for m in pack.get("mock") or [] if m["id"] == mock_id), None)


def grade_mock(pack, mock_id, answers, texts=None, seconds=None):
    """Objective sections are auto-graded; open sections (writing prompts,
    read-aloud) get a key-free word-count check and are listed separately.
    Estimated level from the mock's `bands` on the objective percentage."""
    m = mock_test(pack, mock_id)
    if m is None:
        return None
    rows, sections, open_rows = [], [], []
    for s in m["sections"]:
        if s.get("questions"):
            r = _grade(s["questions"], answers)
            rows += r
            c = sum(x["correct"] for x in r)
            sections.append({"id": s["id"], "skill": s["skill"], "correct": c,
                             "total": len(r), "pct": round(100 * c / len(r))})
        for p in s.get("prompts") or []:
            t = str((texts or {}).get(p["id"]) or "")
            n = len(re.findall(r"\S+", t))
            lo, hi = int(p.get("min_words") or 0), p.get("max_words")
            ok = n >= lo and (hi is None or n <= int(hi))
            open_rows.append({"id": p["id"], "section": s["id"], "skill": s["skill"],
                              "words": n, "min_words": lo, "max_words": hi, "ok": ok})
    correct = sum(r["correct"] for r in rows)
    pct = round(100 * correct / len(rows)) if rows else 0
    level = m["bands"][0]["level"]
    for b in sorted(m["bands"], key=lambda b: b["min_pct"]):
        if pct >= b["min_pct"]:
            level = b["level"]
    weak = sorted({s["skill"] for s in sections if s["pct"] < WEAK_PCT} |
                  {o["skill"] for o in open_rows if not o["ok"]})
    timed_out = bool(seconds) and int(seconds) > m["minutes"] * 60
    return {"mock_id": mock_id, "level": level, "score_pct": pct, "correct": correct,
            "total": len(rows), "sections": sections, "open": open_rows, "weak": weak,
            "rows": rows, "timed_out": timed_out, "minutes": m["minutes"], "estimate": True}


def course_result(lang, level, score, date):
    """SEAM for the certificate agent (agent/learncert): the canonical,
    validated result record. `date` is an ISO date string the caller passes
    (no clock here). Raises PackError on bad input."""
    _need(lang in CODES, "lang")
    pack = load(lang)
    _need(pack is not None, "no pack")
    _need(level in [l["id"] for l in pack["levels"]], "level")
    score = int(score)
    _need(0 <= score <= 100, "score 0..100")
    _need(re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(date) or "") is not None, "date YYYY-MM-DD")
    meta = next(l for l in LANGUAGES if l["code"] == lang)
    return {"lang": lang, "language_en": meta["name_en"], "language_bn": meta["name_bn"],
            "level": level, "level_system": pack.get("level_system", ""),
            "score": score, "date": str(date), "estimate": True,
            "label": ESTIMATE_LABEL}


# ------------------------------------------------------------- daily AI quota
FREE_AI_PER_DAY = 3      # free plan: AI role-play / AI estimate turns, not charged
PAID_AI_PER_DAY = 30     # any paid plan
# Beyond the allowance each AI turn is charged in credits through the AI router
# (ai_msg_cheap for role-play, ai_msg_medium for an estimate) — both priced
# >= cost / 0.60 (40% rule, pinned by tests_p2lang).


def ai_allowance(plan):
    return PAID_AI_PER_DAY if plan and plan != "free" else FREE_AI_PER_DAY
