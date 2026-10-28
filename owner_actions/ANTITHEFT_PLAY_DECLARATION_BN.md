# চুরি-রোধ: Play ঘোষণার পুরো প্যাকেজ (at100, ২৮ অক্টোবর)

এই পাতায় আছে: চুরি-রোধ ইঞ্জিন কোন কোন সংবেদনশীল অনুমতি ব্যবহার করে, প্রতিটির Play নিয়ম, কেন দরকার, অ্যাপে অনুমতির আগে কোন প্রকাশ্য ঘোষণা (prominent disclosure) দেখানো হয়, Play Console ফর্মে কী লিখবেন, আর ভিডিওতে ধাপে ধাপে কী রেকর্ড করবেন।
ইংরেজি অংশগুলো **হুবহু কপি করে** Play Console-এ বসান।

## ০. এক নজরে — কী রাখা হলো, কী সরানো হলো

| অনুমতি / API | এখন | কেন |
|---|---|---|
| Device Admin (`BIND_DEVICE_ADMIN`) — `force-lock`, `watch-login` | **রাখা** | দূর থেকে লক, ভুল আনলক চেষ্টা টের পাওয়া |
| Device Admin `limit-password`, `reset-password` | **সরানো** | কোথাও ব্যবহার হতো না; Android 9/10 থেকে ডিভাইস অ্যাডমিনের জন্য বাতিল (deprecated) |
| Device Admin `wipe-data` (দূর থেকে মুছে ফেলা) | **কখনো চাওয়া হয়নি, এখনো না** | অপরিবর্তনীয় ও ঝুঁকিপূর্ণ; Google Find Hub বিনা খরচে মুছে দেয় — অ্যাপে সরাসরি Find Hub-এর বোতাম আছে |
| `FOREGROUND_SERVICE_CAMERA` + ক্যামেরা FGS টাইপ | **সরানো** | Play-র FGS নিয়মে ক্যামেরা টাইপ শুধু চলমান, চোখের সামনের ক্যামেরা ব্যবহারে চলে; সারাদিনের সার্ভিসে "কখনো একটা ছবি" এর মধ্যে পড়ে না। লক-স্ক্রিনে ছবি তোলা stalkerware মনে হতে পারে |
| `FOREGROUND_SERVICE_LOCATION` + `ACCESS_FINE/COARSE_LOCATION` (শুধু অ্যাপ ব্যবহারের সময়ের অনুমতি) | **রাখা** | সতর্কবার্তায় শেষ লোকেশন, হারানো মোড |
| `ACCESS_BACKGROUND_LOCATION` | **চাওয়া হয় না** | — |
| `CAMERA` (সাধারণ রানটাইম অনুমতি) | **রাখা, শুধু অ্যাপ খোলা থাকলে** | ইনট্রুডার ছবি: অ্যাপের ভেতরে ভুল সিকিউরিটি পিন দিলে, শাটার-শব্দসহ |
| SMS পড়া/পাঠানো, `READ_PHONE_STATE`, Accessibility, `SYSTEM_ALERT_WINDOW` | **ব্যবহার হয় না** | SIM বদল ধরা হয় অনুমতি ছাড়াই পড়া যায় এমন তথ্য দিয়ে |
| `RECEIVE_BOOT_COMPLETED`, `POST_NOTIFICATIONS`, `VIBRATE`, `WAKE_LOCK`, `ACCESS_WIFI_STATE`, `ACCESS_NETWORK_STATE` | রাখা (সাধারণ অনুমতি, কোনো ফর্ম নেই) | রিস্টার্টে সুরক্ষা ফেরানো, সতর্কবার্তা, অ্যালার্মে কাঁপুনি, বাসার ওয়াই-ফাই নিয়ম |

