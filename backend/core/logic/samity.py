"""
samity.py — pure deterministic engine behind Assisto's SAMITY / COMMITTEE
tracker (feature #184, SPEC v2.1 §20, built to the §21 ADVANCED standard).

WHAT A SAMITY IS
----------------
A *samity* (সমিতি) is a rotating-savings-and-credit group (a ROSCA): a fixed
circle of MEMBERS each contribute the SAME amount every CYCLE (weekly / monthly),
and in each cycle the pooled money is handed to ONE member whose turn it is. Over
the full round every member receives the pot exactly once, so nobody lends and
nobody profits — it is a disciplined savings rotation. People run these on paper
and lose track of who has paid this cycle and whose turn is next. Assisto makes it
transparent.

This module is PURE, in the exact idiom of `payment_ladder.py` / `social.py`:
no Django, no DB, no network, no AI, and NO CLOCK of its own — any function that
needs "now" takes it as an argument. Same inputs always give the same output, so
the on-device Dart mirror (`samity_engine.dart`) produces an identical summary
offline and the self-tests can pin every number.

HARD HONESTY RULES (structural, not cosmetic)
---------------------------------------------
  * NEVER HOLDS MONEY. `holds_money()` is a constant `False`. This engine only
    TRACKS who has contributed and who has received; it custodies nothing, moves
    nothing, and charges nothing. The payout is handed over in person / by the
    members' own means — the app records that it happened.
  * TRANSPARENT MATH. Every per-cycle figure is derived from the recorded
    contributions and the fixed member list — never guessed. `collected`,
    `pending`, `expected` always reconcile: expected == collected + pending.
  * DETERMINISTIC ROTATION. The payout order is the members' own agreed order
    (their list position, or an explicit `payout_order`), never random, never
    reshuffled by the app. The engine only reports whose turn it is and who has
    already received.

MONEY is INTEGER POISHA everywhere (1 taka = 100 poisha), like the rest of the
money stack — no float arithmetic, so sums never drift. Amounts arrive as integer
`amount_poisha` (preferred) or as a taka string/number; `to_poisha` normalises
both with Decimal.

DATA SHAPES (unknown keys ignored; missing keys use safe defaults)
------------------------------------------------------------------
member = {
    "id": 1,
    "name": "Rahim",
    "payout_order": 1,          # 1-based turn; ties broken by id then name
    "active": true,             # inactive members are excluded from new cycles
}

samity = {
    "id": 10,
    "name": "Office Samity",
    "amount_poisha": 50000,     # each member's per-cycle contribution (৳500.00)
    "period": "monthly",        # weekly | biweekly | monthly  (display only here)
    "members": [member, ...],
}

contribution = {
    "member_id": 1,
    "cycle": 1,                 # 1-based cycle number
    "paid": true,               # whether this member has paid THIS cycle
    "paid_poisha": 50000,       # optional partial; defaults to the full amount
    "paid_at": "2026-02-01",    # optional record date
}

payout = {
    "cycle": 1,
    "member_id": 1,             # who received the pot this cycle
    "handed_over": true,        # the pot was physically handed over (recorded)
    "at": "2026-02-02",
}

Everything is plain stdlib and hand-verified in samity_tests_snippets.py.
"""

from decimal import Decimal, InvalidOperation

PERIODS = ("weekly", "biweekly", "monthly")
# days between cycles, for the honest "next cycle around" hint (display only;
# the engine never invents a schedule the members did not agree to)
_PERIOD_DAYS = {"weekly": 7, "biweekly": 14, "monthly": 30}


# ------------------------------------------------------------------ honesty
def holds_money():
    """This engine NEVER custodies money. Constant False — a structural promise
    the UI surfaces as a 'tracks only, never holds money' banner."""
    return False


def charges_money():
    """No function here ever moves or charges money. Constant False."""
    return False


# ------------------------------------------------------------------ amounts
def to_poisha(value):
    """Normalise an amount to integer poisha with NO float math.

    Accepts integer poisha is NOT assumed here — callers pass a taka amount
    (string/number/Decimal) OR an int already in poisha via `amount_poisha`.
    This helper only converts a *taka* value → poisha. Invalid ⇒ 0."""
    if value is None:
        return 0
    try:
        d = Decimal(str(value).strip())
    except (InvalidOperation, ValueError):
        return 0
    return int((d * 100).to_integral_value())


