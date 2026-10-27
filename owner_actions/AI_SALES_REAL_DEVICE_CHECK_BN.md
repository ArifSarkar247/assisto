# AI সেলস অ্যাসিস্ট্যান্ট — ১০ মিনিটের আসল ফোন চেক (Meta টেস্ট নম্বর + Messenger টেস্ট Page)

কবে চালাবেন: যখন হাতে ফোন আর Meta ডেভেলপার অ্যাকাউন্ট আছে। কোনো App Review লাগে না — WhatsApp-এর ফ্রি **টেস্ট নম্বর** আর **development mode**-এর Messenger Page দিয়ে পুরোটা চলে (শুধু আপনি যাদের Tester বানাবেন, তারাই মেসেজ পাঠাতে পারবে)।

সার্ভারে আগে থেকেই যা পরীক্ষা করা আছে: `backend/core/tests_e2e_sales.py` (Meta-র আসল payload আকারে webhook → উত্তর → Graph API-তে ঠিক কোন body যায় — সব যাচাই; নেটওয়ার্ক শুধু নকল)। এই চেক দেখায় আসল Meta-তেও একই জিনিস হয়।

> ⚠️ App Secret, টোকেন বা পাসওয়ার্ড চ্যাটে/ইমেইলে/GitHub-এ দেবেন না। App Secret যায় শুধু **Owner Admin → Integrations**-এ; টোকেন যায় শুধু অ্যাপের **চ্যানেল যুক্ত করুন** ফর্মে।

## আপনার কাজ — শুধু যা আমি নিজে করতে পারি না

1. **Meta app বানান** (আপনার Facebook/Business অ্যাকাউন্ট লাগে): developers.facebook.com → Create App → Business → App settings → Basic থেকে **App ID** + **App Secret** কপি।
2. **verify token** বানান (লম্বা র‍্যান্ডম লেখা) → **Owner Admin → Integrations → "Meta app"**-এ App ID, App Secret, verify token → Save।
3. **WhatsApp টেস্ট নম্বর**: app-এ WhatsApp যোগ → API Setup-এ নিজের ফোন নম্বর **To** তালিকায় যোগ করে OTP দিয়ে যাচাই → **Phone number ID** + **token** কপি → Configuration-এ Callback URL `https://api.lifeassisto.com/api/v1/bizagent/webhook/whatsapp` + verify token → Verify and save → `messages` Subscribe।
4. **Messenger টেস্ট Page**: app-এ Messenger যোগ → Callback URL `https://api.lifeassisto.com/api/v1/bizagent/webhook/meta` + একই verify token → Page যোগ করে **Page token** + **Page ID** কপি → App roles-এ গ্রাহক-অ্যাকাউন্টকে **Tester** বানান (সেই অ্যাকাউন্ট থেকে Accept)।
5. **Assisto অ্যাপে** (বিক্রেতা অ্যাকাউন্ট): একটি পণ্য (দাম + সর্বনিম্ন দাম + স্টক) রাখুন → এজেন্ট সেটআপে WhatsApp (Phone number ID + token) আর Facebook Page (Page ID + Page token) যুক্ত করুন।
6. **ফোনে ভাগ ৪-এর ৯টি মেসেজ** পাঠিয়ে মিলিয়ে নিন (১০ মিনিট)।
7. শুধু আসল গ্রাহকের জন্য (লঞ্চের পরে): Business verification-এর কাগজ, App Review জমা (স্ক্রিন রেকর্ডিং), নিজের আসল WhatsApp নম্বর, WhatsApp Manager-এ পেমেন্ট কার্ড — নিচের শেষ অংশ দেখুন।

বাকি সব (webhook সই যাচাই, উত্তর, দরদাম, অর্ডার, COD, ২৪ ঘণ্টার নিয়ম, STOP, সীমা, ক্রেডিট, WABA সাবস্ক্রিপশন) কোডে করা ও টেস্টে যাচাই করা।

