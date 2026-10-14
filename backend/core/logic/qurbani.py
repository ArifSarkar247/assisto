"""
qurbani.py — pure, deterministic QURBANI (Eid-ul-Adha) PLANNER math (#190,
SPEC v2.1 §20, built to the §21 "advanced" standard).

A Qurbani is one sacrificial animal. A large animal (cow / buffalo / camel) can
be shared by up to SEVEN people (7 shares); a goat / sheep is ONE person's full
Qurbani (1 share). This module computes, with ZERO drift:

  * cost per share            = total animal cost ÷ number of shares
  * each participant's cost   = their shares × cost-per-share (distributed with
                                the largest-remainder method so the per-head
                                amounts sum EXACTLY back to the animal cost)
  * how many shares are taken / still free on an animal
  * the traditional THREE-PART meat distribution plan (family / relatives /
    poor) by weight — presented NEUTRALLY; see the note below.
  * a planning checklist's progress (done ÷ total)

HARD RULES (identical to money_engine / expense_split discipline):

  * ALL MONEY IS INTEGER POISHA. 1 taka = 100 poisha. No float ever enters the
    ledger. Splitting N poisha among k shares uses the largest-remainder method
    (leftover poisha to the biggest fractional remainders, ties -> input order)
    so the share amounts ALWAYS sum EXACTLY to the animal total — no paisa lost
    or invented.
  * WEIGHT (meat) is INTEGER GRAMS internally, same largest-remainder split, so
    the three parts sum EXACTLY to the usable meat weight.
  * NO DB, NO AI, NO I/O, NO CLOCK, NO MONEY-HOLDING. Computes and returns plain
    dicts; the view layer persists plans/participants in a flexible per-user
    JSON collection and renders what we return. The app moves no money and keeps
    no animal — it only helps people PLAN and split the cost fairly themselves.
  * Human-facing copy is returned as bilingual {"bn","en"} pairs so the Dart
    layer shows them directly and keeps ZERO Bangla in .dart.

RELIGIOUS CONTENT — ACCURATE & RESPECTFUL, NO FATWA
---------------------------------------------------
The 1-vs-7 share rule for small-vs-large animals and the customary one-third /
one-third / one-third split of the meat (family / relatives / the poor) are the
WIDELY-FOLLOWED traditional (sunnah) practice. We present them NEUTRALLY as the
default the user may adjust; we make no fatwa or ruling and the three-part
percentages are editable. This module encodes arithmetic only.

Run self-tests (no DB):
    python3 -c "import core.logic.qurbani_tests_snippets as t; t.run_all()"
"""
from __future__ import annotations

# ------------------------------------------------------------------ animals
# Max shares per animal kind. A small animal is ONE person's full Qurbani; a
# large animal may be shared by up to SEVEN. These are the well-known caps; the
# UI label for each kind is localised by key — the engine never emits that prose.
ANIMAL_SHARES = {
    "cow": 7,
    "buffalo": 7,
    "camel": 7,
    "goat": 1,
    "sheep": 1,
}
ANIMAL_KINDS = tuple(ANIMAL_SHARES.keys())
MAX_SHARES = 7

# Traditional three-part meat split (fractions). Presented neutrally and the UI
# lets the user override the percentages; this is only the default.
DEFAULT_DISTRIBUTION = {"family": 1, "relatives": 1, "poor": 1}  # equal thirds
DIST_PARTS = ("family", "relatives", "poor")


def pick(lang, bn, en):
    return en if lang == "en" else bn


# ---------------------------------------------------------------------------
# poisha <-> taka (integer only) — same discipline as the money modules
# ---------------------------------------------------------------------------

def to_poisha(v):
    """Coerce taka-ish input to INTEGER poisha. Junk -> 0."""
    if v is None or v == "":
        return 0
    if isinstance(v, bool):
        return 0
    if isinstance(v, int):
        return v
    s = str(v).strip().replace(",", "")
    neg = s.startswith("-")
    if neg:
        s = s[1:]
    if "." in s:
        whole, frac = s.split(".", 1)
    else:
        whole, frac = s, ""
    whole = whole or "0"
    frac = (frac + "00")[:3]
    try:
        taka = int(whole)
        milli = int(frac)
    except ValueError:
        return 0
    poisha = taka * 100 + milli // 10
    if milli % 10 >= 5:
        poisha += 1
    return -poisha if neg else poisha


def _group(n):
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


def fmt_poisha(p):
    """Format integer poisha as a ৳ amount string (always 2 dp)."""
    p = int(p)
    neg = p < 0
    p = abs(p)
    taka, paisa = divmod(p, 100)
    return ("-" if neg else "") + "৳" + f"{_group(taka)}.{paisa:02d}"


# ---------------------------------------------------------------------------
# the no-drift integer split core (largest remainder)
# ---------------------------------------------------------------------------

