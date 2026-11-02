# Play Production চেকলিস্ট — ৮ Nov **সব-ফিচার** লঞ্চ (মালিকের জন্য, ধাপে ধাপে)

**হালনাগাদ:** ২ Nov ২০২৬ (playall)।

**এটা আগের সংস্করণের বদলি।** আগেরটা ছিল সরু লঞ্চের জন্য (১৮টি ফিচার)। আপনি পরিকল্পনা বদলেছেন: **সব ফিচার চালু।** তাই সব ঘোষণা এখন সব-চালু ধরে লেখা।

**উৎস:**
- অ্যাপের আসল কোড;
- CI-তে তৈরি হওয়া Play ম্যানিফেস্ট (`.github/workflows/android.yml`, নিচে "W:" লিখে লাইন নম্বর দেওয়া);
- Google-এর নিজের নীতির পাতা (২ Nov পড়া)।

**অন্য যে ফাইলগুলো এর সাথে চলে:**

| ফাইল | কী আছে |
|---|---|
| `LAUNCH_SWITCHES_8NOV_BN.md` | কোন সুইচ চালু, কোনটা কেন বন্ধ |
| `PLAY_FGS_DECLARATION_BN.md` | FGS ও full-screen-এর কপি-লেখা আর ভিডিওর ধাপ |
| `PLAY_HEALTH_DECLARATION_BN.md` | স্বাস্থ্য ও Health Connect |
| `ANTITHEFT_PLAY_DECLARATION_BN.md` | Device admin, চুরি-রোধ |
| `ADMOB_PLAY_DECLARATIONS_BN.md` | বিজ্ঞাপন |
| `PLAY_LISTING_8NOV_ALL_BN.md` | স্টোর লিস্টিং আর স্ক্রিনশট |
| `PLAY_REVIEWER_PATH_8NOV_BN.md` | রিভিউয়ার ও pre-launch robot-এর পথ (ফাইলটা না থাকলে লিস্টিং-ফাইলের শেষ অংশ দেখুন) |

> **মূল নিয়ম:** Play Console-এ যা ঘোষণা করবেন আর লিস্টিংয়ে যা লিখবেন, তা যেন **Play বিল্ডে সত্যিই চালু ও কাজ করা** ফিচারের সাথে মেলে। ম্যানিফেস্টে কোনো অনুমতি থাকলে তার ব্যবহারও রিভিউয়ারকে দেখাতে পারতে হবে। তাই অব্যবহৃত অনুমতি আর সার্ভিস সরানো হয়েছে, আর CI সেটা পাহারা দেয়।

---

## ধাপ ০ — আপনার সময়সীমা (৮ Nov পর্যন্ত)

Google-এর রিভিউ সাধারণত ১–৩ দিন লাগে। কিন্তু **নতুন সংবেদনশীল ঘোষণা** (FGS, Health Connect, device admin) থাকলে **৭ দিন বা তার বেশি** লাগতে পারে। Production access-এর আবেদনের রিভিউ সাধারণত **~৭ দিন**। তাই সব ঘোষণা **রিলিজের সাথে আগেই** জমা দিতে হবে।

| কবে (শেষ সময়) | কী করবেন | কোথায় | না করলে কী হবে |
|---|---|---|---|
| **আজই, ২ Nov** | Production access আছে কিনা দেখুন (ধাপ ১)। "১২ টেস্টার × ১৪ দিন" পূরণ না হলে **৮ Nov production অসম্ভব।** তখন নিচের বিকল্প দেখুন। | Play Console → Dashboard | পুরো তারিখ সরে যাবে |
| **৩ Nov** | Owner Admin → Features-এ সুইচ বসান (`LAUNCH_SWITCHES_8NOV_BN.md`)। নিজের দ্বিতীয় (owner নয়) অ্যাকাউন্টে Play বিল্ড খুলে দেখুন, সব ঠিক দেখাচ্ছে কিনা। | Owner Admin | রিভিউয়ার বন্ধ ফিচার খুঁজে পাবে না, অথবা অসমাপ্ত ফিচার দেখবে |
| **৩ Nov** | রিভিউয়ারের লগইন ঠিক করুন: App access, আর Pre-launch report → Sign-in credentials (ধাপ ৬)। | App content → App access | রিভিউ "লগইন করা যায়নি" বলে আটকাবে |
| **৩–৪ Nov** | **সব ঘোষণা জমা দিন**, এই কোড থাকা প্রথম closed-testing বিল্ডের সাথে: FGS (মাইক + লোকেশন, ভিডিওসহ), Full-screen intent (Calling), Health apps + Health Connect, Data safety, Ads, Content rating, Target audience। | App content | ৮ Nov-এ রিভিউ শেষ হবে না। আগে জমা দিলে ৮ Nov-এর আগেই জানবেন কোনোটা প্রত্যাখ্যাত হলো কিনা। |
| **৪ Nov** | তিনটা ভিডিও রেকর্ড করে লিংক দিন: Voice SOS + কল, নিরাপদ যাত্রা + চুরি-রোধ, Health Connect সংযোগ। ধাপ `PLAY_FGS_DECLARATION_BN.md`-এ। | YouTube unlisted | FGS ঘোষণা অসম্পূর্ণ থাকবে |
| **৫ Nov** | স্টোর লিস্টিং (bn + en) আর স্ক্রিনশট বদলান (`PLAY_LISTING_8NOV_ALL_BN.md`)। লাইভ লিস্টিংয়ের ভুল দাবি সরান। | Grow → Store presence → Main store listing | ভুল দাবির জন্য রিভিউ আটকাবে (Misleading claims নীতি) |
| **৫ Nov** | AI চাবি লাইভ কিনা নিশ্চিত করুন। লাইভ না হলে লিস্টিংয়ের "AI" অংশ বাদ দিন। | Owner Admin → Integrations | লিস্টিংয়ের দাবি মিথ্যা হয়ে যাবে |
| **৬ Nov** | Policy status-এ লাল কিছু নেই, আর App content-এর সব সারি "Completed", তা দেখুন। | Policy → Policy status | — |
| **৭ Nov** | Production রিলিজ তৈরি করুন: internal-এ আপনার পরীক্ষা করা versionCode, staged ২০%। **Send for review।** | Test and release → Production | ৮ Nov-এ লাইভ হবে না |
| **৮ Nov** | রিভিউ পাস হলে রোলআউট শুরু (ধাপ ৮)। পাস না হলে প্রত্যাখ্যানের ইমেইল আমাকে পাঠান। | — | — |

