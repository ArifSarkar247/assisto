# পেমেন্ট চালু করার নির্দেশিকা (Google Play + EPS)

Assisto-তে Premium / Business / ক্রেডিট কেনার **দুটি উপায়**:

1. **Google Play Billing** — শুধু Play Store থেকে নামানো অ্যাপে, সবার আগে দেখায়।
2. **বিকাশ / নগদ / কার্ড — EPS** (Easy Payment System) — ওয়েবসাইট থেকে নামানো APK-তে, আর
   ওয়েবসাইট https://lifeassisto.com/premium -এ। Play বিল্ডেও দেখানো যায় (নিচে "সুইচ" দেখুন)।

যেভাবেই কেনা হোক, সার্ভারে **একটাই হিসাব**: কেনার সঙ্গে সঙ্গে অ্যাপ, ওয়েবসাইট — সব জায়গায় চালু।
কোনো কেনাকাটা সার্ভার নিজে Google / EPS-এর কাছে **যাচাই না করে** কখনো চালু হয় না।

কী এখনই তৈরি আছে আর কী আপনার দরকার — এক নজরে:

| অংশ | অবস্থা |
|---|---|
| কেনার শিট (অ্যাপ), ৳ দাম, বাংলা + ইংরেজি | তৈরি |
| সার্ভারে যাচাই, রিফান্ড, মেয়াদ শেষ, নবায়ন রিমাইন্ডার | তৈরি |
| ওয়েবসাইট /premium (ফোন OTP দিয়ে লগইন) | তৈরি (SMS গেটওয়ে চালু থাকলে OTP যায়) |
| Admin → Payments (সুইচ, ফি, দাম, চ্যানেল-ভিত্তিক লাভ) | তৈরি |
| EPS মার্চেন্ট অ্যাকাউন্ট + কী | **আপনার কাজ** (নিচে ধাপ ১) |
| Play Console প্রোডাক্ট + সার্ভিস অ্যাকাউন্ট + RTDN | **আপনার কাজ** (নিচে ধাপ ২) |

চালু করা মানে শুধু: **Admin → Integrations-এ কী পেস্ট করা → Test**। নতুন অ্যাপ বিল্ড লাগে না।

---

## ধাপ ১ — EPS মার্চেন্ট অ্যাকাউন্ট

### ১.১ EPS-এর কাছে যা জমা দিতে হয় (মার্চেন্ট অনবোর্ডিং)

EPS (https://eps.com.bd, ফোন 09609377377, ইমেইল support@eps.com.bd, ইন্টিগ্রেশন:
integration@eps.com.bd)-কে বলুন: "ওয়েবসাইট + অ্যান্ড্রয়েড অ্যাপের জন্য পেমেন্ট গেটওয়ে মার্চেন্ট
অ্যাকাউন্ট চাই (বিকাশ, নগদ, কার্ড)"। সাধারণত যা চাওয়া হয় (EPS চূড়ান্ত তালিকা দেবে):

- **ট্রেড লাইসেন্স** (হালনাগাদ)
- **TIN সার্টিফিকেট** (e-TIN); থাকলে **BIN / VAT রেজিস্ট্রেশন**
- মালিকের **জাতীয় পরিচয়পত্র (NID)** ও ছবি
- **ব্যাংক অ্যাকাউন্ট** — ব্যবসার নামে (চেকের পাতা বা ব্যাংক সলভেন্সি/অ্যাকাউন্ট সার্টিফিকেট)।
  টাকা এই অ্যাকাউন্টে জমা হবে।
- ব্যবসার ঠিকানা, ফোন, ইমেইল
- **ওয়েবসাইট**: https://lifeassisto.com (দাম, শর্তাবলী https://lifeassisto.com/terms,
  গোপনীয়তা নীতি https://lifeassisto.com/privacy, যোগাযোগ — সবই আছে)
- **অ্যাপ**: Play Store লিংক (প্রকাশিত হলে) এবং ওয়েবসাইট APK লিংক https://lifeassisto.com/get
- রিফান্ড নীতি (শর্তাবলীতে আছে; দরকার হলে আলাদা পাতা বানিয়ে দেব)

### ১.২ EPS থেকে যা নিতে হবে (এগুলোই Integrations-এ পেস্ট করবেন)

