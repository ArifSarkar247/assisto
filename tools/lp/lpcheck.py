#!/usr/bin/env python3
"""Automatic checks for Language Partner content bundles (assisto.lp.bundle/1).

Stdlib only. Runs in GitHub Actions (lp-content.yml), never needs an AI API.

    python3 tools/lp/lpcheck.py                      # check every bundle under tools/lp/content
    python3 tools/lp/lpcheck.py --out out/           # + write out/index.json and out/report.md
    python3 tools/lp/lpcheck.py path/to/bundle.json  # check given files (others still used for duplicates)

Exit code 1 when any bundle has an error. Bundles with no errors get status "ai-checked" in
index.json (the file in git keeps "draft"; human approval happens later in Owner Admin).
See tools/lp/FORMAT.md for the format and the meaning of every check.
"""
from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import re
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
CONTENT_DIR = os.path.join(HERE, "content")
FINGERPRINTS = os.path.join(HERE, "fingerprints", "known_hashes.json")
FORMAT_ID = "assisto.lp.bundle/1"

COMPLETION = {"form_completion", "note_completion", "table_completion", "flow_chart_completion",
              "sentence_completion", "summary_completion", "short_answer", "diagram_label"}
OPTION_SINGLE = {"summary_completion_box", "mcq_single", "matching", "map_labelling",
                 "matching_headings", "matching_information", "matching_sentence_endings"}
TFNG = {"tfng": ("TRUE", "FALSE", "NOT GIVEN"), "ynng": ("YES", "NO", "NOT GIVEN")}
ALL_TYPES = COMPLETION | OPTION_SINGLE | set(TFNG) | {"mcq_multi"}
LISTENING_ONLY = {"map_labelling"}
READING_ONLY = {"matching_headings", "matching_information", "matching_sentence_endings",
                "tfng", "ynng"}
SKILLS = {"detail", "number", "spelling", "paraphrase", "gist", "inference", "opinion",
          "main_idea", "map_direction", "matching_info", "vocabulary", "writer_view", "signpost"}
CONTEXTS = {1: "everyday_dialogue", 2: "everyday_monologue", 3: "academic_discussion",
            4: "academic_lecture"}
ACCENTS = {"GB", "US", "AU"}
BANNED_MARKERS = ["cambridge ielts", "cambridge university press", "cambridge assessment",
                  "ucles", "©", "(c) ", "all rights reserved", "british council", "idp education",
                  "official ielts", "ielts official", "reproduced with permission",
                  "copyright"]
NUM_WORDS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5}
WPM = 150          # spoken English pace used for timing estimates
SHINGLE = 8

# ---------------------------------------------------------------------------- text helpers

def norm_answer(s: str) -> str:
    s = unicodedata.normalize("NFKC", str(s)).lower().strip()
    s = s.replace("’", "'").replace("‘", "'").replace("“", '"').replace("”", '"')
    s = s.replace("-", " ").replace("–", " ")
    s = re.sub(r"\s+", " ", s).strip()
    if s.endswith("."):
        s = s[:-1].strip()
    return s


def norm_text(s: str) -> str:
    s = unicodedata.normalize("NFKC", str(s)).lower()
    s = s.replace("’", "'").replace("‘", "'")
    s = re.sub(r"(?<=\w)'(?=\w)", "", s)        # don't -> dont (so quotes match either way)
    return " " + re.sub(r"[^0-9a-zÀ-ɏ]+", " ", s).strip() + " "


def words(s: str) -> list[str]:
    return re.findall(r"[A-Za-zÀ-ɏ]+(?:['’-][A-Za-z]+)*", s)


def is_number_token(tok: str) -> bool:
    return bool(re.fullmatch(r"[£$€]?\d[\d,]*(\.\d+)?(%|am|pm|st|nd|rd|th|kg|km|m|cm|ml)?", tok,
                             re.I)) or bool(re.fullmatch(r"\d{1,2}[.:]\d{2}(am|pm)?", tok, re.I))


def answer_counts(ans: str) -> tuple[int, int]:
    """(word tokens, number tokens) of an answer as IELTS counts them."""
    toks = re.sub(r"\s+", " ", str(ans).strip()).split(" ")
    w = n = 0
    for t in toks:
        if not t:
            continue
        if is_number_token(t):
            n += 1
        else:
            w += 1
    return w, n


def sentences(text: str) -> list[str]:
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if words(s)]


def syllables(word: str) -> int:
    w = word.lower()
    w = re.sub(r"[^a-z]", "", w)
    if not w:
        return 0
    if len(w) <= 3:
        return 1
    w = re.sub(r"(?:[^laeiouy]es|ed|[^laeiouy]e)$", "", w)
    w = re.sub(r"^y", "", w)
    return max(1, len(re.findall(r"[aeiouy]{1,2}", w)))


