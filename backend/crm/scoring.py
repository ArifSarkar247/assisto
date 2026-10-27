"""
Lead scoring — DETERMINISTIC and honest.

The base score is computed purely in code from real, observable signals:
  - industry fit (target verticals score higher),
  - company size (bigger = more seats = higher value),
  - explicit buying-signal keywords in the lead's own messages
    (e.g. "দাম", "ভ্যাট", "কম্পোনেন্ট", "price", "quote", "ERP", "module").

A lead that wrote "আমাদের গার্মেন্টসের জন্য ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে"
(industry + size + multiple buying signals) lands ≥ 90 and is flagged High
Priority. A lead that only wrote "হাই" scores low. No number is ever invented.

When ai.available(), refine() may add a sentiment read + a short summary — but
it can only *nudge* the score within a tight band; the floor/ceiling stay
rule-based so results remain reproducible and auditable.
"""

# Buying-signal keywords (lowercased match on raw message text). Bangla +
# English, covering price/VAT/component/module/ERP/quote style intent.
BUYING_SIGNALS = [
    # Bangla
    "দাম", "মূল্য", "ভ্যাট", "কম্পোনেন্ট", "মডিউল", "ইআরপি", "কোটেশন",
    "প্রাইস", "ডেমো", "প্রপোজাল", "কিনতে", "কিনব", "ইমপ্লিমেন্ট",
    "লাগবে", "প্রয়োজন", "দরকার",   # expressing a need = strong buying intent
    # English
    "price", "pricing", "cost", "vat", "quote", "quotation", "erp",
    "module", "component", "demo", "proposal", "budget", "implement",
    "license", "subscription", "buy", "purchase",
    "need", "require", "looking for",
]

# Industry fit — target verticals from the spec get a head start.
INDUSTRY_FIT = {"rmg": 25, "pharma": 22, "retail": 18, "other": 8}

HIGH_PRIORITY_THRESHOLD = 90


def _size_points(company_size):
    """Company headcount → up to 25 points. Bigger deals, higher priority."""
    try:
        size = int(company_size or 0)
    except (TypeError, ValueError):
        size = 0
    if size >= 500:
        return 25
    if size >= 200:
        return 20
    if size >= 50:
        return 14
    if size >= 10:
        return 8
    if size > 0:
        return 4
    return 0  # unknown — no credit, we never guess


def _signal_points(texts):
    """Count DISTINCT buying-signal keywords across the lead's inbound text.
    Up to 50 points: strong, explicit intent is the biggest driver."""
    blob = " ".join(t for t in texts if t).lower()
    hits = {kw for kw in BUYING_SIGNALS if kw in blob}
    # 10 points per distinct signal, capped — multiple signals = serious buyer.
    return min(50, len(hits) * 10), sorted(hits)


def base_score(industry="other", company_size=0, inbound_texts=None):
    """Pure-code score in 0–100 plus a human-readable reason. No AI, no network.

    Returns dict: {score, priority, reason, signals}.
    """
    inbound_texts = inbound_texts or []
    fit = INDUSTRY_FIT.get(industry, INDUSTRY_FIT["other"])
    size = _size_points(company_size)
    sig, hits = _signal_points(inbound_texts)

    score = min(100, fit + size + sig)
    priority = Lead_HIGH if score >= HIGH_PRIORITY_THRESHOLD else Lead_NORMAL

    reason = (f"industry_fit={fit} + company_size={size} + "
              f"buying_signals={sig} (" + (", ".join(hits) if hits else "none")
              + f") = {score}")
    return {"score": score, "priority": priority, "reason": reason, "signals": hits}


# Avoid importing models at module import time (keeps scoring importable in
# isolation / tests); mirror the Lead priority constants as plain strings.
Lead_HIGH = "high"
Lead_NORMAL = "normal"


def rule_sentiment(text):
    """Deterministic sentiment from keywords — no AI needed. Returns
    'pos' | 'neu' | 'neg'. Interest/agreement = pos; rejection/anger = neg."""
    t = (text or "").lower()
    pos = ["agree", "interested", "yes", "great", "thanks", "ধন্যবাদ", "আগ্রহী",
           "ভালো", "হ্যাঁ", "চাই", "কিনব", "কথা বলি", "পরের সপ্তাহে", "demo",
           "proposal", "সময় দিন", "ঠিক আছে"]
    # Note: bare "না" is intentionally NOT used — as a 2-char substring it would
    # false-match inside neutral words (e.g. "আপনার"). We match specific
    # negation phrases instead, which is both correct and honest.
    neg = ["no", "not interested", "expensive", "costly", "cancel", "never",
           "বেশি দাম", "আগ্রহী নই", "লাগবে না", "বাদ দিন", "সমস্যা", "খারাপ",
           "দরকার নেই", "নই", "চাই না"]
    if any(k in t for k in neg):
        return "neg"
    if any(k in t for k in pos):
        return "pos"
    return "neu"


def refine_with_ai(base, inbound_texts, feature="crm.scoring", user=None):
    """OPTIONAL, honest refinement. If ai.available(), ask the model for a
    sentiment read + one-line summary and allow a small (±5) nudge within the
    rule-based band. If AI is off or fails, return the base unchanged — we never
    fabricate a score. Returns (result_dict, summary_or_'').
    """
    try:
        from core import ai
    except Exception:
        return base, ""
    if not ai.available():
        return base, ""

    data = "\n".join(t for t in inbound_texts if t)
    task = (
        "You are scoring a B2B software (ERP) sales lead. From the buyer's "
        "messages in <data>, reply with EXACTLY two lines:\n"
        "LINE1: one of POSITIVE / NEUTRAL / NEGATIVE (overall buying intent)\n"
        "LINE2: a one-sentence Bangla summary of what the buyer wants.\n"
        "Base intent only on the messages; do not invent requirements."
    )
    try:
        text, _ = ai.generate(task=task, data=data, tier="cheap",
                              max_tokens=120, feature=feature, user=user)
    except Exception:
        return base, ""

    lines = [l.strip() for l in (text or "").splitlines() if l.strip()]
    sentiment = lines[0].upper() if lines else ""
    summary = lines[1] if len(lines) > 1 else ""

    nudged = dict(base)
    # Positive intent can lift up to +5; negative can drop up to -5 — but the
    # score stays capped to [0,100] and the rule reason is preserved.
    if "POSITIVE" in sentiment:
        nudged["score"] = min(100, base["score"] + 5)
    elif "NEGATIVE" in sentiment:
        nudged["score"] = max(0, base["score"] - 5)
    nudged["priority"] = (Lead_HIGH if nudged["score"] >= HIGH_PRIORITY_THRESHOLD
                          else Lead_NORMAL)
    nudged["reason"] = base["reason"] + f" | ai_intent={sentiment or 'n/a'} (±5)"
    return nudged, summary
