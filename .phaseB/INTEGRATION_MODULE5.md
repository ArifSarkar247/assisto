# MODULE 5 (P13+) BATCHED INTEGRATION — continuation recipe
All 4 modules built+reviewed (no P0). Code fixes running: agent a5978c21 (health emergency_check/set_source/turning_age; life duration_min cast/noon/travel-persist; launch-gaps photo-kind/analytics-fail-closed). DONE (a5978c21): all applied, tests green (health_tips 14, medicine_db 13, birthdays 17). NOTE: launch-gaps ARB now also needs photoKindPersonal/photoKindDocument (SegmentedButton).

## 1. ARB (author/collect [bn,en], then merge into app_en.arb+app_bn.arb, gen-l10n)
- health_arb.json READY (41). 
- Life (~92), Launch-gaps (~45), Connected-Circle (~55, agent gave [EN,BN] → SWAP). GET these via SendMessage to the build agents: Life=a046f0d4, Launch-gaps=a515a717, CC=ac08c7e3 — ask each: "emit the COMPLETE {key:[bn,en]} JSON for all your module's l10n keys to /home/ubuntu/assisto/.phaseB/<module>_arb.json". (They authored the en; have them author bn.) Add placeholder @-meta for {..} keys. gen-l10n.
## 2. api.dart: fold widgets/health_api.dart + scam_safety_api.dart extensions; add reset/analytics/legal/photo/unseen, meetings/dictionary/ramadan/exam, circle* methods (per each .phaseB spec). (Many screens use generics; add named where screens call them.)
## 3. Models (core unless noted) + serializers, then DB BACKUP → makemigrations core → migrate:
Birthday; Appointment; ExamWatcher; PasswordResetToken; AnalyticsEvent; (CircleMember/CircleMessage/CircleInvite/CircleReport). Exact fields in each *_integration.md.
## 4. Endpoints (views+urls, req_lang). CRITICAL CC enforcement (reviewer P1 — MUST wire, pure fns don't self-enforce): POST /circle/<id>/messages calls validate_envelope before persist; report view calls apply_request_event(...,"block") on auto_block; scoped reads gate on circle.can_see server-side; invite token DB single-use. Reset endpoints RATE-LIMITED. analytics fail-closed. photo.plan honors declared kind. Health/Life/Launch endpoints per specs.
## 5. Drawer (sidebar_sections.dart) + ChatNav + screen_synonyms: Health[MedicineDb,HealthTips,Birthdays]; Life[Meetings,Dictionary,RideFood,Ramadan,Exam,Unseen,PhotoEnhance]; Family[Circle]; Settings/About[Legal + login reset link + name-about]. Imports.
## 6. fake_api stubs (all module-5) per specs. Register new standalone gallery screens (health_tips/medicine_db/birthdays/meetings/dictionary/ramadan/exam/circle/legal/photo/unseen) in screenshots_test.dart.
## 7. Fold *_tests_snippets.py into core/tests.py. gen-l10n → flutter analyze 0 → lang gate CLEAN → backend tests (core+crm) → crm_scenario. Fix to green.
## 8. Build+ship APK (flip public→push→build→flip private→publish-apk) → re-render gallery AFTER publish (cleanup deletes screenshots/) → deploy (restart assisto.service) → health 200 + Asalify 12-tenant 200. Commit.
## 9. THEN: P14-P16 leftovers, P11 iOS, P12 FINAL.
