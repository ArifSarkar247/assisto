# Play Console — স্বাস্থ্য ও ফিটনেস ঘোষণা (Health apps, Health Connect, Data safety)

**তারিখ:** ২৭ Oct ২০২৬ · **মালিকের সিদ্ধান্ত:** স্বাস্থ্য ও ফিটনেস ফিচার লুকানো হবে না; শুধু ওষুধ লুকানো থাকবে।
এই ফাইলে Play Console-এ বসানোর **হুবহু ইংরেজি উত্তর** (কপি করে পেস্ট করুন) আর প্রতিটির **বাংলা কারণ** আছে।
**Play Console, ফ্ল্যাগ বা লাইভ সার্ভারে কিছুই বদলানো হয়নি** — এগুলো আপনি নিজে বসাবেন।

Play-তে যে চারটি ফিচার দেখানো থাকবে (Health and Fitness হিসেবে, কখনো চিকিৎসা নয়):

| ফিচার (অ্যাপে নাম) | ফ্ল্যাগ | কী করে |
|---|---|---|
| পানি, ঘুম ও খাবার | `wellness` | দিনে কত গ্লাস পানি, কত ঘণ্টা ঘুম, খাবারের নোট — নিজের লক্ষ্য ও ৭ দিনের চার্ট |
| ফিটনেস সঙ্গী | `fitness` | একটি ছোট লক্ষ্য (সপ্তাহে ব্যায়ামের দিন / দৈনিক পদক্ষেপ / ওজনের লক্ষ্য), ব্যায়ামের লগ |
| স্মার্টওয়াচ ও ফিটনেস | `smartwatch` | Health Connect থেকে শুধু **পড়া**: পদক্ষেপ, হার্ট রেট, ঘুম, সক্রিয় ক্যালরি — ফোনেই থাকে |
| মন ও প্রাণশক্তির ডায়েরি | `voice_mood` | দিনে একবার মন ও প্রাণশক্তি লেখা, ছোট নোট, এক মিনিটের শ্বাস-বিরতি — শুধু ফোনে থাকে |

অ্যাপে যা বদলানো হয়েছে (এই কাজে): চারটি স্ক্রিনের নিচে সবসময় দেখা যায় এমন লাইন —
"এটি চিকিৎসা-পরামর্শ নয়। স্বাস্থ্য নিয়ে চিন্তা থাকলে ডাক্তারের সাথে কথা বলুন।" / "This is not medical advice. Talk to a doctor about any health concern."
মন-এর স্ক্রিন এখন "মন ও প্রাণশক্তির ডায়েরি" — মানসিক-স্বাস্থ্য হেল্পলাইনের বদলে শুধু একটি নিরাপত্তা লাইন: "কখনো নিজেকে অনিরাপদ মনে হলে ৯৯৯-এ কল করুন।"
AI-র প্রতিটি উত্তরে নিয়ম: চিকিৎসা-পরামর্শ, রোগ নির্ণয়, চিকিৎসা/থেরাপি বা ওষুধের মাত্রা নয়; স্বাস্থ্য নিয়ে চিন্তায় ডাক্তার দেখাতে বলা; বিপদে ৯৯৯।
`ACTIVITY_RECOGNITION` অনুমতি বাদ দেওয়া হয়েছে (দরকার ছিল না)।

---

## ১. Health apps declaration (Policy → App content → Health apps)

**কোথায়:** Play Console → আপনার অ্যাপ → Policy → **App content** → **Health apps** → Start / Manage.

### ✅ টিক দিন — এই চারটি (Health and fitness দলে)

| Play-এর ঘর | টিক | কেন (বাংলা) |
|---|---|---|
| **Activity and fitness** | ✅ | ফিটনেস সঙ্গী (ব্যায়ামের লগ, পদক্ষেপ) আর স্মার্টওয়াচ স্ক্রিন (Health Connect-এর পদক্ষেপ, হার্ট রেট, সক্রিয় ক্যালরি)। |
| **Nutrition and weight management** | ✅ | পানি ও খাবারের নোট, আর ফিটনেসে ওজনের লক্ষ্য। |
| **Sleep management** | ✅ | ঘুমের ঘণ্টা লেখা (পানি-ঘুম-খাবার) আর Health Connect থেকে ঘুম দেখা। |
| **Stress management** (ফর্মে নাম হতে পারে "Stress management, relaxation, mental acuity") | ✅ | মন ও প্রাণশক্তির ডায়েরি — নিজের মন লিখে রাখা ও এক মিনিটের শ্বাস-বিরতি। শুধু বিশ্রাম, কোনো চিকিৎসা নয়। |

