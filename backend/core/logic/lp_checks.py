"""
lp_checks.py — the AUTOMATIC checks every Language Partner content item passes
before it can be shown (lpcore, owner order 9 Nov 21:45 part G). PURE.

check_item(kind, data, level, known=frozenset()) -> {"ok", "failures": [...]}

  format      required fields per kind / question type; IELTS structure
              (Listening 4 parts + 40 questions, Reading 3 passages + 40)
  uniqueness  a single-answer question has exactly ONE key, options are
              unique, an mcq key is one of the options, T/F/NG keys are valid
  word_limit  every accepted gap answer fits the question's word limit
  level       Reading passage length fits the level / exam
  timing      Listening 30 min, Reading 60, Writing 60, Speaking 11-14
  copyright   banned markers (Cambridge, UCLES, publisher lines) + a
              known-text fingerprint list (8-word shingle hashes; the texts
              themselves are never stored)
  duplicate   (DB side) the same normalized content hash as another key

Failures are short machine codes + a human hint; the Owner Admin queue shows them.
"""
import hashlib
import json
import re

from . import lp_bands as B

SECTIONS = ("listening", "reading", "writing", "speaking")
DURATION = {"listening": (1800, 1800), "reading": (3600, 3600), "writing": (3600, 3600)}
SPEAKING_TOTAL = (660, 840)          # 11-14 minutes
L_PARTS, L_QUESTIONS, R_PASSAGES, R_QUESTIONS = 4, 40, 3, 40
# Reading passage words by band target (public exam passages run ~700-950;
# practice levels may be shorter)
PASSAGE_WORDS = {"default": (500, 1100), "B1": (250, 800), "A2": (120, 500), "A1": (60, 300)}
SINGLE = ("mcq", "tfng", "ynng", "matching", "map")
ACCENTS = ("uk", "au", "us", "ca", "nz", "in")

# NEVER Cambridge material (owner rule). Lower-case substrings.
BANNED = (
    "cambridge university press", "cambridge english", "cambridge assessment", "cambridge ielts",
    "ucles", "university of cambridge local examinations", "© cambridge", "(c) cambridge",
    "cambridge books for", "cambridge book ", "ielts 1 academic", "authentic examination papers",
    "british council ielts", "idp ielts", "© british council", "© idp",
)
SHINGLE = 8
# stage 2 (lpstage2, tools/lp/FORMAT.md §10): going-abroad tracks
# + stage 3 (lpstage3, FORMAT.md §11): Chinese HSK1, French A1, work Arabic
STAGE2_TRACKS = ("jlpt_n5", "jft_basic", "eps_topik", "de_a1", "hsk1", "fr_a1", "ar_work")
LETTERS = "ABCDEF"          # shared 6-option banks (HSK / DELF matching)


def text_of(obj):
    """Every string inside a JSON object, joined (for copyright / dup checks)."""
    out = []

    def walk(o):
        if isinstance(o, str):
            out.append(o)
        elif isinstance(o, dict):
            for k in sorted(o):
                if k not in ("audio", "image", "audio_url", "image_url"):
                    walk(o[k])
        elif isinstance(o, (list, tuple)):
            for x in o:
                walk(x)
    walk(obj)
    return "\n".join(out)


def content_hash(kind, data):
    t = B.norm(text_of(data))
    return hashlib.sha256(("%s|%s" % (kind, t)).encode("utf-8")).hexdigest()


def shingles(text, n=SHINGLE):
    w = re.findall(r"[a-z0-9']+", str(text or "").lower())
    for i in range(max(0, len(w) - n + 1)):
        yield hashlib.sha256(" ".join(w[i:i + n]).encode()).hexdigest()[:16]


def fingerprints(text):
    """The hashes the owner may add to the known-text list (manage.py
    lp_fingerprint) — the source text is never kept."""
    return sorted(set(shingles(text)))


def copyright_failures(text, known=frozenset()):
    low = str(text or "").lower()
    fails = []
    hit = next((b for b in BANNED if b in low), None)
    if hit:
        fails.append(("copyright_marker", hit))
    if known:
        n = sum(1 for h in shingles(text) if h in known)
        if n >= 2:
            fails.append(("copyright_known_text", "%d matching 8-word runs" % n))
    return fails


