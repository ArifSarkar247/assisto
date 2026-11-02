# Play লিস্টিং — ৮ Nov, সব ফিচার চালু (যাচাই করা লেখা + রিভিউয়ারের পথ)

**তৈরি:** ২ Nov ২০২৬। **শুধু লেখা।** Play Console, সার্ভার, ফ্ল্যাগ, ডাটাবেস কিছুই বদলানো হয়নি। `owner_private` খোলা হয়নি।
**ধরে নেওয়া হয়েছে:** ৮ Nov সব সার্ভার-সুইচ "Play-তেও চালু" (enabled_play ON)। কিন্তু কোডে বাঁধা গেট Play বিল্ডে বন্ধই থাকে:
- `kMedicalFeaturesAllowed = !AppConfig.playStore` (`app/lib/feature_gates.dart:34`): ওষুধ, ডোজ, প্রেসক্রিপশন, ডাক্তার সিরিয়াল, স্বাস্থ্য-টিপস Play-তে লুকানো।
- `VaWake.shipped` = false (`app/lib/voice/va_wake.dart:54`): "Hey Assisto" কোথাও নেই। Play ম্যানিফেস্ট থেকে এর মাইক-সার্ভিসও সরানো হয় (`.github/workflows/android.yml` ~১১০৩–১১১৫ লাইন, "playall" অংশ)।
- `kJobsFeedConnected=false` (`feature_gates.dart:67`), `kLostActionSwitchesWired=false` (`:93`), `kShowKeySeams=false` (`:110`) ইত্যাদি।
- **নতুন তথ্য:** `FallDetectScreen.engineShipped` এখন **true** (`app/lib/screens/fall_detect_screen.dart:38`)। পতন-শনাক্ত এখন শুধু সার্ভার-সুইচ `fall_detect` দিয়ে লুকানো। "সব সুইচ চালু" করলে এটা Play-তে দেখা যাবে ("experimental" লেখা থাকবে)। কোডের মন্তব্য বলছে আসল ফোনে প্রমাণের আগে এটা বন্ধ রাখার কথা (`fall_detect_screen.dart:31-37`)। **পরামর্শ: `fall_detect` Play-তে বন্ধ রাখুন।** লিস্টিংয়ে এর কোনো দাবি নেই।

**AI চাবি:** আজ যোগ হচ্ছে। তাই লিস্টিংয়ে AI-র কথা আলাদা একটা **"AI ব্লক"**-এ রাখা হয়েছে। AI চাবি লাইভে চালু হয়েছে, আর অ্যাপে একটা প্রশ্ন করে আসল AI উত্তর পেয়েছেন, এটা নিজে দেখার পরেই ব্লকটা পেস্ট করবেন। তার আগে "AI ছাড়া" লেখাই চলবে।

---

## সংক্ষেপে (আপনার জন্য)

1. পুরনো ও লাইভ লিস্টিংয়ের **২৪টি দাবি** কোড দেখে যাচাই করা হয়েছে। **রাখা যায় ৯টি। শর্তসহ রাখা যায় ৯টি** (AI চাবি, যন্ত্র বা নিজের অ্যাকাউন্ট লাগে)। **বাদ দিতে হবে ৬টি:** ওষুধ, ডাক্তার, "Hey Assisto", ভুল স্ক্রিন-আনলকে ছবি, রিমোট মুছে ফেলা, কুরিয়ার বুকিং। **কথা বদলাতে হবে ২টির:** "jobs hub" থেকে "job tracker", আর "optional ads" থেকে "Free plan shows ads"।
2. নতুন লেখা (বাংলা ও ইংরেজি) নিচে আছে, কপি করে পেস্ট করার মতো। অক্ষর গোনা আছে, সব Play-র সীমার ভেতরে।
3. স্ক্রিনশট: CI গ্যালারির ৮টি শট বেছে দেওয়া হয়েছে। **কিন্তু গ্যালারি এখন Play-মোডে চলে না।** তাই রিমাইন্ডারের শটে "Take medicine" দেখা যায়, আর হোম, ফ্যামিলি ও ইমার্জেন্সি শটে ওষুধের অংশ আসতে পারে। নিচে লেখা আছে কোনগুলো আবার তুলতে হবে।
4. **রিভিউয়ার লগইন: OTP ছাড়াই ঢোকা যায়।** লগইন পাতায় ফোন নম্বর আর পাসওয়ার্ড দিয়ে ঢোকা যায় (`backend/core/views.py:163-190`)। রিভিউয়ারের ডেমো অ্যাকাউন্ট বানানোর কমান্ডও আছে (`seed_play_reviewer`)। **তাই এটা লঞ্চ আটকাবে না।** তবে আপনাকে নিজে একবার Play বিল্ডে ওই অ্যাকাউন্ট দিয়ে লগইন করে দেখতে হবে (নিচে অংশ খ দেখুন)।
5. **লঞ্চের আগে ঠিক করার মতো ৫টি ছোট কাজ:**
   - রিভিউয়ারের নমুনা-ডেটায় "Doctor appointment / Bring last prescription" আছে। এটা বদলাতে হবে।
   - রিভিউয়ারকে **Business** প্ল্যান দিতে হবে, নইলে শপ বক্স দেখা যাবে না।
   - গ্যালারির শট Play-মোডে আবার তুলতে হবে।
   - `fall_detect` Play-তে বন্ধ রাখতে হবে।
   - Trust পাতায় এনক্রিপশনের লেখাটা পুরনো (নিচে আছে)।

---

## ক) দাবি-যাচাই টেবিল (Play বিল্ডের কোড অনুযায়ী)

রায়:
- **KEEP** = কাজ করে, রিভিউয়ার নিজে চালিয়ে দেখতে পারবেন।
- **KEEP-COND** = আসল ফিচার, তবে কিছু লাগে (কী লাগে, তা লেখা আছে)। লিস্টিংয়ে শর্তটাও লেখা থাকবে।
- **REMOVE** = Play বিল্ডে লুকানো, তৈরি হয়নি, বা কথাটা ভুল।

