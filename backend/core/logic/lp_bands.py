"""
lp_bands.py — Language Partner V2 marking engine (lpcore). PURE: no Django,
no DB, no network, no clock, no AI.

* raw -> band with the PUBLIC conversion tables IELTS publishes for
  Listening, Academic Reading and General Training Reading (practice
  estimate: the official tables vary slightly per test version);
* the overall band with the public rounding rule (.25 -> .5, .75 -> next whole);
* answer matching for every objective question type (mcq, mcq_multi, tfng,
  ynng, gap, short, matching, map) with accepted alternatives ("a/b") and
  optional words in brackets ("(the) museum");
* the mistake-type classifier the owner asked for: spelling, plural,
  word_limit, tfng, map, matching (else other).

The same marker serves our own mocks and the Cambridge companion, where the
key is the one the USER typed from his own book (nothing of the book is kept).
"""
import re

PRACTICE_LABEL = {
    "en": "Practice score — not an official IELTS result.",
    "bn": "অনুশীলনের স্কোর — অফিসিয়াল IELTS ফল নয়।",
}

# (minimum raw score out of 40, band) — highest first. Public tables.
LISTENING = ((39, 9.0), (37, 8.5), (35, 8.0), (32, 7.5), (30, 7.0), (26, 6.5), (23, 6.0),
             (18, 5.5), (16, 5.0), (13, 4.5), (10, 4.0), (8, 3.5), (6, 3.0), (4, 2.5),
             (2, 2.0), (1, 1.0))
READING_AC = ((39, 9.0), (37, 8.5), (35, 8.0), (33, 7.5), (30, 7.0), (27, 6.5), (23, 6.0),
              (19, 5.5), (15, 5.0), (13, 4.5), (10, 4.0), (8, 3.5), (6, 3.0), (4, 2.5),
              (2, 2.0), (1, 1.0))
READING_GT = ((40, 9.0), (39, 8.5), (37, 8.0), (36, 7.5), (34, 7.0), (32, 6.5), (30, 6.0),
              (27, 5.5), (23, 5.0), (19, 4.5), (15, 4.0), (12, 3.5), (9, 3.0), (6, 2.5),
              (3, 2.0), (1, 1.0))

MISTAKES = ("spelling", "plural", "word_limit", "tfng", "map", "matching", "other")
TYPES = ("mcq", "mcq_multi", "tfng", "ynng", "gap", "short", "matching", "map")
TFNG = {"t": "TRUE", "true": "TRUE", "f": "FALSE", "false": "FALSE",
        "ng": "NOT GIVEN", "not given": "NOT GIVEN", "notgiven": "NOT GIVEN"}
YNNG = {"y": "YES", "yes": "YES", "n": "NO", "no": "NO",
        "ng": "NOT GIVEN", "not given": "NOT GIVEN", "notgiven": "NOT GIVEN"}


def table_for(section, variant="academic"):
    if section == "listening":
        return LISTENING
    if section == "reading":
        return READING_GT if variant in ("general", "gt", "ielts_gt") else READING_AC
    return None


def raw_to_band(raw, section, variant="academic", total=40):
    """Band for `raw` correct answers. A shorter practice set (total < 40) is
    scaled to 40 first so the same public table applies."""
    t = table_for(section, variant)
    if t is None:
        return None
    raw = max(0, int(raw or 0))
    total = max(1, int(total or 40))
    if total != 40:
        raw = int(round(raw * 40.0 / total))
    for lo, band in t:
        if raw >= lo:
            return band
    return 0.0


def round_band(x):
    """Public IELTS rounding of an average: .25 -> .5 and .75 -> next whole."""
    if x is None:
        return None
    whole = int(x)
    frac = x - whole
    if frac < 0.25 - 1e-9:
        return float(whole)
    if frac < 0.75 - 1e-9:
        return whole + 0.5
    return float(whole + 1)


def overall(bands):
    """Overall from the four section bands (missing ones ignored)."""
    vals = [float(b) for b in (bands or {}).values()
            if isinstance(b, (int, float)) and 0 <= b <= 9]
    if not vals:
        return None
    return round_band(sum(vals) / len(vals))


def writing_band(task1, task2):
    """Task 2 counts twice as much as Task 1 (public rule)."""
    if task1 is None and task2 is None:
        return None
    if task1 is None:
        return round_band(task2)
    if task2 is None:
        return round_band(task1)
    return round_band((task1 + 2 * task2) / 3.0)


def criteria_band(values):
    vals = [float(v) for v in values if isinstance(v, (int, float))]
    return round_band(sum(vals) / len(vals)) if vals else None


# ---------------------------------------------------------------- matching
_SPACE = re.compile(r"\s+")
_EDGE = re.compile(r"^[\s.,;:!?()\"'“”‘’]+|[\s.,;:!?()\"'“”‘’]+$")


