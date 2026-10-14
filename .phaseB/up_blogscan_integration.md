# Integration — Blog & script writing (#130) + Document scanner (#29)

Two NEW advanced, KEY-GATED features (SPEC v2.1 §21). Both ship a deterministic
/ mock layer that works with **no key**, honest "AI-generated — review" / "connect
a key" markers, and documented key-gated seams. Nothing auto-posts; no OCR/AI
text is ever fabricated. Mirror pattern follows `social.py` / `mock_interview`.

I did NOT touch: `api.dart` request helpers, `core/models.py`, `core/urls.py`,
the sidebar/`sidebar_sections.dart`, `app_*.arb`, migrations, Flutter builds,
Asalify. Only NEW files + one `core/tests.py` registration block.

---

## New files

Backend (pure deterministic logic + self-tests):
- `backend/core/logic/blog_writer.py` — template-assembly engine (blog / script /
  caption / outline scaffolds).
- `backend/core/logic/blog_writer_tests_snippets.py` — 11 plain-assert tests.
- `backend/core/logic/doc_scanner.py` — document organiser (type coerce/suggest,
  validate, filter/search, counts).
- `backend/core/logic/doc_scanner_tests_snippets.py` — 14 plain-assert tests.

Flutter (NEW screens; each carries its own on-device mirror of the Python logic
+ local card/chip widgets, so no shared widget files were added or edited):
- `app/lib/screens/blog_writer_screen.dart` (mirrors `blog_writer.py`).
- `app/lib/screens/doc_scanner_screen.dart` (mirrors `doc_scanner.py`).

ARB keys to merge:
- `.phaseB/up_blogscan_arb.json` — 69 keys ({bn, en}); `bw*` ×40, `ds*` ×29.

Tests registration (one block appended after `PriceRadarSnippetTests`):
- `backend/core/tests.py`:
  `BlogWriterSnippetTests = _make_snippet_case("core.logic.blog_writer_tests_snippets", "BlogWriterSnippetTests")`
  `DocScannerSnippetTests = _make_snippet_case("core.logic.doc_scanner_tests_snippets", "DocScannerSnippetTests")`

---

## Persistence — generic REST collection (PaCollectionItem, NO migration)

Both reuse the existing flexible per-user JSON collection via `PaCollectionViewSet`
(flatten serializer → each row round-trips as `{id, ...data}`). The integrator
adds two names to `GENERIC_COLLECTIONS` in `backend/core/views.py` (the list that
auto-builds `GENERIC_COLLECTION_VIEWSETS` via `type()` — no new ViewSet classes,
no model, no migration):

```python
# #130 Blog & script writing + #29 Document scanner (§21, advanced)
"blog/drafts", "docscan/items",
```

That makes `/api/v1/blog/drafts/` and `/api/v1/docscan/items/` live with the
standard list/create/retrieve/update/delete, user-scoped + audit-logged
(`log(user, "pa.<collection>.create", ...)` via the base `perform_create`).

The screens call these through the UNMODIFIED generic helpers already in
`api.dart`: `listItems(path)`, `createItem(path, body)`, `updateItem(path, id,
body)`, `deleteItem(path, id)`.

### Collection shapes

`blog/drafts` row `data`:
```json
{
  "format":  "blog|script|caption|outline",
  "topic":   "<string>",
  "tone":    "informative|casual|persuasive|storytelling|professional",
  "length":  "short|medium|long",
  "lang":    "bn|banglish|en",
  "title":   "<working title line, for the list label>",
  "body":    "<edited scaffold text (markdown-ish)>",
  "saved_at":"YYYY-MM-DD"
}
```

`docscan/items` row `data`:
```json
{
  "title":          "<string, required>",
  "doc_type":       "nid|passport|certificate|bill|receipt|other",
  "image_ref":      "<opaque handle: local file path, or server media id>",
  "notes":          "<string>",
  "date":           "YYYY-MM-DD",
  "extracted_text": ""   // HONEST: empty until the key-gated OCR seam fills it
}
```

### Document image / blob seam (no storage invented)

The organiser holds **no bytes**. `image_ref` is an opaque string the UI fills
with the local file path returned by `ImagePicker().pickImage(...).path` — the
same way other media screens keep a local path (e.g. `vault_screen.dart`
`_pickImage` returns `x?.path`). The engine never reads `image_ref`. If/when the
owner wants durable cross-device blobs, the integrator can swap `image_ref` to a
server document id produced by an EXISTING media upload endpoint; no change to
the organiser logic is needed. (I deliberately did NOT call the vault's
`uploadDocumentWithDetails`, since that lives in `api.dart` which is off-limits,
and the scanner complements rather than duplicates the vault.)

---

## Key-gated seams + which Integrations keys

Both features are fully usable with **no key**; the key only unlocks the richer
path, routed server-side elsewhere (NOT in these pure modules).

