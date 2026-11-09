# কেয়ার কল — Play Console ঘোষণা ও Listing লেখা (খসড়া)

শাখা `agent/carecall` · ৪ নভেম্বর। **মালিক নিজে Play Console-এ বসাবেন** — এজেন্ট Play Console-এ কিছু বদলায়নি।

> নিয়ম: Play listing ও ঘোষণায় কেয়ার কলকে **"family care reminder call"** বলা হবে — **medical / health app নয়**। কোনো রোগ নির্ণয়, চিকিৎসা বা ওষুধের পরামর্শের দাবি নেই। ব্যবহারকারী নিজে যা লেখেন, সেটাই বাজে।

## ১. Full-screen intent (USE_FULL_SCREEN_INTENT) — Android 14+

Play Console → App content → **Full-screen intent** → "Calling and alarms"। Assisto আগে থেকেই My Circle ভয়েস/ভিডিও কলের জন্য এই অনুমতি ঘোষণা করেছে; কেয়ার কল **একই** কল-ব্যবস্থা ব্যবহার করে, তাই নতুন অনুমতি লাগে না — শুধু বিবরণে কেয়ার কল যোগ করুন।

**Declaration text (English, paste as is):**

> Assisto uses full-screen intents only for incoming calls: (1) My Circle voice and video calls between family members, and (2) Care Call — a family care reminder call that a family member schedules for a loved one (for example "time to eat" or "prayer time"). At the scheduled time the receiver's phone shows a full-screen incoming-call screen, also on the lock screen, with the family member's own recorded voice and two large buttons ("Done" / "Remind me in 10 minutes"). The receiver accepts Care Calls from each family member once and can stop them at any time in the app. Full-screen intents are never used for ads, promotions or any other notification.

## ২. Calling app / self-managed calls

Play Console-এ "calling app" প্রশ্ন এলে (Telecom self-managed `MANAGE_OWN_CALLS` আগে থেকেই আছে):

> Assisto is a family communication app with its own in-app voice and video calling (WebRTC) between My Circle family members. Care Call rings through the same in-app call system; it does not place SIM/PSTN calls and does not read the call log or phone state.

## ৩. Data safety — কী যোগ করতে হবে

| তথ্য | কেন | শেয়ার |
|---|---|---|
| Audio (voice recording) — সেটারের নিজের রেকর্ড | কেয়ার কলে নিজের গলা শোনানোর জন্য | শুধু সেই রিসিভারের ফোনে; কোনো AI-কে দেওয়া হয় না, বিক্রি হয় না; Care Call মুছলে ফাইলও মুছে যায় |
| App activity — কেয়ার কলের লেখা, সময়, "হয়ে গেছে" | কল বাজানো ও সেটারকে খবর দেওয়া | শুধু সেটার ও রিসিভার |

ঐচ্ছিক নয় বলে চিহ্নিত করবেন না — কেয়ার কল ঐচ্ছিক ফিচার (Optional)।

## ৪. Store listing — বাংলা

**ছোট বিবরণে যোগ (যদি জায়গা থাকে):** "কেয়ার কল — প্রিয়জনকে নিজের গলায় ঠিক সময়ে মনে করিয়ে দিন"

**বড় বিবরণের অংশ:**

> **কেয়ার কল — পরিবারের যত্নের রিমাইন্ডার কল**
> মা-বাবা বা প্রিয়জনের জন্য একটা সময় ঠিক করুন, নিজের গলায় কথাটা রেকর্ড করুন — "আম্মু, খাবার খেয়ে নাও", "নামাজের সময় হয়েছে", "আজ বিল দেওয়ার দিন"। ঠিক সময়ে তাঁর ফোনে কলের মতো পুরো-স্ক্রিন বাজবে, আপনার গলা শোনাবে। উনি "হয়ে গেছে" চাপলে আপনি জানবেন; না ধরলে ১০ মিনিট পরে আবার বাজবে, তারপর আপনাকে খবর দেবে।
> • যিনি কল পাবেন, তাঁর একবার সম্মতি লাগে; যেকোনো সময় বন্ধ করতে পারেন
> • তাঁর নিজের "নীরব সময়" মানা হয়
> • নেট না থাকলেও ফোনের নিজের অ্যালার্মে বাজে
> • শুধু আপনার নিজের গলা — কোনো AI কণ্ঠ নকল নয়
> • ফ্রি, বিজ্ঞাপন নেই

## ৫. Store listing — English

> **Care Call — a family care reminder call**
> Set a time for a loved one and record the reminder in your own voice — "Mum, time to eat", "prayer time", "today is bill day". At that time their phone rings full screen like a call and plays your voice. When they tap "Done" you know; if they don't answer, it rings again 10 minutes later and then tells you.
> • The receiver agrees once and can stop it any time
> • Respects their quiet hours
> • Rings from the phone's own alarm even without internet
> • Only your own recorded voice — never an AI voice
> • Free, no ads

**এড়িয়ে চলুন (listing-এ লিখবেন না):** "medical", "medication management", "health monitoring", "treatment", "pill tracker", কোনো রোগের নাম।

## ৬. মালিকের করণীয় (৫ মিনিট)

১. Play Console → App content → Full-screen intent → ওপরের English লেখাটা বসান → Save।
২. Data safety → Audio (voice recording) যোগ করুন (৩ নম্বর টেবিল)।
৩. Store listing-এ ৪/৫ নম্বরের অংশ যোগ করুন (ঐচ্ছিক)।
