# সিসিটিভি ব্র্যান্ড-ক্লাউড — ডেভেলপার অ্যাকাউন্টের ধাপ (Imou, EZVIZ, Dahua DoLynk, Hikvision)

## DAHUA DOLYNK NOW (৯ Nov ১৮:৩০, সর্বজনীন পাতা দেখে লেখা)

**আগে সৎ কথা:** DoLynk-এর ইংরেজি ডক (Doc Center) **লগইন ছাড়া খোলে না** — সাইট নিজেই লগইন পাতায় পাঠায়।
আমরা লগইন করি না। তাই নিচের অনেক ঘর "আপনি কনসোলে যা দেখবেন" ধরে লেখা। যেখানে নিশ্চিত নই, সেখানে ✋ চিহ্ন।

### ১) উইজার্ডের চার ধাপ — কী বেছে নেবেন
**ধাপ ১ — Create Product**
- Product name: **Assisto CCTV**
- Product type / category: **Video / Camera (IPC, NVR/DVR)** — "ভিডিও নজরদারি" ধরনের যেটি আছে সেটি। ✋ তালিকায় ঠিক কী নাম, আমাদের জানান।
- Device type: যদি একটিই বাছতে হয় → **NVR/DVR** (দোকানে বেশিরভাগ এটাই); একাধিক বাছা গেলে **IPC + NVR/DVR** দুটোই।
- Access mode বা Scenario চাইলে: **Open IoT** (ARC বা Access Control নয়)।

**ধাপ ২ — Select Service Package**
- বাছুন **Video Service Package** — এতে আছে লাইভ, প্লেব্যাক, লাইভ স্ট্রিম ও স্মার্ট ঘটনার সতর্কতা।
- Device Maintenance, Video Intercom, Access Control প্যাকেজ এখন **লাগবে না** (বাছবেন না)।
- ট্রায়াল: কনসোলে "Free / Trial" লেখা প্যাকেজটিই বেছে নিন। **টাকা লাগে এমন কিছু কিনবেন না, কার্ড দেবেন না।**

**ধাপ ৩ — Develop (Develop Functions)**
- চালু করুন: **Cloud Access** (ডিভাইস যুক্ত ও তালিকা), **Cloud Live** (লাইভ ও প্লেব্যাক), **Cloud Message** (সতর্কতা)।
- Message push / Callback URL চাইলে লিখুন:
  `https://api.lifeassisto.com/api/v1/cctv/dolynk/callback`
  এই ঠিকানা **পরের বিল্ডে চালু হবে**; এখন "Verify" ব্যর্থ হলে ঘরটা ফাঁকা রেখে এগিয়ে যান, পরে বসাবেন।
- মেসেজের ধরন বাছতে বললে: **Motion detection, Human/Vehicle (SMD/IVS), Tamper, Video loss, Disk error, Device offline**।

**ধাপ ৪ — Debug**
- নিজের একটি Dahua ক্যামেরা/NVR (যেটি DMSS-এ আছে) যোগ করুন → ডিভাইস **Online** দেখায় কিনা।
- **Live** চালান → ছবি আসে কিনা। **Playback**-এ গতকালের ৫ মিনিট চালান।
- ক্যামেরার সামনে হাত নাড়ুন → Debug-এ **Message** আসে কিনা।
- চারটি সবুজ হলে আমাদের "DoLynk Debug সবুজ" লিখে জানান (চাবি নয়)।

### ২) শেষে কী চাবি দেখাবে, কোথায় বসাবেন
- সম্ভাব্য: **AppId / AppKey**, **AppSecret**, **Product ID / Product Key**, আর **API ঠিকানা (Region/Endpoint)**। ✋ ঠিক নামগুলো কনসোলে যেমন লেখা, তেমন আমাদের জানান (মান নয়, শুধু নাম)।
- এগুলো **শুধু** Owner Admin → **Integrations → "Dahua DoLynk"** কার্ডে পেস্ট করবেন (কার্ডটি **পরের বিল্ডে** আসছে) → Save → Test connection।
- **চ্যাটে, ফাইলে, স্ক্রিনশটে কখনো নয়।**