| Feature | Seam | Integrations key | Honest no-key state |
|---|---|---|---|
| #130 Blog/script | full fleshed-out AI draft in the chosen language | `anthropic` (REGISTRY, category AI) | mock scaffold labelled "AI-generated — review"; `_FullAiCard` shows "connect an AI key for a full AI draft" |
| #29 Doc scanner | OCR auto-read of text from the image | `ocr` (REGISTRY, category AI) | `extracted_text` stays `""` (never fabricated); `_OcrSeamCard` shows "connect an OCR key to auto-read text"; tool works as a manual organiser |

- `blog_writer.assemble()` returns `ai_required=False, mock=True,
  marker="ai_review", ai_full_requires="anthropic"`. The real path reuses the
  SAME request shape (`format/topic/tone/length/lang`) via `core.ai.generate`
  (contract only; nothing here calls a model).
- `doc_scanner.ocr_state(ocr_key_present)` returns
  `{"state": "ocr_locked"|"ocr_ready", "key": "ocr", "can_autoread": bool}`. The
  Dart screen defaults to LOCKED (`_ocrReady => false`) because the OCR key is
  owner-only and not exposed to the client; when the owner connects `ocr`, the
  server-side route fills `extracted_text` and the UI can flip to `ocr_ready`.
  `filter_items` already searches `extracted_text`, so OCR'd text becomes
  searchable the moment the seam fills it — without ever being fabricated.

Both `anthropic` and `ocr` already exist in
`backend/core/integrations.py::REGISTRY` — no registry edit needed.

### owner_actions note

No new owner action is required: the two keys (`anthropic`, `ocr`) are already
documented in `owner_actions/integrations.md` (the shared "how to connect" note
the Integrations dashboard deep-links). When the owner connects either key via
the existing Integrations flow, the corresponding richer path turns on
automatically (`integrations.is_enabled("anthropic")` / `is_enabled("ocr")`); no
code change, matching the project's key-gating convention. The server executor
that wires `assemble()` → `core.ai.generate` and the OCR route → the `ocr`
provider is the only remaining owner-side wiring, and it is gated on
`is_enabled(...)` so it stays off until a working key is saved.

---

## Tests

- `blog_writer_tests_snippets.py` — **11** tests (validation, determinism,
  honest flags, topic fill, length→section count, script hook/CTA beats, caption
  2-section cap, bracketed placeholder prompts never-fabricated, text-block
  assembly, total/no-raise on bad input).
- `doc_scanner_tests_snippets.py` — **14** tests (type coerce/suggest, validate,
  build-row shape + honest OCR flags, manual-entry-without-image, bad-type
  coercion, ocr_state locked/ready, filter-by-type, filter-all, search across
  title/notes/extracted_text, stable-non-mutating, zero-filled type counts).
- Both run standalone (`python <file>`) — verified **25/25 green**.
- Wired into Django via the two `_make_snippet_case` lines in `core/tests.py`
  (discovery confirmed `Found 25 test(s)`; execution is only blocked by the
  sandbox's "permission denied to create database", unrelated to this change).

---

## Sidebar entries (integrator wires in `sidebar_sections.dart` — I did not edit it)

Per the brief: **blog → Work**, **docscan → Daily Life**. Add alongside the
existing `SidebarItem`s (same shape as `MockInterviewScreen` / `ContractAnalyzerScreen`):

Work section (`SidebarSection('work', ...)`), import
`'../screens/blog_writer_screen.dart'`:
```dart
SidebarItem(Icons.edit_note_outlined, (t) => t.bwTitle,
    (_) => const BlogWriterScreen(),
    synonyms: ['blog', 'script', 'write', 'caption', 'outline', 'content']),
```

Daily Life section (the §20/§21 Daily-Life group), import
`'../screens/doc_scanner_screen.dart'`:
```dart
SidebarItem(Icons.document_scanner_outlined, (t) => t.dsTitle,
    (_) => const DocScannerScreen(),
    synonyms: ['document', 'scan', 'scanner', 'nid', 'passport', 'bill', 'receipt', 'organise']),
```

(Could also be opened from Agent Studio like `SocialComposeScreen` if desired —
optional, not required.)

---

## Honesty / safety checklist

- Deterministic mock labelled on every result (`mock=True`, `marker="ai_review"`);
  Dart mirrors are byte-for-semantics identical to the Python source of truth.
- No fabricated AI text: blog body is template scaffolding with bracketed
  `[...]` placeholder prompts the user completes — no real claims asserted.
- No fabricated OCR: `extracted_text` is ALWAYS `""` in the engine; only the
  key-gated seam fills it.
- Never auto-posts / never publishes: blog writer only produces text + a manual
  Share-sheet / Copy; nothing is sent.
- Works fully with no key (template generator / manual organiser).
- Original Assisto identity; bilingual (bn real + natural, en); ৳ not used.
- ZERO Bangla literals in `.dart` (verified: no U+0980–U+09FF in either screen);
  all 69 strings are AppLocalizations getters pending the ARB merge.
```