| # | দাবি (পুরনো বা লাইভ লিস্টিংয়ে) | কোডে প্রমাণ (file:line) | রায় | লিস্টিংয়ে যা লেখা যাবে |
|---|---|---|---|---|
| 1 | ওষুধের রিমাইন্ডার ("Remind me about medicine", "Medicine schedules") | `app/lib/feature_gates.dart:34` (`kMedicalFeaturesAllowed = !playStore`); `kMedicalRoutes` `:45-50`; সার্ভার `backend/core/i18n.py:23-34` (`is_play_flavour`: চ্যাট থেকে ওষুধ বানায় না) | **REMOVE** | কিছুই না। শুধু সাধারণ রিমাইন্ডার ("Call mum at 8")। |
| 2 | ডাক্তারের অ্যাপয়েন্টমেন্ট / সিরিয়াল | `feature_gates.dart:49` (`doctor_serial` মেডিকেল রুট); ড্রয়ারের "doctorSerial" সারিও একই গেটে | **REMOVE** | কিছুই না |
| 3 | ম্যাপ (গাড়ির ট্র্যাকিং, যাত্রা) | `app/lib/vehicle/veh_map.dart:12-28`: ম্যাপের টাইল আসে সার্ভারের `MAP_TILE_URL` থেকে (`backend/assisto_backend/settings.py:87`, ডিফল্ট খালি; `backend/core/views_vehicle.py:158-169`)। খালি থাকলে টাইল ছাড়া রুটের ছবি (`RouteCanvas`) দেখায়। | **KEEP-COND** (সার্ভারে টাইল প্রোভাইডার বসাতে হবে; লাইভে বসানো আছে কিনা এখান থেকে দেখা হয়নি) | "map" শব্দ না লিখে "live location / live tracking" লিখুন |
| 4 | জব হাব / চাকরির খবর | `feature_gates.dart:67` `kJobsFeedConnected=false`: চাকরির কোনো উৎস যুক্ত নেই। শুধু নিজের ট্র্যাকার আর সেভ করা তালিকা চলে। | **REMOVE** ("jobs hub")। **KEEP** ("job tracker") | "job tracker" |
| 5 | রিমোট লক | `app/lib/widgets/remote_switches_card.dart:21-30`; সার্ভার `backend/core/views_at_remote.py:9,49` (lost_mode, alarm, lock, message); ফোনে `MainActivity.kt:402-407` `dpm.lockNow()` | **KEEP-COND**: Device admin চালু থাকতে হবে, ফোন অন ও অনলাইন থাকতে হবে। চালানো যায় অন্য ফোনে লগইন করে, বা বিশ্বস্ত পরিবারের সদস্যের মাধ্যমে। একই ফোনে "Test lock" বোতামও আছে। | শর্তসহ লেখা আছে |
| 6 | কুরিয়ার বুকিং | `app/lib/screens/business/orders_screen.dart:13,218-219,252`: অর্ডার থেকে শুধু কুরিয়ারের নাম নোট হয় ("manual note")। আসল বুকিং আছে শুধু AI সেলস এজেন্টের সেটআপে, বিক্রেতার নিজের Pathao/Steadfast/RedX মার্চেন্ট চাবি দিলে (`backend/core/couriers.py:29`, `seller_setup_screen.dart:498`)। | **REMOVE** | কিছুই না |
| 7 | হাত না লাগিয়ে ভয়েস SOS | `app/lib/widgets/voice_sos_service.dart:1-20`: ফোনের স্পিচ-টু-টেক্সট দিয়ে শোনে, foreground service চলে (microphone ও location), আর একই SOS পথ ব্যবহার করে। চালু করলে নোটিফিকেশন দেখা যায়। ফোনে স্পিচ ইঞ্জিন না থাকলে সৎ বার্তা দেখায় (`vsosUnavailable`)। | **KEEP-COND**: শুরুতে বন্ধ, ফোনে স্পিচ ইঞ্জিন লাগে, ব্যাটারি খরচ হয় | শর্তসহ লেখা আছে |
| 8 | "Hey Assisto" ওয়েক-ওয়ার্ড | `app/lib/voice/va_wake.dart:54` (`shipped` = false, কোনো বিল্ড define দেয় না); Play ম্যানিফেস্ট থেকে `WakeWordService` সরানো (`android.yml` "playall") | **REMOVE** | কিছুই না ("hands-free voice assistant" লেখাও বাদ) |
| 9 | ভুল স্ক্রিন-আনলকে চোরের ছবি | `AntiTheftService.kt:867-871`: লক-স্ক্রিনে ভুল আনলক হলে শুধু ঘটনাটা লেখা থাকে, **ছবি তোলা হয় না**। ছবি ওঠে শুধু Assisto খোলা থাকা অবস্থায় অ্যাপের ভেতরে ভুল Security PIN দিলে, শাটারের শব্দসহ (`:439-447`, `:873-890`)। | **REMOVE** (দাবিটা যেভাবে লেখা ছিল)। **KEEP-COND** (অ্যাপের ভেতরে ভুল PIN দিলে ছবি, মালিক চালু করলে) | "wrong Security PIN inside Assisto" |
| 10 | শপ বক্স / CCTV | `app/lib/screens/shop_box_screen.dart:21-33`: বিজনেস প্ল্যান লাগে, শুধু সংকেত আর একটি ছবি যায়, কোনো ভিডিও নয়। ফোন-ক্যামেরা মোড: `shop_box_screen.dart:480-488` ("Use this phone as a Shop Box")। নেটওয়ার্ক CCTV-র জন্য পিসি-গেটওয়ে লাগে (`owner_actions/CCTV_PLAY_DECLARATIONS_BN.md` §১)। | **KEEP-COND**: বিজনেস প্ল্যান আর একটা বাড়তি Android ফোন, বা CCTV ও পিসি-গেটওয়ে। ৭ দিনের ট্রায়াল আসে শুধু `plans_v2` চালু থাকলে (`plans_screen.dart:487-491`), আর সেটা বন্ধ রাখার প্রস্তাব আছে, তাই "trial" লেখা হয়নি। | শর্তসহ লেখা আছে |
| 11 | গাড়ি: GPS ট্র্যাকিং ও OBD | `app/lib/vehicle/veh_setup.dart:15-24` (Sinotrack, Concox, Coban, Teltonika ট্র্যাকার, সিম ও SMS সেটআপ); সার্ভার `views_vehicle.py:145-155` (track.lifeassisto.com:5023); OBD `app/lib/vehicle/elm327.dart`, `ObdBtChannel.kt` (ব্লুটুথ ELM327) | **KEEP-COND**: GPS ট্র্যাকার যন্ত্র ও সিম, বা ELM327 অ্যাডাপ্টার কিনতে হয় | "Hardware not included" |
| 12 | স্বাস্থ্য ও ফিটনেস / Health Connect | `app/lib/screens/smartwatch_screen.dart:37` (`package:health`, শুধু পড়া: পদক্ষেপ, হার্ট রেট, ঘুম, ক্যালরি); ম্যানিফেস্টে `health.READ_*` (`android.yml:226-229`); অস্বীকৃতির লাইন আছে (`PLAY_HEALTH_DECLARATION_BN.md`) | **KEEP-COND**: Health Connect অ্যাপ আর ঘড়ি বা ফিটনেস অ্যাপের ডেটা লাগে। "Health" শিরোনাম বা চিকিৎসার দাবি চলবে না। | "Smartwatch & fitness … Not medical advice." |
| 13 | কাছেপিঠে (Nearby) | `backend/core/nearby.py:1-5,125-143`: Google Places চাবি না থাকলে OpenStreetMap Overpass থেকে আসল ডেটা আনে, কোনো নকল তালিকা নয় | **KEEP** (আগের অডিটের "নকল তালিকা" আর সত্য নয়) | "ATMs, mosques, police, fuel, restaurants (OpenStreetMap)" |
| 14 | ফটো স্টুডিও | `app/lib/screens/photo_studio_screen.dart:34-39`: এক চাপে enhance ফোনেই চলে। প্রম্পট দিয়ে এডিট, ব্যাকগ্রাউন্ড বদল, পাসপোর্ট ও ভিসার ছবি চলে ক্লাউড ইমেজ-AI দিয়ে (`app/lib/photo_studio/ps_models.dart:418-422`, `backend/core/photo_studio_service.py:81-104`)। ফ্রি ব্যবহারকারী: জলছাপসহ প্রিভিউ, সেভ করতে বিজ্ঞাপন বা ক্রেডিট লাগে। | এক চাপে enhance: **KEEP**। পাসপোর্ট, ভিসা, ব্যাকগ্রাউন্ড ও প্রম্পট: **KEEP-COND** (ইমেজ-AI চাবি) | enhance মূল লেখায়; বাকিটা AI ব্লকে |
| 15 | AI উত্তর / AI এজেন্ট | `LAUNCH_SWITCHES_8NOV_BN.md` "AI চাবি ছাড়া" অংশ: চাবি ছাড়া Assisto Brain নিয়ম মেনে উত্তর দেয় আর সৎভাবে "AI চাবি যোগ হয়নি" বলে | **KEEP-COND** (AI চাবি লাইভে চালু থাকতে হবে) | শুধু AI ব্লকে |
| 16 | E2E এনক্রিপ্টেড চ্যাট | `app/lib/screens/circle_chat_screen.dart:88-91` (X25519 + AEAD); মিডিয়া `app/lib/messaging/media/media_crypto.dart:1-14` (ChaCha20-Poly1305, ফাইল প্রতি আলাদা চাবি) | **KEEP** (লেখা, ছবি, ভয়েস নোট, ফাইল) | "end-to-end encrypted" |
| 17 | E2E এনক্রিপ্টেড কল | `app/lib/calls/webrtc_media.dart` (flutter_webrtc, ১:১, DTLS-SRTP)। কোনো SFU সার্ভার নেই। তবে নিরাপত্তা-নম্বর মিলিয়ে দেখার ব্যবস্থাও নেই। | **KEEP** "encrypted calls"। "end-to-end encrypted calls" লেখা হয়নি (সাবধানতা) | "Encrypted voice and video calls" |
| 18 | বাজেট / রেমিট্যান্স | `sidebar_sections.dart:266-275` (`budget`, `budget_remittance`, "Budget and Remittance") | **KEEP** (টাকা পাঠায় না, শুধু পরিকল্পনা ও হিসাব) | লেখা আছে |
| 19 | খাতা / CRM | `sidebar_sections.dart` ব্যবসা অংশ (`business`, `crm`)। মূল খাতা ফ্রি। AI অ্যাড-অন বিজনেস প্ল্যানে (`backend/core/business_views.py:135-165`)। | **KEEP** | লেখা আছে |
| 20 | চুরি-রোধ: লক (ফোনে) | `lost_stolen_screen.dart` (Enable, তারপর Device admin; "Test lock") | **KEEP-COND** (ব্যবহারকারী নিজে Device admin দেন) | লেখা আছে |
| 21 | চুরি-রোধ: সিম বদলের সতর্কতা | `AntiTheftService.kt:44-52,111-112` (সিমের বেসলাইন আর রিসিভার); সার্ভার `views_at_remote.py:60` (`THEFT_KINDS`: snatch, sim_change …) | **KEEP-COND** ("Always-on protection" চালু থাকতে হবে) | লেখা আছে |
| 22 | চুরি-রোধ: শেষ লোকেশন | "Report last location" (`lostStolenActionLocate`); ইঞ্জিনের heartbeat (`AntiTheftService.kt`, `doHeartbeat`) | **KEEP** (লোকেশন অনুমতি ও ইন্টারনেট লাগে) | লেখা আছে |
| 23 | রিমোট মুছে ফেলা (wipe) | `views_at_remote.py:9-11,458,573`: "wipe is NOT offered", এর বদলে Google Find Hub খোলে (`remote_switches_card.dart:291-299`) | **REMOVE** | উল্টো কথাটা লেখা আছে: "Assisto never erases a phone; use Google Find Hub" |
| 24 | বিজ্ঞাপন: "Free plan with optional ads" / "Premium: no app-open ads" | `app/lib/ads/ad_rules.dart:6-11,277` (পেইড প্ল্যানে কোনো বিজ্ঞাপনই নেই; SOS, নিরাপত্তা, কল, চ্যাট, পেমেন্ট ও লগইন পাতায় কখনো নয়); সম্মতি: `app/lib/ads/consent.dart:1-24` (Google UMP, কোনো বিজ্ঞাপন চাওয়ার আগে; সম্মতি না পেলে বিজ্ঞাপনই চায় না); Settings → "Ad privacy choices" (`ad_privacy_tile.dart:11-16`, শুধু UMP দরকার বললে দেখায়) | পুরনো লেখা **REMOVE**। নতুন লেখা **KEEP** | "Free plan shows ads. Premium and Business show no ads." |

