# Owner work queue (newest order wins)

**STANDING RULE (owner, 22 Oct):** when a question has a safe, reversible Recommended option, pick it, note it in STATUS, keep working. Ask the owner only for irreversible, money, legal or security decisions.

**PERMANENT RULE (owner, 22 Oct) — ALL ANDROID PHONES:** the app must work on every Android phone common in Bangladesh — OPPO, Realme, Xiaomi/Redmi/POCO, Samsung, vivo, Walton, Symphony, Infinix/Tecno — Android 8 to 16. Secure storage must fall back (Keystore failures never break identity/chats); Crashlytics + Owner Admin → Reports (device model + OS + error, NO message content/PII); Firebase Test Lab device matrix + robo (login → My Circle → chat → send → call screen) before each My Circle build, pass/fail per device in STATUS; OEM background guide once after login.
D. [SHIPPED: 191 SecretStore/IdentityVault emergency (user 18 PROVEN: key + 5 queued msgs delivered/read + reply), 192 Crashlytics+Owner Reports+OEM guide+deletion UX+free calls, 193 dead-button sweep (CI). Test Lab workflow ready — BLOCKED on owner GCP_TESTLAB_SA. AGENT mr1: message requests + full last-seen + hide media-gated attach] [AGENTS sc1, tl1] Evidence: user 18 (OPPO Reno 12 F 5G, ColorOS) on build 188 never POSTs /circle/keys; 15 key_request pushes unanswered.

**ORDER OF WORK (owner, 22 Oct evening):** finish My Circle FIRST — E1 OPPO secure-storage key fix (integrator, IdentityVault) + deletion UX + Free calls switch (agent dl1) in ONE emergency build; then message requests like WhatsApp, messages never wait on keys, full last-seen time, Crashlytics (sc1), device matrix (tl1). When My Circle passes, continue the rest of QUEUE automatically — ship each item with proof + Bangla 3-line STATUS.
E. [DONE 22 Oct] user 18 deletion cancelled (owner order), notifications removed, account + My Circle link intact.
F. [AGENT dl1] FREE CALLS (testing): My Circle voice+video calls 0 credits for all plans incl. relayed minutes; Owner Admin switch 'Free calls (testing)' = ON; keep relay cost in P&L.

G2. [SHIPPED 197] media follow-ups: group media forward (same blob), send-to-poll bubble flicker, preview labels.
G. [SHIPPED build 196 + backend live (0066, nginx internal location, live blob proof)] MY CIRCLE E2E MEDIA (photo, voice note, document, video if reliable): encrypt on device, ciphertext blob via signed URLs, key inside the E2E message, quotas + retention; attach button stays hidden until each kind truly works. (from mr1 design note)
H. [SHIPPED/IN CI] mr1: message requests like WhatsApp + full last-seen + media showpieces hidden (live smoke passed with test accounts A/C). DECISION (reversible, noted in STATUS): default 'who can message me' = My Circle now lets people with your number send a REQUEST (WhatsApp-like); 'nobody' blocks strangers.

