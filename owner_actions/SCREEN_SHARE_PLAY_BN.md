# স্ক্রিন শেয়ার — Google Play-তে ঘোষণা (আপনার কাজ, মোট ~২০ মিনিট)

**কেন লাগে:** ভিডিও কলে স্ক্রিন শেয়ার করতে Android-এ একটা বিশেষ পটভূমি-সেবা (foreground service, ধরন "media projection") লাগে। Google Play এটা লেখা আর একটা ছোট ভিডিও ছাড়া মানে না।

**এখন কী অবস্থা:**
- Play-এর বিল্ডে স্ক্রিন শেয়ারের এই অংশ **ঢোকানো হয় না** (`PLAY_SCREEN_SHARE = false`)। তাই ভিডিও-কলের ঠিক করা বিল্ড কখনো আটকাবে না। ভুল করে ঢুকে গেলে CI বিল্ডটাই থামিয়ে দেয়।
- Play ভার্সনে স্ক্রিন-শেয়ার বোতাম **দেখায় না** (মরা বোতাম বা "পরে আসবে" লেখা নিয়ম-বিরোধী)। ঘোষণা পাস হলে সুইচ চালু করলেই বোতাম আসে।
- **ওয়েবসাইটের APK-তে** স্ক্রিন শেয়ার পুরো চালু। ডেমো ভিডিও এটা দিয়েই বানাবেন।
- আপনি ঘোষণা জমা দেওয়ার **পরের** Play বিল্ডে চালু হবে। সেটা একটা সুইচ বদলানো: `PLAY_SCREEN_SHARE = true`।

---

## ধাপ ১ — স্ক্রিন-শেয়ারওয়ালা APK ফোনে বসান (৫ মিনিট)
1. ডাউনলোড লিংকটা **STATUS-এ আছে** (`owner_actions/STATUS_FOR_OWNER.md`-এর ওপরের দিকে, "স্ক্রিন শেয়ার ডেমো APK")। এটা শুধু আপনার জন্য গোপন লিংক, সাধারণ ডাউনলোড পাতা নয়। ফোনের **Chrome**-এ লিংকটা খুলুন → **Download**।
2. ডাউনলোড শেষ হলে নোটিফিকেশনে চাপুন → **Open**।
3. "এই উৎস থেকে অ্যাপ বসানোর অনুমতি নেই" লিখলে → **Settings** → **Allow from this source** (বাংলায় "এই উৎস থেকে অনুমতি দিন") চালু → পেছনে আসুন → **Install**।
   - Realme/Oppo ফোনে: Settings → Security বা Privacy → **Install unknown apps** → Chrome → Allow।
4. ফোনে আগে থেকে Play-এর Assisto থাকলে Android বলতে পারে "App not installed (conflict)"। তখন Play-এর Assisto **আনইনস্টল** না করে **দ্বিতীয় একটা ফোনে** বসান (পরিবারের কারো পুরনো ফোন)। অথবা STATUS-এ লিখে জানান, অন্য উপায় দেওয়া হবে। আপনার ডেটা মুছবেন না।
5. যাকে কল করবেন, তার ফোনে যেকোনো Assisto থাকলেই চলবে (Play বা APK)। স্ক্রিন দেখতে তার ফোনে নতুন কিছু লাগে না।

## ধাপ ২ — ফোনের নিজের স্ক্রিন রেকর্ডার দিয়ে ৩০–৬০ সেকেন্ডের ভিডিও
**রেকর্ডিং চালু করা:**
- স্ক্রিনের ওপর থেকে **দুইবার নিচে টানুন** (Quick Settings)।
- **Screen record / Screen recorder** টাইল চাপুন (Realme/Oppo/Samsung-এ এই নামেই থাকে)। না দেখলে ✏️ (Edit) চেপে টাইলটা টেনে আনুন।
- "Record audio" বন্ধ রাখুন → **Start** → ৩ সেকেন্ড পর রেকর্ড শুরু।

**ভিডিওতে যা দেখাবেন (এই ক্রমে, প্রতিটা ধাপে ২–৩ সেকেন্ড থামুন):**
1. Assisto খুলুন → **My Circle** → পরিবারের একজন → ওপরের **ভিডিও ক্যামেরা** আইকন (ভিডিও কল)।
2. অন্যজন কল ধরুক → দুজনের ছবি দেখা যায়।
3. **"স্ক্রিন শেয়ার" / "Share screen"** বোতাম চাপুন → আমাদের ব্যাখ্যা-শিট দেখা যায় → **চালিয়ে যান / Continue**।
4. Android-এর নিজের অনুমতি-ডায়ালগ ("…will start capturing everything…") → **Start now** (Android 14-এ **Start**)।
5. লাল বার "আপনি স্ক্রিন শেয়ার করছেন" দেখা যায়। ওপরে Android-এর শেয়ারিং চিহ্ন বা নোটিফিকেশন দেখাতে একবার নোটিফিকেশন নামিয়ে দেখান ("শেয়ার বন্ধ করুন" বোতাম)।
6. **অন্য ফোনটা ক্যামেরার সামনে ধরুন**, অথবা সেই ফোনেও আলাদা রেকর্ডিং করুন: সেখানে আপনার স্ক্রিন পুরোটা দেখা যায় + "… স্ক্রিন শেয়ার করছেন"।
7. লাল বারের **বন্ধ / Stop** চাপুন → শেয়ার বন্ধ, ক্যামেরা ফেরে।
8. রেকর্ডিং বন্ধ: ওপরের লাল রেকর্ড-চিহ্ন বা নোটিফিকেশনে **Stop**। ভিডিও **Gallery/Photos → Screen recordings**-এ থাকে।

