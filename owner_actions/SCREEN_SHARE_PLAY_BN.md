# স্ক্রিন শেয়ার — Google Play ঘোষণা (আপনার কাজ, ~১৫ মিনিট)

**কেন লাগে:** ভিডিও কলে স্ক্রিন শেয়ার করতে Android-এ একটি "media projection" foreground service লাগে (permission `FOREGROUND_SERVICE_MEDIA_PROJECTION`)। Play এটা ঘোষণা (লেখা + ভিডিও) ছাড়া নেয় না। তাই এখন:
- ওয়েবসাইট APK-তে স্ক্রিন শেয়ার **পুরো চালু**।
- Play বিল্ডে service ও permission **সরানো থাকে** (`android.yml`-এ `PLAY_SCREEN_SHARE: 'false'`); বোতাম চাপলে সৎ লাইন: "Assisto-র এই ভার্সনে স্ক্রিন শেয়ার এখনো নেই — আপডেটে আসবে"। ভুল করে Play বান্ডলে ঢুকলে CI বিল্ড থামিয়ে দেয়।

## ধাপ ১ — ভিডিও বানান (৩০–৪৫ সেকেন্ড, ওয়েবসাইট APK দিয়ে)
1. ফোন A থেকে ফোন B-কে **ভিডিও কল** করুন, B ধরুক।
2. A-তে **"স্ক্রিন শেয়ার"** চাপুন → আমাদের শিট ("…আপনার স্ক্রিন দেখাবেন?") → **চালিয়ে যান**।
3. Android-এর নিজের ডায়ালগ → **Start now / Start**।
4. লাল বার "আপনি স্ক্রিন শেয়ার করছেন" + নোটিফিকেশনে "শেয়ার বন্ধ করুন" দেখান; হোমে গিয়ে একটা অ্যাপ খুলুন (B-তে দেখা যায়)।
5. লাল বারের **বন্ধ** চাপুন → ক্যামেরা ফেরে।
ফোনের স্ক্রিন রেকর্ড দিয়ে রেকর্ড করুন → YouTube-এ **Unlisted** আপলোড → লিংক কপি।

## ধাপ ২ — Play Console-এ ক্লিক (হুবহু)
1. play.google.com/console → **Assisto** অ্যাপ।
2. বাঁ মেনু **Policy and programs → App content** (পুরনো মেনুতে: **Policy → App content**)।
3. **Foreground service permissions** → **Manage** (বা **Start**)।
4. তালিকায় **Media projection** টিক দিন (মাইক্রোফোন ও লোকেশন আগের মতোই থাকবে — বদলাবেন না)।
5. Media projection-এর নিচে কাজের ধরন: **"Screen sharing / screen recording initiated by the user"** (অথবা কাছাকাছি নাম "User-initiated screen capture") বেছে নিন।
6. **Description** বক্সে নিচের ইংরেজি লেখাটা পেস্ট করুন।
7. **Video link**-এ ধাপ ১-এর YouTube লিংক।
8. **Save** → তারপর বাঁ মেনু **Publishing overview → Send changes for review** (এটা আপনি নিজে চাপবেন; এজেন্ট কখনো চাপে না)।

### Description (পেস্ট করার খসড়া, ইংরেজি)
> Assisto lets a user share their own phone screen with one family member during a My Circle video call (for example, to show an elderly parent where to tap in an app). Sharing starts only when the user taps "Share screen" in a live video call, reads our explanation of what the other person will see, and then accepts Android's own screen-capture dialog. Only after that consent do we start a foreground service of type mediaProjection, with an ongoing notification that has a "Stop sharing" button. A red "You're sharing your screen · Stop" bar stays on the call screen. Sharing stops when the user taps Stop, uses the notification, when Android ends the projection, when the call ends or switches to voice. The service is never started at app launch or in the background, never restarts itself, and the captured screen is sent only to the other person in the call, end-to-end encrypted (WebRTC DTLS-SRTP). We do not record or store it.

## ধাপ ৩ — ঘোষণা জমা হলে (এজেন্ট/লিড)
- `.github/workflows/android.yml`-এ `PLAY_SCREEN_SHARE: 'true'` (এক লাইন) → পরের Play বিল্ডে স্ক্রিন শেয়ার চালু; গার্ড টেস্টও সেই সাথে বদলাতে হবে (`play_disclosure_guard_test.dart`)।
- Google রিভিউ পাস হওয়ার আগে এই পরিবর্তন Play-তে পাঠানো হবে না।

বিস্তারিত ফিচার: `owner_actions/FEATURE_CARD_SCREEN_SHARE_BN.md`।