| EPS থেকে | Integrations → "EPS payment gateway"-এর ঘর |
|---|---|
| Merchant ID | `merchant_id` |
| Store ID | `store_id` |
| API Username (সাধারণত ইমেইল) | `username` |
| API Password | `password` |
| Hash Key | `hash_key` |
| IPN Key / Secret Key (EPS দিলে) | `ipn_key` |
| প্রথমে স্যান্ডবক্স, পরে লাইভ | `mode` = `sandbox` অথবা `live` |

প্রথমে **স্যান্ডবক্স অ্যাকাউন্টের** কী দিন, পরীক্ষা শেষ হলে লাইভ কী দিয়ে `mode` = `live` লিখুন।

### ১.৩ EPS-কে যে URL গুলো দিতে হবে (রেজিস্টার করাতে)

| কাজ | URL |
|---|---|
| Success URL | `https://lifeassisto.com/pay/return?r=success` |
| Fail URL | `https://lifeassisto.com/pay/return?r=fail` |
| Cancel URL | `https://lifeassisto.com/pay/return?r=cancel` |
| IPN (সার্ভার-টু-সার্ভার নোটিফিকেশন) | `https://api.lifeassisto.com/api/v1/payments/gateway/ipn` |

(এই URL গুলো প্রতিটি পেমেন্টের সঙ্গেও পাঠানো হয়; Admin → Payments পেজেও লেখা থাকে।)

**IP allow-list:** EPS যদি জিজ্ঞেস করে আমাদের সার্ভারের IP — `16.4.105.173`। আর EPS-এর IPN
যে IP থেকে আসবে সেটা EPS-এর কাছে জেনে নিন (আমাদের দিকে IP ব্লক নেই; প্রতিটি পেমেন্ট আমরা EPS-এর
স্ট্যাটাস API-তে আবার যাচাই করি, তাই ভুয়া IPN দিয়ে কিছু চালু হয় না)।

### ১.৪ EPS-কে যে প্রশ্নগুলো লিখিতভাবে জিজ্ঞেস করবেন (আমরা অনুমান করে রেখেছি)

EPS-এর পূর্ণ API ডকুমেন্টেশন প্রকাশ্যে নেই; আমরা বানিয়েছি EPS-এর **অফিসিয়াল** GitHub নমুনা
(github.com/EPS-PG: EPS_PHP, EPS_Laravel, EPS_Woocommerce) আর https://eps.com.bd/ipn দেখে, এবং
EPS-এর প্রকাশ্য স্যান্ডবক্সে আসল উত্তরের ধরন মিলিয়ে। এই দুটো বিষয় EPS নিশ্চিত করুক:

1. **IPN এনক্রিপশন কী:** IPN-এর `Data` ("IV:cipher", AES-256-CBC) খুলতে কোন কী লাগে, কীভাবে
   ৩২ বাইট বানাতে হয়? (এখন: `ipn_key` Base64 হলে সেটাই, নাহলে তার SHA-256।) ভুল হলেও টাকা হারাবে
   না — ব্রাউজার রিটার্ন ও প্রতি ঘণ্টার স্যুইপ নিজে স্ট্যাটাস API দিয়ে যাচাই করে।
2. **স্ট্যাটাস শব্দগুলো:** `Success`, `Failed`, `Cancel`, `Pending` ছাড়া আর কী আসে?

### ১.৫ রিফান্ড (EPS)

টাকা ফেরত দিন **EPS মার্চেন্ট প্যানেল থেকে**। তারপর Admin → Payments → অর্ডারের পাশে
"রিফান্ড হিসেবে চিহ্নিত করুন" (কারণ লিখে)। প্ল্যান/ক্রেডিট ফেরত নেওয়া হবে, আয় থেকে বাদ যাবে, অডিটে থাকবে।

---

## ধাপ ২ — Google Play (Play Console)

### ২.১ প্রোডাক্ট তৈরি (Play Console → Monetize with Play → Products)

**Subscriptions** — এই ID গুলো হুবহু:

