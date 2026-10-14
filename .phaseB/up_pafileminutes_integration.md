# Integration note — PA Secretary Mode key-gated extensions #109 Filing + #110 Meeting Minutes

SPEC v2.1 §14 (PA Secretary Mode) / §21 (ADVANCED). Both features are built to
Section-21 "advanced" as DETERMINISTIC/MOCK that work with NO key, with honest
markers and honest key-gated seams. NOTHING fabricated. This agent did NOT touch
`api.dart`, `core/models.py`, `core/urls.py`, the sidebar, `app_*.arb`,
migrations, Flutter builds, or Asalify.

---

## 1. New files created (6)

Backend (pure, deterministic — no Django/DB/network/clock/OCR/STT/AI):
- `backend/core/logic/pa_filing.py` — #109 filing cabinet engine.
- `backend/core/logic/pa_filing_tests_snippets.py` — 15 plain-assert tests.
- `backend/core/logic/pa_minutes.py` — #110 meeting-minutes engine.
- `backend/core/logic/pa_minutes_tests_snippets.py` — 16 plain-assert tests.

Flutter (ZERO Bangla literals; each embeds a verbatim Dart mirror of its backend
engine so previews are deterministic + identical offline):
- `app/lib/screens/pa/filing_screen.dart` — `FilingScreen`.
- `app/lib/screens/pa/meeting_minutes_screen.dart` — `MeetingMinutesScreen`.

One line pair added to `backend/core/tests.py` (right after `PaTasksSnippetTests`):
```python
PaFilingSnippetTests = _make_snippet_case("core.logic.pa_filing_tests_snippets", "PaFilingSnippetTests"); PaMinutesSnippetTests = _make_snippet_case("core.logic.pa_minutes_tests_snippets", "PaMinutesSnippetTests")
```

---

## 2. Persistence — generic REST collections (NO api.dart edit, NO migration)

Both screens use the existing generic helpers:
`context.read<AppState>().api.listItems/createItem/updateItem/deleteItem(path)`.
Rows reuse the `PaCollectionItem` flexible per-user JSON store + `PaItemSerializer`
flatten, exactly like `pa/visitors`, `pa/followups`.

**Integrator: append these three names to `GENERIC_COLLECTIONS` in
`backend/core/views.py`** (the `type()`-built ViewSet family reuses
`PaCollectionItem` + `PaItemSerializer`, user-scoped by `PaCollectionViewSet`,
audit-logged — NO migration, NO urls.py change if the family is already routed):

```python
    # #109 PA filing cabinet + #110 PA meeting minutes (+ flat action-item view)
    "pa/filing", "pa/minutes", "pa/actionitems",
```

### Collection shapes (each row round-trips as `{id, ...data}`)

`pa/filing` (one filed document):
```json
{
  "id": 1,
  "title": "Office lease agreement",
  "category": "contracts|invoices|letters|reports|other",
  "image_ref": "<opaque handle: local path or server media id, may be empty>",
  "notes": "",
  "date": "2026-10-14",
  "tags": ["legal", "2026"],
  "has_image": true,
  "extracted_text": "",          // HONEST: ALWAYS "" until the OCR key fills it
  "ocr_state": "ocr_locked",     // honest key-gated state marker
  "ai_required": false,
  "mock": true
}
```

`pa/minutes` (one meeting, action items embedded):
```json
{
  "id": 1,
  "title": "Weekly sync",
  "date": "2026-10-14",
  "attendees": ["Rahman", "Karim"],
  "agenda": ["Budget review"],
  "decisions": ["Approve Q4 budget"],
  "actions": [
    {"title": "Send budget sheet", "owner": "Karim", "due": "2026-10-20", "status": "open|doing|done"}
  ],
  "stt_state": "stt_locked",     // honest key-gated state marker
  "ai_required": false,
  "mock": true
}
```

`pa/actionitems` (OPTIONAL flat, per-owner cross-meeting action view). The
embedded `actions` inside a `pa/minutes` row are the source of truth; this flat
collection is a convenience projection the app/executor MAY write via
`pa_minutes.action_rows(entry, meeting_id=<minutes row id>)`:
```json
{"id": 9, "title": "Send budget sheet", "owner": "Karim", "due": "2026-10-20", "status": "open", "meeting_id": "1"}
```
> The two shipped screens edit actions EMBEDDED in the `pa/minutes` entry and do
> not themselves write the flat `pa/actionitems` view. The collection is
> registered so a future cross-meeting action dashboard can read/write it with
> zero further backend work.

---

## 3. OCR / Transcription key-gated seams (honest, NEVER fabricated)

