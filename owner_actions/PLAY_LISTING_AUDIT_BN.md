# Play স্টোর লিস্টিং অডিট: অ্যাপে যা আছে, পাতায় কি তা-ই লেখা? (২৭ Oct ২০২৬)

**শুধু রিপোর্ট।** Play Console, লিস্টিং, ফ্ল্যাগ, কোড, DB কিছুই বদলানো হয়নি। লাইভ লিস্টিং পড়া হয়েছে Android Publisher API দিয়ে: একটি edit খোলা হয়েছে, পড়া হয়েছে, তারপর **মুছে ফেলা হয়েছে (commit হয়নি)**।
ঠিক করা লেখা আছে `owner_actions/PLAY_LISTING_FIXED.md`-এ। আপনি নিজে Play Console-এ পেস্ট করবেন।

উৎস:
- লাইভ লিস্টিং: en-US (title, short, full), ৮টি ফোন স্ক্রিনশট আর ফিচার গ্রাফিক। প্রতিটি ছবি খুলে চোখে দেখা হয়েছে।
- **বাংলা লিস্টিং Play-তে নেই।** শুধু en-US আছে। ট্যাবলেটের স্ক্রিনশটও নেই।
- Play-তে আজ কী দেখা যায়: লাইভ ফ্ল্যাগ (`/api/v1/features`, হেডার `X-Assisto-Flavour: play`), বিল্ডের গেট (`app/lib/feature_gates.dart`), সার্ভারের পাহারা (`backend/core/i18n.py` `is_play_flavour`), `FEATURE_STATUS_BN.md`, `SHOWPIECES_BN.md`, `TOP10_MONEY_FEATURES_BN.md`, `PLAY_ORGANIZATION_ACCOUNT_BN.md`।
- কোম্পানির যোগাযোগ Play-তে ঠিক আছে: assistoaiagent@gmail.com, lifeassisto.com।

---

## ক) ওষুধের রিমাইন্ডার Play-তে কেন লুকানো, আর নিরাপদে দেখাতে কী লাগবে

### কেন লুকানো
- **২৪ Oct Google Play অ্যাপটি বাতিল করেছিল।** অ্যাপে "Medication and treatment management" (ওষুধ ও চিকিৎসা ব্যবস্থাপনা) ধরনের স্বাস্থ্য-ফিচার ছিল। Play-র Health apps নীতিতে এই ধরনের অ্যাপ **ব্যক্তিগত (personal) ডেভেলপার অ্যাকাউন্ট থেকে প্রকাশ করা যায় না। লাগে প্রতিষ্ঠানের (Organization) অ্যাকাউন্ট।** Assisto এখন একটি personal অ্যাকাউন্টে আছে।
- তাই Play বিল্ডে ওষুধের সব প্রবেশপথ **বিল্ডের সময়েই** বন্ধ করা আছে: `kMedicalFeaturesAllowed = !AppConfig.playStore`। লুকানো আছে: ওষুধের সময়সূচি, ডোজের ইতিহাস, ডোজ মিস হলে সতর্কতা, ওষুধের ডাটাবেস, প্রেসক্রিপশন রিডার, হেলথ টাইমলাইন, ডাক্তারের সিরিয়াল, স্বাস্থ্য-টিপস, প্রাথমিক চিকিৎসা, আর জরুরি কার্ডের মেডিকেল তথ্য।
- সার্ভারও একই নিয়ম মানে। Play অ্যাপের চ্যাটে "ওষুধ" লিখলে medicine row তৈরি হয় না, শুধু একটি সাধারণ রিমাইন্ডার হয়। ওষুধের সাজেশনও দেখানো হয় না।
- অথচ লিস্টিংয়ে লেখা আছে "Remind me about medicine at 8am", "Medicine schedules…", "Medicine history, health timeline", আর স্ক্রিনশটে "Medicine" কার্ড দেখানো। এতে দুটো ঝুঁকি। Play-র চোখে এটা ঘোষণা না করা স্বাস্থ্য-ফিচারের দাবি (আবার বাতিল হতে পারে)। আর ব্যবহারকারীর চোখে এটা বিভ্রান্তিকর বিজ্ঞাপন (ভোক্তা-অধিকার সংরক্ষণ আইন ২০০৯, ধারা ৪৫)।

