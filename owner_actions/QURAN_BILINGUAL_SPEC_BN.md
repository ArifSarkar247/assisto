# কুরআন দ্বিভাষিক (বাংলা + ইংরেজি) — নকশা ও উৎস-লাইসেন্স (স্পেক)

মালিকের আদেশ ৯ নভেম্বর ২০২৬ ২১:৫৫ (`owner_actions/OWNER_QURAN_BILINGUAL_9NOV_2155.md`) ও ২২:০৫ (MAX PARALLEL, লেন ১৪/১৫/১৬)।
লিখেছে: লেন ১৪ (`agent/quranview`)। এই ফাইল পড়বে: লেন ১৫ (বাংলা উচ্চারণ ইঞ্জিন), লেন ১৬ (কুরআন শিখি)।

## ০. কঠোর নিয়ম (কখনো ভাঙা যাবে না)
1. **AI কখনো** কুরআনের অনুবাদ, তাফসির বা শানে নুযূল **লিখবে না, সারাংশ করবে না, ভাষা বদলাবে না।** সব লেখা লাইসেন্সপ্রাপ্ত উৎসের **হুবহু** লেখা। Assisto AI চ্যাটে কেউ কুরআনের অর্থ চাইলে AI নিজে অনুবাদ বানাবে না — অ্যাপের আয়াত-পাতায় পাঠাবে (পরের ধাপ, AI-চ্যাট লেন)।
2. **আরবি লেখা কখনো বদলানো হবে না** — Tanzil Uthmani 1.1 (হাফস), ফাইল হুবহু (sha256 `assets/quran/SOURCES.txt`-এ)।
3. কুরআন, কুরআন শিখি ও এর সব শিটে **কোনো বিজ্ঞাপন নেই** (`ad_rules.dart`-এ `quran` আগে থেকেই নিষেধ তালিকায়; নতুন রুটও যোগ হবে)।
4. Quran Foundation (QF)-এর কন্টেন্ট **৭ দিনের বেশি রাখা যাবে না** — শুধু QF-এর Content Sync API দিয়ে নেওয়া অফলাইন কপি ছাড়া। **QF-এর কোনো ডেটাবেস অ্যাপের ভেতরে (APK) দেওয়া যাবে না।** QF কন্টেন্ট দিয়ে **কোনো মডেল ট্রেনিং বা embedding নয়।**
5. **quranicaudio.com-এর ফাইল নয়** (বাণিজ্যিক ব্যবহার নিষেধ)। EveryAyah-ও নয় (লাইসেন্স লেখা নেই)।
6. ভাষার নিয়ম: অ্যাপ ইংরেজিতে থাকলেও কুরআন, কুরআন শিখি ও Language Partner-এ **বাংলা ও ইংরেজি দুটোই একসাথে** — এটাই একমাত্র ব্যতিক্রম। প্রতিটি লাইন ব্যবহারকারী আলাদা করে চালু/বন্ধ করতে পারবেন।
7. লাইসেন্স অস্পষ্ট → **সেই উৎস দেখানো হবে না**, মালিকের কাজের তালিকায় যাবে।

## ১. উৎস ও লাইসেন্স টেবিল (প্রতিটি প্রকাশকের নিজের পাতা খুলে পড়া — ৯ নভেম্বর ২০২৬)