_OPT_LETTER = re.compile(r"^\s*([A-Za-z]{1,4})[.)]\s")


def opt_id(o):
    """An option's id: a dict's "id", the letter of "A. text" (the app's
    shape), else the normalized text."""
    if isinstance(o, dict):
        return B.norm(o.get("id"))
    m = _OPT_LETTER.match(str(o or ""))
    return B.norm(m.group(1)) if m else B.norm(o)


def _q_failures(q, where):
    f = []
    t = q.get("type")
    if t not in B.TYPES:
        return [("format", "%s: unknown type %r" % (where, t))]
    if not str(q.get("prompt") or "").strip() and t not in ("map",):
        f.append(("format", "%s: empty prompt" % where))
    if q.get("n") in (None, ""):
        f.append(("format", "%s: no number" % where))
    key = q.get("answer")
    keys = key if isinstance(key, (list, tuple)) else ([key] if key not in (None, "") else [])
    if not keys:
        return f + [("uniqueness", "%s: no answer key" % where)]
    if not str(q.get("tag") or "").strip():
        f.append(("format", "%s: no skill tag" % where))
    if not (q.get("explain_en") and q.get("explain_bn")):
        f.append(("format", "%s: needs explain_en + explain_bn" % where))
    opts = q.get("options")
    if opts is not None:
        labels = [opt_id(o) for o in opts]
        if len(labels) != len(set(labels)):
            f.append(("uniqueness", "%s: repeated options" % where))
    if t in ("mcq", "mcq_multi"):
        if not opts or len(opts) < 3:
            f.append(("format", "%s: mcq needs 3+ options" % where))
        else:
            ids = {opt_id(o).upper() for o in opts}
            letters = B._letters("/".join(str(k) for k in keys)) if t == "mcq_multi" \
                else [B.norm(keys[0]).upper()]
            if any(x not in ids for x in letters):
                f.append(("uniqueness", "%s: key not among the options" % where))
    if t in SINGLE and len(keys) != 1:
        f.append(("uniqueness", "%s: single-answer question has %d keys" % (where, len(keys))))
    if t == "tfng" and B._choice(keys[0], "tfng") not in ("TRUE", "FALSE", "NOT GIVEN"):
        f.append(("uniqueness", "%s: T/F/NG key must be TRUE, FALSE or NOT GIVEN" % where))
    if t == "ynng" and B._choice(keys[0], "ynng") not in ("YES", "NO", "NOT GIVEN"):
        f.append(("uniqueness", "%s: Y/N/NG key must be YES, NO or NOT GIVEN" % where))
    if t in ("gap", "short"):
        mw = q.get("max_words")
        if not isinstance(mw, int) or not 1 <= mw <= 5:
            f.append(("format", "%s: gap needs max_words 1-5" % where))
        else:
            for a in B.accepted(key):
                if len(B.words(a)) > mw:
                    f.append(("word_limit", "%s: key %r is longer than %d words" % (where, a, mw)))
                    break
    return f


def _questions_failures(qs, where):
    f = []
    seen = set()
    for i, q in enumerate(qs or []):
        if not isinstance(q, dict):
            f.append(("format", "%s q%d: not an object" % (where, i + 1)))
            continue
        n = q.get("n")
        if n in seen:
            f.append(("uniqueness", "%s: question number %s repeats" % (where, n)))
        seen.add(n)
        f += _q_failures(q, "%s q%s" % (where, n))
    return f


