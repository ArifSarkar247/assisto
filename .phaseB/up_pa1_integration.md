# PA Secretary — Schedule control (#103) + Meeting reminder & 1-page brief (#104)

SPEC v2.1 §14, built to the §21 ADVANCED standard. This is NEW work. Everything
below is additive; the integrator wires api.dart / models.py / urls.py / sidebar
/ ARB from these notes. No existing files were edited except the single
registration block in `backend/core/tests.py`.

## New files

Backend (pure logic + self-tests):
- `backend/core/logic/pa_schedule.py` — #103. Pure, deterministic, no DB, no
  clock (every time-dependent call takes `now`), no AI. Slot normalise/validate,
  HONEST conflict (overlap) detection with per-pair overlap minutes + index
  mapping, day/week agenda bucketing, `next_up` summary, `day_summary` counts.
- `backend/core/logic/pa_brief.py` — #104. Pure, deterministic. Reminder lead
  normalisation + fire-times + summary (honest `all_past` flag), DETERMINISTIC
  one-page brief assembly (`assemble_brief`), `brief_completeness` meter,
  `share_text` (caller passes localized labels), and `ai_brief_plan` — the
  documented KEY-GATED AI seam (returns the request shape only; never calls a
  model, never built).
- `backend/core/logic/pa_schedule_tests_snippets.py` — 18 plain-assert tests.
- `backend/core/logic/pa_brief_tests_snippets.py` — 15 plain-assert tests.

Flutter (new screens + pure engine mirror; ZERO Bangla glyphs in any .dart):
- `app/lib/screens/pa/pa_schedule_screen.dart` — #103 PA schedule surface.
- `app/lib/screens/pa/pa_meeting_brief_screen.dart` — #104 reminder config +
  1-page brief + share/export.
- `app/lib/widgets/pa_engine.dart` — on-device deterministic mirror of
  `pa_schedule.py` + `pa_brief.py` (conflicts / agenda / next_up / brief
  assembly / completeness / reminder math) plus the label-mapping helpers.

## Tests added

- `core/tests.py`: two registration lines (the one allowed edit) —
  `PaScheduleSnippetTests` and `PaBriefSnippetTests` via the existing
  `_make_snippet_case` pattern (same as `SocialComposeSnippetTests`).
- 33 tests total (18 schedule + 15 brief); all pass standalone:
  `python3 -c "import core.logic.pa_schedule_tests_snippets as t; t.run_all()"`
  `python3 -c "import core.logic.pa_brief_tests_snippets as t; t.run_all()"`
  (The Django test runner collects all 33; creating the test DB is blocked in
  this sandbox by Postgres perms, unrelated to these tests.)

## ARB keys

`.phaseB/up_pa1_arb.json` — 82 NEW keys as `{"key":["<bn>","<en>"]}`, plus a
`_params` object for the 6 parameterized keys:
- `paInMinutes` {n}, `paMinutes` {n}, `paSlotCount` {n},
  `paConflictSummary` {n}, `paBriefReady` {n}, `paReminderNext` {n,time}.

REUSED existing getters (NOT re-emitted): `cancel, save, edit, delete, retry,
copy, copied, commonDeleted`. Key names were checked for NO collision with the
sibling PA ARB files `up_pa2_arb.json` / `up_pa3_arb.json`.

Merge the 82 keys into `app_bn.arb` / `app_en.arb` (then regenerate
`AppLocalizations`). Until merged, `flutter analyze` on the three new files
reports exactly 95 "getter isn't defined for AppLocalizations" errors and
nothing else — those clear the moment the keys land.

## Endpoints the screens call

The screens persist via the EXISTING generic item helpers in `api.dart`
(`listItems/createItem/updateItem/deleteItem`) — NO api.dart edit needed. They
use two new REST paths; wire them as item collections:

