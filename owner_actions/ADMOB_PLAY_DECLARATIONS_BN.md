# AdMob — Google Play ও AdMob কনসোলে যা করতে হবে (মালিকের জন্য)

এই বিল্ড থেকে অ্যাপে Google AdMob যুক্ত হয়েছে (শুধু ফ্রি প্ল্যানে)। তাই যে বিল্ডে
এই কাজটি আছে, সেটি Play-তে পাঠানোর **আগে** নিচের ঘোষণাগুলো Play Console-এ
হালনাগাদ করুন। না করলে Play রিভিউ বিল্ড আটকে দিতে পারে।

মনে রাখুন:
- অ্যাপ এখন Google-এর **টেস্ট বিজ্ঞাপন** দেখায়। আসল বিজ্ঞাপন চালু হবে শুধু যখন আপনি
  Owner Admin → Ads → **"আসল AdMob ইউনিট আইডি চালু"** টিক দেবেন (প্রোডাকশন লঞ্চ ও
  AdMob অ্যাপ অনুমোদনের পরে)। নতুন অ্যাপ আপডেট লাগবে না।
- প্রিমিয়াম ও বিজনেস প্ল্যানে কোনো বিজ্ঞাপন নেই।
- SOS, নিরাপত্তা, চুরি-সুরক্ষা, পরিবারের সতর্কতা, কল, চ্যাট, চ্যাট লক, পেমেন্ট, লগইন,
  অনবোর্ডিং ও অনুমতির স্ক্রিনে কখনো বিজ্ঞাপন নেই।
- অ্যাপের manifest-এ এখন `com.google.android.gms.permission.AD_ID` আছে (Google-এর
  বিজ্ঞাপন SDK এটা যোগ করে) — তাই Advertising ID ঘোষণা **হ্যাঁ** হবে।

---

## ধাপ ১ — Play Console → App content → **Ads**

1. Play Console → আপনার অ্যাপ (Assisto) → বাম মেনু **Policy and programs → App content**।
2. **Ads** → **Manage** (বা Start)।
3. "Does your app contain ads?" → **Yes, my app contains ads** বেছে নিন → **Save**।

## ধাপ ২ — App content → **Advertising ID**

1. App content → **Advertising ID** → **Manage**।
2. "Does your app use advertising ID?" → **Yes**।
3. কেন ব্যবহার হয় (purpose) — এগুলো টিক দিন:
   - **Advertising or marketing** (বিজ্ঞাপন দেখানো) — অবশ্যই।
   - **Fraud prevention, security, and compliance** — Google-এর SDK প্রতারণা ঠেকাতে এটা ব্যবহার করে।
   - **Analytics** — শুধু তখনই টিক দিন যদি আপনি AdMob-এর বিজ্ঞাপন রিপোর্ট ছাড়া অন্য কোনো
     বিশ্লেষণে Advertising ID ব্যবহার করেন। Assisto নিজে এই আইডি রাখে না বা বিশ্লেষণে লাগায় না,
     তাই সাধারণত টিক দিতে হবে না।
4. "Does your app target children?" জাতীয় প্রশ্নে আগের মতোই উত্তর রাখুন (Assisto শিশুদের জন্য নয়)।
5. **Save**।

## ধাপ ৩ — App content → **Data safety** (হালনাগাদ)

Play Console → App content → **Data safety** → **Edit**। নিচের পরিবর্তনগুলো করুন, বাকি সব
আগের মতো থাকবে।

**Data collection and security** অংশে:
- "Does your app collect or share any of the required user data types?" → **Yes** (আগের মতোই)।
- "Is all of the user data collected by your app encrypted in transit?" → **Yes**।

**Data types** অংশে যোগ/হালনাগাদ করুন:

