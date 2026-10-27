# বিলিং অডিট — টাকা ও ক্রেডিটের পুরো পথ (STEP 1, ২৭ অক্টোবর ২০২৬)

মালিকের অর্ডার: `owner_actions/BILLING_ORDER_27OCT.md` (নিয়ম A–V)।
এই অডিটে কোড, লাইভ ডাটাবেস, ফ্ল্যাগ বা টাকায় **কোনো পরিবর্তন করা হয়নি**। লাইভ DB শুধু পড়া হয়েছে, আর সেখান থেকে কেবল সংখ্যা, id ও পরিমাণ নেওয়া হয়েছে। কোনো token, ফোন নম্বর বা নাম এখানে নেই।
কোডের ভিত্তি: `origin/main` @ `0c68501`। লাইন নম্বরগুলো এই কমিটের।

চিহ্ন: ✅ ঠিক আছে · ⚠️ আংশিক · ❌ নেই বা ভুল

---

## ০. এক নজরে: সবচেয়ে বড় ১০টি সমস্যা

| # | সমস্যা | কোথায় | ঝুঁকি |
|---|---|---|---|
| 1 | **প্ল্যানের ক্রেডিট আলাদা বাকেটে রাখা হয় না। প্ল্যান শেষ হলেও সেগুলো মুছে যায় না।** ৯০ ক্রেডিটের pool সরাসরি `User.ai_credits`-এ যোগ হয়। পুরোনো pool শুধু তখনই expire হয়, যখন **পরের মাসের নতুন pool** দেওয়া হয়। ফ্রি ইউজারের pool = 0 হলে ফাংশন শুরুতেই ফেরত যায়, তাই expire কখনো হয় না। | `core/billing.py:138-140`, `:150-162` | একবার এক মাসের সাবস্ক্রিপশন কিনে বাতিল করলে ৯০/২০০ ক্রেডিট চিরদিনের জন্য থেকে যায় (মালিকের ১৩০-এর leak এটাই) |
| 2 | **Pool দেওয়া হয় ক্যালেন্ডার মাস ধরে (Asia/Dhaka `YYYY-MM`), paid period ধরে নয়।** | `core/billing.py:142-149` | ৩১ তারিখে কিনলে আজ ৯০ আর কাল ১ তারিখে আবার ৯০ পাওয়া যায় (খরচ করে ফেললে কিছুই expire হয় না)। মাসের মাঝখানে Premium থেকে Business-এ আপগ্রেড করলে Business-এর ২০০ পরের মাসের আগে আসে না (কম দেওয়া)। Play-র ৫ মিনিটের টেস্ট রিনিউয়ালেও একবারই pool আসে। |
| 3 | **রিফান্ড বা revoke হলে প্ল্যানের ক্রেডিট ফেরত নেওয়া হয় না।** `revoke_period` শুধু প্ল্যান বন্ধ করে, pool-এ হাত দেয় না। | `core/payments/entitlement.py:259-273` | Google ৪৮ ঘণ্টার মধ্যে পুরো টাকা ফেরত দিলেও ইউজার ৯০/২০০ ক্রেডিট রেখে দিতে পারে। এতে কোম্পানির সরাসরি লোকসান। |
| 4 | **প্যাক রিফান্ডে ব্যালান্স কখনো শূন্যের নিচে নামে না** (`take = min(balance, credits)`)। ব্যালান্স নেগেটিভ করা, ব্লক করা বা দ্বিতীয় রিফান্ডে কেনা বন্ধ করার কিছুই নেই। | `entitlement.py:331-335`, `core/payments/service.py:376` | প্যাক কিনে সব ক্রেডিট খরচ করে Google-এর কাছে রিফান্ড চাইলে AI খরচ আমাদের, টাকাও ফেরত যায়। বারবার করা যায়। |
| 5 | **Voided Purchases API-তে কোনো poll নেই, আর কোনো দৈনিক reconciliation-ও নেই।** একটা RTDN হারিয়ে গেলে সেই রিফান্ড আর কখনো ধরা পড়ে না। | `core/payments/play.py` (কোথাও `voidedpurchases` নেই); `service.sweep` `:424-477` | রিফান্ড হওয়া কেনাকাটার প্ল্যান বা ক্রেডিট থেকে যায় |
| 6 | **স্টেজড আনলক (I), রিফান্ড উইন্ডো (J), রিফান্ড রিকোয়েস্ট (K), রিফান্ড পলিসি পেজ (M): চারটির কোনোটিই নেই।** `orders.refund` বা `subscriptionsv2.revoke`-এর কোনো কল নেই। | পুরো কোডবেস (grep: কিছু মেলেনি) | নিয়মগুলো কাগজেই আছে, কোডে নেই |
| 7 | **CreditLedger-এ source id নেই, unique key নেই, bucket নেই।** reason-ও একাধিক অর্থে ব্যবহার হয় (`grant` দিয়ে pool, founding আর referral তিনটিই বোঝায়; `adjust` দিয়ে AI রিফান্ড, প্যাক রিফান্ড আর মালিকের সংশোধন)। Ad wallet-এর ক্রেডিট লেজারে লেখা হয়, কিন্তু `ai_credits`-এ যোগ হয় না। | `core/models.py:723-742`, `billing.py:1006-1013` | "ব্যালান্স = লেজারের যোগফল" কোডে নিশ্চিত করা নেই। এখন মিলছে শুধু কারণ কোনো ad wallet-এ টাকা নেই। |
| 8 | **প্যাকের ক্রেডিট ১২ মাসে expire হওয়ার কোড আছে** (`expires_at = now + 360 দিন`, `expire_credits`)। মালিকের নিয়ম বলে প্যাক কখনো expire হবে না। cron-এ `profit_guard_rollover` নেই বলে এটা এখনো চলেনি। কিন্তু কেউ cron যোগ করলেই প্যাক মুছে যাবে। | `entitlement.py:311`, `billing.py:1067-1094`, `core/management/commands/profit_guard_rollover.py:24` | নিয়ম B ভাঙে। একদিন হঠাৎ ইউজারের কেনা ক্রেডিট মুছে যেতে পারে। |
| 9 | **REVOKED RTDN (type 12) এলে Google-এর কাছে আবার যাচাই করা হয় না, payload-কেই বিশ্বাস করা হয়।** voided নোটিফিকেশনের `refundType` (পুরো বা আংশিক) দেখা হয় না। পুরোনো একটা রিনিউয়াল অর্ডারের রিফান্ড এলেও পুরো token (চলতি মাস সহ) revoke হয়ে যায়। | `play.py:596-598`, `:622-626` | OIDC আছে বলে জাল RTDN কঠিন। কিন্তু নিয়ম E পুরোপুরি মানা হয় না, আর আংশিক রিফান্ডে ভুল প্রতিক্রিয়া হয়। |
| 10 | **Owner Admin-এ ক্রেডিটকে টাকার মতো দেখায়।** `credits.grant` ইভেন্টে প্যাকের দাম `৳20.00` দেখায়, "+20 ক্রেডিট" নয়। TEST purchase-এর credits.grant সারিতে TEST ট্যাগ নেই (৳20.00 দেখায়)। মুদ্রা দেখায় না, বাংলা লেবেল নেই। ইউজারের পেজে শুধু শেষ ২০টি লেজার সারি দেখায়: যোগফল নেই, বাকেট নেই, কেনাকাটা নেই। | `backend/web/templates/owner/payments.html:53`, `web/owner/views_sections.py:823`, `web/templates/owner/user_detail.html:45-46` | মালিক ভুল সংখ্যা দেখেন |

