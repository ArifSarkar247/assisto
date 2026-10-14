# Ramadan mode (GOOD → ADVANCED) — integration notes

SPEC v2.1 §21 (Life module-5, item "Religious times & zakat / Ramadan"). Upgrades
`RamadanScreen` from a location-based prayer-time + alarm + zakat-link + eid-card
screen into a full Ramadan companion. No invented religious content; every money
amount is user-entered; prayer-time method and dua sources are stated.

## Files changed / created
| File | What |
| --- | --- |
| `app/lib/screens/ramadan_screen.dart` | Composes the new widgets; inline zakat replaces the old snackbar-only zakat tile; adds live countdown above the times. |
| `app/lib/widgets/ramadan_countdown.dart` | NEW. Live ticking Sehri/Iftar countdown (1 s timer); shows the sooner event large + both mini. Mirrors `ramadan.minutes_until`. `dart:ui FontFeature` for tabular digits. |
| `app/lib/widgets/ramadan_calendar.dart` | NEW. 30-day Ramadan calendar; start date user-picked + persisted (SharedPreferences `ramadan_start_date`); "day N of 30" highlight. Mirrors `ramadan.ramadan_calendar`. Bangla digits via codepoints. |
| `app/lib/widgets/ramadan_zakat.dart` | NEW. Inline zakat calculator: cash/gold-value/silver-value/investments/debts/nisab inputs → 2.5% of wealth at/above nisab. Mirrors `ramadan.zakat` / `finance.zakat`. Nisab weights (87.48 g / 612.36 g) shown as a reference; prices are user-entered. |
| `app/lib/widgets/ramadan_fasting_tracker.dart` | NEW. Tap days fasted; count /30; persisted (`ramadan_fasts_kept`). Mirrors `ramadan.fasting_stats`. User-marked only. |
| `app/lib/widgets/ramadan_salami_tracker.dart` | NEW. Eid salami (eidi) given/received log; given/received/net totals; persisted (`ramadan_salami_log`). Mirrors `ramadan.salami_tracker_total`. Amounts user-entered — no money moved. |
| `app/lib/widgets/ramadan_duas.dart` | NEW. 3 source-noted authentic duas; Arabic verbatim as data (RTL), meaning + hadith source localized. Mirrors `ramadan.DUAS`. |
| `backend/core/logic/ramadan.py` | Added `ramadan_calendar`, `minutes_until`, `nisab_value`, `fasting_stats`, `salami_tracker_total`, `DUAS` + `duas()`. All pure, no AI. |
| `backend/core/logic/ramadan_tests_snippets.py` | +6 plain-assert tests (15 total, all pass). Registered via existing `RamadanSnippetTests`. |
| `.phaseB/up_ramadan_arb.json` | NEW. 41 ARB keys `{key:[bn,en]}` for the new UI strings. |

## Deliberately NOT touched (per scope)
`api.dart`, `app_en.arb` / `app_bn.arb` (strings emitted to `up_ramadan_arb.json`
for the phase-B merge instead), models, `urls.py`, `views_module5.py`, sidebar,
any other screen/module, Asalify. No flutter/build/migrations run.

## ARB merge (phase B)
Merge the 41 keys from `up_ramadan_arb.json` into `app_en.arb` (value `[1]`) and
`app_bn.arb` (value `[0]`), copy the existing `@`-metadata pattern for the four
placeholder keys (`ramadanDayOf {day}{total}`, `ramadanFastingCount {kept}{total}`,
`ramadanZakatZakatable {amount}`, `ramadanZakatDue {amount}`), then regenerate
`app_localizations*.dart`. The `.dart` already references the getters (same
pattern as the shipped Watch upgrade).

## Honesty / accuracy guarantees
- **Prayer-time method STATED**: times come from the existing backend
  `prayer_times` (NOAA solar position; Karachi 18/18 default) and the UI keeps the
  `ramadanMethodNote` ("astronomical estimate — local committee times may differ").
- **Zakat = 2.5% + nisab gate**: client math mirrors `finance.zakat` exactly;
  below-nisab shows zero due. Nisab is user-entered (classical 87.48 g / 612.36 g
  weights cited as reference; bullion prices never guessed).
- **IVR wake-for-sehri is KEY-GATED**: unchanged `_wakeIvrAvailable = false` + the
  honest "available when a telephony partner is connected" note; no fake call.
- **Duas SOURCE-NOTED**: each dua shows its hadith collection reference (Abi Dawud
  2454 / 2357, Tirmidhi 3513); presented as a reference, not a ruling.
- **No invented data**: calendar start, fasts, salami amounts are all user-entered
  and persisted locally; nothing auto-filled.
- **Zero Bangla glyphs in `.dart`** (digits via U+09E6 codepoints); Arabic duas
  live only as data in `ramadan_duas.dart`.

## Section-21 feature coverage (all 10)
1. Location-based Sehri/Iftar — existing times section (method noted).
2. Sehri + Iftar countdown — `ramadan_countdown.dart`.
3. Prayer times (5 waqt) — existing Fajr/Dhuhr/Asr/Maghrib/Isha rows.
4. Ramadan calendar (day N of 30) — `ramadan_calendar.dart`.
5. Wake-for-Sehri alarm (reuse reminders; IVR key-gated) — existing alarm
   sliders + key-gated IVR note.
6. Zakat calculator (nisab, 2.5%, assets input) — `ramadan_zakat.dart`.
7. Eid salami tracker — `ramadan_salami_tracker.dart`.
8. Eid greeting cards (reuse festival cards) — existing `LifeEidCard`.
9. Fasting tracker — `ramadan_fasting_tracker.dart`.
10. Duas (source-noted, authentic) — `ramadan_duas.dart`.
