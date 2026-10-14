"""
MANDATORY AXON 30-day sales-month scenario — end-to-end, self-verifying.

This is the single "does the CRM actually add up?" test for the Axon Dynamics
sales team. It simulates ONE realistic 30-day month for AXON (an ERP vendor)
against the REAL CRM pure logic (scoring / pipeline / forecast / reports /
quoting) and the models' computed reports, then ASSERTS every report comes out
to a hand-pinned number. Nothing is fabricated: all money is integer poisha
(no float drift), all timestamps are passed in (no wall clock), everything lives
in ONE org (multi-tenant isolation is asserted — no leakage).

HOW TO RUN (standalone, no real DB — boots an in-memory SQLite):

    cd backend && python3 -c "import crm.crm_scenario as s; s.run_all()"

It prints a passed-check count. `run_all()` bootstraps Django with the test
settings (in-memory SQLite, same as `manage.py test ... settings_test`), builds
the schema, runs the scenario inside a transaction and rolls back, so it never
touches the shared Postgres or any live tenant data.

WHAT IT ASSERTS (hand-pinned — see the KEY NUMBERS block at the bottom of run()):
  * 25 leads captured across 5 business sources over 30 days (passed-in ts).
  * Deterministic scoring: strong RMG leads score >=90/high; weak leads normal.
  * Field visits logged as Activities (kind=meeting); next-steps + overdue.
  * Proposals from the price book (prices owner-set, never invented), versions,
    and the discount-approval GATE: <=10% = Draft/no-approval, >10% = Pending +
    needs_approval (and the DB-level approve/send workflow is enforced — that
    part runs as a Django test, see tests_scenario.py).
  * A close with NO loss reason is REJECTED (the view's guard, replicated as a
    pure check here + a real Django test of LeadViewSet.mark_lost / Deal.move).
  * 2 WON deals -> converted to an "order" with an installment collection
    schedule + AMC/renewal date; 3 LOST deals each with a MANDATORY reason.
  * Reports pinned: funnel drop-off per stage, win rate (2/5 = 40%), win-rate by
    SOURCE, average sales-cycle length, weighted/best/commit forecast for open
    deals, booked-vs-collected revenue (collected < booked while installments
    pending), renewal/AMC pipeline. Multi-tenant: a second org sees NOTHING.

GAPS vs the shipped backend (computed HERE, in pure helpers, because the backend
does not model them yet — flagged for the integrator):
  * Orders / installment collection schedule  -> backend has NO model (audit §7).
  * AMC / renewal dates + renewal pipeline     -> backend has NO model (audit §7).
  * Win-rate BY SOURCE                          -> reports.source_attribution only
    gives WON revenue/count by source, not win RATE (won/closed) per source.
These are pinned by `_order_from_deal`, `_collected`, `_renewal_pipeline` and
`_win_rate_by_source` below; wire them into real models when after-sale ships.
"""
from decimal import Decimal


# --------------------------------------------------------------------------- #
#  Pure helpers for the reports the BACKEND DOES NOT YET COMPUTE.              #
#  Integer poisha only (BDT * 100) so there is never float drift. A "taka"    #
#  amount like ৳1,200,000 is 120_000_000 poisha.                              #
# --------------------------------------------------------------------------- #
TAKA = 100  # poisha per taka


def _order_from_deal(value_poisha, down_pct, n_installments):
    """Convert a WON deal into an 'order' with a down payment + equal remaining
    installments. Returns (down, [installment, ...]) in poisha. The last
    installment absorbs any rounding remainder so Σ == value EXACTLY (no drift).
    """
    down = value_poisha * down_pct // 100
    rest = value_poisha - down
    base = rest // n_installments
    installments = [base] * n_installments
    installments[-1] += rest - base * n_installments   # absorb remainder
    assert down + sum(installments) == value_poisha, "order must reconcile"
    return down, installments


def _collected(down, installments, paid_count):
    """Poisha collected so far = down payment + the first `paid_count`
    installments (the rest are still scheduled / outstanding)."""
    return down + sum(installments[:paid_count])


