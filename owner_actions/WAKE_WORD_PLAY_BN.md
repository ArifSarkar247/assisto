# "Hey Assisto" — Play ঘোষণা, ভিডিও স্ক্রিপ্ট ও দুই-ফোন টেস্ট (wakeword, ৪ Nov ২০২৬)

**অবস্থা:** ফিচার চালু (`VaWake.shipped` = true)। `WakeWordService` (টাইপ microphone) এখন Play AAB-এ **থাকে**, CI দেখে নেয় (`android.yml` → "WakeWordService kept")।
তাই Play Console-এ নিচের ঘোষণা **আপনাকে জমা দিতে হবে** (আমি Play-তে কিছু জমা দিই না)।

## ১. Play Console → App content → Foreground service permissions → `FOREGROUND_SERVICE_MICROPHONE`

**টিক দিন:** "Microphone" — user-initiated, ongoing, user-visible (অ্যাপ ব্যাকগ্রাউন্ডে থাকলেও চলে)।
(একই অনুমতি আগে থেকেই Voice SOS ও My Circle কলের জন্য ঘোষিত — ঘোষণায় শুধু "Hey Assisto" যোগ করুন।)

**বর্ণনা (ইংরেজিতে হুবহু পেস্ট করুন, ৫০০ অক্ষরের মধ্যে):**
> Optional hands-free "Hey Assisto", OFF by default. The user turns it on in Settings > Assisto Voice after an in-app disclosure. A foreground service keeps the microphone open so an on-device model can hear "Hey Assisto" while the user is in other apps. Audio is analysed on the phone in 80 ms pieces and discarded; nothing is recorded or uploaded before the wake word. A notification with Pause 1 h and Turn off is always shown. It pauses on calls, Battery Saver, low battery and, unless allowed, when locked.

**কেন ফোরগ্রাউন্ড সার্ভিস লাগবে (পেস্ট):**
> The wake word must be heard while the user is not looking at Assisto. Android allows background microphone use only in a user-visible foreground service. It is never started at app launch or at boot; after a reboot the user gets a one-tap "turn on again" notification.

**বন্ধ থাকলে কী হারায় (পেস্ট):**
> Only hands-free start. The user can still tap the mic or use Assisto as the default assistant (long-press home/power).

**Prominent disclosure:** অ্যাপের ভেতরে পুরো-পর্দার `WakeDisclosureScreen` ("I agree — turn on" / "Not now") — Android-এর মাইক্রোফোন প্রশ্নের **আগে** (CI টেস্ট `play_disclosure_guard_test.dart` পাহারা দেয়)।

## ২. ডেমো ভিডিও (≈ ৫০ সেকেন্ড; YouTube-এ unlisted আপলোড করে লিংক দিন)
1. (০–৫ সে) Assisto → মেনু → Settings → **Assisto Voice**। "“Hey Assisto” — hands-free" সুইচ বন্ধ দেখান।
2. (৫–১২ সে) সুইচ চাপুন → disclosure স্ক্রিন; ধীরে স্ক্রল করুন যাতে প্রতিটি লাইন পড়া যায় → **I agree — turn on**।
3. (১২–১৭ সে) Android মাইক প্রশ্ন → **While using the app**; নোটিফিকেশন → Allow।
4. (১৭–২২ সে) নোটিফিকেশন শেড টানুন: "Listening for “Hey Assisto”" + **Pause 1 h** + **Turn off**।
5. (২২–৩০ সে) Home চাপুন (অন্য অ্যাপ খোলা)। বলুন "Hey Assisto, set an alarm for 6 am" → বিপ + ভাইব্রেশন → Assisto Voice খোলে → **কনফার্ম কার্ড** → Yes।
6. (৩০–৩৮ সে) "Hey Assisto, WhatsApp Rahim I am coming" → কনফার্ম কার্ড → WhatsApp চ্যাট খোলে, লেখা ভরা — **Send ব্যবহারকারী নিজে চাপেন**।
7. (৩৮–৪৪ সে) সেটিংসে "ফোন লক থাকলেও শুনবে" বন্ধ দেখান; ফোন লক করুন → নোটিফিকেশন "বিরতি: ফোন লক"।
8. (৪৪–৫০ সে) নোটিফিকেশন → **Pause 1 h** → **Turn off** (নোটিফিকেশন চলে যায়, সুইচ বন্ধ)।