### ৩) দোকানদার নিজের Dahua/DMSS ডিভাইস কীভাবে দেবেন
- সর্বজনীনভাবে নিশ্চিত: DMSS-এ **শুধু ডিভাইসের মালিক** শেয়ার করতে পারেন — অ্যাকাউন্ট লিখে বা QR স্ক্যান করে; কোন অধিকার (Live, Alarm Push) দেবেন বাছা যায়; যেকোনো সময় বাতিল করা যায়।
- ✋ Open IoT-এ ডিভাইস যোগের নিয়ম (সিরিয়াল + ডিভাইসের **Verification/Safety Code** দিয়ে বাঁধা, নাকি OAuth, নাকি DMSS share) ডকে লগইনের পিছনে। Doc Center-এ **"How to add devices"** পাতায় যা লেখা, তার শিরোনামগুলো আমাদের জানান।
- আমাদের পরিকল্পনা (Imou-র মতো): অ্যাপে **সিরিয়াল + ডিভাইসের Safety Code** → আমাদের সার্ভার DoLynk-এ বাঁধে। দোকানদারকে কোনো চাবি দিতে হবে না।
- এক ডিভাইস একসাথে দুই প্ল্যাটফর্মে বাঁধা যায় কিনা ✋ — ডকে দেখলে জানান।

### ৪) ট্রায়ালে কী ফ্রি, পরে কত টাকা
- আপনার কনসোলে লেখা: **৩০ দিনের ট্রায়াল**। কোম্পানি যাচাই (AXON Dynamic) করলে **production** খোলে (Dahua বলে ১–২ কর্মদিবস)।
- সর্বজনীন দামের পাতা শুধু **চীনা সংস্করণের** (RMB, আন্তর্জাতিক দাম ✋ নিশ্চিত নয়) — শুধু ধারণার জন্য:
  - ফ্রি সংস্করণ: **১০টি চ্যানেল**, ১–২ Mbps; API-ডাকের সীমা অ্যাকাউন্টে ২০/মিনিট, ডিভাইস-প্রতি ২০/মিনিট, ছবি তোলা ১০০০/দিন; মেসেজ "আংশিক"।
  - পরের ধাপ: ৫০ চ্যানেল ≈ ¥১৬০/মাস, ১০০ চ্যানেল ≈ ¥২৬০/মাস, ৫০০ চ্যানেল ≈ ¥৭৮০/মাস।
  - বাড়তি: ভিডিও ট্রাফিক ≈ ¥২.২/GB; বাড়তি ডিভাইস ≈ ¥১.৫/মাস।
- মানে: **ট্রায়ালে ১০টির মতো চ্যানেল দিয়ে পুরো পরীক্ষা করা যাবে।** টাকা লাগবে দোকানদারের সংখ্যা বাড়লে — তখন ৪০% লাভের নিয়মে দাম ঠিক করব, আগে আপনাকে জিজ্ঞেস করব।

### ৫) যা নিশ্চিত হতে পারিনি — কনসোল দেখে আমাদের শুধু নাম/হ্যাঁ-না জানান
1. Create Product-এ **Product type** তালিকার ঠিক নাম।
2. চাবির ঘরের নাম: **AppId / AppKey / AppSecret / Product ID / API Endpoint** কোনটা কোনটা আছে।
3. Cloud Message-এ **Callback URL** ঘর আছে কিনা, নাকি MQTT/পোলিং।
4. "How to add devices" পাতায় ডিভাইস যোগের পদ্ধতি (Safety Code / OAuth / DMSS share)।
5. ট্রায়ালে চ্যানেল সংখ্যা ও ৩০ দিন পরে কী হয় (Billing / Package পাতায়)।

