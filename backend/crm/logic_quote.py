"""
QUOTES / PROPOSALS — advanced PURE LOGIC (spec §6).

No Django, no I/O, no network. Every function here is deterministic and
hand-verifiable; the integrator wires these into views/models separately.

HARD RULES (the whole point of this module):
  * NEVER invent a price or a tax rate. Every line amount is passed IN (it comes
    from the owner-configured Product / price list upstream, or is owner-typed).
    The tax rate is NOT hardcoded to any %; it is an explicit input and, when a
    quote carries any unreviewed line, the whole quote is flagged
    `prices_reviewed=False` and stamped TO-REVIEW. `tax_review_required` is True
    whenever a non-zero tax is applied without the owner confirming the rate.
  * NO FLOAT DRIFT. All money is INTEGER POISHA (1 BDT = 100 poisha). We never
    use float for money; percentages use Fraction so e.g. 7.5% is exact. All
    rounding is explicit, half-up, at the single documented point (per-total,
    not per-line accumulation of fractional poisha).
  * Discount-approval threshold is a RULE, not a guess: any discount strictly
    above the org threshold needs manager approval before the quote can leave
    draft/pending.

Money representation
--------------------
Amounts are integer **poisha** everywhere inside this module. Convert at the
edge with `taka_to_poisha` / `poisha_to_taka_str`. Line `unit_poisha` and `qty`
are integers; a quote's subtotal is Σ(unit_poisha × qty) with NO rounding (exact
integers). Discount and tax are the only places a fraction appears, and we round
ONCE, half-up, to whole poisha.
"""
from decimal import Decimal, ROUND_HALF_UP
from fractions import Fraction

# Any discount percent STRICTLY greater than this needs manager approval before
# the quote can advance past draft/pending. The owner may override per-org by
# passing `threshold_pct` into the relevant calls — this is only the default.
DEFAULT_DISCOUNT_APPROVAL_THRESHOLD_PCT = 10


# ---------------------------------------------------------------------------
# Money conversion (edge helpers — integer poisha is the internal unit)
# ---------------------------------------------------------------------------
def taka_to_poisha(amount):
    """Convert an owner-entered/price-book BDT amount to integer poisha.

    Accepts int, str ("1500.50"), Decimal or float (the float path still goes
    through Decimal(str(x)) so there is no binary-float drift). NEVER invents a
    value — `None` is a hard error, not a silent 0, because a missing price must
    surface, not be guessed.
    """
    if amount is None:
        raise ValueError("amount is required — the price must come from the "
                         "price list or the owner, never be guessed")
    d = amount if isinstance(amount, Decimal) else Decimal(str(amount))
    return int((d * 100).to_integral_value(rounding=ROUND_HALF_UP))


def poisha_to_taka_str(poisha):
    """Integer poisha → a plain '1234.56' BDT string (no symbol, no thousands
    separators — presentation is the UI's job). Exact, no float."""
    sign = "-" if poisha < 0 else ""
    p = abs(int(poisha))
    return f"{sign}{p // 100}.{p % 100:02d}"


def _pct_fraction(pct):
    """A percent (int/str/Decimal/float) as an EXACT Fraction of 1.

    7.5 → Fraction(75, 1000) = 3/40 exactly. No float anywhere, so 7.5% of a
    price is computed exactly and rounded once.
    """
    if pct is None:
        pct = 0
    d = pct if isinstance(pct, Decimal) else Decimal(str(pct))
    # Decimal → exact Fraction via its (num, denom) tuple, then /100.
    return Fraction(d) / 100


def _round_half_up(frac):
    """Round an exact Fraction to the nearest integer poisha, half away-from-zero
    (matches ROUND_HALF_UP). Deterministic; the single rounding point for money."""
    sign = 1 if frac >= 0 else -1
    f = frac if frac >= 0 else -frac
    # floor + (remainder >= 1/2 ? 1 : 0)
    whole = f.numerator // f.denominator
    rem = f - whole
    if rem * 2 >= 1:
        whole += 1
    return sign * whole


