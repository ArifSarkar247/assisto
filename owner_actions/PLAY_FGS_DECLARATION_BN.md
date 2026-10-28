# Play Console — Foreground service declaration (বিল্ড ২১৯ থেকে)

Play Console → **App content → Foreground service permissions**-এ দুটি টাইপ ঘোষণা করতে হবে: **Microphone, Location**। (**at100, ২৮ অক্টোবর:** Camera টাইপ আর নেই — নিচের ৩ নম্বর অংশ দেখুন।) প্রতিটির জন্য নিচের **ইংরেজি লেখা হুবহু কপি করে** বসান, আর প্রতিটির জন্য নিচের স্ক্রিপট অনুযায়ী ফোনে ~৩০ সেকেন্ডের একটা স্ক্রিন রেকর্ডিং করে (YouTube unlisted / Google Drive "anyone with link") লিংক দিন।

**অ্যাপে যা বদলেছে (বিল্ড ২১৯):** প্রতিটি সার্ভিস **শুধু ব্যবহারকারী নিজে চালু করলে** শুরু হয়, চলার সময় একটা **স্থায়ী নোটিফিকেশন** থাকে যেটা ফিচারের নাম বলে, আর তাতে **বন্ধ করার বাটন** আছে; কাজ শেষ হলে নিজে বন্ধ হয়। ফোন রিস্টার্টের পর কোনো সার্ভিস নিজে নিজে শুরু হয় না।

| টাইপ | কোন ফিচার | নোটিফিকেশনের লেখা (ইংরেজি UI) | বন্ধ করার বাটন |
|---|---|---|---|
| Microphone | “Hey Assisto” ডাক | “Hey Assisto” is on — listening for the wake word | **Stop** |
| Microphone + Location | Voice SOS | Voice SOS is on — listening for your SOS phrase | **Stop** |
| Microphone | My Circle কল চলাকালীন (অ্যাপ থেকে বেরিয়ে গেলে) | Call with ‹নাম› | **End call** |
| Location | Lost/Stolen সুরক্ষা | Lost/Stolen protection is on | **Turn off** (অ্যাপের সুরক্ষা পাতা খোলে; চোর যেন নোটিফিকেশন থেকে এক ট্যাপে বন্ধ করতে না পারে) |

---

## ১. MICROPHONE (FOREGROUND_SERVICE_MICROPHONE)

**Feature name / description (copy):**
> Hands-free voice features the user turns on: (1) the “Hey Assisto” wake word, (2) Voice SOS, which listens for the user's own emergency phrase and sends an SOS alert with location to their family, and (3) keeping the microphone working during an ongoing Assisto voice/video call when the user switches to another app. Each runs only after the user switches it on (or starts a call), shows a persistent notification that names the feature with a Stop / End call button, and stops when the user turns it off or the call ends. Speech for the wake word and Voice SOS is processed on the device.

**Why it must run in the foreground (copy):**
> These features must hear the user while Assisto is not on screen: an emergency phrase or wake word can be spoken at any moment, and a call must keep its audio when the user opens another app. Android only allows microphone access from the background through a microphone foreground service, and the user sees it the whole time through the notification.

**Impact if deferred or interrupted (copy):**
> The task cannot be deferred: a delayed Voice SOS means an emergency alert is not sent when the user is in danger; a paused call loses the user's voice mid-conversation; a deferred wake word simply does not respond. Each would fail the user at the moment they need it.

**৩০ সেকেন্ডের রেকর্ডিং স্ক্রিপট (মাইক্রোফোন):**
1. (০–৫ সে) ফোনের স্ক্রিন রেকর্ডার চালু করুন, Assisto খুলুন → মেনু → **Voice SOS**।
2. (৫–১২ সে) সুইচ চালু করুন → মাইক্রোফোনের অনুমতি "Allow" → দেখান উপরে নোটিফিকেশন এসেছে।
3. (১২–১৮ সে) হোম বাটন চাপুন, নোটিফিকেশন নামিয়ে দেখান: **"Voice SOS is on — listening for your SOS phrase"** আর **Stop** বাটন।
4. (১৮–২৪ সে) **Stop** চাপুন → নোটিফিকেশন চলে যায়।
5. (২৪–৩০ সে) Assisto → মেনু → **Assisto Voice** → “Hey Assisto” চালু → নোটিফিকেশন দেখান → **Stop** চাপুন।
(কলের অংশ দেখাতে চাইলে: My Circle → একজনকে কল → হোম চাপুন → নোটিফিকেশনে **"Call with …"** ও **End call**।)

---

## ২. LOCATION (FOREGROUND_SERVICE_LOCATION)