| উৎস | কী নেব | প্রকাশকের নিজের পাতা (পড়ার তারিখ) | শর্ত (প্রকাশকের ভাষায়, সংক্ষেপে) | সিদ্ধান্ত |
|---|---|---|---|---|
| Tanzil Uthmani 1.1 (হাফস) | আরবি লেখা | tanzil.net/docs/text_license (৩ Nov যাচাই, অ্যাপে আগেই আছে) | CC BY 3.0; হুবহু; "Tanzil Project" + লিংক | **চালু** (আগে থেকেই অ্যাপে, হুবহু) |
| QuranEnc — বাংলা অনুবাদ, আবু বকর যাকারিয়া (`bengali_zakaria`, **সংস্করণ 1.1.1**) | বাংলা অর্থ + টীকা (footnotes) | https://quranenc.com/en/browse/bengali_zakaria (৯ Nov ২০২৬); সংস্করণ: `https://quranenc.com/api/v1/translations/updates?key=bengali_zakaria` (৯ Nov) | "Contents of the translations can be downloaded and re-published, with the following terms and conditions: 1. No modification, addition, or deletion of the content. 2. Clearly referring to the publisher and the source (QuranEnc.com). 3. Mentioning the version number when re-publishing the translation. 4. Keeping the transcript information inside the document. 5. Notifying the source (QuranEnc.com) of any note on the translation. 6. Updating the translation according to the latest version issued from the source (QuranEnc.com). 7. Inappropriate advertisements must not be included when displaying translations of the meanings of the Noble Quran." | **চালু** — শর্ত লিখিত ও পরিষ্কার |
| QuranEnc — ইংরেজি Saheeh International (`english_saheeh`, প্রকাশক Noor International Center, **সংস্করণ 1.1.2**) | ইংরেজি অর্থ + টীকা | https://quranenc.com/en/browse/english_saheeh (৯ Nov ২০২৬) — একই ৭টি শর্ত | উপরের মতো | **চালু** |
| QuranEnc — বাংলা "আল-মুখতাসার ফী তাফসীরিল কুরআন" (`bengali_mokhtasar`, **সংস্করণ 1.0.0**) | সংক্ষিপ্ত তাফসির (বাংলা) | https://quranenc.com/en/browse/bengali_mokhtasar (৯ Nov ২০২৬) — একই ৭টি শর্ত | উপরের মতো | **চালু** — এটাই "abridged" তাফসির; QUL থেকে নয়, সরাসরি QuranEnc থেকে (লিখিত শর্ত আছে) |
| Quran Foundation API (Content API v4) | প্রতি-আয়াত অডিও + ক্বারি তালিকা, শব্দে-শব্দে অর্থ (বাংলা ও ইংরেজি), ইংরেজি উচ্চারণ (transliteration, resource 57 + শব্দের transliteration) | https://api-docs.quran.foundation/legal/developer-terms/ ("Last updated: 2026-10-11", পড়া ৯ Nov ২০২৬) | "Cache or store QF Content longer than 1 week" নিষেধ, Content Sync ছাড়া; "Content Sync is the only permitted path for obtaining and maintaining an offline copy"; Content Sync হলে "next sync at least every 7 days"; "does not itself authorize distributing a prepackaged database or build-time bundle of QF Content"; ML মডেল নিষেধ "without written consent"; RAG-এর embedding-ও সংরক্ষণ-সীমার আওতায়; বিক্রি/পুনর্বিতরণে আলাদা লাইসেন্স লাগে, কিন্তু অ্যাপের ভেতরে দেখানো, পেইড প্ল্যান, বিজ্ঞাপন চলবে; "snippets ... preserve original context"। কৃতজ্ঞতা: মালিকের আদেশে কুরআন পাতা + About-এ "Quran Foundation"। | **চালু — কী দিলে।** কী মালিক Owner Admin-এ দেবেন; না দেওয়া পর্যন্ত অডিও/শব্দার্থ/উচ্চারণ ব্লকে সৎ লাইন "চালু হচ্ছে" |
| QUL (qul.tarteel.ai) — তাফসীর ইবনে কাসীর (বাংলা, id 31) | তাফসির | https://qul.tarteel.ai/resources/tafsir/31/licence (৯ Nov) | পাতায় লেখা: **"We don't have copyright information for this resource."** | **দেখানো হবে না** — মালিকের কাজ |
| QUL — তাফসীর আহসানুল বায়ান (id 32) | তাফসির | …/tafsir/32/licence (৯ Nov) | একই: "We don't have copyright information for this resource." | **দেখানো হবে না** — মালিকের কাজ |
| QUL — তাফসীর আবু বকর যাকারিয়া (id 33) | তাফসির | …/tafsir/33/licence (৯ Nov) | একই | **দেখানো হবে না** (তবে যাকারিয়ার অনুবাদের টীকা QuranEnc-এর লিখিত শর্তে চালু) |
| QUL — তাফসীর ফাতহুল মাজীদ (id 39) | তাফসির | …/tafsir/39/licence (৯ Nov) | একই | **দেখানো হবে না** — মালিকের কাজ |
| QUL — Bengali Abridged Explanation (id 267) | তাফসির | …/tafsir/267/licence (৯ Nov) | একই | QUL থেকে **নয়**; একই বই QuranEnc-এর লিখিত শর্তে নেওয়া হচ্ছে (উপরে) |
| quranicaudio.com / EveryAyah | অডিও | (৩ Nov যাচাই) | বাণিজ্যিক নিষেধ / লাইসেন্স নেই | **কখনো নয়** |
| KFGQPC (বাদশাহ ফাহাদ কমপ্লেক্স) Hafs ফন্ট/লেখা | ফন্ট | QuranEnc API পাতায় Hafs_20.zip আছে, কিন্তু KFGQPC-এর নিজের খোলা লাইসেন্স পাইনি | — | **নয়**; ফন্ট Amiri Quran (OFL 1.1, আগেই আছে) |