def _member_amount(samity):
    """The per-cycle contribution for this samity, in integer poisha."""
    if "amount_poisha" in (samity or {}):
        try:
            return max(0, int(samity["amount_poisha"]))
        except (TypeError, ValueError):
            return 0
    return to_poisha((samity or {}).get("amount"))


# ------------------------------------------------------------------ members
def active_members(samity):
    """The active members, in their agreed payout order (stable, deterministic).

    Order key: explicit `payout_order` first (1-based), then id, then name — so a
    missing/duplicate order never makes the rotation non-deterministic."""
    ms = [m for m in (samity or {}).get("members", []) if m.get("active", True)]

    def key(m):
        order = m.get("payout_order")
        has = isinstance(order, int)
        return (0 if has else 1, order if has else 0,
                m.get("id") if isinstance(m.get("id"), int) else 1 << 30,
                str(m.get("name") or ""))

    return sorted(ms, key=key)


def validate(samity):
    """Return a list of problem keys (empty ⇒ usable). The UI localises these."""
    problems = []
    s = samity or {}
    if not str(s.get("name") or "").strip():
        problems.append("name_required")
    if _member_amount(s) <= 0:
        problems.append("amount_required")
    if s.get("period") not in PERIODS:
        problems.append("bad_period")
    mem = active_members(s)
    if len(mem) < 2:
        problems.append("need_two_members")
    # a member with no name is unusable in the rotation display
    if any(not str(m.get("name") or "").strip() for m in mem):
        problems.append("member_name_required")
    seen = set()
    return [p for p in problems if not (p in seen or seen.add(p))]


# ------------------------------------------------------------- rotation
def rotation(samity):
    """The full payout rotation: one entry per active member, in turn order.

    Returns [{"cycle": 1-based, "member_id", "name", "payout_order"}...].
    Deterministic; the number of cycles in a full round == the member count."""
    out = []
    for i, m in enumerate(active_members(samity), start=1):
        out.append({
            "cycle": i,
            "member_id": m.get("id"),
            "name": m.get("name"),
            "payout_order": m.get("payout_order", i),
        })
    return out


def total_cycles(samity):
    """A full round has exactly one cycle per active member."""
    return len(active_members(samity))


def recipient_for_cycle(samity, cycle):
    """Who is SCHEDULED to receive the pot in `cycle` (1-based) by the agreed
    rotation. None if the cycle is outside the round. This is the plan; an actual
    recorded `payout` may differ and the summary reports both honestly."""
    rot = rotation(samity)
    if cycle < 1 or cycle > len(rot):
        return None
    return rot[cycle - 1]


# ------------------------------------------------- per-cycle contributions
def _contribs_for_cycle(contributions, cycle):
    by_member = {}
    for c in contributions or []:
        if c.get("cycle") == cycle:
            by_member[c.get("member_id")] = c
    return by_member


def cycle_status(samity, contributions, cycle):
    """HONEST per-cycle collected/pending summary — the heart of the tracker.

    For the given cycle, for every active member: have they paid, how much, how
    much is still due. All figures reconcile exactly:

        expected_poisha == collected_poisha + pending_poisha

    Returns:
      {
        "cycle": int,
        "per_member_poisha": int,          # the agreed contribution
        "member_count": int,
        "expected_poisha": int,            # per_member * member_count
        "collected_poisha": int,           # sum of what came in (partials counted)
        "pending_poisha": int,             # expected - collected (never < 0)
        "paid_count": int,                 # members fully paid
        "pending_count": int,              # members not fully paid
        "members": [                       # one row per active member
          {"member_id", "name", "paid": bool, "paid_poisha", "due_poisha"}
        ],
      }
    """
    per = _member_amount(samity)
    members = active_members(samity)
    by_member = _contribs_for_cycle(contributions, cycle)

    rows, collected, paid_count = [], 0, 0
    for m in members:
        c = by_member.get(m.get("id"), {})
        if "paid_poisha" in c and c.get("paid_poisha") is not None:
            try:
                paid = max(0, min(per, int(c["paid_poisha"])))
            except (TypeError, ValueError):
                paid = 0
        else:
            paid = per if c.get("paid") else 0
        fully = paid >= per and per > 0
        if fully:
            paid_count += 1
        collected += paid
        rows.append({
            "member_id": m.get("id"),
            "name": m.get("name"),
            "paid": fully,
            "paid_poisha": paid,
            "due_poisha": max(0, per - paid),
        })

    expected = per * len(members)
    return {
        "cycle": cycle,
        "per_member_poisha": per,
        "member_count": len(members),
        "expected_poisha": expected,
        "collected_poisha": collected,
        "pending_poisha": max(0, expected - collected),
        "paid_count": paid_count,
        "pending_count": len(members) - paid_count,
        "members": rows,
    }


