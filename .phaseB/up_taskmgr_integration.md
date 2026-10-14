# #21 Task Manager — integration note (SPEC v2.1 §21, ADVANCED)

Projects + Kanban board module. The user owns **projects**; each project owns
**tasks**. Board (To-do / Doing / Done) with move-between-columns, a list view,
status/assignee filters, task details (title, description, assignee, due date,
priority, progress %), honest overdue flags, and a per-project progress summary.
All §21 states: skeleton loading, welcome/empty, error+retry, offline banner,
confirm gates on every delete, bilingual, no clipped text at 360dp.

Deterministic, no AI. The UI mirrors the pure engine in
`backend/core/logic/task_manager.py` so app and server agree.

---

## 1. New files (all NEW — no existing files edited except the one tests.py line)

| File | Purpose |
|------|---------|
| `backend/core/logic/task_manager.py` | Pure engine: normalize/validate project+task, honest `is_overdue(now)`, `order_tasks`, `board` bucketing, `move_task` (done⇄active progress honesty), `filter_tasks`/`filter_unassigned`/`assignees`, `progress_summary`, `project_rollups`. No Django/DB/clock/AI. |
| `backend/core/logic/task_manager_tests_snippets.py` | 21 pure self-tests (`run_all()`), NOW pinned. |
| `app/lib/screens/task_manager_screen.dart` | The screen: projects list → per-project board/list + filters + task editor. Calls only the generic ApiClient helpers. |
| `app/lib/widgets/task_manager_model.dart` | `Project`/`TaskItem` models, pure Dart mirror of the engine, bilingual `tmStr` table (Bangla as `\u` codepoints — ZERO Bangla glyphs in any .dart). |
| `.phaseB/up_taskmgr_arb.json` | 67 NEW ARB keys `{key:[bn,en]}` + `_params`. |

**One-line edit** to `backend/core/tests.py` (registration only, after
`PaTasksSnippetTests`):

```python
TaskManagerSnippetTests = _make_snippet_case(
    "core.logic.task_manager_tests_snippets", "TaskManagerSnippetTests")
```

---

## 2. Persistence — EXACT generic collection paths the screen calls

The screen uses the proven generic REST-collection pattern (api.dart untouched).
It calls, on `context.read<AppState>().api`:

- `listItems('tasks_projects')` / `createItem('tasks_projects', body)` /
  `updateItem('tasks_projects', id, body)` / `deleteItem('tasks_projects', id)`
- `listItems('tasks_items')` / `createItem('tasks_items', body)` /
  `updateItem('tasks_items', id, body)` / `deleteItem('tasks_items', id)`

→ the generic helper hits `/<path>/` and `/<path>/<id>/`, i.e. the endpoints
**`/api/v1/tasks_projects/`** and **`/api/v1/tasks_items/`**.

### Row shapes (what the client POSTs / expects back, flattened `{id, ...}`)

`tasks_projects` row:
```json
{ "id": 1, "name": "Home renovation", "description": "", "color": "" }
```

`tasks_items` row (`project_id` ties it to a project; omitted ⇒ null/inbox):
```json
{
  "id": 7,
  "project_id": 1,
  "title": "Call the plumber",
  "description": "ring before noon",
  "assignee": "Karim",          // free-text name OR a Circle member name
  "status": "todo",             // todo | doing | done
  "priority": "high",           // urgent | high | normal | low
  "due": "2026-10-20T00:00:00", // ISO-8601, or "" for none
  "progress": 40                // 0..100 int; done ⇒ server/engine reads 100
}
```
The client already clamps/normalises on read (`TaskItem.fromJson`): unknown
status/priority → `todo`/`normal`, progress clamped 0..100, `done` pins 100.

### Register two OwnedViewSets (exact precedent: `PaCollectionViewSet`)

Both collections are the SAME `{id, ...data}` free-shape rows the PA collections
already use. Easiest path — reuse `PaCollectionItem` + `PaItemSerializer`
(serializer already flattens `{id, ...data}`; `collection` is `max_length=24`
and both names fit). **No migration needed** if you reuse `PaCollectionItem`.

In `backend/core/views.py` (next to `PaVisitorsViewSet` etc.):
```python
class TaskProjectsViewSet(PaCollectionViewSet):
    collection = "tasks_projects"; kind = "tasks_projects"

class TaskItemsViewSet(PaCollectionViewSet):
    collection = "tasks_items"; kind = "tasks_items"
```
`PaCollectionViewSet` already pins `collection` per subclass (rows never leak
across collections), is `OwnedViewSet` (user-scoped + audit-logged), and writes
through `PaItemSerializer`. If you prefer a dedicated model, clone
`PaCollectionItem`/`PaItemSerializer` as `TaskCollectionItem`/`TaskItemSerializer`
and add a migration — the row shapes above are unchanged either way.

