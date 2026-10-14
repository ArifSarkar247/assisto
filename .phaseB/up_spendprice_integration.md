# Integration — #51 AI Spending Advice + #34 Market Price Radar (§21 advanced)

Two NEW key-gated features built to the Section-21 advanced standard. Both work
fully DETERMINISTICALLY with no key: #51 analyses the user's OWN summarised
category totals into honest observations (never financial advice); #34 is a
manual market-price tracker over the user's OWN logged prices (never fabricates
a live quote). All live-AI / live-feed paths are documented, honest seams.

No live model/feed call is made. `api.dart`, `core/models.py`, `core/urls.py`,
the sidebar wiring file, `app_en.arb`/`app_bn.arb`, and migrations were NOT
edited. The only backend edit is ONE registration line per feature in
`core/tests.py`.

---

## 1. New files

### Backend (pure deterministic logic — no Django, no DB, no network, no AI, no clock)
- `backend/core/logic/spending_advice.py` — #51 rule-based spending OBSERVATIONS
  over the user's own category totals. `analyse(categories, previous=None)` →
  top category + share, big-share flag (≥30%), month-over-month total change,
  biggest-mover category, overspend flags vs the user's OWN budgets, a neutral
  savings pointer. Integer-poisha money (`to_minor`/`fmt_bdt`), half-up
  percents. Every result carries `advice=False` + `disclaimer_key`
  (`spend_not_advice`) + `marker` (`spend_observations`). `ai_seam()` is the
  documented, key-gated written-summary seam (`ai_required=True`,
  `integration="anthropic"`). Never invents a transaction.
- `backend/core/logic/price_radar.py` — #34 manual price radar. `radar(logs)`
  groups the user's logs by (name, unit) and returns a per-item trend:
  latest / high / low / avg (integer poisha) + signed %-change (1dp) between
  the two most recent logs. `item_trend(logs)` is the per-item core.
  `feed_seam()` is the documented, key-gated LIVE-feed seam (`live_required=
  True`, `integration="price_feed"`) and returns `prices: []` — NEVER a
  fabricated quote. Flags `mixed_units` when one name is logged under >1 unit
  (no unit conversion is ever done).

### Backend tests (plain-assert snippet suites, pure stdlib)
- `backend/core/logic/spending_advice_tests_snippets.py` — 18 tests.
- `backend/core/logic/price_radar_tests_snippets.py` — 12 tests.

### Flutter screens (verbatim on-device mirrors of the backend math)
- `app/lib/screens/spending_advice_screen.dart` — `_SMath` mirrors
  `spending_advice.py`. Always-on "not financial advice" disclaimer card,
  totals + MoM card, observation cards, per-category cards with share bar +
  budget/change chips, honest not-enough-data state, welcome first-use state,
  key-gated AI-seam card. ZERO forbidden Bangla literals.
- `app/lib/screens/price_radar_screen.dart` — `_RMath` mirrors `price_radar.py`.
  Per-item trend cards (latest price, up/down %-pill, high/low/avg/logs stats,
  per-log list with edit/delete, mixed-units warning), "your logged prices —
  not a live feed" note, welcome first-use state, key-gated live-feed seam
  card, add-price-for-this-item shortcut. ZERO forbidden Bangla literals.

---

## 2. ARB keys — `/.phaseB/up_spendprice_arb.json`

Format: `{"keyName": ["<bangla>", "<english>"], ...}` plus a `_params` object
for parameterized keys. **70 new keys** total (42 spend* + 28 price*), of which
**14 are parameterized** (listed in `_params`). Bangla is real/natural; the ৳
glyph (U+09F3) is used for currency and is gate-exempt.

Reused EXISTING shared keys (NOT in the ARB file — already present in
app_*.arb): `cancel, delete, edit, save, saved, saveFailed, loadFailed, retry`.

Parameterized keys (`_params`):
- Spend: `spendVsPrevious(amount:String, pct:int)`,
  `spendShareChip(pct:int)`, `spendBudgetChip(budget:String)`,
  `spendOverBudgetChip(amount:String)`, `spendChangeChip(amount:String, pct:int)`,
  `spendObsTopCategory(category:String, amount:String, pct:int)`,
  `spendObsBigShare(category:String, pct:int)`,
  `spendObsMomUp(pct:int, amount:String)`,
  `spendObsMomDown(pct:int, amount:String)`,
  `spendObsMoverUp(category:String, amount:String, pct:int)`,
  `spendObsMoverDown(category:String, amount:String, pct:int)`,
  `spendObsOverBudget(category:String, amount:String, budget:String)`,
  `spendObsSavingsPointer(category:String, pct:int)`.
- Price: `priceLogAtMarket(date:String, market:String)`.

Integrator: merge these into `app_en.arb`/`app_bn.arb` (English = index [1],
Bangla = index [0]) with the repo's existing merge script (see
`.phaseB/merge_arb.py`), add `@key` placeholder metadata for the 14 param keys
from `_params`, then `flutter gen-l10n`. The Dart screens currently analyze with
exactly 80 `undefined_getter`/`undefined_method` errors — ALL of them are these
new ARB keys and ALL clear once AppLocalizations is regenerated. No other
analyzer issues exist.

---

## 3. Persistence — generic REST collections (PaCollectionItem precedent, NO migration)

Both screens call the existing `ApiClient` generic helpers
(`listItems/createItem/updateItem/deleteItem`) — `api.dart` was NOT edited.

Integrator: add these two collection names to `GENERIC_COLLECTIONS` in
`backend/core/views.py` (same block that already holds `probashi/remittances`
etc.). No model, no serializer, no migration — the flexible per-user
`PaCollectionItem` JSON store + flatten serializer back them, exactly like the
existing collections. `urls.py` already auto-wires every name in
`GENERIC_COLLECTION_VIEWSETS`.

