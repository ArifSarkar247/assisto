# Assisto work queue — rewritten 3 Nov 04:00 BD (short; older history is in git: `git log -p .phaseB/QUEUE.md`)
Rules for every item: Bangla feature card first (owner_actions/FEATURE_CARD_<X>_BN.md) -> competitor teardown -> build with real data + proof -> board row (owner_actions/FEATURE_100_BOARD_BN.md) reaches 100 only with written proof -> new things behind a flag -> 40% profit rule -> CI only (no local tests/builds) -> token rule (grep, never whole files) -> <=2-4 parallel agents. Home frozen except explicit owner order. Never deploy / push main / touch live DB, flags, money, Play, owner_private from agents.
Status words: DONE (shipped in a build) / IN PROGRESS / WAITING FOR OWNER. "DONE" never means 100 on the board; see the board for the honest score. Honest per-item table for Part 2/3: owner_actions/PART2_PART3_TABLE_BN.md.

## MASTER ORDER 3 Nov 04:00 — owner_actions/OWNER_MASTER_ORDER_3NOV_0400.md (replaces unsent messages)
- P1 Finish CCTV completely (auto-arm, daily summary, visitor log, elder no-movement, shop times, watchman, footfall, guard mode, SOS->home camera, time-lapse, multi-site grid, health report, roles, share link, neighbourhood watch, Play Billing plans, Hikvision/Dahua path) — IN PROGRESS (audit: 8 exist / 23 partial / 38 missing, owner_actions/CCTV_AUDIT_3NOV_BN.md)
- P2 Website hero + fixes (owner_actions/OWNER_WEBSITE_ORDER_3NOV.md) — IN PROGRESS (v3 live 3 Nov 03:07; hero change pending)
- P2 Owner fixes 02:55 (owner_actions/OWNER_FIXES_3NOV_0255.md): single blood donor, train banner ad, home + Discover — IN PROGRESS
- P2 Floating chat bubbles FINAL (owner_actions/OWNER_BUBBLES_ORDER_3NOV.md) — IN PROGRESS (first version in b286; board 58)
- P2 Safe Journey final (owner_actions/OWNER_SAFE_JOURNEY_ORDER_3NOV.md) — IN PROGRESS (board rows 75-89, no owner real-phone proof)
- P2 Play listing pack (owner_actions/OWNER_PLAY_LISTING_ORDER_3NOV.md) — IN PROGRESS (same headline as website)
- P3-A Rewrite this queue — DONE (this file)
- P3-B Flag prep (read-only live cron check + ONE sudo command, train schedule path, agent_core 10% rollout, Data safety in Bangla) — IN PROGRESS (agent flagprep; live crons checked 3 Nov 04:00: ops_cron_file --diff = 0 missing, ops_watch bad=0 → no sudo command needed)
- P3-C Business automation real-life ready (crmauto, retention_auto, AI Sales Assistant, agent_core; opt-out, daily caps, SMS cost; Meta App Review steps) — IN PROGRESS (crmauto merged b280, board CRM 69.5; Meta review = owner)
- P3-D Marketing engine v1 behind a switch — NOT STARTED (no code)
- P3-E Assisto Market (reverse auction, group-buy, COD, Dhaka pilot) — NOT STARTED (no code)
- P3-F Honest Bangla table for every Part 2/3 item — DONE (owner_actions/PART2_PART3_TABLE_BN.md)
- MORNING: top of STATUS one short Bangla summary — WAITING (written at morning)