### নিরাপদে দেখাতে যা লাগবে (এই ক্রমে)
| # | কাজ | কে করবে | সময় |
|---|---|---|---|
| ১ | **D-U-N-S নম্বর** (AXON Dynamic)। Google Play-র জন্য Dun & Bradstreet থেকে **বিনামূল্যে** পাওয়া যায়। আগে dnb.com-এ খুঁজে দেখুন নম্বর আগে থেকেই আছে কিনা। | আপনি | সাধারণত **৫–৩০ কর্মদিবস** (বাংলাদেশে প্রায়ই ২–৪ সপ্তাহ)। নম্বর পাওয়ার পর Google-এর কাছে পৌঁছাতে আরও ২–৩ দিন। |
| ২ | Play Console-এ **Organization অ্যাকাউন্টে রূপান্তর**। না পারলে নতুন org অ্যাকাউন্ট খুলে অ্যাপ ট্রান্সফার। তারপর প্রতিষ্ঠান, ফোন, ইমেইল ও ওয়েবসাইট যাচাই। ধাপগুলো আছে `PLAY_ORGANIZATION_ACCOUNT_BN.md`-এ। | আপনি | যাচাইয়ে **২–৭ দিন** (কখনো বেশি) |
| ৩ | App content → **Health apps declaration**: শুধু "Medication and treatment management" বাছবেন। Medical device, diagnosis বা clinical বাছবেন না। Fitness আগের মতোই থাকবে। | আপনি (লেখা আমি দেব) | ১ ঘণ্টা |
| ৪ | **Data safety → "Health info"**: Collected, Not shared, Optional, App functionality, encrypted in transit, deletable। | আপনি | ৩০ মিনিট |
| ৫ | **গোপনীয়তা নীতিতে আলাদা স্বাস্থ্য-অংশ**: কোন তথ্য নেওয়া হয় (ওষুধের নাম, সময়, খেয়েছি/বাদ), কেন নেওয়া হয়, কে দেখে (শুধু আপনি আর আপনার বেছে নেওয়া পরিবার), কতদিন রাখা হয়, কীভাবে মুছবেন। এখনকার নীতিতে শুধু এক লাইন আছে। | আমি (আপনার অনুমোদনে) | ½ দিন |
| ৬ | **অ্যাপে দাবিমুক্তি (disclaimer)**: ওষুধ প্রথমবার খোলার সময় আর Settings-এ লেখা থাকবে "এটি চিকিৎসা-পরামর্শ নয়, ডোজ বলে না, রোগ নির্ণয় বা চিকিৎসা করে না, ডাক্তারের পরামর্শ মানুন।" **ওষুধের পাতায় এখন এমন লেখা নেই** (শুধু হেলথ টাইমলাইন, ওয়েলনেস আর ফিটনেসে আছে)। লিস্টিংয়েও একই লাইন থাকবে (Case A-তে দেওয়া আছে)। | আমি | ½ দিন |
| ৭ | **কোনো মেডিকেল-ডিভাইস বা চিকিৎসা-দাবি থাকবে না।** "কখনো ডোজ মিস হবে না", "ডাক্তার-অনুমোদিত", "রোগ সারায়" জাতীয় কথা কোথাও লেখা যাবে না। প্রথম রিলিজে ওষুধের ডাটাবেস, প্রেসক্রিপশন রিডার, প্রাথমিক চিকিৎসা, স্বাস্থ্য-টিপস আর ডাক্তারের সিরিয়াল **বন্ধ থাকবে**। চালু হবে শুধু রিমাইন্ডার আর পরিবারের দেখা। এর জন্য এখনকার একটা গেটকে দুই ভাগ করতে হবে। | আমি | ১ দিন |
| ৮ | **টেস্ট**: (ক) রিমাইন্ডার ঠিক সময়ে বাজে কিনা: exact alarm, Doze, ColorOS/Realme। (খ) **ফোন রিস্টার্টের পরেও** রিমাইন্ডার থাকে কিনা (সম্প্রতি রিস্টার্টের পরের ক্র্যাশ ঠিক হয়েছে, আবার প্রমাণ লাগবে)। (গ) টাইমজোন বা ঘড়ির সময় বদলালে কী হয়। (ঘ) ডোজ মিসের পুরো ধাপ: রিমাইন্ডার, আবার রিমাইন্ডার, তারপর ফ্যামিলি পাতায় দেখা। **এখন পরিবারের কাছে সতর্কতা যায় শুধু অ্যাপ খুললে, সার্ভার নিজে push পাঠায় না।** তাই লিস্টিংয়ে "তাৎক্ষণিক সতর্কতা" লেখা যাবে না। (ঙ) বাংলা ও ইংরেজি। (চ) ২০০% ফন্ট, TalkBack, ৪৮dp। (ছ) ৯ শর্তের DoD। | আমি + আপনার ফোনে ১০ মিনিটের পরীক্ষা | ২–৩ দিন |
| ৯ | Play বিল্ডে গেট খোলা, সার্ভারের `is_play_flavour` আচরণ একসাথে বদলানো, **নতুন বিল্ড**, তারপর রিভিউ। শুধু ফ্ল্যাগ বদলালে হবে না, নতুন বিল্ড লাগবেই। | আমি, তারপর আপনি "Send for review" | বিল্ড ১ দিন; **স্বাস্থ্য-অ্যাপের রিভিউ ১–৭ দিন** (কখনো বেশি) |

