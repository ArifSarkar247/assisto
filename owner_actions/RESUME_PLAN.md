# RESUME PLAN — pause (3 Nov 21:15) ENDED 4 Nov 02:25: owner RESUME FULL SPEED — this file is the work list

Nothing is lost: every agent branch is committed and pushed; nothing half-merged into main.
Live server = origin/main (build 304) **plus local merges of `agent/placesnew` (Places key fix) and `agent/ailang` (AI Part 1 server fixes: reply language, vision uses saved keys, instant refund, friendly text)** — server HEAD d0b6adf3.
⚠️ The next deploy MUST include both (`placesnew` is in `b301i`; `ailang` is in `agent/aifinal`, which is based on b301i + ailang), otherwise these live fixes are rolled back.

## Exact first steps to resume (in order)
1. Ask the owner for the current Claude usage % and the result of the new-key tests (Places "Test connection", Anthropic key).
2. Integration branch `b301i` (f744f23b, checks green): check APK compile run 41658245611; merge `agent/tplfix` (a0d7e43d); re-run checks if anything changed.
3. When green: ship as the next build (backup → push main → migrate 0148_mapscost, 0149_guardian2, 0150_nearby → restart assisto + assisto-tracker → health) → `bin/ship_watch.sh` (Play internal+alpha, never production) → Bangla STATUS lines (one per part of the 18:40 order, list of Play product ids, Nearby data line).
4. Then fix whatever the owner's phone tests of builds 302/304 find (top priority over new work).

## ⭐ PERMANENT RULE (4 Nov 01:32): WORLD CLASS — see CLAUDE.md top. All features ON at 8 Nov launch; every feature ≥ 9/10 by 7 Nov; create owner_actions/QUALITY_BOARD_BN.md (reference app + 6 scores per feature) and show it in Owner Admin; daily 21:00 board line; 7 Nov 18:00 below-9 list.

