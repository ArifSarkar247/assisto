# ASSISTO — REMAINING BELOW-ADVANCED (precise target list)

Refreshed 2026-10-14, after **build 75** (Wave D batch 3). READ-ONLY audit — no code/build touched.
Baseline = `.phaseB/SPEC_V21_AUDIT.md` (advanced 38 / good 61 / basic 28 / not-built 61 / owner-blocked 13 = 201).

## What is already CLEARED since the audit

| Wave | Build | Items cleared | Effect on grades |
|---|---|---|---|
| **A** | 68 | 6 of the 28 basic (voice-cmd, contacts/personal-CRM, govt-guide, agent-studio, AI-inbox, job-hunter) + the earlier 22 basic from batch-1 | **28 basic → 0** |
| **B** | 72 | 2 not-built UI-with-backend-ready: payment/auto-pay ladder (#56), elderly simple mode (#68) | not-built 61 → 59 |
| **C** | — | 4 web tools → advanced (#167 CV, #168 scam, #169 photo, #170 festival) | (web tools, already "good") |
| **D 1-3** | 73,74,75 | **18 of 61 good → advanced**: medicine-db, health-tips, dictionary, meetings, birthdays, memory, plans, photo-enhance, unseen, ride-food, ramadan, exam, safe-arrival, onboarding, legal, password-reset, name-about, owner-analytics | **good 61 → 43 remaining** |

**Net remaining below-advanced counts:**
- **Remaining "good" → advanced: 43**
- **Remaining "not built" / v2.1-NEW (Wave E): ~79**
- **Owner-blocked (pure, key-only): 13**
- TOTAL still below advanced: **~135** (vs 102 at audit time — the delta is the ~79 v2.1-NEW items which the audit counted inside not-built/owner-blocked; listed explicitly below so nothing is missed).

---

## 1. REMAINING "GOOD" → ADVANCED (43 items)

61 good − 18 Wave-D-done = **43**. Each line: `#id name (bn / en) — lives in — what "advanced" (Section-21 gate) still needs`.
Grouped into **disjoint buildable batches of ~6** (files named; no file appears in two batches).

### Batch D4 — AI-core good-bits (6)
| # | Name (bn / en) | Lives in | Advanced needs |
|---|---|---|---|
| #2 | কঠোর ভাষা-বিভাজন / Strict language split | `app/lib/l10n/*`, `app/lib/services/lang_gate.*`, `backend/core/logic/` (cross-cutting) | zero-leak bn/en audit across every new screen; gate test in CI; "AI-captured" marker language-correct |
| #8 | স্বাধীনতার ধাপ / Autonomy dial | `app/lib/screens/settings_screen.dart` | full ask/confirm/auto tiers surfaced + per-action override + audit-log entry on every autonomous act |
| #9 | অ্যাকশন সেন্টার ও অডিট লগ / Action center & audit log | `settings_screen.dart` + new `action_center_screen.dart`; backend audit models | list/filter/export of every action; empty/loading/offline states; share card |
| #12 | অফলাইন-প্রথম / Offline-first | `app/lib/services/*cache*`, offline store | expand offline coverage (notes/contacts/savings/todos/reminders/docs/money/basic-voice); offline state on each |
| #19 | ডার্ক/লাইট টগল / Dark-light toggle | `settings_screen.dart`, `app/lib/theme/*` | one-tap sidebar toggle + follow-phone-theme; verify both themes on every screen; polish contrast (WCAG) |
| #44 | দুর্যোগ সতর্কতা / Disaster alerts (watch feed good-bit) | `watch_feed_screen.dart`, `backend/core/logic/watch_feed.py` | real source-named alerts, wired to reminders+chat, share card, offline cache, [🔑 weather/news mock] |

### Batch D5 — Reminders & Money good-bits (6)
| # | Name | Lives in | Advanced needs |
|---|---|---|---|
| #22 | ক্যালেন্ডার ও নোট / Calendar & notes | `reminders_screen.dart`, `notes_todos_screen.dart`, `backend/core/logic/reminders_engine.py` | month/week calendar view, note search/filter/export, share card, voice-run |
| #50→detail | বাজেট ও পরের মাসের প্ল্যান / Budget & next-month plan | `money_budget_screen.dart`, `money_engine.py` | AI next-month projection, edit/save, share card (plans module shipped; budget sub-screen still good) |
| #60 | আয়কর ও জাকাত সহায়ক / Income-tax & zakat helper | `money_screen.dart` + tax section, `money_engine.py` | full flow (slabs, rebate, export statement), bn/en, share card, offline calc |
| #61 | পরিবারের হিসাব / Family accounting | `family_screen.dart`, `money_screen.dart` family split | shared ledger create/edit/settle, consent, audit log |
| #62 | ভয়েস প্রশ্ন / Voice questions (money) | `money_screen.dart`, `backend/core/logic/voice_commands.py`, `money_parse.py` | voice→query→answer card for all money views; AI-captured marker |
| #63 | মাসিক Wrapped / Monthly Wrapped | `money_report_screen.dart`, `money_trends_screen.dart`, `money_engine.py` | shareable wrapped card, bn/en, empty/loading, export |

### Batch D6 — Family, Contacts & Profile good-bits (6)
| # | Name | Lives in | Advanced needs |
|---|---|---|---|
| #67 | ফ্যামিলি সিলেক্টিভ শেয়ারিং / Family selective sharing | `family_screen.dart`, `backend/core/logic/circle_privacy.py` | per-item sharing toggles, consent screen, audit log, revoke flow |
| #73 | ফ্যামিলি কার্ড / Family card | `family_screen.dart` | share/result card, bn/en, light/dark, print/export |
| #75 | প্রবাসী পরিবার / Probashi family | `family_screen.dart` probashi section, `backend/core/logic/` | two-timezone scheduled calls, remittance context, share card |
| #98 | প্রোফাইল / Profile | `settings_screen.dart`, `app_drawer.dart`, messenger profile | photo/name/bio edit full flow, states, bn/en |
| #99 | কন্টাক্ট ম্যাচ / Contact match | `app/lib/screens/messenger/*contacts*`, `backend/core/logic/msg_contacts.py` | hashed-match flow states, privacy disclosure, empty/offline |
| #101 | ইনভাইট / Invite | messenger contacts/invite screen, `msg_contacts.py` | FCM-invite + own-SIM-SMS prefilled, share card, states |

### Batch D7 — Contacts referral + Agent + Admin surfaces A (6)
| # | Name | Lives in | Advanced needs |
|---|---|---|---|
| #102 | রেফারেল পয়েন্ট / Referral points | `referral_screen.dart`, `backend/core/logic/referral.py` | points→premium-days flow states, share card, audit |
| #135 | সোশ্যাল পোস্ট ও ক্যাপশন / Social-media post & caption | `agent_studio_screen.dart`, `backend/core/logic/agent_studio.py` | full compose/edit/export, share card, [🔑 AI mock], AI-captured marker |
| #174 | ইউজার তথ্য / User info (admin) | admin surface (settings/admin area), backend admin views | list/search, no-PII, audit, states |
| #175 | অভিযোগ ও মডারেশন কিউ / Complaint & moderation queue | `app/lib/screens/messenger/*moderation*`, `backend/core/logic/msg_moderation.py` | queue/actions/appeals full flow, reviewer-pass |
| #176 | ইন্টিগ্রেশন পেজ / Integration page (admin) | admin integrations screen | key-status per service, owner_actions link, states |
| #177 | অ্যানালিটিক্স ড্যাশবোর্ড / Analytics dashboard (admin, extra to owner-analytics) | `owner_analytics_screen.dart` (shipped) + admin-side metrics | NOTE: owner-analytics shipped build 75; confirm admin-side dashboard parity else drop |

### Batch D8 — Admin surfaces B + Messenger good-bits start (6)
| # | Name | Lives in | Advanced needs |
|---|---|---|---|
| #178 | কস্ট কিল-সুইচ ও ফিচার ফ্ল্যাগ / Cost kill-switch & feature flags | admin screen, backend flags | toggle flows, audit, confirm gate |
| #179 | সার্ভার-অ্যাড্রেস সোয়াপ / Server-address swap | settings/admin, `app/lib/services/api*` | in-app endpoint swap, states, confirm |
| #180 | ইন-অ্যাপ আপডেট / In-app update | update surface | version check, download prompt, states |
| #181 | ইন-অ্যাপ সাপোর্ট / In-app support | support screen | ticket/contact flow, states, bn/en |
| #84 | গ্রুপ চ্যাট / Group chat | `app/lib/screens/messenger/` group screens, `circle_groups.py`/`msg_community.py` | reviewer-pass to advanced: full create/edit/media/actions, states |
| #85 | মিডিয়া শেয়ার / Media share | messenger chat screens, `circle_media.py` | send/view/download all types, offline, states |

### Batch D9 — Messenger good-bits (6)
| # | Name | Lives in | Advanced needs |
|---|---|---|---|
| #86 | মেসেজ অ্যাকশন / Message actions (reply/forward/edit/delete) | messenger chat screen | full long-press action set + reviewer-pass |
| #87 | চ্যাট গোছানো / Chat organise (pin/archive/mute/search) | `messenger/*chat_list*` | all organise actions + states |
| #88 | স্ট্যাটাস / Status | `circle_status_screen.dart` + viewer/composer | named-viewers, view-guard, expiry, states |
| #89 | ভয়েস কল / Voice call | `circle_call_screen.dart`, `circle_calls.py` | call flow states, free-all-plans gate, history |
| #90 | ভিডিও কল / Video call | `circle_call_screen.dart`, `circle_calls.py` | premium caller-pays gate surfaced, states, SFU/TURN note |
| #91 | কল সেটিংস / Call settings | `circle_privacy_screen.dart`, call settings | who-can-call, states, consent |

### Batch D10 — Messenger good-bits tail (6)
| # | Name | Lives in | Advanced needs |
|---|---|---|---|
| #93 | কমিউনিটি / Community | `messenger/*community*`, `msg_community.py` | join/approve/rules/message-requests full flow, reviewer-pass |
| #94 | চ্যানেল / Channel | `messenger/*channel*`, `msg_channel.py` | follower count-only-default privacy, analytics, verified badge, states |
| #95 | মেসেজ রিকোয়েস্ট / Message requests | messenger community/chat, `msg_contacts.py` | accept/decline/block/report flow, who-can-msg default, tests |
| #96 | প্রাইভেসি (মেসেঞ্জার) / Messenger privacy | `circle_privacy_screen.dart` | all privacy toggles, phone-hidden default, states |
| #97 | ইন-চ্যাট AI / In-chat AI | messenger chat screen, agent integration | summarise/translate/tone in chat, [🔑 AI mock], AI-captured marker |
| #5 | "AI আমার সম্পর্কে কী জানে" / "What AI knows about me" page | `memory_screen.dart` (shipped core) — dedicated page | NOTE: folded into memory (build 73); confirm dedicated page exists else build the standalone transparency page |

> Batches D4–D10 = 7 batches covering the 43 remaining good. D7 #177 and D10 #5 carry a verify-or-drop note (may already be covered by shipped owner-analytics / memory). If both drop, the true remaining-good is 41 and D10 shrinks.

---

## 2. REMAINING "NOT BUILT" / v2.1-NEW — WAVE E (~79, grouped, key-gates marked)

`[🔑 X]` = needs external key → build mock/sandbox + wire Integrations-admin + add to owner_actions.

### E-1. Section 14 — PA SECRETARY MODE (23, Premium/Business) — all not built
New Work-section module (`app/lib/screens/` new `pa/` dir + `backend/core/logic/pa_*.py`). Sidebar: add PA Secretary to Work (SPEC §4 diff #5).
#103 Schedule control · #104 Meeting reminder & 1-page brief · #105 Visitor/appointment filter · #106 Call & email handling [🔑 AI] · #107 Letters/notices/memos [🔑 AI] · #108 Liaison & follow-up · #109 Filing [🔑 OCR] · #110 Meeting minutes [🔑 transcription] · #111 Privacy / role-based delegate access · #112 Travel & itinerary [🔑 booking partner] · #113 Expense voucher [🔑 OCR] · #114 Research & presentation [🔑 AI] · #115 Personal-task oversight · #116 Corp board-meeting pack [🔑 AI] · #117 Corp departmental update · #118 Corp VIP & stakeholder · #119 Corp business travel & events [🔑 booking] · #120 Corp project tracking · #121 Star deals & offers · #122 Star PR & press · #123 Star social inbox [🔑 Instagram/FB Page API] · #124 Star shooting/concert logistics · #125 Star lifestyle.

### E-2. AI CORE ADDITIONS (Section 6 v2.1) — 7 remaining not-built
`backend/core/logic/` new `ai_*` + screens.
#7 Morning brief & night summary [🔑 AI+weather+news] · #13 Voice mode live conversation [🔑 AI, live-voice] · #14 Natural/own-voice clone [🔑 voice-clone] · #15 Voice mood sensing (on-device, opt-in) · #17 Quick tools (summarise/grammar/translate/tone/share) [🔑 AI] · #18 Saved / bookmarks (no key) · #6 Proactive AI (watch-feed depth, overlaps #44).

### E-3. DAILY LIFE ADDITIONS (Section 8 v2.1) — 6 not-built
New `daily_life/` screens + `backend/core/logic/`.
#29 Document scanner [🔑 OCR/AI] · #30 Contract analyzer [🔑 AI] · #33 Local service finder [🔑 directory/maps] · #34 Market price radar [🔑 price/news source] · #35 Travel planner [🔑 AI, booking] · #36 Cost/time estimator [🔑 AI].

### E-4. HEALTH / LIFESTYLE ADDITIONS (Section 10 v2.1) — 4 not-built
New health screens + logic.
#69 Health timeline · #70 Smartwatch & fitness (Health Connect, native) · #71 Water/sleep/diet [🔑 OCR food-photo] · #72 Fitness partner [🔑 AI]. (Elderly #68 already shipped build 72.)

### E-5. STANDALONE NEW FEATURES — ~11 not-built
#21 Task manager (projects/board/assign/progress) — new `task_manager_screen.dart` + logic · #27 Kid's school notice→fees/exam/PTM · #51 AI spending advice [🔑 AI] (`money_*`) · #79 Voice SOS native trigger (hands-free) · #80 Lost/stolen phone protection (native device-admin) · #92 Call & voice-note transcription [🔑 transcription] · #130 Blog & script writing [🔑 AI] (`agent_studio`) · #131 Mock interview [🔑 AI] · #132 Language-learning partner [🔑 AI] · #144 Supplier & wholesale market (Business; `business/`) · #145 Demand map (Business) [🔑 trade-data] · #173 Daily challenges/quiz (`referral`-linked) · plus #171 Savings challenge, #172 "Made in 30s" (web growth tools).

### E-6. SECTION 20 — OWNER'S 20 MORE LIFE TASKS (#182–201) — all not built
Thin modules on existing Money/Reminders/Messenger/Family (no separate apps).
#182 Mess & bachelor accounting · #183 Expense splitting (Splitwise-style) · #184 Samity/committee · #185 Landlord-tenant · #186 Domestic staff/driver · #187 Doctor serial/appointment [🔑 partner] · #188 Blood-donor network · #189 Wedding & events · #190 Qurbani & Eid · #191 Probashi corner · #192 Student corner · #193 Electricity & gas (prepaid meter) · #194 Area community (overlaps messenger communities) · #195 AI phone call [🔑 AI voice-call] · #196 Widget & watch (native) · #197 Encrypted backup & phone transfer [🔑 Drive OAuth] · #198 Digital security check-up · #199 Farmer/village mode · #200 True accessibility (mode) · #201 Trust/proof page.

**Wave E total:** 23 (PA) + 7 (AI-core) + 6 (Daily-Life) + 4 (Health) + ~13 (standalone incl growth) + 20 (Section 20) ≈ **~73–79**.

---

## 3. OWNER-BLOCKED (13 pure — logic/no-key path correct, waits only on a key)

| # | Feature (bn / en) | Key needed |
|---|---|---|
| #10 | পেশা রোল-প্লে Personas / Profession role-play | AI API key |
| #11 | মানসিক সাপোর্ট ও মেডিটেশন / Mental support & meditation | AI API key |
| #16 | AI Personas | AI API key |
| #26 | Life Scanner | OCR / AI key |
| #46 | স্মার্ট হোম / Smart Home (Google Home / Tuya) | Smart-home platform keys |
| #65 | SMS/IVR ব্যাকআপ / SMS-IVR backup | IVR / SMS gateway |
| #123 | Star social inbox (FB Page + Instagram DMs) | Instagram / FB Page API |
| #126 | Excel sheet generation | AI API key |
| #127 | দরখাস্ত/চিঠি/স্লাইড / Applications/letters/invoice/slide | AI API key |
| #134 | ছোট ব্যবসার ল্যান্ডিং পেজ / Small-business landing page | AI API key |
| #137 | ইমেইল সহকারী / Email assistant | Google OAuth (restricted scope) |
| #138 | মেসেজ পড়া ও উত্তর / Message read & reply | Notification-listener (native) |
| #140 | মিটিং বট / Meeting bot | Transcription / meeting-join key |

(Partial-layer owner-blocked — CV tailor #128, Job Hunter #129 live-feed, AI Inbox fetch #136, Business/CRM WhatsApp, ERP handoff, photo engine — are graded on their built mock layer and are NOT in this 13; they ship advanced-with-mock and flip live on key.)

---

## RECOMMENDED NEXT 2 BATCHES

**Batch D4 — AI-core good-bits (6)**
Modules: strict-lang-split #2 · autonomy-dial #8 · action-center/audit #9 · offline-first #12 · dark/light #19 · disaster-alerts(watch) #44.
Files: `app/lib/screens/settings_screen.dart`, new `app/lib/screens/action_center_screen.dart`, `app/lib/screens/watch_feed_screen.dart`, `app/lib/theme/*`, `app/lib/services/lang_gate.*` + offline-cache service, `backend/core/logic/watch_feed.py`. Emit `up_aicore_arb.json` + integration note.

**Batch D5 — Reminders & Money good-bits (6)**
Modules: calendar&notes #22 · budget/next-month #50 · income-tax&zakat #60 · family-accounting #61 · money voice-questions #62 · monthly-wrapped #63.
Files: `app/lib/screens/reminders_screen.dart`, `notes_todos_screen.dart`, `money_budget_screen.dart`, `money_screen.dart`, `money_report_screen.dart`, `money_trends_screen.dart`, `family_screen.dart`; `backend/core/logic/reminders_engine.py`, `money_engine.py`, `money_parse.py`, `voice_commands.py`. Emit `up_money_arb.json` + integration note.

(Disjoint: D4 touches settings/theme/watch; D5 touches reminders/money/family — no shared file. `family_screen.dart` appears in D5 and D6 — keep family-accounting #61 in D5 and move family #67/#73/#75 sharing/card/probashi to D6's separate sections of the same file, or sequence D5 before D6 to avoid a merge clash.)