def section_failures(name, s, level=""):
    f = []
    if not isinstance(s, dict):
        return [("format", "%s: missing" % name)]
    if name in DURATION and int(s.get("duration_sec") or 0) not in range(
            DURATION[name][0], DURATION[name][1] + 1):
        f.append(("timing", "%s: duration_sec must be %d" % (name, DURATION[name][0])))
    if name == "listening":
        parts = s.get("parts") or []
        if len(parts) != L_PARTS:
            f.append(("format", "listening: %d parts (needs %d)" % (len(parts), L_PARTS)))
        nq = 0
        for p in parts:
            w = "listening part %s" % p.get("n")
            # lpfinish: until the CI TTS job renders audio, a part may carry its
            # script as `turns` — the phone's own voice reads it (never shown)
            if not p.get("audio") and not tts_lines(p):
                f.append(("format", w + ": no audio and no TTS script"))
            if p.get("accent") not in ACCENTS:
                f.append(("format", w + ": accent must be one of " + "/".join(ACCENTS)))
            if not str(p.get("transcript") or "").strip():
                f.append(("format", w + ": no transcript (reviewers need it)"))
            nq += len(p.get("questions") or [])
            f += _questions_failures(p.get("questions"), w)
        if nq != L_QUESTIONS:
            f.append(("format", "listening: %d questions (needs %d)" % (nq, L_QUESTIONS)))
    elif name == "reading":
        ps = s.get("passages") or []
        if len(ps) != R_PASSAGES:
            f.append(("format", "reading: %d passages (needs %d)" % (len(ps), R_PASSAGES)))
        lo, hi = PASSAGE_WORDS.get(level, PASSAGE_WORDS["default"])
        nq = 0
        for p in ps:
            w = "reading passage %s" % p.get("n")
            nw = len(B.words(p.get("text")))
            if not lo <= nw <= hi:
                f.append(("level", "%s: %d words (expected %d-%d)" % (w, nw, lo, hi)))
            nq += len(p.get("questions") or [])
            f += _questions_failures(p.get("questions"), w)
        if nq != R_QUESTIONS:
            f.append(("format", "reading: %d questions (needs %d)" % (nq, R_QUESTIONS)))
    elif name == "writing":
        ts = s.get("tasks") or []
        if sorted(t.get("n") for t in ts) != [1, 2]:
            f.append(("format", "writing: needs task 1 and task 2"))
        for t in ts:
            if not str(t.get("prompt") or "").strip():
                f.append(("format", "writing task %s: empty prompt" % t.get("n")))
            want = 150 if t.get("n") == 1 else 250
            if int(t.get("min_words") or 0) != want:
                f.append(("format", "writing task %s: min_words must be %d" % (t.get("n"), want)))
    elif name == "speaking":
        ps = {p.get("n"): p for p in (s.get("parts") or [])}
        if sorted(ps) != [1, 2, 3]:
            f.append(("format", "speaking: needs parts 1, 2 and 3"))
        else:
            if len(ps[1].get("questions") or []) < 4:
                f.append(("format", "speaking part 1: 4+ questions"))
            if not str(ps[2].get("cue_card") or "").strip():
                f.append(("format", "speaking part 2: no cue card"))
            if int(ps[2].get("prep_sec") or 0) != 60 or int(ps[2].get("talk_sec") or 0) != 120:
                f.append(("timing", "speaking part 2: prep 60 s + talk 120 s"))
            if len(ps[3].get("questions") or []) < 3:
                f.append(("format", "speaking part 3: 3+ questions"))
            total = int(s.get("duration_sec") or 0)
            if total and not SPEAKING_TOTAL[0] <= total <= SPEAKING_TOTAL[1]:
                f.append(("timing", "speaking: 11-14 minutes"))
    return f


def tts_lines(part):
    """The spoken lines of a listening part without recorded audio."""
    return [str(t.get("text")).strip() for t in part.get("turns") or []
            if isinstance(t, dict) and str(t.get("text") or "").strip()]


def track_questions(data):
    """[(section, part, question)] of a stage-2 track test (sections is a LIST)."""
    out = []
    for s in data.get("sections") or []:
        for p in (s.get("parts") or []) if isinstance(s, dict) else []:
            for q in p.get("questions") or []:
                out.append((s, p, q))
    return out


