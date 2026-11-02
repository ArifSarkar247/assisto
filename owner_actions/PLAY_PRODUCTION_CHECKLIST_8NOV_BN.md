# Play Production চেকলিস্ট — ৮ Nov সরু লঞ্চ (মালিকের জন্য, ধাপে ধাপে)

**তৈরি:** ২ Nov ২০২৬ (CC আইটেম A4)।

**উৎস:**
- অ্যাপের আসল কোড, আর CI-তে তৈরি হওয়া Play ম্যানিফেস্ট (`.github/workflows/android.yml`)।
- লাইভ সার্ভার, শুধু পড়া হয়েছে।
- প্রস্তাবিত সুইচ-সেট: `LAUNCH_SWITCHES_8NOV_BN.md`।

পুরনো ডকগুলোর কথা এখানে আবার লেখা হয়নি, শুধু লিংক দেওয়া আছে। যেখানে পুরনো ডক আর কোড আলাদা কথা বলে, সেটা **⚠️ অমিল** অংশে আছে।

> **মূল নিয়ম:** Play Console-এ যা ঘোষণা করবেন আর স্টোর-লিস্টিংয়ে যা লিখবেন, তা যেন **শুধু ৮ Nov-এ চালু ফিচারের** সাথে মেলে। বন্ধ ফিচারের দাবি লিখলে রিভিউ আটকাতে পারে। অনুমতি থেকে গেলেও তাই।

---

## ধাপ ১ — Production access আছে কিনা (সবার আগে, আজই দেখুন)

ব্যক্তিগত (personal) ডেভেলপার অ্যাকাউন্ট ১৩ Nov ২০২৩-এর পরে খোলা হলে Google একটা শর্ত দেয়: production-এর আগে **closed testing-এ কমপক্ষে ১২ জন টেস্টার, টানা ১৪ দিন opt-in** থাকতে হবে। তারপর "Apply for production" ফর্ম দিতে হয়, যার রিভিউ সাধারণত ~৭ দিন।

**কোথায় দেখবেন:**
1. Play Console → Assisto → বাঁদিকে **Dashboard**। উপরে "Apply for production" কার্ড থাকলে সেখানে লেখা থাকবে "x/12 testers" আর "y/14 days"। কার্ড না থাকলে আর **Test and release → Production** খোলা গেলে, শর্ত আপনার জন্য প্রযোজ্য নয় বা পূরণ হয়ে গেছে।
2. **Test and release → Testing → Closed testing → (আপনার track) → Testers** ট্যাবে opt-in করা টেস্টারের সংখ্যা দেখুন। মনে রাখুন:
   - শুধু **opt-in করা** টেস্টাররাই গোনা হয়;
   - ১৪ দিন **টানা** লাগে;
   - মাঝে কেউ বের হয়ে গেলে গোনা কমে।
3. যদি এখনো ১৪ দিন না হয়ে থাকে, **৮ Nov-এ production সম্ভব নয়।** তাহলে সৎ পথ দুটো:
   - closed testing-এ ১২+ জন রেখে দিন গুনতে থাকুন, তারপর ফর্ম;
   - অথবা organization অ্যাকাউন্টে যান (`PLAY_ORGANIZATION_ACCOUNT_BN.md`)। সেখানে এই শর্ত নেই, মেডিকেলও খোলা যায়, কিন্তু D-U-N-S যাচাইয়ে সময় লাগে।
4. "Apply for production" ফর্মে Google জানতে চায়:
   - টেস্টার কীভাবে পেলেন;
   - তাঁদের মতামতে কী বদলেছেন;
   - অ্যাপ কাদের জন্য।

   সৎভাবে লিখুন: My Circle / নিরাপদ যাত্রা / SOS / খাতা-এর পরীক্ষা, ইয়ারফোন আর কল ঠিক করা (বিল্ড ২৭৭–২৭৮)।

## ধাপ ২ — সুইচ বসানো (production রিলিজের আগে)

`LAUNCH_SWITCHES_8NOV_BN.md`-এর "হ্যাঁ"-তালিকা অনুযায়ী Owner Admin → Features-এ যান। শুধু **enabled_play** টিক বদলান।

তারপর নিজের দ্বিতীয় (সাধারণ, owner নয়) অ্যাকাউন্টে Play বিল্ড খুলে দেখুন:
- ড্রয়ারে শুধু চালু ফিচার আছে;
- হোমের উপরে ফটো বোতাম নেই;
- শর্টকাটে CCTV, গাড়ি বা AI সেলস নেই।

