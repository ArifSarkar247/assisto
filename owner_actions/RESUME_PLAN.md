# Assisto — current work list (one honest list) — updated 9 Nov 2026 21:40 BD

Order = owner FULL POWER order 9 Nov 21:20 (owner_actions/OWNER_FULL_POWER_9NOV_2120.md).
Status words: **DONE (build)** · **IN PROGRESS (agent)** · **WAITING FOR OWNER (what)** · **NOT STARTED**.
Old history (3–9 Nov): owner_actions/archive/RESUME_PLAN_until_9nov.md and archive/QUEUE_until_9nov.md.
The 3 Nov STOP ORDER pause is OVER (owner resumed 4 Nov 02:25 and 9 Nov 10:05) — nothing here is paused.

## 1. Owner phone-test bugs (always first)
- Place search "limit reached" / V1 screen (P0 19:40) — root cause found; fix **IN PROGRESS (build next build after 324 = integration 309, in CI tonight)**.
- Owner phone tests pending → see the short list at the bottom.

## 2. Safe Journey V2 (owner_actions/SAFE_JOURNEY_V2_SPEC_BN.md)
- False "Arrived" fix (distance + earliest time + PIN) — **DONE (324)**.
- Start screen, merged search (own BD list), arrival window card, private traveler prompt, alert ladder, PINs, watcher board, web arrival window — **IN PROGRESS (next build after 324, CI tonight)**.
- "From = my current location" row, Bike + Walk modes, watcher chips, plate photo on start, "Going to Office?" suggestion, all unions + hospitals in place list — **IN PROGRESS (agent sjstart2)**.
- Children corner — **DONE in code, waiting for integration (b310 queue)**.
- Train screen + destination alarm — **DONE in code, waiting for integration (b310 queue)**.
- Two-phone real trip (Badda → Gazipur) — **WAITING FOR OWNER (phone test)**.

## 3. Family Care V3 (owner_actions/FAMILY_CARE_V3_SPEC_BN.md)
- SOS v3 sender + receiver (offline SMS app path, DND ring) — **DONE (324)**.
- Arrive/leave news while app open; background watch behind switch OFF — **DONE (320)**.
- Family screen + widget — **DONE in code, waiting for integration (b310 queue)**.
- Elder Easy Home + Silent Watch (+ 90-day retention) — **DONE in code, waiting for integration (b310 queue)**.
- Background location for auto arrive/leave — **WAITING FOR OWNER (Play declaration + video approval)**.

## 4. CCTV Guard V3 (owner_actions/CCTV_V3_SPEC_BN.md)
- Phone camera fixes, remote alert video, continuous recording, 30-day clips — **DONE (324)**.
- Shop Box PC download — **DONE (lifeassisto.com/get#shopbox, 9 Nov)**.
- Brand clouds Imou / EZVIZ / Hik-Connect + DVR health + discovery — **DONE in code, waiting for integration (b310)**.
- Dahua DoLynk real integration from the owner's docs (Open IoT + Open ARC) — **IN PROGRESS (agent dolynkreal)**.
- Guard Box Android (old phone / TV box reads RTSP) — **DONE in code, CI pending after hold (agent cctvbox)**; Linux/RPi/Windows box — **NOT STARTED**.
- Act / closing report / POS sales match / ask in Bangla (D–G) — **DONE in code, waiting for integration**.
- Roles, installers, privacy wall, pricing proposal (I–L) — **DONE in code, waiting for integration**; Premium AI 400 Tk, 14-day trial, commission — **WAITING FOR OWNER (yes/no)**.
- Accuracy to 90% — Shop Box motion + day person ✅; night person + phone motion — **IN PROGRESS (agent cctvacc2)**; owner night clips — **WAITING FOR OWNER**.
- Detections C (loitering, fall, fire, plates …) — **NOT STARTED**.
- Imou OAuth for customers — **WAITING FOR OWNER (Imou ticket 483)**; EZVIZ live — **WAITING FOR OWNER (open the free "Video Security" trial)**; real-camera tests — **WAITING FOR OWNER (cameras)**.

## 5. City Service (owner_actions/CITY_SERVICE_SPEC_BN.md)
- Data + route engine (391 routes, 452 stops, 50.8% coverage) — data **DONE (320)**, round 2 waiting for integration.
- App screens — **DONE in code, waiting for integration (b310)**.
- Coverage toward 70% (legunas, BRTC, field mapping, trip learning) — **IN PROGRESS (agent citycov)**.

## 6. Home shortcuts + "My Business"
- **DONE in code, waiting for integration (b310)**.

## 7. AI chat quality + nightly AI exam
- AI on Claude while Gemini is off — **DONE (324)**; pricing v2 applied — **DONE (9 Nov live)**.
- Exam update + quality pass — **IN PROGRESS (agent aiqual)**; turning the nightly exam on — **WAITING FOR OWNER/lead after aiqual**.

## 8. Business AI pillars
- Round 1 — **DONE (314)**; customer due link — **DONE (320)**.
- Round 2 (due link in tagada, win-back outcome, stock alerts, daily summary, Prochar scheduler) — **IN PROGRESS (agent bizai2)**.

## BACKLOG (owner 21:55 — start only after items 1–8 above, when agents are free)
9. Language Partner V2 (owner_actions/OWNER_LANGUAGE_PARTNER_V2_9NOV_2145.md) — **PARKED** (spec allowed now; 3 agents finished their current small step and stopped; code committed locally on agent/lpcore, agent/lpcontent, agent/lpapp).
10. Quran bilingual + Quran Shikhi (owner_actions/OWNER_QURAN_BILINGUAL_9NOV_2155.md) — **NOT STARTED**, after Language Partner stage 1; first step = owner_actions/QURAN_BILINGUAL_SPEC_BN.md with each tafsir licence confirmed in writing.

## Also done today (9 Nov)
Care Call (314) · account recovery (314) · plans overhaul + pricing v2 (applied 9 Nov) · My Circle quiet hours + second-phone sign-in (318) · deep links fixed (assetlinks, verified by Google) · Play production access applied (14:23, waiting for Google) · disk 66% → 49%.

## Waiting for owner (full list at the top of STATUS_FOR_OWNER.md)
Play prices + Play Console list · Premium AI / trial / commission decision · CCTV night clips · EZVIZ free trial · Imou ticket 483 · camera purchases · privacy-policy preview OK · production rollout steps after Google approves.

## Owner phone tests pending (install the newest build first)
| Build | Test |
|---|---|
| 318 | Two phones signed in at once; My Circle quiet hours; message sound with app closed |
| 320 | Khata "send due link" opens in another phone's browser; Family Care arrive news while app open |
| 324 | CCTV two-phone test (CCTV_TEST_TODAY_BN.md); SOS v3 on two phones; Imou test camera |
| next (tonight) | Type "Gaibandha" → suggestions, no limit message; start a journey → watcher board on the other phone |
| 302/304 | My Circle bubbles, albums, view once (still not tested) |