def flesch(text: str) -> float:
    ws = words(text)
    ss = sentences(text)
    if not ws or not ss:
        return 100.0
    syl = sum(syllables(w) for w in ws)
    return 206.835 - 1.015 * (len(ws) / len(ss)) - 84.6 * (syl / len(ws))


def shingles(text: str, k: int = SHINGLE) -> set[str]:
    toks = norm_text(text).split()
    return {" ".join(toks[i:i + k]) for i in range(0, max(0, len(toks) - k + 1))}


def shingle_hash(sh: str) -> str:
    return hashlib.sha256(sh.encode("utf-8")).hexdigest()[:24]


def has_bangla(s: str) -> bool:
    return bool(re.search(r"[ঀ-৿]", s or ""))


# ---------------------------------------------------------------------------- bundle helpers

def listening_text(part: dict) -> str:
    out = []
    for seg in part.get("segments", []):
        for t in seg.get("turns", []):
            if "text" in t:
                out.append(t["text"])
    return "\n".join(out)


def reading_text(part: dict) -> str:
    out = []
    for tx in part.get("texts", []):
        for k in ("title", "subtitle"):
            if tx.get(k):
                out.append(tx[k])
        for p in tx.get("paragraphs", []):
            out.append(p.get("text", ""))
    return "\n".join(out)


def bundle_texts(b: dict) -> list[tuple[str, str]]:
    """(label, text) of every authored text in the bundle (for duplicate/copyright checks)."""
    res = []
    for p in b.get("listening", {}).get("parts", []):
        res.append((f"listening part {p.get('part')}", listening_text(p)))
    for p in b.get("reading", {}).get("parts", []):
        res.append((f"reading part {p.get('part')}", reading_text(p)))
    for t in b.get("writing", {}).get("tasks", []):
        res.append((f"writing task {t.get('task')} prompt", t.get("prompt", "")))
        res.append((f"writing task {t.get('task')} model", t.get("model_answer", {}).get("text", "")))
    return res


def iter_groups(b: dict):
    for sec in ("listening", "reading"):
        for p in b.get(sec, {}).get("parts", []):
            for g in p.get("groups", []):
                yield sec, p, g


class Result:
    def __init__(self, path: str):
        self.path = path
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.stats: dict = {}

    def err(self, check: str, msg: str):
        self.errors.append(f"[{check}] {msg}")

    def warn(self, check: str, msg: str):
        self.warnings.append(f"[{check}] {msg}")


# ---------------------------------------------------------------------------- checks

def check_format(b: dict, r: Result):
    c = "format"
    if b.get("format") != FORMAT_ID:
        r.err(c, f"format must be {FORMAT_ID}")
    bid = b.get("bundle_id", "")
    if not re.fullmatch(r"ielts-(ac|gt)-\d{3}", bid):
        r.err(c, f"bad bundle_id {bid!r}")
    if os.path.splitext(os.path.basename(r.path))[0] != bid:
        r.err(c, "file name must equal bundle_id")
    mod = b.get("module")
    if mod not in ("academic", "general"):
        r.err(c, "module must be academic|general")
    elif bid[6:8] != ("ac" if mod == "academic" else "gt"):
        r.err(c, "bundle_id prefix does not match module")
    if b.get("exam") != "ielts":
        r.err(c, "exam must be ielts")
    if b.get("status") != "draft":
        r.err(c, "status in git must be 'draft' (CI promotes; humans approve in Owner Admin)")
    if not isinstance(b.get("version"), int) or b["version"] < 1:
        r.err(c, "version must be an int >= 1")
    if b.get("authoring", {}).get("source") != "original":
        r.err(c, "authoring.source must be 'original'")
    for k in ("title", "practice_label"):
        v = b.get(k, {})
        if not (isinstance(v, dict) and v.get("en") and has_bangla(v.get("bn", ""))):
            r.err("bilingual", f"{k} needs en + Bangla bn")
    for sec in ("listening", "reading", "writing", "speaking"):
        if sec not in b:
            r.err(c, f"missing section {sec}")

    for sec in ("listening", "reading"):
        parts = b.get(sec, {}).get("parts", [])
        if [p.get("part") for p in parts] != [1, 2, 3, 4][:len(parts)] or \
                len(parts) != (4 if sec == "listening" else 3):
            r.err(c, f"{sec}: parts must be numbered 1..{4 if sec == 'listening' else 3}")
        seen = []
        for p in parts:
            pn = []
            for g in p.get("groups", []):
                rg = g.get("range")
                t = g.get("type")
                if t not in ALL_TYPES:
                    r.err(c, f"{sec} part {p.get('part')}: unknown type {t!r}")
                    continue
                if sec == "reading" and t in LISTENING_ONLY or sec == "listening" and t in READING_ONLY:
                    r.err(c, f"{sec}: type {t} not used in this section")
                if not g.get("instructions"):
                    r.err(c, f"{sec} {rg}: group needs instructions")
                qs = g.get("questions", [])
                ns = [q.get("n") for q in qs]
                if not (isinstance(rg, list) and len(rg) == 2 and ns == list(range(rg[0], rg[1] + 1))):
                    r.err(c, f"{sec} {rg}: questions {ns} do not match range")
                pn += ns
                for q in qs:
                    if not q.get("prompt") and t not in ("mcq_multi",):
                        r.err(c, f"{sec} Q{q.get('n')}: empty prompt")
                    if t in COMPLETION and "{gap}" not in q.get("prompt", ""):
                        if t != "short_answer":
                            r.err(c, f"{sec} Q{q.get('n')}: completion prompt needs {{gap}}")
                    sk = q.get("skill")
                    if sk not in SKILLS:
                        r.err(c, f"{sec} Q{q.get('n')}: skill {sk!r} not in {sorted(SKILLS)}")
                    if not q.get("explain_en"):
                        r.err(c, f"{sec} Q{q.get('n')}: explain_en missing")
                    if not has_bangla(q.get("explain_bn", "")):
                        r.err("bilingual", f"{sec} Q{q.get('n')}: explain_bn must be Bangla")
            if sec == "listening" and len(pn) != 10:
                r.err(c, f"listening part {p.get('part')} has {len(pn)} questions (need 10)")
            if sec == "reading" and not 12 <= len(pn) <= 15:
                r.err(c, f"reading part {p.get('part')} has {len(pn)} questions (need 12-15)")
            seen += pn
        if seen != list(range(1, 41)):
            r.err(c, f"{sec}: questions must be numbered 1..40 exactly once (got {len(seen)})")


