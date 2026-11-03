# প্রাইভেসি পাতার হালনাগাদ খসড়া (শুধু খসড়া — আইনি লেখা, মালিকের OK ছাড়া `legal_content.py` বদলানো হয়নি)

শাখা `agent/privdraft` · ৩ Nov · ভিত্তি: `DATA_MINIMISATION_BN.md`-এর ৬ অমিল + আজ রাতের নতুন ফিচার। বর্তমান পাতা: `backend/web/legal_content.py` (তারিখ 2026-10-27)।
নোট: ফিচার ১৩–২৩ এখনো আলাদা শাখায় (`amarket`, `mktengine`, `cctvguard`…) বা এখনো মার্জ হয়নি। মেয়াদ/সংখ্যা মার্জের সময় কোডের সাথে আবার মিলিয়ে নিতে হবে। যেখানে "(যাচাই)" লেখা, সেখানে শাখার কোড দেখে নিশ্চিত হবেন।
প্রতি সারি: **এখনকার বাক্য** → **প্রস্তাব (বাংলা / English)** → কেন (কোড/টেবিল/মেয়াদ) → Play Data safety।

---
## ক. DATA_MINIMISATION-এর ৬ অমিল

### ১. অ্যাপ ব্যবহারের দিন (`ActiveDay`, `last_active`)
- **এখন** ("collect", Device and technical data): "push-notification token, app version, platform; IP address and time in server logs for security; an audit log of sensitive actions; app crash reports"। দিনের কথা নেই।
- **বাংলা:** "যে দিনগুলোতে আপনি অ্যাপ ব্যবহার করেছেন (শুধু তারিখ, কী করেছেন তা নয়), সক্রিয় ব্যবহারকারী গোনার জন্য রাখা হয়।"
- **English:** "The dates on which you used the app (dates only, not what you did), kept to count active users."
- **কেন:** `ActiveDay` (শুধু তারিখ) + `last_active`; অ্যাকাউন্ট থাকা পর্যন্ত।
- **Play:** App activity → Other actions (Analytics/Fraud prevention)। ব্যাখ্যায় যোগ: "active-day count". নতুন টাইপ নয়।

### ২. সতর্কবার্তা / সীমা / সাসপেন্ড / ব্যান ও আপিল (`AccountAction`)
- **এখন** ("use"): "Meeting legal obligations and preventing abuse." আলাদা করে নেই।
- **বাংলা:** "নিয়ম ভাঙলে সতর্কবার্তা, সীমা, সাসপেন্ড বা ব্যান দেওয়া হয় এবং কারণ রাখা হয়। অ্যাপ থেকে আপিল করা যায়; আপিলের লেখাও রাখা হয়।"
- **English:** "If rules are broken we may warn, limit, suspend or ban an account and keep the reason. You can appeal in the app; the appeal text is kept too."
- **কেন:** `AccountAction` (কারণসহ) + আপিল; অ্যাকাউন্ট থাকা পর্যন্ত। Play UGC নীতির প্রমাণ।
- **Play:** পরিবর্তন নেই (Other actions, Fraud prevention/security)। ব্যাখ্যায় এক লাইন: "নিয়ম ভাঙার ব্যবস্থা ও আপিল"।

### ৩. ব্যান-হ্যাশ (`BannedIdentity`) — জরুরি
- **এখন:** missing। "Delete" পাতার "What may remain"-এও নেই।
- **বাংলা:** "কোনো অ্যাকাউন্ট নিয়ম ভাঙার জন্য স্থায়ীভাবে নিষিদ্ধ হলে, আবার খোলা ঠেকাতে তার ফোন নম্বর ও ইমেইলের এক-মুখী হ্যাশ (আসল নম্বর নয়) রাখা হয় — অ্যাকাউন্ট মোছার পরেও। ব্যান তুললে এটি নিষ্ক্রিয় হয়।"
- **English:** "If an account is permanently banned for breaking the rules, we keep a one-way hash of its phone number and email (never the number itself) to stop it re-registering, even after the account is deleted. If the ban is lifted the hash is deactivated."
- **কেন:** HMAC-SHA256; উদ্দেশ্যই মোছার পরে থাকা। একই বাক্য "How long" ও Delete পাতার "What may remain"-এ।
- **Play:** নতুন টাইপ নয়; Device or other IDs → "Fraud prevention, security" ব্যাখ্যায় "one-way hash of banned identifiers"।

