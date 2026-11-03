# ফিচার কার্ড — ম্যাপ খরচ (Maps cost) — মালিকের আদেশ ৩ Nov ১৮:৪০, PART 1

## ১. উদ্দেশ্য (এক লাইনে)
Google Maps-এর পেইড কল এমনভাবে চালানো যাতে স্বাভাবিক মাসে খরচ ০ টাকা (ফ্রি সীমার ভেতরে), কখনো হঠাৎ বড় বিল না আসে, আর SOS কখনো কোনো ম্যাপ কলের জন্য না থামে।

## ২. মানুষের কী লাভ
* অ্যাপে আসল Google ম্যাপ (Maps SDK — ফোনে দেখানো ফ্রি, সীমাহীন)।
* লাইভ লোকেশন, গন্তব্য অ্যালার্ম, স্কুল/পৌঁছানোর জিওফেন্স — ফোনের GPS দিয়ে হিসাব, কোনো API কল নেই, তাই নেট দুর্বল হলেও কাজ করে।
* ঠিকানা আগে ফোনের নিজের (ফ্রি) Android Geocoder থেকে; না পেলে আমাদের সার্ভার — ৫০ মিটারের ভেতরে আগে খোঁজা ঠিকানা আবার ব্যবহার।
* নাম লিখে জায়গা খোঁজা: ৩ অক্ষর পর, ৩০০ ms থেমে — টাইপ করতে করতে ফল; একটি "সেশন" শেষে একটাই Place Details।
* সীমা শেষ হলে অ্যাপ ভাঙে না: স্থানাঙ্ক লেখা + "Google Maps-এ খুলুন" (ফ্রি) দেখায়।

## ৩. আজকের অডিট — কোথায় কোন কল, কে টাকা দেয়, এখন কী
| জায়গা / কল | API | কে টাকা দেয় (আগে) | এখন (এই শাখায়) |
|---|---|---|---|
| Safe Journey গন্তব্য খোঁজা (নাম লিখে, Enter) | Places **Text Search** (পুরোনো, ~$৩২/১০০০) | আমরা, কোনো সীমা ছিল না | Autocomplete (New) + সেশন টোকেন + ১টি Place Details Essentials; পুরোনো Text Search শুধু পুরোনো অ্যাপের জন্য, দৈনিক সীমার ভেতরে |
| ম্যাপে জায়গা বাছাই | flutter_map + মালিকের টাইল (সেট নেই → ম্যাপ নেই) | — | Maps SDK (ফ্রি) যখন Android কি বিল্ডে আছে; না থাকলে আগের মতো |
| ম্যাপে বাছাই করা পিনের ঠিকানা | ছিল না ("পিন করা জায়গা") | — | ফোনের Geocoder (ফ্রি) → সার্ভার Geocoding (সীমা + ৫০ m ক্যাশ) → স্থানাঙ্ক |
| পৌঁছানোর সময় (ETA) | নিজের গতি থেকে অনুমান (API নেই) | ফ্রি | একই থাকছে; উপরন্তু "রাস্তায় সময় দেখুন" ট্যাপে একবার Routes (১০ মিনিট ক্যাশ, দৈনিক সীমা) |
| লাইভ লোকেশন, গন্তব্য অ্যালার্ম, ট্রেন ট্র্যাকার | ফোনের GPS + দূরত্বের অঙ্ক | ফ্রি, API নেই | একই (বদল নেই) |
| স্কুল / পৌঁছানোর জিওফেন্স | GPS/Wi-Fi + আমাদের সার্ভারে দূরত্বের অঙ্ক | ফ্রি, API নেই | একই (বদল নেই) |
| নেভিগেশন (গাড়ি মোড, ভয়েস) | Google Maps অ্যাপ খোলা (`google.navigation:` / maps link) | ফ্রি | একই |
| কাছের হাসপাতাল/থানা/ফায়ার (SOS-এর পরে, Nearby পাতা) | Places Nearby Search বা OSM Overpass | আমরা | **এই শাখার বাইরে** — nearby এজেন্টের কাজ (মালিকের ১৮:৫০ আদেশ) |
| SOS (journey/sos, family/sos) | কোনো ম্যাপ কল নেই | — | কোনো কল নেই — CI টেস্টে প্রমাণ |
| ওয়েব লাইভ-লোকেশন পাতা (`/j/…`, `/v/…`) | টাইল সেট নেই → ম্যাপ নেই | — | ফ্রি OpenStreetMap টাইল (attribution লিংক, Referer শুধু সাইটের নাম, টাইল কেবল কেন্দ্র সরলে নতুন) |
| CCTV, পরিবারের যত্ন, হারানো ফোন | শুধু "Google Maps-এ খুলুন" লিংক | ফ্রি | একই |
| Integrations-এর "Test" (google_places) | Find Place (১টি কল) | আমরা | নতুন সার্ভার কি-এর Test = ১টি Geocoding কল (ফ্রি সীমার ভেতরে) |