আরও যা পাওয়া গেছে (ছোট, তবে ঠিক করতে হবে):
- `plans._grant` (trial-এর ক্রেডিট) row lock ছাড়া `user.ai_credits = old + n; save()` করে। একই সময়ে কোনো charge হলে lost update হতে পারে (`core/plans.py:271-277`)।
- Founding seat-এর ক্রেডিট শুধু user id দিয়ে আটকানো। অ্যাকাউন্ট মুছে একই ফোন নম্বরে আবার খুললে নতুন seat ও আবার ২০ ক্রেডিট পাওয়া যায় (seat যতক্ষণ বাকি আছে) (`core/growth.py:341-368`; `FoundingSeat.user` SET_NULL)।
- Referral-এর device hash আসে client-এর পাঠানো `device_id` থেকে। খালি পাঠালে device check পুরোপুরি বাদ পড়ে (`growth.py:220-225`)।
- AI ব্যর্থ হলে রিফান্ড সবসময় `ai_credits`-এ যায়, যদিও charge-টা ad wallet থেকে কাটা হয়ে থাকতে পারে। এতে ad ক্রেডিট স্থায়ী ক্রেডিটে বদলে যায় (`core/ai.py:272-274`, `billing.py:721-735`)।
- `PlayPurchase` CASCADE। "নতুন করে শুরু" (account delete) করলে token-এর binding মুছে যায় (`core/models.py:4347`)। পুরোনো সাবের RTDN তখন `other_account` হিসেবে উপেক্ষিত হয়, ফলে রিফান্ড আর কোনো ইউজারের সাথে মেলানো যায় না।
- Profit Guard ইউজার ধরে হিসাব করে না, পুরো অ্যাপ মিলিয়ে করে, আর শুধু ফ্রি tier-এ (`billing.py:614-645`; `core/logic/profit_guard.py`)। "এই ইউজার যত দিয়েছে তার চেয়ে বেশি খরচ করেছে" ধরনের কোনো সতর্কতা নেই।
- `profit_guard_rollover` cron-এ নেই (`/etc/cron.d/assisto-app`-এ শুধু `payments_sweep` প্রতি ঘণ্টায় চলে)। তাই `grant_all_monthly_pools`ও চলে না। pool শুধু তখন আসে, যখন ইউজার কোনো charge করে বা /me খোলে।
- লাইভ ইউজার #25-এর Premium ২০২৭-১০-২৩ পর্যন্ত, কোনো পেমেন্ট ছাড়াই (PlanPeriod 0টি; মালিক বা অ্যাডমিন এডিট)। সে এখন প্রতি মাসে ৯০ ক্রেডিট পায়। এটা মালিকের ইচ্ছাকৃত হলে ঠিক আছে। শুধু জানিয়ে রাখা হলো।

---

## ১. মালিকের ১৩০ ক্রেডিট কেন রয়ে গেল (প্রশ্ন ১)

**প্ল্যানের ক্রেডিট কোথায় দেওয়া হয়:** কেনার মুহূর্তে কোথাও না। `sync_subscription` (`play.py:278-341`) আর `grant_prepaid` (`entitlement.py:172-222`) শুধু `PlanPeriod` (প্ল্যানের সময়) লেখে। ক্রেডিট আসে **অলসভাবে** `billing.grant_monthly_pool` থেকে (`billing.py:127-171`)। এটা ডাকা হয় `ensure_monthly_pool` দিয়ে: `charge()` (`:676`), `guard_can()` (`:629`), `plans.entitlements()` (`core/plans.py:174`), `usage_summary` (`:548`) ইত্যাদির ভেতর থেকে।

**আলাদা বাকেট কি না:** না। pool সরাসরি `User.ai_credits`-এ যোগ হয় (`billing.py:163-165`)। প্যাক (`entitlement.py:312`), founding/referral (`growth.py:287-289,362`), trial (`plans.py:275`) সবই এই একই সংখ্যায় যায়। কোনটা কোন বাকেটের, সেটা কোথাও লেখা থাকে না।

**কেন expire হলো না:** expire হওয়ার একমাত্র পথ হলো **পরের** pool দেওয়ার সময় আগেরটার অব্যবহৃত অংশ কেটে নেওয়া (`billing.py:151-162`)। কিন্তু:
1. প্ল্যান শেষ হলে `monthly_pool_credits()` 0 ফেরত দেয় (`billing.py:115-119`), তাই `grant_monthly_pool` লাইন `139-140`-এই `return 0` করে। expire-এর কোড পর্যন্ত পৌঁছায়ই না।
2. প্ল্যান শেষ হওয়ার সময় যা চলে (`E.recompute`, `upsert_play_period`, `revoke_period`, `service.sweep`), তার কোনোটিই ক্রেডিটে হাত দেয় না।
3. হিসাবটা ক্যালেন্ডার মাস ধরে হয়, paid period ধরে নয়। তাই "প্রতিটি paid period শেষে expire" ধারণাটাই কোডে নেই।

---

## ২. নিয়ম A–V: একটা একটা করে

### A) লেজার: append-only, প্রতিটি পরিবর্তনের জন্য এক সারি, ব্যালান্স = যোগফল — ⚠️
- প্রমাণ: `CreditLedger` (`core/models.py:723-742`) সারি যোগ করে, কিন্তু DB-স্তরে append-only হওয়ার কোনো গ্যারান্টি নেই। `source id` ফিল্ড নেই (শুধু ১২০ অক্ষরের `note`)। কোনো unique constraint নেই। `unlock`, `revoke`, `refund` reason নেই (রিফান্ড `adjust` দিয়ে লেখা হয়: `entitlement.py:334`)।
- `ai_credits` আলাদা একটা denormalized সংখ্যা। কোথাও "যোগফল = ব্যালান্স" পরীক্ষা হয় না।
- লাইভ: ২৭ জন ইউজারের মধ্যে ০ জনের mismatch। কিন্তু ad wallet-এর পথ (`billing.py:1006-1013`) লেজারে +N লেখে অথচ `ai_credits`-এ যোগ করে না, ফলে প্রথম ফ্রি ad ক্রেডিট থেকেই mismatch শুরু হবে।
- Owner Admin-এর ইউজার পেজে শুধু শেষ ২০টি সারি দেখায় (`web/owner/views_sections.py:823`)। যোগফল, বাকেট বা source কিছুই নেই।
- ঝুঁকি: কোন ক্রেডিট কোথা থেকে এল, প্রমাণ করা যায় না। রিফান্ডের সময় কোন অংশ কাটতে হবে, তা বের করা যায় না।
- যা করতে হবে: `CreditLedger`-এ `bucket`, `source_type`, `source_id` (purchaseToken-hash + orderId / order id / ssv txn), `balance_after` আর `idempotency_key` (unique) যোগ করা। নতুন reason লাগবে: `plan_grant`, `unlock`, `expire`, `revoke`, `refund`, `adjust`, `pack`, `free`, `rewarded`, `referral`। ad wallet-কে লেজারে আলাদা বাকেট হিসেবে আনা। দৈনিক "যোগফল = ব্যালান্স" পরীক্ষা করা, না মিললে মালিককে সতর্ক করা। ইউজার পেজে পুরো লেজার, বাকেটের যোগফল আর মিলছে কি না, এগুলো দেখানো।

### B) বাকেট ও খরচের ক্রম — ❌
- প্রমাণ: বাকেট মাত্র একটা, `User.ai_credits` (`models.py:71`), আর ফ্রি ইউজারের জন্য `AdWallet` (`models.py:2574`)। `charge()` আগে `ai_credits` থেকে কাটে, তারপর ad wallet থেকে (`billing.py:721-735`)। মালিকের ক্রম হলো: প্ল্যান → ফ্রি/রিওয়ার্ডেড → প্যাক।
- প্যাক ১২ মাসে expire করানো হয় (`entitlement.py:311`, `billing.py:841`, `billing.py:1067-1094`), অথচ মালিকের নিয়ম "কখনো না"।
- ঝুঁকি: leak #1। প্যাকের ক্রেডিট ভুল করে মুছে যেতে পারে। কোন ক্রেডিট আগে খরচ হবে, তা ঠিক করা নেই।
- যা করতে হবে: `CreditBucket` টেবিল বা লেজার-ভিত্তিক বাকেট (plan, pack, free, rewarded, referral), যেখানে প্রতি সারিতে `expires_at` (plan = period শেষ, pack = null) আর `locked_until` (স্টেজড আনলকের জন্য) থাকবে। `charge()` row lock নিয়ে ক্রম মেনে কাটবে। `User.ai_credits` থাকবে শুধু cache বা যোগফল হিসেবে।

### C) বার্ষিক প্ল্যানে মাসে মাসে allowance — ⚠️
- প্রমাণ: বার্ষিক প্ল্যানে ১২ মাসের ক্রেডিট একসাথে দেওয়া হয় **না**। `monthly_pool_credits` প্রতি ক্যালেন্ডার মাসে প্ল্যানের মাসিক ক্রেডিট দেয় (`billing.py:103-124`, `:142`)। এটা নিয়মের পক্ষে।
- কিন্তু মাসগুলো ক্যালেন্ডার মাস, কেনার তারিখ থেকে গোনা মাস নয়। মাসের শেষ দিকে কিনলে প্রথম দুই দিনে দুইবার pool পাওয়া যায়। বার্ষিক প্ল্যান রিফান্ড হলে সেই মাসের allowance ফেরত নেওয়া হয় না।
- যা করতে হবে: allowance-এর মাস গোনা শুরু হবে period-এর `startTime` থেকে (৩১ তারিখের ক্ষেত্রে `add_months`)। প্রতিটি মাস একটা আলাদা grant, যার key `token + orderId + month_index`। মাস শেষ হলে অব্যবহৃত অংশ expire হবে।