## ORDER 6 — GAME CHANGERS (owner, 23 Oct, FINAL) — CURRENT TOP PRIORITY after the Play AAB [AAB DELIVERED: 1.0.209/10209]
G+ NIGHT SALESMAN (owner add-on to G, Business plan only, verbatim): (1) IMAGE UNDERSTANDING: when a customer sends a photo or screenshot, use a vision model to match it to the seller catalog (image embeddings of product photos + vision description); if matched, reply with name, price, sizes, colours, stock; if not, show the 2-3 closest products with photos. Also read size charts and text in images (address, phone). (2) AUTONOMOUS ORDER: collect name, phone, address, size/colour, show a full summary with delivery charge and total, ask the customer to confirm, then create the order, reduce stock, book the courier, send the order number. Polite upsell of a matching product, bundle/free-delivery rules from seller settings. (3) Payment screenshots: NEVER confirm payment from a screenshot (fake screenshots are common); mark the order payment-pending and tell the customer the owner will verify. COD by default. (4) Night mode setting and a morning summary push to the owner: orders, revenue, pending approvals, unanswered questions. (5) Cost: vision replies cost more credits (set in Owner Admin -> Pricing), Profit Guard shows cost per image. (6) Keep all safety: min price in code, number post-check, approval queue, human takeover, AI disclosure. Prove with a test page: image -> match -> order -> courier, screenshots in STATUS (Bangla).
G++ RULE-FIRST (owner, high priority, verbatim): (1) RULE-FIRST layer like Asalify: answer FAQ, price, stock, delivery charge, size, colour, shop hours and order status from the seller catalog/settings WITHOUT calling the AI (instant, cost 0, no credit used); call the AI only when rules do not match. Owner Admin must show percent of replies answered by rules vs AI and the money saved. (2) Read Asalify docs/MESSAGING_AI_SYSTEM.md and its bot code as READ-ONLY reference (never change Asalify config, services or DB) and port anything Asalify does better; write a Bangla comparison table in STATUS: Asalify vs Assisto, what we took, what Assisto already does better. (3) Keep all existing safety: min price locked in code, number post-check, approval queue. [Asalify source = private GitHub repo ArifSarkar247/asalify, read-only clone only]
G+ CORRECTION (owner, verbatim, supersedes 'Night mode' in Night Salesman): the agent works 24/7 by DEFAULT, not only at night. Owner/staff can take over any time: (1) when a human sends a reply in a chat (from Assisto or directly from the Page/WhatsApp, detected via message_echoes), the AI pauses in THAT chat only; (2) if the human goes silent and the customer is waiting, the AI resumes after a timeout the seller sets (default 15 minutes); (3) per-chat toggle: I will reply / Let AI reply; (4) business-wide mode switch: AI always on (default) / only outside business hours / off. Never two replies at once. Morning summary stays. Prove: human reply pauses AI, AI resumes after timeout, toggle works; screenshots in STATUS (Bangla).
Agents: A+B Photo Studio v2 [d1-photo agent, brief extended]; C+D+E video-call UI, chat themes, nicknames [next slot]; F wake every showpiece [after]; G advanced Business AI Agent [after]. Earlier queue (F design agent f1 running, group calls b3 built, P4 in checks) continues behind it.
```
ORDER 6 - GAME CHANGERS (FINAL, replaces any earlier order6/6b/pricing message). Start right after the Play AAB is delivered; the AAB stays first. Use parallel agents.

A. PHOTO STUDIO v2 - must BEAT Remini in a blind test, not just match it. Do whatever it takes.
 1. ENHANCE server-side: face detect -> dedicated face restoration -> full-image upscale/denoise -> FACE LOCK identity check. Choose the best models available NOW. Every model and weight must allow commercial use - list each license in STATUS; no non-commercial weights (check CodeFormer, InsightFace etc. carefully).
    - Runs in a SEPARATE worker process/instance with a queue; the main API must never slow down. Free tier uses the same best open models on our own worker (cost per image = 0, just slower). Premium = fast path (GPU on demand or best hosted API), up to 4K.
    - On-device enhance stays only as an offline fallback.
 2. PROMPT EDIT like ChatGPT/Gemini: photo + Bangla or English prompt -> new image. Provider switchable in Owner Admin (e.g. Nano Banana 2 / GPT Image 2 / Flux 2); default = best identity preservation.
 3. FACE LOCK (our USP): after every AI output, measure face identity similarity vs the original with a commercial-licensed method. Below threshold -> paste the ORIGINAL face back with seamless blending + light/colour match, or re-run as masked inpainting that never touches the face. Promise: "your face stays yours". Show a Face Lock badge.
 4. One-tap templates: HD portrait, old photo restore + colourize, passport/visa sizes, professional/LinkedIn, Eid/Puja/wedding outfits, studio background, product photo for shops.
 5. PROOF: 50 licensed/consented test photos (low light, old, group, dark skin tones) -> ours vs Remini -> blind A/B vote page in Owner Admin + identity score + sharpness metrics. Report honestly. Never claim "better than Remini" anywhere until the blind test proves it.
 6. Safety + Play AI policy: block sexual/undressing edits, suggestive edits of minors, realistic fakes of other real people without consent; in-app "report this AI image" button (Google Play AI-generated content policy); "Edited with AI" in saved metadata.

B. PHOTO STUDIO PRICING (owner decision; every number editable in Owner Admin -> Pricing):
 - FREE ENHANCE: 3 per day, each unlocked by 1 rewarded ad. After 3 -> Premium paywall.
 - FREE AI GENERATION (Face Lock): 2 free in the user's lifetime. After that 1 per week, unlocked only after watching at least 3 rewarded ads; use the highest-paying ad network/placement available. Profit Guard must show AI cost vs ad revenue per free user and alert me if the free tier loses money.
 - PREMIUM: unlimited instant enhance up to 4K, no ads, monthly AI credits, extra credit packs.
 - No ads on safety, SOS, payment, login or call screens. Credits are never withdrawable as cash.

C. VIDEO CALL like WhatsApp: tap the small self-view to swap big/small, drag the small view to any corner, pinch-to-zoom, double-tap fullscreen, flip camera, camera on/off visible to the other side. Prove on 2 real phones.

D. CHAT THEMES - REAL, not a showpiece (owner says the current theme does not work):
 - Per-chat theme that BOTH sides see instantly (theme synced through the chat; system line "X changed the theme").
 - A small curated set of really beautiful themes (about 8-10): love/romantic (hearts, roses, moon & stars), gradient, calm, dark, nature, festival (Eid, birthday, anniversary), each with matching bubble colours and quick-reaction emoji.
 - Custom theme from the user's own photo (sent end-to-end encrypted like media; dimmed so text stays readable). AI theme from a prompt with Face Lock (credits).
 - Free: a few themes; Premium: all + custom + AI.
 - Proof: two real phones see the same theme, after restart, on OPPO/ColorOS too; screenshots of both phones in STATUS.

E. NICKNAMES (Messenger-style), 1:1 and groups:
 - Either person can set, change or remove a nickname for themselves or for the other person; both sides see it instantly; system line "X set the nickname for Y to ..." / "X removed the nickname".
 - Nickname shows in the chat header, chat list, notifications and call screen; the real name stays visible in profile/info. Synced across reinstall and devices.

F. WAKE UP EVERY SHOWPIECE: go through REALITY_AUDIT (all C and D items) and every screen that looks finished but does not really work. For each: make it really work end-to-end with proof, OR hide it from the UI until it does. Nothing fake visible to users. Report a Bangla table: feature -> now works / hidden / needs owner key.

G. BUSINESS AI AGENT - advanced (paid Business plan):
 - One inbox for WhatsApp Business (Cloud API), Facebook Messenger, Instagram DM and a website chat widget. Asalify's proven WhatsApp + Messenger agent is READ-ONLY reference; never touch Asalify config, services or DB.
 - Understands Bangla, Banglish, English, voice notes (transcribe) and product photos (match to catalog).
 - Answers only from real catalog price/stock; takes the order in chat -> creates the order in Assisto -> optional courier booking.
 - Facebook comment-to-DM ("price?" under a post -> reply in inbox). Follow-ups for silent customers. Learns tone/FAQ from the owner's past replies. Human takeover any time. Quiet hours.
 - Report: chats, orders, revenue the agent brought, AI cost, profit.
 - No payment collection inside Assisto for now (Play financial declaration says the app does not move money).
 - List exactly which parts need Meta app review or owner keys.

Each part: real proof (tests + 2 real phones where relevant), Bangla 3-line STATUS, owner tasks listed clearly. Never commit secrets; DB backup before migrations.
```

