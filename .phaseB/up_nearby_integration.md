# Nearby — ADVANCED upgrade (integration notes)

Scope kept inside the allowed edit surface:
- **Edited:** `app/lib/screens/nearby_screen.dart`
- **New widgets (`nearby_` prefix):** `app/lib/widgets/nearby_data.dart`,
  `app/lib/widgets/nearby_category_bar.dart`, `app/lib/widgets/nearby_place_card.dart`
- **Backend (optional, taken):** `backend/core/logic/nearby.py` (+ tests
  `backend/core/logic/nearby_tests_snippets.py`)
- **Strings:** `.phaseB/up_nearby_arb.json` ({key:[bn,en]}, 34 keys)
- **Untouched (as required):** `api.dart`, `app_*.arb`, `models.py`, `urls.py`,
  sidebar/chatnav, migrations, Asalify/crm, existing `backend/core/nearby.py`
  (live Places→OSM path) and `core/views.py#nearby`.

## 1. ARB codegen (required before the app builds)
The 34 new keys in `up_nearby_arb.json` must be merged into
`app/lib/l10n/app_en.arb` (en = index 1) and `app_bn.arb` (bn = index 0), then
`flutter gen-l10n` run to regenerate `app_localizations*.dart`. Until then the
`t.nearby*` getters referenced by the screen/widgets won't exist. This is the
same deferred-codegen pattern used by the other `.phaseB/*_arb.json` drops.

Placeholder keys (need `placeholders` in the .arb metadata):
- `nearbyKmAway` → `{km}`
- `nearbyMAway` → `{m}`
- `nearbyHoursRange` → `{open}`, `{close}`

## 2. Key-gate / live path (honest states)
The feature is **fully built on a curated BD dataset** and is honest about it:
- `nearbyMockBanner` — persistent amber banner: "sample list — goes live when
  the Maps key + location are enabled."
- `nearbyLocationBanner` + **Enable** action — shown when GPS is off/denied;
  the curated list still renders, just **without distances** (distance column
  is hidden, sort-by-distance is a no-op). No fake coordinates, no fake ratings.

To go LIVE later (no edits needed to these files):
- Location is already wired via `geolocator` (permission-reason dialog reused).
- The live Places→OSM backend already exists at `backend/core/nearby.py` and is
  reached through `api.dart#nearby(lat,lon,type)`. To switch the screen from
  mock to live, the integrator swaps `kNearbyMock` for an `api.nearby(...)` call
  behind an `integrations.is_enabled("google_places")` flag (today that key is
  absent, so mock is correct). The advanced UI (card, chips, filter bar, sort,
  favourites) consumes a plain place shape and maps 1:1 onto both sources.

## 3. Mock dataset note
- `app/lib/widgets/nearby_data.dart` — 16 curated central-Dhaka places spanning
  **all 11 categories**: hospital, pharmacy (with 24h flag), ATM/bank,
  bKash/Nagad agent, police, fire, bus/train/launch, fuel/CNG, restaurant,
  mosque, govt office. Names are **romanized proper-noun data** (no Bangla
  literals in any .dart — constraint honored; Bangla digits rendered via
  `U+09E6` codepoints).
- `backend/core/logic/nearby.py` — the **bilingual** mirror (bn+en names) plus
  `haversine_m`, `is_open` (24h / normal / past-midnight / unknown), `search`
  (filter + query + sort distance|open|name) and `nearest(what, lat, lon)` for
  the emergency quick-access. Returns `source: "mock"`. Invents no ratings.
  An endpoint wrapping this should return the `mock` source + a `key_gated`
  flag so the app banner stays honest.

## 4. Emergency quick-access ("nearest X")
`NearbyScreen(placeType: 'hospital'|'pharmacy'|'police'|'atm'|'restaurant')`
pre-selects the matching category on open — the existing emergency/SOS context
can deep-link straight to the nearest hospital/pharmacy/police list. Backend
`nearby.nearest('hospital', lat, lon)` gives the single closest for a card.

## 5. Tests
`cd backend && python3 -c "import core.logic.nearby_tests_snippets as t; t.run_all()"`
→ **7 tests pass** (haversine, open/closed incl. past-midnight + unknown,
filter/query/sort, no-location still lists, nearest-X + alias, all categories
present, honesty invariants: source==mock & rating is None).
