# বিজ্ঞাপনে বেশি আয় — মালিকের করণীয় (adcontrol, আদেশ ১০ নভেম্বর ০৩:৪৫, অংশ E ও F)

শাখা `agent/adcontrol`। অ্যাপের দিকের কাজ শেষ; নিচের ধাপগুলো **শুধু আপনি** আপনার অ্যাকাউন্টে করবেন। কোনো টাকা খরচ নেই।

## অ্যাপে যা করা হয়েছে
- **মিডিয়েশন:** AdMob bidding-এর মাধ্যমে **Meta Audience Network** ও **AppLovin** — মোট ২টি বাড়তি SDK (সর্বোচ্চ ২)। অ্যাডাপ্টার: `com.google.ads.mediation:facebook:6.22.0.1`, `com.google.ads.mediation:applovin:13.6.4.2` (আমাদের Google Ads SDK 25.4.0-এর সাথে মেলানো)।
- **দ্রুত চালু থাকে:** দুই SDK-র নিজের "startup ContentProvider" সরানো হয়েছে (ColorOS/Realme-এ আগের ক্র্যাশের শিক্ষা); এগুলো শুধু ফ্রি ব্যবহারকারীর জন্য, সম্মতির পরে, অ্যাপ খোলা শেষ হওয়ার পর চালু হয়। কোনো নতুন সংবেদনশীল অনুমতি নেই (AppLovin-এর `CHECK_LICENSE` সরানো)।
- **আকার ও গতি:** দুই SDK মিলিয়ে কাঁচা AAR ≈ ৬.৫ MB; R8-এর পর APK-তে আনুমানিক +২–৩ MB। প্রথম ইন্টিগ্রেশন বিল্ডের APK আকার (android.yml-এর `size:` লাইন) ও শুরু-সময় (perf2gb) আগের বিল্ডের সাথে মিলিয়ে STATUS-এ লেখা হবে; লক্ষ্য ছাড়ালে মিডিয়েশন সরিয়ে দেওয়া হবে।
- **ব্লক করা বিভাগ (অংশ E):** অ্যাপ নিজে সর্বোচ্চ রেটিং **T** পাঠায় (প্রাপ্তবয়স্ক/MA বিজ্ঞাপন আসে না)। ডেটিং, জুয়া, মদ, রাজনীতি — এগুলো শুধু AdMob কনসোলেই বন্ধ করা যায় (নিচে ধাপ ২)।
- **ফ্লোর:** অ্যাপে কোনো স্থির ফ্লোর নেই — AdMob-এর **Optimized floors** ব্যবহার হবে (ধাপ ৪)।
- **৳৪৯ = ১৫ ক্রেডিট** ছোট প্যাক (`credits_c15`) সার্ভারে যোগ হয়েছে; Play Console-এ পণ্যটি বানানো ও Active না হওয়া পর্যন্ত অ্যাপে দেখায় না (ধাপ ৬)।

## আপনার ধাপ

### ১. AdMob — মিডিয়েশন গ্রুপ (৫ মিনিট)
1. admob.google.com → **Mediation** → **Create mediation group**।
2. Ad format: **Banner** → Platform: **Android** → নাম: `Assisto Banner`। **Ad units**-এ Assisto-র Banner ইউনিট যোগ করুন।
3. **Bidding** অংশে **Add ad source** → **Meta Audience Network (bidding)** → পরে **AppLovin (bidding)**।
4. একই কাজ আবার করুন: **Native**, **Interstitial**, **Rewarded**, **App open** (প্রতিটি ফরম্যাটে একটি গ্রুপ)।

### ২. AdMob — বিভাগ ব্লক (৩ মিনিট)
1. AdMob → **Blocking controls** → **All apps** (বা শুধু Assisto)।
2. **Sensitive categories** → বন্ধ করুন: **Dating**, **Gambling & Betting**, **Alcohol**, **Politics**, **Sexual & reproductive health**, **References to sex**।
3. **Ad content** → **Maximum ad content rating**: **T** (অ্যাপও T পাঠায়)।
4. **General categories** থেকে চাইলে আরও বন্ধ করা যায়; তবে যত বেশি বন্ধ, আয় তত কম।

### ৩. Meta Audience Network অ্যাকাউন্ট (১০ মিনিট)
1. business.facebook.com → **Monetization Manager** → **Create property** → নাম `Assisto` → Android অ্যাপ (Play-এর লিংক)।
2. প্রতিটি ফরম্যাটে (Banner, Native, Interstitial, Rewarded) একটি **placement** বানান। প্রতিটির **Placement ID** কপি করুন।
3. AdMob → ধাপ ১-এর গ্রুপে Meta-র পাশে **Placement ID** বসান।
4. Monetization Manager → **app-ads.txt** লাইনটি কপি করুন (যেমন `facebook.com, <আপনার ID>, RESELLER, c3e20eee3f780d68`)।

