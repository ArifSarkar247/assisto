# Play production আবেদন — উত্তর, ঘোষণা ও "1 not yet sent for review" (৯ Nov ২০২৬)

শাখা `agent/playprod` · মালিকের আদেশ ৯ Nov ১৩:৪০। **এজেন্ট Play Console বা Play API ছোঁয়নি।** সব লেখা রেপোর রেকর্ড থেকে।
যেটা রেকর্ডে নেই সেটা **[OWNER FILL: …]** — Play Console দেখে আপনি বসাবেন। আগের খসড়া `PLAY_PRODUCTION_ACCESS_ANSWERS.md` (২ Nov) — এই ডক সেটাকে বদলে দেয়।

**কোন রেকর্ড থেকে নেওয়া:**
- ২ Nov-এর আসল সংখ্যা (`PLAY_PRODUCTION_ACCESS_ANSWERS.md`): ১২ জন টেস্টার opt-in (আপনি Console-এ দেখেছিলেন); সার্ভারে ১৪ দিনে ২০টি ফোনে অ্যাপ খোলা; ১৬ জন My Circle-এ ১৫১টি মেসেজ; ১৪ দিনে ১৩টি স্বয়ংক্রিয় ত্রুটি-রিপোর্ট (৩টি ক্র্যাশ), প্রতিটি পরের বিল্ডে ঠিক; অ্যাপের "Send feedback" রিপোর্ট ০টি।
- `logs/play_upload.log`: ২৫ Oct থেকে ৯ Nov পর্যন্ত **৫৬টি আলাদা বিল্ড** (233 → 316) internal + closed testing (alpha)-এ গেছে, প্রতিটি `review=auto`। বিল্ড ৩১৭ লেখার সময় লগে ছিল না।
- আপনার ফোন-পরীক্ষার বাগ ও ঠিক করা (git log, STATUS): খোঁজে "Chandra, Gazipur" লিখে কিছু না আসা (৪ Nov, `OWNER_JOURNEY_SEARCH_BUG_4NOV_0005.md`); দূরের যাত্রায় ভুল "পৌঁছেছেন" (৬ Nov, কারণ খুঁজে পাওয়া গেছে ৯ Nov); দ্বিতীয় ফোনে লগইন করলে প্রথমটি বের হয়ে যাওয়া (বিল্ড ৩১৭-এ ঠিক); অ্যালবামে লং-প্রেস ভুল ছবিতে (৩১৭-এ ঠিক); অ্যাপ বন্ধ থাকলে মেসেজের ভুল শব্দ (৩১৭-এ ঠিক)। ২ Nov-এর ডকে: লক-স্ক্রিন থেকে কল ধরা, ইয়ারফোনে কলের শব্দ, ন্যাভিগেশন বারের নিচে পাতা ঢাকা, Family Care-এ একই কার্ড বারবার।
- E2E প্রমাণ: রান 42557563988 — এমুলেটরে ৮টি মূল কাজের ৮টিই পাস (`E2E_PROOF_BN.md`)। Test Lab (আসল ফোন) এখনো চলেনি — `GCP_TESTLAB_SA` secret নেই।

---

## ১. Production access প্রশ্নোত্তর

