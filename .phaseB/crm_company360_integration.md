# CRM Company/Contact 360 + Reports — integration & backend gaps

Date: 2026-10-14 · Scope: `app/lib/screens/crm/*` + `app/lib/widgets/crm_company_widgets.dart`
only. No backend (`crm/models.py|views.py|urls.py|serializers.py`), `api.dart`
or `app_*.arb` were touched. ARB emitted as `.phaseB/crm_report_arb.json`
(`{key:[bn,en]}`, 91 keys). Dart carries zero Bangla literals.

## Screens created / changed
| File | What |
|------|------|
| `crm_companies_screen.dart` (new) | Company directory: searchable list, per-row contact count + industry + headcount, drill-in. |
| `crm_company_detail_screen.dart` (new) | Company 360: Overview / People / Timeline / Deals / Documents tabs. |
| `crm_reports_screen.dart` (new) | Advanced Sales Reports / dashboard surfacing forecast, win-rate, by-industry, per-rep attainment + honest unavailable panels. |
| `widgets/crm_company_widgets.dart` (new) | `ContactRoleChip`, `PrimaryContactBadge`, `CrmTagChip`, `KvRow`, `CrmSectionHeader`, `FunnelBar`, `ReportStatTile`, `inferContactRole`, `activityKindIcon`. |
| `crm_common.dart` (edited) | Added `companies(org)`, `company(id)`, `contacts(org)` helpers; extended `activities()` with hopeful `company`/`contact` query params. |
| `crm_home_screen.dart` (edited) | Added **Companies** and **Reports** tabs. |

## Endpoints USED (all already routed & correct per CRM_AUDIT)
- `GET /crm/companies/?org=<org>` → list (CompanySerializer)
- `GET /crm/companies/<id>/` → retrieve
- `GET /crm/contacts/?org=<org>` → list (ContactSerializer)
- `GET /crm/deals/?org=<org>` → list (filtered client-side by company)
- `GET /crm/activities/?org=<org>` → list (filtered client-side for the account)
- `GET /crm/dashboard?org=<org>` → Reports data (forecast, win_loss, by_industry, by_salesperson, pipeline_value, won_value)

## BACKEND GAPS (screens degrade honestly; nothing invented)

### Company 360
1. **No `?company=` filter on ContactViewSet / DealViewSet / ActivityViewSet.**
   `ActivityViewSet.get_queryset` filters `lead`/`deal`/`open_tasks`/`org` only;
   Contact/Deal viewsets filter by `org` only. The 360 screen therefore fetches
   the whole org set and groups client-side (contacts by `company`, deals by
   `company`, activities by company/contact-of-company/deal-of-company). Works,
   but is O(org) per open. **Fix:** add `?company=<id>` to all three
   `get_queryset`s. (Client already sends `company=`/`contact=` to
   `/activities/` hopefully; server currently ignores the unknown key.)
2. **No company-level timeline endpoint.** There is no
   `/companies/<id>/timeline/` aggregating the account's activity. The screen
   assembles it in-app and says so (`crmCompanyTimelineClientNote`). **Fix:** a
   detail `@action timeline` on CompanyViewSet mirroring `LeadViewSet.timeline`.
3. **Contact has no explicit ROLE field** (decision maker / influencer /
   finance). The model has `title` (free text) + `is_primary` only. Role chips
   are **inferred** from the title keywords + `is_primary`
   (`inferContactRole`) — a convenience, never persisted, falls back to "User".
   **Fix:** add `Contact.role` (choices: decision_maker / influencer / finance /
   champion / user) + expose on ContactSerializer; the chip then reads real data.
4. **Tags not served.** `Tag`/`TaggedItem` models exist but have **no ViewSet /
   route** in `crm/urls.py`. The tags filter UI (`CrmTagChip`) is built but has
   no data source, so the Companies screen ships without the tag filter wired.
   **Fix:** register `TagViewSet` + `TaggedItemViewSet` (or expose tags inline on
   Company/Contact serializers) so the chip row + filter can light up.
