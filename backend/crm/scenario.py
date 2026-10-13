"""
AXON 30-day sales-month scenario (spec SCENARIO). Plain asserts — NOT run here.

Simulates a realistic month for AXON's own sales team:
  - 20 leads captured (mixed industries/sizes/sources),
  - 8 deals created in the pipeline with real BDT values + probabilities,
  - proposals built from the price book (prices owner-set, never invented),
  - 2 deals WON, 3 deals LOST (with mandatory loss reasons),
  - verifies the pipeline board, weighted forecast and the reports
    (funnel / win-loss / sales-cycle / source attribution) come out correct.

Run manually later (the owner/integrator runs this, not us), e.g.:

    python manage.py shell -c "from crm.scenario import run; run()"

or wire the management command `crm/management/commands/crm_scenario.py`
(also provided). It creates an isolated throwaway org so it never touches real
tenant data; call run(cleanup=True) to delete it afterwards.
"""
from datetime import timedelta
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.utils import timezone

from . import pipeline as pl
from . import forecast as fc
from . import reports as rp
from . import quoting
from . import logic as core_logic
from .models import (CrmOrg, CrmMember, Lead, Product, Deal, Proposal,
                     Company)


def _user():
    U = get_user_model()
    u = U.objects.filter(username="axon_scenario").first()
    if not u:
        u = U.objects.create_user(name="Axon Scenario", phone="01999000111",
                                   password="scenario-not-for-login")
        u.username = "axon_scenario"; u.save(update_fields=["username"])
    return u