### ❌ টিক দেবেন না — কখনো

| Play-এর ঘর | কেন টিক নয় |
|---|---|
| **Medication and treatment management** | ওষুধের ফিচার Play বিল্ডে লুকানো (`kMedicalFeaturesAllowed = false`)। ব্যক্তিগত অ্যাকাউন্টে এটি ২৪ Oct বাতিল হয়েছিল; প্রতিষ্ঠান-অ্যাকাউন্টের আগে নয়। |
| **Mental and behavioral health** | ডায়েরিটি কোনো মানসিক-স্বাস্থ্য সেবা, থেরাপি বা কাউন্সেলিং নয়; অনুভূতির নাম দেয় না, বিচার করে না। টিক দিলে "চিকিৎসা-ধরনের" অ্যাপ ধরা হবে। |
| **Medical devices** / Medical device software | অ্যাপ কিছু মাপে না বা নির্ণয় করে না; হার্ট রেট শুধু ঘড়ির পাঠানো সংখ্যা দেখায়। |
| **Clinical decision support**, **Diseases and conditions management**, **Healthcare services and management**, **Medical reference and education**, **Physical therapy and rehabilitation**, **Reproductive and sexual health**, **Period tracking**, **Health research**, এবং অন্য যেকোনো "medical / clinical" ঘর | এগুলোর কোনো ফিচার Play বিল্ডে নেই। |

> ফর্মে ঘরের নাম একটু অন্যরকম লেখা থাকতে পারে (Google মাঝে মাঝে নাম বদলায়)। নিয়ম একটাই: **শুধু উপরের চারটি "health and fitness" ধরনের ঘর; "medical / clinical / treatment / mental health" শব্দ থাকা কোনো ঘরে টিক নয়।**

যদি ফর্ম বিবরণ চায় (ইংরেজিতে পেস্ট করুন):
```
Assisto offers simple health and fitness tracking only: a water, sleep and food log with the user's own goals; a fitness partner (workout log, daily steps, weight goal); a read-only view of steps, heart rate, sleep and active calories from Health Connect; and a private mood and energy journal with a one-minute breathing exercise for relaxation. The app does not diagnose, treat or manage any disease or condition, gives no medical advice, and is not a medical device or a mental health service. Every one of these screens shows: "This is not medical advice. Talk to a doctor about any health concern." Medicine features are not available in the Google Play version.
```

---

## ২. Health Connect permissions — প্রতিটি অনুমতির কারণ (পেস্ট করার জন্য)

**কোথায়:** App content → **Health apps** ফর্মের Health Connect অংশ (বা আলাদা "Health Connect permissions" ফর্ম, যেটা Console দেখায়)।
অ্যাপ ঠিক এই **চারটি** Health Connect অনুমতি চায়, সবই **শুধু পড়া (READ)** — কোনো WRITE নেই:

| অনুমতি | কোন স্ক্রিন ব্যবহার করে |
|---|---|
| `android.permission.health.READ_STEPS` | স্মার্টওয়াচ ও ফিটনেস — আজকের পদক্ষেপ ও ৭/৩০/৯০ দিনের চার্ট |
| `android.permission.health.READ_HEART_RATE` | স্মার্টওয়াচ ও ফিটনেস — আজকের সর্বশেষ হার্ট রেট |
| `android.permission.health.READ_SLEEP` | স্মার্টওয়াচ ও ফিটনেস — গত রাতের ঘুমের ঘণ্টা |
| `android.permission.health.READ_ACTIVE_CALORIES_BURNED` | স্মার্টওয়াচ ও ফিটনেস — আজকের সক্রিয় ক্যালরি |

**বাদ দেওয়া হয়েছে:** `ACTIVITY_RECOGNITION` (Health Connect থেকে পড়তে লাগে না; কোনো স্ক্রিন ফোনের নিজের স্টেপ-সেন্সর ব্যবহার করে না)।
CI ম্যানিফেস্টে এখন `tools:node="remove"` দিয়ে সেটি সরানো, যাতে কোনো প্লাগিন ফিরিয়ে আনতে না পারে।
টেস্ট `app/test/healthfit_policy_test.dart` পরীক্ষা করে যে ম্যানিফেস্টে ঠিক এই চারটিই আছে এবং স্ক্রিন ঠিক এই চার ধরনের ডেটা পড়ে।

