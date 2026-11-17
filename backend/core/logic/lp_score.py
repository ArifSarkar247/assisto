"""
lp_score.py — Writing / Speaking scoring prompts + parser + credit maths for
Language Partner V2 (lpcore). PURE (no Django, no network).

* The model marks against the PUBLIC IELTS band descriptors. The criteria
  are summarised below IN OUR OWN WORDS (the descriptor tables themselves are
  not copied): Writing TA (Task 1) / TR (Task 2), CC, LR, GRA; Speaking FC,
  LR, GRA, P.
* Output: per-criterion band, the corrected text, every mistake with a
  simple Bangla explanation. Strict JSON, parsed defensively.
* Credits: the worst case (input cap + output cap + thinking headroom at the
  dearest model the call may reach, at >= 125 BDT/USD) priced by
  plan_book.level_credits — so every score keeps >= 40 % worst-case profit.
  Haiku for Normal, Sonnet only for Best.
"""
import json
import math
import re

from . import lp_bands as B

LEVELS = ("normal", "best")
WRITING_KEYS = {1: ("TA", "CC", "LR", "GRA"), 2: ("TR", "CC", "LR", "GRA")}
SPEAKING_KEYS = ("FC", "LR", "GRA", "P")
MISTAKE_TYPES = ("grammar", "vocabulary", "spelling", "punctuation", "coherence", "task",
                 "fluency", "pronunciation", "word_choice")
MAX_WRITING_CHARS = 4500          # ~ 700 words, far above Task 2's 250
MAX_SPEAKING_CHARS = 3500         # ~ 3-4 minutes of speech
MAX_PROMPT_CHARS = 1500
PROMPT_TOKEN_LIMIT = 90000        # owner: Haiku above 100k costs 5x; we stay far below

# The caps the scorer runs with when the AI-levels block is off (otherwise
# the live level caps apply and the larger of the two prices the credits).
CAPS = {"normal": {"in": 12000, "out": 2500}, "best": {"in": 12000, "out": 3000}}
# models the router may reach (dearest counts) when the levels block is off
FALLBACK_TIER = {"normal": "cheap", "best": "strong"}

_DESCRIPTORS_W = """Criteria (public IELTS Writing band descriptors, summarised):
- TA (Task 1) / TR (Task 2): does the answer do everything the task asks? Task 1 (Academic): a clear
  overview, key features selected and compared, accurate data; Task 1 (General): the letter's purpose
  clear, every bullet covered, right tone. Task 2: a clear position all through, ideas extended and
  supported, relevant. Under the minimum words or off-topic lowers this band.
- CC: logical order, paragraphs with one central idea each, linking words used accurately and not
  mechanically, clear referencing.
- LR: range and precision of vocabulary, natural collocation, less common words used well; spelling and
  word-formation errors and repetition lower the band.
- GRA: range of structures (complex sentences) and accuracy; how many sentences are error-free;
  punctuation.
Band guide per criterion: 9 = fully natural, rare slips; 8 = very wide range, occasional errors;
7 = flexible, good control, a few errors; 6 = adequate, some errors that rarely block meaning;
5 = limited, frequent errors that can strain the reader; 4 = basic, errors often block meaning;
3 or less = very little control."""

_DESCRIPTORS_S = """Criteria (public IELTS Speaking band descriptors, summarised):
- FC: speaks at length without effort, little hesitation searching for language, ideas linked and
  developed, answers extended.
- LR: range of vocabulary for familiar and unfamiliar topics, idiomatic use, paraphrase when needed.
- GRA: range of sentence structures and how many are error-free.
- P: how easily the speaker is understood — sounds, word and sentence stress, intonation, chunking.
  You only see a speech-to-text transcript and the phone recogniser's confidence: estimate P from the
  confidence, recognised-word quality and rhythm cues, and say it is approximate.
Band guide per criterion: 9 = fully natural; 8 = very fluent, rare slips; 7 = flexible, some
hesitation, good control; 6 = willing and mostly clear, some errors and repetition; 5 = slow, limited
range, frequent errors; 4 = long pauses, basic language; 3 or less = very little communication."""

_OUT = """Reply with ONE JSON object only, no prose before or after:
{"criteria":{%s},
 "notes":{%s},
 "corrected":"<%s>",
 "mistakes":[{"wrong":"<exact words from the learner>","right":"<fixed>","type":"<one of %s>",
   "en":"<one short sentence: why>","bn":"<the same reason in simple Bangla>"}],
 "summary_en":"<two sentences: main strength + the one change that raises the band most>",
 "summary_bn":"<the same in simple Bangla>"}
Bands are numbers from 0 to 9 in steps of 0.5. List the most important mistakes first, at most %d.
Keep every "bn" text short and plain (Bangladeshi learners). Never invent mistakes. This is practice
marking, never an official result."""


def _crit_json(keys):
    return ",".join('"%s":<band>' % k for k in keys), \
        ",".join('"%s":{"en":"<one sentence>","bn":"<Bangla>"}' % k for k in keys)


