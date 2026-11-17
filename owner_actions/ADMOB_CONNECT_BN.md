# AdMob সংযোগ — মালিকের ধাপে ধাপে কাজ (১৭ নভেম্বর ২০২৬)

**সংক্ষেপে:** অ্যাপ Google Play-তে চালু। app-ads.txt চালু আছে ও ঠিক আছে। এখন আপনাকে AdMob-এ ৪টি কাজ করতে হবে: (১) অ্যাপকে Google Play-র সাথে যুক্ত করা, (২) দুটি সম্মতি-বার্তা (GDPR ও US) প্রকাশ, (৩) সংবেদনশীল বিজ্ঞাপন-বিভাগ ব্লক, (৪) নিজের ফোনকে "টেস্ট ডিভাইস" করা। তারপর **Owner Admin → বিজ্ঞাপন → "আসল AdMob ইউনিট আইডি চালু"** — শুধু এই চারটি শেষ হলে চালু করবেন। এখন সার্ভারে এটি **বন্ধ** — তাই এখন সবাই Google-এর টেস্ট বিজ্ঞাপন দেখে, কোনো আয় নেই, কোনো ঝুঁকিও নেই।

উৎস: শুধু Google-এর প্রকাশ্য AdMob ও Play Console সাহায্য-পাতা (প্রতিটি অংশের নিচে লিংক)। Google মেনুর নাম মাঝে মাঝে বদলায় — না মিললে লিংকের পাতাটি দেখুন।

## ১. app-ads.txt — হয়ে গেছে ✅ (কিছু করতে হবে না)

