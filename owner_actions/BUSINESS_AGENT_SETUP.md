# Business AI Agent চালু করার ধাপ (মালিকের কাজ)

এই ফাইলে আছে Assisto Business AI Agent (F-commerce বিক্রেতাদের জন্য) লাইভ করতে আপনাকে কী কী করতে হবে। কোডের অংশ তৈরি ও টেস্ট করা আছে। নিচের কী আর অনুমোদনগুলো যোগ হলেই আসল মেসেজ আসা-যাওয়া শুরু হবে।

**এখন কী কাজ করে, আর কী অপেক্ষায় আছে**

| অংশ | এখনই কাজ করে | কিসের অপেক্ষায় |
|---|---|---|
| Webhook (সই যাচাই, একই মেসেজ দুবার এলে একবারই ধরা, দ্রুত 200) | হ্যাঁ, self-test দিয়ে প্রমাণ করা যায় (ধাপ ১০) | Meta app-এর App Secret + verify token |
| AI উত্তর (ক্যাটালগের দাম/স্টক, সংখ্যা যাচাই, অনুমোদনের তালিকা, মানুষের হাতে দেওয়া) | হ্যাঁ। Anthropic কী থাকলে আসল AI, না থাকলে নির্দিষ্ট নিয়মে উত্তর | Anthropic কী (আগেই আছে কি না Integrations-এ দেখুন) |
| অর্ডার নেওয়া → আসল Order, স্টক কমে, ইনভয়েস | হ্যাঁ | — |
| Messenger / Instagram / WhatsApp-এ উত্তর পাঠানো | কোড তৈরি (Graph API) | App Review + Business verification + বিক্রেতার টোকেন |
| কুরিয়ার বুকিং + ট্র্যাকিং (Pathao, Steadfast, RedX) | কোড তৈরি, নকল উত্তর দিয়ে টেস্ট করা | বিক্রেতার (বা আপনার) মার্চেন্ট কী |
| বিক্রেতার প্ল্যান কেনা (Starter/Pro) | কোড তৈরি; গেটওয়ে চালু না হলে অ্যাপে "কিনুন" বোতাম লুকানো থাকে | EPS গেটওয়ে কী (PAYMENTS_SETUP.md) |
| ৭ দিনের ফ্রি ট্রায়াল, ক্রেডিট প্যাক | হ্যাঁ | — |
| WhatsApp-এর Meta খরচ বিক্রেতার কাছ থেকে কাটা | কোড তৈরি; রেট ০ থাকা পর্যন্ত কিছু কাটা হয় না | Owner Admin → Sellers-এ Meta-র আসল রেট |

---

## ১. Meta developer app বানান (Business টাইপ)

1. **developers.facebook.com** খুলুন → উপরে ডানে **My Apps** → **Create App**।
2. "What do you want your app to do?" পাতায় **Other** বেছে **Next**, তারপর app type **Business** → **Next**।
3. App name: `Assisto Business Agent`। App contact email: আপনার ইমেইল। Business portfolio: আপনার ব্যবসার Business Manager (না থাকলে আগে business.facebook.com-এ বানান)। **Create app**।
4. বাম মেনু **App settings → Basic**:
   - **App ID** ও **App Secret** (Show চেপে) কপি করুন।
   - **Privacy Policy URL**: `https://lifeassisto.com/privacy`
   - **Terms of Service URL**: `https://lifeassisto.com/terms`
   - **User data deletion**: "Data deletion instructions URL" বেছে দিন `https://lifeassisto.com/delete-account`
   - **App icon** (১০২৪×১০২৪) আর **Category: Business and Pages** দিন → **Save changes**।
5. একটি লম্বা র‍্যান্ডম **verify token** বানান (যেমন সার্ভারে `openssl rand -hex 24`)। এটা নিজের কাছে রাখুন, কাউকে দেবেন না।
6. **Owner Admin → Integrations & keys → "Meta app (Business AI Agent webhooks)"** কার্ডে App ID, App Secret, verify token পেস্ট করে **Save → Test** চাপুন। Graph API version খালি রাখুন (কোড `v23.0` ব্যবহার করে; Meta নতুন ভার্সন চালু করলে এখানে লিখে বদলানো যায়)।

