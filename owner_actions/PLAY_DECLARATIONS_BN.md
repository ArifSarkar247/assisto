# Google Play — সব ঘোষণা এক জায়গায় (play-decl, ১৮ Nov ২০২৬)

**মালিকের স্থায়ী আদেশ:** Play অ্যাপ থেকে কিছুই লুকানো থাকবে না। যেখানে Google Play একটা ফর্ম (ঘোষণা + ভিডিও) চায়, সেটা এখানে পুরো তৈরি। আপনি ক্লিকগুলো করবেন, তারপর লিড একটা সুইচ বদলাবে, আর পরের বিল্ডে ফিচারটা Play-তে চলে আসবে।

**সুইচ কীভাবে কাজ করে:** `.github/workflows/android.yml`-এর Play ধাপে আছে `PLAY_DECLARED: ''`। প্রতিটা ফিচারের একটা নাম (key) আছে, যেমন `screen_share`। আপনি ফর্ম জমা দিলে লিড নামটা এই তালিকায় যোগ করে। যোগ না করা পর্যন্ত:
- সেই ফিচারের অনুমতি আর সার্ভিস Play বিল্ডে ঢোকে না।
- ভুল করে ঢুকে গেলে CI বিল্ড থামিয়ে দেয়।

ওয়েবসাইটের APK-তে সবকিছু সবসময় চালু থাকে। ডেমো ভিডিও সেটা দিয়েই বানাবেন। নিয়ম পাহারা দেয় `tools/ci/play_declared.py` আর `backend/core/tests_play_declared.py`।

> Play Console-এ এজেন্টরা কিছুই বদলায়নি। প্রতিটা ক্লিক আপনার। সব ফর্মের শেষে: বাঁ মেনু **Publishing overview → Send changes for review**।
> Console-এর বোতামের নাম Google মাঝে মাঝে বদলায়। ক্রম একই থাকে।
> ভিডিও: ফোনের নিজের স্ক্রিন রেকর্ডার দিয়ে বানান, তারপর YouTube-এ **Unlisted** আপলোড করুন (নিয়ম `SCREEN_SHARE_PLAY_BN.md` ধাপ ২–৩-এ আছে)। শুধু নমুনা নাম ব্যবহার করুন, ব্যাংক বা OTP খুলবেন না।

## এক নজরে — কোনটা আগে (মূল্য অনুযায়ী)

| # | ফিচার | এখন Play-তে? | কী জমা দিতে হবে | সুইচ |
|---|---|---|---|---|
| ১ | CCTV গার্ড বক্স / ফোন-ক্যামেরা, স্ক্রিন বন্ধ রেখে পাহারা | না (ক্যামেরা FGS কোনো বিল্ডেই নেই; cctv-guardbox লেন বানাচ্ছে) | FGS → Camera | `guardbox_camera` |
| ২ | কল, কেয়ার কল, অ্যালার্ম — লক স্ক্রিনে পুরো পর্দা | **হ্যাঁ** | Full-screen intent ঘোষণা হালনাগাদ (Calling + Alarm) | লাগে না |
| ৩ | ভিডিও কলে স্ক্রিন শেয়ার | না (ঘোষণার অপেক্ষায়) | FGS → Media projection | `screen_share` |
| ৪ | পরিবারের পৌঁছানোর খবর, অ্যাপ বন্ধ থাকলেও | না (সার্ভার সুইচ `family_auto_arrival` সবার জন্য বন্ধ) | Location FGS-এ যোগ; পরে Location permissions | `bg_location` (+ Owner Admin) |
| ৫ | ওষুধ, প্রেসক্রিপশন, স্বাস্থ্য-টাইমলাইন | না (personal অ্যাকাউন্টে Google মানে না) | Organization অ্যাকাউন্ট + Health apps | `medical` |
| ৬ | "Hey Assisto", ভয়েস SOS, কল (মাইক্রোফোন) | **হ্যাঁ** | ঘোষণা আছে (নিশ্চিত করুন) | লাগে না |
| ৭ | চুরি-রোধ (Device admin + লোকেশন FGS) | **হ্যাঁ** | ফর্ম নেই; রিভিউয়ের উত্তর তৈরি | লাগে না |
| ৮ | কলের পরে নোট, নোটিফিকেশন থেকে টাকা | **হ্যাঁ** | ফর্ম নেই; Data safety | লাগে না (সার্ভার সুইচ `money_notif_sms`) |
| ৯ | SMS, Accessibility, Activity recognition | কোনো বিল্ডে নেই, কোনো ফিচারেরও লাগে না | কিছু না | — |