5. **Custom fields: values only, no definitions.** `Company.custom` /
   `Contact.custom` JSON is on the serializers and the 360 Overview renders the
   raw key→value pairs. But `CustomFieldDef` (label / type / options / order) has
   **no route**, so the screen shows raw keys, not human labels/types. **Fix:**
   expose `CustomFieldDef` (filter `?entity=company`) so the UI can label/sort/
   type-format custom values.
6. **Documents: no attachment URL on the list serializer.** Activities carry
   `Activity.attachment` (FileField) but `ActivitySerializer.fields` omits it, so
   the Documents tab can only show *which* activities carry an attachment, not a
   download link. The screen is honest (`crmDocumentsClientNote`). **Fix:** add
   `attachment` (and a `*_url`) to `ActivitySerializer`, or a real
   documents/attachments endpoint.
7. **Company industry has no `*_display`.** CompanySerializer returns the raw
   code; the screen maps rmg/pharma/retail to safe English labels and
   other/empty → "Unknown". **Fix:** add `industry_display` like LeadSerializer.

### Reports / Dashboard (spec §9)
8. **Funnel drop-off, sales-cycle length, source win-rate, activity
   leaderboard are COMPUTED but never RETURNED.** `reports.funnel`,
   `reports.sales_cycle`, `reports.source_attribution`,
   `reports.activity_leaderboard` all exist, but `DashboardView.get` returns only
   `forecast`, `win_loss`, `by_industry` (pipeline_by_industry) and
   `by_salesperson` (rep_performance). No other endpoint exposes them. The
   Reports screen shows these four as honest **"not surfaced by the API yet"**
   panels (`crmReportUnavailable`). **Fix (1 place):** add to the DashboardView
   response:
   ```python
   "funnel": rp.funnel(default_pipeline, deals),
   "sales_cycle": rp.sales_cycle(deals),
   "source_attribution": rp.source_attribution(deals),
   "activity_leaderboard": rp.activity_leaderboard(org, Activity.objects.filter(org_id=org_id)),
   ```
   (`funnel` needs a pipeline arg — pass the org's default pipeline.) Once added,
   the screen's `FunnelBar` widget + the source/cycle/leaderboard panels can be
   switched from the unavailable state to live rendering with no new endpoint.
9. **Booked-vs-collected and renewal pipeline are NOT modelled at all.** Contrary
   to the audit's §9 note, there is **no** collection/payment model and **no**
   renewal/AMC model anywhere in `crm/models.py` (grep: no `collect|booked|
   installment|renewal|amc`). The Reports screen shows both as unavailable
   (`crmReportUnavailableBooked` / `crmReportUnavailableRenewals`). **Fix:** net-
   new models (payments/collections against won deals; a renewals pipeline or
   `Deal.renewal_of`) + report functions before these can be wired.
10. **Weighted forecast is labelled an ESTIMATE.** The screen shows the
    server's `method` string verbatim and an explicit estimate badge +
    disclaimer (`crmForecastEstimateNote`) — never presents it as committed
    revenue. No backend change needed; noted so it stays honest.

## What makes each screen advanced
- **Company directory:** server-light (two fetches), searchable, each row
  surfaces the primary account signals (people count + headcount + industry).
- **Company 360:** five-tab account view (Overview+custom fields, People with
  inferred **role chips** + **primary marker** sorted primary-first, an
  **aggregated company timeline** merging every contact/deal activity, linked
  deals with win/loss tint, documents) — benchmarked against B2B account 360s,
  degrading honestly wherever the backend can't yet filter/serve.
- **Reports:** KPI strip (pipeline / won / win-rate), a **transparent forecast
  card** (method shown, estimate-labelled), win/loss with locale-correct loss
  reasons, pipeline-by-industry, and **per-rep attainment bars** — plus rigorous
  honest-unavailable panels for every report the API doesn't yet return, so a
  manager is never shown an invented number.