**বাফার:** রিভিউ সময় Google-এর হাতে। ৭ Nov রাতের আগে পাঠালে ৮ Nov-এ লাইভ হওয়ার **সম্ভাবনা** আছে, নিশ্চয়তা নেই। ঘোষণাগুলো ৩–৪ Nov-এ closed-testing রিলিজের সাথে পাস হয়ে গেলে production রিভিউ সাধারণত দ্রুত হয়।

---

## ধাপ ১ — Production access (১২ জন টেস্টার × ১৪ দিন)

**নিয়ম:** ব্যক্তিগত (personal) ডেভেলপার অ্যাকাউন্ট ১৩ Nov ২০২৩-এর পরে খোলা হলে, production-এর আগে **closed testing-এ কমপক্ষে ১২ জন টেস্টারকে টানা ১৪ দিন opt-in** থাকতে হয়। তারপর "Apply for production" ফর্ম দিতে হয়, যার রিভিউ সাধারণত ~৭ দিন।

**কীভাবে দেখবেন:**
1. Play Console → Assisto → **Dashboard**।
   - উপরে **"Apply for production"** কার্ড থাকলে সেখানে "x/12 testers" আর "y/14 days" লেখা থাকে।
   - কার্ড নেই, আর **Test and release → Production**-এ "Create new release" বোতাম খোলা? তাহলে শর্ত আপনার জন্য প্রযোজ্য নয়, বা পূরণ হয়ে গেছে।
2. **Test and release → Testing → Closed testing → (track) → Testers**: opt-in করা মানুষের সংখ্যা দেখুন।
   - শুধু **opt-in করা** টেস্টাররাই গোনা হয়।
   - ১৪ দিন **টানা** হতে হয়। কেউ মাঝে বের হলে গোনা কমে।
3. **হিসাব:** আজ ২ Nov। ৮ Nov-এ production পেতে হলে, ১৪ দিন আগেই পূর্ণ হয়ে থাকতে হবে, আর আবেদন অনুমোদিত হতে হবে (~৭ দিন)। মোটামুটি **২৫ Oct বা তার আগে ১২ জন opt-in করে থাকলে** আর আবেদন ১ Nov-এর মধ্যে জমা হলে তবেই সম্ভব।

**শর্ত পূরণ না হলে — সৎ বিকল্প (Google যা দেয়):**
- **(ক) অপেক্ষা:** closed testing-এ ১২+ জন রাখুন, দিন গুনুন, তারপর আবেদন। এর মধ্যে closed testing-এ নিয়মিত বিল্ড দিন আর টেস্টারদের মতামত নিন, কারণ ফর্মে Google এটা জিজ্ঞেস করে।
- **(খ) Organization অ্যাকাউন্ট:** এই ১২×১৪ শর্ত শুধু personal অ্যাকাউন্টে।
  - Organization অ্যাকাউন্টে D-U-N-S নম্বর আর যাচাই লাগে (কয়েক দিন থেকে কয়েক সপ্তাহ)।
  - তারপর অ্যাপটা নতুন অ্যাকাউন্টে **transfer** করতে হয় (আরও কিছু দিন)।
  - সুবিধা: পরে মেডিকেল ফিচারও খোলা যাবে (`PLAY_ORGANIZATION_ACCOUNT_BN.md`)।
  - **৮ Nov-এর জন্য এটা দ্রুত পথ নয়।**
- **(গ) এর মধ্যে কী চলবে:** ওয়েবসাইটের APK আর Play-র closed/internal testing চলতেই থাকবে। ব্যবহারকারীদের closed testing-এর opt-in লিংক দিয়ে Play থেকেই নেওয়ানো যায় (তাঁরাও টেস্টার হিসেবে গোনা হন)।
- **ফাঁকি দেওয়ার কোনো পথ নেই।** Google কোনো ছাড় দেয় না। ভুয়া টেস্টার দিলে অ্যাকাউন্ট ঝুঁকিতে পড়ে। তাই করবেন না।