### ৪. রিপোর্টের মেসেজ-কপি (`ModerationReport`, `TrainChatReport`)
- **এখন:** AI-উত্তরের রিপোর্ট বলা আছে ("A report keeps only the text of the answer…"), কিন্তু মানুষের চ্যাট রিপোর্টে জোড়া মেসেজ **missing**।
- **বাংলা:** "কেউ আপনাকে রিপোর্ট করলে তাঁর ফোন যে শেষ কয়েকটা (সর্বোচ্চ ৫টা) মেসেজ নিজে জুড়ে দেয়, তা আমাদের কাছে আসে। নিষ্পত্তির ৯০ দিন পর মুছে ফেলা হয়; আইনি কারণে আটকে রাখলে নয়।"
- **English:** "When someone reports a message or user, their phone attaches the last few messages (up to 5) they choose to send us. We delete these 90 days after the report is closed, unless a legal hold applies."
- **কেন:** `ModerationReport` snapshot এখন চিরকাল থাকে; ট্রেন-চ্যাটের কপি ৩০ দিনে মোছে কিন্তু `ModerationReport`-এ থেকে যায়। **মেয়াদ ৯০ দিন মালিকের সিদ্ধান্ত + মোছার cron আগে বানাতে হবে** (না থাকলে বাক্যটি মিথ্যা হবে)।
- **Play:** Messages → "Collected", purpose: App functionality / Fraud prevention। Optional নয় (রিপোর্টকারী নিজে পাঠান, তবু collected)।

### ৫. অ্যানালিটিক্স (`AnalyticsEvent`)
- **এখন:** "anonymous counts of which features are used — keyed by a random code…". মেয়াদ নেই।
- **বাংলা:** "…এই তথ্য ১৩ মাস পর মুছে ফেলা হয়।"
- **English:** "…This data is deleted after 13 months."
- **কেন:** মোছার cron এখনো নেই — **cron আগে, তারপর বাক্য**।
- **Play:** App interactions, optional (সম্মতি); পরিবর্তন নেই।

### ৬. সার্ভার লগের মেয়াদ
- **এখন:** "IP address and time in server logs for security"। মেয়াদ নেই।
- **বাংলা:** "সার্ভার লগের IP ও সময় সর্বোচ্চ ১৪ দিন রাখা হয়।" (সংখ্যা logrotate দেখে নিশ্চিত করুন)
- **English:** "IP address and time in server logs are kept for up to 14 days." (confirm against logrotate)
- **Play:** পরিবর্তন নেই।

---
## খ. আজ রাতের নতুন ফিচার — পাতায় যা নেই

### ৭. CCTV এনক্রিপ্টেড সতর্কতা-ছবি/ক্লিপ ও মেয়াদ (`cctvevidence`)
- **এখন** ("cctv"): "one small still photo (snapshot) per event… kept 0–30 days… Video: never kept." — ক্লিপ ও এনক্রিপশন নিয়ে **missing/ভুল** ("Video: never kept" ক্লিপ চালু হলে মিথ্যা)।
- **বাংলা:** "সতর্কতার ছবি ও (আপনি চালু করলে) ছোট ক্লিপ সার্ভারে এনক্রিপ্ট করে রাখা হয়; শুধু আপনি ও আপনার দেওয়া সদস্যরা দেখতে পারেন। ছবি ও ক্লিপ ৭ বা ৩০ দিন (আপনার বাছাই) পর নিজে মুছে যায়। সার্ভার ২৪ ঘণ্টা লাইভ ভিডিও রাখে না।"
- **English:** "Alert photos and, if you turn it on, short clips are stored encrypted on our server and can be seen only by you and the people you allow. They are deleted automatically after 7 or 30 days (your choice). We do not record live video 24/7."
- **কেন:** `ShopEventClip` + এনক্রিপ্টেড মিডিয়া; দৈনিক clean-up। "Video: never kept" লাইন (retention ও cctv দুই জায়গায়) বদলাতে হবে। (যাচাই: মেয়াদ বাছাই 7/30 কিনা)
- **Play:** Photos and videos → **Videos যোগ করুন** (collected, optional, encrypted in transit + at rest, deletable)। Photos আগে থেকেই আছে।

