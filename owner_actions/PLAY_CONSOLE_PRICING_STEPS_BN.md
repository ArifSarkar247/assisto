# Play Console — নতুন দাম ও নতুন পণ্য বসানোর ধাপ (ক্লিকের ক্রমে)

আপনার অনুমোদিত দাম (২৭ অক্টোবর রাত): Plus ৳১৯৯, Premium ৳৪৪৯, Premium Pro ৳৯৯৯, Business ৳১,২৯৯; প্যাক ৫০ = ৳১৭৯, ১২০ = ৳৩৯৯, ৩০০ = ৳৯৪৯; বার্ষিক = মাসিকের ১০ গুণ; প্রবাসী `PROBASHI_PLAN_BN.md` অনুযায়ী।

**আগে জেনে রাখুন (৩টি কথা):**
1. **ID হুবহু লিখবেন।** একটা অক্ষর ভুল হলে অ্যাপ পণ্যটা পাবে না। Product ID পরে বদলানো যায় না।
2. **নতুন পণ্য নিজে থেকে বিক্রি শুরু হয় না।** সার্ভার প্রতিদিন Google-কে জিজ্ঞেস করে পণ্যটা আছে ও **Active** কিনা; Active দেখলে তবেই অ্যাপে কেনার বোতাম আসে। Activate করার পর Owner Admin → **Payments** → “নতুন Play পণ্য — বিক্রির আগে যাচাই” → **Google Play-তে আবার যাচাই** চাপলে সঙ্গে সঙ্গে দেখে নেয়।
3. **পুরনো গ্রাহকেরা পুরনো দামেই থাকবেন** (নিচে ধাপ ২-এ “legacy price” বাছবেন)। অ্যাপ পুরনো গ্রাহককে তাঁর আসল দেওয়া দামই দেখায়।

Base plan ID কোডে যা আছে তাই: **`monthly`** আর **`annual`**। (`assisto_premium`-এ পুরনো একটা `yearly` base plan আছে — সেটা নিষ্ক্রিয় ও ভুল; **ছোঁবেন না**।)

---

## ধাপ ১ — খুলুন

1. play.google.com/console → **Assisto** অ্যাপ।
2. বাঁ দিকে **Monetize with Play → Products → Subscriptions**।

## ধাপ ২ — যে পুরনো পণ্যের দাম বদলাবে (২টি সাবস্ক্রিপশন, ৪টি base plan)

| Product ID | Base plan ID | পুরনো দাম | **নতুন দাম (Bangladesh)** |
|---|---|---|---|
| `assisto_premium` | `monthly` | ৳১৯৯ | **BDT 449** |
| `assisto_premium` | `annual` | (আগের বার্ষিক) | **BDT 4,490** |
| `assisto_business` | `monthly` | (আগের) | **BDT 1,299** |
| `assisto_business` | `annual` | (আগের) | **BDT 12,990** |

প্রতিটি সারির জন্য:
1. **`assisto_premium`** চাপুন → নিচে base plan তালিকায় **`monthly`** চাপুন।
2. **Prices** অংশে **Edit prices** (বা **Manage prices**) → **Bangladesh** খুঁজে **449** লিখুন।
3. অন্য দেশ: **Update other prices using exchange rate** বেছে নিন (প্রবাসীদের দাম আলাদা পণ্যে, ধাপ ৫)।
4. **Save** / **Update prices** চাপুন।
5. Google জিজ্ঞেস করবে **পুরনো গ্রাহকদের কী হবে** — বাছুন **“Keep existing subscribers at their current price”** (এটাকে Google “legacy price” বলে)। **“Move existing subscribers to the new price” বাছবেন না।**
   - মানে: যাঁরা আগে কিনেছেন তাঁরা পুরনো দামেই নবায়ন পাবেন; নতুন ক্রেতারা নতুন দাম দেবেন।
   - পরে কখনো পুরনোদের দাম বাড়াতে চাইলে Google তাঁদের আগে জানায়, অনেক দেশে তাঁদের রাজি হতে হয়; রাজি না হলে নবায়নের দিন সাবস্ক্রিপশন শেষ হয়। এখন এটা করবেন না।
