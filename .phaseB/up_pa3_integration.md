# PA Secretary Mode — #111 Delegate Access + #115 Personal-Task Oversight (integration note)

SPEC v2.1 §14, built to the §21 "advanced" standard. Pure, deterministic,
no-AI backend logic + two new Flutter screens with on-device mirrors. NEW files
only; the single edit to an existing file is the two `_make_snippet_case`
registration lines in `backend/core/tests.py`.

## New files

### Backend (pure logic — no Django, no DB, no clock, no AI)
- `backend/core/logic/pa_delegate.py` — #111 role-based delegate-access scope
  model: ordered `SCOPE_CATALOG`, `default_scopes()` (least privilege),
  `normalize_scopes`, `set_scope`, `can_access` (default-DENY decision),
  `grant_requires_confirm` / `confirm_grant` / `apply_grant` (confirm gate on
  sensitive grants), `audit_entry` + `summarize_audit` (append-only audit).
- `backend/core/logic/pa_delegate_tests_snippets.py` — 22 plain-assert tests.
- `backend/core/logic/pa_tasks.py` — #115 task oversight: `normalize_task`,
  `validate_task`, `is_overdue(task, now)`, `order_tasks(tasks, now)`,
  `add_task` / `edit_task` / `complete_task` / `delete_task`,
  `progress_summary(tasks, now)`. `now` is always passed in — honest overdue.
- `backend/core/logic/pa_tasks_tests_snippets.py` — 17 plain-assert tests.

### Flutter (new screens + on-device engine mirrors)
- `app/lib/screens/pa/delegate_access_screen.dart` — #111. Two tabs:
  Permissions (scope toggles, least-privilege welcome first-use state,
  sensitive-badge rows with honest "what this exposes" copy, confirm dialog on
  sensitive grant) and Access log (audit list + summary header, honest empty
  state). 360dp-safe (ellipsised tabs/labels, Wrap chips).
- `app/lib/screens/pa/personal_tasks_screen.dart` — #115. Prioritised task
  list (overdue-first), gradient progress header, status cycle tap, add/edit
  bottom-sheet editor, confirm-on-delete, welcome first-use state, honest
  overdue badges.
- `app/lib/widgets/pa_delegate_engine.dart` — mirror of `pa_delegate.py`
  (scope catalog, least-privilege default, confirm gate, local audit store).
- `app/lib/widgets/pa_tasks_engine.dart` — mirror of `pa_tasks.py` (ordering,
  overdue, progress, local store).

## tests.py registration (the one allowed edit)
Added after the existing `PaLiaisonSnippetTests` line:
```python
PaDelegateSnippetTests = _make_snippet_case(
    "core.logic.pa_delegate_tests_snippets", "PaDelegateSnippetTests")
PaTasksSnippetTests = _make_snippet_case(
    "core.logic.pa_tasks_tests_snippets", "PaTasksSnippetTests")
```
Standalone run: `pa_delegate: 22 tests passed`, `pa_tasks: 17 tests passed`
(39 total). Django harness discovers all 39 (test-DB creation is blocked by
local DB privileges, not a code failure).

## ARB keys
Emitted to `.phaseB/up_pa3_arb.json` — 71 new keys as
`{"key":["<bn>","<en>"]}`, with a `_params` object listing placeholder order.
Do NOT edit `app_en.arb`/`app_bn.arb` directly; merge this file + run codegen at
integration. The screens already reference every key via `AppLocalizations`
getters (ZERO Bangla literals in .dart). Parameterized keys + order:
- `paGrantConfirmBody(scope)`
- `paAuditSummary(total, sensitive, denied)`
- `paTaskDeleteBody(title)`
- `paProgressDone(percent)`
- `paStatTodo(count)` / `paStatDoing(count)` / `paStatDone(count)` / `paStatOverdue(count)`

Reused existing common keys (not re-emitted): `cancel`, `delete`, `edit`,
`save`, `retry`, `commonDeleted`.

Until these keys are merged + codegen runs, `flutter analyze` reports exactly 81
`undefined_getter`/`undefined_method` errors against `AppLocalizations` — all of
them for the new `pa*` keys, none for anything else (verified: zero non-ARB
analyzer issues). They vanish on ARB integration.

## Models to ADD (describe only — not added; do not touch core/models.py here)
1. `PADelegate` — one row per (owner, delegate) appointment.
   - `owner` FK → User (the person being helped).
   - `delegate` FK → User (the PA). unique_together(owner, delegate).
   - `scopes` JSONField (list[str]) — the AUTHORITATIVE granted scopes; default
     = `pa_delegate.default_scopes()` serialized to a list. WHY JSON: the scope
     catalog is small + evolving; a list avoids a migration per new scope and is
     validated server-side through `normalize_scopes` on every write.
   - `active` Bool (default True), `created_at`, `updated_at`.
   WHY: the scope set must live server-side so enforcement cannot be bypassed by
   a client (see seam below).
2. `PADelegateAudit` — append-only.
   - `owner` FK, `delegate` FK, `scope` CharField, `action` CharField (one of
     `pa_delegate.AUDIT_ACTIONS`), `detail` TextField(blank), `allowed` Bool,
     `at` DateTimeField(auto_now_add). Index on (owner, at desc).
   WHY: honest record of what the PA actually accessed, including denials; built
   via `pa_delegate.audit_entry(...)`. Never updated/deleted (append-only).