## Owner orders not finished (newest first)
| Order | State | What is left |
|---|---|---|
| 4 Nov 01:02 AI CHAT REBUILD FINAL — HIGHEST PRIORITY; supersedes + merges all AI chat orders 3–4 Nov night (owner_actions/OWNER_AI_REBUILD_4NOV_0102.md; earlier texts in OWNER_AI_ROUND2_4NOV_0025.md, OWNER_AI_ORDER_3NOV_2315_2320_2325.md) | IN PROGRESS — agent `aifinal` | 8 parts; if usage runs low finish parts 1–4 first: one AI path (no regex intent parser), actions only via confirm cards, false-entry clean-up + count, best-answer rule; then levels (Normal = Gemini Flash), chat UX, 100-prompt exam ≥90% win/tie on live server |
| 4 Nov 02:05 BUSINESS AI REAL IMPACT (owner_actions/OWNER_BUSINESS_AI_ORDER_4NOV_0205.md) | QUEUED — FIRST after AI rebuild parts 1–4 (before Care Call and plans overhaul) | write owner_actions/BUSINESS_AI_AUDIT_BN.md (4 pillars: exists / works on phone / missing / score with proof), then build pillar 1 sales agent → 2 CRM automation → 5 marketing engine Prochar (02:10: BD calendar, real-catalog content, one-tap posting, lead handover, ATTRIBUTION, weekly report, support autopilot; score vs Mengo Engine) → 4 CCTV accuracy (metrics + clip test set, precision/recall) → 3 Market reverse agent + group buying v1 (seller onboarding + invite link, no fake listings); outcome card on Business home |
| 4 Nov 02:22 VISION CHECKLIST (owner_actions/OWNER_VISION_CHECKLIST_ORDER_4NOV_0222.md) | checklist doc IN PROGRESS (agent `vision`, docs only); Owner Admin page QUEUED after AI rebuild 1–4 | owner_actions/OWNER_VISION_CHECKLIST_BN.md master list (works / partial / not built, missing, plan, launch importance, world-class-by-8-Nov, owner items); after-call note + money-from-notifications = launch important; Owner Admin page with progress; daily 21:00 update |
| 4 Nov 01:20 PLANS & CREDITS OVERHAUL (owner_actions/OWNER_PLANS_CREDITS_OVERHAUL_4NOV_0120.md) | QUEUED — starts right after AI rebuild parts 1–4 are green | Step 1 audit of every plan/paid item + conflicts (90 vs 150 credits, 120-in-2-days drip); Step 2 owner_actions/PRICING_PLAN_BN.md proposal (≥40% worst case after Play fee) — WAIT for owner approval, change no live prices/Play products; Step 3 build after approval (one source of truth, no rollover, ledger/history, proration, grace/hold/refund/restore, multi-device, no ads on paid, P&L per plan); Step 4 license-tester cases (owner phones) |
| 4 Nov 01:50 CARE CALL final with 3 screens (owner_actions/OWNER_CARE_CALL_ORDER_4NOV_0150.md) — LIVE at 8 Nov | QUEUED — starts right after AI rebuild parts 1–4 | consent, full-screen call (own call system, USE_FULL_SCREEN_INTENT + Play calling-app declaration draft), own voice only, retry 10 min then alert setter, DND, reboot/battery-saver safe, offline queue, no ads, free fair limits; screens 1–3 exactly as the order text; user text never filtered (medicine module stays OFF); two-phone/locked/reboot tests; screenshots of 3 screens in STATUS; quality board row |
| 4 Nov 00:05 SAFE JOURNEY SEARCH bug (owner_actions/OWNER_JOURNEY_SEARCH_BUG_4NOV_0005.md) | IN PROGRESS — agent `jsearch` (based on b301i + ailang; uses mapscost's server autocomplete) | live suggestions (Chandra → Chandra Mor, Chandra Bus Terminal), pre-typing list, confirm card + geofence, ETA default, remove internal map text + Wake-me toggle, shared search component; CI with Chandra |
| 3 Nov 23:33 PART 8 ACCOUNT RECOVERY (owner_actions/OWNER_ACCOUNT_RECOVERY_ORDER_3NOV_2333.md) | not started — after AI Parts 1–6 (agent `aifinal`) or on resume | all 7 points: Account & security page, add/verify email (6-digit, 45 s resend, 10 min, 5 tries), gentle nudge, forgot password via SMS or verified email, lost-phone support recovery with 48 h hold, change alerts + 'This was not me' lock + 24 h rule + sign out others + rate limits; CI tests per flow |
| 3 Nov 23:15/23:20 AI FINAL + 23:25 PART 7 Photo Studio (owner_actions/OWNER_AI_ORDER_3NOV_2315_2320_2325.md) | allowed during pause; PART 1 server fixes on `agent/ailang` (CI → deploy); PARTS 1(rest)–6 on `agent/aifinal` (one agent, sequential) | PART 7 Photo Studio after Parts 1–6 or on resume |
| 3 Nov 19:55 Google Places key bug | ✅ fix LIVE (local merge) | owner presses Test connection again; reach main via b301 |
| 3 Nov 18:50 NEARBY final (own emergency list, zero Google cost) | ✅ code CI-green (`agent/nearby` fd48cae3, checks 41649679482), merged in b301i as 0150_nearby, NOT shipped | data run 41639696149 (GitHub) still building → record counts + storage size unknown; SA + QA official number pages unreachable (shown with "confirm locally"); BD official lists have no reuse licence → OSM only; Europe too big for the runner (skipped); two-phone test; Sponsored payment flow |
| 3 Nov 18:40 SAFETY PLANS + MAPS COST (Parts 1–7) | code CI-green, merged in b301i, NOT shipped; switches OFF | ship; owner: create Play products `safe_child` (sub, base plan `monthly`, ৳30), `safe_family` (sub, `monthly`, ৳99), consumables `safe_req_10` ৳10, `safe_req_30` ৳30, `safe_req_100` ৳100; decide prices: 40% rule holds only with per-account paid-map caps (without caps min ৳36 / ৳126); owner reads School Safe Play-policy answer (no in-app price/link, school code only) |
| 3 Nov 16:30 MY CIRCLE final (A–G) | ✅ shipped builds 302 + 304 | owner phone tests (below); Android bubble position is decided by the phone (honest limit) |
| 3 Nov 11:45 Language Partner 8 languages, Noorani Quran, certificate | ✅ code shipped (switches OFF) | mock-test listening via phone voice inside mocks; `lw_` shots into Bangla sweep; native-speaker reviews; Qari review + licensed audio; owner flips switches after phone tests |
| 3 Nov 10:45 launch ALL features 8 Nov | ongoing | board rows need real-phone proof; Part 2/3 table owner_actions/PART2_PART3_TABLE_BN.md |
| 3 Nov 00:45 CCTV final | ✅ code | real-camera proof; Hikvision/Dahua emails; Play CCTV products |
| 2 Nov orders | ✅ code | owner real-phone proofs listed on the board |

## Branches (all committed + pushed)
- `b301i` (integration) head **f744f23b**, clean, pushed as ci/b301: origin/main + mapscost + guardian2 + safeplans + placesnew + nearby; migrations 0148_mapscost, 0149_guardian2, 0150_nearby (makemigrations --check clean). Checks **41654147028 GREEN**. APK compile android.yml 41658245611 (#305) was running at pause — read its result first. Still to merge: `agent/tplfix` commit a0d7e43d (nightly live menu check).
- `agent/nearby` — finished, CI green (fd48cae3); merged in b301i.
- `agent/mapscost`, `agent/safeplans`, `agent/guardian2`, `agent/placesnew` — finished, CI green, merged in b301i.
- Already shipped (no action): circlebub, circlemedia, viewonce, learnwire, langkoja, langmulti, quranread, p3life, launchsweep3, sitefix, tplfix, smtpfix.

## Owner phone tests pending
- Build 302: bubble tap opens chat; second message keeps bubble + soft tick; Back shrinks bubble; new pop sound with app closed.
- Build 304: 7-photo album (remove/rotate/caption) → 2×2 +2; view-once photo opens once, screenshot black, sender sees "Opened"; 4-minute video → trim screen + size.
- Earlier: travel/wedding RSVP, CCTV usage card, language packs on a tester account.

## Keys
| Key | State |
|---|---|
| Email SMTP (Gmail) | ✅ working (result line on card) |
| Gemini | ✅ working |
| Google Places/Maps server key | fix live — waiting for owner retest; App restriction must be None or IP 16.4.105.173 |
| Anthropic | being added by owner |
| Assisto Android maps key | waiting — goes in GitHub secret `MAPS_ANDROID_KEY` (package com.assisto.assisto + Play App Signing SHA-1, Maps SDK for Android only) |

## Process notes
- One dedicated integration agent merges green branches into `bNNNi`; lead ships. android.yml dispatches burn build numbers.
- Daily 21:00 BD report; 15-min guard (p95 > 400 ms or swap growing → pause newest agent).


## To check after the pause
- Google Play RTDN webhook (/api/v1/payments/play/rtdn) arrives every 5 min, 0.5–1 s each, all 200 — find why Google keeps sending (stuck Pub/Sub message or test notifications) and make the handler fast (ack first, verify async).