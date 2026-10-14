# Integration note — SUPPORT surfaces §21 (#180 In-app update, #181 Support center)

Two user-facing support surfaces upgraded to the Section-21 "advanced" standard
(loading/empty/error+retry states, bn/en, honest states, no clipped text at
360dp). All user-facing strings come from ARB getters; **zero Bangla literals in
any `.dart`** (verified: `grep -P '[\x{0980}-\x{09FF}]'` over the new files is
empty).

## Files changed

### New (Flutter)
- `app/lib/screens/app_update_screen.dart` — #180 version-check surface.
- `app/lib/screens/support_center_screen.dart` — #181 support center (2 tabs).
- `app/lib/widgets/support_widgets.dart` — `TicketStatusPill`, `TicketCard`,
  `FaqTile`, and the `ticketStatusOf()` helper (honest 3-state mapping).

### New (Django)
- `backend/core/logic/app_update.py` — pure version-compare helper.
- `backend/core/logic/app_update_tests_snippets.py` — 12 plain-assert tests.

### Edited
- `app/lib/screens/settings_screen.dart` — added two imports and wired **exactly
  one** bounded entry for each surface:
  - the existing "Support / report" tile (`supportReportTile`) now opens
    `SupportCenterScreen` instead of the old inline `SupportScreen`;
  - a new tile (`updateTile` / `updateTileSubtitle`,
    `Icons.system_update_outlined`) opens `AppUpdateScreen`, placed directly
    after the support tile.
  (The old inline `SupportScreen` class is intentionally **kept** — it is still
  used by `messenger/messenger_settings_screen.dart`, which was not touched.)
- `backend/core/tests.py` — registered `AppUpdateSnippetTests` via the existing
  `_make_snippet_case(...)` pattern, right after `SocialComposeSnippetTests`.

## Endpoints used (no new endpoints, no urls.py / api.dart changes)

Both surfaces reuse endpoints that already exist:

- `GET  /api/v1/app/latest` — `{version_code, version_name, apk_url, notes}`.
  Used by `AppUpdateScreen` (direct `http.get` via `AppConfig.api(...)`, since
  it is `AllowAny` and api.dart was off-limits). Decides update availability
  with the same fail-closed logic as `app_update.py`.
- `GET  /api/v1/support/`  (SupportViewSet list) — via `ApiClient.listItems('support')`.
  Feeds the "My tickets" tab.
- `POST /api/v1/support/`  (SupportViewSet create) — via `ApiClient.createItem('support', {...})`.
  Submits a new ticket `{kind, message, app_version}`.

`app_update.py` is a **pure** helper (no view wired) — it exists so the
integrator can, if desired, serve a ready-made decision payload
`{latest, current, update_available, changelog, url}` from a thin view over
`GET /app/latest`. The Flutter screen already mirrors this logic client-side, so
wiring a view is optional.

## New ARB keys

Emitted to `.phaseB/up_support_arb.json` as `{"key": ["<bn>", "<en>"], ...}`.
**55 new keys.** Run them through `merge_arb.py` (adds only missing keys;
existing keys untouched).

Parameterized keys (listed in the file's `_params` object; add to `PARAMS` in
`merge_arb.py` for `@`-metadata):

| key                 | params   | placeholders | notes |
|---------------------|----------|--------------|-------|
| `updateVersionLine` | `[v, n]` | `{v} → {n}`  | v = current version, n = latest version (positional order v, n) |
| `updateUpToDateBody`| `[v]`    | `{v}`        | v = current version |
| `supportSendFailed` | `[v]`    | `{v}`        | v = error detail |

All other 52 keys are plain. `supportContactEmail` is `support@assisto.app` in
both locales — **change this to the real support address** before ship (it is a
localizable getter precisely so the integrator can set it without touching Dart).

## Model the integrator MAY add (optional — NOT added here, no migration)

Persistence works today with the existing `SupportTicket` model
(`kind ∈ {support, bug}`, `message`, `app_version`, `resolved`, `reply`,
`created_at`). The support center offers four submission **categories**
(Help / Bug / Account / Payment); only Help/Bug map to the backend `kind`.

- Account/Payment tickets are currently sent as `kind='support'` with the
  category **folded into the message body** as a `[Category] …` prefix, so no
  user choice is silently dropped (honest).
- To store the category as structured data, add to `SupportTicket`:
  - `category = models.CharField(max_length=16, blank=True, default="")`
    — why: lets support staff filter/triage by Account vs Payment vs general,
    and lets the app render the exact category on the ticket card instead of a
    body prefix.
  Then add `"category"` to `SupportTicketSerializer.fields`, send
  `'category': <value>` from `_GetHelpTab._submit`, and drop the body-prefix
  fallback. **Add the migration yourself** (not added here, per constraints).

No other model is required. The "My tickets" status pill is derived purely from
existing fields (`resolved` → Resolved, non-empty `reply` → Answered, else Open).

## Tests added

- `backend/core/logic/app_update_tests_snippets.py` — **12** plain-assert tests
  (`run_all()` prints `app_update: 12 tests passed`), covering version parsing,
  ordering (numeric not lexical), fail-closed on garbage, the full
  `check_update` payload shape, "up to date" hiding the url, newer-local-not-an-
  update, version_code fallback, unsafe-URL stripping, and empty/non-dict
  records.
- Registered in `backend/core/tests.py` as `AppUpdateSnippetTests` so the Django
  test runner picks it up (`python manage.py test core.tests.AppUpdateSnippetTests`).

Standalone run verified green in this environment:
`cd backend/core/logic && python3 app_update_tests_snippets.py` → `12 tests passed`.
(Django harness not runnable here — no venv/django installed — but the wiring
follows the identical `_make_snippet_case` pattern as all sibling snippet suites.)

## Wiring steps for the integrator

1. `python merge_arb.py` with `.phaseB/up_support_arb.json` to add the 55 keys to
   `app_en.arb` / `app_bn.arb`; add the 3 parameterized keys to `PARAMS`.
   Regenerate localizations (the lang gate must stay clean: en == bn count).
2. Set `supportContactEmail` to the real support address (both locales).
3. `flutter analyze` — the new `.dart` files reference only the new ARB getters
   (undefined until step 1) plus existing symbols; after step 1 they resolve.
4. `python manage.py test core.tests.AppUpdateSnippetTests` → 12 pass.
5. (Optional) add the `category` field + migration per the model note above and
   drop the body-prefix fallback in `_GetHelpTab._submit`.
6. Both entries live under Settings; no sidebar / nav changes were made.