## MASTER STRATEGY 23 Oct (owner, ~/order3.txt) — INCOME FIRST; overrides the A-F order's sequence
MERGED ORDER: 1) A My Circle bugs [agent a1 running] -> 2) P1 Business AI Agent [next free slot] -> 3) P2 monetization -> 4) P3 My Circle differentiators -> 5) P4 Unseen World -> 6) B calls [b1 batch running: wrapping up B1/B2/B6 + flow-18 fix], D Photo Studio, F design, C themes, E gaps -> 7) P5 growth. P6 BUSINESS_PLAN_BN.md written early (doc) [integrator writing now].
Done today: pricing nothing-unlimited (Premium 90/mo) + disk alert 80% [build 203, backend LIVE]; reality audit 202 [b26ccc0]; C4 POS sale/void now A (run 39946885424).
```
OWNER MASTER STRATEGY 23 Oct - INCOME FIRST. Assisto = Bangla super-app + real AI agent.
Profit must beat cost every day; nothing unlimited; credits + Profit Guard on every AI/API
cost; no showpieces; follow laws + Google Play + Meta policies; never touch Asalify.

NEW PRIORITY ORDER (merge with today's A-F order):
1) Finish A (My Circle bugs) -> 2) P1 Business AI Agent -> 3) P2 monetization ->
4) P3 My Circle differentiators -> 5) P4 Unseen World -> 6) B calls, D Photo Studio,
F design, C themes, E gaps -> 7) P5 growth + P6 business plan (write P6 early, it is a doc).

P1. ASSISTO BUSINESS AI AGENT for Bangladeshi F-commerce sellers (main revenue):
 - Connect Facebook Page (Messenger + comments), Instagram DM, WhatsApp Business (Cloud API).
 - AI replies 24/7 in Bangla/Banglish/English from the seller's product catalog, prices,
   stock, delivery charges, policies; takes orders, confirms COD, collects address/phone.
 - Courier booking + tracking: Pathao, Steadfast, RedX (official merchant APIs, keys in
   Admin); invoice to customer; daily sales/orders report; low-stock alert.
 - Human handover button, seller approves risky replies, never invents prices/stock.
 - Plans for sellers (e.g. Starter/Pro by monthly AI replies), 7-day free trial, credit
   packs; Profit Guard per AI reply + per WhatsApp conversation cost.
 - Owner steps in Bangla (owner_actions/BUSINESS_AGENT_SETUP.md): Meta developer app,
   business verification, App Review for page messaging permissions, WhatsApp Business
   number, courier merchant accounts. Build + test with sandboxes/test pages until then.
 - Later (doc only now): integration API so Asalify / AXON ERP shops can connect.

P2. MONETIZATION (free plan only; never on safety, payment, login, call screens):
 - App Open ad: from day 2 after signup, max 3 per day, skippable after 5 s; all caps
   editable in Owner Admin so I can raise/lower them.
 - Home hero native ad (exists), Telegram-style "Sponsored" post at the end of large
   communities/channels (Admin threshold), rewarded ads for credits.
 - Direct sponsors first: brand offers + Discover cards sold by me via Owner Admin
   (price, dates, audience, reports); AdMob fills empty slots.
 - Brand offers by interest: users pick favourite brands/categories; max 2 offer
   notifications/day; mute any brand.
 - Premium must be worth buying: list the premium-only benefits clearly, paywall at
   the moment of need, 3-day trial, yearly discount within the safe margin.
 - P&L per placement + uninstall/retention impact.

P3. MY CIRCLE = WhatsApp + AI assistant + family safety:
 - "@Assisto" inside chats/groups: summarize unread, set reminders for everyone, split a
   bill, make a shopping list, translate, answer questions (credits).
 - Family safety links: missed medicine alert to family, safe-arrival, SOS, lost phone,
   scam message warning inside chats.
 - Stories (24 h) + profile Notes in the Updates tab, privacy controls.

P4. UNSEEN WORLD (everything in one place, Bangla, voice):
 - AI answers anything with LIVE web search + cited sources (search API key in Admin,
   credits per answer).
 - Daily cards (user can turn each on/off): live cricket/football scores (licensed API,
   cost shown), currency rates, gold, fuel, weather, prayer times, news headlines +
   snippet + link only (reputable outlets, never copy articles), world news too.
 - Jobs hub (link out, never copy): bpsc.gov.bd, Bdjobs.com, alljobs.teletalk.com.bd,
   erecruitment.bb.org.bd, LinkedIn.com/jobs, boesl.gov.bd, Chakri.com,
   Careerjet.com.bd, Bangladesh.gov.bd, ngoforum.org.bd; job-type alerts where a lawful
   feed exists.
 - Hubs: Expats (visa, remittance, overseas jobs, country rules), Students (SSC/HSC/
   admission/BCS practice), Farmers (crop photo -> disease + treatment, with "ask an
   agri officer" note), Government services (passport, NID, birth cert, land: steps,
   documents, fees, links, AI help filling forms), Health helpers (prescription reader,
   medicine price; always "consult a doctor").

P5. GROWTH: referral (invite -> credits for both), share AI answers/cards with Assisto
   branding, Founding Members, Facebook page content kit; Owner Admin funnel: installs,
   activation, D1/D7/D30 retention, paying users, revenue per user.

P6. owner_actions/BUSINESS_PLAN_BN.md (Bangla): who pays and why, pricing, unit
   economics per plan, 12-month revenue scenarios (honest assumptions), first 10,000
   users plan, partners to sign (payments, couriers, tickets, brands), risks, and a
   1-page investor summary.

Each part: real proof (tests + live), Bangla 3-line STATUS, owner tasks listed clearly.
```

