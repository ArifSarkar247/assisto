# সিসিটিভি ব্র্যান্ড-ক্লাউড — ডেভেলপার অ্যাকাউন্টের ধাপ (Imou, EZVIZ, Dahua DoLynk, Hikvision)

## IMOU OAUTH NOW (৯ Nov, Imou-র সর্বজনীন ডক মিলিয়ে হালনাগাদ ১৭:৩০)

Imou-র ডক (open.imoulife.com → API reference → Account → OAuth; Concepts → OAuth 2.0 authorization) অনুযায়ী
কনসোলের OAuth মেনুতে **মাত্র তিনটি জিনিস** চায়, তারপর রিভিউ:

| কনসোলের ঘর | যা দেবেন |
|---|---|
| Project logo | Assisto লোগো (রিপোর `logo/` ফোল্ডারের PNG) |
| Project name | `Assisto CCTV` (ব্যবহারকারী অনুমতির পাতায় এই নামই দেখবেন) |
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