**অন্য ছোট দাবি** (আগের অডিটে OK ছিল, আবার দেখা হয়েছে): রিমাইন্ডার, নোট, জন্মদিন, বিল, সাবস্ক্রিপশন, ধার, ভাগাভাগি, মেস, সমিতি, ভাড়া, মিটার, যাকাত, ডকুমেন্ট ভল্ট, নমিনি, CV, পুরনো ফোন যাচাই, নিরাপদ যাত্রা, নকল কল, ইমার্জেন্সি কার্ড (Play-তে মেডিকেল ঘর ছাড়া, `emergency_card_view.dart:51`)। এগুলো **KEEP**।
**ইচ্ছা করে লিস্টিংয়ে রাখা হয়নি:**
- রক্তদাতা: ব্যবহারকারীর লেখা কনটেন্ট, তাই মডারেশনের ঝুঁকি।
- দুর্যোগ সতর্কতা: অফিসিয়াল ফিড যুক্ত নেই (`kShowSampleDisasterWarnings=false`)।
- AI সেলস এজেন্ট (Facebook Page বা WhatsApp): Meta রিভিউ বাকি।
- পতন-শনাক্ত, ছোটদের ঘড়ি, Agent Studio।

---

## খ) লিস্টিংয়ের লেখা (কপি করে পেস্ট করুন)

**কোথায় পেস্ট করবেন:** Play Console → Grow users → Store presence → **Main store listing**।
- ইংরেজি: en-US।
- বাংলা: **Manage translations → Add your own translation → Bengali (bn-BD)**। আজ Play-তে বাংলা লিস্টিং নেই।

**দুটি অবস্থা:**
- **অবস্থা ১ — AI ছাড়া:** আজই পেস্ট করা যায়।
- **অবস্থা ২ — AI চালু:** আগে নিজে দেখুন, অ্যাপের AI চ্যাটে একটা সাধারণ প্রশ্নের আসল উত্তর আসে কিনা। তারপর নাম, ছোট বিবরণ আর AI ব্লক বদলান।