সূত্র (সর্বজনীন):
- https://open.dolynkcloud.com/ (Doc Center: /platform/develop/doccenter — লগইন লাগে; /package/iot/videoService; /price)
- https://www.dahuasecurity.com/ph/products/software/dolynk-cloud/doylnk-product/eco
- https://www.dahuasecurity.com/ph/products/software/dolynk-cloud/doylnk-product/dmss

## IMOU OAUTH NOW (৯ Nov, Imou-র সর্বজনীন ডক মিলিয়ে হালনাগাদ ১৭:৩০)

**অবস্থা (১৭:১৫):** ফর্ম জমা হয়েছে — প্রজেক্টের নাম **"Assisto Camera Link"**, Callback
`https://api.lifeassisto.com/api/v1/cctv/imou/oauth/callback`, Android-এ Play app-signing কী-র SHA1, iOS bundle `com.assisto.assisto`।
Imou বলেছে "work ticket দিয়ে অনুমতি চান" — **টিকিট ৪৮৩ জমা হয়েছে, অনুমোদনের অপেক্ষা।** ততদিন Owner Admin-এর Imou কার্ডে লেখা থাকে
"Imou-র অনুমোদনের অপেক্ষায় (টিকিট ৪৮৩)", অ্যাপে এক-ট্যাপ বোতাম দেখায় না; সিরিয়াল + Safety Code দিয়ে যুক্ত করা এখনই চলে।
Callback লিংকটি চালু আছে (খুললে একটি পরিষ্কার পাতা দেখায়)। অনুমোদন এলে নিচের ধাপ মতো তিনটি মান পেস্ট করুন।

Imou-র ডক (open.imoulife.com → API reference → Account → OAuth; Concepts → OAuth 2.0 authorization) অনুযায়ী
কনসোলের OAuth মেনুতে **মাত্র তিনটি জিনিস** চায়, তারপর রিভিউ:

| কনসোলের ঘর | যা দেবেন |
|---|---|
| Project logo | Assisto লোগো (রিপোর `logo/` ফোল্ডারের PNG) |
| Project name | `Assisto Camera Link` (জমা দেওয়া নাম; ব্যবহারকারী অনুমতির পাতায় এটাই দেখবেন) |
| Authorization success notification URL (Callback URL) | `https://api.lifeassisto.com/api/v1/cctv/imou/oauth/callback` (শেষে `/` ছাড়া, হুবহু) |

- **Scope:** Imou-র ডকে একটিই scope — `all` (আলাদা টিক-বক্স নেই)। ফর্মে টিক-বক্স দেখালে আগের তালিকামতো দিন:
  ডিভাইস তথ্য, লাইভ, রেকর্ডিং, অ্যালার্ম/মেসেজ (passenger flow সহ), ছবি; **না:** মুছা/হস্তান্তর/শেয়ার/পাসওয়ার্ড।
- **Submit → রিভিউ।** অনুমোদনের পর কনসোল তিনটি মান দেখাবে:
  1. **User Authorization H5 Page** (একটি লিংক)
  2. **Project Access Key** (AK)
  3. **Project Secret Key** (SK)
- এগুলো চ্যাটে/এখানে **লিখবেন না**। Owner Admin → Integrations → **"Imou Open Platform"** কার্ডে তিনটি নতুন ঘর:
  "OAuth Project Access Key", "OAuth Project Secret Key", "OAuth User Authorization H5 Page" → পেস্ট → **Save → Test**।
  তিনটিই থাকলে অ্যাপে "Imou অ্যাকাউন্ট দিয়ে এক ট্যাপে যুক্ত করুন" বোতাম নিজে চালু হয়।
