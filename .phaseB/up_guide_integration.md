# Government / Service Guide — BASIC → ADVANCED (SPEC v2.1 §21)

Bangladesh government / public-service "how-to" helper. Benchmarked against
best-in-class gov how-to apps (gov.uk, Singapore LifeSG): every service is a
full card with steps, a required-documents checklist, fee, where/office,
official link, processing time, common mistakes, a source note and a
"verify on the official portal" disclaimer.

## Scope (edit surface honored)
- **Edited:** `app/lib/screens/guide_screen.dart`
- **New widgets (`guide_` prefix):**
  - `app/lib/widgets/guide_data.dart` — models + category/service chrome + offline fallback
  - `app/lib/widgets/guide_service_card.dart` — expandable how-to card
  - `app/lib/widgets/guide_need_sheet.dart` — "what do I need for X" bottom sheet
- **Backend (optional, taken):** `backend/core/logic/govt_guide.py`
  (+ tests `backend/core/logic/govt_guide_tests_snippets.py`)
- **Strings:** `.phaseB/up_guide_arb.json` (`{key:[bn,en]}`, **28 keys**)
- **Untouched (as required):** `api.dart`, `app_bn.arb`/`app_en.arb`,
  `models.py`, `urls.py`, sidebar/chatnav, `backend/core/views.py`, the old
  `backend/core/logic/guides.py`, migrations, Asalify/CRM.

## Advanced vs. before
| | BEFORE (BASIC) | AFTER (ADVANCED) |
|---|---|---|
| Services | 6 names + 3–5 bare steps | **11** real BD services, full how-to |
| Per service | name, portal, steps | + **required-docs checklist**, fee, where/office, official link, processing time, common mistakes, source + disclaimer |
| Find | scroll a flat list | **search** + **8 category** chips + **Saved** filter |
| Save | none | **bookmark/save**, persisted (SharedPreferences) |
| Offline | load fails → nothing | **offline cache** (last good payload) + bundled fallback; honest banner |
| Flows | none | **"what do I need for X"** checklist sheet; open official site |
| States | loading / error only | all §21: loading, empty (welcome), no-results, no-saved, error+retry, **offline/cached banner**, bilingual, WCAG |
| Fees | stated flatly | **never invented** — every fee marked verify-on-portal + source |
| Religious tips | mixed in here | dropped from this module (identity/travel/… categories only) |

The 11 services: NID, e-Passport, Birth registration, Driving licence,
TIN & e-Return, Land record (porcha/khatian), Trade licence, New electricity
connection, New water/gas connection, Police Clearance Certificate, Vehicle
registration (BRTA).

## Fees are SOURCE-NOTED, never invented
This is enforced, not just a convention:
- `govt_guide.py#_svc` sets `fee_verify=True` and a `source` (the official
  portal) on **every** service; the fee *text itself* contains a verify cue
  (e.g. "verify on the portal", "fee varies … verify"). No exact taka amount is
  asserted as final anywhere.
- The test `test_no_invented_fees_honesty_invariant` asserts, for every service:
  `fee_verify is True`, the English fee contains "verify", a non-empty portal
  source exists, and `source_en` starts with "Source:". `has_no_invented_fees()`
  is the reusable guard.
- The UI renders a `guideVerifyOnPortal` chip beside every fee **and** every
  processing time, a per-card `source` + `disclaimer` footer, and a persistent
  top-of-list verify strip. Processing times are treated identically
  (`time_verify=True`).

## §21 — all 10 covered
1. **Empty** — welcome state (title + body + category hint) on first open.
2. **Loading** — `SkeletonList`.
3. **Error** — `StateMessage` + Retry, only when there is no cache AND no fallback.
4. **Offline** — offline-first: `api.guides()` fails → last-good cache → bundled
   English fallback; an amber `guideOfflineBanner` says so and offers Retry when
   back online. The whole guide (search, categories, bookmarks, checklists) works
   with no network.
5. **Bilingual** — zero Bangla literals in any `.dart` (grep-verified). All UI
   copy via `AppLocalizations` (`t.guide*`); all CONTENT (bn+en) comes from the
   server/cache, localised by the backend.
6. **WCAG** — theme `ColorScheme` + `Brand` tokens; numbered step chips, checklist
   ticks, tappable 42px targets, `tooltip`s on icon buttons, no clipped text
   (`maxLines`/`ellipsis` on action labels).
7. **Scenario** — open offline → search "passport" → auto-expanded single result
   → tap "What do I need?" → see docs + fee(verify) + office → open official site.
8. **Edge data** — missing `url`/`office`/`time`/`docs` are all conditionally
   hidden; empty service list → welcome/no-results state.
9. **Save/bookmark** — persisted set; a **Saved** chip filters to it; empty-saved
   state guides the user to the bookmark icon.
10. **Search + categories** — case-insensitive substring over
    name/portal/steps/docs/mistakes; 8 category chips; clear-filters affordance.

## Backend wiring (one-line swap; NOT done here because views.py is out of scope)
`core/views.py#govt_guide` currently returns `guides.localized(req_lang(request))`
(the OLD basic module). To serve the ADVANCED payload, change the import:
```python
from .logic import govt_guide            # was: from .logic import guides
return Response(govt_guide.localized(req_lang(request)))
```
`govt_guide.localized(lang)` returns `{version, categories[], services[],
disclaimer}` — exactly the shape `GuideData.fromJson` parses. `api.guides()`
(`GET /guides`, unchanged) already feeds the screen. Optional endpoints the
module also supports for future routes (no new URL added here):
`govt_guide.search(query, lang, category)` and
`govt_guide.what_do_i_need(service_key, lang)`.

Until the swap, the app still works: the screen parses whatever `/guides`
returns; if the old flat payload arrives (no `categories`/`version`), it renders
what it can and the offline fallback covers a cold start.

## ARB codegen (required before the app builds)
Merge the **28** keys from `up_guide_arb.json` into `app/lib/l10n/app_en.arb`
(en = index 1) and `app_bn.arb` (bn = index 0), then run `flutter gen-l10n`.
Until then the `t.guide*` getters won't exist (same deferred-codegen pattern as
the other `.phaseB/*_arb.json` drops). One placeholder key needs a
`placeholders` block in the `.arb` metadata:
- `guideWhatYouNeedFor` → `{service}` (type String).

## Tests
```
cd backend && python3 -c "import core.logic.govt_guide_tests_snippets as t; t.run_all()"
```
→ **5 tests pass**: services present & complete (11, all categories, bn/en step
counts aligned), localisation (no Bangla leaks into `en`, keys flattened),
search (filter/query/category incl. a docs-text match), the "what do I need"
flow, and the no-invented-fees honesty invariant. The pre-existing Django test
`LocalizationTests.test_guides_localized_both_languages` is unaffected — the old
`core/logic/guides.py` is untouched.
