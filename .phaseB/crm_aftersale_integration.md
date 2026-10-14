# CRM — Advanced Quotes/Proposals (§6) + After-Sale (§7) integration

Date: 2026-10-14 · Scope: CRM_AUDIT Part B items **#6 (quotes/proposals,
advanced)** and **#7 (after-sale)**. Pure logic landed in
`backend/crm/logic_quote.py` + `backend/crm/logic_aftersale.py` (no Django, no
I/O) with hand-verified tests. Flutter screens landed under
`app/lib/screens/crm/` + `app/lib/widgets/crm_aftersale_*`. This file is the
**integrator's** checklist: the Django models + DRF endpoints to add. **No
migration, no model/view/url edit was performed here** (per task constraints:
`models.py`, `views.py`, `urls.py`, `api.dart` untouched). **Asalify/ERP is NOT
touched** — the ERP hand-off is design/link-only.

HARD INVARIANTS the server must preserve (the logic modules already enforce
them; the views must call them, not re-implement):
* **Never invent a price or a tax rate.** Line amounts come from `Product`
  (price book) or owner input; tax rate is an explicit input and is flagged
  `tax_review_required` when applied without owner confirmation — no `%` is
  hardcoded.
* **No float drift.** All money is **integer poisha** (1 BDT = 100 poisha) in
  the new tables + logic. Convert with `logic_quote.taka_to_poisha` /
  `poisha_to_taka_str`. (The existing `Proposal` keeps its Decimal columns; new
  tables below use integer poisha.)

---

## PART 1 — ADVANCED QUOTES / PROPOSALS (§6)

The existing `Proposal` model (quote builder + approval gate) STAYS. Add the
fields/tables below for versions, validity, discount-approval, acceptance and
convert-to-order. Wire views to `crm.logic_quote`.

### 1a. `Proposal` — fields to ADD (migration on existing table)
| field | type | notes |
|-------|------|-------|
| `valid_days` | `PositiveSmallIntegerField(null=True)` | owner-set validity window; null = no expiry. Drives `logic_quote.is_expired/days_left` (use `created_at.date().toordinal()` as issued). |
| `discount_approved` | `BooleanField(default=False)` | manager approved an above-threshold discount. |
| `discount_approved_by` | `FK→CrmMember(null=True)` | who approved. |
| `discount_approved_at` | `DateTimeField(null=True)` | |
| `converted_order_id` | `IntegerField(null=True)` | set when converted → order (one-way). |

Keep the existing `line_items` JSON but store `unit_poisha`/`amount_poisha`
(integers) per line going forward so the new logic is drift-free. Totals may
also be mirrored as `*_poisha` integers if you prefer not to read the Decimal
columns.

### 1b. NEW `QuoteAcceptance` (tokenized customer acceptance link — mock)
| field | type | notes |
|-------|------|-------|
| `proposal` | `OneToOne→Proposal(related_name="acceptance")` | one link per quote version |
| `token` | `CharField(64, unique)` | from `logic_quote.make_acceptance_token` (swap in `django.core.signing.Signer` in prod) |
| `state` | `CharField(12, default="issued")` | issued/viewed/accepted/declined/revoked/expired — transition ONLY via `logic_quote.acceptance_transition` |
| `viewed_at` / `decided_at` | `DateTimeField(null=True)` | |

> `QuoteVersion` is NOT a new table — the existing `Proposal.version` +
> `Proposal.lead` FK already model v1/v2/v3 history (one `Proposal` row per
> version, newest first). The "version diff" comes from
> `logic_quote.version_diff(old_snapshot, new_snapshot)`.

### 1c. Endpoints (DRF `@action` on the existing proposal ViewSet / APIViews)
All org-scoped via the existing `_member_org_ids` pattern. Paths match the Dart
in `app/lib/widgets/crm_aftersale_api.dart`.

| method · path | calls (logic_quote) | returns |
|---|---|---|
| `GET  crm/leads/{lead}/quote_versions/` | — (list `lead.proposals` newest-first) | `[{id,version,title,status,total_poisha,prices_reviewed,discount_needs_approval,discount_approved,valid_days,is_expired,days_left}]` |
| `GET  crm/proposals/{id}/diff/` | `version_diff(prev, this)` | `{added,removed,changed,total_delta_poisha,...}` |
| `POST crm/proposals/{id}/validity/` `{valid_days}` | `validity_until` | updated proposal |
| `POST crm/proposals/{id}/request_discount_approval/` | `discount_needs_approval` | sets status=pending |
| `POST crm/proposals/{id}/approve_discount/` | `approval_gate` (manage perm) | sets `discount_approved` |
| `GET  crm/proposals/{id}/pdf_model/` | `build_pdf_model(pdf_lib_available=…)` | structured PDF model + `rendered` flag (honest: no PDF lib → preview) |
| `GET  crm/proposals/{id}/acceptance_link/` | `make_acceptance_token` | `{url,token,link_state}` (creates `QuoteAcceptance` if absent) |
| `POST crm/proposals/{id}/convert_to_order/` | `can_convert_to_order` + `build_order_payload` | order draft payload (hand to order module) |