## আমাদের webhook ঠিকানা (হুবহু কপি করুন)

| কোথায় | Callback URL |
|---|---|
| WhatsApp → Configuration → Webhook | `https://api.lifeassisto.com/api/v1/bizagent/webhook/whatsapp` |
| Messenger → Messenger API Settings → Webhooks | `https://api.lifeassisto.com/api/v1/bizagent/webhook/meta` |

পুরোনো `/api/v1/webhook/whatsapp` ঠিকানাটি **ব্যবহার করবেন না** (ওটা পুরোনো খালি স্টাব)। দুটো ঠিকানাতেই verify token একই।

---

## ভাগ ১ — Meta app বানানো (একবারই, ~৩ মিনিট)

1. developers.facebook.com → **My Apps → Create App** → Use case: **Other** → টাইপ **Business** → নাম `Assisto Sales Test` → আপনার Business portfolio → **Create app**।
2. **App settings → Basic** → **App ID** আর **App Secret** (Show চাপুন) কপি করুন। Privacy Policy URL: `https://lifeassisto.com/privacy` → Save।
3. নিজের একটি **verify token** বানান — যেকোনো লম্বা র‍্যান্ডম লেখা, যেমন সার্ভারে `openssl rand -hex 24`। লিখে রাখুন।
4. **Owner Admin → Integrations → "Meta app (Business AI Agent webhooks)"** → App ID, App Secret, Webhook verify token দিন → **Save**। (Graph API version খালি রাখুন = v23.0)
   - এখানে Phone number ID বা WABA ID লাগে না: Phone number ID দেবেন অ্যাপের চ্যানেল ফর্মে (ভাগ ২-এর ধাপ ৭), আর WABA ID সার্ভার টোকেন থেকে নিজেই খুঁজে নেয় (`debug_token`) এবং নিজেই সাবস্ক্রাইব করে।

## ভাগ ২ — WhatsApp টেস্ট নম্বর (~৩ মিনিট)

1. App Dashboard → **Add product → WhatsApp → Set up** → Meta একটি ফ্রি **টেস্ট নম্বর** আর একটি টেস্ট WhatsApp Business Account (WABA) দেয়।
2. **WhatsApp → API Setup**:
   - **Phone number ID** কপি করুন (নম্বরটা নয়, এর নিচের লম্বা ID)। **WhatsApp Business Account ID**-ও এখানে দেখা যায় (শুধু রেফারেন্সের জন্য)।
   - **To** → **Manage phone number list** → যে ফোন থেকে "গ্রাহক" সেজে লিখবেন তার নম্বর (+880…) যোগ করুন → WhatsApp-এ আসা কোড দিয়ে যাচাই। (সর্বোচ্চ ৫টি নম্বর।)
   - **Generate access token** → **temporary token** (২৪ ঘণ্টা চলে) কপি করুন। ১০ মিনিটের চেকের জন্য এটাই যথেষ্ট। বেশি দিন চালাতে: business.facebook.com → Business settings → **System users → Add (Admin)** → Assign assets: এই app + WhatsApp account (Full control) → **Generate new token** → `whatsapp_business_messaging`, `whatsapp_business_management` → মেয়াদ **Never**।