def _win_rate_by_source(deals):
    """win-rate per SOURCE = won / (won + lost) closed deals of that source.
    `deals` is a list of dicts {source, state}. Open deals are ignored (not yet
    decided). Returns {source: {won, lost, closed, win_rate_pct|None}}."""
    out = {}
    for d in deals:
        if d["state"] not in ("won", "lost"):
            continue
        row = out.setdefault(d["source"], {"won": 0, "lost": 0})
        row[d["state"]] += 1
    for src, row in out.items():
        closed = row["won"] + row["lost"]
        row["closed"] = closed
        row["win_rate_pct"] = (round(row["won"] / closed * 100.0, 1)
                               if closed else None)
    return out


def _renewal_pipeline(orders, as_of_days, window_days=90):
    """Renewal/AMC pipeline: orders whose AMC renewal date falls within
    `window_days` of `as_of_days` are 'due soon'. Each order is
    {id, amc_renewal_day, amc_value_poisha}. Days are integer day-offsets from
    the month start (passed-in clock, never wall time). Returns the due list +
    the total AMC value coming up for renewal."""
    due = [o for o in orders
           if as_of_days <= o["amc_renewal_day"] <= as_of_days + window_days]
    total = sum(o["amc_value_poisha"] for o in due)
    return {"due": due, "due_count": len(due), "amc_value_poisha": total}


# --------------------------------------------------------------------------- #
#  The scenario itself (Django ORM — needs setup()).                          #
# --------------------------------------------------------------------------- #
def _bootstrap_django():
    """Boot Django with the test settings (in-memory SQLite) and build the
    schema, so `run_all()` works standalone from a bare `python3 -c`. Idempotent
    and safe: it NEVER touches the shared Postgres (settings_test forces SQLite
    :memory:), so no live tenant is at risk."""
    import os
    import django
    from django.conf import settings
    if not settings.configured or not os.environ.get("DJANGO_SETTINGS_MODULE"):
        os.environ.setdefault("DJANGO_SETTINGS_MODULE",
                              "assisto_backend.settings_test")
    try:
        django.setup()
    except Exception:
        pass
    # Hard guard: refuse to run against anything but in-memory SQLite.
    db = settings.DATABASES["default"]
    assert db["ENGINE"].endswith("sqlite3") and db["NAME"] in (":memory:", ""), (
        "crm_scenario must run on in-memory SQLite (settings_test), not a live DB")
    from django.core.management import call_command
    call_command("migrate", run_syncdb=True, verbosity=0)


