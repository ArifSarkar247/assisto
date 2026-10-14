# Farmer / village mode (#199) + Trust / proof page (#201) — integration notes

Two ADD-ONLY features for SPEC v2.1 §20, built to the §21 "advanced" standard.
NEW files only; NO external key. **Not touched:** `api.dart` request helpers,
`core/models.py`, `core/urls.py`, sidebar / `app_drawer.dart`, `app_en.arb` /
`app_bn.arb`, migrations, Flutter builds, Asalify.

---

## 1. New files

### #199 Farmer / village mode
- **New** `app/lib/screens/farmer_mode_screen.dart` — large-touch 3-tab screen
  (Ledger / Crop calendar / Livestock), benchmarked on `elderly_home_screen.dart`
  (big glyphs 18–28sp, >=56dp targets, locale-digit helper, few choices, honest
  states). Token→label switches (`farmerCropLabel` / `farmerSeasonLabel` /
  `farmerAnimalLabel` / `farmerStatusLabel`) live here so the engine stays prose-
  free. CRUD via generic collections; add/edit bottom-sheet forms with inline
  validation; delete-confirm dialogs.
- **New** `app/lib/widgets/farmer_engine.dart` — on-device Dart MIRROR of
  `backend/core/logic/farmer_mode.py` (deterministic; `now` passed in). Exposes
  `FarmerEngine.{recordStatus,recordProfit,ledgerSummary,validateRecord,
  seasonForMonth,seasonNow,cropsForSeason,calendar,vaccinationStatus,
  livestockSummary,validateLivestock}` + value types + the token tables
  (`kSeasons`, `kAnimalKeys`, status/vacc constants).
- **New** `backend/core/logic/farmer_mode.py` — PURE engine: no Django, DB, net,
  AI, or wall-clock (caller passes `now`). Farm-profit math (never invents a
  price), a FIXED cropping-season almanac (Rabi / Kharif-1 / Kharif-2 — NOT live
  weather), and vaccination-due (due/soon/ok/unknown) as the reminder SEAM.
- **New** `backend/core/logic/farmer_mode_tests_snippets.py` — 27 plain-assert
  tests, `run_all()` green; folded into the Django suite (one line, below).

### #201 Trust / proof page
- **New** `app/lib/screens/trust_page_screen.dart` — STATIC transparency page
  (no backend, no persistence). Integrity statement + "what we do" verified
  claims + "what we never do" + a conservative licensing note + links out to the
  Legal and About surfaces via `ChatNav.push('legal' | 'name_about')`. §21: all
  strings localised, WCAG tokens, FittedBox title + wrapping bodies (360dp safe).
  No loading/empty/error needed — static content always renders.

### Shared
- **New** `.phaseB/up_farmtrust_arb.json` — **119 keys** `{key:[bn,en]}` + a
  `_params` object. (87 `farmer*`, 32 `trust*`.)
- **Edited** `backend/core/tests.py` — ONE registration line (allowed):
  ```python
  FarmerModeSnippetTests = _make_snippet_case(
      "core.logic.farmer_mode_tests_snippets", "FarmerModeSnippetTests")
  ```

---

## 2. ARB keys + `_params`

- 119 new keys total, bn+en balanced, in `.phaseB/up_farmtrust_arb.json`.
  Integrator merges into `app_en.arb` / `app_bn.arb` (I did NOT edit them).
- The ONE parameterized key (register the placeholders when merging):
  - `farmerVaccDueSummary` → `_params`: `["due", "soon"]`
    bn `"{due} টি পশুর টিকা এখন বাকি, {soon} টির শীঘ্রই দরকার।"` /
    en `"{due} animal(s) due for vaccination now, {soon} due soon."`
- Currency sign `৳` (U+09F3) is used in `farmerFieldCost` / `farmerFieldIncome`
  and in Dart (gate-exempt, like `$`).
- Common keys REUSED from the existing ARB (not re-emitted): `save`, `delete`,
  `cancel`, `retry`, `loadFailed`, `saveFailed`, `monthJan`…`monthDec`.

