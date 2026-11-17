# Play Console — সাবস্ক্রিপশন, ক্রেডিট প্যাক, ট্রায়াল আর স্টোর লিস্টিং (১৭ Nov ২০২৬)

**এটা আপনার কাজ, আমরা Play Console-এ কিছু বানাই না।** নিচের প্রতিটি ID কোড থেকে মিলিয়ে লেখা — **হুবহু** লিখবেন (ছোট হাতের অক্ষর, `_` আর `-` যেমন আছে)। একটি অক্ষর ভুল হলে অ্যাপ সেটা খুঁজে পাবে না এবং সৎভাবে "এখন পাওয়া যাচ্ছে না" দেখাবে — কারো টাকা কাটবে না।

**কেন নিরাপদ:** অ্যাপে কোনো product ID লেখা নেই — সব সার্ভার থেকে আসে। নতুন প্রতিটি পণ্য সার্ভার ততক্ষণ বিক্রি করে না, যতক্ষণ না Google-এর API বলে সেটা Play-তে **Active** (`core/payments/play_verify.py`)।
**বানানোর পরে যাচাই:** https://api.lifeassisto.com/owner/payments → "Play SKU check" → **Re-check** চাপুন → প্রতিটি সারি সবুজ (ok) হওয়া উচিত। লাল সারিতে কারণ লেখা থাকে (যেমন `NO_BASE_PLAN`)।

**দাম কোথা থেকে:** প্ল্যানের দাম Owner Admin → Pricing-এ যা আছে, Play-তে ঠিক সেটাই বসাবেন (দাম VAT-সহ)। নিচের টেবিলে আপনার ৯ Nov-এর অনুমোদিত দাম (প্ল্যান v2) দেওয়া আছে। প্ল্যান v2 সুইচ (`plans_v2` / `pricing_v2`) এখনো বন্ধ — Play-তে দাম বসানোর পরে চালু হবে। Owner Admin-এর দাম আলাদা হলে সেটাই মানবেন, আর আমাদের জানাবেন।

---

## ক. সাবস্ক্রিপশন বানানোর সাধারণ ধাপ (প্রতিটি পণ্যে একই)

1. play.google.com/console → **Assisto** → বাঁ দিকে **Monetize with Play → Products → Subscriptions** → **Create subscription**।
2. **Product ID** = নিচের টেবিলের ID (পরে বদলানো যায় না) → **Name** = টেবিলের নাম → **Create**।
3. **Add base plan** → **Base plan ID** = টেবিলের ID → **Auto-renewing** → **Billing period** = 1 month বা 1 year → **Grace period** 7 days, **Account hold** 30 days (ডিফল্ট রাখুন)।
4. **Set prices** → **Bangladesh (BDT)**-এ টেবিলের দাম লিখুন → বাকি দেশ Google-এর রূপান্তর মেনে নিন (প্রবাসী প্ল্যান বাদে, নিচে দেখুন) → **Update**।
5. **Save** → **Activate**। প্রতিটি base plan আলাদা করে Activate করতে হয়।
6. Subscription-এর **Benefits** ঘরে ২–৩টি ছোট লাইন লিখুন (কী পাবেন)। এগুলো Google-এর পেমেন্ট শিটে দেখায়।

## খ. সাবস্ক্রিপশনের তালিকা

### ১) মূল প্ল্যান (`backend/core/logic/payments_cfg.py`)
বার্ষিক = মাসিক × ১২ × ০.৮ (২০% ছাড়, `annual_discount_pct`)।

| Product ID | নাম | Base plan ID | মেয়াদ | দাম (৳, অনুমোদিত) |
|---|---|---|---|---|
| `assisto_plus` | Assisto Plus | `monthly` / `annual` | 1 month / 1 year | ১৯৯ / ১,৯১০ |
| `assisto_premium` | Assisto Premium | `monthly` / `annual` | 1 month / 1 year | ৪৪৯ / ৪,৩১০ |
| `assisto_premium_pro` | Assisto Premium Pro | `monthly` / `annual` | 1 month / 1 year | ৯৯৯ / ৯,৫৯০ |
| `assisto_business` | Assisto Business | `monthly` / `annual` | 1 month / 1 year | ১,২৯৯ / ১২,৪৭০ |

⚠️ বার্ষিক base plan-এর ID **`annual`** — `yearly` নয় (পুরোনো `PLAY_PRODUCTS_SETUP_BN.md`-এ ভুল ছিল, নিচে "অমিল" দেখুন)।

