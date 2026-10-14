"""
cost_estimator.py — the deterministic, key-free engine behind Assisto's
COST / TIME ESTIMATOR (SPEC v2.1 §8 #36, ADVANCED).

The user estimates the cost + time for a task or project by entering its
COMPONENTS (items / steps), each with a quantity, a unit cost and a duration.
This engine computes:

    * per-component subtotal cost (quantity × unit_cost) and subtotal time
      (quantity × duration), honestly handling blanks as zero;
    * project TOTAL cost (৳, in integer poisha to avoid float drift) and TOTAL
      time (in whole minutes), with a human breakdown;
    * an optional CONTINGENCY buffer (a % the user picks) added on top;
    * a rough LOW–HIGH band around the total for planning honesty.

This module is PURE, exactly like `social.py` / `in_chat_ai.py`: no Django, no
DB, no network, no clock, **no AI**. It is DETERMINISTIC — same input always
gives the same output — so the on-device Dart mirror matches and tests pin it.

MONEY IS INTEGER POISHA
-----------------------
All currency math is done in POISHA (1 ৳ = 100 poisha) as integers, exactly
like the Section-20 money modules, so totals never drift. The UI formats taka
with the ৳ glyph (U+09F3, gate-exempt). We HOLD NO MONEY — this only plans.

NEVER FINANCIAL ADVICE
----------------------
This is a PLANNING HELPER, not a quote or financial advice. It arithmetic-adds
exactly what the user enters; it never invents prices. Every result carries
`disclaimer=True` and the honest marker key.

HONEST AI, KEY-GATED
--------------------
The deterministic layer works fully with NO key, using the user's own numbers.
The optional "AI estimate for an UNKNOWN component" (the user doesn't know a
price/duration) is the key-gated seam: `ai_estimate_plan()` returns a
DETERMINISTIC rough band (a transparent heuristic from the known components)
AND `{ai_required: True, mock: True}` naming the Integrations AI key that would
unlock a real smart estimate. Nothing here calls a model.

Everything is plain stdlib and hand-verified in
cost_estimator_tests_snippets.py.
"""

# The honest marker key every result carries (UI renders localised chip).
MARKER_KEY = "ai_review"

# The Integrations registry key whose presence unlocks the smart AI estimate.
AI_INTEGRATION = "anthropic"

# Clamp absurd inputs so the mirror + server stay total.
MAX_COMPONENTS = 200
MAX_QTY = 1_000_000
MAX_UNIT_POISHA = 100_000_000_00   # ৳1e8 in poisha
MAX_MINUTES = 100_000_000
# Allowed contingency buffer percent range.
MAX_CONTINGENCY = 100


# ---------------------------------------------------------------- helpers

def to_poisha(taka):
    """Convert a taka amount (int/float/str) to integer POISHA, rounded to the
    nearest poisha. Blanks / junk → 0. Deterministic and total."""
    try:
        val = float(str(taka).replace(",", "").strip() or 0)
    except (ValueError, TypeError):
        return 0
    if val < 0:
        val = 0
    p = int(round(val * 100))
    return min(p, MAX_UNIT_POISHA)


def taka_str(poisha):
    """Format integer poisha as a '৳1,234.50' string. Deterministic. The ৳
    glyph is U+09F3 (currency sign), gate-exempt — not a Bangla letter."""
    poisha = max(0, int(poisha))
    whole, frac = divmod(poisha, 100)
    # group thousands with commas (Western grouping; the UI may re-localise)
    grouped = f"{whole:,}"
    return "৳" + grouped + "." + str(frac).rjust(2, "0")


def _int(value, cap):
    """Parse a non-negative integer, blanks/junk → 0, clamped to `cap`."""
    try:
        v = int(float(str(value).replace(",", "").strip() or 0))
    except (ValueError, TypeError):
        return 0
    if v < 0:
        v = 0
    return min(v, cap)


def minutes_human(total_minutes):
    """Break whole minutes into {days, hours, minutes} for a readable duration.
    The UI localises the unit labels; we only return the numbers."""
    total_minutes = max(0, int(total_minutes))
    days, rem = divmod(total_minutes, 24 * 60)
    hours, mins = divmod(rem, 60)
    return {"days": days, "hours": hours, "minutes": mins,
            "total_minutes": total_minutes}


# ---------------------------------------------------------------- validate

def validate(components, contingency_pct=0):
    """Return a list of problem keys (empty ⇒ valid). The UI localises these.

    `components` is a list of dicts:
        {"name": str, "qty": n, "unit_cost": taka, "minutes": n}
    """
    problems = []
    comps = components or []
    if not comps:
        problems.append("no_components")
    if len(comps) > MAX_COMPONENTS:
        problems.append("too_many_components")
    # a component with no name AND no numbers is "empty" — honest nudge
    named = [c for c in comps if str(c.get("name") or "").strip()]
    if comps and not named:
        problems.append("all_unnamed")
    try:
        cp = int(contingency_pct or 0)
    except (ValueError, TypeError):
        cp = -1
    if cp < 0 or cp > MAX_CONTINGENCY:
        problems.append("bad_contingency")
    return problems


# ---------------------------------------------------------------- compute

