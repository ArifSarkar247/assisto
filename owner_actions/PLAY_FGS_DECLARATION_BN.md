# Play Console — Foreground service (FGS) ও Full-screen intent ঘোষণা (৮ Nov সব-ফিচার লঞ্চ)

**হালনাগাদ:** ২ Nov ২০২৬ (playall)। আগের সংস্করণে "Hey Assisto" ছিল, নিরাপদ যাত্রা ছিল না, আর লেখা ছিল "রিস্টার্টের পরে কোনো সার্ভিস নিজে চালু হয় না" — তিনটিই কোডের সাথে মিলত না। এখন কোড থেকে মিলিয়ে লেখা।

**কোথায়:** Play Console → Policy → **App content** → **Foreground service permissions**। দুটি টাইপ ঘোষণা করবেন: **Microphone** আর **Location**। **Camera নয়।** Play বিল্ডে আর কোনো FGS টাইপ নেই। CI এটা পাহারা দেয় (`android.yml`-এর Play ধাপ + `app/test/play_disclosure_guard_test.dart`)।

প্রতিটি টাইপের জন্য Google চায়:
1. ফিচারের বিবরণ;
2. থামলে বা দেরি হলে ব্যবহারকারীর কী ক্ষতি;
3. একটা ভিডিও-লিংক (YouTube unlisted বা Google Drive "anyone with the link");
4. use case বাছাই।

নিচের **ইংরেজি লেখা হুবহু কপি করুন।**

## Play বিল্ডে আসলে যে সার্ভিস আছে (CI-র তৈরি ম্যানিফেস্ট)

| সার্ভিস (ম্যানিফেস্টে) | টাইপ | কোন ফিচার | কখন চালু হয় | নোটিফিকেশন ও বন্ধের বোতাম |
|---|---|---|---|---|
| `flutter_foreground_task` ForegroundService (`microphone\|location` ঘোষিত, চালুর সময় যেটা লাগে শুধু সেটা) | **Microphone + Location** | **ভয়েস SOS** | ব্যবহারকারী Voice SOS-এর সুইচ চালু করলে | "Voice SOS is on…" + **Stop** |
| একই সার্ভিস | **Microphone** | **My Circle কল** চলার সময় অ্যাপ থেকে বেরোলে (`call_keepalive.dart:89`) | কল শুরু হলে, কল শেষে বন্ধ | "Call with ‹নাম›" + **End call** |
| একই সার্ভিস | **Location** | **নিরাপদ যাত্রা** (`journey_tracker.dart:402`): প্রতি ৩০ সেকেন্ডে লোকেশন | ব্যবহারকারী যাত্রা শুরু করলে, অ্যাপ খোলা থাকা অবস্থায়। পৌঁছালে, Stop চাপলে বা সময় পেরোলে বন্ধ। | "Safe Journey is on" |
| `AntiTheftService` | **Location** | **হারানো/চুরি সুরক্ষা** | ব্যবহারকারী Security PIN দিয়ে সুরক্ষা চালু করলে। চালু থাকা অবস্থায় অ্যাপ খুললে, অ্যাপ আপডেট হলে আর ফোন চালু হলে নিজে আবার চালু হয় (Android ৮–১৩)। Android ১৪+-এ ব্যাকগ্রাউন্ড থেকে চালু হয় না, তখন "ট্যাপ করে আবার চালু করুন" নোটিফিকেশন দেখায় (`RestartPolicy.kt`)। | "Lost/Stolen protection is on" + **Turn off** (অ্যাপের সুরক্ষা পাতা খোলে, PIN চায়) |
| ~~`WakeWordService`~~ | ~~Microphone~~ | "Hey Assisto" | **Play বিল্ড থেকে সরানো (playall)।** কোনো বিল্ডেই ফিচার চালু নয় (`VaWake.shipped` = false)। | — ঘোষণা করবেন না |
| ~~Camera FGS~~ | — | চোরের ছবি | at100-এ সরানো হয়েছে। ছবি ওঠে শুধু Assisto খোলা থাকলে, অ্যাপের ভেতরে ভুল Security PIN দিলে। | — ঘোষণা করবেন না। আগের Camera ঘোষণা থাকলে মুছে দিন। |
| ~~`GeolocatorLocationService`~~ | — | (plugin-এর, আমরা ব্যবহার করি না) | ম্যানিফেস্ট থেকে সরানো | — |