6. একই ভাবে `annual` → **4490**; তারপর `assisto_business` → `monthly` **1299**, `annual` **12990**।

## ধাপ ৩ — নতুন সাবস্ক্রিপশন (২টি)

| Product ID | নাম | Base plan ID | মেয়াদ | দাম (Bangladesh) |
|---|---|---|---|---|
| `assisto_premium_pro` | Assisto Premium Pro | `monthly` | 1 month | **BDT 999** |
| `assisto_premium_pro` | Assisto Premium Pro | `annual` | 1 year | **BDT 9,990** |
| `assisto_plus` | Assisto Plus | `monthly` | 1 month | **BDT 199** |
| `assisto_plus` | Assisto Plus | `annual` | 1 year | **BDT 1,990** |

প্রতিটি সাবস্ক্রিপশনের জন্য:
1. **Create subscription** → Product ID: `assisto_premium_pro` → Name: `Assisto Premium Pro` → **Create**।
2. **Benefits** (ইংরেজিতে, সংখ্যা ছাড়া — পরে মেসেজ বাড়লে বদলাতে হবে না):
   - Premium Pro: `Our strongest AI on every chat` · `Agent tasks` · `Everything in Premium`
   - Plus: `Smart AI chat` · `10 free quick replies a day` · `No ads`
3. **Add base plan** → Base plan ID: `monthly` → **Auto-renewing** → Billing period **1 month** → Grace period **7 days** → Account hold **চালু** (Google-এর ডিফল্ট) → Resubscribe **Allow** → **Set prices** → Bangladesh **999** → অন্য দেশ exchange rate → **Save** → **Activate**।
4. আবার **Add base plan** → `annual` → Auto-renewing → **1 year** → Grace **14 days** → Account hold চালু → Resubscribe Allow → Bangladesh **9990** → Save → **Activate**।
5. **Offers:** কিছু বানাবেন না (ফ্রি ট্রায়াল বা ছাড় নয়)।
6. একই ভাবে `assisto_plus` (দাম 199 / 1990)।

## ধাপ ৪ — নতুন ক্রেডিট প্যাক (৩টি)

বাঁ দিকে **Monetize with Play → Products → In-app products** (নতুন Console-এ **One-time products**)।

| Product ID | নাম | দাম (Bangladesh) |
|---|---|---|
| `credits_c50` | 50 credits | **BDT 179** |
| `credits_c120` | 120 credits | **BDT 399** |
| `credits_c300` | 300 credits | **BDT 949** |

প্রতিটির জন্য: **Create product** → Product ID → Name → (One-time products হলে Purchase option: **Buy**, consumable) → **Set price** → Bangladesh দাম → অন্য দেশ exchange rate → **Save** → **Activate**।

পুরনো প্যাক `credits_p20`, `credits_p50`, `credits_p100`, `credits_p200`: **মুছবেন না**, শুধু **Deactivate** করুন (আগের কেনা ও রিফান্ড ঠিক থাকে)। — নতুন প্যাক Active হওয়ার পরে করবেন।

## ধাপ ৫ — প্রবাসী (দেশ + সাবস্ক্রিপশন `assisto_probashi`)

**ক) ১৩টি দেশে অ্যাপ পাওয়া:** **Test and release → Testing → Closed testing** → আপনার ট্র্যাক → **Countries / regions** → **Add countries / regions** → Saudi Arabia, United Arab Emirates, Qatar, Oman, Kuwait, Bahrain, Malaysia, Singapore, Italy, United Kingdom, United States, Canada, Australia → **Save** → **Publishing overview → Send changes for review**। তারপর **Test and release → Production → Countries / regions**-এ একই ১৩টি দেশ (এটা শুধু “কোথায় পাওয়া যাবে”; কোনো রিলিজ বদলায় না)। **Managed publishing চালু রাখুন।**