**মোট সময় (সৎ হিসাব):** আমাদের কাজ (৫–৯) **৪–৬ কর্মদিবস**। এটা D-U-N-S-এর অপেক্ষার সময়েই করা যায়। কিন্তু মূল সময় যায় অপেক্ষায়: D-U-N-S ১–৬ সপ্তাহ, অ্যাকাউন্ট যাচাই ২–৭ দিন, রিভিউ ১–৭ দিন। **সব মিলিয়ে আজ থেকে প্রায় ৩–৮ সপ্তাহ।** সবচেয়ে ভালো ক্ষেত্রে (AXON Dynamic-এর D-U-N-S আগে থেকেই আছে) প্রায় ২ সপ্তাহ।
**৮ নভেম্বরের আগে (১২ দিন) হওয়া বাস্তবে প্রায় অসম্ভব।** তাই ৮ নভেম্বর যাবে **Case B** (ওষুধ ছাড়া) লিস্টিং নিয়ে। শর্তগুলো পূরণ হলে **Case A**। আপনার পছন্দ (ওষুধ চালু করা) রাখতে **আজই D-U-N-S খোঁজা বা আবেদন শুরু করুন।** দেরি শুধু এখানেই।

**আজই নিয়ম মেনে যা বলা যায় (দ্রুত ও নিরাপদ পথ):** "পরিবার ও রুটিনের রিমাইন্ডার"। যেমন: "রাত ৮টায় মাকে ফোন করতে মনে করিয়ে দিও", "আব্বুকে রাতের খাবারের পর মনে করিয়ে দিও"। ব্যবহারকারী নিজে যা লেখেন, রিমাইন্ডারে তা-ই থাকে। অ্যাপ বা লিস্টিং নিজে থেকে "ওষুধ, ডোজ, চিকিৎসা, রোগী" শব্দ ব্যবহার করবে না। Case B লিস্টিং এভাবেই লেখা।

---

## খ) পুরো অডিট: প্রতিটি লাইন ও ছবি