## ধাপ ৩ — Data safety ফর্ম (Policy → App content → Data safety)

প্রথম প্রশ্নগুলোর উত্তর:
- **"Does your app collect or share user data?" → হ্যাঁ।**
- **"Is all data encrypted in transit?" → হ্যাঁ।** সব HTTPS, চ্যাট/মিডিয়া/ভয়েস নোট এন্ড-টু-এন্ড এনক্রিপ্টেড।
- **"Do you provide a way to request deletion?" → হ্যাঁ।** অ্যাপে Settings → অ্যাকাউন্ট মুছুন, আর ওয়েবে `https://lifeassisto.com/delete-account`।

| ডেটার ধরন (Play-র নাম) | ঘোষণা | কেন (কোড থেকে) |
|---|---|---|
| **Location → Precise location** | Collected, **optional**; উদ্দেশ্য App functionality (+ Safety)। Shared: না। | SOS (`/family/sos`, `/journey/sos`) আর নিরাপদ যাত্রা (৩০ সেকেন্ডে একটা বিন্দু, ব্যাচে পাঠানো), শুধু ব্যবহারকারী চালু করলে। পরিবারকে দেখানো ব্যবহারকারীর নিজের পাঠানো, তাই Play-র "sharing" নয়। |
| **Location → Approximate location** | Shared with AdMob (Advertising) | বিজ্ঞাপন SDK IP থেকে আন্দাজ করে। `ADMOB_PLAY_DECLARATIONS_BN.md` দেখুন। |
| **Background location** | **ঘোষণা লাগবে না** | `ACCESS_BACKGROUND_LOCATION` Play ম্যানিফেস্টে **নেই**। লোকেশন চলে শুধু foreground service দিয়ে, নোটিফিকেশন দেখিয়ে। |
| **Personal info → Name, Email, Phone number** | Collected, **required**; App functionality, Account management | সাইন-ইন, OTP, প্রোফাইল। খাতা/CRM-এ দোকানির লেখা গ্রাহকের নাম-নম্বরও সার্ভারে থাকে, তাই নাম ও ফোন ঘোষণা করুন। |
| **Contacts** | Collected, optional; App functionality | ফোনবুক ফোনেই পড়া হয়। নম্বর সার্ভার-salt দিয়ে **hash** হয়ে শুধু hash যায় (`messenger/contacts/match`)। Google hash-কেও "collected" ধরে, তাই ঘোষণা করুন। |
| **Messages → Other in-app messages** | Collected, optional; App functionality | My Circle মেসেজ এন্ড-টু-এন্ড এনক্রিপ্টেড, আমরা পড়তে পারি না। নিরাপদ পথ হলো ঘোষণা করা: "encrypted in transit"। |
| **Audio → Voice or sound recordings** | Collected, optional; App functionality | My Circle ভয়েস নোট এনক্রিপ্ট হয়ে আপলোড হয়। ⚠️ পুরনো `PLAY_STORE_PACK.md:273-276` বলে "audio collected নয়" — **ভুল, এখন ঘোষণা করুন।** কল (WebRTC) রেকর্ড হয় না। |
| **Photos and videos** | Collected, optional; App functionality | My Circle মিডিয়া (E2E), ডকুমেন্ট ভল্ট, প্রোফাইল ছবি। Photo Picker ব্যবহার হয়, `READ_MEDIA_*` Play-তে নেই (CI চেক করে)। |
| **Financial info → Purchase history** | Collected, required for purchases; App functionality | Play Billing টোকেন সার্ভারে যাচাই হয় (`core/payments/play.py`) |
| **Financial info → Other financial info** | Collected, optional; App functionality | বাজেট, খরচ, রেমিট্যান্স, খাতার বাকি — ব্যবহারকারী নিজে লেখেন, সার্ভারে থাকে |
| **Health info** | **৮ Nov সেটে: না** | পরিবার কার্ডের রক্তের গ্রুপ **শুধু ফোনে** থাকে (`fam_card_section.dart:103`)। জরুরি কার্ডের মেডিকেল ঘর Play-তে লুকানো (`emergency_screen.dart:468`)। রক্তদাতা (`blood_donor`, সার্ভারে পাঠায়) আর পানি-ঘুম-ফিটনেস (`wellness`/`fitness`) **বন্ধ** থাকবে। এগুলোর কোনোটা চালু করলে "Health info: collected" ঘোষণা যোগ করুন। |
| **App activity → App interactions** | Collected (Analytics) + Shared with AdMob (Advertising) | বিজ্ঞাপনের impression/click আমাদের সার্ভারেও যায় (`ads/ad_telemetry.dart`) |
| **App info and performance → Crash logs, Diagnostics** | Collected; Analytics/App functionality | নিজের `/client/crash-report` (ফোনের ব্র্যান্ড, মডেল, Android ভার্সন) + Firebase Crashlytics (লগইনের পরে) |
| **Device or other IDs** | Collected + Shared with AdMob (Advertising) | `AD_ID` অনুমতি CI নিজে যোগ করে (W:461) |