**দূর থেকে চালানোর সুইচ (নতুন):** হারানো মোড, জোরে অ্যালার্ম, স্ক্রিন লক, লক-স্ক্রিনে বার্তা, অ্যালার্ম থামানো। এগুলো কোনো নতুন অনুমতি চায় না — শুধু সার্ভার দিয়ে যায় (লগইন করা মালিক বা মালিকের বেছে নেওয়া বিশ্বস্ত মানুষ), সীমা আছে, অডিট লগে লেখা থাকে। **SMS কমান্ড নেই।**

---

## ১. Device Admin (`BIND_DEVICE_ADMIN`)

**Play নিয়ম:** Device Admin-এর জন্য আলাদা ঘোষণা-ফর্ম নেই; এটা দেখা হয় *Permissions and APIs that Access Sensitive Information* ও *Device and Network Abuse* নীতিতে, আর *User Data → Prominent Disclosure and Consent*: অ্যাপের ভেতরে, সিস্টেমের প্রশ্নের **আগে**, পরিষ্কার ভাষায় কী করে আর কেন। চুরি-রোধ (anti-theft) ব্যবহার অনুমোদিত, যদি ব্যবহারকারী নিজে চালু করে, সবসময় বন্ধ করতে পারে, আর অ্যাপ নিজেকে লুকায় না।

**কেন দরকার:** (১) মালিক বা বিশ্বস্ত মানুষ অন্য ফোন থেকে "লক" বা "লক-স্ক্রিনে বার্তা" চাপলে `lockNow()`; (২) টান ধরা পড়লে সাথে সাথে লক (মালিক চালু করলে); (৩) `onPasswordFailed` — ভুল স্ক্রিন-আনলক চেষ্টার সংখ্যা বিশ্বস্ত মানুষদের জানানো।

**অ্যাপে প্রকাশ্য ঘোষণা:** "হারানো/চুরি" পাতায় "চালু করুন" চাপলে আগে Assisto-র নিজের পাতা `at100DiscAdminTitle/Body` (বাংলা/ইংরেজি) — কোন দুটি কাজে লাগে, মোছার ক্ষমতা চায় না, স্ক্রিন-লকের কোড পড়ে না, কীভাবে বন্ধ করবেন। "এগিয়ে যান" চাপলে তবেই Android-এর "Activate device admin app?" পাতা খোলে। "এখন নয়" চাপলে কিছুই হয় না।

**Play Console-এ যদি জিজ্ঞেস করে (App content → বা রিভিউ টিমের মেইলে) — কপি করুন:**
> Assisto uses the Device Administration API only for the user's own anti-theft protection, which the user switches on from Lost/Stolen protection. Policies: force-lock (lock the screen when the owner, or a trusted contact the owner chose, presses "Lock" or "Lock-screen message" from another phone through our server, or right after a detected grab if the user enabled that) and watch-login (count wrong screen-unlock attempts and alert the owner's trusted contacts). We do NOT request wipe-data, password, camera or keyguard policies. Before Android's activation screen the app shows its own disclosure explaining both uses. The app icon is never hidden, a persistent notification is shown while protection runs, and the user can deactivate it any time in Settings → Security → Device admin apps.

---

## ২. লোকেশন ফোরগ্রাউন্ড সার্ভিস (`FOREGROUND_SERVICE_LOCATION`)

**Play নিয়ম:** Foreground service permissions ঘোষণা (Play Console → App content → Foreground service permissions → **Location**), ভিডিওসহ। লোকেশনের জন্য prominent disclosure। Background location চাওয়া হয় না, তাই "Location permissions" (background) ফর্ম লাগবে না।

**অ্যাপে প্রকাশ্য ঘোষণা:** সুরক্ষা চালু করার সময় লোকেশনের অনুমতি না থাকলে, আর "লোকেশনের অনুমতি দিন" চাপলে, আগে `at100DiscLocTitle/Body` — কী জন্য, কারা দেখে, কতদিন রাখা হয়, "সবসময়" চাওয়া হয় না, কীভাবে বন্ধ করবেন। তারপর Android-এর প্রশ্ন।

