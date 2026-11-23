# HalalAdz ইন্টিগ্রেশন (Assisto) — মালিকের জন্য সংক্ষেপে

শাখা: `ci/halaladz` · মাইগ্রেশন: `core/migrations/0174_halaladz.py` (লাইভ DB-তে এখনো চালানো হয়নি)

## ১. কী তৈরি হলো
1. **অফিসিয়াল HalalAdz কমিউনিটি** — নতুন কোনো আলাদা সিস্টেম নয়; Assisto-র আগের চ্যানেল + কমিউনিটি ব্যবস্থাই ব্যবহার হয়েছে।
   - ঘোষণা চ্যানেল "HalalAdz কমিউনিটি" (@halaladz): শুধু আপনি পোস্ট করবেন, সদস্যরা পড়বে ও রিঅ্যাক্ট দেবে; চ্যানেলটি "ভেরিফায়েড/অফিসিয়াল" চিহ্নিত।
   - কমিউনিটি "HalalAdz কমিউনিটি": ঘোষণা গ্রুপ + আলোচনা গ্রুপ "HalalAdz কমিউনিটি" (আপনি অ্যাডমিন, ভেতরে আসল My Circle গ্রুপ চ্যাট)।
   - দুটোরই ইনভাইট লিংক আছে; QR: অ্যাপে চ্যানেল/কমিউনিটি খুলে "Invite" চাপলে লিংক + QR আসে। কমিউনিটি লিংকে যোগ দিতে চাইলে আগের নিয়মে আপনার (অ্যাডমিন) অনুমতি লাগে।
2. **HalalAdz সাপোর্ট চ্যাট** — যেকোনো ব্যবহারকারী লেখা, ছবি বা ভয়েস পাঠাতে পারে। আগের SupportTicket-ই বাড়ানো হয়েছে (topic = halaladz)। ছবি/ভয়েস সাইন করা, মেয়াদি লিংকে থাকে (কখনো খোলা /media নয়)।
   - আপনার ইনবক্স: Owner Admin → **HalalAdz সাপোর্ট** (`/owner/halaladz-support`): না-পড়া সংখ্যা, খোলা/সমাধান ফিল্টার, ছবি দেখা, ভয়েস শোনা, দ্রুত উত্তর বোতাম, নিজে লেখা উত্তর, "সমাধান হয়েছে" চিহ্ন। আপনার উত্তর ব্যবহারকারীর ফোনে নোটিফিকেশন হয়ে যায়।
3. **HalalAdz অ্যাকাউন্ট যুক্ত করা** — Settings → "HalalAdz অ্যাকাউন্ট যুক্ত করুন": ৮ অক্ষরের কোড লিখে, অথবা লিংক `assisto://link-halaladz?code=CODE` খুললে কোড নিজে বসে যায় (ব্যবহারকারী তবু নিজে "অ্যাকাউন্ট যুক্ত করুন" চাপে)। যুক্ত অ্যাকাউন্টের নাম দেখায়, "সংযোগ বিচ্ছিন্ন করুন" আছে। কোডের ধরন সার্ভারেও যাচাই, ১০ মিনিটে ৫ বার / দিনে ২০ বার সীমা, বাইরের কলে ৮ সেকেন্ড টাইমআউট, বাংলায় সৎ ত্রুটি-বার্তা।
4. **HalalAdz থেকে নোটিফিকেশন** — `POST https://api.lifeassisto.com/api/integrations/halaladz/notify`: স্বাক্ষর মিললে অ্যাপে নোটিফিকেশন + পুশ (ব্যবহারকারীর ভাষায়), চাপলে শুধু নিরাপদ https লিংক (halaladz.com / lifeassisto.com) খোলে।
   - নোট: Assisto-র বাকি সব API `/api/v1/` এর নিচে; এই একটি ঠিকানা অর্ডার অনুযায়ী হুবহু `/api/integrations/halaladz/notify`।