QuranEnc-এর শর্ত মানার উপায়: (১) লেখা হুবহু, টীকার চিহ্নসহ; (২) প্রতিটি ব্লকের নিচে "উৎস: QuranEnc.com · <অনুবাদের নাম> · সংস্করণ X.Y.Z"; (৪) টীকা ও "transcript information" রাখা; (৫) "ভুল জানান" বোতাম → মালিকের কাছে নোট (পরে QuranEnc-এর `POST /translations/note`-এ পাঠানো মালিকের হাতে); (৬) সার্ভার প্রতিদিন `translations/updates?key=` দেখে নতুন সংস্করণ এলে পুরোনো ক্যাশ ফেলে নতুনটা নেয়; ফোনও সংস্করণ মিলিয়ে নেয়; (৭) বিজ্ঞাপন একদমই নেই।

QF-এর শর্ত মানার উপায়: QF কী শুধু সার্ভারে (এনক্রিপ্টেড, Owner Admin কার্ড `quran_foundation`), অ্যাপে কখনো নয়। সার্ভার QF-এর জবাব **সর্বোচ্চ ৬ দিন** রাখে; ফোন QF-এর অংশ **৬ দিন পর মুছে** আবার আনে (৭ দিনের সীমার নিচে)। অডিও ফোনে ডাউনলোড-সংরক্ষণ নয়, শুধু বাজানো। অফলাইন QF চাইলে শুধু Content Sync দিয়ে (পরের ধাপ; ৭ দিনে একবার sync বাধ্যতামূলক)। আমাদের সার্ভার QF কন্টেন্ট শুধু Assisto অ্যাপের লগইন-করা ব্যবহারকারীকে দেখায় — বাইরের কারো জন্য খোলা API/ডাউনলোড নয় (পুনর্বিতরণ নয়)।

## ২. আয়াত-পাতা (Ayah view) — মালিক-অনুমোদিত স্ক্রিন
কুরআন → সূরা → কোনো আয়াতে ট্যাপ → **আয়াত-পাতা**। উপর থেকে নিচে, প্রতিটি আলাদা কার্ড, প্রতিটির নিচে ছোট "উৎস" লাইন:
1. **আরবি** (Tanzil Uthmani, হুবহু, Amiri Quran ফন্ট, বড় অক্ষর, ডান-থেকে-বাম) — উৎস: Tanzil Project (CC BY 3.0)।
2. **বাংলা উচ্চারণ** — লেন ১৫-এর নিয়মভিত্তিক ইঞ্জিন (AI নয়)। সবসময় লেবেল **"যাচাই চলছে"** (যতক্ষণ `review != approved`)। উৎস: "Assisto উচ্চারণ নিয়ম (তাজবীদসহ) · Tanzil লেখা থেকে"।
3. **English transliteration** — QF (resource 57)। উৎস: Quran Foundation।
4. **বাংলা অর্থ** — QuranEnc যাকারিয়া, হুবহু, টীকা-চিহ্নসহ।
5. **English meaning** — QuranEnc Saheeh International, হুবহু।
6. **শব্দে শব্দে** — QF: প্রতিটি আরবি শব্দ + বাংলা শব্দার্থ + ইংরেজি শব্দার্থ + শব্দের transliteration; ডান-থেকে-বামে মোড়ানো চিপ।
7. **অডিও** — QF প্রতি-আয়াত অডিও; ক্বারি বাছাই (QF-এর তালিকা), পুনরাবৃত্তি ১/৩/৫/৭/১০ বার, বাজাও/থামাও; সব শব্দ `audio_route_service.dart` দিয়ে।
8. বোতাম **"তাফসির ও শানে নুযূল"** → শিট (নিচে)।
* উপরে "লাইন দেখাও" টগল: প্রতিটি লাইন আলাদা চালু/বন্ধ, ফোনে মনে থাকে। বাংলা ও ইংরেজি — দুই অ্যাপ-ভাষাতেই দুটো দেখায় (ডিফল্ট সব চালু)।
* আগের/পরের আয়াত বোতাম; বুকমার্ক (আগের ফিচারের সাথে একই)।
* QF কী না থাকলে: ৩, ৬, ৭ নম্বর ব্লকে সৎ লাইন "এই অংশ শিগগির চালু হচ্ছে" — ফাঁকা বা মরা বোতাম নয়। নেট না থাকলে: আরবি সবসময় (অফলাইন), বাকিগুলো আগে দেখা থাকলে ক্যাশ থেকে, নাহলে "নেট লাগবে — আবার চেষ্টা" বোতাম।