> ⚠️ App Secret কখনো চ্যাটে, ইমেইলে বা GitHub-এ দেবেন না। শুধু Owner Admin-এ।

## ২. App-এ products যোগ করুন

App Dashboard → **Add products to your app**:

1. **Messenger** → Set up।
2. **Instagram** → Set up (Instagram API with Facebook Login — Page-এর সাথে যুক্ত প্রফেশনাল অ্যাকাউন্টের জন্য)।
3. **WhatsApp** → Set up (এটা একটি WhatsApp Business Account আর একটি ফ্রি **টেস্ট নম্বর** দেয়)।
4. **Webhooks** (Messenger/WhatsApp সেটআপের ভেতরেই আসে)।

## ৩. Webhook URL আর verify token বসান

আমাদের সার্ভারের ঠিকানা (Owner Admin → Sellers পাতার নিচেও দেখানো আছে):

| কোথায় | Callback URL | Verify token |
|---|---|---|
| Messenger → Settings → Webhooks (Page) | `https://api.lifeassisto.com/api/v1/bizagent/webhook/meta` | ধাপ ১-এর verify token |
| Instagram → Webhooks | `https://api.lifeassisto.com/api/v1/bizagent/webhook/meta` | একই |
| WhatsApp → Configuration → Webhook | `https://api.lifeassisto.com/api/v1/bizagent/webhook/whatsapp` | একই |

**Verify and save** চাপলে Meta একটি GET পাঠায়; আমাদের সার্ভার verify token মিললে challenge ফেরত দেয়। না মিললে 403।

তারপর কোন ঘটনা আসবে তা subscribe করুন:
- **Page**: `messages`, `messaging_postbacks`, `message_echoes`, `feed` (কমেন্টের জন্য)।
- **Instagram**: `messages`, `comments`।
- **WhatsApp**: `messages` (এতেই ইনবাউন্ড মেসেজ আর delivered/read/failed স্ট্যাটাস আসে)।

প্রতিটি POST-এ Meta `X-Hub-Signature-256` হেডার দেয়; আমাদের সার্ভার App Secret দিয়ে HMAC যাচাই করে। সই না মিললে মেসেজ ফেলে দেওয়া হয় (403)।

## ৪. অনুমতি (permissions) আর App Review

App Dashboard → **App Review → Permissions and features**-এ নিচেরগুলোর জন্য **Advanced access** চাইতে হবে (নাম ২০২৬ সালের Meta অনুযায়ী; জমা দেওয়ার আগে ওই পাতায় নাম মিলিয়ে নিন):

| অনুমতি | কেন দরকার |
|---|---|
| `pages_show_list` | বিক্রেতার Page তালিকা দেখা |
| `pages_messaging` | Messenger-এ গ্রাহককে উত্তর পাঠানো |
| `pages_manage_metadata` | Page-এ আমাদের webhook চালু করা (subscribed_apps) |
| `pages_read_engagement` | Page-এর পোস্ট/কমেন্ট পড়া |
| `pages_manage_engagement` | কমেন্টের নিচে ছোট পাবলিক উত্তর ("ইনবক্সে পাঠানো হয়েছে") |
| `instagram_basic` | Instagram প্রফেশনাল অ্যাকাউন্টের তথ্য |
| `instagram_manage_messages` | Instagram DM-এ উত্তর |
| `instagram_manage_comments` | Instagram কমেন্টের উত্তর (ঐচ্ছিক) |
| `whatsapp_business_messaging` | WhatsApp-এ মেসেজ পাঠানো |
| `whatsapp_business_management` | WhatsApp নম্বর/টেমপ্লেট দেখা |
| `business_management` | বিক্রেতার Business portfolio-র সম্পদ (Page/WABA) অ্যাক্সেস |