### ৪. AppLovin অ্যাকাউন্ট (১০ মিনিট)
1. dash.applovin.com → সাইন আপ (Publisher) → **Account → Keys** → **SDK Key** কপি করুন।
2. AdMob → ধাপ ১-এর গ্রুপে AppLovin-এর পাশে **SDK Key** বসান।
3. AppLovin-এর app-ads.txt লাইন কপি করুন (Account → app-ads.txt)।
4. AdMob → **Apps → Assisto → App settings** → **Optimized floors**: **On** (প্রতিটি ইউনিটে "Optimized" — কোনো স্থির উঁচু ফ্লোর নয়)।

### ৫. app-ads.txt-এ সঙ্গীদের লাইন (২ মিনিট)
Owner Admin → **Integrations → Google AdMob** → **app-ads.txt অতিরিক্ত লাইন** ঘরে ধাপ ৩ ও ৪-এর লাইন দুটি বসান (প্রতি লাইনে একটি, বা `;` দিয়ে আলাদা) → সংরক্ষণ। ১০ মিনিটের মধ্যে `lifeassisto.com/app-ads.txt`-এ দেখা যাবে। ভুল লেখা লাইন নিজে থেকে বাদ পড়ে।

### ৬. Play Console — নতুন ছোট প্যাক ৳৪৯ (৫ মিনিট)
1. Play Console → Assisto → **Monetize → Products → In-app products** → **Create product**।
2. Product ID: **`credits_c15`** (ঠিক এই নাম) · নাম: "১৫ ক্রেডিট" · বিবরণ: "১৫ ক্রেডিট, কেনার দিন থেকে ১২ মাস মেয়াদ" · দাম: **BDT 49**।
3. **Save** → **Activate**।
4. Owner Admin → **Payments → "Google Play-তে আবার যাচাই"** চাপুন। `pack_c15` "চালু — বিক্রি হচ্ছে" দেখালে অ্যাপে প্যাকটি আসবে।
5. হিসাব: ৳৪৯ ÷ ২.৮০ = ১৭.৫ → নিচে ৫-এর গুণিতকে **১৫ ক্রেডিট**; ৪০% লাভের নিয়ম মানে (CI পরীক্ষা `tests_adcontrol`)।

### ৭. আয়ের আসল সংখ্যা (ঐচ্ছিক, পরে)
Owner Admin → **বিজ্ঞাপন নিয়ন্ত্রণ** এখন প্রতিটি জায়গার ইমপ্রেশন, eCPM ও দৈনিক আয় দেখায় — Google যখন প্রতি-ইমপ্রেশন মান পাঠায় তখন আসল, তার আগে "আনুমানিক"। হুবহু AdMob রিপোর্টের জন্য: Google Cloud → **AdMob API** চালু → OAuth client → আমাদের জানান (এটা মালিকের কাজ; চাবি কখনো git-এ যায় না)।

## মালিকের পরীক্ষা (দুই ফোন, ১০ মিনিট)
1. ফোন ক (ফ্রি অ্যাকাউন্ট): নোট খুলুন → নিচে একটি ব্যানার। হিসাব → মূল পাতায় একটি নেটিভ কার্ড।
2. ফোন খ (Premium বা Plus): একই পাতা — **কোনো AdMob বিজ্ঞাপন নেই**।
3. Owner Admin → বিজ্ঞাপন নিয়ন্ত্রণ → "নোট ও কাজ — ব্যানার" বন্ধ → সংরক্ষণ। ফোন ক-তে অ্যাপ বন্ধ না করে ৫ মিনিট পর অ্যাপে ফিরে নোট খুলুন → ব্যানার নেই।
4. "SOS ও জরুরি" চালু করতে চেষ্টা করুন → "এটা জরুরি বা নিরাপত্তার পাতা — আপনি কি নিশ্চিত?" সতর্কতা আসবে; বাতিল চাপুন।
5. ফোন ক: ট্রেন ট্র্যাকার → একটি ট্রেন বাছুন → "একটি ছোট বিজ্ঞাপন দেখবেন?" → দেখুন → লাইভ পাতা; ১৫ মিনিটের মধ্যে আবার খুললে বিজ্ঞাপন চাইবে না। (আসল ID চালু না থাকলে বিজ্ঞাপন চায়ই না — সরাসরি খোলে।)