## ৩. তাফসির ও শানে নুযূল শিট (মালিক-অনুমোদিত স্ক্রিন)
* `showAppSheet` দিয়ে নিচ থেকে শিট। উপরে **উৎস চিপ**: "মুখতাসার (বাংলা)", "যাকারিয়া টীকা (বাংলা)", "Saheeh টীকা (English)"। লাইসেন্স না থাকা QUL তাফসিরগুলো চিপে **দেখানো হবে না**।
* বাছাই করা চিপের লেখা হুবহু, নিচে উৎস লাইন (প্রকাশক, QuranEnc.com, সংস্করণ)।
* **শানে নুযূল** অংশ: কোনো খোলা আলাদা বাংলা শানে-নুযূল উৎস নেই। তাই শুধু লাইসেন্সপ্রাপ্ত উৎসের (যাকারিয়া টীকা, মুখতাসার, Saheeh টীকা) **যে টীকা নিজেই নাযিলের কারণ বলে**, সেই পুরো টীকা হুবহু দেখানো হয়, উৎস চিপসহ। কোন টীকা: নির্দিষ্ট শব্দ-নিয়মে খোঁজা (যেমন "শানে নুযূল", "নাযিলের কারণ/প্রেক্ষাপট", "আয়াত(টি) … নাযিল/অবতীর্ণ হয়"; ইংরেজিতে "was revealed … concerning/regarding/when/after") — AI নয়, লেখা কাটছাঁট নয়, পুরো টীকা। না পেলে স্পষ্ট লাইন: **"এই উৎসে এই আয়াতের শানে নুযূল উল্লেখ নেই।"** এটি শব্দ-নিয়ম, তাই আলেমের পর্যালোচনা পর্যন্ত এখানেও "যাচাই চলছে" ছোট লেবেল।

## ৪. সার্ভার (Django) — API
সব `GET`, লগইন লাগবে, বিজ্ঞাপন নেই। সুইচ: আগের `quran` সুইচের ভেতরেই (নতুন সুইচ নয়)।
* `GET /api/quran/meaning/<surah>` → `{ok, surah, bn:{key, title, publisher, version, source:"QuranEnc.com", items:[{ayah, text, footnotes}]}, en:{…}}` — QuranEnc থেকে; সার্ভার ক্যাশ ২৪ ঘণ্টা + সংস্করণ বদলালে নতুন।
* `GET /api/quran/tafsir/<surah>/<ayah>` → `{ok, sources:[{id, title_bn, title_en, lang, publisher, version, text}], shan_nuzul:[{source_id, text}], shan_nuzul_rule:"keyword_v1"}`।
* `GET /api/quran/qf/<surah>/<ayah>?reciter=<id>` → `{ok, enabled, translit, words:[{ar, bn, en, tr}], audio_url, reciter_id, fetched_at, max_age_days:6}` — QF কী না থাকলে `{ok:true, enabled:false}`।
* `GET /api/quran/reciters` → `{ok, enabled, items:[{id, name, style}]}` (QF, ক্যাশ ৬ দিন)।
* `GET /api/quran/pron/<surah>[?ayah=N]` → **লেন ১৫-এর** (`{ok, surah, engine_version, label:"under_review", source, items:[{ayah, bn, review, note_bn?}], bismillah_bn?}`)। আয়াত-পাতা এটাই পড়ে, সূরা-ভিত্তিক ফোনে ক্যাশ।
* Owner Admin: ইন্টিগ্রেশন কার্ড **`quran_foundation`** — ঘর: Client ID, Client Secret, পরিবেশ (production/prelive)। Test = OAuth2 `client_credentials` টোকেন (`https://oauth2.quran.foundation/oauth2/token`, scope `content.quran.read content.audio.read content.translations.read`) পাওয়া গেলে সবুজ। হেডার `x-auth-token`, `x-client-id`; বেস `https://apis.quran.foundation/content/api/v4`।