- https://lifeassisto.com/app-ads.txt → 200, text/plain, লাইন: `google.com, pub-2506398550427515, DIRECT, f08c47fec0942fa0`
- pub আইডি অ্যাপের AdMob App ID `ca-app-pub-2506398550427515~5116255919`-এর সাথে মেলে।
- www ও http → 301 দিয়ে ওপরের ঠিকানায় যায়।
- AdMob-এ অবস্থা দেখতে: **Apps → View all apps → app-ads.txt** ট্যাব → Assisto সারির পাশে ছোট তীর (expand) চাপুন। প্রথমবার যাচাই হতে ২৪ ঘণ্টা পর্যন্ত লাগতে পারে। ([উৎস](https://support.google.com/admob/answer/9363762))

## ২. AdMob-এ অ্যাপকে Google Play-র সাথে যুক্ত করা

**পথ ক (সব অ্যাপের তালিকা থেকে):**
1. admob.google.com-এ লগইন → বাঁ পাশে **Apps** → **View all apps**।
2. Assisto সারিতে **Stores** কলামে **Add store** চাপুন।
3. খোঁজার ঘরে লিখুন: `com.assisto.assisto` (প্যাকেজ নাম) → Assisto দেখালে **Add**।
4. অন্য স্টোরের তালিকা এলে কিছু বাছবেন না → **Continue**।
5. অ্যাপের নাম ও প্যাকেজ নাম নিজে থেকে বসেছে কিনা দেখুন → user metrics চালু রাখুন → **Add app**।

**পথ খ (অ্যাপের সেটিংস থেকে):** Apps → **Assisto** → **App settings** → **App stores** অংশে **Add store** → ওপরের ৩–৫।

- "Add store" না দেখালে অ্যাপ সম্ভবত আগেই যুক্ত — App settings-এ Google Play লেখা আছে কিনা দেখুন।
- নতুন Play অ্যাপ যুক্ত হতে ২৪–৪৮ ঘণ্টা, কখনো এক সপ্তাহ লাগে। যুক্ত না হলে আসল বিজ্ঞাপন চলে না।
- তারপর **Apps → Assisto → App overview**-এ "app readiness" সবুজ (Ready) হয়েছে কিনা দেখুন।

উৎস: [Link your app to an app store](https://support.google.com/admob/answer/10037806), [About app readiness](https://support.google.com/admob/answer/10564477)

## ৩. Privacy & messaging — দুটি সম্মতি-বার্তা তৈরি ও প্রকাশ

**অ্যাপ নিজে যা করে (কোড যাচাই করা হয়েছে, লাইভ ১০৩৩৮ ও এখনকার main দুটোতেই):** কোনো বিজ্ঞাপন চাওয়ার আগে, এমনকি AdMob SDK চালু করার আগেই, অ্যাপ Google-এর UMP সম্মতি SDK ডাকে (`requestConsentInfoUpdate` → দরকার হলে Google-এর ফর্ম দেখায় → `canRequestAds()` হ্যাঁ হলে তবেই বিজ্ঞাপন)। UMP সাড়া না দিলে বিজ্ঞাপন নেই (fail closed)। ইউরোপ/UK/সুইজারল্যান্ড ও US রাজ্যের ব্যবহারকারী সবসময় নন-পার্সোনালাইজড বিজ্ঞাপন পান। সেটিংসে "Ad privacy choices" সারি দেখায় শুধু যেখানে Google বলে দরকার। ফাইল: `app/lib/ads/admob_sdk.dart`, `app/lib/ads/consent.dart`। CI গার্ড `ads_consent_gate_guard_test` এই নিয়ম ভাঙলে বিল্ড ফেল করায়।
কিন্তু Google ফর্মটি দেখাবে **শুধু তখনই যখন আপনি নিচের বার্তাগুলো প্রকাশ করবেন।**

### ৩ক. European regulations (GDPR) বার্তা
1. AdMob → বাঁ পাশে **Privacy & messaging**।
2. **European regulations** কার্ডে **Create** (আগে বানানো থাকলে **Manage → Create message**)।
3. **Select apps** → **Assisto** টিক → **Confirm**।
4. **Languages:** Default language = **English**; Additional languages = **Bengali** (তালিকায় থাকলে)। প্রতিটি ভাষার লেখা একবার পড়ে দেখুন।
5. **User choices:** **"Do not consent" = On** (প্রথম পাতাতেই এক চাপে "না" বলা যাবে — সৎ ও নিরাপদ)। **Close (do not consent) = On**।
6. **Targeting:** **Countries subject to GDPR (EEA, UK, and Switzerland)**।
7. **Message name:** `Assisto GDPR` (শুধু আপনি দেখবেন)।
8. **Privacy policy URL:** `https://lifeassisto.com/privacy`
9. **Publish** চাপুন (Save draft নয়)।

উৎস: [Create a European regulations message](https://support.google.com/admob/answer/10113207)

### ৩খ. US state regulations বার্তা
1. **Privacy & messaging** → **US state regulations** কার্ডে **Create** (বা **Manage → Create message**)।
2. **Select apps** → **Assisto** → **Confirm**।
3. **Default language:** **English**।
4. **Targeting:** **"All current and future supported US states" = On**।
5. **Message name:** `Assisto US states`।
6. লেখা যেমন আছে রাখুন → **Publish**।

উৎস: [Create a US state regulations message](https://support.google.com/admob/answer/10860309), [About US state regulations messages](https://support.google.com/admob/answer/10862202)

**পরীক্ষা (ইচ্ছা হলে):** Owner Admin → বিজ্ঞাপন → "ইউরোপের (EEA) সম্মতি ফর্ম জোর করে দেখান" চালু + Owner Admin → ইন্টিগ্রেশন ও কি → Google AdMob → "UMP টেস্ট ডিভাইস আইডি"-তে আপনার ফোনের hashed id (logcat-এ দেখায়) → অ্যাপ খুললে GDPR ফর্ম আসবে। পরীক্ষা শেষে বন্ধ করুন।

## ৪. Play Console-এ ওয়েবসাইট lifeassisto.com কিনা

পথ: Play Console → **Assisto** → বাঁ পাশে **Grow users → Store presence → Store settings** → **Store listing contact details** খুলুন → **Website** ঘরে ঠিক `https://lifeassisto.com` আছে কিনা দেখুন (www ছাড়া, শেষে কিছু নয়)।
- আমরা Google Play-র প্রকাশ্য পাতা থেকে দেখেছি: সেখানে `https://lifeassisto.com` দেখাচ্ছে ✅। তাই **কিছু বদলাবেন না** (Play নিয়ম: স্টোর লিস্টিং বদলালে আবার রিভিউ হয়)।
- AdMob এই Website থেকেই app-ads.txt খোঁজে, তাই এটি মিলতেই হবে।

উৎস: [How to support your app's users (contact details)](https://support.google.com/googleplay/android-developer/answer/113477), [Set up app-ads.txt](https://support.google.com/admob/answer/9363762)

## ৫. AdMob-এ বিজ্ঞাপন ইউনিট — কোনটি কোথায়

**গুরুত্বপূর্ণ সত্য:** অ্যাপ এখন **প্রতি ধরনের জন্য একটি ইউনিট** নেয় (মোট ৫টি) — প্রতি জায়গার জন্য আলাদা ইউনিট বসানোর ঘর অ্যাপে বা Owner Admin-এ নেই। প্রতি জায়গার আয়/ইমপ্রেশন Owner Admin → বিজ্ঞাপন পাতায় আলাদা আলাদা দেখায় (আমাদের নিজের হিসাব), তাই ৫৯টি ইউনিট বানানোর দরকার নেই — বানালেও সেগুলোতে কোনো বিজ্ঞাপন যাবে না।

**আপনার AdMob-এ ৫টি আসল ইউনিট আগেই আছে** (কোডে ও সার্ভারে বসানো, নিচের শেষ অংশ)। তাই:
1. AdMob → **Apps → Assisto → Ad units** খুলুন।
2. নিচের ৫টি আইডি তালিকায় আছে কিনা মিলিয়ে দেখুন। থাকলে **নতুন বানাবেন না** — শুধু নাম ঠিক করুন (ইউনিটের নাম চাপুন → নাম বদলান → Save)।
3. কোনোটি না থাকলে: **Add ad unit** → ধরন বাছুন → নিচের নাম লিখুন → **Create ad unit** → নতুন আইডি কপি করে ৬ নম্বর অংশের ঘরে পেস্ট।
4. Banner ইউনিটের **Automatic refresh = বন্ধ / Disabled** রাখুন (অ্যাপ নিজে ৬০ সেকেন্ডের আগে বদলায় না)।
5. Rewarded ইউনিটে **Server-side verification** চালু রাখুন (অ্যাপ পুরস্কার দেয় শুধু Google-এর SSV যাচাইয়ের পর)।

| ধরন | AdMob-এ যে নাম লিখবেন | এখন কোডে/সার্ভারে থাকা আইডি | কোথায় দেখায় (সংক্ষেপে) |
|---|---|---|---|
| App open | `Assisto – App open – App open` | `ca-app-pub-2506398550427515/1193237050` | অ্যাপে ফিরে আসার সময় হোমের ওপর (দিনে সর্বোচ্চ ২, ৩ ঘণ্টা ফাঁক, প্রথম দিনে নয়) |
| Native | `Assisto – Home & lists – Native` | `ca-app-pub-2506398550427515/7259951959` | হোম কার্ড, ডিসকভার, তালিকার মাঝে কার্ড |
| Banner | `Assisto – All screens – Banner` | `ca-app-pub-2506398550427515/4940910375` | সাধারণ ফিচার পাতার নিচে একটি ব্যানার |
| Interstitial | `Assisto – After task – Interstitial` | `ca-app-pub-2506398550427515/3547937658` | একটি কাজ শেষ করে বের হওয়ার সময় (৩ মিনিট ফাঁক, দিনে ৬) |
| Rewarded | `Assisto – Unlock – Rewarded` | `ca-app-pub-2506398550427515/2426427676` | ব্যবহারকারী নিজে "বিজ্ঞাপন দেখে খুলুন" চাপলে |

### ৫ক. প্রতিটি জায়গা → কোন ইউনিট → Owner Admin-এর কোন ঘর (চালু ৫৯টি; সার্ভারে এখন ঠিক ৫৯টি চালু)

জায়গার ধরন বদলাতে: Owner Admin → **বিজ্ঞাপন নিয়ন্ত্রণ** (`/owner/ad-control`) → জায়গাটি চাপুন। ধরন বদলালে ইউনিটও সেই ধরনেরটি হয়ে যায়।

| # | জায়গা (key) | অ্যাপে কোথায় দেখায় | ধরন | AdMob ইউনিট (নাম) | Owner Admin-এর ঘর |
|---|---|---|---|---|---|
| ১ | `app_open` | অ্যাপ খোলার বিজ্ঞাপন | app_open | Assisto – App open – App open | App-open unit ID |
| ২ | `home` | হোম — নেটিভ কার্ড (আগের মতো) | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৩ | `discover_native` | ডিসকভার — তালিকায় AdMob নেটিভ | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৪ | `all_services` | সব সেবা — নেটিভ | native (banner বাছলে → Banner) | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৫ | `after_call_review` | কল শেষের রিভিউ কার্ড — নেটিভ | native (banner বাছলে → Banner) | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৬ | `finance_home` | হিসাব ও অর্থ মূল পাতা — নেটিভ কার্ড | native (banner বাছলে → Banner) | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৭ | `finance_list` | লেনদেনের তালিকা — প্রতি ১৫–২০ সারিতে নেটিভ | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৮ | `finance_reports` | রিপোর্ট — নিচে নেটিভ | native (banner বাছলে → Banner) | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ৯ | `mess_list` | মেস তালিকা — নেটিভ | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ১০ | `notes_list` | নোট ও কাজের তালিকা — নেটিভ | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ১১ | `city_results` | সিটি সার্ভিস ফলাফল — নেটিভ | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ১২ | `offers_list` | অফার, কুপন ও মার্কেট — নেটিভ | native | Assisto – Home & lists – Native | Native unit ID (হোম হিরো) |
| ১৩ | `circle_list` | মাই সার্কেল চ্যাট তালিকা — ব্যানার (আগের মতো) | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ১৪ | `photo_gallery` | ফটো স্টুডিও শুরুর পাতা — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ১৫ | `lp_home` | ল্যাঙ্গুয়েজ পার্টনার — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ১৬ | `lp_hub` | ল্যাঙ্গুয়েজ পার্টনার IELTS হাব — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ১৭ | `lp_life` | ল্যাঙ্গুয়েজ পার্টনার জীবনের পরিস্থিতি তালিকা — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ১৮ | `lp_vocab` | ল্যাঙ্গুয়েজ পার্টনার শব্দভান্ডার — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ১৯ | `exam` | পরীক্ষার ফলাফল পাতা — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২০ | `mess_home` | মেস — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২১ | `notes_home` | নোট ও কাজ — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২২ | `reminders_list` | রিমাইন্ডার তালিকা — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৩ | `birthdays` | জন্মদিন — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৪ | `meetings` | মিটিং — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৫ | `city_search` | সিটি সার্ভিস খোঁজা ও ফলাফল — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৬ | `nearby` | কাছাকাছি — ব্যানার (আগের মতো) | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৭ | `train_search` | ট্রেন খোঁজা — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৮ | `train_detail` | ট্রেনের বিস্তারিত — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ২৯ | `saved_items` | সংরক্ষিত — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩০ | `dictionary` | অভিধান — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩১ | `jobs` | চাকরি — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩২ | `cv_builder` | সিভি বিল্ডার — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩৩ | `contract` | চুক্তি যাচাই — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩৪ | `guide` | সেবা গাইড — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩৫ | `quick_tools` | কুইক টুলস — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩৬ | `settings` | সেটিংস তালিকা — ব্যানার | banner (native বাছলে → Native) | Assisto – All screens – Banner | Banner unit ID |
| ৩৭ | `article_after_read` | লেখা পড়া শেষে ফিরে যাওয়ার সময় | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৩৮ | `photo_after_save` | ফটো সেভের পর — পূর্ণ পর্দা | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৩৯ | `lesson_after_finish` | পাঠ শেষে — পূর্ণ পর্দা | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪০ | `exam_after_submit` | পরীক্ষা জমার পর, ফলাফলের আগে — একটি পূর্ণ পর্দা | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪১ | `student_after_practice` | ছাত্র কর্নার অনুশীলনের পর | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪২ | `finance_after_export` | PDF রপ্তানি বা শেয়ারের পর — পূর্ণ পর্দা | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৩ | `finance_month_report` | মাস শেষের পূর্ণ রিপোর্ট — পূর্ণ পর্দা | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৪ | `mess_month_report` | মেসের মাস শেষের রিপোর্ট — পূর্ণ পর্দা | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৫ | `scan_after_save` | ডকুমেন্ট স্ক্যান সেভের পর | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৬ | `cv_after_download` | সিভি ডাউনলোডের পর | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৭ | `interview_after_feedback` | মক ইন্টারভিউ ফিডব্যাকের পর | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৮ | `job_after_apply` | চাকরিতে আবেদনের পর | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৪৯ | `plan_after_save` | ভ্রমণ/অনুষ্ঠান পরিকল্পনা সেভের পর | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৫০ | `estimate_after_finish` | খরচ হিসাব/সেবা গাইড শেষে | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৫১ | `quick_tool_exit` | কুইক টুল ব্যবহারের পর (দিনে ১ বার) | interstitial | Assisto – After task – Interstitial | Interstitial unit ID |
| ৫২ | `ai_chat_unlock` | এআই চ্যাট — বিজ্ঞাপন দেখে উত্তর খুলুন | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৩ | `photo_studio` | ফটো স্টুডিও — বিজ্ঞাপন দেখে খুলুন | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৪ | `lp_unlock` | ল্যাঙ্গুয়েজ পার্টনার — বিজ্ঞাপন দেখে খুলুন | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৫ | `city_more_routes` | আরও পথ (Google) — বিজ্ঞাপন দেখে | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৬ | `train_live_unlock` | ট্রেনের লাইভ অবস্থান — বিজ্ঞাপন দেখে, তারপর ১৫ মিনিট ফ্রি | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৭ | `security_unlock` | নিরাপত্তা ফিচার চালু — একবার বিজ্ঞাপন, তারপর চিরকাল ফ্রি | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৮ | `security_scan` | প্রতি স্ক্যান বা নম্বর যাচাই — একটি বিজ্ঞাপন | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |
| ৫৯ | `credits` | ক্রেডিট পেতে বিজ্ঞাপন (ব্যবহারকারী নিজে চাইলে) | rewarded | Assisto – Unlock – Rewarded | Rewarded unit ID |

## ৬. Owner Admin-এ কোথায় কোন আইডি পেস্ট করবেন

পথ: Owner Admin → বাঁ মেনু **ইন্টিগ্রেশন ও কি** (`/owner/integrations`) → **Google AdMob** কার্ড → নিচের ঘরগুলো → **Save** → **Test** (সবুজ "working" হতে হবে)।

| ঘরের নাম (Owner Admin-এ যেমন লেখা) | কী পেস্ট করবেন |
|---|---|
| AdMob App ID | `ca-app-pub-2506398550427515~5116255919` (আগেই আছে) |
| App-open unit ID | App open ইউনিটের আইডি |
| Native unit ID (হোম হিরো) | Native ইউনিটের আইডি (হোম, ডিসকভার, তালিকা — সব নেটিভ এটাই) |
| Banner unit ID | Banner ইউনিটের আইডি (সব ব্যানার) |
| Interstitial unit ID | Interstitial ইউনিটের আইডি (সব পূর্ণ পর্দা) |
| Rewarded unit ID | Rewarded ইউনিটের আইডি (সব "বিজ্ঞাপন দেখে খুলুন") |
| Publisher ID (app-ads.txt) | `pub-2506398550427515` (আগেই আছে) |
| **শুধু টেস্ট বিজ্ঞাপন পাবে এমন ফোন নম্বর (টেস্টার; কমা দিয়ে)** — নতুন (admob-connect, মার্জ হলে দেখাবে) | টেস্টারদের ফোন নম্বর, যেমন `01XXXXXXXXX, 01YYYYYYYYY` |

সার্ভারে এখন: ৫টি ইউনিট + App ID + Publisher ID সব ঘর ভরা, কোডের আইডির সাথে হুবহু মেলে, কার্ড "working" ✅। আইডি বদলালে নতুন বিল্ড লাগে না।
শেষ ধাপ (৭-এর সব ✅ হলে): Owner Admin → **বিজ্ঞাপন** (`/owner/ads`) → **"আসল AdMob ইউনিট আইডি চালু"** টিক → Save।

## ৭. লাইভ অ্যাপ নিয়ম মানছে কিনা (কোড: লাইভ ১০৩৩৮ = 7d4727b8, এবং এখনকার main; সার্ভার: শুধু পড়া, কিছু বদলানো হয়নি)

| নিয়ম | ফল | প্রমাণ |
|---|---|---|
| Premium / Plus / Business / Founder / Trial-এ কোনো AdMob নয় | ✅ পাস | সার্ভার: `effective_plan != "free"` হলে `ads_enabled=false`, সব জায়গা বন্ধ (`views_ads.py`, `logic/ads.py`); শিশু অ্যাকাউন্টও বন্ধ। অ্যাপ: সার্ভারকে একা বিশ্বাস করে না — `plan != 'free'` হলেই বিজ্ঞাপন নেই (`ad_rules.dart`, ১০৩৩৮-এও)। নতুন টেস্ট: Plus ও Premium → শূন্য বিজ্ঞাপন। |
| ডিফল্ট-বন্ধ জায়গা বন্ধই আছে; SOS, জরুরি, সেফ জার্নি, ফ্যামিলি কেয়ার, কেয়ার কল, রক্তদাতা, কুরআন, পেমেন্ট, লগইন, চ্যাট/কল-এ বিজ্ঞাপন নেই | ✅ পাস | লাইভ সার্ভার: ৭৭ জায়গার ৫৯টি চালু, ১৮টি নিরাপত্তা-জায়গার **০টি** চালু। লাইভ অ্যাপ ১০৩৩৮: শুধু অনুমোদিত-তালিকার পাতায় ব্যানার (`ad_placements.dart`), তালিকায় কোনো নিরাপত্তা পাতা নেই; সার্ভারেও একই "never" তালিকা + শব্দ-বেড়া (sos, safe, journey, family, blood, quran, pay, call, chat …)। |
| নিষিদ্ধ বিভাগ (ডেটিং, জুয়া, মদ, ১৮+, রাজনীতি) | ⚠️ আপনার কাজ | এটি শুধু AdMob কনসোলে সেট হয় — নিচের ৭ক করুন। অ্যাপ নিজে: `maxAdContentRating = T` (প্রাপ্তবয়স্ক MA বিজ্ঞাপন কখনো নয়) ✅; অ্যাপ শিশু-কেন্দ্রিক নয় তাই `tagForChildDirectedTreatment` দেওয়া হয়নি (শিশু অ্যাকাউন্টে বিজ্ঞাপনই নেই) ✅। |
| প্রয়োজনে সম্মতি ফর্ম বিজ্ঞাপনের আগে | ✅ কোড পাস / ⚠️ আপনার কাজ | কোড: UMP → ফর্ম → `canRequestAds()` → তবেই SDK ও বিজ্ঞাপন; ব্যর্থ হলে বিজ্ঞাপন নেই। ফর্ম দেখাতে ৩ক ও ৩খ প্রকাশ করতে হবে। |
| মালিক ও টেস্টার শুধু টেস্ট বিজ্ঞাপন পান (invalid click নয়) | ✅ এখন নিরাপদ; ❌ আসল আইডি চালুর পর ছিল না → **ঠিক করা হয়েছে** (admob-connect) + ⚠️ আপনার কাজ ৭খ | এখন সার্ভারে "আসল আইডি" **বন্ধ** → সবাই Google টেস্ট ইউনিট পায়। কিন্তু চালু করলে মালিকের ফ্রি টেস্ট অ্যাকাউন্টও আসল বিজ্ঞাপন পেত। ঠিক: সার্ভার এখন superuser/staff, মালিকের নম্বর, Play রিভিউয়ার ও "টেস্ট ফোন" ঘরের নম্বরকে সবসময় টেস্ট ইউনিট দেয় (rewarded টিকিটও আসল ইউনিট পায় না); লাইভ অ্যাপ ১০৩৩৮-এ নতুন বিল্ড ছাড়াই কাজ করে। ডিবাগ বিল্ডে আসল ইউনিট কখনো লোড হয় না। |

### ৭ক. নিষিদ্ধ বিভাগ ব্লক — ঠিক যেখানে চাপবেন
1. AdMob → বাঁ পাশে **Blocking controls** (পুরো অ্যাকাউন্টের জন্য; শুধু Assisto হলে: Apps → Assisto → **Blocking controls**)।
2. **Manage Sensitive categories** চাপুন।
3. **Block** করুন: **Dating**, **Politics**, **Reference to sex**, **Sexual and reproductive health**, **Get rich quick**।
4. **Gambling & Betting (18+)** ও **Alcohol** — এগুলো ডিফল্টেই ব্লক; **Blocked** আছে কিনা দেখুন, Allow করবেন না।
5. বদল নিজে থেকে সেভ হয় (Save বোতাম নেই)।
- ব্লক বেশি করলে আয় কিছুটা কমে — তবু এগুলো আমাদের নিয়ম। Google বলে স্বয়ংক্রিয় বাছাই ১০০% নিখুঁত নয়; কোনো খারাপ বিজ্ঞাপন দেখলে সেটির URL একই পাতায় ব্লক করা যায়।

উৎস: [Block ads by sensitive category](https://support.google.com/admob/answer/3150176), [List of sensitive categories](https://support.google.com/admob/answer/3150953), [Ad blocking options](https://support.google.com/admob/answer/3150235)

### ৭খ. নিজের ও টেস্টারদের ফোন "Test device" করা (rewarded-সহ সব বিজ্ঞাপনে নিরাপদ)
1. AdMob → **Settings** → **Test devices** → **Add test device**।
2. Platform = Android; Advertising ID = ফোনের **Settings → Google → Ads** (বা Privacy → Ads)-এ থাকা আইডি; নাম যেমন `Owner Realme`।
3. **Save**। কাজ শুরু হতে ১ ঘণ্টা (কখনো ২৪ ঘণ্টা) লাগে; বিজ্ঞাপনে "Test mode" লেখা দেখলে তবেই চাপুন।
4. টেস্টারদের নম্বর Owner Admin → ইন্টিগ্রেশন ও কি → Google AdMob → "শুধু টেস্ট বিজ্ঞাপন পাবে এমন ফোন নম্বর"-এ দিন (মার্জের পর)।
- নিজের আসল বিজ্ঞাপনে কখনো চাপবেন না — Google অ্যাকাউন্ট বন্ধ করে দিতে পারে।

উৎস: [Set up a test device](https://support.google.com/admob/answer/9691433), [How you can prevent invalid activity](https://support.google.com/admob/answer/3342099)

## ৮. পেমেন্ট (পরে — কোম্পানির ব্যাংক অ্যাকাউন্ট হলে; এখন কিছু করবেন না)

যা লাগবে:
1. **পেমেন্ট প্রোফাইল:** অ্যাকাউন্ট টাইপ Business, কোম্পানির নাম ব্যাংক অ্যাকাউন্টের নামের সাথে হুবহু এক, ঠিকানা।
2. **ট্যাক্স তথ্য:** AdMob → **Payments → Settings / Manage settings → United States tax info** → বাংলাদেশি কোম্পানির জন্য সাধারণত W-8BEN-E ফর্ম (কোম্পানির নাম, দেশ, ঠিকানা, TIN/BIN); ফর্মের ধরন হিসাবরক্ষককে দিয়ে নিশ্চিত করুন। মাসের ২০ তারিখের আগে দিলে সেই মাসে পেমেন্ট। ([উৎস](https://support.google.com/admob/answer/2772513))
3. **পরিচয় যাচাই** (Google চাইলে): কোম্পানির কাগজ/মালিকের NID।
4. **ঠিকানা যাচাই (PIN):** আয় প্রায় $১০ হলে Google ডাকযোগে ৬ অঙ্কের PIN পাঠায় → AdMob-এ বসাতে হয়; ৪ মাস সময়, ৩ বার ভুল হলে বিজ্ঞাপন বন্ধ। তাই পেমেন্ট ঠিকানা এমন দিন যেখানে চিঠি নিশ্চিত পৌঁছায়। ([উৎস](https://support.google.com/admob/answer/2772302))
5. **পেমেন্ট পদ্ধতি:** বাংলাদেশে সাধারণত **Wire transfer** — কোম্পানির নামে ব্যাংক অ্যাকাউন্ট, ব্যাংকের নাম, অ্যাকাউন্ট নম্বর, **SWIFT/BIC কোড**, শাখার ঠিকানা। Google যাচাইয়ের জন্য ছোট একটি টাকা পাঠাতে পারে। ([উৎস](https://support.google.com/admob/answer/6149211))
6. **পেমেন্ট সীমা:** সাধারণত $১০০ (বা সমমান) — মাস শেষে ব্যালান্স সীমার ওপরে থাকলে পরের মাসের ২১ তারিখের দিকে টাকা আসে; কম হলে পরের মাসে যোগ হয়। ([উৎস](https://support.google.com/admob/checklist/2998383))

## ৯. আপনার করণীয় — এক নজরে
1. ২ — Google Play লিংক (৫ মিনিট)।
2. ৩ক + ৩খ — দুটি বার্তা Publish (১০ মিনিট)।
3. ৫ — AdMob-এ ৫টি ইউনিট মিলিয়ে নাম ঠিক করা; Banner auto-refresh বন্ধ।
4. ৭ক — বিভাগ ব্লক; ৭খ — নিজের ফোন Test device।
5. সব হলে ও "app readiness" Ready হলে: Owner Admin → বিজ্ঞাপন → "আসল AdMob ইউনিট আইডি চালু"।
