# CCTV ডেভেলপার অ্যাকাউন্ট — মালিকের ধাপ (Imou, EZVIZ, Dahua DoLynk, Hikvision)

## IMOU OAUTH NOW (৯ Nov ১৬:৫২) — "Create an OAuth project" ফর্মে ঠিক এই মানগুলো দিন

| ফর্মের ঘর | যা লিখবেন / বাছবেন |
|---|---|
| Project name | `Assisto CCTV` |
| Project description (থাকলে) | `Lets shop and home owners link their own Imou cameras to the Assisto app to see live video, playback and alarms.` |
| Redirect URI / Callback URL | `https://api.lifeassisto.com/api/v1/cctv/imou/oauth/callback` |
| Authorized domain / Website (থাকলে) | `https://lifeassisto.com` (ডোমেইন শুধু চাইলে: `api.lifeassisto.com`) |
| Logo (থাকলে) | Assisto লোগো (রিপোর `logo/` ফোল্ডারের PNG) |
| Privacy policy URL (থাকলে) | `https://lifeassisto.com/privacy` |
| Terms URL (থাকলে) | `https://lifeassisto.com/terms` |

**Scopes / permissions — শুধু এগুলোতে টিক দিন (নামে সামান্য পার্থক্য থাকতে পারে):**
1. ডিভাইস তালিকা ও তথ্য দেখা (device list / device info / device online status)
2. লাইভ ভিডিও (live / real-time stream, HLS/FLV)
3. রেকর্ডিং দেখা (record / playback / cloud & SD-card video query)
4. অ্যালার্ম ও মেসেজ (alarm message / message subscription / passenger flow)
5. ছবি তোলা (snapshot / capture)
6. সাইরেন/সাদা আলো চালু (device control — শুধু যদি আলাদা ঘর থাকে; "অ্যালার্টে সাইরেন" বোতামের জন্য)

**টিক দেবেন না:** ডিভাইস মুছে ফেলা/হস্তান্তর (delete / unbind / transfer), ডিভাইস শেয়ার অন্যকে দেওয়া, পাসওয়ার্ড/নেটওয়ার্ক/ফার্মওয়্যার বদলানো, অ্যাকাউন্টের ব্যক্তিগত তথ্য — Assisto-র এগুলো লাগে না।

**জমা দেওয়ার পর:** OAuth প্রজেক্টের যে নতুন মান আসবে (যেমন Client ID / Client Secret বা project key), সেগুলো এখানে বা চ্যাটে **লিখবেন না** — Owner Admin → Integrations → Imou কার্ডে "OAuth" ঘরে পেস্ট করবেন (ঘরটি পরের বিল্ডে আসছে; ততক্ষণ নিজের কাছে রাখুন)।

**সৎ নোট:** Imou কনসোলের এই ফর্মটি আমরা নিজের চোখে দেখিনি। ফর্মে যদি ওপরের কোনো ঘর না থাকে, বাদ দিন; যদি এমন কোনো ঘর থাকে যা এখানে নেই, তার নাম লিখে দিন — ১০ মিনিটের মধ্যে মান জানাব। Redirect URI ঠিক ওপরেরটাই রাখবেন (শেষে `/` ছাড়া) — পরে বদলালে লিংক করা কাজ করবে না।