**READ_STEPS**
```
Assisto reads step counts from Health Connect only to show the user their own steps today and a 7, 30 or 90-day steps chart on the "Smartwatch and fitness" screen, after the user taps Connect. The data is read-only, is shown on the user's phone only, is not uploaded to our servers, and is never sold, shared with third parties or used for advertising, ads profiles, credit or insurance decisions. The user can revoke access at any time in Health Connect.
```

**READ_HEART_RATE**
```
Assisto reads heart rate samples from Health Connect only to show the user the latest heart rate their own watch or fitness band recorded today, on the "Smartwatch and fitness" screen, after the user taps Connect. It is a display of the user's own data for fitness purposes; the app makes no medical interpretation or diagnosis. The data is read-only, stays on the phone, is not uploaded to our servers, and is never sold, shared or used for advertising. The user can revoke access at any time in Health Connect.
```

**READ_SLEEP**
```
Assisto reads sleep sessions from Health Connect only to show the user how many hours they slept, on the "Smartwatch and fitness" screen, after the user taps Connect. The data is read-only, stays on the phone, is not uploaded to our servers, and is never sold, shared or used for advertising. The user can revoke access at any time in Health Connect.
```

**READ_ACTIVE_CALORIES_BURNED**
```
Assisto reads active calories burned from Health Connect only to show the user today's active energy from their own watch or fitness band, on the "Smartwatch and fitness" screen, after the user taps Connect. The data is read-only, stays on the phone, is not uploaded to our servers, and is never sold, shared or used for advertising. The user can revoke access at any time in Health Connect.
```

ফর্ম যদি সাধারণ প্রশ্ন করে:
- *Does your app write data to Health Connect?* → **No**
- *Does your app read data in the background?* → **No** (শুধু স্ক্রিন খোলা থাকলে)
- *Does your app read historical data (older than 30 days)?* → **No** (`READ_HEALTH_DATA_HISTORY` চাওয়া হয় না; ৯০ দিনের চার্টে Health Connect যতটুকু দেয় ততটুকুই)
- *Privacy policy URL:* `https://lifeassisto.com/privacy` (এতে "Health and fitness features" অংশ আছে, `#health_fitness`)
- *In-app rationale:* অ্যাপে আছে — Health Connect-এর "privacy policy" লিংক চাপলে Assisto-র গোপনীয়তা নীতি খোলে (`ACTION_SHOW_PERMISSIONS_RATIONALE` + `VIEW_PERMISSION_USAGE`, CI ম্যানিফেস্টে)।

---

## ৩. Data safety — "Health and fitness" ঘরের উত্তর

**কোথায়:** App content → **Data safety** → Data types → **Health and fitness**।

| Play-এর ডেটা টাইপ | Collected? | Shared? | Processed ephemerally? | Required or optional? | Purposes |
|---|---|---|---|---|---|
| **Fitness info** | **Yes** | **No** | No | **Optional** | **App functionality** |
| **Health info** | **Yes** | **No** | No | **Optional** | **App functionality** |

কেন এভাবে (বাংলা):
- **Fitness info = Yes:** ব্যবহারকারী নিজে যে ব্যায়ামের লগ (ধরন, মিনিট, পদক্ষেপ, ঐচ্ছিক ক্যালরি) আর ওজনের লক্ষ্য লেখেন, তা আমাদের সার্ভারে তাঁর অ্যাকাউন্টে থাকে (অন্য ফোনেও দেখতে)। তাই "collected"।
- **Health info = Yes (সাবধানী উত্তর):** পানি, ঘুমের ঘণ্টা ও খাবারের নোটও সার্ভারে থাকে। Google এগুলো কোন ঘরে চায় তা পুরো স্পষ্ট নয়; কম ঘোষণা করার চেয়ে বেশি ঘোষণা করা নিরাপদ, তাই Yes।
- **Shared = No:** কারও সাথে শেয়ার হয় না, বিক্রি হয় না, বিজ্ঞাপনে যায় না।
- **Optional:** এই ফিচার না খুললে কিছুই নেওয়া হয় না।
- **Purpose = শুধু App functionality** — Analytics, Advertising, Personalization, Developer communications **টিক নয়**।
- **Health Connect-এর ডেটা ও মন-প্রাণশক্তির ডায়েরি "collected" নয়:** এগুলো ফোন থেকে কখনো বের হয় না। Google-এর নিয়মে শুধু ফোনে প্রক্রিয়া হওয়া ডেটা ঘোষণা করতে হয় না।
- এনক্রিপশন (in transit) = Yes; মুছে ফেলার উপায় = Yes (প্রতিটি লগ মুছুন, অ্যাকাউন্ট মুছুন, lifeassisto.com/delete-account) — সাধারণ উত্তর আগের মতোই।