| Subscription ID | Base plan ID | মেয়াদ | দাম (এখনকার মূল দাম) |
|---|---|---|---|
| `assisto_premium` | `monthly` | ১ মাস, auto-renew | ৳১৯৯ |
| `assisto_premium` | `yearly` | ১ বছর, auto-renew | ৳১৯১০ |
| `assisto_business` | `monthly` | ১ মাস, auto-renew | ৳৪৯৯ |
| `assisto_business` | `yearly` | ১ বছর, auto-renew | ৳৪৭৯০ |

প্রতিটি base plan-এ **Grace period** (যেমন ৭ দিন) ও **Account hold** চালু রাখুন — আমাদের সার্ভার
দুটোই ঠিকভাবে সামলায় (grace-এ Premium থাকে, hold-এ বন্ধ হয়, পেমেন্ট ঠিক হলে আবার চালু)।

**In-app products (একবারের, consumable)**:

| Product ID | ক্রেডিট | দাম |
|---|---|---|
| `credits_p20` | ২০ | ৳২০ |
| `credits_p50` | ৫৫ | ৳৫০ |
| `credits_p100` | ১১৫ | ৳১০০ |
| `credits_p200` | ২৪০ | ৳২০০ |

দাম Admin → Pricing / Payments-এর দামের সঙ্গে **একই** রাখুন — Google যা Play Console-এ লেখা থাকে
সেটাই কাটে। (ID বদলাতে চাইলে Admin → /admin/pricing-এর `payments.play_products` বদলানো যায়।)

### ২.২ License testers (টাকা ছাড়া পরীক্ষা)

Play Console → Settings → **License testing** → আপনার ও টেস্টারদের Gmail যোগ করুন। এদের কেনা
"টেস্ট পেমেন্ট" — আসল টাকা কাটে না; আমাদের লাভ-ক্ষতিতেও আয় হিসেবে ধরা হয় না (অডিটে
`play.test_charge`)। টেস্ট সাবস্ক্রিপশন কয়েক মিনিটে নবায়ন হয়, তাই renew/expire দ্রুত দেখা যায়।

### ২.৩ সার্ভিস অ্যাকাউন্ট + Play Developer API

1. Google Cloud Console → প্রজেক্ট বেছে নিন → **Google Play Android Developer API** Enable।
2. IAM → Service accounts → নতুন (যেমন `play-api`) → Keys → **JSON** কী ডাউনলোড।
3. Play Console → **Users and permissions** → Invite → সেই সার্ভিস-অ্যাকাউন্ট ইমেইল →
   অনুমতি: **View financial data** ও **Manage orders and subscriptions** → Assisto অ্যাপ।
4. Admin → Integrations → **Google Play Billing**: JSON পুরোটা `service_account_json`-এ পেস্ট,
   `package_name` = `com.assisto.assisto` → Save → **Test** (সত্যিকারের Google টোকেন নেওয়া হয়)।

JSON কখনো চ্যাট/গিটে দেবেন না — শুধু Integrations-এ (এনক্রিপ্ট হয়ে থাকে)।

### ২.৪ RTDN (Real-time developer notifications) — নবায়ন, বাতিল, রিফান্ড সঙ্গে সঙ্গে

1. Google Cloud → **Pub/Sub** → Topic তৈরি, যেমন `play-rtdn`।
2. Topic-এর Permissions → `google-play-developer-notifications@system.gserviceaccount.com`-কে
   **Pub/Sub Publisher** দিন।
3. Play Console → Monetization setup → **Real-time developer notifications** → Topic name:
   `projects/<আপনার-প্রজেক্ট>/topics/play-rtdn` → "Send test notification" (আমাদের সার্ভার `test` লিখে রাখবে)।
4. সেই Topic-এ **Push subscription**:
   - Endpoint URL: `https://api.lifeassisto.com/api/v1/payments/play/rtdn`
   - **Enable authentication** চালু → একটি সার্ভিস অ্যাকাউন্ট বেছে নিন (যেমন `rtdn-push@...`)
   - Audience: `https://api.lifeassisto.com/api/v1/payments/play/rtdn`
5. Integrations → Google Play Billing → `rtdn_audience` = উপরের Audience, `rtdn_sa_email` = push
   সার্ভিস-অ্যাকাউন্টের ইমেইল → Save।
   (বিকল্প/অতিরিক্ত: `rtdn_token`-এ একটি লম্বা গোপন শব্দ দিন এবং Endpoint-এর শেষে `?token=<সেই শব্দ>` লিখুন।)