# ---------------------------------------------------------------------------
# Totals — integer poisha, no float drift
# ---------------------------------------------------------------------------
def compute_totals(line_items, discount_pct=0, tax_pct=0,
                   threshold_pct=DEFAULT_DISCOUNT_APPROVAL_THRESHOLD_PCT,
                   tax_rate_confirmed=False):
    """Subtotal → discount → taxable → tax → total, all in integer poisha.

    `line_items` = [{"unit_poisha": int, "qty": int, "price_reviewed": bool,
                     ...}]. `unit_poisha` and `qty` are REQUIRED on each line —
    we never guess a price.

    Discount and tax percents are exact (Fraction). Rounding happens ONCE for
    discount and ONCE for tax (half-up), so there is zero accumulation drift.

    Returns a dict of integer poisha + flags. `tax_review_required` is True when
    a non-zero tax is applied but the owner has not confirmed the rate — the UI
    must stamp "tax rate TO REVIEW BY OWNER" (we DO NOT assume any VAT %).
    """
    subtotal = 0
    all_reviewed = True
    for li in line_items:
        if "unit_poisha" not in li or "qty" not in li:
            raise ValueError("each line needs unit_poisha + qty — prices are "
                             "never invented here")
        qty = int(li["qty"])
        if qty < 0:
            raise ValueError("qty cannot be negative")
        subtotal += int(li["unit_poisha"]) * qty
        if not li.get("price_reviewed", False):
            all_reviewed = False

    disc_frac = _pct_fraction(discount_pct)
    discount_poisha = _round_half_up(disc_frac * subtotal)
    if discount_poisha > subtotal:
        discount_poisha = subtotal  # a discount can never exceed the subtotal
    taxable = subtotal - discount_poisha

    tax_frac = _pct_fraction(tax_pct)
    tax_poisha = _round_half_up(tax_frac * taxable)
    total = taxable + tax_poisha

    # Decimal(str(pct)) comparison so "10.00" and 10 behave identically.
    disc_pct_dec = Decimal(str(discount_pct or 0))
    needs_discount_approval = disc_pct_dec > Decimal(str(threshold_pct))
    tax_applied = Decimal(str(tax_pct or 0)) != 0

    return {
        "subtotal_poisha": subtotal,
        "discount_pct": str(disc_pct_dec),
        "discount_poisha": discount_poisha,
        "taxable_poisha": taxable,
        "tax_pct": str(Decimal(str(tax_pct or 0))),
        "tax_poisha": tax_poisha,
        "total_poisha": total,
        "prices_reviewed": all_reviewed,
        "needs_discount_approval": needs_discount_approval,
        "threshold_pct": threshold_pct,
        # Honest tax stance: if tax was applied without the owner confirming the
        # rate, flag it for review — we never silently assume a Bangladesh VAT %.
        "tax_review_required": bool(tax_applied and not tax_rate_confirmed),
    }


# ---------------------------------------------------------------------------
# Discount-approval threshold rule
# ---------------------------------------------------------------------------
def discount_needs_approval(discount_pct,
                            threshold_pct=DEFAULT_DISCOUNT_APPROVAL_THRESHOLD_PCT):
    """True iff `discount_pct` is STRICTLY above the org threshold. Pure rule."""
    return Decimal(str(discount_pct or 0)) > Decimal(str(threshold_pct))


def approval_gate(*, totals, prices_reviewed, approved,
                  discount_approved):
    """Decide whether a quote may ADVANCE past draft/pending to approved/sent.

    Mirrors (and is the single source of truth for) the existing backend gate:
      * prices must be owner-reviewed (no unreviewed line),
      * if the discount is above threshold, a manager must have approved it.

    Returns {can_advance: bool, blockers: [codes]}. The caller maps codes to
    localized copy; we never render text here.
    """
    blockers = []
    if not prices_reviewed:
        blockers.append("prices_not_reviewed")
    if totals.get("needs_discount_approval") and not discount_approved:
        blockers.append("discount_needs_manager_approval")
    if totals.get("tax_review_required"):
        blockers.append("tax_rate_not_confirmed")
    return {"can_advance": not blockers, "blockers": blockers}


# ---------------------------------------------------------------------------
# Versions — v1 / v2 history + diff
# ---------------------------------------------------------------------------
def next_version(existing_versions):
    """Next version number given the list of existing version ints (or []).
    v1, v2, v3… never reuses or guesses. Empty → 1."""
    return (max(existing_versions) + 1) if existing_versions else 1