**খ) সাবস্ক্রিপশন:** **Subscriptions → Create subscription** → Product ID **`assisto_probashi`** → Name **Assisto Probashi Family** → Benefits: `Premium for you, no ads` · `Premium for up to 4 family members in Bangladesh` · `180 shared AI credits a month (annual: 1,800 a year), you set each member's limit` · `Monthly family report`।
- **Add base plan** `monthly` → Auto-renewing, 1 month, Grace 7 days, Account hold 30 days, Resubscribe Allow → **Set prices** → **Manage country / region availability** → শুধু নিচের ১৩টি দেশ টিক দিন → প্রতিটি দেশে নিচের **মাসিক** দাম **নিজে** লিখুন (Google-এর রূপান্তর নেবেন না) → Save → **Activate**।
- **Add base plan** `annual` → 1 year, Grace 7 days, Account hold 30 days → নিচের **বার্ষিক** দাম → Save → **Activate**।
- কোনো offer নয়। পরীক্ষার জন্য Bangladesh-এ একটা দাম (যেমন ৳১,১৯৯) দিতে পারেন — লঞ্চের আগে সরিয়ে দেবেন।

| দেশ | মাসিক (`monthly`) | বার্ষিক (`annual`) |
|---|---|---|
| Saudi Arabia | SAR 37.99 | SAR 379.99 |
| United Arab Emirates | AED 36.99 | AED 369.99 |
| Qatar | QAR 36.99 | QAR 369.99 |
| Oman | OMR 3.900 | OMR 39.000 |
| Kuwait | KWD 2.990 | KWD 29.900 |
| Bahrain | BHD 3.790 | BHD 37.900 |
| Malaysia | MYR 42.90 | MYR 429.00 |
| Singapore | SGD 12.98 | SGD 129.80 |
| Italy | EUR 9.99 | EUR 99.99 |
| United Kingdom | GBP 7.99 | GBP 79.99 |
| United States | USD 9.99 | USD 99.99 |
| Canada | CAD 13.99 | CAD 139.99 |
| Australia | AUD 15.99 | AUD 159.99 |

(দাম, ট্যাক্স ও লাভের পুরো হিসাব `PROBASHI_PLAN_BN.md` §৩-এ। যুক্তরাষ্ট্র ও কানাডায় ট্যাক্স চেকআউটে যোগ হয়; বাকিগুলোতে দামের ভেতরে। Play যে ট্যাক্স দেখায় সেটাই চূড়ান্ত।) প্রবাসী প্ল্যানের সুইচ বন্ধ থাকবে যতক্ষণ না তার সব টেস্ট পাস।

## ধাপ ৬ — শেষে যাচাই

1. Owner Admin → **Payments** → “নতুন Play পণ্য — বিক্রির আগে যাচাই” → **Google Play-তে আবার যাচাই** চাপুন।
2. তালিকায় প্রতিটি নতুন SKU-র পাশে **“চালু — বিক্রি হচ্ছে”** দেখবেন: `plus_monthly`, `plus_yearly`, `premium_pro_monthly`, `premium_pro_yearly`, `pack_c50`, `pack_c120`, `pack_c300` (প্রবাসী মার্জ হলে `probashi_monthly`, `probashi_yearly`)। কোনোটা “বিক্রি বন্ধ” থাকলে পাশে Google-এর অবস্থা লেখা থাকে (যেমন DRAFT, NOT_FOUND) — Play Console-এ সেটা Activate করে আবার চাপুন।
3. লাইসেন্স-টেস্টার Gmail দিয়ে একটা প্যাক আর Premium Pro মাসিক কিনে দেখুন (টেস্ট কার্ডে টাকা কাটে না)।
4. আমাদের জানান “Play-তে দাম বসেছে” — তবেই অ্যাপের লেখায় নতুন দাম দেখানো শুরু হবে।

**অ্যাপে কী সংখ্যা লেখা থাকবে (শুধু নিশ্চিত সংখ্যা):** Plus — মাসে ৩৫টি স্মার্ট মেসেজ; Premium — মাসে ৭৫টি স্মার্ট মেসেজ (কঠিন প্রশ্নে মাসে ১০টি পর্যন্ত প্রো); Premium Pro — মাসে ৭৬টি প্রো মেসেজ; Business — মাসে ২৪০টি স্মার্ট মেসেজ (জটিলে মাসে ৩০টি পর্যন্ত প্রো); সবাই দিনে ১০টি ফ্রি দ্রুত উত্তর। আসল খরচ মাপার পর বাড়ানো গেলে আপনাকে জানাব — আপনার অনুমতি ছাড়া কোনো সংখ্যা বদলাবে না।
