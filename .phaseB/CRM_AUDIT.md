# Assisto in-app CRM — READ-ONLY audit

Date: 2026-10-14 · Scope: Django `crm` app + Flutter `app/lib/screens/crm/`. No code changed.

CRM is mounted at THREE prefixes in `backend/assisto_backend/urls.py`:
```
path("api/v1/crm/", include("crm.urls"))   # the app uses this (apiPrefix=/api/v1)
path("api/crm/",    include("crm.urls"))
path("crm/",        include("crm.weburls")) # separate server-rendered web UI
```
The Flutter app talks to `api/v1/crm/...` (`AppConfig.apiPrefix = '/api/v1'`, base `https://assisto.asalify.com`). `weburls.py`/`webviews.py` is a DIFFERENT, session-auth web surface and is NOT what the app calls — ignore it for the "couldn't load" bug.

---

# PART A — CONTRACT AUDIT

## A5. ROOT-CAUSE LIST (why CRM screens fail to load) — confirmed from the LIVE log

1. **THE bug — client appends the trailing slash AFTER the query string.** In `app/lib/api.dart` the generic helpers build the URL as `AppConfig.api('/$path/')`:
   - `listItems`  → `GET  /api/v1/$path/`
   - `createItem` → `POST /api/v1/$path/`
   - `updateItem` → `PATCH /api/v1/$path/$id/`
   - `deleteItem` → `DELETE /api/v1/$path/$id/`
   When `path` already carries a query (every list call does, e.g. `crm/leads?org=7`), the result is the malformed `/api/v1/crm/leads?org=7/`. Django `APPEND_SLASH` 301-redirects it to `/api/v1/crm/leads/?org=7/` — moving the `/` INTO the query value, so `org=7/`. The view then does `qs.filter(org_id=p["org"])` with `"7/"` → **`ValueError: Field 'id' expected a number but got '7/'` → HTTP 500.**
2. The crash hits **every list-based screen**: Leads, Pipeline (pipelines+deals), Team (members+routing-rules), Products/price-book, Proposals list, Activities. These are the tabs the owner sees "couldn't load".
3. The crash does **not** hit `getJson`/`postJson` endpoints (Today, Dashboard, orgs list, orgs/invite, join, extract, all lead/deal detail actions) — those build the path verbatim with no appended slash, so they return 200. This is exactly the split seen in the log (Today/Dashboard 200, Leads/Pipelines/Members 500).
4. Secondary: even the 301 round-trip is wasteful and, on a POST/PATCH/DELETE, Django's redirect would drop the method/body — so writes via `createItem`-with-query would silently misbehave (none currently pass a query, so not yet observed).

### A4. Live-log ref codes (journalctl `assisto.service`, logger `crm.errors`) — real, reproduced
All are the SAME bug, all `user=3 org=7`, all HTTP 500 preceded by a 301:

| ref | request (post-redirect) | view line | cause |
|-----|-------------------------|-----------|-------|
| `L78YYC`, `78QD7K` | `GET /api/v1/crm/members/?org=7/` | views.py:555 | `org_id=p["org"]` = `"7/"` → ValueError |
| `QQC5CU`, `5M7R2P`, `U3YZSE` | `GET /api/v1/crm/pipelines/?org=7/` | views.py:435 | same |
| `YD27FW`, `VLCLLF`, `BLQNGF` | `GET /api/v1/crm/leads/?org=7/` | views.py:207 | same |

(Each 500 line is immediately preceded by `"GET /api/v1/crm/<x>?org=7/" 301 0`, i.e. the APPEND_SLASH redirect that creates the broken `org` value.) `Today` and `Dashboard` in the same session returned 200. journalctl did NOT need sudo.

## A1. Flutter CRM paths (from `crm_common.dart` / `api.dart`)

Normalized; `{id}`/`{org}` are numeric. "built URL" shows what the helper actually sends.