def payout_status(samity, contributions, payouts, cycle):
    """Who was SCHEDULED to receive this cycle vs. whether a hand-over is recorded.

    Transparent, never money-moving:
      {
        "cycle": int,
        "scheduled": {member_id, name} | None,   # by the rotation
        "recorded_member_id": int | None,         # a `payout` row, if any
        "handed_over": bool,                       # recorded hand-over happened
        "fully_collected": bool,                   # the pot is complete this cycle
        "payable_poisha": int,                     # collected this cycle (the pot)
      }
    """
    sched = recipient_for_cycle(samity, cycle)
    rec = None
    for p in payouts or []:
        if p.get("cycle") == cycle:
            rec = p
            break
    cs = cycle_status(samity, contributions, cycle)
    return {
        "cycle": cycle,
        "scheduled": ({"member_id": sched["member_id"], "name": sched["name"]}
                      if sched else None),
        "recorded_member_id": (rec or {}).get("member_id"),
        "handed_over": bool((rec or {}).get("handed_over")),
        "fully_collected": cs["pending_poisha"] == 0 and cs["expected_poisha"] > 0,
        "payable_poisha": cs["collected_poisha"],
    }


# ------------------------------------------------------------- round summary
def overview(samity, contributions, payouts):
    """A whole-samity honest summary across every cycle of the round.

    Returns:
      {
        "name": str,
        "per_member_poisha": int,
        "member_count": int,
        "total_cycles": int,
        "cycles": [cycle_status(...) merged with payout_status(...) per cycle],
        "total_collected_poisha": int,     # across all recorded cycles
        "total_expected_poisha": int,      # per_member * members * cycles
        "total_pending_poisha": int,
        "payouts_done": int,               # cycles with a recorded hand-over
        "received_member_ids": [int...],   # who has already received (recorded)
        "problems": [validate(...) keys],
        "holds_money": False, "charges_money": False,   # structural honesty
      }
    """
    cycles_n = total_cycles(samity)
    per = _member_amount(samity)
    members = active_members(samity)

    cycle_rows = []
    total_collected = 0
    payouts_done = 0
    received = []
    for cy in range(1, cycles_n + 1):
        cs = cycle_status(samity, contributions, cy)
        ps = payout_status(samity, contributions, payouts, cy)
        total_collected += cs["collected_poisha"]
        if ps["handed_over"]:
            payouts_done += 1
            if ps["recorded_member_id"] is not None:
                received.append(ps["recorded_member_id"])
        cycle_rows.append({**cs, "payout": ps})

    total_expected = per * len(members) * cycles_n
    return {
        "name": (samity or {}).get("name", ""),
        "per_member_poisha": per,
        "member_count": len(members),
        "total_cycles": cycles_n,
        "cycles": cycle_rows,
        "total_collected_poisha": total_collected,
        "total_expected_poisha": total_expected,
        "total_pending_poisha": max(0, total_expected - total_collected),
        "payouts_done": payouts_done,
        "received_member_ids": received,
        "problems": validate(samity),
        "holds_money": holds_money(),
        "charges_money": charges_money(),
    }


def next_turn(samity, payouts):
    """The next member due to receive, by the rotation, skipping anyone whose
    hand-over is already recorded. None when the whole round has been paid out —
    an honest 'round complete' state for the UI. Deterministic."""
    done = {p.get("member_id") for p in (payouts or []) if p.get("handed_over")}
    for entry in rotation(samity):
        if entry["member_id"] not in done:
            return entry
    return None