**যা Play-তে ইচ্ছা করে আলাদা, কিন্তু লুকানো নয় (Google-এর নিয়ম):**
- **Play-তে কেনাকাটা শুধু Google Play Billing দিয়ে হয়।** তাই Play-তে শুধু সেই প্যাক দেখায়, যার Play product আছে। বিকাশ বা গেটওয়ের দাম শুধু APK-তে।
- **নিজে আপডেট করার ব্যবস্থা Play-তে নেই** (`REQUEST_INSTALL_PACKAGES` নেই)। আপডেট আসে Play থেকে।
- **সার্ভারের "Play" কলাম** (Owner Admin → Features): কোনো ফিচারে "Play" বন্ধ থাকলে সেটাও লুকানো। এই লেন লাইভ ডেটাবেস দেখেনি (নিয়ম)। আপনি বা লিড Owner Admin → Features খুলে দেখুন, কোন সারিতে "সবার জন্য চালু" কিন্তু "Play বন্ধ"। এমন সারি থাকলে সেটা এই তালিকায় যোগ হবে।

---

<a id="decl-guardbox_camera"></a>
## ১. CCTV গার্ড বক্স / ফোন-ক্যামেরা — স্ক্রিন বন্ধ রেখে পাহারা (`guardbox_camera`)

**কেন লাগে:** পুরনো ফোনকে দোকান বা বাড়ির পাহারাদার বানালে স্ক্রিন সারারাত খোলা রাখতে হয়। এতে ব্যাটারি আর স্ক্রিন দুটোরই ক্ষতি হয়। স্ক্রিন বন্ধ রেখে ক্যামেরা চালু রাখতে Android একটা নিয়ম চায়: ক্যামেরা-ধরনের foreground service (FGS), আর তার সাথে সবসময় দেখা যায় এমন নোটিফিকেশন।

**এখন কী অবস্থা:**
- এখন ফোন-ক্যামেরা চলে শুধু স্ক্রিন খোলা থাকলে (`keepScreenOn`)। তাই কোনো বিল্ডে camera FGS নেই।
- cctv-guardbox লেন এটা বানাচ্ছে। সুইচ বন্ধ থাকলে Play বিল্ড থেকে `FOREGROUND_SERVICE_CAMERA` আর camera-টাইপ সার্ভিস নিজে থেকেই বাদ যায়। অ্যাপ বুঝতে পারে `PLAY_CAMERA_FGS` দিয়ে।
- তখন Play-তে শুধু "স্ক্রিন খোলা রেখে পাহারা" দেখাবে, ভাঙা বোতাম দেখাবে না।
- **লেনের জন্য নোট:** গার্ড বক্স যদি Wi-Fi-র IP ক্যামেরা দেখে (ফোনের নিজের ক্যামেরা নয়), তাহলে টাইপ হবে **connectedDevice**, camera নয়। সেক্ষেত্রে লেন `ITEMS`-এ আরেকটা key যোগ করবে, আর এই অংশের লেখায় "Connected device" বসাবে।

**Policy:** Foreground service permissions — Camera (`FOREGROUND_SERVICE_CAMERA`)। সাথে User Data → Prominent disclosure, আর নজরদারি বা স্টকারওয়্যার নীতি (শুধু নিজের জায়গা, সবসময় নোটিফিকেশন)।