**আবেদন ফর্মে (সৎভাবে লিখুন):**
- টেস্টার কীভাবে পেলেন: পরিবার, বন্ধু, দোকানি।
- তাঁদের মতামতে কী বদলেছেন। উদাহরণ:
  - কল আর ইয়ারফোন (বিল্ড ২৭৭–২৭৮);
  - নিরাপদ যাত্রা;
  - SOS;
  - খাতা;
  - বিজ্ঞাপন ঠিক করা (২৭৪);
  - ফটো স্টুডিও দ্রুত করা (২৭০)।
- অ্যাপ কাদের জন্য: বাংলাদেশের প্রাপ্তবয়স্ক, পরিবার ও ছোট দোকান।

## ধাপ ২ — সুইচ (Owner Admin → Features)

`LAUNCH_SWITCHES_8NOV_BN.md` দেখুন।

**সংক্ষেপে:** তৈরি হওয়া প্রতিটি ফিচার Play-তে চালু। শুধু যেগুলো তৈরি হয়নি, যেগুলো আসল যন্ত্র/অংশীদার ছাড়া চলে না, বা যেগুলো Play-র নিয়ম ভাঙবে, সেগুলো বন্ধ। প্রতিটির কারণ সেখানে লেখা।

তারপর নিজের দ্বিতীয় (সাধারণ, owner নয়) অ্যাকাউন্টে Play বিল্ড খুলে দেখুন:
- ড্রয়ার, হোম-শর্টকাট আর সার্চে কোনো মরা বা অর্ধেক ফিচার নেই;
- "Hey Assisto", ওষুধ, পতন শনাক্ত দেখা যায় না।

## ধাপ ৩ — Data safety (Policy → App content → Data safety) — চূড়ান্ত উত্তর

**প্রথম প্রশ্নগুলো:**
- **Collect or share user data?** → **হ্যাঁ।**
- **Encrypted in transit?** → **হ্যাঁ।** সব HTTPS। My Circle-এর চ্যাট, মিডিয়া আর ভয়েস নোট এন্ড-টু-এন্ড।
- **Way to request deletion?** → **হ্যাঁ।** অ্যাপে Settings → অ্যাকাউন্ট মুছুন, ওয়েবে `https://lifeassisto.com/delete-account`।
- **Sharing:** Google-এর নিয়মে, ব্যবহারকারী নিজে কাউকে পাঠালে (SOS, যাত্রা, চ্যাট) সেটা "sharing" নয়। আমাদের হয়ে কাজ করা সেবা-প্রদানকারী (AI provider, Firebase, সার্ভার) পেলেও "sharing" নয়। **Sharing শুধু AdMob-এর সাথে** (বিজ্ঞাপন)।

**কলামের মানে:** "দরকারি?" মানে required নাকি optional।

