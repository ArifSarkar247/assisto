# Vault + Scam + Family safety — integrator TODO (agent aab2b537) — PENDING REVIEW

Owned files in tree: backend/core/logic/scam.py, safety.py (+ *_tests_snippets 12/13 pass); app/lib/screens/scam_screen.dart, safety_screen.dart; widgets scam_result_card.dart, safety_checkin_card.dart, safety_sos_countdown.dart, vault_doc_types.dart, scam_safety_api.dart; rebuilt vault_screen.dart (+PIN preserved), emergency_screen.dart (SOS→countdown + Safety-tools button).

## ARB: apply .phaseB/vault_scam_safety_arb.json (~70 keys). Placeholder @-meta: scamRiskScore{score}, safetySosCountdownValue{sec}, safetyFallWindowValue{min,sec}, safetyFallPromptBody{sec}, safetyCheckinByTime{time}, safetyCheckinTarget{place,time}, safetyCheckinTargetNoPlace{time}, safetyCheckinOnTime{min}, safetyCheckinOverdue{min}.

## api.dart: fold widgets/scam_safety_api.dart extension into ApiClient: scamDetect(msg)→POST /scam/check; scamLibrary()→GET /scam/library; scamReportFamily(msg)→POST /scam/report; govtGuides()→GET /guides(.services); safetyCheckinStart({place,etaIso})→POST /safety/checkin; safetyCheckinArrived()→POST /safety/checkin/arrived.

## Endpoints (core/views.py + urls.py):
- Rewire ScamCheckView → core.logic.scam.check_message(msg, req_lang) [new contract: patterns[]/summary + keeps label/emoji/advice/score/verdict]. family_screen scam checker reads OLD reasons/label → map patterns[].name→reasons OR leave (non-breaking).
- GET /scam/library → {"patterns": scam.library(lang)}
- POST /scam/report → scam.family_alert_payload(name,result,lang) → enqueue family /alerts
- POST /safety/checkin + /safety/checkin/arrived → SafetyCheckin store; on-poll safety.should_alert_checkin → family alert
- GET /guides already returns guides.localized(lang).

## MIGRATION: none required to ship (vault type fields encoded in Document.note via encode/decodeDetails). OPTIONAL: SafetyCheckin model (user FK, place Char, eta DateTime, arrived Bool, created_at) for checkin endpoints; Document.details JSONField + insurance/warranty TYPES choices (future). Config (SOS countdown, fall) stored client-side SharedPreferences.

## fake_api: scamDetect/scamLibrary/govtGuides/safetyCheckinStart/safetyCheckinArrived/scamReportFamily stubs (both langs) — see agent report.

## Self-grade: vault advanced(9), scam advanced(9), safety advanced(8.5). PENDING premium reviewer.