---

## 3. Persistence — generic REST collections (no api.dart edit)

Register both in `GENERIC_COLLECTIONS` (`core/views.py`, PaCollectionItem
precedent — no model, no migration). Add to the list beside the other §20 entries:

```python
# #199 Farmer / village mode
"farmer/records", "farmer/livestock",
```

The screen calls the existing generic helpers only:
`listItems / createItem / updateItem / deleteItem`.

### Row shapes (one flexible per-user JSON collection each)

**`farmer/records`** — one crop ledger row:
```
{id:int, name:str, crop:str (crop token or ""),
 planted:"YYYY-MM-DD"|"", harvest:"YYYY-MM-DD"|"",
 cost:number (৳), income:number (৳), notes:str}
```
`crop` is one of the stable crop tokens (boro_rice, wheat, potato, mustard,
lentil, onion, garlic, maize, tomato, cabbage, aus_rice, jute, chilli, aubergine,
cucumber, bitter_gourd, okra, aman_rice, pumpkin, spinach, radish, cauliflower,
bean) — labels localised in Dart, never stored as prose.

**`farmer/livestock`** — one animal row:
```
{id:int, animal:str (cow|goat|sheep|buffalo|chicken|duck),
 count:int, last_vaccinated:"YYYY-MM-DD"|"", notes:str}
```

Each row round-trips as `{id, ...data}`. Blanks are allowed (a *planned* crop may
carry no numbers yet; an animal may have no vaccination date → status `unknown`).

---

## 4. Reminder SEAM (livestock vaccination) — documented, not faked

`farmer_mode.py::vaccination_status(last_vaccinated, now, interval_days=180)`
decides WHETHER a booster is `due` / `soon` (<=14d) / `ok` / `unknown`. It sends
nothing. To deliver the reminder the integrator can:
- **Now (no key):** surface due/soon animals in the existing in-app
  notification/reminders path (same pattern as medicine refill), computed on app
  open/resume — consistent with the foreground-poll decision in MEMORY.
- **Key-gated:** SMS/IVR when an owner SMS/voice provider key is present.
The engine's `livestock_summary` already returns `vacc_due` / `vacc_soon` counts
for a badge; no new endpoint needed.

---

## 5. Tests

- `backend/core/logic/farmer_mode_tests_snippets.py` — **27** tests, all pass
  standalone (`python farmer_mode_tests_snippets.py` → "27 snippet tests passed").
- Registered as `FarmerModeSnippetTests` via `_make_snippet_case` (the
  `SocialComposeSnippetTests` precedent). Module imports cleanly under the venv.
  (The full Django `manage.py test` needs Postgres CREATE-DATABASE rights, which
  are denied here because the DB is shared with live Asalify — an environment
  limit, not a code issue; the factory wraps the same 27 functions that pass.)
- #201 has no backend → no tests.

---

## 6. Sidebar / routing wiring (for the integrator — I did NOT edit the drawer)

- **#199 Farmer mode** → **Daily Life** group (a mode for rural users, like the
  other life tools). Optionally also expose as a large-touch mode toggle in
  Settings next to Elderly mode. Route token suggestion: `farmer_mode`.
- **#201 Trust page** → **Settings / About** area (next to Legal and About).
  Route token suggestion: `trust`.
- `ChatNav` (route→widget map + synonyms) and `core/screen_synonyms.py` are the
  integrator's to update (open-from-chat). Suggested synonyms:
  - farmer: "farmer mode", "village mode", "crop calendar", "farm ledger",
    "livestock" (+ bn equivalents in `screen_synonyms.py`).
  - trust: "trust", "transparency", "proof", "what you do with my data"
    (+ bn equivalents).
- The Trust page already links INTO `legal` and `name_about` via `ChatNav.push`
  (both routes already exist in `chatnav.dart`).

---

## 7. #201 — the exact claims made (verify against the codebase)

