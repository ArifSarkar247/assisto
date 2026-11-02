# Play Console-এ কোনটা কোথায় বসাবেন — ধাপে ধাপে

আমরা Play Console ছুঁই না। আপনি নিজে কপি-পেস্ট আর আপলোড করবেন। সব ফাইল এই ফোল্ডারে: `owner_actions/PLAY_LISTING_PACK/`

**কী কী আছে**
- `listing/en-US/` আর `listing/bn-BD/` — নাম, ছোট বিবরণ, পুরো বিবরণ (মূল লিস্টিং)
- `listing/*/full_description_ai_addon.txt` — AI উত্তরের ছোট অংশ, **শুধু AI চালুর পরে** (নিচে ধাপ ৬)
- `images/` — ৮টি ফোন স্ক্রিনশট প্রতি ভাষায় (`phone_en_1..8.jpg`, `phone_bn_1..8.jpg`), ফিচার গ্রাফিক (`feature_graphic_en.jpg`, `feature_graphic_bn.jpg`), সব একসাথে দেখার জন্য `preview.jpg`
- `custom/` — দুটি কাস্টম লিস্টিংয়ের লেখা; ব্যাখ্যা `CUSTOM_LISTINGS_BN.md`-এ

**লেখা কীভাবে কপি করবেন:** ফাইল খুলে সব সিলেক্ট করে কপি করুন। শেষের ফাঁকা লাইন বাদ দিলেও চলে। সীমা: নাম ৩০, ছোট বিবরণ ৮০, পুরো বিবরণ ৪০০০ অক্ষর — সব CI-তে যাচাই করা।

---

## ধাপ ১ — মূল লিস্টিং, ইংরেজি (en-US)
1. Play Console → Assisto অ্যাপ → বাঁ দিকে **Grow users → Store presence → Main store listing**।
2. ওপরে ভাষা **English (United States) – en-US** (ডিফল্ট) আছে কিনা দেখুন।
3. **App details** অংশে:
   - **App name** ← `listing/en-US/title.txt`
   - **Short description** ← `listing/en-US/short_description.txt`
   - **Full description** ← `listing/en-US/full_description.txt`
4. **Graphics** অংশে:
   - **App icon** — যেটা আছে সেটাই রাখুন (বদলাবেন না)।
   - **Feature graphic** ← `images/feature_graphic_en.jpg` (১০২৪ × ৫০০)
   - **Phone screenshots** ← আগের ছবি মুছে `images/phone_en_1.jpg` থেকে `phone_en_8.jpg` — **এই ক্রমেই** (১ প্রথমে)।
   - **7-inch tablet / 10-inch tablet screenshots** — **ফাঁকা রাখুন** (নিচে কারণ)।
5. নিচে **Save** চাপুন।

## ধাপ ২ — মূল লিস্টিং, বাংলা (bn-BD)
1. একই পাতায় **Manage translations → Add your own translation text** → **Bengali – bn-BD** বেছে **Apply**।
2. ওপরের ভাষা-তালিকা থেকে **Bengali – bn-BD** বেছে নিন।
3. **App name** ← `listing/bn-BD/title.txt`, **Short description** ← `listing/bn-BD/short_description.txt`, **Full description** ← `listing/bn-BD/full_description.txt`
4. একই ভাষায় **Graphics**: Feature graphic ← `images/feature_graphic_bn.jpg`, Phone screenshots ← `images/phone_bn_1.jpg` … `phone_bn_8.jpg` (ক্রমে)। এখানে ছবি না দিলে বাংলা ফোনেও ইংরেজি ছবি দেখাবে।
5. **Save**।

## ধাপ ৩ — পাঠানো
1. বাঁ দিকে **Publishing overview** → পরিবর্তনগুলো দেখুন → **Send for review**।
2. রিভিউ সাধারণত কয়েক ঘণ্টা থেকে কয়েক দিন। লিস্টিং বদলালে অ্যাপের ভার্সন বদলাতে হয় না।

## ধাপ ৪ — কাস্টম লিস্টিং ১: বাংলাদেশ
1. **Grow users → Store presence → Custom store listings → Create custom store listing**।
2. **Listing name**: `Bangladesh — shop and family` (এটা শুধু আপনি দেখবেন)।
3. **Target**: **Country / region** → **Bangladesh**।
4. **Default language**: **Bengali – bn-BD**। লেখা ← `custom/bangladesh/bn-BD/` (নাম, ছোট, পুরো বিবরণ)।
5. ছবি: Feature graphic ← `feature_graphic_bn.jpg`। Phone screenshots এই ক্রমে: `phone_bn_7, 8, 6, 5, 1, 2, 3, 4`।
6. **Manage translations → English (en-US)** যোগ করে ← `custom/bangladesh/en-US/` আর ছবি `phone_en_7, 8, 6, 5, 1, 2, 3, 4`, feature graphic `feature_graphic_en.jpg`।
7. **Save** → Publishing overview → Send for review।

