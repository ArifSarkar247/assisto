# Assisto — অগ্রগতি রিপোর্ট

> **চূড়ান্ত মাস্টার প্ল্যান চলছে (শুরু ১২ অক্টোবর ২০২৬)।** লক্ষ্য: দুই PDF-এর সব ফিচার শেষ করা, যেন মালিক শুধু একে একে API key/account যোগ করলেই সব চালু হয়। এই সেকশনটাই রিজিউম-অ্যাঙ্কর — সেশন থামলে এখান থেকে শুরু।

## 🚨 OWNER DIRECTIVE v2 + FAST MODE (১৩ অক্টোবর ২০২৬) — বর্তমান ক্রম

নতুন ক্রম: (1) **STRICT LANGUAGE fix** → (2) advanced rebuild of every module (benchmarked, reviewer-passed) → (3) P13+ additions same standard → তারপর P11 iOS / P12. Verdict: অ্যাপ "basic" — premium depth দরকার; key ছাড়া যা বানানো যায় সব এখন; AI pipelines mock দিয়ে পূর্ণ।

**PHASE A — STRICT LANGUAGE (single-agent, no parallel until gate green + APK shipped):**
- [x] **Frontend DONE** — language gate CLEAN + wired into CI (`app/tool/lang_gate.py`: Bangla-in-Dart / ARB-key-parity / mixed-"/" → build fails). ALL hard-coded Bangla across 18 screens+widgets → ARB (**464 keys, bn+en balanced**). 14 inline-helper screens auto-converted; 7 read-only translator agents authored the rest; static/const maps (accounts/recurrence/autonomy/sources/doc-types/battery/perm-reasons) → build-time localized fns; `permission_reason` → `PermKind` enum. **0 analyze errors.** Dev tools (on-disk, gitignored `bin/`): arbify.py, arbify_b.py, fix_bn_dart.py, fix_const.py. Decision: **৳ (U+09F3) exempt** from gate (currency sign, valid both langs like `$`); `langPickBangla="বাংলা"` kept in en ARB (picker shows each language in its own script).
- [x] **Gallery both-langs render** — 35 screens × বাংলা/English × Light/Dark (130 renders): https://assisto.asalify.com/dl/shots-V0yyKIoE0PU/index.html
- [x] **APK shipped** — build 55 (strict-language): .../dl/Am68srqH84PkZvvkRDpQw3jL/assisto-part7-build55.apk ; build 56 (owner naming v2) building/published via updater
- [x] **Owner naming v2 applied** — Money→My Account/আমার হিসাব, Vault→Documents/ডকুমেন্টস, user area→Profile/প্রোফাইল; `backend/core/screen_synonyms.py` for open-from-chat synonyms.
- [x] **Backend user-facing localization DONE** — `Accept-Language` mechanism (`core/i18n.py` `req_lang`/`pick`/`localise`; app sends header from locale). Plans bilingual (name_en/desc/benefits) + lang-aware `entitlements`/`plans_public` → **fixes English-mode Bangla Free-plan name**. Localized: views (errors/briefing/alerts/wrapped/inbox/studio/**agent chat replies + action cards**/nearby), guides (`localized()` + app reads flattened name/steps/tip), business/jobs/bills/nearby/watcher/serializers/night-briefings — all follow the user's language; **AI outputs generated in the selected language**. **64 backend tests green** (4 new localization). Deployed (service restarted, health 200, Asalify 200). App-side shipped in build 57.

**✅ PHASE A COMPLETE** — gate CLEAN + CI-enforced; builds 55/56/57 shipped; gallery both-langs; naming v2; backend localized + deployed.

**PHASE B — parallel team (6 worktrees; I=INTEGRATOR: merge, ARB-merge, migrations 1-at-a-time+DB backup, tests, gallery, APK). Premium reviewer (different agent) per module vs depth-standard + benchmark table (top 2–3 apps) + language rules + scenario tests; only reviewer-passed = "advanced". Ship APK per module.** Areas: (1) Medicine/family→Connected Circle (2) Money parser/budgets/loans/reports/net-worth (3) Reminders/memory NL-engine+vault+scam+safety (4) AI CRM web app (own Django app) (5) P13+ additions (6) Plans/paywall+onboarding+grouped sidebar+open-from-chat. Server: heavy jobs 1-at-a-time+lock; throttle on load/RAM/swap/Asalify slowness; ≥8GB disk; cleanup each build.


### Phase B disk + worktree protocol (owner DISK GUARD)
Shared disk w/ LIVE Asalify; floor 8 GB, soft 8.5 GB. `bin/disk_guard.sh` before any worktree: cleanup if <8.5, refuse/reduce if <8. **No flutter build/pub get/test inside agent worktrees** — agents edit code only; the **integrator builds in the main tree** then `cleanup.sh`. Share one pub cache. Delete each worktree + its build dirs right after merging. Never touch Asalify or /home/ubuntu/asalify_backups/.


