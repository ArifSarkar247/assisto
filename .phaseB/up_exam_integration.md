# Exam result — ADVANCED (SPEC v2.1 §21) — integrator notes

Upgrades `ExamResultScreen` (module-5 "Life", BD board results — SSC/HSC/JSC/PSC/
Dakhil/Alim + board/uni) from GOOD → ADVANCED. Benchmarked vs the standard
"result checker" apps on Play Store: those FAKE speed and sometimes show
fabricated/stale results. Assisto's whole differentiator is honesty —
**OFFICIAL-SOURCE-ONLY** and **NEVER-FABRICATE-A-RESULT**, enforced in both the
UI and the logic.

## Non-negotiable guarantees (verify these in review)
- **Official-source-only.** The only place a real result appears is the official
  board portal (`educationboardresults.gov.bd` / `eboardresults.com` /
  `results.ebaube.gov.bd`). CHECK RESULT opens that site in the browser
  (`launchUrl` external). Assisto does **not** scrape it or render a result.
- **Never fabricate a result.** No function anywhere produces/infers/pre-fills a
  GPA/grade/pass-fail. The GPA explainer only interprets a value the USER typed
  off their own slip; the grade table is the board's PUBLIC scale (same for
  everyone). The share card is built ONLY from user-entered values and carries an
  "entered by you — not an official result" footnote so a forward can't pose as
  official. `result_ready_payload` sets `source_only:true` (says the page
  *changed*, not what the result is).
- **Result-day watcher.** Watch by exam + roll + board + reg + expected date; on
  result day it shows an honest traffic-spike note (servers busy) + the
  official-site button — never a faked result. A pasted non-official URL is
  flagged (`examUrlNotOfficial`), not trusted.

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/exam_result_screen.dart` | **Rewritten.** Watcher (exam/board pickers + roll + reg + label + URL + expected date), non-official-URL flag, countdown chip, saving state, traffic-spike phase banner, official-check section, multi-student watch, GPA/grade explainer, live festival result-card preview. |
| `app/lib/widgets/exam_board_picker.dart` | **NEW.** BD board (11) + exam-type (6) code↔label maps (mirror `exam.BOARDS`/`EXAM_TYPES`), `isOfficialResultUrl` (mirror), `ExamBoardPicker` dropdowns, `ExamOfficialCheck` (opens the official portal + official-only note). |
| `app/lib/widgets/exam_gpa_explainer.dart` | **NEW.** Public grade-scale table (mirror `exam.GRADE_SCALE`), `gpaBand` for a user-typed GPA (mirror `explain_gpa`), `ExamGpaExplainer` (expandable), `ExamCountdownChip` (mirror `countdown`). |
| `app/lib/widgets/exam_result_card.dart` | **NEW.** Festival-style (brand-gradient) share card built ONLY from user values; empty hint; "entered by you" footnote in both preview and shared text; `Share`/clipboard fallback. Mirrors `exam.result_card`. |
| `app/lib/widgets/exam_student_watch.dart` | **NEW.** Parent/teacher multi-student editor (label + roll rows, add/remove, 25 cap), honest count summary. Mirrors `exam.normalise_students`/`watch_summary`. |
| `backend/core/logic/exam.py` | **Extended** (optional per task). Added: board/exam registry + `boards()`/`exam_types()`, `OFFICIAL_RESULTS_PORTAL` + `OFFICIAL_RESULT_DOMAINS` + `is_official_result_url()` + `official_check_target()`, `countdown()`, `GRADE_SCALE`+`grade_scale()`+`explain_gpa()`, `normalise_students()`+`watch_summary()`; `result_ready_payload` now carries `source_only:true`. |
| `backend/core/logic/exam_tests_snippets.py` | **Extended** 10 → **15** plain-assert tests (official-URL detection incl. a fake site rejected, official-check carries no result, countdown, grade-scale/GPA-band from user value only + range guard, multi-student incl. cap + summary). `run_all()` → **15 passed**. |
| `.phaseB/up_exam_arb.json` | **NEW.** 54 ARB keys `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `api.dart`, `app_*.arb` (keys emitted to
> `up_exam_arb.json`), `models.py`, `urls`, sidebar, other screens. No
> flutter/build/migrations run. No Asalify touched. Zero Bangla glyphs in any
> `.dart` (all Bangla lives in the ARB json).