**Ads:** App content → **Ads → "Yes, my app contains ads"** (Free প্ল্যানে ব্যানার/নেটিভ/রিওয়ার্ডেড)। বিস্তারিত: `ADMOB_PLAY_DECLARATIONS_BN.md`।

## ধাপ ৪ — Foreground service, Full-screen intent ও অন্যান্য ঘোষণা

**কোথায়:** Policy → App content → Foreground service permissions, ইত্যাদি। **Play AAB-এ আসলে যা আছে** (CI-এর তৈরি ম্যানিফেস্ট):

| ম্যানিফেস্টে | কোন ফিচার (৮ Nov চালু?) | ঘোষণা |
|---|---|---|
| `flutter_foreground_task` সার্ভিস: `microphone\|location` | ভয়েস SOS (মাইক+লোকেশন, ✅), কল চালু রাখা (মাইক, ✅), নিরাপদ যাত্রা (লোকেশন, ✅) | **Microphone** আর **Location** দুটো FGS ঘোষণাই লাগবে। ভিডিওতে দেখান: SOS, চলমান কল, নিরাপদ যাত্রা। `PLAY_FGS_DECLARATION_BN.md` ব্যবহার করুন, কিন্তু নিচের ⚠️ অমিল ১–৩ ঠিক করে। |
| `WakeWordService`: `microphone` | "Hey Assisto" — **Play বিল্ডে বন্ধ** (`VaWake.shipped` = false) | ⚠️ ফিচার নেই অথচ সার্ভিস আছে। ধাপ ৫ দেখুন। |
| `AntiTheftService`: `location` + **Device admin receiver** (`BIND_DEVICE_ADMIN`; নীতি শুধু force-lock আর watch-login) | চুরি-রোধ — **৮ Nov-এ বন্ধ** | ⚠️ ধাপ ৫ দেখুন। ঘোষণা দিলে `ANTITHEFT_PLAY_DECLARATION_BN.md`। |
| `USE_FULL_SCREEN_INTENT` | ইনকামিং কল ও SOS অ্যালার্ম (✅) | Android 14+-এর জন্য Play Console-এ **Full-screen intent** ঘোষণা: "calling" + "alarms". `PLAY_FGS_DECLARATION_BN.md` §৪। |
| `MANAGE_OWN_CALLS`, `CALL_PHONE`, `BIND_VOICE_INTERACTION` | My Circle কল (✅), Assisto Voice-এর "কল করো" আর ডিফল্ট-সহকারী (✅) | আলাদা ফর্ম নেই। লিস্টিংয়ে কল আর ভয়েস-সহকারীর উল্লেখ রাখুন। |
| `SCHEDULE_EXACT_ALARM` (`USE_EXACT_ALARM` সরানো) | রিমাইন্ডার (✅) | ঘোষণা লাগে না |
| Health Connect: `READ_STEPS`, `READ_HEART_RATE`, `READ_SLEEP`, `READ_ACTIVE_CALORIES_BURNED` | স্মার্টওয়াচ — **৮ Nov-এ বন্ধ** | ⚠️ ধাপ ৫ দেখুন। ঘোষণা দিলে `PLAY_HEALTH_DECLARATION_BN.md`। |
| `READ_CONTACTS`, `CAMERA`, `RECORD_AUDIO`, `BLUETOOTH_CONNECT`, `POST_NOTIFICATIONS` | ফোনবুক, ভিডিও কল/ছবি, ভয়েস নোট/কল, ইয়ারফোন (বিল্ড ২৭৮), নোটিফিকেশন | শুধু Data safety। আলাদা ফর্ম নেই। |
| **নেই** | SMS, Call log, `READ_PHONE_STATE`, `QUERY_ALL_PACKAGES`, `SYSTEM_ALERT_WINDOW`, Accessibility service, background location, `REQUEST_INSTALL_PACKAGES` (Play থেকে সরানো), `READ_MEDIA_*` | এগুলোর কোনো ঘোষণা লাগবে না। |