প্রতিটি অনুমতির জন্য Meta চায়:
1. **কীভাবে ব্যবহার হয়** তার লেখা (ইংরেজিতে): "Assisto lets small online sellers in Bangladesh answer their own customers' messages with an AI assistant that uses only the seller's own product catalog. The seller connects their Page, sees every conversation, approves risky replies and can take over any chat."
2. **স্ক্রিন রেকর্ডিং**: টেস্ট Page-এ একজন টেস্ট ইউজার মেসেজ পাঠাচ্ছে → Assisto অ্যাপে চ্যাট দেখা যাচ্ছে → AI উত্তর যাচ্ছে → অনুমোদনের তালিকা → "আপনি উত্তর দিচ্ছেন — AI বিরতিতে" সুইচ।
3. টেস্টের জন্য লগইন: Meta-র reviewer-এর জন্য একটি টেস্ট Assisto অ্যাকাউন্ট (ফোন/পাসওয়ার্ড শুধু রিভিউ ফর্মে দেবেন, এখানে নয়)।

> Messenger-এ ২৪ ঘণ্টার নিয়ম: গ্রাহকের শেষ মেসেজের ২৪ ঘণ্টা পরে আমাদের কোড কোনো উত্তর পাঠায় না (অ্যাপে বিক্রেতাকে কারণ দেখায়)। `HUMAN_AGENT` ট্যাগ (৭ দিন) আমরা ব্যবহার করি না, তাই সেই আলাদা অনুমতি লাগবে না।

## ৫. Business verification

1. **business.facebook.com → Settings → Security Center → Start verification**।
2. ট্রেড লাইসেন্স বা ব্যবসার নিবন্ধনের কাগজ, ব্যবসার নাম-ঠিকানা-ফোন (কাগজের সাথে হুবহু মিল থাকতে হবে), আর ডোমেইন `lifeassisto.com` যাচাই (Brand safety → Domains → DNS TXT রেকর্ড)।
3. যাচাই না হওয়া পর্যন্ত Advanced access আর WhatsApp-এর আসল নম্বর পুরোপুরি চালু হয় না।

## ৬. রিভিউ পাস হওয়ার আগে: টেস্ট Page আর টেস্ট ইউজার

App Review পাস না হওয়া পর্যন্ত শুধু app-এ রোল থাকা মানুষ (Admin/Developer/Tester) কাজ করতে পারে:

1. App Dashboard → **App roles → Roles → Add Testers**: যে বিক্রেতারা আগে চেষ্টা করবেন তাদের Facebook অ্যাকাউন্ট যোগ করুন। তারা developers.facebook.com/requests-এ আমন্ত্রণ গ্রহণ করবেন।
2. একটি **টেস্ট Facebook Page** বানান (নিজের), একজন টেস্টার দিয়ে মেসেজ পাঠিয়ে দেখুন।
3. বিক্রেতা অ্যাপে **ব্যবসা → AI সেলস এজেন্ট → এজেন্ট সেটআপ → Facebook Page যুক্ত করুন** খুলে ধাপগুলো দেখবেন: Graph API Explorer-এ Assisto app বেছে Page token বানিয়ে Page ID + টোকেন পেস্ট। সার্ভার টোকেনটি Meta-র সাথে যাচাই করে আসল অবস্থা দেখায় এবং Page-এ webhook চালু করে।
4. টোকেন সার্ভারে এনক্রিপ্ট হয়ে থাকে (INTEGRATIONS_FERNET_KEY), অ্যাপে আর কখনো দেখানো হয় না।

## ৭. WhatsApp: টেস্ট নম্বর → আসল নম্বর