## NEW ORDER 23 Oct (owner, ~/order.txt) — DO FIRST, in order A, B, C, D, F, E
Status: A [agent a1 starting], B-F [queued]. Pricing (no unlimited, Premium 90) + disk alert 80% [agent pr1]. Reality audit 202 [DONE b26ccc0].
```
OWNER ORDER 23 Oct - My Circle polish + calls like WhatsApp/Messenger + chat themes +
Photo Studio like Remini + Silicon Valley design. Order: A, B, C, D, F, E.

A. BUGS from my phone (build 202):
 1. Chat list shows "Abul Kashem" TWICE (one with messages, one "No messages yet") - merge
    duplicate threads/edges (request thread vs circle edge); one row per person, always.
 2. Chat list preview shows "Encrypted message" instead of the decrypted last message - fix
    on-device preview decryption (incl. after a key change).
 3. Header still shows "last seen today at..." cut off - full time must be visible
    (shorten the name first; 2 lines or marquee). Test 360 dp, bn + en.
 4. Call events must appear INSIDE the chat like WhatsApp ("Missed voice call 10:05",
    "Video call 3:12") with tap to call back.

B. CALLS (must match WhatsApp/Messenger):
 1. Switch voice -> video during a call (request + accept on the other side) and back.
 2. Mute mic, camera on/off, flip camera, speaker/earpiece/Bluetooth; each person sees
    who has camera/mic off.
 3. Add people during a call -> group call; group voice/video calls from groups. Use a
    self-hosted SFU (e.g. LiveKit, Apache-2.0) on our server for 3+ people; 1:1 stays P2P.
    Active speaker, grid, host can mute others, leave/rejoin.
 4. Screen share during a call (Android MediaProjection, foreground service, clear banner).
 5. Call recording ONLY with consent: asking person requests, everyone must accept,
    visible "Recording" banner for all, saved encrypted on the requester's phone only,
    legal note in Privacy Policy (bn + en). No silent recording ever.
 6. Picture-in-picture, call quality indicator, reconnect on network change.
 Measure server cost (SFU bandwidth) in P&L; respect the "Free calls (testing)" switch.

C. CHAT THEMES like Messenger:
 1. A default premium-looking chat theme (bubbles, background, typography) in light/dark.
 2. Per-chat themes: 10+ ready themes (colour gradients, bubble colours, wallpapers incl.
    Bangla-inspired designs), custom colour + own photo wallpaper; both sides see the
    chosen theme (synced), with a "Theme changed" note in the chat.

D. PHOTO STUDIO like Remini, but better - the on-device enhance FAILED on my phone:
 1. Find and fix the root cause first (report in STATUS with device + error).
 2. Feature set (our OWN licence-clean models only - never copy Remini code, models,
    design or brand): Enhance face (face restoration), Unblur/deblur, Old photo restore,
    Colorize B/W, Upscale 2x/4x, Denoise, Low-light fix, Background blur, Before/after
    slider, batch of photos. Candidates (check licences for commercial use): Real-ESRGAN
    (BSD), NAFNet (MIT), DDColor (Apache-2.0), SwinIR (Apache-2.0), GFPGAN only if weights
    allow; NOT CodeFormer (non-commercial).
 3. Light tasks on-device (free to us); heavy tasks on our server or a pay-per-use GPU
    API behind Admin keys, charged in credits/ads with Profit Guard - never a loss.
 4. Face must stay the same person; never change identity. Results in < 10 s on a
    mid-range phone for light tasks; show progress; never a fake result.
 5. Compare our results side by side with Remini on 20 test photos (portraits, old,
    blurry, low light) and report honestly in STATUS.

F. APP-WIDE DESIGN UPGRADE to Silicon Valley standard (owner order; home screen look may
   change too, but keep its structure):
 1. Typography: English = Inter; Bangla = compare Hind Siliguri vs Noto Sans Bengali (also
    Anek Bangla) on real screens and pick the best; all fonts bundled (OFL), never
    downloaded at runtime. One clear type scale (display, title, body, label, caption),
    correct Bangla line-height so letters never clip, tabular figures for amounts/times.
 2. Design system: colour tokens (light + dark, WCAG AA contrast), 4/8 pt spacing, radius,
    elevation, one icon set (Material Symbols Rounded or Phosphor, same weight everywhere),
    consistent buttons, inputs, cards, lists, sheets, empty states, loading skeletons,
    smooth 150-300 ms motion. No random colours or sizes anywhere.
 3. Apply to ALL screens (316): My Circle and call screens first, then home, Assisto AI
    chat, Photo Studio, settings, business tools.
 4. Accessibility: works at 200% font size, screen reader labels, tap targets >= 48 dp.
 5. Proof: before/after screenshots of the 30 most-used screens (bn + en, light + dark) in
    .phaseB/design_shots/ + Bangla summary in STATUS. Show home + My Circle before/after
    first; continue with the rest without waiting.

E. DO MORE ON YOUR OWN: compare My Circle with WhatsApp, Messenger and Telegram, write a
   gap table (feature | them | us | plan) in owner_actions/MYCIRCLE_GAPS_BN.md and build the
   high-value missing ones (e.g. chat lock, disappearing messages, view-once media, pinned/
   archived chats, polls, message search, voice note speed), each one really working.

Rules: no showpieces, prove each part (tests + live), Bangla 3-line STATUS per build.
```

