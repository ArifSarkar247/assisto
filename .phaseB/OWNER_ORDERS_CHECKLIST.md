# Assisto — OWNER ORDERS RECONCILIATION CHECKLIST

> READ-ONLY reconciliation. No code changed. Written 2026-10-20.
> Sources: `ASSISTO_REPORT.md` (build log through build 139), `owner_actions/STATUS_FOR_OWNER.md`,
> `.phaseB/SPEC_V21_AUDIT.md`, `.phaseB/ENABLE_AUDIT.md`, `.phaseB/PREMIUM_SCORECARD.md`,
> `.phaseB/BUSINESS_MODEL_PLAN.md`, `owner_actions/PREMIUM_FINAL_SUMMARY.md`, `ASSISTO_SPEC_v2.pdf` (v2.1 Final),
> plus live code checks in `app/lib/` cited inline.
>
> Status legend: **DONE (build N)** · **PARTIAL** (built but incomplete / below the Section-21 bar) ·
> **NOT DONE** · **FORGOTTEN** (ordered, no trace, not in any plan) · **KEY-GATED** (logic built, needs owner key) ·
> **PLAN-ONLY** (designed, not yet coded).
>
> Honesty rule applied: where I could not find implementing code/evidence, I marked NOT DONE / FORGOTTEN — not assumed.

---

## 0. THE 6 EXPLICITLY-VERIFIED OWNER ITEMS (live code checked)

| # | Owner item | Status | Evidence (file:line) |
|---|---|---|---|
| V1a | Home: My Circle icon & bell icon in the SWAPPED positions (My Circle far-right corner, bell to its left) | **DONE (build ~137)** | `app/lib/screens/home_screen.dart:156-194` — actions render left→right: Enhance-photo → **Bell (notifications)** → **My Circle (`diversity_3`) at far-right**. Comment at `:156-158` states "OWNER UI FIX: bell to the LEFT, My Circle at the far-right corner (its original place)". Matches owner swap. |
| V1b | Notification (bell) icon opens BOTH Reminders AND Notifications (two options), not only the notification centre | **DONE (build ~137)** | Bell → `NotificationCentreScreen` (`home_screen.dart:170-182`). That screen has TWO tabs: **Reminders** + **Notifications** (`app/lib/screens/notification_centre_screen.dart:17-18,44-64`: `notifTabReminders` / `notifTabNotifications`). Satisfies "both". |
| V2a | Sidebar top "Messages" renamed "My Circle" with NO duplicate | **DONE** | `app/lib/screens/app_drawer.dart:107-113` single ListTile `t.sidebarMyCircle`; ARB `sidebarMyCircle`="My Circle"/"আমার সার্কেল" (`app_en.arb:4510`,`app_bn.arb:3675`). Old "My Circle" sidebar GROUP deleted (`sidebar_sections.dart:97-101,141-144`). No duplicate entry found. |
| V2b | Contacts SUB-sidebar that should be removed | **DONE (removed)** | No Contacts sub-sidebar. `sidebar_sections.dart:321-326` — Contacts is a single-item section; `app_drawer.dart:160-168` renders any 1-item section as a direct tile (not an expandable group). No nested Contacts sidebar exists. |
| V2c | "My Account" renamed "Account & Finance" | **DONE** | ARB `sidebarMoney`="Account & Finance"/"হিসাব ও অর্থ" (`app_en.arb:1178`,`app_bn.arb:847`), used as the My-Account section title `sidebar_sections.dart:169-170`. |
| V2d | Any sidebar label that WRAPS (too long) | **PARTIAL / verify on device** | No `maxLines`/overflow guard on sidebar section titles or item labels (`app_drawer.dart:164-166,186-188,193-197`). Scorecard flagged truncation/clip risks elsewhere (settings "System", money labels). Long BN labels ("হিসাব ও অর্থ", "পরিবার ও নিরাপত্তা") are moderate; no confirmed wrap in code but not explicitly protected. **Verify at 360dp.** |
| V3a | My Circle camera icon actually opens the camera (not a stub) | **DONE** | `app/lib/screens/messenger/messenger_home_screen.dart:134-143` — `_openCamera` pushes the REAL `CameraScreen(identity, members)` (live preview/photo/video). Import `camera/camera_screen.dart:14`. Not a stub. |
| V3b | WhatsApp-style ⋮ overflow menus with extra options inside | **DONE** | Hub ⋮ `messenger_home_screen.dart:243` + dispatch `:145-177` (New group/community/Broadcast/Linked/Starred/Read-all/Settings). Chat ⋮ `circle_chat_screen.dart:1362` + dispatch `:728`. Channel ⋮ `channel_detail_screen.dart:277`. Community ⋮ `community_detail_screen.dart:326,465`. |
| V4 | Version info ONLY in Settings → About | **DONE (build 113)** | `app/lib/screens/settings_screen.dart:361-362` comment: "Version info lives ONLY here, deep in Settings → About … nothing version-related on the home screen, sidebar, or elsewhere." No version/build string found on home or drawer (grep clean). Home frozen at 1.0.103 by design. |
| V5a | Feature tour is non-blocking | **DONE (PARTIAL naming)** | No classic coachmark "feature tour"; first-run onboarding is **skippable + resumable** (`app/lib/screens/onboarding_screen.dart:19,150` Skip→`_finish`; resume dialog `:69-87`). Home "Discover" spotlight is non-blocking swipeable cards (`widgets/home_suggestions.dart:12-15`). Non-blocking ✓. |
| V5b | In-app updater works | **DONE** | `app/lib/updater.dart:18-19,51-63` — checks backend for newer APK, downloads + launches install; non-blocking `_UpdateBanner` on home (`home_screen.dart:236-289`). Builds self-update without re-finding links. |
| V6 | No user-visible "coming soon"/"shortly"/"soon" that shouldn't ship | **PARTIAL** | Most are HONEST key-gated/native-pending states (fall sensor, SMS receiver, vehicle live-tracking, iOS widget). A few are shippable-surface "Coming soon" that look thin: messenger `circleComingSoon` (`app_localizations_en.dart:3810`), `msgrComingSoon` (`:8710`), `msgrSetLinkedDevicesSub`/`msgrSetStarredSub`="Coming soon" (`:11189,11195`), Channels preview (`:9297`), PA `paBriefAiCta`="Enhance with AI (coming soon)" (`:18496`), `businessReportsSoon` (`:5765`). See GAPS. |

