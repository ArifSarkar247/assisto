# Play Console-এ যা করবেন — দাম ও ক্রেডিট (মালিকের সিদ্ধান্ত ৯ নভেম্বর ১০:২০)

শাখা `agent/plansprep` · এই কাজগুলো **শুধু আপনি** করবেন (আমরা Play Console ছুঁই না)। কোনো দাম আমরা বদলাইনি (সিদ্ধান্ত ১২)।
লিড `manage.py pricing_v2_apply --apply` চালানোর (DB ব্যাকআপের পরে) **একই দিনে** নিচের কাজগুলো করুন।

## ১. নতুন বানান (One-time products → Create product, "Consumable")

| Product ID | দাম | কী | কেন |
|---|---|---|---|
| `credits_c15` | ৳৪৯ | ১৫ ক্রেডিট, ১২ মাস মেয়াদ | আদেশ ১০ নভেম্বর (ছোট প্যাক; ধাপ: AD_MEDIATION_SETUP_BN.md ধাপ ৬) |
| `credits_c50` | ৳১৭৯ | ৬০ ক্রেডিট, ১২ মাস মেয়াদ | সিদ্ধান্ত ৪ (আগে না থাকলে) |
| `credits_c120` | ৳৩৯৯ | ১৪০ ক্রেডিট, ১২ মাস | সিদ্ধান্ত ৪ |
| `credits_c300` | ৳৯৪৯ | ৩৩০ ক্রেডিট, ১২ মাস | সিদ্ধান্ত ৪ |
| `cctv_extra_relay_1gb` | ৳১৫০ | CCTV: এই মাসে +১ GB রিলে | সিদ্ধান্ত ১১ |
| `cctv_extra_ai_100` | ৳৮০ | CCTV: এই মাসে +১০০ AI চেক | সিদ্ধান্ত ১১ |

* বানানোর পর **Active** করুন। সার্ভার নিজে Google-এ যাচাই করে (Owner Admin → Payments), তারপরই অ্যাপে কেনার বোতাম আসে।
* বিবরণে মেয়াদ লিখুন: "কেনার দিন থেকে ১২ মাস"।

## ২. Inactive করুন (বিক্রি বন্ধ; কেনা ব্যালান্স থাকবে — সিদ্ধান্ত ২)

`credits_p20` · `credits_p50` · `credits_p100` · `credits_p200`
(মুছবেন না — শুধু Inactive। পুরনো কেনাকাটা ফেরত/রিস্টোর এখনো কাজ করবে।)

## ৩. সাবস্ক্রিপশন — base plan-এর নাম মিলিয়ে নিন (দাম বদলাবেন না)

| Subscription ID | Base plan ID (ঠিক এই নাম) |
|---|---|
| `assisto_premium` | `monthly`, `annual` |
| `assisto_business` | `monthly`, `annual` |
| `assisto_plus` (বিক্রি শুরু করলে) | `monthly`, `annual` |
| `assisto_premium_pro` (বিক্রি শুরু করলে) | `monthly`, `annual` |
| `assisto_probashi` | `monthly`, `annual` ($৪.৯৯) |

⚠️ বার্ষিকের নাম **`annual`** — `yearly` নয় (পুরনো ডকে ভুল ছিল; `yearly` হলে বার্ষিক কেনা ধরা পড়বে না)।
* প্রতিটি base plan-এ **Grace period: ৭ দিন**, **Account hold: চালু (৩০ দিন)**, **Resubscribe: চালু**। প্ল্যান বদলের (upgrade/downgrade) প্রোরেশন অ্যাপ নিজে কেনার সময় বলে দেয় — Console-এ কিছু করতে হবে না।
* **আসল দাম** (সিদ্ধান্ত ১২): Premium ও Business-এর যে দাম Play-তে আছে সেটা আমাদের জানান। জানালে Owner Admin → **প্ল্যান ও দাম** পাতায় দাম লিখলেই ক্রেডিট সূত্র নিজে বসাবে (হাতে ক্রেডিট লিখতে হবে না)। উদাহরণ: ৳৪৪৯ → ১৬০, ৳১,২৯৯ → ৪৪০, ৳১৯৯ → ৭০।

## ৪. আগের আদেশ থেকে বাকি (নিরাপত্তা প্ল্যান, safeplans)

`safe_child` (`monthly`, ৳৩০) · `safe_family` (`monthly`, ৳৯৯) · `safe_req_10` ৳১০ · `safe_req_30` ৳৩০ · `safe_req_100` ৳১০০ — বানানো না থাকলে বানান।

## ৫. শেষে যাচাই

Owner Admin → **প্ল্যান ও দাম**: pricing_v2 "চালু", ৪০% টেবিলে সব সবুজ; Payments → Play যাচাই-এ নতুন পণ্যগুলো "Active"। তারপর Play লাইসেন্স-টেস্টার দিয়ে STEP 4-এর কেসগুলো (নিচে FEATURE_CARD_PLANS_CREDITS_BN.md)।