| Feature | Integrations key | Locked state fn | Ready state | Promise |
|---|---|---|---|---|
| #109 Filing auto-read | `ocr` | `pa_filing.ocr_state(False)` → `{"state":"ocr_locked","key":"ocr","can_autoread":false}` | `ocr_state(True)` → `ocr_ready` | "connect an OCR key to auto-extract text / title" |
| #110 Minutes auto-generate | `transcription` | `pa_minutes.transcription_state(False)` → `{"state":"stt_locked","key":"transcription","can_autominutes":false}` | `transcription_state(True)` → `stt_ready` | "connect a transcription key to auto-generate minutes from audio" |

Both keys already exist in `core/integrations.py` REGISTRY (`ocr`, `transcription`).

Client gating: each screen has `bool get _ocrReady => false;` /
`bool get _sttReady => false;` (OCR/STT is owner-only and routed server-side, so
the honest client default is LOCKED). The seam cards (`_OcrSeamCard`,
`_SttSeamCard`) render the honest "connect a key…" copy when locked and a short
"auto-read/auto-minutes on" note when ready. **To light the seam green when the
key is live:** have the screen read the per-feature enabled flag however the app
surfaces `integrations.is_enabled('ocr')` / `is_enabled('transcription')` and
flip the getter — no other change needed. A REAL auto-read / auto-generate is
routed through the key-gated provider ELSEWHERE; neither engine runs OCR/STT and
`extracted_text` / minutes are **never fabricated** (`extracted_text` is always
`""` from `build_item`; `summarise`/`build_minutes` only ever format fields the
user already entered).

---

## 4. ARB keys — `.phaseB/up_pafileminutes_arb.json`

**73 new keys** (`{key: [bn, en]}`, both filled, bn natural). Placeholder
params live under `_params` (7 entries) — the merge SKIPS keys nested there, so
add those manually to `app_{en,bn}.arb` placeholders.

Common keys already present and reused (NOT in the json): `cancel`, `delete`,
`edit`, `save`, `retry`, `loadFailed`, `saveFailed`, `deleteFailed`.

Parameterised keys (declare placeholders): `paFileFolderAll{count}`,
`paFileDeleteBody{title}`, `paMinOwnerHint{owner}`, `paMinDueHint{due}`,
`paMinAttendeeCount{count}`, `paMinActionCount{open,done}`,
`paMinDeleteBody{title}`.

After merge: `flutter gen-l10n` → `flutter analyze` must be 0 (the two new
screens reference only these keys + the reused common ones).

---

## 5. PA-hub tiles — EXACT paste into `pa_hub_screen.dart`

Add these two imports beside the other PA screen imports (after
`import 'personal_tasks_screen.dart';`):
```dart
import 'filing_screen.dart';
import 'meeting_minutes_screen.dart';
```

Add these two tiles to the `tools` list in `_PaTool[]` (e.g. after the tasks
tile, before the delegate tile). **Titles reuse the destination screen's own
title getter** so the hub carries zero new strings — matching the existing hub
convention (`t.paScheduleTitle`, etc.):
```dart
      _PaTool(Icons.folder_copy_outlined, t.paFileTitle,
          (_) => const FilingScreen()),
      _PaTool(Icons.groups_outlined, t.paMinTitle,
          (_) => const MeetingMinutesScreen()),
```

Title ARB keys used by the tiles: **`paFileTitle`** and **`paMinTitle`** (both
in the ARB json above).

---

## 6. Tests

- `pa_filing_tests_snippets.py`: **15** tests (category coerce/suggest/order,
  tag normalise, validate, build_item honest-OCR shape, ocr_state locked/ready,
  filter by category/query/tag, non-mutation, counts, all_tags).
- `pa_minutes_tests_snippets.py`: **16** tests (status/list normalise, action
  normalise/validate, order not-done→due→title + non-mutation, build shape +
  honest STT seam, empty sections, transcription_state, action_rows flatten with
  meeting_id, summary counts/sections/omit-empty/determinism).
- **Total new backend tests: 31.** Both run standalone AND under the Django
  harness import path `core.logic.*` (verified green). Wired via the one
  `_make_snippet_case` pair added to `core/tests.py`.

Run:
```bash
cd backend && python3 -c "import core.logic.pa_filing_tests_snippets as f, core.logic.pa_minutes_tests_snippets as m; f.run_all(); m.run_all()"
```

---

## 7. Wiring checklist for the integrator

1. Merge `up_pafileminutes_arb.json` → `app_{en,bn}.arb` (manually wire the 7
   `_params` placeholder keys).
2. Append `"pa/filing", "pa/minutes", "pa/actionitems"` to `GENERIC_COLLECTIONS`
   in `core/views.py`.
3. Add the 2 imports + 2 tiles to `pa_hub_screen.dart` (snippets in §5).
4. `flutter gen-l10n` → `flutter analyze` (expect 0).
5. Backend tests (expect +31).
6. Gallery review `FilingScreen` + `MeetingMinutesScreen` (bn + en) → ship.
```