| Play-র ডেটা টাইপ | Collected | Shared | দরকারি? | উদ্দেশ্য | কোড থেকে কারণ |
|---|---|---|---|---|---|
| Location → **Precise** | হ্যাঁ | না | ঐচ্ছিক | App functionality; Fraud prevention, security | SOS, নিরাপদ যাত্রা (প্রতি ৩০ সে.), ভয়েস SOS, চুরি-রোধ (সতর্কবার্তা, হারানো মোড), কার-মোড ট্রিপ, স্কুল-মোড, কাছেপিঠে, রমজানের সময়, চ্যাটে লোকেশন শেয়ার। নিরাপত্তা-কাজ আর অ্যাকাউন্ট মোছার সময় **শুধু আগে থেকে অনুমতি থাকলে** লোকেশন যায় (playall: এখানে আর অনুমতি চাওয়া হয় না)। |
| Location → **Approximate** | হ্যাঁ | **হ্যাঁ (AdMob)** | ঐচ্ছিক | Advertising; App functionality | বিজ্ঞাপন SDK IP থেকে আন্দাজ করে (`ADMOB_PLAY_DECLARATIONS_BN.md`) |
| Personal info → **Name, Email, Phone** | হ্যাঁ | না | **দরকারি** | App functionality, Account management | সাইন-ইন, প্রোফাইল। খাতা/CRM-এ দোকানির লেখা গ্রাহকের নাম-নম্বরও। |
| Personal info → **Address** | হ্যাঁ | না | ঐচ্ছিক | App functionality | ঠিকানা লেখা যায় এমন ঘর (বাড়ি ভাড়া, অর্ডার, CRM, জরুরি কার্ড) |
| Personal info → **Other info** | হ্যাঁ | না | ঐচ্ছিক | App functionality | জন্মদিন, নমিনি, প্রোফাইলের "আমার সম্পর্কে" |
| Financial → **Purchase history** | হ্যাঁ | না | ঐচ্ছিক | App functionality | Play Billing টোকেন সার্ভারে যাচাই হয় (`core/payments/play.py`) |
| Financial → **Other financial info** | হ্যাঁ | না | ঐচ্ছিক | App functionality | বাজেট, খরচ, রেমিট্যান্স, খাতা, সমিতি, মেস — ব্যবহারকারী নিজে লেখেন |
| Health and fitness → **Health info** | হ্যাঁ | না | ঐচ্ছিক | App functionality | পানি-ঘুম-খাবারের লগ (`wellness`), রক্তদাতা (`blood_donor`, রক্তের গ্রুপ সার্ভারে যায়), জরুরি কার্ডের রক্তের গ্রুপ (`EmergencyCard`)। মন-প্রাণশক্তির ডায়েরি আর Health Connect-এর ডেটা **শুধু ফোনে**, তাই এর মধ্যে পড়ে না। |
| Health and fitness → **Fitness info** | হ্যাঁ | না | ঐচ্ছিক | App functionality | ফিটনেস সঙ্গীর ব্যায়াম-লগ (সার্ভারে) |
| Messages → **Other in-app messages** | হ্যাঁ | না | ঐচ্ছিক | App functionality | My Circle (এন্ড-টু-এন্ড), এলাকার বার্তা, AI চ্যাট |
| Photos and videos → **Photos** | হ্যাঁ | না | ঐচ্ছিক | App functionality; Security | চ্যাটের মিডিয়া (E2E), ডকুমেন্ট ভল্ট, প্রোফাইল ছবি, ফটো স্টুডিওর ক্লাউড-অংশ, চোরের ছবি (সম্মতিতে, এনক্রিপ্টেড), CCTV/শপ বক্সের সতর্কতা-ছবি |
| Photos and videos → **Videos** | হ্যাঁ | না | ঐচ্ছিক | App functionality | চ্যাটে ভিডিও পাঠানো (E2E)। CCTV লাইভ ভিডিও সরাসরি ফোন-থেকে-ফোনে যায়, রেকর্ড বা জমা হয় না। |
| Audio → **Voice or sound recordings** | হ্যাঁ | না | ঐচ্ছিক | App functionality | My Circle ভয়েস নোট (E2E)। কল রেকর্ড হয় না। `transcription` পাতা অডিও আপলোড করে না, শুধু রেফারেন্স আর টাইপ করা লেখা রাখে। ভয়েস SOS আর মুখে বলে লেখা ফোনেই হয়। |
| Files and docs | হ্যাঁ | না | ঐচ্ছিক | App functionality | ডকুমেন্ট ভল্ট, চ্যাটের ডকুমেন্ট, ডকুমেন্ট স্ক্যানার |
| Contacts | হ্যাঁ | না | ঐচ্ছিক | App functionality | ফোনবুক মেলানো: নম্বর ফোনেই hash হয়, শুধু hash যায় (`messenger/contacts/match`), আর আগে C1 ঘোষণা দেখায়। Google hash-কেও collected ধরে। ভয়েসের "মাকে কল করো" ফোনবুক শুধু ফোনে পড়ে। |
| App activity → **App interactions** | হ্যাঁ | **হ্যাঁ (AdMob)** | ঐচ্ছিক | Analytics; Advertising | বিজ্ঞাপনের impression/click (`ads/ad_telemetry.dart`) |
| App activity → **Other user-generated content** | হ্যাঁ | না | ঐচ্ছিক | App functionality | নোট, রিমাইন্ডার, তালিকা, খাতা, পোস্ট |
| App activity → **Other actions** | হ্যাঁ | না | ঐচ্ছিক | Fraud prevention, security | চুরি-রোধের দূর-সুইচের অডিট |
| App info and performance → **Crash logs, Diagnostics** | হ্যাঁ | না | দরকারি | Analytics; App functionality | `/client/crash-report` + Firebase Crashlytics |
| **Device or other IDs** | হ্যাঁ | **হ্যাঁ (AdMob)** | দরকারি | Advertising; Security; App functionality | `AD_ID` (CI যোগ করে, W:463), FCM টোকেন, ফোনের hash করা আইডি |

**ঘোষণা করবেন না** (Play বিল্ডে এগুলো নেওয়া হয় না):
- SMS, Call log, ইমেইল;
- ক্যালেন্ডার (ফোনের ক্যালেন্ডার পড়া হয় না);
- ওয়েব ব্রাউজিং;
- Installed apps (ভয়েসের "অ্যাপ খোলো" শুধু ফোনে দেখে);
- Race, religion, sexual orientation, political views;
- Credit score;
- User payment info (কার্ড নম্বর নেয় Google Play, আমরা নই)।

**AI চাবি চালু হলে:** চ্যাট, ছবি আর লেখা AI provider-এর কাছে যায়। Google-এর নিয়মে এটা "service provider", তাই shared নয়। তবু AI-provider-এর চুক্তি (DPA) ঠিক রাখুন (`AI_PROVIDER_RETENTION_BN.md`)।

## ধাপ ৪ — সব অনুমতি ও ঘোষণা: চূড়ান্ত উত্তর

(Play বিল্ডের ম্যানিফেস্ট, CI-র তৈরি। W = `android.yml`-এর লাইন)

