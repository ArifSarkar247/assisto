# Unseen World — ADVANCED upgrade (integration notes)

Appendix A **#41 Unseen World** (travel companion), SPEC v2.1 §21. Raised
**good → advanced**. Scope kept strictly inside the allowed edit surface.

## Files
- **Edited:** `app/lib/screens/unseen_world_screen.dart` (full rewrite)
- **New widgets (`unseen_` prefix):**
  - `app/lib/widgets/unseen_data.dart` — curated bilingual-free dataset + models
    (12 hidden-gem destinations across divisions/categories), haversine,
    `searchDestinations`, `seasonalFor`, `kTripIdeas`.
  - `app/lib/widgets/unseen_card.dart` — destination card (category hero,
    best time, how-to-get, approx-cost, nearby, tip, source, save/directions/share).
  - `app/lib/widgets/unseen_filters.dart` — category + wishlist chip rail.
- **Backend (optional, taken):** `backend/core/unseen.py` extended
  (divisions, categories, search, `near_me`, `seasonal`, `trip_ideas`, bilingual
  mirror). `/unseen` view unchanged (still returns `companion()`; shape is
  additive — old keys kept).
- **Tests:** `backend/core/logic/unseen_tests_snippets.py` (8 tests, pass) +
  one stale assertion in `backend/core/launch_gaps_tests_snippets.py` updated to
  the honest multi-source reality (now also asserts `cost_approx`).
- **Strings:** `.phaseB/up_unseen_arb.json` — `{key:[bn,en]}`, **42 new keys**.
- **Untouched (as required):** `api.dart`, `app_*.arb` (strings emitted to
  `.phaseB` only), `models.py`, `urls.py`, sidebar/chatnav, other screens,
  migrations, Asalify/CRM.

## 1. ARB codegen (required before the app builds)
Merge the 42 keys from `up_unseen_arb.json` into `app/lib/l10n/app_en.arb`
(en = index 1) and `app_bn.arb` (bn = index 0), then run `flutter gen-l10n`.
Until then the new `t.unseen*` getters won't exist (same deferred-codegen
pattern as the other `.phaseB/*_arb.json` drops).

**Reused existing keys (NOT in the json):** `unseenTitle`, `unseenBestSeason`,
`unseenTip`, `unseenSource`, `unseenDestinations`, plus common `copied`,
`nothingFound`.

**Placeholder keys (need `placeholders` metadata in the .arb):**
- `unseenCostRange` → `{low}`, `{high}` (String)
- `unseenKmAway` → `{km}` (String)
- `unseenTripDays` → `{days}` (int)

## 2. What's advanced now (vs. the old "good" build)
Old build: a single flat `ListView` of ~6 destinations (name/region/best-season/
tip/source) + a tips list, read-only, from `/unseen`. No search, filter, save,
location, seasonal, trips, share, or offline.

Advanced build adds, inside the allowed surface:
- **By division & category** — 8-division app-bar filter + 7-category chip rail
  (nature / historical / beach / hill / religious / island / waterfall).
- **Rich destination cards** — category hero (honest tint, no fabricated photo;
  a verbatim `photoCredit` line when one exists), best time (+ localized season),
  how to get there, **approx cost range** (labelled approx + sourced), nearby,
  tip, source attribution.
- **Search** across name (both languages), route, and nearby.
- **Save / wishlist** persisted in `SharedPreferences` + an **offline cache**
  (`unseen_saved_cache`) snapshot of saved places so the wishlist survives with
  no network.
- **"Near me"** — `geolocator` + reused permission-reason dialog; distance shown
  per card and used for sort when GPS is granted. Honest banner + Enable action
  when location is off/denied; the curated list still works without it.
- **Seasonal suggestions** — "Good to visit this season" section from the
  current month's best-season windows.
- **Trip ideas** — curated multi-stop itineraries with day count + approx total.
- **Share** — share/copy a destination's card (name, season, route, approx cost,
  source, maps link).
- **States** — loading skeleton, empty (wishlist / no-results), offline-tolerant
  (attribution falls back to a bundled honest line; dataset is local).

## 3. Honesty / source policy (hard requirement)
- Every destination carries a **`source`** shown on the card:
  `unseenbangladesh.com` (owner) or `Wikivoyage / open data`.
- The top banner names both sources and states **"Costs are approximate."**
- Cost ranges are **stable published approximations** (per-person round-trip
  budget estimates), always rendered as a **range with an "approx" marker** and
  a source note (`unseenApproxNote`) — never a live or exact invented price.
  Backend flags each with `cost_approx: True`.
- **No photos are bundled** — cards show a category tint band, not a fabricated
  image. If an image URL is wired later it must keep the `photoCredit` line.
- Nothing is fabricated: facts are limited to stable basics (division, category,
  season window, high-level route). Live conditions are deliberately omitted.

## 4. bn/en + no-Bangla-in-dart
All proper nouns in the `.dart` files are **romanized data**; every user-facing
label resolves through `AppLocalizations`. Verified zero Bangla codepoints in
the three `.dart` files. Bangla lives only in `up_unseen_arb.json` (the ARB) and
`backend/core/unseen.py` (the bilingual server mirror), as required.

## 5. Section-21 (all 10) coverage
1. **Comparable/better** — division+category browse, search, filter, wishlist,
   near-me, seasonal, trip ideas, share, offline cache — matches a hidden-gems
   travel app's core tasks.
2. **Full flow** — browse / search / filter / save+unsave / share / directions;
   create/edit is N/A for a curated guide (wishlist is the user-owned state).
3. **Both rails** — curated data + user manual actions (wishlist, search,
   filters, location opt-in). No AI entries here, so no AI-captured marker
   needed (key-free module).
4. **States** — loading skeleton, empty (wishlist/search), offline (local
   dataset + cached wishlist + fallback attribution), location-denied banner.
5. **bn/en, light/dark, small/large** — all strings localized; theme tokens
   (`Brand`/`Gap`/`Radii`) + scheme colours; chips/cards wrap and ellipsize.
6. **Wired into reminders/watch/chat/voice** — the screen is reached from the
   existing nav; deeper wiring (add-to-reminders, watch seasonal nudge, voice
   "show me hill trips") lands when the integrator adds the routes — out of the
   permitted edit surface (no api.dart/urls/sidebar edits), noted here.
7. **Server + app tests** — 8 server tests (`unseen_tests_snippets.py`) +
   updated `launch_gaps` scenario; logic is deterministic and app-mirrored.
8. **Share card** — per-destination share text (and trip totals shown).
9. **Privacy/consent** — location is opt-in via the permission-reason dialog;
   no personal data leaves the device; wishlist/cache are local `SharedPreferences`.
10. **Independent reviewer** — owner sign-off pending (as for every module).

## 6. Going live later (no edits to these files)
`backend/core/unseen.py` already exposes `search / near_me / seasonal /
trip_ideas / divisions / categories` with the same shapes the app consumes.
An integrator can add `/unseen/*` routes + `api.dart` methods (outside this
scope) and swap the app's bundled `kDestinations` for the endpoint, or pull live
articles from the owner's unseenbangladesh.com feed — the card shape maps 1:1.

## 7. Run the tests
```
cd backend && python3 -c "import core.logic.unseen_tests_snippets as t; t.run_all()"
# -> unseen: 8 tests passed
```