**Feature name / description (copy):**
> Personal safety features the user turns on: (1) Voice SOS — when the user's emergency phrase is heard, Assisto sends an SOS alert with the phone's current location to the family members the user chose; (2) Lost/Stolen protection — while the user keeps it switched on, Assisto watches for the phone being snatched, a SIM change or the phone going offline, and records the last location so the owner can find the phone. Both start only from the user's switch, show a persistent notification naming the feature with a Stop / Turn off button, and stop when switched off.

**Why it must run in the foreground (copy):**
> An emergency or a theft happens while the app is closed and the phone is in a pocket or in a thief's hand. The location must be read at that moment — Android only allows that from the background through a location foreground service, and the persistent notification keeps the user informed the whole time.

**Impact if deferred or interrupted (copy):**
> A deferred location means the family receives an SOS without knowing where the user is, and a stolen phone's last location is lost. These are safety-critical and cannot wait for the user to open the app.

**৩০ সেকেন্ডের রেকর্ডিং স্ক্রিপট (লোকেশন):**
1. (০–৫ সে) রেকর্ডার চালু → Assisto → মেনু → **Lost/Stolen** → **Always-on protection**।
2. (৫–১২ সে) সুরক্ষা চালু করুন → লোকেশনের অনুমতি "Allow" দেখান।
3. (১২–১৮ সে) হোম চাপুন → নোটিফিকেশন নামিয়ে দেখান: **"Lost/Stolen protection is on"** আর **Turn off** বাটন।
4. (১৮–২৫ সে) **Turn off** চাপুন → অ্যাপের সুরক্ষা পাতা খোলে → সুইচ বন্ধ করুন → নোটিফিকেশন চলে যায়।
5. (২৫–৩০ সে) মেনু → **Voice SOS** দেখান: এটাও চালু করলে "Microphone and location in use for voice SOS" লেখা আসে।

---

**journey100 (Safe Journey):** LOCATION ঘোষণায় তৃতীয় ফিচার (3) Safe Journey যোগ করতে হবে — কপি-লেখা আর ভিডিওর ধাপ `owner_actions/SAFE_JOURNEY_100_BN.md`-এর **খ** অংশে।

## ৩. CAMERA — আর ঘোষণা করতে হবে না (at100, ২৮ অক্টোবর)

অ্যাপ থেকে **FOREGROUND_SERVICE_CAMERA অনুমতি আর ক্যামেরা ফোরগ্রাউন্ড-সার্ভিস টাইপ সরানো হয়েছে।** কারণ: Play-র নিয়মে ক্যামেরা টাইপ শুধু চলমান, ব্যবহারকারীর চোখের সামনে থাকা ক্যামেরা ব্যবহারের জন্য (যেমন ভিডিও কল); সারাদিন চালু একটা সার্ভিসে "কখনো একটা ছবি" এর মধ্যে পড়ে না, আর লক-স্ক্রিনে লুকিয়ে ছবি তোলা stalkerware-এর মতো দেখায়।

এখন "অনুপ্রবেশকারীর ছবি" **শুধু Assisto স্ক্রিনে খোলা থাকলে** তোলা হয়: অ্যাপের ভেতরে কয়েকবার ভুল সিকিউরিটি পিন দিলে, শাটার-শব্দসহ একটি সামনের ক্যামেরার ছবি। এর জন্য সাধারণ CAMERA অনুমতিই যথেষ্ট (Data safety-তে ক্যামেরার লাইন — `ANTITHEFT_PLAY_DECLARATION_BN.md`)।

**আপনার কাজ:** নতুন AAB আপলোডের পর Play Console → App content → Foreground service permissions → Camera ঘোষণাটি মুছে দিন (অ্যাপ আর এটা ব্যবহার করে না)।

---

## ৪. Full-screen intent (USE_FULL_SCREEN_INTENT) — আগের মতোই রাখা হয়েছে
আপনি ঘোষণা করেছেন: **calls (making and receiving calls)**, pre-granted নয়। অ্যাপ এখন Android 14+-এ অনুমতি আছে কিনা দেখে; না থাকলে My Circle খুললে (বা প্রথম আসা কলের পরে) **একবার** পরিষ্কার একটা প্রশ্ন দেখায় যেটা সরাসরি Settings → Full screen notifications খোলে। অনুমতি না দিলেও কল বাজে — স্ক্রিনের উপরে উচ্চ-প্রাধান্যের কল নোটিফিকেশন হিসেবে (Accept/Decline সহ)।

## ৫. ছবি/ভিডিও (Photo & Video permissions)
READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_AUDIO, READ_EXTERNAL_STORAGE — **সব সরানো** (Play ও ওয়েবসাইট দুই বিল্ডেই)। সব জায়গায় ছবি/ভিডিও বাছাই এখন Android-এর **Photo Picker** দিয়ে, কোনো অনুমতি লাগে না। Play Console-এ Photo and video permissions ফর্মে আর কিছু ঘোষণা করতে হবে না — নতুন AAB আপলোডের পর পুরনো ঘোষণা মুছে দিন / "does not use" বেছে নিন।