**Health apps declaration (App content → Health apps):** ৮ Nov সেটে স্বাস্থ্য-ফিচার (পানি-ঘুম, ফিটনেস, স্মার্টওয়াচ, মুড) সব বন্ধ, মেডিকেলও Play-তে লুকানো।
- **ধাপ ৫-এ (খ) বাছলে:** "My app does not have any health features"।
- **(ক) বাছলে:** `PLAY_HEALTH_DECLARATION_BN.md` অনুযায়ী, কিন্তু রিভিউয়ারকে allow-list অ্যাকাউন্ট দিতে হবে।

## ধাপ ৫ — ⚠️ বন্ধ ফিচারের অনুমতি ম্যানিফেস্টে থেকে যাওয়া (আপনার সিদ্ধান্ত লাগবে)

সার্ভারের সুইচ ফিচার লুকায়, কিন্তু **অনুমতি অ্যাপের ভেতরে থেকেই যায়।** Google রিভিউ করে ম্যানিফেস্ট দেখে। তাই এই তিনটির জন্য ঘোষণা চাইবে, আর রিভিউয়ার ফিচারটা খুঁজে না পেলে "ঘোষিত ব্যবহার দেখা যায়নি" বলে আটকাতে পারে:
- **Health Connect** (স্মার্টওয়াচ, বন্ধ)
- **Device admin + `AntiTheftService` লোকেশন FGS** (চুরি-রোধ, বন্ধ)
- **`WakeWordService` মাইক FGS** ("Hey Assisto", Play-তে কখনোই চালু নয়)

- **(ক) রেখে দেওয়া:** ঘোষণা জমা দিন। রিভিউয়ারের জন্য একটা টেস্ট-অ্যাকাউন্ট সংশ্লিষ্ট সুইচের allow-list-এ দিন, তার লগইন "App access" অংশে দিন, আর ভিডিও করুন। ঝুঁকি: রিভিউ দেরি বা প্রত্যাখ্যান।
- **(খ) Play AAB থেকে সরানো (আমার প্রস্তাব):** CI-এর Play-ধাপে, যেখানে `REQUEST_INSTALL_PACKAGES` সরানো হয় (W:1088-1102), সেখানেই এই তিনটি সরানো যায়। ওয়েবসাইটের APK-তে সব থাকবে। পরে ফিচার চালু করলে আবার যোগ করে ঘোষণা দেওয়া যাবে। এটা পুরোপুরি উল্টানো যায়, আর ৮ Nov-এর ঘোষণা অনেক ছোট হয়। আপনার "হ্যাঁ" পেলে লঞ্চ-বিল্ডে করব (৫ Nov ফ্রিজের আগে)।

## ধাপ ৬ — Content rating ও Target audience

- **Content rating (IARC):** `PLAY_STORE_PACK.md` §২-এর উত্তরই চলবে। মূল উত্তরগুলো:
  - ব্যবহারকারীরা একে অপরের সাথে কথা বলতে পারেন: **হ্যাঁ** (My Circle);
  - ব্যবহারকারীর লোকেশন অন্যদের সাথে শেয়ার: **হ্যাঁ** (নিরাপদ যাত্রা, SOS);
  - ডিজিটাল কেনাকাটা: **হ্যাঁ**;
  - হিংসা বা জুয়া: না।
- **Target audience:** **শুধু ১৮+।** বাচ্চাদের ঘড়ি ও স্কুল-মোড (`kids_watch`) বন্ধ, তাই অ্যাপ "শিশুদের জন্য" নয়। Families policy প্রযোজ্য নয় (`PLAY_STORE_PACK.md` §৩)। ১৩–১৭ বাছবেন না, বাছলে বিজ্ঞাপন আর ডেটার নিয়ম কঠিন হয়ে যায়।
- **App access:** রিভিউয়ারের জন্য একটা ইমেইল-লগইন টেস্ট অ্যাকাউন্ট দিন, কারণ ফোন-OTP বন্ধ আর লগইন ইমেইল-OTP দিয়ে চলে। OTP ছাড়া ঢোকার উপায় না থাকলে রিভিউ আটকায়, তাই রিভিউয়ারের জন্য স্থির পাসওয়ার্ড-লগইন দিন।