---

## ৪. গোপনীয়তা নীতির নতুন অংশ (যোগ করা হয়েছে)

- **ওয়েবসাইট** (`backend/web/legal_content.py`, পাতা `https://lifeassisto.com/privacy`, অংশ `#health_fitness`) — নতুন অংশ "স্বাস্থ্য ও ফিটনেস ফিচার / Health and fitness features"; "আমরা কী তথ্য রাখি"-তে পানি/ঘুম/খাবার/ফিটনেস লগ; "যা আপনার ফোনেই থাকে"-তে মনের ডায়েরি; অনুমতি টেবিলে Health Connect-এর চারটি অনুমতি (ACTIVITY_RECOGNITION বাদ)। তারিখ ২৭ Oct।
- **অ্যাপের ভেতরের নীতি** (`backend/core/legal.py`) — গোপনীয়তা নীতিতে "স্বাস্থ্য ও ফিটনেস" অংশ, স্বাস্থ্য দাবিত্যাগে ফিটনেস ও ৯৯৯ লাইন, ডেটা-নিরাপত্তা সারসংক্ষেপে "Health and fitness (optional)"।
- **লাইভ হবে কখন:** ব্যাকএন্ড ডিপ্লয় হলে (এই কাজে ডিপ্লয় করা হয়নি)। Play ফর্ম জমা দেওয়ার **আগে** ডিপ্লয় করে `lifeassisto.com/privacy#health_fitness` খুলে দেখুন।

ইংরেজি অংশ (ওয়েবসাইটে যা আছে):
```
Health and fitness features
Water, sleep and food, Fitness partner, Smartwatch and fitness, and the Mood and energy journal are self-care and habit-tracking tools only. This is not medical advice. Assisto does not identify any illness and does not suggest treatment or medicine; talk to a doctor about any health concern. The Mood and energy journal is only for noting how you feel and for relaxation (a breathing exercise); it is not a counselling service. If you ever feel unsafe, call 999.
• Health Connect: if you allow it, we only read steps, heart rate, sleep and active calories and show them on the Smartwatch and fitness screen. This data stays on your phone: it is not sent to our server, and we never write to Health Connect.
• Water/sleep/food/fitness logs you enter are kept on our server in your account so you can see them on another phone; only you can see them. The Mood and energy journal stays only on this phone.
• We never sell health and fitness data, never use it for ads or advertising profiles, never use it to decide credit or insurance eligibility, and never share it with anyone. Use of information received from Health Connect follows the Health Connect Permissions policy, including its Limited Use requirements.
• Delete any time: delete logs on each screen, use "Delete all data" in the Mood and energy journal, revoke access in the Health Connect app, or delete your whole account.
```

বাংলা অংশ:
```
স্বাস্থ্য ও ফিটনেস ফিচার
পানি-ঘুম-খাবার, ফিটনেস সঙ্গী, স্মার্টওয়াচ ও ফিটনেস এবং মন ও প্রাণশক্তির ডায়েরি — এগুলো শুধু নিজের যত্ন ও অভ্যাসের হিসাব রাখার টুল। এটি চিকিৎসা-পরামর্শ নয়। Assisto কোনো রোগ চেনে না, চিকিৎসা বা ওষুধের কথা বলে না; স্বাস্থ্য নিয়ে চিন্তা থাকলে ডাক্তারের সাথে কথা বলুন। মন ও প্রাণশক্তির ডায়েরি শুধু নিজের অনুভূতি লিখে রাখা ও বিশ্রামের (শ্বাসের ব্যায়াম) জন্য; এটি কোনো কাউন্সেলিং সেবা নয়। কখনো নিজেকে অনিরাপদ মনে হলে ৯৯৯-এ কল করুন।
• Health Connect: আপনি অনুমতি দিলে আমরা শুধু পড়ি — পদক্ষেপ, হার্ট রেট, ঘুম ও সক্রিয় ক্যালরি — এবং স্মার্টওয়াচ ও ফিটনেস স্ক্রিনে দেখাই। এই ডেটা ফোনেই থাকে: আমাদের সার্ভারে যায় না, আমরা Health Connect-এ কিছু লিখি না।
• আপনার লেখা পানি/ঘুম/খাবার/ফিটনেস লগ আমাদের সার্ভারে আপনার অ্যাকাউন্টে থাকে, যাতে অন্য ফোনেও দেখতে পান; দেখেন শুধু আপনি। মন ও প্রাণশক্তির ডায়েরি শুধু এই ফোনে থাকে।
• স্বাস্থ্য ও ফিটনেসের কোনো তথ্য আমরা বিক্রি করি না, বিজ্ঞাপনে বা বিজ্ঞাপনের প্রোফাইলে ব্যবহার করি না, ঋণ বা বিমার যোগ্যতা যাচাইয়ে ব্যবহার করি না, এবং কারও সাথে শেয়ার করি না। Health Connect থেকে পাওয়া তথ্যের ব্যবহার Health Connect-এর অনুমতি নীতির (Limited Use) শর্ত মেনে চলে।
• যেকোনো সময় মুছতে পারেন: প্রতিটি স্ক্রিনে লগ মুছুন, মন ও প্রাণশক্তির ডায়েরিতে "সব তথ্য মুছুন", Health Connect অ্যাপ থেকে অনুমতি তুলে নিন, অথবা পুরো অ্যাকাউন্ট মুছে ফেলুন।
```

