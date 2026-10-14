"""
contract_analyzer.py — the deterministic, key-free engine behind Assisto's
CONTRACT / AGREEMENT ANALYZER (SPEC v2.1 §8 #30, ADVANCED).

The user pastes the text of a contract, lease, loan agreement, terms-of-service
or any plain-language agreement. This engine scans it with a fixed set of
RULES (keyword / phrase patterns, bn + en) and returns:

    * flags    — common RISK clauses it detected, each with a severity, the
                 matched phrase, and the kind of clause (auto-renewal, penalty,
                 lock-in, one-sided termination, hidden fees, jurisdiction, …)
    * summary  — a plain-language, deterministic digest ("this text mentions
                 auto-renewal and a penalty clause; verify the following …")
    * checklist — "things to verify before you sign" derived from what was (and
                 was NOT) found.

This module is PURE, exactly like `social.py` / `in_chat_ai.py`: no Django, no
DB, no network, no clock, **no AI**. It is a DETERMINISTIC RULE engine — same
input always gives the same output — so the on-device Dart mirror produces an
identical result offline and the tests can pin it.

NEVER LEGAL ADVICE
------------------
This is a REVIEW HELPER, not a lawyer. It flags phrases that *commonly* deserve
a second look; it does not interpret the law, judge enforceability, or tell the
user what to do. Every result carries `disclaimer=True` and the honest marker
key the UI renders ("review helper, not a lawyer — consult a professional").

HONEST AI, KEY-GATED
--------------------
The deterministic layer above works fully with NO key. A DEEPER analysis (a
real model reading the whole document in context, clause-by-clause) is the
key-gated seam: `deep_analysis_plan()` returns `{ai_required: True, mock: True}`
and names the Integrations key (`anthropic`, category AI) that unlocks the live
route. Nothing here calls a model; the plan shape is the contract the
integrator wires to `core.ai.generate`.

Everything is plain stdlib and hand-verified in
contract_analyzer_tests_snippets.py.
"""

import re

# The honest marker key every result carries. The UI renders the localised
# "AI-generated — review; not legal advice" chip from this; the engine never
# emits prose.
MARKER_KEY = "ai_review"

# The Integrations registry key whose presence unlocks the deeper (real-model)
# analysis. Documented, not called here.
AI_INTEGRATION = "anthropic"