### ২) প্রবাসী পরিবার প্ল্যান — শুধু Play
| Product ID | Base plan ID | দাম |
|---|---|---|
| `assisto_probashi` | `monthly` | **USD ৪.৯৯** — "Set prices"-এ USD দিয়ে শুরু করুন, Google প্রতিটি দেশের দাম বানাবে |
| `assisto_probashi` | `annual` | **USD ৪৯.৯০** (= ১০ মাসের দাম, `catalog.py`) |

### ৩) সিসিটিভি প্ল্যান (`backend/core/logic/cctv_plan.py`)
একটি পণ্য, ক্যামেরার সংখ্যা অনুযায়ী আলাদা base plan। ১টি ক্যামেরা = ২-ক্যামেরার দাম। বার্ষিক = ঠিক ১২ × মাসিক।

| Product ID | Base plan ID | মাসিক ৳ | Base plan ID | বার্ষিক ৳ |
|---|---|---|---|---|
| `cctv_plan` | `c02-monthly` | ৫০০ | `c02-yearly` | ৬,০০০ |
| | `c03-monthly` | ৭৫০ | `c03-yearly` | ৯,০০০ |
| | `c04-monthly` | ১,০০০ | `c04-yearly` | ১২,০০০ |
| | `c05-monthly` | ১,২৫০ | `c05-yearly` | ১৫,০০০ |
| | `c06-monthly` | ১,৫০০ | `c06-yearly` | ১৮,০০০ |
| | `c07-monthly` | ১,৭৫০ | `c07-yearly` | ২১,০০০ |
| | `c08-monthly` | ২,০০০ | `c08-yearly` | ২৪,০০০ |
| | `c09-monthly` | ২,২৫০ | `c09-yearly` | ২৭,০০০ |
| | `c10-monthly` | ২,৫০০ | `c10-yearly` | ৩০,০০০ |

মোট ১৮টি base plan, সব Activate। ১০টির বেশি ক্যামেরা অ্যাপে বিক্রি হয় না ("যোগাযোগ করুন")।

### ৪) সিসিটিভি ভিডিও অ্যাড-অন
| Product ID | Base plan ID | মেয়াদ | দাম ৳ |
|---|---|---|---|
| `cctv_video` | `d7-c01` … `d7-c10` | 1 month | ১০০ × ক্যামেরা (১০০, ২০০ … ১,০০০) |
| `cctv_video` | `d30-c01` … `d30-c10` | 1 month | ১৫০ × ক্যামেরা (১৫০, ৩০০ … ১,৫০০) |

`d7` = ৭ দিনের ক্লিপ, `d30` = ৩০ দিনের ক্লিপ; `c03` = ৩টি ক্যামেরা। মোট ২০টি base plan।

### ৫) সিসিটিভি Premium AI (আপনার ১৭ Nov ১২:৩৫-এর সিদ্ধান্ত)
| Product ID | Base plan ID | মেয়াদ | দাম ৳ |
|---|---|---|---|
| `cctv_premium_ai` | `ai-c01` … `ai-c10` | 1 month | ৪০০ × ক্যামেরা (৪০০, ৮০০ … ৪,০০০) |

মূল সিসিটিভি প্ল্যানের **উপরে** আলাদা পণ্য। ⚠️ এই কোড এখনো শাখা `agent/cctvprice2`-এ, main-এ মেশেনি — মেশার পরে বানাবেন; তার আগে বানালে ক্ষতি নেই, শুধু বিক্রি শুরু হবে না (`premium_ai_on_sale` বন্ধ)।

### ৬) নিরাপত্তা প্ল্যান (`backend/core/logic/safe_plans.py`; SOS সবসময় ফ্রি)
| Product ID | Base plan ID | মেয়াদ | দাম ৳ |
|---|---|---|---|
| `safe_child` | `monthly` | 1 month | ৩০ |
| `safe_family` | `monthly` | 1 month | ৯৯ |

---

## গ. ৭ দিনের ফ্রি ট্রায়াল (শুধু সিসিটিভি)

1. **Subscriptions → `cctv_plan` → base plan `c02-monthly`** খুলুন (এটা Active থাকতে হবে)।
2. **Add offer** → **Offer ID:** `trial-7d` (হুবহু)।
3. **Eligibility:** **New customer acquisition → Never had this subscription** (মানে: একটি গুগল অ্যাকাউন্ট `cctv_plan` কখনো না নিয়ে থাকলে তবেই)।
4. **Phases → Add phase → Free trial → 7 days**। Tags লাগবে না; "Developer determined" বেছে নেবেন না।
5. **Save → Activate**।

