- 3 Nov 16:30 OWNER MY CIRCLE FINAL ORDER (A–G: bubble position, bubble tap, new sound, multi photo, photo bubble, media limits, view once) — TOP PRIORITY, IN PROGRESS (agents circlebub, circlemedia, viewonce) — owner_actions/OWNER_MY_CIRCLE_ORDER_3NOV_1630.md
# QUEUE — rewritten 3 Nov 10:45 BD (owner: launch 8 Nov with ALL features; NOTHING is after launch)
Order text: owner_actions/OWNER_ORDER_3NOV_1045.md. Every item below ships behind its switch by 8 Nov; status per item in STATUS every few hours.

## NOW (agents running, 3 Nov)
- 1a Lost phone: intruder selfie + SIM-change alert — agent lostsim
- 1b Bag/shoe tracker chip + asalifymart buy links — agent chipbuy2
- 1c My Circle Family vs Others + search; review share-to-Facebook button — agent circlefam
- 1d Invoice designs by business type (cafe, restaurant, fine dining, e-commerce, retail, electronics showroom, lawyer, VAT/tax, any service) — agent invdesign
- P2 career: CV Builder, Job Hunter (legal sources), Mock interview — agent p2career
- P2 productivity: Task manager, Cost & time estimator, AI daily planner — agent p2plan
- P2 Quick tools — agent p2tools
- P2 Language Partner (IELTS prep + voice pronunciation scoring) — agent p2lang
- P2 Food-photo calories — agent p2food
- P3 Live home feed + Daily info (official sources) — agent p3feed
- P3 Documents with biometric PIN recovery — agent p3docs
- P3 Ramadan tracker + Quran (licensed text) — agent p3faith
- P3 Service guide + Probashi corner + Student corner — agent p3guides
- P3 Travel planner + Wedding & events + Ride & Food — agent p3life
- P3 Farmer mode + Unseen World — agent p3farm
- CCTV: cap extra pack (cctvcap), AI snapshot check (cctvaicheck); website shots (siteshots)

# Assisto work queue — updated 3 Nov ~11:00 BD (short; older history is in git: `git log -p .phaseB/QUEUE.md`)
Rules for every item: Bangla feature card first (owner_actions/FEATURE_CARD_<X>_BN.md) -> competitor teardown -> build with real data + proof -> board row (owner_actions/FEATURE_100_BOARD_BN.md) reaches 100 only with written proof -> new things behind a flag -> 40% profit rule -> CI only (no local tests/builds) -> token rule (grep, never whole files) -> <=2-4 parallel agents. Home frozen except explicit owner order. Never deploy / push main / touch live DB, flags, money, Play, owner_private from agents.
Status words: DONE (shipped in a build) / IN PROGRESS / WAITING FOR OWNER. "DONE" never means 100 on the board; see the board for the honest score. Honest per-item table for Part 2/3: owner_actions/PART2_PART3_TABLE_BN.md.