- **কীভাবে চলে:** গ্রাহক বোতাম চাপেন → Imou-র নিজের অনুমতির পাতা → Imou Life অ্যাকাউন্টে লগইন করে "Allow" →
  আমাদের সার্ভার কোড বদলে টোকেন নেয় (Secret Key শুধু সার্ভারে) → তাঁর সব Imou ক্যামেরা তালিকায় আসে → বেছে যোগ।
  টোকেন এনক্রিপ্টেড, শুধু সেই জায়গার (site); ২ ঘণ্টা পরপর নিজে নবায়ন; অনুমতি **৯০ দিন** — শেষ হওয়ার আগে অ্যাপ "আবার যুক্ত করুন" বলবে।
- **সৎ নোট:** (১) Imou ডক H5 পাতায় `state` ফেরত দেয় কিনা বলে না — আমরা `state` + নিরাপদ কুকি দুটোই রাখি, তাই যেভাবেই হোক কাজ করবে।
  (২) OAuth-এ PKCE Imou সমর্থন করে বলে ডকে নেই; Secret Key শুধু সার্ভারে থাকে। (৩) OAuth-এ Imou ডক নিশ্চিতভাবে বলে: ডিভাইস তথ্য,
  অনলাইন, মেসেজ, RTSP লাইভ (`getStreamUrl`)। HLS লাইভ ও প্লেব্যাক OAuth টোকেনে চলে কিনা ডকে স্পষ্ট নয় — আমরা আগে চেষ্টা করি,
  না চললে RTSP লাইভ ও রেকর্ডিং-তালিকা দেখাই। (৪) OAuth-এ খরচ "প্রতি অনুমোদিত ব্যবহারকারী" ধরে, ফ্রি কোটার পর প্রিপেইড ব্যালান্স থেকে কাটে।
- **ফ্রি কোটা পাহারা:** মাসে ৩০,০০০ API কল, ৩০,০০০ মেসেজ, ২ GB ট্রাফিক — Owner Admin-এর Imou কার্ডে এই মাসের ব্যবহার দেখায়;
  ৮০%-এ আপনাকে একবার ইমেইল/নোটিশ, তখন ঐচ্ছিক পোলিং কমে; ১০০%-এ ঐচ্ছিক পোলিং বন্ধ (পুশ সতর্কতা ও লাইভ চলবে)।


**কেন দরকার:** গ্রাহকের পুরনো Hikvision / Dahua / EZVIZ / Imou ক্যামেরা ও DVR Assisto-তে **কোনো পিসি ছাড়াই** দেখাতে —
ডিভাইস তালিকা, লাইভ, প্লেব্যাক, ক্যামেরার নিজের AI সতর্কতা (মানুষ/গাড়ি/রেখা পার), হার্ডডিস্কের অবস্থা।
কোড তৈরি ও নকল সার্ভারে পরীক্ষিত। **যে ব্র্যান্ডের চাবি নেই, সেটি অ্যাপে দেখায়ই না** (মৃত বোতাম নেই)।

**নিয়ম:** চাবি (key / secret) কখনো কোডে, গিটে, চ্যাটে বা STATUS-এ নয় — শুধু **Owner Admin → Integrations**-এ।
সেখানে **Save → Test** চাপুন; সবুজ হলে সেই ব্র্যান্ড অ্যাপে নিজে চালু হয়। লাল হলে বন্ধই থাকে।

গ্রাহক একবার অনুমতি দেন: ক্যামেরা / DVR-এর **সিরিয়াল নম্বর + লেবেলের কোড** লিখে (কোডটি একবার ব্যবহার হয়, কোথাও রাখা হয় না)।
প্রতি জায়গার (site) অনুমতি এনক্রিপ্ট করে রাখা, অন্য জায়গায় খোলে না; "সংযোগ সরান" চাপলে ভেন্ডর থেকেও ডিভাইস ছাড়িয়ে দেয়।

---