3. **WhatsApp → Configuration → Webhook → Edit**: Callback URL = উপরের WhatsApp ঠিকানা, Verify token = ভাগ ১-এর token → **Verify and save**। সবুজ টিক = আমাদের সার্ভার challenge ফেরত দিয়েছে (ভুল token হলে Meta লাল error দেখাবে — সার্ভার 403 দেয়)।
4. একই পাতায় **Webhook fields → Manage → `messages` → Subscribe**।
5. API Setup পাতায় **Send message** চাপুন (Meta-র `hello_world` template) → আপনার ফোনে মেসেজ আসবে। এই চ্যাটেই এখন আপনি গ্রাহক।
6. Assisto অ্যাপে **একটি বিক্রেতা অ্যাকাউন্ট** (ব্যবসা মোড) → **ব্যবসা → পণ্য**-এ একটি পণ্য রাখুন: নাম `Panjabi`, দাম `1200`, **সর্বনিম্ন দাম `1000`**, স্টক `10`। ডেলিভারি চার্জ: ঢাকার ভিতরে `60`, বাইরে `120`।
7. **ব্যবসা → AI সেলস এজেন্ট → এজেন্ট সেটআপ → চ্যানেল → WhatsApp যুক্ত করুন** → Phone number ID + টোকেন → সংরক্ষণ। "যুক্ত হয়েছে" আর নাম `Test Number` দেখাবে। AI চালু রাখুন; ট্রায়াল/প্ল্যান চালু থাকলে AI-লেখা উত্তরও যাবে (নিয়মভিত্তিক উত্তর সবসময় ফ্রি)।

## ভাগ ৩ — Messenger টেস্ট Page (development mode, ~২ মিনিট)

1. একটি Facebook Page লাগবে (নিজের টেস্ট Page বানালেও চলে; আপনি Page-এর admin)।
2. App Dashboard → **Add product → Messenger → Set up** → **Messenger API Settings**:
   - **Configure webhooks**: Callback URL = উপরের Messenger ঠিকানা, Verify token = একই token → **Verify and save**।
   - **Generate access tokens → Add Page** → Page বেছে অনুমতি দিন → Page-এর পাশে **Generate** → Page token কপি করুন।
   - Webhook subscriptions: `messages`, `messaging_postbacks`, `message_echoes` চালু করুন (অ্যাপে Page যুক্ত করলে সার্ভারও নিজে এগুলো সাবস্ক্রাইব করে)।
3. **Page ID**: Page → About → Page transparency, অথবা Messenger API Settings-এ Page নামের নিচে।
4. **Tester যোগ**: App Dashboard → **App roles → Roles → Add People → Tester** → যে Facebook অ্যাকাউন্ট থেকে গ্রাহক সেজে লিখবেন। সেই অ্যাকাউন্ট থেকে developers.facebook.com/requests-এ গিয়ে **Accept**। (development mode-এ শুধু app-এর রোল থাকা মানুষের মেসেজ আসে — এটাই নিয়ম।)
5. Assisto অ্যাপ → **এজেন্ট সেটআপ → Facebook Page যুক্ত করুন** → Page ID + Page token → সংরক্ষণ → Page-এর নাম দেখাবে।

## ভাগ ৪ — টেস্ট কথোপকথন (~২ মিনিট, WhatsApp-এ; Messenger-এ একই লিখে দেখুন)

গ্রাহক-ফোন থেকে টেস্ট নম্বরে/Page-এ এগুলো লিখুন। ডান পাশে যা আসার কথা (দাম আপনার পণ্য অনুযায়ী):