**ব্যাকগ্রাউন্ড লোকেশন:** `ACCESS_BACKGROUND_LOCATION` ম্যানিফেস্টে **নেই**। CI ধরলে বিল্ড ফেল করে। তাই Console-এ "Location permissions" (background) ফর্ম আসবে না।

তবে Google-এর নিয়মে, যে FGS ব্যবহারকারীর কাজ শেষ হওয়ার পরেও লোকেশন নেয়, সেটাকে "ব্যাকগ্রাউন্ডের সমান" ধরা হতে পারে। **হারানো/চুরি সুরক্ষা ঠিক এমন।** তাই:
- অ্যাপের ঘোষণা-পাতায় Google-এর চাওয়া শব্দগুলো আছে: "location" + "even when the app is closed or not in use" + সব ফিচারের নাম (`at100DiscLocBody2`, playall)।
- **ঝুঁকি আছে।** নিচে "ঝুঁকি ও বিকল্প" দেখুন।

---

## ১. MICROPHONE (FOREGROUND_SERVICE_MICROPHONE)

**Use case বাছুন:** "Background audio access" / "Other", যেটা ফর্মে থাকে। বিবরণে দুটো কাজই লিখুন।

**Feature description (copy):**
> Two features the user turns on: (1) Voice SOS — while the user keeps it switched on, Assisto listens on the device for the user's own emergency phrase and, when it is heard, sends an SOS alert with the phone's location to the family members the user chose. Speech is converted to text on the device only; nothing is recorded or uploaded. (2) Ongoing My Circle voice/video calls — the microphone keeps working when the user switches to another app during a call. Each starts only from the user's own action (the Voice SOS switch, or starting/answering a call), shows a persistent notification naming the feature with a Stop / End call button, and stops when switched off or when the call ends.

**User impact if deferred or interrupted (copy):**
> Neither task can be deferred. A paused Voice SOS means the user's emergency phrase is not heard and no alert reaches the family while the user is in danger. A paused call loses the user's voice in the middle of the conversation.

**ভিডিও (৩০–৪৫ সেকেন্ড):**
1. স্ক্রিন রেকর্ডার চালু → Assisto → মেনু → **Voice SOS**।
2. সুইচ চালু → অ্যাপের নিজের ঘোষণা-পাতা দেখান ("…even when the app is closed or not in use…") → **Continue** → Android-এর মাইক্রোফোন অনুমতি **Allow** → লোকেশন **While using the app**।
3. হোম বাটন চাপুন → নোটিফিকেশন নামিয়ে দেখান **"Voice SOS is on"** আর **Stop** → **Stop** চাপুন, নোটিফিকেশন চলে যায়।
4. My Circle → একজনকে কল (দ্বিতীয় ফোন বা অ্যাকাউন্ট ধরে) → হোম চাপুন → নোটিফিকেশনে **"Call with …"** আর **End call** → End call।

## ২. LOCATION (FOREGROUND_SERVICE_LOCATION)

**Use case বাছুন:** **"User-initiated location sharing"** (Google-এর তালিকায় আছে)। বিবরণে তিনটে ফিচারই লিখুন।

**Feature description (copy):**
> Personal-safety location features the user turns on: (1) Safe Journey — the user starts a journey and Assisto shares the phone's live location every 30 seconds with the people the user chose until the journey ends (arrival, Stop, or time-out), also with the screen off; (2) Voice SOS — when the user's emergency phrase is heard, the current location is sent with the SOS alert to the user's family; (3) Lost/Stolen phone protection — while the owner keeps it switched on (it needs the owner's Security PIN), Assisto reads the phone's location only for alerts to the owner's trusted contacts (phone snatched, SIM changed, phone offline, low battery) and for lost mode, and it receives the remote actions (lost mode, loud alarm, lock, lock-screen message) that the owner or those contacts send from another phone; the same switched-on service also offers optional, off-by-default safety triggers (an SOS button on its notification, an SOS after five quick power-button presses), each with a countdown the user can cancel. Every feature starts only from the user's own switch in the app, shows a persistent notification naming it with a Stop / Turn off button, and stops when switched off. The app never requests ACCESS_BACKGROUND_LOCATION; location is never sold or used for ads.