In `backend/core/urls.py` (next to the `pa/*` registrations):
```python
router.register("tasks_projects", views.TaskProjectsViewSet, basename="tasks-projects")
router.register("tasks_items", views.TaskItemsViewSet, basename="tasks-items")
```

> Note: DRF's `DefaultRouter` already exposes `/tasks_projects/` and
> `/tasks_projects/{id}/`; the generic client's `_withSlash` appends the
> trailing slash, so the paths line up. If a stricter pattern is wanted the
> basenames can carry a hyphen while the route stays underscore.

The engine is server-safe if you want to validate/rollup server-side: feed the
stored rows (plain dicts) through `task_manager.validate_task`, `board(now)`,
`progress_summary(now)` etc. The app does not require it — it computes board,
order, overdue and summaries client-side from the same mirror logic.

---

## 3. ARB keys (67) — see `.phaseB/up_taskmgr_arb.json`

- Format `{key:[bn,en]}`, `tm` prefix, merge into `app_bn.arb`/`app_en.arb` at
  next sync. **Do NOT edit app_*.arb now** — the app ships every string TODAY via
  the local `tmStr` table in `task_manager_model.dart` (identical key set; 67/67
  parity verified).
- `_params` (placeholder `{n}` = locale-formatted integer):
  `tmPercentDone`, `tmSummaryLine`, `tmOverdueCount`.
- Bangla is real/natural; Bangla digits render via `tmNum` codepoints (zero
  Bangla glyphs in .dart).

---

## 4. Tests added

- 21 pure self-tests in `task_manager_tests_snippets.py`, registered as
  `TaskManagerSnippetTests` (one line in `core/tests.py`).
- `./.venv/bin/python manage.py test core --settings=assisto_backend.settings_test`
  → **1122 passed** (21 new + existing), 0 failures.
- Coverage: normalize/validate (project+task), honest overdue (done/no-due/garbage/
  exactly-now never overdue; tz-aware vs naive aligned), ordering (overdue→priority→
  due→title, done last, no-mutate), status/assignee filters (case/space-insensitive,
  bad-filter ignored), unassigned filter + assignees list, board bucketing+ordering,
  move-to-done/back progress honesty, bad-status/unknown-id no-ops, add/edit/delete,
  set_progress crossing the done boundary both ways, progress_summary (incl. honest
  empty), project_rollups (incl. task-less project reads zero).

---

## 5. Sidebar entry needed

Add ONE `SidebarItem` to the **Work** section (`id: 'work'`) in
`app/lib/widgets/sidebar_sections.dart` — projects/board/assign is work/team
organisation (not the personal Reminders & Memory notes/todos list):

```dart
SidebarItem(Icons.dashboard_customize_outlined, (t) => t.tmTitle,
    (_) => const TaskManagerScreen(),
    synonyms: ['task', 'project', 'board', 'kanban', 'assign', 'todo']),
```
(Uses `t.tmTitle` once the ARB keys are merged; until then the screen's own
AppBar title comes from `tmStr`. The sidebar label getter must exist in the ARB —
merge `up_taskmgr_arb.json` first, or temporarily point the label at an existing
getter.) Import `../screens/task_manager_screen.dart` at the top of the file.

---

## 6. Wiring steps (checklist for the integrator)

1. Register the two ViewSets in `views.py` and two routes in `urls.py` (§2).
   Reusing `PaCollectionItem` needs **no migration**.
2. Merge `up_taskmgr_arb.json` into `app_bn.arb`/`app_en.arb` (keep en/bn parity);
   regenerate localizations. The screen already works bilingually without this
   via the local table — the merge just lets the sidebar label use `t.tmTitle`.
3. Add the sidebar item + import (§5).
4. (Already done) `tests.py` registration line — run the suite.
5. Flutter analyze gate: zero Bangla glyphs in both .dart files (verified); all
   67 referenced `tmStr` keys exist in the local table (verified 1:1).

## 7. Confirmation
- **Zero Bangla literals in .dart** (both new files scanned U+0980–U+09FF: clean).
- 67 ARB keys, 3 parameterized. 21 new backend tests. Full suite: 1122 passed.
- No edits to api.dart, core/models.py, core/urls.py, sidebar, app_*.arb, or any
  migration. Only new files + one `core/tests.py` registration line.
