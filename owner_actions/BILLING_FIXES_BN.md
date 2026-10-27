# বিলিং, ক্রেডিট ও রিফান্ড — কী ঠিক করা হলো (STEP 2, সার্ভার) — ২৭ অক্টোবর ২০২৬

মালিকের অর্ডার: `owner_actions/BILLING_ORDER_27OCT.md` (নিয়ম A–V)। অডিট: `owner_actions/BILLING_AUDIT_BN.md`।
ব্রাঞ্চ: `agent/billing2`। লাইভ DB-তে কিছু লেখা হয়নি, deploy হয়নি, ফ্ল্যাগ বদলানো হয়নি।

## ০. এক নজরে

- নতুন ইঞ্জিন `backend/core/credits.py`: প্রতিটি ক্রেডিট একটা **লট**-এ থাকে (বাকেট: plan / pack / free / rewarded / referral, পুরোনো ব্যালান্সের জন্য legacy, রিফান্ডের ঋণের জন্য debt)। প্রতিটি পরিবর্তন লেজারে **এক সারি** (append-only), সাথে বাকেট, উৎস (order id / token hash / ssv / referral), পরের ব্যালান্স আর একটা unique key।
- সবসময় সত্য: `User.ai_credits == লেজারের যোগফল == সক্রিয় লটের যোগফল` (`manage.py credits_verify`)।
- প্ল্যানের ক্রেডিট এখন **paid period** ধরে আসে (Play-এর প্রতিটি orderId বা EPS অর্ডার = একটা `PaidOrder`), ক্যালেন্ডার মাস ধরে নয়। প্ল্যান শেষ, hold, pause, revoke বা upgrade হলেই অব্যবহৃত প্ল্যান-ক্রেডিট লেজারে `expire` সারি দিয়ে চলে যায়। **মালিকের ১৩০-এর leak বন্ধ।**
- রিফান্ড: Google-এর রিফান্ড (RTDN + দৈনিক Voided poll) → সেই অর্ডারের ক্রেডিট সরানো, খরচ হয়ে যাওয়া অংশ নেগেটিভ ব্যালান্স, দ্বিতীয় রিফান্ডে কেনা বন্ধ। অ্যাপ থেকে রিফান্ডের অনুরোধ + Owner Admin-এ সিদ্ধান্ত।
- নতুন মাইগ্রেশন `0095_billing_v2` — শুধু নতুন টেবিল ও নতুন কলাম (additive)। পুরোনো ব্যালান্স ভাগ করা হয় **শুধু** `credits_rebuild_buckets` কমান্ড দিয়ে (ব্যাকআপের পরে)।

## ১. নিয়ম অনুযায়ী কী বদলাল