**ফর্ম — Feature description (কপি; আগের LOCATION লেখার (2) অংশ এটা দিয়ে বদলে দিন):**
> (2) Lost/Stolen protection — while the user keeps it switched on, Assisto watches for the phone being snatched, a SIM change or the phone going offline, records the last location so the owner's chosen trusted contacts can find the phone, and receives the remote actions (lost mode, loud alarm, lock, lock-screen message) that the owner or those contacts send from another phone. It starts only from the user's switch (Security PIN), shows a persistent "Lost/Stolen protection is on" notification, and stops when switched off.

**Why foreground (কপি):**
> A theft happens while the app is closed and the phone is in the thief's hand. The location must be read at that moment and a remote alarm or lock must be received within seconds; Android only allows this from the background through a location foreground service, and the notification keeps the user informed.

**Impact if deferred (কপি):**
> The trusted contacts would get a theft alert without any location, and a remote alarm or lock would arrive hours later, when the phone is already switched off or reset.

**ভিডিও (৩০–৪০ সেকেন্ড) — ধাপে ধাপে:**
1. (০–৫ সে) স্ক্রিন রেকর্ডার চালু → Assisto → মেনু → **হারানো/চুরি** → **সার্বক্ষণিক সুরক্ষা**।
2. (৫–১২ সে) **চালু করুন** → সিকিউরিটি পিন → লোকেশনের ঘোষণা পাতা দেখান (পুরো লেখা ২ সেকেন্ড স্থির রাখুন) → **এগিয়ে যান** → Android-এ **While using the app**।
3. (১২–১৮ সে) হোম চাপুন → নোটিফিকেশন টেনে নামান: **Lost/Stolen protection is on** আর **Turn off** দেখান।
4. (১৮–৩০ সে) দ্বিতীয় ফোনে (বিশ্বস্ত মানুষ) **যাঁদের ফোন আমি দেখে রাখি** → **জোরে বাজান** → প্রথম ফোন বাজছে, লক-স্ক্রিনে "Assisto alarm" আর **Stop** দেখান → Stop।
5. (৩০–৪০ সে) প্রথম ফোনে Assisto → **Turn off** → পিন → নোটিফিকেশন চলে যায়।

---

## ৩. ক্যামেরা (`CAMERA`) — ইনট্রুডার ছবি, শুধু অ্যাপ খোলা থাকলে

**সিদ্ধান্ত:** লক-স্ক্রিনে/ব্যাকগ্রাউন্ডে ছবি তোলা **বাদ**। Android ব্যাকগ্রাউন্ড অ্যাপকে ক্যামেরা দেয় না যদি না ক্যামেরা-টাইপের ফোরগ্রাউন্ড সার্ভিস চালু থাকে, আর সেটা Play-র নিয়মে এই কাজে চলে না। তাই এখন ছবি তোলা হয় **শুধু Assisto স্ক্রিনে খোলা থাকলে**, যখন অ্যাপের ভেতরে পরপর কয়েকবার (মালিকের ঠিক করা সংখ্যা, সাধারণত ৩) **ভুল সিকিউরিটি পিন** দেওয়া হয় — যেমন টানের পরে "আপনি ঠিক আছেন?" প্রশ্নে, বা কেউ সুরক্ষা বন্ধ করার চেষ্টা করলে। স্ক্রিন-আনলকের ভুল চেষ্টা শুধু সংখ্যা হিসেবে জানানো হয়, ছবি নয়।

**লুকানো নয়:** শাটার-শব্দ বাজে, Android-এর ক্যামেরার সবুজ বিন্দু জ্বলে, আর অপশন চালু থাকলে প্রতিটি সিকিউরিটি-পিনের বাক্সে লেখা থাকে "ভুল পিন দিলে সামনের ক্যামেরায় ছবি তোলা হয় (মালিক এটি চালু করেছেন)"।