def run(cleanup=False):
    """Build the month, run the asserts, return a summary dict."""
    owner = _user()
    org = CrmOrg.objects.create(name="AXON Sales (scenario)", owner=owner)
    member = CrmMember.objects.create(org=org, user=owner, role=CrmMember.OWNER)
    pipe = pl.ensure_default_pipeline(org)
    stages = {s.name.split(" / ")[0].strip(): s for s in pipe.stages.all()}
    # resolve by win/lost flags too (robust to label wording)
    won_stage = pipe.stages.filter(is_won=True).first()
    lost_stage = pipe.stages.filter(is_lost=True).first()
    first_stage = pipe.stages.order_by("order").first()

    # Owner-reviewed price book (prices are examples the owner set, not invented
    # by the CRM — in real use the owner enters these in the Price book page).
    Product.objects.create(org=org, sku="ERP-CORE", name="Axon ERP Core",
                           unit_price=Decimal("250000"), price_reviewed=True)
    Product.objects.create(org=org, sku="ERP-HR", name="HR & Payroll Module",
                           unit_price=Decimal("80000"), price_reviewed=True)
    Product.objects.create(org=org, sku="ERP-SEAT", name="User seat",
                           unit_price=Decimal("3000"), billing=Product.PER_USER,
                           price_reviewed=True)

    # ---- 20 leads (mixed) ----
    strong_msg = ("আমাদের গার্মেন্টসের জন্য ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে, "
                  "দাম ও মডিউল জানান, ডেমো চাই")
    leads = []
    specs = [
        ("rmg", 600, "whatsapp", strong_msg),
        ("pharma", 300, "linkedin", "ERP module price quote লাগবে"),
        ("retail", 120, "email", "দাম জানতে চাই"),
        ("rmg", 800, "whatsapp", strong_msg),
        ("other", 15, "manual", "হাই"),
        ("pharma", 220, "messenger", "proposal চাই, budget আছে"),
        ("retail", 40, "whatsapp", "দরকার একটা erp"),
        ("rmg", 500, "linkedin", strong_msg),
    ]
    for i in range(20):
        ind, size, src, msg = specs[i % len(specs)]
        lead = core_logic.capture_lead(
            org=org, source=src,
            contact={"phone": f"0171000{1000+i}", "email": f"lead{i}@ex.com"},
            first_message=msg, name=f"Lead {i}", company=f"Company {i}",
            industry=ind, company_size=size, assigned_to=member)
        leads.append(lead)

    # At least the strong RMG leads should be high priority (deterministic).
    strong_leads = [l for l in leads if l.industry == "rmg" and l.company_size >= 500]
    assert all(l.score >= 90 and l.priority == "high" for l in strong_leads), \
        "strong RMG leads must score >=90 high"
    assert any(l.priority == "normal" for l in leads), "weak leads must stay normal"

    # ---- 8 deals ----
    deals = []
    values = [1200000, 900000, 500000, 750000, 300000, 650000, 400000, 850000]
    probs = [80, 70, 45, 65, 25, 80, 45, 70]
    today = timezone.now().date()
    for i in range(8):
        d = Deal.objects.create(
            org=org, title=f"Axon ERP — {leads[i].company}", pipeline=pipe,
            stage=first_stage, lead=leads[i], owner=member,
            value=Decimal(values[i]), probability=probs[i],
            expected_close=today + timedelta(days=10 + i),
            source=leads[i].source, next_step="Follow up call",
            next_step_due=today + timedelta(days=2))
        deals.append(d)

    # ---- proposals from the price book (no invented prices) ----
    for i in range(4):
        prop = quoting.make_quote(
            leads[i], [{"sku": "ERP-CORE", "qty": 1}, {"sku": "ERP-SEAT", "qty": 50}],
            requirements="VAT-compliant ERP for RMG", discount_pct=5, tax_pct=0,
            created_by=member, deal=deals[i])
        # subtotal = 250000 + 50*3000 = 400000; 5% discount = 20000; total 380000
        assert prop.subtotal == Decimal("400000.00"), prop.subtotal
        assert prop.discount_amount == Decimal("20000.00"), prop.discount_amount
        assert prop.total == Decimal("380000.00"), prop.total
        assert prop.prices_reviewed is True, "all products owner-reviewed"
        assert prop.discount_needs_approval is False, "5% is under threshold"

    # A 15% discount must trigger the approval workflow.
    big = quoting.make_quote(leads[0], [{"sku": "ERP-CORE", "qty": 1}],
                             discount_pct=15, created_by=member)
    assert big.discount_needs_approval is True
    assert big.status == Proposal.PENDING

    # ---- 2 WON ----
    for i in (0, 5):
        pl.move_deal(deals[i], won_stage, member=member)
        deals[i].refresh_from_db()
        assert deals[i].state == "won" and deals[i].closed_at is not None

    # ---- 3 LOST (mandatory reason) ----
    for idx, reason in ((4, "no_budget"), (2, "price"), (6, "competitor")):
        deals[idx].loss_reason = reason
        deals[idx].save(update_fields=["loss_reason"])
        pl.move_deal(deals[idx], lost_stage, member=member)
        deals[idx].refresh_from_db()
        assert deals[idx].state == "lost" and deals[idx].loss_reason == reason

    # ---- verify pipeline / forecast / reports ----
    all_deals = Deal.objects.filter(org=org)
    open_deals = all_deals.filter(state="open")
    assert open_deals.count() == 3, open_deals.count()  # 8 - 2 won - 3 lost

    f = fc.weighted_forecast(all_deals)
    assert f["has_data"] is True
    # weighted = Σ value*prob/100 over the 3 OPEN deals (indices 1,3,7)
    expected_weighted = sum(Decimal(values[i]) * probs[i] / 100 for i in (1, 3, 7))
    assert abs(Decimal(str(f["weighted"])) - expected_weighted) < Decimal("1"), \
        (f["weighted"], expected_weighted)

    wl = rp.win_loss(all_deals)
    assert wl["won"] == 2 and wl["lost"] == 3 and wl["total_closed"] == 5
    assert wl["win_rate"] == 40.0, wl["win_rate"]

    sc = rp.sales_cycle(all_deals)
    assert sc["has_data"] is True and sc["sample"] == 2

    sa = rp.source_attribution(all_deals)
    assert sa["has_data"] is True  # 2 won deals have a source

    fn = rp.funnel(pipe, all_deals)
    assert fn["has_data"] is True and len(fn["rows"]) == pipe.stages.count()

    summary = {
        "org_id": org.id, "leads": len(leads), "deals": len(deals),
        "won": wl["won"], "lost": wl["lost"], "win_rate": wl["win_rate"],
        "weighted_forecast": f["weighted"], "open_deals": open_deals.count(),
        "avg_cycle_days": sc["avg_days"],
    }

    if cleanup:
        _purge_org(org)
    return summary


def _purge_org(org):
    """Delete all rows for a scenario org in dependency order (several FKs to
    CrmOrg are on_delete=PROTECT, so a bare org.delete() is refused)."""
    from . import models as M
    from django.db import connection
    for name in ["Activity", "Mention", "Proposal", "Deal", "Stage", "Pipeline",
                 "TaggedItem", "Tag", "CustomFieldDef", "Target", "RoutingRule",
                 "Territory", "Product", "Cadence", "CadenceStep", "AuditEntry",
                 "Message", "Conversation", "Lead", "Contact", "Company", "CrmMember"]:
        Model = getattr(M, name, None)
        if Model is None:
            continue
        try:
            Model.objects.filter(org=org).delete()
        except Exception:
            pass
    org.delete()


if __name__ == "__main__":  # pragma: no cover
    print(run())