5. **সিক্রেট না থাকলে পুরো ফিচার বন্ধ**: লিংক/নোটিফাই/সাপোর্ট API 503 দেয়, Settings-এ টাইলই দেখা যায় না। কমিউনিটি কমান্ড সিক্রেট ছাড়াও চলে। HalalAdz ব্যবহারে Assisto লাগবে — এমন কিছু কোথাও বলা নেই।

## ২. সিক্রেট সেট করার ধাপ (আপনি নিজে করবেন — চ্যাটে কখনো সিক্রেট পেস্ট করবেন না)
1. SSH দিয়ে সার্ভারে ঢুকুন।
2. সিক্রেট ফাইলে একটি লাইন যোগ করুন (মান = HalalAdz সার্ভারের `HZ_ASSISTO_SECRET`-এর হুবহু একই মান):
   `nano /home/ubuntu/.assisto_secrets.env` → নতুন লাইন: `HALALADZ_SHARED_SECRET=<একই মান>` → সেভ।
3. `chmod 600 /home/ubuntu/.assisto_secrets.env`
4. Claude-কে শুধু বলুন: "HalalAdz secret দিয়েছি, মাইগ্রেশন চালিয়ে রিস্টার্ট করো।" (মাইগ্রেশন `0174_halaladz` + সার্ভিস রিস্টার্ট Claude করবে।)

## ৩. কমিউনিটি কমান্ড (মাইগ্রেশনের পরে, একবার; আবার চালালেও কিছু ডুপ্লিকেট হয় না)
`cd /home/ubuntu/assisto/backend && ../.venv/bin/python manage.py halaladz_community --owner <আপনার ইউজার আইডি বা ফোন নম্বর>`
- চ্যানেলকে পাবলিক ডিরেক্টরিতেও দেখাতে চাইলে শেষে `--public` যোগ করুন।
- কমান্ড চ্যানেল ও কমিউনিটির লিংক প্রিন্ট করে।

## ৪. দুই ফোনে পরীক্ষা (মালিক)
1. ফোন A (আপনি): কমান্ড চালানোর পর অ্যাপে চ্যানেল খুলে Invite → QR দেখান।
2. ফোন B: QR স্ক্যান করে চ্যানেল ফলো করুন; A একটি পোস্ট দিন → B-তে নোটিফিকেশন আসছে কিনা দেখুন।
3. ফোন B: Settings → "HalalAdz অ্যাকাউন্ট যুক্ত করুন" → সাপোর্টে একটি লেখা, একটি ছবি, একটি ভয়েস পাঠান।
4. A: Owner Admin → HalalAdz সাপোর্ট → না-পড়া ৩ দেখুন, ছবি/ভয়েস খুলুন, একটি দ্রুত উত্তর দিন → B-তে নোটিফিকেশন ও উত্তর আসছে কিনা দেখুন → "সমাধান হয়েছে" চাপুন।
5. HalalAdz থেকে একটি আসল ৮ অক্ষরের কোড নিয়ে B-তে যুক্ত করুন → নাম দেখাচ্ছে কিনা → "সংযোগ বিচ্ছিন্ন করুন"।

---

## 5. Signature spec for the HalalAdz developers (English)

Shared secret: the same value on both servers — `HZ_ASSISTO_SECRET` (HalalAdz) = `HALALADZ_SHARED_SECRET` (Assisto). Signatures are **lowercase hex HMAC-SHA256**. Timestamps are **Unix seconds (UTC)**; the allowed clock skew is **±300 s (5 minutes)** in both directions. Bodies are UTF-8 JSON; always sign the **exact raw bytes** you send / receive.

### 5.1 Assisto → HalalAdz: link an account
`POST https://api.halaladz.com/v1/integrations/assisto/link`

