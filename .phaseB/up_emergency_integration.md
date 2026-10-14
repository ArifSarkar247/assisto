# Emergency + SOS — upgrade (BASIC → ADVANCED)

Agent upgrade of the Emergency module. Reuses Safe Journey's location/SOS/
countdown mechanisms; does not duplicate them.

## Files
EDITED
- `app/lib/screens/emergency_screen.dart` — rewritten: offline-cached editable
  emergency card (preview + editor), one-tap SOS panel, verified helpline
  directory, nearest-help, first-aid; share-as-text/image; full states.
- `backend/core/logic/safety.py` — ADDED pure helpers only (no edits to existing
  logic): `EMERGENCY_HELPLINES` + `emergency_helplines(lang)`,
  `FIRST_AID_CARDS` + `first_aid_cards(lang)`, `emergency_card_text(card,lang)`.
- `backend/core/logic/safety_tests_snippets.py` — +3 tests (now 17, all pass;
  safety_journey 25 still pass).

NEW widgets (all `emergency_`-prefixed under `app/lib/widgets/`)
- `emergency_sos_panel.dart` — big active-language SOS button, countdown-cancel
  (reuses `SafetySosCountdown`), loud mode (haptics now; siren = native TODO),
  calls 999 + shares live location to family.
- `emergency_card_view.dart` — high-contrast printable card + RepaintBoundary
  image capture + share-as-text/image helpers.
- `emergency_helplines.dart` — verified BD directory, one-tap call, bn/en,
  source line. Numbers hard-coded so it works fully OFFLINE.
- `emergency_first_aid.dart` — source-named first-aid quick cards (never
  diagnose; each routes to 999).
- `emergency_nearest_help.dart` — reuses `api.nearby` for nearest hospital +
  pharmacy with directions.

## ARB
`.phaseB/up_emergency_arb.json` — 76 new keys, `{key:[bn,en]}`, camelCase.
Merge into `app_*.arb` + regenerate `AppLocalizations` via the usual merge step
(same as every prior phaseB module). The 87 analyzer "undefined getter" errors
are ONLY these unmerged keys — zero structural errors; zero Bangla in any .dart.
Placeholders: `emergencySosAlertSubject(name)`, `firstAidSourceLabel(source)`.
Big SOS/I'm-OK label = `emergencySosBigButton` — resolves to the active
language only (no combined "bn / en" literal). Bangla digits in .dart via code
points (`_digits`/`localeDigits`), mirroring owner_analytics_screen.

## Reuse (no new wiring needed)
- `api.getEmergency()` / `api.putEmergency()` — unchanged; card now also sends
  new fields `name, doctor, insurance, nid, organ_donor` inside the same PUT
  body (extra keys; see backend note below).
- `api.nearby(lat,lon,type)` — reused for nearest-help.
- `Settings.getString('safety_sos_cd')` — shared SOS countdown value.
- `SafetySosCountdown` widget + `safety.sos_phase` semantics — reused for the
  countdown-cancel.

## Verified helplines (confirmed 2026)
Sources: thedailystar.net (999 launch), tbsnews.net + thedailystar.net (Fire
Service 102 hotline), ambulance 199 (Central Ambulance Coordination). 999 is the
single toll-free national line for police/fire/ambulance.
- 999  National Emergency (police/fire/ambulance, toll-free 24/7) — PRIMARY
- 109  Violence against Women & Children (MoWCA, toll-free)
- 333  Government Information Service
- 102  Fire Service & Civil Defence
- 199  Central Ambulance Coordination Centre
- 100  Police Control Room (999 is primary)
- 1090 Disaster / weather warning (toll-free)

## Backend / API needs (NOT wired — emit only)
1. **Emergency card extra fields.** `PUT /emergency` now receives
   `name, doctor, insurance, nid (ref only), organ_donor (bool)` plus the
   existing `blood_group/allergies/medicines/conditions/contacts`. Persist +
   echo them in `GET /emergency`. The app already caches the full card offline
   (`shared_preferences` key `emergency_card_cache`) so it degrades gracefully
   until the server stores the new fields. NID should be stored as a reference
   string only (treat as sensitive; do not index/log).
2. **`police` nearby type.** `/nearby` supports `hospital`/`pharmacy` but not
   `police` (falls back to restaurant). Add
   `_PLACES_TYPE["police"]="police"` and
   `_OSM_FILTER["police"]='node["amenity"="police"]'` in `core/nearby.py` to
   enable a nearest-police row; until then the UI requests only hospital +
   pharmacy and police contact is covered by 999/100.
3. **SOS auto-send (native).** The SOS panel currently fires via the share sheet
   + `tel:999`. A true silent auto-SMS/FCM to family (no user tap) is the
   integrator's native path — reuse `safety.sos_payload(name, maps_link, lang)`
   / `safety_journey.sos_journey_payload` for the message body and the existing
   Circle+FCM/poll alert pipeline. Loud-mode siren needs a native audio plugin;
   haptics work today.
4. **Backend helpers available** (pure, no key): `safety.emergency_helplines`,
   `safety.first_aid_cards`, `safety.emergency_card_text` — expose via an
   endpoint only if you want server-driven content; the app hard-codes the same
   verified set for offline use, so an endpoint is optional.

## Advanced vs before
- Before: flat form (4 fields + contacts), one SOS that dialled the first
  contact, a location-share button, a link to safety tools. No card view, no
  helplines, no first-aid, no nearest-help, no offline, no image share.
- Now: proper high-contrast **emergency card** (adds name/doctor/insurance/NID/
  organ-donor) with preview + editor, **offline cache** + offline-save badge,
  **lock-screen share as text OR image**; **one-tap SOS** → countdown-cancel +
  loud mode + calls 999 + alerts family with live location; **7 verified
  helplines** one-tap bn/en with source; **nearest-help** (reuses /nearby);
  **6 source-named first-aid cards** with a standing "not a diagnosis → 999"
  disclaimer; full empty/loading/error/permission states; Gap/Radii/Brand
  tokens throughout.