**জরুরি:** Assisto-কে **Default digital assistant** বানালে (Settings → Assisto Voice → প্রথম কার্ড) ব্যাকগ্রাউন্ড থেকে সরাসরি খোলে। না বানালে Android ব্যাকগ্রাউন্ড থেকে অ্যাপ খুলতে দেয় না — তখন "Tap to talk" নোটিফিকেশন আসে (সৎ ফলব্যাক)। ভিডিওর আগে Default assistant বানিয়ে নিন।

## ৩. যা মাপা হয়েছে (সৎ সংখ্যা)
| কী | সংখ্যা | কোথা থেকে |
|---|---|---|
| ভুল জাগা — সাধারণ বাংলা কথা | ১০ ঘণ্টায় **০** (Low ও Normal) | CI রান 39903513961, `backend/core/wakeword_models/eval_report.md` |
| ভুল জাগা — টিভি-চলা বাংলা + গান | ১০ ঘণ্টায় **১** (Low, অ্যাপের ডিফল্ট); Normal-এ ৩ | একই |
| মিস — ১–২ মিটার দূর | ১২.৮% (Low), ৭.৮% (Normal) | একই; **কৃত্রিম কণ্ঠ** — আসল মানুষে মাপা বাকি |
| CPU | `wakeword-proof` CI রান — "CPU ms per audio second" (x86 সার্ভার, ফোন নয়) | `.github/workflows/wakeword-proof.yml` |
| ব্যাটারি | **ফোনে মাপা হয়নি** — নিচের টেস্ট ৫ দিয়ে মাপুন | — |

## ৪. দুই-ফোন মালিক-টেস্ট (Realme + আরেকটি ফোন, ২০ মিনিট)
1. ফোন A: Settings → Assisto Voice → Default assistant বানান → "Hey Assisto" চালু → disclosure → Agree → মাইক Allow। নোটিফিকেশন দেখা যাচ্ছে?
2. অন্য অ্যাপ খুলে ১ মিটার দূর থেকে "Hey Assisto" ১০ বার বলুন — কতবার বিপ হলো লিখুন (৮+ হলে ঠিক)।
3. "Hey Assisto, আম্মুকে কল দাও" → কনফার্ম কার্ড → Yes → SIM কল যায়? (প্রথমবার Android কল-অনুমতি চাইবে; না দিলে ডায়ালারে নম্বর ভরা থাকে।)
4. "Hey Assisto, my circle e B ke likho ami ashchi" → কার্ড → Send → ফোন B-তে মেসেজ আসে?  "Hey Assisto, WhatsApp B ami ashchi" → WhatsApp খোলে, লেখা ভরা, Send আপনি চাপেন। "Hey Assisto, safe journey shuru koro" → কার্ড → নিরাপদ যাত্রা খোলে। "Hey Assisto, kal sokal 6 tay alarm dao" → ঘড়ি-অ্যাপে অ্যালার্ম।
5. **ব্যাটারি:** ফোন ১০০% চার্জে, "Hey Assisto" চালু, স্ক্রিন বন্ধ, ৩ ঘণ্টা রেখে দিন → Settings → Battery → Assisto কত % — লিখে আমাকে দিন (একই কাজ সুইচ বন্ধ রেখে আরেকদিন)।
6. টিভি চালু রেখে ১ ঘণ্টা ফোন পাশে রাখুন — নিজে থেকে কতবার জাগল লিখুন।
7. ব্যাটারি সেভার চালু করুন → নোটিফিকেশন "বিরতি: ব্যাটারি সেভার"। ফোন লক করুন → "বিরতি: ফোন লক"। ফোন রিস্টার্ট → "আবার চালু করুন" নোটিফিকেশন → এক চাপে চালু।
