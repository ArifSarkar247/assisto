# AI CRM (Axon Dynamics) — integrator TODO (agent abad6efc)

All code under backend/crm/ (extends P8). Server-rendered web app, bilingual bn/en, desktop-first. P8 DRF layer at /api/crm/ untouched. Logic modules are FLAT files (not a logic/ package — would shadow P8's logic.py).

## ROOT INCLUSION (I edit assisto_backend/urls.py — add ONE line):
    path("crm/", include("crm.weburls")),
(api/crm/ include already present.)

## MIGRATION (crm app) — `makemigrations crm` then migrate (DB BACKUP FIRST):
Lead += first_response_at(DT null), sla_due(DT null), company_rec(FK Company null related_name=leads), contact_rec(FK Contact null related_name=leads).
Proposal += deal(FK Deal null), version(PosSmallInt), title, requirements, line_items(JSON), subtotal/discount_pct/discount_amount/tax_pct/tax_amount/total(Decimal), prices_reviewed(Bool), status(choices), discount_needs_approval(Bool), approved_by/created_by(FK CrmMember null), approved_at/sent_at/viewed_at/accepted_at(DT null).
NEW models: Company, Contact, Pipeline, Stage, Deal, Activity, Mention, Tag, TaggedItem, CustomFieldDef, Territory, RoutingRule, Target, Product, Cadence, CadenceStep, AuditEntry. (FKs nullable; reverse accessors verified collision-free by agent.)

## Web UI: /crm/ (dashboard; /crm/login session auth via core.User username=phone/email; no-org users → create-org page). Lang toggle ?lang=bn|en session-stored, default bn. No-AI-key banner global; proposal AI draft shows needs-key state.

## Files: crm/webviews.py, weburls.py, admin.py, forecast.py, reports.py, quoting.py, dupes.py, pipeline.py, cadence.py, audit.py, porting.py, i18n.py, scenario.py, templatetags/crm_extras.py, management/commands/crm_scenario.py, 26 templates in crm/templates/crm/.

## Scenario (verify): `python manage.py crm_scenario --cleanup` — 20 leads (RMG≥500→≥90/high), 8 deals, 4 proposals (subtotal 400000, 5%→380000, 15%→approval), 2 won/3 lost(reasons), forecast=Σ(value×prob/100), win-rate 40%.

## Integrator: makemigrations crm + migrate; run crm_scenario + crm tests; CRM web reviewer; add /crm/ web screens to gallery (desktop screenshots) at FINAL. openpyxl may be absent → Excel falls back to CSV (fine). No PDF lib → proposal PDF is print-to-PDF HTML (fine).

## CRM REVIEWER = ADVANCED (no P0/security). Fixes (agent running; G5 done by integrator):
- G1(P1) lead "Mark Lost" bypasses mandatory-reason: route through a server action that REQUIRES loss_reason + records Deal.loss_reason + audit (so reports.win_loss sees it); don't just append to notes/set status freely.
- G2(P1) lead "Mark Won": add confirm dialog + CLOSE/create the backing Deal (Deal.state=won) so pipeline value/forecast/dashboard-won are correct; don't flip Lead.status as ERP-stub side effect.
- G3(P2) crm_lead_detail fetches whole list+firstWhere → add CrmApi.lead(id)→GET /crm/leads/{id}/ (retrieve).
- G4(P2) dashboard harden win_rate 'null%'.
- G5(P2) crmMarkLost bn "Lost"→"হারিয়েছি" (DONE).
- G6(P2 spec gap) build in-app QUOTE BUILDER: select Products from price book → line items → subtotal/tax/total → create proposal (quoting.make_quote). Reachable from proposal/lead detail.
- G7(P3) TodayView filter by assigned_to=member for sales role (person-centric Today).
- G8(P3) quick-action: surface launchUrl failure (don't show 'logged' when dialer/WhatsApp didn't open).