### D) Idempotency: purchaseToken + orderId — ⚠️
- প্লান-সময়: `PlanPeriod` unique `(source, ref)` (`models.py:4397`), ref = token hash ✅। গেটওয়ে: `gw:<merchant_tx_id>` ✅। `provider_tx_id` unique ✅ (`models.py:4321`)।
- প্যাক: `CreditPurchase(provider, txn_ref)` আগে থেকে আছে কি না দেখা হয় user row lock নিয়ে (`entitlement.py:304-306`)। কিন্তু **DB-তে unique constraint নেই** (`models.py:2545-2571`)। key-তে orderId-ও নেই, শুধু token। token-টা এক অ্যাকাউন্টে বাঁধা বলে এখন নিরাপদ, তবে ভঙ্গুর।
- রেভিনিউ: `play.charge` প্রতি orderId-তে একবার (`play.py:265-274`) ✅, কিন্তু DB unique নেই, শুধু `.exists()` দেখা হয় (race হতে পারে)।
- Pool: key হলো `user + ক্যালেন্ডার মাস` (`billing.py:143-149`), purchaseToken বা orderId নয়। একই মাসে নতুন সাব কিনলে আবার pool আসে না, কিন্তু সেটা কাকতালীয়।
- RTDN: `WebhookReceipt (source, message_id)` unique ✅ (`models.py:4443`)। প্রসেস ব্যর্থ হলে receipt মুছে দেওয়া হয়, যাতে retry কাজ করে ✅ (`play.py:568-573`)।
- Restore বা reinstall করলে একই token আবার যাচাই হয়, আর `get_or_create` ও `granted` ফ্ল্যাগ দুবার দেওয়া আটকায় ✅।
- যা করতে হবে: প্রতিটি ক্রেডিট grant-এর জন্য লেজারে `idempotency_key = "play:<tokenhash>:<orderId>[:m<n>]"` রাখা, unique constraint সহ। `CreditPurchase(provider, txn_ref)` আর `PaymentEvent(kind='play.charge', ref)`-এ partial unique index দেওয়া।

### E) Client বা RTDN payload বিশ্বাস না করা + OIDC — ⚠️
- ✅ Client থেকে শুধু token আর productId আসে (`core/views_pay1.py:116-130`)। দাম আসে catalog থেকে (`play.py:313`, `:421`)। প্রতিটি verify-তে `subscriptionsv2.get` আর `products.get` থেকে আসল অবস্থা আনা হয় (`play.py:284`, `:404`)।
- ✅ সাব আর প্যাকের RTDN-এ token নিয়ে আবার Google থেকে আনা হয় (`play.py:600`, `:614`)।
- ❌ REVOKED (`nt == 12`) এলে `revoke_token` সরাসরি চলে, Google-এর কাছে যাচাই ছাড়াই (`play.py:596-598`)। `voidedPurchaseNotification`-ও তাই (`:622-626`)। এগুলো শুধু কেড়ে নেয়, তাই জাল RTDN দিয়ে কিছু পাওয়া যায় না। তবে নিয়ম অনুযায়ী Voided Purchases API বা `subscriptionsv2.get` দিয়ে নিশ্চিত হওয়া দরকার।
- ✅ OIDC: `verify_oidc` RS256 স্বাক্ষর (Google JWKS), `iss`, `aud`, `exp/iat`, `email` আর `email_verified` সব যাচাই করে (`play.py:496-526`)। fail-closed (`:529-543`)। লাইভ কনফিগে: `rtdn_audience` সেট ✅, `rtdn_sa_email` সেট ✅, shared token সেট নেই (দরকারও নেই)। ২২ থেকে ২৬ অক্টোবরের মধ্যে ২৩টি RTDN `rtdn_not_configured` কারণে বাতিল হয়েছিল, কনফিগ বসানোর আগে। এখন সব ঠিক।
- ⚠️ `packageName` শুধু থাকলে যাচাই হয় (`play.py:561`)।
- ⚠️ গ্রাহকের দেওয়া আসল দাম নেওয়া হয় না। সাবে `recurringPrice` (তালিকার দাম) নেওয়া হয়, BDT না হলে catalog-এর দাম বসে যায় (`play.py:312-313`)। প্যাকে সবসময় catalog-এর দাম (`play.py:421`)। ইন্ট্রো অফার, প্রোরেশন বা অন্য মুদ্রায় রেভিনিউ ভুল আসবে।

### F) Token বাঁধা এক অ্যাকাউন্টে (obfuscatedAccountId) — ✅ (ছোট ফাঁক আছে)
- `account_id(user) = "u<pk>-<HMAC16>"` (`play.py:90-96`)। অ্যাপ এটা `applicationUserName` হিসেবে পাঠায় (`app/lib/payments/play_billing_impl.dart:121`)। Google থেকে `obfuscatedExternalAccountId` পড়া হয় (`play.py:295`, `:405`)।
- `_owner_for` (`play.py:247-262`): HMAC না মিললে `other_account`। token আগে থেকে অন্য ইউজারে বাঁধা থাকলে `other_account`। `PlayPurchase.token_hash` unique (`models.py:4349`)।
- ফাঁক ১: `aid` খালি এলে (পুরোনো বিল্ড বা Play-বাইরের কেনাকাটা), প্রথম যে অ্যাকাউন্ট token জমা দেয় সেই মালিক হয়ে যায় (`:255`)। নিয়ম হওয়া উচিত: aid খালি হলে সাব বা প্যাক কিছুই দেওয়া হবে না (অথবা মালিকের পর্যালোচনায় যাবে)।
- ফাঁক ২: `PlayPurchase` CASCADE (`models.py:4347`)। অ্যাকাউন্ট মুছলে বাঁধনের রেকর্ড চলে যায়। পুরোনো pk-এর aid তখন আর কোনো ইউজারের সাথে মেলে না, তাই অন্য কেউ দাবি করতে পারে না (ভালো)। কিন্তু রিফান্ডের হিসাব হারিয়ে যায়। `SET_NULL` করে `owner_pk` বা hash রেখে দেওয়া উচিত।
- `purchase_token` DB-তে সাধারণ টেক্সট হিসেবে আছে (`models.py:4350`)। আবার sync করতে লাগে, কিন্তু DB-র সীমিত অ্যাক্সেস বা এনক্রিপশন নিয়ে ভাবা দরকার।

### G) শুধু PURCHASED হলে দেওয়া; Pending হলে কিছু না; grant-এর পরে ack/consume — ⚠️
- প্যাক: `purchaseState == 2` (PENDING) হলে কিছু দেওয়া হয় না ✅ (`play.py:416-417`)। `!= 0` হলে canceled ✅। আগে grant, তারপর consume ✅ (`:422-440`)। grant আর `pp.granted` একই transaction-এ নেই, তবে `CreditPurchase`-এর idempotency আছে বলে দুবার দেওয়া হয় না।
- সাব: `SUBSCRIPTION_STATE_PENDING` entitled নয় ✅ (`play.py:52-53`, `:299`)। ack হয় plan period লেখার পরে আর শুধু entitled হলে ✅ (`:321-331`)। **কিন্তু ক্রেডিট দেওয়া কেনার সাথে বাঁধা নয়।** ack হয়ে যায় pool দেওয়ার আগেই, pool পরে অলসভাবে আসে। তাই "grant সফল হলে তবেই ack" সাবের ক্রেডিটের ক্ষেত্রে মানা হয় না।
- ৩ দিনের সীমা: `ack_sweep` প্রতি ঘণ্টায় চলে, backoff সর্বোচ্চ ৬ ঘণ্টা, শুধু ৩ দিনের কম বয়সী কেনাকাটায় ✅ (`play.py:631-688`, `service.py:470-476`)।
- অ্যাপ নিজে `completePurchase` করে, আর server consume করতে না পারলে অ্যাপ নিজে consume করে (`play_billing_impl.dart:180-203`)। grant একবারই হয় ✅।

### H) প্রতিটি সাবস্ক্রিপশন state — ⚠️ (প্ল্যানের অ্যাক্সেস প্রায় ঠিক, ক্রেডিট ভুল)
নিচের টেবিলে বিস্তারিত (§৪)। সারকথা:
- প্ল্যানের অ্যাক্সেস: ACTIVE, CANCELED, GRACE হলে আছে; ON_HOLD, PAUSED, EXPIRED, PENDING হলে বন্ধ; REVOKED হলে সাথে সাথে বন্ধ। এগুলো ঠিক আছে।
- ক্রেডিট: EXPIRED, ON_HOLD, PAUSED বা REVOKED হলে pool কেড়ে নেওয়া হয় না ❌। GRACE চলাকালীন নতুন ক্যালেন্ডার মাস এলে নতুন pool দেওয়া হয় ❌ (নিয়ম: grace-এ নতুন allowance নয়)।
- Upgrade বা downgrade: `linkedPurchaseToken` থাকলে পুরোনো period `replaced` হয় ✅ (`play.py:316-317`, `entitlement.py:276-289`)। অ্যাপ `ReplacementMode.withTimeProration` ব্যবহার করে (`play_billing_impl.dart:239-244`)। কিন্তু allowance ক্যালেন্ডার মাস ধরে হয়। Premium থেকে Business-এ গেলে এই মাসে Business-এর allowance মেলে না, আর Business থেকে Premium-এ গেলে Business-এর ২০০ থেকে যায়। দ্বিগুণ হয় না, তবে ভুল হয়।

