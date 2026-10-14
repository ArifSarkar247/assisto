# Reminders + Notes/To-Do — ADVANCED calendar (#22, SPEC v2.1 §21) — integrator notes

Upgrades the Reminders and Notes/To-Do screens from GOOD → ADVANCED. The headline
is a **combined calendar / agenda view** over three stores at once (reminders +
to-dos + dated notes) with day/week/month zoom, plus advanced notes (checklists,
pin, tags, priority, due date, note↔reminder link, search) and advanced to-dos
(priority + due date). All editing stays offline-first through the existing
`SyncedRepo`s; recurrence is NOT re-implemented — the calendar reuses the NLP
engine's `nextOccurrence` (and the backend adds a matching `agenda()` helper).

## Advanced vs before
| Before (GOOD) | After (ADVANCED) |
| --- | --- |
| Reminders = one flat grouped list (Overdue/Today/Upcoming/Done). | + a **Calendar view** toggle: month grid (occurrence dots, overdue=red), week strip, day agenda — over reminders **and** to-dos **and** dated notes together. |
| Recurrence only shown as a chip. | Recurrence **expanded onto every day in view** by reusing `nextOccurrence` (Dart) / `expand` (Python). Completing a recurring item advances it. |
| Reschedule only via the full editor. | **Tap-reschedule** (date+time picker) straight from the agenda; **done/undo** one-tap with a snackbar Undo. |
| Notes = title + body only. | Notes gain an ordered **checklist** (tick inside the card), **pin**, free-form **tags**, **priority** flag, **due date** (lands on the calendar), **search** (title/body/tags/checklist), and **"make a reminder"** that links the note to a real reminder. |
| To-dos = title + done only. | To-dos gain **priority** + **due date** (schedulable, shown on the agenda, overdue-highlighted), sorted high-priority→open→done. |
| No priority / category on reminders. | Reminder cards show + set **priority** (flag) and **category** (chip) via the card menu. |

## Section-21 (all 10 pillars)
Empty (per-day "nothing on this day", notes/tasks empty states) · loading (lists
build from the offline cache; sync spinner in the app bar) · **offline**
(`OfflineBanner` on both screens + the calendar) · error (handled by repo/undo) ·
**bilingual** (40 new `[bn,en]` ARB pairs) · **WCAG** (icon+text never colour-only
— overdue is a red rail **and** a "Overdue" label; theme colour pairs; ≥44px
tap targets; `Semantics` selected/button on the zoom tabs) · **no-search-results**
state · done/undo everywhere · scenario-tested (backend).

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/reminders_screen.dart` | List⇄Calendar toggle in the app bar; `OfflineBanner`; priority + category chips on cards and a priority/category menu; made `ruleFromData` public (was `_ruleFromData`) so the calendar can reuse it. Grouping/NLP logic unchanged. |
| `app/lib/screens/notes_todos_screen.dart` | **Rewritten.** Note cards with pin/priority/checklist preview (tap to tick)/tags/due/linked-reminder chips + search bar + no-results state; advanced to-do tiles (priority, due, overdue) + edit; `OfflineBanner`. Delegates all editing to `rem_notes.dart`. |
| `app/lib/widgets/rem_calendar.dart` | **NEW.** `RemCalendarView` — month/week/day agenda. `_collect()` expands reminders (recurring via `nextOccurrence`) + dated to-dos + dated notes into a window; month/week paint per-day dots (overdue=danger); day agenda rows reschedule / complete+undo / open. |
| `app/lib/widgets/rem_notes.dart` | **NEW.** `editNote` (checklist/tags/priority/pin/due/body), `noteToReminder` (spawns + back-links a reminder, schedules a notification), `editTodo` (priority + due). |
| `backend/core/logic/reminders_engine.py` | **Extended (optional per task).** Added `agenda(items, start, end, now)` — the server-side mirror of the calendar's `_collect`: expands mixed reminder/todo/note items (recurring via existing `expand`) into one `when`-sorted list with `overdue`/`done`/`recurring` flags. No DB/AI; builds only on existing `expand`/`next_occurrence`. |
| `backend/core/logic/reminders_tests_snippets.py` | **Extended** +`test_agenda_combined` (weekly reminder expands to 2 Fridays in window + dated todo overdue + future note not overdue + sort + recurring-flag). `run()` now passes **149 assertions / 24 tests**. |
| `.phaseB/up_remcal_arb.json` | **NEW.** 40 ARB keys `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `app_*.arb` (keys emitted here), `api.dart`,
> models, `urls`, sidebar, `money_screen`, `reminders_quick_add.dart`, any other
> screen/widget. No flutter/build/migrations run. No Asalify touched.

## Verification done
- **Zero Bangla glyphs** (U+0980–U+09FF) in all four `.dart` files — verified by codepoint scan.
- `flutter analyze` on the 4 app files: after temporarily folding the 40 keys into `app_*.arb` and running `gen-l10n`, **"No issues found"** (the ARB + generated files were restored afterward; only the in-scope files remain changed). Without the merge, the only errors are the expected `undefined_getter` for the 40 not-yet-merged keys.
- `python3 backend/core/logic/reminders_tests_snippets.py` → **ALL PASS — 149 assertions across 24 tests.**

## ARB sync (the one integration step)
Fold `.phaseB/up_remcal_arb.json` (**40 keys**) into `app_bn.arb` / `app_en.arb`
and run `flutter gen-l10n`. Placeholders: **`notesMoreItems` takes `{count}` (int)** —
add `"@notesMoreItems": {"placeholders": {"count": {"type": "int"}}}` (mirrors the
existing `notesOpenCount`). Every other key is plain text. Reused as-is (no new
key needed): `remGroupOverdue/Today`, `remTomorrow`, `remRecurDaily/Weekly/Monthly/
Yearly`, `remRecurMonthlyOn`, `remRecurringAdvanced`, `title`, `notesBody`,
`notesTaskField`, `notesNewTask`, `notesPin/Unpin`, `notesOpenCount`, `add`, `save`,
`cancel`, `edit`, `delete`, `undo`, `commonDeleted`.

## Data shape (stored in each SyncedRepo item's `data`, no model/migration here)
- reminder: existing + `priority` (`"high"`|`"none"`), `category` (str).
- note: `title`, `body`, `checklist` (list of `{text, done}`), `tags` (list[str]),
  `priority`, `pinned` (bool), `due_at` (ISO-UTC|null), `reminder_local_id` (link).
- todo: `title`, `done`, `priority`, `due_at`.
All optional and read defensively (missing ⇒ treated as none/empty), so existing
rows render unchanged.

## Optional backend wiring
If/when a server calendar endpoint is wanted, bind `reminders_engine.agenda()`:
pass rows mapped to `{"id","kind","title","anchor","rule","done"}` with
`start`/`end` from the request window; return the sorted occurrence list. Purely
additive — no existing endpoint/behaviour changes.