Headers:
```
Content-Type: application/json
X-Assisto-Timestamp: <unix seconds>
X-Assisto-Signature: hex(HMAC_SHA256(secret, "<timestamp>" + "." + <raw body>))
```
Body (compact JSON): `{"code":"<8 chars A-Z 0-9, upper case>","assisto_user_id":"<string>"}`

HalalAdz must: check the timestamp is within ±300 s, recompute the signature over `<ts>.<raw body>` with a constant-time compare, check the code (single use, short expiry), then answer:
- `200 {"hz_account_id": "<stable id, max 64 chars>", "display_name": "<name shown in Assisto, max 120>"}`
- `400 / 404 / 410 / 422` → code wrong or expired · `409` → this HalalAdz account is already linked to another Assisto account · `429` → too many tries · anything else / no answer within 8 s → Assisto shows "try again later".

Keep `assisto_user_id` with the HalalAdz account: notifications are addressed with it.

Example (dummy secret `test-secret-123`, timestamp `1764000000`):
```
raw body : {"code":"AB12CD34","assisto_user_id":"1234"}
signed   : 1764000000.{"code":"AB12CD34","assisto_user_id":"1234"}
signature: 0589adca3670a07e551121156f8819e1caa639d752570175dc528eac04702d0e
```

### 5.2 HalalAdz → Assisto: send a notification
`POST https://api.lifeassisto.com/api/integrations/halaladz/notify` (exact path — not under `/api/v1/`)

Headers:
```
Content-Type: application/json
X-HZ-Signature: hex(HMAC_SHA256(secret, <raw body>))      ("sha256=<hex>" is also accepted)
```
Body (max 16 KB):

| field | required | rule |
|---|---|---|
| `event_id` | yes | 1–80 chars `[A-Za-z0-9_.:-]`, unique per event — a repeat is answered `200 {"status":"duplicate"}` and NOT shown again (safe retries) |
| `timestamp` | yes | Unix seconds when the event was sent; rejected if more than 300 s old or ahead |
| `assisto_user_id` | yes | the id Assisto sent in the link call |
| `hz_account_id` | no | if sent, must match the linked account |
| `title_bn` / `title_en` | yes (at least one) | or `title` as a string or `{"bn":..,"en":..}`; a missing language copies the other. Max 200 chars |
| `body_bn` / `body_en` | no | same rules as title (or `body`) |
| `url` | no | **https only**, host `halaladz.com` / `lifeassisto.com` or a subdomain, no user@, port 443, max 500 chars — anything else → `400 bad_url` |
| `type` | no | free label ≤ 40 chars (e.g. `order`, `message`) |

Answers: `200 {"status":"delivered"|"duplicate","event_id":..}` · `400 bad_json / bad_event_id / bad_title / bad_url` · `401 bad_signature` / `401 stale` · `404 {"detail":"not_found"}` (no such user, not linked, or unlinked — the same answer every time; stop sending for that user) · `413` body too big · `503 disabled` (secret not set on Assisto).

Assisto shows it in the notification centre and as a push in the user's chosen language (Bangla by default); tapping opens `url` in the browser.

Example (dummy secret `test-secret-123`; the body is the exact compact UTF-8 bytes below, Bangla not escaped):
```
{"event_id":"evt_20261123_0001","timestamp":1764000000,"assisto_user_id":"1234","hz_account_id":"hz-901","type":"order","title_bn":"নতুন অর্ডার","title_en":"New order","body_bn":"আপনার বিজ্ঞাপনে নতুন অর্ডার এসেছে","body_en":"A new order on your ad","url":"https://halaladz.com/orders/55"}
X-HZ-Signature: a431261d29400de21225bd429ae5f736e2b8705e9797470a3f179ae01c6057c0
```
(With a real event use the current time — `1764000000` is old and would be refused as `stale`.)

### 5.3 Unlink
Unlink is done in Assisto (Settings). After it, notify calls for that user answer `404 not_found`. No call is made to HalalAdz on unlink.