def _largest_remainder(total, weights):
    """Split INTEGER `total` across `weights` so the parts sum EXACTLY to total.
    Leftover one-each to the biggest fractional remainders; ties -> input order.
    Handles the sign of total. Returns a list the same length as weights."""
    total = int(total)
    weights = [max(0, int(w)) for w in weights]
    W = sum(weights)
    if not weights:
        return []
    if W == 0:
        # equal split as a fallback so nothing is lost
        weights = [1] * len(weights)
        W = len(weights)
    sign = -1 if total < 0 else 1
    t = abs(total)
    floors, rems = [], []
    for w in weights:
        num = t * w
        floors.append(num // W)
        rems.append(num % W)
    leftover = t - sum(floors)
    order = sorted(range(len(weights)), key=lambda i: (-rems[i], i))
    for k in range(leftover):
        floors[order[k]] += 1
    return [sign * f for f in floors]


# ---------------------------------------------------------------------------
# shares
# ---------------------------------------------------------------------------

def max_shares(animal_kind):
    """Max shares the animal kind supports (7 for large, 1 for small)."""
    return ANIMAL_SHARES.get(str(animal_kind or "").lower(), 7)


def validate_plan(plan):
    """Validation codes for a plan before it is stored."""
    problems = []
    kind = str(plan.get("animal") or "").lower()
    if kind not in ANIMAL_SHARES:
        problems.append("bad_animal")
    cap = ANIMAL_SHARES.get(kind, 7)
    try:
        total = int(plan.get("total_shares") or cap)
    except (TypeError, ValueError):
        total = cap
    if total < 1 or total > cap:
        problems.append("bad_total_shares")
    if to_poisha(plan.get("cost")) <= 0:
        problems.append("cost_required")
    return problems


def validate_participant(p, shares_free):
    """Validation codes for adding a participant taking `want` shares when
    `shares_free` remain."""
    problems = []
    if not str(p.get("name") or "").strip():
        problems.append("name_required")
    raw = p.get("shares")
    if raw is None or raw == "":
        raw = 1
    try:
        want = int(raw)
    except (TypeError, ValueError):
        want = 0
    if want < 1:
        problems.append("shares_min_one")
    if want > shares_free:
        problems.append("not_enough_shares")
    return problems


def cost_per_share(total_cost, total_shares):
    """Exact-ish cost per share (poisha), rounded for DISPLAY only. The ledger
    uses the largest-remainder per-head amounts below, never this rounded value,
    so nothing drifts. 0 shares -> 0 (not an error)."""
    total = to_poisha(total_cost)
    n = max(0, int(total_shares or 0))
    if n == 0:
        return 0
    base, rem = divmod(abs(total), n)
    val = base + (1 if rem * 2 >= n else 0)  # round half up for display
    return -val if total < 0 else val


def participant_costs(total_cost, total_shares, participants):
    """Each participant's EXACT cost (poisha) for the shares they hold,
    distributed by largest remainder so the per-head amounts sum EXACTLY to the
    animal cost scaled to the shares taken.

    participants: [{'id'|'name', 'name', 'shares'}].
    Returns [{'id','name','shares','cost','cost_display'}]. Unfilled shares are
    NOT charged to anyone — only the taken shares' cost is distributed, so the
    sum equals (taken_shares / total_shares) of the animal cost, exactly.
    """
    total = to_poisha(total_cost)
    n = max(1, int(total_shares or 1))
    taken = sum(max(0, int(p.get("shares") or 0)) for p in participants)
    # the taken portion of the animal cost, as exact integer poisha
    taken_cost = _largest_remainder(total, [taken, n - taken])[0] if 0 < taken < n \
        else (total if taken >= n else 0)
    weights = [max(0, int(p.get("shares") or 0)) for p in participants]
    amounts = _largest_remainder(taken_cost, weights) if taken > 0 else [0] * len(participants)
    rows = []
    for p, amt in zip(participants, amounts):
        rows.append({
            "id": _pid(p),
            "name": p.get("name", ""),
            "shares": max(0, int(p.get("shares") or 0)),
            "cost": amt,
            "cost_display": fmt_poisha(amt),
        })
    return rows


def _pid(p):
    v = p.get("id", p.get("member"))
    return v if v is not None else p.get("name")


# ---------------------------------------------------------------------------
# meat distribution — the traditional three parts (neutral)
# ---------------------------------------------------------------------------

def distribute_meat(total_grams, weights=None):
    """Split the usable meat (INTEGER GRAMS) into the three traditional parts
    (family / relatives / poor) by `weights` (default equal thirds). Parts sum
    EXACTLY to the total — no gram lost. Returns
    [{'part','grams','kg_display'}] in DIST_PARTS order.

    `weights` may be a dict keyed by part name or a 3-list in DIST_PARTS order.
    Presented NEUTRALLY; the default is the customary equal thirds, editable by
    the user. No ruling is implied.
    """
    g = max(0, int(total_grams or 0))
    if weights is None:
        w = [DEFAULT_DISTRIBUTION[p] for p in DIST_PARTS]
    elif isinstance(weights, dict):
        w = [max(0, int(weights.get(p, 0) or 0)) for p in DIST_PARTS]
    else:
        w = [max(0, int(x or 0)) for x in list(weights)[:3]]
        w += [0] * (3 - len(w))
    parts = _largest_remainder(g, w)
    out = []
    for name, grams in zip(DIST_PARTS, parts):
        out.append({
            "part": name,
            "grams": grams,
            "kg_display": _kg(grams),
        })
    return out


def _kg(grams):
    """Grams -> 'X.YZ kg' style string (kg to 2 dp). Pure arithmetic; 'kg' is a
    unit token, not translatable prose."""
    grams = int(grams)
    kg, g = divmod(grams, 1000)
    return f"{_group(kg)}.{g // 10:02d} kg"


# ---------------------------------------------------------------------------
# checklist progress
# ---------------------------------------------------------------------------

# Canonical planning checklist steps (stable keys; UI label localised by key).
CHECKLIST_STEPS = (
    "animal_chosen",   # animal selected / booked
    "shares_filled",   # all shares taken
    "cost_collected",  # everyone paid their share
    "butcher_booked",  # butcher / slaughter arranged
    "storage_ready",   # fridge / deep-freeze / ice ready
    "distribution",    # three-part distribution done
)


def checklist_progress(done_keys):
    """Fraction of the canonical checklist completed. `done_keys` is any
    iterable of step keys the user has ticked. Returns
    {'done','total','pct','complete'}. Unknown keys are ignored."""
    done = {k for k in (done_keys or []) if k in CHECKLIST_STEPS}
    total = len(CHECKLIST_STEPS)
    n = len(done)
    pct = round(100 * n / total) if total else 0
    return {"done": n, "total": total, "pct": pct, "complete": n == total}


# ---------------------------------------------------------------------------
# the full plan summary — the one function the screen mirrors
# ---------------------------------------------------------------------------

def plan_summary(plan, participants, lang="bn"):
    """Reconcile one Qurbani plan.

    plan: {'animal','total_shares','cost','meat_kg'?,'distribution'?,'done'?}
    participants: [{'id'|'name','name','shares'}]

    Returns a deterministic dict with cost-per-share, per-participant costs,
    shares taken/free, the three-part meat plan, checklist progress and a
    bilingual honesty note.
    """
    kind = str(plan.get("animal") or "cow").lower()
    cap = ANIMAL_SHARES.get(kind, 7)
    try:
        total_shares = int(plan.get("total_shares") or cap)
    except (TypeError, ValueError):
        total_shares = cap
    total_shares = max(1, min(cap, total_shares))
    cost = to_poisha(plan.get("cost"))

    taken = sum(max(0, int(p.get("shares") or 0)) for p in participants)
    free = max(0, total_shares - taken)

    cps = cost_per_share(cost, total_shares)
    rows = participant_costs(cost, total_shares, participants)
    collected = sum(r["cost"] for r in rows)

    meat_g = int(round(float(plan.get("meat_kg") or 0) * 1000))
    meat = distribute_meat(meat_g, plan.get("distribution"))

    progress = checklist_progress(plan.get("done") or [])

    return {
        "animal": kind,
        "total_shares": total_shares,
        "max_shares": cap,
        "cost": cost,
        "cost_display": fmt_poisha(cost),
        "cost_per_share": cps,
        "cost_per_share_display": fmt_poisha(cps),
        "shares_taken": taken,
        "shares_free": free,
        "full": free == 0,
        "over": taken > total_shares,
        "participants": rows,
        "collected": collected,
        "collected_display": fmt_poisha(collected),
        "meat_total_g": meat_g,
        "meat_total_kg_display": _kg(meat_g),
        "meat_plan": meat,
        "checklist": progress,
        "note": {
            "bn": "ভাগ আর খরচ নিখুঁতভাবে ভাগ করা হয়েছে; অ্যাপ কোনো টাকা রাখে না "
                  "আর কোনো পশু রাখে না — এটি শুধু আপনাকে পরিকল্পনায় সাহায্য করে। "
                  "মাংসের তিন ভাগ (পরিবার/আত্মীয়/গরিব) প্রচলিত রীতি, আপনি বদলাতে পারেন।",
            "en": "Shares and cost are split exactly; the app holds no money and "
                  "no animal — it only helps you plan. The three-part meat split "
                  "(family/relatives/poor) is the customary practice and you can "
                  "adjust it.",
        },
    }
