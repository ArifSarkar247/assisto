# Assisto — অগ্রগতি রিপোর্ট

## ✅ চূড়ান্ত সারসংক্ষেপ (Phase 0 + Step A + V1 শেষ)

Assisto এখন **লাইভ**: `https://assisto.asalify.com` — ৪টি ফ্রি ওয়েব টুল (লগইন ছাড়া) + একটি পূর্ণ **Android অ্যাপ** (ব্যাকএন্ড Django+PostgreSQL)। Asalify-র ১২টি টেন্যান্ট প্রতিটি ডিপ্লয়ের আগে-পরে যাচাই করা হয়েছে — **কোনো প্রভাব পড়েনি**।

### 📱 সর্বশেষ APK (build 20): https://assisto.asalify.com/dl/0fqIEYQZ0Scf217Me75fpeFA/assisto-part7-build20.apk
লিংক খুলুন → ইনস্টল। একবার ইনস্টল করলে অ্যাপই "নতুন আপডেট আছে" দেখাবে — লিংক আর খুঁজতে হবে না। স্থায়ী কি দিয়ে সাইনড (আপডেট আন-ইনস্টল ছাড়াই বসে)।

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

## 🧭 Decisions I made (unattended run)
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
