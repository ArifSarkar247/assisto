# Google Play-তে কী কী বানাতে হবে — হুবহু তালিকা (পেমেন্ট E2E অডিট, ২৬ অক্টোবর)

এই তালিকা কোড পড়ে বানানো (`backend/core/logic/payments_cfg.py`, `core/payments/catalog.py`,
`core/payments/play.py`, `app/lib/payments/play_billing_impl.dart`)। ID-গুলো **হুবহু** লিখবেন —
একটা অক্ষর আলাদা হলে অ্যাপ "product not found" দেখাবে। কোনো চাবি/পাসওয়ার্ড এখানে নেই, শুধু নাম।

> দাম নিচে সার্ভারের **ডিফল্ট** দাম। কেনার আগে https://lifeassisto.com/owner/payments
> (Admin → Payments) খুলে যে দাম দেখায়, Play Console-এ **ঠিক সেই দাম** দিন। অ্যাপ সার্ভারের দাম
> দেখায়, কিন্তু Google কাটে Play Console-এর দাম — দুটো আলাদা হলে গ্রাহক বিভ্রান্ত হবে।

---

## ধাপ ১ — সাবস্ক্রিপশন (Play Console → Monetize with Play → Products → **Subscriptions**)

"Create subscription" চাপুন। দুটি সাবস্ক্রিপশন, প্রতিটিতে দুটি base plan:

| Product ID (Subscription ID) | নাম (যেকোনো) | Base plan ID | ধরন | মেয়াদ | দাম (BDT) |
|---|---|---|---|---|---|
| `assisto_premium` | Assisto Premium | `monthly` | Auto-renewing | 1 month | ৳১৯৯ |
| `assisto_premium` | Assisto Premium | `yearly` | Auto-renewing | 1 year | ৳২১৭৩ |
| `assisto_business` | Assisto Business | `monthly` | Auto-renewing | 1 month | ৳৪৯৯ |
| `assisto_business` | Assisto Business | `yearly` | Auto-renewing | 1 year | ৳৫৮০৮ |

প্রতিটি base plan-এ যা করবেন (Base plan → Edit):
1. **Renewal type**: Auto-renewing। **Billing period**: উপরের মেয়াদ।
2. **Price**: "Set prices" → Bangladesh (BDT) = উপরের দাম → বাকি দেশ Google-এর রূপান্তর মেনে নিন।
3. **Grace period**: monthly = **7 দিন**, yearly = **14 দিন**। (এই সময় প্ল্যান চালু থাকে; অ্যাপে
   হলুদ বার্তা + "পেমেন্ট ঠিক করুন" বোতাম দেখায়।)
4. **Account hold**: চালু (বাকি সময় Google-এর ডিফল্ট, মোট ৬০ দিনের মধ্যে)। hold-এ প্ল্যান বন্ধ থাকে,
   অ্যাপে "পেমেন্ট ঠিক করুন" দেখায়; পেমেন্ট ঠিক হলে নিজে থেকেই আবার চালু হয়।
5. **Resubscribe**: Allow (চালু)।
6. **Pause**: বন্ধ রাখুন (দরকার নেই; চালু করলেও সার্ভার সামলায় — বিরতিতে প্ল্যান বন্ধ থাকে)।
7. **Offers**: কোনো offer বানাবেন **না**। অ্যাপ শুধু base plan কেনে (offer থাকলেও তা উপেক্ষা করে)।
8. শেষে **Activate** চাপুন — base plan "Active" না হলে অ্যাপ সেটা কিনতে দেয় না (ভুল প্ল্যানে টাকা
   কাটা আটকাতে ইচ্ছে করেই)।

নোট: Plans পাতার "বার্ষিক" টগলে এখন Business-এরও বার্ষিক দাম ও কেনার বোতাম আসে (sku `business_yearly`)।
তাই `assisto_business` / `yearly` অবশ্যই বানিয়ে Active করুন — না থাকলে অ্যাপ সৎভাবে "এখন পাওয়া যাচ্ছে না" বলে।

## ধাপ ২ — ক্রেডিট প্যাক (Monetize with Play → Products → **In-app products**)

"Create product" → প্রতিটি **একবারের (one-time), consumable** — সার্ভার নিজেই consume করে, তাই
একই প্যাক বারবার কেনা যায়। (নতুন Console-এ "One-time products" → Purchase option "Buy"।)

| Product ID | নাম | ক্রেডিট | দাম (BDT) |
|---|---|---|---|
| `credits_p20` | 20 credits | ২০ | ৳২০ |
| `credits_p50` | 55 credits | ৫৫ | ৳৫০ |
| `credits_p100` | 115 credits | ১১৫ | ৳১০০ |
| `credits_p200` | 240 credits | ২৪০ | ৳২০০ |

প্রতিটি → Price সেট → **Activate**।
(নতুন প্যাক Admin → Pricing-এ যোগ করলে Product ID হবে `credits_<প্যাকের id>`।)

## ধাপ ৩ — License testers (টাকা ছাড়া পরীক্ষা)