### ৮. শেয়ার লিংক ও "কে দেখেছে" লগ ৩০ দিন
- **এখন:** missing (শুধু গাড়ি/ট্রেন শেয়ারের কথা অন্য অংশে)।
- **বাংলা:** "আপনি লিংক শেয়ার করলে লিংক খোলা প্রত্যেকের সময় ও (আনুমানিক) ডিভাইস ধরন 'কে দেখেছে' তালিকায় ৩০ দিন রাখা হয়, শুধু আপনাকে দেখানোর জন্য। লিংক বন্ধ করলে আর কেউ খুলতে পারে না।"
- **English:** "When you share a link, we keep a 'who viewed' log (time and rough device type of each opener) for 30 days, shown only to you. Once you turn the link off, nobody can open it."
- **কেন:** share link-এর view log; ৩০ দিনে মোছা। (যাচাই: কোন IP/ফিল্ড রাখা হয় — IP রাখলে বাক্যে "হ্যাশ করা IP" লিখুন)
- **Play:** App activity → App interactions-এ ব্যাখ্যা যোগ; নতুন টাইপ নয়।

### ৯. এলাকা পাহারা (Neighbourhood watch) ছবি
- **এখন:** missing (শুধু area board)।
- **বাংলা:** "এলাকার পাহারায় আপনি ছবি দিলে তা আমাদের সার্ভারে থাকে (এন্ড-টু-এন্ড এনক্রিপ্টেড নয়), এলাকার সদস্যরা দেখতে পারেন, আর নির্দিষ্ট সময় পর নিজে মুছে যায়।"
- **English:** "If you post a photo to your neighbourhood watch, it is held on our server (not end-to-end encrypted), visible to members of that area, and expires automatically."
- **কেন:** মূল বিষয়: E2E নয়, তাই খোলাখুলি বলা জরুরি। (যাচাই: মেয়াদ কত দিন লিখুন — কোড মার্জের পর)
- **Play:** Photos → collected, shared (with other users in the area)? **"Shared" হ্যাঁ ধরুন** কারণ অন্য ব্যবহারকারী দেখেন।

### ১০. ফোন-ক্যামেরা (phone-as-camera)
- **এখন:** missing।
- **বাংলা:** "পুরনো ফোনকে ক্যামেরা বানালে ক্লিপ শুধু সেই ফোনেই থাকে; আপনি না চাইলে সার্ভারে যায় না।"
- **English:** "If you use a spare phone as a camera, its clips stay on that phone only and are not uploaded unless you choose to."
- **কেন:** ডিভাইসে সংরক্ষণ; আপলোড শুধু সতর্কতা-ছবি (ধারা ৭ অনুযায়ী)। (যাচাই)
- **Play:** পরিবর্তন নেই; "device_only" অংশে এক লাইন।

### ১১. অটো-গার্ড: শুধু বাড়ি থেকে দূরত্ব
- **এখন:** missing।
- **বাংলা:** "অটো-গার্ড চালু থাকলে শুধু 'বাড়ি থেকে কত দূরে' হিসাবটা ব্যবহার হয়; আপনার চলাচলের পথ সার্ভারে রাখা হয় না।"
- **English:** "With auto-guard on, only your distance from home is used; your movement trail is not stored on our server."
- **কেন:** শুধু দূরত্ব (সংখ্যা) → ছোট্ট; পথ নয়। (যাচাই: দূরত্ব ফোনেই হিসাব হয় না সার্ভারে? সার্ভারে গেলে "approximate location" লিখুন)
- **Play:** Location → Approximate location (precise নয়, যদি শুধু দূরত্ব যায়)। কোড দেখে ঠিক করুন।