| # | গ্রাহক লিখবেন | আসার কথা |
|---|---|---|
| ১ | `Panjabi er dam koto?` | "আমি দোকানের এআই সহকারী। Panjabi — দাম ৳1200, স্টকে আছে। অর্ডার করতে নাম, মোবাইল নম্বর ও পূর্ণ ঠিকানা লিখুন।" — ২–৩ সেকেন্ডে, AI খরচ ০ |
| ২ | `ki ki product ache?` | "আমাদের পণ্যগুলো:" তারপর প্রতিটি পণ্য আর দাম (`- Panjabi — ৳1200`) — ফ্রি |
| ৩ | `Panjabi 800 taka te diben?` | "এই দামের বিষয়ে আমি দোকানের মালিকের সাথে কথা বলে জানাচ্ছি।" — **৮০০ কখনো মেনে নেয় না**; অ্যাপে **অনুমোদন** তালিকায় "ন্যূনতম দামের নিচে" চিহ্ন, গ্রাহকের লেখা, আর খসড়া উত্তর "দুঃখিত, Panjabi ৳800-এ দেওয়া সম্ভব নয়। এর দাম ৳1200।" (বদলে নিজের অফার লিখতে পারেন); পুশ "অনুমোদন দরকার" |
| ৪ | `panjabi ৯৫০ টাকায় দিবেন? শেষ দাম?` | আবার "মালিকের সাথে কথা বলে জানাচ্ছি" (বাংলা অঙ্কও ধরে) |
| ৫ | `Panjabi 1050 e dile nibo` | "ঠিক আছে, Panjabi ৳1050-এ দিতে পারি।" + "অর্ডার করতে অনুগ্রহ করে জানান: আপনার নাম, মোবাইল নম্বর…" |
| ৬ | `nam: Karim, phone 01712345678, address: House 5, Road 2, Mirpur, Dhaka` | অর্ডারের সারাংশ: `Panjabi × 1 = ৳1050`, ডেলিভারি (ঢাকার ভিতরে) ৳60, **মোট (ক্যাশ অন ডেলিভারি) ৳1110**, "সব ঠিক থাকলে "হ্যাঁ" লিখুন" |
| ৭ | `হ্যাঁ` | "ইনভয়েস #… — দোকানের নাম", লাইন, মোট ৳1110 (ক্যাশ অন ডেলিভারি), "ধন্যবাদ! পার্সেল পাঠানো হলে ট্র্যাকিং জানিয়ে দেব।" — বিক্রেতার ফোনে পুশ **"নতুন অর্ডার — অর্ডার #… — ৳1110"**; অ্যাপে অর্ডার `confirmed`, পেমেন্ট COD, স্টক ১০ → ৯ |
| ৮ | `আপনি কি বট?` | "আমি একজন মানুষ নই — আমি এই দোকানের এআই সহকারী। প্রয়োজনে দোকানের মালিক নিজে উত্তর দেবেন।" |
| ৯ | `STOP` | "ঠিক আছে, আর নিজে থেকে মেসেজ দেব না। প্রশ্ন থাকলে যেকোনো সময় লিখুন।" — এরপর এই গ্রাহককে কোনো ফলো-আপ/অটো মেসেজ যায় না |

অ্যাপে মিলিয়ে দেখুন: **ব্যবসার ইনবক্স**-এ চ্যাটটা আছে; প্রতিটি উত্তরের পাশে "নিয়ম"/"AI"; ৩ নম্বরটির অনুমোদন থেকে **Approve** বা নিজে লিখে পাঠালে গ্রাহক পান। এজেন্ট রিপোর্টে নিয়ম বনাম AI ভাগ।

**ব্যর্থ হলে কী দেখবেন:**
- Verify and save লাল: verify token Owner Admin-এর সাথে হুবহু মেলেনি, বা Meta app Save হয়নি।
- মেসেজ এল কিন্তু উত্তর নেই: Owner Admin-এর App Secret এই app-এর নয় (সই না মিললে সার্ভার 403 দেয়, কিছুই রাখে না) — App settings → Basic থেকে আবার কপি করুন।
- অ্যাপে চ্যাটে উত্তর "ব্যর্থ — (#131030) Recipient phone number not in allowed list": গ্রাহক-ফোনটি ভাগ ২-এর **To** তালিকায় নেই।
- "ব্যর্থ — … (code 190)": টেম্পোরারি টোকেনের ২৪ ঘণ্টা শেষ — নতুন টোকেন দিয়ে চ্যানেল আবার যুক্ত করুন।
- উত্তর "আটকে রাখা (২৪ ঘণ্টার বাইরে)": গ্রাহকের শেষ মেসেজের ২৪ ঘণ্টা পার — WhatsApp-এ শুধু অনুমোদিত template যায় (Meta-র নিয়ম), Messenger-এ কিছুই না।
- Messenger-এ মেসেজ আসে না: লেখক অ্যাকাউন্টটি app-এর Tester নয়/Accept করেনি, বা Page-এ `messages` সাবস্ক্রাইব হয়নি।