```python
# add inside GENERIC_COLLECTIONS:
    # #51 AI spending advice (summarised category totals the user enters)
    "spending/notes",
    # #34 Market price radar (user-logged bazar/material prices)
    "price/logs",
```

### Exact paths + row shapes (each row round-trips as `{id, ...data}`)

`spending/notes` — one row per spending CATEGORY the user enters:
```
{ id: int,
  category: string,          # required, e.g. "Food" / "খাবার"
  amount:   string,          # current-period total spend, e.g. "6000" / "6000.50"
  budget?:  string,          # optional: the user's OWN monthly limit for overspend flags
  previous?:string,          # optional: previous-period total for month-over-month
  note?:    string }
```

`price/logs` — one row per PRICE OBSERVATION the user logs:
```
{ id: int,
  item:    string,           # required, e.g. "Rice" / "চাল"
  price:   string,           # required, ৳ price, e.g. "55" / "55.50"
  unit:    string,           # stable slug: kg|g|litre|ml|piece|dozen|bag|other
  date?:   string,           # "YYYY-MM-DD"; trend sorts by date (empty sorts first)
  market?: string,           # e.g. "Karwan Bazar"
  note?:   string }
```
Items are grouped by (lowercased name, unit); a trend is only meaningful within
one unit, so a single name under multiple units is flagged `mixed_units` and
NEVER unit-converted.

---

## 4. Key-gated seams (which Integrations keys unlock live AI / price feed)

### #51 written AI advice → `anthropic` (`core.ai.generate`)
- Deterministic observations are the REAL feature and need no key.
- `spending_advice.ai_seam()` returns the request shape a real route would use
  (`integration="anthropic"`, `tier="cheap"`), with the deterministic
  observations as the DATA-fenced body and `must_not: [invent amounts, give
  financial advice, add transactions]`. `ai_required=True` is the honest
  "connect an AI key for a written summary" state. Nothing calls a model.
- Already in `REGISTRY` as `anthropic` (unlocks via `integrations.is_enabled(
  "anthropic")` → route `ai_seam` through `core.ai.generate`). The screen shows
  the honest seam card unconditionally; wiring the live call is a future step
  gated on `is_enabled("anthropic")`.

### #34 live market prices → `price_feed` (NOT yet in REGISTRY — honest)
- The manual tracker is the REAL feature and needs no key. There is NO
  fabricated live price anywhere.
- `price_radar.feed_seam()` documents a future live feed
  (`integration="price_feed"`, `prices: []`, `live_required=True`). There is
  currently NO `price_feed` entry in `core/integrations.py REGISTRY` — this is
  intentional and honest: the integrator adds a `price_feed` REGISTRY entry (a
  new `_f("api_key", ...)` block, mirroring the `weather`/`news` entries) only
  when a real BD market-data provider is chosen. Until then the screen shows the
  honest "live prices need a market-data key" card and shows only logged prices.

Owner actions note: both seams map to the standard owner Integrations dashboard
(`owner_actions/integrations.md`, `_DOC`). `anthropic` is already documented
there (console.anthropic.com → API key). When `price_feed` is added to the
REGISTRY it inherits the same owner dashboard card + guide steps automatically;
add a one-line `price_feed` guide to `owner_actions/integrations.md` at that
time. Min-price/commission logic is not relevant to these two features (no money
is moved or held); where it ever becomes relevant it stays server-side.

---

## 5. Tests — ONE registration line per feature in `core/tests.py`

Added after `SavedItemsSnippetTests`:
```python
SpendingAdviceSnippetTests = _make_snippet_case(
    "core.logic.spending_advice_tests_snippets", "SpendingAdviceSnippetTests")
PriceRadarSnippetTests = _make_snippet_case(
    "core.logic.price_radar_tests_snippets", "PriceRadarSnippetTests")
```
- SpendingAdvice: **18** tests. PriceRadar: **12** tests. **30 total.**
- Verified: both snippet files pass standalone AND through the Django-registered
  `_make_snippet_case` classes (`python manage.py test` collected all 30; the
  pure tests also run green via `django.setup()` without touching the DB).

---

## 6. Sidebar entries (for the integrator — sidebar file NOT edited here)

- #51 AI spending advice → **My Account** section. Route to
  `SpendingAdviceScreen()`. Suggested label getter `spendTitle`
  ("এআই খরচ পর্যবেক্ষণ" / "AI spending insights"), icon `Icons.insights`.
- #34 Market price radar → **Daily Life** section (also reasonable under My
  Account). Route to `PriceRadarScreen()`. Suggested label getter `priceTitle`
  ("বাজার দাম রাডার" / "Market price radar"), icon `Icons.storefront`.

Add imports for the two screens in the drawer/router file and one nav tile each
in the stated sections — same pattern as the existing §20/§21 entries.

---

## 7. Honesty / safety summary

- #51 is framed as "general observations, not financial advice" on EVERY result
  (`advice=False`, always-on disclaimer card). It analyses ONLY the user's
  entered/summary numbers — it never invents transactions or amounts.
- #34 shows ONLY the user's logged prices. No live/scraped/guessed price ever
  appears; the live feed is a documented seam returning no prices.
- Both are fully functional with NO key; key-gated paths are clearly labelled
  honest "connect a key for live …" states.
- Original Assisto identity; bilingual bn/en via AppLocalizations only; ZERO
  forbidden Bangla literals in either .dart file (U+0980–U+09FF, ৳ exempt).
