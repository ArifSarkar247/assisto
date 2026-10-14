# Integration — Contract analyzer (#30) + Cost/time estimator (#36)

SPEC v2.1 §8, built to the Section-21 **advanced** standard. Two KEY-GATED AI
features whose **deterministic layer works fully with no key**, each with an
honest "AI-generated — review" marker and an honest "connect an AI key for a
deeper/smarter result" state that points to the Integrations admin. Neither
feature gives legal or financial advice — both are framed as **review/planning
helpers, not a lawyer/quote**.

---

## New files (no edits to protected files)

Protected files **NOT touched**: `app/lib/api.dart`, `backend/core/models.py`,
`backend/core/urls.py`, sidebar/drawer, `app_en.arb` / `app_bn.arb`, migrations,
Flutter builds, Asalify. `backend/core/integrations.py` was **read only**.

Backend (pure logic + tests):
- `backend/core/logic/contract_analyzer.py` — deterministic rule-based clause
  detection (bn+en seed phrases), plain-language summary data, verify-checklist,
  key-gated `deep_analysis_plan()` seam. No Django/DB/network/clock/AI.
- `backend/core/logic/cost_estimator.py` — deterministic integer-**poisha**
  cost/time math, contingency buffer, ±15% band, key-gated `ai_estimate_plan()`
  seam. No Django/DB/network/clock/AI.
- `backend/core/logic/contract_analyzer_tests_snippets.py` — 17 plain-assert tests.
- `backend/core/logic/cost_estimator_tests_snippets.py` — 15 plain-assert tests.

Flutter (new screens, self-contained, zero Bangla literals):
- `app/lib/screens/contract_analyzer_screen.dart` — mirrors the backend rule set
  verbatim (English ASCII seeds locally; server adds bn seeds for pasted Bangla);
  welcome/loading/error states, severity chips, flag cards, verify-checklist,
  honest marker + deeper-AI card + never-legal-advice disclaimer.
- `app/lib/screens/cost_estimator_screen.dart` — mirrors the backend poisha math
  verbatim; component rows (name/qty/unit ৳/minutes), contingency slider, totals
  card, rough band, honest marker + AI-estimate card + never-financial-advice
  disclaimer.

One registration line pair in `backend/core/tests.py` (the only edit there):
```python
ContractAnalyzerSnippetTests = _make_snippet_case(
    "core.logic.contract_analyzer_tests_snippets", "ContractAnalyzerSnippetTests")
CostEstimatorSnippetTests = _make_snippet_case(
    "core.logic.cost_estimator_tests_snippets", "CostEstimatorSnippetTests")
```

One registration edit in `backend/core/views.py` `GENERIC_COLLECTIONS` (the only
edit there — no migration, reuses the `PaCollectionItem` flexible store):
```python
# #30 Contract analyzer + #36 Cost/time estimator (§8, advanced)
"contract/analyses", "estimate/projects",
```

---

## ARB keys — `.phaseB/up_contractcost_arb.json`

**90 new keys** (format `{"keyName":["<bangla>","<english>"]}`), plus a
`_params` object naming placeholders for the **7 parameterized keys**:

| key | params |
|-----|--------|
| `ceComponentN` | `index` |
| `ceComponentsCount` | `count` |
| `ceContingency` | `pct` |
| `ceContingencyLine` | `pct` |
| `ceDays` | `n` |
| `ceHours` | `n` |
| `ceMinutes` | `n` |

All placeholders are integers (counts/percentages/index). Every `ca*`/`ce*`
getter used in the two screens is defined exactly once in the ARB (verified
bijection: no missing, no unused). Pre-existing shared getters reused (NOT
re-emitted): `copy`, `copied`, `delete`, `retry`, `save`. Currency uses `৳`
(U+09F3, gate-exempt) — the only U+09xx glyph in either `.dart` file.

Integrator: merge into `app_bn.arb` / `app_en.arb` with the existing
`merge_arb.py`, wiring the 7 `_params` keys as `int` placeholders.

---

## Exact collection paths + row shapes (generic REST, no api.dart edit)

Both reuse `ApiClient.listItems / createItem / updateItem / deleteItem` against
the generic `PaCollectionViewSet` collections (flat `{id, ...data}` round-trip).

**`contract/analyses`** — one saved contract analysis per row:
```json
{ "id": 1, "title": "House rental agreement",
  "text": "<the pasted contract text>",
  "saved_at": "2026-10-14T10:00:00.000Z" }
```
The analysis itself is recomputed deterministically on open (not stored) so a
rule update re-analyzes old rows consistently.

**`estimate/projects`** — one saved cost/time project per row:
```json
{ "id": 1, "name": "Kitchen renovation",
  "components": [
    { "name": "Labour", "qty": "2", "unit_cost": "500.00", "minutes": "120" },
    { "name": "Paint",  "qty": "5", "unit_cost": "199.99", "minutes": "0"   }
  ],
  "contingency_pct": 10,
  "saved_at": "2026-10-14T10:00:00.000Z" }
```
`components[*]` fields are stored as the raw entered strings; totals are
recomputed in integer poisha on open (no float drift, no stored money).