| ডেটার ধরন | Collected | Shared | কেন (purpose) | ঐচ্ছিক? |
|---|---|---|---|---|
| **Device or other IDs** (Advertising ID) | হ্যাঁ | **হ্যাঁ — Google AdMob-এর সাথে** | **Advertising or marketing**, **Fraud prevention, security, and compliance** (পুশ টোকেনের জন্য আগের App functionality থাকবে) | বিজ্ঞাপনের অংশ ঐচ্ছিক নয় (ফ্রি প্ল্যানে), তবে প্রিমিয়ামে কোনো বিজ্ঞাপন নেই |
| **App activity → App interactions** (কোন বিজ্ঞাপন দেখা/ট্যাপ হলো) | হ্যাঁ | **হ্যাঁ — Google AdMob** | **Advertising or marketing**, **Analytics** (বিজ্ঞাপনের সমষ্টিগত রিপোর্ট) | — |
| **Location → Approximate location** (IP থেকে আনুমানিক এলাকা) | হ্যাঁ (আগের মতো) | **হ্যাঁ — Google AdMob** | আগের App functionality + **Advertising or marketing**, **Fraud prevention** | — |
| **App info and performance → Diagnostics** | আগের মতো | Google AdMob-ও SDK-র ডায়াগনস্টিক তথ্য পায় | আগের মতো + **Advertising or marketing** | — |

টিপস:
- Google-এর নিজের পাতা "Google Mobile Ads SDK — Data safety / data disclosure" খুলে মিলিয়ে নিন
  (Play Console-এর Data safety ফর্মে SDK-র জন্য Google কী ঘোষণা করতে বলে)।
- "Is data shared?" প্রশ্নে AdMob-এর জন্য **Shared = Yes** দিন; শুধু সার্ভিস প্রদানকারী হিসেবে নয়,
  কারণ Google বিজ্ঞাপনের জন্য নিজে তথ্যটি ব্যবহার করে।
- "Can users request that data is deleted?" → **Yes** (অ্যাপের সেটিংস → আমার অ্যাকাউন্ট মুছুন, এবং
  https://lifeassisto.com/delete-account)। Advertising ID ব্যবহারকারী নিজে Android সেটিংস → গোপনীয়তা →
  বিজ্ঞাপন থেকে মুছতে/রিসেট করতে পারেন।
- শেষে **Save** → **Submit**।

## ধাপ ৪ — গোপনীয়তা নীতি ও ওয়েবসাইট মিলিয়ে নিন

1. Play Console → App content → **Privacy policy** → লিংক: **https://lifeassisto.com/privacy**
   (এই বিল্ডের সাথে নীতি হালনাগাদ হয়েছে: Google AdMob, Advertising ID, UMP সম্মতি, পার্সোনালাইজড বনাম
   নন-পার্সোনালাইজড বিজ্ঞাপন, কীভাবে বন্ধ করবেন, শুধু ফ্রি প্ল্যানে, নিরাপত্তা স্ক্রিনে কখনো নয় —
   তারিখ ২৫ অক্টোবর ২০২৬)। ব্যাকএন্ড ডিপ্লয়ের পর পাতাটি খুলে দেখে নিন।
2. Play Console → **Grow users → Store presence → Store settings** → **Store listing contact
   details → Website** = **https://lifeassisto.com** (ঠিক এই ডোমেইন — AdMob এখান থেকেই
   app-ads.txt খোঁজে)। ভিন্ন থাকলে বদলে **Save**।
3. ব্রাউজারে খুলুন: **https://lifeassisto.com/app-ads.txt** — ঠিক এই লাইনটি থাকতে হবে:
   `google.com, pub-2506398550427515, DIRECT, f08c47fec0942fa0`
   (ব্যাকএন্ড ডিপ্লয়ের পর এটা স্বয়ংক্রিয়ভাবে আসে; nginx-এ কিছু বদলাতে হবে না — `/app-ads.txt`
   আগে থেকেই Django-তে যায়।)
4. AdMob → **Apps → Assisto → App settings → app-ads.txt** → **Check for updates**। "Verified"
   দেখাতে ২৪ ঘণ্টা পর্যন্ত লাগতে পারে।

## ধাপ ৫ — AdMob → **Privacy & messaging** (সম্মতির বার্তা)

অ্যাপ Google-এর UMP সম্মতি ফর্ম দেখায়, কিন্তু ফর্মের লেখা ও নিয়ম AdMob কনসোলে তৈরি করতে হয়।
না করলে ইউরোপে বিজ্ঞাপন আসবে না।