Every claim is written to be TRUE today; anything not fully shipped is phrased
conservatively.

| # | Claim (en) | Verified against |
|---|---|---|
| 1 | "We never hold your money" — no wallet, no charge; bill-pay only pre-fills & opens your OWN bank/bKash/Nagad app, you press Send. | `payment_ladder_screen.dart` (`kHoldsMoney=false`, "NEVER hold money / NEVER auto-charge"; steps open the user's own app prefilled). |
| 2 | "Your Circle chats are end-to-end encrypted" — TEXT today; server stores ciphertext only; photos/voice/video "coming when encrypted storage is enabled" (not claimed). | `core/logic/circle.py` (software fallback x25519+AEAD, "server stores CIPHERTEXT ONLY"; `MEDIA_UNLOCKED` text=True, voice/photo/video/call=False with "available when … enabled" reasons). |
| 3 | "AI runs only with your key and consent" — no AI without an owner key; AI never auto-posts/pays/applies; memory is shown and deletable. | `core/ai.py` (multi-provider, key from Integrations store, prompt-injection guard); social composer "never posts for you"; payment ladder no auto-charge; job hunter "NEVER auto-applies"; memory screen (explicit, deletable). |
| 4 | "We never sell your data" — no third-party ad/tracking SDKs; analytics are our own, identity-free (hashed id, event allow-list, day buckets). | No `firebase_analytics/google_analytics/mixpanel/segment/amplitude/sentry/facebook_app_events` in `app/pubspec.yaml`; `core.models.AnalyticsEvent` = salted HMAC `uid_hash` + allow-listed event name + day bucket. |
| 5 | "Your data, your control" — export everything + delete your account in-app; vault is PIN-locked. | `api.dart` `exportRaw()` (`/export`) + `deleteAccount()` (`/account/delete`); `vault_screen.dart` PIN lock. |
| 6 | "Where your data lives" — stored on Assisto's own server; not sold or handed to third parties. | Own Django+Postgres backend; stated conservatively (no specific region/host claimed). |
| 7 | "Licensing & building blocks" — we AIM to use permissively-licensed, auditable encryption building blocks (e.g. OpenMLS, Apache/MIT); **the app itself is not yet open source** (stated plainly, not overclaimed). | E2E design prefers OpenMLS (Apache/MIT) over libsignal-AGPL (`circle.py`, MEMORY, P13 notes); repo has NO LICENSE file → NOT claimed open-source. |

"What we never do" list (mirrors the above, in the negative): never hold/charge
your money; never sell your data or hand it to advertisers; never read your
encrypted chats; never post/pay/apply without your go-ahead; never add
third-party trackers.

---

## 8. Section-21 checklist

**#199 Farmer mode** — welcome (per-tab first-use state with CTA), loading
(SkeletonList), error (StateMessage + Retry), bilingual (every string an l10n
getter; zero Bangla literals — gate CLEAN; `৳` exempt), WCAG (solid high-contrast
accents + theme tokens), large-touch (18–28sp, >=56dp targets, locale digits),
honest (never invents a price; `unknown` vaccination state; deterministic),
no-clip at 360dp (FittedBox title, ellipsis + wrapping), deterministic+tested
(engine + 27 snippet tests), real scenario (a farmer logs a boro-rice crop,
sees profit + status, reads the current season's crops, tracks a cow whose
booster is due).

**#201 Trust page** — bilingual, WCAG, no-clip (FittedBox + wrapping bodies),
honest (every claim verified; conservative where unsure; nothing overclaimed),
static (always renders → no loading/empty/error path required), links to the
real policy surfaces.

---

## 9. Language-gate confirmation

`python app/tool/lang_gate.py` → **"LANG GATE: clean ✓"** after adding both
screens + the engine. The only non-ASCII in the new `.dart` is `৳` (U+09F3, the
currency sign, gate-exempt) in `farmer_mode_screen.dart`. `trust_page_screen.dart`
and `farmer_engine.dart` are pure ASCII.