### অ্যাপের নাম (সীমা ৩০)
| | AI ছাড়া | AI চালু |
|---|---|---|
| en-US | `Assisto: Chat, Safety & Money` (29) | `Assisto: Chat, AI & Safety` (26) |
| bn-BD | `Assisto: চ্যাট, SOS ও হিসাব` (27) | `Assisto: চ্যাট, AI ও নিরাপত্তা` (30) |

(লাইভ নাম "Assisto: Chat, AI & Business"-এ "AI" আছে। AI চাবি চালু না হওয়া পর্যন্ত এটা বদলে "AI ছাড়া" নামটা দিন।)

### ছোট বিবরণ (সীমা ৮০)
| | লেখা | অক্ষর |
|---|---|---|
| en-US, AI ছাড়া | `Encrypted chat & calls, family SOS, reminders, money and shop khata in one app` | 78 |
| en-US, AI চালু | `AI answers plus encrypted chat & calls, family SOS, reminders, money and khata` | 78 |
| bn-BD, AI ছাড়া | `এনক্রিপ্টেড চ্যাট ও কল, পরিবারের SOS, রিমাইন্ডার, হিসাব ও দোকানের খাতা এক অ্যাপে` | 80 |
| bn-BD, AI চালু | `AI উত্তর, এনক্রিপ্টেড চ্যাট ও কল, পরিবারের SOS, রিমাইন্ডার, হিসাব ও দোকানের খাতা` | 80 |

### পুরো বিবরণ — ইংরেজি (en-US), AI ছাড়া (3582 অক্ষর, সীমা ৪০০০)
```
One app for everyday life in Bangladesh: talk to your people, keep your family safe, remember what matters, and keep your money and shop in order. In Bangla and English.

MY CIRCLE: CHAT AND CALLS
• One-to-one and group chats with the people you add to My Circle
• Messages, photos, voice notes and files are end-to-end encrypted on your phone; our server keeps only the encrypted form
• Encrypted voice and video calls, read ticks, typing and last seen
• Find friends in your contacts only if you allow it (numbers are hashed)

FAMILY AND SAFETY
• One-tap SOS sends your location to the family members you choose
• Safe Journey: share your live location on a trip; family knows when you arrive
• Hands-free Voice SOS (off by default): when you turn it on, Assisto listens for your chosen phrase and shows a notification the whole time. Speech stays on your phone. Needs a speech engine on the phone and uses battery.
• Emergency card, fake call, scam check and safety tips
Assisto is not an emergency service. In danger, call 999.

PHONE PROTECTION (Android)
• Lost / Stolen Protection: lock the screen, sound a loud alarm, show a "lost phone" message and report the last location, from another phone signed in to your account or by a trusted family member. The phone must be on and online. Locking needs Device admin, which only you can turn on.
• Always-on protection: alerts for SIM change, the phone going offline or being snatched; a notification shows while it runs
• Front-camera photo when someone types a wrong Security PIN inside Assisto (only if you turn it on; with shutter sound)
• Used phone check (Assisto community registry)
Assisto never erases a phone. To erase a lost phone, use Google Find Hub.

REMINDERS AND NOTES
• Reminders, notes, to-dos, birthdays, bills and subscriptions
• Type "Call mum at 8 tonight" or "500 for lunch" and Assisto makes the reminder or the expense

MONEY
• Income, expenses, budget, loans and a monthly summary
• Budget and Remittance: plan the money you send home from abroad
• Split bills, mess accounts, samity, house rent, prepaid meter, zakat calculator
• Assisto never holds your money

BUSINESS
• Digital khata: customer dues, payments and payment reminders
• Quick sell, products, orders, cash box and reports
• CRM: customers, leads, pipeline and quotes
• Shop Box (Business plan): turn a spare Android phone into a shop camera that alerts you with one photo. No video leaves the shop.

EVERYDAY TOOLS
• Photo Studio: one-tap photo enhance on your phone
• Nearby: ATMs, mosques, police, fuel and restaurants (OpenStreetMap data)
• Documents vault with PIN, nominee access, job tracker, CV builder
• Smartwatch & fitness: read your steps, heart rate and sleep from Health Connect, if you allow it (needs Health Connect and a watch or fitness app). Not medical advice.
• My Vehicles: live tracking with your own GPS tracker (Sinotrack, Concox, Coban, Teltonika) and car readings with a Bluetooth ELM327 OBD adapter. Hardware not included.

PLANS AND ADS
• The Free plan shows ads. Premium and Business show no ads.
• Never any ads on SOS, safety, call, chat, payment or login screens.
• Where the law requires it (for example the EEA and UK), Google's consent form asks you first. Change it any time in Settings > Ad privacy choices.
• Paid plans are bought through Google Play.

PRIVACY
We never sell your data. You decide every permission. Delete your account and data from Settings.

For adults (18+). Not medical advice. Not an emergency service.
Developer: AXON Dynamic · lifeassisto.com · Privacy: lifeassisto.com/privacy
```

### AI ব্লক — ইংরেজি (372 অক্ষর)
**শুধু AI চালু হওয়ার পরে।** প্রথম অনুচ্ছেদের পরে, "MY CIRCLE: CHAT AND CALLS"-এর ঠিক আগে বসান। বসানোর পরে মোট **3956** অক্ষর হবে, সীমার ভেতরে।
```
ASSISTO AI
• Ask anything in Bangla or English, by typing or by voice, and get a clear answer
• Business AI helper: drafts replies to customers from your own products and prices; you approve before anything is sent
• Photo Studio AI: background change and passport or visa photos (credits, or a short ad on the Free plan)
AI can make mistakes. Check important information.
```

