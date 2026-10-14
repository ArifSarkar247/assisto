# Integration: Business #144 Supplier & wholesale market + #145 Demand map

Two NEW Business features, built to §21 ADVANCED. Both are deterministic,
key-free, and show ONLY the user's own data. Each has one DOCUMENTED, key-gated
seam that is intentionally absent from the Integrations REGISTRY (the integrator
adds the key when a real provider is chosen). No fabricated market/trade data,
ever.

This change set touches ONLY new files + the explicitly-permitted seams:
`core/views.py` GENERIC_COLLECTIONS, `core/tests.py` (snippet wiring), and the
Business hub cards. It does NOT touch api.dart, core/models.py, core/urls.py,
the sidebar, app_*.arb, migrations, or Asalify.

---

## New files

Backend (pure logic — no Django/DB/network/AI/clock):
- `backend/core/logic/supplier_market.py`      — #144 filter/compare/reorder
- `backend/core/logic/demand_map.py`           — #145 demand heat aggregation
- `backend/core/logic/supplier_market_tests_snippets.py`  — 18 plain-assert tests
- `backend/core/logic/demand_map_tests_snippets.py`       — 10 plain-assert tests

Flutter (zero Bangla literals; `_SMath`/`_DMath` mirror the Python verbatim):
- `app/lib/screens/business/supplier_market_screen.dart`
- `app/lib/screens/business/demand_map_screen.dart`

---

## Edited files (permitted seams only)