def version_diff(old, new):
    """Structured diff between two quote snapshots for the v1→v2 history view.

    Each snapshot = {"line_items": [{sku, qty, unit_poisha}], "total_poisha",
    "discount_pct", "tax_pct"}. Returns added/removed/changed lines (by sku) and
    the money deltas (integer poisha). Pure — no rendering.
    """
    def _by_sku(snap):
        return {li["sku"]: li for li in snap.get("line_items", [])}

    o, n = _by_sku(old), _by_sku(new)
    added = [n[s] for s in n if s not in o]
    removed = [o[s] for s in o if s not in n]
    changed = []
    for s in o:
        if s in n and (o[s].get("qty") != n[s].get("qty")
                       or o[s].get("unit_poisha") != n[s].get("unit_poisha")):
            changed.append({
                "sku": s,
                "qty_from": o[s].get("qty"), "qty_to": n[s].get("qty"),
                "unit_from": o[s].get("unit_poisha"),
                "unit_to": n[s].get("unit_poisha"),
            })
    return {
        "added": added,
        "removed": removed,
        "changed": changed,
        "total_delta_poisha": int(new.get("total_poisha", 0))
        - int(old.get("total_poisha", 0)),
        "discount_pct_from": str(Decimal(str(old.get("discount_pct", 0) or 0))),
        "discount_pct_to": str(Decimal(str(new.get("discount_pct", 0) or 0))),
    }


# ---------------------------------------------------------------------------
# Validity / expiry
# ---------------------------------------------------------------------------
def validity_until(issued_ordinal, valid_days):
    """The last ordinal day a quote is valid. `issued_ordinal` is a day number
    (e.g. date.toordinal()); `valid_days` is owner-set. None days → None (no
    expiry). Pure arithmetic, no date objects, so it is trivially testable."""
    if valid_days is None:
        return None
    if valid_days < 0:
        raise ValueError("valid_days cannot be negative")
    return issued_ordinal + valid_days


def is_expired(issued_ordinal, valid_days, today_ordinal):
    """True iff the quote's validity window has lapsed by `today_ordinal`.
    No expiry window (valid_days None) is never expired."""
    until = validity_until(issued_ordinal, valid_days)
    if until is None:
        return False
    return today_ordinal > until


def days_left(issued_ordinal, valid_days, today_ordinal):
    """Days remaining before expiry (can be negative = already lapsed). None
    when there is no expiry window — we don't invent a deadline."""
    until = validity_until(issued_ordinal, valid_days)
    if until is None:
        return None
    return until - today_ordinal


# ---------------------------------------------------------------------------
# Branded PDF — HONEST data model (no PDF lib here)
# ---------------------------------------------------------------------------
def build_pdf_model(*, quote, org_brand, pdf_lib_available=False):
    """Assemble the STRUCTURED data a branded PDF renderer would consume.

    This module does NOT render a PDF (no lib, no I/O). It returns the exact
    content model + a flag. When `pdf_lib_available` is False the caller renders
    a structured HTML/text fallback and marks it `rendered=False` so nobody
    mistakes it for a finished branded PDF — honest, never faked.

    `quote` carries pre-computed integer-poisha totals; we format to taka strings
    for display only. `org_brand` = {name, logo_ref, address, color}. We never
    inject prices — we only format the ones already computed.
    """
    lines = []
    for li in quote.get("line_items", []):
        unit = li["unit_poisha"]
        qty = int(li["qty"])
        lines.append({
            "sku": li.get("sku"),
            "label": li.get("label", li.get("sku")),
            "qty": qty,
            "unit_taka": poisha_to_taka_str(unit),
            "amount_taka": poisha_to_taka_str(unit * qty),
            "price_reviewed": li.get("price_reviewed", False),
        })
    return {
        "doc_type": "quotation",
        "rendered": bool(pdf_lib_available),
        "render_note": ("branded PDF rendered" if pdf_lib_available
                        else "NO PDF library — structured fallback; mark as "
                             "preview, not a final branded PDF"),
        "brand": {
            "name": org_brand.get("name", ""),
            "logo_ref": org_brand.get("logo_ref", ""),
            "address": org_brand.get("address", ""),
            "color": org_brand.get("color", ""),
        },
        "title": quote.get("title", ""),
        "version": quote.get("version", 1),
        "lines": lines,
        "subtotal_taka": poisha_to_taka_str(quote.get("subtotal_poisha", 0)),
        "discount_taka": poisha_to_taka_str(quote.get("discount_poisha", 0)),
        "discount_pct": str(Decimal(str(quote.get("discount_pct", 0) or 0))),
        "tax_taka": poisha_to_taka_str(quote.get("tax_poisha", 0)),
        "tax_pct": str(Decimal(str(quote.get("tax_pct", 0) or 0))),
        "total_taka": poisha_to_taka_str(quote.get("total_poisha", 0)),
        "prices_reviewed": quote.get("prices_reviewed", False),
        "tax_review_required": quote.get("tax_review_required", False),
    }