**Public (tokenized, session-less) customer page** — the mock acceptance link:
`GET/POST crm/accept/{token}/` → `acceptance_transition(state, view/accept/decline)`.
This is the ONE endpoint reachable without CRM auth; validate the token, never
trust client state.

---

## PART 2 — AFTER-SALE (§7)  — all NEW tables, all additive

Money fields are **integer poisha**. Dates stored as real `DateField`; the
logic takes `date.toordinal()` at the view edge.

### 2a. `Order` (converted-from-quote; minimal — the order module may own more)
| field | type | notes |
|-------|------|-------|
| `org` | `FK→CrmOrg(related_name="orders")` | tenant scope |
| `lead` / `deal` | `FK(null=True)` | provenance |
| `source_proposal` | `FK→Proposal(null=True)` | the accepted quote |
| `total_poisha` | `BigIntegerField` | carried from the quote, NOT re-priced |
| `created_at` | `DateTime(auto_now_add)` | |

### 2b. `Installment` + collection (booked vs collected, cash/cheque/bank)
`Installment` — built by `logic_aftersale.build_installment_schedule`:
| field | type | notes |
|-------|------|-------|
| `order` | `FK→Order(related_name="installments")` | |
| `seq` | `PositiveSmallIntegerField` | 1-based |
| `amount_poisha` | `BigIntegerField` | **booked** amount (exact split; remainder on last seq) |
| `due_date` | `DateField` | |
| `collected_poisha` | `BigIntegerField(default=0)` | running tally via `apply_collection` |
| `status` | `CharField(10, default="scheduled")` | scheduled/partial/collected/overpaid |

`Collection` (one row per payment, for the ledger/audit):
| field | type | notes |
|-------|------|-------|
| `installment` | `FK→Installment(related_name="collections")` | |
| `amount_poisha` | `BigIntegerField` | ≥ 0 (never fabricated) |
| `method` | `CharField(6)` | **cash / cheque / bank** only (`apply_collection` rejects others) |
| `reference` | `CharField(64, blank)` | cheque/txn no. |
| `collected_at` | `DateTime(auto_now_add)` | |

**Endpoints**
| method · path | calls | returns |
|---|---|---|
| `GET  crm/installments/?org=&order=` | — | `[{id,seq,amount_poisha,collected_poisha,due_date,status}]` |
| `GET  crm/collections/summary?org=&order=` | `collection_summary(schedule, today_ord)` | `{booked_poisha,collected_poisha,outstanding_poisha,overdue_poisha,overdue_count,fully_collected}` |
| `POST crm/installments/{id}/collect/` `{amount_poisha,method,reference}` | `apply_collection` | updated installment (writes a `Collection` row) |

### 2c. `AMC` (annual maintenance / renewal) + reminder scheduling
| field | type | notes |
|-------|------|-------|
| `org` | `FK→CrmOrg(related_name="amcs")` | |
| `company` | `FK→Company(null=True)` | |
| `order` | `FK→Order(null=True)` | |
| `title` | `CharField(200)` | |
| `start_date` | `DateField` | |
| `term_days` | `PositiveIntegerField(default=365)` | `amc_renewal_ordinal(start, term_days)` |
| `reminder_lead_days` | `PositiveSmallIntegerField(default=30)` | `renewal_status` |
| `last_renewed_at` | `DateField(null=True)` | |

**Endpoints**
| method · path | calls | returns |
|---|---|---|
| `GET  crm/amcs/?org=&status=` | `renewal_status(renewal_ord, today_ord, lead)` per row | `[{id,company,title,state,days_to_renewal}]` (state ∈ active/due_soon/due_today/overdue) |
| `POST crm/amcs/{id}/schedule_reminder/` | `reminder_schedule(renewal_ord)` | fire-day ordinals → persist as app-local reminders. **NOTE (memory): WorkManager is banned — reminders surface on app open/resume, foreground only.** |
| `POST crm/amcs/{id}/renew/` `{term_days}` | `amc_renewal_ordinal` | rolls `start_date` forward, stamps `last_renewed_at` |