| Dart call | method | built URL | request keys | response keys the Dart reads | status |
|-----------|--------|-----------|--------------|------------------------------|--------|
| `orgs()` `listItems('crm/orgs')` | GET | `/crm/orgs/` | — | `[{id,name}]` | 200 (no query) |
| `createOrg` `createItem('crm/orgs',…)` | POST | `/crm/orgs/` | name, industry, team_size | org | 200 |
| `joinOrg` `postJson('/crm/join',…)` | POST | `/crm/join` | code | ok, joined, org, role | 200 |
| `inviteCode` `getJson('/crm/orgs/{org}/invite/')` | GET | `/crm/orgs/{org}/invite/` | — | ok, org, invite_code | 200 |
| `rotateInviteCode` `postJson('/crm/orgs/{org}/invite/')` | POST | same | — | invite_code | 200 |
| `today` `getJson('/crm/today?org={org}')` | GET | `/crm/today?org={org}` | — | ok, high_score_leads, lead_followups, overdue_next_steps, missing_next_step, due_tasks, stuck_deals | 200 |
| `dashboard` `getJson('/crm/dashboard?org={org}')` | GET | `/crm/dashboard?org={org}` | — | ok, restricted?, status_counts, pipeline_value, won_value, high_priority_leads, forecast, win_loss, by_industry, by_salesperson | 200 |
| `leads(...)` `listItems('crm/leads?org=…')` | GET | `/crm/leads?org={org}/` ❌ | priority,status,industry,q (query) | `[{id,name,company,score,industry/_display,source,status_display,company_size}]` | **500** |
| `createLead` `createItem('crm/leads',body)` | POST | `/crm/leads/` | full lead body | lead | 200 (no query) |
| `updateLead` `updateItem('crm/leads',id,…)` | PATCH | `/crm/leads/{id}/` | fields | — | 200 |
| `lead(id)` `getJson('/crm/leads/{id}/')` | GET | `/crm/leads/{id}/` | — | lead | 200 |
| `leadTimeline` `getJson('/crm/leads/{id}/timeline/')` | GET | same | — | ok, insight, messages, activities | 200 |
| `leadFollowup` `getJson('/crm/leads/{id}/followup/')` | GET | same | — | (suggest_followup dict) | 200 |
| `leadProposal` `postJson('/crm/leads/{id}/proposal/',…)` | POST | same | requirements | (generate_proposal dict) | 200 |
| `leadOnboard` `postJson('/crm/leads/{id}/onboard/')` | POST | same | — | ok/needs state | 200 |
| `leadMarkWon` `postJson('/crm/leads/{id}/mark_won/')` | POST | same | — | ok, lead, deal | 200 |
| `leadMarkLost` `postJson('/crm/leads/{id}/mark_lost/',…)` | POST | same | loss_reason, loss_note, competitor | ok, lead, deal | 200 |
| `leadQuote` `postJson('/crm/leads/{id}/quote/',…)` | POST | same | selections[], discount_pct, tax_pct, requirements, title | proposal | 200 |
| `logAction` `postJson('/crm/leads/{id}/log_action/',…)` | POST | same | kind, subject, body | activity | 200 |
| `extract` `postJson('/crm/extract',…)` | POST | `/crm/extract` | text | ok, ai_available, phone, phones, whatsapp, email, company, name | 200 |
| `pipelines` `listItems('crm/pipelines?org=…')` | GET | `/crm/pipelines?org={org}/` ❌ | — | `[{id,name,stages:[{id,name,order,probability,is_won,is_lost}]}]` | **500** |
| `deals` `listItems('crm/deals?org=…&pipeline=…')` | GET | `/crm/deals?org=…&pipeline=…/` ❌ | — | `[{id,title,stage,value,…}]` | **500** |
| `createDeal` `createItem('crm/deals',body)` | POST | `/crm/deals/` | deal body | deal | 200 (no query) |
| `moveDeal` `postJson('/crm/deals/{id}/move/',…)` | POST | same | stage, loss_reason?, loss_note?, competitor? | deal | 200 |
| `setNextStep` `postJson('/crm/deals/{id}/set_next_step/',…)` | POST | same | next_step, next_step_due | deal | 200 |
| `activities` `listItems('crm/activities?org=…')` | GET | `/crm/activities?org=…/` ❌ | lead?, deal? | activities | **500** |
| `createActivity` `createItem('crm/activities',body)` | POST | `/crm/activities/` | body | activity | 200 (no query) |
| `members` `listItems('crm/members?org=…')` | GET | `/crm/members?org=…/` ❌ | — | `[{id,role,user_name}]` | **500** |
| `routingRules` `listItems('crm/routing-rules?org=…')` | GET | `/crm/routing-rules?org=…/` ❌ | — | rules | **500** |
| `proposals` `listItems('crm/proposals?org=…&lead=…')` | GET | `/crm/proposals?org=…&lead=…/` ❌ | — | proposals | **500** |
| `proposalTransition` `postJson('/crm/proposals/{id}/transition/',…)` | POST | same | to | proposal | 200 |
| `products` `listItems('crm/products?org=…')` | GET | `/crm/products?org=…/` ❌ | — | `[{id,sku,name,unit_price,price_reviewed,active}]` | **500** |