3. `PATask` — the owner's personal tasks the PA oversees.
   - `owner` FK → User, `title` CharField, `status` CharField
     (`pa_tasks.STATUSES`, default `todo`), `priority` CharField
     (`pa_tasks.PRIORITIES`, default `normal`), `due` DateTimeField(null=True),
     `note` TextField(blank), `created_at`, `updated_at`.
   WHY: oversight needs a persisted, server-owned list; ordering/overdue/progress
   are computed by `pa_tasks` with `now=timezone.now()` at request time.

(A migration would add these three models; not generated here per constraints.)

## Endpoints the screens call (describe only — add in a NEW views module + urls)
Suggested new module `backend/core/views_pa_delegate.py`, mounted under
`/api/v1/pa/` (do NOT edit core/urls.py from this task — add the include at
integration).

Delegate access (#111) — all scoped to the authenticated OWNER:
- `GET  /api/v1/pa/delegate/{delegate_id}` → `{scopes, catalog}` where
  `catalog = pa_delegate.catalog()` and `scopes` is the stored list.
- `POST /api/v1/pa/delegate/{delegate_id}/scope` body `{scope, on, confirmed}`
  → calls `pa_delegate.apply_grant(stored_scopes, scope, on, confirmed)`;
  persists `result["scopes"]` only when `changed`; returns the gate so the app
  can raise the confirm dialog when `needs_confirm`. Writes a `granted`/`revoked`
  audit row.
- `GET  /api/v1/pa/delegate/{delegate_id}/audit` → list + `summarize_audit`.

The DELEGATE-facing routes (what the PA actually reads/does) each FIRST call
`pa_delegate.can_access(db_scopes, SCOPE_*)` and, if False, return 403 AND write
a `denied` audit row:
- `GET /api/v1/pa/schedule` → requires `SCOPE_SEE_SCHEDULE`
- `GET /api/v1/pa/briefs` → requires `SCOPE_VIEW_BRIEFS`
- visitors/follow-ups/contacts/money/health/documents → their matching scope.

Personal-task oversight (#115) — reads require `SCOPE_SEE_TASKS`, writes require
`SCOPE_MANAGE_TASKS` (both checked via `can_access` on DB-stored scopes):
- `GET    /api/v1/pa/tasks` → `order_tasks(rows, timezone.now())` +
  `progress_summary(rows, now)`.
- `POST   /api/v1/pa/tasks` body `{title, priority, due, note}` → `validate_task`
  then create.
- `PATCH  /api/v1/pa/tasks/{id}` → partial edit / complete.
- `DELETE /api/v1/pa/tasks/{id}` → delete (UI already confirmed).

## Sidebar / wiring
Both screens live under PA Secretary Mode. Wire exactly like the existing PA
screens and `SocialComposeScreen` (pushed from Agent Studio via
`MaterialPageRoute`):
- From the PA Secretary Mode hub (or the Work group entry that other PA agents
  own), add two rows:
  - "Delegate access" → `const DelegateAccessScreen()`
  - "Personal task oversight" → `const PersonalTasksScreen()`
  using the drawer's `_push((_) => const …Screen())` pattern
  (`app/lib/screens/app_drawer.dart`). One place each, per SIDEBAR_LAYOUT.md.
- No bottom-nav change; drawer-only, consistent with the app's nav rule.

## SERVER-SIDE SCOPE-ENFORCEMENT SEAM (the trust core)
The scope set a client SENDS is advisory only. Enforcement is:
1. The authoritative grant is `PADelegate.scopes` in the DB.
2. On EVERY delegate action, the view loads that row and calls
   `pa_delegate.can_access(db_scopes, required_scope)` — NEVER a scope list the
   client supplied. `can_access` is default-DENY: an unknown, sensitive, or
   never-granted scope returns False, so a FORGED client scope reads as NOT
   granted and the action is refused (403) + logged as `denied`.
3. `normalize_scopes` runs on every write, dropping anything outside the catalog
   (defence in depth against a stale/hostile client).
4. Granting a sensitive scope requires `confirmed=True` to pass
   `apply_grant`/`confirm_grant`; without it the grant is held (`needs_confirm`)
   and nothing is persisted.
The Flutter `canAccess`/local store is a UI convenience for offline preview and
honest labelling only — it grants nothing on the server.

## Honesty / constraints checklist
- LEAST PRIVILEGE: `default_scopes()` = schedule/briefs/tasks (read-only); no
  sensitive scope is ever auto-granted.
- No fake data: screens show welcome/empty/error states; audit shows real
  recorded events incl. denials.
- Deterministic, no AI: every helper is pure; `now` is passed in for overdue.
- Confirm gates: sensitive grant (delegate) + delete (task).
- Zero Bangla literals in .dart (verified U+0980–U+09FF absent in all 4 files).
- Did NOT touch: api.dart, core/models.py, core/urls.py, sidebar impl,
  app_*.arb, migrations, pa_schedule/pa_brief/pa_visitor/pa_liaison, Asalify.