### I) স্টেজড আনলক (প্রথম ৪৮ ঘণ্টায় ২০%) — ❌ নেই
- কোথাও `unlock`, `locked_until` বা `staged` নেই। Pricing config-এ ফিল্ড নেই। অ্যাপে কোনো লেখা নেই।
- যা করতে হবে: plan বাকেটে `unlocked` আর `locked_until` রাখা। `pricing.normalize`-এ `plan_unlock: {pct: 20, hours: 48}` যোগ করা, আর Owner Admin-এর Pricing & plans-এ বসানো। `/payments/state` থেকে `credits_now` আর `unlock_at` পাঠানো, যাতে অ্যাপ বাংলা ও ইংরেজিতে "এখন ৪০, ২ দিনে আরও ১৬০" দেখাতে পারে।

### J) রিফান্ড উইন্ডো ৪৮ ঘণ্টা (মালিক বদলাতে পারবেন) — ❌ নেই

### K) রিফান্ড রিকোয়েস্ট (অ্যাপের বাটন + Owner Admin) — ❌ নেই
- এখন আছে শুধু Owner Admin-এর "mark refunded", গেটওয়ে অর্ডারের জন্য (`web/owner/views_pay1.py:88-100` → `service.refund_order` `:355-380`)। এটা পুরো রিফান্ড, অব্যবহৃত অংশের হিসাব নেই, EPS API কল নেই (মালিক EPS প্যানেলে হাতে করেন)। Play-র জন্য কোনো রিফান্ড বাটন নেই।
- অ্যাপের FAQ শুধু বলে "Google Play-তে রিফান্ড চান" (`app/lib/l10n/app_en.arb:19495-19499`)। পুরোনো একটা স্ট্রিং এখনো বলে "billing চালু নেই, রিফান্ডের কিছু নেই" (`app_en.arb:5628`, ব্যবহার হচ্ছে কি না দেখতে হবে)।
- যা করতে হবে: `RefundRequest` মডেল, যেখানে থাকবে ইউজার, order id, কেনার সময়, কত ঘণ্টা হয়েছে, sku, দেওয়া দাম, দেওয়া ক্রেডিট, ব্যবহৃত ক্রেডিট, ব্যবহৃত দিন, আর প্রস্তাবিত রিফান্ড = দাম × min(অব্যবহৃত ক্রেডিটের ভাগ, অব্যবহৃত দিনের ভাগ)। Approve করলে Play `orders.refund` (পুরো রিফান্ড, `revoke=true`) চলবে। আংশিক রিফান্ডে Play Console-এর ধাপ দেখাতে হবে (API দিয়ে আংশিক রিফান্ড করা যায় না)। EPS-এর জন্য রিফান্ড API (যদি থাকে) অথবা হাতের ধাপ। ইউজারকে বাংলা ও ইংরেজিতে জানানো।

### L) Google নিজে রিফান্ড দিলে (RTDN + দৈনিক Voided poll) — ⚠️/❌
- RTDN-এ `voidedPurchaseNotification` ধরা হয় ✅ (`play.py:622-626`)। REVOKED-ও ✅। এতে প্ল্যান কাটা হয়, প্যাকের অব্যবহৃত অংশ কাটা হয় (শূন্যের নিচে না)।
- ❌ Voided Purchases API-তে দৈনিক poll নেই।
- ❌ সাবের রিফান্ডে pool-এর ক্রেডিট কাটা হয় না।
- ❌ ব্যালান্স নেগেটিভ হয় না, ক্রেডিটের ফিচার ব্লক হয় না, দ্বিতীয় রিফান্ডে কেনা বন্ধ হয় না, Owner Admin-এ ফ্ল্যাগ দেখায় না। `User.ai_credits` IntegerField, নেগেটিভ রাখা যায়। কিন্তু `charge()` `bal < need` হলে আটকায় (`billing.py:717`), তাই নেগেটিভ মানে এমনিতেই ব্লক। শুধু grant-এর কোডগুলো নেগেটিভ ব্যালান্সের হিসাব রাখে না।
- ❌ `refundType` (১ = পুরো, ২ = পরিমাণ-ভিত্তিক আংশিক) আর `productType` পড়া হয় না। সাবের পুরোনো একটা মাসের রিফান্ডেও পুরো token revoke হয় (`play.py:461-467`)। রেভিনিউ ঠিক সেই orderId থেকেই উল্টানো হয় ✅ (`:469-477`)।
- যা করতে হবে: `voided_sweep` (দৈনিক, `voidedpurchases.list?type=1&startTime=…`, সাথে `voidedSource` আর `voidedReason`)। সেই কেনাকাটা থেকে দেওয়া সব বাকেটের অবশিষ্ট অংশ revoke করা। যা খরচ হয়ে গেছে তা নেগেটিভ লেজার হিসেবে লেখা (ব্যালান্স < 0)। `User.refund_count` আর `purchase_blocked` রাখা। Owner Admin-এ ফ্ল্যাগ ও আনব্লক বাটন।

### M) রিফান্ড পলিসি পেজ (অ্যাপ + lifeassisto.com) — ❌ নেই
- `backend/web/templates/web`-এ কোথাও "refund" বা "ফেরত" নেই। Plans বা purchase স্ক্রিন থেকে কোনো লিংকও নেই।

### N) সার্ভারে atomic খরচ, row lock, AI ব্যর্থ হলে ক্রেডিট ফেরত — ✅ (ছোট ফাঁক আছে)
- `charge()`: `transaction.atomic()` + `select_for_update()` ইউজার ও AdWallet-এ, তারপর `F()` দিয়ে কাটা, সাথে এক লেজার সারি (`billing.py:707-736`) ✅।
- AI ব্যর্থ হলে: সব provider ব্যর্থ হলে `billing.credit(user, "adjust", charged, "ai_refund")` (`ai.py:272-274`) ✅। bizagent, booking, retention, photo studio-ও একইভাবে ফেরত দেয় ✅।
- ফাঁক: (১) রিফান্ড সবসময় `ai_credits`-এ যায় (ad wallet থেকে কাটা হলেও)। (২) `plans._grant` (trial) lock ছাড়া চলে (`plans.py:271-277`), পুরোনো `plans.consume_credit` (`:304-313`) আর `reward_ad` (`:316-330`) মৃত কোড, কিন্তু রয়ে গেছে। (৩) রিফান্ডের কোনো idempotency key নেই (একই রিকোয়েস্টে দুবার ফেরত দেওয়া কোডে আটকানো নেই; এখন কোড-পথ একটাই বলে সমস্যা হচ্ছে না)।

### O) রিওয়ার্ডেড অ্যাড শুধু AdMob SSV দিয়ে — ✅
- `ssv_callback`: ECDSA স্বাক্ষর যাচাই Google-এর কী দিয়ে (`core/photo_studio_service.py:543-594`)। nonce টিকিট, `user_id` মেলানো, `transaction_id` replay আটকানো (`:600-607`)। `PhotoAdTicket.transaction_id` unique (`models.py:3737-3749`)। client-এর "দেখেছি" দাবিতে কিছু মেলে না (`billing.py:908-913`)। দৈনিক cap (`:947-960`) আর ২ সেকেন্ডের fraud guard আছে ✅।
- ছোট: paid ইউজারের রিওয়ার্ডেড ক্রেডিট `ai_credits`-এ চলে যায়, স্থায়ীভাবে (`billing.py:992-1005`)। বাকেটের নিয়ম চালু হলে এটা "rewarded" বাকেটে যাবে।

### P) ফ্রি আর রেফারেল ক্রেডিট দিয়ে farming আটকানো — ⚠️
- Referral: self-referral আটকানো, প্রতি ডিভাইস বা ফোনে একবার (hash-গুলো অ্যাকাউন্ট মোছার পরেও থাকে, `SET_NULL`), মাসিক cap, activation দরকার (`growth.py:197-245`, `:265-299`) ✅। কিন্তু device_id client থেকে আসে। খালি পাঠালে device check বাদ পড়ে (`:220`) ⚠️।
- Founding seat: শুধু `user_id` দিয়ে আটকানো (`growth.py:351`)। ফোন বা ডিভাইস hash রাখা হয় না। "নতুন করে শুরু" করলে একই ফোনে নতুন seat ও আবার ২০ ক্রেডিট পাওয়া যায় (seat ফুরানো পর্যন্ত) ❌।
- Trial: account delete করে নতুন করে শুরু করলে `had_trial` আটকায় (`views_account_deletion.py:437-470`) ✅। কিন্তু অন্য ফোন নম্বরে নতুন সাইনআপ করলে কোনো device check নেই ⚠️ (trial button চাপলেই ১৫ ক্রেডিট)।
- যা করতে হবে: আলাদা `FreeGrantClaim(kind, phone_hash, device_hash)` টেবিল, unique, যা মোছা হবে না। founding, trial আর referral সবাই এটা দেখবে। device_id না থাকলে ফ্রি grant দেওয়া হবে না, অথবা সীমিত করা হবে।