---

## 1. HOME / CHAT

| # | Request (short) | Status | Evidence |
|---|---|---|---|
| 1 | Chat-first home (conversation, no utility dashboard) | DONE (build 33) | `home_screen.dart:18-25`; report Part C. |
| 2 | Rule-based agent brain (works without AI key) | DONE | report §Part C; `/agent` endpoint. |
| 3 | Home = ONLY chat; no bottom nav; drawer nav | DONE | `home_screen.dart:18` docstring; `AppDrawer`. |
| 4 | Keyboard never covers input; voice writes into input | DONE (build 139) | STATUS_FOR_OWNER build 139 note 1; `home_screen.dart:144,224`. |
| 5 | Questions get real answers (not silently saved as note) | DONE (build 139) | STATUS build 139 note 2. |
| 6 | Home "Discover" card (app features / Asalify-AXON / ad slot) replaces 4 Q cards | DONE (build 139) | `widgets/home_suggestions.dart:12-15`; STATUS build 139 note 3. |
| 7 | Home frozen at 1.0.103 — never change unless asked | DONE (policy) | MEMORY home-frozen-103; only owner-approved additions (bell swap, enhance-photo). |
| 8 | Home one-tap "Enhance photo" (only approved home add) | DONE (build 137) | `home_screen.dart:162-169`. |
| 9 | Unread/unseen badges on My Circle + bell | DONE | `home_screen.dart:170-194` `HomeBadgeIcon`, `/home/badges`. |

## 2. SIDEBAR / NAV

