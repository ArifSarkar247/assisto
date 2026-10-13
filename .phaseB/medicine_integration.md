# Medicine module — integrator TODO (agents a34f0b07 build + a4c81fe fix) — REVIEW-PASSED (gaps fixed)

Medicine code is already IN TREE (agents edited core/models.py, serializers.py, views.py, urls.py, tests.py, api.dart, family_screen.dart, medicine_history_screen.dart, both ARBs + generated app_localizations*.dart, fake_api.dart, screenshots_test.dart). Reviewer ae9e598 → GOOD; fix agent a4c81fe addressed all blocking gaps (P1 refill surfaced, P2 edit paths, P3 PDF opens, P4 PRN multi-log, P6 correctness). Self-graded advanced (doctor-edit capable but no doctor-list UI button yet — minor).

## MIGRATION (core app) — run `makemigrations core` (DB BACKUP FIRST):
New models: Doctor(name/specialty/hospital/phone/notes/updated_at); Prescription(member FK null/doctor FK SET_NULL null/doctor_name/date null/diagnosis/meds JSON/notes/created_at).
Medicine += prescription(FK SET_NULL null), food_relation(char default "any"), dose_qty(Decimal 6,2 default 1), as_needed(bool False), duration_days(PosInt null), taper(JSON default []), stock_count(**Decimal 8,2 null** — changed from Int by fix agent), refill_warn_days(PosInt default 5), prn_per_day(PosInt default 0).
MedicineLog += skipped(bool False), at(DateTime null), slot max_length 5→12.

## ARB: already applied by agents to both app_*.arb (60 med* + 6 fix keys = 66) AND hand-edited into app_localizations*.dart. Integrator MUST run `flutter gen-l10n` to regenerate cleanly (overwrites hand-edits; ensure both ARBs have all keys + @placeholder metadata for medPredictedRefill{date} etc).

## api.dart: medicine methods added by agents (medicineTaken(skipped), medicineHistory, caregiverDashboard, medicineEscalation, + doctors/prescriptions via generic listItems/createItem/updateItem).

## Build/verify at integration: gen-l10n → flutter analyze → lang gate → backend tests (incl MedicineScenarioTests + new fix tests) → fix → build → ship APK → cleanup.