## ধাপ ৭ — স্টোর লিস্টিং (শুধু চালু ফিচার)

শুরু করুন `PLAY_LISTING_FIXED.md` Case B থেকে, তারপর **৮ Nov সেটে যা বন্ধ, তার দাবি সরান**:
- **সরাতে হবে:**
  - স্বাস্থ্য ও ফিটনেস (পানি, ঘুম, খাবার, ফিটনেস সঙ্গী, Health Connect, মুড ডায়েরি);
  - ফটো স্টুডিও;
  - নমিনি;
  - সাবস্ক্রিপশন, বিল, বিয়ে, রমজান, কোরবানি, কর-যাকাত, খরচ ভাগ, মেস, সমিতি, ভাড়া, প্রিপেইড মিটার, ঋণ, সঞ্চয়;
  - স্কুল কর্নার, প্রতারণা-টিপস;
  - সিভি, স্টুডেন্ট কর্নার, পরীক্ষার ফল, সেবা গাইড, প্রবাসী কর্নার, কৃষক মোড;
  - সব add-on লাইন: চুরি-রোধ, AI সেলস এজেন্ট, শপ বক্স, AI টুল, গাড়ি।
- **রাখুন:**
  - এন্ড-টু-এন্ড এনক্রিপ্টেড চ্যাট (ছবি, ভয়েস নোট, ডকুমেন্ট), ভয়েস/ভিডিও কল, গ্রুপ, এনক্রিপ্টেড ব্যাকআপ;
  - "মুখে বলুন" রিমাইন্ডার ও নোট;
  - বাজেট ও বিদেশ থেকে আসা টাকা (রেমিট্যান্স);
  - SOS, নিরাপদ যাত্রা (নকল কল সহ), অভিভাবকের অনুরোধে যাত্রা, পরিবার কার্ড;
  - PIN ভল্ট (ডকুমেন্ট);
  - খাতা, বিক্রি, ক্যাশবক্স, পণ্য, অর্ডার, CRM;
  - প্ল্যান: Free বিজ্ঞাপনসহ, Premium ও Business বিজ্ঞাপন ছাড়া।
- **বিজ্ঞাপনের লাইন:** বাংলা লিস্টিংয়ের "ঐচ্ছিক, নন-পার্সোনালাইজড বিজ্ঞাপন" **ভুল** (⚠️ অমিল ১৫)। লিখুন: "ফ্রি প্ল্যানে বিজ্ঞাপন; Premium/Business-এ কোনো বিজ্ঞাপন নেই; বিজ্ঞাপনের সম্মতি Google-এর ফর্মে"।
- **স্ক্রিনশট:** শুধু চালু ফিচারের ছবি দিন (`PLAY_SCREENSHOTS_SHOTLIST_BN.md` থেকে বেছে নিন)। CCTV, গাড়ি, ফটো স্টুডিও বা স্বাস্থ্যের ছবি দেবেন না।
- **"AI" শব্দ:** লাইভে AI চাবি নেই। চাবি না বসা পর্যন্ত "AI সহকারী সব প্রশ্নের উত্তর দেয়" জাতীয় দাবি লিখবেন না। লিখতে পারেন "Assisto সহকারী — রিমাইন্ডার, খরচ, পরিবারের নিরাপত্তা, এক জায়গায়"।

## ধাপ ৮ — Staged rollout (ধাপে ধাপে)

ধাপগুলো Test and release → Production → Create release → AAB (internal-এ যেটা আপনি পরীক্ষা করেছেন, সেই versionCode) → **Staged rollout %**:

| দিন | % | পরের ধাপে যাওয়ার শর্ত (Play Console → Quality → Android vitals, আর Owner Admin → Vitals) |
|---|---|---|
| ৮ Nov | **২০%** | ২৪ ঘণ্টায় নতুন crash cluster নেই। User-perceived crash rate < ১.০৯%, ANR rate < ০.৪৭% (Google-এর "bad behavior" সীমা)। কল/SOS নিয়ে ১-তারা রিভিউ নেই। |
| ৯–১০ Nov | **৫০%** | একই শর্ত, ৪৮ ঘণ্টা ধরে |
| ১১–১২ Nov | **১০০%** | — |

