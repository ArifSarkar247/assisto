"""
Requirement sheet → quotation/proposal totals (spec §5).

HARD RULE: this module NEVER invents a price or a tax rate. Every line amount is
read from a `Product` (the owner-configured price book). If a product's
`price_reviewed` flag is False, the whole quote is flagged
`prices_reviewed=False` and the UI/PDF stamp it "TO REVIEW BY OWNER / মালিকের
পর্যালোচনা বাকি". The tax rate is a per-call input (default 0) — we do not
assume Bangladesh VAT; the owner must set it.

Discounts beyond an org-configured threshold set `discount_needs_approval=True`
so a manager must approve before the proposal can be sent (approval workflow in
webviews).
"""
from decimal import Decimal, ROUND_HALF_UP

from .models import Product, Proposal

# Any discount strictly above this % needs manager approval before sending.
DISCOUNT_APPROVAL_THRESHOLD = Decimal("10")


def _money(x):
    return Decimal(x or 0).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def build_line_items(org, selections):
    """`selections` = [{"sku": "...", "qty": n}, ...].

    Returns (line_items, all_reviewed). Each line_item carries the price book
    amount; a missing/unknown SKU is skipped (never guessed). `all_reviewed` is
    False if ANY product used is not yet owner-reviewed.
    """
    items = []
    all_reviewed = True
    skus = [s.get("sku") for s in selections if s.get("sku")]
    products = {p.sku: p for p in Product.objects.filter(org=org, sku__in=skus, active=True)}
    for sel in selections:
        p = products.get(sel.get("sku"))
        if not p:
            continue
        qty = max(1, int(sel.get("qty") or 1))
        amount = _money(p.unit_price * qty)
        if not p.price_reviewed:
            all_reviewed = False
        items.append({
            "sku": p.sku,
            "label": p.name,
            "billing": p.billing,
            "qty": qty,
            "unit_price": float(_money(p.unit_price)),
            "amount": float(amount),
            "price_reviewed": p.price_reviewed,
        })
    return items, all_reviewed


def compute_totals(line_items, discount_pct=0, tax_pct=0):
    """Subtotal → discount → tax → total. All inputs explicit; tax_pct defaults
    to 0 (the owner must set any VAT — we never assume a rate)."""
    subtotal = sum((_money(li["amount"]) for li in line_items), Decimal(0))
    discount_pct = Decimal(discount_pct or 0)
    tax_pct = Decimal(tax_pct or 0)
    discount_amount = _money(subtotal * discount_pct / Decimal(100))
    taxable = subtotal - discount_amount
    tax_amount = _money(taxable * tax_pct / Decimal(100))
    total = _money(taxable + tax_amount)
    return {
        "subtotal": subtotal,
        "discount_pct": discount_pct,
        "discount_amount": discount_amount,
        "tax_pct": tax_pct,
        "tax_amount": tax_amount,
        "total": total,
        "needs_discount_approval": discount_pct > DISCOUNT_APPROVAL_THRESHOLD,
    }


def make_quote(lead, selections, requirements="", discount_pct=0, tax_pct=0,
               title="", created_by=None, deal=None, body=""):
    """Create a Proposal row with price-book line items + computed totals.

    Returns the Proposal. Never invents money: all amounts come from the price
    book; tax_pct is whatever the caller passed (0 unless owner sets it).
    """
    org = lead.org
    line_items, all_reviewed = build_line_items(org, selections or [])
    totals = compute_totals(line_items, discount_pct, tax_pct)

    # Next version number for this lead's proposals.
    last = lead.proposals.order_by("-version").first()
    version = (last.version + 1) if last else 1

    prop = Proposal.objects.create(
        lead=lead, deal=deal, version=version,
        title=title or f"Axon ERP Proposal — {lead.company or lead.name or 'Prospect'}",
        body=body, requirements=requirements or "",
        line_items=line_items,
        subtotal=totals["subtotal"],
        discount_pct=totals["discount_pct"],
        discount_amount=totals["discount_amount"],
        tax_pct=totals["tax_pct"],
        tax_amount=totals["tax_amount"],
        total=totals["total"],
        prices_reviewed=all_reviewed,
        discount_needs_approval=totals["needs_discount_approval"],
        status=Proposal.PENDING if totals["needs_discount_approval"] else Proposal.DRAFT,
        created_by=created_by,
    )
    return prop
