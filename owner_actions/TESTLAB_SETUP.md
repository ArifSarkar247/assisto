# Firebase Test Lab চালু করা (মালিকের কাজ)

**কেন:** প্রতিটি My Circle বিল্ডের আগে GitHub থেকে একটি বোতাম চাপলেই Google-এর ডেটা সেন্টারের আসল ফোনে (Samsung, Xiaomi, OPPO, realme… যা Test Lab-এ আছে) Assisto চালিয়ে দেখা যাবে: লগইন → My Circle → "Call Proof Test B"-এর চ্যাট → মেসেজ পাঠানো → কল → কল কাটা। প্রতিটি ফোনের ফলাফল (পাস/ফেল, ক্র্যাশ, স্ক্রিনশট) একটি টেবিলে আসবে।

**সৎ কথা:**
- এখনো একবারও চালানো হয়নি — নিচের ৪টি কাজ না হওয়া পর্যন্ত চালানো যাবে না। চালালে প্রথম ধাপেই "NOT RUN — Missing secret" লিখে থেমে যাবে।
- Test Lab-এ Walton, Symphony, Infinix, Tecno-র মতো ফোন সাধারণত **থাকে না**। কোন কোন ব্র্যান্ড আছে, তা প্রতিবার রান-এর সারাংশে ("Test Lab catalog (live)") দেখা যাবে — যা নেই, সেখানে লেখা থাকবে "NOT in Test Lab"। এসব ফোনের জন্য আসল ফোনে হাতে পরীক্ষা (PHONE_TEST_CHECKLIST.md) লাগবেই।
- টেস্ট অ্যাকাউন্ট A-র ফোন নম্বর ও পাসওয়ার্ড রান-এর সময় Robo স্ক্রিপ্টে বসানো হয় এবং Google Cloud-এ আপনার প্রজেক্টের নিজস্ব (প্রাইভেট) ফলাফল-বাকেটে জমা থাকে। তাই A অবশ্যই শুধু টেস্টের অ্যাকাউন্ট হবে (এখন যেমন আছে)।

---

## ১. দুটি API চালু করুন (প্রজেক্ট assisto-247)

1. https://console.cloud.google.com খুলুন, উপরে প্রজেক্ট বাছাই থেকে **assisto-247** বেছে নিন।
2. বাঁ দিকের মেনু • **APIs & Services** • **Library**।
3. খুঁজুন **Cloud Testing API** • খুলুন • **Enable**।
4. আবার Library-তে খুঁজুন **Cloud Tool Results API** • খুলুন • **Enable**।

## ২. প্ল্যান ও দৈনিক সীমা বুঝে নিন