| অনুমতি / API (Play AAB-এ) | কোন ফিচার | Play Console-এ কী | অ্যাপে অনুমতির আগে ঘোষণা |
|---|---|---|---|
| `ACCESS_FINE/COARSE_LOCATION` (শুধু অ্যাপ ব্যবহারের সময়ের অনুমতি) | SOS, নিরাপদ যাত্রা, ভয়েস SOS, চুরি-রোধ, কার-মোড, স্কুল-মোড, কাছেপিঠে, রমজান, লোকেশন শেয়ার | Data safety: Location। আলাদা ফর্ম নেই। | ✅ প্রতিটি অনুরোধের আগে: সাধারণ কাজে `permLocation2`, যাত্রায় `permJourneyLoc`, ভয়েস SOS-এ `permVoiceSos`, চুরি-রোধে `at100DiscLocBody2`, চ্যাট-শেয়ারে `mc2PermLocBody`। **ব্যতিক্রম, ইচ্ছাকৃত:** SOS পাঠানোর মুহূর্তে আলাদা পাতা নয়, কারণ বিপদের সময় এক সেকেন্ডও দেরি নয়। SOS বোতাম নিজেই বলে লোকেশন যাবে। ভয়েস SOS চালুর সময়েই লোকেশন চেয়ে নেয়। CI টেস্ট পাহারা দেয় (`play_disclosure_guard_test.dart`)। |
| `ACCESS_BACKGROUND_LOCATION` | — | **নেই।** CI ফেল করায় (playall)। "Location permissions" ফর্ম লাগবে না। | — |
| `FOREGROUND_SERVICE_LOCATION` | নিরাপদ যাত্রা, ভয়েস SOS, চুরি-রোধ | **FGS → Location**। লেখা আর ভিডিও `PLAY_FGS_DECLARATION_BN.md` §২-এ। | উপরের মতো |
| `FOREGROUND_SERVICE_MICROPHONE`, `RECORD_AUDIO` | ভয়েস SOS, কল চালু রাখা। ভয়েস নোট, মুখে বলে লেখা আর কল FGS ছাড়াই চলে। | **FGS → Microphone** (§১) | ভয়েস SOS: `permVoiceSos`। ভয়েস নোট: `md1Perm…` পাতা। মুখে বলে লেখা: `permMic`। কল: ব্যবহারকারী "কল" চাপার পরে Android নিজেই জিজ্ঞেস করে (প্রসঙ্গের ভেতরে)। |
| "Hey Assisto" ওয়েক-ওয়ার্ড (`WakeWordService`) | **তৈরি হয়নি** (`VaWake.shipped` = false) | **কিছু না।** playall-এ Play AAB থেকে সরানো, CI পাহারা দেয়। | — |
| `CAMERA` | ভিডিও কল, চ্যাট-ক্যামেরা, ডকুমেন্ট স্ক্যান, ভল্ট, শপ বক্স (স্ক্রিন খোলা থাকলে), চোরের ছবি (অ্যাপ খোলা থাকলে, ভুল Security PIN দিলে) | Data safety: Photos। কোনো ফর্ম নেই। Camera FGS **নেই**। | ক্যামেরা-পাতার "explain" অবস্থা, `permCamera`, চোরের ছবিতে `IntruderConsentScreen` |
| Device admin (`BIND_DEVICE_ADMIN`): শুধু `force-lock` আর `watch-login`। `wipe-data` নেই। | চুরি-রোধ: দূর থেকে লক, ভুল আনলক গোনা | **আলাদা Console ফর্ম নেই।** এটা Android Enterprise/DPC নয়। রিভিউ মেইল এলে `ANTITHEFT_PLAY_DECLARATION_BN.md` §১ আর §৫-এর লেখা পাঠান। | ✅ `at100DiscAdminBody` (Android-এর "Activate" পাতার আগে) |
| Health Connect: `READ_STEPS`, `READ_HEART_RATE`, `READ_SLEEP`, `READ_ACTIVE_CALORIES_BURNED` (শুধু পড়া) | স্মার্টওয়াচ ও ফিটনেস | **Health apps ফর্ম + Health Connect প্রশ্ন**, প্রতিটি অনুমতির কারণসহ (`PLAY_HEALTH_DECLARATION_BN.md`) | "Connect Health Connect" কার্ড (`swConnectBody`)। Health Connect নিজের rationale পাতা দেখায় (`PrivacyPolicyActivity`)। |
| `READ_CONTACTS` | ফোনবুক থেকে My Circle-এ যোগ, ভয়েসে "কল করো" | Data safety: Contacts | ✅ `C1Disclosure` (hash-এ মেলানোর আগে), ভয়েসে `vaContactsReason` |
| `CALL_PHONE` | ভয়েসে "কল করো", **ব্যবহারকারী "Call now" চাপার পরে** | কিছু না | নিশ্চিত-করার পাতা |
| `MANAGE_OWN_CALLS`, `BIND_TELECOM_CONNECTION_SERVICE` | My Circle কল (self-managed) | কিছু না | — |
| `USE_FULL_SCREEN_INTENT` | **শুধু ইনকামিং কল** | **Full-screen intent → "Calling"।** "Alarm" নয়। | ঘোষণা-পাতা একবার দেখায়, তারপর Settings |
| `SCHEDULE_EXACT_ALARM` (`USE_EXACT_ALARM` সরানো) | রিমাইন্ডার | কিছু না | "Alarms & reminders" ব্যাখ্যা-পাতা |
| `BIND_VOICE_INTERACTION` (ডিফল্ট সহকারী) | Assisto Voice: পাওয়ার-বোতাম চেপে ধরলে খোলে | কিছু না। লিস্টিংয়ে ভয়েস-সহকারীর কথা রাখুন। | ব্যবহারকারী নিজে Android সেটিংসে বাছেন |
| `BLUETOOTH_CONNECT` (+ ১১ বা তার নিচে পুরনো BT) | ইয়ারফোনে কল/শব্দ, গাড়ির OBD | কিছু না | অডিও-শিটের BT ঘোষণা (`arBtPermAllow`); OBD-তে "ডঙ্গল পড়ুন" চাপার পরে |
| `POST_NOTIFICATIONS`, `VIBRATE`, `WAKE_LOCK`, `RECEIVE_BOOT_COMPLETED`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_NETWORK_STATE`, `MODIFY_AUDIO_SETTINGS`, `SET_ALARM`, `INTERNET` | সাধারণ অনুমতি | কিছু না | — |
| `com.android.vending.BILLING` | Play Billing (প্ল্যান ও ক্রেডিট) | Monetization সেটআপ | — |
| `com.google.android.gms.permission.AD_ID` | AdMob (Free প্ল্যান) | **Advertising ID: Yes, Advertising** + **Ads: Yes** | Google UMP সম্মতি-ফর্ম |
| `READ_MEDIA_*`, `READ_EXTERNAL_STORAGE` | — | **নেই** (Photo Picker)। ফর্মে "does not use"। | — |
| SMS, Call log, `READ_PHONE_STATE`, `QUERY_ALL_PACKAGES`, `SYSTEM_ALERT_WINDOW`, Accessibility service, `REQUEST_INSTALL_PACKAGES`, `MANAGE_EXTERNAL_STORAGE`, `ACTIVITY_RECOGNITION`, Camera FGS | — | **নেই।** CI-র Play-ধাপ এগুলো পেলে বিল্ড ফেল করায় (playall)। | — |

**Package visibility:** `<queries>`-এ শুধু নির্দিষ্ট intent/প্যাকেজ আছে। যেমন:
- লঞ্চার অ্যাপ ("অ্যাপ খোলো"-র জন্য);
- WhatsApp, YouTube, Spotify;
- Health Connect;
- OEM ব্যাটারি-সেটিংস।

`QUERY_ALL_PACKAGES` নেই, তাই ফর্ম লাগবে না।

**Stalkerware নীতি:** প্রতিটি লোকেশন-ফিচার ব্যবহারকারী নিজে চালু করেন। চলার সময় নোটিফিকেশন থাকে, আইকন লুকায় না। অভিভাবক-যাত্রায় যাত্রী নিজে সম্মতি দেন। তাই এটা "monitoring app" নয়।

## ধাপ ৫ — ম্যানিফেস্ট বনাম সুইচ (আগের সমস্যা, এখন মীমাংসিত)

সরু প্ল্যানে প্রশ্ন ছিল: সুইচ বন্ধ থাকলেও অনুমতি থেকে যায়। সব-চালু প্ল্যানে উত্তর হলো:
- **Health Connect আর Device admin:** ফিচার চালু, তাই ঘোষণা দিন (ধাপ ৪)।
- **"Hey Assisto":** ফিচার তৈরি হয়নি, তাই Play AAB থেকে **সরানো হলো** (playall, CI-পাহারা)।
- **নিয়ম:** ধাপ ২-এর তালিকায় কোনো ফিচার বন্ধ রাখলে, আর তার নিজস্ব অনুমতি থাকলে, আমাকে বলুন। একইভাবে Play AAB থেকে সরিয়ে দেব। এখনকার "বন্ধ" তালিকার কোনো ফিচারের নিজস্ব সংবেদনশীল অনুমতি নেই:
  - পতন শনাক্ত: অনুমতি লাগে না;
  - বাচ্চাদের ঘড়ি: লোকেশন ইতিমধ্যে অন্য ফিচারে আছে;
  - ইঞ্জিন বন্ধ: সার্ভারের কাজ।

## ধাপ ৬ — Content rating, Target audience, App access

- **Content rating (IARC):** `PLAY_STORE_PACK.md` §২-এর উত্তর। মূল কথা:
  - ব্যবহারকারীরা একে অপরের সাথে কথা বলেন: **হ্যাঁ** (My Circle, এলাকার কমিউনিটি, রক্তদাতা);
  - লোকেশন শেয়ার: **হ্যাঁ**;
  - ডিজিটাল কেনাকাটা: **হ্যাঁ**;
  - হিংসা বা জুয়া: না।
- **Target audience:** **শুধু ১৮+।**
  - `kids_watch` (শিশুর স্কুল-মোড, যা শিশুর ফোনে Assisto চালায়) **বন্ধ থাকবে** (`LAUNCH_SWITCHES` দেখুন)। চালু করলে শিশুরাও ব্যবহারকারী হয়ে যায়। তখন Families নীতি, শিশু-উপযুক্ত বিজ্ঞাপন আর আলাদা ঘোষণা লাগে।
  - ১৩–১৭ বাছবেন না।
- **App access:** "All or some functionality is restricted" → রিভিউয়ারের লগইন দিন (`PLAY_REVIEWER_PATH_8NOV_BN.md`)। পাসওয়ার্ড এই রিপোতে কখনো লিখবেন না, শুধু Play Console-এ।
- **অন্য প্রশ্ন:**
  - Government app: না;
  - Financial features: **না** (আমরা ঋণ, বিনিয়োগ বা ব্যাংকিং দিই না; বাজেট আর খাতা হলো নিজের হিসাব রাখা);
  - News app: না;
  - Health apps: হ্যাঁ (ধাপ ৪)।

## ধাপ ৭ — স্টোর লিস্টিং

`PLAY_LISTING_8NOV_ALL_BN.md` দেখুন। সেখানে আছে:
- প্রতিটি দাবি কোডের সাথে মেলানো তালিকা;
- bn ও en লেখা;
- AI-অংশ আলাদা (চাবি লাইভ হলে তবেই দেবেন);
- স্ক্রিনশটের তালিকা।

**বিজ্ঞাপনের লাইন:** "ফ্রি প্ল্যানে বিজ্ঞাপন; Premium/Business-এ কোনো বিজ্ঞাপন নেই; বিজ্ঞাপনের সম্মতি Google-এর ফর্মে।"

## ধাপ ৮ — Staged rollout (ধাপে ধাপে)

Test and release → Production → Create release → AAB (internal-এ যেটা আপনি পরীক্ষা করেছেন, সেই versionCode) → **Staged rollout %**।

শর্ত দেখবেন: Play Console → Quality → Android vitals, আর Owner Admin → Vitals।

| দিন | % | পরের ধাপে যাওয়ার শর্ত |
|---|---|---|
| ৮ Nov | **২০%** | ২৪ ঘণ্টায় নতুন crash cluster নেই। User-perceived crash rate < ১.০৯%, ANR rate < ০.৪৭% (Google-এর "bad behavior" সীমা)। কল বা SOS নিয়ে ১-তারা রিভিউ নেই। |
| ৯–১০ Nov | **৫০%** | একই শর্ত, ৪৮ ঘণ্টা ধরে |
| ১১–১২ Nov | **১০০%** | — |

## ধাপ ৯ — সমস্যা হলে ফেরার পথ

1. **সবচেয়ে দ্রুত:** Owner Admin → Features → সেই ফিচারের `enabled_play` তুলে দিন। ৩০ সেকেন্ড থেকে ১ মিনিটে সব ফোনে লুকিয়ে যায়।
2. **Halt rollout:** Play Console → Production → release → Halt। নতুন কেউ এই ভার্সন পাবেন না।
3. **ঠিক করা বিল্ড:** বেশি versionCode দিয়ে internal → production-এ দিন।
4. **সার্ভার:** ডিপ্লয়ের আগে সবসময় ব্যাকআপ নেওয়া হয়।
5. **কোনো ঘোষণা প্রত্যাখ্যাত হলে** (যেমন চুরি-রোধের FGS): সেই ফিচারের সুইচ Play-তে বন্ধ করুন। আমি Play AAB থেকে তার সার্ভিস সরিয়ে নতুন বিল্ড দেব। বাকি অ্যাপ আটকে থাকবে না।

## ধাপ ১০ — Pre-launch report ও Vitals

- **Test and release → Testing → Pre-launch report → (বিল্ড) → Overview।** দেখার জিনিস:
  - Crashes ও ANRs = ০;
  - Accessibility সতর্কতা (৪৮dp-এর কম বোতাম, কম কনট্রাস্ট, লেবেলবিহীন);
  - Security & trust;
  - Performance।
- **Robot লগইন পার হতে পারে না।** তাই Pre-launch report settings → **Sign-in credentials**-এ রিভিউয়ারের অ্যাকাউন্ট দিন (`PLAY_REVIEWER_PATH_8NOV_BN.md`)।
- **Quality → Android vitals:** শুধু লঞ্চ-বিল্ড বেছে দেখুন।
- **Policy → Policy status:** কোনো লাল ব্যানার নেই।
- **App content:** প্রতিটি সারি সবুজ "Completed" কিনা দেখুন:
  - Data safety, Ads, Target audience, Content rating;
  - Health apps, FGS, Full-screen intent;
  - Government = No, Financial = No, News = No।

---

## ⚠️ পুরনো ডকের ১৮টি অমিল — কোড যা বলে, আর কী ঠিক করা হলো (playall)

| # | কোথায় ছিল | ডক যা বলত | কোড আসলে | ঠিক করা হয়েছে |
|---|---|---|---|---|
| ১ | `PLAY_FGS_DECLARATION_BN.md` | রিস্টার্টের পরে কোনো সার্ভিস নিজে চালু হয় না | চুরি-রোধ বুট বা আপডেটের পরে নিজে চালু হয় (Android ৮–১৩)। ১৪+-এ "ট্যাপ করে চালু" (`RestartPolicy.kt`)। | ডক নতুন করে লেখা |
| ২ | একই | মাইক-ঘোষণা আর ভিডিওতে "Hey Assisto" | কোনো বিল্ডে চালু নয় (`va_wake.dart:54`) | ডক থেকে সরানো। **কোড:** `WakeWordService` Play AAB থেকে সরানো, আর CI-পাহারা। |
| ৩ | একই | Location-এ নিরাপদ যাত্রা নেই | যাত্রাও লোকেশন FGS চালায় (`journey_tracker.dart:402`) | যোগ করা হয়েছে, ভিডিওর ধাপসহ |
| ৪ | `PLAY_STORE_PACK.md` §FGS | মাইক শুধু SOS-এর জন্য | কল চালু রাখতেও লাগে (`call_keepalive.dart:89`) | ডকে ঠিক করা |
| ৫ | `PLAY_STORE_PACK.md` Data safety | অডিও "collected নয়" | ভয়েস নোট এনক্রিপ্ট হয়ে আপলোড হয় | ডকে ঠিক করা: Audio = collected |
| ৬ | `PLAY_STORE_PACK.md` | Device-admin নীতি limit-password / reset-password | শুধু force-lock আর watch-login (`device_admin.xml`) | ডকে ঠিক করা |
| ৭ | `PLAY_STORE_PACK.md` | App interactions শেয়ার হয় না | AdMob-এর সাথে শেয়ার হয় | ডকে ঠিক করা |
| ৮ | `CCTV_PLAY_DECLARATIONS_BN.md` | চুরি-রোধের Camera FGS "অপরিবর্তিত" | Camera FGS সরানো হয়েছে (at100) | ডকে ঠিক করা |
| ৯ | `ADMOB_PLAY_DECLARATIONS_BN.md` | AD_ID বিজ্ঞাপন SDK যোগ করে | CI নিজে সরাসরি যোগ করে, সব বিল্ডে থাকে | ডকে নোট যোগ করা (উত্তর একই: Yes) |
| ১০ | `PLAY_VISIBILITY_0B_SIMPLE_BN.md` বনাম `PLAY_HEALTH_DECLARATION_BN.md` | ভিজিবিলিটি-ডক বলে স্বাস্থ্য লুকাও, স্বাস্থ্য-ডক বলে দেখাও | সব-চালু প্ল্যান: স্বাস্থ্য-ফিটনেস **চালু**, ওষুধ লুকানো। personal অ্যাকাউন্টে fitness/wellness চলে; শুধু medical অ্যাপে organization অ্যাকাউন্ট লাগে। | ভিজিবিলিটি-ডকে ব্যানার। স্বাস্থ্য-ডকই সঠিক উৎস, তাতে রক্তের গ্রুপ যোগ। |
| ১১ | `PLAY_VISIBILITY_0B_SIMPLE_BN.md` | নিরাপদ যাত্রা ও গাড়িতে background-location ঘোষণা | `ACCESS_BACKGROUND_LOCATION` নেই। শুধু FGS ঘোষণা লাগে। | ডকে ঠিক করা |
| ১২ | `PLAY_STORE_PACK.md`, `PLAY_LISTING_FIXED.md`, at100 | রিমোট লক নিয়ে তিন রকম কথা | **আছে।** মালিক বা বিশ্বস্ত মানুষ অন্য ফোন থেকে লক করতে পারেন, যদি device admin চালু থাকে (`RemoteCommands.kt` "lock")। মুছে ফেলা নেই। | লিস্টিংয়ে শর্তসহ: "device admin চালু থাকলে" |
| ১৩ | `PLAY_LISTING_FIXED.md` / `PLAY_VISIBILITY_0B` | গাড়িতে "আসল ম্যাপ নেই" | `flutter_map` আছে | ডকে ঠিক করা |
| ১৪ | `PLAY_LISTING_FIXED.md` | "ভুল আনলকে চোরের ছবি" | ছবি ওঠে শুধু Assisto খোলা থাকলে, ভুল Security PIN দিলে। ফোনের ভুল আনলক শুধু গোনা হয়, ছবি নয়। | ডকে ঠিক করা |
| ১৫ | `PLAY_STORE_PACK.md` (বাংলা লিস্টিং) | বিজ্ঞাপন "ঐচ্ছিক, নন-পার্সোনালাইজড"; পেইডে শুধু "অ্যাপ-খোলার বিজ্ঞাপন নেই" | Free-তে বিজ্ঞাপন আছে, সম্মতি UMP দিয়ে। পেইডে **কোনো** বিজ্ঞাপন নেই। | নতুন লিস্টিং-ডকে ঠিক লাইন |
| ১৬ | লাইভ Play লিস্টিং (`PLAY_LISTING_AUDIT_BN.md`) | ওষুধ, ডাক্তার, হ্যান্ডস-ফ্রি "Hey Assisto", কুরিয়ার বুকিং, জবস ইত্যাদি | প্রতিটি কোডে যাচাই করা (`PLAY_LISTING_8NOV_ALL_BN.md`-এর টেবিল) | নতুন লিস্টিং |
| ১৭ | `PLAY_STORE_PACK.md`-এর পুরো বর্ণনা (২২ Oct) | পুরনো দাবি | — | উপরে ব্যানার: "ব্যবহার করবেন না" |
| ১৮ | আগের এই চেকলিস্ট (সরু প্ল্যান) | Full-screen intent "calling + alarms"; Health info "না"; Health apps "no health features"; ধাপ ৫-এ "সরাও" | Full-screen শুধু কলে (`push_notifier.dart:147`)। সব-চালুতে Health info **হ্যাঁ** (রক্তদাতা, পানি-ঘুম, জরুরি কার্ড)। Health apps ঘোষণা লাগবে। | এই ডক নতুন করে লেখা |

*W = `.github/workflows/android.yml`*
