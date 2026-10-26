# CCTV ওয়াচম্যান — Google Play ঘোষণা (ফেজ ১)

**অবস্থা:** ফিচারটি সার্ভার-ফ্ল্যাগ `cctv_watchman`-এর পেছনে; Play-সংস্করণে ডিফল্ট **লুকানো** (Owner Admin → Features → cctv_watchman → "Play" বন্ধ)। ৯/৯ DoD পাস ও নিচের ঘোষণা হালনাগাদ হলে তবেই Play-তে চালু করবেন। **৮ নভেম্বরের প্রোডাকশন আবেদন এতে আটকাবে না।**

## ১. নতুন কোনো অনুমতি লাগে কি?
| অনুমতি | ফেজ ১-এ | কেন |
|---|---|---|
| CAMERA | **আগে থেকেই আছে** (ভিডিও কল, Shop Box মোড) — নতুন কিছু নয় | শুধু "পুরনো ফোন গেটওয়ে" মোডে ফোনের নিজের ক্যামেরা চালাতে, মালিক নিজে চালু করলে |
| FOREGROUND_SERVICE_CAMERA | **নতুন করে ব্যবহার করা হচ্ছে না** | ফেজ ১-এ পুরনো ফোন গেটওয়ে **স্ক্রিন খোলা রেখে** চলে (Shop Box মোড), পেছনে সার্ভিস চলে না। Lost/Stolen-এর জন্য আগের camera FGS ঘোষণা অপরিবর্তিত |
| মাইক্রোফোন | **না** | শব্দ কখনো ধরা হয় না |
| লোকাল নেটওয়ার্ক | ফোনে না | নেটওয়ার্ক ক্যামেরা খোঁজা/পড়া হয় পিসি গেটওয়েতে (Windows প্রোগ্রাম), ফোনে নয় |

> পরে (ফেজ ২) যদি পুরনো ফোন **স্ক্রিন বন্ধ রেখে** পাহারা দেয়, তখন FGS "camera" টাইপ ঘোষণা লাগবে — নিচের লেখা তৈরি রাখা হলো।

## ২. Data safety (Play Console → App content → Data safety) — যা যোগ/নিশ্চিত করবেন
- **Photos and videos → Photos**: *Collected* = Yes; Purpose = App functionality; Optional = Yes (শুধু যে ব্যবহারকারী ক্যামেরা যুক্ত করেন); Ephemeral = No; Shared = No। ব্যাখ্যা: "CCTV alert snapshots: one still photo per suspicious event, deleted after the owner's chosen 0–30 days (default 3)."
- **Videos**: *Collected* = **No** (সার্ভার ভিডিও গ্রহণই করে না — স্বয়ংক্রিয় টেস্টে প্রমাণিত)।
- Encryption in transit = Yes; deletion request = Yes (অ্যাকাউন্ট মুছলে সব মুছে যায়)।

## ৩. নজরদারি/স্টকারওয়্যার নীতি — যা মেনে চলা হচ্ছে
- শুধু **নিজের** বাড়ি/দোকানের ক্যামেরা; অ্যাপে লুকানো রেকর্ডিং নেই; গেটওয়ে ফোনে সবসময় দৃশ্যমান স্ক্রিন।
- প্রতিটি সতর্কতা "সন্দেহজনক — একটু দেখে নিন" — কাউকে দোষী বলা নয়; মুখ চেনা নেই; অডিও নেই।
- কর্মী/অতিথিদের জন্য **নোটিশের নমুনা** অ্যাপে (শেয়ার করা যায়) ও গোপনীয়তা নীতিতে।
- গোপনীয়তা নীতিতে নতুন অংশ "CCTV watchman (home and shop)" — বাংলা ও ইংরেজি (lifeassisto.com/privacy, তারিখ ২৬ অক্টোবর ২০২৬)।

## ৪. (ফেজ ২-এর জন্য তৈরি) FGS camera ঘোষণার লেখা — এখন জমা দেবেন না
**Feature description (copy):**
> Home & shop watchman: the user turns an old phone into a camera for their own home or shop. Only after the user switches it on, the phone's camera watches one spot and, when something looks unusual, sends one still photo to the owner. A persistent notification names the feature and has a Stop button.

**Why foreground (copy):**
> The watching must continue while the old phone's screen is off; Android only allows camera access then through a camera foreground service, visible to the user through the notification.

**৩০ সেকেন্ডের ভিডিও স্ক্রিপট:** Assisto → মেনু → বাড়ি ও দোকানের পাহারাদার → গেটওয়ে যুক্ত করুন → "এই ফোনটিই ব্যবহার করুন" → Pair → চালু → নোটিফিকেশন দেখান → Stop।

## ৫. আপনার কাজ (Play চালুর আগে)
1. Data safety-তে উপরের "Photos" লাইন যোগ করুন (Videos = No)।
2. গোপনীয়তা নীতি লাইভ হয়েছে কিনা দেখুন (ব্যাকএন্ড ডিপ্লয়ের পরে)।
3. তারপর Owner Admin → Features → cctv_watchman → Play চালু।
