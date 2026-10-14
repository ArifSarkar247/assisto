# Disaster alerts — ADVANCED (SPEC v2.1 §21 / Appendix-A #44) — integrator notes

Upgrades DISASTER ALERTS from **good (watch line)** → **ADVANCED**. BD-specific
weather & disaster warnings: **cyclone** (BMD signal number), **flood** (FFWC
level vs danger level), **heatwave** (BMD band / heat index) and **earthquake**
awareness. Standalone screen — it does NOT live in the Watch Feed.

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/disaster_alerts_screen.dart` | **NEW.** The advanced screen: key-gated live-feed banner, active-warnings-by-area (or clearly-flagged samples), family-location-aware section, safety-steps library, preparedness checklist, 999/1090 contacts. Honest loading / error / empty / no-key states. |
| `app/lib/widgets/disaster_model.dart` | **NEW.** Bilingual-free model (**zero Bangla glyphs** — all strings via ARB getters), `dNum` Bangla digits, severity/kind enums + ARB label dispatchers, and pure client mirrors of `disaster.py` (`dCycloneSeverity`, `dFloodSeverity`, `dHeatSeverity`, `dAreaMatches`). `DisasterWarning.fromMap` parses server feed items. |
| `app/lib/widgets/disaster_warning_card.dart` | **NEW.** One warning: severity by colour **AND** label **AND** icon (never colour alone), area, metric chip (signal no. / m above DL / °C), source line, explicit **"example — not a live warning"** badge for samples, what-to-do + share actions. |
| `app/lib/widgets/disaster_safety_sheet.dart` | **NEW.** Source-noted per-kind "what to do" steps sheet; always ends with "not a guarantee of safety · call 999". |
| `backend/core/logic/disaster.py` | **NEW (optional per task).** Pure, deterministic BD disaster logic: hotline constants (999/1090), severity bands, cyclone-signal/flood-level/heat/quake classifiers, `heat_index_c`, per-kind `safety_steps`, `preparedness_checklist`, `emergency_contacts`, `active_warnings` (feed classifier — **never fabricates**), `feed_state` (key-gated), `sample_warnings` (flagged `sample=True`/`is_live=False`), `area_matches`/`affected_family` (family-location-aware, reuses circle), `warning_share_text`. |
| `backend/core/logic/disaster_tests_snippets.py` | **NEW. 18 plain-assert tests.** `run_all()` passes. Cover every severity band, feed-state key-gating, "no feed → no warnings", sample honesty, family matching, share text. |
| `.phaseB/up_disaster_arb.json` | **NEW. 92 ARB keys** `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `app_*.arb` (keys emitted to
> `up_disaster_arb.json`), `api.dart`, `core/models.py`, `urls`, sidebar,
> `watch_feed_screen.dart`/`watch_feed.py`, other screens/widgets. No
> flutter/build/migrations run. No Asalify touched.
> `dart analyze` on the 4 new app files: the ONLY issues are the expected
> "undefined `AppLocalizations.dis*`" getters (they live in the ARB json until
> merged) — zero other errors/warnings/infos.

## To wire this up (integrator)
1. **Merge ARB:** fold `up_disaster_arb.json` into `app/lib/l10n/app_bn.arb` +
   `app_en.arb` (`{"key": "bn"/"en"}` per locale), regenerate
   `AppLocalizations`. That clears every analyzer error.
2. **Route + sidebar:** add `'disaster'` → `DisasterAlertsScreen()` to
   `ChatNav.routes` and a drawer entry; add chat synonyms (`disaster alerts`,
   `cyclone`, `flood warning`, `weather warning`).
3. **Official feed endpoint (🔑 KEY-GATED):** the screen soft-fetches
   `GET /disaster/feed` via the existing `api.getJson`. It expects:
   ```json
   { "feed_state": "no_key|empty|active",
     "warnings": [ { "kind":"cyclone|flood|heat|earthquake",
                     "area":"...", "title":"...", "text":"...",
                     "severity":"advisory|warning|severe|extreme",
                     "signal":7, "above_danger_m":0.6, "temp_c":40.5,
                     "source":"BMD|FFWC|DDM", "is_live":true, "sample":false } ] }
   ```
   Build it server-side from `disaster.active_warnings(official_feed_items)` +
   `disaster.feed_state(has_key, items)`. With **no official-feed key** return
   `feed_state:"no_key"` and the app shows the honest "connect official feed"
   banner + clearly-badged sample examples. **Never** emit a fabricated active
   warning. Until the route exists the app falls back to exactly that no-key
   state (soft-fail), so nothing breaks.
4. **Family-location-aware** reuses the existing `api.listItems('family')` list;
   the screen reads each member's `area`/`district`/`city` and matches it
   against live warning areas with `dAreaMatches` (mirror of
   `disaster.area_matches`). No new audience/contacts. Server mirror:
   `disaster.affected_family(circle_members, warnings)`.
5. **Watch feed / reminders / chat / voice** (§21 #6): optionally surface a
   top active warning as a `watch_feed` signal — the server can emit a
   `{"kind":"disaster", "severity":..., "title":...}` signal into the existing
   `build_feed` (watch_feed.py already handles unknown-kind sorting). Not wired
   here to respect the "don't edit watch_feed" constraint.

## HONESTY GUARANTEES (acceptance)
- **Official sources only:** every card/step/checklist is source-noted —
  **BMD** (cyclone signals, heat/weather), **FFWC** (flood levels), **DDM /
  BDRCS** (preparedness, safety steps). No source is invented.
- **Never fabricate a warning:** `active_warnings()` returns ONLY items from the
  official feed; no feed → `[]`. Sample content is always `sample=true` /
  `is_live=false` and badged "example — not a live warning".
- **Live feed is 🔑 key-gated:** `feed_state` returns `no_key` without a key; the
  UI shows "connect official feed" + samples, never a live-looking alert.
- **Hotlines:** 999 (national emergency) + **1090** (toll-free disaster/weather
  warning) are shown, dialable, and repeated in the checklist + share text.

## §21 ten-point coverage
1. **vs best-in-class** (e.g. BMD/বিপদ, Google crisis cards) — equal/better: BD
   signal/level semantics + family-area awareness + bilingual + offline library.
2. **Full flow** — view active/sample warnings, open per-kind steps, share a
   warning, dial hotlines, browse the full safety library + checklist.
3. **Both rails** — auto (official feed classifier) + manual (always-available
   offline safety library / checklist / contacts); every feed item is an
   official-source entry (the "AI-captured" analogue = source badge).
4. **Empty / loading / tool / offline / no-key states** all designed (skeleton,
   error retry, empty "no active warnings", no-key "connect feed").
5. **bn/en, light/dark, small/large** — all strings ARB-backed; severity uses
   colour + icon + label (WCAG), `Wrap` chips reflow on small screens.
6. **Reminders + watch feed + chat + voice** — deep-links into `family`;
   watch-feed/chat/voice hooks documented above (route + synonyms in step 2).
7. **Server + app tests** — `disaster_tests_snippets.py` (18) incl. scenario
   tests (family in a cyclone+heat situation, key-gating, no-fabrication).
8. **Share card** — `warning_share_text` / in-app share, honest about sample.
9. **Privacy + consent + audit** — reuses circle members already consented in
   the family module; the feed fetch is read-only; integrator logs the feed
   connect/consent in the existing audit path.
10. **Independent review** — owner gate before it counts as advanced.
