# Dictionary (feature 39) — GOOD → ADVANCED · integration notes

SPEC v2.1 §21. Scope of THIS change (already done, in-repo):

- `app/lib/screens/dictionary_screen.dart` — rewritten (advanced: tabs
  Search / Saved / History, word-of-the-day, recently-searched, suggestions,
  offline fallback, error+retry, honest needs-data state).
- `app/lib/widgets/dict_store.dart` — NEW (offline-first local store:
  search history, favourites/saved, offline cache of looked-up words; + the
  shared `DictEntry` model). Persists via `Settings` (SharedPreferences).
- `app/lib/widgets/dict_entry_card.dart` — NEW (one result: pos, example,
  pronunciation note, synonyms/antonyms chips, save/copy/share).
- `app/lib/widgets/dict_extras.dart` — NEW (word-of-the-day gradient card,
  chip rows, designed empty/offline/error state views, offline banner).
- `backend/core/logic/dictionary.py` — EXTENDED (open sample now carries
  `ipa`, `example`, `syn`, `ant`; new `_shape`/`_as_list` normalisers;
  new `word_of_the_day()`; `lookup()` now also returns `suggestions` and
  `word_of_the_day` so the single existing endpoint powers the whole UI).
- `backend/core/logic/dictionary_tests_snippets.py` — +6 tests (now 13).
- `.phaseB/up_dict_arb.json` — **36** NEW bilingual keys `{key:[bn,en]}`.

Nothing else was edited: no `api.dart`, no `app_*.arb`, no `models.py`,
`urls.py`, `serializers.py`, `views_module5.py`, no sidebar/chatnav. No
migrations, no builds, no Asalify.

## LICENSING (unchanged, strict)
Content is OPEN-LICENSE only — the tiny hand-written generic sample, or an
open dataset (FreeDict / Wiktionary CC-BY-SA, etc.) wired via
`dictionary.load_dataset(entries, source_label)`. **NEVER** Bangla Academy or
any proprietary/copyrighted dictionary. On a sample miss the backend returns
`needs_data` and the UI shows the honest "available when open dictionary data
is added" state — it never fabricates a meaning.

## l10n — REQUIRED to compile
`flutter analyze` on the 4 Dart files reports **38** `undefined_getter` /
`undefined_method` findings — all for the new `dict*` ARB keys (expected; they
live in the ARB until gen-l10n runs). No other errors/warnings.

To wire:
1. Merge `up_dict_arb.json` into `app/lib/l10n/app_bn.arb` (index `[0]`) and
   `app/lib/l10n/app_en.arb` (index `[1]`). Copy the `@dictShareTemplate` /
   `@dictSavedCount` placeholder blocks verbatim (ICU `{bn}`/`{en}`/`{detail}`,
   `{n}`). The legacy `dictionary*` keys are already present and reused as-is.
2. Run `flutter gen-l10n` → regenerates the getters → 0 analyzer errors.

Zero Bangla string literals in any `.dart` (verified:
`grep -P '[\x{0980}-\x{09FF}]'` on all 4 files is empty). The rendered Bangla
(headwords, examples, synonyms, word-of-the-day) is backend DATA, not Dart.

## Backend
`python3 -c "import core.logic.dictionary_tests_snippets as t; t.run_all()"`
→ `dictionary: 13 tests passed`. The `/dictionary/lookup` contract is a strict
superset of before (added `suggestions`, `word_of_the_day`; entries gained
`ipa`/`syn`/`ant`) — existing callers keep working.

## Section-21 (all 10) coverage
1. Side-by-side (vs offline dict apps): bn↔en, pos, examples, synonyms,
   antonyms, pronunciation, WOTD, history, saved, offline cache, copy/share.
2. Full flow: search / clear / direction switch / save+unsave / clear history /
   open-from-history / open-from-WOTD / copy / share.
3. Input rails: typed search + tap-to-search (history/recent/suggestion/WOTD
   chips). No AI entries here (deterministic open data) — no AI marker needed.
4. States: empty (intro + WOTD), loading (spinner), needs-data (honest),
   not-found, error+retry, offline-from-cache (banner), offline-no-cache.
5. bn/en both (all chrome via ARB), light/dark (ColorScheme-driven, no
   hardcoded surface colours), small/large (ListView/Wrap, no clipping).
6. Hooks: reusable `DictEntry`/`DictStore` + share sheet feed chat/other
   surfaces; voice already routes via `screen_synonyms` ("dictionary"/"অভিধান").
7. Tests: backend 13 asserts (incl. scenario: dataset-swap, string syn/ant
   coercion, stable WOTD per day).
8. Share card: per-entry copy + Share.share with an attributed template.
9. Privacy: history/saved/cache are LOCAL only (SharedPreferences), never sent
   to the server; no PII; "Clear history" one-tap. No audit-log action needed.
10. Reviewer: pending owner screenshot-review pass.