**Google-এর সীমা (৯ Nov যাচাই):** Google-এর সহায়তা পাতা ([answer/14151465](https://support.google.com/googleplay/android-developer/answer/14151465)) প্রশ্নগুলোর তালিকা দেয়, কিন্তু **কোনো অক্ষর-সীমা লেখে না**। ফর্মে ৩টি অংশ: closed test, অ্যাপ, production readiness। দুটি প্রশ্ন বহুনির্বাচনী: নিয়োগ কতটা সহজ ছিল (Very difficult … Very easy) আর প্রথম বছরের install (Under 1K / 1K–10K / 10K–100K / 100K+)। Google-এর বাইরের গাইড বলে প্রতিটি উত্তর অন্তত ২৫০–৩০০ অক্ষর হওয়া ভালো। তাই নিচের প্রতিটি ইংরেজি উত্তর **৩০০–৯০০ অক্ষরের** মধ্যে রাখা হয়েছে (প্রতিটির পাশে গোনা আছে)। Console বক্সে কম সীমা দেখালে শেষের বাক্যটি বাদ দিন। রিভিউ সাধারণত ৭ দিন বা কম লাগে। "আরো টেস্টিং দরকার" এলে closed test চালু রাখতে হয়।

> **সততার নিয়ম:** [OWNER FILL]-এর জায়গা না ভরে পেস্ট করবেন না। মিথ্যা সংখ্যা দিলে আবেদন বাতিল হতে পারে, অ্যাকাউন্টও ঝুঁকিতে পড়ে।

### প্রশ্ন ১ — How did you recruit testers? (৩৪১ অক্ষর, [OWNER FILL] ভরার আগে)
**EN:**
> [OWNER FILL: confirm — 2 Nov draft said: family, friends and small-business owners in Bangladesh whom the developer knows personally, invited by email to the closed test]. We chose them because they match our real audience: Bangla-speaking families and small shop owners using common Android phones (including Realme/ColorOS) on mobile data.

**বাংলা:** টেস্টার কীভাবে পেয়েছেন — ২ Nov-এর খসড়ায় লেখা ছিল "ডেভেলপারের পরিচিত পরিবার, বন্ধু ও ছোট দোকানি, ইমেইলে আমন্ত্রণ"। এটা ঠিক কিনা আপনি নিশ্চিত করুন। কোনো পেইড টেস্টিং সার্ভিস ব্যবহার করে থাকলে সেটাও লিখুন। আমরা তাদের বেছেছি কারণ তারা আমাদের আসল ব্যবহারকারীর মতো।
**কোথায় দেখবেন:** Play Console → Testing → Closed testing → **Testers** ট্যাব (কোন ইমেইল লিস্ট/Google Group)।

### প্রশ্ন ২ — How easy was it to recruit testers? (বহুনির্বাচনী)
**[OWNER FILL: আপনার অভিজ্ঞতা অনুযায়ী বাছুন।]** রেকর্ডে এ বিষয়ে কিছু নেই।

### প্রশ্ন ৩ — Describe the engagement you received from testers (৬৪৭ অক্ষর)
**EN:**
> Testers used Assisto on their own phones during the whole test: My Circle messages and voice/video calls, Safe Journey sharing, SOS and family alerts, reminders, budget and khata entries, Care Call and the AI chat. In the 14 days to 2 Nov, 20 devices opened the app and 16 testers exchanged 151 My Circle messages; [OWNER FILL: current numbers from Play Console → Statistics / closed track (active users, installs)]. Not every feature was used equally: messaging, calls, reminders and Safe Journey were used most; business and CCTV tools mainly by the shop owners. We shipped 56 test builds between 25 Oct and 9 Nov, so testers kept getting fixes.

**বাংলা:** টেস্টাররা নিজের ফোনে পুরো সময় ব্যবহার করেছেন: My Circle মেসেজ ও কল, নিরাপদ যাত্রা, SOS, রিমাইন্ডার, বাজেট-খাতা, কেয়ার কল, AI চ্যাট। ২ Nov পর্যন্ত ১৪ দিনে ২০টি ফোনে অ্যাপ খোলা হয়েছে, ১৬ জন ১৫১টি মেসেজ পাঠিয়েছেন। এখনকার সংখ্যা আপনি Console থেকে বসাবেন। সব ফিচার সমান ব্যবহার হয়নি — মেসেজ, কল, রিমাইন্ডার, যাত্রা বেশি; ব্যবসা ও CCTV মূলত দোকানিরা। ২৫ Oct–৯ Nov ৫৬টি টেস্ট বিল্ড।
**যাচাই করুন:** "business and CCTV tools mainly by the shop owners" বাক্যটি — রেকর্ডে প্রমাণ নেই। [OWNER FILL: সত্য না হলে বাক্যটি মুছুন।] Console → **Statistics** (closed track ফিল্টার) থেকে active users বসান। চাইলে লিড সার্ভার থেকে নতুন ১৪-দিনের read-only গণনা দিতে পারে (২ Nov-এর মতো)।

### প্রশ্ন ৪ — Summarize the feedback and how you collected it (৭০১ অক্ষর)
**EN:**
> Most feedback came from direct phone tests and messages to the developer [OWNER FILL: channel — e.g. WhatsApp/phone calls/email]; [OWNER FILL: number of written Play tester feedback items, if any]. The app also sends scrubbed error reports (no message text): 13 reports from 5 users in the 14 days to 2 Nov, 3 of them crashes. Main feedback: an incoming call could not be accepted from the lock screen on some phones; earphones got no call audio; screens hid behind the navigation bar; place search for a far town ("Chandra, Gazipur") showed no suggestions; two long trips were marked "arrived" too early; signing in on a second phone signed out the first; a long-press acted on the wrong album photo.

**বাংলা:** বেশিরভাগ মতামত এসেছে সরাসরি ফোন-পরীক্ষা আর ডেভেলপারকে পাঠানো বার্তা থেকে। কোন মাধ্যমে এসেছে (WhatsApp/ফোন/ইমেইল), সেটা আপনি বসাবেন। অ্যাপ নিজে থেকে ত্রুটি-রিপোর্টও পাঠায়, মেসেজের লেখা ছাড়া: ২ Nov পর্যন্ত ১৪ দিনে ৫ জনের ১৩টি রিপোর্ট, তার ৩টি ক্র্যাশ। মূল মতামত ছিল: লক-স্ক্রিন থেকে কল ধরা যেত না; ইয়ারফোনে কলের শব্দ আসত না; পাতা ন্যাভিগেশন বারের নিচে ঢাকা পড়ত; "Chandra, Gazipur" খুঁজলে কিছু আসত না; দূরের যাত্রায় আগেভাগে "পৌঁছেছেন" দেখাত; দ্বিতীয় ফোনে লগইন করলে প্রথম ফোন বের হয়ে যেত; অ্যালবামে লং-প্রেস করলে ভুল ছবিতে কাজ হতো।
**সৎ সতর্কতা:** ২ Nov-এ অ্যাপের "Send feedback" রিপোর্ট ছিল ০টি। "Testers sent in-app feedback" লিখবেন না, যদি না Console → Closed testing → **Feedback** (বা Ratings & reviews → Testing feedback)-এ সত্যিই কিছু থাকে। এর অনেক বাগ আপনার নিজের ফোন-পরীক্ষায় পাওয়া। আপনি নিজেও টেস্টার হলে লেখাটা সৎ থাকে।

### প্রশ্ন ৫ — Who is the intended audience? (৪২০ অক্ষর)
**EN:**
> Adults (18+) in Bangladesh and Bangladeshis living abroad, using Bangla or English on everyday Android phones (Android 8 and newer, often on mobile data). Two groups: families who want to stay in touch and keep each other safe (messages, calls, Safe Journey, SOS, Care Call for elderly parents), and small shops and businesses that keep a khata, send invoices and talk to customers. The app is not designed for children.

**বাংলা:** বাংলাদেশ ও প্রবাসের প্রাপ্তবয়স্ক (১৮+), সাধারণ Android ফোনে বাংলা বা ইংরেজিতে। দুই দল: পরিবার (যোগাযোগ ও নিরাপত্তা, বয়স্ক মা-বাবার কেয়ার কল) আর ছোট দোকান/ব্যবসা (খাতা, ইনভয়েস, গ্রাহক)। শিশুদের জন্য বানানো নয়। (Target audience ফর্মের সাথে মিলিয়ে নিন: ১৮+।)

### প্রশ্ন ৬ — How does your app provide value? (৫৪৫ অক্ষর)
**EN:**
> Assisto puts in one Bangla-first app what Bangladeshi families now spread over several apps: end-to-end encrypted family messaging and calls, Safe Journey live sharing until arrival, SOS to family, Care Call reminder calls in a family member's own voice, reminders, budget and khata, and an AI assistant that answers in Bangla. Small shops get a khata with due reminders, invoices and a simple ledger. Safety features (SOS, Safe Journey, family alerts) are free on every plan and never show ads. It works on low-cost phones and slow mobile data.

**বাংলা:** পরিবার যেসব কাজ এখন কয়েকটা অ্যাপে করে, Assisto সেগুলো একটি বাংলা-প্রথম অ্যাপে আনে: এন্ড-টু-এন্ড এনক্রিপ্টেড মেসেজ ও কল, পৌঁছানো পর্যন্ত নিরাপদ যাত্রা, পরিবারের কাছে SOS, নিজের গলায় কেয়ার কল, রিমাইন্ডার, বাজেট-খাতা, বাংলায় উত্তর দেওয়া AI। দোকানের জন্য বাকির খাতা, তাগাদা, ইনভয়েস। নিরাপত্তা ফিচার সব প্ল্যানে ফ্রি, বিজ্ঞাপন নেই। কম দামের ফোন আর ধীর নেটেও চলে।

### প্রশ্ন ৭ — Installs in the first year (বহুনির্বাচনী)
**[OWNER FILL: বাছুন।]** রেকর্ডে কোনো লক্ষ্য বা মার্কেটিং বাজেট নেই। ২ Nov-এ সার্ভারে অ্যাকাউন্ট ছিল ২৯টি। আপনার কোনো পরিকল্পনা না থাকলে সবচেয়ে সৎ বাছাই **1K–10K**। বড় সংখ্যা বাছলে Google প্রশ্ন করতে পারে, কোন পরিকল্পনা থেকে এত ইনস্টল আসবে।

### প্রশ্ন ৮ — What changes did you make based on the closed test? (৭৮১ অক্ষর)
**EN:**
> Every tester report became a fix and, where possible, an automated test. Calls: lock-screen answering and one app-wide audio route for Bluetooth and wired earphones. Layout: an app-wide fix plus an automatic check so no screen hides behind the navigation bar. Safe Journey: a new place search with suggestions from the second letter (found when a tester could not find a far town); the early "arrived" cause was found (the manual "I've arrived" path did not check distance or time) and arrival now needs real checks. My Circle: signing in on a second phone no longer signs out the first; quiet hours; correct message sound when the app is closed. Family Care was redesigned (no repeated cards, people picked from My Circle in one tap). Each crash report was fixed in a later build.

**বাংলা:** প্রতিটি টেস্টার-রিপোর্ট ঠিক করা হয়েছে, আর যেখানে সম্ভব, সেটার জন্য স্বয়ংক্রিয় টেস্টও বসানো হয়েছে। কল: লক-স্ক্রিনে ধরা যায়; ব্লুটুথ ও তারের ইয়ারফোনের শব্দ এখন এক ব্যবস্থায় চলে। পাতা: পুরো অ্যাপে ন্যাভিগেশন বারের ঢাকা পড়া ঠিক, সাথে স্বয়ংক্রিয় চেক। নিরাপদ যাত্রা: দ্বিতীয় অক্ষর থেকেই জায়গার পরামর্শ দেখায়। আগেভাগে "পৌঁছেছেন" দেখানোর কারণ পাওয়া গেছে: হাতে চাপা "পৌঁছে গেছি" দূরত্ব বা সময় যাচাই করত না।
**⚠️ যাচাই করুন:** "arrival now needs real checks" কথাটি Safe Journey V2 শিপ হওয়ার **পরে** সত্য হবে (৯ Nov STATUS: "V2-তে ঠিক হচ্ছে")। আবেদনের দিনে V2 Play-তে না গেলে বাক্যটি এভাবে বদলান: "…the cause was found and the fix is in the next build"। My Circle-এর তিনটি ঠিক করা বিল্ড ৩১৭-এ আছে। ৩১৭ Play-তে না পৌঁছালে সেটাও লিখুন।

### প্রশ্ন ৯ — How did you decide the app is ready for production? (৬৮২ অক্ষর)
**EN:**
> Every build runs the full automated test suite (backend and app) in CI before it can be published, plus a launch check on an Android 13 emulator. On 9 Nov our scripted end-to-end proof passed 8 of 8 main flows on an emulator: sign-up/login, Bangla AI chat, encrypted family messages and photos, Safe Journey, SOS to a guardian, a reminder that fires on time, a khata entry, and Care Call. Crash reports from the test were fixed. Safety features are free and work without ads. We will release in stages (for example 10% → 50% → 100%) and watch Android vitals (crash and ANR rates) before each step, with a one-tap feature switch on our server to turn off any feature that misbehaves.

**বাংলা:** প্রতিটি বিল্ড প্রকাশের আগে CI-তে পুরো স্বয়ংক্রিয় টেস্ট চলে, আর Android 13 এমুলেটরে চালু-পরীক্ষা হয়। ৯ Nov স্ক্রিপ্ট-চালিত E2E প্রমাণে ৮টি মূল কাজের ৮টিই পাস করেছে। টেস্টের সময় আসা ক্র্যাশ ঠিক করা হয়েছে। নিরাপত্তা ফিচার ফ্রি, বিজ্ঞাপন ছাড়া। রিলিজ যাবে ধাপে ধাপে, আর প্রতিটি ধাপের আগে ক্র্যাশ/ANR দেখা হবে। কোনো ফিচার গোলমাল করলে সার্ভার থেকে এক চাপে বন্ধ করা যায়।
**সৎ সতর্কতা:** আসল ফোনে (Test Lab) E2E এখনো চলেনি। তাই "tested on real devices in a lab" লিখবেন না। কোয়ালিটি বোর্ডে এখন ৯+ ফিচার ০/৬০ — এটা আমাদের ভেতরের কড়া লক্ষ্য, Play-র প্রশ্ন নয়। লঞ্চের তারিখ আর ধাপ (Owner item ১০) আপনার সিদ্ধান্ত।

### প্রশ্ন ১০ — What did you do differently this time? (শুধু আগে "more testing" প্রত্যাখ্যান হলে আসে)
রেকর্ডে আগের কোনো আবেদন নেই। এই প্রশ্ন না এলে কিছু করতে হবে না। [OWNER FILL: আগে আবেদন করে থাকলে জানান।]

---

## ২. App content ঘোষণা — আবেদনের আগে বা সাথে

**মূল কথা (কোড থেকে):**
- Play বিল্ডে **`ACCESS_BACKGROUND_LOCATION` নেই।** এটা ফিরে এলে CI বিল্ড ফেল করায় (`android.yml`-এর "playall" গেট)। তাই Console-এ "Location permissions" (background) ফর্ম আসবে না। এখন সেটা জমা দেওয়ার কিছু নেই।
- Family Care আর নিরাপদ যাত্রা লোকেশন নেয় **foreground service (টাইপ location)** দিয়ে। এই সার্ভিস ব্যবহারকারী নিজে চালু করেন, আর চলার সময় নোটিফিকেশন ও Stop বোতাম থাকে। Google এর জন্য চায় **FGS ঘোষণা + ভিডিও**।
- Google-এর নিয়ম: FGS-এর লোকেশন ব্যবহার "ব্যাকগ্রাউন্ডের সমান" হলে ব্যাকগ্রাউন্ড-নিয়ম খাটে ([answer/9799150](https://support.google.com/googleplay/android-developer/answer/9799150))। ঝুঁকিটা সবচেয়ে বেশি হারানো/চুরি সুরক্ষায় (`PLAY_FGS_DECLARATION_BN.md` → "ঝুঁকি ও বিকল্প")।

| # | ঘোষণা (Console → Policy → App content) | অবস্থা | কী করবেন |
|---|---|---|---|
| ক | **Foreground service permissions → Microphone** (Voice SOS, My Circle কল চালু রাখা, শিশুর জরুরি অডিও, **"Hey Assisto"**) | "Hey Assisto" আছে ৩১৬ থেকে; আপনার করণীয় #৫-এ বাকি | নিচে §২.১ |
| খ | **Foreground service permissions → Location** (নিরাপদ যাত্রা, Voice SOS, চুরি-রোধ, অভিভাবক-অনুরোধে যাত্রা, ট্রেন "আমি এই ট্রেনে", গন্তব্য অ্যালার্ম) | ৫ Nov-এর মধ্যে জমা দেওয়ার কথা ছিল — [OWNER FILL: জমা দিয়েছেন কি?] | §২.২ + ভিডিও §২.৬ |
| গ | **Full-screen intent → Calling** (My Circle কল + **কেয়ার কল**) | আপনার করণীয় #৫-এ বাকি | §২.৩ |
| ঘ | **Data safety** — নতুন সারি (কেয়ার কলের ভয়েস, নোটিফিকেশন থেকে টাকা, ট্রেন যাত্রীর অবস্থান ইত্যাদি) | ৮ Nov চেকলিস্টের পরের নতুন অংশ | §২.৪ |
| ঙ | **নোটিফিকেশন অ্যাক্সেস** (bKash/Nagad/Rocket/Upay টাকার নোটিফিকেশন, কল শেষ বোঝা) | আলাদা ফর্ম নেই; App access নোট + Data safety লাগবে | §২.৫ |
| চ | Health apps / Health Connect, Ads + Advertising ID, Device admin, Financial features ("personal finance only", ঋণ বা পেমেন্ট নয়), Target audience ১৮+ | আগের ডকগুলোতে তৈরি | `PLAY_HEALTH_DECLARATION_BN.md`, `ADMOB_PLAY_DECLARATIONS_BN.md`, `ANTITHEFT_PLAY_DECLARATION_BN.md`, `PLAY_PRODUCTION_CHECKLIST_8NOV_BN.md` ধাপ ৩–৬ |

### ২.১ Microphone FGS — "Hey Assisto" যোগ (EN, পেস্ট করুন)
> Microphone foreground service, always started by the user and always shown in a notification with a stop button: (1) Voice SOS — while the user keeps it on, the phone listens on-device for the user's own emergency phrase and sends an SOS with location to family; (2) an ongoing My Circle voice/video call keeps the microphone when the user leaves the app; (3) optional hands-free "Hey Assisto", off by default, turned on in Settings > Assisto Voice after an in-app disclosure; an on-device model checks 80 ms audio pieces and discards them — nothing is recorded or uploaded before the wake word; it pauses on calls, Battery Saver and low battery; it is never started at app launch or at boot.

**User impact if deferred (EN):** "An SOS phrase would not be heard, an ongoing family call would lose audio, and the hands-free wake word would stop. These run only while the user has them on."
বাংলা: মাইক্রোফোন সার্ভিস সবসময় ব্যবহারকারী নিজে চালু করেন, আর নোটিফিকেশনে Stop বোতাম থাকে। এটা তিনটি কাজে লাগে: ভয়েস SOS, কল চলাকালে অ্যাপ থেকে বের হলেও শব্দ, আর ঐচ্ছিক "Hey Assisto"। "Hey Assisto"-তে শব্দ ফোনেই যাচাই হয়ে মুছে যায়, ওয়েক-ওয়ার্ডের আগে কিছু রেকর্ড বা আপলোড হয় না। ভিডিওর স্ক্রিপ্ট: `WAKE_WORD_PLAY_BN.md` §২।

### ২.২ Location FGS (EN) — `PLAY_FGS_DECLARATION_BN.md` §২-এর লেখাই হুবহু দিন
সেই লেখা কোডের সাথে মেলে (৯ Nov আবার দেখা হয়েছে: সার্ভিস `flutter_foreground_task` `microphone|location` আর `AntiTheftService` `location`; `GeolocatorLocationService` সরানো)। Use case: **"User-initiated location sharing"**। নতুন কিছু যোগ হয়নি।
**Family Care:** এখনকার Family Care-এ নিজের কোনো লোকেশন-সার্ভিস নেই। সতর্কতা আসে অ্যাপ খুললে (WorkManager নেই)। তাই আলাদা করে ঘোষণা করার দরকার নেই।

### ২.৩ Full-screen intent (EN) — `CARE_CALL_PLAY_DECLARATION_BN.md` §১-এর লেখা
বাছুন শুধু **"Calling"** — "Alarm" নয় (কোডে full-screen শুধু ইনকামিং কল ও কেয়ার কলের রিং-এ)। লেখা:
> Assisto uses full-screen intents only for incoming calls: (1) My Circle voice and video calls between family members, and (2) Care Call — a family care reminder call that a family member schedules for a loved one. At the scheduled time the receiver's phone shows a full-screen incoming-call screen with the family member's own recorded voice and two large buttons ("Done" / "Remind me in 10 minutes"). The receiver accepts Care Calls from each family member once and can stop them any time. Full-screen intents are never used for ads or promotions.

Google-এর নিয়ম: Android 14+-এ full-screen intent শুধু calling/alarm অ্যাপ নিজে থেকে পায়; অন্যদের ঘোষণা দিতে হয়, নইলে Play অনুমতিটা কেড়ে নিতে পারে। কেয়ার কলকে **"medical" বলবেন না।**

### ২.৪ Data safety — ৮ Nov চেকলিস্টের (ধাপ ৩) পরে যা নতুন এসেছে
আগে চেকলিস্টের মূল টেবিল আর ১–১১ সারি বসান। তারপর নিচেরগুলো মিলিয়ে নিন:

| নতুন ফিচার (বিল্ড) | Play ডেটা টাইপ | Collected / Shared / ঐচ্ছিক | কোড যা করে |
|---|---|---|---|
| **কেয়ার কল** (৩১৪) | Audio → Voice or sound recordings; App activity → Other user-generated content | হ্যাঁ / না / ঐচ্ছিক | সেটারের নিজের রেকর্ড শুধু সেই রিসিভারের ফোনে যায়, AI-তে যায় না; কেয়ার কল মুছলে ফাইলও মোছে |
| **নোটিফিকেশন থেকে টাকা + কলের পরে নোট** (callmoney) | Financial → Other financial info | হ্যাঁ / না / ঐচ্ছিক | শুধু ব্যবহারকারী যেটা নিশ্চিত করেন সেই লেনদেন (টাকা, ধরন, ওয়ালেট, TrxID) সার্ভারে যায়; বার্তা নিজে ফোন ছাড়ে না। **Messages (SMS) = No**, Phone calls = No |
| **"Hey Assisto"** (৩১৬) | — (নতুন টাইপ নেই) | — | শব্দ ফোনেই যাচাই, জমা হয় না। ওয়েক-ওয়ার্ডের পরের কথা আগের Audio/AI চ্যাট সারিতেই পড়ে |
| **ট্রেন যাত্রীর অবস্থান** (train) | Location → Precise (আগের সারি ৩) | হ্যাঁ / না / ঐচ্ছিক | "আমি এই ট্রেনে আছি" চালু থাকলে সার্ভারে যায়; সম্মতির পাতা আগে |
| **খাতার তাগাদা-লিংক** (tagada) | Personal info → Name, Phone; Financial → Other (আগের সারি ৭) | হ্যাঁ / না / ঐচ্ছিক | দোকানি নিজে গ্রাহকের নাম-নম্বর লেখেন, লিংক দোকানি নিজে পাঠান |
| **AI প্রদানকারী** (৯ Nov: Gemini বন্ধ, Anthropic + ফোনের মডেল) | — | service provider, তাই "shared" নয় | প্রাইভেসি পলিসিতে প্রদানকারীর নাম ঠিক আছে কিনা দেখুন [OWNER FILL: lifeassisto.com/privacy-তে Gemini লেখা থাকলে লিডকে বলুন] |
| **CCTV extra pack** (Play-তে টাকা দিয়ে কেনা, ৯ Nov) | Financial → Purchase history (আগে থেকেই আছে) | — | নতুন টাইপ নেই |

**এখনো তৈরি হয়নি (শুধু স্পেক, ৯ Nov) — শিপের দিন Data safety বদলাতে হবে:**
- **Family Care V3 "নীরব পাহারা"** (আনলক, চলাফেরা, চার্জ — স্পেকে "সার্ভারে কোনো ট্র্যাকিং স্ট্রিম নয়, ফোনেই শেখা"। সার্ভারে শুধু সতর্কতা গেলে নতুন টাইপ লাগবে না। "নড়াচড়া" মাপতে `ACTIVITY_RECOGNITION` লাগলে **সেটা এখন CI-তে নিষিদ্ধ** — যোগ করার আগে আপনার অনুমতি লাগবে);
- **নিজে-থেকে পৌঁছানো/বের হওয়া (geofence)** আর Safe Journey V2-এর "বাড়ি থেকে বের হলে প্রস্তাব" — এগুলোর জন্য প্রায় নিশ্চিতভাবে **`ACCESS_BACKGROUND_LOCATION`** লাগবে, তখন §২.৬-এর ব্যাকগ্রাউন্ড ফর্ম আর ভিডিও;
- **City Service "যাত্রা থেকে শেখা"** (সম্মতিতে, নাম ছাড়া GPS ট্রেস) — Location → Precise, purpose-এ "App functionality" (+ "Analytics" যদি রুট খোঁজার কাজে লাগে); প্রাইভেসি পলিসিতে আলাদা লাইন;
- **SOS-এ নেট না থাকলে SMS** — `SEND_SMS` এখন CI-তে নিষিদ্ধ; এর বদলে SMS অ্যাপ খুলে দেওয়া (ব্যবহারকারী নিজে Send চাপবেন) হলে ফর্ম লাগবে না।

### ২.৫ নোটিফিকেশন অ্যাক্সেস (NotificationListenerService) — কোড যা করে
`AssistoNotifListener` (android.yml "callmoney"): Android এটা চালু করে শুধু তখন, যখন ব্যবহারকারী নিজে Settings-এ Notification access দেন। অ্যাপে আগে প্রকাশ-পাতা দেখায় ("Agree and turn on" / "Not now")। কোনো `READ_SMS`, `READ_PHONE_STATE`, `READ_CALL_LOG` নেই। কল রেকর্ড হয় না।
**Google-এর নিয়ম:** Notification access-এর জন্য আলাদা Console ফর্ম নেই। তবে **User Data policy** খাটে: অ্যাপের ভেতরে স্পষ্ট প্রকাশ + সম্মতি, Data safety-তে সৎ উত্তর, প্রাইভেসি পলিসিতে লাইন।
**App access → Instructions (EN, রিভিউয়ারের জন্য):** `CALL_NOTE_MONEY_PLAY_BN.md` §৪-এর লেখা হুবহু দিন।
**ঝুঁকি (সৎভাবে):** লিসনার bKash ইত্যাদি প্রেরকের **SMS-নোটিফিকেশন**-ও পড়ে। একজন রিভিউয়ার এটাকে SMS নীতি এড়ানো মনে করতে পারেন। আমাদের পক্ষে যা আছে: SMS অনুমতি নেই; শুধু অনুমোদিত প্রেরক; সব বিশ্লেষণ ফোনে; বার্তা সার্ভারে যায় না; ফিচারটি ঐচ্ছিক। প্রত্যাখ্যান হলে "SMS থেকে" অংশটি Play বিল্ডে বন্ধ করা যায় (শুধু ওয়ালেট-অ্যাপের নোটিফিকেশন থাকবে) — লিডকে বলুন।

### ২.৬ ভিডিও — আজ CI থেকে বানানো যায়নি; নিচে হুবহু শট-লিস্ট
**কেন CI-তে আজ হয়নি:** আমাদের E2E এমুলেটর-রান লোকেশন, মাইক্রোফোনসহ সব অনুমতি আগেই `adb` দিয়ে দিয়ে রাখে (`tools/reality/run_flows.sh` লাইন ৫৮)। এমুলেটরে চলমান GPS-ও নেই। ফলে CI-রেকর্ডিংয়ে Google যা দেখতে চায় — প্রকাশ-পাতা → Android-এর অনুমতি-প্রশ্ন → চলমান লোকেশন — ঠিক সেটাই বাদ পড়ত। এমন ভিডিও জমা দিলে উল্টো প্রত্যাখ্যানের ঝুঁকি। আলাদা একটা CI রেকর্ডিং-ফ্লো বানানো সম্ভব: অনুমতি আগে না দেওয়া, UiAutomator দিয়ে অনুমতি-প্রশ্নে চাপ, `adb emu geo fix` দিয়ে পথ চালানো, `screenrecord --time-limit 30`। এটা একটা আলাদা কাজ (কয়েকটি CI রান লাগবে) — লিড চাইলে পরের কাজ হিসেবে দেবে। **সবচেয়ে দ্রুত আর সৎ উপায়:** আপনার Realme-এ Android-এর নিজের স্ক্রিন-রেকর্ডার দিয়ে ২ মিনিটে রেকর্ড করা।

**Location FGS ভিডিও (≤৩০ সেকেন্ড, YouTube unlisted; শুরুর আগে Settings → Apps → Assisto → Permissions → Location → "Don't allow" করে নিন যাতে প্রশ্ন আসে):**
| সময় | পর্দায় যা দেখাবেন |
|---|---|
| ০–৪ সে | Assisto → মেনু → **Safe Journey** → My Trip; গন্তব্য টাইপ করে বাছুন (যেমন একটি বানানো জায়গা — আসল ঠিকানা নয়) |
| ৪–৮ সে | My Circle থেকে একজন watcher বাছুন → **Start** |
| ৮–১৪ সে | অ্যাপের **লোকেশন প্রকাশ-পাতা** — ধীরে, যাতে "location … even when the app is closed or not in use" লাইন পড়া যায় → **Continue** |
| ১৪–১৭ সে | Android-এর প্রশ্ন → **While using the app** |
| ১৭–২৩ সে | লাইভ যাত্রার পাতা (দূরত্ব/ETA) → **Home** চাপুন → নোটিফিকেশন শেড টানুন: **"Safe Journey is on"** |
| ২৩–৩০ সে | দ্বিতীয় ফোনে (watcher) লাইভ পাতায় অবস্থান বদলাচ্ছে (ঘরের বাইরে হাঁটতে হাঁটতে রেকর্ড করুন) → প্রথম ফোনে **Stop** → নোটিফিকেশন চলে যায় |

চুরি-রোধ, ট্রেন আর গন্তব্য অ্যালার্মের জন্য আলাদা ভিডিও দিন (Google একাধিক লিংক নেয়)। শট `PLAY_FGS_DECLARATION_BN.md` §২-এর ধাপ ৩–৬।
**ভবিষ্যতের ব্যাকগ্রাউন্ড-লোকেশন ভিডিও** (শুধু geofence/নীরব পাহারা শিপ হলে; Google-এর শর্ত: ≤৩০ সে, দেখাতে হবে প্রকাশ-পাতা → অনুমতি → ফিচার ব্যাকগ্রাউন্ডে চলছে, এবং **একটিই ফিচার**): Family → সদস্য → "বাড়ি পৌঁছালে জানাও" চালু → প্রকাশ-পাতা ("…uses your location in the background, even when the app is closed, for: arrival and leaving news…") → Android "Allow all the time" (Settings পাতা) → অ্যাপ বন্ধ করে হাঁটা → অন্য ফোনে "পৌঁছেছেন ৮:০৫ (auto)"। প্রকাশ-পাতা লাগবে অ্যাপের ভেতরে, Play listing-এ আর ওয়েবসাইটেও।

**ভিডিওর লিংক:** [OWNER FILL: YouTube unlisted লিংক বসান — Location FGS, Microphone FGS ("Hey Assisto", `WAKE_WORD_PLAY_BN.md` §২), চুরি-রোধ]

---

## ৩. Publishing overview: "1 not yet sent for review" — এটা সম্ভবত কী

**আমাদের আপলোড-স্ক্রিপ্ট যা করে** (`bin/play_release.sh` → `bin/play_upload.py`):
- AAB শুধু **internal + alpha (closed testing)**-এ যায়। Production স্ক্রিপ্টে নিষিদ্ধ (`assert "production" not in TRACKS`)।
- edit commit হয় **স্বাভাবিকভাবে**, তাই Google নিজে থেকে রিভিউতে পাঠায়। কেবল Google ফেরত দিলে (`changesNotSentForReview`) স্ক্রিপ্ট "না-পাঠানো" অবস্থায় commit করে, আর লগে লেখে `review=manual`।
- লগ বলছে: শেষ `review=manual` ছিল **২৪ Oct** (বিল্ড ২২১–২২২), পরের বিল্ডগুলো সেটাকে ছাপিয়ে গেছে। ২৫ Oct থেকে ৯ Nov ০২:৫৭ UTC পর্যন্ত **সব ৫৬টি আপলোড `review=auto`** (শেষটি বিল্ড ৩১৬)। তাই **আমাদের কোনো রিলিজ "not sent" অবস্থায় পড়ে থাকার কথা নয়।**
- স্টোর লিস্টিং, Data safety বা ঘোষণা আমাদের কোনো স্ক্রিপ্ট ছোঁয় না। আর in-app পণ্য (CCTV extra pack, credits) Publishing overview-এর রিভিউ-তালিকায় আসে না — সেগুলো Active করলেই চালু।

**তাই সবচেয়ে সম্ভাব্য (ক্রমানুসারে):**
1. **আপনার Console-এ Save করা একটি App content ঘোষণা** — "Hey Assisto"-র মাইক্রোফোন FGS বা কেয়ার কলের full-screen intent (করণীয় #৫), বা Data safety-র খসড়া। Save করলে এগুলো "not yet sent" তালিকায় জমা থাকে।
2. **স্টোর লিস্টিং বদল** (`PLAY_LISTING_8NOV_ALL_BN.md` / `PLAY_LISTING_FIXED.md` থেকে পেস্ট করা লেখা বা স্ক্রিনশট)।
3. কম সম্ভাব্য: বিল্ড ৩১৭-এর আপলোড যদি Google-এর ফেরতের পরে `review=manual` হয়ে থাকে। লেখার সময় ৩১৭-এর লাইন লগে ছিল না। [OWNER FILL / লিড: `logs/play_upload.log`-এ build=317 লাইনটি দেখুন।]
4. Managed publishing চালু থাকলে Google-এর অনুমোদিত জিনিস "Ready to publish" দেখায় — সেটা "not yet sent" থেকে আলাদা।

**পাঠানো কি নিরাপদ? — হ্যাঁ, তবে আগে এগুলো দেখে নিন:**
1. Publishing overview → **"Changes not yet sent for review"** খুলুন। ঠিক কোন জিনিস, তার নাম দেখুন।
2. **App content ঘোষণা হলে:** লেখাটা এই ডকের §২-এর সাথে মেলান — বিশেষ করে full-screen intent-এ শুধু "Calling", আর microphone-এ "Hey Assisto" আছে কিনা। **ভিডিও-লিংক ফাঁকা থাকলে পাঠাবেন না।** FGS ঘোষণা ভিডিও ছাড়া প্রত্যাখ্যাত হয়।
3. **Data safety হলে:** চেকলিস্টের ধাপ ৩ + §২.৪-এর সব সারি আছে কিনা দেখুন। অর্ধেক-ভরা ফর্ম পাঠালে policy-rejection আসতে পারে, তখন পরের টেস্ট-রিলিজও আটকে যায়।
4. **লিস্টিং হলে:** "medical", "health monitoring", "pill tracker" জাতীয় শব্দ থাকা চলবে না (কেয়ার কলের নিয়ম)। স্ক্রিনশটে আসল মানুষের নাম বা নম্বর থাকা চলবে না।
5. **Production রিলিজ হলে** (যেটা আমরা কখনো বানাই না, তাই আপনি বানিয়ে থাকলে): staged rollout শতাংশ দেখুন (চেকলিস্ট ধাপ ৮)।
6. "Send for review" **একসাথে সব জমা জিনিস** পাঠায়। তাই ঘোষণাগুলো (§২ ক–ঙ) পুরো করে **একবারে** পাঠান — production আবেদনের **আগে বা একই দিনে**। Production access-এর রিভিউ আলাদা, কিন্তু অসম্পূর্ণ ঘোষণা থাকলে production রিলিজের সময় আটকাবে।

---

## আপনার কাজের ক্রম (আনুমানিক ৪৫ মিনিট + ভিডিও)
1. Publishing overview-এর জিনিসটি দেখুন (§৩) — এখনই পাঠাবেন না।
2. ভিডিও রেকর্ড করুন: Location FGS (§২.৬) আর "Hey Assisto" (`WAKE_WORD_PLAY_BN.md`) → YouTube unlisted।
3. App content: Microphone FGS (§২.১), Location FGS (§২.২), Full-screen intent (§২.৩), Data safety (চেকলিস্ট ধাপ ৩ + §২.৪), App access নোট (§২.৫) → Save → **Send for review** (একবারে)।
4. Dashboard → **Apply for production** → §১-এর উত্তর, সব [OWNER FILL] ভরে।
5. প্রাইভেসি পলিসিতে নোটিফিকেশন-টাকা আর AI প্রদানকারীর লাইন ঠিক করুন (ওয়েবসাইট নিয়মে: প্রিভিউ → আপনার OK → লাইভ)।

**সূত্র (Google, ৯ Nov দেখা):** [Production access](https://support.google.com/googleplay/android-developer/answer/14151465) · [Background location](https://support.google.com/googleplay/android-developer/answer/9799150) · [Foreground service declaration](https://support.google.com/googleplay/android-developer/answer/13392821)