**User impact if deferred or interrupted (copy):**
> These are safety features. If the service is deferred, the family following a Safe Journey loses the user's live position, an SOS arrives without a location, and a stolen phone's last location is lost — exactly when the user needs help.

**ভিডিও (৪৫–৬০ সেকেন্ড):**
1. Assisto → মেনু → **Safe Journey** → গন্তব্য বাছুন → My Circle থেকে একজন বাছুন → **Start** → অ্যাপের ঘোষণা-পাতা ("…even when the app is closed…") → **Continue** → **While using the app**।
2. হোম চাপুন → নোটিফিকেশন **"Safe Journey is on"** দেখান → অ্যাপে ফিরে **Stop** (বা "I've arrived") → নোটিফিকেশন চলে যায়।
3. মেনু → **Lost/Stolen** → **Always-on protection** → চালু করুন → ঘোষণা-পাতা → Continue → অনুমতি → Security PIN।
4. হোম চাপুন → নোটিফিকেশন **"Lost/Stolen protection is on"** আর **Turn off** দেখান → **Turn off** → অ্যাপের পাতা খোলে → PIN দিয়ে বন্ধ করুন।

## ৩. Full-screen intent (USE_FULL_SCREEN_INTENT)

**কোথায়:** App content → **Full-screen intent**।

**বাছুন:** শুধু **"Calling"** (making and receiving calls)।

**"Alarm" বাছবেন না।** কোডে full-screen ব্যবহার হয় শুধু ইনকামিং কলে: `push_notifier.dart:147` (`isCall`) আর `IncomingCall.kt:442`। SOS বা রিমাইন্ডার full-screen দেখায় না। রিমাইন্ডার চলে `setAlarmClock` আর সাধারণ নোটিফিকেশন দিয়ে।

Android ১৪+-এ অনুমতি না থাকলে অ্যাপ একবার জানায়, আর Settings খুলে দেয়। অনুমতি না দিলেও কল বাজে, উচ্চ-প্রাধান্যের নোটিফিকেশন হিসেবে।

## ৪. Exact alarms

- `SCHEDULE_EXACT_ALARM` আছে। এর জন্য Console ফর্ম লাগে না। ব্যবহারকারী নিজে "Alarms & reminders" দেন; না দিলে অ্যাপ সৎভাবে "সময় একটু এদিক-ওদিক হতে পারে" দেখায়।
- `USE_EXACT_ALARM` (যেটা শুধু অ্যালার্ম-ঘড়ি বা ক্যালেন্ডার অ্যাপ পায়) **সরানো আছে**। CI পাহারা দেয়।

## ৫. ছবি ও ভিডিও (Photo & Video permissions)

`READ_MEDIA_*` আর `READ_EXTERNAL_STORAGE` দুই বিল্ড থেকেই সরানো। সব ছবি বাছাই হয় Android-এর Photo Picker দিয়ে।

Console-এ ফর্ম এলে "does not use" বাছুন।

## ঝুঁকি ও বিকল্প (সৎভাবে)

