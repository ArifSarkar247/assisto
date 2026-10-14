# Job Hunter — ADVANCED integration notes (feature 37, SPEC v2.1 §21)

Upgrades the Job Hunter from a single list+tailor screen to an advanced,
bilingual, offline-aware module: **Discover / Saved / Tracker**, filters &
search, save/bookmark, an applied-tracker pipeline with dates + notes,
interview-prep checklist, company notes, salary insight (source-noted),
application reminders, and CV/cover tailoring (**MOCK + key-gated**).

Edited only: `app/lib/screens/jobs_screen.dart`, new `app/lib/widgets/jobs_*`,
new `backend/core/logic/job_hunter.py` (+ tests, folded into the Django suite).
No `api.dart`, `app_*.arb`, models, serializers, urls, sidebar, or migrations
were touched. No Flutter/build run. Asalify untouched.

## New / changed files
| File | Role |
|---|---|
| `app/lib/screens/jobs_screen.dart` | 3-tab screen (Discover/Saved/Tracker), search, filters badge, FAB, all §21 states |
| `app/lib/widgets/jobs_store.dart` | Local offline store (bookmarks, notes, prep ticks, company notes), FSM/filter constants mirroring the backend, curated sample feed |
| `app/lib/widgets/jobs_filters.dart` | Advanced filter bottom-sheet (category, type, experience, location, salary) |
| `app/lib/widgets/jobs_card.dart` | Job list card (match score, facts, bookmark) + `StageBadge` |
| `app/lib/widgets/jobs_detail.dart` | Job hub: pipeline tracker, reminders, CV/cover (mock+key-gated), prep checklist, notes |
| `backend/core/logic/job_hunter.py` | Deterministic pipeline FSM, reminders, filters, salary insight, sources gate |
| `backend/core/logic/job_hunter_tests_snippets.py` | 18 plain-assert tests |
| `backend/core/tests.py` | +3 lines: registers `JobHunterSnippetTests` into `run_all` suite |
| `.phaseB/up_jobs_arb.json` | 81 new `jobs*` keys `{key:[bn,en]}` — integrator merges into `app_en.arb`/`app_bn.arb` |

## Models (existing — reused, not changed)
`core/models.JobApplication` already carries everything the tracker needs:
`title, company, source, jd, match_score (ro), match_reason (ro), cv_text,
cover_letter, status, applied_at, followup_at, created_at`.

`status` choices already include the pipeline stages the UI drives:
`matched → saved? → applied → interview? → offer | rejected | withdrawn`.
> NOTE: the UI uses stage keys `saved`, `interview`, `withdrawn` in addition to
> the model's current `matched/drafted/applied/followup/replied/closed`. If the
> integrator wants server-side persistence of the new stages, widen the
> `JobApplication.STATUS` choices (+ a migration) to the keys in
> `job_hunter.PIPELINE`/`TERMINAL`. Until then the tracker still works for the
> stages the model already accepts; unknown-stage writes would be rejected by
> the serializer, which the UI surfaces as "couldn't update".

## Endpoints (existing — reused, not changed)
| Call (via existing `api.dart`) | HTTP | Purpose |
|---|---|---|
| `api.listItems('jobs')` | `GET /jobs` | Tracker + user-added discover rows |
| `api.createItem('jobs', {title,company,jd})` | `POST /jobs` | Add a job (server computes `match_score`/`reason`) |
| `api.updateItem('jobs', id, {status[, applied_at]})` | `PATCH /jobs/:id` | Advance pipeline stage (writes `status`, and `applied_at` on → applied) |
| `api.deleteItem('jobs', id)` | `DELETE /jobs/:id` | (available; not yet wired in UI) |
| `api.jobTailor(id)` | `POST /jobs/:id/tailor` | CV + cover letter (**MOCK + key-gated**) |

No new endpoints required. Deleting/withdrawing is a `status` change, not a row
delete, so history is preserved.

## Key-gates (honest, never faked)
- **CV / cover letter tailoring** → `core/jobs.tailor_documents` returns
  `{needs_key:true}` whenever `ai.available()` is false. The UI shows an
  "AI key needed" dialog (`jobsAiNeededTitle` + `availableWhenAnAiKey2`) and the
  button carries a standing note: *AI drafts from your own details — never
  invented.* The AI never fabricates qualifications (enforced server-side).
- **Live job sources** → the discovery feed is **key-gated**. A live feed
  arrives ONLY via an official job-source API or an owner-provided feed
  configured server-side; a flag (`_feedConnected`, currently `false`) gates it.
  `job_hunter.sources_state(feed_connected)` returns the banner copy. Until a
  feed is connected the UI shows a **curated sample** (`kSampleJobs`) plus an
  honest banner (`jobsConnectSourceBanner`).

## NO SCRAPING — hard rule
Benchmarked against the best job-search apps for *capability* only. We do **not**
scrape or copy bdjobs / LinkedIn / any site's listings. `sources_state()` and
every test assert `scraping == false`. The sample feed is representative,
Assisto-authored data, clearly labelled `source: "Assisto sample"`.

## Salary insight — source-noted, never invented
`job_hunter.salary_insight` (and the Dart `salaryInsight` mirror) summarise the
min/median/max only across jobs that **state** a salary in the current set, and
always attach a source note. With no stated salaries it returns
`available:false` ("not estimated") rather than inventing a market figure.

## §21 state coverage (all 10)
empty (per tab) · loading (skeleton) · error (with offline-saved hint) ·
offline-saved (bookmarks/notes/prep persist locally) · bilingual (81 ARB keys,
zero Bangla in `.dart`) · WCAG (container/on-container colour pairs, `—` instead
of a fake 0 score) · scenario (sample-vs-server jobs handled distinctly) ·
no-results (filter-aware message) · key-gated (AI + sources) · never-auto-apply
notice retained.

## Tests
`python3 -c "import core.logic.job_hunter_tests_snippets as t; t.run_all()"`
→ `job_hunter: 18 tests passed`. Folded into the Django suite as
`JobHunterSnippetTests`; full `manage.py test core` = **455 passing**.