## MASTER ORDER 3 Nov 04:00 — owner_actions/OWNER_MASTER_ORDER_3NOV_0400.md (replaces unsent messages)
- P1 Finish CCTV (owner_actions/CCTV_AUDIT_3NOV_BN.md) — W1 auto-arm, W3 daily summary/visitor log, W5 elder no-movement, W6 shop times, W7 watchman, W8 footfall, W9 guard mode, W10 activity brain, W11 roles/multi-site grid/share link: DONE code in b291/b293 (board 45-55, NO real-camera or two-phone proof). IN PROGRESS: cap extra pack (agent cctvcap), AI snapshot check (agent cctvaicheck). WAITING FOR OWNER: Play CCTV products, Hikvision/Dahua emails, real-device tests
- P2 Website hero + fixes — DONE: v3 + new hero live (b291 day, 3 Nov); IN PROGRESS: website shots refresh (agent siteshots)
- P2 Owner fixes 02:55 (single blood donor screen, train banner ad, home ad below fold) — DONE b293 (migration 0142; owner phone check pending)
- P2 Floating chat bubbles FINAL — DONE b293 (board 58; no ColorOS real-phone proof, owner 4-state test pending)
- P2 Safe Journey final — DONE b293 (3 cards: live location, destination alarm, train + banner; board 75-89, owner real-phone proof pending)
- P2 Play listing pack — DONE (16 shots, 2 graphics, bn+en text, Play guide; owner pastes into Play Console)
- P3-A Rewrite this queue — DONE (this file)
- P3-B Flag prep — DONE b292/b293 (cron check = no sudo needed, train schedule check in Owner Admin, agent_core rollout %, Data safety Bangla); owner flips switches
- P3-C Business automation (message safety, opt-out, caps, SMS 40%) — DONE b293 (CRM 69.5, message safety 70, comment replies 55); WAITING FOR OWNER: Meta App Review (META_APP_REVIEW_BN.md), AI keys
- P3-D Marketing engine v1 — DONE b293 behind a switch (board 50; questionnaire, plan, follow-ups; publish gated); WAITING FOR OWNER: Meta App Review, AI keys
- P3-E Assisto Market v1 — DONE b293 (needs, sealed bids, group-buy, COD, Owner Admin; migration 0144); WAITING FOR OWNER: Market decisions (law/trust, card CI section)
- P3-F Honest Bangla table for every Part 2/3 item — DONE, updated 3 Nov ~11:00 (owner_actions/PART2_PART3_TABLE_BN.md)
- MORNING: top of STATUS short Bangla summary — DONE (3 Nov morning + b293 note)

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
- 3 Nov CCTV devices + cost research — DONE; owner decided: relay limit 0.3 GB/camera + 50 AI checks ON (STATUS 10:40); object storage (R2/S3) still WAITING FOR OWNER
- 3 Nov 01:20 Website order v2 (sticky header, mobile menu, chips, Install now, Play badges, cache) — DONE, live 3 Nov 03:07 (board 70) — OWNER_WEBSITE_ORDER_3NOV.md
- 3 Nov website APK signing cert — DONE b293: website APK now Play-signed (owner said yes); owner pastes Play App Signing SHA-256 in Owner Admin -> Integrations
- 3 Nov 01:50 Bubbles FINAL — DONE b293 — OWNER_BUBBLES_ORDER_3NOV.md
- 3 Nov 02:00 Play listing pack — DONE — OWNER_PLAY_LISTING_ORDER_3NOV.md
- 3 Nov 02:25 Safe Journey final — DONE b293 — OWNER_SAFE_JOURNEY_ORDER_3NOV.md
- 3 Nov 02:55 owner fixes (blood single screen, train banner, home/Discover) — DONE b293 — OWNER_FIXES_3NOV_0255.md
- 3 Nov 03:30 website hero + fixes; Play pack same headline — DONE (live; shots refresh IN PROGRESS, agent siteshots)
- 3 Nov 04:00 master order — see top
- Personal Secretary (PS: Today brief, circle people, pick-up sheet) — DONE b290 (board 58; Play notification-listener finding in card) — FEATURE_CARD_PERSONAL_SECRETARY_BN.md
- 3 Nov camera disclosure before phone camera; contrast fix — DONE b290
- Builds 288, 290, 291, 293 are on Play (internal + closed testing); b293 server migrations 0142-0145 live; 292 content ships inside 293

