# d1-discover — Discover manager + sponsored cards (finish report)

Branch `agent/d1-discover` (based on ship148). No manifest / Gradle / pubspec / native
changes are needed: the app uses packages it already has (http, image_picker,
package_info_plus, path_provider, share_plus, url_launcher). No cron, no systemd,
no nginx and no settings changes are needed.

## What was built

### Backend
- **Models** (block at the end of `core/models.py`): `DiscoverCard`, `DiscoverSeen` (dedupe
  ledger) and `DiscoverDailyStat` (daily aggregate).
- **Migration** `0049_d1_discover_cards.py` (depends on `0048_v1_vehicle_tracking`). It creates
  the tables and seeds the 10 cards the app used to hard-code, with the same order and the same
  bn/en copy as the `discover*` ARB keys. Asalify (`https://asalify.com`) and AXON ERP
  (`https://axonerpsoftware.com`) are seeded as `OUR_PRODUCT`.
- **Rules** (`core/logic/discover.py`, pure functions, all enforced on the server):
  - Disabled cards are hidden.
  - A card shows only inside its start/end window.
  - `min_build`: the card is hidden for older builds, and also when the client sends no build.
  - Audience can be all, free, premium or business. It is matched against the plan segment
    from `billing._segment_of`.
  - Premium and Business users never receive SPONSORED or ADMOB cards.
  - ADMOB is for Free users only, at most one, and only when no active SPONSORED card is
    showing for that user.
  - Labels come from the card type and cannot be edited: OUR_PRODUCT gets "our_products" and
    SPONSORED always gets "sponsored".
