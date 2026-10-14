"""
spending_advice.py — pure, deterministic rule-based SPENDING OBSERVATIONS for
the AI spending-advice feature (#51, SPEC v2.1 §21, ADVANCED).

This module turns the user's OWN summarised category totals (which the screen
either reads from the money module or the user types in) into plain, honest
OBSERVATIONS — never financial advice. It is PURE, exactly like money_engine.py
/ in_chat_ai.py: no Django, no DB, no network, **no AI**, no clock. Same inputs
always give the same output, so the on-device Dart mirror produces identical
numbers offline and the tests can pin every figure.

NEVER FINANCIAL ADVICE
----------------------
Everything here is framed as "general observations about numbers you entered",
not advice. We state facts about the user's own data (top category, share of
spend, month-over-month change, whether a category is over a budget the USER
set) and offer neutral, factual savings *pointers* ("Food is 42% of your spend")
— we do not tell anyone what to do with their money. Every result carries
`advice=False` and `disclaimer_key` so the UI always renders the honest
"general observations, not financial advice" note.

NO FABRICATION
--------------
We operate ONLY on the category totals / budgets the caller passes in. We never
invent transactions, never guess amounts, never fill in categories the user did
not enter. If there is too little data we return `enough_data=False` and the UI
shows an honest first-use / not-enough-data state instead of a made-up insight.

HONEST AI SEAM (KEY-GATED)
--------------------------
Deeper, free-text AI advice (e.g. a narrative written by a model) is a DOCUMENTED
seam only: `ai_seam()` returns {required, mock, prompt_shape} describing what a
real AI route would receive. Nothing here calls a model; `ai_required=True` on
that seam is the honest "connect an AI key (Integrations → anthropic:
core.ai.generate) for a written summary" state. The deterministic observations
below need NO key and are the real feature.

MONEY
-----
All money is INTEGER POISHA to avoid float drift (mirror of the Dart `_SMath`).
`to_minor` parses "1,250.50" → 125050; `fmt_bdt` renders 125050 → "৳1,250.50".
Percentages are integers (rounded half-up). Holds no money, moves no money.

Hand-verified in spending_advice_tests_snippets.py.
"""

# The honest marker/disclaimer keys the UI localises. We never emit prose.
DISCLAIMER_KEY = "spend_not_advice"     # "general observations, not advice"
MARKER_KEY = "spend_observations"       # chip over the generated observations

# Below this many categories (with any spend) we decline to "analyse" — an
# honest not-enough-data state instead of a one-line fake insight.
MIN_CATEGORIES = 1

# A category is flagged a "big share" of spend at/above this percent of the
# month's total. Neutral threshold; a fact, not a judgement.
BIG_SHARE_PCT = 30


# ------------------------------------------------------------------ money

