# Integration — PA Secretary Mode: Travel & Itinerary (#112) · Expense Voucher (#113) · Research & Presentation (#114)

SPEC v2.1 §14 (PA Secretary Mode), built to Section-21 "advanced" as
DETERMINISTIC / MOCK (works with no key) + honest markers + honest key-gated
seams. Nothing fabricates a booking, price, amount or researched fact; nothing
holds money. Pure logic + on-device Dart screens; one flexible per-user JSON
collection each. Did NOT touch: api.dart request helpers, core/models.py,
core/urls.py, sidebar, app_*.arb, migrations, Flutter builds, Asalify.

---

## 1. New files

### Backend (pure deterministic logic — no Django / DB / network / clock / AI / booking / OCR)
- `backend/core/logic/pa_travel.py` — boss-trip itinerary assembly (trip, legs,
  stays, meetings, packing), inclusive day span, passed-in-`now` countdown,
  chronological ordering, printable `itinerary_summary`, and `booking_seam()`
  (key-gated live-booking MOCK).
- `backend/core/logic/pa_expense.py` — expense voucher builder: integer-poisha
  `to_poisha` / `fmt_bdt`, line normalisation, `validate_*`, one-way approval
  `can_transition` / `advance_status`, `total_poisha` / `category_totals` /
  `voucher_summary`, and `ocr_seam()` (key-gated OCR MOCK).
- `backend/core/logic/pa_research.py` — research organiser: notes/sources split,
  ordered outline sections + bullets, `research_summary`, deterministic
  `outline_export` (plain text for slides), and `ai_seam()` (key-gated AI MOCK).

### Backend test snippets (plain-assert, stdlib; `run_all()`)
- `backend/core/logic/pa_travel_tests_snippets.py` — 13 tests
- `backend/core/logic/pa_expense_tests_snippets.py` — 12 tests
- `backend/core/logic/pa_research_tests_snippets.py` — 13 tests
- **Total: 38 tests** (all pass standalone).

### Flutter screens (ZERO Bangla literals; every string an AppLocalizations getter; ৳ exempt)
- `app/lib/screens/pa/pa_travel_screen.dart`
- `app/lib/screens/pa/expense_voucher_screen.dart`
- `app/lib/screens/pa/research_prep_screen.dart`

### l10n patch + this note
- `.phaseB/up_patravelexpres_arb.json` — 114 new keys as `{key: [bn, en]}` with a
  `_params` map for the 7 parameterised keys.
- `.phaseB/up_patravelexpres_integration.md` — this file.

---

## 2. One `core/tests.py` line (already added)

Added immediately after the `PaFilingSnippetTests`/`PaMinutesSnippetTests` line:

```python
# PA travel & itinerary (#112) + expense voucher (#113) + research & presentation (#114), §14 ADVANCED §21 — pure deterministic builders; honest key-gated booking/OCR/AI seams.
PaTravelSnippetTests = _make_snippet_case("core.logic.pa_travel_tests_snippets", "PaTravelSnippetTests"); PaExpenseSnippetTests = _make_snippet_case("core.logic.pa_expense_tests_snippets", "PaExpenseSnippetTests"); PaResearchSnippetTests = _make_snippet_case("core.logic.pa_research_tests_snippets", "PaResearchSnippetTests")
```

`_make_snippet_case` turns each `test_*` in the snippet module into an
individual Django `TestCase` method. No other tests.py change.

---

## 3. Persistence — generic REST collections (NO api.dart edit, NO migration)

Each feature reuses the existing `PaCollectionItem` flexible per-user JSON store
via the generic collection machinery in `core/views.py`. **Add these three
names to the `GENERIC_COLLECTIONS` list** (the `GENERIC_COLLECTION_VIEWSETS`
`type()` loop + the generic URL registration already wire everything — no new
ViewSet class, no serializer, no migration):

```python
# §14 PA Secretary Mode — travel & itinerary (#112) + expense voucher (#113) +
# research & presentation (#114). One flexible collection each; rows are tagged
# by a `kind` field (and `kind2` for research note/source) and round-trip as
# {id, ...data}.
"pa/travel", "pa/vouchers", "pa/research",
```

The Dart screens call the existing generic helpers through
`context.read<AppState>().api`:
`listItems(path)`, `createItem(path, body)`, `updateItem(path, id, body)`,
`deleteItem(path, id)` — identical to the travel-planner / money-module
precedent. No api.dart change is required.

### Row shapes (one collection per feature; `kind` discriminates sub-types)

**`pa/travel`** (one collection; sub-rows tagged by `kind`):
```
{id, kind:"trip",    title, start, end, note}
{id, kind:"leg",     trip_id, mode, from_place, to_place, depart, arrive, ref, note}
      mode ∈ flight|train|car|bus|launch   (ref = PNR/ticket the PA typed; never ours)
{id, kind:"stay",    trip_id, name, address, check_in, check_out, note}
{id, kind:"meeting", trip_id, title, place, at, with_whom, note}
{id, kind:"pack",    trip_id, label, checked}
```

**`pa/vouchers`**:
```
{id, kind:"voucher", title, claimant, status, note}   status ∈ draft|submitted|approved
{id, kind:"line",    voucher_id, date, category, amount, receipt_ref, note}
      category ∈ transport|lodging|meals|supplies|communication|entertainment|other
      amount  = BDT string the PA typed; totals computed via integer-poisha to_poisha()
```

**`pa/research`**:
```
{id, kind:"topic",   title, goal}
{id, kind:"item",    topic_id, kind2:"note"|"source", text, ref}
      (note needs text; source needs text or ref; ref = link/citation the PA typed)
{id, kind:"section", topic_id, heading, order, bullets}   (bullets = newline-joined)
```
Note: the note/source discriminator is `kind2` because the row's own `kind`
already tags topic/item/section within this one collection.

