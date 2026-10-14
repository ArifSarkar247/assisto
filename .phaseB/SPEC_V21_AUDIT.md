# ASSISTO — SPEC v2.1 GAP AUDIT + BUILD BACKLOG

Source of truth: **ASSISTO_SPEC_v2.pdf** (v2.1 FINAL, 36 pages, 2026-10-14) — supersedes ASSISTO_SPEC.pdf.
Cross-referenced against: `.phaseB/STATUS_MATRIX.md`, `ASSISTO_REPORT.md` (through build 64 + Messenger v3 + CRM complete + Business v2 + Safe Journey + 6 first-P10 upgrades), and a live codebase sanity-check (`backend/core/logic/`, `backend/core/plans.py`, `app/lib/screens/`, `app/lib/widgets/sidebar_sections.dart`).
Rule: READ-ONLY. No code/build/migrate. Asalify untouched.

Grades: **advanced** (reviewer-passed to Section-21 standard) · **good** (built, below advanced) · **basic** (P10-era thin / model-API-only / stub UI) · **not built** · **owner-blocked** (needs external key/account — logic present, no-key path correct).

---

## SECTION 21 — "ADVANCED" STANDARD (the gate for EVERY module)

A module is **complete only when it meets all 10** (spec p.24). These are the acceptance criteria used to grade Appendix A and to accept every v2.1 build:

1. Side-by-side comparison with the best app in its category — **equal or better** on every core task.
2. The **full task flow** end to end (not just view: create / edit / delete / search / filter / export).
3. **Both input rails** — auto + manual — with an "AI-captured" marker on every AI entry.
4. **Empty / loading / tool / offline** states all designed (nothing raw).
5. Strict **bn / en**, light / dark, small & large screens all correct.
6. Wired into **reminders + watch feed + chat**; runnable **by voice**.
7. **Server + app automated tests**, including real-world **scenario** tests.
8. A **share card / result card** wherever it fits.
9. **Privacy + consent** rules honoured; actions written to the **audit log**.
10. Passes an **independent reviewer** (owner requirement before it counts as advanced).

> Every v2.1-NEW item below must also clear these 10. "Built" ≠ "advanced".

---

## 1. APPENDIX A — 201 FEATURES: GRADE + COUNTS