---

## আসল গ্রাহকের জন্য (production) — Meta-র যা লাগবে, আর বাস্তব সময়

টেস্ট নম্বর আর development mode শুধু আপনার যোগ করা মানুষের জন্য। সাধারণ গ্রাহকের জন্য:

| কী | কেন | বাস্তব সময় |
|---|---|---|
| **Business verification** (business.facebook.com → Security Center → Start verification: ট্রেড লাইসেন্স/নিবন্ধন, ঠিকানা, `lifeassisto.com` ডোমেইন DNS TXT) | অন্য ব্যবসার Page/নম্বর, বেশি মেসেজ সীমা, App Review-এর পূর্বশর্ত | সাধারণত ২–৫ কর্মদিবস; কাগজ ফেরত দিলে ২ সপ্তাহ পর্যন্ত |
| **App Review → Advanced access**: `pages_messaging`, `pages_manage_metadata`, `pages_show_list`, `pages_read_engagement`, `business_management`, `whatsapp_business_messaging`, `whatsapp_business_management` (+ কমেন্ট উত্তর চাইলে `pages_manage_engagement`); তারপর app **Live mode** | Messenger-এ রোলহীন সাধারণ মানুষের মেসেজের উত্তর আর অন্য বিক্রেতার Page/WhatsApp ব্যবহারে লাগে | প্রতি জমায় সাধারণত ~৫ কর্মদিবস; প্রায়ই ১–২ বার ফেরত → মোট ১–৪ সপ্তাহ। স্ক্রিন রেকর্ডিং (মেসেজ → উত্তর → অনুমোদন → টেকওভার) আর reviewer-এর টেস্ট অ্যাকাউন্ট লাগে |
| **নিজের আসল WhatsApp নম্বর** (WhatsApp Manager → Add phone number; নম্বরটি তখন সাধারণ WhatsApp অ্যাপে চালু থাকতে পারবে না) + **display name অনুমোদন** | টেস্ট নম্বর শুধু ৫টি যাচাই করা নম্বরে লেখে | display name সাধারণত ১–৩ দিন |
| **পেমেন্ট মেথড** (WhatsApp Manager → Payment settings, কার্ড) | ২৪ ঘণ্টার বাইরের template মেসেজের দাম Meta নেয় | কয়েক মিনিট |
| **Message templates** (অর্ডার আপডেট ইত্যাদি utility) | ২৪ ঘণ্টার বাইরে শুধু template | মিনিট থেকে ২৪ ঘণ্টা |
| অন্য বিক্রেতাদের WhatsApp যুক্ত করতে **Tech Provider** অনবোর্ডিং (Embedded Signup) | Meta-র নিয়মে অন্যের WABA-তে ঢুকতে লাগে | business verification-এর পরে ১–২ সপ্তাহ |
| মেসেজিং সীমা | নতুন নম্বর দিনে ~২৫০ ব্যবসা-শুরু করা কথোপকথন; verification ও মানের সাথে বাড়ে | স্বয়ংক্রিয় |

বাস্তব হিসাব: আজ জমা দিলে আসল গ্রাহকের জন্য **২–৪ সপ্তাহ**। তাই ৮ নভেম্বর লঞ্চে দেখানোর পথ: **WhatsApp টেস্ট নম্বর + development mode Page** (এই চেকের মতো), App Review লাগে না। নিজের নম্বর/Page-এ সব মানুষের জন্য চালাতে verification + review শেষ হওয়া পর্যন্ত অপেক্ষা। (Meta মাঝে মাঝে অনুমতির নাম/নিয়ম বদলায় — জমার দিন Meta-র পাতায় মিলিয়ে নিন।)