### পুরো বিবরণ — বাংলা (bn-BD), AI ছাড়া (3470 অক্ষর)
```
বাংলাদেশের প্রতিদিনের জীবনের জন্য একটি অ্যাপ: কাছের মানুষের সাথে কথা, পরিবারের নিরাপত্তা, দরকারি কাজ মনে রাখা, আর টাকা ও দোকানের হিসাব গুছিয়ে রাখা। বাংলা ও ইংরেজিতে।

আমার সার্কেল: চ্যাট ও কল
• যাঁদের আমার সার্কেলে যোগ করবেন, তাঁদের সাথে একক ও গ্রুপ চ্যাট
• মেসেজ, ছবি, ভয়েস নোট ও ফাইল আপনার ফোনেই এন্ড-টু-এন্ড এনক্রিপ্ট হয়; আমাদের সার্ভারে থাকে শুধু এনক্রিপ্ট করা রূপ
• এনক্রিপ্টেড ভয়েস ও ভিডিও কল, পড়ার টিক, টাইপিং ও লাস্ট সিন
• আপনি অনুমতি দিলে তবেই কন্টাক্টস থেকে বন্ধু খোঁজা (নম্বর হ্যাশ করে মেলানো হয়)

পরিবার ও নিরাপত্তা
• এক চাপে SOS: আপনার বেছে নেওয়া পরিবারের সদস্যদের কাছে আপনার লোকেশন যায়
• নিরাপদ যাত্রা: যাত্রার সময় লাইভ লোকেশন শেয়ার; পৌঁছালে পরিবার জানতে পারে
• হাত না লাগিয়ে ভয়েস SOS (শুরুতে বন্ধ): আপনি চালু করলে Assisto আপনার বেছে নেওয়া বাক্যটি শোনে, পুরো সময় একটি নোটিফিকেশন দেখা যায়। কথা ফোনের বাইরে যায় না। ফোনে স্পিচ ইঞ্জিন লাগে, ব্যাটারি খরচ হয়।
• ইমার্জেন্সি কার্ড, নকল কল, প্রতারণা যাচাই ও নিরাপত্তা টিপস
Assisto জরুরি সেবা নয়। বিপদে ৯৯৯-এ কল করুন।

ফোন সুরক্ষা (Android)
• হারানো / চুরি সুরক্ষা: স্ক্রিন লক, জোরে অ্যালার্ম, লক-স্ক্রিনে "হারানো ফোন" বার্তা আর শেষ লোকেশন জানা যায়, আপনার অ্যাকাউন্টে লগইন করা অন্য ফোন থেকে বা বিশ্বস্ত পরিবারের সদস্যের মাধ্যমে। ফোন চালু ও অনলাইন থাকতে হবে। লক করতে Device admin লাগে, যা শুধু আপনি নিজে চালু করেন।
• সবসময়ের সুরক্ষা: সিম বদল, ফোন অফলাইন হওয়া বা ছিনতাই হলে সতর্কতা; চলার সময় একটি নোটিফিকেশন দেখা যায়
• Assisto-র ভেতরে কেউ ভুল সিকিউরিটি PIN দিলে সামনের ক্যামেরায় ছবি (আপনি চালু করলে; শাটারের শব্দসহ)
• পুরনো ফোন যাচাই (Assisto কমিউনিটি রেজিস্ট্রি)
Assisto কখনো ফোন মুছে দেয় না। হারানো ফোন মুছতে Google Find Hub ব্যবহার করুন।

রিমাইন্ডার ও নোট
• রিমাইন্ডার, নোট, করণীয়, জন্মদিন, বিল ও সাবস্ক্রিপশন
• লিখুন "আজ রাত ৮টায় আম্মুকে ফোন" বা "দুপুরের খাবার ৫০০", Assisto রিমাইন্ডার বা খরচ বানিয়ে দেবে

হিসাব ও অর্থ
• আয়, খরচ, বাজেট, ধার আর মাসের সারাংশ
• বাজেট ও রেমিট্যান্স: বিদেশ থেকে বাড়িতে পাঠানো টাকার পরিকল্পনা
• খরচ ভাগাভাগি, মেসের হিসাব, সমিতি, বাড়িভাড়া, প্রিপেইড মিটার, যাকাত হিসাব
• Assisto কখনো আপনার টাকা নিজের কাছে রাখে না

ব্যবসা
• ডিজিটাল খাতা: গ্রাহকের বাকি, জমা আর তাগাদা
• দ্রুত বিক্রি, পণ্য, অর্ডার, ক্যাশবক্স ও রিপোর্ট
• CRM: গ্রাহক, লিড, পাইপলাইন ও কোটেশন
• শপ বক্স (বিজনেস প্ল্যান): একটি বাড়তি Android ফোনকে দোকানের ক্যামেরা বানান, সন্দেহ হলে একটি ছবিসহ সতর্কতা আসে। কোনো ভিডিও দোকানের বাইরে যায় না।

প্রতিদিনের টুল
• ফটো স্টুডিও: ফোনেই এক চাপে ছবি সুন্দর করা
• কাছেপিঠে: ATM, মসজিদ, থানা, পেট্রোল পাম্প ও রেস্টুরেন্ট (OpenStreetMap তথ্য)
• PIN-সুরক্ষিত ডকুমেন্টস, নমিনি, চাকরির ট্র্যাকার, সিভি বানানো
• স্মার্টওয়াচ ও ফিটনেস: আপনি অনুমতি দিলে Health Connect থেকে পদক্ষেপ, হার্ট রেট ও ঘুম দেখা (Health Connect আর ঘড়ি বা ফিটনেস অ্যাপ লাগে)। এটি চিকিৎসা-পরামর্শ নয়।
• আমার গাড়ি: নিজের GPS ট্র্যাকার (Sinotrack, Concox, Coban, Teltonika) দিয়ে লাইভ ট্র্যাকিং, আর ব্লুটুথ ELM327 OBD অ্যাডাপ্টার দিয়ে গাড়ির তথ্য। যন্ত্র আলাদা কিনতে হয়।

প্ল্যান ও বিজ্ঞাপন
• ফ্রি প্ল্যানে বিজ্ঞাপন দেখায়। প্রিমিয়াম ও বিজনেসে কোনো বিজ্ঞাপন নেই।
• SOS, নিরাপত্তা, কল, চ্যাট, পেমেন্ট বা লগইন পাতায় কখনো বিজ্ঞাপন নেই।
• আইনে যেখানে লাগে (যেমন EEA ও যুক্তরাজ্য), সেখানে আগে Google-এর সম্মতি-ফর্ম জিজ্ঞেস করে। যেকোনো সময় বদলান: Settings > Ad privacy choices।
• পেইড প্ল্যান কেনা হয় Google Play দিয়ে।

গোপনীয়তা
আমরা আপনার তথ্য বিক্রি করি না। প্রতিটি অনুমতি আপনার হাতে। Settings থেকে অ্যাকাউন্ট ও তথ্য মুছতে পারবেন।

শুধু প্রাপ্তবয়স্কদের জন্য (১৮+)। চিকিৎসা-পরামর্শ নয়। জরুরি সেবা নয়।
ডেভেলপার: AXON Dynamic · lifeassisto.com · গোপনীয়তা নীতি: lifeassisto.com/privacy
```

### AI ব্লক — বাংলা (343 অক্ষর)
**শুধু AI চালু হওয়ার পরে।** প্রথম অনুচ্ছেদের পরে, "আমার সার্কেল: চ্যাট ও কল"-এর ঠিক আগে বসান। বসানোর পরে মোট **3815** অক্ষর হবে।
```
Assisto AI
• বাংলা বা ইংরেজিতে, লিখে বা বলে, যেকোনো প্রশ্ন করুন, পরিষ্কার উত্তর পান
• ব্যবসার AI সহকারী: আপনার নিজের পণ্য ও দাম দেখে গ্রাহকের উত্তরের খসড়া বানায়; আপনি অনুমোদন দিলে তবেই যায়
• ফটো স্টুডিও AI: ব্যাকগ্রাউন্ড বদল আর পাসপোর্ট বা ভিসার ছবি (ক্রেডিট, বা ফ্রি প্ল্যানে একটি ছোট বিজ্ঞাপন)
AI ভুল করতে পারে। দরকারি তথ্য যাচাই করে নিন।
```

