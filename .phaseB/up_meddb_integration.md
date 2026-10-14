# Medicine DATABASE (drug lookup) — ADVANCED upgrade · integration notes

SPEC v2.1 §21. Raises the Medicine-DB module from **good → advanced**.

## Scope of THIS change (already done, in-repo)
- `app/lib/screens/medicine_db_screen.dart` — rewritten (advanced; 3 tabs).
- `app/lib/widgets/meddb_store.dart` — NEW. On-device store (SharedPreferences
  via the shared `Settings`): favourites, recently-viewed, offline cache of the
  full record of every viewed drug.
- `app/lib/widgets/meddb_drug_card.dart` — NEW. Full advanced drug card:
  name/generic/strength/form/manufacturer/indicative-price/uses/how-to-take/
  side-effects/precautions, same-generic alternatives with **price-compare**
  badges + the mandatory switch-warning on each, honest source-noted
  interactions note, save/favourite, share-as-result-card, report-wrong-info.
- `app/lib/widgets/meddb_report_sheet.dart` — NEW. "Report wrong info" sheet;
  posts to `/medicine-db/report` via public `ApiClient.postJson` (no api.dart
  edit); degrades gracefully offline.
- `backend/core/logic/medicine_db.py` — EXTENDED (pure logic, no Django):
  per-record `side_bn/en` + `precaution_bn/en`; `interactions_note(generic)`
  (honest, source-noted, never a clinical check); `report_wrong_info(...)`;
  `source_label(...)` in `meta()`; `search()`/`lookup()` now return full detail
  + alternatives so the app can cache for offline. Switch-warning + sample
  guards unchanged.
- `backend/core/logic/medicine_db_tests_snippets.py` — +6 tests → **19 pass**
  (`run_all()` = 19). Covers detail fields, interactions honesty/source-note,
  source-label never-claims-DGDA-on-sample, report validation.
- `.phaseB/up_meddb_arb.json` — **27** NEW bilingual keys `{key:[bn,en]}`.

Nothing in `api.dart`, `app_*.arb`, `models.py`, `urls.py`, `serializers.py`,
`sidebar`/`chatnav`, `health_api.dart`, or any other module was edited. No
migrations, no flutter/builds, no Asalify.

The legacy `app/lib/widgets/health_medicine_card.dart` is now unused by this
screen (the new `meddb_drug_card.dart` supersedes it). It is left in place
(not deleted / not in scope) and imports no new keys.

## (a) l10n — REQUIRED to compile
Merge `up_meddb_arb.json` into `app_bn.arb` (index `[0]`) and `app_en.arb`
(index `[1]`), then `flutter gen-l10n`. All 27 keys are NEW; the existing
`medicineDb*` keys are reused unchanged. `medicineDbAlternativesTitle` keeps its
existing `{count}` ICU placeholder metadata — do NOT redefine it.

Until gen-l10n runs, `flutter analyze` on the Dart files reports only
`undefined_getter` for the 27 new keys (expected — they live in the ARB). Zero
Bangla literals in any `.dart` (verified; Bangla digits would render at runtime
from codepoints U+09E6..U+09EF — none needed here).

## (b) backend wiring (already consumable; one new route)
Existing routes unchanged and still correct:
- `GET /medicine-db/search?q=` → `{results: medicine_db.search(q,lang),
  meta: medicine_db.meta(lang)}` — results now carry full detail + alternatives.
- `GET /medicine-db/lookup?brand=` → `medicine_db.lookup(brand,lang)` (full
  detail + alternatives) or the needs-data state.

NEW route the integrator should add (thin, mirrors the others):
- `POST /medicine-db/report {brand, issue}` →
  `medicine_db.report_wrong_info(brand, issue, lang)`.
  The app already calls this; if unwired it 404s and the sheet still
  acknowledges (report is non-blocking) — wire it to persist/route reports.

## (c) LICENSING / SAFETY — unchanged guarantees (confirm at review)
- **DGDA-only or a licensed provider.** Data is either a clearly-BADGED curated
  SAMPLE (public facts) or, once wired, a DGDA/licensed feed. `set_source(DGDA)`
  still REFUSES without real records. `source_label()` NEVER claims DGDA
  authority while on the sample set and is shown on-screen for every result.
- **NEVER DIMS / MedEx** (or any proprietary DB) — not copied, not referenced.
- **Alt-swap warning on EVERY record & EVERY alternative** — the mandatory
  "ডাক্তার/ফার্মাসিস্টের পরামর্শ ছাড়া ওষুধ বদলাবেন না / Do not switch
  medicines without a doctor's or pharmacist's advice."
- **Source-noted, never invented.** The interactions note is an honest,
  source-noted general caution (explicitly "not a full interaction check"),
  not a clinical checker. Prices are INDICATIVE and labelled. "Report wrong
  info" routes corrections to DGDA/licensed cross-checking.

## (d) Section-21 coverage (all 10)
1. Category-best lookup subset (brand/generic search, full card, alternatives +
   price-compare, interactions) — equal/better on the safe-lookup tasks.
2. Full flow: search → view → save/unsave → recent → share → report.
3. Both rails: typed search + tap-through from results; saved/recent are the
   manual library. (No AI-captured entries here — all user/server data.)
4. Empty (intro), loading (card skeletons), tool/result (cards), **offline**
   (banner + cache fallback + no-cache message) — all designed, nothing raw.
5. Strict bn/en (all strings in ARB), light/dark via scheme tokens, WCAG-minded
   contrast (error/warning on-container colours; small+large screens via Wrap).
6. Reusable surface for reminders/chat/voice: `medicineDbSearch` + the cache
   store are callable from other entry points (voice "খুঁজুন X" → open on
   Search tab) — thin wiring left to the integrator (no sidebar edit here).
7. Server tests (19 pass, incl. honesty/source/report scenarios) + app logic is
   framework-free in the store/card for widget tests.
8. Share result-card on every drug card (`Share.share`).
9. Privacy: all saved/recent/cache data is on-device, non-sensitive public drug
   facts only; nothing leaves the device except explicit share / explicit
   report. No audit-log entry needed (no sensitive action).
10. Ready for independent review.