## A2. Routed CRM paths (`crm/urls.py`) — all exist and match the Dart names
Router basenames (DRF `DefaultRouter`, trailing-slash routes): `orgs, leads, conversations, proposals, companies, contacts, pipelines, stages, deals, activities, members, routing-rules, territories, products`. Extra `@action`s confirmed present: lead → `followup, proposal, mark_won, mark_lost, onboard, quote, timeline, message, log_action`; deal → `move, set_next_step, stuck`; activity → `complete`; proposal → `transition`; org → `invite`. APIViews: `capture, extract, join, today, dashboard`.

**Every path the Dart calls is correctly routed on the server.** There are NO unrouted-path (true 404) mismatches, NO wrong-method mismatches, and NO payload/response-shape mismatches. Response keys the Dart reads all exist in the serializers/views (verified: Today, Dashboard, LeadSerializer `*_display`, Pipeline `stages`, Deal `stage`/`weighted_value`, Proposal totals).

## A3. DIFF — the ONE mismatch class
The only contract defect is the **trailing-slash-after-query** bug in the four generic helpers (`listItems/createItem/updateItem/deleteItem` in `app/lib/api.dart`, lines ~143/151/160/166). It is not a routing/method/shape mismatch — it is a client URL-construction bug that turns every list GET into a 301→500. `getJson`/`postJson` are built correctly, which is why detail actions work and only the *list* screens fail.

**Fix (client-side, 1 place):** split the query before appending the slash, e.g. in each helper insert the `/` before `?`:
`final p = path.contains('?') ? path.replaceFirst('?', '/?') : '$path/';` then `AppConfig.api('/$p')`. (Server needs no change; it is behaving correctly.)

---

# PART B — 12-POINT SPEC GAP ANALYSIS

Legend: ✅ exists/advanced · 🟡 partial · ⏳ missing. "In-app" = reachable from the Flutter CRM; several advanced backend features have NO Flutter screen yet.

| # | Area | Status | Evidence | What's missing |
|---|------|--------|----------|----------------|
| 1 | Capture | 🟡 | `views.CaptureWebhookView` (WhatsApp-gated, needs-key), `PasteExtractView` rule-based (phone/email/company/name), `logic.capture_lead`, `dupes.find_lead_duplicates`/`merge_leads`, `porting.import_leads_csv`/`leads_to_xlsx`, source field on lead form (`crm_lead_form_screen.dart`) | No in-app business-card OCR, no Messenger/email/web-form ingress UI, no referral-source capture, no dedupe/merge SCREEN (backend only); capture webhook is server-to-server, not driven from app |
| 2 | Company 360 | 🟡 | Models `Company`(parent/child, custom JSON, territory, owner), `Contact`(is_primary, whatsapp), `Tag`/`TaggedItem`, `CustomFieldDef`, `Activity` timeline; ViewSets exist | NO in-app Company/Contact screen wired (`CrmContactsScreen` exists at `screens/crm_contacts_screen.dart` but is a separate stub, not inside CRM tabs); no documents/attachments UI; custom fields have no editor UI |
| 3 | Pipelines & deals | ✅ (backend) / 🟡 (app) | `Pipeline`/`Stage`(probability, is_won/lost, stuck_after_days), `Deal`(value, probability, competitor, loss_reason mandatory, next_step, stage_entered_at), `pipeline.move_deal`/`stuck_deals`, kanban `crm_pipeline_screen.dart` | App shows only the FIRST pipeline (`pipes.first`); no multi-pipeline switch; no products-per-deal line items on the deal; stage-age warning only surfaced on Today, not on board |
| 4 | Daily work | 🟡 | **Today agenda** `TodayView` + `crm_today_screen.dart` ✅; **10-sec post-call log** `log_action` + quick-action buttons ✅; mandatory next step `deal.set_next_step`/`next_step` required field ✅; overdue alerts in Today + `cadence.due_followups` ✅ | NO voice→note AI; NO field-visit GPS check-in w/ photos; NO manager visit view; `Activity.attachment` field exists but no capture UI |
| 5 | Communication | 🟡 | Quick call/WhatsApp/email via `url_launcher` + auto-log (`crm_lead_detail_screen.dart` `_quick`→`logAction`), `Activity` kinds whatsapp/email/call, `Conversation`/`Message` with sentiment | WhatsApp is just a `wa.me` deep-link (no API send/receive, no auto-log of the reply); no message templates UI; no opt-in bulk send; Cadence steps are draft-only with no UI |
| 6 | Quotes & proposals | ✅ (core) / 🟡 | Quote builder from price book `leadQuote`→`quoting.make_quote`, `crm_proposal_screen.dart` (line items, discount/tax, totals), `Proposal` versions, approval gate (`transition`: approve needs manage + prices_reviewed; send needs approved), accept/decline states | `pdf_path` field + weburl `proposal_pdf` exist but NO branded-PDF generation in-app, NO acceptance link, NO validity/expiry, NO "convert to order"; `discount_needs_approval` not enforced on a threshold |
| 7 | After-sale | 🟡 | `logic.onboard_to_erp` (ERP hand-off, needs-integration safe), gated behind lead.status=won | No installment/collection, no AMC/renewal reminders, no complaints, no upsell — none modelled/served |
| 8 | Team | 🟡 | Roles owner/manager/sales (`CrmMember`), routing `RoutingRule`+`pipeline.route_lead` (industry/size/source, first-match), `Territory`, invite-code join, `reports.rep_performance`, `crm_team_screen.dart` (roster, invite code, rules view) | NO round-robin, `Target`/commission models exist but NO targets/commission UI or serializer, no leaderboard screen (only `activity_leaderboard` backend fn), routing rules are read-only in app |
| 9 | Reports | ✅ (backend) / 🟡 (app) | `reports.py`: `funnel`, `win_loss`, `sales_cycle`, `source_attribution`, `pipeline_by_industry`, `rep_performance`, `activity_leaderboard`; `forecast.weighted_forecast`/`target_attainment`; Dashboard surfaces forecast+win_loss+by_industry+by_salesperson | App Dashboard does NOT surface funnel drop-off, cycle length, source win-rate, booked-vs-collected, or renewal pipeline (functions exist server-side but are not returned by `DashboardView` / rendered) |
| 10 | AI (mock) | 🟡 | `scoring.base_score` deterministic + reason (shown as `score_reason`), `scoring.rule_sentiment`, `refine_with_ai` (±5 nudge, needs key), `logic.suggest_followup`, `_update_insight` summary, proposal gen needs-key | No next-best-action surface, no deal-risk signal, no data-quality check, no reply drafts UI; all AI is key-gated and honest but thin — lead score+reason is the only live AI-ish feature |
| 11 | Owner automation rules | ⏳ | Only `RoutingRule` (lead assignment) and `Cadence`/`CadenceStep` (draft sequences) exist | No general owner-creatable automation/trigger-action rule engine; no UI |
| 12 | Offline / isolation / audit / import-export / ERP | 🟡 | Multi-company isolation ✅ (`_member_org_ids` scoping everywhere, `_OrgScopedViewSet`); audit log ✅ (`AuditEntry`, written on won/lost/quote/proposal/stage); import/export ✅ backend (`porting` CSV+XLSX, weburls import/export) but NO in-app import/export UI; ERP link 🟡 (`onboard_to_erp` stub) | NO offline-first (all screens are live-fetch, no local cache/queue); import/export not reachable in app; Axon ERP link is a stub |