## ধাপ ৫ — কাস্টম লিস্টিং ২: প্রবাসী (উপসাগর + মালয়েশিয়া)
1. আগে দেখুন অ্যাপ এই দেশগুলোতে পাওয়া যায় কিনা: **Production → Countries / regions** (Saudi Arabia, United Arab Emirates, Qatar, Kuwait, Oman, Bahrain, Malaysia)।
2. **Custom store listings → Create custom store listing** → নাম `Expats — Gulf and Malaysia`।
3. **Target: Country / region** → ওপরের ৭টি দেশ।
4. **Default language: English (United States) – en-US** ← `custom/expat_gulf_malaysia/en-US/`; ছবি ক্রমে `phone_en_3, 4, 2, 5, 6, 1, 7, 8`; feature graphic `feature_graphic_en.jpg`।
5. **Manage translations → Bengali – bn-BD** ← `custom/expat_gulf_malaysia/bn-BD/`; ছবি `phone_bn_3, 4, 2, 5, 6, 1, 7, 8`; feature graphic `feature_graphic_bn.jpg`।
6. **Save** → Send for review।

## ধাপ ৬ — AI চালুর পরে (শুধু তখন)
AI চাবি বসানোর পরে নিজে অ্যাপের AI চ্যাটে একটা সাধারণ প্রশ্ন করুন। আসল উত্তর এলে তবেই:
- প্রতিটি পুরো বিবরণে (মূল + দুই কাস্টম, দুই ভাষা) "ASSISTANT AND PERSONAL SECRETARY" / "সহকারী ও পার্সোনাল সেক্রেটারি" অংশের ঠিক পরে `full_description_ai_addon.txt`-এর লেখা বসান। বসানোর পরেও সব ৪০০০-এর ভেতরে থাকে (CI যাচাই করে)।
- লাইভ ওয়েবসাইটে "Ask anything" অংশ তখন নিজে থেকেই "Coming soon" থেকে চালু হয়ে যাবে — দুটো মিলিয়ে নিন।

---

## ট্যাবলেটের ছবি কেন নেই
অ্যাপ ট্যাবলেটের জন্য আলাদা করে ঘোষণা করে না: AndroidManifest-এ ট্যাবলেট/বড় স্ক্রিনের কোনো ঘোষণা নেই, আর অ্যাপে ট্যাবলেটের আলাদা লেআউট নেই (ফোনের লেআউটই বড় হয়ে দেখায়)। তাই ৭ আর ১০ ইঞ্চির ঘর ফাঁকা রাখুন। অ্যাপ ট্যাবলেটে ইনস্টল হবে, কিন্তু Play-তে "ট্যাবলেটের জন্য তৈরি" হিসেবে দেখাবে না। ট্যাবলেট লেআউট বানালে তখন ছবি যোগ করা যাবে।

## ছবিগুলো কোথা থেকে
- প্রতিটি ছবি অ্যাপের **আসল স্ক্রিন** (CI গ্যালারি), কোনো বানানো ছবি নয়। ওপরে ছোট সুবিধার শিরোনাম, ওয়েবসাইট v3-এর একই রং (নেভি + ইন্ডিগো→টিল) আর একই ফন্ট (Inter + Noto Sans Bengali, ৳ চিহ্ন ঠিকমতো দেখায়)।
- মাপ ১০৮০ × ১৯২০। ১০৮০ × ২৩৪০ নয়, কারণ Play-তে লম্বা দিক ছোট দিকের দ্বিগুণের বেশি হতে পারে না।
- স্ক্রিনশট কাটা বা চাপা হয়নি; শিরোনাম না আঁটলে CI নিজেই ফেল করে।
- নতুন করে বানাতে: ব্রাঞ্চে `ci/…` পুশ করলে **play-pack** CI চলে, আর্টিফ্যাক্ট `play-listing-pack`-এ সব ছবি থাকে।

## যা লেখায় নেই, আর কেন
- ওষুধ, ডাক্তার — কখনো নয়। অন্য অ্যাপ বা ব্র্যান্ডের নাম নেই। "সেরা", "#১", দামের দাবি, ইমোজি — নেই (Play নীতি)।
- যা এখন বন্ধ (ওয়েবসাইটে "শীঘ্রই আসছে"): গন্তব্য অ্যালার্ম, ট্রেন ট্র্যাকার, কিডস ওয়াচ, নিখোঁজ মানুষের সতর্কতা, পড়ে যাওয়া শনাক্ত, গার্ড বক্স, বুকিং বট, CRM অটোমেশন, পূর্ণ হিসাবের খাতা, এজেন্ট স্টুডিও, রেমিট্যান্স বাজেট, AI ইনবক্স। চালু হলে লেখায় যোগ করতে বলবেন — CI তখন তালিকা থেকে সরাতে হবে।
- CCTV প্ল্যান এখনো কেনা যায় না, তাই লেখায় "কিছু CCTV সুবিধার জন্য পেইড প্ল্যান লাগে" — দাম লেখা হয়নি।