1. **WhatsApp → API Setup**-এ Meta একটি টেস্ট নম্বর দেয়; সর্বোচ্চ ৫টি "To" নম্বরে টেস্ট মেসেজ যায়। এখানে দেখানো **Phone number ID** আর একটি টোকেন দিয়ে অ্যাপে "WhatsApp Business যুক্ত করুন" টেস্ট করা যায়।
2. আসল নম্বর: **WhatsApp Manager → Phone numbers → Add phone number**। নম্বরটি WhatsApp অ্যাপে চালু থাকা যাবে না (আগে অ্যাপ থেকে অ্যাকাউন্ট মুছতে হয়)। Display name ব্যবসার নামের সাথে মিলতে হবে; Meta অনুমোদন করে।
3. **স্থায়ী টোকেন**: Business settings → **System users → Add** (Admin) → Assign assets (WhatsApp account, Full control) → **Generate new token** → app: Assisto Business Agent → `whatsapp_business_messaging`, `whatsapp_business_management` → মেয়াদ: Never।
4. **পেমেন্ট মেথড**: WhatsApp Manager → Payment settings-এ কার্ড যোগ করুন — ব্যবসা-শুরু করা (template) মেসেজে Meta টাকা নেয়।
5. **রেট বসান**: Meta-র বাংলাদেশের রেট (marketing / utility / authentication, ৳-এ) **Owner Admin → Sellers → WhatsApp cost**-এ লিখুন। কোড এর সাথে মার্জিন (৪০%) যোগ করে বিক্রেতার ক্রেডিট থেকে কাটে — একই কথোপকথন/মেসেজে একবারই। রেট ০ থাকা পর্যন্ত কিছু কাটা হয় না এবং পাতায় হলুদ সতর্কতা থাকে। আন্দাজে রেট বসাবেন না।
6. ২৪ ঘণ্টার নিয়ম: গ্রাহকের শেষ মেসেজের ২৪ ঘণ্টা পর শুধু Meta-অনুমোদিত **template** পাঠানো যায় (WhatsApp Manager → Message templates-এ বানিয়ে অনুমোদন নিন)। কোড এই নিয়ম মেনে চলে।
7. ব্যক্তিগত WhatsApp বা WhatsApp Business অ্যাপ কখনো স্বয়ংক্রিয় করা হয় না — শুধু অফিসিয়াল Cloud API।

## ৮. কুরিয়ার মার্চেন্ট অ্যাকাউন্ট

প্রতিটি বিক্রেতা সাধারণত নিজের মার্চেন্ট অ্যাকাউন্ট ব্যবহার করবেন (COD-এর টাকা কুরিয়ার সরাসরি বিক্রেতাকে দেয়; Assisto কখনো টাকা রাখে না)। কী বসানোর জায়গা: অ্যাপে **এজেন্ট সেটআপ → কুরিয়ার**। আপনার নিজের দোকান বা সবার জন্য একটি ব্যাকআপ চাইলে **Owner Admin → Integrations**-এ "Pathao / Steadfast / RedX (owner-level fallback)"।

| কুরিয়ার | অ্যাকাউন্ট | কোন কী, কোথায় পাবেন | আমাদের কোড যে endpoint ডাকে |
|---|---|---|---|
| **Pathao** | merchant.pathao.com-এ মার্চেন্ট অ্যাকাউন্ট | Developer's API → Merchant API Credentials: **Client ID, Client Secret**, মার্চেন্ট **ইমেইল ও পাসওয়ার্ড**, আর **Store ID** (Stores পাতা) | `POST /aladdin/api/v1/issue-token`, `POST /aladdin/api/v1/orders`, `GET /aladdin/api/v1/orders/{id}/info` — live `api-hermes.pathao.com`, sandbox `courier-api-sandbox.pathao.com` |
| **Steadfast** | steadfast.com.bd-এ মার্চেন্ট অ্যাকাউন্ট | portal.packzy.com → API → **API Key** ও **Secret Key** | `POST /api/v1/create_order`, `GET /api/v1/status_by_cid/{id}` — `portal.packzy.com` |
| **RedX** | redx.com.bd-এ মার্চেন্ট অ্যাকাউন্ট | Merchant panel → Developer API → **Access token** (ঐচ্ছিক: Pickup store ID) | `POST /parcel`, `GET /parcel/info/{tracking_id}` — live `openapi.redx.com.bd/v1.0.0-beta`, sandbox `sandbox.redx.com.bd/v1.0.0-beta` |

অ্যাকাউন্ট খোলার সময় কুরিয়ারের দেওয়া ডকুমেন্টে endpoint মিলিয়ে নিন; বদলে গেলে কী-এর সাথে `base_url` দিয়ে বদলানো যায়, কোড বদলাতে হয় না। স্ট্যাটাস প্রতি ৩০ মিনিটে আপডেট হয় (cron), বদল হলে গ্রাহককে মেসেজ যায়; ডেলিভারি হলে বিক্রি (Sale) হিসাবে খাতায় ওঠে।