## Owner TOP-PRIORITY trio
- **Today agenda** — ✅ built & working (`TodayView` + `crm_today_screen.dart`, returns 200 live).
- **10-second post-call log** — ✅ built & working (`log_action` action + quick-action buttons that auto-log every call/WhatsApp/email tap).
- **WhatsApp integration** — 🟡 deep-link only (`wa.me` via url_launcher + manual activity log). No WhatsApp Business API send/receive, no inbound capture, no auto-log of replies. This is the biggest gap in the trio.

> NOTE: today/10-sec-log both use `getJson`/`postJson`, so they already work. But the Leads and Pipeline tabs the owner lands on **next** hit the trailing-slash 500 (Part A), making the whole CRM feel "broken" even though the backend is fine.

## Prioritized build list (gaps)
1. **FIX the trailing-slash bug** in `app/lib/api.dart` (the 4 generic helpers). One change unblocks Leads, Pipeline, Team, Products, Proposals, Activities — turns most of the CRM from "couldn't load" to working. (Highest ROI; server untouched.)
2. Wire **Company/Contact (360) screens** into the CRM tabs (ViewSets already exist; `CrmContactsScreen` stub is orphaned).
3. **WhatsApp Business API** send/receive + auto-log + templates (completes the priority trio); surface the capture webhook in-app.
4. Surface the **already-built reports** (funnel, cycle, source win-rate, booked-vs-collected, renewal) in the Dashboard — backend functions exist, just not returned/rendered.
5. **Targets/commission/leaderboard** UI (models `Target` + `reports.rep_performance`/`activity_leaderboard` exist).
6. **Field-visit GPS check-in + photos** and **voice→note** (Daily-work gaps; `Activity.attachment` field ready).
7. **Branded-PDF + acceptance link + validity + convert-to-order** for proposals.
8. **After-sale** (AMC/renewal reminders, collections, complaints) and **owner automation-rule engine** (#11) — net-new models/UI.
9. **Offline-first** cache/queue layer (currently every screen is a live fetch).
10. In-app **import/export** (CSV/XLSX backend ready in `porting.py`).