CRUD maps to: `GET /api/<path>/`, `POST /api/<path>/`,
`PATCH /api/<path>/<id>/`, `DELETE /api/<path>/<id>/` — all user-scoped +
audit-logged by `PaCollectionViewSet` / `OwnedViewSet`.

---

## Key-gated AI route seam

Both features run fully **without any key** via their deterministic engines.
The real-AI upgrade is a documented seam only — nothing in the logic calls a
model:

- **Which Integrations key unlocks live analysis:** `anthropic`
  (REGISTRY slug `"anthropic"`, category **AI**). Each seam exposes the constant
  `AI_INTEGRATION = "anthropic"` and returns `{"ai_required": True,
  "ai_integration": "anthropic", "mock": True, ...}`.
- **Contract analyzer:** `contract_analyzer.deep_analysis_plan(text)` returns the
  request/plan shape for a clause-by-clause model read **plus** `fallback` (the
  deterministic `analyze()` result) so the UI is never empty. The executor wires
  this plan to `core.ai.generate` when `integrations.is_enabled("anthropic")`.
- **Cost estimator:** `cost_estimator.ai_estimate_plan(label, components)` returns
  a transparent heuristic `rough` band (±40% of the known-component average) as a
  labelled placeholder **plus** the plan shape + `ai_integration`. A real smart
  estimate routes to `core.ai.generate` only when the key is connected.

Honest state in the UI: a "Deeper AI analysis" / "AI estimate for unknowns" card
explains the feature needs an owner-configured AI key in Integrations; until
then the deterministic result stands on its own. Every result carries
`mock=True` and `disclaimer=True`.

### owner_actions note
No new integration is added to the registry — both reuse the existing
`anthropic` (AI) entry whose owner-connect guide already lives at
`owner_actions/integrations.md` (console.anthropic.com → API Keys → paste →
Test). When the owner connects that key and it tests `working`, the executor may
route `deep_analysis_plan` / `ai_estimate_plan` to `core.ai.generate`; no code
change and no further owner action is required for these two features.

---

## Tests

- `contract_analyzer_tests_snippets.py` — **17** tests (validation, bn+en seed
  detection, once-per-clause, no false positives, worst-first severity sort,
  snippet extraction, checklist always+per-clause+dedup, honest-flag shape,
  determinism, key-gated seam + fallback). Run: `python3 contract_analyzer_tests_snippets.py` → `contract_analyzer: 17 tests passed`.
- `cost_estimator_tests_snippets.py` — **15** tests (poisha rounding, ৳ format,
  duration breakdown, validation, line multiply, blanks→0, no-drift totals,
  contingency, band brackets total, honest-flag shape, determinism, key-gated
  heuristic seam basis/band). Run: `python3 cost_estimator_tests_snippets.py` → `cost_estimator: 15 tests passed`.
- **Total: 32 snippet tests**, all passing standalone. Registered in
  `core/tests.py` via `_make_snippet_case` (SocialComposeSnippetTests precedent),
  so each test surfaces individually under `manage.py test`.

---

## Sidebar entries + wiring

Both belong under **Daily Life** (SPEC §8). The sidebar/drawer file is protected,
so the integrator adds two entries (strings via new ARB `caTitle` / `ceTitle`):

- `caTitle` → `ContractAnalyzerScreen` — suggested icon `Icons.description_outlined`.
- `ceTitle` → `CostEstimatorScreen` — suggested icon `Icons.calculate_outlined`.

Example (integrator applies in the drawer, not done here):
```dart
import 'screens/contract_analyzer_screen.dart';
import 'screens/cost_estimator_screen.dart';
// Daily Life group:
_navItem(Icons.description_outlined, t.caTitle,
    () => const ContractAnalyzerScreen()),
_navItem(Icons.calculate_outlined, t.ceTitle,
    () => const CostEstimatorScreen()),
```
(Alternatively surface them from an Agent Studio / Work tools hub the same way
`SocialComposeScreen` is reached from `agent_studio_screen.dart`.)

---

## Honesty / safety checklist

- No fake data presented as real — all numbers come from the user's input or a
  clearly labelled heuristic/mock band.
- Honest `mock=True` on every engine result; honest "AI-generated — review"
  marker in both screens; honest key-gated state pointing to Integrations.
- NEVER legal advice (contract) / NEVER financial advice (estimator) —
  `disclaimer=True` + an on-screen disclaimer card in both.
- Licensing respected: no bundled legal dictionary or price database; the
  engines are pure stdlib rules/arithmetic.
- Original Assisto identity; bilingual (bn/en) via ARB; ৳ for currency.
- Zero Bangla literals in `.dart` (verified: no U+0980–U+09F2 / U+09F4–U+09FF;
  only U+09F3 ৳, gate-exempt).
```