### Q) দৈনিক reconciliation + মিস হওয়া expiry ধরার নিরাপত্তা job — ⚠️
- ✅ নিরাপত্তা: `payments_sweep` প্রতি ঘণ্টায় চলে (`/etc/cron.d/assisto-app` `7 * * * *`)। period-এর `ends_at` (Google-এর expiryTime) পার হলে `recompute` প্ল্যান নামিয়ে দেয় (`service.py:430-439`)। RTDN মিস হলেও প্ল্যান শেষ হয়। **কিন্তু ক্রেডিট থেকে যায়।**
- ❌ Google-এর সাথে কোনো তুলনা নেই: চালু সাবগুলো `subscriptionsv2.get` দিয়ে দেখা, সাম্প্রতিক অর্ডার মেলানো, বা Owner Admin-এ রিপোর্ট, এর কোনোটাই নেই। একটা রিনিউয়াল RTDN মিস হলে ইউজার সময়ের আগে Free হয়ে যায়, আর সেই রিনিউয়ালের রেভিনিউ গোনা হয় না।
- ❌ `profit_guard_rollover` cron-এ নেই। তার ভেতরের `grant_all_monthly_pools` (আর প্যাকের expire, যেটা নিয়ম অনুযায়ী থাকাই উচিত নয়) কখনো চলে না।

### R) Profit Guard: কোনো ইউজার যত দিয়েছে তার চেয়ে বেশি খরচ করলে সতর্কতা — ❌
- এখনকার guard পুরো অ্যাপের, ৭ দিনের হিসাবে, শুধু ফ্রি tier ব্লক করে (`billing.py:378-391`, `:685-703`; `core/logic/profit_guard.py:66`)। ইউজার ধরে "খরচ (AIUsage.cost_usd × usd_bdt) > এই মাসে NET পেমেন্ট" দেখার কিছু নেই। `_user_over_limit` শুধু দৈনিক কলের সংখ্যা গোনে (`ai.py:98-103`)।

### S) টেস্ট purchase রেভিনিউতে না গোনা, শুধু লাইসেন্স টেস্টার — ✅ (ডিসপ্লেতে ⚠️)
- সাব: `"testPurchase" in js` থাকলে `play.test_charge`, রেভিনিউ নয় (`play.py:336-339`) ✅। প্যাক: `purchaseType` থাকলে (0 = Test, 1 = Promo, 2 = Rewarded) রেভিনিউ নয় (`play.py:428-431`) ✅।
- লাইসেন্স টেস্টার ছাড়া কেউ টেস্ট purchase করতে পারে না, এটা Google নিজেই নিশ্চিত করে ✅।
- ⚠️ টেস্টে কেনা জিনিসও আসল প্ল্যান ও ক্রেডিট দেয় (এটাই ঠিক, পরীক্ষার জন্য দরকার)। কিন্তু `CreditPurchase.price_bdt = 20`, `PlayPurchase.price_bdt = 249/20` আর `credits.grant` ইভেন্টে `amount_bdt = 20` লেখা হয়, টেস্ট-ফ্ল্যাগ ছাড়া। কোনো রিপোর্ট এগুলো যোগ করলে টেস্টের টাকাও রেভিনিউ হয়ে যাবে। `PlayPurchase`-এ একটা `is_test` ফিল্ড যোগ করা দরকার।
- লাইভ: ইউজার #3-এর ৮টি `play.test_charge`, `play.charge` ০টি। রেভিনিউতে ৳০ ✅।

### T) EPS-এ একই নিয়ম; ক্রেডিট নগদে তোলা যায় না — ⚠️
- EPS: স্ট্যাটাস API দিয়ে যাচাই, পরিমাণ, মুদ্রা আর tx মেলানো, provider tx unique (`service.py:226-296`) ✅। বার্ষিক EPS প্ল্যানে ১২ মাস প্ল্যান-সময় দেওয়া হয়, ক্রেডিট আসে ক্যালেন্ডার মাস ধরে (Play-র মতোই সমস্যা) ⚠️।
- রিফান্ড শুধু মালিক হাতে "mark refunded" করলে হয় (`service.py:355-380`)। পুরো revoke, প্যাক কখনো শূন্যের নিচে না, pool কাটা হয় না, EPS API নেই ⚠️/❌।
- নগদে তোলা: কোনো কোড-পথ নেই, আর `credits_out.py:13`, `growth.py:7`-এ স্পষ্ট লেখা আছে ✅।

### U) Owner Admin-এর Payment audit ডিসপ্লে — ❌
- ইভেন্ট টেবিল: `{{ e.kind }} {{ e.channel }}` কাঁচা ইংরেজিতে দেখায়, আর amount থাকলে সবসময় `৳{{ e.amount_bdt }}` (`web/templates/owner/payments.html:53`)। তাই `credits.grant` সারিতে "৳20.00" দেখায়: এটা প্যাকের দাম, ক্রেডিট নয়। এটাই মালিকের দেখা "TK 20.00"।
- TEST ট্যাগ নেই: test purchase-এর `credits.grant` সারিতেও ৳20.00 দেখায়। `play.test_charge` শুধু kind-এর নামে বোঝা যায়।
- মুদ্রা কলাম নেই। আসল যে দাম দেওয়া হয়েছে, তার কলাম নেই। রিফান্ডের সারিতে কোন অর্ডার, তা পরিষ্কার নয়।
- `entitlement.update` প্রতি RTDN-এ একটা করে সারি তৈরি করে। শেষ ৪০টি সারির জায়গা এগুলোই ভরে ফেলে (`views_pay1.py:118`)।

### V) ইউজার #3-এর ব্যালান্স লেজার adjust দিয়ে ঠিক করা — ❌ (এখনো করা হয়নি; §৬-এ হিসাব)

---

## ৩. Google Play Billing-এর অফিসিয়াল নিয়মের সাথে তুলনা

| Google-এর নিয়ম | আমাদের কোড | অবস্থা |
|---|---|---|
| **Purchase state**: one-time-এর `purchaseState` 0 = PURCHASED, 1 = CANCELED, 2 = PENDING। PENDING হলে কিছু দেওয়া যাবে না। | `play.py:406-419` | ✅ |
| **৩ দিনের মধ্যে acknowledge**, নাহলে Google নিজে রিফান্ড ও revoke করে | সাবে `ack_subscription` (`:324-331`), প্যাকে consume। ৩ দিনের ack_sweep (`:631-688`) | ✅ (ক্রেডিট দেওয়া ack-এর সাথে বাঁধা নয়: G) |
| **Consumable হলে consume** (consume করলেই acknowledge হয়ে যায়) | server consume করে (`:432-440`), ব্যর্থ হলে অ্যাপ করে | ✅ |
| **subscriptionsv2 state**: ACTIVE, CANCELED (মেয়াদ পর্যন্ত চলবে), IN_GRACE_PERIOD (চলবে), ON_HOLD (বন্ধ), PAUSED (বন্ধ), EXPIRED (বন্ধ), PENDING (দেওয়া হবে না), PENDING_PURCHASE_CANCELED (কিছু না) | `ENTITLED_STATES` (`:52-53`) + `expiry > now` (`:299`) | প্ল্যানে ✅, ক্রেডিটে ❌ (§৪) |
| **linkedPurchaseToken**: upgrade, downgrade বা resubscribe-এ পুরোনো token বাতিল করতে হবে | `mark_replaced` (`:316-317`) | ✅ প্ল্যানে, ⚠️ allowance-এ |
| **obfuscatedExternalAccountId** দিয়ে token কোন অ্যাকাউন্টের তা মেলানো | `_owner_for` + HMAC (`:247-262`) | ✅ (খালি হলে ⚠️) |
| **RTDN subscription type**: 1 RECOVERED, 2 RENEWED, 3 CANCELED, 4 PURCHASED, 5 ON_HOLD, 6 IN_GRACE_PERIOD, 7 RESTARTED, 8 PRICE_CHANGE_CONFIRMED, 9 DEFERRED, 10 PAUSED, 11 PAUSE_SCHEDULE_CHANGED, 12 REVOKED, 13 EXPIRED, 17 ITEMS_CHANGED, 18 CANCELLATION_SCHEDULED, 19 PRICE_CHANGE_UPDATED, 20 PENDING_PURCHASE_CANCELED, 22 PRICE_STEP_UP_CONSENT_UPDATED | REVOKED ছাড়া সবকটির জন্য আবার sync হয় (`:596-607`)। `NOTIF` ম্যাপে 17, 18, 22 নেই, কিন্তু sync হয় বলে ক্ষতি নেই (শুধু লগে সংখ্যা দেখায়) | ✅ (REVOKED-এ ⚠️) |
| **oneTimeProductNotification**: 1 PURCHASED, 2 CANCELED | `:608-621` | ✅ |
| **voidedPurchaseNotification**: `purchaseToken`, `orderId`, `productType` (1 সাব / 2 one-time), `refundType` (1 পুরো / 2 পরিমাণ-ভিত্তিক আংশিক) | token আর orderId পড়া হয়। productType আর refundType উপেক্ষা করা হয় (`:622-626`) | ⚠️ |
| **Voided Purchases API** (`purchases.voidedpurchases.list`, `type=1` দিলে সাবও আসে, ৩০ দিন পর্যন্ত পেছনে): RTDN মিস হলে ব্যাকআপ | নেই | ❌ |
| **রিফান্ড API**: `orders.refund` (`POST applications/{pkg}/orders/{orderId}:refund?revoke=true`, শুধু পুরো রিফান্ড)। সাবের জন্য নতুন `purchases.subscriptionsv2.revoke` (revocationContext: fullRefund বা proratedRefund)। আংশিক টাকা ফেরত শুধু Play Console থেকে। | নেই | ❌ |
| **টেস্ট purchase**: সাবে `testPurchase` ফিল্ড, প্যাকে `purchaseType = 0`। শুধু লাইসেন্স টেস্টার পারে। টেস্টে রিনিউয়াল দ্রুত হয় (মাসিক = ৫ মিনিট) | `:336`, `:428` | ✅ |
| **RTDN OIDC**: Pub/Sub push JWT। Google JWKS দিয়ে RS256, `iss = accounts.google.com`, `aud`, `email = push SA`, `email_verified` | `verify_oidc` (`:496-526`) | ✅ |
| **Order id**: প্রতিটি রিনিউয়ালের নতুন orderId (`GPA.x..0`, `..1`)। v2-তে `latestOrderId` এখন deprecated, তার জায়গায় `lineItems[].latestSuccessfulOrderId` | `js.get("latestOrderId")` (`:308`) | ⚠️ নতুন ফিল্ডে যেতে হবে (Google-এর বর্তমান ডক দেখে নিশ্চিত করতে হবে) |

