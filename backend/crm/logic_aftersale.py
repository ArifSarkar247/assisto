"""
AFTER-SALE — PURE LOGIC (spec §7).

No Django, no I/O, no network. Covers:
  * installment / collection tracking (cash / cheque / bank; BOOKED vs COLLECTED)
  * AMC & renewal date maths + reminder scheduling
  * complaints log state machine
  * upsell opportunity scoring (no invented revenue — all amounts passed in)
  * Axon ERP implementation hand-off record (DESIGN/LINK ONLY — this module
    NEVER touches Asalify/ERP; it only assembles the hand-off descriptor the
    integrator will post once the ERP link is connected)

MONEY is integer **poisha** everywhere (1 BDT = 100 poisha) — no float drift.
Dates are passed as day ordinals (date.toordinal()) so the logic is pure and
hand-verifiable; the view converts real dates at the edge.

HARD RULE: no amount is ever invented. Installment amounts, collected amounts
and upsell values all come IN from the owner / signed order. We only add,
subtract and compare integers.
"""


# ---------------------------------------------------------------------------
# Collection schedule + outstanding (booked vs collected)
# ---------------------------------------------------------------------------
def build_installment_schedule(total_poisha, count, first_due_ordinal,
                               interval_days=30):
    """Split an order total into `count` equal installments in integer poisha.

    The split is EXACT: every installment is total//count, and the remainder
    poisha (total % count) is added to the LAST installment so Σ == total with
    zero drift (never a fractional poisha, never a rounding gap). `count` must be
    ≥ 1. Due dates step by `interval_days`. Pure.
    """
    if count < 1:
        raise ValueError("count must be >= 1")
    if total_poisha < 0:
        raise ValueError("total cannot be negative")
    base = total_poisha // count
    remainder = total_poisha - base * count
    schedule = []
    for i in range(count):
        amt = base + (remainder if i == count - 1 else 0)
        schedule.append({
            "seq": i + 1,
            "amount_poisha": amt,
            "due_ordinal": first_due_ordinal + i * interval_days,
            "booked": True,       # booked == scheduled/expected
            "collected_poisha": 0,
        })
    return schedule


def _method_ok(method):
    return method in ("cash", "cheque", "bank")


def apply_collection(installment, amount_poisha, method):
    """Record a collection against ONE installment (cash/cheque/bank).

    Returns a NEW installment dict (no mutation) with `collected_poisha`
    increased and a `status` of scheduled / partial / collected / overpaid.
    Rejects an unknown payment method and a negative amount — we never fabricate
    a payment. Pure.
    """
    if not _method_ok(method):
        raise ValueError(f"unknown method {method!r} (cash/cheque/bank only)")
    if amount_poisha < 0:
        raise ValueError("collected amount cannot be negative")
    collected = installment.get("collected_poisha", 0) + amount_poisha
    due = installment["amount_poisha"]
    if collected == 0:
        status = "scheduled"
    elif collected < due:
        status = "partial"
    elif collected == due:
        status = "collected"
    else:
        status = "overpaid"
    out = dict(installment)
    out["collected_poisha"] = collected
    out["status"] = status
    out["last_method"] = method
    return out


def collection_summary(schedule, today_ordinal):
    """Roll up a schedule into booked / collected / outstanding / overdue totals.

    All integer poisha. `overdue_poisha` is the uncollected part of installments
    whose due date has passed. Pure.
    """
    booked = collected = outstanding = overdue = 0
    overdue_count = 0
    for inst in schedule:
        due_amt = inst["amount_poisha"]
        got = inst.get("collected_poisha", 0)
        booked += due_amt
        collected += min(got, due_amt)   # overpayment doesn't inflate "collected of booked"
        remaining = max(0, due_amt - got)
        outstanding += remaining
        if remaining > 0 and inst["due_ordinal"] < today_ordinal:
            overdue += remaining
            overdue_count += 1
    return {
        "booked_poisha": booked,
        "collected_poisha": collected,
        "outstanding_poisha": outstanding,
        "overdue_poisha": overdue,
        "overdue_count": overdue_count,
        "fully_collected": outstanding == 0 and booked > 0,
    }


# ---------------------------------------------------------------------------
# AMC & renewal dates + reminder scheduling
# ---------------------------------------------------------------------------
def amc_renewal_ordinal(start_ordinal, term_days=365):
    """The renewal/expiry day of an AMC that started on `start_ordinal` for
    `term_days` (default a 365-day year). Pure arithmetic."""
    if term_days <= 0:
        raise ValueError("term_days must be positive")
    return start_ordinal + term_days


def renewal_status(renewal_ordinal, today_ordinal, reminder_lead_days=30):
    """Classify an AMC/subscription relative to today:
       active / due_soon / due_today / overdue.
    `due_soon` begins `reminder_lead_days` before renewal. Pure.
    """
    delta = renewal_ordinal - today_ordinal
    if delta > reminder_lead_days:
        state = "active"
    elif delta > 0:
        state = "due_soon"
    elif delta == 0:
        state = "due_today"
    else:
        state = "overdue"
    return {"state": state, "days_to_renewal": delta,
            "needs_reminder": state in ("due_soon", "due_today", "overdue")}


def reminder_schedule(renewal_ordinal, lead_days=(30, 7, 1)):
    """The ordinal days on which to fire renewal reminders (default 30/7/1 days
    before). Deterministic, sorted ascending, de-duplicated. The integrator
    turns these into the app's foreground/notification reminders — NOTE:
    WorkManager is banned (see memory), so reminders surface on app open/resume.
    """
    days = sorted({int(d) for d in lead_days if d >= 0}, reverse=True)
    return [renewal_ordinal - d for d in days]