def norm(s):
    s = str(s or "").lower().replace("-", " ").replace("’", "'")
    s = _EDGE.sub("", s)
    return _SPACE.sub(" ", s).strip()


def words(s):
    return [w for w in norm(s).split(" ") if w]


def _expand(alt):
    """'(the) museum' -> {'the museum', 'museum'}."""
    out = {""}
    for part in re.split(r"(\([^)]*\))", alt):
        if part.startswith("(") and part.endswith(")"):
            opt = part[1:-1]
            out = {o + opt for o in out} | out
        else:
            out = {o + part for o in out}
    return {norm(o) for o in out if norm(o)}


def accepted(key):
    """Every accepted spelling of a key: list or 'a/b' string, optional (..)."""
    alts = key if isinstance(key, (list, tuple)) else str(key or "").split("/")
    out = set()
    for a in alts:
        out |= _expand(str(a))
    return out


def lev(a, b, cap=3):
    """Edit distance with adjacent transpositions ('musuem' -> 'museum' = 1)."""
    if abs(len(a) - len(b)) > cap:
        return cap + 1
    d = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1):
        d[i][0] = i
    for j in range(len(b) + 1):
        d[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] != b[j - 1]))
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[len(a)][len(b)]


def _choice(v, qtype):
    v = norm(v)
    if qtype == "tfng":
        return TFNG.get(v, v.upper())
    if qtype == "ynng":
        return YNNG.get(v, v.upper())
    return v.upper()


def _letters(v):
    return sorted(set(x for x in re.split(r"[\s,;/&]+|and", norm(v).upper()) if x))


def _plural(y, a):
    """y and a differ only by an English plural ending (s / es / ies-y)."""
    for one, many in ((y, a), (a, y)):
        if many in (one + "s", one + "es") or (one.endswith("y") and many == one[:-1] + "ies"):
            return True
    return False


def classify(qtype, your, key, max_words=None):
    """(correct, mistake) for one answer. mistake is None when correct."""
    qtype = qtype if qtype in TYPES else "gap"
    if qtype in ("tfng", "ynng"):
        ok = _choice(your, qtype) in {_choice(k, qtype) for k in
                                     (key if isinstance(key, (list, tuple)) else [key])}
        return ok, (None if ok else "tfng")
    if qtype == "mcq_multi":
        want = _letters("/".join(key) if isinstance(key, (list, tuple)) else key)
        ok = _letters(your) == want
        return ok, (None if ok else "other")
    if qtype in ("mcq", "matching", "map"):
        keys = key if isinstance(key, (list, tuple)) else [key]
        ok = norm(your).upper() in {norm(k).upper() for k in keys} or \
            norm(your) in set().union(*[accepted(k) for k in keys])
        if ok:
            return True, None
        return False, ("matching" if qtype == "matching" else "map" if qtype == "map" else "other")
    # gap / short — free text
    y = norm(your)
    acc = accepted(key)
    if max_words and len(words(your)) > int(max_words):
        # a right word with extra words is still wrong in the real exam
        return False, "word_limit"
    if y in acc:
        return True, None
    if not y:
        return False, "other"
    for a in acc:
        if _plural(y, a):
            return False, "plural"
    for a in acc:
        cap = 1 if len(a) <= 6 else 2
        if len(a) >= 4 and 0 < lev(y, a, cap) <= cap:
            return False, "spelling"
    return False, "other"


def key_text(key):
    if isinstance(key, (list, tuple)):
        return " / ".join(str(k) for k in key)
    return str(key or "")


def mark(questions, answers, section="reading", variant="academic"):
    """Mark a set of questions [{n, type, answer, max_words, tag, explain_*}]
    against {n: text}. Returns {raw, total, band, items, weak, mistake_counts}."""
    answers = {str(k): v for k, v in (answers or {}).items()}
    items, raw, weak, counts = [], 0, [], {}
    for q in questions:
        n = str(q.get("n"))
        your = str(answers.get(n) or "")[:120]
        ok, mistake = classify(q.get("type"), your, q.get("answer"), q.get("max_words"))
        raw += 1 if ok else 0
        if mistake:
            counts[mistake] = counts.get(mistake, 0) + 1
            tag = q.get("tag") or ""
            if tag and tag not in weak:
                weak.append(tag)
        items.append({"n": q.get("n"), "your": your, "key": key_text(q.get("answer")),
                      "correct": ok, "mistake": mistake,
                      "explain_en": str(q.get("explain_en") or ""),
                      "explain_bn": str(q.get("explain_bn") or "")})
    total = len(questions)
    return {"raw": raw, "total": total,
            "band": raw_to_band(raw, section, variant, total) if total else None,
            "items": items, "weak": weak, "mistake_counts": counts,
            "practice_label": PRACTICE_LABEL}
