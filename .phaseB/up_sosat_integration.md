# sosat — Family SOS (#4) + Anti-theft (#8) integration notes

* ARB: `.phaseB/up_sosat_arb.json` (86 keys, prefix `sa*`, `{en:{...,"@k"},bn:{...}}`) — `bin/arb_apply.py --app app .phaseB/up_sosat_arb.json`.
* Migration: `backend/core/migrations/0123_sosat.py` (AlterField AntiTheftEvent.kind choices + FamilyAlertDelivery.rerung_at). Additive; depends on 0122_kidswatch.
* No new cron: the SOS re-ring runs inside `family_alerts.sweep` (journey_sweep, every minute); held falls escalate in `antitheft_escalate` (every minute, existing line) + the in-process timer + every ingest.
* New endpoints: GET `family/sos/ladder`, GET `family/fall/pending`, POST `family/fall/ok`. Engine ingest accepts `sos_lockscreen`, `sos_power`, `fall`, `fall_ok`.
* Native: `antitheft/SafetyTriggers.kt` (new) + small hooks in `AntiTheftService.kt` / `AntiTheftChannel.kt`. Nothing at launch; only inside the running opt-in protection service. Needs the daily APK build + API-33 launch smoke before publish (Kotlin is NOT compiled by checks.yml).
* Flag: `fall_detect` stays OFF (registry default false) — `FallDetectScreen.engineShipped` is now true, so the sidebar entry appears only when the owner flips the flag. The "More ways to send SOS" screen (Safety → tile) shows lock-screen + power rows always, the fall row only with the flag.
* Removed: `widgets/fall_alarm_overlay.dart` (the old local-only simulation), Safety screen's duplicate "quick-call SOS" button.
* Tests: `backend/core/tests_sosat.py`; `app/test/sosat_test.dart`, `sosat_logic_test.dart`, `sosat_fall_harness_test.dart`, `sosat_snatch_harness_test.dart`, `sosat_shots_test.dart`; traces `app/test/fixtures/sensor_traces/` (synthetic, `tools/sensor_traces/gen_synthetic.py`).
