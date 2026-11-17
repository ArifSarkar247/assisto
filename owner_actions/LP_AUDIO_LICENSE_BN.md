# Language Partner — লিসেনিং অডিওর লাইসেন্স (lpaudio, ১৭ নভেম্বর ২০২৬)

**কী:** IELTS প্র্যাকটিস টেস্টের (আমাদের নিজের লেখা ৩টি মক: ac-001, ac-002, gt-001) লিসেনিং অংশ এখন আসল রেকর্ডিং।
অডিও বানানো হয় GitHub CI-তে (আমাদের সার্ভারে নয়), ফ্রি ওপেন-সোর্স TTS দিয়ে। কোনো টাকা খরচ নেই, কোনো ক্লাউড TTS নেই।
**কারও কণ্ঠ নকল (voice cloning) করা হয়নি** — শুধু মডেলের সাথে আসা তৈরি (stock) কৃত্রিম কণ্ঠ।

## ব্যবহৃত ইঞ্জিন ও কণ্ঠ

| জিনিস | লাইসেন্স | ব্যবসায় ব্যবহার? | কোথায় |
|---|---|---|---|
| Kokoro-82M v1.0 মডেল + কণ্ঠ (hexgrad) | Apache-2.0 | **হ্যাঁ** | সব IELTS লিসেনিং |
| `kokoro` 0.9.4, `misaki[en]` 0.9.4 (Python) | Apache-2.0 | হ্যাঁ | শুধু CI |
| eSpeak NG (উচ্চারণের সাহায্য) | GPL-3.0 প্রোগ্রাম — শুধু চালাই, তৈরি অডিও আমাদের | হ্যাঁ | শুধু CI |
| ffmpeg (AAC এনকোড) | LGPL/GPL প্রোগ্রাম — শুধু চালাই | হ্যাঁ | শুধু CI |

কণ্ঠ (সব Kokoro stock): ব্রিটিশ — `bm_george` (ঘোষক), `bf_emma`, `bf_isabella`, `bf_alice`, `bm_fable`, `bm_lewis`, `bm_daniel`;
আমেরিকান — `af_heart`, `af_bella`, `af_nicole`, `af_sarah`, `am_michael`, `am_fenrir`, `am_puck`, `am_eric`।
একই কথোপকথনে প্রত্যেক বক্তার আলাদা কণ্ঠ; ঘোষকের কণ্ঠ কোনো বক্তার নয়।

**সৎ সীমা:**
- **অস্ট্রেলিয়ান উচ্চারণের কোনো লাইসেন্স-পরিষ্কার কণ্ঠ নেই।** তাই যে পার্ট "au" লেখা, সেখানে ব্রিটিশ/আমেরিকান কণ্ঠ — অ্যাপে "কণ্ঠ: ব্রিটিশ ইংরেজি" এভাবে সত্যি লেখা দেখায়, কখনো "অস্ট্রেলিয়ান" দাবি করে না।
- Kokoro-র মডেল কার্ড বলে প্রশিক্ষণে পাবলিক-ডোমেইন/Apache/MIT অডিও আর বড় কোম্পানির TTS থেকে তৈরি কিছু কৃত্রিম অডিও ছিল। মডেল নিজে Apache-2.0 (ব্যবসায় চলে); এই প্রজেক্টে আগেই `.phaseB/MODEL_LICENSES.md`-এ "Yes" দেওয়া।

## বাদ দেওয়া হয়েছে (কেন)

| কণ্ঠ | কারণ |
|---|---|
| Piper `en_GB-vctk`, `en_US-libritts_r`, `en_GB-aru`, `en_GB-alan`, `en_GB-northern_english_male`, `en_US-arctic`, `en_US-sam`, `en_US-kusal` | "lessac" কণ্ঠ থেকে বানানো — lessac ডেটা শুধু গবেষণার জন্য (non-commercial) |
| Piper `en_US-ryan`, `en_US-hfc_*`, `en_US-l2arctic`, `en_US-danny` | CC BY-NC (ব্যবসায় নিষেধ) বা ryan থেকে বানানো |
| Piper `en_GB-semaine` | ডেটা শুধু গবেষণার জন্য |
| Coqui XTTS, যে কোনো voice-cloning মডেল | non-commercial + কণ্ঠ নকল — কখনো না |
| ক্লাউড TTS (Google, Azure, ElevenLabs ইত্যাদি) | টাকা লাগে — নিষেধ |

ভবিষ্যতে বিকল্প (পরীক্ষিত, এখনো ব্যবহার নয়): Piper `en_GB-cori-high`, `en_US-ljspeech-high`, `en_US-kristin`, `en_US-john`, `en_US-norman` (পাবলিক ডোমেইন), `en_US-joe`/`mike`/`kathleen` (CC0), `en_GB-alba`, `en_GB-cori-medium` (CC BY 4.0), `en_GB-jenny_dioco` (ব্যবসায় চলে, "Jenny (Dioco)" নাম উল্লেখ ভালো)। এগুলোর ব্রিটিশ পুরুষ কণ্ঠ নেই, তাই এখন Kokoro।

## কোথায় থাকে, কে দেখে

- অডিও ফাইল: GitHub release `lp-audio` (`<bundle>-p<n>-<hash>.m4a`, AAC মোনো ৪০ kbps, প্রতি পার্ট ~১.৫ MB) → সার্ভার `manage.py lp_audio` দিয়ে sha256 মিলিয়ে প্রাইভেট মিডিয়ায় রাখে, ফোনে যায় শুধু স্বল্পমেয়াদি সাইন করা লিংক।
- **স্ক্রিপ্ট ও উত্তর ফোনে যায় না** — সার্ভারেই থাকে (মার্কিং সার্ভারে)। স্ক্রিপ্ট বদলালে পুরনো অডিও নিজে থেকেই বাদ পড়ে (plan hash)।
- এটা Assisto-র নিজের প্র্যাকটিস টেস্ট — আসল IELTS-এর প্রশ্ন বা অডিও নয়।