সংখ্যা কম থাকলে Vitals-এ হার দেখাবে না। তখন Owner Admin → Vitals আর "রিপোর্ট ও ত্রুটি (crash)" পাতায় নিজের crash-রিপোর্ট দেখুন।

## ধাপ ৯ — সমস্যা হলে ফেরার পথ (rollback)

1. **সবচেয়ে দ্রুত (সেকেন্ডে):** যে ফিচারে সমস্যা, Owner Admin → Features-এ তার `enabled_play` তুলে দিন। ৩০ সেকেন্ড থেকে ১ মিনিটের মধ্যে সব ফোনে লুকিয়ে যায়, নতুন বিল্ড লাগে না।
2. **রোলআউট থামানো:** Play Console → Production → release → **Halt rollout**। এতে নতুন কেউ এই ভার্সন পাবেন না। যাঁরা পেয়ে গেছেন, তাঁদের ফোনে থাকবে, কারণ Google ভার্সন নামিয়ে আনতে দেয় না।
3. **ঠিক করা বিল্ড:** বেশি versionCode-এ ঠিক করা বিল্ড internal → production-এ দিন। আগের ভালো কোড আবার পাঠাতে হলে, সেটাও নতুন versionCode দিয়ে পাঠাতে হয়।
4. **সার্ভার:** ব্যাকএন্ড ডিপ্লয়ের আগে সবসময় ব্যাকআপ নেওয়া হয় (আপনার নিয়ম)। দরকার হলে আগের ব্যাকএন্ডে ফেরা যায়, অ্যাপের দিকে কিছু করতে হয় না।

## ধাপ ১০ — Pre-launch report ও Vitals (Play Console-এ যা দেখবেন)

**API দিয়ে পড়া যায়নি:** Google-এর pre-launch report-এর কোনো public API নেই, আর আমাদের কোনো স্ক্রিপ্টও তা পড়ে না। `bin/play_status.py` শুধু-পড়ার, কিন্তু সেটা track, রিভিউ আর vitals দেখে। আমি সেটা চালাইনি, কারণ সার্ভিস-অ্যাকাউন্ট ফাইল ছোঁয়া নিষেধ। Vitals-এর জন্য লাইভ ডাটাবেস পড়েছি, কারণ সেখানে দৈনিক `play_vitals_pull` আগেই পড়ে রাখে।

**লাইভ ডাটাবেসে যা পেলাম (২ Nov):**
- Crash/ANR হারের সারি: **০টি।** ব্যবহারকারী কম, তাই Google এখনো হার দেয় না।
- Crash issue: **৬টি।** সবগুলোই "Unable to start receiver… IllegalStateException", পুরনো versionCode ১০২২১–১০২৪১-এ, শেষ দেখা ২৭ Oct। একটা স্পষ্টভাবে Gson `TypeToken` (R8)।
- এর জন্য keep-rule ও CI-পাহারা আগেই যোগ হয়েছে (`app/android_overlay/app/proguard-rules.pro:50-60`, `android.yml:959-968`)। বিল্ড ২৪১-এর পরে এই crash আর আসেনি।
- **তবু Play Console-এ এই ৬টাকে "fixed" চিহ্নিত করার আগে নিশ্চিত হয়ে নিন, বিল্ড ২৭৮-এ নতুন কোনো রিপোর্ট নেই।**

**Play Console-এ নিজে দেখুন:**
1. **Test and release → Testing → Pre-launch report → (বিল্ড ২৭৮ বা লঞ্চ-বিল্ড) → Overview।** দেখার জিনিস:
   - "Crashes" ও "ANRs" = ০ হতে হবে। থাকলে স্ক্রিনশট আর ডিভাইসের নাম আমাকে পাঠান।
   - "Stability" ট্যাবে কোন ডিভাইসে আটকেছে।
   - **Accessibility** সতর্কতা: ছোট বোতাম (৪৮dp-এর কম), কম কনট্রাস্ট, লেবেলবিহীন বোতাম — তালিকা পাঠান।
   - **Security & trust** (পুরনো লাইব্রেরি, unsafe API) — থাকলে পাঠান।
   - **Performance** (চালু হতে সময়) — ২ GB ফোনের সারিগুলো দেখুন।
   - Pre-launch robot লগইন পার হতে পারে না। তাই Settings → Pre-launch report settings → **"Sign-in credentials"**-এ রিভিউয়ারের টেস্ট অ্যাকাউন্ট দিন। না দিলে রিপোর্ট শুধু লগইন পাতা দেখবে।
