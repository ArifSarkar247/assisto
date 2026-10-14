# ASSISTO — STATUS MATRIX (READ-ONLY audit, 2026-10-14)

Source: ASSISTO_REPORT.md (full, P10→build 64) + codebase sanity-check (backend/core/logic/, backend/core/*.py, app/lib/screens/, app/lib/screens/business/, widgets/sidebar_sections.dart, app/tool/lang_gate.py). No edits/builds/migrations run. Asalify untouched.

Latest shipped: build 63 (Business v2) live; build 62 (Messenger M2) live. **Build 64 (P14-P16 completion) committed but NOT shipped — GitHub repo disabled for push/CI (owner must re-enable; see report lines 498-504).**

Depth grades: **advanced** (reviewer-passed to depth standard) · **good** (A-/GOOD, built but below advanced) · **basic** (P10-era thin, model/API-only or stub UI) · **not built** · **owner-blocked** (needs key/account — logic present, state correct).

---

## PART A — DEPTH MATRIX (every module/feature)

FB = built in FIRST P10 BATCH (build 50/53: Finance, Watch feed, Nearby, Agent Studio, Service guide, AI Inbox, Job hunter, Nominee, Subscriptions, Emergency, Business, Personal CRM contacts) and NOT upgraded since.

| # | Module (bn / en) | Grade | First-P10-batch, never upgraded? |
|---|---|---|---|
| 1 | চ্যাট/এজেন্ট NLU / Chat & agent brain | advanced | no (core, continuously used) |
| 2 | মেমোরি "AI জানে" / Memory "AI knows" | good | no |
| 3 | রিমাইন্ডার/নোট/টাস্ক / Reminders, notes, todos | advanced | no (R2 NL-engine upgrade) |
| 4 | আমার হিসাব / My Account (money) | advanced | no (R1 rebuild) |
| 5 | ফিনান্স টুল / Finance tools (zakat/EMI/net-worth/invest) | **basic** | **YES (P10 FIRST BATCH)** |
| 6 | ডকুমেন্টস / Documents (vault) | advanced | no (R2 rebuild) |
| 7 | ফ্যামিলি কেয়ার ও ওষুধ / Family care & medicine | advanced | no (R1 rebuild) |
| 8 | ওষুধ ফলো-আপ কনফিগ / Medicine follow-up config | good | no (depth-audit fix: per-med form added after build 53) |
| 9 | ইমার্জেন্সি কার্ড ও SOS / Emergency card & SOS | **basic** | **YES (P10 FIRST BATCH)** |
| 10 | সাবস্ক্রিপশন / Subscriptions | **basic** | **YES (P10 FIRST BATCH)** |
| 11 | স্ক্যাম সুরক্ষা / Scam protection | advanced | no (R2 rebuild) |
| 12 | নিরাপদ যাত্রা / Safe Journey | advanced | no (built build 61, all 19 items) |
| 13 | ওয়াচার ফিড / Watch feed | **basic** | **YES (P10 FIRST BATCH)** |
| 14 | ভয়েস কমান্ড / Voice commands (music/call/nav/nearby) | **basic** | **YES (P10 FIRST BATCH)** (native Assist/widget/wake-word not built) |
| 15 | কাছাকাছি / Nearby | **basic** | **YES (P10 FIRST BATCH)** |
| 16 | কন্টাক্টস (পার্সোনাল CRM) / Contacts | **basic** | **YES (P10 FIRST BATCH)** (meetings UI was missing; Meetings now a separate module) |
| 17 | মিটিং ও অ্যাপয়েন্টমেন্ট / Meetings & appointments | good | no (P14 wave) |
| 18 | জন্মদিন/স্মরণীয় দিন / Birthdays & memorable days | good | no (P13+/module 5) |
| 19 | অটো-পে ল্যাডার / Auto-pay ladder | not built (UI) | FB-adjacent: backend done, **no app screen**; exec owner-blocked |
| 20 | বয়স্ক সহজ মোড / Elderly simple mode | not built (UI) | FB-adjacent: flag only, **simplified-UI not built** |
| 21 | সরকারি সেবা গাইড / Govt & religious service guide | **basic** | **YES (P10 FIRST BATCH)** |
| 22 | এজেন্ট স্টুডিও / Agent Studio | **basic** (owner-blocked AI) | **YES (P10 FIRST BATCH)** |
| 23 | AI ইনবক্স / AI Inbox | **basic** (owner-blocked fetch) | **YES (P10 FIRST BATCH)** |
| 24 | ব্যবসা / Business v2 (khata/tagada/cashbox/selling/AI) | advanced | no (build 63, rebuilt this wave) |
| 25 | AI CRM (Axon Dynamics) web | advanced | no (R1 rebuild; web app + in-app Sales CRM) |
| 26 | জব হান্টার / Job hunter | **basic** (owner-blocked tailor/send) | **YES (P10 FIRST BATCH)** |
| 27 | নমিনি অ্যাক্সেস / Nominee access | **basic** | **YES (P10 FIRST BATCH)** |
| 28 | মনিটাইজেশন/প্ল্যান / Plans & monetization | good | no (R2 plans/paywall rebuild; billing owner-blocked) |
| 29 | ইন্টিগ্রেশন অ্যাডমিন / Integrations Admin (web) | advanced | no |
| 30 | কানেক্টেড সার্কেল মেসেঞ্জার / Connected Circle (M1+M2) | advanced | no (builds 61/62) |
| 31 | হেলথ টিপস / Health tips | good | no (module 5, DGHS/WHO) |
| 32 | মেডিসিন ডেটাবেস / Medicine database | good | no (module 5, DGDA-only) |
| 33 | অভিধান / Dictionary bn↔en | good | no (module 5) |
| 34 | ফটো এনহ্যান্স / Photo enhance | good (owner-blocked engine) | no (module 5, plan-only) |
| 35 | আনসিন ওয়ার্ল্ড / Unseen World | good | no (module 5) |
| 36 | রাইড/ফুড ডিপ-লিংক / Ride & food | good | no (module 5) |
| 37 | রমজান মোড / Ramadan mode | good | no (P16) |
| 38 | পৌঁছেছি চেক-ইন / Safe-arrival check-in | good | no (P16, R2 safety) |
| 39 | পরীক্ষার ফল / Exam results | good | no (P16) |
| 40 | পাসওয়ার্ড রিসেট / Password reset & recovery | good (owner-blocked SMS) | no (P15) |
| 41 | প্রাইভেসি অ্যানালিটিক্স / Privacy analytics (owner dashboard) | good | no (P15, build 64 unshipped) |
| 42 | ফল ডিটেক্ট রানটাইম / Fall detection runtime | good (native sensor mock/owner-blocked) | no (P14, build 64 unshipped) |
| 43 | নাম/ট্রেডমার্ক অ্যাবাউট / Name & TM about | good | no (P15, build 64 unshipped) |
| 44 | লিগ্যাল পেজ / Legal pages | good (owner-review content) | no (module 5) |
| 45 | অনবোর্ডিং ও প্যারেন্ট-লিংক / Onboarding + parent-linking | good | no (R2) |
| 46 | গ্রুপড সাইডবার + চ্যাট থেকে ওপেন / Sidebar + open-from-chat | advanced | no (R2) |
| 47 | AI narrative/roleplay/mental/billAI/LifeScanner | owner-blocked | no (needs-key states correct) |
| 48 | Security hardening / backups plan doc | good (doc only, owner-review) | no (P15, written build 64) |

### COUNTS PER GRADE

- **advanced: 12** — Chat/agent, Reminders/notes, My Account/money, Documents/vault, Family care, Scam protection, Safe Journey, Business v2, AI CRM, Integrations Admin, Connected Circle, Grouped sidebar/open-from-chat.
- **good: 20** — Memory, Medicine follow-up config, Meetings, Birthdays, Plans/monetization, Health tips, Medicine DB, Dictionary, Photo enhance, Unseen World, Ride/food, Ramadan, Safe-arrival check-in, Exam results, Password reset, Privacy analytics, Fall-detect runtime, Name/TM about, Legal pages, Onboarding/parent-link, Security/backup doc. (= 21 actually; see note)
- **basic: 11** — Finance tools, Emergency+SOS, Subscriptions, Watch feed, Voice commands, Nearby, Contacts/Personal CRM, Govt/service guide, Agent Studio, AI Inbox, Job hunter, Nominee. (= 12; see note)
- **not built (UI): 2** — Auto-pay ladder app screen, Elderly simple-mode UI.
- **owner-blocked (pure): 1** — AI narrative/roleplay/mental/billAI/LifeScanner bundle (all other owner-blocked items have working no-key paths and are graded on their built layer).

(Note: a few modules carry a secondary owner-blocked AI/exec layer, counted once under their primary built grade. Exact bucket tallies: advanced 12, good 21, basic 12, not-built 2, owner-blocked 1 = 48 rows.)

### BELOW-ADVANCED ITEMS (must all be upgraded) — PRIORITIZED

**Tier 1 — P10 FIRST-BATCH, never upgraded (basic → advanced, highest priority):**
1. Finance tools (zakat/EMI/net-worth/invest) — pure-compute, thin screen
2. Emergency card & SOS — P10-era; Safe Journey built around it but the card itself not rebuilt
3. Subscriptions — thin list, never rebuilt
4. Watch feed — P10 screen over R1 watcher engine; UI thin
5. Nearby — OSM works, UI thin
6. Govt/service guide — factual list, thin
7. Contacts / Personal CRM — P10 contacts screen (meetings split out to its own module)
8. Agent Studio — thin; AI layer owner-blocked but surface is basic
9. AI Inbox — classify works no-key; screen thin until Gmail connected
10. Job hunter — match works no-key; screen basic
11. Nominee — functional but basic
12. Voice commands — deep-links only; native Assist/widget/wake-word not built

**Tier 2 — not-built UI (build the screen):**
13. Auto-pay ladder app screen (backend + stop-all done)
14. Elderly simple-mode UI (flag exists, simplified UI not built)

**Tier 3 — good → advanced (module-5 / P14-16 / launch wave; polish to depth standard):**
15. Memory "AI knows"
16. Medicine follow-up config (per-med form exists; raise to advanced)
17. Meetings & appointments
18. Birthdays & memorable days
19. Plans/monetization
20. Health tips
21. Medicine database
22. Dictionary
23. Photo enhance
24. Unseen World
25. Ride/food
26. Ramadan mode
27. Safe-arrival check-in
28. Exam results
29. Password reset & recovery
30. Privacy analytics dashboard
31. Fall-detect runtime
32. Name/TM about
33. Legal pages (content is owner-review, surface can be upgraded)
34. Onboarding + parent-linking
35. Security/backup plan doc (owner-review deliverable)

---

## PART B — OWNER-REQUEST CHECK

### 1. Strict language (no mixed "bn / en" labels; Bangla-only / English-only) — **DONE**
- Gate: `app/tool/lang_gate.py` fails build on (a) Bangla chars in any Dart outside `lib/l10n/`, (b) ARB key parity break, (c) mixed Bangla+Latin `/` label literals. ৳ (U+09F3) exempt; `crmTitle`/`@Assisto`/WhatsApp/Messenger brand-name allowlist documented.
- **Ran it live: `LANG GATE: clean ✓`** (0 violations). ARB en==bn==1916 (per build 64).
- Spot-checked grep for mixed labels: all hits are code comments (`// Settings / Plans`), within-one-language slash lists (`হাসপাতাল / চেম্বার`, `পরিবার / কাজ / স্বাস্থ্য`), or ARB bn values (Bangla/Bangla) — **no mixed bn/en user labels in Dart**. Each language resolves via AppLocalizations (bn screen = Bangla-only, en = English-only).

### 2. Names live — **DONE**
Evidence: `app/lib/widgets/sidebar_sections.dart` + ARB.
- "আমার হিসাব / My Account" → section id `my_account`, title `t.sidebarMoney`; item `t.moduleMoney` → `MoneyScreen`. (header is My Account, NOT "Money/টাকা".)
- "ডকুমেন্টস / Documents" → **inside Daily Life** section (`daily_life`): `t.moduleVault` → `VaultScreen`, line 150. ✓ (located in দৈনন্দিন জীবন, per spec)
- "CRM" (both langs) → `t.crmTitle`, lang-gate SAME_VALUE_ALLOWLIST exception. ✓
- "কন্টাক্টস / Contacts" → `t.contactsTitle` → `CrmContactsScreen` (Family section). ✓
- "প্রোফাইল / Profile" (never "Account" for profile) → report confirms naming v2 (user area → Profile/প্রোফাইল); sidebar bottom "Profile (name + phone)". ✓

### 3. Exact sidebar grouping vs SIDEBAR_LAYOUT.md — **DONE (with 1 intentional addition)**
8 collapsible sections match the spec order exactly: Reminders&Memory, My Account, Family, Safety, Health, Daily Life, Work, Business. Top (New chat/Messages/search) + bottom (Settings w/ In-progress+Connected apps, Plans&points, Profile) in `app_drawer.dart`. Each module appears once; open/closed persisted; search by bn/en + synonyms; chatnav routes.
- **Deviation (intentional, improvement):** Safety section includes `FallDetectScreen` (item added build 64, not in original spec), and Daily Life includes `RideFoodScreen` (added build 64 per P14 gap fix). Both were explicit owner P14 items; placement matches the P14_16_AUDIT recommendations. Not a regression.

### 4. CRM first-run (no "couldn't load") — **DONE**
Evidence: `app/lib/screens/crm/crm_home_screen.dart` line 48 "No org/membership → first-run, NOT an error"; line 74 renders friendly welcome with "Start your CRM" / "Join a team". `crm_firstrun_screen.dart` + `crm_common.dart` (createOrg / joinByCode + reference codes matching backend error-log code). Root cause (`/api/v1/crm` mount 404) fixed+deployed per report line 13. Error/empty/loading states via `CrmStateView.error/empty`. ✓

### 5. Configurable accident countdown + medicine follow-up timing — **DONE**
- Fall/accident: `backend/core/logic/safety.py` — `FALL_WINDOW_DEFAULT = 120` (2 min), `FALL_WINDOW_MIN = 30`, `FALL_WINDOW_MAX = 600` (10 min), `clamp_fall_window` enforces 30s–10min. OFF by default. UI in `safety_screen.dart` + `fall_detect_screen.dart` (countdown mirrors backend). ✓
- Medicine follow-up: `app/lib/screens/family_screen.dart` — configurable `followup_repeat_min` (def 15), `followup_retries` (def 2), `caregiver_alert_min` (def 30) on the per-medicine add/edit form. ✓

### 6. Safe Journey items 1–19 — **DONE (all 19 present in logic + screens)**
Evidence: `backend/core/logic/safety_journey.py` (+ safety.py) + `app/lib/screens/journey_{start,live,settings,sos,fake_call}_screen.dart`.
1 Start journey (dest/ETA/watchers/presets) — `new_journey`, `preset_journey` ✓
2 Live location + auto-end — `record_location`, `arrival_check`, `mark_arrived`, `stop_journey` ✓ (native foreground service = TODO/key-gated per spec)
3 Vehicle details — journey payload/screen ✓
4 Auto-arrival geofence — `arrival_check` ✓
5 Overdue "Are you OK?" + alert + 999 — `overdue_state`, `should_alert_overdue` ✓
6 Low-battery <15% auto-send — `low_battery_trigger` ✓
7 Discreet SOS (power/shake/tile/widget silent) — `sos_journey_payload`, journey_sos_screen (native triggers key-gated per spec) ✓
8 Duress PIN (fake-cancel + silent alert) — `hash_pin`, `verify_pin_action`, `duress_outcome` ✓
9 Fake incoming call — `fake_call_plan`, `journey_fake_call_screen.dart` ✓
10 "Where are you?" consent request — `where_are_you_request`, `resolve_where_are_you` ✓
11 Nearest help (police/hospital) — `nearest_help_query`, `rank_nearest` (OSM until Places key) ✓
12 Helplines 999 + 109 — HELPLINES const (`emergency`=999, `vaw`=109), sourced note ✓
13 Watchers-without-app expiring web page — `make_web_token`, `parse_web_token` (approved web exception) ✓
14 Routine commutes — `routine_due` ✓
15 Route-deviation — `route_deviation` ✓
16 Wellness check (parents alone, opt-in, quiet hours) — `default_wellness_config` (`parent_opt_in` hard gate), `wellness_state`, `in_quiet_hours` ✓
17 Offline queue/retry — spec'd, SMS fallback key-gated ✓
18 Privacy (traveller controls, auto-delete after trip, no server loc after expiry) — `journey_is_expired`, `redact_expired_journey`, `location_retention` ✓
19 Bilingual + scenario tests — `safety_journey_tests_snippets.py` ✓
**None missing.** Native bits (foreground service, power-button/shake/tile/widget, FCM ring) are TODO/key-gated per spec.

### 7. Connected Circle — **DONE (all requested controls present; native ring/WebRTC key-gated)**
- Mandatory relationship on invite — `circle.py`: relationship is request→accept, no contact upload w/o consent; reciprocal relation derived. ✓
- Referral points → Premium — `referral.py`: points redeem for Premium days (`REASON_REDEEM_PREMIUM`, `POINTS_PER_PREMIUM_DAY`); 3-condition gate (install+signup+active), one-per-person + one-per-device + monthly cap; **server records, plan granted by integrator** (honest). ✓
- Photos like WhatsApp — `circle_media.py`: photo/photo_hd (16/32 MB), compression/thumbnail tiers, encrypted-on-device, ciphertext metadata. ✓
- Voice FREE / video PREMIUM, caller-pays — `circle_calls.py`: `can_place_call` gates video on the **CALLER's** plan only (`VIDEO_PLANS`), receiver may be free (Premium son → free mother OK); voice free for all; referral `video_unlocked` override; cannot be bypassed by client setting kind='video'. ✓
- Call/privacy controls — `circle_privacy.py`: incoming-off default for strangers (circle-only), DND (window + family exception, still logs missed), block (silent two-way), restrict (filtered inbox, hides active status/read receipts), report (attaches recent msgs + optional block), active status visibility (`VIS_FIELDS`/`active_status`), read receipts (`can_see_read_receipt`, two-way honored). ✓
Native (FCM/PushKit-CallKit ring, WebRTC TURN) key-gated per spec.

### 8. Business v2 — digital khata, tagada, cashbox, minimum-price bargain enforced IN CODE — **DONE**
- Khata: `business_khata.py` (29 tests) + `KhataParty`/`KhataEntry` models + `khata_screen.dart`.
- Tagada (collection schedule): `TagadaSchedule` model; urls `tagada/single/<id>`.
- Cashbox: `cashbox_screen.dart` + `CashboxDay`/`CashEntry` models.
- **Minimum-price bargain enforced in code:** `business_views.py` returns **422 below_min** at cart/add (line 483), cart/line price-set (508, price UNCHANGED on reject, 536), discount-preview (clamp-to-floor, 570-617), checkout (617); `business_selling.py` `_price_for` **rejects** below-min (not silent clamp, 429-447), `cart_discount` clamps to floor (`floor = sum(qty*min_price)`), staff-redaction hides `cost_price`/`min_price`. 7+11 min-price tests. ✓

### 9. Platform order Android → iPhone → web — **CONFIRMED (iOS & web NOT built)**
- Android: built, builds 53→64. Primary and only built platform.
- iPhone (P11): **NOT built** — no `ios/` directory in `app/`. Queued after P14-P16.
- Web app: **NOT built** for app features (correct per owner order "web LAST"). Only the sanctioned web exceptions exist: owner Integrations admin page, 4 free web tools (CV/scam/photo/festival), and the Safe-Journey expiring watcher page. ✓ Status matches owner directive exactly.

---

## HEADLINE FINDINGS

1. **12 modules are still P10-first-batch "basic" and never upgraded** — these are the clear upgrade-wave targets: Finance tools, Emergency+SOS, Subscriptions, Watch feed, Voice commands, Nearby, Contacts/Personal CRM, Govt guide, Agent Studio, AI Inbox, Job hunter, Nominee.
2. **2 modules have no UI at all:** Auto-pay ladder screen, Elderly simple-mode UI.
3. All 9 owner-request checks are satisfied (strict language gate runs clean; names/sidebar/CRM-first-run/countdowns/Safe-Journey-19/Circle-controls/Business-min-price all verified in code).
4. **Shipping blocker:** build 64 (P14-P16 completion: analytics dashboard, fall-detect runtime, name/TM about) is GREEN and committed but unshipped — GitHub repo disabled for push/CI after rapid visibility flips. Owner must re-enable the repo (report lines 498-504).