# ---------------------------------------------------------------------------
# Complaints log — state machine
# ---------------------------------------------------------------------------
# A support complaint moves through these states; only these transitions are
# legal (so a resolved complaint can't silently reopen without an action, and a
# closed one is terminal).
_COMPLAINT_TRANSITIONS = {
    "open": {"acknowledge", "resolve", "cancel"},
    "acknowledged": {"start", "resolve", "cancel"},
    "in_progress": {"resolve", "cancel"},
    "resolved": {"close", "reopen"},
    "closed": set(),       # terminal
    "cancelled": set(),    # terminal
}
_COMPLAINT_ACTION_TO_STATE = {
    "acknowledge": "acknowledged", "start": "in_progress",
    "resolve": "resolved", "close": "closed", "reopen": "open",
    "cancel": "cancelled",
}

# Priority → target resolution SLA in days (owner-tunable upstream; these are the
# defaults, not invented promises to a customer).
_SLA_DAYS = {"urgent": 1, "high": 2, "normal": 5, "low": 10}


def complaint_transition(current_state, action):
    """Advance a complaint. Raises ValueError on an illegal move. Pure."""
    allowed = _COMPLAINT_TRANSITIONS.get(current_state)
    if allowed is None:
        raise ValueError(f"unknown complaint state: {current_state}")
    if action not in allowed:
        raise ValueError(f"illegal complaint action {action!r} from "
                         f"{current_state!r}")
    return _COMPLAINT_ACTION_TO_STATE[action]


def complaint_sla(priority, opened_ordinal, today_ordinal, state):
    """Is an OPEN/in-flight complaint within its SLA? Returns due day + breach
    flag. A resolved/closed/cancelled complaint is never 'breached' going
    forward. Pure."""
    sla = _SLA_DAYS.get(priority, _SLA_DAYS["normal"])
    due = opened_ordinal + sla
    inflight = state in ("open", "acknowledged", "in_progress")
    breached = inflight and today_ordinal > due
    return {"sla_days": sla, "due_ordinal": due, "breached": breached,
            "days_left": due - today_ordinal if inflight else None}


# ---------------------------------------------------------------------------
# Upsell opportunities
# ---------------------------------------------------------------------------
def upsell_signals(*, owned_module_codes, catalog_module_codes,
                   amc_state=None, outstanding_poisha=0):
    """Surface honest upsell signals — NO invented revenue.

    `owned_module_codes` = modules the customer already bought;
    `catalog_module_codes` = everything on offer. The gap is a candidate upsell
    list (modules not yet owned). We also flag a RENEWAL upsell when the AMC is
    due_soon/overdue, and SUPPRESS upsell when there is outstanding collection
    (don't upsell a customer who hasn't paid). Pure — the owner sets prices
    elsewhere; we never attach a price here.
    """
    owned = set(owned_module_codes or [])
    catalog = [c for c in (catalog_module_codes or []) if c not in owned]
    signals = []
    for code in catalog:
        signals.append({"kind": "cross_sell_module", "module": code})
    if amc_state in ("due_soon", "due_today", "overdue"):
        signals.append({"kind": "amc_renewal", "amc_state": amc_state})
    return {
        "candidates": catalog,
        "signals": signals,
        "suppressed": outstanding_poisha > 0,   # don't upsell an unpaid account
        "suppress_reason": ("outstanding_balance" if outstanding_poisha > 0
                            else None),
    }


# ---------------------------------------------------------------------------
# Axon ERP implementation hand-off (DESIGN/LINK ONLY — never touches ERP)
# ---------------------------------------------------------------------------
# Hand-off stages for an won deal moving into ERP implementation. This module
# only models the record + legal transitions; it NEVER posts to Asalify/ERP.
_HANDOFF_TRANSITIONS = {
    "not_started": {"prepare"},
    "preparing": {"submit"},
    "submitted": {"accept", "reject"},   # ERP side accepts/rejects the package
    "accepted": {"complete"},
    "rejected": {"prepare"},             # fix and resubmit
    "completed": set(),                  # terminal
}
_HANDOFF_ACTION_TO_STATE = {
    "prepare": "preparing", "submit": "submitted", "accept": "accepted",
    "reject": "rejected", "complete": "completed",
}


def handoff_transition(current_state, action):
    """Advance the ERP implementation hand-off record. Pure, no ERP call."""
    allowed = _HANDOFF_TRANSITIONS.get(current_state)
    if allowed is None:
        raise ValueError(f"unknown handoff state: {current_state}")
    if action not in allowed:
        raise ValueError(f"illegal handoff action {action!r} from "
                         f"{current_state!r}")
    return _HANDOFF_ACTION_TO_STATE[action]


def build_handoff_record(*, deal_id, company_name, module_codes,
                         order_total_poisha, erp_link_connected=False):
    """Assemble the implementation hand-off DESCRIPTOR (design/link only).

    When `erp_link_connected` is False we return a `needs_erp_link` state — we
    NEVER pretend the ERP received anything. This mirrors the honest needs-key
    pattern used across the CRM. No network, no Asalify touch.
    """
    return {
        "object": "erp_handoff",
        "deal_id": deal_id,
        "company": company_name,
        "modules": list(module_codes or []),
        "order_total_poisha": order_total_poisha,
        "state": "not_started",
        "transport": "mock",   # explicit: nothing is sent to ERP from here
        "erp_state": "linked" if erp_link_connected else "needs_erp_link",
        "note": ("ERP link connected — integrator posts this package" if
                 erp_link_connected else
                 "ERP not connected — hand-off saved locally, NOT sent; "
                 "Asalify/ERP untouched"),
    }