# ---------------------------------------------------------------- rule set
# Each rule: a clause KIND, a severity, and a list of lowercase substrings /
# simple patterns (bn + en) that, if present, flag that clause. Severity is a
# stable key the UI localises + colours ("high" / "medium" / "low"). The
# phrases are detection seeds ONLY — they are never shown to the user as prose
# (the UI renders the localised clause label by `kind`), so no Bangla leaks
# into the Dart mirror: the mirror carries the SAME seed list, used only to
# match text the user pasted.
#
# Order here is the stable display order (high severity first within the list).
RULES = [
    {
        "kind": "auto_renewal",
        "severity": "high",
        "patterns": ["auto-renew", "auto renew", "automatically renew",
                     "automatic renewal", "renews automatically",
                     "shall renew", "স্বয়ংক্রিয়ভাবে নবায়ন", "স্বয়ংক্রিয় নবায়ন",
                     "নবায়ন হবে"],
    },
    {
        "kind": "penalty",
        "severity": "high",
        "patterns": ["penalty", "liquidated damages", "late fee", "late fine",
                     "default interest", "forfeit", "forfeiture",
                     "জরিমানা", "দণ্ড", "বিলম্ব ফি", "ক্ষতিপূরণ"],
    },
    {
        "kind": "lock_in",
        "severity": "high",
        "patterns": ["lock-in", "lock in period", "minimum term",
                     "minimum commitment", "non-cancellable", "non cancellable",
                     "binding for a period", "লক-ইন", "নূন্যতম মেয়াদ",
                     "ন্যূনতম মেয়াদ", "বাধ্যতামূলক মেয়াদ"],
    },
    {
        "kind": "one_sided_termination",
        "severity": "high",
        "patterns": ["terminate at its sole discretion",
                     "may terminate at any time without",
                     "terminate without cause", "terminate for convenience",
                     "sole discretion to terminate", "without notice to you",
                     "একতরফা বাতিল", "যেকোনো সময় বাতিল", "নোটিশ ছাড়া বাতিল"],
    },
    {
        "kind": "hidden_fees",
        "severity": "medium",
        "patterns": ["additional charges", "additional fees", "service charge",
                     "processing fee", "subject to change", "as applicable",
                     "plus applicable taxes", "convenience fee",
                     "অতিরিক্ত চার্জ", "অতিরিক্ত ফি", "সার্ভিস চার্জ",
                     "প্রযোজ্য কর", "পরিবর্তন সাপেক্ষে"],
    },
    {
        "kind": "jurisdiction",
        "severity": "medium",
        "patterns": ["governing law", "exclusive jurisdiction",
                     "courts of", "arbitration", "venue shall be",
                     "subject to the jurisdiction", "এখতিয়ার", "সালিশ",
                     "আদালতের এখতিয়ার", "প্রযোজ্য আইন"],
    },
    {
        "kind": "auto_debit",
        "severity": "medium",
        "patterns": ["auto-debit", "auto debit", "standing instruction",
                     "recurring payment", "automatically charged",
                     "স্বয়ংক্রিয় ডেবিট", "অটো ডেবিট", "নিয়মিত পেমেন্ট"],
    },
    {
        "kind": "liability_waiver",
        "severity": "medium",
        "patterns": ["as is", "no warranty", "disclaim all liability",
                     "not be liable", "limitation of liability", "indemnify",
                     "hold harmless", "দায় অস্বীকার", "দায়বদ্ধ থাকবে না",
                     "ক্ষতিপূরণ দিতে বাধ্য"],
    },
    {
        "kind": "data_sharing",
        "severity": "low",
        "patterns": ["share your data", "third party", "third-party",
                     "marketing purposes", "may disclose", "data with partners",
                     "তথ্য শেয়ার", "তৃতীয় পক্ষ", "বিপণন"],
    },
    {
        "kind": "price_increase",
        "severity": "low",
        "patterns": ["price may increase", "revise the price", "increase fees",
                     "adjust the price", "at our discretion increase",
                     "মূল্য বৃদ্ধি", "দাম বাড়াতে পারে", "মূল্য সংশোধন"],
    },
]

# Stable severity ordering (worst first) for sorting the flags.
_SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}

# The checklist is keyed; the UI localises each key. "always" items are shown
# regardless; per-clause items are added when that clause is detected.
ALWAYS_CHECK = ["parties", "dates", "payment_terms", "exit", "signatures"]

# Per-detected-clause extra "verify this" checklist keys.
_CLAUSE_CHECK = {
    "auto_renewal": "verify_renewal",
    "penalty": "verify_penalty",
    "lock_in": "verify_lockin",
    "one_sided_termination": "verify_termination",
    "hidden_fees": "verify_fees",
    "jurisdiction": "verify_jurisdiction",
    "auto_debit": "verify_autodebit",
    "liability_waiver": "verify_liability",
    "data_sharing": "verify_data",
    "price_increase": "verify_price",
}

# How many characters of context we keep around a match for the UI snippet.
_SNIPPET_PAD = 48
# Longest contract text we will scan (guards the mirror + server from abuse).
MAX_TEXT = 60000


# ---------------------------------------------------------------- helpers

def _norm(text):
    """Lowercase + collapse whitespace, clamped to MAX_TEXT. Never crash on
    None. Lowercasing is ASCII-only effectively; Bangla has no case so the
    bn seeds still match."""
    t = str(text or "")[:MAX_TEXT]
    return " ".join(t.split()).lower()


def _find_snippet(haystack_lower, original, needle_lower):
    """Return a short human snippet of the ORIGINAL text around the first match
    of `needle_lower`, or "" if not found. Deterministic."""
    idx = haystack_lower.find(needle_lower)
    if idx < 0:
        return ""
    # map the lower-index back onto a same-length normalised original so the
    # snippet reads naturally (we normalised whitespace identically).
    norm_original = " ".join(str(original or "").split())
    start = max(0, idx - _SNIPPET_PAD)
    end = min(len(norm_original), idx + len(needle_lower) + _SNIPPET_PAD)
    snip = norm_original[start:end].strip()
    if start > 0:
        snip = "… " + snip
    if end < len(norm_original):
        snip = snip + " …"
    return snip


# ---------------------------------------------------------------- validate