## Orders since 2 Nov 18:00 BD (one line each)
- 2 Nov 18:00 daily 21:00 BD feature report + usage forecast — DONE (STATUS)
- 2 Nov 19:00 My Circle notifications lost: fix + chat bubbles — DONE b286 (owner 4-state test pending) — owner_actions/FEATURE_CARD_MY_CIRCLE_BN.md
- 2 Nov video call PiP like WhatsApp — DONE b287 (Realme real-phone proof still owner) — FEATURE_CARD_CALLS_BN.md
- 2 Nov invoices thermal 58/80 + A4, 9 templates, VAT/Mushak — DONE b287 (board 68) — FEATURE_CARD_INVOICES_BN.md
- 2 Nov business accounting: core + UI behind accounting_v2 OFF — DONE code (b279/b284), board 62, flag OFF, owner flips — FEATURE_CARD_ACCOUNTING_BN.md
- 2 Nov channels + communities — DONE b288 (board 62) — FEATURE_CARD_MY_CIRCLE_BN.md
- 2 Nov ledger2 (VAT rates, year end, supplier BIN, payment method) — DONE b288
- 2 Nov Play audit 2 (FGS declaration, data safety all features ON, UGC, App Links) — DONE docs b288; owner pastes into Play Console
- 2 Nov flag-flip readiness table (11 owner-off flags) — DONE (flipready); owner flips
- 2 Nov launch sweep (Bangla digits, English leaks, overflow, 48dp) — DONE b288
- 2 Nov bizops Business AI morning card (agent_core switch OFF) — DONE b287 — FEATURE_CARD_BIZ_OPS_AGENT_BN.md
- 3 Nov 00:45 CCTV FINAL order (owner_actions/OWNER_CCTV_ORDER_3NOV.md): audit table — DONE; phone-as-camera (cctvphone) — DONE b290 (board 55, no 2-phone proof); smart alert types (cctvalerts) — DONE b290 (board 55, no real camera yet); rest — IN PROGRESS (see P1)
- 3 Nov CCTV devices + cost research (Hikvision/Dahua official API, worst-case cost; relay limit decision) — DONE research; WAITING FOR OWNER yes/no on 0.3 GB relay limit and object storage (R2/S3) — owner_actions/CCTV_DEVICES_COST_BN.md
- 3 Nov 01:20 Website order v2 (sticky header, mobile menu, chips, Install now, Play badges, cache) — DONE, live 3 Nov 03:07 (board 70) — OWNER_WEBSITE_ORDER_3NOV.md
- 3 Nov website APK signing cert differs from Play — WAITING FOR OWNER "yes" (use Play-signed universal APK); also paste Play App Signing SHA-256 in Owner Admin -> Integrations
- 3 Nov 01:50 Bubbles FINAL (auto-on, many bubbles, during calls, per-chat off) — IN PROGRESS — OWNER_BUBBLES_ORDER_3NOV.md
- 3 Nov 02:00 Play listing pack — IN PROGRESS — OWNER_PLAY_LISTING_ORDER_3NOV.md
- 3 Nov 02:25 Safe Journey final — IN PROGRESS — OWNER_SAFE_JOURNEY_ORDER_3NOV.md
- 3 Nov 02:55 owner fixes (blood single screen, train banner, home/Discover) — IN PROGRESS — OWNER_FIXES_3NOV_0255.md
- 3 Nov 03:30 website hero + fixes; Play pack uses the same headline — IN PROGRESS
- 3 Nov 04:00 master order — see top
- Personal Secretary (PS: Today brief, circle people, pick-up sheet) — DONE b290 (board 58; Play notification-listener finding in card) — FEATURE_CARD_PERSONAL_SECRETARY_BN.md
- 3 Nov camera disclosure before phone camera; contrast fix — DONE b290
- Build 290 integration (pssec, cctvphone, cctvalerts, sitev3) — release notes committed; server deploy + Play upload by integrator

## OWNER BACKLOG ORDER 2 Nov (real state)
### 0) Always first: owner phone-test bugs + launch blockers
- Guardian +45 min consent, saved places != anti-theft safe places (agent/jdec) — DONE (merged before b280)
- 8 Nov launch: switch list, entry-point leaks, AI-off honesty, Play production checklist (agent/launch, playaudit2, flipready) — DONE docs/tests; owner flips switches + Play steps — WAITING FOR OWNER
- Any owner phone-test bug report jumps here — standing
### 0.5 CCTV / Vehicle / Safe Journey to 100 (cctv100, veh100b, journey100b)
- CCTV: see P1 (board 10 rows avg 61.1) — IN PROGRESS
- Vehicle tracking (board 9 rows avg 57.1; live map 43, car-mode 44) — IN PROGRESS, no real GPS device proof
- Safe Journey (journey100b, journeymode) — DONE code, board 75-89, needs owner real-phone proof; destination alarm in train agent
### 1) Owner first priority
1. A1 My Circle links/preview/safe-link, Family/Others, many-to-many guardians (circlea, finish1) — DONE (board 63-70)
2. A2 Missing person alert + found-share (missing) — DONE code (board 55/50), no 2-phone proof
3. B Blood donor panel + urgent requests (blood, finish1) — DONE code (board 62); 3 Nov 02:55 order = remove the old simple screen — IN PROGRESS
4. C Train tracker + chat + destination alarm (train, journeymode) — DONE code (card FEATURE_CARD_TRAIN_TRACKER_BN.md); banner ads + 16318 SMS/schedule check — IN PROGRESS
### 2) PART 1 before launch
5a Intruder selfie / SIM change / uninstall alert (theftalerts) — DONE code (board 71); Play-policy note in card; flash/reset wipes app (honest)
5b Child emergency audio (kidaudio) — DONE code, flag OFF; WATCH side WAITING FOR OWNER decision (silent MONITOR blocked by our guard)
5c Mini 4G GPS chip on vehicle tracker (chip) — DONE code b284 (board 55); needs real chip proof
5d "Where to buy" asalifymart.com link on CCTV/vehicle/kids/chip pages — DONE with chipbuy (link only)
6e Accounts onboarding personal/business/both (acctmode) — DONE (board +1 row)
6f Listed-company accounting — DONE code flag OFF, board 62 (ledger-acct, acctui, ledger2)
6g Invoices — DONE (see above)
6h CRM most automated (crmauto) — DONE code (board CRM 69.5; CI 41439870415 green)
6i AI sales agent chats + Facebook/Instagram comments (salesbar, sales2) — chats DONE code (board 55-72); FB/IG comments WAITING FOR OWNER (Meta App Review)

