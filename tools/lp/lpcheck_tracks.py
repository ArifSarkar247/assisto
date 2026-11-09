#!/usr/bin/env python3
"""Automatic checks for Language Partner track content (FORMAT.md §10 stage 2, §11 stage 3).

Stage 2: Japanese (JLPT N5, JFT-Basic), Korean (EPS-TOPIK), German (A1 visa level).
Stage 3: Chinese (HSK 1), French (A1, DELF-A1-style), Arabic for Middle East work (A1). All taught from Bangla.
Stdlib only; runs in CI (lp-content.yml), never needs an AI API.

    python3 tools/lp/lpcheck_tracks.py              # check every file under tools/lp/content/{ja,ko,de,zh,fr,ar}
    python3 tools/lp/lpcheck_tracks.py --out out/   # + out/tracks_index.json and out/tracks_report.md

Exit 1 when any file has an error. Files with no errors get status "ai-checked" in the index (git keeps
"draft"; human approval happens in Owner Admin; anything not human-approved shows a "beta" label).
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
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CONTENT_DIR = os.path.join(HERE, "content")
LANGS = ("ja", "ko", "de", "zh", "fr", "ar")
FINGERPRINTS = os.path.join(HERE, "fingerprints", "known_hashes.json")
LANGPACKS = os.path.join(REPO, "backend", "core", "data", "langpacks")

TRACKS = {"jlpt_n5": "ja", "jft_basic": "ja", "eps_topik": "ko", "de_a1": "de",
          "hsk1": "zh", "fr_a1": "fr", "ar_work": "ar"}
TEST_PREFIX = {"jlpt_n5": "jlpt-n5", "jft_basic": "jft-basic", "eps_topik": "eps-topik", "de_a1": "de-a1",
               "hsk1": "hsk1", "fr_a1": "fr-a1", "ar_work": "ar-work"}
LEVELS = {"jlpt_n5": "N5", "jft_basic": "A2", "eps_topik": "EPS", "de_a1": "A1",
          "hsk1": "HSK1", "fr_a1": "A1", "ar_work": "A1"}
COUNTRIES = {"JP", "KR", "DE", "ME", "CN", "FR"}
SKILLS = {"vocab", "kanji", "grammar", "expression", "detail", "gist", "info_search", "response",
          "number", "time", "place", "safety", "workplace", "culture", "spelling", "form", "message",
          "speaking"}
LETTERS = "ABCDEF"  # A–F: HSK 1 / DELF A1 matching parts use a shared bank of 6

# Public exam-format descriptions (structure only; no exam content):
#  JLPT N5 — jlpt.jp "Test Sections and Number of Questions" (N5: 20 + 40 + 30 min).
#  JFT-Basic — Japan Foundation test overview: 4 sections, about 50 questions, 60 minutes, CBT.
#  EPS-TOPIK — HRD Korea overview: reading 25 + listening 25 four-option questions, 40 + 30 min, 200 points.
#  German A1 — public Start Deutsch 1 format: Hören 3 parts/15 items ~20 min, Lesen 3 parts/15 items 25 min,
#              Schreiben 2 parts 20 min, Sprechen 3 parts ~15 min.
# part = (type, questions, options, repeat-for-listening)
BLUEPRINTS = {
    "jlpt_n5": {"total_minutes": 90, "sections": [
        {"id": "vocab", "kind": "vocab", "minutes": 20, "parts": [
            ("kanji_reading", 7, 4, None), ("orthography", 5, 4, None),
            ("contextual", 6, 4, None), ("paraphrase", 3, 4, None)]},
        {"id": "grammar_reading", "kind": "grammar_reading", "minutes": 40, "parts": [
            ("grammar_form", 9, 4, None), ("sentence_composition", 4, 4, None),
            ("text_grammar", 4, 4, None), ("short_passage", 2, 4, None),
            ("mid_passage", 2, 4, None), ("info_search", 1, 4, None)]},
        {"id": "listening", "kind": "listening", "minutes": 30, "parts": [
            ("task", 7, 4, 1), ("point", 6, 4, 1), ("utterance", 5, 3, 1),
            ("quick_response", 6, 3, 1)]}]},
    "jft_basic": {"total_minutes": 60, "sections": [
        {"id": "script_vocab", "kind": "vocab", "minutes": None, "parts": [
            ("word_meaning", 4, 4, None), ("word_usage", 2, 4, None),
            ("kanji_reading", 3, 4, None), ("kanji_usage", 3, 4, None)]},
        {"id": "conversation", "kind": "grammar_reading", "minutes": None, "parts": [
            ("grammar", 6, 4, None), ("expression", 6, 4, None)]},
        {"id": "listening", "kind": "listening", "minutes": None, "parts": [
            ("conversation", 4, 4, 1), ("announcement", 4, 4, 1), ("instruction", 4, 4, 1)]},
        {"id": "reading", "kind": "reading", "minutes": None, "parts": [
            ("content", 6, 4, None), ("info_search", 6, 4, None)]}]},
    "eps_topik": {"total_minutes": 70, "sections": [
        {"id": "reading", "kind": "reading", "minutes": 40, "parts": [
            ("vocab_choice", 6, 4, None), ("grammar_choice", 6, 4, None),
            ("sign_notice", 5, 4, None), ("short_text", 8, 4, None)]},
        {"id": "listening", "kind": "listening", "minutes": 30, "parts": [
            ("word_sentence", 6, 4, 2), ("response", 6, 4, 2),
            ("dialogue", 7, 4, 2), ("long_dialogue", 6, 4, 2)]}]},
    "de_a1": {"total_minutes": 80, "sections": [
        {"id": "hoeren", "kind": "listening", "minutes": 20, "parts": [
            ("teil1", 6, 3, 2), ("teil2", 4, 2, 1), ("teil3", 5, 3, 2)]},
        {"id": "lesen", "kind": "reading", "minutes": 25, "parts": [
            ("teil1", 5, 2, None), ("teil2", 5, 2, None), ("teil3", 5, 2, None)]},
        {"id": "schreiben", "kind": "writing", "minutes": 20, "tasks": 2},
        {"id": "sprechen", "kind": "speaking", "minutes": 15, "tasks": 3}]},
    # Stage 3 (FORMAT.md §11):
    #  HSK 1 — Chinese Testing International public HSK 1 description: listening 20 items (4 parts x 5,
    #          each recording played twice, about 15 min), reading 20 items (4 parts x 5, 17 min);
    #          200 points, 120 to pass; pinyin printed with the characters. Pictures become text options.
    #  French A1 — France Education international public DELF A1 description: oral comprehension
    #          ~20 min (recordings heard twice), written comprehension 30 min, written production 30 min
    #          (form + short message), oral production 3 parts (10 min preparation + 5-7 min); 4 x 25 points.
    #  Arabic for work (A1) — no single official exam: Assisto's own 4-skill A1 test built on the public
    #          CEFR A1 global scale; Gulf spoken + MSA workplace language; scripts heard twice.
    "hsk1": {"total_minutes": 32, "sections": [
        {"id": "listening", "kind": "listening", "minutes": 15, "parts": [
            ("picture_judge", 5, 2, 2), ("picture_choice", 5, 3, 2),
            ("dialogue_picture", 5, 6, 2), ("short_question", 5, 3, 2)]},
        {"id": "reading", "kind": "reading", "minutes": 17, "parts": [
            ("picture_judge", 5, 2, None), ("picture_match", 5, 6, None),
            ("qa_match", 5, 6, None), ("word_bank", 5, 6, None)]}]},
    "fr_a1": {"total_minutes": 97, "sections": [
        {"id": "oral", "kind": "listening", "minutes": 20, "parts": [
            ("ex1", 4, 3, 2), ("ex2", 4, 3, 2), ("ex3", 4, 3, 2), ("ex4", 5, 6, 2)]},
        {"id": "ecrit", "kind": "reading", "minutes": 30, "parts": [
            ("ex1", 4, 3, None), ("ex2", 4, 3, None), ("ex3", 4, 3, None), ("ex4", 5, 3, None)]},
        {"id": "production_ecrite", "kind": "writing", "minutes": 30, "tasks": 2},
        {"id": "production_orale", "kind": "speaking", "minutes": 17, "tasks": 3}]},
    "ar_work": {"total_minutes": 70, "sections": [
        {"id": "listening", "kind": "listening", "minutes": 20, "parts": [
            ("phrase", 6, 4, 2), ("dialogue", 8, 4, 2), ("instruction", 6, 4, 2)]},
        {"id": "reading", "kind": "reading", "minutes": 25, "parts": [
            ("letters", 6, 4, None), ("signs", 6, 4, None), ("messages", 8, 4, None)]},
        {"id": "writing", "kind": "writing", "minutes": 15, "tasks": 2},
        {"id": "speaking", "kind": "speaking", "minutes": 10, "tasks": 3}]},
}
# Free-text writing tasks must state a word limit (min_words/max_words; zh: max_chars) for these tracks.
WORD_LIMIT_TRACKS = {"fr_a1", "ar_work"}

BANNED = ["©", "all rights reserved", "past paper", "past question", "reproduced with permission",
          "過去問", "기출", "minna no nihongo", "みんなの日本語", "marugoto", "irodori",
          "sejong hakdang", "세종학당", "표준교재", "standard textbook",
          "menschen a1", "schritte international", "studio d", "goethe-institut",
          "goethe institut", "japan foundation", "国際交流基金", "hrd korea", "한국산업인력공단",
          "hsk标准教程", "标准教程", "hsk standard course", "汉语教程", "chinese testing international",
          "汉考国际", "真题", "france education international", "cnous", "alter ego", "édito a1", "edito a1",
          "cosmopolite", "écho a1", "al-kitaab", "al kitaab", "الكتاب في تعلم", "madinah arabic",
          "دروس اللغة العربية لغير الناطقين",
          "日本語能力試験公式", "official question", "অফিসিয়াল প্রশ্ন"]

# a marker must end at a word end ("studio d" = the German textbook, not French "studio de 20 m²")
BANNED_RE = {m: re.compile(re.escape(m) + (r"(?![^\W\d_])" if m[-1].isalpha() else "")) for m in BANNED}

# ~100 common N5 kanji (public lists vary slightly; used only for a WARNING on the N5 test).
N5_KANJI = set("一二三四五六七八九十百千万円日月火水木金土曜年時分半午前後今週毎何人男女子父母友"
               "先生学校大小中上下左右外国語本見行来出入休食飲書読話聞買言名山川田天気雨電車道駅"
               "店社会長高安新古白東西南北口目耳手足花魚空多少間")

SCRIPT_RE = {"ja": re.compile(r"[぀-ヿ一-鿿]"),
             "ko": re.compile(r"[가-힣]"),
             "de": re.compile(r"[A-Za-zÄÖÜäöüß]"),
             "zh": re.compile(r"[一-鿿]"),
             "fr": re.compile(r"[A-Za-zÀ-ÿŒœ]"),
             "ar": re.compile(r"[ء-ي]")}
FOREIGN_RE = {"ja": re.compile(r"[가-힣]"), "ko": re.compile(r"[぀-ヿ]"),
              "de": re.compile(r"[぀-ヿ一-鿿가-힣]"),
              "zh": re.compile(r"[぀-ヿ가-힣؀-ۿA-Za-z]"),  # pinyin goes in `roman`, never in `target`
              "fr": re.compile(r"[぀-ヿ一-鿿가-힣؀-ۿ]"),
              "ar": re.compile(r"[A-Za-z぀-ヿ一-鿿가-힣]")}  # transliteration goes in `roman`
# slow learner-exam speech: characters (ja/ko/zh) or words (de/fr/ar) per second
SPEECH_RATE = {"ja": 6.0, "ko": 4.5, "de": 2.0, "zh": 4.0, "fr": 2.2, "ar": 1.8}
WORD_LANGS = {"de", "fr", "ar"}

# --- stage 3 language rules -------------------------------------------------------------------
# Hanyu Pinyin with tone marks (citation tones; 一/不 may be written with their tone change).
TONE_MARKS = {}
for _tone, _chars in ((1, "āēīōūǖĀĒĪŌŪǕ"), (2, "áéíóúǘÁÉÍÓÚǗńŃ"), (3, "ǎěǐǒǔǚǍĚǏǑǓǙňŇ"), (4, "àèìòùǜÀÈÌÒÙǛǹǸ")):
    for _c in _chars:
        TONE_MARKS[_c] = _tone
PINYIN_OK = re.compile(r"[a-zA-ZüÜ" + "".join(TONE_MARKS) + r"\s0-9,.;:?!'’\-·…，。？！、“”\"()]+")
# characters that are usually toneless (neutral) — used only to soften the syllable-count check
NEUTRAL_HANZI = set("的了吗呢吧们子么个啊呀哦嘛儿头得着过地")
# common TRADITIONAL-only forms; Assisto teaches mainland simplified characters (HSK)
TRADITIONAL = set("們這說個來時會對學國東車門見長書買賣錢飯開關電話謝氣醫號點幾歲兒媽認識讀寫聽頭現邊誰師習"
                  "興歡鐘熱涼雞魚飛機場離遠還進廳業員樓禮銀問題愛覺嗎麼")
AR_REGISTERS = {"gulf", "msa", "both"}


def hanzi_count(s) -> int:
    return len(re.findall(r"[一-鿿]", str(s or "")))


def pinyin_tones(s) -> list[int]:
    return [TONE_MARKS[c] for c in unicodedata.normalize("NFC", str(s or "")) if c in TONE_MARKS]


def word_count(s) -> int:
    return len([w for w in str(s or "").split() if re.search(r"\w", w)])


def check_roman(r, lang: str, where: str, obj: dict, required: bool = True):
    """zh: pinyin with tone marks; ar: Latin transliteration. Checks `roman` against `target`."""
    if lang not in ("zh", "ar") or not isinstance(obj, dict):
        return
    tgt, rom = obj.get("target"), obj.get("roman")
    if not rom:
        if required:
            r.err("format", f"{where}: roman ({'pinyin' if lang == 'zh' else 'transliteration'}) required")
        return
    rom = unicodedata.normalize("NFC", str(rom))
    if lang == "ar":
        if re.search(r"[؀-ۿ]", rom) or has_bangla(rom):
            r.err("script", f"{where}: roman must be Latin transliteration")
        return
    if not PINYIN_OK.fullmatch(rom):
        bad = "".join(sorted({c for c in rom if not PINYIN_OK.fullmatch(c)}))
        r.err("tones", f"{where}: pinyin has characters that are not pinyin: {bad!r}")
        return
    n, marks = hanzi_count(tgt), len(pinyin_tones(rom))
    if re.search(r"[0-9]", str(tgt or "")):
        return  # Arabic digits read as one or more syllables
    if marks > n:
        r.err("tones", f"{where}: {marks} tone marks for {n} characters")
    neutral = sum(1 for c in str(tgt or "") if c in NEUTRAL_HANZI)
    if n and marks == 0 and neutral < n:
        r.err("tones", f"{where}: pinyin {rom[:30]!r} has no tone marks")
    elif marks < n - neutral - 2:
        r.warn("tones", f"{where}: only {marks} tone marks for {n} characters — check missing tones")


def check_lang_item(r, lang: str, where: str, obj: dict, vocab: bool = False):
    """Stage-3 per-item rules: pinyin/tones (zh), transliteration + Bangla pronunciation + register (ar)."""
    if lang == "zh":
        check_roman(r, lang, where, obj)
        trad = {c for c in str((obj or {}).get("target", "")) if c in TRADITIONAL}
        if trad:
            r.err("script", f"{where}: traditional characters {''.join(sorted(trad))} — use simplified")
        if vocab:
            tones = obj.get("tones")
            tgt = str(obj.get("target", ""))
            if not isinstance(tones, list) or any(t not in (0, 1, 2, 3, 4) for t in tones):
                r.err("tones", f"{where}: tones must be a list of 0–4 (0 = neutral), one per character")
            elif len(tones) != hanzi_count(tgt):
                r.err("tones", f"{where}: {len(tones)} tones for {hanzi_count(tgt)} characters")
            elif [t for t in tones if t] != pinyin_tones(obj.get("roman")):
                r.err("tones", f"{where}: tones {tones} do not match pinyin {obj.get('roman')!r}")
    elif lang == "ar":
        check_roman(r, lang, where, obj)
        if vocab:
            if not has_bangla(obj.get("bn_pron")):
                r.err("format", f"{where}: bn_pron (Bangla-script pronunciation) required")
            if obj.get("register") not in AR_REGISTERS:
                r.err("format", f"{where}: register must be one of {sorted(AR_REGISTERS)}")


def check_aux_roman(r, lang: str, where: str, q: dict):
    """zh: HSK 1–2 print pinyin with the characters, so Chinese prompts/passages/options carry
    `prompt_roman` / `passage_roman` / `options_roman` (pinyin). ar: optional, checked when present."""
    if lang not in ("zh", "ar"):
        return
    need = lang == "zh"
    for k in ("prompt", "passage"):
        v = q.get(k)
        if isinstance(v, str) and SCRIPT_RE[lang].search(v):
            check_roman(r, lang, f"{where} {k}", {"target": v, "roman": q.get(k + "_roman")},
                        required=need)
    opts = q.get("options") or []
    target_opts = [i for i, o in enumerate(opts) if not has_bangla(o)]
    orom = q.get("options_roman")
    if not target_opts or (orom is None and not need):
        return
    if not isinstance(orom, list) or len(orom) != len(opts):
        r.err("format", f"{where}: options_roman must list one entry per option")
        return
    for i in target_opts:
        check_roman(r, lang, f"{where} option {LETTERS[i]}", {"target": opts[i], "roman": orom[i]})


def check_word_limit(r, lang: str, where: str, item: dict, text, required: bool):
    """Writing word limits: min_words/max_words (word languages) or max_chars (zh) bound the model answer."""
    lo, hi, mc = item.get("min_words"), item.get("max_words"), item.get("max_chars")
    if lang == "zh":
        if mc is not None and hanzi_count(text) > int(mc):
            r.err("word_limit", f"{where}: model has {hanzi_count(text)} characters > max_chars {mc}")
        return
    if lo is None and hi is None:
        if required:
            r.err("word_limit", f"{where}: free-text writing needs min_words/max_words")
        return
    n = word_count(text)
    if lo is not None and hi is not None and int(lo) > int(hi):
        r.err("word_limit", f"{where}: min_words > max_words")
    if lo is not None and n < int(lo):
        r.err("word_limit", f"{where}: model has {n} words < min_words {lo}")
    if hi is not None and n > int(hi):
        r.err("word_limit", f"{where}: model has {n} words > max_words {hi}")


def has_bangla(s) -> bool:
    return bool(re.search(r"[ঀ-৿]", str(s or "")))


def norm(s) -> str:
    s = unicodedata.normalize("NFKC", str(s or "")).lower()
    return re.sub(r"[\s\W_]+", "", s)


def char_grams(s: str, k: int = 12) -> set[str]:
    t = norm(s)
    return {t[i:i + k] for i in range(0, max(0, len(t) - k + 1))}


def word_shingles(text: str, k: int = 8) -> set[str]:
    s = unicodedata.normalize("NFKC", str(text)).lower()
    toks = re.sub(r"[^0-9a-zà-ɏß]+", " ", s).split()
    return {" ".join(toks[i:i + k]) for i in range(0, max(0, len(toks) - k + 1))}


def script_len(lang: str, script: dict) -> float:
    """Estimated seconds to speak one play of a script."""
    secs = 0.0
    for t in script.get("turns", []):
        if "pause" in t:
            secs += float(t.get("pause") or 0)
        elif lang in WORD_LANGS:
            secs += len(str(t.get("text", "")).split()) / SPEECH_RATE[lang] + 0.6
        else:
            secs += len(norm(t.get("text", ""))) / SPEECH_RATE[lang] + 0.6
    return secs


class Result:
    def __init__(self, path: str):
        self.path = path
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.stats: dict = {}

    def err(self, check, msg):
        self.errors.append(f"[{check}] {msg}")

    def warn(self, check, msg):
        self.warnings.append(f"[{check}] {msg}")


# ---------------------------------------------------------------------------- common

def check_common(d: dict, r: Result, fmt: str, lang: str):
    if d.get("format") != fmt:
        r.err("format", f"format must be {fmt!r}")
    if d.get("lang") != lang:
        r.err("format", f"lang must be {lang!r} (folder)")
    if not isinstance(d.get("version"), int) or d.get("version", 0) < 1:
        r.err("format", "version must be an int >= 1")
    if d.get("status") != "draft":
        r.err("format", "status in git must be 'draft' (CI index promotes)")
    for k in ("title", "practice_label"):
        v = d.get(k)
        if not isinstance(v, dict) or not v.get("en") or not v.get("bn"):
            r.err("bilingual", f"{k} needs en + bn")
        elif not has_bangla(v["bn"]):
            r.err("bilingual", f"{k}.bn is not Bangla script")
    pl = d.get("practice_label") or {}
    en, bn = str(pl.get("en", "")).lower(), str(pl.get("bn", ""))
    if "practice" not in en or "not" not in en or "official" not in en:
        r.err("label", "practice_label.en must say practice + not official")
    if ("অনুশীলন" not in bn and "প্র্যাকটিস" not in bn) or "নয়" not in bn:
        r.err("label", "practice_label.bn must say অনুশীলন/প্র্যাকটিস + নয়")
    t = d.get("title") or {}
    if "official" in str(t.get("en", "")).lower() or "অফিসিয়াল" in str(t.get("bn", "")):
        r.err("label", "title must never claim official status")
    a = d.get("authoring") or {}
    if a.get("source") != "original":
        r.err("copyright", "authoring.source must be 'original'")
    if not a.get("format_source"):
        r.err("copyright", "authoring.format_source must name the public format description")


def texts_of(d) -> list[str]:
    """Every string value in a JSON tree (for copyright markers)."""
    out = []
    if isinstance(d, dict):
        for k, v in d.items():
            if k in ("authoring", "official_info_bn"):
                continue
            out += texts_of(v)
    elif isinstance(d, list):
        for v in d:
            out += texts_of(v)
    elif isinstance(d, str):
        out.append(d)
    return out


def check_copyright(d: dict, r: Result, known: set[str]):
    for s in texts_of(d):
        low = s.lower()
        for m in BANNED:
            if m in low and BANNED_RE[m].search(low):
                r.err("copyright", f"banned marker {m!r} in {s[:50]!r}")
        if known:
            for sh in word_shingles(s):
                if hashlib.sha256(sh.encode()).hexdigest()[:24] in known:
                    r.err("copyright", f"8-word sequence matches known published text: {sh!r}")
                    break


def check_bn(r: Result, where: str, s, required=True):
    if not s:
        if required:
            r.err("bilingual", f"{where}: missing Bangla text")
        return
    if not has_bangla(s):
        r.err("bilingual", f"{where}: not Bangla script")


def check_target(r: Result, lang: str, where: str, s):
    s = str(s or "")
    if not s.strip():
        r.err("format", f"{where}: empty target-language text")
        return
    if not SCRIPT_RE[lang].search(s):
        r.err("script", f"{where}: no {lang} script in {s[:40]!r}")
    if FOREIGN_RE[lang].search(s):
        r.err("script", f"{where}: wrong-language script in {s[:40]!r}")
    if has_bangla(s):
        r.err("script", f"{where}: Bangla inside target-language text {s[:40]!r}")


def check_mcq(r: Result, where: str, q: dict, n_opts: int | None = None):
    opts = q.get("options")
    if not isinstance(opts, list) or len(opts) < 2:
        r.err("format", f"{where}: options missing")
        return
    if n_opts and len(opts) != n_opts:
        r.err("format", f"{where}: {len(opts)} options, exam format needs {n_opts}")
    if any(not str(o).strip() for o in opts):
        r.err("answer", f"{where}: empty option")
    if len({norm(o) for o in opts}) != len(opts):
        r.err("answer", f"{where}: options not distinct")
    a = q.get("answer")
    if not isinstance(a, str) or len(a) != 1 or a not in LETTERS[:len(opts)]:
        r.err("answer", f"{where}: answer must be one letter A..{LETTERS[len(opts) - 1]}")
    check_bn(r, f"{where}.explain_bn", q.get("explain_bn"))
    if q.get("skill") not in SKILLS:
        r.err("format", f"{where}: skill {q.get('skill')!r} not in list")


def check_script(r: Result, lang: str, where: str, sc, repeat=None):
    if not isinstance(sc, dict) or not sc.get("turns"):
        r.err("listening", f"{where}: listening question needs script.turns")
        return
    spk = sc.get("speakers") or {}
    if not spk:
        r.err("listening", f"{where}: script.speakers missing")
    for sid, s in spk.items():
        if s.get("gender") not in ("F", "M"):
            r.err("listening", f"{where}: speaker {sid} gender must be F/M")
    for i, t in enumerate(sc["turns"]):
        if "pause" in t:
            if not 0.2 <= float(t["pause"] or 0) <= 5:
                r.err("listening", f"{where}: pause out of 0.2–5 s")
            continue
        if t.get("spk") not in spk:
            r.err("listening", f"{where}: turn {i} speaker {t.get('spk')!r} not declared")
        check_target(r, lang, f"{where} turn {i}", t.get("text"))
    if repeat is not None and sc.get("repeat") != repeat:
        r.err("listening", f"{where}: script.repeat must be {repeat} (exam rule)")


# ---------------------------------------------------------------------------- tests

def check_test(d: dict, r: Result, lang: str, fname: str):
    check_common(d, r, "assisto.lp.test/1", lang)
    track = d.get("track")
    if TRACKS.get(track) != lang:
        r.err("format", f"track {track!r} invalid for lang {lang}")
        return
    bid = d.get("bundle_id", "")
    if not re.fullmatch(TEST_PREFIX[track] + r"-\d{3}", bid) or fname != bid + ".json":
        r.err("format", f"bundle_id {bid!r} must be {TEST_PREFIX[track]}-NNN and equal the file name")
    sc = d.get("scoring") or {}
    if not sc.get("max") or not has_bangla(sc.get("note_bn")):
        r.err("format", "scoring.max and scoring.note_bn (practice, not official) required")
    elif "নয়" not in sc.get("note_bn", ""):
        r.err("label", "scoring.note_bn must say the score is not official (…নয়)")
    bp = BLUEPRINTS[track]
    secs = d.get("sections") or []
    if [s.get("id") for s in secs] != [s["id"] for s in bp["sections"]]:
        r.err("format", f"sections must be {[s['id'] for s in bp['sections']]} in order")
        return
    total_min = sum(int(s.get("minutes") or 0) for s in secs)
    if total_min != bp["total_minutes"]:
        r.err("timing", f"total minutes {total_min} != {bp['total_minutes']}")
    n_expect = 1
    letters = Counter()
    seen_prompts = {}
    q_total = 0
    for s, sb in zip(secs, bp["sections"]):
        sid = s["id"]
        if s.get("kind") != sb["kind"]:
            r.err("format", f"{sid}: kind must be {sb['kind']}")
        if sb["minutes"] is not None and s.get("minutes") != sb["minutes"]:
            r.err("timing", f"{sid}: minutes {s.get('minutes')} != {sb['minutes']}")
        t = s.get("title") or {}
        if not t.get("en") or not has_bangla(t.get("bn")):
            r.err("bilingual", f"{sid}: title needs en + bn")
        if "tasks" in sb:
            check_tasks(d, r, lang, s, sb)
            continue
        parts = s.get("parts") or []
        if [p.get("type") for p in parts] != [p[0] for p in sb["parts"]]:
            r.err("format", f"{sid}: part types must be {[p[0] for p in sb['parts']]}")
            continue
        listen_s = 0.0
        sec_letters = Counter()
        for p, (ptype, count, nopt, rep) in zip(parts, sb["parts"]):
            ins = p.get("instructions") or {}
            check_bn(r, f"{sid}/{ptype} instructions.bn", ins.get("bn"))
            if ins.get("target"):
                check_target(r, lang, f"{sid}/{ptype} instructions.target", ins["target"])
            if p.get("passage"):
                check_target(r, lang, f"{sid}/{ptype} passage", p["passage"])
                check_aux_roman(r, lang, f"{sid}/{ptype}", p)
            qs = p.get("questions") or []
            if len(qs) != count:
                r.err("format", f"{sid}/{ptype}: {len(qs)} questions, format needs {count}")
            for q in qs:
                where = f"{sid}/{ptype} Q{q.get('n')}"
                if q.get("n") != n_expect:
                    r.err("format", f"{where}: numbering must continue at {n_expect}")
                    n_expect = q.get("n") if isinstance(q.get("n"), int) else n_expect
                n_expect += 1
                q_total += 1
                check_mcq(r, where, q, nopt)
                if q.get("answer") in LETTERS:
                    letters[q["answer"]] += 1
                    sec_letters[q["answer"]] += 1
                if q.get("passage"):
                    check_target(r, lang, f"{where} passage", q["passage"])
                for i, o in enumerate(q.get("options") or []):
                    if not has_bangla(o):
                        check_target(r, lang, f"{where} option {LETTERS[i] if i < len(LETTERS) else i}", o)
                check_aux_roman(r, lang, where, q)
                if sb["kind"] == "listening":
                    check_script(r, lang, where, q.get("script"), rep)
                    if isinstance(q.get("script"), dict):
                        listen_s += script_len(lang, q["script"]) * (rep or 1) + 12
                elif "script" in q:
                    r.err("format", f"{where}: script only allowed in listening")
                elif not (q.get("prompt") or q.get("passage") or p.get("passage")):
                    r.err("format", f"{where}: needs prompt or passage")
                key = norm(str(q.get("prompt", "")) + str(q.get("passage", "")) +
                           json.dumps(q.get("script", ""), ensure_ascii=False))
                if len(key) >= 6:
                    if key in seen_prompts:
                        r.err("duplicates", f"{where}: same question as Q{seen_prompts[key]}")
                    seen_prompts[key] = q.get("n")
            if track == "jlpt_n5" and sb["kind"] != "listening":
                extra = {c for q in qs for c in str(q.get("prompt", "")) + "".join(map(str, q.get("options") or []))
                         if "一" <= c <= "鿿"} - N5_KANJI
                if extra:
                    r.warn("level", f"{sid}/{ptype}: kanji beyond the common N5 list: {''.join(sorted(extra))}")
        if sb["kind"] == "listening" and s.get("minutes"):
            r.stats[f"{sid}_audio_min"] = round(listen_s / 60, 1)
            if listen_s > s["minutes"] * 60:
                r.err("timing", f"{sid}: estimated audio {listen_s / 60:.1f} min > {s['minutes']} min")
        tot = sum(sec_letters.values())
        if tot >= 6:
            top, c = sec_letters.most_common(1)[0]
            if c == tot:
                r.err("answer", f"{sid}: every answer is {top}")
            elif c / tot > 0.5:
                r.warn("answer", f"{sid}: {c}/{tot} answers are {top}")
    r.stats["questions"] = q_total
    r.stats["answer_letters"] = dict(sorted(letters.items()))


def check_tasks(d, r: Result, lang: str, s: dict, sb: dict):
    tasks = s.get("tasks") or []
    if len(tasks) != sb["tasks"]:
        r.err("format", f"{s['id']}: {len(tasks)} tasks, format needs {sb['tasks']}")
    for i, t in enumerate(tasks):
        where = f"{s['id']} task {i + 1}"
        pr = t.get("prompt") or {}
        check_target(r, lang, f"{where} prompt.target", pr.get("target"))
        check_bn(r, f"{where} prompt.bn", pr.get("bn"))
        if not t.get("points"):
            r.err("format", f"{where}: points required")
        m = t.get("model") or {}
        check_target(r, lang, f"{where} model.target", m.get("target"))
        check_bn(r, f"{where} model.bn", m.get("bn"))
        check_lang_item(r, lang, f"{where} model", m)
        if s.get("kind") == "writing":
            check_word_limit(r, lang, where, t, m.get("target"),
                             required=d.get("track") in WORD_LIMIT_TRACKS and not t.get("fields"))
        for j, f in enumerate(t.get("fields") or []):
            if not f.get("label") or not str(f.get("answer", "")).strip():
                r.err("answer", f"{where} field {j + 1}: label + answer required")


# ---------------------------------------------------------------------------- lessons

def check_lessons(d: dict, r: Result, lang: str, fname: str, lesson_ids: dict):
    check_common(d, r, "assisto.lp.lessons/1", lang)
    wk = d.get("week")
    if not isinstance(wk, int) or fname != f"lessons-{lang}-w{wk:02d}.json":
        r.err("format", f"week {wk!r} must match the file name lessons-{lang}-wNN.json")
    trs = d.get("tracks") or []
    if not trs or any(TRACKS.get(t) != lang for t in trs):
        r.err("format", f"tracks {trs!r} invalid for {lang}")
    ls = d.get("lessons") or []
    if len(ls) != 5:
        r.err("format", f"{len(ls)} lessons; a week has 5")
    nv = ng = npr = 0
    seen = {}
    for li, l in enumerate(ls):
        lid = l.get("id", "")
        where = lid or f"lesson {li + 1}"
        if not re.fullmatch(rf"{lang}-w{wk:02d}-l{li + 1}" if isinstance(wk, int) else "x", lid):
            r.err("format", f"{where}: id must be {lang}-w{wk:02d}-l{li + 1}" if isinstance(wk, int) else "bad week")
        if lid in lesson_ids and lesson_ids[lid] != r.path:
            r.err("duplicates", f"{where}: id also in {os.path.basename(lesson_ids[lid])}")
        lesson_ids.setdefault(lid, r.path)
        t = l.get("title") or {}
        if not t.get("en") or not has_bangla(t.get("bn")):
            r.err("bilingual", f"{where}: title needs en + bn")
        check_bn(r, f"{where}.goal_bn", l.get("goal_bn"))
        voc = l.get("vocab") or []
        if len(voc) < 6:
            r.err("format", f"{where}: {len(voc)} vocab, need >= 6")
        for vi, v in enumerate(voc):
            w = f"{where} vocab {vi + 1}"
            check_target(r, lang, w, v.get("target"))
            check_bn(r, f"{w}.bn", v.get("bn"))
            if lang in ("ja", "ko") and not v.get("roman"):
                r.err("format", f"{w}: roman required")
            check_lang_item(r, lang, w, v, vocab=True)
            if lang == "ja" and not re.fullmatch(r"[぀-ヿー・\s〜～。、！？]+", str(v.get("kana", ""))):
                r.err("format", f"{w}: kana reading (hiragana/katakana only) required")
            ex = v.get("example") or {}
            check_target(r, lang, f"{w} example", ex.get("target"))
            check_bn(r, f"{w} example.bn", ex.get("bn"))
            if lang in ("ja", "ko") and not ex.get("roman"):
                r.err("format", f"{w} example: roman required")
            check_lang_item(r, lang, f"{w} example", ex)
            k = norm(v.get("target"))
            if k in seen:
                r.warn("duplicates", f"{w}: {v.get('target')!r} already taught in {seen[k]}")
            seen[k] = where
        nv += len(voc)
        gr = l.get("grammar") or []
        if not gr:
            r.err("format", f"{where}: needs >= 1 grammar point")
        for gi, g in enumerate(gr):
            w = f"{where} grammar {gi + 1}"
            if not g.get("pattern"):
                r.err("format", f"{w}: pattern required")
            check_bn(r, f"{w}.explain_bn", g.get("explain_bn"))
            exs = g.get("examples") or []
            if not exs:
                r.err("format", f"{w}: examples required")
            for e in exs:
                check_target(r, lang, f"{w} example", e.get("target"))
                check_bn(r, f"{w} example.bn", e.get("bn"))
                check_lang_item(r, lang, f"{w} example", e)
        ng += len(gr)
        pr = l.get("practice") or {}
        for skill in ("listening", "reading", "writing", "speaking"):
            items = pr.get(skill) or []
            if not items:
                r.err("format", f"{where}: practice.{skill} needs >= 1 item")
            for it in items:
                w = f"{where} {skill} {it.get('id')}"
                if not str(it.get("id", "")).startswith(lid + "-"):
                    r.err("format", f"{w}: id must start with {lid}-")
                check_bn(r, f"{w}.prompt_bn", it.get("prompt_bn"))
                npr += 1
                if skill in ("listening", "reading"):
                    check_mcq(r, w, it)
                    for i, o in enumerate(it.get("options") or []):
                        if not has_bangla(o):
                            check_target(r, lang, f"{w} option {i + 1}", o)
                    if skill == "listening":
                        check_script(r, lang, w, it.get("script"))
                    else:
                        check_target(r, lang, f"{w} passage", it.get("passage"))
                    check_aux_roman(r, lang, w, it)
                else:
                    m = it.get("model") or {}
                    check_target(r, lang, f"{w} model", m.get("target"))
                    check_bn(r, f"{w} model.bn", m.get("bn"))
                    check_lang_item(r, lang, f"{w} model", m)
                    if skill == "writing":
                        check_word_limit(r, lang, w, it, m.get("target"), required=False)
                    if skill == "writing" and it.get("check") not in ("ai", "self"):
                        r.err("format", f"{w}: check must be ai|self")
    r.stats.update({"lessons": len(ls), "vocab": nv, "grammar": ng, "practice_items": npr})


# ---------------------------------------------------------------------------- syllabus

def check_syllabus(d: dict, r: Result, lang: str, fname: str, lesson_ids: dict):
    check_common(d, r, "assisto.lp.syllabus/1", lang)
    track = d.get("track")
    if TRACKS.get(track) != lang or fname != f"syllabus-{track}.json":
        r.err("format", f"track {track!r} invalid or file name not syllabus-<track>.json")
        return
    if d.get("level") != LEVELS[track]:
        r.err("format", f"level must be {LEVELS[track]}")
    for k in ("summary_bn", "who_for_bn"):
        check_bn(r, k, d.get(k))
    cd = d.get("can_do_bn") or []
    if len(cd) < 3:
        r.err("format", "can_do_bn needs >= 3 lines")
    for c in cd:
        check_bn(r, "can_do_bn", c)
    ef = d.get("exam_format") or {}
    bp = BLUEPRINTS[track]
    if ef.get("total_minutes") != bp["total_minutes"]:
        r.err("timing", f"exam_format.total_minutes must be {bp['total_minutes']}")
    if [s.get("id") for s in ef.get("sections", [])] != [s["id"] for s in bp["sections"]]:
        r.err("format", "exam_format.sections must match the blueprint ids")
    for s, sb in zip(ef.get("sections", []), bp["sections"]):
        want = sum(p[1] for p in sb.get("parts", [])) or sb.get("tasks")
        if s.get("questions") != want:
            r.err("format", f"exam_format {s.get('id')}: questions must be {want}")
        if not has_bangla((s.get("title") or {}).get("bn")):
            r.err("bilingual", f"exam_format {s.get('id')}: title.bn")
    check_bn(r, "exam_format.scoring_bn", ef.get("scoring_bn"))
    check_bn(r, "exam_format.official_info_bn", ef.get("official_info_bn"))
    weeks = d.get("weeks") or []
    nums = [w.get("week") for w in weeks]
    if nums[:4] != [1, 2, 3, 4]:
        r.err("format", "weeks 1–4 required first")
    for w in weeks:
        check_bn(r, f"week {w.get('week')} goal_bn", w.get("goal_bn"))
        if w.get("planned"):
            continue
        if not w.get("lessons"):
            r.err("format", f"week {w.get('week')}: lessons required (or planned: true)")
        for lid in w.get("lessons") or []:
            if lid not in lesson_ids:
                r.err("format", f"week {w.get('week')}: lesson {lid!r} not found")
    pb = d.get("probashi") or {}
    if pb.get("country") not in COUNTRIES:
        r.err("format", f"probashi.country must be one of {sorted(COUNTRIES)}")
    wpl = pb.get("work_path_lang")
    if wpl is not None:
        try:
            with open(os.path.join(LANGPACKS, f"{wpl}.json"), encoding="utf-8") as f:
                if "work_path" not in json.load(f):
                    r.err("format", f"langpack {wpl} has no work_path")
        except FileNotFoundError:
            r.err("format", f"probashi.work_path_lang {wpl!r}: no langpack")
    check_bn(r, "probashi.note_bn", pb.get("note_bn"))
    r.stats["weeks"] = len(weeks)


# ---------------------------------------------------------------------------- cross-file

def content_texts(kind: str, d: dict) -> list[str]:
    """Authored target-language content (not labels/instructions, which repeat by design)."""
    out = []
    if kind == "test":
        for s in d.get("sections") or []:
            for p in s.get("parts") or []:
                out.append(p.get("passage", ""))
                for q in p.get("questions") or []:
                    out += [q.get("prompt", ""), q.get("passage", "")]
                    out += [t.get("text", "") for t in (q.get("script") or {}).get("turns", [])]
            for t in s.get("tasks") or []:
                out += [(t.get("prompt") or {}).get("target", ""), (t.get("model") or {}).get("target", "")]
    elif kind == "lessons":
        for l in d.get("lessons") or []:
            for v in l.get("vocab") or []:
                out.append((v.get("example") or {}).get("target", ""))
            for g in l.get("grammar") or []:
                out += [e.get("target", "") for e in g.get("examples") or []]
            for items in (l.get("practice") or {}).values():
                for it in items:
                    out += [it.get("passage", ""), (it.get("model") or {}).get("target", "")]
                    out += [t.get("text", "") for t in (it.get("script") or {}).get("turns", [])]
    return [str(t) for t in out if len(norm(t)) >= 24 and not has_bangla(t)]


def long_texts(d) -> list[str]:
    return [s for s in texts_of(d) if len(norm(s)) >= 24 and not has_bangla(s)]


def langpack_texts(lang: str) -> list[str]:
    try:
        with open(os.path.join(LANGPACKS, f"{lang}.json"), encoding="utf-8") as f:
            return long_texts(json.load(f))
    except (FileNotFoundError, ValueError):
        return []


def check_cross(results: dict, docs: dict):
    """Tests must not reuse long target-language texts from other tests, lessons or the old packs."""
    by_lang: dict[str, list] = {}
    for p, (kind, lang, d) in docs.items():
        by_lang.setdefault(lang, []).append(p)
    for lang, paths in by_lang.items():
        owner: dict[str, str] = {}
        for t in langpack_texts(lang):
            owner.setdefault(norm(t), f"langpacks/{lang}.json")
        for p in sorted(paths):
            kind, _, d = docs[p]
            for t in content_texts(kind, d):
                k = norm(t)
                o = owner.get(k)
                if o and o != os.path.basename(p) and p in results:
                    msg = f"text reused from {o}: {t[:40]!r}"
                    if kind == "test" and not o.startswith("lessons-"):
                        results[p].err("duplicates", msg)
                    else:
                        results[p].warn("duplicates", msg)
                owner.setdefault(k, os.path.basename(p))
        tests = [p for p in paths if docs[p][0] == "test"]
        grams = {p: set().union(*[char_grams(t) for t in content_texts("test", docs[p][2])] or [set()])
                 for p in tests}
        for i, a in enumerate(tests):
            for b in tests[i + 1:]:
                inter = grams[a] & grams[b]
                j = len(inter) / max(1, len(grams[a] | grams[b]))
                if j > 0.08:
                    for x, y in ((a, b), (b, a)):
                        if x in results:
                            results[x].err("duplicates", f"{j:.0%} 12-char overlap with {os.path.basename(y)}")


def load_known() -> set[str]:
    try:
        with open(FINGERPRINTS, encoding="utf-8") as f:
            return set(json.load(f).get("hashes", []))
    except FileNotFoundError:
        return set()


def classify(fname: str) -> str | None:
    if fname.startswith("syllabus-"):
        return "syllabus"
    if fname.startswith("lessons-"):
        return "lessons"
    if re.fullmatch(r"(jlpt-n5|jft-basic|eps-topik|de-a1|hsk1|fr-a1|ar-work)-\d{3}\.json", fname):
        return "test"
    return None


def collect() -> list[str]:
    out = []
    for lang in LANGS:
        out += sorted(glob.glob(os.path.join(CONTENT_DIR, lang, "*.json")))
    return out


def run(paths: list[str]) -> tuple[dict, dict]:
    known = load_known()
    docs, results = {}, {}
    for p in paths:
        r = Result(p)
        results[p] = r
        lang = os.path.basename(os.path.dirname(p))
        kind = classify(os.path.basename(p))
        if lang not in LANGS or kind is None:
            r.err("format", "unknown file (expected syllabus-/lessons-/<test-id>.json under ja|ko|de|zh|fr|ar)")
            continue
        try:
            with open(p, encoding="utf-8") as f:
                docs[p] = (kind, lang, json.load(f))
        except Exception as e:  # noqa: BLE001
            r.err("format", f"invalid JSON: {e}")
    lesson_ids: dict[str, str] = {}
    order = sorted(docs, key=lambda p: {"lessons": 0, "test": 1, "syllabus": 2}[docs[p][0]])
    for p in order:
        kind, lang, d = docs[p]
        r = results[p]
        fname = os.path.basename(p)
        fn = {"lessons": lambda: check_lessons(d, r, lang, fname, lesson_ids),
              "test": lambda: check_test(d, r, lang, fname),
              "syllabus": lambda: check_syllabus(d, r, lang, fname, lesson_ids)}[kind]
        try:
            fn()
        except Exception as e:  # noqa: BLE001 (malformed input must not crash CI)
            r.err("format", f"check crashed on malformed input: {e!r}")
        check_copyright(d, r, known)
    check_cross(results, docs)
    return results, docs


def content_sha(d) -> str:
    return hashlib.sha256(json.dumps(d, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    paths = collect()
    results, docs = run(paths)
    index = {"format": "assisto.lp.tracks_index/1", "files": []}
    lines = ["# Language Partner track check (stage 2 + stage 3)", ""]
    bad = 0
    for p, r in sorted(results.items()):
        kind, lang, d = docs.get(p, (None, None, {}))
        ok = not r.errors
        bad += not ok
        index["files"].append({
            "file": os.path.relpath(p, REPO), "kind": kind, "lang": lang,
            "id": d.get("bundle_id") or d.get("track") or (f"{lang}-w{d.get('week', 0):02d}" if kind == "lessons" else None),
            "version": d.get("version"), "status": "ai-checked" if ok else "draft", "checks_passed": ok,
            "content_sha256": content_sha(d) if d else None,
            "errors": r.errors, "warnings": r.warnings, "stats": r.stats})
        lines.append(f"## {os.path.relpath(p, CONTENT_DIR)} — {'PASS (ai-checked)' if ok else 'FAIL'}")
        lines.append(f"stats: `{json.dumps(r.stats, ensure_ascii=False)}`")
        lines += [f"- ERROR {e}" for e in r.errors] + [f"- warn {w}" for w in r.warnings]
        lines.append("")
    lines.insert(1, f"{len(results) - bad}/{len(results)} files pass all checks.")
    report = "\n".join(lines)
    print(report)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, "tracks_index.json"), "w", encoding="utf-8") as f:
            json.dump(index, f, ensure_ascii=False, indent=1)
        with open(os.path.join(a.out, "tracks_report.md"), "w", encoding="utf-8") as f:
            f.write(report + "\n")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