Firebase কনসোল (https://console.firebase.google.com • assisto-247 • নিচে বাঁয়ে প্ল্যানের নাম) দেখুন **Spark** (ফ্রি) নাকি **Blaze** (ব্যবহার অনুযায়ী বিল)।

আমাদের জানা মতে (⚠️ বর্তমান অবস্থা অবশ্যই https://firebase.google.com/docs/test-lab/usage-quotas-pricing পাতায় মিলিয়ে নিন — Google এগুলো বদলায়):

| প্ল্যান | আসল ফোন (physical) | ভার্চুয়াল ফোন (virtual) |
|---|---|---|
| Spark (ফ্রি) | দিনে ৫টি টেস্ট | দিনে ১০টি টেস্ট |
| Blaze | দিনে প্রথম ৩০ মিনিট ফ্রি, তারপর প্রতি ফোন-ঘণ্টা প্রায় ৫ ডলার | দিনে প্রথম ৬০ মিনিট ফ্রি, তারপর প্রতি ফোন-ঘণ্টা প্রায় ১ ডলার |

এখানে "একটি টেস্ট" মানে একটি ফোনে একবার চালানো। তাই:
- **smoke** (৩টি ফোন: ২টি আসল + ১টি ভার্চুয়াল) — Spark-এ দিনে একবার নিশ্চিন্তে চলে।
- **full** — Spark-এ সর্বোচ্চ ৪টি আসল + ৮টি ভার্চুয়াল ফোন নেওয়া হয় (ওয়ার্কফ্লোর "plan = spark")। Blaze হলে "plan = blaze" দিন (১২টি আসল + ১১টি ভার্চুয়াল পর্যন্ত; প্রতি ফোনে ৫ মিনিট ধরলে প্রায় ১ ঘণ্টা আসল ফোন ≈ ৫ ডলার, ফ্রি ৩০ মিনিট বাদে)।

## ৩. সার্ভিস অ্যাকাউন্ট বানান

1. https://console.cloud.google.com • assisto-247 • **IAM & Admin** • **Service Accounts** • **+ Create service account**।
2. নাম দিন `github-testlab` • **Create and continue**।
3. **Grant this service account access** অংশে রোল দিন — দুটি পথের একটি বেছে নিন:

   **(ক) সহজ পথ:** একটি রোল **Editor**।
   - সুবিধা: সব কিছু একবারেই কাজ করে (Test Lab-এর নিজের ফলাফল-বাকেট থেকে logcat পড়াও)।
   - ঝুঁকি: এই চাবি দিয়ে assisto-247 প্রজেক্টের প্রায় সব কিছু বদলানো যায় (FCM, অন্য সার্ভিস)। চাবি ফাঁস হলে বড় ক্ষতি হতে পারে।

   **(খ) কম-অধিকারের পথ (পরামর্শ):**
   - **Firebase Test Lab Admin**
   - **Cloud Tool Results Editor** (খুঁজলে "Tool Results" লিখুন)
   - তারপর নিজের একটি ফলাফল-বাকেট বানান: **Cloud Storage** • **Buckets** • **Create** • নাম `assisto-247-testlab` • অঞ্চল `asia-south1` • বাকি ডিফল্ট • Create। বাকেট খুলে **Permissions** • **Grant access** • সার্ভিস অ্যাকাউন্টের ইমেইল (`github-testlab@assisto-247.iam.gserviceaccount.com`) • রোল **Storage Object Admin** (এতে Viewer + Creator দুটোই থাকে) • Save।
   - রান করার সময় ওয়ার্কফ্লোর **results_bucket** ঘরে লিখবেন `gs://assisto-247-testlab`।
   - ঝুঁকি কম: চাবি ফাঁস হলেও শুধু টেস্ট চালানো আর এই বাকেট দেখা যাবে।

4. **Done**।
5. তালিকায় `github-testlab` • **Keys** ট্যাব • **Add key** • **Create new key** • **JSON** • **Create**। একটি .json ফাইল ডাউনলোড হবে। এটি গোপন — কাউকে পাঠাবেন না, চ্যাটে বা গিটে রাখবেন না।

## ৪. চাবিটি GitHub-এ গোপন হিসেবে রাখুন

1. https://github.com/ArifSarkar247/assisto • **Settings** • **Secrets and variables** • **Actions** • **New repository secret**।
2. Name: `GCP_TESTLAB_SA`
3. Secret: ডাউনলোড করা .json ফাইলটি নোটপ্যাডে খুলে **পুরো লেখাটি** কপি করে এখানে পেস্ট করুন • **Add secret**।
4. কম্পিউটার থেকে .json ফাইলটি মুছে ফেলুন।
5. `CALL_PROOF_A_PHONE` ও `CALL_PROOF_A_PASSWORD` আগে থেকেই আছে — কিছু করতে হবে না।

---

## চালানো

1. GitHub • **Actions** • বাঁ দিকে **Test Lab (Robo + devices)** • **Run workflow**।
2. **apk_source:** `latest-published` (যে APK এখন ব্যবহারকারীরা পাচ্ছেন) অথবা কোনো android.yml রান-এর নম্বর (রান-এর লিংকের শেষের সংখ্যা)।
3. **device_set:** প্রথমবার `smoke`।
4. **robo_timeout:** `300s` রাখুন।
5. **plan:** আপনার প্ল্যান (`spark` / `blaze`)।
6. **results_bucket:** পথ (খ) বেছে নিলে `gs://assisto-247-testlab`, পথ (ক) হলে ফাঁকা।
7. রান শেষ হলে সারাংশে টেবিল দেখবেন; **testlab-summary** নামে ফাইলও থাকবে। কোনো ফোনে FAIL হলে রান লাল হবে।

সমস্যা হলে রান-এর লিংক ডেভ টিমকে পাঠান।