**নিয়ম কে আটকায়:**
- Google: একটি গুগল অ্যাকাউন্টে একবার।
- আমাদের সার্ভার (`core/trial_guard.py`): একটি দোকানে একবার, একজন মানুষে একবার (একই ফোন নম্বর/ইমেইল/ফোন সেটে আবার নয়)।
- **EZVIZ ক্যামেরা ট্রায়ালের বাইরে** (আপনার ১৭ Nov সিদ্ধান্ত) — এটা Play-তে নয়, সার্ভারে আটকানো: EZVIZ মালিককে অ্যাপ ট্রায়াল বোতাম দেখায় না, ট্রায়ালের মধ্যে EZVIZ ক্যামেরা যোগ করা যায় না। Play-তে আলাদা কিছু করতে হবে না। (এই কোডও শাখা `agent/cctvprice2`-এ, মেশার অপেক্ষায়।)
- প্রিমিয়াম/বিজনেসের ৭ দিনের ট্রায়াল Play-তে **নয়** — সার্ভার নিজে দেয়, কার্ড লাগে না, শেষে টাকা কাটে না। Play-তে কোনো offer বানাবেন না।

---

## ঘ. ক্রেডিট প্যাক ও অন্যান্য এককালীন পণ্য

1. **Monetize with Play → Products → One-time products** (পুরোনো নাম "In-app products") → **Create product**।
2. **Product ID** = নিচের ID → নাম ও ছোট বিবরণ → **Purchase option**: "Buy", **Consumable** (বারবার কেনা যায়) → BDT দাম → **Save → Activate**।

| Product ID | কী পায় | দাম ৳ |
|---|---|---|
| `credits_c15` | ১৫ ক্রেডিট (আপনার বিশেষ অনুমোদন: ৪৯ টাকা = ১৫) | ৪৯ |
| `credits_c50` | ৬০ ক্রেডিট | ১৭৯ |
| `credits_c120` | ১৪০ ক্রেডিট | ৩৯৯ |
| `credits_c300` | ৩৩০ ক্রেডিট | ৯৪৯ |
| `assisto_sms_100` | ব্যবসার ১০০ SMS (তাগাদা) | ১৪৯ |
| `assisto_sms_300` | ৩০০ SMS | ৪৪৯ |
| `assisto_sms_1000` | ১,০০০ SMS | ১,৪৬৯ |
| `safe_req_10` | ১০টি লোকেশন অনুরোধ (৩০ দিন) | ১০ |
| `safe_req_30` | ৩০টি লোকেশন অনুরোধ | ৩০ |
| `safe_req_100` | ১০০টি লোকেশন অনুরোধ | ১০০ |

ক্রেডিট প্যাকের মেয়াদ ১২ মাস (সার্ভার গোনে)। পুরোনো `credits_p20`/`p50`/`p100`/`p200` আগে থেকে থাকলে মুছবেন না — শুধু **Deactivate** করবেন প্ল্যান v2 চালু করার দিন (পুরোনো কেনা মিলাতে ID থাকা দরকার)।
SMS প্যাকের দাম ধরা হয়েছে প্রতি SMS ৳০.৩৫ খরচ ধরে (৪০% লাভের নিয়ম, `tagada_route.py`)। আসল খরচ আলাদা হলে দাম আমরা আবার হিসাব করব।

---

## ঙ. স্টোর লিস্টিং (ASO) — `SEO_PLAN_BN.md` §৪ থেকে

**Grow users → Store presence → Main store listing** (বাংলার জন্য: **Manage translations → বাংলা**)। একবারে একটি জিনিস বদলান, ২–৪ সপ্তাহ ফল দেখুন।

| ঘর | English | বাংলা |
|---|---|---|
| App name (≤৩০) | `Assisto: AI, SOS, CCTV & Khata` | `Assisto: AI সহকারী, SOS ও খাতা` |
| Short description (≤৮০) | `Family SOS, safe journey, CCTV app, khata & AI assistant in Bangla` | `পরিবারের SOS, নিরাপদ যাত্রা, মোবাইলে CCTV, দোকানের খাতা আর বাংলা AI সহকারী` |