def check_listening_structure(b: dict, r: Result):
    c = "format"
    for p in b.get("listening", {}).get("parts", []):
        pn = p.get("part")
        if p.get("context") != CONTEXTS.get(pn):
            r.err(c, f"listening part {pn}: context must be {CONTEXTS.get(pn)}")
        if not p.get("intro"):
            r.err(c, f"listening part {pn}: intro missing")
        spk = p.get("speakers", {})
        n_au = 0
        for k, s in spk.items():
            if s.get("accent") not in ACCENTS or s.get("gender") not in ("F", "M"):
                r.err(c, f"listening part {pn} speaker {k}: accent GB|US|AU and gender F|M")
            n_au += s.get("accent") == "AU"
        if n_au > 1:
            r.err(c, f"listening part {pn}: at most one AU speaker (one licence-clean AU voice)")
        want = {1: (2, 2), 2: (1, 1), 3: (2, 4), 4: (1, 1)}[pn] if pn in (1, 2, 3, 4) else (1, 4)
        if not want[0] <= len(spk) <= want[1]:
            r.err(c, f"listening part {pn}: {len(spk)} speakers (need {want[0]}-{want[1]})")
        segs = p.get("segments", [])
        if pn == 4 and len(segs) != 1:
            r.err(c, "listening part 4 must be one segment (no mid-part pause)")
        covered = []
        used = set()
        for s in segs:
            q = s.get("questions", [])
            covered += list(range(q[0], q[1] + 1)) if len(q) == 2 else []
            if not 10 <= s.get("preview_s", 0) <= 60:
                r.err(c, f"listening part {pn}: preview_s must be 10-60")
            for t in s.get("turns", []):
                if "pause" in t:
                    if not 0.2 <= t["pause"] <= 4:
                        r.err(c, f"listening part {pn}: pause {t['pause']} out of 0.2-4 s")
                elif t.get("spk") not in spk or not t.get("text"):
                    r.err(c, f"listening part {pn}: turn with unknown speaker {t.get('spk')!r}")
                else:
                    used.add(t["spk"])
        if set(spk) - used:
            r.err(c, f"listening part {pn}: speakers never speak: {sorted(set(spk) - used)}")
        qn = [q["n"] for g in p.get("groups", []) for q in g.get("questions", [])]
        if covered != qn:
            r.err(c, f"listening part {pn}: segments cover {covered[:1]}..{covered[-1:]} "
                     f"but groups have {qn[:1]}..{qn[-1:]}")


def parse_limit_text(instr: str):
    s = instr.upper()
    m = re.search(r"NO MORE THAN (ONE|TWO|THREE|FOUR|FIVE) WORDS?", s)
    if m:
        return NUM_WORDS[m.group(1).lower()], "NUMBER" in s[m.start():m.end() + 25]
    m = re.search(r"\b(ONE|TWO|THREE|FOUR|FIVE) WORDS?( ONLY)?( AND/OR A NUMBER)?", s)
    if m:
        return NUM_WORDS[m.group(1).lower()], bool(m.group(3))
    m = re.search(r"\bA NUMBER\b", s)
    if m and "WORD" not in s:
        return 0, True
    return None