## ৪. নিয়ম যেভাবে কোডে
* সব পেইড কল একটাই দরজা দিয়ে: `backend/core/maps_cost.py` (সার্ভার কি, Cost flags-এর `maps_geocoding` সুইচ, প্রতি জনের দৈনিক সীমা, সবার মিলে দৈনিক সীমা, গোনা)।
* ডিফল্ট সীমা (Owner Admin → **ম্যাপ খরচ**-এ বদলানো যায়): Geocoding ২০/জন, ৩০০/দিন · Autocomplete ৬০/জন, ৩০০/দিন · Place Details ১৫/জন, ৩০০/দিন · Routes ৬/জন, ১৫০/দিন · পুরোনো Text Search ৫/জন, ১০০/দিন। এতে মাসের মোট Google-এর ফ্রি সীমার ভেতরে থাকে।
* Owner Admin → **ম্যাপ খরচ**: প্রতিটি API-র আজকের কল, সীমায় আটকানো কল, মাসের কল, ফ্রি সীমা কত বাকি, আনুমানিক USD ও টাকা (১ USD = কত টাকা — বদলানো যায়)। প্রতিটি বদল audit-এ লেখা হয়।
* সার্ভার কি: Owner Admin → Integrations → **Google Maps — server key** (এনক্রিপ্ট করা; ফোনে কখনো যায় না — টেস্টে প্রমাণ)।
* Android কি: Owner Admin → Integrations → **Google Maps — Android key** (রেকর্ড) + GitHub secret `MAPS_ANDROID_KEY` (বিল্ডের সময় manifest-এ ঢোকে; কোডে কোনো কি নেই)।

## ৫. মালিকের করণীয় — Cloud Console ধাপ (প্রজেক্ট assisto-play)
**ক) Android কি (Maps SDK):**
1. console.cloud.google.com → উপরে প্রজেক্ট **assisto-play** বাছুন → APIs & Services → Library → **Maps SDK for Android** → Enable।
2. Credentials → **Create credentials → API key** → নাম দিন `assisto-android`।
3. **Application restrictions → Android apps → Add an item**:
   * Package name: `com.assisto.assisto`
   * SHA-1 (১) — **Play App Signing কি**: Play Console → Assisto → Test and release → Setup → **App integrity → App signing** → "App signing key certificate"-এর **SHA-1** কপি করে এখানে বসান। (এই সংখ্যা Google বানিয়েছে, আমাদের রিপোতে নেই — তাই আমি বানিয়ে লিখিনি।)
   * আরেকটি item, একই package — SHA-1 (২) — **upload / ওয়েবসাইট APK কি** (রিপোর STATUS-এ লেখা আছে): `5D:24:EF:43:9C:7D:73:81:F4:A2:63:11:78:32:9A:17:41:9C:17:19`
4. **API restrictions → Restrict key → শুধু Maps SDK for Android** → Save।
5. কি কপি করে: (ক) Owner Admin → Integrations → Google Maps — Android key-এ পেস্ট; (খ) GitHub → assisto রিপো → Settings → Secrets and variables → Actions → New secret → নাম `MAPS_ANDROID_KEY`, মান = এই কি। পরের বিল্ড থেকে অ্যাপে আসল ম্যাপ দেখাবে।

**খ) সার্ভার কি (Geocoding, Places New, Routes):**
1. Library → **Geocoding API**, **Places API (New)**, **Routes API** — তিনটিই Enable।
2. Credentials → Create credentials → API key → নাম `assisto-server`।
3. Application restrictions → **IP addresses** → আমাদের সার্ভারের IP `16.4.105.173`।
4. API restrictions → শুধু ওই তিনটি API → Save।
5. Owner Admin → Integrations → **Google Maps — server key**-এ পেস্ট → Test।
6. (পরামর্শ) Billing → Budgets & alerts → মাসিক বাজেট যেমন $৫, ৫০%/৯০%/১০০%-এ ইমেইল।

## ৬. সৎ সীমা
* Maps SDK-র Android কি APK-তে বিল্ডের সময় ঢোকে — Owner Admin-এ রাখা কি বদলালে নতুন বিল্ড লাগবে (Google-এর নিয়ম; চলমান অ্যাপে কি বদলানো যায় না)।
* Autocomplete-এর খরচ কার্ডে "সবচেয়ে খারাপ অনুমান" (প্রতি অনুরোধ গোনা); Place Details-এ শেষ হওয়া সেশনে Google আসলে কম নেয়।
* Routes "ট্রাফিকসহ" (Compute Routes Pro রেট $১০/১০০০, ফ্রি ৫০০০/মাস) — রেট Owner Admin-এ বদলানো যায়।
* কাছের হাসপাতাল/থানা/ফায়ারের তালিকা nearby এজেন্টের; এখানে শুধু "Google Maps-এ খুলুন"।

## ৭. দুই ফোনে মালিকের পরীক্ষা (৫ মিনিট)
1. ফোন A: নিরাপদ যাত্রা → গন্তব্য → "খুঁজুন" → "বসু" লিখুন — ৩ অক্ষরে ফল আসবে; একটিতে ট্যাপ → গন্তব্য বসবে।
2. ফোন A: "ম্যাপে বাছুন" → একটি জায়গা → ঠিকানা নিজে থেকে বসবে (ফোনের Geocoder)।
3. ফোন A: যাত্রা শুরু → লাইভ পাতায় "রাস্তায় সময় দেখুন" → মিনিট দেখাবে।
4. ফোন B: যাত্রার লিংক ব্রাউজারে খুলুন → OpenStreetMap ম্যাপ + নিচে "© OpenStreetMap contributors"।
5. Owner Admin → ম্যাপ খরচ → আজকের কল বেড়েছে কিনা দেখুন; Geocoding-এর "প্রতি জনের দৈনিক সীমা" ০ করে ধাপ ২ আবার — ঠিকানার বদলে স্থানাঙ্ক + "Google Maps-এ খুলুন" দেখাবে।

## ৮. প্রমাণ
* ব্যাকএন্ড টেস্ট: `backend/core/tests_mapscost.py`, `backend/web/tests_mapscost_owner.py`। CI রান: (নিচে যোগ হবে)
