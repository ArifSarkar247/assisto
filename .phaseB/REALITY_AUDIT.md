# REALITY AUDIT — does each feature actually work for a real user?

Owner order (21 Oct): a feature is **DONE only when a real user flow works end to end**. Unit tests are not evidence.

**Status of this document: PROVISIONAL.**
- Every class below comes from a static sweep (code reading + `tools/route_check.py` against Django's real URL resolver) plus local backend round-trip tests.
- **No emulator flow has run yet.** This server has no `/dev/kvm`. The flows run only in `.github/workflows/reality.yml` on GitHub Actions, and that workflow has not been pushed or run yet.
- Every "evidence" cell reads **pending first CI run** until the `reality-evidence` artifact exists.
- After the first run, replace each provisional class with the class from `reality_out/reality_summary.md`.

Classes:
- **A**: fully works now.
- **B**: works, but needs key X; the app shows an honest message.
- **C**: partial, UI only, or broken.
- **D**: not built.

`?` marks a provisional class: no flow screenshot proves it yet. **Owner rule (21 Oct night): an `A?`/`B?` is NOT evidence and must never be reported as A/B. A needs a real end-to-end run (emulator flow or the phone checklist).** The owner's audit found "Contacts on Assisto" (rated A? by code reading) to be a facade: the phonebook was never read and UserPhoneHash rows were never created. It is C until the two-phone test passes.

## How the evidence is produced

| piece | file | what it does |
|---|---|---|
| CI job | `.github/workflows/reality.yml` | Runs on `workflow_dispatch` and nightly at 02:30 BD. Steps: in-runner Django (`settings_ci`, file sqlite, DEBUG off, no keys) → migrate → `seed_reality` → API-33 emulator → `flutter drive` all flows against `http://10.0.2.2:8700` → artifact `reality-evidence`. Job timeout is 100 min; every adb call has a `timeout`. |
| build prep | `tools/reality/replay_android_steps.py` | Replays android.yml's `build-apk` prep steps **verbatim**: create, overlay, pub get, icons, splash, manifest patch, gradle patches. If a step is missing, the job fails. The only extras: integration_test dev deps and debug-only cleartext. |
| flows | `app/integration_test/flows/*.dart` | One `realityFlow` per feature. Each step takes a screenshot. Every HTTP call is recorded with its status. The **round trip is asserted through an independent API client** (the data the UI wrote must come back from the server). |
| sweep | `app/integration_test/flows/sweep_flow.dart` | Opens **every drawer feature** (the builder the drawer itself uses). Records its HTTP calls, statuses and exceptions, and any visible load-failed state. One result row per feature (S001…). |
| results | device `files/reality/results.json` + `shots/*.png`, `reality_*.mp4`, `django.log`, `logcat.txt`, `reality_summary.md` | `tools/reality/summarize.py` turns them into the A/B/C table. It is also posted on the run page. |
| API contract | `tools/route_check.py`, `backend/core/tests_api_contract.py`, proposal `.phaseB/proposals/m2-contract.md` | Checks every client API path against Django's resolver. That includes interpolated paths, `<int>`/`<str>`/`<uuid>` converter shapes, DRF router actions and the HTTP method. **Exit 1 on any miss.** |
| API base override | `app/lib/config.dart` | `--dart-define=REALITY_API_BASE=…` is honoured only when `!kReleaseMode` (a compile-time const). It is **inert in release builds**. |

## Priority flows (hand-written, real round trip)

| section | feature | flow file / id | class (provisional) | evidence | what was fixed | key needed (B) |
|---|---|---|---|---|---|---|
| Start | Language picker (first run) | onboarding_flow.dart / 01_language | A? | pending first CI run | — | |
| Start | Login (seeded phone + password; wrong-password error) | onboarding_flow.dart / 02_login | A? | pending first CI run (seed + `POST /auth/login` 200 verified locally on :8790) | — | |
| Start | Onboarding | onboarding_flow.dart / 03_onboarding | A? | pending first CI run | — | |
| Home | Chat send → saved home session on the server | home_flow.dart / 04_home_chat | B? | pending first CI run (`POST /agent` answered the honest no-key reply locally) | — | ANTHROPIC_API_KEY for real answers |
| Home | Chat restored after app restart | home_flow.dart / 05_home_restore | A? | pending first CI run | — | |
| Home | Sidebar chat history (list + reopen) | home_flow.dart / 06_sidebar_history | A? | pending first CI run | — | |
| Home | Edit the 6 quick buttons (persists across restart) | home_flow.dart / 07_quick_buttons | A? | pending first CI run | — (on-device by design) | |
| Personal | Reminders: NL quick-add + form, synced | personal_flow.dart / 08_reminders | A? | pending first CI run | — | an OS alarm with the app closed → phone checklist 6 |
| Personal | Notes | personal_flow.dart / 09_notes | A? | pending first CI run | — | |
| Personal | To-dos (create + done) | personal_flow.dart / 10_todos | A? | pending first CI run | — | |
| Money | Add expense | personal_flow.dart / 11_money | A? | pending first CI run (seeded account/txns via the API OK) | report export: file was dropped with a fake "exported" (fixed) | |
| Money | Budget | personal_flow.dart / 12_budget | A? | pending first CI run | — | |
| Family | Family members load | family_circle_flow.dart / 13_family | A? (members) | pending first CI run | — | |
| Family | Family accounting tab | — (sweep S024) | A? (fixed, m1) | route_check clean (`/family/accounting/*` built, integer poisha) | — | |
| Safety | SOS countdown → Cancel (nothing sent) | family_circle_flow.dart / 14_sos_countdown | A? | pending first CI run | — | a real SOS → phone checklist 12 |
| Safety | Check-in / arrived / Safe Journey | sweep (S026/S028) | A? (fixed) | route_check now clean for these | **fixed C:** check-in "arrived", journey arrived / respond-OK / duress PIN / places / routines / wellness all used `createItem()` → trailing `/` → **404 on every call**. Failures were swallowed with a fake "arrived" / silent check-in. They now use the real routes and show honest failure messages. | |
| My Circle | E2E message A→B **and** B→A between seeded users | family_circle_flow.dart / 15_circle_message | A? (fixed) | pending first CI run; backend round trip proven by `core.tests_reality` | **fixed C (critical):** (1) `POST /circle/keys` discarded the key, so no peer ever got `public_key` and every chat stopped at "key missing"; (2) a message lived only on the sender's edge, so **the peer never received it**. Keys are now published onto peer edges (and re-published on every open), the recipient reads the mirror edge, the recipient can react, and unread counts include incoming messages. | |
| My Circle | **Calls (voice + video)** | family_circle_flow.dart / 16_circle_call | **C** (owner code audit + q1 seam audit 22 Oct) | no real media yet: flutter_webrtc not in pubspec, `circle_call_screen.dart` carries "SFU/TURN SEAM … integrator adds" + a "dev affordance" connect path | c2-calls building real WebRTC | stays **C until a real two-device test passes: voice AND video, Wi-Fi ↔ mobile data (TURN), app open AND app closed** |
| My Circle | Group chat react / pin / vote / member events | — | A? (fixed, m1) | route_check clean | m1: group URL shapes aligned | |
| My Circle | Messenger TODO(backend) routes (info, clear, two-step, change-number, settings/*, group export/ai, community leave/notifications, circle/chats, community/message-requests) | — | A? (fixed, m1) | route_check clean (all 25 TODO(backend) built; see .phaseB/MESSENGER_ROUTES.md) | — | |
| My Circle | Connection requests list (`GET messenger/request` → 405) | — | A? (fixed, m1) | route_check clean | GET list added | |
| My Circle | Channel discover (`GET channels/discover` missing) | — | A? (fixed, m1) | route_check clean | route built | |
| My Circle | Channel post "Attach photo/video" button is `onPressed: () {}` | — | B (fixed, m1) | no `onPressed: () {}` left in app/lib | button hidden honestly until channel media upload exists | |
| My Circle | **Contacts on Assisto (phonebook match, number search)** | — | **C** (owner audit) | permission stub always true; `_runMatch(const [])`; UserPhoneHash never created; no phone normalisation | agent c1-contacts fixing | contacts plugin + READ_CONTACTS (native build) |
| My Circle | Report a member / mute status | — | A? (fixed) | static | a failed report/mute showed "Reported"/"Muted" anyway (fixed) | |
| My Circle | **Contacts on Assisto** (who of my contacts is on Assisto → Add to My Circle → accept → message/call; find by number) | — (c1-contacts; `core.tests_c1_contacts` + `test/c1_contacts_screen_test.dart`) | **C** (until the two-phone test passes, phone checklist 18ক) | backend round trip proven locally (two accounts: search `+880 1865-052200` / `8801865052200` / `01865052200` all find the user; contacts/match with the device hash finds them; circle request → accept → message delivered → call endpoint allows voice). Widget tests with a fake ContactsSource. **No real phone run yet.** | **fixed facade (c1):** (1) the permission was a stub that always returned true, and the phonebook was never read (`_runMatch(const [])`). (2) `UserPhoneHash` rows were never created, so match and search could never find anyone. (3) Matching was "verified only" while OTP is off, so nobody was matchable. (4) circle/request joined phones by exact string (01… vs +880… never matched). (5) The contract endpoint never sent the match salt, so the device hashed with an empty key. Now: one canonical phone helper (`core/phone.py`, mirrored on the device), hashes are created on register / phone change (signal) and backfilled by migration 0051, admin flag `contacts_match_unverified` (ON for test builds, OFF before launch = OTP-verified only), new `POST messenger/contacts/lookup`, and the WhatsApp-style screen. **Honest limit:** reading the phonebook needs the `flutter_contacts` plugin + READ_CONTACTS in the next native build (`.phaseB/proposals/c1-contacts.md`). Until then the screen says so and offers find-by-number. | native build with READ_CONTACTS; two real phones |
| Business | POS sale → receipt → void | business_flow.dart / 17_pos_sale_void | A? | pending first CI run | — | |
| Business | Product edit / customer save / merchant-QR save | (sweep + `core.tests_reality`) | A? (fixed) | backend tests pass | **fixed C:** all three POSTed to views with **no POST handler (405)**, so the forms never saved; `cost_price` was silently dropped on create (profit wrong) | bKash/Nagad merchant = pointer only |
| Business | Khata party | business_flow.dart / 18_khata | A? | pending first CI run | — | |
| Business | Paper-khata / voice-entry "Confirm & save" | — | A? (fixed: hidden) | static | button only closed the sheet (fake save) → hidden until a real ledger write exists | OCR / speech key |
| Business | CRM org + lead | business_flow.dart / 19_crm_lead | A? | pending first CI run | quote-versions screen called a non-existent route (fixed → `/crm/proposals?lead=`) | |
| Shop Box | Site + camera + end-of-day check | business_flow.dart / 20_shop_box | B? | pending first CI run | — | real camera/NVR or Shop Box phone for alerts/live |
| Daily life | Documents vault | docs_voice_settings_flow.dart / 21_documents | A? | pending first CI run | — | |
| Daily life | AI Inbox | sweep S083 | B (fixed) | static | **fixed C:** filled every real user's inbox with FAKE sample emails (e.g. "bKash: URGENT payment failed"). Now an honest "no inbox connected" state. | mail account key |
| Voice | Voice screen opens; typed fallback answers | docs_voice_settings_flow.dart / 22_voice_screen | B? | pending first CI run; **speech itself cannot run on CI** (no mic / Google speech) | — | phone checklist 19-21 |
| Voice | Home chat "approval" card | — | A? (fixed) | static | Approve / Edit / Cancel buttons were `onPressed: () {}` → now information-only (the backend never sends this type) | |
| Settings | Switch Bangla ↔ English; About | docs_voice_settings_flow.dart / 23_settings_language | A? | pending first CI run | — | |
| Settings | Server-address swap (owner) | — | A? (fixed: hidden) | static | the screen promised the override "takes effect after relaunch", but nothing reads it → tile hidden (`_kServerSwapWired`) | |
| Family | Probashi "schedule a call" reminder | — | A? (fixed) | static | the reminder was saved with field `due` (the model field is `due_at`), so it had **no time**, and a failure claimed success (fixed) | |

## Drawer sweep (every other feature) — flow `99_drawer_sweep`, rows S001…

The class is provisional, from static evidence. The CI sweep replaces it with: did it open, which calls did it make and with which status, did it throw, did it show a load-failed state.

| # | section | feature (drawer label) | screen | provisional class | static evidence | key needed |
|---|---|---|---|---|---|---|
| S001 | Reminders & Memory | Reminders | `reminders_screen.dart` | A? | flow 08; an OS alarm firing with the app closed needs the phone (checklist 6) |  |
| S002 | Reminders & Memory | Birthdays & memorable days | `birthdays_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S003 | Reminders & Memory | Meetings & appointments | `meetings_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S004 | Reminders & Memory | Notes/Tasks | `notes_todos_screen.dart` | A? | flows 09/10 |  |
| S005 | Reminders & Memory | AI knows | `memory_screen.dart` | A? | every client route resolves (route_check) |  |
| S006 | Reminders & Memory | Saved | `saved_items_screen.dart` | A? | every client route resolves (route_check) |  |
| S007 | Account & Finance | Account & Finance | `money_screen.dart` | A? (fixed) | flow 11; fixed: the report export claimed "exported" but dropped the file (now saves + opens the share sheet) |  |
| S008 | Account & Finance | Budget | `money_budget_screen.dart` | A? | flow 12 |  |
| S009 | Account & Finance | Tax & Zakat | `money_tax_screen.dart` | A? | every client route resolves (route_check) |  |
| S010 | Account & Finance | Money Wrapped | `money_wrapped_screen.dart` | A? | every client route resolves (route_check) |  |
| S011 | Account & Finance | Money by voice | `money_voice_screen.dart` | A? | every client route resolves (route_check) |  |
| S012 | Account & Finance | Subscriptions | `subscriptions_screen.dart` | A? | every client route resolves (route_check) |  |
| S013 | Account & Finance | Finance tools | `finance_screen.dart` | A? | every client route resolves (route_check) |  |
| S014 | Account & Finance | Payment Ladder | `payment_ladder_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S015 | Account & Finance | Mess & bachelor accounting | `mess_accounting_screen.dart` | A? | every client route resolves (route_check) |  |
| S016 | Account & Finance | Split expenses | `expense_split_screen.dart` | A? | every client route resolves (route_check) |  |
| S017 | Account & Finance | Samity | `samity_screen.dart` | A? | every client route resolves (route_check) |  |
| S018 | Account & Finance | House rent | `landlord_tenant_screen.dart` | A? | every client route resolves (route_check) |  |
| S019 | Account & Finance | Prepaid meters | `prepaid_meter_screen.dart` | A? | every client route resolves (route_check) |  |
| S020 | Account & Finance | Household staff & driver | `domestic_staff_screen.dart` | A? | every client route resolves (route_check) |  |
| S021 | Account & Finance | Savings challenge | `savings_challenge_screen.dart` | A? | every client route resolves (route_check) |  |
| S022 | Account & Finance | AI spending insights | `spending_advice_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S023 | Account & Finance | Market price radar | `price_radar_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S024 | Family & Safety | Family | `family_screen.dart` | A? (fixed, m1) | family accounting routes built; members tab flow 13 |  |
| S025 | Family & Safety | Nominee access | `nominee_screen.dart` | A? | every client route resolves (route_check) |  |
| S026 | Family & Safety | Safe Journey | `journey_start_screen.dart` | A? (fixed) | fixed: arrived / respond-OK / duress PIN / places / routines / wellness used createItem() -> trailing "/" -> 404; they now POST the real routes. The timeline route is still missing (m1) |  |
| S027 | Family & Safety | Emergency | `emergency_screen.dart` | A? | flow 14 (SOS countdown + cancel); a real SOS needs the phone (checklist 12) |  |
| S028 | Family & Safety | Scam protection | `scam_screen.dart` | A? (fixed) | fixed: "report scam" posted to scam/report/ (404); it now uses the real route |  |
| S029 | Family & Safety | Accident / fall detection | `fall_detect_screen.dart` | B? | native fall sensor not wired; the screen says so honestly | native sensor plugin |
| S030 | Family & Safety | Lost / Stolen Protection | `lost_stolen_screen.dart` | A? (fixed, m1) | journey timeline route built |  |
| S031 | Family & Safety | My lost phone | `my_lost_phone_screen.dart` | A? | every client route resolves (route_check) |  |
| S032 | Family & Safety | Phone Safety Check-up | `phone_safety_screen.dart` | A? | every client route resolves (route_check) |  |
| S033 | Family & Safety | Phone ownership protection | `security_screen.dart` | A? | every client route resolves (route_check) |  |
| S034 | Family & Safety | Sell my phone safely | `sell_my_phone_screen.dart` | A? | every client route resolves (route_check) |  |
| S035 | Family & Safety | Shop Box | `shop_box_screen.dart` | B? | flow 20 (site + camera + EOD); live view / motion need a real camera or Shop Box phone | camera / NVR + Shop Box device |
| S036 | Family & Safety | Disaster alerts | `disaster_alerts_screen.dart` | B? (fixed, m1) | /disaster/feed built; honest state until an official feed source is set | official feed source |
| S037 | Family & Safety | Blood donors | `blood_donor_screen.dart` | A? | every client route resolves (route_check) |  |
| S038 | Family & Safety | School corner | `kid_school_screen.dart` | A? | every client route resolves (route_check) |  |
| S039 | Family & Safety | Doctor appointments | `doctor_serial_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S040 | Contacts | Contacts | `crm_contacts_screen.dart` | A? | every client route resolves (route_check) |  |
| S041 | Daily Life | Assisto Voice | `voice_assistant_screen.dart` | B? | flow 22 (typed fallback); speech can't run on CI | phone mic + Google speech; AI key |
| S042 | Daily Life | Medicine database | `medicine_db_screen.dart` | A? (fixed, m1) | /medicine-db/report built |  |
| S043 | Daily Life | Health tips | `health_tips_screen.dart` | A? | every client route resolves (route_check) |  |
| S044 | Daily Life | Documents | `vault_screen.dart` | A? | flow 21 (record without a file); attaching a file needs the phone (checklist 10) |  |
| S045 | Daily Life | Service guide | `guide_screen.dart` | A? | every client route resolves (route_check) |  |
| S046 | Daily Life | Nearby | `nearby_screen.dart` | B? | curated Dhaka dataset with an honest "mock — live with Maps key" banner (verify the banner in the sweep shot) | Google Maps key + location |
| S047 | Daily Life | Unseen Bangladesh | `unseen_world_screen.dart` | A? | every client route resolves (route_check) |  |
| S048 | Daily Life | Dictionary | `dictionary_screen.dart` | B? | honest needs-data state (open-licence dictionary not wired server-side) | dictionary dataset |
| S049 | Daily Life | Ramadan mode | `ramadan_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S050 | Daily Life | Watch feed | `watch_feed_screen.dart` | A? | every client route resolves (route_check) |  |
| S051 | Daily Life | Exam result | `exam_result_screen.dart` | A? | every client route resolves (route_check) |  |
| S052 | Daily Life | Enhance photo | `photo_enhance_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S053 | Daily Life | Ride & food | `ride_food_screen.dart` | A? | every client route resolves (route_check) |  |
| S054 | Daily Life | Used phone check | `used_phone_check_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S055 | Daily Life | My Vehicles | `my_vehicles_screen.dart` | B? | live tracking honestly marked "coming soon"; no fake map | GPS tracker integration |
| S056 | Daily Life | Student corner | `student_corner_screen.dart` | A? | every client route resolves (route_check) |  |
| S057 | Daily Life | Wedding & events | `wedding_events_screen.dart` | A? | every client route resolves (route_check) |  |
| S058 | Daily Life | Qurbani & Eid planner | `qurbani_screen.dart` | A? | every client route resolves (route_check) |  |
| S059 | Daily Life | Probashi corner | `probashi_screen.dart` | A? | every client route resolves (route_check) |  |
| S060 | Daily Life | Farmer mode | `farmer_mode_screen.dart` | A? | every client route resolves (route_check) |  |
| S061 | Daily Life | Health timeline | `health_timeline_screen.dart` | A? | every client route resolves (route_check) |  |
| S062 | Daily Life | Water, sleep & diet | `wellness_tracker_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S063 | Daily Life | Fitness partner | `fitness_partner_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S064 | Daily Life | Smartwatch & fitness | `smartwatch_screen.dart` | A? | every client route resolves (route_check) |  |
| S065 | Daily Life | Daily challenge | `daily_challenges_screen.dart` | A? | every client route resolves (route_check) |  |
| S066 | Daily Life | Contract analyzer | `contract_analyzer_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S067 | Daily Life | Language partner | `language_partner_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S068 | Daily Life | Daily brief | `daily_brief_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S069 | Daily Life | Document scanner | `doc_scanner_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S070 | Daily Life | Calls & voice notes | `transcription_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S071 | Daily Life | Travel planner | `travel_planner_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S072 | Daily Life | Mood & energy | `voice_mood_screen.dart` | A? | every client route resolves (route_check) |  |
| S073 | Daily Life | Proactive helper | `proactive_ai_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S074 | Daily Life | Area community | `area_community_screen.dart` | A? | every client route resolves (route_check) |  |
| S075 | Work | Agent Studio | `agent_studio_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S076 | Work | Task Manager | `task_manager_screen.dart` | A? | every client route resolves (route_check) |  |
| S077 | Work | Cost & time estimator | `cost_estimator_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S078 | Work | Mock interview | `mock_interview_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S079 | Work | Quick tools | `quick_tools_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S080 | Work | Blog & script writing | `blog_writer_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S081 | Work | Job hunter | `jobs_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S082 | Work | CV Builder | `cv_builder_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S083 | Work | AI Inbox | `inbox_screen.dart` | B (fixed) | fixed: fake sample emails (e.g. "bKash: payment failed") removed; honest "no inbox connected" state | mail account (Gmail/IMAP) key |
| S084 | Work | PA Secretary | `pa_hub_screen.dart` | B? | key-gated/mock path present — verify the honest label in the sweep shot | see screen |
| S085 | Business | Business | `business_screen.dart` | A? (fixed) | flows 17/18; fixed in the backend: product edit (405), customer save (405), merchant-QR save (405), cost_price dropped on create; the paper-khata fake "Confirm & save" is hidden |  |
| S086 | Business | CRM | `crm_home_screen.dart` | A? (fixed) | flow 19; fixed: quote versions called a non-existent route (now /crm/proposals?lead=) |  |

## API contract (`tools/route_check.py`)

- **21 Oct night, build 148 (main b5eb97a): 835 client calls, 732 unique — 731 OK, 1 DYNAMIC (runtime prefix, `api.dart:219`), 0 problems.** `core.tests_api_contract` passes in the 2545-test backend suite. The CI step is in `.phaseB/pending_workflows/android.yml.next` (needs the gh `workflow` scope to push).

Earlier run (before m1 landed):

- **796 client calls, 699 unique: 656 OK, 42 problems.** 40 of them are on m1's list (C → in progress (m1)). The other 2 are messenger rows (see above).
- My fixes cleared **13 more misses** before this run: journey ×7, scam/safety ×3, CRM quote versions, product/customer delete (two unused methods that called dead routes were removed) and where-are-you ×2 (two unused methods that called routes that never existed were removed).
- The contract test (`core.tests_api_contract`) **fails until m1 lands**. The owner asked for exactly that: a client call with no route is a screen that can never work.
- Full list: `python3 tools/route_check.py --report-only --md out.md`.

## Static sweep findings (all fixed unless marked)

| finding | where | class | action |
|---|---|---|---|
| `TODO(backend)` messenger routes (25 comments, 16 routes) | messenger_setapi / group_api / chat_api | C → fixed (m1) | all built; route_check 0 |
| "coming soon" | vehicles tracking, wake word, billing, fall sensor, home widget, msgr settings panel | B (honest label) | none needed; verify in sweep shots |
| no-op `onPressed: () {}` | chat_cards.dart approval card (×3) | C → fixed | information-only card |
| no-op `onPressed: () {}` | channel attach photo/video | C → fixed (m1) | hidden honestly until channel media upload exists |
| fake data shown to real users | inbox_screen.dart `mockInbox()` | C → fixed | honest not-connected state + 3 new ARB keys |
| fake data (labelled) | nearby_data.dart curated places, quick-tools/social/in-chat AI "mock" drafts, meet ETA mock | B? (honest banner/label claimed in code) | verify the banner text in the sweep screenshots; any unlabelled one becomes C |
| errors swallowed → fake success | circle report, status mute, safety check-in start + arrived, safe-arrival arrived, probashi reminder, money report export | C → fixed | honest failure messages (2 new ARB keys + existing `grpActionFailed`) |
| errors swallowed → empty list | connection_requests, msgr_chat_list, community lists, starred, broadcast lists (messenger) | routes now exist (m1); A-with-risk (offline looks empty) | phone checklist |
| backend 405 on app writes | product edit, customer save, merchant QR | C → fixed | POST handlers + `core.tests_reality` |
| unwired setting | server-address swap | C → fixed (hidden) | tile hidden until wired |

## Backend tests added
- `core.tests_reality`: 1:1 delivery + keys, business writes, seed. **8 tests, all OK.**
- `core.tests_api_contract`: **red until m1 lands** (42 problems: 40 on m1's list + 2 messenger rows).
- Full backend suite, 21 Oct: **2415 tests, 1 failure.** The failure is exactly the contract test above.
- Local HTTP check: `settings_ci` + `seed_reality` on :8790. B published a key → A's `/circle/members` returned it. A posted → B's `/circle/2/messages` returned it (`mine:false`). The server was stopped afterwards.

## Seam audit 22 Oct (q1-seams — owner order MYCIRCLE2 item 6)

**Scope.** `app/lib`, `backend` (tests, migrations, `*_snippets.py` excluded), `app/android_overlay`, `edge/`. Patterns: `SEAM`, `integrator adds`, `stub`, `placeholder`, `TODO(`, `dev affordance`, `mock`, `fake`, `dummy`, `not implemented`, `coming soon`, `onPressed: () {}` (and any no-op `on…: (_) {}` callback), `catch (_) {}`, plus a heuristic sweep for "API call in `try`, silent `catch`, success toast right after" (fake success without server confirmation). Calls/RTC (c2-calls) and messenger ticks / chat list / message notifications / bubbles (c3-msg) are **listed, not edited**.

**Classes in this section.** **A** real (a test seam, a documented internal seam, honest cleanup, or a feature name) · **B** honest key-gated / "not available yet" state shown to the user · **C** facade or fake success → **fixed** (wired for real) or **hidden** (entry point removed / honest "not available yet").

### Counts

| pattern | hits in scope | A | B | C → fixed | C → hidden | owned by c2/c3 (listed only) |
|---|---|---|---|---|---|---|
| `SEAM` (case-sensitive) | 55 | 21 (internal doc seams: reminder/points/storage/save-this/server-enforcement) | 32 (key-gated AI/partner/feed/booking seams, honest state) | — | — | 2 (c2: `circle_call_screen.dart` 135, 316) |
| `integrator adds` | 15 | 9 (6 stale comments, 5 corrected: contacts_source, scam_safety_api, crm_common ×2, crm_aftersale_api, crm/webviews) + 3 backend key-registry notes | 3 (supplier_market / price_radar / demand_map: no provider key yet, honest) | — | — | 3 (c2: call_controls, circle_call_screen 32; c3: circle_privacy_controls) |
| `stub` | 21 | 19 (test stubs, gated voice-note transcription, poll bound check, linked-device design data, Kotlin notes) | — | 1 (reports "export stub" claimed PDF/Excel) | 1 (products "Excel import" via a media picker) | — |
| `placeholder` | 135 | 125 (hint texts, skeletons, ARB placeholders, deleted-message placeholder, owner-review prices) | 3 (NEIR registry, merchant-QR icon tile + number text, daily-brief key slots) | 3 (circle invite QR, referral QR, CRM contact "link to Circle" -1 sentinel) | 1 (sticker placeholder tiles, via the extras hub) | 3 (c3: discover QR icon, messenger_home communities, group_menu_media) |
| `TODO(` | 10 (7 are `Todo(`/`editTodo` false positives) | 2 (`TODO(M2)` UX notes) | — | — | 1 (`TODO(excel-import)`) | 1 (c3: group-chat @-picker TODO) |
| `dev affordance` | 1 | — | — | — | — | 1 (c2: `circle_call_screen.dart` 316 fake "connect") |
| `mock` | 517 | 41 (tests, "Mock interview" feature name, sms_gateway test hook) | 476 (deterministic mocks flagged `mock:true` + honest banner: business AI, courier `*-MOCK-*` + `courier_live:false`, payment link `live:false`, quick tools, social, blog, in-chat AI, bday wish, nearby, meet ETA, PA tiers, filing/minutes) | — | — | (c3: circle_chat in-chat AI mock is labelled — B) |
| `fake` / `dummy` | 166 | 166 (test fakes, the safety "fake incoming call" feature, scam-pattern words, CI-only seed users — `seed_reality` refuses a non-CI DB) | — | — | — | — |
| `not implemented` | 0 | — | — | — | — | — |
| `coming soon` | 8 | — | 8 (vehicle live tracking, wake word, billing, fall sensor, home widget, msgr settings panel, SMS-command trigger, backend reason strings) | — | — | — |
| `onPressed: () {}` / no-op callbacks | 2 (`onSticker: (_) {}`, `onGif: (_) {}`) | — | — | — | 2 (extras hub) | — |
| `catch (_) {}` | 196 (163 in scope) | 147 (dispose/cleanup, prefs/cache, plugin probes, permission requests, launchUrl/share, JSON parse fallbacks, best-effort telemetry, list loads that then reload) | — | 13 (see table) | — | 33 (push_*, circle_chat, circle_group_chat, circle_call, messenger/*) |
| fake success (heuristic) | 32 flagged | 18 (already honest: they set `ok=false`/`failed++` and show it) | — | 7 | 3 (scheduled msg, broadcast, extras backup/restore) | 4 (c3 messenger, all already honest) |

**Totals in scope: C = 32 (22 fixed for real + 10 hidden honestly).** Every C has a regression test (below).

### C findings — what was done

| file:line (after fix) | finding | class | action taken | regression test |
|---|---|---|---|---|
| app/lib/screens/journey_live_screen.dart:148 | "I've arrived safely": a failed `/journey/<id>/arrived` was swallowed and the screen still said **arrived safely** and closed — family could still get the overdue alert | C | **fixed**: honest `realityArrivedNotSent`, stays on the live screen | `q1_seams_test.dart` "failed arrived…" |
| app/lib/screens/journey_live_screen.dart:178 | "Stop journey": failure swallowed, screen closed — watchers still saw a live journey | C | **fixed**: `grpActionFailed`, screen stays | "failed stop…" |
| app/lib/screens/journey_live_screen.dart:132 | overdue "I'm OK": failure swallowed — server could escalate while the user thought it was cleared | C | **fixed**: says so; the next overdue tick asks again | (same file, path covered by arrived/stop harness) |
| app/lib/screens/journey_settings_screen.dart:60 | wellness check (parents living alone) save swallowed — switch looked ON while the server never armed it | C | **fixed**: `grpActionFailed` + reload server state | "journey settings: a failed wellness save says so" |
| app/lib/screens/safe_arrival_screen.dart:129 | Safe Arrival check-in start swallowed — local-only check-in, family never alerted when late | C | **fixed**: `realityCheckinNotSent` (same copy as safety_screen) | static (same pattern as safety_screen, already verified) |
| app/lib/screens/safe_arrival_screen.dart:259 | "alert if not home by 9pm" routine added optimistically; failure swallowed — would never alert | C | **fixed**: rolled back + `grpActionFailed` | static |
| app/lib/screens/safe_arrival_screen.dart:171 | duress PIN → silent SOS tried once, failure swallowed | C | **fixed**: 3 quiet retries (2 s / 4 s back-off); the cover screen must stay normal, so nothing is shown | static |
| app/lib/state.dart:315 + app/lib/screens/settings_screen.dart:834 | `AppState.saveProfile` swallowed every error; Settings → Safety fall toggle looked saved | C | **fixed**: returns `bool`; Settings shows `saveFailed` | "AppState.saveProfile reports a failed save" |
| app/lib/widgets/fam_share_section.dart:61-110 | Family **selective sharing** grid never loaded the server's grants — always showed "nothing shared" (privacy: could hide real sharing) | C | **fixed**: loads `GET family/sharing/consent`; load failure shows an error card + retry | "a failed load is shown…" |
| app/lib/widgets/fam_share_section.dart:164 | grant / revoke / revoke-all failures swallowed ("Non-fatal: UI already reflects intent") — a failed **revoke** looked revoked | C | **fixed**: every write re-applies the server answer; failure → `grpActionFailed` + reload | "loads the server grants and a failed toggle says so" |
| app/lib/screens/circle_extras_hub_screen.dart:201 / circle_extras_scheduled_screen.dart:134 | **Scheduled messages**: POST carried no envelope, failure swallowed, then "Message scheduled." — and **no dispatcher exists** (no job ever sends a `ScheduledMessage`) | C | **hidden** from the hub; the screen itself now shows `grpActionFailed` on failure | "chat extras: only real tools…" |
| app/lib/screens/circle_extras_hub_screen.dart:201 / circle_extras_broadcast_screen.dart:70 | **Broadcast list**: hub passed no members and no sealing callback; fallback posted **empty envelopes** to `/circle/broadcast` then said "Sent to N" | C | **hidden**; the fallback now refuses with an honest error instead of posting empty envelopes | same |
| app/lib/screens/circle_extras_hub_screen.dart:201 | **Create backup**: "Backup done (N messages)" without sealing or uploading anything | C | **hidden** (real backup: Settings → encrypted backup screen) | same |
| app/lib/screens/circle_extras_hub_screen.dart:201 | **Restore**: "Restored" without restoring | C | **hidden** | same |
| app/lib/screens/circle_extras_hub_screen.dart:138 | **Export chat**: "Export ready" toast, nothing shared | C | **fixed**: builds the transcript on-device from decrypted messages → OS share sheet; empty chat → `q1ExtrasExportEmpty` | same |
| app/lib/screens/circle_extras_hub_screen.dart:201 | **Stickers/GIF**: `onSticker: (_) {}` / `onGif: (_) {}` — the pick was dropped | C | **hidden** | same |
| app/lib/screens/circle_extras_hub_screen.dart:201 | **Wallpaper/theme** and **view-once by default**: saved to prefs that no chat screen ever reads | C | **hidden** | same |
| app/lib/screens/circle_extras_hub_screen.dart:201 | **Link a device**: snackbar "Scan this code…" with no code and no linking | C | **hidden** (the real flow is messenger → linked devices, c3) | same |
| app/lib/screens/crm_contacts_screen.dart:206 | Contacts → "Link to Circle" stamped a `-1` sentinel the server drops, then toasted "Link to Circle" | C | **fixed**: opens the real My Circle add flow (`M3AddToCircleScreen`, number pre-filled) | static (M3 flow has its own tests in `m3_circle_test.dart`) |
| app/lib/screens/crm_contacts_screen.dart:134 | contact delete: server failure → removed locally + "deleted" → came back on sync | C | **fixed**: `grpActionFailed`, row kept | static |
| app/lib/screens/task_manager_screen.dart:149, 188 | project / task delete: same "drop locally anyway" + "deleted" | C | **fixed**: `grpActionFailed`; project delete reloads the real state | static |
| app/lib/widgets/circle_invite_sheet.dart:239 | "Invite by QR" showed a QR-shaped **icon** nobody can scan (qr_flutter was already bundled) | C | **fixed**: real `QrImageView` of the invite link | "circle invite dialog shows a real QR" |
| app/lib/widgets/ref_share_sheet.dart:156 | referral "Show QR code": same icon | C | **fixed**: real QR | "referral share sheet QR is a real QR" |
| app/lib/screens/business/reports_screen.dart:84 | export menu offered **PDF / Excel** but always shared plain text | C | **fixed**: one honest "Share" (text summary) | "business reports: no PDF/Excel claim" |
| app/lib/screens/business/products_screen.dart:100 | "Import from Excel" used `ImagePicker.pickMedia` — can never pick an .xlsx/.csv | C | **hidden** (`kProductImportPickerWired=false`); proposal: file_picker | "products: the media-picker import is hidden" |
| app/lib/screens/crm/crm_proposal_advanced_screen.dart:343 | quote "acceptance link" = a **relative JSON API path** (`/api/crm/accept/<token>/`), not a page a customer can open | C | **hidden** (`kQuoteAcceptPageWired=false`); proposal 2 | unit assert in `q1_seams_test.dart` |
| backend/crm/views.py:548, 907 + crm/whatsapp.py | with a WhatsApp key connected, a send answered `state:"queued"` → "Message queued for sending" — **nothing ever POSTs it** | C | **fixed**: API reports `draft` + `live_send:false` while `LIVE_SEND_BUILT=False` (1:1 and bulk) | `crm.tests_q1_seams` (3 tests) |
| app/lib/screens/birthdays_screen.dart:164 | optimistic delete; failure swallowed (row silently reappeared) | C | **fixed**: says why | static |
| app/lib/screens/security_checkup_screen.dart:96, 131 | check-up toggle + reset failures swallowed | C | **fixed**: `saveFailed` | static |

### Notable A/B (kept, with why)

| file:line | finding | class | why it is fine |
|---|---|---|---|
| app/lib/screens/camera/camera_send_sheet.dart:107 | "Send to chats" posts caption + `media_gated:true` | B | the sheet shows `camMediaGatedNote` ("for now the caption is sent") before Send |
| app/lib/screens/business/payments_screen.dart:96 | merchant "QR" tile is an icon + the number as text | B | a bKash/Nagad merchant QR needs the provider's official payload; the number is shown in full; link card carries `BizMockBanner` |
| app/lib/screens/business/orders_screen.dart:209, 322 | courier booking `*-MOCK-*` | B | `courier_live:false` → honest banner on the order |
| backend/core/business_views.py:1590 | webhook-send descriptor `mock:false` with a Meta key | A | backend-only descriptor, not used by the app, never claims delivery |
| app/lib/screens/journey_live_screen.dart:76 | battery % for low-battery trigger is always null | A | no UI promises it (no ARB string) — documented seam |
| app/lib/screens/pa/*.dart (`listItems` catch → `[]`) | load failure looks like an empty list | A (risk) | not a fake success; same "offline looks empty" risk as messenger lists (phone checklist) |
| backend/core/logic/circle_extras.py:405 | voice-note transcription "stub" | B | returns `available:false` + bilingual gate reason until a model is present |
| backend/core/management/commands/seed_reality.py:29 | fixed demo password | A | CI-only: refuses any DB that is not the CI sqlite |

### Owned by c2-calls / c3-msg — listed, NOT edited (hand-over)

| file:line | finding | owner | suggested action |
|---|---|---|---|
| app/lib/screens/circle_call_screen.dart:32, 135 | "SFU/TURN SEAM … the integrator adds" — no RTCPeerConnection, no media | **c2** | real flutter_webrtc (order item 0) |
| app/lib/screens/circle_call_screen.dart:316 | "SFU/TURN SEAM (dev affordance)": a connect path with no media | **c2** | remove; honest error if media fails |
| app/lib/screens/circle_call_screen.dart:166 | `catch (_) {}` on call teardown | c2 | fine if teardown-only; verify |
| app/lib/widgets/circle_call_controls.dart:12 | "integrator adds them from the report's ARB JSON" (stale) | c2 | refresh comment |
| app/lib/screens/circle_chat_screen.dart:972 | `_exportChat` toasts `msgrChatExportReady` **before** anything is exported, then opens the extras hub | **c3** | drop the toast (the hub export now really shares) |
| app/lib/screens/circle_chat_screen.dart:241, 903, 1057 | silent `catch (_) {}` | c3 | verify none hides a send/delete failure |
| app/lib/screens/circle_group_list_screen.dart:81 | create group: failure swallowed (silent; reload shows no group) | c3 | `grpActionFailed` on failure |
| app/lib/screens/circle_group_chat_screen.dart:224 | `TODO(M2)` free-text @-mention parsing | c3 | UX only (A) |
| app/lib/screens/circle_group_chat_screen.dart:186, 339, 1393 | silent `catch (_) {}` | c3 | verify |
| app/lib/screens/circle_screen.dart:133 | `/circle/keys` publish failure swallowed (peers can't encrypt to me until a later open re-publishes) | c3 | retry / surface "can't receive messages yet" |
| app/lib/screens/messenger/discover_screen.dart:291 | invite "QR placeholder" icon (not scannable) | c3 | `QrImageView` (as fixed here for circle invite) |
| app/lib/screens/messenger/messenger_home_screen.dart:40 | "Communities — placeholder until the sibling agent…" | c3 | check the tab is real or honest |
| app/lib/widgets/circle_privacy_controls.dart:13 | "integrator adds" ARB note (stale) | c3 | refresh comment |
| app/lib/push/push_service.dart, push_notifier.dart, firebase_push_bridge.dart, push_payload.dart (14 `catch (_) {}`) | message-notification paths swallow errors | c3 (message) / c2 (call push) | each must degrade to "no push" honestly, never drop a visible notification silently |
| app/lib/screens/messenger/*.dart (12 `catch (_) {}`) | contacts/channel_admin/twostep/community | c3 | heuristic found them already honest (`_loadFailed`, revert + reload) — re-verify after c3 |

### Calls

**Calls stay C** until a real two-device test passes: **voice and video, Wi-Fi ↔ mobile data (through TURN), with the app open AND closed** (phone checklist 16). Code-reading evidence today: no media stack at all (see the c2 rows above).

### Checks run for this section

See the q1-seams finish report (analyze, `test/q1_seams_test.dart`, backend `crm.tests_q1_seams` + core suite, lang gate, `route_check --report-only`, `makemigrations --check`).

## NO SHOWPIECES sweep 22 Oct (s2-showpieces — owner round 2, item 4, permanent rule)

**Rule.** Nothing in the app may say "arrives in the next update" / "coming soon" for a feature the user can tap. Either it really works now, or the entry point is hidden until it does. A key-gated feature may stay only when it says plainly what is missing and the owner is the one who can fix it.

**Scope / method.** Every value in `app_en.arb` + `app_bn.arb` was scanned for future-promise phrases (en: next update, coming soon, coming in/here/with, is/are coming, later/future update, later/next version, not in this build/version, in this version yet, arrives in/with/when, will arrive/come, comes later/after, added soon, with an update, needs an update, once added; bn: পরের আপডেট, পরবর্তী আপডেট, ভবিষ্যৎ/ভবিষ্যতের আপডেট, শিগগির আসছে, শীঘ্রই এখানে, আপডেটের সাথে আসবে, এই বিল্ডে, এই সংস্করণে, পরে আসবে/যুক্ত হবে, শিগগির একটি). Then every Dart caller of each hit was read, plus Dart string literals and `coming soon`/`not in this build` comments, plus the related "Available when ___" entry points (disabled switches/locked rows/buttons that only answer "not set up"). Photo Studio (p2-photo), chat header/ticks (t1-ticks), chat list/scroll/send (e2-keys) and badges/notifications (b2-badges) are **listed, not edited**.

**Regression guard.** `app/test/no_showpieces_test.dart`: fails when any en/bn ARB value matches the banned phrases (allow-list = only the 6 handover keys below, which must shrink), when a Dart UI string literal says "coming soon"/"next update", when a removed key comes back, when a hide-until-shipped flag is flipped without the engine, and when the voice settings screen shows the "Hey Assisto" card while not shipped. Updated: `c1_contacts_screen_test.dart` (+1 test: reader refused → honest reason, no Allow loop), `q1_seams_test.dart`, `m1_messenger_menus_test.dart`, `h1_home_test.dart`. Backend: `core.tests` `test_packs_list_endpoint` (+`purchasable` false) and new `test_packs_purchasable_once_provider_connected`.

### Fixed / hidden (this branch)

| where (after fix) | key / what it said | action |
|---|---|---|
| `app/lib/screens/messenger/contacts_screen.dart:806` | `c1PhonebookNextUpdateTitle` "Reading your phonebook arrives in the next update" (+ `…Body` "This version can't read your phonebook yet") — the real reader ships since build 176 | **fixed**: banner now shows only when this phone truly can't open contacts (no reader, or the OS/plugin answered `unavailable` to status/request) with the honest reason `c1PhonebookCantReadTitle/Body` ("Couldn't read contacts on this phone … nothing was read"); the old Allow-button loop on `unavailable` is gone; permission **denied** keeps the existing denied screen + Open settings. Old keys removed. |
| `app/lib/screens/voice_assistant_settings_screen.dart:317` + `app/lib/voice/va_wake.dart:48` | `vaWakeComing` "Coming soon — available once the wake-word key is set up." / `vaWakeEngineMissing` "Not in this app version yet — it arrives with an update." | **hidden**: the whole "Hey Assisto" card is gone until `VaWake.shipped` (const, `--dart-define=ASSISTO_WAKE_WORD=true` or flip in code — for the wake-word branch) **and** the engine/config is really ready on the phone (ready/running/error). `vaWakeComing` removed; `vaWakeEngineMissing` reworded to a present-tense failure ("This phone couldn't start the wake word, so nothing is listening.") for the start-failed snackbar. |
| `voice_assistant_settings_screen.dart:298`, TTS button, `va_onboarding_step.dart:103` | `vaNeedsUpdate` "This needs the next Assisto update on this phone." | **hidden/fixed**: the "Open assistant settings" button is hidden when the native bridge is missing; when the OS refuses to open a settings page the snackbar says `vaSettingsOpenFailed` ("Your phone didn't open that settings page…"). Key removed. |
| `app/lib/screens/journey_settings_screen.dart:243` (deleted `widgets/sos_native_hooks.dart`) | `sosHookGated` "Coming in a later update." chip on 5 rows (power-button, shake, lock-screen tile, widget, background service) | **hidden**: section removed; 12 `sosHook*` keys removed. |
| `app/lib/screens/plans_screen.dart:97` | `plansBillingComingSoon` "Upgrades turn on once billing is connected." — every paid plan's "Choose …" button | **hidden**: no in-app checkout exists, so the Choose button is removed (plans, benefits, current plan, ad/referral earning stay). Key removed. |
| `app/lib/screens/credits_screen.dart` + `app/lib/api.dart:691` + `backend/core/views_build61.py:293` | `creditsNoProviderBody` "…a payment method will be added soon" after tapping a pack | **hidden + server flag**: `/credits/packs` now returns `purchasable` (= `topups_enabled` flag AND a connected payment provider); while false the app shows "No top-up packs are available right now" instead of buy buttons. Value reworded (no "soon") for older servers. |
| `credits_screen.dart` (`_adsReady`) + `app/lib/ads/ads_service.dart:167` | `adNotSetUpBody` "Reward ads will arrive in a future update." | **hidden**: "Watch an ad to earn credits" (free) and the paid opt-in row show only when `AdsService.rewardedAvailable()` (server ads config + usable unit, same `AdRules.decide` the player uses). Value reworded ("No reward ad can play on this phone right now…"). |
| `app/lib/screens/camera/camera_send_sheet.dart:213` + `app/lib/services/circle_media_gate.dart` | `camMediaGatedNote` "Full photo/video delivery arrives when encrypted storage is on; for now the caption is sent." — "Send to chats" posted the caption only | **fixed**: while `kCircleMediaStorageOn` is false the sheet offers one real action — share the actual photo/video file through the phone's share menu (`camShareFile`, `camShareFileSub`, `camCircleTextOnly`, `camShareFailed`); caption-only chat send + status post are hidden. Key removed. |
| `app/lib/screens/circle_status_composer_screen.dart:102` | Photo / Video tabs → `statusMediaGated` "Available when encrypted media storage is enabled." | **hidden**: text-only status composer until media storage ships. |
| `app/lib/screens/fall_detect_screen.dart:26`, `safety_screen.dart:346`, `settings_screen.dart:860`, `widgets/sidebar_sections.dart:254` | `safetyFallSensorGated` "…isn't wired on this device yet — it will work automatically once added." + three "turn on fall detection" switches that detect nothing | **hidden**: `FallDetectScreen.engineShipped` (false) hides the sidebar entry, the Safety and Settings switches and the in-screen enable card. The screen stays reachable only via the internal ChatNav route (CI native tour) with its honest sensor banner + "Simulate a fall". Key removed. |
| `app/lib/screens/lost_stolen_screen.dart` (triggers card) | `lostStolenSmsTriggerSoon` disabled "SMS-command trigger" switch ("coming soon" in code) | **hidden** (+ `lostStolenSmsTrigger`, dead prefs field removed). |
| `lost_stolen_screen.dart:156` | `lostStolenNativeMissing` "…isn't available in this build." | **reworded** (present-tense, rare plugin failure): "This phone couldn't open device protection. Nothing was changed." |
| `app/lib/screens/settings_screen.dart:955` | `hwIosSoon` "…an iOS widget is coming in a later update." (disabled tile) | **hidden** on iOS. Key removed. |
| `app/lib/screens/circle_extras_hub_screen.dart:198` | `q1ExtrasNotYetTitle/Body` "More chat tools are not available yet…" row | **hidden**. Keys removed. |
| `app/lib/screens/messenger/msgr_set_storage_screen.dart:102` | `msgAutoDlNotYet` "…These switches turn on when media arrives." + 4 disabled auto-download switches | **hidden** (section removed until media ships). Key removed. |
| `app/lib/screens/password_reset_screen.dart:156` | locked SMS row (`resetSmsUnavailable`) + locked security-question row (`resetChannelLockedTip` "This option isn't available yet.") | **hidden**: SMS row listed only once the SMS gateway is connected; security-question row removed (no setup flow exists). |
| `app/lib/screens/encrypted_backup_screen.dart:713` | Google Drive card: Connect → `bkCloudNotConfigured` "…isn't enabled yet." | **hidden**; 6 `bkCloud*` keys removed. Local encrypted backup unchanged. |
| `app/lib/chat_vision/chat_photo.dart:242` | `h1OnDeviceUnavailable` "Reading photos on the phone isn't in this app version yet." in every photo answer | **hidden**: the on-device block shows only when an on-device reader exists. Key removed. |
| `app/lib/widgets/circle_extras_backup.dart` | `circleExtrasWebAfterMobile` "A web client comes after Android and iPhone…" | **hidden**. Key removed. |
| `app/lib/screens/wellness_tracker_screen.dart` | `wellPhotoSeam` "Reading a meal from a photo will come later." | **hidden**. Key removed. |
| `app/lib/screens/messenger/m3_add_to_circle_screen.dart:375` | `m3ScanLater` "Scanning a QR code inside Assisto comes in a later update…" | **reworded** to present-tense guidance ("open their QR with your phone's camera app, or ask them to share their link"). |
| `app/lib/screens/shop_box_mode_screen.dart:590` | `shopModeNoScan` "QR scanning isn't available yet — please paste…" | **reworded**: "Paste or type the pairing token shown on the shop phone." |
| `app/lib/screens/jobs_screen.dart:213` | `jobsNoResultsBody` "Jobs will appear here soon." | **reworded**: "No jobs to show right now. Pull down to refresh." |
| `app/lib/widgets/group_menu_media.dart:68` | `grpMediaGated` "Media storage coming" | **reworded**: "Media storage is off". |
| `app/lib/screens/kid_school_screen.dart:448` | `kidReminderNote` "…notification reminders aren't switched on yet." | **reworded** (states what is true). |
| `app/lib/screens/trust_page_screen.dart:108` | `trustE2eBody` "Photos, voice and video will come when encrypted storage is enabled" | **reworded**: "can't be sent in Connected Circle today, so we make no claim about them." |
| unused keys | `msgrUpdatesSoon`, `msgrCommunitiesSoon`, `msgrCallsSoon` ("coming here soon"), `phBatchNote`, `vehiclesTrackingComingSoon`, `securityApproverTodoNote` ("future update"), `circleCallTransportAppOpen/Push/Full` ("arrives when/with") | **removed** (no caller). |

### Kept — honest key-gated, owner can fix (informational notes inside features that work without the key)
`jobsConnectSourceBanner` (sample jobs until an official feed), `nearbyMockBanner` (Maps key), `courierMockNote` (courier key), `otpSmsOffTitle`/`delAcctOtpOff` (SMS gateway), `upNeirNotAvailable`/`upTacUnavailable`/`recStationsUnavailable` (no data source — the screens never guess), `medPushGatedNote` (Firebase), `rideFoodInAppComing`/`ramadanWakeCallComing` ("available when a partner is connected"), the ~40 `*SeamTitle/Body` AI/OCR/STT/booking cards ("connect a key in Integrations"), `phAiGated*`, Agent Studio `studioRanWithAiMock`/`studioAiMockTag` (AI steps labelled mock). None promises a date or an update; none is a tappable dead end on its own. **Follow-up (owner decision):** the app has no generic "which keys are configured" endpoint for normal users (only per-feature configs: `/ads/config`, `/voice/config`, otp status, `/credits/packs.purchasable` now). A small `/app/capabilities` endpoint would let all of these hide for normal users and show "add key in Admin → Integrations" only to the owner.

### Handover — other agents' areas (listed, NOT edited)
| owner | where | text | suggested action |
|---|---|---|---|
| p2-photo | `photo_studio_screen.dart:96-101, 367, 477`, `photo_studio/ps_gate_sheet.dart:67` | `psEnhanceNotInBuild` ("arrives in the next app update"), `psIdentityMissing` ("arrives in the next update"), `psSecureOff` ("arrives in the next update"), `psSinkUnavailable` ("isn't available in this app version yet"), `psGateAdsNotLinked` ("Ads aren't set up in this app version yet") | make real (order 4a-c) or hide; then delete from `_pendingHandover` in `no_showpieces_test.dart` |
| b2-badges | `push/push_settings_screen.dart:73` | `pushSetDeliveryOffBuild` "Not available in this version yet…" | reword to present tense ("Background delivery is off on this phone; Assisto checks when you open it") or hide the row; then delete from `_pendingHandover` |
| b2-badges | `messenger/msgr_set_notifications_screen.dart:84`, `messenger/community_detail_screen.dart:358` | `msgNotifInAppNotYet`, `msgCommunityAlertsNotYet` "Not available yet — …" (disabled switches) | hide the disabled switches |
| e2-keys / t1-ticks (chat) | `circle_chat_screen.dart:911` attach sheet; `widgets/circle_media_viewer.dart:84` | all media kinds answer "available when encrypted media storage is enabled" (`circleMedia*Gated`, `circleMediaSavingSoon`) — My Circle has no blob storage (`core/logic/circle.MEDIA_UNLOCKED` all False) | hide the attach (paperclip) button while `kCircleMediaStorageOn` (`lib/services/circle_media_gate.dart`) is false, or build blob storage |
| e2-keys / t1-ticks (chat) | `circle_chat_screen.dart:1304-1344` | `msgrChatAiMock` "This is a sample result — Assisto AI is not yet enabled for this chat." | hide the in-chat AI helper until an AI key is configured |
| e2-keys (chat list) | `messenger/messenger_home_screen.dart:532` | `msgrComingSoon` "Preview" title on the keys-not-ready placeholder | use a plain title (the body already explains) |
| e2-keys (chat list) | `channel_list_screen.dart:189,208`, `channel_detail_screen.dart:339,382`, `discover_screen.dart:229` | `channelsBackendSoon` "Channels are in preview for now." | hide the Channels tab/Discover until `backend_ready` |
| e2-keys (composer) | `widgets/circle_extras_stickers.dart:136,147` | sticker/GIF "available when … enabled / owner adds a Tenor key" | already hidden from the extras hub (q1); hide in composer too if reachable |