def check_answers(b: dict, r: Result):
    c = "answers"
    tf_all: list[str] = []
    letter_counts: dict[str, int] = {}
    for sec, p, g in iter_groups(b):
        t = g.get("type")
        rg = g.get("range")
        src = norm_text(listening_text(p) if sec == "listening" else reading_text(p))
        opts = [o.get("key") for o in g.get("options", [])]
        otexts = [norm_answer(o.get("text", "")) for o in g.get("options", [])]
        if len(set(opts)) != len(opts) or len(set(otexts)) != len(otexts):
            r.err(c, f"{sec} {rg}: duplicate option keys/texts")
        qs = g.get("questions", [])
        if t in COMPLETION:
            wl = g.get("word_limit")
            if not isinstance(wl, dict) or "max_words" not in wl:
                r.err("word_limit", f"{sec} {rg}: completion group needs word_limit")
                wl = {"max_words": 3, "numbers": True}
            stated = parse_limit_text(g.get("instructions", ""))
            if stated is None:
                r.err("word_limit", f"{sec} {rg}: instructions do not state a word limit")
            elif stated != (wl["max_words"], bool(wl.get("numbers"))):
                r.err("word_limit", f"{sec} {rg}: instructions say {stated}, word_limit says "
                                    f"{(wl['max_words'], bool(wl.get('numbers')))}")
            keys = []
            for q in qs:
                ans = q.get("answer")
                if not isinstance(ans, str) or not ans.strip():
                    r.err(c, f"{sec} Q{q.get('n')}: answer missing")
                    continue
                variants = [ans] + list(q.get("accept", []))
                for v in variants:
                    w, n = answer_counts(v)
                    if w > wl["max_words"] or (n and not wl.get("numbers")) or n > 1 or w + n == 0:
                        r.err("word_limit", f"{sec} Q{q['n']}: {v!r} breaks limit "
                                            f"{wl['max_words']} words{' + number' if wl.get('numbers') else ''}")
                ev = q.get("evidence", "")
                if not ev:
                    r.err(c, f"{sec} Q{q['n']}: evidence missing")
                elif norm_text(ev) not in src:
                    r.err(c, f"{sec} Q{q['n']}: evidence not found in text: {ev[:60]!r}")
                elif not any(norm_text(v) in norm_text(ev) or norm_text(v.replace(",", "")) in
                             norm_text(ev) for v in variants):
                    r.err(c, f"{sec} Q{q['n']}: answer {ans!r} not inside its evidence")
                if norm_text(ans) in norm_text(q.get("prompt", "").replace("{gap}", " ")):
                    r.err(c, f"{sec} Q{q['n']}: answer already printed in the prompt")
                keys.append(norm_answer(ans))
            if len(set(keys)) != len(keys):
                r.err(c, f"{sec} {rg}: two questions share the same answer")
        elif t in OPTION_SINGLE:
            per_q = t == "mcq_single" and qs and all(q.get("options") for q in qs)
            if len(opts) < 2 and not per_q:
                r.err(c, f"{sec} {rg}: option group needs options (mcq_single: on the group or on every question)")
            if t == "mcq_single":
                want = 3 if sec == "listening" else 4
                for q in qs:
                    qo = [o.get("key") for o in q.get("options", [])]
                    opts_q = qo or opts
                    qt = [norm_answer(o.get("text", "")) for o in q.get("options", [])]
                    if len(set(qo)) != len(qo) or len(set(qt)) != len(qt):
                        r.err(c, f"{sec} Q{q.get('n')}: duplicate option keys/texts")
                    if len(opts_q) != want:
                        r.warn(c, f"{sec} Q{q.get('n')}: mcq has {len(opts_q)} options (exam uses {want})")
                    if q.get("answer") not in opts_q:
                        r.err(c, f"{sec} Q{q.get('n')}: answer {q.get('answer')!r} not an option")
                    letter_counts[q.get("answer")] = letter_counts.get(q.get("answer"), 0) + 1
                    if not q.get("evidence"):
                        r.err(c, f"{sec} Q{q.get('n')}: evidence missing")
                    elif norm_text(q["evidence"]) not in src:
                        r.err(c, f"{sec} Q{q.get('n')}: evidence not found in text: {q['evidence'][:60]!r}")
                continue
            answers = []
            for q in qs:
                a = q.get("answer")
                if a not in opts:
                    r.err(c, f"{sec} Q{q.get('n')}: answer {a!r} not in options {opts}")
                answers.append(a)
                ev = q.get("evidence")
                if not ev:
                    r.err(c, f"{sec} Q{q.get('n')}: evidence missing")
                elif norm_text(ev) not in src:
                    r.err(c, f"{sec} Q{q.get('n')}: evidence not found in text: {ev[:60]!r}")
            reusable = g.get("options_reusable", t == "matching_information")
            if not reusable and len(set(answers)) != len(answers):
                r.err(c, f"{sec} {rg}: options not reusable but a letter is the answer twice")
            if t == "matching_headings":
                if len(opts) < len(qs) + 2:
                    r.err(c, f"{sec} {rg}: headings need at least 2 distractors")
            elif t in ("matching", "matching_sentence_endings", "summary_completion_box",
                       "map_labelling") and not reusable and len(opts) <= len(qs):
                r.err(c, f"{sec} {rg}: need more options than questions (distractors)")
        elif t in TFNG:
            vals = TFNG[t]
            for q in qs:
                a = q.get("answer")
                if a not in vals:
                    r.err(c, f"{sec} Q{q.get('n')}: answer must be one of {vals}")
                    continue
                tf_all.append(a)
                if a == "NOT GIVEN":
                    if not q.get("rationale"):
                        r.err(c, f"{sec} Q{q.get('n')}: NOT GIVEN needs rationale")
                    if q.get("evidence") and norm_text(q["evidence"]) not in src:
                        r.err(c, f"{sec} Q{q.get('n')}: evidence not found in text")
                else:
                    ev = q.get("evidence")
                    if not ev:
                        r.err(c, f"{sec} Q{q.get('n')}: evidence missing")
                    elif norm_text(ev) not in src:
                        r.err(c, f"{sec} Q{q.get('n')}: evidence not found in text: {ev[:60]!r}")
            got = {q.get("answer") for q in qs}
            if len(qs) >= 5 and got != set(vals):
                r.err(c, f"{sec} {rg}: {t} group of {len(qs)} should use all three answers")
            if len(qs) >= 3 and len(got) == 1:
                r.err(c, f"{sec} {rg}: all {t} answers identical")
        elif t == "mcq_multi":
            ch = g.get("choose")
            ans = g.get("answers", [])
            if ch not in (2, 3) or len(ans) != ch or len(qs) != ch:
                r.err(c, f"{sec} {rg}: mcq_multi needs choose 2|3, that many answers and questions")
            if len(set(ans)) != len(ans) or any(a not in opts for a in ans):
                r.err(c, f"{sec} {rg}: mcq_multi answers must be distinct options")
            if len(opts) < (ch or 2) + 2:
                r.err(c, f"{sec} {rg}: mcq_multi needs at least choose+2 options")
            for ev in g.get("evidence", []):
                if norm_text(ev) not in src:
                    r.err(c, f"{sec} {rg}: evidence not found in text: {ev[:60]!r}")
            if not g.get("evidence"):
                r.err(c, f"{sec} {rg}: mcq_multi group needs evidence list")
            if not g.get("prompt"):
                r.err(c, f"{sec} {rg}: mcq_multi group needs prompt")
    if tf_all:
        r.stats["tfng_mix"] = {k: tf_all.count(k) for k in sorted(set(tf_all))}
    if letter_counts:
        r.stats["mcq_letters"] = dict(sorted(letter_counts.items()))
        tot = sum(letter_counts.values())
        if tot >= 6 and max(letter_counts.values()) > 0.6 * tot:
            r.warn(c, f"mcq answers skewed to one letter: {letter_counts}")