---

## ৫. স্টোর লিস্টিং-এর লাইন (Case B-তে বসানো হয়েছে)

`owner_actions/PLAY_LISTING_FIXED.md` → **Case B** (এখন ব্যবহার করুন) ও Case A — দুই জায়গাতেই "FITNESS AND SELF-CARE / ফিটনেস ও নিজের যত্ন" অংশ যোগ হয়েছে, "DOCUMENTS AND PHOTO STUDIO"-র ঠিক আগে। আগের "Fitness" ঐচ্ছিক লাইনটি সরানো হয়েছে (এখন মূল লেখায়)। ওষুধ আগের মতোই বাইরে। নতুন অক্ষর-সংখ্যা: Case B en 3282, bn 3115 (৪০০০-এর মধ্যে)।

```
FITNESS AND SELF-CARE
• Water, sleep and food: log glasses of water, hours of sleep and what you ate, with your own goals and a 7-day chart.
• Fitness partner: one small goal (workout days, daily steps or a weight goal), a workout log and streaks.
• Smartwatch and fitness: see steps, heart rate, sleep and active calories from Health Connect - read-only, kept on your phone.
• Mood and energy journal: a private daily check-in with a short note and a one-minute breathing break - it stays on your phone.
• This is not medical advice. Talk to a doctor about any health concern.
```
```
ফিটনেস ও নিজের যত্ন
• পানি, ঘুম ও খাবার: কত গ্লাস পানি, কত ঘণ্টা ঘুম আর কী খেলেন লিখে রাখুন — নিজের লক্ষ্য ও ৭ দিনের চার্টসহ।
• ফিটনেস সঙ্গী: ছোট একটি লক্ষ্য (সপ্তাহে ব্যায়ামের দিন, দৈনিক পদক্ষেপ বা ওজনের লক্ষ্য), ব্যায়ামের লগ ও টানা দিনের হিসাব।
• স্মার্টওয়াচ ও ফিটনেস: Health Connect থেকে পদক্ষেপ, হার্ট রেট, ঘুম ও সক্রিয় ক্যালরি দেখুন — শুধু পড়া, তথ্য ফোনেই থাকে।
• মন ও প্রাণশক্তির ডায়েরি: দিনে একবার মন ও প্রাণশক্তি লিখে রাখা, ছোট নোট আর এক মিনিটের শ্বাস-বিরতি — সব ফোনেই থাকে।
• এটি চিকিৎসা-পরামর্শ নয়। স্বাস্থ্য নিয়ে চিন্তা থাকলে ডাক্তারের সাথে কথা বলুন।
```

লিস্টিং-এ কখনো লিখবেন না: diagnose, treatment, therapy, cure, dose, disease, clinical, doctor-approved, mental health, depression, anxiety, stress cure; বাংলায় রোগ নির্ণয়, চিকিৎসা (শুধু "চিকিৎসা-পরামর্শ নয়" লাইনে চলবে), থেরাপি, ডোজ, মানসিক স্বাস্থ্য, বিষণ্ণতা, উদ্বেগ, নিরাময়। স্ক্রিনশটেও এই শব্দ যেন না থাকে।