## PART 2 (owner 2 Nov) — real state; per-item honest table in owner_actions/PART2_PART3_TABLE_BN.md
- 2.1 Rename PA Secretary -> Personal Secretary + PS for everyone — rename DONE b275; PS Today brief DONE b290 (58); WhatsApp notification reading NOT built (Play policy)
- 2.2 CV Builder professional — PARTIAL (board 65); "ads line" question WAITING FOR OWNER
- 2.3 Job Hunter legal sources — PARTIAL (board 56; no real job source feed)
- 2.4 Mock interview with voice + scoring — PARTIAL (board 52)
- 2.5 Task manager (subtasks, shared, calendar, voice) — PARTIAL (board 62)
- 2.6 Cost and time estimator real prices — PARTIAL (screen+engine exist; no board row)
- 2.7 Quick tools — PARTIAL (screen+engine exist; no board row)
- 2.8 Language Partner (5 languages, IELTS, pronunciation scoring) — PARTIAL (bn<->en decks only; no IELTS, no scoring)
- 2.9 Food photo -> calories — NOT STARTED
- 2.10 AI daily planner — NOT STARTED (needs AI key)

## PART 3 (owner 2 Nov) — real state
- 3.1 Home feed live (dollar, gold, football/cricket, offers, packages) — NOT STARTED (home frozen; needs official/licensed sources)
- 3.2 Documents typed add, PIN recovery, free limit — PARTIAL (vault exists; typed add/recovery not verified)
- 3.3 Service guide — NOT STARTED
- 3.4 Daily info and services — PARTIAL (lifebar, board rows 24-70)
- 3.5 Ramadan tracker (deadline Jan 2027) — PARTIAL (ramadan screen/calendar/alarms exist; no board row)
- 3.6 Quran Majid — NOT STARTED (needs licensed text + audio)
- 3.7 Probashi corner — PARTIAL (board 63)
- 3.8 Student corner — PARTIAL (board 61)
- 3.9 Travel Planner — PARTIAL (board 49)
- 3.10 Wedding and events — PARTIAL (screen+engine exist; no board row)
- 3.11 Ride and Food — PARTIAL (board 63, opens partner apps)
- 3.12 Farmer mode — PARTIAL (offline ledger engine; no DAE/BARI/DAM data)
- 3.13 Unseen World / Unseen Bangladesh — PARTIAL (board 66/59)
- 3.14 My Circle community + channels — channels/communities DONE b288 (62); further plan WAITING FOR OWNER explanation

## Standing orders still in force (details in owner_actions/OWNER_*.md and memory)
- Owner final order 2 Nov: launch ALL features 8 Nov at Silicon Valley standard; guard = p95>400 ms or swap -> pause newest agent; daily 21:00 BD report
- Definition of Done (owner_actions/DEFINITION_OF_DONE_BN.md), Master quality order, Feature excellence rule, 100% mode, Maximum mode (owner_actions/OWNER_FINAL_ORDER_27OCT.md)
- Agent Core (Part 2 of 27 Oct order): owner_actions/AGENT_CORE_DESIGN_BN.md; flag agent_core OFF; AI keys: owner adds
- Billing hardening (owner_actions/BILLING_ORDER_27OCT.md), call bugs (b287 done), home frozen (v2; v6 behind home_v2)
- Daily: STATUS_FOR_OWNER.md top = short Bangla summary; 3 Bangla lines per published build

## OWNER ADMIN SUPPORT/SAFETY/STATS (3 Nov 04:22) — after CCTV P1
Full text: owner_actions/OWNER_ADMIN_SUPPORT_ORDER_3NOV.md. Agent: adminsafe (running).