| নিয়ম | কী করা হলো | কোথায় | অবস্থা |
|---|---|---|---|
| A লেজার | `CreditLedger`-এ `bucket`, `source_type`, `source_id`, `grant_key` (DB-unique), `balance_after`, `lot`। সারি একবার লেখা হয়, বদলানো বা মোছা যায় না (save/delete আটকানো)। নতুন reason: `unlock`, `revoke`, `refund`, `return`। Ad wallet-এর পুরো ক্রেডিট এখন `rewarded` বাকেটে যায়, ব্যালান্সও বাড়ে (অডিট #৭ ঠিক)। `credits_verify` কমান্ড + দৈনিক রিপোর্ট। | `core/credits.py`, `core/models.py`, `core/billing.py` | ✅ |
| B বাকেট | plan (paid period শেষে expire, rollover নেই), pack (**কখনো expire নয়**; ১২ মাসের expiry সরানো), free, rewarded, referral। খরচের ক্রম: plan → free+rewarded+referral → pack। `User.ai_credits` = মোট (cache)। | `credits.spend`, `billing.expire_credits` (এখন প্যাকে হাত দেয় না) | ✅ |
| C বার্ষিক | ১২ মাসের ক্রেডিট একসাথে নয়: প্রথম মাস এখন, বাকি ১১টি `scheduled` লট, কেনার তারিখের মাসিক বার্ষিকীতে (৩১ তারিখে কিনলে ৩০ নভেম্বর…) চালু হয়। | `payments/orders.py grant_allowance` | ✅ |
| D Idempotent | প্রতিটি grant-এর key `play:<orderId>:m<n>` / `gateway:<tx>:m<n>` / `…:pack`, DB-unique। `PaidOrder (channel, order_id)` unique, `CreditPurchase (provider, txn_ref)` unique, `play.charge`/`play.refund` রেভিনিউ প্রতি order-এ একবার (DB-unique)। `lineItems[].latestSuccessfulOrderId` আগে পড়া হয়, না থাকলে পুরোনো `latestOrderId`। | `play.order_id_of` | ✅ |
| E বিশ্বাস নয় | REVOKED এলে `subscriptionsv2.get` আবার আনা হয়; Google এখনো চালু বললে কিছুই বদলায় না (`revoked:unconfirmed`)। Voided এলে Voided Purchases API-তে মিলিয়ে দেখা হয়। `packageName` এখন বাধ্যতামূলক। OIDC আগের মতোই। paid period-এর শেষ সময় সবসময় Google-এর `expiryTime` (নিজের হিসাব নয়, টেস্ট আছে)। | `play._revoked`, `play._confirm_voided` | ✅ |
| F এক অ্যাকাউন্ট | `obfuscatedExternalAccountId` না থাকলে আর "প্রথম যে জমা দেয়" সে পায় না (`unbound_purchase`)। অ্যাকাউন্ট মুছলে `PlayPurchase` ও `PaidOrder` থাকে (user = NULL, `owner_ref` থাকে) — অন্য কেউ দাবি করতে পারে না, পরের রিফান্ডও মেলে। | `play._owner_for`, মডেল SET_NULL | ✅ |
| G শুধু PURCHASED | Pending = কিছু না। সাব: আগে প্ল্যান + ক্রেডিট grant, **তারপর** acknowledge; grant ব্যর্থ হলে ack হয় না (RTDN retry করে)। প্যাক: আগে grant, তারপর consume। ৩ দিনের ack sweep আছে। | `play.sync_subscription/sync_pack` | ✅ |
| H সব state | purchased/renewed/recovered/restarted → নতুন order = নতুন allowance (আগেরটা expire); canceled → মেয়াদ পর্যন্ত থাকে; grace → অ্যাক্সেস থাকে, **নতুন allowance নয়**; on hold / paused / expired / pending → অ্যাক্সেস বন্ধ + প্ল্যান-ক্রেডিট expire; revoked → সাথে সাথে বন্ধ। Upgrade/downgrade (Premium↔Business, মাসিক↔বার্ষিক, `linkedPurchaseToken`): পুরোনো token-এর বাকি প্ল্যান-ক্রেডিট expire, নতুন period-এর পুরো allowance আসে। **সিদ্ধান্ত: "যোগ নয়, বদল"** — কখনো দ্বিগুণ হয় না। | `play.sync_subscription`, `entitlement.mark_replaced` | ✅ |
| I ধাপে আনলক | প্রতিটি নতুন paid period-এ (প্রথম কেনা ও প্রতিটি নবায়ন, মাসিক ও বার্ষিক, EPS-ও) X% এখন, বাকিটা H ঘণ্টা পরে নিজে থেকে (`unlock` সারি)। ডিফল্ট ২০% / ৪৮ ঘণ্টা; Owner Admin → Pricing & plans → `billing` (০–১০০%, ০–১৬৮ ঘণ্টা)। | `credits.grant(staged)`, `credits.settle` | ✅ |
| J রিফান্ড উইন্ডো | প্রতিটি কেনা/নবায়ন থেকে W ঘণ্টা (শুধু ২৪ বা ৪৮, ডিফল্ট ৪৮), Owner Admin → Pricing & plans → `billing.refund_window_hours`। | `payments/refunds.py` | ✅ |
| K রিফান্ড অনুরোধ | `RefundRequest` মডেল + API (উইন্ডোর ভেতরে, নইলে নীতি ফেরত)। Owner Admin → Payments → Refund requests: ইউজার, order id, কেনার সময়, কত ঘণ্টা, প্ল্যান/প্যাক, দাম, দেওয়া/ব্যবহৃত ক্রেডিট, ব্যবহৃত দিন, প্রস্তাব = দাম × min(অব্যবহৃত ক্রেডিটের ভাগ, অব্যবহৃত দিনের ভাগ)। Approve suggested / custom / Reject + নোট। Play পুরো = `orders.refund?revoke=true` (seam, টেস্টে mock); Play আংশিক = Play Console-এর ধাপ + পরিমাণ; EPS = gateway-তে refund API থাকলে, নইলে হাতের ধাপ। সব লেজারে (`refund` সারি), ইউজারকে বাংলা/ইংরেজি in-app বার্তা। | `refunds.approve/reject`, `web/owner/views_bill2.py` | ✅ |
| L Google রিফান্ড | RTDN voided/REVOKED (যাচাইসহ) + **দৈনিক** Voided Purchases poll (`billing_daily` / `play_voided_poll`)। সেই অর্ডারের ক্রেডিট ও প্ল্যান সরানো; খরচ হয়ে যাওয়া অংশ → নেগেটিভ ব্যালান্স (`debt` বাকেট), নেগেটিভ থাকলে সব ক্রেডিট-ফিচার বন্ধ; দ্বিতীয় Google রিফান্ডে নতুন কেনা বন্ধ (মালিক খুলে দেন); Owner Admin-এ ইউজার পেজ + "Refund-flagged users" তালিকা। `refundType`/order id মানা হয়: পুরোনো একটা নবায়নের রিফান্ডে চলতি সাবস্ক্রিপশন বাতিল হয় না (অডিট #৯)। | `refunds.void_play`, `refunds.voided_poll` | ✅ |
| M নীতির পেজ | `lifeassisto.com/refund-policy` (বাংলা/ইংরেজি), ফুটার ও sitemap-এ লিংক, কোম্পানির ইমেইল (`LEGAL_CONTACT_EMAIL`), উইন্ডো সেটিং থেকে ঘণ্টা দেখায়। অ্যাপের স্ক্রিন পরের ধাপে। | `web/legal_content.py` | ✅ (ওয়েব) |
| N Atomic খরচ | প্রতিটি খরচ ইউজারের row lock নিয়ে এক transaction-এ। AI ব্যর্থ হলে ক্রেডিট **যে লট থেকে কাটা হয়েছিল সেখানেই** ফেরত (`spend_ref`; পুরোনো কলারদের জন্যও কাজ করে), একবারই। Photo Studio, ক্যামেরা, WhatsApp-বিল, মালিকের adjust সবাই এখন এই পথে। | `credits.spend/return_spend` | ✅ |
| O রিওয়ার্ডেড অ্যাড | আগের SSV যাচাই (ECDSA স্বাক্ষর, nonce, `transaction_id` unique) ঠিক আছে; দৈনিক cap আছে; ক্রেডিট এখন `rewarded` বাকেটে। | — | ✅ (যাচাই) |
| P Farming | `FreeGrantClaim` — ফোন/ডিভাইস/ইমেইলের hash, ইউজারের সাথে যুক্ত নয়, কখনো মোছে না; অ্যাকাউন্ট মোছার আগে tombstone লেখা হয়। Founding seat-এর ক্রেডিট একই ফোন/ডিভাইসে দ্বিতীয়বার নয়; রেফারেলে device id বাধ্যতামূলক (`device_required`); ট্রায়াল প্রতি **ব্যক্তি** একবার (ডিভাইস / ফোন / ইমেইল), row lock সহ। | `core/antifarm.py`, `growth.py`, `plans.py` | ✅ |
| Q Reconciliation | `billing_reconcile` / `billing_daily`: চালু ও সাম্প্রতিক Play সাব/প্যাক Google থেকে আবার এনে মেলানো (মিস হওয়া রিনিউয়াল/expiry/রিফান্ড ধরে), grant-হীন অর্ডার রিপোর্ট, Owner Admin → Billing reports। নিরাপত্তা: প্রতি ঘণ্টার `payments_sweep` এখন ক্রেডিটও settle করে (RTDN না এলেও মেয়াদ পার হওয়া প্ল্যান-ক্রেডিট expire)। `profit_guard_rollover` এখন নিরাপদ (প্যাক expire করে না) — cron-এ দেওয়া যায়। | `payments/reconcile.py` | ✅ |
| R Profit Guard | প্রতি ইউজার: এই মাসের AI খরচ (৳) > এই মাসে দেওয়া টাকা (টেস্ট ছাড়া, রিফান্ড বাদে) এবং ন্যূনতম সীমার বেশি হলে তালিকা (Billing reports) + ঐচ্ছিক স্টাফ পুশ (`billing.profit_guard_push`)। | `reconcile.profit_guard_users` | ✅ |
| S টেস্ট | টেস্ট কেনাকাটা কখনো রেভিনিউ নয় (আগের মতো) + এখন `PaidOrder.is_test`, `PlayPurchase.is_test` ট্যাগ। শুধু লাইসেন্স টেস্টার পারবে — এটা Play Console-এর সেটিং (Setup → License testing)। EPS sandbox মোডের অর্ডারও TEST। | — | ✅ |
| T EPS | একই নিয়ম: `PaidOrder`, paid-period allowance, ধাপে আনলক, বার্ষিকে মাসে মাসে, প্যাক বাকেট, মালিকের "mark refunded" এখন বাকেট দিয়ে ক্রেডিট সরায়, রিফান্ড অনুরোধে EPS-এর হাতের ধাপ। ক্রেডিট নগদে তোলা যায় না। | `entitlement.grant_prepaid`, `service.complete` | ✅ |
| U Payment audit | Payments পেজে "কেনাকাটা ও নবায়ন (আসল দাম)" টেবিল: দাম + মুদ্রা, TEST ট্যাগ, রিফান্ডের পরিমাণ। ইভেন্টে বাংলা লেবেল, ক্রেডিট "+20 ক্রেডিট" (কখনো ৳ নয়), `entitlement.update`/`play.rtdn` আওয়াজ লুকানো। ইউজার পেজে পুরো লেজার (৫০০ সারি), বাকেটের যোগফল, মিলছে কি না, কেনাকাটা, দেওয়া প্ল্যান। | `web/owner/views_bill2.py`, টেমপ্লেট | ✅ |
| V ইউজার #৩ | `credits_rebuild_buckets` (অডিটের বিকল্প ১): লেজার আবার চালিয়ে বাকেট, শেষ হওয়া প্ল্যান-ক্রেডিট expire, প্রতি ইউজারে **এক** `adjust` সারি। `--dry-run` আগে-পরে দেখায়। ইউজার #৩: **১৩০ → ৪০** (plan 0, free 20, pack 20), adjust −90। লাইভে চালানো হয়নি। | `core/rebuild_buckets.py` | ✅ (চালানো বাকি) |

### মালিকের পরের সংযোজন (২৭ অক্টোবর)
- **দেওয়া প্ল্যান লিখে রাখা:** `EntitlementGrant` (source: owner_grant / play_reviewer / founding / trial …, actor, কারণ)। Owner Admin-এর প্ল্যান এডিট আর `seed_play_reviewer` এখন এই পথে চলে; কখনো রেভিনিউ নয়।
- **"Paid" সংখ্যা:** Overview আর P&L-এ শুধু যাচাই করা আসল (টেস্ট নয়) Play/EPS পেমেন্ট যার paid period এখন চালু। আলাদা দেখায়: টেস্ট কেনাকাটা, ট্রায়াল, মালিক/সিস্টেমের দেওয়া। ARPU/break-even এই সংখ্যা দিয়েই।
- **যাচাই-না-হওয়া প্ল্যান ও ক্রেডিট:** `manage.py entitlements_audit [--fix --dry-run]` + Owner Admin → Payments → Unverified plans and credits। `--fix` শুধু জানা উৎস লিখে রাখে (Play রিভিউয়ার `PLAY_REVIEWER_PHONE` দিয়ে); বাকিগুলো শুধু প্রস্তাব। লাইভে #২৫ = Play reviewer grant (Premium থাকবে)।
- **ট্রায়াল:** সেটিং এক জায়গায় (`limits.trial_on_signup / trial_days / trial_credits`), Pricing & plans-এ বাংলা/ইংরেজি নামসহ, সীমা ০–৯০ দিন। ট্রায়ালের ক্রেডিট plan বাকেটে (source = trial) এবং **ট্রায়াল শেষ হলে expire** হয় (`expire` সারি)। ট্রায়াল প্রতি ব্যক্তি একবার; মানা করলে বাংলা/ইংরেজি বার্তা (`trial_used_person`)।

## ২. অ্যাপের পরের ধাপের জন্য API (সব আগের সাথে সামঞ্জস্যপূর্ণ; শুধু নতুন ঘর যোগ হয়েছে)

**GET `/api/v1/credits/state`** — প্ল্যান ও ক্রেডিট স্ক্রিন:
```json
{"balance": 18, "now_usable": 18, "locked": 72, "unlocks_at": "2026-10-29T10:00:00+00:00",
 "negative": false, "blocked": false, "purchase_blocked": false,
 "buckets": {"plan": 18, "pack": 0, "free": 0, "rewarded": 0, "referral": 0, "legacy": 0, "debt": 0},
 "plan_expires_at": "2026-11-27T10:00:00+00:00",
 "unlock_pct": 20, "unlock_hours": 48, "refund_window_hours": 48, "server_time": "…"}
```
অ্যাপের লেখা: "এখন ১৮ ক্রেডিট, আরও ৭২টি ২ দিনে খুলবে" / "18 credits now, 72 more unlock in 2 days" (`locked`, `unlocks_at`)। `blocked: true` হলে: "রিফান্ডের কারণে ব্যালান্স শূন্যের নিচে — ক্রেডিট-ফিচার বন্ধ"।

**GET `/api/v1/credits/refunds`** — রিফান্ড স্ক্রিন:
```json
{"window_hours": 48, "policy": {"window_hours": 48, "url": "/refund-policy", "text": "…বাংলা বা English…"},
 "purchases": [{"id": 12, "channel": "play", "order_ref": "…00000", "sku": "premium_monthly", "kind": "sub",
   "plan": "premium", "price": "199.00", "currency": "BDT", "test": false,
   "purchased_at": "…", "window_ends_at": "…", "eligible": true, "reason": "", "request": null}],
 "requests": [{"id": 3, "status": "pending|approved|manual|rejected", "order": 12, "requested_at": "…",
   "decided_at": null, "note": "", "approved_amount": "0.00"}]}
```
"রিফান্ড চান" বোতাম শুধু `eligible: true` সারিতে; না হলে `policy.text` দেখান।

**POST `/api/v1/credits/refunds`** `{"purchase_id": 12, "reason": "…"}` → `201 {"ok": true, "request": {...}}` অথবা `409 {"ok": false, "reason": "outside_window|already_requested|not_refundable", "message": "…", "policy": {...}}` (404 = অন্যের বা নেই)।

**আগের API-তে নতুন ঘর:** `/payments/state` → `credits_state`; `/payments/config` → `purchase_blocked`, `refund_policy`, আর blocked হলে `purchasable: false`; `/credits/history` → `credits_state` আর প্রতিটি লেজার সারিতে `bucket`; `/payments/play/verify` নতুন কারণ `unbound_purchase` (409); `/plans/trial/start` নতুন কারণ `trial_used_person` (409, বার্তাসহ); রেফারেল `device_required`। `charge()`-এর ফলাফলে `spend_ref` (আর ঋণ থাকলে `negative: true`)।

অ্যাপের পরের বিল্ডে যা লাগবে (এই ধাপে অ্যাপ বদলানো হয়নি): প্ল্যান/ক্রেডিট স্ক্রিনে now/locked/unlocks_at, রিফান্ড বোতাম + কারণের ঘর (প্ল্যান স্ক্রিন ও সাহায্য), নীতির লিংক (প্ল্যান ও কেনার স্ক্রিন), নেগেটিভ ব্যালান্স ও purchase_blocked-এর বার্তা, `/plans/trial/start`-এ `X-Device-Id` হেডার (ইতিমধ্যে পাঠানো হলে ঠিক আছে), পুরোনো FAQ স্ট্রিং "billing চালু নেই" সরানো।

## ৩. Owner Admin-এর নতুন পাতা
- Payments → **Refund requests** (`/owner/payments/refunds`)
- Payments → **Refund-flagged users** (`/owner/payments/flagged`) — আনব্লক বোতাম
- Payments → **Billing reports** (`/owner/payments/reports`) — reconcile, voided poll, credits verify, Profit Guard, entitlements audit
- Payments → **Unverified plans and credits** (`/owner/payments/unverified`)
- Payments পেজ: আসল দামের কেনাকাটা টেবিল + বাংলা লেবেলের পেমেন্ট অডিট
- Users → ইউজার: বাকেট, মিলছে কি না, পুরো লেজার, দেওয়া প্ল্যান (Play রিভিউয়ার আলাদা ট্যাগ), রিফান্ড-ফ্ল্যাগ
- Overview / P&L: Paid (যাচাই করা) · টেস্ট · ট্রায়াল · দেওয়া
- Pricing & plans → `billing` অংশ: unlock %, unlock ঘণ্টা, রিফান্ড উইন্ডো (২৪/৪৮), Profit Guard সীমা ও পুশ; `limits` অংশে ট্রায়ালের সেটিং — সবকিছুর বাংলা/ইংরেজি নাম

## ৪. Cron লাইন (মালিক `/etc/cron.d/assisto-app`-এ যোগ করবেন; integrator পারে না)
```
# billing-v2: daily voided poll + reconcile + credits verify + per-user Profit Guard
40 3 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py billing_daily >> /home/ubuntu/assisto/backend/logs/billing_daily.log 2>&1
# billing-v2: daily settle + trailing-7-day guard (now safe: packs never expire)
5 0 * * * ubuntu cd /home/ubuntu/assisto/backend && nice -n15 /home/ubuntu/assisto/.venv/bin/python manage.py profit_guard_rollover >> /home/ubuntu/assisto/backend/logs/profit_guard_rollover.log 2>&1
```
আগের `payments_sweep` (প্রতি ঘণ্টা) থাকবে — এটা এখন ধাপে আনলক আর মেয়াদ পার হওয়া প্ল্যান-ক্রেডিটের expire-ও করে (#২০/#২৩-এর ট্রায়াল ক্রেডিট ২৯ অক্টোবর এভাবেই expire হবে, rebuild চালানোর পরে)।
সময় সার্ভারের টাইমজোনে; Asia/Dhaka হলে ৩:৪০ রাত।

## ৫. Deploy-এর ধাপ (integrator)
1. **ব্যাকআপ:** DB-র পুরো ব্যাকআপ (migration kit-এর backup)।
2. কোড merge + `manage.py migrate` (শুধু `0095_billing_v2`, additive)। ব্যাকএন্ড restart।
   - migrate-এর পরে কেউ খরচ করলে তার পুরোনো ব্যালান্স সাময়িকভাবে `legacy` লটে থাকে — ব্যালান্স বদলায় না।
3. `manage.py credits_rebuild_buckets --dry-run` → প্রতিটি ইউজারের আগে/পরে দেখুন। প্রত্যাশা: **#৩: ১৩০ → ৪০** (adjust −90); #২৫: plan 90 থাকবে (রিভিউয়ারের চলতি মাস); শেষ হয়ে যাওয়া ট্রায়ালের ক্রেডিট expire হবে (নতুন নিয়ম: ট্রায়ালের ক্রেডিট ট্রায়ালের সাথে শেষ) — #১৮/#১৯-এর মতো ইউজারদের সংখ্যা কমতে পারে, dry-run-এ মালিক দেখে নেবেন; #২০/#২৩-এর ট্রায়াল ক্রেডিট ২৯ অক্টোবর পর্যন্ত থাকবে।
4. মালিক দেখে ঠিক বললে: `manage.py credits_rebuild_buckets` (এক transaction প্রতি ইউজার, আবার চালালে কিছু হয় না)।
5. `manage.py credits_verify` → ০ mismatch।
6. `manage.py entitlements_audit --fix --dry-run` → #২৫ = play_reviewer; তারপর `--fix` (শুধু জানা গ্রান্ট লেখে)।
7. মালিক cron লাইন দুটি যোগ করবেন।
8. Play Console: RTDN-এর মতোই Voided Purchases API-র জন্য আলাদা কিছু লাগে না (একই service account, "View financial data" অনুমতি লাগে — না থাকলে দিন)। রিফান্ড API-র জন্য "Manage orders and subscriptions" অনুমতি লাগে।

## ৬. টেস্ট
- নতুন: `core/tests_billing2.py` (A–V প্রতিটি নিয়মের ক্লাস + সংযোজন: concurrency, RTDN retry/restore/double verify, সব state, upgrade/downgrade, ৪৭:৫৯ বনাম ৪৮:০১, প্রস্তাবের হিসাব, নেগেটিভ ব্লক, দ্বিতীয় রিফান্ডে ব্লক, voided poll, reconciliation, #৩-এর rebuild dry-run, ট্রায়াল প্রতি ব্যক্তি একবার, Paid সংখ্যা), `web/tests_billing2.py` (Owner Admin পাতা)।
- পুরোনো টেস্ট যেগুলো পুরোনো নিয়ম ধরে ছিল (payload বিশ্বাস করা, প্যাক কখনো নেগেটিভ নয়, প্যাক expire, ক্যালেন্ডার মাস, aid ছাড়া প্রথমজন পায়, ad wallet আলাদা) — নতুন নিয়মে হালনাগাদ করা হয়েছে, প্রতিটিতে কারণ লেখা।
- ফলাফল: রিপোর্টে।

## ৭. জানা সীমা
- Play Console থেকে **আংশিক** রিফান্ড API দিয়ে হয় না — পাতায় ধাপ ও পরিমাণ দেখায়; মালিক Console-এ করবেন।
- EPS-এর রিফান্ড API আমাদের gateway কোডে নেই — হাতের ধাপ দেখায়।
- `orders.get` (আসল দেওয়া দাম) Google না দিলে তালিকার দাম / ক্যাটালগের দাম বসে, `price_source` কলামে লেখা থাকে।
- Play-তে purchase_blocked ইউজার Google-এ কিনে ফেললে টাকা দিয়েছেন বলে ক্রেডিট পান; ব্লক কাজ করে অ্যাপের বোতাম (`purchasable: false`) আর EPS checkout-এ।
- SQLite টেস্টে row lock নেই; concurrency টেস্ট "কখনো দ্বিগুণ খরচ নয় ও ব্যালান্স = লেজার" প্রমাণ করে; আসল lock Postgres-এ `select_for_update`।
