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

`?` marks a provisional class: no flow screenshot proves it yet.

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
| My Circle | Call screen opens / hangs up | family_circle_flow.dart / 16_circle_call | B? | pending first CI run | — | TURN_STATIC_SECRET + FCM + second phone (checklist 16) |
| My Circle | Group chat react / pin / vote / member events | — | A? (fixed, m1) | route_check clean | m1: group URL shapes aligned | |
| My Circle | Messenger TODO(backend) routes (info, clear, two-step, change-number, settings/*, group export/ai, community leave/notifications, circle/chats, community/message-requests) | — | A? (fixed, m1) | route_check clean (all 25 TODO(backend) built; see .phaseB/MESSENGER_ROUTES.md) | — | |
| My Circle | Connection requests list (`GET messenger/request` → 405) | — | A? (fixed, m1) | route_check clean | GET list added | |
| My Circle | Channel discover (`GET channels/discover` missing) | — | A? (fixed, m1) | route_check clean | route built | |
| My Circle | Channel post "Attach photo/video" button is `onPressed: () {}` | — | B (fixed, m1) | no `onPressed: () {}` left in app/lib | button hidden honestly until channel media upload exists | |
| My Circle | Report a member / mute status | — | A? (fixed) | static | a failed report/mute showed "Reported"/"Muted" anyway (fixed) | |
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