- **Content safety on every admin save.** It rejects:
  - gambling, adult, and scam or fake-claim wording, with bn and en word lists;
  - anything the existing Scam-check engine (`core.logic.scam.check_message`) rates "scam";
  - links that are not https;
  - link shorteners (the scam module's list plus extras);
  - IP-literal hosts;
  - links pasted inside the title or description text.

  Structural checks: the route must be in `ROUTE_KEYS`, and `ROUTE_KEYS` is tested to stay
  identical to `ChatNav.routes`. Other checks: route or URL but not both, required titles,
  sponsor name required for SPONSORED, end date after start date.
- **Endpoints** (one block in `core/urls.py`, `# ---- d1-discover ----`):
  - App:
    - `GET /discover/cards?build=N` returns the cards for this user.
    - `POST /discover/track {card_id, event}` (or `{events:[...]}`) records impressions and
      clicks. It counts one impression and one click per user per card per local day. It
      ignores events for cards the user may not see right now, for example a Premium user's
      stale cached sponsored card.
  - Owner admin. Every route uses the same superuser gate as `/admin/pnl` and `/admin/pricing`,
    and every write is logged to AuditLog.
    - `GET/POST /admin/discover/cards`
    - `GET/PATCH/DELETE /admin/discover/cards/<pk>`
    - `POST/DELETE /admin/discover/cards/<pk>/image`: PNG, JPG or WEBP up to 2 MB, checked with
      Pillow, stored through the default `SignedMediaStorage`, so `image_url` is a signed
      `/api/v1/m/...` link.
    - `POST /admin/discover/reorder`
    - `GET /admin/discover/meta`: the route picker and icon list.
    - `GET /admin/discover/preview?segment=free|premium|business&build=`
    - `GET /admin/discover/cards/<pk>/report?days=N`: per-day impressions, clicks and CTR,
      with every day in the window filled in.
    - `GET /admin/discover/cards/<pk>/report.csv` and `report.pdf` (reportlab).
- **P&L:**
  - `profit_guard.REVENUE_SOURCES` gains `"sponsored"`.
  - `billing._trailing_rows` merges booked sponsor revenue into each day's
    `revenue_by_source.sponsored`, spread evenly over the card's start to end dates.
    - With a start date only, the whole amount goes on the start date.
    - With no dates, it goes on the day the card was created.
  - This is computed from the cards and never written into DailyLedger, so editing or deleting
    a deal cannot double-count.
  - `/admin/pnl` totals, the series and the profit-guard all include it, and the payload has a
    new `sponsored: {total}` field.
  - A disabled SPONSORED card still counts as a booked deal. Deleting the card removes its
    revenue.
  - Non-sponsored cards are forced to `sponsor_revenue = 0` on save.

### App
- `lib/discover_api.dart` holds a `DiscoverApi` extension on `ApiClient` (api.dart is
  untouched), the `DiscoverItem` model and the icon map.
- `lib/widgets/home_suggestions.dart` is now server-driven. The home layout is unchanged and so
  is the `HomeSuggestions` constructor.
  - On load it shows the cached last server set first (SharedPreferences key
    `discover_cards_cache_v1`), then refreshes from the server and caches the new set. It sends
    the build number from package_info.
  - The built-in list is used only on first run, when there is no cache and no network.
  - It uses the bn or en copy to match the UI language, and falls back to the other language
    when one is blank.
  - It shows the "Sponsored" and "Our products" labels.
  - In-app routes open through `ChatNav.push`; https links open externally.
  - Impressions (once per card per session on the client; the server dedupes per day) and taps
    are sent fire-and-forget.
  - Unopened-first personalisation is kept, but it reorders only the feature slots. Sponsored
    and product cards stay where the owner put them.
  - The old `/me/plan` and AdMob-placeholder logic is removed. ADMOB cards render nothing.
- **Owner Discover manager** (`lib/screens/admin/discover_manager_screen.dart`). Its tile sits in
  Settings next to the P&L tile, behind the same operator probe.
  - The list supports drag to reorder, enable/disable switches, live/off chips, view, tap and
    CTR stats per card, and Report and Delete with a confirm step.
  - The editor has:
    - a live preview using the real home card widget;
    - type, bn/en titles and descriptions;
    - the action as either an app-screen picker (routes from the server) or an https link;
    - icon, image upload or removal, audience, start/end dates, min build;
    - sponsor name and revenue for SPONSORED cards;
    - the enabled switch.

    Server validation and safety errors are shown in plain language.
  - A preview sheet shows exactly what Free, Premium and Business users get, using the server
    preview endpoint.
  - The sponsor report covers 7, 30 or 90 days, shows totals and a table, and exports CSV or
    PDF through the share sheet.
- **Where Discover appears:** only `home_screen.dart`, inside the welcome state. It is never on
  the SOS, family-alert or safety screens. I checked every place the widget is used.

## Tests
- Backend `core.tests_d1_discover`: 29 tests, OK. They cover:
  - the rules: audience, Premium/Business never get sponsored or AdMob, ADMOB fill, end-date
    expiry, min build, disabled cards, order, labels;
  - the safety rejections, both bn and en;
  - that the seed copy passes the safety check, and that the seed matches the old list;
  - the route-key lock-step with chatnav.dart;
  - tracking dedupe, and that Premium events on sponsored cards are ignored;
  - the report JSON, CSV and PDF;
  - P&L inclusion, and that non-sponsored revenue is zeroed;
  - admin permissions (403 on every admin route for non-owners);
  - image upload to a signed URL, with non-images rejected;
  - end to end: the owner creates a card, the app endpoint returns it, and after the end date
    it is gone.
- Full backend `core` suite: 2532 tests, OK. The "RuntimeError: boom" in the log is the expected output of an existing test.
- Flutter `test/d1_discover_test.dart`: 7 tests pass. They cover:
  - server cards render, the build is sent, the Sponsored label shows, ADMOB is skipped, an
    impression is tracked, and the set is cached;
  - Bangla copy;
  - offline cache;
  - first-run fallback;
  - an empty server list shows nothing;
  - a tap is tracked;
  - the renderable filter.

  Also re-run and passing: `home_keyboard_test`, `assisto_chats_flow_test` and `widget_test`.
- Screenshot gallery entries `discover_mgr`, `discover_edit` and `discover_report` were added,
  and FakeApi got Discover stubs in `test/fake_discover.dart`. They render in bn/en and
  light/dark, and `home_welcome` looks the same as before.
- `flutter analyze` on the changed files shows 0 errors. The only warnings are pre-existing
  ones in settings_screen.dart and fake_api.dart.
- `lang_gate` is clean, `route_check` reports 0 problems, and `makemigrations --check` finds no
  changes.

## ARB
`.phaseB/up_d1_arb.json` has 69 keys (`discoverSponsored` plus `discoverMgr*`), all present in
both en and bn. Three have placeholders, with `@` metadata in en:
- `discoverMgrStats(impressions:int, clicks:int, ctr:String)`
- `discoverMgrDays(days:int)`
- `discoverMgrErrFields(fields:String)`

Apply it with
`python3 ~/assisto/bin/arb_apply.py --app app .phaseB/up_d1_arb.json`, then run gen-l10n.

## Integrator steps
1. Apply the ARB file, then run gen-l10n.
2. Run `migrate` to apply 0049. Renumber it if another slot also took 0049. It creates the
   tables and the seed rows.
3. No cron. The daily aggregates are written live by `/discover/track`.

## Honest limits
- **AdMob is not linked in the app yet.** ADMOB cards can be created and the server applies the
  Free-only, no-sponsor rule, but the app renders nothing for them. The editor says so.
- **The PDF report** labels are in English. A Bangla sponsor name uses whatever glyphs
  reportlab's default font has, so Bangla may not render. The CSV is UTF-8 and complete.
- **Images:** card images use the signed media URL, which lasts 1 to 2 hours. A card cached
  offline for longer falls back to its icon until the next refresh.
- **Click counting:** clicks are counted once per user per card per day, like impressions. CTR
  is therefore unique tappers divided by unique viewers.
- **Not verified on a real device:** the image picker upload and the CSV/PDF share sheet need a
  real device (or CI) check.