## ৯. সার্ভারে cron (মূল সেশন বসাবে)

`deploy/p1/bizagent.cron` ফাইলে আছে:
- প্রতি মিনিটে `bizagent_process` (কোনো webhook ঘটনা আটকে থাকলে প্রসেস),
- প্রতি ৩০ মিনিটে `bizagent_couriers` (কুরিয়ার স্ট্যাটাস),
- রাত ৯টায় `bizagent_daily` (দিনের সারাংশ + কম স্টক সতর্কতা)।

## ১০. কী ছাড়াই লাইভ প্রমাণ (self-test)

ডিপ্লয়ের পরে সার্ভারে:

```
cd /home/ubuntu/assisto/backend
../.venv/bin/python manage.py bizagent_selftest_setup --secret "$(openssl rand -hex 24)"
python3 ../tools/p1_webhook_selftest.py --base https://api.lifeassisto.com --secret <SELFTEST_SECRET> --manage ./manage.py
../.venv/bin/python manage.py bizagent_selftest_setup --teardown
```

এটা একটি আলাদা টেস্ট ব্যবসার দুটি "test mode" চ্যানেলে (নকল Page ID আর নকল WhatsApp নম্বর আইডি) সই করা নকল মেসেজ পাঠায়: ভুল সই → 403, দামের প্রশ্ন → ক্যাটালগের দামে উত্তর, একই মেসেজ দুবার → একবারই, অর্ডারের তথ্য → সারাংশ, "yes" → আসল Order। টেস্ট চ্যানেল কখনো Meta-তে কিছু পাঠায় না, আর তার সই-কী দিয়ে আসল কোনো চ্যানেলে মেসেজ ঢোকানো যায় না। শেষে "RESULT: ALL PASSED" দেখাবে।

## ১১. বিক্রেতার প্ল্যান (Owner Admin → Sellers)

- Starter ৳১,৪৯০ / ১,০০০ AI উত্তর, Pro ৳৩,৯৯০ / ৩,০০০ AI উত্তর, ট্রায়াল ৭ দিন / ১০০ উত্তর — সব Owner Admin থেকে বদলানো যায়।
- প্রতিটি পরিবর্তনে কোড যাচাই করে: সব উত্তর ব্যবহার হলেও (প্রতি উত্তর সর্বোচ্চ ৳০.৭২, `ai_sales`) গেটওয়ে ফি বাদে কমপক্ষে ৪০% মার্জিন থাকবে; না থাকলে সংরক্ষণ হয় না।
- Google Play দিয়ে বিক্রি করলে Pro-তে মার্জিন ~৩৬% হয় — পাতায় সতর্কতা দেখায়। তাই বিক্রেতার প্ল্যান শুধু পেমেন্ট গেটওয়ে (EPS) দিয়ে বিক্রি হয়।
- **কিল সুইচ**: Owner Admin → Sellers-এ যেকোনো চ্যানেলের ধরন (Messenger/Instagram/WhatsApp) সবার জন্য একসাথে বন্ধ, অথবা "সব AI উত্তর বন্ধ"। আলাদা বিক্রেতার একটি চ্যানেলও বন্ধ করা যায়।

## ১২. প্রাইভেসি পলিসিতে যোগ করার প্রস্তাব (আপনার সিদ্ধান্ত — আইনি বিষয়)

`https://lifeassisto.com/privacy`-তে একটি অনুচ্ছেদ দরকার, Meta রিভিউ এটা দেখে:

> **Business AI Agent.** When a seller connects a Facebook Page, Instagram account or WhatsApp Business number, Assisto receives that seller's customers' messages and comments from Meta to draft and send replies on the seller's behalf, and stores the conversation, the order details the customer gives (name, phone, delivery address) and the delivery status. This data is used only to serve that seller, is never sold, and is deleted when the seller disconnects and asks for deletion, or on request via https://lifeassisto.com/delete-account. Access tokens are stored encrypted.

বাংলা সংস্করণও একই কথায় যোগ করুন। লেখাটি আপনি অনুমোদন করলে মূল সেশন legal_content-এ বসাবে।