Rows persist through the flexible JSON column; `id` is the server PK and is used
for update/delete and `trip_id`/`voucher_id`/`topic_id` parent linkage.

---

## 4. Key-gated seams (honest "connect a key" — NEVER fabricate)

Each seam is a pure `{required, mock}`-shaped function on the backend and an
honest card in the UI. Nothing ever calls a provider here.

| # | Feature | Seam fn (backend) | Marker key | Integration key | UI card | Honest copy keys |
|---|---------|-------------------|-----------|-----------------|---------|------------------|
| 112 | Travel | `pa_travel.booking_seam()` → `results: []` | `booking_seam` | `booking` (registry has no `booking` slug yet; this is the documented seam the owner adds when a booking provider is onboarded) | `_BookingSeamCard` | `paTravelBookingSeamTitle` / `paTravelBookingSeamBody` |
| 113 | Expense | `pa_expense.ocr_seam()` → `fields: {}` | `ocr_seam` | `ocr` (exists in `integrations.REGISTRY`) | `_OcrSeamCard` | `paVoucherOcrSeamTitle` / `paVoucherOcrSeamBody` |
| 114 | Research | `pa_research.ai_seam()` → `result: ""` | `research_ai_seam` | `anthropic` (exists in `integrations.REGISTRY`) | `_AiSeamCard` | `paResearchAiSeamTitle` / `paResearchAiSeamBody` |

The real path (when a key is present) routes the SAME request shape to the
provider — e.g. `ai_seam` → `core.ai.generate` (anthropic), `ocr_seam` → the
`ocr` provider, `booking_seam` → a future booking provider. Until then the cards
honestly say nothing is booked / read / invented and everything is done by hand.

---

## 5. PA-hub tiles — ready-to-paste (do NOT let me edit pa_hub_screen.dart)

In `app/lib/screens/pa/pa_hub_screen.dart`:

**a) Add imports** (top of file, beside the other `pa/` screen imports):
```dart
import 'pa_travel_screen.dart';
import 'expense_voucher_screen.dart';
import 'research_prep_screen.dart';
```

**b) Add three tiles** to the `tools` list (`List<_PaTool>`), e.g. after the
existing `paTasksTitle` tile:
```dart
      _PaTool(Icons.flight_takeoff, t.paTravelTitle,
          (_) => const PaTravelScreen()),
      _PaTool(Icons.receipt_long, t.paVoucherTitle,
          (_) => const ExpenseVoucherScreen()),
      _PaTool(Icons.menu_book_outlined, t.paResearchTitle,
          (_) => const ResearchPrepScreen()),
```

**Hub tile title ARB keys** (defined in this patch, so the hub stays
Bangla-literal-free): `paTravelTitle`, `paVoucherTitle`, `paResearchTitle`.
Each doubles as the destination screen's AppBar title (same pattern as the
existing tiles reusing a title getter).

---

## 6. l10n keys

- **114 new keys** in `.phaseB/up_patravelexpres_arb.json`, format `{key: [bn, en]}`.
- **7 parameterised keys** under `_params` — add each to the merge script's
  PARAMS map so `@`-metadata (Object-typed placeholders, repo convention) is
  generated:
  - `paTravelDaysCount {days:int}`
  - `paTravelCountdown {days:int}`
  - `paTravelOngoingPast {days:int}`
  - `paTravelPackingProgress {checked:int, total:int}`
  - `paTravelRefLabel {ref:String}`
  - `paVoucherLineCount {count:int}`
  - `paVoucherReceiptLabel {ref:String}`
- **Reused existing shared keys** (NOT redefined): `add`, `cancel`, `delete`,
  `edit`, `save`, `retry`, `loadFailed`, `saveFailed`.
- Bangla is real & natural. `৳` kept as-is (exempt). Verified: every `t.<key>`
  referenced by the three screens is defined (0 missing, 0 extra); no EN value
  contains Bangla.

Merge as usual (author keys into the merge script / run the ARB merge); then
`flutter gen-l10n` regenerates `AppLocalizations`, resolving the 144
`undefined_getter` analyzer errors that are expected until the merge runs.

---

## 7. Tests

Run backend self-tests standalone (no DB):
```
cd backend/core/logic
python3 pa_travel_tests_snippets.py     # pa_travel: 13 tests passed
python3 pa_expense_tests_snippets.py    # pa_expense: 12 tests passed
python3 pa_research_tests_snippets.py   # pa_research: 13 tests passed
```
Or via Django: the three `_make_snippet_case` classes in `core/tests.py` fold
all 38 into the suite (one method per `test_*`).

Coverage highlights: inclusive day span + honest countdown (past/today/future);
chronological leg/meeting/stay ordering (undated last) + purity; packing %;
booking seam empties + honest flags. Integer-poisha half-up + negative clamp +
grouping (lakh); one-way approval flow (no draft→approved skip; reject-back);
no-drift totals; category rollup; summary ordering; OCR seam honesty. Notes/
sources split; order-by-order section sort; deterministic `outline_export`
(with/without sources, empty); AI seam honesty.

---

## 8. Report summary

- **Files created:** 9 (3 backend logic + 3 backend test-snippets + 3 Flutter
  screens) + 1 ARB JSON + 1 integration note. **One line** added to
  `core/tests.py`.
- **ARB key count:** 114 new keys (7 parameterised).
- **Test count:** 38 (13 travel + 12 expense + 13 research), all passing.
- **Zero-Bangla confirmation:** the three `.dart` files contain NO Bangla
  literals — the only `[ঀ-৿]`-range characters are the exempt `৳` symbol and
  doc comments; every user-facing string is an `AppLocalizations` getter.