def track_mock_failures(data):
    """Stage-2 test (§10.5): letter-keyed choice questions numbered 1..N across
    the whole test; listening questions carry a TTS script; writing/speaking
    sections carry tasks. The per-exam blueprint is checked in lpstage2's CI."""
    f = []
    secs = data.get("sections")
    if not isinstance(secs, list) or not secs:
        return [("format", "track test: no sections")]
    if not (data.get("title_en") and data.get("title_bn")):
        f.append(("format", "track test: title_en + title_bn"))
    ns = []
    for s, p, q in track_questions(data):
        w = "%s q%s" % (s.get("id"), q.get("n"))
        ns.append(q.get("n"))
        opts = q.get("options") or []
        # 2 = true/false items of the real formats (German A1 Hoeren richtig/falsch,
        # HSK 1 picture judge); 6 = the shared HSK / DELF matching banks
        if not 2 <= len(opts) <= 6:
            f.append(("format", w + ": 2-6 options"))
        elif len(set(map(str, opts))) != len(opts):
            f.append(("uniqueness", w + ": repeated options"))
        a = str(q.get("answer") or "")
        if len(a) != 1 or a not in LETTERS[:max(1, len(opts))]:
            f.append(("uniqueness", w + ": answer must be ONE option letter"))
        if not q.get("explain_bn"):
            f.append(("format", w + ": needs explain_bn"))
        if s.get("kind") == "listening" and not isinstance(q.get("script") or p.get("script"), dict):
            f.append(("format", w + ": listening needs a script"))
    if ns != list(range(1, len(ns) + 1)):
        f.append(("format", "track test: question numbers must run 1..N"))
    for s in secs:
        if isinstance(s, dict) and s.get("kind") in ("writing", "speaking") and not s.get("tasks"):
            f.append(("format", "%s: needs tasks" % s.get("id")))
        if isinstance(s, dict) and not 1 <= int(s.get("minutes") or 0) <= 180:
            f.append(("timing", "%s: minutes" % s.get("id")))
    return f


def syllabus_failures(data):
    f = []
    if not isinstance(data.get("title"), dict):
        f.append(("format", "syllabus: title {en, bn}"))
    weeks = data.get("weeks") or []
    if not weeks:
        f.append(("format", "syllabus: no weeks"))
    for w in weeks:
        if not w.get("planned") and not w.get("lessons"):
            f.append(("format", "syllabus week %s: lessons or planned" % w.get("week")))
    if not (data.get("exam_format") or {}).get("sections"):
        f.append(("format", "syllabus: exam_format.sections"))
    return f


def lesson_failures(data):
    f = []
    if not data.get("id"):
        f.append(("format", "lesson: no id"))
    if len(data.get("vocab") or []) < 6:
        f.append(("format", "lesson: 6+ vocab"))
    if not data.get("grammar"):
        f.append(("format", "lesson: 1+ grammar point"))
    pr = data.get("practice") or {}
    for sk in ("listening", "reading", "writing", "speaking"):
        if not pr.get(sk):
            f.append(("format", "lesson: no %s practice" % sk))
    for sk in ("listening", "reading"):
        for q in pr.get(sk) or []:
            a = str(q.get("answer") or "")
            if len(a) != 1 or a not in LETTERS[:len(q.get("options") or [])]:
                f.append(("uniqueness", "lesson %s: answer must be ONE option letter" % q.get("id")))
    return f


def check_item(kind, data, level="", known=frozenset(), track=""):
    f = []
    if not isinstance(data, dict) or not data:
        return {"ok": False, "failures": [{"code": "format", "hint": "empty item"}]}
    if kind == "mock" and (track in STAGE2_TRACKS or isinstance(data.get("sections"), list)):
        f += track_mock_failures(data)
    elif kind == "syllabus":
        f += syllabus_failures(data)
    elif kind == "lesson":
        f += lesson_failures(data)
    elif kind == "mock":
        if not (data.get("title_en") and data.get("title_bn")):
            f.append(("format", "mock: title_en + title_bn"))
        for s in SECTIONS:
            if s not in data and s not in (data.get("sections") or {}):
                f.append(("format", "mock: no %s section" % s))
    elif kind == "section":
        f += section_failures(data.get("section"), data.get("body"), level)
    elif kind == "question":
        if data.get("section") not in ("listening", "reading"):
            f.append(("format", "question: section must be listening or reading"))
        f += _q_failures(data.get("q") or {}, "question")
    elif kind in ("scenario", "vocab"):
        if not str(data.get("id") or "").strip():
            f.append(("format", "%s: no id" % kind))
        if kind == "vocab" and not (data.get("words") or data.get("word") or data.get("items")):
            f.append(("format", "vocab: no words"))
    else:
        f.append(("format", "unknown kind %r" % kind))
    f += copyright_failures(text_of(data), known)
    return {"ok": not f, "failures": [{"code": c, "hint": h[:200]} for c, h in f[:60]]}


def dumps_small(data, limit=200000):
    raw = json.dumps(data, ensure_ascii=False)
    return len(raw.encode("utf-8")) <= limit