## ১) EZVIZ Open Platform — অপেক্ষায়
**এখনকার অবস্থা (৯ Nov):** সাইন-আপ পাতা ৪০৪ দিচ্ছে; আপনি open-team@ezviz.com-এ ইমেইল করেছেন। উত্তর এলে AppKey + Secret শুধু EZVIZ কার্ডে পেস্ট → Save → Test। ততদিন EZVIZ সংযোগ অ্যাপে দেখায় না (কোড তৈরি)।

1. ব্রাউজারে **open.ezvizlife.com** খুলুন → **Sign up** (একটি EZVIZ অ্যাকাউন্ট দিয়ে; ইমেইল যাচাই করুন)।
2. উপরে **Developer Center / Console** → **My Application** → **Create Application** (নাম: `Assisto`, ধরন: Mobile App)।
3. অ্যাপের পাতায় **AppKey** ও **Secret** দেখাবে — কপি করুন।
4. Assisto Owner Admin → **Integrations → "EZVIZ Open Platform"** → AppKey, Secret পেস্ট → **Save → Test**।
5. (ঐচ্ছিক, পরে) রিয়েল-টাইম পুশের জন্য EZVIZ-কে ইমেইল: open-team@ezvizlife.com — "message subscription" আবেদন।
   ততদিন সার্ভার প্রতি মিনিটে সতর্কতা টেনে আনে (আগের মতোই চলবে)।
- খরচ: ডেভেলপার অ্যাকাউন্ট ফ্রি; বড় পরিমাণের কোটা/দাম **যাচাই করা যায়নি** — EZVIZ-কে জিজ্ঞেস করুন।

## ২) Imou Open Platform
1. **open.imoulife.com** → **Register** (Imou Life অ্যাকাউন্ট দিয়েই চলে) → **Developer** হিসেবে যোগ দিন।
2. **App Management → Create App** → নাম `Assisto` → তৈরি হলে **appId** ও **appSecret** দেখাবে।
3. Owner Admin → **Integrations → "Imou Open Platform"** → appId, appSecret → **Save → Test**।
4. কিছু সুবিধার জন্য কোম্পানি যাচাই চাইতে পারে (ট্রেড লাইসেন্স) — চাইলে দিন; সময় **যাচাই করা যায়নি** (সাধারণত কয়েক দিন)।
- যোগাযোগ: cloud_openteam_intl@imou.com

## ৩) Hikvision — Hik-Connect / Hik-Partner Pro OpenAPI (বাংলাদেশে সবচেয়ে বেশি DVR)
1. **tpp.hikvision.com** (Hikvision Technology Partner Program) → **Apply / Register** → কোম্পানির তথ্য দিন
   (নাম, ঠিকানা, ট্রেড লাইসেন্স, ওয়েবসাইট lifeassisto.com, কাজ: "cloud video app for small shops in Bangladesh")।
2. অনুমোদনের পর ডেভেলপার পোর্টালে **Hik-Connect for Teams OpenAPI** (বা Hik-Partner Pro OpenAPI) প্রকল্প খুলুন →
   **AppKey** ও **SecretKey** পাবেন। অঞ্চল (region) জিজ্ঞেস করলে **Asia / Singapore** বা আপনাকে যে ঠিকানা দেয় সেটি নিন।
3. Owner Admin → **Integrations → "Hikvision Hik-Connect OpenAPI"** → AppKey, SecretKey; **API ঠিকানা**-তে পোর্টালে লেখা ঠিকানা
   (যেমন `https://isgp.hik-connect.com`; খালি রাখলে ইউরোপের ঠিকানা ধরা হয়) → **Save → Test**।
4. সাথে সাথে বাংলাদেশের Hikvision ডিস্ট্রিবিউটরকে (যার কাছ থেকে দোকানিরা DVR কেনে) জানান — তারা অনুমোদন দ্রুত করাতে পারে।
- সৎ কথা: অনুমোদনে সপ্তাহ লাগতে পারে; দাম **যাচাই করা যায়নি**। API-র পথগুলো সর্বজনীন ডক থেকে বানানো, আসল অ্যাকাউন্টে এখনো চালানো হয়নি —
  Test সবুজ হওয়ার পর একটি আসল DVR দিয়ে নিচের "আসল পরীক্ষা" করতে হবে।
