# RESUME PLAN — work paused by owner STOP ORDER (3 Nov 2026 21:15 BD, Claude usage 86%)

Nothing is lost: every agent branch is committed and pushed; nothing half-merged into main.
Live server = origin/main (build 304 + daily report) **plus a local merge of `agent/placesnew`** (Google Places key fix, live).
⚠️ The next deploy MUST include `agent/placesnew` (it is inside `b301i`), otherwise the Places fix is rolled back.

## Exact first steps to resume (in order)
1. Ask the owner for the current Claude usage % and the result of the new-key tests (Places "Test connection", Anthropic key).
2. Integration branch `b301i` (f744f23b, checks green): check APK compile run 41658245611; merge `agent/tplfix` (a0d7e43d); re-run checks if anything changed.
3. When green: ship as the next build (backup → push main → migrate 0148_mapscost, 0149_guardian2, 0150_nearby → restart assisto + assisto-tracker → health) → `bin/ship_watch.sh` (Play internal+alpha, never production) → Bangla STATUS lines (one per part of the 18:40 order, list of Play product ids, Nearby data line).
4. Then fix whatever the owner's phone tests of builds 302/304 find (top priority over new work).

## Owner orders not finished (newest first)
| Order | State | What is left |
|---|---|---|
| 4 Nov 00:05 Safe Journey place search (phone test) | code on `agent/jsearch` (on top of b301i + ailang), CI on ci/jsearch-arb | merge after b301i; owner: Cost flags `maps_geocoding` ON + server key with Places API (New) + Routes API; retest "Chandra" |
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

## AI order 3 Nov 23:15 / 23:20 / 23:25 / 23:33 (branch agent/aifinal, CI ci/aifinal-arb)
- Order: PART 1 (lang, markdown, photo follow-ups, friendly lines, refunds) → 2 usage log → 3 answer levels → 4 credits → 5 action buttons → 6 compliance → 7 Photo Studio chat editing → 8 Account recovery.
- PART 8 (23:33, text in scratchpad recovery_order_2333.txt): Account & security page, email add/verify (6-digit, 45 s resend, 10 min, 5 tries), gentle add-email nudge, forgot password via SMS or verified email, lost-phone recovery request with My Circle confirmation + 48 h hold, change alerts with "This was not me" lock, no phone+email change within 24 h, password change signs out other devices, rate limits.
- State 4 Nov ~02:00 (agent/aifinal): PARTs 1-7 + rounds 2/3/4 + rebuild 01:02/01:05/01:12 committed. LEFT: PART 8 account recovery (server draft in scratchpad part8_wip/account_security.py + otp email 10-min/45-s diff — not wired, no app screen yet); Photo Studio direct "send to My Circle / business catalog" (share sheet works today); stop button on the HOME chat (not streamed); live exam run + ai_live_e2e (lead, after deploy); Test Lab Robo run (lead dispatch, free Spark quota); Play pre-launch report has no public API — read it in Play Console by hand.