চিহ্ন: **OK** = Play বিল্ডে আজ আছে ও কাজ করে · **লুকানো** = Play বিল্ডে নেই · **তৈরি হয়নি** = কোথাও কাজ করে না বা নকল · **বিভ্রান্তিকর** = ভুল বা বাড়িয়ে বলা · **ঝুঁকি** = আজ দেখা যায়, কিন্তু `FEATURE_STATUS_BN.md` ৮ নভেম্বরের জন্য Play-তে লুকানোর প্রস্তাব দিয়েছে। লুকালে লিস্টিং থেকেও সরাতে হবে।
"ফ্ল্যাগ" মানে লাইভ `/features` (play)। "গেট" মানে বিল্ডের সময়ের গেট।

### শিরোনাম ও সংক্ষিপ্ত বিবরণ
| লাইন (লাইভ, en-US) | কী দাবি করে | Play-তে আজ | রায় |
|---|---|---|---|
| Title: "Assisto: Chat, AI & Business" (২৮) | চ্যাট, AI, ব্যবসা | my_circle, business = true | OK |
| Short: "Super app: chat,calls,family & safety,reminders,business & AI agent in one place" (৮০) | …"AI agent" সহ | business_agent = true (বিজনেস প্ল্যান লাগে) | ঝুঁকি: AI এজেন্ট লুকানোর প্রস্তাব আছে (Meta রিভিউ বাকি)। কমার পরে স্পেস নেই। নতুন লেখা দেওয়া হয়েছে। |
| বাংলা title, short ও full | — | **Play-তে বাংলা লিস্টিং নেই** | অনুপস্থিত। bn-BD যোগ করুন (FIXED.md-তে লেখা আছে)। |

