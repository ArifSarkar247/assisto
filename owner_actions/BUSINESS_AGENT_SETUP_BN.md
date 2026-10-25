# Business AI Agent — আগে নিজের Page আর নিজের নম্বর (মালিকের ধাপ)

আপনার আদেশ (২৫ অক্টোবর): "আগে নিজের Page আর নম্বর" — অর্থাৎ ব্যবসার মালিক **নিজের** Facebook Page (Messenger) আর **নিজের** WhatsApp নম্বর যুক্ত করবেন; এজেন্ট ২৪/৭ গ্রাহকের উত্তর দেবে; মালিক যেকোনো চ্যাট নিজের হাতে নিতে পারবেন; সব চ্যাট এক "ব্যবসার ইনবক্স"-এ।

এই ফাইলে শুধু আপনার (মালিকের) কাজগুলো আছে। কোড তৈরি ও টেস্ট করা আছে (branch `agent/biz-agent`)। বিস্তারিত পটভূমি, কুরিয়ার, Instagram ইত্যাদির জন্য পুরোনো `owner_actions/BUSINESS_AGENT_SETUP.md` দেখুন।

> ⚠️ কোনো টোকেন, App Secret বা পাসওয়ার্ড চ্যাটে, ইমেইলে বা GitHub-এ দেবেন না। App Secret যায় শুধু Owner Admin → Integrations-এ; Page/WhatsApp টোকেন যায় শুধু অ্যাপের "চ্যানেল যুক্ত করুন" ফর্মে। সার্ভার সেগুলো এনক্রিপ্ট করে রাখে (`INTEGRATIONS_FERNET_KEY`), অ্যাপে আর কখনো দেখায় না।

---

## কী এখনই কাজ করে, কী আপনার ধাপের অপেক্ষায়

| অংশ | অবস্থা | কিসের অপেক্ষায় |
|---|---|---|
| Webhook যাচাই (hub.challenge), `X-Hub-Signature-256` সই যাচাই, একই মেসেজ দুবার এলে একবারই ধরা | কোড + টেস্ট আছে | Meta app-এর App Secret + verify token (ধাপ ১) |
| অটো-উত্তর: শুধু আপনার ক্যাটালগ/দাম/স্টক/ডেলিভারি/সময়/প্রশ্নোত্তর থেকে; অজানা হলে "দোকানের মালিককে জিজ্ঞেস করে জানাচ্ছি"; বানানো দাম কখনো যায় না | কোড + টেস্ট আছে | AI কী না থাকলে নিয়মভিত্তিক উত্তর চলে (খরচ ০) |
| মালিকের টেকওভার → এজেন্ট চুপ; ফেরত দিলে বা নির্দিষ্ট মিনিট চুপ থাকলে এজেন্ট আবার উত্তর দেয় | কোড + টেস্ট আছে | — |
| ব্যবসার ইনবক্স (এজেন্ট / আপনি / আপনাকে দরকার, না-পড়া, খোঁজা, চ্যানেল) + ইনবক্স থেকে উত্তর | কোড + টেস্ট আছে | কমপক্ষে একটি চ্যানেল যুক্ত হলে অ্যাপে দেখা যায় |
| ছবি → খসড়া অর্ডার (ক্যাটালগের ছবির সাথে মিললে; মালিক নিশ্চিত করলে তবেই স্টক কমে) | কোড + টেস্ট আছে | ফ্রি ছবি-মিল ক্যাটালগে ছবি থাকলেই চলে; বর্ণনা-ভিত্তিক মিল (vision) চলে শুধু vision কী থাকলে |
| দৈনিক সীমা: ব্যবসা প্রতি পেইড AI উত্তর (ডিফল্ট ৩০০), প্রতি চ্যাটে এজেন্টের উত্তর (ডিফল্ট ৫০), মিনিটে ৮টির বেশি মেসেজ এলে এজেন্ট থামে | কোড + টেস্ট আছে | মালিক অ্যাপে বদলাতে পারেন |
| অডিট লগ (টেকওভার, ফেরত, মালিকের উত্তর, চ্যানেল যুক্ত/বাদ, সীমা, খসড়া অর্ডার) — টোকেন বা মেসেজের লেখা রাখে না | কোড + টেস্ট আছে | — |
| Messenger/WhatsApp-এ আসল মেসেজ পাঠানো | কোড তৈরি (Graph API) | নিচের ধাপ ১–৫ |