---

## ৬. কোন ক্রমে বসাবেন (closed testing বিল্ডের আগে)

1. ব্যাকএন্ড ডিপ্লয় (গোপনীয়তা নীতির নতুন অংশ লাইভ) → `lifeassisto.com/privacy#health_fitness` খুলে দেখুন।
2. App content → **Health apps**: §১-এর চারটি টিক, বাকি কোনোটা নয় → Save।
3. Health Connect অংশ: §২-এর চারটি কারণ পেস্ট → Save।
4. **Data safety**: §৩ অনুযায়ী Fitness info + Health info → Save → Submit।
5. Store listing: `PLAY_LISTING_FIXED.md` Case B পেস্ট (en-US ও bn-BD)।
6. পরের closed testing বিল্ড (এই কাজসহ) আপলোড করে review-এ পাঠান।

---

## ৭. Google বাতিল করলে কী করবেন

**ইমেইল কীভাবে পড়বেন:** Google-এর ইমেইলের বিষয় সাধারণত "Action Required: Your app is not compliant with Google Play Policies" বা "App update rejected"। ভেতরে দেখুন:
- **Policy name / "Issue found"** — যেমন "Health apps declaration", "Health Connect permissions", "Misleading Claims", "Health Misinformation", "Medical functionality"।
- **"Issue details"** অনুচ্ছেদ — এখানে কোন ফিচার, কোন অনুমতি বা কোন লেখা সমস্যা তা লেখা থাকে (যেমন "your app requests READ_HEART_RATE but…", "store listing contains medical claims…")।
- **Affected version code(s)** আর কখনো কখনো একটি স্ক্রিনশট।
- Play Console → **Policy and programs → Policy status** পাতায় একই তথ্য আরও বিস্তারিত থাকে।

**আমাকে যা পাঠাবেন (হুবহু কপি করে):**
1. ইমেইলের বিষয় (subject) লাইন।
2. "Issue found" / policy-র নাম।
3. পুরো "Issue details" অনুচ্ছেদ (ইংরেজিতেই, এক অক্ষরও না বদলে)।
4. Version code (যেমন 1.0.150)।
5. ইমেইলে বা Policy status পাতায় স্ক্রিনশট থাকলে সেটি।

**পরিকল্পনা — শুধু বাতিল হওয়া অংশ লুকানো (বাকি সব দেখানো থাকবে):**

| বাতিলের লেখায় যা আছে | শুধু এটি লুকাব (Play-তে) | বাকি থাকবে |
|---|---|---|
| Heart rate / `READ_HEART_RATE` | স্মার্টওয়াচ স্ক্রিন থেকে হার্ট রেট বাদ + ম্যানিফেস্ট থেকে ওই একটি অনুমতি বাদ | পদক্ষেপ, ঘুম, ক্যালরি |
| Health Connect পুরো (যেকোনো অনুমতি / declaration) | `smartwatch` Play-তে বন্ধ + Play AAB থেকে চারটি Health Connect অনুমতি বাদ | পানি-ঘুম-খাবার, ফিটনেস, মন |
| Mood / "mental health" / Stress management | `voice_mood` Play-তে বন্ধ | বাকি তিনটি |
| Sleep management | ঘুমের অংশ (পানি-ঘুম-খাবার ও স্মার্টওয়াচ থেকে ঘুম) | পানি, খাবার, ফিটনেস |
| Nutrition / weight | ফিটনেসের ওজনের লক্ষ্য ও খাবারের নোট | পানি, ঘুম, পদক্ষেপ, ব্যায়াম |
| Store listing-এর কোনো লেখা ("misleading / medical claim") | শুধু সেই লাইন বদলাব — কোনো ফিচার লুকানো নয় | সব |
| Declaration-এ ভুল ঘর / তথ্য অমিল | ফর্ম ঠিক করব — কোনো ফিচার লুকানো নয় | সব |

ফ্ল্যাগ বন্ধ করা হয় Owner Admin → Features থেকে "Play-তে লুকান" দিয়ে (APK ওয়েবসাইট বিল্ডে সব থাকে)। অনুমতি বাদ দিতে হলে CI-র Play AAB ধাপে একটি `tools:node="remove"` লাইন লাগে — নতুন বিল্ড লাগবে। ঠিক করে আবার জমা দেওয়ার সময় Play Console-এ "Appeal" নয়, নতুন বিল্ড + ঠিক করা ফর্ম পাঠানোই দ্রুত।