অক্ষর গোনা হয়েছে `python3 len()` দিয়ে। Play-ও প্রায় এভাবেই গোনে। পেস্ট করার পরে Console-এর কাউন্টারে একবার দেখে নিন। বাংলা যুক্তাক্ষরে সংখ্যা ১–২টা এদিক-ওদিক হতে পারে, তবু সীমা থেকে অনেক দূরে।

**লেখায় যা ইচ্ছা করে নেই:**
- ওষুধ, ডাক্তার, "Health" শিরোনাম, "Hey Assisto", "hands-free voice assistant"।
- কুরিয়ার বুকিং, রিমোট wipe, "map", "jobs hub", ট্রায়াল।
- "never invents"-এর মতো চূড়ান্ত দাবি, আর "optional ads"।

---

## গ) স্ক্রিনশট — ৮টি (CI গ্যালারির নাম অনুযায়ী)

গ্যালারি: `app/test/screenshots_test.dart`। ফাইলের নাম হয় `<shot>_<en|bn>_light.png` (`:1010`)। CI আর্টিফ্যাক্ট `shots-*`।

**⚠️ সব শটের আগে একটা জরুরি কথা:**
- গ্যালারি আজ **Play-মোডে চলে না।** টেস্টে `AppConfig.playStore` = false, আর `debugMedicalFeaturesOverride` কোথাও বসানো হয়নি। তাই হোমের শর্টকাট, ফ্যামিলি, ইমার্জেন্সি কার্ড আর শেয়ারিং-এ ওষুধের অংশ দেখা যেতে পারে।
- নকল ডেটায় (`app/test/fake_api.dart:351`) রিমাইন্ডার হিসেবে **"Take medicine / ওষুধ খাও"** আছে।
- **ঠিক করার ছোট উপায়** (আমি করিনি):
  - `screenshots_test.dart`-এ store-শট চালানোর সময় `debugMedicalFeaturesOverride = false` বসান।
  - `fake_api.dart:351`-এর লেখা বদলে "Call mum / আম্মুকে ফোন" করুন।
  - তারপর CI-তে শটগুলো আবার তুলুন।
- না হলে আসল ফোনে তুলুন (`PLAY_SCREENSHOTS_SHOTLIST_BN.md`)।

| # | গ্যালারি শট | ক্যাপশন (en) | ক্যাপশন (bn) | অবস্থা |
|---|---|---|---|---|
| 1 | `home_v2` (`app/test/home_v2_shots.dart:32`; বিজ্ঞাপনসহ `home_v2_free_ad` **নয়**) | Your day, in one app | আপনার দিনের সব, এক অ্যাপে | **আবার তুলুন** Play-মোডে (হোমের শর্টকাটে ওষুধ লুকানো থাকে `home_quick_buttons.dart:12`; গ্যালারিতে লুকানো থাকে না) |
| 2 | `c3_chat` (`:842`) | Encrypted chat with your people | কাছের মানুষের সাথে এনক্রিপ্টেড চ্যাট | ঠিক আছে |
| 3 | `incoming_call` (`:657`) | Encrypted voice & video calls | এনক্রিপ্টেড ভয়েস ও ভিডিও কল | ঠিক আছে |
| 4 | `journey_live` (`:694`) | Safe Journey: family knows you arrived | নিরাপদ যাত্রা: পৌঁছালে পরিবার জানে | ঠিক আছে (ম্যাপের টাইল ছাড়া রুটের ছবি দেখায়, তাই "map" লিখবেন না) |
| 5 | `safety` (`:663`) | One-tap SOS and hands-free Voice SOS | এক চাপে SOS, হাত না লাগিয়ে ভয়েস SOS | ঠিক আছে। `emergency` শট **নেবেন না** (মেডিকেল কার্ডের ঘর দেখা যায়)। |
| 6 | `remnotes_reminders` / `reminders` (`:618`, `:626`) | Reminders that really ring | যে রিমাইন্ডার সত্যিই বাজে | **আবার তুলুন** ("Take medicine" দেখা যায়) |
| 7 | `money_budget` (`:516`) | Money and budget, made clear | হিসাব আর বাজেট, পরিষ্কার | ঠিক আছে। পুরনো `money` শট নেবেন না (ব্যালান্স ৳২০,৮০০ কিন্তু নেট ওয়ার্থ ৳০, সংখ্যা মেলে না)। |
| 8 | `biz_khata` (`:757`) | Digital khata for your shop | দোকানের ডিজিটাল খাতা | ঠিক আছে |

**বিকল্প শট** (৮টির কোনোটা বদলাতে চাইলে):
- `at_protection_on` (`:749`): "Phone protection: SIM change and snatch alerts" / "ফোন সুরক্ষা: সিম বদল ও ছিনতাইয়ের সতর্কতা"।
- `shop_box` (`:811`): "Shop Box: one photo alert, no video" / "শপ বক্স: ছবিসহ সতর্কতা, ভিডিও নয়"। লিখতে হবে যে এটা বিজনেস প্ল্যানে।

**এই শটগুলো ব্যবহার করবেন না:**
- **ওষুধ বা স্বাস্থ্য (Play-তে লুকানো):** `medicine_history`, `medicine_db`, `health_tips`, `doctor`, `health_tl`, `emergency`, `family` ও `famcare_*` (ওষুধ শেয়ারিং দেখা যেতে পারে)।
- **আসল উৎস নেই, শুধু নমুনা ম্যাচ দেখায়:** `jobs` (`kJobsFeedConnected=false`)।
- **AI চাবি ছাড়া দেখানো যায় না বা প্ল্যান লাগে:** `voice_assistant`, `ai_chat`, `daily_brief`।
  - `owner_actions/play_store/phone_*_4_voice_assistant.png` খুলে দেখুন। ওষুধ বা AI-উত্তর থাকলে বাদ দিন।
- **বিজ্ঞাপন দেখায়:** `home_v2_free_ad`।
- **আমাদের দাবির বাইরে:** `kids_watch`, `agent_studio`।

**এখনকার Play-ছবি** (`owner_actions/play_store/phone_*_1..8`):
- ৪ নম্বর (`voice_assistant`) আর ৬ নম্বর (`family`) আবার দেখুন বা বদলান।
- ৮ নম্বর (`shop_cameras`) শুধু বিজনেস প্ল্যানে কাজ করে, ক্যাপশনে সেটা লিখতে হবে।

---

## ঘ) Play রিভিউয়ার ও pre-launch রোবটের পথ