**Console (ক্লিক):**
1. play.google.com/console → **Assisto** → বাঁ মেনু **Policy and programs → App content**।
2. **Foreground service permissions** → **Manage**।
3. আগের **Microphone** আর **Location** যেমন আছে রাখুন। নতুন টিক দিন **Camera**।
4. Use case-এ যেটা সবচেয়ে কাছের সেটা বাছুন: "ongoing camera use started by the user" ধরনের। শুধু "Other" থাকলে সেটা বাছুন।
5. নিচের ইংরেজি লেখা পেস্ট করুন → ভিডিও লিংক দিন → **Save** → **Send changes for review**।

```
Assisto Home & Shop Watchman: the user turns their own old phone into a camera for their own shop or home. It starts only when the user taps "Start watching" on that phone after reading our disclosure. A camera-type foreground service keeps the camera on while the screen is off, so the old phone does not have to keep its screen lit all night. While it runs, Android's camera indicator and our ongoing notification "Assisto is watching this spot" with a Stop button are always visible. When something looks unusual, one still photo (and an encrypted short clip only the owner can open) is sent to the owner. It never records audio, never starts at boot or in the background by itself, and stops on Stop, low battery or when the user leaves the watch screen settings.
Impact if delayed or stopped: the shop or home is not watched while the screen is off; the user must keep the screen on all night.
```

**Video (≤৩০ সে):**
1. পুরনো ফোনে Assisto → মেনু → বাড়ি ও দোকানের পাহারাদার → "এই ফোনটিই ক্যামেরা"।
2. আমাদের ব্যাখ্যা-পাতা দেখান → "পাহারা শুরু"।
3. পাওয়ার বোতাম চাপুন (স্ক্রিন বন্ধ)। আবার খুলে নোটিফিকেশন নামান: "Assisto is watching" আর **Stop** দেখান।
4. হাত নাড়ুন। মালিকের ফোনে সতর্কতার ছবি এসেছে, দেখান।
5. নোটিফিকেশনের **Stop** চাপুন।

**Risk:**
- Google দুটো প্রশ্ন তুলতে পারে: "স্ক্রিন বন্ধে ক্যামেরা = লুকিয়ে নজরদারি?" আর "ক্যামেরা FGS শুধু ভিডিও-কলের মতো কাজে"।
- আমাদের উত্তর: শুধু নিজের ফোন আর নিজের জায়গা, ব্যবহারকারী নিজে চালু করেন, Android-এর সবুজ ক্যামেরা-চিহ্ন আর নোটিফিকেশন সবসময় থাকে, শব্দ ধরা হয় না।
- প্রত্যাখ্যান হলে লিড সুইচে `guardbox_camera` যোগ করবে না। Play-তে তখনো "স্ক্রিন খোলা রেখে" পাহারা পুরো চলবে। ফিচার লুকানো হবে না, শুধু স্ক্রিন বন্ধের সুবিধাটা থাকবে না।

**Switch:** `guardbox_camera` → `PLAY_CAMERA_FGS=true`।
- **কবে চালু:** cctv-guardbox লেন মার্জ হওয়ার পরে, আর আপনি ফর্ম জমা দেওয়ার পরে, পরের ইন্টিগ্রেশন বিল্ডে (b331 বা তার পরে)।
- **আগে দরকার:** অনুমতি-পাতায় `fgs_camera` এন্ট্রি (নিচে খসড়া আছে)।

<a id="decl-screen_share"></a>
## ৩. ভিডিও কলে স্ক্রিন শেয়ার (`screen_share`)

**কেন লাগে:** কলে বাবা-মাকে দেখানো যায় কোথায় চাপতে হবে। Android-এ এর জন্য "media projection" ধরনের FGS লাগে।