কিছুই সেট না থাকলে সার্ভার RTDN নেয় না (fail-closed) — তখনও অ্যাপ খুললে/কিনলে যাচাই হয়, শুধু
নবায়ন/বাতিলের খবর দেরিতে আসে।

---

## ধাপ ৩ — সুইচ ও দাম (Admin → Payments, https://lifeassisto.com/owner/payments)

- **Play বিল্ডে Google Play Billing** — চালু/বন্ধ।
- **গেটওয়ে (EPS)** — ওয়েবসাইট APK ও ওয়েবসাইটে চালু/বন্ধ।
- **Play বিল্ডের ভেতরেও গেটওয়ে দেখান** — Google সতর্ক করলে এক ক্লিকে বন্ধ (কমপ্লায়েন্স কিল-সুইচ)।
- **lifeassisto.com/premium** পেজ চালু/বন্ধ।
- সুইচ নতুন বিল্ড ছাড়াই কয়েক মিনিটে সব অ্যাপে পৌঁছায় এবং **সবার জন্য একই** — শুধু রিভিউয়ারের
  কাছ থেকে লুকানো হয় না, হবেও না।
- ফি: Play সাবস্ক্রিপশন ১৫% (০.১৫), Play প্যাক ১৫%, EPS ফি (আপনার চুক্তির MDR, যেমন ০.০২)।
- চ্যানেল-ভিত্তিক দাম: খালি রাখলে Pricing-এর মূল দাম (এখন সব জায়গায় একই দাম)।
- নিচে চ্যানেল অনুযায়ী মোট আয়, ফি, রিফান্ড ও **নেট আয়**; Profit Guard ও লাভ-ক্ষতি পেজ নেট আয়ই ধরে।

---

## নিয়মগুলো (আপগ্রেড, ডাউনগ্রেড, রিফান্ড, মেয়াদ)

- **একই প্ল্যান আবার কেনা (EPS, প্রিপেইড)**: আগের মেয়াদ শেষে নতুনটা যোগ হয় — কিছু হারায় না।
- **আপগ্রেড Premium → Business (EPS)**: Business সঙ্গে সঙ্গে চালু; Premium-এর বাকি দিনগুলো দামের
  অনুপাতে (১৯৯/৪৯৯) বাড়তি Business দিন হয়ে যোগ হয়।
- **ডাউনগ্রেড Business → Premium (EPS)**: Business শেষ হলে Premium শুরু।
- **Google Play**: আপগ্রেড/ডাউনগ্রেড/বাতিল Google নিজে সামলায় (Play Store → Subscriptions); আমাদের
  সার্ভার Google-এর তারিখ হুবহু মেনে চলে। Play সাবস্ক্রিপশন চালু থাকলে একই প্ল্যান EPS দিয়ে আবার কেনা
  যায় না (দুবার টাকা কাটা বন্ধ)। প্রিপেইড EPS প্ল্যান চলাকালীন একই প্ল্যানের Play সাবস্ক্রিপশনও আটকানো।
- **Founding Member / রেফারেল দিন**: পেমেন্ট এগুলো মুছে দেয় না; Business শেষ হলে বাকি ফ্রি Premium আবার চলে।
- **রিফান্ড / Google revoke**: প্ল্যান সঙ্গে সঙ্গে বন্ধ, না-খরচ হওয়া ক্রেডিট ফেরত নেওয়া হয় (শূন্যের নিচে নয়), আয় থেকে বাদ।
- **মেয়াদ শেষ**: প্রতি ঘণ্টার স্যুইপ Free-তে নামিয়ে দেয় (বা পরের চালু প্ল্যানে)।
- **রিমাইন্ডার**: প্রিপেইড প্ল্যান শেষ হওয়ার ৭, ৩ ও ১ দিন আগে পুশ, আর SMS গেটওয়ে চালু থাকলে SMS — সঙ্গে
  এক-ট্যাপ নবায়নের লিংক (`/premium?renew=...`); অ্যাপের প্ল্যান পেজে "এক ট্যাপে নবায়ন" বোতাম।
- একই পেমেন্ট কখনো দুবার গোনা হয় না (EPS ট্রানজেকশন ID ও Play purchase token ইউনিক)।