---

## ৪. প্রতিটি সাবস্ক্রিপশন state-এ কী হয় (প্রশ্ন ৭)

| State / ঘটনা | মালিকের নিয়ম | এখন প্ল্যান | এখন ক্রেডিট | অবস্থা |
|---|---|---|---|---|
| PURCHASED (4) / ACTIVE | প্ল্যান + allowance (২০% আনলক) | চালু ✅ | pool আসে পরের charge বা /me-তে, ক্যালেন্ডার মাস ধরে | ⚠️ |
| RENEWED (2) | নতুন period, নতুন allowance, আগেরটা expire | `ends_at` বাড়ে ✅ | **কিছু হয় না** (একই মাসে) ❌ | ❌ |
| RECOVERED (1) (hold থেকে ফেরা) | প্ল্যান ফেরে + সেই period-এর allowance | ফেরে ✅ | কিছু না | ⚠️ |
| RESTARTED (7) | বাতিল করা ফিরিয়ে নেওয়া, চলবে | ✅ | — | ✅ |
| CANCELED (3) | মেয়াদ পর্যন্ত অ্যাক্সেস | ✅ (`ENTITLED_STATES`) | — | ✅ |
| IN_GRACE_PERIOD (6) | অ্যাক্সেস থাকবে, নতুন allowance নয় | ✅ | নতুন মাস এলে **নতুন pool** ❌ | ⚠️ |
| ON_HOLD (5) | অ্যাক্সেস বন্ধ | বন্ধ ✅ | pool থেকে যায় ❌ | ⚠️ |
| PAUSED (10) | বন্ধ, resume করলে ফেরে | বন্ধ, ফেরে ✅ | pool থেকে যায় ❌ | ⚠️ |
| EXPIRED (13) | বন্ধ, allowance expire | বন্ধ ✅ | **থেকে যায়** (মালিকের leak) ❌ | ❌ |
| REVOKED (12) | সাথে সাথে বন্ধ + ক্রেডিট কাটা | বন্ধ ✅ | থেকে যায় ❌ | ❌ |
| PENDING / PENDING_PURCHASE_CANCELED (20) | কিছু না | কিছু না ✅ | কিছু না ✅ | ✅ |
| Upgrade/downgrade (linkedPurchaseToken) | পুরোনোটা শেষ, allowance দ্বিগুণ নয় | পুরোনো `replaced` ✅ | ক্যালেন্ডার মাস ধরে, Business-এর allowance আসে না বা Business-এর থেকে যায় | ⚠️ |
| Voided (রিফান্ড) | সব কাটা, নেগেটিভ, ব্লক | বন্ধ ✅ | শুধু প্যাক, শূন্যের নিচে না | ❌ |

---

## ৫. নির্দিষ্ট প্রশ্নের উত্তর

1. **প্ল্যানের ক্রেডিট কোথায় দেওয়া হয়, আলাদা বাকেট কি না, কেন expire হয়নি:** §১ দেখুন। `billing.grant_monthly_pool` (`billing.py:127-171`) অলসভাবে, ক্যালেন্ডার মাস ধরে, সরাসরি `ai_credits`-এ দেয়। বাকেট নেই। ফ্রি হয়ে গেলে `pool <= 0` হয়ে `return` (`:139-140`) হয়, তাই expire কখনো চলে না।
2. **বার্ষিকে ১২ মাস একসাথে?** না। প্রতি ক্যালেন্ডার মাসে একবার (`billing.py:142`)। নিয়ম C প্রায় মানা হয়, শুধু মাস কেনার তারিখ থেকে গোনা হয় না।
3. **Idempotency key:** PlanPeriod `(source, ref = play:<sha256(token)[:40]>)` unique। গেটওয়ে `gw:<merchant_tx_id>`। `PaymentOrder.provider_tx_id` unique। `(user, idempotency_key)` unique। প্যাক `CreditPurchase(provider, txn_ref)` (শুধু lock, DB unique নেই)। রেভিনিউ `PaymentEvent(kind='play.charge', ref=orderId)` (শুধু `.exists()`)। Pool `CreditLedger(note='pool:YYYY-MM')` (lock আছে, unique নেই)। RTDN `WebhookReceipt(source, message_id)` unique। SSV `PhotoAdTicket.transaction_id` unique।
4. **Client বা RTDN payload কোথাও বিশ্বাস করা হয় কি?** Client: না (দাম catalog থেকে, অবস্থা Google থেকে)। RTDN: REVOKED (`play.py:596`) আর voided (`:622`) এলে Google-এর কাছে আবার যাচাই হয় না। শুধু কেড়ে নেয়, OIDC দিয়ে সুরক্ষিত। আর voided-এর `orderId` দিয়ে কোন রেভিনিউ উল্টাতে হবে তা ঠিক হয় (অন্য অ্যাকাউন্টের অর্ডার আটকানো আছে, `:472-473`)।
5. **Token কোন অ্যাকাউন্টে বাঁধা:** `obfuscatedAccountId = u<pk>-HMAC` + `PlayPurchase.token_hash` unique + `_owner_for` (§F)। ফাঁক: aid খালি থাকলে প্রথম যে দাবি করে সেই পায়। CASCADE delete।
6. **Ack/consume বনাম grant-এর ক্রম:** প্যাকে আগে grant, পরে consume ✅। সাবে আগে plan period, পরে ack ✅। কিন্তু ক্রেডিট (pool) কেনার সাথে বাঁধা নয়, পরে আসে।
7. **প্রতিটি state:** §৪ টেবিল।
8. **আজকের রিফান্ডের পথ:** (ক) Play: ইউজার Google-এর কাছে চায় → voided বা REVOKED RTDN → `revoke_token` → সাবের period revoked (প্ল্যান সাথে সাথে বন্ধ) / প্যাকের অব্যবহৃত অংশ কাটা (শূন্যের নিচে না) → `play.refund` ইভেন্ট আর DailyLedger থেকে NET বিয়োগ। pool-এর ক্রেডিট থেকে যায়। দৈনিক poll নেই। আমাদের দিক থেকে রিফান্ড দেওয়ার কোনো API কল নেই। (খ) EPS: মালিক EPS প্যানেলে রিফান্ড দিয়ে Owner Admin → Payments-এ "mark refunded" চাপেন (`views_pay1.py:88-100`) → `refund_order` (`service.py:355-380`) একই রকম revoke করে। (গ) অ্যাপে কোনো রিফান্ড রিকোয়েস্ট বা উইন্ডো নেই।
9. **Atomic খরচ, row lock, AI ব্যর্থ হলে ফেরত:** ✅ `billing.charge` (`:650-743`) আর `ai.py:272-274`। ফাঁক §N-এ।
10. **টেস্ট purchase রেভিনিউতে গোনা হয় কি?** না, রেভিনিউতে যায় না (`play.py:336`, `:428`)। কিন্তু `price_bdt` আর `credits.grant`-এর amount-এ টেস্টের দাম লেখা থাকে, ফ্ল্যাগ ছাড়া (§S)।
11. **Owner Admin-এর ডিসপ্লে:** §U। `payments.html:53`-এ সব amount-এর আগে `৳` বসে, তাই credits.grant "৳20.00" দেখায়। TEST ট্যাগ নেই, মুদ্রা নেই, বাংলা লেবেল নেই। ইউজার পেজে শেষ ২০টি সারি শুধু, যোগফল বা বাকেট নেই (`views_sections.py:823`, `user_detail.html:45-46`)।
12. **ইউজার #3:** §৬।