- ছোট বিবরণের বিকল্প: আপনার ৩ Nov-এর হিরো লাইন ("চ্যাট, কল, AI সহকারী, নিরাপত্তা আর ব্যবসা — এক সুপার অ্যাপে") রাখতে চাইলে সেটাই থাকুক — ওয়েবসাইটের সাথে মেলে।
- **Full description (≤৪০০০):** `PLAY_LISTING_8NOV_ALL_BN.md`-এর যাচাই করা লেখা রাখুন; প্রথম ২ লাইনে "family safety, SOS, CCTV mobile app, khata" (বাংলায়: পরিবারের নিরাপত্তা, মোবাইলে সিসিটিভি, বাকি খাতা, মেসের হিসাব)। অংশের শিরোনামে: MESS & BACHELOR, CITY (Dhaka bus & metro)। শেষে `https://lifeassisto.com`। যা বন্ধ আছে (কুরআনের বাংলা অনুবাদ, IELTS মক, সর্বক্ষণ ট্র্যাকার) সেই শব্দ লিখবেন না। একই শব্দ ১–২ বারের বেশি নয়।
- **Screenshots (৮টি, ফোন):** ১) হোম/AI চ্যাট ২) পরিবারের SOS ৩) নিরাপদ যাত্রা ৪) সিসিটিভি সতর্কতা ৫) বাকি খাতা ৬) মেসের হিসাব ৭) ভাষা ৮) কুরআন — শেষ দুটি শুধু ওই সুইচ চালু হলে, না হলে শহর (বাস ও মেট্রো) আর ব্যবসার ইনভয়েস। প্রতিটির উপরে ৪–৬ শব্দের ক্যাপশন। নকল রিভিউ, "#১", তারকা, ব্যবহারকারী-সংখ্যা নয়। আমরা CI গ্যালারি থেকে আসল শট দেব।
- **Feature graphic (১০২৪×৫০০):** সায়ান → নীল → বেগুনি; বাঁয়ে "Assisto" + "অনেক অ্যাপ নয়, একটাই Assisto"; ডানে একটি আসল স্ক্রিনশট; ছোট লেখা নয়।
- পরে মাপুন: **Statistics → Store listing acquisition**; চাইলে **Store listing experiments** দিয়ে A/B।

---

## চ. কোডের সাথে মিলিয়ে দেখা — অমিলের তালিকা

| # | কোথায় | কী অমিল | কী করবেন |
|---|---|---|---|
| ১ | পুরোনো `PLAY_PRODUCTS_SETUP_BN.md` | বার্ষিক base plan `yearly` লেখা; কোড চায় **`annual`** (`payments_cfg.py`) | Play-তে আগেই `yearly` বানালে: নতুন base plan `annual` বানান (base plan ID বদলানো যায় না), অথবা আমাদের বলুন — Owner Admin → Payments-এর `play_products`-এ `yearly` বসিয়ে দেব। পুরোনো ডকটি এই ডক দিয়ে বাতিল। |
| ২ | পুরোনো ডকের দাম | প্রিমিয়াম ১৯৯ / বিজনেস ৪৯৯ (কোডের পুরোনো ডিফল্ট) বনাম অনুমোদিত ৪৪৯ / ১,২৯৯ (প্ল্যান v2) | Owner Admin → Pricing-এর দামই Play-তে; প্ল্যান v2 চালুর দিন দুই জায়গায় একসাথে বদলান। |
| ৩ | পুরোনো ডকের প্যাক | `credits_p20…p200` — এখন নতুন প্যাক `credits_c15/c50/c120/c300` | উপরের §ঘ মানুন। |
| ৪ | `credits_c50` / `c120` / `c300` | ID-র সংখ্যা ≠ ক্রেডিট (c50 দেয় ৬০, c120 দেয় ১৪০, c300 দেয় ৩৩০) | ভুল নয় — ID শুধু নাম; ক্রেডিট সার্ভার ঠিক করে। Play-র নামে আসল সংখ্যা লিখুন ("60 credits")। |
| ৫ | `cctv_premium_ai` + EZVIZ ট্রায়াল বাদ | কোড শুধু শাখা `agent/cctvprice2`-এ (কমিট 9e051677), main-এ নেই | মেশার পর পর্যন্ত বিক্রি বন্ধ থাকে; Play-তে আগে বানালে ক্ষতি নেই। |
| ৬ | `PLAY_TRIAL_OFFER_BN.md` | EZVIZ নিয়ে "সিদ্ধান্ত বাকি" লেখা — আপনি ১৭ Nov বাদ দেওয়ার সিদ্ধান্ত দিয়েছেন | এই ডকের §গ মানুন। |
| ৭ | `safe_req_10` (৳১০) | Play-তে বাংলাদেশের সর্বনিম্ন দামের চেয়ে কম হতে পারে | Play দাম না নিলে আমাদের জানান — প্যাক বদলাব। |

অ্যাপে (`app/lib`) কোনো product ID হাতে লেখা নেই — সব সার্ভার থেকে আসে, তাই অ্যাপ আর সার্ভারের মধ্যে অমিল নেই।