def check_timing_and_level(b: dict, r: Result):
    lis = b.get("listening", {})
    total_s = 0.0
    lw = {}
    limits = {1: (380, 950), 2: (420, 1000), 3: (450, 1050), 4: (550, 1100)}
    for p in lis.get("parts", []):
        pn = p.get("part")
        n = len(words(listening_text(p)))
        lw[pn] = n
        lo, hi = limits.get(pn, (300, 1200))
        if not lo <= n <= hi:
            r.err("timing", f"listening part {pn}: script {n} words (need {lo}-{hi})")
        pauses = sum(t.get("pause", 0) for s in p.get("segments", []) for t in s.get("turns", []))
        prev = sum(s.get("preview_s", 0) for s in p.get("segments", []))
        total_s += n / WPM * 60 + pauses + prev + lis.get("check_s", 30) + 25   # +25 s narrator
    r.stats["listening_words"] = lw
    r.stats["listening_est_min"] = round(total_s / 60, 1)
    if lis.get("minutes") != 30:
        r.err("timing", "listening minutes must be 30")
    if not 20 <= total_s / 60 <= 40:
        r.err("timing", f"listening audio ≈{total_s / 60:.1f} min (need 20-40)")

    rd = b.get("reading", {})
    if rd.get("minutes") != 60:
        r.err("timing", "reading minutes must be 60")
    mod = b.get("module")
    rw = {}
    fre = {}
    for p in rd.get("parts", []):
        pn = p.get("part")
        txt = reading_text(p)
        n = len(words(txt))
        rw[pn] = n
        fre[pn] = round(flesch(txt), 1)
        if mod == "academic":
            lo, hi = 680, 1150
        else:
            lo, hi = {1: (350, 950), 2: (420, 1000), 3: (650, 1150)}.get(pn, (300, 1200))
        if not lo <= n <= hi:
            r.err("timing", f"reading part {pn}: {n} words (need {lo}-{hi})")
        if mod == "academic":
            if fre[pn] > 65:
                r.err("level", f"reading part {pn}: Flesch {fre[pn]} too easy for Academic (≤65)")
            elif not 15 <= fre[pn] <= 58:
                r.warn("level", f"reading part {pn}: Flesch {fre[pn]} outside typical 15-58")
        avg_sl = n / max(1, len(sentences(txt)))
        if not 10 <= avg_sl <= 34:
            r.warn("level", f"reading part {pn}: average sentence length {avg_sl:.1f} words")
        uniq = {w.lower() for w in words(txt)}
        long_share = sum(1 for w in words(txt) if len(w) >= 7) / max(1, n)
        r.stats.setdefault("reading_long_word_share", {})[pn] = round(long_share, 3)
        if mod == "academic" and long_share < 0.18:
            r.warn("level", f"reading part {pn}: few long words ({long_share:.2f}) for Academic")
        r.stats.setdefault("reading_types", {})[pn] = len(uniq)
    tot = sum(rw.values())
    if mod == "academic" and not 2150 <= tot <= 3300:
        r.err("timing", f"academic reading total {tot} words (need 2150-3300)")
    if mod == "general" and not 1800 <= tot <= 3000:
        r.err("timing", f"general reading total {tot} words (need 1800-3000)")
    if mod == "academic" and len(fre) == 3 and not fre[1] >= fre[3]:
        r.warn("level", f"academic passages should get harder 1→3 (Flesch {fre})")
    r.stats["reading_words"] = rw
    r.stats["reading_flesch"] = fre
    if lw:
        p4 = flesch(listening_text(lis["parts"][3])) if len(lis.get("parts", [])) == 4 else 0
        p1 = flesch(listening_text(lis["parts"][0])) if lis.get("parts") else 0
        r.stats["listening_flesch_p1_p4"] = [round(p1, 1), round(p4, 1)]
        if p4 and p1 and p4 > p1:
            r.warn("level", "listening part 4 lecture reads easier than part 1")

    wr = b.get("writing", {})
    tasks = wr.get("tasks", [])
    if wr.get("minutes") != 60 or [t.get("task") for t in tasks] != [1, 2]:
        r.err("timing", "writing: 60 minutes, tasks 1 and 2")
    for t in tasks:
        want = (20, 150) if t.get("task") == 1 else (40, 250)
        if (t.get("minutes"), t.get("min_words")) != want:
            r.err("timing", f"writing task {t.get('task')}: must be {want[0]} min / {want[1]} words")
        if not t.get("prompt") or not t.get("key_features"):
            r.err("format", f"writing task {t.get('task')}: prompt and key_features required")
        if str(want[1]) not in t.get("prompt", "") and t.get("task") == 2:
            r.err("format", "writing task 2 prompt must state 'at least 250 words'")
        ma = t.get("model_answer", {}).get("text", "")
        mw = len(words(ma))
        if mw < want[1]:
            r.err("timing", f"writing task {t.get('task')}: model answer {mw} words < {want[1]}")
        if t.get("task") == 1:
            if mod == "academic":
                if t.get("kind") != "chart" or not isinstance(t.get("visual"), dict):
                    r.err("format", "academic task 1 needs kind=chart and a visual")
            else:
                lt = t.get("letter", {})
                if t.get("kind") != "letter" or len(lt.get("bullets", [])) != 3 or \
                        lt.get("tone") not in ("formal", "semi-formal", "informal") or not lt.get("opening"):
                    r.err("format", "general task 1 needs kind=letter, tone, 3 bullets, opening")
        else:
            if t.get("essay_type") not in ("opinion", "discussion", "problem_solution",
                                           "advantages", "two_part"):
                r.err("format", "writing task 2 essay_type invalid")
    sp = b.get("speaking", {})
    p1 = sp.get("part1", [])
    if not (2 <= len(p1) <= 3 and all(3 <= len(t.get("questions", [])) <= 5 for t in p1)):
        r.err("format", "speaking part1: 2-3 topics with 3-5 questions each")
    p2 = sp.get("part2", {})
    cc = p2.get("cue_card", {})
    if not (cc.get("topic") and 3 <= len(cc.get("bullets", [])) <= 4 and cc.get("final")):
        r.err("format", "speaking part2 cue card: topic, 3-4 bullets, final 'and explain' line")
    if (p2.get("prep_s"), p2.get("talk_s")) != (60, 120):
        r.err("timing", "speaking part2: 60 s preparation, up to 120 s talk")
    p3 = sp.get("part3", [])
    if not (2 <= len(p3) <= 3 and all(3 <= len(t.get("questions", [])) <= 5 for t in p3)):
        r.err("format", "speaking part3: 2-3 themes with 3-5 questions each")
    if not 11 <= sp.get("minutes", 0) <= 14:
        r.err("timing", "speaking minutes must be 11-14")