def writing_system(task, variant):
    keys = WRITING_KEYS[2 if task == 2 else 1]
    c, n = _crit_json(keys)
    what = ("Task 2 essay (at least 250 words)" if task == 2 else
            "Task 1 report on a chart/diagram (Academic, at least 150 words)" if variant != "general"
            else "Task 1 letter (General Training, at least 150 words)")
    return ("You are a senior IELTS Writing examiner and a kind teacher for Bangla speakers. Mark the "
            "learner's %s.\n%s\n%s" % (what, _DESCRIPTORS_W, _OUT % (
                c, n, "the whole answer rewritten with every mistake fixed, same ideas, same length",
                "|".join(MISTAKE_TYPES), 8)))


def speaking_system(part):
    c, n = _crit_json(SPEAKING_KEYS)
    return ("You are a senior IELTS Speaking examiner and a kind teacher for Bangla speakers. Mark the "
            "learner's Speaking Part %d answer from its transcript.\n%s\n%s" % (
                part, _DESCRIPTORS_S, _OUT % (
                    c, n, "the answer as a natural, corrected spoken reply (same ideas)",
                    "|".join(MISTAKE_TYPES), 6)))


def writing_task(prompt, text):
    nw = len(B.words(text))
    return ("Task prompt:\n%s\n\nThe learner wrote %d words. Mark the answer inside <data>." % (
        str(prompt or "")[:MAX_PROMPT_CHARS], nw)), str(text or "")[:MAX_WRITING_CHARS]


def speaking_task(prompt, transcript, seconds=None, confidence=None):
    nw = len(B.words(transcript))
    wpm = round(nw * 60.0 / seconds) if seconds else None
    meta = "Words: %d." % nw
    if wpm:
        meta += " Speed: %d words per minute." % wpm
    if isinstance(confidence, (int, float)):
        meta += " Phone recogniser confidence: %d%%." % round(100 * max(0.0, min(1.0, confidence)))
    return ("Question:\n%s\n\n%s Mark the transcript inside <data>." % (
        str(prompt or "")[:MAX_PROMPT_CHARS], meta)), str(transcript or "")[:MAX_SPEAKING_CHARS]


def _band(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not 0 <= v <= 9:
        return None
    return math.floor(float(v) * 2 + 0.5) / 2.0


def parse(text, keys, max_mistakes=8):
    """Model text -> safe dict, or None when unusable (then nothing is charged)."""
    m = re.search(r"\{.*\}", str(text or ""), re.S)
    if not m:
        return None
    try:
        j = json.loads(m.group(0))
    except (ValueError, TypeError):
        return None
    crit_in = j.get("criteria") if isinstance(j.get("criteria"), dict) else {}
    crit = {k: _band(crit_in.get(k)) for k in keys}
    if any(v is None for v in crit.values()):
        return None
    notes_in = j.get("notes") if isinstance(j.get("notes"), dict) else {}
    notes = {}
    for k in keys:
        nk = notes_in.get(k) if isinstance(notes_in.get(k), dict) else {}
        notes[k] = {"en": str(nk.get("en") or "")[:400], "bn": str(nk.get("bn") or "")[:400]}
    mistakes = []
    for x in (j.get("mistakes") or [])[:max_mistakes]:
        if not isinstance(x, dict) or not str(x.get("wrong") or "").strip():
            continue
        t = str(x.get("type") or "grammar")
        mistakes.append({"wrong": str(x["wrong"])[:200], "right": str(x.get("right") or "")[:200],
                         "type": t if t in MISTAKE_TYPES else "grammar",
                         "en": str(x.get("en") or "")[:300], "bn": str(x.get("bn") or "")[:300]})
    return {"criteria": crit, "criteria_notes": notes,
            "band": B.criteria_band(list(crit.values())),
            "corrected": str(j.get("corrected") or "")[:6000], "mistakes": mistakes,
            "summary_en": str(j.get("summary_en") or "")[:500],
            "summary_bn": str(j.get("summary_bn") or "")[:500]}


# ------------------------------------------------------------- credit maths
def worst_cost_usd(models, in_tokens, out_tokens, prices):
    """Dearest model the call may reach; unknown model -> priced as Opus."""
    worst = 0.0
    for m in models:
        p = prices.get(m) or prices.get("claude-opus-5-5") or {"in": 4.0, "out": 20.0}
        worst = max(worst, (in_tokens * float(p["in"]) + out_tokens * float(p["out"])) / 1e6)
    return worst


def credits_for(models, in_tokens, out_tokens, prices, usd_bdt=None, floor=1):
    from . import plan_book as PB
    return max(int(floor or 1), PB.level_credits(
        worst_cost_usd(models, in_tokens, out_tokens, prices), usd_bdt or PB.SAFETY_USD_BDT))


def profit_pct(credits, cost_usd, usd_bdt=None):
    """Worst-case profit share of the credits' floor price (the owner's 40 % rule)."""
    from . import plan_book as PB
    rate = max(float(usd_bdt or 0), PB.SAFETY_USD_BDT)
    price = credits * PB.MIN_BDT_PER_CREDIT
    net = price * PB.NET_PCT - price * PB.OVERHEAD_PCT - cost_usd * rate
    return net / price if price else 0.0