---

## ৬. ইউজার #3: শুধু পড়ে দেখা (লাইভ DB, ২৭ অক্টোবর)

**এখনকার অবস্থা:** `ai_credits = 130`, plan = free (plan_until নেই), trial নেই, founder নয়, AdWallet = 0 পয়সা।

**লেজার (৩টি সারি, যোগফল = 130 = ব্যালান্স):**

| id | সময় (UTC) | delta | reason | note | আসলে কোন বাকেট |
|---|---|---|---|---|---|
| 6 | 2026-10-24 18:23 | +20 | grant | founding:1 | ফ্রি (Founding seat-এর এককালীন উপহার) |
| 12 | 2026-10-27 04:36 | +90 | grant | pool:2026-10 | প্ল্যান allowance (Premium) |
| 13 | 2026-10-27 04:45 | +20 | topup | pack:p20 play | প্যাক (টেস্ট purchase) |

reason অনুযায়ী: `grant` ২টি = +110, `topup` ১টি = +20। খরচ (consume) ০টি।

**কেনাকাটা (token ছাড়া):**

| | ধরন | sku | state | সময় | অন্যান্য |
|---|---|---|---|---|---|
| PlayPurchase 1 | sub | premium_monthly | SUBSCRIPTION_STATE_EXPIRED | তৈরি 04:30, মেয়াদ শেষ 04:55 | ack ✅, price 249.00, linked নেই, test purchase (৮টি `play.test_charge`) |
| PlayPurchase 2 | pack | pack_p20 | PURCHASED | 04:45 | purchaseType = 0 (TEST), consumed ✅, granted ✅, price 20.00 |
| PlanPeriod 1 | play premium | — | active (তবে ends 04:55, তাই অকার্যকর) | 04:30 থেকে 04:55 | note = EXPIRED |
| CreditPurchase 1 | p20 | — | confirmed, granted | — | `expires_at = 2027-10-22` (নিয়ম B-এর বিরুদ্ধে) |

RTDN-এর ধারা: PURCHASED → ৪টি RENEWED (৫ মিনিটের টেস্ট রিনিউয়াল) → CANCELED (04:54) → EXPIRED (04:55)। মোট ৫টি paid period (কেনা + ৪টি রিনিউয়াল), অথচ pool দেওয়া হয়েছে **১ বার** (ক্যালেন্ডার মাস ধরে)। মালিকের নিয়মে প্রতিটি period আলাদা allowance পেত, আর পরেরটা আসার সময় আগেরটা expire হতো। শেষ ফল একই।

**মালিকের নিয়মে হিসাব:**
```
ফ্রি (founding:1)              +20   → কখনো expire হয় না (ফ্রি বাকেট)
প্ল্যান allowance (Premium)     +90   → period শেষ 2026-10-27 04:55 → অব্যবহৃত 90 expire
প্যাক p20 (টেস্ট)               +20   → কখনো expire হয় না (প্যাক বাকেট)
খরচ                              0
------------------------------------------------
সঠিক ব্যালান্স = 20 + 20 + (90 − 90) = 40
এখন = 130  →  পার্থক্য = −90
```
**V-এর জন্য প্রস্তাব:** একটা লেজার সারি লেখা: `delta = −90`, reason `expire` (নতুন স্কিমায় `bucket = plan`), source = `play:<PlayPurchase 1-এর token hash>`, note = "Premium period ended 2026-10-27 04:55 UTC — unused plan allowance (owner order V)"। ফল: ব্যালান্স 40 = লেজারের যোগফল। (STEP 2-এ, DB ব্যাকআপ নেওয়ার পর। এই অডিটে কিছু লেখা হয়নি।)
বিকল্প: test pack-কেও শূন্য করে দিলে (মালিক যদি চান টেস্টে পাওয়া ক্রেডিট না থাকুক) ব্যালান্স 20 হবে। তবে মালিকের নিয়মে প্যাক কখনো expire হয় না, তাই সুপারিশ 40।

**লাইভ DB-র অন্যান্য সংখ্যা (মাইগ্রেশনের জন্য):** মোট ইউজার ২৭। লেজার: `grant` ৮টি (founding ৬ = +120, pool ২ = +180), `trial` ৪টি = +60, `topup` ১টি = +20। কোনো খরচ নেই। ব্যালান্স ≠ যোগফল: ০ জন। নেগেটিভ ব্যালান্স: ০। ফ্রি হয়েও pool ধরে রাখা ইউজার: শুধু #3। Pool পাওয়া অন্যজন #25 (Premium owner-edit, ৯০, এখনো চালু)। PlayPurchase ২টি, PaymentOrder ০টি, ReferralClaim ০টি, FoundingSeat ৬টি।

---

## ৭. ঠিক করার তালিকা (অগ্রাধিকার অনুযায়ী)

### P0: টাকার লোকসান বা ফ্রি ক্রেডিট বন্ধ করা (server, এখনই deploy করা যায়)
| # | কাজ | নিয়ম |
|---|---|---|
| P0-1 | লেজার v2: `bucket`, `source_type`, `source_id`, `idempotency_key` (unique), `balance_after`। নতুন reason। `ai_credits` হবে শুধু যোগফলের cache। দৈনিক মিলিয়ে দেখা। | A, D |
| P0-2 | বাকেট (plan / pack / free / rewarded / referral), সাথে `expires_at` আর `locked_until`। `charge()` ক্রম: plan → free+rewarded → pack। প্যাকে আর কোনো expiry নয় (`entitlement.py:311`, `billing.py:841`, `expire_credits` থেকে প্যাক বাদ)। | B |
| P0-3 | প্ল্যান allowance হবে **paid period** ধরে, ক্যালেন্ডার মাস ধরে নয়। প্রতিটি সাব বা রিনিউয়াল order-এ একটা grant, key `token+orderId` (বার্ষিকে `+month_index`)। period শেষ হলে (EXPIRED, ON_HOLD, PAUSED, REVOKED, replaced, sweep-এ মেয়াদ পার) অব্যবহৃত plan বাকেট expire। GRACE-এ নতুন allowance নয়। | B, C, D, H |
| P0-4 | রিফান্ড বা voided হলে সেই কেনাকাটা থেকে দেওয়া সব বাকেটের অবশিষ্ট অংশ revoke করা, আর খরচ হয়ে যাওয়া অংশ নেগেটিভ ব্যালান্স হিসেবে রাখা। `refund_count` রাখা, দ্বিতীয়বারে `purchase_blocked`, Owner Admin-এ ফ্ল্যাগ। সাব আর প্যাক দুটোতেই, EPS-সহ। | L, T |
| P0-5 | দৈনিক `voided_sweep` (Voided Purchases API, `type=1`)। REVOKED বা voided RTDN এলে আবার যাচাই করা। `refundType` অনুযায়ী পুরো বা আংশিক। | E, L |
| P0-6 | ইউজার #3-এর −90 adjust (ব্যাকআপের পরে)। | V |
| P0-7 | Upgrade বা downgrade: নতুন token-এর প্রথম order-এ নতুন tier-এর allowance। পুরোনো token-এর plan বাকেট `replaced` হওয়ার সাথে সাথে expire। | H |