Meta app কনফিগার না হওয়া পর্যন্ত অ্যাপে Page/WhatsApp যুক্ত করার বোতাম **লুকানো** থাকে; কোনো চ্যানেল যুক্ত না হলে ইনবক্সও লুকানো থাকে ("শীঘ্রই আসছে" জাতীয় কিছু দেখানো হয় না)।

---

## ১. Meta app (একবারই, আপনার নিজের)

1. **developers.facebook.com → My Apps → Create App** → "Other" → টাইপ **Business** → নাম `Assisto Business Agent` → আপনার Business portfolio বেছে **Create app**।
2. **App settings → Basic**: App ID আর App Secret কপি করুন। Privacy Policy URL `https://lifeassisto.com/privacy`, Terms `https://lifeassisto.com/terms`, Data deletion `https://lifeassisto.com/delete-account`, Category: Business and Pages → Save।
3. একটি লম্বা র‍্যান্ডম **verify token** বানান (যেমন `openssl rand -hex 24`), নিজের কাছে রাখুন।
4. **Owner Admin → Integrations & keys → "Meta app (Business AI Agent webhooks)"**-এ App ID, App Secret, verify token দিন → **Save → Test**।
5. App Dashboard → **Add products**: **Messenger** আর **WhatsApp** → Set up।

## ২. Webhook — আমাদের সার্ভারের ঠিকানা

| কোথায় বসাবেন | Callback URL | Verify token |
|---|---|---|
| Messenger → Settings → Webhooks | `https://api.lifeassisto.com/api/v1/bizagent/webhook/meta` | ধাপ ১-এর token |
| WhatsApp → Configuration → Webhook | `https://api.lifeassisto.com/api/v1/bizagent/webhook/whatsapp` | একই token |

**Verify and save** চাপলে Meta একটি GET পাঠায়; token মিললে সার্ভার challenge ফেরত দেয়, না মিললে 403।

Subscribe করুন:
- **Page**: `messages`, `messaging_postbacks`, `message_echoes` (Page Inbox থেকে আপনি নিজে উত্তর দিলে এজেন্ট সেই চ্যাটে থামে), `feed` (কমেন্ট, ঐচ্ছিক)।
- **WhatsApp**: `messages` (ইনবাউন্ড মেসেজ + delivered/read/failed স্ট্যাটাস)।

প্রতিটি POST-এ Meta `X-Hub-Signature-256` দেয়; সার্ভার App Secret দিয়ে HMAC-SHA256 যাচাই করে, না মিললে 403 আর কিছুই সংরক্ষণ হয় না। একই message id আবার এলে উপেক্ষা হয়।

## ৩. নিজের Facebook Page যুক্ত করা

**App Review-এর আগেই** নিজের Page-এ পুরো টেস্ট করা যায়, কারণ আপনি app-এর Admin। অন্য ব্যবসার Page-এর জন্য পরে App Review লাগবে (ধাপ ৫)।

1. **Graph API Explorer** (developers.facebook.com/tools/explorer) → Meta App: `Assisto Business Agent` → **User or Page: আপনার Page** → অনুমতি: `pages_show_list`, `pages_messaging`, `pages_manage_metadata`, `pages_read_engagement` → **Generate Access Token**।
2. দীর্ঘমেয়াদি Page token: Access Token Debugger-এ **Extend Access Token** করে long-lived user token নিন, তারপর `GET /me/accounts` থেকে আপনার Page-এর `access_token` (এটি মেয়াদহীন Page token)।
3. Page ID: Page → About → Page transparency, অথবা `/me/accounts`-এর `id`।
4. Assisto অ্যাপ → **ব্যবসা → AI সেলস এজেন্ট → এজেন্ট সেটআপ → Facebook Page যুক্ত করুন** → Page ID + token দিন। সার্ভার token Meta-র সাথে যাচাই করে (Page-এর নাম দেখায়) আর Page-এ webhook চালু করে (`subscribed_apps`)।
5. টেস্ট: অন্য একটি Facebook অ্যাকাউন্ট (app-এ Tester রোল দেওয়া) থেকে Page-এ "পাঞ্জাবির দাম কত?" লিখুন → অ্যাপের **ব্যবসার ইনবক্স**-এ চ্যাট আসবে, এজেন্টের উত্তর ক্যাটালগের দাম দিয়ে যাবে।

## ৪. নিজের WhatsApp নম্বর যুক্ত করা (Cloud API)