### 2d. `Complaint` (log + state machine + SLA)
| field | type | notes |
|-------|------|-------|
| `org` | `FK→CrmOrg(related_name="complaints")` | |
| `company`/`lead` | `FK(null=True)` | who |
| `subject` | `CharField(200)` | |
| `details` | `TextField(blank)` | |
| `priority` | `CharField(8, default="normal")` | urgent/high/normal/low → SLA days 1/2/5/10 |
| `state` | `CharField(14, default="open")` | transition ONLY via `logic_aftersale.complaint_transition` |
| `opened_at` | `DateTime(auto_now_add)` | SLA clock start |
| `resolved_at` | `DateTime(null=True)` | |

**Endpoints**
| method · path | calls | returns |
|---|---|---|
| `GET  crm/complaints/?org=&state=` | `complaint_sla(priority, opened_ord, today_ord, state)` per row | `[{id,subject,details,state,priority,sla_breached,days_left}]` |
| `POST crm/complaints/` (create) | — | new complaint (state=open) |
| `POST crm/complaints/{id}/transition/` `{action}` | `complaint_transition(state, action)` | updated complaint (stamps `resolved_at` on resolve) |

### 2e. Upsell (computed, no new table required)
`GET crm/upsell?org=&company=&lead=` → `logic_aftersale.upsell_signals(
owned_module_codes, catalog_module_codes, amc_state, outstanding_poisha)`.
Owned modules come from the lead/company's accepted proposals' `line_items`;
catalog from `Product`/module options. Returns `{candidates, signals,
suppressed, suppress_reason}`. **No price is attached** — the owner sets prices
elsewhere; upsell is SUPPRESSED when the account has an outstanding balance.

### 2f. `ErpHandoff` (Axon ERP implementation — DESIGN / LINK ONLY)
> **Does NOT touch Asalify/ERP.** Models the hand-off record + legal
> transitions; with no ERP link connected the state is `needs_erp_link` and
> nothing is sent (`transport="mock"`). Mirrors the existing `onboard_to_erp`
> needs-integration stub.

| field | type | notes |
|-------|------|-------|
| `deal` | `OneToOne→Deal(related_name="erp_handoff")` | per won deal |
| `company_name` | `CharField(200)` | |
| `module_codes` | `JSONField(default=list)` | |
| `order_total_poisha` | `BigIntegerField(default=0)` | |
| `state` | `CharField(12, default="not_started")` | transition ONLY via `logic_aftersale.handoff_transition` |
| `erp_link_connected` | `BooleanField(default=False)` | gate; False → `needs_erp_link` |

**Endpoints**
| method · path | calls | returns |
|---|---|---|
| `GET  crm/deals/{deal}/erp_handoff/` | `build_handoff_record(erp_link_connected=…)` | `{company,modules,order_total_poisha,state,erp_state,note,transport}` |
| `POST crm/deals/{deal}/erp_handoff/transition/` `{action}` | `handoff_transition` | updated record (never posts to ERP) |

---

## PART 3 — Flutter surfaces added (reference)
* `app/lib/screens/crm/crm_proposal_advanced_screen.dart` — versions, validity,
  discount-approval, branded-PDF preview (honest), acceptance link (copy),
  convert-to-order.
* `app/lib/screens/crm/crm_aftersale_screen.dart` — 4 tabs: Collections,
  AMC/Renewals, Complaints, Upsell.
* `app/lib/screens/crm/crm_erp_handoff_screen.dart` — ERP hand-off (design/link).
* `app/lib/widgets/crm_aftersale_api.dart` — endpoint wrappers (uses existing
  generic ApiClient helpers; `api.dart` untouched) + `bdtFromPoisha`.
* `app/lib/widgets/crm_aftersale_widgets.dart` — shared pills/rows/progress.

All strings via `AppLocalizations`; new keys emitted to
`.phaseB/crm_aftersale_arb.json` (`{key:[bn,en]}`, camelCase). **Zero Bangla in
`.dart`** (only the `৳` sign, which is allowed). Merge the ARB with the project's
existing `merge_arb.py` and run codegen there — no codegen was run here.

## PART 4 — Verify
```
cd backend && python3 -c "import crm.logic_quote_tests_snippets as a; a.run_all(); \
  import crm.logic_aftersale_tests_snippets as b; b.run_all()"
# -> logic_quote: 13 tests passed
# -> logic_aftersale: 11 tests passed
```