## OWNER BACKLOG ORDER 2 Nov (real state)
### 0) Always first: owner phone-test bugs + launch blockers
- Guardian +45 min consent, saved places != anti-theft safe places (agent/jdec) — DONE (merged before b280)
- 8 Nov launch: switch list, entry-point leaks, AI-off honesty, Play production checklist (agent/launch, playaudit2, flipready) — DONE docs/tests; owner flips switches + Play steps — WAITING FOR OWNER
- Any owner phone-test bug report jumps here — standing
### 0.5 CCTV / Vehicle / Safe Journey to 100 (cctv100, veh100b, journey100b)
- CCTV: see P1 (board 10 rows, no real-camera proof) — IN PROGRESS (cctvcap, cctvaicheck)
- Vehicle tracking (board 9 rows avg 57.1; live map 43, car-mode 44) — IN PROGRESS, no real GPS device proof
- Safe Journey (journey100b, journeymode) — DONE b293, board 75-89, needs owner real-phone proof
### 1) Owner first priority
1. A1 My Circle links/preview/safe-link, Family/Others, many-to-many guardians (circlea, finish1) — DONE (board 63-70)
2. A2 Missing person alert + found-share (missing) — DONE code (board 55/50), no 2-phone proof
3. B Blood donor panel + urgent requests (blood, finish1) — DONE code (board 62); old simple screen removed b293
4. C Train tracker + chat + destination alarm (train, journeymode) — DONE code; banner ads DONE b293; 16318 schedule check in Owner Admin DONE; owner real-phone proof pending
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
- 3.3 Service guide — DONE code (p3guides 3 Nov; board 68): /guides bug fixed (advanced content now reaches the phone), official sources + last-checked + published fees only, e-namjari; owner: fee screenshots from a BD network
- 3.4 Daily info and services — PARTIAL (lifebar, board rows 24-70)
- 3.5 Ramadan tracker (deadline Jan 2027) — PARTIAL (ramadan screen/calendar/alarms exist; no board row)
- 3.6 Quran Majid — NOT STARTED (needs licensed text + audio)
- 3.7 Probashi corner — DONE code behind flag official_corners (p3guides; board 63 visible): Help tab helplines/welfare/real cost/SOS abroad; owner 2-phone test pending
- 3.8 Student corner — DONE code behind flag official_corners (p3guides; board 61 visible): study timer + official dates/save-a-deadline; exam watcher kept
- 3.9 Travel Planner — PARTIAL (board 49)
- 3.10 Wedding and events — PARTIAL (screen+engine exist; no board row)
- 3.11 Ride and Food — PARTIAL (board 63, opens partner apps)
- 3.12 Farmer mode — PARTIAL+ (p3farm 3 Nov: Help tab, sourced crop calendar, symptom picker/AI photo, 16123, honest DAM; DAM feed + vision key + real phone left)
- 3.13 Unseen World / Unseen Bangladesh — WAITING FOR OWNER (FEATURE_CARD_UNSEEN_WORLD_BN.md: site ownership + option A/B/C); Unseen Bangladesh board 66
- 3.14 My Circle community + channels — channels/communities DONE b288 (62); further plan WAITING FOR OWNER explanation

## Standing orders still in force (details in owner_actions/OWNER_*.md and memory)
- Owner final order 2 Nov: launch ALL features 8 Nov at Silicon Valley standard; guard = p95>400 ms or swap -> pause newest agent; daily 21:00 BD report
- Definition of Done (owner_actions/DEFINITION_OF_DONE_BN.md), Master quality order, Feature excellence rule, 100% mode, Maximum mode (owner_actions/OWNER_FINAL_ORDER_27OCT.md)
- Agent Core (Part 2 of 27 Oct order): owner_actions/AGENT_CORE_DESIGN_BN.md; flag agent_core OFF; AI keys: owner adds
- Billing hardening (owner_actions/BILLING_ORDER_27OCT.md), call bugs (b287 done), home frozen (v2; v6 behind home_v2)
- Daily: STATUS_FOR_OWNER.md top = short Bangla summary; 3 Bangla lines per published build

## OWNER ADMIN SUPPORT/SAFETY/STATS (3 Nov 04:22) — after CCTV P1
Full text: owner_actions/OWNER_ADMIN_SUPPORT_ORDER_3NOV.md. adminsafe — DONE b293 (stats + filters + trend, user detail, appeals, staff roles, bans, DATA_MINIMISATION_BN.md; board users 85, audit/security 80; migration 0145). WAITING FOR OWNER: privacy page OK (PRIVACY_UPDATE_DRAFT_BN.md), AI keys, real-device tests.
