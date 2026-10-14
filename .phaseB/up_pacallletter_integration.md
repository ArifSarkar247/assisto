# PA Secretary Mode — #106 Call & email handling + #107 Letters/notices/memos

SPEC v2.1 §14, built to the §21 ADVANCED standard. Deterministic / MOCK (works
with no AI key), honest "AI-generated — review" markers, honest key-gated AI
seams, never auto-sends. Original Assisto identity. Extends the existing PA
module; no live Asalify, no api.dart/models.py/urls.py/sidebar/migration edits.

## New files

Backend (pure stdlib, no Django/DB/network/clock/AI):
- `backend/core/logic/pa_callemail.py` — call/email task inbox engine: enums +
  `validate` / `normalise` / `order` / `counts` + `draft_reply(item, category,
  sender, want_ai)` deterministic template drafter by category. No send/dial.
- `backend/core/logic/pa_letters.py` — formal document assembler: enums +
  `validate` + `build(doc_type, to, sender, subject, body_points, date,
  want_ai_body)` returning an ordered list of `{role, text, phrase}` lines.
- `backend/core/logic/pa_callemail_tests_snippets.py` — 12 plain-assert tests.
- `backend/core/logic/pa_letters_tests_snippets.py` — 13 plain-assert tests.

Flutter (zero Bangla literals; all strings are `AppLocalizations` getters):
- `app/lib/screens/pa/call_email_screen.dart` — `CallEmailScreen` (inbox + add/
  edit task form + suggested-reply sheet with category chips, editable draft,
  copy/share, AI-seam card). Mirrors `pa_callemail.py`.
- `app/lib/screens/pa/letters_screen.dart` — `LettersScreen` (saved list) +
  `_LetterEditor` (type chips, fields, live preview, copy/share, save, AI-seam
  card). Mirrors `pa_letters.py`.

## PA-hub wiring (integrator edits `pa_hub_screen.dart` — do NOT auto-edit)

Add two imports at the top with the other PA screen imports:

```dart
import 'call_email_screen.dart';
import 'letters_screen.dart';
```

Add two tiles to the `tools` `<_PaTool>[ ... ]` list (title getters reuse the
destination screens' own title keys, so the hub stays zero-string — matches the
existing pattern):

```dart
      _PaTool(Icons.contact_phone_outlined, t.paCeTitle,
          (_) => const CallEmailScreen()),
      _PaTool(Icons.description_outlined, t.paLetTitle,
          (_) => const LettersScreen()),
```

Hub tile TITLE ARB keys (already defined in the ARB file, also used as each
screen's AppBar title): `paCeTitle`, `paLetTitle`.

## ARB keys — `up_pacallletter_arb.json`

86 new keys total (format `key -> [bn, en]`; merge `bn` → app_bn.arb, `en` →
app_en.arb; @-metadata lives in app_en.arb only). ZERO Bangla in any .dart.

10 parameterized keys — add to `merge_arb.py` PARAMS so gen-l10n emits the
`String Function(...)` signatures (declared in the JSON's `_params` block):
- `paCeWith(name)`, `paCeStatCalls(count)`, `paCeStatEmails(count)`,
  `paCeStatDone(count)`, `paCeDeleteBody(name)`, `paLetDeleteBody(name)`
- `paCeTplAcknowledge(contact, subject, sender)`,
  `paCeTplDecline(contact, subject, sender)`,
  `paCeTplSchedule(contact, subject, sender)`,
  `paCeTplFollowup(contact, subject, sender)`

Shared honest marker key: `paAiReviewMarker` ("AI-generated draft — review and
edit before use").

REUSED existing keys (NOT redefined): `save, cancel, delete, edit, retry, copy,
share, copied, saved, saveFailed, deleteFailed, loadFailed`.

After merging, run `flutter gen-l10n` (/ the project's l10n codegen) so the
`tr.paCe*` / `tr.paLet*` getters exist — until then the analyzer will report
them missing (expected).

## Persistence — generic REST collections (no migration)

Integrator adds two names to `GENERIC_COLLECTIONS` in `core/views.py` (the list
near the `PaCollectionViewSet` precedent — `type()`-built viewsets, user-scoped,
audit-logged, PaCollectionItem JSON store, no migration):

```python
    # #106 PA call & email handling + #107 PA letters/notices/memos
    "pa/callemail", "pa/letters",
```

Row shapes (flat JSON on PaCollectionItem; the Flutter screens send/read these):

- `pa/callemail` (one call-or-email task):
  - `channel`  : "call" | "email"
  - `contact`  : string (name / organisation)
  - `subject`  : string
  - `priority` : "high" | "normal" | "low"
  - `status`   : "todo" | "done"
  - `notes`    : string
- `pa/letters` (one saved document):
  - `type`        : "letter" | "notice" | "memo" | "application"
  - `to`          : string (recipient; optional for notice)
  - `from`        : string (sender)
  - `subject`     : string
  - `body_points` : string (newline-separated paragraphs; the engine splits)
  - `date`        : string (free text, e.g. "14 October 2026" — no clock)

Endpoints used (generic api.dart helpers already exist — NOT edited):
`listItems / createItem / updateItem / deleteItem` on `'pa/callemail'` and
`'pa/letters'`.

## AI seam (honest, key-gated — documented, not wired to a live model here)

Both engines are the contract shape the integrator can later route to
`core.ai.generate` (gated on `integrations.is_enabled('anthropic')`):
- `pa_callemail.draft_reply(item, category, sender, want_ai=True)` → returns
  `ai_required=True`, empty `body`, `marker="ai_review"`. The template path
  (`want_ai=False`) is fully served offline and never fabricates "real" AI text.
  The UI shows `_DraftSheet`'s `_aiSeamCard` ("connect an AI key for a full
  AI-drafted reply").
- `pa_letters.build(..., want_ai_body=True)` with no `body_points` → returns
  `ai_required=True`, body section omitted, `marker="ai_review"`. With body
  points supplied the owner's own words are always assembled. The UI shows
  `_LetterEditor`'s `_aiSeamCard` ("connect an AI key for an AI-written body").

Nothing in either module calls a model, holds a key, sends mail or dials. Every
result carries `mock=True` + `marker=MARKER_KEY` ("ai_review").

## Tests

One block added to `core/tests.py` (after the `InChatAiSnippetTests` line),
registering both snippet suites via the existing `_make_snippet_case` helper:

```python
PaCallEmailSnippetTests = _make_snippet_case(
    "core.logic.pa_callemail_tests_snippets", "PaCallEmailSnippetTests")
PaLettersSnippetTests = _make_snippet_case(
    "core.logic.pa_letters_tests_snippets", "PaLettersSnippetTests")
```

25 checks total (12 call/email + 13 letters). Verified passing standalone:
`python3 pa_callemail_tests_snippets.py` → "pa_callemail: 12 checks passed";
`python3 pa_letters_tests_snippets.py` → "pa_letters: 13 checks passed". Django
discovery via `manage.py test` finds all 25 (DB creation is sandboxed in this
env; the logic is pure and needs no DB).

## Honesty / safety invariants held

- Works with no AI key: usable call/email task manager + template drafter, and a
  template-based formal-document generator.
- Honest `paAiReviewMarker` shown on every generated draft/document.
- Key-gated AI states never fabricate prose (empty body + `ai_required=True`).
- Never auto-sends: engines return text/state only; the UI copies/shares (manual
  send by the user); no dialer, no mail client, no address book.
- Formal document templates are correct/respectful in both Bangla and English
  (localised salutations/closings/headings per type).