1. Play Console (অ্যাকাউন্ট লেভেল) → **Settings → License testing** → আপনার ও টেস্টারদের Gmail যোগ → Save।
2. সেই Gmail-গুলো **Internal testing** ট্র্যাকের টেস্টার তালিকাতেও রাখুন; অ্যাপ Play থেকে (ইন্টারনাল
   লিংক দিয়ে) ইনস্টল করুন — sideload করা APK-তে Play Billing কাজ করে না।
3. টেস্টারের কেনা "Test card, always approves / declines / slow" বেছে পরীক্ষা করা যায়; এটা আয়
   হিসেবে গোনা হয় না (অডিটে `play.test_charge`)। টেস্ট সাবস্ক্রিপশন ৫ মিনিটে নবায়ন হয়।

## ধাপ ৪ — সার্ভিস অ্যাকাউন্ট (সার্ভার Google-এর কাছে প্রতিটি কেনা যাচাই করে)

1. Google Cloud Console → Play Console-এর সঙ্গে যুক্ত প্রজেক্ট → **APIs & Services → Enable APIs** →
   "Google Play Android Developer API" → Enable।
2. IAM & Admin → Service accounts → Create → নাম `play-billing` → Keys → Add key → **JSON** → ডাউনলোড।
   (আগের `play-uploader` অ্যাকাউন্ট ব্যবহার করবেন না — আলাদা রাখলে নিরাপদ।)
3. Play Console → **Users and permissions** → Invite new users → সেই সার্ভিস-অ্যাকাউন্টের ইমেইল →
   App permissions → Assisto → এই দুটি টিক:
   - **View financial data, orders, and cancellation survey responses**
   - **Manage orders and subscriptions**
   → Invite। (অন্য কোনো অনুমতি লাগবে না।)
4. https://lifeassisto.com/owner → Integrations → **Google Play Billing**:
   - `service_account_json` = JSON ফাইলের পুরো লেখা
   - `package_name` = `com.assisto.assisto`
   → Save → **Test**। JSON কখনো চ্যাট/গিট/ইমেইলে দেবেন না।
   (নতুন অনুমতি কার্যকর হতে Google-এর কয়েক ঘণ্টা লাগতে পারে।)

## ধাপ ৫ — RTDN (নবায়ন, বাতিল, grace, hold, রিফান্ড সঙ্গে সঙ্গে সার্ভারে আসে)

1. Google Cloud → **Pub/Sub → Topics → Create topic** → Topic ID: `play-rtdn`।
2. Topic → Permissions → Add principal: `google-play-developer-notifications@system.gserviceaccount.com`
   → Role: **Pub/Sub Publisher** → Save।
3. IAM → Service accounts → Create → `rtdn-push` (কোনো রোল লাগবে না)।
4. Topic `play-rtdn` → **Create subscription**:
   - Subscription ID: `play-rtdn-push`
   - Delivery type: **Push**
   - Endpoint URL: `https://api.lifeassisto.com/api/v1/payments/play/rtdn`
   - **Enable authentication**: চালু → Service account: `rtdn-push@<প্রজেক্ট>.iam.gserviceaccount.com`
   - Audience: `https://api.lifeassisto.com/api/v1/payments/play/rtdn`
   - Retry policy: Exponential backoff → Create।
   (পুরনো প্রজেক্ট হলে Google বলতে পারে Pub/Sub service agent-কে "Service Account Token Creator" দিতে — দিন।)
5. Play Console → অ্যাপ → **Monetize with Play → Monetization setup → Real-time developer
   notifications** → Topic name: `projects/<প্রজেক্ট-ID>/topics/play-rtdn` → Notification content:
   **Subscriptions, voided purchases, and all one-time products** → Save → **Send test notification**।
6. Integrations → Google Play Billing:
   - `rtdn_audience` = `https://api.lifeassisto.com/api/v1/payments/play/rtdn`
   - `rtdn_sa_email` = `rtdn-push@<প্রজেক্ট>.iam.gserviceaccount.com`
   - (ঐচ্ছিক, অতিরিক্ত সুরক্ষা) `rtdn_token` = একটি লম্বা গোপন শব্দ, আর উপরের ৪ নম্বরের Endpoint-এর শেষে
     `?token=<সেই শব্দ>` যোগ করুন।
   → Save। একটিও না থাকলে সার্ভার RTDN নেয় না (fail-closed)।

## ধাপ ৬ — Admin → Payments-এর সুইচ (https://lifeassisto.com/owner/payments)

| সুইচ (কোডে নাম) | কী করে | সুপারিশ |
|---|---|---|
| `play_enabled` | Play বিল্ডে Google Play দিয়ে কেনা | চালু |
| `gateway_enabled` | ওয়েবসাইট APK ও lifeassisto.com/premium-এ EPS | চালু (EPS কী আসার পর) |
| `gateway_on_play` | **Play বিল্ডের ভেতরেও** EPS দেখানো | **বন্ধ** — নিচের "নীতি" দেখুন |
| `web_enabled` | lifeassisto.com/premium ওয়েবসাইট চেকআউট | চালু |