1. **WhatsApp → API Setup**: Meta একটি ফ্রি টেস্ট নম্বর দেয় (সর্বোচ্চ ৫টি "To" নম্বরে)। এখানের **Phone number ID** দিয়ে আগে টেস্ট করুন।
2. আসল নম্বর: **WhatsApp Manager → Phone numbers → Add phone number**। নম্বরটি তখন সাধারণ WhatsApp/WhatsApp Business অ্যাপে চালু থাকা যাবে না (আগে অ্যাপ থেকে অ্যাকাউন্ট মুছতে হয়)। Display name ব্যবসার নামের সাথে মিলতে হবে; Meta অনুমোদন দেয়। নম্বর যাচাই SMS/কলে।
3. **স্থায়ী টোকেন**: business.facebook.com → **Business settings → Users → System users → Add** (Admin) → **Assign assets**: WhatsApp account (Full control) আর app → **Generate new token** → app `Assisto Business Agent` → `whatsapp_business_messaging`, `whatsapp_business_management` → মেয়াদ **Never**।
4. Assisto অ্যাপ → **এজেন্ট সেটআপ → WhatsApp Business যুক্ত করুন** → **Phone number ID** (নম্বর নয়) + স্থায়ী টোকেন। সার্ভার নম্বরের verified name দেখিয়ে যাচাই করে।
5. **Message templates** (WhatsApp Manager → Message templates): অন্তত একটি utility template বানিয়ে অনুমোদন নিন (যেমন অর্ডার আপডেট)। গ্রাহকের শেষ মেসেজের ২৪ ঘণ্টা পরে শুধু template পাঠানো যায়; অ্যাপ সেই সময় সাধারণ উত্তর আটকে দেয় এবং কারণ দেখায়।
6. **পেমেন্ট মেথড**: WhatsApp Manager → Payment settings-এ কার্ড যোগ করুন (template মেসেজের খরচ Meta সরাসরি আপনার কার্ড থেকে নেয়)।
7. ব্যক্তিগত WhatsApp কখনো স্বয়ংক্রিয় করা হয় না — শুধু অফিসিয়াল Cloud API।

## ৫. App Review + Business verification (অন্যদের Page/নম্বরের জন্য)

নিজের Page/নম্বরে চালাতে App Review লাগে না। অন্য ব্যবসাকে দিতে হলে:

1. **Business verification**: business.facebook.com → Security Center → Start verification (ট্রেড লাইসেন্স, ঠিকানা, ডোমেইন `lifeassisto.com` DNS TXT)।
2. **App Review → Permissions and features → Advanced access**: `pages_show_list`, `pages_messaging`, `pages_manage_metadata`, `pages_read_engagement`, `business_management`, `whatsapp_business_messaging`, `whatsapp_business_management` (কমেন্ট উত্তর চাইলে `pages_manage_engagement`)। প্রতিটির জন্য ব্যবহারের ইংরেজি বর্ণনা + স্ক্রিন রেকর্ডিং (মেসেজ আসা → ইনবক্স → এজেন্টের উত্তর → "আমি উত্তর দেব" টেকওভার → ফেরত) + reviewer-এর জন্য একটি টেস্ট Assisto অ্যাকাউন্ট (তথ্য শুধু রিভিউ ফর্মে)।
3. জমার আগে Meta-র পাতায় অনুমতির নাম মিলিয়ে নিন (Meta মাঝে মাঝে নাম বদলায়)।

## ৬. খরচ (Meta)