**পুরো ধাপ, ভিডিওর নিয়ম আর পেস্ট করার লেখা:** `owner_actions/SCREEN_SHARE_PLAY_BN.md` (এটাই চূড়ান্ত, এখানে আবার লেখা হয়নি, যাতে দুই জায়গায় দুই রকম না হয়)।

**Policy:** Foreground service permissions — Media projection (`FOREGROUND_SERVICE_MEDIA_PROJECTION`)।

**Console:** App content → Foreground service permissions → Manage → **Media projection** টিক → "user-initiated screen sharing" → লেখা পেস্ট + ভিডিও → Save → Send changes for review।

```
Paste the "Description" block from owner_actions/SCREEN_SHARE_PLAY_BN.md (step 4) exactly as it is.
```

**Video (≤৩০ সে):** SCREEN_SHARE_PLAY_BN.md ধাপ ২। ছোট রূপ: কল → "স্ক্রিন শেয়ার" → আমাদের শিট → Android-এর "Start now" → লাল বার আর নোটিফিকেশন → Stop।

**Risk:** কম। Google-এর তালিকায় "user-initiated screen sharing" হুবহু আছে। ভিডিওতে Android-এর সম্মতি-ডায়ালগ পরিষ্কার দেখা না গেলে Google বাতিল করতে পারে।

**Switch:** `screen_share`।
- এটা `PLAY_SCREEN_SHARE=true` export করে। circle-screenshare লেনের পুরনো সুইচও তাতে চালু হয়।
- **কবে চালু:** circle-screenshare লেন মার্জ হওয়ার পরে, আর আপনি ফর্ম জমা দেওয়ার পরে, পরের ইন্টিগ্রেশন বিল্ডে।
- **আগে দরকার:** অনুমতি-পাতায় `fgs_screen_share` এন্ট্রি (নিচে খসড়া আছে)।

<a id="decl-bg_location"></a>
## ৪. পরিবারের পৌঁছানোর খবর, অ্যাপ বন্ধ থাকলেও (`bg_location`)

**কেন লাগে:** "মা বাসায় পৌঁছেছেন" খবরটা পরিবার পায়, মাকে অ্যাপ খুলে রাখতে হয় না। এখন খবর আসে শুধু যাত্রা চালু থাকলে বা অ্যাপ খোলা থাকলে। বাকি সময় সৎভাবে ধূসর "খবর নেই" দেখায় (মালিকের ৯ Nov সিদ্ধান্ত)।

**দুই ধাপ (সৎভাবে):**
- **ধাপ A — নতুন অনুমতি লাগে না।**
  - `FamilyWatchService` (location FGS, আগে থেকেই বিল্ডে আছে) সদস্য নিজের ফোনে "রাজি" বলার পরে খোলা অ্যাপ থেকে চালু হয়।
  - Location FGS ঘোষণায় এই কাজটা যোগ করুন (নিচের লেখা)। তারপর Owner Admin → Features → `family_auto_arrival` → সবার জন্য + Play চালু করুন।
  - এটা কোড বদল ছাড়াই হয়।
- **ধাপ B — `ACCESS_BACKGROUND_LOCATION`, পরে।**
  - Android ১৪+-এ ফোন রিস্টার্টের পরে নিজে আবার চালু হতে এটা লাগে।
  - fcbrain লেনকে আগে "Allow all the time" চাওয়ার ধাপটা বানাতে হবে (disclosure আগে)। এখনো বানানো হয়নি।
  - তার আগে `bg_location` যোগ করবেন না।

**Policy:** ধাপ A: Foreground service permissions — Location। ধাপ B: **Location permissions** (background location), প্রতি ঘোষণায় একটাই ফিচার।

**Console (ক্লিক):**
- **ধাপ A:** App content → Foreground service permissions → Manage → **Location** (আগে থেকেই টিক) → বিবরণের শেষে নিচের প্রথম অনুচ্ছেদ যোগ করুন → নতুন ভিডিও লিংক → Save।
- **ধাপ B:** App content → **Sensitive app permissions → Location permissions** → Start → ফিচার: "Family arrival alerts" → নিচের দ্বিতীয় অনুচ্ছেদ → ভিডিও → Save → Send changes for review।