### Full description (en-US), প্রতিটি লাইন
| # | লাইন (সংক্ষেপে) | Play-তে আজ (ফ্ল্যাগ / গেট) | রায় ও কারণ |
|---|---|---|---|
| 0 | "super app… let an AI agent answer your customers" | business_agent true | ঝুঁকি: বিজনেস প্ল্যান ও পেজ সংযোগ লাগে, লুকানোর প্রস্তাব আছে |
| 1 | E2E ব্যক্তিগত ও গ্রুপ চ্যাট, ছবি, ভয়েস নোট, ডকুমেন্ট | my_circle true | OK |
| 2 | ভয়েস/ভিডিও কল, টিক, typing, last seen, status | calls true | OK (স্ট্যাটাস শুধু লেখা; ছবি বা ভিডিও স্ট্যাটাস তৈরি হয়নি, তাই "text status" লিখুন) |
| 3 | Groups, channels, communities, message requests, encrypted backup | চালু | OK |
| 4 | **"Remind me about medicine at 8am"** | গেট `kMedicalFeaturesAllowed=false`। সার্ভার শুধু সাধারণ রিমাইন্ডার বানায় | **লুকানো / বিভ্রান্তিকর** (স্বাস্থ্য-দাবি) |
| 5 | "500 for lunch, add to expenses", undo কার্ড | money true | OK |
| 6 | যেকোনো প্রশ্ন কণ্ঠে বা লিখে; Daily brief | daily_brief true | ঝুঁকি: daily brief লুকানোর প্রস্তাব আছে (AI চাবি ছাড়া নকল ফল) |
| 7 | **"Hands-free voice assistant"**; ডিফল্ট অ্যাসিস্ট্যান্ট | voice_assistant true; "Hey Assisto" `VaWake.shipped=false` | **বিভ্রান্তিকর**: হাত না লাগিয়ে চালু করার wake-word লুকানো। ডিফল্ট অ্যাসিস্ট্যান্ট বানানো যায় (OK)। |
| 8 | কিছু বাইরে যাওয়ার আগে অনুমতি নেয় | — | OK |
| 9 | CV builder, mock interview, contract checker, blog writer | সব true | CV OK; বাকিগুলো ঝুঁকি (লুকানোর প্রস্তাব) |
| 10 | Travel planner, language partner, voice-to-text, personal secretary | সব true | ঝুঁকি (লুকানোর প্রস্তাব, AI চাবি-নির্ভর) |
| 11 | Business AI Agent ২৪/৭ উত্তর দেয় | business_agent true | ঝুঁকি: পেজ বা WhatsApp সংযোগে Meta রিভিউ বাকি |
| 12 | "never invents a price" | — | ঝুঁকি: পরম দাবি। নতুন লেখায় বলা হয়েছে "আপনার পণ্য ও দাম দেখে উত্তর দেয়"। |
| 13 | খাতা, দ্রুত বিক্রি, কার্ট, ক্যাশবক্স, রিপোর্ট | business true | OK |
| 14 | পণ্য, অর্ডার, গ্রাহক, CRM | business, crm true | OK |
| 15 | **"Courier booking"** | কোড বলছে "courier booking is key-gated mock"; Pathao/Steadfast/RedX চাবি নেই | **তৈরি হয়নি** (নকল) |
| 16 | Shop Box ও CCTV লাইভ ভিউ | cctv_watchman true, home_watchman false | ঝুঁকি (লুকানোর প্রস্তাব; আসল ক্যামেরা লাগে) |
| 17 | এক চাপে SOS, নকল কল | emergency, safe_journey true | OK |
| 18 | Safe Journey, safe-arrival | safe_journey true | OK |
| 19 | **"Medicine schedules for parents and children with 'please check' alerts"** | গেট false | **লুকানো** |
| 20 | Emergency card, blood donors, **doctor appointments**, school corner | emergency true (মেডিকেল তথ্য লুকানো); blood_donor true; doctor_serial **লুকানো**; kid_school true | **"doctor appointments" লুকানো**; blood donor ঝুঁকি (UGC); বাকি OK |
| 21 | Scam tips ও alerts | scam_check true | OK ("alerts" না লিখে "report" লেখা ভালো) |
| 22 | **"Remote lock and alerts if your phone is lost"**, SIM change alert | anti_theft true; `kLostActionSwitchesWired=false`, রিমোট ট্রিগার বা SMS-কমান্ড তৈরি হয়নি | **রিমোট লক তৈরি হয়নি / বিভ্রান্তিকর**। SIM alert আছে। পুরো anti_theft লুকানোর প্রস্তাব আছে (Device admin)। |
| 23 | Intruder photo, security check-up, used phone check | anti_theft true | OK, তবে ঝুঁকি (একই কারণে) |
| 24 | Fingerprint lock | — | OK |
| 25 | রিমাইন্ডার, নোট, to-do, task manager | reminders, notes, task_manager true | OK |
| 26 | জন্মদিন, বার্ষিকী, মিটিং, বিল, সাবস্ক্রিপশন, মেয়াদ | সব true | OK (birthdays ও meetings লুকানোর প্রস্তাব আছে, AI শুভেচ্ছা অংশের কারণে) |
| 27 | বিয়ে, রমজান, উৎসব | wedding_events, ramadan, qurbani true | OK |
| 28–31 | হিসাবের সব লাইন (বাজেট, ধার, যাকাত, ভাগাভাগি, মেস, সমিতি, ভাড়া, মিটার, "টাকা রাখি না") | সব true | OK |
| 32 | Photo enhance, পাসপোর্ট ও ভিসা ছবি | photo_studio true | OK |
| 33 | PIN ভল্ট, মেয়াদ রিমাইন্ডার, **ডকুমেন্ট স্ক্যানার** | documents true; doc_scanner true | ভল্ট OK; স্ক্যানার ঝুঁকি (OCR চাবি-নির্ভর) |
| 34 | Nominee access | nominee true | OK |
| 35 | "HEALTH AND FITNESS": Health Connect থেকে steps, heart rate, sleep | smartwatch true | ঝুঁকি: "Health" শিরোনাম বাদ দিন। Fitness ঘোষণা লাগে, লুকানোর প্রস্তাব আছে। |
| 36 | **"Medicine history, health timeline"**, water, sleep, wellness | health timeline ও medicine **লুকানো**; wellness true | **লুকানো** (প্রথম অংশ)। wellness ঝুঁকি। |
| 37 | **GPS tracking: "map"**, ২৪ ঘণ্টার প্লেব্যাক, geofence | vehicle_tracking true; স্ক্রিনে আঁকা রুট (RouteCanvas) দেখায়, আসল ম্যাপ নেই | **"map" তৈরি হয়নি / বিভ্রান্তিকর**। প্লেব্যাক আছে। লুকানোর প্রস্তাবও আছে। |
| 38 | Car OBD (Bluetooth) ও Car Mode | vehicles true | ঝুঁকি: শুধু টেস্টে প্রমাণিত, ELM327 অ্যাডাপ্টার লাগে |
| 39 | **Nearby places**, **jobs hub**, student corner, expat guide, service guides, exam results | nearby true কিন্তু Maps চাবি নেই, বাছাই করা নকল তালিকা দেখায়; jobs true কিন্তু `kJobsFeedConnected=false` (শুধু নিজের তালিকা); বাকিগুলো true | **Nearby ও Jobs hub বিভ্রান্তিকর**; বাকিগুলো OK |
| 40–41 | ডেটা বিক্রি নয়, অনুমতি, অ্যাকাউন্ট মোছা | — | OK |
| 42 | **"Free plan with optional ads"** | App-open, banner, native ও interstitial বিজ্ঞাপন ঐচ্ছিক নয়; শুধু rewarded ঐচ্ছিক | **বিভ্রান্তিকর** ("optional" ভুল) |
| 43 | **"Premium: no app-open ads and more AI credits"** | আসলে প্রিমিয়াম ও বিজনেসে **কোনো বিজ্ঞাপনই নেই** | **বিভ্রান্তিকর / ভুল** (কম বলা) |
| 44 | ১৮+; চিকিৎসা-পরামর্শ নয়; জরুরি সেবা নয় | — | OK (৯৯৯ নম্বর যোগ করা ভালো) |
| 45 | Privacy policy লিংক | — | OK। ডেভেলপারের নাম (AXON Dynamic) বর্ণনায় নেই, নতুন লেখায় যোগ করা হয়েছে। |