- `GET  /api/v1/pa_schedule/`  — list rows; each row is `{"data": {...}}` or the
  raw object. (#103)
- `POST /api/v1/pa_schedule/`  — upsert. The screen posts `{"items": [<slot>...]}`
  (same convention as the existing `appointments` surface). (#103)

The brief screen does NOT call the network itself — it edits the selected
meeting map in memory and hands the updated map back to the schedule screen via
an `onSaved` callback, which re-saves through the same `pa_schedule` POST. So
#104 needs no separate endpoint for the deterministic path.

Slot / meeting shape (normalised by `pa_schedule.normalise_slot`; the brief
screen adds the #104 fields onto the SAME object):
```
{
  "id": <pk, optional>,
  "title": str, "kind": meeting|appointment|call|task|block,
  "start": ISO8601, "duration_min": int,
  "place": str, "people": [str...], "note": str,
  "status": tentative|confirmed|done|cancelled,
  # added by the brief screen (#104):
  "purpose": str, "agenda": [str...], "prep": [str...],
  "organiser": str, "leads": [int minutes-before...]
}
```

### Optional (cleaner) endpoints if you prefer a real model over the item blob
- `GET/POST /api/v1/pa/meetings/`, `PATCH/DELETE /api/v1/pa/meetings/<id>/`
  backed by `PaMeeting` (below). If you adopt these, change the two path
  strings in `pa_schedule_screen.dart` (`'pa_schedule'`) and keep the same
  slot shape — the engine/UI are model-agnostic.

## Model(s) for the integrator to add (describe-only; NOT created here)

`PaMeeting` (recommended; owned by the account whose PA/secretary manages it):

| field          | type                         | why |
|----------------|------------------------------|-----|
| `owner`        | FK → User                    | whose schedule this slot belongs to |
| `title`        | CharField                    | required; the agenda/brief heading |
| `kind`         | CharField(choices)           | meeting/appointment/call/task/block — drives icon/colour |
| `start`        | DateTimeField                | required; agenda ordering, conflict math, reminders |
| `duration_min` | PositiveIntegerField         | end = start + duration; conflict + brief "when" |
| `place`        | CharField(blank)             | brief "where" |
| `people`       | JSONField(list, default=[])  | attendee display names; brief "who" |
| `note`         | TextField(blank)             | free note; brief "notes" |
| `status`       | CharField(choices)           | tentative/confirmed/done/cancelled; cancelled is hidden from agenda & ignored by conflicts |
| `purpose`      | CharField(blank)             | #104 brief "what" |
| `agenda`       | JSONField(list, default=[])  | #104 agenda bullets |
| `prep`         | JSONField(list, default=[])  | #104 prep checklist items |
| `organiser`    | CharField(blank)             | #104 listed first in brief "who" |
| `leads`        | JSONField(list, default=[])  | #104 reminder lead offsets (minutes before) |
| `created_at` / `updated_at` | auto DateTimeFields | housekeeping |

Why a model (vs. reusing `Appointment`): the PA schedule is its own organised
surface with secretary-specific fields (`kind`, `status=tentative/confirmed`,
`organiser`, brief `purpose/agenda/prep`, `leads`). Reusing the owner's personal
`Appointment` would overload it; a dedicated `PaMeeting` keeps the two clean
while the slot SHAPE deliberately matches `meetings.py` so you may back both with
one table later if you choose. If you go with the generic item blob instead, NO
model/migration is needed to ship — the screens already work against
`pa_schedule` item storage.

Server-side validation/derivation should call the pure logic so the API and app
never drift:
`normalise_slot`, `conflicts`, `agenda`, `next_up` (pa_schedule);
`clean_leads`, `reminder_times`, `assemble_brief`, `share_text` (pa_brief).

## Reminders / notifications wiring

On save of a slot with `leads`, schedule notifications at
`pa_brief.reminder_times(start, leads, now)` via the EXISTING reminders/
notifications pipeline. `reminder_summary` already surfaces an honest
`all_past` state the UI shows — don't schedule past fire-times (the function
already drops them).

## AI-enhanced brief (key-gated seam — documented, NOT built)

`pa_brief.ai_brief_plan(meeting, lang)` returns the request shape a real
provider (`core.ai.generate`) would receive to polish the owner's OWN entered
notes into crisper agenda/prep points. It sets `ai_required=True`, calls no
model, needs no key. The brief screen shows this as a DISABLED, lock-badged
"Enhance with AI (coming soon)" affordance (`paBriefAiCta`). To enable later:
gate on an AI key, route `ai_brief_plan(...)` through `core.ai.generate`, and
flip the button's `onPressed`. The deterministic `assemble_brief` remains the
always-available honest path.

## Sidebar entry needed (you wire; I must not touch the sidebar)

Add under the **Work** section:
- **PA Secretary** → open `PaScheduleScreen`
  (`app/lib/screens/pa/pa_schedule_screen.dart`). The brief screen is reached
  from a slot's "Open brief" action — it does not need its own sidebar entry.
- Suggested label keys (if you want localized nav text, add to the ARB too):
  reuse `paScheduleTitle` for the destination title. Icon suggestion:
  `Icons.badge_outlined` or `Icons.event_note`.
- NOTE: sibling PA screens from the parallel build (delegate access, liaison,
  visitor filter, personal tasks) live in the same `screens/pa/` folder; group
  them under a single "PA Secretary" nav area as you see fit.

## Wiring steps (summary)

1. Merge the 82 keys from `up_pa1_arb.json` into `app_bn.arb` / `app_en.arb`;
   regenerate `AppLocalizations`. (Clears the 95 analyze errors.)
2. Either (a) expose `pa_schedule` as a generic item collection endpoint
   (fastest — screens work as-is), or (b) add the `PaMeeting` model + a
   `pa/meetings` REST endpoint and change the two path strings in
   `pa_schedule_screen.dart`.
3. On slot save, schedule reminder notifications via
   `pa_brief.reminder_times`.
4. Add the **PA Secretary → PaScheduleScreen** entry under the Work section of
   the sidebar.
5. (Later, optional) enable the key-gated AI brief seam per the section above.

## Honest-states checklist (ADVANCED §21) — what shipped

- Loading skeleton, error + retry, offline banner (keeps last list), empty
  "welcome" first-use state, and a separate honest "nothing in this day/week"
  state distinct from the first-use empty.
- Confirm gate before delete (destructive) with explicit "can't be undone" copy.
- Conflicts are HONEST: exact overlap minutes, per-pair, with a clash badge on
  each affected card and a summary banner — never a vague "may conflict".
- Brief is deterministic assembly only (labelled), shows which sections are
  missing + an "N% ready" meter, never fabricates agenda/prep.
- Reminder config honestly flags "all chosen reminders are in the past" and
  "set a start time first".
- AI enhancement is a DISABLED, clearly-labelled key-gated seam, not a fake.
- bn/en throughout via ARB getters; no clipped text (ellipsis + maxLines on
  titles/chips); ZERO Bangla glyphs in any .dart (verified).