## MASTER ORDER 22 Oct (single source of truth; earlier orders below are history)
Rules: max parallel agents (own worktree each), heavy cmds via lock, ship each part immediately, deploy each backend after checks (standing approval), max 1 h on CI problems (gate = release cold start + backend tests + route_check; note missing proof), commit hourly, never idle, blockers in Bangla at top of STATUS, 3 Bangla lines per build.

MY CIRCLE MASTER ORDER (22 Oct, after build 183 real-phone tests) — supersedes all earlier My Circle items. SHIP ORDER: Build A as soon as proven → Build B. Do not hold A for B.
A. [SHIPPED build 187 + backend live + LIVE PROOF PASSED (calls relay/direct; ticks server-side 0.14/0.10 s; runner 2.3/1.6 s = network distance). MISSING PROOF: two real phones] [EMERGENCY — agents x1-calls, x2-ticks] A1 calls (root cause: every call POSTed twice by the same phone → duplicate ends 'busy' → Busy + Missed rows; ICE rarely connected; relayed=False always, coturn 0 allocations, no TLS 5349): idempotent start + glare merge, busy only when really active, signalling <1 s, early-ICE queue, ICE restart, 20 s fail both sides, stale sweeps + cron + one-time cleanup, grouped log, TURN probe from outside (AWS SG). A2 ticks: delivered via FCM background ack <2 s, read only when visible <1 s, grey/grey/bright-blue + darker outgoing bubble, Message info real times (read receipts: user 3 on, user 20 default). A3 profile photos everywhere. A4 proof against LIVE server + LIVE TURN from a GitHub runner (relay + direct, 30 s audio both ways, ticks timings).
B. [PUSHED as build 188 (CI) + backend live: 0060_e2_keys, Photo Studio model installed] [agents e2-keys, b2-badges (in CI), t1-ticks, p2-photo, s2-showpieces] B1 keys per user + outbox (BEFORE: 2 accepted pairs, 1 missing a key — 3↔18). B2 chat opens at latest (reversed, unread divider, paged), date chips + floating date, header name/status line, Search in ⋮, E2E notice as first history item (not pinned). B3 badges repair + sum rule + bell clear (b2 build). B4 legacy tick info + min-version gate. B5 NO SHOWPIECES: Photo Studio real on-device enhance, FLAG_SECURE, identity check, prompt section hidden without key, Hey Assisto hidden, Discover rename (b2), list every removed text in STATUS.
Each build: deploy backend (backup → migrate → restart), Bangla 3-line STATUS, two-phone checklist. Parallel: wake word (training in CI). PAYMENTS [BUILT; integrating as Build C with TURN scale-up (agent integ-c); needs owner EPS + Play keys] [AGENT pay1, decided 22 Oct]: Play Billing first (Play flavour) + EPS gateway (eps.com.bd — owner amendment, NOT SSLCommerz; bKash/Nagad/cards), provider-agnostic gateway layer, no QR; checkout sheet, Play subs + credit packs with server verification + RTDN, EPS hosted checkout + server-to-server verification + signed callback, prepaid gateway periods + reminders, website /premium with OTP login, one entitlement service, owner per-channel kill-switch (same options for everyone), P&L per channel, PAYMENTS_SETUP.md (Bangla, incl. Play policy risk note), sandbox proof. After Build A.
T. [LIVE 22 Oct] TURN debug + scale-up: quota root cause fixed, ports 49152-65535, TLS 5349, bps-capacity ceiling removed (total-quota 1200), outside probe UDP/TCP/TLS pass; list/monitor/alerts/relay cost in Build C; CALL_SCALING.md.
1. [SHIPPED build 176 + backend deployed] My Circle like WhatsApp (add any format/phonebook/QR/link, requests, messages, voice+video calls, FCM ringing closed app) + settings-store release fix + Phone Safety spinner fix. MISSING PROOF: native tour + two-account emulator audit (hosted emulator wedges adb) — re-run when CI stable.
2. [DONE 22 Oct] Owner account: owner confirmed id 3 (Arif, 01784056199) → superuser + staff (backup first, AuditLog entry). Superusers: Owner (13) + id 3.
3. [BUILT, in builds] OTP flow (provider-agnostic, key-gated) + owner_actions/SMS_GATEWAY_NEEDS.md (Bangla). Needs SMS gateway keys.
4. [SHIPPED build 177] Voice assistant: default assistant (long-press power), optional Hey Assisto (needs Picovoice key), YouTube/YT Music, hands-free, TTS, bn/Banglish/en.
5. [LIVE 22 Oct] Web Owner Admin Panel https://api.lifeassisto.com/owner/ (migration 0051_o2; login steps in STATUS, Bangla).
6. [SHIPPED build 178: Photo Studio; home hero + image in chat merged, next] Photo Studio + home ad hero (remove suggestions, muted hero) + image in chat.
7. [vehicle OBD SHIPPED build 179; webphoto next] Vehicle app part (live map, 24h playback, engine cut-off rules, geofence/over-speed, OBD, Car Mode) — verify completeness; website passport funnel.
8. [NOT IN THIS SESSION] Remote support — owner's full spec saved in .phaseB/REMOTE_SUPPORT_SPEC.md; the first launch here was stopped by a safety system before it ran, so it must be built in a separate session.
9. [Batch 6 SHIPPED build 195 + backend 0065] [CCTV live + Shop Box mode SHIPPED build 180] [b6r READY (agent/b6r 00f2517: intruder photo real, no Keystore, Kotlin compiled) — ships right after My Circle; migration re-chain to 0065] [AGENT b6-antitheft, spec .phaseB/BATCH6_ORDER.md] Batch 6 native lost/stolen engine (opt-in, own phone: heartbeat, snatch, SIM/airplane/battery/shutdown guards, intruder photo, store-and-forward) + [READY cctv] CCTV live view + Android Shop Box mode.
10. [SHIPPED 197: QA avg 8.98, below-9 78->8 (rest explained in QA_REPORT_BN.md); reality audit runs (31 flows, 61 real shots); rt1 SHIPPED 198: C 18->1, 4 real bugs fixed; rt2 SHIPPED 199: honest 5xx text, rt logging, cart/add 500 fix, per-group matrix; emulator still dies (RenderThread; guest/swiftshader both) - 1h CI cap hit, parked; 17_circle "exactly one candidate" = harness bug (ended call screen has Close, no back button) fixed in flow, no CI rerun; ty1 SHIPPED 200: realtime loop in safe mode + harness (typing/in-app ring); qa2 MERGED -> build 201: last 7 screens 8->9 (avg 9.00), 100+ screens honest 5xx] Premium QA every screen >=9/10, full reality audit with real runs, owner phone checklist.
L. [SHIPPED build 185: legal pages live (AXON ERP Software, Mumbai), signed Play AAB in CI, app-ads.txt 200, PLAY_STORE_PACK.md; owner still owes [ADDRESS] + AdMob publisher ID] LAUNCH TRACK [AGENT]: Privacy Policy / Terms / Data Deletion pages on lifeassisto.com (bn+en, Play + AdMob compliant, every permission explained); app-ads.txt ready for the AdMob publisher ID; owner_actions/PLAY_STORE_PACK.md (name, short/full description bn+en, feature graphic, 8 screenshots, content rating + Data Safety, permission declarations); signed release AAB per release in CI + upload key + Play App Signing plan.
L2. [SHIPPED build 185] [AGENT f1-founders] FOUNDING TESTERS: owner admin action grants "Founding Member" (free Premium N months, admin-editable default 12, + badge) to a pasted list of accounts (first 12–20 Play closed testers); in-app "Send feedback / report a problem" (screenshot + note) landing in the owner admin panel.
L3. [SHIPPED 202: UMP consent gate + Settings ad-privacy tile + Owner EEA debug switch; off until AdMob linked (a6 apply + owner AdMob ID + GDPR message)] Google UMP consent flow for AdMob (EEA/UK/Switzerland) — then re-add those countries in Play.
L4. [ww2 DONE: conversion fixed (agent/ww2), full training ok, NOT ship-ready (TV/music FA 20/10h); ww3 MERGED (tools only): TV FA 3/10h (target <1), bn 0/10h, far FRR 7.8% synthetic, ship_ready=false; NEXT needs owner HF_TOKEN (AI4Bharat Kathbath/Shrutilipi) + real recordings; owner: real voice clips later; app integration needs clamp 0.9999 + ship_ready gate]  [AGENT k1-wake] "Hey Assisto" wake word on openWakeWord (Picovoice removed): custom model trained in a CI workflow, opt-in mic FGS + disclosure, auto-pause, locked-phone rules, reboot honesty, OEM guide, default-assistant step, Play declaration; real-phone proof before shipping.
Also queued: [hc1 MERGED 0f39297, in all builds since] Health Connect plugin fails to register (MainActivity must become FlutterFragmentActivity) — own native build (the HC privacy activity is now in the launch build).