def component_line(comp):
    """Compute one component's subtotal. Returns a dict:

        {"name", "qty", "unit_poisha", "minutes_each",
         "cost_poisha", "time_minutes"}

    cost_poisha = qty × unit_poisha ; time_minutes = qty × minutes_each.
    Blanks → 0. Deterministic."""
    name = str(comp.get("name") or "").strip()
    qty = _int(comp.get("qty"), MAX_QTY)
    unit_poisha = to_poisha(comp.get("unit_cost"))
    minutes_each = _int(comp.get("minutes"), MAX_MINUTES)
    return {
        "name": name,
        "qty": qty,
        "unit_poisha": unit_poisha,
        "minutes_each": minutes_each,
        "cost_poisha": qty * unit_poisha,
        "time_minutes": qty * minutes_each,
    }


def estimate(components, contingency_pct=0):
    """MAIN ENTRY. Deterministic cost + time estimate for a project.

    Returns a dict the app renders:

        {
          "lines":        [component_line, ...],   # per-component subtotals
          "subtotal_poisha": int,                  # Σ cost before contingency
          "contingency_pct": int,
          "contingency_poisha": int,               # buffer added on top
          "total_poisha": int,                     # subtotal + contingency
          "total_taka": "৳...",                    # formatted
          "total_minutes": int,                    # Σ time (no contingency)
          "time_human":   {days, hours, minutes, total_minutes},
          "band": {"low_poisha", "high_poisha",    # ±15% planning band
                   "low_taka", "high_taka"},
          "component_count": int,
          "ai_required": False,     # the deterministic estimate needs no key
          "mock": True,             # honest: arithmetic, not an AI quote
          "disclaimer": True,       # NEVER financial advice / a quote
          "marker": "ai_review",
          "problems": [..]          # validate() keys
        }

    All money in integer poisha; no float drift. No model, no key, no clock.
    """
    problems = validate(components, contingency_pct)
    lines = [component_line(c) for c in (components or [])[:MAX_COMPONENTS]]
    subtotal = sum(l["cost_poisha"] for l in lines)
    total_minutes = sum(l["time_minutes"] for l in lines)

    cp = _int(contingency_pct, MAX_CONTINGENCY)
    contingency = (subtotal * cp) // 100   # integer poisha, floor
    total = subtotal + contingency

    # a transparent ±15% planning band on the total (floor/ceil-ish, integer).
    low = (total * 85) // 100
    high = (total * 115 + 99) // 100   # round up so high ≥ total
    return {
        "lines": lines,
        "subtotal_poisha": subtotal,
        "contingency_pct": cp,
        "contingency_poisha": contingency,
        "total_poisha": total,
        "total_taka": taka_str(total),
        "total_minutes": total_minutes,
        "time_human": minutes_human(total_minutes),
        "band": {
            "low_poisha": low,
            "high_poisha": high,
            "low_taka": taka_str(low),
            "high_taka": taka_str(high),
        },
        "component_count": len(lines),
        "ai_required": False,
        "mock": True,
        "disclaimer": True,
        "marker": MARKER_KEY,
        "problems": problems,
    }


# ---------------------------------------------------------------- AI seam

def ai_estimate_plan(label, components):
    """KEY-GATED seam: a smart estimate for an UNKNOWN component the user can't
    price. This does NOT call a model. It returns a DETERMINISTIC rough band
    derived transparently from the KNOWN components (the average known unit
    cost / duration, ±40%), labelled honestly as a placeholder, PLUS the
    request/plan shape + the Integrations key that unlocks a real smart estimate.

        {
          "label": "<what the user is unsure about>",
          "rough": {"low_poisha", "high_poisha", "low_taka", "high_taka",
                    "low_minutes", "high_minutes"},   # heuristic placeholder
          "basis": "known_average" | "none",          # how `rough` was derived
          "ai_required": True,            # a real smart estimate needs the key
          "ai_integration": "anthropic",  # the Integrations key that unlocks it
          "mock": True,                   # honest: this band is a heuristic
          "disclaimer": True,
          "marker": "ai_review",
        }

    When the AI key is NOT connected the UI shows `rough` + an honest
    "owner can connect an AI key in Integrations for a smarter estimate" state.
    Deterministic; invents no real price.
    """
    lines = [component_line(c) for c in (components or [])]
    priced = [l for l in lines if l["qty"] and l["unit_poisha"]]
    timed = [l for l in lines if l["qty"] and l["minutes_each"]]

    if priced:
        avg_unit = sum(l["unit_poisha"] for l in priced) // len(priced)
        basis = "known_average"
    else:
        avg_unit = 0
    if timed:
        avg_min = sum(l["minutes_each"] for l in timed) // len(timed)
    else:
        avg_min = 0
    basis = "known_average" if (priced or timed) else "none"

    low_p = (avg_unit * 60) // 100    # −40%
    high_p = (avg_unit * 140) // 100  # +40%
    low_m = (avg_min * 60) // 100
    high_m = (avg_min * 140) // 100
    return {
        "label": str(label or "").strip(),
        "rough": {
            "low_poisha": low_p,
            "high_poisha": high_p,
            "low_taka": taka_str(low_p),
            "high_taka": taka_str(high_p),
            "low_minutes": low_m,
            "high_minutes": high_m,
        },
        "basis": basis,
        "ai_required": True,
        "ai_integration": AI_INTEGRATION,
        "mock": True,
        "disclaimer": True,
        "marker": MARKER_KEY,
    }