**ক) GDPR বার্তা (ইউরোপ, যুক্তরাজ্য, সুইজারল্যান্ড):**
1. AdMob → বাম মেনু **Privacy & messaging** → **European regulations** (GDPR) → **Create message**।
2. **Apps**: Assisto (Android, App ID `ca-app-pub-2506398550427515~5116255919`) বেছে নিন।
3. **Languages**: English (ডিফল্ট) — চাইলে আরও ভাষা।
4. **User consent options**: "Consent" ও "Do not consent" দুটো বোতামই রাখুন (Google-এর সুপারিশ)।
   "Manage options" থাকবে।
5. **Privacy policy URL**: https://lifeassisto.com/privacy?lang=en
6. **Ad partners**: "Commonly used ad partners" (ডিফল্ট) রাখুন।
7. **Publish**।

**খ) যুক্তরাষ্ট্রের রাজ্যের নিয়ম (US state regulations — CCPA/CPRA ইত্যাদি):**
1. Privacy & messaging → **US state regulations** → **Create message**।
2. Apps: Assisto (Android)।
3. "Do not sell or share my personal information" বার্তাটি চালু রাখুন; Privacy policy URL
   একই দিন।
4. **Publish**।
5. একই পাতায় **Settings** → "Restricted data processing" নিয়ম Google-এর ডিফল্টে রাখুন।

**গ) (ঐচ্ছিক) IDFA/iOS বার্তা** — এই রিলিজে iOS-এ বিজ্ঞাপন নেই, তাই দরকার নেই।

**ঘ) পরীক্ষা:** Owner Admin → Ads → **"Force EEA consent form (testing)"** চালু করে এবং AdMob
ইন্টিগ্রেশনে আপনার টেস্ট ফোনের "UMP test device ID" দিয়ে অ্যাপ খুললে ইউরোপের ফর্মটি দেখা যাবে।
পরীক্ষা শেষে সুইচটি **বন্ধ** করুন। অ্যাপের সেটিংস → **"বিজ্ঞাপনের গোপনীয়তা"** এন্ট্রি শুধু তখনই
দেখা যায় যখন Google বলে এটা দরকার (যেমন ইউরোপে)।

## ধাপ ৬ — AdMob অ্যাপ লিংক ও অনুমোদন

1. AdMob → Apps → Assisto → **App settings** → "App store details" → Google Play-তে অ্যাপটি
   লিংক করুন (Play-তে প্রোডাকশনে প্রকাশ হওয়ার পর)।
2. AdMob "App readiness / Review" শেষ হলে (Ready অবস্থা), এবং প্রোডাকশন লঞ্চের পর:
   Owner Admin → **Ads** → **"আসল AdMob ইউনিট আইডি চালু"** টিক দিন → কারণ লিখুন → **Save**।
   তখন থেকেই সবার ফোনে আসল বিজ্ঞাপন যায় এবং রিওয়ার্ডেড বিজ্ঞাপন (ক্রেডিট/ছবি আনলক) চালু হয় —
   পুরস্কার দেওয়া হয় শুধু Google-এর সার্ভার যাচাই (SSV) করার পর।
3. রিওয়ার্ডেড ইউনিটে SSV চালু করুন: AdMob → Apps → Assisto → **Ad units → Rewarded
   (`ca-app-pub-2506398550427515/2426427676`)** → **Server-side verification** → Callback URL:
   **https://api.lifeassisto.com/api/v1/ads/ssv** → Save → "Verify URL" চাপুন (সার্ভার ২০০ উত্তর দেবে)।

## ধাপ ৭ — বিল্ড পাঠানোর আগে চেকলিস্ট

- [ ] Ads = Yes
- [ ] Advertising ID = Yes (Advertising or marketing + Fraud prevention)
- [ ] Data safety হালনাগাদ ও Submit করা
- [ ] Privacy policy লিংক https://lifeassisto.com/privacy, পাতায় AdMob অংশ দেখা যাচ্ছে
- [ ] Store listing Website = https://lifeassisto.com
- [ ] https://lifeassisto.com/app-ads.txt-এ সঠিক লাইন
- [ ] AdMob-এ GDPR ও US state বার্তা Published
- [ ] (প্রোডাকশন লঞ্চ + AdMob অনুমোদনের পরে) Owner Admin → Ads → আসল আইডি চালু, SSV URL যাচাই