### ১. রিভিউয়ার কীভাবে লগইন করবেন (OTP ছাড়া) — পাওয়া গেছে ✅
- **লগইন পাতা:** অ্যাপ খুললে প্রথমে ভাষা বাছাই আসে, তারপর `LoginScreen` (`app/lib/main.dart:545-564`)। এই পাতায় "Phone or email" আর "Password" ঘর আর "Log in" বোতাম আছে (`app/lib/screens/login_screen.dart:153-185`)। এখানে **কোনো OTP লাগে না**।
- **সার্ভার:** `POST /auth/login` (`backend/core/urls.py:74`) → `LoginView` (`backend/core/views.py:163-190`)। ফোন, ইমেইল বা ইউজারনেম আর পাসওয়ার্ড মিললেই টোকেন দেয়। কোনো OTP বা নতুন-ডিভাইস যাচাই নেই।
- **রিভিউয়ারের ডেমো অ্যাকাউন্ট:** `backend/core/management/commands/seed_play_reviewer.py`।
  - এটা সার্ভারের `.env` থেকে পড়ে: `PLAY_REVIEWER_PHONE` (০১০… দিয়ে শুরু, আসল নয় এমন নম্বর), `PLAY_REVIEWER_PASSWORD` (১২+ অক্ষর), ঐচ্ছিক `PLAY_REVIEWER_PEER_ID` (দ্বিতীয় টেস্ট অ্যাকাউন্ট, My Circle-এ যুক্ত হয়)।
  - অ্যাকাউন্টটা বানায় বা নতুন করে, আর ১ বছরের **Premium** দেয় (রেকর্ড করা grant, `source=play_reviewer`; `:53-58`)।
  - নমুনা রিমাইন্ডার, নোট, করণীয় আর খরচও বসায়।
- **ঠিক করা OTP-কোড** (`PLAY_REVIEWER_OTP`, `backend/core/otp.py:116-133,431-449`) **আজ কাজ করবে না।**
  - কারণ: `issue()` শুরুতেই দেখে SMS gateway যুক্ত আছে কিনা (`otp.py:411`), না থাকলে ৫০৩ ফেরত দেয়। লাইভে SMS বন্ধ।
  - **তাই রিভিউয়ারকে "Sign in with SMS code" নয়, পাসওয়ার্ড দিয়ে লগইন করতে বলুন।**
- **নম্বর লেখার নিয়ম:** ০১০… নম্বরটা আসল বাংলাদেশি মোবাইল সিরিজের বাইরে। তাই লগইন পাতায় নম্বর **হুবহু** সেভাবে লিখতে হবে, যেভাবে `.env`-এ আছে (১১ সংখ্যা, ০১০…, ফাঁকা বা +৮৮০ ছাড়া)। কারণ `LoginView` এই নম্বর খোঁজে হুবহু মিলিয়ে (`views.py:174-175`)।

**আপনার কাজ (Play-তে পাঠানোর আগে, ১০ মিনিট):**
1. সার্ভারে `.env`-এ উপরের তিনটি মান আছে কিনা দেখুন। তারপর `python manage.py seed_play_reviewer` একবার চালান। এটা আপনার নিজের কাজ, আমি সার্ভারে কিছু চালাইনি।
2. **Play বিল্ড** (internal testing) দিয়ে ওই নম্বর আর পাসওয়ার্ডে একবার লগইন করে দেখুন।
3. নমুনা-ডেটায় **"Doctor appointment — Bring last prescription"** রিমাইন্ডার আছে (`seed_play_reviewer.py:71`)।
   - Play বিল্ডে মেডিকেল লুকানো, তাই রিভিউয়ারের চোখে এটা অসঙ্গতি।
   - **ছোট সমাধান:** লাইনটা বদলে `("Pay internet bill", …, "Monthly package")` করুন, তারপর seed আবার চালান। কোডের এই পরিবর্তন আমি করিনি।
4. **শপ বক্স** দেখাতে রিভিউয়ারের **Business** প্ল্যান লাগে (Premium-এ "upgrade" কার্ড দেখায়)।
   - Owner Admin → ব্যবহারকারী → Play Reviewer → প্ল্যান grant → **Business**।
   - অথবা seed-এ `plan="business"` করুন।
5. দ্বিতীয় টেস্ট অ্যাকাউন্ট ("Salma") বানান এবং `PLAY_REVIEWER_PEER_ID`-এ দিন। এতে কল আর চ্যাটের অন্য পাশে কেউ থাকে।

### ২. Play Console → App content → **App access**-এ যা দেবেন
- বাছুন: **"All or some functionality in my app is restricted"** → **Add instructions**।
- **Name:** `Assisto reviewer (password sign-in)`
- **Username / Password:** `owner_private/play_reviewer.txt` থেকে আপনি নিজে বসাবেন। এখানে লেখা হয়নি।
- **"Any other information"**-এ এই লেখাটা পেস্ট করুন (ইংরেজি):

```
1. Open the app, choose English, tap Continue.
2. On "Log in", type the phone number EXACTLY as given (11 digits, starting 010) in "Phone or email", type the password, tap "Log in". Do NOT use "Sign in with SMS code" (SMS is not used for this account).
3. Skip or finish the short welcome steps. The account is Premium (no ads) and has sample reminders, notes and expenses.
4. Open the menu (top-left) to reach every feature. Paths for features that use sensitive permissions:
   - Location (foreground service): Menu > Family & Safety > Safe Journey > Start a journey > Start journey. A notification shows while the journey runs; end the journey on the same screen.
   - Microphone + location (foreground service): Menu > Family & Safety > Emergency > Safety tools > Hands-free Voice SOS > turn on. It is off by default; the notification shows while it listens. Turn it off on the same screen or with "Stop" in the notification.
   - Device admin + location (foreground service): Menu > Family & Safety > Lost / Stolen Protection > Enable (Android asks for Device admin) > "Test lock" / "Test alarm" / "Report location now". "Always-on protection" on the same screen > Turn on (permanent notification). Turn off: same screen (asks the Recovery PIN you set).
   - Contacts: Menu > My Circle > New chat > read "Find your people on Assisto" > continue > Android asks for Contacts > Allow. Only hashed numbers are checked.
   - Camera: in a My Circle chat, start a video call or take a photo to send; Shop Box mode below also uses the camera.
   - Health Connect (read only): Menu > Daily Life > Smartwatch & fitness > Connect Health Connect > Allow & connect. Needs the Health Connect app; without a watch or fitness app the screen shows no data.
   - Calls (microphone foreground service, full-screen incoming call): Menu > My Circle > open the chat with the second test account > call button. Receiving a call needs a second phone signed in to the second test account; see the attached video.
   - Shop Box (camera, Business plan): Menu > Family & Safety > Shop Box > "Use this phone as a Shop Box". The screen stays on while it watches; no video leaves the phone.
   - Vehicle tracking: Menu > Daily Life > My Vehicles > Live tracking. Needs a GPS tracker device with a SIM (Sinotrack / Concox / Coban / Teltonika); see the attached video.
5. Medicine, doctor and prescription features are not part of this Google Play version.
```

- **ভিডিও লিংক** (Play-র FGS ও Health ঘোষণার জন্য দরকারি, unlisted YouTube):
  - যাত্রা শুরু থেকে শেষ।
  - ভয়েস SOS চালু, নোটিফিকেশন, তারপর বন্ধ।
  - Device admin দেওয়া আর "Test lock"।
  - দুই ফোনে কল আসা (পুরো স্ক্রিনে)।
  - Health Connect-এ অনুমতি দেওয়া।
  - GPS ট্র্যাকার যুক্ত করা আর লাইভ দেখা।
  - শপ বক্স মোড।
  - বিস্তারিত: `PLAY_FGS_DECLARATION_BN.md`, `ANTITHEFT_PLAY_DECLARATION_BN.md`, `PLAY_HEALTH_DECLARATION_BN.md`, `CCTV_PLAY_DECLARATIONS_BN.md`।