### P1: নিয়ম পুরো করা (server + পরের অ্যাপ বিল্ড)
| # | কাজ | নিয়ম |
|---|---|---|
| P1-1 | স্টেজড আনলক: ২০% সাথে সাথে, বাকিটা ৪৮ ঘণ্টা পরে (`locked_until`)। Pricing config-এ % আর ঘণ্টা, Owner Admin-এ এডিট। `/payments/state`-এ `credits_now` আর `unlock_at`। অ্যাপে বাংলা ও ইংরেজি লেখা। | I |
| P1-2 | রিফান্ড উইন্ডো config (২৪/৪৮, ডিফল্ট ৪৮)। `RefundRequest` মডেল + API + অ্যাপের বাটন (উইন্ডোর ভেতরে) বা পলিসি (উইন্ডোর পরে)। Owner Admin → Payments → Refund requests (প্রস্তাবিত অংশ, Approve suggested / custom / Reject + নোট)। Play পুরো রিফান্ডে `orders.refund?revoke=true`। আংশিক হলে Console-এর ধাপ দেখানো। EPS-এর পথ। ইউজারকে বাংলা ও ইংরেজিতে জানানো। | J, K |
| P1-3 | রিফান্ড পলিসি পেজ (অ্যাপ + lifeassisto.com, বাংলা ও ইংরেজি, শুধু কোম্পানির ইমেইল)। Plans, purchase স্ক্রিন আর ওয়েবসাইটের ফুটার থেকে লিংক। পুরোনো "billing চালু নেই" FAQ স্ট্রিং সরানো। | M |
| P1-4 | দৈনিক reconciliation: চালু সব Play সাব `subscriptionsv2.get` দিয়ে মেলানো, সাম্প্রতিক order মেলানো, অমিল ঠিক করা, Owner Admin-এ রিপোর্ট। `profit_guard_rollover` বা নতুন `billing_daily` cron-এ যোগ করা। | Q |
| P1-5 | ইউজার ধরে Profit Guard: এই মাসের AI খরচ > এই মাসের NET পেমেন্ট হলে মালিককে সতর্কতা আর Owner Admin-এর তালিকা। | R |
| P1-6 | Owner Admin Payment audit: আসল দাম + মুদ্রা, TEST ট্যাগ (`PlayPurchase.is_test`), ক্রেডিট "+20 ক্রেডিট", প্রতিটি ইভেন্টের বাংলা লেবেল, `entitlement.update` আলাদা বা লুকানো। ইউজার পেজে পুরো লেজার, বাকেটের যোগফল, মিলছে কি না, কেনাকাটার তালিকা। | U, A |
| P1-7 | Anti-farming: `FreeGrantClaim(phone_hash, device_hash, kind)` unique, যা মোছা হবে না। founding, trial আর referral সবাই দেখবে। device_id খালি হলে ফ্রি grant নয়। | P |
| P1-8 | `obfuscatedAccountId` খালি থাকলে কিছু দেওয়া হবে না (মালিকের পর্যালোচনায় যাবে)। `PlayPurchase` → `SET_NULL` + owner hash রাখা। | F |

### P2: পরিষ্কার করা ও শক্ত করা
| # | কাজ | নিয়ম |
|---|---|---|
| P2-1 | `plans._grant`, `consume_credit`, `reward_ad`, `grant_monthly_if_due` সরানো বা `billing`-এর atomic পথে নেওয়া। | N |
| P2-2 | AI রিফান্ড যে বাকেট থেকে কাটা হয়েছিল সেখানেই ফেরত। রিফান্ডে idempotency key। | N, B |
| P2-3 | আসল দেওয়া দাম আর মুদ্রা রাখা (Play orders API বা `lineItems[].latestSuccessfulOrderId`)। `latestOrderId`-এর deprecation দেখে নেওয়া। | E, U |
| P2-4 | `CreditPurchase(provider, txn_ref)` আর `play.charge(ref)`-এ DB unique index। | D |
| P2-5 | `packageName` বাধ্যতামূলক। `NOTIF`-এ 17, 18, 22 যোগ করা। | E |
| P2-6 | `purchase_token`-এর জন্য এনক্রিপশন বা সীমিত অ্যাক্সেস। | — |
| P2-7 | ক্রেডিট নগদ নয়, এটা রিফান্ড পলিসি আর ToS-এ স্পষ্ট করা। | T |
| P2-8 | প্রতিটি নিয়মের জন্য automated test (STEP 3)। | সব |

---

## ৮. পুরোনো ইউজারদের ডেটা মাইগ্রেশন (এখনকার ব্যালান্সকে বাকেটে ভাগ করা)

সমস্যা: এখনকার `ai_credits` একটা মাত্র সংখ্যা। লেজারের `reason` আর `note` থেকে উৎস বোঝা যায় (`pool:` = প্ল্যান, `founding:` বা `referral:` = ফ্রি/রেফারেল, `trial` = ফ্রি, `topup` = প্যাক, `rewarded` বা `ad_*` = রিওয়ার্ডেড)। খরচ কোন বাকেট থেকে হয়েছিল, সেটা লেখা নেই, তাই একটা ধরে নেওয়া নিয়ম লাগবে। (লাইভে এখন পর্যন্ত কোনো খরচই হয়নি, তাই আজকের ২৭ জনের ক্ষেত্রে সব বিকল্পের ফল প্রায় একই। শুধু #3 আলাদা।)

**বিকল্প ১ (সুপারিশ): লেজার থেকে নতুন করে গড়া, মালিকের খরচের ক্রম ধরে।**
প্রতিটি ইউজারের জন্য লেজার সময় অনুযায়ী আবার চালানো। প্রতিটি + সারি তার বাকেটে যাবে। প্রতিটি − সারি (consume) কাটা হবে plan → free+rewarded → pack ক্রমে। `pool:` grant-এর মেয়াদ = সেই মাসের শেষ, অথবা প্ল্যান তার আগে শেষ হলে সেই সময়। যে plan বাকেটের মেয়াদ পার হয়ে গেছে তার অবশিষ্ট অংশ `expire` সারি দিয়ে বাদ। এখনো চালু প্ল্যানের বাকেট থাকবে, মেয়াদ = চলতি period-এর শেষ (Play-তে `PlayPurchase.expires_at`, owner-edit-এ `plan_until` বা মাসের শেষ যেটা আগে আসে)। পুরোনো pool-এর ক্ষেত্রে স্টেজড আনলক প্রযোজ্য নয় (সবটাই আনলক ধরা হবে)। শেষে নতুন যোগফল আর পুরোনো ব্যালান্সের পার্থক্য একটা `adjust` (migration) সারিতে লেখা, কারণসহ।
- আজকের ফল: #3 → 40 (plan 0, free 20, pack 20)। #25 → plan 90 (চালু)। #18 → free 35। #19, #20, #23 → free 15। #31, #32, #35, #36 → free 20। প্যাক মোট ২০ (#3)।
- সুবিধা: মালিকের নিয়মের সাথে মেলে, leak বন্ধ হয়, প্রতিটি পরিবর্তন লেজারে দেখা যায়।

**বিকল্প ২: ইউজারের পক্ষে যায় এমন (সব পুরোনো ব্যালান্স প্যাক বাকেটে, কখনো expire হবে না)।**
সহজ, কেউ অভিযোগ করবে না। কিন্তু #3-এর ৯০-এর leak স্থায়ী হয়ে যায়, আর founding বা trial-এর ক্রেডিটও "কেনা" হিসেবে দেখায় (রিফান্ডের হিসাব ভুল হয়)। সুপারিশ নয়।

**বিকল্প ৩: কোম্পানির পক্ষে যায় এমন (pool দেখে plan বাকেট, বাকি সব ফ্রি বাকেটে, প্যাক শুধু CreditPurchase-এর অবশিষ্ট অংশ)।**
বিকল্প ১-এর মতোই, শুধু খরচ হিসাব করার সময় প্যাক আগে কাটা ধরা হয় (কেনা ক্রেডিট কম দেখায়)। নিয়মের সাথে মেলে না, আর ইউজারের কেনা ক্রেডিট কমে যেতে পারে। সুপারিশ নয়।

**মাইগ্রেশনের নিরাপত্তা:** DB ব্যাকআপ নেওয়া। আগে dry-run চালিয়ে প্রতিটি ইউজারের আগে ও পরের সংখ্যা Owner Admin বা STATUS-এ দেখানো। তারপর একটি transaction-এ লেখা। প্রতিটি পরিবর্তন `adjust` বা `expire` সারি হিসেবে, `source = migration:billing_v2`। কোনো সারি মোছা হবে না। নেগেটিভ ব্যালান্স কাউকে দেওয়া হবে না (পুরোনো ডেটায় রিফান্ড নেই)। `CreditPurchase.expires_at` null করা (প্যাক কখনো expire হয় না)।

---

## ৯. পদ্ধতি ও সীমা
- পড়া হয়েছে: `core/payments/{play,entitlement,catalog,service,eps,gateway}.py`, `core/billing.py`, `core/plans.py`, `core/ai.py`, `core/growth.py`, `core/photo_studio_service.py` (SSV), `core/views_pay1.py`, `core/views_account_deletion.py`, `core/models.py` (পেমেন্টের মডেলগুলো), `web/owner/views_pay1.py`, `web/owner/views_sections.py`, `web/templates/owner/{payments,user_detail}.html`, `app/lib/payments/play_billing_impl.dart`, `/etc/cron.d/assisto-app`, ইউজারের crontab।
- লাইভ DB: শুধু পড়ার জন্য `manage.py shell`, শুধু সংখ্যা ও id। কোনো token, ফোন বা নাম বের করা হয়নি। কিছু লেখা হয়নি।
- Google-এর তথ্য এসেছে Play Billing আর Play Developer API-এর ডক থেকে, আমার জানা অনুযায়ী। `latestOrderId`-এর deprecation আর `subscriptionsv2.revoke`-এর revocationContext Google-এর বর্তমান রেফারেন্সে আরেকবার মিলিয়ে নেওয়া দরকার।