### Phase B IN PROGRESS (integrate when all 3 land; tree mid-edit — NO build until money+CRM done)
- [x] **Medicine & family care** built + committed (a34f0b07): 6-tab Family Care, backend/core/logic/medicine.py, Doctor/Prescription models, adherence/refill/escalation/caregiver/doctor-PDF, 60 med* ARB keys, 30-day scenario test. Self-graded advanced (PDF Bengali shaping=good). reviewer ae9e598=GOOD→**fix agent a4c81fe DONE** (P1-P4+P6 fixed, review-passed). INTEGRATOR TODO: makemigrations core (DB backup first) — new fields: Doctor(name/specialty/hospital/phone/notes), Prescription(member/doctor/doctor_name/date/diagnosis/meds JSON/notes), Medicine(+prescription/food_relation/dose_qty/as_needed/duration_days/taper/stock_count/refill_warn_days), MedicineLog(+skipped/at); then gen-l10n + analyze + gate + backend tests + apply reviewer gaps.
- [~] **Medicine reviewer: GOOD → sent back** (ae9e598): math/escalation/adherence/language all pass; blocked by P1 refill-date not surfaced, P2 no edit path, P3 doctor-PDF bytes discarded, P4 PRN single-log/day. **Fix agent a4c81fe running** (P1–P4 + P6 hardening). Reviewer confirmed language gate CLEAN (0 Bangla in .dart, 61 med keys balanced).
- [x] **My Account/money built** (a8ca5f4e): SMS parser (bKash/Nagad/Rocket/Upay/bank)+learn, rollover budgets, loans w/ partial repay, split, trends, net worth+chart, monthly report. 23 engine tests pass. Integration spec saved → `.phaseB/money_arb.json` (53 keys) + `.phaseB/money_integration.md` (api/models/endpoints/fake_api). reviewer afa4f65=GOOD→**fix agent af15e5c running** (parser amount-collision, budget state key, dedupe, split guard, loan pct, received→income).
- [x] **AI CRM built** (abad6efc): web app backend/crm/ (26 templates, kanban, forecast, dedup/merge, CSV import/export, cadences, quoting w/ no-invented-prices, reports, roles, 18 new models, crm_scenario cmd). Spec → `.phaseB/crm_integration.md` (root url line + migration). **CRM reviewer running (a9eafa2)**. Needs `makemigrations crm`.
- NOTE: medicine's `git add -A` swept partial money_parse.py/crm/models.py into its commit — expected; final versions land when those agents finish; I commit cleanly at integration.
- INTEGRATION ORDER (one heavy job at a time, server throttle, disk guard, cleanup after build): money list → add shared (ARB/api/models/urls/fake_api) → CRM → migrations (DB backup, core then crm) → gen-l10n → flutter analyze + lang gate + backend tests → reviewers' gaps → build+ship APK → cleanup.
- Agent 1 **Medicine & family care** (a34f0b07) — owns family_screen + new medicine widgets/screens + backend medicine models/logic/tests; commits when done.
- Agent 2 **My Account / money** (a8ca5f4e) — owns money_screen + new money_*.dart + backend/core/logic/money_parse.py + money_engine.py (notif parser, recurring, split, loans w/ partial repay, budgets w/ rollover, trends, net worth, reports). Hands integrator: ARB keys, api methods, model fields, endpoints, fake_api. No git/migrations.
- Agent 3 **AI CRM Axon Dynamics** (abad6efc) — owns backend/crm/* (models/views/urls/serializers/templates/static/logic) web app: pipelines/kanban, custom fields, dedup/merge, CSV/Excel, activities timeline, follow-up engine, lead scoring+reasons, proposal PDF (prices TO REVIEW BY OWNER), reports, roles, 30-day scenario. No git/migrations.
- **Integrator (me) only**: shared files (core models.py/urls.py/views.py/serializers, app_drawer, ARB, api.dart, fake_api, settings, main.dart), migrations (DB backup first, one at a time), flutter analyze+gate+tests, gallery, per-module APK, cleanup after each build. Premium reviewer (separate agent) grades each module vs benchmark before "advanced".
- **Stop-hook: BLOCKED by safety classifier** (self-modifying startup config / human-oversight). `bin/stop_guard.sh` built + tested (blocks normally; allows on .run_complete/.pause/.usage_limit/safety-valve 30-per-15min; logs to logs/stop_guard.log) — owner must wire it via /hooks or settings.json; watchdog remains the backup never-stop.

### Phase B — ROUND 1 INTEGRATED (medicine + money + CRM) ✅
- **Medicine & family care** — advanced; reviewer GOOD→fixed→integrated. 6-tab Family Care, adherence/refill/escalation/caregiver/PDF/prescriptions, PRN multi-log, fractional stock. In build 58.
- **My Account / money** — advanced; reviewer GOOD→fixed→integrated. SMS parser (bKash/Nagad/Rocket/Upay/bank)+learn, rollover budgets, loans w/ partial repay+ledger, split, trends, net worth+chart, monthly report+export, 6 endpoints. In build 58.
- **AI CRM (Axon Dynamics)** — advanced; reviewer GOOD→**P0 security fixed** (cross-tenant IDOR org-scoped both layers + CSV/XLSX formula-injection escaped)→integrated. Web app at /crm/ (kanban, forecast, dedup/merge, CSV, cadences, quoting no-invented-prices, reports, roles). Scenario validated (20 leads/8 deals/40% win/forecast ৳1.71M).
- Integrator: migrations 0017 (core) + crm 0002 applied (2 DB backups taken); **90 backend tests green** (incl new); flutter 0 errors; **language gate CLEAN**; service redeployed (health 200, /crm/ 302, Asalify 200). **APK build 58 shipping.**
- REMAINING Phase B: register money sub-screens + CRM web screenshots in gallery; re-render both-langs gallery; modules 4-6 (Reminders/memory NL-engine+vault+scam+safety; P13+ additions; Plans/onboarding/sidebar/open-from-chat). Then P13-P16, P11 iOS, P12 FINAL.

### Phase B — ROUND 2 running (3 agents, code-only, hand integrator lists)
- Gallery (round-1 advanced): https://assisto.asalify.com/dl/shots-6rWx8DSeAJM/index.html (36 screens, 134 renders, bn+en).
- Agent ada293c7 — **Reminders & Memory NL-engine** (Bangla/Banglish NL date parser nlp_datetime.py, recurrence/snooze reminders_engine.py, linked entities, memory retrieval).
- Agent aab2b537 — **Vault + Scam + Family safety** (type-specific vault+expiry+renewal+nominee-share+PIN lookup; scam.py BD scam-pattern library+detector+why+family alert; safety.py SOS/accident/arrival).
- Agent a32ccfc9 — **Plans/paywall + Onboarding(<60s, parent-link<2min) + grouped Sidebar(spec for app_drawer) + open-from-chat(spec)**.
- Build 58 shipping (ship4). Each agent hands ARB/api/model/endpoint/fake_api lists → integrator wires shared files + migrates + builds + reviewer per module.
- NEXT round: module 5 (P13+ additions). Then P13-P16, P11 iOS, P12 FINAL.

## 🧭 লাইভ রিজিউম-চেকলিস্ট (ফেজ ক্রম)

- [x] **STEP 1** — সম্পূর্ণ ফিচার ম্যাট্রিক্স (নিচে) + এই চেকলিস্ট + "Decisions I made"
- [x] **P1 — Integrations Admin** (keystone) ✅ **লাইভ**: `https://assisto.asalify.com/owner/integrations` — owner-only এনক্রিপ্টেড (Fernet) key store, ২১টি ইন্টিগ্রেশন কার্ড (bn/en গাইড + Save/Test + status), feature-flag (`integrations.is_enabled`), AI layer key store থেকে পড়ে; ২৫ backend test সবুজ; DB ব্যাকআপ নেওয়া। **owner login:** `/home/ubuntu/.assisto_secrets.env`-এ `OWNER_ADMIN_LOGIN`/`OWNER_ADMIN_PASSWORD` (লগইন করে পাসওয়ার্ড বদলান)।
- [x] **P2 — AI layer v2** ✅ (backend, 28 tests): multi-provider (Anthropic→Gemini→OpenAI) graceful degrade → "কিউতে আছে" (never fake); providers from Integrations store; per-user limit + daily budget kill-switch; bill-template cache (2nd scan no AI + MoM); batch night briefings (model+command+3AM cron+cached in briefing). *(credit system → P3)*
- [x] **P3 — Monetization** ✅ (backend, 31 tests): সব প্ল্যান + credit ledger + 7-day trial (রেজিস্টারে অটো) + rewarded-ad→credit (daily cap) + waitlist; free প্ল্যানে AI credit-gated, paid unlimited (daily budget-এর নিচে); `/me/plan` `/credits/rewarded` `/waitlist`; top-up packs defined। *(UI: প্ল্যান স্ক্রিন/ক্রেডিট/rewarded ad widget + Play Billing/payment wiring → app-UI ব্যাচ + 🔑 integration)*
- [x] **P4 — Watcher engine** ✅ (backend, 33 tests): plain-code change-detection → AI only on change; RSS/USD-BDT(open.er-api)/page/weather(open-meteo)/price watcher; robots.txt + polite UA মানা; plan limit (free 2/premium 20); Watcher+WatchHit, viewset + `/watch/feed`, hourly cron; শুধু original short note (source content কখনো নয়)। *(app feed UI → app ব্যাচ; Places/Spotify watcher = 🔑)*
- [x] **P5 — Voice + nearby + fav-artist** ✅ (backend, 35 tests): agent voice commands (গান→YouTube/Spotify search deep-link, call, navigate→Maps, nearby) — কখনো auto-send নয়; Nearby Places→OSM fallback (real data, rating invent করে না); fav-artist→YouTube-RSS watcher/search link। *(app: deep-link launch + GPS nearby UI + system Assist + widget + wake-word OFF → app ব্যাচ)*
- [x] **P6 — V2 features 22–32** ✅ (backend, 40 tests): Finance (net worth/zakat/EMI/invest), govt+religious guide, personal CRM (Contact/Meeting), auto-pay ladder (notify/prepare/auto-capped + stop-all, payment-gated), elderly mode, Agent Studio (AI letter/CV/caption/Excel/email), AI Inbox triage (red/yellow/green; Gmail-gated fetch)। *(key-gated: AI Inbox fetch=Gmail, auto-pay exec=payment, health=Health Connect; app UI → ব্যাচ)*
- [x] **P7 — Business mode (33)** ✅ (backend standalone, 44 tests): catalog (Product)/orders (capture→confirm→courier state machine), replies from REAL catalog only (never invents price/stock; out-of-stock honest; low-confidence→human handoff; AI never claims human), WhatsApp webhook (verify + gated on integration, auto-reply OFF default); Asalify-inside version = ⛔ design-only (`owner_actions/asalify_business_mode.md`). *(app UI + live send = 🔑 WhatsApp/courier)*
- [x] **P8 — AI CRM Axon Dynamics (34)** ✅ (separate `crm` app, 58 tests total): CrmOrg/Member/Lead/Conversation/Message/Proposal — omnichannel capture, deterministic lead scoring+routing (≥90→high, real signals only), sentiment, predictive follow-up, AI proposal (needs-key state), 1-click Axon ERP onboarding (gated), multi-tenant member-gated dashboard + labelled forecast estimate; `/api/crm/*`. *(live WhatsApp/LinkedIn capture = 🔑; CRM-sell = multi-tenant ready)*
- [x] **P9 — V3 features 35–40** ✅ (backend, 60 tests): Nominee/family access (scoped, explicit, audit-logged activate), Job hunter (deterministic match from user's OWN skills + reason, AI-tailored CV/cover with needs-key state, NEVER auto-applies, Gmail-gated send), auto-pay ladder+stop-all (P6), CRM-sell (P8 multi-tenant); Telegram bot-builder = ⛔ sandbox design (`owner_actions/bot_builder_sandbox.md`), smart-home/meeting-bots = 🔑. *(app UI + payment/Gmail exec = batch/🔑)*
- [x] **P10 — App UI + Android hardening** ✅ **build 53 লাইভ**: ১৩ নতুন স্ক্রিন (Finance/Plans+Credits/Watch feed/Nearby/Agent Studio/Service guide/Job hunter/Nominee/Personal CRM/Business/AI Inbox) + voice action-cards + Settings→Safety(accident countdown)+medicine follow-up + OEM battery-guidance (per-brand) + runtime-permission reason dialogs (mic/location/camera, bn/en) + first-run onboarding (<60s)। গ্যালারি: ১৩০ renders, ২৫ screens → https://assisto.asalify.com/dl/shots-ZhjOfafF/index.html । *(বাকি polish: responsive 320/360/412 + parent-linking=P13)*
- [ ] **P11 — iOS-ready**: iOS project + permission strings (bn+en), Share Extension + Siri Shortcuts/App Intents, hide Android-only gracefully, unsigned iOS compile on macOS runner
- [ ] **P12 — FINAL**: full gallery (every screen/dialog/state), latest APK via updater, iOS compile result, repo PRIVATE, Bangla-first summary + OWNER UNLOCK LIST (priority order)
- [ ] **P13 — Connected Circle** (owner addition): relationship request→accept (আব্বা/আম্মা/সন্তান/স্বামী/স্ত্রী/ভাই/বোন/আত্মীয়/বন্ধু/সহকর্মী+custom), invite by phone/QR, no contact-upload w/o consent, block/report, relationship-scoped sharing; **E2E** text/voice-note/photo/short-video via audited lib — **MLS (OpenMLS, Apache/MIT)** preferred over libsignal (AGPL — licence-incompatible w/ closed app); server stores ciphertext only; server AI never reads; optional encrypted backup+recovery code; 1-to-1 WebRTC voice (coturn limited-test here; prod TURN=🔑 separate server; closed-app ring=FCM/PushKit-CallKit 🔑); 1-tap call/msg from parent medicine card.
- [ ] **P14 — New features**: birthdays/anniversaries (pre-reminders+wish/card drafts); meeting/appointment scheduling+reminders+'এখনই বের হন'(Maps 🔑); health tips library (DGHS/WHO, source-named, never diagnose, emergency→999); **medicine DB** (name/generic/strength/form/mfr/price/uses/how-to-take/same-generic alternatives) — **ONLY DGDA official data or licensed provider 🤝; NEVER copy DIMS/MedEx**; every alt shows 'ডাক্তার/ফার্মাসিস্টের পরামর্শ ছাড়া বদলাবেন না'; accident/fall detect (OFF default, battery disclosure; **countdown = user setting, default 2 min, range 30s–10min**; during: loud alarm+strong vibration+large 'আমি ঠিক আছি/I'm OK' button; on timeout→alert chosen family+location→offer 999 call; always cancellable; a child may set it for a parent in elderly mode ONLY with the parent's permission); ride/food (deep-link provider app prefilled; in-app booking=🤝); **dictionary bn↔en** (open/licensed data only, NEVER Bangla Academy; +web tool); **photo enhance** (own photos only, never alter IDs; open-source/CPU or paid 🔑; +web tool); Unseen World travel companion (prefer owner's unseenbangladesh.com+open data).
- [ ] **P15 — Launch gaps**: password reset+recovery (email now, SMS 🔑); privacy-friendly analytics on OUR backend (D1/D7/D30, invites, free→paid, funnel; no 3rd-party trackers; owner-admin dashboard); onboarding <60s wow (add parent medicine / scan bill) + parent-linking (child enters parent#→call/SMS/QR invite; IVR for feature phones 🔑); security hardening checklist + pre-launch audit plan (vault/E2E/admin/rate-limits/OWASP MASVS) + off-server encrypted DB+vault backups plan; legal pages (privacy/terms/health-disclaimer/Play data-safety — drafts 'TO REVIEW BY OWNER'); name/trademark check for 'Assisto'.
- [ ] **P16 — Seasonal**: Ramadan mode (location sehri/iftar times+alarms, wake-parents-for-sehri IVR 🔑, zakat calc, Eid salami/greeting cards — ready before early Feb 2027); 'পৌঁছেছি' safe-arrival check-in (no check-in by set time→alert family); exam-result day (result watcher+share card+traffic-spike plan).
- [ ] **DEPTH AUDIT** (after P10): per feature list model/API/app-screen/tests/works-without-key; mark thin/placeholder honestly; fix thin non-key ones.

**প্রতি ফেজ শেষে:** backend tests + `flutter analyze` + widget/screenshot tests সবুজ → public ≤15 মিনিট (≤30 emulator/macOS) → private → ১২-টেন্যান্ট চেক (fail হলে 60s পরে re-check) → report আপডেট।

## 📋 সম্পূর্ণ ফিচার ম্যাট্রিক্স (দুই PDF + মালিকের তালিকা + extras)

স্ট্যাটাস: ✅ শেষ · 🔨 বানানো হচ্ছে/বাকি · 🔑 মালিকের key লাগবে · ⛔ এই সার্ভারে নয় (কারণ+আনলক)

### ভাইরাল ওয়েব (W1–W4) — সব ✅ লাইভ
W1 CV স্কোর · W2 স্ক্যাম চেকার · W3 পাসপোর্ট/ভিসা/জব ছবি · W4 উৎসব কার্ড

### Appendix A — ব্যক্তিগত/পরিবার (1–21, V1) — সব ✅ (build 41)
1✅ Life Scanner(non-AI অংশ; 🔑 AI narrative) · 2✅ Memory+"AI জানে" · 3✅ অ্যালার্ম/ক্যালেন্ডার/রিমাইন্ডার/নোট/To-Do · 4✅ Proactive alerts · 5✅ ব্রিফিং(non-AI; 🔑 AI narrative/রাতের সারাংশ) · 6✅ ডকুমেন্টস (ভল্ট)+মেয়াদ+ফাইল সংযুক্তি · 7✅ আমার হিসাব: অ্যাকাউন্ট/আয়-খরচ(auto+manual) · 8✅ মাসিক সারাংশ/বাজেট/PDF-Excel · 9✅ ধার · 10✅ সঞ্চয় লক্ষ্য+সাবস্ক্রিপশন · 11🔨 বিল গাইড পূর্ণ ফিল্ড(company/account/meter/last date/late fee/MoM)+এক-ট্যাপ pay(🔑 payment) · 12✅ ফ্যামিলি ওষুধ+"খেয়েছি" · 🔨 **configurable follow-up** (per-medicine+per-member: dose-time reminder → re-remind after N min [def 15] → retries [def 2] → caregiver alert after M min [def 30] → quiet hours; app notif now, IVR 🔑; child sets for parent with permission) · 13✅ স্ক্যাম অ্যালার্ট · 14✅ ইমার্জেন্সি+SOS GPS · 15✅ স্কুল · 16✅ বাংলা ভয়েস(ইন-অ্যাপ) · 17🔑 পেশা রোল-প্লে(AI) · 18🔑 মানসিক সাপোর্ট(AI; ক্রাইসিসে হেল্পলাইন) · 19✅ Wrapped+ইনভাইট · 20✅ অটোনমি+অডিট+undo+per-source · 21✅ অফলাইন+এক্সপোর্ট/ডিলিট+সাপোর্ট

### Appendix A — V2 (22–34)
22🔨 AI Inbox(লাল/হলুদ/সবুজ)+ইমেইল সহকারী+ক্যালেন্ডার সিঙ্ক(🔑 Gmail OAuth) · 23🔨 মেসেজ পড়া+কিওয়ার্ড খসড়া/অটো-রিপ্লাই(🔑 notification listener/WhatsApp) · 24🔨 মিটিং→ব্যক্তিগত CRM+ক্লাস অ্যালার্ট · 25🔨 হাই-প্রায়োরিটি খবর/স্টক/watcher(P4) · 26🔨 ঋণ/EMI/বিনিয়োগ/net worth/যাকাত ক্যালকুলেটর · 27🔨 অনুমোদন-সাপেক্ষ auto-pay ladder(per-bill cap+stop-all)+ফ্যামিলি যৌথ+রেমিট্যান্স+রিচার্জ অ্যালার্ট(🔑 payment) · 28🔨 হেলথ টাইমলাইন+স্মার্টওয়াচ(🔑 Health Connect)+ডায়েট লগ · 29🔨 বয়স্ক সহজ মোড+দুর্বলতা সতর্কতা · 30🔨 সরকারি সেবা গাইড+ধর্মীয় রিমাইন্ডার · 31🔨 বাংলা ভয়েস ডিফল্ট অ্যাসিস্ট্যান্ট(Android)(P5) · 32🔨 Agent Studio: Excel/চিঠি/CV/ক্যাপশন(🔑 AI) · 33 Business mode(P7) · 34 AI CRM(P8)

### Appendix A — V3 (35–40) + V4/Future (41–42)
35🔨 Agent Actions(ট্রাভেল, লিমিটে পূর্ণ auto-pay, অটো-রিচার্জ)(🔑 payment) · 36🔨 নমিনি/ফ্যামিলি অ্যাক্সেস · 37🔨 জব হান্টার এজেন্ট(🔑 Gmail; কখনো Bdjobs/LinkedIn-এ অটো-apply নয়) · 38⛔ Telegram bot runtime(আলাদা sandbox সার্ভার লাগবে — UI/API/sandbox ডিজাইন বানাবো) + 🔨 ছবি টুল/ল্যান্ডিং পেজ · 39🔨 মিটিং বট/স্মার্ট হোম(🔑)/পার্টনার প্ল্যাটফর্ম · 40 CRM বিক্রি(P8-এর multi-tenant) · 41🔨 আরও ইন্টিগ্রেশন+iOS(P11) · 42⛔ Future(ন্যানো-সেন্সর/রোবট/ডিজিটাল টুইন/সীমাহীন auto-pay/therapist-level) — ডিজাইন নোট only

### CRM_SPEC — Axon Dynamics (P8)
1🔨 Omnichannel lead capture(🔑 WhatsApp/Meta/LinkedIn) · 2🔨 AI lead scoring+auto-route · 3🔨 conversation-sync+sentiment · 4🔨 predictive follow-up+draft · 5🔨 auto demo+proposal PDF · 6🔨 1-click Axon ERP onboarding(🔑 Axon ERP API) · +🔨 predictive-forecast dashboard

### Monetization (§17 + ২৩-সেপ্ট) — P3
🔨 Free/Premium ৳149/Family ৳299/প্রবাসী $4.99/Business ৳1,999/Founder/Annual ৳1,199 · 🔨 credit ৳20–30 top-up · 🔨 7-day full trial · 🔨 rewarded ad→1 scan(🔑 AdMob) · 🔨 Google Play Billing(🔑) · 🔨 bKash/Nagad/SSLCommerz/ekPay(🔑) · 🔨 waitlist/invite gate

### Extras A–D
A🔨 Voice assistant(গান deep-link/call/alarm/WhatsApp draft/Maps/memory; system Assist; widget; wake-word OFF) · B🔨 Favourite artists(YouTube RSS free + Spotify 🔑) · C🔨 Nearby(Google Places 🔑 → OSM fallback) · D🔨 Watcher engine server-side(P4)

### Integrations Admin — P1 (keystone)
🔨 Owner web admin: Anthropic/Gemini/OpenAI · Firebase · Google Places/Maps · Spotify · YouTube Data · AdMob · Play Billing · bKash/Nagad/SSLCommerz/ekPay · SMS gateway · IVR/voice · Gmail/Google OAuth · Meta WhatsApp/Messenger · courier · Health Connect · smart-home(Google Home/Tuya)। প্রতি কার্ড: কী আনলক + bn/en setup গাইড + paste + Test + status; key এনক্রিপ্টেড, কখনো ফেরত দেখানো হয় না; pass করলে ফিচার অটো-চালু।

### Platform
P10🔨 সব Android ফোন(8–15, 320/360/412+tablet, OEM battery guidance, runtime-perm reason, crash-proof) · P11🔨 iOS-ready(compile only; signing/TestFlight = 🔑 Apple Developer)

### ⛔ এই সার্ভারে নয় (ডিজাইন বানাবো)
- Business mode **Asalify-র ভেতরে** → আলাদা asalify সেশনে, এক টেস্ট-টেন্যান্টে flag-এর পিছনে ধাপে ধাপে করার প্ল্যান লিখব (standalone সংস্করণ Assisto backend-এ বানাবো)।
- User-generated **Telegram bot runtime** → আলাদা sandbox সার্ভার লাগবে; UI+API+sandbox আর্কিটেকচার ডিজাইন করব, রানটাইম নয়।

## ✅ চূড়ান্ত সারসংক্ষেপ (Phase 0 + Step A + V1 শেষ)

Assisto এখন **লাইভ**: `https://assisto.asalify.com` — ৪টি ফ্রি ওয়েব টুল (লগইন ছাড়া) + একটি পূর্ণ **Android অ্যাপ** (ব্যাকএন্ড Django+PostgreSQL)। Asalify-র ১২টি টেন্যান্ট প্রতিটি ডিপ্লয়ের আগে-পরে যাচাই করা হয়েছে — **কোনো প্রভাব পড়েনি**।

### 📱 সর্বশেষ APK (build 53): https://assisto.asalify.com/dl/kQOVIFf0tYMkNlNnhtN7uo5q/assisto-part7-build53.apk
লিংক খুলুন → ইনস্টল। একবার ইনস্টল করলে অ্যাপই "নতুন আপডেট আছে" দেখাবে — লিংক আর খুঁজতে হবে না। স্থায়ী কি দিয়ে সাইনড (আপডেট আন-ইনস্টল ছাড়াই বসে)।

---

## 🔄 মাস্টার-প্ল্যান অগ্রগতি (১২ অক্টোবর ২০২৬)

**সর্বশেষ লাইভ: build 33** — Part C কোর (চ্যাট হোম + ডিজাইন সিস্টেম + ডার্ক মোড) + দ্বিভাষিক ভিত্তি + সম্পূর্ণ Part A প্লাগিন ফিচার (ভয়েস/SOS GPS/ভল্ট সংযুক্তি/ফ্যামিলি অ্যালার্ট) + সাবস্ক্রিপশন UI।
- এই সেশনে Asalify-তে **কোনো পরিবর্তন করা হয়নি** (শুধু `~/assisto`, GitHub, probe রিপো)। তাই টেন্যান্ট রিগ্রেশন অসম্ভব।
- **ব্যাকএন্ড টেস্ট: ২১টি সবুজ** (এজেন্ট পার্সার + `/agent` এন্ডপয়েন্ট; ইন-মেমরি SQLite, শেয়ারড Postgres ছোঁয় না)।

**পাবলিক উইন্ডো লগ (UTC → প্রাইভেট):**
- build 23: `17:00:38 → 17:07:14` (৬:৩৬) — Part C কোর
- build 29: `17:19:45 → 17:26:59` (৭:১৪) — দ্বিভাষিক i18n + ডার্ক মোড + টেস্ট
- build 31: `17:31:50 → 17:39:20` (৭:৩০) — Part A ৫টি প্লাগিন ফিচার
- build 33: `17:42:39 → 17:48:23` (৫:৪৪) — সাবস্ক্রিপশন UI
- (এর মাঝে ২টি দ্রুত ব্যর্থ অ্যানালাইজ-ফ্লিপ `~2 মি` করে — intl রেজোলিউশন ও `state.dart` ইম্পোর্ট ফিক্স)
- প্রতিটি ফ্লিপের আগে সম্পূর্ণ গিট-হিস্ট্রি সিক্রেট স্ক্যান — সব পরিষ্কার; বিল্ডের পর রিপো সবসময় **প্রাইভেট**।

### Part C — ওয়ার্ল্ড-ক্লাস রিডিজাইন (চলছে, শীর্ষ অগ্রাধিকার)
- ✅ হোম এখন **Assisto-র সাথে চ্যাট থ্রেড** (কথা বলুন → রিচ কার্ড উত্তর, Undo সহ) — ইউটিলিটি ড্যাশবোর্ড নয়।
- ✅ রুল-ভিত্তিক এজেন্ট ব্রেইন (`/agent`) — AI key ছাড়াই বাংলা/English কমান্ড বোঝে ও কাজ করে।
- ✅ ব্র্যান্ড ডিজাইন সিস্টেম (`theme.dart`): লোগোর navy+gold+cyan টোকেন, ৮-pt স্পেসিং, এক আইকন সেট (ইমোজি UI আইকন বাদ), **লাইট+ডার্ক মোড**, হ্যাপটিকস।
- ✅ A7 — সব ডেভেলপার/প্লেসহোল্ডার টেক্সট বাদ।
- ⏳ বাকি: অনুমোদন-চেকপয়েন্ট কার্ড, "চলমান কাজ" ভিউ, "সংযুক্ত অ্যাপ" পেজ, মডিউল স্ক্রিন পরিশীলন, স্কেলেটন/এম্পটি-স্টেট।

### Part B — দ্বিভাষিক (বাংলা+English) — ভিত্তি ✅ (build 29-এ যাচাইকৃত)
- ✅ Flutter i18n (ARB, gen-l10n), `flutter_localizations`, bn+en ARB, প্রথম-লঞ্চে ভাষা পিকার (ডিফল্ট বাংলা) + সেটিংসে ভাষা ও থিম সুইচ। নেভ/থ্রেড/লগইন/সেটিংস/ইমার্জেন্সি দ্বিভাষিক।
- ⏳ বাকি: বাকি স্ক্রিনের (ভল্ট/ফ্যামিলি/মানি/মেমরি/রিমাইন্ডার) স্ট্রিং ARB-তে সরানো (সুইপ), ব্যাকএন্ড/নোটিফিকেশন/PDF দ্বিভাষিক, AI উত্তর ব্যবহারকারীর ভাষায়।

### Part A — V1 সম্পূর্ণ করা (build 31/33-এ যাচাইকৃত ✅)
- ✅ ভল্ট ফাইল সংযুক্তি — ক্যামেরা/গ্যালারি থেকে ছবি (`image_picker`), owner-only আপলোড + ইন-অ্যাপ ভিউ। (PDF: `file_picker` win32 কনফ্লিক্টে বাদ → share-in ফলো-আপ)
- ✅ বাংলা/English ভয়েস ইনপুট — থ্রেডে মাইক (`speech_to_text`, লোকেল অনুযায়ী bn_BD/en_US)।
- ✅ SOS GPS — "আমার লোকেশন শেয়ার করুন" → ম্যাপ লিংক OS শেয়ার শিটে (`geolocator`+`share_plus`)।
- ✅ ফ্যামিলি অ্যালার্ট Firebase ছাড়া — `workmanager` ঘণ্টায় পোল → high-severity হলে লোকাল নোটিফিকেশন (read-only, নিঃশব্দে ফেল-সেফ)।
- ✅ সাবস্ক্রিপশন UI — নিয়মিত বিল + মাসিক মোট (দ্বিভাষিক), সেটিংস থেকে।
- ✅ ফ্যামিলি "খেয়েছি/খেয়েছেন" ওষুধ কার্ড — আগে থেকেই আছে (today ট্যাব, চেক → কনফার্ম)।
- ⏳ বাকি: নোটিফিকেশন লিসেনার (bKash/ব্যাংক — নেটিভ Kotlin সার্ভিস, OFF ডিফল্ট), ৩০-দিন চ্যালেঞ্জ UI।

### Plugin probe — সমাধান ✅
- ৫টি ঝুঁকিপূর্ণ প্লাগিন একসাথে রিলিজ-বিল্ড যাচাই: **সফল**। `workmanager` ০.৫.২ পুরোনো v1 এম্বেডিংয়ে ভাঙছিল → **০.৬.০-তে ঠিক**। win32 কনফ্লিক্ট নেই।

### ভাইরাল ওয়েব টুল (W1–W4) — সব ✅ লাইভ
✅ W1 CV স্কোর · ✅ W2 স্ক্যাম চেকার · ✅ W3 পাসপোর্ট/ভিসা ছবি · ✅ W4 উৎসবের কার্ড (/cv /scam /photo /festival)

### ফিচার ১–২১ (Appendix A)
- ✅ 2 Memory + "AI কী জানে" + মুছে ফেলা
- ✅ 3 রিমাইন্ডার/অ্যালার্ম/নোট/To-Do (recurring, লোকাল নোটিফিকেশন)
- ✅ 4 Proactive alerts (ডক মেয়াদ/বাজেট/ধার/রিফিল)
- ✅ 5 সকালের ব্রিফিং (non-AI) · 🔑 AI ন্যারেটিভ/রাতের সারাংশ (key লাগবে)
- ✅ 6 ডকুমেন্ট ভল্ট (PIN লক + মেয়াদ 90/30/7) · ⏳ আসল ফাইল সংযুক্তি (follow-up)
- ✅ 7 অ্যাকাউন্ট+আয়/খরচ+ব্যালেন্স · ⏳ নোটিফিকেশন-ক্যাপচার/ভয়েস (follow-up)
- ✅ 8 মাসিক সারাংশ+বাজেট ৮০/১০০% সতর্ক+খাত-ভাগ+PDF/Excel এক্সপোর্ট
- ✅ 9 ধার (দেওয়া/নেওয়া) + রিমাইন্ডার খসড়া
- ✅ 10 সঞ্চয় লক্ষ্য · ⏳ সাবস্ক্রিপশন UI (ব্যাকএন্ড আছে)
- 🔑 11 বিল গাইড (ছবি→AI = key) · ⛔ বিল পে (payment partner লাগবে)
- ✅ 12 ফ্যামিলি সদস্য + ওষুধ সময়সূচি + "খেয়েছি" + রিফিল · ⏳ মিস→সন্তানকে push
- ✅ 13 স্ক্যাম অ্যালার্ট (নিয়ম-ভিত্তিক, ইন-অ্যাপ)
- ✅ 14 ইমার্জেন্সি কার্ড + SOS কল · ⏳ GPS লোকেশন শেয়ার (follow-up)
- ✅ 15 বাচ্চার স্কুল (ফি/পরীক্ষা/মিটিং)
- ⏳ 16 বাংলা ভয়েস ইনপুট (speech plugin — লোকাল টেস্ট পেলে)
- 🔑 17 পেশা রোল-প্লে (key লাগবে)
- 🔑 18 মানসিক সাপোর্ট/মেডিটেশন (key লাগবে; ক্রাইসিসে হেল্পলাইন দেখানো হবে)
- ✅ 19 মাসিক Wrapped কার্ড + ইনভাইট কোড · ⏳ 30-দিন চ্যালেঞ্জ/ফ্যামিলি কার্ড UI
- ✅ 20 অটোনমি ডায়াল + অডিট লগ + undo + per-source অনুমতি
- ✅ 21 অফলাইন-ফার্স্ট সিঙ্ক + এক্সপোর্ট (JSON/Excel/PDF) + সাপোর্ট/বাগ রিপোর্ট + অ্যাকাউন্ট ডিলিট
- ✅ AI layer (multi-provider, needs-key, budget kill-switch, prompt-injection guard) — key পেলে স্বয়ংক্রিয় চালু

### 🔑 আপনাকে যা দিতে হবে (অগ্রাধিকার ক্রমে)
1. **ANTHROPIC_API_KEY** — সবচেয়ে বড় আনলক (সস্তা, Haiku)। Life Scanner, AI ব্রিফিং/রাতের সারাংশ, রোল-প্লে, মানসিক সাপোর্ট, স্মার্ট CV/স্ক্যাম চালু হবে। `/home/ubuntu/.assisto_secrets.env`-এ `ANTHROPIC_API_KEY=...` বসিয়ে `sudo systemctl restart assisto.service` — কোড বদলাতে হবে না।
2. **GitHub billing ঠিক করুন** (Settings→Billing & plans) — তাহলে প্রাইভেট রিপোতেই বিল্ড চলবে, পাবলিক করার দরকার হবে না।
3. **Asalify CI ফিক্স** merge করুন — `~/assisto/owner_actions/asalify_ci_fix.md` (২ লাইন)।
4. **Firebase (FCM)** — ক্রস-ডিভাইস push (ওষুধ মিস হলে সন্তানকে অ্যালার্ট, ফ্যামিলি শেয়ার)।
5. **SMS/ভয়েস প্রোভাইডার** — OTP লগইন, SOS SMS, ফ্যামিলি কল।
6. **Payment partner** (bKash/Nagad/SSLCommerz/ekPay) — বিল পে।
7. **Play Store**: ডেভেলপার অ্যাকাউন্ট ($25) + চূড়ান্ত ডোমেইন/নাম + **release keystore নিরাপদে রাখুন** (`~/assisto/secrets/` + GitHub secrets; হারালে আপডেট দেওয়া যাবে না)।

### 👉 সুপারিশ (পরের ধাপ)
প্রথমে **ANTHROPIC_API_KEY যোগ করুন + GitHub billing ঠিক করুন**। এরপর বাকি follow-up (ভল্টে ফাইল সংযুক্তি, বাংলা ভয়েস, নোটিফিকেশন-ক্যাপচার, push, সাবস্ক্রিপশন UI) শেষ করে Play Store-এর দিকে এগোনো যাবে। সার্ভার সরানোর প্ল্যান নিচে "move plan"-এ আছে (এক সেটিং থেকে সব URL)।

---

## 🔖 মাস্টার প্ল্যান চেকলিস্ট (resume এখান থেকে — 2026-10-12 নতুন নির্দেশ)
লেজেন্ড: ✅ done · 🔨 in progress · ⏳ todo · 🔑 needs owner · ⛔ not built (reason)

**Part A — V1 finish/polish**
- ⏳ A1 ভল্টে আসল অ্যাটাচমেন্ট (picker যা বিল্ড হয়) — probe repo-তে যাচাই আগে
- ⏳ A2 বাংলা/English ভয়েস ইনপুট (on-device STT) — probe আগে
- ⏳ A3 Notification Listener (bKash/ব্যাংক, OFF default, disclosure, রিভিউ কিউ) — probe আগে
- ⏳ A4 SOS GPS শেয়ার (share sheet) — probe আগে
- ⏳ A5 ফ্যামিলি অ্যালার্ট Firebase ছাড়া (WorkManager polling + local notif)
- ⏳ A6 সাবস্ক্রিপশন UI, 30-দিন চ্যালেঞ্জ, ফ্যামিলি "ওষুধ খেয়েছেন" কার্ড, বাকি ⏳
- 🔨 A7 সব developer/placeholder টেক্সট সরানো (হোম কার্ডসহ)

**Part B — বাইলিঙ্গুয়াল (Bangla+English, Flutter i18n ARB, zero hard-coded)** ⏳
**Part C — World-class redesign (conversation-first AI agent thread)** ⏳ (top priority)
**Part D — V2+V3 (Appendix A 22–40), AI CRM; never-build items ⛔ design-doc only** ⏳
**Testing — emulator smoke test (both languages, light/dark) + screenshots** ⏳

### 🧭 পদ্ধতি (unattended, resumable)
বিশাল স্কোপ — একাধিক সেশনে ছড়াবে। অগ্রাধিকার: A7 (দ্রুত বাগ) → plugin-probe repo (A1–A4 নিরাপদে যাচাই) → Part C-র agent-brain ব্যাকএন্ড (key ছাড়া rule-based) → thread UI → B (i18n) → বাকি A → D → testing। প্রতিটা অংশ শেষে commit + checklist আপডেট + (দরকারে) APK। plugin-probe repo: `ArifSarkar247/assisto-plugin-probe` (পাবলিক, minimal Flutter, Assisto কোড নেই)।

---

## 🔖 পুরোনো V1 চেকলিস্ট
লেজেন্ড: ✅ done · 🔨 in progress · ⏳ todo · 🔑 needs owner (key/account) · ⛔ blocked

**Phase 0**
- ✅ 0.2 লোগো · 0.3 নাম+আইকন+স্প্ল্যাশ+লগইন · 0.4 সাইনিং কি · 0.5 ইন-অ্যাপ আপডেট · 0.6 arm64 APK
- 🔑 0.1 Asalify CI fix — **needs owner** (ready patch: `owner_actions/asalify_ci_fix.md`). আমি live Asalify রিপোতে commit করিনি (সেফটি রুল + গার্ডরেইল)। কারণ (বাংলা): `ci.yml` প্রতি push+PR-এ চলে, `concurrency` নেই (দ্রুত একাধিক push একসাথে পুরো জব চালায়, একটাও ক্যানসেল হয় না), আর `timeout-minutes` নেই (আটকে গেলে ডিফল্ট ৬ ঘণ্টা চলে) → একদিনেই ২০০০ মিনিট শেষ। ফিক্স: `concurrency(cancel-in-progress)` + `timeout-minutes:15` (শুধু ওই ২টা লাইন)।
- ✅ 0.7 সিদ্ধান্ত: লোকাল Flutter বসানো হয়নি (ডিস্ক ≥9GB রাখতে); বদলে CI-তে `flutter analyze`+`test` ধাপ

**Step A — ভাইরাল ওয়েব টুল (assisto.asalify.com, লগইন ছাড়া) — ✅ লাইভ**
- ✅ W1 CV স্কোর (/cv) · ✅ W2 স্ক্যাম চেকার (/scam) · ✅ W3 পাসপোর্ট/ভিসা ছবি (/photo) · ✅ W4 উৎসবের কার্ড (/festival)
- বাংলা, মোবাইল-ফার্স্ট, লগইন ছাড়া, per-IP রেট লিমিট, শেয়ার কার্ড (1080+story), OG প্রিভিউ, "অ্যাপ নিন" লিংক
- AI খরচ/ব্যবহার (key থাকলে, Haiku): W1 ≈ $0.005, W2 ≈ $0.0017; key ছাড়া $0 (নিয়ম-ভিত্তিক)

**V1 — অ্যাপ + ব্যাকএন্ড (ফিচার ১–২১)**
- ✅ Part 2 (build 6): (3) রিমাইন্ডার/নোট/To-Do অফলাইন সিঙ্ক + লোকাল নোটিফিকেশন · (2) Memory + মুছে ফেলা · (20) autonomy dial/audit log/undo/per-source permission · (21) sync/export(JSON+Excel+PDF)/support+bug
  - 📱 APK: https://assisto.asalify.com/dl/THsEnWPn6oEEHRdIznFqsspf/assisto-part2-build6.apk (~21MB, signed) — অথবা পুরোনো অ্যাপে "নতুন আপডেট আছে" থেকে আপডেট
  - রিপো পাবলিক: 13:17:54 UTC (19:17:54 BST) → প্রাইভেট: 13:32:37 UTC (19:32:37 BST)। হিস্ট্রি সিক্রেট-মুক্ত। (২বার ফিক্স: ডিফল্ট টেস্ট ফাইল + desugaring)
- ✅ Part 3 (build 16): (6) ডকুমেন্ট ভল্ট — PIN লক + এক্সপায়ারি ট্র্যাকার (90/30/7 ব্যাজ) · (14) ইমার্জেন্সি কার্ড + SOS কল
  - 📱 APK: https://assisto.asalify.com/dl/gUchLXG3jhnx89aRMz3Vdx-f/assisto-part3-build16.apk — বা অ্যাপে "নতুন আপডেট আছে"
  - রিপো পাবলিক: 13:39:43 UTC (19:39:43 BST) → প্রাইভেট: 14:33:51 UTC (20:33:51 BST)। হিস্ট্রি সিক্রেট-মুক্ত। (বেশ কয়েকবার Flutter প্লাগইন/SDK ফিক্স — এখন ওয়ার্কফ্লোতে স্থায়ী)
- ✅ Part 4 (money, build 17): (7) অ্যাকাউন্ট+আয়/খরচ+ব্যালেন্স · (8) মাসিক সারাংশ+বাজেট ৮০/১০০% সতর্ক+খাত-ভাগ · (9) ধার+রিমাইন্ডার খসড়া · (10) সঞ্চয় লক্ষ্য। APK: /dl/gqg-KB5U1AZpa_f1WseAIBAZ/assisto-part4-build17.apk · পাবলিক 14:40:45→প্রাইভেট 14:48:18 UTC (প্রথম চেষ্টাতেই বিল্ড)। বাকি: সাবস্ক্রিপশন UI, (11) বিল গাইড/পে (needs payment partner), নোটিফিকেশন-ক্যাপচার (needs follow-up)
- 🔨 Part 5: ✅(12) ফ্যামিলি সদস্য + ওষুধ সময়সূচি + "খেয়েছি" কনফার্ম + রিফিল · ✅(13) ইন-অ্যাপ স্ক্যাম চেক · ✅(15) বাচ্চার স্কুল (ফি/পরীক্ষা/মিটিং) — APK বিল্ড চলছে। বাকি: মিস হলে সন্তানকে অ্যালার্ট (needs push/Firebase)
- 🔨 Part 6: ✅(4) proactive alerts (ডক মেয়াদ/বাজেট/ধার/রিফিল — non-AI) · ✅(5) সকালের ব্রিফিং (non-AI; key পেলে AI ন্যারেটিভ) · 🔑(1) Life Scanner (needs AI key — needs-key state আছে) · 🔑(17) role-play · 🔑(18) মানসিক সাপোর্ট · ⏳(16) বাংলা ভয়েস (speech plugin — বিল্ড-ঝুঁকি, পরে)
- ✅ Part 7 (build 20): (19) মাসিক Wrapped কার্ড (ব্যাজ, টাকার অঙ্ক ছাড়া শেয়ার) + ইনভাইট কোড। APK: /dl/0fqIEYQZ0Scf217Me75fpeFA/assisto-part7-build20.apk · পাবলিক 15:05:30→প্রাইভেট 15:12:51 UTC (প্রথম চেষ্টাতেই)। বাকি: 30-দিন চ্যালেঞ্জ UI, ফ্যামিলি "✅ ওষুধ খেয়েছেন" কার্ড (ব্যাকএন্ড লগ আছে)
- ✅ AI layer: multi-provider (Anthropic), cheap/medium/strong রাউটিং, per-user limit, daily budget kill-switch, prompt-injection guard, needs-key state। key (ANTHROPIC_API_KEY) পেলে W1/W2/briefing/Life Scanner স্বয়ংক্রিয় চালু।

**Owner-blocked (এগুলো আপনি দিলে চালু হবে):** ANTHROPIC_API_KEY (AI ফিচার) · GitHub billing (Nov 1 পর্যন্ত private বিল্ড বন্ধ) · Firebase (ক্রস-ডিভাইস push) · SMS/voice provider (কল/এসএমএস) · payment partner (বিল পে)

## ✅ Ops (2026-10-13)
- **Watchdog FIXED**: bottom-12-line + ❯-cursor/"Do you want" detection (not scrollback numbers/keywords); 5-min cron; tested idle→send, dialog/working→skip, false-positive→IDLE. `bin/watchdog.sh --test <files>`.
- **Disk**: `bin/cleanup.sh` (app/build, backups>5, APKs>3, old galleries, temp — never Asalify) wired into publish-apk.sh + daily 3:30 cron. <!-- WATCHDOG+DISK DONE -->
- **Build 47 লাইভ**: + Service guide, Settings→Safety (accident countdown), OEM battery-guidance, Nominee, Job hunter, Personal CRM contacts — সব drawer-এ।

## 🧭 Decisions I made (unattended run)
- **Owner superuser bootstrap (P1):** মালিকের লগইন দরকার ছিল integrations পেজে; একটা ডেডিকেটেড superuser (`owner@assisto.local`) + র‍্যান্ডম strong পাসওয়ার্ড তৈরি করে `/home/ubuntu/.assisto_secrets.env`-এ (600) রাখলাম (`OWNER_ADMIN_LOGIN`/`OWNER_ADMIN_PASSWORD`)। মালিক লগইন করে পাসওয়ার্ড বদলাবেন। অ্যাপের সাধারণ ইউজার থেকে আলাদা।
- **Integrations encryption:** Fernet; key `INTEGRATIONS_FERNET_KEY` secrets ফাইলে (600)। raw secret কখনো client-এ ফেরত/লগে যায় না; টেস্ট ছাড়া ইন্টিগ্রেশন "saved — প্রথম ব্যবহারে যাচাই" (সৎ, fake নয়)।
- **চূড়ান্ত বিল্ড-অর্ডার (২০২৬-১০-১২):** P1 Integrations Admin আগে (keystone — key ছাড়া বানানো যায়, আর এটাই পরে সব key আনলক করে), তারপর P2 AI-layer, P3 monetization, P4 watcher, P5 voice, P6 V2, P7 business, P8 CRM, P9 V3, P10 Android-hardening, P11 iOS, P12 final। কারণ: আগে এমন সব কিছু যা key ছাড়া সম্পূর্ণ হয়; key-নির্ভর অংশ "🔑 Available when ___" state-এ থাকবে আর Integrations টেস্ট pass করলে অটো-চালু হবে।
- **Flutter লোকাল বসানো হয়েছে** (`~/assisto/tools/flutter`, owner অনুমোদিত; ডিস্ক ≥8GB রাখা) → এখন `flutter analyze` + golden/স্ক্রিনশট টেস্ট লোকালি চলে; আর অন্ধ CI-ফ্লিপ লাগে না। (পুরোনো "Flutter বসাইনি" সিদ্ধান্ত বাতিল।)
- **WorkManager বাদ, স্থায়ীভাবে:** ColorOS/Realme-তে androidx.work-এর startup ContentProvider লঞ্চেই ক্র্যাশ করত (owner-নিশ্চিত); ব্যাকগ্রাউন্ডও ওসব ফোনে throttled। ফ্যামিলি অ্যালার্ট এখন অ্যাপ খোলা/রিজিউমে `/alerts` পোল + লোকাল নোটিফিকেশন (dedup)। প্রকৃত push = Firebase (🔑)।
- **লোগো:** owner-এর নিজের ডিজাইন (`new-logo.png`) সরাসরি ব্যবহার ("use it as is"); adaptive fg কালো bg থেকে key করে ~64% safe-zone; brand palette cyan→blue→purple।
- **গান/খবর/watcher ও কপিরাইট:** কখনো গানের কথা/আর্টিকেল/দীর্ঘ উদ্ধৃতি রিপ্রোডিউস করব না — শুধু **deep-link** (YouTube/Spotify) আর নিজের ছোট original summary; সোর্স robots.txt + terms মানব; অফিসিয়াল API/RSS/পাবলিক পেজ।
- **Startup crash-proof:** `runZonedGuarded` + `FlutterError.onError` + `PlatformDispatcher.onError` + প্রতিটা init try/catch ও non-blocking; নতুন ঝুঁকিপূর্ণ প্লাগইন probe-repo-তে যাচাই ছাড়া startup ContentProvider যোগ করব না।
- **(আপডেট) SOS GPS + ভল্ট ফাইল সংযুক্তি + ভয়েস ইনপুট — এখন যোগ করা হয়েছে** (build 31+, probe-যাচাইকৃত plugin দিয়ে)। নিচের পুরোনো "বাদ" নোটগুলো ইতিহাস।
- **Asalify parallel edits (owner note 2026-10-12):** owner is editing Asalify in another session; services may restart briefly. টেন্যান্ট চেক ফেল করলে ৬০ সেকেন্ড অপেক্ষা করে আবার চেক — তবেই regression ধরা/rollback। নিজে থেকে Asalify-র কিছু ছোঁব না।
- **plugin-probe repo:** ঝুঁকিপূর্ণ প্লাগইন (image_picker/geolocator/speech_to_text/workmanager/share_plus) আগে পাবলিক probe repo-তে রিলিজ-বিল্ড করে যাচাই, তারপর আসল অ্যাপে। probe পাবলিক + Assisto কোড নেই → সিক্রেট-স্ক্যান/ফ্লিপ লাগে না।
- **0.7 Flutter লোকাল বসাইনি:** ডিস্ক ১১GB ফ্রি; Flutter ~২GB → ৯GB-র নিচে নামার ঝুঁকি (হার্ড রুল ≥9GB)। বদলে CI-তে `flutter analyze`/`test` ফেল-ফাস্ট ধাপ যোগ করছি।
- **secrets ফাইল:** `/home/ubuntu/.assisto_secrets.env` (chmod 600) canonical; backend/.env ও GitHub secrets এর সাথে সিঙ্ক।
- **রিমাইন্ডার নোটিফিকেশন:** exact-alarm পারমিশন এড়াতে `inexactAllowWhileIdle` মোডে শিডিউল (Play-নীতিসম্মত, বাড়তি পারমিশন লাগে না)। সব নোটিফিকেশন কল try/catch — ব্যর্থ হলেও অ্যাপ/রিমাইন্ডার অফলাইনে কাজ করে।
- **PDF এক্সপোর্ট:** reportlab-এ জটিল বাংলা shaping নেই (যুক্তাক্ষর অসম্পূর্ণ দেখাতে পারে); পূর্ণ বাংলার জন্য **Excel এক্সপোর্ট** ব্যবহার করুন (সঠিক রেন্ডার)।
- **Step A W3 (ছবি):** ব্যাকগ্রাউন্ড রিমুভাল (ভারী ML/ইমেজ-AI) যোগ করিনি — শুধু ক্রপ/রিসাইজ (CPU-লাইট, সৎ)। bg রিমুভাল পরে (needs image-AI key)।
- **Step A AI:** key থাকলে W1/W2 উন্নত হয়; key ছাড়া নিয়ম-ভিত্তিক (সৎ)। AI daily budget kill-switch + per-user limit + prompt-injection guard আছে।
- **Part 3 ভল্ট লক:** PIN লক (ডিভাইস secure storage) দিয়ে করেছি। **ফিঙ্গারপ্রিন্ট** ও **স্ক্রিনশট ব্লকিং** এখন বাদ — এগুলো MainActivity/প্ল্যাটফর্ম কনফিগ বদলায় (লোকাল টেস্ট ছাড়া বিল্ড-ঝুঁকি বেশি); পরে যোগ হবে। ভল্ট ফাইল HTTPS + owner-only (পাবলিকলি সার্ভ হয় না); ফিল্ড-লেভেল এনক্রিপশন-অ্যাট-রেস্ট পরের hardening।
- **SOS:** শুধু ইউজার চাপলে ডায়ালার খোলে (url_launcher tel:)। নিখুঁত GPS লোকেশন শেয়ার (geolocator) এখন বাদ — লোকেশন পারমিশন/প্লে-সার্ভিস বিল্ড-ঝুঁকি; পরে।
- **ভল্টে ফাইল আপলোড বাদ (আপাতত):** file_picker 13 win32 6 টেনে আনে যা package_info_plus/secure_storage/path_provider ইত্যাদির win32 5-এর সাথে সংঘর্ষ করে (লোকাল Flutter ছাড়া প্রতিটা ফিক্স ক্লাউড বিল্ডে আলাদা ইটারেশন)। তাই ভল্ট এখন **PIN-লক + মেয়াদ ট্র্যাকার** (পাসপোর্ট/NID/লাইসেন্স মেয়াদ, 90/30/7 অ্যালার্ট) — spec-এর মূল মূল্য। **আসল ফাইল/ছবি সংযুক্তি** পরে (ব্যাকএন্ড রেডি; লোকাল Flutter টেস্ট পেলে নিরাপদে যোগ হবে)। ব্যাকএন্ড ফাইল-আপলোড API owner-only, টেস্টেড ও রাখা আছে।
- **Flutter বিল্ড কনফিগ (এখন ওয়ার্কফ্লোতে স্থায়ী):** core library desugaring, minSdk=23, compileSdk=36 — flutter_local_notifications-এর জন্য। নতুন প্লাগইন যোগ করলে win32/SDK সংঘর্ষ হতে পারে; সাবধানে।

---

## বাংলা সারসংক্ষেপ (সর্বশেষ: Part 1 ✅ সম্পন্ন)

Assisto V1 অ্যাপ বানানো শুরু হয়েছে — Asalify থেকে **সম্পূর্ণ আলাদা**, লাইভ Asalify-তে কোনো প্রভাব ছাড়াই।

### 📱 সর্বশেষ টেস্ট APK (লোগো + আইকন + ইন-অ্যাপ আপডেট)
**লিংক (build 3):** https://assisto.asalify.com/dl/qojkImV7OzDmJwK9jw8vex6D/assisto-part2-build3.apk
- Android ফোনে লিংকটা খুলুন → APK ডাউনলোড → "এই উৎস থেকে ইনস্টল" অনুমতি দিন → ইনস্টল। অ্যাপের নাম **Assisto**, নতুন লোগো আইকন।
- **এখন থেকে লিংক খুঁজতে হবে না:** অ্যাপ খুললে নিজেই চেক করে — নতুন ভার্সন থাকলে "নতুন আপডেট আছে" দেখায়, এক ট্যাপে ডাউনলোড + ইনস্টল।
- **সাইজ ~১৯ MB** (arm64, রিলিজ, সাইনড — আগের ১৬০MB থেকে অনেক ছোট)।
- **স্থায়ী সাইনিং কি:** সব ভার্সন একই কি দিয়ে সাইন হয় → আন-ইনস্টল না করেই আপডেট বসে। কি-র ব্যাকআপ সার্ভারে `~/assisto/secrets/` (git-এ নেই) + GitHub Actions secrets-এ। **এই কি হারালে Play Store-এ আপডেট দেওয়া যাবে না — নিরাপদে রাখুন।**

**লোগো:** নেভি-ব্লু গ্রেডিয়েন্ট রাউন্ডেড আইকন; সোনালি দুই হাত একটা জ্বলন্ত সায়ান মস্তিষ্ক (AI, ভেতরে সার্কিট লাইন) আলতো করে ধরে আছে — মানে "AI যে আপনার যত্ন নেয়"। অ্যাডাপ্টিভ আইকন (fg/bg আলাদা) + স্প্ল্যাশ স্ক্রিন।

**রিপো পাবলিক/প্রাইভেট (এই বিল্ড):** পাবলিক `2026-10-12 12:37:39 UTC` → বিল্ড → প্রাইভেট `2026-10-12 12:45:24 UTC` (~৮ মিনিট)। পুরো git হিস্ট্রি সিক্রেট-মুক্ত (DB পাসওয়ার্ড/SECRET_KEY/keystore পাসওয়ার্ড/PEM কি/টোকেন = ০)। রিপো এখন **PRIVATE**।

**এখন পর্যন্ত যা হয়েছে (Part 1 — অ্যাপ শেল):**
- ✅ **ব্যাকএন্ড (Django + PostgreSQL)** তৈরি, টেস্ট ও চালু — আলাদা DB (`assisto`), আলাদা DB ইউজার, আলাদা venv, আলাদা systemd সার্ভিস `assisto.service` (পোর্ট ৮৭০০, **CPUQuota=50%, MemoryMax=1G**)।
  - কাজ করছে: রেজিস্টার, লগইন (ফোন/ইমেইল + পাসওয়ার্ড), প্রোফাইল, "AI কী জানে" মেমোরি (যোগ/এডিট/মুছে), অডিট লগ, ডাটা এক্সপোর্ট, অ্যাকাউন্ট ডিলিট।
  - OTP ডিজাইন করা আছে কিন্তু **বন্ধ** (SMS প্রোভাইডার নেই — নকল SMS পাঠানো হয় না)।
- ✅ **HTTPS চালু:** `https://assisto.asalify.com` — আসল Let's Encrypt সার্টিফিকেট (certbot, অটো-রিনিউ)। Caddy-তে শুধু assisto-র ব্লক যোগ হয়েছে; **১২টি Asalify টেন্যান্ট আগের মতোই ঠিক আছে** (প্রতিবার যাচাই করা হয়েছে)।
- ✅ **Flutter অ্যাপ (Android)** কোড তৈরি — বাংলা-প্রথম UI, বাংলা ফন্ট বান্ডেল করা, অফলাইন-ফার্স্ট লোকাল স্টোরেজ (sqflite), লগইন, হোম, "AI কী জানে" পেজ, সেটিংস (অটোনমি ডায়াল, এক্সপোর্ট, ডিলিট, অডিট লগ)।
- ✅ **ক্লাউড APK বিল্ড** (GitHub Actions) সেটআপ — এই সার্ভারে Android SDK/Flutter বসানো হয়নি (Asalify ধীর হবে না)।

**এখন আপনার কাছ থেকে যা দরকার:**
1. **GitHub device-code অনুমোদন** — কোড দেখানো হয়েছে, github.com/login/device-এ বসান। (এটা হলেই প্রাইভেট রিপো বানিয়ে প্রথম APK বিল্ড হবে, আর আপনাকে গোপন ডাউনলোড লিংক দেব।)
2. **AI API key** — শুধু Part 5 (Life Scanner/ব্রিফিং) আর Part 4-এর প্রেসক্রিপশন OCR-এর জন্য। বাকি সব key ছাড়াই হচ্ছে।

**পরের ধাপ:** GitHub অনুমোদনের পর — প্রাইভেট রিপো → পুশ → APK বিল্ড → গোপন লিংক। তারপর Part 2 (রিমাইন্ডার + ভল্ট)।

---

## English details

### Separation (Asalify never touched)
| Item | Asalify | Assisto |
|---|---|---|
| Code | `~/asalify` | `~/assisto/backend`, `~/assisto/app` |
| Git | its own | new private repo (pending GitHub auth) |
| DB | PG16 `main`@5432 | DB `assisto` + role `assisto` (same cluster, isolated) |
| Port | 8000 | **8700** (127.0.0.1 only) |
| venv | its own | `~/assisto/.venv` |
| Service | its own | `assisto.service` — `CPUQuota=50%`, `MemoryMax=1G` |
| Web | Caddy blocks | one added `assisto.asalify.com` block |

Disk: Assisto footprint well under the 3 GB budget.

### TLS note (important for later)
Caddy on this box uses a global `on_demand_tls` with a `*.asalify.com` wildcard whose ask-endpoint (Asalify's app) denies `assisto`. That makes Caddy refuse to *proactively* issue a managed cert for `assisto.asalify.com`. Per your instruction we did **not** touch the global config. Instead the cert is issued **out-of-band by certbot** (HTTP-01 webroot served only inside the assisto block) and **pinned** in the assisto block (`tls <fullchain> <privkey>`). Auto-renewal: `certbot.timer` → deploy-hook `~/assisto/bin/caddy-deploy-hook.sh` (copies cert to a Caddy-readable path, `caddy validate`, `caddy reload` — never restart). `certbot renew --dry-run` passes.

### API (v1, token auth)
`/api/v1/`: `health`, `version`, `auth/register`, `auth/login`, `auth/logout`, `auth/otp/request` (503 until SMS), `me` (GET/PATCH), `memory/` (CRUD), `audit`, `export`, `account` (DELETE).

### App build / APK delivery
- Cloud build: `.github/workflows/android.yml` → debug-signed APK, `--dart-define=API_BASE=https://assisto.asalify.com`.
- Delivery (no GitHub login on your phone): `~/assisto/bin/publish-apk.sh` downloads the artifact to the server and serves it at a secret `https://assisto.asalify.com/dl/<token>/assisto-partN-<build>.apk`. Keeps only the last 3 APKs.

### Move plan (to Assisto's own server, zero user change)
All URLs come from ONE setting: backend `ASSISTO_BASE_URL`, app `--dart-define=API_BASE`. To move:
1. Provision new server; install the same stack; `git clone` the repo; create its own `.venv`, DB `assisto` + role.
2. `pg_dump` the `assisto` DB here → restore on the new server.
3. Point `assisto.asalify.com` DNS to the new server (**same hostname → users need zero change**; the pinned API URL in installed apps keeps working).
4. Move the certbot setup (or re-issue). Keep `ASSISTO_BASE_URL` identical.
5. Decommission here. (If a *new* domain/name is chosen later, that is a one-line setting change + one APK rebuild.)

### Pending (blocking next steps)
- **GitHub device-code authorization** (for private repo + APK build).
- **AI API key** — only for Part 4 (prescription OCR) & Part 5 (Life Scanner, briefing, proactive). Everything else proceeds without it.

### Signing (for later, before Play Store)
V1 test APKs are **debug-signed** (installable now). Before Play Store we will generate a **release keystore**, back it up safely (you hold it), and add it to CI as encrypted secrets.

<!-- P10-PROGRESS -->
### P10 app-UI progress (checkpoint)
- ✅ api.dart methods for all P1–P9 endpoints + CRM.
- ✅ Screens built+wired to drawer: Plans/Credits, Finance tools (zakat/EMI/net-worth/invest), Watch feed, Nearby (GPS), voice action-cards (music/navigate/call/nearby deep-links).
- ✅ Batch 4: Agent Studio screen; Settings → Safety (accident/fall detection, configurable countdown 30s–10min) + medicine follow-up config (backend); accident/followup matrix corrected per owner.
- ✅ **Build 43 লাইভ** (P10 interim): Plans/Finance/Watch/Nearby/voice-cards/Agent-Studio/Safety-settings সব অ্যাপে।
- ✅ Batch 5: Govt-service + religious guide screen wired.
- **P10 done so far (build 43 live):** 7 new drawer screens — Finance, Plans/Credits, Watch feed, Agent Studio, Service guide + Nearby (GPS) + voice action-cards (music/navigate/call/nearby) + Settings→Safety (accident/fall countdown 30s–10min) + medicine follow-up config (backend).
- ⚠️ **APK NOTE:** committed since build 43 (not yet shipped): Service guide, Settings→Safety (accident/fall + medicine follow-up), OEM battery-guidance → include in next P10 APK.
- ✅ **P10 screens DONE (12 new, in drawer):** Finance, Plans/Credits, Watch feed, Nearby(GPS), Agent Studio, Service guide, Job hunter, Nominee, Personal CRM contacts, Business (catalog/orders/reply) + voice action-cards + Settings→Safety(accident) + OEM battery-guidance + medicine follow-up config. **Build 50 লাইভ** — সব ১৩টি নতুন স্ক্রিন (Business + AI Inbox সহ) অ্যাপে।
- 🔨 **P10 remaining:** AI Inbox screen; runtime-permission reason dialogs (mic/location/camera/notification, bn/en); responsive 320/360/412+tablet polish; onboarding <60s + parent-linking; full screenshot gallery (every new screen+dialog+empty/loading/error, bn/en×light/dark) → review → final P10 APK. Then DEPTH AUDIT.

## 🔎 DEPTH AUDIT (2026-10-13) — what really exists

Legend: M=model · A=API · S=app screen · T=tests · K=works without a key. ✅ full · ◑ thin/partial · ➖ n/a · 🔑 needs key · 🔨 fixable-without-key (TODO)

| Feature | M | A | S | T | K | Notes |
|---|---|---|---|---|---|---|
| Chat/agent NLU | ✅ | ✅ | ✅ | ✅ | ✅ | rule-based; solid |
| Memory + "AI knows" | ✅ | ✅ | ✅ | ◑ | ✅ | solid |
| Reminders/notes/todos | ✅ | ✅ | ✅ | ◑ | ✅ | offline-first |
| Money (acct/txn/budget/loan/goal) | ✅ | ✅ | ✅ | ◑ | ✅ | solid |
| Finance calc (zakat/EMI/networth/invest) | ➖ | ✅ | ✅ | ✅ | ✅ | pure compute |
| Vault (+file attach) | ✅ | ✅ | ✅ | ◑ | ✅ | PIN+expiry+photo |
| Family medicine + "খেয়েছি" | ✅ | ✅ | ✅ | ◑ | ✅ | solid |
| **Medicine follow-up config** | ✅ | ✅ | ◑ | ➖ | ✅ | 🔨 fields in model/serializer + Settings note; **per-medicine form UI missing** |
| Emergency + SOS GPS | ✅ | ✅ | ✅ | ➖ | ✅ | solid |
| Subscriptions | ✅ | ✅ | ✅ | ➖ | ✅ | solid |
| Scam check | ✅ | ✅ | ✅ | ➖ | ✅ | rule-based |
| Watcher engine | ✅ | ✅ | ✅ | ✅ | ✅ | RSS/USD/weather no-key; Places/Spotify 🔑 |
| Voice cmds (music/call/nav/nearby) | ➖ | ✅ | ✅ | ✅ | ✅ | deep-links; system-Assist/widget/wake-word ➖ not built (native) |
| Nearby | ➖ | ✅ | ✅ | ✅ | ✅ | OSM no-key; Places 🔑 |
| Personal CRM | ✅ | ✅ | ◑ | ➖ | ✅ | 🔨 contacts screen done; **meetings UI missing** |
| Auto-pay ladder | ✅ | ✅ | ➖ | ➖ | ◑ | 🔨 backend+stop-all done; **no app screen**; exec 🔑 |
| Elderly simple mode | ✅ | ✅ | ➖ | ➖ | ✅ | 🔨 flag only; **simplified-UI mode not built** |
| Govt/religious guide | ➖ | ✅ | ✅ | ➖ | ✅ | original factual |
| Agent Studio | ➖ | ✅ | ✅ | ➖ | 🔑 | needs-key state correct |
| AI Inbox | ➖ | ✅ | ◑ | ✅ | ◑ | classify no-key; fetch 🔑 Gmail; screen thin until connected |
| Business mode | ✅ | ✅ | ✅ | ✅ | ✅ | catalog replies no-key; WhatsApp send 🔑 |
| AI CRM (Axon) | ✅ | ✅ | ➖ | ✅ | ◑ | 🔨 **no UI (API only)**; scoring no-key; proposal/ERP 🔑 |
| Job hunter | ✅ | ✅ | ✅ | ✅ | ◑ | match no-key; tailor 🔑; Gmail-send 🔑 |
| Nominee | ✅ | ✅ | ✅ | ➖ | ✅ | solid |
| Monetization | ✅ | ✅ | ◑ | ✅ | ✅ | Plans screen; billing/AdMob/payment 🔑 |
| Integrations Admin | ✅ | ✅ | ✅(web) | ✅ | ✅ | keystone; solid |
| AI narrative/roleplay/mental/billAI/LifeScanner | ➖ | ✅ | ✅ | ◑ | 🔑 | needs-key states correct |

**Fixable-without-key TODO (from audit):** (1) per-medicine follow-up config on the medicine add/edit form; (2) Personal CRM meetings UI; (3) Auto-pay ladder app screen; (4) Elderly simple-mode UI. **Bigger (plugin/native):** fall-detection sensors (settings done), system-Assist/widget/wake-word, notification-listener (bKash/bank), AI CRM web dashboard.

<!-- DEPTH-AUDIT PROGRESS -->
### Depth-audit fixes progress
- ✅ (1) per-medicine follow-up config form (committed after build 53 → next APK).
- 🔨 next (no key): (2) CRM meetings UI, (3) auto-pay ladder app screen, (4) elderly simple-mode UI → then P13 Connected Circle, P14 new features, P15 launch gaps, P16 seasonal, FINAL.