## ARB sync
Apply `.phaseB/up_exam_arb.json` (**54 keys**) into `app_bn.arb`/`app_en.arb`,
then `dart gen-l10n`. Placeholders: `examWatchSummary` → `{count}` (int),
`examYourGpaBand` → `{gpa}` (String), `{band}` (String), `examCountdownLeft` →
`{days}`,`{hours}` (int). Everything else is plain. The 22 pre-existing exam keys
(examTitle, examWatcherSection, examLabelField, examUrlField, examUrlHelper,
examUrlInvalid, examUrlOrDateRequired, examPickDate, examExpectedOn, examWatch,
examWatcherSaved, examWatcherSavedLocal, examWaiting, examTrafficSpikeNote,
examCardSection, examCardNote, examCardDefaultHeader, examFieldName,
examFieldRoll, examFieldBoard, examFieldGpa, examShareCard) are reused as-is.

## Backend wiring (model + endpoints)
Watcher model: user FK, label, url, expected_date (nullable), roll, reg, board,
exam. **ADVANCED adds**: `reg` (char), `board`/`exam` codes, and an optional
`students` JSON list (`[{label,roll}]`) for the parent/teacher case.

Endpoints (bind `exam.*`, `req_lang`):
- `POST /exam/watcher` {label,url,expected_date,roll,reg,board,exam,students[]}
  → run `exam.normalise_watcher` then (if present) `exam.normalise_students`;
  store. The app already posts all of these.
- `GET /exam/refs` → `{boards: exam.boards(lang), exams: exam.exam_types(lang),
  grade_scale: exam.grade_scale(lang), official: exam.official_check_target()}`
  (the app currently mirrors boards/exams/scale locally; this endpoint lets the
  server own them later with no UI change).
- Polling worker: use `exam.next_poll_minutes(expected_date, now, failures)`
  (sparse before day; backs off on result day) + `exam.is_result_day`. Fetch is
  a platform hook — fetch ONLY the public official page. Compare with
  `exam.snapshot_changed(prev, cur)`. On change → `exam.result_ready_payload`
  ("page changed, go check" — NEVER the result value).

## Check-result flow (official, honest)
`ExamOfficialCheck` opens `OFFICIAL_RESULTS_PORTAL` with `launchUrl` external.
We deliberately do NOT embed a WebView that auto-fills + reads back the result —
that risks screen-scraping a possibly-rate-limited/erroring page and presenting
it as fact. The honest contract shown to the user: "checks the official board
site". `official_check_target()` carries `official_only:true` and no result key.

## Section-21 coverage (all 10)
1. **Benchmarked** vs result-checker apps — honest where they fake: official-only
   source, traffic-spike truth, GPA explainer, countdown, multi-student, share
   card. Equal/better on every core task, without lying about results.
2. **Full flow**: set up / edit (live fields) / add + remove students / pick date
   / open official site / build + share card.
3. **Both rails**: manual entry + the watcher (auto poll of the official page).
   No AI entry here (no AI key needed); nothing is "AI-captured".
4. **Empty / loading / result-day / offline** states: empty card hint, saving
   spinner, waiting-vs-watching phase banners, traffic-spike note on result day,
   `examWatcherSavedLocal` fallback when the POST fails (offline).
5. **bn/en** strict (zero Bangla glyphs in .dart — all in ARB), light/dark via
   theme, small/large via `Expanded`/`Row` + ellipsis-safe `Text`.
6. Wire into **reminders** (expected-date reminder) + **watch feed**
   (`result_ready_payload` on page-change) + **chat** route `exam`; voice-runnable
   via that route.
7. **Server tests** 15 pass incl. scenarios: a FAKE result site is rejected as
   non-official; the official-check target carries no result; GPA band only from
   a user value (range-guarded); multi-student cap + honest summary.
8. **Share/result card**: festival-style `ExamResultCard` (brand gradient), built
   only from user values, "entered by you — not official" footnote travels in the
   shared text.
9. **Privacy/consent + never-fabricate**: no result ever stored/shown by Assisto;
   only user identifiers + official-site links; non-official URLs flagged; audit
   the watcher create/update in the model save hook.
10. Pending **independent reviewer**.