# ---------------------------------------------------------------------------
# Customer acceptance link — tokenized state machine (mock, no network)
# ---------------------------------------------------------------------------
def make_acceptance_token(*, quote_id, version, salt):
    """A deterministic, URL-safe acceptance token (MOCK — not a secret-grade
    signer; the integrator swaps in Django's signing.Signer). Pure, so tests can
    assert it. Same (quote_id, version, salt) → same token; any change → new."""
    import hashlib
    raw = f"{quote_id}:{version}:{salt}".encode()
    digest = hashlib.sha256(raw).hexdigest()[:24]
    return f"q{quote_id}v{version}-{digest}"


# Acceptance state machine: the states a tokenized link can be in and the only
# legal transitions. The customer can only view→accept or view→decline; an
# expired or revoked link can do nothing.
_ACCEPT_TRANSITIONS = {
    "issued": {"view", "revoke", "expire"},
    "viewed": {"accept", "decline", "revoke", "expire"},
    "accepted": set(),   # terminal
    "declined": set(),   # terminal
    "revoked": set(),    # terminal
    "expired": set(),    # terminal
}
_ACCEPT_ACTION_TO_STATE = {
    "view": "viewed", "accept": "accepted", "decline": "declined",
    "revoke": "revoked", "expire": "expired",
}


def acceptance_transition(current_state, action):
    """Advance the tokenized acceptance link. Returns the new state.

    Raises ValueError on an illegal transition (e.g. accept an already-declined
    link, or act on an expired one) so the server never records a bogus
    acceptance. Pure.
    """
    allowed = _ACCEPT_TRANSITIONS.get(current_state)
    if allowed is None:
        raise ValueError(f"unknown acceptance state: {current_state}")
    if action not in allowed:
        raise ValueError(f"illegal acceptance action {action!r} from "
                         f"{current_state!r}")
    return _ACCEPT_ACTION_TO_STATE[action]


def can_accept(*, link_state, is_expired_flag):
    """True iff the customer may still accept via the link right now. Honest
    gate for the mock acceptance page."""
    return link_state == "viewed" and not is_expired_flag


# ---------------------------------------------------------------------------
# Convert an accepted quote → order
# ---------------------------------------------------------------------------
def can_convert_to_order(*, status, link_state, is_expired_flag):
    """Only an ACCEPTED, non-expired quote may convert to an order. Returns
    {can_convert, blockers[]}. Pure rule — the view performs the actual write."""
    blockers = []
    if status != "accepted":
        blockers.append("quote_not_accepted")
    if link_state not in ("accepted",):
        blockers.append("acceptance_not_recorded")
    if is_expired_flag:
        blockers.append("quote_expired")
    return {"can_convert": not blockers, "blockers": blockers}


def build_order_payload(*, quote, accepted_ordinal):
    """The order draft a converted quote hands to the order module. Carries the
    SAME integer-poisha totals (no re-pricing, no new tax) + provenance. Pure."""
    return {
        "source": "quote",
        "quote_id": quote.get("id"),
        "quote_version": quote.get("version", 1),
        "lead_id": quote.get("lead_id"),
        "line_items": quote.get("line_items", []),
        "subtotal_poisha": quote.get("subtotal_poisha", 0),
        "discount_poisha": quote.get("discount_poisha", 0),
        "tax_poisha": quote.get("tax_poisha", 0),
        "total_poisha": quote.get("total_poisha", 0),
        "accepted_ordinal": accepted_ordinal,
        "status": "order_draft",   # the order module owns the next step
    }