## History

0. (old) Final order 21 Oct: 1 → 2 (+contract test) → 4 (FCM) → 3 (reality audit) → 5 (voice assistant) → 6 (vehicle) → 7.
1. 21-Oct NIGHT order (replaces the order above): 1 broken links + contract CI → 2 sidebar/auto voice → 2b DISCOVER MANAGER → 3 FCM + un-park workflows → 4 OTP → 5 reality audit → 6 voice assistant → 7 Photo Studio → 8 vehicle → 9 remote support → Batch 6 → CCTV live + Shop Box → Premium QA. Max 3 agents.
0a. MY CIRCLE LIKE WHATSAPP (top priority, current build): FCM + contacts + New chat / Add to My Circle / requests / no silent failures / Phone Safety Check-up loading fix; ships only after the two-account emulator proof (agent m3-circle).
0b. WEB OWNER ADMIN PANEL at https://api.lifeassisto.com/owner/ — RIGHT AFTER the My Circle build (agent o2-admin building). Owner tried the URL: Not Found (expected — not deployed yet). Superuser login + mandatory TOTP 2FA + recovery codes, HTTPS only, rate-limited, audit log; sections: Discover manager (cards, sponsors, images, schedule, audience, CTR reports, CSV/PDF), Pricing & plans & credits, Profit Guard + P&L, Ads settings (caps, hero ad, sound), Integrations/API keys, Users (search, plan, credits, block), Reports; bn + en. Needs nginx /owner/ location → :8700. When live: tell the owner in Bangla (URL + login steps, owner_actions/OWNER_ADMIN_PANEL.md).
   Decision done 21 Oct: SPONSORED cards reach every plan (always labelled), AdMob Free-only — LIVE.