### ৩. Pre-launch report রোবট (Play Console → Testing → Pre-launch report → Settings)
- **App sign-in credentials**-এ দিন:
  - Username resource name: `tl_login_id`
  - Password resource name: `tl_login_password`
  - Sign-in button resource name: `tl_login_submit`
- এগুলো Flutter Semantics identifier, Android-এ resource-id হিসেবে যায় (`app/lib/widgets/robo_id.dart:3-7`; `login_screen.dart:153,160,172`)।
- ভাষার পাতার id: `tl_lang_en`, `tl_lang_continue` (`language_picker_screen.dart:48,72`)। Test Lab-এর Robo স্ক্রিপ্ট আগেই এগুলো ব্যবহার করে (`tools/testlab/robo_mycircle.json`)।
- **ব্যবহারকারী আর পাসওয়ার্ড: রিভিউয়ারের অ্যাকাউন্ট নয়, আলাদা একটা টেস্ট অ্যাকাউন্ট দিন।** কারণ:
  - একই অ্যাকাউন্টের সব ডিভাইস একটাই টোকেন ভাগ করে (`views.py:188` `Token.get_or_create`)।
  - রোবট "Log out" চাপলে টোকেন মুছে যায় (`views.py:193-196`)। তখন ঠিক সেই সময়ে রিভিউয়ারও লগআউট হয়ে যাবেন।
  - এছাড়া প্রতিটি নতুন ডিভাইস লগইনে নিজের E2E চাবি সার্ভারে দেয় (`state.dart:343-345`)। তাতে ওই অ্যাকাউন্টের চ্যাট-পার্টনারের সাথে এনক্রিপশন-চাবি বারবার বদলায়।
- **রোবট যা পারবে না** (সমস্যা নয়, স্বাভাবিক):
  - Device admin দেওয়া।
  - Health Connect-এর অনুমতি।
  - দ্বিতীয় ফোন থেকে কল।
  - GPS ট্র্যাকার, শপ বক্সের ক্যামেরা।
  - ভয়েস SOS শোনা।

### ৪. কোথায় রিভিউয়ার নিজে পৌঁছাতে পারবেন না (রিভিউ নোটে লিখুন, ভিডিও দিন)
| ফিচার | কেন পারবেন না | কী দেবেন |
|---|---|---|
| কল আসা (full-screen intent, Telecom) | দ্বিতীয় ফোন ও দ্বিতীয় অ্যাকাউন্ট লাগে | দ্বিতীয় অ্যাকাউন্টের লগইনও App access-এ দিন (ঐচ্ছিক), আর ভিডিও |
| রিমোট লক অন্য ফোন থেকে | দ্বিতীয় ফোন লাগে | একই ফোনে "Test lock" দেখান, বাকিটা ভিডিওতে |
| Health Connect ডেটা | Health Connect অ্যাপ আর ঘড়ি বা ফিটনেস অ্যাপ লাগে | অনুমতির ধাপ রিভিউয়ার নিজে দেখতে পারেন, ডেটা দেখান ভিডিওতে |
| গাড়ির GPS / OBD | আলাদা যন্ত্র লাগে | ভিডিও |
| শপ বক্স (নেটওয়ার্ক CCTV) | ক্যামেরা আর পিসি-গেটওয়ে লাগে | ফোন-মোড রিভিউয়ার নিজে চালাতে পারেন (Business প্ল্যান দিলে), বাকিটা ভিডিওতে |
| ভয়েস SOS আসল SOS পাঠানো | পরিবারের সদস্যের কাছে সতর্কতা যায় | চালু ও বন্ধ করা রিভিউয়ার নিজে পারেন। পুরো SOS দেখান ভিডিওতে। রিভিউ নোটে লিখুন: "test SOS goes only to the sample family member" |

### ৫. লঞ্চ আটকাবে এমন কিছু?
- **OTP ছাড়া রিভিউয়ারের লগইন আছে।** তাই "লগইন পারা যায় না" ধরনের কোনো ব্লকার **নেই**।
- **শর্ত একটাই:** সার্ভারে রিভিউয়ারের অ্যাকাউন্ট বানানো থাকতে হবে, আর পাসওয়ার্ড দিয়ে লগইন হতে হবে (উপরের "আপনার কাজ" ১–২)। লগইন না হলে রিভিউ সঙ্গে সঙ্গে আটকাবে।
- **ব্যাকআপ পথ** (দরকার হলে, আমি এখন করিনি): `otp.py:411`-এর SMS-চেকের আগে রিভিউয়ারের নম্বর আর `purpose="login"` হলে ঠিক করা কোডটা মেনে নেওয়া। ফাইল: `backend/core/otp.py` (`issue`, ৪০৪–৪৫০ লাইন)। আর `backend/core/views_otp.py`-এ status-এ `sms_enabled` থাকা। তবে পাসওয়ার্ড-লগইন থাকায় এটা দরকার নেই।

---

## ঙ) অন্য যা পাওয়া গেছে (ঠিক করার প্রস্তাব, আমি কোড বা ARB বদলাইনি)
1. **Trust পাতার এনক্রিপশন-লেখা পুরনো।** `trustE2eBody` (ARB) বলছে "Photos, voice and video can't be sent in Connected Circle today"। অথচ এখন মিডিয়াও এনক্রিপ্ট হয়ে যায় (`media_crypto.dart`)। লেখাটা আপডেট করা দরকার, শুধু ARB-এর কাজ।
2. **`fall_detect`** Play-তে বন্ধ রাখুন। ইঞ্জিন আছে, কিন্তু আসল ফোনে প্রমাণ বাকি।
3. **`MAP_TILE_URL`** লাইভে বসানো আছে কিনা দেখুন। না থাকলে যাত্রা আর গাড়ির পাতায় ম্যাপ নয়, শুধু রুটের ছবি দেখায়। লিস্টিংয়ে তাই "map" লেখা হয়নি।
4. **Data safety ও ঘোষণা:** সব চালু থাকলে এগুলো ম্যানিফেস্টে থাকে এবং প্রতিটির জন্য ঘোষণা লাগবে।
   - Health Connect (`READ_STEPS`, `READ_HEART_RATE`, `READ_SLEEP`, `READ_ACTIVE_CALORIES_BURNED`)
   - Device admin
   - Location FGS (AntiTheftService, যাত্রা)
   - Microphone ও location FGS (ভয়েস SOS)
   - `USE_FULL_SCREEN_INTENT`, `MANAGE_OWN_CALLS`
   - `READ_CONTACTS`, `CAMERA`
   - `AD_ID`
   - "Hey Assisto"-র মাইক-সার্ভিস Play থেকে সরানো, ওটা ঘোষণা করবেন না।
5. **Ads declaration:** "Contains ads = Yes"।