---

## Google Play নীতির ঝুঁকি — মালিকের জেনেশুনে নেওয়া সিদ্ধান্ত

Google Play-র নিয়ম অনুযায়ী Play থেকে নামানো অ্যাপের ভেতরে ডিজিটাল জিনিস (Premium, ক্রেডিট)
বিক্রি করতে হলে সাধারণত **শুধু Google Play Billing** ব্যবহার করতে হয়; অ্যাপের ভেতরে অন্য
পেমেন্ট (বিকাশ/নগদ/কার্ড) দেখালে Google অ্যাপ রিজেক্ট, আপডেট আটকানো বা সতর্কবার্তা দিতে পারে।
মালিক এই ঝুঁকি জেনে Play বিল্ডেও EPS রাখার সিদ্ধান্ত নিয়েছেন। Google সতর্ক করলে **Admin → Payments →
"Play বিল্ডের ভেতরেও গেটওয়ে দেখান" বন্ধ করুন** — নতুন বিল্ড ছাড়াই সবার কাছে সঙ্গে সঙ্গে বন্ধ হবে;
ওয়েবসাইট ও ওয়েবসাইট APK-তে EPS চালু থাকবে। আমরা কখনো শুধু রিভিউয়ের সময় অপশন লুকাই না।

---

## পরীক্ষা (স্যান্ডবক্স রানবুক) — দুই চ্যানেলেই: কেনা → Premium চালু → নবায়ন → মেয়াদ শেষ/বাতিল

### EPS স্যান্ডবক্স
1. Integrations → EPS: স্যান্ডবক্স কী, `mode` = `sandbox` → Save → Test (✓ token OK)।
2. ওয়েবসাইট APK (বা https://lifeassisto.com/premium) → Plans → Premium → "বিকাশ / নগদ / কার্ড — EPS"।
3. EPS স্যান্ডবক্স পেজে টেস্ট পেমেন্ট → অ্যাপে ফিরে "পেমেন্ট করেছি — যাচাই করুন" → **Premium চালু**।
   Admin → Payments-এ অর্ডার `paid`, অডিটে `order.paid` ও `entitlement.grant`।
4. **নবায়ন**: আবার Premium কিনুন → মেয়াদ এক মাস বাড়বে (Plans পেজে তারিখ দেখুন)।
5. **বাতিল/রিফান্ড**: Admin → Payments → "রিফান্ড হিসেবে চিহ্নিত করুন" → অ্যাপে Free।
6. **মেয়াদ শেষ**: টেস্ট অ্যাকাউন্টে কেনার পর Admin-এর প্ল্যান তারিখ পেছনে দিয়ে স্যুইপ চালান
   (`python manage.py payments_sweep`) → Free।
7. ভুল টাকা/ভুয়া রিটার্ন: ব্রাউজারে `/pay/return?Status=Success&MerchantTransactionId=<অন্য>` খুললেও কিছু চালু হয় না।

### Google Play (license tester)
1. Integrations → Google Play Billing ভরা ও Test ✓; RTDN সেট (ধাপ ২.৪), "Send test notification"।
2. Play-র **internal testing** ট্র্যাকে AAB আপলোড, tester Gmail দিয়ে ফোনে ইনস্টল।
3. Plans → Premium → "Google Play" → টেস্ট কার্ড → **Premium চালু** (Admin অডিটে `play.test_charge`)।
4. **নবায়ন**: টেস্ট সাবস্ক্রিপশন ৫ মিনিটে নবায়ন হয় → RTDN `RENEWED` → মেয়াদ বাড়ে।
5. **বাতিল**: Play Store → Subscriptions → Cancel → RTDN `CANCELED` → মেয়াদ শেষ পর্যন্ত Premium, তারপর `EXPIRED` → Free।
6. **রিফান্ড**: Play Console → Order management → Refund (revoke) → RTDN `REVOKED` → সঙ্গে সঙ্গে Free।
7. ক্রেডিট প্যাক কিনুন → ক্রেডিট যোগ, আবার কেনা যায় (সার্ভার consume করে)।

ফলাফল (তারিখ, স্ক্রিনশট) `STATUS_FOR_OWNER.md`-এ লিখে রাখবেন।