1. **হারানো/চুরি সুরক্ষা (সবচেয়ে ঝুঁকির):** Google-এর FGS তালিকায় "anti-theft" নামে আলাদা use case নেই। নিয়ম বলে, FGS শুরু হতে হবে ব্যবহারকারীর কাজ থেকে, আর কাজ শেষ হলেই থামতে হবে।
   - আমাদের সুরক্ষা ব্যবহারকারী নিজে চালু করেন, কিন্তু সারাদিন চলে।
   - রিভিউয়ার এটাকে ব্যাকগ্রাউন্ড লোকেশন ধরলে **পুরো রিলিজ আটকে যেতে পারে।**
   - **তাই আগেই পরীক্ষা করুন:** ৩–৪ Nov-এর closed-testing রিলিজের সাথেই এই ঘোষণাগুলো জমা দিন। রিভিউয়ের ফল ৮ Nov-এর আগে জানা যাবে।
   - **প্রত্যাখ্যান হলে:** Owner Admin → `anti_theft` → Play বন্ধ করুন, আর আমাকে বলুন। আমি Play বিল্ড থেকে `AntiTheftService` সরিয়ে দেব (`WakeWordService`-এর মতো, এক লাইনের কাজ)। বাকি ঘোষণা আগের মতোই থাকবে। ওয়েবসাইটের APK-তে চুরি-রোধ থাকবে।
2. **ভয়েস SOS:** মাইক সারাক্ষণ শোনে, আর লোকেশন নেয় শুধু SOS পাঠানোর মুহূর্তে। এটা Google-এর "voice commands" ধরনের মধ্যে পড়ে। ঝুঁকি কম।
3. **নিরাপদ যাত্রা:** Google-এর তালিকার "user-initiated location sharing"-এর সাথে হুবহু মেলে। ঝুঁকি কম।
## ৫. ছবি/ভিডিও (Photo & Video permissions)
READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_AUDIO, READ_EXTERNAL_STORAGE — **সব সরানো** (Play ও ওয়েবসাইট দুই বিল্ডেই)। সব জায়গায় ছবি/ভিডিও বাছাই এখন Android-এর **Photo Picker** দিয়ে, কোনো অনুমতি লাগে না। Play Console-এ Photo and video permissions ফর্মে আর কিছু ঘোষণা করতে হবে না — নতুন AAB আপলোডের পর পুরনো ঘোষণা মুছে দিন / "does not use" বেছে নিন।

## ৬. ট্রেন ট্র্যাকার + গন্তব্য অ্যালার্ম — LOCATION (নতুন, ফ্ল্যাগ `train_tracker` / `dest_alarm`, এখন বন্ধ)
নতুন অনুমতি লাগে না — একই `FOREGROUND_SERVICE_LOCATION` (flutter_foreground_task সার্ভিস, type `location`), শুধু নিচের দুই কাজের যেকোনোটা **চালু থাকলে**, অ্যাপ সামনে থাকা অবস্থায় শুরু হয়; নোটিফিকেশনে সবসময় "থামুন" বোতাম। `ACCESS_BACKGROUND_LOCATION` লাগে না।
**Play Console-এ ইংরেজিতে যা লিখবেন (কপি করুন):**
> Assisto uses a location foreground service only while the user has turned on (a) "I am on this train" sharing, which sends the passenger's location so other passengers see the train's position (stops automatically on arrival, at the end of the trip, or with one tap), or (b) a destination alarm, which checks on the device how close the user is to the stop they chose (bus, train, metro or launch) and wakes them before it. Both are started by the user from the foreground, show a persistent notification with a Stop button, and stop as soon as the task ends. Location is not collected at any other time.
**ভিডিওর ধাপ (৩০–৪৫ সেকেন্ড, স্ক্রিন রেকর্ড):** ১) ড্রয়ার → ট্রেন ট্র্যাকার → একটি ট্রেন খুলুন → "আমি এই ট্রেনে আছি" → সম্মতির পাতা → শুরু; ২) নোটিফিকেশন টেনে "ট্রেনের লোকেশন শেয়ার হচ্ছে" + থামুন দেখান; ৩) থামুন চাপুন — নোটিফিকেশন চলে যায়; ৪) গন্তব্য অ্যালার্ম → স্টেশন বাছুন → ৫০০ মি → চালু; নোটিফিকেশন দেখান; ৫) "অ্যালার্ম বন্ধ" (বাজার সময় "আমি জেগে আছি") — নোটিফিকেশন চলে যায়।