def check_visuals(b: dict, r: Result):
    def one(v, where):
        k = v.get("kind")
        if k in ("line", "bar"):
            cats = v.get("categories", [])
            if not cats or not v.get("series"):
                r.err("format", f"{where}: chart needs categories and series")
            for s in v.get("series", []):
                if len(s.get("values", [])) != len(cats):
                    r.err("format", f"{where}: series {s.get('name')} length != categories")
        elif k == "pie":
            for ch in v.get("charts", []):
                tot = sum(s.get("value", 0) for s in ch.get("slices", []))
                if abs(tot - 100) > 0.6:
                    r.err("format", f"{where}: pie {ch.get('label')} sums to {tot}, not 100")
        elif k == "table":
            cols = v.get("columns", [])
            for row in v.get("rows", []):
                if len(row) != len(cols):
                    r.err("format", f"{where}: table row length != columns")
        elif k == "process":
            if len(v.get("steps", [])) < 4:
                r.err("format", f"{where}: process needs ≥4 steps")
        elif k == "map":
            for m in v.get("maps", [v]):
                if not m.get("areas"):
                    r.err("format", f"{where}: map needs areas")
        else:
            r.err("format", f"{where}: unknown visual kind {k!r}")
    for t in b.get("writing", {}).get("tasks", []):
        if isinstance(t.get("visual"), dict):
            one(t["visual"], f"writing task {t.get('task')}")
    for sec, p, g in iter_groups(b):
        if g.get("type") == "map_labelling":
            v = g.get("visual")
            if not isinstance(v, dict):
                r.err("format", f"{sec} {g.get('range')}: map_labelling needs a visual")
                continue
            one(v, f"{sec} {g.get('range')}")
            keys = {l.get("key") for l in v.get("labels", [])}
            if keys != {o.get("key") for o in g.get("options", [])}:
                r.err("format", f"{sec} {g.get('range')}: map label keys != options")


