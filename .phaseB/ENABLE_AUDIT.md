# ENABLE AUDIT — every OFF / paused / placeholder / key-gated feature in Assisto

Discovery only. No code was changed. Scope: `app/` (Flutter) + `backend/` (Django).
Authoritative sources found during the audit:
- **Feature flags / cost kill-switches:** `backend/core/logic/admin_flags.py` (11 flags) — mirrored client-side in `app/lib/admin_flags_api.dart`, flipped from `app/lib/screens/admin/cost_flags_screen.dart`. All 11 default **ON**; the owner console can turn them off. These are NOT "off" today — they are the switchboard, listed here for completeness.
- **Owner keys / integrations:** `backend/core/integrations.py` → `REGISTRY` (29 slugs) + `is_enabled(slug)` / `get(slug)`. This is the one place the Integrations admin page reads.
- **Build-99 ANR mitigation:** WorkManager removed; `app/lib/background.dart` is a no-op; native init gated by `StartupGuard.isSafeMode()` in `app/lib/main.dart:73`; alerts now poll foreground via `app/lib/alerts_fg.dart`.

Legend for state: **off** · **placeholder** · **mock** (honest template/rule-based) · **flag** · **hidden/orphan** · **paused** (native seam) · **key-gated**.

---

## A) CAN ENABLE NOW — no owner key needed (sorted: small effort first)

These need only code/finishing (or a flag flip / nav wiring / crash-guarded native start). Nothing here needs an account or server secret.