| # | Request | Status | Evidence |
|---|---|---|---|
| 10 | Grouped collapsible sidebar, remembers open/closed | DONE (build 59/61) | `app_drawer.dart:170-183` ExpansionTile + `_expanded` set. |
| 11 | One module = one place (no duplicate entries) | DONE | `sidebar_sections.dart:127-136` docstring; verified single entries. |
| 12 | Search sidebar by bn/en + synonyms | DONE | `sidebar_sections.dart:516-534` `filter()`. |
| 13 | Every module openable from chat (ChatNav + synonyms) | DONE | `sidebar_sections.dart` synonyms; `screen_synonyms.py` backend. |
| 14 | Top chrome: New chat / My Circle / search | DONE | `app_drawer.dart:86-139`. |
| 15 | Settings holds In-progress / Connected apps / Battery / Legal | DONE (build 61) | report build 61; `app_drawer.dart:204-217`. |
| 16 | Plans & points at bottom of scroll (nothing pinned) | DONE | `app_drawer.dart:212-217`. |
| 17 | Profile card REMOVED from sidebar (Profile not a module) | DONE | `app_drawer.dart:82-85`; `sidebar_sections.dart:317-320`. |
| 18 | Money header → "Account & Finance" / হিসাব ও অর্থ | DONE | ARB `sidebarMoney` (see V2c). |
| 19 | Family + Safety merged into one "Family & Safety" section | DONE | `sidebar_sections.dart:233-236`. |
| 20 | Health info folded into Daily Life (no standalone Health section) | DONE | `sidebar_sections.dart:327-336`. |
| 21 | Documents under Daily Life; Life → Daily Life; Sales CRM → "CRM" | DONE | `sidebar_sections.dart:337`,`:507-509`. |
| 22 | PA Secretary in Work section | DONE (PA core shipped) | `sidebar_sections.dart:497-499` → `PaHubScreen`. |

## 3. MY CIRCLE / MESSENGER

| # | Request | Status | Evidence |
|---|---|---|---|
| 23 | Connected Circle M1 — 1:1 messaging + media | DONE (build 61) | report build 61. |
| 24 | Voice call free / video call Premium (caller-pays, server-gated) | DONE | SPEC_V21_AUDIT §4b; `circle_calls.can_place_call`. |
| 25 | E2E text (X25519+AEAD now, OpenMLS seam; server ciphertext-only) | DONE (software) | report Module 5 CC; `connected_circle_e2e.md`. |
| 26 | Messenger M2 (groups / status / extras) | DONE (build 62+) | report QUEUE item 2; messenger screens present. |
| 27 | Messenger v3 (community / channel / moderation / privacy) | PARTIAL (good, reviewer-pass pending) | SPEC_V21_AUDIT §Messenger #84-97 "good". |
| 28 | Camera icon opens real camera | DONE | V3a. |
| 29 | ⋮ overflow menus (WA-style) | DONE | V3b. |
| 30 | Circle management moved INTO hub (no separate sidebar group) | DONE | `sidebar_sections.dart:97-101`; `app_drawer.dart:103-113`. |
| 31 | Call/voice-note transcription | KEY-GATED | SPEC_V21_AUDIT #92; needs transcription key. |
| 32 | Linked devices / Starred (hub ⋮) fully wired | PARTIAL | screens exist (`linked_devices_screen.dart`,`starred_messages_screen.dart`) but subtitles "Coming soon" (`msgrSetLinkedDevicesSub/StarredSub`). |

## 4. SAFETY / ANTI-THEFT