## ধাপ ৭ — EPS (শুধু ওয়েবসাইট APK ও ওয়েবসাইটের জন্য) — Integrations → "EPS payment gateway"

ঘরের নাম (মান EPS দেবে): `merchant_id`, `store_id`, `username`, `password`, `hash_key`,
`ipn_key`, `mode` (`sandbox` → পরে `live`)।
EPS-কে দেবেন: Success `https://lifeassisto.com/pay/return?r=success`, Fail `…?r=fail`,
Cancel `…?r=cancel`, IPN `https://api.lifeassisto.com/api/v1/payments/gateway/ipn`, সার্ভার IP `16.4.105.173`।
বিস্তারিত: `owner_actions/PAYMENTS_SETUP.md` ধাপ ১।

## ধাপ ৮ — Play Console-এর ঘোষণা

- **App content → Data safety**: "Financial info → Purchase history" = Collected, ব্যবহার "App
  functionality" ও "Account management", শেয়ার হয় না, এনক্রিপ্টেড ট্রান্সফার = হ্যাঁ। (কার্ড/বিকাশ নম্বর
  আমরা দেখি না — সেটা Google/EPS-এর কাছে থাকে।)
- **Store listing**: "Contains in-app purchases" নিজে থেকেই দেখাবে।

## Google Play নীতি — মালিকের সিদ্ধান্ত (২৬ অক্টোবর)

Play থেকে নামানো অ্যাপে **সব ডিজিটাল জিনিস** (Premium, Business, ক্রেডিট প্যাক, ফিচার আনলক,
Seller Agent প্ল্যান) **শুধু Google Play Billing** দিয়ে বিক্রি হয়। EPS থাকে শুধু ওয়েবসাইট APK-তে,
lifeassisto.com/premium-এ, আর আসল জিনিস/সেবার (দোকানের অর্ডার, ডেলিভারি) জন্য।

- লাইভ সার্ভারে `gateway_on_play` = বন্ধ (মালিক করেছেন); কোডের ডিফল্টও এখন বন্ধ।
- অ্যাপের Play বিল্ড এই সুইচ চালু থাকলেও ডিজিটাল জিনিসের জন্য EPS **কখনো দেখায় না** (অ্যাপে কড়া নিয়ম + টেস্ট)।
- অ্যাপের কোথাও lifeassisto.com/premium বা /pay-এর লিংক নেই (টেস্ট দিয়ে পাহারা দেওয়া)।
- Seller Agent প্ল্যানের Play প্রোডাক্ট এখনও নেই, তাই Play বিল্ডে কেনার বোতাম লুকানো; সেখানে সৎ বার্তা:
  "অ্যাপের Google Play সংস্করণে সেলার এজেন্ট প্ল্যান বিক্রি হয় না। ফ্রি ট্রায়াল বা AI ক্রেডিট ব্যবহার করুন।"
  (বাইরের কোনো লিংক নেই।) পরে চাইলে `assisto_seller` সাবস্ক্রিপশন (base plan `starter`, `pro`) বানিয়ে
  Play দিয়ে বিক্রি চালু করা যাবে — তার জন্য আলাদা কোড-কাজ লাগবে, এখন **বানাবেন না**।

## ১০ মিনিটে পরীক্ষা (license tester Gmail দিয়ে, Play থেকে ইনস্টল করা অ্যাপে)

1. Plans → Premium (মাসিক) → Google Play → টেস্ট কার্ড → "Payment received" → Premium চালু।
2. Plans পাতায় "নবায়ন হবে …" + "সাবস্ক্রিপশন ম্যানেজ করুন" → Play-র সাবস্ক্রিপশন পাতা খোলে।
3. সেখানে Cancel → অ্যাপে "বাতিল — … পর্যন্ত চালু থাকবে" (প্ল্যান মেয়াদ শেষ পর্যন্ত থাকে)।
4. বার্ষিক টগল → Premium বার্ষিক → Play সঙ্গে সঙ্গে বদলে দেয় (মাসিকের বাকি সময় জমা হয়)।
5. Credits → ৫০ টাকার প্যাক → ৫৫ ক্রেডিট যোগ; আবার একই প্যাক কেনা যায়।
6. "Test card, declines" দিয়ে নবায়ন ব্যর্থ করুন → অ্যাপে হলুদ "পেমেন্ট ঠিক করুন" (grace)।
7. অ্যাপ মুছে আবার ইনস্টল → একই অ্যাকাউন্টে লগইন → Plans → "কেনাকাটা ফিরিয়ে আনুন" → Premium ফিরে আসে।
8. একই ফোনে অন্য Assisto অ্যাকাউন্টে লগইন → "কেনাকাটা ফিরিয়ে আনুন" → "এটি অন্য Assisto
   অ্যাকাউন্টের" — দ্বিতীয় অ্যাকাউন্টে কিছু চালু হয় না।
9. Play Console → Order management → একটি অর্ডার → Refund (প্ল্যানের ক্ষেত্রে "Revoke" টিকসহ) → কয়েক সেকেন্ডে অ্যাপে প্ল্যান/ক্রেডিট সরে যায়।