- **Messenger**: Meta মেসেজ পাঠাতে টাকা নেয় না। নিয়ম: গ্রাহকের শেষ মেসেজের পর **২৪ ঘণ্টা** (standard messaging window) উত্তর দেওয়া যায়; তার পরে কোড উত্তর পাঠায় না। আমরা `HUMAN_AGENT` ট্যাগ (৭ দিন) ব্যবহার করি না।
- **WhatsApp Cloud API**: গ্রাহক মেসেজ দেওয়ার ২৪ ঘণ্টার ভেতরে সাধারণ উত্তর (service) ফ্রি। ২৪ ঘণ্টার বাইরে শুধু template; template-এর দাম Meta নেয় **প্রতি delivered মেসেজে**, ধরন অনুযায়ী (marketing / utility / authentication), দেশ অনুযায়ী আলাদা রেট। সঠিক বাংলাদেশ রেট Meta-র "WhatsApp Business Platform pricing" পাতায় দেখুন — আন্দাজে বসাবেন না।
- রেট জেনে **Owner Admin → Sellers → WhatsApp cost**-এ ৳-এ বসালে কোড অন্য বিক্রেতাদের ক্রেডিট থেকে রেট + মার্জিন কাটে। রেট ০ থাকা পর্যন্ত কিছু কাটা হয় না।
- **AI খরচ**: নিয়মভিত্তিক উত্তর (দাম, স্টক, ডেলিভারি, প্রশ্নোত্তর, অর্ডার) খরচ ০। শুধু AI-লেখা উত্তর আর ছবি-বর্ণনা (vision) প্ল্যান/ক্রেডিট খরচ করে, Profit Guard-এ হিসাব হয়, আর দৈনিক সীমা (ডিফল্ট ৩০০) পেরোলে এজেন্ট আর AI ডাকে না — গ্রাহক পান "মালিককে জিজ্ঞেস করে জানাচ্ছি", প্রশ্নটি আপনার অনুমোদনের তালিকায় যায়, আর আপনাকে দিনে একবার জানানো হয়। ক্রেডিট কখনো তোলা যায় না।

## ৭. টেকওভার কীভাবে কাজ করে

1. **ব্যবসার ইনবক্স** খুলুন → যেকোনো চ্যাট → উপরে **"আমি উত্তর দেব"** চাপুন। এখন থেকে ওই চ্যাটে এজেন্ট চুপ; নতুন মেসেজ এলে আপনাকে নোটিফিকেশন যায়।
2. নিচের বক্সে লিখে **পাঠান** — উত্তর আপনার Page/নম্বর থেকেই যায় (২৪ ঘণ্টার ভেতরে)। প্রতিটি উত্তরে "চুপ থাকার ঘড়ি" আবার শুরু হয়।
3. ফেরত দিতে **"AI উত্তর দিক"** চাপুন। অথবা আপনি চুপ থাকলে **এজেন্টের আচরণ → টেকওভার ও সীমা**-তে দেওয়া মিনিট (ডিফল্ট ৬০; ০ = কখনো নিজে ফেরত নয়) পরে এজেন্ট নিজেই আবার উত্তর দেয়, আর গ্রাহক অপেক্ষায় থাকলে তার শেষ মেসেজের উত্তর দেয়। চ্যাটের উপরে দেখায় কখন ফেরত যাবে।
4. Facebook Page Inbox (Meta Business Suite) থেকে আপনি সরাসরি উত্তর দিলেও এজেন্ট ওই চ্যাটে সাময়িক থামে ("মানুষ উত্তর দিলে বিরতি", ডিফল্ট ১৫ মিনিট)।
5. ইনবক্সে প্রতিটি চ্যাটের অবস্থা: **এজেন্ট উত্তর দিচ্ছে** / **আপনি উত্তর দিচ্ছেন** / **আপনাকে দরকার** (অনুমোদন বাকি, পাঠানো ব্যর্থ, এজেন্ট "মালিককে জিজ্ঞেস করছি" বলেছে, বা ছবি থেকে খসড়া অর্ডার)। না-পড়া সংখ্যা, নাম/নম্বর/মেসেজ দিয়ে খোঁজা যায়।
6. **ছবি থেকে অর্ডার**: গ্রাহক পণ্যের ছবি পাঠালে এজেন্ট আপনার ক্যাটালগের ছবির সাথে মেলায়; নিশ্চিত মিল হলে আসল দাম বলে আর একটি **খসড়া অর্ডার** রাখে। চ্যাটে **"অর্ডার নিশ্চিত করুন"** চাপলে তবেই স্টক কমে; **"খসড়া বাতিল করুন"** চাপলে বাতিল। মিল না পেলে এজেন্ট বানিয়ে কিছু বলে না — "দোকানের একজন দেখে জানাবেন" বলে প্রশ্নটি আপনার কাছে পাঠায়।

## ৮. ডেপ্লয়ের আগে যা লাগবে (ইন্টিগ্রেটর)

- মাইগ্রেশন `core/0086_biz_inbox_guard` (এখন `0084_connect_flow`-এর পরে চেইন করা; `0085_admob_placement_stats` মার্জ হলে dependency সেটিতে বদলাতে হবে)।
- প্রতি মিনিটের cron `manage.py bizagent_process` আগে থেকেই আছে; নিষ্ক্রিয় টেকওভার ফেরত দেওয়া এর ভেতরেই চলে।