```
(A, add to the Location FGS description) Family Care arrival watch: a family member turns on "Tell my family when I arrive" on their own phone, after an in-app disclosure. A location foreground service with an ongoing "Arrival watch is on" notification (Stop button) checks the member's own saved places (home, school, office) and tells the family when they arrive or leave. It is started only from the open app by the member and stops when they switch it off.

(B, Location permissions form) Assisto uses background location only for Family arrival alerts: after the family member turns on "Tell my family when I arrive" and allows "Allow all the time", Assisto tells the family members they chose when they arrive at or leave their own saved places, even when Assisto is closed. A prominent in-app disclosure is shown before Android's permission dialog. The member can turn it off at any time in the app or in Android settings. Location is not used for ads and is not sold.
```

**Video (≤৩০ সে):**
1. সদস্যের ফোনে Assisto → আমার পরিবার → "পৌঁছালে পরিবারকে জানাও" → আমাদের ব্যাখ্যা-পাতা → রাজি।
2. (ধাপ B-তে) Android-এর "Allow all the time" ডায়ালগ দেখান।
3. নোটিফিকেশন "Arrival watch is on" দেখান → অ্যাপ বন্ধ করুন।
4. (`adb geo fix` বা হেঁটে) বাসার কাছে আসুন। অন্য ফোনে "পৌঁছেছেন" খবর দেখান।
5. Stop চাপুন।

**Risk:**
- Google background location খুব কড়া দেখে।
- "পরিবারের লোকেশন" অনেক সময় স্টকারওয়্যার সন্দেহে পড়ে। আমাদের উত্তর: সদস্য নিজের ফোনে রাজি হন, সবসময় নোটিফিকেশন থাকে, যেকোনো সময় বন্ধ করা যায়।
- ধাপ B প্রত্যাখ্যান হলে ধাপ A চলতেই থাকবে।

**Switch:**
- ধাপ A = সার্ভার সুইচ `family_auto_arrival` (Owner Admin)।
- ধাপ B = `bg_location` → Play ম্যানিফেস্টে `ACCESS_BACKGROUND_LOCATION` যোগ হয়, অ্যাপ বুঝতে পারে `PLAY_BG_LOCATION` দিয়ে।
- **কবে চালু:** ধাপ A আপনার ফর্ম জমার পরে, কোনো বিল্ড লাগে না। ধাপ B fcbrain-এর অনুরোধ-ধাপ মার্জ হওয়ার পরে, আর আপনি ফর্ম জমা দেওয়ার পরে, পরের ইন্টিগ্রেশন বিল্ডে।
- **ধাপ B-র আগে দরকার:** অনুমতি-পাতায় `bg_location` এন্ট্রি।

<a id="decl-medical"></a>
## ৫. ওষুধ, প্রেসক্রিপশন, স্বাস্থ্য-টাইমলাইন (`medical`)

**কেন লুকানো:** ২৪ Oct Google বলেছে, ব্যক্তিগত (personal) ডেভেলপার অ্যাকাউন্ট থেকে "Medication and treatment management" প্রকাশ করা যায় না। কোড পুরোটাই আছে, Play-তে শুধু ঢোকার পথগুলো বন্ধ (`kMedicalFeaturesAllowed`)।

**Policy:** Health apps declaration (Medication and treatment management)। এর জন্য **Organization অ্যাকাউন্ট** লাগে (D-U-N-S, Google Play-র জন্য বিনামূল্যে)।