2. **Quality → Android vitals → Crashes and ANRs:** শুধু বিল্ড ২৭৮ বেছে দেখুন।
3. **Policy → Policy status:** কোনো লাল ব্যানার বা "Action required" আছে কিনা।
4. **App content:** প্রতিটি সারি সবুজ "Completed" কিনা (Data safety, Ads, Target audience, Content rating, Health apps, FGS, Full-screen intent, Government apps = No, Financial features = No, News = No)।

---

## ⚠️ অমিল — পুরনো ডক বনাম আসল কোড (ঠিক করে নিয়ে ঘোষণা দিন)

| # | ডক যা বলে | কোড আসলে যা করে |
|---|---|---|
| ১ | `PLAY_FGS_DECLARATION_BN.md`: রিস্টার্টের পরে কোনো সার্ভিস নিজে চালু হয় না | চুরি-রোধ বুট বা অ্যাপ-আপডেটের পরে নিজে আবার চালু হয় (Android ৮–১৩; W:653-662, `RestartPolicy.kt`)। চুরি-রোধ বন্ধ বা সরানো থাকলে ৮ Nov-এ প্রাসঙ্গিক নয়। |
| ২ | একই ডকের ধাপ ৫: "Hey Assisto"-এর ভিডিও | Play বিল্ডে ওয়েক-ওয়ার্ড বন্ধ (`va_wake.dart:54`), কিন্তু `WakeWordService` ম্যানিফেস্টে আছে। ভিডিও করার মতো ফিচার নেই, তাই ধাপ ৫ (খ)। |
| ৩ | একই ডকের Location অংশে শুধু ভয়েস SOS + চুরি-রোধ | **নিরাপদ যাত্রাও** লোকেশন FGS চালায় (`journey_tracker.dart:402`)। ৮ Nov-এর মূল ফিচার, তাই অবশ্যই লিখুন। |
| ৪ | `PLAY_STORE_PACK.md:324-325`: মাইক শুধু SOS-এর জন্য | কল চালু রাখতেও মাইক FGS লাগে (`call_keepalive.dart:89`) |
| ৫ | `PLAY_STORE_PACK.md:273-276`: অডিও "collected নয়" | My Circle ভয়েস নোট এনক্রিপ্ট হয়ে আপলোড হয়। ঘোষণা করুন (ধাপ ৩)। |
| ৬ | `PLAY_STORE_PACK.md:330`: device-admin নীতি limit-password / reset-password | সেগুলো সরানো হয়েছে। শুধু force-lock আর watch-login আছে (`res/xml/device_admin.xml`)। |
| ৭ | `PLAY_STORE_PACK.md:299`: App interactions শেয়ার হয় না | `ADMOB_PLAY_DECLARATIONS_BN.md` ঠিক বলে: AdMob-এর সাথে শেয়ার হয় |
| ৮ | `CCTV_PLAY_DECLARATIONS_BN.md` §১: চুরি-রোধের Camera FGS "অপরিবর্তিত" | Camera FGS সরানো হয়েছে (at100)। ঘোষণা লাগবে না (`PLAY_FGS_DECLARATION_BN.md` §৩ ঠিক বলে)। |
| ৯ | `ADMOB_PLAY_DECLARATIONS_BN.md`: AD_ID বিজ্ঞাপন SDK যোগ করে | CI নিজে সরাসরি যোগ করে (W:461), তাই সব বিল্ডে থাকে। ফল একই: "Yes, uses Advertising ID"। |
| ১০ | `PLAY_HEALTH_DECLARATION_BN.md`: শুধু ওষুধ লুকানো, স্বাস্থ্য-ফিটনেস দেখায়। `PLAY_VISIBILITY_0B_SIMPLE_BN.md`: এগুলো লুকানো (আর নিজের শুরুর লাইনের সাথেই মেলে না)। | ৮ Nov সেটে স্বাস্থ্য-ফিটনেস সব **বন্ধ**। এই ডকটাই এখন সঠিক উৎস। |
| ১১ | `PLAY_VISIBILITY_0B`: নিরাপদ যাত্রা ও গাড়িতে background-location ঘোষণা লাগবে | কোড কখনো background location চায় না (ম্যানিফেস্টে নেই)। ঘোষণা লাগবে না। |
| ১২ | রিমোট লক নিয়ে তিন ডক তিন কথা বলে (`PLAY_STORE_PACK.md:88`, `PLAY_LISTING_FIXED.md:181`, at100) | চুরি-রোধ ৮ Nov-এ বন্ধ, তাই লিস্টিংয়ে **রিমোট লকের উল্লেখই নয়** |
| ১৩ | `PLAY_LISTING_FIXED` / `PLAY_VISIBILITY_0B`: গাড়িতে "আসল ম্যাপ নেই" | `flutter_map` এখন আছে। গাড়ি বন্ধ, তাই লিস্টিংয়ে নেই। |
| ১৪ | `PLAY_LISTING_FIXED.md:189`: "ভুল আনলকে চোরের ছবি" | ছবি ওঠে শুধু অ্যাপের ভেতরের Security PIN ভুল দিলে। চুরি-রোধ বন্ধ, তাই উল্লেখ নয়। |
| ১৫ | `PLAY_STORE_PACK.md:169` (বাংলা লিস্টিং): বিজ্ঞাপন "ঐচ্ছিক, নন-পার্সোনালাইজড", পেইডে "অ্যাপ-খোলার বিজ্ঞাপন নেই" | বিজ্ঞাপন ঐচ্ছিক নয় (রিওয়ার্ডেড ছাড়া)। সম্মতি Google UMP দিয়ে, তাই পার্সোনালাইজড হতে পারে। পেইডে **কোনো** বিজ্ঞাপন নেই। ধাপ ৭-এর লাইন ব্যবহার করুন। |
| ১৬ | লাইভ Play লিস্টিং (`PLAY_LISTING_AUDIT_BN.md`): ওষুধ রিমাইন্ডার, ডাক্তার অ্যাপয়েন্টমেন্ট, হ্যান্ডস-ফ্রি ভয়েস, কুরিয়ার বুকিং, রিমোট লক, ম্যাপ, কাছেপিঠে, জবস | সবই Play-তে লুকানো বা ৮ Nov-এ বন্ধ। **লিস্টিং অবশ্যই বদলান** (ধাপ ৭)। |
| ১৭ | `PLAY_STORE_PACK.md`-এর পুরো বর্ণনা (২২ Oct): শপ বক্স, OBD/GPS গাড়ি, চুরি-রোধ, হ্যান্ডস-ফ্রি ভয়েস SOS | পুরনো। ব্যবহার করবেন না, Case B + ধাপ ৭। |
| ১৮ | জরুরি কার্ডের রক্তের গ্রুপ | **সার্ভারে** থাকে (`EmergencyCard`, `models.py:610`)। Play-তে এডিট লুকানো, তাই Play থেকে নতুন তথ্য যায় না। ওয়েবসাইট-APK দিয়ে আগে দেওয়া থাকলে সার্ভারে আছে। পরিবার কার্ডেরটা শুধু ফোনে। এই কারণেই Health info "না" (ধাপ ৩)। স্বাস্থ্য-ফিচার চালু করলে আবার দেখুন। |