def run(_checks=None):
    """Build the month + run every assertion against the REAL helpers.

    Returns a summary dict. `_checks` is an optional list the caller passes to
    collect a running tally; each `_ck(...)` call appends the label so run_all()
    can print the passed count. All DB writes happen inside the caller's
    transaction (rolled back by run_all) — nothing persists."""
    from datetime import timedelta
    from django.contrib.auth import get_user_model
    from django.utils import timezone

    from . import pipeline as pl
    from . import forecast as fc
    from . import reports as rp
    from . import quoting
    from . import logic as core_logic
    from . import scoring
    from .models import (CrmOrg, CrmMember, Lead, Product, Deal, Proposal,
                         Activity)

    checks = _checks if _checks is not None else []

    def _ck(cond, label):
        assert cond, "FAILED: " + label
        checks.append(label)

    U = get_user_model()

    def _mk_user(username, phone):
        u = U.objects.filter(username=username).first()
        if not u:
            u = U.objects.create_user(name=username, phone=phone,
                                      password="scenario-not-for-login")
            u.username = username
            u.save(update_fields=["username"])
        return u

    owner = _mk_user("axon_scn_owner", "01999000311")
    org = CrmOrg.objects.create(name="AXON Sales (scenario)", owner=owner)
    member = CrmMember.objects.create(org=org, user=owner, role=CrmMember.OWNER)

    # A SECOND tenant, fully populated, to prove no cross-tenant leakage.
    other_owner = _mk_user("axon_scn_other", "01999000312")
    other_org = CrmOrg.objects.create(name="Rival ERP (scenario)",
                                      owner=other_owner)
    other_member = CrmMember.objects.create(org=other_org, user=other_owner,
                                            role=CrmMember.OWNER)
    other_pipe = pl.ensure_default_pipeline(other_org)
    core_logic.capture_lead(
        org=other_org, source="whatsapp",
        contact={"phone": "01800000000", "email": "rival@ex.com"},
        first_message="দাম জানতে চাই ERP", name="Rival Lead",
        company="Rival Co", industry="rmg", company_size=900,
        assigned_to=other_member)
    Deal.objects.create(
        org=other_org, title="Rival deal", pipeline=other_pipe,
        stage=other_pipe.stages.order_by("order").first(), owner=other_member,
        value=Decimal(5000000), probability=90, source="whatsapp",
        next_step="x")

    pipe = pl.ensure_default_pipeline(org)
    st = list(pipe.stages.order_by("order"))  # New,Qual,Demo,Prop,Neg,Won,Lost
    first_stage = st[0]
    won_stage = pipe.stages.filter(is_won=True).first()
    lost_stage = pipe.stages.filter(is_lost=True).first()
    _ck(won_stage is not None and lost_stage is not None,
        "pipeline seeded with Won + Lost stages")

    # ---- Owner-reviewed price book (prices the OWNER set — never invented) ----
    Product.objects.create(org=org, sku="ERP-CORE", name="Axon ERP Core",
                           unit_price=Decimal("250000"), price_reviewed=True)
    Product.objects.create(org=org, sku="ERP-HR", name="HR & Payroll Module",
                           unit_price=Decimal("80000"), price_reviewed=True)
    Product.objects.create(org=org, sku="ERP-SEAT", name="User seat",
                           unit_price=Decimal("3000"), billing=Product.PER_USER,
                           price_reviewed=True)
    # One product the owner has NOT yet reviewed → any quote using it is flagged.
    Product.objects.create(org=org, sku="ERP-WIP", name="Unreviewed add-on",
                           unit_price=Decimal("50000"), price_reviewed=False)

    # ================================================================ #
    #  1) 25 LEADS captured across 30 days, 5 business sources, passed  #
    #     timestamps (no wall clock).                                   #
    # ================================================================ #
    month_start = timezone.now() - timedelta(days=30)

    # The model's Lead.SOURCES are whatsapp/messenger/linkedin/email/manual.
    # The brief's five business capture CHANNELS map onto them like this
    # (documented, honest — "referral"/"web form"/"Excel import" are intake
    # channels that land as the nearest modelled source):
    #   WhatsApp    -> "whatsapp"
    #   Referral    -> "manual"    (a human adds the referred lead)
    #   Web form    -> "email"     (web form posts an emailed enquiry)
    #   Manual      -> "manual"
    #   Excel       -> "manual"    (bulk import, no live channel)
    strong_msg = ("আমাদের গার্মেন্টসের জন্য ভ্যাট কমপ্লায়েন্ট ইআরপি লাগবে, "
                  "দাম ও মডিউল জানান, ডেমো চাই")
    # 25 lead specs: (industry, company_size, model_source, business_source, msg)
    specs = [
        ("rmg", 600, "whatsapp", "WhatsApp", strong_msg),
        ("rmg", 800, "whatsapp", "WhatsApp", strong_msg),
        ("rmg", 520, "linkedin", "Referral", strong_msg),
        ("pharma", 300, "linkedin", "Referral", "ERP module price quote লাগবে"),
        ("pharma", 220, "messenger", "Web form", "proposal চাই, budget আছে"),
        ("retail", 120, "email", "Web form", "দাম জানতে চাই pricing"),
        ("retail", 40, "whatsapp", "WhatsApp", "দরকার একটা erp quote"),
        ("other", 15, "manual", "Manual", "হাই"),
        ("other", 0, "manual", "Excel", "test"),
        ("rmg", 700, "whatsapp", "WhatsApp", strong_msg),
    ]
    leads = []
    sources_seen = set()
    for i in range(25):
        ind, size, msrc, bsrc, msg = specs[i % len(specs)]
        lead = core_logic.capture_lead(
            org=org, source=msrc,
            contact={"phone": f"0171000{1000 + i}", "email": f"lead{i}@ex.com"},
            first_message=msg, name=f"Lead {i}", company=f"Company {i}",
            industry=ind, company_size=size, assigned_to=member)
        # Backdate capture across the 30-day window (passed-in, deterministic).
        captured_at = month_start + timedelta(days=i % 30, hours=(i * 7) % 24)
        Lead.objects.filter(pk=lead.pk).update(created_at=captured_at)
        lead.refresh_from_db()
        lead._business_source = bsrc
        leads.append(lead)
        sources_seen.add(bsrc)

    _ck(len(leads) == 25, "25 leads captured")
    _ck(sources_seen == {"WhatsApp", "Referral", "Web form", "Manual", "Excel"},
        "leads span all 5 business sources")
    _ck(all(l.org_id == org.id for l in leads), "every lead in the one org")

    # Deterministic scoring: strong RMG(>=500) leads score >=90/high.
    strong = [l for l in leads if l.industry == "rmg" and l.company_size >= 500]
    _ck(len(strong) == 11 and all(l.score >= 90 and l.priority == "high"
                                  for l in strong),
        "strong RMG leads score >=90 / high (deterministic)")
    _ck(any(l.priority == "normal" for l in leads),
        "weak leads stay normal priority")
    # Re-scoring is reproducible (pure, no AI/network).
    r1 = scoring.base_score(industry="rmg", company_size=600,
                            inbound_texts=[strong_msg])
    r2 = scoring.base_score(industry="rmg", company_size=600,
                            inbound_texts=[strong_msg])
    _ck(r1["score"] == r2["score"] >= 90, "scoring is deterministic & reproducible")

    # ================================================================ #
    #  2) 8 DEALS (5 will close -> 2 won + 3 lost = 40% win rate;       #
    #     3 stay open for the forecast).                                #
    # ================================================================ #
    #   deal source -> business win-rate-by-source assertion later.
    src = ["whatsapp", "whatsapp", "email", "manual", "messenger",
           "whatsapp", "linkedin", "email"]
    vals = [1200000, 900000, 500000, 750000, 300000, 650000, 400000, 850000]
    probs = [80, 70, 45, 65, 25, 80, 45, 70]
    today = timezone.now().date()
    deals = []
    for i in range(8):
        d = Deal.objects.create(
            org=org, title=f"Axon ERP — {leads[i].company}", pipeline=pipe,
            stage=first_stage, lead=leads[i], owner=member,
            value=Decimal(vals[i]), probability=probs[i], source=src[i],
            expected_close=today + timedelta(days=5 + i),
            next_step="Follow up call", next_step_due=today + timedelta(days=2))
        Deal.objects.filter(pk=d.pk).update(
            created_at=month_start + timedelta(days=i))
        d.refresh_from_db()
        deals.append(d)

    # ---- Field visits logged as Activities (kind=meeting) ----
    for i in range(3):
        Activity.objects.create(
            org=org, kind=Activity.MEETING, deal=deals[i], lead=leads[i],
            actor=member, subject="Field visit", body="On-site demo at factory")
    visits = Activity.objects.filter(org=org, kind=Activity.MEETING).count()
    _ck(visits == 3, "field visits logged as meeting activities")

    # ---- Overdue next-step detection (one deal's next step is in the past) ----
    Deal.objects.filter(pk=deals[7].pk).update(
        next_step_due=today - timedelta(days=3))
    overdue = Deal.objects.filter(
        org=org, state="open", next_step_due__lt=today).count()
    _ck(overdue >= 1, "overdue next-step detected")

    # ================================================================ #
    #  3) PROPOSALS from the price book: totals, versions, discount     #
    #     approval GATE.                                                 #
    # ================================================================ #
    # (a) <=10% discount, all-reviewed products -> Draft, no approval needed.
    p1 = quoting.make_quote(
        leads[0], [{"sku": "ERP-CORE", "qty": 1}, {"sku": "ERP-SEAT", "qty": 50}],
        requirements="VAT-compliant ERP for RMG", discount_pct=5, tax_pct=0,
        created_by=member, deal=deals[0])
    # subtotal = 250000 + 50*3000 = 400000; 5% = 20000 off; total 380000.
    _ck(p1.subtotal == Decimal("400000.00"), "proposal subtotal 400000")
    _ck(p1.discount_amount == Decimal("20000.00"), "proposal 5% discount = 20000")
    _ck(p1.total == Decimal("380000.00"), "proposal total 380000")
    _ck(p1.prices_reviewed is True, "all-reviewed price book -> prices_reviewed")
    _ck(p1.discount_needs_approval is False and p1.status == Proposal.DRAFT,
        "5% discount is UNDER threshold -> Draft, no approval")
    _ck(p1.version == 1, "first proposal is version 1")

    # (b) a REVISED quote for the same lead -> version 2.
    p2 = quoting.make_quote(
        leads[0], [{"sku": "ERP-CORE", "qty": 1}], discount_pct=8,
        created_by=member, deal=deals[0])
    _ck(p2.version == 2, "revised proposal bumps to version 2")

    # (c) >10% discount -> approval GATE: Pending + needs_approval.
    big = quoting.make_quote(
        leads[0], [{"sku": "ERP-CORE", "qty": 1}], discount_pct=15,
        created_by=member)
    _ck(big.discount_needs_approval is True and big.status == Proposal.PENDING,
        "15% discount -> approval gate (Pending + needs_approval)")

    # (d) a quote using an UNREVIEWED product -> prices_reviewed False (blocks
    #     send until the owner reviews — asserted at DB level in the Django test).
    wip = quoting.make_quote(
        leads[1], [{"sku": "ERP-WIP", "qty": 1}], created_by=member)
    _ck(wip.prices_reviewed is False,
        "quote with unreviewed product -> prices_reviewed False (TO REVIEW)")

    # ================================================================ #
    #  4) CLOSE-OUT: a loss WITHOUT a reason must be REJECTED.          #
    #     The hard gate lives in the VIEW (LeadViewSet.mark_lost /      #
    #     DealViewSet.move). Here we replicate the exact guard as a pure #
    #     check; the real view path is exercised in tests_scenario.py.  #
    # ================================================================ #
    valid_reasons = {code for code, _ in Deal.LOSS_REASONS}

    def _reject_lost_without_reason(reason):
        """Mirror of the view guard: a blank/invalid reason is refused."""
        return (reason or "").strip() in valid_reasons

    _ck(_reject_lost_without_reason("") is False,
        "close as LOST with NO reason is rejected")
    _ck(_reject_lost_without_reason("garbage") is False,
        "close as LOST with an invalid reason is rejected")
    _ck(_reject_lost_without_reason("no_budget") is True,
        "close as LOST with a valid reason is accepted")

    # ---- 2 WON (indices 0, 5) ----
    for i in (0, 5):
        pl.move_deal(deals[i], won_stage, member=member)
        deals[i].refresh_from_db()
        _ck(deals[i].state == "won" and deals[i].closed_at is not None,
            f"deal {i} marked WON with closed_at")

    # ---- 3 LOST (each with a MANDATORY reason) ----
    for idx, reason in ((4, "no_budget"), (2, "price"), (6, "competitor")):
        _ck(_reject_lost_without_reason(reason),  # gate passes for a real reason
            f"deal {idx} has a valid loss reason before close")
        deals[idx].loss_reason = reason
        deals[idx].save(update_fields=["loss_reason"])
        pl.move_deal(deals[idx], lost_stage, member=member)
        deals[idx].refresh_from_db()
        _ck(deals[idx].state == "lost" and deals[idx].loss_reason == reason,
            f"deal {idx} marked LOST with reason {reason}")

    # ---- the 3 OPEN deals land in mid-pipeline stages (for the funnel) ----
    pl.move_deal(deals[1], st[4], member=member)  # Negotiation
    pl.move_deal(deals[3], st[3], member=member)  # Proposal
    pl.move_deal(deals[7], st[2], member=member)  # Demo
    for i in (1, 3, 7):
        deals[i].refresh_from_db()

    # Pin WON closed_at so the sales-cycle length is deterministic (passed-in):
    #   deal0: created month_start,       closed +20 days -> 20 day cycle
    #   deal5: created month_start+5 days, closed +19 days -> 14 day cycle
    # average = (20 + 14) / 2 = 17.0 days.
    Deal.objects.filter(pk=deals[0].pk).update(
        created_at=month_start, closed_at=month_start + timedelta(days=20))
    Deal.objects.filter(pk=deals[5].pk).update(
        created_at=month_start + timedelta(days=5),
        closed_at=month_start + timedelta(days=19))

    # ================================================================ #
    #  5) WON -> ORDER: installment schedule + AMC/renewal (backend has  #
    #     NO model for this; computed in pure helpers, integer poisha).  #
    # ================================================================ #
    # deal0 value 1,200,000 taka -> 120,000,000 poisha; 25% down + 3 installments.
    d0 = Decimal(deals[0].value) * TAKA
    down0, inst0 = _order_from_deal(int(d0), down_pct=25, n_installments=3)
    _ck(down0 == 30000000, "order0 down payment = 300000 taka (25%)")
    _ck(sum(inst0) == 90000000 and len(inst0) == 3,
        "order0 remaining 900000 taka over 3 installments, reconciles")
    # deal5 value 650,000 -> 65,000,000 poisha; 20% down + 4 installments.
    d5 = Decimal(deals[5].value) * TAKA
    down5, inst5 = _order_from_deal(int(d5), down_pct=20, n_installments=4)
    _ck(down5 + sum(inst5) == 65000000, "order5 reconciles to 650000 taka exactly")

    # BOOKED vs COLLECTED: booked = full order value; collected = down + paid
    # installments only (the rest are still scheduled -> collected < booked).
    booked_poisha = int(d0) + int(d5)                       # 185,000,000
    collected_poisha = (_collected(down0, inst0, paid_count=1)
                        + _collected(down5, inst5, paid_count=0))
    #   order0: down 30,000,000 + 1 installment 30,000,000 = 60,000,000
    #   order5: down 13,000,000 + 0 installments            = 13,000,000
    _ck(booked_poisha == 185000000, "booked revenue = 1,850,000 taka (2 won)")
    _ck(collected_poisha == 73000000,
        "collected = 730,000 taka (down + 1 installment)")
    _ck(collected_poisha < booked_poisha,
        "collected < booked while installments are pending")

    # AMC / RENEWAL pipeline: each order carries a 1-year AMC renewing on day
    # 365 + a few; "due soon" = within 90 days of as_of. We check the renewal
    # window near the anniversary (passed-in day math, no wall clock).
    orders = [
        {"id": deals[0].id, "amc_renewal_day": 365,
         "amc_value_poisha": int(d0) * 18 // 100},   # 18% AMC
        {"id": deals[5].id, "amc_renewal_day": 400,
         "amc_value_poisha": int(d5) * 18 // 100},
    ]
    near = _renewal_pipeline(orders, as_of_days=320, window_days=90)
    _ck(near["due_count"] == 2,
        "renewal pipeline: both AMCs due within the 90-day window at day 320")
    _ck(near["amc_value_poisha"] == (int(d0) + int(d5)) * 18 // 100,
        "renewal AMC value = 18% of both orders")
    far = _renewal_pipeline(orders, as_of_days=0, window_days=90)
    _ck(far["due_count"] == 0, "no renewals due at the start of the year")

    # ================================================================ #
    #  6) REPORTS — assert the computed numbers (hand-pinned).          #
    # ================================================================ #
    all_deals = Deal.objects.filter(org=org)
    open_deals = all_deals.filter(state="open")
    _ck(open_deals.count() == 3, "3 deals remain open (8 - 2 won - 3 lost)")

    # ---- weighted / best / commit forecast (open deals only) ----
    # After the stage moves, open probabilities follow the stage defaults:
    #   deal1 -> Negotiation (80), deal3 -> Proposal (65), deal7 -> Demo (45).
    #   weighted = 900000*0.80 + 750000*0.65 + 850000*0.45
    #            = 720000 + 487500 + 382500 = 1,590,000
    #   best     = 900000 + 750000 + 850000 = 2,500,000
    far_end = today + timedelta(days=400)   # explicit period_end -> deterministic
    f = fc.weighted_forecast(all_deals, period_end=far_end)
    _ck(f["has_data"] is True and f["open_count"] == 3, "forecast has 3 open deals")
    _ck(f["weighted"] == 1590000.0, "weighted forecast = 1,590,000")
    _ck(f["best_case"] == 2500000.0, "best-case forecast = 2,500,000")
    #   commit = open deals with prob>=70 closing before period_end -> only deal1.
    _ck(f["commit"] == 900000.0 and f["commit_count"] == 1,
        "commit forecast = 900,000 (one high-prob open deal)")

    # ---- win / loss + win rate ----
    wl = rp.win_loss(all_deals)
    _ck(wl["won"] == 2 and wl["lost"] == 3 and wl["total_closed"] == 5,
        "win/loss counts: 2 won, 3 lost, 5 closed")
    _ck(wl["win_rate"] == 40.0, "win rate = 40.0% (2/5 closed)")
    by_reason = {r["label"].split(" / ")[0]: r["count"]
                 for r in wl["loss_reasons"]}
    _ck(sum(r["count"] for r in wl["loss_reasons"]) == 3,
        "loss reasons add up to the 3 lost deals")

    # ---- average sales-cycle length (WON deals only) ----
    sc = rp.sales_cycle(all_deals)
    _ck(sc["has_data"] is True and sc["sample"] == 2, "sales cycle sampled 2 won")
    _ck(sc["avg_days"] == 17.0, "average sales-cycle length = 17.0 days")

    # ---- source attribution (WON revenue by source) ----
    sa = rp.source_attribution(all_deals)
    #   won deals: deal0 (whatsapp, 1,200,000) + deal5 (whatsapp, 650,000).
    _ck(sa["has_data"] is True and len(sa["rows"]) == 1, "won revenue in 1 source")
    _ck(sa["rows"][0]["source"] == "whatsapp"
        and sa["rows"][0]["value"] == 1850000.0,
        "whatsapp won revenue = 1,850,000 across 2 deals")

    # ---- win-rate BY SOURCE (gap: computed here in pure helper) ----
    wrs = _win_rate_by_source(
        [{"source": d.source, "state": d.state} for d in all_deals])
    #   whatsapp closed: deal0 won, deal5 won  -> 2/2 = 100%
    #   email closed:    deal2 lost            -> 0/1 = 0%
    #   manual closed:   deal4 lost            -> 0/1 = 0%
    #   linkedin closed: deal6 lost            -> 0/1 = 0%
    #   (deal1 messenger, deal3 manual-open, deal7 email-open are still OPEN)
    _ck(wrs["whatsapp"]["win_rate_pct"] == 100.0 and wrs["whatsapp"]["closed"] == 2,
        "win-rate by source: whatsapp 100% (2/2)")
    _ck(wrs["email"]["win_rate_pct"] == 0.0, "win-rate by source: email 0% (0/1)")
    _ck(wrs["linkedin"]["win_rate_pct"] == 0.0,
        "win-rate by source: linkedin 0% (0/1)")

    # ---- funnel drop-off per stage (documented reached-approximation) ----
    fn = rp.funnel(pipe, all_deals)
    reached = {r["stage"].split(" / ")[0]: r["reached"] for r in fn["rows"]}
    #   New 8, Qualified 8, Demo 8, Proposal 7, Negotiation 6, Won 5, Lost 0.
    _ck(fn["has_data"] is True and len(fn["rows"]) == pipe.stages.count(),
        "funnel has a row per stage")
    _ck(reached["নতুন"] == 8 and reached["যোগাযোগ"] == 8 and reached["ডেমো"] == 8,
        "funnel: 8 deals reached New/Qualified/Demo")
    _ck(reached["প্রপোজাল"] == 7, "funnel: 7 reached Proposal (1 dropped at Demo)")
    _ck(reached["নেগোসিয়েশন"] == 6, "funnel: 6 reached Negotiation")
    _ck(reached["জিতেছি"] == 5, "funnel: 5 reached Won stage (2 won + 3 closed-past)")
    _ck(reached["হারিয়েছি"] == 0, "funnel: Lost stage is not counted as 'reached'")

    # ---- pipeline by industry + rep performance (sanity: org-scoped, no leak) ----
    bi = rp.pipeline_by_industry(all_deals)
    _ck(bi["has_data"] is True, "pipeline-by-industry has data")
    rpf = rp.rep_performance(org, all_deals)
    _ck(rpf["has_data"] and rpf["rows"][0]["won"] == 2
        and rpf["rows"][0]["won_value"] == 1850000.0,
        "rep performance: owner has 2 won worth 1,850,000")

    # ================================================================ #
    #  7) MULTI-TENANT ISOLATION: the other org sees NONE of our data,  #
    #     and we see none of theirs. No leakage.                         #
    # ================================================================ #
    other_deals = Deal.objects.filter(org=other_org)
    _ck(other_deals.count() == 1, "other org has exactly its own 1 deal")
    _ck(all_deals.filter(org=other_org).count() == 0,
        "our deal queryset contains nothing from the other org")
    _ck(Lead.objects.filter(org=org).count() == 25
        and Lead.objects.filter(org=other_org).count() == 1,
        "leads are isolated per org (25 vs 1)")
    other_wl = rp.win_loss(other_deals)
    _ck(other_wl["total_closed"] == 0,
        "other org's win/loss is independent (0 closed) — no cross-tenant bleed")
    our_forecast = fc.weighted_forecast(all_deals, period_end=far_end)
    _ck(our_forecast["weighted"] == 1590000.0,
        "our forecast unchanged by the other tenant's 5,000,000 deal (isolated)")

    return {
        "org_id": org.id,
        "leads": len(leads),
        "deals": len(deals),
        "won": wl["won"], "lost": wl["lost"], "win_rate": wl["win_rate"],
        "weighted_forecast": f["weighted"], "best_case": f["best_case"],
        "commit": f["commit"], "open_deals": open_deals.count(),
        "avg_cycle_days": sc["avg_days"],
        "booked_taka": booked_poisha // TAKA,
        "collected_taka": collected_poisha // TAKA,
        "renewals_due_soon": near["due_count"],
        "checks": len(checks),
    }

    # KEY NUMBERS (hand-pinned):
    #   leads=25  deals=8  won=2  lost=3  win_rate=40.0%
    #   weighted=1,590,000  best_case=2,500,000  commit=900,000
    #   avg_sales_cycle=17.0 days
    #   booked=1,850,000 taka  collected=730,000 taka  (collected < booked)
    #   funnel reached: New8 Qual8 Demo8 Proposal7 Negotiation6 Won5 Lost0
    #   win-rate by source: whatsapp 100% (2/2), email 0%, manual 0%, linkedin 0%
    #   renewals due within 90d at day 320: 2 orders


def run_all():
    """Standalone entrypoint. Boots an in-memory DB, runs the scenario inside a
    rolled-back transaction, prints the passed-check count. Returns the summary.
    """
    _bootstrap_django()
    from django.db import transaction
    checks = []
    summary = {}
    # Wrap in a transaction and roll back so NOTHING persists (belt-and-braces
    # on top of the in-memory DB).
    try:
        with transaction.atomic():
            summary = run(_checks=checks)
            raise _Rollback()
    except _Rollback:
        pass
    print(f"AXON scenario: {len(checks)} checks PASSED")
    print("KEY NUMBERS:",
          f"leads={summary['leads']} deals={summary['deals']}",
          f"won={summary['won']} lost={summary['lost']}",
          f"win_rate={summary['win_rate']}%",
          f"weighted={summary['weighted_forecast']:,.0f}",
          f"best={summary['best_case']:,.0f} commit={summary['commit']:,.0f}",
          f"avg_cycle={summary['avg_cycle_days']}d",
          f"booked={summary['booked_taka']:,} collected={summary['collected_taka']:,}",
          f"renewals_due={summary['renewals_due_soon']}")
    return summary


class _Rollback(Exception):
    """Internal sentinel to force the scenario transaction to roll back."""


if __name__ == "__main__":  # pragma: no cover
    run_all()
