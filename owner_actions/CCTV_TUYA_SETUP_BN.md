# Tuya / Smart Life — মালিকের জন্য ধাপ (CCTV অটোমেশন)

কেন: রাতে দোকানে কেউ ঢুকলে Smart Life-এর আলো, প্লাগ, সাইরেন নিজে নিজে চালু হবে আর বক্সে আপনার কণ্ঠে সতর্কবাণী বাজবে। দরজার লক **কখনো নিজে হবে না** — প্রতিবার মালিকের "হ্যাঁ" লাগবে। খরচ: Tuya-র ফ্রি (Trial/Basic) সার্ভিসেই চলে; কোনো টাকা লাগে না।

## ক) একবার: Tuya developer অ্যাকাউন্ট (১৫ মিনিট)
1. https://iot.tuya.com → Sign Up (ইমেইল দিয়ে) → লগইন।
2. বাঁ দিকে **Cloud → Development → Create Cloud Project**।
   * Project Name: `Assisto CCTV` · Industry: `Smart Home` · Development Method: `Smart Home`
   * **Data Center:** `India` বেছে নিন (বাংলাদেশের Smart Life অ্যাকাউন্ট সাধারণত এখানে; না মিললে Central Europe যোগ করুন — একাধিক বাছা যায়)।
3. পরের পাতায় API সার্ভিস: **IoT Core**, **Authorization Token Management**, **Smart Home Basic Service**, **Smart Lock Open Service** (লকের জন্য) — সব Authorize করুন।
4. Project → **Overview** থেকে **Access ID/Client ID** আর **Access Secret/Client Secret** কপি করুন।
5. Assisto Owner Admin → Integrations → **Tuya / Smart Life (CCTV automations)** → Access ID, Access Secret, ডেটা সেন্টার (`in`) পেস্ট → Save → **Test** (সবুজ = চালু)।

## খ) প্রতিটি দোকান/বাড়ির Smart Life অ্যাকাউন্ট যুক্ত করা
1. Tuya Console → Project → **Devices → Link Tuya App Account → Add App Account** → একটি QR আসবে।
2. দোকানের মালিক নিজের ফোনের **Smart Life** অ্যাপ → উপরে ডানে স্ক্যান আইকন → QR স্ক্যান → Confirm।
   (ভুল করে "Users" ট্যাবে যুক্ত করবেন না — তাহলে ডিভাইস দেখা যায় না।)
3. লিঙ্ক হওয়া অ্যাকাউন্টের পাশে **UID** দেখাবে — কপি করুন।
4. দোকানের মালিক Assisto অ্যাপে: CCTV → দোকান → **অটোমেশন** → "Smart Life যুক্ত করুন" → UID পেস্ট → যুক্ত করুন। ডিভাইসের তালিকা আসবে।

**বিকল্প (মালিকের সাহায্য ছাড়া):** দোকানের মালিক নিজেই উপরের ক) ধাপে নিজের ফ্রি প্রজেক্ট খুলে অ্যাপে "নিজের Tuya প্রজেক্ট" বেছে Access ID, Secret, UID দিতে পারেন — Secret সার্ভারে তালাবদ্ধ (encrypted) থাকে, কখনো ফেরত দেখানো হয় না।

## গ) নিয়ম বানানো (অ্যাপে)
* "রাতে কেউ ঢুকলে" (রাত ১০টা–সকাল ৬টা, বদলানো যায়) → আলো/প্লাগ চালু (কত সেকেন্ড — ১০ থেকে ৬০০), সাইরেন, বক্সে আপনার কণ্ঠ।
* "আগুন/ধোঁয়া" → সাইরেন + আলো।
* লক বেছে নিলে: সতর্কতা এলে ফোনে প্রশ্ন "দরজা লক করবেন?" — ১০ মিনিটের মধ্যে "হ্যাঁ" চাপলেই কেবল লক হবে।
* "পরীক্ষা" বোতাম: একটি আলো/প্লাগ ১০ সেকেন্ড চালু হয়ে নিজে বন্ধ হবে।

## সৎ সীমা
* আসল প্লাগ/লাইট/লকে এখনো চালানো হয়নি (CI-তে Tuya-র প্রকাশিত request/answer আকারে পরীক্ষা হয়েছে)।
* Tuya-র ক্লাউড বন্ধ থাকলে বা ইন্টারনেট না থাকলে অটোমেশন চলবে না — সতর্কতা আর ফোনের অ্যালার্ম তবুও আসবে।