### স্ক্রিনশট (৮টি) ও ফিচার গ্রাফিক (লাইভ ছবি খুলে দেখা)
| # | ছবিতে যা আছে | Play-তে আজ | রায় |
|---|---|---|---|
| ১ | "Your super app": হোম, শর্টকাট (Reminders, Account & Finance, Notes, Assisto AI, Family, Documents) | সব আছে | OK |
| ২ | "Free chat & calls, End-to-end encrypted": চ্যাট, ছবি, ভয়েস নোট | আছে | OK |
| ৩ | "Voice & video calls": এনক্রিপ্টেড ভিডিও কল | আছে | OK |
| ৪ | **"Just say it": "Remind me medicine tomorrow 8am" থেকে "Medicine, Tomorrow 8:00" কার্ড** | ওষুধ লুকানো | **বিভ্রান্তিকর, এখনই সরান।** রিপোতে ঠিক করা ছবি তৈরি আছে: `play_store_v2/phone_en_4.png` ("Call mom")। |
| ৫ | "Money made clear": Total ৳২০,৮০০, কিন্তু Net worth ৳০ আর Accounts ০ | money আছে | ঠিক করুন: ডেমো সংখ্যাগুলো একে অপরের সাথে মেলে না |
| ৬ | "Run your shop": খাতা, বিক্রি | আছে | OK |
| ৭ | "Photo Studio": enhance, পাসপোর্ট, HD | আছে | OK |
| ৮ | "Family care & SOS": Safe Journey, SOS, ভয়েস SOS | আছে | OK |
| FG | ফিচার গ্রাফিক: Chat & Calls, AI Assistant, **Business AI Agent**, Reminders, Family & SOS, Photo Studio, Money | business_agent true | OK, তবে ঝুঁকি: AI এজেন্ট লুকালে চিপটি বদলাতে হবে |