**Console (ক্লিক):**
1. আগে `PLAY_ORGANIZATION_ACCOUNT_BN.md`-এর সব ধাপ শেষ করুন।
2. তারপর App content → **Health apps** → Manage। আগের চারটা টিক রাখুন, নতুন টিক দিন **Medication and treatment management**।
3. লেখা পেস্ট করুন → Save → Send changes for review।
4. Data safety → Health info → "Collected" নিশ্চিত করুন (ওষুধের নাম ও সময়, শুধু ব্যবহারকারীর নিজের দেওয়া তথ্য)।

```
Assisto's medicine reminders help the user and their family remember the user's own medicines: the user (or a family member they invited) types the medicine name and times, and Assisto reminds them and records "taken / missed". A photo of a prescription can be read on request to fill the list. Assisto does not diagnose, does not recommend medicines or doses, and is not a medical device; every medicine screen says "This is not medical advice. Talk to a doctor." Data stays in the user's account, is never sold or used for ads, and can be deleted any time.
```

**Video (≤৩০ সে):** দরকার হয় না (Health apps ফর্মে ভিডিও চায় না)। রিভিউয়ার চাইলে দেখান: ওষুধ যোগ → রিমাইন্ডার বাজে → "খেয়েছি" → "চিকিৎসা-পরামর্শ নয়" লাইন।

**Risk:** organization যাচাই কয়েক দিন থেকে প্রায় ৩০ কর্মদিবস লাগতে পারে। কাগজে নাম না মিললে যাচাই আটকে যায়।

**Switch:** `medical` → Play AAB বানানো হয় `PLAY_MEDICAL=true` দিয়ে।
- অ্যাপ সার্ভারে `X-Assisto-Medical: 1` পাঠায়, সার্ভার ওষুধের পরামর্শ আবার দেখায় (`play_medical_hidden`)।
- **কবে চালু:** organization অ্যাকাউন্ট আর Health apps অনুমোদনের পরে, পরের ইন্টিগ্রেশন বিল্ডে।

---

<a id="inplay-fullscreen"></a>
## ২. লক স্ক্রিনে পুরো পর্দা — কল, কেয়ার কল, অ্যালার্ম (Play-তে আছে, ঘোষণা হালনাগাদ করুন)

**কী পাওয়া গেছে (এই অডিট):** কোডে full-screen intent চারটা জায়গায় ব্যবহার হয়:
1. My Circle কল (`push_notifier.dart`, `IncomingCall.kt`)।
2. কেয়ার কল (`carecall_alarms.dart`)।
3. গন্তব্য অ্যালার্ম (`dest_alarm_fullscreen.dart`, ধরন alarm)।
4. সাইলেন্ট ওয়াচের "আপনি ঠিক আছেন?" (`SilentWatch.kt`, ধরন alarm)।

কিন্তু `PLAY_FGS_DECLARATION_BN.md` §৩ বলে "শুধু Calling বাছুন, Alarm নয়", আর অনুমতি-পাতা (`legal_content.py`, id `fullscreen`) বলে "কল ও পরিবারের SOS"। তিনটা কথা এক নয়। **ঠিক করা উত্তর:** Calling **আর** Alarm দুটোই।

**Console (ক্লিক):** App content → **Full-screen intent** → Manage → core functionality: **Calling** টিক, আর **Alarm** টিক → লেখা পেস্ট করুন → Save → Send changes for review।

```
Assisto uses full-screen intents only for time-critical, user-expected alerts: (1) incoming My Circle voice and video calls and Care Calls (a family member's scheduled reminder call), shown as an incoming-call screen, also on the lock screen; (2) alarms the user set: the destination alarm on a bus or train journey ("your stop is next") and the Silent Watch "Are you OK?" safety check that the user turned on. Full-screen intents are never used for ads, promotions, chat messages or any other notification. Without the permission these alerts still ring as high-priority notifications.
```

**Video:** দরকার হয় না।

**Risk:** Alarm বাতিল হলে শুধু Calling থাকে। তখন গন্তব্য অ্যালার্ম আর "ঠিক আছেন?" সাধারণ জরুরি নোটিফিকেশন হিসেবে বাজে (Android নিজে এটা করে)। ফিচার হারায় না।