Appendix A lists **201 numbered features** (#1–201; the intro line's "209" is a typo — the table is 1→201). Graded against current code.

### COUNTS PER GRADE

| Grade | Count |
|---|---|
| **advanced** | **38** |
| **good** | **61** |
| **basic** | **28** |
| **not built** | **61** |
| **owner-blocked** (pure; no built layer) | **13** |
| **TOTAL** | **201** |

> Reconciliation with STATUS_MATRIX (48 *modules*): the matrix groups features into 48 modules; Appendix A explodes them into 201 line-items, so each module's sub-features inherit/split the grade. Net: **~99 at advanced-or-good, ~102 below-advanced** (28 basic + 61 not-built + 13 owner-blocked). The 61 "not built" are dominated by the **PA-mode (Section 14, 23 items)**, **Section 20 owner additions (20 items)**, and **Daily-Life / health v2.1 additions** — none of which existed before v2.1.
>
> Note on owner-blocked: features whose built no-key layer is real (Agent Studio surface, AI Inbox classify, Business WhatsApp mock, Job tailor, Photo engine) are graded on that layer (basic/good), NOT counted in the 13. The 13 "pure owner-blocked" are features that are *only* a needs-key state (e.g. Smart Home / Google Home-Tuya #46, Star-PA Social Inbox #123, Instagram/FB-page bits, live-voice).

### BELOW-ADVANCED FULL LIST = THE BACKLOG (English)

Grouped by Appendix-A section. Each line: `#id name — grade`.

**AI Agent core (#1–19)**
- #2 Strict language split — good
- #4 Personal Memory — good
- #5 "What AI knows about me" page — good
- #6 Proactive AI & Watch feed — basic (watch feed thin)
- #7 Morning brief & night summary — not built
- #8 Autonomy dial — good
- #9 Action center & audit log — good
- #10 Profession role-play (Personas) — owner-blocked (AI key)
- #11 Mental support & meditation — owner-blocked (AI key)
- #12 Offline-first — good
- #13 Voice mode (live conversation) — not built
- #14 Natural voice / own voice (voice-clone) — not built / owner-blocked (voice-clone key)
- #15 Voice mood sensing (on-device) — not built
- #16 AI Personas — owner-blocked (AI key)
- #17 Quick tools (summarise/grammar/translate/tone/share) — not built
- #18 Saved / bookmarks — not built
- #19 Dark / light toggle — good (exists; raise to advanced polish)

**Reminders & Memory (#20–27)**
- #21 Task manager (projects/board/assign/progress) — not built (as a manager; basic todos exist)
- #26 Life Scanner — owner-blocked (OCR/AI key)
- #22 Calendar & notes — good · #23 Birthdays — good · #24 Meetings — good · #25 Medicine reminder & follow-up — good · #27 Kid's school (notice→fees/exam/PTM) — not built

**Daily Life (#28–46)**
- #29 Document scanner (OCR, multi-page PDF) — not built
- #30 Contract analyzer — not built (owner-blocked AI key)
- #33 Local service finder — not built
- #34 Market price radar — not built
- #35 Travel planner — not built
- #36 Cost / time estimator — not built
- #28 Documents vault — advanced (already) · #32 Nearby — basic · #31 Govt service guide — basic · #37 Medicine DB — good · #38 Health tips — good · #39 Dictionary — good · #40 Photo enhance — good (owner-blocked engine) · #41 Unseen World — good · #42 Ride/food — good · #43 Religious times & zakat — good (Ramadan) · #44 Disaster alerts — good (watch) · #45 Watch/alerts — basic · #46 Smart Home (Google Home/Tuya) — owner-blocked (device keys) / not built

**My Account (#47–63)**
- #50 Budget & next-month plan — good (part of Money) · #48 Income-expense — advanced · #49 Monthly statement — advanced
- #51 AI spending advice — not built
- #55 Subscriptions — basic
- #56 Bill guide & payment ladder — not built (UI; backend done) / owner-blocked (payment partner)
- #57 Finance tools (66 calculators) — basic
- #59 Net worth — basic (part of finance)
- #60 Income-tax & zakat helper — good
- #61 Family accounting — good (Family) · #62 Voice questions — good · #63 Monthly Wrapped — good · #52 Loan ledger — advanced · #53 EMI — basic (finance) · #54 Savings goals — basic (finance) · #58 Savings & investment — basic (finance)

**Family & Health (#64–75)**
- #68 Elderly simple mode — not built (UI; flag only)
- #69 Health timeline — not built
- #70 Smartwatch & fitness (Health Connect) — not built (owner-blocked native)
- #71 Water / sleep / diet — not built
- #72 Fitness partner — not built
- #74 Nominee / family access — basic
- #64 Family Care mode — advanced · #65 SMS/IVR backup — owner-blocked (IVR/SMS key) · #66 Connected Circle — advanced · #67 Family selective sharing — good · #73 Family card — good · #75 Probashi family — good

**Safety (#76–83)** — mostly strong
- #76 Emergency card — basic · #77 SOS — basic · #78 Accident/fall detect — good (native sensor owner-blocked) · #79 Voice emergency alert — basic (voice SOS native not built) · #80 Phone lost/stolen protection — not built · #81 Scam alert — advanced · #82 Scam checker — advanced · #83 Safe Journey (19 items) — advanced

**Messenger (#84–97)** — v3 just built
- All of #84–97 (group chat, media, msg actions, chat organise, Status, voice call, video call, call settings, call transcription, community, channel, msg requests, privacy, in-chat AI) — **good** (built this session, pending reviewer pass to advanced). #92 Call & voice-note transcription — not built (owner-blocked transcription key).

**Contacts & Profile (#98–102)**
- #100 Contacts & Personal CRM — basic · #98 Profile — good · #99 Contact match — good · #101 Invite — good · #102 Referral points — good

**PA Secretary (#103–125) — SECTION 14, 23 items — ENTIRELY NOT BUILT**
- #103 Schedule control · #104 Meeting reminder & brief · #105 Visitor/appointment filter · #106 Call & email handling · #107 Letters/notices/memos · #108 Liaison & follow-up · #109 Filing · #110 Meeting minutes · #111 Privacy (role-based, delegate access) · #112 Travel & itinerary · #113 Expense voucher · #114 Research & presentation · #115 Personal-task oversight · #116 Corp: board-meeting pack · #117 Corp: departmental update · #118 Corp: VIP & stakeholder · #119 Corp: business travel & events · #120 Corp: project tracking · #121 Star: deals & offers · #122 Star: PR & press · #123 Star: social inbox (FB/IG API) · #124 Star: shooting/concert logistics · #125 Star: lifestyle. — **ALL not built** (several owner-blocked: AI key, Instagram/FB-page API, booking partner).

**Agent Studio / Inbox / Jobs (#126–140)**
- #126 Excel sheet — owner-blocked (AI key) · #127 Applications/letters/invoice/slide — owner-blocked (AI) · #128 CV & cover letter — basic (owner-blocked tailor) · #129 Job Hunter agent — basic · #130 Blog & script writing — not built · #131 Mock interview — not built · #132 Language-learning partner — not built · #133 Telegram bot builder — not built (owner-blocked sandbox) · #134 Small-business landing page — owner-blocked (AI) · #135 Social-media post & caption — good · #136 AI Inbox — basic (owner-blocked fetch) · #137 Email assistant — owner-blocked (Gmail scope) · #138 Message read & reply — owner-blocked (notification-listener native) · #139 High-priority keyword alert — basic · #140 Meeting bot — not built (owner-blocked)

**Business (#141–152)** — v2 advanced
- #141 Digital khata · #142 Cashbox · #143 Products & stock · #144 Supplier & wholesale market · #145 Demand map · #146 Selling & orders · #147 AI sales assistant · #148 Bargain / min-price lock · #149 Human hand-off · #150 Auto-reply & follow-up · #151 Reports · #152 Multi-shop & staff — **all advanced** EXCEPT **#144 Supplier/wholesale market — not built** and **#145 Demand map — not built** (new v2.1 items; rest advanced).

**CRM (#153–166)** — complete this session
- #153–166 all **advanced** (Today/10-sec-log/omnichannel-capture/pipeline/scoring/WhatsApp/company360/quotes/after-sale/team/automation/reports/ERP-handoff/offline-multitenant-audit). WhatsApp & ERP handoff owner-blocked at the live-key boundary (mock correct).

**Web growth tools (#167–173)**
- #167 CV score · #168 Scam checker web · #169 Photo maker · #170 Festival card · #171 Savings challenge · #172 "Made in 30s" · #173 Daily challenge & quiz — **#167–170 good** (4 web tools built); **#171, #172, #173 not built**.

**Admin (#174–181)**
- #174 User info · #175 Complaint & moderation queue · #176 Integration page · #177 Analytics dashboard · #178 Cost kill-switch & feature flags · #179 Server-address swap · #180 In-app update · #181 In-app support — **all good** (admin surfaces built build 64 + integrations admin advanced; moderation panel built with messenger v3). Raise to advanced on reviewer pass.

**Section 20 owner additions "20 more life tasks" (#182–201) — MOSTLY NOT BUILT**
- #182 Mess & bachelor accounting — not built
- #183 Expense splitting (Splitwise-style) — not built
- #184 Samity / committee (rotating fund) — not built
- #185 Landlord-tenant — not built
- #186 Domestic staff / driver — not built
- #187 Doctor serial/appointment — not built
- #188 Blood-donor network — not built
- #189 Wedding & events — not built
- #190 Qurbani & Eid — not built
- #191 Probashi corner — not built (Probashi plan exists; this feature set does not)
- #192 Student corner — not built
- #193 Electricity & gas (prepaid meter) — not built
- #194 Area community — not built (overlaps messenger communities; dedicated not built)
- #195 AI phone call (AI dials for you) — not built (owner-blocked voice-call key)
- #196 Widget & watch (home/lock/Wear OS) — not built (native)
- #197 Encrypted backup & phone transfer — not built
- #198 Digital security check-up — not built
- #199 Farmer / village mode — not built
- #200 True accessibility (TalkBack/large-touch/captions) — not built (as a mode; base a11y partial)
- #201 Trust / proof page (data location, requests) — not built (overlaps privacy analytics; dedicated page not built)

---

### ২.ক — অ্যাডভান্সডের নিচের তালিকা (বাংলা) — মালিকের জন্য ব্যাকলগ

(গ্রেড: advanced এর নিচে সব আইটেম, বিভাগ অনুযায়ী)

**AI এজেন্ট কোর:** কঠোর ভাষা-বিভাজন (good), Personal Memory (good), "AI আমার সম্পর্কে কী জানে" পাতা (good), Proactive AI ও ওয়াচ ফিড (basic), **সকালের ব্রিফিং ও রাতের সারাংশ (তৈরি হয়নি)**, স্বাধীনতার ধাপ (good), অ্যাকশন সেন্টার ও অডিট লগ (good), **পেশা অনুযায়ী রোল-প্লে (key লাগবে)**, **মানসিক সাপোর্ট ও মেডিটেশন (key)**, অফলাইন-প্রথম (good), **ভয়েস মোড লাইভ কথোপকথন (তৈরি হয়নি)**, **প্রাকৃতিক কণ্ঠ/নিজের কণ্ঠ ক্লোন (তৈরি হয়নি/key)**, **কণ্ঠের মেজাজ বোঝা (তৈরি হয়নি)**, **AI চরিত্র Personas (key)**, **কুইক টুলস (তৈরি হয়নি)**, **সেভড/বুকমার্ক (তৈরি হয়নি)**, ডার্ক/লাইট (good)।

**রিমাইন্ডার ও মেমোরি:** **টাস্ক ম্যানেজার (তৈরি হয়নি)**, ক্যালেন্ডার/নোট (good), জন্মদিন (good), মিটিং (good), ওষুধ ফলো-আপ (good), **Life Scanner (key)**, **বাচ্চার স্কুল নোটিস (তৈরি হয়নি)**।

**দৈনন্দিন জীবন:** **ডকুমেন্ট স্ক্যানার (তৈরি হয়নি)**, **চুক্তিপত্র বিশ্লেষক (তৈরি হয়নি/key)**, কাছাকাছি (basic), সরকারি সেবা গাইড (basic), **লোকাল সার্ভিস খোঁজা (তৈরি হয়নি)**, **বাজারদর রাডার (তৈরি হয়নি)**, **ভ্রমণ পরিকল্পনাকারী (তৈরি হয়নি)**, **খরচ ও সময় প্রাক্কলন (তৈরি হয়নি)**, ওষুধ তথ্য (good), স্বাস্থ্য টিপস (good), অভিধান (good), ছবি উন্নত (good/key), Unseen World (good), রাইড/খাবার (good), ধর্মীয় সময় ও জাকাত (good), দুর্যোগ সতর্কতা (good), নজরদারি/অ্যালার্ট (basic), **স্মার্ট হোম (key/তৈরি হয়নি)**।

**আমার হিসাব:** **AI খরচ-পরামর্শ (তৈরি হয়নি)**, সাবস্ক্রিপশন (basic), **বিল গাইড ও পেমেন্ট ল্যাডার (UI তৈরি হয়নি/key)**, ফিনান্স টুলস (basic), নিট সম্পদ (basic), আয়কর ও জাকাত (good), পরিবারের হিসাব (good), ঋণ/কিস্তি EMI (basic), সঞ্চয়ের লক্ষ্য (basic), সঞ্চয় ও বিনিয়োগ (basic)।

**পরিবার ও স্বাস্থ্য:** **বয়স্কদের সহজ মোড (UI তৈরি হয়নি)**, **হেলথ টাইমলাইন (তৈরি হয়নি)**, **স্মার্টওয়াচ ও ফিটনেস (তৈরি হয়নি)**, **পানি/ঘুম/ডায়েট (তৈরি হয়নি)**, **ফিটনেস পার্টনার (তৈরি হয়নি)**, নমিনি (basic), SMS/IVR ব্যাকআপ (key), ফ্যামিলি সিলেক্টিভ শেয়ারিং (good), ফ্যামিলি কার্ড (good), প্রবাসী পরিবার (good)।

**নিরাপত্তা:** ইমার্জেন্সি কার্ড (basic), SOS (basic), ভয়েস জরুরি অ্যালার্ট (basic), **ফোন হারালে/চুরি সুরক্ষা (তৈরি হয়নি)**, দুর্ঘটনা শনাক্ত (good)।

**মেসেঞ্জার (v3):** সব আইটেম (good — এই সেশনে তৈরি, রিভিউয়ার পাস বাকি), **কল/ভয়েস-নোট ট্রান্সক্রিপশন (key)**।

**কন্টাক্টস:** কন্টাক্টস ও পার্সোনাল CRM (basic), প্রোফাইল (good), রেফারেল (good)।

**PA সেক্রেটারি (সেকশন ১৪, ২৩টি — পুরোটাই তৈরি হয়নি):** শিডিউল নিয়ন্ত্রণ, মিটিং রিমাইন্ডার ও ব্রিফ, সাক্ষাৎপ্রার্থী ফিল্টার, কল ও ইমেইল সামলানো, চিঠি/নোটিস/মেমো, লিয়াজোঁ ও ফলো-আপ, ফাইলিং, মিটিংয়ের কার্যবিবরণী, গোপনীয়তা/ডেলিগেট অ্যাক্সেস, ভ্রমণ ও ভ্রমণসূচি, খরচের ভাউচার, রিসার্চ ও প্রেজেন্টেশন, ব্যক্তিগত কাজ তদারকি, কর্পোরেট: বোর্ড প্যাক, বিভাগীয় আপডেট, VIP ও স্টেকহোল্ডার, বিজনেস ট্রাভেল ও ইভেন্ট, প্রজেক্ট ট্র্যাকিং; তারকা: ডিল ও অফার, PR ও প্রেস, সোশ্যাল ইনবক্স (key), শুটিং/কনসার্ট লজিস্টিকস, লাইফস্টাইল।

**এজেন্ট স্টুডিও/ইনবক্স/চাকরি:** Excel শিট (key), দরখাস্ত/চিঠি/স্লাইড (key), CV ও কভার লেটার (basic/key), জব হান্টার (basic), **ব্লগ ও স্ক্রিপ্ট রাইটিং (তৈরি হয়নি)**, **মক ইন্টারভিউ (তৈরি হয়নি)**, **ভাষা শেখার সঙ্গী (তৈরি হয়নি)**, **Telegram bot নির্মাতা (key/তৈরি হয়নি)**, ছোট ব্যবসার ল্যান্ডিং পেজ (key), সোশ্যাল পোস্ট (good), AI Inbox (basic), ইমেইল সহকারী (key), মেসেজ পড়া ও উত্তর (key), হাই-প্রায়োরিটি অ্যালার্ট (basic), **মিটিং বট (তৈরি হয়নি/key)**।

**ব্যবসা:** **সাপ্লায়ার ও পাইকারি বাজার (তৈরি হয়নি)**, **চাহিদার মানচিত্র (তৈরি হয়নি)**।

**ওয়েব গ্রোথ টুল:** **সঞ্চয় বাজ ও ৩০ দিনের চ্যালেঞ্জ (তৈরি হয়নি)**, **"৩০ সেকেন্ডে AI বানিয়ে দিল" (তৈরি হয়নি)**, **দৈনিক চ্যালেঞ্জ ও কুইজ (তৈরি হয়নি)**।

**অ্যাডমিন:** সব সার্ফেস good (রিভিউয়ার পাসে advanced)।

**সেকশন ২০ — মালিকের আরও ২০টি কাজ (প্রায় সবই তৈরি হয়নি):** মেস ও ব্যাচেলর হিসাব, খরচ ভাগাভাগি, সমিতি ও কমিটি, বাড়িওয়ালা-ভাড়াটিয়া, গৃহকর্মী ও ড্রাইভার, ডাক্তারের সিরিয়াল, রক্তদাতা নেটওয়ার্ক, বিয়ে ও অনুষ্ঠান, কুরবানি ও ঈদ, প্রবাসী কর্নার, ছাত্র কর্নার, বিদ্যুৎ ও গ্যাস, এলাকার কমিউনিটি, AI দিয়ে ফোন কল (key), উইজেট ও ঘড়ি (native), এনক্রিপ্টেড ব্যাকআপ ও ফোন বদল, ডিজিটাল নিরাপত্তা চেক-আপ, কৃষক ও গ্রামের মোড, সত্যিকার অ্যাক্সেসিবিলিটি, বিশ্বাসের প্রমাণ পাতা।

---

## 3. V2.1 NEW ITEMS — BUILD BACKLOG (grouped, one line each)

Everything v2.1 added on top of v2.0. `[🔑 X]` = needs an external key/service → goes to **owner_actions**, built **mock/sandbox** until the key arrives.

### A. SECTION 14 — PA SECRETARY MODE (23 items, Premium/Business; ALL NOT BUILT)
1. Schedule control (daily/weekly/monthly appts, conflict detect, free-slot finder, booking links) — Premium
2. Meeting reminder & 1-page brief (who's coming, prior talks, files) — Premium
3. Visitor/appointment filter (reason, priority, time after boss-approval) — Premium
4. Call & email handling (reply drafts for approval; answer AI-number calls) — Premium
5. Letters / notices / memos (institutional drafts, letterhead & staff templates) — Premium
6. Liaison & follow-up ("who owes what by when" tracker + drafts) — Premium
7. Filing (auto-classify contracts/docs, search, expiry reminders) — Premium
8. Meeting minutes (decisions/owners/deadlines; staff PDF) — Premium
9. Privacy (role-based access, audit log, delegate-access for human PA) — Premium
10. Travel & itinerary (flight/train/hotel options + booking [🔑 booking partner]; local commute) — Premium
11. Expense voucher (official + travel receipt scan, categorise, accounts report) — Premium
12. Research & presentation (pre-meeting info + slide drafts) — Premium [🔑 AI]
13. Personal-task oversight (doctor serial, gift buying, family-event appts) — Premium
14. Corporate: board-meeting pack (data+PPT+minutes in one) — Business
15. Corporate: departmental update (HR/Finance/Marketing scheduled pulls + summary) — Business
16. Corporate: VIP & stakeholder (investor/partner/VIP profiles, schedule, hospitality checklist) — Business
17. Corporate: business travel & events (domestic/intl trips, conf/event logistics) — Business
18. Corporate: project tracking (subordinate deadlines, delay alerts) — Business
19. Star: deals & offers (cinema/song/ad/show offers + scripts, date-conflict) — Premium
20. Star: PR & press (interviews, pressers, photoshoot schedule, journalist list) — Premium
21. Star: social inbox (FB Page + Instagram DMs via official API, priority sort, reply drafts, fan mail) — Premium [🔑 Instagram/FB Page API]
22. Star: shooting & concert logistics (costume/makeup/security/car/crew checklist) — Premium
23. Star: lifestyle (diet meals, gym/trainer, designer trials, shopping) — Premium

### B. AI CORE ADDITIONS (Section 6 v2.1)
- Voice mode — live conversation screen (interrupt mid-sentence, Bangla voice replies) — all plans — **not built** [🔑 AI, optional live-voice]
- Natural voice / own-voice clone (voice select; clone only user's own, verified) — Premium — **not built** [🔑 voice-clone]
- Voice mood sensing (on-device tone→soft reply, no diagnosis, nothing stored) — Premium — **not built** (on-device)
- AI Personas (profession-swap: mentor/trainer/coding/teacher/advisor; custom personas) — Premium — **not built** [🔑 AI]
- Quick tools (one-tap summarise / grammar-fix / translate / tone-change / share) — all plans — **not built** [🔑 AI]
- Saved / bookmarks (save any AI reply or chat slice; folders & tags; search) — all plans — **not built**
- Dark / light toggle (sidebar one-tap OR follow phone theme) — all plans — good (exists, polish)
- Morning brief & night summary ("today": AM Bangla voice of calendar/weather/commute/urgent + curated news; PM day-recap + tomorrow prep) — all plans — **not built**
- Offline-cache expansion (emergency notes/contacts/savings list, todos, reminders, docs, money, basic voice cmds offline) — all plans — good (expand coverage)

### C. DAILY LIFE ADDITIONS (Section 8 v2.1) — ALL NOT BUILT
- Document scanner (edge-detect, deskew, multi-page→PDF, Bangla+English OCR, AI edit/summarise/analyse) — all plans [🔑 OCR/AI]
- Contract analyzer (rent/job/service PDF→plain Bangla, risky-clause highlight, expiry/renewal reminder, "not legal advice") — Premium [🔑 AI]
- Market price radar (rice/dal/oil/veg wholesale+retail official & market sources w/ dates, nearby offers, anti-scam band) — all plans [🔑 price/news source]
- Travel planner (destination+days+budget→itinerary, hotel list, sights, transport, packing list, ticket/booking reminders) — all plans [🔑 AI; optional booking partner]
- Local service finder (mechanic/plumber/electrician/AC/cleaner → one-tap call, appointment from app) — all plans [🔑 directory/maps]
- Cost / time estimator (rough budget+schedule for small business / event / construction; editable assumptions) — Premium [🔑 AI]

### D. HEALTH / LIFESTYLE ADDITIONS (Section 10 v2.1) — NOT BUILT
- Water / sleep / diet (daily water goal+reminders, sleep habit, calorie & nutrition log — auto via photo or manual) — all plans [🔑 OCR for food photo]
- Fitness partner (home/gym workout routine, correct-form guide for bodyweight, progress; "not medical advice") — Premium [🔑 AI]
- Health timeline (prescriptions/reports/doctor by date; one-tap history to new doctor; follow-up reminders) — Premium
- Smartwatch & fitness (Android Health Connect: heart rate, sleep, steps; diet/calorie log) — Premium (native Health Connect)
- Elderly simple mode (big buttons, fewer buttons, voice-only, child sets settings remotely, one-tap call & SOS) — Family — **not built (UI)**

### E. STANDALONE NEW FEATURES (scattered across sections)
- Task manager (#21: projects & lists, deadlines, priority, board view, assign-to-others, progress; linked to reminders) — all plans — **not built**
- AI spending advice (#51: pattern→"eating-out +40% this month", where to cut, hit savings-goal faster) — all plans — **not built** [🔑 AI]
- Voice SOS (#79 native: "Assisto, বিপদ!" → alert family+friends w/ location + 999 one-tap, hands-free) — all plans — **basic** (voice cmds basic; native trigger not built)
- Lost / stolen phone protection (#80: repeated wrong-PIN/SIM-swap/power-off → send location to emergency contacts; show thief photo; remote ring & lock; last-location after wipe) — all plans — **not built** (native device-admin)
- Call & voice-note transcription (#92: both parties notified, voice-note & meeting→text + key-points summary; normal mobile calls NOT recorded per Android policy) — Premium — **not built** [🔑 transcription]
- Blog & script writing (#130: YouTube script / blog post / article — outline→full draft) — Premium — **not built** [🔑 AI]
- Mock interview (#131: voice/text interview for a role, per-answer score + improvement tips) — Premium — **not built** [🔑 AI]
- Language-learning partner (#132: English/Arabic etc. practice sessions, pronunciation fix, quizzes; work-language for expat workers) — Premium — **not built** [🔑 AI]
- Supplier & wholesale market (#144: supplier/wholesale lists by business type — Chawkbazar/Moulvibazar/Islampur — own supplier khata, price compare) — Business — **not built**
- Demand map (#145: where is demand for a product — domestic regional trends + ITC-Trade-Map-style export sources w/ dates) — Business — **not built** [🔑 trade-data source]
- Daily challenges / quiz (#173: small quizzes, daily tasks, streak & badges; earns referral points) — all plans — **not built**

### F. SECTION 20 — OWNER'S "20 MORE LIFE TASKS" (#182–201; ALL NOT BUILT; sit on top of existing Money/Reminders/Messenger/Family — no separate apps)
1. Mess & bachelor accounting (meal count, bazar rotation, month-end who-owes-what) — all plans
2. Expense splitting (tour/office-lunch/flat-bill, Splitwise-style one-tap settle) — all plans
3. Samity / committee (monthly instalment, rotation, who-collects, who's due — digital samity khata) — all plans
4. Landlord-tenant (tenant list, monthly rent collection, digital receipts, utility split, lease expiry) — all plans
5. Domestic staff / driver (salary, advance, leave, attendance, Eid-bonus reminders) — all plans
6. Doctor serial/appointment (serial no., chamber time, "your serial is near" alert, prescription→pharmacy order [🔑 partner]) — all plans
7. Blood-donor network (consented donor groups by area, last-donation date, urgent request to community — most-shareable post) — all plans
8. Wedding & events (budget, guest list, digital invite card, task list, gift accounting) — all plans
9. Qurbani & Eid (cow share, who-gives-how-much, budget, Eid shopping list, home-trip ticket reminder) — all plans
10. Probashi corner (remittance-rate compare, passport/visa/work-permit expiry, two-timezone scheduled family calls) — all plans
11. Student corner (class & exam routine, result alert, scholarship/admission circulars, tuition-fee accounting) — all plans
12. Electricity & gas (prepaid-meter low-balance reminder, load-shedding schedule, gas-cylinder refill estimate) — all plans
13. Area community (lost & found, urgent notices, local news, complaint-based moderation) — all plans [overlaps messenger communities]
14. AI phone call (with permission AI dials to take a doctor serial / find a shop; states upfront it's an AI assistant) — Premium — [🔑 AI voice-call]
15. Widget & clock (home/lock-screen widget: today's tasks, budget, meds; Wear OS reminders & SOS) — Premium — (native)
16. Encrypted backup & phone transfer (encrypted backup to user's own Google Drive, restore all on new phone one-tap) — all plans [🔑 Drive OAuth]
17. Digital security check-up (parents' phone: screen-lock, 2FA, suspicious apps? → simple report for the child) — all plans
18. Farmer / village mode (voice-first, weather, market price, agri-advice govt sources; low-data) — all plans
19. True accessibility (TalkBack, screen reader, colour-blind themes, large touch targets, captions on all videos) — all plans
20. Trust / proof page (where data lives, who can see, how many govt requests received — plain-Bangla transparency report) — all plans

> **PA mode**, **Section 14 corporate/star**, and several Daily-Life/Health items are **Premium/Business gated** and **AI-key-gated** — build the UX + mock responses now; wire live on key arrival.

---

## 4. VERIFY vs CURRENT — DISCREPANCIES TO FIX

### 4a. SECTION 4 — SIDEBAR (spec p.5 vs `app/lib/widgets/sidebar_sections.dart`)

Spec sidebar sections: **Chat(home)** · **Messenger** · **Reminders & Memory** · **Daily Life** · **My Account** · **Family & Safety** · **Work** · **Business** · **CRM** · **Contacts & Profile** · **Settings**.

Current code sections: `messages` · `reminders_memory` · `my_account` · `family` · `safety` · `health` · `daily_life` · `work` · `business(+crm)`.

| # | Spec says | Code has | Status |
|---|---|---|---|
| 1 | Chat (home) is the landing, NOT a sidebar section | home_screen is landing; sidebar top = New chat (app_drawer) | OK (verify app_drawer renders New-chat + search at top) |
| 2 | **Daily Life** should contain **Documents, Govt guide, Nearby, Medicine-info, Health tips, Dictionary, photo, travel, ride/food** | Code splits **Health** into its OWN section (Medicine DB + Health tips) separate from Daily Life | **DISCREPANCY** — spec folds health-info into Daily Life; code has a standalone "Health" section. Decide: match spec (merge Health→Daily Life) OR keep Health split (owner previously approved richer grouping). FLAG to owner. |
| 3 | **Family & Safety** = ONE section (Connected Circle, Family Care, Safe Journey, SOS, Emergency card, Nominee) | Code has **two** sections: `family` (Family/Contacts/Nominee) + `safety` (Journey/Emergency/Scam/Fall) | **DISCREPANCY** — spec merges Family+Safety; code keeps them separate. Also **Contacts is under Family in code** but spec puts Contacts in its own **"Contacts & Profile"** section. FLAG. |
| 4 | **Contacts & Profile** = its own section (Profile, Contacts, Invite, Referral) | Code: Contacts under `family`; Profile/Referral rendered by app_drawer bottom, no dedicated section | **DISCREPANCY** — no "Contacts & Profile" sidebar section; Contacts mis-placed under Family. FLAG. |
| 5 | **Work** = Agent Studio, AI Inbox, Job hunter, **PA Secretary** | Code `work`: Agent Studio, Jobs, Inbox — **no PA Secretary** | **DISCREPANCY** — PA Secretary (Section 14) missing from Work section (because not built). Add when PA mode ships. |
| 6 | **CRM** should be its own top-level sidebar section (Today/Leads/Pipeline/Company/Quotes/Team/Reports) | Code: CRM is an item inside the **Business** section | Minor — spec lists CRM as a sibling section (#17 TOC) but functionally Business. Acceptable; FLAG as cosmetic. |
| 7 | Messenger = "Messages" at TOP of sidebar | Code: `messages` section pinned at index 0 | OK ✓ |
| 8 | Settings bottom: language, theme, permissions, privacy, autonomy-dial, subscription, support, **dark/light toggle** | app_drawer bottom: Settings(+In-progress+Connected apps), Plans&points, Profile | OK (verify dark/light toggle + autonomy dial exposed) |

**Net sidebar diffs to fix:** (a) Health section vs spec's Daily-Life fold; (b) Family + Safety are two sections, spec wants one "Family & Safety"; (c) no dedicated "Contacts & Profile" section (Contacts mis-grouped under Family); (d) PA Secretary absent from Work (build-gated). Items (a)–(c) are regroupings the owner should confirm — the earlier owner-approved grouping (SIDEBAR_LAYOUT.md) predates v2.1; **v2.1 Section 4 is the newer source — reconcile and re-confirm with owner.**

### 4b. SECTION 25 — PLAN GATES (spec p.27 vs `backend/core/plans.py` + `circle_calls.can_place_call`)

| Rule (spec) | Code | Status |
|---|---|---|
| Text + voice calls **free, unlimited, all plans** | `can_place_call`: voice allowed for any accepted non-blocked pair | OK ✓ |
| Video call **Premium, caller-pays** (caller/creator premium, receiver free, server-gated) | `can_place_call`: video gated on CALLER's plan only; referral `video_unlocked` override; client can't force kind=video | OK ✓ |
| Safe Journey + SOS **free on ALL plans** | Free-plan benefits list includes "Emergency SOS & scam alerts (free)"; journey logic not plan-gated | OK ✓ (verify journey endpoints have no plan gate) |
| Referral points → **Premium days** | `referral.py`: points redeem for Premium days, 3-condition gate | OK ✓ |
| **Premium price ৳849/mo** | `plans.py` premium `"price": 149` | **❌ DISCREPANCY — ৳149 vs spec ৳849** |
| **Family price ৳1299/mo** | `plans.py` family `"price": 299` | **❌ DISCREPANCY — ৳299 vs spec ৳1299** |
| Probashi **$4.99/mo** | `plans.py` `4.99 USD` | OK ✓ |
| Business **৳1,999/mo** | `plans.py` `1999 BDT` | OK ✓ |
| Annual Premium **৳8,499** (annual = ~2 months free on ৳849) | `plans.py` annual `"price": 1199` | **❌ DISCREPANCY — ৳1199 vs spec implies ~৳8499** |
| Free plan AI credits: spec "a few AI credits/month" (~5 scans + chats table p.28) | `plans.py` free `"credits": 15` | Minor — spec p.28 table says ~5 scans; free lists 15 credits. FLAG (credits≠scans; confirm mapping). |
| Business: 500 conversations free then ৳63/extra + WhatsApp charge | Not visibly encoded in plans.py benefits | **GAP — per-conversation Business overage (৳63) not represented.** Verify in business_views / wallet. |
| Credit top-up ৳20–50 (reward-ad → 8 extra AI scans) | Not in plans.py | **GAP — credit top-up / rewarded-ad pack not represented.** |

**Top plan discrepancies:** Premium **৳149 should be ৳849**, Family **৳299 should be ৳1299**, Annual **৳1199 should be ~৳8499**. These are the headline fixes. (Prices are owner-set — confirm the spec numbers are final before editing, since the earlier build intentionally used lower launch pricing. **FLAG to owner: spec v2.1 lists ৳849/৳1299 — is that the launch price or aspirational?**)

### 4c. SECTION 22 — LEGAL / PRIVACY RULES (spec p.25) — compliance checklist

All are **honoured in design** per STATUS_MATRIX owner-checks; verify at ship:
- Outside actions need confirmation; never send money from voice alone (voice-clone risk) — OK (autonomy dial + confirm gate).
- Payment: only Bangladesh-Bank-licensed partner, per-bill cap, prior notice, after-receipt, one-tap stop-all auto-pay — **payment partner owner-blocked**; ladder UI not built (fix in #56).
- Google Play: no READ_SMS; Notification-Listener + Share-sheet only; no Accessibility-Service abuse; clear disclosure; policy-check before lock. — OK (design); verify disclosure screens exist.
- Gmail: read scope = Google "restricted scope" → needs security assessment — owner-blocked.
- WhatsApp/Meta: official Cloud API + Business Verification only; never automate personal WhatsApp. — OK (mock; owner-blocked live).
- Messenger: E2E; admins never see msg/contacts; contacts hash-matched; community/channel moderation complaint-based. — OK (verified in msg logic).
- Location: only user-chosen people in Safe Journey/SOS; auto-delete after trip; history self-expires. — OK.
- Health/mental: "not medical advice" banner; crisis → helpline + trusted humans. — OK (verify banner on every health screen incl new water/sleep/fitness).
- Photo/identity: edit own photos only; no face-swap of others; no fake govt docs. — OK (photo enhance).
- Data: never sold; encrypted; sensitive data on-device where possible; ads non-personalised & never on sensitive screens; one-click export (PDF/Excel) + delete-all; breach→notify within 24h. — OK (verify export + delete-all live; breach-notify process = owner-review doc).
- 18+ accounts; minors get guardian-limited mode; no "girlfriend/boyfriend" AI. — **verify age-gate enforced**; Personas must exclude romantic AI.
- Phone security: Device-Admin permission disclosure; photo captured only with user consent. — tied to #80 (not built).
- Contract analyzer: "comprehension aid only, not legal advice"; important decisions → lawyer. — tied to #30 (not built; include banner).

**Legal discrepancies to fix:** none are violations; the **gaps are features not yet built** that carry mandatory banners/consent (payment ladder stop-all UI #56, phone-security disclosure #80, contract-analyzer legal banner #30, "not medical advice" on new health items, romantic-AI exclusion in Personas, one-click delete-all + 24h breach-notify process). Add these at build time.

---

## 5. KEY-GATED INVENTORY → owner_actions (Appendix B + derived)

From spec Appendix B (p.36) plus features mapped above. Each → `owner_actions`; feature built **mock/sandbox** until key present.

| Key / service | Gates these features |
|---|---|
| **AI API key (Claude / Gemini / OpenAI, billing)** | ALL AI: chat agent, Personas, mental support, quick tools, spending advice, contract analyzer, cost estimator, blog/script, mock interview, language partner, PA drafts, Excel/letters, AI sales assistant, CRM AI, voice mode. (Spec note: Claude Max subscription is dev-only, NOT for product users.) |
| **Firebase (FCM)** | Push notifications, incoming calls, family alerts |
| **Google Play Developer account** ($25, org name) | Android publishing |
| **Apple Developer** ($99/yr) | iPhone publishing |
| **Google Maps / Places key** | Nearby, Safe Journey, "leave now" ETA, local service finder, travel planner |
| **IVR / voice-call & SMS gateway** | Parent auto voice-call, SMS backup, AI phone call (#195), voice emergency fallback |
| **Meta Business Verification (WhatsApp Cloud API, Messenger)** | Business WhatsApp, CRM WhatsApp, Business/CRM message auto-reply |
| **Google OAuth (restricted scope)** | Email assistant / AI Inbox Gmail fetch; encrypted Drive backup (#197) |
| **Payment partner (bKash / Nagad / SSLCommerz / ekPay)** | Bill pay, payment ladder (#56), subscriptions billing, credit top-up |
| **AWS inbound call ports / disk / future server** | Voice & video calls (TURN/SFU), growth scale (owner_actions/aws_ports.md) |
| **AdMob, Spotify (optional)** | Free-plan ads, music voice command |
| **Axon ERP module & price list** | CRM proposals, ERP handoff |
| **Weather & news API** | "Today" morning brief, disaster alerts, market price radar |
| **Flight / hotel / service booking partner** | Travel planner, PA travel, local service finder appointments, doctor serial order |
| **Instagram / Facebook Page API** | Star-PA social inbox (#123), social-media posting |
| **OCR engine** | Document scanner, Life Scanner, food-photo diet log, receipt/voucher scan |
| **Transcription service** | Call & voice-note transcription (#92), meeting minutes |
| **Voice-clone service** | Own-voice clone (#14) |
| **Trade-data source (ITC Trade Map / equivalent)** | Demand map (#145) |
| **Photo-enhance engine** | Photo enhance (#40, #169) |
| **Smart-home platform keys (Google Home / Tuya)** | Smart Home (#46) |

> Logic/no-key paths already correct for: scam check, finance calculators, money parse, reminders NLU, medicine DB (DGDA), dictionary (open-license), Unseen World (open data), nearby (OSM fallback), referral, Safe Journey (OSM + web token), circle messaging (E2E), CRM scoring, Business khata/min-price. These do NOT wait on keys.

---

## 6. BUILD WAVE PRIORITIES (derived)

1. **Fix plan prices** (৳849/৳1299/annual) + Business overage + credit top-up — *after owner confirms numbers* (Section 25).
2. **Sidebar regroup** to v2.1 Section 4 (Family&Safety merge, Contacts&Profile section, Health-into-Daily-Life or keep — owner confirm) (Section 4).
3. **First-P10 basics → advanced** (28 basic items): Finance tools, Emergency/SOS, Subscriptions, Watch feed, Nearby, Govt guide, Contacts/Personal CRM, Agent Studio, AI Inbox, Job hunter, Nominee, Voice cmds — most have a batch-1 upgrade in flight; finish + reviewer-pass.
4. **Not-built UI with backend ready**: Auto-pay ladder (#56), Elderly simple mode (#68).
5. **v2.1 AI core** (quick tools, bookmarks, morning brief, voice mode, personas, mood, spending advice) — biggest UX uplift, mostly [🔑 AI] mock.
6. **PA Secretary mode (Section 14, 23 items)** — new Work-section module; large; Premium/Business + [🔑 AI/booking/IG].
7. **Daily-Life v2.1** (doc scanner, contract analyzer, market radar, travel planner, local service finder, cost estimator) + **Health v2.1** (water/sleep/diet, fitness, health timeline, smartwatch).
8. **Section 20 (20 owner items)** — thin modules on existing Money/Reminders/Messenger/Family.
9. **Messenger v3 reviewer pass** → advanced; add transcription when key arrives.
10. **Growth tools** (savings challenge, "made in 30s", daily quiz) + remaining safety (phone lost/stolen #80, voice SOS native).

---

## RETURN SUMMARY (headline numbers)
- Appendix A grades: **advanced 38 · good 61 · basic 28 · not-built 61 · owner-blocked(pure) 13** (= 201).
- **Below-advanced total: 102** (28 basic + 61 not-built + 13 owner-blocked).
- **v2.1 NEW items: ~79** (Section 14 PA = 23 · AI-core adds 9 · Daily-Life adds 6 · Health adds ~5 · standalone new ~11 · Section 20 = 20 · plus supplier/demand-map/growth-tools ~5).
- Top discrepancies: **plan prices Premium ৳149→৳849, Family ৳299→৳1299, Annual ৳1199→~৳8499**; **sidebar: Family+Safety not merged, no Contacts&Profile section, Health split vs spec's Daily-Life fold, PA Secretary absent from Work**; **legal: no code violations — gaps are unbuilt features carrying mandatory banners (payment stop-all, phone-security disclosure, contract legal banner, not-medical-advice on new health, romantic-AI exclusion, delete-all + 24h breach-notify).**