def to_minor(v):
    """Parse str/int/float/None money into integer poisha. '1,250.50'→125050.
    Junk → 0. Mirrors money handling across the app; never raises."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(round(v * 100))
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, _, frac = s.partition(".")
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    if not (whole.isdigit() and frac.isdigit()):
        return 0
    minor = int(whole) * 100 + int(frac) // 10
    if int(frac) % 10 >= 5:
        minor += 1
    return -minor if neg else minor


def _group(n):
    """Group digits in the South-Asian 2-2-3 style: 1234567 → 12,34,567."""
    s = str(n)
    if len(s) <= 3:
        return s
    head, tail = s[:-3], s[-3:]
    parts = []
    while len(head) > 2:
        parts.insert(0, head[-2:])
        head = head[:-2]
    if head:
        parts.insert(0, head)
    return ",".join(parts) + "," + tail


def fmt_bdt(poisha):
    """Integer poisha → '৳1,250.50' (the ৳ glyph is a currency sign)."""
    neg = poisha < 0
    poisha = abs(int(poisha))
    taka, paisa = poisha // 100, poisha % 100
    return ("-" if neg else "") + "৳" + _group(taka) + "." + f"{paisa:02d}"


def _pct(part, whole):
    """Integer percent of part in whole, rounded half-up. 0 when whole<=0."""
    if whole <= 0:
        return 0
    return int((part * 100 + whole // 2) // whole) if whole else 0


# ------------------------------------------------------------------ inputs

def normalise_categories(rows):
    """Turn a list of {category, amount[, budget]} into a clean, de-duped list
    of {category, spent(minor), budget(minor|None)}. Amounts are summed per
    category (so the UI can pass raw entries); non-positive/junk → 0. Rows with
    no spend AND no budget are dropped (nothing to observe). Deterministic:
    sorted by spend desc, then category name for ties."""
    agg = {}
    for r in rows or []:
        cat = (r.get("category") or "uncategorized")
        if not isinstance(cat, str):
            cat = str(cat)
        cat = cat.strip() or "uncategorized"
        spent = max(0, to_minor(r.get("amount") if "amount" in r else r.get("spent")))
        budget = r.get("budget")
        bminor = to_minor(budget) if (budget is not None and budget != "") else None
        if bminor is not None and bminor < 0:
            bminor = None
        cur = agg.get(cat)
        if cur is None:
            agg[cat] = {"category": cat, "spent": spent, "budget": bminor}
        else:
            cur["spent"] += spent
            # keep the first non-None budget we see for a category
            if cur["budget"] is None and bminor is not None:
                cur["budget"] = bminor
    out = [v for v in agg.values() if v["spent"] > 0 or v["budget"] is not None]
    out.sort(key=lambda x: (-x["spent"], x["category"]))
    return out


# ------------------------------------------------------------------ analysis

def analyse(categories, previous=None, min_categories=MIN_CATEGORIES):
    """Deterministic observations over the user's OWN summarised totals.

    categories: list of {category, amount|spent[, budget]} for the current
        period (the screen builds this from the money module or user entry).
    previous:   optional {category: amount} (or list of {category, amount}) of
        the PREVIOUS period, for month-over-month deltas. None ⇒ no MoM facts.
    min_categories: below this many spending categories we decline and return
        enough_data=False (honest first-use / not-enough-data state).

    Returns a dict the client renders. Every figure is derived from the input;
    nothing is invented. Observation entries are {key, params} so the UI
    localises them — this module never emits prose. advice=False always.
    """
    cats = normalise_categories(categories)
    spending = [c for c in cats if c["spent"] > 0]
    total = sum(c["spent"] for c in spending)

    base = {
        "advice": False,            # NEVER financial advice
        "mock": True,               # deterministic engine, honestly labelled
        "ai_required": False,       # the observations need no key
        "marker": MARKER_KEY,
        "disclaimer_key": DISCLAIMER_KEY,
    }

    if len(spending) < min_categories or total <= 0:
        return {
            **base,
            "enough_data": False,
            "category_count": len(spending),
            "min_categories": min_categories,
            "total_spent": 0,
            "total_spent_display": fmt_bdt(0),
            "observations": [],
            "categories": [],
            "overspend": [],
        }

    # previous-period lookup {category: minor}
    prev_map = {}
    if previous:
        items = previous.items() if isinstance(previous, dict) else (
            (p.get("category"), p.get("amount") if "amount" in p else p.get("spent"))
            for p in previous)
        for k, v in items:
            if k is None:
                continue
            prev_map[str(k)] = prev_map.get(str(k), 0) + max(0, to_minor(v))

    # per-category breakdown (share of spend, MoM delta, budget state)
    rows = []
    overspend = []
    for c in spending:
        share = _pct(c["spent"], total)
        prev = prev_map.get(c["category"])
        delta = (c["spent"] - prev) if prev is not None else None
        delta_pct = _pct(abs(delta), prev) * (1 if delta and delta > 0 else -1) \
            if (prev is not None and prev > 0 and delta) else (
                0 if prev is not None else None)
        budget = c["budget"]
        over = None
        if budget is not None and budget > 0:
            over = c["spent"] - budget
        row = {
            "category": c["category"],
            "spent": c["spent"],
            "spent_display": fmt_bdt(c["spent"]),
            "share_pct": share,
            "previous": prev,
            "previous_display": (fmt_bdt(prev) if prev is not None else None),
            "delta": delta,
            "delta_display": (fmt_bdt(delta) if delta is not None else None),
            "delta_pct": delta_pct,          # signed %, None when no prev
            "up": (delta > 0) if delta is not None else None,
            "budget": budget,
            "budget_display": (fmt_bdt(budget) if budget is not None else None),
            "over_budget": (over is not None and over > 0),
            "over_by": (over if (over is not None and over > 0) else None),
            "over_by_display": (fmt_bdt(over) if (over is not None and over > 0) else None),
            "big_share": share >= BIG_SHARE_PCT,
        }
        rows.append(row)
        if row["over_budget"]:
            overspend.append(row)

    # total MoM (only when we have any previous data)
    prev_total = sum(prev_map.values()) if prev_map else None
    total_delta = (total - prev_total) if prev_total is not None else None
    total_delta_pct = (_pct(abs(total_delta), prev_total)
                       * (1 if total_delta and total_delta > 0 else -1)) \
        if (prev_total and prev_total > 0 and total_delta) else (
            0 if prev_total is not None else None)

    top = rows[0]

    # -------- deterministic OBSERVATION list (keys + params; UI localises) ----
    obs = []
    # 1) top category share — a fact about the user's own split
    obs.append({"key": "top_category",
                "params": {"category": top["category"],
                           "amount": top["spent_display"],
                           "pct": top["share_pct"]}})
    # 2) big-share flag when a single category dominates
    if top["big_share"]:
        obs.append({"key": "big_share",
                    "params": {"category": top["category"],
                               "pct": top["share_pct"]}})
    # 3) month-over-month on total spend (only with real previous data)
    if total_delta is not None and prev_total and prev_total > 0:
        obs.append({"key": "total_mom_up" if total_delta > 0 else (
                        "total_mom_down" if total_delta < 0 else "total_mom_flat"),
                    "params": {"pct": abs(total_delta_pct or 0),
                               "amount": fmt_bdt(abs(total_delta))}})
    # 4) biggest mover category (largest absolute delta) — a fact, not advice
    movers = [r for r in rows if r["delta"] is not None and r["delta"] != 0]
    if movers:
        mover = max(movers, key=lambda r: (abs(r["delta"]), r["category"]))
        obs.append({"key": "category_mover_up" if mover["delta"] > 0
                    else "category_mover_down",
                    "params": {"category": mover["category"],
                               "amount": fmt_bdt(abs(mover["delta"])),
                               "pct": abs(mover["delta_pct"] or 0)}})
    # 5) overspend flags vs the user's OWN budgets
    for r in overspend:
        obs.append({"key": "over_budget",
                    "params": {"category": r["category"],
                               "amount": r["over_by_display"],
                               "budget": r["budget_display"]}})
    # 6) neutral savings pointer: the single largest category as a share — a
    # factual pointer ("the biggest slice is X"), never a directive.
    obs.append({"key": "savings_pointer",
                "params": {"category": top["category"],
                           "pct": top["share_pct"]}})

    return {
        **base,
        "enough_data": True,
        "category_count": len(spending),
        "total_spent": total,
        "total_spent_display": fmt_bdt(total),
        "previous_total": prev_total,
        "previous_total_display": (fmt_bdt(prev_total) if prev_total is not None else None),
        "total_delta": total_delta,
        "total_delta_display": (fmt_bdt(total_delta) if total_delta is not None else None),
        "total_delta_pct": total_delta_pct,
        "total_up": (total_delta > 0) if total_delta is not None else None,
        "categories": rows,
        "overspend": overspend,
        "observations": obs,
    }


# ------------------------------------------------------------------ AI seam

def ai_seam(categories, previous=None):
    """DOCUMENTED, key-gated seam for a *written* AI summary — not wired here.

    Returns the request shape a real route (Integrations → `anthropic`,
    i.e. `core.ai.generate`) would receive, plus the honest deterministic
    observations as the MOCK body. `ai_required=True` is the honest "connect an
    AI key for a written summary" state; nothing in this function calls a model
    and it never fabricates a narrative. The user's numbers would be passed as
    DATA (never as instructions) to the model behind the key.
    """
    result = analyse(categories, previous=previous)
    return {
        "ai_required": True,
        "mock": True,
        "marker": MARKER_KEY,
        "disclaimer_key": DISCLAIMER_KEY,
        "integration": "anthropic",      # unlock via core.ai.generate
        "prompt_shape": {
            "task": "summarise_spending_observations",
            "tier": "cheap",
            # the deterministic observations are the DATA fenced input; the model
            # would only rephrase them — it must not invent new figures.
            "data": {
                "total_spent_display": result.get("total_spent_display"),
                "observations": result.get("observations", []),
            },
            "must_not": ["invent amounts", "give financial advice",
                         "add transactions"],
        },
        "mock_result": result,
    }