**অনুমতি-পাতার লেখা:** `fullscreen` এন্ট্রিতে "পরিবারের SOS" আছে, কিন্তু SOS কোডে full-screen দেখায় না। গন্তব্য অ্যালার্ম আর "ঠিক আছেন?" এন্ট্রিতে নেই। নিচের খসড়া দিয়ে বদলানো দরকার (privacy পাতা, তাই আগে আপনার প্রিভিউ)।

<a id="inplay-others"></a>
## ৬–৯. যা আগে থেকেই Play-তে আছে, বা কোনো বিল্ডেই নেই

- **মাইক্রোফোন FGS** (ভয়েস SOS, কল চলার সময়, "Hey Assisto"): ঘোষিত।
  - লেখা আর ভিডিও: `PLAY_FGS_DECLARATION_BN.md` §১ আর `WAKE_WORD_PLAY_BN.md`। Console-এ দেখে নিন "Hey Assisto" যোগ আছে কিনা।
- **লোকেশন FGS** (নিরাপদ যাত্রা, ট্রেন, গন্তব্য অ্যালার্ম, চুরি-রোধ): ঘোষিত (`PLAY_FGS_DECLARATION_BN.md` §২)। পরিবারের পৌঁছানোর খবর উপরে §৪ ধাপ A-তে।
- **Device admin** (চুরি-রোধ: দূর থেকে লক, ভুল আনলকের হিসাব): Play-তে আছে। আলাদা ফর্ম নেই।
  - রিভিউয়ার জিজ্ঞেস করলে উত্তর: `ANTITHEFT_PLAY_DECLARATION_BN.md` §১।
- **নোটিফিকেশন অ্যাক্সেস** (কলের পরে নোট, ওয়ালেট বা ব্যাংকের নোটিফিকেশন থেকে টাকা): Play-তে আছে, আলাদা ফর্ম নেই।
  - Data safety আর রিভিউ-নোট: `CALL_NOTE_MONEY_PLAY_BN.md`।
  - রিভিউয়ার আপত্তি করলে Owner Admin → `money_notif_sms` বন্ধ করুন (মিনিটের মধ্যে কাজ করে)।
- **SMS:** কোনো SMS অনুমতি নেই। SOS নিজের SMS অ্যাপ খোলে, বার্তা আগে থেকে লেখা থাকে, ব্যবহারকারী Send চাপেন।
- **Accessibility, Activity recognition:** কোনো ফিচার এগুলো ব্যবহার করে না। CI দুটোকেই আটকে রাখে। কিছু জমা দেবেন না।

## অনুমতি-পাতার নতুন এন্ট্রি (খসড়া — সুইচ চালুর আগে `backend/web/legal_content.py`-এ যোগ হবে, আপনার প্রিভিউয়ের পরে)

- `fgs_camera` — "Camera in the background (Home & Shop Watchman)": the old phone you chose keeps watching your own shop or home with the screen off, only after you tap Start watching; a notification with Stop is always shown; no sound is recorded. Off: tap Stop, or switch the watchman off.
- `fgs_screen_share` — "Screen sharing in a call": only after you tap Share screen in a My Circle video call and accept Android's dialog; only the person in the call sees it; nothing is recorded. Off: tap Stop, or end the call.
- `bg_location` — "Location all the time (Family arrival alerts)": only after you turn on "Tell my family when I arrive" and choose Allow all the time; used only for arrival and leave news at your own saved places. Off: switch it off in the app, or set location to "Only while using the app".
- `fullscreen` (বদল) — "Full-screen alerts (calls, Care Call, destination alarm, Are you OK? check)".

`core.tests_play_declared` পাহারা দেয়: কোনো সুইচ চালু করলে তার এন্ট্রি অনুমতি-পাতায় না থাকলে CI ফেল করে।