- অনুমোদন আসার আগেও Hikvision **একই Wi-Fi-তে Guard Box দিয়ে** পুরো চলে (ISAPI: AcuSense সতর্কতা, ডিস্ক, রেকর্ডিং) — কোনো অ্যাকাউন্ট লাগে না।

## ৪) Dahua — DoLynk Open Platform (আপনার পরের ধাপ)
1. Dahua-র **DoLynk Developer** পোর্টালে রেজিস্টার করুন (dahuasecurity.com → Products → DoLynk Cloud → Developer; অথবা বাংলাদেশের
   Dahua ডিস্ট্রিবিউটরের কাছে লিংক চান)।
2. **কোম্পানি যাচাই** করুন (Dahua বলে ১–২ কর্মদিবস) → **Create Application** → **appId** ও **appSecret**।
3. কনসোলে লেখা **API ঠিকানা** (অঞ্চলভিত্তিক) কপি করুন — এটি ছাড়া চালু হবে না (আমরা অনুমান করে কোনো ঠিকানা বসাই না)।
4. Owner Admin → **Integrations → "Dahua DoLynk Open Platform"** → appId, appSecret, API ঠিকানা; ভিডিও/ছবি অন্য ডোমেইনে এলে
   "ভিডিও/ছবির ডোমেইন" ঘরে (যেমন `.example.com`) → **Save → Test**।
- সৎ কথা: DoLynk-এর পদ্ধতির নাম Imou-র মতো ধরে নেওয়া (একই Dahua পরিবার) — কনসোলের ডকে আলাদা হলে আমাদের জানান, এক দিনে বদলানো যাবে।
- অনুমোদন আসার আগেও Dahua **একই Wi-Fi-তে Guard Box দিয়ে** চলে (HTTP API: SMD সতর্কতা, ডিস্ক, রেকর্ড মোড)।

## কোন চাবি কোথায় (সারাংশ)
| ব্র্যান্ড | Owner Admin → Integrations-এর ঘর | কী বসাবেন |
|---|---|---|
| EZVIZ | EZVIZ Open Platform | AppKey, Secret |
| Imou | Imou Open Platform | appId, appSecret (✅ দেওয়া) + OAuth Project Access Key, Secret Key, User Authorization H5 Page |
| Hikvision | Hikvision Hik-Connect OpenAPI | AppKey, SecretKey, (API ঠিকানা) |
| Dahua | Dahua DoLynk Open Platform | appId, appSecret, API ঠিকানা, (ভিডিও ডোমেইন) |

## আসল পরীক্ষা (চাবি সবুজ হওয়ার পর, ১০ মিনিট)
1. Assisto → CCTV → **ব্র্যান্ড ক্লাউড যুক্ত করুন** → ব্র্যান্ড বাছুন → DVR-এর নিচের স্টিকারের **সিরিয়াল + কোড** লিখুন।
2. ডিভাইস তালিকায় সব চ্যানেল দেখা যাচ্ছে কিনা → ২টি ক্যামেরা বেছে **যোগ করুন**।
3. ক্যামেরার সামনে হাঁটুন → ১ মিনিটের মধ্যে ছবিসহ সতর্কতা আসছে কিনা।
4. লাইভ খুলুন; গতকালের ৩০ সেকেন্ডের প্লেব্যাক খুলুন।
5. **দ্বিতীয় ফোনে** (পরিবারের সদস্য, দর্শক) একই সতর্কতা আসছে কিনা; লাইভ অনুমতি না দিলে লাইভ খোলে না কিনা।
6. "সংযোগ সরান" → ব্র্যান্ডের নিজের অ্যাপে ডিভাইস মুক্ত হয়েছে কিনা।
