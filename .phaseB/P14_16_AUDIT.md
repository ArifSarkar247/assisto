# P14–P16 Built-vs-Remaining Audit (READ-ONLY)

Date: 2026-10-14. Source of truth for item defs: ASSISTO_REPORT.md lines ~119–121 + RESUME ANCHOR lines 479–485.
Method: inspected backend/core/logic/*.py + backend/core/*.py (analytics/reset/legal/photo/unseen/nmcheck live at core/ top level, not logic/), models.py, urls.py, views_module5.py, plus app/lib/screens, l10n/app_en.arb, widgets/sidebar_sections.dart + chatnav.dart. No code edited, no migrations/flutter/builds run.

Legend: LOGIC / BACKEND WIRING (model+view+url) / FLUTTER (screen+ARB+nav) / TESTS = y/n.

---

## P14 — New features

| ITEM | LOGIC | BACKEND WIRING | FLUTTER | TESTS | VERDICT |
|---|---|---|---|---|---|
| Birthdays/anniversaries (pre-reminders + wish/card drafts) | done `logic/birthdays.py` | done — `Birthday` model, `BirthdaysView`/`BirthdayDraftsView`/`BirthdayDeleteView`, urls `/birthdays*` | done `birthdays_screen.dart`, 19 ARB keys, nav (Health sec) | y | DONE |
| Meetings/appointments + reminders + 'এখনই বের হন' (Maps 🔑) | done `logic/meetings.py` | done — `Meeting` + `Appointment` models, `MeetingViewSet` + `AppointmentsView`, urls | done `meetings_screen.dart` (415 ln), 12 ARB keys, nav | y | DONE (Maps leave-now is key-gated per spec — OK as-is) |
| Health tips library (DGHS/WHO sourced, never diagnose, emergency→999) | done `logic/health_tips.py` (`disclaimer()`) | done — `HealthTipsView`/`HealthEmergencyView`, urls | done `health_tips_screen.dart`, 12 ARB keys, nav | y | DONE |
| Medicine DB (DGDA-only; never DIMS/MedEx; alt-swap warning) | done `logic/medicine_db.py` (+ `logic/medicine.py` schedule/escalation) | done — `Medicine`/`MedicineLog` models, `MedicineViewSet` + `MedicineDbSearchView`/`MedicineDbLookupView` + taken/escalation/today/history/caregiver/doctor-pdf, urls | done `medicine_db_screen.dart` + `medicine_history_screen.dart`, 17 ARB keys, nav | y | DONE (source/licensing is a DATA constraint — see Safety notes) |
| Accident/fall detect (OFF default; countdown 30s–10min default 2m; loud alarm + vibration + big I'm-OK; timeout→family+location, offer 999; cancellable; elderly mode w/ parent permission) | done `logic/safety.py` (`default_fall_config` enabled=False, `clamp_fall_window` 30–600 default 120, `fall_prompt_phase`) | partial — `User.fall_detect`/`fall_countdown_sec` fields + serializer; config persisted via settings. No dedicated fall-event ingest endpoint (not required — detection is on-device) | partial — `safety_screen.dart` has full CONFIG UI (window/alarm/vibration/preview) + ARB (`safetyFall*`, `accidentFallDetection`); **native sensor NOT wired** (`_sensorAvailable=false`, hardcoded); no live "fall-triggered countdown" runtime screen | y | GAP: native accelerometer/fall sensor plugin + live countdown runtime (loud-alarm+vibration+I'm-OK→timeout→family alert+999). Config/logic complete. NATIVE — mock/key-gate the sensor now. |
| Ride/food (provider deep-links prefilled; in-app booking 🤝) | n/a (pure deep-link UI; `screen_synonyms.py` has ride_food) | n/a (no backend needed) | done `ride_food_screen.dart` (deep-links via launchUrl, in-app booking shown as key-gated), 9 `rideFood*` ARB keys; **nav: chatnav.dart only, NOT in sidebar_sections** | n/a | GAP (minor): add RideFood to sidebar (Life section) for discoverability. Functionally complete. |
| Dictionary bn↔en (open-license; never Bangla Academy; +web tool) | done `logic/dictionary.py` | done — `DictionaryLookupView`, url `/dictionary/lookup` | done `dictionary_screen.dart` (246 ln), 11 ARB keys, nav | y | DONE (open-license is a DATA constraint) |
| Photo enhance (own photos only, never IDs; open-source/CPU or 🔑; +web tool) | done `core/photo.py` (blocks documents/ID fabrication) | done — `PhotoPlanView`, url `/photo/plan` | done `photo_enhance_screen.dart` (241 ln), `photoTitle` ARB, nav (Life sec) | y (in launch_gaps + tests.py) | DONE (actual enhancement engine is key-gated/mock per spec — plan only now) |
| Unseen World travel companion (unseenbangladesh.com + open data) | done `core/unseen.py` (sourced + filterable) | done — `UnseenView`, url `/unseen` | done `unseen_world_screen.dart`, 7 `unseen*` ARB keys, nav | y | DONE |

## P15 — Launch gaps

| ITEM | LOGIC | BACKEND WIRING | FLUTTER | TESTS | VERDICT |
|---|---|---|---|---|---|
| Password reset + recovery (email now; SMS 🔑) | done `core/reset.py` (token hashing, no-enumeration, strength) | done — `PasswordResetToken` model, `ResetRequestView`/`ResetConfirmView`, urls `/auth/reset/request`+`/confirm` | done `password_reset_screen.dart` + `password_reset_confirm_screen.dart`, routed from `login_screen.dart` | y | DONE (SMS channel key-gated per spec; email path complete) |
| Privacy analytics on OUR backend (D1/D7/D30, invites, free→paid funnel; no 3rd-party; owner-admin dashboard) | done `core/analytics.py` (`normalize_event` consent+no-PII, `uid_hash`, `retention`, `invites`, `paid_funnel`, `dashboard`) | done — `AnalyticsEvent` model, `AnalyticsIngestView` + `AnalyticsDashboardView`, urls | **none** — no owner-admin dashboard SCREEN; event ingest from app not confirmed in UI | y | GAP: build owner-admin analytics dashboard Flutter screen (consume `/analytics/dashboard`: D1/D7/D30 + invites + paid funnel) + ARB keys + nav gating (owner only); wire client-side event ingest calls to `/analytics/ingest`. |
| Onboarding <60s wow + parent-linking (child enters parent# → call/SMS/QR; IVR 🔑) | n/a (flow) | done — reuses Circle invite (`CircleInviteView`) + `LinkedDevice` model; no dedicated parent-link endpoint needed | done `onboarding_screen.dart` (397 ln): 3 intro + try-now + `_LinkParentStep` (phone → tel:/sms: invite + copy-link, QR-ready note, IVR noted key-gated); ARB `onbLinkParent*`/`onbParentPhone*` | — | DONE (IVR for feature phones key-gated per spec; QR is noted ready but copy-link used now) |
| Security hardening checklist + pre-launch audit plan + off-server encrypted DB/vault backups plan | n/a (DOCS/PLAN deliverable) | n/a | n/a | n/a | GAP: no written checklist/audit/backup-plan doc exists in repo (searched). Deliverable = a plan doc (vault/E2E/admin/rate-limits/OWASP MASVS + off-server encrypted backup plan). No code. |
| Legal pages (privacy/terms/health-disclaimer/Play data-safety — drafts 'TO REVIEW BY OWNER') | done `core/legal.py` (`PAGES`, `page()`, `index()`, DRAFT_STAMP bn/en both langs) | done — `LegalIndexView` + `LegalPageView`, urls `/legal`+`/legal/<key>` | done `legal_screen.dart` (in-app reader, shows draft/owner-review stamp), `legalTitle`/`legalLastUpdated`/`legalOffline` ARB, reached from `settings_screen.dart` | y | DONE as drafts. CONSTRAINT: content is draft TO BE REVIEWED BY OWNER (not a build gap). |
| 'Assisto' name/trademark check | done `core/nmcheck.py` (`disclaimer()` — explicitly "not legal clearance") | done — `NameAboutView`, url `/name/about` | **none** — not surfaced in any screen (no legal/settings/about link) | y | GAP (minor): expose name/trademark "about" (no-clearance disclaimer) in-app — small screen or settings/legal entry + ARB. Backend ready. |

## P16 — Seasonal

| ITEM | LOGIC | BACKEND WIRING | FLUTTER | TESTS | VERDICT |
|---|---|---|---|---|---|
| Ramadan mode (sehri/iftar times+alarms; wake-parents IVR 🔑; zakat calc; Eid salami/greeting cards) | done `logic/ramadan.py` (`sehri_alarm_time`, `iftar_alert_time`, `zakat`, `sehri_payload`/`iftar_payload`, Eid cards; `WAKE_IVR_AVAILABLE=False`) | done — `RamadanTimesView` + `RamadanEidCardView`, urls `/ramadan/times`+`/ramadan/eid-card` | done `ramadan_screen.dart` (283 ln), 22 `ramadan*` ARB keys (sehri/iftar/zakat/eid), nav (Life sec) | y | DONE (wake-parents IVR key-gated per spec; location times need device geo — already location-driven). Ready before Feb 2027. |
| 'পৌঁছেছি' safe-arrival check-in (no check-in by set time→alert family) | done `logic/safety.py` (`checkin_status`: arrived/on_time/grace/overdue, default grace 15m) | done — `SafetyCheckin` + `FamilyAlert` models, `SafetyCheckinView` (start) + `SafetyCheckinArrivedView`, urls `/safety/checkin`+`/arrived`; overdue surfaced via `/alerts` foreground poll | done — `safety_screen.dart` (set place/time, arrived button) + `widgets/safety_checkin_card.dart`, `safetyCheckin*` ARB | y | DONE |
| Exam-result day (result watcher + share card + traffic-spike plan) | done `logic/exam.py` (`normalise_watcher`, `watcher_phase`, `result_card`, traffic-spike polling note) | done — `ExamWatcher` model, `ExamWatcherView`, url `/exam/watcher` | done `exam_result_screen.dart` (221 ln): watcher + share card via share_plus, 23 `exam*` ARB keys, nav | y | DONE |

---

## GAP SUMMARY (only the items needing a build)

1. **Fall-detect native + runtime** (P14) — logic/config/UI done; missing native sensor plugin + live fall-triggered countdown runtime screen. NATIVE capability → mock/key-gate the sensor now (ship the runtime screen driven by a manual/test trigger; real accelerometer behind the plugin flag `sensor_available`).
2. **Analytics owner-admin dashboard** (P15) — backend fully done; missing Flutter owner-only dashboard screen (D1/D7/D30 + invites + free→paid funnel) + ARB + owner-gated nav, and wiring client event-ingest calls. CONSTRAINT: OUR-backend only, no 3rd-party trackers, no PII (uid is hashed).
3. **Security/backup plan doc** (P15) — no code; a written hardening checklist + pre-launch audit plan + off-server encrypted DB/vault backup plan (OWASP MASVS, rate-limits, vault/E2E/admin). Pure doc deliverable.
4. **Name/trademark "about" surface** (P15, minor) — backend `NameAboutView` done; add a small in-app surface (settings/legal entry) showing the no-legal-clearance disclaimer + ARB.
5. **Ride/food in sidebar** (P14, minor) — screen+chatnav done; add `RideFoodScreen` to `sidebar_sections.dart` Life section for discoverability.

Everything else in P14/P15/P16 is DONE (logic + wiring + screen + ARB + nav + tests).

---

## PRIORITIZED BUILD PLAN (disjoint tasks for the agent fan-out)

The established pipeline = pure-logic agent → backend wiring → Flutter screen (+ARB → merge_arb → integration). Since nearly all logic+wiring already exists, this wave is mostly Flutter + one native + one doc. Partition into 5 disjoint tasks:

**Sub-wave 1 (recommended first — highest value, fully independent):**
- **TASK A — Analytics owner dashboard (Flutter + client ingest).** No backend work (ingest + dashboard endpoints exist). Build `analytics_dashboard_screen.dart` (owner-gated), ARB keys, nav entry under Settings/owner area; add `analytics.ingest` calls at key events (app_open/onboarding_complete/invite/paid). SAFETY: OUR-backend only, NO 3rd-party SDK, consult `analytics.normalize_event` (consent + hashed uid, no PII). No device/native dep.
- **TASK B — Fall-detect native + runtime screen.** Build the live countdown runtime (loud alarm + strong vibration + large 'আমি ঠিক আছি/I'm OK', timeout→family alert + location→offer 999; always cancellable), driven by `logic/safety.fall_prompt_phase`. NATIVE: add sensor plugin behind `sensor_available` flag — **MOCK/key-gate the accelerometer now** (manual/test trigger); elderly-mode fall-set for a parent **requires parent permission** gate. OFF by default, battery disclosure already in config UI.

**Sub-wave 2 (small UI touch-ups, can run alongside 1):**
- **TASK C — Minor Flutter surfaces.** (c1) Add `RideFoodScreen` to sidebar Life section. (c2) Add name/trademark "about" surface (settings/legal entry) consuming `/name/about` + ARB. SAFETY: name-check text must keep the "not legal clearance" disclaimer (from `nmcheck.py`); ride/food = deep-links only, in-app booking stays key-gated/🤝.

**Sub-wave 3 (doc deliverable, independent, no code):**
- **TASK D — Security & backups plan doc.** Write hardening checklist + pre-launch audit plan + off-server encrypted DB/vault backup plan (vault/E2E/admin/rate-limits/OWASP MASVS). Owner-review deliverable, not shipped code.

**Owner action (not an agent task):** Legal pages already shipped as DRAFTS stamped "TO REVIEW BY OWNER" — owner must review/approve content before launch. 'Assisto' trademark result also owner-driven (nmcheck only disclaims).

### Safety/licensing & native/key-gate flags (carry into every agent brief)
- Medicine: DGDA official data or licensed provider ONLY; NEVER copy DIMS/MedEx; every alternative shows 'ডাক্তার/ফার্মাসিস্টের পরামর্শ ছাড়া বদলাবেন না'. (DATA sourcing constraint — logic/UI already done.)
- Dictionary: open/licensed data ONLY; NEVER Bangla Academy. (DATA constraint.)
- Health tips: DGHS/WHO source-named, never diagnose, emergency→999. (Done.)
- Fall detect: OFF by default + battery disclosure; countdown 30s–10min default 2m; loud alarm + strong vibration + large I'm-OK; timeout→chosen family + location→offer 999; always cancellable; child-sets-for-parent (elderly mode) ONLY with parent permission. NATIVE sensor → mock/key-gate now.
- Analytics: OUR backend ONLY, no 3rd-party trackers, no PII (hashed uid), consent-gated. Owner-admin dashboard.
- Legal pages: DRAFTS 'TO REVIEW BY OWNER'.
- KEY-GATED / mock now: Maps leave-now (P14), in-app ride/food booking (P14), photo-AI engine (P14 — plan only), SMS reset channel (P15), IVR parent-link & wake-for-sehri (P15/P16), fall native sensor (P14).
- NATIVE/device capability needed → must be mocked/key-gated now: fall-detect accelerometer (TASK B), IVR telephony, SMS gateway.