### ১২. ট্রিপ রেকর্ডার (শুধু মালিক)
- **এখন:** missing।
- **বাংলা:** "ট্রিপ রেকর্ডারের যাত্রা-ইতিহাস শুধু আপনি দেখতে পারেন; মালিক বা স্টাফও না।"
- **English:** "Your trip-recorder history is visible only to you, not to anyone else, including our staff."
- **কেন:** owner-only; PrivacyWallTests-এ তালিকাভুক্ত করা উচিত। মেয়াদ: (যাচাই, কোড মার্জের পর)।
- **Play:** Precise location (collected, optional) — "Location" আগে থেকেই আছে; উদ্দেশ্যে "trip history" যোগ।

### ১৩. Assisto Market (চাহিদা, দর, চুক্তি)
- **এখন:** missing। (শাখা `amarket`: `MarketSeller`, `MarketNeed`, `MarketBid`, `MarketDeal`, `MarketBlock`)
- **বাংলা:** "মার্কেটে আপনি যে চাহিদা, দর বা চুক্তি দেন তা অন্য মার্কেট-সদস্যরা দেখতে পারেন (আপনার নাম/শহর যতটুকু আপনি দেখাতে চান)। ফোন নম্বর চুক্তি নিশ্চিত হওয়ার আগে দেখানো হয় না। ব্লক করা সদস্য আপনাকে দেখে না।"
- **English:** "Needs, bids and deals you post in Market are visible to other Market members (your name/area as you choose to show it). Your phone number is not shown until a deal is confirmed. People you block cannot see you."
- **কেন:** মার্কেট টেবিলগুলো; অ্যাকাউন্ট মুছলে মোছা। (যাচাই: ফোন কখন দেখায়, মেয়াদ)
- **Play:** User-generated content / Financial info (দর) → collected, **shared** with users। Purpose: App functionality।

### ১৪. মার্কেটিং ইঞ্জিন (ব্যবসার তথ্য ব্যবহার)
- **এখন:** missing (Business mode: "products, customers, sales" আছে, কিন্তু ক্যাম্পেইন বানাতে ব্যবহারের কথা নেই)। শাখা `mktengine`।
- **বাংলা:** "মার্কেটিং সহকারী আপনার নিজের পণ্য, বিক্রি ও গ্রাহকের সংখ্যা দিয়ে প্ল্যান বানায়; কিছু পাঠানোর আগে আপনার অনুমোদন লাগে। গ্রাহক 'STOP' বললে তাকে আর পাঠানো হয় না।"
- **English:** "The marketing assistant builds a plan from your own products, sales and customer counts, and nothing is sent without your approval. A customer who replies STOP is not messaged again."
- **কেন:** retention automation; STOP honoured, দৈনিক সীমা, রাত ২১:০০–০৯:০০ বন্ধ। AI যদি ব্যবহার হয়, "AI features" অংশ মিলিয়ে দেখুন।
- **Play:** Financial info (sales) ও Personal info (গ্রাহকের ফোন) — ব্যবসায়িক ব্যবহারকারীর নিজের তথ্য; আগেই আছে, ব্যাখ্যায় "campaign planning" যোগ।

### ১৫. বার্তা-বন্ধ তালিকা (message opt-out, `BizOptOut`)
- **এখন:** শুধু বুকিংয়ের "Reply STOP" আছে; ব্যবসার গ্রাহক-তালিকা নিয়ে **missing**।
- **বাংলা:** "কেউ 'STOP' বা 'আনসাবস্ক্রাইব' বললে তার ফোন নম্বর (হ্যাশ করা) একটি বন্ধ-তালিকায় রাখা হয়, যাতে আর বার্তা না যায়। অ্যাকাউন্ট মুছলেও এই তালিকা রাখা হতে পারে, কারণ নইলে আবার বার্তা চলে যাবে।"
- **English:** "If someone replies STOP or unsubscribes, their number (hashed) goes on a do-not-message list so we never message them again. This list may remain after account deletion, otherwise messages would resume."
- **কেন:** `BizOptOut`। (যাচাই: নম্বর হ্যাশ না আসল? আসল হলে "হ্যাশ করা" শব্দ মুছুন।) Delete পাতার "What may remain"-এও যোগ।
- **Play:** পরিবর্তন নেই (Phone number, ইতিমধ্যে আছে)।

