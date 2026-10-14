# Offline-first (#12, SPEC v2.1 §21) — integration note

Strengthens Assisto's OFFLINE capability from *good* to *advanced*: a reusable
cache helper + banner, and an honest "Offline & data" screen. Nothing shared
was edited (no `state.dart` / `api.dart` / `models` / `urls` / `sidebar` /
existing screens / `app_*.arb`).

## New files (all additive)

- `app/lib/widgets/offline_cache.dart` — `OfflineCache<T>` (write-through
  SharedPreferences via the existing `Settings` store, TTL, last-synced
  timestamp, size, clear) + the `OfflineModules` registry the screen enumerates.
- `app/lib/widgets/offline_banner.dart` — `OfflineBanner` / `OfflineBanner.chip`
  reusable offline indicator; renders nothing while online.
- `app/lib/widgets/offline_strings.dart` — bilingual `oStr`/`oStrNum`/`oStrS`
  table (mirrors `up_offline_arb.json`); keeps new UI bilingual TODAY without
  touching `app_*.arb`. No Bangla glyph literals in any `.dart`.
- `app/lib/widgets/offline_module_tile.dart` — `OfflineModuleStatus` (resolver)
  + `OfflineModuleTile` (name, "works offline" badge, honest cached/not-cached/
  pure-local state, last-synced, per-module clear).
- `app/lib/screens/offline_status_screen.dart` — the "Offline & data" screen:
  live online/offline card, per-module list, data-usage note, clear-one +
  clear-all (server copy never touched).

## Wiring (left for the owner — not done here, per task rules)

The screen is not yet linked, because the sidebar is off-limits. To surface it,
add one route/drawer entry (in `app_drawer.dart` or the router) pointing at
`const OfflineStatusScreen()`. No other change is needed.

## How an existing module ADOPTS `OfflineCache<T>`

Today's per-module stores (`dict_store`, `meddb_store`, `ride_store`, the
`SyncedRepo`s for notes/reminders/todos, the contacts model) already persist via
`Settings`. Adopting the shared helper is opt-in and incremental — it adds the
missing pieces (last-synced timestamp, TTL, uniform clear) without a rewrite:

```dart
// 1. Declare a typed cache for the module (id must match OfflineModules).
final _cache = OfflineCache<List<Map<String, dynamic>>>(
  id: 'notes',
  ttl: const Duration(days: 30),            // optional
  decode: (j) => (j as List).cast<Map<String, dynamic>>(),
  encode: (v) => v,
);

// 2. WRITE-THROUGH right after a successful server fetch / local mutation:
await _cache.save(notes);                    // also stamps "last synced = now"

// 3. READ on open — show this instantly, then refresh when online:
final cached = await _cache.read() ?? const [];

// 4. The "Offline & data" screen then reports this module's last-synced,
//    size, staleness and offers clear — automatically, because 'notes' is
//    already registered in OfflineModules.all().
```

Registering a brand-new module is a **one-line** add in
`OfflineModules.all()` (a `_cache('<id>')` plus its `offMod<Id>` display-name
key in `offline_strings.dart` + `up_offline_arb.json`).

Drop-in offline indicator for any screen body:

```dart
const OfflineBanner(),                        // full-width strip, auto-hides
// or in a dense header:
const OfflineBanner.chip(),
```

## Honesty / safety

- `read()` returns exactly what was last written, or `null` — never fabricated.
- `isStale()` only *labels* an old copy; the data is still returned.
- Clearing a cache removes only the on-phone copy; nothing on the server is
  deleted (stated in-screen via `offServerSafeNote`).
- Pure-local modules (e.g. finance calculators) show a "works offline" badge and
  "always offline — no data to store", with no fake last-synced time.

## ARB

`up_offline_arb.json` — 35 keys, each `{key: [bn, en]}`, to merge into
`app_bn.arb` / `app_en.arb` at the next sync. Placeholder style uses `{n}` /
`{size}` for the sync-time/size lines so they become standard ARB plural-free
placeholders on merge; the Dart side fills them via `oStrNum`/`oStrS` today.
