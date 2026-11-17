# Assisto Test — মালিকের টেস্ট অ্যাপ (Google Play-এর বাইরে)

**এটা কী:** "Assisto Test" নামে আলাদা একটি অ্যাপ (কমলা **TEST** চিহ্নসহ আইকন)। প্রতিদিন রাত ২:৩০-এ
main থেকে নতুন বিল্ড হয় এবং Firebase App Distribution দিয়ে (বিনামূল্যে, Google Play নয়) আপনার কাছে আসে।
Play-এর Assisto অ্যাপ যেমন আছে তেমনই থাকবে — দুটো অ্যাপ পাশাপাশি ফোনে থাকবে।

টেস্টার: assistoaiagent@gmail.com এবং axonadmin001@gmail.com (গ্রুপ "owner")।

## ইনস্টল করার ৩টি সহজ ধাপ

1. **ইমেইলের আমন্ত্রণ গ্রহণ করুন** — "Firebase App Distribution" থেকে "Assisto Test" আমন্ত্রণ আসবে।
   ফোনে ইমেইল খুলে **Get started / Accept invitation** চাপুন, ওপরের দুটো ইমেইলের একটি Google অ্যাকাউন্ট দিয়ে।
2. **App Tester অ্যাপ নিন** — একই পাতায় **Download Firebase App Tester** চাপুন ও ইনস্টল করুন।
   ফোন "অজানা অ্যাপ ইনস্টল" অনুমতি চাইলে App Tester-কে অনুমতি দিন।
3. **"Assisto Test" ইনস্টল করুন** — App Tester খুলুন → **Assisto Test** → **Download** → **Install**।
   হোম স্ক্রিনে কমলা TEST চিহ্নের আইকন আসবে। আপনার আসল অ্যাকাউন্ট দিয়ে লগইন করুন।

প্রতিদিন নতুন বিল্ড এলে ইমেইল/App Tester-এ জানাবে — App Tester থেকে **Update** চাপলেই হবে।

## মনে রাখুন (টেস্ট অ্যাপ বনাম Play অ্যাপ)

- **আসল সার্ভার:** টেস্ট অ্যাপ লাইভ সার্ভারে চলে। মেসেজ, SOS, কল — সব **সত্যিকারের মানুষের কাছে যায়**।
- **কেনাকাটা বন্ধ:** টেস্ট অ্যাপে কিছু কেনা যায় না, কোনো টাকা কাটে না (সৎভাবে "টেস্ট অ্যাপে কেনাকাটা বন্ধ" দেখায়)।
  পেইড প্ল্যান পরীক্ষা করতে টিম সার্ভারে আপনার অ্যাকাউন্টে **টেস্ট প্ল্যান** চালু করবে (শুধু তালিকাভুক্ত অ্যাকাউন্ট;
  এটা কেনা নয়, তালিকা থেকে সরালেই শেষ)।
- **বিজ্ঞাপন:** শুধু Google-এর TEST বিজ্ঞাপন — আসল বিজ্ঞাপন কখনো নয়।
- **লিংক:** lifeassisto.com-এর লিংক (ইনভাইট, শপ ইত্যাদি) Play-এর Assisto অ্যাপে খোলে, টেস্ট অ্যাপে নয়।
- **ম্যাপ:** টেস্ট অ্যাপে Google Maps চাবি নেই — ম্যাপ বিকল্প (ফ্রি) পদ্ধতিতে দেখায়।
- **ফিচার:** Play ব্যবহারকারীরা যা দেখেন, টেস্ট অ্যাপও তাই দেখায়।
- **নোটিফিকেশন (push):** নিচের ধাপ ক ও খ করার পর চালু হবে; তার আগে টেস্ট অ্যাপে push আসবে না।

## একবারের কাজ — Firebase ও GitHub-এ (মালিককে নিজে করতে হবে)

এগুলো ছাড়া বিল্ড হবে ও পরীক্ষাও পাস করবে, কিন্তু আপনার ফোনে পাঠানো যাবে না। পাসওয়ার্ড/চাবি কাউকে পাঠাবেন না —
নিজে GitHub-এ বসাবেন। GitHub-এ secret বসানো: **github.com/ArifSarkar247/assisto → Settings → Secrets and
variables → Actions → New repository secret** (নাম হুবহু নিচের মতো)।

**ক. টেস্ট অ্যাপ Firebase-এ যোগ করুন** (একই Assisto Firebase প্রজেক্টে)
1. console.firebase.google.com → Assisto প্রজেক্ট → ⚙ **Project settings** → **Your apps** → **Add app** → Android।
2. Package name: `com.assisto.assisto.staging` · App nickname: `Assisto Test` ·
   SHA-1: `98:C1:41:21:FE:83:FF:B9:9B:68:02:C5:AC:50:FE:DF:70:4D:40:8D` → **Register app**।
3. **google-services.json** ডাউনলোড করুন → ফাইলটি খুলে পুরো লেখা কপি করুন → GitHub secret
   **`STAGING_GOOGLE_SERVICES_JSON`**-এ পেস্ট করুন (এতে টেস্ট অ্যাপে push চালু হবে)। পুরনো
   `GOOGLE_SERVICES_JSON_B64` secret বদলাবেন না।
4. Project settings → Your apps → **Assisto Test**-এর **App ID** (`1:…:android:…`) কপি করুন →
   GitHub secret **`FIREBASE_STAGING_APP_ID`**।

**খ. App Distribution চালু করুন** — Firebase মেনু → **Release & Monitor → App Distribution** → অ্যাপ বাছাইয়ে
**Assisto Test** → **Get started**। (টেস্টার গ্রুপ "owner" ও দুই ইমেইল আমাদের workflow নিজেই যোগ করবে।)

**গ. আপলোডের জন্য একটি service account**
1. console.cloud.google.com → ওপরে একই Firebase প্রজেক্ট বাছাই → **IAM & Admin → Service accounts → Create service account**।
2. নাম: `assisto-appdist` → **Create and continue** → Role: **Firebase App Distribution Admin** → **Done**।
3. তালিকায় `assisto-appdist` → **Keys → Add key → Create new key → JSON** → ফাইল ডাউনলোড হবে।
4. ফাইলের পুরো লেখা কপি করে GitHub secret **`FIREBASE_APPDIST_SA_JSON`**-এ পেস্ট করুন। তারপর ফাইলটি মুছে ফেলুন।

**ঘ. প্রথমবার চালান** — GitHub → **Actions → "Assisto Test (staging app, daily)" → Run workflow** (main)।
~৪০ মিনিটে দুই ইমেইলে আমন্ত্রণ যাবে। এরপর প্রতিদিন নিজে থেকেই চলবে।

(সাইনিং চাবি `STAGING_KEYSTORE_B64` / `STAGING_KEYSTORE_PASSWORD` টিম আগেই GitHub secret-এ রেখেছে —
এটা Play-এর চাবি নয়, আলাদা।)
