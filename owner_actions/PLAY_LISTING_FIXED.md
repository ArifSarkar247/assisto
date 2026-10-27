# Play store listing — corrected text (ready to paste)

Owner order 27 Oct: "store listing must match the app". Audit and reasons: `owner_actions/PLAY_LISTING_AUDIT_BN.md`.
**Nothing was changed in Play Console or in any flag.** The owner pastes this text himself.

Play limits: title ≤ 30, short description ≤ 80, full description ≤ 4000 characters. Counts below were made with a script
(Python `len()`, i.e. Unicode characters — Play's own counter gives the same or fewer for Bangla).

Language codes in Play Console: English = `en-US` (already the default), Bangla = **`bn-BD`** (Store presence → Store listing →
"Manage translations" → Add your own translation → Bengali (Bangladesh)). Today the live listing has **English only**; there is
no Bangla listing at all, so Bangla users see English.

Rules both cases follow: only features visible in the **Play build today** (live flags `X-Assisto-Flavour: play` + build gate
`kMedicalFeaturesAllowed=false`); no "best / #1 / top" words; no prices in the text (prices come from Play in the app);
ads wording matches the real ad set-up (Free = ads, paid plans = no ads); contact = **AXON Dynamic / assistoaiagent@gmail.com**,
no personal name.

---

## Case B — medicine STILL HIDDEN (use this now, before 8 Nov)

Nothing about medicine, doses, prescriptions, doctors or health records. "Health" is not used as a heading.

**Title en-US** (28 chars)
```
Assisto: Chat, AI & Business
```

**Title bn-BD** (27 chars)
```
Assisto: চ্যাট, AI ও ব্যবসা
```

**Short description en-US** (73 chars)
```
Chat & calls, reminders, money, family safety and shop tools - in Bangla.
```

**Short description bn-BD** (75 chars)
```
চ্যাট ও কল, রিমাইন্ডার, হিসাব, পরিবারের নিরাপত্তা ও দোকানের খাতা — বাংলায়।
```

**Full description en-US** (2703 chars)
```
Assisto is an all-in-one app for everyday life in Bangladesh. Chat and call your people, keep reminders, notes and money in order, look after your family's safety and run your shop - in Bangla or English, by text or voice.

CHAT AND CALLS
• Personal and group chats, end-to-end encrypted, with photos, voice notes and documents.
• Voice and video calls, read ticks, typing and last seen, text status updates.
• Groups, channels, communities, message requests and passphrase-encrypted chat backup.

JUST SAY IT
• "Remind me to call Mom at 8pm", "500 for lunch, add to expenses" - Assisto saves it and shows a card you can undo.
• Ask by voice or text. Assisto asks your OK before anything leaves the app.

REMINDERS, NOTES AND TASKS
• Reminders that ring at the time you set, notes, to-do lists and a task manager.
• Bills, subscriptions and document expiry dates.
• Wedding and event planner, Ramadan prayer times and Qurbani/Eid planner.

MONEY MADE CLEAR
• Income, expenses, budgets, loans, savings goals and savings challenges.
• Monthly trends, net worth, tax and zakat calculator, money recap.
• Split expenses, mess accounts, samity (savings groups), house rent and prepaid meter tracking.
• Assisto never holds or moves your money - it is your own ledger.

FAMILY AND SAFETY
• One-tap SOS that sends your location to the contacts you choose, with a countdown you can cancel.
• Safe Journey: the people you choose can follow your trip until you arrive, plus a fake call to get away.
• Emergency contacts card and kids' school corner.
• Scam safety tips and a way to report scams.

DOCUMENTS AND PHOTO STUDIO
• PIN-locked vault for passport, NID and licence details, with expiry reminders.
• Nominee access for your family.
• Photo enhance, and passport and visa size photos.

FOR YOUR SHOP
• Digital khata (dues and payables), quick selling, cart, cashbox and daily reports.
• Products, orders, customers and a simple sales CRM.

MORE
• CV builder, student corner, exam results, service guides, expat (probashi) corner and farmer mode.

PRIVACY
• We never sell your data. Each permission is asked only when you use the feature that needs it.
• Delete your account and data any time in Settings or at lifeassisto.com/delete-account.

PLANS
• Free plan with ads. Ads never appear on SOS, safety, call or payment screens.
• Premium and Business plans have no ads and include more AI credits. Some AI features use credits.
• Prices are shown in the app before you pay.

For ages 18+. Assisto does not give medical, legal or financial advice and is not an emergency service - in an emergency, call 999.

Developer: AXON Dynamic · assistoaiagent@gmail.com
Privacy policy: https://lifeassisto.com/privacy
```

**Full description bn-BD** (2544 chars)
```
Assisto — বাংলাদেশের দৈনন্দিন জীবনের জন্য এক অ্যাপ। প্রিয়জনের সাথে চ্যাট ও কল, রিমাইন্ডার-নোট-হিসাব গুছিয়ে রাখা, পরিবারের নিরাপত্তা আর দোকান চালানো — বাংলা বা ইংরেজিতে, লিখে বা বলে।

চ্যাট ও কল
• ব্যক্তিগত ও গ্রুপ চ্যাট, end-to-end এনক্রিপ্টেড — ছবি, ভয়েস নোট ও ডকুমেন্টসহ।
• ভয়েস ও ভিডিও কল, পড়ার টিক, টাইপ করছে ও শেষ দেখা, লেখা স্ট্যাটাস।
• গ্রুপ, চ্যানেল, কমিউনিটি, মেসেজ রিকোয়েস্ট আর পাসফ্রেজ-এনক্রিপ্টেড চ্যাট ব্যাকআপ।

শুধু বলুন
• "রাত ৮টায় মাকে ফোন করতে মনে করিয়ে দিও", "দুপুরের খাবার ৫০০ টাকা খরচ" — Assisto লিখে রাখে, একটি কার্ড দেখায়, চাইলে ফিরিয়ে নিতে পারেন।
• কণ্ঠে বা লিখে জিজ্ঞেস করুন। অ্যাপের বাইরে কিছু করার আগে Assisto আপনার অনুমতি নেয়।

রিমাইন্ডার, নোট ও কাজ
• আপনার দেওয়া সময়ে বাজা রিমাইন্ডার, নোট, কাজের তালিকা ও টাস্ক ম্যানেজার।
• বিল, সাবস্ক্রিপশন ও কাগজপত্রের মেয়াদ।
• বিয়ে ও অনুষ্ঠান পরিকল্পনা, রমজানে নামাজের সময়, কোরবানি ও ঈদ পরিকল্পনা।

পরিষ্কার হিসাব
• আয়, খরচ, বাজেট, ধার, সঞ্চয়ের লক্ষ্য ও সঞ্চয় চ্যালেঞ্জ।
• মাসভিত্তিক প্রবণতা, নিট সম্পদ, কর ও যাকাতের হিসাব, টাকার রিক্যাপ।
• খরচ ভাগাভাগি, মেসের হিসাব, সমিতি, বাড়ি ভাড়া ও প্রিপেইড মিটারের হিসাব।
• Assisto কখনো আপনার টাকা রাখে বা পাঠায় না — এটি শুধু আপনার নিজের খাতা।

পরিবার ও নিরাপত্তা
• এক চাপে SOS — আপনার বেছে নেওয়া মানুষদের কাছে লোকেশন যায়; কাউন্টডাউনে বাতিল করা যায়।
• নিরাপদ যাত্রা: আপনি যাদের বেছে নেন, তারা পৌঁছানো পর্যন্ত যাত্রা দেখতে পান; সাথে নকল কল।
• জরুরি যোগাযোগের কার্ড ও বাচ্চাদের স্কুল কর্নার।
• প্রতারণা থেকে বাঁচার টিপস ও প্রতারণা রিপোর্ট।

ডকুমেন্ট ও ফটো স্টুডিও
• পাসপোর্ট, NID ও লাইসেন্সের তথ্য PIN-লক ভল্টে, মেয়াদ শেষের আগে রিমাইন্ডার।
• পরিবারের জন্য নমিনি অ্যাক্সেস।
• ছবি উন্নত করা, আর পাসপোর্ট ও ভিসা মাপের ছবি।

আপনার দোকানের জন্য
• ডিজিটাল খাতা (বাকি ও দেনা), দ্রুত বিক্রি, কার্ট, ক্যাশবক্স ও দৈনিক রিপোর্ট।
• পণ্য, অর্ডার, গ্রাহক ও সহজ সেলস CRM।

আরও
• সিভি বিল্ডার, স্টুডেন্ট কর্নার, পরীক্ষার ফল, সরকারি সেবা গাইড, প্রবাসী কর্নার ও কৃষক মোড।

গোপনীয়তা
• আমরা কখনো আপনার ডেটা বিক্রি করি না। প্রতিটি অনুমতি চাওয়া হয় শুধু যখন সেই ফিচার ব্যবহার করেন।
• সেটিংস থেকে বা lifeassisto.com/delete-account-এ যেকোনো সময় অ্যাকাউন্ট ও ডেটা মুছুন।

প্ল্যান
• ফ্রি প্ল্যানে বিজ্ঞাপন থাকে। SOS, নিরাপত্তা, কল বা পেমেন্টের স্ক্রিনে কখনো বিজ্ঞাপন নয়।
• প্রিমিয়াম ও বিজনেস প্ল্যানে বিজ্ঞাপন নেই, AI ক্রেডিট বেশি। কিছু AI ফিচারে ক্রেডিট লাগে।
• টাকা দেওয়ার আগে অ্যাপেই দাম দেখানো হয়।

১৮ বছর বা তার বেশি বয়সীদের জন্য। Assisto চিকিৎসা, আইনি বা আর্থিক পরামর্শ দেয় না এবং জরুরি সেবা নয় — জরুরি প্রয়োজনে ৯৯৯-এ কল করুন।

ডেভেলপার: AXON Dynamic · assistoaiagent@gmail.com
গোপনীয়তা নীতি: https://lifeassisto.com/privacy
```


### Optional add-on lines (paste ONLY the lines whose feature is still ON for Play on the day you paste)
These features are visible in Play today (flag on), but `owner_actions/FEATURE_STATUS_BN.md` proposes hiding them in Play
for 8 Nov. If you keep one on, paste its line at the end of the "MORE" / "আরও" section. With all six lines the
English full text is 3397 chars and Bangla 3164 — inside 4000.

| Line | Flag that must be ON for Play | Extra condition |
|---|---|---|
| Phone protection | `anti_theft` | Device-admin declaration accepted by Play. Do **not** write "remote lock" — no remote trigger exists. |
| Business AI Agent | `business_agent` | Business plan product active in Play; page connection works (Meta review). |
| Shop Box | `cctv_watchman` | — |
| AI tools | `mock_interview`, `contract_analyzer`, `blog_writer`, `travel_planner`, `language_partner` | Server AI key live (otherwise results are canned). Drop any tool whose flag is off. |
| Fitness | `smartwatch` | Health apps declaration = Fitness only (already in `PLAY_STORE_PACK.md` §3). |
| Vehicles | `vehicles`, `vehicle_tracking` | The tracker shows a drawn route, not a street map — so never write "map". |

**Add-on lines en-US** (693 chars)
```
• Phone protection: SIM change alert, intruder photo on a wrong unlock, security check-up and used-phone check.
• Business AI Agent (Business plan): replies to your customers on your connected page using your own products and prices; you see every conversation and can take over.
• Shop Box: use an old phone as a shop camera with alerts.
• AI tools: mock interview, contract checker, blog and post writer, travel planner and language partner (use AI credits).
• Fitness: see your steps, heart rate and sleep from Health Connect, read-only, kept on your phone.
• Vehicles: live position and 24-hour route playback with your own GPS tracker; OBD readings with a paired Bluetooth OBD-II adapter.
```

**Add-on lines bn-BD** (619 chars)
```
• ফোন সুরক্ষা: সিম বদলের সতর্কতা, ভুল আনলকে ছবি তোলা, নিরাপত্তা চেক-আপ ও পুরনো ফোন যাচাই।
• বিজনেস AI এজেন্ট (বিজনেস প্ল্যান): আপনার যুক্ত করা পেজে আপনার নিজের পণ্য ও দাম দেখে গ্রাহককে উত্তর দেয়; সব কথোপকথন দেখতে ও নিজে ধরতে পারেন।
• শপ বক্স: পুরনো ফোনকে সতর্কবার্তাসহ দোকানের ক্যামেরা বানান।
• AI টুল: মক ইন্টারভিউ, চুক্তি যাচাই, ব্লগ ও পোস্ট লেখা, ভ্রমণ পরিকল্পনা ও ভাষা শেখার সঙ্গী (AI ক্রেডিট লাগে)।
• ফিটনেস: Health Connect থেকে ধাপ, হার্ট রেট ও ঘুম দেখুন — শুধু পড়া, তথ্য ফোনেই থাকে।
• গাড়ি: নিজের GPS ট্র্যাকার দিয়ে লাইভ অবস্থান ও ২৪ ঘণ্টার রুট প্লেব্যাক; pair করা ব্লুটুথ OBD-II অ্যাডাপ্টার দিয়ে OBD রিডিং।
```


---

## Case A — medicine VISIBLE (use ONLY after all of these are true)

1. Developer account is an **Organization** account (AXON Dynamic, D-U-N-S verified) — `owner_actions/PLAY_ORGANIZATION_ACCOUNT_BN.md`.
2. App content → **Health apps** declaration includes "Medication and treatment management" (and nothing medical-device / diagnosis).
3. Data safety → **Health info** declared; privacy policy has its own health section.
4. A new Play build with medicine reminders + caregiver view ON (prescription reader, medicine database, first aid,
   health tips, doctor serial still OFF), in-app disclaimer on first use and in Settings, tests passed
   (see audit §ক), and that build is the one live in production.

Same as Case B plus a "MEDICINE REMINDERS" section and the disclaimer line. Still no claims of diagnosis, treatment,
dose advice, "never miss a dose" or "doctor approved".

**Title en-US** (28 chars)
```
Assisto: Chat, AI & Business
```

**Title bn-BD** (27 chars)
```
Assisto: চ্যাট, AI ও ব্যবসা
```

**Short description en-US** (78 chars)
```
Chat & calls, reminders incl. medicine times, money, family safety, shop tools
```

**Short description bn-BD** (72 chars)
```
চ্যাট ও কল, ওষুধসহ রিমাইন্ডার, হিসাব, পরিবারের নিরাপত্তা ও দোকানের খাতা।
```

**Full description en-US** (3143 chars)
```
Assisto is an all-in-one app for everyday life in Bangladesh. Chat and call your people, keep reminders, notes and money in order, look after your family's safety and run your shop - in Bangla or English, by text or voice.

CHAT AND CALLS
• Personal and group chats, end-to-end encrypted, with photos, voice notes and documents.
• Voice and video calls, read ticks, typing and last seen, text status updates.
• Groups, channels, communities, message requests and passphrase-encrypted chat backup.

JUST SAY IT
• "Remind me to call Mom at 8pm", "500 for lunch, add to expenses" - Assisto saves it and shows a card you can undo.
• Ask by voice or text. Assisto asks your OK before anything leaves the app.

REMINDERS, NOTES AND TASKS
• Reminders that ring at the time you set, notes, to-do lists and a task manager.
• Bills, subscriptions and document expiry dates.
• Wedding and event planner, Ramadan prayer times and Qurbani/Eid planner.

MONEY MADE CLEAR
• Income, expenses, budgets, loans, savings goals and savings challenges.
• Monthly trends, net worth, tax and zakat calculator, money recap.
• Split expenses, mess accounts, samity (savings groups), house rent and prepaid meter tracking.
• Assisto never holds or moves your money - it is your own ledger.

FAMILY AND SAFETY
• One-tap SOS that sends your location to the contacts you choose, with a countdown you can cancel.
• Safe Journey: the people you choose can follow your trip until you arrive, plus a fake call to get away.
• Emergency contacts card and kids' school corner.
• Scam safety tips and a way to report scams.

MEDICINE REMINDERS
• Add the medicines and times your doctor gave you - Assisto reminds you at those times.
• Mark each dose as taken or skipped and see your own history.
• Set reminders for a parent or child, and see in Family when a reminder was not marked taken.
• Assisto only reminds you at the times you enter. It is not medical advice, does not suggest doses and does not diagnose or treat any condition. Always follow your doctor.

DOCUMENTS AND PHOTO STUDIO
• PIN-locked vault for passport, NID and licence details, with expiry reminders.
• Nominee access for your family.
• Photo enhance, and passport and visa size photos.

FOR YOUR SHOP
• Digital khata (dues and payables), quick selling, cart, cashbox and daily reports.
• Products, orders, customers and a simple sales CRM.

MORE
• CV builder, student corner, exam results, service guides, expat (probashi) corner and farmer mode.

PRIVACY
• We never sell your data. Each permission is asked only when you use the feature that needs it.
• Delete your account and data any time in Settings or at lifeassisto.com/delete-account.

PLANS
• Free plan with ads. Ads never appear on SOS, safety, call or payment screens.
• Premium and Business plans have no ads and include more AI credits. Some AI features use credits.
• Prices are shown in the app before you pay.

For ages 18+. Assisto does not give medical, legal or financial advice and is not an emergency service - in an emergency, call 999.

Developer: AXON Dynamic · assistoaiagent@gmail.com
Privacy policy: https://lifeassisto.com/privacy
```

**Full description bn-BD** (2980 chars)
```
Assisto — বাংলাদেশের দৈনন্দিন জীবনের জন্য এক অ্যাপ। প্রিয়জনের সাথে চ্যাট ও কল, রিমাইন্ডার-নোট-হিসাব গুছিয়ে রাখা, পরিবারের নিরাপত্তা আর দোকান চালানো — বাংলা বা ইংরেজিতে, লিখে বা বলে।

চ্যাট ও কল
• ব্যক্তিগত ও গ্রুপ চ্যাট, end-to-end এনক্রিপ্টেড — ছবি, ভয়েস নোট ও ডকুমেন্টসহ।
• ভয়েস ও ভিডিও কল, পড়ার টিক, টাইপ করছে ও শেষ দেখা, লেখা স্ট্যাটাস।
• গ্রুপ, চ্যানেল, কমিউনিটি, মেসেজ রিকোয়েস্ট আর পাসফ্রেজ-এনক্রিপ্টেড চ্যাট ব্যাকআপ।

শুধু বলুন
• "রাত ৮টায় মাকে ফোন করতে মনে করিয়ে দিও", "দুপুরের খাবার ৫০০ টাকা খরচ" — Assisto লিখে রাখে, একটি কার্ড দেখায়, চাইলে ফিরিয়ে নিতে পারেন।
• কণ্ঠে বা লিখে জিজ্ঞেস করুন। অ্যাপের বাইরে কিছু করার আগে Assisto আপনার অনুমতি নেয়।

রিমাইন্ডার, নোট ও কাজ
• আপনার দেওয়া সময়ে বাজা রিমাইন্ডার, নোট, কাজের তালিকা ও টাস্ক ম্যানেজার।
• বিল, সাবস্ক্রিপশন ও কাগজপত্রের মেয়াদ।
• বিয়ে ও অনুষ্ঠান পরিকল্পনা, রমজানে নামাজের সময়, কোরবানি ও ঈদ পরিকল্পনা।

পরিষ্কার হিসাব
• আয়, খরচ, বাজেট, ধার, সঞ্চয়ের লক্ষ্য ও সঞ্চয় চ্যালেঞ্জ।
• মাসভিত্তিক প্রবণতা, নিট সম্পদ, কর ও যাকাতের হিসাব, টাকার রিক্যাপ।
• খরচ ভাগাভাগি, মেসের হিসাব, সমিতি, বাড়ি ভাড়া ও প্রিপেইড মিটারের হিসাব।
• Assisto কখনো আপনার টাকা রাখে বা পাঠায় না — এটি শুধু আপনার নিজের খাতা।

পরিবার ও নিরাপত্তা
• এক চাপে SOS — আপনার বেছে নেওয়া মানুষদের কাছে লোকেশন যায়; কাউন্টডাউনে বাতিল করা যায়।
• নিরাপদ যাত্রা: আপনি যাদের বেছে নেন, তারা পৌঁছানো পর্যন্ত যাত্রা দেখতে পান; সাথে নকল কল।
• জরুরি যোগাযোগের কার্ড ও বাচ্চাদের স্কুল কর্নার।
• প্রতারণা থেকে বাঁচার টিপস ও প্রতারণা রিপোর্ট।

ওষুধের রিমাইন্ডার
• ডাক্তার যে ওষুধ ও সময় দিয়েছেন, তা লিখে রাখুন — Assisto ঠিক সেই সময়ে মনে করিয়ে দেবে।
• প্রতিটি ডোজ "খেয়েছি" বা "বাদ" চিহ্ন দিন, নিজের ইতিহাস দেখুন।
• মা-বাবা বা সন্তানের জন্য রিমাইন্ডার দিন; কোনো রিমাইন্ডার "খেয়েছি" চিহ্ন না পেলে ফ্যামিলি পাতায় দেখতে পাবেন।
• Assisto শুধু আপনার দেওয়া সময়ে মনে করিয়ে দেয়। এটি চিকিৎসা-পরামর্শ নয়, ডোজ বলে না, রোগ নির্ণয় বা চিকিৎসা করে না। সবসময় ডাক্তারের পরামর্শ মানুন।

ডকুমেন্ট ও ফটো স্টুডিও
• পাসপোর্ট, NID ও লাইসেন্সের তথ্য PIN-লক ভল্টে, মেয়াদ শেষের আগে রিমাইন্ডার।
• পরিবারের জন্য নমিনি অ্যাক্সেস।
• ছবি উন্নত করা, আর পাসপোর্ট ও ভিসা মাপের ছবি।

আপনার দোকানের জন্য
• ডিজিটাল খাতা (বাকি ও দেনা), দ্রুত বিক্রি, কার্ট, ক্যাশবক্স ও দৈনিক রিপোর্ট।
• পণ্য, অর্ডার, গ্রাহক ও সহজ সেলস CRM।

আরও
• সিভি বিল্ডার, স্টুডেন্ট কর্নার, পরীক্ষার ফল, সরকারি সেবা গাইড, প্রবাসী কর্নার ও কৃষক মোড।

গোপনীয়তা
• আমরা কখনো আপনার ডেটা বিক্রি করি না। প্রতিটি অনুমতি চাওয়া হয় শুধু যখন সেই ফিচার ব্যবহার করেন।
• সেটিংস থেকে বা lifeassisto.com/delete-account-এ যেকোনো সময় অ্যাকাউন্ট ও ডেটা মুছুন।

প্ল্যান
• ফ্রি প্ল্যানে বিজ্ঞাপন থাকে। SOS, নিরাপত্তা, কল বা পেমেন্টের স্ক্রিনে কখনো বিজ্ঞাপন নয়।
• প্রিমিয়াম ও বিজনেস প্ল্যানে বিজ্ঞাপন নেই, AI ক্রেডিট বেশি। কিছু AI ফিচারে ক্রেডিট লাগে।
• টাকা দেওয়ার আগে অ্যাপেই দাম দেখানো হয়।

১৮ বছর বা তার বেশি বয়সীদের জন্য। Assisto চিকিৎসা, আইনি বা আর্থিক পরামর্শ দেয় না এবং জরুরি সেবা নয় — জরুরি প্রয়োজনে ৯৯৯-এ কল করুন।

ডেভেলপার: AXON Dynamic · assistoaiagent@gmail.com
গোপনীয়তা নীতি: https://lifeassisto.com/privacy
```


The same optional add-on lines as Case B apply (with all six: en 3837, bn 3600 chars — inside 4000).

---

## Screenshot and feature-graphic plan

What is live today (en-US only, read from Play via the API, 27 Oct): 8 phone screenshots in the **bright blue style**
+ 1 feature graphic. No 7-inch / 10-inch tablet screenshots, no Bangla set.

| # live | Caption on the live image | Decision |
|---|---|---|
| 1 | "Your super app — Everything in one place" (home) | Keep |
| 2 | "Free chat & calls — End-to-end encrypted" | Keep |
| 3 | "Voice & video calls — Clear, private and free" | Keep |
| 4 | "Just say it" — chat shows **"Remind me medicine tomorrow 8am" → card "Medicine"** | **REMOVE now** (medical claim; Play build has no medicine feature) |
| 5 | "Money made clear" — balance ৳20,800 but net worth ৳0 and Accounts 0 | Replace (demo numbers contradict each other; a reviewer or user will notice) |
| 6 | "Run your shop" | Keep |
| 7 | "Photo Studio — Enhance & passport photos" | Keep |
| 8 | "Family care & SOS" (Safe Journey + SOS) | Keep |
| FG | Feature graphic chips: Chat & Calls, AI Assistant, **Business AI Agent**, Reminders, Family & SOS, Photo Studio, Money | Keep while `business_agent` is ON for Play; if you hide it, replace that chip with "Notes & Tasks" |

### Case B — do this now
- **Fastest fix (5 minutes):** replace live #4 with `owner_actions/play_store_v2/phone_en_4.png` ("Just say it" → "Remind me to call mom tomorrow 8am" → card "Call mom"). It is already medicine-free (checked by eye).
  Better: upload the whole `play_store_v2/phone_en_1..8.png` set (same 8 screens, one consistent dark style, medicine-free) so styles do not mix.
- Fix the money screenshot: re-render #5 with consistent fake data (net worth and account count matching the balance) — `app/test/fake_api.dart`, then `owner_actions/play_store/make_graphics.py` (`PLAY_STORE_PACK.md` §1 "Graphics").
- **Add the Bangla (bn-BD) set:** `play_store_v2/phone_bn_1..8.png` + `play_store_v2/feature_graphic_bn.png` (checked: chat screenshot says "মাকে ফোন", no medicine).
  Same money-data fix applies to `phone_bn_5.png`.
- Do not add a Shop Box, vehicle, anti-theft or Business-AI-Agent screenshot unless that flag stays ON for Play.

### Case A — after the conditions above
- Replace #7 (Photo Studio) or #3 (calls) with **"Medicine reminders" screen** from the Play build: Family → Medicines → today's list with
  "taken / skipped" buttons and the disclaimer line visible on screen. Caption EN "Medicine times, on time — as your doctor prescribed",
  BN "ডাক্তারের দেওয়া সময়ে ওষুধের রিমাইন্ডার". No dose numbers that look like advice; use made-up medicine names (no real brand).
- Optional second: caregiver view ("Ma — 8:00 reminder not marked taken"). Never a prescription photo, never a medicine-database page.
- Chat screenshot may then show "Remind me about my medicine at 8am" → a card titled with the user's own words; keep "Call mom" if unsure.
- Feature graphic: may add a "Medicine reminders" chip; no cross / pill-bottle medical-device imagery.