| # | Feature | Where (file:line) | State | Why it's off | Effort |
|---|---------|-------------------|-------|--------------|--------|
| 1 | **BargainRulesScreen** orphan — defined, never linked | `app/lib/screens/business/bargain_rules_screen.dart:18` | hidden/orphan | Built but no nav path from Business Hub | small (add 1 tile) |
| 2 | **BusinessPlansScreen** orphan | `app/lib/screens/business/business_plans_screen.dart:16` | hidden/orphan | Built, no nav path | small (add 1 tile) |
| 3 | **ModerationAppealScreen** orphan | `app/lib/screens/messenger/moderation_appeal_screen.dart:17` | hidden/orphan | Takes params, not pushed from AdminModeration | small (wire from moderation decision) |
| 4 | **Dictionary** — open-license word data | `app/lib/screens/dictionary_screen.dart:447` (`_NeedsData`); `backend/core/logic/dictionary.py:99` | placeholder/mock (20 sample words) | Full open dataset not dropped in server-side; `load_dataset()` hook ready | small (import FreeDict/Wiktionary data; no key) |
| 5 | **Social media drafts** | `backend/core/logic/social.py:196,242` | mock (deterministic templates, `ai_required=False`) | Template engine ships; AI polish is the key-gated seam | small (already honest+real; can promote as default) |
| 6 | **Mock interview** rubric feedback | `backend/core/logic/mock_interview.py:304-356`; `app/lib/screens/mock_interview_screen.dart` | mock (rubric: word-count/keyword/structure) | Rule-based grader, no model | small (already real & useful) |
| 7 | **Document letters / notices / memos** | `backend/core/logic/pa_letters.py:149-221` | mock (assembles owner's own fields) | Formal scaffolding only; AI body is seam | small |
| 8 | **Blog writer** scaffold | `backend/core/logic/blog_writer.py:186,225`; `app/lib/screens/blog_writer_screen.dart:288` | mock/placeholder prompt | Template scaffold; AI draft is seam | small |
| 9 | **Spending advice** observations | `backend/core/logic/spending_advice.py:176`; `app/lib/screens/spending_advice_screen.dart` | mock (rules on user's own txns) | Deterministic observations; "smart estimate" is seam | small |
| 10 | **Travel planner** (organizer) | `backend/core/logic/travel_planner.py:305`; `app/lib/screens/travel_planner_screen.dart` | mock (manual day-by-day organizer) | Booking + AI itinerary are seams | small |
| 11 | **Language partner** (dialogue tree) | `backend/core/logic/language_partner.py` | mock (romanization + Q&A scaffold) | Live conversational AI is seam | small |
| 12 | **Research summaries** (manual mode) | `backend/core/logic/pa_research.py:173` | mock (structures owner's links/notes) | Live AI research is seam | small |
| 13 | **Contract analyzer** (basic tier) | `backend/core/logic/contract_analyzer.py:280`; `app/lib/screens/contract_analyzer_screen.dart:163` | mock (pattern flags: law/liability/fees) | Deep AI analysis is seam | small |
| 14 | **Daily brief** (reminders/payments/birthdays/events) | `backend/core/logic/daily_brief.py:230,291`; `app/lib/screens/daily_brief_screen.dart` | mock (assembles user's own data) | Fully real already; only weather/news slots are key-gated (§B) | small (nothing to do; brief itself works) |
| 15 | **PA brief** digest | `backend/core/logic/pa_brief.py:230` | mock (user's own PA data) | AI narration is seam | small |
| 16 | **Email draft** (template reply) | `backend/core/logic/pa_callemail.py:245` | mock (formal skeleton) | Full AI reply is seam | small |
| 17 | **Quick-tools phrases** | `backend/core/logic/quick_tools.py:177,248` | mock (~100-phrase table) | Hits = instant; novel phrase sets `ai_required=True` | small |
| 18 | **My Vehicles — live tracking** | `app/lib/screens/my_vehicles_screen.dart:558` | placeholder ("coming soon" note) | No GPS/telematics source; no fake map by design | medium (needs a device/telematics source; no owner key) |
| 19 | **Photo enhance — on-device path** | `backend/core/photo.py:160`; `app/lib/screens/photo_enhance_screen.dart` | on-device live; cloud path requires_key | On-device denoise/sharpen/upscale already runs | medium (harden Dart on-device ops; cloud is §B) |
| 20 | **OCR on-device fallback** | `backend/core/photo.py`; doc_scanner path | on-device fallback; cloud is key-gated | Dart on-device layer exists, less accurate | medium (robustness only; no key for base) |
| 21 | **Transcription — manual/on-device** | `app/lib/screens/transcription_screen.dart:38`; `app/lib/screens/money_voice_screen.dart:34` | enabled via `speech_to_text`; auto-STT seam | Manual works now; auto cloud-STT is seam | medium (base already live) |
| 22 | **Lost/Stolen — SMS-command trigger** | `app/lib/screens/lost_stolen_screen.dart:775-784` (`onChanged: null`) | paused (toggle disabled, "coming soon") | Native SMS `BroadcastReceiver` (RECEIVE_SMS) not shipped | medium (native receiver + manifest; no key) |
| 23 | **Home widget — iOS** | `app/lib/screens/settings_screen.dart:823`; `app/lib/services/home_widget_service.dart` | off on iOS (Android works) | No WidgetKit extension shipped; honest disabled tile | medium (iOS Swift extension; Android already on) |
| 24 | **Action Center — PENDING list** | `app/lib/screens/action_center_screen.dart:28`; `app/lib/action_api.dart` | placeholder (degrades to empty) | New backend endpoint not yet deployed | medium (deploy endpoint; no key) |
| 25 | **Fall detection — real sensor** | `app/lib/screens/fall_detect_screen.dart:43` (`_sensorAvailable = false`) | paused (simulate-only) | Native accelerometer plugin not wired; sim path only | large (sensor + platform channel + alarm, crash-guarded via StartupGuard) |
| 26 | **Scheduled commutes** | `backend/core/views_build61.py:694` | placeholder (marked "native TODO") | Native commute source not wired | large |
| 27 | **Circle calls provisioning** | `backend/core/logic/circle_calls.py:378` | off (defaults "not yet") | RTC infra flags off until server provisioned | large (self-hosted TURN/relay; no 3rd-party key strictly) |

### Native-feature status note (post build-99 ANR)
These native features are **already reachable and crash-guarded** — no action needed, listed so nothing is assumed broken:
- **Voice SOS** — Android live, opt-in flag `app/lib/widgets/voice_sos_config.dart:33`; iOS honest-unavailable. `app/lib/screens/voice_sos_screen.dart:72`.
- **Lost/Stolen (device-admin)** — Android live; iOS honest-unavailable. `app/lib/screens/lost_stolen_screen.dart:122`.
- **Smartwatch / Health Connect** — Android live (needs Health Connect app + in-app permission, not an owner key); iOS unavailable. `app/lib/screens/smartwatch_screen.dart:35`.
- **Home widget (Android)** — live, gated to safe-mode init. `app/lib/main.dart:73`.
- **Camera** — live with permission gate. `app/lib/screens/camera/camera_screen.dart`.
- **Voice mood** — live, on-device only. `app/lib/screens/voice_mood_screen.dart:30`.
- **Registry/IMEI** — reads from vault only (Android forbids native IMEI read). `app/lib/screens/registry_imei.dart`.
- **Background sync** — intentionally removed (ANR); foreground polling replaces it. `app/lib/background.dart`, `app/lib/alerts_fg.dart` — do NOT re-enable WorkManager.

### Messenger "coming soon" placeholders (no key; need backend routes)
Several messenger settings/screens degrade honestly because their backend routes don't exist yet — pure code work, no key:
- Updates/Communities tabs placeholders: `app/lib/screens/messenger/messenger_home_screen.dart:337,369,384`.
- Moderation policy pages (owner-review placeholders): `app/lib/screens/messenger/moderation_policy_screen.dart:112`.
- Chat/group/account seams (two-step, change-number, blocked, message-requests, privacy, notifications, calls, storage, mute, disappearing, theme, favourite, export, group-AI, community notifications/leave, chat info/clear): `app/lib/messenger_setapi.dart:22-179`, `app/lib/messenger_group_api.dart:30-148`, `app/lib/messenger_chat_api.dart:32,141`. Each is a `TODO(backend)` route — medium effort to add server routes, no key.
- Storage-usage "unavailable yet": `app/lib/screens/messenger/msgr_set_storage_screen.dart:110`.

---

## B) NEEDS OWNER KEY / ACCOUNT / SERVER — keep honest "needs X" state (wire to Integrations admin page)

Each maps to a slug in `backend/core/integrations.py` → `REGISTRY`. Flip-the-key turns these on honestly.

| Feature | Where (file:line) | State | Key slug(s) |
|---------|-------------------|-------|-------------|
| AI drafting / smart briefing / roleplay / CRM AI / bill-scan AI | `backend/core/jobs.py:64`, `backend/core/bills.py:68`, `backend/core/views.py:1223,1886,2051`; flag `ai_drafting` | needs_key | **anthropic** (backup: gemini, openai) |
| Weather in daily brief | `backend/core/logic/daily_brief.py:315`; `app/lib/screens/daily_brief_screen.dart:405` | needs_key chip | **weather** |
| News in daily brief | `backend/core/logic/daily_brief.py:330`; `app/lib/screens/daily_brief_screen.dart:413` | needs_key chip (RSS fallback possible) | **news** |
| Cross-device push (missed medicine → child, family share) | Firebase init; flag `push_fanout` | off until keys | **firebase** |
| Nearby places / map navigation (live) | `backend/core/nearby.py:106` (curated offline fallback in `core/logic/nearby.py`) | key-gated (honest fallback) | **google_places** |
| Photo cloud enhance (upscale/denoise/bg) | `backend/core/photo.py:80,113`; flag `cloud_photo_enhance` | requires_key (on-device fallback) | **ocr**/cloud photo provider |
| OCR document scanner (cloud) | `backend/core/integrations.py` slug `ocr`; `crm/logic_capture.py:209` | needs_key (on-device fallback) | **ocr** |
| Speech-to-text / transcription (cloud auto) | `app/lib/screens/transcription_screen.dart` seam | key-gated (manual works) | **transcription** |
| Voice clone TTS briefing | registry slug | off | **voice_clone** |
| SMS OTP login + family SMS alerts + SMS password reset | `backend/core/reset.py:63-74`; flag `sms_fanout` | key-gated ("Available when SMS gateway added") | **sms** (ssl_sms/bulk_sms) |
| IVR voice-call reminders | registry slug | off | **ivr** |
| Telegram bot (reminders/alerts, /help /balance /remind) | `backend/core/integrations.py:211`, `backend/core/views_build61.py:146` | sandbox (inert until token) | **telegram** |
| Gmail / AI Inbox / email assistant / job hunter | `backend/core/views.py:2088,2432`, `backend/core/jobs.py` | key-gated | **google_oauth** |
| In-app subscriptions / credit purchase | `app/lib/screens/plans_screen.dart:105` ("billing coming soon"), `:476,483` disabled buttons | off | **play_billing** |
| Bill pay / subscription / top-up | payment flows | off | **bkash**, **nagad**, **sslcommerz**, **ekpay** |
| Payment link (business) | `backend/core/logic/business_ai.py:953` | mock link until partner key | **bkash/nagad/sslcommerz** / **axon_erp** |
| Non-personalized + rewarded ads | `backend/core/views.py:1629` | key-gated | **admob** |
| Spotify new releases | `backend/core/views.py:1722` | key-gated | **spotify** |
| YouTube artist channels | registry slug (RSS works key-free) | optional | **youtube** |
| WhatsApp sales assistant + CRM lead capture | `backend/core/business_views.py:1491`, `backend/core/logic/business_ai.py:717`, `backend/core/crm/views.py:98,1126` | key-gated; flag `business_crm` | **whatsapp** |
| Meta Messenger / FB Page sales assistant | `backend/core/business_views.py:1588` | key-gated | **messenger** |
| Instagram DM sales assistant | registry slug | key-gated | **instagram** |
| Courier booking (Pathao/Steadfast/RedX) | `backend/core/business_views.py:167`, `backend/core/logic/business_scenarios.py:499` | mock tracking until key | **courier** |
| CRM deal Won → Axon ERP onboarding | `backend/crm/logic.py:257` | key-gated | **axon_erp** |
| Smart-home voice device control | registry slug | off | **smart_home** |
| NEIR stolen-phone registry (official mobile-network block) | `app/lib/api.dart:935`, `app/lib/screens/used_phone_check_screen.dart:89,335` | honest "not available yet" | external (NEIR gov; no private key — honest placeholder, keep) |

**Cost kill-switch flags (owner console, default ON):** `ai_drafting, ai_inbox_summary, ai_scam_check, sms_fanout, push_fanout, cloud_photo_enhance, maps_geocoding` (cost) and `messenger_public, business_crm, family_sharing, new_signups` (feature) — `backend/core/logic/admin_flags.py:60-72`. Turning a cost flag ON still needs the underlying key from §B.

---

## বাংলা সারাংশ (Bangla summary) — top ~15

| ফিচার | কেন বন্ধ ছিল | এখন করণীয় (key লাগবে?) |
|-------|--------------|--------------------------|
| Dictionary | ওপেন-লাইসেন্স ডেটা সার্ভারে বসানো হয়নি (২০টি নমুনা শব্দ) | ডেটাসেট import — **key লাগবে না** (small) |
| সোশ্যাল পোস্ট ড্রাফট | AI polish seam; template ইঞ্জিন রেডি | এখনই চালু, বাস্তব — **key লাগবে না** (small) |
| Mock interview / চিঠি / ব্লগ / স্পেন্ডিং অ্যাডভাইস | rule-based, AI অংশ seam | ডিফল্ট চালু করে দিন — **key লাগবে না** (small) |
| Daily brief (নিজের রিমাইন্ডার/পেমেন্ট/জন্মদিন) | পুরো ফিচার আসলে চালু; শুধু weather/news স্লট key-gated | ব্রিফ নিজেই কাজ করে — **key লাগবে না** |
| ৩টি orphan screen (Bargain rules, Business plans, Moderation appeal) | nav-এ লিংক করা হয়নি | ১টি করে tile যোগ — **key লাগবে না** (small) |
| Lost/Stolen SMS কমান্ড | native SMS receiver এই বিল্ডে নেই (toggle disabled) | native receiver যোগ — **key লাগবে না** (medium) |
| Home widget (iOS) | WidgetKit extension নেই; Android চালু | iOS extension — **key লাগবে না** (medium) |
| Action Center PENDING | backend endpoint deploy হয়নি | endpoint deploy — **key লাগবে না** (medium) |
| Fall detection | native accelerometer wired নয় (শুধু simulate) | sensor + crash-guard — **key লাগবে না** (large) |
| My Vehicles লাইভ ট্র্যাকিং | GPS/telematics সোর্স নেই (ভুয়া ম্যাপ নয়) | ডিভাইস সোর্স লাগবে — **key লাগবে না** (medium) |
| AI ব্রিফিং / স্ক্যান / CRM AI | AI key নেই | **anthropic key লাগবে** |
| Weather / News ব্রিফ | key নেই (News-এ RSS fallback সম্ভব) | **weather / news key** |
| ক্রস-ডিভাইস push | Firebase key নেই | **firebase** |
| OTP/SMS অ্যালার্ট ও SMS reset | SMS gateway নেই | **sms gateway** |
| পেমেন্ট / সাবস্ক্রিপশন | gateway key নেই | **bkash/nagad/sslcommerz/ekpay/play_billing** |
| Telegram বট | token না দিলে inert (sandbox) | **telegram bot token** |
| WhatsApp/Messenger/IG সেলস, Courier, Axon ERP (Business) | Meta/partner key নেই | **whatsapp/messenger/instagram/courier/axon_erp** |
| Nearby/Maps লাইভ, Photo cloud, OCR cloud | key নেই (সবগুলোর honest fallback আছে) | **google_places / ocr** (fallback চলে) |