1a. OWNER BUG — CONTACTS ON ASSISTO IS A FACADE (top priority right after the current build): agent c1-contacts.
   - Root causes: permission stub always true + phonebook never read (no plugin); UserPhoneHash never created; no phone normalisation (exact-string match).
   - Fix: E.164 canonical phone everywhere + data migration; UserPhoneHash on register/phone change + backfill; admin flag allow-unverified-matching (ON test, OFF at launch); contacts plugin + READ_CONTACTS + prominent disclosure (native build, needs workflow scope); WhatsApp-style On Assisto / Invite; search any format.
   - Stays C in the Reality Audit until the two-phone test passes (01865052200 searched as +880 1865-052200 / 8801865052200 / 01865052200).
1b. DISCOVER MANAGER + SPONSORED CARDS (owner, 21 Oct night; right after priority 2):
   - Link fix axonerp.com → https://axonerpsoftware.com: DONE in build 148.
   - Admin panel: cards CRUD + reorder + enable; image/icon; bn+en title/desc; action = in-app route (picker) or external URL; start/end datetime; audience all/Free/Premium/Business; optional min app version.
   - Types: FEATURE, OUR PRODUCT (Asalify https://asalify.com, AXON ERP https://axonerpsoftware.com, label "Our products"), SPONSORED (always labelled "Sponsored"), ADMOB slot (free only, fills when no sponsored booked).
   - Rules: Premium/Business never see SPONSORED/AdMob; never on safety screens; content safety check (no scams/gambling/adult/fake claims).
   - Sponsor reporting: impressions/clicks/CTR per card per day; CSV/PDF export; sponsor revenue per card → owner P&L dashboard.
   - App: server fetch + offline cache (last set), auto-rotate as now, tap tracking; hard-coded list only as first-run fallback.
   - Real E2E test: admin adds card → appears without update; expires on end date; audience respected. 3 Bangla lines.
2. PHOTO STUDIO — queued right AFTER the voice assistant ships (owner order 21 Oct, replaces all earlier Photo Studio messages).
   Full text of the order is in the session; key constraints:
   - One-tap on-device enhance, no API key; commercially-licensed models only (Real-ESRGAN BSD-3 ok; CodeFormer NON-commercial → never; verify GFPGAN + every weight) → .phaseB/MODEL_LICENSES.md.
   - Prompt edit/generate via switchable, key-gated cloud adapter (Gemini / OpenAI image / Replicate-class); keys + cost/image in OWNER_UNLOCK_LIST.md.
   - Face-lock compositing for scene edits; beauty retouch only within allowed list; identity guard (ArcFace-class + landmarks) on every result; original kept, undo + history.
   - Ads: entry interstitial (≤1 per 30 min, admin-editable); every export path gated by rewarded ads for free users; watermarked reduced preview + FLAG_SECURE; no free bypass on no-fill; Profit Guard makes loss-making edits impossible (tests); owner dashboard.
   - Safety refusals (sexual/undressing, fake compromising scenes, ID/document/money/seal edits), child caution, consent reminder, AI-edit metadata.
   - Ship with 3 Bangla lines + before/after gallery examples; Reality Audit A/B/C/D on emulator.