## ৫. অ্যাপ (Flutter)
* নতুন: `app/lib/quran/ayah_view_screen.dart` (আয়াত-পাতা), `app/lib/quran/quran_tafsir_sheet.dart` (শিট), `app/lib/quran/quran_bilingual_api.dart` (সার্ভার কল + ফোন ক্যাশ: QuranEnc সংস্করণ ধরে; QF অংশ ৬ দিনে মেয়াদ শেষ)।
* পুরোনো `quran_screen.dart`-এর পড়ার পাতায় আয়াতে ট্যাপ → আয়াত-পাতা। "উৎস ও লাইসেন্স" পাতায় QuranEnc ও Quran Foundation যোগ; About-এ "Quran Foundation" কৃতজ্ঞতা।
* বাংলা অঙ্ক, ৪৮dp, ২০০% ফন্ট, ডার্ক, TalkBack লেবেল, নেভ-বার ওভারল্যাপ নয়।

## ৬. লেন ১৫ ও ১৬-এর জন্য
* লেন ১৫: API আকার উপরে (৪ নম্বর)। আরবি ইনপুট শুধু Tanzil Uthmani (হুবহু)। "under_review" লেবেল বাধ্যতামূলক যতক্ষণ আলেম/ক্বারি অনুমোদন না দেন।
* লেন ১৬ (কুরআন শিখি): ভাষার নিয়ম (বাংলা+ইংরেজি একসাথে), বিজ্ঞাপন নেই, অডিও শুধু লাইসেন্সপ্রাপ্ত (QF অডিও শুধু আয়াতের জন্য; হরফ-অডিও এখনো নেই — `FEATURE_CARD_QURAN_READING_BN.md`), ভয়েস-নম্বর "অনুশীলনের মাপ — শিক্ষকের বিকল্প নয়"।

## ৭. মালিকের কাজ
1. quran.foundation-এ ফ্রি ডেভেলপার অ্যাকাউন্ট → Client ID + Secret → Owner Admin → ইন্টিগ্রেশন → "Quran Foundation" কার্ডে পেস্ট → Test।
2. QUL-এর ৪টি বাংলা তাফসিরের (ইবনে কাসীর, আহসানুল বায়ান, আবু বকর যাকারিয়া পূর্ণ তাফসির, ফাতহুল মাজীদ) লিখিত অনুমতি — প্রকাশক/অনুবাদকের কাছ থেকে (QUL নিজেই লিখেছে কপিরাইট তথ্য নেই)। অনুমতিপত্র এলে চিপ যোগ করা ১ দিনের কাজ।
3. একজন আলেম/ক্বারি: বাংলা উচ্চারণ (লেন ১৫) ও শানে-নুযূল শব্দ-নিয়মের ফল যাচাই।
4. চাইলে QuranEnc-কে (support) জানানো যে Assisto তাদের অনুবাদ শর্ত মেনে দেখাচ্ছে (শর্তে বাধ্যতামূলক নয়, সৌজন্য)।

## ৮. মালিকের পরীক্ষা (একটা ফোন)
1. কুরআন → আল-বাকারা → আয়াত ৬-এ ট্যাপ → আরবি, বাংলা উচ্চারণ ("যাচাই চলছে"), বাংলা অর্থ, English meaning — প্রতিটির নিচে উৎস।
2. "লাইন দেখাও" → English meaning বন্ধ → অ্যাপ বন্ধ করে খুললেও বন্ধ থাকবে।
3. অ্যাপ ইংরেজিতে → একই পাতায় বাংলা ও ইংরেজি দুটোই।
4. "তাফসির ও শানে নুযূল" → চিপ বদলে লেখা বদলায়; শানে নুযূল না থাকলে স্পষ্ট লাইন।
5. QF কী দেওয়ার পর: ক্বারি বাছুন → পুনরাবৃত্তি ৩ → আয়াত ৩ বার বাজে।