def check_copyright(b: dict, r: Result, known: set[str]):
    for label, text in bundle_texts(b):
        low = text.lower()
        for m in BANNED_MARKERS:
            if m in low:
                r.err("copyright", f"{label}: banned marker {m!r}")
        if known:
            hits = [sh for sh in shingles(text) if shingle_hash(sh) in known]
            if hits:
                r.err("copyright", f"{label}: {len(hits)} 8-word sequence(s) match known published "
                                   f"text, e.g. {hits[0]!r}")
    blob = json.dumps(b, ensure_ascii=False).lower()
    for m in ("cambridge ielts", "ucles", "©"):
        if m in blob:
            r.err("copyright", f"bundle mentions {m!r}")


def check_internal_duplicates(b: dict, r: Result):
    prompts = {}
    for sec, p, g in iter_groups(b):
        for q in g.get("questions", []):
            k = (sec, norm_answer(q.get("prompt", "")))
            if k[1] and k[1] != "{gap}":
                if k in prompts:
                    r.err("duplicates", f"{sec} Q{q.get('n')}: same prompt as Q{prompts[k]}")
                prompts[k] = q.get("n")


def check_cross_duplicates(results: dict, bundles: dict):
    sh = {}
    for path, b in bundles.items():
        s = set()
        for _, t in bundle_texts(b):
            s |= shingles(t)
        sh[path] = s
    long = {}
    for path, b in bundles.items():
        s = set()
        for _, t in bundle_texts(b):
            s |= shingles(t, 12)
        long[path] = s
    paths = sorted(bundles)
    for i, a in enumerate(paths):
        for bpath in paths[i + 1:]:
            inter = sh[a] & sh[bpath]
            j = len(inter) / max(1, len(sh[a] | sh[bpath]))
            ov12 = long[a] & long[bpath]
            for pth, other in ((a, bpath), (bpath, a)):
                if pth not in results:
                    continue
                if j > 0.03:
                    results[pth].err("duplicates", f"shares {j:.1%} of 8-word shingles with "
                                                   f"{os.path.basename(other)}")
                if ov12:
                    results[pth].err("duplicates", f"12-word overlap with {os.path.basename(other)}: "
                                                   f"{sorted(ov12)[0]!r}")
    # same reading titles / speaking cue cards across bundles
    seen: dict[str, str] = {}
    for path in paths:
        b = bundles[path]
        keys = [norm_answer(tx.get("title", "")) for p in b.get("reading", {}).get("parts", [])
                for tx in p.get("texts", [])]
        keys.append(norm_answer(b.get("speaking", {}).get("part2", {}).get("cue_card", {})
                                .get("topic", "")))
        keys += [writing_topic_key(t.get("prompt", "")) for t in b.get("writing", {}).get("tasks", [])]
        for k in keys:
            if not k:
                continue
            if k in seen and seen[k] != path and path in results:
                results[path].err("duplicates", f"topic/title repeated from "
                                                f"{os.path.basename(seen[k])}: {k[:60]!r}")
            seen.setdefault(k, path)