def validate(text):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these."""
    problems = []
    clean = str(text or "").strip()
    if not clean:
        problems.append("empty_text")
    elif len(clean) < 40:
        # too short to be a meaningful agreement — honest nudge, not a hard stop
        problems.append("too_short")
    return problems


# ---------------------------------------------------------------- analysis

def detect_clauses(text):
    """Scan `text` against RULES; return a list of flag dicts, worst-severity
    first then stable rule order. Each flag:

        {"kind", "severity", "matched", "snippet"}

    `matched` is the seed phrase that triggered the flag (for transparency);
    `snippet` is a short slice of the user's own text around it. Deterministic.
    A clause is reported at most ONCE even if several of its seeds match."""
    lower = _norm(text)
    flags = []
    for rule in RULES:
        hit = None
        for pat in rule["patterns"]:
            if pat in lower:
                hit = pat
                break
        if hit is not None:
            flags.append({
                "kind": rule["kind"],
                "severity": rule["severity"],
                "matched": hit,
                "snippet": _find_snippet(lower, text, hit),
            })
    # stable sort by severity rank; Python's sort is stable so rule order is
    # preserved within a severity band.
    flags.sort(key=lambda f: _SEVERITY_RANK.get(f["severity"], 9))
    return flags


def checklist(flags):
    """Build the 'things to verify' checklist KEYS: the always-check items plus
    one extra per detected clause kind. De-duped, stable order (always first,
    then per-clause in flag order). The UI localises each key."""
    items = list(ALWAYS_CHECK)
    seen = set(items)
    for f in flags:
        key = _CLAUSE_CHECK.get(f["kind"])
        if key and key not in seen:
            seen.add(key)
            items.append(key)
    return items


def severity_counts(flags):
    """Count flags per severity for the UI's at-a-glance summary chips."""
    counts = {"high": 0, "medium": 0, "low": 0}
    for f in flags:
        counts[f["severity"]] = counts.get(f["severity"], 0) + 1
    return counts


def analyze(text):
    """MAIN ENTRY. Deterministic rule-based analysis of `text`.

    Returns a dict the app renders:

        {
          "flags":    [{kind, severity, matched, snippet}, ...],  # worst first
          "counts":   {"high", "medium", "low"},
          "checklist":[verify-key, ...],
          "clause_kinds": [kind, ...],   # the distinct kinds detected
          "text_len": int,               # chars scanned
          "ai_required": False,          # the mock works with NO key
          "mock": True,                  # HONEST: rule-based, not real AI
          "disclaimer": True,            # NEVER legal advice
          "marker": "ai_review",
          "problems": [..]               # validate() keys; non-empty ⇒ invalid
        }

    No model, no key, no network, no clock. Identical input → identical output.
    """
    problems = validate(text)
    flags = detect_clauses(text)
    return {
        "flags": flags,
        "counts": severity_counts(flags),
        "checklist": checklist(flags),
        "clause_kinds": [f["kind"] for f in flags],
        "text_len": len(_norm(text)),
        "ai_required": False,   # deterministic layer needs no key
        "mock": True,           # honest: rule-based, review helper
        "disclaimer": True,     # never legal advice
        "marker": MARKER_KEY,
        "problems": problems,
    }


# ---------------------------------------------------------------- AI seam

def deep_analysis_plan(text):
    """The KEY-GATED seam for a DEEPER, model-read analysis (clause-by-clause
    in full context). This does NOT call a model — it returns the request/plan
    SHAPE the integrator wires to `core.ai.generate`, plus the deterministic
    analysis as a usable fallback so the UI is never empty.

        {
          "ai_required": True,           # a real model is needed for the deep read
          "ai_integration": "anthropic", # the Integrations key that unlocks it
          "mock": True,                  # this response is still the mock
          "fallback": {...analyze()...}, # the deterministic result to show now
          "marker": "ai_review",
          "disclaimer": True,
        }

    Honest: when the AI key is NOT connected, the UI shows `fallback` and an
    "owner can connect an AI key in Integrations for a deeper read" state. When
    it IS connected, the executor routes `text` to the real provider using this
    same shape. Still never legal advice.
    """
    return {
        "ai_required": True,
        "ai_integration": AI_INTEGRATION,
        "mock": True,
        "fallback": analyze(text),
        "marker": MARKER_KEY,
        "disclaimer": True,
    }