1. `backend/core/views.py` — appended two entries to `GENERIC_COLLECTIONS`:
   `"supplier/vendors"`, `"demand/signals"`. No new class, no migration — they
   register automatically into `GENERIC_COLLECTION_VIEWSETS` via the existing
   `type()` factory (verified: `supplier/vendors` → kind `supplier_vendors`,
   `demand/signals` → kind `demand_signals`). Each reuses the `PaCollectionItem`
   flexible per-user JSON store + flatten serializer (same precedent as #182–#199).

2. `backend/core/tests.py` — added TWO `_make_snippet_case` lines (right after
   `PaProjectsSnippetTests`):
   - `SupplierMarketSnippetTests` → `core.logic.supplier_market_tests_snippets`
   - `DemandMapSnippetTests`       → `core.logic.demand_map_tests_snippets`

3. `app/lib/screens/business/business_hub_screen.dart` — imports the two new
   screens and adds two `_HubCard`s in the owner (non-staff) section:
   - Suppliers & wholesale market → `SupplierMarketScreen` (icon inventory_2, Brand.cyan)
   - Demand map → `DemandMapScreen` (icon insights, Brand.danger)
   (placed after the Reports card, inside the `if (!isStaff)` block).

---

## Persistence — generic REST collections (no api.dart edit)

Both screens use the existing generic helpers on `AppState.api`:
`listItems(path)`, `createItem(path, body)`, `updateItem(path, id, body)`,
`deleteItem(path, id)`. Endpoints are the standard DRF collection routes already
wired by `GENERIC_COLLECTION_VIEWSETS` (user-scoped, audit-logged by OwnedViewSet).

### `supplier/vendors`  (#144)  — one supplier per row
```
{
  "id": <int>,                 // server-assigned
  "name": "Dhaka Wholesale",   // required (blank-name rows are ignored by logic)
  "category": "wholesale",     // slug: raw_material|wholesale|packaging|electronics|
                               //       clothing|food|logistics|services|other
  "products": "Rice, Oil",     // raw "a, b" string the user typed (server/logic
                               //  also accept a list); normalised + de-duped
  "location": "Dhaka",
  "contact": "01XXXXXXXXX",
  "price_note": "50kg bag ৳2600, gives credit",
  "rating": 4,                 // int 0..5 (0 = unrated), clamped
  "note": "",
  "reorder": true              // on the reorder/contact list?
}
```

### `demand/signals`  (#145)  — one demand signal per row
```
{
  "id": <int>,
  "product": "Rice",           // product and/or area required (both-blank ignored)
  "area": "Dhaka",
  "period": "January",         // free label (month/season/Eid season…)
  "level": "surge",            // low|medium|high|surge  (score 1/2/3/4)
  "note": ""
}
```

---

## Pure logic API

`core.logic.supplier_market` (mirrored in Dart `_SMath`):
- `normalize(row)` → normalised supplier (slug category, de-duped products list,
  clamped 0–5 rating).
- `search(rows, query, category, location, min_rating, reorder_only)` →
  `{suppliers, match_count, total_count, reorder_count, by_category,
    partner_required:false, mock:true}`. Sort: rating DESC, name ASC (stable).
- `compare(rows, ids)` → `{suppliers (in picked order), best_rating_id,
  reorder_ids, enough (len>=2), count}`. `best_rating_id` is None when every pick
  is unrated (honest — never recommends without data).
- `reorder_list(rows)` → suppliers flagged `reorder=True`, same sort.
- `directory_seam(query, category, location)` → SEAM: `{partner_required:true,
  mock:true, integration:"supplier_directory", query_shape, suppliers:[]}`.

`core.logic.demand_map` (mirrored in Dart `_DMath`):
- `normalize(row)` → signal with level slug + integer score.
- `heat(rows)` → `{by_product, by_area, grid, hottest_product, hottest_area,
  signal_count, product_count, area_count, trade_required:false, mock:true}`.
  Buckets carry `{key,label,count,total (sum of scores),avg (1dp),band,top_level}`;
  sort total DESC, label ASC (stable). Band from avg score: <1.5 low, <2.5 medium,
  <3.5 high, else surge. Grid cells need BOTH product + area.
- `trade_seam(product, area, period)` → SEAM: `{trade_required:true, mock:true,
  integration:"trade_data", query_shape, signals:[]}`.

Both logic modules return `mock:true` + a `..._required:false` on the manual path
and `..._required:true` on the seam — callers stay honest about which path produced
the data. Neither holds money; #144 `price_note` is free text; #145 scores are
derived only from the user's own level choices.

---

## Documented, key-gated seams (intentionally absent)

| Feature | Seam fn | Integration slug (NOT in REGISTRY) | Honest UI state |
|---|---|---|---|
| #144 | `directory_seam()` | `supplier_directory` | "Partner directory … turns on when the owner connects a directory source" |
| #145 | `trade_seam()` | `trade_data` | "Live trade data … turns on when the owner connects a trade-data source" |

To activate later, the integrator adds a REGISTRY entry in `core/integrations.py`
for the chosen provider (slug `supplier_directory` / `trade_data`), then routes a
view to the seam's `query_shape`. The seams NEVER return suppliers/market figures —
they document the request contract only. No scraping (own data only).

---

## ARB keys — `.phaseB/up_supplierdemand_arb.json`

80 keys total: **77 plain** `{bn,en}` pairs + **3 placeholder** keys (listed under
`_params`). Bangla is natural/real; the `৳` glyph is the only non-ASCII in .dart
(currency sign, gate-exempt). Merge into `app_en.arb` / `app_bn.arb` and
regenerate `app_localizations.dart` with the existing merge/gen pipeline.

Placeholder keys + params (positional in generated getters):
- `supCompareN(n:int)`
- `supMatchCount(shown:int, total:int)`
- `demandSignalSummary(signals:int, products:int, areas:int)`

Key groups:
- Supplier (44): `supTitle`, `supHubSub`, `supLoadError`, `supWelcomeTitle/Body`,
  `supManualNote`, `supAddSupplier`, `supEditSupplier`, `supDelete{Title,Body}`,
  `supSearchHint`, `supReorderOnly`, `supRatedMin4`, `supClearFilters`,
  `supNoMatch{Title,Body}`, `supCat{RawMaterial,Wholesale,Packaging,Electronics,
  Clothing,Food,Logistics,Services,Other}`, `supField{Name,Category,Products,
  ProductsHelp,Location,Contact,ContactHelp,PriceNote,PriceNoteHelp,Note,Rating}`,
  `supUnrated`, `supReorderToggle`, `supReorderToggleSub`, `supCompare`,
  `supCompareDone`, `supComparePick`, `supCompareIntro`, `supBestRated`,
  `supOnReorderList`, `supPartnerSeam{Title,Body}`, `supCompareN*`, `supMatchCount*`.
- Demand (36): `demandTitle`, `demandHubSub`, `demandLoadError`,
  `demandWelcome{Title,Body}`, `demandManualNote`, `demandLogSignal`,
  `demandEditSignal`, `demandDelete{Title,Body}`, `demandHeatTitle`,
  `demandHottest{Product,Area}`, `demandView{Product,Area,Grid}`,
  `demandGridNeedsBoth`, `demandStat{Signals,Heat,Avg}`, `demandSignalsHeading`,
  `demandLevel{Low,Medium,High,Surge}`, `demandField{Product,Area,Period,
  PeriodHelp,Level,Note}`, `demandTradeSeam{Title,Body}`, `demandSignalSummary*`.

Reused existing shared keys (NOT in this ARB): `save`, `cancel`, `edit`,
`delete`, `retry`, `saved`, `saveFailed`, `loadFailed`.

---

## Tests

- Standalone: `python supplier_market_tests_snippets.py` → 18 passed;
  `python demand_map_tests_snippets.py` → 10 passed.
- Django: `SupplierMarketSnippetTests` (18) + `DemandMapSnippetTests` (10) =
  **28 methods**, discovered by the test runner (verified: "Found 28 test(s)").
  Covers normalize/clamp/dedup, search filters + sort + histogram, compare
  order + best pointer + not-enough + all-unrated, reorder list, heat buckets
  (product/area/grid) + bands + top-level, empty states, determinism, and both
  seams returning empty + `required:true` (never fabricated).

---

## Sidebar / nav entries

Both reachable from the **Business HUB** (`business_hub_screen.dart`), in the
owner section:
- "Suppliers & wholesale market" → `SupplierMarketScreen`
- "Demand map" → `DemandMapScreen`

No sidebar/drawer file was edited (per constraints) — the hub is the entry point,
matching the existing Khata/Selling/Cashbox/Reports/AI card pattern.

---

## Wiring checklist for the integrator

1. Merge `up_supplierdemand_arb.json` into app_en/app_bn.arb; regenerate l10n.
   (Until then the two screens show `undefined_getter` analyzer errors — expected;
   every getter maps 1:1 to a key in this ARB, verified no typos.)
2. `GENERIC_COLLECTIONS` + `tests.py` lines are already in place — no further
   backend wiring; no migration (reuses PaCollectionItem).
3. (Later, optional) add `supplier_directory` / `trade_data` REGISTRY entries to
   light up the live seams.