> গোপনীয়তা: রেকর্ডিংয়ের সময় ব্যাংক অ্যাপ, OTP বা ব্যক্তিগত মেসেজ খুলবেন না। নমুনা নাম ব্যবহার করুন।

## ধাপ ৩ — YouTube-এ UNLISTED আপলোড (৩ মিনিট)
1. ফোনে **YouTube** অ্যাপ → নিচে **＋** → **Upload a video** → রেকর্ড করা ভিডিওটা বাছুন।
2. Title: `Assisto – screen sharing in a video call (Play declaration)`।
3. **Visibility → Unlisted** (Public নয়, Private নয় — Google-কে Unlisted দেখতে হয়)।
4. "No, it's not made for kids" → **Upload**।
5. আপলোড শেষে: **Library → Your videos** → ভিডিওর ⋮ → **Share → Copy link**। লিংকটা `https://youtu.be/…` দিয়ে শুরু হবে।

## ধাপ ৪ — Play Console-এ হুবহু ক্লিক (৫ মিনিট, কম্পিউটারে সহজ)
1. **play.google.com/console** → **Assisto** অ্যাপ।
2. বাঁ দিকের মেনুতে **Policy and programs → App content** (কিছু অ্যাকাউন্টে **Policy → App content**)।
3. পাতায় **Foreground service permissions** খুঁজুন (কোথাও লেখা থাকে **"Foreground service types"**) → **Manage** চাপুন (প্রথমবার হলে **Start**)।
4. তালিকায় আগে থেকে টিক থাকা **Microphone** ও **Location** **যেমন আছে রাখুন**। নতুন করে **Media projection** টিক দিন।
5. Media projection-এর নিচে কাজের ধরন জিজ্ঞেস করলে **"Screen sharing / screen recording initiated by the user"** বেছে নিন (নাম একটু আলাদা হতে পারে, যেমন "User-initiated screen capture")। "Other" বেছে নেবেন না।
6. **Description / "Describe how your app uses this permission"** বক্সে নিচের ইংরেজি লেখাটা হুবহু পেস্ট করুন।
7. **Video link / "Provide a video"** বক্সে ধাপ ৩-এর YouTube লিংক পেস্ট করুন।
8. **Save** চাপুন।
9. বাঁ মেনু **Publishing overview** → **Send changes for review** (এটা শুধু আপনি চাপবেন)।
10. জমা হলে লিডকে জানান। আমরা পরের বিল্ডে সুইচ চালু করব (`PLAY_SCREEN_SHARE = true`), তারপর সেই বিল্ড আগের মতো internal/closed testing-এ যাবে।

### পেস্ট করার ইংরেজি লেখা (Description)
```
Assisto uses a foreground service of type mediaProjection only for user-initiated screen sharing during a My Circle video call (a private 1-to-1 video call with a family member or close contact, for example to show an elderly parent where to tap in an app).

How it starts: the user is in a live video call and taps "Share screen". Assisto first shows its own explanation of what the other person will see (everything on the screen, including notifications). Then Android's system screen-capture consent dialog appears. Only after the user accepts it does Assisto start the mediaProjection foreground service and capture the screen.

Why a foreground service is needed: Android requires a running foreground service of type mediaProjection while the screen is captured, so that sharing continues when the user leaves Assisto to show another app. Without it the screen cannot be shared.

What the user sees: Android's own screen-sharing indicator, an ongoing notification "Sharing your screen in an Assisto call" with a "Stop sharing" button, and a red "You're sharing your screen - Stop" bar on the call screen.

When it stops: when the user taps Stop (call screen or notification), when Android ends the capture (status-bar control or screen lock), when the call ends, or when the call switches to voice. The service is never started at app launch or in the background, never restarts itself, and stops together with the capture.

Data: the screen is sent only to the other person in the call over the call's encrypted WebRTC connection (DTLS-SRTP). Assisto does not record, store or upload the shared screen.
```

---
বিস্তারিত ফিচার ও দুই-ফোন পরীক্ষা: `owner_actions/FEATURE_CARD_SCREEN_SHARE_BN.md`।