### গণনা
- **বিভ্রান্তিকর বা লুকানো জিনিস দেখানো: ১৩টি।**
  - ওষুধ ও স্বাস্থ্য (লুকানো), ৫টি: লাইন ৪, ১৯, ২০ (doctor appointments), ৩৬, আর স্ক্রিনশট ৪।
  - তৈরি হয়নি বা বাড়িয়ে বলা, ৬টি: hands-free (৭), courier booking (১৫), remote lock (২২), vehicle "map" (৩৭), nearby places ও jobs hub (৩৯, দুটি)।
  - বিজ্ঞাপন বা প্ল্যানের ভুল কথা, ২টি: লাইন ৪২ ও ৪৩।
- অন্যান্য: বাংলা লিস্টিং নেই (১), মানি স্ক্রিনশটের ডেমো সংখ্যা মেলে না (১), "ঝুঁকি" চিহ্নিত লাইন প্রায় ১৫টি (আজ দেখা যায়, কিন্তু ৮ নভেম্বরে লুকানোর প্রস্তাব আছে)।
- নতুন লেখায় ঝুঁকির ফিচারগুলো মূল লেখা থেকে বাদ রাখা হয়েছে। প্রতিটির জন্য আলাদা "add-on" লাইন আছে। যেটা Play-তে চালু রাখবেন, শুধু সেটার লাইন পেস্ট করবেন।

---

## STATUS-এ পেস্ট করার অংশ (বাংলা)

> ## 🏷️ Play লিস্টিং বনাম অ্যাপ: অডিট (২৭ Oct; কিছু বদলানো হয়নি)
> ১. **ওষুধ কেন লুকানো:** ২৪ Oct Play অ্যাপ বাতিল করেছিল। "Medication and treatment management" ফিচার personal অ্যাকাউন্ট থেকে প্রকাশ করা যায় না, Organization অ্যাকাউন্ট লাগে। তাই Play বিল্ডে ওষুধ বিল্ডের সময়েই বন্ধ (`kMedicalFeaturesAllowed`)।
> ২. **দেখাতে যা লাগবে:** D-U-N-S (ফ্রি) → org অ্যাকাউন্ট যাচাই → Health apps ঘোষণা → Data safety-তে "Health info" → গোপনীয়তা নীতিতে স্বাস্থ্য-অংশ → অ্যাপ ও লিস্টিংয়ে দাবিমুক্তি ("চিকিৎসা-পরামর্শ নয়, ডোজ বলে না") → টেস্ট (সময়, রিস্টার্ট, টাইমজোন, ডোজ মিস, বাংলা/ইংরেজি, অ্যাক্সেসিবিলিটি) → নতুন বিল্ড।
> ৩. **সময়:** আমাদের কাজ ৪–৬ দিন। D-U-N-S, যাচাই আর রিভিউয়ের অপেক্ষা মিলিয়ে মোট **৩–৮ সপ্তাহ**। **৮ নভেম্বরের আগে বাস্তবে সম্ভব নয়।** আজই D-U-N-S শুরু করুন।
> ৪. **অডিট:** লাইভ লিস্টিংয়ে **১৩টি** বিভ্রান্তিকর বা লুকানো জিনিসের দাবি। এর মধ্যে ৫টি ওষুধ বা স্বাস্থ্য, ৬টি তৈরি হয়নি (courier, remote lock, hands-free, map, nearby, jobs), ২টি বিজ্ঞাপনের ভুল কথা। বাংলা লিস্টিং নেইই।
> ৫. **এখনই (৫ মিনিট):** স্ক্রিনশট ৪ ("Medicine" কার্ড) সরিয়ে `play_store_v2/phone_en_4.png` দিন, তারপর `PLAY_LISTING_FIXED.md`-এর **Case B** লেখা পেস্ট করুন (ইংরেজি ও বাংলা)।
> ৬. ওষুধ চালু হলে **Case A** লেখা পেস্ট করবেন। বিস্তারিত: `owner_actions/PLAY_LISTING_AUDIT_BN.md`।