### ১৬. Meta (Facebook/Instagram) ডেটা-মোছার callback
- **এখন:** "Services you connect yourself: WhatsApp Business/Facebook/Instagram…" আছে; মোছার callback **missing**।
- **বাংলা:** "Facebook বা Instagram থেকে আপনি Assisto-র অনুমতি তুলে নিলে বা মোছার অনুরোধ করলে, Meta আমাদের জানায় এবং আমরা সেই সংযোগের তথ্য মুছে দিই। একটি নিশ্চিতকরণ কোড পাতায় দেখানো হয়।"
- **English:** "If you remove Assisto from Facebook or Instagram or ask Meta to delete your data, Meta notifies us and we delete the data of that connection. A confirmation code is shown on a status page."
- **কেন:** Meta-র বাধ্যতামূলক data deletion callback (`DataDeletion` ticket/endpoint); Meta app review-এও লাগে। (যাচাই: URL ও মোছার সময়)
- **Play:** পরিবর্তন নেই; Delete পাতায় Meta-র কথা যোগ।

### ১৭. মোছার পরেও যা থাকে (হ্যাশ ও snapshot) — "What may remain"-এ একত্র
- **এখন** ("kept"): শুধু আইনি/লেনদেনের রেকর্ড ও ব্যাকআপ (~১৪ দিন)।
- **বাংলা:** "ব্যান-হ্যাশ (৩), বার্তা-বন্ধ তালিকা (১৫), আর আইনি কারণে আটকানো রিপোর্ট (৪) থেকে যেতে পারে।"
- **English:** "Ban hashes (3), the do-not-message list (15) and reports held for legal reasons (4) may remain."
- **Play:** পরিবর্তন নেই; Data deletion ফর্মে "some data may be retained" ব্যাখ্যা মিলিয়ে নিন।

### ১৮. আমরা কখনো লোকেশন ডেটা বিক্রি করি না (safeplans, মালিকের আদেশ ৩ Nov PART 7)
- **এখন:** পাতায় এই প্রতিশ্রুতি আলাদা করে লেখা নেই।
- **বাংলা:** "আমরা কখনো লোকেশন ডেটা বিক্রি করি না।"
- **English:** "We never sell location data."
- **কোথায়:** "Location" অংশের প্রথম লাইন, আর নিরাপত্তা-প্ল্যান (চাইল্ড / সেফ ফ্যামিলি / স্কুল সেফ) বর্ণনার পাশে। আরও: Owner Admin কারো লোকেশন দেখে না; স্কুল শুধু গেটে আসা-যাওয়ার সময় দেখে, স্থানাঙ্ক নয়; স্কুল-বাসের অবস্থান ১০ মিনিট মেমরিতে, ইতিহাস রাখা হয় না।
- **Play:** Data safety-তে Location "not sold / not shared with third parties for advertising" — আগের মতোই সত্য থাকতে হবে। শুধু খসড়া — প্রকাশ মালিকের OK-র পরে।

---
## গ. মালিকের জন্য ছোট তালিকা
1. **আগে কোড, পরে লেখা:** ৪ (৯০ দিনের মোছা), ৫ (১৩ মাসের মোছা), ৭ (ক্লিপ ৭/৩০) — cron না থাকলে বাক্য মিথ্যা হবে।
2. **আইনি OK লাগবে:** ৩, ৪, ১৫, ১৭ (মোছার পরেও রাখা)।
3. **Play Data safety-তে আসল পরিবর্তন:** Videos যোগ (৭), Photos "shared" (৯), Messages collected (৪), Approximate location (১১ — কোড দেখে)। বাকিগুলো শুধু ব্যাখ্যা।
4. পাতা বদলালে `LAST_UPDATED` ও Play-র privacy policy তারিখ একসাথে বদলাবে; ফিচার মার্জের আগে বাক্য প্রকাশ করবেন না।