**সম্মতি:** শুরুতে বন্ধ। চালু করতে আগে পুরো পাতা `IntruderConsentScreen` (কী, কখন, লুকানো নয়, কোথায় থাকে, কে দেখে, কতদিন, বন্ধ/মোছা, "শুধু নিজের ফোনে" সতর্কতা) → "আমি রাজি" → তারপর Android-এর ক্যামেরা অনুমতি → সিকিউরিটি পিন। সার্ভার সম্মতির সংস্করণ (`intruder_consent=1`) ছাড়া এটা চালু হতে দেয় না, আর সম্মতির সময় অডিট লগে রাখে। আগের বিল্ডে সম্মতি ছাড়া যাঁদের চালু ছিল, তাঁদের জন্য এটা এখন বন্ধ ধরা হয় (আবার সম্মতি দিতে হবে)।

**Play Console-এ কোনো আলাদা ফর্ম নেই** (CAMERA সাধারণ রানটাইম অনুমতি)। শুধু Data safety (নিচে)।

---

## ৪. Data safety ফর্মে যা বদলাবেন / নিশ্চিত করবেন

| ডেটা টাইপ | Collected | Shared | ঐচ্ছিক? | উদ্দেশ্য | লেখা |
|---|---|---|---|---|---|
| **Location → Precise / Approximate** | হ্যাঁ | না (বিশ্বস্ত মানুষ = ব্যবহারকারীর নিজের বাছাই, অ্যাপের ভেতরের "user-initiated" — Play-তে shared নয়) | হ্যাঁ (সুরক্ষা চালু করলে) | App functionality, Fraud prevention/security | ২৪ ঘণ্টা হার্টবিট, সতর্কবার্তা ৩০ দিন |
| **Photos and videos → Photos** | হ্যাঁ | না | হ্যাঁ (ইনট্রুডার ছবি, সম্মতি দিলে) | Fraud prevention, security | এনক্রিপ্ট করা, ৩০ দিনে মুছে যায় |
| **Device or other IDs** | হ্যাঁ (আগের মতো) | না | — | Security | ফোনের হ্যাশ করা আইডি |
| **App activity → Other actions** | হ্যাঁ | না | হ্যাঁ | Security | দূর থেকে চালানো সুইচ: কে পাঠাল, কখন, ফল কী (অডিট) |

Encrypted in transit: **Yes**। Users can request deletion: **Yes**।
ওয়েবসাইটের প্রাইভেসি পাতা (`/privacy`) একই কথা বলে (backend/web/legal_content.py আপডেট করা হয়েছে)।

---

## ৫. Play রিভিউ যদি প্রশ্ন করে "stalkerware?" — উত্তর (কপি)
> Assisto's anti-theft protects only the signed-in user's own phone. It is switched on by the user with their Security PIN, shows a persistent notification the whole time, never hides its icon, and can be switched off by the user. Alerts and remote actions go only to trusted contacts the owner selected from their own circle; every remote action is authenticated, rate-limited and recorded in the owner's audit log. The optional intruder photo is off by default, requires an explicit in-app consent screen, is taken only while Assisto is open on screen after wrong Security PINs typed inside Assisto, plays the shutter sound and is announced on every PIN box. There is no remote wipe, no SMS command, no background camera, no call/SMS/message monitoring.

---

## ৬. আপনার কাজের তালিকা (Play Console)
1. Foreground service permissions → **Camera ঘোষণা মুছুন**; **Location** ঘোষণার (2) অংশ উপরের লেখা দিয়ে বদলান; নতুন ভিডিও (৫ ধাপ) দিন।
2. Data safety → Photos (ঐচ্ছিক, security) আর App activity → Other actions যোগ/নিশ্চিত করুন।
3. রিভিউ মেইল এলে ১ ও ৫ নম্বরের লেখা পাঠান।
4. চুরি-রোধ Play-তে দেখানোর আগে `ANTITHEFT_100_BN.md`-এর দুই-ফোন পরীক্ষা পাস হতে হবে।