| # | Request | Status | Evidence |
|---|---|---|---|
| 33 | Safe Journey (19 items, 999/109, duress-PIN, expiring web page) | DONE (build 61) | report build 61 Safe Journey. |
| 34 | SOS + GPS share | DONE (build 31/33) | report Part A. |
| 35 | Accident/fall detect (countdown 30s-10min, "I'm OK", child-sets-for-parent) | PARTIAL | `fall_detect_screen.dart`; native accelerometer NOT wired (ENABLE_AUDIT #25 simulate-only). |
| 36 | Scam alert + scam checker | DONE (advanced) | SPEC_V21_AUDIT #81-82. |
| 37 | Phone Safety Check-up (brand-aware hardening wizard) | DONE (build 130/132) | `phone_safety_screen.dart`; STATUS builds 130,132. |
| 38 | Device record (IMEI/serial/box photo) | DONE (build 130/136) | STATUS builds 130,136. |
| 39 | Stolen-while-unlocked protection (security PIN + delay + freeze; Apple-style) | DONE (build 133) | STATUS build 133; `security_screen.dart`. |
| 40 | Stolen-IMEI registry + used-phone check + sell safely | DONE (build 134) | STATUS build 134; `used_phone_check_screen.dart`,`sell_my_phone_screen.dart`. |
| 41 | "My lost phone" + recovery help (GD/SP letter/evidence PDF) | DONE (build 135) | STATUS build 135; `my_lost_phone_screen.dart`. |
| 42 | IMEI tamper awareness (serial + Luhn + TAC) | DONE (build 136) | STATUS build 136. |
| 43 | My Vehicles (profile + expiry reminders + buyer guide) | DONE (build 131); live GPS NOT DONE | STATUS build 131; `my_vehicles_screen.dart:34` "coming soon" tracking. |
| 44 | Lost/Stolen SMS-command trigger | NOT DONE (native) | ENABLE_AUDIT #22; `lost_stolen_screen.dart:775-784` disabled. |
| 45 | Voice SOS ("Assisto বিপদ" hands-free) | PARTIAL (basic) | SPEC_V21_AUDIT #79; Android opt-in, native trigger thin. |

## 5. MONEY / CRM

| # | Request | Status | Evidence |
|---|---|---|---|
| 46 | My Account: accounts / income-expense (auto SMS parse + manual) | DONE (build 58) | report Round-1 money; `money_parse.py`. |
| 47 | Budgets w/ rollover, loans w/ partial repay, split, trends, net worth, monthly report | DONE (build 58) | report Round-1 money. |
| 48 | CRM backend 404 root cause (`/api/v1/crm` mount) | DONE (deployed) | report OWNER FIXES; journalctl 404 fix. |
| 49 | CRM in-app Sales CRM (Today/leads/pipeline/quotes/forecast, multi-tenant) | DONE (build 59) | report Round-2; CRM #153-166 advanced. |
| 50 | CRM first-run (start/join org) + empty/error states | DONE (build 61) | report build 61. |
| 51 | Fast "log activity + next follow-up" sheet (sales blocker) | DONE (build 123) | STATUS build 123; commit 7a59a54. |
| 52 | CRM follow-up → real local notification + presets | DONE (build 128) | STATUS build 128. |
| 53 | CRM money in Bangla digits (BN mode) | DONE (build 129) | STATUS build 129. |
| 54 | Subscription/bill payment-ladder reminders actually fire | DONE (build 120) | STATUS build 120. |
| 55 | Bill guide full fields + one-tap pay | PARTIAL / KEY-GATED | SPEC_V21_AUDIT #56; payment ladder UI thin, payment partner blocked. |
| 56 | Inbox Superhuman swipe (Done/Snooze) + snooze notification | DONE (build 128) | STATUS build 128. |

## 6. BUSINESS

| # | Request | Status | Evidence |
|---|---|---|---|
| 57 | Business mode: catalog/orders, replies from real catalog only | DONE (P7) | report P7 (44 tests). |
| 58 | Business v2 (khata/cashbox/stock/orders/AI sales/min-price/handoff/reports/multi-shop) | DONE (advanced) | SPEC_V21_AUDIT #141-152. |
| 59 | WhatsApp/Messenger/IG sales + courier | KEY-GATED | ENABLE_AUDIT §B; mock until Meta/courier key. |
| 60 | Supplier & wholesale market (#144) | DONE (build via supplier screen, reviewer 9) | PREMIUM_SCORECARD round-3 "supplier" ship-ready — note: SPEC_V21_AUDIT listed "not built" pre-build; later built. |
| 61 | Demand map (#145) | DONE (demand screen, reviewer 9) | PREMIUM_SCORECARD round-3 "demand"; trade-data live=KEY-GATED. |
| 62 | Asalify-inside business mode | DESIGN-ONLY (by design) | `owner_actions/asalify_business_mode.md`. |

## 7. MONETIZATION

| # | Request | Status | Evidence |
|---|---|---|---|
| 63 | Plans Free / Premium / Business / Probashi / Annual / Founder | DONE (P3) | `core/plans.py`. |
| 64 | Credit ledger + 7-day trial + rewarded-ad credit + waitlist | DONE (P3) | report P3; BUSINESS_MODEL_PLAN §1.2. |
| 65 | v2 pricing: Premium ৳199 (was 149), Business ৳499/999, remove Family | PLAN-ONLY | BUSINESS_MODEL_PLAN step 1; plans.py still 149/299/1999. **Not applied.** |
| 66 | Monthly credit pools (Premium 90 / Business 240, no rollover) | PLAN-ONLY | BUSINESS_MODEL_PLAN §0-2. |
| 67 | Per-action credit cost table + atomic debit (double-spend fix) | PLAN-ONLY / BUG OPEN | BUSINESS_MODEL_PLAN §1.2(b),§2; `consume_credit` non-atomic today. |
| 68 | Ad-funded wallet (free users), app-open ≤1/3h, SOS never gated | PLAN-ONLY | BUSINESS_MODEL_PLAN §3. |
| 69 | Profit-guard (daily, spend ≤60% of 7d rev, auto-downgrade, owner alert) | PLAN-ONLY | BUSINESS_MODEL_PLAN §4. |
| 70 | Storage quota + always-visible meter (WhatsApp model) | PLAN-ONLY | BUSINESS_MODEL_PLAN §5; no quota today (§1.7). |
| 71 | Owner daily P&L dashboard | PARTIAL | `analytics.revenue_by_plan` + owner screen exist; cost side/P&L PLAN-ONLY (§1.6,§7). |
| 72 | Play Billing / bKash / Nagad / SSLCommerz / ekPay wiring | KEY-GATED | ENABLE_AUDIT §B; `plans_screen.dart:105` "billing coming soon". |
| 73 | Admin-editable pricing config store | PLAN-ONLY | BUSINESS_MODEL_PLAN §0 (`PricingConfig` new). |

## 8. AI / VOICE

| # | Request | Status | Evidence |
|---|---|---|---|
| 74 | AI layer v2 (multi-provider, needs-key, budget kill-switch) | DONE (P2) | report P2; `core/ai.py`. |
| 75 | Bangla voice input (locale-aware) | DONE (build 16/122) | report; STATUS build 122 (elderly BN voice). |
| 76 | Elderly Bangla voice command routing | DONE (build 122) | STATUS build 122; commit c03f364. |
| 77 | AI outputs in user's selected language | DONE (Phase A) | report Phase A backend localization. |
| 78 | Watcher engine (RSS/USD-BDT/weather/price) | DONE (P4) | report P4. |
| 79 | Voice commands (song/call/navigate/nearby, never auto-send) | DONE (P5) | report P5. |
| 80 | Voice mode (live conversation) | NOT DONE | SPEC_V21_AUDIT #13 not built. |
| 81 | Own-voice clone | NOT DONE / KEY-GATED | SPEC_V21_AUDIT #14. |
| 82 | Voice mood sensing (on-device) | DONE (basic) | `voice_mood_screen.dart`; ENABLE_AUDIT native note. |
| 83 | AI Personas / profession role-play | KEY-GATED | SPEC_V21_AUDIT #10,#16. |
| 84 | Quick tools (summarise/grammar/translate/tone) | DONE (mock, key-gated polish) | `quick_tools_screen.dart`; ENABLE_AUDIT #17. |
| 85 | Morning brief / night summary | PARTIAL (daily brief built; AI narrative key-gated) | ENABLE_AUDIT #14; weather/news key-gated. |

## 9. PLATFORM / LAUNCH

| # | Request | Status | Evidence |
|---|---|---|---|
| 86 | Android first, all phones, OEM battery guidance, runtime-perm reasons | DONE (P10/build 53) | report P10. |
| 87 | Launch-ANR fix (opens on Realme 9i) | DONE (build 102/103) | STATUS builds 102,103; MEMORY known-good-103. |
| 88 | Language-picker Continue freeze fix | DONE (build 126) | STATUS build 126; `state.dart`. |
| 89 | In-app About screen (version/build/date + copy-for-bug) | DONE (build 113) | STATUS build 113; `settings_screen.dart:361`. |
| 90 | Premium QA sweep (154 screens, 8 personas, ≥9 bar) | DONE (builds 113-124) | PREMIUM_SCORECARD; PREMIUM_FINAL_SUMMARY. |
| 91 | Safe account delete (owner-only, 7-day grace) | DONE (build 138) | STATUS build 138. |
| 92 | Password eye-icon + profile-photo save | DONE (build 137) | STATUS build 137. |
| 93 | iOS-ready (P11) | NOT DONE | report P11 unchecked. |
| 94 | Final gallery + repo PRIVATE + unlock list (P12) | NOT DONE (repo PUBLIC by owner design) | report P12; RESUME note "repo stays PUBLIC". |
| 95 | API 30 (Android 11) CI emulator coverage | PAUSED (owner informed) | STATUS "সিদ্ধান্ত জানাবেন"; API 33 only now. |

## 10. LEGAL / PRIVACY

| # | Request | Status | Evidence |
|---|---|---|---|
| 96 | Legal pages (privacy/terms/health/Play data-safety) DRAFT to review | DONE-DRAFT | report Module 5 launch-gaps; PREMIUM_SCORECARD "legal DRAFT — TO REVIEW BY OWNER". |
| 97 | Name/trademark check for "Assisto" | DONE-DOC | `owner_actions/name_check.md`. |
| 98 | Privacy analytics (own backend, no 3rd-party, D1/7/30 + funnel) | DONE | report Module 5; `analytics.py`. |
| 99 | Password reset/recovery (email now, SMS key-gated, no enumeration) | DONE (build via reset) | `reset.py`; PREMIUM_SCORECARD "password_reset" ship-ready. |
| 100 | "Not medical advice" banners; crisis → helpline | DONE (verify on new health screens) | SPEC_V21_AUDIT §4c. |
| 101 | 18+ gate; no romantic/girlfriend AI | NOT VERIFIED | SPEC_V21_AUDIT §4c "verify age-gate enforced" — no evidence found. |
| 102 | One-click export (PDF/Excel) + delete-all; 24h breach-notify | PARTIAL | export/delete built (feature 21); breach-notify = owner-review process doc. |

## 11. v2.1 BIG BACKLOG (feature matrix — summary rows)

| # | Request | Status | Evidence |
|---|---|---|---|
| 103 | PA Secretary mode (Section 14, 23 items) | PARTIAL (core hub shipped; corporate/star thin) | `pa_hub_screen.dart`; PREMIUM_SCORECARD round-2/3 pa_* screens exist; SPEC_V21_AUDIT listed all-not-built pre-build. |
| 104 | Section 20 "20 more life tasks" (#182-201) | MOSTLY DONE post-audit | PREMIUM_SCORECARD rounds 2-3: mess/split/samity/landlord/staff/doctor/blood/wedding/qurbani/probashi/student/meter/area/farmer/security/trust/enc_backup all have screens. SPEC_V21_AUDIT marked "not built" BEFORE these shipped. |
| 105 | Daily-Life v2.1 (doc scanner, contract, price radar, travel, cost est) | DONE (mock/key-gated) | `doc_scanner_screen.dart`,`contract_analyzer_screen.dart`,`price_radar_screen.dart`,`travel_planner_screen.dart`,`cost_estimator_screen.dart`; ENABLE_AUDIT §A. |
| 106 | Health v2.1 (water/sleep/diet, fitness, timeline, smartwatch) | DONE (smartwatch key-gated) | `wellness_tracker_screen.dart`,`fitness_partner_screen.dart`,`health_timeline_screen.dart`,`smartwatch_screen.dart`. |
| 107 | Task manager (#21) | DONE | `task_manager_screen.dart`. |
| 108 | Saved / bookmarks (#18) | DONE | `saved_items_screen.dart`; `sidebar_sections.dart:164`. |
| 109 | CV builder (persona blocker) | DONE (build 123) | STATUS build 123; commit f2a4a39; `cv_builder_screen.dart`. |
| 110 | Elderly simple mode | PARTIAL (flag/UI) | SPEC_V21_AUDIT #68; `User.elderly_mode`. |
| 111 | Encrypted backup & phone transfer (#197) | DONE | PREMIUM_SCORECARD "enc_backup" 10/10. |
| 112 | Web growth tools (CV/scam/photo/festival) | DONE (live) | report W1-W4. |
| 113 | Daily challenge/quiz (#173) | DONE | `daily_challenges_screen.dart`. |
| 114 | Integrations admin page (29 slugs, encrypted keys) | DONE (P1) | report P1; `core/integrations.py`. |
| 115 | Admin surfaces (users/moderation/analytics/kill-switch/server-swap/update/support) | DONE (build 64) | SPEC_V21_AUDIT #174-181. |
| 116 | Telegram bot builder | KEY-GATED (sandbox) | `bot_builder_sandbox.md`; ENABLE_AUDIT §B. |
| 117 | PA schedule 2nd-edit data corruption | DONE (build 121) | STATUS build 121; commit cb48449. |
| 118 | Reminder wrong-id scheduling bug | DONE (build 118) | STATUS build 118. |
| 119 | Notification-off banner on reminders | DONE (build 119) | STATUS build 119. |

---

## GAPS TO FIX NOW (prioritized — for a single corrective build)

> Ordered by owner-sensitivity. Items 1-6 are the explicitly-flagged owner items.
> NOTE: the 6 flagged UI items are LARGELY ALREADY DONE in code (builds 113-139). The real remaining
> gaps are the "coming soon" leaks, the sidebar-wrap verification, and the un-applied monetization/pricing plan.

**P0 — user-visible "coming soon" that shouldn't ship (item V6):**
1. `app/lib/l10n/app_en.arb` (+ `_bn`) `circleComingSoon`="Coming soon." — trace its on-screen use; if shown as a live tab/panel, replace with real content or an honest key-gated state.
2. `msgrComingSoon` (`app_localizations_en.dart:8710`) and Channels preview `"Channels are coming soon…"` (`:9297`) — messenger surfaces; confirm gated behind an honest "preview" badge, not a dead tab.
3. `msgrSetLinkedDevicesSub`/`msgrSetStarredSub`="Coming soon" (`:11189`,`:11195`) — the Linked-devices and Starred screens EXIST (`linked_devices_screen.dart`, `starred_messages_screen.dart`); the "Coming soon" subtitle is stale/misleading → update subtitle to reflect the real screen.
4. `paBriefAiCta`="Enhance with AI (coming soon)" (`:18496`) and `businessReportsSoon`="Reports are coming soon" (`:5765`) — reword to honest key-gated ("needs AI key") or wire the real path.

**P1 — sidebar label wrap (item V2d):**
5. `app/lib/screens/app_drawer.dart:164-166,186-188,193-197` — section titles and item labels have NO `maxLines`/`overflow` guard. Add `maxLines:1, overflow: ellipsis` (or `softWrap`) and verify "হিসাব ও অর্থ" / "পরিবার ও নিরাপত্তা" at 360dp don't wrap/clip.

**P2 — monetization plan not applied (items 65-73, owner approval pending):**
6. `backend/core/plans.py` — prices still Premium ৳149 / Family ৳299 / Business ৳1999; owner v2 wants Premium ৳199, Business ৳499-999, Family removed. CONFIRM numbers with owner, then apply + migrate Family→Premium (BUSINESS_MODEL_PLAN §1, "smallest first slice").
7. `backend/core/plans.py::consume_credit` — **real double-spend bug**: non-atomic read-modify-write (BUSINESS_MODEL_PLAN §1.2(b)). Make atomic (`select_for_update` + `F()`), never-negative. Fix regardless of pricing decision.

**P3 — verification / safety (items 101, 35, 44):**
8. 18+ age-gate + romantic-AI exclusion (item 101) — SPEC_V21_AUDIT §4c says "verify age-gate enforced"; NO implementing code found → confirm or build.
9. Fall detection native accelerometer (`fall_detect_screen.dart:43` `_sensorAvailable=false`) + Lost/Stolen SMS receiver (`lost_stolen_screen.dart:775-784`) — native, no key; currently honest "coming soon". Decide scope.

**Already-DONE owner items (no action, verification only):** V1a bell/My-Circle swap · V1b bell opens Reminders+Notifications tabs · V2a My-Circle top no-dup · V2b no Contacts sub-sidebar · V2c Account & Finance rename · V3a real camera · V3b ⋮ menus · V4 version only in About · V5a non-blocking onboarding/discover · V5b in-app updater.

---

## বাংলা সারাংশ — সবচেয়ে গুরুত্বপূর্ণ ~২০টি সারি

| অনুরোধ | অবস্থা | বিল্ড / প্রমাণ |
|---|---|---|
| হোমে My Circle ডানে, বেল বামে (swap) | ✅ হয়েছে | `home_screen.dart:156-194` |
| বেল আইকনে Reminders ও Notifications দুটোই | ✅ হয়েছে | `notification_centre_screen.dart:17-64` |
| সাইডবার টপে "My Circle" (ডুপ্লিকেট নেই) | ✅ হয়েছে | `app_drawer.dart:107-113` |
| Contacts সাব-সাইডবার সরানো | ✅ হয়েছে | `sidebar_sections.dart:321-326` |
| "My Account" → "Account & Finance / হিসাব ও অর্থ" | ✅ হয়েছে | `app_en.arb:1178` |
| সাইডবার লেবেল wrap কি না | ⚠️ যাচাই দরকার | `app_drawer.dart:164-197` (overflow গার্ড নেই) |
| My Circle ক্যামেরা আসল ক্যামেরা খোলে | ✅ হয়েছে | `messenger_home_screen.dart:139` |
| WhatsApp-স্টাইল ⋮ মেনু | ✅ হয়েছে | `circle_chat_screen.dart:1362` সহ |
| ভার্সন শুধু Settings → About-এ | ✅ হয়েছে (build 113) | `settings_screen.dart:361` |
| ফিচার-ট্যুর/অনবোর্ডিং non-blocking | ✅ হয়েছে | `onboarding_screen.dart:150` |
| ইন-অ্যাপ আপডেটার কাজ করে | ✅ হয়েছে | `updater.dart:51` |
| "Coming soon" লিক (messenger/PA/business) | ⚠️ ঠিক করুন | `app_localizations_en.dart:8710,11189,18496` |
| Safe Journey + চুরি-প্রতিরোধ মডিউল | ✅ হয়েছে | builds 130-136 |
| Money + CRM (SMS parse, follow-up, BN digit) | ✅ হয়েছে | builds 58,128,129 |
| পারসোনা-ব্লকার (রিমাইন্ডার/PA/ভয়েস/CV) | ✅ হয়েছে | builds 118-123 |
| ভাষা-পিকার Continue ফ্রিজ ফিক্স | ✅ হয়েছে | build 126 |
| v2 দাম (Premium ৳199, Family বাদ) | ⏳ প্ল্যান-only, প্রয়োগ হয়নি | `plans.py` এখনো 149/299 |
| ক্রেডিট double-spend বাগ | ⏳ খোলা বাগ | `plans.py::consume_credit` |
| 18+ গেট / রোমান্টিক-AI বাদ | ❓ যাচাই হয়নি | SPEC_V21_AUDIT §4c |
| iOS (P11) + রিপো প্রাইভেট (P12) | ❌ হয়নি | report P11/P12 |

---

*End of reconciliation. Code untouched. Row count and GAPS list reported separately to the integrator.*