WRITING_BOILERPLATE = [
    r"summari[sz]e the information by selecting and reporting the main features,? and make comparisons where relevant\.?",
    r"write at least \d+ words\.?", r"you should spend about \d+ minutes on this task\.?",
    r"give reasons for your answer and include any relevant examples from your own knowledge or experience\.?",
    r"you do not need to write any addresses\.?", r"begin your letter as follows:?", r"dear sir or madam,?",
    r"to what extent do you agree or disagree\??", r"discuss both these views and give your own opinion\.?",
    r"in your letter,?"]


def writing_topic_key(prompt: str) -> str:
    """Topic of a writing prompt without the standard exam instruction lines (those repeat by design)."""
    s = norm_answer(prompt)
    for pat in WRITING_BOILERPLATE:
        s = re.sub(pat, " ", s)
    return re.sub(r"\s+", " ", s).strip()[:120]


def load_known() -> set[str]:
    try:
        with open(FINGERPRINTS, encoding="utf-8") as f:
            d = json.load(f)
        return set(d.get("hashes", []))
    except FileNotFoundError:
        return set()


def content_sha(b: dict) -> str:
    return hashlib.sha256(json.dumps(b, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def run(paths: list[str], all_paths: list[str]) -> tuple[dict, dict]:
    known = load_known()
    bundles = {}
    results = {}
    for p in sorted(set(all_paths) | set(paths)):
        r = Result(p)
        try:
            with open(p, encoding="utf-8") as f:
                bundles[p] = json.load(f)
        except Exception as e:  # noqa: BLE001
            r.err("format", f"invalid JSON: {e}")
        if p in paths:
            results[p] = r
    for p, r in results.items():
        b = bundles.get(p)
        if b is None:
            continue
        for fn in (check_format, check_listening_structure, check_answers,
                   check_timing_and_level, check_visuals, check_internal_duplicates):
            try:
                fn(b, r)
            except Exception as e:  # noqa: BLE001 (malformed input must not crash CI)
                r.err("format", f"{fn.__name__} crashed on malformed input: {e!r}")
        check_copyright(b, r, known)
    check_cross_duplicates(results, bundles)
    return results, bundles


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    all_paths = sorted(p for p in glob.glob(os.path.join(CONTENT_DIR, "*", "*.json"))
                       if re.fullmatch(r"ielts-(ac|gt)-\d{3}\.json", os.path.basename(p)))
    paths = [os.path.abspath(p) for p in a.files] or all_paths
    all_paths = [os.path.abspath(p) for p in all_paths]
    results, bundles = run(paths, all_paths)
    index = {"format": "assisto.lp.index/1", "bundles": []}
    lines = ["# Language Partner content check", ""]
    bad = 0
    for p, r in sorted(results.items()):
        b = bundles.get(p, {})
        ok = not r.errors
        bad += not ok
        index["bundles"].append({
            "bundle_id": b.get("bundle_id"), "file": os.path.relpath(p, os.path.dirname(os.path.dirname(HERE))),
            "module": b.get("module"), "version": b.get("version"),
            "status": "ai-checked" if ok else "draft", "checks_passed": ok,
            "content_sha256": content_sha(b) if b else None,
            "errors": r.errors, "warnings": r.warnings, "stats": r.stats})
        lines.append(f"## {os.path.basename(p)} — {'PASS (ai-checked)' if ok else 'FAIL'}")
        lines.append(f"stats: `{json.dumps(r.stats, ensure_ascii=False)}`")
        lines += [f"- ERROR {e}" for e in r.errors] + [f"- warn {w}" for w in r.warnings]
        lines.append("")
    lines.insert(1, f"{len(results) - bad}/{len(results)} bundles pass all checks.")
    report = "\n".join(lines)
    print(report)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "index.json"), "w", encoding="utf-8") as f:
            json.dump(index, f, ensure_ascii=False, indent=1)
        with open(os.path.join(a.out, "report.md"), "w", encoding="utf-8") as f:
            f.write(report + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