*উৎস ও লাইন নম্বর: CI ফাইল `.github/workflows/android.yml`-এ "W:" দিয়ে চিহ্নিত।*

## আসছে — ফ্ল্যাগের পেছনে (coming behind flags)
### ট্রেন ট্র্যাকার + গন্তব্য অ্যালার্ম (`train_tracker`, `dest_alarm` — বন্ধ)
Data safety-তে চালুর আগে যোগ করুন: **Location → Precise location: Collected** (উদ্দেশ্য: App functionality), **Shared: No**, **Optional** (ব্যবহারকারী নিজে "আমি এই ট্রেনে আছি" চাপলে তবেই; শুধু শেয়ার চলাকালীন; সার্ভারে শুধু শেষ যাচাই-করা অবস্থান থাকে, অন্যরা দেখে শুধু ট্রেনের মিলিত অবস্থান, যাত্রার পর মুছে যায়)। **Messages → Other in-app messages: Collected** (ট্রেন চ্যাট; ডাকনাম; যাত্রার পর মুছে যায়; রিপোর্ট করা মেসেজের কপি ৩০ দিন)। গন্তব্য অ্যালার্মের লোকেশন **ফোন থেকে বের হয় না** (Collected নয়)। FGS ঘোষণা: `PLAY_FGS_DECLARATION_BN.md` §৬।
