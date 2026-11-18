# Play ঘোষণা — "পুরনো ফোন = CCTV ক্যামেরা" (Foreground service: camera)

> কেন: আপনার নির্দেশ — Play অ্যাপে কিছুই লুকানো থাকবে না। এখন থেকে পুরনো ফোনকে ক্যামেরা বানালে **স্ক্রিন বন্ধ করলেও পাহারা চলে**। এর জন্য Play বিল্ডে নতুন একটি অনুমতি আছে: `FOREGROUND_SERVICE_CAMERA` (সার্ভিস: `PhoneCamService`, টাইপ `camera`)। Google এটা ঘোষণা ছাড়া মেনে নেয় না — তাই নিচের কাজটি **এই বিল্ড প্রোডাকশনে পাঠানোর আগে** একবার করবেন।
>
> কী করে না: ফোন চালু হলে নিজে চালু হয় না, লুকিয়ে চলে না, ভিডিও রেকর্ড করে না (স্ক্রিন বন্ধ থাকলে শুধু নড়াচড়া হলে একটি ছবি), শব্দ নেয় না। ব্যবহারকারী "চালু করুন" চাপলেই শুধু চলে; পুরো সময় একটি নোটিফিকেশন থাকে, তাতে **"বন্ধ করুন"** বোতাম।

## ১. Play Console-এ কোথায় চাপবেন (ধাপে ধাপে)

1. play.google.com/console → **Assisto** অ্যাপ খুলুন।
2. বাঁ দিকের মেনু → **Policy and programs** → **App content**।
3. তালিকায় **Foreground service permissions** → **Manage** (আগে মাইক্রোফোন/লোকেশন ঘোষণা করেছিলেন, সেই একই পাতা)।
4. নতুন টাইপ **Camera** দেখাবে → তার পাশে টিক দিন।
5. কাজের ধরন (task) বাছাইয়ে যেটি সবচেয়ে কাছাকাছি সেটি নিন — সাধারণত **"Other"** (নাম একটু ভিন্ন হতে পারে; "user-initiated camera" ধরনের কিছু থাকলে সেটি)। তারপর নিচের ইংরেজি লেখা বসান।
6. **Video link**: নিচের অংশ ৩-এর মতো ভিডিও (৩০ সেকেন্ডের কম) YouTube-এ **Unlisted** করে লিংক দিন।
7. **Save** → তারপর **Publishing overview**-এ গিয়ে পরিবর্তন পর্যালোচনায় পাঠান (এটি আপনি নিজে করবেন; এজেন্টরা Play-তে কিছু পাঠায় না)।

## ২. কপি-পেস্ট করার ইংরেজি লেখা

**Feature / why the app needs a camera foreground service:**
> Assisto lets a user turn an old Android phone into a security camera for their own shop or home ("Use this phone as a camera"). After the user pairs the phone with their account and taps Start, the phone watches its own camera for movement and sends the owner an alert with one photo, and the owner can open live view. The watching must continue when the user turns the phone's screen off (to save power and not light up the shop at night). Android only allows camera use in that state through a foreground service of type camera.

**How the user starts and stops it / what the user sees:**
> It starts ONLY when the user taps Start on the "Use this phone as a camera" screen, after granting the camera permission. It never starts at boot or by itself. While it runs, a persistent notification says "This phone is working as a camera" with a Stop button, and the screen shows a red "this phone is recording" banner. Tapping Stop (in the notification or on the screen) ends the service and releases the camera immediately. If the user closes the app, the service stops.

**What data is used:**
> With the screen off, only still frames are analysed on the phone; a single photo is uploaded only when movement is detected. No video is recorded with the screen off and no audio is captured. Live view is shown only to the account owner (and family members the owner allowed).

**Why it cannot be deferred / WorkManager is not suitable:**
> Security watching is continuous and user-visible; it cannot be paused or scheduled. Stopping the camera when the screen turns off would leave the shop unwatched.

## ৩. ভিডিও রেকর্ডিং স্ক্রিপ্ট (৩০ সেকেন্ডের কম, ফোনের স্ক্রিন রেকর্ডার দিয়ে)

| সময় | কী দেখাবেন |
|---|---|
| ০–৫ সে | Assisto খুলুন → মেনু → CCTV পাহারা → **এই ফোনকে ক্যামেরা বানান** (আগে থেকেই জোড়া লাগানো রাখুন) |
| ৫–১০ সে | **চালু করুন** চাপুন → ক্যামেরা অনুমতি (প্রথমবার হলে) → লাল "রেকর্ড হচ্ছে" ব্যানার |
| ১০–১৫ সে | ওপর থেকে নোটিফিকেশন টানুন → "This phone is working as a camera" + **Stop** বোতাম দেখান |
| ১৫–২২ সে | পাওয়ার বোতাম চেপে স্ক্রিন বন্ধ → ক্যামেরার সামনে হাত নাড়ুন → দ্বিতীয় ফোনে (মালিক) ছবিসহ সতর্কতা আসছে দেখান |
| ২২–৩০ সে | স্ক্রিন খুলে নোটিফিকেশনের **Stop** চাপুন → নোটিফিকেশন চলে গেছে, পাতায় আবার "চালু করুন" |

টিপ: দ্বিতীয় ফোনের অংশ ছোট রাখুন; মূল বিষয় — **ব্যবহারকারী নিজে চালু করে, নোটিফিকেশন সব সময় দেখা যায়, Stop কাজ করে**।
বিকল্প: CI-এর এমুলেটর রান (`guardbox-fgs.yml`)-এর স্ক্রিনশটগুলো (`guardbox-fgs-emulator` আর্টিফ্যাক্ট) ভিডিওর ধাপ বোঝাতে সাহায্য করবে, কিন্তু Google সাধারণত আসল ফোনের ভিডিও চায়।

## ৪. দুই ফোনে নিজে পরীক্ষা (২ মিনিট)

1. ফোন ক (পুরনো): মালিকের অ্যাকাউন্টে "এই ফোনকে ক্যামেরা বানান" → কোড দিয়ে জোড়া → **চালু করুন**।
2. পাওয়ার বোতাম চেপে স্ক্রিন বন্ধ করুন, সামনে হাঁটুন।
3. ফোন খ (মালিক/পরিবার): ১–২ মিনিটে ছবিসহ সতর্কতা আসবে; লাইভ খুলুন — ছবি চলবে।
4. ফোন ক-তে নোটিফিকেশনের **বন্ধ করুন** চাপুন → নোটিফিকেশন উধাও, ক্যামেরা বন্ধ।

ফেল হলে স্ক্রিনশট পাঠান; প্রতিটি ফেল একটি নতুন টেস্ট হবে।
